#!/usr/bin/env bash
# run_desc_ab.sh —— y1 C3.4 的闸门：**描述符解析器**（`rtl/DescFetch.scala` + `rtl/DescDefs.scala`
#   ⇒ `gen/DescFetch.v`）的字节级/字段级判据，与 Python 真源 `tools/desc_table.py` **交叉对账**。
#
# 为什么需要它：S1 要求"主机写表 → NPU 读回并逐项回显"。本闸门把这条通路的 RTL 半钉死：
#   · 取表：`DescFetch` 用 `DdrMaster(RD, len=32)` 取**一个 32 B 描述符**（一笔 32 B 突发 = 4 拍 x 8 B）；
#   · 译码：`DescDefs.DescWords` 把那 8 个 32-bit 小端字**纯组合**译成 14 个字段 + FLAGS 两位语义；
#   · 两处独立实现互相钉死：RTL 的 `words/字段` 必须与 `desc_table.py` 的**同一组向量**逐字/逐字段相等。
#
# 判据（全部独立算，不盲信装置自报的 PASS）：
#   0) **向量来源**：`desc_table.py --emit-hex`（表字节，一行一字节 = `$readmemh` 格式）+
#      `--emit-meta`（逐项期望：`W` 行 = 8 个 32-bit 字；`F` 行 = 14 个字段 + SENTINEL/HEAD/TAIL）。
#      表指纹必须仍是 `desc_table.TABLE_MD5_FROZEN`（单一真源，不许漂移）——
#      ★ A-2 把表**重生成**为**逐算子链式**编码（68 项 = 2176 B，FLAGS = head/middle/tail；
#        旧值 42 项 / 1344 B / `4908613bdb…` 与更早的 2176 B / `374121088f…` 都作废）。
#      ★ A-3b（契约侧收口 RTL 的 A-3）把 `desc_table.CHAIN_L_MAX` 与 RTL 的 `L_MAX` 对齐到 **8**
#        （最长链不再拆）⇒ 表**重生成**：md5 `ed00cad736b82378a59bdeedc79f3b21`（A-2/L_MAX=4）→
#        `a45d0da0440a468f1b75788c9ad5bc14`（A-3b/L_MAX=8）。
#        ★ **本闸门的前提跟着表走，但这次没挪位**（已核）：表**仍是 68 项 = 2176 B**（一个算子一项
#        与链是否拆无关 ⇒ 项数不变）、**哨兵仍在下标 67**、被测的 **idx 1 仍是 head(`0b00`)**、
#        **idx 2 仍是 tail(`0b11`)**（那条 2 片链在 L=4 时也没被拆）⇒ `TEST_IDX` / `ADDR_BASE` /
#        `mkvar.py` 的 2176 断言 / M6 的 "idx0 STRIDE!=PAD" 前提**全部照旧**。变的只有 md5。
#   1) **正对照**：把整张表预载进 `AxiMemModel`，对 4 个代表项（0 / 1 head / 2 tail / 哨兵 67）各跑一次，
#      `+DESC_ADDR = BASE + 32*idx`。判据：
#        · 装置 `RESULT: PASS`（它自己查 AR_COUNT/AR_ADDR/ARLEN/RD_BEATS/写通道静默/busy/words_valid）；
#        · **RTL 的 W0..W7 与 `desc_table` 的期望逐字相等（`WORD_BAD=0`）**；
#        · **RTL 译出的 17 个字段与 `desc_table.unpack` 逐字段相等（`FIELD_BAD=0`）**；
#        · 与内存模型交叉对账：`MEM rd=32 wr=0 bursts=1 maxburst=4`；
#        · AR 序列 == `[(DESC_ADDR, 3)]`（**一笔 32 B**，地址就是给的那个，arlen=3 = 4 拍）。
#   2) **负对照 A（位敏感）**：把表里该项的 `w6` 翻一个 bit ⇒ 装置照旧 PASS，但 RTL 的
#      `W6` 必须**恰好**等于"翻过 bit 的那个期望值"（其余 7 个字逐字不变）⇒ 闸门看的是**位**，
#      不是"到底取没取到东西"。
#   3) **负对照 A2（字序不瞎）**：把表里该项的 `w4/w5` 两段**对调** ⇒ RTL 必须报 `W4=期望的W5`、
#      `W5=期望的W4`（其余不变）。只比"不一样"是不够的 —— 必须落在**对调后的那个预测值**上。
#   4) **负对照 A3（字内小端不瞎）**：把表里该项 `w1` 的 4 个字节**整体反转** ⇒ RTL 必须报
#      `W1 = byteswap(期望的W1)`（其余不变）⇒ 钉死"同一拍里低地址字节在低 8 位"这条小端口径。
#   5) **负对照 B（对齐）**：`+DESC_ADDR=` 给一个**未 32 B 对齐**的地址 ⇒ 装置（`+EXPECT_ERR`）
#      必须 `ERR=1 && WORDS_VALID=0 && AR_COUNT=0 && RD_BEATS=0`，且内存模型 `MEM rd=0 wr=0 bursts=0`
#      （入参非法 ⇒ 一个字节都不搬）。
#   6) **负对照 C（越界）**：给一个 32 B 对齐但会让 32 B 窗口**跨出已建模内存**的地址 ⇒
#      内存模型必须 `$fatal`（`AXI-MEM OUT-OF-RANGE`）且 vvp 非 0（越界读绝不许安静地过）。
#   7) **比较器自检**：扰动一个期望字 ⇒ 逐字对账必须报**恰好 1** 个字不符（且**就是那一个下标**）
#      —— 不做这步就分不清"真的逐字相符"与"比较器把两边都读成空表也报 0"。
#   8) **非混叠断言**：预载的模式（周期 251）在**每一个被测行的 32 B 窗口**上都必须与该行的
#      表字节**不同**，否则"根本没读到表（读到的是模式）"也能蒙过逐字对账。
#
# 退出码：
#   0 = 全过（4 个正对照 + 3 个位/序负对照全按**预测值**发火 + 对齐/越界两道负对照 + 比较器自检）
#   1 = 对账不符 / 编译或仿真失败 / 装置未 PASS / AR 序列不符 / 表指纹漂移
#   2 = 负对照没发火，或比较器自检不过 ⇒ **闸门自身不可信**（橡皮图章）
#
# 装置契约（rtl_test/DescTb.v + rtl_test/AxiMemModel.v + gen/DescFetch.v）：
#   +DESC_ADDR=<dec>   描述符地址（十进制；32 B 对齐由 DUT 自己校验）
#   +MEMFILE=<file>    $readmemh 一行一个十六进制字节（整张表预载在 BASE 起；模型自己取）
#   +EXPECT_ERR        断言"本次必须 err 且零搬运"
#   +DUMPFILE=<file>   （可选）转给模型
#   装置输出：`ARB <addr> arlen=<n>` / `WORDS W0=.. W7=..` / `FIELDS[2/3] k=v ...` /
#             `TBSTAT[2/3] k=v ...` / `RESULT: PASS|FAIL`（FAIL ⇒ $fatal ⇒ vvp 非零）。
#   内存模型输出：末尾 `MEM rd=<bytes> wr=<bytes> bursts=<n> maxburst=<n>`。
set -uo pipefail

