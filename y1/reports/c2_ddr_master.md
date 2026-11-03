# C2 结论 —— NPU 的 DDR 主口（J1–J4）+ **SoC 内含 NPU** 的 dev_map 资源

- 日期：2026-10-08 / 2026-10-09（dev_map 于 2026-10-09 00:36–00:39 跑）
- 交付物：`y1/tools/..` 既有判据的**汇总裁决** + 新增 PDS 工程 `y1/pds/devmap_soc_npu.tcl`（含 NPU 的 SoC dev_map）。
- 范围：**不碰板、不跑 PnR、不出比特流**。dev_map = `create_project → add_design → compile → synthesize -ads → dev_map`。

---

## 0. 阶段裁决（overall verdict）

**C2 建成并把 NPU 的访存半边**（主机可编程的 DDR 块拷贝主口 + 寄存器窗 + IRQ）**接进了 SoC 唯一的那套内存主口汇聚**，
并且在**含 NPU 的整块 SoC 上跑通了 PDS dev_map**。它证明：

1. **功能上**：主机经 AxiLite 编程 → NPU 派生 `len` → 主口在 DDR 上做字节精确的块拷贝 → done/IRQ；**≥1 MiB 整片逐字节相符**（J1）。
2. **性能上**：主口**自己**在每 32 B 上只加 `cyc_per_group = 1.250031` 拍（判据 ≤ 2）⇒ 静态合成预测 **249.03 MB/s = 275.9 的 90.26 %**（J2，**预测非实测**）。
3. **结构上**：新胶合与 NPU 网表无悬空实例、`rtl/` 无 Xilinx 残留、生成链 byte-reproducible、突发合规（J3）。
4. **台账上**：地址台账 16 处逐字一致（J4），并抓住了 `riscv,ndev` 2→3 的一处**静默漂移**。
5. **面积上**：**SoC 内含 NPU + 整套板级** 在 PG2L200H 上实测占用 **LUT 14370.5 / FF 17187 / APM 4 / DRM 24.5**，
   相对 2026-10-07 的 SoC 基线只 **+240.0 LUT / +63 FF / +0 APM / +1.0 DRM**。

**一句话**：C2 的**功能与结构**判据全绿；**带宽是"预测"，因为桥的 116 ns 跨双时钟域、单时钟仿真复现不了**；
**面积已实测**，NPU 当前（HostRegs+DdrMaster+merger 钩子）对 SoC 的资源增量很小。

> ⚠️ 口径分开（后文第 5 节会再强调）：本阶段测的是 **`NpuTop` = HostRegs + DdrMaster + IRQ**（块拷贝通路），
> **不含**卷积 datapath。那个 datapath（LineBuffer+WeightStore+GroupedMacArray+requant）是**另一个更大的块**
> `y1/gen/Conv3x3Slice.v`，面积见 `y1/reports/g1_area.md`，**不是 `NpuTop` 的一部分**。

---

## 1. 前置指纹（before / after，本阶段实测确认）

```bash
cd /d/code/PDS/VexiiYeshenLinux
md5sum rtl/YeshenSocGlue.v ; wc -l rtl/YeshenSocGlue.v
grep -c "^module NpuTop\|^module HostRegs\|^module DdrMaster" y1/gen/NpuTop.v
md5sum y1/gen/NpuTop.v
```

实测输出：

```
76f70e7ab013a23b47ae464f3fe9beab *rtl/YeshenSocGlue.v     # 4572 行
3                                                          # NpuTop + HostRegs + DdrMaster 三个 module
9bc9ba6f821b36d1fe72079a3ed192e9 *y1/gen/NpuTop.v
```

| 产物 | **before** | **after**（现状） |
|---|---|---|
| `rtl/YeshenSocGlue.v` | md5 `9c9107b712fdaea08019487456519cc8`，135447 B，4378 行 | md5 **`76f70e7ab013a23b47ae464f3fe9beab`**，143221 B，4572 行 |
| `y1/gen/NpuTop.v` | — | md5 **`9bc9ba6f821b36d1fe72079a3ed192e9`**（含 `NpuTop`/`HostRegs`/`DdrMaster` 三 module，顶层 `NpuTop`） |

⇒ 胶合 md5 **确实变了**（改动进了生成链，且 C2.2 已先证链 byte-reproducible），NPU 网表指纹不变（本阶段未重新生成它）。

---

## 2. J1 —— 字节级往返（byte-exact round trip）

