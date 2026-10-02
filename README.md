# 荣耀 9 (STF-AL10) · SukiSU Ultra 4.9 内核移植与研究记录

> 在 **华为荣耀 9（麒麟 960 / STF-AL10 / EMUI 9.1.0.225 / Android 9）** 上，
> 从零编译集成 **SukiSU Ultra v4.1.1** + **SUSFS** 的 **kernel 4.9.148** 内核，
> 并完整记录 **v18 → v31 共 14 个可运行版本**的迭代、踩坑、根因分析与真机验证过程。

---

## ⚠️ 免责声明

- 本项目**仅供学习、研究与技术交流**，目的是记录一次嵌入式内核移植的完整工程过程。
- 刷写自定义内核会**使设备失去保修**、**可能变砖**、**可能清除数据**。**请自行评估风险**，作者不对任何后果负责。
- 请遵守你所在地区的法律法规。**不要**将本项目用于任何非法用途。
- 文中涉及的内核源码、第三方模块（KernelSU / SUSFS / LSPosed 等）版权归各自作者所有，
  本仓库仅包含**自行编写的文档、脚本与补丁**。

---

## 🤖 AI 辅助声明

**本项目的全部研究过程均在 AI 编程助手辅助下完成，特此明确标注。**

| 环节 | AI 承担 | 人类承担 |
|---|---|---|
| 逆向分析 | 反编译 SukiSU 管理器 APK（jadx）、定位 Java/Kotlin 调用链、比对 ABI 布局 | 提出排查方向、判断结论合理性 |
| 代码改动 | 编写/修改内核补丁、defconfig、构建与打包脚本、诊断脚本 | 审核改动、决定取舍 |
| 真机操作 | 生成刷写与回滚脚本、设计验证命令 | **实际操作**（刷机、重启、按键、进 fastboot/eRecovery） |
| 文档整理 | 撰写全部 Markdown 文档、整理证据链 | 提供实测反馈、纠正偏差 |

**关于结论可靠性**：本项目刻意保留了「**错误结论 → 实测推翻 → 修正**」的完整记录
（例如 `docs/PATCHES.md` §P.5 的推测在 §P.9 被复核推翻）。
文中每条关键结论都标注了**验证方法与原始证据**，可直接复现核验。

**使用的模型/工具**：WorkBuddy AI（Claude 系模型）、jadx 1.5.0、aarch64-none-linux-gnu-gcc、
Android SDK platform-tools（adb / fastboot）。

---

## 🙏 参考项目与致谢

本项目的每一块拼图都来自这些优秀的开源项目，**特别致谢**：

| 项目 | 地址 | 许可 | 在本项目中的角色 |
|---|---|---|---|
| ⭐ **盘古内核 Pangu Kernel**<br>（作者 **maimaiguanfan / 麥麥觀飯**） | https://github.com/maimaiguanfan/android_kernel_huawei_hi3660 <br>（国内镜像 https://gitee.com/maimaiguanfan/Pangu9.1EROFS） | GPL-2.0 | ⭐ **本项目的内核源码基线**。荣耀 9 能跑第三方内核，全靠盘古。本项目在它的 `HarmonyOS` 分支之上打补丁 |
| **ARM GNU Toolchain**<br>（经盘古作者镜像） | https://gitee.com/maimaiguanfan/arm-gcc <br>（分支 `aarch64-gcc10`；上游 https://developer.arm.com/ ） | GPL-3.0 + GCC 例外 | 交叉编译工具链（gcc 10.3，`aarch64-none-linux-gnu-`） |
| **KernelSU** | https://github.com/tiann/KernelSU | GPL-2.0 | 内核态 root 方案的理论与代码基础 |
| **SukiSU Ultra** | https://github.com/SukiSU-Ultra/SukiSU-Ultra <br>（官网 https://sukisu.org/） | GPL-2.0 | 本项目集成并适配的 root 方案（v4.1.1, versionCode 40496） |
| **SUSFS** | https://gitlab.com/simonpunk/susfs4ksu | GPL-3.0 | root 隐藏内核补丁（上游为 4.9 提供了 patch，本项目做了非 GKI 适配） |
| **LSPosed** | https://github.com/LSPosed/LSPosed | GPL-3.0 | Xposed 框架（本项目安装 v2.2.0 / 7854） |
| **Zygisk Next** | https://github.com/Dr-TSNG/ZygiskNext | GPL-3.0 | Zygisk 实现（模块 id `zygisksu`） |
| **Shamiko** | https://github.com/LSPosed/LSPosed.github.io/releases | — | 「上锁状态」（BL 隐藏）脚本思路来源，SUSFS 管理器内置脚本即改写自此 |
| **jadx** | https://github.com/skylot/jadx | Apache-2.0 | 反编译 SukiSU 管理器 APK 的分析工具 |
| **Momo (Mahoshojo)** | https://github.com/vvb2060/Mahoshojo | — | 仅作为**检测验证**工具，非本项目组件 |
| **Android Bootloader Interface** | https://developer.android.com/studio/run/win-usb | — | fastboot 驱动（需手工补充 `VID_18D1&PID_D00D`） |

