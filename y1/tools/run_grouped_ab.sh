#!/usr/bin/env bash
# run_grouped_ab.sh —— 分组 / 深度卷积包装器（rtl/GroupedMacArray.scala）的装置级数值闸门。
#
# 七项职责（与 tools/run_macarray_ab.sh 同风格，但要抓住"分组"这个新能力）：
#   1) 造向量：四个 group 配置共用**同一份 X 文件**、**同一批权重数字**；X 一拍给全 8 个输入通道
#      （阵列现在吃真瓦片，一个 (ky,kx) 一拍就算完，不再需要逐 ci 串行）；
#      W 是**权重瓦片**（每拍 64 字节 [k][co][ci]）：与 co 同组的槽放真权重，组外槽塞 0x7f 毒值
#      ⇒ 掩码若被架空，Y 立刻错（这条毒值是"逐 entry 掩码"的装置级证据之一）；
#   2) 用 Python **独立**算期望：dense 循环遍历 co 与全部 ci；grouped 循环遍历 co、但只累加本组通道；
#      depthwise 另给一条**独立**的解析式 Σ_pos x(co,pos)·W(co,0,pos)（不复用 grouped 参考）；
#   3) 跑 TB（iverilog + $readmemh + 一行 "Y ..." + RESULT: PASS/FAIL），逐字节对账，
#      每个配置打印一行 case=group=N MISMATCH=<不等字节数>；
#   4) 负对照①（本任务的核心）：**dense 落位突变体**。同一份 X、同一批权重数字，只把
#      "逐 entry 掩码" 换成 GROUP=1（gen/GroupedMacArray.v 那份 dense 网表 + 不加掩码的整张瓦片），
#      对每个 GROUP>1 配置，MISMATCH 必须**非 0**；同时要求突变体的 Y == dense 参考
#      ⇒ 突变体是一台**工作正常**的 dense 卷积，差异来自"分组 vs 不分组"而不是"跑挂了"。
#      若某个 GROUP>1 下两者竟然一致，说明分组逻辑被架空（闸门退化成"重测阵列"）⇒ 退出 2。
#   5) 负对照②（depthwise 不变性，GROUP=8）：把所有**别的**输入通道都扰动一遍，p(co) 必须一动不动；
#      同一份扰动喂给 dense 网表时 p(co) 必须**会动** ⇒ 证明这条不变性是"分组"给的，不是向量凑巧
#      （装置级 LHS 有牙控制）。扰动若对谁都不可见（或 X 根本没变）⇒ 判据空转 ⇒ 退出 2。
#   6) 结构性判据①：gen/*.v 里内嵌的 `module MacArray` 必须与 gen/MacArray.v 的 `module MacArray`
#      **逐字节相同** ⇒ "阵列结构一个字没改"有据可查（不是靠嘴说）。
#   7) 结构性判据②（新）：每个 group 网表里内嵌 MacArray 的 64 个 w 端口，**哪些接 w_tile、
#      哪些接常数 0**，必须与 participates(co, ci) 的映射**逐 entry 完全一致**
#      ⇒ 掩码是"逐 entry 落位"，不是"漏了/多算了几个 entry"（这条比数值对账更早、更狠）。
#
# 退出码：
#   0 = 通过（四个 group 逐字节全中 + 两发负对照都抓住 + 阵列同体 + 掩码逐 entry 正确）
#   1 = 对账不符 / 编译或仿真失败 / 装置没打印 Y / 装置自检未 PASS / 阵列被改动 / 掩码错位
#   2 = 负对照（或 depthwise 不变性检查）没抓住 ⇒ 闸门自身不可信
#   3 = 向量自检失败（用例写错：非 int8、参考溢出、向量无区分度、毒值缺失）
#
# 装置契约（B4 沿用）：rtl_test/GroupedMacArrayTb.v + gen/GroupedMacArray*.v
#   +XFILE=<file> 每行一个 hex 字节，beat-major [k][ci]，每拍 8 字节（一拍一个 (ky,kx)，全通道）
#   +WFILE=<file> 每行一个 hex 字节，beat-major [k][co][ci]，每拍 64 字节（权重瓦片，逐 entry 掩码）
#   +YFILE=<file> 每行一个 hex 字节，期望 int32 小端字节 [co][byte] ⇒ 32 字节
#   +K=<n>        beat 数（一层 3x3 = 9 拍）；+GROUP=<n> 仅用于日志/自检
set -uo pipefail

