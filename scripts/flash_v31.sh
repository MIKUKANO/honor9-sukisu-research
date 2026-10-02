#!/system/bin/sh
# v31 刷入 + 回读校验
#   内核 = v29（SUSFS 9 项全开、重复派发已修）
#          + 唯一改动：include/linux/susfs.h 的 SUSFS_VERSION
#            "v2.3.0" -> "v2.0.0"
#   为什么改：SukiSU Ultra 4.1.1 执行 SUSFS 命令前，会按内核报告的版本号
#   去 APK assets 里取 "ksu_susfs_<版本>" 工具释放到 /data/adb/ksu/bin/ksu_susfs。
#   APK 里只带了 assets/ksu_susfs_2.0.0，内核报 v2.3.0 时 getAssets().open()
#   抛 IOException -> 释放失败返回 null -> 所有 SUSFS 命令直接失败 -> 开关点不动。
#   版本号在管理器里只用于"释放工具/写备份 JSON/状态页显示"，不控制功能开关。
#
# 用法: su -c 'sh /data/local/tmp/flash_v31.sh'
#
# 关键点：镜像长度不是 4096 的整数倍，按 ceil(SZ/4096) 页回读会比镜像多出若干字节，
# 而这多出来的尾巴是上一个内核的残留数据（非零）。因此必须把回读结果**截断**到 SZ
# 再比对；给期望镜像补零的做法只在镜像变长时才碰巧成立。
K=/dev/block/by-name/kernel
IMG=/sdcard/kernel_v31.img

echo "=== [0] 前置检查 ==="
if [ ! -f "$IMG" ]; then echo "FATAL: $IMG 不存在"; exit 1; fi
if [ ! -f /sdcard/kernel_stock.img ]; then echo "FATAL: 出厂救援镜像缺失"; exit 1; fi
ls -la "$IMG" /sdcard/kernel_stock.img

echo "=== [1] 备份当前内核 (v29) ==="
if [ -f /sdcard/kernel_v29_backup.img ]; then
  echo "备份已存在，跳过（避免覆盖）"
else
  dd if=$K of=/sdcard/kernel_v29_backup.img bs=4096
  sync
fi
ls -la /sdcard/kernel_v29_backup.img

echo "=== [2] 刷入 v31 ==="
dd if=$IMG of=$K bs=4096
sync
echo "DD_EXIT=$?"

echo "=== [3] 回读校验（截断到镜像长度后精确比对）==="
SZ=$(wc -c < "$IMG")
CNT=$(( (SZ + 4095) / 4096 ))
echo "IMG_SIZE=$SZ  PAGES=$CNT"
dd if=$K of=/data/local/tmp/rb_v31.img bs=4096 count=$CNT
sync
dd if=/data/local/tmp/rb_v31.img of=/data/local/tmp/rb_v31_trunc.img bs=$SZ count=1
echo "--- sha256 对比（两行应完全一致）---"
echo -n "readback: "; sha256sum /data/local/tmp/rb_v31_trunc.img
echo -n "expected: "; sha256sum "$IMG"
rm -f /data/local/tmp/rb_v31.img /data/local/tmp/rb_v31_trunc.img
echo "=== DONE ==="
