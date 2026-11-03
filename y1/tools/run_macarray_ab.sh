#!/usr/bin/env bash
# run_macarray_ab.sh —— 8x8 int8 MAC 阵列（rtl/MacArray.scala）的装置级数值闸门。
#
# 六项职责（与 tools/run_numeric_ab.sh 同风格）：
#   1) 造向量：手写小算例（**输入**是手写的，**期望值**由 python 现算，绝不手抄），
#      每行一个十六进制字节，正好是 $readmemh 的输入格式；
#   2) 编译并仿真 rtl_test/MacArrayTb.v + gen/MacArray.v，收一行 "Y <hh> <hh> ..."；
#   3) 逐字节对账装置的 Y 与 python 的期望，打印**唯一一行** MISMATCH=<不等字节数>；
#   4) 负对照（三发，缺一不可）：
#      ① 只改预期文件里**一个字节**，拿装置的 Y 重跑对账 ⇒ 必须**恰好** 1 个字节不符。
#         这一发证明对账口径是**逐字节**而不是按行：按行 diff 时 1 个字节和 500 个字节
#         都只报"1 行不同"，MISMATCH 就失去意义。
#      ② 把损伤后的期望文件当 +YFILE 喂给装置**重跑仿真** ⇒ 装置自己的自检必须报
#         RESULT: FAIL 且 vvp 非 0 退出。这一发证明装置不是只会打印 Y 的哑巴：
#        它的 PASS/FAIL 确实接在回路上。
#      ③ ★"无死乘法器"判据（本任务新增，就是本该抓住 B2 那个缺陷的判据）：
#         逐个扰动 64 个**权重瓦片槽位** (co,ci)，要求**对应的**输出 p(co) 必须变
#         （alive），且**其余 7 个输出一个字节都不许动**（isolation）。完整 64 槽。
#         判据有牙的证明（自带的负对照）：把同一份网表**文本折叠成 rank-1**
#         （每行的 8 个 w 操作数全换成 w(co)(0)，语义 = 旧缺陷 p(co)=w(co)·Σx(ci)），
#         再跑同一个检查器 ⇒ 必须报 dead=56/64（只有第 0 列有导线）。若突变体也报 0 死槽，
#         说明判据是橡皮图章 ⇒ 退出 2。
#   5) 结构性判据（静态，不跑仿真）：module MacArray 里必须有 **64 个乘法表达式**，
#      且**每个输出行 8 个 w 操作数互不相同**、全阵列 64 个互不相同的 w 操作数，
#      并且每个乘积里的 x 下标必须与该 w 的 ci 下标配对（w(co)(ci) 配 x(ci)）。
#      旧 rank-1 网表的实测值：64 个乘法器、但每行只有 1 个互异 w、全阵列只有 8 个
#      互异 w ⇒ 本判据必红。突变体同一套判据也必须红（否则判据没牙 ⇒ 退出 2）。
#   任一发没抓住 ⇒ 判据无效（橡皮图章）⇒ 退出 2。
#
# 退出码：
#   0 = 通过（MISMATCH=0 + 三发负对照都抓住 + 64 槽无死乘法器 + 结构判据绿）
#   1 = 对账不符 / 编译或仿真失败 / 装置没打印 Y / 有死乘法器 / 结构判据红
#   2 = 负对照没抓住损伤 ⇒ 闸门自身不可信
#   3 = 向量自检失败（用例写错）
#
# 装置契约（B3/B4 沿用）：rtl_test/MacArrayTb.v + gen/MacArray.v
#   +XFILE=<file> 每行一个 hex 字节，beat-major [k][ci]              （每拍 8 字节）
#   +WFILE=<file> 同上，beat-major [k][co][ci] = 权重瓦片 w(co)(ci)  （每拍 **64** 字节）
#   +YFILE=<file> 每行一个 hex 字节，期望 int32 的**小端**字节 [co][byte] ⇒ 32 字节
#   +K=<n>        喂几拍，默认 1
#   装置打印一行 "Y <hh> ..."（32 字节）再一行 "RESULT: PASS|FAIL"；FAIL 时 $fatal ⇒ 非 0。
set -uo pipefail

PY="${PY:-python}"
here="$(cd "$(dirname "$0")" && pwd)"
rtl="$here/../gen/MacArray.v"
tb="$here/../rtl_test/MacArrayTb.v"

work="$(mktemp -d)"
cleanup() {
  if [ "${KEEP_TMP:-0}" = "1" ]; then
    echo "KEEP_TMP=1 ⇒ 向量与日志留在 $work"
  else
    rm -rf "$work"
  fi
}
trap cleanup EXIT