PY="${PY:-python}"
here="$(cd "$(dirname "$0")" && pwd)"
gen="${GEN_DIR:-$here/../gen}"
tb="$here/../rtl_test/GroupedMacArrayTb.v"

NCI=8
NCO=8
NPOS=9
K=$NPOS             # 9 拍：一拍一个 (ky,kx) 位置（真瓦片下不再需要逐 ci 串行）
KEEP=3              # depthwise 不变性检查里"不被扰动"的那个通道（**必须与下面 python 块的 KEEP 一致**）

work="$(mktemp -d)"
cleanup() {
  if [ "${KEEP_TMP:-0}" = "1" ]; then
    echo "KEEP_TMP=1 => vectors/logs kept in $work"
  else
    rm -rf "$work"
  fi
}
trap cleanup EXIT

echo "== run_grouped_ab: grouped / depthwise conv wrapper (GROUP in {1,2,4,8}), per-entry tile mask =="
echo "   gen=$gen"
echo "   tb =$tb"
echo "   tmp=$work"

# ---------------- 1) 造向量 + 算期望 ----------------
# 用例全是**闭式确定性**的（不用随机数），输入与权重都取小值（±5 量级）但不全正也不全负
# ⇒ 日志可读，且符号路径被压到。期望值全部现算，绝不手抄。
"$PY" - "$work" <<'PYEOF'
import os, sys, hashlib
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

OUT = sys.argv[1]
NCI = NCO = 8
NPOS = 9                # 3x3
GROUPS = [1, 2, 4, 8]
KEEP = 3
NTILE = NCI * NCO       # 权重瓦片端口容量 = 64（每拍 64 字节）
POISON = 0x7f           # 组外（被掩掉）的瓦片槽塞毒值，证明掩码真的接在回路上

def M(co, ci, pos):     # 主权重张量 [co][ci][pos]，小值、有正有负
    return ((co * 7 + ci * 5 + pos * 3) % 9) - 4

def XV(pos, ci):        # 输入 [pos][ci]，小值、有正有负；**刻意避开 0**（每一拍都要有激励）
    v = ((pos * 5 + ci * 3) % 11) - 5
    return v if v != 0 else 7

def XVp(pos, ci):       # 扰动版：除 KEEP 外**全部取反**
    # 为什么取反而不是"加一个常数"：加常数 d 对某个通道带来的变化是 d·Σ_pos W(co,0,pos)，
    # 那个和完全可能恰好为 0（本用例第一版就踩了这个坑：co=1/4/7 的 Y 一动不动）。
    # 取反则扰动后的 p(ci) 恰好 = -p(ci) ⇒ 只要原值非 0 就**必然**看得见（下面有断言把住）。
    return -XV(pos, ci) if ci != KEEP else XV(pos, ci)

