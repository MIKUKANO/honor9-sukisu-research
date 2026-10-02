# 荣耀9 STF-AL10 启动链与分区情报（DEVICE_NOTES.md）

本项目逆向验证得到的事实，供后续任何开发参考。

## 一、基本盘

| 项 | 值 |
|---|---|
| 机型 | 荣耀9 高配版 STF-AL10（HWSTF），麒麟960 |
| 系统 | EMUI 9.1.0.225C00（Android 9，API 28），2021-12-09 构建 |
| 内核 | Linux 4.9.148，arm64，EROFS 系统分区 |
| Bootloader | 已解锁；`adb reboot bootloader` 可进 fastboot（无需音量键） |
| 音量键 | ✅ **实测可用**（`hisi_gpio_key` @ `/dev/input/event1`，注册 `KEY_VOLUMEDOWN`+`KEY_VOLUMEUP`）。2026-10-02 更正：此前"损坏"的记录是误判。**但按键组合能否进 fastboot/recovery 未经验证**，救援仍以 `adb reboot bootloader` 为准 |

## 二、启动链（逆向结论）

EMUI 9.1 Kirin **没有标准 boot/ramdisk 分区**。相关分区：

```
kernel        24MB   boot 镜像（ANDROID! v1 头 + 仅内核，RAMDISK_SZ=0）
dts           14MB   设备树（DTB，bootloader 加载后传给内核）
recovery_ramdisk 32MB  实测为空壳（ANDROID! 头 + 零填充）
erecovery_*          应急恢复套件
fastboot      12MB   bootloader 本体（含 ARM 向量表头、内嵌 ANDROID! 镜像与 cpio）
patch         200MB  全零（本机）
vector         4MB   ARM 代码（非 ramdisk）
```

- 内核分区原厂内容 = gzip 压缩的 38MB blob：`[ARM64 Image][IKCONFIG_ST 内嵌配置
  (168,173B)][rodata/kallsyms][空 initramfs cpio][默认 initramfs gzip (512B, dev/console+root)][6.5MB 附加数据]`
- ramdisk 来源：bootloader 内置（fastboot 区域，非 by-name 暴露）。刷入**纯
  Image.gz 的 boot 镜像**（RAMDISK_SZ=0）后系统照常启动，即证明 bootloader 有
  内置 ramdisk 兜底，且官方 `tools/pack_kernerimage_cmd.sh` 的 `--kernel Image.gz`
  用法在社区长期可用。
- 内核命令行（原厂）：`loglevel=4 initcall_debug=n page_tracker=on
  slub_min_objects=16 unmovable_isolate1=2:192M,3:224M,4:256M
  printktimer=0xfff0a000,0x534,0x538 androidboot.selinux=enforcing buildvariant=user`
- boot 头部关键参数：base 0x0 / kernel_offset 0x00080000 / tags 0x07A00000 /
  ramdisk_offset 0x07c00000 / page 2048 / header v1 / os 9 / patch 2020-10-01

## 三、华为安全加固（4.9.148 stock config 实测）

