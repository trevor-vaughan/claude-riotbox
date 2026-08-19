#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# detect-mounts.sh — Auto-detect home directory paths to mount into the riotbox.
#
# Output formats (--format=<podman|triple>, default podman):
#   podman  one `-v host:container[:flag]` line per mount (current behavior)
#   triple  one `host:container:mode` line per mount, where mode is `rw` or
#           `ro`. Intended for downstream config generators / tests that need
#           a structured mount table without regex-parsing podman flags.
#
# Separates mounts into:
#   1. Functional dirs (settings, scripts) — bind mounts with :z (rw or ro)
#   2. Package caches — named volumes (rw, no SELinux relabeling needed)
#   3. User-defined mounts from mounts.conf — bind mounts, ro unless the
#      entry opts in with a trailing `:rw`
#
# Sensitive directories (.ssh, .gnupg, .kube, .aws, etc.) are NEVER mounted
# by the auto-detection. Users can explicitly mount files via mounts.conf.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

CONTAINER_HOME="/home/llm"
RIOTBOX_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/riotbox"
# System config dir (default /etc/riotbox); overridable for relocatable
# installs and tests. mounts.conf entries from here are unioned with the
# user's XDG file below.
RIOTBOX_SYSCONF_DIR="${RIOTBOX_SYSCONF_DIR:-/etc/riotbox}"

# Source the config layer for the toggles this script honours (today:
# RIOTBOX_READONLY, which downgrades `:rw` entries in mounts.conf). The files
# use `: "${VAR:=default}"`, so sourcing user (XDG) before system (/etc) yields
# env > $XDG_CONFIG_HOME/riotbox > /etc/riotbox > built-in default. This mirrors
# launch.sh and the script-mode block of mount-projects.sh: `riotbox mounts`
# invokes this script directly, with no launch.sh above it, and the preview it
# prints has to match what a real launch would mount.
#
# Unlike launch.sh, this script's stdout IS the mount list — launch.sh
# word-splits it straight into the podman argv. The config layer is arbitrary
# user shell (the shipped stub demonstrates `$(cmd)` usage), so each source
# runs with stdout redirected to stderr: a stray echo in someone's config
# stays a diagnostic instead of becoming a container argument. A config that
# ends on a non-zero status is reported and tolerated rather than killing the
# launch at launch.sh's `MOUNTS=` assignment with no explanation.
_dm_source_config() {
	local file="$1"
	[[ -f "${file}" ]] || return 0
	# shellcheck disable=SC1090,SC1091  # user-provided path, resolved at run time
	if ! { source "${file}"; } >&2; then
		echo "WARN: ${file}: config exited non-zero; continuing without it" >&2
	fi
}
_dm_source_config "${RIOTBOX_CONFIG_DIR}/config"
_dm_source_config "${RIOTBOX_SYSCONF_DIR}/config"
unset -f _dm_source_config

# ── Output format ───────────────────────────────────────────────────────────
OUTPUT_FORMAT="podman"
for arg in "$@"; do
	case "${arg}" in
	--format=podman) OUTPUT_FORMAT="podman" ;;
	--format=triple) OUTPUT_FORMAT="triple" ;;
	--format=*)
		echo "ERROR: unknown --format value: ${arg#--format=}" >&2
		echo "       allowed: podman, triple" >&2
		exit 2
		;;
	*)
		echo "ERROR: unknown argument: ${arg}" >&2
		exit 2
		;;
	esac
done

# Emit one mount in the active format.
#   $1 host path
#   $2 container path
#   $3 mode: rw (default) or ro
# In podman mode we preserve the existing flag shape: rw mounts get bare ":z"
# (or no suffix for named volumes), ro mounts get ":ro,z". Whether to add :z
# is controlled by the optional 4th arg (selinux=z|none, default z).
emit_mount() {
	local host="$1" container="$2" mode="${3:-rw}" selinux="${4:-z}"
	case "${OUTPUT_FORMAT}" in
	triple)
		printf '%s:%s:%s\n' "${host}" "${container}" "${mode}"
		;;
	podman)
		local suffix=""
		case "${mode}:${selinux}" in
		rw:z) suffix=":z" ;;
		rw:none) suffix="" ;;
		ro:z) suffix=":ro,z" ;;
		ro:none) suffix=":ro" ;;
		*)
			echo "ERROR: emit_mount: unknown mode:selinux '${mode}:${selinux}'" >&2
			return 1
			;;
		esac
		printf -- '-v %s:%s%s\n' "${host}" "${container}" "${suffix}"
		;;
	*)
		echo "ERROR: emit_mount: unknown OUTPUT_FORMAT '${OUTPUT_FORMAT}'" >&2
		return 1
		;;
	esac
}

