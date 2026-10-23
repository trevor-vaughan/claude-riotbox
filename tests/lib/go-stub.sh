#!/usr/bin/env bash
# Stub `go` for tests of install.sh/setup.sh --build. The test image has no
# Go toolchain; the host built libexec/riotbox-core before the suites ran.
# The stub answers `go build … -o <out> …` by copying that binary to <out>,
# so install.sh's own flag handling, ordering and placement are what the
# suites exercise. The real build is covered by `task go:build` and the
# release.
set -euo pipefail

# install_go_stub <dir> <prebuilt-binary> [fail]
#   Write <dir>/go and prepend <dir> to PATH. With a third argument "fail",
#   the stub's build exits 1 the way a Go too old for go.mod does
#   (GOTOOLCHAIN=local).
install_go_stub() {
	local dir="$1" prebuilt="$2" mode="${3:-ok}"
	local q_prebuilt q_mode
	printf -v q_prebuilt '%q' "${prebuilt}"
	printf -v q_mode '%q' "${mode}"
	mkdir -p "${dir}"
	cat >"${dir}/go" <<EOF
#!/usr/bin/env bash
set -euo pipefail
[[ "\${1:-}" == build ]] || { echo "go stub: unsupported: \$*" >&2; exit 2; }
if [[ ${q_mode} == fail ]]; then
	echo "go: go.mod requires go >= 1.26.4 (running go 1.25.0; GOTOOLCHAIN=local)" >&2
	exit 1
fi
out=""
while [[ \$# -gt 0 ]]; do
	if [[ "\$1" == -o ]]; then out="\$2"; shift; fi
	shift
done
[[ -n "\${out}" ]] || { echo "go stub: no -o" >&2; exit 2; }
cp ${q_prebuilt} "\${out}"
EOF
	chmod +x "${dir}/go"
	export PATH="${dir}:${PATH}"
}
