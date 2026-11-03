# Y1「NPU 独立时钟域」报告

- spec：`docs/superpowers/specs/2026-10-11-y1-npu-clock-domain-design.md`（§5 G1–G6 / §6 风险）
- 计划：`docs/superpowers/plans/2026-10-11-y1-npu-clock-domain.md`（Task N6）
- 本报告 = **N6 收口**：按判据 **G1–G6** 逐条给证据（§G1–§G6）+ **能证/不能证**；
  N5b 集成明细（接线/桥/面积原始读数）见 **附录 A**。
- ★ **G4（时序）是占位** —— 由控制器**正在跑的 PnR** 填；本任务**不跑 PDS/PnR**，只做
  docs + 回归 + 面积读数 + 软件侧核查。
- 状态：N1/N2/N2b/N3/N4/N5/N5b 已完成；**N6 的 G1/G2/G3/G5/G6 已收口**；**G4 待填**。

### 一句话

**`NpuTop` 已整块跑独立 `npu_clk`（50.000 MHz，第二颗 GTP_GPLL `pll_50m`）；三个对外接口
（主机寄存器窗 AXI4-Lite / 内存主口 AXI4 / IRQ）各一座异步桥、复位一支跨域同步器；
`cpu_clk` 的 `Clock Load` 由 113393 掉到 10687（NPU 不再挂在 cpu 域）。**
判据 G1/G2/G3/G5/G6 全绿；**G4（`All Constraints Met`）待 PnR 填**。

### 判据总表（G1–G6）

| 判据 | 内容 | 状态 | 证据（本报告节 / 出处） |
|---|---|---|---|
| **G1** 两时钟仿真 | 非整数比 cpu100/npu37 驱动，既有数值闸门逐字节不变；负对照发火 | **绿** | §G1；先红 N1 `a83536a` → 绿 N5b `42f0893`；`run_twoclock_ab.sh` = `N5B-OK` |
| **G2** CDC 无丢失/重复 | 主机窗 + 内存口各背靠背 N 笔，出==入且逐字节对；掐短 ⇒ 必红 | **绿** | §G2；`run_axilite_cdc_ab.sh`=`N3-OK`、`run_mem_cdc_ab.sh`=`N4-OK` |
| **G3** IRQ + 复位跨域 | IRQ 电平保持被稳定观测；两域复位释放顺序明确 | **绿** | §G3；`run_irqrst_cdc_ab.sh`=`N5-OK` |
| **G4** 时序（立项目的） | `npu_clk`/`cpu_clk` 各 `All Constraints Met` | **绿** | §G4；PnR `All Constraints Met`（cpu 112.83/@+1.137，npu 54.14/@+1.530） |
| **G5** 回归 | 单元闸门 + C4a 闸门 + 台账 + dangling 全绿 | **绿（离线半）** | §G5；30 闸门 exit 0 + 台账 16 站点 + dangling 0 |
| **G6** 面积 + 软件 | `dev_map` 记 CDC Δ 面积；DTS/驱动无需改 | **绿** | §G6；`devmap_n5b.log`；DTS 核查=**无需改** |

---

## §G1 两时钟闸门（G1）—— **先红 → 绿** 轨迹 + 证据

**装置**：`y1/rtl_test/NpuTwoClockTb.v`（glue 100 MHz + `AxiMemModel` ⊕ `NpuTop` 37 MHz，
非整数比 **100/37 = 2.7027**）+ `y1/tools/run_twoclock_ab.sh`（退出码 0/1/2/3）。

**先红（N1，commit `a83536a`）** —— "CDC 缺失"的负对照基线：
glue + `NpuTop` **异频直连、全程无 CDC**（今天 RTL 的原样）。实测（cpu100/npu37，
`SRC=0x20000 DST=0x60000 IMG_W=256 IMG_H=64 C_IN=8 LEN=131072`）：

```
单时钟：RESULT: PASS、MISMATCH=0、MEM rd=wr=131072 bursts=2048
两时钟：先红 —— 主机第 2 笔寄存器窗访问 RESULT: FAIL timeout ar ready
        拷贝一字未动 MEM rd=wr=0，MISMATCH=131072 @offset 393216
```

⇒ 装置**能**检出缺失的 CDC（装置半成立）。**不修**：CDC 归 N3/N4/N5，时钟拓扑归 N2。

**转绿（N5b，commit `42f0893`）**：三座异步桥（N3/N4/N5）+ `NpuResetSync` 在 **Verilog 层**
接进 TB（与板级**同拓扑**），`NpuTop.clk = npu_clk`；N1 的"先红基线"由此被解掉。

**N6 复跑（2026-10-11，本轮）**：`run_twoclock_ab.sh` = `VERDICT: N5B-OK`。三道对照事实行：

```
[正对照·单时钟 +SAME_CLK]  CLKCFG same_clk=1 cpu100/npu100 ratio=1.0000
                           ID_READ 594e5031  RB_OK  DONE_SEEN=1 ERR_SEEN=0
                           STATUS_POST 00000001  POST_IRQ=1 IRQ_HELD_AFTER_50=1 IRQ_AFTER_ACK=0
                           RESULT: PASS   MEM rd=131072 wr=131072 bursts=2048 maxburst=16
                           单时钟字节对账: MISMATCH=0 FIRST_OFF=-1
[N5b·两时钟 cpu100/npu37]   CLKCFG same_clk=0 cpu100/npu37 ratio=2.7027
                           ID_READ 594e5031  RB_OK  DONE_SEEN=1 ERR_SEEN=0
                           STATUS_POST 00000001  POST_IRQ=1 IRQ_HELD_AFTER_50=1 IRQ_AFTER_ACK=0
                           RESULT: PASS   MEM rd=131072 wr=131072 bursts=2048 maxburst=16
                           两时钟字节对账: MISMATCH=0 FIRST_OFF=-1
                           DETERMINISM[two]=OK（两次日志逐字节相同）
[负对照·两时钟+掐断 AR]      TB: RESULT: FAIL timeout r valid
                           内存侧: MISMATCH=131072 FIRST_OFF=393216
```

