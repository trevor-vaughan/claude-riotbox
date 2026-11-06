#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# context-mode-summary.sh — bytes-kept-out summary on session exit.
#
# Sourced by entrypoint.sh. Provides:
#   context_mode_summary_init   — take a per-store watermark before the agent
#                                 runs (no-op unless the session is wired)
#   context_mode_read_stats     — print the stores' counters as one line of JSON
#   context_mode_compute_deltas — pure: {"after":…,"baseline_unknown":…} on
#                                 stdin → four integers, "UNKNOWN <total>", or
#                                 nothing
#   context_mode_render_stats   — pure renderer: the same JSON on stdin → the
#                                 summary, or nothing and status 1
#   context_mode_summary_print  — re-read the stores above the watermark and
#                                 render on exit
#
# Also sourced by the image build, which reads CONTEXT_MODE_STATS_BIN to know
# where to generate the stats shim — so, exactly as in context-mode-setup.sh,
# sourcing this file must stay free of top-level side effects: these constants
# and these functions, and nothing else.
#
# Why this exists: before it, the only signal an enabled session gave was one
# line at wiring time, so a run where the model took every routing suggestion
# and a run where it ignored all of them looked identical from outside. That is
# also why the numbers come from exact integers rather than from a humanized
# figure: against a megabyte-scale store, a run that kept 50 KB out rounds to
# zero.
#
# Where the numbers come from. context-mode 2.x keeps one SQLite store per
# project at ~/.context-mode/projects/<key>/context.db. It writes an `events`
# row for shell commands, edits, tool errors and ctx_* calls — and for nothing
# else: upstream's journalKind (src/core/hooks/dispatch.ts) gives a clean
# Read, Grep, WebFetch or other host tool no row, even when the hook replaces
# its output. Such an output is indexed into `sources` and leaves no byte pair
# to measure. In a row, sandbox_bytes is what the call produced and
# returned_bytes is what the model received. The stats shim
# (container/context-mode-stats.mjs on the pinned Node) reads those rows; the
# SQL and the exact row classes are in that file.
#
# So kept out is a LOWER BOUND: a replaced 169 KB Read is a real saving that
# this report does not see. Counting it would mean reading `sources`, whose
# rows do not say what the model received in place of the output; that is
# left for a follow-up rather than estimated here.
#
# THIS REPORT AND UPSTREAM'S `ctx_stats` DELIBERATELY DISAGREE, and the
# difference is the whole point of the report — do not "restore parity".
# ctx_stats (src/core/tools/stats.ts) groups rows by (session_id, agent), takes
# max(0, SUM(sandbox_bytes) − SUM(returned_bytes)) per group as "saved", and
# headlines saved/produced as a reduction percentage. Three things in that are
# not savings:
#   * the netting. Inside a group a ctx_search reply (sandbox 0, returned n)
#     subtracts from another call's saving — upstream's own comment calls it
#     "index then search nets out". A re-read is a cost, not a negative saving,
#     and netting it hides both numbers.
#   * the rows it counts as produced. Every tool except ctx_stats is in the
#     sum, so a ctx_doctor report is "saved", and so are ctx_index bytes, which
#     may be content the model itself wrote into the call — bytes that were
#     already in its context.
#   * the percentage. Its denominator is what the tools produced, which says
#     nothing about what reached the model, and it hides the absolute figure.
# The 1.x report rejected upstream's composite for the same reason: count only
# bytes genuinely withheld from the model. 2.x has no bookkeeping counters to
# leave out (1.x's eventDataBytes and snapshotBytes have no column, and the
# PreCompact snapshot is gone), so the rule now comes down to which ROWS count:
#
#   kept out = SUM over work calls of MAX(sandbox_bytes − returned_bytes, 0),
#              clamped per row so no call cancels another's saving; work calls
#              are every tool call except the diagnostic tools (ctx_stats,
#              ctx_doctor, ctx_upgrade, ctx_purge), ctx_index, and the two
#              retrieval tools
#   re-read  = SUM(returned_bytes) of ctx_search and ctx_resume, a separate
#              cost term
#   no percentage at all
#
# The ctx_index exclusion is the conservative direction to be wrong in: a row
# does not say whether the indexed bytes came from a path or URL (never in
# context) or from the call's own `content` (already in context), so none of
# them are claimed. The 1.x report did not count ctx_index as kept out either.
#
# Which rows are this run's. ~/.context-mode is one mount per project set,
# shared by every concurrent run of it (scripts/mount-projects.sh), so the
# stores are not this run's alone. Init records each store's AUTOINCREMENT
# counter as a watermark; at exit only rows above it count, and only rows this
# run's agent wrote (the `agent` column: claude-code, opencode or pi). The
# agent filter is the scope the 1.x stores had, which lived in each agent's own
# config directory.
#
# Concurrent runs. Two runs of the SAME agent on one project set at the same
# time write rows the report cannot tell apart, and each run's report counts
# both. No column 2.x writes identifies a run: session_id is the agent's own
# session id, which RiotBox neither assigns nor learns (and `riotbox resume`
# continues the last one, so two runs can even share it); worktree is the same
# /workspace path; agent is the same agent. 1.x had the same overlap, since
# its counters were store-wide totals read before and after. The report says
# "this run" because it is exact for the usual case of one run per project set
# at a time; with concurrent runs it is an upper bound.
# ─────────────────────────────────────────────────────────────────────────────

