#!/usr/bin/env bash
# run_convert_ab.sh —— y1 C4a.3 闸门：**转换器**（`yunet.onnx` → 描述符表 + 权重 blob + M 表 + 索引）。
#
# 为什么需要它：C4a.3 的产物是**整条链的下游输入** —— G6 拿 `wgt_blob.bin`/`wgt_index.json` 装权重、
#   G2 拿表 + blob 逐层对账、C4a.5 拿 `wgt_mult.bin` 做 requant。若转换器本身悄悄产错东西
#   （表非法 / blob 与表错序 / 权重与同口径参考不一致 / M 装错层），后面每一道闸门都会一起错。
#   所以这里先把转换器钉死：字面复用冻结件 + 与 C4a.2 的黄金逐层对账 + 三条能发火的负对照。
#
# ============================== 判据 ==============================
#  0) **冻结件复用**：
#       · 表 = **字面调用** `desc_table.build_table`（本闸门断言它的产物 == 冻结 md5
#         `a45d0da0440a468f1b75788c9ad5bc14`）—— 证明"编码口径"没被重推/改坏；
#       · 位打包 / 哨兵 / 校验 / 往返 = `desc_table.pack_table / pack / unpack / validate`；
#       · 量化口径 = `quant_ptq`；校准参数 + requant 乘子公式 = `quant_ref`。
#  1) **表过 `validate`**（字面调用）+ `pack/unpack` 往返逐字段一致 + 独立字编码一致 + 哨兵自洽；
#     `IN_BYTES` 按 spec §3 的"输入字节"口径；**H1** 把被折进源（Relu 尾声 / Transpose-Reshape 布局）
#     的 `SRC_ADDR` 改到"生产者真正写过的 DST"。⇒ 与 C3 冻结向量的差**只允许**（★ A2 强化版、
#     **验签名**、不放宽）：`{IN_BYTES, SRC_ADDR}`（全部项）∪ `{FLAGS→plain, 6 个几何字段→own}`
#     （**仅被拆的宽 run 成员**，且几何差只允许出现在冻结角色为 middle/tail 的成员上）
#     ⇒ `TABLE_DIFF_FIELDS_ALLOWED ok=1`，且逐项记在 `wgt_index.json.table_diff_vs_c3_frozen`。
#  1b) ★ **H1 正判据**（2026-10-12）：**每个描述符的 `SRC_ADDR` 必须是表序更小的描述符写过的 `DST_ADDR`**
#      —— 即"每个源都写在读之前"（图输入除外）⇒ `SRC_WRITTEN ok=1 checked=67 offenders=0`。
#      负对照：把一条 `SRC_ADDR` 改到一个"从未被写过"的槽位 ⇒ `SRC_WRITTEN ok=0`（`NEGCTL_SRC_ADDR FIRED=1`
#      + 红证据 C `--inject badsrc ⇒ rc=1`）。**这条判据本可以抓到原 bug**（旧表 34 条源指到未写槽位）。
#  1c) ★★ **A2（2026-10-16，spec §5.0）：宽 run 拆融合（de-fuse）** —— 判据组：
#      · `DEFUSE_ALL_PLAIN ok=1`：19 段宽 run 的**每个**成员 `FLAGS==plain`（保留窄 run 全 narrow
#        且角色合法；本网 `kept_narrow=0`）；
#      · `DEFUSE_CHAIN_ADDRS ok=1 checked=33`：每 run 逐成员 `SRC == 前驱 DST`（中间张量有真实地址，
#        来自冻结 bump arena ⇒ 分配器零改动）；
#      · `NEGCTL_DEFUSE_HEAD ... FIRED=1`：把一个被拆成员塞回 `head` ⇒ 正判据必红
#        （+ 红证据 E `--inject baddefuse ⇒ rc=1`）；
#      · `ARENA_FIT ok=1`（**硬门**）：分配器高水位 ≤ NPU 预留区上界 `0x0200_0000`
#        （物理 `0x8040_0000–0x8200_0000`，28 MB）；
#      · `DEFUSE_TRAFFIC`（两向断言，**调用**冻结 `ddr_traffic` 的 strategy，不编辑）：
#        拆前（冻结向量）`decoded==fuse_both 12,576,000`；拆后表 `decoded==baseline 31,942,400`
#        （代价 +19,366,400 B/帧 ⇒ `fps_bandwidth` 21.9386 → 8.6374 @275.9 MB/s）。
#  2) **三态覆盖面表**（覆盖 / 需主机旁路 / 不覆盖）与 **C3 冻结表逐项对账**
#     （ONNX 算子直方图 / TYPE 直方图 conv3x3=7 conv1x1=26 depthwise=20 maxpool=4 resize=2 add=2
#      sigmoid=6 / 载荷 67 / 哨兵 68 / 旁路 4-2-2-6 / 融合 33 边 · 19 链 / FLAGS 直方图 / 整帧流量）；
#     `desc.bin` + `wgt_blob.bin` + `wgt_mult.bin` + `wgt_index.json` 记 md5/字节数 + 两次运行**确定性**。
#  2b) ★ **2026-10-12（B0）：权重 blob 32 B 对齐布局**（spec §4.2 修订）—— 每单元段 `ceil32(N_i)`、
#     起点 = `Σ_{j<i} ceil32(N_j)`、补位 `0`（主口 `DdrMaster` 的 `src%32==0 && len%32==0` 契约，C3.3）。
#     显式断言：blob 404064 B == Σceil32(N_i)（真实 403776 + 补位 288）、53/53 段 32 B 对齐 —— **不静默放宽**。
#  3) **负对照（三条都必须发火）**：
#     a. 改 1 个**权重**字节 ⇒ `wgt_blob.bin` md5 变 **且** 与同口径参考的逐字节对账 MISMATCH>0；
#     b. 改 1 个 **`M`** ⇒ `wgt_mult.bin` md5 与 `requant_mult` 指纹都变（spec §4.4 新增）；
#     c. `desc_count` 与哨兵不符 ⇒ `desc_table.validate` **抛**（含"旧口径 = 表长含哨兵"那一档）。
#  3.5) **§4.5-A 中心化（2026-10-11 裁决）**：权重改对称（`z_w≡0`）+ zero-point 中心化折进转换器。
#     正：取**非折进**的 conv 层（单元 `M` == 黄金节点口径），把真网激活码点喂进硬件算术
#         （`Σ x_q·w_q + bias_adj`、pad=`z_pad`、`((acc·M)>>24)>>6 + z_y`、clamp）⇒ 必须与黄金**逐字节**一致
#         （`CENTER_EQUIV ... MISMATCH=0`），覆盖各 TYPE、含非零 `z_x` 的层；
#     负 a：pad 用**字节 0** 代替 `z_pad` ⇒ MISMATCH>0（1×1 层无补位 ⇒ 只有带 pad 的层贡献，聚合仍必 >0）；
#     负 b：去掉 `−z_x·Σ w_q` 项 ⇒ MISMATCH>0；
#     负 c：翻 1 bit 的 `z_pad`/`bias_adj` ⇒ `centering_fp`（索引指纹）必变。
#  4) **红证据**（证明判据不是橡皮章；跑在 `/tmp` 的输出目录上，不污染 `gen/`）：
#     · `--inject noinbytes` ⇒ `IN_BYTES_RULE ok=0` ⇒ **退出 1**；
#     · `--inject nodiv`     ⇒ `NEGCTL_WEIGHT_FLIP ... FIRED=0` ⇒ **退出 2**；
#     · `--inject badsrc`    ⇒ `SRC_WRITTEN ok=0`（H1 正判据红）⇒ **退出 1**；
#     · `--inject badk`      ⇒ `SRC2_CORRECT ok=0`（E1 正判据红）⇒ **退出 1**；
#     · `--inject baddefuse` ⇒ `DEFUSE_ALL_PLAIN ok=0`（A2 正判据红，validate 同时响亮拦 head 无 tail）⇒ **退出 1**。
#
# 退出码：0 = PASS；1 = 判据红；2 = 负对照没发火；3 = 前置缺失（python / 工具 / 模型 / 黄金 JSON）。
#
# 用法：bash y1/tools/run_convert_ab.sh   （可 PY=<python> 覆盖解释器）
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
cd "$here/.." || { echo "FATAL: 进不去 y1/"; echo "RESULT: FAIL"; exit 3; }
# ★ 全仓唯一可用 Python 组合：**必须**从 y1/ 起、用**相对** PYTHONPATH（Windows Python 不认 /d/... 形式）。
tool="tools/y1_convert.py"
onnx="../third_party/yunet/yunet.onnx"
ref_json="reports/c4a_ref_layers.json"
pydeps="./.pydeps"                             # numpy 2.0.2 / onnx 1.19.1 / onnxruntime 1.19.2
deps="../third_party/yunet/deps"

