# 内核完整体检报告（2026-10-02）

> 📝 **关于版本串**：本文档中的 `uname -a` / `UTS_RELEASE` 摘录来自实测日志。早期构建使用过
> 个人自定义的 `CONFIG_LOCALVERSION` 后缀，公开版本已统一隐去为 **`4.9.148-<自定义后缀>`**
> （本仓库现在的默认值是 `4.9.148-SukiSU`）。`#N` 与构建时间才是版本的真实标识，未作改动。
>
> 对象：设备当前运行的 `kernel_sukisu_v29.img`（内核 `#28`，`4.9.148-<自定义后缀>`）
> 结论：**功能全绿；SUSFS 9 项特性全部可用并逐条实测**；剩余项均非缺陷。
> 版本演进与缺陷修复见 §9；v26 首次编入的验证见 §8。

## 1. 功能验收（全部通过）

| 功能 | 判据 | 结果 |
|---|---|---|
| Root | `su -c 'id'` | `uid=0(root) … context=u:r:su:s0` ✅ |
| SELinux | `getenforce` | **Enforcing**（开机默认；管理器可切 Permissive，见 §8.4）✅ |
| KSU 规则 | `Cached ksu_file SID` / `selinux rules applied` | 302 / 出现 ✅ |
| **SUSFS** | `ksud susfs status` / `version` / `features` | **`true` / `v2.3.0` / 9 项** ✅ |
| **SUSFS 命令** | 官方 `ksu_susfs` 工具（13 条可用命令） | **全部 `rc=0`** ✅ |
| **SUSFS 功能** | uname 欺骗 / open_redirect / sus_path 隐藏 / **sus_map 隐藏（smaps）** | 四项端到端实测通过 ✅ |
| 模块系统 | `ksud module list` | 3/3 启用（WorkSettingPro / zygisk_lsposed / zygisksu）✅ |
| LSPosed | `/data/adb/lspd/log/verbose_*.log` | 每次开机新生 ✅ |
| 授权持久化 | 合成条目探测（读+写+字节级往返） | 全通过 ✅ |
| 音量键安全模式 | 物理按键 3 次 | 实测通过 ✅ |
| 管理器通道 | `/proc/<pid>/fd` | `anon_inode:[ksu_driver]` 就位 ✅ |
| 启动完整 | `boot_completed` / `on_post_fs_data` / `post-fs-data triggered` | 1 / 2 / 1 ✅ |

## 2. ⚠️ 更正一处历史错误数据：`avc: denied` 数量

之前记录的「v25 `avc: denied` **仅 11 条**」**是错的**。原因：它是在 `dmesg`（内核环形缓冲，
约 8000 行，开机数十秒后早期记录已被冲掉）上统计的 → **严重低估**。

正确口径：`/data/adb/ksu/log/dmesg.log`（ksud 落盘，完整覆盖 0–50s）。

| 版本 | `avc: denied`（0–50s） | 其中 `su`/`ksu`/`adbd` 域 | 全日志 `WARNING:` |
|---|---|---|---|
| v23（KSU 规则未加载） | **609** | **446** | 1 |
| v24 | 301 | **0** | 1 |
| v25（3 次开机） | **186 / 190 / 198** | **0** | 1 |
| **v26**（SUSFS 编入） | **218** | **0** | 1 |

> v26 的 218 条与 v25 同一量级（同一次快照里还叠加了 SUSFS 命令测试、LSPosed 首次注入等
> 额外活动），域分布完全一致，**没有任何 `ksu`/`su` 相关项**。SUSFS 的编入未引入新 denial。

**域分布**（v25）：`init`(45) / `zygote`(22) / `platform_app`(20) / `vendor_init`(17) /
`system_server`(17) / `hal_camera_default`(16) / `tee`(14) / `vold`(10) / `hal_wifi_default`(10) /
`kernel`(8) / `radio` / `nfc` / `logserver` / `system_app` / `untrusted_app` / `thermal` / `rild` /
`dubaid` / `fusd` / `xlogcat` / `audioserver` / `displayengineserver` / `cust` …

**访问目标**：`cota_vendor_data_file` / `hw_cust_file` / `storage_file` / `system_data_file` /
`sysfs_led` / `sysfs_fingerprint` / `bcm_wifi_open_state` / `sys_rcc_event` / `proc_signtool` /
`radio_rild_public_prop` / `media_rw_data_file` … —— **全是华为私有类型**。

⇒ **`u:r:ksu` / `u:object_r:ksu` 在全部 denial 中出现 0 次**；v25 的 denial 总数比 v24 还少。
这些是 EMUI 固件自身的策略缺口，与本项目无关，**不要逐条放行**。

> 教训：**统计 avc 数量绝不能用 `dmesg`**，必须用 `dmesg.log`。

## 3. 唯一一条"错误"日志：`reboot kprobe failed: -38` —— 无害（已证）

```
<3>[   13.710021] [pid:1,cpu7,swapper/0]KernelSU: reboot kprobe failed: -38
```

