# SUSFS ABI 逆向笔记（荣耀9 / SukiSU Ultra 4.1.1 / 内核 4.9）

> 本文记录内核里 SUSFS 兼容层**为什么长这样**。所有结论都有设备实测或反汇编证据，
> 不是推测。改动 `fs/susfs.c` / `include/linux/susfs.h` 前请先读完。
>
> 覆盖版本：**v26**（双布局兼容）、**v27**（补齐三项能力）、**v28/v29**（修 5 个缺陷）。
> 最新内核 `#28` = `4.9.148-<自定义后缀>`（本仓库默认 `4.9.148-SukiSU`）。

## 0. 一句话结论

SukiSU Ultra 4.1.1 的管理器**不**走 ksud，而是调用一个独立 CLI 工具
`/data/adb/ksu/bin/ksu_susfs`；该工具是 **SUSFS v2.0.0 线格式**。
内核必须同时接受 v2.3.0（ksud / 上游）与 v2.0.0（本机管理器）两套布局，
否则 `add_sus_path` / `add_open_redirect` / `add_sus_kstat` 在管理器里全部显示失败。

## 1. 版本真相：不是 v2.3.0，是 v2.0.0

| 证据 | 内容 |
|---|---|
| 管理器 APK `assets/` | 只有 `ksu_susfs_2.0.0`（19192 B，md5 `b9a0f2b46b98ea58c3643eb944ed4717`），没有 2.3.0 |
| `SuSFSManager.kt` | `const val MAX_SUSFS_VERSION = "2.0.0"` |
| 选版逻辑 | 用 `ksud susfs version` 的结果拼 `ksu_susfs_<ver>`；文件不存在就回退 `MAX_SUSFS_VERSION` |

内核报 `v2.3.0` → 工具找 `ksu_susfs_2.3.0` → 不存在 → **回退 `ksu_susfs_2.0.0`**。
所以内核报什么版本，实际发命令的都是 v2.0.0 布局。

> 顺带：`ksud` 4.1.1 的 `susfs` 子命令**只实现** status / version / features
> （`userspace/ksud/src/susfs.rs` 仅 78 行），其余命令一律由 CLI 工具处理。

## 2. 派发协议

```
reboot(0xDEADBEEF /*KSU_INSTALL_MAGIC1*/, 0xFAFAFAFA /*SUSFS_MAGIC*/,
       cmd /*w3*/, arg /*x4, 用户态结构体指针*/)
```

工具经 `syscall@plt`（x8=142）发出，反汇编里 15 个站点都是
`movz w1,#0xBEEF; movk w1,#0xDEAD` / `movz w2,#0xFAFA; movk w2,#0xFAFA`。

本内核无 kprobe（`CONFIG_KPROBES` 未设），派发点**只有一个**：

```
kernel/reboot.c  SYSCALL_DEFINE4(reboot) 内
    if (magic1 == 0xDEADBEEF) { ksu_handle_sys_reboot(...); return -EINVAL; }   ← ZCODE_KSU_REBOOT_HOOK
        └─ ksu_handle_sys_reboot()  [drivers/kernelsu/supercalls.c]
             └─ magic2 == 0xFAFAFAFA → ksu_handle_susfs_cmd(cmd, arg)
```

### ⭐⭐ 2.1 曾经的致命缺陷：两个派发点（v29 已修）

早期 `drivers/kernelsu/syscall_hook_manager.c` 的 `sys_enter` tracepoint 里
**也**有一条 `if (id == __NR_reboot) ksu_handle_sys_reboot(...)`，与 `reboot.c` 的直钩**重复**。

**后果**：同一条 SUSFS 命令**执行两遍**。

* `add_sus_path_loop` 会往 `LH_SUS_PATH_LOOP` 塞**两条**重复条目，
  此后每轮 `setresuid` 都做两倍工作；
* 所有命令的内核日志都是双份。

**判别方法（`delta` 判据）**：

