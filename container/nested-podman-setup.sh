#!/usr/bin/env bash
# Runtime setup for rootless podman-in-podman.
#
# Three things rootless nested podman needs that cannot be baked into the
# image (they all depend on /proc/self/{uid,gid}_map, which only exists at
# runtime, or on the user's actual uid):
#
# 1. File capabilities on /usr/bin/newuidmap and /usr/bin/newgidmap. The EL10
#    shadow-utils RPM ships them setuid-root, but `podman build` (rootless)
#    strips the setuid bit when writing image layers — uid 0 inside the build
#    is not real root, so the kernel cannot honor a setuid bit recorded by an
#    unprivileged writer. We restore an equivalent privilege via setcap, which
#    works inside a user namespace as long as CAP_SETFCAP is in the bounding
#    set (verified via /proc/self/status:CapBnd).
#
# 2. /etc/subuid and /etc/subgid expressed in the OUTER container's uid space,
#    excluding the running user's own uid. The inner podman's call to
#    newuidmap uses these as "outside" uids, which must be valid in the outer
#    namespace; the kernel rejects any line that includes the caller's own
#    uid. We discover the outer's mapped range from /proc/self/{uid,gid}_map
#    and split it around `id -u` / `id -g` into one or two contiguous lines.
#
# 3. Inner storage driver pinned to vfs. The image pre-configures
#    overlay+fuse-overlayfs (good for the outer's storage of inner images),
#    but inner crun fails on `mkdir /run/secrets` when its rootfs is on
#    nested overlay. vfs is slow but correct; for occasional nested use the
#    cost is acceptable, and overlay is left in place for non-nested mode.
#
# Idempotent. Executed (NOT sourced) by entrypoint.sh when RIOTBOX_NESTED=1
# — sourcing leaks `set -euo pipefail` into the parent shell, which trips
# RVM's cd hook on a later subshell cd in plugin-setup.sh.

set -euo pipefail

# --- 1. v3 file caps on newuidmap/newgidmap -----------------------------------
# `setcap` defaults to writing v2 capability xattrs, which only apply when the
# exec'd process runs as host-root (kuid_t 0 in the host's userns). Inside
# our keep-id container our user is uid 1000 mapped to *outer* uid 0 — root
# in our userns but NOT in the host's. v2 caps are silently ignored at exec.
#
# `-n <rootid>` writes a v3 cap stamped with the userns owner uid. With the
# rootid set to our running uid, the kernel matches the cap against the
# userns owned by that host uid (which is us) and grants newuidmap CAP_SETUID
# at exec. Without the v3 stamp, newuidmap exec drops to zero effective caps
# and every later /proc/<pid>/uid_map write returns EPERM.
#
# Re-set every run: setcap is idempotent and the rootid only fits the running
# user, so a stale v3 cap from a different host uid would silently no-op.
if [ -e /usr/bin/newuidmap ] && [ -e /usr/bin/newgidmap ]; then
    sudo setcap -n "$(id -u)" cap_setuid+ep /usr/bin/newuidmap
    sudo setcap -n "$(id -u)" cap_setgid+ep /usr/bin/newgidmap
fi

# --- 2. /etc/subuid and /etc/subgid alignment ---------------------------------
# Compute the union of all "inside_id..inside_id+count-1" ranges from a
# /proc/self/*_map file, then emit "start length" lines that cover that
# union EXCEPT uid 0 and the given excluded uid. Two restrictions apply:
#
#   * uid 0 cannot be a subordinate. The kernel rejects writes that map an
#     inner uid to outer uid 0 from an unprivileged caller, even if /etc/
#     sub{u,g}id permits it. Always clamp lo to >= 1.
#
#   * The user's own uid cannot be subordinate. newuidmap rejects /etc/
#     sub{u,g}id lines that include the calling user's uid. Split around it.
emit_subid_lines() {
    local map_file="$1" excluded="$2"
    awk -v ex="${excluded}" '
        # Each /proc/*_map entry covers inside uids [$1 .. $1+$3-1].
        { ranges[NR, "lo"] = $1; ranges[NR, "hi"] = $1 + $3 - 1; n = NR }
        END {
            # Sort by lo (insertion sort — n is small, at most a handful).
            for (i = 2; i <= n; i++) {
                for (j = i; j > 1 && ranges[j-1, "lo"] > ranges[j, "lo"]; j--) {
                    tlo = ranges[j-1, "lo"]; thi = ranges[j-1, "hi"]
                    ranges[j-1, "lo"] = ranges[j, "lo"]; ranges[j-1, "hi"] = ranges[j, "hi"]
                    ranges[j, "lo"] = tlo; ranges[j, "hi"] = thi
                }
            }
            # Merge adjacent/overlapping ranges into [min_lo .. max_hi].
            merged_lo = ranges[1, "lo"]; merged_hi = ranges[1, "hi"]
            for (i = 2; i <= n; i++) {
                if (ranges[i, "lo"] <= merged_hi + 1) {
                    if (ranges[i, "hi"] > merged_hi) merged_hi = ranges[i, "hi"]
                } else {
                    print_split(merged_lo, merged_hi, ex)
                    merged_lo = ranges[i, "lo"]; merged_hi = ranges[i, "hi"]
                }
            }
            print_split(merged_lo, merged_hi, ex)
        }
        function print_split(lo, hi, ex,    left_count, right_count) {
            # uid 0 cannot be a subordinate (kernel restriction); clamp.
            if (lo < 1) lo = 1
            if (lo > hi) return
            if (lo == hi && lo == ex) return
            if (ex < lo || ex > hi) {
                print lo, hi - lo + 1
                return
            }
            left_count = ex - lo
            right_count = hi - ex
            if (left_count > 0) print lo, left_count
            if (right_count > 0) print ex + 1, right_count
        }
    ' "${map_file}"
}

write_subid_file() {
    local target="$1" map_file="$2" excluded_id="$3" kind="$4"
    local lines
    lines="$(emit_subid_lines "${map_file}" "${excluded_id}")"
    if [ -z "${lines}" ]; then
        echo "nested-podman-setup: no usable ${kind} range in ${map_file} after excluding ${excluded_id}" >&2
        return 1
    fi
    local user_name
    user_name="$(id -un)"
    local rendered=""
    while IFS=' ' read -r start length; do
        [ -z "${start}" ] && continue
        rendered="${rendered}${user_name}:${start}:${length}"$'\n'
    done <<< "${lines}"
    sudo tee "${target}" >/dev/null <<EOF
${rendered}
EOF
}

write_subid_file /etc/subuid /proc/self/uid_map "$(id -u)" UID
write_subid_file /etc/subgid /proc/self/gid_map "$(id -g)" GID

# --- 3. inner storage driver: vfs ---------------------------------------------
# The Dockerfile pre-installs overlay+fuse-overlayfs in
# ~/.config/containers/storage.conf for the outer's storage of inner images,
# but inner crun fails on `mkdir /run/secrets` when its rootfs is on nested
# overlay. Switching to vfs is the only working option — confirmed empirically
# across alpine and ubi10 inner images, with and without -t.
#
# Done at runtime (not in the Dockerfile) so non-nested mode keeps the
# faster overlay storage when the user is using podman host-side caches.
mkdir -p "${HOME}/.config/containers"
cat > "${HOME}/.config/containers/storage.conf" <<'EOF'
[storage]
driver = "vfs"
EOF
