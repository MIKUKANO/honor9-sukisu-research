# 补丁清单与原理（PATCHES.md）

完整机器可读差异：`patches/sukisu_all_patches.diff`（git diff，相对盘古 master 2025-10 版）。
本文件按功能分组解释每处修改的原因。行号以交付时源码为准。

## A. SukiSU 超级调用通道（核心，"不支持"的根因）

SukiSU v4.1.1 的管理器通过 `reboot(0xDEADBEEF, ...)` 魔数调用内核超级调用，
官方实现是 **kprobe 挂 sys_reboot**；华为 4.9 内核 `CONFIG_KPROBES` 未启用且 kprobe
不可靠（社区公认），因此改为**源码级直钩**：
- `kernel/reboot.c`：SYSCALL_DEFINE4(reboot) 入口处增加
  `magic1 == 0xDEADBEEF` 分支 → 调用驱动 `ksu_handle_sys_reboot()` → 返回 -EINVAL
  （与 kprobe 路径语义一致：reboot 魔数不匹配原厂校验，真实 reboot 逻辑本就会返回 -EINVAL）。

## B. 管理器识别（第二个"不支持"因素）

管理器启动时内核 setuid 钩子比对"管理器 appid"来注入驱动 fd
（`anon_inode:[ksu_driver]`）。appid 正常由 ksud 守护进程扫描 /data/app 上报，
本机 ksud 尚未自启 → 鸡蛋问题。修复：

- `drivers/kernelsu/throne_tracker.c`：`ksu_throne_tracker_init()`（原为空实现）
  中预设 `ksu_set_manager_appid(10189)`（SukiSU 管理器的 uid/appid）。
- 若日后重装管理器导致 uid 变化，改此值重编；或在 SukiSU 管理器内重新触发。

## C. SELinux 强制 Permissive —— **v25 已摘除**（"工作中但获取 root 失败"的根因）

**历史背景（v19–v24）**：EMUI9/Android9 上 SukiSU 的 SELinux 处理依赖 5.2+ 的内核策略结构
（`sepolicy.c`/`rules.c` 当时被 `#if >= 5.2.0` 整体编成空桩），root 进程无法切换 SELinux 域。
为绕开这一点，在 `security/selinux/selinuxfs.c` 的 `sel_write_enforce()` 里插入了
`new_value = 0;`（`#ifdef CONFIG_KSU` 守护）→ **任何切 Enforcing 的写入都被静默改成 Permissive**。
这是盘古/Coconutat 系华为内核的标准做法。

**v25 摘除该补丁**：根因已由 v24 的 P2 修复消除（`sepolicy.c`/`rules.c` 移植到 4.9，
`su`/`ksu` 域在策略里被标记 permissive，`ksu_file_sid` 正常）。摘除后
`sel_write_enforce()` 与上游**逐字一致**。

### ⚠️ 一个反直觉的实测结论（2026-10-02 实机验证）

**cmdline 上的 `androidboot.selinux` 在本 ROM 上根本不生效。**

- **内核侧**：`selinux_enforcing` 定义在 `security/selinux/hooks.c:107`，**无初始化器（BSS = 0）**；
  只有 `enforcing=` 启动参数（`__setup("enforcing=", enforcing_setup)`）会赋值。
  `androidboot.selinux=xxx` **不是** `enforcing=`，内核根本不解析它。
- **用户态侧**：EMUI init 在 **15.9s** 调用 `security_setenforce(1)`。本 ROM
  `buildvariant=user` → `ALLOW_PERMISSIVE_SELINUX=false` → init 的 `IsEnforcing()` 恒为真
  → **无条件把 SELinux 置为 Enforcing**（与 cmdline 无关）。
- **结论**：v19–v24 期间系统之所以是 Permissive，**唯一原因就是那个补丁把 init 的调用吞掉了**。
  cmdline 写 `permissive` 还是 `enforcing`，对最终 SELinux 状态**没有任何影响**。
- **实证**（`/data/adb/ksu/log/dmesg.log`，v25 开机全程）：
  ```
  <5>[   15.862091] [pid:1,cpu6,init]audit: type=1404 audit(...:3): enforcing=1 old_enforcing=0
  ```
  整个开机**仅此一次** enforcing 变更，此后稳定 Enforcing，无任何回翻。

> **教训**：不要用 `ro.boot.selinux` / cmdline 推断实际 SELinux 模式 —— 必须看
> `/sys/fs/selinux/enforce`，并用 `dmesg | grep enforcing`（`type=1404` 审计记录）核对轨迹。
> 另一个廉价探针：ART 的 `Zygote : seccomp disabled by setenforce 0` 只在 **permissive** 时出现。

`androidboot.selinux` 仍写回 `enforcing`（与出厂 `kernel_stock.img` 一致），目的是让
`ro.boot.selinux` 属性正确、避免将来某个 ROM 组件按该属性做分支判断。

**管理器开关**：SukiSU 管理器（v4.1.1）有 `selinux_toggle`，底层就是调 `setenforce`。
补丁摘除前该开关**形同虚设**（写入被吞），现在**真正生效**。它是运行时下发、不落盘，
所以**每次重启后需重开一次**才能保持宽容模式 —— 该行为由 EMUI init
（15.9s 无条件 `security_setenforce(1)`）决定，**属 ROM 行为，内核侧无缺陷**。

## D. SukiSU 驱动 4.9 兼容（v4.1.1 官方仅保证 4.14+）

集中在 `drivers/kernelsu/ksu_compat_49.h`（Kbuild 以 `-include` 强制注入所有
驱动文件）+ 个别文件的条件编译：

| 符号/头 | 上游版本 | 处理 |
|---|---|---|
| TWA_RESUME | 5.14 枚举 | #define true（task_work_add 的 bool notify） |
| strncpy_from_user_nofault | 5.8 改名 | 映射 strncpy_from_user |
| __NR_clone3 | 5.3 | #define 435（4.9 无此调用，钩子永不匹配，无害） |
| ksys_close / ksys_unshare | 5.10 改名 | 映射 sys_close / sys_unshare |
| mmap_read_trylock 等 | 5.8 改名 | 映射 down_read_trylock(&(mm)->mmap_sem) |
| selinux_cred() | 5.2 LSM blob | #define 取 cred->security 强转 |
| ksu_seccomp_allow_cache | 5.10.2 特性 | 空实现桩 |
| MODULE_IMPORT_NS | 5.4 宏 | ksu.c <5.4 分支移除 |
| linux/sched/signal.h, sched/task.h, sched/task_stack.h | 4.11+ 拆分 | 替换 linux/sched.h |
| linux/compiler_types.h | 4.13 拆分 | 替换 linux/compiler.h |
| linux/pgtable.h | 5.8 拆分 | 替换 asm/pgtable.h |
| uapi/linux/mount.h | 5.11 拆分 | <5.11 用 linux/mount.h |
| p4d_t（util.c 页表遍历） | 4.12 五级页表 | <4.12 走 pgd→pud 直达 |
| seccomp_filter_release | 5.9 | app_profile.c <5.9 用 put_seccomp_filter(tsk) |
| allowlist.c task_work | 同 TWA | 直插 shim |

## E. 驱动功能降级 stub（root 不受影响，模块类功能受限）

| 文件 | 需要的内核 | 处理 | 影响 |
|---|---|---|---|
| pkg_observer.c | fsnotify inode API (5.2+) | <5.2 空 init/exit | 管理器包名自动识别不可用（appid 预设已覆盖） |
| file_wrapper.c | iopoll/__poll_t/fadvise/remap_file_range (5.1+) | <5.1 install 返回 -EOPNOTSUPP | 管理器的内核文件包装特性不可用 |
| ~~selinux/sepolicy.c~~ | ~~5.2+ filename_trans 结构~~ | **v24 已移植到 4.9**（见 K.6） | ~~内核态策略注入不可用~~ → 现已可用 |
| ~~selinux/rules.c~~ | ~~同上~~ | **v24 已移植到 4.9**（见 K.6） | ~~同上~~ → 现已可用 |
| kpm/ | 需要 4.19 set_memory.h | CONFIG_KPM=n 不编译 | KPM 不启用 |

## F. 华为加固项关闭（反 root 机制，defconfig 层）

Pangu defconfig 已关闭 DM_VERITY/AVB/HW_ROOT_SCAN/HISI_SELINUX_EBITMAP_RO/
HISI_RO_LSM_HOOKS 等；本项目额外关闭：

- `CONFIG_HUAWEI_HIDESYMS=n`（符号隐藏，干扰 kallsyms 完整性）
- 运行时验证：/proc/config.gz 中上述项均为未设置。

## G. 编译系统兼容（gcc 10.3 × 4.9 旧树）

- 顶层 Makefile：注释 `-Werror=incompatible-pointer-types`、
  `-Werror=implicit-int`、`-Werror=strict-prototypes`、
  `-Werror-implicit-function-declaration`（旧式横线写法）；
  KCFLAGS 合并行后追加 `KBUILD_CFLAGS += -fcommon -Wno-error`（gcc10 默认 -fno-common）；
- 全树 37 处子目录 Makefile/Kbuild 的 `EXTRA_CFLAGS/subdir-ccflags-y += -Werror` 剥离
  （drivers/connectivity、drivers/hisi、sound、drivers/cfi 等）；
- `kernel/sched/cpufreq_blu_schedutil.c`：sugov_exit/stop/limits 三函数
  int→void（gcc10 严格检查，回调返回值本被忽略）；
- 驱动目录 `ccflags-y += -std=gnu11`（SukiSU 代码用 C99 for 内声明，4.9 树是 gnu89）。

## H. 标识与版本

- `Makefile`：`export KBUILD_BUILD_USER/HOST`（/proc/version 显示 MIKUKANO@ATRI）；
- `arch/arm64/configs/Pangu_SukiSU_defconfig`：`CONFIG_LOCALVERSION="-非酋&大肥鱼自制max版"`
  （uname → `4.9.148-非酋&大肥鱼自制max版`）；
  ⚠️ `CONFIG_LOCALVERSION` **不带前导 `-`**，由 kbuild 自动补；
  值里含 `&` ⇒ **必须**同时修 `Makefile` 的 `filechk_utsrelease.h`（见 §M.2）；
- `drivers/kernelsu/Kbuild`：`KSU_VERSION := 40496`、
  `KSU_VERSION_FULL := v4.1.1-非酋自制版`（管理器显示）。
  版本号公式 = 40000 + 提交数 - 2815，v4.1.1 对应 40496（与官方管理器 versionCode 一致）。
- SUSFS 对外版本号保持 **`v2.3.0`**（管理器据此拼工具名，见 `SUSFS_ABI_NOTES.md` §1）。

## I. fs/namespace.c backport

- `path_umount()`：从 5.9 backport（can_umount + do_umount 封装，KernelSU 官方移植写法），
  供内核 umount 功能使用；
- `zcode_path_mount_change_type()`：导出 do_change_type 包装，供 su_mount_ns 的
  MS_PRIVATE|MS_REC 调用（5.9 前无 path_mount）。

## J. 其它