echo "== run_macarray_ab: 8x8 int8 MAC 阵列（真权重瓦片 w(co)(ci)，一拍 64 个有用 MAC）数值对账 =="
echo "   rtl=$rtl"
echo "   tb =$tb"
echo "   tmp=$work"

# ---------------- 1) 造向量 + 算期望 ----------------
# 用例全部手写**输入**；期望的 int32 累加和由 python 现算（不手抄数字）。
# ★ 权重瓦片的每一行都必须**随 ci 变化**：若某行 8 个权重全相同（例如"全 1"），
#   rank-1 缺陷算出来的值恰好和真瓦片一样，这个用例就抓不到缺陷 —— 见下面的
#   "RANK1-SENSITIVE" 自检（它对每个用例量出"与 rank-1 折叠差几个通道"）。
"$PY" - "$work" <<'PYEOF'
import os, sys
try:
    # Windows 控制台是 GBK：显式按 UTF-8 写（errors=replace 兜底），否则中文打印出来是乱码。
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

NCI = NCO = 8
NB = NCI * NCO            # 每拍权重瓦片 = 64 个 entry

def ones():
    return [[1] * NCI for _ in range(NCO)]

CASES = [
    # ① 老用例：X=1..8，权重瓦片全 1 ⇒ 每个 p(co)=36。
    #    ★ 注意：这个用例 rank-1 缺陷 **也** 能过（tariff: 全 1 瓦片折叠后同值），
    #    所以它**不能**单独当"阵列是瓦片"的证据 —— 下面会把它标成 SENSITIVE=0/8。
    dict(name="pos_unit", K=1,
         X=[[1, 2, 3, 4, 5, 6, 7, 8]],
         W=[ones()]),
    # ② 负例 + 压位宽：x 全正、每行权重全负且**随 ci 变化**（-128..-125）⇒ 8 个通道结果都是
    #    大负数，|p| 远超 int16 ⇒ 只有真正的 int32 符号扩展累加才能对上（先截到 16 位必然错），
    #    且高字节是 0xff。
    dict(name="neg_wide", K=3,
         X=[[127] * 8, [100] * 8, [64] * 8],
         W=[[[-128 + ((co + ci + k) % 4) for ci in range(NCI)] for co in range(NCO)]
            for k in range(0, 3)]),
    # ③ 正例 + 压位宽：第 0 拍 x 全 127、权重全正且随 ci 变化（123..127）；
    #    第 1 拍 x 全 -128、权重偶数 ci 负/奇数 ci 正 ⇒ 每个 co 走的符号路径都不同，
    #    合起来是大正数（>int16），且每一行的瓦片都随 ci 变化。
    dict(name="pos_wide", K=2,
         X=[[127] * 8, [-128] * 8],
         W=[[[127 - ((co * 3 + ci) % 5) for ci in range(NCI)] for co in range(NCO)],
            [[(-128 if ci % 2 == 0 else 127) for ci in range(NCI)] for co in range(NCO)]]),
]

def hx(v):
    assert -128 <= v <= 127, "not int8: %d" % v
    return "%02x" % (v & 0xff)

def by(v):
    """int32 的原始字节（0..255），不做 int8 检查（期望值的高字节本来就 >127）。"""
    return "%02x" % (v & 0xff)

def le32(v):
    return [(v >> (8 * i)) & 0xff for i in range(4)]

def yline(Y):
    return " ".join(by(b) for b in [b for co in range(NCO) for b in le32(Y[co])])

def ref_tile(X, W, K):
    """真瓦片参考：p(co) = Σ_k Σ_ci sig8(x_k(ci))·sig8(W_k(co)(ci))，全程 int32。"""
    return [sum(X[k][ci] * W[k][co][ci] for k in range(K) for ci in range(NCI))
            for co in range(NCO)]

def ref_rank1(X, W, K):
    """rank-1 折叠参考（旧缺陷的语义）：p(co) = Σ_k Σ_ci x_k(ci)·W_k(co)(0)。
    这里的"折叠"= 只留每行第 0 列（任何单列都一样，等价于旧接口只有 8 个标量权重）。"""
    return [sum(X[k][ci] * W[k][co][0] for k in range(K) for ci in range(NCI))
            for co in range(NCO)]

