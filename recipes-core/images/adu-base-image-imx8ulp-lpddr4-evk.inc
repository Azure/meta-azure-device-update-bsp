# NXP i.MX8ULP EVK image configuration
WKS_FILE = "imx8ulp-adu-ab.wks.in"

IMAGE_FSTYPES += "wic wic.bmap ext4.gz"

IMAGE_INSTALL += " \
    imx8ulp-u-boot-scr \
"
