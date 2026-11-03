#!/usr/bin/env bash
# run_dwpack_ab.sh —— ★★ NPU v2 切片 B1（**depthwise 用满 8 条通道**，AFTER1 档）的**集成**闸门。
#
# 被测 = 片 B-1 钉死、本片落进产品 RTL 的四处 additive 口（spec §4.6a / `reports/npu_v2_accounting.md`
#   §Slice B-1 的接口表；参考实现 = 独立探针 `rtl_test/DwLaneProbe.scala` 的 AFTER1 档）：
#   ① `rtl/Conv3x3Slice.scala` 的 `DWSKIP` 块 —— `dw_mode` 口 + `ph==1 ⇒ ph:=10` 跳拍 + 逐 lane x
#      （`arr.x_dw(r)(j) := colWin(j%3)(r)(j/3)`、`arr.x8(r) := colWin(2)(r)(2)`）；
#   ② `rtl/MacArray.scala` 的 `DW` 档 —— 逐 lane 2:1（`dw_mode ? x_dw/w_dw : 广播 x/瓦片 w`）+
#      **第 9 抽头行**（`x8·w8` 并进同一个 acc）；
#   ③ `rtl/WeightStore.scala` 的 **dw 静态对角读口**（`dwTile(r)(j) = mem[r*72 + r*9 + j]` + `dwTile8`）；
#   ④ `rtl/UnitExec.scala` 的 `dwW := isDwW`（`go` 那一拍锁存；`MultiPassUnit` 只转发）。
#   网表 = `gen/UnitExec_tiled.v`（`TILING=true` = 板级那一档；`TILING=false` 的三份冻结网表**没有**
#   这条通路 —— 那一侧的"逐字节不变"由 md5 前置项 + 全部既有闸门保住，不在本闸门的判据里）。
#   装置 = `rtl_test/UnitExecWideTb.v`（**`-DUE_X1OBS -DUE_CGEOM`**：只有本闸门读 `x1_beats` 这个口，
#   它报的就是切片 `obs_beats` = **`arr.en` 拍数**）+ `rtl_test/AxiMemModel.v`。
#
# 判据（"先立靶、再发火、再外科"三件套；全部按**预测量**断言，不看"像不像"）：
#   0) 前置：冻结参考自检（`multipass_ref` 拆趟 == 整层）；`TILING=false` 三网表 md5 逐字节不变；
#      **结构判据**（四处 additive 口真的在 `gen/UnitExec_tiled.v` 里：`_zz_dw_mode <= isDwW` /
#      逐 lane 2:1 / 第 9 抽头行 / `ph==1` 的 dw 跳拍），锚不唯一 ⇒ 闸门自身不可信（exit 3）。
#   1) 正对照（**六个形状** C ∈ {4,8,10,16,32,64}；探针覆盖的同一条形状表 + 全层黄金）：
#        · `RESULT: PASS`（装置自检：跑完 + 无 err + 列流喂完 + WR 字节/突发数对）；
#        · `DST` 区 `[DST, DST+C*H*W)` **逐字节 == 冻结黄金**（`tiling_ref.conv_tiled`；本闸门另用
#          `quant_ref` 的 requant 与 acc 互证 —— 见"fixture premise"）；
#        · **实测拍数** `X1_BEATS == 1·nCo·H·W`（= **1 拍/像素/趟**；nCo = 对角趟数）；
#   2) **BEFORE 对照（同一张作业、同一黄金，只把 `dw_mode` 掐掉）**——网表突变
#      `_zz_dw_mode <= isDwW` ⇒ `1'b0`：
#        · 拍数必须回到 **9·nCo·H·W**（= as-built 的 9 拍/像素/趟）；
#        · 输出**逐字节不变**（= 跳掉的 8 个拍在数值上确实什么都不干的**直接证据**）；
#        · **实测拍比 = 9.00×**（与 B-1 探针的 `BEFORE→AFTER1` 读数同一条口径）；
#   3) 负对照（**必发火 + 按预测量定位**）：把 lane (co=0, j=2) 的 2:1 反向（`dw_mode ? x_dw_0_2 : x_2`
#      ⇒ `dw_mode ? x_2 : x_2`，即**dw 档读 dense 操作数**）⇒ `MISMATCH == 预测值`（预测 = python 用
#      **冻结 acc** 现算：`Δacc[8b] += (X[8b+2]pad[y][x] - X[8b]pad[y][x+2]) · w[8b,0,0,2]`，再 requant）；
#      ★ 同一条突变**再来一条外科式**：把被换 lane 的权重 `w[c,c,0,2]` 置 0（两个候选操作数**乘到同一个 0**）
#      ⇒ 预测量恰 0 ⇒ 同一突变网表必须**翻绿**（证明红来自"操作数被换掉"，不是注入本身坏了）。
#   4) 第二条负对照（第 9 抽头行，AFTER1 特有的那一行）：`_zz_acc_0_8 = (dw_mode ? _zz_acc_0 : 18'h0)`
#      ⇒ `18'h0`（切掉第 9 抽头）⇒ `MISMATCH == 预测值`（预测 = 黄金把 `w[8b,0,2,2]` 置 0 后的差异字节数）。
#      ★ 重锚（2026-10-16 切片 C-2）：C-2 把第 9 抽头积从**组合** `x8·w8` 改成 **A 级寄存器 `p8r`**
#      （多拍 DCI 档的正确性前提，见 `rtl/MacArray.scala`）⇒ 该行的网表文本随之改名：
#      `_zz_acc_0` = p8r（A 级寄存）、`_zz_acc_0_8` = dw 门输出（`Mux(dw_mode, p8r, 0)`）、
#      `_zz_acc_0_7` = 其符号扩展。语义（dw 档把第 9 抽头并进 acc；切除它 = 该项恒 0）**一字未变**。
#
# 退出码：0 = 全过 / 1 = 判据红 / 2 = 负对照/突变没发火（或锚不唯一）/ 3 = 前置缺失。
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
cd "$here/.." || { echo "FATAL: 进不去 y1/"; echo "RESULT: FAIL"; exit 3; }

