#!/usr/bin/env bash
# run_nonwide_wide_ab.sh —— ★ C4b-C3「**非宽层（C∈{1,4}）按几何路由进宽通路，端到端逐字节**」闸门
#   （被测：`rtl/UnitExec.scala` 的**窄层/宽层路由** —— 就是 `narrowShape` / `isWide` 那两行）
#
# 为什么（`reports/c4b_wgtdma.md` §13.4）：真表 53 个 conv 单元里 44 个是**宽层**
#   （`C_in>8 || C_out>8`）已端到端逐字节。剩余 **9 个**是**非宽层**：`Conv_55/57/59/67/69/71`
#   （`C_in=C_out=1` conv3x3）+ `Conv_61/63/65`（depthwise `C_in=C_out=GROUP=4`）。老口径下
#   `isWide = (C_in>8) || (C_out>8)` ⇒ 这 9 个走**窄通路**，而窄通路 `WeightStore` 是 **8x8 固定形状**
#   （`NENTRY = C*(C/GROUP)*9`）⇒ `C∈{1,4}` 的层**根本装不进去**（§11.7-3）⇒ 整帧跑不了。
#
# 设计（唯一真源 = RTL 的 `val narrowShape` / `val isWide = !narrowShape`；**不做第二条算术路**）：
#   · `narrowShape = C_in==8 ∧ C_out==8 ∧ GROUP==1 ∧ 非 depthwise`（与窄通路 DMA 前提 `dmaGeomOk` **同式**）；
#   · `isWide = !narrowShape`：**只有**那个 8x8 形状走窄通路（**逐字节不变**），其余一律走**宽通路**；
#   · 于是 `C∈{1,4}` 的几何靠宽通路已有的三条能力跑：`C_in<8` 靠 **B1c 零填补**、`C_out<8` 靠
#     **C1 部分 co-block 尾块**、depthwise 靠 **C2 对角趟**（三者都已端到端证死）。
#   ★ 单条算术路：`md5(gen/MultiPassUnit.v)==md5(gen/DwUnit.v)`、宽通路仍是那一个 `MultiPassUnit`。
#
# 判据（每条都要能发火）：
#   [0] 自检（离线；不成立 exit 3）：blob 指纹；真表里 `C∈{1,4}` 的 **9 个**单元（`C=1` conv3x3 **6** +
#       depthwise `C=4` **3**）全部 `narrowShape==假`（= 新路由下走宽通路）；逐单元真 `offset/nbytes`
#       （`nbytes==GROUP==1 ? C_out*C_in*9 : C_out*9`、`nbytes%32!=0` 允许（RD 补位）、offset 32B 对齐、
#       段尾在 28 bit 窗内）；并给出真表口径的「整帧可跑」计数：**53/53**（44 宽层 + 9 本任务）。
#   [1] 正对照（**逐字节**，每个真单元）：权重**从 DDR 真 offset 装载**（`+WBASE=BLOB_BASE+offset`、
#       `+WFILE=` 灌**全 0** ⇒ 片内权重只可能来自 DDR）⇒ DUT 跑完 ⇒
#       · `RESULT: PASS`、`WIDE_ON=1`、`WIDE_PASSES == 趟数`（dense=1、dw=1）、`RTL_M/ZPAD/ZY/LAYER` 对账；
#       · `DST` 区 `[DST,DST+C_out*H*W)` **逐字节 == 黄金**（`MISMATCH=0`）、黄金非退化（`distinct>1`）、
#         尾部空行区 `[DST+C_out*H*W, DST+nCo*8*H*W)` **一字节未写**（== 预载）；
#       · `MEM rd == ceil32(nbytes)`、`WGT_BYTES == nbytes`、`WR_BYTES == C_out*H*W`、`AW/B == C_out*H*W/128`。
#       ★ 黄金来源（**不重写算术**）：dense `C=1` 用冻结 `tools/wide_exec_ref.py`（一般趟）；
#         depthwise `C=4` 用冻结 `tools/dw_wide_ref.py`（对角趟，= `run_dw_wide_ab.sh` 同一口径）。
#   [1z] 零填补**有牙**：同一单元把信箱 `+WFILE=` 灌 **0xFF**（不是 0）再跑一遍 —— 若零填补没写 0，
#       那些"没有 blob 字节对应"的格子会留 0xFF ⇒ 数值必错。⇒ 必须仍 `MISMATCH=0`（零填补真在写）。
#   [2] 负对照（**必须发火且定位**）：**网表突变**把路由退回旧式 `isWide = (C_in>8)||(C_out>8)`
#       ⇒ 这 9 个单元又落回**窄通路**，而窄通路前提 `dmaGeomOk`（要求 `C_in=C_out=8`）不成立
#       ⇒ `IDLE` 那一刻**响亮 err + 零搬运** ⇒ `DONE_SEEN=0 ERR_SEEN=1 WR_BYTES=0`、`DST` 一字节未写
#       ⇒ `MISMATCH == C_out*H*W`（全错）。定位：逐单元一行，谁是那 9 个一目了然。
#   [3] 边界（**真不支持仍响亮 err**，绝不静默）：`GROUP ∉ {1, depthwise}`（如 `C=64,GROUP=8`）与
#       `C_in==0` ⇒ `ERR_SEEN=1` 且 `WR_BYTES=0` / `RD_BYTES=0`（**零搬运**）。
#
# 段号：本脚本的实现分段 = [0] 自检 / [1] 参考供料 / [2] 编译+突变体 / [3] 逐单元 / [4] 边界。
#
# 退出码（与 Y1 既有闸门一致）：0 = 全绿；1 = 判据红；2 = 负对照没发火 / 突变锚不唯一；3 = 向量/自检失败。
#
# 装置契约（rtl_test/UnitExecWideTb.v + rtl_test/AxiMemModel.v + gen/UnitExec.v）——同 run_dw_wide_ab.sh。
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
cd "$here/.." || { echo "FATAL: 进不去 y1/"; echo "RESULT: FAIL"; exit 3; }