- 全树 Makefile 剥离 -Werror 造成的 arch/* 无关改动包含在 diff 中，无害，
  仅影响非 arm64 架构目录（不参与本编译）。

## K. ksud 集成修复（2026-10-02，独立补丁 `ksud_integration_fix.patch`）

> 完整分析见 `FIX_KSUD_INTEGRATION.md`。此处只列改动点。

修复 **root 授权重启丢失** 与 **模块重启不生效**。上游 SukiSU 的 ksud 集成
（`ksud.c` 的 `ksu_ksud_init()`）全部挂在 **kprobe** 上，而本内核
`CONFIG_KPROBES=n`，`register_kprobe()` 恒返回 `-ENOSYS`
（dmesg 实证：`KernelSU: reboot kprobe failed: -38`），4 个钩子从未生效；
且 `arch.h` 的符号名用的是 4.17+ 的 `__arm64_sys_*`，4.9 实际为 `SyS_*`，
即便打开 KPROBES 也会 `-ENOENT`。

| 文件 | 改动 | 说明 |
|---|---|---|
| `ksu_compat_49.h` | +`ksu_kernel_read()` / `ksu_kernel_write()` | 4.9 的 `kernel_read/write` 是**旧式签名**（`loff_t` 按值 / `(file,loff_t,char*,unsigned long)`），驱动按 5.x 传 `loff_t*` 会被当成 offset 数值 → 普通文件 `rw_verify_area()` 返回 `-EINVAL` → allowlist 写盘失败 |
| `ksu_compat_49.h` | +`copy_{from,to}_user_nofault` 映射 | 5.8+ API，4.9 无 → 原为隐式声明（映射到 `probe_kernel_{read,write}`） |
| `allowlist.c` `apk_sign.c` `throne_tracker.c` | 21 处调用改走适配层 | 纯机械替换 |
| `ksud.c` | `is_init_rc()` 同时接受 `/init.rc` | 上游只认 Android 10+ 的 `/system/etc/init/hw/init.rc`；Android 9 真实路径是 `/init.rc`（实测 36412B）→ 否则 `KERNEL_SU_RC` 永不注入 |
| `ksud.c` / `ksud.h` | `ksu_handle_sys_read()` 去掉 `static` | 供 tracepoint 调用 |
| `ksud.c` / `ksud.h` | 新增 `ksu_handle_execve_ksud()` | 把原 `sys_execve_handler_pre` 的合成 `struct filename` 逻辑搬到 tracepoint 可调用的入口 |
| `syscall_hook_manager.c` | `check_syscall_fastpath()` +`__NR_read` | 新增 read 分支（仅 `comm=="init"`，廉价过滤） |
| `syscall_hook_manager.c` | `__NR_execve` 分支追加 `ksu_handle_execve_ksud()` | 恢复 zygote / second_stage 检测 → 触发 `on_post_fs_data()` |
| `supercalls.c` | `list_try_umount()` 加上限 + `__GFP_NOWARN` + `vzalloc` 回退（**v23**） | 见 K.5.1 |

**设计取舍**：不走"打开 `CONFIG_KPROBES`"路线，而是复用本项目**已在设备上验证可用**的
syscall tracepoint（`register_trace_sys_enter`，`CONFIG_FTRACE_SYSCALLS=y`，
证据：dmesg 中的 `handle_setresuid` 与 `hook_manager: unmark ... exec ...`）。
好处：不动 defconfig → **不触发全量重编**，增量编译数分钟完成；
且不与 kprobe 路径重复处理 execve。

**v19 时未迁移**（当时判断为"用不上"）：`sys_fstat_kp`（以为 Android 9 的 init
用循环 `read()`、无需修正 `st_size`）、`input_event_kp`（当时误以为本机音量键物理损坏）。
**v24 两者都已补上**，且发现"音量键物理损坏"的前提是错的（见 K.6）。

### K.2 第二轮（v20）—— sys_enter tracepoint 原子上下文修复

第一轮把 ksud 钩子迁到 tracepoint 后，新增的 `ksu_handle_execve_ksud()` 直接调
`strncpy_from_user_nofault()` 读 execve 路径。但 `trace_sys_enter()` 外层持有
`rcu_read_lock_sched()`，**钩子运行在原子上下文**（`preempt_count() != 0`），
原子上下文禁止页错误 → 路径字符串页面未驻留时直接 `-EFAULT`。

v19 实测日志刷屏 **1010 条** `Access filename failed for execve_handler_pre`。
更严重的是上游既有的 `ksu_handle_init_mark_tracker()` 有同样问题且**失败静默**：
它负责识别 `init` 执行 `/data/adb/ksud` 并提权，一旦读不到路径，
ksud 拿不到 root → `post-fs-data` 失败 → **模块又变回"重启不生效"**（偶发）。

上游 `sucompat.c:ksu_handle_execve_sucompat()` 早有对策，新增的两个函数漏抄了：

```c
if (ret < 0 && preempt_count()) {
    /* This is crazy, but we know what we are doing:
     * Temporarily exit atomic context to handle page faults, then restore it */
    preempt_enable_no_resched_notrace();
    ret = strncpy_from_user(path, fn, sizeof(path));
    preempt_disable_notrace();
}
```

| 文件 | 改动 | 说明 |
|---|---|---|
| `ksud.c` | `ksu_handle_execve_ksud()` +preempt 逃生；`pr_err` → `pr_warn` | 消除报错刷屏，恢复 zygote / second_stage 识别的可靠性 |
| `ksud.c` | +`#include <linux/preempt.h>` | 显式引入 |
| `syscall_hook_manager.c` | `ksu_handle_init_mark_tracker()` +preempt 逃生 | **关键**：消除 ksud 提权偶发静默失败（模块链路的定时炸弹） |
| `syscall_hook_manager.c` | +`#include <linux/preempt.h>` | 显式引入 |
| `sucompat.c` | `pr_info("Access filename failed, try rescue..")` → `pr_debug` | 降噪（该分支在 v20 中几乎不再触发） |

**实测效果**：`Access filename failed` 1010 → **0**，`try rescue` 4 → **0**，
而 `read init.rc` / `on_post_fs_data` / `exec zygote` / `post-fs-data triggered`
四个功能标记**一个不少**。模块的 `service.sh` 每次开机都执行；
LSPosed 的 zygisk companion 由"仅 64 位"变为 **32/64 位均注入**。

**风险提示**：逃生逻辑在 tracepoint 回调里短暂打开抢占，属上游长期使用的手法
（注释原文 "This is crazy, but we know what we are doing"），本项目与上游对齐。

### K.3 第三轮（v21）—— 补前置过滤

修掉逃生逻辑后，报错**换了名字**继续出现：`Access filename when execve failed: -14`，
v20 实测 **1002 条/开机**。原因是 `ksu_handle_execve_ksud()` **没有任何前置门**，
对全系统**每一次** execve 都尝试读用户态路径。

> 插曲：该 `pr_warn` 文案当时写成了与 `sucompat.c` **一字不差**的
> `"Access filename when execve failed: %ld"`，一度被误读为 sucompat 在报错。
> 后来靠"失败进程全是 uid ≥ 1000 的系统 App"+"`sys_execve su found` 全开机仅 1 次"
> 才定位到是自家函数。

| 文件 | 改动 | 说明 |
|---|---|---|
| `ksud.c` | `ksu_handle_execve_ksud()` 加前置过滤 | 只处理 init / root 进程，跳过其余 |

**实测**：报错 1002 → **965**，**但没清干净**（原因见 K.4）。

### K.4 第四轮（v22）—— 收紧过滤条件（`uid != 0` 是错的）

v21 的门写成：

```c
if (unlikely(current->pid != 1 && current_uid().val != 0 &&
             strcmp(current->comm, "init")))
    return 0;
```

`uid != 0` 这一条**把 zygote 系进程也放行了** —— Android 的 `zygote` / `zygote64`
本身就是 **uid 0、comm 为 `main`** 的进程（设备实证：`ps` 显示
`561 zygote64` / `563 zygote`，uid 均为 root）。它们运行期的每一次 execve
都通过门 → 读路径 → 报错，即 v21 残余的那 965 条。

**v22 修法**：去掉 `uid != 0`，只留精确条件。

```c
if (unlikely(current->pid != 1 && strcmp(current->comm, "init")))
    return 0;
```

- `pid == 1` → init 本身（覆盖 Android 10+ 的 `second_stage`）
- `comm == "init"` → init fork 出的子进程，execve **之前** comm 仍继承 `"init"`

| 文件 | 改动 | 说明 |
|---|---|---|
| `ksud.c` | 前置过滤收紧为 `pid==1 \|\| comm=="init"` | 噪声 965 → **0** |

**实测**：`Access filename when execve failed` **965 → 0**，四个功能标记一个不少。

> **教训**：`uid == 0` 不等价于"init 或其子进程" —— **Android 的 zygote 系全是 uid 0**。
> 能用 `pid` + `comm` 精确定位时，不要退化成 uid 判断。

**教训（写进 DEVICE_NOTES.md 第 7 条）**：任何在 `sys_enter` tracepoint 里
读用户态内存的新代码，都必须带这段逃生逻辑。

### K.5 第五轮（v23）—— 体检后清掉两处残余缺陷

v22 之后功能已全绿，于是做了一轮**全面体检**（`/data/adb/ksu/log/dmesg.log` 全量扫描），
发现两处**不影响功能、但污染日志**的缺陷。两处都不是 v19–v22 引入的，
而是**上游代码原本就有的**。

#### K.5.1 `supercalls.c` — `list_try_umount()` 缺分配上限

```c
output_size = cmd.buf_size ? cmd.buf_size : 4096;
output_buf = kzalloc(output_size, GFP_KERNEL);   // ① 无上限  ② 无 __GFP_NOWARN
...
kfree(output_buf);                               // ③ 无 vzalloc 回退路径
```

内核 `CONFIG_FORCE_MAX_ZONEORDER=11` → **order ≥ 11（≥8MB）的连续分配会 WARN**
并打印整条栈。调用方（管理器 App）传大值时即触发，每次开机 1 条 WARNING + 上百行栈转储。
`ksud umount list` 自己只传 4096，不是触发者，所以手动复现不出来。

| 文件 | 改动 | 说明 |
|---|---|---|
| `supercalls.c` | `#include <linux/vmalloc.h>` | 用 `vzalloc`/`vfree` 需要 |
| `supercalls.c` | `output_size` 夹紧到 2MB 上限 | **夹紧而非拒绝** —— 拒绝会打断管理器 App 的列表读取 |
| `supercalls.c` | `kzalloc(..., GFP_KERNEL \| __GFP_NOWARN)` + `vzalloc` 回退 | 大 order 分配失败不再刷日志；非连续回退绕开 order 限制 |
| `supercalls.c` | `kfree` → `using_vmalloc ? vfree : kfree` | 与分配路径配套 |

