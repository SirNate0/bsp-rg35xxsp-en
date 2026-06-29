# bsp-rg35xxsp

Anbernic RG35XX-SP mainline Linux BSP build repository.

Based on mainline Linux 7.0.9 + U-Boot 2026.04 + TF-A lts-v2.14.2, managed via submodule + patch.

## Directory Structure

```
├── linux/          # submodule: gregkh/linux v7.0.9
├── u-boot/         # submodule: u-boot/u-boot v2026.04
├── arm-tf-a/       # submodule: ARM-software/arm-trusted-firmware lts-v2.14.2
├── patches/
│   └── linux/      # Device-related kernel patches (DTS, DRM, drivers, etc.)
├── configs/        # Kernel config fragment
├── scripts/        # Build scripts
└── out/            # Build artifacts (gitignore)
```

## Build

### Dependencies

```bash
# Debian/Ubuntu
sudo apt-get install gcc-aarch64-linux-gnu bc bison flex libssl-dev libgnutls28-dev
```

### Build Order

```bash
# 1. TF-A (BL31)
./scripts/build_tfa.sh

# 2. U-Boot (depends on bl31.bin)
./scripts/build_uboot.sh

# 3. Kernel (auto-applies patches)
./scripts/build_kernel.sh          # dev mode, incremental build
./scripts/build_kernel.sh release  # release mode, full rebuild after distclean
```

### Artifacts

Build artifacts are in `out/`:

| File | Description |
|------|------|
| `bl31.bin` | TF-A BL31 |
| `u-boot-sunxi-with-spl.bin` | U-Boot SPL + BL31 |
| `Image.gz` | Kernel image |
| `sun50i-h700-anbernic-rg35xx-sp.dtb` | Device tree |
| `modules.tar.gz` | Kernel modules |
| `p2-payload/` | FAT partition contents (Image + DTB + extlinux.conf) |

## Upgrading Kernel Version

```bash
cd linux
git fetch --tags
git checkout v7.0.10
cd ..

# Check each patch for compatibility
cd linux
for p in ../patches/linux/*.patch; do
    git apply --check "$p" && echo "OK: $p" || echo "CONFLICT: $p"
done
```

## Patch Notes

| Patch | Content |
|-------|------|
| `0001-dts-h616-display-pipeline-and-rg35xx-boards.patch` | H616 display pipeline DTS + RG35XX device trees |
| `0002-drm-de33-mixer-csc-planes-panel.patch` | DE33 DRM driver + NV3052C panel |
| `0003-clk-de2-add-de33-regmap.patch` | DE2 clock regmap support |
| `0004-mmc-phy-sram-cedrus-fixes.patch` | MMC/PHY/SRAM/Cedrus driver fixes |
| `0005-gitignore-build-temps.patch` | Build temp files gitignore |

## CI

Pushing to `master` branch automatically triggers GitHub Actions build. Pushing a tag creates a Release and uploads artifacts.

## License

Kernel, U-Boot, and TF-A each follow their upstream licenses. Build scripts and patches in this repository are under [LICENSE](LICENSE).