# The stats shim the image build generates beside the context-mode shim. It
# runs container/context-mode-stats.mjs on the pinned Node; see that file for
# its arguments and its JSON. Overridable so the reader and the gate can be
# tested without the image, the same way CONTEXT_MODE_BIN is.
CONTEXT_MODE_STATS_BIN="${CONTEXT_MODE_STATS_BIN:-${HOME}/.local/bin/context-mode-stats}"

# The bind-mounted drop directory for per-run records (scripts/mount-projects.sh
# mounts the host ledger here). Overridable for tests, the same way
# CONTEXT_MODE_STATS_BIN is. Absent means the feature is not configured — not
# broken — because the mount and the toggle are emitted by the same condition.
CONTEXT_MODE_LEDGER_DIR="${CONTEXT_MODE_LEDGER_DIR:-${HOME}/.riotbox-ledger}"

# context-mode 2.x's data root. Not configurable here: context-mode-setup.sh
# unsets CONTEXT_MODE_DATA_DIR, upstream's only override, so the stores are
# always on the ~/.context-mode mount.
CONTEXT_MODE_STORE_ROOT="${HOME}/.context-mode"

# _humanize_bytes N
# Print N as B / KB / MB / GB with no trailing newline.
#
# Deliberately mirrors 1.x upstream's kb() (build/session/analytics.js:1316-1331)
# — one decimal below 100 units, whole numbers above, two decimals for GB — so
# this report never disagreed with 1.x's `context-mode statusline` about the
# magnitude of the same store, and so ledger records from 1.x and 2.x runs
# render alike in `riotbox ctx-stats`. The arithmetic happens on integers;
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
# to an ambient LC_ALL=de_DE... LC_ALL=C is the only override that wins. The
# exit report and `riotbox ctx-stats` share this function so they never render
# one number two ways; a locale-dependent separator would break that silently.
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
# Reads {"after": <stats>, "baseline_unknown": <bool>} on stdin, where <stats>
# is the stats shim's JSON. Prints either four space-separated integers —
#   <kept-out> <re-read> <store total> <tool calls>
# — or "UNKNOWN <store total>" when the run has no usable baseline, or nothing
# at all when the input is malformed.
#
# Extracted from context_mode_render_stats so the renderer and
# context_mode_ledger_append cannot read different numbers out of one store.
# The run figures are already scoped to the run by the shim's SQL, so there is
# no arithmetic left here; what is left is the shape rule, and that is the
# part that must not be duplicated:
#   * every figure must be a non-negative integer. A missing or null field is
#     malformed, not zero — a `// 0` here would turn a reader that lost a
#     column into a confident "0 B kept out".
#   * baseline_unknown (init could not read a store that exists) and rewound
#     (a store's counter is below its watermark: it was recreated during the
#     run and has not yet grown past the old counter) both mean the run
#     figures cannot be trusted. Only the store total survives, and it is still
#     validated. A recreated store that has already grown past its watermark
#     is not detected; its rows above the watermark are counted as the run's.
context_mode_compute_deltas() {
	jq -r '
		def nat: (type == "number") and (. >= 0) and (. == floor);
		if (type != "object") or ((.after | type) != "object") then empty
		else
			.after as $a
			| if ($a.total_kept_out | nat | not) then empty
			  elif (.baseline_unknown == true) or ($a.rewound == true) then
				"UNKNOWN \($a.total_kept_out)"
			  elif ([$a.kept_out, $a.re_read, $a.calls] | all(nat)) then
				"\($a.kept_out) \($a.re_read) \($a.total_kept_out) \($a.calls)"
			  else empty end
		end' 2>/dev/null
}

