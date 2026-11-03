# Y1-DMA **Phase-0** 判词 —— **DDR 桥放开多未完成**（承重前提）

- 日期：2026-10-13
- 上游：`docs/superpowers/specs/2026-10-13-y1-soc-dma-engine-design.md`（§2 家底、**§3.1 裁决=C + 四相顺序**、§5 D1–D6、§6 R5/R6）、
  `docs/superpowers/plans/2026-10-13-y1-soc-dma-engine.md` **Phase 0（T0.1–T0.5）**
- 交付：`src/soc/DDR3Bridge.scala`、`src/soc/CDCQueue.scala`、`sim/ddr3bridge/*`、`rtl/DDR3Bridge.v`（重生成）
- 本轮**不跑 PDS / PnR**（按任务口径：控制器跑 PnR）⇒ 面积/时序只给**网表级口径 + 待跑的精确命令**，不含板级 dev_map 读数。

---

## 0) ★ Gate-P0 判词（先给结论）

> **能。** DDR 侧**可以**多未完成：同一份 TB、同一份 IP 行为模型下，DUT **自报**的未完成峰值
> 达到 **4（写）/ 4（读）/ 4+4（混）= `DEPTH`**，而把 `LANES/DEPTH` 打成 1 的负对照（NC6）**必然掉回 1**
> —— 即"未完成 > 1"是**可观测、可复现、且被深度参数结构性地守住**的，不是推断。
>
> **放开的收益（实测，同装置同用例 A/B）**：
>
> | 背靠背作业（8×32 B 或 4W+4R） | 单未完成档 `LANES=DEPTH=1` | 交付档 `LANES=DEPTH=4` | 增益 |
> |---|---|---|---|
> | 写-only 8 笔（256 B） | 151 cyc = **0.590 cyc/B** = 170 MB/s | 59 cyc = **0.230 cyc/B** = **434 MB/s** | **2.56×** |
> | 读-only 8 笔（256 B） | 144 cyc = **0.562 cyc/B** = 178 MB/s | 45 cyc = **0.176 cyc/B** = **569 MB/s** | **3.20×** |
> | 读写混（4+4 笔） | 76 cyc = 0.297 cyc/B = 337 MB/s | 36 cyc = **0.141 cyc/B** = **711 MB/s** | **2.11×** |
>
> **新的上限在哪**：不在 DDR IP（单 beat 节拍 1 拍/125 MHz = 4 GB/s），也不在地址语义（一字未改）；
> 而是**跨域通道的道数/往返**与 **AXI 从口本身**。AXI 从口 64 bit @100 MHz 的算术上限 = **8 B/cyc = 800 MB/s**；
> 交付档实测写 4.35 B/cyc（54%）、读 5.7 B/cyc（71%）⇒ **还有 ~1.4–1.8× 余量**（加 `LANES` 或加宽 CDC 载荷即可，不是架构问题）。
>
> **代价**：桥的网表级 FF 位宽 **2498 → 8342**（**+5844 FF**，+234%），模块数 5 → 14，交付网表 21 990 → 62 734 B。
> 折成器件占比 ≈ **+1.8% FF**（器件 319 600 FF；板级现用 113 382 = 36%）。**时序未测（本轮无 PnR）** ⇒
> R6 的"桥放开后时序/面积恶化"**尚未关闭**，必须由控制器那次 dev_map/PnR 收（命令见 §6）。
>
> **建议**：**继续 Phase-1**（§3.5 真仲裁）。理由是速度收益**实测成立且有余量**，且**没有动 DDR IP 的对外口、
> 没有动地址语义**（R1/R2 两条红线逐条守住，见 §2）。若 PnR 回来说 CLMA 越线，**不是**退回 A 口径的理由
> （A 口径的速度上限更低），而是把 `LANES/DEPTH` 降档（4→2）——本轮已把这件事做成**两个 `private val`**。

---

## 1) T0.1 冻结的两条红线（改前改后逐条成立）

写进 `src/soc/DDR3Bridge.scala` 文件头（"本轮两条**不变**的红线"）：

