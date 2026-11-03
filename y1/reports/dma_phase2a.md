# Y1-DMA **Phase-2a** 判词 —— **多通道 DMA 引擎**（独立 RTL + 单元闸门；**不入胶合**）

- 日期：2026-10-13
- 上游：`docs/superpowers/specs/2026-10-13-y1-soc-dma-engine-design.md`（§2 家底、§3.1 裁决=C 四相、
  §4 六条裁决项、§5 D1/D2/D6、§6 R2）、
  `docs/superpowers/plans/2026-10-13-y1-soc-dma-engine.md` **Phase 2（T2.1 引擎）**、
  `y1/reports/dma_phase0.md`（Gate-P0=CAN）、`y1/reports/dma_phase1.md` §7（给 Phase-2 的接口单）。
- 交付：`y1/rtl/DmaEngine.scala`（新）、`y1/rtl_test/DmaEngineGen.scala`（新）、
  `y1/rtl_test/DmaEngineTb.v`（新）、`y1/tools/run_dmaeng_ab.sh`（新）、
  `y1/tools/negctl_dmaeng_ab.sh`（新）、`y1/gen/DmaEngine.v`（**生成物，`y1/gen/` 不入库**）。
- 本相**只做引擎这一半**：**没有**碰 `src/`、`rtl/YeshenSocGlue.v`、`board/`、`PlicAlite`、`SdLoader`
  ⇒ **SoC 网表逐字节不变**，本相**不需要 PnR**（PnR 由控制器在 Phase-2b/3 一起跑）。

---

## 0) ★ Gate-P2a 判词（先给结论）

> **成立。** 多通道（**NCH = 2**）DMA 引擎已存在：**AXI-Lite CSR 窗 + 单根 AXI4 主口**
> （28 位地址 / 64 位数据 / 4 位 id，与 `DdrMaster`/`npuMem` 同形），
> **每通道 = 一台独立的 `DdrMaster` 实例**（自己的块缓冲/FSM/流口/CSR/记账），
> 由**事务级轮转仲裁器**共享主口（grant 从命令被接收**持有到 `rlast`/`B`**）。
> §4.1/§4.6 的寄存器形状、32 B 粒度契约、`bytes_moved`/`cycles`/`err_code`/`abort` 全在。
>
> | 判据 | 阳性（本轮实测） | 负对照（必须翻红，实测全红） |
> |---|---|---|
> | **D1 三向 + 背靠背 + 并发，逐字节** | COPY（DDR→DDR）LEN∈{32,96,160,256,512}、RD（DDR→外设缓冲）、WR（外设缓冲→DDR）：dst/stream **逐字节** == 期望，**分块与 AR/AW 地址序列 == Python 独立重算**；背靠背 6 笔整片镜像 **MISMATCH=0**；两通道并发：**同时忙 60 次采样**、AR/AW 地址在窗口间**交错 15 次**、两区各自 **BAD=0** | NC1 突发**短 1 拍** ⇒ 红；NC1b 读突发**多 1 拍** ⇒ 红 |
> | **D2 对账 + 响亮 err** | `bytes_moved` 逐笔 == 期望、`err_code` 在 6 种非法入参下**响亮置位且零搬运**；abort 在**块边界**停下且已搬段逐字节正确 | NC2 **静默收下非法 len** ⇒ 红（err=0、真的搬了 40 字节） |
> | **逐通道记账独立** | 并发时 CH0=1024 / CH1=2048（**各自 == 自己的 LEN**） | NC3 记账**泄漏**到另一通道 ⇒ 红；NC4 逐通道寄存器**读串台** ⇒ 红 |
>
> **代价（网表级，不跑 PDS 的口径）**：`y1/gen/DmaEngine.v` **4 991 行 / 201 608 B**、
> **213 个 `reg` 声明 / 2 090 位 FF**、**2 个模块**（`DmaEngine` + 内联的 `DdrMaster`）、
> **2 个 `DdrMaster` 实例**（每通道一台）。**对 SoC 网表的影响 = 0**（本相不入胶合）。
> **时序未测**（本相无 PnR）⇒ R6 的"每相重跑 PnR"留到 2b/3（命令见 §7）。

---

