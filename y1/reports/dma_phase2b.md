# Y1-DMA **Phase-2b** 判词 —— **把 DMA 引擎接进 SoC**（胶合 §3.5 第 6 个主人 + CSR 窗 + PLIC 源 4 + 板级兄弟 + 台账 17 站）

- 日期：2026-10-13
- 上游：`docs/superpowers/specs/2026-10-13-y1-soc-dma-engine-design.md`、
  `docs/superpowers/plans/2026-10-13-y1-soc-dma-engine.md` **Phase 2（T2.2 并入）**、
  `y1/reports/dma_phase0.md`（Gate-P0）、`dma_phase1.md` §7（接口单）、
  `dma_phase2a.md` §9（**Phase-2b 必须接的线** —— 本报告逐条销账）。
- 本相**只做"并入"**：**没有**碰 `y1/rtl/DmaEngine.scala`（引擎一字未改）、**没有**做描述符环、
  **没有**把 `memSel` 一热选通改造成 `MemArbiter`（§8 有书面裁决）。**没跑 PDS/PnR**（命令见 §12）。

---

## 0) ★ Gate-P2b 判词（先给结论）

> **成立。** 引擎已**真正并入** SoC：CPU/装置在 `0xF000_6000`（256 B 窗）写 CSR 就能**发一笔真实搬运**，
> 经 glue 的 **§3.5 第 6 个主人**（真 `MemArbiter` 类 2 = DMA）拿到总线打到 `io.mem`，完成后
> `GBL_DONE|GBL_ERR` 线或 ⇒ glue `io.dmaIrq` ⇒ **PLIC 源 4**。四件承重件全部落地：
> **① 胶合 §3.5 第 6 个主人**、**② CSR 窗 + 台账**、**③ PLIC 源 4（NDEV 3→4）**、**④ 板级兄弟例化 + PDS 源单**。
>
> | 判据 | 阳性（本轮实测） | 负对照（必须翻红，实测全红） |
> |---|---|---|
> | **胶合层 DMA 作业（逐字节 + 通路 + 中断）** | `sim/glue_pbus/run_dma_pbus_unit.sh` **TEST PASSED**：COPY 逐字节、`io_mem` 上有真实 AR/AW/W 流量、`GBL_ID==0x59444D41`、完成后 `dmaIrq==1` 且 w1c 清源 | `negctl_dma_pbus.sh` **两条全红**：**NC_DMA1**（窗基址打歪 ⇒ CSR 不可达）、**NC_DMA2**（`dmaPend` 钉 0 ⇒ 引擎拿不到总线） |
> | **台账** | `scripts/check_addr_map.py` → **PASS（17 sites reconciled）**（16→17，DMA 记 **1 个 site**） | 台账四处承载者任一漂移即红（见 §6） |
> | **既有回归** | 15 个 `y1/tools/run_*_ab.sh` + `run_dmaeng_ab.sh` **16/16 rc=0**；`sim/glue_pbus/{pBus,NPU,memmerge}`、`sim/memarb`、`sim/ddr3bridge` 全 **TEST PASSED**；dangling 全 **0** | — |
> | **守卫可证伪** | `memSel` 守卫在真实网表上被强制触发 ⇒ **响亮 `$fatal` abort**（§8） | 正常通路（`loadMode=0`）不误报 ⇒ 守卫是有分辨力的 |
>
> **代价（网表级，不跑 PDS 的口径）**：`rtl/YeshenSocGlue.v` 相对 Phase-2a 末（`cc3ca5f`）**+208 行 /
> +8 436 B / +6 个 `reg` 声明 / +52 位已声明 FF**（整段并入 = `fcdc754` 的 +197 行 + 本相守卫 +11 行）。
> 引擎本体 `y1/gen/DmaEngine.v` = 4 993 行 / 201 717 B（**不入 glue jar**，当兄弟例化）。
> **时序未测**（本相无 PnR）⇒ R6 留到 2c/3（命令见 §12）。

---

## 1) 本相交付（提交面）