- 根因：`CONFIG_KPROBES` 未设 → `register_kprobe()` 恒 `-ENOSYS`（`-38`）。
- 该 kprobe（`supercalls.c:910` `reboot_kp` → `ksu_handle_sys_reboot()`）**唯一用途**：
  让管理器用 `reboot(KSU_INSTALL_MAGIC1=0xDEADBEEF, KSU_INSTALL_MAGIC2=0xCAFEBABE, …)`
  换取 KSU driver 的 fd。
- **但这不是唯一路径**：`setuid_hook.c:ksu_handle_setresuid()` 里，
  当 `current_uid == ksu_manager_appid` 时，内核会**自动** `ksu_install_fd()`
  （经 `task_work_add(..., TWA_RESUME)`）。

**实测验证**：
```
$ su -c 'ps -A -o PID,USER,NAME | grep sukisu'
 8376 u0_a189      com.sukisu.ultra
$ su -c 'ls -l /proc/8376/fd | grep ksu'
lrwx------ 1 root root 64 08:02 5 -> anon_inode:[ksu_driver]
```
⇒ 管理器**确实**拿到了 driver fd（走 setresuid 路径）。**这条 `-38` 属预期噪声，可忽略。**

## 4. 已知限制（都不是缺陷）

| 项 | 影响 | 说明 |
|---|---|---|
| `CONFIG_KPROBES` 未设 | `reboot kprobe failed: -38` | 见 §3，无害。4 个 ksud 钩子已全部改走 syscall tracepoint / 源码级直钩 |
| **SUSFS 三项曾"未启用"** | — | **v27 起已全部实现**（`add_sus_path_loop` / `add_sus_map` / `enable_avc_log_spoofing`），`ksud susfs features` = **9 项**。详见 §9 |
| **SUSFS `sus_path` / `sus_map` 只对 uid ≥ 10000 生效** | `adb shell`(2000) / root 仍能看到被标记路径 | **上游设计**，非缺陷。见 §8.3、§9.4 |
| `sus_path_loop` 的复打标跑在 kworker（域 `kernel`） | 登记 `shell_data_file` 类路径必然失败 | **上游固有作用域限制**。只登记 `system_file` 类路径；失败 3 次自动出列（v28） |
| `pkg_observer.c`（`#if >= 5.2.0`）不编译 | 卸载 App 后其 allowlist 条目残留到下次开机 | allowlist 只在 `boot-completed` 时 prune 一次 |
| `input_inject_event()` 未挂钩 | `sendevent` 裸写 evdev 可绕过音量键安全模式 | **有意不补**：补了也无法自动化（窗口 2~20s、adbd 22s 才起），且当前钩子在 `spin_lock` 外，优于上游 |
| `kernel_umount` feature 关闭 | 模块对未授权 App 可见 | 上游默认值，可在管理器里开启 |
| 华为固件自身 1 条 sysfs `WARNING` + 186~218 条 avc denied | 无 | 原厂同样存在，**别去改** |
| Windows fastboot 无驱动 | 不能走 fastboot 救援 | 环境问题（非内核）；改用 **eRecovery**（开机按住音量上） |

## 5. 配置快照（`/proc/config.gz`）

```
CONFIG_KSU=y
CONFIG_KSU_MANUAL_SU=y
# CONFIG_KSU_DEBUG is not set
CONFIG_FTRACE_SYSCALLS=y          ← syscall tracepoint 钩子依赖
CONFIG_SECURITY_SELINUX=y
CONFIG_DEFAULT_SECURITY_SELINUX=y
# CONFIG_KPROBES is not set        ← 4 个 ksud 钩子不能走 kprobe 的原因
CONFIG_KALLSYMS=y / CONFIG_KALLSYMS_ALL=y
CONFIG_KSU_SUSFS=y                ← v26 新增（下面 11 项全 =y）
CONFIG_KSU_SUSFS_SUS_PATH=y
CONFIG_KSU_SUSFS_SUS_MOUNT=y
CONFIG_KSU_SUSFS_AUTO_ADD_SUS_KSU_DEFAULT_MOUNT=y
CONFIG_KSU_SUSFS_AUTO_ADD_SUS_BIND_MOUNT=y
CONFIG_KSU_SUSFS_SUS_KSTAT=y
CONFIG_KSU_SUSFS_TRY_UMOUNT=y
CONFIG_KSU_SUSFS_AUTO_ADD_TRY_UMOUNT_FOR_BIND_MOUNT=y
CONFIG_KSU_SUSFS_SPOOF_UNAME=y
CONFIG_KSU_SUSFS_ENABLE_LOG=y
CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG=y
CONFIG_KSU_SUSFS_OPEN_REDIRECT=y
# CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS is not set
# CONFIG_KSU_SUSFS_SUS_OVERLAYFS is not set
# CONFIG_KSU_SUSFS_HAS_MAGIC_MOUNT is not set
# CONFIG_KSU_SUSFS_SUS_SU is not set
```

## 6. 复检命令（可随时重跑）