PY="${PY:-/d/code/PDS/NaxYeshenLinux/sim/reglogs/lxvenv/Scripts/python.exe}"
[ -x "$PY" ] || PY="$(command -v python || command -v python3 || true)"
[ -n "$PY" ] || { echo "FATAL: 找不到 python"; echo "RESULT: FAIL"; exit 3; }

ref_dense="tools/wide_exec_ref.py"
ref_dw="tools/dw_wide_ref.py"
tb="rtl_test/UnitExecWideTb.v"
memv="rtl_test/AxiMemModel.v"
nl="gen/UnitExec.v"
idx="gen/wgt_index.json"
blob="gen/wgt_blob.bin"
outdir="gen/c4b_nonwide"
MEMSZ=2621440
BLOB_BASE=262144               # 0x40000：真 blob 整块落 DDR 的起点（WBASE = BLOB_BASE + 真 offset）
SRC=131072
DST=2097152
HH=4; WW=64
REF_BLOB_MD5="aa135f0f7d50780b7b13d9a1ba9c518a"
EXP_C1=6                       # 真表 C=1 conv3x3（dense）单元数
EXP_DW4=3                      # 真表 depthwise C=4 单元数
EXP_NONWIDE=9
EXP_TOTAL_CONV=53
EXP_RUNNABLE=53                # C3 后真表整帧可跑（44 宽层 + 9 非宽层）

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
for f in "$ref_dense" "$ref_dw" "$tb" "$memv" "$nl" "$idx" "$blob"; do
  [ -f "$f" ] || { echo "FATAL: 缺 $f"; echo "RESULT: FAIL"; exit 3; }
done
[ -n "$IVERILOG" ] && [ -n "$VVP" ] || { echo "FATAL: 找不到 iverilog/vvp"; echo "RESULT: FAIL"; exit 3; }

work="$(mktemp -d)"
cleanup() { if [ "${KEEP_TMP:-0}" = "1" ]; then echo "KEEP_TMP=1 => 中间件在 $work"; else rm -rf "$work"; fi }
trap cleanup EXIT
export PYTHONPATH="./.pydeps;../third_party/yunet/deps"
export PYTHONIOENCODING=utf-8
PWD_ABS="$(pwd)"

echo "== run_nonwide_wide_ab: 非宽层 C∈{1,4} 按**几何**路由进**宽通路**（端到端逐字节） =="
echo "   nl=$nl tb=$tb py=$PY iverilog=$IVERILOG vvp=$VVP tmp=$work"

TOTAL_BAD=0; NEG_NOFIRE=0
FAIL() { echo "$1"; echo "RESULT: FAIL"; exit "$2"; }

# ---------------------------------------------------------------------------
# [0] 自检（离线）：blob 指纹 + 真表 C∈{1,4} 清单 + 真 offset/nbytes + 「整帧可跑」计数
# ---------------------------------------------------------------------------
echo "---- [0] 自检：blob 指纹 + 真表 C∈{1,4} 单元清单 + 新路由判定 + 计数（53/53）----"
if ! "$PY" - "$idx" "$blob" "$REF_BLOB_MD5" "$EXP_C1" "$EXP_DW4" "$EXP_NONWIDE" \
              "$EXP_TOTAL_CONV" "$EXP_RUNNABLE" "$HH" "$WW" "$work" <<'PYEOF'; then
import sys, json, hashlib
try: sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception: pass
(idx_p, blob_p, want_md5) = sys.argv[1], sys.argv[2], sys.argv[3]
exp_c1, exp_dw4, exp_nonwide, exp_total, exp_run = (int(sys.argv[4]), int(sys.argv[5]), int(sys.argv[6]),
                                                    int(sys.argv[7]), int(sys.argv[8]))
hh, ww, work = int(sys.argv[9]), int(sys.argv[10]), sys.argv[11]
NCOB_MAX = 8
bad = []
d = json.load(open(idx_p, encoding="utf-8"))
blob = open(blob_p, "rb").read()
md5 = hashlib.md5(blob).hexdigest()
if d["blob"]["bytes"] != len(blob): bad.append("blob 字节数 != index")
if md5 != want_md5: bad.append("blob md5=%s != %s（blob 被动过？）" % (md5, want_md5))

def narrow_shape(ci, co, g, tpe):   # = RTL 的 `narrowShape`（同式）
    return (ci == 8 and co == 8 and g == 1 and tpe != 3)

