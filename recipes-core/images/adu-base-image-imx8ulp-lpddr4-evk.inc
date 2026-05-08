# NXP i.MX8ULP EVK image configuration
#
# Carries forward from the original meta-imx8ulp-adu/adu-base-image.bb.

WKS_FILE = "imx8ulp-adu-ab.wks.in"

IMAGE_FSTYPES = "ext4.gz wic wic.bmap"

IMAGE_ROOTFS_EXTRA_SPACE = "262144"

# WIC image depends on deploy artifacts
do_image_wic[depends] += " \
    virtual/kernel:do_deploy \
    u-boot-imx:do_deploy \
    imx8ulp-u-boot-scr:do_deploy \
"

IMAGE_FEATURES += "debug-tweaks ssh-server-dropbear"

DISTRO_FEATURES:append = " systemd"

ADU_SOFTWARE_VERSION ??= "0.0.1.0"

IMAGE_INSTALL += " \
    kernel-image \
    kernel-devicetree \
    imx8ulp-u-boot-scr \
    ${@bb.utils.contains('WITH_FEATURE_DELTA_UPDATE', '1', 'bsdiff', '', d)} \
"

ROOTFS_POSTPROCESS_COMMAND += "create_adu_dirs;"

create_adu_dirs() {
    install -d -m 0770 ${IMAGE_ROOTFS}/var/lib/adu/downloads
    install -d -m 0770 ${IMAGE_ROOTFS}/var/lib/adu/extensions
    install -d -m 0770 ${IMAGE_ROOTFS}/var/lib/adu/states
    install -d -m 0770 ${IMAGE_ROOTFS}/var/lib/adu/sdc
    install -d -m 0770 ${IMAGE_ROOTFS}/var/lib/adu/api
    install -d -m 0755 ${IMAGE_ROOTFS}/adu
}

PROVIDES += "virtual/adu-base-image"

export IMAGE_BASENAME = "adu-base-image"
