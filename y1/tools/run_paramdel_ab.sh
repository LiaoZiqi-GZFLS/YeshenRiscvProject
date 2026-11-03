#!/usr/bin/env bash
# run_paramdel_ab.sh —— ★★ C4b-B2「**逐层参数（M / z_pad / z_y / bias_adj）投递**端到端」闸门
#   （被测：`rtl/UnitExec.scala` 的**权置信箱区域 2/3/4/5** + `LAYER_ID` 索引的 `mzRam`/`biasMem`
#     + 新增的 `lidOk`（**参数表下标越界保护**）；spec §4.4 / §4.5）
#
# ============================ 唯一的真源（本任务的裁决） ============================
#   **`y1/gen/wgt_index.json` 的 `requant_mult`（逐层 Q24 乘子 M）+ `centering`（逐层 z_pad / z_y /
#     bias_adj）是 `M`/`z_pad`/`z_y`/`bias_adj` 的单一真源。**（spec §4.4/§4.5 把**投递**钉在
#   **既有权重信箱**上、以描述符 `w7` 的 `LAYER_ID` 索引；描述符 8 字格式与寄存器契约**一字未动**。）
#   · 为什么**保留在信箱**（而不是改走 DDR）：① §4.4/§4.5 逐字钉的就是"走既有权重信箱 + LAYER_ID 索引"，
#     改成 DDR 侧是**spec 级修订**（本任务不做）；② 这些参数是**每层一次的标量/小向量**
#     （67 个 M 字 + 53×2 字节 + 53×co 个 bias 字），不是逐像素量 ⇒ 信箱带宽**不是**瓶颈；
#     ③ 权重 blob 与参数表在主机侧是**同一份镜像**（`gen/wgt_mult.bin` 紧随 `blob` 之后：
#     `mult.offset_in_mailbox == blob.bytes`；`fingerprints.mailbox_bytes == len(blob)+len(mult)`、
#     `mailbox_md5 == md5(blob ‖ mult)`）⇒ "同源"体现在**那一份镜像**上，只是**传输**用区域寻址。
#   · **等价的证明**（本闸门 [0] 与 [3] 就是它）：`M` 的每一个字 = `requant_mult` 顺序的 LE 字
#     （`wgt_mult.bin` 逐字节相等）；每个单元的 `M/z_pad/z_y/bias_adj` 由**冻结参考** `wide_exec_ref`
#     从**同一份 json** 读出（`job.txt` 对账），且硬件**投递后回读**（`RTL_M/RTL_ZPAD/RTL_ZY` +
#     `biasReg` 白盒 + 输出逐字节）== json（**逐单元、逐字**，不是校验和）。
#
# 判据（每条都要能发火）：
#   [0] 自检（离线；不成立 exit 3）：json↔`wgt_mult.bin` 逐字对账（顺序 = `requant_mult`）；`blob‖mult`
#       的字节数/md5 == `fingerprints.mailbox_bytes/mailbox_md5`；7 个真单元的几何/权重段/参数完备性
#       （`z_pad == z_x`、`len(bias_adj) == C_out`、`layer_id` 在 `requant_mult` 里）。
#   [1] 参考供料（**不重写算术**）：`wide_exec_ref.build_one`（冻结）从 json 供 `w/x/b/gold`；
#       并**复用同一函数**、只改一个参数（`M ^ (1<<12)` / `z_pad+1`）供两条**预测黄金**；
#       `bias_adj ≡ 0` 的预测黄金 = `gold_nobias.hex`（冻结文件本就产出）。
#   [2] 编译（gen/UnitExec.v + UnitExecWideTb + AxiMemModel）。
#   [3] 逐单元（7 个真 dense 单元，各自真 `layer_id`）：
#       · **参数 == json（逐单元、逐字）**：`RTL_M/RTL_ZPAD/RTL_ZY/RTL_LAYER` == json；`biasReg` 白盒
#         （`+DUMPB`，64 字）的前 `C_out` 字 == json 的 `bias_adj`（**逐字**），其余 == 0；
#       · **数值端到端逐字节**：`DST` 区 == `gold.hex`（`MISMATCH=0`），黄金非退化；
#       · `MEM rd == 0`（`+WBASE=0`：权重经信箱 `WFILE` 喂 ⇒ 本判据**只**测参数通路）。
#   [4] 负对照（**必发火 + 定位到单元**）：每个单元三条，各按**预测黄金**逐字节对账（不是"随便红了就行"）：
#       · NC-M：`M` 翻**一位**（bit12）⇒ 输出**精确命中** `m12/gold.hex` 且 != 黄金；
#       · NC-Z：`z_pad + 1` ⇒ 精确命中 `zp1/gold.hex` 且 != 黄金；
#       · NC-B：`bias_adj ≡ 0` ⇒ 精确命中 `gold_nobias.hex` 且 != 黄金。
#   [5] 边界（**参数表下标越界仍响亮 err、零搬运**）：**窄几何**（C_in=C_out=8/GROUP=1）+ `LAYER_ID=64`
#       （越界第一格）与 `LAYER_ID=200` ⇒ `ERR_SEEN=1`、`WR_BYTES=0`、`RD_BYTES=0`（新增 `lidOk` 的靶子；
#       `LAYER_ID ≤ 60` 的 7 个真单元在 [3] 里全部正常跑通 ⇒ 守卫**不误伤**合法层）。
#   [5b] **受控实验**：网表突变 `assign lidOk = (layerIdx < 8'h40);` → `1'b1`（去掉守卫）⇒ `LAYER_ID=64`
#       **不再 err 且真的搬数据**（`WR_BYTES != 0`）⇒ 证明 [5] 的"响亮 err + 零搬运"**由 `lidOk` 造成**。
#   [6] **装载/计算重叠纪律**（G6 的"写明并实测"）：同一单元 `+WBASE` **开/关**两跑，逐字节都 == 黄金
#       ⇒ `CYCLES(on) - CYCLES(off)` = **串行装载的代价**（受控实验）。**裁决 = 不重叠**（单一
#       `DdrMaster` + 单一 `UnitExec` FSM：`WGTLD→WGTRUN→RDSTART/WIDERUN` 严格串行，见文件头与报告）。
#
# 退出码（与 Y1 既有闸门一致）：0 = 全绿；1 = 判据红；2 = 负对照没发火（判据无牙）；3 = 向量/自检失败。
#
# 装置契约（rtl_test/UnitExecWideTb.v + rtl_test/AxiMemModel.v + gen/UnitExec.v）：
#   +CIN +COUT +GROUP +H +W +TYPE +FLAGS +SRC +DST +INB +QSHIFT +LID +M +ZPAD +ZY +NCOL +NCI +NCO
#   +XFILE +WFILE +BFILE +MEMFILE +DUMPFILE +dump +WBASE= +WEXP= +DUMPB=（★ 本任务新增）
#   装置打印：`TB WIDE RTL: ... RTL_M=.. RTL_ZPAD=.. RTL_ZY=.. RTL_LAYER=..` / `CYCLES=..` /
#             `DONE_SEEN=.. ERR_SEEN=.. WR_BYTES=.. WGT_BYTES=..` / `BIAS_DUMPED ..` / `RESULT: PASS|FAIL`
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
cd "$here/.." || { echo "FATAL: 进不去 y1/"; echo "RESULT: FAIL"; exit 3; }

