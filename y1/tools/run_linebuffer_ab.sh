#!/usr/bin/env bash
# run_linebuffer_ab.sh —— 3x3 窗口行缓冲（rtl/LineBuffer.scala + gen/LineBuffer.v）的窗口序列闸门。
#
# 四项职责（与 tools/run_numeric_ab.sh / run_macarray_ab.sh 同风格）：
#   1) 造流：写一张小图（值 = ci*64 + row*8 + col - 64，逐位可区分）——**输入是手写的公式**，
#      **期望的窗口序列由 python 现算**（下面那段独立、直白的循环，绝不手抄）；
#   2) 把图像喂给装置 rtl_test/LineBufferTb.v，仿真收一行 "WIN <hh> ..."；
#   3) 逐字节对账装置的窗口序列与 python 期望，打印**唯一一行** MISMATCH=<不等字节数>；
#   4) 负对照（两发，缺一不可，都要**抓住**）：
#      ① 列错位：把期望序列**按列移一列**（发射行内整块旋转一格）⇒ 与正确的装置输出比，
#         必须 non-zero。窗口序列若真按列排布，任何"列差一"都必然露出来（就是我们想防的
#         "行缓冲列指针差一"那类 bug）；这一发证明对账对**列**敏感。
#      ② 行错位：把期望序列**按发射行移一行**（等价于"窗口没晚一行"：把 e 行的窗口当成
#         e+1 行的窗口）⇒ 必须 non-zero。这一发证明对账对**行**敏感（也就是本任务那条
#         "一行延迟"的约定不是嘴上说说：行差一行必然报错）。
#      任一发抓不住 ⇒ 判据无效（橡皮图章）⇒ 退出 2。
#      另加一发（装置侧）：把**被列错位的期望**当 +YFILE 重跑仿真，装置自己的自检必须报
#      RESULT: FAIL 且 vvp 非 0 退出 —— 证明装置的 PASS/FAIL 确实接在回路上。
#
# 退出码：
#   0 = 通过（MISMATCH=0 + 两发负对照都抓住）
#   1 = 对账不符 / 编译或仿真失败 / 装置没打印 WIN / 装置自检未 PASS
#   2 = 负对照没抓住 ⇒ 闸门自身不可信
#   3 = 向量自检失败（用例/维度写错）
#
# 装置契约：rtl_test/LineBufferTb.v + gen/LineBuffer.v（C_IN=2、WIDTH=4 定点生成）
#   +XFILE=<file> 每行一个 hex 字节，行主序图像 [row][col][ci]          ⇒ CIN*H*IW 字节
#   +YFILE=<file> 每行一个 hex 字节，期望窗口序列（展平顺序见下）        ⇒ (H+1)*IW*CIN*3 字节
#   +CIN=<n> +IW=<n> +H=<n>   维度（CIN/IW 必须与网表一致，H 任意）
#   装置打印一行 "WIN <hh> ..." 再一行 "RESULT: PASS|FAIL"；FAIL 时 $fatal ⇒ 非 0。
#
# ★ 展平顺序（装置、本闸门、rtl/LineBuffer.scala 的约定三处一致）：
#     [发射行 e][列 c][通道 ci][窗口行 r]
#   e = 0..H 共 H+1 行（e=0 是**预滚**行：对应输出行 y=-1；e=1..H 是输出行 0..H-1），
#   c = 0..IW-1，ci = 0..CIN-1，r = 0 上一行 / 1 当前行 / 2 下一行（三行同一列）。
#   一维下标 = ((e*IW + c)*CIN + ci)*3 + r。
#
# ★ 流与零填充：喂 **H+1 行**（第 0..H-1 行是图，第 H 行是全 0 的 pad 行），因为窗口比输入行
#   **晚一行**产出（输出行 y 的窗口在第 y+1 行流入时才给），H 行图像只够到输出行 H-2；
#   输出行 H-1 要的第 H 行只能由驱动方喂 0（本模块接口里没有 H）。第一行之上由 hist 复位为 0。
set -uo pipefail

PY="${PY:-python}"
here="$(cd "$(dirname "$0")" && pwd)"
rtl="$here/../gen/LineBuffer.v"
tb="$here/../rtl_test/LineBufferTb.v"

CIN="${CIN:-2}"     # 通道数（与定点生成的网表一致）
H="${H:-5}"         # 图像高度（H 决定喂几行；喂 H+1 行，最后一行是 pad 行）
W="${W:-4}"         # 图像宽度 / 网表 WIDTH