> ⚠️ **不要照抄上游 `kernel/supercall/dispatch.c` 的新版实现**：它把 `output_size`
> 重算成 `1024 + mount_count*200`，却仍 `copy_to_user(cmd.arg, output_buf, offset)` ——
> 挂载点多于用户缓冲大小时会**溢出用户缓冲区**。本项目保留"以 `cmd.buf_size` 为准"的语义，
> 只加上限；因为回写只拷 `offset` 字节且 `offset <= output_size <= cmd.buf_size`，不会溢出。

**实测**：`list_try_umount` 相关日志 **1 → 0**，`page_alloc` WARNING **1 → 0**；
`ksud umount list / add / remove` 功能不变（add 后能列出、remove 能删、全程无 WARNING）。

#### K.5.2 `ksud.c` — `stop_init_rc_hook()` 缺一次性门

每次开机 **37 条**完全相同的 `unregister init_rc_hook kprobe: 1!`。

原设计靠"kprobe 一注销钩子就不再被调用"来保证只执行一次，但本机
`CONFIG_KPROBES=n`（K.1），实际驱动的是**常驻 syscall tracepoint**，
注销 kprobe 对它毫无影响。init 分块循环读 init.rc（37 次 `read_iter`）→ 37 条日志；
且 `schedule_work()` 在 work 跑完后会**重新入队**，等于把 `unregister_kprobe` 反复执行 37 次。

| 文件 | 改动 | 说明 |
|---|---|---|
| `ksud.c` | `stop_init_rc_hook()` 加 `static bool init_rc_hook_stopped` 一次性门 | 照抄同文件 `stop_input_hook()` 已有的写法（原来只有它漏了） |

```c
static void stop_init_rc_hook()
{
    static bool init_rc_hook_stopped = false;
    if (init_rc_hook_stopped) {
        return;
    }
    init_rc_hook_stopped = true;
    bool ret = schedule_work(&stop_init_rc_hook_work);
    pr_info("unregister init_rc_hook kprobe: %d!\n", ret);
}
```

**实测**：`unregister init_rc_hook` **37 → 1**。

**v23 补丁规模**：+271 / -38，9 个文件。
镜像 `kernel_sukisu_v23_p1p3_fix.img`（15,157,248 B，md5 `e4385b64f197f3da8bc7d69c1723d52d`，
sha256 `519ea860…85f2`），已刷入设备并验证。

### K.6 第六轮（v24）—— SELinux 规则引擎移植到 4.9 + P4 直钩 + 警告清零

v23 之后功能全绿，但"全面体检"又挖出三类**没修干净**的问题：SELinux 规则其实
**从未加载过**（P2）、fstat 与 input_event 两个钩子**没有替代实现**（P4）、
以及 6 条既有编译警告。v24 一并清掉。

#### K.6.1 P2 —— 双层根因（这是本轮最重的一块）

**第一层：`sepolicy.c` / `rules.c` 在 4.9 上被整体编译成空桩**

```c
#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 2, 0)
    ... 整个内核态策略改写引擎 ...
#else
    /* 空桩：所有函数 return false / -EOPNOTSUPP */
#endif
```

守卫写的是 `5, 2, 0`，本机是 `4.9.148` → **引擎是空的**。改成 `4, 9, 0`，
并移植 5 处 ABI 差异：

| 差异点 | 5.2+ | 4.9（本机） | 处理 |
|---|---|---|---|
| 策略对象 | `selinux_state.policy->policydb` | 全局 `struct policydb policydb` | `get_policydb()` 加版本分支 |
| 类型属性图 | `policydb.type_attr_map_array` | `policydb.type_attr_map`（**同一对象**，仅名字不同） | `ksu_type_attr_map(db)` 宏 |
| `ebitmap_init()` | 1 参 | **2 参**（华为魔改：多 `protectable`） | `ksu_ebitmap_init(e)` → `ebitmap_init(e, HISI_SELINUX_EBITMAP_RO)` |
| `struct filename_trans` | 无 stype；datum 带 stypes 位图 + next 链 | **含 stype**；datum 只有 `otype`；`hashtab_insert()` 是 **3 参** | `add_filename_trans()` 整体加 `#if >=5.2 / #else` |
| `kvmalloc()` | 4.12+ | **无**（只有 `kvfree()`） | `ksu_kvrealloc_compat()` 用 `kzalloc` + `vzalloc` 回退 |

另：4.9 的 `filename_trans` 查询被 `policydb.filename_trans_ttypes` 位图**门控**
（`services.c:filename_compute_type()` 先查位图、再查哈希表），所以新增规则必须
同时 `ebitmap_set_bit(&db->filename_trans_ttypes, tgt->value, 1)`，否则哈希表里
有记录也永远查不到。

> 顺带查清：`CONFIG_HISI_PMALLOC` **未设** → `include/linux/pmalloc.h` 的 `#else`
> 降级分支把 `pmalloc→kmalloc`、`pfree→kfree`。所以 `type_attr_map` /
> `type_val_to_struct` / `sym_val_to_name` 都是普通 kmalloc 分配，
> 上游的 `ksu_kvrealloc()` + `kvfree()` 语义在 4.9 上**本来就是对的**。

**第二层：`apply_kernelsu_rules()` 在 Android 9 上从不被调用**

三连调用（`apply_kernelsu_rules()` + `cache_sid()` + `setup_ksu_cred()`）
只出现在 `ksu_handle_execveat_ksud()` 的 `/system/bin/init` + `second_stage` 分支
（源码注释写明 "This applies to versions Android 10+"）。Android 9 **既没有
`/system/bin/init` 也没有 `second_stage` 参数** → 三连从未执行，后果：

- `apply_kernelsu_rules()` 没跑 → 一条 KSU 规则都没加载 → su 域刷出 **446 条** `avc: denied`
- `cache_sid()` 没跑 → `ksu_file_sid == 0` → `KSU_IOCTL_GET_WRAPPER_FD` 恒返回 `-EINVAL`
- `setup_ksu_cred()` 没跑 → `ksu_cred` 未切到 `u:r:su:s0`

**修法**：新增幂等 workqueue `ksu_apply_selinux_rules_async()`（`ksud.c`），两个时机调度：

1. **主路径** —— `ksu_handle_sys_read()` 里 init 首次读 `/init.rc` 那一刻（本机 **16.02s**，
   而 SELinux 策略 **15.86s** 已加载完成）
2. **兜底** —— `on_post_fs_data()` 里再调一次（带 `done` 门，幂等）

**为什么必须走 workqueue**：这三个函数里有 `mutex_lock()`，而 `ksu_handle_sys_read()`
跑在 `sys_enter` tracepoint 的**原子上下文**（`preempt_count() != 0`）→ 直接调会
`scheduling while atomic`。

**时序余量**：规则应用 **16.05s** → init 执行 ksud **19.92s**，**3.87s**。
这正是"将来能安全切回 Enforcing"所必需的最早可用时机（Enforcing 下若规则没加载，
`exec u:r:su:s0 ... ksud` 会被直接拒掉 → 模块系统瘫痪）。

**实测**：

| 指标 | v23 | v24 |
|---|---|---|
| avc denied（原始行数） | 609 | **301** |
| 其中 su 域 | **446** | **0** |
| 去重后唯一 denial | 161 | **120** |
| `Cached ksu_file SID` | （无） | **302** |
| `ksu: selinux rules applied` | （无） | **出现** @16.05s（`kworker/7:2`） |

`su -c 'id'` 现在返回 `uid=0(root) gid=0(root) groups=0(root) context=u:r:su:s0`。
剩余 301 条全部来自华为固件自身域（`vendor_init` / `untrusted_app` / `platform_app` /
`init` / `system_server` …），`grep -i "ksu\|u:r:su\|adb_data"` 在 v24 日志中**零匹配**。

#### K.6.2 P4a —— fstat 钩子改 `fs/stat.c` 源码级直钩

上游用 `kretprobe` 挂 `__arm64_sys_newfstat` 修正 `/init.rc` 的 `st_size`。两条路都不通：
本内核 `CONFIG_KPROBES=n`；且 **arm64 上根本没有 `__arm64_sys_newfstat` 这个符号**
（那是 x86 的命名）。

改为在 `vfs_fstat()` 里直钩（照 `kernel/reboot.c` 的 `ZCODE_KSU_*` 模式）：

```c
error = vfs_getattr(&f.file->f_path, stat);
#ifdef CONFIG_KSU
    /* ZCODE_KSU_INIT_RC_STAT_HOOK */
    if (!error) {
        extern void ksu_fixup_init_rc_stat(struct file *fp, struct kstat *stat);
        ksu_fixup_init_rc_stat(f.file, stat);
    }
#endif
```

`ksu_fixup_init_rc_stat()` 内部复用 `is_init_rc()`（只认 `comm=="init"` **且** 路径为
`/init.rc` 或 `/system/etc/init/hw/init.rc`），命中才 `stat->size += ksu_rc_len`。

> 注：Android 9 的 init 用 `read()` 循环读 EOF、**不依赖** `st_size`（实测注入完整：
> `append 351` + `append done`），所以本钩子在 Android 9 上是**休眠但正确**的；
> Android 10+ 的 init 会用 `fstat` 预分配缓冲区，那时它是必需的。补它是为机制完整性。

#### K.6.3 P4b —— input_event 钩子改 `drivers/input/input.c` 直钩

上游 `register_kprobe(&input_event_kp)` 恒 `-38`；4.9 也**没有 input 子系统 tracepoint**
（`include/trace/events/` 下无 `input.h`）→ 只能源码级直钩。

```c
if (is_event_supported(type, dev->evbit, EV_MAX)) {
#ifdef CONFIG_KSU
    /* ZCODE_KSU_INPUT_HOOK */
    extern bool ksu_input_hook_active;
    extern int ksu_handle_input_handle_event(unsigned int *type,
                                             unsigned int *code, int *value);
    if (ksu_input_hook_active)
        ksu_handle_input_handle_event(&type, &code, &value);
#endif
    spin_lock_irqsave(&dev->event_lock, flags);
    input_handle_event(dev, type, code, value);
    spin_unlock_irqrestore(&dev->event_lock, flags);
}
```

**钩子必须在 `spin_lock_irqsave` 之外**：`ksu_handle_input_handle_event()` 里有
`pr_info()`，且该函数在**输入热路径**上，持 irq-disabled 自旋锁跨过它不合适。

**停止机制**：上游靠"注销 kprobe"；本机改为 `ksu_input_hook_active` 开关
（`stop_input_hook()` 置 false，由 `on_post_fs_data()` 调用）。调用点先读标志，
false 时**直接跳过函数体** → 等价于注销，且热路径零开销。

**同时纠正一个错误前提**：项目此前记录"音量键物理损坏"。实测**是好的** ——
`/dev/input/event1` 是 `hisi_gpio_key`，注册了 `KEY_VOLUMEDOWN`+`KEY_VOLUMEUP`；
按音量下使 `volume_music_speaker` 从 8 → 0，按音量上 0 → 8；`sendevent` 注入同样生效。

**静态验证**（`out/System.map` + `objdump`）：

