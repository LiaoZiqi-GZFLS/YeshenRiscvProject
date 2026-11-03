#!/usr/bin/env bash
# run_tiling2d_rtl_ab.sh —— ★★ T-S2R：**RTL 2-D tile 循环 + 行跨步 halo gather** 的逐字节闸门。
#
# 被测：`rtl/UnitExec.scala`（`TILING=true`）⇒ `gen/UnitExec_tiled.v`（`WIDTH=34 / IMG_H_MAX=32 / L_MAX=8`）。
#   装置 `rtl_test/UnitExecTb.v`（`+TILED`，跳过 IMG_W==imgW 的 time-0 对账）+ `rtl_test/AxiMemModel.v`。
#
# 判据（T2 的 RTL 侧；spec §5 T2）：
#   0) **正对照**：把**整层**激活喂进去（描述符 `IMG_W/IMG_H` = 整层几何），RTL 内部按
#      `W_TILE=(WIDTH-2)/s × H_TILE=IMG_H_MAX` 的 2-D tile 网格跑 ⇒ `DST` 区必须与
#      **整层黄金**（冻结 `tools/conv_unit_ref.py` 的 `build`，同一套 mac_ref 算术）**逐字节**一致。
#      覆盖：`s=1` 的 6 个**真几何**（320×320 / 160×160 / 64×32 / 80×80 / 40×40 / 20×20；
#      320/160/80/40/20 = 真表 FPN 上 dw/conv3x3 的实际 `H×W`；含**边 tile** 如 80×80 ⇒ tx=2 宽 16）
#      + `s=2` 的 1 个（`Conv_0` 式的**非对称 halo**：下/左 +1、上/右 +0；用同一套算术、`s` 只改取样相位）。
#   1) **负对照①（必发火 + 定位）**：把网表里的 **tile 网格列数** 突变 `tNtx-1 -> tNtx-2` ⇒ 最后一列
#      tile **漏跑**（"漏一趟"）⇒ `MISMATCH>0` 且**错配点 100% 落在被漏掉的那条 tile 列带**里
#      （不是随机误差、也不是整片全错 ⇒ 判据有牙且能定位到 tile/seam）。
#  1b) **负对照②（必发火 + 分类）**：把 gather 窗口突变 `tWinLo+1 / tWinHi-1`（= **不给 halo**）
#      ⇒ 错点必须**只出现在 tile 的接缝列**（错的**列数** ≤ 8）而 tile 内部全对 —— 即 T-S0
#      `tiling_ref.py`「边界环占比」口径的 RTL 版（区分"接缝类"与"相位类"）。
#   2) **前置**：`conv_unit_ref.py --selftest`（参考自身可检）。
#
# 本闸门**不做**（★ 明写的开口项）：PnR / 板级；**宽通路的 tiling**；`s>2`。
#   · ★ 装置口径：`rtl_test/UnitExecTb.v` 在 time-0 **硬判 `C_IN==C_OUT==8`** ⇒ 本闸门**只能**跑 C=8
#     （窄通路）。真表的 conv3x3/dw 全是**宽通路**（`C∈{1,3→16,4,10,16,32,64}`，见 `gen/wgt_index.json`）
#     ⇒ **宽通路的 tile 循环未交付（S2b，见 `reports/c4b_tiling_s2.md` 的开口项）**。本闸门跑的
#     C=8 是**几何/halo** 的等价夹具（halo 规则与 C 无关）。宽描述符在 tiling 网表上由 `go` 那一刻
#     **响亮 err + 零搬运**拦住（`isWide ⇒ wideGeomOk`，`IMG_W != WIDTH(34)`）⇒ 绝不静默错值。
#   · `s>2` 同理（`tilingOkC` 只放 `s∈{1,2}`）。
#
# 退出码：0 = 全过 / 1 = 判据红（正对照 MISMATCH>0 或负对照没定位）/ 2 = 负对照没发火 / 3 = 前置缺失。
set -uo pipefail

PY="${PY:-python}"
here="$(cd "$(dirname "$0")" && pwd)"
gen="$here/../gen"
tb="$here/../rtl_test/UnitExecTb.v"
memv="$here/../rtl_test/AxiMemModel.v"
nl="$gen/UnitExec_tiled.v"
ref="$here/conv_unit_ref.py"

