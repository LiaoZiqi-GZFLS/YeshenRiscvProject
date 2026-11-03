#!/usr/bin/env bash
# run_wide_tail_ab.sh —— ★ C4b-C1「**宽层部分 co-block 尾块**（`C_out % 8 != 0`）端到端」闸门
#   （被测：`rtl/UnitExec.scala` 的 `WIDERUN`/WR/收料相位 —— 就是 `wideGeomOk`/`nCo`/`wCob` 那一段）
#
# 为什么（`reports/c4b_wgtdma.md` §11 的实测）：真表 53 个 conv 单元里 **15 个** `C_out ∈ {1,4,10}`
#   （`C_out % 8 != 0`）。B1c 让它们的**权重**能正确装进 `wRam` 了，但宽通路的 **WR/收料相位按整
#   co-block 出料**（`nCo*8` 行）⇒ 它们**响亮 err**（不算错、但整帧跑不了）。
#   本任务给宽通路加**部分尾块**：末 co-block 只写有效的 `C_out - 8*floor(C_out/8)` 行，
#   **绝不写/读 `C_out` 之后**；同时把 `wideGeomOk` 的 `C_out % 8 == 0` 放开到"可寻址"边界
#   （`0 < C_out ≤ 8*NCOB_MAX`），**真不支持**的几何仍**响亮 err**。
#
# 设计（唯一真源 = RTL 的 `val wideCoRows = dw.cOut`）：
#   WR 相位的**总字节** = `C_out*H*W`（不是 `nCo*8*H*W`）。出料的字节序是 `[co-block][cl][pixel]`
#   （见 `UnitExec.scala` 的"缺陷修-2"），在 `co = cob*8+cl` 上**单调**，且 `H*W % 8 == 0` ⇒ 总字节数
#   是整「拍」(8 B) 的整数倍 ⇒ 按字节数截断**恰好**落在 `co == C_out` 的行边界上。
#   `C_out % 8 == 0` 时 `wideCoRows == nCo*8` ⇒ 既有的 `run_unitexec_wide_ab.sh` 逐字节不变。
#
# 判据（每条都要能发火）：
#   [0] 自检（离线；不成立 exit 3）：blob 指纹 + 取真表里**所有 dense 尾块单元**
#       （`isWide ∧ GROUP==1 ∧ 0<C_out≤64 ∧ C_out%8!=0` ⇒ 恰好 12 个，含 `C_out ∈ {1,4,10}` 三档），
#       逐个核真 `offset/nbytes`（32 B 对齐、`N_i == nbytes`、段尾在 28 bit 窗内）；并给出真表口径的
#       **"整帧可跑"计数**：旧（`C_out%8==0`）**29/53** → 新（`0<C_out≤8*NCOB_MAX`）**44/53**。
#   [1] 正对照（**逐字节**，每个真单元）：权重**从 DDR 真 offset 装载**（`+WBASE=BLOB_BASE+offset`，
#       `+WFILE=` 灌**全 0** ⇒ 片内权重只可能来自 DDR）⇒ DUT 跑完 ⇒
#       · `RESULT: PASS`（`DONE_SEEN=1 ERR_SEEN=0`、`wr_bytes == C_out*H*W`、`AW/B` 突发数对、`RD_PEAK==WEXP`）；
#       · `DST` 区 `[DST, DST+C_out*H*W)` **逐字节 == 黄金**（`MISMATCH=0`）；黄金非退化（`distinct>1`）。
#   [2] 装载/存储字节两条纪律：
#       · **装载**：`MEM rd == ceil32(nbytes) == nbytes`（真单元段长是 32 的整数倍）且 `WGT_BYTES == nbytes`；
#       · **存储**：**写的区域恰好 = `C_out` 行** —— `[DST+C_out*H*W, DST+nCo*8*H*W)`（**整 co-block
#         的尾部空行区**）一个字节都没被写（== 预载模式），`WR_BYTES == C_out*H*W`。
#   [3] 负对照（**必须发火且定位**）：**网表突变**把 `wideCoRows` 换成旧的 `nCo*8`（= "强制尾块写满
#       8 行"，改动前的行为）⇒ `WR_BYTES == nCo*8*H*W != C_out*H*W`、尾部空行区**被写**（报出首个越界
#       字节的偏移）；而前 `C_out*H*W` 字节**仍然正确**（定位：毛病就在"多写的那几行"，不是算术）。
#   [4] 边界（**真不支持的几何仍响亮 err**，绝不静默算错）：`C_out > 8*NCOB_MAX`（`--synth 10 72`，
#       `nCo=9>8`）、`C_out == 0`、`IMG_W > WIDTH`（= 运行期 `rowW > W_MAX`，**T-S1 §3.1 的合法边界**）
#       ⇒ 均 `ERR_SEEN=1` 且 `WR_BYTES=0`、`RD_BYTES=0`。
#       ★★ T-S1 前提更新（2026-10-14）：**`IMG_W < WIDTH` 不再是 err** —— 运行期行宽 `rowW = IMG_W·s`
#          只要 `≤ W_MAX` 即合法（正是"一张网表重放 6 个行宽"要的东西，见 `run_roww_ab.sh`）。
#          故本边界从旧的 `IMG_W != WIDTH`（`W=32<64` 也该 err）**重锚**为 `IMG_W > WIDTH`（`W=128>64` 才 err）。
#
# 退出码（与 Y1 既有闸门一致）：0 = 全绿；1 = 判据红；2 = 负对照没发火 / 突变锚不唯一；3 = 向量或自检失败。
#
# 装置契约（rtl_test/UnitExecWideTb.v + rtl_test/AxiMemModel.v + gen/UnitExec.v）：
#   +CIN +COUT +GROUP +H +W +TYPE +FLAGS +SRC +DST +INB +QSHIFT +LID +M +ZPAD +ZY +NCOL +NCI +NCO
#   +XFILE +WFILE +BFILE +MEMFILE +DUMPFILE +dump +WBASE= +WEXP= +DUMPW=
#   装置打印：TB WIDE RTL: ... WIDE_PASSES=.. / DONE_SEEN=.. ERR_SEEN=.. NFED=.. RD_PEAK=.. RD_BYTES=..
#             WGT_BYTES=.. WR_BYTES=.. AR=.. AW=.. B=.. WBASE=.. / RESULT: PASS|FAIL
#   内存模型打印：MEM rd=<b> wr=<b> bursts=<n> maxburst=<n>
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
cd "$here/.." || { echo "FATAL: 进不去 y1/"; echo "RESULT: FAIL"; exit 3; }

