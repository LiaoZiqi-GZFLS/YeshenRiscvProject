#!/usr/bin/env bash
# run_stride_exec_ab.sh —— y1 C4b-D1b 闸门：**集成 `UnitExec` 级的卷积步长 `stride >= 2`** 数值判据。
#
# 上游出处：D1（`0766cbe`）把 `stride >= 2` 实现在 `Conv3x3Slice`（抽稀相位）里，并由 `MultiPassUnit`
#   直通、`UnitExec` 接描述符 `STRIDE` 域；D1 的闸门（`run_stride_ab.sh`）在**单元级**（`MultiPassUnit`
#   + 编排装置）证死，但报告 `y1/reports/c4b_stride.md` §7 明写遗留：
#     「`UnitExec` 级的 stride≥2 端到端数值待给 `UnitExecWideTb` 加 `+STRIDE`（下一片）」。
#   本闸门就是那一片：**RTL 一行未改**（只给装置加 `+STRIDE`），把 stride≥2 逐字节证到**集成 `UnitExec`**。
#
# 被测行为（`gen/UnitExec*.v` 的 `WIDERUN` 通路；描述符 `w3[11:8]` 的 `STRIDE` —— 格式一字未改）：
#   描述符 `STRIDE=s` ⇒ `UnitExec` 的 `strideEff`（字段 0 视作 1）**同时**接给
#   ① 宽层多趟的 `MultiPassUnit`（⇒ 它自己的 `Conv3x3Slice`）、② 窄通路的切片；
#   输出几何由 `IMG_H/IMG_W`（描述符 1 号字）给，**DUT 每趟自己驱动 `inRows = IMG_H·s` 个真行 + 1 行
#   合成的 pad 行（= `z_pad`）**（见 `rtl/UnitExec.scala` 的「C4b-D1」一节：`inRows`/`inWOk`/`inPix`）。
#
# ============================== 判据 ==============================
#  0) **参考自检**（python；不成立 exit 3）：`tools/stride_ref.py --selftest` —— 两套**独立实现**
#     （向量化抽稀切片 / 逐输出像素的显式 3×3 窗口）逐字节互证；拆趟累加 == 整层；`s=1` 与**冻结的
#     C4a.5b caliber**（`wide_exec_ref.conv_acc`）**逐字节相同**（离线锚）；`s>1 != s=1`（步长真在数据通路上）。
#  1) **供料**（`stride_ref.py --emit`，**不写第三条参考**，与 D1 的 `run_stride_ab.sh` 同一份工具）：
#     · `s2_real`    ：真 `Conv_0`（`--lid 0`）**s=2**、`H_in=8 × WIDTH=64`  ⇒ 输出 `IMG 4×32`；
#     · `s1_real`    ：同一真层 **s=1**、`H_in=4 × WIDTH=64`           ⇒ 输出 `IMG 4×64`（**回归锚**）；
#     · `s2_synth`   ：合成 `C_in=16 → C_out=16` **s=2**（`n_ci=2` ⇒ 打**跨 ci 趟累加** + 步长）；
#     · `s2_real640` ：真 `Conv_0` **s=2**、`H_in=8 × WIDTH=640`（**真行宽**）⇒ 输出 `IMG 4×320`
#                      —— **横向抽稀整段为真：640 → 320**；
#     · `s1_real640` ：同一真层 **s=1**、`H_in=4 × WIDTH=640` ⇒ 输出 `IMG 4×640`（真行宽回归锚）。
#       ★ 为什么是 `H_in=4`（不是 8）：WIDTH=640 档网表的输出存储上限 `PIXW = WIDTH·IMG_H_MAX = 2560`
#         ⇒ 必须 `IMG_H·IMG_W ≤ PIXW`（`s=1` 时 `IMG_H=H_in`，`4·640 = 2560` 恰落上限）。
#  2) **两条参考口径交叉对账**（同一次 `--emit`，两个**独立工具**各给一份）：
#     · `md5(xcol.hex[s=1,W=64]) == md5(x.hex[wide_exec_ref --lid 0])` —— "平面 → 列流"两次各算一遍，逐字节同；
#     · `md5(gold.hex[s=1,W=64]) == md5(gold.hex[wide_exec_ref --lid 0])` —— `s=1` 的黄金与**冻结 C4a.5b 口径**
#       逐字节同 ⇒ 本闸门的 `s1_real` 用例与既有 `run_unitexec_wide_ab.sh` 的 `lid0_Conv_0`**是同一个作业**
#       ⇒ "`stride=1` 逐字节不变"的**承重证据**（同一装置、同一网表、同一向量）。
#     · 另记 `s2_real640` 的黄金 md5 与 D1 闸门 §6 的 `lid0_s2` **同一值**（同一份真行宽黄金）。
#  3) **结构证据**：网表里 `stride` 口 + 抽稀判据（`effS`/`dm`/`rm`）都在（不是"译码了但没用"）；
#     `tools/check_dangling.py` 零悬空。
#  4) **正对照（逐字节，集成 `UnitExec`）**：每作业 DUT 的 `DST` 区 == 黄金（`MISMATCH=0`）；
#     邻居未动；`WR_BYTES == C_out*IMG_H*IMG_W`；自报 `WIDE_ON=1`、`WIDE_PASSES == n_ci*n_co`、
#     网表行宽 `RTL_IMG_W ∈ [IMG_W·s-s+1, IMG_W·s]`（= DUT `inWOk` 的同式）。
#  5) **负对照（必须发火）**：**外科式网表突变**（每份网表各一刀；只动 `Conv3x3Slice` 里的一行）
#       `assign effS = ((stride == 4'b0000) ? 4'b0001 : stride);`  ->  `assign effS = 4'b0001;`
#     —— 即"**忽略 STRIDE（当成 1）**"：
#       · 打在 `s2_real` / `s2_real640` 上 ⇒ `MISMATCH > 0` 且**定点定位到第一个不符的输出元素**（`co/y/x`）；
#       · 打在 `s1_real` / `s1_real640` 上 ⇒ `MISMATCH == 0`（**这一刀是外科式的**：只切掉步长抽稀）。
#  6) **退化守卫**：每作业黄金 `distinct > 1`；且 `s=2` 的黄金 != `s=1` 的黄金（步长真改了输出）。
#
# ★ 已知边界（明写，见报告）：
#   · **真帧 640×640 整帧**（一趟 ≈ 641×640 列 × 2 趟 ≈ 9M 周期）在 iverilog 下不可行 ⇒ 本闸门用
#     **真行宽的 8 行条带**（`WIDTH=640`、输出 `4×320`，**横向抽稀整段为真**，纵向 4 行输出）——
#     与 D1 的 `run_stride_ab.sh` **同一条取舍**；`WIDTH=64` 的小档另作对照。
#   · `gen/UnitExec_w640.v` 是 `rtl_test/UnitExecGen.scala` 的**第三份**网表（`WIDTH=640 IMG_H_MAX=4 L_MAX=8`）。
#     ★ 该网表的 `mid_rd_col` 观察口是 10 位（`log2Up(640)`）而装置声明 6 位 ⇒ iverilog 打一条
#     "Padding high bits" 告警。该口**仅观察**（`state==IDLE` 时才被 `FusionBuf` 用到，宽通路运行期不吃）
#     ⇒ 无害；装置保持 6 位是为了让既有 `WIDTH=64` 档**零告警**。
#
# 退出码：0 = 全绿；1 = 判据红（正对照不等 / 自报不符 / 退化）；2 = 负对照没发火（判据无牙）；3 = 前置缺失。
#
# 用法：bash y1/tools/run_stride_exec_ab.sh（可 PY= / NL= / NL640= / TB= 覆盖；KEEP_TMP=1 留中间件）
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
cd "$here/.." || { echo "FATAL: 进不去 y1/"; echo "RESULT: FAIL"; exit 3; }