outdir = sys.argv[1]
INT32_MIN, INT32_MAX = -(1 << 31), (1 << 31) - 1
wide_cases = 0
sens_cases = 0
for cs in CASES:
    X, W, K, name = cs["X"], cs["W"], cs["K"], cs["name"]
    # 向量自检：用例写错时立刻炸，别把错向量喂给装置
    assert len(X) == K and len(W) == K, "%s: K 与 beats 数不符" % name
    for row in X:
        assert len(row) == NCI, "%s: 每个 beat 要给满 %d 个输入通道" % (name, NCI)
    for plank in W:
        assert len(plank) == NCO and all(len(r) == NCI for r in plank), \
            "%s: 每拍要给满 8x8 的权重瓦片" % name
    assert all(-128 <= v <= 127 for row in X for v in row), "%s: x 不是 int8" % name
    assert all(-128 <= v <= 127 for p in W for r in p for v in r), "%s: w 不是 int8" % name

    d = os.path.join(outdir, name)
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, "x.hex"), "w", encoding="ascii", newline="\n") as f:
        f.write("".join(hx(v) + "\n" for row in X for v in row))
    with open(os.path.join(d, "w.hex"), "w", encoding="ascii", newline="\n") as f:
        f.write("".join(hx(v) + "\n" for k in range(K) for co in range(NCO) for v in W[k][co]))

    Y = ref_tile(X, W, K)
    assert all(INT32_MIN <= y <= INT32_MAX for y in Y), "%s: 参考溢出 int32" % name
    yb = [b for co in range(NCO) for b in le32(Y[co])]
    with open(os.path.join(d, "y.hex"), "w", encoding="ascii", newline="\n") as f:
        f.write("".join(by(v) + "\n" for v in yb))
    with open(os.path.join(d, "exp.txt"), "w", encoding="ascii", newline="\n") as f:
        f.write("Y " + yline(Y) + "\n")

    wide = sum(1 for y in Y if abs(y) > 32767)
    if wide:
        wide_cases += 1
    # rank-1 敏感度：这个用例能不能区分"真瓦片"与"rank-1 折叠"
    R1 = ref_rank1(X, W, K)
    nsens = sum(1 for a, b in zip(Y, R1) if a != b)
    if nsens:
        sens_cases += 1
    print("   case=%-9s K=%d  Y=%s" % (name, K, " ".join(str(y) for y in Y)))
    print("             压位宽自检: |Y|>32767 的通道数=%d/8  Y 范围=[%d,%d]"
          % (wide, min(Y), max(Y)))
    print("             RANK1-SENSITIVE: 与 rank-1 折叠值不同的通道数=%d/8%s"
          % (nsens, "   ★ 此用例抓不到 rank-1 缺陷（瓦片每行同值）" if not nsens else ""))

assert wide_cases > 0, "所有用例都没超出 int16 量级 ⇒ 压不住'别截到 16 位'这条"
assert sens_cases > 0, "所有用例都对 rank-1 折叠不敏感 ⇒ 数值用例抓不到该缺陷（需要至少一个随 ci 变化的瓦片）"
print("   向量自检: %d 个用例，其中 %d 个含 |Y|>32767 的分量（int32 累加被真正压到），"
      "%d 个对 rank-1 折叠敏感" % (len(CASES), wide_cases, sens_cases))

# ---- 无死乘法器判据的向量：K=2 拍、瓦片每个 entry 都有值且随 (co,ci,k) 变化 ----
# 探针要求：第 0 拍扰动槽 (co,ci) 时 Δp(co) = x_0(ci) ≠ 0（保证"该变"是可达的，判据不空转）。
def probe_tile(k, co, ci):
    return ((co * 7 + ci * 5 + k * 3) % 9) - 4      # 值域 [-4,4]，int8 安全

PX = [[1, 2, 3, 4, 5, 6, 7, 8],
      [2, 3, 5, 7, 11, 13, 17, 19]]
PK = len(PX)
PW = [[[probe_tile(k, co, ci) for ci in range(NCI)] for co in range(NCO)] for k in range(PK)]
# 判据有牙的前提：每一列都得有非零激励（否则"扰动没反应"是向量的问题，不是硬件的问题）
for ci in range(NCI):
    assert PX[0][ci] != 0, "dead-slot 探针: 第 0 拍 x(%d) 为 0 ⇒ 扰动不可见" % ci

pdr = os.path.join(outdir, "deadslot")
for sub in ("dut", "mut"):
    os.makedirs(os.path.join(pdr, sub), exist_ok=True)
os.makedirs(os.path.join(outdir, "probe"), exist_ok=True)
with open(os.path.join(pdr, "x.hex"), "w", encoding="ascii", newline="\n") as f:
    f.write("".join(hx(v) + "\n" for row in PX for v in row))

def write_w(path, W):
    with open(path, "w", encoding="ascii", newline="\n") as f:
        f.write("".join(hx(W[k][co][ci]) + "\n" for k in range(PK)
                        for co in range(NCO) for ci in range(NCI)))

