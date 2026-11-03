# 小 spec：**通用 SoC DMA 引擎**（DDR ↔ 外设块搬运）

- 日期：2026-10-13
- 上游：`docs/superpowers/specs/2026-10-08-y1-c2-ddr-master-design.md`（`DdrMaster`）、
  `docs/superpowers/specs/2026-10-11-y1-npu-clock-domain-design.md`（多时钟）
- 动因（用户提议）：把"宿主↔板投递靠 ssh+`ddmem` 绕路 / `SdLoader` 自带一套 master / 网络 PIO 占 CPU"
  这三套各自为政的搬运**收敛成一个引擎**，供 TF 装载器 / 未来相机 / 网络共用；目标"可靠 + 快"。
- 状态：**待审阅**（§4 待裁决项给了推荐值）

## 1. 目标与范围

**做什么**：一个 **DMA 引擎**：CPU 编程（CSR 或 DDR 里的描述符链）⇒ 引擎在 DDR 与外设缓冲之间搬块；
带 done/err/完成中断、可中止、可对账（搬了多少字节）。

**不是什么**：不做 AXI 交叉开关（fabric 形状由 §3 决定）；不做网络协议栈改造（那是另一条线，本 spec 不碰）；
不做相机（Y5）——但引擎要为它留口。

## 2. 现状（实测事实，带出处）

| 项 | 现状 | 出处 |
|---|---|---|
| 互联 | **不是 AXI 交叉开关**：胶合块里是"解码 + **单未完成** owner FSM"；主口 = `cpuFetch/cpuLsu/cpuIo/npuMem/sdLoader+uartLoader` | `src/YeshenSocGlue.scala:306-308,331,396-399,744-871,772-778` |
| 合并点 §3.5 | 3-bit `owner`、**一次一笔**（`rlast`/`b` 释放）、CPU 组 vs NPU 轮转 | `:744-871` |
| 下游 | `DDR3Bridge` **也是单未完成**（id4/data64） | `src/soc/DDR3Bridge.scala:91-97,181-196,252-258` |
| 现有 DMA 味的东西 | `DdrMaster`（CSR 驱动：`start/src/dst/len/mode`；`ADDR_W=28/DATA_W=64/ID_W=4`；**32 B 粒度** `len%32==0`）；COPY/RD/WR 三模式 + rd/wr 流 | `y1/rtl/DdrMaster.scala:32-52,195-219`；`y1/rtl/HostRegs.scala:177-178` |
| TF 装载器 | **已经是 AXI4 写主口**（32 B 突发、一次一笔）—— 天生的 DMA 客户 | `src/peripheral/SdLoader.scala:52-65,71-79,94-176` |
| 网络 | **纯 PIO/SRAM 槽窗**（4×0x800 rx + 2×0x800 tx），**无 DMA** | `board/liteeth_wrap.v:20-24,24,265-266` |
| 主口并入 | 新主口要并到 `memSel`——**现在是一热 mux，代码注释自己说"该换成真仲裁"** | `YeshenSocGlue.scala:1040-1078`（`:1041-1047` 注释） |
| 中断 | PLIC `NDEV=3`（1 控制台 / 2 eth / 3 NPU）；`claimCand` 3-bit（≤7 源） | `src/peripheral/PlicAlite.scala:68,95-99,157` |
| 台账 | `check_addr_map.py` `EXPECT` + **16 个 `check()` 站点**（OpenSBI/TB/glue/DTS） | `scripts/check_addr_map.py:49-65,104-151` |
| 时钟 | `cpu_clk`100M（胶合/CPU/DDR-AXI）/`core_clk`125M（DDR）/`npu_clk`50M（第二 GPLL）；**胶合块内无 CDC**，NPU 三接口在板级 Verilog 桥里跨 | `board/yeshen_mini_board_top.v:6,9,65-79`；`board/yeshen_mini_soc.v:844-976` |

## 3. 三条路（含推荐）

