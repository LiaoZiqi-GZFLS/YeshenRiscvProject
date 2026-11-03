#!/usr/bin/env bash
# run_wgtdma_ab.sh —— ★ C4b-B1「**权重段从 DDR 批量装载**（DMA 主路径）」闸门
#   （`rtl/UnitExec.scala` 的 WGTLD/WGTRUN 装载器 + `rtl/LayerSched.scala` 的 `WGT_BLOB_BASE` / 表序前缀和）
#
# 目标（计划 C4b Task B1 Step 2）：**每个单元的权重段由 NPU 自己的 DdrMaster 从 DDR 读进该切片的
#   `WeightStore`**，起点 = `WGT_BLOB_BASE` + 表序前缀和 Σ_{j<i} N_j；信箱（区域 0）退居**覆盖/调试**口。
#
# 三条判据（**都要能发火**）：
#   ① **逐单元逐字节**：帧跑完后把**每片** `WeightStore` 的 576 个条目全部读回，与"按 blob 布局算术
#      （`N = C_out*(C_in/GROUP)*9`、段起点 = 前缀和）算出来的那一段"逐字节对账（`STORE_MISMATCH<i> == 0`）。
#      作业 J1 的期望是 **A++B++C++5 段全 0**（片 0/1/2 = 链的三片；片 3..7 一字节都不许被写）。
#   ② **装载字节数 == blob 大小**：
#      · 设备侧自报 `LayerSched.wgt_bytes`（帧内 Σ 各单元装载字节）**恰好** == 期望；
#      · 内存模型 `MEM rd` 与"同一张表、DMA 开/关两跑"的**差值** == 权重字节数（第三方独立计数）；
#      · **大作业 J6**：把真 blob（★ B0 2026-10-12 **32 B 对齐布局**：`gen/wgt_blob.bin` = 404064 B）
#        按 8 片一链、共 701 个单元（576 B/单元）逐段灌完 ⇒ `wgt_bytes == 403776`（= 701*576 = **≤ blob 的
#        最大 576 倍数**；尾 **288 B = 对齐补位**，不参与窄通路）**恰好**（多/少都要红）+ 总 MEM rd 三方对账。
#   ③ **负对照（必须发火，且要能定位）**：
#      · J5：blob 镜像里改**一个字节** ⇒ 红，且报 `STORE_FIRST slice=0 addr=<该偏移>`（闸门把它翻成
#        "哪个单元、blob 里哪个偏移"）；
#      · J7：**网表突变**（权重 RD 段长 +32 B）⇒ **多读**：`MEM rd` 恰好 +32，而 store 仍逐字节相等
#        （证明判据② 抓的是**字节数**本身，不是"数据对不对"）；
#      · J9：**网表突变**（段长 −32 B，装载器收尾条件同步改小）⇒ **少读**：`MEM rd` −32、
#        `wgt_bytes` −32，且 store 尾部 32 字节为 0 ⇒ 判据① 与 ② **一起**发火。
#
# 退出码（与 Y1 既有闸门一致）：
#   0 = 全过（① 逐字节 0 差 + ② 三处独立计数相符（含大作业 403,776 = 701*576）+ ③ 负对照全都发火）
#   1 = 对账不符 / 编译或仿真失败 / 装置未 PASS / 网表不存在
#   2 = 负对照没发火（含"突变体没跑起来"）⇒ **闸门自身不可信**
#   3 = 向量/参考自检失败（用例写错；含"真 blob 的布局算术"锚不过）
#
# 装置契约（rtl_test/WgtDmaTb.v + rtl_test/AxiMemModel.v + gen/LayerSched.v）：
#   +DESC_ADDR= +DESC_COUNT= +WBASE= +EXPN= +EXPBYTES= +EXPB= [+WGTFILE=] [+OVRFILE=] [+EXPECT_ERR]
#   装置打印：`TB WGTDMA: ...` / `STORE_MISMATCH<i>=<n>` / `STORE_FIRST slice=.. addr=..` /
#             `FRAME_DONE=.. ERR_SEEN=.. UNIT_INDEX=.. WGT_BYTES=..` / `AR_TOTAL=.. AW_TOTAL=.. B_OK=..` /
#             `WGT_BYTES_CHK got=.. exp=..` / `RESULT: PASS|FAIL`
#   内存模型打印：`MEM rd=<b> wr=<b> bursts=<n> maxburst=<n>`
set -uo pipefail

PY="${PY:-python}"
here="$(cd "$(dirname "$0")" && pwd)"
gen="$here/../gen"
tb="$here/../rtl_test/WgtDmaTb.v"
memv="$here/../rtl_test/AxiMemModel.v"
nl="$gen/LayerSched.v"
ref="$here/conv_unit_ref.py"
dangling="$here/check_dangling.py"

# ---- 用例常量（与 rtl_test/WgtDmaTb.v 的 AxiMemModel MEMSZ 一致；sched 网表 = WIDTH=32）----
MEMSZ=2621440          # 2.5 MiB
DESC_ADDR=4096         # 0x1000
SRC=131072             # 0x20000，conv 的输入激活（NHWC）
T2=135168              # 0x21000，maxpool 的输入
DST=196608             # 0x30000，X（plain conv）的输出
DST2=200704            # 0x31000，链尾的输出
T3=204800              # 0x32000，maxpool 的输出
WBASE=524288           # 0x80000，WGT_BLOB_BASE（reduced 与大作业共用）
W=32; H=8; CIN=8; COUT=8; GRP=1; SHIFT=6
IN_BYTES=$(( CIN * H * W ))     # 2048
NSEG=576                        # 每单元/每片权重段字节数 = C_OUT*(C_IN/GROUP)*9
PERIOD=251                      # 素周期（与 128 互素，防混叠）
PETURB=7                        # J5 改的字节（X 段内偏移）
OVRB=9                          # 覆盖作业改的字节
# 大作业 J6：整份真 blob（★ B0 2026-10-12：**32 B 对齐布局** ⇒ blob 长 404064，**不是** 576 的倍数）
BIGBLOB="$gen/wgt_blob.bin"
BIGBYTES=404064        # 真 blob 的（对齐后）字节数；闸门[1a] 与 index/文件**三者互证**（不写死算）
J6LOAD=$(( (BIGBYTES / NSEG) * NSEG ))   # 403776 = 701*576：窄通路用 576B 单元铺满"≤ blob 的最大 576 倍数"
BIGADDR=1310720        # 0x140000，真 blob 镜像落点（+404064 < MEMSZ）
BIGSRC=65536           # 0x10000，激活（避开 702 项的表述区 4096..26560）
BIGDST=524288          # 0x80000
BIGDC=701              # 大作业的表项数（87 条 8 片链 + 1 条 5 片链 = 701 单元 x 576 = 403776 = J6LOAD）

