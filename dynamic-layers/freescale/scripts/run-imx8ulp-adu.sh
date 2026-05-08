#!/bin/bash
# run-imx8ulp-adu.sh - Flash and boot instructions for i.MX8ULP EVK with ADU
#
# This script provides instructions for flashing the ADU image to the
# NXP i.MX8ULP LPDDR4 EVK board.
#
# Prerequisites:
#   - NXP UUU tool (Universal Update Utility) installed
#   - i.MX8ULP EVK board connected via USB OTG
#   - Board set to serial download mode (DIP switches)
#
# ============================================================
# Option 1: Flash to eMMC via UUU
# ============================================================
#
# 1. Build the image:
#    $ bitbake adu-base-image
#
# 2. The WIC image will be at:
#    tmp/deploy/images/imx8ulp-lpddr4-evk/adu-base-image-imx8ulp-lpddr4-evk.wic
#
# 3. Put the board into serial download mode:
#    - Set boot DIP switches to serial download (refer to EVK docs)
#    - Connect USB-C OTG cable to host PC
#
# 4. Flash with UUU:
#    $ sudo uuu -b emmc_all \
#        flash.bin \
#        adu-base-image-imx8ulp-lpddr4-evk.wic
#
# 5. Set boot switches back to eMMC boot and reset the board.
#
# ============================================================
# Option 2: Write to SD card (for development)
# ============================================================
#
# 1. Insert SD card and identify device (e.g., /dev/sdX):
#    $ lsblk
#
# 2. Write the WIC image:
#    $ sudo dd if=tmp/deploy/images/imx8ulp-lpddr4-evk/adu-base-image-imx8ulp-lpddr4-evk.wic \
#        of=/dev/sdX bs=4M conv=fsync status=progress
#
# 3. Set boot switches to SD card boot and insert the card.
#
# ============================================================
# Serial Console
# ============================================================
#
# Connect to the EVK debug UART (ttyLP1) at 115200 baud:
#    $ picocom -b 115200 /dev/ttyUSB0
#
# ============================================================
# Verifying A/B Boot
# ============================================================
#
# In U-Boot console:
#    => printenv boot_partition
#    => printenv boot_attempts
#    => printenv upgrade_available
#
# In Linux:
#    $ fw_printenv boot_partition
#    $ cat /etc/adu/board.conf
#

echo "This script is documentation-only. See comments above for instructions."
echo "No automated flashing is performed."
exit 0
