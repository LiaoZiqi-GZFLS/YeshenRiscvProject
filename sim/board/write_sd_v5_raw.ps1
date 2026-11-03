# write_sd_v5_raw.ps1 -- raw-write sd_y1_v5.img to PhysicalDrive2 (no drive letter needed).
# ASCII only. Guard: disk must be USB, < 16GB and larger than the image.
$ErrorActionPreference = 'Stop'
$img  = 'D:/code/PDS/VexiiYeshenLinux/sw/images/sd_y1_v5.img'
$disk = 2
$log  = 'D:/code/PDS/VexiiYeshenLinux/sim/reglogs/write_sd_v5.log'
Start-Transcript -Path $log -Force | Out-Null
$d  = Get-Disk -Number $disk
$nb = (Get-Item $img).Length
if (-not (($d.BusType -eq 'USB') -and ($d.Size -lt 16GB) -and ($d.Size -gt $nb))) {
    Write-Output ("GUARD FAIL: " + $d.FriendlyName + " " + $d.BusType + " size=" + $d.Size + " img=" + $nb)
    Stop-Transcript | Out-Null; exit 1
}
Write-Output ("GUARD PASS: " + $d.FriendlyName + " (" + $d.BusType + ", " + $d.Size + " B) img=" + $nb + " B")
Get-Partition -DiskNumber $disk -ErrorAction SilentlyContinue | ForEach-Object {
    if ($_.DriveLetter) { Remove-PartitionAccessPath -DiskNumber $disk -PartitionNumber $_.PartitionNumber -AccessPath ($_.DriveLetter + ':\') -ErrorAction SilentlyContinue }
}
$dev  = [char]92 + [char]92 + [char]46 + [char]92 + 'PhysicalDrive' + $disk
$dev2 = [char]92 + [char]92 + [char]46 + [char]92 + 'PhysicalDrive' + $disk
$bytes = [System.IO.File]::ReadAllBytes($img)
$fs = [System.IO.File]::Open($dev, 'Open', 'Write', 'None')
$fs.Write($bytes, 0, $bytes.Length)
$fs.Flush($true)
$fs.Close()
Write-Output ("WROTE " + $bytes.Length + " B")
$fs = [System.IO.File]::Open($dev2, 'Open', 'Read', 'None')
$buf = New-Object byte[] $bytes.Length
$off = 0
while ($off -lt $buf.Length) { $n = $fs.Read($buf, $off, $buf.Length - $off); if ($n -le 0) { break }; $off += $n }
$fs.Close()
$h1 = (Get-FileHash -Algorithm SHA256 -Path $img).Hash
$sha = [System.Security.Cryptography.SHA256]::Create()
$h2 = [BitConverter]::ToString($sha.ComputeHash($buf)).Replace('-', '')
Write-Output ("FILE_SHA256=" + $h1)
Write-Output ("CARD_SHA256=" + $h2)
Write-Output ("MATCH=" + ($h1 -eq $h2))
Stop-Transcript | Out-Null
