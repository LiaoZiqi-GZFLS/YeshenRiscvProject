# C2.2 胶合集成报告：NPU 并入 YeshenSocGlue（merger 输入 + 寄存器窗 + IRQ 源 3）

- 日期：2026-10-08
- 交付物：把 Y1 自研小型 YuNet CNN 加速器（`y1/gen/NpuTop.v`）**并入 SoC**——
  给胶合块一个新内存主口输入并汇入**同一 merger**、加寄存器窗 `0xF000_C000`、IRQ 进 PLIC **源 3**、
  板级组装层例化 `NpuTop`。
- 范围声明：**本任务不动地址台账**（`scripts/check_addr_map.py` 一字未改）；台账缺口见第 7 节。

---

## 1. Step 0：重生成链** faithfulness（no-op）**——先证链可信

改任何一行之前，先**原样重生成**胶合并对指纹：

```
md5sum rtl/YeshenSocGlue.v          # 基线 9c9107b712fdaea08019487456519cc8（135447 B / 4378 行）
bash scripts/build_all.sh --only glue
md5sum rtl/YeshenSocGlue.v          # 仍是 9c9107b712fdaea08019487456519cc8（逐字节一致）
```

**结论：md5 不变 ⇒ 生成链 byte-reproducible / 忠实。** 这是后面"指纹变了 ⇒ 我的改动进了生成链"
这一论断的**唯一地基**：链不忠实的话，任何"改了 md5"都可能是噪声，不能当证据。

---

## 2. 跟着走的模板（§3.5 + §4）

胶合块**已有**一处单 outstanding 汇聚（§3.5：`cpuFetch`+`cpuLsu` ⇒ `cpuMem`），再用 §4 的选通
（`loadActive` 时让装载器、否则 `cpuAxi`）接到唯一的 `io.mem`（`AXIIO64`，下游 `DDR3Bridge`
单 outstanding 从口）。NPU **只作为 §3.5 汇聚点上的一个新 owner**，不另造第二套仲裁。

### ★ 引用的原话（`src/YeshenSocGlue.scala` §4，NPU 改动前就在）：

> **★ W 必须与 AW 同门（不能只修 awready）**：本核 `Axi4Bridge` 的 W 与 AW **不是**握手依赖 ——
> `rtl/NaxSocMini.v:15628 io_down_w_valid = a_data_buffer_valid`（A 命令 fork 出来的数据缓冲，
> 其 ready 只看 `io_down_w_ready`），与 `io_down_aw_ready` **无关**；W 的放行条件只由
> `a_data_buffer_ready = io_down_w_ready` 决定（:15629）。⇒ "AW 被拒 ⇒ 核不会发 W" **不成立**：
> 只修 `awready` 会退化成 "AW 压住、W 照发" ⇒ 从方把 W 拍当 orphan 丢掉 ⇒ 写数据丢失 + `wlast_mismatch`。

### 同时遵守的纪律（§3.5 注释原文）

- **只允许一笔内存事务在飞**：`owner` 登记当前被授予的主方，持有授权直到读突发末拍（`r.last` fire）
  或写响应（`b` fire）。
- **反"假装接受"**：不该收的那一拍，**既不向主方回告 `ready`**（主方保持 valid+payload），
  **又不向下游摆 `valid`** —— 两个半门**必须成对**（绝不能"掩掉自己的 valid、却把下游 ready
  直通给主方"）。

⇒ NPU 的每一条通道都**照抄这两条**：读授权拍 `arready = cpuMem.arready && npuRd`；
写授权拍 `awready/wready = cpuMem.*ready && npuWr` **同门**；数据只在被授权时摆 valid。
（生成网表已核对：`io_npuMem_awready = cpuAxi_aw_awready & npuWr`、
`io_npuMem_wready = cpuAxi_w_wready & npuWr`、`cpuMem_awvalid = lsuWr ? io_cpuLsu_awvalid :
io_npuMem_awvalid & npuWr` —— 同门且成对。）

---

## 3. NPU AXI 主口 —— 逐口对照表

NPU 端口逐字取自 `sed -n '/^module NpuTop/,/^);/p' y1/gen/NpuTop.v`（实测 dump）。
胶合块把 NPU 主口包成新 bundle `NpuAxi64`（`src/YeshenSocGlue.scala`），逐口对照：

