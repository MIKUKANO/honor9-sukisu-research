# fastboot 驱动安装（Windows）

> **本文件解决的问题**：Windows 认不出处于 fastboot 模式的荣耀 9，
> `fastboot devices` 一直空、或报 `waiting for any device`。

---

## 1. 为什么需要这一步

进入 fastboot 后，设备以 `USB\VID_18D1&PID_D00D`（FriendlyName `HI3650`）枚举。
**Google 官方的 `android_winusb.inf` 里没有这个 VID/PID** —— 它只覆盖了
Nexus/Pixel 的 `4E40` / `2C10` / `4EE0` / `9004` / `9006` / `4D00` 等。

所以 Windows 报 `CM_PROB_FAILED_INSTALL`（设备管理器里是黄色感叹号）。

> ℹ️ **本文说的"驱动"和"能不能刷"是两层不同的东西**：
> - **这一层（驱动）**：让 Windows 认得出设备 ⇒ **本文解决的就是它**
> - **另一层（命令）**：设备接不接受 `fastboot flash` ⇒ 实测**华为只锁 `getvar`，没锁 `flash`**，
>   `fastboot flash kernel` **可用**（详见 [`FLASH.md`](FLASH.md) §0.2）

---

## 2. 获取官方驱动

从 Google 下载官方 USB 驱动包：

- **下载地址**：https://developer.android.com/studio/run/win-usb
- 或直接取包（页面上的 `usb_driver_r13-windows.zip`）
- 解压后会看到 `usb_driver/` 目录，内含 `android_winusb.inf`

> ⚠️ **本仓库不随包分发该驱动** —— 它含 Google 的 DLL 与 `.cat` 签名文件，
> 有版权与签名问题。请从官方渠道获取，然后按 §3 改一行。

---

## 3. 关键改动：加一行 VID/PID

用文本编辑器打开 `usb_driver/android_winusb.inf`，在 **两个** 段落的**开头**各加一行：

```ini
[Google.NTx86]
;荣耀 9 / Kirin 960 fastboot (HI3650)
%SingleBootLoaderInterface% = USB_Install, USB\VID_18D1&PID_D00D

[Google.NTamd64]
;荣耀 9 / Kirin 960 fastboot (HI3650)
%SingleBootLoaderInterface% = USB_Install, USB\VID_18D1&PID_D00D
```

**就这么一行（写两处）。** 其余内容不用动。

```
             改动前                              改动后
  ┌─────────────────────────┐        ┌─────────────────────────┐
  │ [Google.NTx86]          │        │ [Google.NTx86]          │
  │ ;Google Nexus One       │        │ ;荣耀9 Kirin960 fastboot │ ← 新增
  │ %SingleAdbInterface%... │        │ %SingleBootLoader...D00D│ ← 新增
  │                         │        │ ;Google Nexus One       │
  │                         │        │ %SingleAdbInterface%... │
  └─────────────────────────┘        └─────────────────────────┘
```

> 💡 本仓库的 `patches/winusb_honor9.patch` 就是这个改动的 diff，
> 可直接对官方 `android_winusb.inf` 应用。

---

## 4. 安装步骤（必须在设备管理器手工点）

> ⚠️ **本机没有管理员权限时 `pnputil` 不可用**；且改了 INF 之后 `.cat` 签名不匹配，
> **只能用"从磁盘安装"绕过**。下面是实测有效的路径。

1. **关机 → 按住音量下 + 插 USB**，进 fastboot 模式。
2. 打开**设备管理器**（`devmgmt.msc`），应看到一个**带黄叹号的设备**，名称类似 `HI3650`
   （或在"其他设备"下）。
3. 右键该设备 → **更新驱动程序** → **浏览我的电脑以查找驱动程序**
   → **让我从计算机上的可用驱动程序列表中选取**
   → 点 **从磁盘安装** → 选择你改过的 `android_winusb.inf`。
4. 型号列表里选 **Android Bootloader Interface** → 下一步 → 忽略签名警告。
5. 验证：

```bash
fastboot devices
# 期望: 5JP0217C07002543   fastboot
```

---

## 5. 常见问题

| 现象 | 原因 | 处理 |
|---|---|---|
| 设备管理器里是黄叹号 `CM_PROB_FAILED_INSTALL` | INF 不含 `18D1:D00D` | 按 §3 加行后重装 |
| "从磁盘安装"灰掉 / 报签名错误 | 改了 INF，`.cat` 签名失配 | 装的时候选"**让我从计算机上的可用驱动程序列表中选取**"再"从磁盘安装"；不要用 `pnputil` |
| `fastboot devices` 还是空 | ① 驱动没装上 ② 线是充电线（无数据）③ 没进 fastboot | 逐项排查；换原装数据线 |
| `fastboot getvar all` 报 `FAILED (Command not allowed)` | 华为锁了 `getvar` | **正常**，不影响 `flash` |
| `fastboot flash` 报 `FAILED (remote: ...)` | ① BL 未解锁 ② 分区名错 | 先解 BL 锁；确认分区名是 `kernel` |
| 设备管理器里出现 CD-ROM 而不是设备 | 那是 eRecovery 模式（不是 fastboot） | 重新按"音量下 + 插 USB"进 fastboot |

---

## 6. 备选：不用改 INF 的办法

如果不想动官方 INF，可以试**通用驱动**：

- **通用 ADB/Google USB 驱动**（如 `universal-adb-driver`、`AdbWinApi` 组合）
- 或在 Linux/macOS 上操作 —— **那两边不需要装驱动**，`fastboot` 直接可用

> 💡 **如果你有 Linux 环境（含 WSL2 + USB 直通、或一台 Ubuntu 机器），
> 刷机体验会更顺**：不需要折腾驱动，`fastboot devices` 开箱即用。

---

## 7. 参考

- Google 官方 USB 驱动说明：https://developer.android.com/studio/run/win-usb
- 本项目刷入总指南：[`FLASH.md`](FLASH.md)
- 救援与 fastboot 实测记录：[`FLASH_AND_RESCUE.md`](FLASH_AND_RESCUE.md)
