#!/system/bin/sh
# 临时诊断脚本：测量 post-fs-data 阶段 ksu_susfs 能否成功执行。
# 目的：判断管理器生成的 susfs_manager/post-fs-data.sh 里那条
#       "$SUSFS_BIN" enable_avc_log_spoofing 1 是否真的成功。
# 验证完请删除本文件。
L=/data/adb/ksu/log/avc_diag.log
{
	echo "--- $(date '+%Y-%m-%d %H:%M:%S') post-fs-data.d diag"
	echo "boot_completed=[$(getprop sys.boot_completed)]"
	echo "selinux=[$(getenforce 2>/dev/null)]"
	ls -l /data/adb/ksu/bin/ksu_susfs 2>&1
	/data/adb/ksu/bin/ksu_susfs enable_avc_log_spoofing 1
	echo "rc=$?"
	echo "recheck: /data/adb/ksu/bin/ksu_susfs enable_avc_log_spoofing 1 (second try)"
	/data/adb/ksu/bin/ksu_susfs enable_avc_log_spoofing 1
	echo "rc2=$?"
} >> "$L" 2>&1
