#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# chcon-stub.sh — Test helper that asserts mount-projects.sh never invokes
# chcon directly. Source from a venom test step's `script:` body.
#
# Side effects:
#   - Creates a stub `chcon` binary on PATH that records each invocation to
#     "${CHCON_MARKER}" and exits 0.
#   - Exports CHCON_MARKER pointing at the marker file.
#
# Assertion helper:
#   chcon_marker_clean   prints "CHCON_NOT_CALLED" if the marker is empty
#                        or absent. Tests assert ShouldContainSubstring on
#                        that string.
#
# Cleanup: the stub directory is added to the caller's PATH for the rest
# of the test step. The caller's `trap '... rm -rf' EXIT` is expected to
# tear it down — pass CHCON_STUB_DIR into the trap if you set one.
# ─────────────────────────────────────────────────────────────────────────────
CHCON_STUB_DIR="$(mktemp -d)"
CHCON_MARKER="${CHCON_STUB_DIR}/chcon-calls"
export CHCON_STUB_DIR CHCON_MARKER

cat >"${CHCON_STUB_DIR}/chcon" <<'STUB'
#!/usr/bin/env bash
printf 'chcon called: %s\n' "$*" >>"${CHCON_MARKER}"
exit 0
STUB
chmod +x "${CHCON_STUB_DIR}/chcon"

PATH="${CHCON_STUB_DIR}:${PATH}"
export PATH

chcon_marker_clean() {
	if [[ ! -s "${CHCON_MARKER}" ]]; then
		echo "CHCON_NOT_CALLED"
	else
		echo "CHCON_WAS_CALLED:"
		cat "${CHCON_MARKER}"
	fi
}