> ⭐ **盘古内核对本项目的具体贡献**：本项目的性能基线中，`zen` I/O 调度器、
> `blu_schedutil` CPU governor、`gpu_scene_aware` GPU governor、Dynamic Stune Boost、
> WireGuard、SELinux 限制解锁、Kirin 970 JPEG 引擎移植等，**全部来自盘古内核**，
> 并非本项目所加。本项目的工作是在此基础上**集成 SukiSU + SUSFS 并修复缺陷**。
>
> **完整的外部依赖清单（含版本、获取方式、许可、是否随包分发）见 [`docs/TOOLS.md`](docs/TOOLS.md)。**
> 本仓库**不随包分发任何第三方二进制或源码**。
>
> 如果本项目的任何内容侵犯了你的权益，请提 Issue，我会立即处理。

---

## 📦 成果概览

| 项 | 结果 |
|---|---|
| 目标机型 | 荣耀 9 高配版 **STF-AL10**（HiSilicon Kirin 960，Android 9 / API 28，EMUI 9.1.0.225） |
| 内核基线 | **盘古内核**（maimaiguanfan）· Linux **4.9.148** 华为魔改（非 GKI） |
| 集成的 root | **SukiSU Ultra v4.1.1**（`com.sukisu.ultra`，versionCode 40496） |
| 编入的隐藏 | **SUSFS**，`show enabled_features` 报告 **9 项全开** |
| 最终版本 | `4.9.148-非酋&大肥鱼自制max版`，内核 `#32`，构建者 `MIKUKANO@ATRI` |
| 编译状态 | `BUILD_EXIT=0`、`error` **0**、`undefined reference` **0** |
| 刷写方式 | `dd` 写 `kernel` 分区（**无 boot/ramdisk**，`RAMDISK_SZ=0`），回读 sha256 校验一致 |
| 救援通道 | eRecovery（音量上）+ **fastboot 已打通**（音量下 + 插 USB） |

**关键成果**

1. **把 SUSFS 移植到华为魔改的 4.9.148 内核**，并实现 13 条命令、6 个废弃命令正确返回 `126`。
2. **定位并修复 `reboot()` 魔法值重复派发**（内核日志差分从 `delta=2` 降到 `delta=1`）。
3. **找到「AVC 日志欺骗开关点不动」的真正根因**（管理器按内核报告的版本号去 APK 里找随包工具，对不上则**全部 SUSFS 命令失效**），并通过改内核版本号根治。
4. **打通 fastboot 通道**（推翻"Windows 下华为 fastboot 不可用"的旧结论，实际只是缺驱动）。
5. **查清两个「看起来像内核缺陷、实际都不是」的现象**（GPU 负载 -1%、卡顿真凶）。

