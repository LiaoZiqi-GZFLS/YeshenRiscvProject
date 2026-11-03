# verify_sd.ps1 -- 只读核对 TF 卡上的镜像（不改卡）
#   read \\.\PhysicalDriveN 的前 <img> 字节 -> SHA256/MD5 与文件对比
# 用法: powershell -NoProfile -ExecutionPolicy Bypass -File sim/board/verify_sd.ps1 -Disk 2 -Img sw/images/sd_gpu0.img
param(
  [int]$Disk = 2,
  [string]$Img = "sw/images/sd_gpu0.img"
)

$ErrorActionPreference = "Stop"
$d = Get-CimInstance Win32_DiskDrive | Where-Object { $_.Index -eq $Disk }
if (-not $d) { Write-Output ("NO DISK " + $Disk); exit 2 }
Write-Output ("disk: PhysicalDrive" + $Disk + " " + $d.FriendlyName + " " + $d.InterfaceType + " " + $d.Size + " B")

$bytes = [System.IO.File]::ReadAllBytes($Img)
$nb = $bytes.Length
$shaF = [System.Security.Cryptography.SHA256]::Create()
$md5F = [System.Security.Cryptography.MD5]::Create()
$hShaF = [BitConverter]::ToString($shaF.ComputeHash($bytes)).Replace("-", "").ToLower()
$hMd5F = [BitConverter]::ToString($md5F.ComputeHash($bytes)).Replace("-", "").ToLower()
Write-Output ("file : " + $Img + "  " + $nb + " B  sha256=" + $hShaF + "  md5=" + $hMd5F)

$fs = New-Object System.IO.FileStream(("\\.\PhysicalDrive" + $Disk), [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
$buf = New-Object byte[] $nb
$g = 0
while ($g -lt $nb) { $n = $fs.Read($buf, $g, $nb - $g); if ($n -le 0) { break }; $g += $n }
$fs.Close()
if ($g -ne $nb) { Write-Output ("SHORT READ " + $g + "/" + $nb); exit 3 }

$shaC = [System.Security.Cryptography.SHA256]::Create()
$md5C = [System.Security.Cryptography.MD5]::Create()
$hShaC = [BitConverter]::ToString($shaC.ComputeHash($buf)).Replace("-", "").ToLower()
$hMd5C = [BitConverter]::ToString($md5C.ComputeHash($buf)).Replace("-", "").ToLower()
Write-Output ("card : first " + $nb + " B  sha256=" + $hShaC + "  md5=" + $hMd5C)

$eq = 0; for ($i = 0; $i -lt $nb; $i++) { if ($bytes[$i] -ne $buf[$i]) { $eq = $i; break } }
if ($hShaC -eq $hShaF) { Write-Output "CARD MATCH"; exit 0 }
Write-Output ("CARD MISMATCH first-diff-off=" + $eq); exit 1