work="$(mktemp -d)"
cleanup() {
  if [ "${KEEP_TMP:-0}" = "1" ]; then
    echo "KEEP_TMP=1 => 激励与日志留在 $work"
  else
    rm -rf "$work"
  fi
}
trap cleanup EXIT

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

echo "== run_wgtdma_ab: 权重段从 DDR 批量装载（DMA 主路径）——逐单元逐字节 + 装载字节数 + 定位负对照 =="
echo "   tb  =$tb"
echo "   mem =$memv"
echo "   nl  =$nl"
echo "   ref =$ref"
echo "   py=${PY}  iverilog=${IVERILOG:-<找不到>}  vvp=${VVP:-<找不到>}"
echo "   tmp =$work"
echo "   用例 DESC_ADDR=$DESC_ADDR SRC=$SRC DST=$DST DST2=$DST2 WBASE=$WBASE W=$W H=$H C=$CIN IN_BYTES=$IN_BYTES"
echo "   reduced blob = $(( 4 * NSEG )) B（4 段 x $NSEG）；大作业 = 真 blob $BIGBLOB（$BIGBYTES B @ $BIGADDR）"

# ---------------- 前置检查 ----------------
[ -f "$nl" ]   || { echo "FATAL: 找不到网表 $nl"; echo "       先生成: cd y1 && printf 'Test/runMain LayerSchedGen D:/code/PDS/VexiiYeshenLinux/y1/gen\\\\nexit\\\\n' | bash sbt.sh"; exit 1; }
[ -f "$tb" ]   || { echo "FATAL: 找不到装置 $tb"; exit 1; }
[ -f "$memv" ] || { echo "FATAL: 找不到内存模型 $memv"; exit 1; }
[ -f "$ref" ]  || { echo "FATAL: 找不到参考 $ref"; exit 1; }
[ -f "$BIGBLOB" ] || { echo "FATAL: 找不到真 blob $BIGBLOB（C4a 产物）"; exit 1; }
if [ -z "$IVERILOG" ] || [ -z "$VVP" ]; then echo "FATAL: 找不到 iverilog / vvp"; exit 1; fi

# ---------------- 0) 参考自检 + 结构判据 ----------------
echo "---- 0) tools/conv_unit_ref.py --selftest（本闸门借它造 X/A/B/C 四段权重与黄金）----"
if ! "$PY" "$ref" --selftest; then
  echo "=== FATAL: 参考自检没过 ⇒ 用例/参考写错了（不是硬件的问题）==="; exit 3
fi
echo "---- 0b) tools/check_dangling.py（gen/LayerSched.v ⇒ 零悬空）----"
if [ -f "$dangling" ]; then
  "$PY" "$dangling" "$nl" | tail -2
  if ! "$PY" "$dangling" "$nl" >/dev/null; then echo "JUDGE-RED: 有悬空实例"; exit 1; fi
else
  echo "WARN: 找不到 $dangling（跳过结构判据）"
fi

# ---------------- 1) 造向量 ----------------
echo "---- 1) 造向量：真 blob 布局算术锚 + reduced blob(4 段) + 各作业镜像/期望 ----"
if ! "$PY" - "$work" "$here" "$gen" "$MEMSZ" "$DESC_ADDR" "$SRC" "$T2" "$DST" "$DST2" "$T3" \
     "$WBASE" "$W" "$H" "$CIN" "$COUT" "$GRP" "$SHIFT" "$NSEG" "$PERIOD" "$PETURB" "$OVRB" \
     "$BIGSRC" "$BIGDST" "$BIGADDR" "$BIGBYTES" "$BIGDC" <<'PYEOF'
import sys, json, struct, hashlib
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

work, here, gen = sys.argv[1], sys.argv[2], sys.argv[3]
(memsz, desc_addr, src, t2, dst, dst2, t3, wbase, W, H, CIN, COUT, GRP, SHIFT, NSEG,
 PERIOD, PETURB, OVRB, bigsrc, bigdst, bigaddr, bigbytes, bigdc) = (int(x) for x in sys.argv[4:27])

sys.path.insert(0, here)
import conv_unit_ref as R

IN_BYTES = CIN * H * W       # 本用例的激活字节数（int8：元素数 == 字节数）

def dump(path, toks):
    with open(path, "w", encoding="ascii", newline="\n") as f:
        f.write("".join("%02x\n" % (v & 0xFF) for v in toks))

def pat(i):
    return ((i % PERIOD) * 131 + 7) % PERIOD

def mkdesc(t, flags, iw, ih, cin, cout, grp, stride, pad, srcA, dstA, inb, qs, lid):
    w = [0] * 8
    w[0] = t | (flags << 8)
    w[1] = iw | (ih << 16)
    w[2] = cin | (cout << 16)
    w[3] = grp | (stride << 8) | (pad << 12)
    w[4] = srcA
    w[5] = dstA
    w[6] = inb
    w[7] = qs | (lid << 8)
    return b"".join(struct.pack("<I", x) for x in w)

SENT = b"\xff" + b"\x00" * 31

# =========================================================================================
# 1a) ★ 锚：真 blob 的**布局算术**（离线判据 —— "装载字节数"这句话的地基）
#     ★ B0 2026-10-12：布局改为 **32 B 对齐**（每单元段 ceil32(N_i)、补位 0；spec §4.2 修订）
# =========================================================================================
idx = json.load(open(gen + "/wgt_index.json", encoding="utf-8"))
blob = open(gen + "/wgt_blob.bin", "rb").read()
assert idx["blob"]["bytes"] == len(blob) == bigbytes, \
    "wgt_index.blob.bytes %d / 文件 %d / 常量 %d 三者不符" % (idx["blob"]["bytes"], len(blob), bigbytes)