MEMSZ=2621440
SRC=131072          # 0x20000
DST=1441792         # 0x160000
SHIFT=6

work="$(mktemp -d)"
cleanup() { [ "${KEEP_TMP:-0}" = "1" ] && echo "KEEP_TMP=1 => $work" || rm -rf "$work"; }
trap cleanup EXIT

find_tool() { local n="$1" p; p="$(command -v "$n" 2>/dev/null || true)"; [ -z "$p" ] && for d in /c/msys64/ucrt64/bin /usr/bin; do [ -x "$d/$n" ] && { p="$d/$n"; break; }; done; printf '%s' "$p"; }
IVERILOG="$(find_tool iverilog)"; VVP="$(find_tool vvp)"

echo "== run_tiling2d_rtl_ab: RTL 2-D tile 循环 + halo gather（gen/UnitExec_tiled.v）整层逐字节对账 =="
echo "   nl=$nl  tb=$tb  ref=$ref  iverilog=${IVERILOG:-<none>}"

[ -f "$nl" ] || { echo "FATAL: 缺 $nl（先 cd y1 && printf 'Test/runMain UnitExecGen ...\\nexit\\n' | bash sbt.sh）"; exit 1; }
[ -z "$IVERILOG" ] || [ -z "$VVP" ] || true
{ [ -z "$IVERILOG" ] || [ -z "$VVP" ]; } && { echo "FATAL: 缺 iverilog/vvp"; exit 1; }
[ -f "$tb" ] && [ -f "$memv" ] && [ -f "$ref" ] || { echo "FATAL: 缺装置/模型/参考"; exit 1; }

echo "---- 0) conv_unit_ref.py --selftest ----"
"$PY" "$ref" --selftest >/dev/null || { echo "RESULT: FAIL 参考自检没过"; exit 3; }
echo "   参考自检 OK"

# ---- 编译 tiled 网表 ----
if ! "$IVERILOG" -g2012 -DUE_CGEOM -o "$work/sim.vvp" "$tb" "$memv" "$nl" > "$work/iv.log" 2>&1; then
  echo "JUDGE-RED: iverilog 编译失败"; sed -n '1,30p' "$work/iv.log"; exit 1
fi
echo "   编译 OK"

cat > "$work/judge.py" <<'PYEOF'
import sys
def load_num(p):
    v=[]; 
    for l in open(p, encoding="utf-8", errors="replace"):
        s=l.strip()
        if not s: continue
        try: x=int(s,16)
        except ValueError: x=-1
        v.append(x if (0<=x<=255) else -1)
    return v
def diffs(a,b,base=0):
    c=0; first=-1
    for k in range(min(len(a),len(b))):
        if a[k]!=b[k]:
            if first<0: first=base+k
            c+=1
    return c,first
PYEOF