PY="${PY:-/d/code/PDS/NaxYeshenLinux/sim/reglogs/lxvenv/Scripts/python.exe}"
[ -x "$PY" ] || PY="$(command -v python || command -v python3 || true)"
[ -n "$PY" ] || { echo "FATAL: 找不到 python"; echo "RESULT: FAIL"; exit 3; }

tb="rtl_test/UnitExecWideTb.v"
memv="rtl_test/AxiMemModel.v"
nl="gen/UnitExec_tiled.v"
mpref="tools/multipass_ref.py"
tref="tools/tiling_ref.py"
qref="tools/quant_ref.py"
MEMSZ=2621440
SRC=131072            # 0x20000
DST=2097152           # 0x200000
HH=8; WW=16           # H*W = 128（% 8 == 0 且 /128 整除 ⇒ 装置那三条字节/突发判据成立）；W ≤ WIDTH(34)
SHAPES="4 8 10 16 32 64"
SEED0=71000
SURG_SHAPE=16         # 外科式的形状（通道 0/2 置 0 ⇒ 两个操作数恒等）

find_tool() {
  local n="$1" p d
  p="$(command -v "$n" 2>/dev/null || true)"
  if [ -z "$p" ]; then for d in /c/msys64/ucrt64/bin /mingw64/bin /usr/bin; do [ -x "$d/$n" ] && { p="$d/$n"; break; }; done; fi
  printf '%s' "$p"
}
IVERILOG="$(find_tool iverilog)"; VVP="$(find_tool vvp)"

echo "== run_dwpack_ab: NPU v2 切片 B1 —— depthwise 用满 8 条通道（AFTER1）的集成闸门 =="
echo "   nl=$nl  py=$PY  iverilog=${IVERILOG:-<none>}  形状 C ∈ {$SHAPES}  几何 H=$HH W=$WW"

for f in "$nl" "$tb" "$memv" "$mpref" "$tref" "$qref"; do
  [ -f "$f" ] || { echo "FATAL: 缺 $f"; echo "RESULT: FAIL"; exit 3; }
done
[ -n "$IVERILOG" ] && [ -n "$VVP" ] || { echo "FATAL: 缺 iverilog/vvp"; echo "RESULT: FAIL"; exit 3; }

work="$(mktemp -d)"
cleanup() { [ "${KEEP_TMP:-0}" = "1" ] && echo "KEEP_TMP=1 => $work" || rm -rf "$work"; }
trap cleanup EXIT
export PYTHONPATH="./.pydeps;../third_party/yunet/deps"
export PYTHONIOENCODING=utf-8
PWD_ABS="$(pwd)"

TOTAL_BAD=0; NEG_NOFIRE=0

# -----------------------------------------------------------------------------
# 0) 前置：参考自检 + TILING=false 三网表 md5 + 四处 additive 口的结构判据
# -----------------------------------------------------------------------------
echo "---- 0) 前置：参考自检 + TILING=false 三网表 md5 + 四处 additive 口的结构判据 ----"
"$PY" "$mpref" selftest >/dev/null 2>&1 || "$PY" "$mpref" --selftest >/dev/null 2>&1 \
  || { echo "RESULT: FAIL 参考自检没过"; exit 3; }
echo "   参考自检 OK（multipass_ref selftest：拆趟 == 整层 + 预测有牙）"

