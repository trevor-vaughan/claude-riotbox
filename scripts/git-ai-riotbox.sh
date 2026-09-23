#!/usr/bin/env bash
#
# git-ai-riotbox.sh — one git-ai usage view across every riotbox session.
#
# THE GAP THIS CLOSES
# -------------------
# git-ai keeps two kinds of record. Attribution lands in refs/notes/ai inside
# the repo, so `git ai log`/`blame`/`stats` already work on the host. The
# analytics store — token spend, session counts, streaks — is a SQLite tree the
# daemon owns, and riotbox mounts it per session from
# $RIOTBOX_DATA_DIR/<session>/git-ai, deliberately NOT the host's ~/.git-ai (the
# directory holds trace2.sock, which the host's gitconfig names; a container
# that judged the host daemon dead would unlink and rebind it). So `git ai
# usage` on the host reports on the host's own store and is blind to every
# session — the same blind spot scripts/tokscale-riotbox.sh exists to close.
#
# Unlike tokscale there is no multi-root env var, so each store is read on its
# own and the results are merged here.
#
# HOW A STORE IS READ
# -------------------
# git-ai resolves its store as $HOME/.git-ai and offers no override, so each
# store is read through a shim: a temp dir with HOME pointed at it.
#
# The shim holds a COPY, not a symlink. Reading is not a read-only operation for
# git-ai — it creates its metrics DB and caches a models.dev pricing catalogue
# under $HOME/.git-ai — so a symlinked shim makes every report mutate the
# sessions it reports on, archived ones included, and leaves a SQLite WAL behind
# if a read is interrupted. A report must not alter what it measures. Reflink
# makes the copy near-free where the filesystem supports it (35 MB in ~25 ms on
# XFS); elsewhere it is a real copy of one store at a time, discarded before the
# next is read, so peak extra space is one store rather than all of them.
#
# The read also runs with NO NETWORK. git-ai fetches that pricing catalogue at
# runtime and exposes no config key to stop it — the four keys RiotBox sets
# (telemetry, version checks, auto-updates, daemon log upload) do not cover it.
# Every row already carries cost_micro_usd priced when it was written, so
# removing the network leaves every reported number identical (verified) while
# making the fetch impossible rather than merely unwanted. This is the rule
# scripts/tokscale-riotbox.sh already applies to the same class of tool.
#
# Stores are still read where they live rather than being registered anywhere,
# so `riotbox reset-session` drops that session from the report.
#
# WHICH BINARY READS WHICH STORE
# ------------------------------
# Each store is stamped with the git-ai release that wrote it, in
# `.riotbox-version` (see container/git-ai-setup.sh). Those DBs were written by
# that release, so it is the correct reader — this is not merely a fallback
# order. Stores are therefore GROUPED by version and each group is read with a
# matching binary. Resolution per group:
#
#   1. $GIT_AI_BIN                      (explicit override always wins)
#   2. a cached binary of that version  (previously fetched by this script)
#   3. `git-ai` on PATH, if its --version matches the group
#   4. a one-time download of that version, verified against the release
#      SHA256SUMS before it is made executable
#
# A group that resolves to nothing is REPORTED, with its version and stores
# named, rather than read with a mismatched binary that may mis-parse silently.
# A store with no `.riotbox-version` predates the stamp and is skipped with a
# notice for the same reason.
#
# `git ai analyze` has no --json (it answers "unknown analyze subcommand"), so
# there is nothing machine-readable to merge; it stays a per-session command and
# this script does not wrap it.
#
# Usage (normally invoked as `riotbox git-ai [args...]`):
#   git-ai-riotbox.sh                     # merged usage summary
#   git-ai-riotbox.sh --json              # merged document, unrendered
#   git-ai-riotbox.sh --period 7d         # window (1d|3d|7d|30d, default 30d)
#   git-ai-riotbox.sh --list              # what stores exist and who can read them
#
# Env overrides:
#   RIOTBOX_DATA_DIR  session root (default: ${XDG_DATA_HOME:-~/.local/share}/riotbox)
#   GIT_AI_BIN        force one binary for every store (skips version matching)
#   RIOTBOX_GIT_AI_NO_FETCH=1   never download; report unreadable groups instead

