#!/usr/bin/env bash
# run_bypass_tile_ab.sh —— ★★ T-S3a.2b：**旁路算子 2-D tile 循环**（`BypassExec`）的闸门。
#
# 被测：`rtl/BypassExec.scala` 的**空间 tiling**（tile 输出 32×32、pool 的列方向再切 `WIDTH/2`；
#   输入窗口无 halo；读 = 按输入行跨步的 32 B 对齐 band 读（每 band 对 8 个平面各一笔）；写 = 每
#   (平面, 输出行) 一笔 32 B 对齐 + `wstrb` 掩码）。
#   装置 `rtl_test/BypassTb.v` 的 **`+TILED_B` 档**（`-DBP_TILED_B` 编出来：DUT = `BypassExec` +
#   `AxiMemModel.v`，**装置不喂列流** —— 激活由 DUT 自己从 DDR 取，这正是 tiling 的要点）。
#
# 契约与口径：`rtl/BypassExec.scala` 文件头的「旁路 tiling（T-S3a）契约」+「T-S3a.2b 落地」两节
#   （逐字冻结），spec `docs/superpowers/specs/2026-10-14-y1-frame-runnable-design.md` §3.1 / §3.1.1。
#
# ★ 网表：**`gen/BypassExec_w34.v`**（`BypassExecGen ... 8 34 32 BypassExec_w34.v`）= **与板级同参**
#   （`WIDTH=34 / IMG_H_MAX=32` ⇒ `MAXPIX = 1088`）。**同一份网表**里两条路径由**运行期二选一**：
#   `wholeOk` ⇒ 原整层路径（本闸门的**前提档**就是这条，它同时是回归锚）；否则 tile。
#
# ============================== 判据 ==============================
#  0) **前置**：冻结参考自检（`tools/bypass_ref.py --selftest`；该参考**冻结、永不编辑**）；
#     网表存在；iverilog/vvp 在 PATH；`tools/check_dangling.py` 存在。
#  1) **前提档（整层路径；`cIn = 8`、小形状）**：`maxpool` C=8 16×16（输入 32×32 ⇒ `rowW = 32 ≤ 34`、
#     `outPix = 256 ≤ 1088`）⇒ **走原整层路径** ⇒ 装置 PASS + `DST` 逐字节 == 整层黄金。
#  2) **正对照（真表旁路形状，走 tile）**：`maxpool` C=16 160×160（`MaxPool_5`）/ C=64 80×80
#     （`MaxPool_18`）/ C=64 40×40（`MaxPool_25`）/ C=64 20×20（`MaxPool_32`）；`resize` C=64 80×80
#     （`Resize_49`）+ ★★ **T-S3e：`resize` C=64 40×40（真表 `Resize_43`：输入 20×20、`inCols = 400`、
#     `400 % 32 == 16` —— per-plane band 的承重档）**。判据：装置 PASS + `DST` 逐字节 == **整层黄金**
#     （`MISMATCH=0`）+ `SRC` 未动 + `DST` 紧邻 64 B 邻居未动。黄金 = **冻结参考复用**（`bypass_ref.py`
#     的 `nontrivial` + `maxpool_ref`/`resize2x_ref`，再经该参考自己的 `to_tensor` 折成通道平面）
#     —— **不写第三条参考**。
#  2d) **正对照（★★ T-S3a.2d：`Add` 的两路源 + 多块 + 平面 + tile）**：`add` C_IN=C_OUT=64、
#     **40×40**（`Add_44`）与 **80×80**（`Add_50`），`+SRCPLANAR +DSTPLANAR +SRC2=<B 平面基址>
#     +SRC2K=1`（E1：`w3[31:16]` 非 0 ⇒ `addTwoSrc`）。两路源**各是一份 NCHW 平面张量**
#     （A 在 `SRC`、B 在 `SRC2`）⇒ DUT 走 tile 的**两趟**（A 趟落 `outMem`、B 趟读 `io.src2` 并
#     在原位改成 `clamp8(A+B)`）。判据 = 装置 PASS + `DST` 逐字节 == 冻结参考黄金 + `SRC`/`SRC2`
#     两个输入区**都未动** + 邻居未动。黄金 = 冻结参考自己的
#     `add_ref(*split_add(add_nontrivial(64,W,H)))` 再经 `to_tensor` 折成平面 —— **不写第三条参考**。
#     形状合法性（逐条由 `BypassExec` 的 tile 前提反推，`genjob.py` 逐条硬断言）：
#       `cIn == cOut == 64`（8 块）、`inCols = outPix = W²`、`inCols % 32 == 0`（平面 band 对齐）、
#       `outPix > MAXPIX(1088)` ⇒ **必须**走 tile（`wholeOk` 恒假）。
#  3) **负对照①（漏最后一个 tile 行，`tNty-1`）** ⇒ `MISMATCH>0`、且**错配全部落在被漏的 tile 行带**
#     （首个坏字节 = 该带在平面 0 的起点 `(tNty-1)·TILE_H·IMG_W`）。★ 外科式自检：同一突变体在**前提档**
#     （走整层路径、根本不读 `tNty`）上**逐字节不变**。
#  4) **负对照②（输入窗口错一格：`2·oy0 -> 2·oy0+1` ⇒ 窗口起点整体下移一行）** ⇒ `MISMATCH>0`。
#     ★ 外科式自检：同一突变体在**前提档**上**逐字节不变**。
#  4d) **负对照③（★★ T-S3a.2d：砍掉第二路源的**通道块偏移**）**：网表突变把 `tSrc2R` 的块偏移去掉
#     （`tSrc2R <= (io.src2 + blkSrcR)` -> `tSrc2R <= io.src2`）⇒ B 趟在块 1..7 上读到**别处**的字节
#     ⇒ `add` 40×40 必须 `DST_MISMATCH>0`，且**首个坏字节 ≥ 8·outPix**（块 1 的平面起点：块 0 是对的）。
#     ★ 外科式自检：同一突变体在**不做 `Add` 的 tile 作业**（`maxpool` C=64 40×40）上**逐字节不变**
#     （那条路 `tPass` 恒 0 ⇒ `tSrcE` 恒取 `tSrcR`，根本不碰 `tSrc2R`）。
#  5) **结构判据**：`tools/check_dangling.py gen/BypassExec_w34.v` ⇒ 零悬空实例。
#  6) **负对照④（★★ T-S3e：per-plane 索引退回**共享 plane-0**，两侧）**：网表突变把 drain 的
#     per-plane band 内下标 `tIdxP_k[4 : 3]` / `tIdxP_k[2 : 0]`（选本平面 chunk 的字/字内字节）
#     退回 `tIdxP_0[...]`（= 旧的"8 个平面共用同一个 band 相位"口径；**只切数据通路**，
#     `tIdxP[6:5]`（chunk 选择/账本）不切 —— 理由见 §7 的同一段注释）⇒
#     **`inCols%32≠0` 的形状（`resize` 40×40，`inCols = 400`）必红**（该档各平面相位 0/16
#     交替 ⇒ 共享位置读错字节），而 **`inCols%32==0` 的形状（`resize` 80×80，`inCols = 6400`）
#     逐字节不变（各平面低 5 位相同 ⇒ 共享位置本来就对）**。**两侧都要断言**，且两侧都要"装置 PASS"
#     （突变只改字节来源，不改收工条件）。
#
# 退出码：0 = 全过 / 1 = **正对照红**（含 iverilog 编译失败：与 `run_tiling2d_wide_ab.sh` 同口径）/
#   2 = 负对照没发火（或"判据线自检"不过）⇒ 闸门自身不可信 / 3 = 前置缺失。
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
cd "$here/.." || { echo "FATAL: 进不去 y1/"; echo "RESULT: FAIL"; exit 3; }