```sh
B=$(su -c "dmesg | grep -c CMD_SUSFS_SHOW_VERSION")
su -c '/data/adb/ksu/bin/ksu_susfs show version'
A=$(su -c "dmesg | grep -c CMD_SUSFS_SHOW_VERSION")
# A - B 必须为 1。为 2 ⇒ 存在第二个派发点。
```

实测：v28 `delta = 2` → v29 删掉 tracepoint 分支后 `delta = 1`。

> 4.9 没有独立的 compat 入口，32/64 位进程都走同一个 `SYSCALL_DEFINE4(reboot)`，
> 所以**保留 `reboot.c` 那一处就够了**。

## 3. 命令号（反汇编解出，基址 `mov w19,#0x5571; movk w19,#0x5`）

| 命令 | 值 | v26 | v27+ |
|---|---|---|---|
| ADD_SUS_PATH | `0x55550` | ✅ 双布局 | ✅ |
| SET_ANDROID_DATA_ROOT_PATH | `0x55551` | 废弃 → 126 | 废弃 → 126 |
| SET_SDCARD_ROOT_PATH | `0x55552` | 废弃 → 126 | 废弃 → 126 |
| ADD_SUS_PATH_LOOP | `0x55553` | 未实现 → 126 | ✅ **已实现** |
| ADD_SUS_MOUNT | `0x55560` | 废弃 → 126 | 废弃 → 126 |
| ADD_SUS_KSTAT | `0x55570` | ✅ 双 err 槽 | ✅ |
| UPDATE_SUS_KSTAT | `0x55571` | ✅ 双 err 槽 | ✅ |
| ADD_SUS_KSTAT_STATICALLY | `0x55572` | ✅ 双 err 槽 | ✅ |
| SET_UNAME | `0x55590` | ✅ | ✅ |
| SET_CMDLINE_OR_BOOTCONFIG | `0x555b0` | ✅ | ✅ |
| ADD_OPEN_REDIRECT | `0x555c0` | ✅ 双布局 | ✅ |
| SHOW_VERSION | `0x555e1` | ✅ | ✅ |
| SHOW_ENABLED_FEATURES | `0x555e2` | ✅ | ✅ |
| SHOW_VARIANT | `0x555e3` | ✅ | ✅ |
| **ENABLE_AVC_LOG_SPOOFING** | `0x60010` | 未实现 → 126 | ✅ **已实现** |
| **ADD_SUS_MAP** | `0x60020` | 未实现 → 126 | ✅ **已实现** |

⚠️ 工具子命令写法：`show <version|enabled_features|variant>`。
**`show_version` 是无效写法**，会打印帮助文本。

## 4. ⭐ 工具的关键行为：`err` 哨兵

**工具在调用内核前，先把 `err` 槽预填成 `126`（`ERR_CMD_NOT_SUPPORTED`）；
调用后如果该值**没被改写**，就打印
`[-] CMD: '0x%x', SUSFS operation not supported, please enable it in kernel`
并返回 126。**

反汇编实证（`add_sus_kstat`，0x740c 起）：

```asm
mov  w8, #0x7e          ; 126
str  w8, [sp, #5120]    ; err 槽 = 126（结构体基址 sp+4752 ⇒ err 偏移 368）
...
bl   syscall@plt        ; reboot(0xdeadbeef, 0xfafafafa, 0x55570, sp+4752)
ldr  w0, [sp, #5120]
cmp  w0, #0x7e
b.ne ok
    printf("[-] CMD: '0x%x', SUSFS operation not supported, ...")
```

**推论**：内核只要把 `err` 写到工具期望的偏移，工具就认为成功。
写错偏移 → 内核日志明明 `ret: 0`，管理器却报「未启用」——这就是本轮踩到的坑。

## 5. 三个布局差异点

### 5.1 `st_susfs_sus_path`

| | v2.3.0 | v2.0.0 |
|---|---|---|
| 字段 | `char pathname[256]; u32 target_uid; int err;` | `u64 target_ino; char pathname[256]; u32 target_uid; int err;` |
| pathname | @0 | @**8** |
| err | @264 | @**268** |

