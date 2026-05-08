# QEMU arm64 image configuration
WKS_FILE = "qemu-adu-ab.wks.in"

IMAGE_FSTYPES += "wic wic.bmap ext4.gz"

IMAGE_FEATURES += "debug-tweaks tools-debug ssh-server-openssh"

do_image_wic[depends] += " \
    virtual/kernel:do_deploy \
    u-boot:do_deploy \
    qemu-u-boot-scr:do_deploy \
"

IMAGE_INSTALL += " \
    sudo \
    openssh-sshd openssh-sftp-server \
    connman \
    python3 \
    nano \
    qemu-u-boot-scr \
"
