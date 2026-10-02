# ksud 集成修复报告（FIX_KSUD_INTEGRATION.md）

> 📝 **关于版本串**：本文档中的 `uname -a` 摘录来自实测日志。早期构建使用过个人自定义的
> `CONFIG_LOCALVERSION` 后缀，公开版本已统一隐去为 **`4.9.148-<自定义后缀>`**
> （本仓库现在的默认值是 `4.9.148-SukiSU`）。`#N` 与构建时间才是版本的真实标识，未作改动。

> 症状：**① root 授权重启后丢失**　**② 刷入的模块重启后不生效**
>
> 修复分六轮：
> - **第一轮（v19）** 定位并修掉 4 个缺陷（2 个 4.9 移植遗留 + 2 个 Android 9 平台差异）
>   → 两条链路打通，但引入了一个 tracepoint 原子上下文的回归（日志刷屏 1010 条）。
> - **第二轮（v20）** 修掉该回归（第 5 个根因），并顺带修掉一个**原本就存在、
>   会导致模块链路偶发静默失败**的隐患。**已刷入设备并验证。**
> - **第三轮（v21）** 补上前置过滤，消除大部分噪声（第 6 个根因）。
>   **已刷入，功能全绿；但过滤条件写宽了（`uid != 0`），残余 965 条/开机。**
> - **第四轮（v22）** 收紧过滤条件为 `pid==1 || comm=="init"`，噪声降到 **0**
>   （第 7 个根因）。**已刷入设备并验证。**
> - **第五轮（v23）** 全面体检后清掉两处残余缺陷（第 8、9 个根因，均**不影响功能**
>   但污染日志）：`list_try_umount` 缺分配上限（每次开机 1 条 WARNING + 上百行栈转储）、
>   `init_rc_hook` 重复注销日志（37 条/开机）。**已刷入设备并验证。**
> - **第六轮（v24）** 把体检发现的**剩余全部问题**一次修完（第 10、11、12 个根因 +
>   6 条编译警告）：SELinux 规则引擎移植到 4.9 并补 Android 9 调用路径
>   （**规则此前从未加载过**，avc denied 609→301、su 域 446→0、`ksu_file_sid` 0→302）、
>   fstat / input_event 两个死钩子改源码级直钩、编译警告 6→0。
>   **已刷入设备并验证。**
>
> | 版本 | 补丁 | 镜像 | md5 | 状态 |
> |---|---|---|---|---|
> | v19 | +196/-33, 7 文件 | `kernel_sukisu_v19_ksud_fixed.img` | `f74b7e2b77389a347e6d1ffe1377b8d3` | 已被取代 |
> | v20 | +227/-42, 8 文件 | `kernel_sukisu_v20_preempt_fix.img` | `d4c95cc65a3587b5f531c4adeac825ca` | 已被取代 |
> | v21 | +242/-42, 8 文件 | `kernel_sukisu_v21_uidgate_fix.img` | `11052ea41d1dc521d9d5cbd08d96679e` | 已被取代 |
> | v22 | +248/-42, 8 文件 | `kernel_sukisu_v22_zygote_filter.img` | `fc617ace486a38bb444f6773097d52b4` | 已被取代 |
> | v23 | +271/-38, 9 文件 | `kernel_sukisu_v23_p1p3_fix.img` | `e4385b64f197f3da8bc7d69c1723d52d` | 已被取代 |
> | **v24** | **5 文件 + 10 文件全文** | `kernel_sukisu_v24_hwfix.img` | `367452e90a48d27264a4155ac58df0bb` | **设备当前运行** |
>
> 补丁文件：v23 = `patches/ksud_integration_fix.patch`（md5 `6d54de16d62d90325f98d8b40c01b335`）；
> v24 = `patches/v24_fixes.patch` + `patches/v24_sources/`（完整源码）。
> 历史版本归档在 `_archive/patches/`。
> 镜像 sha256：v24 = `7f58dae08ecc4712cc85c11244cb1ca9061829b18d57e5a9656f4b1028fd06be`
> （v23 = `519ea86021b050e2d9412ba47362596cf6cfdaca256f086dd0663266d0f585f2`）

---

## 一、先搞清 SukiSU 的两条链路

SukiSU 的运行时功能分两条完全解耦的链路，**两条都断**才会同时出现上述两个症状。

### 链路 A — root 授权（内核态，不依赖 ksud）

```
App 调 su ──► sucompat execve 拦截（syscall tracepoint）
          ──► 查内核内存里的 allow_list
          ──► 命中 → setuid(0)
授权变化时 ──► persistent_allow_list() ──► 写 /data/adb/ksu/.allowlist
开机      ──► on_post_fs_data() ──► ksu_load_allow_list() ──► 读回 .allowlist
```

### 链路 B — 模块系统（依赖 ksud 自启）

```
init 读 /init.rc
   └─► 内核在 read() 结果尾部追加 KERNEL_SU_RC（一段 init 脚本）
          └─► init 执行 `ksud post-fs-data`
                 └─► ksud 挂载 /data/adb/modules/* 的 overlayfs
                        └─► ksud 发 EVENT_POST_FS_DATA 给内核
                               └─► on_post_fs_data()（与链路 A 汇合）
```

**关键点**：`on_post_fs_data()` 只做三件事 —— `ksu_load_allow_list()`、
`ksu_observer_init()`、`stop_input_hook()`。**它自己不执行 ksud**。
模块挂载 100% 依赖链路 B 里 init 执行的那行 `ksud post-fs-data`。

---

## 二、七个根因（全部有实证）

### 根因 1 —— `CONFIG_KPROBES is not set`（链路 A + B 全断）

`drivers/kernelsu/ksud.c` 的 `ksu_ksud_init()` 用 **kprobe** 注册全部 ksud 钩子：

```c
ret = register_kprobe(&execve_kp);       // 检测 zygote → 触发 on_post_fs_data()
ret = register_kprobe(&sys_read_kp);     // init.rc 注入
ret = register_kretprobe(&sys_fstat_kp); // 修正 init.rc 的 st_size
ret = register_kprobe(&input_event_kp);  // 音量键安全模式
```

`Pangu_SukiSU_defconfig:234` 是 `# CONFIG_KPROBES is not set`。
内核里 `register_kprobe()` 退化为 `static inline int register_kprobe(...) { return -ENOSYS; }`。

**实证**（上次启动的 pstore 完整内核日志，`/sys/fs/pstore/console-ramoops-0`）：

```
[   13.715606s][pid:1,cpu7,swapper/0]KernelSU: reboot kprobe failed: -38
```

`-38 = -ENOSYS`。reboot kprobe 与 ksud 的 4 个 kprobe 同源，同样注册失败。
→ **4 个钩子全部从未生效**。

### 根因 2 —— kprobe 符号名是 4.17+ 命名（4.9 上找不到）

`drivers/kernelsu/arch.h`（无版本分支）：