**探测方法**：路径名必为绝对路径 ⇒ 看首字节。`base[0]=='/'` → v2.3.0；
`base[8]=='/'` → v2.0.0。见 `susfs_pathname_offset()`。

### 5.2 `st_susfs_open_redirect`

| | v2.3.0 | v2.0.0 |
|---|---|---|
| 字段 | `char target[256]; char redirected[256]; int uid_scheme; int err;` | `u64 target_ino; char target[256]; char redirected[256]; int err;` |
| target | @0 | @8 |
| redirected | @256 | @**264** |
| err | @516 | @**520** |

同样用首字节探测；`redirected_pathname` 恒在 `path_off + 256`。

### 5.3 `st_susfs_sus_kstat`（最隐蔽）

| | v2.3.0 | v2.0.0 |
|---|---|---|
| 字段 | 同下 + `int flags` | **没有 `flags`** |
| err | @**372** | @**368** |

其余字段（`is_statically`@0、`target_ino`@8、`target_pathname`@16、
`spoofed_ino`@272 … `spoofed_blksize`@360）**完全一致**，且载荷里没有任何
可用来判别版本的字段。

**处理方式：双写。** `flags` 本引擎从不读取，所以把 `err` 同时写 @368 与 @372：

```c
static void susfs_reply_sus_kstat_err(void __user *base, int err)
{
	if (copy_to_user(base + offsetof(struct st_susfs_sus_kstat, err), &err, sizeof(err)))
		return;
	if (copy_to_user(base + offsetof(struct st_susfs_sus_kstat_v200, err), &err, sizeof(err)))
		return;
}
```

安全性依据（已逐条核实，勿凭感觉改）：

1. 派发层用 `ksu_access_ok(arg, sizeof(struct st_susfs_sus_kstat))` = **376 B**
   校验过整个范围，两个槽都在这个窗口内，**不可能缺页**。
2. v2.0.0 工具的缓冲区是栈上的 372 B，写 @372 会越界 4 B。反汇编确认
   工具主函数栈帧 **8864 B**（`sub sp,sp,#0x2000` + `sub sp,sp,#0x2a0`），
   且全程序**没有任何指令引用 `sp+5124`** —— 那 4 B 是死区。

## 6. 其它命令的偏移（供核对，均已实测 ret: 0）

| 结构体 | err 偏移 | 依据 |
|---|---|---|
| `st_susfs_uname` | 132 | `release[65]+version[65]` 对齐后 = 132；工具 `str w8,[sp,#4884]`，基址 4752 |
| `st_susfs_log` | 4 | `{bool enabled; int err;}`；工具 `ldr w0,[sp,#4756]` |
| `st_susfs_spoof_cmdline_or_bootconfig` | 8192 | `SUSFS_FAKE_CMDLINE_OR_BOOTCONFIG_SIZE=8192`；工具 `calloc(1,8196)` + `str w8,[x0,#8192]` |
| `st_susfs_enabled_features` | 8192 | 同上模式 |

## 7. 设备实测矩阵（v26，内核 `#24`）

> v27 补齐三项后的完整验收（含 `delta` 判据、失败出列证据）见 §9 与 `HEALTH_CHECK.md` §9。
> 内核 `#28`（v29）实测：`status`=true / `version`=v2.3.0 / `features` **9 项**，
> `add_sus_path_loop` / `add_sus_map` / `enable_avc_log_spoofing` 均 `rc=0`。

工具逐条执行，`rc` 为工具返回值（0 = 成功）：

```
show version                              rc=0   → v2.3.0
show variant                              rc=0   → NON-GKI
enable_log 1                              rc=0
hide_sus_mnts_for_non_su_procs 1          rc=0
add_sus_path <f>                          rc=0   ← 修复前 ret -2
add_open_redirect <a> <b>                 rc=0   ← 修复前 ret -2
add_sus_kstat <f>                         rc=0   ← 修复前 rc=126
add_sus_kstat_statically <f> ...          rc=0   ← 修复前 rc=126
update_sus_kstat <f>                      rc=0
set_uname testrel testver                 rc=0
```

功能性验证（不是只看返回值）：