PY="${PY:-}"
if [ -z "$PY" ]; then
  for c in /d/code/PDS/NaxYeshenLinux/sim/reglogs/lxvenv/Scripts/python.exe python3 python; do
    if command -v "$c" >/dev/null 2>&1; then PY="$c"; break; fi
  done
fi
[ -n "$PY" ] || { echo "FATAL: 找不到 python"; echo "RESULT: FAIL"; exit 3; }

tb="rtl_test/BypassTb.v"
memv="rtl_test/AxiMemModel.v"
ref="tools/bypass_ref.py"
dangling="tools/check_dangling.py"
nl="gen/BypassExec_w34.v"      # ★ T-S3a.2b：与板级同参（WIDTH=34 / IMG_H_MAX=32 ⇒ MAXPIX=1088）
MEMSZ=2621440                  # 2.5 MB（与 run_bypass_cblk_ab.sh / UnitExecWideTb 同口径）
SRC=131072                     # 0x020000（32 B 对齐；最大输入 1638400 B ⇒ 到 0x1B0000）
DST=1835008                    # 0x1C0000（32 B 对齐；在最大输入之后，不与 SRC 重叠）
# ★★ T-S3a.2d：`Add` 的**第二路源**（B 的平面张量）的落点。只被 `add` 作业使用（其它作业里它只是
#   背景图案）：0x100000、32 B 对齐；`add` 的最大形状（80×80、C=64）B = 409600 B ⇒ 到 0x16_C000，
#   与 `SRC`（到 0x03_9000）和 `DST`（0x1C_0000 起）都不重叠。
SRC2B=1048576
tools_abs="$(pwd)/tools"

find_tool() {
  local n="$1" p d
  p="$(command -v "$n" 2>/dev/null || true)"
  if [ -z "$p" ]; then for d in /c/msys64/ucrt64/bin /mingw64/bin /usr/bin; do [ -x "$d/$n" ] && { p="$d/$n"; break; }; done; fi
  printf '%s' "$p"
}
IVERILOG="$(find_tool iverilog)"; VVP="$(find_tool vvp)"

echo "== run_bypass_tile_ab: BypassExec 空间 tile 循环（真表旁路形状 + ★ Add 两路源）逐字节闸门 —— T-S3a.2b/2d =="
echo "   nl=$nl  tb=$tb  ref=$ref  py=$PY  iverilog=${IVERILOG:-<none>}"

for f in "$nl" "$tb" "$memv" "$ref" "$dangling"; do
  [ -f "$f" ] || { echo "FATAL: 缺 $f"; echo "RESULT: FAIL"; exit 3; }
done
[ -n "$IVERILOG" ] && [ -n "$VVP" ] || { echo "FATAL: 缺 iverilog/vvp"; echo "RESULT: FAIL"; exit 3; }

work="$(mktemp -d)"
cleanup() { [ "${KEEP_TMP:-0}" = "1" ] && echo "KEEP_TMP=1 => $work" || rm -rf "$work"; }
trap cleanup EXIT
export PYTHONPATH="./.pydeps;../third_party/yunet/deps"
export PYTHONIOENCODING=utf-8

echo "---- 0) 冻结参考自检 bypass_ref.py --selftest（前置；不过 exit 3）----"
"$PY" "$ref" --selftest > "$work/ref.log" 2>&1 || { echo "RESULT: FAIL 冻结参考自检没过"; tail -5 "$work/ref.log"; exit 3; }
tail -1 "$work/ref.log" | sed 's/^/   /'

# ---------------------------------------------------------------- 编译 ----
echo "---- 1) iverilog 编译（BypassTb + AxiMemModel + $nl，-DBP_TILED_B）----"
if ! "$IVERILOG" -g2012 -DBP_TILED_B -o "$work/sim.vvp" "$tb" "$memv" "$nl" > "$work/iv.log" 2>&1; then
  echo "JUDGE-COMPILE-FAIL: iverilog 编译失败"; sed -n '1,30p' "$work/iv.log"; echo "RESULT: FAIL"; exit 1
fi
echo "   编译 OK"

# ---------------------------------------------------------------- 作业生成器 ----
cat > "$work/genjob.py" <<'PYEOF'
"""作业生成：**只做布局/落盘**；黄金一律复用**冻结参考**（`bypass_ref.py`），不写第三条。
   argv: tools_abs work name op cin out_w out_h src dst memsz src2
     · op=maxpool/resize：`src.hex` = 输入平面张量、`gold.hex` = 整层黄金（平面）；
     · op=add（★★ T-S3a.2d）：`src.hex` = **A** 的平面张量、`src2.hex` = **B** 的平面张量、
       `gold.hex` = `clamp8(A+B)` 的平面张量 —— 两路源各是一片独立张量（E1 的 `io.src2`）。"""
