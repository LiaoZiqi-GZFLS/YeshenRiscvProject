# Y1 · C2 详细设计：DDR 主口（走既有 `DDR3Bridge`）

- 日期：2026-10-08
- 上游：`docs/superpowers/specs/2026-10-08-yunet-accelerator-small-design.md`（§2.1 的 DDR 预算与推荐调度）
- 实测/静态依据：`y1/partA/ddr_path_ceiling.md`、`y1/reports/ddr_traffic_budget.md`、`y1/reports/GATES_CONCLUSION.md`

---

## 1. 范围与判据

**C2 是什么**：给加速器做出**自己的 DDR 主口**，并证明它能**正确且足够快地**把一层特征搬进/搬出 DDR。

**C2 不是**：不是层调度器（C3）、不是整网（C4）、不是帧率验收（C5）、不是直连主口（C6 已取消）。C2 结束时**加速器能独立地"读一块 DDR → 写回一块 DDR"**，还不做卷积。

**判据（两条，都必须有）**：
1. **字节级往返一致**：从 DDR 读一段到片上、再写回 DDR 的另一段，与**主机的内存镜像逐字节相同**（不是抽查、不是"看着对"）。
2. **吞吐计数器实测（口径必须写清，别混）**：硬件自带**读字节 / 写字节**两个计数器，随遥测寄存器可读。判据用 **traffic 口径**：

   | 口径 | 含义 | 空载判据 |
   |---|---|---|
   | **traffic 速率** | (读字节 + 写字节) / 耗时 | **≥ 248 MB/s**（= 275.9 的 90%） |
   | **有效拷贝速率** | 被拷贝的字节数 / 耗时 | 等价于 **≥ 124 MB/s**（拷贝每份数据要过 2 倍 traffic） |

   **为什么是"打满桥"而不是 137.9**：C2 是**空载**测量（CPU 不活动），此时加速器能拿到**整座桥**（275.9 MB/s traffic）。要证的是"我的主口**能独自把桥打满**"；取 90% 而不是 100%，是因为 275.9 本身就是**静态上界**（假设 CDC 往返 116 ns 且无额外开销），要求 100% 只会脆。

   **50% 份额下的达标（10 fps 档）是另一件事**，属 **C5 的"带真实负载"** 验收项（见 §6.1）—— C2 的空载数字**不能**替代它。

---

## 2. 冻结参数（全部继承自已有结论，不重新论证）

| 项 | 值 | 出处 |
|---|---|---|
| 内存通路形状 | **`AXIIO64`：4 bit id + 64 bit data + 8 bit wstrb** | `src/soc/DDR3Bridge.scala:91` |
| 桥的从口时钟 | `cpu_clk` = **100 MHz** | `constraints/yeshen_mini.fdc:113` |
| 桥的 DDR 侧 | 256 bit @ `core_clk` 125 MHz | `constraints/yeshen_mini.fdc:121` |
| 桥的吞吐上限 | **275.9 MB/s**（116 ns / 32 B） | `y1/partA/ddr_path_ceiling.md` |
| 桥的事务结构 | **单 outstanding**；**每笔 DDR 事务只发 1 个 256-bit beat**；一笔 AXI 突发按 32 B 切成 `ceil((awlen+1)/4)` 笔 | `src/soc/DDR3Bridge.scala` 头注释 + `:146` |
| 桥的读写关系 | **读写互斥**：`awready := wrState === sWrIdle`（**只看写状态机，不看读**） | `src/soc/DDR3Bridge.scala:191` |
| 突发长度上限 | `awlen/arlen` 4 bit ⇒ **最多 16 拍 = 128 B = 4 笔 DDR 事务** | `src/soc/DDR3Bridge.scala:109/118/210` |
| 加速器寄存器窗（建议） | **0xF000_C000**（空闲段见下） | `src/YeshenSocGlue.scala:53-101` 的占用与掩码 |
| 中断源号（建议） | PLIC **源 3**（1=控制台、2=LiteEth） | `src/YeshenSocGlue.scala:88/373` |
| 推荐调度 | `fuse_both` = 12.576 MB/帧 ⇒ 21.94 fps 独占 | `y1/reports/ddr_traffic_budget.md` §C0.3 |

