# Raspberry Pi 4 (64-bit) image configuration
WKS_FILE:raspberrypi4-64 = "adu-raspberrypi.wks"

IMAGE_FSTYPES += "wic wic.gz wic.bmap ext4.gz"

IMAGE_INSTALL += " \
    sudo \
    openssh-sshd openssh-sftp-server \
    connman connman-client \
    python3 \
    nano \
    adu-persistent-overlay \
    adu-tools \
    adu-diag \
    adu-diskutil \
    azure-device-update \
    adu-config-setup \
"
