# Y1-A3-static — 从 RTL 静态算 DDR 访问路径的吞吐上限

**Status: DONE_WITH_CONCERNS**
（离线分析已做完、每个数字都可追到引文；concern 在于：**唯一能过 305 的候选路径（旁路直连）
其"可达值"取决于 DDR3 IP 内部加密源码，静态读不出** ⇒ 最终 ≥305/≥458 的 yes/no 需要上板量。）

**一句话判定**
`RESULT: 静态算不出（列出缺什么）`
> 细分（两条可静态证明的事实）：
> 1. **桥路径（现架构唯一进 DDR 的路）可静态钉死 ≈276 MB/s < 305** ⇒ 「每层激活走 DDR 往返」的现架构达不到 10fps。
> 2. **旁路直连（burst master 直挂 IP 用户口）结构上存在**，原始上限 4000 MB/s（是 458 的 ~8.7×）；
>    但它的可达值取决于 IP 内部（加密 `.vp`）的 `wready` 占空比/仲裁 ⇒ 这一项静态读不出，需实测。

工作负载：**30.5 MB/次推理**；**305 MB/s ⇔ 10 fps**（30.5/305 = 0.1 s），**458 MB/s ⇔ 15 fps**（30.5/458 = 0.0666 s）。

---

## 1. 输入（全部带 `file:line` + 逐字引文）

### 1.1 频率与位宽（A1 的既有结论，此处复核）

| 量 | 值 | 引文 |
|---|---|---|
| `cpu_clk`（AXI/SoC 侧，= 桥的 `clock`） | **100.000 MHz** | `constraints/yeshen_mini.fdc:113` `create_clock -name {cpu_clk} [get_pins {u_pll/u_gpll/CLKOUT0}] -period {10.000} -waveform {0 5.000}` |
| `core_clk`（DDR IP 侧，= 桥的 `io_ddr_clk`） | **125 MHz** | `constraints/yeshen_mini.fdc:121` `create_generated_clock -name {core_clk} -source [get_ports {ref_clk_p}] [get_pins {u_ddr3.u_ddrphy_top.ddrphy_gpll/clkout0}] -master_clock [get_clocks {ref_clk}] -multiply_by {16} -divide_by {16}`（ref_clk 125MHz：`fdc:88` `create_clock -name {ref_clk} [get_ports {ref_clk_p}] -period {8.0}`） |
| IP 用户口数据宽 | **256 bit = 32 B/beat** | `third_party/ddr3_ip_200h/ddr3_test/ddr3_test.v:45` `input  [8*MEM_DQ_WIDTH-1:0]        axi_wdata`，`ddr3_test.v:20` `parameter MEM_DQ_WIDTH = 32` ⇒ 8×32 = 256 bit |
| IP 用户口 word 地址单位 | **32 bit 字**（一笔 256bit = 32B = 8 字） | `board/yeshen_mini_board_top.v:374` `wire [27:0]  ddr_axi_awaddr;` + `DDR3Bridge.scala:24-25` 引 Pango 官方 `test_wr_ctrl_v1_0.v`：`init_addr <= init_addr + 8` 每 `axi_wready` |

> ⚠️ **文档不一致（不影响结论，只记一笔）**：`src/soc/DDR3Bridge.scala:9` 的头注释写
> `// CPU 侧 (axi_clk 域, 80MHz)`，但实测口径是 **100 MHz**：桥的 `clock` 接的是 `cpu_clk`
> （`board/yeshen_mini_board_top.v:403` `.clock (cpu_clk)`，同文件 `:120` `wire cpu_clk; // PLL clkout0 = 100MHz`）。
> 本报告一律按 **100 MHz**（有 fdc/board 引文）；若按过时的 80MHz 算，桥更慢（见 §4 备注）。

### 1.2 CDC 实现 —— `CDCPipe`（`src/soc/CDCQueue.scala`）

文件头即写明"4 相电平握手 + 2 级同步器"：

```
 4  // ===================== 单向跨域传输（4相电平握手） =====================
 5  // 源域(sClk) → 目的域(dClk)，2 级同步器 + 电平握手
 6  // req(电平) / ack(电平) 协议: 任何时钟频率比都不会丢失握手
```