判定行：
```
正对照[单时钟]              = 全绿（RESULT: PASS；逐字节 MISMATCH=0）=> harness 本身可信。
N5b[两时钟 100/37 集成]     = 全绿（RESULT: PASS；逐字节 MISMATCH=0；确定性 2×）=> N1 先红基线已解。
负对照[两时钟 + AR 跨域掐断] = 红（TB RESULT: FAIL）=> 闸门能检出被破坏的 CDC。
VERDICT: N5B-OK（单时钟绿 / 两时钟绿 / 负对照红 / 确定性 2×）
```

负对照做法：把 `NpuAxiLiteCdc.v` 拷进 `$work`，python 定点把 `arPipe.io_enq_valid` 改恒 0
（**锚点命中数必须恰好 1**，否则闸门自判 exit 2）⇒ 主机读地址一个都到不了 npu 域。

**G1 结论：绿**（正对照绿 + 两时钟绿 + 负对照发火；N1 先红 → N5b 绿）。

---

## §G2 CDC 判据（G2）—— 主机窗 AXI4-Lite + 内存主口 AXI4

两座桥都由**独立的两时钟装置**驱动（非整数比），逐字节对账 + **三道负对照** + **比较器自检**。

### (a) 主机寄存器窗 AXI4-Lite 异步桥 —— `NpuAxiLiteCdc`（N3，commit `4b05a2f`）

闸门 `y1/tools/run_axilite_cdc_ab.sh`（N6 复跑）：

```
VERDICT: N3-OK（AXI4-Lite 异步桥：跨域无丢失/无重复/字节级正确；三道负对照 + 比较器自检都在承重点上发火）
RESULT: PASS
```

- **正判据**：穷举写/读回，`NPU_W == stim 写序列`（逐元素）、`NPU_R == stim 读序列`、COUNT 全对、
  `HOST_R` 与独立 python 黄金**逐字节 `MISMATCH=0`**、确定性 2× 一致。
- **负对照 3/3 发火**：① wstrb 短接 ⇒ 字节损坏（`MISMATCH>0`，序列仍对）；
  ② AR 掐断 ⇒ 事务丢失（装置红）；③ R 的一次性消费掩码掐掉 ⇒ 读回错位（陈旧载荷，`MISMATCH>0`）。
- **比较器自检** = 恰好 1 笔 / 1 字节（不是橡皮图章）。

### (b) 内存主口 AXI4 异步桥 —— `NpuMemCdc`（N4，commit `d4633b5`）

放在 glue **§3.5 single-outstanding 汇聚点之前**（汇聚点/仲裁**全程 `cpu_clk` 不变**，spec §3-A / R2）。
闸门 `y1/tools/run_mem_cdc_ab.sh`（N6 复跑）：

```
VERDICT: N4-OK（AXI4 内存主口异步桥：跨域无丢失/无重复/字节级正确；三道负对照 + 比较器自检都在承重点上发火）
RESULT: PASS
```

- **正判据**：**背靠背** N 笔块拷贝，出 == 入、数据逐字节对；内存模型 `MEM rd=/wr=/bursts=/maxburst=`
  与**独立 python 黄金**双双相等（**计数 + 数据双判据**，不只比末值）。
- **负对照 3/3 + 比较器自检**（掐短握手/容量 ⇒ 必红）。

**G2 结论：绿**（两桥都证"跨域无丢失/无重复/字节级正确"，且负对照压在跨域承重点上）。

---

## §G3 IRQ + 复位跨域（G3）

**RTL**：`NpuIrqCdc`（2-FF **电平同步** npu→cpu；反向 clear 口不用，清 IRQ 走 `CTRL.soft_reset`
经 AXI4-Lite 桥）、`NpuResetSync`（**异步置位 / 同步释放**；npu 释放被 cpu 的"已就绪"电平
经 2-FF 门住 ⇒ **cpu 先 / npu 后**）。`NpuTop.reset = ~npu_dom_npu_rstn`。

闸门 `y1/tools/run_irqrst_cdc_ab.sh`（N6 复跑）：

```
VERDICT: N5-OK（IRQ 电平跨域保持语义 + 有界延迟 + 同步性；复位按域同步释放且顺序契约 cpu 先/npu 后；…）
RESULT: PASS
```

两时钟 TB 的 IRQ 事实（§G1 内）：`POST_IRQ=1`、`IRQ_HELD_AFTER_50=1`（保持 50 拍不掉）、
`IRQ_AFTER_ACK=0`（ack 后归零）⇒ 电平保持语义不变、被 cpu 域稳定观测。

**G3 结论：绿**（IRQ 电平保持 + 有界延迟 + 复位按域同步释放、顺序契约 cpu 先/npu 后）。

---

## §G4 时序（G4）—— ★ **占位：待控制器 PnR 填**

> **本任务不跑 PDS/PnR**（spec 立项目的 G4 的时序测定由控制器正在跑的 PnR 负责）。

**★ 已填（PDS PnR 实测，2026-10-11）—— `Design Summary : All Constraints Met.`（0 条违例）**

命令：`YESHENMINI_PNR_TAG=npuclk YESHENMINI_SYNTH_MODE=speed pds_shell -file y1/pds/pnr_c4a.tcl`
（工程 `sim/reglogs/pds_pnr_c4a_npuclk_p10.000`；seed 0 即收敛，`UserFilter: 1`）。
读数取自 `…/prj_tasks/pnr_1/place_route/seed_0/report_timing/yeshen_mini_board_top.rtr`：

