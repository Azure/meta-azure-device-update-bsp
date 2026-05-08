# Raspberry Pi 4 (64-bit) image configuration
WKS_FILE:raspberrypi4-64 = "adu-raspberrypi.wks"

IMAGE_FSTYPES += "wic wic.bmap ext4.gz"

IMAGE_INSTALL += " \
    sudo \
    openssh-sshd openssh-sftp-server \
    connman connman-client \
    python3 \
    nano \
    rpi-u-boot-scr \
    adu-boot-validation \
    adu-persistent-overlay \
    adu-tools \
    adu-diag \
    adu-diskutil \
    adu-swap \
    yocto-a-b-update \
    azure-device-update \
    adu-config-setup \
"
