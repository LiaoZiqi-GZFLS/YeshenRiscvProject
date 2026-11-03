#!/usr/bin/env bash
# run_dmaeng_ab.sh —— y1-DMA Phase-2a 单元闸门：**多通道 DMA 引擎**（y1/rtl/DmaEngine.scala）的 D1/D2 判据。
#
# 装置：y1/rtl_test/DmaEngineTb.v（真 CSR + 真 AXI4 主口）× y1/rtl_test/AxiMemModel.v（行为级内存模型）
#       × 网表 y1/gen/DmaEngine.v（由 `DmaEngineGen` 生成，见文件末尾的生成命令）。
# 判据与 spec §5 D1/D2 逐条对应，**每条都带能翻红的负对照**（见 negctl_dmaeng_ab.sh）：
#   D1（单块搬运正确，三向 + 背靠背 + 逐字节）：
#     JOB 0 COPY（DDR→DDR）  LEN ∈ {32,96,160,256,512}：dst 区 == 原地 src 区（**逐字节**）、
#                            src 区/邻居未动、AR/AW 地址序列 == Python 独立重算的分块、
#                            与内存模型交叉对账 rd=wr=LEN、`bytes_moved == LEN`。
#     JOB 1 RD（DDR→外设缓冲） LEN ∈ {32,96,160}：rd_stream 推出的字节**逐字节** == 源区；
#                            内存一个字节都没写（wr=0）、AW 一笔未发、`bytes_moved == LEN`。
#     JOB 2 WR（外设缓冲→DDR） LEN ∈ {32,96,160}：dst 区**逐字节** == 喂进去的字节；
#                            其余（含源区）== 预载、AR 一笔未发、`bytes_moved == LEN`。
#     JOB 4 背靠背 N=6 笔（同一通道，长度 32/64/96/128/160/192 轮换）：整片镜像 == Python
#                            按次序独立施加 6 笔拷贝算出的黄金镜像（**逐字节**）；每笔自报 == 该笔长度。
#   D2（对账 + 响亮 err）：
#     JOB 3 非法入参 ×6（len=40 / len=48 / len=0 / src 未对齐 / dst 未对齐 / mode=3）：
#                            必须 `err=1`、`done=0`、`bytes_moved=0`、`err_code==期望`，且**零搬运**
#                            （AR/AW 一笔未发、整片镜像 == 预载）。
#     JOB 5 两通道并发：两通道都在 COPY，**同时忙**（GBL_BUSY 采样到两通道同时为 1 ≥3 次）、
#                            AR/AW 地址在两个窗口间**交错**（不是"先跑完一台再跑另一台"）、
#                            两区**各自逐字节**正确、`bytes_moved` **逐通道独立** == 各自的 LEN。
#     JOB 6 abort：长搬运中途 abort ⇒ `aborted=1`、`busy=0`、`done=0`、`err_code=6`、
#                            `bytes_moved` 是 128 的整数倍且 < LEN（**在块边界停下**）、
#                            已搬出的那一段 dst 区**逐字节** == 源区；随后**同一通道再跑一笔**
#                            正常完成（`bytes_moved=128`）⇒ 证中止后通道可用、无残留拍串台。
#
# 退出码：0 = 全绿；1 = 判据不符/仿真失败；2 = 触发器的自检不过（装置/激励构造失败）⇒ **闸门不可信**。
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
gen="$here/../gen"
tbs="$here/../rtl_test/DmaEngineTb.v"
memv="$here/../rtl_test/AxiMemModel.v"
nl="$gen/DmaEngine.v"

find_tool() {
  local n="$1" p d
  p="$(command -v "$n" 2>/dev/null || true)"
  if [ -z "$p" ]; then
    for d in /c/msys64/ucrt64/bin /mingw64/bin /usr/bin; do
      if [ -x "$d/$n" ]; then p="$d/$n"; break; fi
    done
  fi
  printf '%s' "$p"
}
IVERILOG="$(find_tool iverilog)"
VVP="$(find_tool vvp)"
PY="${PY:-$(command -v python || true)}"
[ -n "$PY" ] || PY="$(find_tool python3)"
[ -n "$PY" ] || PY="$(find_tool python)"

