#!/usr/bin/env bash
set -euo pipefail
# Run Claude with a task prompt, checkpointing all project repos first.
# Required env: CONTAINER_CMD, IMAGE_NAME, ROOT_DIR
# Arguments: prompt [projects...]

if [ $# -eq 0 ]; then
    cat >&2 <<EOF
Error: a prompt is required.

Usage:
  task run -- "prompt" [project ...]
  claude-riotbox run "prompt" [project ...]

A prompt describes what Claude should do. Projects default to the current
directory if not specified. All project repos are checkpointed before
Claude runs so you can restore them if something goes wrong.

Examples:
  task run -- "fix the failing tests"
  task run -- "add error handling to the API" . ../shared-lib
  claude-riotbox run "refactor the auth module" .
EOF
    exit 1
fi

task_prompt="$1"
shift
projects="${*:-}"

export RIOTBOX_PROJECTS="${projects}"

source "${ROOT_DIR}/scripts/mount-projects.sh"
resolve_projects "${RIOTBOX_PROJECTS}"

echo "Launching Claude Code in riotbox..."
echo "   Projects: ${PROJECT_SUMMARY}"
echo "   Task    : ${task_prompt}"
echo "   Workdir : /workspace"
echo "   Network : enabled (no host credentials mounted)"
echo ""

# Checkpoint all project repos before launching.
"${ROOT_DIR}/.taskfiles/scripts/checkpoint.sh"

# Non-interactive runs (-p) should never prompt for a session branch.
# Allow explicit override via SESSION_BRANCH=1 if the caller wants it.
export SESSION_BRANCH="${SESSION_BRANCH:-0}"
exec "${ROOT_DIR}/.taskfiles/scripts/launch.sh" claude -p "${task_prompt}"
