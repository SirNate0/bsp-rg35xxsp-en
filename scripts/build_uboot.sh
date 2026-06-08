#!/usr/bin/env bash
#
# build_uboot.sh —— 编译主线 U-Boot 2026.04，输出 u-boot-sunxi-with-spl.bin
#
# 关键改动：
#   - 复制 anbernic_rg35xx_h700_defconfig → anbernic_rg35xx_sp_defconfig
#   - CONFIG_DEFAULT_DEVICE_TREE: rg35xx-2024 → rg35xx-sp
#   - 其它（DRAM/PMIC/PHY MAP）原样照用（H700 公共）
#
# 输入：out/bl31.bin (来自 build_tfa.sh)
# 输出：out/u-boot-sunxi-with-spl.bin
#
# 工具链：系统 aarch64-linux-gnu-gcc 15.2.0

set -euo pipefail

BSP="$(cd "$(dirname "$0")/.." && pwd)"
UBOOT_SRC=$BSP/u-boot
OUT=$BSP/out
BL31=$OUT/bl31.bin

DEFCONFIG_SP=anbernic_rg35xx_sp_defconfig
DEFCONFIG_BASE=anbernic_rg35xx_h700_defconfig

[ -d "$UBOOT_SRC" ] || { echo "缺 $UBOOT_SRC"; exit 1; }
[ -f "$BL31" ]      || { echo "缺 $BL31，先跑 ./build_tfa.sh"; exit 1; }
mkdir -p "$OUT"

cd "$UBOOT_SRC"

# ===== 1. 派生 SP defconfig（不修改 base 文件） =====
if [ ! -f "configs/$DEFCONFIG_SP" ]; then
    echo "==> [1/4] 派生 configs/$DEFCONFIG_SP（基于 $DEFCONFIG_BASE）"
    sed \
        -e 's#sun50i-h700-anbernic-rg35xx-2024#sun50i-h700-anbernic-rg35xx-sp#' \
        "configs/$DEFCONFIG_BASE" > "configs/$DEFCONFIG_SP"
    # 跳过 distroboot 全扫描，直接从 mmc 0:2 加载 Image.gz + dtb
    # （p1 = Roms 2 GiB FAT，distroboot 会 hang）
    cat >> "configs/$DEFCONFIG_SP" <<'EOF'
CONFIG_USE_BOOTCOMMAND=y
CONFIG_BOOTCOMMAND="setenv bootargs 'earlycon=uart8250,mmio32,0x05000000 console=ttyS0,115200 root=/dev/mmcblk0p5 rootwait rw fw_devlink=off' && load mmc 0:2 ${kernel_addr_r} /Image.gz && load mmc 0:2 ${fdt_addr_r} /sun50i-h700-anbernic-rg35xx-sp.dtb && booti ${kernel_addr_r} - ${fdt_addr_r}"
EOF
    diff -u "configs/$DEFCONFIG_BASE" "configs/$DEFCONFIG_SP" || true
else
    echo "==> [1/4] configs/$DEFCONFIG_SP 已存在，跳过派生"
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

# 校验 defconfig 已生效
ACTUAL_DT=$(awk -F'"' '/^CONFIG_DEFAULT_DEVICE_TREE=/{print $2}' .config)
[ "$ACTUAL_DT" = "allwinner/sun50i-h700-anbernic-rg35xx-sp" ] \
    || { echo "!! DEFAULT_DEVICE_TREE = '$ACTUAL_DT'（应为 ...-rg35xx-sp）"; exit 1; }
echo "    CONFIG_DEFAULT_DEVICE_TREE = $ACTUAL_DT ✓"

# ===== 3. build with BL31 =====
echo "==> [3/4] make -j$(nproc) (BL31=$BL31)"
make CROSS_COMPILE=aarch64-linux-gnu- BL31="$BL31" -j$(nproc) 2>&1 | tail -40

# ===== 4. 收产物 =====
echo "==> [4/4] 收产物到 $OUT/"
UB_SPL=$UBOOT_SRC/u-boot-sunxi-with-spl.bin
[ -f "$UB_SPL" ] || { echo "!! $UB_SPL 不存在，build 失败"; exit 1; }

cp -v "$UB_SPL" "$OUT/u-boot-sunxi-with-spl.bin"
cp -v "$UBOOT_SRC/u-boot.bin"  "$OUT/u-boot.bin"
cp -v "$UBOOT_SRC/spl/sunxi-spl.bin" "$OUT/sunxi-spl.bin" 2>/dev/null || true

ls -lh "$OUT/u-boot-sunxi-with-spl.bin"
sha256sum "$OUT/u-boot-sunxi-with-spl.bin"

echo ""
echo "==> done。下一步：./build_kernel.sh"
