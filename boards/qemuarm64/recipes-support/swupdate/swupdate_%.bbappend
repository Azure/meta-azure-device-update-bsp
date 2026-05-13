# QEMU board override: enable hash verify so the SWU files (which always
# carry sha256 hashes) can be installed. Signed images stay OFF since QEMU
# e2e runs without provisioning a verification key.
FILESEXTRAPATHS:prepend := "${THISDIR}/${PN}:"

DEPENDS += " openssl"