## 1) 为什么落在 `y1/rtl/`（而不是 plan 里写的 `src/peripheral/`）

三条硬理由（**能不能复用**的问题，不是偏好）：

1. **每个通道的搬运数据通路就是 `DdrMaster` 的实例**，而它是 **SpinalHDL**（`y1/rtl/DdrMaster.scala`）。
   Chisel **无法**实例化 SpinalHDL 组件 ⇒ 引擎必须是 SpinalHDL、必须住在 `y1/rtl/`。
   这正是任务里"prefer generalising this over inventing a new shape"的字面落实：**32 B 粒度契约、
   尾块缩短突发、COPY/RD/WR 三模式、`err` 语义、写侧"先 AW 后 W"纪律**全部**继承**自那个已验收的件。
2. **判据装置也在 y1**：`y1/rtl_test/AxiMemModel.v`（行为级 AXI4 内存模型：逐字节 + 不合规突发
   `$fatal` + `MEM rd/wr/bursts` **独立计数**）与 15 个 `run_*_ab.sh` 全在这套流程里
   （`DdrMaster` 自己的闸门 `run_ddrmaster32_ab.sh` 就在其中）。
3. **2b 的接法本来就是"板级兄弟"**：`NpuTop` 也是 SpinalHDL，胶合块（Chisel）只暴露一根 AXI 主口
   `npuMem`，真 NPU 在 `board/yeshen_mini_soc.v` 里当**兄弟**例化。DMA 引擎同理 ⇒ 引擎**不进**
   `src/`（不进 glue jar），与本相"不入胶合"的范围一致。Phase-1 报告 §7 的接口单也是照这个形状写的。

**闸门也随 y1 惯例**（`y1/tools/run_dmaeng_ab.sh` + `y1/rtl_test/DmaEngineTb.v` + `y1/gen/*.v`，
iverilog + `AxiMemModel.v`），而不是 `sim/dmaeng/`：DUT 是 SpinalHDL ⇒ 网表由 y1 的 sbt 流程产出、
落在 `y1/gen/`；15 个同类闸门都在这套结构里，本闸门与它们**同构**（可一起重跑，见 §6）。

---

## 2) 接口（冻结）：CSR 表 + 通道结构 + NCH

**顶层 IO**：`axilite`（AXI-Lite4 32/32 从口）+ `axi`（AXI4 主口，`ADDR_W=28/DATA_W=64/ID_W=4`）
+ 每通道一份流口 `rd_valid/rd_ready/rd_data`、`wr_valid/wr_ready/wr_data`（RD 推出 / WR 填入）。

**CSR 窗 = 256 B**（`NCH=2`）。每通道 0x40，全局寄存器跟在通道块之后（`G_BASE = NCH*0x40 = 0x80`）：

| 偏移 | 名字 | 访问 | 语义 |
|---|---|---|---|
| `+0x00` | `CH_CTRL` | W/RO 混合 | W: bit0 `start`（**自清单拍**）、bit1 `abort`（**自清单拍**）；R: bit8 `busy`、bit9 `done_sticky` |
| `+0x04` | `CH_STATUS` | RO + w1c | R: bit0 `done_sticky` / bit1 `err_sticky` / bit2 `aborted`；W: bit0..2 write-1-to-clear |
| `+0x08` | `CH_SRC` | RW | 源地址（低 5 位须为 0 ⇒ 32 B 对齐） |
| `+0x0C` | `CH_DST` | RW | 目标地址（同上） |
| `+0x10` | `CH_LEN` | RW | 字节数（须 32 的正整数倍） |
| `+0x14` | `CH_MODE` | RW | bit1:0 = 0 COPY / 1 RD / 2 WR / **3 非法（引擎层响亮拒绝）** |
| `+0x18` | `CH_BYTES` | RO | **`bytes_moved`**（busy 时实时、完成后终值） |
| `+0x1C` | `CH_CYCLES` | RO | **`cycles`**（同口径） |
| `+0x20` | `CH_ERRCODE` | RO | **`err_code`**：1=len 非 32 倍数 / 2=len=0 / 3=src 未对齐 / 4=dst 未对齐 / 5=mode 非法 / 6=已 abort |
| `+0x24` | `CH_ID` | RO | 通道常数 `0x444D4100｜c` |
| `+0x28..0x3C` | 保留 | — | 读 0、写忽略 |
| `0x80+0x00` | `GBL_ID` | RO | `0x59444D41`（"YDMA"） |
| `0x80+0x04` | `GBL_NCH` | RO | 通道数（=2） |
| `0x80+0x08` | `GBL_BUSY` | RO | 忙向量（bit c） |
| `0x80+0x0C` | `GBL_DONE` | RO | `done_sticky` 向量（2b 的 PLIC 源 4 从这里取线或） |
| `0x80+0x10` | `GBL_ERR` | RO | `err_sticky` 向量 |
| `0x80+0x14..` | 保留 | — | — |