assert hashlib.md5(blob).hexdigest() == idx["blob"]["md5"], "真 blob md5 与 wgt_index 不符"
def _a32(n):
    return (n + 31) & ~31
run = 0
bad_off = []
sum_true = 0
for u in idx["units"]:
    w = u["weight"]
    if w is None:
        continue
    ab = int(w.get("aligned_bytes", _a32(w["nbytes"])))
    if w["offset"] != run or (w["offset"] % 32) != 0 or ab != _a32(w["nbytes"]):
        bad_off.append((u["idx"], u["name"], w["offset"], run, ab))
    run += ab
    sum_true += int(w["nbytes"])
assert not bad_off, "真 blob 不是 32 B 对齐布局（offset != Σceil32(N_j) 或 offset 对 32 非对齐）：前几处 %s" % bad_off[:4]
assert run == len(blob), "Σ ceil32(N_i) = %d != blob %d" % (run, len(blob))
assert sum_true == idx["blob"]["sum_N"] and (len(blob) - sum_true) == idx["blob"]["pad_overhead"], \
    "对齐账不平：真实 ΣN=%d 补位=%d 物理 ΣN'=%d（index 称 %d/%d/%d）" \
    % (sum_true, len(blob) - sum_true, len(blob), idx["blob"]["sum_N"], idx["blob"]["pad_overhead"], idx["blob"]["bytes"])
print(f"ANCHOR: 真 blob **32 B 对齐**布局 OK：53 段 offset = Σ_("
      f"j<i) ceil32(N_j)（全部对 32 取模 == 0）；真实 ΣN = {sum_true} + 补位 {len(blob) - sum_true} "
      f"= 物理 {len(blob)} == blob 字节数（md5 {idx['blob']['md5'][:12]}）")
