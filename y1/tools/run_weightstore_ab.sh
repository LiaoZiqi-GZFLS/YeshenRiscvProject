#!/usr/bin/env bash
# run_weightstore_ab.sh —— 权重存储（rtl/WeightStore.scala + gen/WeightStore*.v）的**瓦片对账**闸门。
#
# 四项职责（与 tools/run_linebuffer_ab.sh / run_macarray_ab.sh 同风格）：
#   1) 造权重：**确定性公式**铺满整层压缩权重张量 [co][ci_local][ky][kx]（值 = 展平下标 mod 256，
#      去撞值的论证见下面 python 段里的注释与断言）；
#   2) 期望瓦片由 python **独立现算**（朴素三重循环 + GroupMask 的掩码规则），k = 0..8 各一块；
#   3) 把权重喂给装置 rtl_test/WeightStoreTb.v，收 9 行 "TILE <k> <hh> ..."，逐字节对账 python 期望，
#      打印唯一一行 MISMATCH=<各档不等的字节总数>（外加 per-group 的 MISMATCH[group=N]=x）；
#   4) 负对照（三发，缺一不可，都要**抓住**）：
#      ① 掩码活着：分组档（GROUP=4/8）的**装置输出** vs **dense（不掩码）期望** ⇒ 必须 >0；
#         且装置拿着 dense 期望当 +TILEFILE 时必须自己报 FAIL（vvp 非 0）。若装置根本没掩码，
#         装置输出就会等于 dense 期望 ⇒ 这一发变绿 ⇒ 判据无效。
#      ② 核位置索引：把期望按 **kx*3+ky**（转置）重算 ⇒ 必须 >0（dense 与分组档都查）。
#         若网表把 k 解释成 kx*3+ky（ky,kx 串了），这一发会变绿 ⇒ 判据无效。
#      ③ RTL 突变体：把网表里 k=8（最后一个核位置）读的 plane 从 base+8 改成 base+7
#         （"最后一个核位置的索引差一"）⇒ 同一套对账必须 >0。这一发证明闸门对**网表内部的
#         k -> plane 接线**敏感，而不是只对"期望文件被改了"敏感。
#      任一发抓不住 ⇒ 判据无效（橡皮图章）⇒ 退出 2。
#
# 退出码：
#   0 = 通过（三档 MISMATCH 全 0 + 三发负对照都抓住）
#   1 = 对账不符 / 编译或仿真失败 / 装置没打印 TILE / 装置自检未 PASS
#   2 = 负对照没抓住 ⇒ 闸门自身不可信
#   3 = 向量自检失败（用例/维度写错：值撞值、转置期望与正确期望相同、dense 期望与分组期望相同…）
#
# 装置契约：rtl_test/WeightStoreTb.v + gen/WeightStore*.v（C_IN = C_OUT = 8 定点生成）
#   +WLOAD=<file>    每行一个 hex 字节，整层权重，展平顺序 = GroupMask.weightAddr 的顺序
#                    [co][ci_local][ky][kx] ⇒ co*PER_GROUP*9 + ci_local*9 + k（COUT*(CIN/GROUP)*9 字节）
#   +TILEFILE=<file> 每行一个 hex 字节，期望瓦片，展平顺序 [k][co][ci] ⇒ 9*COUT*CIN 字节
#   +CIN=8 +COUT=8 +GROUP=<1|4|8>
#   装置打印 9 行 "TILE <k> <hh> ..." + 一行 "RESULT: PASS|FAIL"；FAIL 时 $fatal ⇒ vvp 非 0。
#
# ★ 与 GroupMask.weightAddr 的一致性（必须逐字一致，改它等于改硬件接口）：
#   权重文件就是 GroupMask.weightAddr(co, ci, ky, kx) = co*PER_GROUP*9 + ciLocal*9 + ky*3 + kx
#   这个**展平顺序的原样文件**；装置按地址 0..N-1 逐拍线性写入（不重排、不解释），
#   所以"权重布局 == weightAddr"这条契约在装置侧是**用地址口径本身**表达的，不是靠注释。
set -uo pipefail

