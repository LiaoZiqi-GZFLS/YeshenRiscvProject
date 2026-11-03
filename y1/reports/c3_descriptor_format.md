# Y1-C3.2 + **C3.11a** + **A-2** + **A-3b** 报告 —— 冻结描述符位打包（Python 契约 + 报告）

**Status: DONE_WITH_CONCERNS**

**本文件 = C3.2 报告 + C3.11a 的 spec 修订记录 + A-2 的 spec 修订记录 + A-3b 的契约对齐记录**。
- **C3.11a**（commit `63b09df`）把 FLAGS 融合语义改成"塌缩单条目"、订正 `DESC_COUNT` 口径；
- **A-2**（上一轮）把 FLAGS 改成**逐算子链式编码**（`head`/`plain`/`middle`/`tail`）
  + 规则 (5) 改成**链状态机**（`(P | H M* T)`），并**重生成**冻结表/指纹
  （`2176 B / ed00cad736b82378a59bdeedc79f3b21`，`CHAIN_L_MAX = 4`）；
- **A-3b**（本次）把 `CHAIN_L_MAX` 从 **4** 提到 **8**，与 RTL 的 `L_MAX=8` **对齐** ——
  RTL 侧那次参数化改动的名字是 **A-3**（commit `8120c64`：`L_MAX` 4→8）；**A-3b 是它的
  契约侧收口**（Python 冻结模型跟到同口径）⇒ 最长的那两条极大链（长 6 / 长 8）**不再拆** ⇒ 表**重生成**
  （`2176 B / a45d0da0440a468f1b75788c9ad5bc14`）、流量归到**下界本身**
  （12,576,000 B/帧，零拆点）。**§0.7 是本次修订的核心**。
**§0.6 是 A-2 修订的核心**；§1/§3/§4/§5/§6.6/§7/§8 已按修订后的口径重写（A-3b 再更新一遍数字）。

**开口项指针**：
- **O1** —— `Add` 的两个操作数**都要**从 DDR 读，而冻结格式只有**一个** `SRC_ADDR`（见 §7）。
- **O8（C3.11a 提出，A-2 关闭"编码限制"，A-3/A-3b 关闭"硬件残留"）** —— 旧 O8 = "塌缩编码 >2 切片的
  融合链不可表达"。逐算子链式编码下**编码层没有链长上限**（A-2）；**硬件 `L_MAX` 的限制**也随 RTL 的
  **A-3** 把 `L_MAX` 提到 **8**、并由**本次 A-3b** 把 `CHAIN_L_MAX` 跟到 8 而**归零**：
  本网最长链恰 8 ⇒ **零拆点**、整帧 = 12,576,000 B（§0.7 / §4.5）。

**一句话**：描述符的**位打包**冻死在 `y1/tools/desc_table.py`（8×32-bit 小端 = 32 B/项），
`pack/unpack/pack_table/validate/desc_count_of` 五个冻结 API；A-2 之后，**一项 = 一个算子**
（`FLAGS[1:0]`：`0b00` 链首 / `0b01` 普通 / `0b10` 链中 / `0b11` 链尾），**链** = 一段极大的
`head middle* tail`、`SRC` 取链首、`DST` 取链尾、**run 内 6 个几何字段必须一致**、**链长不在 FLAGS 里**
（调度器扫链后作独立入参给 `UnitExec.io.chain_len`，本代 `L_MAX = 8`），**`DESC_COUNT` = 载荷项数
（不含哨兵）**。用 YuNet 真实表跑通**五条判据**（往返逐字段 + 四条负对照，其中第四条 = 规则 (1)–(6) 的
`_rule_probe` 负对照表，**23 条**变异/正对照），**每一条都拿计算值比外部冻结常量或第二遍独立重算**，
且**每条都被演示过"发火"**（§6）。这是 **C4/M2 的转换器**与 **C3.4 的 `DescDefs.scala`** 的
机器可读单一真源（R3）。

---

## 0) 它与上一步的关系（为什么是这一步）

spec `docs/superpowers/specs/2026-10-09-y1-c3-scheduler-design.md` §3 冻结了描述符的**语义**、
把**位打包留给计划**（§6 R3：表格式必须与 C4/M2 的转换器对齐）。C3.2 落地了那个打包；
C3.11a 做了一次修订（塌缩单条目）；**A-2 是第三次修订** —— 起因是 **A-1a/A-1b 把 RTL 从"2 切片/单元"
扩成"L 切片片上融合链"**（`L_MAX=4`、A-1a），并把描述符编码改成**逐算子链式**（A-1b：`LayerSched`
扫链 → 塌缩成一次 `go`，链长作独立入参）。**编码跟着硬件走**：一项一算子。

- **上游输入（只读，零改动）**：`y1/tools/ddr_traffic.py`、`y1/tools/bypass_traffic.py`、
  `y1/tools/fusion_chains.py`（A-2 只读 import 它做**链/流量交叉对账**）、
  `y1/tools/fusion_buffer.py`（未使用，仅旁证）。
- **下游**：C4/M2 的转换器（产表）、C3.4 的 `DescDefs.scala`（RTL 译码，逐字段一致 + 同一组向量
  交叉对账）、C3.11（S6 的 RTL 侧非法表校验）。
- 本任务**纯离线**：无 RTL 改动（只读 RTL 的既有行为作为"硬件真相"）、无 SoC、无板。

---

## 0.5) ★★ C3.11a 修订回顾（上一轮的编码，**已被 A-2 取代**）★★

C3.11a 把融合单元写成**一个** `FLAGS=0b10` 的**塌缩条目**（"一次 `go` 跑头/尾两个切片"），
理由是当时的 RTL（`UnitExec.scala` C3.9b）只能执行这个形式。它同时宣布了一条**表达力硬限制**（旧 O8）：
塌缩项一次跑两个切片 ⇒ 一条 >2 切片的链**不可表达** ⇒ 33 条边里 7 条被牺牲、整帧 +5,222,400 B。

**A-2 作废这条限制**（理由见 §0.6）：A-1b 的 RTL 已经是"`head middle* tail` 扫链 + 一次 `go` 跑 L 片"，
所以描述符必须**一项一算子**。C3.11a 的四个 FLAGS 组合定义里，`0b10`/`0b11` 的含义被**重新指派**：

| FLAGS | C3.11a（作废） | **A-2（权威）** |
|---|---|---|
| `0b00` | 只生产（本网 0 项） | **链首**：读 DDR、输出留片上 |
| `0b01` | 普通单元 | **普通单元**（不变） |
| `0b10` | **塌缩融合对**（恰一项、无需伙伴） | **链中**：输入取上一片的片上输出、输出留片上 |
| `0b11` | **保留 / 非法**（validate 拒绝） | **链尾**：输入取上一片的片上输出、输出落 DDR |

---

## 0.6) ★★ A-2：本次 spec 修订（核心）★★

### 0.6.1 修订内容（四条）

1. **一项 = 一个算子（逐算子链式编码）**：`FLAGS[1:0]` 四态**逐个显式定义**、**全部合法**：
   `0b00` 链首（in DDR → 片上）、`0b01` 普通（in DDR → out DDR）、`0b10` 链中（in 片上 → 片上）、
   `0b11` 链尾（in 片上 → out DDR）。位号**一字未动**（`bit0=OUT_TO_DDR`、`bit1=IN_FROM_PREV`），
   改的是**四态的语义**。`FLAGS[7:2]` 保留 = 0（规则 (2) 拒绝）。
2. **链（chain）= 极大 run `head middle* tail`**：
   - 语义：链首读 DDR、中间片从上一片的片上输出接着算、链尾写 DDR ⇒ **中间张量结构性零 DDR**；
   - 链的 `SRC` = **链首**的 `SRC_ADDR`、`DST` = **链尾**的 `DST_ADDR`；`UnitExec` 拿到的"链描述符"
     = **链首的 8 个字 + 链尾的 `DST_ADDR`**（`LayerSched.scala` 的 CHAINSCAN 锁存）；
   - **run 内所有条目的 `IMG_W/IMG_H/C_IN/C_OUT/GROUP/QUANT_SHIFT` 必须相同**（= "融合"的硬含义；
     硬件只用链首的几何、逐片行锁步行进）。`TYPE` / `STRIDE` / `PAD` / `SRC` / `DST` / `IN_BYTES`
     与**权重**可以逐片不同（权重带外预载，不进描述符）。
3. **链长不在 `FLAGS` 里**：`FLAGS[1:0]` 只表达上面四态；链长由**调度器扫链**数出来（`LayerSched` 的
   CHAINSCAN/CHAINSCANW），作为**独立入参**交给 `UnitExec.io.chain_len`（A-1b 作废了 A-1a 塞在
   `FLAGS[4:2]` 的链长编码）。**本代硬件的 `L_MAX = 8`**（常量 `CHAIN_L_MAX`；A-3b 从 4 提到 8）：
   一段 run 的长度**不得超过它**，超出 ⇒ 表非法（规则 (5) 的 `chain too long @i`；RTL 同款响亮 `err`）。
4. **规则 (5) 重写为链状态机**：载荷必须写成 `(P | H M* T)*`（`P` = plain / 旁路项），
   并逐 run 检查长度与几何（见 §3）。

### 0.6.2 为什么改（出货硬件的事实）