j6load = (len(blob) // NSEG) * NSEG
print(f"ANCHOR: 窄通路（576 B/单元）能铺满 ≤ blob 的最大 576 倍数 = floor({len(blob)}/576)*576 = {j6load}"
      f"（尾 {len(blob) - j6load} B = 对齐补位，窄通路不读）")
assert j6load == 701 * NSEG, "J6 可铺满的字节数 %d != 701*576" % j6load

# 按 **RTL 规则**（描述符几何 + depthwise 例外）重算段长，看与真 blob 一致的比例（**诚实记录**）
#   ★ B0 2026-10-12：对齐布局下，"`段长%32==0` + `段起点%32==0`"这条 DdrMaster 契约对**全部** 53 段成立；
#     宽通路的**另一条**几何约束（`C_in%8==0`，即"无跳过通道补位"）仍会挡下 C_in 非 8 倍数的单元（如 Conv_0）。
ok_desc = 0
tot_desc = 0
wide_ok = 0
for u in idx["units"]:
    if u["weight"] is None:
        continue
    tot_desc += 1
    g = u["table_geom"]
    n_rtl = (g["C_OUT"] * 9) if u["type_code"] == 3 else (g["C_OUT"] * (g["C_IN"] // g["GROUP"]) * 9)
    if n_rtl == u["weight"]["nbytes"]:
        ok_desc += 1
    # ★ 宽通路**几何**可达 = B1b 的 `wideDmaOk` 前提（除"对齐"外）：GROUP==1、非 depthwise、C_in%8==0、C_out%8==0
    o = u["own"]
    if (o["C_IN"] % 8 == 0) and (o["C_OUT"] % 8 == 0) and (o["GROUP"] == 1) and (u["type_code"] != 3):
        wide_ok += 1
print("ANCHOR: 按 **RTL 规则**（描述符几何 `N = C_out*(C_in/GROUP)*9` + depthwise 例外）能重算出真段长的单元：%d/%d"
      % (ok_desc, tot_desc))
print(f"ANCHOR: 对齐后 DdrMaster 契约（src 对 32 取模 == 0 且 len 对 32 取模 == 0）：53/53 段满足；"
      f"其中**宽通路几何可达**（B1b `wideDmaOk` 的其余前提：GROUP==1 / 非 depthwise / C_in 与 C_out 均为 8 的倍数）"
      f"的 {wide_ok}/{tot_desc}（如 Conv_0 的 C_in=3 ⇒ 归多趟跳过通道，响亮 err——**不是**对齐问题）")

# =========================================================================================
# 1b) reduced blob：X / A / B / C 四段（各一份 dense 8x8 3x3 权重 + 激活 + 黄金）
# =========================================================================================
seeds = [("X", 20251011), ("A", 20251012), ("B", 20251013), ("C", 20251014)]
wt = {}; xddr = {}; yddr = {}
for tag, sd in seeds:
    w_, xc, xd, yd = R.build(CIN, COUT, H, W, seed=sd, shift=SHIFT)
    assert len(w_) == NSEG and len(xd) == IN_BYTES and len(yd) == IN_BYTES
    assert len(set(w_)) > 1 and len(set(yd)) > 1, "%s 向量是常数（用例没意义）" % tag
    wt[tag] = list(w_); xddr[tag] = list(xd); yddr[tag] = list(yd)

rblob = wt["X"] + wt["A"] + wt["B"] + wt["C"]
assert len(rblob) == 4 * NSEG
pl = [0, NSEG, 2 * NSEG, 3 * NSEG]
print("PREFIX: reduced blob 段起点 = %s（= Σ_{j<i} N_j，N = %d）" % (pl, NSEG))

ZERO = [0] * NSEG
EXP8 = lambda s0: s0 + ZERO * 7        # 8 片的期望：片 0 = s0，片 1..7 必须全 0

# ---- 表 ----
# J1：表序 = [X(plain conv) , P(maxpool plain) , A(head) , B(middle) , C(tail)]（5 项）
#   ★ 前缀和证据：A 必须落在**偏移 576**（X 贡献 576、**旁路 P 贡献 0**）、B 在 1152、C 在 1728
tbl_J1 = (mkdesc(0x01, 0b01, W, H, CIN, COUT, GRP, 1, 1, src, dst, IN_BYTES, SHIFT, 0) +
          mkdesc(0x10, 0b01, W // 2, H // 2, CIN, COUT, GRP, 2, 0, t2, t3, IN_BYTES, 0, 1) +
          mkdesc(0x01, 0b00, W, H, CIN, COUT, GRP, 1, 1, src, dst2, IN_BYTES, SHIFT, 2) +
          mkdesc(0x01, 0b10, W, H, CIN, COUT, GRP, 1, 1, src, dst2, IN_BYTES, SHIFT, 3) +
          mkdesc(0x01, 0b11, W, H, CIN, COUT, GRP, 1, 1, src, dst2, IN_BYTES, SHIFT, 4) + SENT)
# J2/J3/J5/J7/J9：表序 = [W(plain conv)]（单单元 ⇒ 段起点 = 基址 + 0 ⇒ 期望 = blob[0:576) = X 段）
tbl_W = mkdesc(0x01, 0b01, W, H, CIN, COUT, GRP, 1, 1, src, dst, IN_BYTES, SHIFT, 0) + SENT
# J4：表序 = [E(plain conv)，但 GROUP=4 ⇒ 与本网表展开期 GROUP 不符]
tbl_E = mkdesc(0x02, 0b01, W, H, CIN, COUT, 4, 1, 0, src, dst, IN_BYTES, SHIFT, 0) + SENT

def ndesc(tbl):
    return (len(tbl) - 32) // 32

# ---- 大作业 J6 的表：87 条 8 片链 + 1 条 5 片链（共 701 项）----
#   ★★ C4b-B2：`LAYER_ID` **必须落在参数表深度 `PN_LAYERS=64` 之内**（`lidOk` 在 `go` 那一刻
#     响亮 err + 零搬运；见 `rtl/UnitExec.scala` 的 `lidOk` 与 `tools/run_paramdel_ab.sh` [5]）。
#     本作业只测**权重装载的字节/落点** ⇒ `LAYER_ID` 取 `& 0x3F`（0..63）即可，
#     判据语义**一字未变**（旧稿用 `& 0xFF` ⇒ 701 项里有相当一部分 `LAYER_ID ≥ 64`，
#     在新守卫下会被正确拦住 ⇒ 装置报 err）。真表 53 个有权重单元 `layer_id ≤ 60` ⇒ 不受影响。
def chain(n, lid):
    out = b""
    for i in range(n):
        fl = 0b00 if i == 0 else (0b11 if i == n - 1 else 0b10)
        out += mkdesc(0x01, fl, W, H, CIN, COUT, GRP, 1, 1, bigsrc, bigdst, IN_BYTES, SHIFT, (lid + i) & 0x3F)
    return out

tbl_BIG = b""
lid = 0
for c in range(87):
    tbl_BIG += chain(8, lid); lid += 8
tbl_BIG += chain(5, lid)
tbl_BIG += SENT
assert ndesc(tbl_BIG) == bigdc, "大作业表项数 %d != %d" % (ndesc(tbl_BIG), bigdc)
# 大作业的期望：**最后一链**（5 片）落在片 0..4 ⇒ 就是"窄通路铺满段"（[0, j6load)）的最后 5 段
last5 = j6load - 5 * NSEG
assert last5 == 400896, "末链段起点 %d != 400896" % last5
print("BIG: 表 = 87x8片 + 1x5片 = %d 项（descCount=%d）；窄通路铺满 [0,%d)（blob 尾 %d B 是对齐补位、不读）；"
      "末链 5 片 = blob[%d:%d]"
      % (ndesc(tbl_BIG), bigdc, j6load, bigbytes - j6load, last5, j6load))

def mk_mem(name, tbl, tbl_at, blobimg, blob_at, acts):
    mem = bytearray(pat(i) for i in range(memsz))
    mem[tbl_at:tbl_at + len(tbl)] = tbl
    if blobimg is not None:
        mem[blob_at:blob_at + len(blobimg)] = bytes(v & 0xFF for v in blobimg)
    for (a, data) in acts:
        mem[a:a + len(data)] = bytes(v & 0xFF for v in data)
    dump("%s/%s.mem.hex" % (work, name), mem)

jobs = []
def job(name, memname, expname, expn, expb, daddr, dcount, wb, wgt=None, ovr=None, eerr=0):
    jobs.append((name, memname, expname or "-", expn, expb, daddr, dcount, wb, wgt or "-", ovr or "-", eerr))

# ---- J1 / J1b：同一张表，DMA 开 / 关（MEM rd 差值 == 权重字节数 = 4*576）----
mk_mem("J1", tbl_J1, desc_addr, rblob, wbase, [(src, xddr["X"]), (t2, xddr["B"])])
dump("%s/J1.exp.hex" % work, EXP8(wt["A"] + wt["B"] + wt["C"]))
job("J1",  "J1", "J1.exp", 8, 4 * NSEG, desc_addr, ndesc(tbl_J1), wbase)
dump("%s/J1b.exp.hex" % work, ZERO * 8)                       # DMA 关 ⇒ 八片全 0
job("J1b", "J1", "J1b.exp", 8, 0, desc_addr, ndesc(tbl_J1), 0)

# ---- J2：单单元 + DMA 装载后经信箱**覆盖**（起点 0 的那一段 = X）----
ovr = list(wt["X"]); ovr[OVRB] = (ovr[OVRB] + 1) & 0xFF
assert ovr != wt["X"]
mk_mem("J2", tbl_W, desc_addr, rblob, wbase, [(src, xddr["X"])])
dump("%s/J2.exp.hex" % work, EXP8(ovr))
dump("%s/J2.ovr.hex" % work, ovr)
job("J2", "J2", "J2.exp", 8, NSEG, desc_addr, ndesc(tbl_W), wbase, ovr="%s/J2.ovr.hex" % work)

# ---- J3：DMA **关** + 帧前经信箱预载（C3/C4a 的旧通路）----
m3 = list(wt["X"]); m3[OVRB] = (m3[OVRB] + 2) & 0xFF
mk_mem("J3", tbl_W, desc_addr, rblob, wbase, [(src, xddr["X"])])
dump("%s/J3.exp.hex" % work, EXP8(m3))
dump("%s/J3.wgt.hex" % work, m3)
job("J3", "J3", "J3.exp", 8, 0, desc_addr, ndesc(tbl_W), 0, wgt="%s/J3.wgt.hex" % work)

# ---- J4：DMA 开 + 几何不符（GROUP=4）⇒ 响亮 err + 零搬运 ----
mk_mem("J4", tbl_E, desc_addr, rblob, wbase, [(src, xddr["X"])])
job("J4", "J4", None, 0, -1, desc_addr, ndesc(tbl_E), wbase, eerr=1)

# ---- J5：负对照 —— blob 镜像里改**一个字节**（X 段内 PETURB）⇒ 必须红且定位 ----
bflip = bytearray(v & 0xFF for v in rblob)
flip_at = PETURB
bflip[flip_at] ^= 0xFF
mk_mem("J5", tbl_W, desc_addr, bflip, wbase, [(src, xddr["X"])])
dump("%s/J5.exp.hex" % work, EXP8(wt["X"]))     # 期望 = **未被改** 的那一段 ⇒ 装置必然报不符
job("J5", "J5", "J5.exp", 8, NSEG, desc_addr, ndesc(tbl_W), wbase)

# ---- JA：单单元、DMA 开、**不**覆盖（= 突变体 J7/J9 的基线；镜像与 J2 同一份）----
dump("%s/JA.exp.hex" % work, EXP8(wt["X"]))
job("JA", "J2", "JA.exp", 8, NSEG, desc_addr, ndesc(tbl_W), wbase)

# ---- J7 / J9：网表突变（装载段长 +32 / -32）——与 JA 同配置 ----
job("J7", "J2", "JA.exp", 8, NSEG, desc_addr, ndesc(tbl_W), wbase)
job("J9", "J2", "JA.exp", 8, NSEG, desc_addr, ndesc(tbl_W), wbase)

# ---- J6：大作业（真 blob 的 32 B 对齐布局，404064 B；窄通路铺满 [0, 403776) = 701*576）----
mk_mem("J6", tbl_BIG, desc_addr, blob, bigaddr, [(bigsrc, xddr["A"])])
dump("%s/J6.exp.hex" % work, blob[last5:last5 + 5 * NSEG])
job("J6", "J6", "J6.exp", 5, j6load, desc_addr, bigdc, bigaddr)

with open("%s/jobs.txt" % work, "w", encoding="ascii", newline="\n") as f:
    for j in jobs:
        f.write("%s %s %s %d %d %d %d %d %s %s %d\n" % j)
dump("%s/J1.goldX.hex" % work, yddr["X"])
with open("%s/meta.txt" % work, "w", encoding="ascii", newline="\n") as f:
    f.write("%d %d %d %d %d %d %d %d\n" % (src, dst, dst2, t3, IN_BYTES, NSEG, PETURB, OVRB))
# ★ J9（-32 突变）的**期望不符字节数**：该段**尾部 32 字节**里"非 0"的个数（未写的字节保持初值 0
#   ⇒ dut=0；只有 exp≠0 的才算不符）。**数据相关**（实测 X 段尾部 32 字节里有 5 个本来就是 0）
#   ⇒ 必须**算出来**，写死 32 会把好闸门判红（闸门第一版就是这么错的）。
j9_ntail = sum(1 for b in wt["X"][NSEG-32:NSEG] if (b & 0xFF) != 0)
with open("%s/wgtnum.txt" % work, "w", encoding="ascii", newline="\n") as f:
    f.write("%d\n" % j9_ntail)
print("VEC: J9（-32 突变）尾部 32 字节里非 0 的个数 = %d（= 期望的 STORE_MISMATCH0）" % j9_ntail)
print("VEC: reduced blob = %dB（X/A/B/C 各 %dB）；J1 期望 = A++B++C++5 段 0；J2/J3/J5/J7/J9 = X 段（+覆盖）"
      % (4 * NSEG, NSEG))
print("VEC: J5 改的字节 = blob 偏移 %d（X 段内 +%d）⇒ 装置必须报 STORE_MISMATCH0=1、STORE_FIRST slice=0 addr=%d"
      % (flip_at, PETURB, PETURB))
PYEOF
then
  echo "FATAL: 生成向量失败（或真 blob 布局锚不过）"; exit 3
fi
for f in J1.mem.hex J1.exp.hex J1b.exp.hex J2.mem.hex J2.exp.hex J2.ovr.hex J3.mem.hex J3.exp.hex \
         J3.wgt.hex J4.mem.hex J5.mem.hex J5.exp.hex J6.mem.hex J6.exp.hex J1.goldX.hex jobs.txt meta.txt wgtnum.txt; do
  [ -s "$work/$f" ] || { echo "FATAL: 向量 $f 缺失或为空"; exit 3; }
done

# 逐字节比较小工具（与 run_unitexec_ab.sh 同款：非法/'xx' 字节按"不等于任何值"计 ⇒ 仍会发火）
cat > "$work/cmpbytes.py" <<'PYEOF'
XBAD = -1
def load_num(p):
    vals = []; nbad = 0; first = -1
    for ln, raw in enumerate(open(p, encoding="utf-8", errors="replace"), 1):
        s = raw.strip()
        if not s:
            continue
        try:
            v = int(s, 16)
        except ValueError:
            v = None
        if v is None or v < 0 or v > 0xFF:
            if first < 0:
                first = ln
            nbad += 1
            vals.append(XBAD)
        else:
            vals.append(v)
    return vals, nbad, first
def diffs(a, b, base=0):
    assert len(a) == len(b), "length %d vs %d" % (len(a), len(b))
    cnt = 0; first = -1
    for k in range(len(a)):
        if a[k] != b[k]:
            if first < 0:
                first = base + k
            cnt += 1
    return cnt, first
PYEOF

# ---------------- 2) 编译（好网表 + 两个突变体）----------------
echo "---- 2) iverilog 编译（WgtDmaTb + AxiMemModel + gen/LayerSched.v）----"
if ! "$IVERILOG" -g2012 -o "$work/sim.vvp" "$tb" "$memv" "$nl" > "$work/iv.log" 2>&1; then
  echo "JUDGE-RED: iverilog 编译失败"; sed -n '1,40p' "$work/iv.log"; exit 1
fi
grep -qi 'warning' "$work/iv.log" && { echo "    编译告警（留意）："; grep -i 'warning' "$work/iv.log" | head -3; }
echo "    编译 OK"

mutate() {  # <mode: plus32|minus32> <outfile>
  "$PY" - "$nl" "$2" "$1" <<'PYEOF'
import re, sys
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass
src = open(sys.argv[1], encoding="utf-8", errors="replace").read()
mode = sys.argv[3]
n1 = len(re.findall(r"mLen <= wgtLenR;", src))
assert n1 == 1, "期望恰好 1 处 `mLen <= wgtLenR;`，实际 %d" % n1
new = src.replace("mLen <= wgtLenR;", "mLen <= (wgtLenR + 32'h20);" if mode == "plus32"
                  else "mLen <= (wgtLenR - 32'h20);")
if mode == "minus32":
    # 装载器的收尾条件同步改小（否则主口给不出那么多拍 ⇒ 挂住），这仍是"只动这一个自由度"
    n2 = len(re.findall(r"\(wlCnt < wgtWrLenR\)", new))
    n3 = len(re.findall(r"\(wlCnt == wgtWrLenR\)", new))
    assert n2 == 1 and n3 == 1, "装载器收尾条件命中数 %d/%d（期望 1/1）" % (n2, n3)
    new = new.replace("(wlCnt < wgtWrLenR)", "(wlCnt < (wgtWrLenR - 32'h20))")
    new = new.replace("(wlCnt == wgtWrLenR)", "(wlCnt == (wgtWrLenR - 32'h20))")
assert new != src
open(sys.argv[2], "w", encoding="utf-8", newline="\n").write(new)
print("MUTGEN mode=%s hits(mlen)=%d" % (mode, n1))
PYEOF
}

echo "---- 2b) 网表突变：装载段长 +32 / -32（'装载字节数'判据的牙）----"
for m in plus32 minus32; do
  if ! mutate "$m" "$work/LayerSched_$m.v" > "$work/mut_$m.out" 2>&1; then
    echo "JUDGE-RED: 构造 $m 突变网表失败："; cat "$work/mut_$m.out"; exit 2
  fi
  cat "$work/mut_$m.out"
  if ! "$IVERILOG" -g2012 -o "$work/mut_$m.vvp" "$tb" "$memv" "$work/LayerSched_$m.v" > "$work/iv_mut_$m.log" 2>&1; then
    echo "JUDGE-RED: $m 突变体编译失败"; sed -n '1,20p' "$work/iv_mut_$m.log"; exit 2
  fi
done

# ---------------- 3) 跑作业 ----------------
declare -A JOBDATA
while read -r nm mem exp expn expb da dc wb wgt ovr eerr; do
  JOBDATA[$nm]="$mem $exp $expn $expb $da $dc $wb $wgt $ovr $eerr"
done < "$work/jobs.txt"

run_job() {  # <vvpfile> <job> <logbase>
  local vvp="$1" job="$2" log="$3"
  local mem exp expn expb da dc wb wgt ovr eerr extra
  read -r mem exp expn expb da dc wb wgt ovr eerr <<< "${JOBDATA[$job]}"
  extra=()
  [ "$exp" != "-" ] && extra+=("+EXPBYTES=$work/$exp.hex")
  [ "$wgt" != "-" ] && extra+=("+WGTFILE=$wgt")
  [ "$ovr" != "-" ] && extra+=("+OVRFILE=$ovr")
  [ "$eerr" = "1" ] && extra+=("+EXPECT_ERR")
  ( cd "$work" && "$VVP" "$vvp" \
      "+MEMFILE=$work/$mem.mem.hex" "+DUMPFILE=$work/$log.dump" +dump \
      "+DESC_ADDR=$da" "+DESC_COUNT=$dc" "+WBASE=$wb" \
      "+EXPN=$expn" "+EXPBYTES=$work/$exp.hex" "+EXPB=$expb" "+CTRL=1" "${extra[@]}" ) > "$work/$log.log" 2>&1
  return $?
}

memrd() { sed -n 's/^MEM rd=\([0-9]*\) wr=.*/\1/p' "$1" | tail -1; }
# ★ `getv` 取 `<name>=<num>` 的**词**（不锚行首）：`WGT_BYTES` 与 `FRAME_DONE/ERR_SEEN/UNIT_INDEX`
#   同行（装置契约），锚行首会取到空串（闸门第一版就这么静默取空、把判据② 判成不符）。
getv() { grep -oE "(^|[[:space:]])$2=[0-9-]+" "$1" | tail -1 | sed -E "s/.*$2=//"; }
getl() { sed -n "s/^$2 \(.*\)/\1/p" "$1" | head -1; }

declare -A RC
runpass() {  # <job> <vvp> <expect: pass|fail|any>
  run_job "$3" "$1" "$1"; RC[$1]=$?
  grep -E '^(TB WGTDMA:|FRAME_DONE|AR_TOTAL|STORE_MISMATCH|STORE_FIRST|STORE_TOTAL|WGT_BYTES_CHK|ERRLESS_OK|RESULT)' \
       "$work/$1.log" | sed 's/^/   /' || true
  case "$2" in
    pass) if [ "${RC[$1]}" -ne 0 ] || ! grep -q '^RESULT: PASS' "$work/$1.log"; then
            echo "JUDGE-RED: 作业 $1 装置未 PASS（rc=${RC[$1]}）"; exit 1; fi ;;
    fail) if [ "${RC[$1]}" -eq 0 ] || ! grep -q '^RESULT: FAIL' "$work/$1.log"; then
            echo "NEGCTL-FAIL: 作业 $1 该红却绿（rc=${RC[$1]}）"; NEG_OK=0; fi ;;
    any)  : ;;
  esac
}

NEG_OK=1
echo "---- 3) 作业（J1 前缀和/链分片；J1b 基线；J2 覆盖；J3 旧信箱通路；J4 err；J5 负对照；J6 大作业）----"
runpass J1  pass "$work/sim.vvp"
runpass J1b pass "$work/sim.vvp"
runpass J2  pass "$work/sim.vvp"
runpass J3  pass "$work/sim.vvp"
runpass J4  pass "$work/sim.vvp"
runpass J5  fail "$work/sim.vvp"
if [ "${RC[J5]}" -eq 0 ]; then :; fi    # （fail 分支只在"该红却绿"时改动 NEG_OK）
runpass J6  pass "$work/sim.vvp"
runpass J7  any "$work/mut_plus32.vvp"
runpass J9  any "$work/mut_minus32.vvp"

# ---- J4 的"零设备搬运"细则（err 路径必须一个 AW/W 都不发）----
J4MEM="$(grep -m1 '^MEM rd=' "$work/J4.log")"
case "$J4MEM" in
  "MEM rd=64 wr=0 bursts=2 maxburst=4") : ;;   # 只取了两次表（表尾哨兵探测 + 第 0 项）
  *) echo "NEGCTL-FAIL: J4（几何不符）不是'零设备搬运'：[$J4MEM]"; NEG_OK=0 ;;