PY="${PY:-python}"
here="$(cd "$(dirname "$0")" && pwd)"
gen="$here/../gen"
tb="$here/../rtl_test/WeightStoreTb.v"

C_IN=8
C_OUT=8
CFGS="${WS_GROUPS:-1 4 8}"     # 对账的档：1 = dense（md5 指纹档）、4、8 = depthwise

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

dutFile() { # <group> -> 网表路径（与 rtl_test/WeightStoreGen.scala 的 fileNameOf 一一对应）
  case "$1" in
    1) printf '%s' "$gen/WeightStore.v" ;;
    *) printf '%s' "$gen/WeightStore_g$1.v" ;;
  esac
}

echo "== run_weightstore_ab: 权重存储（整层常驻 + 按 (ky,kx) 出 64 元瓦片 + 组外置 0）瓦片对账 =="
echo "   tb =$tb"
echo "   档位: C_in=$C_IN C_out=$C_OUT CFGS=$CFGS"
echo "   iverilog=${IVERILOG:-<找不到>}  vvp=${VVP:-<找不到>}"
[ -n "$IVERILOG" ] && "$IVERILOG" -V 2>&1 | head -1
echo "   tmp=$work"

# ---------------- 1) 造权重（公式）+ 2) 由 python 独立现算期望瓦片 ----------------
# 值 v(a,k) = (9a + k) mod 256，a = co*PER_GROUP + ci_local（= 压缩张量展平下标 / 9，k = ky*3+kx）。
# ★ 去撞值论证（本任务明写的一条要求；注意 int8 只有 256 个可取值，而 dense 档有 576 个条目，
#   "全张量两两不同"**数学上不可能**，所以给的是下面两条更强的结构性质，并在闸门里逐条断言）：
#   ① 行不同（固定 (co,ci_local)，k = 0..8 的 9 个值）——因为就是 9 个连续整数 mod 256；
#      ⇒ 任何"核位置"错误（ky/kx 转置、某个 k 差一）在同一行内必然数值显形；
#   ② 列不同（固定 k，a = 0..NENT/9-1 的值）——a 差最多 63 < 256 且 gcd(9,256)=1 ⇒ 两两不同；
#      ⇒ 任何 (co, ci_local) 的索引/步长错误在同一列内必然数值显形。
#   分组档（GROUP=4: 144 字节 / GROUP=8: 72 字节）条目数 <= 256 ⇒ 式子里**不发生 mod 回绕**，
#   于是它们是**严格两两不同**的（比任务要求还强）。两条性质都在下面 assert，破了就退出 3。
if ! "$PY" - "$work" "$C_IN" "$C_OUT" "$CFGS" <<'PYEOF'
import sys
try:
    # Windows 控制台是 GBK：显式按 UTF-8 写（errors=replace 兜底），否则中文打印出来是乱码。
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

work, C_IN, C_OUT = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
groups = [int(x) for x in sys.argv[4].split()]

def per_group(g):
    return C_IN // g

def goo(co, g):
    return (co * g) // C_OUT

def goi(ci, g):
    return (ci * g) // C_IN

def ci_local(co, ci, g):
    # 与 rtl/GroupMask.scala 的 GroupMask.ciLocal 逐字一致（它其实只跟 ci 有关）。
    return ci - goi(ci, g) * per_group(g)

def participates(co, ci, g):
    return goo(co, g) == goi(ci, g)

def nent(g):
    return C_OUT * per_group(g) * 9

def flat_index(g, co, cl, k):
    """GroupMask.weightAddr(co, ci, ky, kx)，k = ky*3+kx。"""
    return co * per_group(g) * 9 + cl * 9 + k

def wbyte(g, co, cl, k):
    """权重字节 = 展平下标 mod 256（去撞值论证见本文件上方注释）。"""
    return flat_index(g, co, cl, k) & 0xFF

