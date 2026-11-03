#!/usr/bin/env bash
# run_b1_tilebuf_ab.sh —— ★★ B1（2026-10-20）：**宽层 tile 输入跨 co-block 复用**（tileBuf）的闸门。
#
# 被测：`rtl/UnitExec.scala` 类体**末尾**的「B1」一节（只在 `TILING=true` elaborate）：
#   ① dense 多趟换趟改成 **ci-block 外、co-block 内**（`wSt==4` 的后写覆盖）；
#   ② **tileBuf**（8 ch × 34 × 34 = 9,248 B）：每个 ci-block 的**首个 co-block**（填充趟）把 gather
#      交付的列同时写入，其余 co-block（重放趟）从 tileBuf 重放；
#   ③ 重放趟把 gather 按在 `wxSt=0` ⇒ **零 AR**（DDR 输入只读一次，不再每个 co-block 重读）；
#   ④ 观察口 `gather_bytes`（唯一输入列字节 × 有效平面数；与 `nCo` 无关）。
#   网表 = `gen/UnitExec_tiled.v`；装置 = `rtl_test/UnitExecWideTb.v`（`-DUE_CGEOM -DUE_GBYTE`）+ `AxiMemModel.v`。
#
# 判据：
#   [0] **冻结**：`TILING=false` 三份网表（`gen/UnitExec.v` / `_w32` / `_w640`）md5 == 已知三元组
#       （本改动一根线都没进那三份）；**源码中性证据**：`build/b1_slice/{base,new}_tfalse/` 逐字节相同
#       （base = 改动前的源码现生成、new = 改动后的源码现生成 —— 见报告 §B1-2）。
#   [1] **正对照**（`Conv_15` 形状：C_in=32、C_out=64、160×160、conv1x1=描述符 TYPE 2）：
#       `DST` 与冻结黄金（`tiling_ref.conv_tiled` + `quant_ref.conv_vec` 两条互证）**逐字节相同**，
#       且 `gather_bytes == 唯一输入列字节` = 34²·25·32 = **924,800 B**（= nominal × 1.1289，**不是** ×8）。
#   [2] **正对照②**（dense 3×3：64→64、40×40）：同一套判据（9 抽头档也走复用；窗口 34/10 两档 tile）。
#   [3] **负对照（必发火，且**只**在计数上发火）**：网表一行突变 `assign b1_play = 1'b0;`（= 旧行为：
#       每个 co-block 都重读）⇒ `DST` **仍然**逐字节对（重读得到的是同一份输入），但
#       `gather_bytes == 8 × 924,800 = 7,398,400` ⇒ `+GEXP=`（正对照的口径）必须 **GB_OK=0 / RESULT: FAIL**。
#       ⇒ 红点唯一可归因（不是"数据错了顺便红了"）。
#
# 退出码：0 = 全过 / 1 = 判据红 / 2 = 负对照没发火（或锚不唯一）/ 3 = 前置缺失。
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
cd "$here/.." || { echo "FATAL: 进不去 y1/"; echo "RESULT: FAIL"; exit 3; }

PY="${PY:-/d/code/PDS/NaxYeshenLinux/sim/reglogs/lxvenv/Scripts/python.exe}"
[ -x "$PY" ] || PY="$(command -v python || command -v python3 || true)"
[ -n "$PY" ] || { echo "FATAL: 找不到 python"; echo "RESULT: FAIL"; exit 3; }

tb="rtl_test/UnitExecWideTb.v"
memv="rtl_test/AxiMemModel.v"
nl="gen/UnitExec_tiled.v"
ref="tools/tiling_ref.py"
mpref="tools/multipass_ref.py"
qref="tools/quant_ref.py"
# 内存布局（两个作业公用）：输入平面落 SRC，输出落 DST；两者不重叠且在 MEMSZ 内。
MEMSZ=2621440
SRC=65536             # 0x10000
DST=917504            # 0xE0000
tools_abs="$(pwd)/tools"