```c
#define SYS_READ_SYMBOL   "__arm64_sys_read"
#define SYS_EXECVE_SYMBOL "__arm64_sys_execve"
#define SYS_FSTAT_SYMBOL  "__arm64_sys_newfstat"
```

arm64 的 syscall 符号前缀在 **4.17** 才由 `SyS_*` 改为 `__arm64_sys_*`。
设备实测（`/proc/kallsyms`）：

| 符号 | 4.9 实际存在 | arch.h 里写的 |
|---|---|---|
| read | `SyS_read` ✓ | `__arm64_sys_read` ✗ |
| execve | `SyS_execve` ✓ | `__arm64_sys_execve` ✗ |
| newfstat | `SyS_newfstat` ✓ | `__arm64_sys_newfstat` ✗ |

→ **即便打开 `CONFIG_KPROBES`，注册也会因找不到符号返回 `-ENOENT`。**

### 根因 3 —— `kernel_read`/`kernel_write` 是 5.x 签名（授权写盘失败）

**这是"授权重启丢失"的直接原因。**

本机 4.9 内核（Huawei 把这两个函数挪了位置）：

```c
/* fs/exec.c:892 */
int kernel_read(struct file *file, loff_t offset, char *addr, unsigned long count);

/* fs/splice.c:369 */
ssize_t kernel_write(struct file *file, const char *buf, size_t count, loff_t pos);
```

SukiSU 驱动按 5.x 签名调用（`allowlist.c` 等 21 处）：

```c
kernel_write(fp, &magic, sizeof(magic), &off);   // 第 4 参传 loff_t* 指针
kernel_read (fp, &magic, sizeof(magic), &off);
```

在 4.9 上 `&off` 被当成 `pos` 的**数值**（内核栈地址，有符号为负），
`vfs_write()` → `rw_verify_area()` 对普通文件返回 **-EINVAL**。

**实证**：

```
[   57.803924s][pid:1,cpu1,init]KernelSU: save_allow_list write magic failed.
[   86.575073s][pid:1,cpu1,init]KernelSU: save_allow_list write magic failed.
```

设备实测 `/data/adb/ksu/.allowlist` = **0 字节**。
→ 授权只存在于内存，重启即丢。

### 根因 4 —— `is_init_rc()` 硬编码 Android 10+ 路径（模块不生效的直接原因）

`drivers/kernelsu/ksud.c`：

```c
if (strcmp(dpath, "/system/etc/init/hw/init.rc")) {
    return false;      // ← 上游只认这个路径
}
```

设备实测（Android 9 / EMUI 9.1）：

```
/init.rc                     存在，36412 字节，root:shell 0750   ← 真实路径
/system/etc/init/hw/init.rc  No such file or directory
/system/etc/init/init.rc     No such file or directory
```

日志亦印证 init 读的是 `/init.rc`：

```
[   15.964508s][pid:1,cpu4,init]init: /init.rc: 6: Could not import file '/init.rphone.rc'
```

→ `is_init_rc()` 恒为 `false`，`KERNEL_SU_RC` 永不注入，
init 永远不执行 `ksud post-fs-data`，**模块系统整体失效**。

### 根因 5 —— sys_enter tracepoint 处于原子上下文，读用户态路径会失败（v20 修）

**这是第一轮修复自己引入的回归，同时也暴露了一个原本就潜伏的隐患。**

第一轮的 `ksu_handle_execve_ksud()` 直接调 `strncpy_from_user_nofault()` 读 execve 的
路径字符串。这在多数情况下能成功，但**并非总是**：

`arch/arm64/kernel/ptrace.c` 的 `syscall_trace_enter()` 是在
`rcu_read_lock_sched()` 保护下调用 `trace_sys_enter()` 的 —— 也就是**原子上下文**
（`preempt_count() != 0`）。原子上下文里**不允许触发页错误**，
因此当路径字符串所在页面未驻留时，`strncpy_from_user()` 直接返回 `-EFAULT`。

**实证（v19 启动日志，`/data/adb/ksu/log/dmesg.log`）**：

```
KernelSU: Access filename failed for execve_handler_pre     ← 我新加的函数，1010 条
KernelSU: Access filename failed, try rescue..              ← sucompat.c 原有的，4 条
```

刷屏只是表象。真正的风险在于：`ksu_handle_init_mark_tracker()`（第一轮未改动的上游
函数）**也有同样的问题，且失败是静默的**。它的职责是识别 `init` 执行 `/data/adb/ksud`
并调 `escape_to_root_for_init()` 给 ksud 提权：

```c
if (unlikely(strcmp(path, KSUD_PATH) == 0)) {
    escape_to_root_for_init();      // 读不到 path 就永远进不来
}
```

一旦某次开机的路径页恰好未驻留，`path` 为空 → ksud 拿不到 root →
`post-fs-data` 静默失败 → **模块又回到"重启不生效"**。这是个偶发的定时炸弹。

**上游其实早有对策**：`sucompat.c:ksu_handle_execve_sucompat()` 里有一段"逃生"逻辑，
临时退出原子上下文把页错误处理掉再恢复：

```c
if (ret < 0 && preempt_count()) {
    /* This is crazy, but we know what we are doing:
     * Temporarily exit atomic context to handle page faults, then restore it */
    preempt_enable_no_resched_notrace();
    ret = strncpy_from_user(path, fn, sizeof(path));
    preempt_disable_notrace();
}
```

第一轮新增的两个函数**没有抄这段**，这就是根因 5。

### 根因 6 —— 缺少前置过滤，全系统每次 execve 都去读用户态路径（v21 修）

补上逃生逻辑后，报错**换了个名字继续出现**：

| 版本 | `Access filename failed for execve_handler_pre` | `Access filename when execve failed` | `try rescue` |
|---|---|---|---|
| v18（改动前） | 0 | 0 | 21（sucompat 的） |
| v19 | **1006** | 4 | 4 |
| v20 | 0 | **1002** | 0 |

v20 那 1002 条其实是**我自己的函数打的** —— 修根因 5 时我把 `pr_err` 改成了
`pr_warn("Access filename when execve failed: %ld\n", ret)`，**文案与 sucompat 那句
一模一样**，一度让人误以为是 sucompat 在报错。（教训：改日志文案时不要抄别处的原句，
否则计数变化会误导定位。）

失败者的身份很说明问题：

```
814  main                 ← 各种系统 App 的 Java 主线程
 68  pool_hiplay_iot
 50  huawei.hiaction
 27  ilink.framework
 10  hwid.persistent
  9  tant:interactor
 ...（全是 uid ≥ 1000 的系统应用）
```

而 `sys_execve su found` 整个开机只出现 **1 次** —— 与 su 完全无关。

**对照 sucompat 为什么只有 21 条**：它有廉价前置门

```c
if (!ksu_is_allow_uid_for_current(current_uid().val)) {
    write_sulog('$');
    return 0;      // 绝大多数进程在这里就返回了，根本不去读路径
}
```

而 `ksu_handle_execve_ksud()` **没有任何前置门**，对全系统每一次 execve 都尝试读路径。
1002 次里绝大多数必然失败（原因见下），于是刷屏。