- `rtl/UnitExec.scala`（A-1b 文件头）：`chainLen` 从 `FLAGS[4:2]` 译码改成**独立入参**
  `io.chain_len`；`FLAGS[1:0]` 按**逐算子**语义译码（bit0 决定切片 0 输出去 outMem 还是留片上）；
  "有没有尾"由 `chainLen ≥ 2` 给出。链长 0 或 > `L_MAX` ⇒ 响亮 `err`。
- `rtl/LayerSched.scala`（A-1b）：新增 `CHAINSCAN/CHAINSCANW` —— 遇 `head`(`0b00`) 就**逐项向前取**，
  `middle`(`0b10`) 继续、`tail`(`0b11`) 收链 ⇒ **塌缩成一次 `UnitExec.go`**。它同时把下列情形判为
  **响亮 `err` + 零设备搬运**（与规则 (5) **逐条对齐**，这就是"单一真源"的含义）：
  `middle`/`tail` 无前驱、`head` 后面不是 `middle`/`tail`（含撞哨兵）、链长 > `L_MAX`、
  链上几何/`QUANT_SHIFT` 与链首不一致、保留位非 0。
  （"零搬运"口径：`err` 是在**扫链途中**发现的 ⇒ 已取过的描述符字节是既成事实；**设备级**一个激活
  字节都不搬、一个 AW/W 都不发。）
- `tools/run_chain_ab.sh`（A-1a/A-1b 闸门）用**四个相邻条目** `0b00,0b10,0b10,0b11`
  （`+CHAINLEN=4`）驱动，并逐字节断言"链描述符 = 链首 8 个字 + 链尾 `DST`"。

### 0.6.3 表达力：旧 O8 **已关闭**（且必须分清"编码"与"硬件"两件事）

- **旧 O8（作废）**："塌缩编码只能保住一条链上 ⌊len/2⌋ 个融合对 ⇒ 33 条边里 7 条被牺牲（+5,222,400 B）"。
- **A-2 的编码层**：任意长的链都是"一串 `head middle* tail`"⇒ **33 条边全部可表达**。
  本文件把这个数**算出来、打印出来、断言住**：`info["per_edge_bytes"]` = **12,576,000 B/帧**
  （= `fuse_both` 下界，用**冻结口径** `ddr_traffic.compute_rows_fused` 算，并与
  `fusion_chains.internal_edges_of_groups(chains, L_MAX_chain=8)` **交叉对账**）。
  ⇒ **这就是"O8 关闭"的证据**（编码层不再是瓶颈）。
- **（A-2 时的）残留：硬件 `L_MAX`**：A-2 当时 `L_MAX = 4` ⇒ 19 条极大链里 **长 6 与长 8 的那两条
  必须在表里拆开**（`_split_run` 用 DP 选"最便宜"的拆点）⇒ 覆盖 **31/33** 条边，被牺牲的 2 条
  （`Conv_10→Conv_12` = 819,200 B、`Conv_34→Conv_36` = 25,600 B）各多一趟 DDR 往返
  = 2 × 844,800 = **1,689,600 B/帧** ⇒ 整帧 12,576,000 → **14,265,600 B**（+13.4%）。
  ★ **这一条已关闭**：RTL 侧的 **A-3** 把 `L_MAX` 提到 **8**（commit `8120c64`）、本文件的
  **A-3b** 把 `CHAIN_L_MAX` 跟到 8 ⇒ 长 6/长 8 的链**不再拆**、**零拆点**、整帧回落到
  **12,576,000 B**（见 §0.7 / §4.5）。
- ★ **这条区分（编码 vs 硬件）是 A-2 的 crux**：`L_MAX` 是**面积/实例**问题（`L_MAX=8` 需要 8 个
  切片实例共享，见 `reports/c3_fusion_chains.md` 的 L 表与 §6 的面积推导），**不是编码的表达力问题**。
  A-3（RTL）+ A-3b（契约）之后**两边同时到位**（编码能表达 + 硬件一次跑得完最长链）⇒ 整帧 = 下界本身。

### 0.6.4 位打包一字未动

字偏移/宽度、TYPE 码、`w0..w7` 布局**保持不变** ⇒ **线格式仍兼容**（C3.4 的 `DescDefs.scala`
字段切片逐字不变、`--emit-hex/--emit-meta` 出口格式不变、C3.4 的交叉对账闸门照跑 PASS）。
改的只有 FLAGS 的**语义**、校验**规则**与表的**内容**（`DESC_COUNT` 口径 = C3.11a 已订正、本轮不变）。

---

## 0.7) ★★ A-3b：本次契约对齐（`CHAIN_L_MAX` 4 → 8，与 RTL 同口径）★★

### 0.7.1 起因：RTL 与冻结模型的口径裂开

`8120c64` 把 RTL 的链长上限从 `L_MAX=4` 参数化提到 **8**（`LayerSched.scala` / `UnitExec.scala`），
实测融合边覆盖 **31/33 → 33/33**（conv-only 14,265,600 → **12,576,000 B/帧**）。但冻结契约
`desc_table.py` 仍写 `CHAIN_L_MAX = 4` ⇒ **Python 校验器会拒绝 5–8 片的链**，而硬件已能执行；
`run_nputop_sched_ab.sh` 的 8 片链作业当场把这个裂口打成可见行
`PYLIST_VALIDATE reject(chain too long @4)`。A-3b 就是**把冻结契约拉回与 RTL 同口径**。

### 0.7.2 改了什么（三处）

1. **`CHAIN_L_MAX = 8`**（`desc_table.py`）：docstring 的 `L_MAX` 段、`_split_run` 注释、
   规则 (5) 描述、`build_table` 的建表注释全部从 4 改成 8。
2. **重生成冻结表 + 指纹**：`L_MAX=8` 下 `_split_run` 对**每条**极大链都只返回一段（最长链 8 = 上限）
   ⇒ 表里 **19 段 run**（15×2 + 2×4 + 1×6 + 1×8）、**零拆点**、FLAGS 直方图
   `{0b00:19, 0b01:15, 0b10:14, 0b11:19}`；**md5 `ed00cad7…`（L=4）→ `a45d0da0…`（L=8）**。
   表**项数与尺寸不变**（一个算子一项与链是否拆无关 ⇒ 仍 **68 项 = 2176 B**、**哨兵仍在下标 67**）。
3. **`_rule_probe` 的正/负对照随上限移动**：`chain too long` 现在由 **9 片链**触发
   （期望串 `chain too long @9`，越限那一条 = 下标 9）；正对照新增**合法 8 片链**（= `L_MAX`），
   与已有的"合法 2 片 / 合法 4 片"并列。**`selftest` 仍全绿**（§6.6 给出"删掉该检查即变红"的原始红证据）。

### 0.7.3 不变的东西（单一真源没动）

**位打包一字未动**：`pack/unpack/pack_table/validate/desc_count_of` 五 API 签名与位表不变、
`DescDefs.scala` 的 17 字段对账向量不变、`--emit-hex/--emit-meta` 出口格式不变。
变的只有**常量 `CHAIN_L_MAX`**、**表的内容**（FLAGS 角色 + 链首几何覆盖范围）、md5 与 §4.5 的流量数。
`run_desc_ab.sh` 的前提（表 2176 B / 哨兵 @67 / idx1=head / idx2=tail）**跟着表走但没挪位**，
只在注释里记下这次 md5 迁移（§9）。

---

## 1) 冻结位打包（= spec §3 的语义 + A-2 修订的 FLAGS 语义；逐字）

```
每项 8 个 32-bit 小端字（= 32 B）：
  w0 : [7:0]=TYPE  [15:8]=FLAGS  [31:16]=0
  w1 : [15:0]=IMG_W [31:16]=IMG_H
  w2 : [15:0]=C_IN  [31:16]=C_OUT
  w3 : [7:0]=GROUP  [11:8]=STRIDE [15:12]=PAD [31:16]=0
  w4 : [31:0]=SRC_ADDR
  w5 : [31:0]=DST_ADDR
  w6 : [31:0]=IN_BYTES
  w7 : [7:0]=QUANT_SHIFT [15:8]=LAYER_ID [31:16]=0

TYPE : 0x01 conv3x3 | 0x02 conv1x1 | 0x03 depthwise | 0x10 maxpool
     | 0x11 resize | 0x12 concat | 0x13 add | 0x14 sigmoid | 0xFF 哨兵

FLAGS（★ A-2 修订：**逐算子链式**编码；四种组合**逐个显式定义、全部合法**）：
  bit0=OUT_TO_DDR  ：1 ⇒ 输出落 DDR
  bit1=IN_FROM_PREV：1 ⇒ 输入取「上一个算子」的片上输出（DDR 读被这一位覆盖）
  bits[7:2] 保留 = 0（规则 (2) 拒绝）
    0b00 HEAD    链首：读 DDR(srcA) -> 计算 -> 输出**留片上**（进链的第一块中间缓冲）
    0b01 PLAIN   普通单元：读 DDR(srcA) -> 计算 -> 写 DDR(dstA)
    0b10 MIDDLE  链中：输入取**上一个算子的片上输出** -> 计算 -> 输出**留片上**
    0b11 TAIL    链尾：输入取**上一个算子的片上输出** -> 计算 -> 写 DDR(dstA)

链（chain）= 一段**极大**的相邻条目序列 `head middle* tail`：
  · 链的 SRC = 链首的 SRC_ADDR；链的 DST = 链尾的 DST_ADDR；
  · run 内 IMG_W/IMG_H/C_IN/C_OUT/GROUP/QUANT_SHIFT 必须相同（几何以**链首**为准）；
  · 链长**不在 FLAGS 里**（调度器扫链数出来 -> UnitExec.io.chain_len）；本代 L_MAX = 8。
```