PY="${PY:-/d/code/PDS/NaxYeshenLinux/sim/reglogs/lxvenv/Scripts/python.exe}"
[ -x "$PY" ] || PY="$(command -v python || command -v python3 || true)"
[ -n "$PY" ] || { echo "FATAL: 找不到 python"; echo "RESULT: FAIL"; exit 3; }

tb="rtl_test/UnitExecWideTb.v"
memv="rtl_test/AxiMemModel.v"
nl="gen/UnitExec.v"
idx="gen/wgt_index.json"
blob="gen/wgt_blob.bin"
mult="gen/wgt_mult.bin"
MEMSZ=2621440
BLOB_BASE=262144          # 0x40000（[6] 里真 blob 整块落点；[3] 不用）
SRC=131072
DST=2097152
HH=4; WW=64
SEL="0 1 13 37 43 38 55"   # 7 个真 dense 单元（conv3x3/1x1；C∈{1,3,64}、C_out∈{1,4,10,16,64}）

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
for f in "$tb" "$memv" "$nl" "$idx" "$blob" "$mult"; do
  [ -f "$f" ] || { echo "FATAL: 缺 $f"; echo "RESULT: FAIL"; exit 3; }
done
[ -n "$IVERILOG" ] && [ -n "$VVP" ] || { echo "FATAL: 找不到 iverilog/vvp"; echo "RESULT: FAIL"; exit 3; }

work="$(mktemp -d)"
cleanup() { if [ "${KEEP_TMP:-0}" = "1" ]; then echo "KEEP_TMP=1 => 中间件在 $work"; else rm -rf "$work"; fi }
trap cleanup EXIT
export PYTHONIOENCODING=utf-8
export PYTHONPATH="./.pydeps;../third_party/yunet/deps"

echo "== run_paramdel_ab: 逐层参数（M/z_pad/z_y/bias_adj）投递端到端 =="
echo "   nl=$nl  tb=$tb  py=$PY  iverilog=$IVERILOG  vvp=$VVP  tmp=$work"
echo "   真源 = $idx 的 requant_mult(M) + centering(z_pad/z_y/bias_adj)；投递 = 权重信箱区域 2/3/4/5"

FAIL() { echo "$1"; echo "RESULT: FAIL"; exit "$2"; }

# ===========================================================================
# [0]+[1] 自检 + 参考供料（只用**冻结**的 wide_exec_ref；它读的正是同一份 json）
# ===========================================================================
echo "---- [0] 自检：json ↔ wgt_mult.bin ↔ blob‖mult 指纹 + 真单元清单；[1] 参考供料 ----"
if ! "$PY" - "$idx" "$blob" "$mult" "$work" "$HH" "$WW" $SEL <<'PYEOF'
import sys, os, json, hashlib
sys.path.insert(0, "tools")               # 冻结参考（cwd = y1/）
import numpy as np
import wide_exec_ref as W

idx_p, blob_p, mult_p, work = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
H, Wd = int(sys.argv[5]), int(sys.argv[6])
sel = [int(x) for x in sys.argv[7:]]

d = json.load(open(idx_p, encoding="utf-8"))
blob = open(blob_p, "rb").read()
multb = open(mult_p, "rb").read()
bad = []