**形状口径**（与 `HostRegs.scala` 同款惯用法）：RW 档是**整 32 位存储**；自清单拍写成
"`bus.write` 之后 `when(x){x:=False}`"；RO 档用 `bus.read(纯表达式)`（避免落成敏感表只有常量的
`always @(*)` 而停在 X）；表外地址读 0 / 写忽略。

**每通道结构**：
```
CSR（每通道一份）──┬─→ start 自清 ⇒ 影子寄存器(src/dst/len/mode) ⇒ launch(延后一拍) ⇒ eng.start
                   ├─→ abort 自清 ⇒ 排空 FSM ⇒ 通道 ClockDomain 复位 ⇒ aborted=1 / err_code=6
                   └─→ 记录：done/err/aborted 粘滞 + bytes/cycles/err_code 快照（start 清、w1c 清）
通道 c：ClockDomain(clock = 本域时钟, reset = 系统复位 || chRst(c)) ──→ DdrMaster(dmCfg)
                                                             ↑ 同频不同复位（无 CDC）
仲裁器（类间无关，通道间）：req(c)=arvalid||awvalid 且未被 abort/reset 掩 ⇒ 事务级轮转
                             grant 持有到 rlast（读）/ B（写）⇒ 任一时刻只有一笔事务在飞
```
**`NCH` = 2（选它、不选 1 的理由）**：§4.3 的原裁决"推荐 1 个"是**在 fabric 还是单未完成时**给的；
Phase-0/1 已把承重项（`DDR3Bridge` 多未完成、§3.5 真仲裁）做掉，多通道**已经有意义**，所以本相取
**最小的 >1**：`NCH=2`（参数化 1..4）。取 2 而不是 4：既够证"并发 + 逐通道记账独立"，
又把面积/复杂度控制在最小；`NCH=1` 是退化情形（仲裁器恒选通道 0，逐拍等价于直连）。

**并发的口径（诚实的上限）**：两通道**可以同时在飞**（都 `busy`、`GBL_BUSY` 两位置 1 —— 实测 60 次采样），
授予在**事务边界**交替（实测 24 笔事务里 AR/AW 地址交错 15 次）。**但** grant 是"一笔事务独占"的
⇒ **没有**"读与写同时占用总线"这一档（AR/AW、R/W 重叠计数实测恒 0，闸门把它钉成设计事实）。
再往上（多未完成 + 通道级流水）要 fabric 与 DDR 桥再放开一档，属于另一相。

---

## 3) ★ 开发中实测到的**真坑**（已修；写进 `DmaEngine.scala` 文件头）

**现象**：两通道并发时，**低优先那个通道永远抢不到**，而且它**读完第一块就再也不发 AW**；
高优先通道把整笔跑完，低优先通道的 `busy` 一直挂着不动。

**根因**：第一版仲裁器只把 **`ar/aw/w` 的 `valid`** 按授予 mux，却把 **`ar/aw/w` 的 `ready`
广播给所有通道**。而 `DdrMaster` 的 AR 态**只判 `arready`**（单主人语境下 `arready ⇒ 握手`，
因为 `arvalid` 是它自己举的）：于是**没被选中的通道也会以为自己那笔被收下了** ⇒ 它跳进 R 态、
把**别人的 R 拍**当成自己的数据、状态机跑飞。