# ---- Python：本机 onnx 依赖在仓内 venv / third_party/yunet/deps 里（desc_table 的 GraphView 要它）----
PY="${PY:-}"
if [ -z "$PY" ]; then
  for c in /d/code/PDS/NaxYeshenLinux/sim/reglogs/lxvenv/Scripts/python.exe python3 python; do
    if command -v "$c" >/dev/null 2>&1; then PY="$c"; break; fi
  done
fi

here="$(cd "$(dirname "$0")" && pwd)"
top="$here/../.."                     # 仓库根（Python 侧的统一 cwd：PYTHONPATH 用相对路径）
gen="$here/../gen"
tb="$here/../rtl_test/DescTb.v"
memv="$here/../rtl_test/AxiMemModel.v"
nl="$gen/DescFetch.v"

# ---- 用例常量（必须与 rtl_test/DescTb.v 里 AxiMemModel 的 MEMSZ 一致）----
MEMSZ=8192                 # 8 KiB 建模内存
ADDR_BASE=4096             # 表基址（32 B 对齐）；整表 2176 B ⇒ 落在 [4096, 6272)
PERIOD=251                 # 与 C3 其它闸门同一个非混叠模式（周期恰 251，与 32/128 互素）
TEST_IDX="0 1 2 67"        # 4 个代表项：0=0b01 普通(Conv_0)、1=0b00 链首、2=0b11 链尾、67=哨兵
W6_FLIP_BIT=5              # 负对照 A：翻 w6 的第 5 位（与 desc_table 自检的探针同一位）
# 表指纹（C3.2 冻结）**不在本脚本里抄一份**：M1 —— 单一真源 = desc_table.py 的 TABLE_MD5_FROZEN
# （下面工具就绪后由 python 读出来；两处手抄会漂）。

work="$(mktemp -d)"
cleanup() {
  if [ "${KEEP_TMP:-0}" = "1" ]; then echo "KEEP_TMP=1 => 激励与日志留在 $work"
  else rm -rf "$work"; fi
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

echo "== run_desc_ab: 描述符解析器（DescFetch 32 B 取表 + DescDefs 纯组合译码）x desc_table.py 交叉对账 =="
echo "   tb  =$tb"
echo "   mem =$memv"
echo "   nl  =$nl"
echo "   py  =${PY:-<找不到>}  iverilog=${IVERILOG:-<找不到>}  vvp=${VVP:-<找不到>}"
echo "   tmp =$work"
echo "   用例 BASE=$ADDR_BASE (MEMSZ=$MEMSZ, 表 2176 B)  idx ∈ {$TEST_IDX}"

if [ ! -f "$nl" ];   then echo "FATAL: 找不到网表 $nl";   exit 1; fi
if [ ! -f "$tb" ];   then echo "FATAL: 找不到装置 $tb";  exit 1; fi
if [ ! -f "$memv" ]; then echo "FATAL: 找不到内存模型 $memv"; exit 1; fi
if [ -z "$PY" ] || [ -z "$IVERILOG" ] || [ -z "$VVP" ]; then echo "FATAL: 找不到 python / iverilog / vvp"; exit 1; fi

# ---- M1：表指纹**单一真源** —— 从 desc_table.py 读出冻结常量（本脚本不再手抄一份，避免漂移）----
TABLE_MD5="$( cd "$top" && PYTHONIOENCODING=utf-8 PYTHONPATH='third_party/yunet/deps' \
  "$PY" -c 'import sys; sys.path.insert(0, "y1/tools"); import desc_table; print(desc_table.TABLE_MD5_FROZEN)' \
  2>/dev/null | tail -1 )"
if [ -z "$TABLE_MD5" ]; then
  echo "FATAL: 读不出 desc_table.TABLE_MD5_FROZEN（单一真源）⇒ 无法校验表指纹"
  exit 1
fi
echo "TABLE_MD5（单一真源 desc_table.TABLE_MD5_FROZEN）=$TABLE_MD5"

# ===========================================================================
# 0) 向量来源：desc_table.py 的两个出口（同一份真源；表指纹必须没漂）
# ===========================================================================
echo "---- 0) 向量来源：desc_table.py --emit-hex / --emit-meta ----"
if ! ( cd "$top" && PYTHONIOENCODING=utf-8 PYTHONPATH='third_party/yunet/deps' \
         "$PY" y1/tools/desc_table.py --emit-hex "$work/table.hex" --emit-meta "$work/meta.txt" \
         third_party/yunet/yunet.onnx ) > "$work/emit.log" 2>&1; then
  echo "FATAL: desc_table.py 出口失败（onnx 依赖 / PY 不对？见日志）"
  sed -n '1,20p' "$work/emit.log"; exit 1
fi
grep -E '^(EMIT_TABLE|EMIT_HEX|EMIT_META|EMIT_WARN)' "$work/emit.log"
EMIT_MD5="$(sed -n 's/^EMIT_TABLE BYTES=[0-9]* ITEMS=[0-9]* MD5=\([0-9a-f]*\)$/\1/p' "$work/emit.log" | tail -1)"
[ -s "$work/table.hex" ] && [ -s "$work/meta.txt" ] || { echo "FATAL: 出口文件缺失"; exit 1; }
echo "TABLE_MD5=$EMIT_MD5（冻结 $TABLE_MD5）"
if [ "$EMIT_MD5" != "$TABLE_MD5" ]; then
  echo "RESULT: FAIL（表指纹漂了：$EMIT_MD5 != $TABLE_MD5 ⇒ 位打包被改过，走 spec 修订）"
  exit 1
fi

# ===========================================================================
# 1) 造激励：预载镜像（模式 + 表）+ 三个变异镜像；非混叠断言
# ===========================================================================
cat > "$work/mkvar.py" <<'PYEOF'
import hashlib
import sys

def load_lines(p):
    return [l.strip() for l in open(p, encoding="utf-8") if l.strip()]

def load_bytes(p):
    return bytes(int(x, 16) for x in load_lines(p))

def pat(i, period):
    return ((i % period) * 131 + 7) % period

def bswap32(b4):
    return b4[::-1]

def main():
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    work, memsz, base, period, flip_bit = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5])
    idxs = [int(x) for x in sys.argv[6:]]
    blob = load_bytes(work + "/table.hex")
    assert len(blob) == 2176, "表字节数 %d != 2176" % len(blob)
    assert base % 32 == 0 and base + len(blob) <= memsz, "表放不下"
    # ---- 非混叠断言（闸门可信度的前提）----
    assert len(set(pat(i, period) for i in range(period))) == period, "模式周期不是恰好 %d" % period
    pre = bytes(pat(i, period) for i in range(memsz))

    # ---- 逐项的表行 + 期望（与 meta 同源：直接按字节偏移解，不经 unpack）----
    def row(i):
        return blob[32 * i:32 * (i + 1)]
    for i in idxs:
        addr = base + 32 * i
        r = row(i)
        assert len(r) == 32
        same = sum(1 for j in range(32) if r[j] == pre[addr + j])
        assert same < 32, "idx=%d 的表行与模式在该窗口**逐字节相同** ⇒ 逐字对账会被混叠蒙过" % i
        assert len(set(r)) > 1 or any(b != 0 for b in r), "idx=%d 的表行太平凡" % i
        print("NONALIAS idx=%-3d addr=0x%05x row_vs_pattern_identical_bytes=%d (<32 OK)" % (i, addr, same))

    # ---- 镜像 1：模式 + 竖好的表（正对照）----
    mem = bytearray(pre)
    mem[base:base + len(blob)] = blob
    open(work + "/mem_gold.hex", "w").write("".join("%02x\n" % b for b in mem))

    # ---- 变异镜像（都以 idx 0 那一行为目标）----
    #      A  : w6 翻一个 bit（w6 的字节偏移 = 24..27 ⇒ 32 字节块内 [24] 的第 flip_bit 位）
    #      A2 : w4/w5 两段对调（字节 [16:20] <-> [20:24]）
    #      A3 : w1 的 4 个字节整体反转（字节 [4:8]）
    row0 = bytearray(row(0))
    w6_mut = bytearray(row0); w6_mut[24] ^= (1 << flip_bit)
    sw_mut = bytearray(row0); sw_mut[16:24] = row0[20:24] + row0[16:20]
    bs_mut = bytearray(row0); bs_mut[4:8] = bswap32(row0[4:8])
    for tag, mut in (("w6flip", w6_mut), ("swap45", sw_mut), ("bswap1", bs_mut)):
        assert bytes(mut) != bytes(row0), "%s 没改动任何字节" % tag
        m = bytearray(pre)
        m[base:base + 32] = mut
        m[base + 32:base + len(blob)] = blob[32:]
        open(work + "/mem_%s.hex" % tag, "w").write("".join("%02x\n" % b for b in m))
        print("VAR %-8s 目标行字节 %s -> %s" % (tag, bytes(row0).hex(), bytes(mut).hex()))
    print("MEMFILE 就绪：gold + 3 个变异（每个都含**非平凡模式**做背景，防混叠）")
    print("TABLE_MD5=%s" % hashlib.md5(blob).hexdigest())

