#!/usr/bin/env bash
# run_wgtdma_wide_ab.sh —— ★ C4b-B1b「**宽层**权重段从 DDR 批量装载」闸门
#   （`rtl/UnitExec.scala` 的 **同一个** WGTLD/WGTRUN 装载器 + 宽通路落点 `wRam`）
#
# 目标（计划 C4b Task B1b）：B1（`29f95a7`）只覆盖**窄层**（段长能装进切片 `WeightStore`），
#   真表里的 conv 单元基本全是**宽层**（`C_in>8 || C_out>8`）⇒ 本任务把同一条 DMA 装载机制
#   接到**宽层多趟通路**的趟瓦片 RAM `wRam`（36,864 B；原先只经信箱**区域 1** 逐字节由主机灌）。
#
# 三条判据（**都要能发火**；与 B1 同形，只是判据① 的对照面从 `WeightStore` 换成 `wRam`）：
#   ① **逐单元、逐字节**：宽层跑完后把 `wRam` 全量（36864 B）读回，与"按 blob 布局 + 趟序映射
#      算出来的那一幅"逐字节对账（`WRAM_BAD == 0`）；且**段外**（≥ `nCi*nCo*576`）一个字节都不许被写。
#      ★ 映射（本闸门的中心口径，与 `MultiPassUnit` 读的趟序一致）：
#        wRam[(cob*nCi + cib)*576 + cl*72 + cil*9 + tap] == blob[off + ((cob*8+cl)*C_in + (cib*8+cil))*9 + tap]
#        （cl = co%8、cil = ci%8、tap = ky*3+kx；blob 是密集 [co][ci][tap]，C_in%8==0 && C_out%8==0
#         时两边字节数**相等** ⇒ 装载是一次**纯重排**（8x8 块划分，nCi*nCo*576 == 段长））。
#      ★ 该镜像由**两条独立的路径**得出并互证：本闸门按上式从 blob 段算 vs `wide_exec_ref.py` 算的 w.hex。
#   ② **装载字节数 == `wgt_index.json` 的 `bytes`**（多/少都要红）：**三方独立对账** ——
#      · 内存模型 `MEM rd`（总线真正读回的字节）；
#      · 设备侧自报 `WGT_BYTES`（`UnitExec.wgt_bytes` = 装载器逐字节计数）；
#      · 期望值 = 真 index 里该单元的 `bytes`（= C_out*C_in*9）。
#   ③ **负对照（必须发火，且要能定位）**：
#      · N1：DDR 镜像里把该段的**一个字节**改掉 ⇒ 红，且报出 wRam 地址 <-> (趟, cl, cil, tap) <-> blob 绝对偏移；
#      · N2：**网表突变**（权重 RD 段长 +32 B）⇒ **多读**：MEM rd 恰 +32，而 wRam 仍逐字节相等、
#        WGT_BYTES 仍 = 段长（证明判据② 抓的是**字节数**本身，不是"数据对不对"）；
#      · N3：**网表突变**（段长 -32 B + 收尾条件同步改小）⇒ **少读**：MEM rd/WGT_BYTES 各 -32，
#        且判据① 一起发火（段尾 32 字节为 0）⇒ 位置/字节数两条判据**一起**有牙。
#
# 另附（能力边界，非判据）：★★ C4b-B1c 起 `C_IN%8!=0`（真表 Conv_0）**已被装载器支持**（见新闸门
#   `run_wgtdma_geom_ab.sh`）；本闸门 [4b] 的边界改成"`GROUP ∉ {1, C_in==C_out}`"⇒ dmaEn 下**响亮 err + 零搬运**
#   （`ERR_SEEN=1 WGT_BYTES=0 RD_PEAK=0` 且 wRam 一字节未改）——绝不静默算错。
#
# 实测数据（真转换器产物，gen/wgt_index.json + gen/wgt_blob.bin；★ B0 2026-10-12 **32 B 对齐布局**）：
#   单元 Conv_6（idx/layer_id **4**）：C_IN=16 C_OUT=16 GROUP=1、offset=**2912**（32 B 对齐；对齐后 2880→2912）、
#   nbytes=2304（32 的整数倍 ⇒ aligned_bytes==2304）⇒ n_ci=2 n_co=2、nCi*nCo*576 = 2304 == nbytes（纯重排）。
#   数值正对照：DST 区逐字节 == tools/wide_exec_ref.py --lid 4 的黄金（权重**只**经 DMA 进来）。
#   ★ B0 新增 [8]：**真表单元装载扫描** —— 取真 index 的多个单元（各自的真 offset/nbytes）逐个跑 RTL 装载，
#     证明"对齐后真单元不再触发 DdrMaster 的 `src%32/len%32` err 且逐字节相等"。
#
# 退出码（与 Y1 既有闸门一致）：0 = 全绿；1 = 判据红；2 = 负对照没发火 / 突变锚不唯一；3 = 向量或自检失败。
#
# 装置契约（rtl_test/UnitExecWideTb.v + rtl_test/AxiMemModel.v + gen/UnitExec.v）：
#   +CIN +COUT +GROUP +H +W +TYPE +FLAGS +SRC +DST +INB +QSHIFT +LID +M +ZPAD +ZY +NCOL +NCI +NCO
#   +XFILE +WFILE +BFILE +MEMFILE +DUMPFILE +dump   [C4b-B1b 新增：+WBASE= +WEXP= +DUMPW=]
#   装置打印：TB WIDE RTL: ... / DONE_SEEN=.. ERR_SEEN=.. NFED=.. RD_PEAK=.. RD_BYTES=.. WGT_BYTES=..
#             WR_BYTES=.. AR=.. AW=.. B=.. WBASE=.. / WRAM_DUMPED .. / RESULT: PASS|FAIL
#   内存模型打印：MEM rd=<b> wr=<b> bursts=<n> maxburst=<n>
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
cd "$here/.." || { echo "FATAL: 进不去 y1/"; echo "RESULT: FAIL"; exit 3; }

PY="${PY:-/d/code/PDS/NaxYeshenLinux/sim/reglogs/lxvenv/Scripts/python.exe}"
[ -x "$PY" ] || PY="$(command -v python || command -v python3 || true)"
[ -n "$PY" ] || { echo "FATAL: 找不到 python"; echo "RESULT: FAIL"; exit 3; }

