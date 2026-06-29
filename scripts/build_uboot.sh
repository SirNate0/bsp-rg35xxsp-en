#!/usr/bin/env bash
#
# build_uboot.sh —— Compile mainline U-Boot 2026.04, output u-boot-sunxi-with-spl.bin
#
# Key changes:
#   - Copy anbernic_rg35xx_h700_defconfig → anbernic_rg35xx_sp_defconfig
#   - CONFIG_DEFAULT_DEVICE_TREE: rg35xx-2024 → rg35xx-sp
#   - Other (DRAM/PMIC/PHY MAP) reused as-is (H700 common)
#
# Input: out/bl31.bin (from build_tfa.sh)
# Output: out/u-boot-sunxi-with-spl.bin
#
# Toolchain: system aarch64-linux-gnu-gcc 15.2.0

set -euo pipefail

BSP="$(cd "$(dirname "$0")/.." && pwd)"
UBOOT_SRC=$BSP/u-boot
OUT=$BSP/out
BL31=$OUT/bl31.bin

DEFCONFIG_SP=anbernic_rg35xx_sp_defconfig
DEFCONFIG_BASE=anbernic_rg35xx_h700_defconfig

[ -d "$UBOOT_SRC" ] || { echo "Missing $UBOOT_SRC"; exit 1; }
[ -f "$BL31" ]      || { echo "Missing $BL31, run ./build_tfa.sh first"; exit 1; }
mkdir -p "$OUT"

cd "$UBOOT_SRC"

# ===== 1. Derive SP defconfig (don't modify base file) =====
if [ ! -f "configs/$DEFCONFIG_SP" ]; then
    echo "==> [1/4] Deriving configs/$DEFCONFIG_SP (from $DEFCONFIG_BASE)"
    sed \
        -e 's#sun50i-h700-anbernic-rg35xx-2024#sun50i-h700-anbernic-rg35xx-sp#' \
        "configs/$DEFCONFIG_BASE" > "configs/$DEFCONFIG_SP"
    # Skip distroboot full scan, load Image.gz + dtb directly from mmc 0:2
    # (p1 = Roms 2 GiB FAT, distroboot would hang)
    cat >> "configs/$DEFCONFIG_SP" <<'EOF'
CONFIG_USE_BOOTCOMMAND=y
CONFIG_BOOTCOMMAND="setenv bootargs 'earlycon=uart8250,mmio32,0x05000000 console=ttyS0,115200 root=/dev/mmcblk0p5 rootwait rw fw_devlink=off' && load mmc 0:2 ${kernel_addr_r} /Image.gz && load mmc 0:2 ${fdt_addr_r} /sun50i-h700-anbernic-rg35xx-sp.dtb && booti ${kernel_addr_r} - ${fdt_addr_r}"
EOF
    diff -u "configs/$DEFCONFIG_BASE" "configs/$DEFCONFIG_SP" || true
else
    echo "==> [1/4] configs/$DEFCONFIG_SP already exists, skipping derivation"
fi

# Keep the derived defconfig quiet even if it was created by an older script.
sed -i \
    -e 's/ ignore_loglevel//g' \
    -e 's/ drm\.debug=0x[0-9a-fA-F]\+//g' \
    "configs/$DEFCONFIG_SP"

# ===== 2. distclean + defconfig =====
echo "==> [2/4] make distclean + $DEFCONFIG_SP"
make CROSS_COMPILE=aarch64-linux-gnu- distclean >/dev/null
make CROSS_COMPILE=aarch64-linux-gnu- "$DEFCONFIG_SP"

# Verify defconfig took effect
ACTUAL_DT=$(awk -F'"' '/^CONFIG_DEFAULT_DEVICE_TREE=/{print $2}' .config)
[ "$ACTUAL_DT" = "allwinner/sun50i-h700-anbernic-rg35xx-sp" ] \
    || { echo "!! DEFAULT_DEVICE_TREE = '$ACTUAL_DT' (expected ...-rg35xx-sp)"; exit 1; }
echo "    CONFIG_DEFAULT_DEVICE_TREE = $ACTUAL_DT ✓"

# ===== 3. build with BL31 =====
echo "==> [3/4] make -j$(nproc) (BL31=$BL31)"
make CROSS_COMPILE=aarch64-linux-gnu- BL31="$BL31" -j$(nproc) 2>&1 | tail -40

# ===== 4. Collect artifacts =====
echo "==> [4/4] Collecting artifacts to $OUT/"
UB_SPL=$UBOOT_SRC/u-boot-sunxi-with-spl.bin
[ -f "$UB_SPL" ] || { echo "!! $UB_SPL not found, build failed"; exit 1; }

cp -v "$UB_SPL" "$OUT/u-boot-sunxi-with-spl.bin"
cp -v "$UBOOT_SRC/u-boot.bin"  "$OUT/u-boot.bin"
cp -v "$UBOOT_SRC/spl/sunxi-spl.bin" "$OUT/sunxi-spl.bin" 2>/dev/null || true

ls -lh "$OUT/u-boot-sunxi-with-spl.bin"
sha256sum "$OUT/u-boot-sunxi-with-spl.bin"

echo ""
echo "==> done. Next step: ./build_kernel.sh"