EXPECT_UE="7593b189ae8339e291c2fa398d0fcb2b"
EXPECT_W32="817ab5bbce2ef0bcaae556c8a9ded41b"
EXPECT_W640="5d2cd81addb84c62b2407f64aa0ac3a2"
md5of() { md5sum "$1" 2>/dev/null | awk '{print $1}'; }
MD5_BAD=0
for pair in "gen/UnitExec.v:$EXPECT_UE" "gen/UnitExec_w32.v:$EXPECT_W32" "gen/UnitExec_w640.v:$EXPECT_W640"; do
  f="${pair%%:*}"; e="${pair##*:}"; g="$(md5of "$f")"
  if [ "$g" != "$e" ]; then echo "    JUDGE-RED: $f md5=$g != $e（TILING=false 必须逐字节不变）"; MD5_BAD=1; fi
done
[ "$MD5_BAD" = 0 ] && echo "   TILING=false 三网表 md5 不变（97912901… / 618af338… / ddb9bb8a…）"
[ "$MD5_BAD" = 0 ] || { echo "RESULT: FAIL"; exit 1; }
echo "   TILED_NL_MD5=$(md5of "$nl")（gen/UnitExec_tiled.v，只记账）"

if ! "$PY" - "$nl" <<'PYEOF'; then
import sys
try: sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception: pass
nl = open(sys.argv[1], encoding="utf-8").read().replace("\r\n", "\n")
# 四处 additive 的口（结构判据：网表里真的在；锚必须唯一 ⇒ 突变才可信）
checks = [
  ("④ UnitExec：`dwW := isDwW`（go 拍锁存）", "_zz_dw_mode <= isDwW;"),
  ("② MacArray：逐 lane 2:1（lane co=0,j=2）", "assign _zz_ps_0_1_2 = (dw_mode ? x_dw_0_2 : x_2);"),
  ("② MacArray：第 9 抽头行（行 co=0；C2 后 Mux 内是 A 级 p8r）", "assign _zz_acc_0_8 = (dw_mode ? _zz_acc_0 : 18'h0);"),
  ("③ WeightStore：dw 对角读口", "ws_dwTile8_0"),
  ("① Conv3x3Slice：dw 跳拍条件", "inPix && dw_mode"),
]
bad = []
for name, pat in checks:
    n = nl.count(pat)
    print("   [struct] %-42s hit=%d" % (name, n))
    if n < 1: bad.append(name + " 不在网表里")
for b in bad: print("   JUDGE-RED: " + b)
# 突变锚必须**恰好** 1 处
anchors = ["_zz_dw_mode <= isDwW;",
           "assign _zz_ps_0_1_2 = (dw_mode ? x_dw_0_2 : x_2);",
           "assign _zz_acc_0_8 = (dw_mode ? _zz_acc_0 : 18'h0);"]
for a in anchors:
    n = nl.count(a)
    if n != 1: bad.append("突变锚不唯一（%d 处）：%s" % (n, a))
print("   突变锚唯一性检查：%s" % ("OK（3 条各 1 处）" if not bad else "BAD"))
sys.exit(1 if bad else 0)
PYEOF
  echo "RESULT: FAIL 结构判据不过（见上）"; exit 3
fi

# -----------------------------------------------------------------------------
# 1) iverilog 编译（tiled 网表；-DUE_CGEOM 逐片几何口 + -DUE_X1OBS 拍数观测口）
# -----------------------------------------------------------------------------
echo "---- 1) iverilog 编译（UnitExecWideTb + AxiMemModel + gen/UnitExec_tiled.v；-DUE_CGEOM -DUE_X1OBS）----"
if ! "$IVERILOG" -g2012 -DUE_CGEOM -DUE_X1OBS -o "$work/sim.vvp" "$tb" "$memv" "$nl" > "$work/iv.log" 2>&1; then
  echo "JUDGE-RED: iverilog 编译失败"; sed -n '1,30p' "$work/iv.log"; echo "RESULT: FAIL"; exit 1
fi
echo "   编译 OK"

# -----------------------------------------------------------------------------
# 2) 作业生成器（**调用**冻结参考：multipass_ref 的 make_layer/weight_tiles/bias_of +
#    tiling_ref.conv_tiled 的黄金；不重写任何算术）
#   每个形状落一目录：x.hex（对角 8 通道列流）/ w.hex / b.hex / gold.hex / job.txt（含预测量）
# -----------------------------------------------------------------------------
cat > "$work/genjob.py" <<'PYEOF'
import sys, os
sys.path.insert(0, sys.argv[1])
import numpy as np
import wide_exec_ref as W          # ★ 冻结参考（集成宽层闸门同一条：run_dw_wide / run_unitexec_wide / run_wide_tail）

TILE = W.TILE

