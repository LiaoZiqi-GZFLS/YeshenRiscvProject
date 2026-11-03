# T-S3g / A'-1：**宽链口径修订（第一片）** —— 接口钉死 + 黄金缺口（B1）闭环 + 标定表

- 日期：2026-10-15
- 上游：spec §3.3/§3.6（用户裁决 **A'**）、`reports/ts3f_red_first.txt`（B1/B2/B3 实测）
- 本片边界：**设计 + 离线**。RTL **一字未改**；只动 `tools/run_chain_ab.sh`（重锚）与新增
  `tools/chain_wide_ref.py`（参考 #2）+ 本节报告 + plan 的 `Task A'-1`。
- 证据文件：
  - `reports/ts3g_chain_gate_green.txt` —— `run_chain_ab.sh` 全绿（RESULT: PASS / EXIT=0）
  - `reports/ts3g_ref2_selftest.txt` —— 参考 #2 自检（REF2_SELFTEST: PASS）
  - `reports/ts3g_chain_calib.txt` —— 19-run 标定表（原文，本文 §3 内联）
  - `reports/ts3g_ref2_allruns.txt` —— 19 条 run 的链黄金 md5（自造输入 seed=20261015）

---

## 1. 接口钉死（实现片按此落地，不再重新裁决）

见 `docs/superpowers/plans/2026-10-14-y1-frame-runnable.md` 的 **Task A'-1**（含 file:line 逐条）。
摘要：

- **现状**：`LayerSched` 给 `UnitExec` 的链输入**只有** {8 字链描述符（链首 + 链尾 DST）、
  `chain_len`、`wgt_dma_addr`（帧前缀和）、权重信箱直通}；几何**全部取链首**（`UnitExec.scala:696-697`、
  `LayerSched.scala:450-453/:473/:538-539`）。
- **逐片几何**：`LayerSched` 在 `CHAINSCAN` 逐条锁存
  `chainCin/Cout(16)/Grp(8)/Qsh(8)/Lid(8)/Dw/1x1`（`L_MAX×59 bit` 寄存器数组）⇒ 经**新专用端口**送
  `UnitExec`；槽 0 与链描述符冗余并在 `go` 断言一致。**8 字描述符线格式一字不动**。
  逐片 `M/z_pad/z_y/bias_adj` 用 `chain_lid(k)` 索引**现有**按 `LAYER_ID` 的参数表（零新增存储）。
- **逐片 blob 基址**：冻结转换器契约 `len(k)=ceil32(N_k)`、`N_k = C_out·(C_in/GROUP)·9`、
  偏移 = 前缀和（`y1_convert.py:13-20/:600-612`）⇒ 片上推导：
  `base(0)=wgt_dma_addr`、`base(k+1)=base(k)+ceil32(N_k)`；**无新外部编程**（`WGT_BLOB_BASE`
  仍走邮箱区域 6 的既有 idiom）。帧级指针同步修：`wgtPtrR += Σ_k ceil32(N_k)`（现在 `:829` 是
  `chainLen×N_head`，实测 **52/53** 个单元错位 —— B2 在帧级同样存在）。
- **`desc_table.py` 最小解冻**（实现片一次提交；**本片不动**，理由见 §5-④）：
  (a) `build_table :736-741` 去掉"链首几何覆盖"、逐成员写 own 几何；
  (b) `validate` 规则 (5) `:334-349` 的"6 字段与链首全等"→ **可链谓词**
  （`IMG_W/IMG_H/STRIDE/PAD` 全 run 相等 ∧ `C_OUT(i)==C_IN(i+1)`；通道/GROUP/QUANT_SHIFT 逐片自由）；
  (c) 自检负探针 `:929` 改瞄可链性违反 + 表 md5 锚重冻。**位打包、规则 (1)(2)(3)(4)(6)、
  `reference_words` 一字不动**；"逐成员段长记账"在 `desc_table.py` 本来就不存在（在转换器里）⇒ 零改动。

## 2. 黄金缺口（B1）的裁决与闭环 —— **选项 (b)，显式声明"参考 #2"**