---

## 3. 挂点决策：加速器的 AXI 主口接在哪

**现状（板级装配，`board/yeshen_mini_board_top.v:10/254/297`）**：

```
yeshen_mini_soc.mem_*  (64bit AXI4 主, 4bit id)  ──►  DDR3Bridge.io_axi_*  (64bit 从)
DDR3Bridge.io_ddr*     (256bit 简化 AXI 主)      ──►  u_ddr3 的 axi_* 用户口
```

**关键事实**：`DDR3Bridge` **只有一个从口**，而 `YeshenSocGlue` 里**已经有一个模板**把核的多个内存主口合并成一个（`src/YeshenSocGlue.scala:625` 起，含 §4 模板与 `memRdBusy` 之类的纪律，`:701/:713/:720/:764`）。所以"多主共享这座桥"这件事**在本工程里不是新问题**。

### 方案 A（推荐）：让胶合块**新增一个内存主口输入**，NPU 仍留在板级

> ⚠ **2026-10-08 依据更正**：本节初稿写"NPU 作为第二个 Verilog 黑盒进胶合块，先例是 VexiiRiscv"——**先例举错了**。实际装配层是 `board/yeshen_mini_soc.v`：它**同时例化** `VexiiRiscv`（2 MB 网表）与 `YeshenSocGlue`（131 KB），胶合**不是**装 CPU 的地方；胶合的 `io.mem`（`AXIIO64`）是它**合并完之后**唯一的对外内存主口（`YeshenSocGlue.scala:625` 起把 `cpuFetch/cpuLsu/cpuIo` 三个主口合并）。**实质结论不变，但做法更干净**：

- 给胶合**新增一个内存主口输入**（如 `io.npuMem = Flipped(new VexiiAxi64)`）；
- 把它**并入胶合里已有的那套 merger 模板**（不另写一套），于是 merger 仍是**唯一**做合并的地方；
- **NPU 与 CPU 一样，作为板级 Verilog 网表**例化在 `board/yeshen_mini_soc.v` 里，把它的 AXI 主口接到 `io.npuMem`。
- 由此**自动继承**已经踩过的坑（W 必须与 AW 同门、`a_cmdFork_fire = valid && ready`、单 outstanding 下的握手纪律）。
- 代价：要动 `src/YeshenSocGlue.scala`（**本仓自有文件，不是被参考的仓库**）并重生成 `rtl/YeshenSocGlue.v`；黑盒的端口名/位宽必须与 `VexiiAxi64`/`AXIIO64` 逐条相等。

### 方案 B：在板级加一层二级仲裁（`{glue.mem, npu.mem} → DDR3Bridge`）

- 不动胶合，只在 `board/yeshen_mini_board_top.v` 加一层 AXI 仲裁。
- 代价：**要把 merger 的纪律再实现一遍**（尤其"W 与 AW 同门"这条 —— 只修 `awready` 会出错，见 `:764` 的 ★ 注释）。等于把一份已验证的逻辑复制成两份，两份都会漂移。

**决策：走 A。** 理由是"把问题消灭在结构里"：桥只有一个从口这件事已经被 merger 模板解决过一次，第二次不该换个地方重写。

---

## 4. 协议契约（NPU 主口必须遵守的，逐条有出处）