PERM = [(k % 3) * 3 + (k // 3) for k in range(9)]   # ky<->kx 转置：k=ky*3+kx -> kx*3+ky

def tiles(g, mask=True, kperm=None):
    """期望瓦片，展平顺序 [k][co][ci]（与装置 got[] 的下标一致）。kperm = 输出槽 k 去取哪个平面。"""
    out = []
    for k in range(9):
        plane_sel = k if kperm is None else kperm[k]
        for co in range(C_OUT):
            for ci in range(C_IN):
                if mask and not participates(co, ci, g):
                    out.append(0)                       # 组外恒 0（分组只能靠掩权重表达，见 GroupMask）
                else:
                    out.append(wbyte(g, co, ci_local(co, ci, g), plane_sel))
    return out

def dump(path, toks):
    with open(path, "w", encoding="ascii", newline="\n") as f:
        f.write("".join("%02x\n" % b for b in toks))

ntile = 9 * C_OUT * C_IN
manifest = []
for g in groups:
    if g < 1 or C_IN % g or C_OUT % g:
        print("FATAL: GROUP=%d 必须 >=1 且整除 %d/%d" % (g, C_IN, C_OUT)); sys.exit(3)
    N = nent(g)
    wf = [wbyte(g, co, cl, k)
          for co in range(C_OUT) for cl in range(per_group(g)) for k in range(9)]
    ok    = tiles(g, mask=True)
    dense = tiles(g, mask=False)
    kxky  = tiles(g, mask=True, kperm=PERM)

    # 自检 0：长度自洽
    if len(wf) != N or len(ok) != ntile or len(dense) != ntile or len(kxky) != ntile:
        print("FATAL: group=%d 长度不自洽（W=%d/%d tile=%d/%d）" % (g, len(wf), N, len(ok), ntile))
        sys.exit(3)
    # 自检 1：行不同（同一 (co,ci_local) 的 9 个核位置值两两不同）
    for co in range(C_OUT):
        for cl in range(per_group(g)):
            row = [wbyte(g, co, cl, k) for k in range(9)]
            if len(set(row)) != 9:
                print("FATAL: group=%d (co=%d,ci_local=%d) 行内有撞值 %s ⇒ 核位置错位可能被糊住"
                      % (g, co, cl, row)); sys.exit(3)
    # 自检 2：列不同（固定 k，所有 (co,ci_local) 的值两两不同）
    for k in range(9):
        col = [wbyte(g, co, cl, k) for co in range(C_OUT) for cl in range(per_group(g))]
        if len(set(col)) != len(col):
            print("FATAL: group=%d k=%d 列内有撞值（%d 个值里只有 %d 个不同）"
                  % (g, k, len(col), len(set(col)))); sys.exit(3)
    # 自检 3：条目数 <= 256 时必须**严格两两不同**（分组档走这条）
    if N <= 256 and len(set(wf)) != N:
        print("FATAL: group=%d N=%d <= 256 但整张量不是两两不同" % (g, N)); sys.exit(3)
    # 自检 4：转置期望必须**真的**与正确期望不同（否则负对照②无从谈起）
    d_tr = sum(1 for a, b in zip(ok, kxky) if a != b)
    if d_tr == 0:
        print("FATAL: group=%d 的 kx*3+ky 转置期望与正确期望完全相同 ⇒ 用例没意义" % g); sys.exit(3)
    # 自检 5/6（分组档）：dense 期望必须不同，且掩码期望里必须真有 0
    d_dn = sum(1 for a, b in zip(ok, dense) if a != b)
    if g > 1 and d_dn == 0:
        print("FATAL: group=%d 的 dense 期望与掩码期望完全相同 ⇒ 负对照①没意义" % g); sys.exit(3)
    if g > 1 and 0 not in ok:
        print("FATAL: group=%d 的掩码期望里一个 0 都没有 ⇒ 掩码规则没生效" % g); sys.exit(3)

    dump("%s/g%d.w.hex" % (work, g), wf)
    dump("%s/g%d.tile.hex" % (work, g), ok)
    dump("%s/g%d.dense.hex" % (work, g), dense)
    dump("%s/g%d.kxky.hex" % (work, g), kxky)
    manifest.append((g, N))
    print("VEC group=%d: 权重 %d 字节（%d 个 (co,ci_local) 行 x 9 核位置）| 期望瓦片 %d 字节/档 | %s"
          % (g, N, C_OUT * per_group(g), ntile,
             "条目 <=256 ⇒ 严格两两不同" if N <= 256 else "行不同 + 列不同（576 > 256，全张量两两不同不可能）"))
    print("VEC group=%d: dense-vs-masked 差 %d 字节；kx*3+ky 转置差 %d 字节"
          % (g, d_dn, d_tr))

with open(work + "/manifest.txt", "w", encoding="ascii", newline="\n") as f:
    for g, N in manifest:
        f.write("%d %d\n" % (g, N))
print("VEC: 权重文件 = GroupMask.weightAddr 展平顺序的原样文件（装置按地址 0..N-1 线性写入，不重排）")
PYEOF
then
  echo "FATAL: 生成向量/期望失败"; exit 3
fi
for g in $CFGS; do
  for f in "g$g.w.hex" "g$g.tile.hex" "g$g.dense.hex" "g$g.kxky.hex"; do
    [ -s "$work/$f" ] || { echo "FATAL: 向量 $f 缺失或为空"; exit 3; }
  done
done
[ -s "$work/manifest.txt" ] || { echo "FATAL: manifest 缺失"; exit 3; }

# ---------------- 3) 装置：编译 + 仿真 + 逐字节对账 ----------------
# cnt_bytes <期望文件> <装置 TILE 文件>：打印两侧 token 数不等的位置数。
#   -1 = 任一侧缺失；长度不同则打印较长者长度（视作全不等）。
cnt_bytes() {
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

# 把装置打印的 9 行 "TILE <k> <hh> ..." 收成一个 token 流（顺带校验 k = 0..8 且每行恰好 64 字节）。
extract_tiles() { # <装置输出> <目标文件>
  "$PY" - "$1" "$2" <<'PYEOF'
import sys
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass
out = open(sys.argv[1], encoding="utf-8", errors="replace").read().splitlines()
rows = [ln.split() for ln in out if ln.startswith("TILE ")]
if len(rows) != 9:
    print("EXTRACT-ERROR: 期望 9 行 TILE，实际 %d 行" % len(rows)); sys.exit(1)
toks = []
for want, r in enumerate(rows):
    if len(r) != 66:                     # TILE + k + 64 个字节
        print("EXTRACT-ERROR: 第 %d 行 TILE 有 %d 个 token（要 66）" % (want, len(r))); sys.exit(1)
    try:
        kk = int(r[1])
    except ValueError:
        print("EXTRACT-ERROR: 第 %d 行 k 不是整数：%r" % (want, r[1])); sys.exit(1)
    if kk != want:
        print("EXTRACT-ERROR: 第 %d 行给的 k=%d（要按 0..8 顺序）" % (want, kk)); sys.exit(1)
    toks += r[2:]
with open(sys.argv[2], "w", encoding="ascii", newline="\n") as f:
    f.write("".join(t + "\n" for t in toks))
PYEOF
}

sim_bad=0
declare -A MIS=()        # 正面对账：装置瓦片 vs python 正确期望
declare -A MIS_DENSE=()  # 负对照①：装置瓦片 vs dense（不掩码）期望
declare -A MIS_KXKY=()   # 负对照②：装置瓦片 vs kx*3+ky 转置期望
declare -A DUT_OK=()     # 该档装置是否跑通

run_tb() { # <tag> <vvp> <tilefile> <group> <want: pass|fail|any>
  local tag="$1" vvp="$2" tf="$3" g="$4" want="$5" rc=0
  ( cd "$work" && "$VVP" "$vvp" \
      +WLOAD="$work/g$g.w.hex" +TILEFILE="$tf" \
      +CIN="$C_IN" +COUT="$C_OUT" +GROUP="$g" ) > "$work/$tag.out" 2>&1 || rc=$?
  rm -f "$work/$tag.tiles"
  extract_tiles "$work/$tag.out" "$work/$tag.tiles" > "$work/$tag.ex" 2>&1
  case "$want" in
    pass)
      if [ "$rc" -ne 0 ] || ! grep -q '^RESULT: PASS' "$work/$tag.out"; then
        echo "JUDGE-RED: [$tag] 装置自检未 PASS（vvp rc=$rc）"
        grep '^RESULT:' "$work/$tag.out" || true
        sed -n '1,8p' "$work/$tag.out"
        sim_bad=1
      fi
      [ -s "$work/$tag.tiles" ] || { echo "JUDGE-RED: [$tag] 没收到 9 行 TILE"; cat "$work/$tag.ex"; sim_bad=1; }
      ;;
    fail)
      if [ "$rc" -eq 0 ] || ! grep -q '^RESULT: FAIL' "$work/$tag.out"; then
        echo "JUDGE-RED: [$tag] 装置拿到错期望仍收工（vvp rc=$rc）⇒ 装置自检没接在回路上"
        grep '^RESULT:' "$work/$tag.out" || true
        sim_bad=1
      fi
      ;;
    any)   # 突变体：本来就该 FAIL，只取它的 TILE 流
      [ -s "$work/$tag.tiles" ] || { echo "JUDGE-RED: [$tag] 没收到 9 行 TILE"; cat "$work/$tag.ex"; sim_bad=1; }
      ;;
  esac
}

