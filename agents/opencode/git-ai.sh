#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# agents/opencode/git-ai.sh — git-ai verbs for the opencode agent.
#
# Optional contract — see docs/dev/agent-contract.md.
#
# opencode auto-loads every *.ts under ~/.config/opencode/plugins/, and
# upstream's `install-hooks` writes git-ai.ts there with the binary's ABSOLUTE
# path baked in at install time. That directory is a session bind mount, so a
# file written by one image is still there under the next one — with a path that
# may no longer resolve. Regeneration is therefore not a tidiness measure: it is
# how the baked path is kept true. install-hooks rewrites the file every session,
# so this file only needs to own removal.
#
# Removal is content-gated, not path-gated. Deleting whatever sits at
# plugins/git-ai.ts would destroy a plugin the user wrote at that path, so
# something in upstream's generated file is what has to mark it as ours — the
# same under-remove-rather-than-over-remove rule the Claude verb follows.
#
# Ownership is gated on the marker appearing as a BANNER LINE near the head of
# the file, not on the marker as a free substring anywhere in it. The first cut
# of this file used `grep -qF` against the whole file, and adversarial probing
# (see the venom case below named for it) found that this deletes a user's own
# plugin whose comment merely mentions the phrase — e.g. a hand-written file
# that says `// replaces the git-ai plugin for OpenCode`. A plain substring
# match cannot tell that comment from upstream's own banner:
#
#   /**
#    * git-ai plugin for OpenCode
#    */
#
# so the check instead requires the marker to appear as the content of a
# block-comment continuation line (`^[[:space:]]*\*[[:space:]]+...`) within the
# first 10 lines of the file — the shape and position upstream's own generator
# actually produces, confirmed against a real `git-ai install-hooks` run, not
# just a hand-built fixture. 10 lines gives room for a leading shebang or a
# blank line before the banner starts, without being so wide that unrelated
# prose deep in a long file can satisfy it.
#
# The opposite failure is the one that matters more: a gate tightened until it
# stops matching upstream's REAL output silently removes nothing, and stale
# wiring — including the absolute path baked in at a previous install — persists
# forever in a session directory that outlives the image that wrote it. That
# risk is why this file's own tightening was checked against `git-ai
# install-hooks`'s actual generated plugin rather than trusted on inspection
# alone.
# ─────────────────────────────────────────────────────────────────────────────

# Marker from upstream's generated plugin header — the sole source of the
# banner text, so the recognition regex below and this comment can never
# drift apart. No ERE metacharacters, so it is safe to interpolate directly
# into the pattern built in agent_opencode_git_ai_strip.
_GIT_AI_OPENCODE_MARKER='git-ai plugin for OpenCode'

# Remove the generated git-ai plugin from the session's opencode config.
agent_opencode_git_ai_strip() {
	local plugin="${HOME}/.config/opencode/plugins/git-ai.ts"

	[[ -f "${plugin}" ]] || return 0

	# The marker must appear as a block-comment continuation line — a line
	# whose non-blank content is exactly `* git-ai plugin for OpenCode` — within
	# the first 10 lines. That is the shape and position upstream's generator
	# actually writes, not merely a substring anywhere in the file: a
	# free-substring match previously deleted a user's own plugin whose comment
	# read `// replaces the git-ai plugin for OpenCode`, which contains the
	# phrase but is neither a block-comment line nor upstream's banner.
	#
	# `head -n 10 | grep` rather than `grep -m1` on the whole file: a match
	# past the head is a plausible mention in unrelated code, not upstream's
	# banner, which always opens the file.
	#
	# A `head` that cannot read the file (chmod 000) yields no output, `grep`
	# then finds no match on empty input, and the same "not the generated
	# plugin" branch below runs — an unreadable file is left in place, not
	# deleted, matching the file-existence check just above it.
	# shellcheck disable=SC2312  # head's exit status is masked deliberately — an unreadable file yields empty output, and grep finding no match on it takes the same "not ours" branch as a real non-match
	if ! head -n 10 "${plugin}" 2>/dev/null |
		grep -qE "^[[:space:]]*\*[[:space:]]+${_GIT_AI_OPENCODE_MARKER}[[:space:]]*\$"; then
		echo "  [git-ai] NOTE: ${plugin} is not the generated plugin — left in place." >&2
		return 0
	fi

	rm -f "${plugin}"
	echo "  [git-ai] Removed the generated opencode plugin." >&2
}
