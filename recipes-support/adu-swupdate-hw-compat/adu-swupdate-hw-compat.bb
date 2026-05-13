# Generates a text file with the ADU hardware compatibility info
# and copies/installs that file into the image.
# This file is used by swupdate (or potentially other installer)
# to determine if an update is compatible with this hardware.

LICENSE="CLOSED"

# Generate the hardware compatability file
do_compile() {
    echo -n "${MACHINE} ${HW_REV}" > adu-swupdate-hw-compat
}

# Install the hardware compatability file on the image in /etc
do_install() {
    install -d ${D}${sysconfdir}
    install -m 0444 adu-swupdate-hw-compat ${D}${sysconfdir}/adu-swupdate-hw-compat
}

FILES:${PN} += "${sysconfdir}/adu-swupdate-hw-compat"

inherit allarch
