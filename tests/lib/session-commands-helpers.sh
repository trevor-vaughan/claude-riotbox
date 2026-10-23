#!/usr/bin/env bash
# Shared helpers for tests/session-commands.venom.yml.
#
# On a rootless install the session dirs share ${XDG_DATA_HOME}/riotbox with
# the installed app tree and backups/, so every case runs against a real
# ./install.sh layout: a session command that strays outside the sessions
# deletes something these helpers can see is gone.
set -euo pipefail

# Session keys come from the launch's own derivation in
# scripts/mount-projects.sh, never a re-derivation here.
# shellcheck source=scripts/mount-projects.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../scripts/mount-projects.sh"
# shellcheck source=tests/lib/go-stub.sh
source "$(dirname "${BASH_SOURCE[0]}")/go-stub.sh"

# setup_session_install
#   Install RiotBox rootless into a fresh fake HOME and seed a backup store.
#   Sets: T (canonical temp root), DATA (the rootless RIOTBOX_DATA_DIR),
#         STATE (RIOTBOX_STATE_ROOT)
#   Exports: HOME, XDG_DATA_HOME, XDG_CONFIG_HOME, ROOT_DIR, and PATH with a
#            go stub (tests/lib/go-stub.sh) in front for install.sh --build
setup_session_install() {
	: "${RIOTBOX_DIR:?RIOTBOX_DIR must be set by the caller}"
	T="$(mktemp -d)"
	T="$(cd "${T}" && pwd -P)"
	export HOME="${T}/home"
	unset CONTEXT_MODE_DIR RIOTBOX_CONTEXT_MODE RIOTBOX_AGENT _CONTEXT_MODE_WIRED CONTEXT_MODE_DATA_DIR CONTEXT_MODE_PLATFORM
	export XDG_DATA_HOME="${HOME}/.local/share"
	export XDG_CONFIG_HOME="${HOME}/.config"
	export ROOT_DIR="${RIOTBOX_DIR}"
	mkdir -p "${HOME}" "${T}/projects"
	install_go_stub "${T}/go-stub" "${RIOTBOX_DIR}/libexec/riotbox-core"
	"${RIOTBOX_DIR}/install.sh" --build "${T}/bin" >/dev/null 2>&1
	DATA="${XDG_DATA_HOME}/riotbox"
	STATE="${XDG_DATA_HOME}/riotbox-state"
	mkdir -p "${DATA}/backups/proj.git"
	echo ref >"${DATA}/backups/proj.git/HEAD"
}

# make_session <name>
#   Create project ${T}/projects/<name> and a marked session for it holding a
#   payload file, plus a state dir holding a git-ai store. Prints the key.
make_session() {
	local project="${T}/projects/$1" key
	mkdir -p "${project}"
	key="$(session_key "${project}")"
	mkdir -p "${DATA}/${key}" "${STATE}/${key}/git-ai"
	printf '%s\n' "${project}" >"${DATA}/${key}/.projects"
	echo payload >"${DATA}/${key}/payload"
	echo '{}' >"${STATE}/${key}/git-ai/config.json"
	printf '%s\n' "${key}"
}

# assert_app_tree_intact
#   Fail unless every app path install.sh lays down, and the seeded backup,
#   still exists.
assert_app_tree_intact() {
	local p
	for p in bin/riotbox libexec scripts agents container Containerfile VERSION .riotbox-app backups/proj.git/HEAD; do
		if [[ ! -e "${DATA}/${p}" ]]; then
			echo "FAIL: the app tree lost ${p}"
			return 1
		fi
	done
}