**决定**：异型链的字节黄金 = 新工具 `y1/tools/chain_wide_ref.py`（**参考 #2**）。**（a）不可用**：
`conv_unit_ref.py` 是禁改的冻结件，且其链函数口径是"单一 `(C_IN,C_OUT)` 贯穿全链"，真表异型 run 实测
`IndexError`（`ts3f_red_first.txt` 附A）。（b）被选中，并**不是**"第三条独立参考"：它是冻结 #1 的
**严格扩展**，三层校准全部**实测**：

| 层 | 关系 | 实测结果 |
|:--|:--|:--|
| L1 | 同型特例（C=8, L=4，链闸门同款向量）== 冻结 `conv_unit_ref.chain_l` **与** `chain_l_naive` | 中间 + 最终**逐字节相等**（diff=[0,0,0]/0；0） |
| L2 | 真表成员（`folded_ops==[]`）在**冻结输入**上 == 冻结 #1（`reports/c4a_ref_layers.json` + `gen/c4a_ref/*.npy`）| **38/38 片**：3×3/dw = **identity**；1×1 = **(+1,+1) 相位**（`A[i,j]==F[i-1,j-1]`，如 Conv_6 404496/404496） |
| L3 | 折进成员（`folded_ops!=[]`，14 片）硬件用**单趟 eff 刻度**（`M/s_y_eff/z_y_eff` 记录值）| 与冻结**两步**张量的差异**逐片计数**（如 Conv_7 mism=329123/409600）—— 硬件刻意口径（§4.4/§4.5），非参考误差；每片 `M` 记录值 == 冻结口径重算值 |

另：L0 断言 19 run 全部"可链"（空间几何一致 ∧ `C_OUT(k)==C_IN(k+1)`）；L4 断言 53 个单元的
`z_pad==z_x` 与 `bias_adj == bias_round − z_x·Σw` 恒等式。全部 PASS（`ts3g_ref2_selftest.txt`）。

**要点（明写）**：
- **1×1 的 (+1,+1) 相位**是**实测到的硬件折进口径**：真表 blob 把 1×1 抽头放在 `(ky,kx)=(0,0)`
  （`y1_convert.py:604-609`），硬件 3×3/pad-1 固定锚点 ⇒ `out(i,j)=w·x(i-1,j-1)`（等价于 SRC 基址
  +1 行 +1 列时**逐字节全等**，含边界）。真帧的补偿落在表/驱动的地址折进里；参考 #2 **如实记录并断言**
  这一相位关系，不自行折进。**开口项**：补偿的确切落点（表侧 vs 驱动侧）在实现片需一次定点核对。
- 参考 #2 在 L2 覆盖的 38 片上被冻结 #1 **逐字节钉死**；在 L3 的 14 片上其口径 = 硬件真正收到的
  记录值（邮箱投递的同一批数）。⇒ **不引入新口径**，满足"黄金复用冻结工具、任何偏离必须点名"的纪律。

## 3. 19-run 标定表（ground truth；原文同 `reports/ts3g_chain_calib.txt`）

