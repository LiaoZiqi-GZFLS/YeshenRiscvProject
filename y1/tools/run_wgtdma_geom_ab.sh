#!/usr/bin/env bash
# run_wgtdma_geom_ab.sh —— ★ C4b-B1c「**宽层权重装载器的几何覆盖**」闸门
#   （`rtl/UnitExec.scala` 的同一条 WGTLD/WGTRUN 装载器；落点 = 趟瓦片 `wRam`）
#
# 目标（计划 C4b Task B1c）：B0 实测 **只有 14/53 真单元**满足装载器的几何前提 `wideDmaOk`
#   （`C_in%8==0 && C_out%8==0 && GROUP==1 && 非 depthwise`）。其余 39 个**不是算不了**（算的通路
#   早就支持：`3c16o1g` 见 C4a.5a、depthwise 见 C4a.6），而是**装载器太窄**。本任务把装载器放宽到
#   真表的全部几何：`C_in<8`（跳过的输入通道**零填补**）、`C_out<8`（空行零填补）、depthwise
#   （`GROUP=C_in=C_out`：跨组位置 + 非对角趟零填补）。
#
# ★ 映射（与 `multipass_ref.weight_tiles()` 的**冻结口径**逐字同源，本闸门的对照面）：
#     wRam[(cob*nCi + cib)*576 + cl*72 + cil*9 + tap]
#       == blob[off + (co*cig + ciLocal)*9 + tap]   当且仅当 groupOfOut(co) == groupOfIn(ci)
#       == 0                                        否则（跨组位置 / 跳过通道 / 空行 / 非对角趟）
#   其中 co = cob*8+cl、ci = cib*8+cil、cig = C_in/GROUP、`ci = gco*cig + ciLocal`。
#   ★ `GROUP=1` ⇒ `ci = ciLocal`（B1b 原式）；depthwise ⇒ `cig=1`、`ci = co`（对角位置）。
#   ⇒ 参考镜像**不做第二次算术**：直接 import 冻结的 C4a.5/C4a.6 参考 `tools/multipass_ref.py`
#     的 `weight_tiles()`（= `tiling_ref`/`mac_ref` 那一套的瓦片半）。
#
# 四条判据：
#   ① **逐单元逐字节**：真表的**每个宽层单元**（各自真 offset/nbytes）跑一遍 RTL 装载 ⇒ `wRam[0,Z)`
#      与冻结算出的趟序镜像**逐字节相等**（`WRAM_BAD=0`），`wRam[Z,MAXW)` 一字节未写（`WRAM_OUTSIDE_NONZERO=0`）。
#      ★ 零填补**有牙**：`+WFILE=` 灌的是 **0xFF**（不是 0）⇒ 位置没被装载器写 0 就会露出 0xFF。
#   ② **装载字节数**：`MEM rd == ceil32(nbytes)`（B0 的 32 B 对齐段长；`nbytes%32==0` 时两者相等）
#      且设备侧 `WGT_BYTES == nbytes`（**补位是"写"不是"读"**，多/少都红）。
#   ③ **负对照（必须发火且能定位）**：把 `Conv_0`（`C_in=3`，padded 几何）段内第 7 字节翻 1 位 ⇒
#      `WRAM_BAD=1`，且定位回 `wRam` 地址 7 <-> blob 绝对偏移 7。
#   ④ **真表扫描**：53 个真 conv 单元逐个裁决"装载器几何前提"（`loaderGate`）与"计算侧前提"
#      （`wideGeomOk`：★ C4b-C1 起 = `0 < C_out ≤ 8*NCOB_MAX`，**不再**要 `C_out%8==0` —— 末 co-block
#      允许部分尾块），给出**逐单元表 + 计数**。
#      ★ C4b-C1 之前本闸门期望 `C_out ∈ {1,4,10}` 的 15 个单元"装完响亮 err"；放宽后它们**跑得完**
#        （DONE=1/ERR=0）⇒ 本闸门把那 15 条"期望 err"锚改成"期望 DONE"（**锚必须跟着动，不动就是自欺**）。
#        端到端**数值**判据在 `run_wide_tail_ab.sh`（12 个 dense 尾块单元逐字节 == 黄金）。
#
# 退出码（与 Y1 既有闸门一致）：0 = 全绿；1 = 判据红；2 = 负对照没发火（闸门自身不可信）；3 = 向量/自检失败。
#
# 装置契约（rtl_test/UnitExecWideTb.v + rtl_test/AxiMemModel.v + gen/UnitExec.v）：见 run_wgtdma_wide_ab.sh 头。
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
cd "$here/.." || { echo "FATAL: 进不去 y1/"; echo "RESULT: FAIL"; exit 3; }