```bash
ADB="<adb路径>"
# 1) 拉完整日志（必须用这个，不要用 dmesg）
"$ADB" shell "su -c 'cp /data/adb/ksu/log/dmesg.log /data/local/tmp/x.log; chmod 644 /data/local/tmp/x.log'"
env MSYS_NO_PATHCONV=1 "$ADB" pull /data/local/tmp/x.log "C:/out/dmesg.log"

# 2) avc 统计
grep -c 'avc: *denied' dmesg.log                                          # 期望 180~200
grep 'avc: *denied' dmesg.log | grep -cE 'scontext=u:r:(su|ksu|adbd)'     # 期望 0
grep -o 'scontext=u:r:[a-zA-Z0-9_]*' dmesg.log | sort | uniq -c | sort -rn

# 3) 内核侧错误
grep 'KernelSU:.*\(failed\|err\|warn\|invalid\|unsupported\)' dmesg.log

# 4) 管理器 fd / 功能开关
"$ADB" shell "su -c 'ls -l /proc/\$(pidof com.sukisu.ultra)/fd | grep ksu'"
"$ADB" shell "su -c 'ksud feature list; ksud susfs status; ksud susfs version'"

# 5) SUSFS 工具逐条（★ 先确认工具就位；管理器按需释放，可能不在）
"$ADB" shell "su -c 'ls -l /data/adb/ksu/bin/ksu_susfs'"
# 若不存在，从管理器 APK 的 assets/ksu_susfs_2.0.0 释放到该路径并 chmod 755
"$ADB" shell "su -c '/data/adb/ksu/bin/ksu_susfs show version; echo rc=\$?'"

# 6) SUSFS 功能验证（★ sus_path 必须用 uid>=10000 才看得到效果）
"$ADB" shell "su 10123 -c 'ls -1 <被标记的目录>'"
```

## 7. 体检结论

**当前内核已达到本项目目标的"完成"状态**：root 授权持久、模块系统正常、
SUSFS 已编入且管理器全部命令可用、无与本项目相关的 denial / WARNING / 错误日志。

## 8. v26 · SUSFS 专项验证（2026-10-02）

### 8.1 命令级（官方 `ksu_susfs` v2.0.0 工具，逐条执行）

```
show version                     rc=0  → v2.3.0
show variant                     rc=0  → NON-GKI
enable_log 1                     rc=0
hide_sus_mnts_for_non_su_procs 1 rc=0
add_sus_path <f>                 rc=0
add_open_redirect <a> <b>        rc=0
add_sus_kstat <f>                rc=0
add_sus_kstat_statically <f> ... rc=0
update_sus_kstat <f>             rc=0
set_uname testrel testver        rc=0
```

内核日志同步显示对应 `CMD_SUSFS_* -> ret: 0`，无 `unknown cmd` / `not supported`。

### 8.2 功能性（不是只看返回值）

| 功能 | 操作 | 观察 |
|---|---|---|
| `set_uname` | `set_uname testrel testver` | `uname -r` → `testrel`，`uname -v` → `testver`（shell 与 root 均生效） |
| `open_redirect` | 把 `secret.txt` 重定向到 `fake.txt` | `cat secret.txt` 输出 `fake`（即 `fake.txt` 的内容） |
| `sus_path` | 标记 `secret.txt` / `hidden2.txt` | 以 **uid 10123** 运行：`ls` 中两项消失，`cat` 返回 `No such file or directory` |

### 8.3 ⚠️ sus_path 的作用域（易误判）

readdir / namei 钩子都有前置条件 `current->susfs_task_state &
TASK_STRUCT_NON_ROOT_USER_APP_PROC`，该标志只在 `setresuid()` 到**不在 allowlist 的 uid** 时设置。

* 用 `adb shell`（uid 2000）验证会看到文件**仍然可见** → 这是**正确的上游行为**，不是缺陷。
* 正确验证姿势：`su 10123 -c 'ls ...'`（非 root 用户 App uid）。
* root（`su`）永不隐藏。

### 8.4 SELinux 模式：Enforcing 为 ROM 默认（非缺陷）

```
$ adb shell getenforce
Enforcing
$ adb shell su -c 'cat /data/adb/ksu/log/dmesg.log' | grep type=1404
[15.887237] [pid:1,init] audit: type=1404 enforcing=1 old_enforcing=0
```

开机后为 `Enforcing` 是 **EMUI init 的 ROM 行为**：它在 15.9s 无条件
`security_setenforce(1)`（`buildvariant=user` → `IsEnforcing()` 恒真），
与内核、与 cmdline 都无关 —— **内核侧无缺陷**。

管理器的"宽容模式"开关**真正生效**（写入不再被补丁吞掉），但不落盘
（`shared_prefs` 中无该项），只对当前开机有效；
**需要宽容模式时，每次重启后在 SukiSU 管理器里重开一次即可。**

### 8.5 逆向笔记

双布局的完整推导（命令号表、err 偏移表、工具 126 哨兵机制、反汇编证据、
换设备时的复现步骤）见 **`patches/susfs/SUSFS_ABI_NOTES.md`**。

---

## 9. v27 → v29 · SUSFS 三项补齐 + 缺陷修复验收（2026-10-02）

v26 只做了"能跑通已有命令"，v27 补齐最后三项能力，v28/v29 再修掉实测暴露的 5 个缺陷。
**三个版本全部 `BUILD_EXIT=0 / ERRORS=0 / WARNINGS=0`**，全部刷入并回读 sha256 一致。

### 9.1 三项能力补齐（v27 完成，v29 复测仍 rc=0）