| NPU 端口（NpuTop.v） | 宽度 | 方向(NPU) | 胶合 bundle 字段 | 匹配? |
|---|---|---|---|---|
| `axi_aw_valid` | 1 | out | `npuMem.awvalid` | ✔ |
| `axi_aw_ready` | 1 | in | `npuMem.awready` | ✔ |
| `axi_aw_payload_addr` | **28** | out | `npuMem.awaddr` (28) | ✔（**不是 32**，见下） |
| `axi_aw_payload_id` | 4 | out | `npuMem.awid` (4) | ✔ |
| `axi_aw_payload_len` | 8 | out | `npuMem.awlen` (8) | ✔ |
| `axi_aw_payload_size` | 3 | out | `npuMem.awsize` (3) | ✔ |
| `axi_aw_payload_burst` | 2 | out | `npuMem.awburst` (2) | ✔ |
| `axi_aw_payload_cache` | 4 | out | `npuMem.awcache` (4) | ✔ |
| `axi_aw_payload_prot` | 3 | out | `npuMem.awprot` (3) | ✔ |
| —（无 `awlock`） | — | — | —（`NpuAxi64` 无此字段） | ✔ 一致 |
| `axi_w_valid` / `_ready` | 1 | out/in | `npuMem.wvalid` / `wready` | ✔ |
| `axi_w_payload_data` | **64** | out | `npuMem.wdata` (64) | ✔ |
| `axi_w_payload_strb` | **8** | out | `npuMem.wstrb` (8) | ✔ |
| `axi_w_payload_last` | 1 | out | `npuMem.wlast` | ✔ |
| —（无 `w_payload_id`） | — | — | —（`NpuAxi64` 无 `wid`） | ✔ 一致 |
| `axi_b_valid` / `_ready` | 1 | in/out | `npuMem.bvalid` / `bready` | ✔ |
| `axi_b_payload_id` | 4 | in | `npuMem.bid` (4) | ✔ |
| `axi_b_payload_resp` | 2 | in | `npuMem.bresp` (2) | ✔ |
| `axi_ar_valid` / `_ready` | 1 | out/in | `npuMem.arvalid` / `arready` | ✔ |
| `axi_ar_payload_addr` | **28** | out | `npuMem.araddr` (28) | ✔（零扩展见下） |
| `axi_ar_payload_id` | 4 | out | `npuMem.arid` (4) | ✔ |
| `axi_ar_payload_len/size/burst/cache/prot` | 8/3/2/4/3 | out | 同名同宽 | ✔ |
| —（无 `arlock`） | — | — | — | ✔ 一致 |
| `axi_r_valid` / `_ready` | 1 | in/out | `npuMem.rvalid` / `rready` | ✔ |
| `axi_r_payload_data` | **64** | in | `npuMem.rdata` (64) | ✔ |
| `axi_r_payload_id` | 4 | in | `npuMem.rid` (4) | ✔ |
| `axi_r_payload_resp` | 2 | in | `npuMem.rresp` (2) | ✔ |
| `axi_r_payload_last` | 1 | in | `npuMem.rlast` | ✔ |
| `irq` | 1 | out | `npuIrq`（Input，进 PLIC 源 3） | ✔ |
| `clk` / `reset` | 1 | in | 板级接 `soc_clk` / `soc_cpu_reset` | ✔ |
| `axilite_*`（AW/W/B/AR/R） | 32bit data / 4bit strb / 3bit prot | slave | `npuAxi`（`VexiiAxiLite32`，**非 Flipped**） | ✔ |

### 与胶合块形状的差异及收敛（**这正是本步要防的"静默位宽不符"**）

1. **addr 28 ↔ 32**：NPU 主口 `addr` 是 **28bit**（`DdrMaster.v:1471 arAddr = {rbase[27:5],5'h0}` ⇒
   **28bit 字节地址、32B 对齐**），而胶合 `cpuMem`（`VexiiAxi64`）/`io.mem`（`AXIIO64`）是 32bit。
   收敛：§3.5 里 `Cat(0.U(4.W), io.npuMem.araddr/awaddr)` **高位零扩展**（NPU 只用低 28 位，零扩展
   不改变地址含义）。
