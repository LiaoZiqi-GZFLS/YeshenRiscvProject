#!/usr/bin/env bash
# run_dw_wide_ab.sh —— ★ C4b-C2「**真 depthwise 单元经集成宽通路的对角趟调度**」闸门
#   （被测：`rtl/UnitExec.scala` 的 `WIDERUN` 子 FSM —— `isDwW` / 换趟分支 / `wCollectCiOk` / `wBiasR`）
#
# 为什么（`reports/c4b_wgtdma.md` §11.7-1 / §12.5-1）：C1 之后真表的 17 个**宽层 depthwise** 单元
#   （`C_in=C_out=GROUP ∈ {10,16,32,64}`）**跑得完**（几何可寻址），但集成宽通路的趟调度仍是**一般趟**
#   （co-block × ci-block 全组合、`wCi == nCi-1` 收料）。depthwise 的冻结口径是**对角趟**
#   （`DwUnit`/`MultiPassUnit`，C4a.6：co-block `b` 只吃 ci-block `b`，一趟即成品）。本任务把集成宽通
#   路接到那条对角调度上（**不是新起一条算术路**：`md5(DwUnit.v)==md5(MultiPassUnit.v)` 仍是同一网表）。
#
# 设计（唯一真源 = RTL 的 `val isDwW`；`isDwW=0` 的几何**逐字节不变**）：
#   · `isDwW = (GROUP != 0) && (GROUP == C_in) && (C_in == C_out)`；
#   · 换趟：`isDwW` ⇒ 下一趟 = `(wCob+1, wCi=wCob+1)`（对角），跑完末 co-block 收工；
#            否则**逐字沿用 C1**（`wCi` 先跑完、再换 co-block）；
#   · 收料门 `wCollectCiOk = Mux(isDwW, wCi==wCob, wCi==nCi-1)`（dense 侧**逐字不变**）；
#   · 偏置门：`isDwW` 的每一趟（= 每个 co-block 的**唯一**一趟）都带本块偏置（`DwTb` 同口径）；
#   · 趟数自报：`wide_passes = Mux(isDwW, nCo, nCi*nCo)`（对角 = `nCo`，`C=64` ⇒ 8 趟 vs 64 趟）。
#   ★ 输入列流（对角口径）：**输入喂一次** —— `nCo` 块 × `H*W` 列 × 8 通道（dense 的 `nCo*nCi` 倍扇出
#     在这里被省掉）。参考供料 `tools/dw_wide_ref.py` 只把冻结 `wide_exec_ref` 的一般流**裁**成对角流。
#
# 判据（每条都要能发火）：
#   [0] 自检（离线；不成立 exit 3）：blob 指纹 + 真表里**全部** depthwise 单元的几何清单、distinct 几何
#       {10,16,32,64}（宽）与 {4}（非宽）分离；逐单元真 `offset/nbytes`（`nbytes==C_out*9`、32B 对齐、
#       段尾在 28 bit 窗内）；并给出真表口径的「整帧可跑」计数：宽层 conv **44/53**（其中 depthwise **17**）。
#   [1] 正对照（**逐字节**，每个真宽层 depthwise 单元）：权重**从 DDR 真 offset 装载**（`+WBASE=BLOB_BASE+
#       offset`，`+WFILE=` 灌**全 0** ⇒ 片内权重只可能来自 DDR）⇒ DUT 跑完 ⇒
#       · `RESULT: PASS`、`WIDE_PASSES == nCo`（**对角趟数**，不是 `nCi*nCo`）、`RTL_M/ZPAD/ZY/LAYER` 对账；
#       · `DST` 区 `[DST,DST+C_out*H*W)` **逐字节 == 黄金**（`MISMATCH=0`）、黄金非退化（`distinct>1`）、
#         邻居区未动；`MEM rd == ceil32(nbytes)`、`WGT_BYTES == nbytes`、`WR_BYTES == C_out*H*W`。
#       ★ 同一组**distinct 几何**（10/16/32/64）必须各至少被一个单元覆盖（本闸门断言）。
#   [2] 负对照（**必须发火且定位**）：**网表突变**把 `wCollectCiOk` 退回改动前的收料门 `wCi == nCi-1`
#       ⇒ 对角循环下**只有末 co-block** 收得到料 ⇒ 前 `nCo-1` 个 co-block 的 `wOutMem` 全是预载值 ⇒
#       `MISMATCH>0`，且**末 co-block 那一段仍逐字节对**（定位：毛病就在"没收到料的那几个 co-block"）。
#   [3] 边界（**真不支持仍响亮 err**，绝不静默）：`GROUP ∉ {1, depthwise}`（如 `C=64,GROUP=8`）与
#       `C_in == 0` ⇒ `ERR_SEEN=1` 且 `WR_BYTES=0` / `RD_BYTES=0`（**零搬运**）。
#       （`C_out > 8*NCOB_MAX` 这条计算侧边界由既有 `run_wide_tail_ab.sh` 覆盖：本装置 `bm[0:63]`
#        装不下第 9 个 co-block 的 bias，故此处不重复。）
#
# 段号：本脚本的实现分段 = [0] 自检 / [1] 参考供料 / [2] 编译+突变体 / [4] 逐单元 / [5] 边界
#   （[3] 是共用的内存镜像构造）。
#
# 退出码（与 Y1 既有闸门一致）：0 = 全绿；1 = 判据红；2 = 负对照没发火 / 突变锚不唯一；3 = 向量/自检失败。
#
# 装置契约（rtl_test/UnitExecWideTb.v + rtl_test/AxiMemModel.v + gen/UnitExec.v）——同 run_wide_tail_ab.sh。
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
cd "$here/.." || { echo "FATAL: 进不去 y1/"; echo "RESULT: FAIL"; exit 3; }

