# Y1-DMA **Phase-2c** 判词 —— **把真客户接到引擎上**（第一个客户 = SD 装载器；**D3 逐字节成立**）

- 日期：2026-10-13
- 上游：`docs/superpowers/specs/2026-10-13-y1-soc-dma-engine-design.md`（§4.4 客户顺序、§5 D3）、
  `docs/superpowers/plans/2026-10-13-y1-soc-dma-engine.md` **Phase 2 / T2.2**、
  `y1/reports/dma_phase2b.md` §11（**"Phase-2c 必须接的线"** —— 本报告逐条销账）。
- 本相**只做客户接线**：引擎 `y1/rtl/DmaEngine.scala` / `y1/gen/DmaEngine.v` **一字未改**
  （md5 `4f31e78ba397e6f3381a65b91ab301a8` 不变）。**没跑 PDS/PnR**（控制器跑；命令见 §9）。

---

## 0) ★ 判词（先给结论）

> **成立（第一个真客户已接上，D3 逐字节证完）。** SD 装载器**不再自己举 AXI 写突发**：它用一根小
> AXI4-Lite 主口编程引擎通道 0 的 CSR（`DST/LEN/MODE=2(WR)/start`）、再把原本要发成 32B 突发的
> 字节流从 `wr_valid/wr_data` **推给引擎**，由引擎过 glue §3.5 落到 DDR。
>
> **D3 核心判据**：同一张卡镜像、同一份卡表（3 个表项、目标地址在 `0x8000_0000` 段 = **真机口径**），
> **两条通路**（A = 直写内存 / B = 喂引擎）在同一装置里各跑一次，装载结果 **逐字节相同**
> （`BAD=0 / 13824 B`）且都与卡镜像逐字节一致。
>
> | 判据 | 阳性（本轮实测） | 负对照（必须翻红，实测全红） |
> |---|---|---|
> | **★ D3（客户端等价）** | `sim/sdloader/run_sdloader_dma_unit.sh` **TEST PASSED**：通路A vs 通路B **逐字节 BAD=0**、`wlast`/记账吻合 | `negctl_sdloader_dma.sh` **两条全红**：**NC_SDLDMA1**（喂流 64bit 高低半交换 ⇒ 13824 B 全错）、**NC_SDLDMA2**（`memSel` 退回 `loadActive` ⇒ 引擎流量被挡） |
> | **切换是真的** | 通路 A：CSR 主口 0 笔、喂流 0 笔、§3.5 `owner` 从不进 DMA 类；通路 B：CSR 4 笔/表项、喂流 1728 拍、`owner==7`(OWN_DMA_WR) 出现过 | 上面两条 NC 恰好各打这两侧之一 |
> | **既有回归** | 胶合 4 装置 + `memarb` + `ddr3bridge` 全 PASS；`negctl_{pbus,dma_pbus,memmerge}` 全部按期望翻红；y1 闸门见 §7 | — |
> | **台账 / 结构** | `check_addr_map.py` **17 站**（**未加窗** ⇒ 站数不变）、`check_dangling` 0、`check_dup_modules` **81/81 无重名** | — |
>
> **代价（网表级，− PDS）**：`rtl/YeshenSocGlue.v` 相对 Phase-2b 末（`b33d9c7`）**+364 行 / +12 679 B /
> `reg` 声明 +20**；引擎本体与 `y1/gen/DmaEngine.v` **未动**。**时序未测**（本相无 PnR）。

---

## 1) 本相交付（提交面）

| 提交 | 内容 |
|---|---|
| `e53dfcc` | **SD 装载器接引擎**（RTL + 板级 + 装置 + 负对照）：`SdLoader` 的 DMA 客户端口与顺序器、glue 的窗主口让渡 + 喂流端口 + **`memSel` 收紧**、板级 `sd_dma_mode=1` + `wr_*_0` 接线、`sim/sdloader/{sdloader_dma_top.v,tb_sdloader_dma.cpp,run_sdloader_dma_unit.sh,negctl_sdloader_dma.sh}`、顺带订正两处 `0xF000_5000` 旧注释、`run_unit.sh` 改判**本树** |
| （本报告） | 判词 + 网络/相机的**明确余量**（§8） |

**纪律**：`y1/rtl/DmaEngine.scala`、`y1/gen/DmaEngine.v`、`third_party/**`、冻结 Python 工具 **一字未动**。

