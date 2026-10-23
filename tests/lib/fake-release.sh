#!/usr/bin/env bash
# Fake GitHub release for tests of install.sh --binary. A `curl` stub serves
# the release assets from a local directory, and a `cosign` stub accepts any
# signature and records its arguments, so the suites exercise install.sh's
# download, checksum, extraction and placement logic without the network.
# Real Sigstore verification is the release's job (Task 8's workflow).
#
# --binary only trusts a checkout that is exactly the release tag, or a tree
# with no git at all (an unpacked source tarball). The suites run install.sh
# from the repo, which is neither, so --binary cases install from
# copy_source_tree or make_tagged_checkout instead.
set -euo pipefail

# copy_source_tree <src> <dst>
#   Copy the checkout at <src> to <dst> the way a source tarball unpacks:
#   without .git, and without .test-output (Venom writes there mid-run).
copy_source_tree() {
	local src="$1" dst="$2"
	mkdir -p "${dst}"
	tar -C "${src}" --exclude=./.git --exclude=./.test-output -cf - . | tar -C "${dst}" -xf -
}

# make_tagged_checkout <src> <dst> <version>
#   copy_source_tree, then commit <dst> as a fresh repo tagged v<version>.
#   git runs with no global or system config and a fixed test identity.
make_tagged_checkout() {
	local src="$1" dst="$2" version="$3"
	copy_source_tree "${src}" "${dst}"
	(
		cd "${dst}"
		git init -q --initial-branch=main
		git add .
		git commit -q -m "release v${version}"
		git tag "v${version}"
	)
}

# git_test_env
#   Isolate git from the caller's config and pin a test identity. Exports
#   the GIT_* variables; call before make_tagged_checkout or any test commit.
git_test_env() {
	export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1
	export GIT_AUTHOR_NAME="RiotBox install test" GIT_AUTHOR_EMAIL="riotbox-install-test@invalid"
	export GIT_COMMITTER_NAME="RiotBox install test" GIT_COMMITTER_EMAIL="riotbox-install-test@invalid"
}

# install_fake_release <dir> <version> <prebuilt-binary> [variant] [cosign-version]
#   Build the release for <version> under <dir>/srv, write the curl and
#   cosign stubs to <dir>/bin and prepend <dir>/bin to PATH.
#   `cosign version` answers in cosign's real format with
#   `GitVersion:    <cosign-version>` (default v3.0.6, what the release
#   workflow uses). Any other cosign call writes its arguments, one per line,
#   to <dir>/cosign-args. The curl stub appends each URL it is asked for to
#   <dir>/curl-urls.
#   Variants:
#     ok              archive holds <prebuilt-binary> as riotbox-core (default)
#     dup-line        checksums.txt names the archive twice
#     no-member       archive holds the binary under another name
#     symlink-member  archive's riotbox-core is a symlink to /bin/sh
install_fake_release() {
	local dir="$1" version="$2" prebuilt="$3" variant="${4:-ok}" cosign_version="${5:-v3.0.6}"
	local machine arch=amd64
	machine="$(uname -m)"
	if [[ "${machine}" == aarch64 || "${machine}" == arm64 ]]; then
		arch=arm64
	fi
	local archive="riotbox-core_${version}_linux_${arch}.tar.gz"
	local member=riotbox-core
	mkdir -p "${dir}/srv" "${dir}/stage" "${dir}/bin"
	case "${variant}" in
	ok | dup-line) cp "${prebuilt}" "${dir}/stage/riotbox-core" ;;
	no-member)
		member=other
		cp "${prebuilt}" "${dir}/stage/other"
		;;
	symlink-member) ln -s /bin/sh "${dir}/stage/riotbox-core" ;;
	*)
		echo "fake release: unknown variant ${variant}" >&2
		return 2
		;;
	esac
	tar -czf "${dir}/srv/${archive}" -C "${dir}/stage" "${member}"
	(cd "${dir}/srv" && sha256sum "${archive}") >"${dir}/srv/checksums.txt"
	if [[ "${variant}" == dup-line ]]; then
		(cd "${dir}/srv" && sha256sum "${archive}") >>"${dir}/srv/checksums.txt"
	fi
	touch "${dir}/srv/checksums.txt.sigstore.json"

	local q_srv q_urls q_args q_cosign_version
	printf -v q_srv '%q' "${dir}/srv"
	printf -v q_urls '%q' "${dir}/curl-urls"
	printf -v q_args '%q' "${dir}/cosign-args"
	printf -v q_cosign_version '%q' "${cosign_version}"
	cat >"${dir}/bin/curl" <<EOF
#!/usr/bin/env bash
set -euo pipefail
out="" url=""
while [[ \$# -gt 0 ]]; do
	case "\$1" in
	-o)
		out="\$2"
		shift
		;;
	https://*) url="\$1" ;;
	*) ;;
	esac
	shift
done
[[ -n "\${out}" && -n "\${url}" ]] || { echo "curl stub: need -o and an https URL" >&2; exit 2; }
echo "\${url}" >>${q_urls}
src=${q_srv}/"\${url##*/}"
[[ -f "\${src}" ]] || { echo "curl: (22) The requested URL returned error: 404" >&2; exit 22; }
cp "\${src}" "\${out}"
EOF
	cat >"${dir}/bin/cosign" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == version ]]; then
	printf 'cosign: A tool for Container Signing, Verification and Storage in an OCI registry.\n\n'
	printf 'GitVersion:    %s\n' ${q_cosign_version}
	printf 'GitCommit:     unknown\nGitTreeState:  clean\n'
	exit 0
fi
printf '%s\n' "\$@" >${q_args}
EOF
	chmod +x "${dir}/bin/curl" "${dir}/bin/cosign"
	export PATH="${dir}/bin:${PATH}"
}