| 命令 | 命令号 | v26 | v27+ | 实现要点 |
|---|---|---|---|---|
| `add_sus_path_loop` | `0x55553` | 126 不支持 | ✅ rc=0 | 加入 `LH_SUS_PATH_LOOP`，每次 `setresuid` 后由 kworker 重新打标 |
| `add_sus_map` | `0x60020` | 126 不支持 | ✅ rc=0 | `INODE_STATE_SUS_MAP BIT(28)`；`fs/proc/task_mmu.c` 的 `show_smap()` / `pagemap_read()` 隐藏 |
| `enable_avc_log_spoofing` | `0x60010` | 126 不支持 | ✅ rc=0 | `security/selinux/avc.c:avc_dump_query()` 里把 `tsid == susfs_ksu_sid` 的拒绝伪装成 `priv_app` |

`ksud susfs features` 由 **7 项 → 9 项**（`SUS_MAP`、`AVC_LOG_SPOOFING` 出现在列表里）。

### 9.2 ⭐ 5 个缺陷修复（v28 修 3 个，v29 再修 2 个）

| # | 缺陷 | 表现（实测） | 修复 | 验证 |
|---|---|---|---|---|
| ① | **SUSFS 命令被重复派发** | 一次 `ksu_susfs` 调用产生 **2 条**内核日志；`add_sus_path_loop` 会往链表塞 **2 条重复条目**，后续每轮 setresuid 做两倍工作 | 删掉 `syscall_hook_manager.c` 里 `__NR_reboot` 的 tracepoint 分支，只保留 `kernel/reboot.c:SYSCALL_DEFINE4(reboot)` 的直钩 | `dmesg \| grep -c CMD_SUSFS_SHOW_VERSION` 前后差值 **2 → 1** |
| ② | `add_sus_path_loop` **延迟打标** | add 当时不解析路径，等到下一次 setresuid 才在 kworker 里做；失败也只有日志，调用方看到 rc=0 | 改成 **add 时就地 `kern_path()` + 打标**，失败立即 `err = -ENOENT` 返回给调用方，不入队 | add 后 5 s 内 kworker 出现 `re-flagged INODE_STATE_SUS_PATH on path '/system/etc/hosts'` |
| ③ | **重复注册同一条路径** | 重复 add 产生多条链表项 | 加 `cursor` 遍历 `LH_SUS_PATH_LOOP` 去重 | 第 2 次 add 同路径 → `rc=0` + `already in LH_SUS_PATH_LOOP` |
| ④ | **失败重试无限刷屏** | 打标失败的条目每轮 setresuid 都重试，`SUSFS_LOGE`(pr_err) 上 console（本 ROM `console_loglevel=4`），日志/控制台被刷爆 | 新增 `fail_count` 字段 + `SUSFS_SUS_PATH_LOOP_MAX_RETRY 3`；**连续失败 3 次自动出列**；失败日志改 `SUSFS_LOGI`(pr_info，不上 console) 且只记一次 | 见 §9.3 |
| ⑤ | **`pr_err` 用错级别** | 见 ④；另有 tmpfs/fuse 的"有意跳过"也被当错误刷屏 | `susfs_update_sus_path_inode()` 两处 `SUSFS_LOGE` → `SUSFS_LOGI`，并注明原因 | 修复后 kworker 相关 avc 仅 4 条，之后彻底静默 |

### 9.3 缺陷 ④ 的实测证据（负向用例）

注册一个 **kworker 域无法解析** 的路径（`/data/local/tmp/susfs_neg_test`，
SELinux 域是 `kernel`，目标标签 `shell_data_file` 不可 search）：

```
add_sus_path_loop …                        rc=0
kworker: Failed opening file '…'                          ← 第 1 次（pr_info，不上 console）
kworker: cannot re-flag path '…', retrying up to 3 times  ← 只记一次
kworker: Failed opening file '…'                          ← 第 2 次
kworker: Failed opening file '…'                          ← 第 3 次
kworker: giving up on path '…' after 3 failures, removing it from LH_SUS_PATH_LOOP
```

之后**再触发 8 次 setresuid**，该路径的日志计数**恒为 6 不再增长** ⇒ 条目已真正出列，
不再有周期性开销、不再刷 console。

> ⚠️ **为什么这个路径必然失败**：`sus_path_loop` 的复打标跑在 **kworker**（SELinux 域 `kernel`）里，
> 它 `kern_path()` 一个 `shell_data_file` 会直接被 SELinux 拒绝并产生 avc。
> 这不是缺陷，是上游设计的固有作用域限制 —— 详见
> `patches/susfs/SUSFS_ABI_NOTES.md` §9.3。

### 9.4 v29 验收表（内核 `#28`）

```
ksud susfs status      → true
ksud susfs version     → v2.3.0
ksud susfs features    → 9 项
add_sus_path_loop <f>  → rc=0（即时打标 + 去重 + 失败出列均验证）
add_sus_map <f>        → rc=0（内核日志 is flagged as INODE_STATE_SUS_MAP）
enable_avc_log_spoofing 1 / 0 → rc=0（enabled: 1 / enabled: 0）
```

