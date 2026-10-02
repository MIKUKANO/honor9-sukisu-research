<#
=======================================================================
 荣耀9 (STF-AL10) · Windows 侧刷入脚本（adb + dd，无需 fastboot）

 用法:
   powershell -ExecutionPolicy Bypass -File .\flash_phone.ps1 -Image ..\artifacts\kernel.img
   powershell -ExecutionPolicy Bypass -File .\flash_phone.ps1 -Adb "D:\platform-tools\adb.exe"

 流程: push → sha256 双向校验 → 备份存在性检查 → dd 写入 kernel 分区
       → sync → 读回截断校验 → reboot

 ⚠️ 刷写前务必确认手机上 /sdcard/kernel_stock.img 存在（回滚唯一依靠）。
=======================================================================
#>
param(
    [string]$Image = "",
    [string]$Adb = "",
    [switch]$SkipBackupCheck
)
$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

# ---------------------------------------------------------------------------
# 定位镜像
# ---------------------------------------------------------------------------
if ([string]::IsNullOrWhiteSpace($Image)) {
    $Image = Join-Path $PSScriptRoot '..\artifacts\kernel_sukisu.img'
}
if (-not (Test-Path -LiteralPath $Image)) { throw "image not found: $Image" }
$Image = (Resolve-Path -LiteralPath $Image).Path
Write-Host "image: $Image"

# ---------------------------------------------------------------------------
# 定位 adb：优先 -Adb 参数，其次常见位置，最后 PATH
# ---------------------------------------------------------------------------
function Find-Adb {
    param([string]$Explicit)
    $cands = @(
        $Explicit,
        (Join-Path $PSScriptRoot '..\tools\platform-tools\adb.exe'),
        (Join-Path $PSScriptRoot 'tools\platform-tools\adb.exe'),
        (Get-Command adb.exe -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source)
    )
    foreach ($c in $cands) {
        if ($c -and (Test-Path -LiteralPath $c)) { return (Resolve-Path -LiteralPath $c).Path }
    }
    throw 'adb.exe not found; pass -Adb <path>, or put platform-tools under scripts\tools\platform-tools\, or add it to PATH'
}
$adb = Find-Adb -Explicit $Adb
Write-Host "adb:   $adb"

$dev = (& $adb devices) -join "`n"
if ($dev -notmatch 'device\s*$' -and $dev -notmatch "\tdevice") { throw "no adb device online`n$dev" }

# ---------------------------------------------------------------------------
# 引号铁律（本文件所有 su 调用都必须遵守）
#   必须写成 & $adb shell "su -c '...'"（外层双引号 + 内层单引号）
#   PowerShell 会把 `su -c "cmd"` 拆成多个 argv，adb 再用空格重新拼接，
#   远端最终只看到 `su -c <第一个词>`；带 `>` / `2>&1` 时重定向由**非 root** shell
#   执行，权限不足会**静默失败** —— 结果读到的是上一次遗留的旧文件。
#   （曾踩过：读回哈希竟是上一版内核的。）
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# 1) push
# ---------------------------------------------------------------------------
& $adb push "$Image" /data/local/tmp/kernel_new.img
if ($LASTEXITCODE -ne 0) { throw 'push failed' }

# ---------------------------------------------------------------------------
# 2) sha256 双向校验（必须一致再继续）
# ---------------------------------------------------------------------------
$localHash = (Get-FileHash -LiteralPath $Image -Algorithm SHA256).Hash.ToLower()
Write-Host "local sha256: $localHash"
$phoneHash = (& $adb shell "su -c 'sha256sum /data/local/tmp/kernel_new.img'") -replace '\s.*$', ''
$phoneHash = "$phoneHash".Trim()
Write-Host "phone sha256: $phoneHash"
if ($localHash -ne $phoneHash) { throw 'sha256 MISMATCH after push - ABORT' }
Write-Host 'push verified OK'

# ---------------------------------------------------------------------------
# 3) 确认手机上的原厂备份仍在（回滚唯一依靠）
# ---------------------------------------------------------------------------
if (-not $SkipBackupCheck) {
    $bk = & $adb shell "su -c 'ls -la /sdcard/kernel_stock.img'" 2>$null
    Write-Host "backup check: $bk"
    if ("$bk" -notmatch 'kernel_stock\.img') {
        throw 'stock backup MISSING on phone - ABORT (use -SkipBackupCheck to override)'
    }
}

# ---------------------------------------------------------------------------
# 4) dd 写入 kernel 分区（EMUI 的 toybox dd 不支持 conv，用独立 sync）
# ---------------------------------------------------------------------------
& $adb shell "su -c 'dd if=/data/local/tmp/kernel_new.img of=/dev/block/by-name/kernel bs=4096'"
if ($LASTEXITCODE -ne 0) { throw 'dd write failed' }
& $adb shell "su -c 'sync'"
Write-Host 'dd write done + sync'

# ---------------------------------------------------------------------------
# 5) 读回校验
# ---------------------------------------------------------------------------
$size  = (Get-Item -LiteralPath $Image).Length
$pages = [math]::Ceiling($size / 4096)
Write-Host "image $size bytes = $pages pages, reading back..."
& $adb shell "su -c 'dd if=/dev/block/by-name/kernel of=/data/local/tmp/readback.img bs=4096 count=$pages'"
# 注意 1：$pages*4096 通常大于 $size（镜像非整数页），必须截断回 $size 再比对。
#         否则尾部残留字节会让哈希恒不相等（镜像 15157248B = 3700.5 页即会触发）。
# 注意 2：不要写成 su -c "head -c N file | sha256sum" —— SukiSU 的 su_compat 下这条
#         管道的 stdout 会丢失（返回空串，导致误报 READBACK MISMATCH）。必须拆成两步。
& $adb shell "su -c 'head -c $size /data/local/tmp/readback.img > /data/local/tmp/rb_trunc.img'"
$rbHash = (& $adb shell "su -c 'sha256sum /data/local/tmp/rb_trunc.img'") -replace '\s.*$', ''
$rbHash = "$rbHash".Trim()
Write-Host "readback sha256: $rbHash"
& $adb shell "su -c 'rm -f /data/local/tmp/readback.img /data/local/tmp/rb_trunc.img'"
if ($localHash -ne $rbHash) { throw 'READBACK MISMATCH - partition write not verified' }
Write-Host 'FLASH VERIFIED OK'

# ---------------------------------------------------------------------------
# 6) reboot
# ---------------------------------------------------------------------------
& $adb reboot
Write-Host 'REBOOTING - phone will boot the new kernel'