def dump(path, toks, w=2):
    m = (1 << (4 * w)) - 1
    with open(path, "w", encoding="ascii", newline="\n") as f:
        f.write("".join(("%0" + str(w) + "x\n") % (int(t) & m) for t in toks))

def build(C, H, Wd, seed, d, zero_ch=(), name="pos"):
    """一个 depthwise 形状的作业 + 预测量。
    · 权重 = **对角**稠密 (C,C,3,3)（其余位置恒 0 = dw 口径）；黄金/参数全走**冻结** `wide_exec_ref`；
    · 列流 = 对角趟序（block b 的 8 通道列），与 `tools/dw_wide_ref.py` 的裁法**同一套**；
    · 预测量（负对照 = python 用**同一条冻结 acc** 现算）：
        Δacc[8b] += (X[8b+2]pad[y][x] - X[8b]pad[y][x+2])·w[8b,8b,0,2]   （lane (0,2) 反向读 dense）
        Δacc[8b] -= X[8b]pad[y+1][x+1]·w[8b,8b,2,2]                      （第 9 抽头行切除）
    """
    C = int(C)
    n_ci = (C + TILE - 1) // TILE
    n_co = n_ci
    CI8, CO8 = n_ci * TILE, n_co * TILE
    rng = np.random.default_rng(seed)                    # ★ 与 `build_one` 同一消费序（第一个 draw 就是 xq）
    w = np.random.default_rng(seed + 7919).integers(-10, 11, size=(C, C, 3, 3), dtype=np.int64)
    for c in range(C):                                   # 对角 ⇒ 与 dw 的 "w[c][c][k]" 等价
        w[c, [j for j in range(C) if j != c], :, :] = 0
    if name == "surg":                                   # ★ 外科式：把被换的 lane 的权重置 0
        for c in range(C):                               #   ⇒ 两个候选操作数**乘到同一个 0** ⇒ 突变必翻绿
            w[c, c, 0, 2] = 0
    g = np.random.default_rng(seed + 1)
    spec = {"cin": C, "cout": C, "w": w, "M": 3_000_000,
            "z_pad": -128, "z_y": int(g.integers(-2, 3)),
            "bias_adj": g.integers(-10, 11, size=C).astype(np.int64), "name": "DwSynth_%d" % C}
    r = W.build_one(spec, H, Wd, d, seed=seed)
    if not r["tiled_eq"]:
        print("JUDGE-RED: 参考自检 tiled_eq=0（拆趟 != 整层）"); return None

    M, zp, zy = r["M"], r["zp"], r["zy"]
    xq = rng.integers(-20, 21, size=(1, C, H, Wd)).astype(np.int64)
    for c in zero_ch:
        if c < C: xq[0, c] = 0                            # 外科式：两个候选操作数恒等（= 全 0）
    x8 = np.zeros((1, CI8, H, Wd), dtype=np.int64); x8[0, :C] = xq[0]
    wfull = np.zeros((CO8, CI8, 3, 3), dtype=np.int64); wfull[:C, :C] = w
    bj8 = np.zeros(CO8, dtype=np.int64); bj8[:C] = spec["bias_adj"]
    acc = W.conv_acc(x8, wfull, zp, bj8)                  # ★ 冻结 acc（= build_one 内部那一条）
    gold = W.requant(acc, M, zy)[:C]
    # ---- fixture premise：重算的 acc/requant 与冻结参考自己落的 gold.hex **逐字节相同** ----
    gfile = np.array([int(l.strip(), 16) for l in open(os.path.join(d, "gold.hex"), encoding="ascii") if l.strip()],
                     dtype=np.int64).astype(np.int8)
    if not np.array_equal(gold.reshape(-1), gfile):
        print("JUDGE-RED: fixture premise 破了（重算 acc != 冻结 gold.hex）"); return None

    def P(c):                                             # 空间零填充 = z_pad（与参考 conv_acc 同一条）
        return np.pad(x8[0, c], ((1, 1), (1, 1)), constant_values=int(zp))

    acc_neg = acc.copy()
    for b in range(n_co):
        ch = b * TILE
        acc_neg[ch] += (P(ch + 2)[0:H, 0:Wd] - P(ch)[0:H, 2:Wd + 2]) * int(wfull[ch, ch, 0, 2])
    acc_t8 = acc.copy()
    for b in range(n_co):
        ch = b * TILE
        acc_t8[ch] -= P(ch)[2:H + 2, 2:Wd + 2] * int(wfull[ch, ch, 2, 2])

    def mm(a):
        return int(np.count_nonzero(W.requant(a, M, zy)[:C].reshape(-1) != gold.reshape(-1)))
    pred_neg, pred_t8 = mm(acc_neg), mm(acc_t8)

    # ---- 对角列流（block 0..nCo-1，每块 H*W 列 × 8 通道；与 dw_wide_ref 的裁法同一套）----
    stream = np.concatenate([x8[0, b * TILE:(b + 1) * TILE].transpose(1, 2, 0).reshape(-1) for b in range(n_co)])
    dump(os.path.join(d, "x.hex"), stream)
    with open(os.path.join(d, "job.txt"), "w", encoding="ascii", newline="\n") as f:
        f.write("CIN=%d\nCOUT=%d\nGROUP=%d\nH=%d\nW=%d\n" % (C, C, C, H, Wd))
        f.write("M=%d\nZY=%d\nZPAD=%d\nNCI=%d\nNCO=%d\nNCOL=%d\nLEN=%d\n"
                % (M, zy, zp, n_ci, n_co, n_co * H * Wd, C * H * Wd))
        f.write("PRED_NEG=%d\nPRED_T8=%d\nBEATS1=%d\nBEATS9=%d\nDISTINCT=%d\n"
                % (pred_neg, pred_t8, n_co * H * Wd, 9 * n_co * H * Wd,
                   len(set(int(v) for v in gold.reshape(-1)))))
    print("JOBGEN %-5s C=%-2d n_ci=%d n_co=%d M=%d z_y=%d z_pad=%d len=%d distinct=%d PRED_NEG=%d PRED_T8=%d"
          % (name, C, n_ci, n_co, M, zy, zp, C * H * Wd, len(set(int(v) for v in gold.reshape(-1))),
             pred_neg, pred_t8))
    return d

