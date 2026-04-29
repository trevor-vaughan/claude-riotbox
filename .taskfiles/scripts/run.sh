#!/usr/bin/env bash
set -euo pipefail
# Run the selected agent with a task prompt, checkpointing all project repos
# first. Required env: CONTAINER_CMD, IMAGE_NAME, ROOT_DIR
# Arguments: prompt [projects...]

if [ $# -eq 0 ]; then
    cat >&2 <<EOF
Error: a prompt is required.

Usage:
  task run -- "prompt" [project ...]
  claude-riotbox run "prompt" [project ...]

A prompt describes what the agent should do. Projects default to the
current directory if not specified. All project repos are checkpointed
before the agent runs so you can restore them if something goes wrong.

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

# Resolve the agent's argv via the registry. The previous implementation
# had a per-agent case statement here; with the registry every agent
# advertises its own argv shape and adding one is a manifest edit.
# shellcheck source=../../agents/registry.sh
source "${ROOT_DIR}/agents/registry.sh"
agent="${RIOTBOX_AGENT:-claude}"
if ! agent_is_registered "${agent}"; then
    echo "ERROR: unknown RIOTBOX_AGENT: '${agent}'" >&2
    echo "       Registered agents: ${AGENT_REGISTRY[*]}" >&2
    exit 1
fi
mapfile -d '' -t agent_argv < <(agent_call "${agent}" run_argv "${task_prompt}")

echo "Launching ${agent} in riotbox..."
echo "   Projects: ${PROJECT_SUMMARY}"
echo "   Task    : ${task_prompt}"
echo "   Workdir : /workspace"
echo "   Network : enabled (no host credentials mounted)"
echo ""

# Checkpoint all project repos before launching.
"${ROOT_DIR}/.taskfiles/scripts/checkpoint.sh"

# Non-interactive runs should never prompt for a session branch.
# Allow explicit override via SESSION_BRANCH=1 if the caller wants it.
export SESSION_BRANCH="${SESSION_BRANCH:-0}"

exec "${ROOT_DIR}/.taskfiles/scripts/launch.sh" "${agent_argv[@]}"