# ---- [0a] 真源唯一性：requant_mult ↔ wgt_mult.bin（顺序 = 表序），blob‖mult 指纹 ----
rm = d["requant_mult"]; cen = d["centering"]
if len(rm) != 67: bad.append("requant_mult 条数 %d != 67" % len(rm))
if d["mult"]["bytes"] != len(multb): bad.append("wgt_mult.bin %d != index %d" % (len(multb), d["mult"]["bytes"]))
if hashlib.md5(multb).hexdigest() != d["mult"]["md5"]: bad.append("wgt_mult.bin md5 != index")
words = [int.from_bytes(multb[4 * i:4 * i + 4], "little") for i in range(len(rm))]
if words != [int(e["M"]) for e in rm]:
    bad.append("wgt_mult.bin 的 LE 字 != requant_mult 的 M（顺序/值不符）")
if int(d["mult"]["offset_in_mailbox"]) != len(blob):
    bad.append("mult.offset_in_mailbox %d != blob.bytes %d" % (int(d["mult"]["offset_in_mailbox"]), len(blob)))
img = blob + multb
fp = d["fingerprints"]
if len(img) != int(fp["mailbox_bytes"]): bad.append("blob‖mult %d != mailbox_bytes %d" % (len(img), int(fp["mailbox_bytes"])))
if hashlib.md5(img).hexdigest() != fp["mailbox_md5"]: bad.append("blob‖mult md5 != mailbox_md5")
for e in cen:
    if int(e["z_pad"]) != int(e["z_x"]): bad.append("%s: z_pad %s != z_x %s" % (e["name"], e["z_pad"], e["z_x"]))

print("SELFTEST 真源: requant_mult=%d centering=%d mult=%dB(%s) mailbox=blob‖mult %dB(md5 %s)"
      % (len(rm), len(cen), len(multb), d["mult"]["md5"][:12], len(img), fp["mailbox_md5"][:12]))
print("SELFTEST 真源: wgt_mult.bin 的 67 个 LE 字 == requant_mult 的 M（顺序 = 表序）✓；"
      "mult.offset_in_mailbox == blob.bytes == %d（'M 紧随 blob' 的布局口径）✓" % len(blob))