import os, sys
sys.path.insert(0, sys.argv[1])
import numpy as np
import bypass_ref as B

def dump(path, toks, w=2):
    a = (np.asarray(toks, dtype=np.int64) & ((1 << (4 * w)) - 1))
    with open(path, "w", encoding="ascii", newline="\n") as f:
        f.write("".join(("%0" + str(w) + "x\n") % int(v) for v in a))

def main():
    tools, work, name, op = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
    cin, out_w, out_h = (int(x) for x in sys.argv[5:8])
    src, dst, memsz = (int(x) for x in sys.argv[8:11])
    src2 = int(sys.argv[11]) if len(sys.argv) > 11 else 0
    if op == "maxpool":
        in_w, in_h = 2 * out_w, 2 * out_h                 # 2x2/s2：输入几何 = 输出的 2 倍
    elif op == "resize":
        in_w, in_h = out_w // 2, out_h // 2               # x2 最近邻：输入几何 = 输出的一半
        assert out_w % 2 == 0 and out_h % 2 == 0, "resize 的输出几何必须偶数（输入 = 输出/2）"
    elif op == "add":
        in_w, in_h = out_w, out_h                         # ★ T-S3a.2d：Add 逐点 ⇒ 输入几何 == 输出几何
    else:
        raise SystemExit("FATAL: 本闸门只做 maxpool / resize / add(两路源)")
    d = os.path.join(work, name); os.makedirs(d, exist_ok=True)

    in_cols, out_pix = in_w * in_h, out_w * out_h
    WIDTH, MAXPIX, TILE_H, TILE_W = 34, 1088, 32, 32
    assert src % 32 == 0 and dst % 32 == 0, "SRC/DST 必须 32 B 对齐（AxiMemModel 的合规检查）"
    assert cin % 8 == 0 and cin != 0, "cIn 必须是 8 的正整数倍（cBlkOk）"
    # ★★ T-S3e：**`inCols % 32 == 0` 不再是对 tile 读的前提** —— 每个平面各记自己的
    #   `(chunk 序, band 内下标)`（`tIdxP(p)`，各平面按自己的地址算）；band 基址仍 `& ~31`
    #   （突发合法）。真表 `Resize_43`（`inCols = 400`）正是这条的承重档（见 §6 负对照④）。

    if op == "add":
        # ---- ★★ T-S3a.2d：两路源各一份**独立的 NCHW 平面张量**（A@SRC、B@SRC2）----
        #   取数/相加/布局**全部复用冻结参考**（add_nontrivial / split_add / add_ref / to_tensor）
        #   —— 不写第三条参考、也不改冻结文件。
        st = B.add_nontrivial(cin, in_w, in_h)
        a, bb = B.split_add(st, cin, in_w, in_h)
        assert a != bb, "两路输入相等 ⇒ 加法退化成 ×2（判据没意义）"
        assert B.add_sat_events(a, bb) > 0, "向量上没有饱和点 ⇒ '饱和 vs 回绕'的负对照是橡皮章"
        gold_nhwc = B.add_ref(a, bb, cin, in_w, in_h)
        assert out_pix > MAXPIX, "本档的 add 只放**必须走 tile** 的形状（outPix=%d > MAXPIX=%d）" % (out_pix, MAXPIX)
        xs  = B.to_tensor(a,  cin, in_w, in_h)
        xs2 = B.to_tensor(bb, cin, in_w, in_h)
        assert src2 % 32 == 0, "SRC2 必须 32 B 对齐（平面 band 读的前提）"
        assert src + len(xs) <= src2 or src2 + len(xs2) <= src, "SRC 与 SRC2 重叠"
        assert src2 + len(xs2) <= dst and src + len(xs) <= dst, "SRC/SRC2 与 DST 重叠"
        assert max(src + len(xs), src2 + len(xs2), dst + cin * out_pix) + 64 <= memsz, "越界（memsz=%d）" % memsz
    else:
        # ★ 本档的 maxpool/resize 全是**真表大形状**（`outPix > MAXPIX` 或 `rowW > WIDTH`）⇒ 必走 tile。
        #   为什么**不**在 `genjob.py` 里逐条断言"必须走 tile"：那要求把 `geomOk`/`rowWOk` 复刻一遍
        #   （= 第三条参考）；本闸门的判据是**逐字节 == 冻结参考的整层黄金**，装置若走了别的路径
        #   （err / 整层）就会当场露馅（前提档 `premise_*` 反过来钉"整层路径也是对的"）。
        #   ★★ T-S3e：`inCols % 32 != 0`（真表 `Resize_43`，400）已支持 ⇒ 不再断言。
        xin = B.nontrivial(cin, in_w, in_h)
        gold_nhwc = B.maxpool_ref(xin, cin, in_w, in_h) if op == "maxpool" else B.resize2x_ref(xin, cin, in_w, in_h)
        xs  = B.to_tensor(xin, cin, in_w, in_h)
        xs2 = []
        assert src + len(xs) <= dst or dst + cin * out_pix <= src, "SRC/DST 重叠"
        assert max(src + len(xs), dst + cin * out_pix) + 64 <= memsz, "越界（memsz=%d）" % memsz

    assert len(gold_nhwc) == cin * out_pix, "黄金长度 %d != C_out*outPix = %d" % (len(gold_nhwc), cin * out_pix)
    assert len(set(int(v) for v in gold_nhwc)) > 1, "黄金退化（常数）⇒ 判据没意义"
    # ---- 折成**通道平面**（NCHW，`off(c) = c·HW`）—— 复用冻结参考自己的 to_tensor ----
    gs = B.to_tensor(gold_nhwc, cin, out_w, out_h)
    # 内存镜像：背景 + SRC（A）处的输入平面 [+ SRC2（B）]；DST 处预载**与黄金必然不同**
    mem = (((np.arange(memsz, dtype=np.int64) % 251) * 131 + 7) % 251).astype(np.uint8)
    mem[src:src + len(xs)] = np.asarray(xs, dtype=np.int64).astype(np.uint8)
    if len(xs2):
        mem[src2:src2 + len(xs2)] = np.asarray(xs2, dtype=np.int64).astype(np.uint8)
    gb = np.asarray(gs, dtype=np.int64).astype(np.uint8)
    mem[dst:dst + len(gb)] = gb ^ np.uint8(0x5A)
    assert int(np.count_nonzero(mem[dst:dst + len(gb)] != gb)) == len(gb), "DST 预载与黄金重合"

    dump(os.path.join(d, "mem.hex"), mem)
    dump(os.path.join(d, "gold.hex"), gb)
    dump(os.path.join(d, "src.hex"), np.asarray(xs, dtype=np.int64).astype(np.uint8))
    dump(os.path.join(d, "src2.hex"), np.asarray(xs2, dtype=np.int64).astype(np.uint8))
    with open(os.path.join(d, "job.txt"), "w", encoding="ascii", newline="\n") as f:
        f.write("OP=%s\nCIN=%d\nCOUT=%d\nW=%d\nH=%d\nINW=%d\nINH=%d\nSRC=%d\nDST=%d\nNB=%d\nOUTPIX=%d\n"
                "INCOL=%d\nTILEH=%d\nTILEW=%d\nSRC2=%d\n" %
                (op, cin, cin, out_w, out_h, in_w, in_h, src, dst, len(gb), out_pix, in_cols, TILE_H, TILE_W,
                 (src2 if op == "add" else 0)))
    print("JOBGEN %s op=%s C=%d 输出 %dx%d（输入 %dx%d）| A 平面 %d B / B 平面 %d B / 黄金 %d B | "
          "outPix=%d inCols=%d src2=%d"
          % (name, op, cin, out_w, out_h, in_w, in_h, len(xs), len(xs2), len(gb), out_pix, in_cols,
             (src2 if op == "add" else 0)))