- **R1 DDR IP 对外端口一字不改**：`io_ddrAwAddr/ddrAwLen/ddrAwValid/ddrAwReady`、`io_ddrWData/ddrWStrb/ddrWReady`、
  `io_ddrArAddr/ddrArLen/ddrArValid/ddrArReady`、`io_ddrRData/ddrRValid/ddrRLast` —— 名字/方向/位宽全部原样。
  板级 `board/yeshen_mini_board_top.v` 与紫光 DDR3 IP 的装配**未动一个字符**（本轮新增的 4 个观察口是
  **输出**且板级用**具名端口**例化 ⇒ 不接即合法，见 §2.3）。
- **R2 地址语义一字不改**：① 每笔 AXI 突发首址 **32 B 对齐**（`awaddr(29,2)` = 32 bit 字地址）；
  ② 每笔 DDR 事务地址递进 = **+8 个 32 bit 字 = 32 B**（DDR 侧单位是 32 bit 字）；③ 一笔 DDR 事务只发
  **1 个 256 bit beat**（`ddrAwLen/ddrArLen` 恒 0）。**NC3**（`+ 8.U` → `+ 4.U`）本轮**重锚后仍然翻红**（§4）。
- 同时冻结的两条"**改前**的限制"（L1 单 outstanding；L2 `ceil(beats/4)` 单 beat 拆分）与由此踩过的
  两个真坑（`wItemTaken`/`rItemTaken`）也逐条写进了文件头。

---

## 2) T0.2 怎么放开的（实现）

### 2.1 新原语：`CdcFifo`（`src/soc/CDCQueue.scala`，`CDCPipe` **一字未改**）

```
源域环形 FIFO(depth) ──轮转派发──> [CDCPipe]×lanes ──按序回取──> 目的域环形 FIFO(depth)
```
- 顺序靠两条纪律：**① 不跳道**（第 L 道没空就等，绝不提前用第 L+1 道）；**② 每条 CDCPipe 一次只挂 1 份**。
- 稳态吞吐 ≈ `lanes` × 单条 `CDCPipe`；目的域攒着多份 ⇒ DDR 侧可**背靠背**发单 beat。
- `lanes = depth = 1` ⇒ **逐字退化成改前的单未完成形态**（NC6 就打这两行）。

### 2.2 每条通道（AW / W / AR / R + 写完成 token）各一条 `CdcFifo`

| 通道 | 方向 | 载荷 | `lanes` | `depth` |
|---|---|---|---|---|
| AW（`AwBeat`） | axi → ddr | 本 beat 的 28 bit word 地址 | 4 | 4 |
| W（`WBeat`） | axi → ddr | 256 bit 数据 + 32 bit `wstrb` + 4 bit `awid` + `last` | 4 | 4 |
| AR（`ArBeat`） | axi → ddr | 28 bit word 地址 | 4 | 4 |
| R | ddr → axi | 256 bit 数据 | 4 | 4 |
| done | ddr → axi | 4 bit `awid`（B 回带） | 4 | 4 |

- **分组语义（`GRP_BEATS`=4 / 32 B）落在 axi 侧**：仍按 4 拍聚合成一个 32 B 组（残组未用 lane 的 `wstrb`
  **必须清零**，判据仍钉着）；`AwCmd.groups` **取消**——axi 侧改成**按 beat 推命令**（每组 1 条 AW + 1 份 W），
  ddr 侧只需"AW 队列非空就发一笔单 beat 事务、`wready` 高就取下一份 W"。
- **AXI 侧看到的仍是完整突发**：`wlast` 在每笔末拍、B 每笔恰一次且回带本笔 `awid`、`rlast` 在每笔末拍、
  `rid` = 本笔 `arid` —— 与改前逐条相同（既有 8 条用例原样守）。
- **未完成容量 = `DEPTH`，且被 AXI 口的信用计数守住**（**可证**，不是"看起来能到 2"）：
  `axi.aw.awready := enq.ready && (outW < DEPTH)`、`axi.ar.arready := … && (outR < DEPTH)`，
  其中 `outW` = AW 已收 − B 已回、`outR` = AR 已收 − rlast 已回。
  ⚠️ 信用必须**同时**掐 `enq.valid` 与 `awready`（只掐 `awready` 时，主方把 `awvalid` 挂高会让内部队列
  **每拍都推进**，信用形同虚设、`outW` 绕圈 —— 这正是本轮开发中实测到的一个真 bug，已修并写进注释）。
