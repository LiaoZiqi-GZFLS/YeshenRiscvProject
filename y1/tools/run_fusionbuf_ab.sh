#!/usr/bin/env bash
# run_fusionbuf_ab.sh —— y1 C3.5 的闸门：**行流式融合缓冲**（`rtl/FusionBuf.scala` ⇒ `gen/FusionBuf*.v`）
#   的功能判据（3 行环形窗口、**可寻址 RAM 结构**、读写都"一拍一整列"）。
#
# 为什么需要它：C3.0（`reports/c3_fusion_buffer.md` §4）判定 `fuse_both` 的中间张量必须**行流式**，
#   且同一份 3 行窗口**必须落 RAM 结构**（按 FF 是 30,720 x 8 = 245,760 > 空闲 215,004；且 PDS
#   忽略 `ram_style`）。本闸门只证**功能**："真的落 DRM"由后续 S5 面积闸门证。判据全部**独立**算
#   （python 环形模型），绝不盲信装置自报的 PASS。
#
# ★ **两个形状**（都是 C=2；专治"只仿过 WIDTH=4 这一档"的盲区）：
#     形状 small：C=2 / WIDTH=4  / CW=2  → gen/FusionBuf.v      （默认档，也是 md5 指纹目标）
#     形状 w5   ：C=2 / WIDTH=5  / CW=3  → gen/FusionBuf_w5.v   （**非 2 的幂列宽**：log2Up 寻址、
#                                                            WORDS=15、aw=4，覆盖列的"非 2 的幂"这条路）
#   两形状各跑**一整套**正对照 + 三条负对照 + 比较器自检 + 参数自报；任一形状发火 ⇒ 整体非 0。
#   （WIDTH=1 与更大 C 仍未仿真：装置端口名 rd_data_0/1 不可参数化 ⇒ C 只能 2。**已知残留风险**，
#    已在 rtl_test/FusionBufTb.v 头部显式写明。）
#
# ============================== 消费者契约（与 rtl/FusionBuf.scala 文件头逐条一致） ==============================
#   (1) 读延迟 = 1 拍（同步读）：第 T 拍给 `(rd_row, rd_col)`，第 T+1 拍 `rd_data` 才有效。
#   (2) 同址"读写同拍"读到**旧值**（本站 RTL 的性质）；但 Pango DRM 同步读可能**写透** ⇒ 消费侧
#       必须避免读"本拍正在写的那一格"（别用 rd_row=0 读正在写的 R）。
#   (3) 推进边界：`wr_row_adv && wr_col==WIDTH-1` 那一拍 row_ptr **尚未**翻转 ⇒ **与该推进同拍**发出的读
#       看到的是推进前（老一行）的窗口（同拍 rd_row=2 得 R-2，下一拍才得 R-1）。
#   (4) 本模块**不另开** `rd_rows_valid` 端口（C3.5 端口已冻结）：完成度由生产侧自己的节拍给出；
#       安全用法 = `rd_row=1,2` 恒为已整行完成的行，`rd_row=0` 只在**行间**用。
#   本装置每笔读与写分开摆拍（do_read 固定两拍），故不踩 (3) 的边界；三相位读都在**行间**发起。
#
# 判据（正 + 三条负对照 + 比较器自检 + 参数自报；**每个形状各来一遍**）：
#   0) **向量来源 + 非退化前提**：python 用 `f(r,c,ci)=(r*W+c)*C+ci-64`（对任意 C,W 逐位可区分）造图，
#      独立环形模型算三份期望。显式断言：
#        · `H > 3`（否则"整张 = 一个窗口"，行流式退化成无意义）；
#        · `H % 3 != 0`（收尾 row_ptr = H mod 3 != 0 —— 负对照 A2 的**非空性显式前提**，不再是隐含依赖）；
#        · **相邻行内容两两不同**（一行移位必改变窗口）；
#        · 像素值对 (row,col,ci) **两两不同**（行/列/通道串了立刻显形）；
#        · `rows_live=3 ∉ (C, W)`（C3.0 §5 的 test-pattern collision 类别：窗口深度不与 C/W 混叠）；
#        · **窗口对"整行移位"敏感**（rd_row 三档内容两两不同）⇒ 不是周期性图案把整行移位吞掉。
#   1) **正对照**：装置 `RESULT: PASS`，且 STALE / PARTIAL / WIN **三相**都与 python 期望逐字节一致
#      （`MISMATCH=0`）。
#   2) **负对照 A（陈旧行 / 未写过位置 = 复位值 0）**：
#        · A1（复位态）：复位后、任何写之前读回 ⇒ 全 0；把网表的 Mem **初值块删掉** ⇒ 未写过位置变 X
#          ⇒ STALE 判据必须发火；**且 WIN 必须保持与黄金一致**（证明这发突变是**外科式**：只动了
#          "未写过位置"的初值，已写行全不受影响）。
#        · A2（环形行指针不把旧行当新行）：只写 2 行后读回，"最老"那一档落在**从未写过的物理槽** ⇒
#          必须读 0；把网表的 `rd_sum` 里 `row_ptr` 那一项**去掉**（读地址不再随环号转）⇒ 该档必须
#          读到已写行的数据 ⇒ 判据必须发火。
#   3) **负对照 B（行序：把 wr_row_adv 提前一行）**：多加一次行指针推进（`+ADV_EARLY=1`）⇒ 窗口整体
#      错一行。判据：装置 WIN == python 的**"提前一行"预测值**（精确命中）**且** != 黄金 WIN。
#   4) **参数自报**：`+C` 与网表自报 `imgC` 不符 ⇒ 装置 time 0 `$fatal`（非 0 退出）。
#   5) **比较器自检**：扰动黄金 WIN 的一个期望字节 ⇒ 逐字节对账必须报**恰好 1**；**长度不等**⇒
#      必须报"较长者长度"；**文件缺失** ⇒ 必须报 -1（把 `cnt` 的三条分支都走到）。
#
# 退出码：
#   0 = 全过（**两个形状**各自正对照三相逐字节 + 三条负对照全发火 + 参数自报 + 比较器三分支）
#   1 = 对账不符 / 编译或仿真失败 / 装置未 PASS
#   2 = 负对照没发火，或比较器自检不过 ⇒ **闸门自身不可信**（橡皮图章）
#   3 = 向量/维度自检失败（用例写错）
#
# 装置契约（rtl_test/FusionBufTb.v + gen/FusionBuf*.v，形状由编译期宏 -DFB_NW/-DFB_CW 决定）：
#   +XFILE= +STALEFILE= +PARTIALFILE= +WINFILE= +C= +W= +H= [+ADV_EARLY=1]
#   装置打印三行 `STALE <hh> ...` / `PARTIAL <hh> ...` / `WIN <hh> ...`（展平顺序 [rd_row][rd_col][ci]）
#   再一行 `RESULT: PASS|FAIL`（FAIL ⇒ $fatal ⇒ vvp 非 0）。
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
tb="$here/../rtl_test/FusionBufTb.v"

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