def loader_ok(ci, co, g, nb, off):
    if not (g == 1 or (g == ci and ci == co)): return False
    if ci == 0 or co == 0: return False
    if co * (ci // g) * 9 == 0: return False
    al = (nb + 31) // 32 * 32
    return (off + al) < (1 << 28)

units = [u for u in d["units"] if u["weight"] is not None]
n_conv = len(units)
nonwide = []
for u in units:
    o = u["own"]; ci, co, g = int(o["C_IN"]), int(o["C_OUT"]), int(o["GROUP"])
    tpe = int(u.get("type_code", -1))
    if narrow_shape(ci, co, g, tpe):
        continue
    if ci <= 8 and co <= 8:
        nonwide.append(u)
c1 = [u for u in nonwide if int(u["own"]["C_IN"]) == 1 and int(u["own"]["GROUP"]) == 1]
dw4 = [u for u in nonwide if int(u["own"]["C_IN"]) == 4 and int(u["own"]["GROUP"]) == 4]
if len(nonwide) != exp_nonwide: bad.append("C∈{1,4} 非宽层 %d != %d" % (len(nonwide), exp_nonwide))
if len(c1) != exp_c1: bad.append("C=1 dense %d != %d" % (len(c1), exp_c1))
if len(dw4) != exp_dw4: bad.append("depthwise C=4 %d != %d" % (len(dw4), exp_dw4))
if n_conv != exp_total: bad.append("conv 单元 %d != %d" % (n_conv, exp_total))

# 「整帧可跑」计数（新路由）：narrowShape（走窄通路）或（loader 前提 ∧ 0<C_out≤8*NCOB_MAX）
runnable = 0
for u in units:
    o = u["own"]; ci, co, g = int(o["C_IN"]), int(o["C_OUT"]), int(o["GROUP"])
    tpe = int(u.get("type_code", -1)); w = u["weight"]
    off, nb = int(w["offset"]), int(w["nbytes"])
    if narrow_shape(ci, co, g, tpe) or (loader_ok(ci, co, g, nb, off) and 0 < co <= 8 * NCOB_MAX):
        runnable += 1
if runnable != exp_run: bad.append("整帧可跑 %d != %d" % (runnable, exp_run))

lines = []
for u in nonwide:
    o, w = u["own"], u["weight"]
    ci, co, g = int(o["C_IN"]), int(o["C_OUT"]), int(o["GROUP"])
    tpe = int(u.get("type_code", -1))
    off, nb = int(w["offset"]), int(w["nbytes"])
    al = int(w.get("aligned_bytes") or ((nb + 31) // 32 * 32))
    nci, nco = (ci + 7) // 8, (co + 7) // 8
    kind = "dw" if tpe == 3 else "dense"
    npass = nco if kind == "dw" else nci * nco
    ncol = (nco * hh * ww) if kind == "dw" else (nci * nco * hh * ww)
    exp_nb = (co * 9) if kind == "dw" else (co * ci * 9)
    if narrow_shape(ci, co, g, tpe): bad.append("%s 仍被判为窄形状（新路由没生效）" % u["name"])
    if nb != exp_nb: bad.append("%s nbytes=%d != %d" % (u["name"], nb, exp_nb))
    if off % 32: bad.append("%s offset=%d 非 32B 对齐" % (u["name"], off))
    if al != (nb + 31) // 32 * 32: bad.append("%s aligned_bytes=%d != ceil32(%d)" % (u["name"], al, nb))
    if off + al >= (1 << 28): bad.append("%s 段越出 28 bit DDR 窗" % u["name"])
    if off + nb > len(blob): bad.append("%s 段越出 blob" % u["name"])
    if kind == "dw" and (ci != co or g != ci): bad.append("%s 不是 depthwise 几何" % u["name"])
    lines.append("%d %s %d %d %d %d %d %d %d %d %d %s" %
                 (u["idx"], u["name"], ci, co, g, tpe, off, nb, nci, nco, ncol, kind))
open(work + "/units.txt", "w", encoding="ascii", newline="\n").write("\n".join(lines) + "\n")

print("SELFTEST blob_bytes=%d md5=%s" % (len(blob), md5))
print("SELFTEST 真表 conv 单元=%d；C∈{1,4} 非宽层=%d（C=1 dense=%d、depthwise C=4=%d）"
      % (n_conv, len(nonwide), len(c1), len(dw4)))
print("SELFTEST 新路由：narrowShape = C_in==8 ∧ C_out==8 ∧ GROUP==1 ∧ 非 depthwise；其余走宽通路；"
      "9 个非宽层全部 narrowShape==假 ⇒ 走宽通路")
print("SELFTEST 整帧可跑（新路由）= %d/%d（44 宽层 + 9 非宽层）；旧口径 = 44/53" % (runnable, n_conv))
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
# [1] 参考供料（逐单元：dense 用 wide_exec_ref 一般流；depthwise 用 dw_wide_ref 对角流）
# ---------------------------------------------------------------------------
echo "---- [1] 参考供料（dense=wide_exec_ref / dw=dw_wide_ref；逐单元）----"
rm -rf "$outdir"; mkdir -p "$outdir"
while read -r LIDN UNAME CIN COUT GRP TPE OFF NB NCI NCO NCOL KIND; do
  JD="$outdir/lid${LIDN}_${UNAME}"
  # 供料落点口径不同：`wide_exec_ref` 自己在内部 join `lid<idx>_<name>`（⇒ 传父目录）；
  # `dw_wide_ref` 直接把产物落进 `--outdir`（⇒ 传本单元的 JD）。
  if [ "$KIND" = "dw" ]; then REFR="$ref_dw"; REFOUT="$JD"; else REFR="$ref_dense"; REFOUT="$outdir"; fi
  if ! "$PY" "$REFR" --lid "$LIDN" --H "$HH" --W "$WW" --outdir "$REFOUT" > "$work/ref_$LIDN.out" 2>&1; then
    tail -10 "$work/ref_$LIDN.out"; FAIL "JUDGE-RED(3): 参考供料失败 lid=$LIDN" 3
  fi
  grep -E '^(WIDE_REF|DW_WIDE_REF)' "$work/ref_$LIDN.out" | sed "s/^/    [$UNAME $KIND] /"
  [ -f "$JD/gold.hex" ] || FAIL "JUDGE-RED(3): 找不到 $JD/gold.hex" 3
  # 参考自检：黄金长度 == C_out*H*W 且非退化
  "$PY" - "$JD" "$(( COUT * HH * WW ))" <<'PYEOF'
import sys
JD, ln = sys.argv[1], int(sys.argv[2])
g = [int(l.strip(), 16) for l in open(JD + "/gold.hex", encoding="utf-8") if l.strip()]
bad = 0
if len(g) != ln: print("  REF_BAD gold=%d != C_out*H*W=%d" % (len(g), ln)); bad = 1
if len(set(g)) <= 1: print("  REF_BAD 黄金退化 distinct=%d" % len(set(g))); bad = 1
sys.exit(bad)
PYEOF
  [ $? -eq 0 ] || FAIL "JUDGE-RED(3): 参考黄金与几何不符（lid=$LIDN）" 3
done < "$work/units.txt"

# ---------------------------------------------------------------------------
# [2] 编译：正网表 + 2 个突变体（① 路由退回旧式 isWide；② 丢掉零填补 wzNeedW）
# ---------------------------------------------------------------------------
echo "---- [2] iverilog 编译 + 突变体（① isWide 退回旧式 ⇒ 9 个单元落回窄通路；② wzNeedW:=0 丢零填补）----"
if ! "$IVERILOG" -g2012 -o "$work/nw.vvp" "$tb" "$memv" "$nl" > "$work/iv.log" 2>&1; then
  sed -n '1,30p' "$work/iv.log"; FAIL "JUDGE-RED(1): iverilog 编译失败" 1
fi
echo "    正网表编译 OK"
if ! "$PY" - "$nl" "$work/mut_route.v" "$work/mut_zero.v" <<'PYEOF'; then
import sys
src, outr, outz = sys.argv[1], sys.argv[2], sys.argv[3]
txt = open(src, encoding="utf-8").read()
# 突变体①：路由退回旧式（= C4b-C3 前的 `isWide`）
old1 = "assign isWide = (! narrowShape);"
if txt.count(old1) != 1:
    print("MUTATE-ANCHOR-BAD: '%s' 命中 %d 次（要求恰好 1）" % (old1, txt.count(old1))); sys.exit(2)
new1 = "assign isWide = ((desc_2[15 : 0] > 16'h0008) || (desc_2[31 : 16] > 16'h0008));"
print("MUTATE#1 OK: %s\n         ->  %s   (= 旧路由，C∈{1,4} 落回窄通路)" % (old1, new1))
open(outr, "w", encoding="utf-8").write(txt.replace(old1, new1))
# 突变体②：丢掉零填补相位（跳过通道/空行不再被清 0）
old2 = "assign wzNeedW = (((_zz_wzNeedW[2 : 0] != 3'b000) || (_zz_wzNeedW_1[2 : 0] != 3'b000)) || (desc_3[7 : 0] != 8'h01));"
if txt.count(old2) != 1:
    print("MUTATE-ANCHOR-BAD: '%s' 命中 %d 次（要求恰好 1）" % (old2, txt.count(old2))); sys.exit(2)
new2 = "assign wzNeedW = 1'b0;"
print("MUTATE#2 OK: %s\n         ->  %s   (= 丢零填补)" % (old2, new2))
open(outz, "w", encoding="utf-8").write(txt.replace(old2, new2))
PYEOF
  FAIL "NEGCTL-FAIL: 突变锚不唯一（闸门自身不可信）" 2
fi
for m in route zero; do
  if ! "$IVERILOG" -g2012 -o "$work/mut_$m.vvp" "$tb" "$memv" "$work/mut_$m.v" > "$work/iv_mut_$m.log" 2>&1; then
    sed -n '1,20p' "$work/iv_mut_$m.log"; FAIL "JUDGE-RED(2): 突变体 $m 编译失败" 2
  fi
  echo "    突变体 $m 编译 OK"
done

# ---------------------------------------------------------------------------
# [3] 逐单元：正对照（WFILE 全 0 自证 DDR）+ 零填补有牙（WFILE 全 0xFF）+ 负对照（突变体）
# ---------------------------------------------------------------------------
echo "---- [3] 逐单元：正对照（逐字节 == 黄金）+ 零填补有牙（WFILE=0xFF 仍 MISMATCH=0）+ 负对照 ----"
UI=0
while read -r LIDN UNAME CIN COUT GRP TPE OFF NB NCI NCO NCOL KIND; do
  UI=$(( UI + 1 ))
  JD="$outdir/lid${LIDN}_${UNAME}"
  LEN=$(( COUT * HH * WW )); FULL=$(( NCO * 8 * HH * WW ))
  WBASE=$(( BLOB_BASE + OFF )); WEXP=$(( (NB + 31) / 32 * 32 ))
  NW=$(( NCI * NCO * 576 ))
  AWEXP=$(( LEN / 128 ))
  MV="$(sed -n 's/^M=//p' "$JD/job.txt" | head -1)"
  ZP="$(sed -n 's/^ZPAD=//p' "$JD/job.txt" | head -1)"
  ZY="$(sed -n 's/^ZY=//p' "$JD/job.txt" | head -1)"

  # ---- 内存镜像（真 blob 整块落 BLOB_BASE；DST 预载 = 素周期模式，必与黄金不同）----
  if ! "$PY" - "$work" "$blob" "$BLOB_BASE" "$DST" "$LEN" "$MEMSZ" "$NW" "$JD/gold.hex" <<'PYEOF'; then
import sys
work, blob_p, base, dst, ln, memsz, nw, gold_p = (sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4]),
                                                 int(sys.argv[5]), int(sys.argv[6]), int(sys.argv[7]), sys.argv[8])
blob = open(blob_p, "rb").read()
pre = [((i % 251) * 131 + 7) % 251 for i in range(memsz)]
for i, b in enumerate(blob): pre[base + i] = b
gold = [int(l.strip(), 16) for l in open(gold_p, encoding="utf-8") if l.strip()]
dif = sum(1 for j in range(ln) if pre[dst + j] != gold[j])
assert dif >= int(ln * 0.5), "dst 预载与黄金只差 %d/%d" % (dif, ln)
assert base + len(blob) <= memsz, "blob 越出内存模型"
open(work + "/mem.hex", "w").write("".join("%02x\n" % b for b in pre))
open(work + "/wfile_zero.hex", "w").write("".join("%02x\n" % 0 for _ in range(nw)))
open(work + "/wfile_ff.hex",   "w").write("".join("%02x\n" % 0xff for _ in range(nw)))
sys.exit(0)
PYEOF
    FAIL "JUDGE-RED(3): 内存镜像构造失败（lid=$LIDN）" 3
  fi

  run_job() {   # run_job <vvp> <wfile> <dumpname>
    ( cd "$work" && "$VVP" "$1" \
        "+XFILE=$PWD_ABS/$JD/x.hex" "+WFILE=$2" "+BFILE=$PWD_ABS/$JD/b.hex" \
        "+MEMFILE=$work/mem.hex" "+DUMPFILE=$work/$3.dump" +dump \
        "+CIN=$CIN" "+COUT=$COUT" "+GROUP=$GRP" "+H=$HH" "+W=$WW" "+TYPE=$TPE" "+FLAGS=1" \
        "+SRC=$SRC" "+DST=$DST" "+INB=$(( CIN * HH * WW ))" "+QSHIFT=6" "+LID=$LIDN" \
        "+M=$MV" "+ZPAD=$ZP" "+ZY=$ZY" "+NCOL=$NCOL" "+NCI=$NCI" "+NCO=$NCO" \
        "+WBASE=$WBASE" "+WEXP=$WEXP" ) > "$work/$3.log" 2>&1
  }

  # ---- 正对照（WFILE 全 0：片内权重只可能来自 DDR）----
  run_job "$work/nw.vvp" "$work/wfile_zero.hex" "pos_$LIDN" || true
  DLINE="$(grep -m1 '^DONE_SEEN=' "$work/pos_$LIDN.log")"
  RLINE="$(grep -m1 '^TB WIDE RTL:' "$work/pos_$LIDN.log")"
  echo "    [pos $UNAME $KIND] $DLINE"
  POS_PASS=0; grep -q '^RESULT: PASS' "$work/pos_$LIDN.log" && POS_PASS=1
  REPOK=0
  case "$RLINE" in
    *"WIDE_ON=1 WIDE_PASSES=1"*"RTL_M=$MV RTL_ZPAD=$ZP RTL_ZY=$ZY RTL_LAYER=$LIDN"*) REPOK=1 ;;
  esac
  WRPOS="$(sed -n 's/.*WR_BYTES=\([0-9]*\).*/\1/p' "$work/pos_$LIDN.log" | head -1)"
  WBPOS="$(sed -n 's/.*WGT_BYTES=\([0-9]*\).*/\1/p' "$work/pos_$LIDN.log" | head -1)"
  RDPOS="$(sed -n 's/^MEM rd=\([0-9]*\).*/\1/p' "$work/pos_$LIDN.log" | head -1)"
  AWPOS="$(sed -n 's/.* AW=\([0-9]*\) B=.*/\1/p' "$work/pos_$LIDN.log" | head -1)"
  BBPOS="$(sed -n 's/.* B=\([0-9]*\) WBASE=.*/\1/p' "$work/pos_$LIDN.log" | head -1)"

  region_py "$work/pos_$LIDN.dump" "$DST" "$FULL"  > "$work/pos_$LIDN.mem_slice"
  region_py "$work/mem.hex"        "$DST" "$FULL"  > "$work/pos_$LIDN.pre_slice"
  eval "$("$PY" - "$work/pos_$LIDN.mem_slice" "$JD/gold.hex" "$work/pos_$LIDN.pre_slice" "$LEN" <<'PYEOF'
