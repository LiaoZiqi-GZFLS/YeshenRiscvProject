#!/usr/bin/env bash
# run_x1skip_ab.sh —— ★★ NPU v2 §4.6-5（**切片 A**）：**1×1 只发 1 个 tap-beat**（"跳拍"读法①）的闸门。
#
# 被测：`rtl/Conv3x3Slice.scala` 的 `X1SKIP` 块（`one_x1=1 ∧ ph==1 ⇒ ph:=10`）+ `rtl/MultiPassUnit.scala`
#   的转发口 + `rtl/UnitExec.scala` 的 `x1W`（描述符 TYPE=0x02 在 `go` 那拍锁存）与 `x1_beats` 观测口。
#   网表 = `gen/UnitExec_tiled.v`（`TILING=true` = 真帧网表那一档；`TILING=false` 的三份冻结网表**没有**
#   这条通路 —— 那一侧的"逐字节不变"由 md5 前置项 + 全部既有闸门保住，不在本闸门的判据里）。
#   装置 = `rtl_test/UnitExecWideTb.v`（**`-DUE_X1OBS`**：只有本闸门接 `x1_beats` 这个口）+ `AxiMemModel.v`。
#
# 判据（"先立靶、再发火、再外科"三件套；全部按**预测量**断言，不看"像不像"）：
#   0) 前置：冻结参考自检；`TILING=false` 三网表 md5 逐字节不变；**真 blob 前提现场重扫**
#      （26 个真 1×1 单元的全部非零权重字节都在槽 0；且真表**没有** 8→8 的 1×1 ⇒ 窄通路不需要本改动的接线）；
#   1) 正对照（**同一作业、同一权重 blob**，只换描述符 TYPE）：
#        · `+TYPE=1`（3×3 ⇒ 9 拍/像素/趟）= as-built 左上窗口；`+TYPE=2`（1×1 ⇒ 1 拍/像素/趟，**居中**）= 修后行为；
#        · 两条都必须 `RESULT: PASS`，`TYPE=2` 的 DST == **居中**黄金、`TYPE=1` 的 DST == **左上**黄金
#          （都用冻结 `tiling_ref.conv_tiled` 算，并与 `quant_ref.conv_vec` 二实现交叉对账）；
#          两份整片 dump 的差异字节数**恰等于**两份黄金的差异字节数（= 修复的唯一数值差）；
#        · `X1_BEATS`（实测发出拍）：TYPE=1 == `9·P·H·W`、TYPE=2 == `1·P·H·W`（**9.00×**）；
#          非 tiled 与 tiled（`+TILED_W`，`wxPixTot` 口径）两档都跑 —— 前者绝对值按 P0b 的
#          `beats_issued = taps·passes·H·W` 断言，后者按 `taps·passes·(tTh+1)·tOutPerRow` 断言；
#   2) 负对照（**必发火 + 按预测量定位**）：把 1×1 权重 blob 的**一个非中心抽头**（DUT 槽 5）置 7
#      ⇒ 跳拍（TYPE=2，只把槽 0 采在窗口**中心**）必须 `MISMATCH == 预测值`
#      （预测 = `#(gold_full ≠ gold_centeronly)`，python 现算）；同一 blob 用 TYPE=1（9 抽头）
#      ⇒ `MISMATCH == 0`（证明负对照的"红"是**跳拍**造成的，不是注入本身坏了）；
#   3) 外科式（**只把一个字节移到中心，红↔绿翻面**）：同一个值 `7`、同一个 `(co,ci)`，叠加到**中心抽头**
#      （DUT 槽 0）⇒ 同一读法（TYPE=2）必须**从红翻绿**（`MISMATCH == 0`）—— 证明负对照真的盯着
#      "哪些抽头被采样"，而"槽 0 的字节必须被吃到"（该 job 的黄金 ≠ base 黄金，逐字节证）。
#   ★ S4-C 参考口径（2026-10-17）：1×1 = **居中**。冻结的 `tiling_ref.conv_tiled` 不动，改**调用点**：
#      参考核 `wref` 把抽头放在 (ky,kx)=(1,1) 且 pads=[1,1,1,1]（≡ 真 1×1 核 + pad=0，脚本内互证），
#      DUT 的 blob `wdut` 仍把抽头放在**槽 0**（真表布局；修后的 RTL 把槽 0 采在中心）。
#   4) 网表突变（**外科锚**，两条，都是"把新逻辑拆掉"而不是"改夹具"）：
#        · 突变①：`when_Conv3x3Slice_l*`（跳拍条件）⇒ `1'b0` ⇒ P2 作业的 `X1_BEATS` 必须**回到 9×**
#          且输出仍 == **居中**黄金（= 多发的 8 个零权重拍数值上什么都不干）；
#        · 突变②：`_zz_one_x1 <= (desc_0[7:0] == 8'h02)` ⇒ `1'b0`（TYPE 译码掐掉）⇒ 同样 9× + 逐字节不变
#          （= "1×1 的真源是描述符 TYPE"这条口径的可判证据）。
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
ref="tools/tiling_ref.py"
mpref="tools/multipass_ref.py"
qref="tools/quant_ref.py"
MEMSZ=2621440
SRC=131072            # 0x20000：tiled 档的激活平面（NCHW）落点
DST=2097152           # 0x200000：输出区
tools_abs="$(pwd)/tools"