| 提交 | 内容 |
|---|---|
| `fcdc754` | **胶合起手**：`src/YeshenSocGlue.scala` §3.5 加第 6 个主人（`dmaMem` 主口 + `dmaPend` + `OWN_DMA_RD/WR`）+ DMA CSR 窗（§3 解码 + §4 从口）+ PLIC 源 4（`io.dmaIrq`）⇒ 重生成 `rtl/YeshenSocGlue.v` |
| `e05f098` | **台账**：`scripts/check_addr_map.py` 加 `check_dma_window_site()`（窗基址 + 源号 **记 1 个 site**）+ 四处承载者核对 ⇒ **16→17 站** |
| `1010b89` | **板级**：`board/yeshen_mini_soc.v` 把 `DmaEngine` 当 `NpuTop` 的**兄弟**例化（`cpu_clk` 直连，**无桥**） |
| `c51e63e` | **胶合级 DMA 作业判词**：`sim/glue_pbus/{pbus_dma_top.v,tb_dma_pbus.cpp,run_dma_pbus_unit.sh,negctl_dma_pbus.sh}`（J1..J4 + 两条负对照） |
| **（本相收口，未提交前）** | **item 5 决策**：`src/YeshenSocGlue.scala` **保留 `memSel` 一热选通**（不改成 `MemArbiter`）+ **守卫断言**；`rtl/YeshenSocGlue.v` 重生成；`sim/glue_pbus/run_dma_pbus_unit.sh` 加 `--assert`。见 §8。 |

**纪律**：`y1/rtl/DmaEngine.scala` **一字未改**（Phase-2a 冻结件）；`third_party/**`、冻结 Python 工具 **未动**。

---

## 2) §3.5 第 6 个主人（真仲裁，`MemArbiter` 一字不改）

`y1/reports/dma_phase1.md` §7 的接口单**逐字照抄即可**，本相照做：

- **主口**：`IOBundle` 加 `val dmaMem = Flipped(new NpuAxi64)`（**从方**：引擎的主口接进来）。
  形状与 `npuMem` **同款**（28 bit 地址 / 64 bit 数据 / 4 bit id）。
- **请求线**：`private val dmaPend = io.dmaMem.awvalid || io.dmaMem.arvalid`（**第 6 个主人**）。
- **配额**：`arb.io.req(2) := dmaPend`；`ARB_WEIGHTS = Seq(2, 1, 1)`（类 0 CPU 组 / 类 1 NPU / 类 2 DMA）；
  **`MemArbiter` 一字未改**（N/权重都是参数）。
- **owner 态**：`OWN_DMA_RD = 6` / `OWN_DMA_WR = 7`（Phase-1 已预留的 8 态）。
- **DMA 分支**：照抄 NPU 分支 —— 写 > 读；`28→32` **零扩展**（`Cat(0.U(4.W), io.dmaMem.araddr)`）、**id 丢弃**；
  `ar/aw/w` 的 valid 按 grant 加门，`ready` 回程同理（`io.dmaMem.arready := cpuMem.arready && dmaRd` …）。
- **落账**：`when(dmaRd && cpuMem.rvalid && cpuMem.rready && cpuMem.rlast){owner:=IDLE}` / 写侧等 `B`。

**为什么它不改 `MemArbiter`**：Phase-1 把类与权重做成参数、owner 位宽留到 4 位 ⇒ 加第 6 个主人 = 接两条线 +
两个稳态，仲裁器**结构不变**（这正是 Phase-1 §7 写的"一字不改"）。

---

## 3) DMA CSR 窗（256 B @ `0xF000_6000`）

- **常量**（`src/YeshenSocGlue.scala`）：`DMA_BASE = 0xF0006000L`、`DMA_MASK = 0xFFFF_FF00L`（256 B）。
- **§3 解码**：`isDmaR/(pR&DMA_MASK)==BASE`、`isDmaW` 同款（读用读地址、写用写地址，不合并）；
  与 NPU 窗一样经 `selDma = 7.U(3.W)` 进一热选通。
- **§4 从口**：`val dmaAxi = new VexiiAxiLite32`（胶合作**主方**）→ 板级接 `DmaEngine.axilite_*`。
  给引擎的是**窗内相对偏移**（低 8 位 = 256 B），因为 `DmaEngine.axilite` 是**基址 0** 的
  `AxiLite4SlaveFactory` 从口（CSR 0x00..0x93 在窗内）。