```
T ksu_fixup_init_rc_stat          T ksu_handle_input_handle_event
T ksu_apply_selinux_rules_async   D ksu_input_hook_active
input.o: 2020  adrp x0, <ksu_input_hook_active>   ← 读开关
         2084  bl   <ksu_handle_input_handle_event>  ← 调用
stat.o:   7d4  bl   <ksu_fixup_init_rc_stat>
```

#### K.6.4 6 条既有编译警告清零

| 文件 | 警告 | 修法 |
|---|---|---|
| `selinux/selinux.c` | `security_secctx_to_secid` / `security_secid_to_secctx` / `security_release_secctx` 隐式声明（**3 条**） | 补 `#include <linux/security.h>`（4.9 的头文件链不会自动带入） |
| `manual_su.c` | `get_random_bytes` 隐式声明 | 补 `#include <linux/random.h>` |
| `sucompat.c` | `strncpy_from_user_nofault` 重定义 | `#undef` 后再 `#define`（`ksu_compat_49.h` 以 `-include` 先行定义） |
| `su_mount_ns.c` | `zcode_path_mount_change_type` 隐式声明 | 补显式 `extern` 声明（定义在 `fs/namespace.c:3596`） |

6 条都是 4.9 上**既有**的（v23 同样存在，非本轮引入），且实测签名匹配、返回类型无害；
清零是为"最完美"以及将来 `-Werror` 化的余量。**实测 `CC_ERRORS=0 CC_WARNS=0`。**

#### K.6.5 v24 交付物

- `patches/v24_fixes.patch` —— 5 文件（`ksud.c` / `ksud.h` / `sucompat.c` /
  `fs/stat.c` / `drivers/input/input.c`），基线 = v23 状态 / 原始内核树（`git HEAD`），
  已验证 `APPLY_CHECK_OK` + `BYTE_IDENTICAL_OK`
- `patches/v24_sources/` —— 10 个改动文件的**完整 v24 源码**。其中
  `selinux/{sepolicy,rules,selinux}.c` 与 `manual_su.c` / `su_mount_ns.c` 的
  v23 基线无法从本工作区逐字节重建，故直接给全文（含 `drivers/kernelsu/` 与 `fs/`、`drivers/input/` 路径结构）

镜像 `kernel_sukisu_v24_hwfix.img`（15,161,344 B，md5 `367452e90a48d27264a4155ac58df0bb`，
sha256 `7f58dae08ecc4712cc85c11244cb1ca9061829b18d57e5a9656f4b1028fd06be`），
已刷入设备并验证。内核标识 `#18 SMP PREEMPT Thu Oct 1 19:04:05 UTC 2026`。

**回归确认**（v24 未破坏 v23 的修复）：`unregister init_rc_hook` 仍 **1** 次、
`list_try_umount` 告警仍 **0** 条、WARNING 仍 **1** 条（华为 `internal_create_group`，v23/v24 完全相同）、
四个功能标记（`read init.rc` / `on_post_fs_data` / `exec zygote` / `post-fs-data triggered`）一个不少、
`.allowlist` 1560 B 非空、`zygisk_lsposed` 模块正常挂载。

### K.7 第七轮（v25）—— 切回 SELinux Enforcing

v24 之后唯一剩下的开放项：把系统从 Permissive 切回 **Enforcing**（与出厂一致）。

**改动量极小**：源码只删 6 行（C 节那个 `ZCODE_FORCE_PERMISSIVE` 补丁），
cmdline 把 `androidboot.selinux` 由 `permissive` 改回 `enforcing`。

| 文件 | 改动 |
|---|---|
| `security/selinux/selinuxfs.c` | 删除 `sel_write_enforce()` 内 `#ifdef CONFIG_KSU / new_value = 0; / #endif`（6 行） |
| （打包） | `mkbootimg --cmdline` 中 `androidboot.selinux=permissive` → `enforcing` |

#### K.7.1 为什么分两阶段刷（探针 + 永久化）

真正的风险点只有一个：**cmdline 改动会不会让系统起不来**。于是拆成两步，每步都可控：

1. **v25-probe** —— 内核二进制 = v25（补丁已摘），但 cmdline **保持 `permissive`**
   （与已验证可用的 v24 **逐字相同**）→ 启动行为与 v24 等价，**风险 ≈ 0**。
   目的：在安全前提下让 `setenforce` 恢复可用，做运行时试切。
2. **v25-final** —— 同一个 `Image.gz`，只把 cmdline 改成 `enforcing`。
   在 probe 已验证的前提下，这步同样安全。

> **踩坑**：probe 刷完一开机就发现**已经是 Enforcing 了** —— 这正是 C 节那个反直觉结论的由来：
> cmdline 的 `permissive` 被 init 覆盖，唯一让它失效的是被摘掉的补丁。
> 所以 probe 阶段就已经达成目标，final 只是为了 `ro.boot.selinux` 属性与出厂对齐。

#### K.7.2 实测（两次开机，均干净）

| 指标 | v24（Permissive） | v25-final（Enforcing） |
|---|---|---|
| `getenforce` | Permissive | **Enforcing** |
| `ro.boot.selinux` | permissive | **enforcing** |
| enforcing 变更次数（整次开机） | 1（被补丁吞成 0） | **1**（init @15.86s，无回翻） |
| `su -c 'id'` | `context=u:r:su:s0` | **`context=u:r:su:s0`** ✅ |
| `avc: denied`（`dmesg.log`，0–50s 区间） | 301（v23 基线 609） | **186 / 190 / 198**（3 次开机） |
| 其中 `su` / `ksu` / `adbd` 域 | 0 | **0** ✅ |
| `Zygote: seccomp disabled by setenforce 0` | 有 | **0 条** |
| 模块 | 3 个 | **3 个**（WorkSettingPro / zygisk_lsposed / zygisksu） |
| LSPosed | 正常 | **正常**（`verbose_*.log` 每次开机新生） |
| `sys.boot_completed` | 1 | **1** |

denial 域分布全是华为/安卓系统自身：`init`(45) / `zygote`(22) / `platform_app`(20) /
`vendor_init`(17) / `system_server`(17) / `hal_camera_default`(16) / `tee`(14) / `vold`(10) /
`hal_wifi_default`(10) / `kernel`(8) / `radio` / `nfc` / `logserver` / `untrusted_app` /
`system_app` / `thermal` / `rild` / `dubaid` / `fusd` / `xlogcat` / `audioserver` …；
访问目标全是华为私有类型（`cota_vendor_data_file` / `hw_cust_file` / `sysfs_led` /
`sysfs_fingerprint` / `bcm_wifi_open_state` / `sys_rcc_event` / `proc_signtool` …）
—— **无一与 KSU 相关**（`u:r:ksu` / `u:object_r:ksu` 计数均为 0）。

> ⚠️ **数据更正（2026-10-02）**：本节初版曾写「`avc: denied` 仅 **11** 条」——**那是错的**。
> 它是在 `dmesg`（环形缓冲，约 8000 行、开机数十秒后早期记录已被冲掉）上数的，**严重低估**。
> 正确口径必须用 `/data/adb/ksu/log/dmesg.log`（完整落盘，覆盖 0–50s）：
> **v23 = 609（其中 su 域 446）→ v24 = 301 → v25 = 186/190/198，su/ksu/adbd 域恒为 0**。
> 教训：**统计 avc 数量绝不能用 `dmesg`**。

**回归确认**（v25 未破坏 v23/v24 的任何修复）：

| 指标 | v24 基线 | **v25** |
|---|---|---|
| `read init.rc` | 1 | **1** ✓ |
| `on_post_fs_data` | 2 | **2** ✓ |
| `exec zygote` | 1 | **1** ✓ |
| `post-fs-data triggered` | 1 | **1** ✓ |
| `unregister init_rc_hook kprobe` | 1 | **1** ✓ |
| `list_try_umount` 相关日志 | 0 | **0** ✓ |
| 全日志 `WARNING:` | 1（华为固件自身） | **1** ✓ |
| `Cached ksu_file SID` | 302 | **302** ✓ |
| `.allowlist` | 1560 B | **1560 B** ✓ |
| `ksu: selinux rules applied` | 1 | **1** ✓ |

> 注：`grep -c unregister` 会得到 3 —— 另外两条是 `unregister execve kprobe: 1!`（另一个钩子）
> 与 WiFi 驱动的 `BCMDHD:P2P interface unregistered`。查 `init_rc_hook` 要用精确 pattern。

**开关验证**：`su -c 'setenforce 0; getenforce'` → `Permissive`；
`su -c 'setenforce 1; getenforce'` → `Enforcing`，两条 `type=1404` 审计记录齐全
（证明管理器那个 `selinux_toggle` 现在真的能用了）。

#### K.7.3 v25 交付物

- 镜像 `kernel_sukisu_v25.img`（15,163,392 B，md5 `3370ac4189f2319bb90d0b76babcd9fa`，
  sha256 `2ee03060d9dc861f6ca95987b1f284e96f0b7f211b5f04bf9850eba1e1003805`）
  —— cmdline = `enforcing`，**已刷入设备并验证**
- 镜像 `kernel_sukisu_v25probe.img`（同尺寸，md5 `a6a5cddc64fe1dbca2782097f31e0901`，
  sha256 `0acecc9d78d2e663dae08da2d55788b97156f18642128318c1e826dc5e65a6e1`）
  —— cmdline = `permissive`，探针版
- 内核标识 `#19 SMP PREEMPT Thu Oct 1 23:16:44 UTC 2026`
- 编译：`BUILD_EXIT=0`、`ERRORS=0`、`WARNS=0`

#### K.7.4 救援通道（本轮查清，务必记住）

刷 `kernel` 分区**唯一**的救援不是 fastboot（本机 Windows 缺驱动，`USB\VID_18D1&PID_D00D`
无匹配 INF），而是 **eRecovery**：

| 分区 | 用途 |
|---|---|
| `kernel` (mmcblk0p39, 24 MB) | 内核，**正常开机与 recovery 共用** |
| `recovery_ramdisk` (mmcblk0p41, 32 MB) | EMUI9 是 aonly SAR 方案（**无 `boot` 分区**），这个就是系统启动用的 ramdisk |
| **`erecovery_kernel` (p35) + `erecovery_ramdisk` (p36)** | **独立内核 + 独立 ramdisk → 与 `kernel` 分区完全解耦** |

- `erecovery_kernel` 头部实测 = `ANDROID!`（合法 boot 镜像）→ **`kernel` 刷坏也能进 eRecovery**
- 进入方式：开机时**按住音量上**（EMUI 9.1 会进 erec 模式）
- 设备端自带出厂备份 `/sdcard/kernel_stock.img`（25,165,824 B = 整个 24 MB 分区）
- 回滚：`su -c "dd if=/sdcard/kernel_stock.img of=/dev/block/by-name/kernel bs=4096"`

> **Windows fastboot 驱动**：本机驱动库中**没有任何** Android/fastboot 驱动；
> Google USB Driver（r13）的 `android_winusb.inf` **不含** `USB\VID_18D1&PID_D00D`
> （只有 4E40 / 2C10 / 4EE0 / 9004 / 9006 / 4D00）。
> 麒麟盘古工具箱的说明里写明前提是「**电脑安装好华为手机助手**」——即需要 **HiSuite 的华为 USB 驱动**。