源域两个同步器（`dAckOut`←目的域 ack 电平）与 enq 许可：

```
28    val ackSync1 = withClockAndReset(io.sClk, !io.sRstn) { RegInit(false.B) }
29    val ackSync2 = withClockAndReset(io.sClk, !io.sRstn) { RegInit(false.B) }
...
31    ackSync1 := dAckOut   // 目的域 ack 电平（跨域，由下面同步器采样）
32    ackSync2 := ackSync1
...
34    io.enq.ready := !sValid && !ackSync2
35    when(io.enq.fire) {
36      sData := io.enq.bits
37      sValid := true.B
38    }.elsewhen(ackSync2) {
39      // ack 电平同步回来 → 清除 req；等待 ack 也清除后才允许新事务
40      sValid := false.B
41    }
```

目的域两个同步器（`sValid`←源域 req 电平）与 deq/ack：

```
44    val validSync1 = withClockAndReset(io.dClk, !io.dRstn) { RegInit(false.B) }
45    val validSync2 = withClockAndReset(io.dClk, !io.dRstn) { RegInit(false.B) }
...
50    validSync1 := sValid
51    validSync2 := validSync1
...
54    when(validSync2 && !dPending) {
55      dData := sData
56      dPending := true.B
57    }.elsewhen(!validSync2) {
58      // req 已清除 → 复位 pending 和 ack
59      dPending := false.B
60      dAck := false.B
61    }
...
63    io.deq.valid := dPending
...
67    when(io.deq.fire) {
68      dAck := true.B
69    }
...
71    dAckOut := dAck
```

**同步器深度 = 2（两个方向各 2 级）：** `validSync1/2`（`:50-51`）、`ackSync1/2`（`:31-32`）。

### 1.3 桥的不变量（`src/soc/DDR3Bridge.scala` 文件头 + 关键代码）

```
36  // 简化 AXI 协议特性（紫光同创 DDR3 IP 用户接口）:
37  // - W 通道无 wvalid，wready 高即采样 → 数据必须始终有效
38  // - AW 握手后连续发 awlen+1 个 256bit beat
...
40  // 1. **一笔 DDR 事务只发 1 个 256bit beat**（`ddrAwLen`/`ddrArLen` 恒 0）。理由：DDR3 IP 的 W 通道
41  //    没有 wvalid（wready 高即采样），而两个 beat 之间必须过一次跨域握手（`wPipe`），无法保证背靠背
42  //    连续；R 通道同理没有 rready，多 beat 突发会顶掉 CDC 管道。
...
45  //    例（64bit 从口）：Dcache 64B 行回写 = 8 拍 AXI = 2 笔 DDR 事务；ICache/Dcache 行填充 = arlen 7 = 2 笔。
...
50  // 3. 单 outstanding 事务
```

- 一笔 DDR 事务 = 1 beat：`DDR3Bridge.scala:366` `io.ddrAwLen := 0.U`、`:462` `io.ddrArLen := 0.U`。
- 单 outstanding（AW 侧）：`:191` `axi.aw.awready := wrState === sWrIdle`（只在 idle 收 AW）。
- 读侧还要**等管道空**才发 AR：`:463` `io.ddrArValid := ddrRdState === 1.U && rPipe.io.enq.ready`。
- 一个 32B 组 = 4 拍 AXI（64bit 从口）：`:130-131`
  `private val GRP_BYTES = 32` / `private val GRP_BEATS = GRP_BYTES / AXI_BYTES   // = 4`。
- 每个方向都是一条 `CDCPipe`：`:150-154` `awPipe/wPipe/arPipe/rPipe/donePipe`；`:64-68` 头注释列出 5 条跨域管。
- "本次呈现已取用"纪律（`*ItemTaken`）：`:360-362`、`:375-377`、`:379-382` —— **下一份必须等上一份呈现"撤干净"**，
  而"撤干净"要一个完整的 4 相往返，所以一条管**每 32B 只可能流一份**。