# run_case <tag> <W> <H> <s>
run_case() {
  local tag="$1" Wo="$2" Ho="$3" s="$4"
  local Hin=$(( Ho * s )) Win=$(( Wo * s ))
  local IN_BYTES=$(( 8 * Hin * Win ))
  echo "---- case $tag: 输出 ${Wo}x${Ho} s=$s ⇒ 输入 ${Win}x${Hin}（整层喂入，RTL 内部切 tile）----"
  if ! "$PY" - "$work" "$here" "$MEMSZ" "$SRC" "$DST" "$Wo" "$Ho" "$s" "$SHIFT" "$IN_BYTES" <<'PYEOF'
import sys, os
sys.path.insert(0, sys.argv[2]); import conv_unit_ref as R
work, refdir = sys.argv[1], sys.argv[2]
memsz, src, dst, Wo, Ho, s, SHIFT, IN_BYTES = (int(x) for x in sys.argv[3:11])
Hin, Win = Ho*s, Wo*s
# 输入 NHWC [y][x][c]（s=2 时输入是 (Ho*s)x(Wo*s)）；黄金 [y][x][co]
if s == 1:
    wt, x_chw, x_ddr, y_ddr = R.build(8, 8, Hin, Win, seed=20251014, shift=SHIFT)
else:
    # s>=2：同一套 mac_ref 算术 + requant，只把"取样相位"抽稀（输出 (y,x) 的窗口中心 = 输入 (s·y, s·x)）
    import mac_ref
    import random
    rng = random.Random(20251014)
    wt  = [rng.randint(-127,127) for _ in range(8*8*9)]
    x_chw = [rng.randint(-127,127) for _ in range(8*Hin*Win)]
    acc = [0]*(8*Ho*Wo)
    for co in range(8):
        for ci in range(8):
            for ky in range(3):
                for kx in range(3):
                    kv = wt[co*8*9 + ci*9 + ky*3 + kx]
                    if kv == 0: continue
                    for y in range(Ho):
                        iy = s*y + ky - 1
                        if iy < 0 or iy >= Hin: continue
                        for x in range(Wo):
                            ix = s*x + kx - 1
                            if ix < 0 or ix >= Win: continue
                            acc[(co*Ho + y)*Wo + x] += kv * x_chw[(ci*Hin + iy)*Win + ix]
    y_chw = [mac_ref.requant(a) for a in acc]
    x_ddr = R.permute_chw_nhwc(x_chw, 8, Hin, Win)
    y_ddr = R.permute_chw_nhwc(y_chw, 8, Ho, Wo)
assert len(x_ddr)==8*Hin*Win and len(y_ddr)==8*Ho*Wo
assert len(set(x_ddr))>1 and len(set(y_ddr))>1, "向量退化"
assert src + len(x_ddr) <= dst or dst + len(y_ddr) <= src, "src/dst 重叠"
assert max(src+len(x_ddr), dst+len(y_ddr)) <= memsz, "越界"
# 预载 = 周期 251 模式
PER=251
pre=bytes(((i%PER)*131+7)%PER for i in range(memsz))
mem=bytearray(pre); mem[src:src+len(x_ddr)] = bytes(v & 0xFF for v in x_ddr)
open(work+"/mem.hex","w").write("".join("%02x\n"%b for b in mem))
open(work+"/pre.hex","w").write("".join("%02x\n"%b for b in pre))
R.dump_bytes(work+"/wgt.hex", wt)
open(work+"/gold.hex","w").write("".join("%02x\n"%(v & 0xFF) for v in y_ddr))
# 描述符
D=[0]*8
D[0]=0x01|(0x01<<8)              # TYPE=conv3x3, FLAGS=0b01（plain，输出落 DDR）
D[1]=Wo|(Ho<<16)                 # IMG_W | IMG_H
D[2]=8|(8<<16)                   # C_IN | C_OUT
D[3]=1|(s<<8)|(1<<12)            # GROUP=1, STRIDE=s, PAD=1
D[4]=src; D[5]=dst
D[6]=IN_BYTES
D[7]=SHIFT                       # QUANT_SHIFT, LAYER_ID=0
open(work+"/desc.args","w").write(" ".join(str(x) for x in D))
print("CASE %dx%d s=%d input=%dx%d in_bytes=%d" % (Wo,Ho,s,Win,Hin,IN_BYTES))
PYEOF
  then echo "RESULT: FAIL 向量/黄金生成失败"; exit 3; fi
  read -r D0 D1 D2 D3 D4 D5 D6 D7 < "$work/desc.args"
  # 留一份（负对照要复用某个 case 的激励）
  for f in mem.hex pre.hex wgt.hex gold.hex desc.args; do cp "$work/$f" "$work/case_$tag.$f"; done
  ( cd "$work" && "$VVP" "$work/sim.vvp" "+WGTFILE=$work/wgt.hex" "+MEMFILE=$work/mem.hex" \
      "+DUMPFILE=$work/$tag.dump" +dump +TILED=1 "+D0=$D0" "+D1=$D1" "+D2=$D2" "+D3=$D3" \
      "+D4=$D4" "+D5=$D5" "+D6=$D6" "+D7=$D7" "+CTRL=1" ) > "$work/$tag.log" 2>&1
  local rc=$?
  grep -q '^RESULT: PASS' "$work/$tag.log" || { echo "RESULT: FAIL $tag 装置未 PASS (rc=$rc)"; grep -E '^(RESULT|TB-ERROR|TILED_)' "$work/$tag.log"|head; exit 1; }
  local J
  J="$("$PY" - "$work" "$tag" "$SRC" "$DST" <<'PYEOF'
import sys
sys.path.insert(0, sys.argv[1]); from judge import load_num, diffs
work, tag, src, dst = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
d=load_num(work+"/%s.dump"%tag); g=load_num(work+"/gold.hex")
p=load_num(work+"/pre.hex")           # 纯背景（dst 邻域未被写时应等于它）
mm=load_num(work+"/mem.hex")          # ★ 装置**真正装载**的镜像（背景 + src 区已叠加激活）
ln=len(g)
m,first=diffs(d[dst:dst+ln], g, 0)
# ★ SRC 区不变：必须与**装载镜像** mm 比（不是纯背景 p —— 激活本来就在 src 区，拿 p 比永远红）
sb,_=diffs(d[src:src+ln], mm[src:src+ln])
nb=sum(1 for j in range(32) if d[dst-32+j]!=p[dst-32+j])+sum(1 for j in range(32) if d[dst+ln+j]!=p[dst+ln+j])
print("MISMATCH=%d FIRST_OFF=%d SRC_UNCHANGED_BAD=%d NEIGHBOR_BAD=%d"%(m, dst+first if first>=0 else -1, sb, nb))
PYEOF
)"
  echo "   $J"
  echo "$J" > "$work/$tag.judge"
  local mm; mm="$(printf '%s\n' "$J" | sed -n 's/^MISMATCH=\([0-9]*\).*/\1/p')"
  local sb; sb="$(printf '%s\n' "$J" | sed -n 's/.*SRC_UNCHANGED_BAD=\([0-9]*\).*/\1/p')"
  local nb; nb="$(printf '%s\n' "$J" | sed -n 's/.*NEIGHBOR_BAD=\([0-9]*\).*/\1/p')"
  if [ "$mm" != "0" ] || [ "$sb" != "0" ] || [ "$nb" != "0" ]; then
    echo "RESULT: FAIL $tag 正对照 MISMATCH=$mm SRC_BAD=$sb NB_BAD=$nb"; exit 1
  fi
  echo "   OK: $tag DST == 整层黄金（MISMATCH=0）"
}

