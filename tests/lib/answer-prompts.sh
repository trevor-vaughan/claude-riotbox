#!/usr/bin/env bash
# Drive an interactive command by answering its prompts as they appear, so a
# test does not depend on how many y/n questions the host state triggers.
# Prompts are not newline-terminated, so output is read one character at a time.
set -euo pipefail

# kill_tree <pid>
#   SIGKILL <pid> and all its descendants, children first. A plain TERM to a
#   shell blocked on a foreground child is deferred, leaving the child running.
kill_tree() {
	local child
	for child in $(pgrep -P "$1" || true); do
		kill_tree "${child}"
	done
	kill -KILL "$1" 2>/dev/null || true
}

# answer_prompts <core-answer> <command> [args...]
#   Runs <command> with stdout+stderr merged, echoes everything it prints, and
#   answers each prompt: a "[b/r] " prompt gets <core-answer>; any "[Y/n] " or
#   "[y/N] " prompt gets Enter (the default). Returns the command's exit code.
answer_prompts() {
	local core_answer="$1"
	shift
	local line="" ch rfd wfd pid rc=0
	local timeout="${ANSWER_PROMPTS_TIMEOUT:-60}"
	# A child that exited before reading its answer must not kill the caller.
	trap '' PIPE
	# coproc gives a bidirectional pipe; stderr is merged so prompts (stdout)
	# and ERROR lines (stderr) share one stream.
	coproc DRIVEN { "$@" 2>&1; }
	# bash unsets DRIVEN when the child exits; duplicate the fds so the read
	# loop sees a clean EOF instead of an unbound variable.
	# shellcheck disable=SC2154 # DRIVEN_PID is set by bash for the DRIVEN coproc
	pid="${DRIVEN_PID}"
	exec {rfd}<&"${DRIVEN[0]}" {wfd}>&"${DRIVEN[1]}"
	# Prompt markers are matched anywhere in the output, not only in prompts.
	while true; do
		rc=0
		IFS= read -r -N 1 -t "${timeout}" ch <&"${rfd}" || rc=$?
		if ((rc > 128)); then
			echo "answer_prompts: no output for ${timeout}s; killing $*" >&2
			kill_tree "${pid}"
			wait "${pid}" 2>/dev/null || true
			exec {rfd}<&- {wfd}>&-
			trap - PIPE
			return 124
		fi
		((rc == 0)) || break
		printf '%s' "${ch}"
		if [[ "${ch}" == $'\n' ]]; then
			line=""
			continue
		fi
		line+="${ch}"
		case "${line}" in
		*"[b/r] ") { printf '%s\n' "${core_answer}" >&"${wfd}"; } 2>/dev/null || true ;;
		*"[Y/n] " | *"[y/N] ") { printf '\n' >&"${wfd}"; } 2>/dev/null || true ;;
		*) ;;
		esac
	done
	exec {rfd}<&- {wfd}>&-
	rc=0
	wait "${pid}" || rc=$?
	trap - PIPE
	return "${rc}"
}