| 时钟 | 请求 | 估计 | **Slack** |
|---|---|---|---|
| **`cpu_clk`** | 100.000 MHz | **112.829 MHz** | **+1.137** ✅ |
| **`npu_clk`** | 50.000 MHz | **54.142 MHz** | **+1.530** ✅ |
| `core_clk` | 125 MHz | 137.514 | +0.728 ✅ |
| `rgmii_clk` | 125 MHz | 156.642 | +1.616 ✅ |
| `rst_clk` | 125 MHz | 285.307 | +4.495 ✅ |
| `clk_in` | 27.027 MHz | 225.581 | +32.567 ✅ |

`grep -c 'VIOLATED' <rtr>` = **0**。比特流：`…/generate_bitstream/yeshen_mini_board_top.sbit`
**9,188,552 B / md5 `fd52ba8c53ee3f74bba31abb7184b971`**。

**⇒ 立项目的达成**：把 NPU 移出 `cpu_clk` 后，`cpu_clk` **回到 100 MHz 且留 +1.137 ns 余量**
（对照：NPU 同域时 R1/R2/R3b 的 46.74 / 72.53 / 71.40 MHz 都达不到 100）；
`npu_clk` 50 MHz 有 **+1.530 ns** 余量 ⇒ NPU 实际可到 ≈54 MHz。
**注意：这是 PnR 的时序判词（"设计收敛"）；"上板功能验收"（G5 的板级半）仍未重跑**（时机由用户给）。

---

## §G5 回归（G5）—— 离线全套，全绿

**环境**：按计划口径用 venv python（`…/lxvenv/Scripts/python.exe`，Python 3.9.1 + numpy 2.0.2）+
`PYTHONPATH='./.pydeps;../third_party/yunet/deps'`。
（⚠️ 环境坑，非 RTL：若用 `C:\Python314`，`y1/.pydeps` 里 numpy 的 C 扩展版本不匹配 ⇒
`run_convert/dw/desc` 会因 numpy ImportError 假红；换 venv python 即绿。）

### (a) 30 个 `y1/tools/run_*_ab.sh`（含 N1/N3/N4/N5/N5b 闸门）全部 exit 0

```
run_axilite_cdc_ab.sh     exit=0   run_bypass_ab.sh          exit=0   run_chain_ab.sh           exit=0
run_convert_ab.sh         exit=0   run_ddrcopy_ab.sh         exit=0   run_ddrmaster32_ab.sh     exit=0
run_ddrread_ab.sh         exit=0   run_ddrwrite_ab.sh        exit=0   run_desc_ab.sh            exit=0
run_dw_ab.sh              exit=0   run_fuse_ab.sh            exit=0   run_fuse_head_ab.sh       exit=0
run_fusionbuf_ab.sh       exit=0   run_grouped_ab.sh         exit=0   run_hostregs_ab.sh        exit=0
run_irqrst_cdc_ab.sh      exit=0   run_layout_ab.sh          exit=0   run_linebuffer_ab.sh      exit=0
run_macarray_ab.sh        exit=0   run_mem_cdc_ab.sh         exit=0   run_multipass_ab.sh       exit=0
run_nputop_ab.sh          exit=0   run_nputop_sched_ab.sh    exit=0   run_quant_ab.sh           exit=0
run_sched_ab.sh           exit=0   run_tiling_ab.sh          exit=0   run_twoclock_ab.sh        exit=0
run_unitexec_ab.sh        exit=0   run_unitexec_wide_ab.sh   exit=0   run_weightstore_ab.sh     exit=0
```

（`run_numeric_ab.sh` 是**需带参 helper**，按下节单独跑。）

**N 系闸门判词（本轮复跑，逐条）**：
```
run_axilite_cdc_ab.sh  → VERDICT: N3-OK     RESULT: PASS
run_mem_cdc_ab.sh      → VERDICT: N4-OK     RESULT: PASS
run_irqrst_cdc_ab.sh   → VERDICT: N5-OK     RESULT: PASS
run_twoclock_ab.sh     → VERDICT: N5B-OK
```

### (b) 数值 helper（带参）

```
bash tools/run_numeric_ab.sh dense 8 8 16 16 21
  MISMATCH=0
  NEGCTL: ref-vs-ref=0(期望0) ref-vs-wrong(seed=22)=2018(期望>0) one-byte=1(期望1) dut-vs-wrong=2018(期望>0或NA)
  NEGCTL-OK
  === JUDGE-GREEN: 装置 Y 与参考 Y 逐字节一致 ===   exit=0
```

### (c) 地址台账 —— `scripts/check_addr_map.py`

```
PASS: address ledger consistent (16 sites reconciled)          exit=0
```

**台账站点数 = 16**（NPU 窗 `0xF000_C000`/16KiB、IRQ 源 3、PLIC ndev=3 三处承载：
`YeshenSocGlue.scala` / `PlicAlite.scala` / DTS 各就位，逐字相等）。

### (d) 悬空实例 —— `y1/tools/check_dangling.py`（glue + NpuTop + 4 桥）

```
file: rtl/YeshenSocGlue.v      total dangling instances: 0   RESULT: PASS
file: y1/gen/NpuTop.v          total dangling instances: 0   RESULT: PASS
file: y1/gen/NpuAxiLiteCdc.v   total dangling instances: 0   RESULT: PASS
file: y1/gen/NpuMemCdc.v       total dangling instances: 0   RESULT: PASS
file: y1/gen/NpuIrqCdc.v       total dangling instances: 0   RESULT: PASS
file: y1/gen/NpuResetSync.v    total dangling instances: 0   RESULT: PASS
```

### (e) 其余