* **uname 欺骗**：`adb shell`（uid 2000）与 root 执行 `uname -r/-v` 均返回 `testrel` / `testver`。
* **open_redirect**：`cat secret.txt` 输出的是 `fake.txt` 的内容。
* **sus_path**：以 `su 10123 -c 'ls ...'`（非 root 用户 App uid）执行时，
  被标记的 `secret.txt` / `hidden2.txt` **从 readdir 消失**，
  `cat` 返回 `No such file or directory`。

### ⚠️ sus_path 只对 uid ≥ 10000 生效，这是设计而非缺陷

readdir / namei 钩子都有前置条件：

```c
current->susfs_task_state & TASK_STRUCT_NON_ROOT_USER_APP_PROC
```

该标志只在 `drivers/kernelsu/setuid_hook.c:ksu_handle_setresuid()` 里设置——
即 `setresuid()` 到的 uid **不在 allowlist 中**时。

* `adb shell`（uid 2000）不是 App uid，`__ksu_is_allow_uid(2000)` 为 false…
  **但仍要实测确认**：实测 `adb shell` 下文件可见，`su 10123` 下不可见。
  用 uid 2000 做验证会得出「sus_path 不工作」的错误结论。
* root（`su`）永不隐藏，符合预期。

## 8. 复现步骤（换设备/换管理器版本时）

```bash
# 1) 确认管理器版本与 SUSFS 目标版本
adb shell su -c 'dumpsys package com.sukisu.ultra | grep -E "versionName|lastUpdateTime"'
# 2) 看 APK 里到底带了哪个工具
unzip -l mgr.apk | grep ksu_susfs
# 3) 工具就位后逐条试，并同步看内核日志（别用 dmesg 统计，用 ksu 日志）
adb shell su -c '/data/adb/ksu/bin/ksu_susfs add_sus_kstat /some/file; echo rc=$?'
adb shell su -c 'cp /data/adb/ksu/log/dmesg.log /data/local/tmp/x.log'
```

判读口诀：**内核日志 `ret: 0` + 工具 `rc=126` ⇒ err 回写偏移不匹配**，
去反汇编里找该命令的 `str w8,[sp,#N]`，用 `N - 结构体基址` 算出真实偏移。

---

## 9. v27 补齐的三项能力

三项都**不含新的 err 偏移差异**（载荷里 `err` 的位置与 v2.3.0 结构体一致），
所以不需要像 §5 那样做双布局探测。真正的工作量在功能实现。

### 9.1 `ADD_SUS_PATH_LOOP`（`0x55553`）

载荷 = `struct st_susfs_sus_path`（与 `ADD_SUS_PATH` 同构，走 `susfs_pathname_offset()` 探测）。

语义：**把路径登记进 `LH_SUS_PATH_LOOP`，之后每次 `setresuid()` 后由 kworker 重新给
目标 inode 打 `INODE_STATE_SUS_PATH`**。用途是应对"文件被重新创建 / inode 变化"
（例如 `/system/etc/hosts` 被模块重新 bind mount 之后）。

v28 起的三条行为约定（都有实测证据）：

| 行为 | 说明 |
|---|---|
| **就地解析** | add 时立刻 `kern_path()` + 打标；失败立即 `err = -ENOENT` 返回给调用方，**不入队** |
| **去重** | 遍历 `LH_SUS_PATH_LOOP`，路径已存在则返回 `err = 0` + 日志 `already in LH_SUS_PATH_LOOP` |
| **失败出列** | 复打标失败累计 `fail_count`，达 `SUSFS_SUS_PATH_LOOP_MAX_RETRY`(3) 次后 `list_del` + `kfree` |

```c
/* include/linux/susfs_def.h */
#define SUSFS_SUS_PATH_LOOP_MAX_RETRY 3

/* include/linux/susfs.h —— struct st_susfs_sus_path_list 新增字段 */
u32 fail_count;
```

⚠️ 该结构体是**内核私有链表节点**，不是与用户态共享的 ABI 结构体，
所以加字段**不影响**双布局探测。

### 9.2 `ADD_SUS_MAP`（`0x60020`）