work="$(mktemp -d)"
cleanup() {
  if [ "${KEEP_TMP:-0}" = "1" ]; then
    echo "KEEP_TMP=1 ⇒ 向量与日志留在 $work"
  else
    rm -rf "$work"
  fi
}
trap cleanup EXIT

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

echo "== run_linebuffer_ab: 3x3 窗口行缓冲（存 2 行历史 + 窗口晚一行产出）窗口序列对账 =="
echo "   rtl=$rtl"
echo "   tb =$tb"
echo "   dim: C_in=$CIN H=$H W=$W（喂 H+1=$((H+1)) 行，最后一行是全 0 的 pad 行）"
echo "   iverilog=${IVERILOG:-<找不到>}  vvp=${VVP:-<找不到>}"
[ -n "$IVERILOG" ] && "$IVERILOG" -V 2>&1 | head -1
echo "   tmp=$work"

# ---------------- 1) 造流 + 由 python 现算期望窗口序列 ----------------
# 值 = ci*64 + row*8 + col - 64（ci=0 一档是负数、ci=1 一档是正数，两条符号路径都过一遍）。
# ★ 为什么不用 spec 里举例的 row*16 + col + ci*64：那个式子里 (row=4,ci=0) 与 (row=0,ci=1)
#   都等于 64 ⇒ **撞值**，"行/通道串了"这一类错位会被撞值糊住。这里 ci 占 64 一档、row 占 8
#   一档、col 占 1 一档，三档互不重叠，H,W <= 8 时每个 (row,col,ci) 的值**两两不同** ⇒
#   任何行/列/通道的错位都在数值上立刻显形。
if ! "$PY" - "$work" "$CIN" "$H" "$W" <<'PYEOF'
import sys
try:
    # Windows 控制台是 GBK：显式按 UTF-8 写（errors=replace 兜底），否则中文打印出来是乱码。
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

work, CIN, H, W = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
if not (1 <= H <= 64) or not (1 <= W <= 8) or not (1 <= CIN <= 8):
    print("FATAL: 维度越界（H<=64 / W<=8 / CIN<=8）")
    sys.exit(3)

def img(r, c, ci):
    """像素值。越界行（第一行之上 / 最后一行之下）= 0，就是零填充。"""
    if r < 0 or r >= H:
        return 0
    v = ci * 64 + r * 8 + c - 64
    assert -128 <= v <= 127, "像素值出 int8 范围: %d" % v
    return v & 0xff

# 期望序列：发射行 e 的窗口是**输出行 y = e-1** 的窗口（win0=第 y-1 行 / win1=第 y 行 /
# win2=第 y+1 行，三行同一列 c）。e=0 是预滚行（y=-1），e=1..H 是输出行 0..H-1。
def base_rows():
    rows = []
    for e in range(H + 1):
        y = e - 1
        row = []
        for c in range(W):
            cell = []
            for ci in range(CIN):
                cell += [img(y - 1, c, ci), img(y, c, ci), img(y + 1, c, ci)]
            row.append(cell)
        rows.append(row)
    return rows

def flat(rows):
    return [b for row in rows for cell in row for b in cell]

ok_rows = base_rows()
ok = flat(ok_rows)
# 负对照①：整条期望序列**按列移一列**（每个发射行内把列旋转一格；一列 = CIN*3 个字节）
col_shift = flat([row[1:] + row[:1] for row in ok_rows])
# 负对照②：整条期望序列**按发射行移一行**（把 e 行的窗口当 e+1 行 ⇒ 等价于"窗口没晚一行"）
row_shift = flat(ok_rows[1:] + ok_rows[:1])

def dump(path, toks):
    with open(path, "w", encoding="ascii", newline="\n") as f:
        f.write("".join("%02x\n" % b for b in toks))

# 向量自检 1：期望序列的字节数必须与 H/W/CIN 自洽
nwin = (H + 1) * W * CIN * 3
if len(ok) != nwin:
    print("FATAL: 期望长度 %d != (H+1)*W*CIN*3 = %d" % (len(ok), nwin))
    sys.exit(3)
# 向量自检 2：两发负对照必须真的**改了**期望（否则谈不上"抓得住/抓不住"）
d_col = sum(1 for a, b in zip(ok, col_shift) if a != b)
d_row = sum(1 for a, b in zip(ok, row_shift) if a != b)
if d_col == 0 or d_row == 0:
    print("FATAL: 负对照的期望与正确期望完全相同（列差 %d / 行差 %d）⇒ 用例没意义" % (d_col, d_row))
    sys.exit(3)