- 桥网表**确定性 2×**：4 份桥网表两次生成 md5 逐字节相同（N5b 记录，`y1/gen/` 为 gitignore 构建产物）。
- **上板六级验收**：**未跑**（离线任务，见"不能证"）。

**G5 结论：绿（离线半）**。板级半（上板六级）本轮未跑 ⇒ 见"不能证"。

---

## §G6 面积 + 软件（G6）

### (a) 面积 —— `dev_map` 全表 + Δ

**N5b 探针**：`y1/pds/devmap_n5b.log`（PDS 2025.2，`devmap_n5b.tcl`，integrated，含 4 桥 + `pll_50m.v`；
`Design 'yeshen_mini_board_top' has been successfully mapped`；`Y1_N5B_DEVMAP_DONE`）。
`Device Utilization Summary`（**实测**）：

| 资源 | **N5b（现值）** | Available | Util(%) |
|---|---|---|---|
| LUT | **98486.5** | 159800 | 62 |
| FF | **119663** | 319600 | 38 |
| APM | **540** | 740 | 73 |
| DRM | **120** | 415 | 29 |
| Distributed RAM | **1767** | 39500 | 5 |
| IO | **99** | 400 | 25 |
| （附）GPLL | **4** | 10 | 40 |
| （附）PPLL / USCM / RCKB / TSERDES / DDR_PHY | 2 / 6 / 2 / 14 / 7 | — | — |

**基线选择（诚实标注）**：`y1/pds/devmap_c4a.log` **存在，但它不是** R3a/R3b 之后的状态 ——
它是 **C4a.8 的 integrated dev_map**（`Distributed RAM = 10855` / `LUT = 107401`，即"宽层大存储
仍落在 LUTRAM"的**旧**状态）；R3a/R3b 把宽层大存储搬进 block RAM 后 `Distributed RAM` 才降到
**1767**、`DRM` 升到 120。**⇒ 真正的"C4a R3b 集成"面积读数在 `y1/pds/pnr_c4a_r3b.log`**
（该 R3b PnR 的综合面积表）。故本报告给**两组 Δ**：主基线 = **C4a R3b**（`pnr_c4a_r3b.log`），
并给 **N2b**（`devmap_n2b.log`，R3b 之后、**接桥之前**的 dev_map）以**单独隔离"桥 + 第二颗 PLL"的代价**。

| 资源 | C4a.8 dev_map<br>`devmap_c4a.log`（**旧, 非 R3b**） | **C4a R3b**<br>`pnr_c4a_r3b.log` | **N2b**<br>`devmap_n2b.log`（桥前） | **N5b**<br>`devmap_n5b.log`（现值） |
|---|---|---|---|---|
| LUT | 107401 | 101352 | 100076.5 | **98486.5** |
| FF | 114642 | 119094 | 119053 | **119663** |
| APM | 532 | 540 | 540 | **540** |
| DRM | 93.5 | 120 | 120 | **120** |
| Distributed RAM | 10855 | 1767 | 1767 | **1767** |
| IO | 99 | 99 | 99 | **99** |
| GPLL | 3 | 3 | 4 | **4** |

**Δ（N5b − 基线）**：

| 基线 | ΔLUT | ΔFF | ΔAPM | ΔDRM | ΔDistRAM | ΔIO | ΔGPLL |
|---|---|---|---|---|---|---|---|
| **C4a R3b**（真基线） | **−2865.5** | **+569** | 0 | 0 | 0 | 0 | +1 |
| N2b（桥前，隔离桥代价） | **−1589.5** | **+610** | 0 | 0 | 0 | 0 | 0 |
| C4a.8 dev_map（旧，仅备查） | −8914.5 | +5021 | +8 | +26.5 | −9088 | 0 | +1 |

**读数解读（实测 vs 推断，标注）**：
- **第二颗 PLL（`pll_50m` GTP_GPLL）的代价 = 1 个 GPLL 硬宏**（GPLL **3→4**），**不占 FF/LUT**
  （N2b 引入；N5b 沿用）。——**实测**（utilization 行）。
- **三座异步桥 + `NpuResetSync` 的代价 ≈ FF +610 / LUT −1589.5**（N2b→N5b **实测**）：
  FF 增 = 桥内 CDC 打拍寄存器 + 复位同步器；LUT **反降**是**推断**（NPU 换域后时序驱动的映射
  不同 ⇒ 不再为 cpu_clk 收敛做那么重的复制/展开），**非**"桥不占逻辑"的结论。
- APM / DRM / Distributed RAM / IO **零增**：CDC 全在**寄存器/逻辑**里，不消耗 DSP、块 RAM、
  LUTRAM 或引脚（**实测**）。

### (b) 软件 —— DTS / 驱动 / 装载器：**无需改**

核查对象：`sw/buildroot-external/boards/naxmini/linux/linux_raw.dts` 的 `npu@f000c000` 节点
（第 186–192 行）与任何触碰 NPU 的软件。

```dts
npu@f000c000 {
    compatible = "y1,yunet-npu";
    reg = <0xf000c000 0x4000>;     // 16 KiB = 胶合 NPU_MASK 0xFFFF_C000 的窗
    interrupt-parent = <&plic>;
    interrupts = <3>;
    status = "okay";
};
```

**判定：no change needed（无需改）**，理由（逐条）：
1. **NPU 是自计时的（self-timed）**：主机只"编描述符 + 起 `CTRL.go` + 等 IRQ/`CTRL.done`"，
   软件**不**依赖"NPU 一个周期 = CPU 一个周期"的任何时序关系 ⇒ 换钟源/换频率对软件透明。
2. **DTS 里没有时钟耦合**：`npu@` 节点**无** `clocks` / `clock-frequency` 属性（全文 DTS 里
   `clock-frequency` 只出现在 serial 节点，与本变更无关）⇒ 不存在"DTS 里写着 cpu_clk"要改。
