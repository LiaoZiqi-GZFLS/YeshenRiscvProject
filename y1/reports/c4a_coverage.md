# Y1-C4a.3 报告 —— 转换器（`yunet.onnx` → 描述符表 + 权重 blob + 索引）（**G1 + G2 的表侧**）

**Status: DONE_WITH_CONCERNS（2026-10-11 修订：权重改对称 §4.5-A + 中心化落转换器）**：转换器与闸门都已落地、
判据全绿（`RESULT: PASS` / `exit 0`）、负对照**全部**发火、红证据都跑通；`third_party/**` 与冻结工具
（含已重建的 `quant_ref.py`）**一字未改**。
**必须点名的三处**：① `Relu 折进生产者尾声` 与 C4a.2 的两步参考之间存在**取整级**差异（§7-O1）；
② `QUANT_SHIFT` 字段对旁路项仍是 C3 的**占位值**，而生产 requant 一律 `>>SHIFT(6)` + 乘子 `M`（§7-O2）；
③ `desc.bin` 与 C3 冻结向量**刻意不同**（`IN_BYTES` 7 项，spec §3 的坑）（§4.2）。

> **2026-10-11 变更（本次）**：黄金 `quant_ref` 已按 **§4.5-A** 重建（权重**对称**：`z_w≡0`、`s_w=max|w|/127`、
> `w_q∈[−127,127]`、中心化权重 `c_q=w_q` 恰落 int8，commit `a77efb3`）。本转换器随之：
> ① 权重 blob **消费黄金的对称权重**、1×1 补位抽头填 **0**；② `wgt_index.json` 增 **`centering` 段**
> （逐消费权重的单元：`z_pad`/`bias_adj[]`/`s_x,z_x,s_w,z_w,s_y,z_y`）；③ 闸门增 **§4.5 正对照（真网字节级等价）
> + 三条负对照**。**格式口径**（blob 布局 / `N_i` / 表序 == blob 序）一字未改，只换字节值。

- 上游：`docs/superpowers/specs/2026-10-10-y1-c4-converter-and-coverage-design.md`（§2/§3/§4、**§4.4**）
- 计划：`docs/superpowers/plans/2026-10-10-y1-c4a-converter-and-coverage.md`（Task C4a.3）
- 黄金：`y1/reports/c4a_ref_layers.json` + `y1/tools/quant_ref.py`（C4a.2）
- 冻结真源（只读、只 import）：`y1/tools/desc_table.py`、`y1/tools/ddr_traffic.py`、
  `y1/tools/quant_ptq.py`、`y1/tools/bypass_traffic.py`

---

## 1) 交付物 + 指纹

| 文件 | 说明 | 字节数 | md5 |
|:--|:--|--:|:--|
| `y1/tools/y1_convert.py` | 转换器（复用冻结件；`--gate` 一把跑完判据 + 负对照） | — | — |
| `y1/tools/run_convert_ab.sh` | 闸门（判据 + 确定性 + 红证据 + 退出码 0/1/2/3） | — | — |
| `y1/gen/desc.bin` | 描述符表（**载荷 67 + 哨兵 1 = 68 项**，68 × 32 B） | **2176** | **`06c8c7f7af9856546727957b95b6816a`** |
| `y1/gen/wgt_blob.bin` | 权重 blob（53 个消费权重的单元，Σ `N_i = C_out*(C_in/GROUP)*9`；**对称权重 §4.5-A**，补位填 0） | **403776** | **`2270b6795d46cf551c140164ef862310`** |
| `y1/gen/wgt_mult.bin` | **§4.4 的 `M` 区**：67 项 Q24 乘子，下标 = 表序 = `LAYER_ID` | 268 | `ff2ed3c66041e196718d9c62d8202b7d` |
| `y1/gen/wgt_index.json` | 每单元名字/偏移/字节数 + `requant_mult` 段 + **`centering` 段（§4.5-A）** + `layout_fold` 段 + 指纹 | 186541 | `3a28f1f78eef37cb9bff45151b08bc34` |

（`y1/gen/**` gitignore，不入库；`wgt_mult.bin` 是 §4.4 要求的新增落地物，见 §2。）

派生指纹（都逐次可复算，`wgt_index.json.fingerprints` 里各有一份）：

```
mailbox   = wgt_blob.bin ‖ wgt_mult.bin          bytes=404044  md5=7c1984b04f30c6b3bde4a3e03a193c4d
requant_fp  = sha1({layer_id, M, REQUANT_Q}×67)  = 30c02aba5143be4915b0e3bffd689c4d7f9ca31c
centering_fp= sha1({layer_id, z_pad, bias_adj}×53) = 245f60152605d3a2140e103240de1a2fe8e86cd1
units_fp    = sha1(units 段)                     = 3906a333c224753dc39658da6429844ff4166053
输入模型    = third_party/yunet/yunet.onnx       md5=4ae92eeb150c82ce15ac80738b3b8167
黄金参考    = y1/tools/quant_ref.py              md5=d1c75dc262cfd46bb6f7c66bf93ac159（对称口径，commit a77efb3）
黄金层数据  = y1/reports/c4a_ref_layers.json     md5=3d92c97d3698ac77d2554a95808ce473（权重 aggregate=8d185e21bff2256635e85cc200293eb9）
C3 冻结表   = desc_table 建表器产物              md5=a45d0da0440a468f1b75788c9ad5bc14（本闸门逐次自证）
```

**确定性**：闸门把转换跑两遍（第二遍落临时目录），`desc.bin / wgt_blob.bin / wgt_mult.bin` **逐字节相同**，
四件产物的 md5 也相同。

---

## 2) 冻结接口与契约（Step 1 逐字；文件头同文）

```
输入：yunet.onnx + quant_ptq 的每层参数
输出（落 gen/ 下，gitignore）：
  ① desc.bin    —— 描述符表（复用 desc_table.pack_table；末尾自动哨兵）
  ② wgt_blob.bin—— 权重 blob，按表序连续排布；第 i 个消费权重的单元占用
                   N_i = C_out*(C_in/GROUP)*9 字节，起点 = Σ_{j<i} N_j
  ③ wgt_index.json —— 每个单元的名字/偏移/字节数（供 G6 的装载与 G2 的索引）
契约：表序 == blob 序（R4 的对冲：wgt_index.json + G6 的 blob 指纹 + G2 的逐层对账）
```

**§4.4 的落地（requant 乘子 `M`）**：`M = round( (s_x·s_w/s_y) · 2^(SHIFT+REQUANT_Q) )`、`REQUANT_Q=24`、
`SHIFT=6`（公式**字面复用** `quant_ref.scale_ratio_multiplier` + `quant_ref.REQUANT_Q`，不另写一份）。
`M` 按表序排在权重 blob **之后**（`wgt_index.json.mult.offset_in_mailbox = 403776 = blob.bytes`），
走**既有的** `WGT_ADDR/WGT_DATA/WGT_WE` 信箱，用 `w7[15:8]` 的 `LAYER_ID` 索引 ⇒ **8 字描述符格式一字未改**。

★ **`LAYER_ID` 语义加重（格式不变）**：C3 里它只是"遥测身份 = 表序"，从 C4a.3 起它是**乘子索引**。
闸门逐项断言 `LAYER_ID == 表序下标`（`LAYER_ID_EQ_TABLE_IDX ok=1 checked=67`），
且 `M` 表下标 == 表序 == `LAYER_ID`（`MULT_WORDS=67`）。

**`M` 的三条口径**（都在 `wgt_index.json.requant_mult` 里逐项可查）：

| 单元类型 | `s_y` | 备注 |
|:--|:--|:--|
| conv3x3 / conv1x1 / depthwise | 折进后的**有效输出刻度** `sy_eff` | `ratio = s_x·s_w/sy_eff`；另记 `M_two_step`（不折的口径） |
| maxpool / resize | `sy_eff` | 无权重 ⇒ `s_w = 1`，`ratio = s_x/sy_eff`（与 `quant_ref` 同式） |
| add | `sy_eff` | 两路：主 `M`（input[0]）+ `M2`（input[1]），两个刻度都可不同（与 `quant_ref` 的 `Ma/Mb` 同源） |
| sigmoid | — | 走 256 项 LUT（`quant_ref.sigmoid_lut` 同形）⇒ `M = 0`（6 项，`M_zero(sigmoid)=6`） |

