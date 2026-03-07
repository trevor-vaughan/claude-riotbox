#!/usr/bin/env just --justfile
set shell := ["bash", "-euo", "pipefail", "-c"]
set dotenv-load := true

# --- Variables ---
root := source_directory() / ".."
image_name := env_var_or_default("IMAGE_NAME", "claude-riotbox")
container_cmd := if `command -v podman 2>/dev/null` != "" { "podman" } else { "docker" }
userns_flag := if container_cmd == "podman" { "--userns=keep-id" } else { "" }
init_flag := if container_cmd == "podman" { "--init=false" } else { "" }

# --- Recipes ---

# List recipes in this module
_default:
    @just --list --unsorted

# Build the riotbox image (detects your local toolchains)
build:
    @{{root}}/scripts/build.sh

# Rebuild from scratch (no cache)
rebuild:
    @DOCKER_EXTRA_ARGS="--no-cache" {{root}}/scripts/build.sh

# Remove the riotbox image
clean:
    {{container_cmd}} rmi {{image_name}} 2>/dev/null || true
    @echo "Image removed"