3. **寄存器契约与地址窗不变**：N5b 只在 glue 边界插桥，NPU 的 AXI4-Lite 窗
   （`0xF000_C000`/16 KiB）与寄存器语义**一字未改** ⇒ `reg = <0xf000c000 0x4000>` 仍精确。
4. **中断号与语义不变**：仍 PLIC **源 3**、仍**电平保持**（写 `CTRL.soft_reset` 清）、`riscv,ndev` 仍 3
   ⇒ `interrupts = <3>` 无需改。
5. **无 Linux 驱动**：本版 NPU **没有内核驱动**（用户态 mmap `/dev/mem` 直接编程，见 `y1/tools/`）；
   板上对 NPU 的软件（`y1/tools/npu_board_test.py` / `npu_board_conv.py` / `npu_copy_probe.py`）
   **不出现**任何 `clock`/`freq`/`npu_clk` 引用 ⇒ 无可改处。
6. **台账佐证**：`scripts/check_addr_map.py` = `PASS（16 sites reconciled）` ⇒ 地址/中断的"唯一真源"
   与 DTS 逐字相等，没漂移。

**G6 结论：绿**（面积已记 Δ，第二颗 PLL = 1 GPLL；桥 ≈ FF +610 / LUT −1589.5；DTS/驱动**无需改**）。

---

## 能证 / 不能证

**能证（有本轮可复跑证据）**：
- **G1**：非整数比两时钟下，N5b 集成后**逐字节对账通过**（单时钟/两时钟均 `MISMATCH=0`、确定性 2×），
  且**负对照（掐断 AR）发火** ⇒ N1 的"先红基线"确实是被桥解掉的（不是橡皮图章）。
- **G2**：主机窗 + 内存口两桥**跨域无丢失/无重复/字节级正确**，各自三道负对照 + 比较器自检发火。
- **G3**：IRQ 电平保持被 cpu 域稳定观测（`IRQ_HELD_AFTER_50=1`、ack 后归零），复位按域同步释放、
  顺序契约 cpu 先/npu 后（闸门 `N5-OK`）。
- **G5（离线半）**：**30 个单元/集成闸门 exit 0** + 数值 helper `JUDGE-GREEN` + 台账 **16 站点** +
  dangling **0**。
- **G6**：`N5b` 面积读数（实测）；CDC/桥与第二颗 PLL 的 Δ；DTS/驱动**无需改**（实测核查）。
- **G4 的结构面**：NPU 已整块跑 `npu_clk`（`Clock Load 103322`、独立根钟），`cpu_clk` load
  113393→10687。

**不能证（诚实标注 —— 本轮或本仓不覆盖）**：
- **G4 的时序面（`All Constraints Met`）**：本任务**不跑 PnR** ⇒ 未得。**占位**见 §G4，
  **由控制器**用 `pnr_c4a.tcl`（源清单已含桥 + `pll_50m`）填 `npu_clk@50MHz` / `cpu_clk@100MHz`
  两条判词。
- **上板六级验收（G5 的板级半）**：离线，**未跑**（时机由用户给）。`run_twoclock_ab.sh` 与
  `dev_map` 只证"结构 + 行为 + 可映射"，**不**等于上板通过。
- **C5 帧率 / 性能**：本报告**只记结构性代价，不报帧率**（C5 归 C5）。
- **桥的物理效应（亚稳态/MTBF/SETF）**：仿真（零延迟）证不了 ⇒ 留 PnR 时序报告与上板。

**性能代价的诚实记录（供 C5 合账）**：
- N4/内存口桥是 spec §4.4 裁决的 **beat-serialized（单拍一手握）CDC** ⇒ 块拷贝比"直连"慢约
  **4×**（实测，N5b note：单时钟 **~4150 ns / 16 拍突发** vs 两时钟 **~6270 ns**）。
- 128 KiB 拷贝经两座桥约需 **8~13 ms**（直连约 **2 ms**）。这是"慢但简单"的**预期代价**
  （瓶颈在跨域握手往返，不在拍级带宽）。
- ★ **对帧率的影响 flagged for C5**：NPU 现跑 **50 MHz**（cpu_clk 的 1/2），且内存主口经全握手桥
  ⇒ **块拷贝吞吐与 NPU 时钟频率双双下降**，C5 帧率口径**必须**把这两项计入（本报告不下帧率结论）。

**假设 / 注意**：
- 附录 A 记有 N5b 的接线/桥重名修复/`devmap` 探针细节与旧诊断（"glue 侧 32b 零扩展"旧说、
  `devmap_n2/n2b.tcl` 是当时快照等），以**附录 A 与现行网表**为准。
- 本报告所有 PDS 读数取自**已提交的 N5b 那版 RTL**（`y1/pds/devmap_n5b.log`）；N6 未改动 RTL/board，
  无需重跑 PDS。**G4** 若 PnR 发现需改 RTL，则 G1/G2/G3/G5/G6 的回归需按"改 RTL 就重跑"纪律再来一遍。

---

## 附录 A：§N5b 集成明细（2026-10-11，commit `42f0893`）—— 三桥 + reset sync 接进板级 SoC，`NpuTop` 搬 `npu_clk`

### 一句话

**把 N3/N4/N5 的三座异步桥 + `NpuResetSync` 在 Verilog 层接进 `board/yeshen_mini_soc.v`，
`NpuTop` 整块改跑 `npu_clk`（50MHz 独立钟），删掉 `npu_clk_alive` 脚手架；
`run_twoclock_ab.sh` 由"先红"转 **GREEN**（单时钟绿 / 两时钟绿 / 负对照红）。
glue 的 Chisel 未改、§3.5 汇聚点全程 `cpu_clk` 不变。**

### 交付状态