def main():
    tools, work, C, H, Wd, seed, d, mode = (sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4]),
                                             int(sys.argv[5]), int(sys.argv[6]), sys.argv[7], sys.argv[8])
    zc = ()                                             # ★ 外科式由**权重置 0**表达（见 build 里的 "surg" 支），不动输入
    r = build(C, H, Wd, seed, d, zero_ch=zc, name=mode)
    sys.exit(3 if r is None else 0)

main()
PYEOF

# -----------------------------------------------------------------------------
# 2b) 内存镜像（共用一个；DST 预载必须与该形状黄金不同 ⇒ "不写"必被抓）
# -----------------------------------------------------------------------------
echo "---- 2b) 内存镜像（素周期预载；DST 区与该形状黄金必须足够不同）----"
"$PY" - "$work" "$MEMSZ" "$DST" <<'PYEOF' || { echo "RESULT: FAIL 内存镜像构造失败"; exit 3; }
import sys
work, memsz, dst = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
pre = [((i % 251) * 131 + 7) % 251 for i in range(memsz)]
open(work + "/mem_nt.hex", "w").write("".join("%02x\n" % b for b in pre))
print("   mem_nt.hex：%d B（DST=%d；预载 = 素周期模式）" % (memsz, dst))
PYEOF

# -----------------------------------------------------------------------------
# 3) 网表突变（**外科锚**：把新逻辑拆掉 / 换个操作数，而不是改夹具）
# -----------------------------------------------------------------------------
echo "---- 3) 网表突变：dw_cut（掐 dw_mode）/ sel（2:1 反向）/ tap8（切第 9 抽头行）----"
mutate() {  # mutate <in> <out> <mode>
  "$PY" - "$1" "$2" "$3" <<'PYEOF'
import sys
src, out, mode = sys.argv[1], sys.argv[2], sys.argv[3]
# ★ 逐字节保真：网表带中文注释（UTF-8）⇒ 二进制读、utf-8 解码、newline="" 写回
data = open(src, "rb").read().decode("utf-8")
MUT = {
  "dw_cut": ("_zz_dw_mode <= isDwW;", "_zz_dw_mode <= 1'b0;   // DWPACK-MUT（dw_mode 掐掉 = BEFORE）"),
  "sel":    ("assign _zz_ps_0_1_2 = (dw_mode ? x_dw_0_2 : x_2);",
             "assign _zz_ps_0_1_2 = (dw_mode ? x_2 : x_2);   // DWPACK-MUT（lane (0,2) 反向读 dense）"),
  "tap8":   ("assign _zz_acc_0_8 = (dw_mode ? _zz_acc_0 : 18'h0);",
             "assign _zz_acc_0_8 = 18'h0;   // DWPACK-MUT（第 9 抽头行切除；C2 后切 dw 门输出）"),
}
old, new = MUT[mode]
n = data.count(old)
if n != 1:
    print("MUTATE-ANCHOR-BAD: mode=%s 命中 %d 次（要求恰好 1）" % (mode, n)); sys.exit(1)
open(out, "w", encoding="utf-8", newline="").write(data.replace(old, new))
print("   MUTATE mode=%-7s 1 site：%s" % (mode, new))
sys.exit(0)
PYEOF
}