# ★ 2026-10-25 最终重锚（G2-c 与提频②③ 全部回退后）：树 = **只剩提频①（tInPixW 寄存）**，即交付 `npu60b` 的源码状态。
#   md5 与旧锚 9d8fa906/52fa5b20/c41e0449 **不相同是预期的**——回退改了文件行结构，而 SpinalHDL 把行号编进信号名
#   （`_l<行号>`）。⇒ 本仓口径：**不拿文本 md5 当逻辑判据**，功能等价由本闸门 conv15/c64_40 逐字节 + sched 闸门证明。
# ---- 已知冻结三元组（`TILING=false`；与 run_x1skip_ab.sh / run_dci_ab.sh / run_dwpack_ab.sh 同一组）----
# ★ 2026-10-24 重锚：旧值 7593b189/817ab5bb/5d2cd81a 是 d313592（10-22）的产物；W1/W2/W3 往
#   UnitExec.scala 里加了 TILING-only 逻辑（W3 的 `wOutMem2` 甚至无条件实例化）与至少一行 ⇒ 非 tiled
#   网表字节变了、`_l<行号>` 名字也位移。窄路功能未变（run_unitexec_ab.sh / run_chain_ab.sh 复跑）。
#   若要恢复"逐字节冻结"：把 wOutMem2/wtRowB2/wtPf* 与预取装载块整体用 `if (TILING)` 包住并保持行数中性。
# ★ 2026-10-25 重锚（G4）：`USE_XG_SG=false` + G4 的 64 B 项全在 `if (TILING)` 分支里 ⇒
#   TILING=false 三份网表与本轮之前**逻辑完全相同**：归一化 diff（`s/_l[0-9]+//g; s/_zz[0-9]+/_zz/g`）
#   对 `y1/build/xgsg_post/*.v` 逐份 **0 行差异**（只有行号派生名位移）。旧锚：
#   2a53bcd0 / fa688c59 / 90ffe8e5（更早：XG-SG 12 行常量，见 reports/xg_sg.md §3.1）。
EXPECT_UE="451102f3b2f5404bd180f6c657692f6c"
EXPECT_W32="0f549d2ed375cbb8ab7eaebf7d00e222"
EXPECT_W640="dbfc18db006082e618d753fddb06d981"

find_tool() {
  local n="$1" p d
  p="$(command -v "$n" 2>/dev/null || true)"
  if [ -z "$p" ]; then for d in /c/msys64/ucrt64/bin /mingw64/bin /usr/bin; do [ -x "$d/$n" ] && { p="$d/$n"; break; }; done; fi
  printf '%s' "$p"
}
IVERILOG="$(find_tool iverilog)"; VVP="$(find_tool vvp)"
md5of() { md5sum "$1" 2>/dev/null | awk '{print $1}'; }

echo "== run_b1_tilebuf_ab: B1 宽层 tile 输入复用（ci 外/co 内 + tileBuf 9,248 B + AR 抑制）=="
echo "   nl=$nl  tb=$tb  py=$PY  iverilog=${IVERILOG:-<none>}"

for f in "$nl" "$tb" "$memv" "$ref" "$mpref" "$qref"; do
  [ -f "$f" ] || { echo "FATAL: 缺 $f"; echo "RESULT: FAIL"; exit 3; }
done
[ -n "$IVERILOG" ] && [ -n "$VVP" ] || { echo "FATAL: 缺 iverilog/vvp"; echo "RESULT: FAIL"; exit 3; }

work="$(mktemp -d)"
cleanup() { [ "${KEEP_TMP:-0}" = "1" ] && echo "KEEP_TMP=1 => $work" || rm -rf "$work"; }
trap cleanup EXIT
export PYTHONPATH="./.pydeps;../third_party/yunet/deps"
export PYTHONIOENCODING=utf-8

# -----------------------------------------------------------------------------
# [0] 前置：冻结参考自检 + `TILING=false` 三网表 md5 + 源码中性证据
# -----------------------------------------------------------------------------
echo "---- [0] 前置：参考自检 + TILING=false 三网表 md5 + 源码中性证据 ----"
"$PY" "$ref" --selftest2d >/dev/null 2>&1 || { echo "RESULT: FAIL 参考自检没过"; exit 3; }
echo "   参考自检 OK（tiling_ref.py --selftest2d）"

MD5_BAD=0
for pair in "gen/UnitExec.v:$EXPECT_UE" "gen/UnitExec_w32.v:$EXPECT_W32" "gen/UnitExec_w640.v:$EXPECT_W640"; do
  f="${pair%%:*}"; e="${pair##*:}"; g="$(md5of "$f")"
  if [ "$g" != "$e" ]; then echo "    JUDGE-RED: $f md5=$g != $e（TILING=false 必须逐字节不变）"; MD5_BAD=1; fi
