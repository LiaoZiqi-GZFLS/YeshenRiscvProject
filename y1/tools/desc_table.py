#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""描述符表（C3 层调度器）的**冻结位打包** + 打包/解包/校验 —— **C4/M2 的机器可读契约**。

单一真源（spec R3 的落实）
--------------------------
本文件是描述符**位打包**的唯一真源：
  · C4/M2 的转换器（模型 → 表）必须产**这个**格式；
  · RTL 侧 `y1/rtl/DescDefs.scala`（C3.4）必须与它**逐字段一致**，两处用**同一组测试向量**交叉对账；
  · 要改格式 ⇒ 走 **spec 修订**（`docs/superpowers/specs/2026-10-09-y1-c3-scheduler-design.md`
    §3 + R3），不得让任一侧"就地改"。
本文件**不**产生 RTL、不碰 SoC、不上板（纯离线 Python）。

冻结的位打包（spec §3 冻结语义、本任务冻结位打包；逐字）
--------------------------------------------------------
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

★ FLAGS 语义（**A-2 spec 修订：改用"逐算子链式"编码 —— 一项 = 一个算子**）
  bit0=OUT_TO_DDR  ：1 ⇒ 输出落 DDR
  bit1=IN_FROM_PREV：1 ⇒ 输入取「**上一个算子**」的片上输出（DDR 读被这一位覆盖）
  bits[7:2] 保留 = 0（由 `validate` 规则 (2) 在**读**侧强制）
  四种组合**逐个显式定义**（这就是全部合法取值）：
    0b00 HEAD   —— **链首**：读 DDR(`srcA`) -> 计算 -> 输出**留片上**（进链的第一块中间缓冲）
    0b01 PLAIN  —— **普通单元**：读 DDR(`srcA`) -> 计算 -> 写 DDR(`dstA`)。一单元一份搬运。
    0b10 MIDDLE —— **链中**：输入取**上一个算子的片上输出** -> 计算 -> 输出**留片上**
    0b11 TAIL   —— **链尾**：输入取**上一个算子的片上输出** -> 计算 -> 写 DDR(`dstA`)

★ **链（chain）** = 一段**极大**的相邻条目序列 `head middle* tail`（`plain` = 链外的单点）：
  · 语义：`head` 读 DDR、输出留片上；每个 `middle` 从上一片的片上输出接着算、输出仍留片上；
    最后一个 `tail` 把结果写回 DDR。**中间张量结构性零 DDR**（`rtl/UnitExec.scala` 的 L 切片
    交错行锁步；`LayerSched.scala` 遇 `head` 就**逐项向前扫**、`tail` 收链 ⇒ **塌缩成一次 `go`**）。
  · 链的 `SRC` = **链首**条目的 `SRC_ADDR`，`DST` = **链尾**条目的 `DST_ADDR`；`UnitExec` 拿到的
    "链描述符" = **链首的 8 个字 + 链尾的 `DST_ADDR`**（`rtl/LayerSched.scala` 的 CHAINSCAN 锁存）。
  · **同一段 run 里所有条目的 `IMG_W/IMG_H/C_IN/C_OUT/GROUP/QUANT_SHIFT` 必须相同**（这就是"融合"
    的含义：硬件只用**链首**的几何、逐片锁步行进）⇒ `validate` 规则 (5) 的 `chain geom mismatch`
    响亮拦住"中间几片几何被静默忽略"。`TYPE`（3×3 / 1×1 / depthwise）、`STRIDE`/`PAD`、`SRC/DST`
    与**权重**可以**逐片不同**（权重带外预载，不进描述符）。
  · ★ **run 的长度不在 `FLAGS` 里**：位打包一字未动 —— `FLAGS[1:0]` 只表达上面那**逐算子四态**；
    链长由**调度器**扫链时自己数出来（`LayerSched.scala` 的 CHAINSCAN/CHAINSCANW），再作为
    **独立入参**交给 `UnitExec.io.chain_len`（A-1b：A-1a 的 `FLAGS[4:2]` 链长编码**已作废**，
    `FLAGS[7:2]` 收回保留、必须为 0）。
  · `L_MAX = 8`（**本代**硬件的切片实例数上限；见常量 `CHAIN_L_MAX`）：**一段 run 的长度不得超过它**，
    超出 ⇒ 表非法（规则 (5) 的 `chain too long @i`；RTL 同款响亮 `err`）⇒ **比 `L_MAX` 长的融合链
    必须在表里拆开**（拆点那条边重走一趟 DDR，见下"O8 已关闭"）。★ 本网最长极大链恰为 **8** ⇒
    等于 `L_MAX` ⇒ **零拆点**（`_split_run` 对每条极大链都返回一段；见 `RUNS_FROZEN`）。

★★ 这是对**上一轮冻结契约**（C3.11a，commit `63b09df`）的又一次**刻意 spec 修订** ★★
  C3.11a 把融合写成**一个** `FLAGS=0b10` 的**塌缩条目**（"一次 `go` 跑头/尾两个切片"），并宣布
  "**>2 切片的融合链不可表达**"（旧 O8）。**A-1b 把出货 RTL 改成逐算子链式编码**：`LayerSched`
  遇 `head` 逐项向前扫（`middle` 继续、`tail` 收链）⇒ 塌缩成**一次** `UnitExec.go`，链长作**独立入参**
  交给 `UnitExec`。⇒ 描述符必须**一个算子一项**：`0b10` 不再是"塌缩的融合对"而是**链中**（进片上、
  出片上），`0b11` 不再是"保留/非法"而是**链尾**（进片上、出 DDR），`0b00` 是**链首**。
  ★ 位打包（字偏移/宽度、TYPE 码、`w0..w7` 布局）**一字未动** ⇒ **线格式仍兼容**；改的只有 FLAGS 的
    **语义**、校验**规则**与表的**内容**（`DESC_COUNT` 口径 = C3.11a 已订正为"载荷项数、不含哨兵"，
    本轮**不变**）。

★★ O8 已关闭（表达力限制**不再是编码限制**）★★
  · 旧 O8 = "塌缩编码只保得住一条链上 ⌊len/2⌋ 个融合对 ⇒ 33 条边里 7 条被牺牲"（+5,222,400 B/帧）。
    **作废**：逐算子链式编码下任意长的链都是"一串 `head middle* tail`"，**编码层没有长度上限**。
  · 本表的链 = C3.11b 分析出的 **19 条极大链**（长 2×15 / 4×2 / 6×1 / 8×1，共 52 个 conv 节点、
    33 条边）。**编码层 + 本代硬件**：33 条边**全部**可表达（最长链 8 = `L_MAX`）⇒
    `info["per_edge_bytes"]` = `info["chain_bytes"]` = **12,576,000 B/帧**（= `fuse_both` 下界；
    本文件把这个数**打印并断言**，见 `selftest`）—— **这才是"O8 关闭"的证据**。
  · **本代硬件 `L_MAX = 8`**（切片实例数；RTL 的 A-3 提交 `8120c64` 把它从 4 参数化提到 8）
    ⇒ 长 6 / 长 8 的链**一次跑完、不拆**（`_split_run` 返回单段）。★ **A-3b（本次）**把本文件的
    `CHAIN_L_MAX` 从 4 跟到 **8**，让 Python 校验器与 RTL **同口径**：`L_MAX=4` 时它们必须拆、
    代价 +1,689,600 B/帧 —— **这一笔已随 A-3 归零**。
    ⇒ 本表**实际**覆盖 **33/33** 条边，**零拆点**、`split_cost_bytes == 0`。
  · ★ **分清这两件事**（本任务的关键区分）：**编码**能表达全部 33 条边；**本代硬件的 `L_MAX=8`**
    也**一次就能跑完**最长的那条链 ⇒ 两者**同时**成立 ⇒ 整帧 = 12,576,000 B（无拆点代价）。
    `L_MAX` 若是 4，再多出的那部分是 **`L_MAX`（面积/实例）的代价，不是编码的代价**
    （历史对照见 `reports/c3_fusion_chains.md` 的 L 表）。

API（冻结）
-----------
    pack(d: dict) -> bytes            # 32 B（8 个小端字）
    unpack(b: bytes) -> dict          # 逆
    pack_table(descs: list) -> bytes  # 末尾自动追加哨兵项
    validate(descs, desc_count, ddr_bytes) -> None | raise DescError()
      ★ `desc_count` = **载荷项数（不含表尾哨兵）**；哨兵必须落在下标 `desc_count` 上。
        这是 **C3.11a 订正的口径**（旧契约写"含哨兵"⇒ 与 RTL 的 `descCount` 相反）。
        与 `rtl/LayerSched.scala` 的 `io.descCount`（"载荷项数，哨兵在下标 descCount"）**逐字一致**。

十四个字段（`FIELD_ORDER`）：TYPE FLAGS IMG_W IMG_H C_IN C_OUT GROUP STRIDE PAD
SRC_ADDR DST_ADDR IN_BYTES QUANT_SHIFT LAYER_ID。
`pack` 对每个字段做**位宽检查**（越界 ⇒ ValueError，绝不静默截断）；**字内高位保留段**
（`w0[31:16]` / `w3[31:16]` / `w7[31:16]`）由 pack 恒写 0。`FLAGS` 是**整 8 bit 字段透传**，
其保留子位 `bits[7:2]` **不由 pack 强制**（pack 只检查位宽）—— 改由 `validate` 在**读**侧
拒绝（`FLAGS & FLAGS_RESERVED_MASK` ⇒ `DescError`，见规则 (2)）⇒ 合法表里它们必然为 0。

校验六规则（= 上游 spec S6 的 Python 侧；见 `validate`）
-------------------------------------------------------
  (1) `DESC_COUNT` 与表长自洽：`desc_count == 载荷项数`（= `len(descs) - 1`，**不含**哨兵）；
  (2) 非法 `TYPE`（不在 `VALID_TYPES`）+ `FLAGS` 的保留位非 0（`FLAGS & 0xFC`）；
  (3) 地址 32 B 对齐 + `IN_BYTES` 是 32 的整数倍且 > 0 + SRC/DST 两个区间都落在 DDR 窗内；
  (4) 自环（`SRC_ADDR == DST_ADDR`）；
  (5) `FLAGS` 语义 + **链结构**（**A-2 重写**）：把载荷的 `FLAGS[1:0]` 当**状态机**走过
      `(P | H M* T)*`（`P` = `plain`/旁路项）：
        · `middle`/`tail` **必须跟在** `head`/`middle` 之后（= 它俩不能当一段序列的**起点**）
          ⇒ `middle without predecessor @<i>` / `tail without predecessor @<i>`；
        · `head` 后面**必须**是 `middle`/`tail`（**包括直接撞上哨兵/表尾**）⇒ `head without tail @<i>`
          （`<i>` = **链首**的下标）；
        · 一段 run 的长度 `> CHAIN_L_MAX` ⇒ `chain too long @<i>`（`<i>` = **越限那一条**的下标）；
        · 一段 run 里某个条目的 `IMG_W/IMG_H/C_IN/C_OUT/GROUP/QUANT_SHIFT` 与**链首**不一致
          ⇒ `chain geom mismatch @<i>`（`<i>` = 第一个不一致的条目）；
        （`bits[7:2]` 已由规则 (2) 收干净 ⇒ 这里只看低两位）；
  (6) 表尾哨兵（最后一项 `TYPE=0xFF`、`FLAGS=0`、且哨兵在表里唯一）。

⚠ **规则 (2)–(5) 的作用域 = 载荷项（哨兵之前的所有项）**：哨兵项（TYPE=0xFF、其余全 0）会撞
规则 (3) 的 `IN_BYTES == 0` ⇒ 若把 (2)–(5) 真遍历**全部**项，任何合法表都会被判非法。故本实现把
(2)–(5) 限定在**载荷项**上，(1)/(6) 负责 COUNT 与哨兵自洽。
★ C3.11a 修订后规则 (5) **不再有头/尾前瞻**（"配对"这件事整体作废）⇒ 载荷末尾是 `0b10` 或
`0b00` 都合法（旧契约会误报 `head without tail` —— 那正是被移除的自相矛盾规则）。
★ A-2 又把规则 (5) 换成**链式状态机**：`head` 必须有 `middle* tail` 收尾（这才是"链"），
`middle`/`tail` 不能自己起头，run 长 ≤ `CHAIN_L_MAX`、且 run 内几何必须一致（见上）。
★ `desc_count` 口径 = C3.11a 订正后的"**载荷项数（不含哨兵）**"（与 RTL 的 `descCount` 对齐），
本轮**未再改**；读旧报告 / 旧表请按**新**口径。