PY="${PY:-/d/code/PDS/NaxYeshenLinux/sim/reglogs/lxvenv/Scripts/python.exe}"
[ -x "$PY" ] || PY="$(command -v python || command -v python3 || true)"
[ -n "$PY" ] || { echo "FATAL: 找不到 python"; echo "RESULT: FAIL"; exit 3; }

tool="tools/stride_ref.py"          # ★ 参考（D1 的那一份，**不写第三条**）
toolw="tools/wide_exec_ref.py"      # ★ 冻结 C4a.5b 口径（只用来做 s=1 的交叉对账）
tb="rtl_test/UnitExecWideTb.v"
memv="rtl_test/AxiMemModel.v"
nl="${NL:-gen/UnitExec.v}"          # WIDTH=64 主网表（小档用例）
nl640="${NL640:-gen/UnitExec_w640.v}"  # WIDTH=640（**真行宽**用例；UnitExecGen 的第三份）
outdir="gen/c4b_stride_exec"
MEMSZ=2621440                       # 必须与 TB 里 AxiMemModel 的 MEMSZ 一致
SRC=$((0x20000)); DST=$((0x200000)) # DST = 0x200000（32B 对齐；与既有宽层闸门同一档）

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
for f in "$tool" "$toolw" "$tb" "$memv" "$nl" "$nl640"; do
  [ -f "$f" ] || { echo "FATAL: 缺 $f"; \
    [ "$f" = "$nl640" ] && echo "      先生成: cd y1 && printf 'Test/runMain UnitExecGen <y1/gen>\\\\nexit\\\\n' | bash sbt.sh"; \
    echo "RESULT: FAIL"; exit 3; }
