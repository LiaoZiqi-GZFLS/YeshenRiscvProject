#!/usr/bin/env bash
# run_chaingeom_ab.sh —— ★★ A'-2（2026-10-15）**逐片几何投递 + 逐成员段长/基址 + 帧级指针** 的判据闸门。
#
# 被测行为（`rtl/LayerSched.scala` + `rtl/UnitExec.scala` 的文件头「A'-2」一节；口径 = 计划 Task A'-1）：
#   · **逐片几何**：`LayerSched` 在 `CHAINSCAN` 逐条取回成员描述符时**逐槽锁存**（槽 0 = 链首）并经
#     **新专用端口**送 `UnitExec`（`UnitExec` 在 `go` 那拍把收到的值落寄存器 ⇒ 可回读）；
#   · **逐成员段长/基址**：`UnitExec` 片上推导 `len(k) = ceil32(N_k)`、`base(0) = wgt_dma_addr`、
#     `base(k+1) = base(k) + len(k)`；
#   · **帧级指针**：`LayerSched.wgtPtrR += Σ_k ceil32(N_k)`（B2 的修法；旧式 = `chainLen × N_head`）。
#
# 作业（**异型链**，成员几何逐片不同 —— 正是真表宽 run 的形状）：
#   把冻结 `gen/wgt_index.json` 里真表 run `[4..11]`（`Conv_6 → … → Conv_16`，8 片）的**逐成员 own 几何**
#   （`C_IN/C_OUT/GROUP/TYPE`，= A'-1.3 解冻后表里会写的东西）与**逐成员 `weight.aligned_bytes`**
#   （真 blob 的段长）填进描述符表 ⇒ 跑 `gen/LayerSched.v`（`+EXPECT_ERR`）⇒ 回读并逐槽对账。
#   ★ 本作业**期望 err**：宽链引擎（跑 `chain_len>1` 的宽路）**不在本片**；`UnitExec` 的**引擎互锁**
#     要求链上非首片的 `(C_IN,C_OUT,GROUP,QUANT_SHIFT)` 与链首相等 ⇒ 本作业必**响亮 err + 零搬运**。
#     这正是"几何**投递**到位（可回读）但**引擎未落地**"的诚实形状（见报告）。
#
# 判据（正对照 + 负对照会发火 + 结构）：
#   0) **前提自检**（向量侧，不过 ⇒ exit 3）：真表该 run 的 `weight.offset` 前缀差 == `aligned_bytes` 前缀和
#      （= 冻结转换器的"逐片 32 B 对齐 + 偏移 = 前缀和"契约，即 A'-1.2 的 base(k) 语义）；
#   1) **逐片几何 == 每位成员自己的表值**（LayerSched 锁存 + UnitExec 收到并锁存的两处**各自**对账；
#      8 个槽全部对账 —— 这正是"逐片投递"与旧"链首覆盖"的分水岭）；
#   2) **段长/基址序列 == 冻结转换器的真实逐单元偏移**（`wgt_index.json` 的 `aligned_bytes` / 前缀和；
#      base(0) = `wgt_dma_addr` = 0（本作业未编程 blob 基址）⇒ 相对偏移逐位可比）；
#   3) **帧级推进量 ADVP == Σ_k ceil32(N_k)**（= 真 blob 里该 run 的实际总字节 35872）；
#      ★ PTR（帧指针）在本作业**不得**推进（宽链引擎未落地 ⇒ `go` 即响亮 err ⇒ 无 `done`）——
#      推进量本身（ADVP）已被负对照①钉死；`PTR==0`（err ⇒ 未推进）也当场断言；
#   4) **几何门**：`GATE=2`（引擎互锁 —— 异型链被响亮拦下）+ 零设备搬运（`AW/AW_n128=0`）；
#   5) **负对照（必须发火）**：把网表里的帧级推进回退成"每片都取链首段长"（= B2 旧式）⇒ ADVP 变错 ⇒ 判据红；
#   6) **负对照（必须发火）**：把 `LayerSched` 的槽 0 锁存改坏 ⇒ `UnitExec` 的"槽 0 == 链描述符"断言发火
#      ⇒ `GATE` 从 2 变 1（**断言真的在起作用**）；
#   7) 结构：`check_dangling.py` 对 `gen/LayerSched.v`（零悬空）。
#
# ★ 装置前提：`LayerSchedTb.v` 的 `MAXWGT` 抬到 4096（本作业首片 `N=2304 > 旧上限 1024`；既有作业逐字不变）。
#
# 退出码：0 = 全过；1 = 对账不符/编译或仿真失败/网表不存在；2 = 负对照没发火 ⇒ 闸门自身不可信；
#         3 = 前提/向量自检失败。
set -uo pipefail