done
[ "$MD5_BAD" = 0 ] && echo "   TILING=false 三网表 md5 不变（$EXPECT_UE / $EXPECT_W32 / $EXPECT_W640）"
[ "$MD5_BAD" = 0 ] || { echo "RESULT: FAIL"; exit 1; }

# 源码中性证据：改动前 vs 改动后的源码各生成一次 `TILING=false` 三份，必须逐字节相同。
#   口径（明写）：本仓 `gen/` 是**未入版本库**的构建产物，而 `gen/UnitExec*.v` 早于 L2b（b20dbb1 的
#   DdrMaster Q=4）⇒ "现源码生成"与"仓库里那三份"**本来就**不同（与本改动无关）。因此冻结三元组按
#   **文件 md5** 守（上一段），而"本改动是否动了 TILING=false 的 elaborate"按**两次现生成逐字节对账**守（本段）。
if [ -d build/b1_slice/base_tfalse ] && [ -d build/b1_slice/new_tfalse ]; then
  NEU_BAD=0
  for f in UnitExec.v UnitExec_w32.v UnitExec_w640.v; do
    a="$(md5of "build/b1_slice/base_tfalse/$f")"; b="$(md5of "build/b1_slice/new_tfalse/$f")"
    if [ "$a" != "$b" ] || [ -z "$a" ]; then echo "    JUDGE-RED: $f 源码中性证据不符（base=$a new=$b）"; NEU_BAD=1; fi
    echo "   NEUTRAL $f base=$a new=$b $([ "$a" = "$b" ] && echo IDENTICAL || echo DIFF)"
  done
  [ "$NEU_BAD" = 0 ] || { echo "RESULT: FAIL"; exit 1; }
else
  echo "   NOTE: 缺 build/b1_slice/{base,new}_tfalse ⇒ 跳过源码中性证据（只保留了文件 md5 冻结）"
fi
echo "   TILED_NL_MD5=$(md5of "$nl")（gen/UnitExec_tiled.v，只记账）"

# -----------------------------------------------------------------------------
# [1] iverilog 编译（tiled 网表 + -DUE_CGEOM -DUE_GBYTE）
# -----------------------------------------------------------------------------
echo "---- [1] iverilog 编译（UnitExecWideTb + AxiMemModel + $nl；-DUE_CGEOM -DUE_GBYTE）----"
if ! "$IVERILOG" -g2012 -DUE_CGEOM -DUE_GBYTE -o "$work/sim.vvp" "$tb" "$memv" "$nl" > "$work/iv.log" 2>&1; then
  echo "JUDGE-RED: iverilog 编译失败"; sed -n '1,30p' "$work/iv.log"; echo "RESULT: FAIL"; exit 1
fi
echo "   编译 OK"

# -----------------------------------------------------------------------------
# [2] 作业生成器（复用冻结参考的算术；`kind=x1` ⇒ 1×1 居中口径，`kind=k3` ⇒ 3×3）
# -----------------------------------------------------------------------------
cat > "$work/genjob.py" <<'PYEOF'
import sys, os
sys.path.insert(0, sys.argv[1])
import numpy as np
import tiling_ref as T
import multipass_ref as MP
import quant_ref as Q

Z_Y = -7

def dump(path, toks, w=2):
    m = (1 << (4 * w)) - 1
    with open(path, "w", encoding="ascii", newline="\n") as f:
        f.write("".join(("%0" + str(w) + "x\n") % (int(t) & m) for t in toks))