> **为什么这些读取会失败？** 本函数只需要识别两种情况：
> ① `init` 执行 `/system/bin/app_process -Xzygote`（zygote 首次启动）；
> ② `init` 执行 `/system/bin/init second_stage`（Android 10+）。
> 两者发起者都是 uid 0 的 init 或其未 setuid 的 root 子进程。
> 系统 App（uid ≥ 1000）的 execve 根本不在关心范围内，读它既无意义、
> 失败也是必然的（`-14 = -EFAULT`）。

**v21 修法**：加等价的前置门，直接跳过不关心的进程。

```c
if (unlikely(current->pid != 1 && current_uid().val != 0 &&
             strcmp(current->comm, "init")))
    return 0;
```

**收益**：每次开机少 1000 条内核警告。这不只是"干净"的问题 ——
系统 dmesg 环形缓冲只有约 8000 行，**正是这 1000 条噪声把早期启动证据挤出去的**，
反过来又让人查不到 `read init.rc` / `exec zygote` 等关键标记（本项目踩过这个坑）。

**风险很低**：`on_post_fs_data()` 有**两个**触发源 —— ksud 发 `EVENT_POST_FS_DATA`
（实测在 19.86s 先触发）与 zygote 识别（21.21s，日志显示 `already done`）。
即使 zygote 识别路径出问题，ksud 的路径仍然保证模块链路可用。

### 根因 7 —— 门条件里的 `uid != 0` 把 zygote 也放进来了（v22 修）

v21 的过滤方向对了，但**条件写宽了**：刷入后噪声从 1002 只降到 **965**，仍有刷屏。

对比 v20 / v21 的失败进程分布，一眼看出过滤**部分生效**：

| 进程 | v20 | v21 |
|---|---|---|
| `[pid:1916/1919,main]` | 158 | 157 |
| `[pid:561/563,main]` | 80 | 85 |
| `huawei.hiaction` | 30 | **0** |
| `ilink.framework` | 22 | **0** |
| `pool_hiplay_iot` | 14+9+6… | **0** |
| `tant:interactor` | 6 | **0** |

uid ≥ 1000 的系统 App **全部被过滤干净**（说明门确实在工作），
但 comm 为 `main` 的进程一个没少 —— 它们**都是 uid 0**，被 `uid != 0` 这一条放行。

在设备上核对身份：

```
  561     1 root         zygote64
  563     1 root         zygote
```

**`zygote` / `zygote64` 本身就是 uid 0、comm 为 `main` 的进程**
（Android 的 zygote 由 init 以 root 启动，`app_process` 的 main 线程把 comm 改成了 `main`）。
它们运行期 fork/exec 时，每一次 execve 都因 `uid==0` 通过门 → 读路径 → 报错，965 条由此而来。

用 `sulog.log` 做了交叉验证：整次开机只有 **209 个 `$`**（sucompat 的 uid 门拦截计数），
远少于 965 —— 说明这 965 条**不是** sucompat 打的，确实是本函数打的。

**v22 修法**：去掉 `uid != 0`，只保留精确命中的两个条件。

```c
if (unlikely(current->pid != 1 && strcmp(current->comm, "init")))
    return 0;
```

- `pid == 1`：init 本身（覆盖 Android 10+ 的 `second_stage`）。
- `comm == "init"`：init **fork 出**的子进程 —— 它在 `execve` **之前** comm 仍继承父进程的
  `"init"`，这正是"init 启动 zygote"那一刻。`sys_enter` 钩子恰好在 execve 入口触发，所以能抓到。

zygote 之后的任何 execve，comm 已是 `main` / `app_process32/64`，一律被过滤。

**收益**：噪声 965 → **0**，同时 `read init.rc` / `exec zygote` / `post-fs-data triggered` /
`on_post_fs_data` 四个功能标记一个不少。

> **教训**：用 uid 做门要格外小心 —— **Android 的 zygote 系进程全部是 uid 0**，
> `uid == 0` 并不等价于"init 或其子进程"。能用 `comm` + `pid` 精确定位时，不要退化成 uid 判断。

### 根因 8 —— `list_try_umount()` 没有分配上限（v23 修）

v22 之后功能已全绿，于是做了一轮**全面体检**，在 `/data/adb/ksu/log/dmesg.log` 里发现
每次开机有 1 条 `WARNING` + 上百行栈转储：

```
WARNING: CPU: 7 PID: 1514 at ../mm/page_alloc.c:3763 __alloc_pages_nodemask+0xab4/0x...
Call trace:
 __alloc_pages_nodemask+0xab4
 kmalloc_order+0x24
 __kmalloc+0x50
 list_try_umount+0xd8        ← 分配点
 anon_ksu_ioctl+0x74
 SyS_ioctl
```

根因是这一行**没有上限校验**：

```c
output_size = cmd.buf_size ? cmd.buf_size : 4096;
output_buf = kzalloc(output_size, GFP_KERNEL);   // 调用方传多大就申请多大
```

- 内核 `CONFIG_FORCE_MAX_ZONEORDER=11` → **order ≥ 11（即 ≥ 8MB）的连续分配会 WARN**
  并打印整条栈（这是 buddy allocator 的"我做到了但你别这么干"告警）。
- `ksud umount list` 自己只传 `BUF_SIZE = 4096`，**不是**触发者；
  真正传大值的是管理器 App（它想一次拿到完整挂载点列表）。
- 实测：内存充足（`MemAvailable` 3.2GB），**不会 OOM**，纯属噪声。
- 手动执行 `ksud umount list` 复现不出来，因为该路径只申请 4096 字节。

**v23 修法**（三点）：

```c
const size_t umount_list_max = 2 * 1024 * 1024;  /* 2MB hard cap */
if (output_size > umount_list_max)
    output_size = umount_list_max;               /* ① 夹紧而非拒绝 */

output_buf = kzalloc(output_size, GFP_KERNEL | __GFP_NOWARN);  /* ② 静音 */
if (!output_buf) {
    output_buf = vzalloc(output_size);           /* ③ 非连续回退 */
    using_vmalloc = true;
}
...
if (using_vmalloc) vfree(output_buf); else kfree(output_buf);
```

**为什么"夹紧"而不是像上游 `supercall/dispatch.c` 那样 `return -EINVAL`**：
调用方可能是管理器 App，硬拒绝会打断它的列表读取。而"挂载点列表"本身永远只需要几 KB，
截断分配是**无害**的 —— 因为回写始终只拷 `offset` 字节，且
`offset <= output_size <= cmd.buf_size`，用户缓冲区**不可能溢出**。

> ⚠️ 注意：**不要**照抄上游 `dispatch.c` 的新版实现。它把 `output_size` 重算成
> `1024 + mount_count*200` 之后，却仍 `copy_to_user(cmd.arg, output_buf, offset)` ——
> 当挂载点多于用户给的缓冲大小时会**溢出用户缓冲区**。本项目保留了
> "以 `cmd.buf_size` 为准"的语义，只加上限。