- **W 通道没有 `wvalid`** 这件事用**不变式**兜住：ddr 侧 **AW 队列占用 ≤ W 队列占用**（两条队列同刻同序推入，
  AW 每发一笔 −1、W 每 `wready` −1）⇒「AW 队列非空」必然蕴含"这份 W 数据已在 ddr 域"，IP 采样那一拍数据一定对。
- **R 通道没有 `rready`** 用**信用**兜住：`inflightAR + rCdc.sOcc ≤ DEPTH` 才发 AR ⇒ 每拍回来的 R 一定收得下
  （改前是"发 AR 前要求 `enq.ready`"，同样思想，但只允许 1 笔在飞）。

### 2.3 两个真坑：**用结构消掉，不用 flag 兜**

改前的 `wItemTaken`/`rItemTaken`（"本次呈现已取用"）现在**搬进 `CdcFifo`**（每条道一个 `dTaken`），
而且对外的 `deq` 是**真 FIFO 口**（`valid`/`bits` 稳定、`ready` 弹出）⇒ `DDR3Bridge` 里**不再有**
`wItemTaken`/`rItemTaken`/`rFresh` 这类标志，"取到旧呈现"在结构上不可能。

**诚实标注一条**：`dTaken` 的相对 `dLane` 轮转是**冗余的一道保险**——NC2 最初就打在"摘掉 `dTaken` 置位"上，
**不发火**（因为道号轮转已经先一步挡住重复收取）。因此 NC2 改锚到**轮转纪律本身**（§4）。

**★ NC6 当场抓出一个真 bug**：`lanes=1` 时 `LW = max(1, log2Ceil(1)) = 1` 位，道号 `+1` 会走到 1 ⇒
没有任何一条道命中 `sLane === i.U` ⇒ 源队列永不排空 = **挂死**（实测：既有用例 1 就卡死）。
修法：道号**按 `lanes` 取模**（`& (lanes-1)`）。⇒ `lanes=1` 档因此从"挂死"变成**功能正确但单未完成**，
NC6 的判词才是它该有的样子（见 §4）。

### 2.4 只读观察口（证据口）

`io.dbgOutW/dbgOutR`（当前未完成笔数）+ `io.dbgMaxOutW/dbgMaxOutR`（高水位），4 个 **输出**口。
板级 `board/yeshen_mini_board_top.v` 是**具名端口**例化 ⇒ 新增输出口不接线合法，**板级一字不改**；
PnR 里它们会被当悬空输出裁掉（不影响功能）。

---

## 3) T0.3 判据（先红后绿）

`sim/ddr3bridge/tb_ddrbridge.cpp` 的**既有判据一条没松**（8 条用例：整组读写往返逐字节 / 跨两组 64 B /
部分 `wstrb` / 残组 / `rlast` 位置 / B 恰一次 / **B id 回带**），并新增：

### 3.1 DDR IP 行为模型升级（多未完成**必须能被观察**）

改前的模型 `ipState` **一次只认一笔事务**（AW 收下必须等 W 吃完才回 idle）⇒ 桥就算真能多未完成也观察不到
（判据会变成"测模型"）。新模型照真 IP 的样子建模：**AW/AR 各带命令队列**（`AWDEPTH=ARDEPTH=4`）、
W 队列非空就吃 1 拍、R 按 AR 顺序流水回来（`R_LATENCY`）。
既有 8 条用例都是"一笔一笔串行"⇒ 新旧模型在它们上面行为等价。

### 3.2 新作业：**B2B 背靠背 N=8 笔**（写-only / 读-only / 读写混）

AXI 主方**不等响应就继续发下一笔**（真背靠背）。判据四条：
① 逐字节对账（写区 / 读回逐拍逐字节）；② DDR 地址纸带 = 每笔 **+8 字（32 B）**递进；
③ 每笔写恰 1 个 B（`bid` **按序** = 1..8）、每笔读恰 1 次 `rlast` 且在末拍；
④ **★「未完成 > 1」的证据**：DUT 自报 `io_dbgOutW/io_dbgOutR` 的**作业内高水位** ≥ `B2B_MIN_OUT`（默认 2）。