# 基准（未扰动）瓦片：dut 用真瓦片参考，mut 用 rank-1 折叠参考（突变体是台"好用的 rank-1"）
write_w(os.path.join(pdr, "dut", "base.w.hex"), PW)
Yb = ref_tile(PX, PW, PK)
Yb_r1 = ref_rank1(PX, PW, PK)
for sub, Y in (("dut", Yb), ("mut", Yb_r1)):
    with open(os.path.join(pdr, sub, "base.y.hex"), "w", encoding="ascii", newline="\n") as f:
        f.write("".join(by(v) + "\n" for v in [b for co in range(NCO) for b in le32(Y[co])]))
    with open(os.path.join(pdr, sub, "base.exp.txt"), "w", encoding="ascii", newline="\n") as f:
        f.write("Y " + yline(Y) + "\n")

slots = []
for co in range(NCO):
    for ci in range(NCI):
        P2 = [[[v for v in row] for row in plank] for plank in PW]
        assert P2[0][co][ci] + 1 <= 127
        P2[0][co][ci] += 1                     # 第 0 拍这一个槽 +1（正好一个字节）
        write_w(os.path.join(pdr, "dut", "%d_%d.w.hex" % (co, ci)), P2)
        Yd = ref_tile(PX, P2, PK)
        Yr = ref_rank1(PX, P2, PK)
        for sub, Y in (("dut", Yd), ("mut", Yr)):
            with open(os.path.join(pdr, sub, "%d_%d.y.hex" % (co, ci)), "w",
                      encoding="ascii", newline="\n") as f:
                f.write("".join(by(v) + "\n" for v in [b for c in range(NCO) for b in le32(Y[c])]))
        for c in range(NCO):
            if c == co:
                continue
            assert Yd[c] == Yb[c], "dead-slot 探针: 扰动 (%d,%d) 竟然动了 p(%d) 的期望值" % (co, ci, c)
        assert Yd[co] != Yb[co], "dead-slot 探针: 扰动 (%d,%d) 的期望值没变 ⇒ 判据空转" % (co, ci)
        slots.append((co, ci))
with open(os.path.join(pdr, "slots.txt"), "w", encoding="ascii", newline="\n") as f:
    f.write("".join("%d %d\n" % (co, ci) for co, ci in slots))
print("   dead-slot 探针: %d 个槽位，每槽 Δp(co)=x_0(ci)=ci+1（非 0，判据不空转）；"
      "同一份向量也喂 rank-1 突变体（其 +YFILE 用 rank-1 参考）" % len(slots))
PYEOF
if [ $? -ne 0 ]; then
  echo "FATAL: 向量/期望构造或自检失败"; exit 3
fi

# 用例名按上面 python 里的顺序（bash 只用来循环驱动）
CASES="pos_unit:1 neg_wide:3 pos_wide:2"

# ---------------- 2) 编译 + 仿真 ----------------
iv="$(command -v iverilog 2>/dev/null || true)"
echo "   iverilog: ${iv:-<PATH 上找不到>}"
[ -n "$iv" ] && echo "   version : $(iverilog -V 2>&1 | head -1)"

if [ ! -f "$rtl" ]; then
  echo "JUDGE-RED: 装置 Verilog 不存在：$rtl"
  echo "  先跑：printf 'Test/runMain MacArrayGen <abs gen 目录>\\nexit\\n' | bash sbt.sh"
  exit 1
fi
if [ -z "$iv" ]; then
  echo "JUDGE-RED: 找不到 iverilog，无法仿真"; exit 1
fi
if ! iverilog -g2012 -o "$work/dut_sim.vvp" "$tb" "$rtl" > "$work/iv.log" 2>&1; then
  echo "JUDGE-RED: iverilog 编译失败"; sed -n '1,30p' "$work/iv.log"; exit 1
fi

# 逐字节对账：cnt_y <期望文件> <实际文件> ⇒ 打印两个 Y 行之间不等的**字节**个数。
#  -1 = 任一侧缺 Y 行；长度不同则打印较长者长度（视作全不等）。
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

total_mis=0
sim_bad=0
first_case=""
first_K=""
for item in $CASES; do
  name="${item%%:*}"; K="${item##*:}"
  if [ -z "$first_case" ]; then first_case="$name"; first_K="$K"; fi
  d="$work/$name"
  out="$work/$name.out"
  rc=0
  ( cd "$work" && vvp dut_sim.vvp \
      +XFILE="$d/x.hex" +WFILE="$d/w.hex" +YFILE="$d/y.hex" +K="$K" ) > "$out" 2>&1 || rc=$?

  grep '^Y ' "$out" > "$d/dut_y.txt" || true
  if [ ! -s "$d/dut_y.txt" ]; then
    echo "JUDGE-RED: $name 装置没有打印 Y 行（vvp rc=$rc，输出见下）"
    sed -n '1,30p' "$out"; sim_bad=1; continue
  fi
  if [ "$rc" -ne 0 ] || ! grep -q '^RESULT: PASS' "$out"; then
    echo "JUDGE-RED: $name 装置自检未 PASS（vvp rc=$rc）"
    grep '^RESULT:' "$out" || true; sim_bad=1
  fi

  mis="$(cnt_y "$d/exp.txt" "$d/dut_y.txt")"
  echo "   case=$name vvp_rc=$rc  bytes_bad=$mis"
  if [ "$mis" != "0" ]; then
    echo "     --- 差异摘录（期望 < / 实际 >，按 token 一行一个）---"
    diff <(tr ' ' '\n' < "$d/exp.txt") <(tr ' ' '\n' < "$d/dut_y.txt") | head -20
  fi
  [ "$mis" -gt 0 ] 2>/dev/null && total_mis=$((total_mis + mis))