# ---- 组映射（与 rtl/GroupMask.scala 逐字一致；这里是**参考侧**的独立实现）----
def gOut(co, g): return (co * g) // NCO
def gIn(ci, g):  return (ci * g) // NCI
def participates(co, ci, g): return gOut(co, g) == gIn(ci, g)
def ciLocal(ci, g): return ci - gIn(ci, g) * (NCI // g)

def hx(v):
    assert -128 <= v <= 127, "not int8: %d" % v
    return "%02x" % (v & 0xff)

def by(v):              # int32 的原始字节（0..255），不做 int8 检查
    return "%02x" % (v & 0xff)

def le32(v):
    return [(v >> (8 * i)) & 0xff for i in range(4)]

# ---- 期望：grouped（dense 遍历 co，co 只累加本组通道） ----
def ref_grouped(g, xf):
    Y = [0] * NCO
    for co in range(NCO):
        for ci in range(NCI):
            if not participates(co, ci, g):
                continue
            j = ciLocal(ci, g)           # 组内序号
            for pos in range(NPOS):
                Y[co] += xf(pos, ci) * M(co, j, pos)
    return Y

# ---- 期望：dense（每个 co 看到全部 ci；这是 GROUP=1 落位突变体该给出的结果） ----
def ref_dense(xf):
    return [sum(xf(pos, ci) * M(co, ci, pos)
                for ci in range(NCI) for pos in range(NPOS)) for co in range(NCO)]

# ---- 期望：depthwise 的**独立**解析式 p(co) = Σ_pos x(co,pos)·W(co,0,pos) ----
def ref_dw(xf):
    return [sum(xf(pos, co) * M(co, 0, pos) for pos in range(NPOS)) for co in range(NCO)]

INT32_MIN, INT32_MAX = -(1 << 31), (1 << 31) - 1

def write_x(path, xf):
    """beat-major [pos][ci] 的**稠密**输入：每拍 8 个通道全给（一拍一个 (ky,kx)）。"""
    lines = []
    for pos in range(NPOS):
        for c in range(NCI):
            lines.append(hx(xf(pos, c)))
    with open(path, "w", encoding="ascii", newline="\n") as f:
        f.write("".join(t + "\n" for t in lines))
    return lines

def write_y(sub, Y, name):
    """写一份 Y（装置自检用的 $readmemh 小端字节 + 本脚本对账用的 "Y ..." 行）。"""
    assert all(INT32_MIN <= y <= INT32_MAX for y in Y), "%s: reference overflows int32" % name
    d = os.path.join(OUT, sub)
    os.makedirs(d, exist_ok=True)
    yb = [b for co in range(NCO) for b in le32(Y[co])]
    with open(os.path.join(d, "y.hex"), "w", encoding="ascii", newline="\n") as f:
        f.write("".join(by(v) + "\n" for v in yb))
    with open(os.path.join(d, "exp.txt"), "w", encoding="ascii", newline="\n") as f:
        f.write("Y " + " ".join(by(v) for v in yb) + "\n")
    return yb

def write_bundle(sub, g, yfun):
    """写一份 W（+Y/exp）。每拍 64 字节的瓦片：participates(co,ci) ⇒ M(co,ci_local,pos)，
    否则塞毒值 0x7f（掩码架空就会立刻错）。"""
    d = os.path.join(OUT, sub)
    os.makedirs(d, exist_ok=True)
    wl = []
    nlive = ndead = 0
    for pos in range(NPOS):
        for co in range(NCO):
            for ci in range(NCI):
                if participates(co, ci, g):
                    wl.append(hx(M(co, ciLocal(ci, g), pos)))
                    nlive += 1
                else:
                    wl.append(hx(POISON))
                    ndead += 1
    assert len(wl) == NPOS * NTILE, "W file must be %d bytes per beat" % NTILE
    with open(os.path.join(d, "w.hex"), "w", encoding="ascii", newline="\n") as f:
        f.write("".join(t + "\n" for t in wl))
    Y = yfun()
    write_y(sub, Y, sub)
    return Y, nlive, ndead

# ---- X（四个 group 共用）与 X_pert ----
x_lines = write_x(os.path.join(OUT, "x.hex"), XV)
xp_lines = write_x(os.path.join(OUT, "x_pert.hex"), XVp)
os.makedirs(os.path.join(OUT, "pert"), exist_ok=True)

# 向量自检①：每拍 8 个通道**全非 0**（真瓦片下一拍算完一个 (ky,kx)：每条 x 通路都要被激励，
#             否则"某条通道没接上"会被漏检）
for k in range(0, len(x_lines), NCI):
    beat = x_lines[k:k + NCI]
    nz = sum(1 for t in beat if t != "00")
    assert nz == NCI, "beat %d is not dense (nonzero count=%d, want %d)" % (k // NCI, nz, NCI)
# 向量自检②：扰动确实改到了东西
xdiff = sum(1 for a, b in zip(x_lines, xp_lines) if a != b)
assert xdiff > 0, "X_pert == X => perturbation is a no-op"
print("   向量自检: X 每拍 %d 个通道全非 0（%d 拍）；X vs X_pert 有 %d 个字节不同（扰动非空转）"
      % (NCI, len(x_lines) // NCI, xdiff))

dense_ref = ref_dense(XV)
print("   dense 参考(每个 co 看全部 ci): " + " ".join("%d" % v for v in dense_ref))

for g in GROUPS:
    Y, nlive, ndead = write_bundle("g%d" % g, g, lambda g=g: ref_grouped(g, XV))
    print("   group=%d PER_GROUP=%d 瓦片/拍=%d 字节（真权重 %d entry/拍 + 组外毒值 %d entry/拍）期望 Y=%s"
          % (g, NCI // g, NTILE, nlive // NPOS, ndead // NPOS, " ".join("%d" % v for v in Y)))
    if g == 1:
        assert ndead == 0 and nlive == NPOS * NTILE, "group=1 必须 64 entry/拍 全参与（无掩码）"
        assert Y == dense_ref, "group=1 expectation must equal the dense expectation"
    else:
        want_live = NPOS * NCO * (NCI // g)
        assert nlive == want_live and ndead == NPOS * NTILE - want_live, \
            "group=%d: 参与 entry 数必须 = NPOS*C_OUT*PER_GROUP" % g
        # 向量自检③：GROUP>1 的期望必须与 dense 期望不同（否则这组向量压根区分不了分组/不分组）
        d = sum(1 for a, b in zip(Y, dense_ref) if a != b)
        assert d > 0, "group=%d expectation == dense expectation => vectors cannot tell them apart" % g
        print("             与 dense 期望不同的通道数=%d/8（保证负对照有东西可抓）" % d)

# dense 突变体的 W（整张瓦片无掩码，= group=1 的瓦片）与期望
write_bundle("dense", 1, lambda: ref_dense(XV))
assert open(os.path.join(OUT, "g1", "exp.txt"), encoding="utf-8").read() == \
       open(os.path.join(OUT, "dense", "exp.txt"), encoding="utf-8").read(), \
       "group=1 expectation must be byte-identical to the dense expectation"

# depthwise 两条独立期望（原始 X 与扰动 X）
dwY = ref_dw(XV)
dwYp = ref_dw(XVp)
assert dwY == ref_grouped(8, XV), "dw analytic form must match the grouped(=8) reference"
write_y("dw", dwY, "dw")
write_y("pert/dw", dwYp, "dw-perturbed")
denseYp = ref_dense(XVp)
write_y("pert/dense", denseYp, "dense-perturbed")

# 向量自检④：扰动必须"有牙"（否则后面那些"必须不变 / 必须变"的判据是空转的）
for co in range(NCO):
    if co == KEEP:
        assert dwYp[co] == dwY[co], "dw: kept channel %d must be unchanged" % co
    else:
        assert dwY[co] != 0, "dw: channel %d expectation is 0 => sign-flip invisible" % co
        assert dwYp[co] == -dwY[co] and dwYp[co] != dwY[co], \
            "dw: perturbed channel %d must move (got %d -> %d)" % (co, dwY[co], dwYp[co])
assert denseYp[KEEP] != dense_ref[KEEP], \
    "dense: kept channel must move under the same perturbation => vectors lack teeth"

print("   depthwise 解析式 p(co)=Σ_pos x(co,pos)·W(co,0,pos): " + " ".join("%d" % v for v in dwY))
print("     扰动 X 后该解析式应为(除 co=%d 外全变): %s" % (KEEP, " ".join("%d" % v for v in dwYp)))
print("   X 文件 md5: %s（四个 group 共用同一份）"
      % hashlib.md5(open(os.path.join(OUT, "x.hex"), "rb").read()).hexdigest())
PYEOF
if [ $? -ne 0 ]; then
  echo "FATAL: 向量/期望构造或自检失败"; exit 3
fi

# ---------------- 2) 编译 + 仿真 ----------------
iv="$(command -v iverilog 2>/dev/null || true)"
echo "   iverilog: ${iv:-<not on PATH>}"
[ -n "$iv" ] && echo "   version : $(iverilog -V 2>&1 | head -1)"
if [ -z "$iv" ]; then echo "JUDGE-RED: 找不到 iverilog，无法仿真"; exit 1; fi

dut_file() { # group=N ⇒ 对应的网表文件名（与 GroupedMacArrayGen.scala 的 fileNameOf 一一对应）
  if [ "$1" = "1" ]; then echo "$gen/GroupedMacArray.v"; else echo "$gen/GroupedMacArray_g$1.v"; fi
}
for f in "$(dut_file 1)" "$(dut_file 2)" "$(dut_file 4)" "$(dut_file 8)"; do
  if [ ! -f "$f" ]; then
    echo "JUDGE-RED: 网表不存在：$f"
    echo "  先跑：printf 'Test/runMain GroupedMacArrayGen <abs gen 目录>\\nexit\\n' | bash sbt.sh"
    exit 1
  fi
done

SIM_BAD=0
DUT_VVP=""
compile_dut() { # 同一份网表只编一次（按文件名缓存）
  local dut="$1" tag
  tag="$(basename "$dut" .v)"
  DUT_VVP="$work/$tag.vvp"
  [ -f "$DUT_VVP" ] && return 0
  if ! iverilog -g2012 -o "$DUT_VVP" "$tb" "$dut" > "$work/iv_$tag.log" 2>&1; then
    echo "JUDGE-RED: iverilog 编译失败：$dut"; sed -n '1,30p' "$work/iv_$tag.log"; return 1
  fi
  return 0
}
run_tb() { # <name> <dut.v> <x.hex> <w.hex> <y.hex> <K> <GROUP>
  local name="$1" dut="$2" xf="$3" wf="$4" yf="$5" kk="$6" gg="$7"
  compile_dut "$dut" || { SIM_BAD=1; return 1; }
  local out="$work/$name.out" rc=0
  ( cd "$work" && vvp "$DUT_VVP" \
      +XFILE="$xf" +WFILE="$wf" +YFILE="$yf" +K="$kk" +GROUP="$gg" ) > "$out" 2>&1 || rc=$?
  grep '^Y ' "$out" > "$work/$name.y" || true
  if [ ! -s "$work/$name.y" ]; then
    echo "JUDGE-RED: $name 装置没有打印 Y 行（vvp rc=$rc）"; sed -n '1,20p' "$out"; SIM_BAD=1; return 1
  fi
  if [ "$rc" -ne 0 ] || ! grep -q '^RESULT: PASS' "$out"; then
    echo "JUDGE-RED: $name 装置自检未 PASS（vvp rc=$rc）"; grep '^RESULT:' "$out" || true; SIM_BAD=1; return 1
  fi
  echo "   run=$name dut=$(basename "$dut") vvp_rc=$rc RESULT=PASS"
  return 0
}

# 逐字节对账：cnt_y <期望文件> <实际文件> ⇒ 两个 Y 行之间不等的**字节**个数（-1 = 任一侧缺 Y 行）
cnt_y() {
  "$PY" - "$1" "$2" <<'PYEOF'
import sys
def load(p):
    try:
        f = open(p, encoding="utf-8", errors="replace")
    except OSError:
        return None
    for ln in f:
        if ln.startswith("Y "):
            return ln.split()[1:]
    return None
a, b = load(sys.argv[1]), load(sys.argv[2])
if a is None or b is None:
    print(-1)
elif len(a) != len(b):
    print(max(len(a), len(b)))
else:
    print(sum(1 for i, j in zip(a, b) if i != j))
PYEOF
}
# ---- 四个 group 的正例 ----
for g in 1 2 4 8; do
  run_tb "g$g" "$(dut_file $g)" "$work/x.hex" "$work/g$g/w.hex" "$work/g$g/y.hex" "$K" "$g" || true
done
# ---- dense 落位突变体（同一份 X + 整张瓦片无掩码）----
run_tb "dense" "$(dut_file 1)" "$work/x.hex" "$work/dense/w.hex" "$work/dense/y.hex" "$K" 1 || true
# ---- depthwise 独立解析式 + 扰动不变性 ----
run_tb "dw" "$(dut_file 8)" "$work/x.hex" "$work/g8/w.hex" "$work/dw/y.hex" "$K" 8 || true
run_tb "dwp" "$(dut_file 8)" "$work/x_pert.hex" "$work/g8/w.hex" "$work/pert/dw/y.hex" "$K" 8 || true
run_tb "densep" "$(dut_file 1)" "$work/x_pert.hex" "$work/dense/w.hex" "$work/pert/dense/y.hex" "$K" 1 || true

# ---- 每个 group 的逐字节对账 ----
total_mis=0
grouped_mis=""
for g in 1 2 4 8; do
  if [ -s "$work/g$g.y" ]; then
    mis="$(cnt_y "$work/g$g/exp.txt" "$work/g$g.y")"
  else
    mis="-1"
  fi
  grouped_mis="$grouped_mis $g:$mis"
  echo "   case=group=$g MISMATCH=$mis"
  if [ "$mis" != "0" ]; then
    if [ -s "$work/g$g.y" ]; then
      echo "     --- diff (expected < / actual >), one token per line ---"
      diff <(tr ' ' '\n' < "$work/g$g/exp.txt") <(tr ' ' '\n' < "$work/g$g.y") | head -20
    fi
    [ "$mis" -gt 0 ] 2>/dev/null && total_mis=$((total_mis + mis))
    SIM_BAD=1
  fi
done
echo "MISMATCH=$total_mis"

# ---------------- 3) 负对照①：dense 落位突变体必须被抓住 ----------------
neg_ok=1
mut_self="$(cnt_y "$work/dense/exp.txt" "$work/dense.y")"
echo "NEGCTL-A: dense 突变体自身 vs dense 参考 = $mut_self 字节不符（期望 0 ⇒ 突变体是台好用的 dense 卷积）"
if [ "$mut_self" != "0" ]; then
  echo "NEGCTL-FAIL: dense 突变体连 dense 参考都对不上 ⇒ 这一发不可信（差异不是来自分组/不分组）"
  neg_ok=0
fi
mut_lines=""
for g in 2 4 8; do
  m="$(cnt_y "$work/g$g/exp.txt" "$work/dense.y")"
  mut_lines="$mut_lines g$g:$m"
  if ! [ "$m" -gt 0 ] 2>/dev/null; then
    echo "NEGCTL-FAIL: group=$g 下 dense 落位的结果与 grouped 参考**完全一致**（$m 字节不符）"
    echo "             ⇒ 分组逻辑被架空（闸门只是在重测阵列）⇒ 判据无效"
    neg_ok=0
  fi
done
echo "NEGCTL-A: dense-placement vs grouped-ref 的字节不符数:$mut_lines（每个 GROUP>1 都必须 >0）"

# ---------------- 4) 负对照②：depthwise 不变性（含"有牙"控制）----------------
dw_val="$(cnt_y "$work/dw/exp.txt" "$work/dw.y")"
echo "NEGCTL-B: depthwise 独立解析式的字节不符数 = $dw_val（期望 0）"
if [ "$dw_val" != "0" ]; then
  echo "NEGCTL-FAIL: GROUP=8 的 Y 对不上 Σ_pos x(co,pos)·W(co,0,pos) ⇒ 不是 depthwise"; neg_ok=0
fi

# 取 co 的 4 个字节（lane = 4*co），比较两组 run
# lane <Y 行文件> <co> ⇒ 取该 co 的 4 个字节（一个大端显示的 8 位十六进制串）
lane() { "$PY" - "$1" "$2" <<'PYEOF'
import sys
co = int(sys.argv[2])
toks = None
for ln in open(sys.argv[1], encoding="utf-8", errors="replace"):
    if ln.startswith("Y "):
        toks = ln.split()[1:]
        break
print("".join(toks[4*co:4*co+4]) if toks else "????")
PYEOF
}
same_lanes=1
for co in 0 1 2 3 4 5 6 7; do
  a="$(lane "$work/dw.y" $co)"; b="$(lane "$work/dwp.y" $co)"
  if [ "$co" = "$KEEP" ]; then
    echo "   dw-invariance: co=$KEEP (自己的通道未扰动) 原始=$a 扰动后=$b  -> 必须相同"
    [ "$a" = "$b" ] || { echo "NEGCTL-FAIL: co=$KEEP 在别的通道被扰动后变了 ⇒ 不是 depthwise"; neg_ok=0; }
  else
    if [ "$a" = "$b" ]; then
      echo "NEGCTL-FAIL: co=$co 的输入通道被扰动，Y 却没动（$a）⇒ 扰动对谁都不可见，判据空转"
      same_lanes=0
    fi
  fi
done
if [ "$same_lanes" = "1" ]; then
  echo "   dw-invariance-teeth: co!=3 的 7 个通道的 Y 都随扰动而变（扰动真的有牙）"
else
  neg_ok=0
fi
# 同一份扰动喂 dense 网表：co=KEEP 必须**会动**（否则说明不变性不是分组给的）
if [ -s "$work/densep.y" ]; then
  d0="$(lane "$work/dense.y" $KEEP)"; d1="$(lane "$work/densep.y" $KEEP)"
  echo "NEGCTL-B: 同一份扰动喂 dense 网表: co=$KEEP 原始=$d0 扰动后=$d1 -> 必须不同"
  if [ "$d0" = "$d1" ]; then
    echo "NEGCTL-FAIL: dense 网表下 co=$KEEP 也不受扰动影响 ⇒ 不变性不是分组给的，判据无区分度"
    neg_ok=0
  fi
else
  echo "NEGCTL-FAIL: dense 扰动那发没跑出来"; neg_ok=0
fi

if [ "$neg_ok" = 1 ]; then echo "NEGCTL-OK"; else echo "NEGCTL-FAIL: 至少一发没抓住"; fi

# ---------------- 5) 结构性判据①：阵列同体；判据②：掩码逐 entry 正确 ----------------
"$PY" - "$gen" <<'PYEOF'
import os, re, sys, hashlib
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass
gen = sys.argv[1]

def mod(path, name):
    try:
        txt = open(path, encoding="utf-8", errors="replace").read()
    except OSError:
        return None
    m = re.search(r"^module %s\b.*?^endmodule" % name, txt, re.S | re.M)
    return m.group(0) if m else None

# 参考侧的组映射（与 rtl/GroupMask.scala / 上面 python 块同一套规则）
NCI = NCO = 8
def participates(co, ci, g):
    return ((co * g) // NCO) == ((ci * g) // NCI)

ref = mod(os.path.join(gen, "MacArray.v"), "MacArray")
if ref is None:
    print("STRUCT: SKIP-MISSING gen/MacArray.v（先跑 MacArrayGen 才能做这条结构判据）")
    sys.exit(0)
print("STRUCT: gen/MacArray.v 的 module MacArray md5=%s (%d 字节)"
      % (hashlib.md5(ref.encode()).hexdigest(), len(ref)))
bad = 0
for g, f in [(1, "GroupedMacArray.v"), (2, "GroupedMacArray_g2.v"),
             (4, "GroupedMacArray_g4.v"), (8, "GroupedMacArray_g8.v")]:
    p = os.path.join(gen, f)
    if not os.path.isfile(p):
        print("STRUCT: SKIP-MISSING %s" % f); bad += 1; continue
    txt = open(p, encoding="utf-8", errors="replace").read()
    cur = mod(p, "MacArray")
    same = (cur == ref)
    print("STRUCT: %-22s module MacArray %s" % (f, "IDENTICAL" if same else "*** DIFFERS ***"))
    if not same:
        bad += 1

    # 判据②：内嵌 MacArray 的 64 个 w 端口 —— 接 w_tile 的 entry 集合必须**恰好**是 participates
    inst = re.search(r"MacArray arr \((.*?)\n  \);", txt, re.S)
    if not inst:
        print("   MASK: %s 里找不到 MacArray 例化 ⇒ 判据失效" % f); bad += 1; continue
    conns = re.findall(r"\.w_(\d+)_(\d+)\s*\(\s*([^)]*)\)", inst.group(1))
    live = {(int(a), int(b)) for a, b, e in conns if "w_tile" in e}
    dead = {(int(a), int(b)) for a, b, e in conns if "8'h0" in e}
    want_live = {(co, ci) for co in range(NCO) for ci in range(NCI) if participates(co, ci, g)}
    want_dead = {(co, ci) for co in range(NCO) for ci in range(NCI)
                 if not participates(co, ci, g)}
    okm = (len(conns) == NCO * NCI and live == want_live and dead == want_dead)
    print("   MASK: %-22s w 端口=%d 接瓦片=%d 接常数0=%d 期望(接瓦片=%d 接0=%d) %s"
          % (f, len(conns), len(live), len(dead), len(want_live), len(want_dead),
             "OK" if okm else "*** MISPLACED ***"))
    if not okm:
        extra = sorted(live - want_live)[:4]
        miss = sorted(want_live - live)[:4]
        print("   MASK-FAIL: %s 掩码与 participates 不符（多接/少接的样例: live-want=%s want-live=%s）"
              % (f, extra, miss))
        bad += 1
sys.exit(1 if bad else 0)
PYEOF
struct_rc=$?
if [ "$struct_rc" -ne 0 ]; then
  echo "JUDGE-RED: 结构性判据失败（内嵌 module MacArray 与 gen/MacArray.v 不同体，或掩码 entry 错位）"
  SIM_BAD=1
fi

# ---------------- 判决 ----------------
if [ "$neg_ok" != 1 ]; then
  echo "=== JUDGE-RED: 负对照没抓住 ⇒ 闸门自身不可信 ==="; exit 2
fi
if [ "$SIM_BAD" -ne 0 ]; then
  echo "=== JUDGE-RED: 仿真/自检/对账/结构判据失败（grouped_mis:$grouped_mis）==="; exit 1
fi
echo "=== JUDGE-GREEN: GROUP in {1,2,4,8} 逐字节全中；dense 落位突变体对每个 GROUP>1 都被抓住；"
echo "                    depthwise 不变性(含有牙控制)成立；内嵌 MacArray 与 gen/MacArray.v 同体；"
echo "                    逐 entry 掩码与 participates(co,ci) 完全一致 ==="
exit 0
