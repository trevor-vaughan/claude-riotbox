#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# mount-projects.sh — Resolves project directories into container mount flags.
#
# Two invocation modes:
#
#   1. Sourced (existing taskfile scripts). Sets these variables:
#        PROJECT_DIRS         — bash array of resolved host paths
#        PROJECT_VOLUME_FLAGS — -v flags for podman/docker run (includes
#                               riotbox session mount)
#        PROJECT_SUMMARY      — human-readable list for status output
#        WORKDIR              — container working directory
#        CONTAINER_NAME       — unique container name for --name flag
#        RIOTBOX_SESSION_DIR  — host-side session directory path
#
#   2. Executed (downstream config generators / tests). Accepts:
#        --format=podman   one `-v host:container[:flag]` line per mount
#                          (default; matches sourced PROJECT_VOLUME_FLAGS).
#        --format=triple   one `host:container:mode` line per mount, where
#                          mode is `rw` or `ro`.
#      Project paths come from "$@" (after flags) or RIOTBOX_PROJECTS.
#
# Single project:  mounted at /workspace (backward compatible)
# Multiple projects: each mounted at /workspace/<dirname>
# No projects:     current directory mounted at /workspace
#
# LIMITATION: Project paths must not contain spaces. Volume flags are
# accumulated as a flat string and word-split at the container run call.
# This is a deliberate tradeoff for simplicity — paths with spaces are
# extremely uncommon for development project directories.
# ─────────────────────────────────────────────────────────────────────────────