| # | 契约 | 为什么 | 出处 |
|---|---|---|---|
| P1 | 数据 **64 bit**、id **4 bit**、`wstrb` **8 bit** | 与 `AXIIO64` 逐条相等才能零胶合 | `src/soc/DDR3Bridge.scala:91` |
| P2 | **同时只允许 1 笔在飞**（单 outstanding） | 桥本来就是单 outstanding；多笔在飞没有收益，只会把 merger 复杂度白抬 | 桥头注释约束 3 |
| P3 | **突发必须 32 B 对齐、长度取 4 的倍数拍**（8 拍 = 64 B 或 16 拍 = 128 B） | 桥按 32 B 分组切；不对齐会多切一笔 | `DDR3Bridge.scala:130/146/210` |
| P4 | **W 通道必须与 AW 同门**（不能只等 `awready`） | 桥是 `w.wready := wrState === sWrAgg`；核的 `Axi4Bridge` 判据是 `valid && ready` ⇒ 只修 `awready` 会让主方以为成交却永不重发 | `YeshenSocGlue.scala:764`（★） |
| P5 | **读写不并发**（同一时刻只发一类） | 桥内读写互斥 | `DDR3Bridge.scala:191` |
| P6 | 长突发的收益只在 **merger→桥** 之间（省掉逐笔握手），**不改变桥的 116 ns/32 B** | 桥的瓶颈是 CDC 往返，不是 AXI 握手 | `y1/partA/ddr_path_ceiling.md` |

**P6 的推论（设计上要据此选突发长度）**：既然桥的代价与突发长度**无关**，那就不必为了"少发命令"去追求长突发；**取 16 拍（128 B）**即可，理由是 ① 对齐简单（128 B 对 32 B 整除）、② 行缓冲/行尾的零头少、③ 单 outstanding 下延迟可控。

---

## 5. 地址图与中断

**寄存器窗口**：建议 **`0xF000C000`**。把掩码算进来后的实际占用是（**不能只看基址，要看 `*_MASK`**）：

| 已占 | 范围 | 掩码 |
|---|---|---|
| console | `0xF000_1000–10FF` | `0xFFFF_F000`（4 KB） |
| GPIO | `0xF000_2000–20FF` | `0xFFFF_F000` |
| ETH MAC | `0xF000_3000–30FF` | `0xFFFF_FF00`（256 B） |
| ETH MDIO | `0xF000_4000–40FF` | `0xFFFF_FF00` |
| **ETH BUF** | **`0xF000_8000–BFFF`（16 KB）** | `0xFFFF_C000` |
| ETH DBG | `0xF000_B000–B0FF`（落在 ETH BUF 窗内） | `0xFFFF_FF00` |
| CLINT / PLIC | `0xF001_0000`、`0xF0C0_0000` | 见 `:99/:102` |

⇒ **空闲段只有两段：`0xF000_5000–0x7FFF`（12 KB）与 `0xF000_C000–0xFFFF`（16 KB）**。选 `0xC000` 起的 16 KB：一是够放下 C1 的 13 格表并给以后留位置，二是**避开** ETH BUF 的 16 KB 窗（`0x9000/0xA000` 并**不**空闲 —— 它们在该窗内）。

**中断**：NPU 的 `done`/`err` 合成一条 IRQ → PLIC **源 3**。接线方式与 LiteEth 同法（板级从 NPU 取信号送进 `peripheral_externalInterrupts_port[3]`，见 `src/YeshenSocGlue.scala:88` 的源 2 例子）。

**台账闸门（必须过）**：`scripts/check_addr_map.py` 的 **`EXPECT` 常量表是唯一台账**，另四处（OpenSBI `config.mk`、tb 装载表、DTS、板级顶层）必须与它**逐字相等**，一处不符就非零退出。所以加寄存器窗与 IRQ 源号时，**五处一起改**，并跑这个脚本当闸门（它只做静态文本对账，故意的 —— "写下来的字面量一致"而不是"编译后可能恰好一致"）。

---

## 6. DDR 缓冲与共享带宽（本设计的核心约束）

### 6.1 CPU 也在用这座桥 ⇒ 加速器拿不到全部 275.9 MB/s

按推荐调度 `fuse_both`（12.576 MB/帧）算加速器能容忍多少 CPU 争用：

