#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# context-mode-summary.sh — bytes-kept-out summary on session exit.
#
# Sourced by entrypoint.sh. Provides:
#   context_mode_summary_init   — snapshot the store's byte counters before the
#                                 agent runs (no-op unless the session is wired)
#   context_mode_read_stats     — print those counters as one line of JSON
#   context_mode_compute_deltas — pure arithmetic: {"before":…,"after":…} on
#                                 stdin → four integers, "UNKNOWN <total>", or
#                                 nothing
#   context_mode_render_stats   — pure renderer: {"before":…,"after":…} on stdin
#                                 → the summary, or nothing and status 1
#   context_mode_summary_print  — re-read the counters and render on exit
#
# Also sourced by the image build, which reads CONTEXT_MODE_STATS_BIN to know
# where to generate the stats shim — so, exactly as in context-mode-setup.sh,
# sourcing this file must stay free of top-level side effects: these constants
# and these functions, and nothing else.
#
# Why this exists: before it, the only signal an enabled session gave was one
# line at wiring time, so a run where the model took every routing suggestion
# and a run where it ignored all of them looked identical from outside. That is
# also why the numbers come from exact integers rather than from
# `context-mode statusline`, whose kb() rounds to one decimal — against a
# megabyte-scale store, a run that kept 50 KB out rounds to zero.
#
# THIS REPORT AND `context-mode statusline` DELIBERATELY DISAGREE, and the
# difference is the whole point of the report — do not "restore parity".
# statusline (bin/statusline.mjs:312-319) and `ctx_stats` headline a composite:
# bytesAvoided + snapshotBytes + eventDataBytes as "kept", over that plus
# bytesReturned as a percentage. Two of those three terms are not savings.
# eventDataBytes is SUM(LENGTH(data)) over every row PostToolUse writes to
# session_events — continuity bookkeeping that accrues whether or not anything
# was ever redirected — and snapshotBytes is the PreCompact resume snapshot,
# which is context added BACK after a compact. Only bytesAvoided is context
# genuinely withheld from the model. Worse, the denominator holds only
# retrieval cost, so the percentage sits near 100% by construction and reads
# LOWEST exactly when the feature is working hardest; a session that redirected
# nothing at all still printed "11.7 KB kept out (100%)". This report therefore
# prints bytesAvoided alone as "kept out" and the bytesReturned delta as a
# separate re-read term, with no percentage at all. The magnitudes still agree
# with statusline for the same counter (see _humanize_bytes), but the headline
# numbers differ: statusline's is larger because it counts bookkeeping, ours is
# the saving.
# ─────────────────────────────────────────────────────────────────────────────

# The stats shim the image build generates beside the context-mode shim. It
# prints upstream's own byte counters for one sessions directory as JSON.
# Overridable so the reader and the gate can be tested without the image, the
# same way CONTEXT_MODE_BIN is.
CONTEXT_MODE_STATS_BIN="${CONTEXT_MODE_STATS_BIN:-${HOME}/.local/bin/context-mode-stats}"

# The bind-mounted drop directory for per-run records (scripts/mount-projects.sh
# mounts the host ledger here). Overridable for tests, the same way
# CONTEXT_MODE_STATS_BIN is. Absent means the feature is not configured — not
# broken — because the mount and the toggle are emitted by the same condition.
CONTEXT_MODE_LEDGER_DIR="${CONTEXT_MODE_LEDGER_DIR:-${HOME}/.riotbox-ledger}"

