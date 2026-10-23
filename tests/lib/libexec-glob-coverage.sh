#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# libexec-glob-coverage.sh — assert every libexec/ entry is shipped by the
# `./libexec/*.sh` glob in .goreleaser.yaml's nfpms contents.
#
# The packages take libexec/ through that glob rather than the directory, so
# the riotbox-core a developer's `task go:build` leaves in libexec/ cannot ride
# along beside the release build that `bindir` installs. A glob drops a file it
# does not match without a word: a libexec helper that is not a top-level .sh
# would be missing from every rpm and deb while working in the repo.
#
# Usage:  bash tests/lib/libexec-glob-coverage.sh [REPO_ROOT]   (default ".")
#
# Prints "libexec_glob_coverage=pass (<n> files)" and exits 0 when every
# entry matches; prints one "UNSHIPPED <file>: …" line per gap and exits
# 1 otherwise. Premise failures (no glob entry, nothing listed) exit 1 with
# "FAIL: …" so a check that has stopped seeing anything cannot report a pass.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

repo_root="${1:-.}"
manifest="${repo_root}/.goreleaser.yaml"

[[ -r "${manifest}" ]] || {
	echo "FAIL: cannot read ${manifest}"
	exit 1
}
grep -qE '^[[:space:]]*-[[:space:]]+src:[[:space:]]+\./libexec/\*\.sh[[:space:]]*$' "${manifest}" || {
	echo "FAIL: ${manifest} has no \`src: ./libexec/*.sh\` entry — the glob this check mirrors moved or changed"
	exit 1
}

# A filesystem listing, not `git ls-files`: in a worktree run through the
# containerised `task test`, .git points at a host path the container lacks.
# libexec/riotbox-core is the gitignored `task go:build` output the glob exists
# to keep out, so it is the one entry exempt here.
# shellcheck disable=SC2312  # a find failure leaves the array empty, which the check below reports
mapfile -t entries < <(
	cd "${repo_root}" && find libexec -mindepth 1 \( -type f -o -type l \) ! -path libexec/riotbox-core | sort
)
((${#entries[@]} > 0)) || {
	echo "FAIL: found no files under ${repo_root}/libexec"
	exit 1
}

unshipped=0
for f in "${entries[@]}"; do
	# nfpm's `*` does not cross `/`, so only top-level .sh files match.
	if [[ "${f}" == libexec/*.sh && "${f}" != libexec/*/* ]]; then
		continue
	fi
	echo "UNSHIPPED ${f}: not matched by ./libexec/*.sh in ${manifest}, so no rpm or deb carries it — list it in nfpms contents and extend this check (docs/dev/riotbox-core.md)"
	unshipped=$((unshipped + 1))
done

((unshipped == 0)) || {
	echo "FAIL: ${unshipped} libexec file(s) would be left out of the packages — see the lines above"
	exit 1
}
echo "libexec_glob_coverage=pass (${#entries[@]} files)"