# context_mode_render_stats
# Reads {"after": <stats>, "baseline_unknown": <bool>} on stdin and prints the
# summary. Returns 1 printing nothing when context_mode_compute_deltas does:
# stdin empty, not JSON, not an object, or .after missing or mistyped. A store
# that could not be read at exit never gets this far — there is no .after to
# render, and a report with no end state is not a report.
#
# A row of zeros is NOT one of those conditions. It once was, on the reasoning
# that an idle feature has nothing to say; that rule made a session which saved
# nothing print exactly what a session with no wiring printed, which is the one
# distinction this report exists to draw. See the always-print note below.
#
# Three lines:
#
#   this run     kept out, then re-read and the tool-call count when non-zero.
#                See the header for what each counts. The tool-call count is
#                the report's proof of life: non-zero means the hooks or the
#                MCP server recorded calls, so beside a zero kept-out it is the
#                whole diagnosis — the feature ran and withheld nothing. It
#                counts only the calls 2.x journals (shell commands, edits,
#                tool errors, ctx_* calls), so a session of Reads and Greps
#                shows none. It is a count of calls, not bytes, so nothing on
#                the line can be read as a token cost that never reached the
#                model.
#   store total  kept out over every row the stores hold for this agent. It is
#                not a time window: 2.x's row retention deletes indexed sources
#                idle for 30 days, but never events; only ctx_purge and the
#                dead-project sweep (a whole project idle for 14 days with no
#                live owner) remove them. A total that drops between runs is
#                one of those two. The ledger keeps the durable history.
#   store        where the stores are, and that they are this project set's.
#
# A run with nothing to report still prints, and the block is unconditional
# because silence was not neutral: a session that saved nothing and a session
# where the feature never engaged both printed nothing, so the report could not
# answer the one question it exists for. Individual terms still drop out at
# zero — a term with no number behind it says nothing — but the block does not.
#
# The re-read term is omitted when it is zero, and that omission is
# information rather than tidiness: a large kept-out with no retrieval at all is
# what a session looks like when the MCP server never started — the hooks
# replaced the output and pointed the model at ctx_search tools that did not
# exist, so bytes were "kept out" that the model never got back by any route.
# Printing " · 0 B re-read" would bury that shape among the ordinary runs; its
# absence next to a big kept-out figure is the tell.
context_mode_render_stats() {
	local raw
	raw="$(cat)"
	[[ -n "${raw}" ]] || return 1

	local computed
	computed="$(context_mode_compute_deltas <<<"${raw}")" || return 1
	[[ -n "${computed}" ]] || return 1

	# The unusable-baseline path: one integer, not four. Handled before the
	# guard below, which expects exactly four from the other branch. The store
	# line is identical in both: scope is a property of the mount, not of what
	# this particular run managed to measure.
	if [[ "${computed}" == "UNKNOWN "* ]]; then
		local total="${computed#UNKNOWN }"
		[[ "${total}" =~ ^[0-9]+$ ]] || return 1
		printf '── context-mode ─────────────────────────────────────\n'
		# shellcheck disable=SC2312  # _humanize_bytes is a display formatter — its awk exits 0 on every path
		printf ' this run unknown (no usable baseline) · store total %s kept out\n' \
			"$(_humanize_bytes "${total}")"
		printf ' store: %s (this project set)\n' "${CONTEXT_MODE_STORE_ROOT}"
		return 0
	fi

	local run_kept run_returned total run_calls
	read -r run_kept run_returned total run_calls <<<"${computed}"

	# Guard the arithmetic before using it in a test: a jq program that emitted
	# anything but four integers must be silent, not a bash error at teardown.
	# There is deliberately no "and at least one of them is non-zero" guard
	# among these — an all-zero run is a result, not a malformed one.
	[[ "${run_kept}" =~ ^[0-9]+$ ]] || return 1
	[[ "${run_returned}" =~ ^[0-9]+$ ]] || return 1
	[[ "${total}" =~ ^[0-9]+$ ]] || return 1
	[[ "${run_calls}" =~ ^[0-9]+$ ]] || return 1

	# Built up rather than printed from a branch per shape: with two optional
	# terms that would be four printf variants of the same line. Each append is
	# a full `if` and not `[[ … ]] && run_line+=…`, because a false test as the
	# tail of an AND-list becomes the list's exit status, and this file is
	# sourced into shells whose options it does not control — some run `set -e`.
	local run_line
	run_line=" this run $(_humanize_bytes "${run_kept}") kept out"
	if [[ "${run_returned}" -gt 0 ]]; then
		run_line+=" · $(_humanize_bytes "${run_returned}") re-read via ctx_search"
	fi
	if [[ "${run_calls}" -eq 1 ]]; then
		run_line+=" · 1 tool call recorded"
	elif [[ "${run_calls}" -gt 1 ]]; then
		run_line+=" · ${run_calls} tool calls recorded"
	fi

	printf '── context-mode ─────────────────────────────────────\n'
	printf '%s\n' "${run_line}"
	# shellcheck disable=SC2312  # _humanize_bytes is a display formatter — its awk exits 0 on every path
	printf ' store total %s kept out\n' "$(_humanize_bytes "${total}")"
	printf ' store: %s (this project set)\n' "${CONTEXT_MODE_STORE_ROOT}"
}

