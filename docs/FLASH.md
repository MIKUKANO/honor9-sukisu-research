# 刷入指南（FLASH.md）

> ⚠️ **刷机会变砖、会失去保修、可能清数据。请先完整读完本文，并确认你已备份原厂内核。**
>
> 本文面向**已经拿到 `kernel_sukisu_v32.img`** 的使用者。
> 如果你想自己编译，见 [`BUILD.md`](BUILD.md)。

---

## 0. 适用对象

| 项 | 值 |
|---|---|
| 机型 | **荣耀 9 高配版 STF-AL10**（HiSilicon Kirin 960 / EMUI 9.1 / Android 9） |
| 前提 | Bootloader **已解锁**，且设备**已 root**（`su` 可用） |
| 目标分区 | `kernel`（`/dev/block/by-name/kernel`） |
| 镜像 | `kernel_sukisu_v32.img`（见 [Releases](../../releases)） |

> ⚠️ **本设备没有独立的 boot/ramdisk 分区**：`initrd` 放在 `recovery_ramdisk` 分区，
> `kernel` 分区**只放内核**。因此我们**只写 `kernel` 分区**，不碰 ramdisk。

---

## 1. 下载并校验

从 [Releases](../../releases) 页面下载 `kernel_sukisu_v32.img`，然后**务必校验哈希**：

```bash
# Linux / macOS / Git Bash
sha256sum kernel_sukisu_v32.img
# 期望值见 Release 说明（形如 58ccabae5397...1bdad8）

# Windows PowerShell
Get-FileHash .\kernel_sukisu_v32.img -Algorithm SHA256
```

⚠️ **哈希不一致就不要刷。** 下载损坏的镜像写进 `kernel` 分区 = 直接变砖。

---

## 2. 备份原厂内核（**必做**，回滚唯一依靠）

```bash
adb shell "su -c 'dd if=/dev/block/by-name/kernel of=/sdcard/kernel_stock.img bs=4096'"
adb shell "su -c 'sync'"
adb shell "su -c 'ls -la /sdcard/kernel_stock.img'"     # 确认文件存在且非 0 字节
```

把 `/sdcard/kernel_stock.img` 也**拷一份到电脑**，别只留在手机上。

> 如果这一步拿不到（比如设备还没 root），就**不要继续**。没有回滚手段的刷机等于赌博。

---

## 3. 刷入

### 方式 A：Windows 一键脚本（推荐）

仓库自带 `scripts/flash_phone.ps1`，它会自动完成 push → 双向 sha256 → 备份检查 → 写入 → 读回校验 → 重启：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\flash_phone.ps1 `
    -Image .\kernel_sukisu_v32.img `
    -Adb "D:\platform-tools\adb.exe"
```

任何一步失败它会**直接中止**（不会留下写坏的分区）。

### 方式 B：手动（三条命令）

```bash
adb push kernel_sukisu_v32.img /data/local/tmp/kernel_new.img
adb shell "su -c 'dd if=/data/local/tmp/kernel_new.img of=/dev/block/by-name/kernel bs=4096'"
adb shell "su -c 'sync'"
```

### 方式 C：fastboot（设备进不了系统时）

进 fastboot：**关机 → 按住音量下 + 插 USB**（枚举为 `USB\VID_18D1&PID_D00D`）。

```bash
fastboot flash kernel kernel_sukisu_v32.img
fastboot reboot
```

> 驱动问题见 [`FLASH_AND_RESCUE.md`](FLASH_AND_RESCUE.md)。
> ⚠️ 华为的 fastboot 锁了大部分 `getvar`，只有 `max-download-size` 能读，属正常。

---

## 4. 读回校验（**别跳过**）

`dd` 写完不代表写对了。必须回读比对：

```bash
# 镜像大小（字节）
SZ=$(stat -c%s kernel_sukisu_v32.img)
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
# 期望: Linux version 4.9.148-SukiSU (user@host) (gcc version 10.3.1 ...) #NN ...

# 确认 root 与 SUSFS 都在
adb shell "su -c 'ksud susfs version'"
adb shell "su -c 'ksud susfs show enabled_features'"
```

> ⭐ **判断跑的是哪个内核，看 `#N` + 构建时间**，不要只看 `uname -r` ——
> 各版本的 `localversion` 可能相同。

---

## 6. 回滚

```bash
adb shell "su -c 'dd if=/sdcard/kernel_stock.img of=/dev/block/by-name/kernel bs=4096'"
adb shell "su -c 'sync'"
adb reboot
```

或 fastboot：`fastboot flash kernel kernel_stock.img`

---

## 7. 卡住 / 变砖了怎么办

**卡在「BL 已解锁」界面** = 内核在显示驱动初始化前就挂了（**不是**存储卡顿）。

按顺序尝试：

1. **长按电源键 10 秒**强制重启，看能否进系统。
2. **进 eRecovery**：开机**按住音量上**。可连 WiFi「下载最新版本并恢复」（会重刷官方固件，**可能清数据**）。
3. **进 fastboot**：关机 → 按住音量下 + 插 USB → `fastboot flash kernel <上次可用的 img>`。
   （实测从卡死到恢复约 3 分钟。）

> ⚠️ **`recovery_ramdisk` 分区救不了你** —— 本机的 eRecovery 用的是**独立的**
> `erecovery_kernel` 分区（p35），所以只有音量上那条路有效。

详细排查见 [`FLASH_AND_RESCUE.md`](FLASH_AND_RESCUE.md)。

---

## 8. 常见问题

| 现象 | 原因 | 处理 |
|---|---|---|
| `dd: /dev/block/by-name/kernel: Permission denied` | 没走 root | 用 `su -c '...'`，且引号必须是**外双内单** |
| 读回 sha256 对不上 | 没截断 / 管道丢输出 | 见 §4 的两个坑 |
| 刷完进不去系统 | 镜像损坏或与本机型不匹配 | 回滚（§6），然后重新校验哈希 |
| `uname` 还是旧版本号 | 没重启，或写到了别的分区 | 重启；确认写的是 `by-name/kernel` |
| 开机后 root 没了 | 内核没起来（回滚到了原厂） | 检查是否写对分区 |
| SUSFS 命令报 "不支持" | 管理器与内核版本号不匹配 | 见 [`../patches/SUSFS_ABI_NOTES.md`](../patches/SUSFS_ABI_NOTES.md) |

---

## 9. 免责声明

- 本项目**仅供学习、研究与技术交流**。
- 刷写自定义内核会**使设备失去保修**、**可能变砖**、**可能清除数据**。
  **请自行评估风险，作者不对任何后果负责。**
- 请遵守你所在地区的法律法规。
