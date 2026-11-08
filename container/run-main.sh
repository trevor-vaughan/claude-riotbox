#!/usr/bin/env bash
# run-main.sh — Run the session's main command under the PID-1 entrypoint.
#
# Sourced by entrypoint.sh. Provides:
#   run_main_command [cmd args...] — run the command (bash when none is
#                                    given), forward SIGTERM to it, and
#                                    return its exit status.
#
# The entrypoint cannot exec the command: it has to survive to run teardown
# (overlay summary, session-branch merge). A foreground child is no good
# either. The kernel drops every signal sent to PID 1 that has no handler
# installed, and bash installs none for SIGTERM, so `podman stop` would wait
# out its timeout and SIGKILL the agent, skipping teardown. Running the child
# in the background lets a SIGTERM trap fire during `wait`.
#
# A background child of a non-interactive shell differs from a foreground one
# in two ways, and both are undone here:
#   - its stdin defaults to /dev/null, so `<&0` hands it the terminal again;
#   - it ignores SIGINT and SIGQUIT, so the subshell resets them to default
#     before exec and Ctrl-C still reaches the agent.
# No job control runs in this shell, so the child stays in the terminal's
# foreground process group and gets Ctrl-C from the terminal directly. The
# entrypoint therefore swallows its own SIGINT instead of forwarding it: a
# second copy would read as a double Ctrl-C.

run_main_command() {
	if [[ $# -eq 0 ]]; then
		set -- bash
	fi
	(
		trap - INT QUIT
		exec "$@"
	) <&0 &
	_main_pid=$!
	trap 'kill -TERM "${_main_pid}" 2>/dev/null' TERM
	trap ':' INT

	# wait returns early (status > 128) whenever a trapped signal arrives.
	# Wait again until the child is gone; a child that has exited but not
	# been reaped still answers kill -0, so its real status is never lost.
	local rc
	while :; do
		wait "${_main_pid}"
		rc=$?
		kill -0 "${_main_pid}" 2>/dev/null || break
	done

	trap - TERM INT
	unset _main_pid
	return "${rc}"
}