[ -f "$tool" ] || { echo "FATAL: 缺 $tool"; echo "RESULT: FAIL"; exit 3; }
[ -f "$onnx" ] || { echo "FATAL: 缺模型 $onnx"; echo "RESULT: FAIL"; exit 3; }
[ -f "$ref_json" ] || { echo "FATAL: 缺 C4a.2 黄金 $ref_json（先跑 bash tools/run_quant_ref.sh）"; echo "RESULT: FAIL"; exit 3; }

PY="${PY:-/d/code/PDS/NaxYeshenLinux/sim/reglogs/lxvenv/Scripts/python.exe}"
[ -x "$PY" ] || PY="$(command -v python || command -v python3 || true)"
[ -n "$PY" ] || { echo "FATAL: 找不到 python"; echo "RESULT: FAIL"; exit 3; }

export PYTHONPATH="$pydeps;$deps"
export PYTHONIOENCODING=utf-8

work="$(mktemp -d)"
cleanup() { if [ "${KEEP_TMP:-0}" = "1" ]; then echo "KEEP_TMP=1 => 保留 $work"; else rm -rf "$work"; fi; }
trap cleanup EXIT

echo "== run_convert_ab: PY=$PY =="
echo "   tool=$tool"
echo "   onnx=$onnx"
echo "   ref =$ref_json"
echo "   tmp =$work"

