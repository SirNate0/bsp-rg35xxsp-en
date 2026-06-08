#!/usr/bin/env bash
#
# build_kernel.sh —— 编译主线 Linux 7.0.9 + 生成 FAT 部署文件夹
#
# 用法:
#   ./build_kernel.sh              # dev 模式 (默认)
#   ./build_kernel.sh dev          # 同上
#   ./build_kernel.sh release      # release 模式
#
# 模式区别:
#   dev     — linux-7.0.9, 增量编译, 适合迭代开发
#   release — linux-7.0.9, distclean 后全量编译, 产物可复现
#
# 产物（out/）：
#   Image.gz                                   arm64 内核
#   sun50i-h700-anbernic-rg35xx-sp.dtb         设备树
#   modules.tar.gz                             /lib/modules/7.0.9/ 打包
#   p2-payload/                                Image + dtb + extlinux.conf
#
# 内核配置:
#   rg35xxsp.config 存放在 configs/ 目录, 构建时复制进源码树。

set -euo pipefail

BSP="$(cd "$(dirname "$0")/.." && pwd)"
OUT=$BSP/out
KVER=7.0.9

DTB_NAME=sun50i-h700-anbernic-rg35xx-sp.dtb
DTB_REL=allwinner/$DTB_NAME

# ===== 解析模式 =====
MODE="${1:-dev}"
case "$MODE" in
    dev|release)
        KSRC=$BSP/linux
        echo "==> 模式: $MODE ($KSRC)"
        ;;
    *)
        echo "用法: $0 [dev|release]"
        exit 1
        ;;
esac

[ -d "$KSRC" ] || { echo "缺 $KSRC"; exit 1; }
mkdir -p "$OUT"

cd "$KSRC"

# ===== 0. 应用 patches =====
PATCH_DIR=$BSP/patches/linux
APPLIED_MARKER=$KSRC/.patches_applied
if [ -d "$PATCH_DIR" ] && ls "$PATCH_DIR"/*.patch >/dev/null 2>&1; then
    if [ ! -f "$APPLIED_MARKER" ]; then
        echo "==> [0/6] 应用 patches"
        for p in "$PATCH_DIR"/*.patch; do
            echo "    applying $(basename "$p")"
            git apply --check "$p" 2>/dev/null \
                || { echo "!! patch 不兼容: $p"; exit 1; }
            git apply "$p"
        done
        touch "$APPLIED_MARKER"
    else
        echo "==> [0/6] patches 已应用，跳过"
    fi
fi

# ===== 0b. 复制 rg35xxsp.config =====
CONFIG_SRC=$BSP/configs/rg35xxsp.config
CONFIG_DST=$KSRC/kernel/configs/rg35xxsp.config
if [ -f "$CONFIG_SRC" ]; then
    mkdir -p "$(dirname "$CONFIG_DST")"
    cp "$CONFIG_SRC" "$CONFIG_DST"
fi

# ===== 1. release 模式: distclean 确保干净 =====
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
# 每次构建都合并 rg35xxsp.config（幂等：olddefconfig 会忽略已存在的项）
if [ -f "$EXTRA" ]; then
    echo "==> [2/6] 应用 rg35xxsp.config:"
    grep -E "^CONFIG_" "$EXTRA" | sed 's/^/      /'
    cat "$EXTRA" >> .config
    make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- olddefconfig
fi

# ===== 3. Image + dtbs + modules =====
# LOCALVERSION="" (empty but set):压住 setlocalversion 在 .scmversion 缺失时
# 给 KERNELRELEASE 末尾追加的 "+"。结合 # CONFIG_LOCALVERSION_AUTO is not set
# (rg35xxsp.config),让 kernel release 稳定为 "7.0.9",modules 路径不再带 git hash。
echo "==> [3/6] make -j$(nproc) Image.gz dtbs modules"
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- LOCALVERSION="" \
    Image.gz dtbs modules -j$(nproc) 2>&1 | tail -10

IMAGE_SRC=$KSRC/arch/arm64/boot/Image.gz
DTB_SRC=$KSRC/arch/arm64/boot/dts/$DTB_REL
[ -f "$IMAGE_SRC" ] || { echo "!! $IMAGE_SRC 不存在"; exit 1; }
[ -f "$DTB_SRC" ]   || { echo "!! $DTB_SRC 不存在"; exit 1; }

# ===== 4. modules → tar.gz =====
echo "==> [4/6] make modules_install + tar.gz"
STAGING=$OUT/modules-staging
rm -rf "$STAGING"
mkdir -p "$STAGING"
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- LOCALVERSION="" \
    INSTALL_MOD_PATH="$STAGING" \
    INSTALL_MOD_STRIP=1 \
    modules_install >/dev/null

# 砍掉绝对 build/ source/ 软链（指向主机路径，rootfs 上没意义）
rm -f "$STAGING/lib/modules/$KVER/build" "$STAGING/lib/modules/$KVER/source"

tar -C "$STAGING" -czf "$OUT/modules.tar.gz" lib
ls -lh "$OUT/modules.tar.gz"

# ===== 5. 摆 p2 FAT 内容 =====
echo "==> [5/6] 摆 p2 部署目录"
P2=$OUT/p2-payload
rm -rf "$P2"
mkdir -p "$P2/extlinux"

cp -v "$IMAGE_SRC" "$P2/Image.gz"
cp -v "$DTB_SRC"   "$P2/$DTB_NAME"

cat > "$P2/extlinux/extlinux.conf" <<EOF
# RG35XX-SP 一期 mainline boot：仅串口登录
default sp
prompt 0
timeout 1

label sp
    kernel /Image.gz
    fdt /$DTB_NAME
    append earlycon=uart8250,mmio32,0x05000000 console=ttyS0,115200 root=/dev/mmcblk0p5 rootwait rw
EOF

cat "$P2/extlinux/extlinux.conf"

# ===== p2 容量校验：32 MiB FAT16 减 FAT 表/根目录开销，留 30 MiB 余量 =====
P2_USED=$(du -sb "$P2" | awk '{print $1}')
P2_LIMIT=$((30 * 1024 * 1024))
P2_USED_MB=$((P2_USED / 1024 / 1024))
if [ "$P2_USED" -gt "$P2_LIMIT" ]; then
    echo "!! p2-payload 总占用 ${P2_USED_MB} MiB > 30 MiB 上限（p2 FAT16 = 32 MiB）"
    echo "   明细："
    du -h --max-depth=2 "$P2"
    exit 1
fi
printf '    p2-payload 占用 %s MiB / 30 MiB 上限 ✓\n' "$P2_USED_MB"

# ===== 6. 顶层留 sha256 摘要 =====
echo "==> [6/6] 收尾"
cp -v "$IMAGE_SRC" "$OUT/Image.gz"
cp -v "$DTB_SRC"   "$OUT/$DTB_NAME"

( cd "$OUT" && sha256sum Image.gz $DTB_NAME modules.tar.gz 2>/dev/null \
    && sha256sum bl31.bin u-boot-sunxi-with-spl.bin 2>/dev/null || true ) > "$OUT/SHA256SUMS"
cat "$OUT/SHA256SUMS"

echo ""
echo "==> done ($MODE 模式)。下一步：sudo ./flash_sd.sh 或 ./deploy_ssh.sh"
