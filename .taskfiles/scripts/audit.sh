#!/usr/bin/env bash
set -euo pipefail
# Audit untrusted repo in read-only mode.
# Required env: CONTAINER_CMD, IMAGE_NAME, ROOT_DIR
# Arguments: task [projects...]

task_prompt="${1:?Usage: audit.sh <task> [projects...]}"
shift
projects="${*:-}"

export RIOTBOX_READONLY=1
export RIOTBOX_PROJECTS="${projects}"
exec "${ROOT_DIR}/.taskfiles/scripts/launch.sh" claude -p "${task_prompt}"
