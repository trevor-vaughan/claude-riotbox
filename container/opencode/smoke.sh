#!/usr/bin/env bash
# Build-time smoke test for OpenCode V2 and the plugins RiotBox wires into it.
#
# The OpenCode install floats (Containerfile), and V1 plugins do not load in
# V2. A release that breaks a wired plugin must fail the image build here
# rather than ship sessions where the plugin silently does nothing. The venom
# suites cannot catch it: they run a fake `opencode`.
#
# Two halves:
#   opencode_smoke_check — decides pass/fail from `opencode api plugin.list`
#     JSON. Unit-tested by tests/opencode-smoke.venom.yml.
#   opencode_smoke_run — wires a throwaway HOME the way a session does, asks
#     the real binary for its plugin list, and runs the check. Exercised only
#     by the image build.
#
# Facts this relies on (verified against OpenCode v2.2.5, `opencode --version`
# prints "opencode v2.2.5"):
#   * `curl -fsSL https://opencode.ai/v2/install | bash -s -- --no-modify-path`
#     installs non-interactively to $HOME/.opencode/bin/opencode (plus an
#     `opencode2` shim). Other flags: --version <v>, --binary <path>.
#   * `opencode api plugin.list --param 'location[directory]=<dir>'` prints
#     {"location":{"directory":<dir>},"data":[Plugin.Info...]}, builtins
#     included (source.type "builtin"). `--param directory=<dir>` is ignored;
#     without a location the server's own cwd is used.
#   * The server answers plugin.list from its current inventory without
#     waiting for activation, so the first answer can be "data":[]. With
#     `--standalone` the private server serves only that first request, so
#     the list is always empty; query the background service (which a plain
#     `opencode api` starts on demand) and poll until the plugins appear.
#   * A plugin that fails to load is listed with no id, its source path,
#     state.status "failed", state.error ("Plugin failed to load" for a module
#     that throws, the PluginModule.LoadError message for a bad export) and
#     state.ref (packages/core/src/plugin/supervisor.ts:77).
#   * The background service (`opencode serve --service`) reads
#     OPENCODE_CONFIG_CONTENT from its own environment
#     (packages/cli/src/server-process.ts:133), and the client that starts
#     it passes its whole environment on
#     (packages/client/src/service-contender.ts:23).
#     A client attaching to a service that is already running contributes
#     nothing, so the env has to be on whichever process starts the service.
#   * Plugin ids, read from the live list: "context-mode", "git-ai",
#     "headroom". The first two are global plugins in
#     $OPENCODE_CONFIG_DIR/plugins/; headroom's is the _dist DIRECTORY inside
#     the headroom wheel, named in OPENCODE_CONFIG_CONTENT's "plugin" array.
#     V2 skips a configured plugin FILE (core/src/config/plugin/source.ts:155),
#     and headroom 0.43.0 configures the directory for exactly that reason
#     (providers/opencode/runtime.py:114, headroom_opencode_plugin_path).
#
# How the driver reaches headroom's plugin. `headroom wrap opencode` builds
# OPENCODE_CONFIG_CONTENT and runs opencode with the args after `--`. It adds
# `--standalone` only to the interactive launches (root TUI, `run`, `mini`)
# and leaves management subcommands such as `service` alone
# (runtime.py:40 and :75, with_opencode_standalone). So the driver starts the
# background service THROUGH wrap (`... -- service start`): the service
# inherits exactly the environment wrap builds for a session, and nothing of
# headroom's is reproduced here. Polling then uses the plain binary, whose
# environment the already-running service ignores. A session reaches the
# same config by the other road: wrap adds `--standalone` to the TUI, and the
# private server reads the same environment.