---

## 2) 第一个客户：SD 装载器（`src/peripheral/SdLoader.scala`）

### 2.1 接口（新增，都是**客户侧**的，不动引擎）

```
dmaMode                        // strap：1 = 喂引擎（0 = 既有的"装载器直写 DDR"通路，逐字保留）
dmaCsr_{awaddr,awvalid,awready,wdata,wvalid,wready,bvalid,bready,bresp,
        araddr,arvalid,arready,rvalid,rready,rdata,rresp}   // AXI4-Lite **主口**（引擎 CSR 窗）
dmaWr_{valid,data,ready}       // 32B 组拆 4 拍 64bit 喂引擎 `wr_stream`
```

- **程序模型**：每**表项**一次 —— 写 `CH_DST = 表项目标地址`（引擎截 28bit，见 §2.3）、
  `CH_LEN = 块数 × 512`（32B 的整数倍、非 0）、`CH_MODE = 2`（**WR**：只写，从 `wr_stream` 灌）、
  `CH_CTRL = 1`（start）；随后把该表项的字节按 32B 组喂进 `wr_stream`；最后轮询 `CH_STATUS`
  直到 `done`（进 `lDone` 放核）或 `err/aborted/超时`（`errCode` 5/6 ⇒ `lFail`）。
- **喂流与读块并行**（与 Phase-2b 之前 AXI 侧同一条纪律）：`dbAct/dbIdx` 小 FSM 把 `wBuf` 的
  4 拍 64bit 一拍一拍推给引擎，**背压由引擎的 `wr_ready`（只在 `DSTR/WSTR` 态举）表达**；
  `sd.io.dReady` 加上 `!dbAct` ⇒ 推流期间不收新字（不会盖掉本组）。
- **两条通路按 `dmaMode` 互斥**：AXI 写通道的三个 valid/bready 都加了 `&& !io.dmaMode` 门；
  `wGo`（发 AXI 突发）与 `dbAct`（喂引擎）各由 `dmaMode` 选通，`groupFull` 只可能被其中一条清掉。
- **`errCode` 新增**：`5 = DMA 引擎报错`（`CH_STATUS` 的 err/aborted，或 CSR 事务响应非 OKAY）、
  `6 = DMA 引擎超时`（轮询次数上限 / 单笔事务超时）。
- **守卫**：`when(!io.active)` 的断言扩到 DMA 端口（CSR 主口 + 喂流），保持"非装载期一律不驱动"。

### 2.2 ★ 本相**实测踩到的两个真坑**（都写进代码注释，因为它们都不是风格问题）

1. **轮询不能与喂流同时开始**（否则预算被"慢卡"吃干）。
   SPI 读块是**百万拍量级**；若"写完 start"就开始轮询 `CH_STATUS`，轮询次数预算会在数据还没喂完时
   耗尽。**实测签名**：第二个表项数据全写对了，但第三个表项 `errCode=6`（超时），`CH_STATUS` 一直读回 0；
   CSR 轨迹显示 3 轮编程都对（`DST/LEN/MODE/START` 各 3 笔）。
   **修法**：顺序器写完 4 个寄存器后停在**新状态 `dWait`**，等主 FSM 走到 `lDPoll`（= 本表项字节**全部推完**）
   才抬 `dPollGo` 开始轮询 ⇒ 轮询预算只需覆盖"引擎收尾"（几百拍量级）。
2. **AW/AR 收下即撤**：AXI 的 valid 只需一拍就能成交，持续举着等于**又发一笔**（会把同一笔当两笔接受）。
   `dAw/dWc/dAr` 三个 "已成交" 标志就是这条纪律；`dPh` 把"命令相位 / 响应相位"分开。

### 2.3 ★ 地址口径：引擎的 28bit 主口**为什么**与 32bit 直写同义（D3 的承重前提）

- 引擎主口是 **28bit**（`DmaEngineConfig.ADDR_W`），`CH_DST` 写进去后被截到低 28 位；
- `src/soc/DDR3Bridge.scala` 对 AXI 地址取的是 **`awaddr(29,2)` 为字地址** ⇒ **bit31/30 被丢弃**；
- ⇒ 板级 DDR 基址 `0x8000_0000` 在整条 DDR 通路上是**纯别名**：
  直写通路送 `0x8040_0000`（bit31 被桥丢掉）与引擎送 `0x0040_0000`（被引擎截掉）**落到同一个 DDR 字节**。