**为什么改**：上一轮（C3.11a）的"塌缩单条目"是**当时的**硬件形式；A-1a/A-1b 把硬件扩成"L 切片链 +
扫链塌缩一次 `go`" ⇒ 编码必须**一项一算子**（§0.6）。**位打包没动** ⇒ 线格式仍兼容。

---

## 2) API（冻结）

```python
pack(d: dict) -> bytes            # 32 B（8 个小端字）
unpack(b: bytes) -> dict          # 逆
pack_table(descs: list) -> bytes  # 末尾自动追加哨兵项
validate(descs, desc_count, ddr_bytes) -> None | raise DescError()
desc_count_of(descs) -> int       # = 载荷项数（不含哨兵）= len(descs) - 1
```

`desc_count` 的**唯一真源** = `desc_count_of()`；`validate` 规则 (1)、自检判据四、
`_rule_probe` 的 R1/R1b、`--emit-meta` 头都调它 ⇒ 口径不可能再裂开。

实现里的两条硬化（都在 docstring 里写死，且都有"发火"证据）：

- `pack` 对 14 个字段做**位宽检查**（越界 ⇒ `ValueError`，**绝不静默截断**）。
- `unpack` 只收**恰好 32 B**；字内**高位保留段**由 `pack` 恒写 0（`w0/w3/w7` 的 `[31:16]`）。
- `FLAGS` 是**整 8 bit 字段透传**：`pack` **不**强制其保留子位 `bits[7:2]`，故由 `validate`
  规则 (2) 在**读**侧拒绝（`FLAGS_RESERVED_MASK = 0xFC`）；`FLAGS[1:0]` 的**链语义**由规则 (5) 管。

---

## 3) `validate` 六规则（A-2 修订版）

| # | 规则 | 报错串 |
|---|---|---|
| 1 | `DESC_COUNT` 与表长自洽：**`desc_count == 载荷项数`（= `len(descs) - 1`，不含哨兵）** | `DESC_COUNT <n> != <payload>` |
| 2 | 非法 `TYPE`（不在 `VALID_TYPES`）+ `FLAGS` 的保留位非 0（`FLAGS & 0xFC`） | `bad TYPE 0x%02x @<i>` / `FLAGS reserved bits 0x%02x != 0 @<i>` |
| 3 | 地址 32 B 对齐 + `IN_BYTES` 是 32 的倍数且 > 0 + SRC/DST 两区间都在 DDR 窗内 | `addr misalign @<i>` / `IN_BYTES bad @<i>` / `addr OOB @<i>` |
| 4 | 自环（`SRC_ADDR == DST_ADDR`） | `self-loop @<i>` |
| 5 | **FLAGS 语义 + 链结构**：载荷写成 `(P \| H M* T)*` + run 长 ≤ `CHAIN_L_MAX` + run 内几何 == 链首 | `middle without predecessor @<i>` / `tail without predecessor @<i>` / `head without tail @<i>` / `chain too long @<i>` / `chain geom mismatch @<i>` |
| 6 | 表尾哨兵：最后一项 `TYPE=0xFF`、`FLAGS=0`、且哨兵唯一 | `SENTINEL missing at tail (...)` / `SENTINEL FLAGS <n> != 0` / `SENTINEL inside payload @<i>` |

### 3.1 规则 (5)（本轮**重写**）

状态机实现（`validate` 里逐字就是这段逻辑）：

```
i = 0
while i < 载荷项数:
    f = FLAGS[i] & 0b11
    if f == MIDDLE(0b10):  raise "middle without predecessor @i"     # 链中/链尾不能自己起头
    if f == TAIL  (0b11):  raise "tail without predecessor @i"
    if f == PLAIN (0b01):  i += 1; continue                          # P：单点跳过
    # f == HEAD(0b00)：向后扫 middle* tail
    run, j = 1, i + 1
    while True:
        if j >= 载荷项数:                       raise "head without tail @i"    # 直接撞哨兵
        nf = FLAGS[j] & 0b11
        if nf not in (MIDDLE, TAIL):            raise "head without tail @i"    # 跟 plain/head
        run += 1
        if run > CHAIN_L_MAX:                   raise "chain too long @j"
        if geom[j] != geom[i]:                  raise "chain geom mismatch @j"
        if nf == TAIL: break
        j += 1
    i = j + 1
```

- `i` 分别是：**链首**下标（`head without tail`）、**越限那一条**（`chain too long`）、
  **第一个几何不一致的条目**（`chain geom mismatch`）、**没有前驱的那一条**（middle/tail 两档）。
- 检查次序：`chain too long` 先于 `chain geom mismatch`（同一条目上两者都成立时报前者）。
- `geom` = `(IMG_W, IMG_H, C_IN, C_OUT, GROUP, QUANT_SHIFT)`（常量 `CHAIN_GEOM_FIELDS`）。

### 3.2 规则 (1) 的口径（C3.11a 订正、本轮**不变**）

`desc_count == len(descs) - 1`（**不含**哨兵），与 `LayerSched.scala` 的 `io.descCount`
（"载荷项数，哨兵必须落在下标 `descCount` 上"）**逐字一致**；FSM 进表前**先取下标 `descCount` 项**
验哨兵。

### 3.3 规则 (2)–(6) 的作用域 = 载荷项

哨兵项（`TYPE=0xFF`、其余全 0）会撞规则 (3) 的 `IN_BYTES == 0` ⇒ 若 (2)–(5) 真遍历**全部**项，
任何合法表都会被判非法。故本实现把 (2)–(5) 限定在**载荷项**上，(1)/(6) 负责 COUNT 与哨兵自洽。

### 3.4 负对照已进代码（`_rule_probe` ⇒ 第五判据）

`_rule_probe()` 把"变异输入 → **期望**错误串"做成 **23 行**表（含 **4 条正对照**：合法表、
**合法 2 片链 `0b00,0b11`**、**合法 4 片链**、**合法 8 片链（= 本代 `L_MAX`）**），作为**第五个自检判据**
逐行比对（`SELFTEST_NEGCTL_RULES_OK`）：覆盖规则 **(1)** ×2（含"旧口径即错"那一档）、**(2)** 保留位、
**(3)** ×6、**(4)**、**(5)** 的**六档**（middle 无前驱 / tail 无前驱 / head 无 tail（跟 plain）/
head 无 tail（撞哨兵）/ chain too long（`CHAIN_L_MAX=8` ⇒ 用 **9 片链**顶）/ chain geom mismatch）
+ **三条合法链正对照**、**(6)** ×3。
删掉 `validate` 里任一条规则 ⇒ 对应行 `MISMATCH` ⇒ `SELFTEST_NEGCTL_RULES_OK=0`、`RESULT: FAIL`、
exit≠0（§6.6 的五组实证）。
**每条都拿 `validate` 的 `got` 串比 `expect` 串（不是"抛了就算过"）** ⇒ 直接把规则删掉也照样红
（§6.6 的 (A) 就是删 `chain too long` 那一行，本档当场 MISMATCH）。

---

## 4) 表是怎么从模型建出来的（`--selftest` 的正向向量）

### 4.1 枚举来源（只读 `ddr_traffic` / `bypass_traffic` / `fusion_chains`，不改一个字节）

| 量 | 计算值 | 外部冻结期望 | 出处 |
|---|---|---|---|
| `fuse_both` 整帧字节 | 12,576,000 | 12,576,000 | C0.2/C0.3 报告 |
| 融合**边**数 | 33（= 7 个 `3×3→1×1` + 26 个 `1×1→3×3`，**允许重叠**） | 33 / 7 / 26 | C0.2/C0.3、C3.0 |
| 旁路算子节点数 | maxpool 4 / resize 2 / add 2 / sigmoid 6 | 同 | C3.1 报告 |
| 旁路算子字节 | 4,736,000 / 640,000 / 1,536,000 / 33,600（Σ 6,945,600） | 同（逐类 + 总额） | C3.1 报告、`bypass_traffic.py` 冻结常量 |
| 旁路输入落在融合边界上的条数 | 0 | 0 | C3.1 的 `OVERLAP_PROBE` |
| 极大链数 / 链上节点数 / 链长直方图 | 19 / 52 / `{2:15, 4:2, 6:1, 8:1}` | 同 | C3.11b（`c3_fusion_chains.md`） |

drop 集合只用**公开**策略推导（`baseline` 与 `fuse_both` 的逐行字节差），不调私有 API。

### 4.2 执行序 = 表序 = ONNX 节点序（跳过不占描述符的算子）

`Relu` 折进生产者输出后处理（冻结 TYPE 表里没有它的码）；`Transpose`/`Reshape` 是布局算子，
由 C4/M2 折进寻址（spec §2/§8）。`Sigmoid` 虽在 `ELEMENTWISE_OPS` 里，但在 C3 是**进硬件的
旁路算子**（`0x14`）⇒ **占描述符**。

### 4.3 ★ 融合图 → 极大链 → run → **一项一算子**（A-2 的核心动作）

