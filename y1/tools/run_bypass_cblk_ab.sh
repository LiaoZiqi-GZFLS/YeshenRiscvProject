#!/usr/bin/env bash
# run_bypass_cblk_ab.sh —— ★★ T-S3a.2a：`BypassExec` 的**通道分块**（`cIn/8` 趟）闸门。
#
# 被测：`rtl/BypassExec.scala`（网表 `gen/BypassExec.v`，`BypassExecGen` 缺省档 `C=8 WIDTH=80 IMG_H_MAX=40`）。
#   装置：`rtl_test/BypassTb.v` 的 **`+TILED_B` 档**（`-DBP_TILED_B`：DUT = `BypassExec` + `AxiMemModel`，
#   装置**不喂列流** —— 激活由 DUT 自己从 DDR 取）+ `rtl_test/AxiMemModel.v`（预载/落盘）。
#
# 为什么需要它：`geomOk` 改动前要求 `dw.cIn === C ∧ dw.cOut === C`（`C = 8`），而真表旁路层是
#   `C_IN = C_OUT ∈ {16, 64, 1}`（`gen/desc.bin` 解码：`MaxPool_5`=16；`MaxPool_18/25/32`、
#   `Resize_43/49`=64）⇒ **每个真旁路层在"通道"这一维就 `err`**。T-S3a.2a 的口径 = **通道分块**
#   （`cIn/C` 趟，逐趟跑一遍既有的整层相位；源/目标平面偏移 `+8·HW` / `+8·outPix`，见
#   `rtl/BypassExec.scala` 文件头 §T-S3a.2a）。本闸门用**小的整层形状**（`outPix ≤ MAXPIX`、
#   `rowW ≤ WIDTH`）把"通道维"独立出来证死 —— 空间 tiling（大形状）是 T-S3a.2b 的事。
#
# ============================== 判据 ==============================
#  0) **前置**：冻结参考自检（`tools/bypass_ref.py --selftest`；该参考**冻结、永不编辑**）；
#     网表存在；iverilog/vvp 在 PATH。
#  1) **前提档（cIn = 8，单块）**：与多块作业**同一个形状、同一条平面通路** ⇒ 必须 `RESULT: PASS`
#     且 DST 逐字节 == 黄金。★ 它证明"本装置 + 本形状 + 平面布局"这条判据线本身是通的
#     （不是"多块作业红是因为形状/装置不对"），同时是 `cIn == C` 的**回归锚**。
#  2) **正对照（cIn ∈ {16, 64}，maxpool/resize）**：DUT 走 `cIn/8` 趟 ⇒ `DST` 区逐字节 == **整层黄金**
#     （`MISMATCH=0`）、`SRC` 区逐字节未被改动（输入没被写坏）、`DST` 紧邻的 64 B 邻居未被改动。
#     黄金 = **冻结参考复用**（`bypass_ref.py` 的 `nontrivial` + `maxpool_ref`/`resize2x_ref`，
#     再经该参考自己的 `to_tensor` 折成**通道平面（NCHW）**布局）—— **不写第三条参考**。
#     形状合法性（都由 `geomOk` 的出线条件反推，逐条写在这里并被 `genjob.py` 断言）：
#       · `rowW = 2·IMG_W`（maxpool）/ `IMG_W/2`（resize）`≤ WIDTH(80)`；
#       · `outPix = IMG_W·IMG_H ≤ MAXPIX = 3200`（整层路径，**不触发** T-S3a.2b 的空间 tile）；
#       · `inCols % 32 == 0` ∧ `outPix % 32 == 0`（平面通路的对齐前提）。
#  2c) **正对照（★★ T-S3a.2c：`cIn=1` 的逐点布局折）**：`sigmoid` `C_IN=C_OUT=1`、`H=1`、
#      `W ∈ {6400,1600,400}`（真表 `Sigmoid_85/93/101/109/117/125`；`desc[61..66]`）⇒ DUT 走
#      **线性折**（8 个连续元素 = 一拍 ⇒ `C_eff=8`；有效像素 `800/200/50`）⇒ `DST` 逐字节 ==
#      **冻结参考** `bypass_ref.sigmoid_ref(bypass_ref.sigmoid_sweep(...))`（码点扫描向量，覆盖全 256 码点）。
#      `W=400` 的有效像素 50 **不是 4 的倍数** ⇒ 传输长度上取整到 416 B（`DdrMaster` 的 `len%32==0`），
#      多出的 16 B 由 RTL 的 `wstrb` 掩掉 ⇒ `DST` 只写前 400 B、**邻居 64 B 未动**（硬判据）。
#  2d) **负对照②（★★ T-S3a.2c）**：网表突变把折的**分母减半**（`>>>3` -> `>>>4`）⇒ 折档三作业
#      `DST_MISMATCH > 0`；同一突变在**非折档**（`cIn=8` 前提档）上逐字节不变（**外科式**自检）。
#  3) **负对照（必须发火）**：外科式网表突变（scratch 拷贝，绝不动 `gen/`）把**块数**钉成 1
#     （`nBlkR <= nBlk` -> `nBlkR <= 16'h0001`）⇒ 只跑块 0 ⇒
#       · 多块作业必须 `DST_MISMATCH > 0`，且**首个坏字节落在块 1 的平面里**
#         （相对 `DST` 的偏移 ≥ `8·outPix`）—— 这条把"漏块"与"整段乱写"区分开；
#       · 前提档（cIn = 8，本来就只有 1 块）在**同一突变体**下必须仍 `MISMATCH=0`
#         ⇒ 这一刀是**外科式**的（它只影响多块）。
#  4) **结构判据**：`tools/check_dangling.py gen/BypassExec.v` ⇒ 零悬空实例。
#
# 退出码：0 = 全过 / 1 = **正对照红**（含 iverilog 编译失败：与 `run_tiling2d_wide_ab.sh` 同口径）/
#   2 = 负对照没发火（或"判据线自检"不过）⇒ 闸门自身不可信 / 3 = 前置缺失。
#
# 备注：`NL=` 可用环境变量换网表（本闸门用它做过**先红**证据：把 `git show HEAD:y1/gen/BypassExec.v`
#   存成一个文件当 `NL=` ⇒ cIn=8 档绿、16/64 档红）。
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
cd "$here/.." || { echo "FATAL: 进不去 y1/"; echo "RESULT: FAIL"; exit 3; }