实测 `M` 范围：`M_min=57384`、`M_max=1073741824`（= 2³⁰，ratio 恰好 1.0 的那个 maxpool），全部落在 32 bit 内。

**§4.5-A 的落地（权重对称 + zero-point 中心化 + `centering` 段）**：
权重侧改**对称**量化（`quant_ptq.weight_params`/`quant_weight`，黄金 `quant_ref` 同一份）⇒ 每个权重张量
`z_w ≡ 0`、`s_w = max|w|/127`、`w_q ∈ [−127,127]` ⇒ **中心化权重 `c_q = w_q − z_w ≡ w_q` 恰落 int8**
（**MAC 位宽零改动**）。硬件「中心化」算术（RTL 侧无位宽变化，只在转换器铺索引元数据）：

```
z_w ≡ 0                                    # 对称 ⇒ w_q 本身即中心化权重
z_pad = z_x                                # 补位值 = 真实 0 的码点（不是字节 0），逐层不同
bias_adj = round(bias/(s_x·s_w)) − z_x·Σ_all-taps w_q     # 每输出通道一个常数
hw:  acc = Σ x_q·w_q + bias_adj (pad = z_pad)  ≡  黄金 Σ(x_q−z_x)(w_q−0) + round(bias/(s_x·s_w))
```

`wgt_index.json` 的 **`centering` 段**逐消费权重的单元（53 项）给出：`z_pad`（= 该单元输入激活 `z_x`）、
`bias_adj[]`（每输出通道）、`s_x,z_x,s_w,z_w(=0),s_y,z_y`（+ 硬件口径 `s_y_eff,z_y_eff`、`sum_w_q_all_taps[]`、
`bias_round[]` 供复核）。实测 `nonzero_z_x=53`、`z_pad_distinct=22`（逐层不同 ⇒ 补位值确实**不是**字节 0）、
`z_w_all_zero=1`。**1×1 核的补位抽头一律填 0**（§4.5-A：z_w≡0 ⇒ 中心化零的码点就是 0 ⇒ 零贡献；与旧口径
「填 `z_w`」至此**重合** —— `pad_bad` 判据用黄金 `r["zp"]`（现为 0）作期望，逐单元 `pad_bad=0`）。

---

## 3) 三态覆盖面表（**G1**）—— 与 C3 冻结表**逐项对账**

判据口径（读自 C3 冻结语义，不重推）：**覆盖** = 有冻结 TYPE 码、进描述符表的单元
（`Relu` 亦判覆盖：`spec §2` 的 `✅ 折进生产者尾声`，数据通路有它、不占描述符）；
**需主机旁路** = 不进描述符、由转换器折进寻址（`Transpose/Reshape`），必要时主机搬一次；
**不覆盖** = 既无单元、又无折进办法（`Concat`，本网 0 个）。

| # | 算子 | ONNX 个数 | **三态** | C3 冻结表对账（逐字） | 依据 / 证据 |
|--:|:--|--:|:--|:--|:--|
| 1 | Conv(**conv3x3**) | 7 | **覆盖** | TYPE `0x01` × **7** | `c3_descriptor_format.md` §4.5 的 TYPE 直方图；进表项 |
| 2 | Conv(**conv1x1**) | 26 | **覆盖** | TYPE `0x02` × **26** | 同上 |
| 3 | Conv(**depthwise**) | 20 | **覆盖** | TYPE `0x03` × **20** | 表/编码已覆盖；**本代 RTL 单元待 C4a.6** |
| 4 | MaxPool | 4 | **覆盖** | TYPE `0x10` × **4**；`BYPASS_OPS_FROZEN{maxpool:4}` | C3.6 已交付 + 板上 PASS |
| 5 | Resize | 2 | **覆盖** | TYPE `0x11` × **2**；`{resize:2}` | C3.6 已交付 |
| 6 | Add | 2 | **覆盖** | TYPE `0x13` × **2**；`{add:2}` | C3.7 已交付 |
| 7 | Sigmoid | 6 | **覆盖** | TYPE `0x14` × **6**；`{sigmoid:6}` | C3.7 已交付（256 项 LUT） |
| 8 | Relu | 15 | **覆盖**（折进生产者尾声，不占描述符） | 表内 **0 项**（冻结 TYPE 表无 Relu 码） | `spec §2` 的 `✅`；`REQUANT_FOLD folded_units=15 relu_nodes=15` |
| 9 | Transpose | 12 | **需主机旁路**（折进寻址） | 表内 **0 项** | `layout_fold` 段（18 条，含跨 `Transpose→Reshape` 的链） |
| 10 | Reshape | 12 | **需主机旁路**（折进寻址） | 表内 **0 项** | 同上（线性序不变 ⇒ 换形状/步长） |
| 11 | Concat | 0 | **不覆盖** | 表内 **0 项**（`0x12` 未实现） | 本网 0 个 ⇒ 不阻塞（C4 边界，`spec §7`） |
| | **合计** | **106** | **覆盖 82 / 需主机旁路 24 / 不覆盖 0** | **载荷 67 + 哨兵 1 = 68 项 = 2176 B** | 82 + 24 + 0 = 106 ✓ |

其中"覆盖 82"的分拆（`COVERAGE_SPLIT`）：**进表项 67**（= `desc_table.PAYLOAD_FROZEN`）+ **折进尾声 15**（Relu）。

**闸门里的机器可核对账（`COVERAGE_CHECK`，全部 `ok=1`）**：

```
onnx_op_hist   {'Add':2,'Conv':53,'MaxPool':4,'Relu':15,'Reshape':12,'Resize':2,'Sigmoid':6,'Transpose':12}  == frozen
type_hist      {'conv3x3':7,'conv1x1':26,'depthwise':20,'maxpool':4,'resize':2,'add':2,'sigmoid':6}          == frozen
payload        67 == frozen 67            desc_total   68 == frozen 68
bypass_ops     {'maxpool':4,'resize':2,'add':2,'sigmoid':6} == frozen
covered_items  覆盖项 67 == 载荷 67
flags_hist     {0b00:19, 0b01:15, 0b10:14, 0b11:19} == frozen（A-2 的链角色直方图）
chains         chains=19 runs=19 edges=33 covered=33（= C3/A-3b 的"零拆点、33/33"）
traffic        chain_bytes=12576000 == frozen 12576000（= fuse_both 下界）
```

`Transpose/Reshape` 折进寻址（**不产生单元**）：`wgt_index.json.layout_fold` 给**每个消费者**算
`(src_stride, src_order)`（源头真张量 + 行主要素的轴步长 + `Transpose` 的轴序；`Reshape` 不改线性序）。
例（逐字取自索引）：

```
consumer=Sigmoid_85 layout_ops=['Transpose_78','Reshape_84'] src_tensor=258 src_shape=[1,1,80,80]
                     src_stride=[6400,1,1] src_order=null view_shape=[1,6400,1]
consumer=Reshape_84  layout_ops=['Transpose_78']             src_tensor=258 src_shape=[1,1,80,80]
                     src_stride=[6400,80,1,6400] src_order=[0,2,3,1] view_shape=[1,80,80,1]
```

（★ 这只是**元数据**：C4a.7 才把它落成硬件寻址。）

---

## 4) 判据（`bash y1/tools/run_convert_ab.sh`，逐字收口）

### 4.1 主跑（`y1_convert.py --gate`）