echo "---- 三档对账（dense=1 / 分组=4 / depthwise=8）----"
while read -r g N; do
  [ -z "${g:-}" ] && continue
  nl="$(dutFile "$g")"
  echo "== group=$g（NENT=$N 字节权重、网表 $nl）=="
  if [ ! -f "$nl" ]; then
    echo "JUDGE-RED: 网表不存在：$nl（先跑 WeightStoreGen 生成步骤）"; sim_bad=1; continue
  fi
  if [ ! -f "$tb" ]; then echo "JUDGE-RED: 装置不存在：$tb"; sim_bad=1; continue; fi
  if [ -z "$IVERILOG" ] || [ -z "$VVP" ]; then echo "JUDGE-RED: 找不到 iverilog / vvp"; sim_bad=1; continue; fi
  if ! "$IVERILOG" -g2012 -o "$work/sim_g$g.vvp" "$tb" "$nl" > "$work/iv_g$g.log" 2>&1; then
    echo "JUDGE-RED: iverilog 编译失败（group=$g）"; sed -n '1,20p' "$work/iv_g$g.log"; sim_bad=1; continue
  fi

  # 正面：正确期望 ⇒ 装置必须 PASS，且闸门逐字节对账必须 0
  run_tb "dut_g$g" "sim_g$g.vvp" "$work/g$g.tile.hex" "$g" pass
  if [ -s "$work/dut_g$g.tiles" ]; then
    DUT_OK[$g]=1
    MIS[$g]="$(cnt_bytes "$work/g$g.tile.hex" "$work/dut_g$g.tiles")"
    MIS_KXKY[$g]="$(cnt_bytes "$work/g$g.kxky.hex" "$work/dut_g$g.tiles")"
    if [ "$g" != "1" ]; then
      MIS_DENSE[$g]="$(cnt_bytes "$work/g$g.dense.hex" "$work/dut_g$g.tiles")"
    fi
  else
    DUT_OK[$g]=0
    MIS[$g]=-1; MIS_KXKY[$g]=-1; MIS_DENSE[$g]=-1
  fi
  echo "   MISMATCH[group=$g]=${MIS[$g]}   (装置瓦片 vs python 独立现算的期望)"

  # 负对照① 掩码活着：分组档拿 dense 期望当 +TILEFILE ⇒ 装置必须自己 FAIL
  #   （"装置输出 vs dense 期望"的字节差在上面已经算好：若装置没掩码，这个差就是 0）
  if [ "$g" != "1" ]; then
    run_tb "neg_dense_g$g" "sim_g$g.vvp" "$work/g$g.dense.hex" "$g" fail
  fi
  # 负对照② 核位置索引：转置期望 ⇒ 装置必须自己 FAIL
  run_tb "neg_kxky_g$g" "sim_g$g.vvp" "$work/g$g.kxky.hex" "$g" fail