# ── Functional mounts ────────────────────────────────────────────────────────
# These are directories the container needs for correct operation.
# Bind-mounted with :z because they're small and need SELinux relabeling.
FUNCTIONAL_MOUNTS=(
	# User scripts and tools
	"bin"
	# RiotBox config (plugins.conf, etc.)
	".config/riotbox"
)

# ── Auth tokens ───────────────────────────────────────────────────────────────
# Credentials (~/.claude/.credentials.json) are bind-mounted RW by
# mount-projects.sh as a nested mount inside the session dir. This lets
# Claude Code refresh OAuth tokens in-session with writes going directly
# to the host file (no copy/writeback needed).
# Config (~/.claude.json) is copied into the session dir for account metadata.
# CLAUDE_CONFIG_DIR is set in the entrypoint so Claude Code finds both files
# inside the bind-mounted session dir.

# ── RiotBox session data ─────────────────────────────────────────────────────
# Session isolation is handled by mount-projects.sh, which mounts a
# project-specific subdirectory of $XDG_DATA_HOME/riotbox/ as ~/.claude.
# The real ~/.claude is NEVER mounted — this prevents an autonomous
# container from reading your host conversation history.

# ── Cache mounts ─────────────────────────────────────────────────────────────
# Named volumes for package caches. These avoid the SELinux relabeling
# penalty of bind mounts with :z — named volumes get the correct label
# (container_file_t) automatically. The tradeoff is that caches are not
# shared with the host, but this avoids relabeling gigabytes of small
# files on every container start.
CACHE_MOUNTS=(
	# volume-name              container-path
	"riotbox-cache-npm          .npm"
	"riotbox-cache-cargo        .cargo/registry"
	"riotbox-cache-go           go/pkg"
	"riotbox-cache-pip          .cache/pip"
	"riotbox-cache-uv           .cache/uv"
	"riotbox-cache-bundler      .bundle/cache"
	"riotbox-cache-m2           .m2/repository"
	"riotbox-cache-gradle       .gradle/caches"
	"riotbox-cache-bun          .bun/install"
	# opencode installs its configured plugins (npm + git) here via `bun
	# install` at startup. Persisting it across sessions means the ~15s
	# cold install happens once; later sessions resolve plugins from the
	# warm cache in ~2s, offline. Built inside the container, so the native
	# deps match the container platform regardless of the host OS.
	"riotbox-cache-opencode     .cache/opencode"
)

# ── Sensitive directories — NEVER mount these ────────────────────────────────
# Listed here for documentation; the script uses an allowlist (above),
# not a blocklist, so these are excluded by default:
#   .ssh  .gnupg  .kube  .aws  .config/gcloud  .docker/config.json
#   .azure  .oci  .vault-token  .netrc

# ── Generate mount flags ────────────────────────────────────────────────────
for rel in "${FUNCTIONAL_MOUNTS[@]}"; do
	src="${HOME}/${rel}"
	if [[ -e "${src}" ]]; then
		emit_mount "${src}" "${CONTAINER_HOME}/${rel}" ro z
	fi
done

for entry in "${CACHE_MOUNTS[@]}"; do
	read -r vol_name rel_path <<<"${entry}"
	# Named volumes get container_file_t labelling automatically; no :z.
	emit_mount "${vol_name}" "${CONTAINER_HOME}/${rel_path}" rw none
done

# ── User-defined mounts from mounts.conf ─────────────────────────────────────
# Additional files/directories to mount into the container, listed one per
# line. Entries are read from BOTH the system file (/etc/riotbox/mounts.conf)
# and the user file ($XDG_CONFIG_HOME/riotbox/mounts.conf) and unioned —
# mounts are additive, so a system admin's defaults and the user's own
# entries are all applied.
#
# Format:
#   - Lines starting with # are comments; blank lines are ignored
#   - Paths starting with / or ~ are absolute
#   - Other paths are relative to $HOME
#   - Mounts are read-only (:ro,z) unless the entry ends in `:rw`
#   - Mounted to the same path under /home/llm
#
# Example mounts.conf:
#   # Private npm registry auth (needed for npm install of private packages)
#   .npmrc
#   # Yarn config
#   .yarnrc.yml
#   # Maven settings
#   .m2/settings.xml
#   # A scratch directory the session is meant to write back to
#   .cache/mytool:rw
#
# Counters for the two stderr summaries emitted after both files are read.
RW_MOUNT_COUNT=0
RO_DOWNGRADED=()