PY="${PY:-/d/code/PDS/NaxYeshenLinux/sim/reglogs/lxvenv/Scripts/python.exe}"
[ -x "$PY" ] || PY="$(command -v python || command -v python3 || true)"
[ -n "$PY" ] || { echo "FATAL: 找不到 python"; echo "RESULT: FAIL"; exit 3; }

tb="rtl_test/UnitExecWideTb.v"
memv="rtl_test/AxiMemModel.v"
nl="gen/UnitExec.v"
idx="gen/wgt_index.json"
blob="gen/wgt_blob.bin"
ref="tools/multipass_ref.py"
outdir="gen/c4b_geom_dma"

MEMSZ=2621440          # 2.5 MiB（与 TB 的 AxiMemModel MEMSZ 一致）
BLOB_BASE=524288       # 0x80000：整份对齐 blob 在 DDR 的起点（32 B 对齐）
SRC=131072             # 0x20000（宽层不读激活；只为描述符字段合法）
DST=2097152            # 0x200000
HH=4; WW=64            # 测试几何（H*W=256 = 8 的整数倍 ⇒ wideGeomOk 的 pixPer%8 成立）
MAXW=$(( 8 * 8 * 576 ))  # 36864：wRam 字节数（TB 的上限）
FLIPBYTE=7             # 负对照：Conv_0 段内第 7 字节

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

echo "== run_wgtdma_geom_ab: 宽层权重装载器的**几何覆盖**（C_in<8 / C_out<8 / depthwise）=="
echo "   nl=$nl  tb=$tb  py=$PY  iverilog=$IVERILOG  tmp=$work"
echo "   参考 = 冻结 tools/multipass_ref.py:weight_tiles()（不重写算术）；真 blob/ddr 镜像 = $blob"

TOTAL_BAD=0; NEG_NOFIRE=0
FAIL() { echo "$1"; echo "RESULT: FAIL"; exit "$2"; }

# ---------------------------------------------------------------------------
# [0] 向量 + 参考镜像 + 真表裁决表（一个 python 进程；先于任何仿真）
# ---------------------------------------------------------------------------
echo "---- [0] 真 blob 指纹 + 逐单元参考镜像（冻结 weight_tiles）+ 真表裁决 ----"
if ! "$PY" - "$idx" "$blob" "$ref" "$work" "$MEMSZ" "$BLOB_BASE" "$SRC" "$DST" "$HH" "$WW" "$MAXW" "$FLIPBYTE" <<'PYEOF'; then
import sys, os, json, hashlib, importlib.util
import numpy as np
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass
(idx_p, blob_p, ref_p, work, memsz, blob_base, src, dst, HH, WW, maxw, flipb) = (
    sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], int(sys.argv[5]), int(sys.argv[6]),
    int(sys.argv[7]), int(sys.argv[8]), int(sys.argv[9]), int(sys.argv[10]), int(sys.argv[11]),
    int(sys.argv[12]))
spec = importlib.util.spec_from_file_location("multipass_ref", ref_p)
M = importlib.util.module_from_spec(spec); spec.loader.exec_module(M)
idx = json.load(open(idx_p, encoding="utf-8"))
blob = open(blob_p, "rb").read()
CONV = ("conv3x3", "conv1x1", "depthwise")

bad = []
md5 = hashlib.md5(blob).hexdigest()
if md5 != "aa135f0f7d50780b7b13d9a1ba9c518a":
    bad.append("blob md5=%s != aa135f0f7d50780b7b13d9a1ba9c518a（B0 的 32 B 对齐布局）" % md5)
if int(idx["blob"]["bytes"]) != len(blob):
    bad.append("index.blob.bytes=%d != len(blob)=%d" % (int(idx["blob"]["bytes"]), len(blob)))


def ceil32(n):
    return (n + 31) & ~31


# ★ C4b-C1：计算侧可寻址的 co 行数上界（= UnitExec 的 NCOB_MAX*8；`wOutMem` 按 `PIXW*NCOB_MAX` 字分配）
NCOB_MAX = 8