PY="${PY:-/d/code/PDS/NaxYeshenLinux/sim/reglogs/lxvenv/Scripts/python.exe}"
[ -x "$PY" ] || PY="$(command -v python || command -v python3 || true)"
[ -n "$PY" ] || { echo "FATAL: 找不到 python"; echo "RESULT: FAIL"; exit 3; }

ref="tools/wide_exec_ref.py"
tb="rtl_test/UnitExecWideTb.v"
memv="rtl_test/AxiMemModel.v"
nl="gen/UnitExec.v"
idx="gen/wgt_index.json"
blob="gen/wgt_blob.bin"
outdir="gen/c4b_tail"

# ---- 常量（与 TB 的 AxiMemModel MEMSZ / 装置上限一致）----
MEMSZ=2621440                 # 2.5 MiB
BLOB_BASE=262144              # 0x40000：真 blob **整块**落 DDR 的起点（WBASE = BLOB_BASE + 真 offset）
SRC=131072                    # 0x20000（宽层不从 DDR 读激活；只为描述符字段合法）
DST=2097152                   # 0x200000：输出区
HH=4; WW=64                   # 与网表 WIDTH=64 / IMG_H_MAX=4 对账（H*W = 256 = PIXW）
MAXW=$(( 8 * 8 * 576 ))       # wRam 字节数（36864）
REF_BLOB_MD5="aa135f0f7d50780b7b13d9a1ba9c518a"
EXP_OLD_RUNNABLE=29
EXP_NEW_RUNNABLE=44
EXP_DENSE_TAIL=12
EXP_TAIL_TOTAL=15

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
export PYTHONIOENCODING=utf-8
export PYTHONPATH="./.pydeps;../third_party/yunet/deps"

echo "== run_wide_tail_ab: 宽层**部分 co-block 尾块**（C_out%8!=0）端到端 =="
echo "   nl=$nl  tb=$tb  py=$PY  iverilog=$IVERILOG  vvp=$VVP  tmp=$work"
echo "   用例：真表全部 **dense 尾块单元**（isWide ∧ GROUP==1 ∧ 0<C_out≤64 ∧ C_out%8!=0）、各自真 offset"

TOTAL_BAD=0; NEG_NOFIRE=0
FAIL() { echo "$1"; echo "RESULT: FAIL"; exit "$2"; }

# ---------------------------------------------------------------------------
# [0] 自检（离线）：blob 指纹 + 真表尾块单元清单 + 真 offset/nbytes + 「整帧可跑」计数
# ---------------------------------------------------------------------------
echo "---- [0] 自检：blob 指纹 + 真表尾块单元清单 + 「整帧可跑」计数（旧 29 → 新 44）----"
if ! "$PY" - "$idx" "$blob" "$REF_BLOB_MD5" "$EXP_OLD_RUNNABLE" "$EXP_NEW_RUNNABLE" \
              "$EXP_DENSE_TAIL" "$EXP_TAIL_TOTAL" "$HH" "$WW" "$work" <<'PYEOF'; then