main()
PYEOF
if ! "$PY" "$work/mkvar.py" "$work" "$MEMSZ" "$ADDR_BASE" "$PERIOD" "$W6_FLIP_BIT" $TEST_IDX > "$work/mkvar.out" 2>&1; then
  echo "FATAL: 造激励失败（或非混叠断言不成立）⇒ 闸门不可信"
  cat "$work/mkvar.out"; exit 2
fi
cat "$work/mkvar.out"

# ===========================================================================
# 2) 编译（DescTb + AxiMemModel + gen/DescFetch.v —— 一个文件里同时有 DescFetch 与 DdrMaster）
# ===========================================================================
if ! "$IVERILOG" -g2012 -o "$work/desc.vvp" "$tb" "$memv" "$nl" > "$work/iv.log" 2>&1; then
  echo "JUDGE-RED: iverilog 编译失败"; sed -n '1,40p' "$work/iv.log"; exit 1
fi
echo "---- iverilog 编译 OK（DescTb + AxiMemModel + gen/DescFetch.v）----"

# 跑一次仿真：sim <logbase> <desc_addr> <memfile> [extra plusargs...]
sim() {
  local log="$1" da="$2" mf="$3"; shift 3
  ( cd "$work" && "$VVP" desc.vvp "+DESC_ADDR=$da" "+MEMFILE=$mf" "$@" > "$log" 2>&1 )
  return $?
}

# ===========================================================================
# 3) 判定器（RTL 事实 vs desc_table 的期望）
# ===========================================================================
cat > "$work/judge.py" <<'PYEOF'
import re
import sys

# `desc_table.unpack` 的字段名 -> 装置打印的 **DescDefs.DescWords 访问器名**（两处独立实现，
# 名字不同 ⇒ 必须显式映射，不许"猜"；装置那 17 个名字逐字对应 DescDefs.scala 的 def 名）。
FMAP = [("TYPE", "TPE"), ("FLAGS", "FLAGS"), ("IMG_W", "IMGW"), ("IMG_H", "IMGH"),
        ("C_IN", "CIN"), ("C_OUT", "COUT"), ("GROUP", "GROUP"), ("STRIDE", "STRIDE"),
        ("PAD", "PAD"), ("SRC_ADDR", "SRCA"), ("DST_ADDR", "DSTA"), ("IN_BYTES", "INBYTES"),
        ("QUANT_SHIFT", "QSHIFT"), ("LAYER_ID", "LAYERID"),
        ("SENTINEL", "ISSENTINEL"), ("HEAD", "HEAD"), ("TAIL", "TAIL")]


def parse_log(path):
    words, fields, stat, mem, result, arb = {}, {}, {}, None, None, []
    words2, stat2 = {}, {}
    for line in open(path, errors="replace"):
        s = line.strip()
        if not s:
            continue
        t = s.split()
        if t[0] == "WORDS":
            for p in t[1:]:
                k, v = p.split("=")
                words[int(k[1:])] = int(v, 16)
        elif t[0] == "R2WORDS":
            for p in t[1:]:
                k, v = p.split("=")
                words2[int(k[1:])] = int(v, 16)
        elif t[0].startswith("R2STAT"):
            for p in t[1:]:
                k, v = p.split("=", 1)
                stat2[k] = int(v, 0)
        elif t[0].startswith("FIELDS"):
            for p in t[1:]:
                k, v = p.split("=", 1)
                fields[k] = int(v, 0)
        elif t[0].startswith("TBSTAT"):
            for p in t[1:]:
                k, v = p.split("=", 1)
                stat[k] = int(v, 0)
        elif s.startswith("MEM rd="):
            mem = dict(p.split("=") for p in t[1:])
        elif s.startswith("ARB "):
            arb.append((int(t[1], 16), int(t[2].split("=")[1])))
        elif s.startswith("RESULT:"):
            result = s.split(":", 1)[1].strip()
    return words, fields, stat, mem, result, arb, words2, stat2


def parse_meta(path, idx):
    words, fields = None, {}
    for line in open(path, encoding="utf-8"):
        if line.startswith("#"):
            continue
        t = line.split()
        if t and t[0] == "W" and int(t[1]) == idx:
            words = [int(x, 16) for x in t[2:10]]
        elif t and t[0] == "F" and int(t[1]) == idx:
            for p in t[2:]:
                k, v = p.split("=", 1)
                fields[k] = int(v)
    return words, fields


def bswap32(w):
    return int.from_bytes(w.to_bytes(4, "little"), "big")


