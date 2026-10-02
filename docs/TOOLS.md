# 工具链与外部依赖清单（TOOLS.md）

> **本仓库不随包分发任何第三方二进制或源码。** 本文列出复现本项目所需的**全部**外部依赖，
> 以及每一项的**获取方式、版本、许可**。请自行从官方渠道下载。

---

## 一、为什么不分发

| 原因 | 说明 |
|---|---|
| **许可** | 多数工具为 GPL / 专有软件，本仓库以 MIT 发布，不适合转分发；华为 HiSuite 等为专有软件，禁止再分发。 |
| **体积** | 内核源码 ~1 GB、工具链 ~500 MB、platform-tools ~15 MB、`magiskboot` ~1 MB —— 远超本仓库（505 KB）的定位。 |
| **版本漂移** | 工具会更新，随包固化的旧版本反而误导。给出**获取方式 + 版本要求**更可靠。 |
| **安全** | 二进制分发易被篡改，从官方源获取更安全。 |

---

## 二、编译侧（Linux / VM 内）

| # | 工具 | 本项目所用版本 | 用途 | 获取方式 | 许可 |
|---|---|---|---|---|---|
| 1 | **盘古内核源码**<br>Pangu Kernel | `HarmonyOS` 分支<br>（Kirin 960 / EMUI 9.1 EROFS） | ⭐ **内核源码基线**，本项目在其之上打补丁 | `git clone --depth=1 https://github.com/maimaiguanfan/android_kernel_huawei_hi3660.git`<br>（国内镜像：https://gitee.com/maimaiguanfan/Pangu9.1EROFS ） | GPL-2.0 |
| 2 | **ARM GNU Toolchain**<br>（经盘古作者镜像） | gcc **10.3**<br>前缀 `aarch64-none-linux-gnu-` | 交叉编译内核 | `git clone --depth=1 -b aarch64-gcc10 https://gitee.com/maimaiguanfan/arm-gcc.git`<br>（上游：ARM 官方 GNU Toolchain，见 https://developer.arm.com/downloads/-/arm-gnu-toolchain-downloads ） | GPL-3.0 + GCC Runtime Library Exception |
| 3 | **SukiSU Ultra 驱动源码** | **v4.1.1**<br>（versionCode **40496**，须与管理器严格一致） | 内核态 root 驱动 | `curl -fL -o sukisu_v411.tar.gz https://github.com/SukiSU-Ultra/SukiSU-Ultra/archive/refs/tags/v4.1.1.tar.gz` | GPL-2.0 |
| 4 | **SUSFS 内核补丁** | 引擎 **1.5.9**（kernel-4.9 分支）<br>工具线格式 **2.0.0** | root 隐藏 | https://gitlab.com/simonpunk/susfs4ksu<br>（本项目只用了其内核补丁，并做了非 GKI 适配） | GPL-3.0 |
| 5 | **Ubuntu** | **20.04 x86_64**（22.04 缺 python2 需另行处理） | 编译宿主 | https://releases.ubuntu.com/20.04/ | — |
| 6 | 系统依赖包 | — | `build-essential bc bison flex libssl-dev libncurses5-dev python2.7 python-is-python2 cpio zip rsync wget perl git curl xz-utils` | `apt-get install`（`scripts/vm_setup.sh` 已自动化） | 各自开源许可 |
| 7 | **mkbootimg** | 随盘古源码提供（`tools/mkbootimg`） | 打包 boot 镜像（`--header_version 1`） | 已包含在依赖 #1 中 | AOSP / Apache-2.0 |
| 8 | **magiskboot**（可选） | 随 Magisk 发布 | 解包 / 分析 boot 镜像 | https://github.com/topjohnwu/Magisk/releases | GPL-3.0 |

> ⚠️ **#3 的版本一致性是硬要求**：驱动 tag、versionCode、管理器 APK 三者必须对齐，
> 否则会出现「管理器按版本号找不到随包工具、SUSFS 命令全部失效」的问题 —— 这正是本项目 v31 修复的那个 bug。

---

## 三、刷写 / 设备侧（Windows）

| # | 工具 | 用途 | 获取方式 | 许可 | 本仓库是否提供 |
|---|---|---|---|---|---|
| 9 | **Android platform-tools**（adb / fastboot） | 刷写、调试、回读校验 | https://developer.android.com/studio/releases/platform-tools | Apache-2.0 | ❌ |
| 10 | **Google USB Driver**（需改版 INF） | 让 Windows 认到 fastboot 设备 | 基于 https://developer.android.com/studio/run/win-usb 修改 | — | ✅ **仅提供补丁片段**（`docs/FLASH_AND_RESCUE.md` 中的 INF 行） |
| 11 | **HiSuite / 华为手机助手** | 提供华为 USB 驱动（adb 通道） | https://consumer.huawei.com/cn/support/hisuite/ | 专有（禁止再分发） | ❌ |
| 12 | **麒麟盘古工具箱**（可选） | 一键刷机 GUI，内置 adb / fastboot | 由盘古作者发布（第三方整理，**非官方**） | — | ❌ |
| 13 | **SukiSU Ultra 管理器 APK** | root 授权与 SUSFS 配置界面 | https://github.com/SukiSU-Ultra/SukiSU-Ultra/releases | GPL-2.0 | ❌ |
| 14 | **LSPosed** | Xposed 框架（本项目用 v2.2.0 / 7854） | https://github.com/LSPosed/LSPosed/releases | GPL-3.0 | ❌ |
| 15 | **Zygisk Next** | Zygisk 实现（模块 id `zygisksu`） | https://github.com/Dr-TSNG/ZygiskNext | GPL-3.0 | ❌ |

> **说明**：`麒麟盘古工具箱` 只是便利封装。**官方 `platform-tools` + 改版 INF 就足够完成全部刷写操作**，
> 本项目实际的刷写流程走的就是 `adb`（见 `scripts/flash_phone.ps1`），并不依赖该工具箱。

---

## 四、分析侧

| # | 工具 | 版本 | 用途 | 获取方式 | 许可 |
|---|---|---|---|---|---|
| 16 | **jadx** | **1.5.0** | 反编译 SukiSU 管理器 APK（定位 SUSFS 版本号→工具名 的调用链） | https://github.com/skylot/jadx/releases | Apache-2.0 |
| 17 | **Momo（Mahoshojo）** | 4.4.1 | 仅作为**检测验证**工具（确认 root 痕迹暴露面），**非本项目组件** | https://github.com/vvb2060/Mahoshojo | — |

---

## 五、一句话获取全部编译依赖

```bash
# 在 Ubuntu 20.04 上（会自动跳过已存在的产物）
sudo -E bash scripts/vm_setup.sh
```

该脚本会依次完成：系统依赖 → 内核源码（盘古）→ 工具链 → SukiSU 驱动 → defconfig → 补丁。
**注意**：脚本假定 `sukisu_all_patches.diff` 与 `ksu_compat_49.h` 位于 `$WORK` 目录下，
前者是本项目全部内核改动的完整 diff，需按 `docs/PATCHES.md` 自行生成或逐条应用。

---

## 六、许可提示

- 本仓库**自行编写**的文档与脚本：**MIT**。
- 本仓库的**内核补丁**（`patches/*.patch`、`*.h`、`*_defconfig`）：**GPL-2.0**（Linux 内核衍生作品）。
- 上述所有第三方工具/源码，版权与许可**归各自作者所有**，详见 `NOTICE.md`。
