#!/usr/bin/env bash
set -euo pipefail
# overlay-reject.sh — Discard overlay changes.
# Usage: overlay-reject.sh [--force] [project-path]
# Required env: ROOT_DIR

source "${ROOT_DIR}/scripts/overlay-resolve.sh"

FORCE=false
PROJECT_ARG=""
for arg in "$@"; do
    case "${arg}" in
        --force|-f) FORCE=true ;;
        *) PROJECT_ARG="${arg}" ;;
    esac
done

resolve_overlay "${PROJECT_ARG}"

if ! overlay_has_changes "${OVERLAY_DIR}"; then
    echo "No overlay changes to discard for ${OVERLAY_PROJECT_DIR}."
    exit 0
fi

echo "Discarding overlay changes for: ${OVERLAY_PROJECT_DIR}"

if [ "${FORCE}" != true ]; then
    read -rp "Discard all changes? This cannot be undone. [y/N] " confirm
    if [[ ! "${confirm}" =~ ^[Yy]$ ]]; then
        echo "Aborted."
        exit 0
    fi
fi

rm -rf "${OVERLAY_DIR}/upper" "${OVERLAY_DIR}/work"
mkdir -p "${OVERLAY_DIR}/upper" "${OVERLAY_DIR}/work"
echo "Overlay data discarded."