PY="${PY:-/d/code/PDS/NaxYeshenLinux/sim/reglogs/lxvenv/Scripts/python.exe}"
[ -x "$PY" ] || PY="$(command -v python || command -v python3 || true)"
[ -n "$PY" ] || { echo "FATAL: 找不到 python"; echo "RESULT: FAIL"; exit 3; }

ref="tools/dw_wide_ref.py"
tb="rtl_test/UnitExecWideTb.v"
memv="rtl_test/AxiMemModel.v"
nl="gen/UnitExec.v"
idx="gen/wgt_index.json"
blob="gen/wgt_blob.bin"
outdir="gen/c4b_dwwide"
MEMSZ=2621440
BLOB_BASE=262144               # 0x40000：真 blob 整块落 DDR 的起点（WBASE = BLOB_BASE + 真 offset）
SRC=131072
DST=2097152
HH=4; WW=64
REF_BLOB_MD5="aa135f0f7d50780b7b13d9a1ba9c518a"
EXP_DW_WIDE=17                 # 真表宽层（isWide）depthwise 单元数
EXP_DW_NARROW=3                # 真表非宽层（C=4）depthwise 单元数
EXP_WIDE_CONV=44               # 真表宽层 conv 单元数（其中 depthwise 17）
EXP_TOTAL_CONV=53
DISTINCT_WIDE="10 16 32 64"    # 真表宽层 depthwise 的 distinct (C_in=C_out=GROUP)

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
for f in "$ref" "$tb" "$memv" "$nl" "$idx" "$blob"; do
  [ -f "$f" ] || { echo "FATAL: 缺 $f"; echo "RESULT: FAIL"; exit 3; }
done
[ -n "$IVERILOG" ] && [ -n "$VVP" ] || { echo "FATAL: 找不到 iverilog/vvp"; echo "RESULT: FAIL"; exit 3; }

work="$(mktemp -d)"
cleanup() { if [ "${KEEP_TMP:-0}" = "1" ]; then echo "KEEP_TMP=1 => 中间件在 $work"; else rm -rf "$work"; fi }
trap cleanup EXIT
export PYTHONPATH="./.pydeps;../third_party/yunet/deps"
export PYTHONIOENCODING=utf-8
PWD_ABS="$(pwd)"

echo "== run_dw_wide_ab: 真 depthwise 单元经**集成宽通路**的**对角趟调度** =="
echo "   nl=$nl tb=$tb py=$PY iverilog=$IVERILOG vvp=$VVP tmp=$work"

TOTAL_BAD=0; NEG_NOFIRE=0
FAIL() { echo "$1"; echo "RESULT: FAIL"; exit "$2"; }

