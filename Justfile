#!/usr/bin/env just --justfile
set shell := ["bash", "-euo", "pipefail", "-c"]
set dotenv-load := true

# --- Modules ---
mod docker '.justfiles/docker.just'
mod tests '.justfiles/test.just'
mod session '.justfiles/session.just'
mod backup '.justfiles/backup.just'
mod setup '.justfiles/setup.just'

# --- Recipes ---

# List all available recipes
_default:
    @just --list --unsorted --list-submodules

# Build the riotbox image (shortcut)
build:
    just -f "{{justfile()}}" docker build

# Run Claude with a task prompt (shortcut)
# task - the task/prompt to give Claude
# projects - project directories to mount (default: cwd)
run task *projects:
    cd "{{invocation_directory()}}" && just -f "{{justfile()}}" session run "{{task}}" {{projects}}

# Open a shell inside the riotbox (shortcut)
# projects - project directories to mount (default: cwd)
shell *projects:
    cd "{{invocation_directory()}}" && just -f "{{justfile()}}" session shell {{projects}}

# Run tests (shortcut)
# filter - bats filter regex or test file path (default: all tests)
reown *ref="":
    just -f "{{justfile()}}" setup reown {{ref}}

# Continue the last Claude session (shortcut)
# projects - project directories to mount (default: cwd)
resume *projects:
    cd "{{invocation_directory()}}" && just -f "{{justfile()}}" session resume {{projects}}

# Run tests (shortcut)
# filter - bats filter regex or test file path (default: all tests)
test *filter="":
    just -f "{{justfile()}}" tests run {{filter}}

# Remove the riotbox image (shortcut)
clean:
    just -f "{{justfile()}}" docker clean
