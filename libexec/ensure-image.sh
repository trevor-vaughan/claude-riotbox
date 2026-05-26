#!/usr/bin/env bash
set -euo pipefail
# Verify the container image exists before launching.
# Required env: CONTAINER_CMD, IMAGE_NAME
# shellcheck disable=SC2154  # CONTAINER_CMD and IMAGE_NAME are required env — set by the caller
_img_check="$("${CONTAINER_CMD}" images -q "${IMAGE_NAME}" 2>/dev/null)"
_img_check_local="$("${CONTAINER_CMD}" images -q "localhost/${IMAGE_NAME}" 2>/dev/null)"
if [[ -z "${_img_check}" ]] && [[ -z "${_img_check_local}" ]]; then
	echo "ERROR: Image '${IMAGE_NAME}' not found. Run 'riotbox build' first." >&2
	exit 1
fi