**★ 先红（证据必须能失效）**：把 `LANES/DEPTH` 打成 1（NC6）⇒ 未完成峰值**结构性**只能到 1 ⇒ 判据翻红。
证据是**可证的**：`outW/outR ≤ DEPTH` 由 §2.2 的信用计数**保证**，不是"看起来能到 2"。

### 3.3 实测证据（交付档 `LANES=DEPTH=4`，AXI_W=64，100/125 MHz 两档）

```
[OUTSTANDING] 写：DUT自报峰值=4（外部口径 1）｜读：DUT自报峰值=0（外部口径 0）｜要求 ≥ 2   ← 作业 0（写 8 笔）
[OUTSTANDING] 写：DUT自报峰值=0（外部口径 0）｜读：DUT自报峰值=4（外部口径 4）｜要求 ≥ 2   ← 作业 1（读 8 笔）
[OUTSTANDING] 写：DUT自报峰值=4（外部口径 1）｜读：DUT自报峰值=4（外部口径 4）｜要求 ≥ 2   ← 作业 2（读写混）
[SPEED] 作业 0：59 cyc / 256 B = 0.230 cyc/B = 433.9 MB/s（axi 100MHz 口径）
[SPEED] 作业 1：45 cyc / 256 B = 0.176 cyc/B = 568.9 MB/s
[SPEED] 作业 2：36 cyc / 256 B = 0.141 cyc/B = 711.1 MB/s
=== TEST PASSED ===
```
（"外部口径" = TB 在 DDR 口/AXI 响应沿上自己数的 AW 发−B 回 / AR 发−rlast 回；写方向它偏小是因为
8 笔的 AW 都在开头 8 拍内发完、而 B 要等跨域往返 —— **判据取 DUT 自报**，外部口径只作旁证。）

---

## 4) T0.4 回归 + 记账

### 4.1 单元闸门（`sim/ddr3bridge/`）

| 项 | 结果 |
|---|---|
| `AXI_W=64 bash sim/ddr3bridge/run_unit.sh` @100 MHz / @125 MHz | **TEST PASSED / TEST PASSED**（既有 8 条 + B2B 3 条） |
| NC1 地址不递进（重锚到 axi 侧 `wqAddr/arAddr`） | **TEST FAILED（按期望）** |
| NC2 **目的域不再轮转**（`dLane` 冻结；重锚，理由见 §2.3） | **TEST FAILED（按期望，挂死）** |
| NC3 ★步进减半（`+ 8.U` → `+ 4.U`，spec §2 表里的 `+4`） | **TEST FAILED（按期望）** |
| NC4 `CdcFifo` 的「本份已取用」不再清零 | **TEST FAILED（按期望）** |
| NC5 B 不再回带 `awid` | **TEST FAILED（按期望）** |
| **NC6 ★本轮承重项**：`LANES/DEPTH` → 1 | **TEST FAILED（按期望，且只红在未完成证据那一条）** |

NC6 的红法（就是这个判词要的）：**逐字节 / 纸带 / B-rlast 三条全过**（功能没坏），
`[OUTSTANDING] … 峰值=1 < 2` ⇒ 只红在"拿不出未完成 > 1 的证据"。⇒ **深度是承重的。**

> ⚠️ **闸门脚本的历史坑，本轮修掉**：`run_unit.sh`/`gen_bridge.sh`/`negctl_ddr3bridge.sh` 里把仓库根
> **写死**成 `/mnt/d/code/PDS/NaxYeshenLinux`（= **另一棵 checkout**，`git remote`/`git log` 都不同）
> ⇒ 在 VexiiYeshenLinux 上跑会去打**别的树**的网表，判据还照样打印 PASS。现改为**从脚本自身位置反推**。

### 4.2 15 个单元闸门 + 台账 + dangling（实跑）

