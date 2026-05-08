# meta-azure-device-update-bsp

Consolidated board support layer for [Azure Device Update](https://learn.microsoft.com/azure/iot-hub-device-update/) (ADU) on Yocto-based embedded Linux systems.

## Purpose

This layer provides the board-specific integration recipes needed to run the ADU agent on supported hardware. It is designed to be used alongside the core ADU meta-layers (`meta-azure-device-update`, `meta-iot-hub-device-update-delta`, `meta-azure-device-update-samples`).

Each supported board gets:
- **A/B root filesystem layout** (WIC partitioning)
- **U-Boot boot script** with rollback support
- **Board configuration** (`/etc/adu/board.conf`)
- **Base image recipe** (`adu-base-image`)
- **SWUpdate integration** for OTA updates

## Supported Boards

| Board | Machine | BSP Layer Required |
|-------|---------|-------------------|
| Raspberry Pi 4 (64-bit) | `raspberrypi4-64` | `meta-raspberrypi` |
| QEMU arm64 (virtual) | `qemuarm64` | *(built-in to poky)* |
| NXP i.MX8ULP EVK | `imx8ulp-lpddr4-evk` | `meta-freescale` |

## Layer Architecture

```
meta-azure-device-update-bsp/
├── conf/layer.conf                    # Unified layer config
├── recipes-core/images/               # Shared image base (adu-base-image)
├── recipes-support/adu-board-config/  # Board config (per-machine files/)
├── boards/qemuarm64/                  # QEMU-specific (no external BSP dep)
├── dynamic-layers/
│   ├── raspberrypi/                   # Loaded only when meta-raspberrypi present
│   └── freescale/                     # Loaded only when meta-freescale present
├── wic/                               # WIC partition layouts
└── docs/                              # Architecture decisions & porting guide
```

Board-specific recipes that depend on optional BSP layers (e.g., `meta-raspberrypi`) are placed under `dynamic-layers/` and loaded conditionally via `BBFILES_DYNAMIC`. This means you only need the BSP layer for the board you're building.

QEMU recipes are under `boards/qemuarm64/` and always parsed since QEMU support is built into poky.

## Quick Start

### Using kas (recommended)

```bash
# Build for Raspberry Pi 4
kas build kas/machine-rpi4.yml

# Build for QEMU arm64
kas build kas/machine-qemu.yml

# Build for NXP i.MX8ULP EVK
kas build kas/machine-imx8ulp.yml
```

### Manual setup

Add this layer to your `bblayers.conf`:
```
BBLAYERS += "/path/to/meta-azure-device-update-bsp"
```

Set your machine in `local.conf`:
```
MACHINE = "raspberrypi4-64"  # or qemuarm64, imx8ulp-lpddr4-evk
```

Build the image:
```bash
bitbake adu-base-image
```

## Adding a New Board

See [docs/porting-guide.md](docs/porting-guide.md) for step-by-step instructions on adding support for a new board.

## Dependencies

- **Required**: `poky` (core), `meta-openembedded`, `meta-swupdate`, `meta-azure-device-update`
- **Optional**: `meta-raspberrypi` (for RPi builds), `meta-freescale` (for i.MX builds)

## License

MIT — see [COPYING.MIT](COPYING.MIT)
