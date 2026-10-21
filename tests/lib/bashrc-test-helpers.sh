#!/usr/bin/env bash
# Helpers for suites that exercise the image's .bashrc block.
# Source this file at the top of each test script.
set -euo pipefail

# Write the Containerfile's .bashrc heredoc to the given file.
#
# Why: the cases run the real block rather than grepping it for variable
# names, so a typo or a quoting slip in the heredoc fails them.
extract_riotbox_bashrc() {
    local root="$1" out="$2"
    awk '/^RUN cat >> \/home\/llm\/\.bashrc <<.BASHRC.$/ { f = 1; next }
         /^BASHRC$/ { f = 0 }
         f' "${root}/Containerfile" > "${out}"
    if [ ! -s "${out}" ]; then
        echo "FAIL: no .bashrc heredoc found in ${root}/Containerfile" >&2
        return 1
    fi
}

# Feed stdin to an interactive bash that runs the image's .bashrc block,
# recording history to the given file.
#
# Why: history settings only take effect in interactive shells, and the
# property under test is what bash actually writes to HISTFILE. HOME is a
# scratch dir so the block's guarded `.` lines (nvm, cargo, rvm) find
# nothing of the caller's to source.
run_riotbox_shell() {
    local root="$1" histfile="$2"
    local sandbox rc
    sandbox="$(dirname "${histfile}")"
    rc="${sandbox}/bashrc"

    extract_riotbox_bashrc "${root}" "${rc}"
    env -i HOME="${sandbox}" PATH="/usr/bin:/bin" HISTFILE="${histfile}" \
        bash --noprofile --rcfile "${rc}" -i >/dev/null 2>&1
}

# Print the environment a shell has after sourcing the image's .bashrc block,
# starting from an empty one so nothing is inherited from the caller.
riotbox_shell_env() {
    local root="$1" sandbox="$2"
    extract_riotbox_bashrc "${root}" "${sandbox}/bashrc"
    # shellcheck disable=SC2016  # $1 belongs to the inner bash, not this one
    env -i HOME="${sandbox}" PATH="/usr/bin:/bin" \
        bash --noprofile --norc -c '. "$1" && env' _ "${sandbox}/bashrc"
}