- 这与 NPU 的既有约定**同款**（DTS 注释：`物理 [0x8040_0000, 0x8200_0000) = NPU [0x0040_0000, 0x0200_0000)`）。
- **装置里如实建模**：内存模型索引 = `addr & 0x3FFF_FFFF`（= 与 `awaddr(29,2)` + 字节道同口径）
  ⇒ 两条通路的镜像**直接可比**，不需要任何"为判据而编的偏移"。卡表因此可以（也应该）直接用**真机地址**
  （`0x8000_0000` 段）。

---

## 3) glue 的两处改动（`src/YeshenSocGlue.scala`）

### 3.1 DMA CSR 窗主口：装载期**让给装载器**

`io.dmaAxi` 这根窗主口现在有**两个主人**，按时间互斥选通（与 §4 的 `memSel` 同一条纪律）：

```scala
private val sdDmaCsr = sdEnable && io.sdDmaMode      // 选通**必须**带 sdEnable，不能只看 strap
io.dmaAxi.awvalid := Mux(sdDmaCsr, sdLoader.io.dmaCsrAwValid, pBus.awvalid && isDmaW)   // 其余同款
sdLoader.io.dmaCsrAwReady := io.dmaAxi.awready && sdDmaCsr                                  // 回程只给被授权方
```

- **为什么可行**：装载期 CPU 被扣在复位（`io.cpuReset`）⇒ pBus 结构性静默 ⇒ 两方**不可能同时在飞**。
- **为什么必须带 `sdEnable`**：否则非装载期装载器的恒 0 valid 会把 CPU 的窗读**闷死**。

### 3.2 ★ `memSel` 收紧（**推翻 Phase-2b 的一条理由**，如实记）

```scala
private val memSel = uartEnable || (sdEnable && !io.sdDmaMode)     // Phase-2c 收紧
// Phase-2b 曾是：private val memSel = loadActive
```

- **为什么必须改**：DMA 模式下**装载器不再是 `io.mem` 的主人** —— 字节走的是"装载器 → 引擎 → §3.5 →
  `cpuAxi` 分支"。若选通仍等于 `loadActive`，则 `io.mem` 仍被**装载器分支**（在 DMA 模式下恒 0）驱动
  ⇒ **引擎的写突发全被挡掉**（一笔都到不了内存）。
  实测签名：`owner==7` 已登记（引擎拿到了总线）、引擎内部算作 AW 成交，但 `io_mem` 上 **AW/W 恒 0**、
  装载器卡在 `state=2` 直到超时。修好后通路 B 的 `io_mem` 立刻出现 108 笔 AW / 1728 拍 W。
- `sdDmaMode=0` 时 `memSel = uartEnable || sdEnable = loadActive` ⇒ 与 Phase-2b **逐位同值**
  （既有装置/判据不受影响）。UART 后备装载器**永远直写**（它没有喂引擎这条路），故它始终占装载器分支。
- **守卫**仍成立且范围正确：`memSel=1` 只可能在"UART 后备直写"或"SD 直写(`sdDmaMode=0`)"时出现，
  两种情况下 CPU 都必须静默。**这条改动由 `NC_SDLDMA2` 钉住**（退回旧口径 ⇒ D3 立刻翻红）。

### 3.3 板级（`board/yeshen_mini_soc.v`）

- `sd_dma_mode` 板上**恒 1**（新通路；置 0 可退回老通路，仅供装置做 A/B 比对）；
- `glue.io_dmaWr{Valid,Data,Ready}` ↔ `DmaEngine.wr_{valid,data,ready}_0`（**通道 0 = SD 装载器**）；
- `wr_*_1`（**通道 1 = 网络**）与 `rd_*_0/1` 仍结构化空闲 —— 见 §8。

---

## 4) ★ 装置决策：**用最小 SPI/SD 卡模型 harness**（不是给装载器打桩）

**决策：建"卡模型 + 引擎"的复合装置**（`sim/sdloader/sdloader_dma_top.v` = `YeshenSocGlue`（内含
`SdLoader`/`SdSpi`）+ `DmaEngine` + 装置侧 SPI 卡模型 + 64bit 内存模型），**不**给装载器的
`wr_valid/wr_data` 打桩。**逐条理由**：

