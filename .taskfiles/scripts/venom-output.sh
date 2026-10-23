#!/usr/bin/env bash
# venom-output.sh <output-dir> <command> [args...] — run a venom invocation,
# save its console output, and render it for TEST_MODE (human|llm).
#
# Shared by run-tests.sh (venom inside the test container) and
# scripts/venom-run.sh (venom on the host), so both paths honour MODE the same
# way. <command> is the full venom invocation; it must write its JUnit XML
# results (venom's default --format) into <output-dir>.
#
#   human  The console output passes through unchanged.
#   llm    The console output is suppressed. Afterwards each failing test case
#          is printed with its suite file, case name and the failure text venom
#          recorded in the XML results, followed by one totals line. Passing
#          and skipped cases print nothing.
#
# Either way the full console output is saved to <output-dir>/venom-output.log.
# Only result files written during this run are read: a marker file created
# before the run separates them from results left by earlier runs.
#
# The exit code is venom's when it failed, otherwise the summary's, so the
# rendering can never hide a failure. An unreadable result file counts as a
# failure.
#
# Concurrent runs sharing one output directory can read each other's results.
set -euo pipefail

mode="${TEST_MODE:-human}"
case "${mode}" in
human | llm) ;;
*)
	echo "ERROR: MODE must be human or llm (got '${mode}')." >&2
	exit 2
	;;
esac

if [[ "${mode}" == "llm" ]] && ! command -v python3 >/dev/null 2>&1; then
	echo "ERROR: MODE=llm needs python3 to summarise venom's XML results." >&2
	exit 2
fi

if [[ $# -lt 2 ]]; then
	echo "Usage: venom-output.sh <output-dir> <command> [args...]" >&2
	exit 2
fi
out_dir="$1"
shift

mkdir -p "${out_dir}"
log="${out_dir}/venom-output.log"
marker="$(mktemp "${out_dir}/.venom-run.XXXXXX")"
trap 'rm -f -- "${marker}"' EXIT

if [[ "${mode}" == "human" ]]; then
	statuses=(0 0)
	"$@" 2>&1 | tee "${log}" || statuses=("${PIPESTATUS[@]}")
	if [[ "${statuses[0]}" -ne 0 ]]; then
		exit "${statuses[0]}"
	fi
	exit "${statuses[1]}"
fi

# The log is a file, so venom's colour library already disables colour;
# NO_COLOR makes that explicit for any venom build (run-tests.sh passes it into
# the container).
export NO_COLOR=1
venom_rc=0
"$@" >"${log}" 2>&1 || venom_rc=$?

summary_rc=0
python3 -I - "${out_dir}" "${marker}" "${log}" "${venom_rc}" <<'PY' || summary_rc=$?
import glob
import os
import sys
import xml.etree.ElementTree as ET

out_dir, marker, log, venom_rc = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
MAX_LINES = 30
since = os.stat(marker).st_mtime_ns


def clip(text, limit=MAX_LINES):
    """Last `limit` lines of text, with a note when lines were dropped."""
    lines = text.strip("\n").splitlines()
    if len(lines) <= limit:
        return lines
    return [f"[... {len(lines) - limit} earlier lines in the XML results]"] + lines[-limit:]


def head(text, limit=MAX_LINES):
    """First `limit` lines of text, with a note when lines were dropped."""
    lines = text.strip("\n").splitlines()
    if len(lines) <= limit:
        return lines
    return lines[:limit] + [f"[... {len(lines) - limit} more lines in the XML results]"]


results = sorted(
    path
    for path in glob.glob(os.path.join(out_dir, "test_results_*.xml"))
    if os.stat(path).st_mtime_ns >= since
)

passed = failed = skipped = suites = unreadable = 0
for path in results:
    try:
        root = ET.parse(path).getroot()
    except ET.ParseError as err:
        unreadable += 1
        print(f"UNREADABLE {path}: {err}")
        continue
    for suite in root.iter("testsuite"):
        suites += 1
        for case in suite.iter("testcase"):
            problems = case.findall("error") + case.findall("failure")
            if not problems:
                if case.find("skipped") is not None:
                    skipped += 1
                else:
                    passed += 1
                continue
            failed += 1
            print(f"FAIL {case.get('classname', '?')}: {case.get('name', '?')}")
            messages = [p.text or "" for p in problems]
            for message in messages:
                for line in head(message):
                    print(f"  {line}")
            for tag, label in (("system-err", "stderr"), ("system-out", "stdout")):
                stream = case.findtext(tag) or ""
                if not stream.strip() or any(stream.strip() in m for m in messages):
                    continue
                print(f"  {label}:")
                for line in clip(stream):
                    print(f"    {line}")

if not results or (venom_rc != 0 and failed == 0):
    if not results:
        print("no venom XML result files were written — was --format changed? End of its output:")
    else:
        print(f"venom exited {venom_rc} without a failing test case in its results; end of its output:")
    with open(log, encoding="utf-8", errors="replace") as handle:
        for line in handle.read().splitlines()[-40:]:
            print(f"  {line}")

if not results:
    print(f"venom: no results to summarise; exit {venom_rc}; full output: {log}")
    sys.exit(0)

unreadable_note = f", {unreadable} unreadable result file(s)" if unreadable else ""
print(
    f"venom: {passed} passed, {failed} failed, {skipped} skipped{unreadable_note} "
    f"in {suites} suite(s); exit {venom_rc}; full output: {log}"
)
sys.exit(1 if unreadable else 0)
PY

if [[ "${venom_rc}" -ne 0 ]]; then
	exit "${venom_rc}"
fi
exit "${summary_rc}"