### K.8 第八轮（v25 之上）—— 授权持久化端到端复测（2026-10-02，**无新补丁**）

原始故障「root 授权重启会丢失」的机理只可能出在两条路径上，本轮回测**同时覆盖两条**：

| 路径 | 内核函数 | 断掉的表现 |
|---|---|---|
| **读** | `ksu_load_allow_list()`（`on_post_fs_data()` 调用） | 文件里有条目、开机后内存里没有 |
| **写** | `do_persistent_allow_list()`（`persistent_allow_list()` 排入 init 的 task_work） | 授权后文件没更新，重启即丢 |

**方法（全自动，无需人工在管理器点授权）**：追加一条**合成探测条目**
（`key="com.example.persistprobe"`、`uid=19999`，复制 `com.android.shell` 的 776 B 记录只改这两处）
→ 重启 → 开机时 `ksu_load_allow_list()` 应加载 3 条（**读**）；
`ksud boot-completed` → `on_boot_completed()` → `track_throne(true)` → `ksu_prune_allowlist()`
发现 uid 19999 不存在 → 剔除 → `persistent_allow_list()` 重写文件（**写**）→ 文件自动回到 2 条。

**实测结果（全部通过）**：

```
# 读路径 @19.715s [pid:475,ksud]
allowlist version: 3
load_allow_uid, name: com.android.shell,        uid: 2000,  allow: 1
load_allow_uid, name: com.byyoung.setting,      uid: 10186, allow: 1
load_allow_uid, name: com.example.persistprobe, uid: 19999, allow: 1   ← 新条目
load_allow_list read err: 0        ← 读完 3 条后的正常 EOF（上游措辞如此，不是错误）
ksu_show_allow_list → uid:2000 / uid:10186 / uid:19999

# 写路径 @38.58~38.61s
[38.582489] [pid:3104,ksud] on_boot_completed!
[38.604461] [pid:3104,ksud] prune uid: 19999, package: com.example.persistprobe
[38.610565] [pid:1,init]    save allow list, name: com.android.shell   uid :2000,  allow: 1
[38.610565] [pid:1,init]    save allow list, name: com.byyoung.setting uid :10186, allow: 1
```

- **字节级往返**：探测前 1560 B（sha256 `b26852b8…592d`）→ 探测后 2336 B → 重启后内核重写回
  **1560 B 且 sha256 与基线逐字节相同** ✅；inode 96136 与标签 `u:object_r:adb_data_file:s0` 全程保留
- **功能**：`getenforce`=Enforcing、`su -c 'id'`→`u:r:su:s0`、3 模块全启用、LSPosed 新生 verbose 日志
- 写盘发生在 **pid:1 (init)** —— 与 `task_work_add(init_task, cb, TWA_RESUME)` 实现吻合

**⭐ 为什么 `on_boot_completed` 是唯一 prune 触发点**：`pkg_observer.c`（监听 `packages.list`）
整个文件被 `#if LINUX_VERSION_CODE >= KERNEL_VERSION(5,2,0)` 包住，**4.9 上不编译**。

**⭐ `.allowlist` 文件格式（源码 + 十六进制双向确认）**：

```
偏移 0 : u32 magic   = 0x7f4b5355 ("USK\x7f")
偏移 4 : u32 version = 3
偏移 8 : N × struct app_profile (776 B)     ← 无 count 字段，读到 EOF 为止
```
`sizeof(struct app_profile)=776`（`app_profile.h` 布局验算，与实测 `(1560-8)/2` 吻合）；
`selinux_domain` 绝对偏移 = `8 + 704 = 712`，与实测 `u:r:su:s0` 位置逐字节吻合。

**⭐ 附带查清：管理器永远有 root** —— `supercalls.c:allowed_for_su() = is_manager() || ksu_is_allow_uid_for_current()`
；`is_manager()` 比 `ksu_manager_appid`（本项目补丁 `ZCODE_PRESET_MANAGER` 预置 **10189** = `com.sukisu.ultra` 实测 uid）。
⇒ **即使 `.allowlist` 完全损坏、adb `su` 失效，管理器仍能取得 root 并重建授权** → 清空 allowlist 重测**无自锁风险**。

**⚠️ 别被 `ksud profile set-sepolicy` 误导**：它写的是 `/data/adb/ksu/profile/selinux/<pkg>`（9 字节纯域名），
**不触碰 `.allowlist`、不触发 `save allow list`**。`ksud` 全部子命令中确无 grant/revoke/allowlist 项。

证据：`_work/fix/artifacts/allowlist_persistence/EVIDENCE.md`；工具 `scripts/mkprobe.py`。

---

## L. SUSFS 编入（v26，2026-10-02）

> ⭐ **完整逆向推导、命令号表、err 偏移表与反汇编证据见
> `patches/susfs/SUSFS_ABI_NOTES.md`** —— 本节只记「改了什么、为什么这么改」。
> 改动文件完整源码：`patches/susfs/v26_sources/`（13 个文件）。

### L.1 引擎选型

上游 SUSFS **没有 v2.3.0 的 4.9 版本**（v2.x 最低要求 GKI 5.10）。
选定路线：**以 4.9 原生引擎（v1.5.9）为基础，把 UAPI/派发层改造成能同时吃 v2.3.0 与 v2.0.0 布局**。

| 文件 | 来源 / 改动 |
|---|---|
| `fs/susfs.c` | v1.5.9 (kernel-4.9) 引擎 + **双布局改造**（本轮） |
| `include/linux/susfs.h` | v2.3.0 UAPI + 3 个 `_v200` 影子结构体 |
| `include/linux/susfs_def.h` | v2.3.0 常量；`#include <linux/bitops.h>`（4.9 无 `bits.h`）；`ERR_CMD_NOT_SUPPORTED 126` |

**Kconfig 新增 11 项**（全部 `=y`）：`SUS_PATH` / `SUS_MOUNT` / `AUTO_ADD_SUS_KSU_DEFAULT_MOUNT` /
`AUTO_ADD_SUS_BIND_MOUNT` / `SUS_KSTAT` / `TRY_UMOUNT` / `AUTO_ADD_TRY_UMOUNT_FOR_BIND_MOUNT` /
`SPOOF_UNAME` / `ENABLE_LOG` / `SPOOF_CMDLINE_OR_BOOTCONFIG` / `OPEN_REDIRECT`。
未启用：`HIDE_KSU_SUSFS_SYMBOLS` / `SUS_OVERLAYFS` / `HAS_MAGIC_MOUNT` / `SUS_SU`。

### L.2 内核侧钩子落点（20 处）

```
fs/namei.c        ×15  （link_path_walk / may_create_in_sticky / do_last / lookup_* …）
fs/readdir.c      ×2   （filldir / filldir64）
fs/stat.c         ×1   （vfs_getattr）
fs/statfs.c       ×1
fs/dcache.c       ×2
fs/proc/fd.c      ×1
fs/notify/fdinfo.c×1
fs/proc/task_mmu.c、fs/namespace.c、fs/overlayfs/*、kernel/sys.c
include/linux/sched.h  （task_struct 加 `susfs_task_state` / `susfs_last_fake_mnt_id`）
drivers/kernelsu/setuid_hook.c （设置 TASK_STRUCT_NON_ROOT_USER_APP_PROC）
```

⚠️ `fs/namespace.c` 的 `susfs_is_mnt_devname_ksu()` 必须**先声明变量再用 `#ifdef` 守卫**，
否则 `-Wdeclaration-after-statement` 报警。修法脚本：`patches/susfs/patch_namespace.py`（幂等）。

### L.3 派发路径（无 kprobe）

`CONFIG_KPROBES` 未设 → `sys_enter` tracepoint：

```c
/* syscall_hook_manager.c */
if (id == __NR_reboot) {
    int magic1 = (int)PT_REGS_PARM1(regs);
    int magic2 = (int)PT_REGS_PARM2(regs);
    unsigned int cmd = (unsigned int)PT_REGS_PARM3(regs);
    void __user **arg = (void __user **)&PT_REGS_SYSCALL_PARM4(regs);
    ksu_handle_sys_reboot(magic1, magic2, cmd, arg);
    return;
}
```

`ksu_handle_sys_reboot()` 中 `magic2 == SUSFS_MAGIC(0xFAFAFAFA)` → `ksu_handle_susfs_cmd(cmd, arg)`。
`PT_REGS_SYSCALL_PARM4` 定义在 `drivers/kernelsu/arch.h:60`（arm64 取 `regs[3]`）。

### L.4 ⭐ 本轮真正的坑：v2.3.0 vs v2.0.0 双布局

**现象**：内核日志 `CMD_SUSFS_ADD_SUS_PATH -> ret: 0`，但管理器报失败；
`add_sus_path` 返回 `-2`，内核日志出现 `failed opening file '\x1eD\x01'`（乱码路径）。

**根因（三重证据闭环）**：

1. 乱码 `\x1eD\x01` 小端 = `0x01441E` = **82974** = 被探测文件的真实 inode 号
   → 说明内核把结构体**开头 8 字节当成了路径名**。
2. 反汇编工具：`orr x0,x8,#0x8`（strncpy 到 base+8）、`str x8(ino),[base+0]`、
   `str w8(126),[base+268]` → 工具结构体带 8 字节 `target_ino` 前缀，err 在 **268**。
3. 对齐校准：`set_uname` 站点 `str w8(126),[sp,#4884]`，基址 4752 → err@132，
   与我们结构体逐字节一致，且实测成功 → 证明「用 err 偏移反推布局」的方法可靠。

**结论**：SukiSU Ultra 4.1.1 带的工具是 **v2.0.0 线格式**。

**修法**：

* `sus_path` / `open_redirect`：**首字节探测**（路径名必为绝对路径）
  ```c
  if (probe[0] == '/') return 0;                 /* v2.3.0 */
  if (probe[8] == '/') return SUSFS_LEGACY_INO_PREFIX;  /* v2.0.0 */
  ```
  按 `path_off` 读 pathname、按对应偏移写 err。
* `sus_kstat`：载荷里**没有**可判别版本的字段 → **双写 err**（@368 与 @372）。
  安全性已核实：两个槽都在派发层 `ksu_access_ok()` 校验过的 376 B 窗口内；
  工具栈帧 8864 B 且全程序不引用 `sp+5124`。
* 派发层 `ksu_access_ok` 尺寸放宽到**两布局中较大者**
  （`sus_path` 272 B / `open_redirect` 524 B）。

### L.5 工具的关键行为（导致误判的元凶）

工具**调用内核前先把 err 槽预填 126**，调用后若**仍为 126** 就打印
`[-] CMD: '0x%x', SUSFS operation not supported, please enable it in kernel` 并返回 126。

⇒ **判读口诀：内核日志 `ret: 0` + 工具 `rc=126` ⇒ err 回写偏移不匹配**（不是命令没实现）。

### L.6 交付物

