#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# scripts/lib/egress-trust.sh — make the tools in an egress session trust the
# session CA its proxy intercepts credential hosts with (RIOTBOX_EGRESS=1;
# docs/dev/egress.md "Credential injection").
#
# riotbox-core egress-up mounts the CA's certificate read-only at
# RIOTBOX_EGRESS_CA and sets NODE_EXTRA_CA_CERTS to it, which Node (Pi) and
# Bun (Claude Code, opencode) add to their own roots. curl and Python instead
# take one bundle that replaces their roots (SSL_CERT_FILE, CURL_CA_BUNDLE,
# REQUESTS_CA_BUNDLE), so a CA-only file would break every other host; this
# file builds the image's system bundle plus the CA. headroom (Python) reads
# SSL_CERT_FILE or REQUESTS_CA_BUNDLE first, so it uses this bundle, and
# falls back to NODE_EXTRA_CA_CERTS only when neither is set. The
# system trust store is root-owned and the container runs as the user, so
# the bundle is a separate file.
#
# Only the hosts the proxy intercepts (provider APIs) need the CA. git is not
# pointed at it: libcurl in the image has its own compiled-in CA path and
# ignores SSL_CERT_FILE, and git talks to forges, which are tunnelled.
#
# container/entrypoint.sh sources this file and calls egress_trust_apply
# before any agent starts. In the image it is ~/.riotbox/lib/egress-trust.sh
# (the Containerfile copies scripts/lib/).
#
# Public:
#   egress_trust_apply [system-bundle] [bundle]
#       Without RIOTBOX_EGRESS_CA, do nothing. Otherwise write <bundle>
#       (default /tmp/riotbox-egress-ca-bundle.pem, in the container's own
#       writable layer) as <system-bundle> (default: the first readable of
#       EGRESS_TRUST_SYSTEM_BUNDLES), a newline and the CA, and export
#       SSL_CERT_FILE, CURL_CA_BUNDLE and REQUESTS_CA_BUNDLE as its path,
#       only when it was written. The bundle is public, so mode 0644. It
#       is written to a mktemp file beside <bundle> and renamed over it:
#       /tmp is shared, so a link planted at <bundle> is replaced, never
#       written through. The CA must be a regular file, not a link, checked
#       right before the read (the system bundle is root-owned, and is a
#       link in the image). Returns 1, with a warning and nothing exported,
#       when the CA or the system bundle cannot be read or <bundle> cannot
#       be written: the session still starts, the agents still trust the CA
#       through NODE_EXTRA_CA_CERTS, and curl and Python fail TLS for the
#       intercepted hosts only.
# ─────────────────────────────────────────────────────────────────────────────

# CentOS Stream 10, the image's base, has /etc/pki/tls/certs/ca-bundle.crt (a
# link to the extracted p11-kit bundle); the Debian path covers a rebased image.
EGRESS_TRUST_SYSTEM_BUNDLES=(
	/etc/pki/tls/certs/ca-bundle.crt
	/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem
	/etc/ssl/certs/ca-certificates.crt
)

egress_trust_apply() {
	local ca="${RIOTBOX_EGRESS_CA:-}" system="${1:-}" bundle="${2:-/tmp/riotbox-egress-ca-bundle.pem}"
	local tmp candidate
	[[ -n "${ca}" ]] || return 0
	if [[ -z "${system}" ]]; then
		for candidate in "${EGRESS_TRUST_SYSTEM_BUNDLES[@]}"; do
			if [[ -f "${candidate}" && -r "${candidate}" ]]; then
				system="${candidate}"
				break
			fi
		done
	fi
	if [[ -z "${system}" || ! -f "${system}" || ! -r "${system}" ]]; then
		echo "WARNING: egress: no system CA bundle (${system:-none of ${EGRESS_TRUST_SYSTEM_BUNDLES[*]}}); curl and Python will not reach credential hosts." >&2
		return 1
	fi
	if ! tmp="$(mktemp "${bundle}.XXXXXX" 2>/dev/null)"; then
		echo "WARNING: egress: could not write ${bundle}; curl and Python will not reach credential hosts." >&2
		return 1
	fi
	# The checks sit right before the read; the newline keeps a system bundle
	# that does not end in one from running into the CA's BEGIN line.
	if [[ ! -f "${ca}" || -L "${ca}" || ! -r "${ca}" ]]; then
		rm -f -- "${tmp}"
		echo "WARNING: egress: the session CA ${ca} is not a readable regular file; curl and Python will not reach credential hosts." >&2
		return 1
	fi
	if ! { cat -- "${system}" && printf '\n' && cat -- "${ca}"; } >"${tmp}" ||
		! chmod 0644 -- "${tmp}" || ! mv -fT -- "${tmp}" "${bundle}"; then
		rm -f -- "${tmp}"
		echo "WARNING: egress: could not write ${bundle}; curl and Python will not reach credential hosts." >&2
		return 1
	fi
	export SSL_CERT_FILE="${bundle}" CURL_CA_BUNDLE="${bundle}" REQUESTS_CA_BUNDLE="${bundle}"
}