```
CONVERT onnx=yunet.onnx md5=4ae92eeb150c82ce15ac80738b3b8167
CONVERT nodes=106 payload=67 desc_items=68 desc_bytes=2176
TABLE_VALIDATE ok=1 desc_count=67 msg=
ROUNDTRIP_BAD=0 RAW_WORD_BAD=0 SENTINEL_OK=1
COVERAGE_STATES 覆盖=82 需主机旁路=24 不覆盖=0 nodes=106
COVERAGE_SPLIT 进表项=67 折进尾声(Relu)=15
TABLE_BYTES=2176 TABLE_MD5=06c8c7f7af9856546727957b95b6816a
TABLE_ENCODER_REUSE frozen_md5=a45d0da0440a468f1b75788c9ad5bc14 frozen_const=a45d0da0440a468f1b75788c9ad5bc14 matches=1
TABLE_DIFF_VS_C3_FROZEN items=7 fields={'IN_BYTES': 7}
WGT_BLOB_BYTES=403776 WGT_BLOB_MD5=2270b6795d46cf551c140164ef862310 WGT_UNITS=53 SUM_N=403776
WGT_MULT_BYTES=268 WGT_MULT_MD5=ff2ed3c66041e196718d9c62d8202b7d MULT_WORDS=67 REQUANT_Q=24
MAILBOX_BYTES=404044 MAILBOX_MD5=7c1984b04f30c6b3bde4a3e03a193c4d
REQUANT_FP=30c02aba5143be4915b0e3bffd689c4d7f9ca31c UNITS_FP=3906a333c224753dc39658da6429844ff4166053
IN_BYTES_RULE ok=1 checked=67 patched_vs_c3=7
LAYER_ID_EQ_TABLE_IDX ok=1 checked=67
BLOB_OFFSET_CUM_SUM ok=1 units=53 total=403776
CROSS_REF_SEQ kept=67 golden_geom_checked=34 chain_members=33 problems=0
XCHECK_WEIGHTS checked=53 mismatch=0 pad_bad=0
REQUANT_FOLD folded_units=15 M_differs_from_two_step=15 units=67 relu_nodes=15
REQUANT_RANGE M_min=57384 M_max=1073741824 M_zero(sigmoid)=6 SHIFT=6 REQUANT_Q=24
CENTERING units=53 nonzero_z_x=53 z_pad_distinct=22 z_w_all_zero=1 centering_fp=245f60152605d3a2140e103240de1a2fe8e86cd1
CENTERING_PAD_Z_DIST {-128: 27, -61: 1, -22: 1, -21: 1, -10: 1, -8: 1, -6: 1, -5: 1, -4: 3, -2: 1, -1: 1,
                      3: 2, 5: 1, 8: 1, 17: 1, 20: 1, 28: 1, 37: 1, 40: 1, 51: 1, 54: 1, 127: 3}
CENTER_EQUIV units=6 elems=2088000 nonzero_z_x=6 MISMATCH=0 neg_pad0_mism=2132 neg_dropterm_mism=2060966
CENTER_UNIT layer_id=1  Conv_2   conv1x1   z_x=-128 z_pad=-128 M=3011925 elems=1638400 mism=0
CENTER_UNIT_NEG layer_id=1  Conv_2  pad0_mism=0     dropterm_mism=1638400
CENTER_UNIT layer_id=4  Conv_6   conv1x1   z_x=-128 z_pad=-128 M=6782591 elems=409600  mism=0
CENTER_UNIT layer_id=38 Conv_55  conv3x3   z_x= -61 z_pad= -61 M=1423026 elems=6400    mism=0
CENTER_UNIT_NEG layer_id=38 Conv_55 pad0_mism=316   dropterm_mism=6400
CENTER_UNIT layer_id=40 Conv_57  conv3x3   z_x=  28 z_pad=  28 M=4288081 elems=1600    mism=0
CENTER_UNIT layer_id=44 Conv_61  depthwise z_x= -21 z_pad= -21 M=7421197 elems=25600   mism=0
CENTER_UNIT layer_id=46 Conv_63  depthwise z_x= -22 z_pad= -22 M=4618415 elems=6400    mism=0
NEGCTL_CENTER_PAD0  mism=2132 (须 >0) FIRED=1
NEGCTL_CENTER_DROPTERM mism=2060966 (须 >0) FIRED=1
NEGCTL_WEIGHT_FLIP unit=Conv_0 byte_off=0 md5_before=2270b6795d46cf551c140164ef862310 md5_after=1a06f7502c8098af3959a422e92cc7cb blob_changed=1 xcheck_mismatch=2 (须 >0) FIRED=1
NEGCTL_MULT_FLIP layer_id=0 M 57384 -> 57385 mult_md5_changed=1 requant_fp_changed=1 FIRED=1
NEGCTL_DESC_COUNT desc_count=67(sentinel idx=67) incl_sentinel_raise=1 msg='DESC_COUNT 68 != 67' minus1_raise=1 msg='DESC_COUNT 66 != 67' FIRED=1
NEGCTL_CENTER_FP_FLIP z_pad_off=0 z_pad_fp_changed=1 bias_adj_off=0 bias_adj_fp_changed=1 fp_before=245f60152605d3a2140e103240de1a2fe8e86cd1 FIRED=1
ARTIFACT desc       gen/desc.bin bytes=2176 md5=06c8c7f7af9856546727957b95b6816a
ARTIFACT blob       gen/wgt_blob.bin bytes=403776 md5=2270b6795d46cf551c140164ef862310
ARTIFACT mult       gen/wgt_mult.bin bytes=268 md5=ff2ed3c66041e196718d9c62d8202b7d
ARTIFACT index      gen/wgt_index.json bytes=186541 md5=3a28f1f78eef37cb9bff45151b08bc34
RESULT: PASS
   判据 OK：表合法 + 往返 + 冻结件复用自证 + 三态覆盖逐项对账 + 黄金层序/几何/权重一致 + 三条负对照发火
            §4.5-A 中心化：真网逐字节等价（CENTER_EQUIV MISMATCH=0）+ pad0/dropterm/fp-flip 三条负对照发火
```

退出码 **0**。逐条判据（闸门自己再抠一遍，不靠 `RESULT` 一个 blurb）：

| 判据 | 结论 | 事实 |
|:--|:--|:--|
| 表过冻结 `validate` | OK | 字面调用 `desc_table.validate(full, 67, 2^28)`，`desc_count` 口径 = 载荷项数（哨兵在下标 67） |
| `pack`/`unpack` 往返 + 独立字编码 | OK | `ROUNDTRIP_BAD=0 RAW_WORD_BAD=0 SENTINEL_OK=1`（3 条独立实现：往返 / `reference_words` / 保留位为 0） |
| **冻结建表器复用自证** | OK | 第二遍 `desc_table.build_table` 的产物 md5 **== 冻结常量 `a45d0da0…`** ⇒ 编码口径没被重推/改坏 |
| `IN_BYTES` 口径 | OK | 逐项 == `align32(该单元要读的激活字节数)`；与 C3 冻结向量差 **7 项、只差这一个字段** |
| `LAYER_ID` == 表序（§4.4） | OK | 67/67 |
| 权重 offset == `Σ_{j<i} N_j` | OK | 53 单元、总长 403776 == blob 字节数（"表序隐含权重"契约） |
| 与 C4a.2 黄金层序/几何 | OK | 67 项逐项同名同算子；**34 项几何**逐项对黄金形状；33 项链成员对链首 |
| blob ↔ 同口径参考权重 | OK | `checked=53 mismatch=0 pad_bad=0`（逐字节 + 逐点反量化；权重**对称** `z_w≡0`） |
| **§4.5-A 中心化正对照** | OK | 真网 6 个**非折进** conv 层、2,088,000 个输出码点，硬件算术（`Σ x_q·w_q + bias_adj`、pad=`z_pad`、`((acc·M)>>24)>>6 + z_y`）**逐字节 == 黄金**（`MISMATCH=0`），含非零 `z_x` |
| §4.5 负对照 a/b/c | OK | pad0 ⇒ `mism=2132>0`；去 `−z_x·Σw_q` 项 ⇒ `mism=2060966>0`；翻 1 bit 的 `z_pad`/`bias_adj` ⇒ `centering_fp` 变 |
| 三态覆盖对账 | OK | 10 条 `COVERAGE_CHECK` 全 `ok=1`（§3） |
| 确定性 | OK | 两遍运行的 4 件产物逐字节相同 |