- **DTS**（`sw/buildroot-external/boards/naxmini/linux/linux_raw.dts`）：
  `dma@f0006000 { compatible = "y1,dma-engine"; reg = <0xf0006000 0x100>; interrupts = <4>; }`。
- ⚠️ **提示（非阻断）**：`src/YeshenSocGlue.scala` 里有两处**旧注释**写的是 `0xF000_5000`
  （约 600 / 705 行），与真正的 `DMA_BASE = 0xF000_6000L` **不一致**。**只是注释**（`0xF000_5000`
  在本设计里是**未译码空段**，被胶合级装置用作"错窗基址"负对照）。**本相未改**：改它会移动 1174 行
  以上注释行号、进而改变网表里那条守卫断言的 `YeshenSocGlue.scala:<行>` 文本 ⇒ 触发一次无谓的重生成 +
  重验；留待 Phase-2c 顺手订正。

---

## 4) PLIC **源 4**（`NDEV` 3→4）

- **源线**：`val dmaIrq = Input(Bool())`；`plic.io.dmaIrq := io.dmaIrq`。板级把 `DmaEngine.irq`
  （= `GBL_DONE|GBL_ERR` 的**线或**，电平保持）接进来。
- **`PlicAlite.NDEV 3→4`**；源号分配：1=控制台 ns16550a / 2=LiteEth / 3=NPU / **4=DMA**。
- **DTS**：`interrupts = <4>` + `plic` 的 `riscv,ndev = <4>`（台账 `PLIC_NDEV` 同步）。
- **清源落点**：`CH_STATUS` 的 **w1c**（写 1 清 `done_sticky`/`err_sticky`）⇒ `irq` 落 0（胶合级装置 J3 实测）。

---

## 5) 板级兄弟 + PDS 源单

- `board/yeshen_mini_soc.v`【12】：`DmaEngine` 当 **`NpuTop` 的兄弟**（**不进** glue jar）；
  **`cpu_clk` 直连、无桥**（DMA 与 CPU 同域；NPU 才走 `npu_clk` + 跨时钟桥）。
  - 寄存器窗从口：`glue.io_dmaAxi_*`（主）↔ `DmaEngine.axilite_*`（从）。
  - 内存主口：`DmaEngine.axi_*`（主）→ `glue.io_dmaMem_*`（从，**汇入 §3.5 同一汇聚点**）。
  - 每通道流口**结构化空闲**（本相只走 COPY / DDR↔DDR）。
  - 中断：`DmaEngine.irq` → `glue.io_dmaIrq`（PLIC 源 4）。
- **PDS 源单**：`y1/pds/pnr_c4a.tcl` 与 `y1/pds/devmap_c4a.tcl` 都加了
  `add_design "$root/y1/gen/DmaEngine.v"`（第 106 行）—— 否则 PnR 会因缺实体报黑盒。

---

## 6) 台账 delta：**16 → 17** 站

- `scripts/check_addr_map.py`：`EXPECT` 加 `DMA_BASE = 0xF000_6000`、`DMA_IRQ_BIT = 4`、`PLIC_NDEV = 4`；
  新增 `check_dma_window_site()` —— 把 **"窗基址 + 源号"** 当**一对不可分**的条目、**记 1 个 site**，
  并核对**四处承载者**：胶合 `DMA_BASE` / `DMA_IRQ_BIT`、DTS `dma@` 的 `reg` / `interrupts`
  （外加 `PlicAlite.NDEV` 与 `riscv,ndev`）。任一处漂移即红。
- 实测：`PASS: address ledger consistent (17 sites reconciled)`，rc=0。

---

## 7) 胶合级 DMA 作业 + 负对照（证据）

**装置**：`sim/glue_pbus/pbus_dma_top.v`（**新增件**：把 `YeshenSocGlue` 与 `DmaEngine` 两个**只读**网表
装进同一 Verilator 模型并使二者"板级那样"互连）+ `tb_dma_pbus.cpp` + `run_dma_pbus_unit.sh`。