done

echo "MISMATCH=$total_mis"

# ---------------- 3) 负对照 ----------------
# ① 单字节损伤：改期望文件里第 5 个字节（toks[0] 是 "Y" 前缀）的一位。
"$PY" - "$work/$first_case/exp.txt" "$work/$first_case/exp_bad.txt" <<'PYEOF'
import sys
toks = None
for ln in open(sys.argv[1], encoding="utf-8", errors="replace"):
    if ln.startswith("Y "):
        toks = ln.split()
        break
if toks is None or len(toks) < 7:
    sys.exit(1)
toks[5] = "%02x" % (int(toks[5], 16) ^ 0x01)
with open(sys.argv[2], "w", encoding="ascii", newline="\n") as f:
    f.write(" ".join(toks) + "\n")
PYEOF
if [ ! -s "$work/$first_case/exp_bad.txt" ]; then
  echo "FATAL: 无法生成单字节损伤样本"; exit 3
fi
onediff="$(cnt_y "$work/$first_case/exp_bad.txt" "$work/$first_case/dut_y.txt")"

# ② 同一处损伤也做一份 $readmemh 的 y.hex，当 +YFILE 重跑仿真 ⇒ 装置必须自己报 FAIL。
"$PY" - "$work/$first_case/y.hex" "$work/$first_case/y_bad.hex" <<'PYEOF'
import sys
lines = open(sys.argv[1], encoding="utf-8", errors="replace").read().split()
if len(lines) < 6:
    sys.exit(1)
lines[5] = "%02x" % (int(lines[5], 16) ^ 0x01)
with open(sys.argv[2], "w", encoding="ascii", newline="\n") as f:
    f.write("".join(t + "\n" for t in lines))
PYEOF
[ -s "$work/$first_case/y_bad.hex" ] || { echo "FATAL: 无法生成 y_bad.hex"; exit 3; }
rc2=0
( cd "$work" && vvp dut_sim.vvp \
    +XFILE="$work/$first_case/x.hex" +WFILE="$work/$first_case/w.hex" \
    +YFILE="$work/$first_case/y_bad.hex" +K="$first_K" ) > "$work/negctl.out" 2>&1 || rc2=$?
negctl_fail=0
if grep -q '^RESULT: FAIL' "$work/negctl.out" && [ "$rc2" -ne 0 ]; then
  negctl_fail=1
fi
selfdiff="$(cnt_y "$work/$first_case/exp.txt" "$work/$first_case/exp.txt")"   # 自己比自己必须 0
echo "NEGCTL: ref-vs-ref=$selfdiff(期望0) one-byte=$onediff(期望1) tb-fail-on-bad-yfile=$negctl_fail(期望1, vvp_rc=$rc2)"

neg_ok=1
if [ "$selfdiff" -ne 0 ]; then
  echo "NEGCTL-FAIL: 自己比自己报出 $selfdiff 处差异 ⇒ 对账口径坏了"; neg_ok=0
fi
if [ "$onediff" -ne 1 ]; then
  echo "NEGCTL-FAIL: 单字节损伤报出 $onediff 处差异（期望恰好 1）⇒ 对账粒度不对（橡皮图章）"
  neg_ok=0
fi
if [ "$negctl_fail" -ne 1 ]; then
  echo "NEGCTL-FAIL: 装置拿到被损伤的 +YFILE 仍收工（vvp_rc=$rc2）⇒ 装置的自检没接在回路上"
  sed -n '1,10p' "$work/negctl.out"
  neg_ok=0
fi