done < "$work/manifest.txt"

# ---------------- 负对照③：RTL 突变体（k=8 读 base+7，最后一个核位置差一） ----------------
mut_mis=-1
mut_ok=0
if [ -f "$work/sim_g1.vvp" ] && [ -n "$VVP" ] && [ -n "$IVERILOG" ]; then
  mut_cnt="$("$PY" - "$gen/WeightStore.v" "$work/mutant.v" <<'PYEOF'
import re, sys
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass
src = open(sys.argv[1], encoding="utf-8", errors="replace").read()
# 每块瓦片的核位置选择链最后一级长这样：
#   assign _zz_tile_7_7_7 = ((k == 4'b1000) ? mem_575 : 8'h0);
# 突变：k=8 时读的 plane 从 base+8 改成 base+7 ⇒ "最后一个核位置差一"。
pat = re.compile(r"\(k == 4'b1000\) \? mem_(\d+) : 8'h0\)")
hits = pat.findall(src)
if not hits:
    print("MUTANT-ERROR: 没找到 (k == 4'b1000) ? mem_N : 8'h0) 形状（生成风格变了，请更新本判据）")
    sys.exit(1)
bad = [h for h in hits if int(h) % 9 != 8]
if bad:
    print("MUTANT-ERROR: 命中的 mem 下标 %s 不是某行的第 9 个 plane（n %% 9 != 8）" % bad[:4])
    sys.exit(1)