# 向量自检 3：值必须两两可区分（同一 (row,col) 上，两个通道、或同通道上一行的邻居都不同值）
vals = set((r, c, ci) for r in range(H) for c in range(W) for ci in range(CIN))
if len(set(img(r, c, ci) for (r, c, ci) in vals)) != len(vals):
    print("FATAL: 像素值有撞值 ⇒ 错位可能被糊住")
    sys.exit(3)

dump(work + "/x.hex", [img(r, c, ci) for r in range(H) for c in range(W) for ci in range(CIN)])
dump(work + "/exp.hex", ok)
dump(work + "/exp_colshift.hex", col_shift)
dump(work + "/exp_rowshift.hex", row_shift)
print("VEC: C_in=%d H=%d W=%d 图=%d 字节 期望窗口=%d 字节（发射行 %d 行 x 列 %d x 通道 %d x 3）"
      % (CIN, H, W, CIN * H * W, nwin, H + 1, W, CIN))
print("VEC: 期望 vs 列错位差 %d 字节、期望 vs 行错位差 %d 字节（负对照的期望确实不同）" % (d_col, d_row))
print("VEC: 上边区（y=-1）与下边区（第 H 行）在期望里都是 0 —— 零填充规则已生效")
PYEOF
then
  echo "FATAL: 生成向量/期望失败"; exit 3
fi
for f in x.hex exp.hex exp_colshift.hex exp_rowshift.hex; do
  [ -s "$work/$f" ] || { echo "FATAL: 向量 $f 缺失或为空"; exit 3; }
done

# ---------------- 2) 装置：编译 + 仿真 ----------------
sim_bad=0
dut_ran=0
if [ ! -f "$rtl" ]; then
  echo "JUDGE-RED: 网表不存在：$rtl（先跑 Task 里的 sbt 生成步骤）"
elif [ ! -f "$tb" ]; then
  echo "JUDGE-RED: 装置不存在：$tb"
elif [ -z "$IVERILOG" ] || [ -z "$VVP" ]; then
  echo "JUDGE-RED: 找不到 iverilog / vvp，无法仿真"
else
  if ! "$IVERILOG" -g2012 -o "$work/dut_sim.vvp" "$tb" "$rtl" > "$work/iv.log" 2>&1; then
    echo "JUDGE-RED: iverilog 编译失败"; sed -n '1,30p' "$work/iv.log"; sim_bad=1
  else
    run_tb() { # <tag> <yfile> <expect: pass|fail|any> [<vvp 文件名，默认 dut_sim.vvp>]
      local tag="$1" yf="$2" want="$3" vvp="${4:-dut_sim.vvp}" rc=0
      ( cd "$work" && "$VVP" "$vvp" \
          +XFILE="$work/x.hex" +YFILE="$yf" \
          +CIN="$CIN" +IW="$W" +H="$H" ) > "$work/$tag.out" 2>&1 || rc=$?
      grep '^WIN ' "$work/$tag.out" | sed -e 's/^WIN *//' | tr -s ' ' '\n' \
        > "$work/$tag.win" || true
      eval "${tag}_rc=$rc"
      case "$want" in
        pass)
          if [ "$rc" -ne 0 ] || ! grep -q '^RESULT: PASS' "$work/$tag.out"; then
            echo "JUDGE-RED: 装置自检未 PASS（vvp rc=$rc）"
            grep '^RESULT:' "$work/$tag.out" || true
            sed -n '1,10p' "$work/$tag.out"
            sim_bad=1
          fi
          if [ ! -s "$work/$tag.win" ]; then
            echo "JUDGE-RED: 装置没有打印 WIN 行（vvp rc=$rc）"
            sed -n '1,20p' "$work/$tag.out"; sim_bad=1
          fi
          ;;
        fail)
          if [ "$rc" -eq 0 ] || ! grep -q '^RESULT: FAIL' "$work/$tag.out"; then
            echo "JUDGE-RED: 装置拿到错期望仍收工（vvp rc=$rc）⇒ 装置自检没接在回路上"
            grep '^RESULT:' "$work/$tag.out" || true
            sim_bad=1
          fi
          ;;
        any)   # 突变体：只取它的 WIN 行（它本来就该 FAIL）
          [ -s "$work/$tag.win" ] || { echo "JUDGE-RED: $tag 没有 WIN 行"; sim_bad=1; }
          ;;
      esac
    }
    run_tb dut "$work/exp.hex" pass
    [ -s "$work/dut.win" ] && dut_ran=1
  fi