# -E so the ERR trap is inherited by functions and subshells; without it a
# failure inside a helper exits silently with no line number.
set -Eeuo pipefail
trap 'echo "git-ai-riotbox: failed at line ${LINENO}" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MERGE_PROGRAM="${SCRIPT_DIR}/lib/git-ai-merge.jq"
RIOTBOX_DATA_DIR="${RIOTBOX_DATA_DIR:-${XDG_DATA_HOME:-${HOME}/.local/share}/riotbox}"
CACHE_DIR="${XDG_CACHE_HOME:-${HOME}/.cache}/riotbox/git-ai"
RELEASES_URL="https://github.com/git-ai-project/git-ai/releases/download"

period="30d"
want_json=0
list_only=0

while [[ $# -gt 0 ]]; do
	case "$1" in
	--json) want_json=1; shift ;;
	--list) list_only=1; shift ;;
	--period) period="${2:?--period needs a value}"; shift 2 ;;
	--period=*) period="${1#*=}"; shift ;;
	-h | --help)
		sed -n '/^# Usage (normally/,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
		exit 0
		;;
	*)
		echo "git-ai-riotbox: unknown argument '$1' (try --help)" >&2
		exit 2
		;;
	esac
done

# Isolation is mandatory, not best-effort: there is no un-isolated fallback,
# for the same reason tokscale-riotbox.sh has none.
if ! command -v unshare >/dev/null 2>&1; then
	echo "git-ai-riotbox: 'unshare' not found; refusing to run git-ai without network isolation" >&2
	exit 1
fi

for tool in jq curl sha256sum; do
	command -v "${tool}" >/dev/null 2>&1 || {
		echo "git-ai-riotbox: '${tool}' is required but not installed." >&2
		exit 1
	}
done
[[ -f "${MERGE_PROGRAM}" ]] || {
	echo "git-ai-riotbox: missing merge program at ${MERGE_PROGRAM}" >&2
	exit 1
}

# ── Discover stores ─────────────────────────────────────────────────────────
# The host's own ~/.git-ai is included as one more root so the report is a
# superset of what plain `git ai usage` shows, never a replacement for it.
# A store is a directory; its version stamp may be absent on old sessions.
declare -a STORE_PATHS=()
declare -a STORE_VERSIONS=()

record_store() {
	local path="$1" version=""
	[[ -d "${path}" ]] || return 0
	# An empty store (a session that never ran git-ai) has nothing to add and
	# would only show up as a version-less skip notice.
	[[ -e "${path}/config.json" || -d "${path}/internal" ]] || return 0
	if [[ -r "${path}/.riotbox-version" ]]; then
		version="$(tr -d '[:space:]' <"${path}/.riotbox-version" 2>/dev/null || true)"
	fi
	STORE_PATHS+=("${path}")
	STORE_VERSIONS+=("${version}")
}

record_store "${HOME}/.git-ai"
if [[ -d "${RIOTBOX_DATA_DIR}" ]]; then
	for session in "${RIOTBOX_DATA_DIR}"/*/; do
		record_store "${session%/}/git-ai"
	done
fi

if [[ ${#STORE_PATHS[@]} -eq 0 ]]; then
	echo "git-ai-riotbox: no git-ai stores found." >&2
	echo "  Looked in ${HOME}/.git-ai and ${RIOTBOX_DATA_DIR}/*/git-ai." >&2
	exit 1
fi

# ── Binary resolution, per version group ────────────────────────────────────
# Prints the release asset name for this host, or nothing when the platform
# has no published build. Like every helper here it always returns 0: a
# non-zero status inside a condition disables set -e for the whole expression
# (SC2310), so callers test the VALUE instead.
host_arch_asset() {
	local os arch
	os="$(uname -s)"
	arch="$(uname -m)"
	case "${arch}" in
	x86_64 | amd64) arch="x64" ;;
	aarch64 | arm64) arch="arm64" ;;
	*) return 0 ;;
	esac
	case "${os}" in
	Linux) printf 'git-ai-linux-%s\n' "${arch}" ;;
	Darwin) printf 'git-ai-macos-%s\n' "${arch}" ;;
	# Windows assets exist upstream but riotbox does not run there; an
	# unknown OS prints nothing and the caller reports the group unread.
	*) : ;;
	esac
}

binary_version() {
	"$1" --version 2>/dev/null | tr -d '[:space:]' || true
}