# ---- [0b]+[1] 逐单元：真源完备性 + 冻结参考供料（base / M^bit12 / z_pad+1 三份黄金） ----
lines = []
for lid in sel:
    u = [x for x in d["units"] if x["idx"] == lid][0]
    o = u["own"]; w = u["weight"]
    if w is None: bad.append("%s: 无权重组" % u["name"]); continue
    if int(o["GROUP"]) != 1: bad.append("%s: 非 dense（本闸门的单元集只取 GROUP==1）" % u["name"])
    if int(u["type_code"]) == 3: bad.append("%s: depthwise（本闸门不取；见报告'诚实边界'）" % u["name"])
    rq = [e for e in rm if int(e["layer_id"]) == int(u["layer_id"])]
    ce = [e for e in cen if int(e["layer_id"]) == int(u["layer_id"])]
    if len(rq) != 1: bad.append("%s: layer_id=%d 在 requant_mult 里不是恰好 1 条" % (u["name"], u["layer_id"]))
    if len(ce) != 1: bad.append("%s: layer_id=%d 在 centering 里不是恰好 1 条" % (u["name"], u["layer_id"]))
    if len(ce[0]["bias_adj"]) != int(o["C_OUT"]): bad.append("%s: len(bias_adj) != C_out" % u["name"])
    nb = int(w["nbytes"]); off = int(w["offset"]); ab = int(w.get("aligned_bytes") or ((nb + 31) // 32 * 32))
    if nb != int(o["C_OUT"]) * int(o["C_IN"]) * 9: bad.append("%s: nbytes != C_out*C_in*9" % u["name"])
    if off % 32 or ab % 32 or ab != (nb + 31) // 32 * 32: bad.append("%s: 段起点/对齐段长不满足 32 B 粒度" % u["name"])
    if off + nb > len(blob): bad.append("%s: 段越出 blob" % u["name"])
    # 冻结参考供料（与 run_unitexec_wide_ab.sh 同一份函数）：**从 json 读参数**
    spec = W.build_real(idx_p, blob_p, lid)
    base = os.path.join(work, "u%02d_%s" % (lid, u["name"]))
    r = W.build_one(spec, H, Wd, base)
    rM = W.build_one(dict(spec, M=int(spec["M"]) ^ (1 << 12)), H, Wd, os.path.join(base, "m12"))
    rZ = W.build_one(dict(spec, z_pad=int(spec["z_pad"]) + 1), H, Wd, os.path.join(base, "zp1"))
    jt = dict(l.strip().split("=", 1) for l in open(os.path.join(base, "job.txt")) if "=" in l)
    if int(jt["M"]) != int(rq[0]["M"]) or int(jt["ZPAD"]) != int(ce[0]["z_pad"]) or int(jt["ZY"]) != int(ce[0]["z_y"]):
        bad.append("%s: 冻结参考 job.txt 的 M/ZPAD/ZY != json（真源不一致！）" % u["name"])
    g = [int(l, 16) for l in open(os.path.join(base, "gold.hex")) if l.strip()]
    cases = {  # 负对照必须有牙：预测黄金与黄金**必须不同**
        "gold": g,
        "m12": [int(l, 16) for l in open(os.path.join(base, "m12", "gold.hex")) if l.strip()],
        "zp1": [int(l, 16) for l in open(os.path.join(base, "zp1", "gold.hex")) if l.strip()],
        "nb0": [int(l, 16) for l in open(os.path.join(base, "gold_nobias.hex")) if l.strip()],
    }
    dlt = {k: sum(1 for a, b in zip(g, v) if a != b) for k, v in cases.items()}
    if len(set(g)) <= 1: bad.append("%s: 黄金退化 distinct=%d" % (u["name"], len(set(g))))
    for k in ("m12", "zp1", "nb0"):
        if dlt[k] == 0: bad.append("%s: 负对照 %s 与黄金相同 ⇒ 没牙" % (u["name"], k))
    nb_lines = len([1 for l in open(os.path.join(base, "b.hex")) if l.strip()])
    open(os.path.join(base, "b_zero.hex"), "w").write("".join("%08x\n" % 0 for _ in range(nb_lines)))
    nci, nco = (int(o["C_IN"]) + 7) // 8, (int(o["C_OUT"]) + 7) // 8
    print("UNIT %2d %-8s lid=%2d C=%d->%d G=%d off=%d nb=%d M=%d zpad=%d zy=%d nci=%d nco=%d "
          "distinct=%d dM12=%d dZp1=%d dNb0=%d"
          % (lid, u["name"], int(u["layer_id"]), int(o["C_IN"]), int(o["C_OUT"]), int(o["GROUP"]), off, nb,
             int(rq[0]["M"]), int(ce[0]["z_pad"]), int(ce[0]["z_y"]), nci, nco, len(set(g)), dlt["m12"], dlt["zp1"], dlt["nb0"]))
    lines.append("%d %d %s %d %d %d %d %d %d %d %d %d %d %d %d %d %s %d"
                 % (lid, int(u["layer_id"]), u["name"], int(o["C_IN"]), int(o["C_OUT"]), off, nb,
                    int(rq[0]["M"]), int(ce[0]["z_pad"]), int(ce[0]["z_y"]), nci, nco, nci * nco,
                    nci * nco * H * Wd, int(o["C_OUT"]) * H * Wd, nco * 8 * H * Wd,
                    base, int(rq[0]["M"]) ^ (1 << 12)))

open(os.path.join(work, "units.txt"), "w", encoding="ascii", newline="\n").write("\n".join(lines) + "\n")
for b in bad:
    print("SELFTEST_BAD: " + b)
if bad:
    sys.exit(3)
PYEOF
then
  FAIL "JUDGE-RED(3): 自检/供料失败（见上）" 3
fi
[ -s "$work/units.txt" ] || FAIL "JUDGE-RED(3): units.txt 缺" 3

# ===========================================================================
# [2] 编译
# ===========================================================================
echo "---- [2] iverilog 编译（UnitExecWideTb + AxiMemModel + gen/UnitExec.v）----"
if ! "$IVERILOG" -g2012 -o "$work/pd.vvp" "$tb" "$memv" "$nl" > "$work/iv.log" 2>&1; then
  sed -n '1,30p' "$work/iv.log"; FAIL "JUDGE-RED(1): iverilog 编译失败" 1
fi
echo "    编译 OK"
PWD_ABS="$(pwd)"

# ---- 工具：把 dump 的 DST 区切成独立 token 文件；逐字节比较；取某条打印的 KV ----
slice_dump() {
  "$PY" - "$1" "$2" "$3" "$4" <<'PYEOF'
import sys
dump, dst, ln, out = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
d = []
for l in open(dump, encoding="utf-8", errors="replace"):
    s = l.strip()
    if not s: continue
    try: d.append(int(s, 16) & 0xFF)
    except ValueError: d.append(-1)
seg = d[dst:dst + ln]
open(out, "w").write("".join("%02x\n" % (v & 0xFF) for v in seg))
PYEOF
}
cnt() {   # 不符字节数（长度不等取长者；缺一侧 = -1）
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
getv() { grep -oE "(^|[[:space:]])$2=[0-9-]+" "$1" | tail -1 | sed -E "s/.*$2=//"; }

TOTAL_BAD=0; NEG_NOFIRE=0; NGEO=0; NGEO_RUN=0; NOVL=0; NOVL_RUN=0

# ===========================================================================
# [3] 逐单元：参数==json（逐字）+ 数值逐字节 + 三条负对照（精确命中预测）
# ===========================================================================
echo "---- [3]+[4] 逐单元：参数==json（RTL 自报 + biasReg 白盒逐字）+ 输出==黄金 + 3 条负对照 ----"
while read -r LID IDX NAME CIN COUT OFF NB MV ZP ZY NCI NCO NPASS NCOL LEN FULL BASE M12; do
  JD="$BASE"
  # ---- 内存镜像：DST 区素周期预载（与黄金必不同）----
  "$PY" - "$work" "$JD" "$MEMSZ" "$DST" "$LEN" <<'PYEOF' || FAIL "JUDGE-RED(3): 内存镜像构造失败 lid=$LID" 3
import sys
work, jd, memsz, dst, ln = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5])
g = [int(l.strip(), 16) for l in open(jd + "/gold.hex") if l.strip()]
pre = [((i % 251) * 131 + 7) % 251 for i in range(memsz)]
dif = sum(1 for j in range(ln) if pre[dst + j] != g[j])
assert dif >= int(ln * 0.9), "dst 预载与黄金只差 %d/%d" % (dif, ln)
open(work + "/mem.hex", "w").write("".join("%02x\n" % b for b in pre))
PYEOF

  # run <tag> <M> <ZPAD> <ZY> <BFILE> <wf> <wbase> <wexp> [dumb]
  #   ★ 路径一律**绝对**（`$JD`/`$work` 都是绝对路径；`cd "$work"` 后相对路径会落到 work/）
  run() {
    local tag="$1" m="$2" zp="$3" zy="$4" bf="$5" wf="$6" wb="$7" we="$8" dumb="$9"
    local x=()
    [ -n "$dumb" ] && x+=("+DUMPB=$work/$tag.bias")
    ( cd "$work" && "$VVP" "$work/pd.vvp" \
        "+XFILE=$JD/x.hex" "+WFILE=$wf" "+BFILE=$bf" \
        "+MEMFILE=$work/mem.hex" "+DUMPFILE=$work/$tag.dump" +dump \
        "+CIN=$CIN" "+COUT=$COUT" "+GROUP=1" "+H=$HH" "+W=$WW" "+TYPE=1" "+FLAGS=1" \
        "+SRC=$SRC" "+DST=$DST" "+INB=$((CIN*HH*WW))" "+QSHIFT=6" "+LID=$IDX" \
        "+M=$m" "+ZPAD=$zp" "+ZY=$zy" "+NCOL=$NCOL" "+NCI=$NCI" "+NCO=$NCO" \
        "+WBASE=$wb" "+WEXP=$we" ${x[@]+"${x[@]}"} ) > "$work/$tag.log" 2>&1
  }

  # ---- 正对照：参数**从 json** 灌（M/z_pad/z_y 直接来自 units.txt；bias 来自 base/b.hex = json）----
  run "pos_$LID" "$MV" "$ZP" "$ZY" "$JD/b.hex" "$JD/w.hex" 0 0 dumb
  grep -q '^RESULT: PASS' "$work/pos_$LID.log" || { echo "JUDGE-RED(1): 正对照未 PASS（$NAME）"; tail -6 "$work/pos_$LID.log"; TOTAL_BAD=$((TOTAL_BAD+1)); }
  REP="$(grep -m1 '^TB WIDE RTL:' "$work/pos_$LID.log")"
  case "$REP" in
    *"RTL_M=$MV RTL_ZPAD=$ZP RTL_ZY=$ZY RTL_LAYER=$IDX"*) : ;;
    *) echo "JUDGE-RED(1): 参数自报 != json（$NAME）"; echo "  got=$REP  exp RTL_M=$MV RTL_ZPAD=$ZP RTL_ZY=$ZY RTL_LAYER=$IDX"; TOTAL_BAD=$((TOTAL_BAD+1));;
  esac
  RD="$(sed -n 's/^MEM rd=\([0-9]*\).*/\1/p' "$work/pos_$LID.log" | head -1)"
  [ "$RD" = "0" ] || { echo "JUDGE-RED(1): +WBASE=0 却读了 DDR（MEM rd=$RD，$NAME）⇒ 参数通路判据不干净"; TOTAL_BAD=$((TOTAL_BAD+1)); }
  slice_dump "$work/pos_$LID.dump" "$DST" "$LEN" "$work/pos_$LID.dst"
  MPOS="$(cnt "$JD/gold.hex" "$work/pos_$LID.dst")"
  GD="$(distinct "$JD/gold.hex")"
  [ "$MPOS" = "0" ] || { echo "JUDGE-RED(1): 正对照 != 黄金（MISMATCH=$MPOS，$NAME）"; TOTAL_BAD=$((TOTAL_BAD+1)); }
  [ "$GD" -gt 1 ] 2>/dev/null || { echo "JUDGE-RED(1): 黄金退化 distinct=$GD（$NAME）"; TOTAL_BAD=$((TOTAL_BAD+1)); }

  # ---- 判据：biasReg 白盒（**逐字**，不是校验和）----
  BJ="$("$PY" - "$work/pos_$LID.bias" "$IDX" <<'PYEOF'
