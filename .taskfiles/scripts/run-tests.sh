#!/usr/bin/env bash
set -euo pipefail
# Run venom tests inside the test container.
# Required env: from test.yml vars (via task)
# Arguments: [suite] — specific .venom.yml file (default: all suites)

ROOT_DIR="${ROOT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
CONTAINER_CMD="${CONTAINER_CMD:-$(command -v podman 2>/dev/null || echo docker)}"
TEST_IMAGE="${TEST_IMAGE:-riotbox-test}"
USERNS_FLAG=""
INIT_FLAG=""
if [[ "$(basename "${CONTAINER_CMD}")" = "podman" ]]; then
	USERNS_FLAG="--userns=keep-id"
	INIT_FLAG="--init=false"
fi

# TEST_AS_ROOT=1 runs the suites as uid 0 in the container instead of the
# image's `USER testuser`. One case in tests/doctor-context-mode.venom.yml
# drops to uid 65534 with setpriv, and that branch is only reached when the
# runner is already uid 0 — which nothing here is by default, so it would be
# exercised only by a maintainer who happened to be root. The `test` job in
# .github/workflows/test.yml runs `task test:as-root` for that one suite, which
# is also the supported way to reproduce it locally.
#
# --userns=keep-id has to be removed when it is set, not merely supplemented.
# keep-id maps the caller's host uid onto itself and everything else onto the
# caller's subuid range, so container uid 0 becomes a subuid and writes to the
# .test-output bind mount land as a host id the caller neither owns nor can
# remove without `podman unshare` — verified: the file came out owned by the
# first id of the subuid range. Under the default rootless mapping container
# uid 0 *is* the caller's host uid, so artifacts stay caller-owned and a later
# non-root run on the same workspace is unaffected. Docker has no such mapping:
# there uid 0 is real root and .test-output would be left root-owned, so run
# the root pass under podman.
USER_FLAG=""
if [[ "${TEST_AS_ROOT:-}" = "1" ]]; then
	USERNS_FLAG=""
	USER_FLAG="--user=0:0"
fi

RIOTBOX_DIR=/home/testuser/riotbox

OUTPUT_DIR="${TEST_DIR:-${ROOT_DIR}/.test-output}"
CONTAINER_OUTPUT_DIR="${RIOTBOX_DIR}/.test-output"
mkdir -p "${OUTPUT_DIR}"

run_venom() {
	local _container_cmd _expected_version
	_container_cmd="$(command -v podman 2>/dev/null || command -v docker 2>/dev/null || echo '')"
	_expected_version="$(cat "${ROOT_DIR}/VERSION")"
	# shellcheck disable=SC2086,SC2248  # USERNS_FLAG/INIT_FLAG are empty under docker and USER_FLAG unless TEST_AS_ROOT=1; quoting would pass empty args to `run`
	${CONTAINER_CMD} run --rm \
		${USERNS_FLAG} \
		${INIT_FLAG} \
		${USER_FLAG} \
		-v "${ROOT_DIR}:${RIOTBOX_DIR}:ro,z" \
		-v "${OUTPUT_DIR}:${CONTAINER_OUTPUT_DIR}:rw,z" \
		-e RIOTBOX_DIR="${RIOTBOX_DIR}" \
		"${TEST_IMAGE}" \
		venom run "$@" \
		--output-dir "${CONTAINER_OUTPUT_DIR}" \
		--var root="${RIOTBOX_DIR}" \
		--var riotbox_dir="${RIOTBOX_DIR}" \
		--var container_cmd="${_container_cmd}" \
		--var expected_version="${_expected_version}" \
		--var helpers="${RIOTBOX_DIR}/tests/lib/git-test-helpers.sh" \
		--var wrapper_helpers="${RIOTBOX_DIR}/tests/lib/wrapper-test-helpers.sh" \
		--var overlay_helpers="${RIOTBOX_DIR}/tests/lib/overlay-test-helpers.sh" \
		--var inject_helpers="${RIOTBOX_DIR}/tests/lib/inject-test-helpers.sh" \
		--var opencode_helpers="${RIOTBOX_DIR}/tests/lib/opencode-test-helpers.sh" \
		--var agent_helpers="${RIOTBOX_DIR}/tests/lib/agent-test-helpers.sh" \
		--var shared_helpers="${RIOTBOX_DIR}/tests/lib/wrapper-shared.sh" \
		--var sync_helpers="${RIOTBOX_DIR}/tests/lib/sync-settings-test-helpers.sh" \
		--var startup_helpers="${RIOTBOX_DIR}/tests/lib/startup-scripts-test-helpers.sh" \
		--var release_helpers="${RIOTBOX_DIR}/tests/lib/release-test-helpers.sh"
}

filter="${*:-}"
if [[ -z "${filter}" ]]; then
	run_venom "${RIOTBOX_DIR}/tests/"
elif [[ -f "${ROOT_DIR}/${filter}" ]] || [[ "${filter}" == *.venom.yml ]]; then
	run_venom "${RIOTBOX_DIR}/${filter}"
else
	# Try to match a partial name to a suite file
	matched=$(find "${ROOT_DIR}/tests" -name "*${filter}*.venom.yml" -print -quit 2>/dev/null)
	if [[ -n "${matched}" ]]; then
		suite="${matched#"${ROOT_DIR}/"}"
		run_venom "${RIOTBOX_DIR}/${suite}"
	else
		echo "No test suite matching '${filter}' found" >&2
		exit 1
	fi
fi
