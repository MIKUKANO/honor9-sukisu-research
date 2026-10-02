# scripts/ — 构建、刷写与诊断脚本

> ⚠️ 使用前请先读 `docs/BUILD.md` 与 `docs/FLASH_AND_RESCUE.md`。
> 刷机会**变砖**，请确保已备份原厂内核。

## 文件清单

| 脚本 | 平台 | 说明 |
|---|---|---|
| `vm_setup.sh` | Linux/VM | **编译环境一键搭建**。系统依赖 → 拉取**盘古内核**源码 → 拉取 gcc 10.3 工具链 → 拉取 SukiSU v4.1.1 驱动并挂载进内核树 → 生成 defconfig → 应用补丁。可重复执行（已有产物自动跳过） |
| `build_and_pack.sh` | Linux/VM | **编译 + 打包**。生成 defconfig → `make Image.gz` → 校验 ARM64 魔数 → 用华为官方参数（`base=0x0`、`tags_offset=0x07A00000`、`kernel_offset=0x00080000`、`header_version=1` 等）打包成 `kernel_sukisu.img` |
| `flash_phone.ps1` | Windows | **刷入 + 校验**（`adb` 通道，无需 fastboot）。push → sha256 双向校验 → 备份存在性检查 → `dd` 写 `kernel` 分区 → `sync` → 回读截断校验 → `reboot`。支持 `-Adb <路径>` / `-Image <路径>` / `-SkipBackupCheck` |
| `flash_v31.sh` | 设备端 | **刷入 + 校验**（在设备 shell 内执行）。先备份现有内核 → `dd` 写 `kernel` 分区 → `sync` → **按镜像长度截断回读** → `sha256sum` 比对 |
| `avc_diag.sh` | 设备端 | **开机阶段诊断脚本范例**。放到 `/data/adb/post-fs-data.d/` 可测量「该阶段能否成功执行某条命令」（本项目用它验证了 SUSFS 的 `post-fs-data` 时序）。⚠️ 用完请删除 |
| `patch_namespace.py` | 任意 | 给 `fs/namespace.c` 的 `susfs_is_mnt_devname_ksu()` 加开关门控（含 `-Wdeclaration-after-statement` 的声明顺序修正，幂等） |
| `mkprobe.py` | 任意 | 构造一条合成的 `allowlist` 探测条目（复制现有记录、仅改 key/uid），用于验证 KSU 授权持久化的「读 + 写」两条路径 |
| `tune_v30_defconfig.py` | 任意 | v30 性能优化尝试的配置调整脚本 —— **该次尝试失败并已回滚**，此文件作为踩坑留档（见 `docs/PATCHES.md` §O） |

> **推荐顺序**：`vm_setup.sh` → `build_and_pack.sh` → `flash_phone.ps1`（或 `flash_v31.sh`）。
> 全部外部依赖见 [`../docs/TOOLS.md`](../docs/TOOLS.md)。

## 重要提示

### 1. `flash_v31.sh` 的回读校验必须**按镜像长度截断**

```sh
SZ=$(wc -c < "$IMG"); CNT=$(( (SZ + 4095) / 4096 ))
dd if=$K of=/data/local/tmp/rb.img bs=4096 count=$CNT
dd if=/data/local/tmp/rb.img of=/data/local/tmp/rb_trunc.img bs=$SZ count=1
sha256sum /data/local/tmp/rb_trunc.img "$IMG"
```

⚠️ **不要**给期望镜像补零 —— 回读多出来的半页是**上一个内核**的残留，直接整块比对会永远失败。

### 2. `build_and_pack.sh` 的 `CONFIG_LOCALVERSION` 陷阱

若 `CONFIG_LOCALVERSION` 里含 shell 元字符（如 `&`），顶层 `Makefile` 的
`filechk_utsrelease.h` 会因为 `KERNELRELEASE` 未加引号而被 `/bin/sh` 当作后台符，报 `Error 127`。
需改为：

```make
printf '#define UTS_RELEASE "%s"\n' '$(KERNELRELEASE)'
```

### 3. 诊断脚本的通用手法

`avc_diag.sh` 演示了一个非常有用的技巧：**把临时脚本丢进
`/data/adb/post-fs-data.d/`（或 `service.d/`），把命令的 `$?` 写进日志文件，重启后读日志**。
这是判断「某条命令在开机某阶段能否成功」的唯一可靠办法 —— 很多管理器脚本
**不记录 `$?`**，日志里写的「成功」并不代表真的成功。

## 环境变量

`build_and_pack.sh` 支持用环境变量覆盖默认值：

```sh
SRC=/root/kernel_src_gh                       # 内核源码目录
TC=/root/toolchain/bin/aarch64-none-linux-gnu- # 交叉工具链前缀
DEFCONFIG=Pangu_SukiSU_defconfig
JOBS=$(nproc)
KBUILD_BUILD_USER / KBUILD_BUILD_HOST        # 构建标识（显示在 /proc/version）
```