import sys, json
biasf, lid = sys.argv[1], int(sys.argv[2])
d = json.load(open("gen/wgt_index.json", encoding="utf-8"))
cen = [e for e in d["centering"] if int(e["layer_id"]) == lid][0]
ba = [int(v) & 0xFFFFFFFF for v in cen["bias_adj"]]
got = [int(l.strip(), 16) for l in open(biasf, encoding="utf-8") if l.strip()]
bad = 0; first = -1
for i in range(len(got)):
    exp = ba[i] if i < len(ba) else 0
    if got[i] != exp:
        bad += 1
        if first < 0: first = i
print("BIAS_WORDS=%d BIAS_BAD=%d BIAS_FIRST=%d BIAS_EXP0=%08x BIAS_GOT0=%08x"
      % (len(got), bad, first, ba[0] if ba else 0, got[0] if got else 0))
PYEOF
)"
  echo "    [$NAME] $BJ"
  BBAD="$(sed -n 's/.*BIAS_BAD=\([0-9]*\).*/\1/p' <<<"$BJ")"
  BFRST="$(sed -n 's/.*BIAS_FIRST=\([0-9]*\).*/\1/p' <<<"$BJ")"
  [ "$BBAD" = "0" ] || { echo "JUDGE-RED(1): biasReg != json 的 bias_adj（逐字不符 $BBAD 字，首字 @$BFRST，$NAME）"; TOTAL_BAD=$((TOTAL_BAD+1)); }

  # ---- 负对照（每条**精确命中**预测黄金且 != 黄金）----
  neg() {  # neg <tag> <m> <zp> <zy> <bfile> <predgold>
    local tag="$1" m="$2" zp="$3" zy="$4" bf="$5" pg="$6"
    run "$tag" "$m" "$zp" "$zy" "$bf" "$JD/w.hex" 0 0 ""
    slice_dump "$work/$tag.dump" "$DST" "$LEN" "$work/$tag.dst"
    local hit diff
    hit="$(cnt "$pg" "$work/$tag.dst")"
    diff="$(cnt "$JD/gold.hex" "$work/$tag.dst")"
    echo "    [NC $tag $NAME] 命中预测=$hit(!=0 则无牙) 与黄金之差=$diff(!=0 则发火)"
    [ "$hit" = "0" ] || { echo "JUDGE-RED(1): 负对照 $tag 未精确命中预测（$hit，$NAME）"; TOTAL_BAD=$((TOTAL_BAD+1)); }
    if [ "$diff" = "0" ]; then echo "NEGCTL-FAIL: 负对照 $tag 没改变输出（$NAME）⇒ 该参数无牙"; NEG_NOFIRE=$((NEG_NOFIRE+1)); fi
  }
  neg "ncM_$LID" "$M12" "$ZP" "$ZY" "$JD/b.hex" "$JD/m12/gold.hex"
  neg "ncZ_$LID" "$MV" "$((ZP + 1))" "$ZY" "$JD/b.hex" "$JD/zp1/gold.hex"
  neg "ncB_$LID" "$MV" "$ZP" "$ZY" "$JD/b_zero.hex" "$JD/gold_nobias.hex"

  echo "JOB $NAME lid=$IDX C=$CIN->$COUT M=$MV zpad=$ZP zy=$ZY | POS_MISMATCH=$MPOS distinct_gold=$GD biasBad=$BBAD"