**修法**：`ar/aw/w` 的 `ready` 一律按"本拍总线上呈现的是不是它"加门：
`isCmd = anyReq && (selNow === c)`（命令相位；`anyReq` 是必要的——`pickIdx` 在没有请求时会退回
`lastR`，那可能是一个正被 abort/reset 掩掉请求的通道）；`isDat = (selNow === c)`（**W 的呈现不带
`anyReq` 门 ⇒ ready 也不带**，否则写相位的 W 握手会死锁：`DdrMaster` 的 `ready` 只在 R/WB 态举、
`ar/aw` 的 `valid` 在数据相位恒 0 ⇒ `anyReq=0`）。
**这条闸门抓得到**：修之前 JOB 5 直接超时（`MEM rd=2048` 卡住），修之后 `rd=wr=3072` 全对。

---

## 4) abort 的语义（§4.6 的"保守第一版"）—— **在事务边界排空**

`abort` 写 1 ⇒ 该通道**不再被仲裁器授予**（`req` 被掩），并等**当前在飞的那一笔 AXI 事务**落地
（读等 `rlast`、写等 `B`；这一步是**自然排空**，不需要强推，因为 grant 本来就持有到事务完成），
然后**把该通道的 `DdrMaster` 用**它自己的（同频、复位 = 系统复位 || `chRst(c)`）`ClockDomain`
复位 `RST_CYCLES=2` 拍** ⇒ 通道回 IDLE、`busy` 落 0、`aborted=1`、`err_code=6`，
**能立刻接受下一次 `start`**。

- **为什么必须"先排空再复位"**：若在读突发**中途**把 `DdrMaster` 复位，它的 `r.ready` 会在 `rvalid`
  还在的拍落 0 ⇒ 内存停在中途、残留拍随后被**下一次**搬运当成自己的数据（静默搬错）。
- **实测**：4 KiB 搬运跑到第 300 拍 abort ⇒ `BYTES=1024`（**128 的整数倍** ⇒ 在块边界停下）、
  `CYCLES=314`、`STAT=0x4`（只有 `aborted`）、`busy=0`；**已搬出的那 1024 B 逐字节 == 源区**；
  随后**同一通道**再跑一笔 128 B **正常完成**（`BYTES=128`）⇒ 中止后通道可用、无残留拍串台。
  内存模型交叉对账：`wr = 1024+128 = 1152` 精确；`rd ∈ {wr, wr+128}`（中止点可能正好落在
  "读完了但还没写出去"之间 ⇒ rd 可比 wr 多**一个块**，这条口径写在闸门里）。

---

## 5) 描述符环（§4.1 的可选升级 / §3.1 的 "B 形态"）—— **本相明确不做**

**不做，也不装作做了。** 理由（三条，都不是"没时间"）：

1. spec §3 的推荐是**先 A、把 B 写成升级路径**；§3.1 的裁决把**承重项**（DDR 桥多未完成 + §3.5 真仲裁）
   排在最前 —— 那两件 Phase-0/1 已完成；到本相为止，引擎的程序模型仍是 §4.1 的
   "**A 的 CSR 形状 + 留接口的链指针**"。
2. 环自带一套**所有权/一致性纪律**（`{src,dst,len,flags,next}`、完成位、中断、与 NPU 的
   `LayerSched`/描述符纪律分清），且需要 `DescFetch` 式的 **DDR 取表通路** ⇒ 那是**下一个独立档**，
   塞进本相会把"引擎这一半"变成两个交付。
3. **本相的 CSR-only 通路是一条完整、可判的交付**：D1 三向 + 背靠背逐字节、D2 对账 + 响亮 err、
   5 条负对照全红。**接口已留口**：`CH_MODE` 之上还有 2 bit 未用、`CH_CTRL` 的 bit2..7 未用
   ⇒ 环的"链模式 / 链指针"可以落在那里而不动既有字段；`GBL_*` 里也可加"链游标"。

---

## 6) 判据（先红后绿；正负对照逐条）

### 6.1 单元闸门 `y1/tools/run_dmaeng_ab.sh`（7 个作业）