main()
PYEOF

# ---------------------------------------------------------------- 比对器 ----
cat > "$work/cmpdump.py" <<'PYEOF'
"""从 AxiMemModel 的落盘镜像里按窗口对账。
   argv: dump goldhex srchex src2hex dst goldlen SRC SRC2 CIN W H
   ★★ T-S3a.2d：多一个**第二路源区** `SRC2` 的"未被改动"判据（`add` 作业里它是 B 的平面张量）。"""
import sys
import numpy as np

def load_dump(p, memsz):
    txt = open(p, "r", encoding="utf-8", errors="replace").read()
    h = "".join(txt.split())
    assert len(h) == 2 * memsz, "落盘镜像长度 %d 个十六进制字符 != 2*memsz = %d" % (len(h), 2 * memsz)
    return np.frombuffer(bytes.fromhex(h), dtype=np.uint8)

def load_hex(p):
    return np.frombuffer(bytes.fromhex("".join(open(p, "r", encoding="utf-8").read().split())), dtype=np.uint8)

dumpp, goldp, srcp, src2p = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
dst, goldlen, SRC, SRC2 = (int(x) for x in sys.argv[5:9])
MEMSZ = 2621440
mem = load_dump(dumpp, MEMSZ)
gold = load_hex(goldp); src = load_hex(srcp); src2 = load_hex(src2p)
assert len(gold) == goldlen
got = mem[dst:dst + goldlen]
bad = np.flatnonzero(got != gold)
print("DST_MISMATCH=%d" % len(bad))
print("FIRST_BAD=%d" % (int(bad[0]) if len(bad) else -1))
print("LAST_BAD=%d" % (int(bad[-1]) if len(bad) else -1))
# 邻居：DST 窗口之后 64 B 必须纹丝不动（背景图案）
nb0, nb1 = dst + goldlen, dst + goldlen + 64
bg = (((np.arange(MEMSZ, dtype=np.int64) % 251) * 131 + 7) % 251).astype(np.uint8)
print("NEIGH_MISMATCH=%d" % int(np.count_nonzero(mem[nb0:nb1] != bg[nb0:nb1])))
# 源：输入平面区必须纹丝不动（DUT 只读不写那里 ⇒ 逐字节 == 供料时的输入）
print("SRC_MISMATCH=%d" % int(np.count_nonzero(mem[SRC:SRC + len(src)] != src)))
# ★★ T-S3a.2d：第二路源区（B 的平面张量）同样必须纹丝不动（len==0 ⇒ 本作业不用第二路 ⇒ 0）
print("SRC2_MISMATCH=%d" % (int(np.count_nonzero(mem[SRC2:SRC2 + len(src2)] != src2)) if len(src2) else 0))
# ---- 错配的**定位**（供"漏 tile 行"/"漏块偏移"负对照断言"错配落在被影响的区域里"）----
if len(bad):
    C, W, H = int(sys.argv[9]), int(sys.argv[10]), int(sys.argv[11])
    pl = bad // (W * H); rr = (bad % (W * H)) // W
    print("BAD_ROW_MIN=%d" % int(rr.min()))
    print("BAD_ROW_MAX=%d" % int(rr.max()))
    print("BAD_PLANE_MIN=%d" % int(pl.min()))
    print("BAD_PLANE_MAX=%d" % int(pl.max()))
else:
    print("BAD_ROW_MIN=-1")
    print("BAD_ROW_MAX=-1")
    print("BAD_PLANE_MIN=-1")
    print("BAD_PLANE_MAX=-1")
PYEOF