done
[ -n "$IVERILOG" ] && [ -n "$VVP" ] || { echo "FATAL: 找不到 iverilog/vvp"; echo "RESULT: FAIL"; exit 3; }

work="$(mktemp -d)"
cleanup() { if [ "${KEEP_TMP:-0}" = "1" ]; then echo "KEEP_TMP=1 => 中间件在 $work"; else rm -rf "$work"; fi; }
trap cleanup EXIT
export PYTHONPATH="./.pydeps;../third_party/yunet/deps"
export PYTHONIOENCODING=utf-8
PWD_ABS="$(pwd)"

echo "== run_stride_exec_ab: 集成 UnitExec 级的卷积步长 stride>=2（真网 Conv_0 权重/参数/步长/真行宽）=="
echo "   nl=$nl  nl640=$nl640  tb=$tb  py=$PY  iverilog=$IVERILOG  vvp=$VVP  tmp=$work"

# 逐字节比较（token 文件）-> 不符数（长度不等取较长者；缺一侧 = -1）
cnt() {
  "$PY" - "$1" "$2" <<'PYEOF'
import sys
def load(p):
    try: return [t.lower() for t in open(p, encoding="utf-8", errors="replace").read().split()]
    except OSError: return None
a, b = load(sys.argv[1]), load(sys.argv[2])
print(-1 if (a is None or b is None) else (max(len(a), len(b)) if len(a) != len(b) else sum(1 for i, j in zip(a, b) if i != j)))
PYEOF
}
distinct() {
  "$PY" - "$1" <<'PYEOF'
import sys
try: t = open(sys.argv[1], encoding="utf-8", errors="replace").read().split()
except OSError: print(-1); sys.exit(0)
print(len(set(x.lower() for x in t)) if t else -1)
PYEOF
}

# ---------------- 0) 参考自检 ----------------
echo "---- [0] tools/stride_ref.py --selftest（两套实现互证 + s=1 == 冻结 caliber + s>1 != s=1）----"
if ! "$PY" "$tool" --selftest > "$work/st.out" 2>&1; then
  echo "FATAL: 参考自检没过 ⇒ 用例/参考写错了（不是硬件的问题）"; tail -12 "$work/st.out"; echo "RESULT: FAIL"; exit 3
fi
grep -c '^  PASS' "$work/st.out" | sed 's/^/    PASS 断言数=/'
grep -v '^RESULT:' "$work/st.out" | tail -1 | sed 's/^/    /'

# ---------------- 1) 供料 ----------------
echo "---- [1] 供料：stride_ref --emit —— 真 Conv_0 s=2/s=1（W=64 与 W=640 两档）+ 合成 16->16 s=2 ----"
emit() {
  local d="$1"; shift
  if ! "$PY" "$tool" --emit --outdir "$d" "$@" > "$work/emit.out" 2>&1; then
    echo "JUDGE-RED(3): 供料失败（$*）"; tail -8 "$work/emit.out"; exit 3
  fi
  grep -E '^STRIDE_REF ' "$work/emit.out" | sed 's/^/    /'
}
mkdir -p "$outdir"
emit "$outdir/s2_real"    --lid 0 --stride 2 --h 8 --w 64
emit "$outdir/s1_real"    --lid 0 --stride 1 --h 4 --w 64
emit "$outdir/s2_synth"   --synth 16 16 --stride 2 --h 4 --w 64
emit "$outdir/s2_real640" --lid 0 --stride 2 --h 8 --w 640
emit "$outdir/s1_real640" --lid 0 --stride 1 --h 4 --w 640
for d in s2_real s1_real s2_synth s2_real640 s1_real640; do
  for f in xcol.hex w.hex b.hex gold.hex job.txt; do
    [ -s "$outdir/$d/$f" ] || { echo "FATAL: 缺 $outdir/$d/$f"; echo "RESULT: FAIL"; exit 3; }
  done
