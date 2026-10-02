# 编译详细步骤（BUILD.md）

环境要求：**Ubuntu 20.04 x86_64**（20.04 是实测通过的版本；22.04 缺 python2 需另行处理），≥2 核 4GB 内存，磁盘 ≥20GB。VM（Proxmox LXC / VirtualBox / WSL2）均可。

> 📦 **全部外部依赖（源码、工具链、platform-tools、APK…）的版本与获取方式见 [`TOOLS.md`](TOOLS.md)。**
> 本仓库**不随包分发**任何第三方二进制或源码。

## 一、一键路径（推荐）

```bash
sudo -E bash vm_setup.sh        # 环境搭建 + 源码 + 工具链 + 驱动集成 + 补丁
sudo -E bash build_and_pack.sh  # 编译 + 打包 → /root/kernel_src_gh/kernel_sukisu.img
```

`vm_setup.sh` 内各步若已有产物会自动跳过，可反复执行。以下为手工分步说明。

## 二、分步说明

### 1. 系统依赖

```bash
sed -i 's|http://archive.ubuntu.com/ubuntu|https://mirrors.tuna.tsinghua.edu.cn/ubuntu|g' /etc/apt/sources.list
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y build-essential bc bison flex \
  libssl-dev libncurses5-dev python2.7 python-is-python2 cpio zip rsync wget perl git curl
```

### 2. 内核源码（⭐ 来源必须标明）

**盘古内核 Pangu Kernel**（作者 **maimaiguanfan / 麥麥觀飯**，**GPL-2.0**），
EMUI 9.1 EROFS 版，原生支持荣耀 9（骑士定制版：荣耀9 / V9 / Nova2S / 平板 M5）：

```bash
cd /root
git clone --depth=1 https://github.com/maimaiguanfan/android_kernel_huawei_hi3660.git kernel_src_gh
```

> **国内镜像**：https://gitee.com/maimaiguanfan/Pangu9.1EROFS
> （gitee 仓库只有一个 README 指路，真源码在 GitHub）
>
> 国内直连 github.com 的 git 协议实测可用；archive/codeload 被墙需走代理。
>
> ⭐ **本项目是盘古内核的衍生作品**，其 `zen` / `blu_schedutil` / `gpu_scene_aware` /
> Dynamic Stune Boost / WireGuard / SELinux 限制解锁 / Kirin 970 JPEG 引擎等特性
> **均由盘古提供**，本项目只是沿用。致谢与许可详见 [`TOOLS.md`](TOOLS.md) 与 `../NOTICE.md`。

### 3. 工具链

盘古作者镜像的 **ARM 官方 gcc 10.3**（x86_64 宿主；上游为 ARM GNU Toolchain）：

```bash
git clone --depth=1 -b aarch64-gcc10 https://gitee.com/maimaiguanfan/arm-gcc.git toolchain
# 工具链前缀: /root/toolchain/bin/aarch64-none-linux-gnu-
```

### 4. SukiSU 驱动集成（非 GKI · syscall-tracepoint hook 方案）

```bash
# 4.1 下载与管理器严格同版本的驱动源码（管理器 v4.1.1 ↔ 驱动 tag v4.1.1 ↔ version 40496）
curl -fL -o sukisu_v411.tar.gz https://github.com/SukiSU-Ultra/SukiSU-Ultra/archive/refs/tags/v4.1.1.tar.gz
mkdir sukisu && tar -xzf sukisu_v411.tar.gz -C sukisu --strip-components=1

# 4.2 挂载进内核树
cp -r sukisu/kernel kernel_src_gh/drivers/kernelsu
# drivers/Kconfig 末行 endmenu 前插入:  source drivers/kernelsu/Kconfig
# drivers/Makefile 末尾追加:           obj-$(CONFIG_KSU) += kernelsu/
# drivers/kernelsu/Kbuild 末尾追加:
#   ccflags-y += -include $(srctree)/drivers/kernelsu/ksu_compat_49.h
#   ccflags-y += -std=gnu11
# 并把 patches/ksu_compat_49.h 复制到 drivers/kernelsu/

# 4.3 驱动版本钉定（与管理器 versionCode 一致）
# drivers/kernelsu/Kbuild 中 KSU_VERSION := 13000 的回退分支改为 40496，
# KSU_VERSION_FULL := v4.1.1-SukiSU
```

### 5. defconfig

```bash
cd kernel_src_gh
cp arch/arm64/configs/Pangu_Kirin960_defconfig arch/arm64/configs/Pangu_SukiSU_defconfig
```

在 Pangu 基础上追加/修改（详见 `patches/Pangu_SukiSU_defconfig` 尾部）：