# _humanize_bytes N
# Print N as B / KB / MB / GB with no trailing newline.
#
# Deliberately mirrors upstream's kb() (build/session/analytics.js:1316-1331) —
# one decimal below 100 units, whole numbers above, two decimals for GB — so
# this report and `context-mode statusline` never disagree about the magnitude of
# the same store. The arithmetic upstream rounds away happens on integers here;
# only the display is humanized.
#
# The int(x + 0.5) is not decoration. awk's "%d" truncates where upstream uses
# Math.round, so a plain "%d" would render 226280 bytes as "220 KB" against
# statusline's "221 KB" for the identical store — a discrepancy a reader would
# reasonably read as one of the two numbers being wrong. Verified equal to kb()
# across the boundary values the test pins.
# LC_ALL=C pins the decimal point regardless of the caller's locale. gawk
# normally ignores locale for printf's "%f" family and always emits '.', but
# under POSIXLY_CORRECT (or --posix) it honors LC_NUMERIC, and a de_DE-family
# locale renders "%.1f" with a comma — "1,5 KB" instead of "1.5 KB". Pinning
# LC_NUMERIC alone is not enough: POSIX defines LC_ALL, when set, as
# overriding every individual LC_* variable, so LC_NUMERIC=C would still lose
# to an ambient LC_ALL=de_DE... LC_ALL=C is the only override that wins. This
# file claims never to disagree with `context-mode statusline` about the same
# store; a locale-dependent separator would break that promise silently.
_humanize_bytes() {
	LC_ALL=C awk -v n="$1" 'BEGIN{
		if (n < 1024) { printf "%d B", int(n + 0.5); exit }
		k = n / 1024
		if (k < 1024) { if (k < 100) printf "%.1f KB", k; else printf "%d KB", int(k + 0.5); exit }
		m = k / 1024
		if (m < 1024) { if (m < 100) printf "%.1f MB", m; else printf "%d MB", int(m + 0.5); exit }
		g = m / 1024
		if (g < 100) printf "%.2f GB", g; else printf "%.1f GB", g
	}'
}