```
run      L  片  idx  name          TYPE           C_IN→C_OUT  G    H×W     N_i     al      off       cum
[ 1.. 2] 2 head  1  Conv_2        0x02 conv1x1   16→16     1 320×320   2304   2304      448        0
[ 1.. 2] 2 tail  2  Conv_3        0x03 depthwise  16→16    16 320×320    144    160     2752     2304
          head N_i=2304  LayerSched-advance(L*N_head)=4608  real=Σaligned=2464  drift=YES
[ 4..11] 8 head  4  Conv_6        0x02 conv1x1   16→16     1 160×160   2304   2304     2912        0
[ 4..11] 8 mid   5  Conv_7        0x03 depthwise  16→16    16 160×160    144    160     5216     2304
[ 4..11] 8 mid   6  Conv_9        0x02 conv1x1   16→32     1 160×160   4608   4608     5376     2464
[ 4..11] 8 mid   7  Conv_10       0x03 depthwise  32→32    32 160×160    288    288     9984     7072
[ 4..11] 8 mid   8  Conv_12       0x02 conv1x1   32→32     1 160×160   9216   9216    10272     7360
[ 4..11] 8 mid   9  Conv_13       0x03 depthwise  32→32    32 160×160    288    288    19488    16576
[ 4..11] 8 mid  10  Conv_15       0x02 conv1x1   32→64     1 160×160  18432  18432    19776    16864
[ 4..11] 8 tail 11  Conv_16       0x03 depthwise  64→64    64 160×160    576    576    38208    35296
          head N_i=2304  LayerSched-advance(L*N_head)=18432  real=Σaligned=35872  drift=YES
[13..16] 4 head 13  Conv_19       0x02 conv1x1   64→64     1  80×80   36864  36864    38784        0
[13..16] 4 mid  14  Conv_20       0x03 depthwise  64→64    64  80×80     576    576    75648    36864
[13..16] 4 mid  15  Conv_22       0x02 conv1x1   64→64     1  80×80   36864  36864    76224    37440
[13..16] 4 tail 16  Conv_23       0x03 depthwise  64→64    64  80×80     576    576   113088    74304
          head N_i=36864  LayerSched-advance(L*N_head)=147456  real=Σaligned=74880  drift=YES
[18..21] 4 head 18  Conv_26       0x02 conv1x1   64→64     1  40×40   36864  36864   113664        0
[18..21] 4 mid  19  Conv_27       0x03 depthwise  64→64    64  40×40     576    576   150528    36864
[18..21] 4 mid  20  Conv_29       0x02 conv1x1   64→64     1  40×40   36864  36864   151104    37440
[18..21] 4 tail 21  Conv_30       0x03 depthwise  64→64    64  40×40     576    576   187968    74304
          head N_i=36864  LayerSched-advance(L*N_head)=147456  real=Σaligned=74880  drift=YES
[23..28] 6 head 23  Conv_33       0x02 conv1x1   64→64     1  20×20   36864  36864   188544        0
[23..28] 6 mid  24  Conv_34       0x03 depthwise  64→64    64  20×20     576    576   225408    36864
[23..28] 6 mid  25  Conv_36       0x02 conv1x1   64→64     1  20×20   36864  36864   225984    37440
[23..28] 6 mid  26  Conv_37       0x03 depthwise  64→64    64  20×20     576    576   262848    74304
[23..28] 6 mid  27  Conv_39       0x02 conv1x1   64→64     1  20×20   36864  36864   263424    74880
[23..28] 6 tail 28  Conv_40       0x03 depthwise  64→64    64  20×20     576    576   300288   111744
          head N_i=36864  LayerSched-advance(L*N_head)=221184  real=Σaligned=112320  drift=YES
[31..32] 2 head 31  Conv_45       0x02 conv1x1   64→64     1  40×40   36864  36864   300864        0
[31..32] 2 tail 32  Conv_46       0x03 depthwise  64→64    64  40×40     576    576   337728    36864
          head N_i=36864  LayerSched-advance(L*N_head)=73728  real=Σaligned=37440  drift=YES
[35..36] 2 head 35  Conv_51       0x02 conv1x1   64→64     1  80×80   36864  36864   338304        0
[35..36] 2 tail 36  Conv_52       0x03 depthwise  64→64    64  80×80     576    576   375168    36864
          head N_i=36864  LayerSched-advance(L*N_head)=73728  real=Σaligned=37440  drift=YES
[37..38] 2 head 37  Conv_54       0x02 conv1x1   64→1      1  80×80     576    576   375744        0
[37..38] 2 tail 38  Conv_55       0x01 conv3x3    1→1      1  80×80       9     32   376320      576
          head N_i=576  LayerSched-advance(L*N_head)=1152  real=Σaligned=608  drift=YES
[39..40] 2 head 39  Conv_56       0x02 conv1x1   64→1      1  40×40     576    576   376352        0
[39..40] 2 tail 40  Conv_57       0x01 conv3x3    1→1      1  40×40       9     32   376928      576
          head N_i=576  LayerSched-advance(L*N_head)=1152  real=Σaligned=608  drift=YES
[41..42] 2 head 41  Conv_58       0x02 conv1x1   64→1      1  20×20     576    576   376960        0
[41..42] 2 tail 42  Conv_59       0x01 conv3x3    1→1      1  20×20       9     32   377536      576
          head N_i=576  LayerSched-advance(L*N_head)=1152  real=Σaligned=608  drift=YES
[43..44] 2 head 43  Conv_60       0x02 conv1x1   64→4      1  80×80    2304   2304   377568        0
[43..44] 2 tail 44  Conv_61       0x03 depthwise   4→4      4  80×80      36     64   379872     2304
          head N_i=2304  LayerSched-advance(L*N_head)=4608  real=Σaligned=2368  drift=YES
[45..46] 2 head 45  Conv_62       0x02 conv1x1   64→4      1  40×40    2304   2304   379936        0
[45..46] 2 tail 46  Conv_63       0x03 depthwise   4→4      4  40×40      36     64   382240     2304
          head N_i=2304  LayerSched-advance(L*N_head)=4608  real=Σaligned=2368  drift=YES
[47..48] 2 head 47  Conv_64       0x02 conv1x1   64→4      1  20×20    2304   2304   382304        0
[47..48] 2 tail 48  Conv_65       0x03 depthwise   4→4      4  20×20      36     64   384608     2304
          head N_i=2304  LayerSched-advance(L*N_head)=4608  real=Σaligned=2368  drift=YES
[49..50] 2 head 49  Conv_66       0x02 conv1x1   64→1      1  80×80     576    576   384672        0
[49..50] 2 tail 50  Conv_67       0x01 conv3x3    1→1      1  80×80       9     32   385248      576
          head N_i=576  LayerSched-advance(L*N_head)=1152  real=Σaligned=608  drift=YES
[51..52] 2 head 51  Conv_68       0x02 conv1x1   64→1      1  40×40     576    576   385280        0
[51..52] 2 tail 52  Conv_69       0x01 conv3x3    1→1      1  40×40       9     32   385856      576
          head N_i=576  LayerSched-advance(L*N_head)=1152  real=Σaligned=608  drift=YES
[53..54] 2 head 53  Conv_70       0x02 conv1x1   64→1      1  20×20     576    576   385888        0
[53..54] 2 tail 54  Conv_71       0x01 conv3x3    1→1      1  20×20       9     32   386464      576
          head N_i=576  LayerSched-advance(L*N_head)=1152  real=Σaligned=608  drift=YES
[55..56] 2 head 55  Conv_72       0x02 conv1x1   64→10     1  80×80    5760   5760   386496        0
[55..56] 2 tail 56  Conv_73       0x03 depthwise  10→10    10  80×80      90     96   392256     5760
          head N_i=5760  LayerSched-advance(L*N_head)=11520  real=Σaligned=5856  drift=YES
[57..58] 2 head 57  Conv_74       0x02 conv1x1   64→10     1  40×40    5760   5760   392352        0
[57..58] 2 tail 58  Conv_75       0x03 depthwise  10→10    10  40×40      90     96   398112     5760
          head N_i=5760  LayerSched-advance(L*N_head)=11520  real=Σaligned=5856  drift=YES
[59..60] 2 head 59  Conv_76       0x02 conv1x1   64→10     1  20×20    5760   5760   398208        0
[59..60] 2 tail 60  Conv_77       0x03 depthwise  10→10    10  20×20      90     96   403968     5760
          head N_i=5760  LayerSched-advance(L*N_head)=11520  real=Σaligned=5856  drift=YES

帧级指针：按未对齐 N_i 累加 vs blob 实际偏移 ⇒ 52/53 个单元错位（第 2 个起全部错位）。
```