PY="${PY:-}"
if [ -z "$PY" ]; then
  for c in /d/code/PDS/NaxYeshenLinux/sim/reglogs/lxvenv/Scripts/python.exe python3 python; do
    if command -v "$c" >/dev/null 2>&1; then PY="$c"; break; fi
  done
fi
[ -n "$PY" ] || { echo "FATAL: 找不到 python"; echo "RESULT: FAIL"; exit 3; }

tb="rtl_test/BypassTb.v"
memv="rtl_test/AxiMemModel.v"
ref="tools/bypass_ref.py"
dangling="tools/check_dangling.py"
nl="${NL:-gen/BypassExec.v}"
MEMSZ=2621440                 # 2.5 MB（与 run_bypass_tile_ab.sh / UnitExecWideTb 同口径）
SRC=131072                    # 0x020000（32 B 对齐）
DST=1048576                   # 0x100000（32 B 对齐；与 SRC 不重叠）
tools_abs="$(pwd)/tools"

find_tool() {
  local n="$1" p d
  p="$(command -v "$n" 2>/dev/null || true)"
  if [ -z "$p" ]; then for d in /c/msys64/ucrt64/bin /mingw64/bin /usr/bin; do [ -x "$d/$n" ] && { p="$d/$n"; break; }; done; fi
  printf '%s' "$p"
}
IVERILOG="$(find_tool iverilog)"; VVP="$(find_tool vvp)"

echo "== run_bypass_cblk_ab: BypassExec 通道分块（cIn/8 趟；C_in = 8/16/64）逐字节闸门 —— T-S3a.2a =="
echo "   nl=$nl  tb=$tb  ref=$ref  py=$PY  iverilog=${IVERILOG:-<none>}"

for f in "$nl" "$tb" "$memv" "$ref" "$dangling"; do
  [ -f "$f" ] || { echo "FATAL: 缺 $f"; echo "RESULT: FAIL"; exit 3; }
done
[ -n "$IVERILOG" ] && [ -n "$VVP" ] || { echo "FATAL: 缺 iverilog/vvp"; echo "RESULT: FAIL"; exit 3; }

work="$(mktemp -d)"
cleanup() { [ "${KEEP_TMP:-0}" = "1" ] && echo "KEEP_TMP=1 => $work" || rm -rf "$work"; }
trap cleanup EXIT
export PYTHONPATH="./.pydeps;../third_party/yunet/deps"
export PYTHONIOENCODING=utf-8

