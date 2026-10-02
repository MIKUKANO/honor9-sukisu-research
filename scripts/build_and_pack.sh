#!/bin/bash
# =====================================================================
# 荣耀9 STF-AL10 · SukiSU 内核 编译+打包 一键脚本 (在 Linux/VM 内执行)
# 用法:  sudo -E bash build_and_pack.sh
# 前提:  已按 BUILD.md 完成源码/工具链/SukiSU 驱动集成 (或用 vm_setup.sh)
# 产物:  $SRC/kernel_sukisu.img  (可直接 dd 刷入 kernel 分区)
# =====================================================================
set -e
SRC=${SRC:-/root/kernel_src_gh}
TC=${TC:-/root/toolchain/bin/aarch64-none-linux-gnu-}
DEFCONFIG=${DEFCONFIG:-Pangu_SukiSU_defconfig}
# 构建标识（显示在 /proc/version 的 "Linux version ... (user@host)"）
# 默认值如下；想换成编译机的 登录用户@主机名，先 unset 再运行：
#   unset KBUILD_BUILD_USER KBUILD_BUILD_HOST
export KBUILD_BUILD_USER=${KBUILD_BUILD_USER:-MIKUKANO}
export KBUILD_BUILD_HOST=${KBUILD_BUILD_HOST:-ATRI}
JOBS=${JOBS:-$(nproc)}
# 荣耀9 官方 boot 参数 (cmdline 中 selinux 保持 permissive, 内核已强制)
CMDLINE='loglevel=4 initcall_debug=n page_tracker=on slub_min_objects=16 unmovable_isolate1=2:192M,3:224M,4:256M printktimer=0xfff0a000,0x534,0x538 androidboot.selinux=permissive buildvariant=user'

echo "=== [1/4] 生成 defconfig ==="
cd "$SRC"
make O=out ARCH=arm64 CROSS_COMPILE="$TC" "$DEFCONFIG"

echo "=== [2/4] 编译 Image.gz  (-j$JOBS) ==="
make O=out ARCH=arm64 CROSS_COMPILE="$TC" -j"$JOBS" Image.gz

echo "=== [3/4] 校验 ARM64 Image 魔数 ==="
zcat out/arch/arm64/boot/Image.gz > /tmp/Image_check
magic=$(od -A n -t x1 -j 0x38 -N 4 /tmp/Image_check | tr -d ' ')
[ "$magic" = "41524d64" ] || { echo "ARM64 魔数错误: $magic (期望 41524d64)"; exit 1; }
echo "    ARM64 魔数正确 (ARMd)"

echo "=== [4/4] 华为官方参数打包 mkbootimg ==="
cd tools
cp ../out/arch/arm64/boot/Image.gz Image_sukisu.gz
python mkbootimg \
  --kernel Image_sukisu.gz \
  --base 0x0 \
  --cmdline "$CMDLINE" \
  --tags_offset 0x07A00000 \
  --kernel_offset 0x00080000 \
  --ramdisk_offset 0x07c00000 \
  --header_version 1 \
  --os_version 9 \
  --os_patch_level 2020-10-01 \
  --output "$SRC/kernel_sukisu.img"

echo ""
echo "完成! 产物: $SRC/kernel_sukisu.img  ($(stat -c%s "$SRC/kernel_sukisu.img") bytes)"
echo "刷入: adb push $SRC/kernel_sukisu.img /data/local/tmp/ && adb shell su -c 'dd if=/data/local/tmp/kernel_sukisu.img of=/dev/block/by-name/kernel bs=4096'"