# context_mode_ledger_append <payload-json>
# Write one record for this run into CONTEXT_MODE_LEDGER_DIR.
#
# Takes the JSON context_mode_summary_print already assembled, so the record
# and the printed report come from one read of the stores and cannot disagree.
# The record is schema 2; docs/dev/decisions/context-mode-ledger.md has both
# schemas and why they differ.
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

	# jq --argjson accepts the literal `null`, which is how an unusable baseline
	# records "not measured" rather than a zero indistinguishable from a real
	# zero-saving run. The store total is known in both branches.
	local kept re_read calls total unknown="false"
	if [[ "${computed}" == "UNKNOWN "* ]]; then
		total="${computed#UNKNOWN }"
		kept="null"
		re_read="null"
		calls="null"
		unknown="true"
	else
		# Field order — kept-out, re-read, store total, tool calls — is
		# context_mode_compute_deltas's contract; see that function for the
		# shape rules this positional read relies on.
		read -r kept re_read total calls <<<"${computed}"
		[[ "${kept}" =~ ^[0-9]+$ ]] || return 0
		[[ "${re_read}" =~ ^[0-9]+$ ]] || return 0
		[[ "${calls}" =~ ^[0-9]+$ ]] || return 0
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
		--argjson calls "${calls}" \
		--argjson total "${total}" \
		--argjson unknown "${unknown}" \
		'{schema: 2, started_at: (if $started == "" then null else $started end),
		  ended_at: $ended, session_id: $sid,
		  project_set: $pset, agent: $agent, kept_out_bytes: $kept,
		  re_read_bytes: $reread, tool_calls: $calls,
		  retained_total_bytes: $total, baseline_unknown: $unknown}' 2>/dev/null)" || return 0
	[[ -n "${record}" ]] || return 0

	json_write_atomic \
		"${CONTEXT_MODE_LEDGER_DIR}/${stamp}-${SESSION_ID:-unknown}.json" \
		"${record}" 2>/dev/null || return 0
	return 0
}

