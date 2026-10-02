#!/usr/bin/env python3
"""v30: strip the *real* debug overhead from Pangu_SukiSU_defconfig.

Why only three options
----------------------
The first pass also tried to drop SCHEDSTATS / TASK_DELAY_ACCT / TASK_XACCT /
TASKSTATS (to kill CONFIG_SCHED_INFO) and to move HZ 250 -> 300.  Both ideas
were dropped after checking the tree:

  * task_struct->delays is touched *directly* (no #ifdef CONFIG_TASK_DELAY_ACCT)
    by five Huawei-specific files -- mm/memory.c, kernel/sched/hwstatus.c,
    kernel/cgroup_workingset.c, drivers/allocpages_delayacct/*.c and
    include/chipset_common/allocpages_delayacct/allocpages_delayacct.h.
    Turning TASK_DELAY_ACCT off breaks the build outright
    ("'struct task_struct' has no member named 'delays'", 4 hits in mm/memory.c
    alone) and would need dozens of vendor hunks to fix properly.
  * CONFIG_SCHEDSTATS uses a static key that is *off* by default
    (schedstat_enabled() -> static_branch_unlikely(&sched_schedstats)), so it
    costs essentially nothing at runtime.
  * HZ 250 -> 300 buys a barely perceptible wakeup improvement, costs ~20% more
    timer interrupts, and risks subtle timing bugs in vendor code that we have
    no way to validate on this device.

What is actually changed
------------------------
  DEBUG_SPINLOCK=n
      With this on, do_raw_spin_lock()/do_raw_spin_unlock() are *out-of-line*
      functions in kernel/locking/spinlock_debug.c, and each one additionally
      writes lock->owner / lock->owner_cpu.  spinlocks are taken on nearly every
      syscall path (scheduler, slab, page allocator, VFS), so removing both the
      call and the two stores is the one change here with a real payoff.
      This is also what every shipping Android kernel does.

  ZSMALLOC_STAT=n
      Per-class counters on the zram alloc/free path.  This ROM runs
      swappiness=100 against a 2.24 GB zram, so that path is genuinely hot.
      Only costs /sys/kernel/debug/zsmalloc/*/stats.

  BOOTPARAM_HUNG_TASK_PANIC=n
      Huawei defaults hung_task_panic to 1, i.e. "any task stuck in D state for
      120 s => panic the kernel".  That is exactly what rebooted this phone once
      already (mmc-cmdqd/0 blocked 840 s on stalled storage I/O).  We keep
      DETECT_HUNG_TASK and the 120 s timeout, so dmesg still reports what got
      stuck -- we just stop the automatic reboot.

Deliberately NOT touched
------------------------
  TASK_DELAY_ACCT / TASK_XACCT / TASKSTATS / SCHED_INFO  see above
  SCHEDSTATS                                             see above
  HZ                                                     see above
  FRAME_POINTER      we need usable stacks for oops / hungtask reports
  FTRACE_SYSCALLS    SukiSU/SUSFS hook syscalls through the syscall tracepoints
  KALLSYMS_ALL       SukiSU resolves symbols at runtime
  SLUB_DEBUG         harmless while SLUB_DEBUG_ON is off
  DEBUG_RODATA / DEBUG_ALIGN_RODATA / DEBUG_SET_MODULE_RONX
                     page-table permissions only, zero runtime cost, real hardening
  anything under drivers/devfreq or kernel/sched (hisi/blu_*) -- vendor tuning

Usage
-----
    python tune_v30_defconfig.py [output_path]

Reads patches/Pangu_SukiSU_defconfig.  When writing in place it first makes a
one-off .v29.bak copy.  Idempotent.
"""
import os
import re
import shutil
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "patches", "Pangu_SukiSU_defconfig")

# key (without CONFIG_ prefix) -> desired literal value.
# None  =>  "# CONFIG_KEY is not set"
WANT = {
    "DEBUG_SPINLOCK": None,
    "ZSMALLOC_STAT": None,
    "BOOTPARAM_HUNG_TASK_PANIC": None,
}

# Options kconfig recomputes on its own; we only report them.
DERIVED = ["BOOTPARAM_HUNG_TASK_PANIC_VALUE", "SCHED_INFO"]


def render(key, val):
    return "CONFIG_%s=%s" % (key, val) if val else "# CONFIG_%s is not set" % key


def main():
    out_path = sys.argv[1] if len(sys.argv) > 1 else SRC
    with open(SRC, "r", encoding="utf-8", errors="surrogateescape") as fh:
        lines = fh.read().splitlines()

    pat = {
        k: re.compile(r"^(?:# )?CONFIG_%s(?: is not set|=.*)?$" % re.escape(k))
        for k in WANT
    }

    seen = {k: False for k in WANT}
    new_lines = []
    changed = []

    for line in lines:
        hit = None
        for k, p in pat.items():
            if p.match(line):
                hit = k
                break
        if hit is None:
            new_lines.append(line)
            continue
        seen[hit] = True
        want = render(hit, WANT[hit])
        if line != want:
            changed.append((hit, line, want))
        new_lines.append(want)

    appended = []
    for k, val in WANT.items():
        if not seen[k]:
            want = render(k, val)
            new_lines.append(want)
            appended.append((k, want))

    if out_path == SRC:
        bak = SRC + ".v29.bak"
        if not os.path.exists(bak):
            shutil.copy2(SRC, bak)
            print("backup  -> %s" % bak)
        else:
            print("backup  -> %s (already exists, kept)" % bak)

    with open(out_path, "w", encoding="utf-8", errors="surrogateescape") as fh:
        fh.write("\n".join(new_lines) + "\n")

    print("write   -> %s  (%d lines)" % (out_path, len(new_lines)))
    print()
    print("--- rewritten in place (%d) ---" % len(changed))
    for k, old, new in changed:
        print("  %-38s %s  ->  %s" % (k, old, new))
    if appended:
        print()
        print("--- appended (absent from source) (%d) ---" % len(appended))
        for k, new in appended:
            print("  %-38s %s" % (k, new))

    print()
    print("--- derived, recomputed by kconfig ---")
    for k in DERIVED:
        print("  %s" % k)


if __name__ == "__main__":
    main()
