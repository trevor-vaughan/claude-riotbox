#!/usr/bin/env bash
# changelog-section.sh — print one release's section of CHANGELOG.md.
#
# The release workflow feeds this to `gh release create --notes-file` so the
# published notes are the committed changelog rather than a separately
# generated list. It lives here, not inline in the workflow, so
# tests/release-bump.venom.yml can exercise the same extraction CI runs.
#
# Usage: changelog-section.sh <version> [changelog]
# Exits 1 when the version has no section.
set -euo pipefail

version="${1:?usage: changelog-section.sh <version> [changelog]}"
changelog="${2:-CHANGELOG.md}"

[[ -f "${changelog}" ]] || {
	printf 'error: %s not found\n' "${changelog}" >&2
	exit 1
}

# Capture between this version's heading and the next one. Blank lines are held
# back and only flushed once another line follows, which drops the separator
# blank at the top of the section and any trailing ones at the bottom without a
# second pass.
section="$(awk -v want="## [${version}]" '
	index($0, want) == 1 { capture = 1; next }
	capture && /^## \[/  { exit }
	capture {
		if ($0 ~ /^[[:space:]]*$/) { held++; next }
		while (held-- > 0) { if (printed) print "" }
		held = 0
		print
		printed = 1
	}
' "${changelog}")"

[[ -n "${section}" ]] || {
	printf 'error: no section for version %s in %s\n' "${version}" "${changelog}" >&2
	exit 1
}

printf '%s\n' "${section}"