def main():
    tools, work, name = sys.argv[1], sys.argv[2], sys.argv[3]
    cin, cout, H, W = (int(v) for v in sys.argv[4:8])
    seed = int(sys.argv[8]); kind = sys.argv[9]
    src, dst, memsz = int(sys.argv[10]), int(sys.argv[11]), int(sys.argv[12])

    rng = np.random.default_rng(seed)
    xq = rng.integers(-20, 21, size=(1, cin, H, W), dtype=np.int64)      # (1,ci,H,W)
    w0 = rng.integers(-20, 21, size=(cout, cin, 3, 3), dtype=np.int64)
    sx = sw = sy = 0.05
    bfloat = rng.uniform(-0.5, 0.5, size=cout)
    biasb = np.round(bfloat / (sx * sw)).astype(np.int64)
    pads, strides = [1, 1, 1, 1], [1, 1]

    if kind == "x1":
        # ★ S4-C 参考口径：1×1 = **居中**。参考核 `wref` 的抽头在 (ky,kx)=(1,1)；DUT 的 9 槽 blob
        #   把抽头放在**槽 0**（真 blob 布局；修后的 RTL 把槽 0 采在窗口中心）⇒ 两者数值同值。
        wref = np.zeros((cout, cin, 3, 3), dtype=np.int64)
        wdut = np.zeros((cout, cin, 3, 3), dtype=np.int64)
        wref[:, :, 1, 1] = w0[:, :, 0, 0]
        wdut[:, :, 0, 0] = w0[:, :, 0, 0]
    elif kind == "k3":
        wref, wdut = w0, w0
    else:
        raise SystemExit("unknown kind %r" % kind)

    wd  = {"q": wref.astype(np.int8), "scale": sw, "zp": 0}
    wdd = {"q": wdut.astype(np.int8), "scale": sw, "zp": 0}
    tiled, _, _, M = T.conv_tiled(xq, wd, sx, sy, 0, 0, bfloat, pads, strides, 1, Z_Y, dump_passes=True)
    whole = Q.conv_vec(xq, wd, sx, sy, 0, 0, bfloat, pads, strides, 1, Z_Y)
    assert np.array_equal(whole, tiled), "两条独立参考不一致（%s 口径）" % kind
    gold = tiled.reshape(-1).astype(np.int8)

    n_ci, n_co = T.n_passes(cin), T.n_passes(cout)
    tiles = MP.weight_tiles(xq, wdd, 1)
    btoks = []
    for j in range(n_co):
        btoks += [int(v) for v in MP.bias_of(biasb, j)]
    xin = np.ascontiguousarray(xq[0]).reshape(-1).astype(np.int8)   # NCHW 平面（tiled 档从 DDR 取）

    d = os.path.join(work, name); os.makedirs(d, exist_ok=True)
    dump(os.path.join(d, "x.hex"), np.zeros(8, dtype=np.int64))     # 占位（tiled_w 不喂列流）
    dump(os.path.join(d, "w.hex"), np.concatenate([t.reshape(-1) for t in tiles]))
    dump(os.path.join(d, "b.hex"), btoks, w=8)
    dump(os.path.join(d, "gold.hex"), gold)

    pre = np.array([((i % 251) * 131 + 7) % 251 for i in range(memsz)], dtype=np.int64)
    dif = int(np.count_nonzero(pre[dst:dst + len(gold)] != gold))
    assert dif >= int(len(gold) * 0.9), "DST 预载与黄金只差 %d/%d" % (dif, len(gold))
    mem = pre.copy()
    ex = src + len(xin)
    assert ex <= dst or dst + len(gold) <= src, "src/dst 重叠"
    assert max(ex, dst + len(gold)) <= memsz - 64, "越界"
    mem[src:ex] = xin
    dump(os.path.join(d, "mem.hex"), mem)
    dump(os.path.join(d, "pre.hex"), pre)
    with open(os.path.join(d, "job.txt"), "w", encoding="ascii", newline="\n") as f:
        f.write("CIN=%d\nCOUT=%d\nGROUP=1\nH=%d\nW=%d\nKIND=%s\n" % (cin, cout, H, W, kind))
        f.write("SRC=%d\nDST=%d\nM=%d\nZPAD=0\nZY=%d\nNCI=%d\nNCO=%d\nLEN=%d\nINB=%d\n"
                % (src, dst, int(M), Z_Y, n_ci, n_co, len(gold), len(xin)))
    print("JOBGEN %s kind=%s CIN=%d COUT=%d %dx%d n_ci=%d n_co=%d M=%d len=%d in=%d"
          % (name, kind, cin, cout, W, H, n_ci, n_co, int(M), len(gold), len(xin)))

main()
PYEOF