for m in dw_cut sel tap8; do
  if ! mutate "$nl" "$work/nl_$m.v" "$m"; then echo "NEGCTL-FAIL: 突变锚不唯一（$m）"; NEG_NOFIRE=$((NEG_NOFIRE+1)); fi
  "$IVERILOG" -g2012 -DUE_CGEOM -DUE_X1OBS -o "$work/mut_$m.vvp" "$tb" "$memv" "$work/nl_$m.v" > "$work/iv_$m.log" 2>&1 \
    || { echo "RESULT: FAIL 突变网表编译失败（$m）"; sed -n '1,10p' "$work/iv_$m.log"; exit 1; }
done

# -----------------------------------------------------------------------------
# 4) 跑一次 + 判官
#    run_tb <vvp> <jobdir> <tag>；dump 落 $work/<tag>.dump，日志 $work/<tag>.log
# -----------------------------------------------------------------------------
run_tb() {
  local vvp="$1" d="$2" tag="$3" mem
  eval "$(sed 's/^/X_/' "$d/job.txt" | tr '\n' ' ')"
  mem="${MEMFILE:-$work/mem_nt.hex}"
  ( cd "$work" && "$VVP" "$vvp" \
      "+XFILE=$d/x.hex" "+WFILE=$d/w.hex" "+BFILE=$d/b.hex" \
      "+MEMFILE=$mem" "+DUMPFILE=$work/$tag.dump" +dump \
      "+CIN=${X_CIN}" "+COUT=${X_COUT}" "+GROUP=${X_GROUP}" "+H=${X_H}" "+W=${X_W}" "+TYPE=3" "+FLAGS=1" \
      "+SRC=$SRC" "+DST=$DST" "+INB=$(( X_CIN * X_H * X_W ))" "+QSHIFT=6" "+LID=0" \
      "+M=${X_M}" "+ZPAD=${X_ZPAD}" "+ZY=${X_ZY}" "+NCOL=${X_NCOL}" "+NCI=${X_NCI}" "+NCO=${X_NCO}" ) \
      > "$work/$tag.log" 2>&1
}
beats_of() { sed -n 's/^X1_BEATS=\([0-9]*\).*/\1/p' "$1" | head -1; }
pass_of()  { grep -q '^RESULT: PASS' "$1" && echo 1 || echo 0; }
# judge：DST 区对黄金
judge_dst() {
  local job="$1" tag="$2"
  "$PY" - "$work" "$job" "$tag" "$DST" <<'PYEOF'
import sys
work, job, tag, dst = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
d = [int(x, 16) for x in open("%s/%s.dump" % (work, tag), encoding="utf-8").read().split()]
g = [int(x, 16) for x in open("%s/%s/gold.hex" % (work, job), encoding="utf-8").read().split()]
ln = len(g)
k = min(ln, max(0, len(d) - dst))
mm = sum(1 for i in range(k) if d[dst + i] != g[i]) + max(0, ln - k)
print("MISMATCH=%d" % mm)
PYEOF
}
mm_of() { judge_dst "$1" "$2" | sed -n 's/^MISMATCH=\([0-9]*\).*/\1/p'; }

# -----------------------------------------------------------------------------
# 5) 逐形状：正对照 + BEFORE 对照 + 两条负对照
# -----------------------------------------------------------------------------
echo "---- 5) 逐形状（C ∈ {$SHAPES}）：正对照 / BEFORE（dw_cut）/ 负对照 sel / 负对照 tap8 ----"
k=0
for C in $SHAPES; do
  d="$work/job_C$C"
  if ! "$PY" "$work/genjob.py" "$PWD_ABS/tools" "$work" "$C" "$HH" "$WW" "$((SEED0 + 37 * k))" "$d" pos > "$work/gen_C$C.out" 2>&1; then
    echo "RESULT: FAIL 供料失败（C=$C）"; tail -6 "$work/gen_C$C.out"; exit 3
  fi
  grep -E '^JOBGEN' "$work/gen_C$C.out" | sed 's/^/    /'
  eval "$(sed 's/^/X_/' "$d/job.txt" | tr '\n' ' ')"
  k=$((k+1))

  # ---- DST 预载与黄金必须足够不同（否则"不写"会被误判成对）----
  if ! "$PY" - "$work" "job_C$C" "$DST" <<'PYEOF'; then
