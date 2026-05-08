PACKAGECONFIG:append:rpi = " gbm"
PROVIDES:append:rpi = " virtual/libgbm"

do_install:append:rpi() {
    rm -rf ${D}${includedir}/KHR/khrplatform.h
}