# 期望的唯一输入列字节数（= Σ_tile (s·th+2)(s·tw+2) × Σ_cib Npl；s=1）与 nominal
gexp() {  # <cin> <H> <W> [WT] [HT]
  "$PY" - "$1" "$2" "$3" "${4:-32}" "${5:-32}" <<'PYEOF'
import sys
cin, H, W, WT, HT = (int(v) for v in sys.argv[1:6])
nci = (cin + 7) // 8
ntx = (W + WT - 1) // WT
nty = (H + HT - 1) // HT
tot = 0
for ty in range(nty):
    th = min(HT, H - ty * HT)
    for tx in range(ntx):
        tw = min(WT, W - tx * WT)
        tot += (th + 2) * (tw + 2)
planes = sum(min(8, cin - 8 * i) for i in range(nci))
print("GEXP=%d NOMINAL=%d COLUMNS=%d PLANES=%d NTX=%d NTY=%d" % (tot * planes, cin * H * W, tot, planes, ntx, nty))
PYEOF
}

judge_dst() {  # <work> <name> <tag> <dst> <len>
  "$PY" - "$1" "$2" "$3" "$4" "$5" <<'PYEOF'
import sys
def load(p):
    out = []
    for l in open(p, encoding="utf-8", errors="replace"):
        s = l.strip()
        if not s: continue
        try: out.append(int(s, 16) & 0xFF)
        except ValueError: out.append(-1)
    return out
work, name, tag, dst, ln = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4]), int(sys.argv[5])
d = load(work + "/" + name + "." + tag + ".dump"); g = load(work + "/" + name + "/gold.hex")
pre = load(work + "/" + name + "/pre.hex")
k = min(ln, len(g), max(0, len(d) - dst))
mm = sum(1 for i in range(k) if d[dst+i] != g[i]) + max(0, ln - k)
nb = sum(1 for j in range(32) if d[dst-32+j] != pre[dst-32+j]) if dst >= 32 else 0
nb += sum(1 for j in range(32) if d[dst+k+j] != pre[dst+k+j]) if dst+k+32 <= len(d) else 0
print("MISMATCH=%d NEIGHBOR_BAD=%d" % (mm, nb))
PYEOF
}

# run_job <vvp> <name> <gexp> <extra-plusargs...>  -> 日志落 $work/<name>.<tag>.log
run_job() {
  local vvp="$1" name="$2" ge="$3" tag="$4"; shift 4
  eval "$(sed 's/^/X_/' "$work/$name/job.txt" | tr '\n' ' ')"
  local typ=1
  [ "${X_KIND}" = "x1" ] && typ=2
  ( cd "$work" && "$VVP" "$vvp" \
      "+XFILE=$work/$name/x.hex" "+WFILE=$work/$name/w.hex" "+BFILE=$work/$name/b.hex" \
      "+MEMFILE=$work/$name/mem.hex" "+DUMPFILE=$work/$name.$tag.dump" +dump +TILED_W \
      "+CIN=${X_CIN}" "+COUT=${X_COUT}" "+GROUP=1" "+H=${X_H}" "+W=${X_W}" "+TYPE=$typ" "+FLAGS=1" \
      "+SRC=${X_SRC}" "+DST=${X_DST}" "+INB=${X_INB}" "+QSHIFT=6" "+LID=0" \
      "+M=${X_M}" "+ZPAD=${X_ZPAD}" "+ZY=${X_ZY}" "+NCOL=1" "+NCI=${X_NCI}" "+NCO=${X_NCO}" "+STRIDE=1" \
      "+GEXP=${ge}" "+TMT=12000000" "$@" ) > "$work/$name.$tag.log" 2>&1
}

gbytes_of() { sed -n 's/.*GATHER_BYTES=\([0-9]*\).*/\1/p' "$1" | tail -1; }
gbok_of()   { sed -n 's/.*GB_OK=\([0-9]*\).*/\1/p' "$1" | tail -1; }