# ===========================================================================
# run_job <tag> <netlist> <simname> <op> <cin> <out_w> <out_h>  -> 0=绿(且逐字节对) 1=红
# ===========================================================================
run_job() {
  local tag="$1" nl="$2" sim="$3" op="$4" cin="$5" ow="$6" oh="$7"
  local d="$work/$tag"
  echo "--------------------------------------------------------------------------"
  echo "==== [$tag] op=$op C_IN=C_OUT=$cin 输出 ${ow}x${oh}  网表=$nl ===="
  if ! "$PY" "$work/genjob.py" "$tools_abs" "$work" "$tag" "$op" "$cin" "$ow" "$oh" "$SRC" "$DST" "$MEMSZ" "$SRC2B" > "$work/$tag.gen.log" 2>&1; then
    echo "[$tag] FATAL: 供料失败"; tail -8 "$work/$tag.gen.log"; return 3
  fi
  grep -E '^JOBGEN' "$work/$tag.gen.log" | sed 's/^/   /'
  . "$d/job.txt" 2>/dev/null || true
  # ★★ T-S3a.2d：`Add` 的两路源 ⇒ `+SRC2=<B 平面基址>` 且 `+SRC2K=1`（非 0 ⇒ `addTwoSrc`）；
  #   其余算子 `SRC2=0 / SRC2K=0` ⇒ `desc[3]` 与改动前**逐位相同**（既有作业一字不变）。
  local s2k=0; [ "$OP" = "add" ] && s2k=1
  local rc=0
  ( cd "$work" && timeout 3600 "$VVP" "$work/$sim" \
      "+MEMFILE=$d/mem.hex" "+DUMPFILE=$d/dump.hex" +dump +TILED_B \
      "+OP=$OP" "+CIN=$CIN" "+COUT=$COUT" "+W=$W" "+H=$H" \
      "+GROUP=1" "+FLAGS=1" "+SRC=$SRC" "+DST=$DST" "+INB=$((CIN*INW*INH))" \
      "+QSHIFT=6" "+LID=0" "+SRC2=$SRC2" "+SRC2K=$s2k" "+SRCPLANAR" "+DSTPLANAR" ) > "$work/$tag.log" 2>&1 || rc=$?
  grep -E '^(TB TILED_B|RESULT|MEM )' "$work/$tag.log" | sed 's/^/    /'
  if [ ! -f "$d/dump.hex" ]; then
    echo "[$tag] JUDGE-RED: 没有落盘镜像（DUT 没跑到收工？）"; tail -3 "$work/$tag.log" | sed 's/^/    /'
    return 1
  fi
  local mis
  mis="$("$PY" "$work/cmpdump.py" "$d/dump.hex" "$d/gold.hex" "$d/src.hex" "$d/src2.hex" "$DST" "$NB" "$SRC" "$SRC2" "$CIN" "$W" "$H" 2>&1)"
  echo "$mis" | sed 's/^/    /'
  echo "[$tag] vvp 退出码=$rc"
  echo "$mis" > "$work/$tag.mis"
  if grep -q '^RESULT: PASS' "$work/$tag.log" \
     && echo "$mis" | grep -q '^DST_MISMATCH=0$' \
     && echo "$mis" | grep -q '^SRC_MISMATCH=0$' \
     && echo "$mis" | grep -q '^SRC2_MISMATCH=0$' \
     && echo "$mis" | grep -q '^NEIGH_MISMATCH=0$'; then
    echo "[$tag] 作业 = GREEN（装置 PASS + DST 逐字节 == 黄金 + 两个源区/邻居未动）"
    return 0
  fi
  echo "[$tag] 作业 = RED（装置未 PASS 或逐字节不符）"
  return 1
}

mis_of() { sed -n "s/^$2=//p" "$work/$1.mis" 2>/dev/null; }

# ===========================================================================
# 作业表
#   · 前提档：`cIn = 8`、小形状 ⇒ 走**原整层路径**（回归锚 + 两个负对照的"外科式"对照）；
#   · 正对照：真表旁的 6 个形状；★★ T-S3e 起 `Resize_43`（`resize` C=64 **40×40**、`inCols = 400`、
#     `400 % 32 = 16`）**在表内** —— per-plane band 的承重档（见 neg④ 的两侧）。
# ===========================================================================
JOBS="
premise_wholehole_c8_16x16  maxpool 8  16 16
c16_maxpool_160x160        maxpool 16 160 160
c64_maxpool_80x80          maxpool 64 80 80
c64_maxpool_40x40          maxpool 64 40 40
c64_maxpool_20x20          maxpool 64 20 20
c64_resize_80x80           resize  64 80 80
c64_resize_40x40           resize  64 40 40
c64_add_40x40              add     64 40 40
c64_add_80x80              add     64 80 80
"

rc=0
POS_FAIL=""
while read -r tag op cin ow oh; do
  [ -z "${tag:-}" ] && continue
  run_job "$tag" "$nl" sim.vvp "$op" "$cin" "$ow" "$oh" || { rc=1; POS_FAIL="$POS_FAIL $tag"; }
done <<< "$JOBS"

echo "=========================================================================="
if [ "$rc" != "0" ]; then
  echo "RESULT: FAIL 正对照红（未过的作业：$POS_FAIL）——见上；T-S3a.2b/2d 的口径下，前提档（整层路径）"
  echo "  与 6 个真表旁路形状（走 tile）、以及 2 个 Add 两路源形状（走 tile 的两趟）都必须"
  echo "  装置 PASS + DST 逐字节 == 冻结参考的黄金。"
  exit 1
fi

# ===========================================================================
# 负对照（网表突变；scratch 拷贝，绝不动 gen/）
#   ① 漏最后一个 tile 行（`tNty := tNty - 1`）⇒ 该 tile 行带的输出**一个字节都没写**；
#   ② 输入窗口错一格（`tPixR := tPixR + inW32`，即窗口起点整体下移一行）⇒ 对齐错 ⇒ 必红；
#   ③（★★ T-S3a.2d）B 源丢块偏移（`tSrc2R := io.src2 + blkSrcR` -> `io.src2`）⇒ Add 从块 1 起必红。
#   三条都配**外科式自检**：同一突变体在不走那条路的作业上必须逐字节不变。
# ===========================================================================
mut="$work/mut"; mkdir -p "$mut"

mutate() {   # mutate <old> <new> <out> -> 0=OK
  "$PY" - "$nl" "$mut/$3" "$1" "$2" <<'PYEOF'
import sys
src = open(sys.argv[1], encoding="utf-8", errors="replace").read()
old, new = sys.argv[3], sys.argv[4]
n = src.count(old)
assert n == 1, "mutation anchor not unique: %d" % n
open(sys.argv[2], "w", encoding="ascii", newline="\n").write(src.replace(old, new))
print("  MUT: %s  ->  %s" % (old.strip(), new.strip()))
PYEOF
}

