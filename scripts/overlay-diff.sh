#!/usr/bin/env bash
set -euo pipefail
# overlay-diff.sh — Show changes in overlay upper dir.
# Usage: overlay-diff.sh [project-path]
# Required env: ROOT_DIR

source "${ROOT_DIR}/scripts/overlay-resolve.sh"
resolve_overlay "${1:-}"

upper="${OVERLAY_DIR}/upper"
project="${OVERLAY_PROJECT_DIR}"

echo "Overlay diff for: ${project}"
echo ""

found=0
while IFS= read -r path; do
    rel="${path#"${upper}"/}"
    base="$(basename "${path}")"
    dir="$(dirname "${rel}")"

    if [[ "${base}" == ".wh..wh..opq" ]]; then
        found=$((found + 1))
        echo "D  ${dir}/  (directory replaced)"
    elif [[ "${base}" == .wh.* ]]; then
        found=$((found + 1))
        real_name="${base#.wh.}"
        echo "D  ${dir}/${real_name}"
    elif [ -f "${path}" ]; then
        found=$((found + 1))
        if [ -f "${project}/${rel}" ]; then
            echo "M  ${rel}"
            # Show diff if both are text files
            if file "${path}" | grep -q text && file "${project}/${rel}" | grep -q text; then
                diff -u "${project}/${rel}" "${path}" \
                    --label "a/${rel}" --label "b/${rel}" 2>/dev/null || true
            else
                echo "   (binary file)"
            fi
        else
            echo "A  ${rel}"
            if file "${path}" | grep -q text; then
                # Show the new file content as a unified diff against /dev/null
                diff -u /dev/null "${path}" --label /dev/null --label "b/${rel}" 2>/dev/null || true
            else
                echo "   (binary file)"
            fi
        fi
    fi
done < <(find "${upper}" -mindepth 1 -not -type d 2>/dev/null | sort)

if [ "${found}" -eq 0 ]; then
    echo "No changes."
fi