# ★ 真表 halo 层的真实**几何**（`H×W`）：320 / 160 / 80 / 40 / 20 就是 FPN 上那几个档
#   （`gen/wgt_index.json`：`Conv_3` 320、`Conv_7` 160、`Conv_55` 80、`Conv_57` 40、`Conv_59` 20）。
#   ★★ 口径诚实项（必读）：本闸门的装置 `rtl_test/UnitExecTb.v` **在 time-0 硬判 `C_IN==C_OUT==8`**
#     （`$fatal`，见 TB）⇒ 这里跑的 C=8 是**窄通路**。真表这些层的 `C∈{1,4,16,64}` 走**宽通路**
#     （有单独的 `UnitExecWideTb`），**宽通路的 tiling 未交付（S2b）** —— 见尾注 + 报告开口项。
run_case s1_320x320 320 320 1
run_case s1_160x160 160 160 1
run_case s1_64x32  64 32 1
run_case s1_80x80  80 80 1
run_case s1_40x40  40 40 1
run_case s1_20x20  20 20 1
run_case s2_32x32  32 32 2

# ---------------- 负对照：漏一趟（tile 网格列数 -1 ⇒ 最后一列 tile 不跑） ----------------
echo "---- 负对照：网表突变 tNtx-1 -> tNtx-2（漏最后一列 tile）⇒ MISMATCH>0 且定位在漏掉的 tile 列带 ----"
if ! "$PY" - "$nl" "$work/nl_mut.v" <<'PYEOF'
import sys
src=open(sys.argv[1],encoding="utf-8").read()
old="(tNtx - 16'h0001)"; new="(tNtx - 16'h0002)"
n=src.count(old)
print("MUTGEN_HITS=%d (期望 >=1)"%n)
if n<1: sys.exit(2)
open(sys.argv[2],"w",encoding="utf-8").write(src.replace(old,new))
PYEOF
then echo "RESULT: FAIL 无法构造漏趟突变网表"; exit 2; fi
"$IVERILOG" -g2012 -DUE_CGEOM -o "$work/sim_mut.vvp" "$tb" "$memv" "$work/nl_mut.v" > "$work/ivm.log" 2>&1 || { echo "RESULT: FAIL 突变网表编译失败"; exit 2; }
# 复用 case s1_64x32 的激励（该 case 的 mem/wgt/gold/descs 已在运行时留档）
for f in mem.hex pre.hex wgt.hex gold.hex; do cp "$work/case_s1_64x32.$f" "$work/$f"; done
read -r D0 D1 D2 D3 D4 D5 D6 D7 < "$work/case_s1_64x32.desc.args"
( cd "$work" && "$VVP" "$work/sim_mut.vvp" "+WGTFILE=$work/wgt.hex" "+MEMFILE=$work/mem.hex" \
    "+DUMPFILE=$work/mut.dump" +dump +TILED=1 "+D0=$D0" "+D1=$D1" "+D2=$D2" "+D3=$D3" \
    "+D4=$D4" "+D5=$D5" "+D6=$D6" "+D7=$D7" "+CTRL=1" ) > "$work/mut.log" 2>&1
