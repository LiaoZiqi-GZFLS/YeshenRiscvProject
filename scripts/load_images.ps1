# load_images.ps1 -- push the four images into DDR via the on-board UART loader, then release the CPU.
#
# Protocol (extracted from src/peripheral/UartLoader.scala -- do not guess):
#   frame = 'W' + addr[4B BE] + len[4B BE] + data[len] + xor8
#        . every byte EXCEPT the trailing checksum byte is acknowledged with 0x06
#          (including 'W', the addr bytes, the len bytes and every data byte)
#        . the trailing checksum byte is answered with 'K' (ok) / 'E' (bad, resend frame)
#        . xor8 = XOR over the DATA bytes only (RTL clears xorAcc at end of header, adds in pData)
#        . addr MUST be 32B aligned (RTL asserts at the 'W' header)
#   'J' -> answers 'K' then releases the CPU (SoC takes the line back)
#   '?' -> answers 'Y' (liveness)
#   The loader streams "YSLD\n" until the first command byte, so the host always aligns.
#
# Usage: powershell -File load_images.ps1 [-Port COM7] [-Root D:/.../sw/images]
param(
  [string]$Port = 'COM7',
  [int]   $Baud = 115200,
  [string]$Root = 'D:/code/PDS/NaxYeshenLinux/sw/images',
  [switch]$NoJump
)
$ErrorActionPreference = 'Stop'
# NOTE: use decimal literals -- in PS 5.1 the literal 0x80000000 becomes an Int32 (-2147483648)
# and [uint32] of a negative Int32 throws InvalidCastIConvertible.
$Img = @(
  @{ name='fw_jump.bin';  addr=[int64]2147483648 },   # 0x80000000
  @{ name='Image';        addr=[int64]2181038080 },   # 0x82000000 (H2b: above the NPU arena carve)
  @{ name='linux.dtb';    addr=[int64]2197291008 },   # 0x82F80000
  @{ name='rootfs.cpio';  addr=[int64]2197815296 }    # 0x83000000
)

$p = New-Object System.IO.Ports.SerialPort $Port,$Baud,None,8,one
$p.ReadTimeout = 8000
$p.WriteTimeout = 8000
$p.DtrEnable = $true
$p.RtsEnable = $true
$p.Open()
Write-Host ("PORT {0} opened @ {1}" -f $Port,$Baud)

function Drain([int]$ms = 300) {
  Start-Sleep -Milliseconds $ms
  $n = $p.BytesToRead
  if ($n -gt 0) { $b = New-Object byte[] $n; [void]$p.Read($b,0,$n); return $n }
  return 0
}
# Drain until the line is quiet for $quiet ms (the loader streams "YSLD\n" continuously until the
# first command byte, so a plain sleep leaves a big backlog in the host buffer).
function DrainQuiet([int]$quiet = 600, [int]$maxMs = 8000) {
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $last = 0
  while ($sw.Elapsed.TotalMilliseconds -lt $maxMs) {
    Start-Sleep -Milliseconds 100
    $n = $p.BytesToRead
    if ($n -gt 0) { $b = New-Object byte[] $n; [void]$p.Read($b,0,$n); $last = $sw.Elapsed.TotalMilliseconds }
    elseif (($sw.Elapsed.TotalMilliseconds - $last) -gt $quiet) { return }
  }
}
function ReadAckExpect([byte]$want, [string]$ctx) {
  # Tolerate up to 8 stray banner bytes ('Y'=59 'S'=53 'L'=4C 'D'=44 '\n'=0A): the loader streams
  # "YSLD\n" until the first command byte, and TX queueing can let a few slip past the probe.
  $skips = 0
  for ($try = 0; $try -lt 4; $try++) {
    try {
      $r = $p.ReadByte()
      if ($r -eq $want) { return }
      if ($r -eq 0x59 -or $r -eq 0x53 -or $r -eq 0x4C -or $r -eq 0x44 -or $r -eq 0x0A) {
        if ($skips -lt 8) { $skips++; continue }
      }
      throw ("ctx={0} want {1:X2} got {2:X2}" -f $ctx,$want,$r)
    } catch [System.TimeoutException] {
      Write-Host ("  timeout retry {0} ({1})" -f $try,$ctx)
    }
  }
  throw ("ctx={0} wait {1:X2} failed" -f $ctx,$want)
}