模型侧建表（只对 `--selftest` 生效；只读 `ddr_traffic` / `bypass_traffic` / `fusion_chains`，不改它们一个字节）
----------------------------------------------------------------------------------------------------------
  · 枚举来源 = `ddr_traffic` 的两个融合查找器（`fu33` = 7 个 `3×3→1×1` + `fu11` = 26 个 `1×1→3×3`
    ⇒ **33 条边**）+ 四类旁路算子（MaxPool/Resize/Add/Sigmoid，本网 4/2/2/6 个节点）；
  · 执行序 = 表序 = ONNX 节点序（跳过 `Relu`：冻结 TYPE 表里没有 Relu，逐元素算子是**生产者的
    输出后处理**，不占描述符；`Transpose`/`Reshape` 是**布局**算子，由转换器折进寻址 —— spec §2/§8）；
  · **链（A-2）**：33 条边在融合图里连成 **19 条极大链**（`_chain_nodes`；与 `fusion_chains.py` 逐字同源）；
    `_split_run` 把每条极大链拆成**长度 ≤ `CHAIN_L_MAX`(=8)** 的 run（DP 选最便宜的拆点 ——
    本网最长链恰 8 ⇒ **无需拆**，DP 每条链都只返回一段）⇒ 表里 **19 段 run**
    （15 段 2 片 + 2 段 4 片 + 1 段 6 片 + 1 段 8 片），**零条被牺牲的边**；
  · conv 项 = **52**（= 链上的 conv 节点数，**一个算子一项**：head / middle / tail 各自成项）
    + 1 个自由 conv `Conv_0`（`0b01`）= 53；载荷 = 53 + 14 个旁路项（皆 `0b01`）= **67** 项
    （+ 哨兵 = **68** 项 = **2176 B**）；
    FLAGS 直方图 = `{head: 19, plain: 15, middle: 14, tail: 19}`（**一项一算子**：head/tail 各 = run 数，
    middle = Σ(run 长 − 2)，plain = 1 个自由 conv + 14 个旁路）—— 与报告 §4.3 逐字一致；
  · 表的**字段值**不是冻结物，**位打包**才是：地址按"每张量独立槽位（bump，32 B 对齐）"生成，
    只是给 C3.4 交叉对账用的确定向量；真实转换器应做内存复用。逐项字段口径见 `build_table`；
    ★ 同一段 run 内 `IMG_W/IMG_H/C_IN/C_OUT/GROUP/QUANT_SHIFT` 一律取**链首**的值（中间/链尾片
    的自身几何**不写进表** —— 硬件只认链首的；这条与规则 (5) 的 `chain geom mismatch` 同源）；
  · 本文件的五个自检判据都拿**计算值**去比**外部冻结常量**（C0/C3.0/C3.1/C3.11b 报告里的数字）
    或第二遍独立重算（含 `fusion_chains` 的交叉对账），绝不"自己比自己"（见 `selftest` 与
    `y1/reports/c3_descriptor_format.md`）。

用法
----
    PYTHONIOENCODING=utf-8 PYTHONPATH='../third_party/yunet/deps' <py3.9> \
        tools/desc_table.py --selftest [../third_party/yunet/yunet.onnx]

C3.4 在**本文件**里追加的两个**出口旗标**（additive；`--selftest` 的输出与表指纹一字不变）
--------------------------------------------------------------------------------------------
    --emit-hex  <path>   整表字节按 `$readmemh` 格式落盘（**一行一个十六进制字节**）——
                         `rtl_test/AxiMemModel.v` 的 `+MEMFILE=` 直接吃它，RTL 侧就有**同一张表**。
    --emit-meta <path>   逐项的**期望向量**（RTL 侧对账用）：
                           `W <idx> <8 个 32-bit 字（hex）>` —— 按**位表独立算**（`reference_words`），
                             不是拿 `unpack` 反推的；
                           `F <idx> <14 个字段 k=v> SENTINEL=.. HEAD=.. TAIL=..` —— 由 `unpack(pack(d))`
                             **往返**得到（不是直接抄 build dict），再加 FLAGS 两个语义位；
                             ⇒ 与 W 行互为两条独立实现（位表算法 vs pack/unpack 往返）。
    两个旗标可同时给；都会先打一行 `EMIT_*` 摘要（含表指纹）再落盘。用法：C3.4 的
    `tools/run_desc_ab.sh`（同一份真源出口，不另起一份表生成器 —— 见 C3.2 报告 §7 开口项 O7）。