ref="tools/wide_exec_ref.py"
tb="rtl_test/UnitExecWideTb.v"
memv="rtl_test/AxiMemModel.v"
nl="gen/UnitExec.v"
idx="gen/wgt_index.json"
blob="gen/wgt_blob.bin"
outdir="gen/c4b_wide_dma"

# ---- 用例常量（与 TB 的 AxiMemModel MEMSZ / 装置上限一致）----
MEMSZ=2621440          # 2.5 MiB
WBASE=524288           # 0x80000：权重段在 DDR 的起点（32 B 对齐）
SRC=131072             # 0x20000（宽层不从 DDR 读激活；只为描述符字段合法）
DST=2097152            # 0x200000：输出区
LID=4                  # Conv_6（真表 idx 4；参数表按 LAYER_ID=4 索引）
CIN=16; COUT=16; HH=4; WW=64; NCI=2; NCO=2; NCOL=1024
SEGOFF=2912            # 该单元权重段在真 blob 里的起点（= wgt_index.json 的 offset；★ B0 对齐后 2880→2912）
NW=$(( NCI * NCO * 576 ))     # 段长 = 2304（== index.bytes）
SEGFLIP=7              # 负对照 N1 翻的**段内**偏移
MAXW=$(( 8 * 8 * 576 ))       # wRam 字节数（36864）
LEN=$(( COUT * HH * WW ))     # 输出字节数 = 4096

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
for f in "$ref" "$tb" "$memv" "$nl" "$idx" "$blob"; do
  [ -f "$f" ] || { echo "FATAL: 缺 $f"; echo "RESULT: FAIL"; exit 3; }
done
[ -n "$IVERILOG" ] && [ -n "$VVP" ] || { echo "FATAL: 找不到 iverilog/vvp"; echo "RESULT: FAIL"; exit 3; }

work="$(mktemp -d)"
cleanup() { if [ "${KEEP_TMP:-0}" = "1" ]; then echo "KEEP_TMP=1 => 中间件在 $work"; else rm -rf "$work"; fi }
trap cleanup EXIT
export PYTHONIOENCODING=utf-8
export PYTHONPATH="./.pydeps;../third_party/yunet/deps"

echo "== run_wgtdma_wide_ab: 宽层权重段从 DDR 装载（同一装载器 + 落点 wRam）=="
echo "   nl=$nl  tb=$tb  py=$PY  iverilog=$IVERILOG  vvp=$VVP  tmp=$work"
echo "   用例：idx=$LID（Conv_6）C_IN=$CIN C_OUT=$COUT H=$HH W=$WW n_ci=$NCI n_co=$NCO 段长=$NW"

TOTAL_BAD=0; NEG_NOFIRE=0
FAIL() { echo "$1"; echo "RESULT: FAIL"; exit "$2"; }

# ---------------------------------------------------------------------------
# [0] 自检：真 blob 指纹 + 单元几何 + 趟序映射是双射（离线，先于任何仿真）
# ---------------------------------------------------------------------------
echo "---- [0] 自检：blob 指纹 + 单元几何 + 趟序映射（双射）----"
if ! "$PY" - "$idx" "$blob" "$LID" "$CIN" "$COUT" "$NCI" "$NCO" <<'PYEOF'; then
import sys, json, hashlib
idx_p, blob_p, lid, cin, cout, nci, nco = (sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4]),
                                           int(sys.argv[5]), int(sys.argv[6]), int(sys.argv[7]))
d = json.load(open(idx_p, encoding="utf-8")); blob = open(blob_p, "rb").read()
bad = []
if d["blob"]["bytes"] != len(blob): bad.append("blob 字节数 %d != index %d" % (len(blob), d["blob"]["bytes"]))
md5 = hashlib.md5(blob).hexdigest()
if md5 != "aa135f0f7d50780b7b13d9a1ba9c518a": bad.append("blob md5=%s != aa135f0f7d50780b7b13d9a1ba9c518a" % md5)
u = [x for x in d["units"] if x["idx"] == lid][0]
w = u["weight"]; off, nb = int(w["offset"]), int(w["nbytes"]); o = u["own"]
if (int(o["C_IN"]), int(o["C_OUT"]), int(o["GROUP"])) != (cin, cout, 1): bad.append("几何不符 %s" % o)
if nb != cin * cout * 9: bad.append("bytes=%d != C_in*C_out*9=%d" % (nb, cin * cout * 9))
if off % 32: bad.append("段起点 %d 非 32 B 对齐（DdrMaster 会响亮拒绝）" % off)
if nb % 32:  bad.append("段长 %d 非 32 的整数倍（RD 粒度）" % nb)
if nb != nci * nco * 576: bad.append("段长 %d != nCi*nCo*576=%d（本闸门要求纯重排）" % (nb, nci * nco * 576))
if off + nb > len(blob): bad.append("段越出 blob")
seen = set()
for co in range(cout):
    for ci in range(cin):
        for tap in range(9):
            dd = ((co // 8) * nci + (ci // 8)) * 576 + (co % 8) * 72 + (ci % 8) * 9 + tap
            if dd in seen: bad.append("双射破裂：dest %d 被写两次" % dd)
            seen.add(dd)
if sorted(seen) != list(range(nb)): bad.append("双射破裂：像集 != [0,%d)" % nb)
print("SELFTEST unit=%s idx=%d off=%d bytes=%d n_ci=%d n_co=%d dest_cover=%d"
      % (u["name"], lid, off, nb, nci, nco, len(seen)))
print("SELFTEST blob_bytes=%d md5=%s" % (len(blob), md5))
for b in bad: print("SELFTEST_BAD: " + b)
sys.exit(3 if bad else 0)
PYEOF
  FAIL "JUDGE-RED(3): 自检不过" 3
fi

# ---------------------------------------------------------------------------
# [1] 参考供料（真层 Conv_6：XFILE/BFILE/M/ZPAD/ZY + 黄金）
# ---------------------------------------------------------------------------
echo "---- [1] 参考供料：wide_exec_ref --lid $LID --H $HH --W $WW ----"
if ! "$PY" "$ref" --lid "$LID" --H "$HH" --W "$WW" --outdir "$outdir" > "$work/ref.out" 2>&1; then
  tail -10 "$work/ref.out"; FAIL "JUDGE-RED(3): 供料失败" 3
fi
grep -E '^WIDE_REF|^RESULT' "$work/ref.out" | sed 's/^/    /'
JD="$(ls -d "$outdir"/lid"$LID"_* 2>/dev/null | head -1)"
[ -n "$JD" ] && [ -f "$JD/gold.hex" ] || FAIL "JUDGE-RED(3): 找不到参考作业目录" 3
MV="$(sed -n 's/^M=//p' "$JD/job.txt" | head -1)"
ZP="$(sed -n 's/^ZPAD=//p' "$JD/job.txt" | head -1)"
ZY="$(sed -n 's/^ZY=//p' "$JD/job.txt" | head -1)"
echo "    作业目录 $JD  M=$MV ZPAD=$ZP ZY=$ZY（job.txt 的 LID 是占位 0；本闸门按真 layer_id=$LID 索引参数表）"

# ---------------------------------------------------------------------------
# [2] 向量：期望 wRam 镜像（blob→趟序）+ DDR 镜像（正 / 翻一字节）+ 零 WFILE
# ---------------------------------------------------------------------------
echo "---- [2] 向量：期望 wRam 镜像（blob→趟序，并与参考 w.hex 互证）+ DDR 镜像 ----"
if ! "$PY" - "$JD" "$idx" "$blob" "$LID" "$CIN" "$COUT" "$NCI" "$NCO" "$NW" "$MAXW" \
              "$MEMSZ" "$WBASE" "$DST" "$LEN" "$SEGFLIP" "$work" <<'PYEOF'; then
import sys
(JD, idx_p, blob_p, lid, cin, cout, nci, nco, nw, maxw, memsz, wbase, dst, ln, segflip, work) = (
    sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4]), int(sys.argv[5]), int(sys.argv[6]),
    int(sys.argv[7]), int(sys.argv[8]), int(sys.argv[9]), int(sys.argv[10]), int(sys.argv[11]),
    int(sys.argv[12]), int(sys.argv[13]), int(sys.argv[14]), int(sys.argv[15]), sys.argv[16])
