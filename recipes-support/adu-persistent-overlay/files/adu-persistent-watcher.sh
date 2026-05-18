#!/bin/bash
# Watch /etc (and /etc/ssh for host keys) for changes to persistent files and
# propagate them to /adu/system. Debounced to coalesce close-write storms.

set +e

CONFIG_FILE="/etc/overlay/overlay.conf"
if [ -f "$CONFIG_FILE" ]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
fi

PERSIST_BASE="${PERSIST_BASE:-/adu}"
SYSTEM_DIR="${SYSTEM_DIR:-${PERSIST_BASE}/system}"
DEBOUNCE_SECONDS="${WATCHER_DEBOUNCE:-1}"

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

# Build a set of basenames to watch.
declare -A WATCH_NAMES
for spec in "${SYNC_FILES[@]}"; do
    IFS=':' read -r _src tgt <<< "$spec"
    WATCH_NAMES["$(basename "$tgt")"]=1
done

if ! command -v inotifywait >/dev/null 2>&1; then
    echo "ERROR: inotifywait not found (install inotify-tools)" >&2
    exit 1
fi

echo "=== ADU persistent-watcher started ==="
echo "Watching: /etc and /etc/ssh (host keys)"

# Watch /etc top-level files AND /etc/ssh top-level files (for ssh_host_*).
# Use -m for monitor mode. Watch close_write,moved_to (the rename target side
# of atomic writes), create (new files), delete (file removal).
WATCH_DIRS=(/etc)
[ -d /etc/ssh ] && WATCH_DIRS+=(/etc/ssh)

# Pending event accumulator: name -> 1
declare -A pending

flush_pending() {
    local n
    for n in "${!pending[@]}"; do
        /usr/lib/adu/sync-persistent-files.sh "$n" || true
    done
    pending=()
}

# We tail inotifywait via a coproc so we can use a non-blocking-ish loop with
# debounce. The strategy: use read with a timeout once a pending event exists.
inotifywait -m -q --format '%w|%e|%f' \
    -e close_write -e moved_to -e create -e delete \
    "${WATCH_DIRS[@]}" 2>/dev/null | \
while IFS='|' read -r wdir events fname; do
    [ -n "$fname" ] || continue
    # /etc/<name>
    if [ "$wdir" = "/etc/" ] || [ "$wdir" = "/etc" ]; then
        if [ -n "${WATCH_NAMES[$fname]:-}" ]; then
            pending["$fname"]=1
        fi
    elif [ "$wdir" = "/etc/ssh/" ] || [ "$wdir" = "/etc/ssh" ]; then
        case "$fname" in
            ssh_host_*) pending["$fname"]=1 ;;
        esac
    fi
    # Debounce: keep absorbing events for $DEBOUNCE_SECONDS, then flush.
    # Use a non-blocking read with short timeout to coalesce bursts.
    while IFS='|' read -t "$DEBOUNCE_SECONDS" -r wdir2 events2 fname2; do
        [ -n "$fname2" ] || continue
        if [ "$wdir2" = "/etc/" ] || [ "$wdir2" = "/etc" ]; then
            if [ -n "${WATCH_NAMES[$fname2]:-}" ]; then
                pending["$fname2"]=1
            fi
        elif [ "$wdir2" = "/etc/ssh/" ] || [ "$wdir2" = "/etc/ssh" ]; then
            case "$fname2" in
                ssh_host_*) pending["$fname2"]=1 ;;
            esac
        fi
    done
    flush_pending
done