import sys
work, job, dst = sys.argv[1], sys.argv[2], int(sys.argv[3])
g = [int(l.strip(), 16) for l in open("%s/%s/gold.hex" % (work, job), encoding="utf-8") if l.strip()]
dif = sum(1 for j, v in enumerate(g) if ((((dst + j) % 251) * 131 + 7) % 251) != v)
assert dif >= int(len(g) * 0.5), "DST 预载与黄金只差 %d/%d" % (dif, len(g))
print("   [%s] DST 预载 vs 黄金：差 %d/%d 字节（≥50%%，\"不写\"必被抓）" % (job, dif, len(g)))
PYEOF
    echo "JUDGE-RED: C=$C DST 预载与黄金过近"; TOTAL_BAD=$((TOTAL_BAD+1)); fi

  # ---- 正对照（新路径；1 拍/像素/趟）----
  run_tb "$work/sim.vvp" "$d" "pos_C$C"
  P="$(pass_of "$work/pos_C$C.log")"; B="$(beats_of "$work/pos_C$C.log")"
  MM_POS="$(mm_of "job_C$C" "pos_C$C")"
  echo "   [C=$C pos] PASS=$P MISMATCH=$MM_POS X1_BEATS=$B（预测 $X_BEATS1，= 1 拍/像素/趟；nCo=$X_NCO）"
  [ "$P" = 1 ] || { echo "JUDGE-RED: C=$C 正对照装置未 PASS"; sed -n '1,6p' "$work/pos_C$C.log"; TOTAL_BAD=$((TOTAL_BAD+1)); }
  [ "$MM_POS" = 0 ] || { echo "JUDGE-RED: C=$C 正对照 != 冻结黄金（MISMATCH=$MM_POS）"; TOTAL_BAD=$((TOTAL_BAD+1)); }
  [ "$B" = "$X_BEATS1" ] || { echo "JUDGE-RED: C=$C 实测拍数 $B != 预测 $X_BEATS1（1 拍/像素/趟）"; TOTAL_BAD=$((TOTAL_BAD+1)); }
  [ "${X_DISTINCT:-1}" -gt 1 ] 2>/dev/null || { echo "JUDGE-RED: C=$C 黄金退化 distinct=$X_DISTINCT"; TOTAL_BAD=$((TOTAL_BAD+1)); }

  # ---- BEFORE 对照（dw_mode 掐掉；9 拍/像素/趟，数值逐字节不变）----
  run_tb "$work/mut_dw_cut.vvp" "$d" "before_C$C"
  P="$(pass_of "$work/before_C$C.log")"; B9="$(beats_of "$work/before_C$C.log")"
  MM_B="$(mm_of "job_C$C" "before_C$C")"
  echo "   [C=$C before] PASS=$P MISMATCH=$MM_B X1_BEATS=$B9（预测 $X_BEATS9，= 9 拍/像素/趟）"
  [ "$P" = 1 ] || { echo "JUDGE-RED: C=$C BEFORE 未 PASS"; TOTAL_BAD=$((TOTAL_BAD+1)); }
  [ "$MM_B" = 0 ] || { echo "JUDGE-RED: C=$C BEFORE != 冻结黄金（MM=$MM_B）⇒ 跳拍不是数值透明的"; TOTAL_BAD=$((TOTAL_BAD+1)); }
  [ "$B9" = "$X_BEATS9" ] || { echo "JUDGE-RED: C=$C BEFORE 拍数 $B9 != 预测 $X_BEATS9"; TOTAL_BAD=$((TOTAL_BAD+1)); }
  # 拍比 9.00×：B9 == 9·B（两者都按预测量断言过，这里给出显式的比值判据）
  R="$(awk -v a="$B9" -v b="$B" 'BEGIN{ if (b == 0) print "NA"; else printf "%.2f", a / b }')"
  echo "   [C=$C 拍比] $B9 / $B = ${R}×（要求 9.00×）"
  [ "$R" = "9.00" ] || { echo "JUDGE-RED: C=$C 实测拍比 ${R}× != 9.00×"; TOTAL_BAD=$((TOTAL_BAD+1)); }

  # ---- 负对照①（sel：dw 档读 dense 操作数）----
  run_tb "$work/mut_sel.vvp" "$d" "neg_C$C"
  MM_N="$(mm_of "job_C$C" "neg_C$C")"
  echo "   [C=$C neg sel] MISMATCH=$MM_N（预测 $X_PRED_NEG）X1_BEATS=$(beats_of "$work/neg_C$C.log")"
  [ "$MM_N" = "$X_PRED_NEG" ] || { echo "JUDGE-RED: C=$C 负对照① 未按预测量发火（$MM_N != $X_PRED_NEG）"; TOTAL_BAD=$((TOTAL_BAD+1)); }
  [ "${MM_N:-0}" != 0 ] || { echo "NEGCTL-FAIL: C=$C 负对照① 没发火（MISMATCH=0）"; NEG_NOFIRE=$((NEG_NOFIRE+1)); }

  # ---- 负对照②（tap8：切第 9 抽头行）----
  run_tb "$work/mut_tap8.vvp" "$d" "t8_C$C"
  MM_T="$(mm_of "job_C$C" "t8_C$C")"
  echo "   [C=$C neg tap8] MISMATCH=$MM_T（预测 $X_PRED_T8）"
  [ "$MM_T" = "$X_PRED_T8" ] || { echo "JUDGE-RED: C=$C 负对照② 未按预测量发火（$MM_T != $X_PRED_T8）"; TOTAL_BAD=$((TOTAL_BAD+1)); }
  [ "${MM_T:-0}" != 0 ] || { echo "NEGCTL-FAIL: C=$C 负对照② 没发火"; NEG_NOFIRE=$((NEG_NOFIRE+1)); }