def main():
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    mode, log, meta, idx = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
    lw, lf, st, mem, result, arb, lw2, st2 = parse_log(log)
    mw, mf = parse_meta(meta, idx)
    bad = 0

    def bad_word_list(got, exp):
        return [i for i in range(8) if got.get(i) != exp[i]]

    if result != "PASS":
        print("TB_RESULT_BAD %s（装置自己没 PASS ⇒ 后面的字节判据无从谈起）" % result)
        bad += 1

    if mode == "err":
        want = {"WORDS_VALID": 0, "ERR": 1, "AR_COUNT": 0, "RD_BEATS": 0, "WRITE_CHAN_BAD": 0,
                "AR_EXTRA_BAD": 0, "AW_COUNT": 0, "W_BEATS": 0, "B_COUNT": 0}
        for k, v in want.items():
            if st.get(k) != v:
                print("ERR_STAT_BAD %s=%s != %d" % (k, st.get(k), v)); bad += 1
        if mem is None or (mem.get("rd") != "0" or mem.get("wr") != "0" or mem.get("bursts") != "0"):
            print("ERR_MEM_BAD %s（非法入参必须零搬运）" % mem); bad += 1
        else:
            print("ERR_MEM_OK rd=0 wr=0 bursts=0（入参非法 ⇒ 一个字节都没搬）")
        if arb:
            print("ERR_ARB_BAD 竟然发了 %d 笔 AR" % len(arb)); bad += 1
        print("ERR_VIEW WORDS_VALID=%s ERR=%s AR_COUNT=%s RD_BEATS=%s WRITE_CHAN_BAD=%s"
              % (st.get("WORDS_VALID"), st.get("ERR"), st.get("AR_COUNT"),
                 st.get("RD_BEATS"), st.get("WRITE_CHAN_BAD")))
        print("ERR JUDGE_EXTRA=%d" % bad)
        return 1 if bad else 0

    # ---- 再取表（re-entrancy）：一笔仿真两次 go/两笔 AR；第二项字与它**自己的**黄金期望逐字对账 ----
    # 参数口径：judge.py refetch <log> <meta> <idx1> <idx2> <addr1> <addr2>
    if mode == "refetch":
        idx2  = int(sys.argv[5])
        addr1 = int(sys.argv[6])
        addr2 = int(sys.argv[7])
        mw2, _mf2 = parse_meta(meta, idx2)
        wb1 = bad_word_list(lw, mw)          # 第一项 == 自己的黄金
        wb2 = bad_word_list(lw2, mw2)        # 第二项 == 自己的黄金（不许是第一项的残留）
        print("LABEL 再取表(refetch) MODE refetch IDX1 %d IDX2 %d" % (idx, idx2))
        print("REFETCH_W1_BAD %d DIFF %s（第一项 W0..W7 == 黄金）" % (len(wb1), wb1 if wb1 else "[]"))
        print("REFETCH_W2_BAD %d DIFF %s（第二项 W0..W7 == 它自己的黄金）" % (len(wb2), wb2 if wb2 else "[]"))
        if len(wb1):
            bad += 1
        if len(wb2):
            bad += 1
        # 装置自报的再取表状态：words_valid 先落后起 / busy 收尾回 0 / 两笔 AR / 8 拍 R
        want2 = {"VALID_DIP": 1, "WORDS_VALID": 1, "ERR": 0, "BUSY_FINAL": 0,
                 "AR_COUNT": 2, "RD_BEATS": 8}
        for k, v in want2.items():
            if st2.get(k) != v:
                print("REFETCH_STAT_BAD %s=%s != %d" % (k, st2.get(k), v)); bad += 1
        for i in range(8):
            print("  R2W%d_VIEW rtl=%08x exp=%08x%s"
                  % (i, lw2.get(i, -1) & 0xFFFFFFFF, mw2[i],
                     "" if lw2.get(i) == mw2[i] else "   <== 不符"))
        if arb != [(addr1, 3), (addr2, 3)]:
            print("REFETCH_AR_SEQ_BAD got=%s expect=[(0x%x, 3), (0x%x, 3)]" % (arb, addr1, addr2))
            bad += 1
        else:
            print("AR_SEQ_OK [(0x%08x, arlen=3), (0x%08x, arlen=3)] = 两笔 32 B" % (addr1, addr2))
        want_mem = {"rd": "64", "wr": "0", "bursts": "2", "maxburst": "4"}
        if mem != want_mem:
            print("REFETCH_MEM_BAD %s != %s" % (mem, want_mem)); bad += 1
        else:
            print("MEM_OK rd=64 wr=0 bursts=2 maxburst=4（两笔各 32 B）")
        print("JUDGE_EXTRA %d" % bad)
        return 1 if bad else 0

    # ---- 期望（按模式给"变异后的预测值"；不是"只要不一样就算过"）----
    # 参数口径：judge.py <mode> <log> <meta> <idx> <addr> [<bit>]
    exp = list(mw)
    if mode == "pos":
        label = "正对照"
    elif mode == "mut_w6":
        exp[6] = mw[6] ^ (1 << int(sys.argv[6]))          # w6 翻一个 bit（bit 号在 argv[6]）
        label = "负对照A(w6 bit flip)"
    elif mode == "mut_swap45":
        exp[4], exp[5] = mw[5], mw[4]                     # w4/w5 对调
        label = "负对照A2(w4/w5 对调)"
    elif mode == "mut_bswap1":
        exp[1] = bswap32(mw[1])                           # w1 字节反转
        label = "负对照A3(w1 字节反转)"
    elif mode == "mut_pairs":
        # 网表突变（拍内低/高 4 字节对调）⇒ 相邻两个字整体对调
        for k in range(4):
            exp[2 * k], exp[2 * k + 1] = mw[2 * k + 1], mw[2 * k]
        label = "网表突变(拍内低/高 4 字节对调)"
    elif mode == "mut_stride":
        label = "网表突变(STRIDE 切片 w3[11:8] -> w3[15:12])"
    elif mode == "cmp_self":
        exp[3] = mw[3] ^ 1                                # 比较器自检：扰动一个期望字
        label = "比较器自检(扰动期望 W3)"
    else:
        raise SystemExit("unknown mode %s" % mode)

    wb = bad_word_list(lw, exp)              # 对**本模式的期望**（变异后）的差异
    wb_vs_gold = bad_word_list(lw, mw)       # 对**黄金**期望的差异（用来点名"哪几个字被动了"）
    # 期望的 WORD_BAD：正对照/变异模式必须 **0**（RTL 恰好落在预测值上）；
    #                  比较器自检必须 **1**（扰动了一个期望字 ⇒ 逐字对账当场发火 —— 这才是要证的）。
    want_wb = 1 if mode == "cmp_self" else 0
    if not lw:
        print("WORD_MISSING 日志里没有 WORDS 行（装置没打到）"); bad += 1
    if len(wb) != want_wb:
        print("WORD_BAD_EXP_BAD got=%d want=%d（逐字对账没按预期发火/通过）" % (len(wb), want_wb))
        bad += 1
    print("LABEL %s MODE %s IDX %d" % (label, mode, idx))
    print("WORD_BAD %d (want %d) DIFF_IDX %s" % (len(wb), want_wb, wb if wb else "[]"))
    print("WORD_DIFF_VS_GOLD %d DIFF_IDX_VS_GOLD %s"
          % (len(wb_vs_gold), wb_vs_gold if wb_vs_gold else "[]"))
    for i in range(8):
        print("  W%d_VIEW rtl=%08x exp=%08x gold=%08x%s"
              % (i, lw.get(i, -1) & 0xFFFFFFFF, exp[i], mw[i],
                 "" if lw.get(i) == exp[i] else "   <== 不符"))
    for m in wb:
        print("  WORD_DIFF W%d rtl=%08x exp=%08x" % (m, lw.get(m, -1) & 0xFFFFFFFF, exp[m]))

    # ---- 字段级交叉对账：按模式给"变异后**应该**译出的字段"，再与**黄金**（unpack）各比一次 ----
    RLT = dict(FMAP)
    f_exp = None
    if mode == "pos":
        f_exp = dict(mf)                                  # 正对照：逐字段 == unpack
    elif mode == "mut_w6":
        f_exp = dict(mf); f_exp["IN_BYTES"] = mf["IN_BYTES"] ^ (1 << int(sys.argv[6]))
    elif mode == "mut_stride":
        f_exp = dict(mf); f_exp["STRIDE"] = mf["PAD"]     # 切片被改成 PAD 的位段 ⇒ STRIDE 跟着变
    if f_exp is None:
        print("FIELD_BAD -（本模式不查字段：字本身被变异了）")
        print("FIELD_DIFF_VS_GOLD -（本模式不查字段）")
    else:
        fbad = [(pyk, RLT[pyk]) for pyk, _ in FMAP if lf.get(RLT[pyk]) != f_exp[pyk]]
        fgold = [pyk for pyk, _ in FMAP if lf.get(RLT[pyk]) != mf[pyk]]
        print("FIELD_BAD %d（对照 %d 个字段）" % (len(fbad), len(FMAP)))
        for pyk, rtlk in fbad:
            print("  FIELD_DIFF %s(rtl %s=%s) != 预测 %s" % (pyk, rtlk, lf.get(rtlk), f_exp[pyk]))
        print("FIELD_DIFF_VS_GOLD %d DIFF_FIELDS %s" % (len(fgold), fgold if fgold else "[]"))
        if fbad:
            bad += 1

    # ---- AR 序列 + 内存模型交叉对账 ----
    if mode != "cmp_self":
        addr = int(sys.argv[5])
        if arb != [(addr, 3)]:
            print("AR_SEQ_BAD got=%s expect=[(0x%x, 3)]" % (arb, addr)); bad += 1
        else:
            print("AR_SEQ_OK [(0x%08x, arlen=3)] = 一笔 32 B（4 拍）" % addr)
        want_mem = {"rd": "32", "wr": "0", "bursts": "1", "maxburst": "4"}
        if mem != want_mem:
            print("MEM_BAD %s != %s" % (mem, want_mem)); bad += 1
        else:
            print("MEM_OK rd=32 wr=0 bursts=1 maxburst=4（与模型独立计数一致）")
        for k, v in (("WORDS_VALID", 1), ("ERR", 0), ("AR_COUNT", 1), ("RD_BEATS", 4),
                     ("WRITE_CHAN_BAD", 0), ("AR_EXTRA_BAD", 0), ("BUSY_SEEN", 1),
                     ("BUSY_FINAL", 0)):            # M3：busy 收尾回 0
            if st.get(k) != v:
                print("STAT_BAD %s=%s != %d" % (k, st.get(k), v)); bad += 1

    print("JUDGE_EXTRA %d" % bad)
    return 1 if bad else 0


