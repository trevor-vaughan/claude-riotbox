#!/usr/bin/env bash
# Shared environment neutralisation for the container/plugin-setup.sh Venom
# suite. Source this file in each test script, after HOME is exported.
#
# No `set -euo pipefail` here, deliberately: this is sourced into scripts that
# have already chosen their own shell options, and tightening them from a
# helper would change how every case in the suite fails.

# Clear the ambient environment these suites test against, then pin the
# Context Mode toggle to "${1}" — "on" or "off".
#
# Two groups, and the difference is worth keeping straight because this list is
# the maintenance contract. RIOTBOX_CONTEXT_MODE, RIOTBOX_PLUGINS and
# RIOTBOX_CM_PLUGIN_DIR are what container/plugin-setup.sh itself reads, beside
# HOME, which every case sets for itself. CONTEXT_MODE_DIR, RIOTBOX_AGENT,
# _CONTEXT_MODE_WIRED and RIOTBOX_HEADROOM belong to the wiring around it —
# container/context-mode-setup.sh, container/agent-wrapper.sh and the summary
# scripts — and are cleared here because the same cases reach that code and a
# session running these suites exports them.
#
# One place rather than a line per case, because the ambient values are real:
# libexec/launch.sh forwards RIOTBOX_PLUGINS and RIOTBOX_CONTEXT_MODE into the
# container these suites run in, and the Containerfile sets
# RIOTBOX_CM_PLUGIN_DIR image-wide. Each of the three changes what a case tests
# rather than merely perturbing it:
#
#   * RIOTBOX_PLUGINS makes step 4 run `claude plugin install` for every name it
#     does not find registered — a real Node spawn against the network, which
#     also writes the fixture registry the case is about to assert on.
#   * RIOTBOX_CM_PLUGIN_DIR points the staged-tree lookup at the image's own
#     Context Mode instead of the tree the case staged under its temporary HOME,
#     so a case that staged nothing silently registers something.
#   * RIOTBOX_CONTEXT_MODE decides steps 3 and 5, which every case now
#     traverses whether or not it is about Context Mode.
#
# It is unset, not redirected: isolation is "the environment says nothing", and
# the cases that stage a tree export RIOTBOX_CM_PLUGIN_DIR themselves after
# this call, which is fixture rather than isolation. The toggle takes an
# argument for the same reason — a default here would be a case's premise
# hidden in a helper — and "off" unsets it because that is what the launcher
# does with the feature off, so `off` and the production shape agree.
plugin_setup_test_env() {
	case "${1:-}" in
	on) export RIOTBOX_CONTEXT_MODE=1 ;;
	off) unset RIOTBOX_CONTEXT_MODE ;;
	*)
		echo "plugin_setup_test_env: want 'on' or 'off', got '${1:-}'" >&2
		return 1
		;;
	esac
	unset CONTEXT_MODE_DIR RIOTBOX_AGENT _CONTEXT_MODE_WIRED RIOTBOX_HEADROOM \
		RIOTBOX_PLUGINS RIOTBOX_CM_PLUGIN_DIR
}

# Refuse to run a case whose premise is a directory mode, unless the uid can be
# stopped by one.
#
# The cases that reach json_write_atomic's failure path do it by taking write
# permission off the plugins directory, which root ignores — the write would
# succeed and the case would fail somewhere further down, blaming the code for
# the runner. CI already runs one suite as uid 0 (`task test:as-root`, for
# tests/doctor-context-mode.venom.yml), so this is a state the repo reaches
# rather than a hypothetical. Failing here says which it was.
plugin_setup_test_needs_unprivileged() {
	local uid
	uid="$(id -u)"
	if [[ "${uid}" != "0" ]]; then
		return 0
	fi
	echo "FAIL - this case needs an unprivileged uid: root writes through the directory mode it uses to fail json_write_atomic"
	return 1
}