**判据**：`bash y1/tools/run_ddrcopy_ab.sh`（装置 `rtl_test/DdrCopyTb.v` + `rtl_test/AxiMemModel.v` + 网表 `y1/gen/DdrMaster.v`）。

| 项 | 值 |
|---|---|
| 向量 | 周期恰 251 的置换模式 `pat(i)=((i%251)*131+7)%251`（251 素数、与块长 128 互素 ⇒ 整块平移 k=1..16 **每字节都变**；`(DST−SRC)%251=249≠0` ⇒ 不拷贝**不可能**混过） |
| 用例 | `SRC=131072 (0x20000)` / `DST=1441792 (0x160000)`，二者 32 B 对齐且不重叠；内存模型 `MEMSZ=2621440` |
| `LEN` | **1048576 B = 1 MiB ≥ 1 MB**（8192 块；小长度会让地址计数器错位藏起来） |
| **`MISMATCH`** | **`MISMATCH=0`**，`FIRST_OFF=-1`（整片逐字节相符） |

**三个区域各自点名（全部 0）**：

```
DST_EQ_SRC_BAD=0 (first=-1)      # dst 区逐字节 == 原地的 src 区（拷贝真发生且内容对）
SRC_UNCHANGED_BAD=0 (first=-1)   # src 区逐字节 == 预载（源没被改动）
NEIGHBOR_BAD=0 (before_dst=0 at -1, after_dstlen=0 at -1)
NEIGHBOR32 before_dst=0 after_dstlen=0   # 紧邻 dst 前后各 32 B 也没被多写/越界写
```

**三个负对照（闸门有牙的证据）**：

| 负对照 | 机制 | 期望 | 实测 | 退出码 |
|---|---|---|---|---|
| **A 写地址平移** | 网表突变 `wbase <= dst;` → `wbase <= dst + 128;`（整条写地址序列平移一块） | `MISMATCH>0` 且首个不符偏移 **== DST** | `MUTMISMATCH=1048704`，`MUTFIRST_OFF=1441792`（== DST），装置照旧 PASS（**突变只改"写到哪里"，不改"搬多少"**） | 0 |
| **B 字节粒度** | 源区**恰好一个字节**改掉：`SRC+61`（61 % 8 = 5 ⇒ 非 8 字节行对齐、非块对齐） | dst 区 `MISMATCH` **恰为 1** 且首个不符偏移 **== DST+61** | `NEGB_MISMATCH=1`，`NEGB_FIRST_OFF=1441853`（= DST+61）；`NEGB_SRC_UNCHANGED_BAD=0 NEGB_NEIGHBOR_BAD=0` | 0 |
| **C 非法长度 / err 路径** | 三种非法入参各跑一次：dst 非 32 B 对齐 / `len` 非 128 的整数倍（`LEN−64`）/ `len==0` | 装置自己报 `ERR=1` 且**一字节不搬** | `NEG_OK[dstalign]`、`NEG_OK[lenmult]`、`NEG_OK[lenzero]` 三发全中：`AR/AW/B=0`、`CHUNKS=0`、`MEM rd=wr=bursts=0`、镜像==预载 | 0 |

（另有两项**闸门自检**佐证：比较器自检 `CMP_SELFTEST MISMATCH=1`（扰动一个期望字节恰报 1）；
与内存模型**独立计数**交叉对账 `MEMCHECK rd=1048576 wr=1048576 bursts=16384 maxburst=16`、
`TBCHECK AR_BURSTS=8192 AW_BURSTS=8192 B_OK=8192 RDWR_OVERLAP=0 AW_LEAD_MAX=0`。）

**该闸门总退出码 = 0**（`RESULT: PASS`）。

**集成体（主机编程）端的 J1 孪生证据** —— `bash y1/tools/run_nputop_ab.sh`（网表 `y1/gen/NpuTop.v`）：
主机写 `SRC/DST/IMG_W=256/IMG_H=64/C_IN=8`（⇒ `len=131072`）→ 写 `CTRL.start` → `MISMATCH=0`、
三区域全 0、`STATUS_POST 00000001`（done）、IRQ 纪律 `PRE_IRQ=0 / POST_IRQ=1 / IRQ_AFTER_ACK=0 /
IRQ_RISES=1 / IRQ_HIGH_CYCLES=61`（**保持电平**，非单拍脉冲）；负对照 A 非法长度（`250×3×1=750`）
经 `STATUS.bit1` 观察到 err 且零搬运，负对照 B（派生 `len+128` 突变）被字节判据抓住
（`MISMATCH=128`，首个不符偏移 == `DST+LEN`）。总退出码 0。

