#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# sync-claude-settings.sh — Copy host Claude config files into a RiotBox session dir.
#
# Usage: sync-claude-settings.sh <host-claude-dir> <session-dir>
#
# Copies (or bind-mounts via -v flags printed to stdout) the following from the
# host ~/.claude directory into the container's session directory:
#
#   .credentials.json  — RW bind mount (token refresh writes back to host)
#   .claude.json       — copied (account metadata; container may write oauthAccount)
#   CLAUDE.md          — copied if present (user-level instructions)
#   rules/             — copied if present (user-level rules, path-scoped)
#   skills/            — copied with symlink dereferencing (may be plugin symlinks)
#   agents/            — copied with symlink dereferencing (user-level subagents)
#   commands/          — copied with symlink dereferencing (user-level slash commands)
#   output-styles/     — copied with symlink dereferencing (custom output styles)
#   statusline-command.sh — copied if present (custom status bar command)
#
# Bind-mount flags (for credentials) are printed to stdout so the caller can
# capture and append them to its volume flag string.
#
# Copies are staged outside the session dir and renamed in (see STAGE_DIR).
#
# Exit codes:
#   0 — success
#   1 — wrong number of arguments, a non-absolute <session-dir>, or an entry
#       changed during sync
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

if [[ $# -ne 2 ]]; then
	echo "Usage: $0 <host-claude-dir> <session-dir>" >&2
	exit 1
fi

HOST_CLAUDE_DIR="$1"
SESSION_DIR="$2"

[[ "${SESSION_DIR}" = /* ]] || {
	echo "sync-settings.sh: session dir must be an absolute path: ${SESSION_DIR}" >&2
	exit 1
}

# Container home — must match the image's user home (see detect-mounts.sh)
CONTAINER_HOME="/home/llm"

# The session dir is the container's read-write ~/.claude, and several
# sessions of one project may run at once, so a running container can replace
# any entry in it with a link while this script runs. `cp`, `chmod` and
# `tar -x` follow a link at their destination, so a planted `.claude.json ->
# ~/.bashrc` would have them write a host file. Every copy is therefore built
# in STAGE_DIR and renamed into place. STAGE_DIR sits in the session dir's
# parent (riotbox/, never mounted; dot-named, so the riotbox/*/ session
# enumerators skip it) on the same filesystem, so the rename is atomic.
STAGE_DIR="$(mktemp -d "$(dirname -- "${SESSION_DIR}")/.claude-sync.XXXXXX")"
trap 'rm -rf -- "${STAGE_DIR}"' EXIT

# _install_staged <name> — rename ${STAGE_DIR}/<name> onto ${SESSION_DIR}/<name>.
# rename(2) replaces a link or other non-directory instead of following it, but
# cannot replace a directory with a file or a non-empty directory with a
# directory. So the old copy of a directory is removed first, and so is a
# directory at a file's destination. A link or FIFO there would be replaced
# anyway; it is removed first only so the warning names it (only the
# container puts one there). If an entry is re-planted after that removal,
# the rename fails (EISDIR, ENOTDIR or ENOTEMPTY) rather than following a
# link or merging into a directory; abort then, as on a failed removal.
_install_staged() {
	local name="$1"
	local staged="${STAGE_DIR}/${name}" dest="${SESSION_DIR}/${name}"
	# shellcheck disable=SC2015  # abort when either the removal or the rename fails
	if [[ -d "${staged}" ]]; then
		rm -rf -- "${dest}"
	elif [[ -L "${dest}" ]] || { [[ -e "${dest}" ]] && [[ ! -f "${dest}" ]]; }; then
		echo "Warning: ${dest} is not a regular file; removing it." >&2
		rm -rf -- "${dest}"
	fi && mv -T -- "${staged}" "${dest}" || {
		echo "Error: ${name} in ${SESSION_DIR} changed during sync (another process, possibly a running session of this project, modified it); aborting." >&2
		exit 1
	}
}

# ── Credentials (RW bind mount) ───────────────────────────────────────────────
# Bind-mounted RW as a nested mount inside the session dir so that token
# refresh writes go directly to the host file. OAuth uses rotating refresh
# tokens, so keeping the host file current is essential for subsequent runs.
if [[ -f "${HOST_CLAUDE_DIR}/.credentials.json" ]]; then
	echo "-v ${HOST_CLAUDE_DIR}/.credentials.json:${CONTAINER_HOME}/.claude/.credentials.json:z"
fi

# ── Config copy (.claude.json) ────────────────────────────────────────────────
# Note: .claude.json lives at ~/.claude.json (next to ~/.claude/, not inside it).
# Contains account metadata needed for auth, plus host-specific UI state that
# the container shouldn't permanently modify. Copied writable so Claude Code
# can update oauthAccount fields during token refresh without error.
if [[ -f "${HOME}/.claude.json" ]]; then
	cp "${HOME}/.claude.json" "${STAGE_DIR}/.claude.json"
	chmod 600 "${STAGE_DIR}/.claude.json"
	_install_staged .claude.json
fi

# ── User CLAUDE.md ───────────────────────────────────────────────────────────
# The RiotBox system prompt lives at the managed policy path
# (/etc/claude-code/CLAUDE.md) inside the container, so ~/.claude/CLAUDE.md is
# free for the user's personal instructions. Copy from host if present; remove
# stale copies (or anything planted there) if the host file was deleted.
if [[ -f "${HOST_CLAUDE_DIR}/CLAUDE.md" ]]; then
	cp "${HOST_CLAUDE_DIR}/CLAUDE.md" "${STAGE_DIR}/CLAUDE.md"
	_install_staged CLAUDE.md
else
	rm -rf -- "${SESSION_DIR}/CLAUDE.md"
fi

# ── User rules ───────────────────────────────────────────────────────────────
# Personal rules in ~/.claude/rules/ apply to every project. Path-scoped rules
# use glob frontmatter and load on demand. Re-copy each launch so
# added/removed rules don't linger.
if [[ -d "${HOST_CLAUDE_DIR}/rules" ]]; then
	cp -rL "${HOST_CLAUDE_DIR}/rules" "${STAGE_DIR}/"
	_install_staged rules
else
	rm -rf -- "${SESSION_DIR}/rules"
fi

# ── User extension directories ────────────────────────────────────────────────
# Claude Code loads user-level resources from several sibling directories under
# ~/.claude/. All follow the same loading model — a directory of files scanned
# at startup — so they share one copy routine:
#
#   skills/        — reusable instruction bundles
#   agents/        — user-defined subagents
#   commands/      — user-defined slash commands
#   output-styles/ — custom output style definitions
#
# Each may contain symlinks pointing into plugin checkouts or dev sources, so
# we dereference during copy. `cp -rL` aborts on the first dangling symlink
# (e.g. a plugin checkout the user removed). Pre-filter with `find -L … !
# -type l` — under -L, valid symlinks report their target's type, so only
# broken symlinks retain `-type l` — then stream paths through `tar -h` to
# dereference and copy. This mirrors the host-plugin copy pattern in
# container/plugin-setup.sh.
#
# Re-copy each launch so renamed/removed files don't linger; clean up the
# destination when the source has been removed so it does not outlive the
# host.
for _user_dir in skills agents commands output-styles; do
	if [[ -d "${HOST_CLAUDE_DIR}/${_user_dir}" ]]; then
		(
			cd "${HOST_CLAUDE_DIR}" &&
				find -L "${_user_dir}" ! -type l -print0 |
				tar -ch --null --no-recursion --files-from=- -f -
		) | tar -xf - -C "${STAGE_DIR}/" --no-same-owner
		_install_staged "${_user_dir}"
	else
		rm -rf -- "${SESSION_DIR:?}/${_user_dir}"
	fi
done
unset _user_dir

# ── Statusline command ────────────────────────────────────────────────────────
# Optional user script that customises the Claude Code status bar.
# Copied (not mounted) so the container gets a clean read-only snapshot.
# chmod +x is explicit: cp preserves bits from the source, but the source may
# not be executable (e.g. created without chmod +x), so we enforce it here.
# If the source has been removed, delete any stale copy from the session dir.
if [[ -f "${HOST_CLAUDE_DIR}/statusline-command.sh" ]]; then
	cp "${HOST_CLAUDE_DIR}/statusline-command.sh" "${STAGE_DIR}/statusline-command.sh"
	chmod +x "${STAGE_DIR}/statusline-command.sh"
	_install_staged statusline-command.sh
else
	rm -rf -- "${SESSION_DIR}/statusline-command.sh"
fi

# ── Host plugins (read-only mount) ───────────────────────────────────────────
# Mounted at /home/llm/.host-plugins inside the container. plugin-setup.sh
# copies contents into ~/.claude/plugins/ at startup, with host plugins taking
# highest precedence (overwriting pre-staged defaults on conflict).
if [[ -d "${HOST_CLAUDE_DIR}/plugins" ]]; then
	echo "-v ${HOST_CLAUDE_DIR}/plugins:${CONTAINER_HOME}/.host-plugins:ro,z"
else
	echo "Notice: ~/.claude/plugins not found on host — host plugin copy will be skipped." >&2
fi