1. **D3 要证的是"同一张卡上的同一份镜像、改走引擎后逐字节不变"** ⇒ 承重的是
   **SPI 读块时序 + 块 0 表解析 + 那一次字节反转**（`SdLoader.scala:158-163` 的 2026-10-05 事故）。
   打桩会把这三段**整段绕掉**，证不到"客户端切换是安全的"。
2. **卡模型是现成的**：`sim/sdloader/tb_sdloader.cpp`（Phase-1 建的）已含
   CMD0/CMD8/CMD55+ACMD41/CMD58/CMD17 的 mode-0 SD 卡模型与逐字节判据，且**正是它当年抓出字节反转**。
   复用它（照抄惯用法）代价极低、覆盖面却是真实的。
3. **同一装置能同时给出两条通路**（`sdDmaMode` strap 是顶层输入），⇒ D3 的"逐字节相同"可以在
   **一次仿真里比对**，不用跨装置比指纹（比跨装置更硬：同一份内存模型、同一个卡模型、逐字节）。
4. 现成的 `sim/sdloader/run_unit.sh`（老通路单装置）**改成判本树**并保留为**独立的通路 A 闸门**
   ——两条通路各有独立装置，互不背书。

**装置清单**：`sim/sdloader/{sdloader_dma_top.v, tb_sdloader_dma.cpp, run_sdloader_dma_unit.sh,
negctl_sdloader_dma.sh}`；卡镜像 `sim/reglogs/sd_small.img`（28 块 = 14 KB，**目标地址在 `0x8000_0000` 段**，
由 `sim/mk_sd_image.py` 用 `sim/sdloader/testdata/{a,b,c}.bin` 现造；两个闸门都会在缺镜像时自动造）。

---

## 5) D3 证明 + 负对照（实测证据）

### 5.1 阳性（`bash sim/sdloader/run_sdloader_dma_unit.sh` ⇒ **TEST PASSED**，rc=0）

```
卡镜像 ../reglogs/sd_small.img: 14336 B = 28 块, 3 个表项
  表项: DDR 0x80000000  lba 1   8 块 (4096 B)
  表项: DDR 0x80400000  lba 9  16 块 (8192 B)
  表项: DDR 0x80F80000  lba 25  3 块 (1536 B)

J1 通路 A（sdDmaMode=0：装载器**直写内存**）
  cyc=2844806 state=3 err=0 | io_mem AR=0 AW=432 W=1728 B=432 wlast=432
                             | CSR-AW=0  wr_stream v/r=0/0 | owner==7 次数=0        [ok]
J2 通路 B（sdDmaMode=1：装载器**喂 DMA 引擎**）
  cyc=2844818 state=3 err=0 | io_mem AR=0 AW=108 W=1728 B=108 wlast=108
                             | CSR-AW=12 wr_stream v/r=1728/2292522 | owner==7 次数=1944
  CSR 明细：DST=3 LEN=3 MODE=3 START=3 其它=0 | 轮询=3 次，最后一次读回=0x00000001
  D3：通路A vs 通路B 逐字节 **BAD=0**（first=-1，共 13824 B）| 与卡镜像 BAD=0           [ok]
```

**这几行读法**（每条都是承重的）：

- **逐字节 BAD=0** ⇒ D3 成立（同一镜像经引擎 == 直写）。且两条通路各自与**卡镜像**独立对账也是 0。
- **`W 拍数` 两条通路完全相同（1728 = 13824/8）**：通路 A 发 432 笔 4 拍突发（32 B/笔），
  通路 B 发 108 笔 16 拍突发（128 B/笔，= `DdrMaster` 的块），**总写字节数一字不差**。
  两条通路的 `wlast == AW 笔数`、`B == AW`、`AR == 0`、`wstrb` 恒 0xFF、`awsize` 恒 3 ⇒ 突发合规。
- **`CSR 明细：DST=3 LEN=3 MODE=3 START=3`** ⇒ 装载器**每表项**编程一次引擎（3 个表项 ⇒ 各 3 笔），
  且没有第 4 笔（没有多余 start —— 那会让引擎丢掉一笔搬运）。`轮询=3 次，最后一次读回=0x1`
  ⇒ 每表项各自等到了 `done`。
- **切换是真的**：通路 B 的 `owner==7`（`OWN_DMA_WR`，§3.5 授予 DMA 类）出现 1944 拍、喂流 1728 拍；
  通路 A 这三项**全 0**（直写通路**结构性地绕过引擎**）。