esac

# ---------------- 4) 判据① 的数值附判（J1：X 的输出 == 黄金）----------------
echo "---- 4) J1 数值附判：X（plain conv，用 DMA 装进来的权重）的输出 == conv_unit_ref 黄金 ----"
J1NUM="$("$PY" - "$work" <<'PYEOF'
import sys
sys.path.insert(0, sys.argv[1])
from cmpbytes import load_num, diffs
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass
work = sys.argv[1]
src, dst, dst2, t3, ln, nseg, pet, ovb = (int(x) for x in open(work + "/meta.txt").read().split()[-8:])
d, dx, _ = load_num(work + "/J1.dump")
g, gx, _ = load_num(work + "/J1.goldX.hex")
m, first = diffs(d[dst:dst+ln], g[:ln], 0)
print("J1_X_OUT_MISMATCH=%d" % m)
print("J1_X_OUT_FIRST=%d" % (dst + first if first >= 0 else -1))
PYEOF
)"
echo "$J1NUM" | sed 's/^/   /'
J1XM="$(printf '%s\n' "$J1NUM" | sed -n 's/^J1_X_OUT_MISMATCH=//p' | tail -1)"
if [ "$J1XM" != "0" ]; then
  echo "JUDGE-RED: J1 的 conv 输出与黄金不符（$J1XM）⇒ DMA 装进来的权重没有被计算用上"; exit 1