### 1.4 DDR3 IP 用户口协议（`third_party/ddr3_ip_200h/ddr3_test/ddr3_test.v`）

```
38    input  [CTRL_ADDR_WIDTH-1:0]       axi_awaddr                    ,
...
41    input  [3:0]                       axi_awlen                     ,
42    output                             axi_awready                   ,
43    input                              axi_awvalid                   ,
44
45    input  [8*MEM_DQ_WIDTH-1:0]        axi_wdata                     ,
46    input  [MEM_DQ_WIDTH-1:0]          axi_wstrb                     ,
47    output                             axi_wready                    ,
48    output [3:0]                       axi_wusero_id                 ,
49    output                             axi_wusero_last               ,
...
54    input  [3:0]                       axi_arlen                     ,
...
58    output [8*MEM_DQ_WIDTH-1:0]        axi_rdata                     ,
59    output [3:0]                       axi_rid                       ,
60    output                             axi_rlast                     ,
61    output                             axi_rvalid                    ,
```
```
295   assign core_clk = ddrphy_sysclk;
```

**从模块头可读出的协议约束：**
- **W 通道无 `wvalid`**：只有 `axi_wdata[255:0]` / `axi_wstrb[31:0]` / `axi_wready`（`:45-47`）——确认。
- **R 通道无 `rready`**：只有 `axi_rdata` / `axi_rvalid` / `axi_rlast` / `axi_rid`（`:58-61`）——确认。
- **但 IP 支持突发**：`axi_awlen`/`axi_arlen` 是 4 bit（`:41`/`:54`）⇒ 一笔最多 `awlen=15` ⇒ **16 beat**。

### 1.5 直连路径证据 —— Pango 官方 example design 用的是 **16-beat 突发**

同一颗 IP 的官方写控制器（`third_party/ddr3_ip_200h/ddr3_test/example_design/rtl/test_wr_ctrl_v1_0.v`）：

```
134        axi_awlen <= 4'd15;
...
139             axi_awaddr <= axi_awaddr + 8'd128;
...
209        if(axi_wready)
210        init_addr <= init_addr + 8;
```

- `:134` 用 `awlen=15`（16 beat/笔），`:139` 每笔地址推进 128 字（= 512 B = 16×32B ✓），
  `:209-210` **每个 `axi_wready` 推 8 字 = 32 B = 1 个 256bit beat**。
  ⇒ **IP 用户口确实接受背靠背多 beat 突发**（突发内数据地址逐 beat 递增，没有跨域握手）。

读侧同理（`.../test_rd_ctrl_v1_0.v`）：
```
248      if(cnt_len <= axi_arlen) begin
249        if(axi_rvalid) begin
250          normal_rd_addr <= normal_rd_addr + 8;
```
⇒ 每个 `axi_rvalid` = 1 个 32B beat，读也支持 `arlen` 突发。

### 1.6 拓扑：现在谁挂在 IP 口上（决定"直连"是不是新增设计）

- IP 用户口是**单个 AXI slave**，在板级只接一条线束 `ddr_axi_*`：
  `board/yeshen_mini_board_top.v:480-524`（`ddr3_test u_ddr3 ( .axi_awaddr(ddr_axi_awaddr) ... )`）。
- 这条线束的另一端**只接 DDR3Bridge 的 DDR 侧的 `io_ddr*`**：
  `board/yeshen_mini_board_top.v:402-461`（`DDR3Bridge u_bridge ( ... .io_ddrAwAddr(ddr_axi_awaddr) ... )`）。
- SoC 侧（100 MHz、64bit）所有内存主口先合并成**一个**从口再进桥：
  `src/YeshenSocGlue.scala:12-13`（`mem` 形状 = `AXIIO64`，64bit）与 `:625`
  `// DDR3Bridge 只有**一个**单 outstanding 的从口 ⇒ 这里把前两个内存主口合并成模板`。

⇒ **现状：整个 SoC（含任何 fabric 加速器）要访 DDR，只有"经桥"这一条路。**
**直连 = 需要新增（在 IP 口前加一路 master / 仲裁器），不是"打开一个开关"。**

---