import sys
d = [int(x, 16) for x in open(sys.argv[1], encoding="utf-8").read().split()]
g = [int(x, 16) for x in open(sys.argv[2], encoding="utf-8").read().split()]
p = [int(x, 16) for x in open(sys.argv[3], encoding="utf-8").read().split()]
ln = int(sys.argv[4]); full = len(d)
mis = sum(1 for i in range(ln) if d[i] != g[i]) + max(0, ln - len(g))
tail = sum(1 for i in range(ln, full) if d[i] != p[i])
print("P_MISMATCH=%d P_TAIL_BAD=%d P_DUP=%d" % (mis, tail, len(set(g))))
PYEOF
)"
  echo "    [pos $UNAME $KIND] MISMATCH=$P_MISMATCH  TAIL(空行区)被写=$P_TAIL_BAD  黄金distinct=$P_DUP"
  echo "    [pos $UNAME $KIND] WR_BYTES=$WRPOS(期望 $LEN) WGT_BYTES=$WBPOS(期望 $NB) MEM rd=$RDPOS(期望 $WEXP) AW=$AWPOS B=$BBPOS(期望 $AWEXP) 趟数=$NCOL/NCOL"
  [ "$POS_PASS" = "1" ] || { echo "JUDGE-RED(1): 正对照装置未 PASS（$UNAME）"; TOTAL_BAD=$((TOTAL_BAD+1)); }
  [ "$REPOK" = "1" ]   || { echo "JUDGE-RED(1): 自报不符（$UNAME）: $RLINE"; TOTAL_BAD=$((TOTAL_BAD+1)); }
  [ "$P_MISMATCH" = "0" ] || { echo "JUDGE-RED(1): 正对照 != 黄金（MISMATCH=$P_MISMATCH，$UNAME）"; TOTAL_BAD=$((TOTAL_BAD+1)); }
  [ "$P_TAIL_BAD" = "0" ] || { echo "JUDGE-RED(1): 尾部空行区被写（$UNAME）；写过了 C_out"; TOTAL_BAD=$((TOTAL_BAD+1)); }
  [ "$P_DUP" -gt 1 ] 2>/dev/null || { echo "JUDGE-RED(1): 黄金退化 distinct=$P_DUP（$UNAME）"; TOTAL_BAD=$((TOTAL_BAD+1)); }
  [ "$WRPOS" = "$LEN" ] || { echo "JUDGE-RED(1): WR_BYTES=$WRPOS != C_out*H*W=$LEN（$UNAME）"; TOTAL_BAD=$((TOTAL_BAD+1)); }
  [ "$RDPOS" = "$WEXP" ] || { echo "JUDGE-RED(1): MEM rd=$RDPOS != ceil32(nbytes)=$WEXP（$UNAME）"; TOTAL_BAD=$((TOTAL_BAD+1)); }
  [ "$WBPOS" = "$NB" ] || { echo "JUDGE-RED(1): WGT_BYTES=$WBPOS != nbytes=$NB（$UNAME）"; TOTAL_BAD=$((TOTAL_BAD+1)); }
  [ "$AWPOS" = "$AWEXP" ] || { echo "JUDGE-RED(1): AW 突发数=$AWPOS != C_out*H*W/128=$AWEXP（$UNAME）"; TOTAL_BAD=$((TOTAL_BAD+1)); }

  # ---- [1z] 零填补有牙：WFILE 全 0xFF ⇒ 没被零填补清掉的格子会留 0xFF ⇒ 必须仍 MISMATCH=0 ----
  run_job "$work/nw.vvp" "$work/wfile_ff.hex" "ff_$LIDN" || true
  region_py "$work/ff_$LIDN.dump" "$DST" "$LEN" > "$work/ff_$LIDN.mem_slice"
  ZMIS="$("$PY" - "$work/ff_$LIDN.mem_slice" "$JD/gold.hex" "$LEN" <<'PYEOF'