### 4.2 `IN_BYTES`：与 C3 冻结向量的**刻意**差异（spec §3 的坑）

`desc_table` 是 C3 的**编码器**，它对 `IN_BYTES` 用的是 `align32(max(Σ读, 写))`；而
spec §3 冻结的是"**conv 的 `IMG_W/IMG_H` 填输出尺寸；旁路算子填输出尺寸 + `IN_BYTES` 填输入字节**"，
且 `rtl/UnitExec.scala:524` 的 `rdLen = dw.inBytes` ⇒ conv 的 `IN_BYTES` 必须**就是输入激活字节数**。
本转换器按 spec §3 逐项改写，**只改这一个字段**（闸门断言"差 ≤ {IN_BYTES}"）：

```
idx=0  Conv_0   (Conv)    1638400 -> 1228800     (输入 = 640×640×3 的图；输出 320×320×16)
idx=6  Conv_9   (Conv)     819200 ->  409600
idx=10 Conv_15  (Conv)    1638400 ->  819200
idx=29 Resize_43(Resize)   102400 ->   25600     (×2 上采样：读 40×40×16、写 80×80×16)
idx=30 Add_44   (Add)      204800 ->  102400     (读一路 = 写)
idx=33 Resize_49(Resize)   409600 ->  102400
idx=34 Add_50   (Add)      819200 ->  409600
```

⇒ `desc.bin` 的 md5 **不等于** C3 的 `--emit-hex` 向量（`06c8…` vs `a45d…`）是**预期的**：
其余 **13 个字段**与冻结向量**逐字节相同**（闸门逐项断言）。**这一改动逐项记在
`wgt_index.json.table_diff_vs_c3_frozen` 里**，供 C3 侧复核。

### 4.3 与 C4a.2 黄金的对账（G2 的表侧精神）

* **层序**：`json.layers` 去掉 `Relu/Transpose/Reshape` 后的子序列（67 项）与表序**逐项同名同算子**；
* **几何**：链首/plain 项（19 头 + 15 plain = **34 项**）的 `(C_IN, C_OUT, IMG_W, IMG_H)` 必须等于黄金的
  张量形状（按冻结 `_chw` 口径：4 维 NCHW 丢 N、非 4 维按扁平单通道）；33 项链中/链尾的表内几何
  = **链首**（冻结口径，`validate` 规则 (5) 同源），其**自有几何**逐项记进 `wgt_index.json.units[*].own`；
* **权重**：blob 读回、用**黄金的对称** `(s_w, z_w≡0)` 反量化（`quant_ref.weights[*]`，即
  `quant_ptq.weight_params ∘ quant_weight`，§4.5-A）⇒ 逐字节/逐点复现黄金参考量化出来的权重（`mismatch=0`）。
  ★ 本转换器**消费黄金的权重**（`w["q"]` / `w["scale"]` / `w["zp"]==0`），并用冻结对称量化器重算**自证**逐字节一致。
  1×1 核按冻结布局 `co*(C_in/G)*9 + ci*9 + ky*3 + kx` 占 **9 字节**（`N_i` 公式），实抽头落 `(ky,kx)=(0,0)`、
  其余 **8 个抽头补 0**（§4.5-A：`z_w≡0` ⇒ 中心化零的码点就是 0；旧口径「补 `z_w`」至此**重合**）
  ⇒ 有效权重 `w_q` 在补位上恰为 0（判据：`pad_bad=0`，用黄金 `r["zp"]`（现为 0）作期望）；
  blob 比"真实权重字节和"大，正是 `N_i` 冻结公式的结果。

### 4.4 §4.5-A 中心化落法（正/负对照，字节级）

**落法**：权重对称（`z_w≡0`）使中心化权重 `c_q = w_q` 恰落 int8 ⇒ **MAC 仍 int8×int8**；zero-point
中心化**折进转换器**（不占 MAC 位宽）：`z_pad = z_x`（补位填真 0 的码点，**不是字节 0**）、
`bias_adj = round(bias/(s_x·s_w)) − z_x·Σ_all-taps w_q`（每输出通道一常数）。硬件
`acc = Σ x_q·w_q + bias_adj`（pad=`z_pad`）**恒等**于黄金 `Σ(x_q−z_x)(w_q−0) + round(bias/(s_x·s_w))`；
1×1 核的 8 个补位抽头填 0（零贡献）。代数证见 `tools/center_equiv_probe.py`（200 组随机、`ALL_EQUAL`，
`z_w≠0` 也成立 ⇒ `z_w=0` 更成立）；本闸门再对**真网**逐字节复核：

* **正对照** `CENTER_EQUIV`：取 6 个**非折进**的 conv 层（各 TYPE 至多 2 个；其单元 `M` == 黄金节点口径
  `M_two_step`，否则折进单元需第二个乘子，见 §7-O1），用黄金整网在该层输入上的**真激活码点**、真权重
  （blob 读回）、`z_pad`/`bias_adj` 走硬件算术 ⇒ **2,088,000 个输出码点逐字节 == 黄金**（`MISMATCH=0`）。
  含 `z_x = -128 / -61 / 28 / -21 / -22` 等非零层（`nonzero_z_x=6`）。
* **负对照 d** `NEGCTL_CENTER_PAD0`：pad 用**字节 0** 代替 `z_pad` ⇒ `mism=2132>0`（**发火**）。
  ★ 1×1 层 `pads=(0,0,0,0)` **无补位** ⇒ 该层不贡献（`pad0_mism=0`）；只有带 pad 的 3×3/dw 层贡献，聚合仍 >0。
* **负对照 e** `NEGCTL_CENTER_DROPTERM`：去掉 `−z_x·Σ w_q` 项（bias 不预调）⇒ `mism=2060966>0`（**发火**）。
* **负对照 f** `NEGCTL_CENTER_FP_FLIP`：翻 1 bit 的 `z_pad` / `bias_adj` ⇒ `centering_fp`
  （进而是 `wgt_index.json` 的指纹）必变（**发火**）。

`centering` 段示例（逐字取自 `wgt_index.json`，层 38 `Conv_55` 的头部若干通道）：

```
layer_id=38 name=Conv_55 in_tensor=257 out_tensor=258
s_x=0.0055788235  z_x=-61   z_pad=-61    s_w=0.0024406757  z_w=0
s_y=0.0102740045  z_y=-103  s_y_eff=0.0102740045  z_y_eff=-103
sum_w_q_all_taps=[854, ...]   bias_round=[17367, ...]   bias_adj=[69461, ...]
```

---

## 5) 负对照（三条，全部发火）+ 红证据

| # | 负对照 | 结果（逐字） |
|--:|:--|:--|
| a | app 里改 **1 个权重字节** | `md5_before=2270b679…` → `md5_after=1a06f750…`，`blob_changed=1`，**`xcheck_mismatch=2 (>0)`**，`FIRED=1` |
| b | app 里改 **1 个 `M`**（§4.4 新增） | `layer_id=0 M 57384 -> 57385`，`mult_md5_changed=1`，`requant_fp_changed=1`，`FIRED=1` |
| c | `desc_count` 与哨兵不符 | `desc_count=68`（旧口径：表长含哨兵）⇒ `raise: 'DESC_COUNT 68 != 67'`；`66` ⇒ `'DESC_COUNT 66 != 67'`，`FIRED=1` |
| **d** | **§4.5 pad 用字节 0**（新） | `NEGCTL_CENTER_PAD0 mism=2132 (>0)`，`FIRED=1` |
| **e** | **§4.5 去掉 −z_x·Σw_q 项**（新） | `NEGCTL_CENTER_DROPTERM mism=2060966 (>0)`，`FIRED=1` |
| **f** | **§4.5 翻 1 bit 的 z_pad/bias_adj**（新） | `NEGCTL_CENTER_FP_FLIP z_pad_fp_changed=1 bias_adj_fp_changed=1`，`FIRED=1` |

红证据（证明上面这些判据**不是橡皮章**；注入跑在临时输出目录，不污染 `gen/`）：