# ---- 作业几何（16→16 / 8×8 ⇒ nCi=nCo=2 ⇒ P=4 趟；非 tiled 每趟 64 像素、tiled 每趟 90 像素）----
CIN=16; COUT=16; HH=8; WW=8; SEED=20261016
PASSES=4
NT_PIX=$(( HH * WW ))                 # 非 tiled：每趟出 H*W 个像素
TI_PIX=$(( (HH + 1) * (WW + 2) ))     # tiled：每趟出 (tTh+1)*tOutPerRow 个像素（tNCol=tW+2）
NT_B9=$(( 9 * PASSES * NT_PIX ));  NT_B1=$(( PASSES * NT_PIX ))
TI_B9=$(( 9 * PASSES * TI_PIX ));  TI_B1=$(( PASSES * TI_PIX ))

find_tool() {
  local n="$1" p d
  p="$(command -v "$n" 2>/dev/null || true)"
  if [ -z "$p" ]; then for d in /c/msys64/ucrt64/bin /mingw64/bin /usr/bin; do [ -x "$d/$n" ] && { p="$d/$n"; break; }; done; fi
  printf '%s' "$p"
}
IVERILOG="$(find_tool iverilog)"; VVP="$(find_tool vvp)"

echo "== run_x1skip_ab: NPU v2 §4.6-5 切片 A（1×1 只发 1 个 tap-beat；跳拍读法①）=="
echo "   nl=$nl  py=$PY  iverilog=${IVERILOG:-<none>}"
echo "   预测拍数：非 tiled  TYPE=1: $NT_B9  TYPE=2: $NT_B1  |  tiled  TYPE=1: $TI_B9  TYPE=2: $TI_B1"

for f in "$nl" "$tb" "$memv" "$ref" "$mpref" "$qref"; do
  [ -f "$f" ] || { echo "FATAL: 缺 $f"; echo "RESULT: FAIL"; exit 3; }
done
[ -n "$IVERILOG" ] && [ -n "$VVP" ] || { echo "FATAL: 缺 iverilog/vvp"; echo "RESULT: FAIL"; exit 3; }

work="$(mktemp -d)"
cleanup() { [ "${KEEP_TMP:-0}" = "1" ] && echo "KEEP_TMP=1 => $work" || rm -rf "$work"; }
trap cleanup EXIT
export PYTHONPATH="./.pydeps;../third_party/yunet/deps"
export PYTHONIOENCODING=utf-8

TOTAL_BAD=0; NEG_NOFIRE=0

# -----------------------------------------------------------------------------
# 0) 前置：参考自检 + TILING=false 三网表 md5 + 真 blob 的 1×1 槽 0 前提
# -----------------------------------------------------------------------------
echo "---- 0) 前置：参考自检 + TILING=false 三网表 md5 + 真 blob 前提重扫 ----"
"$PY" "$ref" --selftest2d >/dev/null 2>&1 || { echo "RESULT: FAIL 参考自检没过"; exit 3; }
echo "   参考自检 OK（tiling_ref.py --selftest2d）"

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

if ! "$PY" - "$tools_abs" <<'PYEOF'; then
import sys, os, json, hashlib
sys.path.insert(0, sys.argv[1])
idx_p = os.path.join(sys.argv[1], "..", "gen", "wgt_index.json")
blob_p = os.path.join(sys.argv[1], "..", "gen", "wgt_blob.bin")
d = json.load(open(idx_p, encoding="utf-8"))
blob = open(blob_p, "rb").read()
md5 = hashlib.md5(blob).hexdigest()
bad = []
if md5 != d["blob"]["md5"]: bad.append("blob md5=%s != index 记录 %s" % (md5, d["blob"]["md5"]))
if len(blob) != d["blob"]["bytes"]: bad.append("blob 字节数 != index")
x1 = [u for u in d["units"] if u.get("weight") is not None and int(u.get("type_code", 0)) == 2]
nz_all = 0
for u in x1:
    w = u["weight"]; off = int(w["offset"]); nb = int(w["nbytes"])
    seg = blob[off:off + nb]
    nz = [i for i, b in enumerate(seg) if b]
    nz_all += len(nz)
    if any(i % 9 != 0 for i in nz): bad.append("%s：有非零字节不在槽 0" % u["name"])