| 文件 | md5 / 说明 |
|---|---|
| `artifacts/kernel_sukisu_v26.img` | `28171388579c9716e5725b88eb12a4f9`（15173632 B，内核 `#24`） |
| `scripts/build_v26.sh` / `pack_v26.sh` / `flash_v26.sh` | 编译 / 打包 / 刷入 |
| `patches/susfs/SUSFS_ABI_NOTES.md` | ★★ 双布局逆向笔记 |
| `patches/susfs/v26_sources/` | 13 个改动文件完整源码 |
| `patches/susfs/upstream_ref/` | 上游参考 + `ksu_susfs_2.0.0.bin` + `.dis` |

### L.7 ⚠️ 刷入校验脚本的一个陷阱（本轮修正）

`flash_v26.sh` 原实现：把**期望镜像补零**到整页后与回读比对。
**镜像变短时必然误报** —— 多出的那半页是**上一个内核**的残留数据，不是零。
正确做法：把**回读结果截断到镜像长度**再比。已修正。

```sh
dd if=$K of=/data/local/tmp/rb.img bs=4096 count=$CNT
dd if=/data/local/tmp/rb.img of=/data/local/tmp/rb_trunc.img bs=$SZ count=1
sha256sum /data/local/tmp/rb_trunc.img "$IMG"     # 两行应一致
```

### L.8 未实现项（v26 时的状态）

> ⚠️ **本节已被 §M 部分取代**：`ADD_SUS_PATH_LOOP` / `ADD_SUS_MAP` /
> `ENABLE_AVC_LOG_SPOOFING` 三项在 **v27 已实现**。此处保留 v26 的原始判断，
> 用于说明"为什么当时没有顺手实现"。

v26 时 `ADD_SUS_PATH_LOOP` / `ADD_SUS_MAP` / `ENABLE_AVC_LOG_SPOOFING` 及 6 个废弃命令
（`ADD_SUS_MOUNT` / `SET_ANDROID_DATA_ROOT_PATH` / `SET_SDCARD_ROOT_PATH` /
`UMOUNT_FOR_ZYGOTE_ISO_SERVICE` / `ADD_TRY_UMOUNT` / `SUS_SU`）一律走 `default` → 返回 126。

**为什么不"顺手"实现**：这些命令的载荷布局**各不相同**，废弃命令的 `err` 偏移无处可查，
在 `default` 里猜一个偏移去写会把数据写到 `access_ok()` 校验范围之外。
返回 126 时管理器会**正确显示为"不支持"**（而不是报错），这是最安全的行为。

v27 实现那三项时，正是**先反汇编确认了各自的 `err` 偏移**再动手（见 §M.1），
并且**仍然保留** 6 个废弃命令返回 126 —— 它们的布局确实无处可查。

---

## M. SUSFS 三项补齐 + 缺陷修复（v27 → v29，2026-10-02）

> 命令号表 / err 偏移 / inode 状态位等 ABI 细节见 `patches/susfs/SUSFS_ABI_NOTES.md`。
> 此处只列改动点与实测证据。三个版本均 `BUILD_EXIT=0 / ERRORS=0 / WARNINGS=0`。

### M.1 三项能力补齐（v27）

| 命令 | 命令号 | 载荷 err 偏移 | 实现 |
|---|---|---|---|
| `ADD_SUS_PATH_LOOP` | `0x55553` | 走 `susfs_pathname_offset()` 双布局探测 | `LH_SUS_PATH_LOOP` 链表 + kworker 复打标 |
| `ADD_SUS_MAP` | `0x60020` | 256 | `INODE_STATE_SUS_MAP BIT(28)` + `fs/proc/task_mmu.c` 两处钩子 |
| `ENABLE_AVC_LOG_SPOOFING` | `0x60010` | 4 | `security/selinux/avc.c:avc_dump_query()` 伪装 `tcontext` |

配套改动：

* `drivers/kernelsu/Kconfig`：新增 `KSU_SUSFS_SUS_MAP` / `KSU_SUSFS_AVC_LOG_SPOOFING`（均 `default y`）；
* `drivers/kernelsu/supercalls.c`：`ksu_handle_susfs_cmd()` 三个 case 由 126 桩改为真派发；
  `susfs_reply_not_supported()` 改 `static void __maybe_unused`（三项实现后它只在废弃命令分支用）；
* `include/linux/susfs_def.h`：`INODE_STATE_SUS_MAP BIT(28)`、`SUSFS_KSU_CONTEXT`、
  `SUSFS_PRIV_APP_CONTEXT`、`SUSFS_PRIV_APP_SECCTX`、`SUSFS_SUS_PATH_LOOP_MAX_RETRY 3`；
* `drivers/kernelsu/setuid_hook.c`：`ksu_handle_setresuid()` 末尾调 `susfs_schedule_extra_works()`。

效果：`ksud susfs features` 由 **7 项 → 9 项**。

### M.2 ⭐ 编译期陷阱：localversion 里的 `&`

`CONFIG_LOCALVERSION="-非酋&大肥鱼自制max版"` 让首次编译直接失败：

```
/bin/sh: 1: 大肥鱼自制max版": not found
Makefile:1374: recipe for target 'include/generated/utsrelease.h' failed
Error 127
```

**根因**：顶层 `Makefile` 的 `filechk_utsrelease.h` 用的是

```make
(echo \#define UTS_RELEASE \"$(KERNELRELEASE)\";)
```

`$(KERNELRELEASE)` **未加引号** → 值里的 `&` 被 `/bin/sh` 当成**后台运算符**，
`echo` 只吃到 `非酋`，剩下的被当命令执行。

**修法**（`scripts/fix_makefile_utsrelease.py`，幂等）：

```make
(printf '#define UTS_RELEASE "%s"\n' '$(KERNELRELEASE)')
```

顺带修了 `cmd_depmod` 里同类的 `echo` 隐患。备份：`/root/Makefile.bak_v27`。

### M.3 5 个缺陷修复（v28 修 3 个，v29 再修 2 个）

| # | 文件 | 缺陷 | 修法 |
|---|---|---|---|
| ① | `drivers/kernelsu/syscall_hook_manager.c` | `__NR_reboot` 在 tracepoint 与 `kernel/reboot.c` 直钩**重复派发**，命令执行两遍 | **删掉 tracepoint 分支**，只留 `reboot.c` |
| ② | `fs/susfs.c` | `susfs_add_sus_path_loop()` 延迟打标：add 时只入队，失败也不告知调用方 | **就地 `kern_path()` + 打标**，失败 `err = -ENOENT` 且不入队 |
| ③ | `fs/susfs.c` | 同路径重复注册产生多条链表项 | 加 `cursor` 遍历去重，命中返回 `err = 0` + `already in LH_SUS_PATH_LOOP` |
| ④ | `fs/susfs.c` + `include/linux/susfs.h` | 打标失败条目无限重试，刷 console | 新增 `u32 fail_count` + `SUSFS_SUS_PATH_LOOP_MAX_RETRY 3`，达阈值 `list_del` + `kfree` |
| ⑤ | `fs/susfs.c` | `susfs_update_sus_path_inode()` 用 `SUSFS_LOGE`(pr_err)，本 ROM `console_loglevel=4` 故上 console | 两处改 `SUSFS_LOGI`(pr_info)，失败只记一次 |

**① 的实测判据**：

```sh
B=$(su -c "dmesg | grep -c CMD_SUSFS_SHOW_VERSION"); su -c '…/ksu_susfs show version'
A=$(su -c "dmesg | grep -c CMD_SUSFS_SHOW_VERSION")   # A-B：v28=2 → v29=1
```

**④ 的实测证据**（登记一个 kworker 域无法解析的路径）：

```
kworker: Failed opening file '…'                              ← 1
kworker: cannot re-flag path '…', retrying up to 3 times
kworker: Failed opening file '…'                              ← 2
kworker: Failed opening file '…'                              ← 3
kworker: giving up on path '…' after 3 failures, removing it from LH_SUS_PATH_LOOP
```

之后触发 8 次 `setresuid`，该路径日志计数**恒为 6 不再增长** ⇒ 已出列。

### M.4 顺带修掉的两类编译警告

* **4 条 COMMON symbol 警告**（`susfs_extra_works` / `susfs_priv_app_sid` /
  `susfs_is_avc_log_spoofing_enabled` / `susfs_ku_su_sid`）：
  work_struct 改 `static` 并导出 `susfs_schedule_extra_works()`；
  三个变量加显式初值（`= 0` / `= false`）。
* 其余警告（`kernel/module.c:1946 -Wunused-value`、`ksu_cred` COMMON）经核查
  **v26 基线已存在**，属华为 vendor 代码固有噪声，**非本次引入**。

### M.5 交付物

| 文件 | 说明 |
|---|---|
| `artifacts/kernel_sukisu_v27.img` | 内核 `#27`，三项功能首次可用 |
| `artifacts/kernel_sukisu_v28.img` | md5 `24daf5f4c2e7685d89c0f087ab9043e2`，修 ①②③④⑤ |
| `artifacts/kernel_sukisu_v29.img` | md5 `67cd30e58707170f1bbb8c52ecf647dd`，额外修 ①（重复派发） |
| `patches/susfs/v29_sources/` | 10 个改动文件完整源码快照 |
| `scripts/build_v2{7,8,9}.sh` / `pack_v2{7,8,9}.sh` / `flash_v2{8,9}.sh` | 编译 / 打包 / 刷入 |
| `scripts/fix_makefile_utsrelease.py` | §M.2 的 Makefile 修复脚本（幂等） |

### M.6 遗留观察（非本项目原因，已排查）

* **`context_struct_compute_av` oops**（v28 某次开机 17.23 s）：
  崩溃点在 `security/selinux/ss/services.c`，**本项目从未修改该文件**；
  本项目唯一改过的 SELinux 文件是 `avc.c` 的 `avc_dump_query()`（审计格式化），
  而崩溃发生在 `avc_compute_av` **之前**。详见 `HEALTH_CHECK.md` §9.5(a)。
* **`hungtask` panic**（1235.199 s）：`mmc-cmdqd/0` 阻塞 840 s+ 导致存储 I/O 停滞，
  与内核改动无关。详见 `HEALTH_CHECK.md` §9.5(b)。
* **`avc_log_spoofing` 的端到端验证受限**：
  需构造 `tsid == susfs_ksu_sid` 的 SELinux 拒绝，但设备上**不存在继承 `u:r:su:s0`
  的文件标签**（`/data/adb/*`→`adb_data_file`、`/dev/*`→`device`、`/mnt/*`→`tmpfs`、
  `/cache/*`→`cache_file`、`/data/local/tmp/*`→`shell_data_file`，均因 type_transition）。
  只验证到 `rc=0` + `enabled: 1/0` + 代码路径逐字核对。详见 `SUSFS_ABI_NOTES.md` §9.3。
* **`sus_map` 端到端已验证通过**（smaps 隐藏）：标记 `/system/lib64/libc.so` 后，
  uid 10123 读 `/proc/self/smaps` 的 `^Rss:` 行数由 115 → **112**（少 3，即 libc.so 的
  3 个 vma），总行数 2345 → 2297（少 48 = 3×16）；root(uid 0) 不受影响（仍 115）。
  ⚠️ 判据是 `Rss`/`Pss` 行数，**不是** `Size: 0 kB`（隐藏后 `Size` 仍是真实值）。
  详见 `SUSFS_ABI_NOTES.md` §9.2。

