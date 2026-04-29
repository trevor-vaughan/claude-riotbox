#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# credfile-vars.sh — Build container -v and -e flags for credential files.
#
# Sourced (not executed) by launch.sh. Provides:
#   credfile_flags — for each entry in RIOTBOX_CREDFILE_VARS where the env
#                    var is set AND points to an existing regular file:
#                      * emits  -v <host>:<container>:ro,z
#                      * emits  -e VAR=<container>   (rewrites the path)
#                    Skip cases (var unset / path missing / wrong type) print
#                    a notice on stderr and produce no flags for that entry.
#                    Empty stdout when nothing applies.
#
# Format of RIOTBOX_CREDFILE_VARS: whitespace-separated entries, each
# "VAR_NAME:/container/path". The container path is the location the file
# is bind-mounted to AND the value the env var is rewritten to inside the
# container. Defaults cover the common cloud-SDK credfile vars.
#
# Read-only is the only supported mount mode here. If a tool needs RW
# access to a host file (OAuth refresh tokens), wire it explicitly like
# Claude's .credentials.json or opencode's auth.json — those have a
# different threat model and don't belong in this generic helper.
# ─────────────────────────────────────────────────────────────────────────────

RIOTBOX_CREDFILE_VARS_DEFAULT="\
GOOGLE_APPLICATION_CREDENTIALS:/run/secrets/gcp-creds.json \
AWS_SHARED_CREDENTIALS_FILE:/run/secrets/aws-credentials \
AWS_CONFIG_FILE:/run/secrets/aws-config \
KUBECONFIG:/run/secrets/kubeconfig"

credfile_flags() {
    local vars="${RIOTBOX_CREDFILE_VARS:-${RIOTBOX_CREDFILE_VARS_DEFAULT}}"
    local entry name container_path host_path flags=""
    for entry in ${vars}; do
        name="${entry%%:*}"
        container_path="${entry#*:}"
        if [ -z "${name}" ] || [ "${name}" = "${container_path}" ]; then
            echo "Notice: malformed credfile entry '${entry}', skipping" >&2
            continue
        fi
        host_path="${!name:-}"
        if [ -z "${host_path}" ]; then
            continue
        fi
        if [ ! -e "${host_path}" ]; then
            echo "Notice: ${name}=${host_path} does not exist, not mounting" >&2
            continue
        fi
        if [ ! -f "${host_path}" ]; then
            echo "Notice: ${name}=${host_path} is not a regular file, not mounting" >&2
            continue
        fi
        if [ -z "${flags}" ]; then
            flags="-v ${host_path}:${container_path}:ro,z -e ${name}=${container_path}"
        else
            flags="${flags} -v ${host_path}:${container_path}:ro,z -e ${name}=${container_path}"
        fi
    done
    printf '%s' "${flags}"
}