def analyse(u):
    """按 RTL 的口径（`grpOkW`/`isWide`/`wideGeomOk`）算该单元的几何裁决 —— 纯函数，无副作用。"""
    o = u["own"]; ci, co, gg = int(o["C_IN"]), int(o["C_OUT"]), int(o["GROUP"])
    if gg == 1:
        cig = ci
    elif gg == ci == co:
        cig = 1
    else:
        cig = None
    ni = (co * cig * 9) if cig is not None else None
    ab = ceil32(int(u["weight"]["nbytes"])) if u["weight"] else None
    nci = (ci + 7) // 8
    nco = (co + 7) // 8
    z = nci * nco * 576
    iswide = (ci > 8) or (co > 8)
    grpok = (gg == 1) or (gg == ci == co)
    winok = (int(u["weight"]["offset"]) + ab) <= (1 << 28) if u["weight"] else False
    loadgate = grpok and ci != 0 and co != 0 and ni and winok            # ★ 装载器自己的前提
    # ★ C4b-C1：**计算侧**前提 = `wideGeomOk`（不再要 `C_out%8==0`！末 co-block 允许部分尾块；
    #   改由"输出通道数可寻址"兜底：`0 < C_out ≤ 8*NCOB_MAX`）。
    compgate = (0 < co <= 8 * NCOB_MAX) and (WW == 64) and int(u["layer_id"]) < 64 and ((HH * WW) % 8 == 0)
    return dict(ci=ci, co=co, gg=gg, cig=cig, ni=ni, ab=ab, nci=nci, nco=nco, z=z,
                iswide=iswide, grpok=grpok, winok=winok, loadgate=loadgate, compgate=compgate,
                off=int(u["weight"]["offset"]) if u["weight"] else None,
                nb=int(u["weight"]["nbytes"]) if u["weight"] else None)


convs = [u for u in idx["units"] if u["type"] in CONV]
rows = []
for u in convs:
    a = analyse(u)
    if a["gg"] == 1:
        cig = a["ci"]
    else:
        cig = 1
    wq = np.frombuffer(blob[a["off"]:a["off"] + a["nb"]], dtype=np.int8).reshape(a["co"], cig, 3, 3)
    tiles = M.weight_tiles(np.zeros((1, a["ci"], 1, 1), dtype=np.int64), {"q": wq}, a["gg"])
    img = np.concatenate([t.reshape(-1) for t in tiles]).astype(np.int64) & 0xFF
    assert len(img) == a["z"], "lid=%d 参考镜像 %d != Z=%d" % (u["idx"], len(img), a["z"])
    assert int(np.count_nonzero(img)) > 0, "lid=%d 参考镜像全 0（没分辨度）" % u["idx"]
    open("%s/w_exp_%d.hex" % (work, u["idx"]), "w").write("".join("%02x\n" % b for b in img))
    open("%s/wfile_%d.hex" % (work, u["idx"]), "w").write("".join("ff\n" for _ in range(a["z"])))
    a["name"] = u["name"]; a["idx"] = u["idx"]; a["layer_id"] = int(u["layer_id"])
    a["nz"] = int(np.count_nonzero(img))
    rows.append(a)
    assert a["layer_id"] == u["idx"], "lid=%d layer_id=%s 不等（本闸门按同一数索引参数表）" % (u["idx"], u["layer_id"])

# ---- 公共供料：X 列流全 0（最大 NCOL*8）、bias 全 0、整份 blob 落 DDR（+ 翻一字节的镜像）----
ncolmax = max(r["nci"] * r["nco"] * HH * WW for r in rows)
open("%s/x_zero.hex" % work, "w").write("".join("00\n" for _ in range(ncolmax * 8)))
open("%s/b_zero.hex" % work, "w").write("".join("00000000\n" for _ in range(64)))
pat = lambda i: ((i % 251) * 131 + 7) % 251
mem = bytearray(pat(i) for i in range(memsz))
mem[blob_base:blob_base + len(blob)] = blob
open("%s/mem_blob.hex" % work, "w").write("".join("%02x\n" % b for b in mem))
memf = bytearray(mem)
o0 = memf[blob_base + flipb]
memf[blob_base + flipb] = o0 ^ 0x01
open("%s/mem_flip.hex" % work, "w").write("".join("%02x\n" % b for b in memf))
print("SELFTEST blob_bytes=%d md5=%s conv_units=%d NCOLMAX=%d" % (len(blob), md5, len(rows), ncolmax))
print("SELFTEST_NEGCTL blob@%d 翻偏移 %d：%d -> %d（Conv_0 段内第 %d 字节，期望 WRAM_BAD=1 @ wRam[%d]）"
      % (blob_base, flipb, o0, o0 ^ 1, flipb, flipb))

