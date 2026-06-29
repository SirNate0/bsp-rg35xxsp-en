#!/usr/bin/env bash
#
# build_kernel.sh —— Compile mainline Linux 7.0.9 + generate FAT deploy folder
#
# Usage:
#   ./build_kernel.sh              # dev mode (default)
#   ./build_kernel.sh dev          # same as above
#   ./build_kernel.sh release      # release mode
#
# Mode differences:
#   dev     — linux-7.0.9, incremental build, suitable for iterative dev
#   release — linux-7.0.9, full rebuild after distclean, reproducible artifacts
#
# Artifacts (out/):
#   Image.gz                                   arm64 kernel
#   sun50i-h700-anbernic-rg35xx-sp.dtb         device tree
#   modules.tar.gz                             /lib/modules/7.0.9/ tarball
#   p2-payload/                                Image + dtb + extlinux.conf
#
# Kernel config:
#   rg35xxsp.config is stored in configs/ directory, copied into source tree at build time.

set -euo pipefail

BSP="$(cd "$(dirname "$0")/.." && pwd)"
OUT=$BSP/out
KVER=7.0.9

DTB_NAME=sun50i-h700-anbernic-rg35xx-sp.dtb
DTB_REL=allwinner/$DTB_NAME

# ===== Parse mode =====
MODE="${1:-dev}"
case "$MODE" in
    dev|release)
        KSRC=$BSP/linux
        echo "==> Mode: $MODE ($KSRC)"
        ;;
    *)
        echo "Usage: $0 [dev|release]"
        exit 1
        ;;
esac

[ -d "$KSRC" ] || { echo "Missing $KSRC"; exit 1; }
mkdir -p "$OUT"

cd "$KSRC"

# ===== 0. Apply patches =====
PATCH_DIR=$BSP/patches/linux
APPLIED_MARKER=$KSRC/.patches_applied
if [ -d "$PATCH_DIR" ] && ls "$PATCH_DIR"/*.patch >/dev/null 2>&1; then
    if [ ! -f "$APPLIED_MARKER" ]; then
        echo "==> [0/6] Applying patches"
        for p in "$PATCH_DIR"/*.patch; do
            echo "    applying $(basename "$p")"
            git apply --check "$p" 2>/dev/null \
                || { echo "!! Patch incompatible: $p"; exit 1; }
            git apply "$p"
        done
        touch "$APPLIED_MARKER"
    else
        echo "==> [0/6] Patches already applied, skipping"
    fi
fi

# ===== 0b. Copy rg35xxsp.config =====
CONFIG_SRC=$BSP/configs/rg35xxsp.config
CONFIG_DST=$KSRC/kernel/configs/rg35xxsp.config
if [ -f "$CONFIG_SRC" ]; then
    mkdir -p "$(dirname "$CONFIG_DST")"
    cp "$CONFIG_SRC" "$CONFIG_DST"
fi

# ===== 1. release mode: distclean for clean state =====
if [ "$MODE" = "release" ]; then
    echo "==> [1/6] make distclean"
    make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- distclean
fi

# ===== 2. defconfig + rg35xxsp.config =====
EXTRA=$KSRC/kernel/configs/rg35xxsp.config
if [ ! -f .config ]; then
    echo "==> [2/6] make defconfig"
    make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- defconfig
fi
# Merge rg35xxsp.config every build (idempotent: olddefconfig ignores existing items)
if [ -f "$EXTRA" ]; then
    echo "==> [2/6] Applying rg35xxsp.config:"
    grep -E "^CONFIG_" "$EXTRA" | sed 's/^/      /'
    cat "$EXTRA" >> .config
    make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- olddefconfig
fi

# ===== 3. Image + dtbs + modules =====
# LOCALVERSION="" (empty but set): suppress the "+" that setlocalversion appends
# to KERNELRELEASE when .scmversion is missing. Combined with
# CONFIG_LOCALVERSION_AUTO is not set (rg35xxsp.config), kernel release stays
# "7.0.9", module paths no longer include git hash.
echo "==> [3/6] make -j$(nproc) Image.gz dtbs modules"
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- LOCALVERSION="" \
    Image.gz dtbs modules -j$(nproc) 2>&1 | tail -10

IMAGE_SRC=$KSRC/arch/arm64/boot/Image.gz
DTB_SRC=$KSRC/arch/arm64/boot/dts/$DTB_REL
[ -f "$IMAGE_SRC" ] || { echo "!! $IMAGE_SRC does not exist"; exit 1; }
[ -f "$DTB_SRC" ]   || { echo "!! $DTB_SRC does not exist"; exit 1; }

# ===== 4. modules → tar.gz =====
echo "==> [4/6] make modules_install + tar.gz"
STAGING=$OUT/modules-staging
rm -rf "$STAGING"
mkdir -p "$STAGING"
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- LOCALVERSION="" \
    INSTALL_MOD_PATH="$STAGING" \
    INSTALL_MOD_STRIP=1 \
    modules_install >/dev/null

# Remove absolute build/ source/ symlinks (point to host paths, meaningless on rootfs)
rm -f "$STAGING/lib/modules/$KVER/build" "$STAGING/lib/modules/$KVER/source"

tar -C "$STAGING" -czf "$OUT/modules.tar.gz" lib
ls -lh "$OUT/modules.tar.gz"

# ===== 5. Set up p2 FAT contents =====
echo "==> [5/6] Setting up p2 deploy directory"
P2=$OUT/p2-payload
rm -rf "$P2"
mkdir -p "$P2/extlinux"

cp -v "$IMAGE_SRC" "$P2/Image.gz"
cp -v "$DTB_SRC"   "$P2/$DTB_NAME"

cat > "$P2/extlinux/extlinux.conf" <<EOF
# RG35XX-SP phase 1 mainline boot: serial login only
default sp
prompt 0
timeout 1

label sp
    kernel /Image.gz
    fdt /$DTB_NAME
    append earlycon=uart8250,mmio32,0x05000000 console=ttyS0,115200 root=/dev/mmcblk0p5 rootwait rw
EOF

cat "$P2/extlinux/extlinux.conf"

# ===== p2 capacity check: 32 MiB FAT16 minus FAT table/root dir overhead, keep 30 MiB margin =====
P2_USED=$(du -sb "$P2" | awk '{print $1}')
P2_LIMIT=$((30 * 1024 * 1024))
P2_USED_MB=$((P2_USED / 1024 / 1024))
if [ "$P2_USED" -gt "$P2_LIMIT" ]; then
    echo "!! p2-payload total ${P2_USED_MB} MiB > 30 MiB limit (p2 FAT16 = 32 MiB)"
    echo "   Details:"
    du -h --max-depth=2 "$P2"
    exit 1
fi
printf '    p2-payload using %s MiB / 30 MiB limit ✓\n' "$P2_USED_MB"

# ===== 6. Top-level sha256 checksum =====
echo "==> [6/6] Finishing up"
cp -v "$IMAGE_SRC" "$OUT/Image.gz"
cp -v "$DTB_SRC"   "$OUT/$DTB_NAME"

( cd "$OUT" && sha256sum Image.gz $DTB_NAME modules.tar.gz 2>/dev/null \
    && sha256sum bl31.bin u-boot-sunxi-with-spl.bin 2>/dev/null || true ) > "$OUT/SHA256SUMS"
cat "$OUT/SHA256SUMS"

echo ""
echo "==> done ($MODE mode). Next step: sudo ./flash_sd.sh or ./deploy_ssh.sh"