| 方案 | 内容 | 取舍 |
|---|---|---|
| **(A) CSR 驱动的单块引擎（推荐起步）** | 引擎 = 一个 **AXI4 主口**（`cpu_clk`）+ 一个 AXI-Lite CSR 窗；寄存器形状**沿用 `DdrMaster`**（`src/dst/len/mode/done/err/bytes`）+ 完成中断。三客户（SD/网络/相机）统一**指向引擎的 src/dst**，而不是各自出主口。 | 与现状同构 ⇒ **单未完成下也能立刻用**；把"三套搬运"收敛成一套；**速度上限 = fabric**（32 B 单未完成），但 CPU 彻底卸载、不再碰 `/dev/mem` |
| (B) 描述符链引擎（DDR 里的环） | 引擎读 DDR 里的描述符环（`{src,dst,len,flags,next}`），链式执行 + 完成位 + 中断；工程上是"工业级"那一套 | 真工业级的排队/耦合，但**在单未完成 fabric 上拿不到并发收益**；且需要环所有权/一致性规矩（与 NPU 的 `DdrMaster`/描述符纪律要分清） |
| (C) A + **§3.5 换真仲裁** + 多通道 | 先把 `memSel` 一热 mux 换成真仲裁、`DDR3Bridge` 放开多未完成，再谈多通道并行 | 才可能真正提速，但**动到已验收的互联与 DDR 桥**，回归面最大；且"多未完成"要 DDR IP 配合 |

**推荐：先 (A)，把升级路径写成 (B)**。理由：现状 fabric **单未完成**，B/C 的并发/链式在这块布线上换不来速度；
A 就能解决"可靠 + 统一 + 卸载 CPU"三件事，且不动已验收的互联。**C 留到"真的需要并发"时**（并在那时把它当独立项目做）。

### 3.1 ★ 已裁决（2026-10-13，用户）：**直接做 C** —— 并附 C 的承重前提（Phase-0）

**用户裁决：直接做 C**（A + §3.5 真仲裁 + 多通道）。据此，计划的**第一步不是 DMA，而是把 DDR 侧的"单未完成/单 beat"放开** ——
因为它是 C 全部收益的**承重环**：

- **实测约束（`src/soc/DDR3Bridge.scala`）**：`:50` 白纸黑字 **"单 outstanding 事务"**；`:41-47` 说明它把一笔 AXI 突发拆成
  `ceil((awlen+1)/4)` 笔**单 beat** DDR 事务 —— 原因是 **DDR 侧 W 通道没有 `wvalid`/`wready`**（wready 高即采样 ⇒
  数据必须始终有效）**且跨域是电平式 `CDCPipe`**（四相往返 ≥4 个 dClk，无法保证背靠背）。`:36-37,51-58` 还记着由此踩过的两个真坑。
- **⇒ Phase-0（承重前提）**：给 `DDR3Bridge` 加**每通道 FIFO**（把"电平握手一次一份"换成"FIFO 攒拍 + 独立发单 beat"），
  使 **AW/W/AR/R 各能多未完成**；这动的是 **C3 已验收**的件（自带单元闸门 `sim/ddr3bridge/` + NC3 负对照）⇒ **必须先回归它**。
- **若 Phase-0 达不到**（DDR IP 的简化口不允许，或 CDC 原语撑不住）：**C 的速度收益不成立** —— 那时要么停在 A（DMA 引擎 + 卸 CPU，
  但速度上限=fabric），要么改 DDR IP 接入方式（更大的项目）。**这条要 Phase-0 用实测判**，不许推断。
- 顺序：**Phase-0（DDR 桥放开）→ Phase-1（§3.5 真仲裁 + `owner` 位宽）→ Phase-2（多通道 DMA 引擎 + 客户端接入）→ Phase-3（收口/回归/上板）**。

## 4. 待裁决项（给了推荐值）

