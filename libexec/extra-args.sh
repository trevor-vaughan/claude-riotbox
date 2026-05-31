#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# extra-args.sh — confirmation gate for RIOTBOX_EXTRA_ARGS.
#
# Sourced (not executed) by launch.sh before the container-engine run command
# is assembled. RIOTBOX_EXTRA_ARGS is a relief valve: raw flags inserted into the
# `podman`/`docker run` command, after all other RiotBox-managed flags (just
# before `-w` and the image name). Because raw
# passthrough bypasses RiotBox's curated safety defaults (and can weaken or
# disable container isolation), the launcher confirms before applying it.
#
# Provides:
#   extra_args_gate — returns 0 to proceed, non-zero to abort the launch.
#                     * unset/empty RIOTBOX_EXTRA_ARGS: silent no-op (0)
#                     * RIOTBOX_EXTRA_ARGS_ACK=1: proceed, no prompt (0)
#                     * no TTY and no ack: abort (non-zero) — fail-safe so CI
#                       never silently applies isolation-weakening flags
#                     * TTY: [y/N] prompt (default No); "y" proceeds (0),
#                       anything else aborts (non-zero)
#
# Why a gate instead of a content denylist: any raw passthrough bypasses the
# defaults, so the speed-bump fires on presence, not on a guess about which
# flags are "dangerous" (a denylist is incomplete and falsely implies safety).
# ─────────────────────────────────────────────────────────────────────────────

extra_args_gate() {
	[[ -n "${RIOTBOX_EXTRA_ARGS:-}" ]] || return 0

	# A bare `--` ends option parsing for the engine, which would turn the
	# launcher's own trailing `-w`, image name, and command into positionals.
	# Reject it (independently of the ack/TTY gate) to protect command assembly.
	local _arg
	# shellcheck disable=SC2086  # intentional word-split to inspect each token
	for _arg in ${RIOTBOX_EXTRA_ARGS}; do
		if [[ "${_arg}" = "--" ]]; then
			echo "ERROR: RIOTBOX_EXTRA_ARGS contains a bare '--', which would end the" >&2
			echo "       engine's option parsing and corrupt the run command. Remove it;" >&2
			echo "       put any '--' terminator in the container command, not here." >&2
			return 1
		fi
	done

	if [[ "${RIOTBOX_EXTRA_ARGS_ACK:-}" = "1" ]]; then
		echo "Notice: RIOTBOX_EXTRA_ARGS is set (acknowledged): ${RIOTBOX_EXTRA_ARGS}" >&2
		return 0
	fi

	if [[ ! -t 0 ]]; then
		cat >&2 <<EOF
ERROR: RIOTBOX_EXTRA_ARGS is set but stdin is not a TTY, so the
       confirmation prompt cannot be shown. These raw flags bypass RiotBox
       safety defaults:
         ${RIOTBOX_EXTRA_ARGS}
       To apply them non-interactively, set RIOTBOX_EXTRA_ARGS_ACK=1.
EOF
		return 1
	fi

	echo "" >&2
	echo "WARNING: RIOTBOX_EXTRA_ARGS bypasses RiotBox safety defaults and passes" >&2
	echo "         these raw flags directly to the container engine:" >&2
	echo "           ${RIOTBOX_EXTRA_ARGS}" >&2
	printf "Proceed? [y/N] " >&2
	local answer
	read -r answer
	case "${answer}" in
	[Yy] | [Yy][Ee][Ss])
		return 0
		;;
	*)
		echo "Aborted. Unset RIOTBOX_EXTRA_ARGS or set RIOTBOX_EXTRA_ARGS_ACK=1 to skip this prompt." >&2
		return 1
		;;
	esac
}