# ---------------- [1] 主跑：转换 + 全部判据（落到 gen/） ----------------
"$PY" "$tool" --gate > "$work/gate.out" 2> "$work/gate.err"
rc=$?
echo "---- [1] y1_convert.py --gate（表 + blob + M 表 + 索引；判据 + 三条负对照） ----"
grep -vE '^COVERAGE_ROW ' "$work/gate.out"
[ -s "$work/gate.err" ] && sed -n '1,20p' "$work/gate.err" >&2

if [ "$rc" -eq 3 ]; then
  echo "JUDGE-RED: 前置缺失（rc=3）"; echo "RESULT: FAIL"; exit 3
fi
if [ "$rc" -eq 2 ]; then
  echo "NEGCTL-FAIL: 负对照没发火（rc=2）"; echo "RESULT: FAIL"; exit 2
fi
if [ "$rc" -ne 0 ] || ! grep -q '^RESULT: PASS$' "$work/gate.out"; then
  echo "JUDGE-RED: 转换器判据未过（rc=$rc）"; echo "RESULT: FAIL"; exit 1
fi

# ---- 逐条把判据抠出来（不靠 RESULT 一个 blurb）----
fail() { echo "JUDGE-RED: $1"; echo "RESULT: FAIL"; exit 1; }
grep -q '^TABLE_VALIDATE ok=1 ' "$work/gate.out"              || fail "表没过 desc_table.validate"
grep -q '^ROUNDTRIP_BAD=0 RAW_WORD_BAD=0 SENTINEL_OK=1$' "$work/gate.out" \
                                                              || fail "pack/unpack 往返或哨兵不自洽"
grep -q '^TABLE_ENCODER_REUSE .* matches=1' "$work/gate.out"   || fail "建表器产物 != C3 冻结 md5（编码口径被动过）"
grep -q '^TABLE_DIFF_FIELDS_ALLOWED ok=1 ' "$work/gate.out" \
                                                              || fail "与 C3 冻结向量的差超出 {IN_BYTES, SRC_ADDR}"
grep -q '^IN_BYTES_RULE ok=1 ' "$work/gate.out"               || fail "IN_BYTES 未按 spec §3 的输入字节口径"
grep -q '^LAYER_ID_EQ_TABLE_IDX ok=1 ' "$work/gate.out"       || fail "LAYER_ID != 表序（§4.4 乘子索引契约）"
grep -q '^BLOB_OFFSET_CUM_SUM ok=1 ' "$work/gate.out"         || fail "权重 offset != Σ_{j<i} N_j（表序隐含权重契约）"
grep -q '^COVERAGE_STATES 覆盖=82 需主机旁路=24 不覆盖=0 nodes=106$' "$work/gate.out" \
                                                              || fail "三态覆盖面的态计数不对"
