# NOTICE — 参考项目、致谢与 AI 使用声明

本文件是本仓库的**正式声明**，涵盖：第三方依赖、AI 使用情况、版权归属与免责条款。

---

## 一、参考项目与致谢

本项目的每一块拼图都来自以下优秀的开源项目。**没有它们，本项目不可能存在。**

| # | 项目 | 仓库地址 | 许可 | 在本项目中的角色 |
|---|---|---|---|---|
| 1 | ⭐ **盘古内核 Pangu Kernel**<br>（作者 **maimaiguanfan / 麥麥觀飯**） | https://github.com/maimaiguanfan/android_kernel_huawei_hi3660 <br>国内镜像：https://gitee.com/maimaiguanfan/Pangu9.1EROFS | GPL-2.0 | ⭐ **本项目的内核源码基线**（Kirin 960 / 4.9.148 / EMUI 9.1 EROFS）。本项目在其 `HarmonyOS` 分支之上打补丁。**荣耀 9 能跑第三方内核完全归功于盘古** |
| 2 | **ARM GNU Toolchain**<br>（经盘古作者镜像） | https://gitee.com/maimaiguanfan/arm-gcc （分支 `aarch64-gcc10`）<br>上游：https://developer.arm.com/downloads/-/arm-gnu-toolchain-downloads | GPL-3.0 + GCC Runtime Library Exception | 交叉编译工具链（gcc 10.3，前缀 `aarch64-none-linux-gnu-`） |
| 3 | **KernelSU** | https://github.com/tiann/KernelSU | GPL-2.0 | 内核态 root 方案的理论与代码基础 |
| 4 | **SukiSU Ultra** | https://github.com/SukiSU-Ultra/SukiSU-Ultra | GPL-2.0 | 本项目集成并适配的 root 方案（v4.1.1 / versionCode 40496） |
| 5 | **SUSFS** | https://gitlab.com/simonpunk/susfs4ksu | GPL-3.0 | root 隐藏内核补丁；上游提供 4.9 分支，本项目做了**非 GKI 适配** |
| 6 | **LSPosed** | https://github.com/LSPosed/LSPosed | GPL-3.0 | Xposed 框架（本项目使用 v2.2.0 / 7854） |
| 7 | **Zygisk Next** | https://github.com/Dr-TSNG/ZygiskNext | GPL-3.0 | Zygisk 实现（模块 id `zygisksu`） |
| 8 | **Shamiko** | https://github.com/LSPosed/LSPosed.github.io/releases | — | 「上锁状态」（BL 隐藏）脚本思路来源；SUSFS 管理器内置的隐藏脚本即改写自此 |
| 9 | **jadx** | https://github.com/skylot/jadx | Apache-2.0 | 反编译 SukiSU 管理器 APK 的分析工具（本项目用 1.5.0） |
| 10 | **Momo (Mahoshojo)** | https://github.com/vvb2060/Mahoshojo | — | 仅作为**检测验证**工具（确认 root 痕迹暴露面），**非本项目组件** |
| 11 | **Android USB Driver** | https://developer.android.com/studio/run/win-usb | — | fastboot 驱动；需手工补充 `USB\VID_18D1&PID_D00D` |
| 12 | **Android Open Source Project** | https://source.android.com/ | Apache-2.0 | 平台基础（`mkbootimg` 等） |
| 13 | **Linux Kernel** | https://www.kernel.org/ | GPL-2.0 | 内核基础 |

### 1.1 盘古内核对本项目的具体贡献

**必须澄清**：本项目**没有**从零编写任何 governor 或调度器。下列特性**全部由盘古内核提供**，
本项目只是**沿用**并把它们记录为性能基线：

| 特性 | 说明 |
|---|---|
| `zen` I/O 调度器 | 盘古从上游移植并设为默认 |
| `blu_schedutil` CPU governor | 盘古从 Honor 9 EMUI8 Proto Kernel 移植，设为默认 |
| `gpu_scene_aware` GPU governor | 盘古解锁的华为隐藏 governor |
| Dynamic Stune Boost | 盘古加入 |
| WireGuard | 盘古加入 |
| SELinux 限制解锁 | 盘古在 defconfig 层解锁 |
| Kirin 970 JPEG 处理引擎移植 | 盘古从 Kirin 970 移植 |
| `fsync` 开关 / Spectrum 支持 | 盘古加入 |