done
# 真行宽黄金的**值** md5（与 D1 闸门 §6 的 lid0_s2 gold_md5 可直接比：同一份工具、同一向量、同一几何）
echo "    GOLD640 s2_real640 值md5=$("$PY" -c "import hashlib,sys;print(hashlib.md5(bytes(int(l.strip(),16)&0xFF for l in open(sys.argv[1]) if l.strip())).hexdigest())" "$outdir/s2_real640/gold.hex")（D1 §6 的 lid0_s2 = b5961a8d42a14f01c7c42ba2c1980742）"

# ---------------- 2) 两条参考口径交叉对账（s=1 与冻结 C4a.5b 同作业）----------------
echo "---- [2] 交叉对账：s1_real(W=64) 的列流/黄金 与 冻结 C4a.5b 口径（wide_exec_ref）逐字节同 ----"
if ! "$PY" "$toolw" --lid 0 --H 4 --W 64 --outdir "$work/wide_ref" > "$work/wref.out" 2>&1; then
  echo "JUDGE-RED(3): 冻结 C4a.5b 口径供料失败"; tail -8 "$work/wref.out"; exit 3
fi
grep -E '^WIDE_REF ' "$work/wref.out" | sed 's/^/    /'
wref="$work/wide_ref/lid0_Conv_0"
XR="$(cnt "$outdir/s1_real/xcol.hex" "$wref/x.hex")"
GR="$(cnt "$outdir/s1_real/gold.hex" "$wref/gold.hex")"
echo "    CROSS xcol.hex(s=1,W=64) vs wide_exec_ref x.hex   : MISMATCH=$XR （期望 0）"
echo "    CROSS gold.hex(s=1,W=64) vs wide_exec_ref gold.hex: MISMATCH=$GR （期望 0）"
XCHK_BAD=0
[ "$XR" = "0" ] || { echo "JUDGE-RED(2): s=1 的列流与冻结口径不同（$XR）⇒ 装置口径走岔了"; XCHK_BAD=$((XCHK_BAD+1)); }
[ "$GR" = "0" ] || { echo "JUDGE-RED(2): s=1 的黄金与冻结口径不同（$GR）⇒ 本闸门的 s1_real 不是既有作业"; XCHK_BAD=$((XCHK_BAD+1)); }

# ---------------- 3) 结构证据 ----------------
echo "---- [3] 结构证据：两份网表里 stride 口 + 抽稀判据（effS/dm/rm）都在 ----"
for n in "$nl" "$nl640"; do
  echo "  [$n]"
  "$PY" - "$n" <<'PYEOF'
import sys
try: sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception: pass
src = open(sys.argv[1], encoding="utf-8", errors="replace").read()
need = {"stride 口": "input  wire [3:0]    stride,",
        "effS（0 视作 1）": "assign effS = ((stride == 4'b0000) ? 4'b0001 : stride);",
        "列相位": "assign dmNext = ((dm == effSm1)",
        "行相位": "assign rmNext = ((rm == effSm1)"}
ok = True
for k, v in need.items():
    n = src.count(v)
    print("    %-4s %s（命中 %d 处）" % ("OK" if n >= 1 else "BAD", k, n))
    if n < 1: ok = False
print("    STRUCT: %s" % ("PASS" if ok else "FAIL"))
sys.exit(0 if ok else 1)
PYEOF
  [ $? -eq 0 ] || { echo "JUDGE-RED: 结构判据红（$n）"; echo "RESULT: FAIL"; exit 1; }
  if [ -f tools/check_dangling.py ]; then
    "$PY" tools/check_dangling.py "$n" | grep -v '^RESULT:' | tail -1 | sed 's/^/    /'
    "$PY" tools/check_dangling.py "$n" >/dev/null || { echo "JUDGE-RED: 有悬空实例（$n）"; echo "RESULT: FAIL"; exit 1; }
  fi
done