**判据（逐条能翻红）**：
- **J1【正·核心】** COPY **逐字节**（目标 == 源、`CH_BYTES == LEN`、源未被改）。
- **J2【正·通路】** `io_mem` 上 AR/AW/W 计数 **> 0**（引擎真的过 §3.5 打到内存）；CSR 读回 `GBL_ID == 0x59444D41`（"YDMA"）。
- **J3【正·中断】** 完成后 `dmaIrq == 1`；写 `CH_STATUS` w1c ⇒ `0`。
- **J4【负·窗口基址】** 同一偏移放到未译码错窗 ⇒ 读不回 `GBL_ID`、写 DECERR、且**不产生任何搬运**。

**实测**：`run_dma_pbus_unit.sh` → **TEST PASSED**（rc=0）。

**负对照**（`negctl_dma_pbus.sh`，逐条**单行源码变异 + 重生成 glue jar + 重跑**）：
- **NC_DMA1**：`DMA_BASE = 0xF0006000L → 0xF0007000L`（窗挪走）⇒ **TEST FAILED** ✔（CSR 不可达）。
- **NC_DMA2**：`dmaPend = ...awvalid||...arvalid → false.B`（第 6 个主人请求线**钉 0**）⇒ **TEST FAILED** ✔（引擎拿不到总线）。
- 跑完**恢复源码 + 重生成**并核对 md5：`rtl/YeshenSocGlue.v` 跑前/跑后 **逐字节一致**（`a382439d…`）；
  `src/YeshenSocGlue.scala` 也复原（`4a07afd1…`）。脚本 `exit 0`（两条都按期望翻红）。

> **关于 `--assert`**：`run_dma_pbus_unit.sh` 的构建行加了 `--assert`（把 §8 的守卫断言"显式启用"）。
> 本相实测：**Verilator 5.020 无论是否 `--assert`，都会把 Chisel 的 `ASSERT_VERBOSE_COND_/STOP_COND_`
> 守卫编译成运行期检查**（配对构建的生成 C++ 里都出现 `VL_STOP_MT`，见 §8）。所以 `--assert`
> 是**显式保险**、不是唯一开关；而 J1..J4 本身在**正常通路**（`loadMode=0`）下守卫**从不误报**。

---

## 8) ★ item 5：`memSel` 一热选通的**书面裁决** + 守卫的**可证伪性证明**

### 8.1 裁决：**保留 `memSel` 一热选通，不改成 `MemArbiter`**

`private val memSel = loadActive`（`src/YeshenSocGlue.scala` §4 内存主口收尾）——**逐条理由**：

1. DMA 引擎接在 **§3.5 那个汇聚点**（第 6 个主人，CPU 组/NPU/DMA 之间**真仲裁**），**不接在这条最终主口上**
   ⇒ 本处两个分支（装载器 / `cpuAxi`=CPU 组）**一字未变**；DMA 的流量走 `cpuAxi` 分支**内部**（§3.5→§4），
   与本选通无关。
2. 本选通的分支是**时间互斥**的：`memSel = loadActive`，而**装载期板级把 CPU 扣在复位**（`io.cpuReset`
   由板级 OR 进核复位）⇒ CPU 组**结构性地不发命令**；装载器加载期**只写**、读通道恒空闲 ⇒ 一次只有一方
   驱动 `io.mem` ⇒ 一热选通**足够**（与 Phase-1 的口径一致）。
3. 把它也换成 `MemArbiter` 需要一个**能同时驱动装载器与 CPU 组**的装置才判得出（现有 harness 的 loader
   是 tf 卡 SPI 时序，代价大、收益 0）—— 属于"**另一相**"，本相**不做**（对应待办 #258 P1-C）。

### 8.2 守卫（**把"互斥"钉成断言，不是注释**）

```scala
when(memSel) {
  assert(!(io.cpuFetch.arvalid || io.cpuLsu.awvalid || io.cpuLsu.arvalid),
    "memSel: loader owns io.mem => CPU group must NOT issue (loader/CPU must stay time-exclusive)")
}
```
生成到 `rtl/YeshenSocGlue.v` 的守卫块（`ifndef SYNTHESIS` + `always @(posedge clock)`，
条件 `loadActive & ~reset & (io_cpuFetch_arvalid | io_cpuLsu_awvalid | io_cpuLsu_arvalid)`）。

