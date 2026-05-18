#!/bin/bash
# Restore persistent /etc state at boot, with line-level 3-way merge for auth
# files so that maintainer-driven changes in a new A/B rootfs (e.g. a new
# system user) are folded in WITHOUT clobbering runtime-set user credentials.
#
# This replaces bind-mounting /etc/{passwd,shadow,group,gshadow,hostname,
# timezone,machine-id} — which is fundamentally broken because shadow-utils
# tools (chpasswd, usermod, useradd, ...) write a temp file and rename() it
# over the target. Renaming over a bind-mount target returns EBUSY, so any
# password change fails. With this script we COPY persistent state into /etc
# at boot; runtime writes go to /etc (a normal file). adu-persistent-watcher
# pushes runtime changes back to /adu/system.

set +e

CONFIG_FILE="/etc/overlay/overlay.conf"
if [ -f "$CONFIG_FILE" ]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
else
    echo "ERROR: $CONFIG_FILE not found" >&2
    exit 1
fi

PERSIST_BASE="${PERSIST_BASE:-/adu}"
SYSTEM_DIR="${SYSTEM_DIR:-${PERSIST_BASE}/system}"
BASELINE_DIR="${SYSTEM_DIR}/baseline"

echo "=== ADU Restore Persistent /etc Files ==="