new = pat.sub(lambda mo: "(k == 4'b1000) ? mem_%d : 8'h0)" % (int(mo.group(1)) - 1), src)
if new == src:
    print("MUTANT-ERROR: 突变体与原文相同"); sys.exit(1)
open(sys.argv[2], "w", encoding="ascii", newline="\n").write(new)
print("%d" % len(hits))
PYEOF
)"
  mut_rc=$?
  if [ "$mut_rc" -ne 0 ]; then
    echo "JUDGE-RED: 生成突变体失败：$mut_cnt"; sim_bad=1
  else
    echo "MUTANT: 把 $mut_cnt 处「k=8 读 plane base+8」改成「读 plane base+7」（最后一个核位置差一）"
    if "$IVERILOG" -g2012 -o "$work/mut_sim.vvp" "$tb" "$work/mutant.v" > "$work/iv_mut.log" 2>&1; then
      run_tb "mut" "mut_sim.vvp" "$work/g1.tile.hex" 1 any
      if [ -s "$work/mut.tiles" ]; then
        mut_mis="$(cnt_bytes "$work/g1.tile.hex" "$work/mut.tiles")"
        mut_ok=1
      fi
    else
      echo "JUDGE-RED: 突变体编译失败"; sed -n '1,20p' "$work/iv_mut.log"; sim_bad=1
    fi
  fi
fi

# ---------------- 汇总 ----------------
total_mis=0
for g in $CFGS; do
  v="${MIS[$g]:--1}"
  if [ "$v" -lt 0 ] 2>/dev/null; then total_mis=-1; break; fi
  total_mis=$((total_mis + v))
done
echo "MISMATCH=$total_mis"
if [ -s "$work/dut_g1.tiles" ] && [ "$total_mis" != "0" ]; then
  echo "  --- 差异摘录（group=1，期望 < / 实际 >，按 token 一行一个，前 20 行）---"
  diff <(tr ' ' '\n' < "$work/g1.tile.hex") <(tr ' ' '\n' < "$work/dut_g1.tiles") | head -20 || true
