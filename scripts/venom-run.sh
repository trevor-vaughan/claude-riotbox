#!/usr/bin/env bash
# venom-run.sh — direct, container-free venom invocation that contains its spew.
#
# Why this script exists
# ----------------------
# `venom run` writes `venom.log` to CWD on every invocation and rotates
# prior runs to `venom.0.log`, `venom.1.log`, etc. Venom 1.3.0 has no flag
# to redirect this log; `--output-dir` only controls test-result files
# (XML/JSON). Run `venom run tests/foo.venom.yml` from the repo root and
# you litter `/workspace/venom.log` (plus rotated siblings) every time.
#
# The container-driven path (`task test`) avoids this because the repo is
# mounted read-only — venom's log write fails silently and is discarded
# with `--rm`. But developers iterating locally, agent sandboxes without
# the test image, and anyone invoking venom directly all hit the spew.
#
# This wrapper exists so there is one supported way to run venom directly:
# it routes everything (logs and result files) into `.test-output/` by
# `cd`-ing there before invoking venom. Test files passed as arguments are
# resolved to absolute paths up front so the `cd` does not break them.
#
# Usage
# -----
#   scripts/venom-run.sh tests/socket.venom.yml
#   scripts/venom-run.sh --stop-on-failure tests/wrapper.venom.yml
#   scripts/venom-run.sh --format=json tests/
#
# Any additional `venom run` flags pass through unchanged.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIR="${ROOT_DIR}/.test-output"

mkdir -p "${OUTPUT_DIR}"

# Resolve any positional argument that looks like a path under the repo
# (a venom suite or a directory of suites) to an absolute path. Flags and
# `--key=value` arguments are passed through untouched.
resolved_args=()
for arg in "$@"; do
	case "${arg}" in
	-*)
		resolved_args+=("${arg}")
		;;
	*)
		if [[ -e "${arg}" ]]; then
			# shellcheck disable=SC2312  # cd/dirname/basename failures on a verified existing path are unreachable
			resolved_args+=("$(cd "$(dirname "${arg}")" && pwd)/$(basename "${arg}")")
		elif [[ -e "${ROOT_DIR}/${arg}" ]]; then
			resolved_args+=("${ROOT_DIR}/${arg}")
		else
			resolved_args+=("${arg}")
		fi
		;;
	esac
done

cd "${OUTPUT_DIR}"

# shellcheck disable=SC2312  # var assembly — command -v/cat fallbacks are intentional
venom run \
	--output-dir=. \
	--var root="${ROOT_DIR}" \
	--var riotbox_dir="${ROOT_DIR}" \
	--var container_cmd="$(command -v podman 2>/dev/null || command -v docker 2>/dev/null || echo '')" \
	--var expected_version="$(cat "${ROOT_DIR}/VERSION")" \
	--var helpers="${ROOT_DIR}/tests/lib/git-test-helpers.sh" \
	--var wrapper_helpers="${ROOT_DIR}/tests/lib/wrapper-test-helpers.sh" \
	--var overlay_helpers="${ROOT_DIR}/tests/lib/overlay-test-helpers.sh" \
	--var inject_helpers="${ROOT_DIR}/tests/lib/inject-test-helpers.sh" \
	--var opencode_helpers="${ROOT_DIR}/tests/lib/opencode-test-helpers.sh" \
	--var agent_helpers="${ROOT_DIR}/tests/lib/agent-test-helpers.sh" \
	--var shared_helpers="${ROOT_DIR}/tests/lib/wrapper-shared.sh" \
	--var sync_helpers="${ROOT_DIR}/tests/lib/sync-settings-test-helpers.sh" \
	--var startup_helpers="${ROOT_DIR}/tests/lib/startup-scripts-test-helpers.sh" \
	"${resolved_args[@]}"
