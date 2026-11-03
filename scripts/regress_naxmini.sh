#!/usr/bin/env bash
# =============================================================================
# regress_naxmini.sh —— NaxYeshenLinux 一键回归（T13）
#
# 用法（**在 WSL 里跑**；verilator/sim 都在 WSL）：
#   bash scripts/regress_naxmini.sh            # 快速档（<1 分钟）
#   bash scripts/regress_naxmini.sh --full     # 加上 P1 主判据（四镜像跑到用户态，~7-15 分钟）
#
# 快速档做四件事（都不依赖长跑）：
#   1) 四个镜像存在 + magic/尺寸自检（fw_jump.bin / Image / linux.dtb / rootfs.cpio）
#   2) `check_addr_map.py`：地址台账与 DTS/装载链/装置四处对账
#   3) 判据装置存在（obj_dir_hb/naxminip 或 $SOC_TB）
#   4) **负对照**：`SOC_LOAD_MODE=1`（CPU 扣复位）⇒ 必须 `frames=0` + `FAIL: timeout`
#      —— 这步验的是"判据不是随便什么都能过"，是整套判据的**闸门**。
# --full 再加：
#   5) 四镜像跑 P1 主判据：线上解出的文本必须包含 `VEXIIYESHEN-OK`
#
# 口径：本脚本**只判已有的判据**，不放宽任何断言（见 docs/M2-Gate2-2026-09-30.md §15.6）。
# =============================================================================
set -uo pipefail

cd "$(dirname "$0")/.." || exit 9
SRC=$(pwd)
TB=${SOC_TB:-./obj_dir_hb/naxminip}
IMG4='sw/images/Image@0x82000000,sw/images/linux.dtb@0x82F80000,sw/images/rootfs.cpio@0x83000000'
PROG="sw/images/fw_jump.bin@0x80000000,$IMG4"
LOGD=${LOGD:-sim/reglogs}
mkdir -p "$LOGD"

pass=0; fail=0
ok()   { echo "  [OK]   $*"; pass=$((pass+1)); }
bad()  { echo "  [FAIL] $*"; fail=$((fail+1)); }
phase(){ echo; echo "===== $* ====="; }

phase "1/5 四个镜像 + magic"
declare -A WANT=( [sw/images/fw_jump.bin]=133872 [sw/images/Image]=6079580 \
                  [sw/images/linux.dtb]=2003 [sw/images/rootfs.cpio]=2510848 )
for f in "${!WANT[@]}"; do
  if [ ! -f "$f" ]; then bad "缺 $f"; continue; fi
  sz=$(stat -c%s "$f"); [ "$sz" = "${WANT[$f]}" ] && ok "$f $sz B" || bad "$f 尺寸 $sz ≠ 期望 ${WANT[$f]}（镜像变了就更新本脚本的期望值）"
done
py=python3; command -v "$py" >/dev/null 2>&1 || py=python
$py - <<'PY'
import pathlib,sys
p=pathlib.Path("sw/images")
# RISC-V Image 头 magic 字段在 0x38，值 0x05435352 **按小端存放** ⇒ 字节序是 52 53 43 05 = b"RSC\x05"
checks=[(p/"Image",b"RSC\x05",0x38,"RISC-V Image magic"),(p/"rootfs.cpio",b"070701",0,"cpio newc"),(p/"linux.dtb",b"\xd0\x0d\xfe\xed",0,"FDT magic")]
bad=0
for f,m,off,what in checks:
    if not f.exists(): print(f"  [FAIL] 缺 {f}"); bad=1; continue
    b=f.read_bytes()[off:off+len(m)]
    print(f"  [OK]   {f.name} {what} @0x{off:x} = {b.hex()}") if b==m else (print(f"  [FAIL] {f.name} {what} = {b.hex()}"), )
    bad |= (b!=m)
sys.exit(bad)
PY
[ $? -eq 0 ] && ok "镜像内部 magic 自检" || bad "镜像内部 magic 自检"

phase "2/5 地址台账对账"
if [ -f scripts/check_addr_map.py ]; then
  $py scripts/check_addr_map.py >"$LOGD/regress_addr_map.log" 2>&1 && ok "check_addr_map.py" || { bad "check_addr_map.py（见 $LOGD/regress_addr_map.log）"; tail -5 "$LOGD/regress_addr_map.log"; }
else bad "缺 scripts/check_addr_map.py"; fi

phase "3/5 判据装置"
[ -x "$TB" ] && ok "$TB" || bad "判据装置 $TB 不存在（先跑 docs/M2-Gate2-2026-09-30.md §15.6 的 verilator 命令；或用 SOC_TB=... 指定）"

phase "4/5 负对照（SOC_LOAD_MODE=1 ⇒ 必须 frames=0 + FAIL）"
if [ -x "$TB" ]; then
  SOC_LOAD_MODE=1 SOC_MEM_MIB=256 SOC_EXPECT='VEXIIYESHEN-OK' SOC_MAX_CYC=2000000 \
    SOC_PROG="$PROG" "$TB" >"$LOGD/regress_negctl.log" 2>&1
  line=$(grep -a -E "TEST PASSED|FAIL:" "$LOGD/regress_negctl.log" | tail -1)
  echo "  $line"
  case "$line" in
    FAIL:*frames=0*) ok "负对照 frames=0（判据有闸门）" ;;
    *)               bad "负对照异常（期望 FAIL + frames=0）" ;;
  esac
else bad "负对照跳过（无装置）"; fi

phase "5/5 P1 主判据"
if [ "${1:-}" = "--full" ]; then
  if [ -x "$TB" ]; then
    SOC_MEM_MIB=256 SOC_EXPECT='VEXIIYESHEN-OK' SOC_MAX_CYC=600000000 \
      SOC_PROG="$PROG" "$TB" >"$LOGD/regress_judge.log" 2>&1
    line=$(grep -a -E "TEST PASSED|FAIL:" "$LOGD/regress_judge.log" | tail -1)
    echo "  $line"
    case "$line" in
      "TEST PASSED criterion=VEXIIYESHEN-OK"*) ok "P1 主判据（用户态 marker）" ;;
      *) bad "P1 主判据（见 $LOGD/regress_judge.log）" ;;
    esac
  else bad "P1 判据跳过（无装置）"; fi
else echo "  [SKIP] 未加 --full（主判据要 7-15 分钟；命令见 docs/M2-Gate2-2026-09-30.md §15.6）"; fi

phase "结果"
echo "  pass=$pass fail=$fail"
[ "$fail" -eq 0 ] && { echo "REGRESS PASS"; exit 0; } || { echo "REGRESS FAIL"; exit 1; }
