#!/usr/bin/env bash
# run_numeric_ab.sh <mode> <cin> <cout> <H> <W> <seed>
#
# 数值对账判据：Python 整数参考（tools/mac_ref.py） vs 装置 Verilog 仿真。
# 四项职责：
#   1) 跑参考，把向量落到临时目录（另导出 $readmemh 用的纯 hex 表）；
#   2) 把向量喂给装置 testbench 并仿真 —— 装置尚未存在 ⇒ 必须**明确报红**，
#      绝不能因为缺文件就静默"通过"；
#   3) 逐字节对账装置的 Y 与参考的 Y，打印 MISMATCH=<不等字节数>；
#   4) 负对照：拿一份**故意错的期望**重跑对账，必须出现非零 mismatch，
#      以此证明判据**有能力失败**（否则它只是个橡皮图章）。
#      两发：① 换 seed 的整块错期望（必须报大量字节）；② 只改一个字节（必须恰好报 1）。
#
# 退出码：
#   0 = 对账通过（判据绿）
#   1 = 判据红：装置缺失 / 编译或仿真失败 / 装置没打印 Y / Y 字节不符
#   2 = 判据自身无效（负对照没能抓住错误期望）
#   3 = 参考或向量自检失败
#
# 装置契约（交给 B2/B4 的实现者；本脚本按此喂数据、按此收数据）：
#   rtl_test/Conv3x3Tb.v 顶层模块，用 $value$plusargs 取：
#     +XFILE=<file> +WFILE=<file> +CIN=<n> +COUT=<n> +H=<n> +IW=<n> +GROUP=<n>
#   （XFILE/WFILE 是每行一个十六进制字节的文本，正好是 $readmemh 的输入格式）
#   然后按 3x3 pad=1 stride=1 分组卷积、int32 累加、max(-128,min(127,acc>>>6)) 量化，
#   把 Y 按 [co][y][x] 展平，向 stdout 打印**一行** "Y <hh> <hh> ..."。
#   注：宽度 plusarg 用 +IW 而不是 +W，避免与"权值文件"撞名。
set -uo pipefail

PY="${PY:-python}"
here="$(cd "$(dirname "$0")" && pwd)"

mode="${1:?usage: run_numeric_ab.sh <mode> <cin> <cout> <H> <W> <seed>}"
cin="${2:?cin}"; cout="${3:?cout}"; H="${4:?H}"; W="${5:?W}"; seed="${6:?seed}"

work="$(mktemp -d)"
cleanup() {
  if [ "${KEEP_TMP:-0}" = "1" ]; then
    echo "KEEP_TMP=1 ⇒ 向量与日志留在 $work"
  else
    rm -rf "$work"
  fi
}
trap cleanup EXIT

echo "== run_numeric_ab: mode=$mode C_in=$cin C_out=$cout H=$H W=$W seed=$seed =="
echo "   tmp=$work"

# ---------------- 1) 参考：生成向量 ----------------
if ! "$PY" "$here/mac_ref.py" "$mode" "$cin" "$cout" "$H" "$W" "$seed" \
        > "$work/ref.txt" 2> "$work/ref.err"; then
  echo "FATAL: 参考 mac_ref.py 退出非 0（参数非法？）"; cat "$work/ref.err"; exit 3
fi
grep '^Y ' "$work/ref.txt" > "$work/ref_y.txt" || true
[ -s "$work/ref_y.txt" ] || { echo "FATAL: 参考没有产出 Y 行"; exit 3; }

# $readmemh 用：去前缀，一个字节一行（不出现 0x / x / z 这类会干扰 $readmemh 的 token）
hex_bytes() { grep "^$1 " "$work/ref.txt" | cut -d' ' -f2- | tr -s ' ' '\n'; }
hex_bytes X > "$work/x.hex"
hex_bytes W > "$work/w.hex"

group="$(grep -o 'group=[0-9]*' "$work/ref.err" | head -1 | cut -d= -f2)"
[ -n "$group" ] || { echo "FATAL: 解析不出 group"; cat "$work/ref.err"; exit 3; }