`fu33 + fu11` 的 33 条边**允许重叠**（14 个节点既是某条边的头、又是另一条边的尾）⇒ 融合图是
**19 条互不相交的简单路径（极大链）**（`_chain_nodes`；断言"每点度数 ≤1、每边恰落一条链"）：

| 极大链长（节点数 = 切片数） | 条数 | 节点数 | 边数 |
|---|---|---|---|
| 2 | 15 | 30 | 15 |
| 4 | 2 | 8 | 6 |
| 6 | 1 | 6 | 5 |
| 8 | 1 | 8 | 7 |
| **合计** | **19** | **52** | **33** |

**本代 `L_MAX = 8`（A-3b）** ⇒ 19 条极大链**每条都 ≤ 上限**（最长恰 8）⇒ **无需拆**（`_split_run` 仍
按"段数最少 + DP 选最便宜拆点"的规则跑，但 `limit=8` 下**每条链都只返回一段**；递推与
`fusion_chains.optimal_segments` 同款）⇒ 表里 **19 段 run**（**15 段 2 片** + **2 段 4 片** +
**1 段 6 片** + **1 段 8 片**），覆盖 **33/33** 条边，**拆点 0 处**：

| 拆点（被牺牲的边） | 中间张量字节 | 代价（一趟往返） | 落在哪条极大链 |
|---|---|---|---|
| **（无）** | 0 | **0** | `L_MAX=8` ⇒ 长 6/长 8 的链一次跑完 |

> **历史对照（A-2 的 `L_MAX=4` 表）**：当时长 6 与长 8 的链必须拆开 ⇒ 21 段 run（16×2 + 5×4）、
> 覆盖 31/33、拆点 2 处（`Conv_10→Conv_12` 819,200 B、`Conv_34→Conv_36` 25,600 B）= **1,689,600 B/帧**、
> md5 `ed00cad7…`。**该行已作废**（说明 `L_MAX` 的代价随上限提高而归零）。

⇒ **conv 项 = 52**（= 链上 conv 节点数，**一个算子一项**）+ 1 个自由 conv `Conv_0`（`0b01`）= 53；
载荷 = 53 + 14 个旁路项（皆 `0b01`）= **67** 项（+ 哨兵 = **68** 项 = **2176 B**）。
★ **项数与尺寸与"链是否拆"无关**（一项恒等于一个算子）⇒ A-3b 只改 FLAGS 角色与几何覆盖范围，
载荷/总项数**照旧是 67/68**。

| FLAGS | 项数 | 含义 |
|---|---|---|
| `0b00` head | **19** | 链首（= 表里的 run 数 = 极大链数） |
| `0b01` plain | **15** | 1 个自由 3×3 conv + 14 个旁路算子 |
| `0b10` middle | **14** | 链中（= Σ(run 长 − 2) = 0+0+2+4+6） |
| `0b11` tail | **19** | 链尾（= run 数） |

`validate` 正向通过（`POSITIVE_VALIDATE_OK=1`）。表字节的
**新 MD5 = `a45d0da0440a468f1b75788c9ad5bc14`**（2176 B，A-3b/L_MAX=8）；**旧值均已作废**：
A-2 的 `ed00cad736b82378a59bdeedc79f3b21`（2176 B，L_MAX=4 拆链）、
C3.11a 的 `4908613bdb67e2f650a0b99c0565cd41`（1344 B，塌缩单条目）、
C3.2 的 `374121088ff90bf7e2d5b20c06f7874f`（2176 B，两项一对 + 每片自身几何）。

**TYPE 直方图（最终表）**：`conv3x3=7  conv1x1=26  depthwise=20  maxpool=4  resize=2  add=2  sigmoid=6`
（`depthwise` = `3×3` 且 `group == C_in == C_out > 1`；逐片 TYPE 保留各片自身，见 §4.4）。

### 4.4 字段取值的口径（**本表的决定**；位打包才是冻结物）

| 字段 | 取法 |
|---|---|
| `TYPE` | 逐片取**该算子自身**：`kernel=[3,3]` 且 `group == C_in == C_out > 1` ⇒ `0x03`；`[3,3]` ⇒ `0x01`；`[1,1]` ⇒ `0x02`；旁路按 §1 的码 |
| `FLAGS` | **由链角色决定**（`head`/`middle`/`tail`）或 `plain`；与"`baseline` vs `fuse_both` 的 drop 集合推出来的那两位"**逐项对账**（两条独立推导 ⇒ §5 的 `链角色 vs drop 集合` 行） |
| `IMG_W`/`IMG_H` | 输出张量几何；★ **run 内一律取链首**（4 维按 NCHW 丢 N；非 4 维按**扁平单通道**，元素数 == 字节数） |
| `C_IN`/`C_OUT` | ★ **run 内一律取链首**（真值：链首的输入通道 / 链首的输出通道）；非链项取输入/输出张量的通道 |
| `GROUP`/`QUANT_SHIFT` | ★ **run 内一律取链首**；非链项按算子属性 / §1 的占位口径 |
| `STRIDE`/`PAD` | **逐片取自身**（conv 取 ONNX 属性；MaxPool/Resize 的倍率放 `STRIDE`；Add/Sigmoid 恒 `1/0`） |
| `SRC_ADDR`/`DST_ADDR` | **逐片取自身**：链首的 `SRC` = 链输入边界、链尾的 `DST` = 链输出边界；中间片的 `SRC/DST` = 各自的输入/输出张量槽位（**不搬**，只为确定性与规则 (3)/(4) 自洽；与 `run_chain_ab.sh` 的 TB 约定同款） |
| `IN_BYTES` | `align32(max(Σ读, 写))`，**逐片取自身**（仍是**上界**；规则 (3) 只把它当区间上界 / 32 B 粒度检查） |
| `LAYER_ID` | = **最终表序**（0…66），遥测身份 |

★ **run 内几何取链首**是**编码的硬要求**（规则 (5) 的 `chain geom mismatch` 与 RTL 的"只用链首几何"
同源）：中间/链尾片的**自身几何不写进表** —— 写了也会被硬件静默忽略，所以必须响亮拦住。

**DDR 窗**：`ddr_bytes = 2^28 = 268,435,456`（与 `DdrMaster.ADDR_W = 28` 同源）。
表的建议落点 `DESC_ADDR = 0x00100000`；激活槽位从 `0x00200000` 起 bump，89 个张量、
顶到 `0x01C505C0`（28.3 MiB，窗内）。

> **地址的"值"不是冻结物，位打包才是。** 判据只依赖**格式**（往返一致 + 六规则）。

### 4.5 ★ 融合流量（A-2 建立口径，A-3b 重算并**断言零拆点**）

两个数都用**冻结件** `ddr_traffic.compute_rows_fused(gv, drop_out=…, drop_in=…)` 算
（`drop_out` = 被融合边的**头**节点名、`drop_in` = 对应**尾**的 `input[0]` 张量 —— 与
`find_fusion_pairs*` 的 per-edge drop 口径逐字一致），并与 `fusion_chains.py` 的
`internal_edges_of_groups` **交叉对账**（两条独立实现，逐字同数）：

| 口径 | 整帧 DDR 流量 | 说明 |
|---|---|---|
| `baseline`（不融合） | 31,942,400 B | C0.1 复现基线 |
| **逐边全融合（33 条边，= `fuse_both` 下界）** | **12,576,000 B** | `info["per_edge_bytes"]`：**编码层**能表达全部 33 条边（A-2 关闭 O8） |
| **本代表（`L_MAX=8`，run ≤ 8）** | **12,576,000 B** | `info["chain_bytes"]`：**零拆点 ⇒ 恰好等于下界**（A-3b） |
| **拆点代价** | **+0 B（0%）** | `split_cost_bytes` = 0；`selftest` 里**断言** `chain_bytes == 12,576,000` |

**含旁路算子（`c3_traffic_full.md` 冻结的 +6,945,600 B，单独、可加）**：

| 口径 | 整帧（含旁路） | fps @275.9 MB/s |
|---|---|---|
| 逐边全融合（33 条边） | **19,521,600 B/帧** | **≈ 14.13** |
| **本代表（`L_MAX=8`，33 条边）** | **19,521,600 B/帧** | **≈ 14.13** |

> **历史对照（A-2 的 `L_MAX=4` 表）**：本代表 14,265,600 B/帧（31 条边）、含旁路 21,211,200 B/帧
> ≈ 13.01 fps、拆点 +1,689,600 B。**该行已作废**（`L_MAX` 提到 8 后代价归零）。

★ **这两个数是下界、fps 是上界**（只计激活 IO）—— 不含 12 个头张量的后处理（decode/NMS）、
突发对齐/填充浪费、权重装载。真实流量只会更高、fps 只会更低。

⇒ **必须交给 C4/M2 的两条**：① 编码已经能表达任意长的链（**不要**再按"两项一对"或"塌缩一项"产表）；
② **本代 `L_MAX=8` 下，本网（最长链 8）无需拆链**；换一张**更长**的网时，一段 run 不得超过
`CHAIN_L_MAX=8`，比 8 长的极大链要拆成多段（拆点那条边重走一趟 DDR），并把 `descCount` 写成载荷项数。

---

## 5) `--selftest` 逐字输出（健康）与退出码

命令（唯一的可用组合）：