---

## 3. J2 —— 吞吐（★ 报告的是**预测**，不是实测）

**本阶段报告的是第 (ii) 档：单时钟 `cyc_per_group_added` + 与桥 116 ns/32 B 的静态合成。**
第 (i) 档"双时钟测量"**本阶段没做**（属条件任务 C2.4），所以下面每一个速率都带"**预测**"定语。

**主口一侧（单时钟实测，`run_ddrcopy_ab.sh` 打印）**：

```
J2 cyc=303105 rd_bytes=1048576 wr_bytes=1048576
J2 groups=32768 beat_cycles=262144 overhead=40961 cyc_per_group=1.250031 cyc_per_group_total=9.250031
J2_OVERHEAD_OK cyc_per_group=1.250031 <= 2
```

- `cyc_per_group_added = 1.250031 ≤ 2`（判据 **PASS**）。口径：`(CYC − 搬运数据本身必走的拍数)/groups`
  = "主口在从方之外**自己**加了几个 100 MHz 拍 / 每 32 B"；它**不含**桥的代价。

**静态合成（`python y1/tools/predict_traffic.py 1.250031`，逐字）**：

```
CYCPG=1.250031  (主口每 32 B 自己加的 100 MHz 拍数，来自 run_ddrcopy_ab.sh 的单时钟实测)
T_group = 116.0 ns (桥静态) + 1.250 x 10.0 ns = 128.500 ns / 32 B
PREDICT_TRAFFIC_MBPS=249.03
PREDICT_PCT_OF_275.9=90.26%
PREDICT_COPY_MBPS=124.51  (= traffic 的一半：一份带宽被读、写各占一次)
THRESHOLD_MBPS=220.72  (= 275.9 x 80%，判据行里说的 220 MB/s)
VERDICT_GE_80PCT=YES
J2_CRITERION cyc_per_group <= 2 at 100 MHz: PASS (1.250031)
PREDICTION_LABEL: 本数为**预测**（依据桥的静态 116 ns/32 B = 60 ns@100 MHz + 56 ns@125 MHz），非实测 —— 单时钟仿真复现不了双时钟的 116 ns。
```

**结论（明确标注）**：**预测** traffic = **249.03 MB/s = 275.9 MB/s 的 90.26 %**（≥ 80 % 判据 = **YES**）；
等价**有效拷贝速率 124.51 MB/s**（一份带宽读/写各占一次 ⇒ 减半）。**这是预测，不是测量。**

**为什么只能是预测（必须写清）**：桥的 `116 ns / 32 B` **不是一个时钟域里的时间**，是**两个域的拍数相加**
（单 outstanding，两段不可重叠）：`6 拍 @ 100 MHz = 60 ns`（sClk 侧）+ `7 拍 @ 125 MHz = 56 ns`（dClk 侧）= **116 ns**。
`rtl_test/` 里只有一个 `clk`（100 MHz 口径）⇒ 桥的 125 MHz 域与 CDC 四相往返**根本不存在**，
**一次 Verilog 仿真测不出 116 ns**。故本数是"静态算出来的桥代价" **+** "单时钟仿真实测出来的主口开销"两笔相加 ⇒ **预测**。
（去掉"预测"这个定语需要 C2.4 的双时钟 + 行为级桥模型。）

---

## 4. J3 —— 结构

| 判据 | 命令 | 实测 | 退出码 |
|---|---|---|---|
| 无悬空实例（新胶合） | `python y1/tools/check_dangling.py rtl/YeshenSocGlue.v` | `--- no dangling instances ---` / `total dangling instances: 0` / `RESULT: PASS` | 0 |
| 无悬空实例（NPU） | `python y1/tools/check_dangling.py y1/gen/NpuTop.v` | `total dangling instances: 0` / `RESULT: PASS` | 0 |
| 无 Xilinx 残留（`rtl`） | `bash y1/tools/check_no_xilinx.sh rtl` | `xilinx-residual hits: 0` / `RESULT: PASS` —— **C2.2d 左锚定修复后转绿**（原模式无锚定，`c_addsub` 会命中 CPU 网表的内部信号名 `logic_addsub_combined_rs2` 而**假 FAIL**；那是继承缺陷，非回归） | 0 |
| 生成链确定性 | `md5sum rtl/YeshenSocGlue.v`（no-op 重生成） | byte-reproducible：C2.2 里**原样重生成**后 md5 仍是 `9c9107b712fdaea08019487456519cc8`（逐字节一致）⇒ "md5 变了 = 我的改动进了链"这一论断有地基；本阶段实测的 after 值 = `76f70e7ab013a23b47ae464f3fe9beab`（**本阶段未重跑生成器**，该证据引自 C2.2） | 0 |
| 突发合规 | `grep` `y1/gen/DdrMaster.v` | `axi_ar_payload_len = 8'h0f` / `axi_aw_payload_len = 8'h0f`（`arlen/awlen = 15`，恒 16 拍 = 128 B）；`arAddr = {rbase[27:5],5'h0}` / `awAddr = {wbase[27:5],5'h0}`（**低 5 位构造性为 0 ⇒ 32 B 对齐**，静态可查、运行期不可能违反） | — |