# ---------------- 4) 编译（两份好网表 + 两份"忽略 STRIDE"突变体）----------------
echo "---- [4] iverilog 编译（UnitExecWideTb + AxiMemModel + 两份网表 / 两份突变体）----"
ivc() { # ivc <out-vvp> <netlist> <tag>
  if ! "$IVERILOG" -g2012 -o "$1" "$tb" "$memv" "$2" > "$work/iv_$3.log" 2>&1; then
    echo "JUDGE-RED(1): iverilog 编译失败（$3）"; sed -n '1,25p' "$work/iv_$3.log"; echo "RESULT: FAIL"; exit 1
  fi
  if grep -qi 'warning' "$work/iv_$3.log"; then
    echo "    告警（$3，留意）:"; grep -i 'warning' "$work/iv_$3.log" | head -2 | sed 's/^/      /'
  fi
}
ivc "$work/good.vvp"   "$nl"     "good"
ivc "$work/good640.vvp" "$nl640" "good640"
echo "    好网表编译 OK（WIDTH=64 与 WIDTH=640 两档）"
# 突变体：每份网表各一刀（同一外科式突变）
mutgen() { # mutgen <netlist> <out>
  "$PY" - "$1" "$2" <<'PYEOF'
import sys
try: sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception: pass
src = open(sys.argv[1], encoding="utf-8", errors="replace").read()
a = "  assign effS = ((stride == 4'b0000) ? 4'b0001 : stride);"
b = "  assign effS = 4'b0001;   // MUT: ignore STRIDE (force stride=1)"
n = src.count(a)
if n != 1:
    print("MUT-ERROR: %s 里 effS 命中 %d 处（期望 1）" % (sys.argv[1], n)); sys.exit(1)
open(sys.argv[2], "w", encoding="utf-8", newline="\n").write(src.replace(a, b))
print("MUT: %s 的 Conv3x3Slice effS -> 4'b0001（1 处）⇒ **忽略 STRIDE**" % sys.argv[1])
PYEOF
}
mutgen "$nl" "$work/mut_stride.v" || { echo "JUDGE-RED(2): 构造突变体失败"; echo "RESULT: FAIL"; exit 2; }
mutgen "$nl640" "$work/mut_stride640.v" || { echo "JUDGE-RED(2): 构造突变体失败"; echo "RESULT: FAIL"; exit 2; }
ivc "$work/mut.vvp"    "$work/mut_stride.v"    "mut"
ivc "$work/mut640.vvp" "$work/mut_stride640.v" "mut640"
echo "    突变体编译 OK（外科式：只动切片里的那一行）"

# ---------------- 5) 逐作业：正对照（逐字节）+ 自报 + 退化守卫 ----------------
TOTAL_BAD=0; NEG_NOFIRE=0; JOBS=""

memgen() { # memgen <dir>  —— 素周期 251 的镜像；DST 区预载与黄金压倒性不同 ⇒ "不写"必被抓住
  local d="$1"
  "$PY" - "$d" "$work" "$MEMSZ" "$DST" <<'PYEOF'
import sys
d, work, memsz, dst = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
g = [int(l.strip(), 16) for l in open(d + "/gold.hex") if l.strip()]
ln = len(g)
pre = [((i % 251) * 131 + 7) % 251 for i in range(memsz)]
dif = sum(1 for j in range(ln) if pre[dst + j] != g[j])
assert dif >= int(ln * 0.9), "dst 预载与黄金只差 %d/%d" % (dif, ln)
txt = "".join("%02x\n" % b for b in pre)
open(work + "/mem.hex", "w").write(txt)      # 每作业覆盖同名文件（作业逐个跑）
open(work + "/pre.hex", "w").write(txt)
print("MEMGEN %s dst_len=%d dst_preload_vs_gold_diff=%d/%d" % (d.split('/')[-1], ln, dif, ln))
PYEOF
}

judge_dst() { # judge_dst <dump> <gold> <len> <out>  -> MISMATCH / 邻居 / 首个不符元素
  "$PY" - "$1" "$2" "$3" "$4" "$DST" <<'PYEOF'
import sys
try: sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception: pass
dump, gold, ln, out, dst = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4], int(sys.argv[5])
def load(p):
    o = []
    for l in open(p, encoding="utf-8", errors="replace"):
        s = l.strip()
        if not s: continue
        try: o.append(int(s, 16) & 0xFF)
        except ValueError: o.append(-1)
    return o
d = load(dump); g = load(gold); p = load(dump.rsplit('/', 1)[0] + "/pre.hex")
k = min(ln, len(g))
first = -1
for i in range(k):
    if dst + i >= len(d) or d[dst + i] != g[i]:
        first = i; break
mis = sum(1 for i in range(k) if dst + i >= len(d) or d[dst + i] != g[i]) + max(0, ln - k)
nb = 0
if dst >= 32:
    nb += sum(1 for i in range(32) if d[dst - 32 + i] != p[dst - 32 + i])
for i in range(32):
    if dst + ln + i < len(d) and d[dst + ln + i] != p[dst + ln + i]: nb += 1
res = ["MISMATCH=%d" % mis, "DST_NEIGHBOR32_BAD=%d" % nb, "FIRST_IDX=%d" % first]
open(out, "w").write("\n".join(res) + "\n")
print("\n".join(res))
PYEOF
}