```bash
cd /d/code/PDS/VexiiYeshenLinux/y1
PYTHONIOENCODING=utf-8 PYTHONPATH='../third_party/yunet/deps' \
  /d/code/PDS/NaxYeshenLinux/sim/reglogs/lxvenv/Scripts/python.exe tools/desc_table.py --selftest
```

```
desc_table.py --selftest —— 描述符冻结位打包（8×32 bit 小端 = 32 B/项）
MODEL=../third_party/yunet/yunet.onnx

== 1) 表来源（只读 ddr_traffic / bypass_traffic / fusion_chains；拿计算值比外部冻结常量） ==
  FUSE_BOTH_BYTES=12576000  (frozen 12576000) OK
  UNITS(边)=33 (= 7 个 3×3→1×1 + 26 个 1×1→3×3；**允许重叠**)  (frozen 33/7/26) OK
  CHAINS=19（极大链）  CHAIN_NODES=52  链长直方图=2:15;4:2;6:1;8:1  (frozen 19/52/2:15;4:2;6:1;8:1) OK
  RUNS(run 长 <= CHAIN_L_MAX=8)=19  run 长直方图=2:15;4:2;6:1;8:1  (frozen 19/2:15;4:2;6:1;8:1) OK
  COVERED_EDGES=33/33  UNMATCHED_EDGES=0（L_MAX=8 ⇒ 最长链 8 一次跑完、零拆点）  (frozen 33/0) OK
    拆点（重走一趟 DDR）: <无>
  PER_EDGE_BYTES=12576000（**编码层**：33 条边全部可表达 = fuse_both 下界）  (frozen 12576000) OK
  CHAIN_BYTES=12576000（**本代表**：run <= 8 实际表达的整帧）拆点代价=+0 B  (frozen 12576000) OK
  ★ 编码能表达全部 33 条边（12576000 B）；本代硬件 L_MAX=8 也**一次跑得完**最长链 8 片 ⇒ **零拆点**（拆点代价 0 B）⇒ 整帧 = 下界本身
  含旁路（+6945600 B）: 逐边全融合档 = 19521600 B/帧 ⇒ 14.13 fps；本代表(L_MAX=8) = 19521600 B/帧 ⇒ 14.13 fps（**下界**：只计激活 IO，不含头张量后处理/对齐填充/权重装载）
  链角色 vs drop 集合（两条独立推导；L_MAX=8 ⇒ 零拆点 ⇒ 必须**逐集合相等**）：role_drop_out=33(=33-0) / drop_out_nodes=33；role_drop_in=33(=33-0) / drop_in_tensors=33 ⇒ 一致 OK
  PAYLOAD=67 DESC_TOTAL=68 DESC_BYTES=2176  (frozen 67/68/2176) OK
  FLAGS: 0b00(head)=19  0b01(plain)=15  0b10(middle)=14  0b11(tail)=19  (frozen 0b00=19 0b01=15 0b10=14 0b11=19) OK
  FLAGS 直方图: 0b00=19  0b01=15  0b10=14  0b11=19
  DESC_COUNT 口径 = **载荷项数（不含哨兵）** = 67（哨兵落在下标 67）—— 与 RTL 的 descCount 一致
  BYPASS maxpool  nodes=4(frozen 4) my_bytes=4736000   bt_bytes=4736000   frozen=4736000   OK
  BYPASS resize   nodes=2(frozen 2) my_bytes=640000    bt_bytes=640000    frozen=640000    OK
  BYPASS add      nodes=2(frozen 2) my_bytes=1536000   bt_bytes=1536000   frozen=1536000   OK
  BYPASS sigmoid  nodes=6(frozen 6) my_bytes=33600     bt_bytes=33600     frozen=33600     OK
  BYPASS_BYTES=6945600 (frozen 6945600) OK
  OVERLAP_PROBE bypass_inputs=20 produced_by_fused_drop=0 (frozen 0) OK
  IN_BYTES 读==写 的项=44；读≠写 的项=23（后者按 max(Σ读, 写) 取上界）
  DDR_BYTES=268435456 (2^28，与 DdrMaster.ADDR_W=28 同源)；DESC_ADDR 建议 0x00100000
  张量槽位：89 个张量，arena_top=0x01C505C0 (28.314 MiB，窗内 OK)
  TYPE 直方图（最终表）: conv3x3=7  conv1x1=26  depthwise=20  maxpool=4  resize=2  add=2  sigmoid=6
  与 fusion_chains.py 交叉对账：链集合==1；L_MAX=8 -> 覆盖 33/33 牺牲 0 流量 12576000（frozen 12576000）；L=8 -> 覆盖 33 牺牲 0 流量 12576000（frozen 12576000） ⇒ OK

== 2) 表（逐项；执行序 = 表序 = ONNX 节点序，跳过逐元素/布局算子） ==
  idx type      flags  IMG_W IMG_H  C_IN C_OUT GROUP  STR  PAD        SRC        DST  IN_BYTES  QS LID
  0   conv3x3   0b01    320   320     3    16     1    2    1 0x00200000 0x0032C000   1638400   6   0
  1   conv1x1   0b00    320   320    16    16     1    1    0 0x004BC000 0x0064C000   1638400   6   1
  2   depthwise 0b11    320   320    16    16     1    1    1 0x0064C000 0x007DC000   1638400   6   2
  3   maxpool   0b01    160   160    16    16     1    2    0 0x0096C000 0x00AFC000   1638400   0   3
  4   conv1x1   0b00    160   160    16    16     1    1    0 0x00AFC000 0x00B60000    409600   6   4
  5   depthwise 0b10    160   160    16    16     1    1    1 0x00B60000 0x00BC4000    409600   6   5
  6   conv1x1   0b10    160   160    16    16     1    1    0 0x00C28000 0x00C8C000    819200   6   6
  7   depthwise 0b10    160   160    16    16     1    1    1 0x00C8C000 0x00D54000    819200   6   7
  8   conv1x1   0b10    160   160    16    16     1    1    0 0x00E1C000 0x00EE4000    819200   6   8
  9   depthwise 0b10    160   160    16    16     1    1    1 0x00EE4000 0x00FAC000    819200   6   9
  10  conv1x1   0b10    160   160    16    16     1    1    0 0x01074000 0x0113C000   1638400   6  10
  11  depthwise 0b11    160   160    16    16     1    1    1 0x0113C000 0x012CC000   1638400   6  11
  12  maxpool   0b01     80    80    64    64     1    2    0 0x0145C000 0x015EC000   1638400   0  12
  13  conv1x1   0b00     80    80    64    64     1    1    0 0x015EC000 0x01650000    409600   6  13
  14  depthwise 0b10     80    80    64    64     1    1    1 0x01650000 0x016B4000    409600   6  14
  15  conv1x1   0b10     80    80    64    64     1    1    0 0x01718000 0x0177C000    409600   6  15
  16  depthwise 0b11     80    80    64    64     1    1    1 0x0177C000 0x017E0000    409600   6  16
  17  maxpool   0b01     40    40    64    64     1    2    0 0x01844000 0x018A8000    409600   0  17
  18  conv1x1   0b00     40    40    64    64     1    1    0 0x018A8000 0x018C1000    102400   6  18
  19  depthwise 0b10     40    40    64    64     1    1    1 0x018C1000 0x018DA000    102400   6  19
  20  conv1x1   0b10     40    40    64    64     1    1    0 0x018F3000 0x0190C000    102400   6  20
  21  depthwise 0b11     40    40    64    64     1    1    1 0x0190C000 0x01925000    102400   6  21
  22  maxpool   0b01     20    20    64    64     1    2    0 0x0193E000 0x01957000    102400   0  22
  23  conv1x1   0b00     20    20    64    64     1    1    0 0x01957000 0x0195D400     25600   6  23
  24  depthwise 0b10     20    20    64    64     1    1    1 0x0195D400 0x01963800     25600   6  24
  25  conv1x1   0b10     20    20    64    64     1    1    0 0x01969C00 0x01970000     25600   6  25
  26  depthwise 0b10     20    20    64    64     1    1    1 0x01970000 0x01976400     25600   6  26
  27  conv1x1   0b10     20    20    64    64     1    1    0 0x0197C800 0x01982C00     25600   6  27
  28  depthwise 0b11     20    20    64    64     1    1    1 0x01982C00 0x01989000     25600   6  28
  29  resize    0b01     40    40    64    64     1    2    0 0x0198F400 0x01995800    102400   0  29
  30  add       0b01     40    40    64    64     1    1    0 0x0193E000 0x019AE800    204800   0  30
  31  conv1x1   0b00     40    40    64    64     1    1    0 0x019AE800 0x019C7800    102400   6  31
  32  depthwise 0b11     40    40    64    64     1    1    1 0x019C7800 0x019E0800    102400   6  32
  33  resize    0b01     80    80    64    64     1    2    0 0x019F9800 0x01A12800    409600   0  33
  34  add       0b01     80    80    64    64     1    1    0 0x01844000 0x01A76800    819200   0  34
  35  conv1x1   0b00     80    80    64    64     1    1    0 0x01A76800 0x01ADA800    409600   6  35
  36  depthwise 0b11     80    80    64    64     1    1    1 0x01ADA800 0x01B3E800    409600   6  36
  37  conv1x1   0b00     80    80    64     1     1    1    0 0x01BA2800 0x01C06800    409600   6  37
  38  conv3x3   0b11     80    80    64     1     1    1    1 0x01C06800 0x01C08100      6400   6  38
  39  conv1x1   0b00     40    40    64     1     1    1    0 0x019F9800 0x01C09A00    102400   6  39
  40  conv3x3   0b11     40    40    64     1     1    1    1 0x01C09A00 0x01C0A040      1600   6  40
  41  conv1x1   0b00     20    20    64     1     1    1    0 0x0198F400 0x01C0A680     25600   6  41
  42  conv3x3   0b11     20    20    64     1     1    1    1 0x01C0A680 0x01C0A820       416   6  42
  43  conv1x1   0b00     80    80    64     4     1    1    0 0x01BA2800 0x01C0A9C0    409600   6  43
  44  depthwise 0b11     80    80    64     4     1    1    1 0x01C0A9C0 0x01C10DC0     25600   6  44
  45  conv1x1   0b00     40    40    64     4     1    1    0 0x019F9800 0x01C171C0    102400   6  45
  46  depthwise 0b11     40    40    64     4     1    1    1 0x01C171C0 0x01C18AC0      6400   6  46
  47  conv1x1   0b00     20    20    64     4     1    1    0 0x0198F400 0x01C1A3C0     25600   6  47
  48  depthwise 0b11     20    20    64     4     1    1    1 0x01C1A3C0 0x01C1AA00      1600   6  48
  49  conv1x1   0b00     80    80    64     1     1    1    0 0x01BA2800 0x01C1B040    409600   6  49
  50  conv3x3   0b11     80    80    64     1     1    1    1 0x01C1B040 0x01C1C940      6400   6  50
  51  conv1x1   0b00     40    40    64     1     1    1    0 0x019F9800 0x01C1E240    102400   6  51
  52  conv3x3   0b11     40    40    64     1     1    1    1 0x01C1E240 0x01C1E880      1600   6  52
  53  conv1x1   0b00     20    20    64     1     1    1    0 0x0198F400 0x01C1EEC0     25600   6  53
  54  conv3x3   0b11     20    20    64     1     1    1    1 0x01C1EEC0 0x01C1F060       416   6  54
  55  conv1x1   0b00     80    80    64    10     1    1    0 0x01BA2800 0x01C1F200    409600   6  55
  56  depthwise 0b11     80    80    64    10     1    1    1 0x01C1F200 0x01C2EC00     64000   6  56
  57  conv1x1   0b00     40    40    64    10     1    1    0 0x019F9800 0x01C3E600    102400   6  57
  58  depthwise 0b11     40    40    64    10     1    1    1 0x01C3E600 0x01C42480     16000   6  58
  59  conv1x1   0b00     20    20    64    10     1    1    0 0x0198F400 0x01C46300     25600   6  59
  60  depthwise 0b11     20    20    64    10     1    1    1 0x01C46300 0x01C472A0      4000   6  60
  61  sigmoid   0b01   6400     1     1     1     1    1    0 0x01C48240 0x01C49B40      6400   4  61
  62  sigmoid   0b01   1600     1     1     1     1    1    0 0x01C4B440 0x01C4BA80      1600   4  62
  63  sigmoid   0b01    400     1     1     1     1    1    0 0x01C4C0C0 0x01C4C260       416   4  63
  64  sigmoid   0b01   6400     1     1     1     1    1    0 0x01C4C400 0x01C4DD00      6400   4  64
  65  sigmoid   0b01   1600     1     1     1     1    1    0 0x01C4F600 0x01C4FC40      1600   4  65
  66  sigmoid   0b01    400     1     1     1     1    1    0 0x01C50280 0x01C50420       416   4  66
  67  sentinel  0b00      0     0     0     0     0    0    0 0x00000000 0x00000000         0   0   0

== 3) 判据（五条，缺一不可；每条都拿计算值比**外部**期望） ==
SELFTEST_ROUNDTRIP  ROUNDTRIP_BAD=0 RAW_WORD_BAD=0 SENTINEL_OK=1 POSITIVE_VALIDATE_OK=1 TABLE_SOURCE_OK=1
  TABLE_BYTES=2176 MD5=a45d0da0440a468f1b75788c9ad5bc14
SELFTEST_ROUNDTRIP_OK=1
SELFTEST_NEGCTL_BITFLIP  w6: IN_BYTES 0x190000 → 0x190020（期望 0x190020）；其余字段不变=1
  w7 探针: LAYER_ID 5 → 4（期望 4）
SELFTEST_NEGCTL_BITFLIP_OK=1
SELFTEST_NEGCTL_BADTYPE  raise=1 msg='bad TYPE 0x77 @3' (期望 'bad TYPE 0x77 @3')
SELFTEST_NEGCTL_BADTYPE_OK=1
SELFTEST_NEGCTL_COUNT  desc_count=68（旧口径：表长含哨兵）⇒ raise=1 msg='DESC_COUNT 68 != 67'；desc_count=66 ⇒ raise=1 msg='DESC_COUNT 66 != 67'（正确口径 = 载荷 67）
  附加（哨兵 FLAGS≠0）: raise=1 msg='SENTINEL FLAGS 3 != 0'
SELFTEST_NEGCTL_COUNT_OK=1
SELFTEST_NEGCTL_RULES  规则 (1)–(6) 负对照表（_rule_probe）：cases=23 mismatch=0
    R0 legal table (positive ctl)  expect='' got='' OK
    R1 COUNT == len(descs) (old incl-sentinel) expect='DESC_COUNT 68 != 67' got='DESC_COUNT 68 != 67' OK
    R1b COUNT == payload-1         expect='DESC_COUNT 66 != 67' got='DESC_COUNT 66 != 67' OK
    R2 FLAGS reserved 0xFC         expect='FLAGS reserved bits 0xfc != 0 @0' got='FLAGS reserved bits 0xfc != 0 @0' OK
    R3 SRC misalign (+4)           expect='addr misalign @0' got='addr misalign @0' OK
    R3 DST misalign (+4)           expect='addr misalign @0' got='addr misalign @0' OK
    R3 IN_BYTES == 0               expect='IN_BYTES bad @0' got='IN_BYTES bad @0' OK
    R3 IN_BYTES % 32 != 0          expect='IN_BYTES bad @0' got='IN_BYTES bad @0' OK
    R3 SRC out of DDR window       expect='addr OOB @0' got='addr OOB @0' OK
    R3 DST out of DDR window       expect='addr OOB @0' got='addr OOB @0' OK
    R4 self-loop (SRC == DST)      expect='self-loop @0' got='self-loop @0' OK
    R5 middle without predecessor @0 expect='middle without predecessor @0' got='middle without predecessor @0' OK
    R5 tail without predecessor @0 expect='tail without predecessor @0' got='tail without predecessor @0' OK
    R5 head without tail @1 (follower=plain) expect='head without tail @1' got='head without tail @1' OK
    R5 head without tail @66 (hits SENTINEL) expect='head without tail @66' got='head without tail @66' OK
    R5 chain > CHAIN_L_MAX=8 rejected expect='chain too long @9' got='chain too long @9' OK
    R5 chain geom mismatch @2      expect='chain geom mismatch @2' got='chain geom mismatch @2' OK
    R5 legal 2-slice chain 0b00,0b11 (pos ctl) expect='' got='' OK
    R5 legal 4-slice chain 0b00..0b11 (pos ctl) expect='' got='' OK
    R5 legal 8-slice chain 0b00..0b11 (pos ctl, = L_MAX) expect='' got='' OK
    R6 SENTINEL inside payload     expect='SENTINEL inside payload @1' got='SENTINEL inside payload @1' OK
    R6 SENTINEL missing at tail    expect='SENTINEL missing at tail (last TYPE=0x01)' got='SENTINEL missing at tail (last TYPE=0x01)' OK
    R6 SENTINEL FLAGS != 0         expect='SENTINEL FLAGS 1 != 0' got='SENTINEL FLAGS 1 != 0' OK
SELFTEST_NEGCTL_RULES_OK=1

RESULT: PASS
```