# ---------------- 4) 无死乘法器：必须做 64 个槽，且每个槽都要能推动它自己的那一行 ----------------
# 判据（本任务新增，就该在这里抓住 B2 那个 rank-1 缺陷）：
#   对 64 个瓦片槽位 (co,ci) 逐个只改**一个字节**（第 0 拍该槽 +1）：
#     alive    : p(co) 必须**变**（rank-1 下 ci≠0 的槽位没有导线，扰动看不见 ⇒ dead）
#     isolation: p(co') (co'≠co) 必须**一个字节都不变**（每行只吃自己那 8 个 entry）
# 判据有牙的证明：同一份网表文本折叠成 rank-1（每行 8 个 w 操作数 → w(co)(0)）再跑一遍，
# 必须报 dead=56/64（每行只有第 0 列有导线）。
"$PY" - "$rtl" "$work/rank1_mutant.v" <<'PYEOF'
import re, sys
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass
src = open(sys.argv[1], encoding="utf-8", errors="replace").read()
m = re.search(r"^module MacArray\b.*?^endmodule", src, re.S | re.M)
if not m:
    print("MUTANT-ERROR: gen/MacArray.v 里找不到 module MacArray"); sys.exit(1)
body = m.group(0)
# 每个乘积 ($signed(x_i) * $signed(w_co_ci)) 里的 w 操作数换成该行第 0 列 ⇒ 语义退化成
# p(co) = Σ_ci x(ci)·w(co)(0) = w(co)(0)·Σ_ci x(ci)（就���旧缺陷的 rank-1 外积）。
pat = re.compile(r"\(\$signed\((x_\d+)\) \* \$signed\(w_(\d+)_(\d+)\)\)")
n = [0]
def repl(mo):
    n[0] += 1
    return "($signed(%s) * $signed(w_%s_0))" % (mo.group(1), mo.group(2))
newbody = pat.sub(repl, body)
if n[0] != 64:
    print("MUTANT-ERROR: 只替换了 %d 个乘积（期望 64）" % n[0]); sys.exit(1)
out = src[:m.start()] + newbody + src[m.end():]
open(sys.argv[2], "w", encoding="ascii", newline="\n").write(out)
print("MUTANT: rank-1 折叠突变体已生成（64 个乘积的 w 操作数全折到第 0 列）⇒ %s" % sys.argv[2])
PYEOF
if [ $? -ne 0 ]; then echo "FATAL: 生成 rank-1 突变体失败"; exit 3; fi
if ! iverilog -g2012 -o "$work/mut_sim.vvp" "$tb" "$work/rank1_mutant.v" > "$work/iv_mut.log" 2>&1; then
  echo "JUDGE-RED: rank-1 突变体编译失败"; sed -n '1,30p' "$work/iv_mut.log"; exit 3
fi

PROBE_VVP="$work/dut_sim.vvp"
PROBE_K=2   # 必须与上面 python 块的 PK（= PX 的拍数）一致：探针向量喂几拍
probe_run() { # <tag> <wfile> <yfile>  ⇒ 日志与 Y 行落在 $work/probe/
  local tag="$1" wf="$2" yf="$3" rc=0
  ( cd "$work" && vvp "$PROBE_VVP" \
      +XFILE="$work/deadslot/x.hex" +WFILE="$wf" +YFILE="$yf" +K="$PROBE_K" ) \
      > "$work/probe/$tag.log" 2>&1 || rc=$?
  if [ "$rc" -ne 0 ] || ! grep -q '^RESULT: PASS' "$work/probe/$tag.log"; then
    echo "PROBE-BAD: tag=$tag vvp_rc=$rc（装置没 PASS ⇒ 这一发的 Y 不可信）"
    grep '^RESULT:' "$work/probe/$tag.log" || true
    sim_bad=1
  fi
  grep '^Y ' "$work/probe/$tag.log" > "$work/probe/$tag.y" || true
  [ -s "$work/probe/$tag.y" ] || { echo "PROBE-BAD: tag=$tag 没有 Y 行"; sim_bad=1; }
}

# ① 真阵列：基准 + 64 个槽位（+YFILE = 真瓦片参考）
probe_run "dut_base" "$work/deadslot/dut/base.w.hex" "$work/deadslot/dut/base.y.hex"
for co in 0 1 2 3 4 5 6 7; do
  for ci in 0 1 2 3 4 5 6 7; do
    probe_run "dut_${co}_${ci}" "$work/deadslot/dut/${co}_${ci}.w.hex" "$work/deadslot/dut/${co}_${ci}.y.hex"
  done
done

# ② rank-1 突变体：同一份探针向量与瓦片文件，只把 +YFILE 换成 rank-1 参考
#    （⇒ 突变体是台"算得对的 rank-1 阵列"，死槽是**结构**造成的，不是它跑挂了）
PROBE_VVP="$work/mut_sim.vvp"
probe_run "mut_base" "$work/deadslot/dut/base.w.hex" "$work/deadslot/mut/base.y.hex"
for co in 0 1 2 3 4 5 6 7; do
  for ci in 0 1 2 3 4 5 6 7; do
    probe_run "mut_${co}_${ci}" "$work/deadslot/dut/${co}_${ci}.w.hex" "$work/deadslot/mut/${co}_${ci}.y.hex"
  done
done