sys.exit(main())
PYEOF

# ===========================================================================
# 4) 正对照：4 个代表项（0/1/5/67）各跑一次 —— 逐字 + 逐字段 + 交叉对账
# ===========================================================================
echo "---- 4) 正对照：idx ∈ {$TEST_IDX}（ADDR=BASE+32*idx）----"
for I in $TEST_IDX; do
  DA=$(( ADDR_BASE + 32 * I ))
  sim "pos$I.log" "$DA" "$work/mem_gold.hex"; RC=$?
  if [ "$RC" -ne 0 ] || ! grep -q '^RESULT: PASS' "$work/pos$I.log"; then
    echo "JUDGE-RED: 正对照 idx=$I 装置未 PASS（vvp rc=$RC）"
    grep -E '^(RESULT|TBFAIL|ARB|TBSTAT|MEM )' "$work/pos$I.log" || true
    exit 1
  fi
  if ! "$PY" "$work/judge.py" pos "$work/pos$I.log" "$work/meta.txt" "$I" "$DA" > "$work/jp$I.out" 2>&1; then
    echo "JUDGE-RED: 正对照 idx=$I 判据不符"; cat "$work/jp$I.out"; exit 1
  fi
  grep -E '^(LABEL|WORD_BAD|WORD_DIFF_VS_GOLD|FIELD_BAD|AR_SEQ_OK|MEM_OK|JUDGE_EXTRA)' "$work/jp$I.out" || true
  grep -E '^  W[0-7]_VIEW' "$work/jp$I.out" || true
done
echo "正对照 PASS：4/4 项的 W0..W7 与 desc_table 期望**逐字**相等，17 个字段**逐字段**与 unpack 相等"

# ===========================================================================
# 4b) 再取表（re-entrancy）：**一笔仿真内发两次 go**（不同地址，idx 1 -> idx 5）
#     把"重入守卫 / 新 go 清 validR / DONE->IDLE 再武装（= I1 的那个窗口）"全部走一遍。
#     ★ **时序命门**：第二个 `go` 必须落在 `busy` **首次落 0 的那一拍**（同拍），不许先空等 idle 拍。
#       那一拍正是 I1 修的死区：`busyR` 在 DONE 落 0、比内部 `DdrMaster` 回 IDLE 早一拍；若 `io.busy`
#       只出 `busyR`（丢掉 `|| ddrMaster.busy`），IDLE 态的 `io.go && !ddrMaster.io.busy` 守卫仍为假
#       ⇒ 这拍脉冲被**静默吞掉**（`go` 单拍、无重试）⇒ 第二笔取表永不发生。装置按此口径发第二个 `go`
#       （见 rtl_test/DescTb.v 的 `+REFETCH` 段），于是本作业**对 I1 敏感**：回退 I1 即红（超时 ⇒
#       无 `RESULT: PASS` ⇒ 上面 exit 1），不再"恒绿"。
#     判据（装置 + 本闸门都独立算，不盲信）：
#       · words_valid **先落 0 再起**（VALID_DIP=1：新 go 确实清了 validR）；
#       · 第二项 W0..W7 == **它自己的**黄金期望（不是第一项的残留）；
#       · AR 序列 == [(A1,arlen=3),(A2,arlen=3)]（**两笔**各 32 B）；RD_BEATS==8；MEM rd=64 bursts=2；
#       · busy 收尾回 0（BUSY_FINAL=0）。
# ===========================================================================
echo "---- 4b) 再取表：同一笔仿真发两次 go（idx 1 -> idx 5，不同地址）----"
RF1=1; RF2=5
RF_A1=$(( ADDR_BASE + 32 * RF1 )); RF_A2=$(( ADDR_BASE + 32 * RF2 ))
sim "refetch.log" "$RF_A1" "$work/mem_gold.hex" "+REFETCH=$RF_A2"; RC=$?
if [ "$RC" -ne 0 ] || ! grep -q '^RESULT: PASS' "$work/refetch.log"; then
  echo "JUDGE-RED: 再取表作业装置未 PASS（vvp rc=$RC）"
  grep -E '^(RESULT|TBFAIL|R2WORDS|R2STAT|WORDS|TBSTAT|ARB|MEM )' "$work/refetch.log" || true
  exit 1
fi
if ! "$PY" "$work/judge.py" refetch "$work/refetch.log" "$work/meta.txt" "$RF1" "$RF2" "$RF_A1" "$RF_A2" > "$work/refetch.out" 2>&1; then
  echo "JUDGE-RED: 再取表作业判据不符"; cat "$work/refetch.out"; exit 1
