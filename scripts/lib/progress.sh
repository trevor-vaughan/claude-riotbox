#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# scripts/lib/progress.sh — elapsed-time reporting for slow startup steps.
#
# Sourced by container/entrypoint.sh, ahead of the setup scripts that call it.
#
# A first container start against a fresh session directory can sit for minutes
# inside one `claude plugin install`. The step announces itself and then goes
# quiet, and the user has no signal distinguishing "working" from "wedged".
# This prints the same announcement and then keeps it current.
#
# Public:
#   with_progress <label> <command> [args...]
#     Run <command>, report elapsed time, and return <command>'s exit status
#     unchanged. <label> is fully-formed prefix text with NO trailing ellipsis
#     (e.g. "  [plugins] Installing superpowers") — the caller owns the
#     "  [subsystem] " convention the other startup messages use, and this
#     function owns everything from the "..." onward.
#
#     Output of <command> is captured, not passed through: discarded on
#     success, replayed to stderr on failure.
#
#     Never aborts the caller. Safe to call from a shell running under set -e.
# ─────────────────────────────────────────────────────────────────────────────

# Seconds a step must run before the first elapsed-time tick is drawn. Steps
# that finish faster render exactly the two lines they did before this file
# existed, so the common fast path is visually unchanged.
RIOTBOX_PROGRESS_GRACE=2

with_progress() {
	local label="${1:?with_progress: label required}"
	shift
	if (($# == 0)); then
		echo "with_progress: command required" >&2
		return 2
	fi

	# Kept for the failure banner: "$@" is consumed by the run below, and a
	# reader looking at a replayed error needs to know which command produced
	# it — the label names the step, not the command line.
	local cmd_str="$*"

	local tmp
	if ! tmp="$(mktemp)"; then
		# Degrade rather than fail. A step whose output cannot be captured is
		# still a step this session needs run, and a full disk must not turn a
		# progress indicator into a broken startup. Output passes through.
		printf '%s...\n' "${label}"
		local passthrough_status=0
		"$@" || passthrough_status=$?
		return "${passthrough_status}"
	fi

	# The ticker is a TTY-only affair. Off a TTY there is nothing to redraw
	# over, so the poll loop is skipped entirely rather than run with its
	# output discarded.
	#
	# `((...))` is written as an `if` throughout rather than `((...)) && cmd`.
	# Not because the `&&` form is unsafe where it sits — bash exempts a
	# failure in a non-final position of an `&&` list from `set -e` — but
	# because the exemption is positional, and the day such a line becomes the
	# last statement of this function it silently starts returning 1 for a step
	# that succeeded, aborting a `set -e` caller mid-startup. The `if` form
	# carries no such dependency on where it appears.
	#
	# The status guards on `wait` below are the load-bearing ones, and are
	# pinned by the exit-status and failure-replay cases in
	# tests/startup-progress.venom.yml — removing either `|| status=$?` fails
	# both.
	local tty=0
	if [[ -t 1 ]]; then
		tty=1
	fi

	if ((tty)); then
		printf '%s...' "${label}"
	else
		printf '%s...\n' "${label}"
	fi

	# Microseconds, not ${SECONDS}. SECONDS counts whole seconds from shell
	# start, so a step taking 20 ms reports "done (1s)" or "done (0s)"
	# depending only on where the second boundary happened to fall — wrong, and
	# nondeterministically wrong. EPOCHREALTIME is "<seconds>.<microseconds>";
	# dropping the separator yields an integer count directly. The separator is
	# whichever character LC_NUMERIC dictates, so both are matched — a comma
	# locale would otherwise silently multiply every duration by a million.
	local start_us=${EPOCHREALTIME/[.,]/}
	"$@" >"${tmp}" 2>&1 &
	local pid=$!

	if ((tty)); then
		# Polled at a fraction of a second but redrawn at most once per whole
		# second. Polling at 1 s would make every wrapped step up to a second
		# slower to report completion, which on a startup path with a dozen
		# fast steps is a real cost — and an ironic one for a feature whose
		# purpose is to make waiting feel shorter.
		#
		# Bare \r, no erase sequence and no padding. Correct ONLY because the
		# rendered line grows monotonically: constant label, non-decreasing
		# counter, and both terminal states ("done (14s)", "failed (3s)") are
		# longer than the tick they overwrite. A change that makes a final
		# state shorter than the last tick must add erasure at the same time.
		local elapsed last_drawn=-1
		while kill -0 "${pid}" 2>/dev/null; do
			sleep 0.25
			elapsed=$(((${EPOCHREALTIME/[.,]/} - start_us) / 1000000))
			if ((elapsed >= RIOTBOX_PROGRESS_GRACE && elapsed != last_drawn)); then
				printf '\r%s... %ds' "${label}" "${elapsed}"
				last_drawn=${elapsed}
			fi
		done
	fi

	local status=0
	wait "${pid}" || status=$?
	local total=$(((${EPOCHREALTIME/[.,]/} - start_us) / 1000000))

	# Return to column 0 so the final state overwrites the last tick. Harmless
	# when no tick was drawn — the cursor is already mid-line after the label.
	if ((tty)); then
		printf '\r'
	fi

	if ((status == 0)); then
		printf '%s... done (%ds)\n' "${label}" "${total}"
		rm -f "${tmp}"
		return 0
	fi

	printf '%s... failed (%ds)\n' "${label}" "${total}"
	# The subsystem tag, reused from the label, so a replayed block stays
	# visually attached to the step that produced it. A label with no bracket
	# yields no tag rather than a wrong one.
	local tag=""
	if [[ "${label}" == *"]"* ]]; then
		tag="${label%%]*}] "
	fi
	printf "%s--- output from '%s' ---\n" "${tag}" "${cmd_str}" >&2
	cat "${tmp}" >&2
	printf '%s--- end of output ---\n' "${tag}" >&2
	rm -f "${tmp}"
	return "${status}"
}
