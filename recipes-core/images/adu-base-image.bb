SUMMARY = "ADU base image with Azure Device Update agent"
DESCRIPTION = "Minimal embedded Linux image with Azure Device Update (ADU) \
agent integration. Machine-specific packages and configuration are \
included via per-machine .inc files."
LICENSE = "MIT"

inherit core-image

# Shared base packages for all ADU targets
IMAGE_INSTALL += " \
    packagegroup-core-boot \
    systemd \
    parted \
    zstd \
    libubootenv-bin \
    adu-board-config \
    azure-device-update \
"

# Shared image settings
NO_RECOMMENDATIONS = "1"

POSTINST_INTERCEPTS_DIR = "${THISDIR}/intercept-scripts"

# Include machine-specific image configuration
# Each board provides an .inc file that adds board-specific packages,
# sets WKS_FILE, IMAGE_FSTYPES, do_image_wic[depends], etc.
include adu-base-image-${MACHINE}.inc
