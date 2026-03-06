#!/usr/bin/env bash
# find-real-claude.sh — locate the npm-installed claude binary, skipping
# the .riotbox wrapper. Source this file, then use ${REAL_CLAUDE}.
#
# Usage:
#   source ~/.riotbox/find-real-claude.sh
#   "${REAL_CLAUDE}" plugin install foo

REAL_CLAUDE=""
IFS=: read -ra _path_entries <<< "${PATH}"
for _dir in "${_path_entries[@]}"; do
    [[ "${_dir}" == */.riotbox/bin ]] && continue
    if [ -x "${_dir}/claude" ]; then
        REAL_CLAUDE="${_dir}/claude"
        break
    fi
done
unset _path_entries _dir
