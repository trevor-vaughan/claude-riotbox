#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# agents/claude/manifest.sh — Manifest for the Claude Code CLI agent.
#
# Sourced by agents/registry.sh from both host and container contexts.
# Co-located with claude-specific helpers under agents/claude/:
#   manifest.sh       — this file (the contract functions)
#   setup.sh          — container-side runtime setup
#   sync-settings.sh  — host-side config sync
#
# See docs/dev/agent-contract.md for the full contract.
# ─────────────────────────────────────────────────────────────────────────────

# Resolve this manifest's own directory so sibling files load by absolute path.
# BASH_SOURCE works regardless of caller cwd or how the registry was sourced.
_AGENT_CLAUDE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Context Mode verbs (optional contract — see docs/dev/agent-contract.md).
# shellcheck source=./context-mode.sh
source "${_AGENT_CLAUDE_DIR}/context-mode.sh"

# Removal of the GitHub/GitLab MCP entries earlier images wired (issue #19).
# shellcheck source=./forge-mcp.sh
source "${_AGENT_CLAUDE_DIR}/forge-mcp.sh"

# git-ai verbs (optional contract — see docs/dev/agent-contract.md).
# shellcheck source=./git-ai.sh
source "${_AGENT_CLAUDE_DIR}/git-ai.sh"

# Name of the binary on PATH inside the container.
agent_claude_real_binary() {
	printf 'claude\n'
}

# Argv for non-interactive "run with prompt" mode. Claude Code uses
# -p/--prompt to enter scripted mode.
#
# Argv tokens are emitted NUL-terminated (`printf '%s\0'`) so multi-line
# prompts survive the round-trip through `mapfile -d ''`. NUL is safe —
# argv tokens cannot contain NUL bytes (execve invariant). See
# docs/dev/agent-contract.md for the full contract.
agent_claude_run_argv() {
	local prompt="${1:?run_argv requires a prompt argument}"
	printf '%s\0' claude -p "${prompt}"
}

# Argv for "continue last session". --continue is a top-level Claude flag.
agent_claude_resume_argv() {
	printf '%s\0' claude --continue
}

# Argv for read-only audit mode. Same shape as run.
agent_claude_audit_argv() {
	local prompt="${1:?audit_argv requires a prompt argument}"
	printf '%s\0' claude -p "${prompt}"
}

# Wrapper injection rules. Claude takes --dangerously-skip-permissions as
# a root-level flag and is non-interactive when -p / --prompt is present.
# See docs/dev/agent-contract.md for the full contract.
agent_claude_wrapper_inject() {
	local set_ci=0
	local arg
	for arg in "$@"; do
		if [[ "${arg}" = "-p" ]] || [[ "${arg}" = "--prompt" ]]; then
			set_ci=1
			break
		fi
	done
	printf '%s\0' --dangerously-skip-permissions
	for arg in "$@"; do
		printf '%s\0' "${arg}"
	done
	# Env hints go to the wrapper-allocated sidecar file (one KEY=VAL per
	# line). The wrapper reads + exports it after we return. Stderr is
	# reserved for user-facing diagnostics.
	if [[ "${set_ci}" = "1" ]] && [[ -n "${RIOTBOX_INJECT_ENV_FILE:-}" ]]; then
		printf 'CI=true\n' >>"${RIOTBOX_INJECT_ENV_FILE}"
	fi
}

# Optional verb: argv for headroom interposition (RIOTBOX_HEADROOM=1).
# Helper-shaped, like opencode's: headroom-exec.sh starts the proxy, then
# runs claude with the routing env pointing at it. `headroom wrap claude`
# is not used because it writes .claude/settings.local.json, lock and
# marker files and a SessionStart hook into the CWD, the caller's checkout;
# the helper's header lists what it keeps from wrap and what it drops.
# See docs/dev/agent-contract.md.
agent_claude_headroom_argv() {
	printf '%s\0' "${_AGENT_CLAUDE_DIR}/headroom-exec.sh"
	local arg
	for arg in "$@"; do
		printf '%s\0' "${arg}"
	done
}