要点：**19/19 run 漂移**（与 T-S3f 附B 一致）；每片 `aligned_bytes == ceil32(N_i)`（53/53 验证）；
blob 偏移 == 逐单元前缀和（总 404064 B）。**帧级指针也必须按 ceil32 推进**（新发现，A'-1.2 已收编）。

## 4. `run_chain_ab.sh` 既有红 —— 已修复并全绿

- 两处锚位腐坏（T-S3f 报告已如实记账，非行为回归）：
  ① `<<< 2'd2` 全表 8→9：第 9 处是 T-S3b 宽路 per-plane 的 `cl*4`（`cl <<< 2`），**不在**
  `Conv3x3Slice` 内 ⇒ 把两处 requant 常量的计数**作用域收敛到 `Conv3x3Slice` 模块体内**（两处仍各 8，
  语义恢复原意且对 `UnitExec` 顶层其它 `<<< 2` 免疫）；
  ② `WeightStore` 正则命中 0：SpinalHDL 物化为 `WeightStore_8 ws (` ⇒ 改认参数后缀名，并断言
  **单份 `Conv3x3Slice` 定义内恰好 1 个例化点**（elaborated = `Conv3x3Slice` 例化点数 × 1 = 9；
  旧版该量只打印不判，一并纳入判据）。