**收益**：开机 WARNING 从 2 条降到 1 条（剩下那条是华为固件自己的，见下），
上百行栈转储消失；`ksud umount list / add / remove` 实测功能不变。

### 根因 9 —— `stop_init_rc_hook()` 缺一次性门（v23 修）

每次开机日志里有 **37 条**完全相同的：

```
KernelSU: unregister init_rc_hook kprobe: 1!
```

原设计意图是：kprobe 一注销，`ksu_handle_sys_read()` 就**不会再被调用**，
所以 `rc_hooked` 这个静态门之后的 `stop_init_rc_hook()` 天然只会跑一次。
但本机 `CONFIG_KPROBES=n`（根因 1），实际驱动它的是**常驻的 syscall tracepoint** ——
注销 kprobe 对 tracepoint 毫无影响，于是 init 每读一次 init.rc 就重复执行一次注销。

init 是**分块循环读** init.rc 的（`read_iter` 直到 EOF），实测 37 次读 → 37 条日志。

**v23 修法**：照抄同文件里 `stop_input_hook()` 已有的写法，加一个静态一次性门。

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

（`stop_input_hook()` 早就有这个门，`stop_init_rc_hook()` 漏了 —— 属实现不一致。）

**收益**：37 条 → **1** 条；且避免了 `stop_init_rc_hook_work` 被反复重新入队
（`schedule_work` 在 work 跑完后会**重新排队**，等于把 `unregister_kprobe` 反复执行 37 次）。

---

### 根因 10 —— fstat / input_event 两个钩子没有替代实现（v24 修）

v19–v23 只迁走了 `execve` 与 `read`，剩下两个**直接放弃**了，理由是"用不上"。
v24 复查发现两个理由都站不住：

- **`sys_fstat_kp`**：原判断是"Android 9 的 init 用循环 `read()`，不需要修正 `st_size`" ——
  对 Android 9 成立，但**钩子本身仍应存在**（Android 10+ 的 init 会用 `fstat` 预分配缓冲区，
  届时缺了它 `KERNEL_SU_RC` 的尾段会被截断）。而且上游的实现路线在本机**根本走不通**：
  - `CONFIG_KPROBES=n` → `register_kretprobe()` 恒 `-ENOSYS`；
  - **arm64 上不存在 `__arm64_sys_newfstat` 这个符号**（那是 x86 的命名），
    即便打开 KPROBES 也会 `-ENOENT`。
- **`input_event_kp`**：原判断是"本机音量键物理损坏，无用途" —— **这个前提是错的**（见根因 11）。
  而且 4.9 **没有 input 子系统 tracepoint**（`include/trace/events/` 下无 `input.h`），
  所以也没有 tracepoint 可用。

**结论**：两者都只能走**源码级直钩** —— 与 `kernel/reboot.c` 的 SukiSU 超级调用同一手法
（`#ifdef CONFIG_KSU` + 函数内 `extern` + `ZCODE_KSU_*` 注释标记）。

### 根因 11 —— "音量键物理损坏"是误判（v24 纠正）

项目从早期就记录"音量键物理损坏 → 无按键进 fastboot/recovery"。v24 实测**证伪**：

```
/dev/input/event1 = hisi_gpio_key，注册 KEY_VOLUMEDOWN + KEY_VOLUMEUP
按音量下 → volume_music_speaker 从 8 → 0
按音量上 → 0 → 8
sendevent /dev/input/event1 1 114 1/0 注入同样生效
```

后果：**P4b（音量键安全模式）其实一直是可用的功能**，此前被错误地放弃。

> ⚠️ 但"能进 fastboot/recovery"仍需独立验证（按键组合是否被 bootloader 接受）。
> 文档里所有"救援靠 `adb reboot bootloader`"的结论**不变**。

### 根因 12 —— SELinux 规则从未加载（双层根因，v24 修）

这是 v24 最重的一块，两层都要修：

**第一层：`sepolicy.c` / `rules.c` 在 4.9 上被整体编译成空桩**

```c
#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 2, 0)
    ... 整个内核态策略改写引擎 ...
#else
    /* 空桩：所有函数 return false / -EOPNOTSUPP */
#endif
```

守卫写的是 `5, 2, 0`，本机 `4.9.148` → **引擎是空的**。改为 `4, 9, 0` 后需移植 5 处 ABI 差异
（`selinux_state.policy` → 全局 `policydb`；`type_attr_map_array` → `type_attr_map`；
华为 4.9 的 `ebitmap_init()` 是 **2 参**；`struct filename_trans` **含 stype** 且
`hashtab_insert()` 是 3 参；4.9 无 `kvmalloc()`）。另需注意 4.9 的 `filename_trans`
查询被 `filename_trans_ttypes` 位图门控，新增规则必须同时 `ebitmap_set_bit()`。

**第二层：`apply_kernelsu_rules()` 在 Android 9 上从不被调用**

`apply_kernelsu_rules()` + `cache_sid()` + `setup_ksu_cred()` 三连调用**只**出现在
`ksu_handle_execveat_ksud()` 的 `/system/bin/init` + `second_stage` 分支
（源码注释写明 "This applies to versions Android 10+"）。Android 9 既没有
`/system/bin/init` 也没有 `second_stage` → 三连从未执行。

**后果**：一条 KSU 规则都没加载（su 域 446 条 `avc: denied`）；
`ksu_file_sid == 0`（`KSU_IOCTL_GET_WRAPPER_FD` 恒返回 `-EINVAL`）；
`ksu_cred` 未切到 `u:r:su:s0`。

**修法**：新增幂等 workqueue `ksu_apply_selinux_rules_async()`，在两个时机调度 ——
主路径是 init 首次读 `/init.rc` 那一刻（本机 16.02s，SELinux 策略 15.86s 已加载），
兜底是 `on_post_fs_data()`。**必须走 workqueue**：这三个函数里有 `mutex_lock()`，
而 `ksu_handle_sys_read()` 跑在 `sys_enter` tracepoint 的原子上下文里。

**时序余量**：规则应用 **16.05s** → init 执行 ksud **19.92s**，**3.87s** ——
这正是"将来能安全切回 Enforcing"所必需的最早可用时机。

---

## 三、修复方案

**设计原则：沿用本项目已验证可用的机制。**
`kernel/reboot.c` 的超级调用当初就是因为"华为内核 kprobe 不可用"而改成源码级直钩；
`sucompat` / `setresuid` / `mark_tracker` 则走 **syscall tracepoint**
（`register_trace_sys_enter`，依赖 `CONFIG_FTRACE_SYSCALLS=y`，本机已启用）。
**tracepoint 路径在设备上是被证实工作的**：

```
[   42.151580s][pid:1692,cpu4,main]KernelSU: handle_setresuid from 0 to 1000
[   47.937103s][pid:1991,cpu3,init]KernelSU: hook_manager: unmark 1991 exec /vendor/bin/wpa_supplicant
```