# ---- 负对照①：漏最后一个 tile 行 ----
echo "---- 3) 负对照①：网表突变「tNty := tNty - 1」（漏最后一个 tile 行）----"
if ! mutate "        tNty <= _zz_tNty[15:0];" "        tNty <= (_zz_tNty[15:0] - 16'h0001);" BypassExec_nty.v; then
  echo "RESULT: FAIL（构造突变网表失败：生成风格变了，请更新本判据）⇒ 闸门不可信"; exit 2
fi
cmp -s "$nl" "$mut/BypassExec_nty.v" && { echo "RESULT: FAIL（突变网表与原文相同）⇒ 闸门不可信"; exit 2; }
if ! "$IVERILOG" -g2012 -DBP_TILED_B -o "$work/sim_nty.vvp" "$tb" "$memv" "$mut/BypassExec_nty.v" > "$work/iv_nty.log" 2>&1; then
  echo "RESULT: FAIL（突变网表编译失败）"; sed -n '1,20p' "$work/iv_nty.log"; exit 2
fi
# ①-a 正对照作业（走 tile）上必须发火
run_job "neg1_c64_40x40" "$mut/BypassExec_nty.v" sim_nty.vvp maxpool 64 40 40 || true
N1_DST="$(mis_of neg1_c64_40x40 DST_MISMATCH)"
N1_FB="$(mis_of neg1_c64_40x40 FIRST_BAD)"
N1_RMIN="$(mis_of neg1_c64_40x40 BAD_ROW_MIN)"
# 被漏的行带 = 输出行 [(tNty-1)·TILE_H, IMG_H)；tNty = ceil(40/32) = 2 ⇒ 起点 = 行 32、字节 32·40
N1_ROW="$(( (40 + 32 - 1) / 32 - 1 ))"
N1_ROW="$(( N1_ROW * 32 ))"
N1_EXP="$(( N1_ROW * 40 ))"
echo "[neg1] 突变体：DST_MISMATCH=$N1_DST（期望 >0）  FIRST_BAD=$N1_FB（期望 == 被漏行带起点 $N1_EXP）  BAD_ROW_MIN=$N1_RMIN（期望 == $N1_ROW）"
if ! [ "${N1_DST:-0}" -gt 0 ] 2>/dev/null; then
  echo "RESULT: FAIL（负对照①没发火：漏了最后一个 tile 行后仍逐字节 == 黄金）⇒ 判据是橡皮章"; exit 2
fi
if [ "${N1_FB:-0}" != "$N1_EXP" ]; then
  echo "RESULT: FAIL（负对照①发火了但首个坏字节 $N1_FB != 被漏行带起点 $N1_EXP ⇒ 不是"漏行"）"; exit 2
fi
if [ "${N1_RMIN:-0}" != "$N1_ROW" ]; then
  echo "RESULT: FAIL（负对照①的错配最小行号 $N1_RMIN != $N1_ROW ⇒ 错配没落在被漏的行带里）"; exit 2
fi
echo "  NEG_OK[漏 tile 行]: 行 0..$((N1_ROW-1)) 逐字节正确、错配全部落在被漏的行带 [$N1_ROW,40) ⇒ 这一发真被抓住"
# ①-b 外科式自检：前提档（整层路径）在同一突变体下必须逐字节不变
run_job "neg1_premise" "$mut/BypassExec_nty.v" sim_nty.vvp maxpool 8 16 16 || true
N1P_DST="$(mis_of neg1_premise DST_MISMATCH)"
echo "[neg1] 同一突变体 × 前提档（整层路径）：DST_MISMATCH=$N1P_DST（期望 0）"
if [ "${N1P_DST:-1}" != "0" ]; then
  echo "RESULT: FAIL（突变体把整层路径也改坏了）⇒ 这一刀不是外科式的"; exit 2
fi
echo "  NEG_OK[外科式]: 同一突变体下整层路径逐字节不变（它根本不读 tNty）"

# ---- 负对照②：输入窗口错一格 ----
echo "---- 4) 负对照②：网表突变「tPixR := tPixR + inW32」（输入窗口起点下移一行 = 2·oy0 -> 2·oy0+1）----"
#   ⚠ 锚点必须带上下文：★★ T-S3a.2d 之后 `tPixR <= (tYBRd + tXOfs);` 在网表里出现**两次**
#     （`TILEGO` 与 `Add` 的 B 趟重启）⇒ 单行锚点不再是唯一的。这里锚在 `TILEGO` 那一段
#     （前一行 `tNRR <= tNRC;`、后一行 `tSrcR <= (desc_4 + blkSrcR);`），语义与原来**逐字相同**。
if ! mutate "        tNRR <= tNRC;
        tPixR <= (tYBRd + tXOfs);
        tSrcR <= (desc_4 + blkSrcR);" "        tNRR <= tNRC;
        tPixR <= (tYBRd + tXOfs + inW32);
        tSrcR <= (desc_4 + blkSrcR);" BypassExec_win.v; then
  echo "RESULT: FAIL（构造突变网表失败：生成风格变了，请更新本判据）⇒ 闸门不可信"; exit 2
fi
cmp -s "$nl" "$mut/BypassExec_win.v" && { echo "RESULT: FAIL（突变网表与原文相同）⇒ 闸门不可信"; exit 2; }
if ! "$IVERILOG" -g2012 -DBP_TILED_B -o "$work/sim_win.vvp" "$tb" "$memv" "$mut/BypassExec_win.v" > "$work/iv_win.log" 2>&1; then
  echo "RESULT: FAIL（突变网表编译失败）"; sed -n '1,20p' "$work/iv_win.log"; exit 2
fi
run_job "neg2_c64_40x40" "$mut/BypassExec_win.v" sim_win.vvp maxpool 64 40 40 || true
N2_DST="$(mis_of neg2_c64_40x40 DST_MISMATCH)"
echo "[neg2] 突变体：DST_MISMATCH=$N2_DST（期望 >0）"
if ! [ "${N2_DST:-0}" -gt 0 ] 2>/dev/null; then
  echo "RESULT: FAIL（负对照②没发火：窗口错一格后仍逐字节 == 黄金）⇒ "输入窗口对齐"这一条没在起作用"; exit 2
