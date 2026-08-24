#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# agents/opencode/manifest.sh — Manifest for the opencode CLI agent.
#
# Sourced by agents/registry.sh from both host and container contexts.
# Co-located with opencode-specific helpers under agents/opencode/:
#   manifest.sh       — this file (the contract functions)
#   setup.sh          — container-side runtime setup
#   sync-settings.sh  — host-side config sync
#
# See docs/dev/agent-contract.md for the full contract.
# ─────────────────────────────────────────────────────────────────────────────

# Resolve this manifest's own directory so sibling files load by absolute path.
_AGENT_OPENCODE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Context Mode verbs (optional contract — see docs/dev/agent-contract.md).
# shellcheck source=./context-mode.sh
source "${_AGENT_OPENCODE_DIR}/context-mode.sh"

# GitHub/GitLab MCP verbs (optional contract — see docs/dev/agent-contract.md).
# Only the riotbox-gh-glab image ships the commands that call these; the verbs
# themselves are harmless everywhere else, since nothing invokes them unasked.
# shellcheck source=./forge-mcp.sh
source "${_AGENT_OPENCODE_DIR}/forge-mcp.sh"

# Name of the binary on PATH inside the container.
agent_opencode_real_binary() {
	printf 'opencode\n'
}

# Argv for non-interactive "run with prompt" mode. opencode uses a cobra-style
# subcommand layout: `opencode run <prompt>`. The wrapper injects --auto
# immediately after `run` (see agent_opencode_wrapper_inject).
#
# Argv tokens are emitted NUL-terminated (`printf '%s\0'`) so multi-line
# prompts survive the round-trip through `mapfile -d ''`. NUL is safe —
# argv tokens cannot contain NUL bytes (execve invariant). See
# docs/dev/agent-contract.md for the full contract.
agent_opencode_run_argv() {
	local prompt="${1:?run_argv requires a prompt argument}"
	printf '%s\0' opencode run "${prompt}"
}

# Argv for "continue last session". opencode's continuation is also a
# `run` subcommand flag.
agent_opencode_resume_argv() {
	printf '%s\0' opencode run --continue
}

# Argv for read-only audit mode. Same shape as run — the read-only project
# mount is a launch-time concern, not an agent flag.
agent_opencode_audit_argv() {
	local prompt="${1:?audit_argv requires a prompt argument}"
	printf '%s\0' opencode run "${prompt}"
}