# ---- 用例常量（必须与 DmaEngineTb.v 的默认值/内存布局一致）----
MEMSZ=65536
PERIOD=251
SRC0=1024; DST0=16384          # JOB 0/4/5 通道 0；JOB 1 的源；JOB 2 的目标
SRC1=4096; DST1=24576          # JOB 5 通道 1
SRC_A=8192; DST_A=16384; LEN_A=4096; RERUN_OFF=32768; RERUN_LEN=128   # JOB 6
LEN5_0=1024; LEN5_1=2048

echo "== run_dmaeng_ab：多通道 DMA 引擎（NCH=2）单元判据 =="
echo "   tb =$tbs"
echo "   nl =$nl"
echo "   iverilog=${IVERILOG:-<找不到>}  vvp=${VVP:-<找不到>}  python=$PY"
if [ ! -f "$nl" ]; then
  echo "FATAL: 缺网表 $nl"
  echo "       先生成: cd $here/.. && printf 'Test/runMain DmaEngineGen D:/code/PDS/VexiiYeshenLinux/y1/gen\\nexit\\n' | bash sbt.sh"
  exit 2
fi
if [ -z "$IVERILOG" ] || [ -z "$VVP" ] || [ -z "$PY" ]; then echo "FATAL: 缺 iverilog / vvp / python"; exit 2; fi

work="$(mktemp -d)"
cleanup() { if [ "${KEEP_TMP:-0}" = "1" ]; then echo "KEEP_TMP=1 => 留在 $work"; else rm -rf "$work"; fi }
trap cleanup EXIT

# ===========================================================================
# 0) 激励 + 黄金（全部由 Python 独立算；装置只给事实）
# ===========================================================================
cat > "$work/dj.py" <<'PYEOF'
import sys
def load(p):
    return bytes.fromhex("".join(open(p, errors="replace").read().split()))
def diffs(a, b, base=0):
    assert len(a) == len(b), "len %d vs %d" % (len(a), len(b))
    n = len(a); cnt = 0; first = -1; i = 0; B = 1 << 16
    while i < n:
        j = min(i + B, n)
        if a[i:j] != b[i:j]:
            for k in range(i, j):
                if a[k] != b[k]:
                    if first < 0: first = base + k
                    cnt += 1
        i = j
    return cnt, first
