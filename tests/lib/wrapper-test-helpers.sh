#!/usr/bin/env bash
# Shared helpers for bin/riotbox dispatcher Venom tests.
# Source this file at the top of each test script.
#
# The dispatcher self-locates its install root from `readlink -f bin/riotbox`
# (the grandparent of the resolved entrypoint). To exercise its routing without
# launching a real container, we stage a fake app tree, drop a COPY of the real
# dispatcher into it, and replace every helper it can exec with a stub that
# records how it was invoked (script identity, args, and the security-relevant
# env the dispatcher exports) into a single capture file.
set -euo pipefail

# Create a staged app tree with the real dispatcher and stub helpers.
# Sets: TEST_DIR, CAPTURE
# Exports: CAPTURE
setup_wrapper_test() {
	# The privileged-mode env vars are set only by the nested-*/socket-* verbs.
	# Clear any ambient values so a host that runs RiotBox-in-RiotBox does not
	# poison the NESTED/SOCKET assertions of non-privileged cases.
	unset RIOTBOX_NESTED RIOTBOX_SOCKET || true

	TEST_DIR="$(mktemp -d)"
	mkdir -p \
		"${TEST_DIR}/app/bin" \
		"${TEST_DIR}/app/libexec" \
		"${TEST_DIR}/app/scripts" \
		"${TEST_DIR}/projects/foo" \
		"${TEST_DIR}/projects/bar"

	# Capture file the stubs append to. Absolute so the separate stub
	# processes can find it regardless of their CWD.
	CAPTURE="${TEST_DIR}/capture"
	: >"${CAPTURE}"
	export CAPTURE

	# Copy the real dispatcher and the artifacts it reads at startup. The
	# dispatcher computes its own RIOTBOX_DIR from readlink -f $0, so running
	# this copy makes ${TEST_DIR}/app the install root.
	# shellcheck disable=SC2154  # RIOTBOX_DIR is set by the Venom test runner that sources this file
	cp "${RIOTBOX_DIR}/bin/riotbox" "${TEST_DIR}/app/bin/riotbox"
	chmod +x "${TEST_DIR}/app/bin/riotbox"
	cp "${RIOTBOX_DIR}/VERSION" "${TEST_DIR}/app/VERSION"
	# Real agents tree: the dispatcher sources agents/registry.sh and validates
	# --agent against it. Stubbing agents would be fragile; use the real ones.
	cp -a "${RIOTBOX_DIR}/agents" "${TEST_DIR}/app/agents"

	# Stub every helper the dispatcher can exec/run. Each stub records its
	# identity, args, and the exported env into ${CAPTURE}. The capture path is
	# baked in at write time (unquoted heredoc) so each stub is self-contained.
	local libexec_stubs=(
		run.sh launch.sh checkpoint.sh resume.sh audit.sh
		list-sessions.sh remove-session.sh reset-session.sh install-hooks.sh
	)
	local scripts_stubs=(
		build.sh overlay.sh reown-commits.sh preflight.sh
	)
	local s
	for s in "${libexec_stubs[@]}"; do
		_write_capture_stub "${TEST_DIR}/app/libexec/${s}" "${s}"
	done
	for s in "${scripts_stubs[@]}"; do
		_write_capture_stub "${TEST_DIR}/app/scripts/${s}" "${s}"
	done

	# ensure-image.sh is a no-op gate (the dispatcher calls it before most
	# session verbs). Keep it silent so it never pollutes assertions.
	cat >"${TEST_DIR}/app/libexec/ensure-image.sh" <<'ENSURE'
#!/usr/bin/env bash
exit 0
ENSURE
	chmod +x "${TEST_DIR}/app/libexec/ensure-image.sh"

	# detect-mounts.sh feeds the `mounts` verb, which reads its output with
	# `while read -r _flag path`. Emit a couple of "flag path" lines so the
	# verb produces visible output.
	cat >"${TEST_DIR}/app/scripts/detect-mounts.sh" <<'MOUNTS'
#!/usr/bin/env bash
echo "-v /home/llm/.config"
echo "-v /home/llm/.cache"
MOUNTS
	chmod +x "${TEST_DIR}/app/scripts/detect-mounts.sh"
}

# _write_capture_stub <dest> <scriptname>
#   Write an executable stub at <dest> that appends a capture record. The
#   absolute ${CAPTURE} path is expanded into the stub at write time so the
#   stub has no runtime dependency on the parent's environment.
_write_capture_stub() {
	local dest="$1" name="$2"
	cat >"${dest}" <<STUB
#!/usr/bin/env bash
{
  echo "CALL ${name} \$*"
  echo "ENV PROJECTS=\${RIOTBOX_PROJECTS:-} AGENT=\${RIOTBOX_AGENT:-} NESTED=\${RIOTBOX_NESTED:-} SOCKET=\${RIOTBOX_SOCKET:-}"
} >> "${CAPTURE}"
STUB
	chmod +x "${dest}"
}

# Print the captured dispatcher routing records to stdout (for assertions).
print_capture() {
	cat "${CAPTURE}"
}