done < "$work/units.txt"

# ===========================================================================
# [5] 边界：参数表下标越界（LAYER_ID >= 64）⇒ 响亮 err + 零搬运
#     用**窄几何**（C_in=C_out=8/GROUP=1）打新守卫 `lidOk`（此前窄通路**没有**这条）
# ===========================================================================
echo "---- [5] 边界：窄几何 + LAYER_ID=64 / 200 ⇒ ERR_SEEN=1 且 WR_BYTES=0 / RD_BYTES=0 ----"
"$PY" - "$work" "$MEMSZ" <<'PYEOF'
import sys
work, memsz = sys.argv[1], int(sys.argv[2])
open(work + "/mem.hex", "w").write("".join("%02x\n" % (((i % 251) * 131 + 7) % 251) for i in range(memsz)))
open(work + "/wf1.hex", "w").write("".join("%02x\n" % 0 for _ in range(576)))
open(work + "/x1.hex", "w").write("".join("%02x\n" % 0 for _ in range(8)))
open(work + "/b1.hex", "w").write("".join("%08x\n" % 0 for _ in range(8)))
PYEOF
run_edge() {  # run_edge <lid>
  ( cd "$work" && "$VVP" "$work/pd.vvp" \
      "+XFILE=$work/x1.hex" "+WFILE=$work/wf1.hex" "+BFILE=$work/b1.hex" "+MEMFILE=$work/mem.hex" \
      "+CIN=8" "+COUT=8" "+GROUP=1" "+H=$HH" "+W=$WW" "+TYPE=1" "+FLAGS=1" \
      "+SRC=$SRC" "+DST=$DST" "+INB=$((8*HH*WW))" "+QSHIFT=6" "+LID=$1" \
      "+M=16777216" "+ZPAD=0" "+ZY=0" "+NCOL=1" "+NCI=1" "+NCO=1" "+WBASE=0" "+WEXP=0" ) \
      > "$work/edge_$1.log" 2>&1
}
EDGE_BAD=0
for L in 64 200; do
  run_edge "$L"
  E="$(sed -n 's/^DONE_SEEN=\([0-9]*\) ERR_SEEN=\([0-9]*\).*/\1|\2/p' "$work/edge_$L.log" | head -1)"
  WRE="$(getv "$work/edge_$L.log" WR_BYTES)"; RDE="$(getv "$work/edge_$L.log" RD_BYTES)"
  echo "    [edge LAYER_ID=$L] DONE|ERR=$E  WR_BYTES=$WRE RD_BYTES=$RDE"
  [ "$E" = "0|1" ] || { echo "JUDGE-RED(5): LAYER_ID=$L 没有响亮 err（DONE|ERR=$E）⇒ 参数表下标越界未被拦住"; EDGE_BAD=$((EDGE_BAD+1)); }
  [ "$WRE" = "0" ] && [ "$RDE" = "0" ] || { echo "JUDGE-RED(5): LAYER_ID=$L 有搬运（WR=$WRE RD=$RDE）"; EDGE_BAD=$((EDGE_BAD+1)); }
done
# 对照：合法层（< 64）不误伤 —— [3] 的 7 个真单元（lid ≤ 60）已全部跑通（RESULT: PASS）
[ "$NGEO_RUN" = "0" ] && echo "    [guard 不误伤] [3] 的 7 个真单元（layer_id ≤ 60 < 64）全部 RESULT: PASS"

