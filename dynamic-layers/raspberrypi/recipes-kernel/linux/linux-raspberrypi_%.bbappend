FILESEXTRAPATHS:prepend := "${THISDIR}/${PN}:"

SRC_URI += "file://enable-overlayfs.cfg"

KERNEL_FEATURES:append = " features/overlayfs/overlayfs.scc"

# Mirror yocto-kernel-cache via GitHub. git.yoctoproject.org has had repeated
# outages in 2025 (cgit/DDoS) that fail-stop kernel do_fetch with:
#   "No up to date source found: clone directory not available or not up to date"
# The official GitHub mirror at github.com/yoctoproject/yocto-kernel-cache
# tracks upstream and is reachable from hosted ADO agents.
#
# Regex form: any branch under git.yoctoproject.org/<repo> -> github.com/yoctoproject/<repo>
PREMIRRORS:prepend = "\
    git://git\\.yoctoproject\\.org/(.+) git://github.com/yoctoproject/\\1;protocol=https \n\
"