- 两条通路都 `state=3`（`lDone`，放核）+ `err=0`，且都在 ~2.84M 拍完成（同量级 ⇒ 通路 B 没有额外等待）。

### 5.2 负对照（`bash sim/sdloader/negctl_sdloader_dma.sh` ⇒ 两条全红 + 逐字节复原，rc=0）

```
[nc] 跑前 rtl/YeshenSocGlue.v md5 = 47464c0057a3af458576c72831ea02b8
NC_SDLDMA1 => TEST FAILED（期望 TEST FAILED）
    D3：通路A vs 通路B 逐字节 **BAD=13824**（first=0，共 13824 B）| 与卡镜像 BAD=0
NC_SDLDMA2 => TEST FAILED（期望 TEST FAILED）
    [FAIL] J2 通路 B 未放核（state!=3）  D3：… BAD=13770 …  [FAIL] J4 通路 B 的 W 拍数 != 镜像字节数/8
[nc] 跑后 rtl/YeshenSocGlue.v md5 = 47464c0057a3af458576c72831ea02b8
[nc] 全部负对照按期望翻红，且源码/网表已复原 ⇒ PASS
```

- **NC_SDLDMA1**（★ 承重：喂流的**字节序**）：把 `Cat(wBuf(2i+1), wBuf(2i))` 换成
  `Cat(wBuf(2i), wBuf(2i+1))`（高低半交换）⇒ 13824 B **全错**（每 4 字节组反序）、**通路 A 仍 0 错**。
  ⇒ 这一处的字节序**是承重的**；D3 判据对它有分辨力。
- **NC_SDLDMA2**（★ 承重：`memSel` 的模式门）：退回 Phase-2b 口径 `memSel = uartEnable || sdEnable`
  ⇒ 通路 B **一笔都没写进内存**（`W 拍=0`）、未放核。
  ⇒ §3.2 那条收紧**是承重的**，不是"顺手改风格"。
- 两条 NC 各是**单行源码变异 + 重生成 netlist + 重跑**；跑完**源码与网表 md5 逐字节复原**。

### 5.3 判据自检（`SD_NC=1`）：**证明"逐字节比较"不是恒绿的橡皮图章**

```
=== J5 负对照（判据自检）：把通路 A 快照第 6912 字节翻一位 ⇒ 逐字节判据须翻红 ===
  [ok] J5 判据有分辨力（翻一位 ⇒ 逐字节比较报出差异）
```
（装置把通路 A 的快照翻一位，D3 比较立刻报出差异 ⇒ 比较器本身有分辨力；
这一条是**装置侧**的判据自检，与 §5.2 的**源码侧**负对照互补。）

---

## 6) 面积 Δ（**网表级**口径，− PDS）

对 `rtl/YeshenSocGlue.v` 做 grep 口径（before = Phase-2b 末 `b33d9c7` / after = 本相工作区）：

| 口径 | before | after | Δ |
|---|---|---|---|
| 行数 | 4 910 | 5 274 | **+364** |
| 字节 | 155 210 | 167 889 | **+12 679** |
| `reg` 声明数 | 373 | 393 | **+20** |
| `module` 数 | 12 | 12 | 0 |

- 增量全部来自 `SdLoader`（CSR 顺序器 + 喂流小 FSM + `dActive` 相关寄存器）与 glue（窗主口选通 +
  `memSel` 多两条项）：**没有新增模块**、没有新增窗（台账 17 站不变）。
- **引擎本体未动**：`y1/gen/DmaEngine.v` md5 `4f31e78b…` 与 Phase-2b 一致。
- **未测**：CLMA/CLMS 与**时序** —— 本相**无 PnR**（R6 仍未关闭）。

---

## 7) 回归（实跑）

### 7.1 胶合 / 仲裁 / DDR 桥（WSL + Verilator 5.020）

