#!/bin/bash
# Sync /etc state to /adu/system. Called by:
#   - adu-persistent-watcher (after debounce, on inotify event)
#   - adu-persistent-overlay.service ExecStop (final shutdown sync fallback)
#
# Single-file mode: ./sync-persistent-files.sh <basename>
# All-files mode:   ./sync-persistent-files.sh

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

sync_one() {
    local src_rel="$1" tgt="$2"
    local dst="${SYSTEM_DIR}/${src_rel}"
    [ -f "$tgt" ] || return 0
    mkdir -p "$(dirname "$dst")"
    local tmp
    tmp="$(mktemp -p "$(dirname "$dst")" ".$(basename "$dst").XXXXXX")" || return 1
    if ! cp "$tgt" "$tmp" 2>/dev/null; then
        rm -f "$tmp"; return 1
    fi
    chmod --reference="$tgt" "$tmp" 2>/dev/null || true
    chown --reference="$tgt" "$tmp" 2>/dev/null || true
    sync "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$dst"
}

if [ -n "$1" ]; then
    # Single-file mode (called by watcher).
    name="$1"
    for spec in "${SYNC_FILES[@]}"; do
        IFS=':' read -r src_rel tgt <<< "$spec"
        if [ "$(basename "$tgt")" = "$name" ] || [ "$src_rel" = "$name" ]; then
            sync_one "$src_rel" "$tgt"
            exit 0
        fi
    done
    # Special: ssh host keys (file under /etc/ssh)
    case "$name" in
        ssh_host_*)
            mkdir -p "${SYSTEM_DIR}/ssh"
            if [ -f "/etc/ssh/$name" ]; then
                tmp="$(mktemp -p "${SYSTEM_DIR}/ssh" ".${name}.XXXXXX")"
                cp "/etc/ssh/$name" "$tmp"
                chmod --reference="/etc/ssh/$name" "$tmp" 2>/dev/null || true
                chown --reference="/etc/ssh/$name" "$tmp" 2>/dev/null || true
                sync "$tmp" 2>/dev/null || true
                mv -f "$tmp" "${SYSTEM_DIR}/ssh/$name"
            fi
            exit 0
            ;;
    esac
    echo "  [skip] $name not in SYNC_FILES" >&2
    exit 0
fi

# All-files mode (called at shutdown).
echo "=== ADU Sync /etc -> /adu/system ==="
for spec in "${SYNC_FILES[@]}"; do
    IFS=':' read -r src_rel tgt <<< "$spec"
    sync_one "$src_rel" "$tgt"
done
# Also sync ssh host keys
if [ -d /etc/ssh ]; then
    mkdir -p "${SYSTEM_DIR}/ssh"
    for k in /etc/ssh/ssh_host_*; do
        [ -f "$k" ] || continue
        name="$(basename "$k")"
        tmp="$(mktemp -p "${SYSTEM_DIR}/ssh" ".${name}.XXXXXX")"
        cp "$k" "$tmp"
        chmod --reference="$k" "$tmp" 2>/dev/null || true
        chown --reference="$k" "$tmp" 2>/dev/null || true
        mv -f "$tmp" "${SYSTEM_DIR}/ssh/$name"
    done
fi
sync
echo "Sync complete"
exit 0