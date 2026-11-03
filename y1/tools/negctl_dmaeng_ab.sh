#!/usr/bin/env bash
# negctl_dmaeng_ab.sh —— y1-DMA Phase-2a 的**负对照**：每条都必须是"**单行源码变异 + 重生成 + 重跑闸门**"，
# 闸门**必须翻红**（这就是"判据不是橡皮图章"的证据）。跑完**恢复源码 + 重新生成**并核对 md5。
#
#   NC1 每笔突发**短 1 拍**：`DdrMaster.beatsM1For` 的满块值 15 -> 14
#       ⇒ 分块字节数与地址递进随之错位（112 B/块 ⇒ 地址不再 32 B 对齐），
#         内存模型**响亮 $fatal**、逐字节判据同时翻红。
#   NC1b 每笔读突发**多 1 拍**：AR 的 `len` 由 `beatsM1` 改成 `beatsM1+1`
#       ⇒ 声明的突发变成 17 拍（> 16），内存模型**响亮 $fatal**。
#   NC2 **静默收下非法 len**（D2 的核心条款）：`DdrMaster` 的 `lenOk` 恒真
#       ⇒ len=40 被**悄悄执行**（err=0、真的搬了 40 字节）⇒ JOB 3 的"必须 err + 零搬运"翻红。
#   NC3 一通道的记账**泄漏**进另一通道：`bytesR(c) := liveBytes` 改成 `bytesR(c) := liveBytes + bytesR(1-c)`
#       ⇒ JOB 5 的并发对账翻红（后完成的通道把自己的字节数算成了两台之和）。
#   NC4 逐通道寄存器**读串台**：CH_BYTES 的读口恒指向通道 0 的寄存器 ⇒ JOB 5 的 `bytes_moved` 翻红。
#
# 另外做一条**比较器自检**（不用仿真）：扰动一个字节 ⇒ `diffs` 必须恰好报 1 处不符
#   —— 不做这步就分不清"真的逐字节相符"与"比较器把两边都读成空表也报 0"。
#
# 退出码：0 = 5 条负对照**全部发火** + 自检过 + 源码逐字节恢复；2 = 有负对照没发火 ⇒ **闸门不可信**。
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
R="$(cd "$here/../.." && pwd)"
cd "$R" || exit 2
PY="${PY:-$(command -v python || command -v python3)}"
[ -n "$PY" ] || { echo "FATAL: 找不到 python"; exit 2; }
DM="y1/rtl/DdrMaster.scala"
DE="y1/rtl/DmaEngine.scala"
GEN='Test/runMain DmaEngineGen D:/code/PDS/VexiiYeshenLinux/y1/gen

exit
'
LOGD="sim/reglogs"
mkdir -p "$LOGD"

regen() {
  ( cd y1 && printf '%s' "$GEN" | bash sbt.sh ) > "/tmp/dmaeng_nc_gen.log" 2>&1 || {
    echo "  REGEN_FAIL（见 /tmp/dmaeng_nc_gen.log）"; tail -6 /tmp/dmaeng_nc_gen.log; return 1; }
  grep -q DMAENGINEGEN_DONE "/tmp/dmaeng_nc_gen.log" || { echo "  REGEN_NO_DONE"; return 1; }
  return 0
}

patch1() { # <file> <old> <new>  —— 要求**恰好 1 处**命中，否则拒绝变异
  "$PY" - "$1" "$2" "$3" <<'PYEOF'
import io, sys
p, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
s = io.open(p, encoding="utf-8").read()
n = s.count(old)
print("  PATCH_HITS=%d" % n)
if n != 1: sys.exit(2)
io.open(p, "w", encoding="utf-8", newline="\n").write(s.replace(old, new))
PYEOF
}

MD5_DM0="$(md5sum "$DM" | awk '{print $1}')"
MD5_DE0="$(md5sum "$DE" | awk '{print $1}')"
cp "$DM" "/tmp/DdrMaster.scala.bak"
cp "$DE" "/tmp/DmaEngine.scala.bak"
echo "== negctl_dmaeng_ab：5 条负对照（每条都必须让闸门翻红）=="
echo "   基线 md5: DdrMaster.scala=$MD5_DM0  DmaEngine.scala=$MD5_DE0"

