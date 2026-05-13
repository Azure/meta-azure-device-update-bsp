#!/bin/bash
# Setup ADU Swap File for Delta Update Operations
# Delta reconstruction (bspatch/applydiff) requires ~1GB RAM
# Swap size is board-dependent and is read from /etc/adu/board.conf
# (ADU_SWAP_SIZE_MB). Default 2048 MB (RPi4 historical behavior).
# Set ADU_SWAP_SIZE_MB=0 in board.conf to skip swap setup entirely
# (e.g., small QEMU disk).

set -e

# Source board-specific configuration (provides ADU_SWAP_SIZE_MB).
BOARD_CONF="/etc/adu/board.conf"
if [[ -r "$BOARD_CONF" ]]; then
    # shellcheck source=/dev/null
    . "$BOARD_CONF"
fi

SWAP_FILE="${ADU_SWAP_FILE:-/adu/swapfile}"
SWAP_SIZE_MB="${ADU_SWAP_SIZE_MB:-2048}"
LOG_FILE="/adu/health/swap-setup.log"
ADU_UID=800
ADU_GID=800

# Honor opt-out: size=0 means "this board has no spare /adu space, skip".
if [[ "$SWAP_SIZE_MB" -eq 0 ]]; then
    echo "ADU_SWAP_SIZE_MB=0 in $BOARD_CONF — skipping swap setup."
    exit 0
fi

# Ensure health directory exists with proper permissions
# Only accessible by adu user/group (800:800) and root
mkdir -p /adu/health
chown ${ADU_UID}:${ADU_GID} /adu/health
chmod 770 /adu/health

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

log "========================================="
log "ADU Swap File Setup Starting"
log "========================================="

# Check if /adu is mounted
if ! mount | grep -q "on /adu "; then
    log "ERROR: /adu partition is not mounted"
    exit 1
fi

# Check if swap file already exists and is active
if [ -f "$SWAP_FILE" ]; then
    log "Swap file already exists: $SWAP_FILE"
    
    # Check if it's already active
    if swapon -s | grep -q "$SWAP_FILE"; then
        log "Swap file is already active"
        log "Current swap status:"
        swapon -s | tee -a "$LOG_FILE"
        log "Memory info:"
        free -h | tee -a "$LOG_FILE"
        exit 0
    else
        log "Swap file exists but not active, activating..."
        chmod 600 "$SWAP_FILE"
        
        # Verify it's a valid swap file
        if file "$SWAP_FILE" | grep -q "swap file"; then
            swapon "$SWAP_FILE"
            log "✓ Existing swap file activated"
        else
            log "WARNING: Existing file is not a valid swap file, recreating..."
            rm -f "$SWAP_FILE"
        fi
    fi
fi

# Create new swap file if it doesn't exist
if [ ! -f "$SWAP_FILE" ]; then
    log "Creating ${SWAP_SIZE_MB}MB swap file at $SWAP_FILE"
    
    # Check available space in /adu
    AVAILABLE_MB=$(df -BM /adu | awk 'NR==2 {print $4}' | sed 's/M//')
    REQUIRED_MB=$((SWAP_SIZE_MB + 100))  # Add 100MB buffer
    
    if [ "$AVAILABLE_MB" -lt "$REQUIRED_MB" ]; then
        log "ERROR: Insufficient space in /adu partition"
        log "  Available: ${AVAILABLE_MB}MB"
        log "  Required: ${REQUIRED_MB}MB (${SWAP_SIZE_MB}MB swap + 100MB buffer)"
        exit 1
    fi
    
    log "Available space: ${AVAILABLE_MB}MB (sufficient)"
    
    # Create swap file using fallocate (faster than dd on ext4)
    log "Creating swap file..."
    if fallocate -l ${SWAP_SIZE_MB}M "$SWAP_FILE" 2>&1 | tee -a "$LOG_FILE"; then
        log "✓ Swap file created successfully"
    else
        log "ERROR: Failed to create swap file"
        rm -f "$SWAP_FILE"
        exit 1
    fi
    
    # Set proper permissions
    chmod 600 "$SWAP_FILE"
    
    # Format as swap
    log "Formatting swap file..."
    if mkswap "$SWAP_FILE" 2>&1 | tee -a "$LOG_FILE"; then
        log "✓ Swap file formatted"
    else
        log "ERROR: Failed to format swap file"
        rm -f "$SWAP_FILE"
        exit 1
    fi
    
    # Activate swap
    log "Activating swap file..."
    if swapon "$SWAP_FILE"; then
        log "✓ Swap file activated"
    else
        log "ERROR: Failed to activate swap file"
        exit 1
    fi
fi

# Show current status
log "========================================="
log "✓ Swap setup complete"
log "========================================="
log "Current swap status:"
swapon -s | tee -a "$LOG_FILE"
log ""
log "Memory info:"
free -h | tee -a "$LOG_FILE"

exit 0