运行期交叉证据（同 J1，`run_ddrcopy_ab.sh`）：`ARSEQ_OK 8192 笔，地址逐笔 +128` / `AWSEQ_OK 8192 笔，地址逐笔 +128`，
且每笔 `arlen/awlen` 恒 15（`ARLEN_BAD`/`AWLEN_BAD` 未触发）；读写不重叠 `RDWR_OVERLAP=0`、写不领先读 `AW_LEAD_MAX=0`、`WLAST_BAD=0`。

---

## 5. J4 —— 地址台账

```
PASS: address ledger consistent (16 sites reconciled)
```

（`python scripts/check_addr_map.py` → 退出码 **0**。`-v` 逐条列举了这 16 处。）

**它现在对账什么（C2.2c 新增的三项 + 既有 13 项）**：

- **NPU 寄存器窗**：`glue NPU_BASE`（`src/YeshenSocGlue.scala` = `0xF000C000`）↔ **`DTS npu@ base`**
  （`sw/buildroot-external/boards/naxmini/linux/linux_raw.dts` 的 `npu@f000c000` 节点 `reg` 首格）。
- **IRQ 源号**：`glue NPU_IRQ_BIT`（= 3）↔ **`DTS npu interrupts`**（= 3）；且 `PLIC NDEV`
  （`src/peripheral/PlicAlite.scala` 的 `val NDEV` = 3）↔ **`DTS riscv,ndev`**（= 3）。
- **它抓住的一处静默漂移**：NPU 并入后 `PlicAlite.NDEV` 由 **2→3**，而 DTS 的 `riscv,ndev` **当时仍是 2**
  —— 这条漂移在 Linux 上**无人会碰到**（没有 NPU 驱动），属"最怕静默通过"的一类；现已被台账对账钉住。
  （DTS 内注释原文记着这次 2→3 的修订与理由。）

> 载体选择说明：台账的**四个消费者**里，OpenSBI `config.mk` 与仿真 tb 装载表只装**内存**镜像，
> NPU 是**外设**窗 ⇒ **刻意不**往那两处塞外设地址（塞进去只会是"没人读的装饰"）；
> `board/yeshen_mini_soc.v` 一个常量都没写（窗在胶合里解）⇒ 同样无承载。承载者只有胶合 / PlicAlite / DTS 三处。

---

## 6. 资源（**实测**与**投影**严格分开）

### 6a) 实测：SoC + NPU（本阶段 dev_map 真跑的）

**命令**（工作目录必须是仓根 `D:/code/PDS/VexiiYeshenLinux`）：

```bash
/c/Pango/PDS_2025.2-ads/bin/pds_shell.exe -file "D:/code/PDS/VexiiYeshenLinux/y1/pds/devmap_soc_npu.tcl" \
  > y1/pds/devmap_soc_npu.log 2>&1 ; echo "exit=$?"
```

| 项 | 值 |
|---|---|
| 脚本 | `y1/pds/devmap_soc_npu.tcl`（由 `pds/run_devmap_yeshen.tcl` **照抄**改核，板级源清单**一字未动**，**只增**一行 `add_design $root/y1/gen/NpuTop.v`） |
| 器件行 | `create_project ... -family Logos2 -device PG2L200H -package FBB676 -speedgrade -6`（照抄，未凭记忆手写） |
| 工程路径 | `sim/reglogs/pds_devmap_npu_p10.000`（tag = `devmap_npu`）—— 与 SoC 基线的 `sim/reglogs/pds_devmap_p10.000` **绝不交叉** |
| **退出码** | **0** |
| **墙钟** | `START 2026-10-09 00:36:36` → `END 2026-10-09 00:39:19` = **2 分 43 秒**（PDS 自报 `Total Real Time elapsed is 0h:2m:40s`） |
| **完成标记** | `YESHENMINI_DEVMAP_DONE`（日志末行） |
| DRC | **无** `DRC-0018` / `DeviceMap-2003` / `Program Error`（grep 命中 0）⇒ 资源未超限，**打印了 `Device Utilization Summary`** |
| 日志 | `y1/pds/devmap_soc_npu.log`（10185 行，md5 `78ac59787e097cd69e36cf56c94e984d`；`*.log` 按 .gitignore 不入库） |