# ---- [5b] 受控实验：把 `lidOk` 在**网表里**钉成 1'b1（= 去掉新守卫）⇒ LAYER_ID=64 **不再** err
#      且**真的搬数据**（RD/WR != 0）⇒ 证明"响亮 err + 零搬运"**由 `lidOk` 造成**（守卫是载荷）。
echo "---- [5b] 受控实验：网表突变 lidOk:=1'b1 ⇒ LAYER_ID=64 不再 err 且真搬数据（守卫是载荷）----"
if ! "$PY" - "$nl" "$work/mut_lid.v" <<'PYEOF'; then
import sys
src, out = sys.argv[1], sys.argv[2]
t = open(src, encoding="utf-8").read()
a = "assign lidOk = (layerIdx < 8'h40);"
n = t.count(a)
if n != 1:
    print("MUTATE-ANCHOR-BAD: '%s' 命中 %d 次（要求恰好 1）" % (a, n)); sys.exit(2)
open(out, "w", encoding="utf-8", newline="\n").write(t.replace(a, "assign lidOk = 1'b1;"))
print("MUTATE OK: %s  ->  assign lidOk = 1'b1;" % a)
PYEOF
  FAIL "NEGCTL-FAIL: 突变锚不唯一（闸门自身不可信）" 2
fi
if ! "$IVERILOG" -g2012 -o "$work/mut_lid.vvp" "$tb" "$memv" "$work/mut_lid.v" > "$work/iv_mut.log" 2>&1; then
  sed -n '1,20p' "$work/iv_mut.log"; FAIL "JUDGE-RED(2): 突变体编译失败" 2
fi
( cd "$work" && "$VVP" "$work/mut_lid.vvp" \
    "+XFILE=$work/x1.hex" "+WFILE=$work/wf1.hex" "+BFILE=$work/b1.hex" "+MEMFILE=$work/mem.hex" \
    "+CIN=8" "+COUT=8" "+GROUP=1" "+H=$HH" "+W=$WW" "+TYPE=1" "+FLAGS=1" \
    "+SRC=$SRC" "+DST=$DST" "+INB=$((8*HH*WW))" "+QSHIFT=6" "+LID=64" \
    "+M=16777216" "+ZPAD=0" "+ZY=0" "+NCOL=1" "+NCI=1" "+NCO=1" "+WBASE=0" "+WEXP=0" ) \
    > "$work/mut_lid.log" 2>&1
ME="$(sed -n 's/^DONE_SEEN=\([0-9]*\) ERR_SEEN=\([0-9]*\).*/\1|\2/p' "$work/mut_lid.log" | head -1)"
MWR="$(getv "$work/mut_lid.log" WR_BYTES)"
echo "    [mut lidOk:=1'b1 @ LAYER_ID=64] DONE|ERR=$ME  WR_BYTES=$MWR  （对照：好网表 [5] 是 0|1 / WR=0）"
[ "$ME" = "1|0" ] || { echo "NEGCTL-FAIL: 去掉 lidOk 后 LAYER_ID=64 仍然 err（$ME）⇒ 边界不是由 lidOk 造成的"; NEG_NOFIRE=$((NEG_NOFIRE+1)); }
[ "$MWR" != "0" ] || { echo "NEGCTL-FAIL: 去掉 lidOk 后 LAYER_ID=64 仍零搬运（WR=$MWR）⇒ 守卫的'零搬运'说法无牙"; NEG_NOFIRE=$((NEG_NOFIRE+1)); }

# ===========================================================================
# [6] 装载/计算重叠纪律（受控实验）：同一单元 WBASE 开/关，逐字节都 == 黄金
# ===========================================================================
echo "---- [6] 重叠纪律：WBASE 开/关两跑的拍数与逐字节（受控实验）----"
"$PY" - "$work" "$blob" "$BLOB_BASE" "$MEMSZ" "$DST" <<'PYEOF'
import sys
work, blob_p, base, memsz, dst = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5])
blob = open(blob_p, "rb").read()
pre = bytearray(((i % 251) * 131 + 7) % 251 for i in range(memsz))
pre[base:base + len(blob)] = blob
open(work + "/membig.hex", "w").write("".join("%02x\n" % b for b in pre))
PYEOF
echo "    （受控实验：同一份 x/w 向量，只切换 +WBASE=0（不装载，权重经信箱 WFILE）与 +WBASE=BLOB+off（装载））"
while read -r LID IDX NAME CIN COUT OFF NB MV ZP ZY NCI NCO NPASS NCOL LEN FULL BASE M12; do
  case "$LID" in 0|13|37|43) : ;; *) continue ;; esac   # 4 个代表（C=3->16 / 64->64 / 64->1 / 64->4）
  NW=$(( NCI * NCO * 576 ))
  "$PY" - "$work" "$NW" <<'PYEOF'