"$PY" - "$work" <<'PYEOF'
import os, sys
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass
work = sys.argv[1]

def lanes(tag):
    p = os.path.join(work, "probe", tag + ".y")
    try:
        f = open(p, encoding="utf-8", errors="replace")
    except OSError:
        return None
    for ln in f:
        if ln.startswith("Y "):
            t = ln.split()[1:]
            if len(t) != 32:
                return None
            return ["".join(t[4 * co:4 * co + 4]) for co in range(8)]   # 每个 co 的 4 字节小端
    return None

def audit(prefix, label):
    base = lanes(prefix + "_base")
    if base is None:
        print("DEADSLOT-ERROR: %s 基准没有 Y 行" % label)
        return None
    alive = dead = iso_bad = 0
    for co in range(8):
        for ci in range(8):
            cur = lanes("%s_%d_%d" % (prefix, co, ci))
            if cur is None:
                print("DEADSLOT-ERROR: %s 槽 (%d,%d) 没有 Y 行" % (label, co, ci))
                return None
            if cur[co] != base[co]:
                alive += 1
            else:
                dead += 1
                if dead <= 4:
                    print("   dead-slot[%s]: (%d,%d) 扰动后 p(%d) 仍是 %s（期望它变）"
                          % (label, co, ci, co, base[co]))
            if any(cur[c] != base[c] for c in range(8) if c != co):
                iso_bad += 1
                if iso_bad <= 4:
                    moved = [c for c in range(8) if c != co and cur[c] != base[c]]
                    print("   dead-slot[%s]: (%d,%d) 扰动竟然动了别的输出 %s（期望一个字节都不动）"
                          % (label, co, ci, moved))
    print("DEADSLOT: %s total=64 alive=%d dead=%d isolation_bad=%d" % (label, alive, dead, iso_bad))
    return alive, dead, iso_bad

dut = audit("dut", "dut(真瓦片网表)")
mut = audit("mut", "mut(rank-1 折叠突变体)")
if dut is None or mut is None:
    sys.exit(1)
if dut[1] != 0 or dut[2] != 0:
    print("DEADSLOT-FAIL: 真阵列有 %d 个死槽 / %d 个串扰 ⇒ 阵列不是一拍 64 个有用 MAC 的瓦片"
          % (dut[1], dut[2]))
    sys.exit(1)
if mut[1] != 56 or mut[0] != 8:
    print("DEADSLOT-FAIL(判据没牙): rank-1 突变体本该 dead=56 alive=8，实测 dead=%d alive=%d "
          "⇒ 这个检查抓不住 rank-1 缺陷，等于装饰" % (mut[1], mut[0]))
    sys.exit(2)
print("DEADSLOT-OK: 64/64 槽位都能推动自己那一行、且都不串扰；"
      "rank-1 折叠突变体 dead=56 alive=8（判据确实抓得住该缺陷）")
PYEOF
deadslot_rc=$?
if [ "$deadslot_rc" -eq 2 ]; then
  echo "NEGCTL-FAIL: 无死乘法器判据在 rank-1 突变体上没红 ⇒ 判据无牙"; exit 2
fi
if [ "$deadslot_rc" -ne 0 ]; then
  echo "JUDGE-RED: 无死乘法器判据未通过（see DEADSLOT lines above）"; sim_bad=1
fi

# ---------------- 5) 结构性判据：64 个乘法器，且每行 8 个**互不相同**的 w 操作数 ----------------
# 断言（对 gen/MacArray.v 的 module MacArray 正文，纯静态）：
#   ① 乘法表达式（$signed(a) * $signed(b)）恰好 64 个 —— 少一个就说明有乘法器被折叠/砍掉；
#   ② 每个输出行 co（按 w 操作数名 w_co_ci 的行号分组）恰好 8 个乘积，且这 8 个的
#      w 操作数**互不相同**、x 操作数互不相同，且 x 的下标 == w 的 ci 下标（配对正确）；
#   ③ 全阵列互不相同的 w 操作数恰好 64 个（= 64 个独立权重输入）。
# 为什么这三条正好区分"瓦片"与"rank-1"（**实测**旧网表 gen/MacArray.v@f165494d）：
#   旧网表：64 个乘法器 ✓（① 过），但每行 8 个乘积全用同一个 w_co ⇒ 每行互异 w = **1**（② 红），
#           全阵列互异 w = **8**（③ 红）—— 也就是说 64 个乘法器里只有 8 个在做独立有用功。
#   只数乘法器个数（①）区分不了两者（两边都是 64），所以 ②③ 是这条判据的牙齿。
"$PY" - "$rtl" "$work/rank1_mutant.v" <<'PYEOF'
import re, sys
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