2. **id**：NPU `aw/ar/b/r` 带 4bit id，但胶合汇聚点**单 outstanding**、`VexiiAxi64` **无 id 通道**
   ⇒ 与 CPU 一样**丢弃**（NPU 侧 `DdrMaster.v` 实测恒发 `arid=awid=4'h0`，且**不校验** `bid/rid`）
   ⇒ 回程恒 0（`io.npuMem.bid := 0.U`、`io.npuMem.rid := 0.U`）。
3. **lock**：NPU 主口**无** `awlock/arlock`（SpinalHDL `useLock=false`）；胶合 `AXIIO64` 有
   `awlock(2)`/`arlock(3)` ⇒ 由胶合块内部填 0（原本 CPU 也是填 0），`NpuAxi64` 侧不设这两个字段。
4. **W 无 wid**：`AXIIO64.w.wid` 由胶合块内部填 0；`NpuAxi64` 不含 `wid`。

---

## 4. 第四个主方的仲裁选择与理由

- **起点**（模板给定）：CPU 组内是**固定优先级** `LSU 写 > LSU 读 > Fetch 读`。
- **把 NPU 直接塞进这条固定链的两种坏结果**：垫底 ⇒ **NPU 被饿死**；置顶 ⇒ **CPU 被饿死**。
- **选择：在"{CPU 三个} vs {NPU}"两个组之间做轮转（round-robin），组内保留原固定优先级。**
  - `npuTurn = 0` ⇒ 本拍优先 CPU 组（组内 LSU 写 > LSU 读 > Fetch 读），CPU 组无请求才让 NPU；
  - `npuTurn = 1` ⇒ 本拍优先 NPU（写 > 读），NPU 无请求才让 CPU 组；
  - 授权给 CPU 组 ⇒ `npuTurn := 1`；授权给 NPU ⇒ `npuTurn := 0`。
- **为什么**：两方持续争用时**严格交替** ⇒ 谁都不会被对方饿死（目标"NPU 不许饿死、CPU 也不许饿死"
  达成）；只有一方请求时另一位**不受任何惩罚**——NPU 恒空闲时 `npuTurn` 不进入 CPU 分支的判据
  ⇒ 与改动前**逐位同值**（低风险：既有三主的语义一字未改）。

---

## 5. 窗口与 IRQ 落点

- **寄存器窗**：`YeshenMap.NPU_BASE = 0xF000C000` / `NPU_MASK = 0xFFFF_C000`（**16 KiB**）。
  选址依据（逐条算过，写进代码注释）：`0x1000/0x2000/0x3000/0x4000` 已占；`0x8000–0xBFFF` 被
  **ETH buffer** 的 16 KiB 窗占住（`ETH_BUF_MASK = 0xFFFF_C000`，基址 0x8000）⇒ **0x9000 / 0xA000
  在 ETH buffer 窗内、不是空闲**；空闲段只有 `0x5000–0x7FFF` 与 `0xC000–0xFFFF` ⇒ 取 `0xC000`
  （按 16 KiB 对齐，覆盖 `0xC000–0xFFFF`，恰好一段空闲区、不与 ETH 窗重叠）。
  解码照 `isEth*` 模板：`isNpuR/isNpuW` + `selNpu=6` 进 §3 的 ready/rvalid/rdata/rresp/bvalid/bresp
  MuxCase/MuxLookup；地址整根交给 `NpuTop.axilite_*`（NPU 内部取偏移）。
- **IRQ 源 3**：`io.npuIrq`（Input）⇒ `plic.io.npuIrq` ⇒ `PlicAlite` 的 `srcIn(3)`；`PlicAlite` 的
  `NDEV 2→3` + 新增 `priority(3)` 读。NPU 的 `irq` 是**保持电平**（done/err 抬起，主机写
  `CTRL.soft_reset` 清源）⇒ 天然适配 PLIC 的"电平锁存成 pending + 读 claim 清源"网关。
  源号：1=控制台、2=LiteEth、**3=NPU**（DTS 需 `interrupts = <3>`）。

---

## 6. 指纹 before → after（证据：改动进了生成链）