# context_mode_compute_deltas
# Reads {"before": <stats|null>, "after": <stats>, "baseline_unknown": <bool>}
# on stdin. Prints either four space-separated integers —
#   <kept-out delta> <re-read delta> <retained total> <hook-log delta>
# — or "UNKNOWN <retained total>" when the baseline could not be read, or
# nothing at all when the input is malformed.
#
# Extracted from context_mode_render_stats so the renderer and
# context_mode_ledger_append cannot compute different numbers for one store.
# The clamps are the reason this must not be duplicated: SessionStart runs
# cleanupOldSessions(7) after the baseline is taken, so a pruned store can be
# smaller at exit than at start, and two copies of that rule would eventually
# disagree about a negative delta.
#
# $b distinguishes two DIFFERENT non-object shapes: null/absent .before is a
# first run (falls to {}), while any other non-object .before — a number, an
# array, a string — is malformed input (falls to `null`, which the `if $b ==
# null` below turns into `empty` — silence, same as every other malformed
# shape). Collapsing both cases the same way is exactly the bug this branch
# exists to avoid: coercing a corrupted baseline to {} would report the
# entire store as this run's savings, the one failure mode worse than staying
# silent for a feature whose only job is being trustworthy evidence.
#
# baseline_unknown is checked FIRST and unconditionally, before .before is
# looked at at all, so a null .before caused by a failed read is never
# mistaken for the null .before of a genuine first run.
context_mode_compute_deltas() {
	jq -r '
		def kept: (.bytesAvoided // 0);
		def ret:  (.bytesReturned // 0);
		def ev:   (.eventDataBytes // 0);
		def clamp: if . < 0 then 0 else . end;
		if (type != "object") or ((.after | type) != "object") then empty
		elif .baseline_unknown == true then
			"UNKNOWN \(.after | kept)"
		else
			(if .before == null then {}
			 elif (.before | type) == "object" then .before
			 else null end) as $b
			| if $b == null then empty
			  else
				.after as $a
				| ((($a | kept) - ($b | kept)) | clamp) as $dk
				| ((($a | ret)  - ($b | ret))  | clamp) as $dr
				| ((($a | ev)   - ($b | ev))   | clamp) as $de
				| "\($dk) \($dr) \($a | kept) \($de)"
			  end
		end' 2>/dev/null
}

# context_mode_render_stats
# Reads {"before": <stats|null>, "after": <stats>, "baseline_unknown": <bool>}
# on stdin and prints the summary. Returns 1 printing nothing when:
#   - stdin is empty, not valid JSON, or not an object
#   - .after is absent or not an object — the store could not be read at exit,
#     and a report with no end state is not a report
#
# A row of zeros is NOT one of those conditions. It once was, on the reasoning
# that an idle feature has nothing to say; that rule made a session which saved
# nothing print exactly what a session with no wiring printed, which is the one
# distinction this report exists to draw. See the always-print note below.
#
# The totals are labelled "last 7 days", not "lifetime", and the label is a fact
# about upstream rather than a hedge: bytesAvoided is SUM(session_events
# .bytes_avoided), and hooks/sessionstart.mjs calls cleanupOldSessions(7) — a
# hardcoded literal at every call site, with no configuration knob — which
# deletes session_events, session_meta and session_resume for sessions older
# than seven days. The parked content survives that sweep (build/session/
# purge.js is the only thing that deletes chunks, reachable solely through
# ctx_purge), so retrieval keeps working across the boundary while the counters
# do not. Anything that needs totals beyond seven days has to capture them at
# session exit; they cannot be re-derived from the store later.
#
# Three terms, each straight from one counter, and no percentage:
#
#   kept out  = bytesAvoided — SUM(session_events.bytes_avoided), the bytes the
#               PreToolUse hooks actually withheld from the model's context.
#               eventDataBytes is excluded because it is this feature's own
#               bookkeeping, not a saving; snapshotBytes is excluded because a
#               resume snapshot is context added back after a compact. See the
#               header for why counting either inverts the signal. The stats
#               shim calls getRealBytesStats with sessionsDir alone — no
#               contentDbPath — so this figure is the session_events column and
#               nothing else, which is the conservative direction to be wrong in.
#   re-read   = bytesReturned — the cost of pulling kept-out content back in
#               (session_events.bytes_returned plus the ctx_search /
#               ctx_fetch_and_index rows of tool_calls; the label names the
#               common one). It is a cost, not a saving, so it is reported
#               beside the saving rather than folded into a ratio with it.
#   hook log  = eventDataBytes — the continuity rows PostToolUse writes for
#               every matched call, whether or not anything was redirected.
#               Named "on disk" because that is the whole of it: these rows are
#               read back only by aggregate queries (COUNT, SUM(LENGTH(data)),
#               GROUP BY category) and by getMcpToolUsage for stats. Nothing
#               feeds them to a hook's additionalContext, so they are SQLite
#               volume and cost ZERO tokens. The counter that does re-enter
#               context is snapshotBytes, and it is excluded for that reason.
#
#               It earns a place on a line about context bytes anyway, because
#               it is the only proof-of-life the report has: non-zero means the
#               hooks fired. Beside a zero kept-out that is the entire
#               diagnosis — the feature ran and withheld nothing — and it is
#               unavailable from any other number here. The unit is stated on
#               the line so it cannot be read as a token cost; upstream's
#               headline divides this same counter by 4 and calls the result
#               saved tokens, which is what happens when it is not.
#
# A run with nothing to report still prints, and the block is unconditional
# because silence was not neutral: a session that saved nothing and a session
# where the feature never engaged both printed nothing, so the report could not
# answer the one question it exists for. The two are now told apart by the hook
# log term rather than by the presence of output. Individual terms still drop
# out at zero — a term with no number behind it says nothing — but the block
# does not.
#
# The re-read term is omitted when its delta is zero, and that omission is
# information rather than tidiness: a large kept-out with no retrieval at all is
# what a session looks like when the MCP server never started — the hooks denied
# the tool calls and pointed the model at ctx_search tools that did not exist,
# so bytes were "kept out" that the model never got back by any route. Printing
# " · 0 B re-read" would bury that shape among the ordinary runs; its absence
# next to a big kept-out figure is the tell.
context_mode_render_stats() {
	local raw
	raw="$(cat)"
	[[ -n "${raw}" ]] || return 1

	# See context_mode_compute_deltas for the shape rules (first run vs.
	# malformed .before, baseline_unknown, the negative-delta clamp).
	local computed
	computed="$(context_mode_compute_deltas <<<"${raw}")" || return 1
	[[ -n "${computed}" ]] || return 1

	local store="${CONTEXT_MODE_DIR:-${CLAUDE_CONFIG_DIR:-${HOME}/.claude}/context-mode}"

	# The unknown-baseline path: one integer, not four. Handled before the
	# guard below, which expects exactly four from the other branch. The store
	# line is identical in both: scope is a property of the mount, not of what
	# this particular run managed to measure.
	if [[ "${computed}" == "UNKNOWN "* ]]; then
		local lifetime="${computed#UNKNOWN }"
		[[ "${lifetime}" =~ ^[0-9]+$ ]] || return 1
		printf '── context-mode ─────────────────────────────────────\n'
		printf ' this run unknown (baseline could not be read) · last 7 days %s\n' \
			"$(_humanize_bytes "${lifetime}")"
		printf ' store: %s (this project set)\n' "${store}"
		return 0
	fi

	local run_kept run_returned lifetime run_events
	read -r run_kept run_returned lifetime run_events <<<"${computed}"

	# Guard the arithmetic before using it in a test: a jq program that emitted
	# anything but four integers must be silent, not a bash error at teardown.
	# There is deliberately no "and at least one of them is non-zero" guard
	# among these — an all-zero run is a result, not a malformed one.
	[[ "${run_kept}" =~ ^[0-9]+$ ]] || return 1
	[[ "${run_returned}" =~ ^[0-9]+$ ]] || return 1
	[[ "${lifetime}" =~ ^[0-9]+$ ]] || return 1
	[[ "${run_events}" =~ ^[0-9]+$ ]] || return 1

	# Built up rather than printed from a branch per shape: with three optional
	# terms that would be four printf variants of the same line. Each append is
	# a full `if` and not `[[ … ]] && run_line+=…`, because a false test as the
	# tail of an AND-list becomes the list's exit status, and this file is
	# sourced into shells whose options it does not control — some run `set -e`.
	local run_line
	run_line=" this run $(_humanize_bytes "${run_kept}") kept out"
	if [[ "${run_returned}" -gt 0 ]]; then
		run_line+=" · $(_humanize_bytes "${run_returned}") re-read via ctx_search"
	fi
	if [[ "${run_events}" -gt 0 ]]; then
		run_line+=" · $(_humanize_bytes "${run_events}") hook log on disk"
	fi

	printf '── context-mode ─────────────────────────────────────\n'
	printf '%s\n' "${run_line}"
	printf ' last 7 days %s\n' "$(_humanize_bytes "${lifetime}")"
	printf ' store: %s (this project set)\n' "${store}"
}

# context_mode_ledger_append <before-after-json>
# Write one record for this run into CONTEXT_MODE_LEDGER_DIR.
#
# Takes the JSON context_mode_summary_print already assembled, so the record
# and the printed report come from one read of the store and cannot disagree.
#
# Returns 0 on EVERY path, including every failure. This runs in the teardown
# after the agent's exit status has been captured; a ledger that could change
# that status would be worse than no ledger. Failures are silent for the same
# reason the report's are: a teardown that complains about its own bookkeeping
# is noise on the one stream an autonomous run might be reading for real output.
context_mode_ledger_append() {
	[[ "${_CONTEXT_MODE_WIRED:-0}" = "1" ]] || return 0
	[[ -d "${CONTEXT_MODE_LEDGER_DIR}" ]] || return 0
	[[ -w "${CONTEXT_MODE_LEDGER_DIR}" ]] || return 0

	local raw="${1:-}"
	[[ -n "${raw}" ]] || return 0

	local computed
	computed="$(context_mode_compute_deltas <<<"${raw}")" || return 0
	[[ -n "${computed}" ]] || return 0

	# jq --argjson accepts the literal `null`, which is how an unknown baseline
	# records "not measured" rather than a zero indistinguishable from a real
	# zero-saving run. The retained total is known in both branches.
	local kept re_read hook_log total unknown="false"
	if [[ "${computed}" == "UNKNOWN "* ]]; then
		total="${computed#UNKNOWN }"
		kept="null"
		re_read="null"
		hook_log="null"
		unknown="true"
	else
		# Field order — kept-out, re-read, retained total, hook log — is
		# context_mode_compute_deltas's contract; see that function for the
		# shape rules this positional read relies on.
		read -r kept re_read total hook_log <<<"${computed}"
		[[ "${kept}" =~ ^[0-9]+$ ]] || return 0
		[[ "${re_read}" =~ ^[0-9]+$ ]] || return 0
		[[ "${hook_log}" =~ ^[0-9]+$ ]] || return 0
	fi
	[[ "${total}" =~ ^[0-9]+$ ]] || return 0

	local ended_at stamp
	ended_at="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)" || return 0
	stamp="$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null)" || return 0

	# started defaults to the empty string when context_mode_summary_init never
	# ran or swallowed a `date` failure with `|| true`; the jq program below
	# turns that into a JSON null rather than an empty string, matching how
	# every other unmeasured field in this schema reads — a reader can check
	# for null, but an empty string that looks like a truncated timestamp
	# invites a naive date parse to accept it and fail downstream instead.
	local record
	record="$(jq -nc \
		--arg started "${_CONTEXT_MODE_SUMMARY_STARTED_AT:-}" \
		--arg ended "${ended_at}" \
		--arg sid "${SESSION_ID:-unknown}" \
		--arg pset "${RIOTBOX_SESSION_KEY:-unknown}" \
		--arg agent "${RIOTBOX_AGENT:-claude}" \
		--argjson kept "${kept}" \
		--argjson reread "${re_read}" \
		--argjson hooklog "${hook_log}" \
		--argjson total "${total}" \
		--argjson unknown "${unknown}" \
		'{schema: 1, started_at: (if $started == "" then null else $started end),
		  ended_at: $ended, session_id: $sid,
		  project_set: $pset, agent: $agent, kept_out_bytes: $kept,
		  re_read_bytes: $reread, hook_log_bytes: $hooklog,
		  retained_total_bytes: $total, baseline_unknown: $unknown}' 2>/dev/null)" || return 0
	[[ -n "${record}" ]] || return 0

	json_write_atomic \
		"${CONTEXT_MODE_LEDGER_DIR}/${stamp}-${SESSION_ID:-unknown}.json" \
		"${record}" 2>/dev/null || return 0
	return 0
}

# context_mode_read_stats [timeout_seconds]
# Print the store's byte counters as one line of JSON, or nothing. The budget
# defaults to 10 — the teardown path's value, and the same guard
# headroom_summary_print uses, since a wedged read must not hold a session's
# exit open. context_mode_summary_init passes a shorter budget of its own: see
# that function for why the two callers cannot share one number.
#
# Silent on every failure, and that is deliberate: the shim is absent on an
# image built before this feature, the sessions directory does not exist until
# something writes it, and a teardown that warns about its own report is worse
# than one that says nothing.
context_mode_read_stats() {
	local budget="${1:-10}"
	[[ -x "${CONTEXT_MODE_STATS_BIN}" ]] || return 1
	command -v jq >/dev/null 2>&1 || return 1
	local sessions="${CONTEXT_MODE_DIR:-${CLAUDE_CONFIG_DIR:-${HOME}/.claude}/context-mode}/sessions"
	[[ -d "${sessions}" ]] || return 1

	local raw
	raw="$(timeout "${budget}" "${CONTEXT_MODE_STATS_BIN}" "${sessions}" 2>/dev/null)" || return 1
	# The naive `jq -ce 'type == "object"'` looks equivalent but is not: -e's
	# exit status reflects the LAST output value, so it would exit 0 having
	# printed the boolean `true` — the string "true", not the counters — and
	# the baseline this function feeds would become that string. Print the
	# object itself when it validates, nothing otherwise, so a caller that
	# captures stdout gets the counters or gets silence, never a decoy.
	jq -ce 'if type == "object" then . else empty end' <<<"${raw}" 2>/dev/null
}

# context_mode_summary_init
# Snapshot the counters before the agent runs. No-op unless context_mode_wire
# reported success — an unwired session has nothing to measure, and taking a
# baseline anyway would let a later toggle change print a report for a run that
# never had the feature.
#
# Reads with a 3-second budget, not the teardown's 10: this call sits in front
# of the agent, on the critical path to a usable session, while
# context_mode_summary_print's read sits behind it with nothing waiting on it.
# The stats shim opens the session's SQLite store with a 30-second
# busy_timeout, so a concurrent session mid-write is a real way to stall this
# read, not a hypothetical one.
#
# A failed read is NOT the same baseline as a store that never existed, and
# collapsing the two used to be the bug here: context_mode_render_stats treats
# a null .before as a first run and attributes the WHOLE store to this run's
# savings, which is correct when the store genuinely did not exist yet but
# wrong — reporting a stall as a zero baseline — when a concurrent session's
# write lock is what stopped the read. The two are told apart by whether the
# sessions directory already holds a database: none means Context Mode really
# has never run here, so an absent baseline is honest and the first-run path
# below is correct as-is. One or more means a real baseline exists and simply
# could not be read in the budget, so _CONTEXT_MODE_SUMMARY_BASELINE_UNKNOWN is
# set for context_mode_summary_print to pass on to the renderer, which prints
# the retained total on exit without a "this run" claim it cannot back up.
context_mode_summary_init() {
	[[ "${_CONTEXT_MODE_WIRED:-0}" = "1" ]] || return 0
	_CONTEXT_MODE_SUMMARY_STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)"
	unset _CONTEXT_MODE_SUMMARY_BASELINE_UNKNOWN
	if _CONTEXT_MODE_SUMMARY_START="$(context_mode_read_stats 3)"; then
		return 0
	fi
	_CONTEXT_MODE_SUMMARY_START=""

	local sessions="${CONTEXT_MODE_DIR:-${CLAUDE_CONFIG_DIR:-${HOME}/.claude}/context-mode}/sessions"
	local existing
	existing="$(find "${sessions}" -maxdepth 1 -name '*.db' -print -quit 2>/dev/null)"
	[[ -n "${existing}" ]] && _CONTEXT_MODE_SUMMARY_BASELINE_UNKNOWN=1

	# Explicit: the common case is no *.db found, which leaves the `&&` above
	# at status 1. That must not become this function's own return status —
	# this file is sourced into shells whose options it does not control, and a
	# caller running `set -e` would abort on it. Every other exit here is
	# already 0 by construction (a no-op, or a successful read).
	return 0
}

# context_mode_summary_print
# Re-read the counters and render. Never propagates failure and never affects the
# exit code: this runs in entrypoint.sh's teardown, after the agent's status has
# been captured and before it is returned.
context_mode_summary_print() {
	[[ "${_CONTEXT_MODE_WIRED:-0}" = "1" ]] || return 0

	local after
	after="$(context_mode_read_stats)" || return 0
	[[ -n "${after}" ]] || return 0

	# --argjson rejects an empty string, so an absent baseline is passed as a
	# JSON null; the renderer treats that as a first run rather than an error
	# — UNLESS baseline_unknown is true, which is how context_mode_summary_init
	# tells it that this null came from a failed read against a store that
	# already existed, not from a store that never did.
	local baseline_unknown="false"
	[[ "${_CONTEXT_MODE_SUMMARY_BASELINE_UNKNOWN:-0}" = "1" ]] && baseline_unknown="true"

	local payload
	payload="$(jq -nc \
		--argjson before "${_CONTEXT_MODE_SUMMARY_START:-null}" \
		--argjson after "${after}" \
		--argjson baseline_unknown "${baseline_unknown}" \
		'{before: $before, after: $after, baseline_unknown: $baseline_unknown}' 2>/dev/null)" || return 0
	[[ -n "${payload}" ]] || return 0

	context_mode_render_stats <<<"${payload}" || true
	context_mode_ledger_append "${payload}" || true
}