# 向量自检：长度必须与维度自洽（参考写错时立刻炸，别把错向量喂给装置）
nx="$(awk '/^X /{print NF-1}' "$work/ref.txt")"
nw="$(awk '/^W /{print NF-1}' "$work/ref.txt")"
ny="$(awk '/^Y /{print NF-1}' "$work/ref.txt")"
sx="$(wc -l < "$work/x.hex" | tr -d ' ')"; sw="$(wc -l < "$work/w.hex" | tr -d ' ')"
echo "   向量自检: X=$nx W=$nw Y=$ny group=$group | x.hex=$sx w.hex=$sw 行"
if [ "$nx" -ne $((cin*H*W)) ] || [ "$ny" -ne $((cout*H*W)) ] \
   || [ "$nw" -le 0 ] || [ $((nw % 9)) -ne 0 ] || [ "$sx" -ne "$nx" ] || [ "$sw" -ne "$nw" ]; then
  echo "FATAL: 向量长度与维度不自洽"; exit 3
fi

# ---------------- 2) 装置：编译 + 仿真 ----------------
tb="$here/../rtl_test/Conv3x3Tb.v"
rtl="${RTL:-$here/../gen/Conv3x3Slice.v}"   # device netlist; override with RTL=... for other GROUP variants
[ -f "$rtl" ] || { echo "JUDGE-RED: device netlist missing ($rtl) -- run SliceGen first"; exit 1; }
iv="$(command -v iverilog 2>/dev/null || true)"
echo "   iverilog: ${iv:-<PATH 上找不到>}"
[ -n "$iv" ] && echo "   version : $(iverilog -V 2>&1 | head -1)"

dut_ran=0
if [ ! -f "$tb" ]; then
  # 缺装置 = 判据红。这是 B1（先写判据）的**预期状态**，不是脚本坏掉。
  echo "JUDGE-RED: 装置不存在：$tb"
  echo "  本任务（B1）只写判据、不写硬件 ⇒ 现在必须红；装置由 B2/B4 创建。"
  echo "  下一任务要交付 rtl_test/Conv3x3Tb.v，契约见本脚本头部注释，要点："
  echo "    a) \$value\$plusargs 取 +XFILE/+WFILE/+CIN/+COUT/+H/+IW/+GROUP；"
  echo "    b) \$readmemh 读每行一个十六进制字节的 XFILE/WFILE（本脚本已导出）；"
  echo "    c) int32 累加后 max(-128,min(127,acc>>>6))，按 [co][y][x] 展平；"
  echo "    d) stdout 打印一行 'Y <hh> <hh> ...'（本脚本用 grep '^Y ' 收）。"
elif [ -z "$iv" ]; then
  echo "JUDGE-RED: 装置 $tb 存在，但找不到 iverilog，无法仿真"
else
  if ! ( cd "$work" && iverilog -g2012 -o dut_sim.vvp "$tb" "$rtl" ) > "$work/iv.log" 2>&1; then
    echo "JUDGE-RED: iverilog 编译失败"; sed -n '1,30p' "$work/iv.log"
  else
    if ! ( cd "$work" && vvp dut_sim.vvp \
             +XFILE="$work/x.hex" +WFILE="$work/w.hex" \
             +CIN="$cin" +COUT="$cout" +H="$H" +IW="$W" +GROUP="$group" ) \
             > "$work/dut_out.txt" 2>&1; then
      echo "  注意: vvp 退出非 0"
    fi
    grep '^Y ' "$work/dut_out.txt" > "$work/dut_y.txt" || true
    if [ -s "$work/dut_y.txt" ]; then
      dut_ran=1
    else
      echo "JUDGE-RED: 装置没有打印 Y 行（vvp 输出见下）"
      sed -n '1,30p' "$work/dut_out.txt"
    fi
  fi
fi

# ---------------- 3) 对账（逐字节） ----------------
# cnt_y <期望文件> <实际文件>：打印两行 Y 之间不等的**字节**个数。
#   -1 = 任一侧缺 Y 行；长度不同则打印较长者长度（视作全不等）。
# 口径说明：Y 是一个长单行，用 diff 数行只能得到 0/1（有差异就是"1 行不同"），
# 无法反映错多少字节 ⇒ 这里按 token 逐字节比。
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

mis=-1
if [ "$dut_ran" = 1 ]; then
  mis="$(cnt_y "$work/ref_y.txt" "$work/dut_y.txt")"
  echo "MISMATCH=$mis"
  if [ "$mis" -gt 0 ]; then
    echo "  --- 差异摘录（期望 < / 实际 >，按 token 一行一个）---"
    diff <(tr ' ' '\n' < "$work/ref_y.txt") <(tr ' ' '\n' < "$work/dut_y.txt") | head -20
  fi
else
  echo "MISMATCH=NA(装置未运行)"
fi