**数字来源（明确声明）**：采用 **`Device Utilization Summary`**（`y1/pds/devmap_soc_npu.log` **第 10134–10164 行**，含表头与收尾边框），
并用 **`Mapping Summary`**（同 log **第 9398–9412 行**）交叉印证 —— 两处一致（LUT `14370.5` vs `14372`（含 231 当 dram）；
FF `17187` vs `17200`；DRM `24.5` vs `24.5`；APM `4` vs `4.00`）。
**没有**退回 `GTP_*` 行（本次未触发那种"dev_map 被 DRC 中止、无 Utilization Summary"的情况）。

**逐字复制 `Device Utilization Summary`（log 第 10134 行起，摘录前 12 行）**：

```text
Device Utilization Summary:
+---------------------------------------------------------------------------+
| Logic Utilization     | Used        | Available     | Utilization(%)     
+---------------------------------------------------------------------------+
| APM                   | 4           | 740           | 1                  
| FF                    | 17187       | 319600        | 6                  
| LUT                   | 14370.5     | 159800        | 9                  
| Distributed RAM       | 231         | 39500         | 1                  
| DRM                   | 24.5        | 415           | 6                  
| IO                    | 99          | 400           | 25                 
+---------------------------------------------------------------------------+
```

**相对 2026-10-07 基线的 delta**（基线 = 本仓自身日志 `sim/reglogs/m_yeshen_devmap.log`（2026-10-07 20:52）
的 `Device Utilization Summary`，同 log 第 8505 行起；该日志就是 SoC 资源基线）：

| 资源 | 基线（无 NPU，2026-10-07） | **本阶段实测（SoC+NPU）** | **delta** |
|---|---|---|---|
| LUT | `14130.5` | **`14370.5`** | **+240.0** |
| FF | `17124` | **`17187`** | **+63** |
| APM | `4` | **`4`** | **+0** |
| DRM | `23.5` | **`24.5`** | **+1.0** |
| Distributed RAM | `224` | `231` | +7 |
| IO | `99` | `99` | +0 |

> 读法与诚实说明：两份日志是**两次不同的 dev_map 运行**（不同时间、不同工程、设计差一个 NPU），
> 所以 delta 是"**两次独立实测之差**"，不是"同一工程的前后对比"。基线（14130.5）本身**已含**整套 SoC；
> delta（+240 LUT / +63 FF / +0 APM / +1 DRM）就是**当前 `NpuTop`（HostRegs + DdrMaster + merger/窗口钩子）
> 对 SoC 的资源增量**——很小，因为它**不含**卷积 datapath（见 6b）。`+240.0`/`+1.0` 的 .5 尾数是 LUT/DRM
> 分数化（PDS 以半格 LUT / 0.5 个 DRM36K 计），两个日志口径一致，可直接相减。

### 6b) 投影（★ 明确标注为**算术**，不是联合测量）

**"SoC + 切片 + NPU" 的面积和**：SoC+NPU **已实测**（6a），切片是**另一份独立测量**
（`y1/reports/g1_area.md`，`y1/gen/Conv3x3Slice.v`，md5 `e54fc5232644745ad113c1d80e879f16`，WIDTH=640 / GROUP=1）。
**两类网表从未在同一工程里一起综合过**，所以下表**只是把两次数值相加**，不是一次联合测量：

| 资源 | SoC+NPU（实测，6a） | 切片（实测，g1_area，WIDTH=640） | **和（算术）** | 器件可用 | 占器件 | 装得下？ |
|---|---|---|---|---|---|---|
| LUT | `14370.5` | `26447` | **`40817.5`** | 159800 | 25.5 % | **YES** |
| FF | `17187` | `87409` | **`104596`** | 319600 | 32.7 % | **YES** |
| APM | `4` | `40` | **`44`** | 740 | 5.9 % | **YES** |
| DRM | `24.5` | `0` | **`24.5`** | 415 | 5.9 % | **YES** |