**`sus_map` 端到端（smaps 隐藏）—— 已实测通过**（判据见 `SUSFS_ABI_NOTES.md` §9.2）：

标记 `/system/lib64/libc.so` 后，以 uid 10123 读 `/proc/self/smaps`：

| 观察者 | `^Size:` 行 | `^Rss:` 行 | 总行数 |
|---|---|---|---|
| uid 10123（标记前） | 115 | **115** | 2345 |
| uid 10123（标记后） | 115（不变） | **112**（少 3） | 2297（少 48） |
| uid 0（root，标记后） | 115 | **115**（完整） | — |

少掉的 3 个 vma = `cat` 映射 `libc.so` 的 `r-xp`/`r--p`/`rw-p` 三段，
其 `Rss`/`Pss`/`Shared_*`/`Private_*`/`Swap*`/`VmFlags` 等约 16 行统计被省略
（`48 = 3 × 16` 与总行数差完全吻合）。

> ⚠️ **易误判点**：被隐藏的 vma **头行仍在**，且 `Size` 填的是**真实 vma 大小**（不是 0）。
> 必须用 `^Rss:` / `^Pss:` 行数判断，去找 `Size: 0 kB` 会得出"没生效"的**错误**结论。
> 该标记无 remove 命令，重启即清除（仅影响 smaps 统计显示，无功能影响）。

镜像与校验：

| 版本 | 内核 | localversion | 镜像 md5 | 内嵌 Image.gz |
|---|---|---|---|---|
| v27 | `#27` | `<自定义后缀>` | — | 15173504 B |
| v28 | `#27` | 同上 | `24daf5f4c2e7685d89c0f087ab9043e2` | 15173536 B |
| **v29** | **`#28`** | 同上 | **`67cd30e58707170f1bbb8c52ecf647dd`** | 15174992 B |

`UTS_RELEASE = "4.9.148-<自定义后缀>"`（Makefile 的 `filechk_utsrelease.h`
已从裸 `echo` 改为 `printf '%s'`，否则 localversion 里的 `&` 会被 sh 当后台符 → 编译 Error 127）。

### 9.5 ⚠️ 遗留观察：两次非本项目原因的重启（已排查，无因果关系）

排查期间从设备取了两次 ramoops，**均已论证与本项目改动无关**，记录在此以免下次重复排查。

**(a) `context_struct_compute_av` oops（v28 某次开机 17.23 s）**

```
PC is at context_struct_compute_av+0xd8/0x4d0
Tainted: G W  4.9.148-<自定义后缀> #28
el0_svc_naked → SyS_faccessat → inode_permission2 → security_inode_permission
  → selinux_inode_permission → avc_has_perm_noaudit → avc_compute_av
  → security_compute_av → context_struct_compute_av → type_attribute_bounds_av
  → (嵌套) context_struct_compute_av
```

**非因果论证**：

1. 崩溃点在 `security/selinux/ss/services.c`，**本项目从未修改该文件**。
2. 本项目唯一改过的 SELinux 文件是 `security/selinux/avc.c`，改的是 `avc_dump_query()`
   （**审计格式化**路径）；崩溃发生在 `avc_compute_av` **之前**，调用链上不含任何被改代码。
3. `task_struct` 加字段只改变结构体大小，`avc_has_perm()` 读的是内存**内容**，
   与布局扩展无关。
4. 全仓库检索：该 oops 字符串**仅**出现在本次 `console-ramoops-0.txt`，
   历史日志与归档中无同类。
5. 内核随后 2 次开机均正常。

**(b) `hungtask` panic（1235.199 s）**

```
Kernel panic - not syncing: hungtask: blocked tasks
```

`mmc-cmdqd/0`(PID 280) 被阻塞 **840 s+**，连带 `ls`(8421)、`head`(8580, 852 s)、
`sh`、`iptables-restor`(8730, 474 s)、`app_process64`(8642, 699 s) 全部 D 态。
**根因是存储 I/O 停滞**，与内核改动无关。

### 9.6 排查方法学（本轮新增的判据）

* **`delta` 判据**：验证某命令是否被重复派发 ——
  ```sh
  B=$(su -c "dmesg | grep -c CMD_SUSFS_SHOW_VERSION")
  su -c '/data/adb/ksu/bin/ksu_susfs show version'
  A=$(su -c "dmesg | grep -c CMD_SUSFS_SHOW_VERSION")
  # A - B 必须为 1；为 2 说明有两个派发点
  ```
* **`console_loglevel` 判据**：`cat /proc/sys/kernel/printk` 首字段即 console 级别
  （本 ROM = `4`）⇒ `pr_err`(3) 上 console、`pr_info`(6) 不上。
  想"日志里有、控制台不刷屏"就用 `pr_info`。
* **`sus_path` / `sus_map` 的作用域**：必须用 `su <uid≥10000> -c '…'` 验证；
  用 `adb shell`（uid 2000）会得出"不工作"的**错误**结论（§8.3、§9.3）。

---

## 10. 传感器节点专项：GPU 负载恒显示 `-1%`（2026-10-02）

### 10.1 结论

**不是内核缺陷，也不是本项目改动引入的问题** —— 是本平台**没有**工具箱所读的那个节点。