## 2. CDC 四相握手每笔的拍数（逐拍推导，不猜）

以 **写路径的 `wPipe`（`sClk = cpu_clk`、`dClk = core_clk`）** 为例，从"源域 `enq.fire`"到"源域下一次 `enq.ready`"：

| # | 事件 | 域 | 拍 | 依据 |
|---|---|---|---|---|
| A | `enq.fire` → `sValid:=1` | sClk | **1** | `CDCQueue.scala:35-37` |
| B | `validSync1:=sValid` / `validSync2:=validSync1` / `dPending:=1`（= `deq.valid`） | dClk | **3** | `:50-51`、`:54-56`、`:63` |
| C | `deq.fire` → `dAck:=1` | dClk | **1** | `:67-69` |
| D | `ackSync1:=dAckOut` / `ackSync2:=ackSync1` / `sValid:=0` | sClk | **3** | `:31-32`、`:38-40` |
| E | `validSync1:=0` / `validSync2:=0` / `dPending:=0,dAck:=0` | dClk | **3** | `:50-51`、`:57-60` |
| F | `ackSync1:=0` / `ackSync2:=0` → `enq.ready=1` | sClk | **2** | `:31-32`、`:34` |

```
sClk（100 MHz）侧合计 = A + D + F = 1 + 3 + 2 = 6 拍
dClk（125 MHz）侧合计 = B + C + E = 3 + 1 + 3 = 7 拍
```

**"来源域-目的域"两段是异步且（因单 outstanding）不可重叠 ⇒ 每笔墙钟时间 = 两段之和**：

```
T = 6 / f_s + 7 / f_d   ,  f_s = 100 MHz, f_d = 125 MHz
  = 6/100e6 + 7/125e6
  = 60.0 ns + 56.0 ns
  = 116.0 ns / 32 B
```

> 口径澄清：`sync 深度 × 相数` 的"教科书"读法是 2 级 × 4 相 = 8 个同步器拍（s 侧 4 + d 侧 4）；
> 实测 RTL 在同步器之外还有状态机寄存器（A、C 各自 +1，D/E 各 +1），故精确值是 **s=6 / d=7**。
> 两种口径都指向同一量级；**关键是两域拍数必须相加，不能只数一个域**（见 §4 反面示例）。

---

## 3. 桥的吞吐上限（含宽度/域的转换点）

- **一拍数据量 = 32 B**：转换点在 `DDR3Bridge.scala:128-131`
  （AXI 从口 64bit/拍 ×4 拍 = 32 B 聚合成 1 个 256bit beat），并 `:202-203` `Cat` 聚合。
- **一拍 = 一次 4 相往返**：`ddrAwLen/ArLen ≡ 0`（`:366`/`:462`）+ 单 outstanding（`:191`/`:50`）
  ⇒ 每个 32 B 都要走完 §2 的 116 ns。

```
桥路径上限  = 32 B / T = 32 B / 116 ns = 275 862 069 B/s ≈ 276 MB/s
```

对比目标：**305 MB/s 需要 ≤104.9 ns/beat；458 MB/s 需要 ≤69.9 ns/beat**；桥是 **116 ns** ⇒ **两个目标都够不着**。
（若误用头注释的 80 MHz：`T = 6/80e6 + 7/125e6 = 75+56 = 131 ns → 244 MB/s`，更差。）

运行 `y1/partA/ddr_path_ceiling.py bridge 6 100e6 7 125e6` 复现：`275.9 MB/s [FAIL <305]`。

---

## 4. 各候选路径的算术（100/125 MHz 两侧）

| 路径 | 每 32B 的时间 | MB/s | 判据 |
|---|---|---|---|
| **桥（现架构唯一路）**：6 s-拍@100 + 7 d-拍@125 | 116.0 ns | **275.9** | **< 305 ⇒ FAIL** |
| 桥·异步最坏（+1 拍/次穿越）：8@100 + 9@125 | 152.0 ns | 210.5 | 更差（界） |
| 反面示例：**只数 d 域** 7 拍@125（错） | 56.0 ns | 571.4 | 会误判"过 458" |
| 反面示例：**只数 s 域** 6 拍@100（错） | 60.0 ns | 533.3 | 会误判"过 458" |
| 反面示例：**教科书 8 拍**@125（错） | 64.0 ns | 500.0 | 也会误判"过 458" |
| **直连旁路**：原始上限 32 B × 125 MHz | 8.0 ns | **4000.0** | 原始 ≫458（可达值未知，见 §5）|
| （参考）SoC 64bit @100MHz 原始 | — | 800.0 | 原始 ≫458，非瓶颈 |