（`handle_setresuid` 与 `ksu_handle_init_mark_tracker` 只可能由
`ksu_sys_enter_handler` 调用。）

因此把 ksud 集成从**失效的 kprobe** 迁到**可用的 tracepoint**，
而不是去打开 `CONFIG_KPROBES`（那要全量重编，且 kprobe 在本内核的可用性未经验证）。

| # | 修复 | 文件 |
|---|---|---|
| 1 | 新增 `ksu_kernel_read()`/`ksu_kernel_write()` 4.9 适配层 | `ksu_compat_49.h` |
| 2 | 21 处调用点改用适配层 | `allowlist.c` `apk_sign.c` `throne_tracker.c` |
| 3 | `is_init_rc()` 同时接受 `/init.rc` 与 `/system/etc/init/hw/init.rc` | `ksud.c` |
| 4 | 新增 `ksu_handle_execve_ksud()`，由 tracepoint 驱动 | `ksud.c` / `ksud.h` |
| 5 | `ksu_handle_sys_read()` 去掉 `static`，对外可见 | `ksud.c` / `ksud.h` |
| 6 | tracepoint 增加 `__NR_read` 与 ksud 的 execve 分支 | `syscall_hook_manager.c` |
| 7 | 顺带补 `copy_{from,to}_user_nofault` 兼容映射（5.8+ API，原为隐式声明） | `ksu_compat_49.h` |
| **8** | **`ksu_handle_execve_ksud()` 补 preempt 逃生逻辑（修根因 5）** | **`ksud.c`** |
| **9** | **`ksu_handle_init_mark_tracker()` 补 preempt 逃生逻辑（消除偶发静默失败）** | **`syscall_hook_manager.c`** |
| **10** | **`sucompat.c` 的 `try rescue` 日志 `pr_info` → `pr_debug`（降噪）** | **`sucompat.c`** |
| **11** | **`ksu_handle_execve_ksud()` 加前置过滤（v21，但条件写宽了）** | **`ksud.c`** |
| **12** | **收紧该过滤为 `pid==1 \|\| comm=="init"`，去掉 `uid != 0`（修根因 7）** | **`ksud.c`** |
| **13** | **`list_try_umount()` 加 2MB 分配上限 + `__GFP_NOWARN` + `vzalloc` 回退 + 正确释放（修根因 8）** | **`supercalls.c`** |
| **14** | **`stop_init_rc_hook()` 加静态一次性门，与 `stop_input_hook()` 对齐（修根因 9）** | **`ksud.c`** |
| **15** | **`sepolicy.c` / `rules.c` 版本守卫 `5.2.0` → `4.9.0`，并移植 5 处 4.9 ABI 差异（修根因 12 第一层）** | **`selinux/sepolicy.c` `selinux/rules.c`** |
| **16** | **新增幂等 workqueue `ksu_apply_selinux_rules_async()`，在 init 读 `/init.rc` 时 + `on_post_fs_data()` 兜底调度（修根因 12 第二层）** | **`ksud.c` / `ksud.h`** |
| **17** | **`fs/stat.c:vfs_fstat()` 源码级直钩 `ksu_fixup_init_rc_stat()`；删除 `sys_fstat_kp` 的 kretprobe（修根因 10）** | **`fs/stat.c` `ksud.c`** |
| **18** | **`drivers/input/input.c:input_event()` 源码级直钩 `ksu_handle_input_handle_event()`，用 `ksu_input_hook_active` 开关替代 kprobe 注销（修根因 10/11）** | **`drivers/input/input.c` `ksud.c`** |
| **19** | **6 条既有编译警告清零（`linux/security.h`、`linux/random.h`、`#undef`、`extern`）** | **`selinux/selinux.c` `manual_su.c` `sucompat.c` `su_mount_ns.c`** |

补丁规模：**+271 / -38，9 个文件**（1–7 为第一轮 v19，8–10 为第二轮 v20，11 为第三轮 v21，
12 为第四轮 v22，13–14 为第五轮 v23）。

**v24 追加**：15–19，另有 `drivers/kernelsu/ksud.c` / `ksud.h` 的相应改动，
详见 `PATCHES.md` K.6；补丁为 `patches/v24_fixes.patch`（5 文件，已验
`APPLY_CHECK_OK` + `BYTE_IDENTICAL_OK`）+ `patches/v24_sources/`（10 文件完整源码）。

**v24 后 4 个 ksud 钩子的驱动路径**：

| 钩子 | 驱动机制 | 入口 |
|---|---|---|
| `execve` | syscall tracepoint（`sys_enter`） | `ksu_handle_execve_ksud()` |
| `read` | syscall tracepoint（`sys_enter`） | `ksu_handle_sys_read()`（init.rc 注入 + 触发 P2） |
| `newfstat` | **源码级直钩** | `fs/stat.c:vfs_fstat()` → `ksu_fixup_init_rc_stat()` |
| `input_event` | **源码级直钩** | `drivers/input/input.c:input_event()` → `ksu_handle_input_handle_event()` |

### 修复后的链路

```
链路 A：execve tracepoint ──► ksu_handle_execve_ksud() ──► 识别 zygote
                                                  └─► task_work → on_post_fs_data()
                                                          └─► ksu_load_allow_list()   [适配层读盘]
       授权变化 ──► persistent_allow_list() ──► 写 .allowlist                        [适配层写盘]

链路 B：read tracepoint（仅 comm=="init"）──► ksu_handle_sys_read()
                                                └─► /init.rc 命中 → 追加 KERNEL_SU_RC
                                                        └─► init 执行 ksud post-fs-data
```

---

## 四、验证记录

### 4.1 编译与补丁（五轮均通过）

| 项目 | 结果 |
|---|---|
| 驱动目录定向编译 | `exit=0`，各文件 `CC` 通过，`LD built-in.o` 成功，**无 error / 无新增 warning** |
| 完整编译 | `make Image.gz` → `BUILD_EXIT=0`（仅有华为内核固有的 `COMMON symbol` modpost 噪声） |
| ARM64 魔数 | `41524d64`（ARMd）✓ |
| 镜像尺寸 | v19 15,155,200 B / v20–v23 15,157,248 B，均 < 分区 25,165,824 B ✓ |
| 补丁可应用性 | `git apply -p1` 通过，正式应用无 fuzz |
| 补丁结果一致性 | 应用后 9 个文件与已编译版本 **逐字节一致** ✓ |

> ⚠️ 在 Windows 上验证补丁必须写 `git -c core.autocrlf=false apply -p1 <patch>`。
> 默认 `core.autocrlf=true` 会把 LF 转成 CRLF，造成"应用成功、但逐字节比对全 DIFF"的假象。

### 4.2 设备实测（v19 → v23，均已刷入）

数据来源：`/data/adb/ksu/log/dmesg.log`（ksud 开机自动落盘的**完整**启动日志，
从 `[0.000000]` 开始 —— 系统 `dmesg` 环形缓冲太小，早期启动信息会被冲掉）。