# run_job <vvp> <dir> <tag>  —— 从 job.txt 组 plusarg 跑一次（列流 = xcol.hex）
run_job() {
  local vvp="$1" d="$2" tag="$3"
  local CIN COUT HIN WIN H W NCOL INB STRIDE M ZP ZY NCI NCO
  CIN="$(sed -n 's/^CIN=//p' "$d/job.txt")";  COUT="$(sed -n 's/^COUT=//p' "$d/job.txt")"
  HIN="$(sed -n 's/^HIN=//p' "$d/job.txt")";  WIN="$(sed -n 's/^WIN=//p' "$d/job.txt")"
  H="$(sed -n 's/^HO=//p' "$d/job.txt")";     W="$(sed -n 's/^WO=//p' "$d/job.txt")"
  STRIDE="$(sed -n 's/^STRIDE=//p' "$d/job.txt")"; M="$(sed -n 's/^M=//p' "$d/job.txt")"
  ZP="$(sed -n 's/^ZPAD=//p' "$d/job.txt")";  ZY="$(sed -n 's/^ZY=//p' "$d/job.txt")"
  NCI="$(sed -n 's/^NCI=//p' "$d/job.txt")";  NCO="$(sed -n 's/^NCO=//p' "$d/job.txt")"
  NCOL="$(sed -n 's/^NCOL=//p' "$d/job.txt")"; INB=$(( CIN * HIN * WIN ))
  ( cd "$work" && "$VVP" "$vvp" \
      "+XFILE=$PWD_ABS/$d/xcol.hex" "+WFILE=$PWD_ABS/$d/w.hex" "+BFILE=$PWD_ABS/$d/b.hex" \
      "+MEMFILE=$work/mem.hex" "+DUMPFILE=$work/$tag.dump" +dump \
      "+CIN=$CIN" "+COUT=$COUT" "+GROUP=1" "+H=$H" "+W=$W" "+TYPE=1" "+FLAGS=1" \
      "+SRC=$SRC" "+DST=$DST" "+INB=$INB" "+QSHIFT=6" "+LID=0" \
      "+M=$M" "+ZPAD=$ZP" "+ZY=$ZY" "+NCOL=$NCOL" "+NCI=$NCI" "+NCO=$NCO" "+STRIDE=$STRIDE" ) \
      > "$work/$tag.log" 2>&1
}

# 作业表：<tag>:<n64|n640>:<stride>
JOBTABLE=" s2_real:n64:2 s1_real:n64:1 s2_synth:n64:2 s2_real640:n640:2 s1_real640:n640:1 "
vvp_of() { case "$1" in n64) printf '%s' "$work/good.vvp" ;; n640) printf '%s' "$work/good640.vvp" ;; esac; }
mut_of() { case "$1" in n64) printf '%s' "$work/mut.vvp" ;; n640) printf '%s' "$work/mut640.vvp" ;; esac; }
nlf_of() { case "$1" in n64) printf '%s' "$nl" ;; n640) printf '%s' "$nl640" ;; esac; }