```
---- JOB 0：COPY（DDR→DDR）LEN ∈ {32,96,160,256,512} ----
  COPY LEN=512 DST_EQ_SRC_BAD=0 SRC_UNCHANGED_BAD=0 OTHERS_BAD=0 ; AR/AW 序列 == 独立重算
  MEM rd=512 wr=512 bursts=8   COPY LEN=512 CH0 BYTES=512 CYCLES=149
JOB 0 PASS：三向之一（COPY）多块/尾块逐字节正确
---- JOB 1：RD（DDR→外设缓冲）LEN ∈ {32,96,160} ----
  RD LEN=160 STREAM_vs_SRC_BAD=0 ; MEM_UNTOUCHED_BAD=0 ; AR 2 笔 / AW 0 笔 ; MEM rd=160 wr=0
---- JOB 2：WR（外设缓冲→DDR）LEN ∈ {32,96,160} ----
  WR LEN=160 DST_vs_FED_BAD=0 OTHERS_BAD=0 ; AW 2 笔 / AR 0 笔 ; MEM rd=0 wr=160
---- JOB 3：非法入参 ×6 ----
  ERR[len40] / [len48] / [lenzero] / [srcaln] / [dstaln] / [modebad]  6/6 PASS（err=1、done=0、BYTES=0、CODE 对、零搬运）
---- JOB 4：背靠背 N=6 笔（LEN 32/64/96/128/160/192 轮换）----
  B2B 整片镜像 MISMATCH=0 FIRST=-1（65536 B）   B2B 计数 AR=8 AW=8 B=8
---- JOB 5：两通道并发 ----
  CONC CH0 区逐字节 BAD=0 / CH1 区 BAD=0
  CONC AR 交错=15 次（0=8 笔 1=16 笔）  CONC AW 交错=15 次（0=8 笔 1=16 笔）
  CONC BOTH_BUSY_SAMPLES=60   CONC CH0 BYTES=1024(期望 1024) CH1 BYTES=2048(期望 2048)
  MEM rd=3072 wr=3072 bursts=48
---- JOB 6：abort ----
  ABORT STAT=00000004 BYTES=1024 CYCLES=314 CODE=6
  ABORT 已搬段逐字节 BAD=0（1024 B）  ABORT 再跑一笔 DST+32768 逐字节 BAD=0
  ABORT MEM rd=1280 wr=1152（期望 wr=1024+128=1152，rd ∈ {wr, wr+128}）
==================== 汇总 ====================
D1 = PASS（三向 + 背靠背 + 并发，全部逐字节）
D2 = PASS（bytes_moved 对账 + 非法入参响亮 err 且零搬运 + abort 在块边界）
RESULT: PASS
```

**判据的"独立重算"**：AR/AW 的地址与 `len` 域序列由 Python 按 `beats = min(16, remain/8)`
**独立重算**后逐笔比（`SEQ_OK`）；内存模型的 `MEM rd/wr/bursts` 与装置自报计数**两处独立计数**一起对；
逐字节对账全部是"**逐元素**"，不是校验和。

**装置自身的结构性断言**（运行期计数，全 0）：`RBEAT_BAD`（每笔读突发拍数 == AR 声明、末拍恰一个
`rlast`）、`WLAST_BAD`/`WBURST_BAD`（同上写侧）、`ORPHAN_W`（没有"无 AW 的 W"）、
`RDWR_OVERLAP`/`ARAW_OVERLAP`（**恒 0**，= 仲裁器"一笔事务独占"这条设计事实的运行期版本）、
`MODE_LEAK_BAD`/`STREAM_IDLE_BAD`（RD 不发 AW/W、WR 不发 AR/R、COPY 流口静默）。

### 6.2 负对照 `y1/tools/negctl_dmaeng_ab.sh`（**5 条全部发火**，单行源码变异 + 重生成 + 重跑闸门）

| NC | 打法 | 实测结果 |
|---|---|---|
| **NC1 突发短 1 拍** | `DdrMaster.beatsM1For` 满块 `U(15,4)` → `U(14,4)` | 闸门红：COPY LEN≥160 / RD LEN=160 逐字节判据翻红（分块与地址递进随之错位） |
| **NC1b 读突发多 1 拍** | AR 的 `len` 由 `beatsM1` → `beatsM1+1` | 闸门红：声明的突发变 17 拍（>16）⇒ 内存模型**响亮 $fatal**（13 处证据） |
| **NC2 静默收下非法 len** | `DdrMaster`: `val lenOk = ((io.len % 32) === 0) && (io.len =/= 0)` → `True` | 闸门红：`TBFAIL: 非法入参没有 err` + `竟然 done` + `搬了 40 字节`（**这就是 D2 的核心条款**） |
| **NC3 记账泄漏进另一通道** | `bytesR(c) := liveBytes` → `liveBytes + bytesR(1-c)` | 闸门红：JOB 5 `CH1 BYTES=3072 != 2048` |
| **NC4 逐通道寄存器读串台** | `CH_BYTES` 读口 `bytesR(c)` → `bytesR(0)` | 闸门红：JOB 5 `CH1 BYTES=1024 != 2048` |
| **比较器自检** | 扰动一个期望字节 | `SELFTEST MISMATCH=1 FIRST=1234`（**恰好 1** ⇒ 逐字节比较器不是橡皮图章） |