fi

# ---------------- 5) 判据②：装载字节数 ----------------
echo "---- 5) 判据②：设备侧 wgt_bytes 与内存模型 MEM rd（差值 == 权重字节数；大作业 == 403,776 = 701*576）----"
MRD_J1=$(memrd "$work/J1.log");  MRD_J1B=$(memrd "$work/J1b.log"); MRD_J2=$(memrd "$work/J2.log")
MRD_J6=$(memrd "$work/J6.log")
WGT_J1=$(getv "$work/J1.log" WGT_BYTES); WGT_J2=$(getv "$work/J2.log" WGT_BYTES)
WGT_J3=$(getv "$work/J3.log" WGT_BYTES); WGT_J6=$(getv "$work/J6.log" WGT_BYTES)
EXPW=$(( 4 * NSEG ))
DELTA=$(( MRD_J1 - MRD_J1B ))
EXP_MRD_J6=$(( J6LOAD + 88 * IN_BYTES + (BIGDC + 1) * 32 ))
echo "   J1 : MEM rd=$MRD_J1  wgt_bytes=$WGT_J1（X + 链 3 片 = 4 段 = $EXPW B）"
echo "   J1b: MEM rd=$MRD_J1B（DMA 关，同一张表）  差值 = $DELTA（必须 == $EXPW）"
echo "   J2 : MEM rd=$MRD_J2  wgt_bytes=$WGT_J2（单单元 = $NSEG B）"
echo "   J3 : wgt_bytes=$WGT_J3（DMA 关 ⇒ 必须 0）"
echo "   J6 : MEM rd=$MRD_J6（期望 == 窄通路铺满 $J6LOAD + 激活 88*$IN_BYTES + 取表 $(( (BIGDC+1)*32 )) = $EXP_MRD_J6）"
echo "        wgt_bytes=$WGT_J6（期望 == 701*576 = $J6LOAD；blob 物理 $BIGBYTES，尾 $(( BIGBYTES - J6LOAD )) B 是对齐补位）"
BYTES_OK=1
if [ "$WGT_J1" != "$EXPW" ] || [ "$WGT_J2" != "$NSEG" ] || [ "$WGT_J3" != "0" ]; then
  echo "JUDGE-RED: 设备侧装载字节数不符（J1=$WGT_J1/期望 $EXPW；J2=$WGT_J2/期望 $NSEG；J3=$WGT_J3/期望 0）"; BYTES_OK=0