fi

# ---------------- 3) 逐字节对账 ----------------
# cnt_bytes <期望文件> <装置 WIN 文件>：打印两侧 token 数不等的位置数。
#   -1 = 任一侧缺失；长度不同则打印较长者长度（视作全不等）。
# 为什么按 token 逐字节比而不按行 diff：WIN 是一个长单行，行 diff 只会给 0/1
# （有差异就是"1 行不同"），反映不了错多少字节 ⇒ MISMATCH 就失去意义。
cnt_bytes() {
  "$PY" - "$1" "$2" <<'PYEOF'
import sys
def load(p):
    try:
        toks = open(p, encoding="utf-8", errors="replace").read().split()
    except OSError:
        return None
    return toks
a, b = load(sys.argv[1]), load(sys.argv[2])
if a is None or b is None:
    print(-1)
elif len(a) != len(b):
    print(max(len(a), len(b)))
else:
    print(sum(1 for i, j in zip(a, b) if i != j))
PYEOF
}

mis=-1
self_mis=-1
col_mis=-1
row_mis=-1
if [ "$dut_ran" = 1 ]; then
  mis="$(cnt_bytes "$work/exp.hex" "$work/dut.win")"
  self_mis="$(cnt_bytes "$work/exp.hex" "$work/exp.hex")"          # 自己比自己必须 0
  col_mis="$(cnt_bytes "$work/exp_colshift.hex" "$work/dut.win")"  # 负对照①：必须 >0
  row_mis="$(cnt_bytes "$work/exp_rowshift.hex" "$work/dut.win")"  # 负对照②：必须 >0
  echo "MISMATCH=$mis"
  if [ "$mis" -gt 0 ] 2>/dev/null; then
    echo "  --- 差异摘录（期望 < / 实际 >，按 token 一行一个）---"
    diff <(tr ' ' '\n' < "$work/exp.hex") <(tr ' ' '\n' < "$work/dut.win") | head -20
  fi
else
  echo "MISMATCH=NA(装置未运行)"
fi

# 装置侧负对照：把**列错位**的期望当 +YFILE 重跑，装置必须自己报 FAIL 且非 0 退出。
tb_neg_fail=-1
if [ -f "$work/dut_sim.vvp" ] && [ -n "$VVP" ]; then
  run_tb neg "$work/exp_colshift.hex" fail
  if grep -q '^RESULT: FAIL' "$work/neg.out" 2>/dev/null && [ "${neg_rc:-1}" -ne 0 ]; then
    tb_neg_fail=1
  else
    tb_neg_fail=0
  fi
fi

# 装置侧负对照 ②（突变体，抓的是"硬件真违背约定"而不只是"期望被改了"）：
#   把网表里 win(ci)(1)（"当前行"，应读 hist1 = 第 y 行）的来源换成 hist0（第 y-1 行）
#   ⇒ 网表变成"窗口的当前行落后一行"，不再遵守本任务的"窗口晚一行"约定。
#   同一套对账必须报 MISMATCH>0；若突变体也能绿，说明这条约定只是写在注释里，闸门抓不住它。
#   （这一发与上面两发的分工：上面两发证明**对账代码**对行/列敏感，这一发证明**约定本身**被验证。）
mut_mis=-1
if [ -f "$work/dut_sim.vvp" ] && [ -n "$VVP" ] && [ -n "$IVERILOG" ]; then
  if "$PY" - "$rtl" "$work/mutant.v" <<'PYEOF'
import re, sys
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass
src = open(sys.argv[1], encoding="utf-8", errors="replace").read()
m = re.search(r"^module LineBuffer\b.*?^endmodule", src, re.S | re.M)
if not m:
    print("MUTANT-ERROR: gen/LineBuffer.v 里找不到 module LineBuffer"); sys.exit(1)
body = m.group(0)
# 窗口的"当前行"读 hist1 -> 改读 hist0（每通道一处）
pat = re.compile(r"(_zz_win_\d+_1 = )hist1_")
n = [0]
def repl(mo):
    n[0] += 1
    return mo.group(1) + "hist0_"
newbody = pat.sub(repl, body)
if n[0] < 1:
    print("MUTANT-ERROR: 没找到 _zz_win_*_1 = hist1_* 形状的赋值（生成风格变了，请更新本判据）")
    sys.exit(1)