每条跑完都**恢复源码 + 重新生成**并核对 **md5 与基线逐字节一致**（`RESTORED ok`）；
基线：`DdrMaster.scala=1b4d1358a040d4acfd7d7aedf0837a75`、`DmaEngine.scala=32ce7a75b9ea0d48d6a32a721c8caad7`。

★ 负对照脚本自己**也抓到过一个闸门 bug**：`run_dmaeng_ab.sh` 的 JOB 4/5/6 原先写成
`if run ...; then if ! judge ...`，于是**装置未 PASS 时失败被吞掉**（NC3/NC4 第一次跑出
"闸门全绿"就是这么假出来的）⇒ 已改成"装置失败也计入 `fails`"。**判据自己先被负对照审过一遍。**

---

## 7) 回归 + 记账

### 7.1 15 个单元闸门 + 台账 + dangling（实跑，git-bash）

```
run_ddrmaster32_ab=0 run_desc_ab=0      run_fusionbuf_ab=0 run_bypass_ab=0   run_unitexec_ab=0
run_fuse_head_ab=0  run_fuse_ab=0       run_chain_ab=0      run_sched_ab=0    run_nputop_ab=0
run_nputop_sched_ab=0 run_hostregs_ab=0 run_ddrcopy_ab=0    run_ddrread_ab=0  run_ddrwrite_ab=0
+ run_dmaeng_ab=0（本相新增，第 16 个）
```
```
python scripts/check_addr_map.py   -> PASS: address ledger consistent (16 sites reconciled)  rc=0
python y1/tools/check_dangling.py y1/gen/DmaEngine.v
    -> defined modules: 2 | distinct instantiated: 1 | total dangling instances: 0 | RESULT: PASS
python y1/tools/check_dangling.py rtl/YeshenSocGlue.v  -> dangling 0 | RESULT: PASS
python y1/tools/check_dangling.py y1/gen/NpuTop.v      -> dangling 0 | RESULT: PASS
```
**台账站点数仍 16** —— 本相**没有**动地址窗/`EXPECT`/`check()`（引擎没入胶合、没占窗、没接中断）。
**`run_ddrmaster32_ab.sh` 全绿**：`DdrMaster.scala` 一字未改（md5 与 HEAD 一致、`git diff` 空）
⇒ 继承来的 32 B 粒度/RD-WR 语义**逐字节未动**。

### 7.2 面积（**网表级**口径，− PDS）

| 口径 | `y1/gen/DmaEngine.v` |
|---|---|
| 行 / 字节 | 4 991 / 201 608 |
| `reg` 声明数 | 213 |
| **FF 位宽合计** | **2 090** |
| 模块数 | 2（`DmaEngine` + 内联 `DdrMaster`） |
| `DdrMaster` 实例数 | 2（每通道一台；各含 128 B 块缓冲 = 1 024 位） |

- FF 主体就是**两台 `DdrMaster` 的块缓冲**（2 × 1 024 位 = 2 048 位）+ 两台 FSM/指针 + CSR + 仲裁器
  （`sel(1)+last(1)+inFlight(1)`）；折成器件占比 ≈ **2 090 / 319 600 ≈ 0.65% FF**（板级现用 113 382 FF = 36%）。
- **板级紧资源是 CLMA/CLMS**（C3/C4b 在 ~90–91%）；本相的增项是**寄存器 + 窄 mux + 一块 128:1 的
  8bit 读 mux ×2 通道**（块缓冲的 `wData`/`rdData`），**未测**对 CLMS 的影响。
