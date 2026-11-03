# probe_frame.ps1 -- minimal diagnostic: send '?' then a 4-byte 'W' frame, echoing every reply byte.
param([string]$Port='COM7',[int]$Baud=115200,[int]$DataLen=4)
$ErrorActionPreference='Stop'
$p = New-Object System.IO.Ports.SerialPort $Port,$Baud,None,8,one
$p.ReadTimeout = 3000
$p.Open()
Write-Host ("PORT {0} @ {1}" -f $Port,$Baud)

function DrainQuiet([int]$quiet=600,[int]$maxMs=8000){
  $sw=[Diagnostics.Stopwatch]::StartNew(); $last=0
  while($sw.Elapsed.TotalMilliseconds -lt $maxMs){
    Start-Sleep -Milliseconds 100
    $n=$p.BytesToRead
    if($n -gt 0){ $b=New-Object byte[] $n; [void]$p.Read($b,0,$n); $last=$sw.Elapsed.TotalMilliseconds }
    elseif(($sw.Elapsed.TotalMilliseconds-$last) -gt $quiet){ return }
  }
}
function SendShow([byte]$b,[string]$ctx){
  $p.Write([byte[]]@($b),0,1)
  $got=@()
  $sw=[Diagnostics.Stopwatch]::StartNew()
  while($sw.Elapsed.TotalMilliseconds -lt 3000){
    if($p.BytesToRead -gt 0){
      $n=$p.BytesToRead; $rb=New-Object byte[] $n; [void]$p.Read($rb,0,$n)
      foreach($x in $rb){ $got += ('{0:X2}' -f $x) }
    } else { Start-Sleep -Milliseconds 20 }
  }
  Write-Host ("  {0,-6} <- send {1:X2}   recv[{2}] = {3}" -f $ctx,$b,$got.Count,($got -join ' '))
}

DrainQuiet 600 8000
SendShow 0x3F "probe"                                   # '?' expect... 06 then Y
$addr=[int64]2147483648; $len=[int64]$DataLen
$hdr=@([byte]0x57,
  [byte](($addr -shr 24)-band 0xFF),[byte](($addr -shr 16)-band 0xFF),[byte](($addr -shr 8)-band 0xFF),[byte]($addr -band 0xFF),
  [byte](($len  -shr 24)-band 0xFF),[byte](($len  -shr 16)-band 0xFF),[byte](($len  -shr 8)-band 0xFF),[byte]($len  -band 0xFF))
SendShow $hdr[0] "W"
for($i=1;$i -lt $hdr.Count;$i++){ SendShow $hdr[$i] ("hdr"+$i) }
$data=@(0xA5,0x5A,0x11,0x22)
$xor=0; foreach($d in $data){ $xor = $xor -bxor $d }
foreach($d in $data){ SendShow $d "data" }
SendShow ([byte]$xor) "xor8"
$p.Close()
