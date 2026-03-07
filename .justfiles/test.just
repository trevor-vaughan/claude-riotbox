#!/usr/bin/env just --justfile
set shell := ["bash", "-euo", "pipefail", "-c"]
set dotenv-load := true

# --- Variables ---
root := source_directory() / ".."
test_image := "claude-riotbox-test"
container_cmd := if `command -v podman 2>/dev/null` != "" { "podman" } else { "docker" }
userns_flag := if container_cmd == "podman" { "--userns=keep-id" } else { "" }
init_flag := if container_cmd == "podman" { "--init=false" } else { "" }

# --- Recipes ---

# List recipes in this module
_default:
    @just --list --unsorted

# Build the test image
_build:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "Building test image..."
    {{container_cmd}} build \
        --build-arg "HOST_UID=$(id -u)" \
        -f "{{root}}/tests/Dockerfile.test" \
        -t "{{test_image}}" \
        "{{root}}"

# Run a bats command inside the test container
_bats +args: _build
    {{container_cmd}} run --rm \
        {{userns_flag}} \
        {{init_flag}} \
        -v "{{root}}:/home/testuser/riotbox:ro,z" \
        -e RIOTBOX_DIR=/home/testuser/riotbox \
        "{{test_image}}" \
        bats {{args}}

# List available tests
list:
    @grep -h '^@test ' "{{root}}"/tests/*.bats | sed 's/@test "\(.*\)".*/\1/'

# Run tests (setup.sh, install.sh, reown-commits.sh)
# filter - bats filter regex or test file path (default: all tests)
run *filter="":
    #!/usr/bin/env bash
    set -euo pipefail
    filter="{{filter}}"
    if [ -z "${filter}" ]; then
        just -f "{{root}}/Justfile" tests _bats /home/testuser/riotbox/tests/
    elif [ -f "{{root}}/${filter}" ] || [[ "${filter}" == *.bats ]]; then
        just -f "{{root}}/Justfile" tests _bats "/home/testuser/riotbox/${filter}"
    else
        just -f "{{root}}/Justfile" tests _bats --filter "${filter}" /home/testuser/riotbox/tests/
    fi