```
---- [3] 红证据 A：--inject noinbytes ⇒ IN_BYTES_RULE ok=0，rc=1 ----
    IN_BYTES_RULE ok=0 checked=67 patched_vs_c3=0
    IN_BYTES_BAD idx=0 Conv_0 got=1638400 expected=1228800
    ...（7 项）
    JUDGE-RED: IN_BYTES 口径红：7 项 != 输入激活字节数
---- [3] 红证据 B：--inject nodiv ⇒ NEGCTL_WEIGHT_FLIP FIRED=0，rc=2 ----
    NEGCTL_WEIGHT_FLIP unit=Conv_0 byte_off=0 md5_before=2270… md5_after=2270… blob_changed=0 xcheck_mismatch=0 (须 >0) FIRED=0
    NEGCTL-FAIL: 改 1 个权重字节没能打红（blob md5 或逐字节对账）
```

第三条红路径（`--inject nofold` ⇒ `folded_units=0 != relu_nodes=15` ⇒ rc=1）也已实跑验证。
§4.5 的三条负对照（d/e/f，见上表）在**主跑 `--gate` 内**真跑并**全部发火**：pad0（`mism=2132>0`）、
dropterm（`mism=2060966>0`）、fp-flip（`centering_fp` 变）；它们同时是**正对照的"牙"** —— 证明
`CENTER_EQUIV MISMATCH=0` 不是橡皮章（口径一偏就红）。

退出码语义：`0` PASS / `1` 判据红 / `2` 负对照没发火 / `3` 前置缺失（python / 工具 / 模型 / 黄金 JSON）。
`run_convert_ab.sh` 里有 `[3]` 两段**真跑**注入：A 段要求 `rc=1`，B 段要求 `rc=2`，达不到就自己红。

---

## 6) 闸门输出收口（`bash y1/tools/run_convert_ab.sh`）

```
== run_convert_ab: PY=…/lxvenv/Scripts/python.exe ==
… [1] 主跑（见 §4.1） …
   判据 OK：表合法 + 往返 + 冻结件复用自证 + 三态覆盖逐项对账 + 黄金层序/几何/权重一致 + 三条负对照发火
            §4.5-A 中心化：真网逐字节等价（CENTER_EQUIV MISMATCH=0）+ pad0/dropterm/fp-flip 三条负对照发火
---- [2] 产物指纹（两次运行逐字节相同 ⇒ 确定性） ----
   desc md5=06c8c7f7af9856546727957b95b6816a
   blob md5=2270b6795d46cf551c140164ef862310
   mult md5=ff2ed3c66041e196718d9c62d8202b7d
   index md5=3a28f1f78eef37cb9bff45151b08bc34
   desc.bin     bytes=2176    （表：载荷 67 + 哨兵 1 = 68 项 x 32 B）
   wgt_blob.bin bytes=403776 （53 个消费权重的单元，Σ N_i = C_out*(C_in/GROUP)*9；对称权重）
   wgt_mult.bin bytes=268 （67 项 Q24 乘子 M，下标 = 表序 = LAYER_ID）
   wgt_index.json bytes=186541
---- [3] 红证据 A … rc=1 ----
---- [3] 红证据 B … rc=2 ----
==========================================================================
转换器（C4a.3）：…
RESULT: PASS
```

退出码 = **0**。

---

## 7) 假设 / 开口项 / 自查

**假设（已按冻结文本裁决，逐条留痕）**

* **A1 表的地址向量原样保留**：`desc_table` 的 `SRC/DST_ADDR` 是"给 C3.4 交叉对账用的确定向量"
  （冻结 docstring 逐字："表的**字段值**不是冻结物，位打包才是…真实转换器应做内存复用"）。
  本任务**不做内存复用**（§4.2 只改 `IN_BYTES`），地址按 bump 分配原样落表 ⇒ 与冻结向量逐字节可比。
* **A2 权重布局按冻结公式 `*9`**：1×1 核也占 9 字节/`(co,ci)`（`N_i = C_out*(C_in/GROUP)*9` 逐字），
  实抽头落 `(ky,kx)=(0,0)`、补位填 **0**（§4.5-A：`z_w≡0` ⇒ 中心化零的码点就是 0；旧口径「补 `z_w`」至此重合）。
  **这需要 C4a.5 的 `Conv3x3Slice/WeightStore` 同口径**（1×1 只迭代 1 个抽头，或 8 个补位抽头因值为 0
  而不加料）。★ 接口项。
* **A5 §4.5-A 中心化的两处口径**：① `bias_adj` 在**转换器侧**算好、逐输出通道落 `wgt_index.json.centering`
  （`round()` 用 `np.round`/banker's rounding，与黄金 `conv_vec` 逐字同源）；② 补位值 `z_pad = z_x`（**不是
  字节 0**）由转换器逐层给出。**RTL 侧需按 `z_pad` 给补位、按 `bias_adj` 初值化累加器**（MAC 仍 int8×int8）
  —— 这是 C4a.5/C4a.6 的实现接口项。
* **A3 bias 不进 blob**：冻结的 8 字描述符里**没有** bias 字段。§4.5-A 起，bias 的**整数**形态是
  `bias_adj = round(bias/(s_x·s_w)) − z_x·Σ_all-taps w_q`（逐输出通道）⇒ 落 `wgt_index.json.centering[*].bias_adj`
  （并保留 `round(bias/(s_x·s_w))` 为 `bias_round`）；浮点 bias 本身仍旧**不**写进任何产物，只在
  `wgt_index.json.units[*].bias` 里记 `{name, shape, md5, in_blob:false}`（53 个，供 C4a.5/C4b 定位）。
  **`bias_adj` 的投递口径是 C4a.5/C4b 的开口项**（可复用同一个权重信箱，或与 `M` 区一样另起一小段）。
* **A4 `Sigmoid` 的量化走 LUT**：`M=0`（6 项），与 `quant_ref.sigmoid_lut` 同形；真表刻度的落法属 C4a.5。

**开口项（点名，不静默）**

* **O1 `Relu` 折进 vs 两步参考的取整差**：冻结口径是"Relu 折进生产者尾声"（spec §2）。
  数值后果 = 生产者的累加器**只做一次** requant 到 `sy_eff`（= 折进后消费者真正读的张量的刻度），
  而 `quant_ref`（C4a.2 黄金）是**两步**（先 requant 到 conv 自刻度、再按 Relu 输出刻度 requant）。
  两者相差**取整级**（正数区域可能差 ±1 码点；负数区域都在 relu 后落到 `z_y`，一致）。
  本文件两者都给出：`requant_mult[*].M`（折进口径，进硬件）与 `M_two_step`（黄金口径）；
  实测 `folded_units=15 / M_differs_from_two_step=15`（恰是网里 15 个 Relu）。
  ⇒ **C4a.4/G3 的逐字节黄金必须决定采用哪一种**（若坚持与 C4a.2 逐字节一致，则 epilogue 需要第二个乘子
  或把 C4a.2 的参考也改成折进口径）。这是本任务**唯一**会影响下游判据的接口项。
  ★ §4.5 正对照为求**与黄金逐字节可比**，只取**非折进**的 conv 层（其单元 `M` == `M_two_step`）；
  折进层同样满足 §4.5 的代数恒等（中心化与 requant 折叠**互相独立**），只是对不上黄金的**两步**节点输出。
* **O2 `QUANT_SHIFT` 字段的旁路占位值**：`desc_table.QUANT_SHIFT_BY_TYPE` 对旁路项给的是
  `maxpool 0 / resize 0 / add 0 / sigmoid 4`（冻结 docstring 明说"本表的**占位口径**，不是生产量化器"），
  而 spec §3 又要求 `QUANT_SHIFT == 网表展开期 SHIFT(6)`，且 §4.4 的 requant 对**所有**单元用 `>>SHIFT(6)`。
  本文件**保持冻结字段值不变**（零改动，`TABLE_DIFF_VS_C3_FROZEN` 只差 `IN_BYTES`），
  生产 requant 由 `M` 表 + `>>REQUANT_Q` + `>>SHIFT` 承担。⇒ **C4a.5 需要一次 spec 口径确认**：
  旁路项的描述符 `QUANT_SHIFT` 是保持占位（0/0/0/4）还是统一改成 6？