# opencode_smoke_check <list.json> <expected-id>...
# Exit 0: every expected id is listed active and nothing failed.
# Exit 1: a plugin failed, an expected id is missing, or the input is not a
#         plugin list. The reason goes to stderr.
# Exit 2: called without expected ids (a caller bug, not a smoke failure).
opencode_smoke_check() {
	local list="$1"
	shift
	if [[ $# -eq 0 ]]; then
		echo "opencode smoke: no expected plugin ids given" >&2
		return 2
	fi
	if ! jq -e '.data | type == "array"' "${list}" >/dev/null 2>&1; then
		echo "opencode smoke: output is not a plugin list:" >&2
		head -c 2000 "${list}" >&2
		echo >&2
		return 1
	fi

	local failed
	failed="$(jq -r '.data[] | select(.state.status != "active")
		| "\(.id // "-")\t\(.source.path // .source.target // .source.type)\t\(.state.error // .state.status)"' "${list}")"
	if [[ -n "${failed}" ]]; then
		echo "opencode smoke: plugins failed to load (id, source, error):" >&2
		printf '  %s\n' "${failed}" >&2
		return 1
	fi

	local id missing=()
	for id in "$@"; do
		jq -e --arg id "${id}" 'any(.data[]; .id == $id and .state.status == "active")' "${list}" >/dev/null ||
			missing+=("${id}")
	done
	if [[ ${#missing[@]} -gt 0 ]]; then
		echo "opencode smoke: expected plugins not loaded: ${missing[*]}" >&2
		return 1
	fi
}

# opencode_smoke_run <riotbox-dir> — wire a throwaway HOME the way a session
# does, then poll the plugin list of the real binary and check it.
# <riotbox-dir> is the image's ~/.riotbox: agents/, lib/ and the container
# scripts at its top level, as the Containerfile copies them.
#
# Offline: no provider key is set, headroom's proxy is not started (the
# plugin only reads its URL), and the build has no network requirement here.
#
# The body is a subshell so that set -e, the HOME switch and the cleanup trap
# stay inside it. Call it as a plain command: under `if` or `||` bash ignores
# set -e in the whole subshell.
opencode_smoke_run() (
	set -euo pipefail
	local riotbox_dir="$1"
	# Polling stops at this many seconds. The plugins appeared within about
	# 2 s in testing; upstream's own service smoke allows 10 s for discovery
	# (packages/cli/script/service-smoke.ts:200, waitForPlugin).
	local poll_seconds=30
	local expected=(context-mode git-ai headroom)
	local usersite real_name
	# Not local: the EXIT trap reads them after the function has returned.
	# The subshell keeps them from the caller all the same.
	started=0 git_ai_started=0

	# Sourced before HOME moves: context-mode-setup.sh and git-ai-setup.sh
	# fix CONTEXT_MODE_BIN and RIOTBOX_GIT_AI_BIN from HOME when sourced, and
	# those binaries live in the image's home, not the throwaway one. The
	# list mirrors what container/entrypoint.sh sources for these steps.
	# shellcheck source=scripts/lib/json-write.sh
	source "${riotbox_dir}/lib/json-write.sh"
	# shellcheck source=scripts/lib/egress-prompt.sh
	source "${riotbox_dir}/lib/egress-prompt.sh"
	# shellcheck source=container/context-mode-setup.sh
	source "${riotbox_dir}/context-mode-setup.sh"
	# shellcheck source=container/git-ai-setup.sh
	source "${riotbox_dir}/git-ai-setup.sh"
	# shellcheck source=agents/registry.sh
	source "${riotbox_dir}/agents/registry.sh"

	# The image's PATH puts the agent-wrapper shims first. The smoke tests the
	# plugins, not the wrapper, so put the real binary in front, found the way
	# the wrapper finds it. `headroom wrap` resolves `opencode` on PATH too.
	real_name="$(agent_call opencode real_binary)"
	# shellcheck source=container/find-real-bin.sh
	source "${riotbox_dir}/find-real-bin.sh" "${real_name}"
	if [[ -z "${REAL_BIN}" ]]; then
		echo "opencode smoke: no real opencode binary on PATH" >&2
		return 1
	fi
	PATH="$(dirname "${REAL_BIN}"):${PATH}"
	# headroom is a `pip install --user` package; its user site is found
	# through HOME, so pin it first (as the headroom layer's own smoke does).
	usersite="$(python3 -m site --user-site)"
	export PYTHONPATH="${usersite}"

	home="$(mktemp -d)"
	list="${home}/plugin-list.json"
	# The stops must outlive every failure below: the opencode service and
	# the git-ai daemon (install-hooks starts it) would otherwise keep running
	# against the directory this removes, and outlive the RUN step.
	# `git-ai bg shutdown` returns before the daemon exits; the daemon removes
	# its daemon.pid.json on the way out, so wait for that before the rm.
	# shellcheck disable=SC2317  # invoked indirectly, by the EXIT trap
	_opencode_smoke_cleanup() {
		local pidfile="${home}/.git-ai/internal/daemon/daemon.pid.json"
		local rc=0
		if [[ ${started} -eq 1 ]]; then
			timeout 10 opencode service stop >/dev/null 2>&1 || rc=$?
			if [[ ${rc} -eq 124 ]]; then
				echo "opencode smoke: WARN: opencode service stop timed out after 10 s" >&2
			elif [[ ${rc} -ne 0 ]]; then
				echo "opencode smoke: WARN: opencode service stop failed (exit ${rc})" >&2
			fi
		fi
		if [[ ${git_ai_started} -eq 1 ]]; then
			if ! "${RIOTBOX_GIT_AI_BIN}" bg shutdown >/dev/null 2>&1; then
				echo "opencode smoke: WARN: git-ai bg shutdown failed" >&2
			fi
			for _ in {1..50}; do
				[[ -e "${pidfile}" ]] || break
				sleep 0.1
			done
			if [[ -e "${pidfile}" ]]; then
				echo "opencode smoke: WARN: the git-ai daemon was still running 5 s after shutdown" >&2
			fi
		fi
		rm -rf -- "${home}"
	}
	trap _opencode_smoke_cleanup EXIT

	# A session's layout (container/entrypoint.sh exports OPENCODE_CONFIG_DIR),
	# with every XDG root in the throwaway HOME as upstream's smoke has them.
	export HOME="${home}" TMPDIR="${home}/tmp"
	export OPENCODE_CONFIG_DIR="${HOME}/.config/opencode"
	export XDG_CONFIG_HOME="${HOME}/.config" XDG_DATA_HOME="${HOME}/.local/share"
	export XDG_STATE_HOME="${HOME}/.local/state" XDG_CACHE_HOME="${HOME}/.cache"
	export RIOTBOX_AGENT=opencode RIOTBOX_CONTEXT_MODE=1
	mkdir -p "${TMPDIR}"
	cd "${HOME}"

	# The entrypoint's order: the agent's container setup (opencode.jsonc),
	# then Context Mode, then git-ai. Only opencode's setup runs: the other
	# agents' setups write nothing opencode reads.
	agent_call opencode container_setup
	context_mode_setup
	if [[ "${_CONTEXT_MODE_WIRED:-}" != "1" ]]; then
		echo "opencode smoke: context_mode_setup did not wire opencode (its warning is above)" >&2
		return 1
	fi
	# install-hooks wires opencode only when ~/.config/opencode exists
	# (git-ai src/mdm/agents/opencode.rs); container_setup has made it.
	git_ai_write_config
	git_ai_started=1
	# shellcheck disable=SC2310 # it warns and returns 1; the smoke names the step
	if ! git_ai_install_hooks; then
		echo "opencode smoke: git-ai install-hooks failed" >&2
		return 1
	fi

	# The delegated flags of agents/opencode/headroom-exec.sh; keep the two in
	# step. The port is never dialled: no proxy runs, and the plugin only
	# records the URL. Every opencode call below is bounded: the CLI's
	# requests carry no timeout of their own
	# (packages/cli/src/commands/handlers/api.ts:36-42), and a build step
	# that hangs is worse than one that fails.
	started=1
	if ! timeout 60 headroom wrap opencode --no-proxy --no-mcp --no-serena --port 8787 \
		-- service start >&2; then
		echo "opencode smoke: starting the service through headroom wrap failed or took over 60 s" >&2
		return 1
	fi

	# The first answers are expected to be empty or partial. Poll until the
	# check passes; a failed state can be transient while plugins are still
	# being discovered, so it is judged only at the deadline.
	local deadline=$((SECONDS + poll_seconds))
	while :; do
		# shellcheck disable=SC2310 # a failing check means poll again
		if timeout 10 opencode api plugin.list --param "location[directory]=${HOME}" \
			>"${list}" 2>"${home}/api.err" &&
			opencode_smoke_check "${list}" "${expected[@]}" 2>/dev/null; then
			echo "opencode smoke: ${expected[*]} loaded" >&2
			return 0
		fi
		[[ ${SECONDS} -lt ${deadline} ]] || break
		sleep 0.5
	done
	echo "opencode smoke: the plugin list did not pass within ${poll_seconds}s; the last answer:" >&2
	if [[ -s "${home}/api.err" ]]; then
		cat "${home}/api.err" >&2
	fi
	# Run again for its report on the last answer: it failed in the loop.
	# shellcheck disable=SC2310 # the smoke fails here whatever it returns
	opencode_smoke_check "${list}" "${expected[@]}" || :
	# A plain `opencode api` starts a service of its own when none is running,
	# and that one never saw headroom's environment.
	echo "opencode smoke: if only headroom is missing, the service started through headroom wrap may have died and been replaced by one without its config" >&2
	return 1
)

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	set -euo pipefail
	opencode_smoke_run "${1:?usage: smoke.sh <riotbox-dir>}"
fi