- 证书：`reports/ts3g_chain_gate_green.txt` ⇒ `RESULT: PASS`、`EXIT=0`（六节 + §7 + 收口全绿）。

## 5. 开口项 / 诚实记录

1. **1×1 的 (+1,+1) 相位**（§2）是实测的硬件折进口径；"真帧里补偿落在哪（表侧地址 vs 驱动侧）"
   本片只给出证据（blob 抽头落 `(0,0)` + desc `PAD=0` + 冻结张量与硬件口径差 (+1,+1)），**未定点裁决**
   ⇒ 实现片做一次定点核对（列入 A'-1.5 的判据面）。
2. **帧级指针漂移 52/53** 是新发现（B2 的帧级镜像）；A'-1.2 已把"帧级 advance = Σ ceil32(N_k)"写进设计，
   但**未在 RTL 里验证**（本片不改 RTL）。负对照（漏一截/偏一段 ⇒ 必红）留给实现片。
3. **折进成员的硬件口径 ≠ 冻结两步张量**（14 片，逐片计数见 `ts3g_ref2_selftest.txt` 的 L3）。
   这是转换器/硬件的刻意口径（§4.4/§4.5 单趟 requant）。参考 #2 以**记录值**为准（= 硬件收到的数），
   **不**把冻结两步张量当作这些片的黄金 —— 这一条在闸门里必须按"折叠口径"对账，不能拿两步张量硬比。
4. **`desc_table.py` 本片不动**（硬约束允可后仍判定不动）：单独放宽规则 (5) 而不动 `build_table` 的
   覆盖与自检负探针 ⇒ 冻结自检的 R5 探针会瞄在"解冻后已合法"的条件上（红或失声）；且现有产物仍是
   覆盖表、解冻后没有正对照用户 ⇒ 三者（a)(b)(c) 必须与转换器一次提交，归实现片（spec §3.6 同款）。
5. 参考 #2 的"任意输入"泛化性依据：L2 的逐字节关系是在**冻结真数据**（256 个码点、自然统计）上
   实测的；折进/相位都是**数据无关**的接口性质 —— 但"数据无关"这一步是**推理**，闸门里仍以
   参考 #2 直接出黄金 + 一条冻结输入锚定正对照双保险。

---

## 提交

