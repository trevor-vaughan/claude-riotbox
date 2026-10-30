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
	install_engine_stub idle
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

# make_dot_session
#   Like make_session for the project set {.dotfiles, zeta}. A multi-project
#   key starts with the first basename, so this key starts with a dot. The
#   state dir also holds the launch's own record of the set. Prints the key.
make_dot_session() {
	local first="${T}/projects/.dotfiles" second="${T}/projects/zeta" key
	mkdir -p "${first}" "${second}"
	key="$(session_key "${first}" "${second}")"
	[[ "${key}" == .* ]] || {
		echo "FAIL: key '${key}' does not start with a dot" >&2
		return 1
	}
	mkdir -p "${DATA}/${key}" "${STATE}/${key}/git-ai"
	printf '%s\n%s\n' "${first}" "${second}" >"${DATA}/${key}/.projects"
	printf '%s\n%s\n' "${first}" "${second}" >"${STATE}/${key}/projects"
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

# install_engine_stub idle | busy <mount-source> | down
#   Write ${T}/engine and export it as CONTAINER_CMD, the engine riotbox-core
#   session-busy asks. idle: nothing runs. busy: one container mounts
#   <mount-source> read-write. down: every call fails.
install_engine_stub() {
	local mode="$1" source="${2:-}"
	case "${mode}" in
	idle) printf '#!/bin/sh\nexit 0\n' >"${T}/engine" ;;
	down) printf '#!/bin/sh\necho engine down >&2\nexit 125\n' >"${T}/engine" ;;
	busy)
		cat >"${T}/engine" <<EOF
#!/bin/sh
case "\$1" in
ps) echo abc ;;
container) printf 'abc\\0web\\0%s\\0true\\0\\n' '${source}' ;;
esac
EOF
		;;
	*)
		echo "install_engine_stub: unknown mode ${mode}" >&2
		return 1
		;;
	esac
	chmod +x "${T}/engine"
	export CONTAINER_CMD="${T}/engine"
}

# age_session <key> <days>
#   Set every file and directory of the session and its state dir to <days>
#   days ago, so nothing under it counts as recent.
age_session() {
	local -a dirs=("${DATA}/$1")
	if [[ -d "${STATE}/$1" ]]; then
		dirs+=("${STATE}/$1")
	fi
	find "${dirs[@]}" -exec touch -h -d "$2 days ago" {} +
}
