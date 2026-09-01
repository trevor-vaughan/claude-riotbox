#!/usr/bin/env bash
# release-bump.sh — bump the release version, regenerate CHANGELOG.md, commit
# and tag. Driven by `task release:bump`.
#
# The new version comes from the first argument, or from an interactive prompt
# whose default is what git-cliff derives from the Conventional Commits since
# the last release tag. cliff.toml's [bump] block defines the levels: while the
# major version is 0, a breaking change bumps the minor and a feature bumps the
# patch, so nothing here ever auto-suggests 1.0.0.
#
# Nothing is pushed. The tag stays local until the operator pushes it, which is
# what triggers .github/workflows/release.yml.
#
# Env:
#   ROOT_DIR   repository to operate on (default: this checkout)
#   GIT_CLIFF  git-cliff executable (default: git-cliff on PATH)
set -euo pipefail

ROOT_DIR="${ROOT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
GIT_CLIFF="${GIT_CLIFF:-git-cliff}"
GIT_CLIFF_VERSION="2.13.1"
SEMVER_RE='^[0-9]+\.[0-9]+\.[0-9]+$'

die() {
	printf 'error: %s\n' "$*" >&2
	exit 1
}

# Echo <version> with its patch component incremented. This is the suggestion
# whenever git-cliff cannot infer a bump: with no release tag it has no
# baseline to measure against, and a VERSION that has drifted away from the
# last tag would make its answer wrong rather than merely absent.
patch_bump() {
	local major minor patch
	IFS=. read -r major minor patch <<<"${1}"
	printf '%s.%s.%s\n' "${major}" "${minor}" "$((patch + 1))"
}

# True when <candidate> sorts strictly after <current> under version ordering.
is_greater() {
	local current="${1}" candidate="${2}" sorted
	[[ "${current}" != "${candidate}" ]] || return 1
	sorted="$(printf '%s\n%s\n' "${current}" "${candidate}" | sort -V)"
	[[ "${sorted%%$'\n'*}" == "${current}" ]]
}

if ! command -v "${GIT_CLIFF}" >/dev/null 2>&1; then
	printf 'error: git-cliff not found. Install git-cliff v%s:\n' "${GIT_CLIFF_VERSION}" >&2
	printf '  cargo install git-cliff --version %s\n' "${GIT_CLIFF_VERSION}" >&2
	printf 'or take a prebuilt binary from https://git-cliff.org/docs/installation/\n' >&2
	exit 1
fi

[[ -f "${ROOT_DIR}/VERSION" ]] || die "no VERSION file in ${ROOT_DIR}"
[[ -f "${ROOT_DIR}/cliff.toml" ]] || die "no cliff.toml in ${ROOT_DIR}"

if ! git -C "${ROOT_DIR}" diff --quiet || ! git -C "${ROOT_DIR}" diff --cached --quiet; then
	die "working tree has uncommitted changes; commit or stash them first"
fi

current="$(cat "${ROOT_DIR}/VERSION")"
[[ "${current}" =~ ${SEMVER_RE} ]] || die "VERSION (${current}) is not a semantic version"

# --abbrev=0 yields the nearest reachable tag rather than a describe string.
# The match pattern keeps the repository's riotbox-checkpoint/* and backup/*
# tags out of the answer; cliff.toml's tag_pattern does the same for git-cliff.
last_tag="$(git -C "${ROOT_DIR}" describe --tags --match 'v[0-9]*' --abbrev=0 2>/dev/null || true)"

if [[ -z "${last_tag}" ]]; then
	printf 'note: no v* release tag found; suggesting a patch bump instead of reading the commit history\n' >&2
	suggested="$(patch_bump "${current}")"
elif [[ "${last_tag#v}" != "${current}" ]]; then
	printf 'warning: last release tag %s does not match VERSION (%s); suggesting a patch bump instead of reading the commit history\n' \
		"${last_tag}" "${current}" >&2
	suggested="$(patch_bump "${current}")"
else
	suggested="$("${GIT_CLIFF}" --config "${ROOT_DIR}/cliff.toml" --repository "${ROOT_DIR}" --bumped-version 2>/dev/null || true)"
	suggested="${suggested#v}"
	[[ "${suggested}" =~ ${SEMVER_RE} ]] || die "git-cliff returned an unusable version ('${suggested}')"
	# With nothing releasable since the tag, git-cliff echoes the tag back.
	# shellcheck disable=SC2310  # is_greater is a predicate — its return value is the answer, so set -e suppression is intentional
	if ! is_greater "${current}" "${suggested}"; then
		printf 'note: no releasable commits since %s; suggesting a patch bump\n' "${last_tag}" >&2
		suggested="$(patch_bump "${current}")"
	fi
fi

new="${1:-}"
if [[ -z "${new}" ]]; then
	printf 'Current version: %s\n' "${current}" >&2
	printf 'New version [%s]: ' "${suggested}" >&2
	# read fails on EOF, which is how a closed stdin reaches us. Failing here
	# beats defaulting silently: a scripted caller that meant to pass a version
	# would otherwise cut a release nobody chose.
	IFS= read -r reply ||
		die "no version given and stdin is closed; pass one as an argument (task release:bump -- ${suggested})"
	new="${reply:-${suggested}}"
fi

[[ "${new}" =~ ${SEMVER_RE} ]] || die "'${new}' is not a semantic version (expected MAJOR.MINOR.PATCH)"
# shellcheck disable=SC2310  # is_greater is a predicate — its return value is the answer, so set -e suppression is intentional
is_greater "${current}" "${new}" || die "${new} is not greater than the current version ${current}"
if git -C "${ROOT_DIR}" rev-parse -q --verify "refs/tags/v${new}" >/dev/null 2>&1; then
	die "tag v${new} already exists"
fi

printf '%s\n' "${new}" >"${ROOT_DIR}/VERSION"

# Regenerate the whole file rather than prepending. The release commit written
# below is skipped by cliff.toml's commit_parsers, so a later full regeneration
# reproduces this same content — a prepend would drift the moment history is
# rewritten or the config changes.
"${GIT_CLIFF}" \
	--config "${ROOT_DIR}/cliff.toml" \
	--repository "${ROOT_DIR}" \
	--tag "v${new}" \
	--output "${ROOT_DIR}/CHANGELOG.md"

git -C "${ROOT_DIR}" add VERSION CHANGELOG.md
git -C "${ROOT_DIR}" commit -qm "chore(release): v${new}"
git -C "${ROOT_DIR}" tag -a "v${new}" -m "v${new}"

printf "✅ Released v%s — run 'git push --follow-tags' when ready\\n" "${new}"