if grep -q '^COVERAGE_CHECK .* ok=0' "$work/gate.out"; then fail "三态覆盖与 C3 冻结表对不上"; fi
grep -q '^CROSS_REF_SEQ .* problems=0$' "$work/gate.out"      || fail "与 c4a_ref_layers.json 的层序/几何对账红"
grep -q '^XCHECK_WEIGHTS checked=53 mismatch=0 pad_bad=0$' "$work/gate.out" \
                                                              || fail "blob 与同口径参考权重对不上"
grep -q '^REQUANT_FOLD folded_units=15 .* relu_nodes=15$' "$work/gate.out" \
                                                              || fail "15 个 Relu 未全部折进生产者尾声"
grep -q '^NEGCTL_WEIGHT_FLIP .* blob_changed=1 .* FIRED=1$' "$work/gate.out" \
                                                              || fail "负对照 a（改 1 个权重字节）没发火"
grep -q '^NEGCTL_MULT_FLIP .* FIRED=1$' "$work/gate.out"      || fail "负对照 b（改 1 个 M）没发火"
grep -q '^NEGCTL_DESC_COUNT .* FIRED=1$' "$work/gate.out"     || fail "负对照 c（desc_count 与哨兵不符）没发火"
grep -q '^CENTERING units=53 nonzero_z_x=53 z_pad_distinct=[0-9]* z_w_all_zero=1 ' "$work/gate.out" \
                                                              || fail "§4.5 中心化段不完整 / 权重 z_w 非全 0"
grep -q '^CENTER_EQUIV units=[0-9]* elems=[0-9]* nonzero_z_x=[1-9][0-9]* MISMATCH=0 ' "$work/gate.out" \
                                                              || fail "§4.5 正对照红（硬件中心化算术 != 黄金）"
grep -q '^NEGCTL_CENTER_PAD0 mism=[1-9][0-9]* .* FIRED=1$' "$work/gate.out" \
                                                              || fail "§4.5 负对照 a（pad 用字节 0 代替 z_pad）没发火"
grep -q '^NEGCTL_CENTER_DROPTERM mism=[1-9][0-9]* .* FIRED=1$' "$work/gate.out" \
                                                              || fail "§4.5 负对照 b（去掉 −z_x·Σ w_q 项）没发火"
grep -q '^NEGCTL_CENTER_FP_FLIP .* FIRED=1$' "$work/gate.out" \
                                                              || fail "§4.5 负对照 c（翻 1 bit 的 z_pad/bias_adj）没发火"
# ★★ 2026-10-12（B0）：权重 blob 的 **32 B 对齐布局**（DdrMaster `src%32==0 && len%32==0` 契约，spec §4.2 修订）。
#   显式断言（不静默放宽）：真实 ΣN=403776、物理 Σceil32(N)=404064、补位 288 B、段起点 = Σceil32(N_j) 且逐段 32 B 对齐。
grep -q '^WGT_BLOB_BYTES=404064 WGT_BLOB_MD5=[0-9a-f]\{32\} WGT_UNITS=53 SUM_N=403776 SUM_N_ALIGNED=404064 PAD_OVERHEAD=288$' "$work/gate.out" \
  || fail "权重 blob 不是 32 B 对齐布局（blob 字节 / ΣN / Σceil32 / 补位开销 与预期不符）"
grep -q '^BLOB_OFFSET_CUM_SUM ok=1 units=53 total=404064 (aligned)$' "$work/gate.out" \
  || fail "权重段起点 != Σ ceil32(N_j)（或某段非 32 B 对齐）—— 表序隐含的对齐布局契约破裂"
# ★★ H1（2026-10-12）：SRC_ADDR 折进 —— 正判据（每个源都写在读之前）+ 负对照（改一条 SRC ⇒ 必发火）。
grep -q '^SRC_WRITTEN ok=1 checked=67 offenders=0 external=1$' "$work/gate.out" \
  || fail "H1 正判据红：有 SRC_ADDR 不是更早描述符写过的 DST（源写在读之前被破坏）"
