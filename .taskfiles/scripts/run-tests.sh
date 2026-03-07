#!/usr/bin/env bash
set -euo pipefail
# Run bats tests inside the test container.
# Required env: from test.yml vars (via task)
# Arguments: [filter] — bats filter regex or test file path (default: all)

ROOT_DIR="${ROOT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
CONTAINER_CMD="${CONTAINER_CMD:-$(command -v podman 2>/dev/null || echo docker)}"
TEST_IMAGE="${TEST_IMAGE:-claude-riotbox-test}"
USERNS_FLAG=""
INIT_FLAG=""
if [ "$(basename "${CONTAINER_CMD}")" = "podman" ]; then
    USERNS_FLAG="--userns=keep-id"
    INIT_FLAG="--init=false"
fi

run_bats() {
    ${CONTAINER_CMD} run --rm \
        ${USERNS_FLAG} \
        ${INIT_FLAG} \
        -v "${ROOT_DIR}:/home/testuser/riotbox:ro,z" \
        -e RIOTBOX_DIR=/home/testuser/riotbox \
        "${TEST_IMAGE}" \
        bats "$@"
}

filter="${*:-}"
if [ -z "${filter}" ]; then
    run_bats /home/testuser/riotbox/tests/
elif [ -f "${ROOT_DIR}/${filter}" ] || [[ "${filter}" == *.bats ]]; then
    run_bats "/home/testuser/riotbox/${filter}"
else
    run_bats --filter "${filter}" /home/testuser/riotbox/tests/
fi