* 本项目从未碰过 GPU / devfreq：`grep -n "devfreq\|gpufreq\|mali\|drivers/gpu" docs/PATCHES.md` → **零匹配**。
* 全树搜标准节点：`grep -rn 'dev_attr_load' drivers/devfreq/` → 只有 `l3c_devfreq.c:1312` 的
  `load_map`（L3 缓存调频器，与 GPU 无关）；**没有** `load` / `gpu_busy` / `gpu_load`。

### 10.2 本平台 GPU 负载的真实位置（英式拼写，注意）

华为把 GPU 负载放在自研调频器的**私有只读属性**里：

```
/sys/class/devfreq/gpufreq/gpu_scene_aware/utilisation      # 0444，只读
```

* 源码：`drivers/devfreq/hisi/governor_gpu_scene_aware.c`（726 行）
  * `GPU_SCENE_AWARE_ATTR_RO(utilisation);` → 注册进 `dev_attr_group`
  * 语义：`util = stat.busy_time * 100 / stat.total_time`（L123），滑窗加权后
    `data->utilisation = div64_u64(a, *freq)`（L138）
* `gpu_scene_aware/` 目录下属性全清单：
  `cl_boost` / `cl_boost_freq` / `scene` / `scene_para` / **`utilisation`**(只读) / **`vsync`**(只读)
* 实测（设备空闲）：`cat .../gpu_scene_aware/utilisation` → `0`

### 10.3 工具箱为什么显示 -1

工具箱按**通用路径**读负载，读失败时返回哨兵值 `-1`：

| 工具箱尝试的路径 | 本机结果 |
|---|---|
| `/sys/class/devfreq/gpufreq/load`（标准 devfreq） | **不存在**（本平台无此节点） |
| `/sys/class/kgsl/kgsl-3d0/gpu_busy_percentage`（高通 Adreno 专用） | **连 `/sys/class/kgsl` 都不存在**（本机是麒麟 Mali） |

⇒ 两处都失败，工具箱回落到 `-1%`。

### 10.4 想看 GPU 负载时怎么做

```sh
# 实时 GPU 利用率（百分比，本平台唯一正确来源）
su -c 'cat /sys/class/devfreq/gpufreq/gpu_scene_aware/utilisation'
# 当前 GPU 频率 / 可选 governor
su -c 'cat /sys/class/devfreq/gpufreq/cur_freq'
su -c 'cat /sys/class/devfreq/gpufreq/available_governors'
```

### 10.5 其他已确认的"工具箱节点不适配"（同类问题）

* `/sys/block/sda/queue/scheduler` → **`No such file or directory`**（本机无 `sda` 块设备，
  存储是 `mmcblk0`）。读 eMMC 调度器要用 `/sys/block/mmcblk0/queue/scheduler`。

---

## 11. `enable_avc_log_spoofing` 专项（2026-10-02）

> ⚠️ **§11.1–§11.5 是第一版结论**（基于 Kotlin 源码推测，判断为“管理器不持久化”）。
> 当天下午用 **jadx 反编译 APK 字节码**后找到了**更根本的根因**：**管理器按内核报告的
> SUSFS 版本号去 APK 里找随包工具，找不到就让全部 SUSFS 命令一起失效** ——
> 见下面的 **§11.0**（权威结论）与 `PATCHES.md` §P。

### 11.0 ⭐⭐⭐ 真正根因：管理器按内核版本号找随包工具，对不上就整体失效

SukiSU Ultra 4.1.1 执行**任何** SUSFS 命令前，都会先从 APK `assets/` 释放一份 `ksu_susfs`
到 `/data/adb/ksu/bin/ksu_susfs`，**文件名按内核报告的 SUSFS 版本拼**：

```java
// C1188l（释放工具）
str    = m5063I();                              // "<libksud.so> susfs version" → "v2.3.0"
concat = "ksu_susfs_" + str.removePrefix("v");  // → "ksu_susfs_2.3.0"
open   = context.getAssets().open(concat);      // APK 里只有 ksu_susfs_2.0.0 ⇒ IOException
// catch → Log.e("SuSFSManager","Failed to copy binary") → return null
// C1189m（执行器）
if (path == null) return new C1185j0("", "SUSFS binary not found", false);  // 全部命令失败
```

**4 条实测证据**：

| # | 检查 | 结果 |
|---|---|---|
| ① | `ksud susfs version` | **v2.3.0** |
| ② | `unzip -l sukisu_ultra_4.1.1.apk` 找 `ksu_susfs` | 只有 **`assets/ksu_susfs_2.0.0`**（19192 B） |
| ③ | `ls -l /data/adb/ksu/bin/` | `ksu_susfs`=**09:23**（手动放的），`bootctl`/`busybox`/`ksud`=**12:15**（开机释放的） |
| ④ | `susfs_config.xml` | 只有 `auto_start_enabled`，**没有 `enable_avc_log_spoofing`** |

**修复（v31）**：`include/linux/susfs.h` 的 `SUSFS_VERSION` 改回 **`"v2.0.0"`**，重编重刷。
版本号在管理器里只用于「拼工具文件名 / 写备份 JSON / 状态页显示」三处，**不控制功能开关**。