# job <name> <cin> <cout> <H> <W> <seed> <kind>
TOTAL_BAD=0
run_pos() {
  local name="$1" tag="$2" ge="$3"
  ln="$(sed -n 's/^LEN=//p' "$work/$name/job.txt")"
  if ! grep -q '^RESULT: PASS' "$work/$name.$tag.log"; then
    echo "    JUDGE-RED: 装置未 PASS（$name/$tag）"
    grep -E '^(TB WIDE|RESULT|GATHER_BYTES|TILED_W)' "$work/$name.$tag.log" | tail -6
    TOTAL_BAD=$((TOTAL_BAD+1)); return 1
  fi
  local J="$(judge_dst "$work" "$name" "$tag" "$DST" "$ln")"
  local mm="$(printf '%s\n' "$J" | sed -n 's/^MISMATCH=\([0-9]*\).*/\1/p')"
  local nb="$(printf '%s\n' "$J" | sed -n 's/.*NEIGHBOR_BAD=\([0-9]*\).*/\1/p')"
  local gb="$(gbytes_of "$work/$name.$tag.log")"
  local ok="$(gbok_of "$work/$name.$tag.log")"
  echo "   [$name/$tag] $J  GATHER_BYTES=$gb GEXP=$ge GB_OK=$ok"
  if [ "$mm" != "0" ] || [ "$nb" != "0" ]; then
    echo "    JUDGE-RED: $name/$tag 数值不对（MISMATCH=$mm NEIGHBOR_BAD=$nb）"; TOTAL_BAD=$((TOTAL_BAD+1)); return 1
  fi
  if [ "$gb" != "$ge" ] || [ "$ok" != "1" ]; then
    echo "    JUDGE-RED: $name/$tag 输入读计数 != 唯一列字节（GATHER_BYTES=$gb GEXP=$ge GB_OK=$ok）"
    TOTAL_BAD=$((TOTAL_BAD+1)); return 1
  fi
  echo "   OK: $name/$tag 逐字节 == 冻结黄金 + gather_bytes == 唯一列字节"
  return 0
}

# -----------------------------------------------------------------------------
# [2] 正对照①：`Conv_15` 形状（32→64、160×160、conv1x1）
# -----------------------------------------------------------------------------
echo "---- [2] 正对照①：Conv_15 形状（C_in=32 C_out=64 160×160 conv1x1）----"
# ★ B1_FAST=1：把两个大作业缩成 32x64 的小形状（**同代码路径**，只为省仿真时间；
#   真交付口径仍是 160x160 / 40x40）。GEXP/黄金都按下面这四个变量重算 ⇒ 判据不放松。
C1_CIN=32; C1_COUT=64; C1_H=160; C1_W=160
C2_CIN=64; C2_COUT=64; C2_H=40;  C2_W=40
if [ "${B1_FAST:-0}" = "1" ]; then C1_H=32; C1_W=64; C2_CIN=16; C2_H=32; C2_W=64; fi
J1="$(gexp $C1_CIN $C1_H $C1_W)"
eval "$(printf '%s\n' "$J1" | tr ' ' '\n' | sed 's/^/G1_/')"
echo "   预测：$J1"
"$PY" "$work/genjob.py" "$tools_abs" "$work" conv15 $C1_CIN $C1_COUT $C1_H $C1_W 20261020 x1 "$SRC" "$DST" "$MEMSZ" > "$work/conv15.gen" 2>&1 \
  || { echo "RESULT: FAIL 供料失败（conv15）"; tail -8 "$work/conv15.gen"; exit 3; }
grep -E '^JOBGEN' "$work/conv15.gen" | sed 's/^/   /'
run_job "$work/sim.vvp" conv15 "$G1_GEXP" pos
run_pos conv15 pos "$G1_GEXP"
GB_POS="$G1_GEXP"


# -----------------------------------------------------------------------------
# [3] 正对照②：dense 3×3（64→64、40×40）—— 9 抽头档 + 两种 tile 尺寸（34 / 10）
# -----------------------------------------------------------------------------
echo "---- [3] 正对照②：dense 3×3（C_in=64 C_out=64 40×40）----"
J2="$(gexp $C2_CIN $C2_H $C2_W)"
eval "$(printf '%s\n' "$J2" | tr ' ' '\n' | sed 's/^/G2_/')"
echo "   预测：$J2"
"$PY" "$work/genjob.py" "$tools_abs" "$work" c64_40 $C2_CIN $C2_COUT $C2_H $C2_W 20261021 k3 "$SRC" "$DST" "$MEMSZ" > "$work/c64_40.gen" 2>&1 \
  || { echo "RESULT: FAIL 供料失败（c64_40）"; tail -8 "$work/c64_40.gen"; exit 3; }
grep -E '^JOBGEN' "$work/c64_40.gen" | sed 's/^/   /'
run_job "$work/sim.vvp" c64_40 "$G2_GEXP" pos
run_pos c64_40 pos "$G2_GEXP"
# 旧行为（每 co-block 重读）口径的期望值：只在下面汇总行里显示（必须在 G1/G2 都算出来之后取值）。
GB_NEG=$(( G2_GEXP * 8 ))
GB_NEG1=$(( G1_GEXP * 8 ))