1. **编程模型**：推荐 **A 的 CSR 形状 + 一个"链指针"寄存器**（单描述符 vs 环，先单块，环留接口）。
2. **主口归属域**：推荐 **`cpu_clk`**（到 DDR 无 CDC）；相机等异域客户端在**合并点之前**过 `NpuMemCdc` 式的桥（§2）。
3. **通道数**：推荐 **1 个**（串行）；多通道 = C。
4. **客户端接入顺序**：推荐 **先 SD 装载器**（它已经是 master，最容易改成"喂引擎"）、**再网络**（rx 槽→DDR / DDR→tx 槽）、**后相机**。
5. **完成通知**：推荐**一个 PLIC 源（源 4）+ CSR 的 done/err stub**（NDEV 3→4）。
6. **可靠性要素**：推荐 CSSR 里带 **`bytes_moved` / `cycles` / `err_code`** 可对账（沿用 `DdrMaster` 的自报口），+ **abort**。

## 5. 判据（D1–D6，每条都要**正负对照**）

- **D1（单块搬运正确）**：DDR→DDR、DDR→外设缓冲、外设缓冲→DDR 三向各跑**背靠背** N 笔，**逐字节对**；负对照：掐短/多搬 1 拍 ⇒ 必红。
- **D2（对账）**：`bytes_moved` == 期望；`err_code` 在非法地址/长度（非 32 B 对齐等）时**响亮置位**；负对照：给个不对齐的 `len` ⇒ 必红。
- **D3（客户端等价）**：**SD 装载器改走引擎后**，同一镜像的装载结果与现在**逐字节相同**（这是第一个真客户）；负对照：绕开引擎直连 ⇒ 结果应相同（证明没偷改）。
- **D4（不破坏既有互联）**：15 个单元闸门 + 台账（`check_addr_map.py`，站点数 +1）+ dangling 全绿；**PnR 全角 MET**；面积 Δ 记账。
- **D5（中断）**：完成中断在 PLIC 源 4 上可见、`claim/complete` 正确；负对照：屏蔽源 ⇒ 中断不到。
- **D6（速度口径）**：给出"同样 1 MB 搬运"的 **CPU 占用 / 墙上时间**（引擎 vs 现状 ssh+`ddmem` / vs 逐字 `devmem`），**声明这是下限/上限口径**。

## 6. 风险

| # | 风险 | 处置 |
|---|---|---|
| R1 | **C 动到已验收的互联 + DDR 桥**（C3 上板过的件） | Phase-0/1 各自**先回归原闸门**（`sim/ddr3bridge/` + 台账 + dangling），再谈新功能；**每相都重跑 PnR** |
| R2 | 与 NPU 的 `DdrMaster` 争用同一端口 ⇒ 互相拖慢 | 仲裁要给**优先级/配额**；D6 量"NPU 帧 + DMA 同时"的退化 |
| R3 | 多时钟客户端的 CDC | 客户端在合并点**之前**过 `NpuMemCdc` 式桥；跨域多未完成要另行设计 |
| R4 | 台账/地址窗/DTS 漂移 | 每加一处按 §2 的清单同步（`EXPECT` + `check()` + `YeshenMap` + DTS） |
| R5 | **C 的速度收益不成立**（DDR 侧放不开） | **Phase-0 用实测判**（§3.1）；判不出来就退回 A 的口径，不硬推 |
| R6 | DDR 桥放开后**时序/面积**恶化（C3 CLMA ~91% 满） | 每相 `dev_map` + PnR 记账；超预算则回退该相的激进档 |

## 7. 边界与依赖

- 不做：网络协议栈改造（另一条线）；AXI 交叉开关；相机 RTL（Y5）。
- 依赖：`DdrMaster` 的接口形状（复用）、`SdLoader` 的改写口、PLIC 的 `NDEV`、台账五件套、多时钟桥。
- **与 Y1 的关系**：本 spec **不阻塞 Y1 整帧**（整帧堵在"用真几何重生成网表 + PnR + 重烧"）；本引擎是**产品级基础设施**，
  按独立项目推进；第一个真客户是 SD 装载器。