本项目**自行完成**的工作是：在其之上**集成 SukiSU Ultra 驱动 + 移植 SUSFS + 修复缺陷 + 逐项验证**。

### 1.2 特别说明

- 本仓库**不包含**上述任何项目的**完整源码树**或**预编译二进制**，只包含自行编写的
  **文档、脚本与补丁**。
- ⚠️ **例外（因 GPL 合规而随附）**：`patches/honor9_all_patches.diff` 中包含本项目**修改后的
  SUSFS 内核源码**（`fs/susfs.c`、`fs/sus_su.c`、`include/linux/susfs.h`、`susfs_def.h`、`sus_su.h`）。
  这些文件**源自 SUSFS 上游（GPL-3.0）**，版权归 **simonpunk / ShirkNeko** 所有。
  随附原因：本项目在 [Releases](../../releases) 分发编译好的内核二进制，
  按 GPL 必须能取得完整对应源码。**本仓库不对这些文件主张任何版权。**
- **全部外部依赖的版本、获取方式与许可，见 [`docs/TOOLS.md`](docs/TOOLS.md)。**
- `docs/` 与 `patches/SUSFS_ABI_NOTES.md` 中引用的代码片段，仅用于**技术说明**，版权归原项目所有。
- 如果本仓库的任何内容侵犯了你的权益，请提 Issue，作者会**立即**处理。

---

## 二、AI 使用声明

> **本项目的全部研究过程均在 AI 编程助手辅助下完成。在此如实声明。**

### 2.1 使用的工具

- **WorkBuddy AI**（底层为 Claude 系大语言模型）
- 辅助工具：jadx 1.5.0（反编译）、`aarch64-none-linux-gnu-` 工具链、Android platform-tools（adb / fastboot）

### 2.2 分工边界

| 环节 | AI 承担 | 人类承担 |
|---|---|---|
| **逆向分析** | 反编译 SukiSU 管理器 APK、定位 Java/Kotlin 调用链、比对 SUSFS ABI 布局、统计证据 | 提出排查方向、判断结论是否合理、否决错误推断 |
| **代码改动** | 编写/修改内核补丁、defconfig、构建与打包脚本、诊断脚本 | 审核改动、决定技术取舍 |
| **真机操作** | 生成刷写与回滚脚本、设计验证命令、解析输出 | **实际操作**：刷机、重启、按键、进入 fastboot / eRecovery |
| **文档整理** | 撰写全部 Markdown 文档、整理证据链、脱敏 | 提供实测反馈、纠正偏差 |

### 2.3 关于结论可靠性

AI 会犯错。本项目**刻意保留了「错误结论 → 实测推翻 → 修正」的完整记录**，供读者参考：

- `docs/PATCHES.md` §P.5 曾推测 SukiSU 管理器有「两处缺陷」，
  在 §P.9 经复核**被推翻**（原文保留了修正痕迹）。
- `docs/HEALTH_CHECK.md` §11 的第一版结论与 §11.0 的真正根因并存，明确标注了先后关系。

**因此**：文中每条关键结论都标注了**验证方法与原始证据**（命令、输出、日志片段），
读者可**独立复现核验**。请勿盲信，务必自行验证。

### 2.4 人类的责任

所有**最终决策**（刷不刷、改不改、删不删）与**真机操作**均由人类完成并承担后果。
AI 的产出经人类审核后才被采纳。

### 2.5 边界声明

**AI 未创作任何第三方项目。** 盘古内核、KernelSU / SukiSU Ultra、SUSFS、LSPosed、Zygisk Next、
Shamiko、jadx 等**全部由各自的人类作者开发**，AI 在本项目中只做了：

- **阅读**它们的源码 / 反编译产物；
- **编写**适配它们的内核补丁、defconfig、构建与诊断脚本；
- **撰写**记录这一切的文档。

因此本项目的 AI 声明**不适用于**上述任何第三方项目。

---

## 三、许可与版权