* **O3 折进后的 `DST_ADDR`**：折叠会让生产者实际写"折进后的张量"，但 A1 说地址向量原样保留
  ⇒ 表里 `DST_ADDR` 仍是生产者**自身**输出张量的槽位，与"折进"在语义上不完全自洽。
  这是 C3 冻结向量的既成事实（地址不承载语义）；**内存复用 + 折进改写 DST 属 C4b/G6**（与 G6 的
  "blob 装载 == blob" 同批做）。本文件不引入第二套地址口径。
  ★ **2026-10-12（H1）已修其 SRC 侧孪生**：`Relu/Transpose/Reshape` 折进后，消费者的 `SRC_ADDR`
  仍指向"从未被写过的折叠视图槽位"（6 个 Sigmoid 的 291/303/… + 28 个 Relu 消费者，共 **34** 项）。
  H1 在**转换器**里把每个消费者的 `SRC_ADDR` 改到"生产者真正写过的 `DST_ADDR`"（详见文末 §H1）。
  **DST 侧**（生产者 DST 仍指向自身张量名，而非折进后张量名）**仍按本条留给 C4b/G6**（地址已不承载语义）。
* **O4 `wgt_mult.bin` 是 Step-1 三件套之外的第四件**：§4.4 要求 `M` 落在"权重 blob 之后"且
  `wgt_index.json` 记它；为了**同时**满足 Step-1 对 `wgt_blob.bin` 的精确尺寸契约
  （`Σ N_i`，闸门逐项断言）与 §4.4 的"M 紧随其后"，本文件把 `M` 单独成 `wgt_mult.bin`
  （`mult.offset_in_mailbox == blob.bytes` ⇒ 信箱里的映像是 `wgt_blob.bin ‖ wgt_mult.bin`，
  指纹 `mailbox_md5`）。G6 的"`WeightStore` 逐字节 == blob"应比 `blob[0:blob.bytes]`。

**自查（findings / concerns）**

1. **判据有没有"自己比自己"？** 有外部锚：① 建表器产物 == **冻结常量** md5；② 三态覆盖比
   **C3 报告**的直方图/载荷数/流量；③ 层序/几何比 **C4a.2 的 JSON 黄金**；④ 权重比 **`quant_ref` 的** `(s,z,q)`；
   ⑤ `IN_BYTES` 比 spec §3 的输入字节口径。没有一条是拿本文件的输出跟自己比。
2. **负对照有牙吗？** 三条都发火，且**红路径实跑**（`noinbytes⇒rc=1`、`nodiv⇒rc=2`、`nofold⇒rc=1`）。
3. **口径复用了冻结件吗？** `desc_table`（表/打包/校验/往返/独立字编码）、`ddr_traffic`（算子序/融合枚举，
   经 `build_table`）、`quant_ptq`（量化）、`quant_ref`（校准参数 + 乘子公式 + `REQUANT_Q`）——
   全部 `import`，无一处重写。`third_party/**` 与四个冻结工具**零改动**（`git status` 只有本任务的新增文件）。
4. **退化守卫**：`wgt_blob.bin` 非空（403776 B）、M 非全零（`M_min=57384`）、
   `wgt_index.json` 的 `layout_fold` 18 条非空、黄金对账 `golden_geom_checked=34 > 0`。
5. **C4 边界**：不做 RTL、不做内存复用、不做反量化浮点 DQ、不做帧率/上板（均属 C4a.4–C4a.8 / C4b）。

---

# Y1-C4a.7 报告 —— 布局算子折进寻址（转换器侧）（**G5**）

**Status: DONE（2026-10-11）**：`Transpose/Reshape` 已折进寻址 `(src_stride, src_order)`（**不产生单元**），
`y1/tools/run_layout_ab.sh` 判据全绿（`RESULT: PASS` / `exit 0`）：**折进 == 显式参考（逐字节）** +
**搬运不增**（两个数都打印）+ **反转 `src_order` 负对照发火**；红证据实跑（rc=2）。
`third_party/**` 与冻结工具（`ddr_traffic.py` / `desc_table.py` / `quant_ref.py` …）**一字未改**。

- 上游：`docs/superpowers/specs/...-design.md` §5 **G5**；计划 `.../2026-10-10-y1-c4a-...md` **Task C4a.7**。
- 依赖（只读、只 import）：`y1/tools/y1_convert.py`（本任务改）、`ddr_traffic.py`（冻结，`GraphView`/`fuse_both`）。

## 1) 交付物 + 指纹

| 文件 | 说明 | 字节数 | md5 |
|:--|:--|--:|:--|
| `y1/tools/y1_convert.py` | 转换器（**改**：`compute_layout_fold` 与验证器共用 `layout_addressing`；新增 `--layout` 闸门） | 80629 | `8c2117cdd821e051159a9867ad6b40de` |
| `y1/tools/run_layout_ab.sh` | G5 闸门（判据 + 确定性 + 红证据 + 退出码 0/1/2/3） | 8672 | `580f311eeb114a95659660b3b01010c4` |

`gen/wgt_index.json`（`layout_fold` 段）**逐字节未变**（md5 仍 `3a28f1f78eef37cb9bff45151b08bc34`）——
本次只**重排**了取口径的函数（`compute_layout_fold` → `layout_addressing`），产物零变化。

## 2) 口径：「折进寻址」是什么

`Transpose/Reshape` 不进描述符（§3：**需主机旁路**，但由转换器**折进寻址**）。折进后：

```
生产者把源头真张量按行主序写进 DDR（线性缓冲）；
消费者不再读「中间张量」，而是按 (src_stride) 直接 strided 读该缓冲 —— 读出 view_shape 张量。
src_stride[k] = 消费侧第 k 条轴在源头线性缓冲里的元素步长；src_order = 链尾 Transpose 的轴序。
```

`y1_convert.py` 新增的验证器（与 `compute_layout_fold` **同一条口径**）：
`layout_addressing`（算 `(view_shape, src_stride, src_order)`）、`folded_read`（按步长读）、
`layout_apply_chain`（显式 numpy 参考）、`layout_verify / layout_traffic / layout_negctl`；
`--layout` 一把跑完判据 + 负对照。

## 3) 判据（`bash y1/tools/run_layout_ab.sh`，逐字收口）

### 3.1 判据 1：折进 == 显式参考（逐字节）

18 个位置（**12 Transpose + 12 Reshape**，12 张源头张量）。对每个位置：源头张量取**唯一 id**
（排列级敏感）与 **int8 图案**两种确定性样本，分别过「显式链（Transpose 用 `perm`、Reshape 用推断形状）」
与「折进寻址读」，逐字节比：

```
LAYOUT_EQUIV entries=18 byte_exact=18 MISMATCH_total=0 elems=151200
```

12 张源头张量与消费侧 `view_shape`（逐字取自 `--layout`）：

| # | 源头 | 源头形状 | Transpose | 消费侧 `view_shape` | stride |
|--:|--:|:--|:--|:--|:--|
| 0/1 | 258 | [1,1,80,80] | Transpose_78(+Reshape_84) | [1,80,80,1] / [1,6400,1] | [6400,80,1,6400] / [6400,1,1] |
| 2/3 | 260 | [1,1,40,40] | Transpose_86(+Reshape_92) | [1,40,40,1] / [1,1600,1] | [1600,40,1,1600] / [1600,1,1] |
| 4/5 | 262 | [1,1,20,20] | Transpose_94(+Reshape_100) | [1,20,20,1] / [1,400,1] | [400,20,1,400] / [400,1,1] |
| 6/7 | 270 | [1,1,80,80] | Transpose_102(+Reshape_108) | [1,80,80,1] / [1,6400,1] | [6400,80,1,6400] / [6400,1,1] |
| 8/9 | 272 | [1,1,40,40] | Transpose_110(+Reshape_116) | [1,40,40,1] / [1,1600,1] | [1600,40,1,1600] / [1600,1,1] |
| 10/11 | 274 | [1,1,20,20] | Transpose_118(+Reshape_124) | [1,20,20,1] / [1,400,1] | [400,20,1,400] / [400,1,1] |
| 12 | 264 | [1,4,80,80] | Transpose_126 | [1,80,80,4] | [25600,80,1,6400] |
| 13 | 266 | [1,4,40,40] | Transpose_133 | [1,40,40,4] | [6400,40,1,1600] |
| 14 | 268 | [1,4,20,20] | Transpose_140 | [1,20,20,4] | [1600,20,1,400] |
| 15 | 276 | [1,10,80,80] | Transpose_147 | [1,80,80,10] | [64000,80,1,6400] |
| 16 | 278 | [1,10,40,40] | Transpose_154 | [1,40,40,10] | [16000,40,1,1600] |
| 17 | 280 | [1,10,20,20] | Transpose_161 | [1,20,20,10] | [4000,20,1,400] |

