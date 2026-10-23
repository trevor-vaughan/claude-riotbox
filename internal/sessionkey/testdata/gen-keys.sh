#!/usr/bin/env bash
# gen-keys.sh <riotbox-tree> — print golden session-key vectors (keys.tsv).
#
# The vectors pin what the bash key functions computed before they moved to
# Go, so <riotbox-tree> must be a v0.7.0 tree, the last release where bash
# computed keys itself. Running this against a later tree compares Go with
# itself. Regenerate with:
#
#   tree="$(mktemp -d)"
#   git archive v0.7.0 scripts | tar -x -C "${tree}"
#   internal/sessionkey/testdata/gen-keys.sh "${tree}" > internal/sessionkey/testdata/keys.tsv
#
# Columns, tab-separated, every byte field hex-encoded so any byte (newline,
# non-UTF-8) survives:
#   1. description (plain text)
#   2. the session_key arguments, each hex-encoded, joined by ","
#   3. session_key's exact stdout
#   4. compute_multi_project_identity's exact stdout, or "-" where that output
#      is not a contract: its first_seg is the per-line sed output of the
#      bytewise-first basename, so a newline in that basename splits it and
#      shifts the three-line output. Go maps the newline to "-" instead
#      (see sessionkey_test.go). "trailing newline, single" stays computed:
#      v0.7.0's $(...) strips the trailing newline, so first_seg is just "a".
set -euo pipefail
shopt -s inherit_errexit

if [[ $# -ne 1 ]] || [[ ! -f "$1/scripts/mount-projects.sh" ]]; then
	echo "usage: gen-keys.sh <riotbox v0.7.0 tree>" >&2
	exit 2
fi

# shellcheck source=/dev/null
source "$1/scripts/mount-projects.sh"

hex() {
	printf '%s' "$1" | od -An -tx1 -v | tr -d ' \n'
}

# emit <description> <identity: yes|no> <dir>...
emit() {
	local desc="$1" with_identity="$2"
	shift 2
	local d dirs="" key ident="-"
	for d in "$@"; do
		dirs+="${dirs:+,}$(hex "${d}")"
	done
	# The trailing "x" keeps $(...) from stripping the output's own newlines.
	key="$(
		session_key "$@" && printf x
	)"
	key="$(hex "${key%x}")"
	if [[ "${with_identity}" == yes ]]; then
		ident="$(
			compute_multi_project_identity "$@" && printf x
		)"
		ident="$(hex "${ident%x}")"
	fi
	printf '%s\t%s\t%s\t%s\n' "${desc}" "${dirs}" "${key}" "${ident}"
}

long="$(printf 'abcdefghij%.0s' {1..30})"
bangs250="$(printf '!%.0s' {1..250})"
bangs300="$(printf '!%.0s' {1..300})"

emit "single project" yes /home/me/src/app
emit "root" yes /
emit "two projects" yes /home/me/a /home/me/b
emit "unsorted three" yes /z/c /a/b /m/n
emit "duplicates" yes /home/me/a /home/me/a
emit "duplicates in set" yes /x/a /x/b /x/a
emit "non-ascii utf-8" yes /home/me/café /home/me/über
emit "non-utf-8 byte" yes $'/home/me/\xff\xfeproj' /home/me/z
emit "spaces" yes "/tmp/a b/x y"
emit "spaces in set" yes "/tmp/a b/x y" /tmp/z
emit "punctuation basename in set" yes "/p/--weird!!name--" /q/r
emit "all-punctuation basename in set" yes "/p/!!!" /q/r
emit "newline in path, single" yes $'/tmp/a\n/b'
emit "newline then dash, single" no $'/tmp/a\n-b'
emit "trailing newline, single" yes $'/tmp/a\n'
emit "newline in a later set member" yes /a/first $'/z/sec\nond'
emit "long single" yes "/${long}/${long}"
emit "long single, punctuation after the cut" yes "/${long}/${bangs250}x"
emit "long single, no alphanumeric" yes "/${bangs300}"
emit "single, prefix exactly 238 bytes" yes "/$(printf 'a%.0s' {1..238})"
emit "single, prefix 239 bytes (cut one)" yes "/$(printf 'a%.0s' {1..239})"
emit "set, first_seg+suffix exactly 238" yes "/p/$(printf 'a%.0s' {1..232})" /q
emit "set, first_seg+suffix 239 (cut one)" yes "/p/$(printf 'a%.0s' {1..233})" /q
emit "set, cut lands right after a dash" yes "/p/$(printf 'a%.0s' {1..231})-$(printf 'b%.0s' {1..20})" /q
emit "single, long non-ascii cut inside a character" yes "/$(printf 'é%.0s' {1..150})"
emit "long set" yes "/a/${long}" /b
emit "long set, many members" yes "/a/${long}" /b /c /d /e /f /g /h /i /j /k