| | md5 | 字节 | 行数 |
|---|---|---|---|
| **before**（Step 0 no-op） | `9c9107b712fdaea08019487456519cc8` | 135447 | 4378 |
| **after** | `76f70e7ab013a23b47ae464f3fe9beab` | 143221 | 4572 |

md5 **变了** ⇒ 改动确实进了生成链（Step 0 已证链忠实，故此差异可归因于本次编辑）。

---

## 7. 判据退出码 + **台账缺口（明确声明）**

| 判据 | 结果 | 退出码 |
|---|---|---|
| `bash scripts/build_all.sh --only glue` | 重生成成功 | 0 |
| `grep -q "^module YeshenSocGlue" rtl/YeshenSocGlue.v` | module header OK | 0 |
| `python y1/tools/check_dangling.py rtl/YeshenSocGlue.v` | PASS（0 悬空实例；11 定义 / 10 例化） | 0 |
| `bash y1/tools/check_no_xilinx.sh rtl` | **FAIL（继承的假阳性，非本次回归）** | 1 |
| `python scripts/check_addr_map.py` | PASS（10 sites reconciled） | 0 |
| `run_nputop_ab / run_ddrcopy_ab / run_ddrread_ab / run_ddrwrite_ab / run_hostregs_ab` | 全 PASS | 0 / 0 / 0 / 0 / 0 |
| verilator `--lint-only`（板级 `yeshen_mini_soc` + glue + NpuTop + liteeth + 原语桩） | **0 error** | 0 |

### `check_no_xilinx.sh rtl` FAIL 的定性（**如实报，不假装 PASS**）

10 个命中**全在 `rtl/vexiiriscv/VexiiRiscv.v`**（`git status` 该文件**未改动**），全是同一处假阳性：
判据正则里的 `c_addsub` 命中了 Vexii 网表的内部信号名 `logi**c_addsub**`
（`early0/1_SrcPlugin_logic_addsub_combined_rs2Patched`）。这**不是**本次改动引入的回归——
单独跑本任务的产物 `bash y1/tools/check_no_xilinx.sh rtl/YeshenSocGlue.v` 得 **0 命中 / PASS**。
（无法在此修正：判据在 `y1/tools/` 禁改；CPU 网表是生成产物、不在本任务范围。）

### ★ 台账缺口 —— 明说，不掩盖

- NPU 的寄存器窗（`0xF000_C000`）与它的 PLIRC 源号（3）**尚未进入地址台账的 `EXPECT` 表**
  （`scripts/check_addr_map.py` 本任务**一字未改**）。
- 台账的**四个消费者**——OpenSBI `config.mk` / 仿真 tb 装载表 / DTS / 板级顶层——**都还没更新**，
  因此 **NPU 这两个地址常量目前没有任何判据在守**（台账只在 `EXPECT` 里出现过的常量才认领）。
- `check_addr_map.py` 之所以仍 PASS：它**只检查已登记在 `EXPECT` 里的条目**，新增窗口"不在表里"
  自然不改变结论——**这不是"被覆盖了"，是"没被检查"**。补齐由**后续任务**（台账五处同步）完成。

---

## 8. 改动的文件

- `src/YeshenSocGlue.scala`：新增 `NpuAxi64` bundle；IO 新增 `npuMem`/`npuAxi`/`npuIrq`；
  `YeshenMap` 加 `NPU_BASE/NPU_MASK/NPU_IRQ_BIT`；§3.5 汇聚点扩为三主 + 组间轮转；§3 加 NPU 窗解码；
  §2b 接 `plic.io.npuIrq`。
- `src/peripheral/PlicAlite.scala`：`NDEV 2→3`、新增 `npuIrq` 输入与 `srcIn(3)`、`priority(3)` 读。
- `board/yeshen_mini_soc.v`：例化 `NpuTop`，wire 其 AXI 主口/AxiLite 从口，接 glue 的
  `io_npuMem_*` / `io_npuAxi_*` / `io_npuIrq`；头加【9】。**不接任何引脚/LED**。
- `rtl/YeshenSocGlue.v`：由生成链重生成（**未手改**）。
- `y1/reports/c2_glue_integration.md`：本文件。
