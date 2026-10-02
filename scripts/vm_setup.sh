#!/bin/bash
# =====================================================================
# 荣耀9 STF-AL10 · 编译环境一键搭建 (Ubuntu 20.04 x86_64, VM/proot/物理机通用)
# 用法:  sudo -E bash vm_setup.sh
# 内容: 依赖 → 国内源 → 内核源码 → gcc10.3 工具链 → SukiSU v4.1.1 驱动集成 → 补丁应用
# =====================================================================
set -e
NAME=${NAME:-SukiSU}              # uname 后缀 (CONFIG_LOCALVERSION)，留空则用盘古原版命名
WORK=${WORK:-/root}
PATCH=${PATCH:-honor9_all_patches.diff}   # 完整内核补丁 (放在 $WORK 下; 亦可用绝对路径)

echo "=== [1/8] 系统依赖 (清华源) ==="
sed -i 's|http://archive.ubuntu.com/ubuntu|https://mirrors.tuna.tsinghua.edu.cn/ubuntu|g' /etc/apt/sources.list 2>/dev/null || true
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
  build-essential bc bison flex libssl-dev libncurses5-dev python2.7 \
  python-is-python2 cpio zip rsync wget perl git curl xz-utils

echo "=== [2/8] 拉取内核源码 (盘古 EMUI9.1 hi3660, 支持荣耀9 骑士版) ==="
cd "$WORK"
[ -d kernel_src_gh ] || git clone --depth=1 https://github.com/maimaiguanfan/android_kernel_huawei_hi3660.git kernel_src_gh
# 若 github 直连失败, 可用镜像: git clone --depth=1 https://ghproxy.cn/https://github.com/... 或 gitee 搜索镜像

echo "=== [3/8] 拉取 gcc10.3 aarch64 工具链 (盘古作者维护) ==="
[ -d toolchain ] || git clone --depth=1 -b aarch64-gcc10 https://gitee.com/maimaiguanfan/arm-gcc.git toolchain

echo "=== [4/8] 拉取 SukiSU v4.1.1 源码 (与管理器版本严格一致) ==="
[ -f sukisu_v411.tar.gz ] || curl -fL -o sukisu_v411.tar.gz \
  "https://gh.ddlc.top/https://github.com/SukiSU-Ultra/SukiSU-Ultra/archive/refs/tags/v4.1.1.tar.gz"
# 直连失败可换: https://github.com/SukiSU-Ultra/SukiSU-Ultra/archive/refs/tags/v4.1.1.tar.gz
rm -rf sukisu && mkdir sukisu && tar -xzf sukisu_v411.tar.gz -C sukisu --strip-components=1

echo "=== [5/8] 挂载 SukiSU 驱动到内核源码 ==="
cd "$WORK/kernel_src_gh"
cp -r "$WORK/sukisu/kernel" drivers/kernelsu
# 驱动自带的兼容头 (含全部 4.9 shim, 见 patches/ksu_compat_49.h 说明)
cp "$WORK/ksu_compat_49.h" drivers/kernelsu/ 2>/dev/null || true
# Kbuild: 强制注入兼容头 + gnu11 (SukiSU 代码用了 C99 语法)
grep -q 'ksu_compat_49.h' drivers/kernelsu/Kbuild || cat >> drivers/kernelsu/Kbuild <<'EOF'

# 4.9 compat shims force-include (ZCode patch)
ccflags-y += -include $(srctree)/drivers/kernelsu/ksu_compat_49.h
ccflags-y += -std=gnu11
EOF
# drivers/Kconfig 注册 (插在最后一行 endmenu 之前)
if ! grep -q 'drivers/kernelsu/Kconfig' drivers/Kconfig; then
  head -n -1 drivers/Kconfig > /tmp/kc
  printf 'source drivers/kernelsu/Kconfig\nendmenu\n' >> /tmp/kc
  mv /tmp/kc drivers/Kconfig
fi
# drivers/Makefile 挂载
if ! grep -q 'CONFIG_KSU' drivers/Makefile; then
  echo 'obj-$(CONFIG_KSU) += kernelsu/' >> drivers/Makefile
fi

echo "=== [6/8] 生成 SukiSU defconfig ==="
cp arch/arm64/configs/Pangu_Kirin960_defconfig arch/arm64/configs/Pangu_SukiSU_defconfig
sed -i 's/^CONFIG_HUAWEI_HIDESYMS=y/# CONFIG_HUAWEI_HIDESYMS is not set/; s/^CONFIG_DEBUG_INFO=y/# CONFIG_DEBUG_INFO is not set/' \
  arch/arm64/configs/Pangu_SukiSU_defconfig
printf '\n# SukiSU integration\nCONFIG_KSU=y\nCONFIG_KSU_MANUAL_SU=y\nCONFIG_KSU_DEBUG=y\n# CONFIG_KPM is not set\nCONFIG_FTRACE_SYSCALLS=y\nCONFIG_KALLSYMS=y\nCONFIG_KALLSYMS_ALL=y\nCONFIG_SECURITY_SELINUX_DEVELOP=y\nCONFIG_LOCALVERSION="-%s"\n' "$NAME" >> arch/arm64/configs/Pangu_SukiSU_defconfig

echo "=== [7/8] 应用完整内核补丁 (patches/${PATCH##*/}) ==="
# 补丁文件默认放在 $WORK 下 (可从仓库 patches/ 复制或改 PATCH= 指向)
# 注意: diff 相对源码根生成, --dir-diff 语义, 直接 git apply:
[ -f "$PATCH" ] || PATCH="$WORK/${PATCH##*/}"
if [ -f "$PATCH" ]; then
  git -c core.autocrlf=false apply --stat "$PATCH" | tail -3 || true
  git -c core.autocrlf=false apply "$PATCH" || echo "部分 hunks 已应用过, 跳过失败项属正常"
  # 若冲突, 说明源码版本不同, 需按 PATCHES.md 手工对应
else
  echo "未找到补丁 $PATCH —— 跳过。请把 honor9_all_patches.diff 放到 $WORK, 或 export PATCH=<绝对路径>"
fi

echo "=== [8/8] 完成 ==="
echo "localversion: -$NAME"
echo "构建标识 (user@host): 未设置则使用编译机的 登录用户@主机名"
echo "  如需自定义: export KBUILD_BUILD_USER=xxx KBUILD_BUILD_HOST=yyy 后重新编译"
echo "下一步: bash build_and_pack.sh"