| 项 | 结果 |
|---|---|
| `NpuTop.clk` | = `npu_clk`（50MHz 独立域）；`.reset = ~npuRstn`（npu 域同步释放，cpu 先/npu 后） |
| 三座桥 + reset sync | 板级 Verilog 例化（`u_npu_axilite_cdc` / `u_npu_mem_cdc` / `u_npu_irq_cdc` / `u_npu_rst_sync`） |
| `npu_clk_alive` 脚手架 | **已删**（SoC 端口 + `npu_clk_alive_r` + 板级诊断 `<npu>` 字节；诊断帧回到 8 字节） |
| PDS 源清单 | `devmap_c4a.tcl` / `pnr_c4a.tcl` 加 `pll_50m.v` + 4 份桥网表；新增 `devmap_n5b.tcl` 探针 |
| 两时钟闸门 | **GREEN**（`VERDICT: N5B-OK`，见下） |
| 回归 | 29 个 `run_*_ab.sh` 全绿 + 台账 PASS + dangling PASS + netlist 确定性 2× |
| dev_map 探针 | `npu_clk` **Declared / 独立根钟 / Clock Load 103322**（N2b 时 =1）；`cpu_clk` load 113393→10687 |

### 1) 接线（哪根信号跨到哪去）

`board/yeshen_mini_soc.v`（glue 的 Chisel 一字未改；**在 Verilog 层**例化桥网表）：

| 路 | cpu_clk 侧（glue / 汇聚点，全程不变） | 桥 | npu_clk 侧（NpuTop） |
|---|---|---|---|
| (a) 主机寄存器窗 AXI4-Lite | `glue.io_npuAxi_*`（本层网名 `npuAxi_*`） | `NpuAxiLiteCdc` | `io_npu_axilite_*` → `NpuTop.axilite_*`（`npuAxi2_*`） |
| (b) 内存主口 AXI4（28b/64b/id4） | `glue.io_npuMem_*`（本层网名 `npuMem_*`，喂 §3.5 汇聚点） | `NpuMemCdc` | `io.npuMem_*` → `NpuTop.axi_*`（`npuMem2_*`） |
| (c) IRQ（电平保持） | `glue.io_npuIrq`（= PLIC 源 3） | `NpuIrqCdc`（2-FF） | `NpuTop.irq`（本层网名 `npu_irq`） |
| (d) 复位 | `async_reset \| cpu_reset`（异步置位源） | `NpuResetSync` | `~npuRstn` → `NpuTop.reset` |

- 桥的时钟/复位：`cpuClk=soc_clk / cpuRstn=npu_dom_cpu_rstn`；`npuClk=npu_clk / npuRstn=npu_dom_npu_rstn`。
- **复位释放顺序**：`NpuResetSync` 产两域低有效复位（异步置位 / 同步释放），npu 释放被 cpu 的"已就绪"
  电平经 2-FF 门住 ⇒ **npu 必然晚于 cpu 释放**。`NpuTop.reset = ~npu_dom_npu_rstn`（同步、高有效，与
  NPU 网表 R3-4 起的同步复位口同语义）。
- `io_asyncRst = async_reset | cpu_reset`：沿用旧口径"装载期把 NPU 也扣住"（`cpu_reset` 是 cpu 域电平，
  作**异步置位源**合规 —— 释放仍由同步器对齐）。
- `NpuIrqCdc.io_cpuClearReq` 恒 0（反向口不用）：清 IRQ 走 `CTRL.soft_reset`，一次寄存器写经 (a) 的
  AXI4-Lite 桥跨到 npu 域。

**桥网表重名修复（集成期发现并修）**：`NpuAxiLiteCdc.v` 与 `NpuMemCdc.v` **各自**都定义了
`CdcPipeSp`/`_1`/`_2`/`_4`（端口形状不同）—— 单文件各自落盘时无恙，但同处一个设计时 iverilog/PDS 报
"already declared"。修法：`CdcPipeSp` 定义名参数化（`defName`），N4 传 `NpuMemCdcPipe{Addr,W,B,R}` ⇒
两座桥子模块名**全局唯一**；N3（NpuAxiLiteCdc）用默认（自动命名，网表接口/行为不变）。**重生成 4 份网表**
（NpuAxiLiteCdc/NpuMemCdc 受影响，NpuIrqCdc/NpuResetSync 逐字节不变）。

### 2) `run_twoclock_ab.sh` 判词（现在 GREEN）

```
verdict: N5B-OK（单时钟绿 / 两时钟绿 / 负对照红 / 确定性 2×）
```

事实行（`two_1.log`，cpu100/npu37 非整数比 2.7027）：

```
CLKCFG same_clk=0 cpu_clk=100.000MHz npu_clk=37.000MHz ratio_cpu_over_npu=2.7027
ID_READ 594e5031
RB_OK
DONE_SEEN=1 ERR_SEEN=0
STATUS_POST 00000001
POST_IRQ=1
IRQ_HELD_AFTER_50=1
IRQ_AFTER_ACK=0
RESULT: PASS
MEM rd=131072 wr=131072 bursts=2048 maxburst=16
```

三道对照：
- **正对照（单时钟）**：`RESULT: PASS`，导出镜像 vs 黄金 `MISMATCH=0`。
- **N5b（两时钟）**：`RESULT: PASS`，`MISMATCH=0`，确定性 2×（两次日志逐字节相同）。
- **负对照（两时钟 + 掐断 AR 跨域）**：`RESULT: FAIL timeout r valid`（读地址到不了 npu 域）⇒ **红** = 闸门能检出被破坏的 CDC。

### 3) dev_map 探针证据（`y1/pds/devmap_n5b.log`）

