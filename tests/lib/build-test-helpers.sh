#!/usr/bin/env bash
set -euo pipefail

setup_build_test() {
	local root="$1"
	TEST_DIR="$(mktemp -d)"
	trap 'rm -rf "${TEST_DIR}"' EXIT
	mkdir -p "${TEST_DIR}/proj/scripts" "${TEST_DIR}/proj/container" \
		"${TEST_DIR}/proj/configs" "${TEST_DIR}/bin" "${TEST_DIR}/home"
	cp "${root}/scripts/build.sh" "${TEST_DIR}/proj/scripts/build.sh"
	cp "${root}/container/gitignore_global" "${TEST_DIR}/proj/container/gitignore_global"
	printf '0.0.0-test\n' >"${TEST_DIR}/proj/VERSION"
	: >"${TEST_DIR}/proj/Containerfile"
	: >"${TEST_DIR}/proj/configs/preserved"
	export TEST_DIR TEST_UID=4243795 TEST_GID=5243795
	export TEST_SUBIDS='tvaughan:165536:165536'
	export TEST_PASSWD='tvaughan:x:4243795:5243795::/home/tvaughan:/bin/bash'
	export TEST_GROUP='tvaughan:x:5243795:'
	TEST_REAL_CAT="$(command -v cat)"
	export TEST_REAL_CAT
	export UID_MAP='0 4243795 1
1 165536 65536'
	export GID_MAP='0 5243795 1
1 231072 65536'
	export HOME="${TEST_DIR}/home" NVM_DIR="${TEST_DIR}/home/.nvm"
	export PATH="${TEST_DIR}/bin:${PATH}" RIOTBOX_NONINTERACTIVE_BUILD=1
	cat >"${TEST_DIR}/bin/id" <<'STUB'
#!/usr/bin/env bash
case "$1" in
-u) printf '%s\n' "${TEST_UID}" ;;
-g) printf '%s\n' "${TEST_GID}" ;;
-un) printf 'tvaughan\n' ;;
*) exit 2 ;;
esac
STUB
	cat >"${TEST_DIR}/bin/getent" <<'STUB'
#!/usr/bin/env bash
[[ "${ACCOUNT_PROBE_FAILURE:-0}" = 1 ]] && exit 2
case "$1" in
passwd) printf '%s\n' "${TEST_PASSWD}" ;;
group) printf '%s\n' "${TEST_GROUP}" ;;
*) exit 2 ;;
esac
STUB
	cat >"${TEST_DIR}/bin/cat" <<'STUB'
#!/usr/bin/env bash
if [[ "$*" = '/etc/subuid /etc/subgid' ]]; then
	printf '%s\n' "${TEST_SUBIDS}"
else
	exec "${TEST_REAL_CAT}" "$@"
fi
STUB
	cat >"${TEST_DIR}/bin/podman" <<'STUB'
#!/usr/bin/env bash
case "$1" in
unshare)
	if [[ "${PROBE_FAILURE:-0}" = 1 ]]; then
		echo 'newuidmap: fixture permission denied' >&2
		exit 125
	fi
	case "$*" in
	'unshare cat /proc/self/uid_map') printf '%s\n' "${UID_MAP}" ;;
	'unshare cat /proc/self/gid_map') printf '%s\n' "${GID_MAP}" ;;
	*) exit 2 ;;
	esac
	;;
build) touch "${TEST_DIR}/build-called" ;;
*) exit 2 ;;
esac
STUB
	chmod +x "${TEST_DIR}/bin/id" "${TEST_DIR}/bin/podman" \
		"${TEST_DIR}/bin/getent" "${TEST_DIR}/bin/cat"
}

run_build_test() {
	local status=0
	bash "${TEST_DIR}/proj/scripts/build.sh" >"${TEST_DIR}/build.log" 2>&1 || status=$?
	cat "${TEST_DIR}/build.log"
	if [[ -f "${TEST_DIR}/build-called" ]]; then
		echo BUILD_CALLED
	else
		echo BUILD_NOT_CALLED
	fi
	if [[ -f "${TEST_DIR}/proj/configs/preserved" ]]; then
		echo CONFIGS_PRESERVED
	fi
	return "${status}"
}