def audit(path, must_be_tile):
    try:
        src = open(path, encoding="utf-8", errors="replace").read()
    except OSError:
        print("STRUCT-ERROR: 读不到 %s" % path)
        return False
    m = re.search(r"^module MacArray\b.*?^endmodule", src, re.S | re.M)
    if not m:
        print("STRUCT-ERROR: %s 里找不到 module MacArray" % path)
        return False
    body = m.group(0)
    prods = re.findall(
        r"assign\s+(\S+)\s*=\s*\(\$signed\((\w+)\)\s*\*\s*\$signed\((\w+)\)\);", body)
    if not prods:
        nstar = body.count("*")
        print("STRUCT-ERROR: %s 里没解析出 $signed(a) * $signed(b) 形式的乘法"
              "（正文里 '*' 出现 %d 次）⇒ 生成风格变了，请更新本判据" % (path, nstar))
        return False
    rows = {}
    bad_pair = 0
    for lhs, a, b in prods:
        if a.startswith("x_"):
            xo, wo = a, b
        elif b.startswith("x_"):
            xo, wo = b, a
        else:
            print("STRUCT-ERROR: %s 的乘积 %s = (%s * %s) 里没有 x_ 操作数" % (path, lhs, a, b))
            return False
        mo = re.match(r"w_(\d+)_(\d+)$", wo)
        if not mo:
            print("STRUCT-ERROR: %s 的乘积 %s 里 w 操作数 %s 不是 w_<co>_<ci> 形状" % (path, lhs, wo))
            return False
        co, ci = int(mo.group(1)), int(mo.group(2))
        if int(xo[2:]) != ci:
            bad_pair += 1
        rows.setdefault(co, []).append((xo, wo))
    names = sorted(rows)
    per_row_w = [len(set(w for _, w in rows[c])) for c in names]
    per_row_x = [len(set(x for x, _ in rows[c])) for c in names]
    total_w = len(set(w for c in names for _, w in rows[c]))
    print("STRUCT: %-28s mul_total=%d rows=%d per_row_mul=%s distinct_w_per_row=%s "
          "distinct_x_per_row=%s distinct_w_total=%d x_ci!=w_ci 的乘积=%d"
          % (path.split("/")[-1].split("\\")[-1], len(prods), len(names),
             sorted(set(len(rows[c]) for c in names)), sorted(set(per_row_w)),
             sorted(set(per_row_x)), total_w, bad_pair))
    ok = (len(prods) == 64 and len(names) == 8
          and all(len(rows[c]) == 8 for c in names)
          and all(v == 8 for v in per_row_w)
          and all(v == 8 for v in per_row_x)
          and total_w == 64 and bad_pair == 0)
    if must_be_tile:
        if ok:
            print("STRUCT-OK: 64 个乘法器 / 每行 8 个互不相同的 w 且与 x(ci) 配对 / 全阵列 64 个互异 w")
        else:
            print("STRUCT-FAIL: 网表不是'每行 8 个独立权重'的瓦片（rank-1 复发或有乘法器被折叠）")
    else:
        if ok:
            print("STRUCT-TEETH-FAIL: rank-1 突变体的结构判据竟然绿了 ⇒ 这条判据没牙")
        else:
            print("STRUCT-TEETH-OK: 同一套判据把 rank-1 突变体判红（每行互异 w=%s、全阵列互异 w=%d）"
                  % (sorted(set(per_row_w)), total_w))
    return ok

dut_ok = audit(sys.argv[1], True)
mut_ok = audit(sys.argv[2], False)
if not dut_ok:
    sys.exit(1)
if mut_ok:
    sys.exit(2)
sys.exit(0)
PYEOF
struct_rc=$?
if [ "$struct_rc" -eq 2 ]; then
  echo "NEGCTL-FAIL: 结构判据在 rank-1 突变体上没红 ⇒ 判据无牙"; exit 2
fi
if [ "$struct_rc" -ne 0 ]; then
  echo "JUDGE-RED: 结构判据未通过"; sim_bad=1
fi

# ---------------- 判决 ----------------
if [ "$neg_ok" = 1 ]; then echo "NEGCTL-OK"; else exit 2; fi
if [ "$sim_bad" -ne 0 ]; then
  echo "=== JUDGE-RED: 仿真失败或装置自检未通过 ==="; exit 1
fi
if [ "$total_mis" -eq 0 ]; then
  echo "=== JUDGE-GREEN: 装置 Y 与 python 参考逐字节一致（3 个用例，含超 int16 量级）；"
  echo "                    64/64 瓦片槽位无死乘法器（rank-1 突变体 dead=56 被抓住）；"
  echo "                    结构判据 64 乘法器 / 每行 8 个互异 w ==="
  exit 0
fi
echo "=== JUDGE-RED: 装置 Y 有 $total_mis 个字节与参考不符 ==="
exit 1