fi
if [ "$DELTA" != "$EXPW" ]; then
  echo "JUDGE-RED: MEM rd 差值 $DELTA != $EXPW ⇒ 权重读的字节数不对"; BYTES_OK=0
fi
if [ "$WGT_J6" != "$J6LOAD" ]; then
  echo "JUDGE-RED: 大作业 wgt_bytes=$WGT_J6 != 701*576 = $J6LOAD（多/少都不许）"; BYTES_OK=0
fi
if [ "$MRD_J6" != "$EXP_MRD_J6" ]; then
  echo "JUDGE-RED: 大作业 MEM rd=$MRD_J6 != 期望 $EXP_MRD_J6（三方对账失败）"; BYTES_OK=0
fi
[ "$BYTES_OK" = "1" ] && echo "   判据② OK：设备侧自报 + 内存模型差值 + 大作业总量（含 403,776 = 701*576）三方相符"

# ---------------- 6) 负对照判决 ----------------
echo "---- 6) 负对照判决 ----"
J5MIS=$(getv "$work/J5.log" STORE_MISMATCH0); J5FIRST=$(getl "$work/J5.log" STORE_FIRST)
echo "   J5（blob 镜像改 1 字节）：STORE_MISMATCH0=$J5MIS  STORE_FIRST=[$J5FIRST]"
if [ "${RC[J5]}" -eq 0 ] || ! grep -q '^RESULT: FAIL' "$work/J5.log"; then
  echo "NEGCTL-FAIL: J5（blob 改 1 字节）没红 ⇒ 判据① 对 blob 内容不敏感"; NEG_OK=0
