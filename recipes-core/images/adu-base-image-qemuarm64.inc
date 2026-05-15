# QEMU arm64 image configuration
#
# Carries forward from the original meta-qemu-adu/adu-base-image.bb.

WKS_FILE = "qemu-adu-ab.wks.in"

IMAGE_FSTYPES = "wic wic.bmap ext4.gz"

IMAGE_ROOTFS_EXTRA_SPACE = "262144"

# WIC image depends on deploy artifacts
do_image_wic[depends] += " \
    virtual/kernel:do_deploy \
    u-boot:do_deploy \
    qemu-u-boot-scr:do_deploy \
"

IMAGE_FEATURES += "debug-tweaks tools-debug ssh-server-openssh"

ADU_SOFTWARE_VERSION ??= "0.0.1.0"

IMAGE_INSTALL += " \
    adu-filesystem-layout \
    adu-persistent-overlay \
    sudo \
    openssh \
    connman connman-client \
    python3 \
    nano \
    qemu-u-boot-scr \
"

ROOTFS_POSTPROCESS_COMMAND += "create_adu_dirs; write_adu_base_version;"

create_adu_dirs() {
    install -d -m 0770 ${IMAGE_ROOTFS}/var/lib/adu/downloads
    install -d -m 0770 ${IMAGE_ROOTFS}/var/lib/adu/extensions
    install -d -m 0770 ${IMAGE_ROOTFS}/var/lib/adu/states
    install -d -m 0770 ${IMAGE_ROOTFS}/var/lib/adu/sdc
    install -d -m 0770 ${IMAGE_ROOTFS}/var/lib/adu/api
    install -d -m 0755 ${IMAGE_ROOTFS}/adu
}

# Baseline /etc/adu-version for the freshly-flashed rootfs. The versioned
# update images (adu-update-image-v{1,2,3}) overwrite this file during the
# debugfs ext4 surgery in adu-update-image-common.inc, so this value is what
# the device reports BEFORE any update has been applied.
write_adu_base_version() {
    echo "${ADU_SOFTWARE_VERSION}" > ${IMAGE_ROOTFS}/etc/adu-version
    chmod 0644 ${IMAGE_ROOTFS}/etc/adu-version
}

PROVIDES += "virtual/adu-base-image"

export IMAGE_BASENAME = "adu-base-image"