★ 6 个 `Sigmoid_*` 位置（#1/3/5/7/9/11）的链是 `Transpose → Reshape`，其 `(perm, reshape)`
在**行主序**下**恰好相消**（`Transpose` 只动了 size-1 的轴）⇒ 折进寻址退化成**线性身份读**
（`stride=[n,1,1]`、`order=None`）—— 这也是为什么它们对「轴序反转」不敏感（见 §3.4）。

### 3.2 判据 2：搬运不增（两个数都打印）

口径复用**冻结** `ddr_traffic.GraphView`（激活 int8、1 字节/元素）。
- **折进**：布局算子不存在为单元 ⇒ 自身 DDR 读+写 = **0**；
- **不折进**（对照）：每个布局算子当**显式单元**（读输入 + 写输出）⇒ 24 个算子共 **537600 B**。

```
LAYOUT_TRAFFIC_FOLDED   read=0      write=0      total=0
LAYOUT_TRAFFIC_UNFOLDED read=268800 write=268800 total=537600
LAYOUT_TRAFFIC ops=24 folded_total=0 unfolded_total=537600 delta=537600 not_increased=1
LAYOUT_TRAFFIC_NET fuse_both_folded=12576000 fuse_both_unfolded=13113600 delta=537600
```

整网锚：冻结模型的推荐调度 `fuse_both` = **12576000 B**（= C4a.3 报告的 `chain_bytes`），
折进后**不变**；不折进则 **+537600 B**。⇒ 折进**没有**增加任何 DDR 搬运（`not_increased=1`）。

### 3.3 判据 0：不产生单元 + 与产物对账

```
LAYOUT_NO_UNITS payload_nodes=67 expected=67 layout_in_payload=0 onnx_T=12 onnx_R=12
LAYOUT_INDEX_AGREE ok=1 entries=18 recomputed=18 units_layout_named=0 src=gen/wgt_index.json
```

载荷节点数 == 冻结期望（`Σ C3 TYPE 直方图 = 67`），布局算子**一个都没进载荷**；
重算的 `layout_fold` 与持久化的 `gen/wgt_index.json.layout_fold`（18 条）**逐项一致**。

### 3.4 判据 3：反转 `src_order` ⇒ 必须红

对每个 `src_order != None` 的位置（折进寻址由 `Transpose` 轴序驱动；**12 个**），用**写反的轴序**
重建寻址，与**正确的显式参考**逐字节比 ⇒ 全部发火：

```
NEGCTL_LAYOUT_ORDER reversible=12 fired=12 trivial_insensitive=6
NEGCTL_LAYOUT_ORDER_DETAIL consumer=Reshape_84  src_order=[0,2,3,1] rev=[1,3,2,0] stride_changed=1 mismatch=6320
...（12 条，mismatch 从 380 到 63998）
```

★ **诚实标注**：6 个 `Sigmoid_*` 位置的 `src_order=None`（链由 `Reshape` 收尾 ⇒ 线性序不变），
其折进寻址是**线性身份读**（§3.1 ★）⇒ 任何**轴置换**类改动都不改变映射（`trivial_insensitive=6`）。
判据因此挂在**12 个轴序驱动**的位置上，且要求 `fired == reversible`（一个不漏）。

## 4) 闸门输出收口（`bash y1/tools/run_layout_ab.sh`）

```
== run_layout_ab: Transpose/Reshape folded into (src_stride, src_order) -- G5 ==
---- [1] y1_convert.py --layout（折进==显式 + 搬运不增 + 反转轴序负对照）----
LAYOUT_FOLD entries=18 ops_transpose=12 ops_reshape=12 srcs=12
LAYOUT_EQUIV entries=18 byte_exact=18 MISMATCH_total=0 elems=151200
LAYOUT_TRAFFIC_FOLDED   read=0      write=0      total=0
LAYOUT_TRAFFIC_UNFOLDED read=268800 write=268800 total=537600
LAYOUT_TRAFFIC ops=24 folded_total=0 unfolded_total=537600 delta=537600 not_increased=1
LAYOUT_TRAFFIC_NET fuse_both_folded=12576000 fuse_both_unfolded=13113600 delta=537600
NEGCTL_LAYOUT_ORDER reversible=12 fired=12 trivial_insensitive=6
LAYOUT_NO_UNITS payload_nodes=67 expected=67 layout_in_payload=0 onnx_T=12 onnx_R=12
LAYOUT_INDEX_AGREE ok=1 entries=18 recomputed=18 units_layout_named=0 src=gen/wgt_index.json
RESULT: PASS
   判据 1 OK：18 个位置（12 Transpose + 12 Reshape）折进 (src_stride, src_order) == 显式参考（逐字节）
   判据 2 OK：折进搬运 total=0 B  vs  不折进 total=537600 B（不增）
   判据 3 OK：反转 src_order  12/12  位置发火
---- [2] determinism：两次运行的 fold/traffic 指纹逐字节相同 ----
---- [3] 红证据：--inject nobadorder ⇒ NEGCTL_LAYOUT_ORDER fired=0，rc=2 ----
==========================================================================
RESULT: PASS
```

退出码 **0**。**红证据**：`--layout --inject nobadorder` 关掉反转轴序负对照 ⇒ `fired=0` ⇒ **rc=2**
（证明判据 3 不是橡皮章）。

## 5) 假设 / 开口项 / 自查

**假设**

* **A1 折进寻址就是「strided 读生产者的线性缓冲」**：`src_stride[k]` = 消费侧第 k 轴在源头缓冲里的元素步长，
  消费者**直接读**该缓冲、不落中间张量。RTL 侧（消费者取数）需支持按 `(base, stride, shape)` 的**
  行/列步长**寻址 —— 这是 C4a.5/C4b 的实现接口项（本任务只证 Python 侧口径成立）。
* **A2 测量口径**：判据 1 用**源头真张量**的确定性样本（唯一 id + int8 图案）过显式链 vs 折进读；
  判据 2 用**冻结 `ddr_traffic.GraphView`**（int8、1 B/元素）逐布局算子记 `读+写`。均不污染真网计算。
* **A3 6 个 `Sigmoid_*` 位置在行主序下折进为线性身份**（`Transpose` 只动 size-1 轴）⇒ 对轴序置换不敏感，
  已在判据 3 中**点名**（`trivial_insensitive=6`），不静默当作"发火"。

**开口项**

* **O1 消费者取数硬化**：`(src_stride, src_order)` 尚是**元数据**；把 strided 寻址落到
  `UnitExec`/`DdrMaster` 的取数路径属 C4a.5/C4b（本任务明确不做 RTL）。
* **O2 `src_order` 语义**：链尾若是 `Reshape`（线性序不变），`src_order=None`；此时轴序信息由 `src_stride`
  唯一确定（`Reshape` 把步长重置为行主序）。这是"折进寻址由步长表承载、轴序仅为**出处标注**"的口径。

**自查（findings / concerns）**

1. **判据有没有"自己比自己"？** 有外部锚：① 与 `gen/wgt_index.json.layout_fold`（持久化产物）对账；
   ② 载荷数比 **冻结** `C3 TYPE 直方图`（= 67）；③ 整网锚比 **冻结** `ddr_traffic.fuse_both`（= 12576000）。