# Wrapper injection rules. opencode auto-approves permissions with --auto,
# which is registered on the `run` command and on the default `[project]`
# (TUI) command — NOT globally. It shows up under root `--help` only because
# root help documents the default command.
#
# Position therefore matters, and getting it wrong breaks opencode outright.
# Verified against 1.18.13:
#
#   opencode --auto run "hi"   -> exit 1, prints root help
#   opencode run --auto "hi"   -> parses
#   opencode --auto            -> parses (default [project] command)
#
# The root parser consumes --auto for the default command and then treats
# `run` as that command's [project] positional, so the subcommand is never
# dispatched. Every sibling subcommand (`models`, `auth`, ...) breaks the same
# way, including ones upstream adds after this comment was written.
#
# That last point sets the rule. We cannot ask "is there a subcommand?" without
# tracking upstream's command list, and a list that falls behind would inject
# at the root in front of a subcommand we do not know — the exact breakage this
# guards against. So the test is "does argv carry a POSITIONAL token?":
#
#   no positional (bare, `--pure`, `--print-logs`)  -> root, TUI takes it
#   `run` present                                   -> immediately after `run`
#   any other positional (`models`, `/workspace`)   -> inject nothing
#
# The bias is deliberate. Injecting where we should not breaks the session;
# declining to inject only forfeits auto-approval. So a bare positional gets
# nothing even when it is really the TUI's [project] path — `opencode
# /workspace` runs ask-first rather than risk a subcommand we cannot recognise.
#
# opencode's parser is strict: an unknown flag exits 1 with usage
# (`opencode run --bogus hi` -> exit 1). A stale flag name here fails LOUDLY
# at session start, not silently. The Containerfile still asserts --auto
# exists at build time so the failure names what moved, rather than surfacing
# as a broken session.
agent_opencode_wrapper_inject() {
	local saw_run=0
	local saw_positional=0
	local arg
	for arg in "$@"; do
		if [[ "${arg}" != -* ]]; then
			saw_positional=1
			break
		fi
	done
	if [[ "${saw_positional}" -eq 0 ]]; then
		printf '%s\0' --auto
	fi
	for arg in "$@"; do
		printf '%s\0' "${arg}"
		if [[ "${saw_run}" -eq 0 ]] && [[ "${arg}" = "run" ]]; then
			saw_run=1
			printf '%s\0' --auto
		fi
	done
	# `opencode --pure` runs without external plugins, so the Context Mode
	# plugin shim never loads. Say so: the session would otherwise report the
	# feature as wired and report a zero saving, which is exactly the "did it
	# engage at all?" ambiguity the exit report exists to remove. Warn and
	# continue — --pure is the user's explicit instruction, not ours to drop.
	# stderr only: stdout is the NUL-terminated argv the wrapper reads back.
	if [[ "${RIOTBOX_CONTEXT_MODE:-0}" = "1" ]]; then
		for arg in "$@"; do
			if [[ "${arg}" = "--pure" ]]; then
				echo "  [context-mode] WARN: opencode --pure disables external plugins," >&2
				echo "  [context-mode] so Context Mode will not engage this session." >&2
				break
			fi
		done
	fi
	# Env hints go to the wrapper-allocated sidecar file (one KEY=VAL per
	# line). The wrapper reads + exports it after we return. Stderr is
	# reserved for user-facing diagnostics.
	if [[ "${saw_run}" -eq 1 ]] && [[ -n "${RIOTBOX_INJECT_ENV_FILE:-}" ]]; then
		printf 'CI=true\n' >>"${RIOTBOX_INJECT_ENV_FILE}"
	fi
}

# Optional verb: argv for headroom interposition (RIOTBOX_HEADROOM=1).
# Written when headroom had no `wrap opencode` subcommand (true through
# 0.25.0) — its wrap docstring said to run `headroom proxy` and point
# opencode at it. 0.36.5 does ship one; see headroom-exec.sh's header for
# why this path is kept for now. headroom-exec.sh
# is that proxy-routed path: it ensures the proxy is listening, injects
# provider baseURLs into the merged opencode.jsonc (only after the proxy
# answers), and re-execs opencode under the wrapper's exported
# RIOTBOX_HEADROOM_ACTIVE guard. No `--` separator: the helper defines no
# flags of its own, so every token after argv[0] is a user arg.
agent_opencode_headroom_argv() {
	printf '%s\0' "${_AGENT_OPENCODE_DIR}/headroom-exec.sh"
	local arg
	for arg in "$@"; do
		printf '%s\0' "${arg}"
	done
}

# Container-side runtime setup. setup.sh places AGENTS.md and a merged
# opencode.jsonc (combining host opencode.json + opencode.jsonc with
# riotbox-mandatory overrides) on every container start; both are idempotent.
agent_opencode_container_setup() {
	# shellcheck source=./setup.sh
	source "${_AGENT_OPENCODE_DIR}/setup.sh"
	opencode_setup
}

# Host-side config sync. sync-settings.sh copies the host opencode config
# tree into the session dir and emits volume flags (including the auth.json
# RW bind when present).
agent_opencode_host_sync() {
	local session_dir="${1:?host_sync requires a session_dir argument}"
	"${_AGENT_OPENCODE_DIR}/sync-settings.sh" \
		"${HOME}/.config/opencode" \
		"${HOME}/.local/share/opencode" \
		"${session_dir}"
}

# Print the env var names this agent reads (one per line). The launcher
# unions these across all registered agents to build the passthrough set.
# Names only — no values; the container runtime copies values from the
# caller's environment via `-e <name>` (see passthrough-vars.sh).
#
# opencode is provider-agnostic: it reads each provider's own API key when
# configured to use that provider. We list every key opencode supports
# upstream so users can switch providers without re-editing this manifest.
agent_opencode_env_vars() {
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