| 加速器分到的份额 | 可用带宽 | 可达帧率 |
|---|---|---|
| 100%（独占） | 275.9 MB/s | 21.94 fps |
| **50%** | **137.9 MB/s** | **10.97 fps** ✔ 10 fps 档 |
| 68% | 188.6 MB/s | 15.00 fps（15 fps 档的门槛） |
| 30% | 82.8 MB/s | 6.58 fps ✗ |

**⇒ C2 只证"空载能把桥打满"（traffic ≥248 MB/s）。** 真机是 **CPU 争用**下的份额问题： 想要 15 fps 档则必须证明能稳定拿到 ≥68% 的份额 —— 那需要在 C5 用**真实负载**（CPU 同时在跑）测，而不是空载测。

**这条也是为什么 `fuse_both` 值得做**：若退回 `fuse_native`（17.80 MB/帧），50% 份额只有 7.75 fps ⇒ **过不了 10 fps**。所以融合不是优化，是**在 CPU 争用下也能达标**的前提。

### 6.2 缓冲放在 DDR 的哪里（开放项，C2 先用固定区）

C2 是硬件往返测试，可以先用**固定的物理地址段**（例如 SoC 保留区的某个 4 MB 段）。但**最终系统里这块缓冲必须由 Linux 分配并告诉加速器物理地址**（CMA / reserved-memory / 或者干脆把整块 DDR 划出一段不给 Linux）。这在 C2 里**不解决**，只把地址来源做成寄存器（C1 的 `SRC_ADDR`/`DST_ADDR` 已经是 32 位可写），留给 C3/C4 的驱动决定。

---

## 7. 关键落点（改哪里）

**新增（本仓自有，可改）**
- `src/YeshenSocGlue.scala` —— 加 NPU 黑盒 + 把它的内存主口并入既有的 merger；加寄存器窗口解码；加 IRQ 源 3。
- 加速器侧：`y1/rtl/` 下新增 DDR 主口模块（建议 `DdrMaster.scala`，见 §8 的判据）。
- 板级：`board/yeshen_mini_soc.v`（黑盒例化与端口）、`board/yeshen_mini_board_top.v`（若挂点在板级则在此；按方案 A 则不动）。

**台账五处（必须一起改，跑 `check_addr_map.py` 当闸门）**
- `scripts/check_addr_map.py` 的 `EXPECT`
- OpenSBI 的 `config.mk`
- tb 装载表
- `sw/buildroot-external/boards/naxmini/linux/linux_raw.dts`
- 板级顶层

**只读参考（不得修改）**
- `src/soc/DDR3Bridge.scala`、`src/soc/CDCQueue.scala`、`third_party/ddr3_ip_200h/**`
- `y1/rtl/{MacArray,GroupMask,GroupedMacArray,LineBuffer,WeightStore,Conv3x3Slice,HostRegs}.scala`

---

## 8. 验收判据（与判据一起写正负对照）

### J1 字节级往返（主判据）
- **做法**：主机（或 tb）在 DDR 里预置一段**已知且非平凡**的数据（例如 `byte[i] = (i*131 + 7) & 0xFF`，**不能用全 0** —— 全 0 会让"没搬"也通过），加速器把它从 `SRC_ADDR` 搬到 `DST_ADDR`，主机回读**逐字节**比对。
- **判据**：`MISMATCH=0`，且**字节数 ≥ 1 MB**（太小会让"计数器数错"混过去）。
- **负对照**：故意把 `DST_ADDR` 偏 4 字节（或把源数据改一个字节），断言 `MISMATCH` **非 0** 且能定位到第一个不符的偏移。

### J2 吞吐计数器（口径：traffic）
- 硬件内置**读字节 / 写字节**两个计数器（随遥测寄存器可读），另有 `cycles`。
- **判据（空载）**：`(读字节 + 写字节) / 耗时 ≥ 248 MB/s`（= 275.9 的 90%）—— 即**有效拷贝速率 ≥ 124 MB/s**。报出两者与占上限的**百分比**。
- **单时钟仿真下的操作化形式**（⚠ 2026-10-08 修正）：拷一份数据是**非重叠**的"读 + 写"，每个 32 B 组的**地板就是 8 拍**，所以判据落在**主口额外加的拍数**上：
  `cyc_per_group_added = (CYC − LEN/8×2) / (LEN/32) ≤ 2`（@100 MHz），再与桥的 116 ns/32 B **静态合成**得预测 traffic 速率。