⚠️ **手动往 `/data/adb/ksu/bin/` 放工具没用** —— 管理器每次都重新释放，释放失败返回 `null`，
不会回退用已有文件。

### 11.1 现象与结论（第一版结论，保留备查）

用户报告：SUSFS 页面里 **“AVC 日志欺骗”开关无法启用**。

**内核侧完全正常**：`ksu_susfs enable_avc_log_spoofing 1` → **`rc=0`**（两次实测均成功）。

**当时判断的管理器两处缺陷**（源码 `mgr_SuSFSManager.kt`，56306 B）：

| # | 位置 | 缺陷 |
|---|---|---|
| ① | `parseEnabledFeaturesFromOutput()` L866–875 | `featureMap` **只列了 8 项**，**缺 `CONFIG_KSU_SUSFS_AVC_LOG_SPOOFING`** ⇒ UI **永远无法显示它为"已启用"**，即使内核里已生效 |
| ② | `ModuleConfig.enableAvcLogSpoofing`（L167 定义 / L276 赋值） | **全文件只出现 2 次，从未被 `ScriptGenerator.generateAllScripts(config)` 消费** ⇒ 生成的模块脚本不含该命令；`hasAutoStartConfig()`（L174–184）也没算它 |

### 11.2 为什么后果严重：SUSFS 状态不持久化

SUSFS 的开关是**内核内存态**，**重启即丢**，必须每次开机重放。
管理器为**其他**配置生成 KSU 模块来重放，**唯独漏了 AVC 欺骗**。

设备侧证据：

* SharedPreferences（`/data/data/com.sukisu.ultra/shared_prefs/*.xml`）里**没有**
  `enable_avc_log_spoofing` 记录；
* `/data/adb/modules/` 只有 `.core` / `WorkSettingPro` / `zygisk_lsposed` / `zygisksu`，
  **无 SUSFS 模块**。

⚠️ 排除项：`isSusVersion159()` 前置检查**无问题** —— `compareVersions()` 用 `removePrefix("v")`
后 `2.3.0 > 1.5.9` ✅，不会误拦。

### 11.3 处置：补充持久化模块（已实施并验证）

管理器不会替我们重放，那就自己做一个最小模块：

```
/data/adb/modules/susfs_avc_spoof/
├── module.prop     470 B   （描述里写明管理器缺陷，便于日后回溯）
├── service.sh      1471 B  （等 sys.boot_completed=1 后 sleep 3 再执行，755）
├── ksu_susfs       19192 B （从 APK assets/ksu_susfs_2.0.0 释放，755）
└── run.log                  （每次执行追加时间戳 + rc）
```

`service.sh` 要点：

* 等 `sys.boot_completed=1`（最多 120 s）再 `sleep 3`，避开与管理器自身初始化抢时序；
* 工具优先用模块内自带的 `ksu_susfs`，回退 `/data/adb/ksu/bin/ksu_susfs`；
* 结果追加进 `run.log`，便于事后核对。

首次手动执行结果：

```
--- Fri Oct  2 11:37:24 CST 2026 boot_completed=1
rc=0
```

**下次重启后**核对 `cat /data/adb/modules/susfs_avc_spoof/run.log` 是否新增一行 `rc=0`
即可确认自动重放生效。删除整个目录即可撤销。

### 11.4 ⚠️ 端到端功能验证的已知障碍（诚实记录）

`enable_avc_log_spoofing` 只对 **`tsid == susfs_ksu_sid`** 的拒绝生效。本设备上
**不存在继承 `u:r:su:s0` 目标的文件标签**：

| 路径 | 实际标签 | 原因 |
|---|---|---|
| `/data/adb/*` | `adb_data_file` | type_transition |
| `/dev/*` | `device` | 固定标签 |
| `/mnt/*` | `tmpfs` | 固定标签 |
| `/cache/*` | `cache_file` | 固定标签 |
| `/data/local/tmp/*` | `shell_data_file` | type_transition |

⇒ 无法构造出 `tsid == susfs_ksu_sid` 的 avc 拒绝，因此**功能级验证暂不可做**，
目前只能验证到"命令返回 `rc=0`"。

补充：**内核不打印该命令的日志**（`dmesg | grep -i spoof` 无输出），所以连
"日志有记录"这条旁证也没有 —— 判定依据只有工具返回码 `rc=0`。这是环境限制，非缺陷。

### 11.5 直接证据：内核报了 9 项，管理器只认 8 项

```sh
su -c '/data/adb/ksu/bin/ksu_susfs show enabled_features'
```

输出（9 行，**含 AVC_LOG_SPOOFING**）：

```
CONFIG_KSU_SUSFS_SUS_PATH
CONFIG_KSU_SUSFS_SUS_MOUNT
CONFIG_KSU_SUSFS_SUS_KSTAT
CONFIG_KSU_SUSFS_SPOOF_UNAME
CONFIG_KSU_SUSFS_ENABLE_LOG
CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG
CONFIG_KSU_SUSFS_OPEN_REDIRECT
CONFIG_KSU_SUSFS_SUS_MAP
CONFIG_KSU_SUSFS_AVC_LOG_SPOOFING      ← 内核报了，管理器丢弃
```