| 配置 | 值 | 原因 |
|---|---|---|
| CONFIG_KSU / CONFIG_KSU_MANUAL_SU | y | SukiSU 驱动 + prctl 手动授权 |
| CONFIG_FTRACE_SYSCALLS | y | syscall tracepoint hook（kprobe 在华为内核不可用） |
| CONFIG_KALLSYMS / _ALL | y | 驱动要求 |
| CONFIG_KSU_DEBUG | y | 内核日志（量产可关） |
| CONFIG_KPM | n | KPM 需要 4.19 set_memory backport，不必要 |
| CONFIG_HUAWEI_HIDESYMS | n | 华为符号隐藏（反 root） |
| CONFIG_DEBUG_INFO | n | 减内存加速编译 |
| CONFIG_SECURITY_SELINUX_DEVELOP | y | 允许 `setenforce` 切换（**内核不再强制回 permissive**，v25 已摘除 `ZCODE_FORCE_PERMISSIVE`） |
| CONFIG_DM_VERITY/AVB、HW_ROOT_SCAN、TEE_ANTIROOT_CLIENT 等 | n | 盘古 defconfig 已关，确认无残留 |
| CONFIG_LOCALVERSION | `"-SukiSU"` | uname 显示（可随意改；⚠️ 若含 shell 元字符如 `&`，须同步修 Makefile，见 PATCHES.md §M.2） |

### 6. 应用内核补丁

```bash
cd kernel_src_gh
git -c core.autocrlf=false apply ../patches/honor9_all_patches.diff
```

该 diff 是**完整对应源码**（191 文件 / 23,251 行，相对盘古 master `b15bb35c7`）：reboot 超级调用钩子、
SukiSU 驱动 4.9 兼容 shim、SUSFS 移植、全树 -Werror 清理、defconfig 与版本串等全部改动。
逐项说明见 PATCHES.md。若目标源码与盘古 master 有差异导致个别 hunk 冲突，按 `git apply --reject` 生成 .rej 手工对齐。

> ⚠️ **v25 起内核不再强制 SELinux Permissive**（`ZCODE_FORCE_PERMISSIVE` 已摘除）；
> **v26 起编入 SUSFS**；**v27–v29 补齐三项能力并修 5 个缺陷**；**v31 改 SUSFS 版本号修 AVC 开关**。
> ⚠️ **Windows 上必须加 `-c core.autocrlf=false`**，否则 git 会把补丁的 LF 转成 CRLF，
> 应用结果与目标逐字节不一致。

### 6.5 应用 ksud 集成修复补丁（**必做**）

```bash
# ⚠️ Windows 上必须显式关掉 autocrlf，否则 git apply 会把补丁的 LF 转成 CRLF，
#    应用结果与目标版本逐字节不一致（cmp 全部 DIFF，字节数凭空多出「行数」个）。
git -c core.autocrlf=false apply --check patches/ksud_integration_fix.patch && \
git -c core.autocrlf=false apply         patches/ksud_integration_fix.patch
# 或：patch -p1 < patches/ksud_integration_fix.patch
```

修复「root 授权重启丢失」与「模块重启不生效」，见 `FIX_KSUD_INTEGRATION.md`。
**不应用此补丁，编出来的内核模块系统与授权持久化都是坏的。**

该补丁只改 `drivers/kernelsu/` 下 **8 个文件**（含 `sucompat.c` 的一处降噪）、
**不动 defconfig**，因此不会触发全量重编。改动后可先快速自检：

```bash
make O=out ARCH=arm64 CROSS_COMPILE="$TC" drivers/kernelsu/
# 期望：各文件 CC 通过、LD built-in.o 成功、无 error
```

> ⏱ 环境机只有 **2 核**，增量编译 + 链接 `Image.gz` 约需数分钟
> （`-j$(nproc)` 在 2 核上就是 `-j2`）。用脚本调用时记得给足超时，
> 或改后台执行后轮询 `/tmp/build_v20.log` 里的 `BUILD_EXIT=`。
>
> 编译输出里的 `WARNING: "xxx" [vmlinux] is COMMON symbol` 与
> `Found N section mismatch(es)` 是**华为内核源码固有的 modpost 噪声**，
> 与本次改动无关，可忽略。判断成功只需看 `BUILD_EXIT=0`。

### 7. 编译

```bash
make O=out ARCH=arm64 CROSS_COMPILE=/root/toolchain/bin/aarch64-none-linux-gnu- Pangu_SukiSU_defconfig
make O=out ARCH=arm64 CROSS_COMPILE=/root/toolchain/bin/aarch64-none-linux-gnu- -j$(nproc) Image.gz
# 已实测: 2 核约 2.5~3 小时; 8 核约 40 分钟
```