---

## 🔧 内核版本演进

> ⭐ 判断设备当前跑哪个版本，看 `uname -a` 的 **`#N` + 构建时间**
> —— 因为各版本的 `localversion` 完全相同，只看 `uname -r` 无法区分。

| 版本 | 内容 | 标识 |
|---|---|---|
| v18 | SukiSU 首次跑通（Permissive） | — |
| v19 | 修复 `ksud` 集成 | — |
| v20 | 修复 preempt 相关缺陷 | — |
| v21 | 修复 uid gate | — |
| v22 | 修复 zygote 过滤 | — |
| v23 | 修复 P1+P3 | — |
| **v24** | sepolicy 空桩 → 移植 5 处 ABI；`fstat`/`input_event` 直钩 | 编译警告 6 → 0 |
| **v25** | 切回 **Enforcing**，删除 `ZCODE_FORCE_PERMISSIVE` | `#19` |
| **v26** | **编入 SUSFS** | `#24` |
| **v27** | 补齐 SUSFS 三项 + 修改 localversion | `#27` |
| **v28** | 修复 `sus_path_loop` 三处缺陷 | — |
| **v29** | 修复 `reboot()` 重复派发 + 注册去重 | `#28` |
| ~~v30~~ | 关闭 3 项 debug 配置做性能优化 → **刷入卡在「BL 已解锁」界面，已作废** | **勿刷** |
| **v31** | **`SUSFS_VERSION` `v2.3.0` → `v2.0.0`**，根治 AVC 开关 | `#32` |

**SELinux 域污染收敛**（`avc denied` 计数，原厂固件本身就有 ~186 条）：

```
v23 = 609  →  v24 = 301  →  v25 = 186/190/198  →  v26 = 218
其中 su / ksu / adbd 域恒为 0
```

---

## 🎯 关键技术点（各有一节详细文档）

### 1. SUSFS 移植到非 GKI 的 4.9 内核
- 引擎取自上游 **v1.5.9**（kernel-4.9 分支），派发机制改为
  `reboot(0xDEADBEEF, 0xFAFAFAFA, cmd, arg)`。
- ⭐ **唯一派发点 = `kernel/reboot.c` 的 `SYSCALL_DEFINE4(reboot)` 直钩**；
  `syscall_hook_manager.c` 里 `__NR_reboot` 的 tracepoint 分支**必须删掉**，否则同一条命令执行两遍。
- 判据：`dmesg | grep -c CMD_SUSFS_SHOW_VERSION` 前后差值必须为 **1**。
- 详见 `patches/SUSFS_ABI_NOTES.md`。

### 2. ⭐ 「AVC 日志欺骗」开关点不动的真正根因（本项目最有价值的发现）
- **症状**：SUSFS 配置页里该开关怎么点都不生效，配置不写盘。
- **根因**：SukiSU Ultra 4.1.1 在执行**任何** SUSFS 命令前，会按**内核报告的 SUSFS 版本号**
  去 APK 的 `assets/` 里取 `ksu_susfs_<版本>` 释放到 `/data/adb/ksu/bin/`。
  内核当时报 **`v2.3.0`**，而 APK 里**只有 `ksu_susfs_2.0.0`** ⇒ `getAssets().open()` 抛 `IOException`
  ⇒ 释放失败 `return null` ⇒ **所有 SUSFS 命令一起失效**。
- **关键陷阱**：`try { v = susfsVersion() } catch { v = "2.0.0" }` 的回退**只覆盖"取版本"那一步**；
  `open()` 抛异常时**直接 return null，没有任何回退** ⇒ **手动往 `/data/adb/ksu/bin/` 放工具没用**。
- **修复**：把内核 `include/linux/susfs.h` 的 `SUSFS_VERSION` 改回 `"v2.0.0"`。
  该版本号在管理器里只用于「拼工具名 / 写备份 JSON / 状态页显示」三处，**不控制任何功能** ⇒ 降版本号不丢功能。