### 8.3 可证伪性证明（**不是死守卫**）

在**真实** `rtl/YeshenSocGlue.v` 上，用 scratch wrapper（把 `loadMode`/`cpuFetch.arvalid` 提到顶层输入、
把 `loadActive` 提到顶层输出；**RTL 一字不改**）驱动出"**装载器当主人 + CPU 组发命令**"这一非法时刻：

```
after reset:        loadActive=0
after loadMode=1:   loadActive=1     # 装载器当主人（sdEnable=1）
# 再把 io_cpuFetch_arvalid=1 —— posedge 采样 ⇒ 守卫条件成立
%Error: YeshenSocGlue.v:4567: Assertion failed in TOP.memsel_top.u_glue:
        Assertion failed: memSel: loader owns io.mem => CPU group must NOT issue ...
          at YeshenSocGlue.scala:1174 assert(!(io.cpuFetch.arvalid || ...))
%Error: Verilog $stop / Aborting...     # 进程 abort（rc=134）
```

- 生成 C++（配对构建）里，守卫条件就是**真信号**：`(loadActive) & (~reset) & (io_cpuFetch_arvalid)` → `VL_STOP_MT`
  ⇒ **活代码，不是被常量折叠掉的死码**。
- **配对对照**：去掉 `io_cpuFetch_arvalid`（正常通路，即 `run_dma_pbus_unit.sh` 的 `loadMode=0` 场景）
  守卫**不触发**（装置 TEST PASSED）⇒ 守卫**有分辨力**、不是"恒发火"的橡皮图章。
- （过程记录：Verilator 5.020 下 `--assert` 与 `--no-assert` 都会把该守卫编译成运行期检查且都发火；
  `--assert` 属显式保险。这一点已如实记在上面。）

---

## 9) 网表面积 Δ（**网表级**口径，− PDS）

对 `rtl/YeshenSocGlue.v` 做 grep 口径（before = Phase-2a 末 `cc3ca5f` / after = 本相工作区）：

| 口径 | before | after | Δ |
|---|---|---|---|
| 行数 | 4 702 | 4 910 | **+208** |
| 字节 | 146 774 | 155 210 | **+8 436** |
| `module` 数 | 12 | 12 | 0 |
| `reg` 声明数 | 367 | 373 | **+6** |
| 已声明 FF 位宽 | 5 326 | 5 378 | **+52** |

- 其中 **`fcdc754`（并入）= +197 行**；**本相守卫 = +11 行 / +0 FF**（断言不落寄存器）。
- FF 增量很小：主因是 **owner 位宽 3→4**、§3.5 新增的 DMA 侧 grant/稳态、§4 CSR 窗选通的一两颗寄存器；
  解码/多路选通都是组合逻辑（不显 FF）。
- 引擎本体 `y1/gen/DmaEngine.v` = 4 993 行 / 201 717 B / 218 `reg` 声明（**入 PDS 源单**，但**不入 glue jar**）。
- **未测**：对 CLMA/CLMS（板级紧资源）与**时序**的影响 —— 本相**无 PnR**（R6 未关闭）。

---

## 10) 回归 + 记账（实跑）

### 10.1 胶合/pBus/仲裁/DDR 桥（WSL + Verilator 5.020）

```
sim/glue_pbus/run_unit.sh            rc=0  TEST PASSED   (pBus 译码：console/CLINT/PLIC/...)
sim/glue_pbus/run_npu_unit.sh        rc=0  TEST PASSED   (NPU 寄存器窗 CPU 侧写通路)
sim/glue_pbus/run_memmerge_unit.sh   rc=0  TEST PASSED   (§3.5 内存合并点)
sim/glue_pbus/run_dma_pbus_unit.sh   rc=0  TEST PASSED   (★ 本相新增：DMA 胶合作业)
sim/memarb/run_unit.sh (NO_GEN=1)    rc=0  TEST PASSED   (真仲裁器单元；源码本相未动)
sim/ddr3bridge/run_unit.sh(NO_GEN=1) rc=0  TEST PASSED   (DDR3 桥；源码本相未动)
sim/glue_pbus/negctl_dma_pbus.sh     rc=0  NC_DMA1/NC_DMA2 均 TEST FAILED（按期望翻红）+ 恢复逐字节一致
```
> 闸门根路径核对：`run_unit.sh`/`run_npu_unit.sh` 里写死的是 **`/mnt/d/code/PDS/VexiiYeshenLinux`**
> = **本树**（不是早期抓到的另一个 checkout `…/NaxYeshenLinux`）；`memarb`/`ddr3bridge`/`glue_pbus/*dma*`
> 均已**从脚本自身位置反推**仓库根。⇒ **判的是本树**。`memarb`/`ddr3bridge` 用 `NO_GEN=1` 复用**本树**既有网表
> （两模块源码本相未动、网表确定性）。

