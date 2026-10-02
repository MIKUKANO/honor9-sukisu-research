# 刷入 / 提取 / 回滚 / 救援（FLASH_AND_RESCUE.md）

## 一、刷入内核（免音量键）

前提：系统能开机且 adb 可用；已取得 `kernel_sukisu.img`。

```powershell
# 1) 推送
adb push kernel_sukisu.img /data/local/tmp/

# 2) 双向哈希校验（必须一致再继续）
adb shell "su -c 'sha256sum /data/local/tmp/kernel_sukisu.img'"
Get-FileHash kernel_sukisu.img -Algorithm SHA256   # PC 端对比

# 3) 刷入（EMUI 的 dd 不支持 conv=fsync，用独立 sync）
adb shell "su -c 'dd if=/data/local/tmp/kernel_sukisu.img of=/dev/block/by-name/kernel bs=4096'"
adb shell "su -c 'sync'"

# 4) 读回校验（页数 = 镜像字节数/4096 向上取整，然后**截断回原长度**再比对）
adb shell "su -c 'dd if=/dev/block/by-name/kernel of=/data/local/tmp/rb.img bs=4096 count=3701'"
adb shell "su -c 'head -c 15157248 /data/local/tmp/rb.img > /data/local/tmp/rb_trunc.img'"
adb shell "su -c 'sha256sum /data/local/tmp/rb_trunc.img'"   # 与第 2 步哈希比对

# 5) 重启
adb reboot
```

> ⚠️ **读回校验必须截断**：`Ceiling(size/4096)*4096` 通常大于 `size`
> （例如 15,157,248 B = 3700.5 页 → 读 3701 页 = 15,159,296 B，多出 2 KB）。
> 直接 `sha256sum` 整个读回文件会因尾部残留字节恒不相等，误报"刷写未验证"。
> 尾巴那 2 KB 是分区原有数据，无害 —— boot 头的 `kernel_size` 决定了实际读取长度。
> （`scripts/flash_phone.ps1` 已在 2026-10-02 修掉这个 bug。）
>
> ⚠️ **截断不要写成 `su -c 'head -c N f | sha256sum'`**：SukiSU 的 su_compat 下这条
> 管道的 stdout 会丢失（返回空串 → 误报 MISMATCH）。必须拆成「先重定向落盘、再单独
> `sha256sum`」两步（见 `scripts/flash_phone.ps1` 的注意 2）。

一键脚本：`scripts/flash_phone.ps1`（内置全部校验，任一步失败自动中止）。

## 二、提取 boot / 内核（一键）

```powershell
powershell -ExecutionPolicy Bypass -File scripts\extract_boot.ps1
```

产物（`extract_out/`）：内核分区完整备份、解压后的 ARM64 Image、boot 头部与
cmdline、当前运行内核配置（/proc/config.gz）、/proc/version、dts 分区、
recovery_ramdisk 分区。用于更换开发工具时的基线对照。

## 三、回滚原厂内核

原厂备份有两份：PC 端 `artifacts/kernel_stock_backup.img`（25,165,824 字节）与
手机端 `/sdcard/kernel_stock.img`。

```bash
adb shell "su -c 'dd if=/sdcard/kernel_stock.img of=/dev/block/by-name/kernel bs=4096'"
adb shell "su -c 'sync'"
adb reboot
```

回滚后**面具不会恢复**（2026-10-01 已彻底移除：App 卸载、`/data/adb/magisk*`
删除、`recovery_ramdisk` 还原原厂、magiskd 进程消失）。原厂内核下将没有 root，
需要重新 root 的话得走一次完整的面具/内核流程。

## 四、救援通道

| 场景 | 手段 |
|---|---|
| 系统能开机，adb 可用 | `adb reboot bootloader` 进入 fastboot（**不需要音量键**），BL 已解锁可直接 `fastboot flash kernel xxx.img` |
| 系统卡死但 adbd 已起 | 部分情况 `adb wait-for-device` 可抢救 |
| 完全变砖（无 adb） | 若物理按键组合不被 bootloader 接受，则无 fastboot/recovery → 只能拆机短接测试点或送修。**因此任何写入分区操作前必须完成备份与哈希校验** |

