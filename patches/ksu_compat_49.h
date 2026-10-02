#ifndef KSU_COMPAT_49_H
#define KSU_COMPAT_49_H
/* Central 4.9-compat shims for SukiSU v4.1.1 driver (force-included via Kbuild) */
#include <linux/version.h>

#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 14, 0)
#ifndef TWA_RESUME
#define TWA_RESUME true
#endif
#endif

#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 8, 0)
#ifndef strncpy_from_user_nofault
#define strncpy_from_user_nofault(dst, src, n) strncpy_from_user(dst, src, n)
#endif
#endif

#ifndef __NR_clone3
#define __NR_clone3 435
#endif

#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 10, 2)
struct seccomp_filter;
static inline void ksu_seccomp_allow_cache(struct seccomp_filter *f, int nr) {}
static inline void ksu_seccomp_clear_cache(struct seccomp_filter *f, int nr) {}
#endif

#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 10, 0)
#ifndef ksys_close
#define ksys_close(fd) sys_close(fd)
#endif
#ifndef ksys_unshare
#define ksys_unshare(x) sys_unshare(x)
#endif
#endif

#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 8, 0)
#define mmap_read_trylock(mm) down_read_trylock(&(mm)->mmap_sem)
#define mmap_read_unlock(mm) up_read(&(mm)->mmap_sem)
#define mmap_write_lock(mm) down_write(&(mm)->mmap_sem)
#define mmap_write_unlock(mm) up_write(&(mm)->mmap_sem)
#endif

#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 2, 0)
#define selinux_cred(cred) ((struct task_security_struct *)((cred)->security))
#endif

#endif