### 8. 打包（华为官方 mkbootimg，参数与原厂逐字段一致）

```bash
cd tools   # 内核源码 tools/ 目录自带华为原版 mkbootimg (python2)
cp ../out/arch/arm64/boot/Image.gz Image_sukisu.gz
python mkbootimg --kernel Image_sukisu.gz --base 0x0 \
  --cmdline 'loglevel=4 initcall_debug=n page_tracker=on slub_min_objects=16 \
  unmovable_isolate1=2:192M,3:224M,4:256M printktimer=0xfff0a000,0x534,0x538 \
  androidboot.selinux=permissive buildvariant=user' \
  --tags_offset 0x07A00000 --kernel_offset 0x00080000 --ramdisk_offset 0x07c00000 \
  --header_version 1 --os_version 9 --os_patch_level 2020-10-01 \
  --output /root/kernel_sukisu.img
```

> 这些参数抄自源码 `tools/pack_kernerimage_cmd.sh`（华为官方打包脚本），与原厂 boot 头部逐字段比对一致。
>
> **v25 已切回 `enforcing`**（2026-10-02 实机验证）。改动是两处：① 摘除
> `security/selinux/selinuxfs.c:sel_write_enforce()` 内的 `ZCODE_FORCE_PERMISSIVE`（6 行）；
> ② 把 cmdline 的 `androidboot.selinux=permissive` 改回 `enforcing`。
>
> ⚠️ **实测结论（反直觉）**：② 对最终 SELinux 状态**没有影响**。EMUI init 在 **15.9s** 会
> 无条件调 `security_setenforce(1)`（本 ROM `buildvariant=user` → `ALLOW_PERMISSIVE_SELINUX=false`
> → `IsEnforcing()` 恒真）；而内核**根本不解析** `androidboot.selinux`
> （`selinux_enforcing` 在 `hooks.c:107` 无初始化器，只认 `enforcing=` 参数）。
> **真正决定一切的是 ①**。保留 ② 只为让 `ro.boot.selinux` 属性与出厂一致。
> 详见 `PATCHES.md` 的 C 节与 K.7。

### 9. 校验产物

```bash
zcat out/arch/arm64/boot/Image.gz > /tmp/Image_check
od -A n -t x1 -j 0x38 -N 4 /tmp/Image_check   # 应输出 41 52 4d 64 (ARMd)
ls -la /root/kernel_sukisu.img                 # 约 15MB (内核分区 24MB, 余量充足)
```

## 三、编译期已知问题速查（均已在交付 diff 中修复）

| 症状 | 原因 | 处理 |
|---|---|---|
| cpufreq_blu_schedutil.c 指针签名错误 | 盘古 Makefile 额外加的 -Werror=incompatible-pointer-types | 已注释+源码签名修正 |
| hisi 连接性/音频驱动 -Werror 风暴 | 各目录 Makefile/Kbuild 的 EXTRA_CFLAGS+=-Werror | 已全树剥离（31+6 处） |
| -Wno-error 压不住 -Werror=xxx | GCC 语义：必须 -Wno-error=具体类 | 顶层 Makefile 具体行已注释 |
| MODULE_IMPORT_NS 未定义 | 5.4+ 宏 | ksu_compat_49.h / ksu.c 条件编译 |
| struct seccomp 无 filter_count | 5.9+ 成员 | app_profile.c 版本守卫 |
| TWA_RESUME 未定义 | 5.14+ 枚举 | 兼容头 #define TWA_RESUME true |
| strncpy_from_user_nofault 未定义 | 5.8 改名 | 兼容头映射 strncpy_from_user |
| __NR_clone3 未定义 | 5.3 syscall | 兼容头 #define 435 |
| linux/sched/signal.h 等头缺失 | 4.11+ 拆分 | 全部替换为 4.9 等价路径 |
| selinux_state 未定义 | 5.2 状态结构 | selinux.c 改用 selinux_enforcing 全局量 |
| sepolicy/rules 引擎编译失败 | 5.2+ policydb 结构 | <5.2 整体 stub（permissive 下无需） |
| pkg_observer/file_wrapper 编译失败 | 5.1+/5.2+ API | <对应版本 stub（功能降级，root 不受影响） |
| ksys_close 未定义 | 5.10 改名 | 兼容头映射 sys_close |
| path_umount/path_mount/setns 未定义 | 5.9/4.17 API | fs/namespace.c backport + su_mount_ns.c 版本分支 |
| for 循环内声明报错 | 4.9 用 gnu89 | 驱动目录 -std=gnu11 |
| gnu11 下 selinux_state 等 | 同上 | 见 selinux.c 补丁 |
