# 刷入指南（FLASH.md）

> ⚠️ **刷机会变砖、会失去保修、可能清数据。请先完整读完本文，并确认你已备份原厂内核。**
>
> 本文面向**已经拿到 `kernel_sukisu_v34.img`** 的使用者。
> 如果你想自己编译，见 [`BUILD.md`](BUILD.md)。

---

## 0. 适用对象

| 项 | 值 |
|---|---|
| 机型 | **荣耀 9 高配版 STF-AL10**（HiSilicon Kirin 960 / EMUI 9.1 / Android 9） |
| 目标分区 | `kernel`（`/dev/block/by-name/kernel`） |
| 镜像 | `kernel_sukisu_v34.img`（见 [Releases](../../releases)） |

> ⚠️ **本设备没有独立的 boot/ramdisk 分区**：`initrd` 放在 `recovery_ramdisk` 分区，
> `kernel` 分区**只放内核**。因此我们**只写 `kernel` 分区**，不碰 ramdisk。

### 0.1 前置条件：**BL 解锁 ≠ 有 root**（重要的两个独立条件）

这两件事经常被混为一谈，但它们是**不同的门槛，必须同时满足**：

| | 解除 BL 锁 | root 权限 |
|---|---|---|
| **作用** | 让设备**愿意接受**未签名镜像 | 让**正在运行的系统**里有 `su` |
| **由谁提供** | bootloader（fastboot `flashing unlock`） | 内核里的 KernelSU / SukiSU |
| **在哪一步需要** | **刷机之前**（否则镜像被拒） | **刷机过程中**（`dd` 写分区那一步） |
| **没有会怎样** | 任何第三方镜像**直接拒绝启动** | `dd: Permission denied`，写不进分区 |

**光解 BL 锁是不够的**（对 `dd` 方式而言）—— 解了锁只代表"设备允许你刷"，
但**用 `dd` 写分区这个动作本身需要 root**。

> 💡 **但还有 fastboot 这条路可以绕过 root**，见下节。

### 0.2 ✅ 两条刷写通道（**fastboot 可用，且能救砖**）

本机型**两条路都通**：

| 通道 | 需要 root？ | 何时用 | 命令 |
|---|---|---|---|
| **A. adb + `dd`** | ✅ 需要 | 系统能正常开机 | `su -c 'dd if=xxx.img of=/dev/block/by-name/kernel'` |
| **B. fastboot** | ❌ **不需要 root** | ⭐ **系统开不了机时唯一选择** | `fastboot flash kernel xxx.img` |

**⭐ fastboot 是真正的救援通道** —— 它工作在 bootloader 层，**不依赖系统能否启动，也不需要 root**。

进 fastboot：**关机 → 按住音量下 + 插 USB**（设备枚举 `USB\VID_18D1&PID_D00D`，FriendlyName `HI3650`）。

> ⚠️ **必须先用改版 INF 装好驱动**，否则 Windows 认不出设备（`CM_PROB_FAILED_INSTALL`）。
> Google 官方 INF **不含 `18D1:D00D`**，需手工补一行。详见 [`FLASH_AND_RESCUE.md`](FLASH_AND_RESCUE.md)。

**实测证据**（2026-10-02，v30 事故救援）：

```
fastboot devices
  5JP0217C07002543  fastboot

fastboot flash kernel kernel_sukisu_v29.img
  Sending 'kernel' (14822 KB) OKAY
  Writing 'kernel' OKAY
```

⇒ **卡在「BL 已解锁」界面时，就是靠 fastboot 刷回旧内核救活的。**

> ℹ️ **华为 fastboot 只锁 `getvar`，没锁 `flash`**：
> `getvar all` / `product` / `unlocked` / `partition-size:*` 全部返回
> `FAILED (remote: 'Command not allowed')`，**只有 `max-download-size` 可读**。
> 但这**不影响 `flash` / `reboot`** —— 不要因为 getvar 报错就以为刷不了。

### 0.3 那什么时候非要有 root？

**只有走方式 A（`dd`）时才需要 root。** 典型场景：

- 系统能正常开机、你只是想**升级**内核 → 方式 A 最方便（不必关机进 fastboot）
- 想用 `scripts/flash_phone.ps1` 一键脚本（它走 adb + dd）

**全新零 root 设备**：直接走**方式 B（fastboot）**即可，不需要先有 root ——
fastboot 本身就是"从零开始刷入"的通道。步骤：

1. **解 BL 锁**（必做，否则 bootloader 拒绝写）。
2. **装好 fastboot 驱动**（改版 INF，见 [`FLASH_AND_RESCUE.md`](FLASH_AND_RESCUE.md)）。
3. 关机 → 音量下 + 插 USB → `fastboot flash kernel <img>` → `fastboot reboot`。
3. **拿到 root 后**，才回到本文，用 `dd` 刷入本项目的内核。