# 每个形状一个临时目录；统一在 EXIT 时清理（KEEP_TMP=1 则保留并打印）。
WORKDIRS=()
cleanup() {
  if [ "${KEEP_TMP:-0}" = "1" ]; then
    echo "KEEP_TMP=1 => 向量与日志留在: ${WORKDIRS[*]:-<无>}"
  else
    for d in ${WORKDIRS[@]+"${WORKDIRS[@]}"}; do rm -rf "$d"; done
  fi
}
trap cleanup EXIT

# cnt <golden-file> <token-file> -> 不符字节数（长度不等取较长者；任一侧缺失 = -1）
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

echo "== run_fusionbuf_ab: 行流式融合缓冲 FusionBuf（3 行环窗 / 可寻址 RAM 结构 / 一拍一整列） =="
echo "   tb =$tb"
echo "   py =${PY:-<找不到>}  iverilog=${IVERILOG:-<找不到>}  vvp=${VVP:-<找不到>}"

# ===========================================================================
# judge_shape <TAG> <C> <W> <CW> <H> <NL>
#   对一个形状跑**整套**判据。返回 0=全过 / 1=判据红 / 2=闸门不可信 / 3=用例写错。
# ===========================================================================
judge_shape() {
  local TAG="$1" C="$2" W="$3" CW="$4" H="$5" nl="$6"
  local work; work="$(mktemp -d)"; WORKDIRS+=("$work")

  echo "=========================================================================="
  echo "== [$TAG] 形状 C=$C W=$W（CW=$CW 位列地址）H=$H  nl=$nl"
  echo "   tmp=$work"
  echo "=========================================================================="

  if [ ! -f "$nl" ]; then echo "[$TAG] FATAL: 找不到网表 $nl（先跑 sbt 生成 FusionBufGen）"; return 1; fi
  if [ ! -f "$tb" ]; then echo "[$TAG] FATAL: 找不到装置 $tb"; return 1; fi
  if [ -z "$PY" ] || [ -z "$IVERILOG" ] || [ -z "$VVP" ]; then
    echo "[$TAG] FATAL: 找不到 python / iverilog / vvp"; return 1
  fi

  # -------------------------------------------------------------------------
  # 0) 向量来源 + 非退化前提 + python 环形模型（三份期望 + "提前一行"的预测值）
  # -------------------------------------------------------------------------
  echo "---- [$TAG] 0) 造向量 + 非退化自检 + python 环形模型 ----"
  if ! "$PY" - "$work" "$C" "$W" "$H" <<'PYEOF'
import sys
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

work, C, W, H = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])