def chunks(ln):
    assert ln > 0 and ln % 32 == 0
    out, off, rem = [], 0, ln
    while rem:
        beats = min(16, rem // 8)
        out.append((off, beats)); off += beats * 8; rem -= beats * 8
    return out
NUMKEYS = ("AR_BURSTS","AW_BURSTS","B_OK","RD_BEATS","WR_BEATS","ORPHAN_W","WLAST_BAD","WBURST_BAD",
           "RBEAT_BAD","RDWR_OVERLAP","ARAW_OVERLAP","MODE_LEAK_BAD","STREAM_IDLE_BAD",
           "STREAM_RD_BEATS","STREAM_WR_BEATS","BOTH_BUSY_SAMPLES")
def parse(p):
    d = {"ar": [], "aw": [], "ch": {}, "mem": None}
    for line in open(p, errors="replace"):
        t = line.split()
        if not t: continue
        if t[0] == "ARB": d["ar"].append((int(t[1], 16), int(t[2].split("=")[1]))); continue
        if t[0] == "AWB": d["aw"].append((int(t[1], 16), int(t[2].split("=")[1]))); continue
        if t[0] == "CHSN":
            c = int(t[1]); kv = dict(x.split("=") for x in t[2:] if "=" in x)
            d["ch"][c] = {k: int(v, 16) if k in ("CTRL","STAT","ID") else int(v) for k, v in kv.items()}
            continue
        if t[0] == "MEM" and "rd=" in line:
            d["mem"] = dict(x.split("=") for x in t[1:] if "=" in x); continue
        for x in t:
            if "=" in x:
                k, v = x.split("=", 1)
                if k in NUMKEYS:
                    try: d[k] = int(v)
                    except ValueError: pass
    return d
def arseq(label, got, exp):
    if got == exp:
        print("  %s SEQ_OK %d 笔" % (label, len(got))); return 0
    bad = next(("0x%08x/len=%d vs 0x%08x/len=%d" % (a[0], a[1], b[0], b[1]))
               for a, b in zip(got, exp) if a != b)
    print("  %s SEQ_BAD got=%d exp=%d firstbad=%s" % (label, len(got), len(exp), bad)); return 1
def memcheck(d, rd, wr, bursts_max):
    m = d.get("mem")
    if m is None: print("  MEMLINE_MISSING"); return 1
    got = (int(m["rd"]), int(m["wr"]), int(m["bursts"]))
    print("  MEM rd=%d wr=%d bursts=%d (expect rd=%d wr=%d bursts<=%d)" % (got + (rd, wr, bursts_max)))
    bad = 0
    if got[0] != rd or got[1] != wr or got[2] > bursts_max: bad = 1
    return bad
PYEOF

"$PY" - "$work" "$MEMSZ" "$PERIOD" "$SRC0" "$DST0" "$SRC1" "$DST1" "$SRC_A" "$DST_A" "$LEN_A" <<'PYEOF'
import sys
sys.path.insert(0, sys.argv[1])
import dj
try: sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception: pass
work = sys.argv[1]
memsz, period = int(sys.argv[2]), int(sys.argv[3])
src0, dst0, src1, dst1 = (int(x) for x in sys.argv[4:8])
src_a, dst_a, len_a = (int(x) for x in sys.argv[8:11])

def pat(i): return ((i % period) * 131 + 7) % period
assert len(set(pat(i) for i in range(period))) == period, "pattern period"
pre = bytes(pat(i) for i in range(memsz))
open(work + "/mem.hex", "w").write("\n".join("%02x" % b for b in pre) + "\n")

# WR 喂入流：目标区的预载**逐字节取反**（保证"一个字节都没写"不可能蒙过逐字节对比）
for ln in (32, 96, 160):
    fb = bytes(pre[dst0 + j] ^ 0x5A for j in range(ln))
    assert all(fb[j] != pre[dst0 + j] for j in range(ln)), "fed==pre at DST0"
    open(work + "/fed%d.hex" % ln, "w").write("\n".join("%02x" % b for b in fb) + "\n")

# COPY 黄金分块（Python 独立重算）
def chunks(ln):
    out, off, rem = [], 0, ln
    while rem:
        b = min(16, rem // 8); out.append((off, b)); off += b * 8; rem -= b * 8
    return out

# JOB 4 黄金镜像：按次序施加 6 笔（源区从不被写 ⇒ 读到的是原图案）
b2b = pre[:]
meta = []
for i in range(6):
    ln = 32 * (i + 1)
    s = src0 + i * 256; d = dst0 + i * 256
    meta.append((s, d, ln))
    b2b = b2b[:d] + pre[s:s + ln] + b2b[d + ln:]
open(work + "/b2b_gold.hex", "w").write("\n".join("%02x" % b for b in b2b) + "\n")
open(work + "/b2b_meta.txt", "w").write("\n".join("%d %d %d" % m for m in meta) + "\n")
print("STIM mem=%d period=%d" % (memsz, period))
print("STIM b2b=%s" % " ".join("s%d d%d l%d" % m for m in meta))
PYEOF
[ $? -eq 0 ] || { echo "FATAL: 激励构造失败 ⇒ 闸门不可信"; exit 2; }

# ===========================================================================
# 1) 编译
# ===========================================================================
if ! "$IVERILOG" -g2012 -o "$work/de.vvp" "$tbs" "$memv" "$nl" > "$work/iv.log" 2>&1; then
  echo "JUDGE-RED: iverilog 编译失败"; sed -n '1,30p' "$work/iv.log"; exit 1
fi
echo "---- iverilog 编译 OK ----"

run() {  # run <logname> <plusargs...>
  local log="$1"; shift
  ( cd "$work" && "$VVP" de.vvp +MEMFILE="$work/mem.hex" +DUMPFILE="$work/$log.dump" +dump "$@" > "$work/$log" 2>&1 )
  local rc=$?
  grep -qE '^RESULT: PASS' "$work/$log" || { echo "JUDGE-RED: $log 装置未 PASS (rc=$rc)"; grep -aE '^(RESULT|TBFAIL)' "$work/$log" | head -10; return 1; }
  return 0
}
fails=0

# ===========================================================================
# JOB 0：COPY（DDR→DDR）三向之一，含多块与尾块
# ===========================================================================
echo "---- JOB 0：COPY（DDR→DDR）LEN ∈ {32,96,160,256,512} ----"
for L in 32 96 160 256 512; do
  run "c$L.log" +JOB=0 +CH=0 +SRC=$SRC0 +DST=$DST0 +LEN=$L +MODE=0 || { fails=$((fails+1)); continue; }
  if ! "$PY" - "$work" "$work/c$L.log" "$work/c$L.log.dump" "$SRC0" "$DST0" "$L" > "$work/jc$L.out" 2>&1 <<'PYEOF'
import sys
sys.path.insert(0, sys.argv[1]); import dj
try: sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception: pass
work, log, dump = sys.argv[1], sys.argv[2], sys.argv[3]
src, dst, ln = int(sys.argv[4]), int(sys.argv[5]), int(sys.argv[6])
pre = dj.load(work + "/mem.hex"); got = dj.load(dump)
bad = 0
d_bad, d_first = dj.diffs(got[dst:dst+ln], got[src:src+ln], dst)       # dst 区 == 原地 src 区
s_bad, _ = dj.diffs(got[src:src+ln], pre[src:src+ln], src)             # src 区未动
n_bad, _ = dj.diffs(got[:dst], pre[:dst], 0)
t_bad, _ = dj.diffs(got[dst+ln:], pre[dst+ln:], dst+ln)
print("  COPY LEN=%d DST_EQ_SRC_BAD=%d SRC_UNCHANGED_BAD=%d OTHERS_BAD=%d" % (ln, d_bad, s_bad, n_bad+t_bad))
if d_bad or s_bad or n_bad or t_bad: bad += 1
d = dj.parse(log)
ch = dj.chunks(ln)
bad += dj.arseq("COPY AR", d["ar"], [(src+o, b-1) for o, b in ch])
bad += dj.arseq("COPY AW", d["aw"], [(dst+o, b-1) for o, b in ch])
bad += dj.memcheck(d, ln, ln, 2*len(ch))
c0 = d["ch"].get(0, {})
if c0.get("BYTES") != ln: print("  CH0 BYTES=%s != %d" % (c0.get("BYTES"), ln)); bad += 1
if c0.get("DONE") != 1:   print("  CH0 DONE=%s != 1" % c0.get("DONE")); bad += 1
if c0.get("ERR") != 0:    print("  CH0 ERR=%s" % c0.get("ERR")); bad += 1
if not (c0.get("CYCLES", 0) > 0): print("  CH0 CYCLES=0"); bad += 1
print("  COPY LEN=%d CH0 BYTES=%s CYCLES=%s" % (ln, c0.get("BYTES"), c0.get("CYCLES")))
sys.exit(1 if bad else 0)
PYEOF
  then echo "JUDGE-RED: COPY LEN=$L"; cat "$work/jc$L.out"; fails=$((fails+1)); else grep -aE '^  (COPY|MEM rd)' "$work/jc$L.out" | head -6; fi
done
[ "$fails" -eq 0 ] && echo "JOB 0 PASS：三向之一（COPY）多块/尾块逐字节正确"

# ===========================================================================
# JOB 1：RD（DDR → 外设缓冲，走 rd_stream）—— 三向之二
# ===========================================================================
echo "---- JOB 1：RD（DDR→外设缓冲）LEN ∈ {32,96,160} ----"
for L in 32 96 160; do
  run "r$L.log" +JOB=1 +CH=0 +SRC=$SRC0 +DST=$DST0 +LEN=$L +MODE=1 +STREAMOUT="$work/r$L.sout" || { fails=$((fails+1)); continue; }
  if ! "$PY" - "$work" "$work/r$L.log" "$work/r$L.log.dump" "$work/r$L.sout" "$SRC0" "$L" > "$work/jr$L.out" 2>&1 <<'PYEOF'
import sys
sys.path.insert(0, sys.argv[1]); import dj
try: sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception: pass
work, log, dump, sout = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
src, ln = int(sys.argv[5]), int(sys.argv[6])
pre = dj.load(work + "/mem.hex"); got = dj.load(dump); st = dj.load(sout)
bad = 0
mis, first = dj.diffs(st, pre[src:src+ln], 0)
print("  RD LEN=%d STREAM_vs_SRC_BAD=%d FIRST=%d (stream=%d B)" % (ln, mis, first, len(st)))
if mis or len(st) != ln: bad += 1
w_bad, _ = dj.diffs(got, pre)
print("  RD LEN=%d MEM_UNTOUCHED_BAD=%d" % (ln, w_bad))
if w_bad: bad += 1
d = dj.parse(log); ch = dj.chunks(ln)
bad += dj.arseq("RD AR", d["ar"], [(src+o, b-1) for o, b in ch])
if d["aw"]: print("  RD AWB_BAD %d 笔（RD 不该发 AW）" % len(d["aw"])); bad += 1
else: print("  RD AW_SEQ_OK 0 笔")
bad += dj.memcheck(d, ln, 0, len(ch))
c0 = d["ch"].get(0, {})
if c0.get("BYTES") != ln: print("  CH0 BYTES=%s != %d" % (c0.get("BYTES"), ln)); bad += 1
print("  RD LEN=%d CH0 BYTES=%s CYCLES=%s" % (ln, c0.get("BYTES"), c0.get("CYCLES")))
sys.exit(1 if bad else 0)
PYEOF
  then echo "JUDGE-RED: RD LEN=$L"; cat "$work/jr$L.out"; fails=$((fails+1)); else grep -aE '^  RD|^  MEM' "$work/jr$L.out" | head -5; fi
done
echo "JOB 1：见上（RD 三向之二）"

# ===========================================================================
# JOB 2：WR（外设缓冲 → DDR，走 wr_stream）—— 三向之三
# ===========================================================================
echo "---- JOB 2：WR（外设缓冲→DDR）LEN ∈ {32,96,160} ----"
for L in 32 96 160; do
  run "w$L.log" +JOB=2 +CH=0 +SRC=$SRC0 +DST=$DST0 +LEN=$L +MODE=2 +STREAMIN="$work/fed$L.hex" || { fails=$((fails+1)); continue; }
  if ! "$PY" - "$work" "$work/w$L.log" "$work/w$L.log.dump" "$work/fed$L.hex" "$DST0" "$L" > "$work/jw$L.out" 2>&1 <<'PYEOF'
import sys
sys.path.insert(0, sys.argv[1]); import dj
try: sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception: pass
work, log, dump, fed = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
dst, ln = int(sys.argv[5]), int(sys.argv[6])
pre = dj.load(work + "/mem.hex"); got = dj.load(dump); fb = dj.load(fed)
bad = 0
mis, first = dj.diffs(got[dst:dst+ln], fb[:ln], dst)
print("  WR LEN=%d DST_vs_FED_BAD=%d FIRST=%d" % (ln, mis, first))
if mis: bad += 1
a_bad, _ = dj.diffs(got[:dst], pre[:dst], 0); b_bad, _ = dj.diffs(got[dst+ln:], pre[dst+ln:], dst+ln)
print("  WR LEN=%d OTHERS_BAD=%d" % (ln, a_bad + b_bad))
if a_bad + b_bad: bad += 1
d = dj.parse(log); ch = dj.chunks(ln)
bad += dj.arseq("WR AW", d["aw"], [(dst+o, b-1) for o, b in ch])
if d["ar"]: print("  WR ARB_BAD %d 笔（WR 不该发 AR）" % len(d["ar"])); bad += 1
else: print("  WR AR_SEQ_OK 0 笔")
bad += dj.memcheck(d, 0, ln, len(ch))
c0 = d["ch"].get(0, {})
if c0.get("BYTES") != ln: print("  CH0 BYTES=%s != %d" % (c0.get("BYTES"), ln)); bad += 1
print("  WR LEN=%d CH0 BYTES=%s CYCLES=%s" % (ln, c0.get("BYTES"), c0.get("CYCLES")))
sys.exit(1 if bad else 0)
PYEOF
  then echo "JUDGE-RED: WR LEN=$L"; cat "$work/jw$L.out"; fails=$((fails+1)); else grep -aE '^  WR|^  MEM' "$work/jw$L.out" | head -5; fi
done
echo "JOB 2：见上（WR 三向之三）"

# ===========================================================================
# JOB 3：非法入参 ⇒ 响亮 err + 零搬运（D2）
# ===========================================================================
echo "---- JOB 3：非法入参 ×6 ----"
err_case() { # <tag> <src> <dst> <len> <mode> <code> <说明>
  local tag="$1" s="$2" d="$3" l="$4" m="$5" cd="$6" why="$7"
  run "e_$tag.log" +JOB=3 +CH=0 +SRC=$s +DST=$d +LEN=$l +MODE=$m +EXPECT_ERR +CODE=$cd || { fails=$((fails+1)); return; }
  if ! "$PY" - "$work" "$work/e_$tag.log" "$work/e_$tag.log.dump" > "$work/je_$tag.out" 2>&1 <<'PYEOF'
import sys
sys.path.insert(0, sys.argv[1]); import dj
try: sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception: pass
work, log, dump = sys.argv[1], sys.argv[2], sys.argv[3]
pre = dj.load(work + "/mem.hex"); got = dj.load(dump)
mis, first = dj.diffs(got, pre)
d = dj.parse(log); c0 = d["ch"].get(0, {})
print("  ERR IMAGE_BAD=%d CH0 ERR=%s DONE=%s BYTES=%s CODE=%s" % (mis, c0.get("ERR"), c0.get("DONE"), c0.get("BYTES"), c0.get("CODE")))
bad = 0
if mis: bad += 1
if c0.get("ERR") != 1 or c0.get("DONE") != 0 or c0.get("BYTES") != 0: bad += 1
if d["ar"] or d["aw"]: print("  ERR 总线动了 ar=%d aw=%d" % (len(d["ar"]), len(d["aw"]))); bad += 1
sys.exit(1 if bad else 0)
PYEOF
  then echo "JUDGE-RED: ERR[$tag]"; cat "$work/je_$tag.out"; fails=$((fails+1)); else echo "  ERR[$tag] PASS（$why）"; fi
}
err_case len40    $SRC0 $DST0 40       0 1 "LEN=40 不是 32 的倍数"
err_case len48    $SRC0 $DST0 48       0 1 "LEN=48 不是 32 的倍数"
err_case lenzero  $SRC0 $DST0 0        0 2 "LEN=0"
err_case srcaln   $((SRC0+8)) $DST0 32 0 3 "SRC 未 32B 对齐"
err_case dstaln   $SRC0 $((DST0+8)) 32 0 4 "DST 未 32B 对齐"
err_case modebad  $SRC0 $DST0 32       3 5 "MODE=3 非法（引擎层拒绝）"

# ===========================================================================
# JOB 4：背靠背 N=6 笔（D1 的"背靠背"）
# ===========================================================================
echo "---- JOB 4：背靠背 N=6 笔（逐字节 + 每笔自报）----"
if run "b2b.log" +JOB=4 +CH=0 +SRC=$SRC0 +DST=$DST0 +N=6; then
  if "$PY" - "$work" "$work/b2b.log" "$work/b2b.log.dump" > "$work/jb2b.out" 2>&1 <<'PYEOF'
import sys
sys.path.insert(0, sys.argv[1]); import dj
try: sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception: pass
work, log, dump = sys.argv[1], sys.argv[2], sys.argv[3]
gold = dj.load(work + "/b2b_gold.hex"); got = dj.load(dump)
mis, first = dj.diffs(got, gold)
d = dj.parse(log)
print("  B2B 整片镜像 MISMATCH=%d FIRST=%d（%d B）" % (mis, first, len(got)))
print("  B2B 计数 AR=%d AW=%d B=%d" % (d.get("AR_BURSTS", 0), d.get("AW_BURSTS", 0), d.get("B_OK", 0)))
bad = 1 if mis else 0
if d["ch"].get(0, {}).get("BYTES") != 192:  # 最后一笔 LEN=192
    print("  B2B CH0 BYTES=%s（最后一笔应为 192）" % d["ch"].get(0, {}).get("BYTES")); bad += 1
sys.exit(1 if bad else 0)
PYEOF
  then grep -aE '^  B2B' "$work/jb2b.out"; else echo "JUDGE-RED: JOB 4 背靠背"; cat "$work/jb2b.out"; fails=$((fails+1)); fi
else fails=$((fails+1)); fi

# ===========================================================================
# JOB 5：两通道并发（D1 的并发 + 逐通道独立记账）
# ===========================================================================
echo "---- JOB 5：两通道并发（同时忙 + 地址交错 + 各自逐字节 + 逐通道记账）----"
if run "conc.log" +JOB=5 +SRC=$SRC0 +DST=$DST0 +LEN=$LEN5_0 +SRC1=$SRC1 +DST1=$DST1 +LEN1=$LEN5_1; then
  if "$PY" - "$work" "$work/conc.log" "$work/conc.log.dump" "$SRC0" "$DST0" "$LEN5_0" "$SRC1" "$DST1" "$LEN5_1" > "$work/jconc.out" 2>&1 <<'PYEOF'
import sys
sys.path.insert(0, sys.argv[1]); import dj
try: sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception: pass
work, log, dump = sys.argv[1], sys.argv[2], sys.argv[3]
s0, d0, l0, s1, d1, l1 = (int(x) for x in sys.argv[4:10])
pre = dj.load(work + "/mem.hex"); got = dj.load(dump)
bad = 0
m0, f0 = dj.diffs(got[d0:d0+l0], pre[s0:s0+l0], d0)
m1, f1 = dj.diffs(got[d1:d1+l1], pre[s1:s1+l1], d1)
print("  CONC CH0 区逐字节 BAD=%d FIRST=%d / CH1 区 BAD=%d FIRST=%d" % (m0, f0, m1, f1))
if m0 or m1: bad += 1
d = dj.parse(log)
# 地址交错：把 AR/AW 的地址按窗口归到 0/1，要求序列**有来回**（不是"先一台跑完再另一台"）
def seqof(lst, r0, r1):
    out = []
    for a, _ in lst:
        if r0[0] <= a < r0[1]: out.append(0)
        elif r1[0] <= a < r1[1]: out.append(1)
        else: out.append(-1)
    return out
def trans(s):
    return sum(1 for i in range(1, len(s)) if s[i] != s[i-1])
sa = seqof(d["ar"], (s0, s0+l0), (s1, s1+l1))
sw = seqof(d["aw"], (d0, d0+l0), (d1, d1+l1))
print("  CONC AR 交错=%d 次（0=%d 笔 1=%d 笔）" % (trans(sa), sa.count(0), sa.count(1)))
print("  CONC AW 交错=%d 次（0=%d 笔 1=%d 笔）" % (trans(sw), sw.count(0), sw.count(1)))
if trans(sa) < 2 or sa.count(0) == 0 or sa.count(1) == 0:
    print("  CONC AR 未交错 ⇒ 两台没有真正并发"); bad += 1
if trans(sw) < 2 or sw.count(0) == 0 or sw.count(1) == 0:
    print("  CONC AW 未交错 ⇒ 两台没有真正并发"); bad += 1
print("  CONC BOTH_BUSY_SAMPLES=%s" % d.get("BOTH_BUSY_SAMPLES"))
if (d.get("BOTH_BUSY_SAMPLES") or 0) < 3: print("  CONC 两通道从未同时忙"); bad += 1
c0 = d["ch"].get(0, {}); c1 = d["ch"].get(1, {})
print("  CONC CH0 BYTES=%s(期望 %d) CH1 BYTES=%s(期望 %d)" % (c0.get("BYTES"), l0, c1.get("BYTES"), l1))
if c0.get("BYTES") != l0: bad += 1
if c1.get("BYTES") != l1: bad += 1
if c0.get("DONE") != 1 or c1.get("DONE") != 1: bad += 1
if c0.get("ERR") != 0 or c1.get("ERR") != 0: bad += 1
bad += dj.memcheck(d, l0+l1, l0+l1, 2*(l0+l1)//32)
sys.exit(1 if bad else 0)
PYEOF
  then grep -aE '^  CONC|^  MEM' "$work/jconc.out"; else echo "JUDGE-RED: JOB 5 并发"; cat "$work/jconc.out"; fails=$((fails+1)); fi
else fails=$((fails+1)); fi

# ===========================================================================
# JOB 6：abort（D2/§4.6）+ 中止后同通道再跑一笔
# ===========================================================================
echo "---- JOB 6：abort（块边界停下 + 已搬部分逐字节 + 同通道再跑一笔）----"
if run "abort.log" +JOB=6 +CH=0 +SRC=$SRC_A +DST=$DST_A +LEN=$LEN_A +ABORT_AFTER=300; then
  if "$PY" - "$work" "$work/abort.log" "$work/abort.log.dump" "$SRC_A" "$DST_A" "$LEN_A" "$RERUN_OFF" "$RERUN_LEN" > "$work/jab.out" 2>&1 <<'PYEOF'
import sys
sys.path.insert(0, sys.argv[1]); import dj
try: sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception: pass
work, log, dump = sys.argv[1], sys.argv[2], sys.argv[3]
src, dst, ln, r_off, r_len = (int(x) for x in sys.argv[4:9])
pre = dj.load(work + "/mem.hex"); got = dj.load(dump)
d = dj.parse(log)
import re
ab = [l for l in open(log, errors="replace") if l.startswith("ABORT ")]
kv = dict(x.split("=") for x in ab[0].split()[1:] if "=" in x) if ab else {}
by = int(kv.get("BYTES", -1))
print("  ABORT %s" % (ab[0].strip() if ab else "<none>"))
bad = 0
if not (0 <= by < ln): print("  ABORT BYTES=%d 不在 [0,%d)" % (by, ln)); bad += 1
if by % 128 != 0: print("  ABORT BYTES=%d 不是 128 的倍数（未在块边界停）" % by); bad += 1
mis, first = dj.diffs(got[dst:dst+by], pre[src:src+by], dst)   # 已搬出的那一段必须逐字节正确
print("  ABORT 已搬段逐字节 BAD=%d FIRST=%d（%d B）" % (mis, first, by))
if mis: bad += 1
rm, rf = dj.diffs(got[dst+r_off:dst+r_off+r_len], pre[src:src+r_len], dst+r_off)
print("  ABORT 再跑一笔 DST+%d 逐字节 BAD=%d" % (r_off, rm))
if rm: bad += 1
m = d.get("mem") or {}
if m:
    rd, wr = int(m.get("rd", -1)), int(m.get("wr", -1))
    # 排空点在**事务边界**（读等 rlast、写等 B）⇒ 中止那一拍可能正好落在"读完了但还没写出去"之间，
    # 于是内存的 rd 可比 wr 多**一个块**（≤128 B）。wr 必须精确等于"已搬出 + 再跑那一笔"。
    print("  ABORT MEM rd=%d wr=%d（期望 wr=%d+%d=%d，rd ∈ {wr, wr+128}）" % (rd, wr, by, r_len, by + r_len))
    if wr != by + r_len: bad += 1
    if rd not in (wr, wr + 128): bad += 1
sys.exit(1 if bad else 0)
PYEOF
  then grep -aE '^  ABORT' "$work/jab.out"; else echo "JUDGE-RED: JOB 6 abort"; cat "$work/jab.out"; fails=$((fails+1)); fi
else fails=$((fails+1)); fi

# ===========================================================================
echo "==================== 汇总 ===================="
if [ "$fails" -eq 0 ]; then
  echo "D1 = PASS（三向 + 背靠背 + 并发，全部逐字节）"
  echo "D2 = PASS（bytes_moved 对账 + 非法入参响亮 err 且零搬运 + abort 在块边界）"
  echo "RESULT: PASS"
  exit 0
else
  echo "RESULT: FAIL（$fails 处判据不符）"
  exit 1
fi