grep -q '^NEGCTL_SRC_ADDR .* (须 >0) FIRED=1$' "$work/gate.out" \
  || fail "H1 负对照（改一条 SRC_ADDR）没发火"
# ★★ E1（2026-10-13）：Add 第二路源 = w3[31:16] 的「表内偏移」k（spec §4.6）。
#   正判据：两个 Add 的 k 都 == 表序 − 图推导的生产者表序（SRC2 = 生产者 DST）；负对照：改一个 k ⇒ 必红。
grep -q '^SRC2_CORRECT ok=1 adds=2 offenders=0$' "$work/gate.out" \
  || fail "E1 正判据红：Add 的 SRC2_K 与图推导的生产者不符（SRC2 = DST[idx-k] 语义破裂）"
grep -q '^NEGCTL_SRC2_K .* (须 >0) FIRED=1$' "$work/gate.out" \
  || fail "E1 负对照（改一个 Add 的 k）没发火"
# ★★ A2（2026-10-16，spec §5.0）：宽 run 拆融合（de-fuse）—— 判据组（正 + 地址 + arena 硬门 + 流量两向）
grep -q '^DEFUSE_ALL_PLAIN ok=1 defused_runs=19 offenders=0$' "$work/gate.out" \
  || fail "A2 正判据红：宽 run 成员未全 plain（或缺口变了 ⇒ 重新锚定）"
grep -q '^DEFUSE_CHAIN_ADDRS ok=1 checked=33$' "$work/gate.out" \
  || fail "A2 地址判据红：链中张量的 SRC != 前驱 DST（中间张量没真实地址）"
grep -q '^NEGCTL_DEFUSE_HEAD .* (须 >0) FIRED=1$' "$work/gate.out" \
  || fail "A2 负对照（被拆成员塞回 head）没发火"
grep -q '^ARENA_FIT ok=1 ' "$work/gate.out"                   || fail "A2 arena 硬门红：高水位没装进预留区（BLOCKED）"
grep -q '^DEFUSE_TRAFFIC frozen_baseline=31942400 frozen_fuse_both=12576000 decoded_frozen_base=12576000 decoded_final=31942400 cost=19366400 B/frame (19.37 MB)$' "$work/gate.out" \
  || fail "A2 流量判据红：拆前/拆后的按-flag 流量 != 冻结 fuse_both/baseline"
grep -q '^DEFUSE_FPS fps_bandwidth_fused=21.9386 fps_bandwidth_de_fused=8.6374 ' "$work/gate.out" \
  || fail "A2 fps_bandwidth 重新签发不匹配（21.9386 -> 8.6374）"
echo "   判据 OK：表合法 + 往返 + 冻结件复用自证 + 三态覆盖逐项对账 + 黄金层序/几何/权重一致 + 三条负对照发火"
echo "            §4.5-A 中心化：真网逐字节等价（CENTER_EQUIV MISMATCH=0）+ pad0/dropterm/fp-flip 三条负对照发火"
echo "            ★ B0 对齐布局（2026-10-12）：blob 404064 B = Σ ceil32(N_i)（真实 403776 + 补位 288）；53/53 段 32 B 对齐"
echo "            ★ H1 SRC 折进（2026-10-12）：34 条被折进源的 SRC_ADDR 改到生产者 DST ⇒ SRC_WRITTEN ok=1 offenders=0（负对照发火）"
echo "            ★★ A2 de-fuse（2026-10-16）：19 段宽 run → 52 个 plain（窄 run 保留 0 段）；SRC==前驱 DST 33/33；"
echo "               arena 高水位 0x01C505C0 < 0x02000000（余 3,865,152 B）；流量两向 == 冻结 fuse_both/baseline（代价 +19.37 MB/帧）"

# ---------------- [2] 产物指纹 + 确定性（第二跑逐字节相同） ----------------
for f in gen/desc.bin gen/wgt_blob.bin gen/wgt_mult.bin gen/wgt_index.json; do
  [ -s "$f" ] || fail "产物缺失/为空：$f"