"""
import hashlib
import struct
import sys
from pathlib import Path

# 非 ASCII 输出规则：Windows 控制台是 GBK，未解码字节会触发 UnicodeEncodeError。
sys.stdout.reconfigure(encoding="utf-8", errors="replace")
sys.stderr.reconfigure(encoding="utf-8", errors="replace")

# ============================ 冻结常量 ============================
# TYPE（spec §3 逐字）
TYPE_CONV3X3 = 0x01
TYPE_CONV1X1 = 0x02
TYPE_DEPTHWISE = 0x03
TYPE_MAXPOOL = 0x10
TYPE_RESIZE = 0x11
TYPE_CONCAT = 0x12
TYPE_ADD = 0x13
TYPE_SIGMOID = 0x14
TYPE_SENTINEL = 0xFF
VALID_TYPES = {TYPE_CONV3X3, TYPE_CONV1X1, TYPE_DEPTHWISE, TYPE_MAXPOOL,
               TYPE_RESIZE, TYPE_CONCAT, TYPE_ADD, TYPE_SIGMOID, TYPE_SENTINEL}
TYPE_NAME = {TYPE_CONV3X3: "conv3x3", TYPE_CONV1X1: "conv1x1", TYPE_DEPTHWISE: "depthwise",
             TYPE_MAXPOOL: "maxpool", TYPE_RESIZE: "resize", TYPE_CONCAT: "concat",
             TYPE_ADD: "add", TYPE_SIGMOID: "sigmoid", TYPE_SENTINEL: "sentinel"}

# FLAGS 位号（spec §3 逐字；★ A-2 只改**语义**，位号一字未动）
FLAG_OUT_TO_DDR = 0      # 1 ⇒ 输出落 DDR（head/middle 为 0 ⇒ 输出留给链上的下一个算子）
FLAG_IN_FROM_PREV = 1    # 1 ⇒ 输入取"上一个算子的片上输出"（middle/tail；DDR 读被这一位覆盖）
FLAGS_RESERVED_MASK = 0xFC   # bits[7:2] 保留 = 0（由 validate 规则 (2) 在**读**侧强制）
# ★ FLAGS 两位的**四种组合**（A-2：逐算子链式编码；四态逐个显式定义、**全部合法**）
FLAGS_HEAD   = 0b00      # 链首：读 DDR(`srcA`) -> 算 -> 输出留片上（进链的第一块中间缓冲）
FLAGS_PLAIN  = 0b01      # 普通单元：读 DDR(`srcA`) -> 算 -> 写 DDR(`dstA`)
FLAGS_MIDDLE = 0b10      # 链中：输入取上一个算子的片上输出 -> 算 -> 输出留片上
FLAGS_TAIL   = 0b11      # 链尾：输入取上一个算子的片上输出 -> 算 -> 写 DDR(`dstA`)
FLAGS_SEMANTIC_MASK = 0x03   # 只看低两位
# ★ A-2：**本代**硬件的切片实例数上限（= `rtl/LayerSched.scala` 的 `L_MAX`，逐字一致）。
#   一段 run（head middle* tail）的长度**不得超过它**；超过 ⇒ 表非法（规则 (5) `chain too long`），
#   RTL（LayerSched 扫链 / UnitExec 生成期上限）同款响亮 err。**链长不在 FLAGS 里**：
#   调度器扫链自己数出来，作为独立入参给 `UnitExec.io.chain_len`（A-1b）。
CHAIN_L_MAX = 8

DESC_WORDS = 8
DESC_BYTES = DESC_WORDS * 4            # = 32 B
FIELD_ORDER = ("TYPE", "FLAGS", "IMG_W", "IMG_H", "C_IN", "C_OUT", "GROUP", "STRIDE",
               "PAD", "SRC_ADDR", "DST_ADDR", "IN_BYTES", "QUANT_SHIFT", "LAYER_ID")
# 字段位宽（pack 的位宽检查用；与上面的位表逐字对应）
FIELD_BITS = {"TYPE": 8, "FLAGS": 8, "IMG_W": 16, "IMG_H": 16, "C_IN": 16, "C_OUT": 16,
              "GROUP": 8, "STRIDE": 4, "PAD": 4, "SRC_ADDR": 32, "DST_ADDR": 32,
              "IN_BYTES": 32, "QUANT_SHIFT": 8, "LAYER_ID": 8}

# 表尾哨兵项：除 TYPE 外**全 0**（= 转换器最自然的写法；也是 C3.4 的交叉向量）
SENTINEL = dict([(k, 0) for k in FIELD_ORDER])
SENTINEL["TYPE"] = TYPE_SENTINEL


class DescError(Exception):
    """非法描述符表（= spec S6 的 `err`）。"""


# ============================ 打包 / 解包 ============================
def _field(d, name):
    """取字段并做位宽检查（越界 ⇒ ValueError；不静默截断）。"""
    if name not in d:
        raise ValueError("字段 %s 缺失（需要全部 14 个字段：%s）" % (name, ", ".join(FIELD_ORDER)))
    v = d[name]
    if not isinstance(v, int) or isinstance(v, bool) or v < 0 or v >= (1 << FIELD_BITS[name]):
        raise ValueError("字段 %s=%r 超出 %d bit 无符号范围" % (name, v, FIELD_BITS[name]))
    return v


def pack(d):
    """dict（14 个字段）→ 32 B（8 个 32-bit **小端**字）。位表见模块 docstring。"""
    w0 = _field(d, "TYPE") | (_field(d, "FLAGS") << 8)
    w1 = _field(d, "IMG_W") | (_field(d, "IMG_H") << 16)
    w2 = _field(d, "C_IN") | (_field(d, "C_OUT") << 16)
    w3 = _field(d, "GROUP") | (_field(d, "STRIDE") << 8) | (_field(d, "PAD") << 12)
    w4 = _field(d, "SRC_ADDR")
    w5 = _field(d, "DST_ADDR")
    w6 = _field(d, "IN_BYTES")
    w7 = _field(d, "QUANT_SHIFT") | (_field(d, "LAYER_ID") << 8)
    return struct.pack("<8I", w0, w1, w2, w3, w4, w5, w6, w7)


def unpack(b):
    """32 B → dict（`pack` 的逆）。长度不对 ⇒ ValueError。"""
    if len(b) != DESC_BYTES:
        raise ValueError("描述符必须是 %d B，收到 %d B" % (DESC_BYTES, len(b)))
    w0, w1, w2, w3, w4, w5, w6, w7 = struct.unpack("<8I", bytes(b))
    return {"TYPE": w0 & 0xFF, "FLAGS": (w0 >> 8) & 0xFF,
            "IMG_W": w1 & 0xFFFF, "IMG_H": (w1 >> 16) & 0xFFFF,
            "C_IN": w2 & 0xFFFF, "C_OUT": (w2 >> 16) & 0xFFFF,
            "GROUP": w3 & 0xFF, "STRIDE": (w3 >> 8) & 0xF, "PAD": (w3 >> 12) & 0xF,
            "SRC_ADDR": w4, "DST_ADDR": w5, "IN_BYTES": w6,
            "QUANT_SHIFT": w7 & 0xFF, "LAYER_ID": (w7 >> 8) & 0xFF}


def pack_table(descs):
    """载荷项列表 → 整表字节（**末尾自动追加哨兵项**）。"""
    out = bytearray()
    for d in descs:
        out += pack(d)
    out += pack(SENTINEL)
    return bytes(out)


# ============================ 校验（S6 的 Python 侧） ============================
def _geom_key(d):
    """一段 run 的"几何指纹"：`CHAIN_GEOM_FIELDS` 那 6 个字段的元组（规则 (5) 对账用）。"""
    return tuple(d[k] for k in CHAIN_GEOM_FIELDS)


def validate(descs, desc_count, ddr_bytes):
    """六规则校验（见模块 docstring）；不合法 ⇒ raise DescError（= S6 的"响亮 err"）。

    `descs` **含**表尾哨兵；`desc_count` = 主机写在 `DESC_COUNT` 里的项数
    = **载荷项数（不含哨兵）**（C3.11a 订正的口径，与 `rtl/LayerSched.scala` 的 `io.descCount`
    逐字一致）；哨兵必须落在下标 `desc_count` 上。
    规则 (2)–(5) 只作用于**载荷项**（哨兵之前），(1)/(6) 管 COUNT 与哨兵自洽。
    规则 (2) 除非法 TYPE 外，还拒绝 `FLAGS` 的保留子位 `bits[7:2]`（`FLAGS_RESERVED_MASK`）；
    规则 (5) 管 `FLAGS[1:0]` 的**逐算子四态 + 链结构**（A-2）：载荷必须写成 `(P | H M* T)*`
    （`P` = plain / 旁路项），`middle`/`tail` 不能自己起头，`head` 必须有 `middle* tail` 收尾，
    一段 run 长度 ≤ `CHAIN_L_MAX`、且 run 内 6 个几何字段与**链首**一致（`_geom_key`）。
    """
    # (1) COUNT 与表长自洽（desc_count == 载荷项数，**不含**哨兵）
    if not descs:
        raise DescError("空表（至少要哨兵项）")
    n_payload = len(descs) - 1          # 载荷项数（哨兵之后不该有项）
    if desc_count != n_payload:
        raise DescError("DESC_COUNT %d != %d" % (desc_count, n_payload))
    # (2) 非法 TYPE + FLAGS 保留位非 0（载荷项）
    for i, d in enumerate(descs[:n_payload]):
        if d["TYPE"] not in VALID_TYPES:
            raise DescError("bad TYPE 0x%02x @%d" % (d["TYPE"], i))
        if d["FLAGS"] & FLAGS_RESERVED_MASK:
            raise DescError("FLAGS reserved bits 0x%02x != 0 @%d"
                            % (d["FLAGS"] & FLAGS_RESERVED_MASK, i))
    # (3) 地址 32 B 对齐 + IN_BYTES 是 32 的整数倍且 > 0 + 落在 DDR 窗内（载荷项）
    for i, d in enumerate(descs[:n_payload]):
        if d["SRC_ADDR"] % 32 or d["DST_ADDR"] % 32:
            raise DescError("addr misalign @%d" % i)
        if d["IN_BYTES"] % 32 or d["IN_BYTES"] == 0:
            raise DescError("IN_BYTES bad @%d" % i)
        if d["SRC_ADDR"] + d["IN_BYTES"] > ddr_bytes or d["DST_ADDR"] + d["IN_BYTES"] > ddr_bytes:
            raise DescError("addr OOB @%d" % i)
    # (4) 自环（载荷项）
    for i, d in enumerate(descs[:n_payload]):
        if d["SRC_ADDR"] == d["DST_ADDR"]:
            raise DescError("self-loop @%d" % i)
    # (5) FLAGS 语义 + 链结构（载荷项）：状态机 (P | H M* T)* ——
    #     遇 plain 走一步；遇 middle/tail ⇒ 没有前驱（它俩只能由下面的 head 分支消费）；
    #     遇 head ⇒ 向后扫 middle* tail（run 长 ≤ CHAIN_L_MAX、run 内几何 == 链首）。
    i = 0
    while i < n_payload:
        flags = descs[i]["FLAGS"] & FLAGS_SEMANTIC_MASK
        if flags == FLAGS_MIDDLE:
            raise DescError("middle without predecessor @%d" % i)
        if flags == FLAGS_TAIL:
            raise DescError("tail without predecessor @%d" % i)
        if flags == FLAGS_PLAIN:
            i += 1
            continue
        # FLAGS_HEAD：必须由 middle* tail 收尾（含"直接撞上哨兵/表尾"）
        run = 1
        j = i + 1
        while True:
            if j >= n_payload:
                raise DescError("head without tail @%d" % i)
            nf = descs[j]["FLAGS"] & FLAGS_SEMANTIC_MASK
            if nf not in (FLAGS_MIDDLE, FLAGS_TAIL):
                raise DescError("head without tail @%d" % i)
            run += 1
            if run > CHAIN_L_MAX:
                raise DescError("chain too long @%d" % j)
            if _geom_key(descs[j]) != _geom_key(descs[i]):
                raise DescError("chain geom mismatch @%d" % j)
            if nf == FLAGS_TAIL:
                break
            j += 1
        i = j + 1
    # (6) 表尾哨兵：最后一项必须是哨兵、FLAGS 必须为 0、且哨兵只出现一次
    for i, d in enumerate(descs[:n_payload]):
        if d["TYPE"] == TYPE_SENTINEL:
            raise DescError("SENTINEL inside payload @%d" % i)
    if descs[-1]["TYPE"] != TYPE_SENTINEL:
        raise DescError("SENTINEL missing at tail (last TYPE=0x%02x)" % descs[-1]["TYPE"])
    if descs[-1]["FLAGS"] != 0:
        raise DescError("SENTINEL FLAGS %d != 0" % descs[-1]["FLAGS"])


def desc_count_of(descs):
    """表 → 主机应写进 `DESC_COUNT` 的值（口径 = **载荷项数、不含哨兵**；C3.11a 订正、A-2 沿用）。

    单一真源：`validate` 规则 (1) 与 `--emit-meta` / 自检都调它，保证三处口径不再裂开。
    """
    return max(len(descs) - 1, 0)       # 表里最后一项恒为哨兵 ⇒ 载荷 = 表长 − 1


# ============================ 模型侧建表（只读 ddr_traffic / bypass_traffic / fusion_chains） ============================
_TOOLS = Path(__file__).resolve().parent
if str(_TOOLS) not in sys.path:
    sys.path.insert(0, str(_TOOLS))
import ddr_traffic as dt          # noqa: E402  （只读：GraphView 形状层 + STRATEGIES + 流量口径）
import bypass_traffic as bt       # noqa: E402  （只读：旁路算子枚举 + 形状/字节口径）
import fusion_chains as fc        # noqa: E402  （只读：A-2 用它的链解算 + L 容量口径做**交叉对账**）

# ---- DDR 窗：与 RTL 的地址位宽同源（DdrMaster.ADDR_W = 28 ⇒ 256 MiB） ----
DDR_ADDR_W = 28
DDR_BYTES = 1 << DDR_ADDR_W               # = 268,435,456 B
TENSOR_BASE = 0x00200000                  # 激活区起点（2 MiB；32 B 对齐）
DESC_TABLE_ADDR_SUGGEST = 0x00100000      # 建议的表地址（C3.12 的 DESC_ADDR；32 B 对齐）

# ---- 外部冻结期望值（来源：C0.2/C0.3 的 ddr_traffic_budget.md、C3.0、C3.1、C3.11b 报告） ----
# 判据拿**计算值**去比它们 ⇒ 任何一侧被改坏都会红（不是"自己比自己"）。
BASE_STRATEGY = "fuse_both"
BASE_BYTES_FROZEN = 12576000              # C0 冻结：fuse_both 的整帧流量
UNITS_FROZEN = 33                         # C0.3：33 条融合**边**（7 个 3×3→1×1 + 26 个 1×1→3×3；允许重叠）
UNITS_33X11X_FROZEN = 7
UNITS_11X33X_FROZEN = 26
# ★ A-2：融合图 → **极大链**（C3.11b 的 19 条简单路径；链长直方图 {2:15, 4:2, 6:1, 8:1}）
CHAINS_FROZEN = 19
CHAIN_HIST_FROZEN = {2: 15, 4: 2, 6: 1, 8: 1}
CHAIN_NODES_FROZEN = 52                   # 链上的 conv 节点总数（一个算子一项 ⇒ 52 项）
# ★ A-3b：把极大链**拆到 ≤ CHAIN_L_MAX=8** 之后表里的 run（= 一段 `head middle* tail`）。
#   `L_MAX` 从 4 提到 8 ⇒ 本表最长的那两条极大链（长 6 / 长 8）**不再需要拆** ⇒ 19 条极大链
#   各自成为**一段** run（19 段 = 15 段 2 片 + 2 段 4 片 + 1 段 6 片 + 1 段 8 片），**零拆点**。
RUNS_FROZEN = 19                          # 15 条 2 链 + 2 条 4 链 + 1 条 6 链 + 1 条 8 链（各一段）
RUN_HIST_FROZEN = {2: 15, 4: 2, 6: 1, 8: 1}
COVERED_EDGES_FROZEN = 33                 # 表里**实际**被融合的边（= 33 − 0 个拆点 ⇒ 全部）
UNMATCHED_EDGES_FROZEN = 0                # 本代 L_MAX=8 已能一次跑完最长链 ⇒ 无拆点、无重走 DDR
PER_EDGE_BYTES_FROZEN = BASE_BYTES_FROZEN  # 全部 33 条边**都可表达**时的整帧（= fuse_both 下界）
CHAIN_BYTES_FROZEN = 12576000             # 本代表（L_MAX=8）实际表达的整帧 = 下界本身（零拆点代价）
PAYLOAD_FROZEN = 67                       # 52 个链上 conv + 1 个自由 conv + 14 个旁路项
DESC_TOTAL_FROZEN = 68                    # = 载荷 67 + 哨兵 1
TABLE_BYTES_FROZEN = DESC_TOTAL_FROZEN * 32   # 2176 B（68 项 x 32 B）
# 整表字节的 md5 —— **A-3b 重生成**（把极大链从"拆到 4 片"改成"直通"：FLAGS 与链首几何覆盖都变了）。
# 再往前都**已作废**：A-2 的 2176 B / `ed00cad736b82378a59bdeedc79f3b21`（L_MAX=4 拆链）、
# C3.11a 的 1344 B / `4908613bdb67e2f650a0b99c0565cd41`（"塌缩单条目"）、C3.2 的 2176 B /
# `374121088ff90bf7e2d5b20c06f7874f`（"两项一对 + 每片自身几何"）。C3.4 的 `--emit-hex` 出口
# 拿它做交叉核对：出口吐出来的字节必须还是**这一份**（口径/模型任何一处被改坏，这里当场出声）。
TABLE_MD5_FROZEN = "a45d0da0440a468f1b75788c9ad5bc14"
# 合法表的 FLAGS 直方图（A-2/A-3b：一项一算子；head/tail 各 = run 数，middle = Σ(run 长 − 2)）
#   L_MAX=8 ⇒ run 数 = 19 ⇒ head/tail 各 19；middle = (0+0+2+4+6) = 14；plain = 15。
FLAGS_HIST_FROZEN = {FLAGS_HEAD: 19, FLAGS_PLAIN: 15, FLAGS_MIDDLE: 14, FLAGS_TAIL: 19}
BYPASS_OPS_FROZEN = {"maxpool": 4, "resize": 2, "add": 2, "sigmoid": 6}
BYPASS_CLASS_BYTES_FROZEN = {"maxpool": 4736000, "resize": 640000,
                             "add": 1536000, "sigmoid": 33600}
BYPASS_BYTES_FROZEN = 6945600             # = Σ BYPASS_CLASS_BYTES_FROZEN
BYPASS_ON_FUSED_BOUNDARY_FROZEN = 0       # C3.1 的 OVERLAP_PROBE（=0）

# 旁路算子：op_type → TYPE 码 + 短名（spec §2 裁决"进硬件"的四类）
BYPASS_TYPE = {"MaxPool": TYPE_MAXPOOL, "Resize": TYPE_RESIZE,
               "Add": TYPE_ADD, "Sigmoid": TYPE_SIGMOID}
# 逐元素算子：冻结 TYPE 表里没有它们的码 ⇒ 折进生产者的输出后处理，不占描述符。
# ⚠ Sigmoid 虽然也在 ddr_traffic 的 ELEMENTWISE_OPS 里（融合链可穿透它），但它在 C3 里是
#   **进硬件的旁路算子**（TYPE=0x14，C3.7 的 SigmoidUnit）⇒ **占描述符**，必须从本清单里剔除。
EPILOGUE_OPS = tuple(o for o in dt.ELEMENTWISE_OPS if o != "Sigmoid")
# 布局算子：由转换器折进寻址（spec §2/§8），不占描述符
LAYOUT_OPS = ("Transpose", "Reshape")

# QUANT_SHIFT 的取值（**本表的占位口径**，不是生产量化器）：
#   conv/depthwise = 6 —— 项目冻结的 requant 夹具 `>>6`（tools/mac_ref.py:SHIFT=6；
#                        C3.8 的冻结向量也用 SHIFT=6）；真实按层 scale 属 C4/M2（开口项）。
#   旁路：MaxPool/Resize 无量化（C3.6：激活直传）⇒ 0；Add 只 clamp（C3.7）⇒ 0；
#         Sigmoid 输入 Q3.4（C3.7）⇒ 4。
QUANT_SHIFT_BY_TYPE = {TYPE_CONV3X3: 6, TYPE_CONV1X1: 6, TYPE_DEPTHWISE: 6,
                       TYPE_MAXPOOL: 0, TYPE_RESIZE: 0, TYPE_ADD: 0, TYPE_SIGMOID: 4}

# ★ A-2：一段 run（head middle* tail）里**必须逐项相同**的几何字段（= "融合"的硬含义）。
#   链首的值是权威：`build_table` 拿它覆盖同 run 的其它条目，`validate` 规则 (5) 拿它做对账
#   （`chain geom mismatch @i`）。`TYPE`/`STRIDE`/`PAD`/`SRC_ADDR`/`DST_ADDR`/`IN_BYTES` **不在**此列。
CHAIN_GEOM_FIELDS = ("IMG_W", "IMG_H", "C_IN", "C_OUT", "GROUP", "QUANT_SHIFT")


def align32(n):
    return (n + 31) & ~31


def _hist(values):
    """`[v, ...]` → `{v: 条数}`（键**升序**；判据拿它比冻结直方图）。"""
    h = {}
    for v in values:
        h[v] = h.get(v, 0) + 1
    return dict(sorted(h.items()))


def _node_int_attr(node, name, default=None):
    for a in node.attribute:
        if a.name == name:
            if a.type == a.INTS:
                return list(a.ints)
            return a.i
    return default


def _conv_type(node):
    """conv 的 TYPE：按核大小（depthwise 的判定要看通道数，在 `build_table` 里做）。

    ⚠ 本函数只看核大小、**不**判 grouped/depthwise：那个提升在 `build_table` 里、且只覆盖
    3×3（`tpe == TYPE_CONV3X3 and grp == ci == co > 1`）。所以假设出现 group=C_in=C_out>1 的
    **1×1 grouped/depthwise**，这里会把它**误标成 `conv1x1`**（本网不存在：所有 depthwise 都是
    3×3）。要支持 ⇒ 走 spec 修订 + 重生成向量，别就地改。
    """
    k = dt.conv_kernel(node)
    grp = _node_int_attr(node, "group", 1) or 1
    if k == [3, 3]:
        return TYPE_CONV3X3, grp
    if k == [1, 1]:
        return TYPE_CONV1X1, grp
    raise ValueError("本表不认识 kernel=%r（%s）：冻结 TYPE 表只有 1×1/3×3；走 spec 修订" % (k, node.name))


def _chw(gv, name):
    """张量 → (C, H, W, 元素数)；4 维按 NCHW（丢 N），非 4 维按**扁平单通道**（C=1,H=1,W=元素数）。

    非 4 维只出现在 YuNet 的头张量（`[1,N,1]`，由 Reshape/Transpose 折出）：按"扁平单通道缓冲"
    解释 ⇒ 元素数 == 字节数（与 C3.1 的旁路口径同源）。这是本表的**决定**；若 C4/M2 需要
    `(C=1,W=80,H=80)` 那样的几何，必须走 spec 修订 + 重生成本表。

    ⚠ **继承口径，只在 N==1 时成立**：这里的元素数把**所有维相乘（含 batch N）**，而
    `ddr_traffic.act_bytes` 只乘 C/H/W（**丢掉 N**）⇒ 两者只有 N==1 才相同（本网 N==1，
    故同源）。换个 N≠1 的网就不再等价，别当成通用口径。
    """
    s = gv.shape_of(name)
    if not s:
        return None
    n = 1
    for d in s:
        n *= d
    if len(s) == 4:
        return s[1], s[2], s[3], n
    return 1, 1, n, n


def _geom(gv, in_name, out_name):
    """(IMG_W, IMG_H, C_IN, C_OUT)：几何取**输出**张量，C_IN 取输入张量。"""
    gi, go = _chw(gv, in_name), _chw(gv, out_name)
    if gi is None or go is None:
        raise ValueError("形状推不出来：%r → %r" % (in_name, out_name))
    return go[2], go[1], gi[0], go[0]


def _chain_nodes(edges, node_order):
    """33 条融合**边** → **极大链**（互不相交的简单路径）：返回 `[[节点名, ...], ...]`。

    前提：融合图 in/out-degree ≤ 1（一个 conv 至多是一条边的头 + 一条边的尾：头侧/尾侧的核大小
    互斥）⇒ 连通分量都是简单路径。链首 = 无前辈者；沿 succ 走到无后继为止。**断言**（不是假设）：
    每个节点出/入度 ≤ 1，且每条边**恰好**落在一条链上（有环/悬挂 ⇒ 断言发火）。
    返回的链 = C3.11b 分析的 **19 条极大链**（与 `tools/fusion_chains.py` 的同名结构逐字同源；
    `selftest` 拿它做交叉对账）。链**按表序里的链首**排（`node_order` 的下标）。
    """
    succ, pred, nodes = {}, {}, set()
    for a, b in edges:
        succ.setdefault(a, []).append(b)
        pred.setdefault(b, []).append(a)
        nodes.add(a)
        nodes.add(b)
    for nm in nodes:
        assert len(succ.get(nm, [])) <= 1 and len(pred.get(nm, [])) <= 1, \
            "节点 %s 度数 > 1：融合图不是简单路径集合" % nm
    pos = dict((nm, i) for i, nm in enumerate(node_order))
    chains = []
    seen = set()
    for r in sorted([n for n in nodes if n not in pred], key=lambda nm: pos[nm]):
        seq, cur = [r], r
        while cur in succ and succ[cur]:
            cur = succ[cur][0]
            seq.append(cur)
        for t in range(len(seq) - 1):
            seen.add((seq[t], seq[t + 1]))
        chains.append(seq)
    assert seen == set((a, b) for a, b in edges), \
        "有边未落入任何链（存在环或悬挂）：%d/%d" % (len(seen), len(edges))
    return chains


def _split_run(chain, cost, limit=CHAIN_L_MAX):
    """一条极大链 → **长度 ≤ `limit` 的 run 列表** `[(i, j), ...]`（半开区间，按链序）。

    ★ A-2：run 的长度**不在 `FLAGS` 里**，但**硬件的 `L_MAX` 是硬上限** ⇒ 比它长的链必须**拆开**
    （`L_MAX=8` 时本网最长链 8 ⇒ 无需拆；换张更长的网仍会拆）。
    目标 = 「覆盖的边最多」+「被牺牲的边**最便宜**」：
      · run 数最少 ⇔ 每条链用 ⌈k/limit⌉ 段（覆盖边数 = k − ⌈k/limit⌉，与**分段位置无关**）；
      · 在"段数最少"的前提下，用 DP 选段边界，使 Σ(拆点那条边的中间张量字节) 最小。
    `cost[t]` = 边 (t, t+1) 的中间张量字节数（= 拆在那里要重走一趟 DDR 的**一半**代价，见流量口径）。
    递推/遍历序与 `tools/fusion_chains.optimal_segments` **逐字同款** ⇒ 逐字同解（`selftest` 交叉对账）。
    """
    k = len(chain)
    assert limit >= 1
    INF = float("inf")
    dp = [INF] * (k + 1)
    prev = [-1] * (k + 1)
    dp[0] = 0
    for j in range(1, k + 1):
        for i in range(max(0, j - limit), j):        # 段 = 链上节点 [i, j)，长度 j-i ∈ [1, limit]
            c = dp[i] + (cost[i - 1] if i > 0 else 0)   # i > 0 ⇒ 边 (i-1, i) 成为边界 ⇒ 被牺牲
            if c < dp[j]:
                dp[j] = c
                prev[j] = i
    segs = []
    j = k
    while j > 0:
        i = prev[j]
        segs.append((i, j))
        j = i
    segs.reverse()
    return segs


def build_table(gv):
    """按**逐算子链式编码**（A-2）+ 四类旁路算子建表。

    执行序 = 表序 = ONNX 节点序，**一个算子一项**：链上的 conv 按角色写 `head`/`middle`/`tail`
    （`FLAGS[1:0]`），链外的 conv 与旁路算子写 `plain`（`0b01`）。
    返回 (descs, info)。`descs` = 载荷项（**不含**哨兵）：**52 个链上 conv 项**（19 段 run：
    15 段 2 片 + 2 段 4 片 + 1 段 6 片 + 1 段 8 片）+ 1 个自由 conv `Conv_0`（`0b01`）+ **14 个旁路项**（`0b01`）
    = **67** 项（+ 哨兵 = **68** 项 = **2176 B**）。info 里有用于判据的对账数字（报告 §4.1/§4.3/§4.5）。
    """
    base_rows = list(dt.STRATEGIES["baseline"](gv))
    fused_by_idx = dict((r.idx, r) for r in dt.STRATEGIES[BASE_STRATEGY](gv))

    # ---- drop 集合：只用**公开**策略（baseline vs fuse_both 的字节差），不用私有 API ----
    #    ★ 这两个集合是"`fuse_both`（33 条边全融合）"的口径 ⇒ 本轮它们**不再是**表的 FLAGS 来源
    #      （FLAGS 改由链角色决定），而是当作**独立第二实现**去和"链角色推出来的 drop 集合"对账。
    drop_out_nodes = set()        # 节点名：其输出不落 DDR（= 融合边的头侧）
    drop_in_tensors = set()       # 张量名：其读不落 DDR（= 融合边的尾侧）
    for r in base_rows:
        f = fused_by_idx[r.idx]
        if r.bytes_out > 0 and f.bytes_out == 0:
            drop_out_nodes.add(r.name)
        if r.bytes_in > 0 and f.bytes_in == 0:
            drop_in_tensors.add(gv.conv_nodes[r.idx].input[0])

    # ---- 融合边（两条查找器之和；**允许重叠**）与**极大链**（19 条）+ 拆到 L_MAX 的 run ----
    fu33, _ = dt.find_fusion_pairs(gv)               # 3×3 → 1×1
    fu11, _ = dt.find_fusion_pairs_native(gv)        # 1×1 → 3×3（元素是 4 元组 (A, B, T, readers)）
    edges = [(a.name, b.name) for (a, b) in fu33] + [(x[0].name, x[1].name) for x in fu11]
    node_by_name = dict((n.name, n) for n in gv.nodes)

    # ---- 张量槽位（bump，32 B 对齐；确定性） ----
    arena = {}
    next_addr = [TENSOR_BASE]

    def slot(name):
        if name is None:
            return 0
        if name not in arena:
            s = gv.shape_of(name)
            if not s:
                return 0                      # 形状推不出来（常量初始化器）⇒ 无地址
            n = 1
            for d in s:
                n *= d
            arena[name] = next_addr[0]
            next_addr[0] += align32(n)
        return arena[name]

    plain = {}                                # 节点名 → **逐节点**描述符（含**自身**几何）
    order = []                                # 表序（= 节点序）里的载荷节点名
    per_class_nodes = {"maxpool": 0, "resize": 0, "add": 0, "sigmoid": 0}
    per_class_bytes = {"maxpool": 0, "resize": 0, "add": 0, "sigmoid": 0}
    unit_bytes = {"read_ne_write": 0, "read_eq_write": 0}
    for n in gv.nodes:
        op = n.op_type
        if op in EPILOGUE_OPS or op in LAYOUT_OPS:
            continue                          # 后处理 / 布局：不占描述符（见模块 docstring）
        if op == "Conv":
            tpe, grp = _conv_type(n)
            ci, co = _chw(gv, n.input[0])[0], _chw(gv, n.output[0])[0]
            if tpe == TYPE_CONV3X3 and grp == ci and grp == co and grp > 1:
                tpe = TYPE_DEPTHWISE
            stride = dt.conv_strides(n)[0]
            pads = _node_int_attr(n, "pads", [0, 0, 0, 0])
            pad = pads[0] if pads else 0
            in_t, out_t = n.input[0], n.output[0]
            read_names = [in_t]
        elif op in BYPASS_TYPE:
            tpe = BYPASS_TYPE[op]
            grp, pad = 1, 0
            ins = [t for t in n.input if gv.shape_of(t)]      # Resize 的 roi/scales 无形状 ⇒ 跳过
            in_t = ins[0]
            out_t = n.output[0]
            if op == "MaxPool":
                stride = gv.shape_of(in_t)[-1] // gv.shape_of(out_t)[-1]   # 2×2/s2 ⇒ 2
            elif op == "Resize":
                stride = gv.shape_of(out_t)[-1] // gv.shape_of(in_t)[-1]   # ×2 最近邻 ⇒ 2
            else:
                stride = 1                                                # Add / Sigmoid
            read_names = ins
        else:
            raise ValueError("本表不认识算子 %s（%s）：走 spec 修订" % (op, n.name))

        # C_IN/C_OUT：多输入算子（Add/Resize）取第一路真激活；几何取输出
        img_w, img_h, c_in, c_out = _geom(gv, in_t, out_t)
        read_bytes = 0
        for t in read_names:
            s = gv.shape_of(t)
            if not s:
                continue
            b = 1
            for d in s:
                b *= d
            read_bytes += b
        write_bytes = 1
        for d in gv.shape_of(out_t):
            write_bytes *= d
        # ⚠ 字节口径是**继承**来的、只在 **N==1** 时与上游同源（见原 docstring 的说明）。
        in_bytes = align32(max(read_bytes, write_bytes))
        if read_bytes == write_bytes:
            unit_bytes["read_eq_write"] += 1
        else:
            unit_bytes["read_ne_write"] += 1

        # FLAGS 先按"自身几何 + drop 集合"算一份（= **独立第二实现**；下面由链角色覆盖成权威值，
        # 两者在 `selftest` 里逐项对账 ⇒ 链角色不是"自己说自己对"）。
        flags = 0
        if n.name not in drop_out_nodes:
            flags |= (1 << FLAG_OUT_TO_DDR)
        if in_t in drop_in_tensors:
            flags |= (1 << FLAG_IN_FROM_PREV)

        d = {"TYPE": tpe, "FLAGS": flags, "IMG_W": img_w, "IMG_H": img_h,
             "C_IN": c_in, "C_OUT": c_out, "GROUP": grp, "STRIDE": stride, "PAD": pad,
             "SRC_ADDR": slot(in_t), "DST_ADDR": slot(out_t), "IN_BYTES": in_bytes,
             "QUANT_SHIFT": QUANT_SHIFT_BY_TYPE[tpe], "LAYER_ID": 0}
        plain[n.name] = d
        order.append(n.name)
        if op in BYPASS_TYPE:
            k = bt.BYPASS_TYPES[op]
            per_class_nodes[k] += 1
            for t in list(n.input) + list(n.output):
                s = gv.shape_of(t)
                if s:
                    b = 1
                    for dd in s:
                        b *= dd
                    per_class_bytes[k] += b

    # ---- 链 → run（≥1 段，每段 ≤ CHAIN_L_MAX）→ **每个算子一项**（head / middle* / tail） ----
    chains = _chain_nodes(edges, order)

    def _mid_tensor(a, b):
        """边 (a, b) 被消掉的中间张量（= `b` 的 `input[0]`；与 `ddr_traffic` 的查找器同口径）。"""
        return node_by_name[b].input[0]

    role = {}                                 # 节点名 → (FLAGS, 链首节点名)
    runs = []                                 # 每段 run：{chain 下标, 段区间, 链首}
    sacrificed = []                           # 拆点：[(edge_head, edge_tail, mid_tensor, size)]
    for chain in chains:
        cost = [gv.act_bytes(_mid_tensor(chain[t], chain[t + 1])) for t in range(len(chain) - 1)]
        for (i, j) in _split_run(chain, cost):
            head_nm = chain[i]
            for t in range(i, j):
                nm = chain[t]
                fl = (FLAGS_HEAD if t == i else
                      (FLAGS_TAIL if t == j - 1 else FLAGS_MIDDLE))
                role[nm] = (fl, head_nm)
            runs.append((head_nm, chain[i:j]))
            if i > 0:                         # 段边界 ⇒ 边 (i-1, i) 被牺牲（重走一趟 DDR）
                mid = _mid_tensor(chain[i - 1], chain[i])
                sacrificed.append((chain[i - 1], chain[i], mid, gv.act_bytes(mid)))

    descs = []
    for nm in order:
        d = plain[nm]
        if nm in role:
            fl, head_nm = role[nm]
            h = plain[head_nm]
            for k in CHAIN_GEOM_FIELDS:       # ★ run 内 6 个几何字段一律取**链首**的值
                d[k] = h[k]
            d["FLAGS"] = fl                   # ★ 权威 FLAGS = 链角色（不是 drop 集合推的）
        descs.append(d)                       # 非链节点（自由 conv / 旁路）保持 `0b01`
    for i, d in enumerate(descs):
        d["LAYER_ID"] = i                     # 遥测身份 = 最终表序

    conv_types = (TYPE_CONV3X3, TYPE_CONV1X1, TYPE_DEPTHWISE)
    hist = {}
    types = {}
    for d in descs:
        hist[d["FLAGS"]] = hist.get(d["FLAGS"], 0) + 1
        types[d["TYPE"]] = types.get(d["TYPE"], 0) + 1       # **最终表**的 TYPE 直方图

    # ---- 流量（冻结口径 `ddr_traffic.compute_rows_fused`；**只读**，两个数都要对账）----
    #   ① per_edge：**编码层**把 33 条边全融合（= `fuse_both` 下界）—— 与 RTL 的 `L_MAX` 无关；
    #   ② chain：**本表**（run ≤ CHAIN_L_MAX=8）实际融合的边 —— L_MAX=8 下与 ① **相同**（零拆点）。
    def _traffic(pairs_of_pairs):
        do, di = set(), set()
        for a, b in pairs_of_pairs:
            do.add(a)
            di.add(_mid_tensor(a, b))
        rows = dt.compute_rows_fused(gv, drop_out=do, drop_in=di)
        return sum(r.traffic for r in rows)

    per_edge_pairs = [(chain[t], chain[t + 1]) for chain in chains
                      for t in range(len(chain) - 1)]
    table_pairs = [(ch[t], ch[t + 1]) for (_h, ch) in runs for t in range(len(ch) - 1)]
    per_edge_bytes = _traffic(per_edge_pairs)
    chain_bytes = _traffic(table_pairs)
    base_bytes = sum(r.traffic for r in dt.STRATEGIES[BASE_STRATEGY](gv))

    # ---- 链角色 vs drop 集合：两条**独立**推导必须一致 ----
    #   角色推出来的 drop 集合 = **本表**（拆到 L_MAX）实际不吃 DDR 的输出/输入；
    #   `baseline` vs `fuse_both` 的字节差推出来的 = **全部 33 条边**都不吃 DDR。
    #   L_MAX=8 ⇒ 零拆点 ⇒ 两者**必须逐集合相等**（拆点那 2 条边的差额不存在了）。
    sac_out = set(a for (a, _b, _m, _s) in sacrificed)
    sac_in = set(_m for (_a, _b, _m, _s) in sacrificed)
    role_drop_out = set(nm for nm, (fl, _h) in role.items() if fl != FLAGS_TAIL)
    role_drop_in = set(_mid_tensor(a, b) for (a, b) in table_pairs)
    info = {"units": len(edges), "units_33x11x": len(fu33), "units_11x33x": len(fu11),
            "chains": len(chains),
            "chain_seq": [list(c) for c in chains],
            "chain_hist": _hist([len(c) for c in chains]),
            "chain_nodes": sum(len(c) for c in chains),
            "runs": len(runs),
            "run_hist": _hist([len(ch) for (_h, ch) in runs]),
            "covered_edges": len(table_pairs), "unmatched_edges": len(edges) - len(table_pairs),
            "sacrificed_edges": sacrificed,
            "per_edge_bytes": per_edge_bytes, "chain_bytes": chain_bytes,
            "split_cost_bytes": chain_bytes - per_edge_bytes,
            "drop_out_nodes": len(drop_out_nodes), "drop_in_tensors": len(drop_in_tensors),
            "base_bytes": base_bytes,
            "role_drop_out": len(role_drop_out), "role_drop_in": len(role_drop_in),
            "role_matches_drop": (role_drop_out == drop_out_nodes - sac_out
                                  and role_drop_in == drop_in_tensors - sac_in),
            "bypass_nodes": per_class_nodes, "bypass_bytes": per_class_bytes,
            "unit_bytes": unit_bytes, "types": types,
            "arena_top": next_addr[0], "arena_tensors": len(arena),
            "flags_hist": hist,
            "nodes_bit0_0": sum(1 for d in descs if (d["FLAGS"] & 1) == 0),
            "nodes_bit1_1": sum(1 for d in descs if (d["FLAGS"] & 2)),
            "plain_conv_units": sum(1 for d in descs if d["TYPE"] in conv_types
                                    and (d["FLAGS"] & FLAGS_SEMANTIC_MASK) == FLAGS_PLAIN)}
    return descs, info


# ============================ 独立字编码（第二遍，不经 pack/unpack） ============================
def reference_words(d):
    """按**位表**独立算出 8 个字（用移位/掩码，不调用 pack）—— 用于字级对账。"""
    return [
        (d["TYPE"] & 0xFF) | ((d["FLAGS"] & 0xFF) << 8),
        (d["IMG_W"] & 0xFFFF) | ((d["IMG_H"] & 0xFFFF) << 16),
        (d["C_IN"] & 0xFFFF) | ((d["C_OUT"] & 0xFFFF) << 16),
        (d["GROUP"] & 0xFF) | ((d["STRIDE"] & 0xF) << 8) | ((d["PAD"] & 0xF) << 12),
        d["SRC_ADDR"], d["DST_ADDR"], d["IN_BYTES"],
        (d["QUANT_SHIFT"] & 0xFF) | ((d["LAYER_ID"] & 0xFF) << 8),
    ]


# ============================ 规则负对照探针（第五个自检判据） ============================
def _rule_probe(full):
    """规则 (1)–(6) 的**负对照表**：变异输入 → **期望**的 `DescError` 消息。

    变异基元 = 整表浅拷贝（`[dict(d) for d in full]`）+ 改 1–2 个字段（正对照改一小段）。每条都拿
    `validate` 的**实际**错误串比**期望**错误串（不是"抛了就算过"），否则把规则删掉也照样"绿"。
    A-2 覆盖：规则 (1) 的 `DESC_COUNT` 口径（**载荷项数，不含哨兵**）、(2) 的 FLAGS 保留位、
    (3) 对齐 / `IN_BYTES` / DDR 窗、(4) 自环、(5) 的链状态机**五档负对照**
    （`middle`/`tail` 无前驱、`head` 无 tail（含撞哨兵）、`chain too long`（`CHAIN_L_MAX=8`
    ⇒ 用 **9 片链**去顶）、`chain geom mismatch`）
    + **四条正对照**（合法表 / 合法 2 片链 `0b00,0b11` / 合法 4 片链 / **合法 8 片链 = `L_MAX`**）、
    (6) 哨兵三个子句。
    `full` 含表尾哨兵（与 `validate` 的口径一致）。
    返回 `[(label, expected_msg, got_msg), ...]`；`got_msg == ""` ⇒ 该条没发火。
    """
    rows = []
    n = len(full) - 1              # 载荷项数（哨兵在下标 n；见 desc_count_of）

    def probe(label, expect, mutate, count=None):
        m = [dict(d) for d in full]
        mutate(m)
        dc = desc_count_of(m) if count is None else count(m)
        try:
            validate(m, dc, DDR_BYTES)
            got = ""
        except DescError as e:
            got = str(e)
        rows.append((label, expect, got))

    def _plain_tail_run(m, k):
        """把**表尾** k+1 项塑成一段合法的 **k 片链**（`head middle* tail`）+ 收尾 plain，
        几何一律取链首 —— 用来做"合法链"的**正对照**（表尾那几项本网是旁路 plain，改成链不影响
        前面的合法序列）。"""
        p = n - (k + 1)              # 表尾留 1 项 plain 收尾，前面一段 k 片链
        for t in range(p, n):
            m[t].update(FLAGS=FLAGS_PLAIN)
        m[p].update(FLAGS=FLAGS_HEAD)
        for t in range(p + 1, p + k):
            for f in CHAIN_GEOM_FIELDS:
                m[t][f] = m[p][f]
            m[t].update(FLAGS=FLAGS_MIDDLE if t < p + k - 1 else FLAGS_TAIL)

    def _tail_chain_at_end(m, k):
        """把**最末尾** k 项塑成一段合法的 k 片链（`head middle* tail`，几何取链首），链尾**正好**
        落在最后一个载荷项上（不收尾 plain）。

        ★ 用于"合法 k 片链（k = `L_MAX`）"的正对照：本网的载荷**尾部不是一整片 plain**
        （末尾 8 项里前 2 项是一条 2 片链 `head/tail`），所以 `_plain_tail_run(m, 8)` 会把那条链的
        tail 抢走 ⇒ 前缀里留下悬空的 head。这里改成"链锚在**最末**"，前缀 `0..p-1` 因此原样保留。
        前提（显式断言，不靠"本网恰好如此"）：`p-1` 那一项**不是** head（本网 = tail），否则前缀
        仍会悬空 ⇒ 断在这里给**清晰**报错，而不是让正对照变成假绿。
        """
        p = n - k
        assert m[p - 1]["FLAGS"] & FLAGS_SEMANTIC_MASK != FLAGS_HEAD, \
            "表尾正对照的前提不成立：下标 %d 是 head ⇒ 抢到它的 tail 会让前缀悬空" % (p - 1)
        for t in range(p, n):
            for f in CHAIN_GEOM_FIELDS:
                m[t][f] = m[p][f]
            m[t].update(FLAGS=FLAGS_HEAD if t == p else
                        (FLAGS_TAIL if t == n - 1 else FLAGS_MIDDLE))

    # R0 正对照：合法表必须**不**报错（= 本表就是 `(P | H M* T)*` 的合法序列）
    probe("R0 legal table (positive ctl)", "", lambda m: None)
    # R1：DESC_COUNT 口径 = **载荷项数（不含哨兵）**—— 旧口径"含哨兵"现在必须报错
    probe("R1 COUNT == len(descs) (old incl-sentinel)",
          "DESC_COUNT %d != %d" % (len(full), len(full) - 1),
          lambda m: None, count=lambda m: len(m))
    probe("R1b COUNT == payload-1", "DESC_COUNT %d != %d" % (len(full) - 2, len(full) - 1),
          lambda m: None, count=lambda m: len(m) - 2)
    # R2：FLAGS 的保留子位 bits[7:2]
    probe("R2 FLAGS reserved 0xFC", "FLAGS reserved bits 0xfc != 0 @0",
          lambda m: m[0].update(FLAGS=0xFC))
    # R3：地址 32 B 对齐 / IN_BYTES 是 32 的倍数且 > 0 / 落在 DDR 窗内
    probe("R3 SRC misalign (+4)", "addr misalign @0",
          lambda m: m[0].update(SRC_ADDR=m[0]["SRC_ADDR"] + 4))
    probe("R3 DST misalign (+4)", "addr misalign @0",
          lambda m: m[0].update(DST_ADDR=m[0]["DST_ADDR"] + 4))
    probe("R3 IN_BYTES == 0", "IN_BYTES bad @0",
          lambda m: m[0].update(IN_BYTES=0))
    probe("R3 IN_BYTES % 32 != 0", "IN_BYTES bad @0",
          lambda m: m[0].update(IN_BYTES=16))
    probe("R3 SRC out of DDR window", "addr OOB @0",
          lambda m: m[0].update(SRC_ADDR=DDR_BYTES))
    probe("R3 DST out of DDR window", "addr OOB @0",
          lambda m: m[0].update(DST_ADDR=DDR_BYTES))
    # R4：自环
    probe("R4 self-loop (SRC == DST)", "self-loop @0",
          lambda m: m[0].update(DST_ADDR=m[0]["SRC_ADDR"]))
    # R5：FLAGS 语义 + 链结构（A-2：(P | H M* T)* 状态机）—— 负对照五档
    probe("R5 middle without predecessor @0", "middle without predecessor @0",
          lambda m: m[0].update(FLAGS=FLAGS_MIDDLE))
    probe("R5 tail without predecessor @0", "tail without predecessor @0",
          lambda m: m[0].update(FLAGS=FLAGS_TAIL))
    probe("R5 head without tail @1 (follower=plain)", "head without tail @1",
          lambda m: (m[1].update(FLAGS=FLAGS_HEAD), m[2].update(FLAGS=FLAGS_PLAIN)))
    probe("R5 head without tail @%d (hits SENTINEL)" % (n - 1),
          "head without tail @%d" % (n - 1),
          lambda m: m[n - 1].update(FLAGS=FLAGS_HEAD))

    def _too_long(m):
        r"""表首起造一段 `CHAIN_L_MAX + 1` 片链（`CHAIN_L_MAX=8` ⇒ `H M M M M M M M T` 共 9 片）
        ⇒ `chain too long @9`（越限那一条的下标 = 9）。"""
        for t in range(1, CHAIN_L_MAX + 2):
            for f in CHAIN_GEOM_FIELDS:
                m[t][f] = m[1][f]
            m[t].update(FLAGS=FLAGS_HEAD if t == 1 else
                        (FLAGS_TAIL if t == CHAIN_L_MAX + 1 else FLAGS_MIDDLE))

    probe("R5 chain > CHAIN_L_MAX=%d rejected" % CHAIN_L_MAX,
          "chain too long @%d" % (CHAIN_L_MAX + 1), _too_long)
    probe("R5 chain geom mismatch @2", "chain geom mismatch @2",
          lambda m: (m[1].update(FLAGS=FLAGS_HEAD),
                     m[2].update(FLAGS=FLAGS_TAIL, IMG_W=m[2]["IMG_W"] + 8)))
    # R5 正对照：合法 2 片链 `0b00,0b11` / 合法 4 片链（表尾塑形，见 `_plain_tail_run`）/
    #   **合法 8 片链**（= 本代 `L_MAX`；锚在最末，见 `_tail_chain_at_end` —— 8 片正是
    #   "长 8 的极大链不拆"的那一档，必须过）
    probe("R5 legal 2-slice chain 0b00,0b11 (pos ctl)", "",
          lambda m: _plain_tail_run(m, 2))
    probe("R5 legal 4-slice chain 0b00..0b11 (pos ctl)", "",
          lambda m: _plain_tail_run(m, 4))
    probe("R5 legal 8-slice chain 0b00..0b11 (pos ctl, = L_MAX)", "",
          lambda m: _tail_chain_at_end(m, 8))
    # R6：哨兵三个子句（载荷里不得再出现 0xFF / 表尾必须 0xFF / 哨兵 FLAGS 必须 0）
    probe("R6 SENTINEL inside payload", "SENTINEL inside payload @1",
          lambda m: m[1].update(TYPE=TYPE_SENTINEL))
    probe("R6 SENTINEL missing at tail", "SENTINEL missing at tail (last TYPE=0x01)",
          lambda m: m[-1].update(TYPE=TYPE_CONV3X3))
    probe("R6 SENTINEL FLAGS != 0", "SENTINEL FLAGS 1 != 0",
          lambda m: m[-1].update(FLAGS=1))
    return rows


# ============================ 出口旗标（C3.4：--emit-hex / --emit-meta） ============================
def emit_files(onnx_path, hex_path, meta_path):
    """C3.4 的两个出口（**只加旗标、不动 `--selftest` 的输出，也不动表指纹**）。

      · `--emit-hex  <path>`：整表字节按 `$readmemh` 格式落盘（**一行一个十六进制字节**，
        `rtl_test/AxiMemModel.v` 的 `+MEMFILE=` 直接吃）。RTL 侧因此读的是**同一张表**。
      · `--emit-meta <path>`：逐项的**期望向量**（RTL 侧对账用）：
          `W <idx> <8 个 32-bit 字>` —— 由 `reference_words()` 按**位表独立算**（不经 `unpack`）；
          `F <idx> <14 个字段 k=v> SENTINEL=.. HEAD=.. TAIL=..` —— 由 `unpack(pack(d))` **往返**
            得到（不是直接抄 build dict）；FLAGS 两个语义位 `HEAD = !(FLAGS & 1)`、`TAIL = !!(FLAGS & 2)`。
          ⇒ W 行（位表独立算法）与 F 行（`pack`/`unpack` 往返）是**两条独立实现**，互为交叉对账。
    每一份都先断言"与自检用的那份字节**逐字节相同**"（`pack_table` 的产物 + 哨兵项自洽），
    再落盘 ⇒ 出口与自检不可能漂移成两套。
    """
    gv = dt.GraphView(onnx_path)
    descs, _info = build_table(gv)
    full = descs + [dict(SENTINEL)]
    blob = pack_table(descs)
    # 出口的正确性自检（**不是**"自己比自己"：这里比的是"整表字节"与"逐项 pack 出来的字节"
    # 两条**不同**的构造路径，再与上面那句"哨兵项必须与 pack(SENTINEL) 一致"合起来钉住）
    assert len(full) == DESC_TOTAL_FROZEN, "表项数 %d != 冻结 %d" % (len(full), DESC_TOTAL_FROZEN)
    assert blob == b"".join(pack(d) for d in full), "整表字节 != 逐项 pack 的拼接"
    md5 = hashlib.md5(blob).hexdigest()
    print("EMIT_TABLE BYTES=%d ITEMS=%d MD5=%s" % (len(blob), len(full), md5))
    if md5 != TABLE_MD5_FROZEN:
        print("EMIT_WARN: 表指纹 %s != C3.2 冻结的 %s（位打包被改过 ⇒ 走 spec 修订）"
              % (md5, TABLE_MD5_FROZEN))
    if hex_path:
        with open(hex_path, "w", encoding="utf-8") as f:
            for b in blob:
                f.write("%02x\n" % b)
        print("EMIT_HEX  %s (%d 行，一行一字节)" % (hex_path, len(blob)))
    if meta_path:
        with open(meta_path, "w", encoding="utf-8") as f:
            f.write("# desc_table.py --emit-meta；W 行 = 期望的 8 个 32-bit 字（按位表独立算）\n")
            f.write("# F 行 = 14 个字段（unpack(pack(d)) 往返口径）+ FLAGS 两位语义（SENTINEL/HEAD/TAIL）\n")
            f.write("# FIELD_ORDER=%s\n" % " ".join(FIELD_ORDER))
            f.write("# TABLE_BYTES=%d ITEMS=%d MD5=%s DESC_COUNT=%d（口径：载荷项数，不含哨兵）\n"
                    % (len(blob), len(full), md5, desc_count_of(full)))
            for i, d in enumerate(full):
                # M2：F 行**真的**走 `unpack(pack(d))`（不是直接抄 build dict）—— 与 W 行的
                # `reference_words`（位表独立算法）互为**两条**独立实现 ⇒ 逐字段对账才钉得死。
                du = unpack(pack(d))
                f.write("W %d %s\n" % (i, " ".join("%08x" % w for w in reference_words(d))))
                f.write("F %d %s SENTINEL=%d HEAD=%d TAIL=%d\n"
                        % (i, " ".join("%s=%d" % (k, du[k]) for k in FIELD_ORDER),
                           1 if du["TYPE"] == TYPE_SENTINEL else 0,
                           0 if (du["FLAGS"] & 1) else 1,
                           1 if (du["FLAGS"] & 2) else 0))
        print("EMIT_META %s (%d 项 x (W+F) 行)" % (meta_path, len(full)))
    return 0


# ============================ 自检 ============================
def selftest(onnx_path):
    gv = dt.GraphView(onnx_path)
    descs, info = build_table(gv)
    full = descs + [dict(SENTINEL)]
    ok = True

    print("desc_table.py --selftest —— 描述符冻结位打包（8×32 bit 小端 = 32 B/项）")
    print("MODEL=%s" % onnx_path)
    print()
    print("== 1) 表来源（只读 ddr_traffic / bypass_traffic / fusion_chains；拿计算值比外部冻结常量） ==")
    print("  FUSE_BOTH_BYTES=%d  (frozen %d) %s"
          % (info["base_bytes"], BASE_BYTES_FROZEN,
             "OK" if info["base_bytes"] == BASE_BYTES_FROZEN else "MISMATCH"))
    print("  UNITS(边)=%d (= %d 个 3×3→1×1 + %d 个 1×1→3×3；**允许重叠**)  (frozen %d/%d/%d) %s"
          % (info["units"], info["units_33x11x"], info["units_11x33x"],
             UNITS_FROZEN, UNITS_33X11X_FROZEN, UNITS_11X33X_FROZEN,
             "OK" if (info["units"] == UNITS_FROZEN
                      and info["units_33x11x"] == UNITS_33X11X_FROZEN
                      and info["units_11x33x"] == UNITS_11X33X_FROZEN) else "MISMATCH"))
    chain_ok = (info["chains"] == CHAINS_FROZEN and info["chain_hist"] == CHAIN_HIST_FROZEN
                and info["chain_nodes"] == CHAIN_NODES_FROZEN
                and info["runs"] == RUNS_FROZEN and info["run_hist"] == RUN_HIST_FROZEN
                and info["covered_edges"] == COVERED_EDGES_FROZEN
                and info["unmatched_edges"] == UNMATCHED_EDGES_FROZEN)
    print("  CHAINS=%d（极大链）  CHAIN_NODES=%d  链长直方图=%s  (frozen %d/%d/%s) %s"
          % (info["chains"], info["chain_nodes"],
             ";".join("%d:%d" % kv for kv in info["chain_hist"].items()),
             CHAINS_FROZEN, CHAIN_NODES_FROZEN,
             ";".join("%d:%d" % kv for kv in CHAIN_HIST_FROZEN.items()),
             "OK" if (info["chains"] == CHAINS_FROZEN
                      and info["chain_hist"] == CHAIN_HIST_FROZEN
                      and info["chain_nodes"] == CHAIN_NODES_FROZEN) else "MISMATCH"))
    print("  RUNS(run 长 <= CHAIN_L_MAX=%d)=%d  run 长直方图=%s  (frozen %d/%s) %s"
          % (CHAIN_L_MAX, info["runs"],
             ";".join("%d:%d" % kv for kv in info["run_hist"].items()),
             RUNS_FROZEN, ";".join("%d:%d" % kv for kv in RUN_HIST_FROZEN.items()),
             "OK" if (info["runs"] == RUNS_FROZEN
                      and info["run_hist"] == RUN_HIST_FROZEN) else "MISMATCH"))
    print("  COVERED_EDGES=%d/%d  UNMATCHED_EDGES=%d（L_MAX=%d ⇒ 最长链 %d 一次跑完、零拆点）  "
          "(frozen %d/%d) %s"
          % (info["covered_edges"], info["units"], info["unmatched_edges"], CHAIN_L_MAX,
             max(info["chain_hist"]), COVERED_EDGES_FROZEN, UNMATCHED_EDGES_FROZEN,
             "OK" if (info["covered_edges"] == COVERED_EDGES_FROZEN
                      and info["unmatched_edges"] == UNMATCHED_EDGES_FROZEN) else "MISMATCH"))
    sac_str = "  ".join("%s->%s(%d B)" % (a, b, sz) for (a, b, _m, sz) in info["sacrificed_edges"])
    print("    拆点（重走一趟 DDR）: %s" % (sac_str if sac_str else "<无>"))
    print("  PER_EDGE_BYTES=%d（**编码层**：33 条边全部可表达 = fuse_both 下界）  (frozen %d) %s"
          % (info["per_edge_bytes"], PER_EDGE_BYTES_FROZEN,
             "OK" if info["per_edge_bytes"] == PER_EDGE_BYTES_FROZEN else "MISMATCH"))
    traffic_ok = (info["per_edge_bytes"] == PER_EDGE_BYTES_FROZEN
                  and info["chain_bytes"] == CHAIN_BYTES_FROZEN)
    # ★ A-3b 的**核心判据**（独立断言，不是"打印出来看看"）：L_MAX=8 下表实际表达的整帧必须
    #   **正好等于**逐边全融合下界 12,576,000 B/帧（零拆点 ⇒ 没有重走 DDR 的代价）。
    assert info["chain_bytes"] == 12576000, \
        "本代表（L_MAX=%d）实际表达的整帧 %d != 12,576,000（零拆点下界）" % (
            CHAIN_L_MAX, info["chain_bytes"])
    print("  CHAIN_BYTES=%d（**本代表**：run <= %d 实际表达的整帧）拆点代价=+%d B"
          "  (frozen %d) %s"
          % (info["chain_bytes"], CHAIN_L_MAX, info["split_cost_bytes"],
             CHAIN_BYTES_FROZEN, "OK" if traffic_ok else "MISMATCH"))
    print("  ★ 编码能表达全部 33 条边（%d B）；本代硬件 L_MAX=%d 也**一次跑得完**最长链 %d 片"
          " ⇒ **零拆点**（拆点代价 %d B）⇒ 整帧 = 下界本身"
          % (PER_EDGE_BYTES_FROZEN, CHAIN_L_MAX, max(info["chain_hist"]),
             info["split_cost_bytes"]))
    print("  含旁路（+%d B）: 逐边全融合档 = %d B/帧 ⇒ %.2f fps；本代表(L_MAX=%d) = %d B/帧 ⇒ %.2f fps"
          "（**下界**：只计激活 IO，不含头张量后处理/对齐填充/权重装载）"
          % (BYPASS_BYTES_FROZEN, info["per_edge_bytes"] + BYPASS_BYTES_FROZEN,
             dt.DDR_MBPS * 1e6 / float(info["per_edge_bytes"] + BYPASS_BYTES_FROZEN),
             CHAIN_L_MAX, info["chain_bytes"] + BYPASS_BYTES_FROZEN,
             dt.DDR_MBPS * 1e6 / float(info["chain_bytes"] + BYPASS_BYTES_FROZEN)))
    print("  链角色 vs drop 集合（两条独立推导；L_MAX=%d ⇒ 零拆点 ⇒ 必须**逐集合相等**）："
          "role_drop_out=%d(=33-%d) / drop_out_nodes=%d；"
          "role_drop_in=%d(=33-%d) / drop_in_tensors=%d ⇒ %s"
          % (CHAIN_L_MAX, info["role_drop_out"], info["unmatched_edges"], info["drop_out_nodes"],
             info["role_drop_in"], info["unmatched_edges"], info["drop_in_tensors"],
             "一致 OK" if info["role_matches_drop"] else "MISMATCH"))
    print("  PAYLOAD=%d DESC_TOTAL=%d DESC_BYTES=%d  (frozen %d/%d/%d) %s"
          % (len(descs), len(full), len(full) * DESC_BYTES,
             PAYLOAD_FROZEN, DESC_TOTAL_FROZEN, TABLE_BYTES_FROZEN,
             "OK" if (len(descs) == PAYLOAD_FROZEN and len(full) == DESC_TOTAL_FROZEN
                      and len(full) * DESC_BYTES == TABLE_BYTES_FROZEN) else "MISMATCH"))
    flags_ok = (info["flags_hist"] == FLAGS_HIST_FROZEN)
    print("  FLAGS: 0b00(head)=%d  0b01(plain)=%d  0b10(middle)=%d  0b11(tail)=%d  (frozen %s) %s"
          % (info["flags_hist"].get(FLAGS_HEAD, 0), info["flags_hist"].get(FLAGS_PLAIN, 0),
             info["flags_hist"].get(FLAGS_MIDDLE, 0), info["flags_hist"].get(FLAGS_TAIL, 0),
             " ".join("0b%s=%d" % (format(k, "02b"), v) for k, v in sorted(FLAGS_HIST_FROZEN.items())),
             "OK" if flags_ok else "MISMATCH"))
    print("  FLAGS 直方图: " + "  ".join("0b%s=%d" % (format(k, "02b"),
                                                   info["flags_hist"][k])
                                        for k in sorted(info["flags_hist"])))
    print("  DESC_COUNT 口径 = **载荷项数（不含哨兵）** = %d（哨兵落在下标 %d）—— 与 RTL 的 descCount 一致"
          % (desc_count_of(full), len(full) - 1))
    bt_per, bt_counts = bt.bypass_per_op(gv)
    byn, byb = info["bypass_nodes"], info["bypass_bytes"]
    by_ok = True
    for k in bt.ORDER:
        good = (byn[k] == BYPASS_OPS_FROZEN[k] and bt_counts[k] == BYPASS_OPS_FROZEN[k]
                and byb[k] == BYPASS_CLASS_BYTES_FROZEN[k] and bt_per[k] == byb[k])
        by_ok &= good
        print("  BYPASS %-8s nodes=%d(frozen %d) my_bytes=%-9d bt_bytes=%-9d frozen=%-9d %s"
              % (k, byn[k], BYPASS_OPS_FROZEN[k], byb[k], bt_per[k],
                 BYPASS_CLASS_BYTES_FROZEN[k], "OK" if good else "MISMATCH"))
    print("  BYPASS_BYTES=%d (frozen %d) %s"
          % (sum(byb.values()), BYPASS_BYTES_FROZEN,
             "OK" if sum(byb.values()) == BYPASS_BYTES_FROZEN else "MISMATCH"))
    ov_inputs, ov_hit, _ = bt.overlap_probe(gv)
    print("  OVERLAP_PROBE bypass_inputs=%d produced_by_fused_drop=%d (frozen %d) %s"
          % (ov_inputs, ov_hit, BYPASS_ON_FUSED_BOUNDARY_FROZEN,
             "OK" if ov_hit == BYPASS_ON_FUSED_BOUNDARY_FROZEN else "MISMATCH"))
    print("  IN_BYTES 读==写 的项=%d；读≠写 的项=%d（后者按 max(Σ读, 写) 取上界）"
          % (info["unit_bytes"]["read_eq_write"], info["unit_bytes"]["read_ne_write"]))
    print("  DDR_BYTES=%d (2^%d，与 DdrMaster.ADDR_W=%d 同源)；DESC_ADDR 建议 0x%08X"
          % (DDR_BYTES, DDR_ADDR_W, DDR_ADDR_W, DESC_TABLE_ADDR_SUGGEST))
    print("  张量槽位：%d 个张量，arena_top=0x%08X (%.3f MiB，窗内 %s)"
          % (info["arena_tensors"], info["arena_top"], info["arena_top"] / 1048576.0,
             "OK" if info["arena_top"] <= DDR_BYTES else "OVERFLOW"))
    print("  TYPE 直方图（最终表）: " + "  ".join("%s=%d" % (TYPE_NAME[t], info["types"][t])
                                                 for t in sorted(info["types"])))
    # ---- ★ 与冻结件 `tools/fusion_chains.py`（C3.11b）**交叉对账**（只读；两条独立实现）----
    fcs = fc.solve(gv)
    fc_chains = sorted(tuple(ch.nodes) for ch in fcs["chains"])
    my_chains = sorted(tuple(c) for c in info["chain_seq"])
    fc_doM, fc_diM, fc_covM, fc_sacM = fc.internal_edges_of_groups(
        fcs["chains"], fcs["l_max"], fcs["tensor_of"], fcs["size_of"])
    fc_doL, fc_diL, fc_covL, fc_sacL = fc.internal_edges_of_groups(
        fcs["chains"], CHAIN_L_MAX, fcs["tensor_of"], fcs["size_of"])
    fc_per_edge = fc.traffic_bytes(gv, fc_doM, fc_diM)
    fc_chain = fc.traffic_bytes(gv, fc_doL, fc_diL)
    xcheck_ok = (fc_chains == my_chains
                 and fc_covM == info["units"] and fc_sacM == 0
                 and fc_per_edge == info["per_edge_bytes"]
                 and fc_covL == info["covered_edges"] and fc_sacL == info["unmatched_edges"]
                 and fc_chain == info["chain_bytes"])
    print("  与 fusion_chains.py 交叉对账：链集合==%s；L_MAX=%d -> 覆盖 %d/%d 牺牲 %d 流量 %d（frozen %d）；"
          "L=%d -> 覆盖 %d 牺牲 %d 流量 %d（frozen %d） ⇒ %s"
          % (1 if fc_chains == my_chains else 0, fcs["l_max"], fc_covM, info["units"], fc_sacM,
             fc_per_edge, PER_EDGE_BYTES_FROZEN, CHAIN_L_MAX, fc_covL, fc_sacL, fc_chain,
             CHAIN_BYTES_FROZEN, "OK" if xcheck_ok else "MISMATCH"))
    src_ok = (info["base_bytes"] == BASE_BYTES_FROZEN and info["units"] == UNITS_FROZEN
              and info["units_33x11x"] == UNITS_33X11X_FROZEN
              and info["units_11x33x"] == UNITS_11X33X_FROZEN
              and chain_ok and traffic_ok and flags_ok
              and len(descs) == PAYLOAD_FROZEN and len(full) == DESC_TOTAL_FROZEN
              and by_ok and ov_hit == BYPASS_ON_FUSED_BOUNDARY_FROZEN
              and info["role_matches_drop"] and xcheck_ok)

    print()
    print("== 2) 表（逐项；执行序 = 表序 = ONNX 节点序，跳过逐元素/布局算子） ==")
    print("  %-3s %-9s %-6s %5s %5s %5s %5s %5s %4s %4s %10s %10s %9s %3s %3s"
          % ("idx", "type", "flags", "IMG_W", "IMG_H", "C_IN", "C_OUT", "GROUP",
             "STR", "PAD", "SRC", "DST", "IN_BYTES", "QS", "LID"))
    for i, d in enumerate(full):
        print("  %-3d %-9s 0b%s  %5d %5d %5d %5d %5d %4d %4d 0x%08X 0x%08X %9d %3d %3d"
              % (i, TYPE_NAME.get(d["TYPE"], "?"), format(d["FLAGS"], "02b"),
                 d["IMG_W"], d["IMG_H"], d["C_IN"], d["C_OUT"], d["GROUP"], d["STRIDE"],
                 d["PAD"], d["SRC_ADDR"], d["DST_ADDR"], d["IN_BYTES"],
                 d["QUANT_SHIFT"], d["LAYER_ID"]))

    # ---------------- 判据 1：正向（pack/unpack 逐字段 + 独立字对账 + 合法表过 validate） ----------------
    blob = pack_table(descs)
    roundtrip_bad = 0
    bad_detail = []
    for i, d in enumerate(descs):
        got = unpack(blob[i * DESC_BYTES:(i + 1) * DESC_BYTES])
        for k in FIELD_ORDER:
            if got[k] != d[k]:
                roundtrip_bad += 1
                if len(bad_detail) < 8:
                    bad_detail.append("i=%d %s: %r != %r" % (i, k, got[k], d[k]))
    sentinel_ok = (unpack(blob[-DESC_BYTES:]) == SENTINEL)
    # 独立字对账：直接按**字节偏移**解 8 个字（不经 unpack），与 reference_words 比
    raw_bad = 0
    for i, d in enumerate(full):
        words = struct.unpack_from("<8I", blob, i * DESC_BYTES)
        if list(words) != reference_words(d):
            raw_bad += 1
            if len(bad_detail) < 8:
                bad_detail.append("i=%d raw words %s != %s" % (i, words, reference_words(d)))
        if (words[0] & 0xFFFF0000) or (words[3] & 0xFFFF0000) or (words[7] & 0xFFFF0000):
            raw_bad += 1              # 保留位必须为 0（位表：w0[31:16]、w3[31:16]、w7[31:16]）
    try:
        validate(full, desc_count_of(full), DDR_BYTES)
        pos_val_ok, pos_val_msg = True, ""
    except DescError as e:
        pos_val_ok, pos_val_msg = False, str(e)
    check1 = (roundtrip_bad == 0 and sentinel_ok and raw_bad == 0 and pos_val_ok and src_ok)

    # ---------------- 判据 2：负对照 A（打包器自检：翻 w6 的 bit ⇒ IN_BYTES 必须变） ----------------
    probe = descs[0]
    b0 = pack(probe)
    k_bit = 5
    w6 = struct.unpack_from("<I", b0, 24)[0]
    w6_exp = w6 ^ (1 << k_bit)
    mutated = bytearray(b0)
    struct.pack_into("<I", mutated, 24, w6_exp)
    got = unpack(bytes(mutated))
    flip_ok = (got["IN_BYTES"] == w6_exp and got["IN_BYTES"] != probe["IN_BYTES"])
    same_others = all(got[k] == probe[k] for k in FIELD_ORDER if k != "IN_BYTES")
    # 附加探针：翻 w7 的 bit（LAYER_ID 侧）⇒ LAYER_ID 必须变
    probe7 = descs[5]
    b7 = bytearray(pack(probe7))
    w7 = struct.unpack_from("<I", b7, 28)[0]
    struct.pack_into("<I", b7, 28, w7 ^ (1 << 8))
    got7 = unpack(bytes(b7))
    flip_ok &= (got7["LAYER_ID"] == probe7["LAYER_ID"] ^ 1 and got7["LAYER_ID"] != probe7["LAYER_ID"])
    check2 = bool(flip_ok and same_others)

    # ---------------- 判据 3：负对照 B（非法 TYPE 0x77 ⇒ validate 必须抛） ----------------
    mut = [dict(d) for d in descs]
    mut[3]["TYPE"] = 0x77
    try:
        validate(mut + [dict(SENTINEL)], desc_count_of(full), DDR_BYTES)
        bad_type_raised, bad_type_msg = False, ""
    except DescError as e:
        bad_type_raised, bad_type_msg = True, str(e)
    expect_msg = "bad TYPE 0x77 @3"
    check3 = bool(bad_type_raised and bad_type_msg == expect_msg)

    # ---------------- 判据 4：负对照 C（COUNT 口径/哨兵不符 ⇒ validate 必须抛） ----------------
    #   ★ C3.11a：desc_count 的正确口径 = **载荷项数（不含哨兵）**；下面两条都用**错**口径，
    #     "旧口径（= 表长，含哨兵）" 这一档现在必须报错 —— 正是本轮订正的那条。
    n_payload = desc_count_of(full)
    msg_plus = msg_minus = ""
    raised_plus = raised_minus = False
    try:
        validate(full, len(full), DDR_BYTES)              # 旧口径（含哨兵）⇒ 错
    except DescError as e:
        raised_plus, msg_plus = True, str(e)
    try:
        validate(full, n_payload - 1, DDR_BYTES)          # 少数一项 ⇒ 错
    except DescError as e:
        raised_minus, msg_minus = True, str(e)
    # 附加：把哨兵 FLAGS 改成 3（规则 6）也必须抛
    sent_bad = [dict(d) for d in full]
    sent_bad[-1]["FLAGS"] = 3
    try:
        validate(sent_bad, n_payload, DDR_BYTES)
        sent_flags_raised, sent_flags_msg = False, ""
    except DescError as e:
        sent_flags_raised, sent_flags_msg = True, str(e)
    check4 = bool(raised_plus and raised_minus and sent_flags_raised
                  and msg_plus == "DESC_COUNT %d != %d" % (len(full), n_payload)
                  and msg_minus == "DESC_COUNT %d != %d" % (n_payload - 1, n_payload))

    # ---------------- 判据 5：六规则负对照表（`_rule_probe`；规则 (2)–(6) 每条都有负控制） ----------------
    rule_rows = _rule_probe(full)
    rule_bad = [r for r in rule_rows if r[1] != r[2]]
    check5 = not rule_bad

    # ---------------- 判据输出 ----------------
    print()
    print("== 3) 判据（五条，缺一不可；每条都拿计算值比**外部**期望） ==")
    print("SELFTEST_ROUNDTRIP  ROUNDTRIP_BAD=%d RAW_WORD_BAD=%d SENTINEL_OK=%d "
          "POSITIVE_VALIDATE_OK=%d TABLE_SOURCE_OK=%d"
          % (roundtrip_bad, raw_bad, 1 if sentinel_ok else 0, 1 if pos_val_ok else 0,
             1 if src_ok else 0))
    if pos_val_msg:
        print("  POSITIVE_VALIDATE_ERR=%s" % pos_val_msg)
    for m in bad_detail:
        print("  ROUNDTRIP_DETAIL %s" % m)
    print("  TABLE_BYTES=%d MD5=%s" % (len(blob), hashlib.md5(blob).hexdigest()))
    print("SELFTEST_ROUNDTRIP_OK=%d" % (1 if check1 else 0))

    print("SELFTEST_NEGCTL_BITFLIP  w6: IN_BYTES 0x%X → 0x%X（期望 0x%X）；其余字段不变=%d"
          % (probe["IN_BYTES"], w6_exp, w6_exp, 1 if same_others else 0))
    print("  w7 探针: LAYER_ID %d → %d（期望 %d）"
          % (probe7["LAYER_ID"], probe7["LAYER_ID"] ^ 1, probe7["LAYER_ID"] ^ 1))
    print("SELFTEST_NEGCTL_BITFLIP_OK=%d" % (1 if check2 else 0))

    print("SELFTEST_NEGCTL_BADTYPE  raise=%d msg=%r (期望 %r)"
          % (1 if bad_type_raised else 0, bad_type_msg, expect_msg))
    print("SELFTEST_NEGCTL_BADTYPE_OK=%d" % (1 if check3 else 0))

    print("SELFTEST_NEGCTL_COUNT  desc_count=%d（旧口径：表长含哨兵）⇒ raise=%d msg=%r；"
          "desc_count=%d ⇒ raise=%d msg=%r（正确口径 = 载荷 %d）"
          % (len(full), 1 if raised_plus else 0, msg_plus,
             n_payload - 1, 1 if raised_minus else 0, msg_minus, n_payload))
    print("  附加（哨兵 FLAGS≠0）: raise=%d msg=%r" % (1 if sent_flags_raised else 0, sent_flags_msg))
    print("SELFTEST_NEGCTL_COUNT_OK=%d" % (1 if check4 else 0))

    print("SELFTEST_NEGCTL_RULES  规则 (1)–(6) 负对照表（_rule_probe）：cases=%d mismatch=%d"
          % (len(rule_rows), len(rule_bad)))
    for label, expect, got in rule_rows:
        print("    %-30s expect=%r got=%r %s"
              % (label, expect, got, "OK" if expect == got else "MISMATCH"))
    print("SELFTEST_NEGCTL_RULES_OK=%d" % (1 if check5 else 0))

    ok = bool(check1 and check2 and check3 and check4 and check5)
    print()
    print("RESULT: %s" % ("PASS" if ok else "FAIL"))
    return 0 if ok else 1


def main(argv):
    # ---- C3.4 追加的两个出口旗标（**additive**：不改 `--selftest` 的输出、不改表指纹）----
    #      解析走**自己一条**通路：`--emit-hex <path>` / `--emit-meta <path>` 各吃**一个**参数，
    #      其余参数原样落到 `args`（与旧口径 `[a for a in argv[1:] if not a.startswith("--")]`
    #      在只给 `--selftest` 时**逐字等价**）。
    emit_hex = emit_meta = None
    rest = []
    i = 1
    while i < len(argv):
        a = argv[i]
        if a in ("--emit-hex", "--emit-meta"):
            if i + 1 >= len(argv):
                print("FATAL: %s 需要一个路径参数" % a)
                return 2
            if a == "--emit-hex":
                emit_hex = argv[i + 1]
            else:
                emit_meta = argv[i + 1]
            i += 2
            continue
        rest.append(a)
        i += 1
    args = [a for a in rest if not a.startswith("--")]
    onnx_path = args[0] if args else "../third_party/yunet/yunet.onnx"
    if emit_hex or emit_meta:
        return emit_files(onnx_path, emit_hex, emit_meta)
    if "--selftest" not in argv:
        print(__doc__)
        return 2
    return selftest(onnx_path)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