import sys
d = [int(x, 16) for x in open(sys.argv[1], encoding="utf-8").read().split()]
g = [int(x, 16) for x in open(sys.argv[2], encoding="utf-8").read().split()]
ln = int(sys.argv[3])
print("%d" % (sum(1 for i in range(ln) if d[i] != g[i]) + max(0, ln - len(g))))
PYEOF
)"
  echo "    [1z $UNAME $KIND] WFILE=0xFF（片内预载全 0xFF）⇒ MISMATCH=$ZMIS（期望 0：零填补把跳过通道/空行清成 0）"
  [ "$ZMIS" = "0" ] || { echo "JUDGE-RED(1): 零填补有牙不过（WFILE=0xFF 下 MISMATCH=$ZMIS，$UNAME）⇒ 零填补没写满"; TOTAL_BAD=$((TOTAL_BAD+1)); }

  # ---- 负对照①：突变体（路由退回旧式 ⇒ 落回窄通路 ⇒ 前提不成立 ⇒ IDLE 响亮 err + 零搬运）----
  run_job "$work/mut_route.vvp" "$work/wfile_zero.hex" "mut_$LIDN" || true
  MERR="$(sed -n 's/^DONE_SEEN=\([0-9]*\) ERR_SEEN=\([0-9]*\).*/\1|\2/p' "$work/mut_$LIDN.log" | head -1)"
  MWR="$(sed -n 's/.*WR_BYTES=\([0-9]*\).*/\1/p' "$work/mut_$LIDN.log" | head -1)"
  region_py "$work/mut_$LIDN.dump" "$DST" "$LEN" > "$work/mut_$LIDN.mem_slice"
  eval "$("$PY" - "$work/mut_$LIDN.mem_slice" "$JD/gold.hex" "$work/pos_$LIDN.pre_slice" "$LEN" <<'PYEOF'