echo "---- [5] 逐作业：集成 UnitExec 的 DST 区逐字节 == 黄金 + 自报 + 退化守卫 ----"
for spec in $JOBTABLE; do
  tag="${spec%%:*}"; rest="${spec#*:}"; net="${rest%%:*}"; s="${rest##*:}"
  d="$outdir/$tag"
  STRIDE="$(sed -n 's/^STRIDE=//p' "$d/job.txt")"
  M="$(sed -n 's/^M=//p' "$d/job.txt")"; ZP="$(sed -n 's/^ZPAD=//p' "$d/job.txt")"
  ZY="$(sed -n 's/^ZY=//p' "$d/job.txt")"
  NCI="$(sed -n 's/^NCI=//p' "$d/job.txt")"; NCO="$(sed -n 's/^NCO=//p' "$d/job.txt")"
  NPASS="$(sed -n 's/^NPASS=//p' "$d/job.txt")"
  HO_="$(sed -n 's/^HO=//p' "$d/job.txt")"; WO_="$(sed -n 's/^WO=//p' "$d/job.txt")"
  COUT="$(sed -n 's/^COUT=//p' "$d/job.txt")"; NCOL="$(sed -n 's/^NCOL=//p' "$d/job.txt")"
  LEN=$(( COUT * HO_ * WO_ ))
  JOBS="$JOBS $tag(s=$s,$net)"
  memgen "$d" | sed 's/^/    /'
  run_job "$(vvp_of "$net")" "$d" "pos_$tag"
  grep -E '^(TB WIDE|DONE_SEEN|RESULT)' "$work/pos_$tag.log" | sed "s/^/    [$tag] /"
  if ! grep -q '^RESULT: PASS' "$work/pos_$tag.log"; then
    echo "JUDGE-RED(1): 正对照装置未 PASS（$tag）"; tail -8 "$work/pos_$tag.log"; TOTAL_BAD=$((TOTAL_BAD+1)); continue
  fi
  REP="$(grep -m1 '^TB WIDE RTL:' "$work/pos_$tag.log")"
  IMGW="$(printf '%s' "$REP" | sed -n 's/.*imgW=\([0-9]*\).*/\1/p')"
  RMAXP="$(printf '%s' "$REP" | sed -n 's/.*RTL_MAXPIX=\([0-9]*\).*/\1/p')"
  LO=$(( WO_ * s - s + 1 )); HI=$(( WO_ * s ))
  if [ "$IMGW" -lt "$LO" ] || [ "$IMGW" -gt "$HI" ]; then
    echo "JUDGE-RED(1): 网表行宽 imgW=$IMGW 不在 inWOk 区间 [$LO,$HI]（$tag）"; TOTAL_BAD=$((TOTAL_BAD+1))
  fi
  # 前提（网表展开期的输出存储上限）：`IMG_H·IMG_W ≤ PIXW = WIDTH·IMG_H_MAX`（= 自报 RTL_MAXPIX）
  if [ "$(( HO_ * WO_ ))" -gt "$RMAXP" ]; then
    echo "JUDGE-RED(1): HO*WO=$(( HO_ * WO_ )) > 网表 RTL_MAXPIX=$RMAXP（$tag）⇒ 用例几何越出该网表上限"; TOTAL_BAD=$((TOTAL_BAD+1))
  fi
  case "$REP" in
    *"WIDE_ON=1 WIDE_PASSES=$NPASS"*) : ;;
    *) echo "JUDGE-RED(1): 自报不符（$tag）got=$REP"; TOTAL_BAD=$((TOTAL_BAD+1));;
  esac
  judge_dst "$work/pos_$tag.dump" "$d/gold.hex" "$LEN" "$work/pos_$tag.judge" | sed 's/^/    /'
  MPOS="$(sed -n 's/^MISMATCH=//p' "$work/pos_$tag.judge")"
  NB="$(sed -n 's/^DST_NEIGHBOR32_BAD=//p' "$work/pos_$tag.judge")"
  GD="$(distinct "$d/gold.hex")"
  [ "$MPOS" = "0" ] || { echo "JUDGE-RED(1): 正对照 != 黄金（MISMATCH=$MPOS，$tag）"; TOTAL_BAD=$((TOTAL_BAD+1)); }
  [ "$NB" = "0" ] || { echo "JUDGE-RED(1): dst 邻居被改（$NB，$tag）"; TOTAL_BAD=$((TOTAL_BAD+1)); }
  [ "$GD" -gt 1 ] 2>/dev/null || { echo "JUDGE-RED(1): 黄金退化 distinct=$GD（$tag）"; TOTAL_BAD=$((TOTAL_BAD+1)); }
  echo "JOB $tag net=$net STRIDE=$s M=$M ZPAD=$ZP ZY=$ZY n_ci=$NCI n_co=$NCO passes=$NPASS NCOL=$NCOL | DST_MISMATCH=$MPOS neigh=$NB distinct(gold=$GD) imgW=$IMGW in [$LO,$HI]"
done

# 黄金分辨度：s=2 与 s=1 的黄金必须不同（同一档网表内比：形状不同 ⇒ >0）
G640="$(cnt "$outdir/s2_real640/gold.hex" "$outdir/s1_real640/gold.hex")"
G64="$(cnt "$outdir/s2_real/gold.hex" "$outdir/s1_real/gold.hex")"
for gv in "$G640" "$G64"; do
  [ "$gv" != "0" ] || { echo "NEGCTL-FAIL: s=2 与 s=1 的黄金完全相同 ⇒ 步长没被刻画"; NEG_NOFIRE=$((NEG_NOFIRE+1)); }
done
echo "GOLD 分辨度：s=2 vs s=1 的黄金差 W=640: $G640 / W=64: $G64 个 token（>0 ⇒ 步长真改了输出）"