```
sim/glue_pbus/run_unit.sh            rc=0  TEST PASSED
sim/glue_pbus/run_npu_unit.sh        rc=0  TEST PASSED
sim/glue_pbus/run_memmerge_unit.sh   rc=0  TEST PASSED
sim/glue_pbus/run_dma_pbus_unit.sh   rc=0  TEST PASSED   （Phase-2b 的 DMA 胶合作业）
sim/memarb/run_unit.sh      (NO_GEN=1) rc=0  TEST PASSED
sim/ddr3bridge/run_unit.sh  (NO_GEN=1) rc=0  TEST PASSED
sim/sdloader/run_unit.sh             rc=0  TEST PASSED   （★ 本相改判**本树**：通路 A 独立闸门）
sim/sdloader/run_sdloader_dma_unit.sh rc=0 TEST PASSED   （★ 本相新增：D3）
sim/glue_pbus/negctl_dma_pbus.sh     rc=0  NC_DMA1/NC_DMA2 均翻红 + 复原逐字节一致
sim/glue_pbus/negctl_memmerge.sh     rc=0  NC_MM1/NC_MM2   均翻红
sim/sdloader/negctl_sdloader_dma.sh  rc=0  NC_SDLDMA1/2    均翻红 + 复原逐字节一致
```

> 两条既有的 DMA 负对照（`negctl_dma_pbus.sh`）在**新的 glue 网表**上仍按期望翻红 ⇒ Phase-2b 的
> 两个变异锚点（`DMA_BASE` 行 / `dmaPend` 行）没有被本相改动破坏。

### 7.2 y1 单元闸门（git-bash + iverilog）

`y1/tools/run_*_ab.sh` **全量 43 条逐个跑**（`run_numeric_ab.sh` 是**参数化助手**、不是闸门：
它要求 `<mode> <cin> <cout> <H> <W> <seed>` 六个参数，裸跑必然 rc=1 ⇒ 排除在闸门集之外）。
逐条 rc 见 §7.4 的实测表（全部 rc=0）。**这些闸门测的是 `y1/rtl/*` + `y1/gen/*`，本相一字未改**
（`git status` 只列 `src/`、`board/`、`sim/`、`rtl/YeshenSocGlue.v`）；重跑是"没用我的改动去破坏它们"的
**回归证据**，不是新判据。

### 7.3 台账 + 结构

```
python scripts/check_addr_map.py                     -> PASS: 17 sites reconciled      rc=0（**未加窗**）
python y1/tools/check_dangling.py rtl/YeshenSocGlue.v -> modules 12 | dangling 0 | PASS
python y1/tools/check_dup_modules.py                  -> 77 files / 81 modules / 0 dup | PASS
```

### 7.4 实测 rc 表（y1 闸门）

见本报告末尾 §11 的"回归 rc 表"（由 `/tmp/gate_summary.txt` 落盘；全部 rc=0）。

---

## 8) 余量（本相**没做**的，明确记账）

### 8.1 网络客户（spec §4.4 的②）：**已探明接口，未接**

**现状**（实读 `board/liteeth_wrap.v`）：网口是**纯 PIO/SRAM 槽窗**，无 DMA ——
`tgt_rx = tgt_buf & ~addr[13]`（rx 槽区 `0xF000_8000..0x9FFF`，4 × 0x800）；
`tgt_tx = tgt_buf & addr[13]`（tx 槽区 `0xF000_A000..0xAFFF`，2 × 0x800）；
槽内存是 **32bit 字寻址 + 4bit 字节使能**；CPU 侧走 glue 的 `io.ethAxi`（AXI-Lite 主口）。

**要接上还差什么**（逐条，可直接动手）：

1. **一个"槽泵"模块**（板级新增，~1 个小件）：① **rx 方向**：按 `{槽号, 长度}` 从 eth buffer 窗读
   32bit 字 → 组 64bit 拍 → 喂 `DmaEngine.wr_valid_1/wr_data_1`（**通道 1 的 WR 模式**：流 → DDR）；
   ② **tx 方向**：吃 `DmaEngine.rd_valid_1/rd_data_1`（**通道 1 的 RD 模式**：DDR → 流）→ 写 tx 槽。
   *两端引擎侧都已存在*（`DmaEngine` 每通道的 `rd_*`/`wr_*` 口在 Phase-2a 就有），**引擎不用改**。
2. **长度来源 / 臂载**：LiteEth 的 SRAM writer 写完一个 rx 槽会在其 CSR 给出长度；建议臂载走
   **CPU 写通道 1 的 CSR**（`CH_SRC = 槽地址`、`CH_LEN = 长度`、`CH_MODE = 2`、`start`）——
   即"网络客户"= **槽泵 + ch1 CSR**，与 SD 装载器同构（这也是 §4.4 把网络排在 SD 之后的原因）。