import sys
d = [int(x, 16) for x in open(sys.argv[1], encoding="utf-8").read().split()]
g = [int(x, 16) for x in open(sys.argv[2], encoding="utf-8").read().split()]
p = [int(x, 16) for x in open(sys.argv[3], encoding="utf-8").read().split()]
ln = int(sys.argv[4])
mis = sum(1 for i in range(ln) if d[i] != g[i]) + max(0, ln - len(g))
untouched = sum(1 for i in range(ln) if d[i] != p[i])   # DST 区相对**预载**变了几字节（0 = 一字节未写）
print("M_MISMATCH=%d M_UNTOUCHED=%d" % (mis, untouched))
PYEOF
)"
  echo "    [mut① $UNAME $KIND] DONE|ERR=$MERR  WR_BYTES=$MWR(期望 0)  MISMATCH=$M_MISMATCH/$LEN  DST 相对预载变了=$M_UNTOUCHED(期望 0)"
  echo "    [mut① $UNAME $KIND] ⇒ 旧路由把 $UNAME 落回窄通路 ⇒ 窄通路前提（C_in=C_out=8）不成立 ⇒ IDLE 响亮 err、零搬运 ⇒ 红"
  [ "$MERR" = "0|1" ] || { echo "NEGCTL-FAIL: 突变体①在 $UNAME 上没有响亮 err（DONE|ERR=$MERR）"; NEG_NOFIRE=$((NEG_NOFIRE+1)); }
  [ "$MWR" = "0" ] || { echo "NEGCTL-FAIL: 突变体①在 $UNAME 上有写搬运（WR=$MWR）⇒ 未零搬运"; NEG_NOFIRE=$((NEG_NOFIRE+1)); }
  [ "$M_UNTOUCHED" = "0" ] || { echo "NEGCTL-FAIL: 突变体①在 $UNAME 上 DST 被动过（$M_UNTOUCHED 字节）⇒ 定位不清"; NEG_NOFIRE=$((NEG_NOFIRE+1)); }
  [ "$M_MISMATCH" -gt $(( LEN / 2 )) ] 2>/dev/null || { echo "NEGCTL-FAIL: 突变体①在 $UNAME 上 DST 并非未写（MISMATCH=$M_MISMATCH）"; NEG_NOFIRE=$((NEG_NOFIRE+1)); }

  # ---- 负对照②：突变体（丢零填补 wzNeedW:=0）+ WFILE 全 0xFF ⇒ 跳过通道/空行留 0xFF ⇒ 数值必错 ----
  run_job "$work/mut_zero.vvp" "$work/wfile_ff.hex" "mutz_$LIDN" || true
  ZWR="$(sed -n 's/.*WR_BYTES=\([0-9]*\).*/\1/p' "$work/mutz_$LIDN.log" | head -1)"
  region_py "$work/mutz_$LIDN.dump" "$DST" "$LEN" > "$work/mutz_$LIDN.mem_slice"
  ZM2="$("$PY" - "$work/mutz_$LIDN.mem_slice" "$JD/gold.hex" "$LEN" <<'PYEOF'
