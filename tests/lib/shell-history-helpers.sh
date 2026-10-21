#!/usr/bin/env bash
# Helpers for tests/shell-history.venom.yml.
# Source this file at the top of each test script.
set -euo pipefail

# Feed stdin to an interactive bash that runs the image's .bashrc block,
# recording history to the given file.
#
# Why: history settings only take effect in interactive shells, and the
# property under test is what bash actually writes to HISTFILE — so the case
# runs the real heredoc from the Containerfile rather than grepping it for a
# variable name. HOME is a scratch dir so the block's guarded `.` lines (nvm,
# cargo, rvm) find nothing of the caller's to source.
run_riotbox_shell() {
    local root="$1" histfile="$2"
    local sandbox rc
    sandbox="$(dirname "${histfile}")"
    rc="${sandbox}/bashrc"

    awk '/^RUN cat >> \/home\/llm\/\.bashrc <<.BASHRC.$/ { f = 1; next }
         /^BASHRC$/ { f = 0 }
         f' "${root}/Containerfile" > "${rc}"
    if [ ! -s "${rc}" ]; then
        echo "FAIL: no .bashrc heredoc found in ${root}/Containerfile" >&2
        return 1
    fi

    env -i HOME="${sandbox}" PATH="/usr/bin:/bin" HISTFILE="${histfile}" \
        bash --noprofile --rcfile "${rc}" -i >/dev/null 2>&1
}