| 标记 | v19 | v20 | v21 | v22 | **v23** | 说明 |
|---|---|---|---|---|---|---|
| `read init.rc, comm: init, rc_count: 351` | 1 | 1 | 1 | 1 | **1** | 根因 4 已修，init.rc 注入成功 |
| `init: starting service 'exec 6 (/data/adb/ksud post-fs-data)'` | ✓ | ✓ | ✓ | ✓ | **✓** | init 真的执行了 ksud |
| `hook_manager: escape to root for init executing ksud` | ✓ | ✓ | ✓ | ✓ | **✓** | ksud 拿到 root |
| `post-fs-data triggered` / `on_post_fs_data!` | ✓ | ✓ | ✓ | ✓ | **✓** | 链路 A 与 B 汇合 |
| `exec zygote, /data prepared, second_stage: 0` | 1 | 1 | 1 | 1 | **1** | zygote 识别成功 |
| `init: starting service 'exec 7 (/data/adb/ksud services)'` | — | ✓ | ✓ | ✓ | **✓** | 模块 service.sh 执行入口 |
| **`Access filename failed for execve_handler_pre`** | **1006** | 0 | 0 | 0 | **0** | **根因 5 已修** |
| **`Access filename when execve failed`** | 4 | **1002** | **965** | 0 | **0** | **根因 6/7 已修** |
| `try rescue` | 4 | 0 | 0 | 0 | **0** | 降噪生效 |
| **`unregister init_rc_hook kprobe`** | 37 | 37 | 37 | 37 | **1** | **根因 9 已修（v23）** |
| **`list_try_umount` 出现次数** | 1 | 1 | 1 | 1 | **0** | **根因 8 已修（v23）** |
| **`page_alloc` 分配 WARNING** | 1 | 1 | 1 | 1 | **0** | **根因 8 已修（v23）** |
| `allowlist file invalid: 2026!` | ✓（报错） | — | — | — | **—** | v18 留下的 0 字节脏文件，已被正确覆盖 |
| `allowlist version: 3` + `load_allow_list read err: 0` | — | ✓ | ✓ | ✓ | **✓** | **读回成功** |

**链路 B（模块）功能验证**：

```
/data/adb/ksu/log/modules_info : zygisk_lsposed 64 fd=9 / 32 fd=10   ← 模块已挂载
ps -A                          : lspd (883)                          ← LSPosed 守护进程
                               : zn-zygisk-companion64 zygisk_lsposed
                               : zn-zygisk-companion32 zygisk_lsposed  ← v19 时只有 64 位
/data/adb/modules/WorkSettingPro/Log.txt :
    2026年10月02日00:38:10 : 执行文件｜.../service.d/service.sh       ← 上一次开机
    2026年10月02日00:49:46 : 执行文件｜.../service.d/service.sh       ← 本次开机，证明可重复
```

**链路 A（授权）功能验证**：

```
/data/adb/ksu/.allowlist : 55 53 4b 7f | 03 00 00 00 | 02 00 00 00 | "com.android.shell" ...
                           └ magic    └ version 3  └ count 2      └ 条目 + "u:r:su:s0"
                        1560 字节，非 0，格式合法
```

### 4.3 刷入后自查（无需 PC）

```bash
su -c 'grep -E "read init.rc|on_post_fs_data|exec zygote|allowlist" /data/adb/ksu/log/dmesg.log'
```

> ⚠️ 用 `/data/adb/ksu/log/dmesg.log` 而**不要**用 `dmesg`：系统环形缓冲只有约 8000 行，
> 开机几十秒后早期启动信息（1~25s）就已被冲掉，直接 `dmesg` 会查不到任何标记。

期望看到：

```
KernelSU: read init.rc, comm: init, rc_count: 351        ← 根因 4 已修
KernelSU: exec zygote, /data prepared, second_stage: 0    ← 根因 1/2 已修
KernelSU: allowlist version: 3                            ← 根因 3 已修（读回成功）
KernelSU: load_allow_list read err: 0
```

以及：

```bash
su -c 'grep -c "Access filename failed" /data/adb/ksu/log/dmesg.log'   # 应为 0
su -c 'ls -l /data/adb/ksu/.allowlist'                                # 应为非 0 字节
su -c 'cat /data/adb/ksu/log/modules_info'                            # 应列出已挂载模块
su -c 'ps -A | grep -E "lspd|zygisk"'                                 # 应有守护进程
```

### 4.4 v22 刷入验证（最终态）

内核版本：`4.9.148-<自定义后缀> #14 SMP PREEMPT Thu Oct 1 17:23:27 UTC 2026`。

| 检查项 | 方法 | 结果 |
|---|---|---|
| 分区写入 | 读回 `dd` 后**截断到镜像长度**再 sha256 | `a75f7412…466d9` = 镜像 ✓ |
| 噪声清零 | `grep -c "Access filename when execve failed" dmesg.log` | **0** ✓ |
| `execve_handler_pre` | 同上 | **0** ✓ |
| `try rescue` | 同上 | **0** ✓ |
| 功能标记 | `read init.rc` / `exec zygote` / `post-fs-data triggered` / `on_post_fs_data` | **1 / 1 / 1 / 2**，一个不少 ✓ |
| 授权持久化 | `ls -l /data/adb/ksu/.allowlist` | 1560 B，**mtime 未变**（开机只读回、未改写）✓ |
| 模块挂载 | `modules_info` + `ps` | `zygisk_lsposed 64 fd=9 / 32 fd=10`；`lspd` + 双 companion ✓ |

> **刷机脚本的一个坑**（本次踩到）：`flash_phone.ps1` 的读回校验一度报
> `READBACK MISMATCH`，但分区其实是写对的。原因是 PowerShell 里写
> `su -c "head -c N f > out"` 会被拆成多个 argv，adb 再用空格拼接，远端只拿到
> `su -c head`，而 `>` 重定向由**非 root** shell 执行 → 权限不足静默失败 →
> 读到的还是上一版遗留的旧文件。正确写法是**外层双引号 + 内层单引号**：
> `& $adb shell "su -c 'head -c N f > out'"`。脚本已修（v23 轮把**全部** `su` 调用
> 统一改成该形式，不再只修读回那一处）。

### 4.5 v23 刷入验证（最终态）

内核版本：`4.9.148-<自定义后缀> #15 SMP PREEMPT Thu Oct 1 17:53:45 UTC 2026`。

