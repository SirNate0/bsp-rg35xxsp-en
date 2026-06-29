#!/usr/bin/env bash
#
# build_tfa.sh —— Compile mainline TF-A (BL31), output out/bl31.bin
#
# Output: out/bl31.bin (~30 KiB)
#   Used by: build_uboot.sh packages it into u-boot-sunxi-with-spl.bin
#
# Toolchain: system aarch64-linux-gnu-gcc 15.2.0 (satisfies TF-A v2.14 LTS requirement GCC 11+)

set -euo pipefail

BSP="$(cd "$(dirname "$0")/.." && pwd)"
TFA_SRC=$BSP/arm-tf-a
OUT=$BSP/out

[ -d "$TFA_SRC" ] || { echo "Missing $TFA_SRC"; exit 1; }
mkdir -p "$OUT"

echo "==> TF-A lts-v2.14.2 build, PLAT=sun50i_h616 DEBUG=0"
cd "$TFA_SRC"

# Still fast without -j (BL31 is small, build < 30s); -j occasionally triggers build-id race
make -C "$TFA_SRC" \
    CROSS_COMPILE=aarch64-linux-gnu- \
    PLAT=sun50i_h616 \
    DEBUG=0 \
    bl31 \
    -j$(nproc)

BL31=$TFA_SRC/build/sun50i_h616/release/bl31.bin
[ -f "$BL31" ] || { echo "!! BL31 not found: $BL31"; exit 1; }

cp -v "$BL31" "$OUT/bl31.bin"
sha256sum "$OUT/bl31.bin"

echo ""
echo "==> done: $OUT/bl31.bin"
echo "    Next step: ./build_uboot.sh"
