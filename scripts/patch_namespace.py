#!/usr/bin/env python3
# Gate fs/namespace.c:susfs_is_mnt_devname_ksu() on the v2.3.0
# CMD_SUSFS_HIDE_SUS_MNTS_FOR_NON_SU_PROCS toggle.
#
# NOTE on ordering: this kernel is built with -Wdeclaration-after-statement,
# so the local `struct mount *mnt;` declaration MUST stay first; the early
# `return false;` guard goes after it.  Idempotent: it repairs the earlier
# (wrong-order) revision if it is already present.
p = "/root/kernel_src_gh/fs/namespace.c"
s = open(p, encoding="utf-8", errors="surrogateescape").read()

HDR_OLD = "#ifdef CONFIG_KSU_SUSFS\nbool susfs_is_mnt_devname_ksu("
HDR_NEW = ("#ifdef CONFIG_KSU_SUSFS\n"
           "#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\n"
           "extern bool susfs_is_hide_sus_mnts_for_non_su_procs_enabled;\n"
           "#endif\n"
           "bool susfs_is_mnt_devname_ksu(")

FN_HEAD = "bool susfs_is_mnt_devname_ksu(struct path *path) {\n"
GUARD = ("#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\n"
         "\tif (!susfs_is_hide_sus_mnts_for_non_su_procs_enabled) {\n"
         "\t\treturn false;\n"
         "\t}\n"
         "#endif\n")
DECL = "\tstruct mount *mnt;\n"

BAD = FN_HEAD + GUARD + DECL           # guard before declaration -> -Wdeclaration-after-statement
GOOD = FN_HEAD + DECL + GUARD          # correct order

if BAD in s:
    if s.count(BAD) != 1:
        print("FAIL reorder: count=%d" % s.count(BAD))
        raise SystemExit(1)
    s = s.replace(BAD, GOOD)
    print("namespace.c reordered (guard moved after declaration)")
elif GOOD in s:
    print("namespace.c guard already in correct order")
else:
    for old, new, name in ((HDR_OLD, HDR_NEW, "extern"), (FN_HEAD, GOOD, "gate")):
        n = s.count(old)
        if n != 1:
            print("FAIL %s: count=%d" % (name, n))
            raise SystemExit(1)
        s = s.replace(old, new)
    print("namespace.c patched (fresh apply)")

open(p, "w", encoding="utf-8", errors="surrogateescape").write(s)
print("namespace.c OK")