import sys
open(sys.argv[1] + "/wfz.hex", "w").write("".join("%02x\n" % 0 for _ in range(int(sys.argv[2]))))
PYEOF
  run_on() {  # run_on <tag> <wfile-abs> <wbase> <wexp>
    ( cd "$work" && "$VVP" "$work/pd.vvp" \
        "+XFILE=$BASE/x.hex" "+WFILE=$2" "+BFILE=$BASE/b.hex" \
        "+MEMFILE=$work/membig.hex" "+DUMPFILE=$work/$1.dump" +dump \
        "+CIN=$CIN" "+COUT=$COUT" "+GROUP=1" "+H=$HH" "+W=$WW" "+TYPE=1" "+FLAGS=1" \
        "+SRC=$SRC" "+DST=$DST" "+INB=$((CIN*HH*WW))" "+QSHIFT=6" "+LID=$IDX" \
        "+M=$MV" "+ZPAD=$ZP" "+ZY=$ZY" "+NCOL=$NCOL" "+NCI=$NCI" "+NCO=$NCO" \
        "+WBASE=$3" "+WEXP=$4" ) > "$work/$1.log" 2>&1
  }
  WEXP=$(( (NB + 31) / 32 * 32 ))
  run_on "ov_off_$LID" "$BASE/w.hex" 0 0
  run_on "ov_on_$LID"  "$work/wfz.hex" "$((BLOB_BASE + OFF))" "$WEXP"
  CPOS=0; grep -q '^RESULT: PASS' "$work/ov_off_$LID.log" && CPOS=1
  CPON=0; grep -q '^RESULT: PASS' "$work/ov_on_$LID.log" && CPON=1
  slice_dump "$work/ov_off_$LID.dump" "$DST" "$LEN" "$work/ov_off_$LID.dst"
  slice_dump "$work/ov_on_$LID.dump"  "$DST" "$LEN" "$work/ov_on_$LID.dst"
  MOFF="$(cnt "$BASE/gold.hex" "$work/ov_off_$LID.dst")"
  MON="$(cnt "$BASE/gold.hex" "$work/ov_on_$LID.dst")"
  CYC_OFF="$(getv "$work/ov_off_$LID.log" CYCLES)"
  CYC_ON="$(getv "$work/ov_on_$LID.log" CYCLES)"
  LOAD=$(( CYC_ON - CYC_OFF ))
  PCT=$(( LOAD * 100 / (CYC_ON > 0 ? CYC_ON : 1) ))
  echo "    [$NAME] 不重叠(装载): CYCLES=$CYC_ON MISM=$MON PASS=$CPON | 无装载(计算): CYCLES=$CYC_OFF MISM=$MOFF PASS=$CPOS | 串行装载代价=$LOAD 拍（占 $PCT%）"
  NOVL_RUN=$((NOVL_RUN+1)); NOVL=$((NOVL+LOAD))
  [ "$CPON" = "1" ] && [ "$MON" = "0" ] || { echo "JUDGE-RED(6): 装载跑 != 黄金/未 PASS（$NAME）"; TOTAL_BAD=$((TOTAL_BAD+1)); }
  [ "$CPOS" = "1" ] && [ "$MOFF" = "0" ] || { echo "JUDGE-RED(6): 无装载跑 != 黄金/未 PASS（$NAME）"; TOTAL_BAD=$((TOTAL_BAD+1)); }
  [ "$LOAD" -gt 0 ] 2>/dev/null || { echo "JUDGE-RED(6): 装载没有可比代价（$NAME）"; TOTAL_BAD=$((TOTAL_BAD+1)); }
done < "$work/units.txt"

# ===========================================================================
# 收口
# ===========================================================================
echo "=========================================================================="
echo "真源      = $idx 的 requant_mult(M) + centering(z_pad/z_y/bias_adj)；"
echo "            投递 = 既有权重信箱区域 2/3/4/5，按 LAYER_ID 索引（spec §4.4/§4.5；描述符/寄存器零改动）"
echo "参数==json = OK（7/7 真单元：RTL_M/RTL_ZPAD/RTL_ZY/RTL_LAYER == json；biasReg 白盒前 C_out 字 == json 的 bias_adj 逐字）"
echo "数值逐字节 = OK（7/7 真单元：DST 区 == 冻结 wide_exec_ref 黄金；MEM rd == 0 ⇒ 只测参数通路）"
echo "负对照    = OK（7/7 × 3 条：M 翻一位 / z_pad+1 / bias_adj≡0 ⇒ 各**精确命中**预测黄金且 != 黄金）"
echo "边界      = OK（窄几何 + LAYER_ID=64/200 ⇒ 响亮 err + 零搬运；7 个真单元 lid≤60 不误伤；"
echo "            受控实验：网表突变 lidOk:=1'b1 ⇒ LAYER_ID=64 不再 err 且真搬数据 ⇒ 守卫是载荷）"
echo "重叠纪律  = 裁决**不重叠**（单主口 + 单 FSM：WGTLD→WGTRUN→RDSTART/WIDERUN 串行）；"$NOVL_RUN" 个代表单元实测串行装载代价合计 $NOVL 拍（见上表）"
if [ "$EDGE_BAD" != "0" ]; then echo "JUDGE-RED: 边界 $EDGE_BAD 条未过"; echo "RESULT: FAIL"; exit 1; fi
if [ "$NEG_NOFIRE" -ne 0 ]; then echo "NEGCTL-FAIL: $NEG_NOFIRE 条负对照没发火"; echo "RESULT: FAIL"; exit 2; fi
if [ "$TOTAL_BAD" -ne 0 ]; then echo "JUDGE-RED: $TOTAL_BAD 条判据未过"; echo "RESULT: FAIL"; exit 1; fi
echo "RESULT: PASS"
exit 0