import json
d = json.load(open(idx_p, encoding="utf-8")); blob = open(blob_p, "rb").read()
u = [x for x in d["units"] if x["idx"] == lid][0]
off, nb = int(u["weight"]["offset"]), int(u["weight"]["nbytes"])
seg = blob[off:off + nb]

def dest(co, ci, tap):
    return ((co // 8) * nci + (ci // 8)) * 576 + (co % 8) * 72 + (ci % 8) * 9 + tap

exp = bytearray(maxw)
for co in range(cout):
    for ci in range(cin):
        for tap in range(9):
            exp[dest(co, ci, tap)] = seg[(co * cin + ci) * 9 + tap]
open(work + "/w_exp.hex", "w").write("".join("%02x\n" % b for b in exp))
open(work + "/w_zero.hex", "w").write("".join("%02x\n" % 0 for _ in range(nw)))

ref_w = [int(l.strip(), 16) for l in open(JD + "/w.hex") if l.strip()]
bad = sum(1 for i in range(nw) if i >= len(ref_w) or ref_w[i] != exp[i]) + max(0, len(ref_w) - nw)
print("XCHECK 映射(本闸门) vs 参考 wide_exec_ref.w.hex：MISMATCH=%d/%d" % (bad, nw))

pre = [((i % 251) * 131 + 7) % 251 for i in range(memsz)]
for i, b in enumerate(seg):
    pre[wbase + i] = b
gold = [int(l.strip(), 16) for l in open(JD + "/gold.hex") if l.strip()]
dif = sum(1 for j in range(ln) if pre[dst + j] != gold[j])
open(work + "/mem.hex", "w").write("".join("%02x\n" % b for b in pre))
flip = list(pre); old = flip[wbase + segflip]; flip[wbase + segflip] = old ^ 1
open(work + "/mem_flip.hex", "w").write("".join("%02x\n" % b for b in flip))
co0 = segflip // (cin * 9); r = segflip % (cin * 9); ci0 = r // 9; tap0 = r % 9
print("VEC 段@%d len=%d  N1 翻段内 %d（原值=%d -> %d）=> co=%d ci=%d tap=%d => wRam[%d]"
      % (wbase, nb, segflip, old, old ^ 1, co0, ci0, tap0, dest(co0, ci0, tap0)))
print("VEC DST 预载 vs 黄金 差 %d/%d（'不写'抓得住）" % (dif, ln))
print("VEC 期望镜像段内非 0 字节=%d（分辨度）" % sum(1 for i in range(nw) if exp[i] != 0))
sys.exit(1 if (bad or dif < int(ln * 0.9) or sum(1 for i in range(nw) if exp[i] != 0) == 0) else 0)
PYEOF
  FAIL "JUDGE-RED(3): 向量生成/互证失败" 3
fi

# ---------------------------------------------------------------------------
# [3] 编译：正网表 + 两个突变体（+32 多读 / -32 少读）
# ---------------------------------------------------------------------------
echo "---- [3] iverilog 编译 + 突变体 ----"
if ! "$IVERILOG" -g2012 -o "$work/wide.vvp" "$tb" "$memv" "$nl" > "$work/iv.log" 2>&1; then
  sed -n '1,30p' "$work/iv.log"; FAIL "JUDGE-RED(1): iverilog 编译失败" 1
fi
echo "    正网表编译 OK"
if ! "$PY" - "$nl" "$work/mut_plus.v" "$work/mut_minus.v" <<'PYEOF'; then
import sys
src, outp, outm = sys.argv[1], sys.argv[2], sys.argv[3]
txt = open(src, encoding="utf-8").read()
def sub(t, old, new):
    n = t.count(old)
    if n != 1:
        print("MUTATE-ANCHOR-BAD: '%s' 命中 %d 次（要求恰好 1）" % (old, n)); sys.exit(2)
    print("MUTATE OK: %s  ->  %s" % (old, new))
    return t.replace(old, new)
open(outp, "w", encoding="utf-8").write(sub(txt, "mLen <= wgtLenR;", "mLen <= wgtLenR + 32'd32;"))
t2 = sub(txt, "mLen <= wgtLenR;", "mLen <= wgtLenR - 32'd32;")
t2 = sub(t2, "(wlCnt == wgtWrLenR)", "(wlCnt == (wgtWrLenR - 32'd32))")
open(outm, "w", encoding="utf-8").write(t2)
PYEOF
  FAIL "NEGCTL-FAIL: 突变锚不唯一（闸门自身不可信）" 2
fi
for m in mut_plus mut_minus; do
  if ! "$IVERILOG" -g2012 -o "$work/$m.vvp" "$tb" "$memv" "$work/$m.v" > "$work/iv_$m.log" 2>&1; then
    sed -n '1,20p' "$work/iv_$m.log"; FAIL "JUDGE-RED(2): 突变体 $m 编译失败" 2
  fi
  echo "    突变体 $m 编译 OK"
done

# ---------------------------------------------------------------------------
# 运行 + 对账
# ---------------------------------------------------------------------------
PWD_ABS="$(pwd)"
runw() {  # runw <vvp> <memfile> <log> <wramdump> <dumpfile> <wexp> [cin nci ncol lid grp]
  local v="$1" mf="$2" lg="$3" wd="$4" df="$5" wx="$6"
  local ci="${7:-$CIN}" ni="${8:-$NCI}" nc="${9:-$NCOL}" li="${10:-$LID}" gg="${11:-1}"
  # 注：`$work`/`$mf`/… 都是**绝对**路径（MSYS 形式，与既有闸门同一口径：vvp 在 `cd $work` 之后按
  #     这些字符串开文件）；`$JD/...` 是 y1 下的相对路径 ⇒ 用 `$PWD_ABS/$JD/...` 拼成 Windows 绝对路径。
  ( cd "$work" && "$VVP" "$v" \
      "+XFILE=$PWD_ABS/$JD/x.hex" "+WFILE=$work/w_zero.hex" "+BFILE=$PWD_ABS/$JD/b.hex" \
      "+MEMFILE=$mf" "+DUMPFILE=$df" +dump "+DUMPW=$wd" \
      "+CIN=$ci" "+COUT=$COUT" "+GROUP=$gg" "+H=$HH" "+W=$WW" "+TYPE=1" "+FLAGS=1" \
      "+SRC=$SRC" "+DST=$DST" "+INB=$(( ci * HH * WW ))" "+QSHIFT=6" "+LID=$li" \
      "+M=$MV" "+ZPAD=$ZP" "+ZY=$ZY" "+NCOL=$nc" "+NCI=$ni" "+NCO=$NCO" \
      "+WBASE=$WBASE" "+WEXP=$wx" ) > "$lg" 2>&1
  return 0
}

# wramcmp <wramdump> <exp> <NW> <MAXW> <CIN> <NCI> <blob_off>  -> 逐字节对账 + 定位
wramcmp() {
  "$PY" - "$1" "$2" "$3" "$4" "$5" "$6" "$7" <<'PYEOF'
import sys
dump, expf, nw, maxw, cin, nci, off = (sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4]),
                                       int(sys.argv[5]), int(sys.argv[6]), int(sys.argv[7]))
def load(p):
    try:
        return [int(l.strip(), 16) for l in open(p, encoding="utf-8", errors="replace") if l.strip()]
    except OSError:
        return []
d = load(dump); e = load(expf)
def at(a, i): return a[i] if 0 <= i < len(a) else -1
bad = sum(1 for i in range(nw) if at(d, i) != at(e, i))
first = next((i for i in range(nw) if at(d, i) != at(e, i)), -1)
print("WRAM_BAD=%d" % bad)
if first >= 0:
    p = first // 576; cl = (first % 576) // 72; cil = (first % 72) // 9; tap = first % 9
    cob, cib = p // nci, p % nci
    co, ci = cob * 8 + cl, cib * 8 + cil
    # 定位（**全部写成 KV**，闸门用 `grep '^NAME='` + eval 取值 ⇒ 单行里不出现空格）
    print("WRAM_FIRST_ADDR=%d" % first)
    print("WRAM_FIRST_PASS=%d" % p)
    print("WRAM_FIRST_CL=%d" % cl)
    print("WRAM_FIRST_CIL=%d" % cil)
    print("WRAM_FIRST_TAP=%d" % tap)
    print("WRAM_FIRST_CO=%d" % co)
    print("WRAM_FIRST_CI=%d" % ci)
    print("WRAM_FIRST_BLOB_OFF=%d" % (off + (co * cin + ci) * 9 + tap))
    print("WRAM_FIRST_DUT=%02x" % (at(d, first) & 0xFF))
    print("WRAM_FIRST_EXP=%02x" % (at(e, first) & 0xFF))
print("WRAM_OUTSIDE_NONZERO=%d" % sum(1 for i in range(nw, maxw) if at(d, i) != 0))
print("WRAM_EXP_NONZERO=%d" % sum(1 for i in range(nw) if at(e, i) != 0))
print("WRAM_TAIL32_BAD=%d" % sum(1 for i in range(nw - 32, nw) if at(d, i) != at(e, i)))
PYEOF
}