PY="${PY:-}"
if [ -z "$PY" ]; then
  for c in /d/code/PDS/NaxYeshenLinux/sim/reglogs/lxvenv/Scripts/python.exe python3 python; do
    if command -v "$c" >/dev/null 2>&1; then PY="$c"; break; fi
  done
fi
[ -n "$PY" ] || { echo "FAIL: 找不到 python（PY=…）"; exit 1; }

here="$(cd "$(dirname "$0")" && pwd)"
gen="$here/../gen"
tb="$here/../rtl_test/LayerSchedTb.v"
memv="$here/../rtl_test/AxiMemModel.v"
nl="$gen/LayerSched.v"
dangling="$here/check_dangling.py"

MEMSZ=2621440
DESC_ADDR=4096
W=160; H=160; CIN=16; COUT=16; SGROUP=1; SHIFT=6
IN_BYTES=409600            # 160*160*16 = 409600（128 的整数倍 ⇒ 字段合法）
SRC=131072                 # 0x020000（32 B 对齐）
DST=1441792                # 0x160000（32 B 对齐）

echo "==== run_chaingeom_ab.sh（A'-2：逐片几何 / 逐成员段长基址 / 帧级指针）===="
echo "网表 = $nl  装置 = $tb"
[ -f "$nl" ] || { echo "FAIL: 网表不存在：$nl"; exit 1; }

echo "---- 0) 结构：check_dangling.py（$nl ⇒ 零悬空）----"
"$PY" "$dangling" "$nl" | tail -2
"$PY" "$dangling" "$nl" | grep -q "RESULT: PASS" || { echo "FAIL: 结构判据不过"; exit 1; }

work="$(mktemp -d)"
KEEP="${KEEP_TMP:-0}"
cleanup() { if [ "$KEEP" = "1" ]; then echo "KEEP_TMP=1 ⇒ $work"; else rm -rf "$work"; fi }
trap cleanup EXIT

echo "---- 1) 造向量：真表 run [4..11] 的逐成员几何 + 真 blob 偏移 ⇒ memfile + 期望值 ----"
"$PY" - "$gen/wgt_index.json" "$work" "$DESC_ADDR" "$MEMSZ" "$IN_BYTES" "$SRC" "$DST" <<'PYEOF'
import json, struct, sys
idx_p, work, desc_addr, memsz, in_bytes, src, dst = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5]), int(sys.argv[6]), int(sys.argv[7])
d = json.load(open(idx_p, encoding='utf-8'))
units = d['units']
RUN = list(range(4, 12))                      # 真表 run [4..11]：Conv_6 … Conv_16（8 片，异型）
mem = bytearray(memsz)
for i in range(memsz):                        # 背景：素周期 251（与 32/128 互素）
    mem[i] = (i * 251 + 17) & 0xFF
