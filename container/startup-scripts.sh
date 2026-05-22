#!/usr/bin/env bash
# startup-scripts.sh — User-defined post-setup scripts inside the container.
#
# Sourced by entrypoint.sh. Provides:
#   startup_scripts_run — run every executable *.sh under
#                         ~/.config/claude-riotbox/startup_scripts/ in
#                         lexicographic filename order. Failures warn and
#                         continue; the session is still usable.
#
# Convention follows run-parts(8) / /etc/profile.d:
#   - Files must have the executable bit set to run; non-executable files
#     are skipped with a notice on stderr.
#   - Files are executed directly (the script's shebang chooses the
#     interpreter), not sourced — so they cannot mutate the entrypoint's
#     environment, and they may use any interpreter.
#   - Files are sorted lexicographically by basename; users can prefix
#     with 10-, 20-, etc. to control ordering.

startup_scripts_run() {
    local dir="${HOME}/.config/claude-riotbox/startup_scripts"
    [ -d "${dir}" ] || return 0

    local script
    while IFS= read -r -d '' script; do
        if [ ! -x "${script}" ]; then
            echo "  [startup_scripts] Skipping ${script##*/}: not executable" >&2
            continue
        fi
        echo "  [startup_scripts] Running ${script##*/}..."
        local rc=0
        "${script}" || rc=$?
        if [ "${rc}" -ne 0 ]; then
            echo "  [startup_scripts] WARN: ${script##*/} exited with status ${rc}" >&2
        fi
    done < <(find "${dir}" -maxdepth 1 -name '*.sh' -print0 | sort -z)
    return 0
}