restore() {  # 恢复源码 + 重生成 + 核对 md5
  cp "/tmp/DdrMaster.scala.bak" "$DM"
  cp "/tmp/DmaEngine.scala.bak" "$DE"
  regen || return 1
  local a b
  a="$(md5sum "$DM" | awk '{print $1}')"; b="$(md5sum "$DE" | awk '{print $1}')"
  if [ "$a" != "$MD5_DM0" ] || [ "$b" != "$MD5_DE0" ]; then
    echo "  RESTORE_MD5_MISMATCH ($a / $b)"; return 1
  fi
  echo "  RESTORED ok（源码 md5 与基线一致；网表已重生成）"
  return 0
}

nc_run() { # <tag> <说明> <file> <old> <new>
  local tag="$1" why="$2" f="$3" old="$4" new="$5" rc=0
  echo "---- $tag：$why ----"
  patch1 "$f" "$old" "$new" || { echo "  $tag PATCH_FAIL ⇒ 负对照不成立"; return 2; }
  regen || { restore; return 2; }
  if bash y1/tools/run_dmaeng_ab.sh > "$LOGD/dmaeng_nc_$tag.log" 2>&1; then
    echo "  $tag 闸门**仍然全绿** ⇒ 负对照没发火（判据是橡皮图章）"; rc=2
  else
    echo "  $tag 闸门翻红 ✔（证据：# $(grep -acE 'JUDGE-RED|RESULT: FAIL' "$LOGD/dmaeng_nc_$tag.log") 处；摘录见下）"
    grep -aE 'JUDGE-RED|RESULT: FAIL|TBFAIL' "$LOGD/dmaeng_nc_$tag.log" | head -4 | sed 's/^/      /'
  fi
  restore || return 2
  return $rc
}

FAILED=0
nc_run NC1 "每笔突发**短 1 拍**（满块 16 -> 15 拍）" "$DM" \
  'Mux(full, U(15, 4 bits), (rem(6 downto 3) - U(1, 4 bits)).resize(4 bits))' \
  'Mux(full, U(14, 4 bits), (rem(6 downto 3) - U(1, 4 bits)).resize(4 bits))' || FAILED=1
nc_run NC1b "每笔读突发**多 1 拍**（AR 声明的 len = beatsM1 + 1）" "$DM" \
  'io.axi.ar.payload.len   := beatsM1.resize(8 bits)' \
  'io.axi.ar.payload.len   := (beatsM1.resize(8 bits) + U(1, 8 bits))' || FAILED=1
nc_run NC2 "**静默收下非法 len**（D2 的核心）：lenOk 恒真" "$DM" \
  'val lenOk = ((io.len % 32) === 0) && (io.len =/= 0)' \
  'val lenOk = True' || FAILED=1
nc_run NC3 "一通道的记账**泄漏**进另一通道（bytesR(c) += bytesR(1-c)）" "$DE" \
  '      bytesR(c)     := liveBytes' \
  '      bytesR(c)     := liveBytes + bytesR(1 - c)' || FAILED=1
nc_run NC4 "逐通道寄存器**读串台**（CH_BYTES 恒读通道 0 的寄存器）" "$DE" \
  'bytesR(c)),        base + OFF_BYTE' \
  'bytesR(0)),        base + OFF_BYTE' || FAILED=1

# ---- 比较器自检（不用仿真）：扰动 1 个字节 ⇒ diffs 必须恰好 1 ----
echo "---- 比较器自检（扰动 1 字节 ⇒ diffs 恰好 1）----"
"$PY" - > /tmp/dmaeng_selfcheck.out 2>&1 <<'PYEOF'
try: import sys; sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception: pass
def diffs(a, b, base=0):
    n = len(a); cnt = 0; first = -1
    for k in range(n):
        if a[k] != b[k]:
            if first < 0: first = base + k
            cnt += 1
    return cnt, first
a = bytes(range(256)) * 8
b = bytearray(a); b[1234] ^= 0x01
c, f = diffs(a, bytes(b))
print("  SELFTEST MISMATCH=%d FIRST=%d（期望 1/1234）" % (c, f))
sys.exit(0 if (c == 1 and f == 1234) else 1)
PYEOF
if [ $? -ne 0 ]; then cat /tmp/dmaeng_selfcheck.out; echo "  比较器自检不过 ⇒ 闸门不可信"; FAILED=1
else cat /tmp/dmaeng_selfcheck.out; fi

echo "==================== 汇总 ===================="
if [ "$FAILED" -eq 0 ]; then
  echo "5/5 负对照全部发火 + 比较器自检过 + 源码逐字节恢复 ⇒ RESULT: PASS"
  exit 0
else
  echo "有负对照没发火 / 自检不过 ⇒ RESULT: FAIL（闸门不可信）"
  exit 2
fi