2. **负对照有牙吗？** 反转 `src_order` 在 **12/12** 轴序驱动位置上发火（`mismatch` 380–63998）；
   **红路径实跑**（`--inject nobadorder ⇒ rc=2`）。
3. **口径复用了冻结件吗？** 形状/字节数取 `ddr_traffic.GraphView`、整网名取 `ddr_traffic.STRATEGIES`、
   轴序取 `desc_table._node_int_attr` —— 全部 `import`，无一处重写。
4. **退化守卫**：18 条非空、`elems=151200 > 0`、`unfolded_total=537600 > 0`、`reversible=12 > 0`。
5. **C4 边界**：不做 RTL 取数、不做内存复用、不做整帧（均属 C4a.8 / C4b）。

---

# Y1-C4b-H1 报告 —— `SRC_ADDR` 折进（让 `desc.bin` 自洽，每个源都写在读之前）

**Status: DONE（2026-10-12）**：`y1_convert.py` 新增 `apply_src_addr_fold`（**后处理**：把被折进源
——`Relu` 尾声 + `Transpose/Reshape` 布局——的 `SRC_ADDR` 改到"生产者真正写过的 `DST`"）。
`bash y1/tools/run_convert_ab.sh` 全绿（`RESULT: PASS` / `exit 0`），新增**正判据**（`SRC_WRITTEN ok=1
offenders=0`）+ **发火的负对照**（`NEGCTL_SRC_ADDR FIRED=1` + 红证据 C `--inject badsrc ⇒ rc=1`）。
驱动 `npu_frame_run.py` 的 `--fold-src` 改写**归零**（`DRY_FOLD_REWRITES=0`），并变成**复发哨兵**。
`third_party/**` 与冻结工具（`desc_table.py` 等）**一字未改**。

## H1.1 交付物 + 指纹

| 文件 | 说明 | 字节数 | md5 |
|:--|:--|--:|:--|
| `y1/tools/y1_convert.py` | 转换器（**改**：`apply_src_addr_fold` / `check_src_written` + `--inject badsrc`） | — | — |
| `y1/tools/run_convert_ab.sh` | 闸门（**改**：H1 正判据 + 负对照 + 红证据 C；diff 白名单加 `SRC_ADDR`） | — | — |
| `y1/tools/npu_frame_run.py` | 驱动（**改**：`fold_src_rewrite` 从"改写器"变"复发哨兵"，恒返回 []） | — | — |
| `y1/tools/run_frame_ab.sh` | B5 闸门（**改**：`DRY_FOLD_REWRITES=6 → 0`） | — | — |
| `y1/gen/desc.bin` | 描述符表（载荷 67 + 哨兵 1 = 68 项） | **2176** | **`5b525947a997a2bfab2954a61620208e`** |
| `y1/gen/wgt_index.json` | 索引（**新增 `src_addr_fold` 段**：34 条改写 before→after） | **202691** | **`ab5663ffb051da8d3d669e9853b1b3dc`** |

（`wgt_blob.bin`/`wgt_mult.bin` **未变**：`aa135f0f7d50780b7b13d9a1ba9c518a` / `ff2ed3c66041e196718d9c62d8202b7d`
—— H1 只动描述符表里的地址字段，**不碰权重**。）

## H1.2 根因（测自 B5 `555a387`）

`desc_table.build_table` 对每一项取 `SRC_ADDR = slot(node.input[0])`，即**节点原始输入张量**的槽位。
但被折进的算子**不占描述符**：`Relu` 折进**生产者尾声**、`Transpose/Reshape` 折进**寻址** ⇒ 消费者
读的那个"Relu 输出 / 折叠视图"张量**没有任何描述符写过**。全表 **34 项**中招（不止 B5 点名的 6 个
Sigmoid）：**6 个 Sigmoid**（`Reshape/Transpose` 折叠视图）+ **28 个 Relu 尾声消费者**（`Conv/MaxPool/
Resize/Add` 读 `Relu` 输出）。这是 §O3（DST 侧）的 **SRC 侧孪生**。B5 驱动只用 `--fold-src` 在内存里
补了 6 个 Sigmoid（另 28 个**未察觉**）。

## H1.3 修法与判据

* **修法**：`apply_src_addr_fold(gv, descs, units)` 对每个消费者，沿"被折进算子"回溯到第一个**占描述符**
  的生产者，令 `SRC_ADDR := 该生产者 DST_ADDR`；折进必须**连续展平**（`_fold_is_contiguous`），否则
  **响亮拒绝**（strided 读属 B4/RTL）。回溯到头是图输入/常量 ⇒ 保持原样（主机提供）。
* **正判据** `SRC_WRITTEN`：**每个描述符的 `SRC_ADDR` 必须是表序更小描述符写过的 `DST_ADDR`**（图输入除外）
  —— 即"每个源都写在读之前"。实测 `ok=1 checked=67 offenders=0 external=1`。
* **负对照**：`NEGCTL_SRC_ADDR`（把一条 SRC 打到"从未写过"的槽位 ⇒ 必发火）+ 红证据 C `--inject badsrc ⇒ rc=1`。
  **这条判据本可以抓到原 bug**（旧表 34 条源指到未写槽位 ⇒ 会直接红）。

**6 个 Sigmoid 的 `SRC_ADDR`（before → after）**（逐字取自 `wgt_index.json.src_addr_fold`）：

```
desc[61] Sigmoid_85  链=[Reshape_84,Transpose_78]  生产者 Conv_55  0x01C48240 -> 0x01C08100
desc[62] Sigmoid_93  链=[Reshape_92,Transpose_86]  生产者 Conv_57  0x01C4B440 -> 0x01C0A040
desc[63] Sigmoid_101 链=[Reshape_100,Transpose_94] 生产者 Conv_59  0x01C4C0C0 -> 0x01C0A820
desc[64] Sigmoid_109 链=[Reshape_108,Transpose_102]生产者 Conv_67  0x01C4C400 -> 0x01C1C940
desc[65] Sigmoid_117 链=[Reshape_116,Transpose_110]生产者 Conv_69  0x01C4F600 -> 0x01C1E880
desc[66] Sigmoid_125 链=[Reshape_124,Transpose_118]生产者 Conv_71  0x01C50280 -> 0x01C1F060
```

（另 28 条为 `Relu` 尾声消费者，如 `desc[1] Conv_2`：`Relu_1` 的源 `0x004BC000 → Conv_0 的 DST 0x0032C000`。）

## H1.4 驱动侧（`--fold-src` 不再需要）

H1 前：驱动把 6 条 Sigmoid 的 `SRC_ADDR` 在内存里改写到生产者 DST。H1 后：`desc.bin` 已自洽
⇒ `fold_src_rewrite` **恒返回 []**（`DRY_FOLD_REWRITES=0`）。它现在是**复发哨兵**：若表被回退到旧口径，
**响亮 `SystemExit`**（不静默改写）。`bash y1/tools/run_frame_ab.sh` 全绿（12 路输出 + **0 条改写** + 0 HARD）。

## H1.5 证据边界（诚实）

* **离线已证**：`desc.bin` 的自洽性（每个 `SRC_ADDR` 都被更早描述符写过）；表的合法/往返/冻结件复用；
  与 C4a.2 黄金逐层对账；§4.5-A 中心化逐字节等价；折进改写的**地址**正确（= 生产者 DST）。
* **仍需上板（B6）**：折进后的**数值**（拿到生产者 DST 的连续缓冲后，硬件读出的是否就是该消费者该看到的
  `Relu/Transpose-Reshape` 结果）；`done/err`；整帧流量/帧时。**注意**：多数 `Relu` 输出的**刻度**是否
  折进生产者（O1）是**另一件事**，H1 只保证**地址**自洽，不改刻度口径。
* **仍开口**：`Add` 的**第二路**输入没有描述符字段（冻结的 8 字格式只有**一个** `SRC_ADDR`）——H1 只修
  主 `SRC_ADDR`；第二路的投递口径属 C4a.5/C4b 的既有开口项（本网 `Add` 的第二路来自常量/已写缓冲，
  不新增"未写源"）。