```
run_ddrmaster32_ab=0 run_desc_ab=0      run_fusionbuf_ab=0 run_bypass_ab=0   run_unitexec_ab=0
run_fuse_head_ab=0  run_fuse_ab=0       run_chain_ab=0      run_sched_ab=0    run_nputop_ab=0
run_nputop_sched_ab=0 run_hostregs_ab=0 run_ddrcopy_ab=0    run_ddrread_ab=0  run_ddrwrite_ab=0
```
（15/15 `rc=0`、每道 `RESULT: PASS`。）

```
python scripts/check_addr_map.py                -> PASS: address ledger consistent (16 sites reconciled)  rc=0
python y1/tools/check_dangling.py y1/gen/NpuTop.v / LayerSched.v / UnitExec.v / MultiPassUnit.v / DwUnit.v
python y1/tools/check_dangling.py rtl/YeshenSocGlue.v   -> 六处全 RESULT: PASS  rc=0
```

### 4.3 面积 Δ（**网表级口径**，− PDS）

| 口径 | 改前 `rtl/DDR3Bridge.v` | 交付 `rtl/DDR3Bridge.v` | Δ |
|---|---|---|---|
| `reg` 条数 | 76 | 204 | +128 |
| **FF 位宽合计** | **2 498** | **8 342** | **+5 844（+234%）** |
| 模块数 | 5 | 14 | +9 |
| 文件行数 / 字节 | 699 / 21 990 | 2 081 / 62 734 | +1 382 行 |

- 器件占比折算：**+5 844 FF ≈ +1.8%**（器件 319 600 FF；板级现用 113 382 FF = 36%、LUT 61 530.5/159 800 = 39%、
  APM 273/740、DRM 32.5/415）。**注意板级的紧资源是 CLMA/CLMS（C3/C4b 在 ~90–91%）**，本轮的增项是
  寄存器 + 窄 mux（不是加法进位链），**对 CLMS 影响应小、对 CLMA 有影响但未测**。
- **时序未测**。新增的关键路径：`awready := enq.ready && (outW < DEPTH)`（4 bit 比较）+ `CdcFifo` 的
  动态道号 mux（5 条 FIFO × 4 道）。都在短逻辑里，但**必须由 PnR 判**。

### 4.4 待跑的 PnR（**控制器执行**，本轮不跑）

```
# 工作目录 = D:/code/PDS/VexiiYeshenLinux（前置：rtl/DDR3Bridge.v 已按新源码重生成，md5 见 §7）
/c/Pango/PDS_2025.2-ads/bin/pds_shell.exe -file y1/pds/pnr_c4a.tcl \
    > y1/pds/pnr_dma_p0.log 2>&1 ; echo "exit=$?"

# 面积（dev_map，同一 tcl 的 integrated 档；与 C4b 的权威读数对照算 Δ）
/c/Pango/PDS_2025.2-ads/bin/pds_shell.exe -file y1/pds/devmap_c4a.tcl \
    > y1/pds/devmap_dma_p0.log 2>&1 ; echo "exit=$?"
# 取数：grep -nE "Device Utilization Summary" -A 14 y1/pds/devmap_dma_p0.log
# 判据：report_timing 的 "All Constraints Met" + 结束标记 YESHENMINI_PNR_C4A_DONE
#      + Device Utilization 的 CLMA/CLMS/LUT/FF/APM/DRM 与 C4b（c3_pnr_timing.md §31 行）
#        的基线（LUT 61 530.5 / FF 113 382 / APM 273 / DRAM 1 767 / DRM 32.5 / CLMA ~90%）逐项 Δ
```

---

## 5) 能证 / 不能证

**能证（本轮实测）**
1. DDR 侧**放开多未完成是可行的**：未完成峰值 4/4/4，且 `DEPTH=1` 时**结构性**掉回 1（NC6）。
2. **DDR IP 对外口与地址语义一字未改**（R1/R2），既有 8 条判据 + NC1..NC5 全绿/全翻红。
3. **背靠背速度实测有 2.1–3.2× 增益**（同装置同用例 A/B），且离 AXI 从口算术上限还有 1.4–1.8× 余量。
4. 既有互联未受影响：15 单元闸门 + 台账（16 站点）+ dangling 全绿。