### 10.2 15 个 `y1/tools/run_*_ab.sh` + `run_dmaeng_ab.sh`（git-bash + iverilog）

```
run_ddrmaster32_ab=0 run_desc_ab=0      run_fusionbuf_ab=0 run_bypass_ab=0   run_unitexec_ab=0
run_fuse_head_ab=0  run_fuse_ab=0       run_chain_ab=0      run_sched_ab=0    run_nputop_ab=0
run_nputop_sched_ab=0 run_hostregs_ab=0 run_ddrcopy_ab=0    run_ddrread_ab=0  run_ddrwrite_ab=0
+ run_dmaeng_ab=0（Phase-2a 新增，第 16 个）
```
（这 16 条走 **msys iverilog** —— 在 WSL 里会**假红**，故一律在 **git-bash** 里跑。）

### 10.3 台账 + dangling

```
python scripts/check_addr_map.py        -> PASS: address ledger consistent (17 sites reconciled)  rc=0
python y1/tools/check_dangling.py rtl/YeshenSocGlue.v   -> modules 12 (inst 11) | dangling 0 | PASS
python y1/tools/check_dangling.py y1/gen/DmaEngine.v    -> modules 2  (inst 1)  | dangling 0 | PASS
python y1/tools/check_dangling.py y1/gen/NpuTop.v       -> modules 19 (inst 18) | dangling 0 | PASS
```

**`third_party/**` 与冻结 Python 工具**（`ddr_traffic.py`/`fusion_buffer.py`/`bypass_traffic.py`/
`mac_ref.py`/`bypass_ref.py`/`conv_unit_ref.py`/`desc_table.py`）**一字未动**。

---

## 11) Phase-2c 必须接的线（本节的每一条都可直接动手）

1. **P1-C / item 5 的另一相**：若要"装载器与 CPU 组**同时**在飞"，把 §4 的 `memSel` 一热选通换成**同一个
   `MemArbiter`**（类 = {CPU 组, 装载器, DMA}），并把装载器的直连 `ready/bvalid` 按 ownership 加门；
   **需要一个能同时驱动两方的装置**才判得出（现 harness 的 loader 是 tf 卡 SPI 时序）。
2. **第一个真客户：SD 装载器（D3）**：`src/peripheral/SdLoader.scala` 已是 AXI4 写主口（32 B 突发）；
   改成"喂引擎"：把 `awaddr/wdata/...` 换成写引擎 CSR（`SRC/DST/LEN/MODE=2` + `start`），字节流接到
   引擎的 `wr_valid/wr_data` ⇒ **同一镜像逐字节相同**（D3 判据）。
3. **网络 rx/tx 与相机留口**：同一套 CSR + 流口，按 spec §4.4 顺序推。
4. **描述符环（§4.1 的 B 形态）**：`CH_MODE` 之上 2 bit / `CH_CTRL` bit2..7 未用 ⇒ 链模式/链指针可落那里；
   需要 `DescFetch` 式 DDR 取表通路（独立一档）。
5. **时序/面积**：R6 —— **每相重跑 PnR**（命令见 §12），关掉"并入后 100 MHz 是否仍收敛"。
6. **`0xF000_5000` 旧注释订正**（§3 提示；改注释会移动断言行号 ⇒ 与重生成一起做）。

---

## 12) 控制器 PnR 命令（**本相未跑**，仅为记录）