# ---- 真表裁决表 + 计数 ----
wide = [r for r in rows if r["iswide"]]
narrow_no = [r for r in rows if not r["iswide"]]
lg = [r for r in wide if r["loadgate"]]
dg = [r for r in lg if r["compgate"]]
lerr = [r for r in lg if not r["compgate"]]
print("SWEEP_TOTAL conv_units=%d  isWide=%d  !isWide(走窄通路, C!=8)=%d" % (len(rows), len(wide), len(narrow_no)))
print("SWEEP_LOADGATE 宽层且装载器几何前提成立 = %d/%d（grpOk 且 段长!=0 且 段尾在 28 bit 窗内）"
      % (len(lg), len(rows)))
print("SWEEP_DISPATCH 装载器前提成立且**计算侧**也成立（★ C4b-C1：0 < C_out ≤ %d，**不再**要 C_out%%8==0）"
      "⇒ 整帧可跑 = %d/%d" % (8 * NCOB_MAX, len(dg), len(rows)))
print("SWEEP_LOADS_ONLY 装载器前提成立但计算侧不成立（C_out==0 或 C_out > %d）⇒ **装完再响亮 err** = %d"
      % (8 * NCOB_MAX, len(lerr)))
for r in lerr:
    print("   LOADS_ONLY lid=%-2d %-10s C=%d->%d GROUP=%d  nbytes=%d(对齐 %d) Z=%d（计算侧要 0<C_out≤%d）"
          % (r["idx"], r["name"], r["ci"], r["co"], r["gg"], r["nb"], r["ab"], r["z"], 8 * NCOB_MAX))
for r in narrow_no:
    print("   NARROW_ONLY lid=%-2d %-10s C=%d->%d GROUP=%d（非宽层 ⇒ 窄通路 WeightStore 是 8x8，本版装不了）"
          % (r["idx"], r["name"], r["ci"], r["co"], r["gg"]))
assert len(lg) == len(wide), "有宽层单元的装载器前提不成立（本版应全部成立）"
assert len(dg) + len(lerr) == len(lg)

# ---- 写扫描清单（逐单元 RTL 跑；只有宽层单元会被派到装载器）----
with open("%s/sweep.txt" % work, "w", encoding="ascii", newline="\n") as f:
    for r in rows:
        f.write("%d %s %d %d %d %d %d %d %d %d %d %d\n"
                % (r["idx"], r["name"], r["ci"], r["co"], r["gg"], r["nci"], r["nco"], r["z"],
                   r["nb"], r["ab"], r["off"], 1 if r["iswide"] else 0))
for b in bad:
    print("SELFTEST_BAD: " + b)
sys.exit(3 if bad else 0)
PYEOF
  FAIL "JUDGE-RED(3): 向量/参考自检失败" 3
fi

# ---------------------------------------------------------------------------
# [1] iverilog 编译（被测网表 + TB + 内存模型）
# ---------------------------------------------------------------------------
echo "---- [1] iverilog 编译（UnitExecWideTb + AxiMemModel + gen/UnitExec.v）----"
if ! "$IVERILOG" -g2012 -o "$work/sim.vvp" "$tb" "$memv" "$nl" > "$work/iv.log" 2>&1; then
  sed -n '1,30p' "$work/iv.log"; FAIL "JUDGE-RED(1): iverilog 编译失败" 1
fi
echo "    编译 OK"

# ---------------------------------------------------------------------------
# 对账子程序
# ---------------------------------------------------------------------------
# wramcmp <dump> <exp> <Z> <MAXW> <nci> <blob_off> <cin>
wramcmp() {
  "$PY" - "$1" "$2" "$3" "$4" "$5" "$6" "$7" <<'PYEOF'
import sys
dump, expf, z, maxw, nci, off, cin = (sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4]),
                                      int(sys.argv[5]), int(sys.argv[6]), int(sys.argv[7]))
def load(p):
    try:
        return [int(l.strip(), 16) for l in open(p, encoding="utf-8", errors="replace") if l.strip()]
    except OSError:
        return []