fi
echo "  NEG_OK[窗口错一格]: 窗口起点下移一行 ⇒ 逐字节必错 ⇒ 对齐这一条真在起作用"
run_job "neg2_premise" "$mut/BypassExec_win.v" sim_win.vvp maxpool 8 16 16 || true
N2P_DST="$(mis_of neg2_premise DST_MISMATCH)"
echo "[neg2] 同一突变体 × 前提档（整层路径）：DST_MISMATCH=$N2P_DST（期望 0）"
if [ "${N2P_DST:-1}" != "0" ]; then
  echo "RESULT: FAIL（突变体把整层路径也改坏了）⇒ 这一刀不是外科式的"; exit 2
fi
echo "  NEG_OK[外科式]: 同一突变体下整层路径逐字节不变（它根本不读 tPixR）"

# ---------------------------------------------------------------------------
# 负对照③（★★ T-S3a.2d）：砍掉**第二路源的通道块偏移**（`tSrc2R <= io.src2 + blkSrcR` -> `<= io.src2`）
#   ⇒ B 趟在**块 1..7** 上读到"块 0 的那些平面"（少了 `blk·8·inCols` 的偏移）⇒
#     · `add` C=64 40×40 必须 `DST_MISMATCH > 0`，且**首个坏字节 ≥ 8·outPix**（= 块 1 的平面起点：
#       块 0 读的是对的地方 ⇒ 它的平面必须逐字节正确）—— 这条把"漏块偏移"与"整段乱写"区分开；
#     · 外科式自检：同一突变体在**不做 Add 的 tile 作业**（`maxpool` C=64 40×40）上必须逐字节不变
#       （那条路 `tPass` 恒 0 ⇒ `tSrcE` 恒取 `tSrcR`，`tSrc2R` 根本不落数据通路）。
# ---------------------------------------------------------------------------
echo "---- 6) 负对照③：网表突变「tSrc2R 丢块偏移」（B 源少 blkSrcR）⇒ Add 必发火、maxpool 不变 ----"
if ! mutate "        tSrc2R <= (_zz_tSrc2R + blkSrcR);" "        tSrc2R <= _zz_tSrc2R;" BypassExec_src2blk.v; then
  echo "RESULT: FAIL（构造突变网表失败：生成风格变了，请更新本判据）⇒ 闸门不可信"; exit 2
fi
cmp -s "$nl" "$mut/BypassExec_src2blk.v" && { echo "RESULT: FAIL（突变网表与原文相同）⇒ 闸门不可信"; exit 2; }
if ! "$IVERILOG" -g2012 -DBP_TILED_B -o "$work/sim_s2b.vvp" "$tb" "$memv" "$mut/BypassExec_src2blk.v" > "$work/iv_s2b.log" 2>&1; then
  echo "RESULT: FAIL（突变网表编译失败）"; sed -n '1,20p' "$work/iv_s2b.log"; exit 2
fi
run_job "neg3_c64_add_40x40" "$mut/BypassExec_src2blk.v" sim_s2b.vvp add 64 40 40 || true
N3_DST="$(mis_of neg3_c64_add_40x40 DST_MISMATCH)"
N3_FB="$(mis_of neg3_c64_add_40x40 FIRST_BAD)"
N3_PMIN="$(mis_of neg3_c64_add_40x40 BAD_PLANE_MIN)"
N3_B1OFS="$(( 8 * $(sed -n 's/^OUTPIX=//p' "$work/c64_add_40x40/job.txt") ))"
echo "[neg3] 突变体：DST_MISMATCH=$N3_DST（期望 >0）  FIRST_BAD=$N3_FB（期望 >= 块 1 起点 $N3_B1OFS）  BAD_PLANE_MIN=$N3_PMIN（期望 8）"
if ! [ "${N3_DST:-0}" -gt 0 ] 2>/dev/null; then
  echo "RESULT: FAIL（负对照③没发火：丢掉 B 的块偏移后 add 仍逐字节 == 黄金）⇒ "第二路源的块偏移"没在起作用"; exit 2
fi
if ! [ "${N3_FB:-0}" -ge "$N3_B1OFS" ] 2>/dev/null; then
  echo "RESULT: FAIL（负对照③发火了但首个坏字节 $N3_FB < 块 1 起点 $N3_B1OFS ⇒ 不是"漏块偏移"，是整段乱写）"; exit 2
fi
if [ "${N3_PMIN:-0}" != "8" ]; then
  echo "RESULT: FAIL（负对照③的错配最小平面 $N3_PMIN != 8 ⇒ 错配没落在块 1 起）"; exit 2
fi
echo "  NEG_OK[漏块偏移]: 块 0 的平面逐字节正确、错配全部落在块 1 及以后的平面里 ⇒ 这一发真被抓住"
run_job "neg3_surgical_maxpool" "$mut/BypassExec_src2blk.v" sim_s2b.vvp maxpool 64 40 40 || true
N3S_DST="$(mis_of neg3_surgical_maxpool DST_MISMATCH)"
echo "[neg3] 同一突变体 × maxpool C=64 40×40（走 tile、但没有第二路源）：DST_MISMATCH=$N3S_DST（期望 0）"
if [ "${N3S_DST:-1}" != "0" ]; then
  echo "RESULT: FAIL（突变体把不用第二路源的 tile 作业也改坏了）⇒ 这一刀不是外科式的"; exit 2
fi
echo "  NEG_OK[外科式]: 同一突变体下 maxpool tile 作业逐字节不变（它根本不读 tSrc2R）"