narrow = [u["name"] for u in x1
          if int(u["own"]["C_IN"]) == 8 and int(u["own"]["C_OUT"]) == 8 and int(u["own"]["GROUP"]) == 1]
if len(x1) != 26: bad.append("真表 1×1 单元 %d != 26" % len(x1))
if nz_all != 42697: bad.append("1×1 非零字节 %d != 42697" % nz_all)
if narrow: bad.append("真表出现了 8→8 的 1×1（窄通路也要接线）：%s" % narrow)
print("   真 blob：%d 个 1×1 单元、%d 个非零字节**全在槽 0**；无 8→8 的 1×1（窄通路不参与）" % (len(x1), nz_all))
for b in bad: print("   JUDGE-RED: " + b)
sys.exit(1 if bad else 0)
PYEOF
  echo "RESULT: FAIL 真 blob 前提扫查不过（见上）"; exit 3
fi

# -----------------------------------------------------------------------------
# 1) iverilog 编译（tiled 网表；-DUE_CGEOM 逐片几何口 + -DUE_X1OBS 跳拍观测量）
# -----------------------------------------------------------------------------
echo "---- 1) iverilog 编译（UnitExecWideTb + AxiMemModel + gen/UnitExec_tiled.v；-DUE_CGEOM -DUE_X1OBS）----"
if ! "$IVERILOG" -g2012 -DUE_CGEOM -DUE_X1OBS -o "$work/sim.vvp" "$tb" "$memv" "$nl" > "$work/iv.log" 2>&1; then
  echo "JUDGE-RED: iverilog 编译失败"; sed -n '1,30p' "$work/iv.log"; echo "RESULT: FAIL"; exit 1
fi
echo "   编译 OK"