# ---- 维度边界（与装置 localparam / 网表一致）----
if not (1 <= C <= 8) or not (1 <= W <= 8) or not (3 < H <= 64):
    print("FATAL: 维度越界（C<=8 / W<=8 / 3<H<=64）")
    sys.exit(3)

def fval(r, c, ci):
    """像素值：行占 (W*C) 一档、列占 C 一档、通道占 1 一档 —— 三档互不重叠 ⇒ 对任意 C,W 都两两不同。
    （旧式子 r*16+c*4+ci 在 W=5 时 c*4+ci 会到 17 > 16 ⇒ 与 r 档撞值，故改成对 WIDTH 自适应。）"""
    v = (r * W + c) * C + ci - 64
    assert -128 <= v <= 127, "像素值出 int8 范围: %d" % v
    return v & 0xff

# ---- 非退化前提 1：H > 3（否则"整张 = 一个窗口"）----
assert H > 3, "H=%d 不大于 3 ⇒ 行流式退化" % H

# ---- 非退化前提 1b：收尾 row_ptr = H mod 3 必须 != 0（负对照 A2 的非空性**显式**前提）----
# A2 把读地址里的 row_ptr 项去掉；若收尾环号恰为 0，则"去掉与不去掉"在环号 0 上完全同址 ⇒ A2 无从发火。
# 旧版把这条交给"默认 H"隐式保证；这里显式断言，理由可见（H 必须是 3 的非倍数）。
assert (H % 3) != 0, ("H=%d ⇒ 收尾 row_ptr=%d=0 ⇒ 负对照 A2（读地址丢掉 row_ptr）在环号 0 上看不出差异"
                      " ⇒ 用例没意义（H 必须不是 3 的倍数）" % (H, H % 3))

# ---- 非退化前提 2：像素值对 (row,col,ci) 两两不同（行/列/通道串了立刻显形）----
vals = [(r, c, ci) for r in range(H) for c in range(W) for ci in range(C)]
enc = [fval(*x) for x in vals]
assert len(set(enc)) == len(enc), "像素值有撞值 ⇒ 错位可能被糊住"

# ---- 非退化前提 3：相邻行内容两两不同（一行移位必改变窗口）----
def rowbytes(r):
    return [fval(r, c, ci) for c in range(W) for ci in range(C)]
for r in range(1, H):
    assert rowbytes(r) != rowbytes(r - 1), "第 %d/%d 行内容相同" % (r - 1, r)
# 相邻三行两两不同
for r in range(2, H):
    a, b, c3 = rowbytes(r - 2), rowbytes(r - 1), rowbytes(r)
    assert len({tuple(a), tuple(b), tuple(c3)}) == 3, "相邻三行有重复"

# ---- 非退化前提 4：rows_live=3 ∉ (C, W)（不与通道/列方向周期混叠）----
assert 3 not in (C, W), "rows_live=3 与 C=%d/W=%d 混叠（C3.0 §5 的 collision 类别）" % (C, W)

# ---- python 环形模型（**独立实现**：mem[3][W][C]、row_ptr、写完一行轮转）----
mem = [[[0] * C for _ in range(W)] for _ in range(3)]
rp = 0

def frow(r):
    return [[fval(r, c, ci) for ci in range(C)] for c in range(W)]

def phase(rp_):
    """读回展平： [rd_row][rd_col][ci]，phys = (rp_ + rd_row) % 3。"""
    return [mem[(rp_ + rr) % 3][cc][ci] for rr in range(3) for cc in range(W) for ci in range(C)]