fi
grep -E '^(LABEL|REFETCH_|AR_SEQ_OK|MEM_OK|JUDGE_EXTRA)' "$work/refetch.out" || true
grep -E '^  R2W[0-7]_VIEW' "$work/refetch.out" || true
echo "再取表 PASS：第二个 go 被受理、words_valid 先落后起、第二项 8 字 == 它自己的黄金、AR 两笔 32 B、RD_BEATS=8、busy 回 0"

# ===========================================================================
# 5) 负对照 A（位敏感）：w6 翻一个 bit ⇒ RTL 必须报**翻过 bit 的那个预测值**
# ===========================================================================
echo "---- 5) 负对照 A：表里 w6 翻第 $W6_FLIP_BIT 位（装置照旧 PASS，字节判据必须发火）----"
sim "negA.log" "$ADDR_BASE" "$work/mem_w6flip.hex"; RC=$?
if [ "$RC" -ne 0 ] || ! grep -q '^RESULT: PASS' "$work/negA.log"; then
  echo "RESULT: FAIL（负对照 A 的仿真未 PASS：装置本身没问题才有资格谈字节判据）"
  grep -E '^(RESULT|TBFAIL)' "$work/negA.log" || true; exit 2
fi
"$PY" "$work/judge.py" mut_w6 "$work/negA.log" "$work/meta.txt" 0 "$ADDR_BASE" "$W6_FLIP_BIT" > "$work/negA.out" 2>&1
JA=$?
cat "$work/negA.out"
# 两条独立证据：①WORD_BAD=0（RTL 恰好落在**翻 bit 后的预测值**上）；②与**黄金**期望比恰好 1 个字 = W6
NA_WB="$(sed -n 's/^WORD_BAD \([0-9]*\) (want.*$/\1/p' "$work/negA.out" | tail -1)"
NA_DIFF="$(sed -n 's/^WORD_DIFF_VS_GOLD \([0-9]*\) DIFF_IDX_VS_GOLD \(.*\)$/\2/p' "$work/negA.out" | tail -1)"
[ "$JA" -eq 0 ] || { echo "RESULT: FAIL（负对照 A 没发火：RTL 没有报出翻 bit 后的预测值）⇒ 闸门不可信"; exit 2; }
if [ "${NA_WB:-x}" != "0" ] || [ "${NA_DIFF:-x}" != "[6]" ]; then
  echo "RESULT: FAIL（负对照 A：WORD_BAD=${NA_WB:-?}（须 0）DIFF_VS_GOLD=${NA_DIFF:-?}（须 [6]））⇒ 闸门不可信"
  exit 2
fi
echo "NEG_OK[A]: w6 翻 1 bit ⇒ RTL 恰好 W6 一个字与黄金期望不符（其余 7 字逐字不变），且落在**翻 bit 后的预测值**上"

# ===========================================================================
# 6) 负对照 A2/A3（字序 / 字内小端）：预测值必须**精确**命中
# ===========================================================================
echo "---- 6) 负对照 A2：表里 w4/w5 两段对调（RTL 必须报 W4=期望W5、W5=期望W4）----"
sim "negA2.log" "$ADDR_BASE" "$work/mem_swap45.hex"; RC=$?
if [ "$RC" -ne 0 ] || ! grep -q '^RESULT: PASS' "$work/negA2.log"; then
  echo "RESULT: FAIL（负对照 A2 的仿真未 PASS）"; grep -E '^(RESULT|TBFAIL)' "$work/negA2.log" || true; exit 2
fi
if ! "$PY" "$work/judge.py" mut_swap45 "$work/negA2.log" "$work/meta.txt" 0 "$ADDR_BASE" > "$work/negA2.out" 2>&1; then
  echo "RESULT: FAIL（负对照 A2 没发火）⇒ 闸门不可信"; cat "$work/negA2.out"; exit 2
fi
A2_DIFF="$(sed -n 's/^WORD_DIFF_VS_GOLD \([0-9]*\) DIFF_IDX_VS_GOLD \(.*\)$/\2/p' "$work/negA2.out" | tail -1)"
grep -E '^(LABEL|WORD_BAD|WORD_DIFF_VS_GOLD|FIELD_BAD|AR_SEQ_OK|MEM_OK|JUDGE_EXTRA)' "$work/negA2.out"
grep -E '^  W[45]_VIEW' "$work/negA2.out"
[ "${A2_DIFF:-x}" = "[4, 5]" ] || {
  echo "RESULT: FAIL（负对照 A2 的差异字=${A2_DIFF:-?} != [4, 5]）⇒ 闸门不可信"; exit 2; }
echo "NEG_OK[A2]: w4/w5 对调 ⇒ RTL 精确报到「W4=期望的W5、W5=期望的W4」⇒ 取字顺序不是瞎的"

echo "---- 6b) 负对照 A3：表里 w1 的 4 个字节整体反转（RTL 必须报 W1=byteswap(期望W1)）----"
sim "negA3.log" "$ADDR_BASE" "$work/mem_bswap1.hex"; RC=$?
if [ "$RC" -ne 0 ] || ! grep -q '^RESULT: PASS' "$work/negA3.log"; then
  echo "RESULT: FAIL（负对照 A3 的仿真未 PASS）"; grep -E '^(RESULT|TBFAIL)' "$work/negA3.log" || true; exit 2
fi
if ! "$PY" "$work/judge.py" mut_bswap1 "$work/negA3.log" "$work/meta.txt" 0 "$ADDR_BASE" > "$work/negA3.out" 2>&1; then
  echo "RESULT: FAIL（负对照 A3 没发火）⇒ 闸门不可信"; cat "$work/negA3.out"; exit 2
fi
A3_DIFF="$(sed -n 's/^WORD_DIFF_VS_GOLD \([0-9]*\) DIFF_IDX_VS_GOLD \(.*\)$/\2/p' "$work/negA3.out" | tail -1)"
grep -E '^(LABEL|WORD_BAD|WORD_DIFF_VS_GOLD|FIELD_BAD|AR_SEQ_OK|MEM_OK|JUDGE_EXTRA)' "$work/negA3.out"
grep -E '^  W1_VIEW' "$work/negA3.out"
[ "${A3_DIFF:-x}" = "[1]" ] || {
  echo "RESULT: FAIL（负对照 A3 的差异字=${A3_DIFF:-?} != [1]）⇒ 闸门不可信"; exit 2; }
echo "NEG_OK[A3]: w1 字节反转 ⇒ RTL 精确报到「W1=byteswap(期望W1)」⇒ 字内小端不是瞎的"

# ===========================================================================
# 7) 负对照 B（对齐）：未 32 B 对齐的 DESC_ADDR ⇒ err 且零搬运
# ===========================================================================
DA_BAD=$(( ADDR_BASE + 4 ))     # 4096+4：32 B 对齐被破坏（低下 5 位非 0）
echo "---- 7) 负对照 B：+DESC_ADDR=$DA_BAD（未 32 B 对齐）+EXPECT_ERR ----"
sim "negB.log" "$DA_BAD" "$work/mem_gold.hex" +EXPECT_ERR; RC=$?
if [ "$RC" -ne 0 ] || ! grep -q '^RESULT: PASS' "$work/negB.log"; then
  echo "RESULT: FAIL（负对照 B 的仿真未 PASS ⇒ 装置没按预期 err 且零搬运）"
  grep -E '^(RESULT|TBFAIL|TBSTAT|MEM )' "$work/negB.log" || true; exit 2