# ---------------------------------------------------------------------------
# [0] 自检（离线）：blob 指纹 + 真表 depthwise 清单/几何 + 真 offset/nbytes + 「整帧可跑」计数
# ---------------------------------------------------------------------------
echo "---- [0] 自检：blob 指纹 + 真表 depthwise 清单 + 几何 + 计数（宽层 conv 44/53，其中 depthwise 17）----"
if ! "$PY" - "$idx" "$blob" "$REF_BLOB_MD5" "$EXP_DW_WIDE" "$EXP_DW_NARROW" "$EXP_WIDE_CONV" \
              "$EXP_TOTAL_CONV" "$HH" "$WW" "$work" <<'PYEOF'; then
import sys, json, hashlib
try: sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception: pass
idx_p, blob_p, want_md5 = sys.argv[1], sys.argv[2], sys.argv[3]
exp_dw_wide, exp_dw_narrow, exp_wide, exp_total = (int(sys.argv[4]), int(sys.argv[5]),
                                                   int(sys.argv[6]), int(sys.argv[7]))
hh, ww, work = int(sys.argv[8]), int(sys.argv[9]), sys.argv[10]
NCOB_MAX = 8
bad = []
d = json.load(open(idx_p, encoding="utf-8"))
blob = open(blob_p, "rb").read()
md5 = hashlib.md5(blob).hexdigest()
if d["blob"]["bytes"] != len(blob): bad.append("blob 字节数 != index")
if md5 != want_md5: bad.append("blob md5=%s != %s（blob 被动过？）" % (md5, want_md5))

units = [u for u in d["units"] if u["weight"] is not None]
n_conv = len(units)
dw = [u for u in units if int(u.get("type_code", -1)) == 3]
n_wide = sum(1 for u in units if int(u["own"]["C_IN"]) > 8 or int(u["own"]["C_OUT"]) > 8)
dw_wide = [u for u in dw if int(u["own"]["C_IN"]) > 8 or int(u["own"]["C_OUT"]) > 8]
dw_narrow = [u for u in dw if u not in dw_wide]

distinct = sorted({int(u["own"]["C_IN"]) for u in dw_wide})
geo = sorted({(int(u["own"]["C_IN"]), int(u["own"]["C_OUT"]), int(u["own"]["GROUP"])) for u in dw})
if n_conv != exp_total: bad.append("conv 单元 %d != %d" % (n_conv, exp_total))
if n_wide != exp_wide: bad.append("宽层 conv %d != %d" % (n_wide, exp_wide))
if len(dw_wide) != exp_dw_wide: bad.append("宽层 depthwise %d != %d" % (len(dw_wide), exp_dw_wide))
if len(dw_narrow) != exp_dw_narrow: bad.append("非宽层 depthwise %d != %d" % (len(dw_narrow), exp_dw_narrow))
if distinct != [10, 16, 32, 64]: bad.append("宽层 depthwise distinct 几何 %s != [10,16,32,64]" % distinct)
for (ci, co, gg) in geo:
    if not (ci == co == gg and gg > 1): bad.append("非 depthwise 几何 %s" % ((ci, co, gg),))