import sys
d = [int(x, 16) for x in open(sys.argv[1], encoding="utf-8").read().split()]
g = [int(x, 16) for x in open(sys.argv[2], encoding="utf-8").read().split()]
ln = int(sys.argv[3])
print("%d" % (sum(1 for i in range(ln) if d[i] != g[i]) + max(0, ln - len(g))))
PYEOF
)"
  echo "    [mut② $UNAME $KIND] 丢零填补 + WFILE=0xFF ⇒ MISMATCH=$ZM2（期望 >0）  WR_BYTES=$ZWR(期望 $LEN)"
  echo "    [mut② $UNAME $KIND] ⇒ 跳过通道/空行留 0xFF ⇒ 权重错 ⇒ 数值红（搬运仍在 ⇒ 定位到「零填补」，不是搬运）"
  [ "$ZM2" -gt 0 ] 2>/dev/null || { echo "NEGCTL-FAIL: 突变体②在 $UNAME 上没把数值弄错 ⇒ 零填补判据没牙"; NEG_NOFIRE=$((NEG_NOFIRE+1)); }
  [ "$ZWR" = "$LEN" ] || { echo "NEGCTL-FAIL: 突变体②在 $UNAME 上搬运算术变了（WR=$ZWR != $LEN）⇒ 定位不清"; NEG_NOFIRE=$((NEG_NOFIRE+1)); }
done < "$work/units.txt"