> 口径：SoC+NPU 那一列**已经含 NPU**，"SoC + 切片 + NPU" 的和即"（SoC+NPU）+ 切片"，不重复计 NPU。
> （若换成 g1_area 里用的**旧** SoC 基线 14130.5 打头，和是 40577.5；与本表的差别正是那 +240.0 的 NPU 增量。）
> **这不是联合测量**：切片**不在** `NpuTop` 里（`NpuTop` 目前只有 HostRegs+DdrMaster+IRQ），
> 两者也从未同工程综合；且切片是**无板级约束**的纯资源探针（见 g1_area §7）。

---

## 7. 可追溯（结论 ↔ 命令 ↔ 指纹）

| 结论 | 命令 | 产物指纹 |
|---|---|---|
| J1 字节往返 | `bash y1/tools/run_ddrcopy_ab.sh`（exit 0） | 被测网表 `y1/gen/DdrMaster.v`；装置 `y1/rtl_test/DdrCopyTb.v` |
| J1 集成体（主机编程） | `bash y1/tools/run_nputop_ab.sh`（exit 0） | 被测网表 `y1/gen/NpuTop.v` md5 `9bc9ba6f821b36d1fe72079a3ed192e9` |
| J2 主口开销 | 同上（`run_ddrcopy_ab.sh` 的 `J2 ... cyc_per_group=1.250031`） | — |
| J2 预测 | `python y1/tools/predict_traffic.py 1.250031`（exit 0） | 桥 116 ns 出处 `y1/partA/ddr_path_ceiling.md` §2–3 |
| J3 结构 | `python y1/tools/check_dangling.py {rtl/YeshenSocGlue.v,y1/gen/NpuTop.v}`；`bash y1/tools/check_no_xilinx.sh rtl`；`grep` `y1/gen/DdrMaster.v` | 胶合 md5 `76f70e7ab013a23b47ae464f3fe9beab` |
| J4 台账 | `python scripts/check_addr_map.py`（exit 0） | `PASS: address ledger consistent (16 sites reconciled)` |
| 资源 | `/c/Pango/PDS_2025.2-ads/bin/pds_shell.exe -file y1/pds/devmap_soc_npu.tcl`（exit 0，2m43s） | 脚本 `y1/pds/devmap_soc_npu.tcl`；日志 `y1/pds/devmap_soc_npu.log` md5 `78ac59787e097cd69e36cf56c94e984d`，`Device Utilization Summary` 第 10134–10164 行 |

---

## 8. 未验证 / 已知缺口（如实列）

1. **没有上板**：本阶段的 SoC-含-NPU **从未上板/从未烧写**（无 bring-up、无 JTAG、无 bitstream）。
2. **没有时序**：`dev_map` 只做综合 + 器件映射，**不含布局布线与时序** ⇒ NPU/SoC 能否在 100 MHz 收敛**未知**。
3. **没有 PnR / 没有比特流**（本任务明确不跑）。
4. **J2 是预测，不是测量**：249.03 MB/s 由"静态桥代价 116 ns" + "单时钟仿真实测主口开销"**两笔相加**得到；
   桥的双时钟 116 ns 在单时钟仿真里**不可复现** ⇒ 想要实测须做 C2.4（双时钟 + 行为级桥模型）。
5. **融合调度器的流量是模型，不是测量**：`fuse_both` 12.5760 MB/帧 / 21.94 fps 等来自 `y1/tools/ddr_traffic.py`
   的**静态下界模型**（只计激活流量，不计权重装载 / 后处理读写 / 对齐填充）——见 `y1/reports/ddr_traffic_budget.md` §C0.3.8。
6. **CPU 争用份额未测**：NPU 与 CPU 组在 merger 上的 **round-robin** 是**设计**（两方争用时严格交替，
   谁都不会被饿死），但"真实负载下 CPU 拿多少、NPU 拿多少"**没有测量** —— 属 C5。
7. **融合所需的流式/行缓冲面积未验**：`fuse_both` 要求 33 条边界上的中间张量不出片（最大 1.6 MB），
   物理上意味着**流式/行缓冲数据通路 + 两种块序都能接**；其 DRAM/FF 占用**面积闸门必须复核** —— 属 C3。
8. **`NpuTop.len` 必须是 128 的整数倍**：这是当前集成契约（`len = IMG_W×IMG_H×C_IN`，非 128 倍数 ⇒ 走 err）。
   放开这个限制是 **C3** 的事。本阶段的 J1 负对照 C 正是把"非 128 倍数"当**非法**来判的。
