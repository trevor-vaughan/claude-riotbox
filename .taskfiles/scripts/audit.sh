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

A prompt describes what the agent should do. Projects default to the
current directory if not specified.

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

# shellcheck source=../../agents/registry.sh
source "${ROOT_DIR}/agents/registry.sh"
agent="${RIOTBOX_AGENT:-claude}"
if ! agent_is_registered "${agent}"; then
    echo "ERROR: unknown RIOTBOX_AGENT: '${agent}'" >&2
    echo "       Registered agents: ${AGENT_REGISTRY[*]}" >&2
    exit 1
fi
mapfile -d '' -t agent_argv < <(agent_call "${agent}" audit_argv "${task_prompt}")
exec "${ROOT_DIR}/.taskfiles/scripts/launch.sh" "${agent_argv[@]}"