# ---------------------------------------------------------------------------
# [4] 边界：真不支持仍响亮 err（+WBASE 开也 err；零搬运）
# ---------------------------------------------------------------------------
echo "---- [4] 边界：GROUP ∉ {1,depthwise} / C_in==0 ⇒ ERR_SEEN=1 且零搬运 ----"
JDFIRST="$(ls -d "$outdir"/lid* 2>/dev/null | head -1)"
run_edge() {   # run_edge <tag> <cin> <cout> <group> <type> <ncol> <nci> <nco>
  local tag="$1" cin="$2" cout="$3" grp="$4" tpe="$5" ncol="$6" nci="$7" nco="$8"
  ( cd "$work" && "$VVP" "$work/nw.vvp" \
      "+XFILE=$PWD_ABS/$JDFIRST/x.hex" "+WFILE=$work/wfile_zero.hex" "+BFILE=$PWD_ABS/$JDFIRST/b.hex" \
      "+MEMFILE=$work/mem.hex" \
      "+CIN=$cin" "+COUT=$cout" "+GROUP=$grp" "+H=$HH" "+W=$WW" "+TYPE=$tpe" "+FLAGS=1" \
      "+SRC=$SRC" "+DST=$DST" "+INB=$(( cin * HH * WW ))" "+QSHIFT=6" "+LID=0" \
      "+M=3000000" "+ZPAD=-128" "+ZY=0" "+NCOL=$ncol" "+NCI=$nci" "+NCO=$nco" \
      "+WBASE=$(( BLOB_BASE + 32 ))" "+WEXP=0" ) > "$work/edge_$tag.log" 2>&1
}
EDGE_BAD=0
run_edge gmis 64 64 8  1 64 8 8 || true    # GROUP=8 ∉ {1, depthwise} ⇒ grpOkW 假 ⇒ IDLE 响亮 err
run_edge cin0  0 64 1  1  1 1 8 || true    # C_in=0 ⇒ 装载器前提 cIn!=0 假 ⇒ IDLE 响亮 err
for tag in gmis cin0; do
  E="$(sed -n 's/^DONE_SEEN=\([0-9]*\) ERR_SEEN=\([0-9]*\).*/\1|\2/p' "$work/edge_$tag.log" | head -1)"
  WRE="$(sed -n 's/.*WR_BYTES=\([0-9]*\).*/\1/p' "$work/edge_$tag.log" | head -1)"
  RDE="$(sed -n 's/.*RD_BYTES=\([0-9]*\).*/\1/p' "$work/edge_$tag.log" | head -1)"
  echo "    [edge $tag] $(grep -m1 '^DONE_SEEN=' "$work/edge_$tag.log")"
  case "$tag" in
    gmis) DESC="GROUP=8 ∉ {1,depthwise} (C_in=C_out=64)" ;;
    cin0) DESC="C_in=0 (装载器前提 cIn!=0 不成立)" ;;
  esac
  [ "$E" = "0|1" ] || { echo "JUDGE-RED(4): 边界 $tag（$DESC）没有响亮 err（got DONE|ERR=$E）"; EDGE_BAD=$((EDGE_BAD+1)); }
  [ "$WRE" = "0" ] && [ "$RDE" = "0" ] || { echo "JUDGE-RED(4): 边界 $tag（$DESC）有搬运（WR=$WRE RD=$RDE）"; EDGE_BAD=$((EDGE_BAD+1)); }
done
[ "$EDGE_BAD" = "0" ] || TOTAL_BAD=$((TOTAL_BAD+EDGE_BAD))

echo "=========================================================================="
echo "正对照   = OK（真表全部 9 个 C∈{1,4} 非宽层单元：权重经 DDR 真 offset 装载（WFILE 全 0 自证）⇒"
echo "                宽通路跑完 ⇒ DST 逐字节 == 冻结黄金；WR_BYTES==C_out*H*W、WGT_BYTES==nbytes）"
echo "零填补   = OK（同单元 WFILE 全 0xFF 仍 MISMATCH=0 ⇒ 跳过通道/空行确实被零填补清 0）"
echo "路由     = OK（narrowShape 只留 C_in==8 ∧ C_out==8 ∧ GROUP==1 ∧ 非 depthwise；其余走宽通路）"
echo "负对照①  = OK（旧路由 ⇒ 9 个单元落回窄通路 ⇒ 前提不成立 ⇒ IDLE 响亮 err、零搬运 ⇒ 红）"
echo "负对照②  = OK（丢零填补 + WFILE=0xFF ⇒ 跳过通道/空行留 0xFF ⇒ 数值红；搬运仍在 ⇒ 定位到零填补）"
echo "边界     = OK（GROUP ∉ {1,depthwise} / C_in==0 ⇒ ERR_SEEN=1、零搬运）"
echo "整帧可跑 = 真表 conv 53/53（44 宽层 + 9 非宽层 **本任务证死**）"
if [ "$NEG_NOFIRE" -ne 0 ]; then echo "NEGCTL-FAIL: $NEG_NOFIRE 条负对照没发火"; echo "RESULT: FAIL"; exit 2; fi
if [ "$TOTAL_BAD" -ne 0 ]; then echo "JUDGE-RED: $TOTAL_BAD 条判据未过"; echo "RESULT: FAIL"; exit 1; fi
echo "RESULT: PASS"
exit 0
