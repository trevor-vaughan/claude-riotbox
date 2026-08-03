#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# scripts/lib/json-write.sh — atomic replacement of a JSON config file.
#
# Sourced inside the container by container/entrypoint.sh, ahead of the setup
# scripts that call it (codegraph-setup.sh, context-mode-setup.sh). It lives
# here rather than in either of them because the entrypoint sources those two
# independently and neither may depend on the other having been sourced; a
# third file both can reach is the only shape that leaves one definition.
#
# Public:
#   json_write_atomic <target-file> <content>
#     Replace <target-file> with <content> plus a trailing newline. Creates the
#     parent directory if it is missing. Prints nothing; returns non-zero so the
#     caller can name what was lost.
# ─────────────────────────────────────────────────────────────────────────────

# Every caller rewrites an agent config file that the user owns, living in a
# bind-mounted host session directory, so all of them need the same three
# properties and must not grow separate versions of them:
#
#   * A partial write must never replace a good config, hence the staging file
#     and the rename.
#   * The staging file is uniquely named and created inside the target
#     directory: same filesystem keeps the rename atomic, and a unique name
#     keeps two sessions sharing this bind-mounted config directory
#     (mount-projects.sh supports two concurrent sessions per project) from
#     renaming each other's half-written file over the user's config.
#   * A rename adopts the source inode's mode, so the staging file must carry
#     the mode the target should end up with. Whatever mode the file has is
#     preserved and a new one is created 0600 rather than at the process
#     umask: these paths resolve into the host session directory, so a mode
#     this code picks persists on the host, and a config the user chose to
#     restrict must never come back looser than they left it.
json_write_atomic() {
	local target_file="${1:?json_write_atomic requires a target file}"
	local content="${2?json_write_atomic requires content}"

	local tmp_file
	if ! mkdir -p "$(dirname "${target_file}")" ||
		! tmp_file="$(mktemp "${target_file}.XXXXXX")"; then
		return 1
	fi

	local mode
	if ! mode="$(stat -c '%a' "${target_file}" 2>/dev/null)" || [[ -z "${mode}" ]]; then
		mode=600
	fi

	if ! printf '%s\n' "${content}" >"${tmp_file}" ||
		! chmod "${mode}" "${tmp_file}" ||
		! mv "${tmp_file}" "${target_file}"; then
		rm -f "${tmp_file}"
		return 1
	fi
}
