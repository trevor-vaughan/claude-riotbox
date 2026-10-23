#!/usr/bin/env bash
# Stub container engine for tests of host commands that ask the engine which
# RiotBox containers are running and what they mount (overlay-accept,
# overlay-reject, session-migrate).
set -euo pipefail

# Resolved now: a test may change directory before the engine runs.
_ENGINE_STUB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# install_stub_engine <dir>
#   Set CONTAINER_CMD to the stub engine, the executable
#   tests/lib/engine-stub/podman, and keep the stub's files in <dir>.
#   Exports: CONTAINER_CMD, STUB_RUNNING, STUB_PS_CALLS, STUB_INSPECT_CALLS
#
#   ${STUB_RUNNING} (absent by default: nothing runs) describes the
# containers, one mount per line:
# "<id> <source> <rw: true|false> [<state> [unlabelled]]", state "running"
# when omitted (or "created", "paused", "exited"); "unlabelled" marks a
# container without the riotbox.session label, as releases up to v0.5.3
# started. `ps --format {{.ID}}` prints each ID once: with no status filter,
# only running ones, as the engines do; with one or more `--filter
# status=<s>`, those in any listed state (the engines OR a key's values);
# with `--filter label=riotbox.session`, only labelled ones. Any other `ps`
# (the container-name probe) prints nothing.
# `container inspect <id>...` prints each ID's mounts in the NUL-separated
# form riotbox-core asks for (internal/engine),
# naming each container after its ID, and counts its calls in
# ${STUB_INSPECT_CALLS}.
# With STUB_ENGINE_FAIL set, every call fails as an unreachable engine would;
# with STUB_INSPECT_FAIL set, only `inspect` fails. IDs listed in
# STUB_GONE_IDS have exited since `ps`: an `inspect` naming one fails as podman
# does ("Error: no such object", 125) or, with STUB_GONE_STYLE=docker, as
# docker does ("Error: No such container", 1).
# With STUB_RUNNING_FROM_CALL=<n>, ${STUB_RUNNING} is consulted only from the
# n-th `ps` on (counted in ${STUB_PS_CALLS}), so a session can "start" partway
# through a command.
install_stub_engine() {
	local dir="$1"
	export CONTAINER_CMD="${_ENGINE_STUB_DIR}/engine-stub/podman"
	export STUB_RUNNING="${dir}/running"
	export STUB_PS_CALLS="${dir}/ps-calls"
	export STUB_INSPECT_CALLS="${dir}/inspect-calls"
}