# Container-side runtime setup. setup.sh is a no-op in the common case
# (managed policy /etc/claude-code/CLAUDE.md is rendered at build time);
# it only does work when RIOTBOX_PROMPT overrides or the build-time render
# is missing. The forge MCP strip then takes back any GitHub/GitLab server
# entry an earlier image left in the persisted .claude.json. In egress mode
# the managed policy also gets the egress prompt section
# (scripts/lib/egress-prompt.sh).
agent_claude_container_setup() {
	# shellcheck source=./setup.sh
	source "${_AGENT_CLAUDE_DIR}/setup.sh"
	claude_setup
	# From scripts/lib/egress-prompt.sh, which container/entrypoint.sh sources.
	egress_prompt_apply "${RIOTBOX_MANAGED_POLICY_DIR:-/etc/claude-code}/CLAUDE.md"
	claude_strip_forge_mcp_entries
}

# Host-side config sync. sync-settings.sh handles credentials, config,
# skills, statusline-command.sh, host plugins, etc. Prints volume flags
# on stdout, notices on stderr. Claude writes into the session dir ($1)
# because that dir IS its ~/.claude mount root (copies are staged and renamed
# in; see sync-settings.sh); the state dir ($2) is unused.
agent_claude_host_sync() {
	local session_dir="${1:?host_sync requires a session_dir argument}"
	"${_AGENT_CLAUDE_DIR}/sync-settings.sh" \
		"${HOME}/.claude" \
		"${session_dir}"
}

# Print the env var names this agent reads (one per line). The launcher
# unions these across all registered agents to build the passthrough set.
# Names only — no values; the container runtime copies values from the
# caller's environment via `-e <name>` (see passthrough-vars.sh).
#
# Claude Code reads:
#   * ANTHROPIC_API_KEY / ANTHROPIC_AUTH_TOKEN — direct API auth
#   * ANTHROPIC_BASE_URL — proxy/gateway routing
#   * ANTHROPIC_VERTEX_* / CLAUDE_CODE_USE_VERTEX / VERTEX_LOCATION /
#     CLOUD_ML_REGION — Google Vertex AI provider routing
#   * ANTHROPIC_BEDROCK_BASE_URL / CLAUDE_CODE_USE_BEDROCK / AWS_REGION /
#     AWS_PROFILE — AWS Bedrock provider routing (AWS_PROFILE selects a
#     credential set; access keys are NOT included by design — see
#     THREAT_MODEL.md)
agent_claude_env_vars() {
	cat <<'EOF'
ANTHROPIC_API_KEY
ANTHROPIC_AUTH_TOKEN
ANTHROPIC_BASE_URL
ANTHROPIC_VERTEX_PROJECT_ID
ANTHROPIC_VERTEX_BASE_URL
ANTHROPIC_BEDROCK_BASE_URL
CLAUDE_CODE_USE_VERTEX
CLAUDE_CODE_USE_BEDROCK
VERTEX_LOCATION
CLOUD_ML_REGION
AWS_REGION
AWS_PROFILE
EOF
}

# agent_claude_egress_hosts — the hosts Claude Code must reach through the
# RIOTBOX_EGRESS=1 proxy, one egress.conf entry per line
# (docs/dev/agent-contract.md):
#   api.anthropic.com      the Messages API
#   claude.ai              subscription (OAuth) login and account calls
#   platform.claude.com    OAuth token exchange and refresh
#   console.anthropic.com  the older OAuth token endpoint
# Vertex and Bedrock hosts are not listed: a user routing through them adds
# them to egress.conf.
agent_claude_egress_hosts() {
	cat <<'EOF'
api.anthropic.com
claude.ai
platform.claude.com
console.anthropic.com
EOF
}