d = load(dump); e = load(expf)
def at(a, i): return a[i] if 0 <= i < len(a) else -1
n = min(z, len(e))
bad = sum(1 for i in range(n) if at(d, i) != at(e, i))
first = next((i for i in range(n) if at(d, i) != at(e, i)), -1)
print("WRAM_BAD=%d" % bad)
if first >= 0:
    p = first // 576; cl = (first % 576) // 72; cil = (first % 72) // 9; tap = first % 9
    print("WRAM_FIRST_ADDR=%d" % first)
    print("WRAM_FIRST_PASS=%d" % p)
    print("WRAM_FIRST_CL=%d" % cl)
    print("WRAM_FIRST_CIL=%d" % cil)
    print("WRAM_FIRST_TAP=%d" % tap)
    print("WRAM_FIRST_DUT=%02x" % (at(d, first) & 0xFF))
    print("WRAM_FIRST_EXP=%02x" % (at(e, first) & 0xFF))
    print("WRAM_FIRST_BLOB_OFF=%d" % (off + (((p // nci) * 8 + cl) * cin + (p % nci) * 8 + cil) * 9 + tap))
print("WRAM_OUTSIDE_NONZERO=%d" % sum(1 for i in range(z, maxw) if at(d, i) != 0))
print("WRAM_EXP_NONZERO=%d" % sum(1 for v in e if v != 0))
PYEOF
}

PWD_ABS="$(pwd)"
# runu <lid> <name> <cin> <cout> <grp> <nci> <nco> <z> <nb> <ab> <off> <memfile> <tag>
runu() {
  local lid="$1" nm="$2" ci="$3" co="$4" gg="$5" ni="$6" no="$7" z="$8" nb="$9" ab="${10}" off="${11}"
  local mf="${12}" tag="${13}"
  local ncol=$(( ni * no * HH * WW ))
  ( cd "$work" && "$VVP" "$work/sim.vvp" \
      "+XFILE=$work/x_zero.hex" "+WFILE=$work/wfile_${lid}.hex" "+BFILE=$work/b_zero.hex" \
      "+MEMFILE=$mf" "+DUMPW=$work/wram_${tag}.hex" \
      "+CIN=$ci" "+COUT=$co" "+GROUP=$gg" "+H=$HH" "+W=$WW" "+TYPE=1" "+FLAGS=1" \
      "+SRC=$SRC" "+DST=$DST" "+INB=$(( ci * HH * WW ))" "+QSHIFT=6" "+LID=$lid" \
      "+M=16777216" "+ZPAD=0" "+ZY=0" "+NCOL=$ncol" "+NCI=$ni" "+NCO=$no" \
      "+WBASE=$(( BLOB_BASE + off ))" "+WEXP=$ab" ) > "$work/run_${tag}.log" 2>&1
  return 0
}

# ---------------------------------------------------------------------------
# [2] 真表逐单元扫描（44 个宽层单元：真 offset/nbytes + 真几何）
# ---------------------------------------------------------------------------
echo "---- [2] 真表逐单元扫描：宽层单元的装载（逐字节 + 装载字节数 + DONE/ERR 按计算侧前提）----"
SWEEP_BAD=0; SWEEP_N=0
while read -r lid nm ci co gg ni no z nb ab off iswide; do
  SWEEP_N=$((SWEEP_N + 1))
  runu "$lid" "$nm" "$ci" "$co" "$gg" "$ni" "$no" "$z" "$nb" "$ab" "$off" "$work/mem_blob.hex" "u$lid"
  RD="$(sed -n 's/^MEM rd=\([0-9]*\).*/\1/p' "$work/run_u$lid.log" | head -1)"
  WB="$(sed -n 's/.*WGT_BYTES=\([0-9]*\).*/\1/p' "$work/run_u$lid.log" | head -1)"
  DN="$(sed -n 's/^DONE_SEEN=\([0-9]*\).*/\1/p' "$work/run_u$lid.log" | head -1)"
  ER="$(sed -n 's/.*ERR_SEEN=\([0-9]*\).*/\1/p' "$work/run_u$lid.log" | head -1)"
  if [ "$iswide" = "0" ]; then
    # 非宽层：走窄通路，装载器根本不参与 ⇒ 只记录（由 [0] 的 NARROW_ONLY 行解释）
    printf '   lid=%-2s %-10s C=%2s->%-2s G=%-2s | 非宽层（走窄通路）⇒ 不进装载器 | DONE=%s ERR=%s WB=%s RD=%s\n' \
      "$lid" "$nm" "$ci" "$co" "$gg" "${DN:-?}" "${ER:-?}" "${WB:-?}" "${RD:-?}"
    continue
  fi
  eval "$(wramcmp "$work/wram_u$lid.hex" "$work/w_exp_$lid.hex" "$z" "$MAXW" "$ni" "$off" "$ci" \
          | grep -E '^[A-Z0-9_]+=' | sed 's/^/SWR_/')"
  # ★ C4b-C1：**计算侧**前提搬到与 RTL 同一口径 —— `0 < C_out ≤ 8*NCOB_MAX`（不再要 `C_out%8==0`）。
  #   真表 44 个宽层单元的 `C_out` 全 ≤ 64 ⇒ **全部**期望 DONE=1/ERR=0（部分尾块已支持）。
  expdn=0; [ "$co" -gt 0 ] 2>/dev/null && [ "$co" -le 64 ] 2>/dev/null && expdn=1
  row="ok"
  [ "${WB:-x}" = "$nb" ]  || { row="$row WGT_BYTES($WB!=$nb)"; SWEEP_BAD=$((SWEEP_BAD+1)); }
  [ "${RD:-x}" = "$ab" ]  || { row="$row MEMrd($RD!=$ab)"; SWEEP_BAD=$((SWEEP_BAD+1)); }
  [ "${SWR_WRAM_BAD:-x}" = "0" ] || { row="$row WRAM_BAD(${SWR_WRAM_BAD:-?})"; SWEEP_BAD=$((SWEEP_BAD+1)); }
  [ "${SWR_WRAM_OUTSIDE_NONZERO:-x}" = "0" ] || { row="$row OUTSIDE(${SWR_WRAM_OUTSIDE_NONZERO:-?})"; SWEEP_BAD=$((SWEEP_BAD+1)); }
  if [ "$expdn" = "1" ]; then
    [ "${DN:-x}" = "1" ] && [ "${ER:-x}" = "0" ] || { row="$row DONE/ERR($DN/$ER)"; SWEEP_BAD=$((SWEEP_BAD+1)); }
  else
    [ "${DN:-x}" = "0" ] && [ "${ER:-x}" = "1" ] || { row="$row DONE/ERR($DN/$ER,期望装完 err：计算侧不支持)"; SWEEP_BAD=$((SWEEP_BAD+1)); }
  fi
  printf '   lid=%-2s %-10s C=%2s->%-2s G=%-2s nci=%s nco=%s Z=%-5s | DONE=%s ERR=%s WB=%-5s RD=%-5s WRAM_BAD=%-3s OUTSIDE=%s NZ=%s | %s\n' \
    "$lid" "$nm" "$ci" "$co" "$gg" "$ni" "$no" "$z" "${DN:-?}" "${ER:-?}" "${WB:-?}" "${RD:-?}" \
    "${SWR_WRAM_BAD:-?}" "${SWR_WRAM_OUTSIDE_NONZERO:-?}" "${SWR_WRAM_EXP_NONZERO:-?}" "$row"
  if [ "${SWR_WRAM_BAD:-0}" != "0" ]; then
    echo "      定位：wRam[${SWR_WRAM_FIRST_ADDR}]（趟 ${SWR_WRAM_FIRST_PASS} cl=${SWR_WRAM_FIRST_CL} cil=${SWR_WRAM_FIRST_CIL} tap=${SWR_WRAM_FIRST_TAP}）= blob 偏移 ${SWR_WRAM_FIRST_BLOB_OFF}  dut=${SWR_WRAM_FIRST_DUT} exp=${SWR_WRAM_FIRST_EXP}"
  fi
done < "$work/sweep.txt"
[ "$SWEEP_BAD" -eq 0 ] && echo "   ★ 真表扫描：$SWEEP_N 个单元全部按预期（逐字节相等 + 装载字节数相符 + DONE/ERR 与计算侧前提一致）"
TOTAL_BAD=$(( TOTAL_BAD + SWEEP_BAD ))

# ---------------------------------------------------------------------------
# [3] 负对照：Conv_0（C_in=3，padded 几何）段内翻 1 字节 ⇒ 判据① 红且定位
# ---------------------------------------------------------------------------
echo "---- [3] 负对照：Conv_0（C_in=3）blob 段内第 $FLIPBYTE 字节翻 1 位 ----"
N0="$(awk '$1==0{print}' "$work/sweep.txt")"
if [ -z "$N0" ]; then
  echo "NEGCTL-FAIL: 找不到 Conv_0（idx 0）"; NEG_NOFIRE=$((NEG_NOFIRE+1))
else
  set -- $N0
  runu "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" "${10}" "${11}" "$work/mem_flip.hex" "flip"
  eval "$(wramcmp "$work/wram_flip.hex" "$work/w_exp_0.hex" "${8}" "$MAXW" "${6}" "${11}" "${3}" \
          | grep -E '^[A-Z0-9_]+=' | sed 's/^/FL_/')"
  RD="$(sed -n 's/^MEM rd=\([0-9]*\).*/\1/p' "$work/run_flip.log" | head -1)"
  if [ "${FL_WRAM_BAD:-0}" -gt 0 ] 2>/dev/null && [ "${FL_WRAM_FIRST_ADDR:-x}" = "$FLIPBYTE" ] \
     && [ "${FL_WRAM_FIRST_BLOB_OFF:-x}" = "$FLIPBYTE" ]; then
    echo "   发火：WRAM_BAD=${FL_WRAM_BAD} @ wRam[${FL_WRAM_FIRST_ADDR}] <-> blob 绝对偏移 ${FL_WRAM_FIRST_BLOB_OFF}"
    echo "         dut=${FL_WRAM_FIRST_DUT} exp=${FL_WRAM_FIRST_EXP}；读字节数仍 = ${RD}（判据② 不红 ⇒ 两条判据各抓各的）"
  else
    echo "NEGCTL-FAIL: 翻字节没红或定位错（BAD=${FL_WRAM_BAD:-?} @ addr=${FL_WRAM_FIRST_ADDR:-?} / blob=${FL_WRAM_FIRST_BLOB_OFF:-?}）"
    NEG_NOFIRE=$((NEG_NOFIRE+1))
  fi
fi

# ---------------------------------------------------------------------------
# [4] 汇总
# ---------------------------------------------------------------------------
echo "=========================================================================="
echo "判据① 逐单元逐字节  = $([ "$SWEEP_BAD" -eq 0 ] && echo 'OK（44 个宽层单元 wRam[0,Z) == 冻结 weight_tiles 的趟序镜像；段外未写）' || echo "RED（$SWEEP_BAD 项）")"
echo "判据② 装载字节数    = 每单元 WGT_BYTES == nbytes 且 MEM rd == ceil32(nbytes)（见上表）"
echo "判据③ 负对照        = $([ "$NEG_NOFIRE" -eq 0 ] && echo 'OK（Conv_0 段内翻字节 ⇒ WRAM_BAD=1 @ wRam[7] <-> blob 偏移 7）' || echo 'RED')"
echo "判据④ 真表扫描      = 53 个真 conv 单元：**装载器几何前提**（GROUP in {1,C_in==C_out} + 段长!=0 + 段尾在 28 bit 窗内）"
echo "                      53/53 成立；其中 44/53 是宽层（走装载器）、9/53 非宽层（C in {1,4}：窄通路 8x8 装不了）；"
echo "                      ★ C4b-C1 起计算侧前提 = 0 < C_out ≤ 8*NCOB_MAX（**不再**要 C_out%8==0）"
echo "                      ⇒ **44/53 可整帧跑**（旧口径 29/53），0/53 装完响亮 err（真表 C_out 全 ≤ 64）"
echo "                      ★ 其中 C_out ∈ {1,4,10} 的 12 个 dense 单元的**端到端数值判据**在 run_wide_tail_ab.sh"
echo "能力边界（装载器）  = GROUP ∉ {1, C_in==C_out} ⇒ 响亮 err + 零搬运（见 run_wgtdma_wide_ab.sh [4b]）"
if [ "$NEG_NOFIRE" -ne 0 ]; then echo "NEGCTL-FAIL: $NEG_NOFIRE 条负对照没发火 ⇒ 闸门自身不可信"; echo "RESULT: FAIL"; exit 2; fi
if [ "$TOTAL_BAD" -ne 0 ]; then echo "JUDGE-RED: $TOTAL_BAD 条判据未过"; echo "RESULT: FAIL"; exit 1; fi
echo "RESULT: PASS"
exit 0