# ---------------- 6) 负对照："忽略 STRIDE" 突变体（两份网表各一刀）----------------
echo "---- [6] 负对照：网表突变"忽略 STRIDE" ⇒ s=2 必红（定位首个不符元素）+ s=1 必绿（外科式）----"
neg_run() { # neg_run <net> <dir> <tag>
  local net="$1" d="$2" tag="$3"
  local COUT HO_ WO_ LEN
  COUT="$(sed -n 's/^COUT=//p' "$d/job.txt")"
  HO_="$(sed -n 's/^HO=//p' "$d/job.txt")"; WO_="$(sed -n 's/^WO=//p' "$d/job.txt")"
  LEN=$(( COUT * HO_ * WO_ ))
  memgen "$d" >/dev/null
  run_job "$(mut_of "$net")" "$d" "$tag"
  judge_dst "$work/$tag.dump" "$d/gold.hex" "$LEN" "$work/$tag.judge" > "$work/$tag.out" 2>&1
  sed -n 's/^MISMATCH=//p' "$work/$tag.out"
}
for spec in "n64:s2_real" "n640:s2_real640"; do
  net="${spec%%:*}"; tag="${spec##*:}"; d="$outdir/$tag"
  MUT_S2="$(neg_run "$net" "$d" "mut_$tag")"
  grep -E '^(TB WIDE RTL|DONE_SEEN|RESULT)' "$work/mut_$tag.log" | sed "s/^/    [mut_$tag] /" || true
  F_IDX="$(sed -n 's/^FIRST_IDX=//p' "$work/mut_$tag.out")"
  if ! [ "$MUT_S2" -gt 0 ] 2>/dev/null; then
    echo "NEGCTL-FAIL: 忽略 STRIDE 后 $tag 的输出没变（MISMATCH=$MUT_S2）⇒ 判据无牙"; NEG_NOFIRE=$((NEG_NOFIRE+1))
  fi
  if [ "$F_IDX" -ge 0 ] 2>/dev/null; then
    WO__="$(sed -n 's/^WO=//p' "$d/job.txt")"; HO__="$(sed -n 's/^HO=//p' "$d/job.txt")"
    LOC="$("$PY" -c "i=$F_IDX; W=$WO__; HW=$((HO__*WO__)); print('co=%d y=%d x=%d'%(i//HW,(i%HW)//W,(i%HW)%W))")"
  else
    LOC="（长度不符/无逐点证据）"
  fi
  echo "NEG-A $tag + 突变体（$net 网表）：MISMATCH=$MUT_S2（>0 **必须**）  首个不符输出元素: FIRST_IDX=$F_IDX  $LOC"
done
for spec in "n64:s1_real" "n640:s1_real640"; do
  net="${spec%%:*}"; tag="${spec##*:}"; d="$outdir/$tag"
  MUT_S1="$(neg_run "$net" "$d" "mut_$tag")"
  [ "$MUT_S1" = "0" ] || { echo "JUDGE-RED(2): 突变体打在本该 stride=1 的用例上却也变了（MISMATCH=$MUT_S1，$tag）⇒ 这一刀不是外科式"; TOTAL_BAD=$((TOTAL_BAD+1)); }
  echo "NEG-B $tag + 同一突变体（$net 网表）：MISMATCH=$MUT_S1（==0 ⇒ 这一刀只切掉步长抽稀）"
done

# ---------------- 判决 ----------------
echo "=========================================================================="
echo "参考     = OK（stride_ref --selftest：两套实现互证；s=1 == 冻结 C4a.5b caliber）"
echo "交叉对账 = OK（s=1 的列流/黄金 == wide_exec_ref（冻结 C4a.5b）逐字节 ⇒ 与 run_unitexec_wide_ab.sh 的 lid0 同作业）"
echo "正对照   = OK（集成 UnitExec：真行宽 640 的 s=2（4x320，横向抽稀 640->320 整段）+ W=64 两档 + 合成 16->16，DST 逐字节 == 黄金）"
echo "结构     = OK（两份网表都有 stride 口 + effS/dm/rm 抽稀判据；零悬空）"
echo "负对照   = 见上（忽略 STRIDE：s=2 必红且定位首个不符元素、s=1 必绿 ⇒ 定点发火 + 外科式）"
if [ "$XCHK_BAD" -ne 0 ]; then echo "JUDGE-RED: 交叉对账未过"; echo "RESULT: FAIL"; exit 1; fi
if [ "$NEG_NOFIRE" -ne 0 ]; then echo "NEGCTL-FAIL: $NEG_NOFIRE 条负对照没发火"; echo "RESULT: FAIL"; exit 2; fi
if [ "$TOTAL_BAD" -ne 0 ]; then echo "JUDGE-RED: $TOTAL_BAD 条判据未过"; echo "RESULT: FAIL"; exit 1; fi
echo "作业集合：$JOBS"
echo "STRIDE_EXEC_RESULT: PASS"
echo "RESULT: PASS"
exit 0