# dstcmp <dump> <gold> <DST> <LEN> <pre>  -> 输出区逐字节 + 邻居
dstcmp() {
  "$PY" - "$1" "$2" "$3" "$4" "$5" <<'PYEOF'
import sys
dump, gold, dst, ln, pre = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), sys.argv[5]
def load(p):
    out = []
    for l in open(p, encoding="utf-8", errors="replace"):
        s = l.strip()
        if not s: continue
        try: out.append(int(s, 16))
        except ValueError: out.append(-1)
    return out
d = load(dump); g = load(gold); p = load(pre)
k = min(ln, len(g), max(0, len(d) - dst))
mis = sum(1 for i in range(k) if d[dst + i] != g[i]) + max(0, ln - k)
nb = sum(1 for i in range(32) if d[dst - 32 + i] != p[dst - 32 + i]) if dst >= 32 else 0
print("MISMATCH=%d" % mis); print("DST_NEIGHBOR32_BAD=%d" % nb)
PYEOF
}

# ---- [4] 正对照 ----
echo "---- [4] W1 正对照（权重只经 DMA 装载 -> 宽层多趟 -> 输出 vs 黄金）----"
runw "$work/wide.vvp" "$work/mem.hex" "$work/w1.log" "$work/w1.wram" "$work/w1.dump" "$NW"
grep -E '^(TB WIDE|DONE_SEEN|WRAM_DUMPED|RESULT)' "$work/w1.log" | sed 's/^/    /'
MEMRD_POS="$(sed -n 's/^MEM rd=\([0-9]*\).*/\1/p' "$work/w1.log" | head -1)"
WB_POS="$(sed -n 's/.*WGT_BYTES=\([0-9]*\).*/\1/p' "$work/w1.log" | head -1)"
grepx() { grep -q "^RESULT: PASS" "$1"; }
if ! grepx "$work/w1.log"; then echo "JUDGE-RED(1): 正对照装置未 PASS"; tail -6 "$work/w1.log"; TOTAL_BAD=$((TOTAL_BAD+1)); fi
[ "${WB_POS:-x}" = "$NW" ] || { echo "JUDGE-RED(1): 判据②(设备侧) WGT_BYTES=${WB_POS:-?} != $NW"; TOTAL_BAD=$((TOTAL_BAD+1)); }
[ "${MEMRD_POS:-x}" = "$NW" ] || { echo "JUDGE-RED(1): 判据②(内存模型) MEM rd=${MEMRD_POS:-?} != $NW"; TOTAL_BAD=$((TOTAL_BAD+1)); }
echo "    WGT_BYTES=$WB_POS  MEM rd=$MEMRD_POS  （宽层无激活 RD ⇒ 读的只有权重段）"
eval "$(dstcmp "$work/w1.dump" "$JD/gold.hex" "$DST" "$LEN" "$work/mem.hex" | sed 's/^/P_/')"
[ "${P_MISMATCH:-x}" = "0" ] || { echo "JUDGE-RED(1): 正对照输出 != 黄金（MISMATCH=${P_MISMATCH:-?}）"; TOTAL_BAD=$((TOTAL_BAD+1)); }
[ "${P_DST_NEIGHBOR32_BAD:-x}" = "0" ] || { echo "JUDGE-RED(1): 输出邻居被改（${P_DST_NEIGHBOR32_BAD}）"; TOTAL_BAD=$((TOTAL_BAD+1)); }
echo "    数值：DST 区 vs 黄金 MISMATCH=${P_MISMATCH:-?} 邻居32B_BAD=${P_DST_NEIGHBOR32_BAD:-?}"
wramcmp "$work/w1.wram" "$work/w_exp.hex" "$NW" "$MAXW" "$CIN" "$NCI" "$SEGOFF" > "$work/w1.wram.judge"
sed 's/^/    /' "$work/w1.wram.judge"
eval "$(grep -E '^[A-Z0-9_]+=' "$work/w1.wram.judge" | sed 's/^/W1_/')"
[ "${W1_WRAM_BAD:-x}" = "0" ] || { echo "JUDGE-RED(1): 判据① wRam 逐字节不符（${W1_WRAM_BAD}）"; TOTAL_BAD=$((TOTAL_BAD+1)); }
[ "${W1_WRAM_OUTSIDE_NONZERO:-x}" = "0" ] || { echo "JUDGE-RED(1): 段外写脏（${W1_WRAM_OUTSIDE_NONZERO} 字节）"; TOTAL_BAD=$((TOTAL_BAD+1)); }

