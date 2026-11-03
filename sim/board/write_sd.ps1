# write_sd.ps1 -- raw-write the TF card image produced by sim/mk_sd_image.py to a physical card.
#
# Method (from the Windows raw-SD lessons):
#   dismount the volume (remove drive letter) -> raw-open \\.\PhysicalDriveN
#   -> write in 64 KiB chunks -> Flush($true) (= FlushFileBuffers, forces to the device)
#   -> read back the whole image -> SHA256 compare -> remount.
# NOTE: writing on a mounted volume silently lands only the first ~4 MiB and reports no error.
#
# !! DESTRUCTIVE: this overwrites raw sectors of a disk. Verify $Disk / $Letter first with
#      Get-Disk / Get-Partition (disk numbers are machine-specific and change when you
#      replug the reader). The GUARD below refuses unless the target is a USB disk,
#      smaller than 16 GB, and larger than the image.
#
# ASCII-ONLY on purpose: this file must not contain non-ASCII bytes.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File sim\board\write_sd.ps1
#   powershell -ExecutionPolicy Bypass -File sim\board\write_sd.ps1 -Disk 3 -Letter F
param(
    [int]    $Disk   = 2,
    [int]    $Part   = 1,
    [string] $Letter = 'E',
    [string] $Img    = 'D:\code\PDS\VexiiYeshenLinux\sw\images\sd.img',
    [string] $Log    = 'D:\code\PDS\VexiiYeshenLinux\sim\reglogs\write_sd.log'
)

$ErrorActionPreference = 'Continue'
try { Start-Transcript -Path $Log -Force | Out-Null } catch { }

Write-Output ("target: PhysicalDrive" + $Disk + " partition " + $Part + " letter " + $Letter + " <- " + $Img)
if (-not (Test-Path $Img)) { Write-Output ("IMG MISSING: " + $Img); try { Stop-Transcript | Out-Null } catch { }; exit 2 }

$d = Get-Disk -Number $Disk
$p = Get-Partition -DriveLetter $Letter
$nb = (Get-Item $Img).Length
if (-not (($d.BusType -eq 'USB') -and ($d.Size -lt 16GB) -and ($p.DiskNumber -eq $Disk) -and ($d.Size -gt $nb))) {
    Write-Output ("GUARD FAIL: disk" + $Disk + " " + $d.FriendlyName + " " + $d.BusType + " size=" + $d.Size + " img=" + $nb)
    try { Stop-Transcript | Out-Null } catch { }; exit 1
}
Write-Output ("GUARD PASS: " + $d.FriendlyName + " (" + [math]::Round($d.Size/1GB,2) + "GB " + $d.BusType + ") part-on-disk=" + $p.DiskNumber)

$bytes = [System.IO.File]::ReadAllBytes($Img)
Write-Output ("image " + $nb + " bytes = " + ($nb/512) + " blocks")

$accessPath = $Letter + ':\'
$removed = $false
try { Remove-PartitionAccessPath -DiskNumber $Disk -PartitionNumber $Part -AccessPath $accessPath -Confirm:$false; $removed = $true; Write-Output ("volume " + $Letter + ": unmounted") }
catch { Write-Output ("unmount failed: " + $_.Exception.Message) }
Start-Sleep -Milliseconds 500

$ok = $false
try {
    $fs = New-Object System.IO.FileStream(("\\.\PhysicalDrive" + $Disk), [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::ReadWrite)
    $off = 0
    while ($off -lt $nb) { $len = [math]::Min(65536, $nb - $off); $fs.Write($bytes, $off, $len); $off += $len }
    $fs.Flush($true)
    $fs.Dispose()
    Write-Output ("WROTE " + $off + " bytes")
    $ok = $true
} catch { Write-Output ("WRITE FAIL : " + $_.Exception.Message) }

if ($ok) {
    try {
        $rs = New-Object System.IO.FileStream(("\\.\PhysicalDrive" + $Disk), [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $buf = New-Object byte[] $nb
        $g = 0
        while ($g -lt $nb) { $n = $rs.Read($buf, $g, $nb - $g); if ($n -le 0) { break }; $g += $n }
        $rs.Dispose()
        $sha = [System.Security.Cryptography.SHA256]::Create()
        $fs2 = ([BitConverter]::ToString($sha.ComputeHash($bytes)) -replace '-','')
        $cs2 = ([BitConverter]::ToString($sha.ComputeHash($buf)) -replace '-','')
        Write-Output ("read back " + $g + " bytes")
        Write-Output ("file sha=" + $fs2)
        Write-Output ("card sha=" + $cs2)
        $first = -1
        for ($i = 0; $i -lt $nb; $i++) { if ($buf[$i] -ne $bytes[$i]) { $first = $i; break } }
        if ($first -lt 0) { Write-Output 'CARD VERIFY PASS' } else { Write-Output ("CARD VERIFY FAIL: first diff at byte " + $first + " (block " + [math]::Floor($first/512) + ")") }
    } catch { Write-Output ("READ FAIL : " + $_.Exception.Message) }
}

if ($removed) {
    try { Add-PartitionAccessPath -DiskNumber $Disk -PartitionNumber $Part -AccessPath $accessPath; Write-Output ("volume " + $Letter + ": remounted") }
    catch { Write-Output ("remount failed: " + $_.Exception.Message) }
}
try { Stop-Transcript | Out-Null } catch { }