> **为什么"只数一个域"是错的**：单 outstanding 下，源域等 ack 的拍与目的域等 valid 的拍是
> **前后相继、不可重叠**的墙钟两段；漏掉任一段都会把 276 抬成 530~570，从而得出相反的结论。
> 这也解释了 A1 对"raw ≠ achievable"的直觉：**raw 4000 与真值 276 之间差的正是这一串协议往返。**

---

## 5. 逐约束的拍数成本（桥路径）

| 约束 | 出处 | 每 32B 的拍/时间成本 |
|---|---|---|
| **CDC 四相往返（单 outstanding）** | `CDCQueue.scala:28-71`（§2） | **6 s-拍 + 7 d-拍 = 116 ns** —— 压倒性主项 |
| `ddrAwLen/ddrArLen ≡ 0`（一笔仅 1 beat） | `DDR3Bridge.scala:366`/`:462` | 使 116 ns **无法摊薄到 >32B**（IP 本可 16-beat 突发，见 §1.5）——这条是**桥自加的** |
| 单 outstanding | `DDR3Bridge.scala:50`/`:191` | 禁止 AW/AR/W 流水 ⇒ 上面那次往返不可与其他事务重叠 |
| R 通道无 `rready` | `ddr3_test.v:58-61`；`DDR3Bridge.scala:463` | AR 必须等 `rPipe` 空才发 ⇒ 读延迟**完全不能隐藏**，每个 32B 都吃一遍（拍数取决于 DDR 延迟，静态不可数）|
| W 通道无 `wvalid` | `ddr3_test.v:45-47`；头注释 `:37` | 对桥本身 ≈0（已用 `wDataReg` 预置，`:337`/`:368`）；**对域内 master 也是 0**（不需跨域即可背靠背）|

**要点：把桥拖到 276 的，是"CDC 往返 × 单 outstanding × 每笔仅 1 beat"三者相乘。
其中"每笔仅 1 beat"这一条是桥为了配合自己的 CDC 而自选的（§1.5 证明 IP 支持 16-beat 突发）。**

---

## 6. 直连（旁路桥）master 路径的判定

**存在吗？—— 结构上存在。** 证据：
1. IP 用户口就是模块端口（`ddr3_test.v:38-61`），板级以 `ddr_axi_*` 线束暴露
   （`board/yeshen_mini_board_top.v:374-387`），**并非只对桥可见**。
2. 该口的协议支持突发（`axi_awlen[3:0]`，`ddr3_test.v:41`），官方 example 就用 `awlen=15`
   （`test_wr_ctrl_v1_0.v:134`）且每 `wready` 推 1 个 32B beat（`:209-210`）⇒ **域内 master 可背靠背发 beat，不需要任何 CDC**。
3. 代价：IP 口是**单 slave**，现挂的是桥（`board/yeshen_mini_board_top.v:402/480`）。
   要直连需**新增一路 master（或加仲裁器）**——属于设计改动，但**不涉及改 IP/third_party**。

