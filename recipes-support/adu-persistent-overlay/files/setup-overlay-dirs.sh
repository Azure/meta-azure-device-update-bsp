#!/bin/bash
# Setup overlay directory structure and initialize files

set -e

# Load configuration from rootfs
CONFIG_FILE="/etc/overlay/overlay.conf"
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
else
    echo "ERROR: Configuration file not found: $CONFIG_FILE"
    exit 1
fi

PERSIST_BASE="${PERSIST_BASE:-/adu}"
OVERLAY_BASE="${OVERLAY_BASE:-${PERSIST_BASE}/overlay}"
WORK_BASE="${WORK_BASE:-${PERSIST_BASE}/work}"
SYSTEM_DIR="${SYSTEM_DIR:-${PERSIST_BASE}/system}"

echo "=== ADU Persistent Overlay Setup ==="
echo "Persistent base: ${PERSIST_BASE}"

# NOTE: /adu partition structure is created by adu-filesystem-layout service
# This service runs after adu-filesystem-layout, so /adu/* directories already exist
# We only verify and ensure correct ownership here

# Ensure base directories exist (they should already be created by adu-filesystem-layout)
mkdir -p "${OVERLAY_BASE}"
mkdir -p "${WORK_BASE}"
mkdir -p "${SYSTEM_DIR}"
mkdir -p "${PERSIST_BASE}/.backups"

# NOTE: /adu/data directory structure is created by adu-filesystem-layout service
# This service (adu-persistent-overlay) runs after adu-filesystem-layout
# We just verify the directories exist and fix ownership if needed
if [ -d "${PERSIST_BASE}/data" ]; then
    echo "Verifying /adu/data ownership and permissions..."
    chown -R adu:adu "${PERSIST_BASE}/data" 2>/dev/null || echo "WARNING: adu user not found, skipping ownership"
    chmod 0770 "${PERSIST_BASE}/data"
    # Ensure subdirectories have correct permissions
    for subdir in states downloads extensions; do
        if [ -d "${PERSIST_BASE}/data/$subdir" ]; then
            chmod 0770 "${PERSIST_BASE}/data/$subdir"
        fi
    done
    echo "✓ /adu/data ownership verified"
else
    echo "ERROR: ${PERSIST_BASE}/data not found - adu-filesystem-layout must run first"
    exit 1
fi

# Create symlink /var/lib/adu → /adu/data (same pattern as /var/log/adu → /adu/logs)
# Remove existing directory if present (first boot migration)
if [ -d "/var/lib/adu" ] && [ ! -L "/var/lib/adu" ]; then
    echo "Migrating /var/lib/adu to ${PERSIST_BASE}/data"
    # Copy existing content to persistent storage (but skip if circular symlinks exist)
    find /var/lib/adu -maxdepth 1 -type d -exec basename {} \; | while read -r subdir; do
        if [ "$subdir" != "adu" ] && [ -d "/var/lib/adu/$subdir" ] && [ ! -L "/var/lib/adu/$subdir" ]; then
            cp -a "/var/lib/adu/$subdir" "${PERSIST_BASE}/data/" 2>/dev/null || true
        fi
    done
    # Remove original directory
    rm -rf /var/lib/adu
fi

# Create or update symlink
if [ ! -e "/var/lib/adu" ]; then
    ln -sf "${PERSIST_BASE}/data" /var/lib/adu
    echo "Created symlink: /var/lib/adu → ${PERSIST_BASE}/data"
elif [ -L "/var/lib/adu" ]; then
    # Verify symlink points to correct location
    current_target=$(readlink /var/lib/adu)
    if [ "$current_target" != "${PERSIST_BASE}/data" ]; then
        ln -sf "${PERSIST_BASE}/data" /var/lib/adu
        echo "Updated symlink: /var/lib/adu → ${PERSIST_BASE}/data"
    fi
fi

echo "Created base directories"

# Create overlay directories for each path
if [ -n "${OVERLAY_DIRS}" ]; then
    for dir in "${OVERLAY_DIRS[@]}"; do
        # Convert path to safe directory name
        safe_name=$(echo "$dir" | tr '/' '-' | sed 's/^-//')
        
        mkdir -p "${OVERLAY_BASE}/${safe_name}"
        mkdir -p "${WORK_BASE}/${safe_name}"
        
        echo "  Created overlay structure for: ${dir}"
    done
fi