def wrow(r):
    global rp
    mem[rp] = frow(r)
    rp = (rp + 1) % 3

stale = phase(rp)                     # rp=0 且全 0 ⇒ 全 0
wrow(0); wrow(1)
partial = phase(rp)                   # 最老那一档落在从未写过的槽 ⇒ 0
for r in range(2, H):
    wrow(r)
win = phase(rp)
win_early = phase((rp + 1) % 3)       # 负对照 B：多推一次行指针后的**预测值**

# ---- 非混叠：窗口必须对"整行移位"敏感（rd_row 三档两两不同）----
blk = [win[i * W * C:(i + 1) * W * C] for i in range(3)]
assert blk[0] != blk[1] and blk[1] != blk[2] and blk[0] != blk[2], \
    "rd_row 三档内容有重复 ⇒ 整行移位会被周期性图案吞掉"
assert win != stale, "win 与全 0 相同 ⇒ 判据无意义"
assert partial != win, "partial 与 win 相同 ⇒ 相位没区别"
assert win != win_early, "win 与'提前一行'预测值相同 ⇒ 负对照 B 没意义"

def dump(path, toks):
    with open(path, "w", encoding="ascii", newline="\n") as fh:
        fh.write("".join("%02x\n" % b for b in toks))

dump(work + "/x.hex", [fval(r, c, ci) for r in range(H) for c in range(W) for ci in range(C)])
dump(work + "/exp_stale.hex", stale)
dump(work + "/exp_partial.hex", partial)
dump(work + "/exp_win.hex", win)
dump(work + "/exp_win_early.hex", win_early)
print("VEC: C=%d W=%d H=%d 图=%d 字节；每相读回 %d 字节（3 档 x %d 列 x %d 通道）"
      % (C, W, H, H * W * C, 3 * W * C, W, C))
print("VEC: 非退化 OK（H=%d>3 且 H%%3=%d!=0；相邻行两两不同；像素两两不同；3 ∉ (%d,%d)；rd_row 三档两两不同）"
      % (H, H % 3, C, W))