# Compute the canonical multi-project identity components.
#
# Emits three lines on stdout:
#   1. first_seg  — sed-mangled basename of the lexically first path
#   2. n_more     — count of remaining paths after the first
#   3. hash8      — first 8 hex chars of sha256 of the canonical form
#
# The canonical hash input is the sorted paths with `/` → `-`, any leading
# `-` stripped, joined by `+`. The container name and session directory
# basename are both derived from this output so a project set carries a
# single identity across the runtime container and its on-disk store.
# Callers consume the three lines with a grouped `read` block.
compute_multi_project_identity() {
    local -a sorted=()
    local sorted_line
    while IFS= read -r sorted_line; do
        sorted+=("${sorted_line}")
    done < <(printf '%s\n' "$@" | LC_ALL=C sort)

    local first_seg
    first_seg="$(basename "${sorted[0]}")"
    first_seg="$(printf '%s' "${first_seg}" | sed 's/[^a-zA-Z0-9_.-]/-/g; s/--*/-/g; s/^-//; s/-$//')"

    local n_more=$(( ${#sorted[@]} - 1 ))
    local hash_input hash8
    hash_input="$(printf '%s\n' "${sorted[@]}" | sed 's|/|-|g; s|^-||' | paste -sd'+' -)"
    hash8="$(printf '%s' "${hash_input}" | sha256sum | cut -c1-8)"

    printf '%s\n%s\n%s\n' "${first_seg}" "${n_more}" "${hash8}"
}

# Generate a unique container name from project paths.
#
# Single-project: builds from the leaf (basename) upward, walking parent
# segments only when an existing container already owns the candidate name.
# A random suffix is appended if the path is fully consumed.
#
# Multi-project: emits `riotbox-<first_basename>-<N>more-<hash8>` using the
# identity from compute_multi_project_identity. The hash is what makes the
# name unique — naive basename concatenation overflowed the 64-char cap and
# the left-truncation that followed silently collapsed distinct project
# sets that happened to share a trailing run of basenames into one name.
#
# CONTAINER_CMD must be set by the caller (podman or docker) for the
# single-project disambiguation probe.
generate_container_name() {
    local -a dirs=("$@")
    local max_len=64
    local prefix="riotbox"

    if [ ${#dirs[@]} -eq 0 ]; then
        # shellcheck disable=SC2034  # used by caller after sourcing
        CONTAINER_NAME="${prefix}"
        return
    fi

    # ── Multi-project ────────────────────────────────────────────────
    if [ ${#dirs[@]} -gt 1 ]; then
        local first_seg n_more hash8
        { read -r first_seg
          read -r n_more
          read -r hash8
        } < <(compute_multi_project_identity "${dirs[@]}")

        local suffix="-${n_more}more-${hash8}"
        local readable_max=$(( max_len - ${#prefix} - 1 - ${#suffix} ))
        if [ "${#first_seg}" -gt "${readable_max}" ]; then
            first_seg="${first_seg:0:${readable_max}}"
        fi
        # shellcheck disable=SC2034  # used by caller after sourcing
        CONTAINER_NAME="${prefix}-${first_seg}${suffix}"
        return
    fi

    # ── Single-project ───────────────────────────────────────────────
    local base
    base="$(basename "${dirs[0]}")"

    local first_dir="${dirs[0]}"
    local -a segments=()
    local tmp="${first_dir}"
    while [ "${tmp}" != "/" ] && [ -n "${tmp}" ]; do
        segments=("$(basename "${tmp}")" "${segments[@]}")
        tmp="$(dirname "${tmp}")"
    done

    local candidate="${prefix}-${base}"
    candidate="$(printf '%s' "${candidate}" | sed 's/[^a-zA-Z0-9_.-]/-/g; s/--*/-/g')"

    local base_idx=$(( ${#segments[@]} - 1 ))
    local depth=0
    while ${CONTAINER_CMD:-podman} ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "${candidate}"; do
        depth=$(( depth + 1 ))
        local parent_idx=$(( base_idx - depth ))
        if [ ${parent_idx} -lt 0 ]; then
            candidate="${candidate}-$(head -c4 /dev/urandom | od -An -tx1 | tr -d ' ')"
            break
        fi
        candidate="${prefix}-${segments[${parent_idx}]}-${base}"
        candidate="$(printf '%s' "${candidate}" | sed 's/[^a-zA-Z0-9_.-]/-/g; s/--*/-/g')"
    done

    if [ ${#candidate} -gt ${max_len} ]; then
        candidate="${candidate: -${max_len}}"
        candidate="${candidate#"${candidate%%[a-zA-Z0-9]*}"}"
    fi

    # shellcheck disable=SC2034  # used by caller after sourcing
    CONTAINER_NAME="${candidate}"
}

# Lightweight resolver: populates PROJECT_DIRS, PROJECT_SUMMARY, and
# RIOTBOX_SESSION_DIR without creating dirs, copying files, or spawning
# container commands. Used by recipes that only need the session path.
resolve_projects() {
    local raw_projects="$1"
    PROJECT_DIRS=()
    PROJECT_SUMMARY=""

    # Default to current directory if no projects specified
    if [ -z "${raw_projects}" ]; then
        raw_projects="$(pwd)"
    fi

    # Resolve each path to absolute, canonicalising symlinks so the same
    # project reached via different paths produces the same session key.
    # Disable globbing so paths with metacharacters (*, ?) aren't expanded.
    # Paths are space-separated by design (CLI args joined by the caller).
    local _old_glob
    _old_glob="$(shopt -po noglob 2>/dev/null || true)"
    set -f
    for p in ${raw_projects}; do
        local resolved
        if ! resolved="$(cd "${p}" 2>/dev/null && pwd -P)"; then
            eval "${_old_glob}"
            echo "ERROR: project path does not exist or is not a directory: ${p}" >&2
            return 1
        fi
        PROJECT_DIRS+=("${resolved}")
    done
    eval "${_old_glob}"

    if [ ${#PROJECT_DIRS[@]} -eq 1 ]; then
        PROJECT_SUMMARY="${PROJECT_DIRS[0]}"
    else
        for dir in "${PROJECT_DIRS[@]}"; do
            local name
            name="$(basename "${dir}")"
            if [ -n "${PROJECT_SUMMARY}" ]; then
                PROJECT_SUMMARY="${PROJECT_SUMMARY}, ${name}"
            else
                PROJECT_SUMMARY="${name}"
            fi
        done
        PROJECT_SUMMARY="${#PROJECT_DIRS[@]} projects: ${PROJECT_SUMMARY}"
    fi

    # ── Session key ───────────────────────────────────────────────────
    # Single-project keeps the human-readable, path-mangled key so
    # list-sessions output and the test helpers in tests/lib/ remain
    # decodable by reversing the `s|/|-|g` mangling. Multi-project uses
    # the same hashed identity as the container name — naive
    # concatenation of N path-mangled segments overflows NAME_MAX (255)
    # on every supported filesystem for non-trivial project sets, and
    # mkdir fails with ENAMETOOLONG.
    local session_key
    RIOTBOX_DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/riotbox"
    if [ ${#PROJECT_DIRS[@]} -le 1 ]; then
        session_key="$(printf '%s\n' "${PROJECT_DIRS[@]}" | sed 's|/|-|g; s|^-||')"
    else
        local first_seg n_more hash8
        { read -r first_seg
          read -r n_more
          read -r hash8
        } < <(compute_multi_project_identity "${PROJECT_DIRS[@]}")
        session_key="${first_seg}-${n_more}more-${hash8}"
    fi
    RIOTBOX_SESSION_DIR="${RIOTBOX_DATA_DIR}/${session_key}"
}

# Return 0 if the given path should be treated as not-owned by the host
# user (i.e. ineligible for `:z` relabel; routed to podman's `:O` overlay).
#
# Production gate: the path's owner UID differs from the effective UID.
# Test seam via RIOTBOX_FORCE_UNOWNED_MOUNTS:
#   ""            production check (`[ ! -O "$p" ]`)
#   "1"           sledgehammer — every path treated as unowned
#   "/a:/b:…"     literal colon-separated path list — only listed paths
#                 treated as unowned; other paths fall through to the
#                 production check
#
# The dual-mode seam exists because venom tests cannot create
# root-owned fixtures without sudo. The path-list form covers the true
# mixed case (owned + unowned in the same project set), which is the
# most interesting per-dir branching scenario.
_mount_path_is_unowned() {
    local p="$1"
    case "${RIOTBOX_FORCE_UNOWNED_MOUNTS:-}" in
        1)
            return 0
            ;;
        "")
            [ ! -O "${p}" ]
            ;;
        *)
            [[ ":${RIOTBOX_FORCE_UNOWNED_MOUNTS}:" == *":${p}:"* ]]
            ;;
    esac
}

setup_projects() {
    local raw_projects="$1"
    PROJECT_VOLUME_FLAGS=""
    # shellcheck disable=SC2034  # used by caller after sourcing
    WORKDIR="/workspace"

    resolve_projects "${raw_projects}"

    # ── Engine guard for unowned mounts ───────────────────────────────
    # Unowned paths require podman's `:O` overlay (no Docker equivalent).
    # If any path is unowned and the runtime is not podman, abort before
    # any filesystem side effects (no session dir, no overlay tree).
    local _engine="${CONTAINER_CMD:-podman}"
    if [ "${_engine}" != "podman" ]; then
        local _unowned_paths=""
        local _dir
        for _dir in "${PROJECT_DIRS[@]}"; do
            if _mount_path_is_unowned "${_dir}"; then
                _unowned_paths="${_unowned_paths}${_dir}"$'\n'
            fi
        done
        if [ -n "${_unowned_paths}" ]; then
            {
                echo "ERROR: project path is not owned by you and requires podman's \`:O\` overlay mount:"
                # shellcheck disable=SC2086  # intentional word-splitting on newlines in the path list
                printf '         %s\n' ${_unowned_paths}
                echo "       This feature is podman-only. Docker does not support per-mount overlays."
                echo "       Either run under podman, or copy the tree to a location you own."
            } >&2
            return 1
        fi
        unset _dir _unowned_paths
    fi

    if [ "${RIOTBOX_OVERLAY:-}" = "1" ]; then
        # ── Overlay mode: per-path branch on ownership ────────────────
        # Owned path → :ro,z lower + session-dir :z upper (persistent).
        # Unowned path → :O only (ephemeral; no session upper/work). The
        # original :ro,z lower would chcon-fail on unowned dirs; :O has
        # the same essential shape (RO source + writable container view)
        # and is the safe fallback. Persistence is fundamentally
        # incoherent against a tree you cannot write back to.
        local _unowned_for_warn=""
        local _name _lower_path _overlay_path _overlay_dir
        if [ ${#PROJECT_DIRS[@]} -eq 1 ]; then
            _lower_path="/mnt/lower"
            _overlay_path="/mnt/overlay"
            _name="project"
            if _mount_path_is_unowned "${PROJECT_DIRS[0]}"; then
                PROJECT_VOLUME_FLAGS="-v ${PROJECT_DIRS[0]}:${_lower_path}:O"
                _unowned_for_warn="${PROJECT_DIRS[0]}"$'\n'
            else
                PROJECT_VOLUME_FLAGS="-v ${PROJECT_DIRS[0]}:${_lower_path}:ro,z"
                _overlay_dir="${RIOTBOX_SESSION_DIR}/overlay/${_name}"
                mkdir -p "${_overlay_dir}/upper" "${_overlay_dir}/work"
                PROJECT_VOLUME_FLAGS="${PROJECT_VOLUME_FLAGS} -v ${_overlay_dir}:${_overlay_path}:z"
            fi
        else
            for dir in "${PROJECT_DIRS[@]}"; do
                _name="$(basename "${dir}")"
                _lower_path="/mnt/lower/${_name}"
                _overlay_path="/mnt/overlay/${_name}"
                if _mount_path_is_unowned "${dir}"; then
                    PROJECT_VOLUME_FLAGS="${PROJECT_VOLUME_FLAGS} -v ${dir}:${_lower_path}:O"
                    _unowned_for_warn="${_unowned_for_warn}${dir}"$'\n'
                else
                    PROJECT_VOLUME_FLAGS="${PROJECT_VOLUME_FLAGS} -v ${dir}:${_lower_path}:ro,z"
                    _overlay_dir="${RIOTBOX_SESSION_DIR}/overlay/${_name}"
                    mkdir -p "${_overlay_dir}/upper" "${_overlay_dir}/work"
                    PROJECT_VOLUME_FLAGS="${PROJECT_VOLUME_FLAGS} -v ${_overlay_dir}:${_overlay_path}:z"
                fi
            done
        fi
        if [ -n "${_unowned_for_warn}" ]; then
            {
                echo "WARN: RIOTBOX_OVERLAY=1 falls back to ephemeral overlay (:O) for unowned paths:"
                # shellcheck disable=SC2086  # intentional word-splitting on newlines in the path list
                printf '        %s\n' ${_unowned_for_warn}
                echo "      Writes to these paths will not persist between runs."
            } >&2
        fi
    else
        # ── Normal mode: direct bind mount ────────────────────────────
        # Per-path branching on ownership:
        #   owned + RIOTBOX_READONLY=1   → :ro,z
        #   owned + default              → :z
        #   not owned (either)           → :O    (podman overlay; ephemeral writes)
        local _ro_suffix=":z"
        if [ "${RIOTBOX_READONLY:-}" = "1" ]; then
            _ro_suffix=":ro,z"
        fi

        local _suffix _container_path
        if [ ${#PROJECT_DIRS[@]} -eq 1 ]; then
            _container_path="/workspace"
            if _mount_path_is_unowned "${PROJECT_DIRS[0]}"; then
                _suffix=":O"
            else
                _suffix="${_ro_suffix}"
            fi
            PROJECT_VOLUME_FLAGS="-v ${PROJECT_DIRS[0]}:${_container_path}${_suffix}"
        else
            for dir in "${PROJECT_DIRS[@]}"; do
                local name
                name="$(basename "${dir}")"
                _container_path="/workspace/${name}"
                if _mount_path_is_unowned "${dir}"; then
                    _suffix=":O"
                else
                    _suffix="${_ro_suffix}"
                fi
                PROJECT_VOLUME_FLAGS="${PROJECT_VOLUME_FLAGS} -v ${dir}:${_container_path}${_suffix}"
            done
        fi
    fi

    local riotbox_session_dir="${RIOTBOX_SESSION_DIR}"
    mkdir -p "${riotbox_session_dir}"
    chmod 700 "${riotbox_session_dir}"
    # Write project paths so list-sessions can show them without decoding the key
    printf '%s\n' "${PROJECT_DIRS[@]}" > "${riotbox_session_dir}/.projects"
    # Bail if a previous run without --userns=keep-id left dirs owned by
    # a subordinate UID.
    if [ ! -w "${riotbox_session_dir}" ]; then
        echo "ERROR: ${riotbox_session_dir} is not writable (wrong UID from a previous run)." >&2
        echo "  Fix with: sudo chown -R $(id -u):$(id -g) ${riotbox_session_dir}" >&2
        exit 1
    fi
    PROJECT_VOLUME_FLAGS="${PROJECT_VOLUME_FLAGS} -v ${riotbox_session_dir}:/home/llm/.claude:z"

    # ── Sync each registered agent's host config into the session dir ──
    # The agent registry tells us which agents to sync. Each manifest's
    # host_sync function knows where its host config lives and what
    # volume flags to emit. Adding a new agent extends this loop without
    # editing this file.
    # shellcheck source=../agents/registry.sh
    source "${ROOT_DIR}/agents/registry.sh"
    local _agent _sync_flags
    for _agent in "${AGENT_REGISTRY[@]}"; do
        _sync_flags="$(agent_call "${_agent}" host_sync "${riotbox_session_dir}")"
        if [ -n "${_sync_flags}" ]; then
            PROJECT_VOLUME_FLAGS="${PROJECT_VOLUME_FLAGS} ${_sync_flags}"
        fi
    done
    unset _agent _sync_flags

    # ── Container name ────────────────────────────────────────────────
    generate_container_name "${PROJECT_DIRS[@]}"
}

# Print the resolved mount table in `host:container:mode` form (one per
# line, mode is `rw`, `ro`, or `ovl` (`:O` overlay)). Reads from
# PROJECT_VOLUME_FLAGS, so the caller must run setup_projects first.
print_mounts_triple() {
    local flag suffix host container mode
    # PROJECT_VOLUME_FLAGS is space-separated `-v <spec>` pairs. Parse with
    # a simple state machine: each `-v` token is followed by one spec.
    local expect_spec=0
    # shellcheck disable=SC2086  # intentional word-splitting on the flag string
    for flag in ${PROJECT_VOLUME_FLAGS}; do
        if [ "${expect_spec}" = "0" ]; then
            if [ "${flag}" = "-v" ]; then
                expect_spec=1
            fi
            continue
        fi
        expect_spec=0
        # Spec is host:container[:opts]. Split on the LAST colon to allow
        # paths to contain `:` is unsupported (matches the existing whole-
        # script LIMITATION). Use the first two colons as separators.
        host="${flag%%:*}"
        local rest="${flag#*:}"
        # rest is `container[:opts]`. opts can be `z`, `ro`, `ro,z`, `rw,z`.
        # The container path itself never contains `:` in this codebase.
        if [[ "${rest}" == *:* ]]; then
            container="${rest%%:*}"
            suffix="${rest#*:}"
        else
            container="${rest}"
            suffix=""
        fi
        case "${suffix}" in
            "")      mode="rw" ;;
            "O")     mode="ovl" ;;
            *)
                case ",${suffix}," in
                    *,ro,*) mode="ro" ;;
                    *)      mode="rw" ;;
                esac
                ;;
        esac
        printf '%s:%s:%s\n' "${host}" "${container}" "${mode}"
    done
}

# ── Script-mode entry ────────────────────────────────────────────────
# When this file is executed (not sourced), parse --format= flags and
# emit the resolved mount table on stdout. Sourced callers reach the
# top of the file and stop here without running setup.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    set -euo pipefail

    OUTPUT_FORMAT="podman"
    PROJECT_ARGS=()
    for arg in "$@"; do
        case "${arg}" in
            --format=podman) OUTPUT_FORMAT="podman" ;;
            --format=triple) OUTPUT_FORMAT="triple" ;;
            --format=*)
                echo "ERROR: unknown --format value: ${arg#--format=}" >&2
                echo "       allowed: podman, triple" >&2
                exit 2
                ;;
            *) PROJECT_ARGS+=("${arg}") ;;
        esac
    done

    # ROOT_DIR is required by setup_projects (sources agents/registry.sh).
    if [ -z "${ROOT_DIR:-}" ]; then
        ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    fi

    raw="${RIOTBOX_PROJECTS:-${PROJECT_ARGS[*]:-}}"
    setup_projects "${raw}"

    case "${OUTPUT_FORMAT}" in
        podman)
            # Trim leading whitespace and emit each `-v <spec>` pair on its
            # own line so output is consistent with detect-mounts.sh.
            # shellcheck disable=SC2086  # intentional word-splitting
            set -- ${PROJECT_VOLUME_FLAGS}
            while [ $# -ge 2 ]; do
                if [ "$1" = "-v" ]; then
                    printf -- '-v %s\n' "$2"
                    shift 2
                else
                    shift
                fi
            done
            ;;
        triple)
            print_mounts_triple
            ;;
    esac
fi