- 详见 `docs/PATCHES.md` §P。

### 3. SELinux 强制模式的真相
- 内核 cmdline 里的 `androidboot.selinux` **完全不生效**（内核 `selinux_enforcing` 初值为 0，只认 `enforcing=`）；
  EMUI 的 init 会在开机 15.9s 时无条件 `security_setenforce(1)`。
- v19–v24 一直停在 Permissive 的**唯一**原因，是 `selinuxfs.c:sel_write_enforce()` 里我们加的
  `ZCODE_FORCE_PERMISSIVE` 补丁 —— **v25 已删除**。

### 4. ⭐ 性能优化的红线：`CONFIG_DEBUG_SPINLOCK` 不能关
- `drivers/vcodec/hi_vcodec/**` 是华为发布的**预处理后汇编（`.S`）**，直接 `bl __raw_spin_lock_init`（21 处），
  该符号**只在 `DEBUG_SPINLOCK=y` 时**由 `kernel/locking/spinlock_debug.c` 提供
  ⇒ 关掉就 `undefined reference`（而且 `.c`/`.h` 里 grep 不到这个符号，极易误判为"没人调用"）。
- ⭐ **补桩也没用**：v30 补了兼容桩后链接通过、镜像格式与原厂**逐字段一致**，
  但刷入后**卡在「BL 已解锁」界面** —— vendor 汇编是按 `DEBUG_SPINLOCK=y` 的 `struct raw_spinlock` 布局编译的，
  补桩只解决**链接**，解决不了**运行时布局不一致**。
- **结论：链接通过 ≠ 运行正确。** 本平台 `CONFIG_DEBUG_SPINLOCK` 必须保持 `=y`。

### 5. fastboot 通道打通
- 进 fastboot：**关机 → 按住音量下 + 插 USB**，枚举为 `USB\VID_18D1&PID_D00D`（FriendlyName `HI3650`）。
- Google 官方 INF **不含该 VID/PID**，需手工加一行 `%SingleBootLoaderInterface% = USB_Install, USB\VID_18D1&PID_D00D`。
- 打通后回滚内核只需 ~3 分钟，详见 `docs/FLASH_AND_RESCUE.md`。

---

## 📁 目录结构

```
honor9-sukisu-research/
├── README.md                     # 本文件
├── NOTICE.md                     # 参考项目清单 + AI 使用声明（正式版）
├── LICENSE                       # MIT（文档与脚本）
├── .gitignore
├── .gitattributes                # 强制 *.sh / *.patch 以 LF 入库
├── docs/
│   ├── DEVICE_NOTES.md           # 设备/分区/环境摸底
│   ├── BUILD.md                  # 编译环境搭建与构建流程
│   ├── TOOLS.md                  # ⭐ 工具链与外部依赖清单（版本/来源/许可/是否分发）
│   ├── FLASH_AND_RESCUE.md       # 刷入、回滚、救援（含 fastboot 驱动）
│   ├── HEALTH_CHECK.md           # 健康检查与逐项验证记录
│   ├── PATCHES.md                # 补丁全集与逐条根因分析（最核心，70KB）
│   └── FIX_KSUD_INTEGRATION.md   # ksud 集成问题的完整排查记录
├── patches/
│   ├── README.md                 # 各补丁用途说明
│   ├── SUSFS_ABI_NOTES.md        # SUSFS ABI 兼容笔记（双布局、err 偏移等）
│   ├── Pangu_SukiSU_defconfig    # 最终内核配置（基于盘古 Pangu_Kirin960_defconfig）
│   ├── ksud_integration_fix.patch
│   ├── v24_fixes.patch           # sepolicy 移植 + 直钩修复
│   └── ksu_compat_49.h
└── scripts/
    ├── README.md                 # 各脚本用途说明
    ├── vm_setup.sh               # Linux 侧：环境搭建 + 源码 + 工具链 + 驱动集成
    ├── build_and_pack.sh         # Linux 侧：编译 + 打包（华为 mkbootimg 参数）
    ├── flash_phone.ps1           # Windows 侧：push + 校验 + dd 刷入 + 回读
    ├── flash_v31.sh              # 设备侧：刷入 + 回读 sha256 校验
    ├── avc_diag.sh               # 开机阶段诊断脚本范例
    ├── mkprobe.py
    ├── tune_v30_defconfig.py
    └── patch_namespace.py
```