> 💡 **一句话总结**：解 BL 锁是"获得刷机资格"，root 是"获得刷机能力"。
> 本机因为 fastboot 被锁，**两者缺一不可**，且必须**先有 root 才能刷入提供 root 的内核**。

---

## 1. 下载并校验

从 [Releases](../../releases) 页面下载 `kernel_sukisu_v34.img`，然后**务必校验哈希**：

```bash
# Linux / macOS / Git Bash
sha256sum kernel_sukisu_v34.img

# Windows PowerShell
Get-FileHash .\kernel_sukisu_v34.img -Algorithm SHA256
```

**v34 期望值**（请以 Release 页面为准）：

```
文件大小  15,177,728 B
MD5       75446834432f4cbe138014333b1a2025
SHA256    f4032ba798626c5e895357a8a306d88bc4a818e9ac4aa715ff23146ff42d63c7
```

⚠️ **哈希不一致就不要刷。** 下载损坏的镜像写进 `kernel` 分区 = 直接变砖。

---

## 2. 备份原厂内核（**必做**，回滚唯一依靠）

> 💡 **如果你打算用 fastboot（方式 C）**：即使设备没 root 也能备份 ——
> 但 `dd` 需要 root。**没 root 就直接跳到 §3 方式 C**，用 fastboot 刷回官方镜像即可回滚。

用 `dd` 方式时，先备份：

```bash
adb shell "su -c 'dd if=/dev/block/by-name/kernel of=/sdcard/kernel_stock.img bs=4096'"
adb shell "su -c 'sync'"
adb shell "su -c 'ls -la /sdcard/kernel_stock.img'"     # 确认文件存在且非 0 字节
```

把 `/sdcard/kernel_stock.img` 也**拷一份到电脑**，别只留在手机上。

> ⚠️ 这一步需要 root。拿不到就改用 **fastboot 方式（§3 方式 C）**，它不需要 root。
> 无论哪种方式，**没有回滚手段的刷机等于赌博**。

---

## 3. 三种刷入方式

| 方式 | 需要 root | 适用场景 |
|---|---|---|
| **A. 一键脚本** | ✅ | 日常升级，系统能开机 |
| **B. 手动 `dd`** | ✅ | 日常升级，想手动控制 |
| **C. fastboot** | ❌ | ⭐ **救砖 / 全新设备 / 系统开不了机** |

### 方式 C：fastboot（⭐ **救砖首选**，不需要 root）

进 fastboot：**关机 → 按住音量下 + 插 USB**（枚举为 `USB\VID_18D1&PID_D00D`）。

```bash
fastboot devices                              # 确认能看到设备
fastboot flash kernel kernel_sukisu_v34.img   # ✅ 实测可用（v30 事故即靠此救活）
fastboot reboot
```

> ⚠️ **驱动**：Google 官方 INF 不含 `18D1:D00D`，需用改版 INF 手工装
> （见 [`FLASH_AND_RESCUE.md`](FLASH_AND_RESCUE.md)）。没装驱动会报 `waiting for any device`。
>
> ℹ️ 华为 fastboot **锁 `getvar` 但不锁 `flash`** —— `getvar all` 报
> `FAILED (remote: 'Command not allowed')` 属正常，**不影响刷写**。

### 方式 A：Windows 一键脚本（走 adb + dd，需 root）

仓库自带 `scripts/flash_phone.ps1`，它会自动完成 push → 双向 sha256 → 备份检查 → 写入 → 读回校验 → 重启：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\flash_phone.ps1 `
    -Image .\kernel_sukisu_v34.img `
    -Adb "D:\platform-tools\adb.exe"
```

任何一步失败它会**直接中止**（不会留下写坏的分区）。

### 方式 B：手动 `dd`（需 root）

```bash
adb push kernel_sukisu_v34.img /data/local/tmp/kernel_new.img
adb shell "su -c 'dd if=/data/local/tmp/kernel_new.img of=/dev/block/by-name/kernel bs=4096'"
adb shell "su -c 'sync'"
```

---

## 4. 读回校验（**走 dd 时别跳过**）

> ℹ️ **方式 C（fastboot）不需要这一步** —— `fastboot flash` 自己会校验传输完整性，
> 成功时打印 `Writing 'kernel' OKAY`，失败会明确报错。
> **下面的步骤只针对方式 A / B（`dd`）。**

`dd` 写完不代表写对了。必须回读比对：

```bash
# 镜像大小（字节）
SZ=$(stat -c%s kernel_sukisu_v34.img)
# 向上取整到 4096 的页数
CNT=$(( (SZ + 4095) / 4096 ))