- `edb1486` fix(y1-chain): re-anchor `run_chain_ab.sh` §7 文本锚（窄链闸门转绿）
- （本文件与 `tools/chain_wide_ref.py`、plan Task A'-1 的提交见 `git log`：`docs(y1-chain): A'-1 ...`）

---

## 6. A'-2（2026-10-15，落地片）—— 逐片几何投递 + 逐成员段长/基址 + 帧级指针（B2 修法）

**边界**：`desc_table.py` / `PartialSumBuf.scala` / 全部冻结参考 **未动**；8 字描述符线格式**一字未动**；
`TILING=false` 三份网表（`UnitExec.v` / `_w32` / `_w640`）**逐字节不变**（md5 同 §A'-1 冻结值）。

**RTL 落点**（`rtl/LayerSched.scala` + `rtl/UnitExec.scala`，口径 = plan Task A'-1）：

- `LayerSched`：`CHAINSCAN` 逐条取回成员描述符时**逐槽锁存** `chainCin/Cout/Grp/Qsh/Lid/Dw/1x1`
  （`L_MAX×59 bit`）+ `chainSegLenR`（逐片 `ceil32(N_k)`；槽 0 = 链首；**落槽先于校验** ⇒ 链被拦下时槽里仍是表值）。
- **可链谓词**（口径修订落地）：`IMG_W/IMG_H/STRIDE` 全 run 与链首相等 ∧ **相邻内部边界**
  `C_OUT(k-1)==C_IN(k)`；`C_IN/C_OUT/GROUP/QUANT_SHIFT` 逐片自由；`PAD` 不进判据（冻结表 PAD 逐片不同；
  与离线参考 L0 同式）。不合 ⇒ `CHAINSCANW` 响亮 err + 零搬运。
- **帧级推进**（B2）：`wgtPtrR += nWgtAdvR`，`nWgtAdvR = Σ_k ceil32(N_k)`（分派那一拍定案；
  plain = `ceil32(N_0)`，链 = 沿链逐片累加**每片自己**的段长；旧式 `chainLen×N_head` 退休）。
- `UnitExec`（`TILING=true` 才 elaborate）：新**专用端口** `chain_cin/cout/grp/qsh/lid/dw/1x1`
  （组件级具名入参；8 字线格式未动）；`go` 那拍断言 `槽 0 == 链描述符`（失败码 1）+ **引擎互锁**
  （宽链引擎未落地 ⇒ 链上非首片的 `(C_IN,C_OUT,GROUP,QUANT_SHIFT)` 必须与链首一致；失败码 2）；
  片上推导 `len(k)=ceil32(N_k)`、`base(0)=wgt_dma_addr`、`base(k+1)=base(k)+len(k)`；
  宽路 RD 长度改用 `segLenC(0)`（与 `wgtWideRdLen` 同式，同值）；加 `chain_rep_*` 观察口
  （纯 mux；引擎未落地时这些寄存器无功能读者 ⇒ 无该口会被剪掉）。

**装置**：`LayerSchedTb.v` 加 `+GEOMDUMP`（层级回读，零面积；不给 ⇒ stdout 逐字节不变）；
`MAXWGT 1024→4096`（真表宽 run 首片 `N=2304`）；`UnitExecTb.v` / `UnitExecWideTb.v` 加
`` `ifdef UE_CGEOM `` 守卫的"逐片几何 = 描述符译码"组合驱动（一份装置两族网表公用：`TILING=false`
网表没有这些端口 ⇒ 那些编译把守卫块整体裁掉；四个编译 **tiled** 网表的闸门
（`run_chain_wide_ab.sh` / `run_tiling2d_wide_ab.sh` / `run_tiling2d_rtl_ab.sh` / `run_wgtblob_tiled_ab.sh`）
编译行加 `-DUE_CGEOM`）。

**判据闸门**：`tools/run_chaingeom_ab.sh`（新）—— 真表 run[4..11]（`Conv_6..Conv_16`，8 片异型链：
`C_IN/C_OUT` 逐片不同、含 3 片 depthwise 与 4 片 1×1）：

- 正对照：8 槽 × （`LayerSched` 锁存 + `UnitExec` 收到）**两处独立回读** == 各成员 own 表值；
  段长/基址 == 冻结 `wgt_index.json` 的 `aligned_bytes` / 偏移前缀（向量侧前提自检：偏移差 == 前缀和，
  Σ=35872 == 标定表）；`ADVP == 35872`；`PTR==0`（err 帧不推进）；`GATE=2`；`AW total=0`；`RESULT: PASS`。
- 负对照①（帧级推进回退成 B2 旧式）**已发火**：`ADVP 2304 ≠ 35872`（判据有牙 ⇒ §5-2 的开口项闭环）。
- 负对照②（`LayerSched` 槽 0 锁存改坏）**已发火**：`GATE 2→1`（"槽 0 == 链描述符"断言真的在起作用）。

