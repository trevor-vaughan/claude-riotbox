#!/usr/bin/env bash
# Helpers for suites that read a real context-mode 2.x store through
# container/context-mode-stats.mjs.
#
# The stores are built from tests/fixtures/context-mode-2-events.sql, which is
# upstream's events DDL copied out of a store the real 2.1.4 hook wrote, and
# filled through node:sqlite by tests/lib/context-mode-store.mjs. The real hook
# is not run here: neither the test image nor a bare host has the pinned
# package. The image build runs the reader against a store the real hook wrote.
#
# Both the fixture driver and the reader need Node 24 or later (node:sqlite
# with readOnly and timeout, the floor context-mode 2.x itself enforces). The
# test image installs one and declares RIOTBOX_REQUIRE_CM_NODE=1 beside it, the
# way it declares RIOTBOX_REQUIRE_GIT_AI for git-ai. Cases that need Node call
# cm_require_node first: there a missing Node fails the case, and on a bare
# host it is reported as a skip, never as a pass.
#
# Callers set RIOTBOX_DIR to the repo root before sourcing.

# cm_node_ok
# 0 when `node` on PATH is version 24 or later.
cm_node_ok() {
	command -v node >/dev/null 2>&1 || return 1
	node -e 'process.exit(Number(process.versions.node.split(".")[0]) >= 24 ? 0 : 1)' 2>/dev/null
}

# cm_require_node <sentinel>
# Return when Node 24 is usable. Otherwise exit the calling testcase script:
# with status 1 when the environment declares RIOTBOX_REQUIRE_CM_NODE=1, and
# with status 0 printing "<sentinel>=SKIPPED" otherwise. Callers assert on
# "<sentinel>=(pass|SKIPPED)", so a skip shows as SKIPPED in the output and
# never as the pass sentinel.
cm_require_node() {
	cm_node_ok && return 0
	if [[ "${RIOTBOX_REQUIRE_CM_NODE:-0}" == "1" ]]; then
		echo "FAIL: RIOTBOX_REQUIRE_CM_NODE=1 but no Node 24 or later is on PATH — this store case would otherwise skip"
		exit 1
	fi
	echo "SKIP: needs Node 24 or later on PATH for node:sqlite"
	echo "$1=SKIPPED"
	exit 0
}

# cm_stats_shim <path>
# Write an executable at <path> that runs the repo's reader on PATH's node, the
# shape the image generates at CONTEXT_MODE_STATS_BIN with the pinned Node.
cm_stats_shim() {
	local reader
	# shellcheck disable=SC2154  # RIOTBOX_DIR is set by the Venom test runner that sources this file
	reader="$(cd "${RIOTBOX_DIR}" && pwd)/container/context-mode-stats.mjs" || return 1
	printf '#!/bin/sh\nexec node --no-warnings "%s" "$@"\n' "${reader}" >"$1" || return 1
	chmod +x "$1"
}

# cm_store <rows|purge|lock> <db> [arg]
# Run the fixture driver; see tests/lib/context-mode-store.mjs for each verb.
cm_store() {
	node --no-warnings "${RIOTBOX_DIR}/tests/lib/context-mode-store.mjs" "$@"
}