# ---- [4b] 能力边界：★★ C4b-B1c 起边界**搬家** ----
#   `C_IN%8!=0`（C_IN=3 的宽层）**不再是**边界 —— 装载器现在把"跳过通道"按零填补装进来
#   （见新闸门 `run_wgtdma_geom_ab.sh` 的判据①/④）。真正的**装载器边界**收窄为：
#   `GROUP ∉ {1, C_in==C_out}`（映射式 `ci = gco*cig + ciLocal` 只在上面两种几何下退化成乘 0/乘 1）。
echo "---- [4b] W2 能力边界（GROUP=3 的宽层 ⇒ 响亮 err + 零设备搬运）----"
runw "$work/wide.vvp" "$work/mem.hex" "$work/w2.log" "$work/w2.wram" "$work/w2.dump" 0 3 1 512 0 3
grep -E '^(DONE_SEEN|RESULT)' "$work/w2.log" | sed 's/^/    /'
eval "$(sed -n 's/^DONE_SEEN=\([0-9]*\) ERR_SEEN=\([0-9]*\).*/W2_DONE=\1 W2_ERR=\2/p' "$work/w2.log" | head -1)"
W2_RD="$(sed -n 's/^MEM rd=\([0-9]*\).*/\1/p' "$work/w2.log" | head -1)"
W2_WB="$(sed -n 's/.*WGT_BYTES=\([0-9]*\).*/\1/p' "$work/w2.log" | head -1)"
W2_NZ="$(sed -n 's/^W2_WRAM_NONZERO=//p' "$work/w2.wram.nz" 2>/dev/null)"
"$PY" - "$work/w2.wram" > "$work/w2.wram.nz" <<'PYEOF'
import sys
try:
    d = [int(l.strip(), 16) for l in open(sys.argv[1], encoding="utf-8", errors="replace") if l.strip()]
except OSError:
    d = []
print("W2_WRAM_NONZERO=%d" % sum(1 for v in d if v != 0))
PYEOF
W2_NZ="$(sed -n 's/^W2_WRAM_NONZERO=//p' "$work/w2.wram.nz")"
echo "    DONE=$W2_DONE ERR=$W2_ERR MEM rd=${W2_RD:-?} WGT_BYTES=${W2_WB:-?} wRam 非0=${W2_NZ:-?}"
[ "${W2_DONE:-x}" = "0" ] && [ "${W2_ERR:-x}" = "1" ] || { echo "JUDGE-RED(1): 能力边界未响亮 err"; TOTAL_BAD=$((TOTAL_BAD+1)); }
[ "${W2_RD:-x}" = "0" ] && [ "${W2_WB:-x}" = "0" ] && [ "${W2_NZ:-x}" = "0" ] || { echo "JUDGE-RED(1): 能力边界仍有搬运（rd=${W2_RD:-?} wb=${W2_WB:-?} wRam非0=${W2_NZ:-?}）"; TOTAL_BAD=$((TOTAL_BAD+1)); }

# ---- [5] 负对照 N1：DDR 镜像翻一个字节 ⇒ 判据① 红且定位 ----
echo "---- [5] N1 负对照（权重段内第 $SEGFLIP 字节翻位）----"
runw "$work/wide.vvp" "$work/mem_flip.hex" "$work/n1.log" "$work/n1.wram" "$work/n1.dump" "$NW"
wramcmp "$work/n1.wram" "$work/w_exp.hex" "$NW" "$MAXW" "$CIN" "$NCI" "$SEGOFF" > "$work/n1.wram.judge"
sed 's/^/    /' "$work/n1.wram.judge"
eval "$(grep -E '^[A-Z0-9_]+=' "$work/n1.wram.judge" | sed 's/^/N1_/')"
N1_MEMRD="$(sed -n 's/^MEM rd=\([0-9]*\).*/\1/p' "$work/n1.log" | head -1)"
if [ "${N1_WRAM_BAD:-0}" = "0" ]; then
  echo "NEGCTL-FAIL: N1 翻字节后 wRam 竟逐字节相等（判据① 没牙）"; NEG_NOFIRE=$((NEG_NOFIRE+1))