3. **板级/胶合出线**：需要把 `wr_valid_1/wr_data_1/wr_ready_1`（rx）与 `rd_valid_1/rd_data_1/rd_ready_1`
   （tx）从 glue 引到板级（本相**只引了通道 0**的三根）；**并给 `io.ethAxi` 加一个主人**
   （现在只有 CPU 的 pBus）—— 要么一个小 AXI-Lite 仲裁，要么沿用 `memSel` 那条"时间互斥"纪律。
4. **判据**：装置里 **`liteeth_wrap` 不在模型内** ⇒ 建议 (a) 槽泵的**单元装置**（喂一个行为级槽内存，
   判"槽内容 → DDR 逐字节"与"DDR → 槽逐字节"）+ (b) ch1 的 CSR-only 判据（引擎侧 WR/RD 已由
   `run_dmaeng_ab.sh` 的 JOB1/JOB2 覆盖）。**不要**在胶合级装置里假装有网口。

**估工**：槽泵 + 板级出线 + 一个单元装置 ≈ 一相；**风险**：`io.ethAxi` 加主人要动 glue §3 的
选通（与 3.1 同款手法，判据可复用本相的 `negctl` 骨架）。

### 8.2 相机（Y5，spec §4.4 的③）：**只登记接口预留，无 RTL（按要求）**

- **通道号预留**（已在 `src/YeshenSocGlue.scala` 的 DMA 端口注释里落字）：
  `ch0 = SD 装载器（已接）`、`ch1 = 网络（待接）`、**`ch2/ch3 = 相机预留`**（`DmaEngine.NCH` 上限 4，
  引擎**不用改**就能扩到 4）。
- **CSR 槽预留**：每通道 0x40（本相只用 ch0 的 `0x00..0x24`）；ch2/ch3 的同一组偏移**原样空着**
  （`DmaEngine` 已经把它们实现好，只是没人接流口）。
- **物理侧**：相机是**异域**客户端（画面时钟 ≠ `cpu_clk`）⇒ 按 spec §4.2/§2 的裁决，
  它的流口要在**合并点之前**过 `NpuMemCdc` 式的桥（板级做）；CSR 走**同一根 DMA 窗**（CPU 直接写）。
- 本相**刻意不把 ch2/ch3 的流线引出 glue**（避免"留了没人用的口"）；留的是**文档 + 通道号 + CSR 槽**。

### 8.3 其它（沿自 Phase-2b §11，仍未做）

- 描述符环（§4.1 的 B 形态）—— 独立一档，接口位已留（`CH_MODE` 之上 2 bit、`CH_CTRL` bit2..7）。
- **R6 时序/面积**：本相无 PnR ⇒ "并入客户后 100 MHz 是否仍收敛"仍未关闭（命令见 §9）。
- P1-C（把最终主口 `memSel` 也换成真仲裁，支持"装载器与 CPU 组同时在飞"）—— 仍待办；
  本相**只**把 `memSel` 收紧到"模式相关"，没有改它的实现形状。

---

## 9) 控制器 PnR 命令（**本相未跑**，仅为记录）

```bash
# 工作目录 = D:/code/PDS/VexiiYeshenLinux
/c/Pango/PDS_2025.2-ads/bin/pds_shell.exe -file y1/pds/pnr_c4a.tcl   > y1/pds/pnr_dma_p2c.log    2>&1 ; echo "exit=$?"
/c/Pango/PDS_2025.2-ads/bin/pds_shell.exe -file y1/pds/devmap_c4a.tcl > y1/pds/devmap_dma_p2c.log 2>&1 ; echo "exit=$?"
# 判据：report_timing 的 "All Constraints Met" + 结束标记 YESHENMINI_PNR_C4A_DONE + Device Utilization Δ
# 源单无需改：本相**没有新增 RTL 文件**（`sd_dma_mode` / 喂流是 board+glue 内的线网）。
```

---

## 10) 改动面 + 指纹（`md5sum`）