> ⚠️ **本仓库是混合许可的**：`LICENSE` 文件中的 MIT 条款**仅覆盖文档与脚本**，
> 不覆盖 `patches/` 目录下的内核补丁。请按下表区分使用。

| 内容 | 许可 | 说明 |
|---|---|---|
| 文档（`*.md`） | **MIT** | 见 `LICENSE` |
| 脚本（`scripts/`） | **MIT** | 见 `LICENSE` |
| **内核补丁**（`patches/*.patch`、`patches/*.h`、`patches/*.diff`、`patches/Pangu_SukiSU_defconfig`） | **GPL-2.0** | Linux 内核衍生作品；`LICENSE` 中的 MIT 条款**不适用**于这些文件 |
| ↳ 其中源自 **SUSFS** 的部分（`fs/susfs.c`、`fs/sus_su.c`、`include/linux/susfs*.h`） | **GPL-3.0** | 版权归 **simonpunk / ShirkNeko**；因 GPL 合规随附，本仓库不主张版权 |
| 引用的第三方项目 | 归各自作者所有 | 详见本文第一节 |

**为什么 `LICENSE` 里不写这条**：GitHub 的许可证识别器要求 `LICENSE` 为纯模板文本，
加入额外说明会导致识别失败（显示为 "Other"）。因此本仓库采用通行做法 ——
`LICENSE` 放纯净 MIT，**目录级例外在 `NOTICE.md`（本文件）声明**。

---

## 四、第三方工具的分发说明（**本仓库不随包提供**）

本项目需要大量外部工具才能复现。**为避免许可问题、体积膨胀与版本漂移，本仓库一律不转分发**，
只提供**版本要求 + 官方获取方式**：

| 类别 | 工具 | 本项目所用版本 | 获取方式 |
|---|---|---|---|
| 源码 | 盘古内核 | `HarmonyOS` 分支 | https://github.com/maimaiguanfan/android_kernel_huawei_hi3660 |
| 工具链 | ARM GNU Toolchain | gcc 10.3 | https://gitee.com/maimaiguanfan/arm-gcc （分支 `aarch64-gcc10`） |
| 驱动源码 | SukiSU Ultra | v4.1.1 / 40496 | https://github.com/SukiSU-Ultra/SukiSU-Ultra/releases/tag/v4.1.1 |
| 内核补丁 | SUSFS | 引擎 1.5.9 | https://gitlab.com/simonpunk/susfs4ksu |
| 刷写 | Android platform-tools | — | https://developer.android.com/studio/releases/platform-tools |
| 刷写 | HiSuite（华为 USB 驱动） | — | https://consumer.huawei.com/cn/support/hisuite/ （专有，禁止再分发） |
| 刷写 | 麒麟盘古工具箱（可选） | V4.9.12.8 | 盘古作者发布（第三方整理，非官方） |
| 管理器 | SukiSU Ultra APK | 4.1.1 (40496) | https://github.com/SukiSU-Ultra/SukiSU-Ultra/releases |
| 框架 | LSPosed | v2.2.0 (7854) | https://github.com/LSPosed/LSPosed/releases |
| 框架 | Zygisk Next | — | https://github.com/Dr-TSNG/ZygiskNext |
| 分析 | jadx | 1.5.0 | https://github.com/skylot/jadx/releases |
| 验证 | Momo | 4.4.1 | https://github.com/vvb2060/Mahoshojo |

> ⭐ **完整的依赖清单（含用途、许可、系统包列表、一键安装脚本）见 [`docs/TOOLS.md`](docs/TOOLS.md)。**
>
> ✅ **本仓库**提供**自行编写**的：文档、补丁、编译/打包脚本、刷写脚本、诊断脚本，以及
> fastboot 驱动所需的 **INF 补丁片段**（见 `docs/FLASH_AND_RESCUE.md`）。

---

## 五、免责声明

- 本项目**仅供学习、研究与技术交流**。
- 刷写自定义内核会**使设备失去保修**、**可能变砖**、**可能清除数据**。
  **请自行评估风险，作者不对任何后果负责。**
- 请遵守你所在地区的法律法规。**不得**将本项目用于任何非法用途。
- 本项目作者与上述第三方项目**无隶属关系**，不代表其立场。