# context_mode_read_stats [timeout_seconds] [watermark_json | --seq-only]
# Print the stats shim's JSON for this session's stores and agent, or nothing.
# --seq-only is init's read: the per-store counters (.seq) alone, without the
# counter query. Without either, every row counts as the run's. The budget
# defaults to 10 — the teardown path's value, and the same guard
# headroom_summary_print uses, since a wedged read must not hold a session's
# exit open. context_mode_summary_init passes a shorter budget of its own: see
# that function for why the two callers cannot share one number.
#
# The agent is upstream's id for RIOTBOX_AGENT: claude's rows are written as
# claude-code, opencode's and pi's under their own names.
#
# Silent on stdout on every failure, and on stderr for all but one: the shim is
# absent on an image built before this feature, the store does not exist until
# something writes it, and a teardown that warns about its own report is worse
# than one that says nothing. The exception is a store that exists and cannot
# be read (the shim exits 2: locked past its busy timeout, or corrupt). That
# store suppresses the report for every later run too, until someone removes
# it, so one stderr NOTE names it. init discards the note: its failure shows
# up again at exit.
context_mode_read_stats() {
	local budget="${1:-10}"
	[[ -x "${CONTEXT_MODE_STATS_BIN}" ]] || return 1
	command -v jq >/dev/null 2>&1 || return 1
	[[ -d "${CONTEXT_MODE_STORE_ROOT}/projects" ]] || return 1

	local agent="${RIOTBOX_AGENT:-claude}"
	[[ "${agent}" == "claude" ]] && agent="claude-code"

	local -a args=("${CONTEXT_MODE_STORE_ROOT}" "${agent}")
	[[ -n "${2:-}" ]] && args+=("$2")

	local raw err rc=0
	err="$(mktemp 2>/dev/null)" || err=/dev/null
	raw="$(timeout "${budget}" "${CONTEXT_MODE_STATS_BIN}" "${args[@]}" 2>"${err}")" || rc=$?
	if [[ "${rc}" -ne 0 ]]; then
		local why
		if [[ "${rc}" -eq 2 && -s "${err}" ]] && why="$(head -n 1 "${err}")"; then
			printf '  [context-mode] NOTE: exit report skipped, cannot read %s\n' "${why}" >&2
		fi
		[[ "${err}" == /dev/null ]] || rm -f "${err}"
		return 1
	fi
	[[ "${err}" == /dev/null ]] || rm -f "${err}"
	# The naive `jq -ce 'type == "object"'` looks equivalent but is not: -e's
	# exit status reflects the LAST output value, so it would exit 0 having
	# printed the boolean `true` — the string "true", not the counters — and
	# the baseline this function feeds would become that string. Print the
	# object itself when it validates, nothing otherwise, so a caller that
	# captures stdout gets the counters or gets silence, never a decoy.
	jq -ce 'if type == "object" then . else empty end' <<<"${raw}" 2>/dev/null
}

