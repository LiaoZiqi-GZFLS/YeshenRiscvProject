@echo off
REM gen_soc_64k.bat -- regenerate NaxSocMini with the peripheral region enlarged 16 KiB -> 64 KiB.
REM Why: LiteEth needs mac+mdio+buffer windows; 16550+GPIO pages + those ~= 20 KB > the old 16 KiB.
REM Writes to a STAGING dir (rtl_64k); promote to rtl/ only after diff+audit (see promote_hubfix.sh).
REM ASCII only + CRLF only.
setlocal
cd /d D:\code\PDS\NaxYeshenLinux\third_party\nax-fork\NaxRiscv
set SBT=C:\Users\Ziqi\AppData\Local\Coursier\data\bin\sbt.bat
set OUT=..\..\..\rtl_64k
set LOG=..\..\..\sim\reglogs\naxgen_64k.log
if not exist "%OUT%" mkdir "%OUT%"
echo [64k] start > "%LOG%"
call "%SBT%" "runMain naxriscv.platform.litex.NaxGen --netlist-directory ..\..\..\rtl_64k --netlist-name NaxSocMini --reset-vector 0x80000000 --xlen 64 --litedram-width 64 --l2-bytes 0 --memory-region 2147483648,536870912,cx,m --memory-region 4026531840,65536,rw,p --scala-file ..\..\..\sw\gen\plugins.scala" >> "%LOG%" 2>&1
echo SBT_EXIT=%ERRORLEVEL% >> "%LOG%"