fi
if ! "$PY" "$work/judge.py" err "$work/negB.log" "$work/meta.txt" 0 > "$work/negB.out" 2>&1; then
  echo "RESULT: FAIL（负对照 B 没发火）⇒ 闸门不可信"; cat "$work/negB.out"; exit 2
fi
grep -E '^(ERR_MEM_OK|ERR_VIEW|ERR JUDGE_EXTRA)' "$work/negB.out"
echo "NEG_OK[B]: DESC_ADDR 未 32 B 对齐 ⇒ ERR=1 / WORDS_VALID=0 / AR_COUNT=0 / RD_BEATS=0 / MEM rd=wr=bursts=0"

# ===========================================================================
# 8) 负对照 C（越界）：32 B 对齐但窗口跨出已建模内存 ⇒ 内存模型必须 $fatal
# ===========================================================================
DA_OOB=$MEMSZ                   # 8192：32 B 对齐，但 8192+32 > MEMSZ(8192) ⇒ 模型越界
echo "---- 8) 负对照 C：+DESC_ADDR=$DA_OOB（窗口跨出 MEMSZ=$MEMSZ）----"
sim "negC.log" "$DA_OOB" "$work/mem_gold.hex"; RC=$?
if grep -q 'AXI-MEM OUT-OF-RANGE' "$work/negC.log"; then
  echo "NEG_OK[C]: 内存模型按预期 fatal（AXI-MEM OUT-OF-RANGE），vvp rc=$RC"
  if [ "$RC" -eq 0 ]; then
    echo "RESULT: FAIL（报出了 fatal 但 vvp 退出码为 0 ⇒ 不能当『响亮失败』用）"; exit 2
  fi
else
  echo "NEG_RED[C]: 越界读没有让内存模型发火（vvp rc=$RC）"
  grep -E '^(RESULT|ARB|TBSTAT|MEM )' "$work/negC.log" || true
  echo "RESULT: FAIL（越界读安静地过了）⇒ 闸门不可信"; exit 2
fi

# ===========================================================================
# 9) 比较器自检：扰动一个期望字 ⇒ 逐字对账必须报**恰好 1** 个字（且就是那一个）
# ===========================================================================
echo "---- 9) 比较器自检：把期望 W3 扰动 1 bit ⇒ 逐字对账必须报恰好 1 个字不符 ----"
if ! "$PY" "$work/judge.py" cmp_self "$work/pos0.log" "$work/meta.txt" 0 > "$work/cmp.out" 2>&1; then
  echo "RESULT: FAIL（比较器自检不过）⇒ 闸门不可信"; cat "$work/cmp.out"; exit 2
fi
CS_WB="$(sed -n 's/^WORD_BAD \([0-9]*\) (want.*$/\1/p' "$work/cmp.out" | tail -1)"
CS_DIFF="$(sed -n 's/^WORD_BAD [0-9]* (want [0-9]*) DIFF_IDX \(.*\)$/\1/p' "$work/cmp.out" | tail -1)"
grep -E '^(LABEL|WORD_BAD|WORD_DIFF_VS_GOLD|JUDGE_EXTRA)' "$work/cmp.out"
if [ "${CS_WB:-x}" != "1" ] || [ "${CS_DIFF:-x}" != "[3]" ]; then
  echo "RESULT: FAIL（比较器自检 WORD_BAD=${CS_WB:-?}（须 1）DIFF_VS_GOLD=${CS_DIFF:-?}（须 [3]））⇒ 闸门不可信"
  exit 2
fi
echo "NEG_OK[cmp_self]: 扰动期望的 W3 一个 bit ⇒ WORD_BAD=1（恰好那一个字）⇒ 逐字对账不是橡皮图章"

# ===========================================================================
# 10) **网表突变**（判据"能发火"的实证；不改源文件，突变件落在 tmp）
#     ① 取字顺序：把每拍的低/高 4 字节对调（= 相邻两个字整体对调）⇒ 8 个字全变，
#        但必须**恰好**是"相邻两字对调"的那个向量（不是"变了就算过"）；
#     ② 译码切片：把 STRIDE 的切片 w3[11:8] 改成 w3[15:12]（PAD 的位段）⇒ **只有 STRIDE**
#        一个字段变（其余 16 个字段与 8 个字一个都不许动）。
# ===========================================================================
echo "---- 10) 网表突变：gen/DescFetch.v 改一处 ⇒ 判据必须精确抓住 ----"
cat > "$work/mknet.py" <<'PYEOF'
import re
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")
nl, out, kind = sys.argv[1], sys.argv[2], sys.argv[3]
src = open(nl, encoding="utf-8").read()
if kind == "pairs":
    # 每拍写两个字的那 8 条语句：把低 4 字节(31:0)与高 4 字节(63:32)对调
    pat = re.compile(r"^(\s*)wReg_(\d) <= ddrMaster_1_rd_data\[(\d+) : (\d+)\];$", re.M)
    swap = {(31, 0): (63, 32), (63, 32): (31, 0)}

    def rep(m):
        hi, lo = int(m.group(3)), int(m.group(4))
        assert (hi, lo) in swap, "意外的切片 %d:%d" % (hi, lo)
        a, b = swap[(hi, lo)]
        return "%swReg_%s <= ddrMaster_1_rd_data[%d : %d];" % (m.group(1), m.group(2), a, b)

    new, n = pat.subn(rep, src)
    print("NETMUT pairs HITS=%d（期望 8：4 拍 x 2 字）" % n)
    if n != 8:
        sys.exit(2)
elif kind == "stride":
    pat = re.compile(r"^(\s*)assign stride = wReg_3\[11 : 8\];$", re.M)
    new, n = pat.subn(r"\1assign stride = wReg_3[15 : 12];", src)
    print("NETMUT stride HITS=%d（期望 1）" % n)
    if n != 1:
        sys.exit(2)
else:
    sys.exit(2)
open(out, "w", encoding="utf-8").write(new)
print("NETMUT %s -> %s" % (kind, out))
PYEOF

