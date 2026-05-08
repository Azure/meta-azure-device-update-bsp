# Porting Guide: Adding a New Board to meta-azure-device-update-bsp

This guide walks through adding support for a new hardware board.

## Prerequisites

- A working Yocto BSP layer for your board (e.g., `meta-your-board`)
- U-Boot bootloader with A/B boot support (or willingness to add it)
- Familiarity with Yocto/BitBake recipes

## Step-by-Step

### 1. Create the board directory

If your board requires an external BSP layer, use `dynamic-layers/`:

```
dynamic-layers/<bsp-layer-name>/
└── recipes-bsp/
    ├── <board>-u-boot-scr/
    │   ├── <board>-u-boot-scr.bb
    │   └── files/boot.cmd.in
    ├── u-boot/
    │   ├── u-boot_%.bbappend  (or u-boot-<vendor>_%.bbappend)
    │   └── files/<board>-adu-env.cfg
    └── libubootenv/
        ├── libubootenv_%.bbappend
        └── files/fw_env.config
```

If your board is built into poky (like QEMU), use `boards/<machine>/` instead.

### 2. Add board.conf

Create `recipes-support/adu-board-config/files/<MACHINE>/board.conf`:

```bash
# Device and partition layout
BOOT_DEVICE=/dev/mmcblk0        # or /dev/sda, /dev/vda, etc.
ROOT_A_DEVICE=${BOOT_DEVICE}p2
ROOT_B_DEVICE=${BOOT_DEVICE}p3
DATA_DEVICE=${BOOT_DEVICE}p4

# U-Boot settings
BOOT_MEDIA=mmc                  # mmc, virtio, scsi, etc.
UBOOT_ENV_FILE=/boot/uboot.env
```

### 3. Create the image include

Create `recipes-core/images/adu-base-image-<MACHINE>.inc`:

```bitbake
# <Board Name> image configuration
WKS_FILE = "<board>-adu-ab.wks.in"
IMAGE_FSTYPES += "wic wic.bmap ext4.gz"

IMAGE_INSTALL += " \
    <board>-u-boot-scr \
"
```

### 4. Create the WIC layout

Create `wic/<board>-adu-ab.wks.in` with A/B root partitions:

```
# Boot partition
part /boot --source bootimg-partition --fstype=vfat --label boot --active --size 64M

# Root A (primary)
part / --source rootfs --fstype=ext4 --label rootA --size 1G

# Root B (secondary, for OTA updates)
part --source rootfs --fstype=ext4 --label rootB --size 1G

# Persistent ADU data
part /adu --fstype=ext4 --label adu --size 512M
```

### 5. Create the U-Boot boot script

Create the boot script recipe with A/B logic. See `boards/qemuarm64/recipes-bsp/qemu-u-boot-scr/` for a minimal example.

### 6. Register in layer.conf (if using dynamic-layers)

Add to `BBFILES_DYNAMIC` in `conf/layer.conf`:

```
BBFILES_DYNAMIC += " \
    <bsp-layer-collection>:${LAYERDIR}/dynamic-layers/<bsp-layer-name>/recipes-*/**/*.bb \
    <bsp-layer-collection>:${LAYERDIR}/dynamic-layers/<bsp-layer-name>/recipes-*/**/*.bbappend \
"
```

Add machine defaults:

```
ADU_MANUFACTURER:<MACHINE> ?= "YourCompany"
ADU_MODEL:<MACHINE> ?= "YourBoard"
```

### 7. Add a kas config (optional)

Create `kas/machine-<board>.yml` in `iot-hub-device-update-yocto` to enable one-command builds.

### 8. Build and test

```bash
MACHINE=<your-machine> bitbake adu-base-image
```

## Checklist

- [ ] `board.conf` with correct device paths
- [ ] WIC file with A/B partition layout
- [ ] U-Boot boot script with rollback support
- [ ] `fw_env.config` pointing to correct U-Boot env location
- [ ] Image include with board-specific packages
- [ ] `BBFILES_DYNAMIC` entry in `layer.conf` (if needed)
- [ ] Machine defaults (`ADU_MANUFACTURER`, `ADU_MODEL`)
- [ ] Build succeeds: `bitbake adu-base-image`
- [ ] A/B boot works on target hardware