grep -q '^RESULT: PASS' "$work/mut.log" || { echo "RESULT: FAIL 突变网表装置未收工（漏 tile 也让 FSM 坏了）"; grep -E '^(RESULT|TILED_)' "$work/mut.log"|head; exit 2; }
MUT="$("$PY" - "$work" "$SRC" "$DST" <<'PYEOF'
import sys
sys.path.insert(0, sys.argv[1]); from judge import load_num, diffs
work, src, dst = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
d=load_num(work+"/mut.dump"); g=load_num(work+"/gold.hex")
ln=len(g)
m,first=diffs(d[dst:dst+ln], g, 0)
# 定位：错配的**全局列**是否都 >= 32*8（= 被漏掉的 tx=1 列带）
badx=set()
for k in range(ln):
    if d[dst+k]!=g[k]:
        pix=k//8; x=pix%64; badx.add(x)
minx = min(badx) if badx else -1
maxx = max(badx) if badx else -1
print("MUT_MISMATCH=%d FIRST_OFF=%d XMIN=%d XMAX=%d"%(m, dst+first if first>=0 else -1, minx, maxx))
PYEOF
)"
echo "   $MUT"
MM="$(printf '%s\n' "$MUT" | sed -n 's/^MUT_MISMATCH=\([0-9]*\).*/\1/p')"
XMIN="$(printf '%s\n' "$MUT" | sed -n 's/.*XMIN=\([0-9-]*\).*/\1/p')"
if [ "${MM:-0}" -le 0 ] 2>/dev/null; then echo "RESULT: FAIL 漏趟负对照没发火（MISMATCH=0）"; exit 2; fi
if [ "${XMIN:-99}" -lt 32 ] 2>/dev/null; then echo "RESULT: FAIL 漏趟错配没定位到被漏的 tile 列带（XMIN=$XMIN < 32）"; exit 2; fi
echo "   NEG_OK: 漏一趟 ⇒ MISMATCH=$MM（>0），错配点 XMIN=$XMIN ≥ 32 ⇒ 落在被漏掉的 tx=1 tile 列带"