---

## 🚀 复现步骤（简述）

**一键路径**（Ubuntu 20.04 x86_64，2 核 4 GB 即可）：

```bash
sudo -E bash scripts/vm_setup.sh        # 依赖 + 盘古源码 + 工具链 + SukiSU 驱动 + defconfig + 补丁
sudo -E bash scripts/build_and_pack.sh  # 编译 + 打包 → $SRC/kernel_sukisu.img
```

**分步说明**：

1. **准备编译环境**：Linux（本项目用 Ubuntu 20.04，2 核即可）+ `aarch64-none-linux-gnu-` 工具链。
2. **获取内核源码**：**盘古内核**（`maimaiguanfan/android_kernel_huawei_hi3660`，`HarmonyOS` 分支，
   4.9.148 / Kirin 960 / 支持 EMUI 9.1 EROFS）。
3. **集成 SukiSU Ultra**：按上游文档接入驱动源码，或参考 `docs/BUILD.md`。
4. **打 SUSFS 补丁**：参考 `patches/SUSFS_ABI_NOTES.md` 与 `docs/PATCHES.md`。
   ⚠️ 注意本文档 §2 的版本号陷阱。
5. **编译打包**：`scripts/build_and_pack.sh`（注意 `CONFIG_LOCALVERSION` 含 `&` 时需改 `Makefile` 的 `filechk_utsrelease.h`）。
6. **刷入**：`scripts/flash_phone.ps1`（Windows）或 `scripts/flash_v31.sh`（设备侧）
   —— `dd` → `sync` → 回读 → sha256 比对。
   ⚠️ **回读必须按镜像长度截断**再比对，多出的半页是上一个内核的残留。

> **全部外部依赖（源码、工具链、platform-tools、APK 等）的版本与获取方式见 [`docs/TOOLS.md`](docs/TOOLS.md)。**

详细步骤见 `docs/BUILD.md` 与 `docs/FLASH_AND_RESCUE.md`。

---

## ⚠️ 已知限制（非缺陷）

- `reboot kprobe failed: -38` —— 无害。本平台未开 `CONFIG_KPROBES`，钩子实际用 syscall tracepoint 与直钩实现。
- 华为固件自身就有 1 条 sysfs WARNING 与 186~218 条 `avc denied`（原厂同样存在，**不建议去改**）。
- 华为把 GPU 负载放在私有节点 `/sys/class/devfreq/gpufreq/gpu_scene_aware/utilisation`（**英式拼写**），
  本平台**没有**标准 devfreq `load` 节点 ⇒ 通用工具箱读不到会回落哨兵值 `-1%`，**与内核改动无关**。
- SUSFS 的多数开关是**内核内存态**，重启即丢，需要每次开机重放（管理器「自动启动」可代劳）。
- root 环境必然留痕：Momo 等检测工具报告的「SELinux 规则异常（neverallow）」是 KernelSU 固有特征，
  **无法通过删模块/改配置消除**（KernelSU issue #2421 有"未装任何模块也报"的复现）。

---

## 📄 许可

- 本仓库的**文档与脚本**：**MIT**（见 `LICENSE`）。
- 本仓库的**内核补丁**（`patches/*.patch`、`patches/*.h`、`patches/Pangu_SukiSU_defconfig`）：
  属于 Linux 内核的衍生作品，遵循 **GPL-2.0**。
- 引用的第三方项目版权归各自作者所有，详见 `NOTICE.md`。
