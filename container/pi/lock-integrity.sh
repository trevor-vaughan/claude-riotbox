#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# lock-integrity.sh — make every tarball in pi.dev's per-release Pi core lock
# verifiable by `npm ci` before the Containerfile's Pi layer installs it.
#
# Usage:  lock-integrity.sh <package-lock.json>     (rewrites the file in place)
#
# Upstream's lock omits `integrity` for Pi's own first-party packages
# (@earendil-works/pi-*). `npm ci` installs an entry without `integrity`
# unverified, so a lock whose `resolved` points at some other tarball installs
# that tarball silently. For every non-root entry this script therefore
# requires:
#   - a key that is a plain `node_modules/…` package path;
#   - a `version` that is plain semver;
#   - a `resolved` that is exactly the registry tarball of the key's package
#     name at that version, https://registry.npmjs.org/<name>/-/<base>-<v>.tgz,
#     so neither another host nor a tarball for another version can hide
#     behind the entry (the resolved URLs are always registry.npmjs.org);
#   - an `integrity`, when present, that is a sha512 SRI hash.
# It then fills each missing `integrity` from
# `npm view <name>@<version> dist.integrity`, so `npm ci` checks every
# downloaded tarball against a hash: upstream's where it supplied one, the
# configured npm registry's where it did not. `npm view` uses the configured
# registry: registry.npmjs.org unless ~/.npmrc names a mirror.
#
# Every check runs inside one jq program over the parsed lock; no lock field
# is ever split or matched in shell, because a field carrying a separator or a
# newline could otherwise forge the fields after it. The only lock-derived text
# that reaches the shell is the `name@version` spec of an entry lacking
# integrity, after both parts have passed the patterns above (no control
# characters, no leading `-`). The hashes go back into the lock as jq data
# (--argjson), never spliced into a filter.
#
# Nothing is written unless every check and every lookup succeeds, so a
# rejected lock is left byte-for-byte as it was. Needs jq and npm on PATH.
# Exits 1 naming the offending entry (JSON-escaped) on any failure.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

readonly REGISTRY="https://registry.npmjs.org/"

die() {
	echo "lock-integrity: $*" >&2
	exit 1
}

lock="${1:?usage: lock-integrity.sh <package-lock.json>}"
[[ -r "${lock}" ]] || die "cannot read ${lock}"

# \A and \z, not ^ and $: in jq's Perl-style regex syntax $ also matches
# just before a trailing newline, so "node_modules/x\n" would pass.
readonly SEGMENT='(@[A-Za-z0-9][A-Za-z0-9._~-]*/)?[A-Za-z0-9][A-Za-z0-9._~-]*'
readonly KEY_RE="\\Anode_modules/(${SEGMENT}/node_modules/)*${SEGMENT}\\z"
readonly VERSION_RE='\A[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?\z'
readonly SHA512_RE='\Asha512-[A-Za-z0-9+/]+=*\z'

# Shared by both jq programs: the package name is the key's last
# node_modules/ segment, and spec is what `npm view` is asked about.
readonly JQ_DEFS='
	def entries: .packages | to_entries[] | select(.key != "");
	def name: .key | sub("\\A.*node_modules/"; "");
	def spec: "\(name)@\(.value.version)";'

problem="$(jq -r --arg registry "${REGISTRY}" --arg key_re "${KEY_RE}" \
	--arg version_re "${VERSION_RE}" --arg sha512_re "${SHA512_RE}" "${JQ_DEFS}"'
	[entries
		| .value.resolved as $resolved
		| .value.integrity as $integrity
		| if (.key | test($key_re) | not) then
			"key \(.key | tojson) is not a plain node_modules package path"
		elif ((.value.version | type) != "string") or (.value.version | test($version_re) | not) then
			"\(.key | tojson) has version \(.value.version | tojson), not a plain semver version"
		elif (($resolved | type) != "string") or ($resolved | startswith($registry) | not) then
			"\(.key | tojson) resolves outside \($registry): \($resolved | tojson)"
		else
			"\($registry)\(name)/-/\(name | split("/") | last)-\(.value.version).tgz" as $expected
			| if $resolved != $expected then
				"\(.key | tojson) is version \(.value.version) but resolves to \($resolved | tojson) (expected \($expected))"
			elif $integrity != null and ((($integrity | type) != "string") or ($integrity | test($sha512_re) | not)) then
				"\(.key | tojson) has integrity \($integrity | tojson), not a sha512 hash"
			else empty end
		end]
	| first // empty' "${lock}")" || die "${lock} is not a readable package-lock.json"
[[ -z "${problem}" ]] || die "${problem}"

count="$(jq "${JQ_DEFS}"' [entries] | length' "${lock}")"
((count > 0)) || die "${lock} lists no packages"

specs="$(jq -r "${JQ_DEFS}"' [entries | select(.value.integrity == null) | spec] | unique[]' "${lock}")"

fills='{}'
while IFS= read -r spec; do
	[[ -n "${spec}" ]] || continue
	got="$(npm view -- "${spec}" dist.integrity)" \
		|| die "npm view ${spec} dist.integrity failed"
	[[ "${got}" =~ ^sha512-[A-Za-z0-9+/]+=*$ ]] \
		|| die "the registry published no sha512 integrity for ${spec}: ${got:-<empty>}"
	fills="$(jq -c --arg spec "${spec}" --arg hash "${got}" '.[$spec] = $hash' <<<"${fills}")"
done <<<"${specs}"

filled=0
if [[ "${fills}" != '{}' ]]; then
	filled="$(jq --argjson fills "${fills}" "${JQ_DEFS}"' [entries | select(.value.integrity == null and $fills[spec] != null)] | length' "${lock}")"
	tmp="$(mktemp "${lock}.XXXXXX")"
	jq --argjson fills "${fills}" "${JQ_DEFS}"'
		.packages |= with_entries(
			if .key != "" and .value.integrity == null then .value.integrity = $fills[spec] else . end)' \
		"${lock}" >"${tmp}" || {
		rm -f "${tmp}"
		die "could not rewrite ${lock}"
	}
	mv "${tmp}" "${lock}"
fi
echo "lock-integrity: ${count} entries resolve to ${REGISTRY} tarballs, ${filled} integrity hashes filled from the configured npm registry"