- **SoC 网表 `rtl/YeshenSocGlue.v` 逐字节未动** ⇒ 本相**不改变**既有的 PnR 结果（无需重跑）。
  **待跑的 PnR**（等 2b 把引擎接进胶合、或要单测引擎时序时）：
  ```bash
  # 工作目录 = D:/code/PDS/VexiiYeshenLinux
  /c/Pango/PDS_2025.2-ads/bin/pds_shell.exe -file y1/pds/pnr_c4a.tcl   > y1/pds/pnr_dma_p2a.log 2>&1 ; echo "exit=$?"
  /c/Pango/PDS_2025.2-ads/bin/pds_shell.exe -file y1/pds/devmap_c4a.tcl > y1/pds/devmap_dma_p2a.log 2>&1 ; echo "exit=$?"
  # 判据：report_timing 的 "All Constraints Met" + 结束标记 YESHENMINI_PNR_C4A_DONE + Device Utilization Δ
  ```

---

## 8) 能证 / 不能证

**能证（本轮实测）**
1. 引擎的三向搬运（COPY / RD / WR）**逐字节**正确，含**多块 + 尾块**、背靠背 6 笔。
2. `bytes_moved` 与内存模型 `rd/wr/bursts`**两处独立计数**对得上；AR/AW 地址与长度域
   == Python 独立重算的分块。
3. **非法入参响亮 err 且零搬运**（len 非 32 倍数 / len=0 / src 未对齐 / dst 未对齐 / mode=3），
   `err_code` 逐项可辨。
4. **多通道并发**：两通道同时在飞（`GBL_BUSY` 两位置 1 采样 60 次）、授予在事务边界交替
   （地址交错 15 次）、**逐通道记账独立**（各自的 `bytes_moved` == 自己的 LEN）。
5. **abort** 在**块边界**停下、已搬段逐字节正确、中止后同通道可立刻再跑一笔且结果正确。
6. **每条判据都能翻红**（5 条负对照 + 比较器自检，全部按期望红）；**判据自己也被负对照审过**
   （§6.2 末尾的 `run_dmaeng_ab.sh` 记账 bug）。
7. 既有 15 闸门 + 台账（16 站点）+ dangling 全绿；**`DdrMaster.scala` 一字未改**。

**不能证 / 有条件**
1. **时序/器件面积未测**（本相无 PnR）⇒ R6 **未关闭**（§7.2 给了命令）。
2. **没入胶合**：本引擎**不参与** SoC 的地址译码/PLIC/RGMII；`GBL_DONE/GBL_ERR` 只是给 2b 留的线或口，
   **中断还没接**（D5 未做，留给 2b）。
3. **"并发"是事务级的，不是带宽级的**：grant 一笔事务独占 ⇒ 没有"读写同拍"，也没有通道级流水；
   真提速要 fabric/DDR 桥再放开一档（另一相）。
4. **不是真 IP/真板**：内存模型是行为模型（1 拍读延迟 + INCR）；真 `DDR3Bridge`/真 DDR 上未验。
5. **`abort` 的粒度是"块"**（128 B）不是"拍"：这是**有意**的（中途复位会把别人的 R 拍串进来），
   口径写在 §4；若将来要"下一拍就停"，要改 `DdrMaster` 的 FSM（本相不碰它）。
6. **环（描述符链）未做**（§5 明确）。

---

## 9) Phase-2b 必须接的线（本节的每一条都可直接动手）

1. **胶合层加第 6 个主人**（`src/YeshenSocGlue.scala` §3.5）：Phase-1 报告 §7 的接口单**照样成立** ——
   `dmaPend := dmaAwValid || dmaArValid`、DMA 分支**照抄 NPU 分支**（含 **28→32 位零扩展**与 **id 丢弃**）、
   `OWN_DMA_RD/WR`（6/7）**已预留**、`MemArbiter` **一字不改**。本引擎的 AXI 口形状（28/64/4）
   与 `npuMem` 同款 ⇒ 该子句**逐字可照抄**。
2. **地址窗 + 台账五件套**：给引擎 CSR 窗一个 SoC 地址（**256 B**：通道 2×0x40 + 全局 0x80..0x93）
   ⇒ `scripts/check_addr_map.py` 的 `EXPECT` + 各 `check()` 站点 + `YeshenMap` + DTS ⇒ **站点数 +1**。