# Initialize critical files if they don't exist
if [ -n "${BIND_MOUNTS}" ]; then
    for mount_spec in "${BIND_MOUNTS[@]}"; do
        IFS=':' read -r source_rel target <<< "$mount_spec"
        source_path="${SYSTEM_DIR}/${source_rel}"
        
        if [ ! -e "${source_path}" ]; then
            # Get parent directory
            source_dir=$(dirname "${source_path}")
            mkdir -p "${source_dir}"
            
            # Copy from rootfs if target exists
            if [ -e "${target}" ]; then
                echo "Initializing ${source_path} from ${target}"
                cp -a "${target}" "${source_path}"
                
                # For files, set proper permissions based on type
                if [ -f "${source_path}" ]; then
                    case "$(basename ${target})" in
                        shadow|gshadow)
                            chmod 640 "${source_path}"
                            chown root:shadow "${source_path}" 2>/dev/null || chown root:root "${source_path}"
                            ;;
                        passwd|group)
                            chmod 644 "${source_path}"
                            chown root:root "${source_path}"
                            ;;
                        machine-id)
                            chmod 444 "${source_path}"
                            chown root:root "${source_path}"
                            ;;
                        *)
                            # Preserve original permissions
                            ;;
                    esac
                    # Record rootfs sha256 fingerprint so subsequent boots can
                    # distinguish an intentional image-level rotation of these
                    # auth files (refresh persistent) from a runtime change
                    # made by the user (keep persistent).
                    case "$(basename ${target})" in
                        shadow|passwd|group|gshadow)
                            sha256sum "${target}" | awk '{print $1}' > "${source_path}.rootfs.sha256"
                            chmod 600 "${source_path}.rootfs.sha256"
                            ;;
                    esac
                fi
            else
                # Target does not exist in the rootfs (e.g. /etc/apt/* on images
                # that do not install apt). Skip seeding — mount-critical-binds.sh
                # will then see no source under ${SYSTEM_DIR} and skip the bind
                # mount, avoiding wrong-type (file-vs-dir) mounts being grafted
                # onto /etc.
                echo "  [skip] Target ${target} not present in rootfs; not seeding ${source_path}"
            fi
        else
            # Persistent copy exists. Decide who wins between the persistent
            # /adu/system/<file> and the new rootfs /etc/<file> for auth files.
            #
            #   - First boot ever: persistent did not exist -> seeded above.
            #   - Re-run with SAME image as last seed: persistent must win,
            #     otherwise we clobber whatever the user did at runtime
            #     (e.g. `passwd root`) on every boot.
            #   - After an A/B swap to a NEW image where the maintainer
            #     intentionally rotated /etc/shadow: rootfs must win so the
            #     image-level credential rotation takes effect.
            #
            # We distinguish the two cases via a sha256 fingerprint of the
            # rootfs file recorded at the moment of last seed/refresh.
            case "$(basename ${target})" in
                shadow|passwd|group|gshadow)
                    if [ -f "${target}" ] && [ -f "${source_path}" ]; then
                        seed_marker="${source_path}.rootfs.sha256"
                        current_rootfs_sha=$(sha256sum "${target}" | awk '{print $1}')
                        recorded_sha=""
                        [ -f "${seed_marker}" ] && recorded_sha=$(cat "${seed_marker}")

                        if [ -z "${recorded_sha}" ]; then
                            # Persistent file exists but no marker — upgrade path
                            # from older overlay versions. Adopt current rootfs
                            # as the baseline WITHOUT touching the persistent
                            # copy: on uncertainty, user data wins.
                            echo "${current_rootfs_sha}" > "${seed_marker}"
                            chmod 600 "${seed_marker}"
                            echo "  [marker] Adopted current rootfs sha for ${target} (preserving persistent copy)"
                        elif [ "${current_rootfs_sha}" != "${recorded_sha}" ]; then
                            # Image rotated this file. Refresh persistent.
                            echo "  [refresh] Image rotated ${target} (sha changed); refreshing persistent copy"
                            cp -a "${target}" "${source_path}"
                            case "$(basename ${target})" in
                                shadow|gshadow)
                                    chmod 640 "${source_path}"
                                    chown root:shadow "${source_path}" 2>/dev/null || chown root:root "${source_path}"
                                    ;;
                                passwd|group)
                                    chmod 644 "${source_path}"
                                    chown root:root "${source_path}"
                                    ;;
                            esac
                            echo "${current_rootfs_sha}" > "${seed_marker}"
                            chmod 600 "${seed_marker}"
                        fi
                        # else: image unchanged -> persistent wins, do nothing.
                    fi
                    ;;
            esac
        fi
    done
fi

# Run migration if enabled and not yet completed
if [ "${AUTO_MIGRATE}" = "yes" ] && [ ! -f "${PERSIST_BASE}/.migration-complete" ]; then
    echo "Running first-time migration..."
    /usr/lib/adu/migrate-to-overlay.sh || {
        echo "WARNING: Migration failed, continuing anyway"
    }
fi

echo "Setup complete"
exit 0
