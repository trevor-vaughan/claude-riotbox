#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# agents/claude/git-ai.sh — git-ai verbs for the Claude Code agent.
#
# Optional contract — see docs/dev/agent-contract.md.
#
# RiotBox does not write git-ai's hooks; upstream's `install-hooks` does (see
# container/git-ai-setup.sh for why). What upstream cannot do is take them back
# out of a session directory that outlives the image, which is what this file is
# for: a session wired by an on-run and reopened with RIOTBOX_GIT_AI=0 would
# otherwise keep firing a PreToolUse and a PostToolUse hook on *every* tool call
# — upstream installs the "*" matcher, not the Write|Edit|MultiEdit its docs
# claim — against a binary whose config the same run just stopped maintaining.
#
# The same ownership rule as agent_claude_context_mode_strip applies, and for
# the same reason: decide on the entry's SHAPE, never on a key name, and
# under-remove rather than over-remove. Only the individual hook entries whose
# command names the git-ai binary as a whole path token are touched, so a hook
# the user wrote that merely mentions git-ai survives, so does one naming a
# longer path our own is a prefix of, and so does the user's own hook sharing a
# stanza with ours. The jq filter carries the reasoning for each of those.
# ─────────────────────────────────────────────────────────────────────────────

# Remove git-ai hook stanzas from the session's Claude settings.
agent_claude_git_ai_strip() {
	local config_dir="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}"
	local settings_file="${config_dir}/settings.json"
	local bin="${RIOTBOX_GIT_AI_BIN:-${HOME}/.local/bin/git-ai}"
	local current stripped

	[[ -f "${settings_file}" ]] || return 0

	# A hand-editable file that is not valid JSON is not ours to rewrite.
	# Warning and leaving it is strictly better than replacing whatever the
	# user was in the middle of writing.
	if ! current="$(jq -c '.' "${settings_file}" 2>/dev/null)" || [[ -z "${current}" ]]; then
		echo "  [git-ai] WARN: ${settings_file} is not valid JSON — stale hooks left in place." >&2
		return 0
	fi

	# One hook entry is ours when its command names the binary as a whole
	# whitespace-delimited token, which is what `unquoted` and the split are
	# for. `contains($bin)` was the first form and it over-removed: our path
	# is a prefix of every sibling script a user might keep beside it, so a
	# hook naming `<bin>-wrapper` read as ours and was deleted. Quotes come
	# off first because a command may quote the path — `"<bin>" checkpoint …`
	# is a shape settings.json carries, and the sibling context-mode strip
	# meets it in live sessions — and a token test that leaves them attached
	# recognises none of our own wiring: it would strip nothing at all and say
	# nothing, which is worse than the over-removal it replaces.
	#
	# A word-boundary regex was the alternative and was rejected. $bin is a
	# filesystem path, full of `.` and `/`, so using it as a pattern means
	# escaping every metacharacter in it first, and an escape that missed one
	# would fail open on a path chosen by whoever set RIOTBOX_GIT_AI_BIN.
	# Splitting on whitespace and comparing strings has no pattern to escape.
	# 34 and 39 are the double and the single quote, named by codepoint
	# because the jq program is one single-quoted shell word: a literal single
	# quote anywhere inside it would end that word.
	#
	# The verdict is per hook entry, not per stanza. Claude Code groups hooks
	# under a shared matcher, so one stanza can hold ours next to one the user
	# added, and asking whether *any* member is ours takes the user's hook
	# down with ours. A stanza goes only when pruning is what emptied it, and
	# one whose `hooks` is missing, of another type, or already empty is left
	# exactly as found — emptiness this code did not cause is not ours to tidy.
	#
	# Type-gated because `explode` raises on a non-string rather than
	# answering false, and one raise fails the whole program and strands the
	# hooks this function exists to remove. settings.json is hand-editable, so
	# an argv array — ["/bin/sh", …] — is a shape a person plausibly writes.
	# A command this filter cannot read is not ours.
	#
	# Every key present in .hooks is pruned rather than a fixed list of the two
	# upstream currently writes: a list would strand a stanza forever the day
	# upstream added an event, for the life of a session directory.
	if ! stripped="$(jq -c --arg bin "${bin}" '
		def unquoted: [explode[] | select(. != 34 and . != 39)] | implode;
		def is_ours: (.command? // null) as $c
			| ($c | type) == "string"
			and ([$c | unquoted | splits("[[:space:]]+")] | any(. == $bin));
		def prune_stanza:
			if ((.hooks? // null) | type) == "array" and (.hooks | length) > 0 then
				.hooks |= map(select(is_ours | not))
				| if (.hooks | length) == 0 then empty else . end
			else . end;
		def prune(key):
			if (.hooks[key] | type) == "array" and (.hooks[key] | length) > 0 then
				.hooks[key] |= map(prune_stanza)
				| if (.hooks[key] | length) == 0 then del(.hooks[key]) else . end
			else . end;
		if (.hooks | type) == "object" then
			reduce (.hooks | keys_unsorted[]) as $k (.; prune($k))
			| if (.hooks | length) == 0 then del(.hooks) else . end
		else . end
	' <<<"${current}" 2>/dev/null)"; then
		echo "  [git-ai] WARN: could not clean ${settings_file} — stale hooks left in place." >&2
		return 0
	fi

	[[ -n "${stripped}" ]] || return 0
	[[ "${stripped}" != "${current}" ]] || return 0

	# json_write_atomic <target-file> <content> comes from
	# scripts/lib/json-write.sh, which entrypoint.sh sources ahead of this
	# file. Not sourced from here: the same writer is shared with
	# codegraph-setup.sh and context-mode-setup.sh, and the entrypoint
	# composes them into one shell. Pretty-printed before writing, and a
	# failure names what was left behind rather than passing silently —
	# both matching the codegraph call sites.
	local pretty
	if ! pretty="$(jq . <<<"${stripped}" 2>/dev/null)" ||
		! json_write_atomic "${settings_file}" "${pretty}"; then
		echo "  [git-ai] WARN: could not write ${settings_file} — stale hooks left in place." >&2
		return 0
	fi
	echo "  [git-ai] Removed hook wiring from ${settings_file}." >&2
}
