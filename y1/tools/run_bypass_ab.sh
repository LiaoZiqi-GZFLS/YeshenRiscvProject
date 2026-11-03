#!/usr/bin/env bash
# run_bypass_ab.sh —— y1 C3 的闸门：旁路算子 MaxPool / Resize / Add / Sigmoid
#   （`rtl/{MaxPoolUnit,ResizeUnit,AddUnit,SigmoidUnit}.scala` ⇒ `gen/<名>{,_w*}.v`）。
#
# 为什么需要它：C3.1（`reports/c3_traffic_full.md` §3.3）把旁路算子的激活 IO 计进了每帧流量
#   （四类共 14 个算子、6.9456 MB/帧 的读+写），C3.10 的 LayerSched 要按描述符把它们当单元跑
#   —— 它们必须**先**有"逐点对账"的数值判据。本闸门只证**功能**（怎么算）；
#   面积/时序留给 C3.13。
#
# ★ **同一装置跑四个算子**（装置与前三个网表端口同名同宽 ⇒ 一份 rtl_test/BypassTb.v 通吃；
#   AddUnit 多一路输入 ⇒ 装置用 `-DBP_TWO_IN` 编成双输入档）：
#     算子用编译期宏 + 运行期 `+OP=` 双管：`-DBP_MOD=<模块名>` 定挂哪个网表，
#     `+OP=maxpool|resize|add|sigmoid` 定期望的输出颗数、每列输入字节数、以及"该不该看到 x_ready 拉低"。
#     Add/Sigmoid 是**纯组合、零状态**的单元 ⇒ 它们的网表**没有 clk/reset 端口**（SpinalHDL 不发），
#     装置用 `-DBP_NOCLK` 编、例化时省掉那两个口（见 rtl_test/BypassTb.v 文件头）。
# ★ **两个形状**（C=2 固定）：
#     · MaxPoolUnit：W=4 与 W=6（**非 2 的幂**列宽：accRow 3 项 / col 3 位回绕在 5）；
#     · ResizeUnit ：W=4 与 W=6（行内列号 log2Up(12)=4 位、输出计数数到 24）；
#     · AddUnit    ：W=4,H=4 与 **W=5,H=3**（非 2 的幂 + **奇数 H** —— 逐点算子没有"行对/列配对"
#                    结构 ⇒ 奇数 H 合法；装置的偶数 H 硬约束只对 MaxPool/Resize 生效，这一档
#                    就是来证明这条放宽**是真的放宽**）；
#     · SigmoidUnit：W=4,H=32（C*W*H = 256 ⇒ 每个码点恰好一次）与 W=6,H=32（384 字节，仍覆盖 256 码点）。
#   ⇒ 覆盖"列计数器非 2 的幂回绕"这条路（B6-fix 的教训：宽度钉死的错会产出**长度对得上、
#     数值整体错**的 Y，靠事后 MISMATCH 才发现既晚又像数值 bug）。
#   C=2 是装置的**已知残留风险**（DUT 端口名 x_0/x_1 不可参数化，与 rtl_test/FusionBufTb.v 同）。
#
# ============================== 判据（MaxPool/Resize：每个 算子 x 形状 各来一遍） ==============================
#  0) **向量 + 非退化前提**（本闸门自己的公式，值与 tools/bypass_ref.nontrivial **不同**）：
#     `(i*131+7)&0xFF` 的 int8 骨架，再按 2x2 块注入四段互不重叠的值域：
#       TL ∈ [-128,-66] < TR ∈ [-64,-2] < BL ∈ [0,62] < BR ∈ [64,127]（块内严格有序）。
#     显式断言（用例写错就 exit 3，不当"判据通过"）：
#       · 输入非常数、黄金输出非常数（防退化）；
#       · MaxPool：**黄金 != 左上/右上/左下/右下 四个"整块平移"子采样**，且四个两两不同
#         —— 这是**混叠**那道坎：周期性/构造性向量会让"窗口取错角"看起来一模一样；
#         先把"黄金与四个角都不同"钉死，负对照 A 才不可能是橡皮章。
#       · Resize：黄金 != 两个相位突变体（dy 行手取反 / dx 源列配对取反）的预测值
#         —— 同理，先把"相位错了必然变值"钉死。
#     ★ 顺带把**独立实现**写一遍（本闸门自己的朴素三重循环），与 `bypass_ref.py` 的黄金交叉对账
#       （`REF_XCHK=0`）：参考自身错了两边一起错的风险被这条挡住。
#  1) **正对照**：装置 `RESULT: PASS` 且输出与 `bypass_ref.py` 的黄金**逐点**一致（`MISMATCH=0`）。
#  2) **负对照 A（MaxPool 窗口 → 恒取左上角）**：网表突变（**scratch 拷贝**，绝不改 gen/ 原地）
#     把 `pairSel_*`/`vertSel_*` 恒置 1 ⇒ 窗口退化成"只看左上角"，且**输出不该再等于黄金**。
#     判据三条一起要：① 突变网表的输出 == 左上角突变体的**预测值**（`MUT_HIT=0`，精确命中，
#     不是"只要变了就算过"）；② != 黄金（`MISMATCH>0`）；③ 装置自己报 FAIL 且 vvp 非 0
#     （证明装置的自检接在回路上，不是闸门在外部替它判）。
#  3) **负对照 B（Resize 相位取反）**：网表突变两发（各自单独一发）：
#       · dy 相位：`bankSel = !bankPh`（行对的两半复刻相反的行缓冲）；
#       · dx 相位：`srcCol = (X/2) ^ 1`（相邻两对输入列互换）。
#     判据同 2)：各自精确命中突变体预测值 + != 黄金 + 装置报 FAIL。
#     ⚠ 口径说明（**这里的"混叠"最容易糊住判据**）：纯最近邻 2x 里 `out[c][2y+dy][2x+dx]=in[c][y][x]`
#       的 4 个槽**同值** ⇒ 把 (dy,dx) 字面地映射成 (1-dy,1-dx) 是**功能恒等**、根本不可观测。
#       所以"相位反了"必须落在"相位选中了哪个**源元素**"上：dy 反 = 换行缓冲；dx 反 = 换源列。
#       两发都必然改变输出（§0 已把这条钉死），于是负对照 B 不是橡皮章。
#  ⚠ **负对照只动"读/选"侧**：A 只改 pairSel/vertSel（选哪个角），B 只改 bankSel/srcCol（读哪一行/列的源）。
#    两个算子的**输入侧计数器**（MaxPool 的 col/rowPar；Resize 的 oc/orow/half/stOut）**只由正对照覆盖**
#    ⇒ "负对照全绿"**不等于**"状态机被证明"：它只证了"选角/选源错了必然变值"，别过度解读。
#
# ============================== 判据（Add：双输入饱和加，C3.7） ==============================
#  0) **向量 + 非退化/可观测前提**（本闸门自己的公式；与 `bypass_ref.add_nontrivial` **不同**）：
#     A/B 两条不同骨架 + 前 8 个点注入边界角（127/127、-128/-128、127/-128、100/100、…）。
#     显式断言：**两路不相等**（否则"加法"退化成 ×2，判据没意义）、**`SAT_EVENTS > 0`**
#     （向量上真出现过 `a+b ∉ [-128,127]`；否则"饱和 vs 回绕"两条口径输出**完全相同** ⇒ 判据是橡皮章）、
#     并且与 `bypass_ref.py add` 的黄金交叉对账（`REF_XCHK=0`）。
#  1) **正对照**：装置 `RESULT: PASS` + `MISMATCH=0`。
#  2) **负对照 C（把饱和改成回绕）**：网表突变把 `clampHi_*`/`clampLo_*` 恒置 0 ⇒ 输出 = 9 位和的低 8 位
#     = 回绕。判据三件套（精确命中 `add_mut_wrap` 预测 + != 黄金 + 装置报 FAIL）同 2)。
#  3) **单边停住**：`+STALLB=1`（`x_b_valid` 恒 0）⇒ DUT 必须**一列不吃、一颗不出**。
#     ⚠ 这是"y_valid/消费条件同时看**两路** valid"的**唯一**判据：正常跑两路 always 同拍齐，
#       "只看 A 路"的错在其它任何作业里**永不可观测**。
#  4) **双输入互锁**：同一（双输入档）网表跑 `+OP=sigmoid` ⇒ 装置 time 0 `$fatal`；
#     反向（单输入网表 + 双输入档）在**编译期**就报错（端口名对不上）——两条都验。
#
# ============================== 判据（Sigmoid：Q3.4 -> Q0.7 查表，C3.7） ==============================
#  0c) **LUT 指纹（前置作业，一次）**：`gen/sigmoid_lut.hex` 重生成两次 ⇒ md5 必须一致且与
#     gen/ 里那份**逐字节相同**（确定性）；`--lutfile` 断言"导出文件 == 冻结公式"、
#     `--lutbin` 断言"**RTL 的 Mem 初值**（SpinalHDL 生成的 `$readmemb` .bin）== 冻结公式"
#     ⇒ 两个副本 256 项逐项比（不是"输出碰巧对"）。
#  1) **向量**：码点扫描（`(j*181+59) mod 256`，前 256 个位置是 0..255 的**排列**）⇒ 断言覆盖全 256 码点；
#     黄金 = **从 gen/sigmoid_lut.hex 读表**查表（与 `bypass_ref.sigmoid_lut()` 的内存路径独立），
#     再与 `bypass_ref.py sigmoid` 的黄金交叉对账（`REF_XCHK=0`）；断言表在 `x -> -x` 下**不对称**。
#  2) **正对照**：装置 `RESULT: PASS` + `MISMATCH=0`，且装置**自己**报 `LUT-XCHK=0`
#     （装置 `$readmemh` 载入 `gen/sigmoid_lut.hex` 后逐字节自算期望）与 `LUT-CODES=256`（覆盖满码点）。
#  3) **负对照 D（查表地址取反 = 把 x 换成 -x）**：网表突变 `lutIdx := 0 - lutIdx` ⇒
#     精确命中 `sigmoid_mut_invert` 预测 + != 黄金（254/256 个码点变值）+ 装置报 FAIL。
#
#  ⚠ 三个新算子的负对照**只动各自那一个自由度**（clamp 选择 / 查表地址），输入侧计数器/自报端口
#    由正对照覆盖 —— 别把"负对照全绿"读成"接口被证明"。
#  4) **装置侧自检**：把**黄金扰动一个字节**当 +YFILE ⇒ 装置必须 `RESULT: FAIL` 且 vvp 非 0。
#  5) **参数自报**：`+IW` 与网表自报 `imgW` 不符 ⇒ 装置 time 0 `$fatal`（非 0 退出）。
#  6) **算子/网表张冠李戴**：拿一个网表跑别的 `+OP`（端口同名同宽，只看输出长度容易撞上）
#     ⇒ 装置必须**不 PASS**。
#  7) **比较器自检**：扰动黄金一个 token ⇒ 恰好 1；长度不等 ⇒ 较长者长度；文件缺失 ⇒ -1。
#  8) **结构判据**：`tools/check_dangling.py` 对八个网表 ⇒ 零悬空实例（与 B9b 同一把尺）。
#
# 退出码（与 Y1 既有闸门一致）：
#   0 = 全过（4 算子 x 2 形状：正对照 + 全部负对照发火 + 自检 + 结构 + LUT 指纹）
#   1 = 对账不符 / 编译或仿真失败 / 装置未 PASS / 网表不存在 / LUT 副本对不上
#   2 = 负对照没发火、比较器自检不过、装置自检没接在回路上 ⇒ **闸门自身不可信**
#   3 = 向量/维度自检失败（用例写错，或参考自身自检没过）
#
# 装置契约（rtl_test/BypassTb.v）：
#   +XFILE= +YFILE= +OP=maxpool|resize|add|sigmoid +C= +IW= +H=
#   （H 必须偶数 —— **只对 maxpool/resize**；`+LUTFILE=` 只对 sigmoid；`+STALLB=1` 只对 add）
#   装置打印一行 `Y <hh> ...`（流顺序 [y][x][ci]）+ 一行 `RESULT: PASS|FAIL`（FAIL ⇒ $fatal）。
set -uo pipefail