载荷 = `struct st_susfs_sus_map { char target_pathname[256]; int err; }`（err @256）。

实现 = inode 标记 + `fs/proc/task_mmu.c` 两处钩子（`show_smap()` / `pagemap_read()`）：

```c
/* show_smap()：show_map_vma() 之后、统计行之前 */
show_map_vma(m, vma, is_pid);          /* ← 头行（地址/权限/inode/路径）照常输出 */
if (vma->vm_file) {
        struct inode *inode = file_inode(vma->vm_file);
        if (inode->i_mapping &&
            unlikely((inode->i_state & INODE_STATE_SUS_MAP) &&
                     (current->susfs_task_state & TASK_STRUCT_NON_ROOT_USER_APP_PROC))) {
                seq_printf(m, "Size:           %8lu kB\n"
                              "KernelPageSize: %8lu kB\n"
                              "MMUPageSize:    %8lu kB\n",
                           (vma->vm_end - vma->vm_start) >> 10, 4UL, 4UL);
                goto bypass_orig_flow;   /* 跳过 Rss/Pss/Shared/Private/Swap/… */
        }
}
```

#### ⭐⭐ 验证判据（**极易搞错**，务必按此判断）

被隐藏的 vma **头行仍在**，`Size` 填的是**真实的 vma 大小**（不是 0！）。
真正被省略的是 `Rss` / `Pss` / `Shared_Clean` / `Shared_Dirty` / `Private_Clean` /
`Private_Dirty` / `Referenced` / `Anonymous` / `Swap` / `SwapPss` / `Locked` / `VmFlags` 等
**统计行**（每个 vma 块约 16 行）。

⇒ **正确判据 = 数 `^Rss:` / `^Pss:` 行数**，不是找 `Size: 0 kB`。

实测（内核 `#28`，标记 `/system/lib64/libc.so` 后以 uid 10123 读 `/proc/self/smaps`）：

| 观察者 | `^Size:` 行 | `^Rss:` 行 | 行数 |
|---|---|---|---|
| uid 10123（标记前） | 115 | **115** | 2345 |
| uid 10123（标记后） | 115（不变） | **112**（少 3） | 2297（少 48 = 3 × 16） |
| uid 0（root，标记后） | 115 | **115**（完整） | — |

少掉的 3 个 vma 正是 `cat` 映射 `libc.so` 的 `r-xp` / `r--p` / `rw-p` 三段。
`adb shell` 侧看到的头行与 `Size` 值完全不变 —— **只看 Size 会误判为"没生效"**。

```bash
# 正确验证姿势
adb shell "su -c '/data/adb/ksu/bin/ksu_susfs add_sus_map /system/lib64/libc.so'"
adb shell "su 10123 -c 'cat /proc/self/smaps'" > after.txt
adb shell "su -c     'cat /proc/self/smaps'" > root.txt
grep -c '^Rss:' after.txt    # 应比未标记时少（少掉的 = 该 inode 的 vma 数）
grep -c '^Rss:' root.txt     # root 不受影响，应与基线一致
```

inode 状态位（`include/linux/susfs_def.h`）：

```c
#define INODE_STATE_SUS_PATH    BIT(24)
#define INODE_STATE_SUS_MOUNT   BIT(25)
#define INODE_STATE_SUS_KSTAT   BIT(26)
#define INODE_STATE_OPEN_REDIRECT BIT(27)
#define INODE_STATE_SUS_MAP     BIT(28)   /* ← v27 新增 */
```

**冲突核查（必做）**：本内核 `inode->i_state` 实际只用到 **位 13（`I_WB_SWITCH`）**，
位 24–28 全空 ⇒ 无冲突。

⚠️ 与 `sus_path` 同样受 `TASK_STRUCT_NON_ROOT_USER_APP_PROC` 前置限制，
必须用 `su <uid≥10000>` 验证（§7 的坑）。
⚠️ `add_sus_map` **没有对应的 remove 命令**，标记只能靠重启清除（无害，只影响 smaps 统计显示）。

