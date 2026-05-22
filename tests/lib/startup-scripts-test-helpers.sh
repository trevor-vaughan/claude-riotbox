#!/usr/bin/env bash
# Shared helpers for startup-scripts Venom tests.
# Source this file at the top of each test script.
set -euo pipefail

# Set up a fake HOME with an empty startup_scripts directory.
# Sets: TEST_DIR, STARTUP_DIR, MARKER_DIR
# Exports: HOME
setup_startup_scripts_test() {
    TEST_DIR="$(mktemp -d)"
    export HOME="${TEST_DIR}/home"
    # shellcheck disable=SC2034
    STARTUP_DIR="${HOME}/.config/claude-riotbox/startup_scripts"
    # shellcheck disable=SC2034
    MARKER_DIR="${TEST_DIR}/markers"
    mkdir -p "${STARTUP_DIR}" "${MARKER_DIR}"
}

# Write an executable script that creates a marker file. Args:
#   $1 — script basename (e.g. "10-touch.sh")
#   $2 — marker filename relative to ${MARKER_DIR}
write_marker_script() {
    local name="$1"
    local marker="$2"
    cat > "${STARTUP_DIR}/${name}" <<EOF
#!/usr/bin/env bash
touch "${MARKER_DIR}/${marker}"
EOF
    chmod +x "${STARTUP_DIR}/${name}"
}

# Write an executable script that appends a literal to a shared file.
# Args: $1 — basename; $2 — literal; $3 — marker filename
write_append_script() {
    local name="$1"
    local literal="$2"
    local marker="$3"
    cat > "${STARTUP_DIR}/${name}" <<EOF
#!/usr/bin/env bash
printf '%s' '${literal}' >> "${MARKER_DIR}/${marker}"
EOF
    chmod +x "${STARTUP_DIR}/${name}"
}

# Write a script WITHOUT the executable bit.
write_non_executable_script() {
    local name="$1"
    local marker="$2"
    cat > "${STARTUP_DIR}/${name}" <<EOF
#!/usr/bin/env bash
touch "${MARKER_DIR}/${marker}"
EOF
    # No chmod +x — deliberately.
}

# Write an executable script that exits non-zero.
write_failing_script() {
    local name="$1"
    local rc="${2:-1}"
    cat > "${STARTUP_DIR}/${name}" <<EOF
#!/usr/bin/env bash
exit ${rc}
EOF
    chmod +x "${STARTUP_DIR}/${name}"
}
