@echo off
REM T33: generate the F2-patched netlist into rtl_hubfix (Windows side only).
REM ASCII only + CRLF only. Region args must match the delivered rtl exactly:
REM the peripheral region is 16384 (16 KiB), NOT 16777216. See docs sec 13.10.
setlocal
cd /d D:\code\PDS\NaxYeshenLinux\third_party\nax-fork\NaxRiscv
set SBT=C:\Users\Ziqi\AppData\Local\Coursier\data\bin\sbt.bat
set OUT=..\..\..\rtl_hubfix
set LOG=..\..\..\sim\reglogs\t33_naxgen_f2.log
if not exist "%OUT%" mkdir "%OUT%"
echo [T33] start > "%LOG%"
call "%SBT%" "runMain naxriscv.platform.litex.NaxGen --netlist-directory ..\..\..\rtl_hubfix --netlist-name NaxSocMini --reset-vector 0x80000000 --xlen 64 --litedram-width 64 --l2-bytes 0 --memory-region 2147483648,536870912,cx,m --memory-region 4026531840,16384,rw,p --scala-file ..\..\..\sw\gen\plugins.scala" >> "%LOG%" 2>&1
echo SBT_EXIT=%ERRORLEVEL% >> "%LOG%"
