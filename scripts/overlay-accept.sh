#!/usr/bin/env bash
set -euo pipefail
# overlay-accept.sh — Apply overlay changes to host project.
# Usage: overlay-accept.sh [--force] [project-path]
# Required env: ROOT_DIR

source "${ROOT_DIR}/scripts/overlay-resolve.sh"

FORCE=false
PROJECT_ARG=""
for arg in "$@"; do
    case "${arg}" in
        --force|-f) FORCE=true ;;
        *) PROJECT_ARG="${arg}" ;;
    esac
done

resolve_overlay "${PROJECT_ARG}"

upper="${OVERLAY_DIR}/upper"
work="${OVERLAY_DIR}/work"
project="${OVERLAY_PROJECT_DIR}"

if ! overlay_has_changes "${OVERLAY_DIR}"; then
    echo "No overlay changes to apply for ${project}."
    exit 0
fi

echo "Overlay changes to apply to: ${project}"
echo ""

# Dry-run: list what will happen
added=0 modified=0 deleted=0
while IFS= read -r path; do
    rel="${path#"${upper}"/}"
    base="$(basename "${path}")"
    dir="$(dirname "${rel}")"

    if [[ "${base}" == ".wh..wh..opq" ]]; then
        echo "  REPLACE  ${dir}/"
        deleted=$((deleted + 1))
    elif [[ "${base}" == .wh.* ]]; then
        real_name="${base#.wh.}"
        echo "  DELETE   ${dir}/${real_name}"
        deleted=$((deleted + 1))
    elif [ -f "${path}" ]; then
        if [ -f "${project}/${rel}" ]; then
            echo "  MODIFY   ${rel}"
            modified=$((modified + 1))
        else
            echo "  ADD      ${rel}"
            added=$((added + 1))
        fi
    fi
done < <(find "${upper}" -mindepth 1 -not -type d 2>/dev/null | sort)

echo ""
echo "Summary: ${added} added, ${modified} modified, ${deleted} deleted"
echo ""

if [ "${FORCE}" != true ]; then
    read -rp "Apply these changes? [y/N] " confirm
    if [[ ! "${confirm}" =~ ^[Yy]$ ]]; then
        echo "Aborted."
        exit 0
    fi
fi

# Apply changes
# Process opaque whiteouts first (directory-level), then file whiteouts, then copies.
# This ordering prevents copying into a directory that's about to be replaced.

# Pass 1: opaque dirs
while IFS= read -r path; do
    rel="${path#"${upper}"/}"
    dir="$(dirname "${rel}")"
    base="$(basename "${path}")"
    if [[ "${base}" == ".wh..wh..opq" ]]; then
        rm -rf "${project:?}/${dir:?}"
        mkdir -p "${project}/${dir}"
    fi
done < <(find "${upper}" -name ".wh..wh..opq" 2>/dev/null)

# Pass 2: file whiteouts
while IFS= read -r path; do
    rel="${path#"${upper}"/}"
    dir="$(dirname "${rel}")"
    base="$(basename "${path}")"
    if [[ "${base}" == .wh.* ]] && [[ "${base}" != ".wh..wh..opq" ]]; then
        real_name="${base#.wh.}"
        rm -rf "${project:?}/${dir:?}/${real_name:?}"
    fi
done < <(find "${upper}" -name ".wh.*" 2>/dev/null)

# Pass 3: copy new/modified files and directories
while IFS= read -r path; do
    rel="${path#"${upper}"/}"
    base="$(basename "${path}")"
    [[ "${base}" == .wh.* ]] && continue
    if [ -d "${path}" ]; then
        mkdir -p "${project}/${rel}"
    else
        dir="$(dirname "${rel}")"
        mkdir -p "${project}/${dir}"
        # `cp -a` preserves context+xattr via fsetxattr, which (a) the kernel
        # denies under SELinux when the project bind mount has a different
        # label class, and (b) would smear container_t-derived labels onto
        # host files. Drop both; mode/timestamps/links are still preserved.
        cp -a --no-preserve=context,xattr "${path}" "${project}/${rel}"
    fi
done < <(find "${upper}" -mindepth 1 2>/dev/null | sort)

# Clean up overlay data
rm -rf "${upper}" "${work}"
mkdir -p "${upper}" "${work}"

echo "Applied. Overlay data cleaned."