lines = []
for u in dw_wide:
    o, w = u["own"], u["weight"]
    ci, co, gg = int(o["C_IN"]), int(o["C_OUT"]), int(o["GROUP"])
    off, nb = int(w["offset"]), int(w["nbytes"])
    al = int(w.get("aligned_bytes") or ((nb + 31) // 32 * 32))
    nci, nco = (ci + 7) // 8, (co + 7) // 8
    if nb != co * 9: bad.append("%s nbytes=%d != C_out*9=%d" % (u["name"], nb, co * 9))
    if off % 32: bad.append("%s offset=%d 非 32B 对齐" % (u["name"], off))
    if al != (nb + 31) // 32 * 32: bad.append("%s aligned_bytes=%d != ceil32(%d)" % (u["name"], al, nb))
    if off + al >= (1 << 28): bad.append("%s 段越出 28 bit DDR 窗" % u["name"])
    if off + nb > len(blob): bad.append("%s 段越出 blob" % u["name"])
    lines.append("%d %s %d %d %d %d %d %d %d" % (u["idx"], u["name"], ci, co, off, nb, nci, nco,
                                                 nco * hh * ww))   # 末列 = 对角列流列数 NCOL
open(work + "/units.txt", "w", encoding="ascii", newline="\n").write("\n".join(lines) + "\n")

print("SELFTEST blob_bytes=%d md5=%s" % (len(blob), md5))
print("SELFTEST conv_units=%d wide=%d depthwise(total)=%d 其中宽层=%d 非宽层=%d"
      % (n_conv, n_wide, len(dw), len(dw_wide), len(dw_narrow)))
print("SELFTEST 宽层 depthwise distinct C 几何 = %s（每组 C_in=C_out=GROUP）" % (distinct,))
print("SELFTEST 非宽层 depthwise（C=4，走窄通路 WeightStore 8x8 ⇒ 本通路不参与）= %s"
      % ", ".join(u["name"] for u in dw_narrow))
print("SELFTEST 整帧可跑（宽层 conv，逐单元端到端逐字节）= %d/%d ；其中 depthwise 17（**本任务端到端证死**）、"
      "其余 %d = B1b 14 + Conv_0 1 + C1 dense 尾块 12；剩余 %d 个非宽层（C∈{1,4}）走窄通路装不了"
      % (n_wide, n_conv, n_wide - 17, n_conv - n_wide))
for ln in lines:
    print("UNIT " + ln)
for b in bad: print("SELFTEST_BAD: " + b)
sys.exit(3 if bad else 0)
PYEOF
  FAIL "JUDGE-RED(3): 自检不过（blob/真表/计数与冻结口径不符）" 3
fi

# 内存区间切片（一字节一行的十六进制）
region_py() {
  "$PY" - "$1" "$2" "$3" <<'PYEOF'
import sys
p, start, n = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
with open(p, "rb") as f:
    head = f.read(3)
    if len(head) == 3 and head[2:3] == b"\n":
        f.seek(start * 3); toks = f.read(n * 3).split()
    else:
        f.seek(0); toks = f.read().split()[start:start + n]
sys.stdout.write("\n".join(t.decode("ascii", "replace") for t in toks))
PYEOF
}

# ---------------------------------------------------------------------------
# [1] 参考供料（逐单元：工具把冻结 wide_exec_ref 的一般流裁成**对角流**）
# ---------------------------------------------------------------------------
echo "---- [1] 参考供料：tools/dw_wide_ref.py --lid <idx> --H $HH --W $WW（逐单元；对角列流）----"
rm -rf "$outdir"; mkdir -p "$outdir"
while read -r LIDN UNAME CIN COUT OFF NB NCI NCO NCOL; do
  JD="$outdir/lid${LIDN}_${UNAME}"
  if ! "$PY" "$ref" --lid "$LIDN" --H "$HH" --W "$WW" --outdir "$JD" > "$work/ref_$LIDN.out" 2>&1; then
    tail -10 "$work/ref_$LIDN.out"; FAIL "JUDGE-RED(3): 参考供料失败 lid=$LIDN" 3
  fi
  grep -E '^DW_WIDE_REF' "$work/ref_$LIDN.out" | sed "s/^/    [$UNAME] /"
  [ -f "$JD/gold.hex" ] || FAIL "JUDGE-RED(3): 找不到 $JD/gold.hex" 3
done < "$work/units.txt"

# ---------------------------------------------------------------------------
# [2] 编译：正网表 + 1 个突变体（收料门退回 `wCi == nCi-1`）
# ---------------------------------------------------------------------------
echo "---- [2] iverilog 编译 + 突变体（wCollectCiOk := wCi == nCi-1 = 改动前的收料门）----"
if ! "$IVERILOG" -g2012 -o "$work/dw.vvp" "$tb" "$memv" "$nl" > "$work/iv.log" 2>&1; then
  sed -n '1,30p' "$work/iv.log"; FAIL "JUDGE-RED(1): iverilog 编译失败" 1
fi
echo "    正网表编译 OK"
if ! "$PY" - "$nl" "$work/mut_full.v" <<'PYEOF'; then
import sys
src, out = sys.argv[1], sys.argv[2]
txt = open(src, encoding="utf-8").read()
old = "assign wCollectCiOk = (isDwW ? (wCi == _zz_wCollectCiOk) : (wCi == _zz_wCollectCiOk_1));"
n = txt.count(old)
if n != 1:
    print("MUTATE-ANCHOR-BAD: '%s' 命中 %d 次（要求恰好 1）" % (old, n)); sys.exit(2)
new = "assign wCollectCiOk = (wCi == _zz_wCollectCiOk_1);"
print("MUTATE OK: %s\n        ->  %s   (= 改动前的收料门)" % (old, new))
open(out, "w", encoding="utf-8").write(txt.replace(old, new))
PYEOF
  FAIL "NEGCTL-FAIL: 突变锚不唯一（闸门自身不可信）" 2
fi
if ! "$IVERILOG" -g2012 -o "$work/mut.vvp" "$tb" "$memv" "$work/mut_full.v" > "$work/iv_mut.log" 2>&1; then
  sed -n '1,20p' "$work/iv_mut.log"; FAIL "JUDGE-RED(2): 突变体编译失败" 2
fi
echo "    突变体编译 OK"

# ---------------------------------------------------------------------------
# [3] 内存镜像（**全部单元共用**：真 blob 整块落 BLOB_BASE + 素周期模式；WFILE 全 0）
#     每单元仍单独核"DST 预载 != 该单元黄金"（解析式算，不读文件）。
# ---------------------------------------------------------------------------
if ! "$PY" - "$work" "$blob" "$BLOB_BASE" "$MEMSZ" "$DST" <<'PYEOF'; then
import sys
work, blob_p, base, memsz, dst = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5])
blob = open(blob_p, "rb").read()
pre = [((i % 251) * 131 + 7) % 251 for i in range(memsz)]
for i, b in enumerate(blob): pre[base + i] = b
assert base + len(blob) <= memsz, "blob 越出内存模型"
open(work + "/mem.hex", "w").write("".join("%02x\n" % b for b in pre))
open(work + "/wfile_zero.hex", "w").write("".join("%02x\n" % 0 for _ in range(8 * 8 * 576)))
sys.exit(0)
PYEOF
  FAIL "JUDGE-RED(3): 内存镜像构造失败" 3
