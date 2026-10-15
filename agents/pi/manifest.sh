#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# agents/pi/manifest.sh — Manifest for the Pi coding agent (https://pi.dev).
#
# Sourced by agents/registry.sh from both host and container contexts.
# Co-located with Pi-specific helpers under agents/pi/:
#   manifest.sh       — this file (the contract functions)
#   setup.sh          — container-side runtime setup
#   sync-settings.sh  — host-side config sync
#   context-mode.sh   — Context Mode verbs
#   git-ai.sh         — git-ai verbs
#
# See docs/dev/agent-contract.md for the full contract and
# docs/dev/decisions/pi-support.md for why Pi is wired this way.
# ─────────────────────────────────────────────────────────────────────────────

# Resolve this manifest's own directory so sibling files load by absolute path.
_AGENT_PI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Context Mode verbs (optional contract — see docs/dev/agent-contract.md).
# shellcheck source=./context-mode.sh
source "${_AGENT_PI_DIR}/context-mode.sh"

# git-ai verbs (optional contract — see docs/dev/agent-contract.md).
# shellcheck source=./git-ai.sh
source "${_AGENT_PI_DIR}/git-ai.sh"

# Name of the binary on PATH inside the container: the shim the image build
# generates at ~/.local/bin/pi.
agent_pi_real_binary() {
	printf 'pi\n'
}

# Argv for non-interactive "run with prompt" mode. `--` ends option parsing,
# so a prompt that starts with `-` is read as the prompt rather than a flag.
#
# Argv tokens are emitted NUL-terminated (`printf '%s\0'`) so multi-line
# prompts survive the round-trip through `mapfile -d ''`.
agent_pi_run_argv() {
	local prompt="${1:?run_argv requires a prompt argument}"
	printf '%s\0' pi -p -- "${prompt}"
}

# Argv for "continue last session". Pi continues the most recent session for
# the working directory.
agent_pi_resume_argv() {
	printf '%s\0' pi -c
}

# Argv for read-only audit mode. Same shape as run — the read-only project
# mount is a launch-time concern, not an agent flag.
agent_pi_audit_argv() {
	local prompt="${1:?audit_argv requires a prompt argument}"
	printf '%s\0' pi -p -- "${prompt}"
}

# Wrapper injection rules. Pi has no per-tool approval prompts to switch off
# and project trust comes from settings.json (agents/pi/setup.sh), so argv
# passes through unchanged. The only hint is CI=true for headless runs —
# print mode (-p/--print) and the json/rpc output modes. CI=true is for parity
# with opencode and for the tools Pi spawns; Pi itself barely reads CI. Pi only
# accepts `--mode json|rpc` as two tokens (`--mode=rpc` is not a mode switch),
# so only that form counts. Scanning stops at `--`, so a prompt that happens
# to read "-p" is not mistaken for the flag.
agent_pi_wrapper_inject() {
	local headless=0
	local prev=""
	local arg
	for arg in "$@"; do
		[[ "${arg}" = "--" ]] && break
		case "${arg}" in
		-p | --print) headless=1 ;;
		json | rpc) [[ "${prev}" = "--mode" ]] && headless=1 ;;
		*) ;;
		esac
		prev="${arg}"
	done
	for arg in "$@"; do
		printf '%s\0' "${arg}"
	done
	# Env hints go to the wrapper-allocated sidecar file (one KEY=VAL per
	# line). The wrapper reads + exports it after we return.
	if [[ "${headless}" -eq 1 ]] && [[ -n "${RIOTBOX_INJECT_ENV_FILE:-}" ]]; then
		printf 'CI=true\n' >>"${RIOTBOX_INJECT_ENV_FILE}"
	fi
}

# Container-side runtime setup. setup.sh places AGENTS.md and rewrites
# settings.json with RiotBox's forced keys on every container start.
agent_pi_container_setup() {
	# shellcheck source=./setup.sh
	source "${_AGENT_PI_DIR}/setup.sh"
	pi_setup
}

# Host-side config sync. Pi itself reads PI_CODING_AGENT_DIR when the user
# relocated their agent directory, so the sync reads the same place. RiotBox
# never sets that variable inside the container: context-mode's platform
# detection treats it as an oh-my-pi marker. The value is normalised as Pi
# does: a leading `~` expands to $HOME and a relative path is taken against
# the current directory. An empty value means the default. Everything Pi keeps
# goes under the state dir ($2); the session dir ($1) is unused.
agent_pi_host_sync() {
	local state_dir="${2:?host_sync requires a state_dir argument}"
	local agent_dir="${PI_CODING_AGENT_DIR:-${HOME}/.pi/agent}"
	case "${agent_dir}" in
	\~) agent_dir="${HOME}" ;;
	\~/*) agent_dir="${HOME}/${agent_dir#\~/}" ;;
	/*) ;;
	*) agent_dir="${PWD}/${agent_dir}" ;;
	esac
	"${_AGENT_PI_DIR}/sync-settings.sh" "${agent_dir}" "${state_dir}"
}

# Print the env var names this agent reads (one per line). The launcher
# unions these across ALL registered agents and forwards the union into every
# container (libexec/passthrough-vars.sh), so this list is deliberately the
# same eight provider keys opencode declares: Pi's built-in providers read
# roughly forty more, and listing them here would forward them into Claude
# and opencode sessions too. Other keys go through
# RIOTBOX_PASSTHROUGH_EXTRA_VARS (see ~/.config/riotbox/config).
agent_pi_env_vars() {
	cat <<'EOF'
ANTHROPIC_API_KEY
OPENAI_API_KEY
OPENROUTER_API_KEY
GEMINI_API_KEY
GROQ_API_KEY
MISTRAL_API_KEY
DEEPSEEK_API_KEY
XAI_API_KEY
EOF
}
