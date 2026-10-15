#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# agents/opencode/headroom-exec.sh — headroom interposition for opencode.
#
# This helper owns the proxy and nothing else. The wrapper execs it on the
# first pass when RIOTBOX_HEADROOM=1, with RIOTBOX_HEADROOM_ACTIVE=1 already
# exported:
#
#   1. Ensure a headroom proxy answers on 127.0.0.1:${HEADROOM_PORT:-8787},
#      or the next port up when something else holds that one — reuse a
#      live one, else spawn `headroom proxy --memory --no-learn`
#      (agents/lib/headroom-proxy.sh, shared with the claude helper, says
#      why learning is off).
#   2. Warn when routing will override a baseURL the user set themselves.
#   3. exec `headroom wrap opencode --no-proxy` — upstream builds
#      OPENCODE_CONFIG_CONTENT and launches opencode, which resolves back to
#      the shim, where the guard sends the second pass to the real binary.
#
# ── Why this exists at all, given `wrap opencode` ────────────────────────────
#
# Everything except step 1 used to live here: the helper merged provider
# baseURLs into ~/.config/opencode/opencode.jsonc with jq and swapped the file
# in through a temp file, because headroom had no `wrap opencode` (true
# through 0.25.0) and opencode ignores ANTHROPIC_BASE_URL/OPENAI_BASE_URL.
# 0.36.5 ships that subcommand, doing the same job through
# OPENCODE_CONFIG_CONTENT — no file surgery, and a bundled transport plugin
# that also covers providers we never named. All of it is now upstream's.
#
# What upstream cannot do for us is memory. `wrap opencode --memory` appends
# a "## Memory" block to AGENTS.md in the CWD and creates .headroom/ beside
# it; in a session the CWD is /workspace, the caller's bind-mounted
# repository. (`wrap claude --memory` does not do this — the injection is on
# the opencode and codex paths only.) Spawning the proxy here with --memory
# gets cross-session memory without that write, so step 1 stays and
# --memory is deliberately NOT forwarded to `wrap opencode`. The proxy's
# own memory DB defaults to $PWD/.headroom too; the wrapper exports
# HEADROOM_MEMORY_DB_PATH (~/.headroom/memory.db, the state-dir mount),
# which `headroom proxy` reads as its --memory-db-path. Without --memory,
# `wrap opencode` touches the CWD nowhere (its only $PWD writes are under
# `if memory:`, cli/wrap.py:7919, 7983).
#
# The delegated flags, all load-bearing:
#   --no-proxy    we started the proxy; without this upstream starts a second
#                 one and terminates it when the launch returns
#   --no-mcp      skips registering headroom's MCP server, which is a config
#                 write we do not need — matches the pre-delegation behavior
#   --no-serena   Serena MCP registration downloads at session start, which
#                 violates offline-after-build
#
# Degraded mode (spawn failure, readiness timeout): warn on stderr and exec
# opencode unwrapped — headroom is an optimization layer, never a reason to
# lose a session. Delegation is deliberately skipped on that path: routing at
# a port nothing serves is worse than not routing at all.
#
# The proxy intentionally outlives this process: the container is the
# lifecycle boundary, and later opencode runs reuse the listening proxy.
# If the proxy crashes mid-session it remains a zombie under the exec'd
# opencode process until container teardown — bounded at one and reaped by
# container init, a deliberate, accepted trade-off.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

_helper_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=agents/lib/headroom-proxy.sh
source "${_helper_dir}/../lib/headroom-proxy.sh"
config="${HOME}/.config/opencode/opencode.jsonc"

# "$@" is consumed by _fallback from inside functions, so snapshot it.
USER_ARGS=("$@")

_fallback() {
	echo "WARNING: $1 — running opencode unwrapped." >&2
	exec opencode "${USER_ARGS[@]}"
}

# ── 1. Ensure the proxy ──────────────────────────────────────────────────────
# shellcheck disable=SC2310 # its status picks the fallback
# opencode adds no proxy arguments or routing env of its own: its launch
# config is the container's environment as it stands.
_opencode_proxy_plan() {
	HEADROOM_PROXY_ARGS=()
}
# shellcheck disable=SC2310 # its status picks the fallback
headroom_proxy_ensure opencode _opencode_proxy_plan || _fallback "${HEADROOM_PROXY_FAILURE}"
# The port the proxy actually uses: another may have been taken.
port="${HEADROOM_PROXY_PORT}"
# opencode's ai-sdk providers build request paths relative to a base that
# already contains /v1, which is the shape upstream writes too — so this is
# only ever compared against, never injected.
proxy_base="http://127.0.0.1:${port}/v1"

# ── 2. Notice when routing overrides a user-set baseURL ──────────────────────
# OPENCODE_CONFIG_CONTENT is merged OVER the config file, so upstream's
# baseURL wins where the old jq path deliberately stood down. The traffic
# still reaches the user's endpoint — the proxy forwards upstream, tagging
# the real base via x-headroom-base-url — but silently repointing a corporate
# gateway is not something anyone should have to discover from a packet
# capture. Advisory only: an unreadable config costs the notice, not the
# session, and upstream's own writes from a previous run are not "user-set".
if [[ -f "${config}" ]] && body="$(grep -v '^//' "${config}" 2>/dev/null)"; then
	for prov in anthropic openai; do
		existing="$(jq -r --arg p "${prov}" '.provider[$p].options.baseURL // ""' <<<"${body}" 2>/dev/null)" || continue
		if [[ -n "${existing}" && "${existing}" != "${proxy_base}" ]]; then
			echo "NOTICE: provider.${prov}.options.baseURL is set in your opencode config (${existing}) — headroom routes ${prov} through the local proxy instead." >&2
		fi
	done
fi

# ── 3. Delegate routing and launch ───────────────────────────────────────────
exec headroom wrap opencode --no-proxy --no-mcp --no-serena \
	--port "${port}" -- "${USER_ARGS[@]}"