工具：PDS 2025.2 / `devmap_n5b.tcl`（integrated，含 4 份桥网表 + `pll_50m.v`）。
`Design 'yeshen_mini_board_top' has been successfully mapped`；`Y1_N5B_DEVMAP_DONE`。

**约束检查**（与 N2b 对比，无回归）：

```
Found 0 error(s), 0 critical warning(s), 20 warning(s), out of 696 constraint(s)
```

（条数 **696 = N2b**，N5b 一个约束都没加 —— `npu_clk` 早就是独立 `create_clock`。
两条 `Timing-4120 … should be a generated clock`（line 113 cpu_clk / line 151 npu_clk）是**提示级**，非 error。）

**时钟表**（`synthesize_report_timing_clock_summary.db`）：

```
cpu_clk  Declared  10.0000ns  100.0000MHz  Clock Load 10687   Source={ u_pll/u_gpll/CLKOUT0 }
npu_clk  Declared  20.0000ns   50.0000MHz  Clock Load 103322  Source={ u_pll_npu/u_gpll/CLKOUT0 }
```

⇒ **两钟同时在列**（100.000 / 50.000MHz），`npu_clk` 的 `Type = Declared`（**独立根钟**，
不是 Generated/Source=cpu_clk）。
★ **N2b → N5b 的关键读数**：`npu_clk` 的 `Clock Load` 由 **1**（那只防悬空脚手架寄存器）
→ **103322**（整块 NpuTop 域的真实扇出）；`cpu_clk` 的 `Clock Load` 由 **113393** → **10687**
（NPU 不再挂 cpu_clk）——这就是"NPU 搬出 cpu 域"的直接证据（G4 的结构面）。

**device_map 时钟网**（`device_map_clock_signal.db`）：

```
Driver_Pin CLKOUT0 | Clk_Source_Inst u_pll_npu/u_gpll | Clk_Inst_Name u_npuclk_bufg | Net_Name npu_clk | Fanout 103322
Driver_Pin CLKOUT0 | Clk_Source_Inst u_pll/u_gpll     | Clk_Inst_Name clkbufg_44    | Net_Name ntclkbufg_0 | Fanout 10686
```

⇒ 第二颗 PLL + BUFG 都在网表里活着，`npu_clk` 被工具认成一根**时钟网**且**扇出 103322**（真负载）。

**面积（Device Utilization Summary）**：

| 资源 | N2b | **N5b** | Δ |
|---|---|---|---|
| APM | 540 | 540 | 0 |
| FF | 119053 | **119663** | +610 |
| LUT | 100076 | **98486.5** | −1589.5 |
| Distributed RAM | 1767 | 1767 | 0 |
| DRM | 120 | 120 | 0 |
| IO | 99 | 99 | 0 |

Δ 主要来自三座桥的 CDC 寄存器 + 复位同步器（FF +610）；LUT 反而略降（NPU 换域后映射不同）。
第二颗 GPLL 是硬宏（GPLL 4/10，不占 FF/LUT）。

### 4) 回归 / 其它闸门

| 项 | 结果 |
|---|---|
| 29 个 `y1/tools/run_*_ab.sh` | **全 exit 0**（N1 的 `run_twoclock_ab.sh` 另跑 GREEN；`run_numeric_ab.sh` 是需带参 helper）——★ **N6 已复跑并刷新为 30 个全绿，见 §G5** |
| `scripts/check_addr_map.py` | `PASS: address ledger consistent (16 sites reconciled)` |
| `y1/tools/check_dangling.py`（glue + NpuTop + 4 桥） | 全部 `RESULT: PASS`（0 悬空） |
| netlist 确定性 2× | 4 份桥网表两次生成 md5 逐字节相同 |
| 上板六级验收 | **未跑**（离线任务；本任务不做板级重跑，见下"能否证"） |

其中 3 座桥的独立闸门（N3/N4/N5 单元级）在本次重生成后仍绿：
`run_axilite_cdc_ab.sh` = N3-OK、`run_mem_cdc_ab.sh` = N4-OK、`run_irqrst_cdc_ab.sh` = N5-OK。

### 5) 变更文件（md5）

| 文件 | md5 | 说明 |
|---|---|---|
| `board/yeshen_mini_soc.v` | `8084f7849d0fa09de0f00088c3f42e12` | 桥 + reset sync 例化；NpuTop→npu_clk；删脚手架 |
| `board/yeshen_mini_board_top.v` | `c34a19ba8fbd495b8975b285457c3693` | 删 `npu_clk_alive` 接线 + 诊断帧回 8 字节 |
| `board/pll_50m.v` | `d8c17a16f66e677e4e74fbd5e3669bf7` | 头注释追加 N5b 说明（参数/端口未改） |
| `constraints/yeshen_mini.fdc` | `51f7d2fe5fbfacd01b0bc3b811928a3b` | N2 段注释更新（约束一字未改） |
| `y1/rtl/NpuAxiLiteCdc.scala` | `a92608d84ff443feec14c6827abd4d5d` | `CdcPipeSp` 定义名参数化（N3 用默认） |
| `y1/rtl/NpuMemCdc.scala` | `e687a468686796d4e825dbb2d42ec14e` | 5 管道传 `NpuMemCdcPipe*` 唯一定义名 |
| `y1/rtl_test/NpuTwoClockTb.v` | `46681fafd419ea5880a51edfeda6695a` | 接 4 桥（与板级同拓扑）；看门狗 2ms→30ms |
| `y1/tools/run_twoclock_ab.sh` | `731cfab019ab27f9f44ea3758aff76d5` | 由"先红"改为"两时钟绿 + 掐断 AR 负对照" |
| `y1/tools/run_mem_cdc_ab.sh` | `82490e0d08e21291d7e9c0d7212d40b6` | NEG-C 自寻址正则改为通用（不再假设 `CdcPipeSp` 前缀） |
| `y1/pds/devmap_c4a.tcl` | `58b30ec1f22978259a13c35929ac1d40` | 源清单加 `pll_50m.v` + 4 桥 |
| `y1/pds/pnr_c4a.tcl` | `102ca1a916792384dfbc46d1063be074` | 源清单加 `pll_50m.v` + 4 桥 |
| `y1/pds/devmap_n5b.tcl` | `fc79a76851e22f71dc62b90af74252fa` | **新增** N5b 探针 |
| spec / plan | `df89f18c…` / `eeac4afb…` | 追加 N5b 集成结果 |