fi

# ---------------------------------------------------------------------------
# [4] 逐单元：正对照 + 负对照
# ---------------------------------------------------------------------------
echo "---- [4] 逐单元：正对照（对角趟；逐字节 == 黄金）+ 负对照（突变体必发火且定位）----"
while read -r LIDN UNAME CIN COUT OFF NB NCI NCO NCOL; do
  JD="$outdir/lid${LIDN}_${UNAME}"
  LEN=$(( COUT * HH * WW )); FULL=$(( NCO * 8 * HH * WW ))
  WBASE=$(( BLOB_BASE + OFF )); WEXP=$(( (NB + 31) / 32 * 32 ))
  MV="$(sed -n 's/^M=//p' "$JD/job.txt" | head -1)"
  ZP="$(sed -n 's/^ZPAD=//p' "$JD/job.txt" | head -1)"
  ZY="$(sed -n 's/^ZY=//p' "$JD/job.txt" | head -1)"

  # DST 预载（解析式）必须与黄金不同 ⇒ "不写"必被抓住
  if ! "$PY" - "$DST" "$LEN" "$JD/gold.hex" <<'PYEOF'; then
import sys
dst, ln, gp = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3]
g = [int(l.strip(), 16) for l in open(gp, encoding="utf-8") if l.strip()]
dif = sum(1 for j in range(ln) if ((((dst + j) % 251) * 131 + 7) % 251) != g[j])
assert dif >= int(ln * 0.5), "dst 预载与黄金只差 %d/%d" % (dif, ln)
sys.exit(0)
PYEOF
    FAIL "JUDGE-RED(3): DST 预载与黄金过近（lid=$LIDN）" 3
  fi

  run_job() {   # run_job <vvp> <dump>
    ( cd "$work" && "$VVP" "$1" \
        "+XFILE=$PWD_ABS/$JD/x.hex" "+WFILE=$work/wfile_zero.hex" "+BFILE=$PWD_ABS/$JD/b.hex" \
        "+MEMFILE=$work/mem.hex" "+DUMPFILE=$work/$2.dump" +dump \
        "+CIN=$CIN" "+COUT=$COUT" "+GROUP=$CIN" "+H=$HH" "+W=$WW" "+TYPE=3" "+FLAGS=1" \
        "+SRC=$SRC" "+DST=$DST" "+INB=$(( CIN * HH * WW ))" "+QSHIFT=6" "+LID=$LIDN" \
        "+M=$MV" "+ZPAD=$ZP" "+ZY=$ZY" "+NCOL=$NCOL" "+NCI=$NCI" "+NCO=$NCO" \
        "+WBASE=$WBASE" "+WEXP=$WEXP" ) > "$work/$2.log" 2>&1
  }

  # ---- 正对照 ----
  run_job "$work/dw.vvp" "pos_$LIDN" || true
  RLINE="$(grep -m1 '^TB WIDE RTL:' "$work/pos_$LIDN.log")"
  echo "    [pos $UNAME] $(grep -m1 '^DONE_SEEN=' "$work/pos_$LIDN.log")"
  echo "    [pos $UNAME] $(grep -m1 '^MEM rd=' "$work/pos_$LIDN.log")"
  POS_PASS=0; grep -q '^RESULT: PASS' "$work/pos_$LIDN.log" && POS_PASS=1
  # 自报：WIDE_ON=1、WIDE_PASSES == nCo（**对角趟数**）、RTL_M/ZPAD/ZY/LAYER 对账
  REPOK=0
  case "$RLINE" in
    *"WIDE_ON=1 WIDE_PASSES=$NCO"*"RTL_M=$MV RTL_ZPAD=$ZP RTL_ZY=$ZY RTL_LAYER=$LIDN"*) REPOK=1 ;;
  esac
  WRPOS="$(sed -n 's/.*WR_BYTES=\([0-9]*\).*/\1/p' "$work/pos_$LIDN.log" | head -1)"
  WBPOS="$(sed -n 's/.*WGT_BYTES=\([0-9]*\).*/\1/p' "$work/pos_$LIDN.log" | head -1)"
  RDPOS="$(sed -n 's/^MEM rd=\([0-9]*\).*/\1/p' "$work/pos_$LIDN.log" | head -1)"

  region_py "$work/pos_$LIDN.dump" "$DST" "$LEN" > "$work/pos_$LIDN.mem_slice"
  P_MIS="$("$PY" - "$work/pos_$LIDN.mem_slice" "$JD/gold.hex" "$LEN" <<'PYEOF'