**exit code = 0**；五条判据全绿，其中四条负对照**确实"发了火"**（错误串逐字对上）。
**两遍独立重跑的表指纹逐字不变**：`TABLE_BYTES=2176 MD5=ed00cad736b82378a59bdeedc79f3b21`
（`for i in 1 2; do … done` 两次都是同一行）。

---

## 6) 判据为什么"真能发火"（扰动证据）

五条判据都**不自己比自己**：正向拿 14 个字段逐字段比 + **第二遍按位表独立算出的 8 个字**
（按字节偏移 `struct.unpack_from("<8I")` 直解，**不经 `unpack`**）比；负对照拿**期望的错误串**比；
流量拿**冻结口径**（`ddr_traffic`）算、再与 `fusion_chains` 交叉对账；链/角色拿**两条独立推导**
（链角色 vs `baseline`/`fuse_both` 的 drop 集合）对账。

### 6.1 Step 2 的"先红"（当时四条全是空壳；现在还有第五条）

```
P0 空实现（pack/unpack/pack_table/validate 全是空壳）
  SELFTEST_ROUNDTRIP  ROUNDTRIP_BAD=870 RAW_WORD_BAD=68 SENTINEL_OK=1 POSITIVE_VALIDATE_OK=1 TABLE_SOURCE_OK=1
  SELFTEST_ROUNDTRIP_OK=0
  SELFTEST_NEGCTL_BITFLIP_OK=0
  SELFTEST_NEGCTL_BADTYPE_OK=0
  SELFTEST_NEGCTL_COUNT_OK=0
  SELFTEST_NEGCTL_RULES_OK=0       （validate 空壳 ⇒ 23 条变异/正对照全 MISMATCH）
  RESULT: FAIL      exit=1
```