echo "---- 0) 冻结参考自检 bypass_ref.py --selftest（前置；不过 exit 3）----"
"$PY" "$ref" --selftest > "$work/ref.log" 2>&1 || { echo "RESULT: FAIL 冻结参考自检没过"; tail -5 "$work/ref.log"; exit 3; }
tail -1 "$work/ref.log" | sed 's/^/   /'

# ---------------------------------------------------------------- 编译 ----
echo "---- 1) iverilog 编译（BypassTb + AxiMemModel + $nl，-DBP_TILED_B）----"
if ! "$IVERILOG" -g2012 -DBP_TILED_B -o "$work/sim.vvp" "$tb" "$memv" "$nl" > "$work/iv.log" 2>&1; then
  echo "JUDGE-COMPILE-FAIL: iverilog 编译失败"; sed -n '1,30p' "$work/iv.log"; echo "RESULT: FAIL"; exit 1
fi
echo "   编译 OK"

# ---------------------------------------------------------------- 作业生成器 ----
cat > "$work/genjob.py" <<'PYEOF'
"""作业生成：**只做布局/落盘**；黄金一律复用**冻结参考**（`bypass_ref.py`），不写第三条。
   argv: tools_abs work name op cin out_w out_h src dst memsz"""
import os, sys
sys.path.insert(0, sys.argv[1])
import numpy as np
import bypass_ref as B

def dump(path, toks, w=2):
    a = (np.asarray(toks, dtype=np.int64) & ((1 << (4 * w)) - 1))
    with open(path, "w", encoding="ascii", newline="\n") as f:
        f.write("".join(("%0" + str(w) + "x\n") % int(v) for v in a))