> 2026-10-02 更正：**音量键实测可用**（`hisi_gpio_key` @ `/dev/input/event1`，
> 注册了 `KEY_VOLUMEDOWN`+`KEY_VOLUMEUP`；按音量下使 `volume_music_speaker` 8→0）。
> 项目此前"物理损坏"的记录是误判。但**按键组合能否进 fastboot/recovery 未经验证**，
> 所以仍把 `adb reboot bootloader` 当作唯一可靠救援通道。

已验证：`adb reboot bootloader` → fastboot 可用（BL 解锁状态）。
bootloader 分区完整备份：`artifacts/fastboot_partition_backup.img`（12MB，sha256
`68f3d7715cd645dc1ff78bcbac4ab7399164c694254d40d1ee8837ef8b52d306`）。

## 五、面具清理现状（已彻底移除，2026-10-01）

- 面具 App：已卸载（`pm uninstall com.topjohnwu.magisk`）
- 数据残留：`/data/adb/magisk`、`/data/adb/magisk.db`、`/cache/magisk*`、
  `/sdcard/magisk.img`、`/sdcard/Download/magisk_patched-*.img` 全部删除
- ramdisk 补丁：`magiskboot cpio ramdisk.cpio test` 判定已回到原厂态
  （`recovery_ramdisk` md5 由 `0b262301675532e1e0ebf959eafbec0b` → `5112be528c51a78d0a8ed71fcba77bde`）
- magiskd 守护：**已消失**（`ps -A | grep magisk` 无输出），`/sbin` 恢复原厂
- PC 端回滚副本：`ksu-magisk-cleanup/`（含 Magisk 态与清洁态两份 ramdisk）
- SukiSU root：内核态实现，不依赖面具的任何部分

## 六、ksud 集成修复版刷入（v24 · 当前版本）

在 v23 基础上把"体检发现的剩余全部问题"一次修完：

- **P2 SELinux 规则引擎移植到 4.9**（`sepolicy.c` / `rules.c` 原被 `#if >= 5.2.0`
  编译成空桩）+ **Android 9 workqueue 补位**调用 `apply_kernelsu_rules()` /
  `cache_sid()` / `setup_ksu_cred()`（原来只挂在 Android 10+ 的 `second_stage` 分支）
- **P4 两个死钩子改源码级直钩**：`fs/stat.c:vfs_fstat()` 与
  `drivers/input/input.c:input_event()`
- **6 条既有编译警告清零**（`CC_ERRORS=0 CC_WARNS=0`）

详见 `FIX_KSUD_INTEGRATION.md` 与 `PATCHES.md` K.6。

```powershell
# 一键（推荐，内置全部校验；不传 -Image 时默认就是 v24）
powershell -ExecutionPolicy Bypass -File scripts\flash_phone.ps1 `
  -Image "C:\...\artifacts\kernel_sukisu_v24_hwfix.img"

# 或手工（注意 MSYS/Git Bash 下要给远端路径加 MSYS_NO_PATHCONV=1，
#         否则 adb push 会把 /data/local/tmp/... 转成 Windows 路径而失败）：
adb push artifacts/kernel_sukisu_v24_hwfix.img /data/local/tmp/kernel_new.img
adb shell "su -c 'sha256sum /data/local/tmp/kernel_new.img'"   # 与 PC 端比对
adb shell "su -c 'dd if=/data/local/tmp/kernel_new.img of=/dev/block/by-name/kernel bs=4096'"
adb shell "su -c 'sync'"
adb reboot
```

镜像信息：15,161,344 B，md5 `367452e90a48d27264a4155ac58df0bb`，
sha256 `7f58dae08ecc4712cc85c11244cb1ca9061829b18d57e5a9656f4b1028fd06be`。
启动后 `uname -a` 应显示 `#18 ... Thu Oct 1 19:04:05 UTC 2026`。

> ⚠️ **PowerShell 里 `su -c` 必须用单引号包住命令**：
> `& $adb shell "su -c 'cmd'"`（外层双引号 + 内层单引号）。
> 若写成 `& $adb shell su -c "cmd"`，PowerShell 会拆成多个 argv、adb 再用空格拼接，
> 远端只剩 `su -c <第一个词>`；带 `>` 重定向时更会由**非 root** shell 执行而静默失败。
> 2026-10-02 因此误判过一次"刷写未验证"。
> （`flash_phone.ps1` 已把**全部** `su` 调用统一成该形式。）
>
> ⚠️ 另一个 2026-10-02 踩到的坑：用 PowerShell 调用 `flash_phone.ps1` 时
> `*> file` / `Tee-Object` **捕获不到 `Write-Host` 输出**（脚本静默完成、看不出走到哪一步）。
> 排查时改为**手工分步执行 + 每步 `$L | Out-File` 落盘**，或直接看脚本是否触发了
> `adb reboot`（用 `uptime` 判断是否真的重启过）。