words = []
exp = []
for pos, i in enumerate(RUN):
    u = units[i]; own = u['own']; w = u['weight']
    tpe = {'conv3x3': 1, 'conv1x1': 2, 'depthwise': 3}[u['type']]
    fl  = 0x00 if pos == 0 else (0x03 if pos == len(RUN) - 1 else 0x02)
    w0 = tpe | (fl << 8)
    w1 = own['IMG_W'] | (own['IMG_H'] << 16)
    w2 = own['C_IN'] | (own['C_OUT'] << 16)
    w3 = own['GROUP'] | (1 << 8) | (1 << 12)   # GROUP | STRIDE=1 | PAD=1（PAD 不进可链谓词）
    # ★ 占位槽（= 链的片上中间张量，主口看不到）：head/middle 的 `DST`、middle/tail 的 `SRC`。
    #   每个条目必须 `SRC != DST` —— `fieldsOk` 的 `selfLoop` 判据逐条查（WIP 旧稿给 head `DST=SRC`、
    #   给 tail `SRC=DST` ⇒ 都在 FETCHW/CHAINSCANW 被响亮拦下，链根本到不了派发相位）。
    w4 = src if pos == 0 else 196608           # SRC：链首真输入；其余 = 片上占位槽 0x030000
    w5 = 196608 if pos == 0 else dst           # DST：链尾真输出；其余（含 head） = 片上占位槽
    w6 = in_bytes
    w7 = (i << 8) | 6                         # LAYER_ID | QUANT_SHIFT=6
    words.append((w0, w1, w2, w3, w4, w5, w6, w7))
    exp.append((own['C_IN'], own['C_OUT'], own['GROUP'], 6, i, 1 if u['type'] == 'depthwise' else 0,
                1 if u['type'] == 'conv1x1' else 0, w['aligned_bytes']))
# 表落盘（8 项 + 哨兵）
base = desc_addr
for pos, ws in enumerate(words):
    mem[base + pos * 32: base + pos * 32 + 32] = struct.pack('<8I', *ws)
sent = base + len(words) * 32
mem[sent:sent + 32] = struct.pack('<8I', 0xFF, 0, 0, 0, 0, 0, 0, 0)
open(work + '/mem.hex', 'w').write(''.join('%02x\n' % b for b in mem))
# 期望值（段长/基址：base(0) = 0 ⇒ base(k) = Σ_{j<k} len(j)；与冻结 blob 的相对偏移逐位可比）
lens = [e[7] for e in exp]
bases, acc = [], 0
for L in lens:
    bases.append(acc); acc += L
with open(work + '/exp.txt', 'w') as f:
    for k, e in enumerate(exp):
        f.write("SLOT %d %d %d %d %d %d %d %d %d %d\n" % (k, e[0], e[1], e[2], e[3], e[4], e[5], e[6], lens[k], bases[k]))
    f.write("ADVP %d\n" % acc)
    f.write("END %d\n" % acc)
    f.write("DESC_ADDR %d\nDESC_COUNT %d\n" % (desc_addr, len(words)))
    f.write("OFF0 %d\n" % units[RUN[0]]['weight']['offset'])
# ---- ★ 前提自检（A'-1.2 的转换器契约）：真表 `offset` 的前缀差 == `aligned_bytes` 的前缀和。
#   不过 ⇒ 下面的"段长/基址 == 真偏移"判据就立不住 ⇒ exit 3（前提失败，不是被测失败）。
off0 = units[RUN[0]]['weight']['offset']
for k, i in enumerate(RUN):
    o = units[i]['weight']['offset'] - off0
    if o != bases[k]:
        print("VEC-FAIL: slot %d 真偏移差 %d != aligned 前缀和 %d（冻结转换器契约被破坏？）" % (k, o, bases[k]))
        sys.exit(1)