# 1) liveness: '?' -> 'Y'   (tolerant: the banner may still be draining, so read until 'Y')
DrainQuiet 600 8000
$p.Write([byte[]]@(0x3F),0,1)
$skipped = 0; $sawY = $false
$sw = [Diagnostics.Stopwatch]::StartNew()
while ($sw.Elapsed.TotalSeconds -lt 5) {
  try { $r = $p.ReadByte() } catch [System.TimeoutException] { break }
  if ($r -eq 0x59) { $sawY = $true; break }
  $skipped++
}
if (-not $sawY) { throw ("probe failed: no 'Y' (skipped {0} bytes)" -f $skipped) }
Write-Host ("probe OK ('?' -> 'Y'), skipped {0} banner bytes" -f $skipped)

# 2) send one frame per image
foreach ($im in $Img) {
  $path = Join-Path $Root $im.name
  if (-not (Test-Path $path)) { throw "missing $path" }
  $data = [System.IO.File]::ReadAllBytes($path)
  $addr = [uint32]$im.addr
  if (($addr -band 0x1F) -ne 0) { throw ("addr not 32B aligned: {0:X8}" -f $addr) }
  $len  = [uint32]$data.Length
  $xor  = 0
  foreach ($b in $data) { $xor = $xor -bxor $b }
  $t0 = Get-Date
  Write-Host ("==> {0}: {1} B @ 0x{2:X8} xor8=0x{3:X2}" -f $im.name,$len,$addr,$xor)
  $hdr = @([byte]0x57,
           [byte](($addr -shr 24) -band 0xFF),[byte](($addr -shr 16) -band 0xFF),
           [byte](($addr -shr  8) -band 0xFF),[byte]($addr -band 0xFF),
           [byte](($len  -shr 24) -band 0xFF),[byte](($len  -shr 16) -band 0xFF),
           [byte](($len  -shr  8) -band 0xFF),[byte]($len  -band 0xFF))
  foreach ($b in $hdr) { $p.Write([byte[]]@($b),0,1); ReadAckExpect 0x06 "hdr" }
  $sent = 0
  foreach ($b in $data) {
    $p.Write([byte[]]@($b),0,1)
    ReadAckExpect 0x06 "data"
    $sent++
    if (($sent % 65536) -eq 0) {
      $el = ((Get-Date) - $t0).TotalSeconds
      Write-Host ("    {0}/{1} B  {2:N1}s  {3:N1} KB/s" -f $sent,$len,$el,($sent/1024.0/[Math]::Max($el,0.001)))
    }
  }
  $p.Write([byte[]]@([byte]$xor),0,1)
  ReadAckExpect 0x4B "frame-K"
  $el = ((Get-Date) - $t0).TotalSeconds
  Write-Host ("    OK {0}  {1:N1}s  {2:N1} KB/s" -f $im.name,$el,($len/1024.0/[Math]::Max($el,0.001)))
}

# 3) 'J' releases the CPU
if (-not $NoJump) {
  Write-Host "==> 'J' releasing CPU (console goes back to the SoC)"
  $p.Write([byte[]]@(0x4A),0,1)
  ReadAckExpect 0x06 "J-ack"
  ReadAckExpect 0x4B "J-K"
  Write-Host "CPU released."
}

# 4) read the console (OpenSBI / Linux banner / VEXIIYESHEN-OK)
$p.ReadTimeout = 30000
$out = New-Object System.Collections.Generic.List[byte]
$sw = [Diagnostics.Stopwatch]::StartNew()
while ($sw.Elapsed.TotalSeconds -lt 120) {
  try { if ($p.BytesToRead -gt 0) { $b = New-Object byte[] $p.BytesToRead; [void]$p.Read($b,0,$b.Length); foreach($x in $b){$out.Add($x)} } } catch {}
  Start-Sleep -Milliseconds 100
}
$p.Close()
$txt = -join ($out | ForEach-Object { if ($_ -ge 32 -and $_ -lt 127) { [char]$_ } elseif ($_ -eq 10) { "`n" } else { '.' } })
Write-Host ("=== console {0} bytes ===" -f $out.Count)
Write-Host $txt