print("VEC: 复位态期望 = 全 0（%d 字节）；只写 2 行时最老档（物理槽 %d）期望 = 全 0" % (3 * W * C, (rp + 0) % 3))
print("VEC: partial 最老档是 0（全 %d 字节）+ 另两档是第 1/第 2 行数据" % (W * C))
print("VEC: win 与 win_early 不同（win_early = 行指针提前一行后的预测值）")
PYEOF
  then
    echo "[$TAG] FATAL: 生成向量/期望失败（或非退化断言不成立）⇒ 用例没意义"; return 3
  fi
  for f in x.hex exp_stale.hex exp_partial.hex exp_win.hex exp_win_early.hex; do
    [ -s "$work/$f" ] || { echo "[$TAG] FATAL: 向量 $f 缺失或为空"; return 3; }
  done

  # -------------------------------------------------------------------------
  # 1) 编译（装置 + 网表；形状靠宏 -DFB_NW/-DFB_CW 传进去）
  # -------------------------------------------------------------------------
  echo "---- [$TAG] 1) iverilog 编译（FusionBufTb + $nl；-DFB_NW=$W -DFB_CW=$CW）----"
  if ! "$IVERILOG" -g2012 -DFB_NW="$W" -DFB_CW="$CW" -o "$work/dut_sim.vvp" "$tb" "$nl" \
        > "$work/iv.log" 2>&1; then
    echo "[$TAG] JUDGE-RED: iverilog 编译失败"; sed -n '1,40p' "$work/iv.log"; return 1
  fi
  # 编译告警（端口位宽失配之类）也不放过：把 log 里的 warning 打出来，便于发现形状参数写错。
  if grep -qi 'warning' "$work/iv.log"; then
    echo "[$TAG] 编译告警（不致命，但需留意形状参数）："; grep -i 'warning' "$work/iv.log" | head -5
  fi
  echo "    编译 OK"

  # ---- 公共：跑一次装置；把三条打印行抓成 token 文件 ----
  # run_dut <logbase> <winfile> [extra plusargs...]
  run_dut() {
    local tag="$1" winf="$2"; shift 2
    ( cd "$work" && "$VVP" dut_sim.vvp \
        "+XFILE=$work/x.hex" "+STALEFILE=$work/exp_stale.hex" \
        "+PARTIALFILE=$work/exp_partial.hex" "+WINFILE=$winf" \
        "+C=$C" "+W=$W" "+H=$H" "$@" ) > "$work/$tag.out" 2>&1 || true
    grep '^STALE '   "$work/$tag.out" | sed -e 's/^STALE *//'   | tr -s ' ' '\n' > "$work/$tag.stale"   || true
    grep '^PARTIAL ' "$work/$tag.out" | sed -e 's/^PARTIAL *//' | tr -s ' ' '\n' > "$work/$tag.partial" || true
    grep '^WIN '     "$work/$tag.out" | sed -e 's/^WIN *//'     | tr -s ' ' '\n' > "$work/$tag.win"     || true
  }

  # -------------------------------------------------------------------------
  # 2) 正对照：三相逐字节对 python 期望
  # -------------------------------------------------------------------------
  echo "---- [$TAG] 2) 正对照：STALE / PARTIAL / WIN 三相 vs python 环形模型 ----"
  run_dut pos "$work/exp_win.hex"
  if ! grep -q '^RESULT: PASS' "$work/pos.out"; then
    echo "[$TAG] JUDGE-RED: 正对照装置未 PASS"
    grep -E '^(RESULT|TB-ERROR)' "$work/pos.out" || true
    sed -n '1,10p' "$work/pos.out"
    return 1
  fi
  local ms_stale ms_part ms_win MISMATCH=0 v
  ms_stale="$(cnt "$work/exp_stale.hex" "$work/pos.stale")"
  ms_part="$(cnt "$work/exp_partial.hex" "$work/pos.partial")"
  ms_win="$(cnt "$work/exp_win.hex" "$work/pos.win")"
  for v in "$ms_stale" "$ms_part" "$ms_win"; do
    case "$v" in ''|*[!0-9-]*) MISMATCH=-1 ;; *) MISMATCH=$(( MISMATCH + v )) ;; esac
  done
  echo "[$TAG] MISMATCH=$MISMATCH  (STALE=$ms_stale PARTIAL=$ms_part WIN=$ms_win)"
  if [ "$ms_stale" != "0" ] || [ "$ms_part" != "0" ] || [ "$ms_win" != "0" ]; then
    echo "[$TAG] JUDGE-RED: 正对照三相没全对齐"; return 1
  fi
  echo "[$TAG] 正对照 PASS：复位态/只写2行/写满 三相都与 python 环形模型逐字节一致"
  echo "  STALE   = $(head -c 200 "$work/pos.stale" | tr '\n' ' ')"
  echo "  WIN     = $(head -c 200 "$work/pos.win" | tr '\n' ' ')"

  # -------------------------------------------------------------------------
  # 3) 比较器自检：三分支（单字节扰动 / 长度不等 / 文件缺失）
  # -------------------------------------------------------------------------
  echo "---- [$TAG] 3) 比较器自检：扰动黄金 WIN 一个期望字节 ⇒ 必须报恰好 1 ----"
  "$PY" - "$work/exp_win.hex" "$work/exp_win_neg.hex" <<'PYEOF'
import sys
lines = [l.strip() for l in open(sys.argv[1]) if l.strip()]
idx = len(lines) // 2
lines[idx] = "%02x" % ((int(lines[idx], 16) ^ 0x01) & 0xFF)
open(sys.argv[2], "w").write("\n".join(lines) + "\n")
print("CMP_SELFTEST_PERTURB idx=%d" % idx)
PYEOF
  local cs cs_len cs_miss N
  cs="$(cnt "$work/exp_win_neg.hex" "$work/pos.win")"
  echo "[$TAG] CMP_SELFTEST 单字节扰动 MISMATCH=$cs（期望恰好 1）"
  if [ "$cs" != "1" ]; then
    echo "[$TAG] RESULT: FAIL（比较器自检不过：MISMATCH=$cs != 1）⇒ 闸门不可信"; return 2
  fi

  echo "---- [$TAG] 3b) 比较器自检：长度不等分支 + 文件缺失分支 - 必须都被走到 ----"
  N="$(wc -w < "$work/exp_win.hex" | tr -d ' ')"
  "$PY" - "$work/exp_win.hex" "$work/exp_win_short.hex" 3 <<'PYEOF'