def main():
    tools, work, name, op = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
    cin, out_w, out_h = (int(x) for x in sys.argv[5:8])
    src, dst, memsz = (int(x) for x in sys.argv[8:11])
    if op == "maxpool":
        in_w, in_h = 2 * out_w, 2 * out_h                 # 2x2/s2：输入几何 = 输出的 2 倍
    elif op == "resize":
        in_w, in_h = out_w // 2, out_h // 2               # x2 最近邻：输入几何 = 输出的一半
        assert out_w % 2 == 0 and out_h % 2 == 0, "resize 的输出几何必须偶数（输入 = 输出/2）"
    elif op == "sigmoid":
        in_w, in_h = out_w, out_h                         # ★ T-S3a.2c：逐点，输入几何 == 输出几何
    else:
        raise SystemExit("FATAL: 本闸门只做 maxpool / resize / sigmoid(C_in=1 布局折)")
    d = os.path.join(work, name); os.makedirs(d, exist_ok=True)

    rowW = 2 * out_w if op == "maxpool" else (out_w // 2 if op == "resize" else out_w)
    out_pix, in_cols = out_w * out_h, in_w * in_h
    WIDTH, MAXPIX = 80, 3200                              # BypassExecGen 缺省档的展开期几何
    assert src % 32 == 0 and dst % 32 == 0, "SRC/DST 必须 32 B 对齐（AxiMemModel 的合规检查）"

    if op == "sigmoid":
        # ---- ★★ T-S3a.2c：`C_in=C_out=1` 的**逐点布局折**（8 个连续元素 = 一拍 ⇒ C_eff=8）----
        #   形状前提（逐条由 RTL 的 `foldPt` / `geomOk` 反推）：`cIn=cOut=1`、`H=1`、`W%8==0`。
        #   有效像素 = `W/8`，**上取整到 4 的倍数**（一拍 8 B ⇒ 4 像素 = 32 B）⇒ 读/写长度是 32 的倍数
        #   （`DdrMaster` 的 P3 硬前提：`len%32==0`）。真表 `Sigmoid_400`（`IMG_W=400,IMG_H=1`）正是
        #   那个"W 不是 32 整数倍"的档 ⇒ 尾部的上取整字节由 RTL 的 `wstrb` 掩掉（邻居不动）。
        assert cin == 1 and out_h == 1, "sigmoid 折档只做 C_in=C_out=1 / H=1（真表 Sigmoid_85..125）"
        assert out_w % 8 == 0, "折档要求 W%%8==0（8 个元素 = 一拍），得到 W=%d" % out_w
        fpix = ((out_w // 8 + 3) // 4) * 4                # RTL 的 `fpix`（上取整到 4 的倍数）
        assert fpix <= MAXPIX, "折档有效像素 %d > MAXPIX=%d" % (fpix, MAXPIX)
        xin = B.sigmoid_sweep(cin, in_w, in_h)            # 冻结参考的码点扫描向量（覆盖全 256 码点）
        gold_nhwc = B.sigmoid_ref(xin, cin, in_w, in_h)
        eff_pix = out_w // 8                              # 未上取整的有效像素（RTL 尾掩码的界）
    else:
        # ---- 形状合法性（**逐条**都由 BypassExec.geomOk / planarOk 的出线条件反推）----
        assert rowW % 2 == 0 if op == "maxpool" else True, "maxpool 的运行期行宽必须偶数"
        assert 1 <= rowW <= WIDTH, "rowW=%d 越出 WIDTH=%d（越界会走 T-S3a.2b 的空间 tile，不在本片）" % (rowW, WIDTH)
        assert out_pix <= MAXPIX, "outPix=%d > MAXPIX=%d（同上）" % (out_pix, MAXPIX)
        assert in_cols % 32 == 0 and out_pix % 32 == 0, "平面通路要求 inCols/outPix 都是 32 的倍数"
        assert cin % 8 == 0 and cin != 0, "cIn 必须是 8 的正整数倍（cBlkOk）"
        xin = B.nontrivial(cin, in_w, in_h)
        gold_nhwc = B.maxpool_ref(xin, cin, in_w, in_h) if op == "maxpool" else B.resize2x_ref(xin, cin, in_w, in_h)
        eff_pix = out_pix

    assert len(gold_nhwc) == cin * out_pix, "黄金长度 %d != C_out*outPix = %d" % (len(gold_nhwc), cin * out_pix)
    assert len(set(int(v) for v in gold_nhwc)) > 1, "黄金退化（常数）⇒ 判据没意义"
    # ---- 折成**通道平面**（NCHW，`off(c) = c·HW`）—— 复用冻结参考自己的 to_tensor ----
    xs = B.to_tensor(xin, cin, in_w, in_h)
    gs = B.to_tensor(gold_nhwc, cin, out_w, out_h)

    assert src + len(xs) <= dst or dst + len(gs) <= src, "SRC/DST 重叠"
    assert max(src + len(xs), dst + len(gs)) + 64 <= memsz, "越界（memsz=%d）" % memsz

    # 内存镜像：背景 + SRC 处的输入平面；DST 处预载**与黄金必然不同**（⇒ "少写/不写"必被抓）
    mem = (((np.arange(memsz, dtype=np.int64) % 251) * 131 + 7) % 251).astype(np.uint8)
    mem[src:src + len(xs)] = np.asarray(xs, dtype=np.int64).astype(np.uint8)
    gb = np.asarray(gs, dtype=np.int64).astype(np.uint8)
    mem[dst:dst + len(gb)] = gb ^ np.uint8(0x5A)
    assert int(np.count_nonzero(mem[dst:dst + len(gb)] != gb)) == len(gb), "DST 预载与黄金重合"

    dump(os.path.join(d, "mem.hex"), mem)
    dump(os.path.join(d, "gold.hex"), gb)
    dump(os.path.join(d, "src.hex"), np.asarray(xs, dtype=np.int64).astype(np.uint8))
    with open(os.path.join(d, "job.txt"), "w", encoding="ascii", newline="\n") as f:
        f.write("OP=%s\nCIN=%d\nCOUT=%d\nW=%d\nH=%d\nINW=%d\nINH=%d\nSRC=%d\nDST=%d\nNB=%d\nOUTPIX=%d\n"
                % (op, cin, cin, out_w, out_h, in_w, in_h, src, dst, len(gb), out_pix))
    print("JOBGEN %s op=%s C=%d 输出 %dx%d（输入 %dx%d）| 平面输入 %d B / 黄金 %d B（%d 个不同值）| rows=%d outPix=%d inCols=%d effPix=%d"
          % (name, op, cin, out_w, out_h, in_w, in_h, len(xs), len(gb),
             len(set(int(v) for v in gold_nhwc)), rowW, out_pix, in_cols, eff_pix))

main()
PYEOF

# ---------------------------------------------------------------- 比对器 ----
cat > "$work/cmpdump.py" <<'PYEOF'
"""从 AxiMemModel 的落盘镜像里按窗口对账。argv: dump goldhex srchex dst goldlen SRC"""
import sys
import numpy as np

def load_dump(p, memsz):
    txt = open(p, "r", encoding="utf-8", errors="replace").read()
    h = "".join(txt.split())
    assert len(h) == 2 * memsz, "落盘镜像长度 %d 个十六进制字符 != 2*memsz = %d" % (len(h), 2 * memsz)
    return np.frombuffer(bytes.fromhex(h), dtype=np.uint8)

def load_hex(p):
    return np.frombuffer(bytes.fromhex("".join(open(p, "r", encoding="utf-8").read().split())), dtype=np.uint8)

dumpp, goldp, srcp = sys.argv[1], sys.argv[2], sys.argv[3]
dst, goldlen, SRC = int(sys.argv[4]), int(sys.argv[5]), int(sys.argv[6])
MEMSZ = 2621440
mem = load_dump(dumpp, MEMSZ)
gold = load_hex(goldp)
src = load_hex(srcp)
assert len(gold) == goldlen
got = mem[dst:dst + goldlen]
bad = np.flatnonzero(got != gold)
print("DST_MISMATCH=%d" % len(bad))
print("FIRST_BAD=%d" % (int(bad[0]) if len(bad) else -1))
# 邻居：DST 窗口之后 64 B 必须纹丝不动（背景图案）
nb0, nb1 = dst + goldlen, dst + goldlen + 64
bg = (((np.arange(MEMSZ, dtype=np.int64) % 251) * 131 + 7) % 251).astype(np.uint8)
print("NEIGH_MISMATCH=%d" % int(np.count_nonzero(mem[nb0:nb1] != bg[nb0:nb1])))
# 源：输入平面区必须纹丝不动（DUT 只读不写那里 ⇒ 逐字节 == 供料时的输入）
print("SRC_MISMATCH=%d" % int(np.count_nonzero(mem[SRC:SRC + len(src)] != src)))
PYEOF

# ===========================================================================
# run_job <tag> <netlist> <simname> <op> <cin> <out_w> <out_h>  -> 0=绿(且逐字节对) 1=红
#   打印：装置日志关键行 + DST/SRC/邻居对账；并把 job 变量写进 $work/<tag>/job.txt
# ===========================================================================
run_job() {
  local tag="$1" nl="$2" sim="$3" op="$4" cin="$5" ow="$6" oh="$7"
  local d="$work/$tag"
  echo "--------------------------------------------------------------------------"
  echo "==== [$tag] op=$op C_IN=C_OUT=$cin 输出 ${ow}x${oh}  网表=$nl ===="
  if ! "$PY" "$work/genjob.py" "$tools_abs" "$work" "$tag" "$op" "$cin" "$ow" "$oh" "$SRC" "$DST" "$MEMSZ" > "$work/$tag.gen.log" 2>&1; then
    echo "[$tag] FATAL: 供料失败"; tail -8 "$work/$tag.gen.log"; return 3
  fi
  grep -E '^JOBGEN' "$work/$tag.gen.log" | sed 's/^/   /'
  . "$d/job.txt" 2>/dev/null || true
  local rc=0
  ( cd "$work" && timeout 900 "$VVP" "$work/$sim" \
      "+MEMFILE=$d/mem.hex" "+DUMPFILE=$d/dump.hex" +dump +TILED_B \
      "+OP=$OP" "+CIN=$CIN" "+COUT=$COUT" "+W=$W" "+H=$H" \
      "+GROUP=1" "+FLAGS=1" "+SRC=$SRC" "+DST=$DST" "+INB=$((CIN*INW*INH))" \
      "+QSHIFT=6" "+LID=0" "+SRCPLANAR" "+DSTPLANAR" ) > "$work/$tag.log" 2>&1 || rc=$?
  grep -E '^(TB TILED_B|RESULT|MEM )' "$work/$tag.log" | sed 's/^/    /'
  if [ ! -f "$d/dump.hex" ]; then
    echo "[$tag] JUDGE-RED: 没有落盘镜像（DUT 没跑到收工？）"; tail -3 "$work/$tag.log" | sed 's/^/    /'
    return 1
  fi
  local mis
  mis="$("$PY" "$work/cmpdump.py" "$d/dump.hex" "$d/gold.hex" "$d/src.hex" "$DST" "$NB" "$SRC" 2>&1)"
  echo "$mis" | sed 's/^/    /'
  echo "[$tag] vvp 退出码=$rc"
  echo "$mis" > "$work/$tag.mis"
  if grep -q '^RESULT: PASS' "$work/$tag.log" \
     && echo "$mis" | grep -q '^DST_MISMATCH=0$' \
     && echo "$mis" | grep -q '^SRC_MISMATCH=0$' \
     && echo "$mis" | grep -q '^NEIGH_MISMATCH=0$'; then
    echo "[$tag] 作业 = GREEN（装置 PASS + DST 逐字节 == 整层黄金 + 源/邻居未动）"
    return 0
  fi
  echo "[$tag] 作业 = RED（装置未 PASS 或逐字节不符）"
  return 1
}

# ===========================================================================
# 作业表
#   · 前提档：`cIn == C == 8`（**单块**）—— 同形状、同通路，证明判据线本身是通的（也是回归锚）；
#   · 正对照：`cIn ∈ {16, 64}`（2 / 8 块）。
# 形状合法性见 genjob.py 的断言（这里每一条都被它硬断言）。
# ===========================================================================
JOBS="
premise_maxpool_c8_16x16   maxpool 8  16 16
c16_maxpool_16x16          maxpool 16 16 16
c64_maxpool_16x16          maxpool 64 16 16
c16_resize_32x32           resize  16 32 32
c64_resize_32x32           resize  64 32 32
fold_sigmoid_6400          sigmoid 1  6400 1
fold_sigmoid_1600          sigmoid 1  1600 1
fold_sigmoid_400           sigmoid 1   400 1
"

rc=0
POS_FAIL=""
MULTI_TAG=""
MULTI_OP=""; MULTI_CIN=""; MULTI_OW=""; MULTI_OH=""
while read -r tag op cin ow oh; do
  [ -z "${tag:-}" ] && continue
  if [ -z "$MULTI_TAG" ] && [ "$cin" != "8" ]; then
    MULTI_TAG="$tag"; MULTI_OP="$op"; MULTI_CIN="$cin"; MULTI_OW="$ow"; MULTI_OH="$oh"
  fi
  run_job "$tag" "$nl" sim.vvp "$op" "$cin" "$ow" "$oh" || { rc=1; POS_FAIL="$POS_FAIL $tag"; }
done <<< "$JOBS"

echo "=========================================================================="
if [ "$rc" != "0" ]; then
  echo "RESULT: FAIL 正对照红（未过的作业：$POS_FAIL）——见上；T-S3a.2a 的口径下，"
  echo "  cIn=8 档必须绿、cIn=16/64 档必须绿且逐字节 == 冻结参考的整层黄金。"
  exit 1
fi

# ---------------------------------------------------------------------------
# 负对照：把**块数**钉成 1（`nBlkR <= nBlk` -> `nBlkR <= 16'h0001`）⇒ 只跑块 0
# ---------------------------------------------------------------------------
echo "---- 4) 负对照：网表突变「块数钉成 1」（只跑块 0）⇒ 多块作业必须发火、且首坏字节落在块 1 的平面里 ----"
mut="$work/mut"
mkdir -p "$mut"
if ! "$PY" - "$nl" "$mut/BypassExec.v" <<'PYEOF'
import sys
src = open(sys.argv[1], encoding="utf-8", errors="replace").read()
old = "        nBlkR <= nBlk;"
new = "        nBlkR <= 16'h0001;"
n = src.count(old)
assert n == 1, "mutation anchor not unique: %d" % n
open(sys.argv[2], "w", encoding="ascii", newline="\n").write(src.replace(old, new))
print("  MUT: %s  ->  %s" % (old.strip(), new.strip()))
PYEOF
then
  echo "RESULT: FAIL（构造突变网表失败：生成风格变了，请更新本判据）⇒ 闸门不可信"; exit 2
fi
if cmp -s "$nl" "$mut/BypassExec.v"; then
  echo "RESULT: FAIL（突变网表与原文相同）⇒ 闸门不可信"; exit 2
fi
if ! "$IVERILOG" -g2012 -DBP_TILED_B -o "$work/simm.vvp" "$tb" "$memv" "$mut/BypassExec.v" > "$work/ivm.log" 2>&1; then
  echo "RESULT: FAIL（突变网表编译失败）"; sed -n '1,20p' "$work/ivm.log"; exit 2
fi

# 多块作业（第一档，cIn=16/64）：必须 RED 且首个坏字节 ≥ 8·outPix（= 块 1 的平面起点）
run_job "neg_$MULTI_TAG" "$mut/BypassExec.v" simm.vvp "$MULTI_OP" "$MULTI_CIN" "$MULTI_OW" "$MULTI_OH" || true
NEG_DST="$(sed -n 's/^DST_MISMATCH=//p' "$work/neg_$MULTI_TAG.mis")"
NEG_FB="$(sed -n 's/^FIRST_BAD=//p' "$work/neg_$MULTI_TAG.mis")"
NEG_BLK1_OFS="$((8 * $(sed -n 's/^OUTPIX=//p' "$work/$MULTI_TAG/job.txt")))"
echo "[neg] 突变体：DST_MISMATCH=$NEG_DST（期望 >0）  FIRST_BAD=$NEG_FB（期望 >= 块 1 起点 $NEG_BLK1_OFS）"
if ! [ "${NEG_DST:-0}" -gt 0 ] 2>/dev/null; then
  echo "RESULT: FAIL（负对照没发火：块数钉成 1 后多块作业仍逐字节 == 黄金）⇒ 判据是橡皮章"; exit 2
fi
if ! [ "${NEG_FB:-0}" -ge "$NEG_BLK1_OFS" ] 2>/dev/null; then
  echo "RESULT: FAIL（负对照发火了但首个坏字节 $NEG_FB < 块 1 起点 $NEG_BLK1_OFS ⇒ 不是"漏块"，是整段乱写）"; exit 2
fi
echo "  NEG_OK[漏块]: 块 0 的平面逐字节正确，坏字节全部落在块 1 及以后的平面里 ⇒ 这一发真被抓住"

# 外科式自检：前提档（cIn=8，本来 1 块）在同一突变体下必须仍逐字节 == 黄金
run_job "neg_premise" "$mut/BypassExec.v" simm.vvp maxpool 8 16 16 || true
NEG_P_DST="$(sed -n 's/^DST_MISMATCH=//p' "$work/neg_premise.mis")"
echo "[neg] 同一突变体 × 前提档（cIn=8，1 块）：DST_MISMATCH=$NEG_P_DST（期望 0）"
if [ "${NEG_P_DST:-1}" != "0" ]; then
  echo "RESULT: FAIL（突变体把单块作业也改坏了）⇒ 这一刀不是外科式的"; exit 2
fi
echo "  NEG_OK[外科式]: 同一突变体下单块作业仍逐字节正确（只影响多块）"

# ---------------------------------------------------------------------------
# 负对照②（★★ T-S3a.2c）：把**折的分母**减半（网表里 `imgW32e := imgW32 >>> 4`，即"只处理前一半组"）
#   ⇒ 折档的三个作业都**逐字节发火**（`DST_MISMATCH > 0`：后半段一个字节都没写）。
#   ★ 外科式自检：同一突变在**非折档**（`cIn=8` 前提档）上必须**逐字节不变**（那条路根本不进折分支）
#     ⇒ 证明这一刀只砍在折上。
#   ⚠ 两个坑（都实测踩过，写在这里免得后人重蹈）：
#     · **不能用 `2'd4`** —— Verilog 的 `2'd4` 是 2 位字面量，4 装不下 ⇒ **截成 0**（`>>> 0` = 恒等）
#       ⇒ 有效像素变成 `W`（不是 `W/16`）⇒ `W=6400` 时 `outPix=6400 > MAXPIX=3200` ⇒ 走 **err**
#      （零搬运）而不是逐字节错；改写成**无尺寸字面量** `>>> 4` 才是"分母 8 -> 16"。
#     · **也不是"把 `>>> 3` 直接去掉"** —— 那只会把**长度**放大，而前 `W` 个字节仍然恰好正确
#       （前 `W/8` 组就是真折）⇒ `DST` 窗口反而全对、只有邻居被踩（`DST_MISMATCH=0`）⇒ 对
#       "`DST_MISMATCH>0`"这条判据是**橡皮章**。分母加倍才能让 `DST` 的**后半段**保持预载图案。
# ---------------------------------------------------------------------------
echo "---- 5) 负对照②：网表突变「折的分母 >>3 -> >>4」（只处理前一半组）⇒ 折档三作业必发火 ----"
mut2="$work/mut2"; mkdir -p "$mut2"
if ! "$PY" - "$nl" "$mut2/BypassExec_halve.v" <<'PYEOF'
import sys
src = open(sys.argv[1], encoding="utf-8", errors="replace").read()
old = "  assign _zz_imgW32e_1 = (imgW32 >>> 2'd3);"
new = "  assign _zz_imgW32e_1 = (imgW32 >>> 4);"
n = src.count(old)
assert n == 1, "mutation anchor not unique: %d" % n
open(sys.argv[2], "w", encoding="ascii", newline="\n").write(src.replace(old, new))
print("  MUT: %s  ->  %s" % (old.strip(), new.strip()))
PYEOF
then
  echo "RESULT: FAIL（构造突变网表失败：生成风格变了，请更新本判据）⇒ 闸门不可信"; exit 2
fi
if cmp -s "$nl" "$mut2/BypassExec_halve.v"; then
  echo "RESULT: FAIL（突变网表与原文相同）⇒ 闸门不可信"; exit 2
fi
if ! "$IVERILOG" -g2012 -DBP_TILED_B -o "$work/sim_halve.vvp" "$tb" "$memv" "$mut2/BypassExec_halve.v" > "$work/iv_halve.log" 2>&1; then
  echo "RESULT: FAIL（突变网表编译失败）"; sed -n '1,20p' "$work/iv_halve.log"; exit 2
fi
while read -r tag W_; do
  [ -z "${tag:-}" ] && continue
  run_job "neg2_$tag" "$mut2/BypassExec_halve.v" sim_halve.vvp sigmoid 1 "$W_" 1 || true
  N2_DST="$(sed -n 's/^DST_MISMATCH=//p' "$work/neg2_$tag.mis")"
  echo "[neg2] [$tag] 突变体：DST_MISMATCH=$N2_DST（期望 >0）"
  if ! [ "${N2_DST:-0}" -gt 0 ] 2>/dev/null; then
    echo "RESULT: FAIL（负对照②没发火：[$tag] 折的分母加倍后仍逐字节 == 黄金）⇒ 判据是橡皮章"; exit 2
  fi
done <<< "fold_sigmoid_6400 6400
fold_sigmoid_1600 1600
fold_sigmoid_400 400"
echo "  NEG_OK[折分母加倍]: 三个折档作业都发火（后半段没写 ⇒ DST_MISMATCH>0）"
# 外科式自检：前提档（cIn=8，非折）在同一突变体下必须仍逐字节 == 黄金
run_job "neg2_premise" "$mut2/BypassExec_halve.v" sim_halve.vvp maxpool 8 16 16 || true
N2P_DST="$(sed -n 's/^DST_MISMATCH=//p' "$work/neg2_premise.mis")"
echo "[neg2] 同一突变体 × 前提档（cIn=8 非折）：DST_MISMATCH=$N2P_DST（期望 0）"
if [ "${N2P_DST:-1}" != "0" ]; then
  echo "RESULT: FAIL（突变体把非折作业也改坏了）⇒ 这一刀不是外科式的"; exit 2
fi
echo "  NEG_OK[外科式]: 同一突变体下非折作业仍逐字节正确（折分支根本不参与）"

# ---------------------------------------------------------------------------
# 结构判据
# ---------------------------------------------------------------------------
echo "---- 6) 结构判据：check_dangling.py $nl ----"
"$PY" "$dangling" "$nl" | tail -1 | sed 's/^/    /'
if ! "$PY" "$dangling" "$nl" | grep -q "total dangling instances: 0"; then
  echo "RESULT: FAIL（有悬空实例）"; exit 1
fi

echo "=========================================================================="
echo "cIn=8（前提/回归锚）+ cIn=16（2 块）+ cIn=64（8 块）的 maxpool/resize + ★★ T-S3a.2c 的"
echo "cIn=1 逐点（Sigmoid，W=6400/1600/400 ⇒ 线性折 8 元素/拍）："
echo "  冻结参考自检 = OK（bypass_ref --selftest）"
echo "  正对照       = OK（8 个作业：装置 PASS + DST 逐字节 == 整层黄金/冻结参考 + 源/邻居未动；MISMATCH=0）"
echo "    （含 cIn=1 折：800/200/50 有效像素；W=400 的 416 B 传输由 wstrb 掩尾 ⇒ 邻居未动）"
echo "  负对照①      = OK（块数钉成 1 ⇒ 只跑块 0：块 1 的平面必错、首坏字节 ≥ 8·outPix；单块档仍绿 = 外科式）"
echo "  负对照②      = OK（折分母 >>3->>4 ⇒ 折档三作业 DST_MISMATCH>0；非折档不变 = 外科式）"
echo "  结构         = OK（check_dangling.py：零悬空）"
echo "RESULT: PASS"
exit 0