netmut() { # <kind> <judge-mode> <期望的 DIFF_IDX_VS_GOLD>
  local kind="$1" jm="$2" want_di="$3"
  echo "---- 10[$kind] 突变网表 + 判据（mode=$jm）----"
  if ! "$PY" "$work/mknet.py" "$nl" "$work/DescFetch_$kind.v" "$kind" > "$work/nm_$kind.gen" 2>&1; then
    echo "RESULT: FAIL（无法构造 $kind 突变网表）⇒ 闸门不可信"; cat "$work/nm_$kind.gen"; exit 2
  fi
  cat "$work/nm_$kind.gen"
  if ! "$IVERILOG" -g2012 -o "$work/nm_$kind.vvp" "$tb" "$memv" "$work/DescFetch_$kind.v" > "$work/iv_nm_$kind.log" 2>&1; then
    echo "RESULT: FAIL（突变网表编译失败）⇒ 闸门不可信"; sed -n '1,30p' "$work/iv_nm_$kind.log"; exit 2
  fi
  ( cd "$work" && "$VVP" "nm_$kind.vvp" "+DESC_ADDR=$ADDR_BASE" "+MEMFILE=$work/mem_gold.hex" \
      > "nm_$kind.log" 2>&1 )
  # 突变**只**动了数据通路/译码，握手与拍数不变 ⇒ 装置**照旧 PASS**（这正是"静默错"的样子）
  if ! grep -q '^RESULT: PASS' "$work/nm_$kind.log"; then
    echo "RESULT: FAIL（$kind 突变把装置改坏了 ⇒ 负对照不成立）"
    grep -E '^(RESULT|TBFAIL)' "$work/nm_$kind.log" || true; exit 2
  fi
  echo "N3 类证据：$kind 突变网表下装置照旧 PASS（$(grep '^MEM ' "$work/nm_$kind.log")）"
  if ! "$PY" "$work/judge.py" "$jm" "$work/nm_$kind.log" "$work/meta.txt" 0 "$ADDR_BASE" > "$work/nm_$kind.out" 2>&1; then
    echo "RESULT: FAIL（$kind 突变**没被**判据抓住）⇒ 闸门不可信"; cat "$work/nm_$kind.out"; exit 2
  fi
  grep -E '^(LABEL|WORD_BAD|WORD_DIFF_VS_GOLD|FIELD_BAD|FIELD_DIFF_VS_GOLD|JUDGE_EXTRA)' "$work/nm_$kind.out"
  local got
  got="$(sed -n 's/^WORD_DIFF_VS_GOLD \([0-9]*\) DIFF_IDX_VS_GOLD \(.*\)$/\2/p' "$work/nm_$kind.out" | tail -1)"
  [ "${got:-x}" = "$want_di" ] || {
    echo "RESULT: FAIL（$kind 突变的差异点=${got:-?} != $want_di）⇒ 闸门不可信"; exit 2; }
  echo "NEG_OK[netmut-$kind]: 突变被**精确**抓住（字的差异点 $got / 期望 $want_di）"
}

# ① 取字顺序突变 ⇒ 差异必须**恰好**是 [0, 1, 2, 3, 4, 5, 6, 7]（相邻两字对调）
netmut pairs  mut_pairs  "[0, 1, 2, 3, 4, 5, 6, 7]"
# ---- M6：netmut-stride 判据的**隐含前提**是"idx 0 的黄金 STRIDE != PAD"。突变把 STRIDE 的切片
#      w3[11:8] 换成 PAD 的位段 w3[15:12]；只有 STRIDE != PAD 时，突变后的 STRIDE 才与黄金不同、
#      FIELD_DIFF_VS_GOLD 才会是 ['STRIDE']。把它**显式钉住** ⇒ 未来表一变、idx 0 恰有 STRIDE == PAD
#      时，这里给**清晰**报错（闸门自身不可信），而不是让 netmut-stride 变成"突变后与黄金一致 ⇒
#      DIFF 为空 ⇒ 误报闸门不可信"。
STR0_PAD0="$("$PY" - "$work/meta.txt" <<'PYEOF'
import sys
for line in open(sys.argv[1], encoding="utf-8"):
    t = line.split()
    if len(t) > 2 and t[0] == "F" and int(t[1]) == 0:
        d = dict(p.split("=", 1) for p in t[2:] if "=" in p)
        print(d.get("STRIDE", "?"), d.get("PAD", "?"))
        break
PYEOF
)"
set -- $STR0_PAD0; SP_STRIDE="${1:-}"; SP_PAD="${2:-}"
if [ -z "$SP_STRIDE" ] || [ -z "$SP_PAD" ] || [ "$SP_STRIDE" = "$SP_PAD" ]; then
  echo "RESULT: FAIL（M6 前提不成立：idx 0 的黄金 STRIDE=${SP_STRIDE:-?} == PAD=${SP_PAD:-?}）"
  echo "        ⇒ netmut-stride 突变后与黄金一致、FIELD_DIFF_VS_GOLD 会变空 ⇒ 判据自相矛盾。"
  echo "        修：换一个 STRIDE != PAD 的 idx（连同下面的 netmut stride 调用一起改），或改突变目标位段。"
  exit 2
fi
echo "M6 前提 OK：idx 0 黄金 STRIDE=$SP_STRIDE != PAD=$SP_PAD（netmut-stride 突变必然偏离黄金）"
# ② 译码切片突变 ⇒ 8 个字一个都不许动（DIFF_IDX_VS_GOLD 必须是 []），只有字段侧报 1 个差异
netmut stride mut_stride "[]"
NM_STRIDE_FG="$(sed -n 's/^FIELD_DIFF_VS_GOLD \([0-9]*\) DIFF_FIELDS \(.*\)$/\2/p' "$work/nm_stride.out" | tail -1)"
[ "${NM_STRIDE_FG:-x}" = "['STRIDE']" ] || {
  echo "RESULT: FAIL（stride 突变的字段差异=${NM_STRIDE_FG:-?} != ['STRIDE']）⇒ 闸门不可信"; exit 2; }
echo "NEG_OK[netmut-stride]: STRIDE 切片突变 ⇒ 8 个字不动、恰好 STRIDE 一个字段被抓（DIFF_FIELDS $NM_STRIDE_FG）"

# ---------------- 收口 ----------------
echo "向量来源 = OK（desc_table.py --emit-hex/--emit-meta；表指纹 $EMIT_MD5 == 冻结值，未漂）"
echo "正对照 = OK（idx ∈ {$TEST_IDX}：8 个字逐字 == 期望；17 个字段逐字段 == unpack；AR 一笔 32 B；MEM rd=32 wr=0）"
echo "再取表 = OK（同一笔仿真两次 go 且第二个 go 落在 busy 首落 0 同拍：words_valid 先落后起、第二项 8 字 == 它自己的黄金、AR 两笔 32 B、RD_BEATS=8、busy 回 0；回退 I1 的 OR ⇒ 本作业超时变红）"
echo "负对照 A[位] = OK（w6 翻 1 bit ⇒ RTL 恰好 W6 不符，且落在翻 bit 后的预测值上）"
echo "负对照 A2[字序] = OK（w4/w5 对调 ⇒ RTL 精确报 W4=期望W5、W5=期望W4）"
echo "负对照 A3[小端] = OK（w1 字节反转 ⇒ RTL 精确报 W1=byteswap(期望W1)）"
echo "负对照 B[对齐] = OK（未 32 B 对齐 ⇒ err 且零搬运：AR_COUNT=0 / RD_BEATS=0 / MEM 全 0）"
echo "负对照 C[越界] = OK（窗口跨出 MEMSZ ⇒ 内存模型 \$fatal、vvp 非 0）"
echo "比较器自检 = OK（扰动一个期望字 ⇒ WORD_BAD=1）"
echo "网表突变 = OK（取字顺序突变 ⇒ 8 个字按预测对调被抓；STRIDE 切片突变 ⇒ 恰好 1 个字段被抓）"
echo "RESULT: PASS"
exit 0