| 检查项 | 方法 | 结果 |
|---|---|---|
| 分区写入 | 读回 `dd` 后**截断到镜像长度**再 sha256 | `519ea860…85f2` = 镜像 ✓ |
| **根因 8** | `grep -c "list_try_umount" dmesg.log` / `grep -c "WARNING: CPU.*page_alloc"` | **0 / 0** ✓ |
| **根因 9** | `grep -c "unregister init_rc_hook" dmesg.log` | **1**（原 37）✓ |
| 噪声清零 | `grep -c "Access filename when execve failed"` | **0** ✓ |
| 功能标记 | `read init.rc` / `exec zygote` / `post-fs-data triggered` / `on_post_fs_data` | **1 / 1 / 1 / 2**，一个不少 ✓ |
| init.rc 注入完整性 | `read_iter_proxy: append 351` + `append done` | 两个都在 ✓ |
| 授权持久化 | `ls -l /data/adb/ksu/.allowlist` | 1560 B，**mtime 未变**（开机只读回、未改写）✓ |
| 授权内容 | 日志 `load_allow_uid` | `com.android.shell`(2000) + `com.byyoung.setting`(10186)，均 `allow: 1` ✓ |
| 模块挂载 | `modules_info` + `ps` | `zygisk_lsposed 64 fd=9 / 32 fd=10`；`lspd`(874) ✓ |
| root | `su -c 'id'` | `uid=0(root) … context=u:r:su:s0` ✓ |
| **加固后功能回归** | `ksud umount list` / `add` / `remove` | 空列表只出表头；add 后列出 `/test/v23/path 0`；remove 成功；**全程无 WARNING** ✓ |
| 剩余唯一 WARNING | `grep "WARNING:" dmesg.log` | 仅 1 条，且是华为固件自身问题（见下）✓ |

**剩下的那 1 条 WARNING 与 KernelSU 无关**：

```
[   12.328033] [pid:1,cpu7,swapper/0]Attribute fsync_enabled: Invalid permissions 0755
[   12.328063] [pid:1,cpu7,swapper/0]WARNING: CPU: 7 PID: 1 at ../fs/sysfs/group.c:59 internal_create_group+0x26c/0x2a0
```

华为 `param_sysfs_init` 注册了一个权限为 `0755` 的 sysfs 属性，而 sysfs 只接受
`0644`/`0444` 之类，于是 `internal_create_group()` 报 WARNING。**原厂内核同样存在**，
属华为驱动自身的写法问题，与本项目改动无关，不值得为它去改华为的驱动。

### 4.6 v24 刷入验证（最终态）

内核版本：`4.9.148-<自定义后缀> #18 SMP PREEMPT Thu Oct 1 19:04:05 UTC 2026`。

| 检查项 | 方法 | 结果 |
|---|---|---|
| 分区写入 | 读回 `dd` 后**截断到镜像长度**再 sha256 | `7f58dae0…06be` = 镜像 ✓ |
| 编译 | `CC_EXIT` / `CC_ERRORS` / `CC_WARNS` | **0 / 0 / 0**（6 条警告清零）✓ |
| **根因 12（P2）** | `grep "selinux rules applied" dmesg.log` | `ksu: selinux rules applied, ksu_file_sid: 302` @16.05s ✓ |
| **根因 12** | `grep "Cached ksu_file SID"` | **302**（此前恒为 0）✓ |
| **根因 12** | `grep -c "scontext=u:r:su" dmesg.log` | **0**（原 446）✓ |
| **根因 12** | `grep -c "avc:  denied" dmesg.log` | **301**（原 609；去重后 120 vs 161）✓ |
| **根因 10（P4a）** | `System.map` + `objdump -d out/fs/stat.o` | `bl ksu_fixup_init_rc_stat` @0x7d4 ✓ |
| **根因 10（P4b）** | `objdump -d out/drivers/input/input.o` | `adrp x0,<ksu_input_hook_active>` @0x2020 + `bl ksu_handle_input_handle_event` @0x2084 ✓ |
| **根因 10（P4b）** | `grep "stop input hook" dmesg.log` | 1 条 @19.97s（状态机在跑）✓ |
| 功能标记 | `read init.rc` / `exec zygote` / `post-fs-data triggered` / `on_post_fs_data` | **1 / 1 / 1 / 2**，一个不少 ✓ |
| 回归：根因 8 | `grep -c "list_try_umount"` / `page_alloc` WARNING | **0 / 0**（未回退）✓ |
| 回归：根因 9 | `grep -c "unregister init_rc_hook"` | **1**（未回退）✓ |
| 回归：噪声 | `grep -c "Access filename when execve failed"` | **0** ✓ |
| 授权持久化 | `ls -l /data/adb/ksu/.allowlist` | 1560 B 非空 ✓ |
| 模块挂载 | `cat /data/adb/ksu/log/modules_info` | `zygisk_lsposed 64 fd=9 / 32 fd=10` ✓ |
| root | `su -c 'id'` | `uid=0(root) gid=0(root) groups=0(root) context=u:r:su:s0` ✓ |
| 剩余唯一 WARNING | `grep "WARNING:" dmesg.log` | 仍 **1** 条，且与 v23 **逐字相同**（华为固件自身）✓ |

**根因 11（P4b）的启动期端到端实测 —— 2026-10-02 通过（物理按键，内核 #18 / v24）**：

| 环节 | 实测证据 |
|---|---|
| 钩子被触发 | `KEY_VOLUMEDOWN val: 1` @ **13.371 / 13.496 / 15.048**（3 次按下，另有 2 次 `val: 0` 抬起） |
| 阈值分支执行 | `stop input hook` @ **15.048675** —— 与第 3 次按下**同一微秒**；基线（无按键）时该行固定在 **19.968s**（`on_post_fs_data()` 无条件调用），**提前 4.92s 即达标铁证** |
| 安全模式判定 | `volumedown_pressed_count: 3` + `KEY_VOLUMEDOWN pressed max times, safe mode detected!` @ **20.184** |
| 内核上报 ksud | `ksud::utils: kernel_safemode: true`（`supercalls.c:145` 的 `cmd.in_safe_mode`） |
| 落地效果 | `safe mode, skip common post-fs-data.d scripts` / `safe mode, skip post-fs-data scripts and disable all modules!` / `skip service scripts` / `skip boot-completed scripts` |
| 恢复 | 重启后 `stop input hook` 回到 19.875s、计数 0、SELinux 规则照常（15.914s）、LSPosed 重新注入 |

> ⚠️ 两个易误读点：
> 1. `safemode: false` 是**用户态**标记；`kernel_safemode: true` 才是**内核**上报（P4b 的产物）。
> 2. **无法用软件注入自动化**：钩子门在 `on_post_fs_data()`（≈19.97s）关闭，而 adbd 首启在 **22.05s**；
>    且 `sendevent` 裸写 evdev 走 `input_inject_event()`（绕过 `input_event()`）。**只能人工物理按键**。
>    窗口约 **2s ~ 19.97s**，阈值 3 次。
>
> ⚠️ **副作用**：进入安全模式后，SukiSU 管理器会把**三个模块全部禁用**
> （`KsuCli module disable ... result: true`，实测 06:58:27–29），**测试后必须检查并恢复模块开关**
> （实测 06:59:23–26 已恢复）。安全模式本身**不写** `disable` 文件，禁用是管理器 App 的行为。
>
> 完整证据归档：`_work/fix/artifacts/safemode_test/EVIDENCE.md`（含 `dmesg.log` / `logcat.log` / 恢复验证）。

---

