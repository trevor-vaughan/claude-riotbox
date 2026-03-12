#!/usr/bin/env bash
set -euo pipefail
# Run venom tests inside the test container.
# Required env: from test.yml vars (via task)
# Arguments: [suite] — specific .venom.yml file (default: all suites)

ROOT_DIR="${ROOT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
CONTAINER_CMD="${CONTAINER_CMD:-$(command -v podman 2>/dev/null || echo docker)}"
TEST_IMAGE="${TEST_IMAGE:-claude-riotbox-test}"
USERNS_FLAG=""
INIT_FLAG=""
if [ "$(basename "${CONTAINER_CMD}")" = "podman" ]; then
    USERNS_FLAG="--userns=keep-id"
    INIT_FLAG="--init=false"
fi

RIOTBOX_DIR=/home/testuser/riotbox

run_venom() {
    ${CONTAINER_CMD} run --rm \
        ${USERNS_FLAG} \
        ${INIT_FLAG} \
        -v "${ROOT_DIR}:${RIOTBOX_DIR}:ro,z" \
        -e RIOTBOX_DIR="${RIOTBOX_DIR}" \
        "${TEST_IMAGE}" \
        venom run "$@" \
            --output-dir /tmp/venom-results \
            --var root="${RIOTBOX_DIR}" \
            --var riotbox_dir="${RIOTBOX_DIR}" \
            --var helpers="${RIOTBOX_DIR}/tests/lib/git-test-helpers.sh"
}

filter="${*:-}"
if [ -z "${filter}" ]; then
    run_venom "${RIOTBOX_DIR}/tests/"
elif [ -f "${ROOT_DIR}/${filter}" ] || [[ "${filter}" == *.venom.yml ]]; then
    run_venom "${RIOTBOX_DIR}/${filter}"
else
    # Try to match a partial name to a suite file
    matched=$(find "${ROOT_DIR}/tests" -name "*${filter}*.venom.yml" -print -quit 2>/dev/null)
    if [ -n "${matched}" ]; then
        suite="${matched#"${ROOT_DIR}/"}"
        run_venom "${RIOTBOX_DIR}/${suite}"
    else
        echo "No test suite matching '${filter}' found" >&2
        exit 1
    fi
fi
