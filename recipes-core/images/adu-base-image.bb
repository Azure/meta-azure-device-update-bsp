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
    adu-agent-service \
    yocto-a-b-update \
    run-postinsts \
"

# qemuarm64's kernel uses the QEMU virt machine and does not produce a
# separate kernel-devicetree package — opkg fails do_rootfs with
# "Couldn't find anything to satisfy 'kernel-devicetree'" if we keep it.
IMAGE_INSTALL:remove:qemuarm64 = "kernel-devicetree"

# Shared image settings
IMAGE_ROOTFS_EXTRA_SPACE = "0"
NO_RECOMMENDATIONS = "1"

# NOTE: Do NOT override POSTINST_INTERCEPTS_DIR — the local copy under
# intercept-scripts/ ships an `exit 1` delay_to_first_boot identical to
# poky's, but the override path was missing other intercept scripts that
# packages like glib-2.0 expect. Using the OE-Core default avoids the
# rootfs failure: "Postinstall scriptlets ... have failed". For first-boot
# deferral to work, the image MUST contain `run-postinsts` (added above).

# Create persistent ADU data directory in rootfs
create_adu_data_dir() {
    install -d ${IMAGE_ROOTFS}/adu
}
ROOTFS_POSTPROCESS_COMMAND += "create_adu_data_dir;"

# Include machine-specific image configuration
# Each board provides an .inc file that adds board-specific packages,
# sets WKS_FILE, IMAGE_FSTYPES, etc.
include adu-base-image-${MACHINE}.inc