# ---- python：本闸门不依赖 onnx，普通 python 即可（找不到 venv 就用 PATH 上的）----
PY="${PY:-}"
if [ -z "$PY" ]; then
  for c in /d/code/PDS/NaxYeshenLinux/sim/reglogs/lxvenv/Scripts/python.exe python3 python; do
    if command -v "$c" >/dev/null 2>&1; then PY="$c"; break; fi
  done
fi

here="$(cd "$(dirname "$0")" && pwd)"
gen="$here/../gen"
tb="$here/../rtl_test/BypassTb.v"
ref="$here/bypass_ref.py"
dangling="$here/check_dangling.py"

C="${C:-2}"          # 通道数（= 装置宏 BP_NCI；DUT 端口名不可参数化 ⇒ 只能 2）

# iverilog/vvp 本机在 /c/msys64/ucrt64/bin（可能不在 PATH 上）⇒ 先 PATH 后固定目录。
find_tool() { # <name>
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

# 每个用例一个临时目录；统一在 EXIT 时清理（KEEP_TMP=1 则保留并打印）。
WORKDIRS=()
cleanup() {
  if [ "${KEEP_TMP:-0}" = "1" ]; then
    echo "KEEP_TMP=1 => 向量与日志留在: ${WORKDIRS[*]:-<无>}"
  else
    for d in ${WORKDIRS[@]+"${WORKDIRS[@]}"}; do rm -rf "$d"; done
  fi
}
trap cleanup EXIT

# cnt <a> <b> -> 逐 token 不符数（长度不等取较长者；任一侧缺失 = -1）
cnt() {
  "$PY" - "$1" "$2" <<'PYEOF'
import sys
def load(p):
    try:
        return open(p, encoding="utf-8", errors="replace").read().split()
    except OSError:
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

# tok <装置日志> <输出 token 文件>：把 "Y <hh> ..." 一行拆成 token
tok_of() { # <log> <out>
  grep '^Y ' "$1" | sed -e 's/^Y *//' | tr -s ' ' '\n' > "$2" || true
}

echo "== run_bypass_ab: 旁路算子 MaxPool(2x2/s2) + Resize(x2 最近邻) + Add(双输入饱和加) + Sigmoid(Q3.4->Q0.7 查表) 逐点对账 =="
echo "   tb =$tb"
echo "   rtl=MaxPoolUnit{,_w6}.v / ResizeUnit{,_w6}.v / AddUnit{,_w5}.v / SigmoidUnit{,_w6}.v  ref=$ref"
echo "   py =${PY:-<找不到>}  iverilog=${IVERILOG:-<找不到>}  vvp=${VVP:-<找不到>}"
[ -n "$IVERILOG" ] && "$IVERILOG" -V 2>&1 | head -1

# ---------------- 参考自身的自检（与独立朴素实现交叉对账） ----------------
echo "---- 0) tools/bypass_ref.py --selftest（参考自检：与独立朴素实现逐点一致 + 无量化 + 防混叠 + 奇数维度响亮失败）----"
if ! "$PY" "$ref" --selftest; then
  echo "=== FATAL: 参考自检没过 ⇒ 用例/参考写错了（不是硬件的问题）==="
  exit 3
fi

# ---------------- 结构判据：零悬空实例 ----------------
echo "---- 0b) tools/check_dangling.py（八个网表 ⇒ 零悬空）----"
dangle_ok=1
if [ -f "$dangling" ]; then
  if ! "$PY" "$dangling" "$gen/MaxPoolUnit.v" "$gen/MaxPoolUnit_w6.v" "$gen/ResizeUnit.v" "$gen/ResizeUnit_w6.v" \
                            "$gen/AddUnit.v" "$gen/AddUnit_w5.v" "$gen/SigmoidUnit.v" "$gen/SigmoidUnit_w6.v"; then
    echo "JUDGE-RED: 有悬空实例（被例化但没有模块定义）"; dangle_ok=0
  fi
else
  echo "JUDGE-RED: 找不到 $dangling"; dangle_ok=0
fi

# ---------------- LUT 指纹与"三个副本"对账（sigmoid 专用，一次） ----------------
# 判据（见文件头 §Sigmoid 0）：
#   · gen/sigmoid_lut.hex 由 bypass_ref --genlut 生成；**重生成两次**必须逐字节一致（确定性）；
#   · `--lutfile` 断言"导出的 .hex == 冻结公式"（256 项逐项）；
#   · `--lutbin` 断言"**RTL 的 Mem 初值** == 冻结公式"——SpinalHDL 对 `Mem.init` 产的是
#     `initial begin $readmemb("<网表>.v_toplevel_lut.bin", lut); end`，于是**表在运行期从文件载入**
#     （不是硬编码 256 个常量）；那个 .bin 就是"RTL 里那张表"的机器可读副本 ⇒ 直接比。
#   · .bin 是 vvp 的**运行期依赖**（相对路径 ⇒ 必须在 vvp 的 CWD 里）⇒ 下面的 judge_sigmoid 会
#     把它拷进 work 目录；缺失时**当场报红**，不许退化成"全 X ⇒ MISMATCH"那种看不懂的红。
LUT_BIN_SUFFIX="_toplevel_lut.bin"
lut_ok=1
echo "---- 0c) LUT 指纹：gen/sigmoid_lut.hex 重生成两次（确定性）+ .hex/.bin 与冻结公式逐项对账 ----"
work_lut="$(mktemp -d)"; WORKDIRS+=("$work_lut")
if ! "$PY" "$ref" --genlut="$work_lut/lut1.hex" > "$work_lut/g1.log" 2>&1 \
   || ! "$PY" "$ref" --genlut="$work_lut/lut2.hex" > "$work_lut/g2.log" 2>&1 \
   || ! "$PY" "$ref" --genlut="$gen/sigmoid_lut.hex" > "$work_lut/g0.log" 2>&1; then
  echo "JUDGE-RED: bypass_ref --genlut 跑不动"; sed -n '1,5p' "$work_lut/g1.log"; lut_ok=0
else
  md5_1="$(sed -n 's/^SIG_LUT_MD5=//p' "$work_lut/g1.log")"
  md5_2="$(sed -n 's/^SIG_LUT_MD5=//p' "$work_lut/g2.log")"
  md5_g="$(sed -n 's/^SIG_LUT_MD5=//p' "$work_lut/g0.log")"
  echo "   SIG_LUT_MD5=$md5_g  （重生成 #1=$md5_1 / #2=$md5_2；gen/ 里那份必须与两次都一致）"
  if [ "$md5_1" != "$md5_2" ]; then
    echo "JUDGE-RED: 两次重生成的 LUT 不一致（不确定性）"; lut_ok=0
  fi
  if ! cmp -s "$work_lut/lut1.hex" "$gen/sigmoid_lut.hex"; then
    echo "JUDGE-RED: 重生成的 LUT 与 gen/ 里那份不逐字节一致"; lut_ok=0
  fi
  if ! "$PY" "$ref" --lutfile="$gen/sigmoid_lut.hex"; then
    echo "JUDGE-RED: 导出的 LUT 文件 != 冻结公式"; lut_ok=0
  fi
  # 两个 sigmoid 形状各有一份 .bin（都由同一条 Scala 公式生成）⇒ 都要对
  for bl in SigmoidUnit SigmoidUnit_w6; do
    bin="$gen/${bl}.v${LUT_BIN_SUFFIX}"
    if [ ! -f "$bin" ]; then
      echo "JUDGE-RED: 找不到 RTL 的表初值文件 $bin（SpinalHDL 的 Mem.init 产物；缺了它网表跑出来全是 X）"; lut_ok=0
      continue
    fi
    if ! "$PY" "$ref" --lutbin="$bin"; then
      echo "JUDGE-RED: RTL 的 Mem 初值（$bl）!= 冻结公式"; lut_ok=0
    fi
  done
fi

# ===========================================================================
# judge_case <TAG> <OP> <W> <H> <网表> <模块名>
#   对一个 (算子, 形状) 跑**整套**判据。返回 0=全过 / 1=判据红 / 2=闸门不可信 / 3=用例写错。
# ===========================================================================
judge_case() {
  local TAG="$1" OP="$2" W="$3" H="$4" nl="$5" mod="$6"
  local work; work="$(mktemp -d)"; WORKDIRS+=("$work")

  echo "--------------------------------------------------------------------------"
  echo "==== [$TAG] op=$OP C=$C W=$W H=$H  网表=$nl  模块=$mod ===="

  # -------------------------------------------------------------------------
  # 0) 造流 + 独立算黄金 + 非退化/防混叠前提
  # -------------------------------------------------------------------------
  if ! "$PY" - "$work" "$OP" "$C" "$W" "$H" <<'PYEOF'
import sys
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

work, OP, C, W, H = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5])
if W < 2 or W % 2 or H % 2:
    print("FATAL: 本闸门只用 W>=2 偶数、H 偶数（MaxPool 硬要求偶数 W/H）")
    sys.exit(3)

def i8(v):
    v &= 0xFF
    return v - 256 if v >= 128 else v

def val(r, c, ci):
    """本闸门自己的造流公式（**与 tools/bypass_ref.nontrivial 不同**：不同乘子/偏移 ⇒ 不是同一组向量）。
    2x2 块内四个角两两不同，且"局部极大"落在哪个角**逐块轮转**（hot = 块号 % 4）：
      hot 角 ∈ [64,119]；其余三角 ∈ {-128+ph, -88+ph, -48+ph}（都 < 64 且互不相同）"""
    i = (r*W + c)*C + ci
    k = ((r//2)*(W//2) + (c//2))*C + ci
    ph = (k*37 + 11) % 56
    hot = k % 4
    corner = (r % 2)*2 + (c % 2)
    if corner == hot:
        v = 64 + ph
    else:
        idx = sum(1 for kk in range(corner) if kk != hot)
        v = [-128 + ph, -88 + ph, -48 + ph][idx]
    v += i8(i*131 + 7) & 1
    assert -128 <= v <= 127, "注入值越界: %d" % v
    return v

x = [val(r, c, ci) for r in range(H) for c in range(W) for ci in range(C)]

# ---- 独立实现的黄金（本闸门自己写，不复用 bypass_ref；用来交叉对账参考）----
def gold_maxpool():
    ow, oh = W//2, H//2
    out = [0]*(C*ow*oh)
    for y in range(oh):
        for xo in range(ow):
            for ci in range(C):
                m = x[((2*y+0)*W + (2*xo+0))*C + ci]
                for dy in (0, 1):
                    for dx in (0, 1):
                        v = x[((2*y+dy)*W + (2*xo+dx))*C + ci]
                        if v > m:
                            m = v
                out[(y*ow + xo)*C + ci] = m
    return out

def gold_resize():
    OW, OH = 2*W, 2*H
    out = [0]*(C*OW*OH)
    for Y in range(OH):
        for X in range(OW):
            for ci in range(C):
                out[(Y*OW + X)*C + ci] = x[((Y//2)*W + (X//2))*C + ci]
    return out

def subsample(rr, cc):
    """按 2x2 块的角 (rr,cc) 子采样（展平 [y][x][ci]）—— "整块平移"的四个位置。"""
    ow, oh = W//2, H//2
    return [x[((2*y+rr)*W + (2*xo+cc))*C + ci]
            for y in range(oh) for xo in range(ow) for ci in range(C)]

def bank_mut():   # dy 相位取反（行手 bank = 1 - g//2）
    OW, OH = 2*W, 2*H
    return [x[((2*(Y//4) + (1 - ((Y % 4)//2)))*W + (X//2))*C + ci]
            for Y in range(OH) for X in range(OW) for ci in range(C)]

def col_mut():     # dx 相位取反（源列号最低位取反）
    OW, OH = 2*W, 2*H
    return [x[((Y//2)*W + ((X//2) ^ 1))*C + ci]
            for Y in range(OH) for X in range(OW) for ci in range(C)]

gold = gold_maxpool() if OP == "maxpool" else gold_resize()
nz = lambda a: len(set(a)) > 1

# ---- 非退化 + 防混叠（用例不满足就 exit 3，绝不当"通过"）----
assert nz(x), "输入是常数 ⇒ 用例没意义"
assert nz(gold), "黄金输出是常数 ⇒ 判据会退化（取最大若全都撞同一个值就白判）"
print("VEC: C=%d W=%d H=%d 输入=%d 字节 黄金=%d 字节；输入/黄金都非常数" % (C, W, H, len(x), len(gold)))
if OP == "maxpool":
    TL, TR, BL, BR = subsample(0,0), subsample(0,1), subsample(1,0), subsample(1,1)
    assert len({tuple(TL), tuple(TR), tuple(BL), tuple(BR)}) == 4, \
        "四个角子采样有重复 ⇒ 只看'某个角'的错会被混叠糊住"
    for nm, sub in (("TL", TL), ("TR", TR), ("BL", BL), ("BR", BR)):
        assert gold != sub, "黄金 == 整块平移 %s ⇒ 该方向上的窗口突变不可观测（混叠）" % nm
    hits = [sum(1 for a, b in zip(gold, s) if a == b) for s in (TL, TR, BL, BR)]
    assert all(0 < h < len(gold) for h in hits), \
        "黄金与某个角子采样只整段相同或整段不同（%s）⇒ 该角没被真用到" % hits
    print("ALIAS_GUARD: 黄金 != 左上/右上/左下/右下 四个整块平移子采样，四者两两不同，且每个角都被真用到（命中 %s）" % hits)
else:
    gb, gc = bank_mut(), col_mut()
    assert gold != gb, "黄金 == dy 相位取反的预测 ⇒ 行相位不可观测（混叠）"
    assert gold != gc, "黄金 == dx 相位取反的预测 ⇒ 列相位不可观测（混叠）"
    assert gb != gc, "两个相位突变体预测相同 ⇒ 至少一发没意义"
    print("ALIAS_GUARD: 黄金 != dy 相位取反 / dx 相位取反 两个突变体预测（相位错了必然变值）")

def dump(path, toks):
    with open(path, "w", encoding="ascii", newline="\n") as fh:
        fh.write("".join("%02x\n" % (v & 0xFF) for v in toks))

dump(work + "/x.hex", x)
dump(work + "/naive.hex", gold)        # 本闸门独立算的黄金（用来交叉对账 bypass_ref）
print("VEC: 已写 %s/x.hex 与 naive.hex（独立实现）" % work)
PYEOF
  then
    echo "[$TAG] FATAL: 向量/期望/非退化前提不成立 ⇒ 用例没意义"; return 3
  fi
  for f in x.hex naive.hex; do
    [ -s "$work/$f" ] || { echo "[$TAG] FATAL: 向量 $f 缺失或为空"; return 3; }
  done

  # -------------------------------------------------------------------------
  # 1) 参考出黄金 + 与独立实现交叉对账；再算突变体预测（并断言它们与黄金不同）
  # -------------------------------------------------------------------------
  echo "---- [$TAG] 1) bypass_ref.py 出黄金 + 与独立实现交叉对账 ----"
  if ! "$PY" "$ref" "$OP" "$C" "$W" "$H" --infile="$work/x.hex" > "$work/gold.hex" 2> "$work/ref.err"; then
    echo "[$TAG] FATAL: bypass_ref 出黄金失败"; cat "$work/ref.err"; return 3
  fi
  local refchk
  refchk="$(cnt "$work/naive.hex" "$work/gold.hex")"
  echo "[$TAG] REF_XCHK=$refchk（期望 0：参考的黄金 == 本闸门独立朴素实现）"
  if [ "$refchk" != "0" ]; then
    echo "[$TAG] FATAL: 参考与独立实现不一致 ⇒ 参考不可信"; sed -n '1,5p' "$work/ref.err"; return 3
  fi

  local muts=""
  if [ "$OP" = "maxpool" ]; then muts="topleft"; else muts="bank col"; fi
  local m
  for m in $muts; do
    if ! "$PY" "$ref" "$OP" "$C" "$W" "$H" --infile="$work/x.hex" --mutate="$m" > "$work/pred_$m.hex" 2>/dev/null; then
      echo "[$TAG] FATAL: 出突变体 $m 的预测失败"; return 3
    fi
    local dm
    dm="$(cnt "$work/gold.hex" "$work/pred_$m.hex")"
    echo "[$TAG] MUT_PREMISE[$m]: 黄金 vs 突变体预测 差 $dm 个字节（期望 >0）"
    if ! [ "$dm" -gt 0 ] 2>/dev/null; then
      echo "[$TAG] FATAL: 突变体 $m 的预测与黄金相同 ⇒ 这一发负对照没意义"; return 3
    fi
  done

  # -------------------------------------------------------------------------
  # 2) 编译 + 正对照
  # -------------------------------------------------------------------------
  echo "---- [$TAG] 2) iverilog 编译（BypassTb + $nl；-DBP_NCI=$C -DBP_NW=$W -DBP_MOD=$mod）----"
  if [ ! -f "$nl" ]; then
    echo "[$TAG] JUDGE-RED: 网表不存在：$nl（先跑 sbt 生成步骤）"; return 1
  fi
  if [ -z "$IVERILOG" ] || [ -z "$VVP" ]; then
    echo "[$TAG] JUDGE-RED: 找不到 iverilog / vvp"; return 1
  fi
  if ! "$IVERILOG" -g2012 -DBP_NCI="$C" -DBP_NW="$W" -DBP_MOD="$mod" -DBP_ROW -o "$work/dut.vvp" "$tb" "$nl" \
        > "$work/iv.log" 2>&1; then
    echo "[$TAG] JUDGE-RED: iverilog 编译失败"; sed -n '1,30p' "$work/iv.log"; return 1
  fi
  grep -qi 'warning' "$work/iv.log" && { echo "[$TAG] 编译告警（留意形状参数）："; grep -i 'warning' "$work/iv.log" | head -3; }

  # run_vvp <tag> <vvp> <yfile> -> 打印 rc
  run_vvp() { # <tag> <vvp> <yfile>
    local tag="$1" vvp="$2" yf="$3"
    ( cd "$work" && "$VVP" "$vvp" \
        "+XFILE=$work/x.hex" "+YFILE=$yf" \
        "+OP=$OP" "+C=$C" "+IW=$W" "+H=$H" ) > "$work/$tag.out" 2>&1
    tok_of "$work/$tag.out" "$work/$tag.tok"
    return 0
  }

  local rc=0
  run_vvp pos dut.vvp "$work/gold.hex" || rc=$?
  local mis
  mis="$(cnt "$work/gold.hex" "$work/pos.tok")"
  echo "[$TAG] MISMATCH=$mis   （vvp rc=$rc）"
  if ! grep -q '^RESULT: PASS' "$work/pos.out"; then
    echo "[$TAG] JUDGE-RED: 正对照装置未 PASS"
    grep -E '^(RESULT|TB-ERROR|TB-INFO|MISMATCH)' "$work/pos.out" | head -10
    return 1
  fi
  if [ "$rc" -ne 0 ]; then echo "[$TAG] JUDGE-RED: 正对照 vvp 非 0 退出（$rc）"; return 1; fi
  if [ "$mis" != "0" ]; then
    echo "[$TAG] JUDGE-RED: 正对照与黄金差 $mis 个字节 ⇒ 硬件与参考不符"; return 1
  fi
  echo "[$TAG] 正对照 PASS：装置输出与 bypass_ref 黄金逐字节一致（MISMATCH=0）"
  echo "  Y = $(head -c 160 "$work/pos.tok" | tr '\n' ' ') ..."

  # -------------------------------------------------------------------------
  # 3) 比较器自检（三分支）
  # -------------------------------------------------------------------------
  echo "---- [$TAG] 3) 比较器自检：扰动黄金 1 个 token ⇒ 恰好 1 / 长度不等 / 缺文件 ----"
  "$PY" - "$work/gold.hex" "$work/gold_pert.hex" <<'PYEOF'
import sys
# 黄金可能是"一行多 token"（bypass_ref 的 CLI 输出）⇒ 一律先 split 成 token 再动。
t = open(sys.argv[1], encoding="utf-8", errors="replace").read().split()
i = len(t) // 2
t[i] = "%02x" % ((int(t[i], 16) ^ 0x01) & 0xFF)
open(sys.argv[2], "w", encoding="ascii", newline="\n").write("\n".join(t) + "\n")
print("CMP_SELFTEST_PERTURB idx=%d" % i)
PYEOF
  local cs cs_len cs_miss N
  cs="$(cnt "$work/gold_pert.hex" "$work/pos.tok")"
  N="$(wc -w < "$work/gold.hex" | tr -d ' ')"
  "$PY" - "$work/gold.hex" "$work/gold_short.hex" 3 <<'PYEOF'
import sys
t = open(sys.argv[1], encoding="utf-8", errors="replace").read().split()
open(sys.argv[2], "w", encoding="ascii", newline="\n").write("\n".join(t[:-3]) + "\n")
PYEOF
  cs_len="$(cnt "$work/gold_short.hex" "$work/pos.tok")"
  cs_miss="$(cnt "$work/definitely_missing.hex" "$work/pos.tok")"
  echo "[$TAG] CMP_SELFTEST 扰动=$cs(期望1) 长度不等=$cs_len(期望$N) 缺文件=$cs_miss(期望-1)"
  if [ "$cs" != "1" ] || [ "$cs_len" != "$N" ] || [ "$cs_miss" != "-1" ]; then
    echo "[$TAG] RESULT: FAIL（比较器自检三分支没走全）⇒ 闸门不可信"; return 2
  fi
  echo "[$TAG] NEG_OK[cmp_self]: cnt 的三条分支（扰动 1 / 长度不等 / 缺文件）都不是橡皮章"

  # -------------------------------------------------------------------------
  # 4) 装置侧自检：扰动黄金当 +YFILE ⇒ 装置必须自己报 FAIL
  # -------------------------------------------------------------------------
  echo "---- [$TAG] 4) 装置侧自检：把扰动过的黄金当 +YFILE ⇒ 装置必须 RESULT: FAIL 且非 0 ----"
  run_vvp tbneg dut.vvp "$work/gold_pert.hex" || true
  if grep -q '^RESULT: PASS' "$work/tbneg.out"; then
    echo "[$TAG] RESULT: FAIL（装置拿到扰动黄金仍 PASS）⇒ 装置自检没接在回路上"; return 2
  fi
  if ! grep -q '^RESULT: FAIL' "$work/tbneg.out"; then
    echo "[$TAG] RESULT: FAIL（装置既没 PASS 也没 FAIL？）"; sed -n '1,10p' "$work/tbneg.out"; return 2
  fi
  echo "[$TAG] NEG_OK[tb_self]: 扰动黄金 ⇒ 装置自己报 FAIL 并 \$fatal（非 0 退出）"

  # -------------------------------------------------------------------------
  # 5) 负对照（网表突变，scratch 拷贝；每一发都要"精确命中突变预测 + != 黄金 + 装置报 FAIL"）
  # -------------------------------------------------------------------------
  # mut_make <mode> <netlist> <out>: 就地替换（严格断言命中数，风格与 run_linebuffer_ab.sh 一致）
  mut_make() { # <mode> <netlist> <out>
    "$PY" - "$1" "$2" "$3" <<'PYEOF'
import re, sys
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass
mode, src_p, out_p = sys.argv[1], sys.argv[2], sys.argv[3]
src = open(src_p, encoding="utf-8").read()
if mode == "topleft":
    # 窗口取最大 -> 恒取左上角：横向选择器与纵向选择器**恒 1**（取"靠前"的那个操作数）
    src, n1 = re.subn(r"^  assign (pairSel_\d+) = .*;$", r"  assign \1 = 1'b1;", src, flags=re.M)
    src, n2 = re.subn(r"^  assign (vertSel_\d+) = .*;$", r"  assign \1 = 1'b1;", src, flags=re.M)
    print("MUT[topleft]: pairSel %d 处 / vertSel %d 处（期望各 1 组 = %s）" % (n1, n2, "C=2 时各 2 处"))
    if n1 < 1 or n2 < 1:
        sys.exit(2)
elif mode == "bank":
    # dy 相位取反：源行手 bank = 1 - dy
    src, n1 = re.subn(r"^  assign bankSel = bankPh;$", "  assign bankSel = (! bankPh);", src, flags=re.M)
    print("MUT[bank]: bankSel %d 处（期望 1）" % n1)
    if n1 != 1:
        sys.exit(2)
elif mode == "col":
    # dx 相位取反：源列号最低位取反（配对边界挪一格）
    src, n1 = re.subn(r"^  assign srcCol = \((oc >>> \d+'d1)\);$",
                      r"  assign srcCol = ((\1) ^ 1'b1);", src, flags=re.M)
    print("MUT[col]: srcCol %d 处（期望 1）" % n1)
    if n1 != 1:
        sys.exit(2)
else:
    sys.exit(2)
open(out_p, "w", encoding="ascii", newline="\n").write(src)
PYEOF
  }

  local mut_hit_all=0
  for m in $muts; do
    echo "---- [$TAG] 5) 负对照[$m]：网表突变 ⇒ 必须精确命中突变预测值、且 != 黄金 ----"
    if ! mut_make "$m" "$nl" "$work/mut_$m.v"; then
      echo "[$TAG] RESULT: FAIL（构造突变网表失败：生成风格变了，请更新本判据）⇒ 闸门不可信"; return 2
    fi
    if cmp -s "$nl" "$work/mut_$m.v"; then
      echo "[$TAG] RESULT: FAIL（突变网表与原文相同）⇒ 闸门不可信"; return 2
    fi
    if ! "$IVERILOG" -g2012 -DBP_NCI="$C" -DBP_NW="$W" -DBP_MOD="$mod" -DBP_ROW -o "$work/mut_$m.vvp" "$tb" "$work/mut_$m.v" \
          > "$work/iv_mut_$m.log" 2>&1; then
      echo "[$TAG] RESULT: FAIL（突变网表编译失败）"; sed -n '1,20p' "$work/iv_mut_$m.log"; return 2
    fi
    # 用**黄金**当 +YFILE 跑突变体：装置该自己报 FAIL（证明装置自检有效），同时它的 Y 行被我们抓来对账
    run_vvp "mut_$m" "mut_$m.vvp" "$work/gold.hex" || true
    local hit mis_mut tb_fail
    hit="$(cnt "$work/pred_$m.hex" "$work/mut_$m.tok")"
    mis_mut="$(cnt "$work/gold.hex" "$work/mut_$m.tok")"
    tb_fail=0
    grep -q '^RESULT: FAIL' "$work/mut_$m.out" && tb_fail=1
    echo "[$TAG] MUT[$m]: 突变体 vs 突变预测 MISMATCH=$hit（期望 0=精确命中）  vs 黄金 MISMATCH=$mis_mut（期望 >0）  装置自报FAIL=$tb_fail（期望 1）"
    if [ "$hit" != "0" ]; then
      echo "[$TAG] RESULT: FAIL（负对照[$m]没精确命中突变预测：$hit）⇒ 这条判据口径对不上突变"; return 2
    fi
    if ! [ "$mis_mut" -gt 0 ] 2>/dev/null; then
      echo "[$TAG] RESULT: FAIL（负对照[$m]没发火：窗口/相位错了输出却没变）⇒ 判据是橡皮章"; return 2
    fi
    if [ "$tb_fail" != "1" ]; then
      echo "[$TAG] RESULT: FAIL（突变体下装置没报 FAIL）⇒ 装置自检没接在回路上"; return 2
    fi
    echo "[$TAG] NEG_OK[$m]: 突变体输出 == 突变预测（逐字节 0 差）且 != 黄金（差 $mis_mut 字节）⇒ 这一发真被抓住"
    mut_hit_all=$((mut_hit_all + mis_mut))
  done

  # -------------------------------------------------------------------------
  # 6) 参数自报：+IW 与网表 imgW 不符 ⇒ time 0 $fatal
  # -------------------------------------------------------------------------
  echo "---- [$TAG] 6) 参数自报：+IW=$((W+1))（与网表 imgW=$W 不符）⇒ 装置必须 \$fatal ----"
  ( cd "$work" && "$VVP" dut.vvp "+XFILE=$work/x.hex" "+YFILE=$work/gold.hex" \
      "+OP=$OP" "+C=$C" "+IW=$((W+1))" "+H=$H" ) > "$work/badw.out" 2>&1
  local badw_rc=$?
  if [ "$badw_rc" -eq 0 ] || ! grep -q 'TB-ERROR: 网表自报' "$work/badw.out"; then
    echo "[$TAG] RESULT: FAIL（+IW 不符但装置没在 time 0 报红，rc=$badw_rc）⇒ 参数自报没接在回路上"; return 2
  fi
  echo "[$TAG] NEG_OK[自报]: +IW 不符 ⇒ 装置 time 0 报红（vvp rc=$badw_rc）"

  # -------------------------------------------------------------------------
  # 7) 算子/网表张冠李戴：拿本网表跑另一个 +OP ⇒ 必须不 PASS
  # -------------------------------------------------------------------------
  local other="resize"; [ "$OP" = "resize" ] && other="maxpool"
  echo "---- [$TAG] 7) 张冠李戴：同一网表跑 +OP=$other ⇒ 装置必须不 PASS ----"
  ( cd "$work" && "$VVP" dut.vvp "+XFILE=$work/x.hex" "+YFILE=$work/gold.hex" \
      "+OP=$other" "+C=$C" "+IW=$W" "+H=$H" ) > "$work/wrongop.out" 2>&1
  local wo_rc=$?
  if [ "$wo_rc" -eq 0 ] || grep -q '^RESULT: PASS' "$work/wrongop.out"; then
    echo "[$TAG] RESULT: FAIL（+OP=$other 配错网表竟然还是 PASS）⇒ 算子/网表绑定没判据"
    grep -E '^(RESULT|TB-ERROR|TB-INFO)' "$work/wrongop.out" | head -5; return 2
  fi
  echo "[$TAG] NEG_OK[张冠李戴]: +OP=$other ⇒ 装置不 PASS（vc=$wo_rc，$(grep -E '^RESULT:' "$work/wrongop.out" | head -1)）"

  echo "[$TAG] CASE = OK（正对照 MISMATCH=0 / 负对照合计差 $mut_hit_all 字节并精确命中 / 自检 + 自报 + 张冠李戴全发火）"
  return 0
}

# ===========================================================================
# mut_make2 <mode> <netlist> <out> <C>：C3.7 两个算子的网表突变（scratch 拷贝，绝不改 gen/ 原地）
#   · addwrap ：把**饱和关掉**（clampHi/clampLo 恒 0）⇒ 输出 = 9 位和的低 8 位 = **回绕**
#   · siginv  ：把**查表地址取反**（`lutIdx := 0 - lutIdx`）⇒ 读到 lut[(-x)+128] = round(127*sigmoid(-x/16))
#   ⚠ 两条都**只动那一个自由度**，两个 `.*`/`[^;]*` 都带"命中数断言"：**严格 `== C`**
#     （clampHi/clampLo/lutIdx 各 C 处；`!= C` 当场 exit 2，与 mut_make 的 bank/col 同一风格）
#     ⇒ 生成风格一变（或通道数漂移）就**在突变点响亮失败**，而不是"正则没匹配上 ⇒ 突变体其实没变 ⇒ 白过"。
# ===========================================================================
mut_make2() { # <mode> <netlist> <out> <C>
  "$PY" - "$1" "$2" "$3" "$4" <<'PYEOF'
import re, sys
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass
mode, src_p, out_p, C = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
src = open(src_p, encoding="utf-8").read()
if mode == "addwrap":
    src, n1 = re.subn(r"^  assign (clampHi_\d+) = .*;$", r"  assign \1 = 1'b0;", src, flags=re.M)
    src, n2 = re.subn(r"^  assign (clampLo_\d+) = .*;$", r"  assign \1 = 1'b0;", src, flags=re.M)
    print("MUT[addwrap]: clampHi %d 处 / clampLo %d 处（期望各 = C = %d 处）" % (n1, n2, C))
    if n1 != C or n2 != C:
        sys.exit(2)
elif mode == "siginv":
    src, n1 = re.subn(r"^  assign (lutIdx_\d+) = ([^;]*);$", r"  assign \1 = (8'h00 - (\2));", src, flags=re.M)
    print("MUT[siginv]: lutIdx %d 处（期望 = C = %d 处）" % (n1, C))
    if n1 != C:
        sys.exit(2)
else:
    sys.exit(2)
open(out_p, "w", encoding="ascii", newline="\n").write(src)
PYEOF
}

# ===========================================================================
# judge_add <TAG> <W> <H> <网表> <模块名>
#   AddUnit 的一整套判据（见文件头 §Add）。返回 0=全过 / 1=判据红 / 2=闸门不可信 / 3=用例写错。
# ===========================================================================
judge_add() {
  local TAG="$1" W="$2" H="$3" nl="$4" mod="$5"
  local work; work="$(mktemp -d)"; WORKDIRS+=("$work")

  echo "--------------------------------------------------------------------------"
  echo "==== [$TAG] op=add（双输入**饱和**加） C=$C W=$W H=$H  网表=$nl  模块=$mod ===="

  # -------------------------------------------------------------------------
  # 0) 向量（两路不同骨架 + 注入边界/饱和点）+ 本闸门独立黄金 + 非退化/可饱和前提
  # -------------------------------------------------------------------------
  if ! "$PY" - "$work" "$C" "$W" "$H" <<'PYEOF'
import sys
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass
work, C, W, H = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])

def i8(v):
    v &= 0xFF
    return v - 256 if v >= 128 else v

N = C * W * H
a = [0] * N
b = [0] * N
# 前 8 个点注入边界角（含 plan 点名的 127+127 / -128+-128，以及跨零的 127+(-128)）
inj = [(127, 127), (-128, -128), (127, -128), (-128, 127), (100, 100), (-100, -100), (127, 0), (-128, 0)]
for r in range(H):
    for c in range(W):
        for ci in range(C):
            i = (r * W + c) * C + ci
            if i < len(inj):
                a[i], b[i] = inj[i]
            else:
                a[i] = i8(i * 97 + 13)          # 本闸门自己的骨架（与 bypass_ref.add_nontrivial 不同）
                b[i] = i8((i * 193 + 41) % 256)

def gold():
    """本闸门**独立**写的饱和加（显式 if/else，不复用 bypass_ref.clamp8）。"""
    out = []
    for x, y in zip(a, b):
        s = x + y
        out.append(127 if s > 127 else (-128 if s < -128 else s))
    return out

def wrap():
    return [i8(x + y) for x, y in zip(a, b)]

assert len(set(a)) > 1 and len(set(b)) > 1, "某一路是常数 ⇒ 用例没意义"
assert a != b, "两路输入相等 ⇒ 加法退化成 ×2，正对照没意义"
assert gold() != wrap(), "黄金 == 回绕预测 ⇒ 饱和/回绕不可区分（负对照会是橡皮章）"
sat = sum(1 for x, y in zip(a, b) if not (-128 <= x + y <= 127))
assert sat > 0, "向量里没有越界点（SAT_EVENTS=0）⇒ '饱和 vs 回绕'这条判据是橡皮章"
# 装置喂的是**按列交织**的流：每列 [A 的 C 个通道][B 的 C 个通道]
st = []
for col in range(W * H):
    st.extend(a[col * C:(col + 1) * C])
    st.extend(b[col * C:(col + 1) * C])
assert len(st) == 2 * C * W * H

def dump(path, toks):
    with open(path, "w", encoding="ascii", newline="\n") as fh:
        fh.write("".join("%02x\n" % (v & 0xFF) for v in toks))

dump(work + "/ab.hex", st)
dump(work + "/naive.hex", gold())
print("VEC: C=%d W=%d H=%d | 交织输入 %d 字节（两路各 %d）| 两路不相等 | SAT_EVENTS=%d | 黄金 != 回绕预测"
      % (C, W, H, len(st), N, sat))
PYEOF
  then
    echo "[$TAG] FATAL: 向量/非退化前提不成立 ⇒ 用例没意义"; return 3
  fi

  # -------------------------------------------------------------------------
  # 1) 参考出黄金 + 与独立实现交叉对账；再算回绕突变体预测（并断言与黄金不同）
  # -------------------------------------------------------------------------
  echo "---- [$TAG] 1) bypass_ref.py add 出黄金 + 与独立实现交叉对账 + 回绕预测 ----"
  if ! "$PY" "$ref" add "$C" "$W" "$H" --infile="$work/ab.hex" > "$work/gold.hex" 2> "$work/ref.err"; then
    echo "[$TAG] FATAL: bypass_ref 出黄金失败"; cat "$work/ref.err"; return 3
  fi
  if ! "$PY" "$ref" add "$C" "$W" "$H" --infile="$work/ab.hex" --mutate=wrap > "$work/pred_wrap.hex" 2>/dev/null; then
    echo "[$TAG] FATAL: 出回绕突变体预测失败"; return 3
  fi
  local refchk dm
  refchk="$(cnt "$work/naive.hex" "$work/gold.hex")"
  dm="$(cnt "$work/gold.hex" "$work/pred_wrap.hex")"
  echo "[$TAG] REF_XCHK=$refchk（期望 0：参考黄金 == 本闸门独立饱和加）  MUT_PREMISE[wrap]=$dm（期望 >0：黄金 != 回绕）"
  if [ "$refchk" != "0" ]; then
    echo "[$TAG] FATAL: 参考与独立实现不一致 ⇒ 参考不可信"; sed -n '1,5p' "$work/ref.err"; return 3
  fi
  if ! [ "$dm" -gt 0 ] 2>/dev/null; then
    echo "[$TAG] FATAL: 回绕预测与黄金相同 ⇒ 这一发负对照没意义（向量上没有越界点？）"; return 3
  fi

  # -------------------------------------------------------------------------
  # 2) 编译（双输入档 + 无 clk/reset 档）+ 正对照
  # -------------------------------------------------------------------------
  echo "---- [$TAG] 2) iverilog 编译（-DBP_NCI=$C -DBP_NW=$W -DBP_MOD=$mod -DBP_TWO_IN -DBP_NOCLK）----"
  if [ ! -f "$nl" ]; then echo "[$TAG] JUDGE-RED: 网表不存在：$nl（先跑 sbt 生成步骤）"; return 1; fi
  if [ -z "$IVERILOG" ] || [ -z "$VVP" ]; then echo "[$TAG] JUDGE-RED: 找不到 iverilog / vvp"; return 1; fi
  if ! "$IVERILOG" -g2012 -DBP_NCI="$C" -DBP_NW="$W" -DBP_MOD="$mod" -DBP_TWO_IN -DBP_NOCLK \
        -o "$work/dut.vvp" "$tb" "$nl" > "$work/iv.log" 2>&1; then
    echo "[$TAG] JUDGE-RED: iverilog 编译失败"; sed -n '1,30p' "$work/iv.log"; return 1
  fi

  # run_add <tag> <vvp> <yfile> [额外 plusargs...]：喂 A/B 两路（B 路可选被 +STALLB 掐住）
  run_add() { # <tag> <vvp> <yfile> [extra...]
    local tag="$1" vvp="$2" yf="$3"; shift 3
    ( cd "$work" && "$VVP" "$vvp" \
        "+XFILE=$work/ab.hex" "+YFILE=$yf" \
        "+OP=add" "+C=$C" "+IW=$W" "+H=$H" "$@" ) > "$work/$tag.out" 2>&1
    tok_of "$work/$tag.out" "$work/$tag.tok"
    return 0
  }

  local rc=0 mis
  run_add pos dut.vvp "$work/gold.hex" || rc=$?
  mis="$(cnt "$work/gold.hex" "$work/pos.tok")"
  echo "[$TAG] MISMATCH=$mis   （vvp rc=$rc）"
  if ! grep -q '^RESULT: PASS' "$work/pos.out"; then
    echo "[$TAG] JUDGE-RED: 正对照装置未 PASS"
    grep -E '^(RESULT|TB-ERROR|TB-INFO|MISMATCH)' "$work/pos.out" | head -10
    return 1
  fi
  if [ "$rc" -ne 0 ]; then echo "[$TAG] JUDGE-RED: 正对照 vvp 非 0 退出（$rc）"; return 1; fi
  if [ "$mis" != "0" ]; then
    echo "[$TAG] JUDGE-RED: 正对照与黄金差 $mis 个字节 ⇒ 硬件与参考不符"; return 1
  fi
  echo "[$TAG] 正对照 PASS：装置输出与 bypass_ref 黄金逐字节一致（MISMATCH=0）"
  echo "  Y = $(head -c 160 "$work/pos.tok" | tr '\n' ' ') ..."

  # -------------------------------------------------------------------------
  # 3) 比较器自检（三分支）
  # -------------------------------------------------------------------------
  echo "---- [$TAG] 3) 比较器自检：扰动黄金 1 个 token ⇒ 恰好 1 / 长度不等 / 缺文件 ----"
  "$PY" - "$work/gold.hex" "$work/gold_pert.hex" <<'PYEOF'
import sys
t = open(sys.argv[1], encoding="utf-8", errors="replace").read().split()
i = len(t) // 2
t[i] = "%02x" % ((int(t[i], 16) ^ 0x01) & 0xFF)
open(sys.argv[2], "w", encoding="ascii", newline="\n").write("\n".join(t) + "\n")
print("CMP_SELFTEST_PERTURB idx=%d" % i)
PYEOF
  local cs cs_len cs_miss N
  cs="$(cnt "$work/gold_pert.hex" "$work/pos.tok")"
  N="$(wc -w < "$work/gold.hex" | tr -d ' ')"
  "$PY" - "$work/gold.hex" "$work/gold_short.hex" 3 <<'PYEOF'
import sys
t = open(sys.argv[1], encoding="utf-8", errors="replace").read().split()
open(sys.argv[2], "w", encoding="ascii", newline="\n").write("\n".join(t[:-3]) + "\n")
PYEOF
  cs_len="$(cnt "$work/gold_short.hex" "$work/pos.tok")"
  cs_miss="$(cnt "$work/definitely_missing.hex" "$work/pos.tok")"
  echo "[$TAG] CMP_SELFTEST 扰动=$cs(期望1) 长度不等=$cs_len(期望$N) 缺文件=$cs_miss(期望-1)"
  if [ "$cs" != "1" ] || [ "$cs_len" != "$N" ] || [ "$cs_miss" != "-1" ]; then
    echo "[$TAG] RESULT: FAIL（比较器自检三分支没走全）⇒ 闸门不可信"; return 2
  fi
  echo "[$TAG] NEG_OK[cmp_self]: cnt 的三条分支（扰动 1 / 长度不等 / 缺文件）都不是橡皮章"

  # -------------------------------------------------------------------------
  # 4) 装置侧自检：扰动黄金当 +YFILE ⇒ 装置必须自己报 FAIL
  # -------------------------------------------------------------------------
  echo "---- [$TAG] 4) 装置侧自检：把扰动过的黄金当 +YFILE ⇒ 装置必须 RESULT: FAIL 且非 0 ----"
  run_add tbneg dut.vvp "$work/gold_pert.hex" || true
  if grep -q '^RESULT: PASS' "$work/tbneg.out"; then
    echo "[$TAG] RESULT: FAIL（装置拿到扰动黄金仍 PASS）⇒ 装置自检没接在回路上"; return 2
  fi
  if ! grep -q '^RESULT: FAIL' "$work/tbneg.out"; then
    echo "[$TAG] RESULT: FAIL（装置既没 PASS 也没 FAIL？）"; sed -n '1,10p' "$work/tbneg.out"; return 2
  fi
  echo "[$TAG] NEG_OK[tb_self]: 扰动黄金 ⇒ 装置自己报 FAIL 并 \$fatal（非 0 退出）"

  # -------------------------------------------------------------------------
  # 5) 负对照 C（把饱和改成回绕）：突变网表必须精确命中回绕预测 + != 黄金 + 装置报 FAIL
  # -------------------------------------------------------------------------
  echo "---- [$TAG] 5) 负对照[addwrap]：clamp 恒 0（饱和 -> 回绕）⇒ 必须精确命中回绕预测、且 != 黄金 ----"
  if ! mut_make2 addwrap "$nl" "$work/mut_addwrap.v" "$C"; then
    echo "[$TAG] RESULT: FAIL（构造突变网表失败：生成风格变了，请更新本判据）⇒ 闸门不可信"; return 2
  fi
  if cmp -s "$nl" "$work/mut_addwrap.v"; then
    echo "[$TAG] RESULT: FAIL（突变网表与原文相同）⇒ 闸门不可信"; return 2
  fi
  if ! "$IVERILOG" -g2012 -DBP_NCI="$C" -DBP_NW="$W" -DBP_MOD="$mod" -DBP_TWO_IN -DBP_NOCLK \
        -o "$work/mut_addwrap.vvp" "$tb" "$work/mut_addwrap.v" > "$work/iv_mut.log" 2>&1; then
    echo "[$TAG] RESULT: FAIL（突变网表编译失败）"; sed -n '1,20p' "$work/iv_mut.log"; return 2
  fi
  run_add mut_addwrap "mut_addwrap.vvp" "$work/gold.hex" || true
  local hit mis_mut tb_fail
  hit="$(cnt "$work/pred_wrap.hex" "$work/mut_addwrap.tok")"
  mis_mut="$(cnt "$work/gold.hex" "$work/mut_addwrap.tok")"
  tb_fail=0; grep -q '^RESULT: FAIL' "$work/mut_addwrap.out" && tb_fail=1
  echo "[$TAG] MUT[addwrap]: 突变体 vs 回绕预测 MISMATCH=$hit（期望 0=精确命中）  vs 黄金 MISMATCH=$mis_mut（期望 >0=$dm）  装置自报FAIL=$tb_fail（期望 1）"
  if [ "$hit" != "0" ]; then
    echo "[$TAG] RESULT: FAIL（负对照[addwrap]没精确命中回绕预测：$hit）⇒ 这条判据口径对不上突变"; return 2
  fi
  if ! [ "$mis_mut" -gt 0 ] 2>/dev/null; then
    echo "[$TAG] RESULT: FAIL（负对照[addwrap]没发火：clamp 关了输出却没变）⇒ 判据是橡皮章"; return 2
  fi
  if [ "$tb_fail" != "1" ]; then
    echo "[$TAG] RESULT: FAIL（突变体下装置没报 FAIL）⇒ 装置自检没接在回路上"; return 2
  fi
  echo "[$TAG] NEG_OK[addwrap]: 突变体输出 == 回绕预测（逐字节 0 差）且 != 黄金（差 $mis_mut 字节 = 越界点数 $dm ... 见上）⇒ 这一发真被抓住"

  # -------------------------------------------------------------------------
  # 6) 参数自报：+IW 与网表 imgW 不符 ⇒ time 0 $fatal
  # -------------------------------------------------------------------------
  echo "---- [$TAG] 6) 参数自报：+IW=$((W+1))（与网表 imgW=$W 不符）⇒ 装置必须 \$fatal ----"
  ( cd "$work" && "$VVP" dut.vvp "+XFILE=$work/ab.hex" "+YFILE=$work/gold.hex" \
      "+OP=add" "+C=$C" "+IW=$((W+1))" "+H=$H" ) > "$work/badw.out" 2>&1
  local badw_rc=$?
  if [ "$badw_rc" -eq 0 ] || ! grep -q 'TB-ERROR: 网表自报' "$work/badw.out"; then
    echo "[$TAG] RESULT: FAIL（+IW 不符但装置没在 time 0 报红，rc=$badw_rc）⇒ 参数自报没接在回路上"; return 2
  fi
  echo "[$TAG] NEG_OK[自报]: +IW 不符 ⇒ 装置 time 0 报红（vvp rc=$badw_rc）"

  # -------------------------------------------------------------------------
  # 7) 张冠李戴（两个方向：运行期 +OP，与编译期端口名）
  # -------------------------------------------------------------------------
  echo "---- [$TAG] 7) 张冠李戴：双输入网表跑 +OP=sigmoid ⇒ 装置必须 \$fatal（互锁）----"
  ( cd "$work" && "$VVP" dut.vvp "+XFILE=$work/ab.hex" "+YFILE=$work/gold.hex" \
      "+OP=sigmoid" "+C=$C" "+IW=$W" "+H=$H" ) > "$work/wrongop.out" 2>&1
  local wo_rc=$?
  if [ "$wo_rc" -eq 0 ] || grep -q '^RESULT: PASS' "$work/wrongop.out"; then
    echo "[$TAG] RESULT: FAIL（+OP=sigmoid 配双输入网表竟然还是 PASS）⇒ 算子/网表绑定没判据"
    grep -E '^(RESULT|TB-ERROR|TB-INFO)' "$work/wrongop.out" | head -5; return 2
  fi
  echo "[$TAG] NEG_OK[张冠李戴/运行期]: +OP=sigmoid ⇒ 装置不 PASS（rc=$wo_rc，$(grep -E '^TB-ERROR' "$work/wrongop.out" | head -1))"
  echo "---- [$TAG] 7b) 张冠李戴/编译期：单输入网表（SigmoidUnit）+ 双输入档 ⇒ iverilog 必须报错 ----"
  if "$IVERILOG" -g2012 -DBP_NCI="$C" -DBP_NW="$W" -DBP_MOD=SigmoidUnit -DBP_TWO_IN -DBP_NOCLK \
        -o "$work/cross.vvp" "$tb" "$gen/SigmoidUnit.v" > "$work/cross.log" 2>&1; then
    echo "[$TAG] RESULT: FAIL（把单输入网表接到双输入档竟然编译过了）⇒ 端口绑定没判据"; return 2
  fi
  echo "[$TAG] NEG_OK[张冠李戴/编译期]: $(grep -m1 -i 'error' "$work/cross.log" | sed 's/^ *//')"

  # -------------------------------------------------------------------------
  # 8) 单边停住：+STALLB=1（x_b_valid 恒 0）⇒ 一列不吃、一颗不出
  #    ⚠ 这条是"消费/y_valid 同时看两路 valid"的**唯一**判据（正常跑两路 always 同拍齐）。
  # -------------------------------------------------------------------------
  echo "---- [$TAG] 8) 单边停住：+STALLB=1（B 路 valid 恒 0）⇒ 装置必须 PASS 且 0 列 / 0 颗 ----"
  run_add stallb dut.vvp "$work/gold.hex" "+STALLB=1" || true
  local sb_i sb_n
  sb_i="$(sed -n 's/.*喂入 \([0-9]*\) 列.*/\1/p' "$work/stallb.out" | head -1)"
  sb_n="$(sed -n 's/.*采集 \([0-9]*\) 颗像素.*/\1/p' "$work/stallb.out" | head -1)"
  echo "[$TAG] STALLB: 喂入=$sb_i（期望 0） 采集=$sb_n（期望 0）  $(grep -E '^RESULT:' "$work/stallb.out" | head -1)"
  if ! grep -q '^RESULT: PASS' "$work/stallb.out"; then
    echo "[$TAG] RESULT: FAIL（+STALLB=1 下装置没 PASS ⇒ B 路停了 DUT 还在吃/吐）"; return 2
  fi
  if [ "$sb_i" != "0" ] || [ "$sb_n" != "0" ]; then
    echo "[$TAG] RESULT: FAIL（+STALLB=1 下 DUT 吃了 $sb_i 列 / 出了 $sb_n 颗，期望都是 0）⇒ 消费/y_valid 没同时看两路 valid"
    return 2
  fi
  echo "[$TAG] NEG_OK[单边停住]: B 路 valid 恒 0 ⇒ DUT 一列不吃、一颗不出（y_valid/消费确实看两路）"

  echo "[$TAG] CASE = OK（正对照 MISMATCH=0 / 负对照[addwrap]精确命中且差 $mis_mut 字节 / 单边停住 / 自检 + 自报 + 张冠李戴全发火）"
  return 0
}

# ===========================================================================
# judge_sigmoid <TAG> <W> <H> <网表> <模块名>
#   SigmoidUnit 的一整套判据（见文件头 §Sigmoid）。返回 0/1/2/3 同上。
# ===========================================================================
judge_sigmoid() {
  local TAG="$1" W="$2" H="$3" nl="$4" mod="$5"
  local work; work="$(mktemp -d)"; WORKDIRS+=("$work")

  echo "--------------------------------------------------------------------------"
  echo "==== [$TAG] op=sigmoid（int8 Q3.4 -> int8 Q0.7，256 项查表） C=$C W=$W H=$H  网表=$nl  模块=$mod ===="

  # -------------------------------------------------------------------------
  # 0) 向量（码点扫描，覆盖全 256）+ **从导出的 .hex 读表**算黄金 + 表不对称前提
  # -------------------------------------------------------------------------
  local vecout="$work/vec.log"
  if ! "$PY" - "$work" "$gen" "$C" "$W" "$H" > "$vecout" 2>&1 <<'PYEOF'
import sys
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass
work, gen, C, W, H = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5])

def i8(v):
    v &= 0xFF
    return v - 256 if v >= 128 else v

# 本闸门自己的码点扫描（与 bypass_ref.sigmoid_sweep 的乘子不同；181 与 256 互素 ⇒ 前 256 个是排列）
n = C * W * H
assert n >= 256, "C*W*H=%d < 256 ⇒ 覆盖不满 int8 全部码点" % n
sv = [i8(j * 181 + 59) for j in range(n)]
assert len(set(sv[:256])) == 256, "前 256 个位置不是 0..255 的排列 ⇒ 覆盖不满"
assert len(set(sv)) == 256, "整条流只覆盖 %d 个码点（期望 256）" % len(set(sv))

# ★ 黄金来自**导出的表文件**（不是 bypass_ref 的内存 LUT）⇒ 与"RTL 的 .bin"是同一条链上的两份拷贝
toks = open(gen + "/sigmoid_lut.hex", encoding="utf-8", errors="replace").read().split()
assert len(toks) == 256, "导出的 LUT 有 %d 项（期望 256）" % len(toks)
lut = [i8(int(t, 16)) for t in toks]
assert all(0 <= v <= 127 for v in lut), "表里有值越出 [0,127]（sigmoid 的值域不该越界）"
gold = [lut[(v + 128) & 0xFF] for v in sv]
assert len(set(gold)) > 1, "黄金是常数 ⇒ 判据会退化"

# 负对照 D 的前提：表在 x -> -x 下**不对称**（否则"地址取反"不可观测）
fixed = [x for x in range(-128, 128) if lut[(x + 128) & 0xFF] == lut[((-x) + 128) & 0xFF]]
assert len(fixed) == 2, "表在 x->-x 下的不动点有 %d 个（期望 2：x=0 与 x=-128）" % len(fixed)
# 地址取反后**变值的码点数**（= 256 - 2 个不动点）与**变值的字节数**（随向量长度变，重复码点要重复计）
diff_codes = len([x for x in range(-128, 128) if lut[(x + 128) & 0xFF] != lut[((-x) + 128) & 0xFF]])
exp_mut_bytes = sum(1 for v in sv if v not in fixed)

def dump(path, toks_):
    with open(path, "w", encoding="ascii", newline="\n") as fh:
        fh.write("".join("%02x\n" % (v & 0xFF) for v in toks_))

dump(work + "/sv.hex", sv)
dump(work + "/naive.hex", gold)
assert diff_codes == 254, "变值码点数 %d != 254" % diff_codes
print("VEC: C=%d W=%d H=%d | 输入 %d 字节（覆盖 256 个码点）| 黄金来自 %s/sigmoid_lut.hex | "
      "表在 x->-x 下不对称：**%d 个码点变值** / 不动点=%s | EXPECT_MUT_BYTES=%d"
      % (C, W, H, len(sv), gen, diff_codes, fixed, exp_mut_bytes))
PYEOF
  then
    echo "[$TAG] FATAL: 向量/覆盖/不对称前提不成立（或 gen/sigmoid_lut.hex 缺失/不合法）⇒ 用例没意义"
    sed -n '1,5p' "$vecout"; return 3
  fi
  cat "$vecout"
  local expmut
  expmut="$(sed -n 's/.*EXPECT_MUT_BYTES=\([0-9]*\).*/\1/p' "$vecout" | tail -1)"
  if [ -z "$expmut" ] || [ "$expmut" -le 0 ] 2>/dev/null; then
    echo "[$TAG] FATAL: 没拿到 EXPECT_MUT_BYTES ⇒ 用例自检输出被改了"; return 3
  fi

  # -------------------------------------------------------------------------
  # 1) 参考出黄金 + 与"从文件读表"的黄金交叉对账 + 地址取反预测
  # -------------------------------------------------------------------------
  echo "---- [$TAG] 1) bypass_ref.py sigmoid 出黄金（内存 LUT 路径）+ 与'从 .hex 读表'交叉对账 ----"
  if ! "$PY" "$ref" sigmoid "$C" "$W" "$H" --infile="$work/sv.hex" > "$work/gold.hex" 2> "$work/ref.err"; then
    echo "[$TAG] FATAL: bypass_ref 出黄金失败"; cat "$work/ref.err"; return 3
  fi
  if ! "$PY" "$ref" sigmoid "$C" "$W" "$H" --infile="$work/sv.hex" --mutate=invert > "$work/pred_inv.hex" 2>/dev/null; then
    echo "[$TAG] FATAL: 出地址取反突变体预测失败"; return 3
  fi
  local refchk dm
  refchk="$(cnt "$work/naive.hex" "$work/gold.hex")"
  dm="$(cnt "$work/gold.hex" "$work/pred_inv.hex")"
  echo "[$TAG] REF_XCHK=$refchk（期望 0：bypass_ref 的内存表 == 从 gen/sigmoid_lut.hex 读出来的表）  MUT_PREMISE[invert]=$dm 字节（期望 $expmut：地址取反后变值的**字节数**；变值**码点数**恒为 254）"
  if [ "$refchk" != "0" ]; then
    echo "[$TAG] FATAL: 参考与'从导出文件读表'不一致 ⇒ 参考/导出文件不可信"; return 3
  fi
  if [ "$dm" != "$expmut" ]; then
    echo "[$TAG] FATAL: 地址取反影响到 $dm 个字节（期望 $expmut）⇒ 与'表不对称（254 码点变值）'的断言对不上"; return 3
  fi

  # -------------------------------------------------------------------------
  # 2) 编译（无 clk/reset 档）+ 正对照（含装置自己的 LUT-XCHK / LUT-CODES）
  # -------------------------------------------------------------------------
  echo "---- [$TAG] 2) iverilog 编译（-DBP_NCI=$C -DBP_NW=$W -DBP_MOD=$mod -DBP_NOCLK）----"
  if [ ! -f "$nl" ]; then echo "[$TAG] JUDGE-RED: 网表不存在：$nl（先跑 sbt 生成步骤）"; return 1; fi
  # ★ 网表靠 `initial $readmemb("<网表名>.v_toplevel_lut.bin", lut)` 载入表 ⇒ 那个文件是**运行期依赖**，
  #   且路径是**相对**的 ⇒ 必须躺在本装置的 CWD（$work）里。缺了它 vvp 只发 warning、lut 全 X。
  local bin; bin="$(dirname "$nl")/$(basename "$nl")${LUT_BIN_SUFFIX}"
  if [ ! -f "$bin" ]; then
    echo "[$TAG] JUDGE-RED: 找不到 RTL 的表初值文件 $bin（缺了它网表跑出来全是 X）"; return 1
  fi
  cp "$bin" "$work/"
  if ! "$IVERILOG" -g2012 -DBP_NCI="$C" -DBP_NW="$W" -DBP_MOD="$mod" -DBP_NOCLK \
        -o "$work/dut.vvp" "$tb" "$nl" > "$work/iv.log" 2>&1; then
    echo "[$TAG] JUDGE-RED: iverilog 编译失败"; sed -n '1,30p' "$work/iv.log"; return 1
  fi

  run_sig() { # <tag> <vvp> <yfile>
    local tag="$1" vvp="$2" yf="$3"
    ( cd "$work" && "$VVP" "$vvp" \
        "+XFILE=$work/sv.hex" "+YFILE=$yf" "+LUTFILE=$gen/sigmoid_lut.hex" \
        "+OP=sigmoid" "+C=$C" "+IW=$W" "+H=$H" ) > "$work/$tag.out" 2>&1
    tok_of "$work/$tag.out" "$work/$tag.tok"
    return 0
  }

  local rc=0 mis
  run_sig pos dut.vvp "$work/gold.hex" || rc=$?
  mis="$(cnt "$work/gold.hex" "$work/pos.tok")"
  echo "[$TAG] MISMATCH=$mis   （vvp rc=$rc）"
  grep -E '^TB-INFO: LUT-XCHK' "$work/pos.out" | sed "s/^/[$TAG] /"
  if ! grep -q '^RESULT: PASS' "$work/pos.out"; then
    echo "[$TAG] JUDGE-RED: 正对照装置未 PASS"
    grep -E '^(RESULT|TB-ERROR|TB-INFO|MISMATCH)' "$work/pos.out" | head -10
    return 1
  fi
  if [ "$rc" -ne 0 ]; then echo "[$TAG] JUDGE-RED: 正对照 vvp 非 0 退出（$rc）"; return 1; fi
  if [ "$mis" != "0" ]; then
    echo "[$TAG] JUDGE-RED: 正对照与黄金差 $mis 个字节 ⇒ 硬件与参考不符"; return 1
  fi
  # ★ 装置**自己**（$readmemh 载入 gen/sigmoid_lut.hex）的对账：这是"RTL 的表 vs 导出的表"的第二条独立链
  if ! grep -q 'LUT-XCHK=0' "$work/pos.out"; then
    echo "[$TAG] JUDGE-RED: 装置侧查表对账 LUT-XCHK != 0 ⇒ RTL 的表/取址与 gen/sigmoid_lut.hex 不一致"; return 1
  fi
  if ! grep -q 'LUT-CODES=256' "$work/pos.out"; then
    echo "[$TAG] JUDGE-RED: 本跑没覆盖满 256 个码点（装置报的 LUT-CODES != 256）"; return 1
  fi
  echo "[$TAG] 正对照 PASS：MISMATCH=0 + 装置自算 LUT-XCHK=0 + 覆盖 256 个码点（全码点穷举）"
  echo "  Y = $(head -c 160 "$work/pos.tok" | tr '\n' ' ') ..."

  # -------------------------------------------------------------------------
  # 3) 比较器自检（三分支）
  # -------------------------------------------------------------------------
  echo "---- [$TAG] 3) 比较器自检：扰动黄金 1 个 token ⇒ 恰好 1 / 长度不等 / 缺文件 ----"
  "$PY" - "$work/gold.hex" "$work/gold_pert.hex" <<'PYEOF'
import sys
t = open(sys.argv[1], encoding="utf-8", errors="replace").read().split()
i = len(t) // 2
t[i] = "%02x" % ((int(t[i], 16) ^ 0x01) & 0xFF)
open(sys.argv[2], "w", encoding="ascii", newline="\n").write("\n".join(t) + "\n")
print("CMP_SELFTEST_PERTURB idx=%d" % i)
PYEOF
  local cs cs_len cs_miss N
  cs="$(cnt "$work/gold_pert.hex" "$work/pos.tok")"
  N="$(wc -w < "$work/gold.hex" | tr -d ' ')"
  "$PY" - "$work/gold.hex" "$work/gold_short.hex" 3 <<'PYEOF'
import sys
t = open(sys.argv[1], encoding="utf-8", errors="replace").read().split()
open(sys.argv[2], "w", encoding="ascii", newline="\n").write("\n".join(t[:-3]) + "\n")
PYEOF
  cs_len="$(cnt "$work/gold_short.hex" "$work/pos.tok")"
  cs_miss="$(cnt "$work/definitely_missing.hex" "$work/pos.tok")"
  echo "[$TAG] CMP_SELFTEST 扰动=$cs(期望1) 长度不等=$cs_len(期望$N) 缺文件=$cs_miss(期望-1)"
  if [ "$cs" != "1" ] || [ "$cs_len" != "$N" ] || [ "$cs_miss" != "-1" ]; then
    echo "[$TAG] RESULT: FAIL（比较器自检三分支没走全）⇒ 闸门不可信"; return 2
  fi
  echo "[$TAG] NEG_OK[cmp_self]: cnt 的三条分支（扰动 1 / 长度不等 / 缺文件）都不是橡皮章"

  # -------------------------------------------------------------------------
  # 4) 装置侧自检：扰动黄金当 +YFILE ⇒ 装置必须自己报 FAIL
  # -------------------------------------------------------------------------
  echo "---- [$TAG] 4) 装置侧自检：把扰动过的黄金当 +YFILE ⇒ 装置必须 RESULT: FAIL 且非 0 ----"
  run_sig tbneg dut.vvp "$work/gold_pert.hex" || true
  if grep -q '^RESULT: PASS' "$work/tbneg.out"; then
    echo "[$TAG] RESULT: FAIL（装置拿到扰动黄金仍 PASS）⇒ 装置自检没接在回路上"; return 2
  fi
  if ! grep -q '^RESULT: FAIL' "$work/tbneg.out"; then
    echo "[$TAG] RESULT: FAIL（装置既没 PASS 也没 FAIL？）"; sed -n '1,10p' "$work/tbneg.out"; return 2
  fi
  echo "[$TAG] NEG_OK[tb_self]: 扰动黄金 ⇒ 装置自己报 FAIL 并 \$fatal（非 0 退出）"

  # -------------------------------------------------------------------------
  # 5) 负对照 D（查表地址取反 = 把 x 换成 -x）
  # -------------------------------------------------------------------------
  echo "---- [$TAG] 5) 负对照[siginv]：lutIdx := 0 - lutIdx（x -> -x）⇒ 必须精确命中预测、且 != 黄金 ----"
  if ! mut_make2 siginv "$nl" "$work/mut_siginv.v" "$C"; then
    echo "[$TAG] RESULT: FAIL（构造突变网表失败：生成风格变了，请更新本判据）⇒ 闸门不可信"; return 2
  fi
  if cmp -s "$nl" "$work/mut_siginv.v"; then
    echo "[$TAG] RESULT: FAIL（突变网表与原文相同）⇒ 闸门不可信"; return 2
  fi
  if ! "$IVERILOG" -g2012 -DBP_NCI="$C" -DBP_NW="$W" -DBP_MOD="$mod" -DBP_NOCLK \
        -o "$work/mut_siginv.vvp" "$tb" "$work/mut_siginv.v" > "$work/iv_mut.log" 2>&1; then
    echo "[$TAG] RESULT: FAIL（突变网表编译失败）"; sed -n '1,20p' "$work/iv_mut.log"; return 2
  fi
  run_sig mut_siginv "mut_siginv.vvp" "$work/gold.hex" || true
  local hit mis_mut tb_fail
  hit="$(cnt "$work/pred_inv.hex" "$work/mut_siginv.tok")"
  mis_mut="$(cnt "$work/gold.hex" "$work/mut_siginv.tok")"
  tb_fail=0; grep -q '^RESULT: FAIL' "$work/mut_siginv.out" && tb_fail=1
  echo "[$TAG] MUT[siginv]: 突变体 vs 取反预测 MISMATCH=$hit（期望 0=精确命中）  vs 黄金 MISMATCH=$mis_mut（期望 $expmut）  装置自报FAIL=$tb_fail（期望 1）"
  if [ "$hit" != "0" ]; then
    echo "[$TAG] RESULT: FAIL（负对照[siginv]没精确命中取反预测：$hit）⇒ 这条判据口径对不上突变"; return 2
  fi
  if [ "$mis_mut" != "$expmut" ]; then
    echo "[$TAG] RESULT: FAIL（负对照[siginv]与黄金差 $mis_mut 个字节，期望 $expmut=向量里非不动点码点的字节数）"; return 2
  fi
  if [ "$tb_fail" != "1" ]; then
    echo "[$TAG] RESULT: FAIL（突变体下装置没报 FAIL）⇒ 装置自检没接在回路上"; return 2
  fi
  echo "[$TAG] NEG_OK[siginv]: 突变体输出 == 取反预测（0 差）且 != 黄金（254 个码点变值，与'表不对称'的断言一致）⇒ 这一发真被抓住"

  # -------------------------------------------------------------------------
  # 6) 参数自报：+IW 与网表 imgW 不符 ⇒ time 0 $fatal
  # -------------------------------------------------------------------------
  echo "---- [$TAG] 6) 参数自报：+IW=$((W+1))（与网表 imgW=$W 不符）⇒ 装置必须 \$fatal ----"
  ( cd "$work" && "$VVP" dut.vvp "+XFILE=$work/sv.hex" "+YFILE=$work/gold.hex" \
      "+LUTFILE=$gen/sigmoid_lut.hex" "+OP=sigmoid" "+C=$C" "+IW=$((W+1))" "+H=$H" ) > "$work/badw.out" 2>&1
  local badw_rc=$?
  if [ "$badw_rc" -eq 0 ] || ! grep -q 'TB-ERROR: 网表自报' "$work/badw.out"; then
    echo "[$TAG] RESULT: FAIL（+IW 不符但装置没在 time 0 报红，rc=$badw_rc）⇒ 参数自报没接在回路上"; return 2
  fi
  echo "[$TAG] NEG_OK[自报]: +IW 不符 ⇒ 装置 time 0 报红（vvp rc=$badw_rc）"

  # -------------------------------------------------------------------------
  # 7) 张冠李戴：sigmoid 网表跑 +OP=maxpool（端口同名同宽 ⇒ 只能靠输出颗数/结构特征分辨）
  # -------------------------------------------------------------------------
  echo "---- [$TAG] 7) 张冠李戴：同一网表跑 +OP=maxpool ⇒ 装置必须不 PASS ----"
  ( cd "$work" && "$VVP" dut.vvp "+XFILE=$work/sv.hex" "+YFILE=$work/gold.hex" \
      "+OP=maxpool" "+C=$C" "+IW=$W" "+H=$H" ) > "$work/wrongop.out" 2>&1
  local wo_rc=$?
  if [ "$wo_rc" -eq 0 ] || grep -q '^RESULT: PASS' "$work/wrongop.out"; then
    echo "[$TAG] RESULT: FAIL（+OP=maxpool 配 sigmoid 网表竟然还是 PASS）⇒ 算子/网表绑定没判据"
    grep -E '^(RESULT|TB-ERROR|TB-INFO)' "$work/wrongop.out" | head -5; return 2
  fi
  echo "[$TAG] NEG_OK[张冠李戴]: +OP=maxpool ⇒ 装置不 PASS（rc=$wo_rc，$(grep -E '^TB-ERROR' "$work/wrongop.out" | head -1))"

  echo "[$TAG] CASE = OK（正对照 MISMATCH=0 + LUT-XCHK=0 + 256 码点 / 负对照[siginv]精确命中且差 $mis_mut 字节 / 自检 + 自报 + 张冠李戴全发火）"
  return 0
}

# ===========================================================================
# 四个算子 x 两个形状（见文件头；两个形状里各有一个**非 2 的幂**的档）
# ===========================================================================
rc=0
judge_case "maxpool-w4" maxpool 4 4 "$gen/MaxPoolUnit.v"    MaxPoolUnit    || rc=$?
if [ "$rc" -eq 0 ]; then judge_case "maxpool-w6" maxpool 6 6 "$gen/MaxPoolUnit_w6.v" MaxPoolUnit || rc=$?; fi
if [ "$rc" -eq 0 ]; then judge_case "resize-w4"  resize  4 4 "$gen/ResizeUnit.v"     ResizeUnit  || rc=$?; fi
if [ "$rc" -eq 0 ]; then judge_case "resize-w6"  resize  6 6 "$gen/ResizeUnit_w6.v"  ResizeUnit  || rc=$?; fi
# C3.7：Add（双输入饱和加）—— 形状 2 用 W=5 且 **H=3（奇数）**：逐点算子没有行对结构，
#       奇数 H 合法（装置的偶数 H 硬约束只对 maxpool/resize 生效，这一档就是来证明放宽是真的）。
if [ "$rc" -eq 0 ]; then judge_add     "add-w4-h4"  4 4  "$gen/AddUnit.v"       AddUnit     || rc=$?; fi
if [ "$rc" -eq 0 ]; then judge_add     "add-w5-h3"  5 3  "$gen/AddUnit_w5.v"    AddUnit     || rc=$?; fi
# C3.7：Sigmoid（Q3.4 -> Q0.7 查表）—— 两档都要**跑满 256 个码点**（装置报 LUT-CODES=256）。
if [ "$rc" -eq 0 ]; then judge_sigmoid "sigmoid-w4" 4 32 "$gen/SigmoidUnit.v"    SigmoidUnit || rc=$?; fi
if [ "$rc" -eq 0 ]; then judge_sigmoid "sigmoid-w6" 6 32 "$gen/SigmoidUnit_w6.v" SigmoidUnit || rc=$?; fi

if [ "$rc" -ne 0 ]; then
  echo "=========================================================================="
  echo "RESULT: FAIL（用例判据未全过，见上；退出码 $rc）"
  exit "$rc"
fi
if [ "$dangle_ok" != "1" ]; then
  echo "=========================================================================="
  echo "RESULT: FAIL（结构判据：有悬空实例）"
  exit 1
fi
if [ "$lut_ok" != "1" ]; then
  echo "=========================================================================="
  echo "RESULT: FAIL（LUT 指纹：gen/sigmoid_lut.hex 不确定 / 或与 RTL 的 Mem 初值(.bin)、冻结公式对不上）"
  exit 1
fi

# ---------------- 收口 ----------------
echo "=========================================================================="
echo "MaxPool(2x2/s2 int8 取最大) + Resize(x2 最近邻) + Add(双输入 int8 **饱和**加) + Sigmoid(Q3.4->Q0.7 256 项查表)："
echo "  向量来源 = OK（闸门自己的造流公式；输入/黄金非常数；防混叠 / 两路不等 / SAT_EVENTS>0 / 256 码点覆盖全过）"
echo "  参考自检 = OK（bypass_ref --selftest：与独立朴素实现逐点一致 / 无量化 / 饱和点 / 表中点 / 不对称 / 响亮失败）"
echo "  参考交叉 = OK（bypass_ref 黄金 == 闸门独立实现；sigmoid 另与'从 gen/sigmoid_lut.hex 读表'逐字节 0 差）"
echo "  LUT 指纹 = OK（重生成两次 md5 一致且与 gen/ 那份逐字节相同；--lutfile/--lutbin 各 256 项逐项 == 冻结公式）"
echo "  RTL 的表 = OK（SpinalHDL 的 Mem.init 走 \$readmemb 载 .bin ⇒ 表是**运行期从文件载入**的，非硬编码常量）"
echo "  正对照   = OK（4 算子 x 2 形状：装置输出逐字节一致，MISMATCH=0；sigmoid 另有装置侧 LUT-XCHK=0 + 256 码点）"
echo "  负对照 A = OK（MaxPool 窗口改'恒取左上角' ⇒ 精确命中突变预测且 != 黄金，装置报 FAIL）"
echo "  负对照 B = OK（Resize dy 行手取反 / dx 源列配对取反，各自精确命中且 != 黄金，装置报 FAIL）"
echo "  负对照 C = OK（Add 把 clamp 关掉 ⇒ 饱和变回绕，精确命中回绕预测且 != 黄金，装置报 FAIL）"
echo "  负对照 D = OK（Sigmoid 查表地址取反 = 把 x 换成 -x，精确命中预测且 254/256 码点变值，装置报 FAIL）"
echo "  单边停住 = OK（Add 的 x_b_valid 恒 0 ⇒ 一列不吃、一颗不出：消费/y_valid 确实看两路 valid）"
echo "  装置自检 = OK（扰动黄金 ⇒ 装置自己 FAIL；+IW 不符 ⇒ time 0 \$fatal；+OP 配错网表 ⇒ 不 PASS/编译期报错）"
echo "  比较器   = OK（扰动 1 / 长度不等 / 缺文件 三分支）"
echo "  结构     = OK（check_dangling.py：八个网表零悬空）"
echo "RESULT: PASS"
exit 0
