#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# agents/pi/git-ai.sh — git-ai verbs for Pi.
#
# Sourced by agents/pi/manifest.sh. container/git-ai-setup.sh drives it and
# holds no agent names of its own.
#
# git-ai's own `install-hooks` writes Pi's wiring: it detects Pi by the `pi`
# binary on PATH (src/mdm/agents/pi.rs) and writes
# ~/.pi/agent/extensions/git-ai.ts with the container's git-ai path baked in.
# That runs at container start, after host_sync, so it also replaces any copy
# host_sync brought in from the host — whose baked path is a host path.
# RiotBox only has to remove the file when git-ai is off.
# ─────────────────────────────────────────────────────────────────────────────

# Unlike its opencode plugin, upstream's Pi extension template
# (agent-support/pi/git-ai.ts, v1.7.5) carries no banner. Two lines of the
# template identify it instead, and BOTH must match exactly as upstream writes
# them: the comment as a whole line at column 0, the binary line anchored at
# column 0. A free-substring match over-removes — it deletes a user's own
# git-ai.ts that merely quotes the comment (the same bug agents/opencode/git-ai.sh
# was fixed for; see its header). Anything lacking either line is left alone.
#
# Upstream places both lines at 7-8 in v1.7.5; the 12-line window leaves slack
# for a few added header lines without reaching into unrelated code.
_GIT_AI_PI_OVERRIDE_COMMENT='// Optional user-owned override file. Managed installer never writes it.'
_GIT_AI_PI_BIN_LINE_RE="^const GIT_AI_BIN = '"

# Remove the git-ai extension that `git-ai install-hooks` writes for Pi.
# Idempotent, always returns 0, silent when there is nothing to remove.
agent_pi_git_ai_strip() {
	local extension="${HOME}/.pi/agent/extensions/git-ai.ts"
	local head_lines

	[[ -f "${extension}" ]] || return 0

	# An unreadable file yields empty output and takes the "not ours" branch.
	head_lines="$(head -n 12 "${extension}" 2>/dev/null)" || head_lines=""
	if ! grep -qxF "${_GIT_AI_PI_OVERRIDE_COMMENT}" <<<"${head_lines}" ||
		! grep -qE "${_GIT_AI_PI_BIN_LINE_RE}" <<<"${head_lines}"; then
		echo "  [git-ai] NOTE: ${extension} is not the generated extension — left in place." >&2
		return 0
	fi

	rm -f "${extension}"
	echo "  [git-ai] Removed the generated pi extension." >&2
}
