#!/usr/bin/env bash
# go-test.sh <human|llm> — run every Ginkgo suite and render one report.
#
# Ginkgo writes a JSON report into $TEST_DIR/go (default .test-output/go) and
# its own console output to ginkgo.log there. ginkgoleaf renders the report:
# `tree` for people, `text` (no colour, failures with expected/actual) for
# LLMs. The exit code is ginkgo's when it failed, otherwise ginkgoleaf's, so
# rendering can never hide a failure.
set -euo pipefail

mode="${1:-human}"
case "${mode}" in
human) format=tree ;;
llm) format=text ;;
*)
	echo "ERROR: MODE must be human or llm (got '${mode}')." >&2
	exit 2
	;;
esac

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${root}"
# A relative TEST_DIR resolves against the repo root, wherever we were called from.
test_dir_arg="${TEST_DIR-.test-output}"
if [[ -z "${test_dir_arg}" ]]; then
	echo "ERROR: TEST_DIR is set but empty." >&2
	exit 2
fi
test_dir="$(realpath -m -- "${test_dir_arg}")"
if [[ "${test_dir}" == "/" ]]; then
	echo "ERROR: TEST_DIR must not be / (got '${test_dir_arg}')." >&2
	exit 2
fi
out="${test_dir}/go"
rm -rf "${out}"
mkdir -p "${out}"

ginkgo_rc=0
go tool ginkgo -r --keep-going --output-dir="${out}" --json-report=ginkgo.json \
	>"${out}/ginkgo.log" 2>&1 || ginkgo_rc=$?

if [[ ! -s "${out}/ginkgo.json" ]]; then
	cat "${out}/ginkgo.log" >&2
	echo "ERROR: ginkgo wrote no report (exit ${ginkgo_rc}); its output is above." >&2
	exit $((ginkgo_rc == 0 ? 1 : ginkgo_rc))
fi

render_rc=0
go tool ginkgoleaf --in "${out}/ginkgo.json" --format "${format}" --exit-code || render_rc=$?

if [[ "${ginkgo_rc}" -ne 0 ]]; then
	exit "${ginkgo_rc}"
fi
exit "${render_rc}"