---

## N. 非内核侧发现与配套模块（2026-10-02，**无内核补丁**）

这一节记录两个"看起来像内核缺陷、实际都不是"的问题，以及为其中一个做的配套模块。

### N.1 GPU 负载恒显示 `-1%` —— 工具箱读的节点本平台不存在

* 本项目**从未**修改 GPU / devfreq：`grep -n "devfreq\|gpufreq\|mali\|drivers/gpu" docs/PATCHES.md`
  → **零匹配**。
* 本平台**没有**标准 devfreq `load` 节点：全树 `grep -rn 'dev_attr_load' drivers/devfreq/`
  → 只有 `l3c_devfreq.c:1312` 的 `load_map`（L3 缓存调频器，与 GPU 无关）。
* 华为把 GPU 负载放在私有只读属性里（**英式拼写**）：
  **`/sys/class/devfreq/gpufreq/gpu_scene_aware/utilisation`**（0444）
  * 源码 `drivers/devfreq/hisi/governor_gpu_scene_aware.c`（726 行）
  * `util = stat.busy_time * 100 / stat.total_time`（L123），滑窗加权后
    `data->utilisation = div64_u64(a, *freq)`（L138）
* 工具箱读通用路径（`/sys/class/devfreq/gpufreq/load`）或高通专用路径
  （`/sys/class/kgsl/kgsl-3d0/gpu_busy_percentage`，本机连 `/sys/class/kgsl` 都没有），
  两处都失败 ⇒ 回落哨兵值 `-1`。
* 同类问题：`/sys/block/sda/queue/scheduler` 也不存在（本机存储是 `mmcblk0`）。

⇒ **结论：工具箱节点适配问题，不是内核缺陷。** 完整记录见 `HEALTH_CHECK.md` §10。

### N.2 `enable_avc_log_spoofing` “无法启用” —— 缺陷在管理器，不在内核

> ⚠️ **2026-10-02 下午修正**：本节是**第一版结论**（当时基于 Kotlin 源码推测）。
> 后来用 **jadx 反编译 APK 字节码**才发现**真正的头号根因是"管理器按内核报告的
> 版本号去找随包工具，找不到就让全部 SUSFS 命令一起失效"** —— 见 **§P**。
> 本节 ① 仍然成立（但只影响"特性列表"的显示，不影响开关）；② 的"从未被消费"
> 经反编译复核**不准确**（`AbstractC2729a.java:1554` 确实有生成该命令的代码）。
> 本节的"自建模块"处置属于**绕过**，§P 的改版本号才是**根治**。

**内核侧正常**：`ksu_susfs enable_avc_log_spoofing 1` → `rc=0`（两次实测）；
`ksu_susfs show enabled_features` 输出 **9 项**，**含 `CONFIG_KSU_SUSFS_AVC_LOG_SPOOFING`**。

**SukiSU Ultra 4.1.1 管理器侧两处缺陷**（源码 `mgr_SuSFSManager.kt`，56306 B）：

| # | 位置 | 缺陷 |
|---|---|---|
| ① | `parseEnabledFeaturesFromOutput()` L866–875 | `featureMap` 只列 8 项，**缺 `CONFIG_KSU_SUSFS_AVC_LOG_SPOOFING`** ⇒ 内核报的那一行被丢弃，UI 永远显示不出"已启用" |
| ② | `ModuleConfig.enableAvcLogSpoofing`（L167 定义 / L276 赋值） | 全文件只出现 2 次，**从未被 `ScriptGenerator.generateAllScripts(config)` 消费**；`hasAutoStartConfig()`（L174–184）也没算它 |

**后果**：SUSFS 开关是内核内存态，**重启即丢**，必须每次开机重放；管理器替**其他**配置
生成 KSU 模块来重放，**唯独漏了 AVC 欺骗**。

设备侧证据：SharedPreferences 里**没有** `enable_avc_log_spoofing` 记录；
`/data/adb/modules/` 只有 `.core` / `WorkSettingPro` / `zygisk_lsposed` / `zygisksu`，
**无 SUSFS 模块**。

⚠️ 排除项：`isSusVersion159()` 前置检查无问题（`compareVersions()` 去掉 `v` 前缀后
`2.3.0 > 1.5.9` ✅），不会误拦。

**处置 —— 自建持久化模块**（管理器不重放，就自己重放）：

| 文件 | 大小 | 说明 |
|---|---|---|
| `modules/susfs_avc_spoof/module.prop` | 470 B | 描述里写明管理器缺陷，便于日后回溯 |
| `modules/susfs_avc_spoof/service.sh` | 1471 B | 等 `sys.boot_completed=1`（≤120 s）再 `sleep 3` 执行；755 |
| （设备上）`ksu_susfs` | 19192 B | 从 APK `assets/ksu_susfs_2.0.0` 释放；755 |

设备安装路径 `/data/adb/modules/susfs_avc_spoof/`，首次手动执行：

```
--- Fri Oct  2 11:37:24 CST 2026 boot_completed=1
rc=0
```

**下次重启后**核对 `cat /data/adb/modules/susfs_avc_spoof/run.log` 新增一行 `rc=0`
即可确认自动重放生效。删除整个目录即撤销。完整记录见 `HEALTH_CHECK.md` §11。

### N.3 ⚠️ 排查陷阱：`grep -c 'error:'` 会虚报

内核源码里有大量形如 `LCDKIT_ERR("... return error: %d", ...)` 的**字符串字面量**，
用 `grep -c 'error:'` 统计编译错误会**误匹配**（v30 编译时虚报 4 条）。

**正确写法**：

```sh
grep -cE '^[^ ]+:[0-9]+:[0-9]+: (error|fatal error):' build.log     # 真实错误数
grep -cE '^[^ ]+:[0-9]+:[0-9]+: warning:' build.log                  # 全树警告数
```

⚠️ 全树 `warning:` 计数（v30 = 1813）包含**华为 vendor 固有噪声**，
**不能**用 `WARNS=0` 去卡全树；本项目只要求自己改过的文件无 warning。

---

## O. v30 性能优化尝试 —— **失败并已回滚**（2026-10-02）

> ⚠️ **结论先行：v30 方案作废，设备已回退 v29。本平台不要关 `CONFIG_DEBUG_SPINLOCK`。**
> 保留本节是为了避免以后重复踩同一个坑。

### O.1 原方案（只改 3 项）

| 项 | 原值 | 拟改 | 理由 | 结果 |
|---|---|---|---|---|
| `CONFIG_DEBUG_SPINLOCK` | `y` | `n` | `do_raw_spin_lock/unlock` 从 out-of-line 函数变回 inline `arch_spin_lock()`，省掉每次加/解锁的 `magic`/`owner` 内存写 | ❌ **导致无法启动** |
| `CONFIG_ZSMALLOC_STAT` | `y` | `n` | zram 分配/释放热路径的 per-class 计数 | ⚠️ 未单独验证 |
| `CONFIG_BOOTPARAM_HUNG_TASK_PANIC` | `y` | `n` | 原厂 `=y` ⇒ D 态超 120 s 直接 panic 重启 | ❌ **不该关**（见 O.4） |

已评估后**放弃**的项：`TASK_DELAY_ACCT`/`TASK_XACCT`/`TASKSTATS`（华为 vendor 5 个文件几十处直接引用
`task->delays` 且无 `#ifdef` 保护 ⇒ **编译必失败**，`mm/memory.c:3023/3050/3068/3079 error: 'struct
task_struct' has no member named 'delays'`）；`SCHEDSTATS`（static key，默认关，开销≈0）；
`HZ 250→300`（收益微弱）；`FRAME_POINTER`（影响 oops 栈回溯，刚出过异常 ⇒ 保留）；
`FTRACE_SYSCALLS`（**SUSFS 依赖** ⇒ 必须保留）；`KALLSYMS_ALL`（SukiSU 运行时解析符号 ⇒ 保留）。

### O.2 第一个坑：链接失败 `undefined reference to __raw_spin_lock_init`

关掉 `DEBUG_SPINLOCK` 后 `vmlinux` 链接报：

```
ld: drivers/built-in.o: in function `VENC_DRV_OsalLockCreate':
  undefined reference to `__raw_spin_lock_init'   （共 21 处）
```

**根因**：`drivers/vcodec/hi_vcodec/**` 里的"源文件"其实是华为发布的**预处理汇编**（`.S`，
如 `drv_venc_osal.S` 476 KB），它们**直接 `bl __raw_spin_lock_init`**；而该符号**只在
`CONFIG_DEBUG_SPINLOCK=y` 时由 `kernel/locking/spinlock_debug.c` 提供**
（`kernel/locking/Makefile`：`obj-$(CONFIG_DEBUG_SPINLOCK) += spinlock_debug.o`）。

⚠️ **在 `.c`/`.h` 里 grep `__raw_spin_lock_init` 是找不到的**（所以一开始会误以为没人调用）。
实测该汇编**只**引用这一个 debug 符号，不引用 `do_raw_spin_lock`/`do_raw_read_lock`/`__rwlock_init`。

**当时的处理**（链接确实修好了）：在 `kernel/locking/spinlock.c` 末尾补

```c
#ifndef CONFIG_DEBUG_SPINLOCK
void __raw_spin_lock_init(raw_spinlock_t *lock, const char *name,
			  struct lock_class_key *key)
{
	*(lock) = __RAW_SPIN_LOCK_UNLOCKED(lock);
}
EXPORT_SYMBOL(__raw_spin_lock_init);
#endif
```

增量编译 35 s 通过，`nm vmlinux` 见 `__raw_spin_lock_init` = **T**、
`do_raw_spin_lock` **不存在**（证明 `DEBUG_SPINLOCK=n` 真的生效）。

### O.3 第二个坑（致命）：刷入后卡在"BL 已解锁"界面

- 镜像校验全通过：`kernel_sukisu_v30.img` md5 `37fe8b2972ec938781eb9b364ce38128`，15,142,912 B；
  dd 刷入后**回读 sha256 == 期望**（`c5ef5603a12afa4f1f30d3edbd9598d0337c9df8a352c452f5fcdb0060893a42`），
  3,697 页正好页对齐。
- 重启后 **adbd 4 分钟未出现**，屏幕**卡在"BL 已解锁"警告界面**。
- **镜像格式无罪**：写脚本解析 Android boot image 头，v30 与 v29/原厂**逐字段一致**
  （`ANDROID!` magic、`page_size=2048`、`header_version=1`、`kernel_addr=0x80000`、
  `tags_addr=0x7a00000`、`header_size=1648`、cmdline 全同），内嵌 `Image.gz` gzip 解压正常。
- **"卡在 BL 界面"的真实含义**：内核**在显示驱动初始化之前就挂了**，屏幕保留 bootloader 最后一帧。
  （区别于存储卡顿 —— 那会让内核起来后卡在挂载阶段。）