if newbody == body:
    print("MUTANT-ERROR: 突变体与原文相同"); sys.exit(1)
open(sys.argv[2], "w", encoding="ascii", newline="\n").write(src[:m.start()] + newbody + src[m.end():])
print("MUTANT: 把 win(ci)(1) 的 %d 处赋值从 hist1(第 y 行) 改成 hist0(第 y-1 行)（窗口当前行落后一行）⇒ %s"
      % (n[0], sys.argv[2]))
PYEOF
  then
    if "$IVERILOG" -g2012 -o "$work/mut_sim.vvp" "$tb" "$work/mutant.v" > "$work/iv_mut.log" 2>&1; then
      run_tb mut "$work/exp.hex" any mut_sim.vvp
      if [ -s "$work/mut.win" ]; then
        mut_mis="$(cnt_bytes "$work/exp.hex" "$work/mut.win")"
      fi
    else
      echo "JUDGE-RED: 突变体编译失败"; sed -n '1,20p' "$work/iv_mut.log"; sim_bad=1
    fi
  else
    echo "JUDGE-RED: 生成突变体失败"; sim_bad=1
  fi
fi

echo "NEGCTL: ref-vs-ref=$self_mis(期望0) dut-vs-colshift=$col_mis(期望>0) dut-vs-rowshift=$row_mis(期望>0) tb-fail-on-bad-yfile=$tb_neg_fail(期望1, vvp_rc=${neg_rc:-NA}) mutant-hist1->hist0=$mut_mis(期望>0)"
echo "  负对照① 列错位：期望按列移一列 ⇒ 对账报 $col_mis 个字节不符"
echo "  负对照② 行错位：期望按发射行移一行（=窗口没晚一行）⇒ 对账报 $row_mis 个字节不符"
echo "  负对照③ 突变体：网表 win(1) 改读 hist0（当前行落后一行）⇒ 对账报 $mut_mis 个字节不符"

neg_ok=1
if [ "$dut_ran" != 1 ]; then
  echo "NEGCTL-SKIP: 装置没跑起来，无法核对负对照"
elif [ "$self_mis" != "0" ]; then
  echo "NEGCTL-FAIL: 自己比自己报出 $self_mis 处差异 ⇒ 对账口径坏了"; neg_ok=0
elif [ "$col_mis" -le 0 ] 2>/dev/null; then
  echo "NEGCTL-FAIL: 列错位没被抓住（$col_mis）⇒ 对账对列不敏感（橡皮图章）"
  neg_ok=0
elif [ "$row_mis" -le 0 ] 2>/dev/null; then
  echo "NEGCTL-FAIL: 行错位没被抓住（$row_mis）⇒ 对账对行不敏感（一行延迟的约定形同虚设）"
  neg_ok=0
elif [ "$tb_neg_fail" != "1" ]; then
  echo "NEGCTL-FAIL: 装置拿到被列错位的 +YFILE 仍收工 ⇒ 装置自检没接在回路上"
  sed -n '1,10p' "$work/neg.out" 2>/dev/null || true
  neg_ok=0
elif [ "$mut_mis" -le 0 ] 2>/dev/null; then
  echo "NEGCTL-FAIL: 违背'窗口晚一行'的突变体也被判绿（$mut_mis）⇒ 这条约定没被真验证"
  neg_ok=0
fi

# ---------------- 判决 ----------------
if [ "$neg_ok" != "1" ]; then
  echo "=== NEGCTL-BAD: 负对照没抓住 ⇒ 闸门自身不可信 ==="
  exit 2
fi
if [ "$sim_bad" -ne 0 ]; then
  echo "=== JUDGE-RED: 编译/仿真失败或装置自检未通过 ==="
  exit 1
fi
if [ "$dut_ran" != 1 ]; then
  echo "=== JUDGE-RED: 装置未运行 ==="
  exit 1
fi
if [ "$mis" = "0" ]; then
  echo "NEGCTL-OK: 三发负对照都抓住（期望列差一列 / 期望行差一行 / 网表当前行落后一行）"
  echo "=== JUDGE-GREEN: 装置窗口序列与 python 期望逐字节一致（含上下零填充 + 预滚行）；"
  echo "                    存 2 行历史、窗口晚一行产出的约定已被序列本身证明 ==="
  exit 0
fi
echo "=== JUDGE-RED: 装置窗口序列有 $mis 个字节与参考不符 ==="
exit 1