**不能证 / 有条件**
1. **"改前"的绝对读数**：A/B 的"单未完成档"是**同一份新 RTL 把 `LANES/DEPTH` 打成 1**（结构上 = 改前的
   单 outstanding 形态：每条通道 1 条 CDCPipe + 1 深队列），**不是**重跑历史 RTL —— 新 TB 依赖新的观察口，
   历史网表端口不匹配、编不过。⇒ 表里的"改前"列读作"单未完成等价档"，这是"放开本身买了什么"的公平对照。
2. **不是真 IP**：IP 侧是行为模型（AW/AR 命令队列 + 顺序回拍 + 固定 `R_LATENCY`）。真紫光 IP 的
   AW/AR 流水深度、`wready` gap、R 通道节拍**未在板上验** ⇒ 带宽数字是**模型口径**，上板要重测。
3. **面积/时序未测**（本轮无 PnR）⇒ R6 **未关闭**，见 §4.3/§4.4。
4. **`AXI_W=32` 那条腿本轮未跑**：32 bit 网表来自 `attic/DDR3Bridge32.scala`（在 `src/` 之外、且仓库里
   **没有**它的现成网表）⇒ 不可在此复现；交付形态是 64 bit（`run_unit.sh` 默认 `AXI_W=64`）。
5. **只测到 8 笔背靠背**：更长流（百笔级）、以及真实描述符链/CPU 客户端的稳态吞吐**未测**（那是 Phase-2/3 的事）。

---

## 6) 改动面 + 指纹（`md5sum`）

| 文件 | md5 | 说明 |
|---|---|---|
| `src/soc/DDR3Bridge.scala` | `3fdab41ccd78eeec22bad6aec1e14c5b` | 内部重写（对外口不变；新增 4 观察口） |
| `src/soc/CDCQueue.scala` | `95bfb179bea22e6c307aa8c523b9c4a2` | **新增 `CdcFifo`**（`CDCPipe` 未改） |
| `sim/ddr3bridge/tb_ddrbridge.cpp` | `9598878c7b84af6827d2d6cb34475fe0` | IP 模型升级 + B2B 作业 + 未完成证据 |
| `sim/ddr3bridge/negctl_ddr3bridge.sh` | `36118033649230b50ebfce460047ddc8` | NC1..NC5 重锚 + **NC6 新增** |
| `sim/ddr3bridge/run_unit.sh` | `90a2de03987a84b9e79fe4fa2996eb60` | 仓库根自推 |
| `sim/ddr3bridge/gen_bridge.sh` | `acbf1a7984037632902397b9e11741e5` | 仓库根自推 |
| `sim/ddr3bridge/patch_exact.py` | `71405ec28a7ed98643bb8397bebbcc0e` | **未改** |
| `rtl/DDR3Bridge.v`（交付网表） | `a3c8eeaf8ba51f2467ceb56118c9feb1` | 由新源码重生成；**连续两次生成逐字节相同** |

- **只读纪律**：`third_party/**`（含 PDS 的 DDR3 IP）与冻结 Python 工具（`ddr_traffic.py`/`fusion_buffer.py`/
  `bypass_traffic.py`/`mac_ref.py`/`bypass_ref.py`/`conv_unit_ref.py`/`desc_table.py`）**一字未动**。
- 板级 `board/yeshen_mini_board_top.v`、`board/yeshen_mini_soc.v`、`YeshenSocGlue.scala`、`check_addr_map.py`
  **一字未动**（地址台账站点数仍 16）。

---

## 7) 给 Phase-1 的接口（本轮的"放开"长什么样）

- 交付档：`LANES = 4`、`DEPTH = 4` = **每条通道 4 道 × 4 深**；未完成容量 `outW/outR ≤ 4`。
- 降档/升档只需改 `src/soc/DDR3Bridge.scala` 里两个 `private val`（`LANES` / `DEPTH`），**判据全会跟着变**
  （NC6 就是把它们打成 1 的同一处）。
- Phase-1 换真仲裁时：本桥已经能"吃下多笔并各自完成"，`owner` 位宽加宽 / 配额不会撞到桥的单未完成墙。