import sys, json, hashlib
(idx_p, blob_p, want_md5, exp_old, exp_new, exp_dense, exp_tail, hh, ww, work) = (
    sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4]), int(sys.argv[5]), int(sys.argv[6]),
    int(sys.argv[7]), int(sys.argv[8]), int(sys.argv[9]), sys.argv[10])
NCOB_MAX = 8
bad = []
d = json.load(open(idx_p, encoding="utf-8"))
blob = open(blob_p, "rb").read()
md5 = hashlib.md5(blob).hexdigest()
if d["blob"]["bytes"] != len(blob): bad.append("blob 字节数 != index")
if md5 != want_md5: bad.append("blob md5=%s != %s（blob 被动过？）" % (md5, want_md5))

def loader_ok(u):
    o = u["own"]; ci, co, g = int(o["C_IN"]), int(o["C_OUT"]), int(o["GROUP"])
    if not (g == 1 or ci == co): return False
    if ci == 0 or co == 0: return False
    if co * (ci // g) * 9 == 0: return False
    off, nb = int(u["weight"]["offset"]), int(u["weight"]["nbytes"])
    al = u["weight"].get("aligned_bytes") or ((nb + 31) // 32 * 32)
    return (off + al) < (1 << 28)

units = [u for u in d["units"] if u["weight"] is not None]
n_conv = len(units)
tail = [u for u in units if (int(u["own"]["C_IN"]) > 8 or int(u["own"]["C_OUT"]) > 8)
        and int(u["own"]["C_OUT"]) % 8 != 0]
dense = [u for u in tail if int(u["own"]["GROUP"]) == 1 and 0 < int(u["own"]["C_OUT"]) <= 8 * NCOB_MAX]
depth = [u for u in tail if u not in dense]

n_old = n_new = n_wide = 0
for u in units:
    o = u["own"]; ci, co = int(o["C_IN"]), int(o["C_OUT"])
    if not (ci > 8 or co > 8): continue
    n_wide += 1
    if not loader_ok(u): continue
    if co % 8 == 0: n_old += 1
    if 0 < co <= 8 * NCOB_MAX: n_new += 1

if len(tail) != exp_tail: bad.append("尾块单元 %d != %d" % (len(tail), exp_tail))
if len(dense) != exp_dense: bad.append("dense 尾块 %d != %d" % (len(dense), exp_dense))
if n_old != exp_old: bad.append("旧「整帧可跑」%d != %d" % (n_old, exp_old))
if n_new != exp_new: bad.append("新「整帧可跑」%d != %d" % (n_new, exp_new))
if not ({1, 4, 10} <= {int(u["own"]["C_OUT"]) for u in dense}):
    bad.append("dense 尾块没覆盖 {1,4,10} 三档")

lines = []
for u in dense:
    o = u["own"]; w = u["weight"]
    ci, co = int(o["C_IN"]), int(o["C_OUT"])
    off, nb = int(w["offset"]), int(w["nbytes"])
    al = int(w.get("aligned_bytes") or ((nb + 31) // 32 * 32))
    nci, nco = (ci + 7) // 8, (co + 7) // 8
    if off % 32: bad.append("%s offset=%d 非 32B 对齐" % (u["name"], off))
    if nb != co * ci * 9: bad.append("%s nbytes=%d != C_out*C_in*9=%d" % (u["name"], nb, co * ci * 9))
    if nb % 32: bad.append("%s nbytes=%d 非 32 的整数倍（RD 粒度）" % (u["name"], nb))
    if al != nb: bad.append("%s aligned_bytes=%d != nbytes=%d" % (u["name"], al, nb))
    if off + nb > len(blob): bad.append("%s 段越出 blob" % u["name"])
    if int(o["IMG_W"]) != ww:
        pass  # 真表的 IMG_W 是原生张量宽（本网表钉 64）⇒ 这里**不**当判据（与 §11.4 同口径）
    lines.append("%d %s %d %d %d %d %d %d %d %d" %
                 (u["idx"], u["name"], ci, co, off, nb, nci, nco, nci * nco, nco * nci * hh * ww))
open(work + "/units.txt", "w", encoding="ascii", newline="\n").write("\n".join(lines) + "\n")

print("SELFTEST blob_bytes=%d md5=%s" % (len(blob), md5))
print("SELFTEST conv_units=%d wide=%d 尾块(C_out%%8!=0)=%d 其中 dense=%d depthwise=%d"
      % (n_conv, n_wide, len(tail), len(dense), len(depth)))
print("SELFTEST 整帧可跑（装载器前提 ∧ 计算侧）: 旧(C_out%%8==0)=%d/%d  新(0<C_out≤%d)=%d/%d  ⇒ 新增 %d"
      % (n_old, n_conv, 8 * NCOB_MAX, n_new, n_conv, n_new - n_old))
print("SELFTEST depthwise 尾块（仍**不**端到端：对角趟调度是计算侧另一件事）= %s"
      % ", ".join(u["name"] for u in depth))
for ln in lines:
    print("UNIT " + ln)
for b in bad: print("SELFTEST_BAD: " + b)
sys.exit(3 if bad else 0)
PYEOF
  FAIL "JUDGE-RED(3): 自检不过（blob/真表/计数与冻结口径不符）" 3
fi

# ---------------------------------------------------------------------------
# 工具：内存区间切片（dump / 预载镜像都是"一字节一行"⇒ 按行长直接 seek）
# ---------------------------------------------------------------------------
region_py() {   # region_py <file> <start> <n>  -> 一字节一行的十六进制到 stdout
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
# [1] 参考供料（每个真单元：wide_exec_ref --lid <idx>；参考**不重写**任何量化算术）
# ---------------------------------------------------------------------------
echo "---- [1] 参考供料：wide_exec_ref --lid <idx> --H $HH --W $WW（逐单元）----"
while read -r LIDN UNAME CIN COUT OFF NB NCI NCO NPASS NCOL; do
  if ! "$PY" "$ref" --lid "$LIDN" --H "$HH" --W "$WW" --outdir "$outdir" > "$work/ref_$LIDN.out" 2>&1; then
    tail -10 "$work/ref_$LIDN.out"; FAIL "JUDGE-RED(3): 参考供料失败 lid=$LIDN" 3
  fi
  grep -E '^WIDE_REF' "$work/ref_$LIDN.out" | sed "s/^/    [$UNAME] /"
  JD="$outdir/lid${LIDN}_${UNAME}"
  [ -f "$JD/gold.hex" ] || FAIL "JUDGE-RED(3): 找不到 $JD/gold.hex" 3
  LEN=$(( COUT * HH * WW )); FULL=$(( NCO * 8 * HH * WW ))
  # ---- 参考自检：拆趟 == 整层 + 黄金非退化（在**本单元**上再钉一次）----
  "$PY" - "$JD" "$LEN" <<'PYEOF'
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
# [2] 编译：正网表 + 1 个突变体（wideCoRows := nCo*8 = 改动前的"整 co-block"口径）
# ---------------------------------------------------------------------------
echo "---- [2] iverilog 编译 + 突变体（wideCoRows := nCo*8 ⇒ 尾块写满 8 行）----"
if ! "$IVERILOG" -g2012 -o "$work/tail.vvp" "$tb" "$memv" "$nl" > "$work/iv.log" 2>&1; then
  sed -n '1,30p' "$work/iv.log"; FAIL "JUDGE-RED(1): iverilog 编译失败" 1
fi
echo "    正网表编译 OK"
if ! "$PY" - "$nl" "$work/mut_full.v" <<'PYEOF'; then
import sys
src, out = sys.argv[1], sys.argv[2]
txt = open(src, encoding="utf-8").read()
old = "assign wideCoRows = desc_2[31 : 16];"
n = txt.count(old)
if n != 1:
    print("MUTATE-ANCHOR-BAD: '%s' 命中 %d 次（要求恰好 1）" % (old, n)); sys.exit(2)
new = "assign wideCoRows = (nCo << 3);"
print("MUTATE OK: %s  ->  %s   (= 改动前'整 co-block'口径)" % (old, new))
open(out, "w", encoding="utf-8").write(txt.replace(old, new))
PYEOF
  FAIL "NEGCTL-FAIL: 突变锚不唯一（闸门自身不可信）" 2
fi
if ! "$IVERILOG" -g2012 -o "$work/mut.vvp" "$tb" "$memv" "$work/mut_full.v" > "$work/iv_mut.log" 2>&1; then
  sed -n '1,20p' "$work/iv_mut.log"; FAIL "JUDGE-RED(2): 突变体编译失败" 2
fi
echo "    突变体编译 OK"

# ---------------------------------------------------------------------------
# [3] 逐单元：正对照（DDR 真 offset 装载 + 全零 WFILE）+ 负对照（突变体）
# ---------------------------------------------------------------------------
echo "---- [3] 逐单元：正对照（逐字节 == 黄金；尾部空行区未写）+ 负对照（突变体必发火）----"
PWD_ABS="$(pwd)"
UI=0
while read -r LIDN UNAME CIN COUT OFF NB NCI NCO NPASS NCOL; do
  UI=$(( UI + 1 ))
  JD="$outdir/lid${LIDN}_${UNAME}"
  LEN=$(( COUT * HH * WW )); FULL=$(( NCO * 8 * HH * WW ))
  WBASE=$(( BLOB_BASE + OFF ))
  WEXP=$(( (NB + 31) / 32 * 32 ))
  NW=$(( NCI * NCO * 576 ))
  MV="$(sed -n 's/^M=//p' "$JD/job.txt" | head -1)"
  ZP="$(sed -n 's/^ZPAD=//p' "$JD/job.txt" | head -1)"
  ZY="$(sed -n 's/^ZY=//p' "$JD/job.txt" | head -1)"

  # ---- 内存镜像：真 blob 整块落 BLOB_BASE；DST 预载 = 素周期模式（与黄金必不同）；WFILE 全 0 ----
  if ! "$PY" - "$work" "$blob" "$BLOB_BASE" "$DST" "$LEN" "$MEMSZ" "$NW" "$JD/gold.hex" <<'PYEOF'; then
import sys
work, blob_p, base, dst, ln, memsz, nw, gold_p = (sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4]),
                                                 int(sys.argv[5]), int(sys.argv[6]), int(sys.argv[7]), sys.argv[8])
blob = open(blob_p, "rb").read()
pre = [((i % 251) * 131 + 7) % 251 for i in range(memsz)]
for i, b in enumerate(blob): pre[base + i] = b
gold = [int(l.strip(), 16) for l in open(gold_p, encoding="utf-8") if l.strip()]
dif = sum(1 for j in range(ln) if pre[dst + j] != gold[j])
assert dif >= int(ln * 0.9), "dst 预载与黄金只差 %d/%d" % (dif, ln)
assert base + len(blob) <= memsz, "blob 越出内存模型"
open(work + "/mem.hex", "w").write("".join("%02x\n" % b for b in pre))
open(work + "/wfile_zero.hex", "w").write("".join("%02x\n" % 0 for _ in range(nw)))
sys.exit(0)
PYEOF
    FAIL "JUDGE-RED(3): 内存镜像构造失败（lid=$LIDN）" 3
  fi

  run_job() {   # run_job <vvp> <dump>
    ( cd "$work" && "$VVP" "$1" \
        "+XFILE=$PWD_ABS/$JD/x.hex" "+WFILE=$work/wfile_zero.hex" "+BFILE=$PWD_ABS/$JD/b.hex" \
        "+MEMFILE=$work/mem.hex" "+DUMPFILE=$work/$2.dump" +dump \
        "+CIN=$CIN" "+COUT=$COUT" "+GROUP=1" "+H=$HH" "+W=$WW" "+TYPE=1" "+FLAGS=1" \
        "+SRC=$SRC" "+DST=$DST" "+INB=$(( CIN * HH * WW ))" "+QSHIFT=6" "+LID=$LIDN" \
        "+M=$MV" "+ZPAD=$ZP" "+ZY=$ZY" "+NCOL=$NCOL" "+NCI=$NCI" "+NCO=$NCO" \
        "+WBASE=$WBASE" "+WEXP=$WEXP" ) > "$work/$2.log" 2>&1
  }

  # ---- 正对照 ----
  run_job "$work/tail.vvp" "pos_$LIDN" || true
  DLINE="$(grep -m1 '^DONE_SEEN=' "$work/pos_$LIDN.log")"
  RLINE="$(grep -m1 '^TB WIDE RTL:' "$work/pos_$LIDN.log")"
  MEMLINE="$(grep -m1 '^MEM rd=' "$work/pos_$LIDN.log")"
  echo "    [pos $UNAME] $DLINE"
  echo "    [pos $UNAME] $MEMLINE"
  POS_PASS=0; grep -q '^RESULT: PASS' "$work/pos_$LIDN.log" && POS_PASS=1
  # 自报对账：WIDE_ON=1、WIDE_PASSES == n_ci*n_co、RTL_M/ZPAD/ZY/LAYER == 灌进去的值
  REPOK=0
  case "$RLINE" in
    *"WIDE_ON=1 WIDE_PASSES=$NPASS"*"RTL_M=$MV RTL_ZPAD=$ZP RTL_ZY=$ZY RTL_LAYER=$LIDN"*) REPOK=1 ;;
  esac
  WRPOS="$(sed -n 's/.*WR_BYTES=\([0-9]*\).*/\1/p' "$work/pos_$LIDN.log" | head -1)"
  WBPOS="$(sed -n 's/.*WGT_BYTES=\([0-9]*\).*/\1/p' "$work/pos_$LIDN.log" | head -1)"
  RDPOS="$(sed -n 's/^MEM rd=\([0-9]*\).*/\1/p' "$work/pos_$LIDN.log" | head -1)"
  AWPOS="$(sed -n 's/.* AW=\([0-9]*\) B=.*/\1/p' "$work/pos_$LIDN.log" | head -1)"
  BBPOS="$(sed -n 's/.* B=\([0-9]*\) WBASE=.*/\1/p' "$work/pos_$LIDN.log" | head -1)"

  # 数值判据：DST 区逐字节 == 黄金；**尾部空行区**未被写（== 预载）
  region_py "$work/pos_$LIDN.dump" "$DST" "$FULL"  > "$work/pos_$LIDN.mem_slice"
  region_py "$work/mem.hex"         "$DST" "$FULL"  > "$work/pos_$LIDN.pre_slice"
  JPOS="$("$PY" - "$work/pos_$LIDN.mem_slice" "$JD/gold.hex" "$work/pos_$LIDN.pre_slice" "$LEN" <<'PYEOF'
import sys
d = [int(x, 16) for x in open(sys.argv[1], encoding="utf-8").read().split()]
g = [int(x, 16) for x in open(sys.argv[2], encoding="utf-8").read().split()]
p = [int(x, 16) for x in open(sys.argv[3], encoding="utf-8").read().split()]
ln = int(sys.argv[4]); full = len(d)
mis = sum(1 for i in range(ln) if d[i] != g[i]) + max(0, ln - len(g))
tail = sum(1 for i in range(ln, full) if d[i] != p[i])
first = next((i for i in range(ln, full) if d[i] != p[i]), -1)
print("P_MISMATCH=%d P_TAIL_BAD=%d P_TAIL_FIRST=%d P_DUP=%d" % (mis, tail, first, len(set(g))))
PYEOF
)" || FAIL "JUDGE-RED(3): 正对照对账失败 lid=$LIDN" 3
  eval "$JPOS"
  echo "    [pos $UNAME] MISMATCH=$P_MISMATCH  TAIL(空行区)被写=$P_TAIL_BAD (首字节 @$P_TAIL_FIRST)  黄金distinct=$P_DUP"
  echo "    [pos $UNAME] WR_BYTES=$WRPOS(期望 $LEN) WGT_BYTES=$WBPOS(期望 $NB) MEM rd=$RDPOS(期望 $WEXP) AW=$AWPOS B=$BBPOS(期望 $(( LEN / 128 )))"

  [ "$POS_PASS" = "1" ] || { echo "JUDGE-RED(1): 正对照装置未 PASS（$UNAME）"; TOTAL_BAD=$((TOTAL_BAD+1)); }
  [ "$REPOK" = "1" ]   || { echo "JUDGE-RED(1): 自报不符（$UNAME）: $RLINE"; TOTAL_BAD=$((TOTAL_BAD+1)); }
  [ "$P_MISMATCH" = "0" ] || { echo "JUDGE-RED(1): 正对照 != 黄金（MISMATCH=$P_MISMATCH，$UNAME）"; TOTAL_BAD=$((TOTAL_BAD+1)); }
  [ "$P_TAIL_BAD" = "0" ] || { echo "JUDGE-RED(1): 尾部空行区被写（$P_TAIL_BAD B，$UNAME）⇒ 写过了 C_out"; TOTAL_BAD=$((TOTAL_BAD+1)); }
  [ "$P_DUP" -gt 1 ] 2>/dev/null || { echo "JUDGE-RED(1): 黄金退化 distinct=$P_DUP（$UNAME）"; TOTAL_BAD=$((TOTAL_BAD+1)); }
  [ "$WRPOS" = "$LEN" ] || { echo "JUDGE-RED(1): WR_BYTES=$WRPOS != C_out*H*W=$LEN（$UNAME）"; TOTAL_BAD=$((TOTAL_BAD+1)); }
  [ "$RDPOS" = "$WEXP" ] || { echo "JUDGE-RED(1): MEM rd=$RDPOS != ceil32(nbytes)=$WEXP（$UNAME）"; TOTAL_BAD=$((TOTAL_BAD+1)); }
  [ "$WBPOS" = "$NB" ] || { echo "JUDGE-RED(1): WGT_BYTES=$WBPOS != nbytes=$NB（$UNAME）"; TOTAL_BAD=$((TOTAL_BAD+1)); }
  [ "$AWPOS" = "$(( LEN / 128 ))" ] || { echo "JUDGE-RED(1): AW 突发数不对（$UNAME）"; TOTAL_BAD=$((TOTAL_BAD+1)); }

  # ---- 负对照：突变体（wideCoRows := nCo*8，= 改动前"整 co-block"口径）----
  run_job "$work/mut.vvp" "mut_$LIDN" || true
  region_py "$work/mut_$LIDN.dump" "$DST" "$FULL" > "$work/mut_$LIDN.mem_slice"
  JMUT="$("$PY" - "$work/mut_$LIDN.mem_slice" "$JD/gold.hex" "$work/pos_$LIDN.pre_slice" "$LEN" <<'PYEOF'
import sys
d = [int(x, 16) for x in open(sys.argv[1], encoding="utf-8").read().split()]
g = [int(x, 16) for x in open(sys.argv[2], encoding="utf-8").read().split()]
p = [int(x, 16) for x in open(sys.argv[3], encoding="utf-8").read().split()]
ln = int(sys.argv[4]); full = len(d)
mis = sum(1 for i in range(ln) if d[i] != g[i]) + max(0, ln - len(g))
tail = sum(1 for i in range(ln, full) if d[i] != p[i])
first = next((i for i in range(ln, full) if d[i] != p[i]), -1)
print("M_MISMATCH=%d M_TAIL_BAD=%d M_TAIL_FIRST=%d" % (mis, tail, first))
PYEOF
)" || FAIL "JUDGE-RED(3): 负对照对账失败 lid=$LIDN" 3
  eval "$JMUT"
  MWR="$(sed -n 's/.*WR_BYTES=\([0-9]*\).*/\1/p' "$work/mut_$LIDN.log" | head -1)"
  MERR="$(sed -n 's/^DONE_SEEN=\([0-9]*\) ERR_SEEN=\([0-9]*\).*/\1|\2/p' "$work/mut_$LIDN.log" | head -1)"
  MDONE="$(sed -n 's/.*WR_BYTES=\([0-9]*\).*/WR_BYTES=\1/p' "$work/mut_$LIDN.log" | head -1)"
  echo "    [mut $UNAME] WR_BYTES=$MWR(期望 ≠ $LEN)  尾部空行区被写=$M_TAIL_BAD (首字节 @$M_TAIL_FIRST)  前 $LEN 字节 MISMATCH=$M_MISMATCH  DONE|ERR=$MERR"
  echo "    [mut $UNAME] ⇒ 正判据在此网表下必红：WR_BYTES($MWR) != C_out*H*W($LEN) ∧ 尾部空行区被写($M_TAIL_BAD B)；毛病就在"多写的那几行"（前 $LEN 字节仍逐字节对）"
  # 负对照必须发火：(a) 写过了 C_out（尾部空行区被写）；(b) 字数变了；且 (c) 前 C_out*H*W 仍正确（定位）
  [ "$M_TAIL_BAD" -gt 0 ] 2>/dev/null || { echo "NEGCTL-FAIL: 突变体没把尾部空行区写脏（$UNAME）⇒ 判据没牙"; NEG_NOFIRE=$((NEG_NOFIRE+1)); }
  [ "$MWR" != "$LEN" ] || { echo "NEGCTL-FAIL: 突变体 WR_BYTES 仍 == C_out*H*W（$UNAME）"; NEG_NOFIRE=$((NEG_NOFIRE+1)); }
  [ "$M_MISMATCH" = "0" ] || { echo "NEGCTL-FAIL: 突变体把前 C_out*H*W 也弄错了（$UNAME）⇒ 定位不清"; NEG_NOFIRE=$((NEG_NOFIRE+1)); }
  [ -n "$M_TAIL_FIRST" ] && [ "$M_TAIL_FIRST" != "-1" ] || { echo "NEGCTL-FAIL: 突变体没报出首个越界字节（$UNAME）"; NEG_NOFIRE=$((NEG_NOFIRE+1)); }
