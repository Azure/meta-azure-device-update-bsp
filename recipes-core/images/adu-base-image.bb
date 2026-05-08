SUMMARY = "ADU base image with Azure Device Update agent"
DESCRIPTION = "Minimal embedded Linux image with Azure Device Update (ADU) \
agent integration. Machine-specific packages and configuration are \
included via per-machine .inc files."
LICENSE = "MIT"

inherit core-image

# Shared base packages for all ADU targets
IMAGE_INSTALL += " \
    packagegroup-core-boot \
    kernel-image \
    kernel-devicetree \
    systemd \
    parted \
    zstd \
    libubootenv-bin \
    adu-board-config \
"

# Shared image settings
IMAGE_ROOTFS_EXTRA_SPACE = "0"
NO_RECOMMENDATIONS = "1"

POSTINST_INTERCEPTS_DIR = "${THISDIR}/intercept-scripts"

# Create persistent ADU data directory in rootfs
create_adu_data_dir() {
    install -d ${IMAGE_ROOTFS}/adu
}
ROOTFS_POSTPROCESS_COMMAND += "create_adu_data_dir;"

# Include machine-specific image configuration
# Each board provides an .inc file that adds board-specific packages,
# sets WKS_FILE, IMAGE_FSTYPES, etc.
include adu-base-image-${MACHINE}.inc