# context_mode_summary_init
# Take the watermark before the agent runs: each store's AUTOINCREMENT counter,
# as the JSON map _CONTEXT_MODE_SUMMARY_START. No-op unless the session is
# wired, which context_mode_setup decides two ways: for an agent that has a
# context_mode_wire verb, that the verb reported success; for one that does not —
# claude, which reaches Context Mode through the plugin container/plugin-setup.sh
# registers — that context_mode_plugin_installed found one registered, enabled
# and present on disk. An unwired session has nothing to measure, and taking a
# baseline anyway would let a later toggle change print a report for a run that
# never had the feature.
#
# Reads with a 3-second budget, not the teardown's 10: this call sits in front
# of the agent, on the critical path to a usable session, while
# context_mode_summary_print's read sits behind it with nothing waiting on it.
# The stores are shared with every concurrent run of this project set, so a
# store another process holds locked is a real way to stall this read; the
# shim gives each store a one-second busy timeout.
#
# A failed read is NOT the same baseline as a store that never existed, and
# collapsing the two used to be the bug here: an empty watermark makes every
# row this run's, which is correct when no store existed yet but wrong —
# reporting a stall as a zero baseline — when a lock or a corrupt file is what
# stopped the read. The two are told apart by whether a context.db already
# exists: none means context-mode has never written here, so the empty
# watermark is honest. One or more means a real baseline exists and could not
# be read, so _CONTEXT_MODE_SUMMARY_BASELINE_UNKNOWN is set for
# context_mode_summary_print to pass on to the renderer, which prints the store
# total on exit without a "this run" claim it cannot back up.
context_mode_summary_init() {
	[[ "${_CONTEXT_MODE_WIRED:-0}" = "1" ]] || return 0
	_CONTEXT_MODE_SUMMARY_STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)"
	unset _CONTEXT_MODE_SUMMARY_BASELINE_UNKNOWN
	_CONTEXT_MODE_SUMMARY_START=""

	local start
	if start="$(context_mode_read_stats 3 --seq-only 2>/dev/null)"; then
		_CONTEXT_MODE_SUMMARY_START="$(jq -c '.seq | if type == "object" then . else empty end' <<<"${start}" 2>/dev/null)" || true
		[[ -n "${_CONTEXT_MODE_SUMMARY_START}" ]] && return 0
	fi

	# find exits 1 when the projects directory does not exist yet — the first
	# run's normal state, and the same answer as an empty one: no database.
	local existing
	existing="$(find "${CONTEXT_MODE_STORE_ROOT}/projects" -mindepth 2 -maxdepth 2 -name context.db -print -quit 2>/dev/null)" || existing=""
	[[ -n "${existing}" ]] && _CONTEXT_MODE_SUMMARY_BASELINE_UNKNOWN=1

	# Explicit: the common case is no context.db found, which leaves the `&&`
	# above at status 1. That must not become this function's own return status
	# — this file is sourced into shells whose options it does not control, and
	# a caller running `set -e` would abort on it. Every other exit here is
	# already 0 by construction (a no-op, or a successful read).
	return 0
}

# context_mode_summary_print
# Re-read the stores above the watermark and render. Never propagates failure
# and never affects the exit code: this runs in entrypoint.sh's teardown,
# after the agent's status has been captured and before it is returned.
context_mode_summary_print() {
	[[ "${_CONTEXT_MODE_WIRED:-0}" = "1" ]] || return 0

	# An empty watermark is a first run (no store existed at start): every row
	# is this run's. With baseline_unknown the run figures are read the same
	# way and then ignored — only the store total is reported.
	local after
	after="$(context_mode_read_stats 10 "${_CONTEXT_MODE_SUMMARY_START:-"{}"}")" || return 0
	[[ -n "${after}" ]] || return 0

	local baseline_unknown="false"
	[[ "${_CONTEXT_MODE_SUMMARY_BASELINE_UNKNOWN:-0}" = "1" ]] && baseline_unknown="true"

	local payload
	payload="$(jq -nc \
		--argjson after "${after}" \
		--argjson baseline_unknown "${baseline_unknown}" \
		'{after: $after, baseline_unknown: $baseline_unknown}' 2>/dev/null)" || return 0
	[[ -n "${payload}" ]] || return 0

	context_mode_render_stats <<<"${payload}" || true
	context_mode_ledger_append "${payload}" || true
}