# ---------------- 负对照②：**不给 halo**（窗口左右各内缩 1 列 ⇒ 只有 tile 接缝列错） ----------------
#   与"漏一趟"（整条 tile 列带全错）**互补**：本档把 gather 的窗口 `[WinLo,WinHi)` 左右各内缩 1 列
#   （= 丢 halo）⇒ 每个 tile 的**第一条与最后一条输出列**退化成 pad ⇒ **只有接缝错、tile 内部全对**。
#   判据要**区分"接缝类"与"相位类"**：错的**列数**必须很少（≤ 8 列）且落在 tile 边界上
#   —— 这就是冻结件 `tools/tiling_ref.py`「边界环占比」口径的 RTL 版（T-S0 §3.2）。
echo "---- 负对照②：不给 halo（tWinLo+1 / tWinHi-1）⇒ 错点只在 tile 接缝列（内部全对）----"
if ! "$PY" - "$nl" "$work/nl_nohalo.v" <<'PYEOF'
import sys
src=open(sys.argv[1],encoding="utf-8").read()
o1="assign tWinLo = (($signed(tFx) < $signed(26'h0)) ? 24'h0 : _zz_tWinLo);"
n1="assign tWinLo = (($signed(tFx) < $signed(26'h0)) ? 24'h1 : (_zz_tWinLo + 24'h1));"
o2="? 24'h0 : _zz_tWinHi_2));"
n2="? 24'h0 : (_zz_tWinHi_2 - 24'h1)));"
a=src.count(o1); b=src.count(o2)
print("NOHALO_MUTGEN_HITS=%d,%d (期望 1,1)"%(a,b))
if a<1 or b<1: sys.exit(2)
open(sys.argv[2],"w",encoding="utf-8").write(src.replace(o1,n1).replace(o2,n2))
PYEOF
then echo "RESULT: FAIL 无法构造 no-halo 突变网表"; exit 2; fi
"$IVERILOG" -g2012 -DUE_CGEOM -o "$work/sim_nh.vvp" "$tb" "$memv" "$work/nl_nohalo.v" > "$work/ivnh.log" 2>&1 || { echo "RESULT: FAIL no-halo 突变网表编译失败"; exit 2; }
for f in mem.hex pre.hex wgt.hex gold.hex; do cp "$work/case_s1_64x32.$f" "$work/$f"; done
read -r D0 D1 D2 D3 D4 D5 D6 D7 < "$work/case_s1_64x32.desc.args"
( cd "$work" && "$VVP" "$work/sim_nh.vvp" "+WGTFILE=$work/wgt.hex" "+MEMFILE=$work/mem.hex" \
    "+DUMPFILE=$work/nh.dump" +dump +TILED=1 "+D0=$D0" "+D1=$D1" "+D2=$D2" "+D3=$D3" \
    "+D4=$D4" "+D5=$D5" "+D6=$D6" "+D7=$D7" "+CTRL=1" ) > "$work/nh.log" 2>&1
grep -q '^RESULT: PASS' "$work/nh.log" || { echo "RESULT: FAIL no-halo 突变网表装置未收工"; grep -E '^(RESULT|TILED_)' "$work/nh.log"|head; exit 2; }
NH="$("$PY" - "$work" "$DST" <<'PYEOF'
import sys
sys.path.insert(0, sys.argv[1]); from judge import load_num, diffs
work, dst = sys.argv[1], int(sys.argv[2])
d=load_num(work+"/nh.dump"); g=load_num(work+"/gold.hex")
ln=len(g); W=64; C=8
m,_=diffs(d[dst:dst+ln], g, 0)
badx=set()
for k in range(ln):
    if d[dst+k]!=g[k]: badx.add((k // C) % W)
print("NH_MISMATCH=%d NBAD_X=%d XMIN=%d XMAX=%d XSORT=%s"%(m, len(badx),
      min(badx) if badx else -1, max(badx) if badx else -1, sorted(badx)[:12]))
PYEOF
)"
echo "   $NH"
NHM="$(printf '%s\n' "$NH" | sed -n 's/^NH_MISMATCH=\([0-9]*\).*/\1/p')"
NHX="$(printf '%s\n' "$NH" | sed -n 's/.*NBAD_X=\([0-9]*\).*/\1/p')"
if [ "${NHM:-0}" -le 0 ] 2>/dev/null; then echo "RESULT: FAIL no-halo 负对照没发火（MISMATCH=0）"; exit 2; fi
if [ "${NHX:-99}" -gt 8 ] 2>/dev/null; then echo "RESULT: FAIL no-halo 错点不是接缝类（错列数=$NHX > 8 ⇒ 像相位/整块错）"; exit 2; fi
echo "   NEG2_OK: 不给 halo ⇒ MISMATCH=$NHM（>0），错**列**仅 $NHX 列（⇒ 接缝类，tile 内部全对）"

echo "=========================================================================="
echo "[1] 正对照 s=1 真几何 320x320/160x160/64x32/80x80/40x40/20x20 + s=2 32x32 整层逐字节 : PASS（MISMATCH=0）"
echo "[2] 负对照① 漏一趟（tNtx-1->tNtx-2）        : PASS（MISMATCH=$MM>0，定位在漏掉的 tile 列带 XMIN=$XMIN）"
echo "[3] 负对照② 不给 halo（tWinLo+1/tWinHi-1）   : PASS（MISMATCH=$NHM>0，错列仅 $NHX 列 ⇒ 接缝类）"
echo "[!] 开口项（S2b）：宽通路（真表 C∈{1,4,16,64}）的 tiling **未交付** —— 见闸门头注与报告"
echo "RESULT: PASS"
exit 0
