SUMMARY = "ADU Persistent Overlay and Bind Mounts"
DESCRIPTION = "Persists user-modifiable /etc state (passwd/shadow/group/gshadow/hostname/...) across A/B rootfs updates via boot-restore + inotify-driven sync, with overlayfs/bind-mounts for runtime directories. Replaces the earlier bind-mount-per-file approach which broke shadow-utils' atomic temp+rename writes."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

# This recipe provides ADU persistence strategy
PROVIDES = "adu-persistence-strategy"
RPROVIDES:${PN} = "adu-persistence-strategy"

# Conflicts with simple symlinks strategy
RCONFLICTS:${PN} = "adu-persistence-symlinks"

SRC_URI = " \
    file://adu-persistent-overlay.service \
    file://adu-persistent-watcher.service \
    file://setup-overlay-dirs.sh \
    file://mount-overlays.sh \
    file://umount-overlays.sh \
    file://mount-critical-binds.sh \
    file://migrate-to-overlay.sh \
    file://restore-persistent-files.sh \
    file://sync-persistent-files.sh \
    file://adu-persistent-watcher.sh \
    file://overlay.conf \
    file://verify-overlays.sh \
    file://factory-reset.sh \
    file://setup-apt-repos.sh \
    file://README.md \
"

S = "${WORKDIR}"

inherit systemd

SYSTEMD_PACKAGES = "${PN}"
SYSTEMD_SERVICE:${PN} = "adu-persistent-overlay.service adu-persistent-watcher.service"
SYSTEMD_AUTO_ENABLE = "enable"

do_install() {
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${WORKDIR}/adu-persistent-overlay.service ${D}${systemd_system_unitdir}/
    install -m 0644 ${WORKDIR}/adu-persistent-watcher.service ${D}${systemd_system_unitdir}/

    install -d ${D}${libdir}/adu
    install -m 0755 ${WORKDIR}/setup-overlay-dirs.sh ${D}${libdir}/adu/
    install -m 0755 ${WORKDIR}/mount-overlays.sh ${D}${libdir}/adu/
    install -m 0755 ${WORKDIR}/umount-overlays.sh ${D}${libdir}/adu/
    install -m 0755 ${WORKDIR}/mount-critical-binds.sh ${D}${libdir}/adu/
    install -m 0755 ${WORKDIR}/migrate-to-overlay.sh ${D}${libdir}/adu/
    install -m 0755 ${WORKDIR}/restore-persistent-files.sh ${D}${libdir}/adu/
    install -m 0755 ${WORKDIR}/sync-persistent-files.sh ${D}${libdir}/adu/
    install -m 0755 ${WORKDIR}/adu-persistent-watcher.sh ${D}${libdir}/adu/
    install -m 0755 ${WORKDIR}/verify-overlays.sh ${D}${libdir}/adu/
    install -m 0755 ${WORKDIR}/factory-reset.sh ${D}${libdir}/adu/
    install -m 0755 ${WORKDIR}/setup-apt-repos.sh ${D}${libdir}/adu/

    install -d ${D}${sysconfdir}/overlay
    install -m 0644 ${WORKDIR}/overlay.conf ${D}${sysconfdir}/overlay/

    install -d ${D}${sysconfdir}/adu
    install -m 0644 ${WORKDIR}/overlay.conf ${D}${sysconfdir}/adu/

    install -d ${D}${docdir}/${PN}
    install -m 0644 ${WORKDIR}/README.md ${D}${docdir}/${PN}/
}

FILES:${PN} += " \
    ${systemd_system_unitdir}/adu-persistent-overlay.service \
    ${systemd_system_unitdir}/adu-persistent-watcher.service \
    ${libdir}/adu/setup-overlay-dirs.sh \
    ${libdir}/adu/mount-overlays.sh \
    ${libdir}/adu/umount-overlays.sh \
    ${libdir}/adu/mount-critical-binds.sh \
    ${libdir}/adu/migrate-to-overlay.sh \
    ${libdir}/adu/restore-persistent-files.sh \
    ${libdir}/adu/sync-persistent-files.sh \
    ${libdir}/adu/adu-persistent-watcher.sh \
    ${libdir}/adu/verify-overlays.sh \
    ${libdir}/adu/factory-reset.sh \
    ${libdir}/adu/setup-apt-repos.sh \
    ${sysconfdir}/adu/overlay.conf \
    ${sysconfdir}/overlay/overlay.conf \
    ${docdir}/${PN}/README.md \
"

# Provides /adu partition structure
RDEPENDS:${PN} += "adu-filesystem-layout"
# Creates adu user/group
RDEPENDS:${PN} += "azure-device-update"
RDEPENDS:${PN} += "bash"
# Used by adu-persistent-watcher.sh
RDEPENDS:${PN} += "inotify-tools"
# Used by atomic_install / merge helpers (mktemp, awk, coreutils sync)
RDEPENDS:${PN} += "coreutils"

pkg_postinst_ontarget:${PN}() {
    #!/bin/sh
    if [ -d /etc/adu ]; then
        chown root:adu /etc/adu
        chmod 0755 /etc/adu
        if [ -f /etc/adu/overlay.conf ]; then
            chown root:adu /etc/adu/overlay.conf
            chmod 0644 /etc/adu/overlay.conf
        fi
    fi
}