# Download one version into the cache, refusing to install it unless its digest
# matches the release SHA256SUMS. Prints the path, or nothing on any failure.
fetch_binary() {
	local version="$1" asset dest tmp sums expected actual
	[[ "${RIOTBOX_GIT_AI_NO_FETCH:-0}" != "1" ]] || return 0
	asset="$(host_arch_asset)"
	[[ -n "${asset}" ]] || return 0
	dest="${CACHE_DIR}/${version}/git-ai"
	mkdir -p "$(dirname "${dest}")"
	tmp="$(mktemp)"

	echo "git-ai-riotbox: fetching git-ai ${version} (one-time, needs network)…" >&2
	if ! curl -fsSLo "${tmp}" "${RELEASES_URL}/v${version}/${asset}"; then
		rm -f "${tmp}"
		echo "git-ai-riotbox: download of ${asset} for v${version} failed." >&2
		return 0
	fi

	sums="$(curl -fsSL "${RELEASES_URL}/v${version}/SHA256SUMS" 2>/dev/null || true)"
	expected="$(printf '%s\n' "${sums}" | awk -v a="${asset}" '$2 == a { print $1; exit }')"
	if [[ -z "${expected}" ]]; then
		rm -f "${tmp}"
		echo "git-ai-riotbox: no SHA256SUMS entry for ${asset} at v${version} — refusing to install unverified." >&2
		return 0
	fi
	actual="$(sha256sum "${tmp}" | awk '{print $1}')"
	if [[ "${actual}" != "${expected}" ]]; then
		rm -f "${tmp}"
		echo "git-ai-riotbox: checksum mismatch for ${asset} v${version} — refusing to install." >&2
		return 0
	fi

	chmod +x "${tmp}"
	mv "${tmp}" "${dest}"
	printf '%s\n' "${dest}"
}

# Prints a runnable binary for the given version, or nothing. Always returns 0:
# a non-zero return inside a command substitution would trip the ERR trap
# before the caller could report which group went unread.
resolve_binary_for() {
	local version="$1" cached path
	if [[ -n "${GIT_AI_BIN:-}" ]]; then
		printf '%s\n' "${GIT_AI_BIN}"
		return 0
	fi
	cached="${CACHE_DIR}/${version}/git-ai"
	if [[ -x "${cached}" ]]; then
		printf '%s\n' "${cached}"
		return 0
	fi
	path="$(command -v git-ai 2>/dev/null || true)"
	local on_path_version=""
	[[ -n "${path}" ]] && on_path_version="$(binary_version "${path}")"
	if [[ -n "${path}" && "${on_path_version}" == "${version}" ]]; then
		printf '%s\n' "${path}"
		return 0
	fi
	fetch_binary "${version}"
	return 0
}

# ── Read one store through a HOME shim ──────────────────────────────────────
read_store() {
	local bin="$1" store="$2" shim out
	shim="$(mktemp -d)"

	# --reflink=auto is GNU cp; a host whose cp lacks it (macOS) falls back to
	# a plain recursive copy rather than failing the scan.
	if ! cp -a --reflink=auto "${store}" "${shim}/.git-ai" 2>/dev/null; then
		rm -rf "${shim}/.git-ai"
		if ! cp -a "${store}" "${shim}/.git-ai" 2>/dev/null; then
			rm -rf "${shim}"
			return 0
		fi
	fi

	out="$(unshare -rn env HOME="${shim}" "${bin}" usage --period "${period}" --json 2>/dev/null || true)"
	rm -rf "${shim}"

	if [[ -n "${out}" ]] && printf '%s' "${out}" | jq -e . >/dev/null 2>&1; then
		printf '%s' "${out}"
	fi
	return 0
}

# ── Group, read, merge ──────────────────────────────────────────────────────
declare -a VERSIONS=()
for v in "${STORE_VERSIONS[@]}"; do
	[[ -n "${v}" ]] || continue
	[[ " ${VERSIONS[*]-} " == *" ${v} "* ]] || VERSIONS+=("${v}")
done

