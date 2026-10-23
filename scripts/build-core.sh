#!/usr/bin/env bash
# scripts/build-core.sh <output-path> — compile riotbox-core from this tree.
#
# The one definition of the build, shared by `task go:build` and
# `install.sh --build`, so both produce the same binary. The release builds
# through .goreleaser.yaml with the same flags.
#
# GOTOOLCHAIN=local: a Go older than go.mod's `go` line fails with that
# version in the message, instead of silently downloading a newer toolchain
# from the network.
set -euo pipefail

if [[ $# -ne 1 ]]; then
	echo "usage: build-core.sh <output-path>" >&2
	exit 2
fi

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
case "$1" in
/*) out="$1" ;;
*) out="${PWD}/$1" ;;
esac

if ! command -v go >/dev/null 2>&1; then
	need="$(sed -n 's/^go //p' "${root}/go.mod")"
	echo "ERROR: go not found; building riotbox-core needs Go ${need} or newer." >&2
	exit 1
fi

# Same pattern as install.sh's VERSION check; keep the two in step.
version="$(cat "${root}/VERSION")"
if [[ ! "${version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$ ]]; then
	echo "ERROR: ${root}/VERSION is not a semantic version (got '${version}')." >&2
	exit 1
fi
cd "${root}"
GOTOOLCHAIN=local CGO_ENABLED=0 go build -trimpath \
	-ldflags "-s -w -X main.version=${version}" \
	-o "${out}" ./cmd/riotbox-core