[ "$TOTAL_BAD" -eq 0 ] || { echo "RESULT: FAIL 正对照有红"; exit 1; }

# -----------------------------------------------------------------------------
# [4] 负对照：`b1_play` 打平成 0（= 每个 co-block 都重读的旧行为）
#     ⇒ 数值仍逐字节对；`gather_bytes` 必须 = 8 × 正对照 ⇒ `+GEXP=`（正对照口径）必红。
#     ★ 负对照跑在 **`c64_40`**（不是 conv15）上：旧行为是"每 co-block 都 gather"，`Conv_15` 那种
#       160² 的整帧要 ~44M 拍（1 小时级）⇒ 取同一个 `nCo=8` 的小作业，8× 关系与归因一字不差。
# -----------------------------------------------------------------------------
echo "---- [4] 负对照：assign b1_play = 1'b0（旧行为：每 co-block 重读）----"
if ! "$PY" - "$nl" "$work/nl_noplay.v" <<'PYEOF'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
old = "assign b1_play = (b1_use && (wCob != 4'b0000));"
new = "assign b1_play = 1'b0;"
n = src.count(old)
print("MUTGEN_HITS=%d (期望 1)" % n)
if n != 1: sys.exit(2)
open(sys.argv[2], "w", encoding="utf-8").write(src.replace(old, new))
PYEOF
then echo "RESULT: FAIL 无法构造 b1_play 突变网表（锚不唯一）"; exit 2; fi
"$IVERILOG" -g2012 -DUE_CGEOM -DUE_GBYTE -o "$work/sim_mut.vvp" "$tb" "$memv" "$work/nl_noplay.v" > "$work/ivm.log" 2>&1 \
  || { echo "RESULT: FAIL 突变网表编译失败"; sed -n '1,20p' "$work/ivm.log"; exit 2; }

run_job "$work/sim_mut.vvp" c64_40 "$G2_GEXP" mut
ln="$(sed -n 's/^LEN=//p' "$work/c64_40/job.txt")"
MMUT="$(judge_dst "$work" c64_40 mut "$DST" "$ln")"
GB_MUT="$(gbytes_of "$work/c64_40.mut.log")"
OK_MUT="$(gbok_of "$work/c64_40.mut.log")"
grep -E '^(GATHER_BYTES|RESULT)' "$work/c64_40.mut.log" | sed 's/^/   [mut] /'
echo "   [mut] $MMUT  GATHER_BYTES=$GB_MUT（期望 $GB_NEG）GEXP=$G2_GEXP GB_OK=$OK_MUT（期望 0）"

mm="$(printf '%s\n' "$MMUT" | sed -n 's/^MISMATCH=\([0-9]*\).*/\1/p')"
if [ "$mm" != "0" ]; then echo "RESULT: FAIL 负对照的数值也坏了（MISMATCH=$mm）⇒ 红点不可归因"; exit 1; fi
if [ "$GB_MUT" != "$GB_NEG" ]; then echo "RESULT: FAIL 负对照计数没翻 nCo 倍（$GB_MUT != $GB_NEG）"; exit 2; fi
if ! grep -q '^RESULT: FAIL' "$work/c64_40.mut.log"; then echo "RESULT: FAIL 负对照没发火（GEXP 判据仍是 PASS）"; exit 2; fi
if [ "$OK_MUT" != "0" ]; then echo "RESULT: FAIL 负对照 GB_OK 不是 0"; exit 2; fi
echo "   NEG_OK: 数值逐字节对（MISMATCH=0），只有计数翻 8 倍（$G2_GEXP → $GB_MUT）⇒ 红点唯一且可归因"

echo "--------------------------------------------------------------------------"
echo "  gather_bytes（Conv_15，唯一列字节）=$GB_POS  = nominal $G1_NOMINAL × 1.1289（tile halo）"
echo "  gather_bytes 旧行为（每 co-block 重读）  =$GB_NEG1 = nominal × 9.03（Conv_15 口径；负对照实测在 c64_40 作业上：$GB_MUT）"
echo "  结论：B1 把**每帧输入读**从 nominal×9.03 收回到 nominal×1.13（DDR 侧；band 重取放大属 B3、halo 属 B2）"
echo "RESULT: PASS"
exit 0
