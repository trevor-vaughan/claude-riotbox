#!/usr/bin/env bash
# Installs the claude-riotbox wrapper script to ~/bin (or a custom directory).
# Usage: ./install.sh [target-dir]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_DIR="${1:-${HOME}/bin}"

mkdir -p "${TARGET_DIR}"

cat > "${TARGET_DIR}/claude-riotbox" <<EOF
#!/usr/bin/env bash
JUSTFILE="${SCRIPT_DIR}/justfile"

# If ALL arguments are existing paths, default to "shell <paths...>"
if [ \$# -ge 1 ]; then
    all_paths=true
    for arg in "\$@"; do
        if [ ! -e "\$arg" ]; then
            all_paths=false
            break
        fi
    done
    if [ "\$all_paths" = true ]; then
        exec just -f "\${JUSTFILE}" -- shell "\$@"
    fi
fi

exec just -f "\${JUSTFILE}" -- "\$@"
EOF

chmod +x "${TARGET_DIR}/claude-riotbox"
echo "Installed: ${TARGET_DIR}/claude-riotbox"

if ! echo "${PATH}" | tr ':' '\n' | grep -qx "${TARGET_DIR}"; then
    echo "Note: ${TARGET_DIR} is not in your PATH. Add it:"
    echo "  export PATH=\"${TARGET_DIR}:\${PATH}\""
fi