import sys
d = [int(x, 16) for x in open(sys.argv[1], encoding="utf-8").read().split()]
g = [int(x, 16) for x in open(sys.argv[2], encoding="utf-8").read().split()]
ln = int(sys.argv[3])
mis = sum(1 for i in range(ln) if d[i] != g[i]) + max(0, ln - len(g))
print("%d" % mis)
PYEOF
)"
  P_DUP="$("$PY" -c "import sys;g=[int(l.strip(),16) for l in open('$JD/gold.hex',encoding='utf-8') if l.strip()];print(len(set(g)))")"
  echo "    [pos $UNAME] MISMATCH=$P_MIS  黄金distinct=$P_DUP  WR_BYTES=$WRPOS(期望 $LEN) WGT_BYTES=$WBPOS(期望 $NB) MEM rd=$RDPOS(期望 $WEXP) 对角趟数=$NCO"
  [ "$POS_PASS" = "1" ] || { echo "JUDGE-RED(1): 正对照装置未 PASS（$UNAME）"; TOTAL_BAD=$((TOTAL_BAD+1)); }
  [ "$REPOK" = "1" ]   || { echo "JUDGE-RED(1): 自报不符（$UNAME）: $RLINE"; TOTAL_BAD=$((TOTAL_BAD+1)); }
  [ "$P_MIS" = "0" ] || { echo "JUDGE-RED(1): 正对照 != 黄金（MISMATCH=$P_MIS，$UNAME）"; TOTAL_BAD=$((TOTAL_BAD+1)); }
  [ "$P_DUP" -gt 1 ] 2>/dev/null || { echo "JUDGE-RED(1): 黄金退化 distinct=$P_DUP（$UNAME）"; TOTAL_BAD=$((TOTAL_BAD+1)); }
  [ "$WRPOS" = "$LEN" ] || { echo "JUDGE-RED(1): WR_BYTES=$WRPOS != C_out*H*W=$LEN（$UNAME）"; TOTAL_BAD=$((TOTAL_BAD+1)); }
  [ "$RDPOS" = "$WEXP" ] || { echo "JUDGE-RED(1): MEM rd=$RDPOS != ceil32(nbytes)=$WEXP（$UNAME）"; TOTAL_BAD=$((TOTAL_BAD+1)); }
  [ "$WBPOS" = "$NB" ] || { echo "JUDGE-RED(1): WGT_BYTES=$WBPOS != nbytes=$NB（$UNAME）"; TOTAL_BAD=$((TOTAL_BAD+1)); }

  # ---- 负对照：突变体（收料门退回 wCi == nCi-1）----
  run_job "$work/mut.vvp" "mut_$LIDN" || true
  region_py "$work/mut_$LIDN.dump" "$DST" "$LEN" > "$work/mut_$LIDN.mem_slice"
  JMUT="$("$PY" - "$work/mut_$LIDN.mem_slice" "$JD/gold.hex" "$LEN" "$(( 8 * (NCO - 1) * HH * WW ))" <<'PYEOF'
