# NOTICE — 参考项目、致谢与 AI 使用声明

本文件是本仓库的**正式声明**，涵盖：第三方依赖、AI 使用情况、版权归属与免责条款。

---

## 一、参考项目与致谢

本项目的每一块拼图都来自以下优秀的开源项目。**没有它们，本项目不可能存在。**

| # | 项目 | 仓库地址 | 许可 | 在本项目中的角色 |
|---|---|---|---|---|
| 1 | **KernelSU** | https://github.com/tiann/KernelSU | GPL-2.0 | 内核态 root 方案的理论与代码基础 |
| 2 | **SukiSU Ultra** | https://github.com/SukiSU-Ultra/SukiSU-Ultra | GPL-2.0 | 本项目集成并适配的 root 方案（v4.1.1 / versionCode 40496） |
| 3 | **SUSFS** | https://gitlab.com/simonpunk/susfs4ksu | GPL-3.0 | root 隐藏内核补丁；上游提供 4.9 分支，本项目做了**非 GKI 适配** |
| 4 | **LSPosed** | https://github.com/LSPosed/LSPosed | GPL-3.0 | Xposed 框架（本项目使用 v2.2.0 / 7854） |
| 5 | **Zygisk Next** | https://github.com/Dr-TSNG/ZygiskNext | GPL-3.0 | Zygisk 实现（模块 id `zygisksu`） |
| 6 | **Shamiko** | https://github.com/LSPosed/LSPosed.github.io/releases | — | 「上锁状态」（BL 隐藏）脚本思路来源；SUSFS 管理器内置的隐藏脚本即改写自此 |
| 7 | **jadx** | https://github.com/skylot/jadx | Apache-2.0 | 反编译 SukiSU 管理器 APK 的分析工具（本项目用 1.5.0） |
| 8 | **Android USB Driver** | https://developer.android.com/studio/run/win-usb | — | fastboot 驱动；需手工补充 `USB\VID_18D1&PID_D00D` |
| 9 | **Android Open Source Project** | https://source.android.com/ | Apache-2.0 | 平台基础 |
| 10 | **Linux Kernel** | https://www.kernel.org/ | GPL-2.0 | 内核基础（华为开源 4.9.148 分支） |

### 特别说明

- 本仓库**不包含**上述任何项目的源码或二进制产物，仅包含自行编写的**文档、脚本与补丁**。
- `docs/` 与 `patches/SUSFS_ABI_NOTES.md` 中引用的代码片段，仅用于**技术说明**，版权归原项目所有。
- SUSFS 的 `kernel_patches/` 与 `ksu_susfs` 工具**未**随本仓库分发，请从上游获取。
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

---

## 三、许可与版权

| 内容 | 许可 |
|---|---|
| 文档（`*.md`）与脚本（`scripts/`） | **MIT**（见 `LICENSE`） |
| 内核补丁（`patches/*.patch`、`*.h`、`*_defconfig`） | **GPL-2.0**（Linux 内核衍生作品） |
| 引用的第三方项目 | 归各自作者所有，详见本文第一节 |

---

## 四、免责声明

- 本项目**仅供学习、研究与技术交流**。
- 刷写自定义内核会**使设备失去保修**、**可能变砖**、**可能清除数据**。
  **请自行评估风险，作者不对任何后果负责。**
- 请遵守你所在地区的法律法规。**不得**将本项目用于任何非法用途。
- 本项目作者与上述第三方项目**无隶属关系**，不代表其立场。