# ---------------- 4) 负对照：证明判据能失败 ----------------
# 错误期望的构造：**换一个 seed** 重新生成参考。
# 为什么这足以证明判据有效：seed 不同 ⇒ 随机抽出的整块 X/W 不同 ⇒ 期望 Y 的字节
# 与正确期望不同（两组无关随机张量，逐字节全同的概率 ~256^-N，实务上为零）。
# 如果判据对一份"必然不同的期望"仍报 0 mismatch，说明对账代码压根没在比
#（橡皮图章）—— 那它同样会把错的硬件判成对的，此时判据无效，必须退出 2。
# 因此负对照必须**抓住**错误期望，这是判据上岗的前置条件。
neg_seed=$((seed + 1))
wdiff=-1
for _ in 1 2 3 4 5 6 7 8; do
  if ! "$PY" "$here/mac_ref.py" "$mode" "$cin" "$cout" "$H" "$W" "$neg_seed" 2>/dev/null \
        | grep '^Y ' > "$work/wrong_y.txt"; then
    echo "FATAL: 生成错误期望失败（neg_seed=$neg_seed）"; exit 3
  fi
  [ -s "$work/wrong_y.txt" ] || { echo "FATAL: 错误期望为空"; exit 3; }
  wdiff="$(cnt_y "$work/ref_y.txt" "$work/wrong_y.txt")"
  [ "$wdiff" -gt 0 ] && break
  neg_seed=$((neg_seed + 1))
done

# 第二发负对照（更狠）：**只改一个字节**。它验证的是对账的"粒度"——
# 若实现成"按行 diff"，只改一个字节也会报 1 行不同、改 500 个字节也是 1 行不同，
# 那 MISMATCH 就失去意义。这里要求恰好命中 1 个字节。
"$PY" - "$work/ref_y.txt" "$work/corrupt_y.txt" <<'PYEOF'
import sys
toks = None
for ln in open(sys.argv[1], encoding="utf-8", errors="replace"):
    if ln.startswith("Y "):
        toks = ln.split()
        break
if toks is None or len(toks) < 2:
    sys.exit(1)
i = 6 if len(toks) > 6 else 1          # toks[0] 是 "Y" 前缀；改第 5 个字节
toks[i] = "%02x" % (int(toks[i], 16) ^ 0x01)
with open(sys.argv[2], "w", encoding="ascii", newline="\n") as f:
    f.write(" ".join(toks) + "\n")
PYEOF
[ -s "$work/corrupt_y.txt" ] || { echo "FATAL: 无法生成单字节损伤样本"; exit 3; }
onediff="$(cnt_y "$work/ref_y.txt" "$work/corrupt_y.txt")"

selfdiff="$(cnt_y "$work/ref_y.txt" "$work/ref_y.txt")"     # 正：自己比自己必须 0
dut_wrong=-1
[ "$dut_ran" = 1 ] && dut_wrong="$(cnt_y "$work/wrong_y.txt" "$work/dut_y.txt")"
echo "NEGCTL: ref-vs-ref=$selfdiff(期望0) ref-vs-wrong(seed=$neg_seed)=$wdiff(期望>0) one-byte=$onediff(期望1) dut-vs-wrong=$dut_wrong(期望>0或NA)"

if [ "$selfdiff" -ne 0 ] || [ "$wdiff" -le 0 ]; then
  echo "NEGCTL-FAIL: 判据无法区分错误期望 ⇒ 判据无效（橡皮图章）"
  exit 2
fi
if [ "$onediff" -ne 1 ]; then
  echo "NEGCTL-FAIL: 单字节损伤报出 $onediff 处差异（期望恰好 1）⇒ 对账粒度不对"
  exit 2
fi
if [ "$dut_ran" = 1 ] && [ "$dut_wrong" -le 0 ]; then
  echo "NEGCTL-FAIL: 装置输出与错误期望一致 ⇒ 判据无效"
  exit 2
fi
echo "NEGCTL-OK"

# ---------------- 判决 ----------------
if [ "$dut_ran" != 1 ]; then
  echo "=== JUDGE-RED: 装置未运行（本任务 B1 预期如此：判据先行）==="
  exit 1
fi
if [ "$mis" = 0 ]; then
  echo "=== JUDGE-GREEN: 装置 Y 与参考 Y 逐字节一致 ==="
  exit 0
fi
echo "=== JUDGE-RED: 装置 Y 有 $mis 个字节与参考不符 ==="
exit 1