else
  echo "    N1 发火：wRam[${N1_WRAM_FIRST_ADDR}]（趟 ${N1_WRAM_FIRST_PASS} cl=${N1_WRAM_FIRST_CL} cil=${N1_WRAM_FIRST_CIL} tap=${N1_WRAM_FIRST_TAP} => co=${N1_WRAM_FIRST_CO} ci=${N1_WRAM_FIRST_CI}）= blob 偏移 ${N1_WRAM_FIRST_BLOB_OFF}（单元 Conv_6 / idx 4：blob 2880 + 段内 ${SEGFLIP}）dut=${N1_WRAM_FIRST_DUT} exp=${N1_WRAM_FIRST_EXP}"
  echo "    N1 读字节数仍 = ${N1_MEMRD}（判据② 不红 ⇒ 位置/字节数两条判据各抓各的）"
fi

# ---- [6] 负对照 N2：网表突变 +32 ⇒ 多读 ----
echo "---- [6] N2 负对照（网表突变：装载 RD 段长 +32 B ⇒ 多读）----"
runw "$work/mut_plus.vvp" "$work/mem.hex" "$work/n2.log" "$work/n2.wram" "$work/n2.dump" "$(( NW + 32 ))"
grep -E '^(DONE_SEEN|RESULT)' "$work/n2.log" | sed 's/^/    /'
N2_MEMRD="$(sed -n 's/^MEM rd=\([0-9]*\).*/\1/p' "$work/n2.log" | head -1)"
N2_WB="$(sed -n 's/.*WGT_BYTES=\([0-9]*\).*/\1/p' "$work/n2.log" | head -1)"
eval "$(wramcmp "$work/n2.wram" "$work/w_exp.hex" "$NW" "$MAXW" "$CIN" "$NCI" "$SEGOFF" | grep -E '^[A-Z0-9_]+=' | sed 's/^/N2_/')"
if [ "${N2_MEMRD:-x}" = "$(( NW + 32 ))" ] && [ "${N2_WB:-x}" = "$NW" ] && [ "${N2_WRAM_BAD:-x}" = "0" ]; then
  echo "    N2 发火：MEM rd=${N2_MEMRD} = 段长+32（多读）而 WGT_BYTES=${N2_WB}、wRam 逐字节仍相等 ⇒ 判据② 抓的是字节数"
else
  echo "NEGCTL-FAIL: N2 未按预期发火（MEM rd=${N2_MEMRD:-?} WGT_BYTES=${N2_WB:-?} WRAM_BAD=${N2_WRAM_BAD:-?}）"
  NEG_NOFIRE=$((NEG_NOFIRE+1))
fi

# ---- [7] 负对照 N3：网表突变 -32（收尾同步改小）⇒ 少读 + 判据① 一起发火 ----
echo "---- [7] N3 负对照（网表突变：段长 -32 B + 收尾同步改小 ⇒ 少读）----"
runw "$work/mut_minus.vvp" "$work/mem.hex" "$work/n3.log" "$work/n3.wram" "$work/n3.dump" "$(( NW - 32 ))"
grep -E '^(DONE_SEEN|RESULT)' "$work/n3.log" | sed 's/^/    /'
N3_MEMRD="$(sed -n 's/^MEM rd=\([0-9]*\).*/\1/p' "$work/n3.log" | head -1)"
N3_WB="$(sed -n 's/.*WGT_BYTES=\([0-9]*\).*/\1/p' "$work/n3.log" | head -1)"
wramcmp "$work/n3.wram" "$work/w_exp.hex" "$NW" "$MAXW" "$CIN" "$NCI" "$SEGOFF" > "$work/n3.wram.judge"
sed 's/^/    /' "$work/n3.wram.judge"
eval "$(grep -E '^[A-Z0-9_]+=' "$work/n3.wram.judge" | sed 's/^/N3_/')"
if [ "${N3_MEMRD:-x}" = "$(( NW - 32 ))" ] && [ "${N3_WB:-x}" = "$(( NW - 32 ))" ] && { [ "${N3_WRAM_BAD:-0}" -gt 0 ] 2>/dev/null; }; then
  echo "    N3 发火：MEM rd=${N3_MEMRD}=WGT_BYTES=${N3_WB}=段长-32（少读）且段尾 32 B 未装（不符 ${N3_WRAM_BAD} 字节 / 段内期望非 0 共 ${N3_WRAM_EXP_NONZERO:-?}）"
else
  echo "NEGCTL-FAIL: N3 未按预期发火（MEM rd=${N3_MEMRD:-?} WGT_BYTES=${N3_WB:-?} WRAM_BAD=${N3_WRAM_BAD:-?}）"
  NEG_NOFIRE=$((NEG_NOFIRE+1))
fi

# ---- [8] ★ B0 2026-10-12：真表单元装载扫描（真 index 的 offset/nbytes）----
#   目的：证明"**32 B 对齐后**，真表的多个单元（各自真 offset）不再触发 DdrMaster 的 `src%32/len%32` err，
#         且装载逐字节相等、装载字节数 == 该单元真 nbytes"。取 6 个真 unit（含 offset 最大的 Conv_19）。
#   ★ 这里**不判数值输出**（本轮只证"装载路径"；数值正对照见 [4]，用 Conv_6 的本几何黄金）。
echo "---- [8] 真表单元装载扫描（真 index 的 offset/nbytes）----"
SWEEP="1 4 6 8 10 13"          # Conv_2 / Conv_6 / Conv_9 / Conv_12 / Conv_15 / Conv_19
BLOB_BASE=$WBASE               # 整份对齐 blob 落在 DDR 的起点（= 现 WBASE；32 B 对齐）
SWEEP_BAD=0
if ! "$PY" - "$work" "gen" "$BLOB_BASE" "$MEMSZ" "$SWEEP" <<'PYEOF'; then
import sys, json
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass
work, gen, blob_base, memsz = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
lids = [int(x) for x in sys.argv[5].split()]
idx = json.load(open(gen + "/wgt_index.json", encoding="utf-8"))
blob = open(gen + "/wgt_blob.bin", "rb").read()
assert blob_base + len(blob) <= memsz, "blob 越出内存模型"
# DDR 镜像：整份对齐 blob 落在 blob_base（逐单元装到各自的真 offset）
def pat(i):
    return ((i % 251) * 131 + 7) % 251
