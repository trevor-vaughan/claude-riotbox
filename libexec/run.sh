#!/usr/bin/env bash
set -euo pipefail
# Run the selected agent with a task prompt, checkpointing all project repos
# first. Required env: CONTAINER_CMD, IMAGE_NAME, ROOT_DIR
# Arguments: prompt [projects...]

if [[ $# -eq 0 ]]; then
	cat >&2 <<EOF
Error: a prompt is required.

Usage:
  riotbox run "prompt" [project ...]

A prompt describes what the agent should do. Projects default to the
current directory if not specified. All project repos are checkpointed
before the agent runs so you can restore them if something goes wrong.

Examples:
  riotbox run "fix the failing tests"
  riotbox run "add error handling to the API" . ../shared-lib
  riotbox run "refactor the auth module" .
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
# shellcheck source=../agents/registry.sh disable=SC1091  # source path resolves only from libexec/; safe to skip follow
source "${ROOT_DIR}/agents/registry.sh"
agent="${RIOTBOX_AGENT:-claude}"
# shellcheck disable=SC2310  # if-condition handles non-zero; set -e suppression is intentional
if ! agent_is_registered "${agent}"; then
	echo "ERROR: unknown RIOTBOX_AGENT: '${agent}'" >&2
	# shellcheck disable=SC2154  # AGENT_REGISTRY is set by agents/registry.sh (sourced above)
	echo "       Registered agents: ${AGENT_REGISTRY[*]}" >&2
	exit 1
fi
# shellcheck disable=SC2312  # agent_call prints; mapfile captures its stdout deliberately
mapfile -d '' -t agent_argv < <(agent_call "${agent}" run_argv "${task_prompt}")

echo "Launching ${agent} in riotbox..."
echo "   Projects: ${PROJECT_SUMMARY}"
echo "   Task    : ${task_prompt}"
echo "   Workdir : /workspace"
echo "   Network : enabled (no host credentials mounted)"
echo ""

# Non-interactive runs should never prompt to create a git repo, even when a
# terminal is attached. Default to "warn and continue" for non-git project dirs
# (the historical behaviour); opt in with RIOTBOX_GIT_INIT=1 to auto-initialise.
# Must be set before checkpoint.sh, which performs the (otherwise interactive) check.
export RIOTBOX_GIT_INIT="${RIOTBOX_GIT_INIT:-0}"

# Checkpoint all project repos before launching.
"${ROOT_DIR}/libexec/checkpoint.sh"

# Non-interactive runs should never prompt for a session branch.
# Allow explicit override via SESSION_BRANCH=1 if the caller wants it.
export SESSION_BRANCH="${SESSION_BRANCH:-0}"

exec "${ROOT_DIR}/libexec/launch.sh" "${agent_argv[@]}"
