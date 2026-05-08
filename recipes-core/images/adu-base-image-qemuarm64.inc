# QEMU arm64 image configuration
WKS_FILE = "qemu-adu-ab.wks.in"

IMAGE_FSTYPES += "wic wic.bmap ext4.gz"

IMAGE_INSTALL += " \
    sudo \
    openssh-sshd openssh-sftp-server \
    connman \
    python3 \
    nano \
    qemu-u-boot-scr \
"