import sys
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass
lines = [l.strip() for l in open(sys.argv[1]) if l.strip()]
k = int(sys.argv[3])
open(sys.argv[2], "w").write("\n".join(lines[:-k]) + "\n")
print("CMP_LENMUT: 砍掉末尾 %d 个 token（%d -> %d）" % (k, len(lines), len(lines) - k))
PYEOF
  cs_len="$(cnt "$work/exp_win_short.hex" "$work/pos.win")"
  echo "[$TAG] CMP_SELFTEST 长度不等分支 MISMATCH=$cs_len（期望 == 较长者长度 $N）"
  if [ "$cs_len" != "$N" ]; then
    echo "[$TAG] RESULT: FAIL（长度不等分支没走到：$cs_len != $N）⇒ 闸门不可信"; return 2
  fi
  cs_miss="$(cnt "$work/definitely_missing.hex" "$work/pos.win")"
  echo "[$TAG] CMP_SELFTEST 缺文件分支 MISMATCH=$cs_miss（期望 -1）"
  if [ "$cs_miss" != "-1" ]; then
    echo "[$TAG] RESULT: FAIL（缺文件分支没走到：$cs_miss != -1）⇒ 闸门不可信"; return 2
  fi
  echo "[$TAG] NEG_OK[cmp_self]: 单字节扰动=1 / 长度不等=$N / 缺文件=-1 ⇒ cnt 三分支都不是橡皮图章"

  # -------------------------------------------------------------------------
  # 4) 负对照 A：陈旧行 / 未写过位置 = 复位值 0（两发网表突变，都必须发火）
  # -------------------------------------------------------------------------
  echo "---- [$TAG] 4) 负对照 A1：删掉网表的 Mem 初值块 ⇒ 未写过位置变 X ⇒ STALE 判据必须发火 ----"
  if ! "$PY" - "$nl" "$work/FusionBuf_noinit.v" <<'PYEOF'
import re, sys
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass
src = open(sys.argv[1], encoding="utf-8").read()
pat = re.compile(r"^  initial begin\n(?:    mem\[\d+\] = [0-9]+'b[01]+;\n)+  end\n", re.M)
new, n = pat.subn("", src)
print("A1MUT: 删掉 Mem 初值块 %d 处（期望 1）" % n)
if n != 1:
    sys.exit(2)
open(sys.argv[2], "w", encoding="utf-8").write(new)
PYEOF
  then
    echo "[$TAG] RESULT: FAIL（无法构造 A1 突变网表：找不到 Mem 初值块）⇒ 闸门不可信"; return 2
  fi
  if ! "$IVERILOG" -g2012 -DFB_NW="$W" -DFB_CW="$CW" -o "$work/noinit.vvp" "$tb" "$work/FusionBuf_noinit.v" \
        > "$work/iv_a1.log" 2>&1; then
    echo "[$TAG] RESULT: FAIL（A1 突变网表编译失败）"; sed -n '1,20p' "$work/iv_a1.log"; return 2
  fi
  ( cd "$work" && "$VVP" noinit.vvp "+XFILE=$work/x.hex" "+STALEFILE=$work/exp_stale.hex" \
      "+PARTIALFILE=$work/exp_partial.hex" "+WINFILE=$work/exp_win.hex" \
      "+C=$C" "+W=$W" "+H=$H" ) > "$work/a1.out" 2>&1 || true
  grep '^STALE ' "$work/a1.out" | sed -e 's/^STALE *//' | tr -s ' ' '\n' > "$work/a1.stale" || true
  grep '^WIN '   "$work/a1.out" | sed -e 's/^WIN *//'   | tr -s ' ' '\n' > "$work/a1.win"   || true
  local a1_stale a1_win
  a1_stale="$(cnt "$work/exp_stale.hex" "$work/a1.stale")"
  a1_win="$(cnt  "$work/exp_win.hex"   "$work/a1.win")"
  echo "[$TAG] A1 STALE_vs_期望0 MISMATCH=$a1_stale（期望 > 0）  WIN_vs_黄金 MISMATCH=$a1_win（期望 0：突变是外科式的）"
  if ! [ "$a1_stale" -gt 0 ] 2>/dev/null; then
    echo "[$TAG] RESULT: FAIL（A1 没发火：删了初值后未写过位置仍读出 0？）⇒ 闸门不可信"; return 2
  fi
  if [ "$a1_win" != "0" ]; then
    echo "[$TAG] RESULT: FAIL（A1 突变不是外科式：删初值竟也改了已写行的 WIN，差 $a1_win 字节）⇒ 闸门不可信"; return 2
  fi
  if grep -q '^RESULT: PASS' "$work/a1.out"; then
    echo "[$TAG] RESULT: FAIL（A1 突变下装置竟然 PASS ⇒ 装置自检没接在回路上）⇒ 闸门不可信"; return 2
  fi
  echo "[$TAG] NEG_OK[A1]: 删初值 ⇒ STALE 报 $a1_stale 字节不符，WIN 差 $a1_win（=0，外科式）⇒ '读 0' 这条真在盯初值"

  echo "---- [$TAG] 4b) 负对照 A2：读地址不再随环号转（rd_sum 丢掉 row_ptr）⇒ partial 最老档必须读到已写行 ----"
  if ! "$PY" - "$nl" "$work/FusionBuf_noring.v" <<'PYEOF'