done < "$work/units.txt"

# ---------------------------------------------------------------------------
# [4] 边界：真不支持的几何仍**响亮 err**（+WBASE=0 ⇒ 不走装载器；`isWide` 仍成立）
# ---------------------------------------------------------------------------
echo "---- [4] 边界：真不支持的几何 ⇒ ERR_SEEN=1 且 零搬运（WR_BYTES=0 / RD_BYTES=0）----"
# ---- 边界 b1/b2 的向量：--synth 10 72（C_out=72 ⇒ nCo=9 > 8）----
if ! "$PY" "$ref" --synth 10 72 --H "$HH" --W "$WW" --outdir "$outdir" > "$work/ref_b72.out" 2>&1; then
  tail -6 "$work/ref_b72.out"; FAIL "JUDGE-RED(3): 边界向量 --synth 10 72 供料失败" 3
fi
grep -E '^WIDE_REF' "$work/ref_b72.out" | sed 's/^/    /'
JD72="$outdir/synth_10_72"
JD10="$(ls -d "$outdir"/lid*_Conv_72 2>/dev/null | head -1)"   # 借 Conv_72 的 XFILE（只是喂列，err 用例不消费）

run_edge() {   # run_edge <tag> <cin> <cout> <w> <ncol> <xfile> <expect-wr>
  local tag="$1" cin="$2" cout="$3" w="$4" ncol="$5" xf="$6"
  ( cd "$work" && "$VVP" "$work/tail.vvp" \
      "+XFILE=$PWD_ABS/$xf" "+WFILE=$work/wfile_zero.hex" "+BFILE=$PWD_ABS/$JD72/b.hex" \
      "+MEMFILE=$work/mem.hex" \
      "+CIN=$cin" "+COUT=$cout" "+GROUP=1" "+H=$HH" "+W=$w" "+TYPE=1" "+FLAGS=1" \
      "+SRC=$SRC" "+DST=$DST" "+INB=$(( cin * HH * w ))" "+QSHIFT=6" "+LID=0" \
      "+M=3000000" "+ZPAD=-128" "+ZY=0" "+NCOL=$ncol" "+NCI=$(( (cin+7)/8 ))" "+NCO=$(( (cout+7)/8 ))" \
      "+WBASE=0" "+WEXP=0" ) > "$work/edge_$tag.log" 2>&1
}
EDGE_BAD=0
run_edge b72 10 72 "$WW" "$(( 9 * 2 * HH * WW ))" "$JD72/x.hex" || true
run_edge b0  64 0  "$WW" 1 "$JD10/x.hex" || true
run_edge bw  64 10 128 "$(( 2 * 8 * HH * 128 ))" "$JD10/x.hex" || true
for tag in b72 b0 bw; do
  L="$(grep -m1 '^DONE_SEEN=' "$work/edge_$tag.log")"
  E="$(sed -n 's/^DONE_SEEN=\([0-9]*\) ERR_SEEN=\([0-9]*\).*/\1|\2/p' "$work/edge_$tag.log" | head -1)"
  WRE="$(sed -n 's/.*WR_BYTES=\([0-9]*\).*/\1/p' "$work/edge_$tag.log" | head -1)"
  RDE="$(sed -n 's/.*RD_BYTES=\([0-9]*\).*/\1/p' "$work/edge_$tag.log" | head -1)"
  echo "    [edge $tag] $L"
  case "$tag" in
    b72) DESC="C_out=72 > 8*NCOB_MAX=64 (nCo=9)" ;;
    b0)  DESC="C_out=0" ;;
    bw)  DESC="IMG_W=128 > WIDTH=64 (= rowW > W_MAX)" ;;
  esac
  [ "$E" = "0|1" ] || { echo "JUDGE-RED(4): 边界 $tag（$DESC）没有响亮 err（got DONE|ERR=$E）"; EDGE_BAD=$((EDGE_BAD+1)); }
  [ "$WRE" = "0" ] && [ "$RDE" = "0" ] || { echo "JUDGE-RED(4): 边界 $tag（$DESC）有搬运（WR=$WRE RD=$RDE）"; EDGE_BAD=$((EDGE_BAD+1)); }
