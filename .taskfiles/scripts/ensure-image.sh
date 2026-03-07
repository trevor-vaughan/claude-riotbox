#!/usr/bin/env bash
set -euo pipefail
# Verify the container image exists before launching.
# Required env: CONTAINER_CMD, IMAGE_NAME
if [ -z "$(${CONTAINER_CMD} images -q "${IMAGE_NAME}" 2>/dev/null)" ] \
    && [ -z "$(${CONTAINER_CMD} images -q "localhost/${IMAGE_NAME}" 2>/dev/null)" ]; then
    echo "ERROR: Image '${IMAGE_NAME}' not found. Run 'task docker:build' first." >&2
    exit 1
fi