3. **中断（D5）**：`PlicAlite.NDEV 3→4`（源 4），中断源 = `GBL_DONE`/`GBL_ERR` 的线或
   （CSR 里已备好向量；`CH_STATUS` 的 w1c 就是清中断的落点）。
4. **第一个真客户：SD 装载器（D3）**：`src/peripheral/SdLoader.scala` **已经是 AXI4 写主口**
   （32 B 突发）⇒ 改成"喂引擎"：把它的 `awaddr/wdata/...` 换成写引擎 CSR（`SRC/DST/LEN/MODE=2` + `start`）
   并把字节流接到**本引擎的 `wr_valid/wr_data`**（`io.wr_valid_c`/`io.wr_data_c` 已经预留）⇒
   **同一镜像的装载结果必须逐字节相同**（D3 的判据）。
5. **网络**（rx 槽→DDR / DDR→tx 槽）与**相机留口**：同一套 CSR + 流口，按 §4.4 的顺序推。
6. **板级例化**：像 `NpuTop` 那样在 `board/yeshen_mini_soc.v` 里把 `DmaEngine` 当**兄弟**接上胶合的
   DMA 主口（本引擎**不进** glue jar）。
7. **§4 的 `memSel` 一热 mux（`YeshenSocGlue.scala:1040-1078`）**：Phase-1 报告 §5.4 说它是"下一个改造点"。
   **本相仍没动它**；2b 若把引擎接在最终主口（而不是 §3.5），这里要用**同一个 `MemArbiter`**
   （类 = {CPU 组, 装载器, DMA}）替换 `Mux(memSel, …)`，并把装载器的直连 ready/bvalid 按 ownership 加门。
8. **本引擎可以原样复用**：`NCH` 参数化（1..4），`DLen`/`ADDR_W` 等都在 `DmaEngineConfig` 里；
   加通道 = 改 `NCH`，CSR 表与流口自动展开。

---

## 10) 改动面 + 指纹（`md5sum`）

| 文件 | md5 | 说明 |
|---|---|---|
| `y1/rtl/DmaEngine.scala` | `32ce7a75b9ea0d48d6a32a721c8caad7` | **新增**：多通道引擎（CSR + 仲裁器 + N×`DdrMaster` + abort 排空/复位） |
| `y1/rtl_test/DmaEngineGen.scala` | `61d2af35ac87a60a80d1b2b655cddfb4` | **新增**：网表生成（SYNC 复位、两个 header 开关 false） |
| `y1/rtl_test/DmaEngineTb.v` | `57255fc4ab405840a0772f1ca8b19a67` | **新增**：单元装置（AXI-Lite 主机 + AxiMemModel + 7 作业 + 结构性断言） |
| `y1/tools/run_dmaeng_ab.sh` | `f6b1460d9b74e6baec9a719d2c897ffa` | **新增**：D1/D2 判据闸门 |
| `y1/tools/negctl_dmaeng_ab.sh` | `b75eb1f4d5690975b85802095d2a45a8` | **新增**：5 条负对照 + 比较器自检 + 源码恢复核对 |
| `y1/gen/DmaEngine.v` | `36bcb9c6d848cfac66f87eae52f71ed8` | 生成物（`y1/gen/` 在 `.gitignore` 里，**不入库**；此 md5 是负对照跑完恢复后的值） |

- **只读纪律**：`third_party/**`（含 PDS 的 DDR3 IP）与冻结 Python 工具
  （`ddr_traffic.py`/`fusion_buffer.py`/`bypass_traffic.py`/`mac_ref.py`/`bypass_ref.py`/
  `conv_unit_ref.py`/`desc_table.py`）**一字未动**。
- `src/**`、`rtl/**`、`board/**`、`constraints/**`、`scripts/check_addr_map.py`、
  `y1/rtl/DdrMaster.scala`、`y1/gen/{NpuTop,DdrMaster,...}.v` **一字未动**
  （`DdrMaster.scala` 的 md5 与 HEAD 逐字节相同；台账站点数仍 16）。
- 本相的 4 个新文件是**纯新增**，不触碰任何既有件的语义。