done
[ "$EDGE_BAD" = "0" ] || TOTAL_BAD=$((TOTAL_BAD+EDGE_BAD))

# ---------------------------------------------------------------------------
# 收口
# ---------------------------------------------------------------------------
echo "=========================================================================="
echo "正对照   = OK（真表全部 dense 尾块单元：权重经 DDR 真 offset 装载（WFILE 全 0 自证）⇒ DST 区逐字节 == 黄金；"
echo "                 WR_BYTES == C_out*H*W；AW/B == C_out*H*W/128；RD_PEAK == ceil32(nbytes)）"
echo "装载/存储= OK（MEM rd == nbytes、WGT_BYTES == nbytes；[DST+C_out*H*W, DST+nCo*8*H*W) 空行区一字节未写）"
echo "负对照   = OK（网表突变 wideCoRows := nCo*8 ⇒ 多写 nCo*8-C_out 行：尾部空行区被写 + WR_BYTES 变；前 C_out*H*W 仍正确）"
echo "边界     = OK（C_out>8*NCOB_MAX / C_out==0 / IMG_W>WIDTH(=rowW>W_MAX) ⇒ ERR_SEEN=1、零搬运；★T-S1：IMG_W<WIDTH 合法）"
echo "整帧可跑 = 旧(C_out%8==0) 29/53 ⇒ 新 44/53（新增 15 = 12 dense 尾块【本闸门端到端证死】+ 3 depthwise 尾块【对角趟属计算侧另一件事】）"
if [ "$NEG_NOFIRE" -ne 0 ]; then echo "NEGCTL-FAIL: $NEG_NOFIRE 条负对照没发火"; echo "RESULT: FAIL"; exit 2; fi
if [ "$TOTAL_BAD" -ne 0 ]; then echo "JUDGE-RED: $TOTAL_BAD 条判据未过"; echo "RESULT: FAIL"; exit 1; fi
echo "RESULT: PASS"
exit 0
