# patches/ — 内核补丁与配置

> ⚠️ 本目录内容属于 **Linux 内核衍生作品**，遵循 **GPL-2.0**。
> 其中源自 **SUSFS**（GPL-3.0）的部分（`fs/susfs.c`、`fs/sus_su.c`、`include/linux/susfs*.h`）
> 版权归其作者所有 —— 因 GPL 合规而随附，详见 `../NOTICE.md`。

## 文件清单

| 文件 | 大小 | 说明 |
|---|---|---|
| ⭐ `honor9_all_patches.diff` | ~717 KB | ⭐ **完整内核补丁集**（191 个文件 / 23,251 行），相对**盘古内核 master**（`b15bb35c7`）生成。**这是复现整个项目的权威补丁**：`盘古上游源码 + 本 diff = 完整对应源码` |
| `Pangu_SukiSU_defconfig` | ~163 KB | **最终内核配置**（华为 Pangu / STF-AL10 平台）。关键项见下方 |
| `SUSFS_ABI_NOTES.md` | ~18 KB | **SUSFS ABI 兼容笔记** —— 双布局兼容、`err` 回写偏移、inode 状态位、验证判据等（移植时最有用） |
| `ksud_integration_fix.patch` | ~25 KB | **ksud 集成修复**（单独摘出，便于定位） |
| `v24_fixes.patch` | ~17 KB | **v24 修复**（单独摘出）—— sepolicy 空桩替换为 5 处 ABI 移植；`vfs_fstat()` / `input_event()` 直钩 |
| `ksu_compat_49.h` | ~1.4 KB | 4.9 内核兼容头（补足上游依赖的新 API） |

> ⭐ **`honor9_all_patches.diff` 已包含** SukiSU 驱动集成、SUSFS 移植（含新增的
> `fs/susfs.c`、`fs/sus_su.c`、`include/linux/susfs*.h`）、全树 `-Werror` 清理、
> defconfig 与版本串修改。**照它打一遍即可复现**。

## 复现完整源码（GPL 对应源码）

```bash
# 1. 取盘古内核源码（GPL-2.0）
git clone --depth=1 https://github.com/maimaiguanfan/android_kernel_huawei_hi3660.git kernel_src_gh
cd kernel_src_gh

# 2. 打上本项目的完整补丁
git -c core.autocrlf=false apply ../patches/honor9_all_patches.diff

# 3. 编译（见 docs/BUILD.md）
```

> ⚠️ **Windows 上必须加 `-c core.autocrlf=false`**，否则 git 会把补丁的 LF 转成 CRLF，
> 应用结果与目标逐字节不一致。
>
> 若个别 hunk 冲突（上游有新提交），用 `git apply --reject` 生成 `.rej` 后手工对齐。


## `Pangu_SukiSU_defconfig` 关键配置

```ini
CONFIG_KSU=y
CONFIG_KSU_DEBUG=y
CONFIG_KSU_MANUAL_SU=y
CONFIG_KSU_SUSFS=y
CONFIG_KSU_SUSFS_SUS_PATH=y
CONFIG_KSU_SUSFS_SUS_MOUNT=y
CONFIG_KSU_SUSFS_SUS_KSTAT=y
CONFIG_KSU_SUSFS_SPOOF_UNAME=y
CONFIG_KSU_SUSFS_ENABLE_LOG=y
CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG=y
CONFIG_KSU_SUSFS_OPEN_REDIRECT=y
CONFIG_KSU_SUSFS_SUS_MAP=y
CONFIG_KSU_SUSFS_AVC_LOG_SPOOFING=y
```

### ⚠️ 本平台的红线（**不要**改）

```ini
CONFIG_DEBUG_SPINLOCK=y              # 必须 =y，理由见 docs/PATCHES.md §O
CONFIG_BOOTPARAM_HUNG_TASK_PANIC=y   # 必须 =y，否则「卡死自动重启」变「永久卡死」
```

> `CONFIG_DEBUG_SPINLOCK=n` 会导致链接失败（`drivers/vcodec/hi_vcodec/**` 的预处理汇编直接调用
> `__raw_spin_lock_init`），**补桩也不能关** —— 实测刷入后卡在「BL 已解锁」界面。
> 详见 `docs/PATCHES.md` §O 与 `docs/HEALTH_CHECK.md`。

## 应用顺序

补丁的具体应用顺序与上下文，请配合 `docs/BUILD.md` 与 `docs/PATCHES.md` 阅读。
`v24_fixes.patch` 与 `ksud_integration_fix.patch` 基于华为 4.9.148 源码，
不同源码快照的行号可能有偏移，必要时手工对齐。

## 与 SUSFS 上游的关系

本项目的 SUSFS 引擎取自上游 **v1.5.9（kernel-4.9 分支）**：
https://gitlab.com/simonpunk/susfs4ksu

⚠️ **关于分发**：为满足 GPL「随二进制提供完整对应源码」的要求，`honor9_all_patches.diff`
**包含了**本项目修改后的 SUSFS 内核源码（`fs/susfs.c`、`fs/sus_su.c`、`include/linux/susfs*.h`）。
这些文件**源自 SUSFS 上游（GPL-3.0）**，版权归其作者 **simonpunk / ShirkNeko** 所有，
本仓库仅因 **GPL 合规**而随附，未做任何版权主张。

本项目在其基础上做了**非 GKI 适配**与若干缺陷修复，记录见 `docs/PATCHES.md`。