fi

neg_ok=1
for g in $CFGS; do
  if [ "${DUT_OK[$g]:-0}" != "1" ]; then
    echo "NEGCTL-SKIP: group=$g 的装置没跑起来，无法核对负对照"
    continue
  fi
  if [ "$g" != "1" ] && [ "${MIS_DENSE[$g]:--1}" -le 0 ] 2>/dev/null; then
    echo "NEGCTL-FAIL: group=$g dense 期望 vs 装置输出 差 ${MIS_DENSE[$g]} ⇒ 掩码没被抓住"
    echo "             （要么网表根本没把组外 entry 掩成 0，要么闸门对掩码不敏感；两种都不许过）"
    neg_ok=0
  fi
  if [ "${MIS_KXKY[$g]:--1}" -le 0 ] 2>/dev/null; then
    echo "NEGCTL-FAIL: group=$g kx*3+ky 转置期望没被抓住（${MIS_KXKY[$g]}）⇒ 对账对核位置索引不敏感"
    neg_ok=0
  fi
done
if [ -f "$work/sim_g1.vvp" ]; then
  if [ "$mut_ok" != "1" ]; then
    echo "NEGCTL-FAIL: RTL 突变体没跑起来 ⇒ 无法证明对账对网表内部接线敏感"; neg_ok=0
  elif [ "$mut_mis" -le 0 ] 2>/dev/null; then
    echo "NEGCTL-FAIL: 突变体（k=8 读 base+7）也被判绿（$mut_mis）⇒ 闸门对核位置接线不敏感"; neg_ok=0
  fi
fi

neg_sum=""
for g in $CFGS; do
  if [ "$g" != "1" ]; then
    neg_sum="$neg_sum g$g:dense-vs-dut=${MIS_DENSE[$g]:-n/a}(>0)"
  fi
  neg_sum="$neg_sum g$g:kxky-vs-dut=${MIS_KXKY[$g]:-n/a}(>0)"
done
echo "NEGCTL: ref-vs-ref=0(期望)$neg_sum mutant-k8-plane7=$mut_mis(>0)"
for g in $CFGS; do
  if [ "$g" = "1" ]; then
    echo "  负对照① 掩码活着：group=1 略（dense 与掩码期望本来就相同 —— GROUP=1 没有组外条目）"
  else
    echo "  负对照① 掩码活着：group=$g 装置输出 vs dense（不掩码）期望 ⇒ ${MIS_DENSE[$g]:-n/a} 个字节不符"
  fi
  echo "  负对照② 核位置索引：group=$g 装置输出 vs kx*3+ky 转置期望 ⇒ ${MIS_KXKY[$g]:-n/a} 个字节不符"
done
echo "  负对照③ RTL 突变体：k=8 读 plane base+7 ⇒ $mut_mis 个字节不符"

# ---------------- 判决 ----------------
# 顺序与 run_linebuffer_ab.sh 一致：**先**判负对照是否抓住（闸门自身可信度），再判对账结果。
if [ "$neg_ok" != "1" ]; then
  echo "=== NEGCTL-BAD: 负对照没抓住 ⇒ 闸门自身不可信（也可能是网表真的没做那件事）==="
  exit 2
fi
if [ "$sim_bad" -ne 0 ]; then
  echo "=== JUDGE-RED: 编译/仿真失败或装置自检未通过 ==="
  exit 1
fi
if [ "$total_mis" = "0" ]; then
  echo "NEGCTL-OK: 三发负对照都抓住（dense 期望撞分组装置的掩码 / kx*3+ky 转置期望 / RTL 里 k=8 的 plane 差一）"
  echo "=== JUDGE-GREEN: 三档（dense / group4 / depthwise）的 9x64 瓦片都与 python 独立现算的期望逐字节一致 ==="
  exit 0
fi
echo "=== JUDGE-RED: 瓦片与参考不符（MISMATCH=$total_mis）==="
exit 1