### 6.2 逐条判据的定向扰动（C3.2 沿用的四组，仍然有效）

| 扰动（副本上改一处） | 期望 | 实测 |
|---|---|---|
| **P1** `w0` 位段互换（TYPE↔FLAGS） | 判据 1 红 | `ROUNDTRIP_BAD=0`（**对称 ⇒ 往返抓不到**）但 `RAW_WORD_BAD=47` ⇒ 红 |
| **P2** `w1` IMG_W/IMG_H 对调（同样对称） | 判据 1 红 | `ROUNDTRIP_BAD=0`、`RAW_WORD_BAD=6`（6 个 `W≠H` 的 sigmoid 项）⇒ 红 |
| **P3** `pack_table` 追加全 0 而不是哨兵 | 判据 1 红 | `SENTINEL_OK=0`、`RAW_WORD_BAD=1` |
| **P4** `unpack` 忽略 `w6` | 判据 2 红 | `SELFTEST_NEGCTL_BITFLIP_OK=0` + 判据 1 红（`ROUNDTRIP_BAD`）|
| **P5** `validate` 去掉非法 TYPE 检查 | 判据 3 红 | `raise=0 msg=''` ⇒ `SELFTEST_NEGCTL_BADTYPE_OK=0` |
| **P6** `validate` 去掉 COUNT 检查 | 判据 4 红 | ±1 都不报 ⇒ `SELFTEST_NEGCTL_COUNT_OK=0` |
| **P7** 建表不表达融合（`FLAGS` 恒 `0b01`） | 判据 1 红 | `CHAINS/RUNS` 行与 `FLAGS` 直方图 MISMATCH、`TABLE_SOURCE_OK=0` |
| **P8** `validate` 删掉规则 (4) 自环整块 | 判据 5 红 | `R4 self-loop … expect='self-loop @0' got='' MISMATCH` ⇒ 红 |

**P1/P2 是关键**：它们让 `pack/unpack` 保持**对称**（往返恒真），只有"第二遍独立字级对账"抓得到。

### 6.6 ★ A-2/A-3b 修订后的规则探针红证（五组，副本上做，**不入库**）

在 `y1/tools/_red_*.py`（`desc_table.py` 的**临时副本**，跑完即删）上做五组突变，各跑同一命令
（`--selftest`）。**五组都 exit=1**，且红的**只**是相关的那几行：

**(A) 删掉 `chain too long` 检查**（A-3b 后再做一遍，`CHAIN_L_MAX=8` ⇒ 探针用 **9 片链**）
⇒ 只有那一档变红（其余规则与正对照全绿）；9 片链不再被拦，往后多走一条才在 `@10` 爆出另一类错：

```
SELFTEST_ROUNDTRIP_OK=1
SELFTEST_NEGCTL_RULES  规则 (1)–(6) 负对照表（_rule_probe）：cases=23 mismatch=1
    R5 chain > CHAIN_L_MAX=8 rejected expect='chain too long @9' got='middle without predecessor @10' MISMATCH
    R5 legal 8-slice chain 0b00..0b11 (pos ctl, = L_MAX) expect='' got='' OK
SELFTEST_NEGCTL_RULES_OK=0
RESULT: FAIL
   exit=1
```

⇒ **`chain too long` 这一档是有牙的**（把检查摘掉 ⇒ 该行 MISMATCH ⇒ `SELFTEST_NEGCTL_RULES_OK=0`、
`RESULT: FAIL`、exit≠0）；绿表里它逐字命中 `chain too long @9`（§5 第 131 行）。

**(B) 删掉 `middle`/`tail` 的"无前驱"两档** ⇒ 那两条精确变红：

```
    R5 middle without predecessor @0 expect='middle without predecessor @0' got='head without tail @0' MISMATCH
    R5 tail without predecessor @0 expect='tail without predecessor @0' got='head without tail @0' MISMATCH
SELFTEST_NEGCTL_RULES_OK=0    RESULT: FAIL    exit=1
```

**(C) 删掉 `chain geom mismatch` 检查** ⇒ 只有那一档变红：

```
    R5 chain geom mismatch @2      expect='chain geom mismatch @2' got='' MISMATCH
SELFTEST_NEGCTL_RULES_OK=0    RESULT: FAIL    exit=1
```

**(D) 把状态机换成 C3.11a 的旧规则（`0b11` 保留 ⇒ 拒绝）** ⇒ **本仓库当前的合法表当场被判非法**
（`POSITIVE_VALIDATE_ERR=reserved FLAGS 0b11 @2`），12 行变红：

```
SELFTEST_ROUNDTRIP  ... POSITIVE_VALIDATE_OK=0 TABLE_SOURCE_OK=1
  POSITIVE_VALIDATE_ERR=reserved FLAGS 0b11 @2
SELFTEST_NEGCTL_RULES  cases=23 mismatch=13
    R0 legal table (positive ctl)  expect='' got='reserved FLAGS 0b11 @2' MISMATCH
    R5 tail without predecessor @0 expect='tail without predecessor @0' got='reserved FLAGS 0b11 @0' MISMATCH
    R5 legal 2-slice chain 0b00,0b11 (pos ctl) expect='' got='reserved FLAGS 0b11 @2' MISMATCH
    R5 legal 4-slice chain 0b00..0b11 (pos ctl) expect='' got='reserved FLAGS 0b11 @2' MISMATCH
    R5 legal 8-slice chain 0b00..0b11 (pos ctl, = L_MAX) expect='' got='reserved FLAGS 0b11 @2' MISMATCH
    ...
SELFTEST_NEGCTL_RULES_OK=0    RESULT: FAIL    exit=1
```

**这就是"编码又改了一轮"的硬证据**：C3.11a 里**非法**的 `0b11` 现在**合法且必需**（链尾）。

**(E) 把旧的"两项一对"规则塞回去**（`bit0=0` 的头必须紧跟 `bit1=1` 的尾、且尾不得接在 `bit0=1` 后）
⇒ 新规则的 4 档探针变红（旧读法挡不住链式编码的"三类错"）：

```
    R5 middle without predecessor @0 expect='middle without predecessor @0' got='head without tail @0' MISMATCH
    R5 tail without predecessor @0 expect='tail without predecessor @0' got='tail without head @0' MISMATCH
    R5 chain > CHAIN_L_MAX=8 rejected expect='chain too long @9' got='tail without head @10' MISMATCH
    R5 chain geom mismatch @2      expect='chain geom mismatch @2' got='' MISMATCH
SELFTEST_NEGCTL_RULES_OK=0    RESULT: FAIL    exit=1
```

（★ 有意思的一点：**(E) 里 `R0` 仍然绿** —— 本表的链式编码**恰好也满足**旧的"位对"读法，
因为 `head/middle`（`0b00/0b10`）后面总是 `bit1=1` 的 `middle/tail`。⇒ 旧的位对规则**认不出**
"链太长/中尾无前驱/几何不一致"这三类错，所以**必须**换成链状态机。）

---

## 7) 给 C4/M2 与 C3.4 的硬要求 + 开口项

**硬要求**

1. **C4/M2 的转换器必须产这个格式**：**一项 = 一个算子**（`FLAGS[1:0]` 四态），链上 conv 按角色写
   `head`/`middle`/`tail`，链外写 `plain`；要改走 spec 修订（R3）—— 改一处也要同步
   `desc_table.py` + `DescDefs.scala` + 本报告，并重跑 C3.4 的交叉对账闸门。**位打包本轮未变**
   ⇒ `DescDefs.scala` 无需改动。
2. **★ 产表必须守链长上限 `CHAIN_L_MAX`（本代 = 8，与 RTL 的 `L_MAX` 同口径）**：一段 run ≤ 8 片；
   **本网最长极大链恰 8 ⇒ 无需拆**（零拆点、整帧 = 12,576,000 B）；换一张**更长**的网时，
   比 8 长的极大链要拆成多段（拆点那条边重走一趟 DDR）。**链长不写进 FLAGS**。
3. **run 内 6 个几何字段必须一致**（取链首），否则规则 (5) 拒绝、RTL 也响亮 `err`。
4. **`DESC_COUNT` = 载荷项数（不含哨兵）**；表尾必须有 `TYPE=0xFF, FLAGS=0` 的哨兵项，
   且哨兵落在下标 `descCount` 上。
5. `DescDefs.scala`（C3.4）的字段切片必须与 §1 **逐字段一致**：
   `w0[7:0]/w0[15:8]`、`w1[15:0]/w1[31:16]`、`w2[15:0]/w2[31:16]`、`w3[7:0]/w3[11:8]/w3[15:12]`、
   `w4/w5/w6`、`w7[7:0]/w7[15:8]`；保留位 `[31:16]` 恒 0。`FLAGS` 两位的**访问器名**
   （`HEAD = !bit0`、`TAIL = bit1`）本轮不变 ⇒ C3.4 的 17 字段对账向量照旧。
6. 表本身 32 B 对齐（`DescFetch` 的 `descAddr`）；每项 32 B、小端、`word(2k)=data[k]低 32`。