adb shell "su -c 'dd if=/dev/block/by-name/kernel of=/data/local/tmp/rb.img bs=4096 count=$CNT'"
# ⚠️ 必须截断回镜像长度再比 —— 多出来的半页是上一个内核的残留
adb shell "su -c 'head -c $SZ /data/local/tmp/rb.img > /data/local/tmp/rb_trunc.img'"
adb shell "su -c 'sha256sum /data/local/tmp/rb_trunc.img'"
```

⚠️ **两个坑**（都实际踩过）：
1. **必须按镜像长度截断**。镜像通常不是 4096 的整数倍（例如 15177728 B = 3705.5 页），
   不截断的话尾部残留字节会让哈希**永远对不上**。
2. **别把 `head -c` 和 `sha256sum` 用管道串起来**。在 SukiSU 的 `su_compat` 下，
   这条管道的 stdout 会丢失（返回空串），导致误报 `READBACK MISMATCH`。必须拆成两步。

---

## 5. 重启与验证

```bash
adb reboot
```

开机后确认：

```bash
adb shell "su -c 'uname -a'"
# 期望: Linux localhost 4.9.148-SukiSU #NN SMP PREEMPT ... aarch64

adb shell "su -c 'cat /proc/version'"
# 期望: Linux version 4.9.148-SukiSU (MIKUKANO@ATRI) (gcc version 10.3.1 ...) #NN ...
#       ↑ v34 的构建标识；v32 是 (root@x)

# 确认 root 与 SUSFS 都在
adb shell "su -c 'ksud susfs version'"
adb shell "su -c 'ksud susfs show enabled_features'"
```

> ⭐ **判断跑的是哪个内核，看 `#N` + 构建时间**，不要只看 `uname -r` ——
> 各版本的 `localversion` 可能相同。

---

## 6. 回滚

**方式 A（fastboot，不需要 root，系统开不了机也能用）** ⭐

```bash
fastboot flash kernel kernel_stock.img
fastboot reboot
```

**方式 B（`dd`，需要 root 且系统能开机）**

```bash
adb shell "su -c 'dd if=/sdcard/kernel_stock.img of=/dev/block/by-name/kernel bs=4096'"
adb shell "su -c 'sync'"
adb reboot
```

---

## 7. 卡住 / 变砖了怎么办

**卡在「BL 已解锁」界面** = 内核在显示驱动初始化前就挂了（**不是**存储卡顿）。

### ⭐ 首选：fastboot 刷回旧内核（**实测有效**）

这是**最可靠、最直接**的救援手段，**不需要系统能开机、不需要 root**：

```bash
# 关机 → 按住音量下 + 插 USB
fastboot devices                              # 应看到序列号
fastboot flash kernel <上一个能用的内核>.img
fastboot reboot
```

> ✅ **实战验证（2026-10-02）**：v30 刷入后卡在「BL 已解锁」界面，就是靠
> `fastboot flash kernel kernel_sukisu_v29.img` 救活的，输出 `Writing 'kernel' OKAY`。
> 从卡死到恢复正常约 **3 分钟**。

### 备选：eRecovery（fastboot 不可用时）

开机**按住音量上**进 eRecovery → 连 WiFi「下载最新版本并恢复」
（会重刷官方固件，**可能清数据**）。

按顺序尝试：

1. **长按电源键 10 秒**强制重启，看能否进系统。
2. **进 fastboot**（⚡ 优先）：关机 → 音量下 + 插 USB → `fastboot flash kernel <上次可用的 img>`。
3. **进 eRecovery**：开机**按住音量上**。

> ⚠️ **`recovery_ramdisk` 分区救不了你** —— 本机的 eRecovery 用的是**独立的**
> `erecovery_kernel` 分区（p35），所以 eRecovery 那条路必须按音量上。

详细排查见 [`FLASH_AND_RESCUE.md`](FLASH_AND_RESCUE.md)。

---

## 8. 常见问题

| 现象 | 原因 | 处理 |
|---|---|---|
| `dd: ... Permission denied` | 没走 root | 用 `su -c '...'`（外双内单）；或改用 fastboot |
| `fastboot waiting for any device` | 驱动没装 | 用改版 INF 装 `18D1:D00D`（见 `FLASH_AND_RESCUE.md`） |
| `fastboot getvar` 报 `Command not allowed` | 华为锁了 getvar | **正常**，不影响 `flash` |
| 读回 sha256 对不上 | 没截断 / 管道丢输出 | 见 §4 的两个坑 |
| 刷完进不去系统 | 镜像损坏或与本机型不匹配 | 回滚（§6），重新校验哈希 |
| `uname` 还是旧版本号 | 没重启，或写到了别的分区 | 重启；确认写的是 `by-name/kernel` |
| 开机后 root 没了 | 内核没起来（回滚到了原厂） | 检查是否写对分区 |
| SUSFS 命令报 "不支持" | 管理器与内核版本号不匹配 | 见 [`../patches/SUSFS_ABI_NOTES.md`](../patches/SUSFS_ABI_NOTES.md) |

---

## 9. 免责声明

- 本项目**仅供学习、研究与技术交流**。
- 刷写自定义内核会**使设备失去保修**、**可能变砖**、**可能清除数据**。
  **请自行评估风险，作者不对任何后果负责。**
- 请遵守你所在地区的法律法规。