# ---------------------------------------------------------------------------
# 负对照④（★★ T-S3e）：drain 的 **per-plane band 内下标退回共享 plane-0**
#   （`tIdxP_k[4 : 3]`/`tIdxP_k[2 : 0]` -> `tIdxP_0[...]`，k=1..7）= 旧的"8 个平面共用同一个
#   band 相位"口径（drain 选字节的位置改由平面 0 的相位决定）。
#   ★ 这一刀**只切数据通路**（`tIdxP[4:3]` 选本平面 chunk 的哪个 8 B 字、`[2:0]` 选字内字节），
#     **不切** `tIdxP[6:5]`（chunk 选择 / 装载账本 `tChk/tLdK`）—— 实测：把 `[6:5]` 一起退回会让
#     "账本存的（本平面自己的 chunk）"与"条件查的（平面 0 的 chunk）"永不一致 ⇒ FETCH 原地打转
#     （40×40 档实测 4M 拍 246154 笔突发、`wr=0` 不收工）⇒ 那就不是"读错字节"这一类的红，本轮判据
#     要的是**能收工的错误数据**（与 T-S3b 负对照③ 同形：装置 PASS、只是字节对不上）。
#   · `resize` C=64 **40×40**（`inCols = 400`、`400 % 32 = 16` ⇒ 平面相位 0/16 交替）：共享位置
#     把奇平面读错位置 ⇒ **必红**（且装置仍 PASS —— 突变只改字节来源，不改收工条件）；
#   · `resize` C=64 **80×80**（`inCols = 6400`、`6400 % 32 = 0` ⇒ 各平面低 5 位相同）：共享位置
#     本来就对 ⇒ **逐字节不变**（须 MISMATCH=0）。**两侧都要断言**。
# ---------------------------------------------------------------------------
echo "---- 7) 负对照④：per-plane 索引退回共享 plane-0（40×40 必红 / 80×80 不提）----"
if ! "$PY" - "$nl" "$mut/BypassExec_idx0.v" <<'PYEOF'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
n = 0
for k in range(1, 8):
    for sl in ("[4 : 3]", "[2 : 0]"):
        n += src.count("tIdxP_%d%s" % (k, sl))
        src = src.replace("tIdxP_%d%s" % (k, sl), "tIdxP_0%s" % sl)
print("IDX0_HITS=%d (期望 >=14)" % n)
if n < 14: sys.exit(2)
open(sys.argv[2], "w", encoding="ascii", newline="\n").write(src)
PYEOF
then
  echo "RESULT: FAIL（构造 shared-idx 突变网表失败：生成风格变了，请更新本判据）⇒ 闸门不可信"; exit 2
fi
cmp -s "$nl" "$mut/BypassExec_idx0.v" && { echo "RESULT: FAIL（突变网表与原文相同）⇒ 闸门不可信"; exit 2; }
if ! "$IVERILOG" -g2012 -DBP_TILED_B -o "$work/sim_idx0.vvp" "$tb" "$memv" "$mut/BypassExec_idx0.v" > "$work/iv_idx0.log" 2>&1; then
  echo "RESULT: FAIL（shared-idx 突变网表编译失败）"; sed -n '1,20p' "$work/iv_idx0.log"; exit 2
fi
# ④-a `inCols % 32 != 0`（40×40）：必红（但装置必须 PASS —— 收工条件没被突变碰）
run_job "neg4_c64_resize_40x40" "$mut/BypassExec_idx0.v" sim_idx0.vvp resize 64 40 40 || true
grep -q '^RESULT: PASS' "$work/neg4_c64_resize_40x40.log" \
  || { echo "RESULT: FAIL（shared-idx 突变网表在 40×40 上装置都没 PASS ⇒ 突变越界了）"; exit 2; }
N4_DST="$(mis_of neg4_c64_resize_40x40 DST_MISMATCH)"
# ④-b `inCols % 32 == 0`（80×80）：逐字节不变（须 MISMATCH=0）
run_job "neg4_c64_resize_80x80" "$mut/BypassExec_idx0.v" sim_idx0.vvp resize 64 80 80 || true
grep -q '^RESULT: PASS' "$work/neg4_c64_resize_80x80.log" \
  || { echo "RESULT: FAIL（shared-idx 突变网表在 80×80 上装置都没 PASS）"; exit 2; }
N4_DST0="$(mis_of neg4_c64_resize_80x80 DST_MISMATCH)"
echo "[neg4] 突变体：40×40 DST_MISMATCH=$N4_DST（须 >0）  80×80 DST_MISMATCH=$N4_DST0（须 ==0）"
if ! [ "${N4_DST:-0}" -gt 0 ] 2>/dev/null; then
  echo "RESULT: FAIL（负对照④没发火：per-plane 索引退回共享 plane-0 后 40×40 仍逐字节 == 黄金）⇒ 判据是橡皮章"; exit 2
fi
if [ "${N4_DST0:-99}" != "0" ]; then
  echo "RESULT: FAIL（负对照④在 inCols%32==0 的 80×80 上误红，MISMATCH=$N4_DST0 ⇒ 突变不是外科式的）"; exit 2
fi
echo "  NEG_OK[共享索引两侧]: 40×40（inCols%32=16）MISMATCH=$N4_DST（>0、装置 PASS）；80×80（inCols%32=0）MISMATCH=0 ⇒ per-plane 索引这一条真在起作用"

# ---------------------------------------------------------------------------
# 结构判据
# ---------------------------------------------------------------------------
echo "---- 5) 结构判据：check_dangling.py $nl ----"
"$PY" "$dangling" "$nl" | tail -1 | sed 's/^/    /'
if ! "$PY" "$dangling" "$nl" | grep -q "total dangling instances: 0"; then
  echo "RESULT: FAIL（有悬空实例）"; exit 1
fi

echo "=========================================================================="
echo "前提档（cIn=8 整层路径）+ 真表旁路形状（maxpool 16/64ch 160×160/80×80/40×40/20×20、resize 64ch 80×80/"
echo "★★ 40×40（Resize_43、inCols%32=16），全部走 tile）+ ★★ Add 的两路源（C=64 40×40/80×80，走 tile 的两趟；B 在 SRC2）："
echo "  冻结参考自检 = OK（bypass_ref --selftest）"
echo "  正对照       = OK（9 个作业：装置 PASS + DST 逐字节 == 冻结参考黄金 + 源/SRC2/邻居未动；MISMATCH=0）"
echo "  负对照①      = OK（漏最后一个 tile 行 ⇒ 错配全部落在被漏的行带；整层路径不变 = 外科式）"
echo "  负对照②      = OK（输入窗口错一格 ⇒ 必红；整层路径不变 = 外科式）"
echo "  负对照③      = OK（B 源丢块偏移 ⇒ add 从块 1 起必错、maxpool 不变 = 外科式）"
echo "  负对照④      = OK（per-plane 索引退回共享 plane-0 ⇒ 40×40/inCols%32=16 必红、80×80/inCols%32=0 不提；两侧）"
echo "  结构         = OK（check_dangling.py：零悬空）"
echo "RESULT: PASS"
exit 0