**刷前必做**：确认 `/sdcard/kernel_stock.img` 仍在（回滚唯一依靠）。

刷入后自查（⚠️ **用 ksud 落盘的完整日志，不要用 `dmesg`** —— 系统环形缓冲
只有约 8000 行，开机几十秒后早期启动信息就被冲掉了）：

```bash
# 功能标记
adb shell "su -c 'grep -c \"read init.rc\" /data/adb/ksu/log/dmesg.log'"             # 1
adb shell "su -c 'grep -c \"post-fs-data triggered\" /data/adb/ksu/log/dmesg.log'"  # 1
adb shell "su -c 'grep -c \"exec zygote\" /data/adb/ksu/log/dmesg.log'"              # 1
adb shell "su -c 'grep -c \"on_post_fs_data\" /data/adb/ksu/log/dmesg.log'"          # 2

# 噪声（v22 起应为 0）
adb shell "su -c 'grep -c \"Access filename when execve failed\" /data/adb/ksu/log/dmesg.log'"

# v23 两项（应为 1 / 0）
adb shell "su -c 'grep -c \"unregister init_rc_hook\" /data/adb/ksu/log/dmesg.log'"  # 1（原 37）
adb shell "su -c 'grep -c \"list_try_umount\" /data/adb/ksu/log/dmesg.log'"          # 0

# v24 新增：SELinux 规则已应用 + ksu_file_sid 非 0
adb shell "su -c 'grep \"selinux rules applied\" /data/adb/ksu/log/dmesg.log'"       # ksu_file_sid: 302
adb shell "su -c 'grep -c \"avc:  denied\" /data/adb/ksu/log/dmesg.log'"             # ~301（原 609）
adb shell "su -c 'grep -c \"scontext=u:r:su\" /data/adb/ksu/log/dmesg.log'"          # 0（原 446）

# 授权与模块
adb shell "su -c 'ls -l /data/adb/ksu/.allowlist'"          # 应为非 0 字节（1560 B 左右）
adb shell "su -c 'cat /data/adb/ksu/log/modules_info'"      # 应列出已挂载模块
adb shell "ps -A | grep -E \"lspd|zygisk\""                 # 应有守护进程（ps 不需要 su）
adb shell "su -c 'id'"                                      # uid=0(root) ... context=u:r:su:s0
```

历史版本（均已归档在 `artifacts/` 与 `_archive/patches/`）：
v19 `f74b7e2b...`（链路已通但刷屏）、v20 `d4c95cc6...`（修原子上下文）、
v21 `11052ea4...`（功能全绿但残余 965 条噪声）、v22 `fc617ace...`（噪声清零）、
v23 `e4385b64...`（`list_try_umount` 加固 + `init_rc_hook` 一次性门），
依次被后一版取代。

## 七、常见问题

**Q: 刷完重启卡第一屏/HUAWEI logo？**
先等 3 分钟（EMUI 首次启动慢）。仍卡 → 若 PC 上 `adb devices` 能看到设备
（部分卡屏阶段 adbd 已起）→ `adb reboot bootloader` 用 fastboot 刷回备份。
看不到设备 → 只能试按键组合（音量键实测可用，但组合是否被 BL 接受未验证），
否则需拆机短接测试点。

**Q: SukiSU 管理器显示"不支持"？**
① 内核驱动与管理器版本不匹配（内核 40496 ↔ 管理器 v4.1.1）；
② 驱动 fd 未注入（内核日志应有 `install fd for manager`，检查管理器 uid 是否
仍为 10189，变了则改 throne_tracker.c 的预设值重编）。

**Q: 应用请求 root 被拒？**
在 SukiSU 管理器「超级用户」里授权该应用。adb shell 的 root 同样在此授权
（shell 条目会在第一次 su 请求后出现）。
