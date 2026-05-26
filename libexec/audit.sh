#!/usr/bin/env bash
set -euo pipefail
# Audit untrusted repo in read-only mode.
# Required env: CONTAINER_CMD, IMAGE_NAME, ROOT_DIR
# Arguments: prompt [projects...]

if [[ $# -eq 0 ]]; then
	cat >&2 <<EOF
Error: a prompt is required.

Usage:
  riotbox audit "prompt" [project ...]

A prompt describes what the agent should do. Projects default to the
current directory if not specified.

Examples:
  riotbox audit "review this code for security issues"
  riotbox audit "find SQL injection vulnerabilities" . ../shared-lib
  riotbox audit "check authentication logic" .
EOF
	exit 1
fi

task_prompt="$1"
shift
projects="${*:-}"

export RIOTBOX_READONLY=1
export RIOTBOX_PROJECTS="${projects}"

# shellcheck source=../agents/registry.sh disable=SC1091  # source path resolves only from libexec/; safe to skip follow
# shellcheck disable=SC2154  # ROOT_DIR is exported by the caller (bin/riotbox)
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
mapfile -d '' -t agent_argv < <(agent_call "${agent}" audit_argv "${task_prompt}")
exec "${ROOT_DIR}/libexec/launch.sh" "${agent_argv[@]}"