| 文件 | md5 | 说明 |
|---|---|---|
| `src/peripheral/SdLoader.scala` | `02fc2a91f4aecb56c21d41150fb04a8e` | DMA 客户端口 + 顺序器 + 喂流（含 §2.2 两个坑的注释） |
| `src/YeshenSocGlue.scala` | `bfd560c0ff21cf8ab62aee155b703a41` | 窗主口让渡 + `memSel` 收紧 + 喂流端口 + 两处旧注释订正 |
| `rtl/YeshenSocGlue.v` | `47464c0057a3af458576c72831ea02b8` | **重生成产物**（`REBUILD_JAR=1 bash sim/glue_pbus/gen_glue.sh`；可复现） |
| `board/yeshen_mini_soc.v` | `2a5306c5bbe238ff4c4059c07fbf2dd6` | `sd_dma_mode=1` + `wr_*_0` 接装载器 |
| `sim/sdloader/sdloader_dma_top.v` | `3dfdc224ba1d7a23bef028193561f2fb` | 装置头（glue + DmaEngine + 观测） |
| `sim/sdloader/tb_sdloader_dma.cpp` | `27327ca2be1abfffaad50fdfa4b7820e` | 卡模型 + 内存模型 + J1..J5 |
| `sim/sdloader/run_sdloader_dma_unit.sh` | `22699f68f7b0525a59814b42bde6ae43` | 闸门（自造镜像；rc 0/1/2/3） |
| `sim/sdloader/negctl_sdloader_dma.sh` | `a4c9f608526a86c1b0e6820511b1ed45` | 两条源码变异负对照 + 复原核对 |
| `sim/sdloader/run_unit.sh` | （见 `e53dfcc`） | 改判**本树** + 自造镜像 |
| `y1/gen/DmaEngine.v` / `y1/rtl/DmaEngine.scala` | `4f31e78b…` / 未动 | **一字未改** |

**`.v` 可复现证据**：`REBUILD_JAR=1 bash sim/glue_pbus/gen_glue.sh` 重跑 ⇒ 产物与工作区
`rtl/YeshenSocGlue.v` **逐字节一致**（负对照脚本跑前/跑后的 md5 就是这条证据）。

---

## 11) 回归 rc 表（y1 闸门，全量逐个实跑）

<!--GATE_TABLE-->

---

## 12) 能证 / 不能证

**能证（本轮实测）**
1. **D3 成立**：同一张卡镜像、同一份卡表（目标地址 = 真机 `0x8000_0000` 段），
   "装载器喂引擎"与"装载器直写"的装载结果**逐字节相同**，且都与卡镜像一致（13824 B / 3 表项）。
2. **客户端切换是真的**：通路 B 的 CSR 编程（4 笔/表项）、喂流（1728 拍）、§3.5 的 `OWN_DMA_WR`
   都实测出现；通路 A 三项全 0（直写通路结构性地绕过引擎）。
3. **两条源码级负对照全红**（喂流字节序 / `memSel` 模式门）⇒ 承重处**是被判据钉住的**，
   不是"恰好没被覆盖"；跑完源码与网表**逐字节复原**。
4. **判据自检**（翻一位 ⇒ 逐字节比较报出差异）⇒ 比较器有分辨力。
5. 既有的 6 个胶合/仲裁/DDR 桥装置 + 3 组既有负对照在新网表上**全绿/按期全红**；
   台账 17 站、dangling 0、模块重名 0。

**不能证 / 有条件**
1. **时序与器件面积未测**（无 PnR）⇒ R6 未关闭（§9 给了命令）。胶合网表 +364 行 / +12 679 B。
2. **不是真板/真卡/DDR**：SPI 卡模型与 DDR 是**行为模型**；真 SD 卡时序、真 DDR3Bridge 未验
   （沿用 Phase-0/2a 的口径）。**尤其是**：引擎 28bit 主口与 DDR 桥 `awaddr(29,2)` 的**别名等价**
   是**实读 RTL 推出**的（§2.3），装置里**如实建模**，但**未在真板上用真 DDR 交叉验证**。
3. **网络与相机没接**（§8 给了逐条余量）：网络差"槽泵 + ch1 + 板级出线 + ethAxi 加主人"；
   相机只有通道/CSR 留口。
4. **性能没测**（D6 属 Phase-3）：通路 A/B 的拍数同量级（2.84M），但这**不是**带宽结论
   （SPI 是瓶颈；引擎侧的真实吞吐要 Phase-3 的 D6 口径）。
5. **`memSel` 仍是"一热选通 + 模式门"**，不是真仲裁：装载器（直写通路）与 CPU 组**仍不能同时在飞**
   （P1-C 待办，与 Phase-2b 的裁决一致）。