done

# -----------------------------------------------------------------------------
# 6) 外科式（同一突变、操作数恒等的作业 ⇒ 必须翻绿）+ BEFORE/pos 的整片 dump 逐字节
# -----------------------------------------------------------------------------
echo "---- 6) 外科式（C=$SURG_SHAPE，把被换 lane 的权重置 0 ⇒ 两个候选操作数恒等）----"
d="$work/job_surg"
if ! "$PY" "$work/genjob.py" "$PWD_ABS/tools" "$work" "$SURG_SHAPE" "$HH" "$WW" "$((SEED0 + 999))" "$d" surg > "$work/gen_surg.out" 2>&1; then
  echo "RESULT: FAIL 外科式供料失败"; tail -6 "$work/gen_surg.out"; exit 3
fi
grep -E '^JOBGEN' "$work/gen_surg.out" | sed 's/^/    /'
eval "$(sed 's/^/X_/' "$d/job.txt" | tr '\n' ' ')"
[ "${X_PRED_NEG:-1}" = 0 ] || { echo "NEGCTL-FAIL: 外科式预测量 != 0（$X_PRED_NEG）⇒ 两操作数没恒等"; NEG_NOFIRE=$((NEG_NOFIRE+1)); }
run_tb "$work/sim.vvp"   "$d" "surg_pos"
run_tb "$work/mut_sel.vvp" "$d" "surg_sel"
MM_SP="$(mm_of "job_surg" "surg_pos")"; MM_SS="$(mm_of "job_surg" "surg_sel")"
echo "   [surg pos] MISMATCH=$MM_SP（应 0）X1_BEATS=$(beats_of "$work/surg_pos.log")（预测 $X_BEATS1）"
echo "   [surg sel] MISMATCH=$MM_SS（应 0 = 预测量）X1_BEATS=$(beats_of "$work/surg_sel.log")"
[ "$MM_SP" = 0 ] || { echo "JUDGE-RED: 外科式作业在正网表上就不对（MM=$MM_SP）"; TOTAL_BAD=$((TOTAL_BAD+1)); }
[ "$MM_SS" = "$X_PRED_NEG" ] || { echo "JUDGE-RED: 外科式未翻绿（$MM_SS != $X_PRED_NEG）"; TOTAL_BAD=$((TOTAL_BAD+1)); }
[ "$(beats_of "$work/surg_sel.log")" = "$X_BEATS1" ] || { echo "JUDGE-RED: 外科式突变网表拍数异常"; TOTAL_BAD=$((TOTAL_BAD+1)); }

echo "---- 6b) 整片 dump 逐字节：BEFORE vs pos（每个形状）----"
for C in $SHAPES; do
  if ! "$PY" - "$work" "$C" <<'PYEOF'; then TOTAL_BAD=$((TOTAL_BAD+1)); fi
import sys
w, C = sys.argv[1], sys.argv[2]
def rd(p): return open(p, encoding="utf-8").read()
a = rd("%s/before_C%s.dump" % (w, C)); b = rd("%s/pos_C%s.dump" % (w, C))
assert a == b, "C=%s：BEFORE 与 pos 的整片内存 dump 不是逐字节相同" % C
print("   [C=%-2s] BEFORE 与 pos 的**整片内存 dump 逐字节相同**（%d 字节）" % (C, len(a)))
PYEOF
done

# -----------------------------------------------------------------------------
# 7) 收口
# -----------------------------------------------------------------------------
echo "=========================================================================="
if [ "$TOTAL_BAD" != 0 ]; then echo "RESULT: FAIL（判据红 $TOTAL_BAD 条）"; exit 1; fi
if [ "$NEG_NOFIRE" != 0 ]; then echo "RESULT: FAIL（负对照/突变没发火 $NEG_NOFIRE 条）"; exit 2; fi
echo "RESULT: PASS"
echo "  正对照：六形状 DST 逐字节 == 冻结黄金；实测 X1_BEATS == 1·nCo·H·W（1 拍/像素/趟）"
echo "  BEFORE ：同作业掐 dw_mode ⇒ X1_BEATS == 9·nCo·H·W，逐字节不变 ⇒ **实测拍比 9.00×**"
echo "  负对照 ：lane (0,2) 反向读 dense + 第 9 抽头行切除 —— 两条都按 python 预测量发火；外科式翻绿"
exit 0