import re, sys
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass
src = open(sys.argv[1], encoding="utf-8").read()
pat = re.compile(r"^  assign _zz_rd_sum = \{1'd0, row_ptr\};\n", re.M)
new, n = pat.subn("  assign _zz_rd_sum = 3'd0;\n", src)
print("A2MUT: 把 rd_sum 里的 row_ptr 项去掉 %d 处（期望 1）" % n)
if n != 1:
    sys.exit(2)
open(sys.argv[2], "w", encoding="utf-8").write(new)
PYEOF
  then
    echo "[$TAG] RESULT: FAIL（无法构造 A2 突变网表：找不到 rd_sum 的 row_ptr 项）⇒ 闸门不可信"; return 2
  fi
  if ! "$IVERILOG" -g2012 -DFB_NW="$W" -DFB_CW="$CW" -o "$work/noring.vvp" "$tb" "$work/FusionBuf_noring.v" \
        > "$work/iv_a2.log" 2>&1; then
    echo "[$TAG] RESULT: FAIL（A2 突变网表编译失败）"; sed -n '1,20p' "$work/iv_a2.log"; return 2
  fi
  ( cd "$work" && "$VVP" noring.vvp "+XFILE=$work/x.hex" "+STALEFILE=$work/exp_stale.hex" \
      "+PARTIALFILE=$work/exp_partial.hex" "+WINFILE=$work/exp_win.hex" \
      "+C=$C" "+W=$W" "+H=$H" ) > "$work/a2.out" 2>&1 || true
  grep '^PARTIAL ' "$work/a2.out" | sed -e 's/^PARTIAL *//' | tr -s ' ' '\n' > "$work/a2.partial" || true
  grep '^WIN '     "$work/a2.out" | sed -e 's/^WIN *//'     | tr -s ' ' '\n' > "$work/a2.win"    || true
  local a2_part a2_win
  a2_part="$(cnt "$work/exp_partial.hex" "$work/a2.partial")"
  a2_win="$(cnt  "$work/exp_win.hex"     "$work/a2.win")"
  echo "[$TAG] A2 PARTIAL_vs_期望 MISMATCH=$a2_part（期望 > 0；最老档被环号丢掉后读到了旧行）  WIN_vs_期望 MISMATCH=$a2_win"
  if ! [ "$a2_part" -gt 0 ] 2>/dev/null || ! [ "$a2_win" -gt 0 ] 2>/dev/null; then
    echo "[$TAG] RESULT: FAIL（A2 没发火：读地址丢掉 row_ptr 后窗口竟没变）⇒ 闸门不可信"; return 2
  fi
  echo "[$TAG] NEG_OK[A2]: 读地址不随环号转 ⇒ PARTIAL 报 $a2_part、WIN 报 $a2_win 个字节不符 ⇒ '环形行指针不把旧行当新行'已被抓"

  # -------------------------------------------------------------------------
  # 5) 负对照 B（行序：把 wr_row_adv 提前一行）⇒ 窗口必须整体错一行
  # -------------------------------------------------------------------------
  echo "---- [$TAG] 5) 负对照 B：+ADV_EARLY=1（多推一次行指针）⇒ WIN 必须 == 提前一行的预测值且 != 黄金 ----"
  run_dut adv "$work/exp_win_early.hex" "+ADV_EARLY=1"
  local b_early b_gold
  b_early="$(cnt "$work/exp_win_early.hex" "$work/adv.win")"   # 期望 0：精确命中"提前一行"
  b_gold="$(cnt  "$work/exp_win.hex"       "$work/adv.win")"   # 期望 > 0：与黄金不同
  echo "[$TAG] B ADV_EARLY: WIN_vs_提前一行预测=$b_early（期望 0）  WIN_vs_黄金=$b_gold（期望 > 0）"
  if [ "$b_early" != "0" ]; then
    echo "[$TAG] RESULT: FAIL（负对照 B 未精确命中'提前一行'的预测值：$b_early）⇒ 闸门不可信"; return 2
  fi
  if ! [ "$b_gold" -gt 0 ] 2>/dev/null; then
    echo "[$TAG] RESULT: FAIL（负对照 B 没发火：提前一行后窗口竟没变）⇒ 判据对行序不敏感"; return 2
  fi
  echo "[$TAG] NEG_OK[B]: 行指针提前一行 ⇒ WIN 恰好落在'提前一行'的预测值上（错 $b_gold 个字节 vs 黄金）"

  # -------------------------------------------------------------------------
  # 6) 参数自报：+C 与网表自报 imgC 不符 ⇒ 装置 time 0 $fatal（非 0 退出）
  # -------------------------------------------------------------------------
  echo "---- [$TAG] 6) 参数自报：+C=$((C+1))（与网表 imgC=$C 不符）⇒ 装置必须 \$fatal ----"
  ( cd "$work" && "$VVP" dut_sim.vvp "+XFILE=$work/x.hex" "+STALEFILE=$work/exp_stale.hex" \
      "+PARTIALFILE=$work/exp_partial.hex" "+WINFILE=$work/exp_win.hex" \
      "+C=$((C+1))" "+W=$W" "+H=$H" ) > "$work/badc2.out" 2>&1
  local badc_rc=$?
  if [ "$badc_rc" -eq 0 ]; then
    echo "[$TAG] RESULT: FAIL（+C 不符但装置收工了：没在 time 0 \$fatal）⇒ 参数自报没接在回路上"; return 2
  fi
  if ! grep -q 'TB-ERROR: 网表自报' "$work/badc2.out"; then
    echo "[$TAG] RESULT: FAIL（+C 不符时没打出'网表自报'的报错行）⇒ 参数自报判据不可信"
    grep -E '^(RESULT|TB-ERROR)' "$work/badc2.out" || true; return 2
  fi
  echo "[$TAG] NEG_OK[自报]: +C 不符 ⇒ 装置 time 0 报红（vvp rc=$badc_rc）"

  # ---------------- 本形状收口 ----------------
  echo "[$TAG] shape = OK（向量非退化 / 正对照 MISMATCH=$MISMATCH / A1 STALE=$a1_stale WIN=$a1_win /"
  echo "              A2 PART=$a2_part WIN=$a2_win / B 提前一行差 $b_gold / 自报 \$fatal / cmp 三分支）"
  return 0
}