if [ -z "${SYNC_FILES+x}" ] || [ ${#SYNC_FILES[@]} -eq 0 ]; then
    SYNC_FILES=(
        "passwd:/etc/passwd"
        "shadow:/etc/shadow"
        "group:/etc/group"
        "gshadow:/etc/gshadow"
        "hostname:/etc/hostname"
        "timezone:/etc/timezone"
        "machine-id:/etc/machine-id"
        "du-config.json:/etc/adu/du-config.json"
    )
fi

mkdir -p "${SYSTEM_DIR}" "${BASELINE_DIR}"

# Atomic in-place replace of $2 with the contents of $1. Preserves $2's mode
# and owner if $2 exists.
atomic_install() {
    local src="$1" dst="$2"
    local dst_dir
    dst_dir="$(dirname "$dst")"
    [ -d "$dst_dir" ] || mkdir -p "$dst_dir"
    local tmp
    tmp="$(mktemp -p "$dst_dir" ".$(basename "$dst").XXXXXX")" || return 1
    if ! cp "$src" "$tmp" 2>/dev/null; then
        rm -f "$tmp"; return 1
    fi
    if [ -e "$dst" ]; then
        chmod --reference="$dst" "$tmp" 2>/dev/null || true
        chown --reference="$dst" "$tmp" 2>/dev/null || true
    fi
    sync "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$dst"
}

# 3-way line merge for colon-separated files (passwd, shadow, group, gshadow).
# Keys are the username/groupname in field 1. Writes merged content to stdout.
#
# Rules per key:
#   - in rootfs only            -> emit rootfs (new system user from update)
#   - in persisted only         -> emit persisted (runtime-added user)
#   - in both, persisted=rootfs -> emit unchanged
#   - in both, persisted=base   -> emit rootfs   (image changed, user did not)
#   - in both, rootfs=base      -> emit persisted (user changed, image did not)
#   - in both, all differ:
#       * shadow/gshadow        -> emit persisted (preserve password hash)
#       * passwd/group          -> emit rootfs   (uid/gid/membership alignment)
#
# Output order: rootfs entries in rootfs order, then persisted-only entries.
merge_three_way() {
    local rootfs="$1" persist="$2" baseline="$3" kind="$4"
    awk -F: -v kind="$kind" -v BFILE="$baseline" '
        FILENAME == ARGV[1] {
            # rootfs pass
            if ($0 == "" || $0 ~ /^[[:space:]]*#/) next
            k = $1
            R[k] = $0
            r_order[++rn] = k
            next
        }
        FILENAME == ARGV[2] {
            # persist pass
            if ($0 == "" || $0 ~ /^[[:space:]]*#/) next
            k = $1
            P[k] = $0
            next
        }
        FILENAME == ARGV[3] {
            # baseline pass
            if ($0 == "" || $0 ~ /^[[:space:]]*#/) next
            k = $1
            B[k] = $0
            next
        }
        END {
            for (i = 1; i <= rn; i++) {
                k = r_order[i]
                emitted[k] = 1
                rline = R[k]
                if (!(k in P)) { print rline; continue }
                pline = P[k]
                if (rline == pline) { print rline; continue }
                bline = (k in B) ? B[k] : ""
                if (bline == "" || pline == bline) { print rline; continue }
                if (rline == bline) { print pline; continue }
                if (kind == "shadow" || kind == "gshadow") {
                    print pline
                } else {
                    print rline
                }
            }
            for (k in P) {
                if (!(k in emitted)) print P[k]
            }
        }
    ' "$rootfs" "$persist" "$baseline"
}

restore_one() {
    local source_rel="$1" target="$2"
    local persist="${SYSTEM_DIR}/${source_rel}"
    local baseline="${BASELINE_DIR}/${source_rel}"

    if [ ! -f "$persist" ]; then
        if [ -e "$target" ]; then
            mkdir -p "$(dirname "$persist")" "$(dirname "$baseline")"
            cp -a "$target" "$persist"
            cp -a "$target" "$baseline"
            echo "  [seed] $target -> $persist (+ baseline)"
        fi
        return 0
    fi

    if [ ! -e "$target" ]; then
        return 0
    fi

    case "$(basename "$target")" in
        passwd|shadow|group|gshadow)
            local merged rootfs_snap
            merged="$(mktemp)" || return 1
            # Capture the pre-merge rootfs version so we can update baseline
            # AFTER merging without losing the new image's reference state.
            rootfs_snap="$(mktemp)" || { rm -f "$merged"; return 1; }
            cp -a "$target" "$rootfs_snap"
            if [ ! -f "$baseline" ]; then
                # No baseline (legacy upgrade or first boot of new layout).
                # Adopt the rootfs snapshot as baseline so future updates can
                # detect image-level changes; merge then falls back to
                # persisted-wins on overlapping keys.
                cp -a "$rootfs_snap" "$baseline"
            fi
            if merge_three_way "$rootfs_snap" "$persist" "$baseline" "$(basename "$target")" > "$merged" && [ -s "$merged" ]; then
                atomic_install "$merged" "$target"
                atomic_install "$merged" "$persist"
                # Baseline now tracks the NEW rootfs version so the next
                # A/B update can again detect image-level rotation.
                atomic_install "$rootfs_snap" "$baseline"
                echo "  [merge] $target"
            else
                echo "  [warn] merge failed for $target; leaving rootfs version" >&2
            fi
            rm -f "$merged" "$rootfs_snap"
            ;;
        *)
            atomic_install "$persist" "$target"
            echo "  [restore] $persist -> $target"
            ;;
    esac
}

# Snapshot pre-merge rootfs entries into baseline if missing. Doing this here
# (BEFORE restore_one mutates /etc) ensures baseline reflects the rootfs's
# version of the file. setup-overlay-dirs.sh also refreshes baseline whenever
# the rootfs fingerprint changes (image-level rotation).
for spec in "${SYNC_FILES[@]}"; do
    IFS=':' read -r src_rel tgt <<< "$spec"
    if [ -e "$tgt" ] && [ ! -f "${BASELINE_DIR}/${src_rel}" ]; then
        mkdir -p "$(dirname "${BASELINE_DIR}/${src_rel}")"
        cp -a "$tgt" "${BASELINE_DIR}/${src_rel}" 2>/dev/null || true
    fi
done

for spec in "${SYNC_FILES[@]}"; do
    IFS=':' read -r src_rel tgt <<< "$spec"
    restore_one "$src_rel" "$tgt"
done


# SSH host keys: persist /adu/system/ssh/ssh_host_* over /etc/ssh/ so clients
# do not see a key change after an A/B rootfs swap. We deliberately do NOT
# bind-mount /etc/ssh (that shadows rootfs-controlled sshd_config/moduli).
if [ -d "${SYSTEM_DIR}/ssh" ] && [ -d /etc/ssh ]; then
    for k in "${SYSTEM_DIR}/ssh/"ssh_host_*; do
        [ -f "$k" ] || continue
        name="$(basename "$k")"
        atomic_install "$k" "/etc/ssh/$name" && echo "  [restore] ssh host key: $name"
    done
fi

echo "Restore complete"
exit 0