done
gen_md5() { grep -oE "^ARTIFACT (desc|blob|mult|index) .* md5=[0-9a-f]{32}" "$1" | sed -E 's/^ARTIFACT ([a-z]+) .* md5=/\1 /'; }
gen_md5 "$work/gate.out" > "$work/md5_a.txt"
"$PY" "$tool" --gate --out "$work/run2" > "$work/gate2.out" 2>&1
gen_md5 "$work/gate2.out" > "$work/md5_b.txt"
if ! diff -q "$work/md5_a.txt" "$work/md5_b.txt" > /dev/null; then
  echo "  指纹 A:"; sed -n '1,8p' "$work/md5_a.txt"
  echo "  指纹 B:"; sed -n '1,8p' "$work/md5_b.txt"
  fail "两次运行的产物指纹不同（不确定）"
fi
det_ok=1
# 第二跑的 desc.bin / wgt_blob.bin 与 gen/ 下的**逐字节相同**（不只是 md5 自报）
for pair in "desc.bin" "wgt_blob.bin" "wgt_mult.bin"; do
  cmp -s "gen/$pair" "$work/run2/$pair" || det_ok=0
done
[ "$det_ok" -eq 1 ] || fail "第二跑的产物与 gen/ 下的不是逐字节相同"
echo "---- [2] 产物指纹（两次运行逐字节相同 ⇒ 确定性） ----"
while read -r k m; do echo "   $k md5=$m"; done < "$work/md5_a.txt"
echo "   desc.bin     bytes=$(wc -c < gen/desc.bin)    （表：载荷 67 + 哨兵 1 = 68 项 x 32 B）"
echo "   wgt_blob.bin bytes=$(wc -c < gen/wgt_blob.bin) （53 个消费权重的单元，物理 Σ ceil32(N_i)=404064 = 真实 403776 + 补位 288，★ B0 2026-10-12 对齐布局）"
echo "   wgt_mult.bin bytes=$(wc -c < gen/wgt_mult.bin) （67 项 Q24 乘子 M，下标 = 表序 = LAYER_ID）"
echo "   wgt_index.json bytes=$(wc -c < gen/wgt_index.json)"

# ---------------- [3] 红证据（判据能被打红；输出落 tmp，不污染 gen/） ----------------
"$PY" "$tool" --gate --inject noinbytes --out "$work/sab1" > "$work/red1.out" 2>&1
r1=$?
if [ "$r1" -ne 1 ] || ! grep -q '^IN_BYTES_RULE ok=0' "$work/red1.out"; then
  echo "NO-RED: --inject noinbytes 没能让 IN_BYTES 判据变红（rc=$r1）"; echo "RESULT: FAIL"; exit 1
fi
echo "---- [3] 红证据 A：--inject noinbytes ⇒ IN_BYTES_RULE ok=0，rc=$r1 ----"
grep -E '^IN_BYTES_RULE|^IN_BYTES_BAD|^JUDGE-RED' "$work/red1.out" | sed 's/^/    /'

"$PY" "$tool" --gate --inject nodiv --out "$work/sab2" > "$work/red2.out" 2>&1
r2=$?
if [ "$r2" -ne 2 ] || ! grep -q '^NEGCTL_WEIGHT_FLIP .*FIRED=0' "$work/red2.out"; then
  echo "NO-RED: --inject nodiv 没能让负对照判据变红（rc=$r2）"; echo "RESULT: FAIL"; exit 1
fi
echo "---- [3] 红证据 B：--inject nodiv ⇒ NEGCTL_WEIGHT_FLIP FIRED=0，rc=$r2 ----"
grep -E '^NEGCTL_WEIGHT_FLIP|^NEGCTL-FAIL' "$work/red2.out" | sed 's/^/    /'

# [3]C ★ H1：把一条 SRC_ADDR 注入成"从未被写过"的槽位 ⇒ SRC_WRITTEN 必须变红（rc=1）。
"$PY" "$tool" --gate --inject badsrc --out "$work/sab3" > "$work/red3.out" 2>&1
r3=$?
if [ "$r3" -ne 1 ] || ! grep -q '^SRC_WRITTEN ok=0 ' "$work/red3.out"; then
  echo "NO-RED: --inject badsrc 没能让 SRC_WRITTEN 正判据变红（rc=$r3）"; echo "RESULT: FAIL"; exit 1
fi
echo "---- [3] 红证据 C：--inject badsrc ⇒ SRC_WRITTEN ok=0，rc=$r3 ----"
grep -E '^SRC_WRITTEN|^SRC_WRITTEN_BAD|^JUDGE-RED' "$work/red3.out" | sed 's/^/    /'