9. **DTS 节点 `reg` 的 size 格未受检**：台账只对账 `npu@f000c000` 的 `reg` **首格（基址）**；
   `reg` 的**第二格（size = 0x4000）** **没有判据在守**（`check_addr_map.py` 未检查它）。
10. **`compatible = "y1,yunet-npu"` 是杜撰的**：这是本项目自拟的 compatible 字符串，**不是**任何
    已登记的 binding（YuNet NPU 没有 upstream DT binding）。它的作用只是让 `reg`/`interrupts` 落进 DTB 被台账对账。
11. **DTS 只做了预处理、从未编译成 DTB**：本机**没有 `dtc`** ⇒ `linux_raw.dts` 只经过 C 预处理器（cpp）生成 `linux.dts`，
    **语法/编译正确性未经 `dtc` 验证**（台账只做**静态文本**对账，故意不解析 DTB）。
12. **J3 的"确定性"证据引自 C2.2**：本阶段**未重跑**胶合/NPU 生成器（避免与 dev_map 抢 CPU），
    胶合 no-op 重生成 md5 稳定引自 `y1/reports/c2_glue_integration.md` §1；NPU 网表 md5 为记录值。
13. **本次资源 delta 是两次独立运行之差**（不同工程、不同日期），非同一工程前后对比（见 6a 读法说明）。
14. **`NpuTop` 不含卷积 datapath**：本阶段的资源增量（+240 LUT）只覆盖 HostRegs+DdrMaster+merger 钩子；
    卷积 datapath（行缓冲/权重/阵列）是**另一个更大的块**（切片 26447 LUT），**尚未**并进 `NpuTop`（见 0/6b）。

---

## 9. 本阶段改动的文件

- 新增 `y1/pds/devmap_soc_npu.tcl`（由 `pds/run_devmap_yeshen.tcl` 改核，只增 NPU 源）。
- 新增 `y1/reports/c2_ddr_master.md`（本文件）。
- **未改**任何 RTL / 测试装置 / 工具 / `src/` / `board/` / `scripts/`。

---

## 10. A/B：把"NPU 集成"的代价**单独隔离**（同会话背靠背）

**为什么要补这一步**：上面第 5 节的 Δ 是"本次含 NPU 的运行"减"**2026-10-07 的历史基线**"。两个数据点之间除了被测变量，还差了时间 / 工程目录 / 工具态 ⇒ 按对照实验纪律，这个 Δ **不能直接归因给 NPU**。本 A/B 用**同会话、背靠背、两臂各自从头重建工程**重做（`devmap_soc_ctrl.tcl` vs `devmap_soc_npu.tcl`）。

**两臂的唯一差异（逐条）**：
1. tag / 工程目录不同（`devmap_ctrl` → `sim/reglogs/pds_devmap_ctrl_p10.000`；`devmap_npu` → `…_npu_p10.000`）；
2. 组装层：控制臂用 **C2.2b 之前**那份 `board/yeshen_mini_soc.v`（`git show 2307a56~1:…`，那时**还没例化 NpuTop**）；实验臂用当前那份；
3. 胶合：控制臂用 C2.2b 之前那份（md5 **`9c9107b712fdaea08019487456519cc8`**）；实验臂用当前（md5 **`76f70e7ab013a23b47ae464f3fe9beab`**）；
4. 控制臂**无** / 实验臂**有** `add_design "$root/y1/gen/NpuTop.v"`。

其余（板级顶层 / PLL / LiteEth 适配层 + MAC 黑盒 + 厂家 RGMII PHY / 核网表 / `DDR3Bridge` / 紫光 DDR3 IP 全套 / 约束 `constraints/yeshen_mini.fdc` / `compile -verilog_standard SystemVerilog` / `dev_map -override_pcf false`）**逐条一致**；两臂都 exit 0、**0 DRC**、都有完成标记。

> **为什么控制臂不能只是"删掉 NPU 源那一行"**：当前组装层已经例化 `NpuTop`，只删源文件会 elaborate 失败 ⇒ 那样的"控制臂"根本跑不出来，A/B 就是假的。所以控制臂必须换回 C2.2b 之前的**组装层 + 胶合**。
> **控制臂自证**：其日志里是 `add_design …/y1/gen/ctrl_src/{yeshen_mini_soc.v, YeshenSocGlue.v}`，且 `NpuTop` 在其日志中出现 **0 次** ⇒ 它跑的确实是没有 NPU 的那份。