- **负对照**：人为把突发切成 1 拍（`awlen=0`）再跑一遍 —— traffic 速率应当**明显下降**（否则说明计数器没在测真东西，或者对桥的瓶颈理解有误）。
- **不属于 J2**：50% 份额下的达标（10 fps 档）—— 那是 **C5 的负载实测**。

### J3 结构/协议判据（防退化）
- 用 `y1/tools/check_dangling.py` + `check_no_xilinx.sh`（既有判据）证明新网表没有悬空与 Xilinx 残留。
- 生成器必须 `headerWithDate=false` **且** `headerWithRepoHash=false`；连跑两次 `md5sum` 一致。
- **"不使用超出桥能力的突发"**：静态检查生成的 AXI 主口里 `awlen/arlen ≤ 15`、且地址低 5 位对齐（与其对应的 32 B 分组）。

### J4 台账判据
- `python scripts/check_addr_map.py` **PASS**（五处逐字相等）。未过则 C2 不算完成。

---

## 9. 风险与开放问题

| # | 风险 / 开放项 | 处置 |
|---|---|---|
| **R1** | **CPU 争用下拿不到 50% 份额**（Linux 访存 + 网络栈 + ssh 都在抢这座单 outstanding 的桥）。C2 的空载数字**不能**证明负载下够 | C2 只证空载 ≥137.9；**负载下的份额必须在 C5 用真实负载测**。若拿不到 50%，退回 `fuse_native` 也过不了 ⇒ 那时才需要考虑 C6（直连主口） |
| **R2** | 单 outstanding 意味着**延迟敏感**：每次 32 B 要等一次 CDC 往返，突发之间无重叠 ⇒ 一旦 merger 的仲裁给了 CPU 优先级，加速器的有效吞吐会掉得很厉害 | 设计上把 NPU 主口的**突发取满 16 拍**（128 B），把"每笔握手"摊薄；并在 merger 里给 NPU **至少不饿死**的仲裁策略（C2 先做最简单的轮转，把"公平性"列成 C3 的验收项） |
| **R3** | 动 `YeshenSocGlue.scala` 会重生成 `rtl/YeshenSocGlue.v`，**整块 SoC 网表都变** ⇒ 既有 SoC 的所有判据都要重跑 | C2 的收尾必须包含"既有 SoC 判据回归"（`scripts/check_addr_map.py` + 板级 devmap/PnR 那条链） |
| **R4** | 黑盒端口名/位宽与 `AXIIO64` 不逐条相等 ⇒ 静默连错 | 例化处逐条列端口（`board/yeshen_mini_board_top.v:374-383` 已是这个写法），并加一条"端口位宽自证"判据 |
| R5 | `fuse_both` 要略掉最大 1.6 MB 的边界，其**数据流缓冲的面积尚未复核** | 属 C3 的验收项（不是 C2）；C2 不碰数据流 |
| R6 | DDR 缓冲的**物理地址来源**（Linux 分配 vs 保留区）未定 | 见 §6.2；C2 用固定区，C3/C4 定策略 |
| — | **开放**：NPU 主口是否需要自己的 id 语义（多 outstanding 时按 id 回填） | 单 outstanding 下不需要；若将来要并发再说 |

---

## 10. 明确不做（C2 边界）

- 不做卷积（C2 只搬数据）。
- 不做层调度/指令（C3）。
- 不碰前/后处理（C4）。
- 不做直连主口（C6 已由 C0 取消）。
- 不上板（上板时机由用户给；C2 的仿真/tb 判据先在离线做完）。
- 不改 `src/soc/DDR3Bridge.scala` 与 DDR3 IP（**它们的纪律是 C2 的输入约束，不是待改对象**）。
