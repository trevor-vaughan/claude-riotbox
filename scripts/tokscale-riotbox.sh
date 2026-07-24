#!/usr/bin/env bash
#
# tokscale-riotbox.sh — view unified tokscale usage across riotbox sessions,
# with zero telemetry.
#
# riotbox isolates each run's agent home under
#   $XDG_DATA_HOME/riotbox/<session-key>/
# with Claude Code transcripts at  <session>/projects/<slug>/*.jsonl
# and opencode data at             <session>/.local-share-opencode/{storage,project}/...
# tokscale, left alone, scans only the ONE native home (~/.claude,
# ~/.local/share/opencode), so it never sees riotbox work.
#
# This wrapper leaves the native home scan intact and adds every riotbox session
# as an extra scan root via tokscale's TOKSCALE_EXTRA_DIRS — comma-separated
# `client:path` pairs, merged and path-deduped into the default scan (available
# since tokscale 2.0.14). The result is one report covering native + all
# containerized agent work.
#
# Nothing is copied: sessions are scanned live from their real location, so a
# `riotbox reset-session` drops that session's usage from the report. Export
# from tokscale first if you need to keep history.
#
# Zero telemetry: tokscale runs inside `unshare -rn` (loopback-only netns), so
# submission is physically impossible, not merely unused. Cost columns read 0.0
# offline; token counts are exact.
#
# tokscale binary resolution (in order): $TOKSCALE_BIN, then a `tokscale` on
# PATH, then an already-primed npx cache, then a one-time `npx tokscale@latest`
# fetch. The npx fetch needs the network, so it runs BEFORE we enter the
# isolated namespace; after that first prime every run is fully offline (the
# native binary is exec'd directly, never via `npx @latest`, which would try to
# re-check the registry). Clear the npx cache to pick up a newer tokscale.
#
# Usage (normally invoked as `riotbox tokscale [args...]`):
#   tokscale-riotbox.sh [tokscale args...]   # run tokscale over native + riotbox
#   tokscale-riotbox.sh -c opencode --month  # args pass through to tokscale
#   tokscale-riotbox.sh                      # no args → tokscale TUI
#
# Env overrides:
#   RIOTBOX_DATA_DIR  riotbox session root (default: ${XDG_DATA_HOME:-~/.local/share}/riotbox)
#   TOKSCALE_BIN      tokscale path        (default: PATH, else npx-cached, else fetched)

# -E (errtrace): without it the ERR trap is NOT inherited by functions or
# subshells, so a failure inside a helper would exit silently with no line
# number. See the trap below.
set -Eeuo pipefail
trap 'echo "tokscale-riotbox: failed at line ${LINENO}" >&2' ERR

RIOTBOX_DATA_DIR="${RIOTBOX_DATA_DIR:-${XDG_DATA_HOME:-${HOME}/.local/share}/riotbox}"
TOKSCALE_BIN="${TOKSCALE_BIN:-}"
NPX_CACHE="${NPM_CONFIG_CACHE:-${HOME}/.npm}/_npx"

# Resolve a runnable tokscale binary, priming the npx cache if needed. Any
# network work happens HERE, before the isolated exec. Prints the path on
# success or nothing on failure, and always returns 0 — the caller treats empty
# output as failure (a non-zero return would trip `set -e` on the command
# substitution before the caller could print its own diagnostic).
resolve_tokscale_bin() {
	if [[ -n "${TOKSCALE_BIN}" ]]; then
		printf '%s\n' "${TOKSCALE_BIN}"
		return 0
	fi
	# `|| true` on each probe: these commands are EXPECTED to fail (binary/dir
	# absent) and are handled below, but under `set -E` a bare non-zero inside a
	# command substitution would trip the ERR trap. `-print -quit` returns the
	# first match without a `head` pipe (no SIGPIPE, stops early).
	local p
	p="$(command -v tokscale 2>/dev/null || true)"
	if [[ -n "${p}" ]]; then
		printf '%s\n' "${p}"
		return 0
	fi
	local cached
	cached="$(find "${NPX_CACHE}" -type f -path '*@tokscale/cli-*/bin/tokscale' -print -quit 2>/dev/null || true)"
	if [[ -z "${cached}" ]] && command -v npx >/dev/null 2>&1; then
		echo "tokscale-riotbox: priming tokscale via npx (one-time, needs network)…" >&2
		npx --yes tokscale@latest --version >/dev/null 2>&1 || true
		cached="$(find "${NPX_CACHE}" -type f -path '*@tokscale/cli-*/bin/tokscale' -print -quit 2>/dev/null || true)"
	fi
	[[ -n "${cached}" ]] && printf '%s\n' "${cached}"
	return 0
}

# Build tokscale's TOKSCALE_EXTRA_DIRS value: one `client:path` entry per live
# riotbox session home, comma-joined. Claude sessions expose a projects/ dir
# (tokscale recurses it for *.jsonl); opencode exposes its data dir — we add both
# the data root and its storage/message subdir so tokscale finds usage whether it
# roots the opencode scan at the home dir or at the sessions dir (redundant hits
# are path-deduped by tokscale). Runs in the caller's command-substitution
# subshell, so `nullglob` here does not leak. Prints the joined value, or nothing
# when there are no sessions.
build_extra_dirs() {
	local src="${RIOTBOX_DATA_DIR}"
	[[ -d "${src}" ]] || return 0
	shopt -s nullglob
	local session ocdata entries=()
	for session in "${src}"/*/; do
		session="${session%/}"
		[[ -d "${session}/projects" ]] && entries+=("claude:${session}/projects")
		ocdata="${session}/.local-share-opencode"
		if [[ -d "${ocdata}" ]]; then
			entries+=("opencode:${ocdata}")
			[[ -d "${ocdata}/storage/message" ]] && entries+=("opencode:${ocdata}/storage/message")
		fi
	done
	[[ ${#entries[@]} -gt 0 ]] || return 0
	local IFS=,
	printf '%s' "${entries[*]}"
}

# Run tokscale with the network physically absent. unshare -rn works rootless
# (it only needs unprivileged user namespaces, which rootless podman already
# requires), so isolation is mandatory here — we never fall back to an
# un-isolated run.
if ! command -v unshare >/dev/null 2>&1; then
	echo "tokscale-riotbox: 'unshare' not found; refusing to run tokscale without network isolation" >&2
	exit 1
fi

# Resolve (and if necessary fetch) tokscale now, while the network is still
# reachable — the exec below has none.
tokscale_bin="$(resolve_tokscale_bin)"
if [[ -z "${tokscale_bin}" ]]; then
	echo "tokscale-riotbox: could not find or fetch tokscale." >&2
	echo "  Install tokscale, put it on PATH, set TOKSCALE_BIN, or install npx so it can be fetched." >&2
	exit 1
fi

# Native HOME is left intact so tokscale scans your real ~/.claude and
# ~/.local/share/opencode live; TOKSCALE_EXTRA_DIRS layers every riotbox session
# on top. Both are read-only to tokscale. unshare -rn removes the network so no
# usage can be submitted.
extra_dirs="$(build_extra_dirs)"
exec unshare -rn env \
	TOKSCALE_EXTRA_DIRS="${extra_dirs}" \
	"${tokscale_bin}" "$@"