```bash
# 工作目录 = D:/code/PDS/VexiiYeshenLinux
/c/Pango/PDS_2025.2-ads/bin/pds_shell.exe -file y1/pds/pnr_c4a.tcl   > y1/pds/pnr_dma_p2b.log    2>&1 ; echo "exit=$?"
/c/Pango/PDS_2025.2-ads/bin/pds_shell.exe -file y1/pds/devmap_c4a.tcl > y1/pds/devmap_dma_p2b.log 2>&1 ; echo "exit=$?"
# 判据：report_timing 的 "All Constraints Met" + 结束标记 YESHENMINI_PNR_C4A_DONE + Device Utilization Δ
# （pnr_c4a.tcl / devmap_c4a.tcl 的源单已含 add_design "$root/y1/gen/DmaEngine.v"）
```

---

## 13) 改动面 + 指纹（`md5sum`）

| 文件 | md5 | 说明 |
|---|---|---|
| `src/YeshenSocGlue.scala` | `4a07afd1a02c1c616b3482f8009732d1` | **本相收口**：`memSel` 裁决注释 + 守卫断言（并入主体见 `fcdc754`） |
| `rtl/YeshenSocGlue.v` | `a382439df9de1d933636bb20082fba2f` | **重生成产物**（与 `src` 用仓库流程逐字节可复现；**非手改**） |
| `sim/glue_pbus/run_dma_pbus_unit.sh` | `b3974ef603228614a21e71e1a0300fe7` | 构建行加 `--assert` |
| `scripts/check_addr_map.py` | （见 `e05f098`） | 台账 17 站（`check_dma_window_site`） |
| `board/yeshen_mini_soc.v` | （见 `1010b89`） | `DmaEngine` 兄弟例化（`cpu_clk` 直连） |
| `y1/gen/DmaEngine.v` | （生成物，`y1/gen/` 不入库） | 4 993 行 / 201 717 B |

**`.v` 可复现证据**：本相用仓库流程（`REBUILD_JAR=1 bash sim/glue_pbus/gen_glue.sh`，
scala-cli assembly + `java -jar`）**重跑**生成 ⇒ 产物与工作区 `rtl/YeshenSocGlue.v` **逐字节一致**
（rc=0、jar built、`[glue] ok`）⇒ 断言证得 `.v` 系**生成**、非手改。

---

## 14) 能证 / 不能证

**能证（本轮实测）**
1. 一条真实 DMA 搬运能走通"**CPU 写 CSR → glue §3.5 第 6 个主人 → io.mem → 回读 → COPY 写回 → 完成/err →
   CSR 回读 + PLIC 源 4 中断**"整条集成通路，且 **逐字节**正确（J1..J4）。
2. **两条负对照全红**（窗基址打歪 / 第 6 个主人请求线钉 0）⇒ 集成判据**有分辨力**；跑完网表**逐字节复原**。
3. **台账 17 站**一致；dangling 全 0；**16 个 y1 单元闸门 + 6 个胶合/仲裁/DDR 闸门全绿**。
4. §4 `memSel` 守卫是**活断言**、**可翻红**（强制非法时刻 ⇒ 响亮 `$fatal`），正常通路**不误报**。
5. `rtl/YeshenSocGlue.v` 由 `src/YeshenSocGlue.scala` **可复现**（重跑生成逐字节一致）。

**不能证 / 有条件**
1. **时序/器件面积未测**（本相无 PnR）⇒ R6 **未关闭**（§12 给了命令）。
2. **没有真实客户**：SD 装载器 / 网络 / 相机**还没接**（那是 Phase-2c 的 §11）；本相只证"CPU 编程的 DMA"。
3. **装载器与 CPU 组不能同时在飞**：这**不是缺陷**，是 §8 的**有意裁决**（板级把 CPU 扣复位 ⇒ 时间互斥）；
   要放开需 P1-C（换真仲裁 + 能同时驱动两方的装置）。
4. **不是真板/真 DDR**：内存是行为模型；真 `DDR3Bridge`/真 DDR 上未验（沿用 Phase-0/2a 的口径）。
5. **`0xF000_5000` 旧注释**属**已知遗留**（§3，仅注释、不影响功能）。