**接前一位 agent 未提交 WIP 的三处勘误**（`run_chaingeom_ab.sh` 对账时逐条暴露）：

1. `geomEq` 旧稿 `headDw.cOut == dw.cIn`（链首对每个成员）⇒ 异型链第 4 片起必然误杀（与 A'-1 谓词、
   参考 L0 不符）⇒ 改相邻比较 `chainCoutR(chainCnt-1) == dw.cIn`；
2. 判据向量占位槽：head 的 `DST` / tail（及 middle）的 `SRC` 原写成自己的另一个地址 ⇒ 触发
   `fieldsOk.selfLoop` 被拦在 `FETCHW` ⇒ 改配片上占位槽 `0x030000`（主口看不到）；判据脚本三处
   token 下标错位（SCHED 行等）一并修正；
3. WIP 把逐片几何接线**无守卫**地加进 `UnitExecWideTb.v` ⇒ 对 `TILING=false` 网表是 iverilog 硬错误
   （12 个闸门编译同一装置）⇒ 改为 `` `ifdef UE_CGEOM `` 守卫（语义不变，只显式化"哪些编译看见它"）；
   WIP 的 `+SLOT0BAD` 未被任何闸门使用 ⇒ 未保留（槽 0 断言已由本闸门经**真路径** `LayerSched→UnitExec` 覆盖）。

**网表指纹**（`gen/` 未跟踪 ⇒ 指纹记于此 + 提交信息；两次重生成逐位相同）：

| 网表 | md5 |
|:--|:--|
| `gen/UnitExec.v`（冻结） | `979129017535dc82ab9e6d89bea31080` |
| `gen/UnitExec_w32.v`（冻结） | `618af3381eadcb4d7c6964cd4338a825` |
| `gen/UnitExec_w640.v`（冻结） | `ddb9bb8addc01f94e2ea8ae8b6b898e6` |
| `gen/UnitExec_tiled.v`（本片） | `6f2e84e88f9009e36d5d6c40ffdab7ef` |
| `gen/LayerSched.v`（本片） | `9fe6923db27cd50e5c64f3e5976ffd96` |
| `gen/NpuTop.v`（本片） | `9622b98d1a1c810e561519619796d95a` |

**回归**（全绿；`check_dangling.py` 对三份新网表 PASS）：`run_chain_ab` / `run_unitexec_ab` /
`run_unitexec_wide_ab` / `run_tiling2d_wide_ab` / `run_tiling2d_rtl_ab` /
`run_wgtblob_tiled_ab` / `run_sched_ab` / `run_nputop_sched_ab` / `run_wgtdma_ab` / `run_wgtdma_wide_ab`。
★ `run_chain_wide_ab.sh` 保持**先红**（T-S3f 的既有先红证据：宽链无通路 ⇒ `go` 即 err + 零搬运；
本片只给它的编译行加了 `-DUE_CGEOM`（tiled 网表），四个作业的红签名与该闸门自己的 JUDGE-RED 文本逐字一致
⇒ 未引入新红）。

**遗留（明写）**：宽链**引擎**未落地 —— 异型链在 `UnitExec` 的 `go` 处被引擎互锁响亮拦下（`GATE=2`）；
逐片几何的**投递面**（本片）已闭环，"用这些几何把链真正跑完"归宽链引擎片（T-S3f 的 A' 后继）。

---

## 7. A'-3（2026-10-16，**设计 + 测量片**）—— 宽链引擎 = `reports/ts3h_wide_chain_engine.md`

该片把"忠实镜像窄链"的引擎结构、板级账（LUT/DRM/拍数）、闸门贴边与**实测墙**逐条钉死，
判词 = **BLOCKED**：镜像（每片一套引擎）**+8×≈6,202 LUT 超余量 35,692 ~14k**；
唯一在预算内的变体 = **与窄链共用 `slices(0..7)` 片阵列**（合体引擎，打开 7 组逐字节冻结面）⇒
需用户裁决。RTL/`gen/` 一字未动（六网表 md5 见该报告 §6）；闸门红签名不变。