而管理器 `parseEnabledFeaturesFromOutput()` 的 `featureMap` 只有 8 个键（**无
`CONFIG_KSU_SUSFS_AVC_LOG_SPOOFING`**）⇒ 这一行被直接忽略，UI 上永远显示不出"已启用"。
这与 §11.1 的缺陷①互为印证：**内核没问题，是管理器解析表漏了一项。**

---

## 12. ⭐⭐⭐ 救砖通道：fastboot 已打通（2026-10-02 实测，推翻旧结论）

> 旧结论写的是"Windows fastboot 不通（无 Android 驱动，需 HiSuite）"。
> **实测证明是错的 —— 只是缺驱动，装上就能用。**

### 12.1 为什么必须知道这个

2026-10-02 的 **v30 事故**（见 `PATCHES.md` §O）：v30 内核刷入后**卡在"BL 已解锁"界面**，
adbd 4 分钟未出现，**adb 通道完全不可用**。当时能救回设备的**唯一通道就是 fastboot**。

### 12.2 完整操作流程

**① 进入 fastboot**

```
关机 → 按住【音量下】不放 → 插入 USB 线
```

设备会枚举为：

| 字段 | 值 |
|---|---|
| 硬件 ID | `USB\VID_18D1&PID_D00D` |
| 设备名 | `HI3650`（Kirin 960 代号） |
| 序列号 | 手机序列号（如 `<设备序列号>`） |
| 初始状态 | `Error` / `CM_PROB_FAILED_INSTALL`（**缺驱动**） |

**② 装驱动（只需一次）**

⚠️ Google 官方 `usb_driver_r13-windows.zip` 里的 `android_winusb.inf`
**不含 `18D1:D00D`**（只有 `4E40`/`2C10`/`4EE0`/`9004`/`9006`/`4D00`），必须手动加一行：

```
%SingleBootLoaderInterface% = USB_Install, USB\VID_18D1&PID_D00D
```

`[Google.NTx86]` 和 `[Google.NTamd64]` **两个段都要加**。改好的 INF 在：
`C:/Users/<你的用户名>/Desktop/android_usb_driver_mod/usb_driver/android_winusb.inf`

然后在**设备管理器**里（`Win+R` → `devmgmt.msc`）：

```
找到带黄色感叹号的 HI3650
 → 右键 → 更新驱动程序
 → 浏览我的电脑以查找驱动程序
 → 让我从计算机上的可用驱动程序列表中选取
 → 从磁盘安装 → 选上面的 android_winusb.inf
 → 选 "Android Bootloader Interface" → 下一步
 → 若提示"无法验证发布者" → 始终安装
```

**③ 验证与刷写**

```sh
fastboot devices                       # → <设备序列号>   fastboot
fastboot flash kernel <kernel.img>     # → Sending 'kernel' OKAY / Writing 'kernel' OKAY
fastboot reboot
```

### 12.3 ⚠️ 几个必须知道的事实

* **Huawei fastboot 把 getvar 全锁了**：`getvar all` / `product` / `unlocked` /
  `partition-size:*` 全部 `FAILED (remote: 'Command not allowed')`。
  **只有 `max-download-size`（471859200）可用** ⇒ 查不了分区，但 `flash kernel` 正常工作。
* **eRecovery 不提供 adb / fastboot**：它只枚举成 `VID_12D1&PID_107E` 的
  **CD-ROM（`Linux File-CD Gadget`）+ USB 大容量存储**，而且**不给盘符**
  （`Get-Disk` 里看不到任何新磁盘）⇒ 拿不到里面的华为驱动盘。
* **本机没有管理员权限**：`net session` → "发生系统错误 5。拒绝访问"；
  且改版 INF 的 catalog 不匹配 ⇒ `pnputil` 不可用 ⇒ **装驱动必须人工在设备管理器点确认**。
* 本机**没装 HiSuite**（工具箱 bat 明确写着"请确认电脑安装好华为手机助手"，
  旧结论大概就是由此而来 —— 但那是**驱动来源**问题，不是 fastboot 本身不可用）。

### 12.4 应急恢复的优先级（下次卡死照这个顺序做）

1. **adb 还在** → 设备端脚本 dd 刷回备份（最快）。
2. **adb 没了** → 按住**音量上**进 **eRecovery** → 选"**关机**" → 按住**音量下**插 USB 进 **fastboot**
   → `fastboot flash kernel <上次可用的 img>` → `fastboot reboot`。
   （实测从卡死到恢复约 3 分钟。）
3. **都不行** → eRecovery 的"**下载最新版本并恢复**"（需 WiFi，会重刷官方固件，**可能清数据**，最后手段）。

### 12.5 判断"当前跑的是哪个内核"

各版本的 `CONFIG_LOCALVERSION` **完全相同**（都是 `4.9.148-<自定义后缀>`），
所以**不能只看 `uname -r`**。要看 `uname -a` 里的 **`#N` 与构建时间**：

```
Linux localhost 4.9.148-<自定义后缀> #28 SMP PREEMPT Fri Oct 2 02:35:44 UTC 2026 aarch64
                    ^^^ 版本号（v29 = #28）        ^^^^^^^^^^^^^^^^^^^ 构建时间
```