### O.4 结论与红线

1. **`CONFIG_DEBUG_SPINLOCK` 保持 `=y`。** 头号嫌疑：vendor 预处理汇编是按
   `DEBUG_SPINLOCK=y` 的 `struct raw_spinlock` 布局（含 `magic`/`owner_cpu`/`owner`）编译的，
   补桩只能解决**链接**，解决不了**运行时布局不一致**。链接通过 ≠ 运行正确。
2. **`CONFIG_BOOTPARAM_HUNG_TASK_PANIC` 保持 `=y`。** 本机本来就有偶发 `hungtask`（曾 panic 自动重启），
   关掉后"卡死 120 s 自动重启"会变成**永久卡死**，更难救。
3. ⇒ **内核侧已无低风险配置优化空间**（完全抢占 + `-O2` + 厂商调优调频器都已就位）。

### O.5 交付物（已作废，仅留档）

`scripts/tune_v30_defconfig.py` / `pack_v30.sh` / `flash_v30.sh`；
`patches/v30_spinlock_stub.c`；`artifacts/kernel_sukisu_v30.img`（**不要刷**）。

---

## P. ⭐⭐⭐ AVC 日志欺骗“打不开”的真正根因 + 修复（v31，2026-10-02）

### P.1 症状与用户诉求

> 「AVC 日志欺骗 我是在 sukisu 里的 susfs 配置发现的 目前还是没法打开
>  **我是想要修复这个 而不是制作模块**」

⇒ 不是“重启后丢”，而是**开关本身点不动 / 点了不生效**；且用户明确要**根治**，不要模块绕过。

### P.2 根因：管理器按**内核报告的版本号**去找随包工具，对不上就整体失效

SukiSU Ultra 4.1.1 在**执行任何 SUSFS 命令之前**，都会先从 APK `assets/` 释放一份
`ksu_susfs` 工具到 `/data/adb/ksu/bin/ksu_susfs`，**文件名是按内核报告的 SUSFS 版本拼的**：

```java
// C1188l（释放工具，每次执行命令前都跑）
str    = m5063I();                              // "<libksud.so> susfs version" → "v2.3.0"
concat = "ksu_susfs_" + str.removePrefix("v");  // → "ksu_susfs_2.3.0"
open   = context.getAssets().open(concat);      // ⚠️ APK 里只有 ksu_susfs_2.0.0 ⇒ IOException
// catch (IOException) → Log.e("SuSFSManager","Failed to copy binary") → return null
// C1189m（命令执行器）
if (path == null) return new C1185j0("", "SUSFS binary not found", false);  // 全部命令直接失败
```

我们 v27 把内核版本号“修正”成 **v2.3.0**（当时为了对齐 ABI），而 APK 里只带了
**`assets/ksu_susfs_2.0.0`** ⇒ **管理器永远释放失败** ⇒ 所有 SUSFS 命令返回失败
⇒ 开关打不开、配置也不写盘。

⚠️ 由此可知：**手动往 `/data/adb/ksu/bin/` 放工具没用** —— 管理器每次都重新释放一份，
释放失败就返回 `null`，**不会回退用已有文件**。

### P.3 4 条证据（全部实测）

| # | 检查 | 结果 |
|---|---|---|
| ① | `ksud susfs version` | **v2.3.0** |
| ② | `unzip -l sukisu_ultra_4.1.1.apk` 找 `ksu_susfs` | 只有 **`assets/ksu_susfs_2.0.0`**（19192 B） |
| ③ | `ls -l /data/adb/ksu/bin/` | `ksu_susfs` = **09:23**（手动放的），`bootctl`/`busybox`/`ksud` = **12:15**（开机释放的）⇒ 管理器刷新失败 |
| ④ | `cat /data/data/com.sukisu.ultra/shared_prefs/susfs_config.xml` | 只有 `auto_start_enabled`，**没有 `enable_avc_log_spoofing`** |

### P.4 修复：`SUSFS_VERSION` `"v2.3.0"` → `"v2.0.0"`

`include/linux/susfs.h:12`：

```diff
- #define SUSFS_VERSION "v2.3.0"
+ #define SUSFS_VERSION "v2.0.0"
```

重编重刷后，管理器会去找 `ksu_susfs_2.0.0`（APK 里确实有）⇒ 释放成功 ⇒ 所有开关恢复。

### P.5 ⚠️ 为什么降版本号**不丢功能**

反编译全局 grep **找不到** `1.5.9` / `compareVersions` / `isSusVersion` 这类版本门槛字符串；
版本号在管理器里**只用于三处**：

| 用途 | 位置 |
|---|---|
| 拼随包工具文件名 | `C1188l` case 0 |
| 写进备份 JSON | `C1189m:140` |
| 状态页显示 | `AbstractC0276q0:31128` / `C0184j:163` |

**不控制任何功能开关** ⇒ 降版本号只是 UI 显示变了，功能无损。

### P.6 ⚠️ 顺带挖出的 v30 遗留坑：`out/.config` 没跟着 defconfig 回滚

v30 回滚时只恢复了 **defconfig 文件**（`cp .v29.bak`），**没有重新生成 `out/.config`**
⇒ `out/.config:5740` 仍是 `# CONFIG_DEBUG_SPINLOCK is not set`。

v31 首次编译 **23 s 就失败**，报的还是 v30 那个错：
`ld: undefined reference to __raw_spin_lock_init`。

**修法**：

```sh
make O=out ARCH=arm64 CROSS_COMPILE=/root/toolchain/bin/aarch64-none-linux-gnu- Pangu_SukiSU_defconfig
grep -n CONFIG_DEBUG_SPINLOCK out/.config      # 必须回到 =y
```

⚠️ 配置变更（`DEBUG_SPINLOCK` n→y 会改变 `raw_spinlock_t` 布局）⇒ **触发全量重编**。

**教训：回滚内核配置时，“恢复 defconfig 文件”和“重新生成 .config”是两步，别只做第一步。**

### P.7 交付物

- `scripts/flash_v31.sh`（设备端刷入 + 回读校验）
- `artifacts/kernel_sukisu_v31.img`

### P.8 v31 端到端验证（2026-10-02 13:0x，全部通过）

| 判据 | 修复前 | 修复后 |
|---|---|---|
| `uname -a` | `#28 … 02:35:44` | **`#32 … 04:58:07`** |
| `ksud susfs version` | `v2.3.0` | **`v2.0.0`** |
| `/data/adb/ksu/bin/ksu_susfs` mtime | `09:23`（手动放的） | **`13:04` / `13:08`（管理器释放）** |
| `susfs_config.xml` | 只有 `auto_start_enabled` | **`enable_avc_log_spoofing=true`** |
| `ksu_susfs enable_avc_log_spoofing 1` | — | **`rc=0`** |
| `ksu_susfs show enabled_features` | — | **9 项含 `CONFIG_KSU_SUSFS_AVC_LOG_SPOOFING`** |

**产物**：`kernel_sukisu_v31.img`，md5 `262be2f5abbd8efa3b752b4f39b07e03`，
sha256 `58ccabae53974b07442da550ae9b987d181e23299605b4d6349d26a3981bdad8`，15,177,728 B。

### P.9 ⭐ 复核修正：管理器**没有**“漏 AVC”（推翻 P.5 的旁支结论）

P.5 曾推测 4.1.1 存在“两处缺陷”（`featureMap` 缺 AVC、`enableAvcLogSpoofing` 未被消费）。
**2026-10-02 下午复核反编译产物后，两条均不成立**：

| 原推测 | 复核结果 |
|---|---|
| `ModuleConfig.enableAvcLogSpoofing` 从未被脚本生成器消费 | ❌ 错。`p166p7/AbstractC2729a.java:1552-1554` 生成 `"$SUSFS_BIN" enable_avc_log_spoofing <0\|1>`，写入 **`post-fs-data.sh`**（`:1563`）。取值 `C1172d.f4797o` = `enableAvcLogSpoofing`（`:54` 声明 / `:71` 赋值 / `:114-115` toString） |
| `C1183i0.m1504d()` 的 featureMap 缺 AVC 是缺陷 | ❌ 错。`:292` 的 9 项是**“特性支持列表”**（`CONFIG_KSU_SUSFS_*` → label）；AVC 日志欺骗是**开关**不是特性 |

`C1183i0.m1501a()`（配置快照 map，`:240`）**也包含** `enable_avc_log_spoofing`。

**实测确认**：打开管理器「自动启动」后，生成的 `/data/adb/modules/susfs_manager/post-fs-data.sh` 里确实有：

```sh
# 设置AVC日志欺骗状态
"$SUSFS_BIN" enable_avc_log_spoofing 1
```

⇒ **唯一根因就是 P.2 那一条**（内核报 v2.3.0 / APK 只有 `ksu_susfs_2.0.0` ⇒ 工具释放失败）。

⚠️ 遗留风险：管理器把该命令放在 `post-fs-data` 阶段（很早），且脚本**不记录 `$?`**（无条件写“启用”），
所以日志无法证明真的成功。自建模块 `susfs_avc_spoof` 特意等 `boot_completed` 才执行以避开该窗口。

#### P.9.1 ✅ 时序实测通过（2026-10-02 13:14 重启验证）

临时诊断脚本 `/data/adb/post-fs-data.d/zz_avc_diag.sh` 在 `post-fs-data` 阶段直接测量 `ksu_susfs` 的返回值：

```text
--- 2026-10-02 05:13:57 post-fs-data.d diag      # UTC，即 13:13:57 CST（该阶段 TZ 未设）
boot_completed=[]                                # 确实还在 post-fs-data 阶段
selinux=[Enforcing]                              # SELinux 策略已加载
rc=0                                             # ✅ 第一次成功
rc2=0                                            # ✅ 再执行一次也成功
```

管理器日志同一时刻（`05:13:58` = 13:13:58 CST，**与诊断脚本同阶段、仅差 1 秒**）：

```text
2026-10-02 05:13:58: Post-FS-Data脚本开始执行
2026-10-02 05:13:58: AVC日志欺骗功能设置为: 启用
2026-10-02 05:13:58: Post-FS-Data脚本执行完成
```

⇒ **`post-fs-data` 阶段 SELinux 策略已就绪、`ksu_susfs` 可用，管理器的重放方案完全可行。**

**处置（已完成）**：

- 删除自建模块 `/data/adb/modules/susfs_avc_spoof/`（备份在 `/data/local/tmp/susfs_avc_spoof.bak`）
- 删除诊断脚本 `/data/adb/post-fs-data.d/zz_avc_diag.sh`
- 现役模块：`WorkSettingPro` / `susfs_manager`（管理器自动生成）/ `zygisk_lsposed` / `zygisksu`
- ⚠️ `susfs_manager/module.prop` 自带“请勿手动卸载或删除”警告 —— 它是管理器「自动启动」的产物，在 UI 改配置时会被重新生成
- ⚠️ 管理器脚本**不记录 `$?`**，日后若开机时序变化会静默失败、无日志可查（只能再放临时诊断脚本复现）
