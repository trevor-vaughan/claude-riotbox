#!/usr/bin/env bash
set -euo pipefail
# Audit untrusted repo in read-only mode.
# Required env: CONTAINER_CMD, IMAGE_NAME, ROOT_DIR
# Arguments: prompt [projects...]

if [ $# -eq 0 ]; then
    cat >&2 <<EOF
Error: a prompt is required.

Usage:
  task audit -- "prompt" [project ...]
  claude-riotbox audit "prompt" [project ...]

A prompt describes what Claude should do. Projects default to the current
directory if not specified.

Examples:
  task audit -- "review this code for security issues"
  task audit -- "find SQL injection vulnerabilities" . ../shared-lib
  claude-riotbox audit "check authentication logic" .
EOF
    exit 1
fi

task_prompt="$1"
shift
projects="${*:-}"

export RIOTBOX_READONLY=1
export RIOTBOX_PROJECTS="${projects}"
exec "${ROOT_DIR}/.taskfiles/scripts/launch.sh" claude -p "${task_prompt}"