`CONFIG_HUAWEI_HIDESYMS=y`（kallsyms 符号隐藏，root 下读 /proc/kallsyms 残缺）、
`CONFIG_HW_ROOT_SCAN=y`、`CONFIG_TEE_ANTIROOT_CLIENT=y`、DM_VERITY+AVB、
HISI_SELINUX_EBITMAP_RO/PROT、HKIP 等。表现为：root 上下文无法读
/proc/cmdline、无法 cp /data/adb/magisk/*、无法 dd recovery_ramdisk。
本项目内核全部关闭，且 SELinux=Permissive 后上述读取全部恢复。

## 四、面具修补位置调查记录（供考证）

1. 内核分区原厂 blob 尾部（旧面具时期）含 Magisk ramdisk —— 但刷入纯内核后面具
   仍存活，说明另有载体；
2. 全部 27 个小分区明文扫描 `magisk`：零命中；
3. recovery_ramdisk 全 32MB 无 cpio/magisk；
4. 结论：修补位于 **by-name 之外的 bootloader 保留 flash 区**（压缩形态，明文
   不可见）。移除需要原厂固件对应镜像做区域恢复，风险为变砖级；
5. 机主最终自行完成移除。移除后启动正常，面具彻底失效。

**2026-10-01 复查（已确认彻底移除）**：`magiskboot cpio test` 判定
`recovery_ramdisk` 已回到原厂态（md5 `5112be528c51a78d0a8ed71fcba77bde`），
`/data/adb/magisk*`、`/cache/magisk*`、`/sbin/magisk`、`com.topjohnwu.magisk`
全部不存在，`ps -A | grep magisk` 无输出。

## 五、SukiSU 在本机的运行时形态

- 驱动内置（CONFIG_KSU=y + KSU_MANUAL_SU=y）；
- **hook 机制 = syscall tracepoint**（`register_trace_sys_enter`，
  `CONFIG_FTRACE_SYSCALLS=y`）。已接入的 syscall：
  `execve` / `faccessat` / `newfstatat` / `setresuid` / `clone` / `clone3`，
  以及 **`read`**（ksud 的 init.rc 注入，见 FIX_KSUD_INTEGRATION.md）。
  设备侧证据：dmesg 出现 `KernelSU: handle_setresuid ...`、
  `hook_manager: unmark ... exec ...`，这两条只可能由 `ksu_sys_enter_handler` 产生；
- **kprobe 路径全部失效**：`CONFIG_KPROBES=n` → `register_kprobe()` 恒 `-ENOSYS`。
  SukiSU 上游把 ksud 集成（execve/read/fstat/input_event）挂在 kprobe 上。
  **v24 起 4 个钩子的实际驱动路径**：
  `execve` / `read` → syscall tracepoint；`newfstat` → 源码级直钩
  `fs/stat.c:vfs_fstat()`；`input_event` → 源码级直钩
  `drivers/input/input.c:input_event()`（fstat/input 的 kprobe 注册已删除，
  避免将来打开 KPROBES 时重复处理）；
- 4.9 **没有 input 子系统 tracepoint**（`include/trace/events/` 下无 `input.h`），
  这是 `input_event` 只能走源码级直钩的原因；
- 超级调用 = `reboot(0xDEADBEEF, ...)` 魔数（源码钩子实现，非 kprobe）；
- 管理器识别 = setuid 钩子比对 appid（10189，编译期预设）→ task_work 注入
  `anon_inode:[ksu_driver]` fd → 管理器扫描自身 fd 表后 ioctl 通信；
- su 请求 = sucompat execve 拦截（优先于任何 su 二进制），permissive 下直接可用；
- 版本串 = `v4.1.1-非酋自制版`（version 40496 = 40000+提交数-2815）。

### sys_enter tracepoint 的三个硬约束（踩过坑，务必记住）

**① 跑在原子上下文里。** `arch/arm64/kernel/ptrace.c` 的 `syscall_trace_enter()`
在 `rcu_read_lock_sched()` 保护下调用 `trace_sys_enter()`，所以钩子回调里
`preempt_count() != 0`。**原子上下文禁止触发页错误** —— 直接调
`strncpy_from_user()` / `strncpy_from_user_nofault()` 读用户态字符串，
当目标页未驻留时会静默返回 `-EFAULT`。

必须照抄 `sucompat.c:ksu_handle_execve_sucompat()` 的逃生写法：

```c
if (ret < 0 && preempt_count()) {
    preempt_enable_no_resched_notrace();
    ret = strncpy_from_user(path, fn, sizeof(path));
    preempt_disable_notrace();
}
```

漏掉的后果：**偶发静默失败** —— 读不到路径 → 所有字符串比较分支被跳过 →
例如 `init` 执行 `/data/adb/ksud` 时认不出来 → ksud 拿不到 root →
`post-fs-data` 失败 → 模块又"重启不生效"。这种 bug 极难复现定位，
因为它在页面恰好驻留时就"正常"。

**② `comm` 过滤不能省。** `sys_enter` 对**所有** syscall 触发。
`__NR_read` 是极高频 syscall，必须先用 `current->comm` 廉价过滤
（只有 `init` 需要 init.rc 注入），否则整个系统的 read 都被拖进钩子。

**③ 别用 `uid == 0` 判"init 进程"。** Android 的 `zygote` / `zygote64`
**本身就是 uid 0**（由 init 以 root 启动），且 comm 被 `app_process` 的
main 线程改成了 `"main"`：

```
$ ps -A -o PID,PPID,USER,NAME | grep -i zygote
  561     1 root         zygote64
  563     1 root         zygote
```

所以 `current_uid().val == 0` **并不**等价于"init 或其子进程" ——
拿 uid 做前置门会把整个 zygote 系放进来，每次开机白读近千次路径、
刷出近千条 `Access filename when execve failed: -14`（v21 踩过，v22 修）。
精确判据是 `current->pid == 1 || !strcmp(current->comm, "init")`：

- `pid == 1` → init 本体
- `comm == "init"` → init **fork 出**的子进程（execve 之前 comm 仍继承 `"init"`）

### 排查启动问题：不要用 `dmesg`

系统 dmesg 环形缓冲只有约 **8000 行**。开机几十秒后，
1~25 秒的早期启动信息（**恰好包含 init.rc 注入、`ksud post-fs-data`、
`on_post_fs_data`、zygote 识别的全部证据**）就被冲掉了 —— 直接 `dmesg`
会什么都查不到，极易误判为"修复没生效"。

**正确做法**：ksud 每次开机把完整日志落盘到 `/data/adb/ksu/log/`：

| 文件 | 内容 |
|---|---|
| `dmesg.log` | 本次开机**完整**内核日志（从 `[0.000000]` 开始） |
| `dmesg.old.log` | 上一次开机（自动轮转） |
| `logcat.log` / `logcat.old.log` | 同上，logcat |
| `modules_info` | 已挂载模块及其 fd/ino |
| `sulog.log` | su 授权记录 |
| `znctx` | ZygiskNext 上下文 |

```bash
su -c 'grep -E "read init.rc|on_post_fs_data|exec zygote|allowlist" /data/adb/ksu/log/dmesg.log'
```

> 拉取时注意 `/data/adb/ksu/log/` 是 `drwx------ root`，adb shell 无权限。
> 需先 `su -c "cp ... /data/local/tmp/"` 再 `adb pull`。

### init.rc 的真实路径（重要，容易踩坑）

| Android 版本 | init.rc 路径 |
|---|---|
| **9 及以前（本机 EMUI 9.1）** | **`/init.rc`**（实测 36412 B，root:shell 0750） |
| 10 及以后 | `/system/etc/init/hw/init.rc` |

SukiSU 上游 `is_init_rc()` 只判断后者，导致在 Android 9 上
`KERNEL_SU_RC` 永不注入、`ksud post-fs-data` 永不执行、**模块系统整体失效**。
日志旁证：`init: /init.rc: 6: Could not import file '/init.rphone.rc'`。

## 六、关键文件在手机上的位置

| 文件 | 说明 |
|---|---|
| /sdcard/kernel_stock.img | 原厂内核备份（25,165,824 B，回滚即刷它） |
| /data/adb/ksud | ksud 主程序（3,996,264 B，管理器自举安装） |
| /data/adb/ksu/bin/ | busybox / magiskboot / resetprop / bootctl（ksud 自带工具） |
| /data/adb/ksu/.allowlist | 授权持久化文件（**正常时应非 0 字节**；0 字节即写盘失败） |
| /data/adb/ksu/log/ | ★ ksud 落盘的完整启动日志（`dmesg.log` 等，**排查必用**） |
| /data/adb/modules/ | 模块目录（`.core` / WorkSettingPro / zygisk_lsposed / zygisksu） |
| /data/local/tmp/ | 刷机临时目录（dd 读写镜像） |
| /init.rc | Android 9 的 init 脚本（36412 B，`KERNEL_SU_RC` 注入点） |
| /dev/block/by-name/kernel | 内核分区（= mmcblk0p39，24 MB） |