## 五、尚未处理 / 已知取舍

1. ~~**`sys_fstat_kp`（修正 init.rc 的 `st_size`）没有迁移。**~~ → **v24 已迁移**，
   改为 `fs/stat.c:vfs_fstat()` 源码级直钩（原因见 根因 10）。Android 9 的 init
   用 `ReadFdToString()`（`while (read(...) > 0)` 循环读）而不是 `fstat` 预分配，
   所以本钩子在 Android 9 上是**休眠但正确**的；Android 10+ 的 init 会用到它。
2. ~~**`input_event_kp`（音量键安全模式）没有迁移。** 本机音量键物理损坏，无实际用途。~~
   → **v24 已迁移**，改为 `drivers/input/input.c:input_event()` 源码级直钩。
   且"音量键物理损坏"这个前提**本身就是错的** —— 实测 `hisi_gpio_key`
   在 `/dev/input/event1` 注册了 `KEY_VOLUMEDOWN`+`KEY_VOLUMEUP`，按音量下使
   `volume_music_speaker` 从 8 → 0、按音量上 0 → 8。见 根因 11。
3. **kprobe 注册调用保留未删**（`ksu_ksud_init()`），失败无副作用
   （`unregister_kprobe` 同样是空桩），仅为最小化改动；已在源码中加注释说明。
   > v24 起 `fstat` / `input_event` 的 kprobe 注册**已删除**（避免将来打开 KPROBES
   > 时与源码直钩**重复处理**：st_size 会被加两次、音量键按 2 次就触发安全模式）；
   > `execve` / `read` 的注册保留（两者都幂等，见源码注释）。
4. **`arch.h` 的 `__arm64_sys_*` 符号名未改。** 因为已不使用 kprobe，
   改与不改都不影响运行；保留原样可避免后人误开 `CONFIG_KPROBES` 后
   出现 kprobe 与 tracepoint **双路重复处理**（execve 会被处理两次）。
5. **未开启 `CONFIG_KPROBES`。** 见第三节设计原则。
6. **preempt 逃生逻辑的代价。** 每次 execve 最坏要经历
   `strncpy_from_user_nofault` → `try_set_access_flag` 重试 → preempt 逃生 三次尝试。
   实测 v20 中该分支几乎不再走到第三步（`Access filename failed` = 0），
   因此热路径开销可忽略。但**这段代码本身是有风险的**：它在 tracepoint 回调里
   短暂打开抢占。上游 KernelSU 长期在生产环境使用同一手法（注释原文
   "This is crazy, but we know what we are doing"），本项目只是与上游对齐，
   并非自创。若将来出现难以解释的调度异常，这里是第一嫌疑点。
7. **`ksu_handle_init_mark_tracker()` 的失败是静默的。** 第一轮未改动它，
   第二轮才发现它同样缺逃生逻辑、且失败无任何日志。已一并修复；
   如需回归排查，可临时把 `syscall_hook_manager.c` 里
   `pr_info("ksu_handle_init_mark_tracker: %ld\n", ret)` 的触发条件放宽。
8. ~~**SELinux 规则未加载（体检发现的 P2，本轮未修）。**~~
   → **v24 已修**（根因 12）。当时开机 599 条 `avc: denied`（su 域 444 条），
   `/data/adb/ksud` 的 label 是 `adb_data_file` 而**不是** `ksu_file`。
   根因是**双层**的：① `sepolicy.c` / `rules.c` 被 `#if >= 5.2.0` 整体编译成空桩；
   ② `apply_kernelsu_rules()` 三连调用只挂在 Android 10+ 的 `second_stage` 分支。
   v24 后 avc denied 609 → **301**（su 域 **446 → 0**），`ksu_file_sid` 0 → **302**。
   剩余的 301 条全部来自华为固件自身域（`vendor_init` / `untrusted_app` / `init` …），
   与原厂内核同源。**Permissive 仍是当前选择**：切 Enforcing 前需要逐条放行这些固件 denial。
9. **华为固件的 `fsync_enabled` sysfs WARNING（体检发现，与本项目无关）。**
   见 4.5 节。原厂内核同样存在，属华为 `param_sysfs_init` 的写法问题。
10. **`load average` 在这台机器上是假高。** 体检时看到 load 一度到 42，但 CPU 实际
    **719% idle**：那 41 个 D 状态进程全是华为固件的常驻内核线程
   （`bbox_main` / `smc_svc_thread` / `hisee_mntn` / `mmc-cmdqd/0`），
   它们在 `TASK_UNINTERRUPTIBLE` 下长时间等待，被计入 load 但不占 CPU。
   **不是内核问题**，排查性能时不要被这个数字误导。

---

## 六、复现步骤（环境机）

```bash
# 1) 基线：源码 + honor9_all_patches.diff（见 BUILD.md）
cd /root/kernel_src_gh

# 2) 应用 v19–v23 的修复（9 个文件，含 sucompat.c / supercalls.c）
git apply --check patches/ksud_integration_fix.patch && \
git apply        patches/ksud_integration_fix.patch
#   （或 patch -p1 < patches/ksud_integration_fix.patch）

# 3) 应用 v24 的修复（5 个文件：ksud.c/ksud.h/sucompat.c/fs/stat.c/drivers/input/input.c）
git -c core.autocrlf=false apply --check -p1 patches/v24_fixes.patch && \
git -c core.autocrlf=false apply        -p1 patches/v24_fixes.patch

# 3b) v24 还有 5 个文件（selinux 三件 + manual_su.c + su_mount_ns.c）没有可复现的
#     diff 基线，直接用 patches/v24_sources/ 下的完整源码覆盖对应路径：
#       drivers/kernelsu/selinux/{sepolicy.c,rules.c,selinux.c}
#       drivers/kernelsu/{manual_su.c,su_mount_ns.c}
#     （v24_sources/ 里其余 5 个文件与第 3 步的结果一致，可一并覆盖）

# 4) 只需重编驱动目录 + 两个直钩文件即可先做快速自检
make O=out ARCH=arm64 CROSS_COMPILE=/root/toolchain/bin/aarch64-none-linux-gnu- -j2 \
  fs/stat.o drivers/input/input.o drivers/kernelsu/
#   ⚠️ 不要直接把 drivers/kernelsu/selinux/*.o 写成 make 目标 —— 该子目录没有
#      自己的 Makefile（那些 .o 是 kernelsu-objs 的成员），Kbuild 会报
#      "No rule to make target '.../selinux/Makefile'"。用目录目标 drivers/kernelsu/ 即可。

# 5) 完整编译 + 打包
sudo -E bash scripts/build_and_pack.sh
```

> 本补丁**不改 defconfig**，因此不会触发全量重编。
> 注意环境机只有 **2 核**，增量编译 + 链接约需数分钟，请给足超时。
>
> v24 的编译自检脚本参考 `_work/build_v24.sh`（定向编译 → 统计 `error:`/`warning:` → 全量），
> 打包脚本参考 `_work/pack_v24.sh`。