| 资源 | 臂 A（无 NPU） | 臂 B（含 NPU） | **Δ = NPU 集成代价** |
|---|---|---|---|
| APM | 4 | 4 | **0** |
| FF | 17,110 | 17,187 | **+77** |
| **LUT** | **14,226** | **14,370.5** | **+144.5** |
| Distributed RAM | 231 | 231 | 0 |
| DRM | 24.5 | 24.5 | **0** |
| IO | 99 | 99 | 0 |
| RCKB / SCANCHAIN / USCM | 2 / 0 / 5 | 2 / 0 / 5 | 0 |

### 它纠正了第 5 节什么

| 口径 | LUT | FF | APM | DRM |
|---|---|---|---|---|
| 控制臂 vs 历史基线（= **漂移**，无 NPU 的两次运行之差） | **+95.5** | −14.0 | 0 | **+1.0** |
| 旧 Δ（**跨运行**：本次 vs 历史基线） | +240.0 | +63.0 | +0 | +1.0 |
| **新 Δ（同会话 A/B）** | **+144.5** | **+77.0** | **+0** | **+0** |

- **LUT：+240 → +144.5**。差额 **95.5** 正好等于"控制臂 14,226 − 历史基线 14,130.5" ⇒ **旧 Δ 里有 95.5 LUT 是运行间/工具态漂移，不是 NPU**。**算术闭合**：`240.0 − 95.5 = 144.5` ✔
- **DRM：+1.0 → 0** ⇒ 历史基线那个 +1 是**噪声**；**NPU 的 DRAM 代价是零**。
- **FF：+63 → +77** ⇒ 旧值低估（同样有漂移）。
- **APM +0** 两法一致（`NpuTop` 里没有乘法器）。

⇒ **结论（可归因）**：把 NPU 集成进 SoC 的代价 = **LUT +144.5 / FF +77 / APM +0 / DRM +0**，其中 ΔLUT 占器件可用 LUT 的 **0.090%**。
第 5 节的"实测 vs 投影"口径不变（投影仍明确标注为算术、非联合测量）；变的只是 **Δ 的归因现在站得住**。

> **★★ C3.14 更正（2026-10-09）—— 上表这组 "+144.5 LUT" A/B 从未测到 NPU，结论作废。**
> A/B 的**两个臂都跑在已把 NPU 剪掉的胶合上**：`src/YeshenSocGlue.scala` 当时把 NPU 寄存器窗的
> **整根 SoC 地址**（`io.npuAxi.awaddr := pW` / `araddr := pR`）喂给了**基址 0** 的 `HostRegs`
> ⇒ 寄存器窗永不命中 ⇒ NPU 从 CPU 侧不可达 ⇒ PDS 把整颗 NPU 常量传播成死逻辑。
> ⇒ 那次 A/B 的 +144.5 LUT 只是"把线接上 / 无 NPU"的残留差，**不是 NPU 的代价**。
> **修法**（`pW(13,0)` / `pR(13,0)`，14 位窗内偏移；同 `c3_area.md` §5.1）后**板级 `dev_map` 实测
> NPU 被保留**：Δ vs SoC-only 控制臂 = **+7,957.5 LUT / +11,412 FF / +13 APM / +512 Distributed RAM**，
> ≈ 独立 `NpuTop` 的 7,639 LUT / 11,373 FF / 13 APM / 512 DRAM。
> **可信的 NPU 面积以独立综合为准**（`NpuTop` 7,639 / 11,373 / 13 / 0 / 512；
> `LayerSched` 33,979 / 48,143 / 163 / 4.0，见 `y1/reports/c3_area.md` §3.2 / §5.1）。

**复现**：
```bash
cd /d/code/PDS/VexiiYeshenLinux
/c/Pango/PDS_2025.2-ads/bin/pds_shell.exe -file D:/code/PDS/VexiiYeshenLinux/y1/pds/devmap_soc_ctrl.tcl > y1/pds/devmap_soc_ctrl.log 2>&1
/c/Pango/PDS_2025.2-ads/bin/pds_shell.exe -file D:/code/PDS/VexiiYeshenLinux/y1/pds/devmap_soc_npu.tcl  > y1/pds/devmap_soc_npu.log  2>&1
# 控制臂的两个源文件取自 git：
git show 2307a56~1:board/yeshen_mini_soc.v > y1/gen/ctrl_src/yeshen_mini_soc.v
git show 2307a56~1:rtl/YeshenSocGlue.v    > y1/gen/ctrl_src/YeshenSocGlue.v
```