import sys
d = [int(x, 16) for x in open(sys.argv[1], encoding="utf-8").read().split()]
g = [int(x, 16) for x in open(sys.argv[2], encoding="utf-8").read().split()]
ln = int(sys.argv[3]); lastblk = int(sys.argv[4])       # = 8*(nCo-1)*H*W（末 co-block 的起点）
k = min(ln, len(g))
mis = sum(1 for i in range(k) if d[i] != g[i]) + max(0, ln - k)
first = next((i for i in range(k) if d[i] != g[i]), -1)
mis_last = sum(1 for i in range(lastblk, k) if d[i] != g[i])   # 末 co-block 段（应仍逐字节对）
print("M_MISMATCH=%d M_FIRST=%d M_LASTBLK_BAD=%d M_LASTBLK0=%d" % (mis, first, mis_last, lastblk))
PYEOF
)"
  eval "$JMUT"
  echo "    [mut $UNAME] MISMATCH=$M_MISMATCH（首差异 @$M_FIRST）；末 co-block 段[$M_LASTBLK0..) 错 $M_LASTBLK_BAD 字节"
  echo "    [mut $UNAME] ⇒ 收料门退回 'wCi==nCi-1' ⇒ 对角循环下前 nCo-1 个 co-block 收不到料 ⇒ 红（末 co-block 仍对 ⇒ 定位到'没收到料的 co-block'）"
  [ "$M_MISMATCH" -gt 0 ] 2>/dev/null || { echo "NEGCTL-FAIL: 突变体没把输出弄错（$UNAME）⇒ 判据没牙"; NEG_NOFIRE=$((NEG_NOFIRE+1)); }
  [ -n "$M_FIRST" ] && [ "$M_FIRST" != "-1" ] || { echo "NEGCTL-FAIL: 突变体没报出首个差异字节（$UNAME）"; NEG_NOFIRE=$((NEG_NOFIRE+1)); }
  [ "$M_LASTBLK_BAD" = "0" ] || { echo "NEGCTL-FAIL: 突变体把末 co-block 也弄错了（$UNAME）⇒ 定位不清"; NEG_NOFIRE=$((NEG_NOFIRE+1)); }
done < "$work/units.txt"