# ===========================================================================
# 两个形状各跑一遍
# ===========================================================================
rc=0
judge_shape small 2 4 2 5 "$gen/FusionBuf.v"    || rc=$?
if [ "$rc" -eq 0 ]; then
  judge_shape w5    2 5 3 5 "$gen/FusionBuf_w5.v" || rc=$?
fi

if [ "$rc" -ne 0 ]; then
  echo "=========================================================================="
  echo "RESULT: FAIL（形状判据未全过，见上；退出码 $rc）"
  exit "$rc"
fi

# ---------------- 收口 ----------------
echo "=========================================================================="
echo "向量来源 = OK（python 独立环形模型；非退化前提 H>3 且 H%3!=0 / 相邻行两两不同 / 像素两两不同 / 3∉(C,W) / rd_row 三档两两不同）"
echo "形状 small（C=2 W=4 CW=2）+ 形状 w5（C=2 W=5 CW=3）：两形状各自"
echo "  正对照 = OK（STALE/PARTIAL/WIN 三相逐字节一致）"
echo "  负对照 A1[初值] = OK（删 Mem 初值 ⇒ STALE 发火且 WIN 不变=外科式）"
echo "  负对照 A2[环号] = OK（读地址丢掉 row_ptr ⇒ PARTIAL/WIN 发火）"
echo "  负对照 B[行序]  = OK（行指针提前一行 ⇒ 精确命中'提前一行'预测值）"
echo "  参数自报       = OK（+C 不符 ⇒ time 0 \$fatal）"
echo "  比较器自检     = OK（单字节扰动=1 / 长度不等=较长者长度 / 缺文件=-1）"
echo "RESULT: PASS"
exit 0