mem = bytearray(pat(i) for i in range(memsz))
mem[blob_base:blob_base + len(blob)] = blob
rows = []
flip_lid, flip_blob_off = None, None
for lid in lids:
    u = [x for x in idx["units"] if x["idx"] == lid][0]
    w = u["weight"]; o = u["own"]
    off, nb, ab = int(w["offset"]), int(w["nbytes"]), int(w["aligned_bytes"])
    cin, cout, grp = int(o["C_IN"]), int(o["C_OUT"]), int(o["GROUP"])
    assert cin % 8 == 0 and cout % 8 == 0 and grp == 1 and u["type_code"] != 3, "lid %d 不满足宽通路几何" % lid
    assert off % 32 == 0 and ab % 32 == 0, "lid %d 段未 32 B 对齐" % lid
    nci, nco = (cin + 7) // 8, (cout + 7) // 8
    nw = nci * nco * 576
    assert nw == nb, "lid %d：nCi*nCo*576=%d != nbytes=%d" % (lid, nw, nb)
    seg = blob[off:off + nb]
    exp = bytearray(nw)
    for co in range(cout):
        for ci in range(cin):
            for tap in range(9):
                d = ((co // 8) * nci + (ci // 8)) * 576 + (co % 8) * 72 + (ci % 8) * 9 + tap
                exp[d] = seg[(co * cin + ci) * 9 + tap]
    open("%s/w_exp_%d.hex" % (work, lid), "w").write("".join("%02x\n" % b for b in exp))
    open("%s/w_zero_%d.hex" % (work, lid), "w").write("".join("%02x\n" % 0 for _ in range(nw)))
    assert sum(1 for b in exp if b) > 0, "lid %d 期望镜像全 0（没分辨度）" % lid
    rows.append((lid, u["name"], cin, cout, nci, nco, off, nb, nw))
    if lid == 13:
        flip_lid, flip_blob_off = lid, off + 7
print("SWEEP_PREP OK：%d 个真单元（%s）；blob@%d；mem_sweep.hex 已建"
      % (len(rows), ",".join(r[1] for r in rows), blob_base))
for (lid, nm, cin, cout, nci, nco, off, nb, nw) in rows:
    print("SWEEP_UNIT lid=%d %-10s C_IN=%d C_OUT=%d n_ci=%d n_co=%d off=%d(%%32=%d) nbytes=%d(%d B 对齐) nw=%d"
          % (lid, nm, cin, cout, nci, nco, off, off % 32, nb, ((nb + 31) & ~31), nw))
# 负对照镜像：把 lid13 段内第 7 字节翻 1 位（⇒ 期望镜像必然对不上，且能定位回 blob 绝对偏移）
if flip_lid is not None:
    memf = bytearray(mem)
    mem_off = blob_base + flip_blob_off          # ★ 翻的是 **DDR 镜像里该 blob 字节**的位置（不是镜像下标）
    old = memf[mem_off]; memf[mem_off] = old ^ 0x01
    open("%s/mem_sweep_flip.hex" % work, "w").write("".join("%02x\n" % b for b in memf))
    print("SWEEP_FLIP lid=%d blob_off=%d mem_off=%d 原值=%d -> %d（负对照：判据① 必红且定位回 blob 偏移）"
          % (flip_lid, flip_blob_off, mem_off, old, old ^ 1))
open("%s/mem_sweep.hex" % work, "w").write("".join("%02x\n" % b for b in mem))
with open("%s/sweep.txt" % work, "w", encoding="ascii", newline="\n") as f:
    for (lid, nm, cin, cout, nci, nco, off, nb, nw) in rows:
        f.write("%d %s %d %d %d %d %d %d\n" % (lid, nm, cin, cout, nci, nco, off, nb))
PYEOF
  echo "JUDGE-RED(3): 扫描向量生成失败"; FAIL "RESULT: FAIL" 3
fi
PWD_ABS="$(pwd)"
while read -r lid nm ci co ni no off nb; do
  "$PY" "$ref" --lid "$lid" --H "$HH" --W "$WW" --outdir "$outdir" > "$work/ref_s$lid.log" 2>&1 \
    || { echo "JUDGE-RED(3): 参考供料 lid=$lid 失败"; sed -n '1,6p' "$work/ref_s$lid.log"; SWEEP_BAD=$((SWEEP_BAD+1)); continue; }
  SWJD="$(ls -d "$outdir"/lid"$lid"_* 2>/dev/null | head -1)"
  [ "$lid" = "13" ] && FLIP_JD="$SWJD"
  SM="$(sed -n 's/^M=//p' "$SWJD/job.txt" | head -1)"
  SZP="$(sed -n 's/^ZPAD=//p' "$SWJD/job.txt" | head -1)"
  SZY="$(sed -n 's/^ZY=//p' "$SWJD/job.txt" | head -1)"
  ncol=$(( ni * no * HH * WW ))
  ( cd "$work" && "$VVP" "$work/wide.vvp" \
      "+XFILE=$PWD_ABS/$SWJD/x.hex" "+WFILE=$work/w_zero_$lid.hex" "+BFILE=$PWD_ABS/$SWJD/b.hex" \
      "+MEMFILE=$work/mem_sweep.hex" "+DUMPFILE=$work/s$lid.dump" +dump "+DUMPW=$work/s$lid.wram" \
      "+CIN=$ci" "+COUT=$co" "+GROUP=1" "+H=$HH" "+W=$WW" "+TYPE=1" "+FLAGS=1" \
      "+SRC=$SRC" "+DST=$DST" "+INB=$(( ci * HH * WW ))" "+QSHIFT=6" "+LID=$lid" \
      "+M=$SM" "+ZPAD=$SZP" "+ZY=$SZY" "+NCOL=$ncol" "+NCI=$ni" "+NCO=$no" \
      "+WBASE=$(( WBASE + off ))" "+WEXP=$nb" ) > "$work/s$lid.log" 2>&1
  SDONE="$(sed -n 's/^DONE_SEEN=\([0-9]*\).*/\1/p' "$work/s$lid.log" | head -1)"
  SERR="$(sed -n 's/.*ERR_SEEN=\([0-9]*\).*/\1/p' "$work/s$lid.log" | head -1)"
  SWB="$(sed -n 's/.*WGT_BYTES=\([0-9]*\).*/\1/p' "$work/s$lid.log" | head -1)"
  SRD="$(sed -n 's/^MEM rd=\([0-9]*\).*/\1/p' "$work/s$lid.log" | head -1)"
  eval "$(wramcmp "$work/s$lid.wram" "$work/w_exp_$lid.hex" "$nb" "$MAXW" "$ci" "$ni" "$off" | grep -E '^[A-Z0-9_]+=' | sed 's/^/SWR_/')"
  row="ok"
  if [ "${SDONE:-x}" != "1" ] || [ "${SERR:-x}" != "0" ]; then row="ERR/DONE(=$SDONE/$SERR)"; SWEEP_BAD=$((SWEEP_BAD+1)); fi
  if [ "${SWB:-x}" != "$nb" ] || [ "${SRD:-x}" != "$nb" ]; then row="$row 字节数(WB=$SWB RD=$SRD != $nb)"; SWEEP_BAD=$((SWEEP_BAD+1)); fi
  if [ "${SWR_WRAM_BAD:-x}" != "0" ]; then row="$row 逐字节(WRAM_BAD=${SWR_WRAM_BAD:-?})"; SWEEP_BAD=$((SWEEP_BAD+1)); fi
  printf '   lid=%-2s %-10s C=%2s->%-2s off=%-6s nbytes=%-5s | DONE=%s ERR=%s WGT_BYTES=%s MEM rd=%s WRAM_BAD=%s | %s\n' \
    "$lid" "$nm" "$ci" "$co" "$off" "$nb" "${SDONE:-?}" "${SERR:-?}" "${SWB:-?}" "${SRD:-?}" "${SWR_WRAM_BAD:-?}" "$row"
done < "$work/sweep.txt"
# 负对照（定位）：lid13 段内第 7 字节翻位 ⇒ 判据① 必红，且定位回 blob 绝对偏移 off13+7
if [ -f "$work/mem_sweep_flip.hex" ] && [ -n "${FLIP_JD:-}" ]; then
  flip_off="$(awk '$1==13{print $7+7}' "$work/sweep.txt")"
  ( cd "$work" && "$VVP" "$work/wide.vvp" \
      "+XFILE=$PWD_ABS/$FLIP_JD/x.hex" "+WFILE=$work/w_zero_13.hex" "+BFILE=$PWD_ABS/$FLIP_JD/b.hex" \
      "+MEMFILE=$work/mem_sweep_flip.hex" "+DUMPFILE=$work/sflip.dump" +dump "+DUMPW=$work/sflip.wram" \
      "+CIN=64" "+COUT=64" "+GROUP=1" "+H=$HH" "+W=$WW" "+TYPE=1" "+FLAGS=1" \
      "+SRC=$SRC" "+DST=$DST" "+INB=$(( 64 * HH * WW ))" "+QSHIFT=6" "+LID=13" \
      "+M=$(sed -n 's/^M=//p' "$PWD_ABS/$FLIP_JD/job.txt" | head -1)" \
      "+ZPAD=$(sed -n 's/^ZPAD=//p' "$PWD_ABS/$FLIP_JD/job.txt" | head -1)" \
      "+ZY=$(sed -n 's/^ZY=//p' "$PWD_ABS/$FLIP_JD/job.txt" | head -1)" \
      "+NCOL=16384" "+NCI=8" "+NCO=8" "+WBASE=$(( WBASE + flip_off - 7 ))" "+WEXP=36864" ) > "$work/sflip.log" 2>&1
  eval "$(wramcmp "$work/sflip.wram" "$work/w_exp_13.hex" "36864" "$MAXW" "64" "8" "$(( flip_off - 7 ))" | grep -E '^[A-Z0-9_]+=' | sed 's/^/SF_/')"
  if [ "${SF_WRAM_BAD:-0}" -gt 0 ] 2>/dev/null && [ "${SF_WRAM_FIRST_BLOB_OFF:-x}" = "$flip_off" ]; then
    echo "   SWEEP-N1 发火：翻 blob 偏移 $flip_off（lid13 段内 +7）⇒ WRAM_BAD=${SF_WRAM_BAD}，定位 WRAM_FIRST_BLOB_OFF=${SF_WRAM_FIRST_BLOB_OFF}（一致）"
  else
    echo "NEGCTL-FAIL: SWEEP-N1（真单元段内翻字节）没红或定位错（BAD=${SF_WRAM_BAD:-?} @ ${SF_WRAM_FIRST_BLOB_OFF:-?}）"; NEG_NOFIRE=$((NEG_NOFIRE+1))
  fi
fi
if [ "$SWEEP_BAD" -eq 0 ]; then
  echo "   ★ 真表单元装载扫描：6/6 单元 DONE + 零 err + 装载字节数 == 真 nbytes + wRam 逐字节相等（对齐后无 DdrMaster err）"
fi
TOTAL_BAD=$(( TOTAL_BAD + SWEEP_BAD ))
echo "=========================================================================="
echo "判据① 逐单元逐字节 = $([ "${W1_WRAM_BAD:-x}" = 0 ] && echo OK || echo RED)（wRam 段内 == blob 段的趟序重排；段外未被写；镜像另与参考独立互证）"
echo "判据② 装载字节数   = $([ "${WB_POS:-x}" = "$NW" ] && [ "${MEMRD_POS:-x}" = "$NW" ] && echo "OK（设备侧 ${WB_POS} == 内存模型 ${MEMRD_POS} == index.bytes $NW）" || echo RED)"
echo "判据③ 负对照       = N1 翻字节+定位 / N2 多读 / N3 少读（三条都要发火）"
echo "数值正对照         = DST 区逐字节 == 黄金（权重只经 DMA 进来）MISMATCH=${P_MISMATCH:-?}"
echo "能力边界           = GROUP∉{1,C_in=C_out} 的宽层：ERR_SEEN=${W2_ERR:-?} + wRam 零搬运（rd=${W2_RD:-?}）"
echo "真表单元扫描 [8]   = $([ "$SWEEP_BAD" -eq 0 ] && echo "6/6 真单元（真 offset/nbytes）装载无 err、逐字节相等" || echo "RED（$SWEEP_BAD 项）")"
if [ "$NEG_NOFIRE" -ne 0 ]; then echo "NEGCTL-FAIL: $NEG_NOFIRE 条负对照没发火 ⇒ 闸门自身不可信"; echo "RESULT: FAIL"; exit 2; fi
if [ "$TOTAL_BAD" -ne 0 ]; then echo "JUDGE-RED: $TOTAL_BAD 条判据未过"; echo "RESULT: FAIL"; exit 1; fi
echo "RESULT: PASS"
exit 0