fi
case "$J5FIRST" in
  "slice=0 addr=$PETURB dut="*) : ;;
  *) echo "NEGCTL-FAIL: J5 的第一处不符不是 (片=0, 地址=$PETURB)：[$J5FIRST]"; NEG_OK=0 ;;
esac
if [ "$J5MIS" != "1" ]; then
  echo "NEGCTL-FAIL: J5 的不符字节数 $J5MIS != 1（改一个字节只应差一个）"; NEG_OK=0
fi
[ "$NEG_OK" = "1" ] && echo "   → 定位：blob 偏移 $PETURB（reduced blob 的 X 段内第 $PETURB 字节）= 单元 X0 / 段起点 0"
# J7：+32 突变 ⇒ 多读：MEM rd 恰好 +32，而 store 仍逐字节相等、设备侧计数仍 576
J7RD=$(memrd "$work/J7.log"); J7WGT=$(getv "$work/J7.log" WGT_BYTES); J7MIS=$(getv "$work/J7.log" STORE_MISMATCH0)
echo "   J7（突变 +32B）：MEM rd=$J7RD（好网表 J2=$MRD_J2）  wgt_bytes=$J7WGT  STORE_MISMATCH0=$J7MIS"
if [ "$J7RD" != "$(( MRD_J2 + 32 ))" ]; then
  echo "NEGCTL-FAIL: J7 的 MEM rd 不是'好网表 +32'（$J7RD != $(( MRD_J2 + 32 ))）⇒ 突变/判据② 不敏感"; NEG_OK=0
elif [ "$J7MIS" != "0" ] || [ "$J7WGT" != "$NSEG" ]; then
  echo "NEGCTL-FAIL: J7 的 store/wgt_bytes 也被改了（mis=$J7MIS wgt=$J7WGT）⇒ 突变不干净"; NEG_OK=0
else
  echo "   → 判据② 的牙（多读）：MEM rd 恰好 +32；store 仍逐字节相等、设备侧计数仍 $J7WGT（只动字节数）"
fi
# J9：-32 突变 ⇒ 少读：MEM rd -32、wgt_bytes -32、store 尾部 32 字节为 0（判据① 与 ② 一起发火）
J9RD=$(memrd "$work/J9.log"); J9WGT=$(getv "$work/J9.log" WGT_BYTES)
J9MIS=$(getv "$work/J9.log" STORE_MISMATCH0); J9FIRST=$(getl "$work/J9.log" STORE_FIRST)
J9NTAIL="$(tr -d '[:space:]' < "$work/wgtnum.txt")"   # 尾部 32 字节里非 0 的个数（数据相关，见造向量）
echo "   J9（突变 -32B）：MEM rd=$J9RD  wgt_bytes=$J9WGT  STORE_MISMATCH0=$J9MIS（期望 $J9NTAIL）  FIRST=[$J9FIRST]"
if [ "$J9RD" != "$(( MRD_J2 - 32 ))" ] || [ "$J9WGT" != "$(( NSEG - 32 ))" ]; then
  echo "NEGCTL-FAIL: J9 的 MEM rd/wgt_bytes 不是'好网表 -32'（$J9RD/$J9WGT）⇒ 少读没被抓"; NEG_OK=0
elif [ "$J9MIS" != "$J9NTAIL" ]; then
  echo "NEGCTL-FAIL: J9 的 store 不符字节数 $J9MIS != 尾部 32 字节里非 0 的 $J9NTAIL（尾部 32 字节应为 0）"; NEG_OK=0
fi
case "$J9FIRST" in
  "slice=0 addr=$(( NSEG - 32 )) dut=00 exp="*) : ;;
  *) echo "NEGCTL-FAIL: J9 的第一处不符不是 (片=0, 地址=$(( NSEG - 32 )))：[$J9FIRST]"; NEG_OK=0 ;;
esac
[ "$NEG_OK" = "1" ] && echo "   → 判据② 的牙（少读）：MEM rd/wgt_bytes 各 -32，且判据① 同时报 store 尾部 32 字节为 0"

# ---------------- 收口 ----------------
echo "=========================================================================="
echo "判据① 逐单元逐字节：J1 片0/1/2 = A/B/C（前缀和 576/1152/1728，旁路单元贡献 0）+ 片3..7 全 0；"
echo "        J2/J3/J5/J7 = 片0 = X 段（含覆盖）；J6 = 末链 5 片 = 真 blob 末 2880 B"
echo "判据② 装载字节数：设备侧 J1=$WGT_J1 J2=$WGT_J2 J3=$WGT_J3 J6=$WGT_J6（窄通路铺满 403,776 = 701*576；blob 物理 404,064）；"
echo "        MEM rd 差值 J1-J1b=$DELTA（== 4 段）；J6 总量三方对账 $MRD_J6 == 期望 $EXP_MRD_J6"
echo "负对照：J5 blob 改 1 字节 ⇒ MISMATCH0=$J5MIS @ [$J5FIRST]（定位 X0 / blob 偏移 $PETURB）；"
echo "        J7 突变 +32B ⇒ MEM rd=$J7RD（+32，store 仍相等）；J9 突变 -32B ⇒ MEM rd=$J9RD、store 尾 32B 为 0"
echo "另附：J4 几何不符 ⇒ 响亮 err + 零设备搬运（MEM rd=64 = 只取了两次表）；"
echo "      J1 数值附判：X 的输出逐字节 == conv_unit_ref 黄金（MISMATCH=$J1XM）"
echo "结构与自检：check_dangling gen/LayerSched.v = OK；conv_unit_ref --selftest = OK"
if [ "$NEG_OK" != "1" ]; then
  echo "=== NEGCTL-BAD: 负对照没抓住 ⇒ 闸门自身不可信 ==="; exit 2
fi
if [ "$BYTES_OK" != "1" ]; then
  echo "=== JUDGE-RED: 判据② 不符 ==="; exit 1
fi
echo "RESULT: PASS"
exit 0
