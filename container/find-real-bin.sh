#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# find-real-bin.sh — Locate the real binary for a CLI agent on PATH, skipping
# any riotbox wrapper directory.
#
# Sourceable helper. Reads $1 as the binary name; sets the bash variable
# REAL_BIN to the first matching binary that is NOT inside a path ending in
# `/.riotbox/bin`. If no such binary is found, REAL_BIN is left empty.
#
# Usage:
#   source ~/.riotbox/find-real-bin.sh claude
#   "${REAL_BIN}" plugin install foo
#
# Replaces find-real-claude.sh and find-real-opencode.sh with a single
# parameterized implementation.
# ─────────────────────────────────────────────────────────────────────────────

# shellcheck disable=SC2034  # REAL_BIN is consumed by the caller after sourcing.
REAL_BIN=""
_target="${1:?find-real-bin.sh requires a binary name argument}"
IFS=: read -ra _path_entries <<< "${PATH}"
for _dir in "${_path_entries[@]}"; do
    [[ "${_dir}" == */.riotbox/bin ]] && continue
    if [ -x "${_dir}/${_target}" ]; then
        REAL_BIN="${_dir}/${_target}"
        break
    fi
done
unset _path_entries _dir _target