生成物（`y1/gen/` 是 .gitignore 的构建产物，非入库文件）：
`NpuAxiLiteCdc.v 95494d0b…` / `NpuMemCdc.v f77e102d…` / `NpuIrqCdc.v 16c67238…` /
`NpuResetSync.v 83efc1b9…` / `NpuTop.v d95a71d9…`（NpuTop 本轮未改）。

### 6) 能证 / 不能证 + 假设与注意

**能证**：
- `NpuTop` 确实整块跑 `npu_clk`（时钟表 `npu_clk Clock Load 103322`、device_map 扇出 103322）。
- 三座桥 + reset sync 接线正确：两时钟 TB（非整数比）逐字节对账 + 确定性 2× + 负对照发火。
- **N1 先红基线已解**：异频直连必红的两个接口（主窗 + 内存口）在集成后逐字节对账通过。
- `cpu_clk` 不再承载 NPU（load 113393→10687）——G4 的结构面达成。

**不能证（诚实标注）**：
- **时序**（G4 的时序面 / `All Constraints Met`）：本任务**不跑 PnR**（只做 `dev_map` 探针）⇒ 未得。
  ★ **N6 亦不跑 PnR**（只做 docs + 回归 + 面积读数）⇒ 该判词仍缺，**占位见 §G4**
  （由控制器的 PnR 用 `pnr_c4a.tcl` 填，源清单已含桥）。
- **上板六级验收**（G5 的板级半）：离线，未跑；`run_twoclock_ab.sh` 与 dev_map 只证"结构 + 行为 + 可映射"。
- **帧率 / 性能**：桥是 spec §4.4 裁决的 **beat-serialized**（单拍一手握）CDC ⇒ 块拷贝比直连慢约 **4×**
  （实测单时钟 ~4150 ns / 16 拍突发、两时钟 ~6270 ns；128 KiB 拷贝经两桥 ~8~13 ms，直连 ~2 ms）。
  这是**预期代价**（桥吞吐瓶颈在跨域握手往返），对帧率的影响留给 N6/C5 合账。
- 桥的**亚稳态/SETF 类物理效应**：仿真（零延迟）证不了，留给 PnR 时序报告与上板。

**假设 / 注意**：
- `glue.io_npuMem_awaddr` 实测是 **28bit**（与 NpuTop.axi_*、桥 cpuMem_* 同宽）⇒ **无需零扩展**
  （NpuMemCdc.scala 头注释里"glue 侧 32b + 零扩展"的旧说法与现行 glue 网表不符，以网表为准）。
- `devmap_n2b.tcl` / `devmap_n2.tcl` 是 N2/N2b 的**当时快照探针**，**未**随 N5b 更新（其头注释记录当时的
  读数）；N5b 的权威探针是 `devmap_n5b.tcl`，维护流是 `devmap_c4a.tcl` / `pnr_c4a.tcl`。
- 复位：`io_asyncRst = async_reset | cpu_reset`（装载期扣住 NPU）；`cpu_reset` 作异步置位源是合规用法。

---

## ★ 附录 B：上板重验（2026-10-11，NPU 已在自己时钟域）—— **六级核心全过**

带：`sim/reglogs/pds_pnr_c4a_npuclk_p10.000/…/yeshen_mini_board_top.sbit`（9,188,552 B，`All Constraints Met`）。
烧写 + 启动：`python -u scripts/flash_and_verify.py --tag pnr_c4a_npuclk --com COM7 --secs 180 --no-net`
⇒ `done bit = 1`；8 个启动 marker **全 `[ok]`**（SD 装载/SDR 帧 → OpenSBI banner → `Linux version` →
LiteEth → dropbear → 用户态 marker → 登录提示符）。
（脚本末尾抛 `UnicodeEncodeError: 'gbk' … '\u21d2'` —— 只是它往 GBK 控制台打 `⇒` 的美化问题，
**判据本身全绿**；正是本项目记过的 Windows-GBK 坑。）

| 级 | 判据 | 结果 |
|---|---|---|
| ① 启动（8 marker） | 见上 | ✅ |
| ② NPU 寄存器窗**可读**（**经新的 AXI4-Lite CDC 桥**） | `devmem 0xF000C030 32` → **`0x594E5031`** | ✅ |
| ⑤ **MaxPool 端到端**（无需权重） | `npu_board_test.py`：word 32/32，**`MISMATCH=0`**，`RESULT: PASS` | ✅ |
| ⑥ **conv3x3 dense 端到端**（**576 B 权重经信箱**） | `npu_board_conv.py`：word 128/128，**`MISMATCH=0`**，`RESULT: PASS` | ✅ |

⇒ **NPU 独立时钟域改造在板上功能与改前一致**（`cpu_clk`/`npu_clk` 两域 + 三处 CDC 一起跑通，
含带权重的卷积整层）。**已证**：时钟域拆分 + CDC 在真实硬件上不破坏 NPU 功能。
**未证**（诚实项）：CDC 的亚稳态/MTBF 类物理指标（仿真与功能测试都测不了，需专用 CDC 分析）；
整帧 YuNet 与帧率（C4b/C5）；内存桥 beat-serialized 的吞吐代价（C5 合账）。
