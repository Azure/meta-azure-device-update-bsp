# ADR-001: Consolidate Board-Specific Layers into a Single Repository

**Status**: Accepted  
**Date**: 2026-05-08  
**Decision makers**: ADU Yocto team

## Context

The Azure Device Update (ADU) Yocto project originally used separate Git repositories for each board's integration layer:

- `meta-raspberrypi-adu` — Raspberry Pi 4
- `meta-qemu-adu` — QEMU arm64 (virtual target)
- `meta-imx8ulp-adu` — NXP i.MX8ULP EVK

As the number of supported boards grew, this approach created operational overhead:

1. **Repository sprawl**: Each new board required a new GitHub repo with branch policies, CI configuration, access controls, and release management.
2. **Code duplication**: Shared patterns (board config recipe, intercept scripts, image base, A/B partition layout) were duplicated across all three layers.
3. **Branching overhead**: All three repos tracked the same branch (`feature/vnext-delta`) and were always released together — they had no independent lifecycle.
4. **Pipeline complexity**: The CI/CD pipeline needed separate parameters for each layer's branch and commit, multiplied by the number of boards.
5. **Onboarding friction**: Adding a new board meant "create a new repo" instead of "add a directory."

## Decision

Consolidate all board-specific ADU integration recipes into a single repository: **`meta-azure-device-update-bsp`**.

### Design Principles

1. **Board-specific recipes are conditionally loaded** using Yocto's `BBFILES_DYNAMIC` mechanism. Recipes that depend on optional BSP layers (e.g., `meta-raspberrypi`, `meta-freescale`) are placed under `dynamic-layers/<layer>/` and only parsed when that BSP layer is present.

2. **QEMU recipes are always available** since QEMU support is built into poky (core). These live under `boards/qemuarm64/`.

3. **Shared code lives at the top level** in `recipes-core/`, `recipes-support/`, `classes/`, and `wic/`.

4. **Machine-specific files use Yocto overrides** (`VARIABLE:machine = "value"`) rather than separate recipes where possible.

5. **The image recipe uses machine-specific includes**: `adu-base-image.bb` includes `adu-base-image-${MACHINE}.inc` so each board can customize the image without duplicating the full recipe.

## Alternatives Considered

### A) Keep separate repos (status quo)
- **Pro**: Independent versioning per board, fine-grained access control.
- **Con**: All the issues listed in Context. In practice, the repos were never versioned independently.

### B) Git submodules in a parent repo
- **Pro**: Single checkout, individual repo history preserved.
- **Con**: Submodule complexity, still requires managing N repos, cache invalidation per-submodule.

### C) Monorepo with directory-per-board (chosen)
- **Pro**: Single branch to manage, shared code stays DRY, adding a new board = adding a directory, one CI pipeline entry.
- **Con**: Customers clone all boards even if they need one (mitigated: layer is small, ~100 files total).

## Consequences

### Positive
- Adding a new board target is now: create a directory, add board.conf + WIC + image include + boot script.
- One pipeline parameter (`meta_azure_device_update_bsp_branch`) replaces three separate branch parameters.
- Shared recipes (adu-board-config, intercept scripts, image base) are maintained in one place.
- Code reviews can see cross-board impacts in a single PR.

### Negative
- The legacy `meta-raspberrypi-adu`, `meta-qemu-adu`, and `meta-imx8ulp-adu` repos must be archived or marked deprecated.
- `LAYERDEPENDS` only lists common dependencies; board-specific deps are implicitly required (enforced by `COMPATIBLE_MACHINE` and `BBFILES_DYNAMIC`).

### Migration Path
1. Create `meta-azure-device-update-bsp` with all content from the three layers.
2. Update kas configs and pipeline to reference the new layer.
3. Validate builds for all three targets.
4. Archive the original per-board repos with a notice pointing to the consolidated layer.

## Layer Structure

```
meta-azure-device-update-bsp/
├── conf/
│   └── layer.conf                         # BBFILES_DYNAMIC for conditional loading
├── recipes-core/
│   └── images/
│       ├── adu-base-image.bb              # Main image (includes per-machine .inc)
│       ├── adu-base-image-common.inc      # Shared image configuration
│       ├── adu-base-image-raspberrypi4-64.inc
│       ├── adu-base-image-qemuarm64.inc
│       ├── adu-base-image-imx8ulp-lpddr4-evk.inc
│       └── intercept-scripts/             # Shared no-op intercepts
├── recipes-support/
│   └── adu-board-config/
│       ├── adu-board-config.bb            # Shared recipe
│       └── files/
│           ├── raspberrypi4-64/board.conf
│           ├── qemuarm64/board.conf
│           └── imx8ulp-lpddr4-evk/board.conf
├── boards/
│   └── qemuarm64/                         # QEMU-specific (always parsed)
├── dynamic-layers/
│   ├── raspberrypi/                       # Parsed only with meta-raspberrypi
│   └── freescale/                         # Parsed only with meta-freescale
├── wic/                                   # All WIC partition layouts
├── tests/                                 # Board integration tests
└── docs/                                  # This document + porting guide
```