# -----------------------------------------------------------------------------
# 2) 作业生成器（复用冻结参考的算术：tiling_ref.conv_tiled + quant_ref.conv_vec 两条互证）
#    变体：base = 真 blob 布局（槽 0 单抽头、居中采样）；neg = 多一个非零字节在**槽 5**（非中心）；
#          surg = 同一字节叠加到**中心抽头**（唯一差别 = 它是否落在被采样的抽头上）。
#    ★ S4-C：参考核 `wref` 的抽头在 (1,1)（居中）；DUT blob `wdut` 的抽头在槽 0（真表布局）。
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
    seed = int(sys.argv[8]); variant = sys.argv[9]
    src, dst, memsz = int(sys.argv[10]), int(sys.argv[11]), int(sys.argv[12])

    rng = np.random.default_rng(seed)
    xq = rng.integers(-20, 21, size=(1, cin, H, W), dtype=np.int64)
    w0 = rng.integers(-20, 21, size=(cout, cin, 3, 3), dtype=np.int64)
    sx = sw = sy = 0.05
    bfloat = rng.uniform(-0.5, 0.5, size=cout)
    biasb = np.round(bfloat / (sx * sw)).astype(np.int64)

    # ---- 权重变体（★ S4-C 参考口径修正：1×1 = **居中**采样）----
    #   同一组 1×1 权重有两个坐标表达：
    #     · `wref`（**参考**）：抽头落在 3×3 的**中心** (ky,kx)=(1,1)，pads=[1,1,1,1]
    #       ⇒ `conv_tiled`/`conv_vec` 算出的就是 ONNX 的居中 1×1（与 `quant_ref` 真口径一致）；
    #     · `wdut`（**装进 DUT 的 9 槽 blob**）：抽头落在**槽 0**（真 blob 的布局，26 个真 1×1
    #       单元的非零字节全在槽 0）—— 修后的 RTL 在 one_x1 时把槽 0 采在窗口**中心**。
    #   变体只动**一个非中心抽头**（DUT 槽 5 / ref (1,2)）：跳拍时看不到它，3×3 时看得到。
    wref = np.zeros((cout, cin, 3, 3), dtype=np.int64)
    wdut = np.zeros((cout, cin, 3, 3), dtype=np.int64)
    wref[:, :, 1, 1] = w0[:, :, 0, 0]
    wdut[:, :, 0, 0] = w0[:, :, 0, 0]
    inj = 0
    if variant == "neg":
        wref[0, 0, 1, 2] = 7; wdut[0, 0, 1, 2] = 7; inj = 7   # 非中心抽头（DUT 槽 5）
    elif variant == "surg":
        wref[0, 0, 1, 1] = w0[0, 0, 0, 0] + 7                  # 同一个值搬到**中心**（叠加）
        wdut[0, 0, 0, 0] = w0[0, 0, 0, 0] + 7; inj = 7
    elif variant != "base":
        raise SystemExit("unknown variant %r" % variant)
    wd = {"q": wref.astype(np.int8), "scale": sw, "zp": 0}
    wdd = {"q": wdut.astype(np.int8), "scale": sw, "zp": 0}
    pads, strides = [1, 1, 1, 1], [1, 1]

    # ---- 参考①（TYPE=2 ⇒ **居中** 1×1）：只留中心抽头（负对照的注入抽头被跳拍忽略）----
    wc = np.zeros_like(wref); wc[:, :, 1, 1] = wref[:, :, 1, 1]
    tiled_c, _, _, M = T.conv_tiled(xq, {"q": wc.astype(np.int8), "scale": sw, "zp": 0},
                                    sx, sy, 0, 0, bfloat, pads, strides, 1, Z_Y, dump_passes=True)
    whole_c = Q.conv_vec(xq, {"q": wc.astype(np.int8), "scale": sw, "zp": 0},
                         sx, sy, 0, 0, bfloat, pads, strides, 1, Z_Y)
    assert np.array_equal(whole_c, tiled_c), "两条独立参考不一致（居中口径）"
    gold = tiled_c.reshape(-1).astype(np.int8)
    # ---- 参考②（TYPE=1 ⇒ 9 抽头 as-built：**DUT 的槽 0 blob 原样**按 3x3 窗口采 = 左上口径）----
    tiled_s, _, _, M2 = T.conv_tiled(xq, wdd, sx, sy, 0, 0, bfloat, pads, strides, 1, Z_Y, dump_passes=True)
    whole_s = Q.conv_vec(xq, wdd, sx, sy, 0, 0, bfloat, pads, strides, 1, Z_Y)
    assert np.array_equal(whole_s, tiled_s), "两条独立参考不一致（3x3 口径）"
    assert int(M2) == int(M)
    goldshift = tiled_s.reshape(-1).astype(np.int8)
    pred_mm = int(np.count_nonzero(goldshift != gold))
    d_gold0 = pred_mm
    # 居中 1×1 的第二实现（真 1×1 核、pad=0）：必须与参考①逐字节相同
    gold11 = Q.conv_vec(xq, {"q": np.ascontiguousarray(wref[:, :, 1, 1]).reshape(cout, cin, 1, 1),
                             "scale": sw, "zp": 0}, sx, sy, 0, 0, bfloat,
                        [0, 0, 0, 0], [1, 1], 1, Z_Y).reshape(-1).astype(np.int8)
    assert np.array_equal(gold11, gold), "居中 1x1（真 1x1 核）与本作业黄金不一致"

    n_ci, n_co = T.n_passes(cin), T.n_passes(cout)
    assert n_ci * 8 == cin and n_co * 8 == cout, "本作业只用整块几何"

    # ---- x.hex：wide_x 列流（趟序 co-block 外、ci-block 内；每列 8 通道）----
    xstream = np.concatenate([xq[0, i * 8:(i + 1) * 8].transpose(1, 2, 0).reshape(-1)
                              for _ in range(n_co) for i in range(n_ci)])
    # ---- 权重瓦片（趟序；与 DUT 的 wRam 趟基址同序）+ bias ----
    tiles = MP.weight_tiles(xq, wdd, 1)
    btoks = []
    for j in range(n_co):
        btoks += [int(v) for v in MP.bias_of(biasb, j)]
    xin = np.ascontiguousarray(xq[0]).reshape(-1).astype(np.int8)   # NCHW 平面（tiled 档从 DDR 取）

    d = os.path.join(work, name); os.makedirs(d, exist_ok=True)
    dump(os.path.join(d, "x.hex"), xstream)
    dump(os.path.join(d, "xin.hex"), xin)
    dump(os.path.join(d, "w.hex"), np.concatenate([t.reshape(-1) for t in tiles]))
    dump(os.path.join(d, "b.hex"), btoks, w=8)
    dump(os.path.join(d, "gold.hex"), gold)          # TYPE=2 期望（居中）
    dump(os.path.join(d, "goldshift.hex"), goldshift)  # TYPE=1 期望（as-built 左上）

    # ---- 两份内存镜像：非 tiled（激活来自列流，SRC 不动）/ tiled（激活落 SRC 平面）----
    pre = np.array([((i % 251) * 131 + 7) % 251 for i in range(memsz)], dtype=np.int64)
    dif = int(np.count_nonzero(pre[dst:dst + len(gold)] != gold))
    assert dif >= int(len(gold) * 0.9), "DST 预载与黄金过近（不写必被误判成对）"
    dump(os.path.join(d, "mem_nt.hex"), pre)
    mem_t = pre.copy(); mem_t[src:src + len(xin)] = xin
    dump(os.path.join(d, "mem_t.hex"), mem_t)
    with open(os.path.join(d, "job.txt"), "w", encoding="ascii", newline="\n") as f:
        f.write("CIN=%d\nCOUT=%d\nGROUP=1\nH=%d\nW=%d\n" % (cin, cout, H, W))
        f.write("SRC=%d\nDST=%d\nM=%d\nZPAD=0\nZY=%d\nNCI=%d\nNCO=%d\n" % (src, dst, int(M), Z_Y, n_ci, n_co))
        f.write("NCOL=%d\nLEN=%d\nPRED_MM=%d\nD_GOLD0=%d\n" % (len(xstream) // 8, len(gold), pred_mm, d_gold0))
    print("JOBGEN %s variant=%s inj=%d n_ci=%d n_co=%d M=%d len=%d pred_mm=%d d_gold0=%d"
          % (name, variant, inj, n_ci, n_co, int(M), len(gold), pred_mm, d_gold0))

main()
PYEOF

# -----------------------------------------------------------------------------
# 3) 跑一次（run_tb <vvp> <job> <TYPE> <nt|tiled>）；dump 落 $work/<job>.<mode>.t<TYPE>.dump
# -----------------------------------------------------------------------------
run_tb() {
  local vvp="$1" name="$2" tpe="$3" mode="$4"
  local d="$work/$name" mem kind
  eval "$(sed 's/^/X_/' "$d/job.txt" | tr '\n' ' ')"
  if [ "$mode" = "tiled" ]; then mem="$d/mem_t.hex"; kind="+TILED_W"
  else mem="$d/mem_nt.hex"; kind=""; fi
  ( cd "$work" && "$VVP" "$vvp" \
      "+XFILE=$d/x.hex" "+WFILE=$d/w.hex" "+BFILE=$d/b.hex" \
      "+MEMFILE=$mem" "+DUMPFILE=$work/$name.$mode.t$tpe.dump" +dump $kind \
      "+CIN=${X_CIN}" "+COUT=${X_COUT}" "+GROUP=${X_GROUP}" "+H=${X_H}" "+W=${X_W}" \
      "+TYPE=${tpe}" "+FLAGS=1" "+SRC=${X_SRC}" "+DST=${X_DST}" "+INB=${X_LEN}" \
      "+QSHIFT=6" "+LID=0" "+M=${X_M}" "+ZPAD=${X_ZPAD}" "+ZY=${X_ZY}" \
      "+NCOL=${X_NCOL}" "+NCI=${X_NCI}" "+NCO=${X_NCO}" ) > "$work/$name.$mode.t$tpe.log" 2>&1
}

beats_of() { sed -n 's/^X1_BEATS=\([0-9]*\).*/\1/p' "$1" | head -1; }
pass_of()  { grep -q '^RESULT: PASS' "$1" && echo 1 || echo 0; }
cyc_of()   { sed -n 's/^CYCLES=\([0-9]*\).*/\1/p' "$1" | head -1; }

# judge：DST 区对黄金（tag = <job>.<mode>.t<TYPE>）
judge_dst() {  # judge_dst <job> <mode> <TYPE> [goldfile]  (goldfile 缺省 gold.hex)
  local job="$1" mode="$2" tpe="$3" gf="${4:-gold.hex}" d="$work/$1" ln dst
  ln="$(sed -n 's/^LEN=//p' "$d/job.txt")"
  dst="$(sed -n 's/^DST=//p' "$d/job.txt")"
  "$PY" - "$work" "$job" "$mode" "$tpe" "$dst" "$ln" "$gf" <<'PYEOF'
import sys
work, job, mode, tpe, dst, ln, gf = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], int(sys.argv[5]), int(sys.argv[6]), sys.argv[7]
d = [int(x, 16) for x in open("%s/%s.%s.t%s.dump" % (work, job, mode, tpe), encoding="utf-8").read().split()]
g = [int(x, 16) for x in open("%s/%s/%s" % (work, job, gf), encoding="utf-8").read().split()]
k = min(ln, len(g), max(0, len(d) - dst))
mm = sum(1 for i in range(k) if d[dst + i] != g[i]) + max(0, ln - k)
print("MISMATCH=%d" % mm)
PYEOF
}

# -----------------------------------------------------------------------------
# 4) 作业 + 正对照（同一作业只换 TYPE）
# -----------------------------------------------------------------------------
for v in base neg surg; do
  "$PY" "$work/genjob.py" "$tools_abs" "$work" "x1_$v" "$CIN" "$COUT" "$HH" "$WW" "$SEED" "$v" "$SRC" "$DST" "$MEMSZ" \
    > "$work/x1_$v.gen" 2>&1 || { echo "RESULT: FAIL 供料失败（$v）"; tail -8 "$work/x1_$v.gen"; exit 3; }
  grep -E '^JOBGEN' "$work/x1_$v.gen" | sed 's/^/    /'
done

echo "---- 4) 正对照：base 作业（槽 0 单抽头），TYPE=2 对**居中**黄金 / TYPE=1 对**左上**黄金 ----"
PRED_BASE="$(sed -n 's/^PRED_MM=//p' "$work/x1_base/job.txt")"
echo "   预测：TYPE=2 期望 gold.hex（居中）0 字节；TYPE=1 期望 goldshift.hex（左上）0 字节；两份黄金差 $PRED_BASE 字节"
for spec in "nt 1" "nt 2" "tiled 1" "tiled 2"; do
  mode="${spec%% *}"; tpe="${spec##* }"
  run_tb "$work/sim.vvp" x1_base "$tpe" "$mode"
  lg="$work/x1_base.$mode.t$tpe.log"
  P="$(pass_of "$lg")"; B="$(beats_of "$lg")"
  GOLD=gold.hex; [ "$tpe" = 1 ] && GOLD=goldshift.hex
  MM="$(judge_dst x1_base "$mode" "$tpe" "$GOLD" | sed -n 's/^MISMATCH=\([0-9]*\).*/\1/p')"
  if [ "$mode" = "nt" ]; then EXP_B=$NT_B9; [ "$tpe" = 2 ] && EXP_B=$NT_B1
  else EXP_B=$TI_B9; [ "$tpe" = 2 ] && EXP_B=$TI_B1; fi
  echo "   [$mode TYPE=$tpe] PASS=$P MISMATCH=$MM（$GOLD）X1_BEATS=$B（预测 $EXP_B） CYCLES=$(cyc_of "$lg")"
  [ "$P" = 1 ] || { echo "JUDGE-RED: $mode TYPE=$tpe 装置未 PASS"; sed -n '1,6p' "$lg"; TOTAL_BAD=$((TOTAL_BAD+1)); }
  [ "$MM" = 0 ] || { echo "JUDGE-RED: $mode TYPE=$tpe DST != $GOLD（MISMATCH=$MM）"; TOTAL_BAD=$((TOTAL_BAD+1)); }
  [ "$B" = "$EXP_B" ] || { echo "JUDGE-RED: $mode TYPE=$tpe X1_BEATS=$B != 预测 $EXP_B"; TOTAL_BAD=$((TOTAL_BAD+1)); }
done

# 两份 dump 的**差异字节数**恰等于两份黄金的差异字节数（S4-C 修复的唯一数值差 = 1×1 的 (-1,-1) 位移）
if ! "$PY" - "$work" "$PRED_BASE" <<'PYEOF'
import sys
w = sys.argv[1]; pred = int(sys.argv[2])
def rd(p): return [int(x, 16) for x in open(p, encoding="utf-8").read().split()]
for mode in ("nt", "tiled"):
    a = rd("%s/x1_base.%s.t1.dump" % (w, mode)); b = rd("%s/x1_base.%s.t2.dump" % (w, mode))
    nd = sum(1 for i in range(len(a)) if a[i] != b[i])
    assert nd == pred, "%s：TYPE=1 与 TYPE=2 的 dump 差 %d 字节 != 黄金差 %d" % (mode, nd, pred)
print("   DIFF-EXACT：TYPE=1 与 TYPE=2 的整片 dump 恰差 %d 字节 == #(居中 vs 左上)（非 tiled 与 tiled 两档；修复的唯一数值差）" % pred)
PYEOF
then TOTAL_BAD=$((TOTAL_BAD+1)); fi
echo "   RATIO：非 tiled 实测 $NT_B9 -> $NT_B1（= 9.00×）；tiled 实测 $TI_B9 -> $TI_B1（= 9.00×）"

# -----------------------------------------------------------------------------
# 5) 负对照 + 外科式
# -----------------------------------------------------------------------------
echo "---- 5) 负对照（槽 5 有非零字节，跳拍必发火且按预测量）+ 外科式（同字节搬到中心，必翻绿）----"
PRED="$(sed -n 's/^PRED_MM=//p' "$work/x1_neg/job.txt")"
DG0="$(sed -n 's/^D_GOLD0=//p' "$work/x1_neg/job.txt")"
echo "   预测量：PRED_MM=$PRED（gold_full ≠ gold_centeronly 的字节数）；D_GOLD0=$DG0"
if [ "${PRED:-0}" = 0 ] || [ "${DG0:-0}" = 0 ]; then
  echo "NEGCTL-FAIL: 注入的字节没有改变黄金 ⇒ 负对照没牙"; NEG_NOFIRE=$((NEG_NOFIRE+1))
fi

run_tb "$work/sim.vvp" x1_neg 2 nt
LGN="$work/x1_neg.nt.t2.log"; MM="$(judge_dst x1_neg nt 2 goldshift.hex | sed -n 's/^MISMATCH=\([0-9]*\).*/\1/p')"
echo "   [N1 neg TYPE=2 跳拍] MISMATCH=$MM（预测 $PRED）X1_BEATS=$(beats_of "$LGN")"
[ "$MM" = "$PRED" ] || { echo "JUDGE-RED: 负对照① 未按预测量发火（MM=$MM != $PRED）"; TOTAL_BAD=$((TOTAL_BAD+1)); }
[ "${MM:-0}" != 0 ] || { echo "NEGCTL-FAIL: 负对照① 没发火（MISMATCH=0）"; NEG_NOFIRE=$((NEG_NOFIRE+1)); }

run_tb "$work/sim.vvp" x1_neg 1 nt
LGN1="$work/x1_neg.nt.t1.log"; MM1="$(judge_dst x1_neg nt 1 goldshift.hex | sed -n 's/^MISMATCH=\([0-9]*\).*/\1/p')"
echo "   [N1' neg TYPE=1 跳拍关] MISMATCH=$MM1（应 0）X1_BEATS=$(beats_of "$LGN1")（应 $NT_B9）"
[ "$MM1" = 0 ] || { echo "JUDGE-RED: 同一 blob 在跳拍关掉时也不对（MM=$MM1）⇒ 红不是跳拍造成的"; TOTAL_BAD=$((TOTAL_BAD+1)); }

run_tb "$work/sim.vvp" x1_surg 2 nt
LGS="$work/x1_surg.nt.t2.log"; MMS="$(judge_dst x1_surg nt 2 | sed -n 's/^MISMATCH=\([0-9]*\).*/\1/p')"
echo "   [N2 surg TYPE=2 同字节搬到中心] MISMATCH=$MMS（应 0；该 job 的黄金与 base 不同 ⇒ 中心样本真被吃到）"
[ "$MMS" = 0 ] || { echo "JUDGE-RED: 外科式未翻绿（MM=$MMS）"; TOTAL_BAD=$((TOTAL_BAD+1)); }
# 外科式的"中心样本真被吃到"证据：surg 与 base 的**黄金**不同（搬过来的那个字节改变了输出），
# 且两份**DUT dump** 的差异字节数**恰等于**黄金差异字节数（改动只落在该字节的贡献上）。
if ! "$PY" - "$work" <<'PYEOF'
import sys
w = sys.argv[1]
def rd(p): return [int(x, 16) for x in open(p, encoding="utf-8").read().split()]
gb = rd("%s/x1_base/gold.hex" % w); gs = rd("%s/x1_surg/gold.hex" % w)
db = rd("%s/x1_base.nt.t2.dump" % w); ds = rd("%s/x1_surg.nt.t2.dump" % w)
n_g = sum(1 for i in range(len(gb)) if gb[i] != gs[i])
n_d = sum(1 for i in range(len(db)) if db[i] != ds[i])
assert n_g > 0, "搬到中心的字节没有改变黄金 ⇒ 外科式不成立（跳拍口径下它也没被吃到？）"
assert n_d == n_g, "DUT 输出差异 %d != 黄金差异 %d（外科式不干净）" % (n_d, n_g)
print("   SURG：中心字节改变黄金 %d 字节，DUT 两份 dump 同样差 %d 字节（中心样本真被吃到、且只差在这些字节）" % (n_g, n_d))
PYEOF
then NEG_NOFIRE=$((NEG_NOFIRE+1)); fi

# -----------------------------------------------------------------------------
# 6) 网表突变（外科锚 ×2）：拆掉新逻辑 ⇒ 拍数回到 9×、数值逐字节不变
# -----------------------------------------------------------------------------
echo "---- 6) 网表突变（外科锚）：拆跳拍条件 ⇒ 9×/仍居中；拆 TYPE 译码 ⇒ 9×/回到左上（修复前行为）----"
mutate() {  # mutate <in> <out> <skip|type>
  "$PY" - "$1" "$2" "$3" <<'PYEOF'
import sys
src, out, mode = sys.argv[1], sys.argv[2], sys.argv[3]
# ★ 逐字节保真：网表带中文注释（UTF-8）与 CRLF ⇒ 二进制读、utf-8 解码、newline="" 写回
data = open(src, "rb").read().decode("utf-8")
lines = data.split("\n")
hit = 0
for i, l in enumerate(lines):
    if mode == "skip" and ("when_Conv3x3Slice_l" in l) and ("assign" in l) and ("inPix && one_x1" in l):
        name = l.split("=")[0].strip().replace("assign ", "")
        lines[i] = "  assign %s = 1'b0;   // X1SKIP-MUT (skip condition cut)" % name
        hit += 1
    if mode == "type" and ("_zz_one_x1 <=" in l) and ("desc_0[7 : 0]" in l):
        lines[i] = "      _zz_one_x1 <= 1'b0;   // X1SKIP-MUT (TYPE decode cut)"
        hit += 1
if hit != 1:
    print("MUTATE-FAIL mode=%s hits=%d (anchor not unique)" % (mode, hit)); sys.exit(1)
with open(out, "w", encoding="utf-8", newline="") as f:
    f.write("\n".join(lines))
print("   MUTATE mode=%s: 1 site (anchor unique)" % mode)
PYEOF
}

for m in skip type; do
  if ! mutate "$nl" "$work/nl_mut_$m.v" "$m"; then
    echo "NEGCTL-FAIL: 突变锚不唯一（$m）"; NEG_NOFIRE=$((NEG_NOFIRE+1)); continue
  fi
  "$IVERILOG" -g2012 -DUE_CGEOM -DUE_X1OBS -o "$work/mut_$m.vvp" "$tb" "$memv" "$work/nl_mut_$m.v" > "$work/iv_mut_$m.log" 2>&1 \
    || { echo "RESULT: FAIL 突变网表编译失败（$m）"; sed -n '1,10p' "$work/iv_mut_$m.log"; exit 1; }
  run_tb "$work/mut_$m.vvp" x1_base 2 nt
  LM="$work/x1_base.nt.t2.log"; B="$(beats_of "$LM")"; P="$(pass_of "$LM")"
  # 拆"跳拍条件" ⇒ 拍数回 9×、数值仍是**居中**（零权重抽头不贡献）；
  # 拆"TYPE 译码" ⇒ 拍数回 9×、数值回到**左上**（= 修复前的 as-built 行为）。
  GOLD=gold.hex; [ "$m" = type ] && GOLD=goldshift.hex
  MM="$(judge_dst x1_base nt 2 "$GOLD" | sed -n 's/^MISMATCH=\([0-9]*\).*/\1/p')"
  echo "   [M-$m TYPE=2] PASS=$P MISMATCH=$MM（$GOLD）X1_BEATS=$B（预测回到 $NT_B9）"
  [ "$MM" = 0 ] && [ "$P" = 1 ] || { echo "JUDGE-RED: 突变 $m 的输出 != $GOLD（MM=$MM）"; TOTAL_BAD=$((TOTAL_BAD+1)); }
  [ "$B" = "$NT_B9" ] || { echo "NEGCTL-FAIL: 突变 $m 没有把拍数拉回 $NT_B9（实测 $B）⇒ 跳拍没被拆掉"; NEG_NOFIRE=$((NEG_NOFIRE+1)); }
done

# -----------------------------------------------------------------------------
# 7) 收口
# -----------------------------------------------------------------------------
echo "=========================================================================="
if [ "$TOTAL_BAD" != 0 ]; then echo "RESULT: FAIL（判据红 $TOTAL_BAD 条）"; exit 1; fi
if [ "$NEG_NOFIRE" != 0 ]; then echo "RESULT: FAIL（负对照/突变没发火 $NEG_NOFIRE 条）"; exit 2; fi
echo "RESULT: PASS"
echo "  正对照：非 tiled TYPE=1 $NT_B9 拍 / TYPE=2 $NT_B1 拍（9.00×）；tiled TYPE=1 $TI_B9 拍 / TYPE=2 $TI_B1 拍（9.00×）"
echo "  负对照 + 外科式 + 2 条突变全部按预测量发火/翻面"
exit 0
