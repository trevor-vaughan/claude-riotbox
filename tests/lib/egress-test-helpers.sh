#!/usr/bin/env bash
# Helpers for tests/egress-launch.venom.yml and tests/egress-cli.venom.yml:
# an isolated HOME/XDG tree whose container engine is the fake in
# tests/lib/egress-fake-engine/podman (its header says what it answers),
# with the real riotbox-core from libexec/ (built by `task go:build`).

_EGRESS_HELPERS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EGRESS_REPO_ROOT="$(cd "${_EGRESS_HELPERS_DIR}/../.." && pwd)"

# egress_test_env <tmp> [engine-name]
#   Put HOME, XDG_CONFIG_HOME, XDG_DATA_HOME and RIOTBOX_SYSCONF_DIR under
#   <tmp>, and the fake engine on PATH and in CONTAINER_CMD as <engine-name>
#   (default podman). Unset the RiotBox and proxy settings a developer's
#   own session exports (it runs headroom-wrapped with Context Mode env), so
#   only what a test sets applies.
#   Exports: HOME XDG_CONFIG_HOME XDG_DATA_HOME RIOTBOX_SYSCONF_DIR PATH
#            CONTAINER_CMD FAKE_ENGINE_LOG CAPTURE EGRESS_ROOT
egress_test_env() {
	local tmp="$1" engine="${2:-podman}"
	mkdir -p "${tmp}/etc" "${tmp}/xdg/riotbox" "${tmp}/data" "${tmp}/proj" "${tmp}/bin"
	ln -s "${_EGRESS_HELPERS_DIR}/egress-fake-engine/podman" "${tmp}/bin/${engine}"
	export HOME="${tmp}" XDG_CONFIG_HOME="${tmp}/xdg" XDG_DATA_HOME="${tmp}/data"
	export RIOTBOX_SYSCONF_DIR="${tmp}/etc"
	export PATH="${tmp}/bin:${PATH}" CONTAINER_CMD="${tmp}/bin/${engine}"
	export FAKE_ENGINE_LOG="${tmp}/engine.log" CAPTURE="${tmp}/argv"
	export EGRESS_ROOT="${XDG_DATA_HOME}/riotbox-egress"
	touch "${FAKE_ENGINE_LOG}"
	unset RIOTBOX_EGRESS RIOTBOX_EGRESS_IMAGE RIOTBOX_SOCKET RIOTBOX_NETWORK \
		RIOTBOX_NESTED RIOTBOX_OVERLAY RIOTBOX_EXTRA_ARGS RIOTBOX_EXTRA_ARGS_ACK \
		RIOTBOX_HEADROOM RIOTBOX_HEADROOM_ACTIVE RIOTBOX_CONTEXT_MODE \
		CONTEXT_MODE_DIR _CONTEXT_MODE_WIRED RIOTBOX_AGENT \
		RIOTBOX_PASSTHROUGH_VARS RIOTBOX_PASSTHROUGH_EXTRA_VARS RIOTBOX_PROJECTS \
		HTTP_PROXY HTTPS_PROXY http_proxy https_proxy NO_PROXY no_proxy \
		ANTHROPIC_BASE_URL
}

# egress_launch [command...]
#   Run launch.sh as `riotbox shell` would (default command: bash), against
#   the fake engine, with RIOTBOX_DRY_RUN=1 so no session dir is written.
#   RIOTBOX_PROJECTS defaults to $HOME/proj.
egress_launch() {
	RIOTBOX_DRY_RUN=1 RIOTBOX_PROJECTS="${RIOTBOX_PROJECTS:-${HOME}/proj}" ROOT_DIR="${EGRESS_REPO_ROOT}" \
		IMAGE_NAME=riotbox bash "${EGRESS_REPO_ROOT}/libexec/launch.sh" "${@:-bash}"
}

# egress_agent_name
#   Print the agent container's name from the captured agent argv.
egress_agent_name() {
	sed -n 's/.* --name \(riotbox-[^ ]*\) .*/\1/p' "${CAPTURE}"
}

# egress_seed_session [--project <dir>]... <name> [host...]
#   Start session <name>'s proxy with riotbox-core against the fake engine,
#   as launch.sh would, allowing the hosts as the agent's and recording the
#   project dirs, so its state dir exists. Does not mark it running; see
#   egress_running.
egress_seed_session() {
	local projects=() name
	while [[ "${1:-}" == --project ]]; do
		projects+=(--project "$2")
		shift 2
	done
	name="$1"
	shift
	printf '%s\n' "$@" | "${EGRESS_REPO_ROOT}/libexec/riotbox-core" egress-up \
		--engine "${CONTAINER_CMD}" --state-root "${EGRESS_ROOT}" \
		--system-conf "${RIOTBOX_SYSCONF_DIR}/egress.conf" \
		--user-conf "${XDG_CONFIG_HOME}/riotbox/egress.conf" \
		--image test-image --session-key test --owner-pid "$$" "${projects[@]}" -- "${name}" >/dev/null
}

# egress_running <name>...
#   Make the fake engine report these sessions' proxies as running.
egress_running() {
	local name json="" sep=""
	for name in "$@"; do
		json+="${sep}{\"Names\":[\"${name}-egress\"],\"Labels\":{\"riotbox.egress\":\"${name}\",\"riotbox.egress-role\":\"gateway\"}}"
		sep=","
	done
	export FAKE_GATEWAYS_JSON="[${json}]"
}