**它的上限（静态能给的最强结论）：**
- 协议原始上限 = `32 B × 125 MHz = 4000 MB/s`（= 458 的 ~8.7×，= 305 的 ~13×）。
- 换算成"要求"：过 458 只需 IP 平均**每 ≤8.73 个 core_clk 接受 1 个 beat**；过 305 需**每 ≤13.1 拍 1 个**。
- 但它**可达多少拍/beat，读不出来**：IP 的用户口状态机在 `ips2l_mcdq_ui_axi_v1_2a.vp` 等文件里，
  是 **Synplify 加密的 `.vp`**（`pragma protect`）——见
  `third_party/ddr3_ip_200h/ddr3_test/rtl/mcdq_ctrl/ips2l_mcdq_ui_axi_v1_2a.vp:1-8`：
  ```
  1  `pragma protect begin_protected
  2  `pragma protect version=1
  ...
  7  `pragma protect encrypt_agent="Synplify encryptP1735.pl"
  ```
  ⇒ **`wready` 占空比 / 用户口 FIFO 深度 / 内部仲裁，静态读不出。**

**结论：直连路径是一条"结构上成立、原始上限远过门槛、但可达值须实测"的路。
它不是"打开开关"，而是"加一路 domain-native burst master"。**

---

## 7. 判定（RESULT）

```
RESULT: 静态算不出（列出缺什么）
```
- **桥路径**：静态**已定**——`276 MB/s < 305`。**现架构（每层激活走桥往返 DDR）达不到 10 fps。**
- **直连路径**：**结构存在、原始上限 4000 MB/s（≫458）**；其可达值取决于 IP 内部加密逻辑 ⇒ **静态缺这一项**。

⇒ 对 Y1 计划的直接含义（二选一，均属"架构需变"）：
**(a)** 若要保留"走 DDR"，必须**旁路桥**，新增 domain-native burst master 直挂 IP 用户口（并实测可达带宽）；
**(b)** 或按任务书预案，改为"**更多驻留片上**"（layer fusion / 更深行缓冲），降低对 DDR 带宽的诉求。

---

## 8. 静态分析**算不出来**的清单（需上板量）

1. **IP 用户口 `wready` 占空比 / FIFO 深度 / 内部仲裁**——源码加密（`.vp` / `pragma protect`，见 §6），读不出 ⇒ 直连可达带宽无法静态定。
2. **真实 DRAM 效率**（bank conflict / 行命中率 / 刷新）：时序参数在 `ddr3_test.v` 里可见
   （`DDRC_TFAW=22` `:241`、`DDRC_TRFC=150` `:249`、`DDRC_TREFI=3900` `:247`、`DDRC_TRRD=5` `:255`、
   `DDRC_TWTR=4` `:261`、`DDRC_TRTP=4` `:257`，`DDR3_CL=4'd6` `:142`），但**它们对"本访问模式"的合成效果**不可从 RTL 推导。
3. **读延迟**：`DDR3_CL=6`（`:142`）是**内存总线节拍**，映射到 `core_clk` 拍数由 IP 内部完成（加密）⇒ 静态不可数；
   桥每个 32B 都把这笔延迟**完整暴露**（`DDR3Bridge.scala:463` 等管道空），其绝对值读不出。
4. **混合读写下的排队 / 总线翻转**（tWTR/tRTW 等）：桥因单 outstanding 而读写互斥（不涉及），
   但**直连 master 的混合模式**会涉及 ⇒ 静态不可数。
5. **CDC 穿越的异步不确定性**：每次跨域"识沿"可能 +0~1 拍 ⇒ 桥真值可能 **>116 ns**（§4 给了 8/9 拍的最坏界 = 210.5 MB/s）。
   真值只能测量。
6. **AXI/互联侧争用**：桥的 AXI 从口是 64bit@100MHz（原始 800 MB/s，非瓶颈），但 SoC 里
   `cpuFetch/cpuLsu` 合流 + 装载选通（`YeshenSocGlue.scala:625-674`）在真实负载下的排队未建模。
7. **30.5 MB/帧**这个工作负载假设本身（读写各占多少、是否有复用）未在本 RTL 内体现 ⇒ 未做读写配比分析。

---

## 9. 文件与提交

- 新增：`y1/partA/ddr_path_ceiling.md`（本报告）
- 新增：`y1/partA/ddr_path_ceiling.py`（可用算术复现：`bridge/oneclk/raw` 三模式；输出纯 ASCII）
- 复现命令：`python y1/partA/ddr_path_ceiling.py bridge 6 100e6 7 125e6` → `275.9 MB/s [FAIL <305]`
- 只读引用了 `src/`、`board/`、`constraints/`、`third_party/ddr3_ip_200h/`（**未改动**）。