### 9.3 `ENABLE_AVC_LOG_SPOOFING`（`0x60010`）

载荷 = `struct st_susfs_avc_log_spoofing { bool enabled; int err; }`（err @4）。

实现 = `security/selinux/avc.c:avc_dump_query()`：

```c
rc = security_sid_to_context(tsid, &scontext, &scontext_len);
#ifdef CONFIG_KSU_SUSFS_AVC_LOG_SPOOFING
	if (unlikely(READ_ONCE(susfs_is_avc_log_spoofing_enabled) &&
			tsid == susfs_ksu_sid)) {
		if (rc) audit_log_format(ab, " tsid=%d", susfs_priv_app_sid);
		else { audit_log_format(ab, " tcontext=%s", SUSFS_PRIV_APP_SECCTX); kfree(scontext); }
		goto bypass_orig_flow;
	}
#endif
	if (rc) audit_log_format(ab, " tsid=%d", tsid);
	else { audit_log_format(ab, " tcontext=%s", scontext); kfree(scontext); }
#ifdef CONFIG_KSU_SUSFS_AVC_LOG_SPOOFING
bypass_orig_flow:
#endif
	BUG_ON(!tclass || tclass >= ARRAY_SIZE(secclass_map));
```

**安全性核查结论**：正常路径（未启用欺骗）与原生代码**逐字一致**，
`goto` 只在启用且命中时跳过，`scontext` 不会泄漏。

SID 由 `susfs_resolve_avc_sids()` 用 `security_secctx_to_secid()` 惰性解析：

```c
#define SUSFS_KSU_CONTEXT        "u:r:su:s0"
#define SUSFS_PRIV_APP_CONTEXT   "u:r:priv_app:s0"
#define SUSFS_PRIV_APP_SECCTX    "u:r:priv_app:s0:c512,c768"
```

> ⚠️ **端到端验证在本设备受阻**：需要构造一条 `tsid == susfs_ksu_sid` 的 SELinux 拒绝。
> 本设备上**不存在任何继承 `u:r:su:s0` 目标域的文件标签** ——
> `/data/adb/*` → `adb_data_file`、`/dev/*` → `device`、`/mnt/*` → `tmpfs`、
> `/cache/*` → `cache_file`、`/data/local/tmp/*` → `shell_data_file`，
> 都因 type_transition 而不继承 `su` 域。目前只验证到 `rc=0` + `enabled: 1/0`
> + 代码路径逐字核对。**这不是缺陷，是设备标签环境所限。**

---

## 10. ⭐ sus_path_loop 的固有作用域限制（易误判为缺陷）

`sus_path_loop` 的**复打标**跑在 **kworker** 里，而 kworker 的 SELinux 域是 **`kernel`**。
它对 `/data/local/tmp/*`（标签 `shell_data_file`）执行 `kern_path()` 会**被 SELinux 拒绝**，
并产生 avc denial。

⇒ 结论：**只把"内核域能 search 的路径"登记进 `sus_path_loop`**，
例如 `/system/etc/hosts`（`system_file`）。`shell_data_file` 类路径注定失败。

v28 之前的表现是"每次 setresuid 都失败重试 + `pr_err` 刷 console"；
v28 之后是"失败 3 次自动出列 + 只在第 1 次记一条 `pr_info`"，问题消解。

---

## 11. printk 级别（决定"日志里有、console 不刷屏"）

```sh
$ su -c 'cat /proc/sys/kernel/printk'
4	4	1	7
```

首字段 = `console_loglevel` = **4** ⇒

| 宏 | 级别 | 上 console？ |
|---|---|---|
| `pr_err` / `SUSFS_LOGE` | 3 | ✅ 会 |
| `pr_warn` | 4 | ✅ 会（`4 <= 4`） |
| `pr_info` / `SUSFS_LOGI` | 6 | ❌ 不会 |

所以想让某条信息"留在 `dmesg` 里但不刷控制台"，**必须用 `pr_info`**。
这正是 v28 把 `sus_path_loop` 失败日志从 `SUSFS_LOGE` 改成 `SUSFS_LOGI` 的依据。