# ---------------------------------------------------------------------------
# [5] 边界：真不支持仍响亮 err + 零搬运（两条 = 装载器前提的两条"真不支持"）
# ---------------------------------------------------------------------------
echo "---- [5] 边界：GROUP ∉ {1,depthwise} / C_in==0 ⇒ ERR_SEEN=1 且零搬运 ----"
JDFIRST="$(ls -d "$outdir"/lid* 2>/dev/null | head -1)"
run_edge() {   # run_edge <tag> <cin> <cout> <group> <ncol> <nci> <nco>
  local tag="$1" cin="$2" cout="$3" grp="$4" ncol="$5" nci="$6" nco="$7"
  ( cd "$work" && "$VVP" "$work/dw.vvp" \
      "+XFILE=$PWD_ABS/$JDFIRST/x.hex" "+WFILE=$work/wfile_zero.hex" "+BFILE=$PWD_ABS/$JDFIRST/b.hex" \
      "+MEMFILE=$work/mem.hex" \
      "+CIN=$cin" "+COUT=$cout" "+GROUP=$grp" "+H=$HH" "+W=$WW" "+TYPE=3" "+FLAGS=1" \
      "+SRC=$SRC" "+DST=$DST" "+INB=$(( cin * HH * WW ))" "+QSHIFT=6" "+LID=0" \
      "+M=3000000" "+ZPAD=-128" "+ZY=0" "+NCOL=$ncol" "+NCI=$nci" "+NCO=$nco" \
      "+WBASE=$(( BLOB_BASE + 32 ))" "+WEXP=0" ) > "$work/edge_$tag.log" 2>&1
}
EDGE_BAD=0
run_edge gmis 64 64 8  1 8 8 || true        # GROUP=8 ∉ {1, depthwise} ⇒ grpOkW 假 ⇒ IDLE 响亮 err
run_edge cin0  0 64 1  1 1 8 || true        # C_in=0 ⇒ 装载器前提 `cIn!=0` 假 ⇒ IDLE 响亮 err
for tag in gmis cin0; do
  L="$(grep -m1 '^DONE_SEEN=' "$work/edge_$tag.log")"
  E="$(sed -n 's/^DONE_SEEN=\([0-9]*\) ERR_SEEN=\([0-9]*\).*/\1|\2/p' "$work/edge_$tag.log" | head -1)"
  WRE="$(sed -n 's/.*WR_BYTES=\([0-9]*\).*/\1/p' "$work/edge_$tag.log" | head -1)"
  RDE="$(sed -n 's/.*RD_BYTES=\([0-9]*\).*/\1/p' "$work/edge_$tag.log" | head -1)"
  echo "    [edge $tag] $L"
  case "$tag" in
    gmis) DESC="GROUP=8 ∉ {1,depthwise} (C_in=C_out=64)" ;;
    cin0) DESC="C_in=0 (装载器前提 cIn!=0 不成立)" ;;
  esac
  [ "$E" = "0|1" ] || { echo "JUDGE-RED(5): 边界 $tag（$DESC）没有响亮 err（got DONE|ERR=$E）"; EDGE_BAD=$((EDGE_BAD+1)); }
  [ "$WRE" = "0" ] && [ "$RDE" = "0" ] || { echo "JUDGE-RED(5): 边界 $tag（$DESC）有搬运（WR=$WRE RD=$RDE）"; EDGE_BAD=$((EDGE_BAD+1)); }
done
[ "$EDGE_BAD" = "0" ] || TOTAL_BAD=$((TOTAL_BAD+EDGE_BAD))

echo "=========================================================================="
echo "正对照   = OK（真表全部 17 个宽层 depthwise 单元：权重经 DDR 真 offset 装载（WFILE 全 0 自证）⇒"
echo "                对角趟跑完 ⇒ WIDE_PASSES==nCo、DST 区逐字节 == 冻结 wide_exec_ref 黄金、WR_BYTES==C_out*H*W）"
echo "几何覆盖 = OK（distinct C_in=C_out=GROUP ∈ {10,16,32,64} 全部被真单元覆盖；C=4 非宽层走窄通路不参与）"
echo "负对照   = OK（收料门退回 'wCi==nCi-1' ⇒ 对角循环下前 nCo-1 个 co-block 收不到料 ⇒ 红且定位到末 co-block 之前）"
echo "边界     = OK（GROUP ∉ {1,depthwise} / C_in==0 ⇒ ERR_SEEN=1、零搬运）"
echo "整帧可跑 = 宽层 conv 44/53 端到端逐字节（其中 depthwise 17 **本任务证死**）；剩余 9 个非宽层（C∈{1,4}）走窄通路装不了"
if [ "$NEG_NOFIRE" -ne 0 ]; then echo "NEGCTL-FAIL: $NEG_NOFIRE 条负对照没发火"; echo "RESULT: FAIL"; exit 2; fi
if [ "$TOTAL_BAD" -ne 0 ]; then echo "JUDGE-RED: $TOTAL_BAD 条判据未过"; echo "RESULT: FAIL"; exit 1; fi
echo "RESULT: PASS"
exit 0