if [[ "${list_only}" -eq 1 ]]; then
	printf '%-12s  %-10s  %s\n' "VERSION" "READER" "STORE"
	for i in "${!STORE_PATHS[@]}"; do
		v="${STORE_VERSIONS[${i}]}"
		if [[ -z "${v}" ]]; then
			printf '%-12s  %-10s  %s\n' "(unstamped)" "skipped" "${STORE_PATHS[${i}]}"
		else
			bin="$(resolve_binary_for "${v}")"
			reader="MISSING"
			[[ -n "${bin}" ]] && reader="ok"
			printf '%-12s  %-10s  %s\n' "${v}" "${reader}" "${STORE_PATHS[${i}]}"
		fi
	done
	exit 0
fi

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
read_count=0
skipped_unstamped=0

for i in "${!STORE_PATHS[@]}"; do
	[[ -n "${STORE_VERSIONS[${i}]}" ]] || {
		echo "git-ai-riotbox: ${STORE_PATHS[${i}]} has no .riotbox-version — skipped (unknown writer)." >&2
		skipped_unstamped=$((skipped_unstamped + 1))
		continue
	}
done

for version in "${VERSIONS[@]-}"; do
	[[ -n "${version}" ]] || continue
	bin="$(resolve_binary_for "${version}")"
	if [[ -z "${bin}" ]]; then
		echo "git-ai-riotbox: no git-ai ${version} available to read these stores:" >&2
		for i in "${!STORE_PATHS[@]}"; do
			[[ "${STORE_VERSIONS[${i}]}" == "${version}" ]] && echo "    ${STORE_PATHS[${i}]}" >&2
		done
		echo "  Set GIT_AI_BIN, install git-ai ${version}, or allow the one-time download." >&2
		continue
	fi
	for i in "${!STORE_PATHS[@]}"; do
		[[ "${STORE_VERSIONS[${i}]}" == "${version}" ]] || continue
		out="$(read_store "${bin}" "${STORE_PATHS[${i}]}")"
		if [[ -n "${out}" ]]; then
			printf '%s' "${out}" >"${work}/store-${read_count}.json"
			read_count=$((read_count + 1))
		else
			echo "git-ai-riotbox: ${STORE_PATHS[${i}]} could not be read — skipped." >&2
		fi
	done
done

if [[ "${read_count}" -eq 0 ]]; then
	echo "git-ai-riotbox: no store could be read; nothing to report." >&2
	exit 1
fi

merged="${work}/merged.json"
if ! jq -s -f "${MERGE_PROGRAM}" "${work}"/store-*.json >"${merged}"; then
	echo "git-ai-riotbox: stores could not be merged (see the error above)." >&2
	exit 1
fi

if [[ "${want_json}" -eq 1 ]]; then
	cat "${merged}"
	exit 0
fi

# ── Render ──────────────────────────────────────────────────────────────────
# Deliberately plain: git-ai's own renderer draws from its store and has no
# mode that takes a merged document, so this reports the merged numbers rather
# than imitating that output and implying it came from git-ai itself.
jq -r --arg stores "${read_count}" '
  def money: "$" + (. * 100 | round / 100 | tostring);
  def n: tostring;
  "git-ai across \($stores) store(s) — \(.period_label)",
  "",
  "  Commits          \(.commits.total | n)  (\(.commits.ai_lines | n) AI / \(.commits.human_lines | n) human lines)",
  "  Checkpoints      \(.checkpoints.total | n)  (\(.checkpoints.files_edited | n) files touched)",
  "  Sessions         \(.sessions.total | n)  (\(.sessions.yield_stats.shipped | n) shipped, \(.sessions.yield_stats.abandoned | n) abandoned)",
  "  Token spend      \(.tokens.estimated_cost_usd | money)  (\(.tokens.output | n) output tokens)",
  "  Active days      \(.summary.active_days | n)  (longest streak \(.summary.longest_streak | n))",
  "  Favorite model   \(.summary.favorite_model // "n/a")",
  "",
  "  By tool:",
  (.commits.by_tool[]? | "    \(.[0])  \(.[1] | n) lines"),
  "",
  "  By model:",
  (.tokens.by_model[]? | "    \(.model)  \(.estimated_cost_usd | money)  (\(.sessions | n) sessions)"),
  "",
  "  Top repos:",
  (.repos[0:5][]? | "    \(.repo_url)  \(.ai_lines | n) AI lines")
' "${merged}"

if [[ "${skipped_unstamped}" -gt 0 ]]; then
	echo "" >&2
	echo "Note: ${skipped_unstamped} unstamped store(s) were left out of these totals." >&2
fi