# [3]D ★ E1：把一个 Add 的 SRC2_K 改错（off-by-one）⇒ SRC2_CORRECT 必须变红（rc=1）。
"$PY" "$tool" --gate --inject badk --out "$work/sab4" > "$work/red4.out" 2>&1
r4=$?
if [ "$r4" -ne 1 ] || ! grep -q '^SRC2_CORRECT ok=0 ' "$work/red4.out"; then
  echo "NO-RED: --inject badk 没能让 SRC2 正判据变红（rc=$r4）"; echo "RESULT: FAIL"; exit 1
fi
echo "---- [3] 红证据 D：--inject badk ⇒ SRC2_CORRECT ok=0，rc=$r4 ----"
grep -E '^SRC2_CORRECT|^SRC2_CORRECT_BAD|^JUDGE-RED' "$work/red4.out" | sed 's/^/    /'

# [3]E ★★ A2：把一个被拆的宽 run 成员的 FLAGS 塞回 `head` ⇒ DEFUSE_ALL_PLAIN 必须变红（rc=1）。
"$PY" "$tool" --gate --inject baddefuse --out "$work/sab5" > "$work/red5.out" 2>&1
r5=$?
if [ "$r5" -ne 1 ] || ! grep -q '^DEFUSE_ALL_PLAIN ok=0 ' "$work/red5.out"; then
  echo "NO-RED: --inject baddefuse 没能让 A2 正判据变红（rc=$r5）"; echo "RESULT: FAIL"; exit 1
fi
echo "---- [3] 红证据 E：--inject baddefuse ⇒ DEFUSE_ALL_PLAIN ok=0（+ validate 响亮拦 head 无 tail），rc=$r5 ----"
grep -E '^DEFUSE_ALL_PLAIN|^DEFUSE_BAD|^TABLE_VALIDATE|^JUDGE-RED' "$work/red5.out" | sed 's/^/    /'

# ---------------- 判决 ----------------
echo "=========================================================================="
echo "转换器（C4a.3 + ★★ A2）："
echo "  接口/契约  = 输入 yunet.onnx + quant_ptq/quant_ref 的每层参数；输出 gen/{desc.bin,"
echo "               wgt_blob.bin, wgt_mult.bin, wgt_index.json}（表序 == blob 序；§4.4 的 M 表随表序）"
echo "  表         = 字面复用 desc_table（建表器产物 == C3 冻结 md5；位打包/校验/往返全绿）"
echo "  三态覆盖   = 覆盖 82（进表 67 + Relu 折进尾声 15）/ 需主机旁路 24（Transpose12+Reshape12）"
echo "               / 不覆盖 0（Concat 本网 0 个）—— 与 C3 冻结表逐项对账一致"
echo "  黄金对账   = 层序 67 项一致；34 项几何逐项对黄金形状；53 个权重（**对称** z_w≡0）与同口径参考逐字节一致"
echo "  负对照     = 权重翻 1 B ⇒ blob md5 变 + 逐字节对账 MISMATCH>0；M 翻 1 bit ⇒ M 表 md5 + 指纹变；"
echo "               desc_count 与哨兵不符 ⇒ validate 抛"
echo "  §4.5-A     = 权重对称 + 中心化落转换器：真网 6 层硬件算术逐字节 == 黄金（MISMATCH=0，含非零 z_x）；"
echo "               pad0 / dropterm / fp-flip 三条负对照全发火；centering 段 53 项（z_pad/bias_adj/刻度）"
echo "  ★★ A2      = 19 段宽 run 拆成 52 个 plain（窄 run 保留 0 段）；SC==前驱 DST 33/33；"
echo "               arena 0x01C505C0 ≤ 0x02000000；流量 == 冻结 fuse_both(拆前)/baseline(拆后)；"
echo "               head-塞回负对照发火；desc_table.py 零改动（A'-1.3 解冻项不适用）"
echo "  红证据     = noinbytes ⇒ rc=1；nodiv ⇒ rc=2；badsrc/badk/baddefuse ⇒ rc=1（判据不是橡皮章）"
echo "  确定性     = 两次运行逐字节相同"
echo "RESULT: PASS"
exit 0
