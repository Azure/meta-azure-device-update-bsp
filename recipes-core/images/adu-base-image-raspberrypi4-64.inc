# Raspberry Pi 4 (64-bit) image configuration
#
# Carries forward the full set of packages, image features, and WIC
# dependencies from the original meta-raspberrypi-adu/adu-base-image.bb.

WKS_FILE:raspberrypi4-64 = "adu-raspberrypi.wks"

IMAGE_FSTYPES = "ext4.gz wic.gz wic.bmap"

IMAGE_ROOTFS_EXTRA_SPACE = "262144"

# WIC image depends on deploy artifacts (not installable packages)
do_image_wic[depends] += " \
    virtual/kernel:do_deploy \
    rpi-bootfiles:do_deploy \
    rpi-config:do_deploy \
    rpi-cmdline:do_deploy \
    ${@bb.utils.contains('RPI_USE_U_BOOT', '1', 'u-boot:do_deploy', '',d)} \
    ${@bb.utils.contains('RPI_USE_U_BOOT', '1', 'rpi-u-boot-scr:do_deploy', '',d)} \
"

IMAGE_FEATURES += "debug-tweaks tools-debug package-management"

inherit extrausers

def get_root_password_param(d):
    passwd = d.getVar('ADU_ROOT_PASSWD')
    if passwd:
        return "usermod -p '%s' root;" % passwd
    return ''

EXTRA_USERS_PARAMS = "${@get_root_password_param(d)}"

ADU_SOFTWARE_VERSION ??= "0.0.1.0"

IMAGE_INSTALL += " \
    kernel-image \
    kernel-devicetree \
    sudo \
    openssh \
    connman connman-client \
    fw-env-conf \
    adu-swupdate-hw-compat \
    u-boot-fw-utils \
    python3 \
    python3-modules \
    ${@bb.utils.contains('WITH_FEATURE_DELTA_UPDATE', '1', 'bsdiff', '', d)} \
    dpkg \
    apt \
    nano \
    binutils \
    kbd \
    terminus-font-consolefonts \
    adu-config-setup \
    adu-agent-service \
    adu-device-info-files \
    adu-boot-validation \
    adu-swap \
    adu-persistent-overlay \
    adu-tools \
    adu-diskutil \
    adu-diag \
    yocto-a-b-update \
"

ROOTFS_POSTPROCESS_COMMAND += "create_adu_bind_targets;"

create_adu_bind_targets() {
    install -d -m 0770 -o 800 -g 800 ${IMAGE_ROOTFS}/var/lib/adu/downloads
    install -d -m 0770 -o 800 -g 800 ${IMAGE_ROOTFS}/var/lib/adu/extensions
    install -d -m 0770 -o 800 -g 800 ${IMAGE_ROOTFS}/var/lib/adu/states
    install -d -m 0770 -o 800 -g 800 ${IMAGE_ROOTFS}/var/lib/adu/sdc
    install -d -m 0770 -o 800 -g 800 ${IMAGE_ROOTFS}/var/lib/adu/api
    bbnote "Created /var/lib/adu/{downloads,extensions,states,sdc,api} in rootfs for bind mounts"
}

PROVIDES += "virtual/adu-base-image"

export IMAGE_NAME_SUFFIX = ""
export IMAGE_BASENAME = "adu-base-image"