**开口项（必须在 spec 修订里处置，不得各自就地发明）**

| # | 开口项 | 说明与建议 |
|---|---|---|
| O1 | **`Add` 是双输入算子，但格式只有一个 `SRC_ADDR`** | 冻结语义里 `Add` 的两路输入"一路来自 `IN_FROM_PREV`/融合缓冲、一路来自 `SRC_ADDR`"（C3.7）。本网的两个 `Add` 两路**都来自 DDR**，格式表达不了第二路。⇒ 要么 spec 修订补源地址字段/约定，要么转换器让一路落在片上。 |
| O2 | `IN_BYTES` 是**上界**而非精确 DMA 长度 | 变通道 1×1 之外还有 MaxPool/Resize/Add/链上各片。RTL 必须按 `IMG_W/IMG_H/C_IN/C_OUT` 算真实长度；`IN_BYTES` 只用于规则 (3) 与 32 B 粒度检查。 |
| O3 | 非 4 维张量的几何解释 | 见 §4.4 的"扁平单通道"决定。若 C4/M2 要 `(C=1,W=80,H=80)` 语义，走 spec 修订 + 重生成向量。 |
| O4 | `QUANT_SHIFT` 是**占位**口径 | 6/4/0 来自项目冻结的夹具与 C3.6/C3.7；真实按层 scale/zero-point 属 C4/M2 的量化器。★ 注意它**在 run 内必须一致**（规则 (5)），转换器要保证。 |
| O5 | `Relu` 没有 TYPE 码 | 本任务按"折进生产者输出后处理"处理（不占描述符）。若需独立后处理单元，走 spec 修订补 TYPE。 |
| O6 | 本表的**地址值**是一次性 bump 布局 | 只为 C3.4 交叉对账确定；真实转换器应做内存复用，只要满足六规则即可。 |
| O7 | `desc_table.py --emit-hex` / `--emit-meta` | 已落地（C3.4 实现，仍是同一真源）。A-2/A-3b 只改了表内容与指纹，出口格式不变。 |
| **O8** | ~~>2 切片的融合链不可表达~~ ⇒ **已关闭**（A-2 关编码，A-3b 关硬件） | 逐算子链式编码**没有链长上限**（33 条边全部可表达 = 12,576,000 B）；硬件那边 A-3b 把 `CHAIN_L_MAX` 提到 **8**、与 RTL 的 `L_MAX=8` 同口径 ⇒ 长 6/长 8 的链**不再拆**、**零拆点** ⇒ 整帧 = **12,576,000 B**（下界本身）。**代价这一项已消除**（面积/实例的背景见 `reports/c3_fusion_chains.md` §6）。 |
| **O9** | 链上**非 conv** 项 | 编码只约束 FLAGS/几何，**不**检查"链上必须是 conv"。RTL（`LayerSched`）把链上的旁路项判为响亮 `err`。若 C4/M2 需要"链上串旁路"，走 spec 修订（并在 `validate` 补同款规则）。 |
| **O10** | 拆点策略（哪条边去牺牲） | 本表用"段数最少 + DP 选最便宜的边"（= `fusion_chains.optimal_segments` 同款）。若 C4/M2 想让**某条特定边**牺牲（例如为了让中间张量复用同一块缓冲），需 spec 修订明确策略 —— 否则表会与 `TABLE_MD5_FROZEN` 漂开。 |

---

## 8) 结论

- 描述符的**位打包已冻结**（8×32-bit 小端 = 32 B/项），API 五个函数（含 `desc_count_of`），
  `validate` 六规则全部实现；六规则的负控制**全部进代码**（`_rule_probe` ⇒ `SELFTEST_NEGCTL_RULES_OK`，
  **23 行含 4 条正对照**，删掉任一条规则当场红，§6.6）。
- ★ **A-2 修订已落地**：**一项 = 一个算子**（`head`/`plain`/`middle`/`tail`），**链** = 极大 run
  `head middle* tail`、`SRC` 取链首、`DST` 取链尾、**run 内几何一致**、**链长不在 FLAGS 里**
  （调度器给 `UnitExec.io.chain_len`；**本代 `L_MAX = 8`**，A-3b）；规则 (5) = 链状态机 `(P | H M* T)`。
  **位打包未变 ⇒ 线格式兼容**。
- ★ **A-3b 已落地（契约对齐）**：`CHAIN_L_MAX` **4 → 8**，与 RTL 的 `L_MAX=8`（`8120c64`）同口径
  ⇒ 长 6/长 8 的极大链**不再拆**、**零拆点**、`split_cost_bytes=0`。
- 重生成的真实 YuNet 表：**68 项 = 2176 B**（项数不随"拆不拆"变），FLAGS 直方图
  `{0b00:19, 0b01:15, 0b10:14, 0b11:19}`，**新 MD5 = `a45d0da0440a468f1b75788c9ad5bc14`**
  （旧 `ed00cad7…`（A-2/L=4）、`4908613bdb…` / 1344 B、`374121088f…` / 2176 B 均作废）；
  `RESULT: PASS`、exit 0、两遍重跑指纹不变。
- **O8 已关闭（编码 + 硬件两边都到位）**：编码层 **12,576,000 B/帧**（33/33 条边，**打印并断言**）；
  本代表（`L_MAX=8`）**也是 12,576,000 B/帧**（**零拆点 ⇒ 等于下界本身**）。
  含旁路（+6,945,600 B）= **19,521,600 B/帧 ≈ 14.13 fps**（**下界**，fps 是上界）。
- 上游只读工具（`ddr_traffic.py` / `bypass_traffic.py` / `fusion_chains.py` / `fusion_buffer.py`）
  与全部 RTL **零改动**；C3.4 的交叉对账闸门（`tools/run_desc_ab.sh`，表尺寸仍 2176 B、
  `TEST_IDX` 仍 `0 1 2 67`）在新表/新指纹下**照跑 PASS**（§9）。

## 9) C3.4 交叉对账闸门（`tools/run_desc_ab.sh`）—— A-3b 后的实测

`bash tools/run_desc_ab.sh` ⇒ **`RESULT: PASS`、exit 0**，关键行：

```
TABLE_MD5（单一真源 desc_table.TABLE_MD5_FROZEN）=a45d0da0440a468f1b75788c9ad5bc14
EMIT_TABLE BYTES=2176 ITEMS=68 MD5=a45d0da0440a468f1b75788c9ad5bc14
用例 BASE=4096 (MEMSZ=8192, 表 2176 B)  idx ∈ {0 1 2 67}
正对照 PASS：4/4 项的 W0..W7 与 desc_table 期望**逐字**相等，17 个字段**逐字段**与 unpack 相等
负对照 A[位] / A2[字序] / A3[小端] / B[对齐] / C[越界] = OK
比较器自检 = OK（扰动一个期望字 ⇒ WORD_BAD=1）
网表突变 = OK（取字顺序突变 ⇒ 8 个字按预测对调被抓；STRIDE 切片突变 ⇒ 恰好 1 个字段被抓）
向量来源 = OK（desc_table.py --emit-hex/--emit-meta；表指纹 a45d0da0440a468f1b75788c9ad5bc14 == 冻结值，未漂）
RESULT: PASS
```

★ **前提跟着表走，但这次没挪位**（已在 `run_desc_ab.sh` 注释里记下这次 md5 迁移）：
表**仍 68 项 = 2176 B**、**哨兵仍在下标 67**、被测 **idx1 仍 head(`0b00`)**、**idx2 仍 tail(`0b11`)**、
M6 前提（idx0 的 `STRIDE=2 != PAD=1`）不变 ⇒ `TEST_IDX`/`ADDR_BASE`/`mkvar.py` 的 2176 断言**照旧**。

**Files**

- `y1/tools/desc_table.py`（C3.2 创建；C3.11a 改塌缩编码；**A-2 再改**：docstring 的 FLAGS/链/O8 段、
  常量（`FLAGS_HEAD/PLAIN/MIDDLE/TAIL`、`CHAIN_L_MAX`、`CHAIN_GEOM_FIELDS`、冻结指纹）、
  `validate` 规则 (5) 链状态机、`_chain_nodes` + `_split_run`（取代 `_decompose_chains`/`_merge_pair`）、
  `build_table` 的逐算子建表 + 双口径流量 + 交叉对账、`_rule_probe`；
  **A-3b 再把** `CHAIN_L_MAX` 4→8、重生成 `PAYLOAD/DESC_TOTAL/TABLE_MD5/FLAGS_HIST` 等冻结常量、
  加零拆点的 `assert chain_bytes == 12_576_000`、`_rule_probe` 加"合法 8 片链"正对照（22→23 行））
- `y1/reports/c3_descriptor_format.md`（本文件；C3.2 创建，C3.11a 增 §0.5，A-2 增 §0.6，
  **A-3b 增 §0.7 并重刷 §1/§3/§4/§5/§6.6/§7/§8/§9 的数字与口径**）
- `y1/reports/c3_fusion_chains.md`（C3.11b 创建；**A-2 更新结论**：L 决定**硬件**能跑多长；
  **A-3b 记 L 已提到 8、拆点代价归零**）
- `y1/tools/run_desc_ab.sh`（C3.4 创建；C3.11a 同步 2176→1344 B；**A-2 同步回 2176 B、`TEST_IDX` → `0 1 2 67`**）