# ---- TB 需要的参数（`+D0..+D7` = 链首 8 字；`+E0..+E7` = 第 2 片 8 字；NENTRY 由 TB 从 D 字算）
open(work + '/d0.args', 'w').write(' '.join(str(x) for x in words[0]) + '\n')
open(work + '/e0.args', 'w').write(' '.join(str(x) for x in words[1]) + '\n')
o0 = units[RUN[0]]['own']
nentry = o0['C_OUT'] * (o0['C_IN'] // o0['GROUP']) * 9
open(work + '/wgt.hex', 'w').write(''.join('%02x\n' % ((k * 37 + 11) & 0xFF) for k in range(nentry)))
print("VEC-OK  run=[4..11]  Σaligned=%d（真 blob 该 run 的段长和）  NENTRY=%d  off0=%d" % (acc, nentry, off0))
PYEOF
[ $? -eq 0 ] || { echo "FAIL: 向量自检不过"; exit 3; }
# 装置必给参数（`LayerSchedTb` 的 `+D*`/`+E*`/`+WGTFILE` 是**硬性**的：缺任一 ⇒ `$fatal`）
read -r D0 D1 D2 D3 D4 D5 D6 D7 < "$work/d0.args"
read -r E0 E1 E2 E3 E4 E5 E6 E7 < "$work/e0.args"

echo "---- 2) iverilog 编译（LayerSchedTb + AxiMemModel + $nl）----"
IV="${IV:-}"
if [ -z "$IV" ]; then for c in /c/msys64/ucrt64/bin/iverilog /usr/bin/iverilog; do [ -x "$c" ] && IV="$c" && break; done; fi
VV="${VV:-}"
if [ -z "$VV" ]; then for c in /c/msys64/ucrt64/bin/vvp /usr/bin/vvp; do [ -x "$c" ] && VV="$c" && break; done; fi
[ -n "$IV" ] && [ -n "$VV" ] || { echo "FAIL: 找不到 iverilog/vvp"; exit 1; }
"$IV" -g2012 -o "$work/a.out" "$tb" "$memv" "$nl" 2>&1 | grep -v "warning:" | head -5
[ -x "$work/a.out" ] || { echo "FAIL: 编译失败"; exit 1; }

run_job() {  # $1 = 网表, $2 = 输出前缀
  local netlist="$1" tag="$2"
  "$IV" -g2012 -o "$work/$tag.out" "$tb" "$memv" "$netlist" 2>&1 | grep -v "warning:" | head -3
  "$VV" "$work/$tag.out" +MEMFILE="$work/mem.hex" +DUMPFILE="$work/$tag.dump" +DESC_ADDR=$DESC_ADDR \
        +DESC_COUNT=8 +CTRL=1 +EXPECT_ERR +SKIP_DESC_CHK +GEOMDUMP +TIMEOUT=200000 \
        +D0=$D0 +D1=$D1 +D2=$D2 +D3=$D3 +D4=$D4 +D5=$D5 +D6=$D6 +D7=$D7 \
        +E0=$E0 +E1=$E1 +E2=$E2 +E3=$E3 +E4=$E4 +E5=$E5 +E6=$E6 +E7=$E7 \
        +WGTFILE="$work/wgt.hex" > "$work/$tag.log" 2>&1
  echo "  $tag: $(grep -c '^TB GEOM' "$work/$tag.log") 行 GEOM 回读；$(grep -E 'RESULT:' "$work/$tag.log" | tail -1)"
}

echo "---- 3) 正对照（异型链：几何逐槽对账 + 段长/基址 + 帧级推进）----"
run_job "$nl" pos
grep -q "RESULT: PASS" "$work/pos.log" || { echo "FAIL: 装置没 PASS（见 $work/pos.log）"; sed -n '1,40p' "$work/pos.log"; exit 1; }

"$PY" - "$work/pos.log" "$work/exp.txt" <<'PYEOF'
import sys
log, expp = open(sys.argv[1], encoding='utf-8', errors='replace').read(), open(sys.argv[2]).read().strip().splitlines()
E = {}
for ln in expp:
    t = ln.split()
    if t[0] == 'SLOT':
        E[int(t[1])] = dict(zip(['cin','cout','grp','qsh','lid','dw','x1','len','base'], map(int, t[2:])))
    elif t[0] in ('ADVP', 'END'):
        E[t[0]] = int(t[1])
bad = []
ls, ue, seg = {}, {}, {}
for ln in log.splitlines():
    t = ln.split()
    if len(t) >= 4 and t[0] == 'TB' and t[1] == 'GEOM':
        if t[2].startswith('SLOT='):
            k = int(t[2][5:]); ls[k] = dict(cin=int(t[3][4:]), cout=int(t[4][5:]), grp=int(t[5][4:]), qsh=int(t[6][4:]),
                                            lid=int(t[7][4:]), dw=int(t[8][3:]), x1=int(t[9][3:]))
        elif t[2].startswith('UE_SLOT='):
            k = int(t[2][8:]); ue[k] = dict(cin=int(t[3][4:]), cout=int(t[4][5:]), grp=int(t[5][4:]), qsh=int(t[6][4:]),
                                            lid=int(t[7][4:]), dw=int(t[8][3:]), x1=int(t[9][3:]))
        elif t[2].startswith('UE_SEG='):
            k = int(t[2][7:]); seg[k] = (int(t[3][4:]), int(t[4][5:]))
        elif t[2] == 'SCHED':
            # `TB GEOM SCHED ADVP=.. PTR=.. UE_END=.. GATE=..` ⇒ t[3..6]（★ 修正：旧稿按 t[4..7] 取，全部错位）
            E['ADVP_RTL'] = int(t[3][5:]); E['PTR'] = int(t[4][4:])
            E['UE_END_RTL'] = int(t[5][7:]); E['GATE'] = int(t[6][5:])
for k, e in E.items():
    if not isinstance(k, int):
        continue
    for src, got in (('SLOT', ls.get(k)), ('UE_SLOT', ue.get(k))):
        if got is None:
            bad.append("%s slot %d 缺回读" % (src, k)); continue
        for f in ('cin','cout','grp','qsh','lid','dw','x1'):
            if got[f] != e[f]:
                bad.append("%s slot %d %s: got=%d exp=%d" % (src, k, f, got[f], e[f]))
    g = seg.get(k)
    if g is None:
        bad.append("UE_SEG slot %d 缺回读" % k)
    else:
        if g[0] != e['len']:  bad.append("UE_SEG slot %d LEN: got=%d exp=%d" % (k, g[0], e['len']))
        if g[1] != e['base']: bad.append("UE_SEG slot %d BASE: got=%d exp=%d" % (k, g[1], e['base']))
if E.get('ADVP_RTL') != E['ADVP']:
    bad.append("ADVP: got=%s exp=%d" % (E.get('ADVP_RTL'), E['ADVP']))
if E.get('UE_END_RTL') != E['END']:
    bad.append("UE_END: got=%s exp=%d" % (E.get('UE_END_RTL'), E['END']))
if E.get('GATE') != 2:
    bad.append("GATE: got=%s exp=2（异型链必须被引擎互锁响亮拦下）" % E.get('GATE'))
if E.get('PTR') != 0:
    bad.append("PTR: got=%s exp=0（err 帧 = 零搬运 ⇒ 帧指针不得推进；推进量由 ADVP 断言）" % E.get('PTR'))
print("回读：LayerSched 槽 %d / UnitExec 槽 %d / 段长基址 %d / ADVP=%s PTR=%s GATE=%s" %
      (len(ls), len(ue), len(seg), E.get('ADVP_RTL'), E.get('PTR'), E.get('GATE')))
print("期望：Σaligned=%d（= 真 blob 该 run 的段长和）" % E['ADVP'])
if bad:
    print("JUDGE-RED（%d 条）：" % len(bad))
    for b in bad[:20]:
        print("   ", b)
    sys.exit(1)
print("JUDGE-GREEN: 逐片几何 == 各成员自己的表值（两处独立回读）；段长/基址 == 冻结 wgt_index 真偏移；ADVP == Σ ceil32(N_k)；GATE=2（引擎互锁）")
PYEOF
[ $? -eq 0 ] || { echo "FAIL: 正对照对账红"; exit 1; }

AW="$(grep -E '^AW_BURSTS' "$work/pos.log" | tail -1)"
echo "  零搬运面：$AW  （必须 total=0）"
echo "$AW" | grep -q "total=0" || { echo "FAIL: 异型链居然搬了字节"; exit 1; }

echo "---- 4) 负对照①（必须发火）：帧级推进回退成"每片都取链首段长"（B2 旧式）----"
sed 's/nWgtAdvR <= chainAdvFetch;/nWgtAdvR <= (chainLenR * chainSegLenR_0);/' "$nl" > "$work/nl_legacy.v"
cmp -s "$nl" "$work/nl_legacy.v" && { echo "FAIL: 负对照①的锚点没命中（网表文本变了？）"; exit 2; }
run_job "$work/nl_legacy.v" neg1
"$PY" - "$work/neg1.log" "$work/exp.txt" <<'PYEOF'
import sys
exp = dict((l.split()[0], int(l.split()[1])) for l in open(sys.argv[2]) if l.split()[0] in ('ADVP',))
log = open(sys.argv[1], encoding='utf-8', errors='replace').read()
got = None
for ln in log.splitlines():
    t = ln.split()
    if len(t) >= 5 and t[0] == 'TB' and t[1] == 'GEOM' and t[2] == 'SCHED':
        got = int(t[3][5:])   # ★ 修正：ADVP 在 t[3]（旧稿按 t[4] 取，错位）
print("  负对照①：ADVP got=%s exp=%d（必须不等 ⇒ 判据有牙）" % (got, exp['ADVP']))
sys.exit(0 if (got is not None and got != exp['ADVP']) else 1)
PYEOF
[ $? -eq 0 ] || { echo "FAIL: 负对照①没发火"; exit 2; }

echo "---- 5) 负对照②（必须发火）：槽 0 锁存改坏 ⇒ UnitExec 的"槽 0 == 链描述符"断言发火（GATE 2->1）----"
sed 's/^\(\s*\)chainCinR_0 <=/\1chainCinR_0 <= 16'"'"'d9; \/\/ APEX-NEG2 : chainCinR_0 <=/' "$nl" > "$work/nl_slot0.v"
cmp -s "$nl" "$work/nl_slot0.v" && { echo "FAIL: 负对照②的锚点没命中"; exit 2; }
run_job "$work/nl_slot0.v" neg2
"$PY" - "$work/neg2.log" <<'PYEOF'
import sys
log = open(sys.argv[1], encoding='utf-8', errors='replace').read()
gate = None; slot0 = None
for ln in log.splitlines():
    t = ln.split()
    if len(t) >= 7 and t[0] == 'TB' and t[1] == 'GEOM':
        if t[2] == 'SCHED':
            gate = int(t[6][5:])   # ★ 修正：GATE 在 t[6]（SCHED 行共 7 token；旧稿按 t[7]/len>=8，永不命中）
        elif t[2] == 'SLOT=0':
            slot0 = int(t[3][4:])
print("  负对照②：GATE got=%s（必须 == 1 = 槽 0 断言发火；正对照为 2）  slot0.cin=%s" % (gate, slot0))
sys.exit(0 if gate == 1 else 1)
PYEOF
[ $? -eq 0 ] || { echo "FAIL: 负对照②没发火"; exit 2; }

echo "---- 6) 收口 ----"
echo "结构       = OK（check_dangling.py：$nl 零悬空）"
echo "逐片几何   = OK（LayerSched 锁存 + UnitExec 收到；逐槽 == 各成员表值）"
echo "段长/基址  = OK（== 冻结 wgt_index 的 aligned_bytes / 前缀和）"
echo "帧级推进   = OK（ADVP == Σ ceil32(N_k)）；负对照①（回退 B2 旧式）已发火"
echo "几何门     = OK（GATE=2 引擎互锁）；负对照②（槽 0 改坏）已发火（GATE=1）"
echo "RESULT: PASS"
exit 0
