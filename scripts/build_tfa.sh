#!/usr/bin/env bash
#
# build_tfa.sh —— 编译主线 TF-A (BL31)，输出 out/bl31.bin
#
# 产物：out/bl31.bin (~30 KiB)
#   用途：被 build_uboot.sh 引用打包进 u-boot-sunxi-with-spl.bin
#
# 工具链：系统 aarch64-linux-gnu-gcc 15.2.0（满足 TF-A v2.14 LTS 要求 GCC 11+）

set -euo pipefail

BSP="$(cd "$(dirname "$0")/.." && pwd)"
TFA_SRC=$BSP/arm-tf-a
OUT=$BSP/out

[ -d "$TFA_SRC" ] || { echo "缺 $TFA_SRC"; exit 1; }
mkdir -p "$OUT"

echo "==> TF-A lts-v2.14.2 build, PLAT=sun50i_h616 DEBUG=0"
cd "$TFA_SRC"

# 不带 -j 也快（BL31 体积小，编译 < 30s）；带 -j 偶尔触发 build-id 竞态
make -C "$TFA_SRC" \
    CROSS_COMPILE=aarch64-linux-gnu- \
    PLAT=sun50i_h616 \
    DEBUG=0 \
    bl31 \
    -j$(nproc)

BL31=$TFA_SRC/build/sun50i_h616/release/bl31.bin
[ -f "$BL31" ] || { echo "!! 没找到 $BL31"; exit 1; }

cp -v "$BL31" "$OUT/bl31.bin"
sha256sum "$OUT/bl31.bin"

echo ""
echo "==> done: $OUT/bl31.bin"
echo "    下一步：./build_uboot.sh"