for MOUNTS_CONF in "${RIOTBOX_SYSCONF_DIR}/mounts.conf" "${RIOTBOX_CONFIG_DIR}/mounts.conf"; do
	[[ -f "${MOUNTS_CONF}" ]] || continue
	while IFS= read -r line || [[ -n "${line}" ]]; do
		# Skip comments and blank lines
		line="${line%%#*}"
		line="$(echo "${line}" | xargs)" # trim whitespace
		[[ -z "${line}" ]] && continue

		# Split the optional mode suffix off before the path form is
		# resolved, so `~/dir:rw` still takes the tilde branch below.
		# Only the exact lowercase tokens are recognised: a typo like
		# `:RW` stays part of the path, which then does not exist and is
		# skipped. That failure direction is deliberate — a malformed
		# mode can drop a mount or leave it read-only, never widen it.
		mode="ro"
		case "${line}" in
		*:rw)
			mode="rw"
			line="${line%:rw}"
			;;
		*:ro) line="${line%:ro}" ;;
		esac

		# A line of nothing but a mode suffix must not fall through: the
		# relative branch below resolves an empty entry to ${HOME}, which
		# would bind-mount the user's whole home directory into the
		# container. The blank-line check above runs before the suffix is
		# stripped, so it cannot catch this.
		if [[ -z "${line}" ]]; then
			echo "WARN: ${MOUNTS_CONF}: mode suffix with no path — skipping entry" >&2
			continue
		fi

		# Resolve host and container paths. Use [[ == "~/"* ]] (quoted
		# tilde) rather than a `case ~/*` glob: bash tilde-expands an
		# unquoted ~ in case patterns, so `~/*` matches paths starting
		# with $HOME instead of paths starting with the literal "~/".
		# That bug silently dropped every tilde-prefixed mounts.conf
		# entry by routing it to the relative branch with a non-existent
		# ${HOME}/~/... source.
		# shellcheck disable=SC2088  # matching the literal "~/" prefix in user config, not expanding it
		if [[ "${line}" == "~/"* ]]; then
			src="${HOME}/${line:2}"
			dst="${CONTAINER_HOME}/${line:2}"
		elif [[ "${line}" == "/"* ]]; then
			src="${line}"
			dst="${line}"
		else
			src="${HOME}/${line}"
			dst="${CONTAINER_HOME}/${line}"
		fi

		if [[ -e "${src}" ]]; then
			# A read-write mount of $HOME, of an ancestor of it, or of /
			# hands the agent the run of the host. Entries reaching those
			# survive the empty-path check above — `~/`, `.`, `./`, `..`
			# and `/` are all non-empty — so this has to test the resolved
			# source rather than the text of the entry.
			#
			# Read-only entries are deliberately left alone: their reach is
			# what it was before per-entry modes existed, and narrowing it
			# here would break configs that work today.
			if [[ "${mode}" == "rw" ]] && [[ -d "${src}" ]]; then
				canon_src="$(cd "${src}" 2>/dev/null && pwd -P)" || canon_src="${src}"
				canon_home="$(cd "${HOME}" 2>/dev/null && pwd -P)" || canon_home="${HOME}"
				if [[ "${canon_src}" == "/" ]] ||
					[[ "${canon_src}" == "${canon_home}" ]] ||
					[[ "${canon_home}" == "${canon_src}/"* ]]; then
					echo "WARN: ${MOUNTS_CONF}: refusing read-write mount of ${canon_src} — it is the home directory, an ancestor of it, or the filesystem root. Name a narrower path." >&2
					continue
				fi
			fi

			# RIOTBOX_READONLY=1 is the session-wide "the host does not
			# get written to" switch — mount-projects.sh honours it for
			# the workspace and withholds the Context Mode ledger under
			# it. An rw entry that survived it would make the flag mean
			# less than its name. Downgraded paths are named once, after
			# both config files have been read.
			if [[ "${mode}" == "rw" ]] && [[ "${RIOTBOX_READONLY:-}" == "1" ]]; then
				mode="ro"
				RO_DOWNGRADED+=("${src}")
			fi
			if [[ "${mode}" == "rw" ]]; then
				RW_MOUNT_COUNT=$((RW_MOUNT_COUNT + 1))
			fi
			emit_mount "${src}" "${dst}" "${mode}" z
		fi
	done <"${MOUNTS_CONF}"
done

# Both summaries go to stderr: stdout is consumed verbatim by launch.sh and
# `riotbox mounts`, and neither should have to filter prose out of the mount
# list.
if [[ ${#RO_DOWNGRADED[@]} -gt 0 ]]; then
	{
		echo "WARN: RIOTBOX_READONLY=1 downgrades these read-write mounts.conf entries to read-only:"
		printf '        %s\n' "${RO_DOWNGRADED[@]}"
	} >&2
fi
if [[ ${RW_MOUNT_COUNT} -gt 0 ]]; then
	echo "NOTE: ${RW_MOUNT_COUNT} host path(s) mounted read-write from mounts.conf" >&2
fi
