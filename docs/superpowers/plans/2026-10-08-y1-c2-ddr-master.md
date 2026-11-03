# Y1 · C2 实施计划：DDR 主口（块拷贝 + 字节级往返 + 吞吐）

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 给加速器做出**自己的 DDR 主口**，并证明它 ① **字节级正确地**把一块 DDR 数据搬进/搬出，② **不会成为瓶颈**（主口自身开销可忽略，端到端受限于桥）。

**Architecture:** 新增 `DdrMaster`（SpinalHDL，AXI4 主口 64 bit / 4 bit id，**单 outstanding、32 B 对齐、16 拍突发**），逐块（128 B）先读进片上小缓冲、再写回另一地址。**先在独立 tb 里用 Verilog AXI 内存模型闭环**（不碰 SoC）；**再把 NPU 作为第二个 Verilog 黑盒并入 `YeshenSocGlue` 既有的内存主口 merger**，并过地址台账闸门。

**Tech Stack:** Scala 2.12.18 / SpinalHDL 1.15.0 + sbt（本机 Coursier 的 `sbt.bat`，声明 1.10.0）；iverilog 13.0；Chisel（`YeshenSocGlue`）；PDS 2025.2 `dev_map`；`scripts/check_addr_map.py`（地址台账唯一闸门）。

**设计依据：** `docs/superpowers/specs/2026-10-08-y1-c2-ddr-master-design.md`（协议契约 P1–P6、判据 J1–J4、风险 R1–R6）

---

## 全局约定（每个 Task 都适用）

- **不上板**：本计划全部离线（仿真 + 综合/映射）。上板时机由用户给；C2 的板级实测另议。
- **只读资产**：`third_party/**`（含 `third_party/ddr3_ip_200h/**`）、`cam2lcd_200mini/**` 一律不改。`src/soc/DDR3Bridge.scala`、`src/soc/CDCQueue.scala` 是**输入约束**，不是待改对象。
- **提交**（本机无 git 身份，**不 push**，**绝不改 git config**）：
  ```bash
  GIT_AUTHOR_NAME="LiaoZiqi-GZFLS" GIT_AUTHOR_EMAIL="LiaoZiqi-GZFLS@users.noreply.github.com" \
  GIT_COMMITTER_NAME="LiaoZiqi-GZFLS" GIT_COMMITTER_EMAIL="LiaoZiqi-GZFLS@users.noreply.github.com" \
  git commit -m "<msg>"
  ```
- **判据必须带正负对照**（已知-good/已知-bad 两份输入，一绿一红）；**产物记指纹**（md5/字节数/行数）。
- **生成器必须 `headerWithDate=false` 且 `headerWithRepoHash=false`**（否则头里嵌仓库 HEAD，指纹跨 commit 必变，"改动是否生效"判据退化成永真）。
- **判据钉死在生成参数上时，不匹配必须"响亮失败"**（Y1 已吃过一次：`WIDTH=640` 网表喂给按 `+IW=16` 的 TB ⇒ 静默 `MISMATCH=2013`；修法 = 暴露常量 + 立即 fatal）。
- **sbt 走 stdin**：`printf '<cmd>\nexit\n' | bash sbt.sh`（`sbt.bat` 会吞掉带引号的参数）。
- 脚本打印非 ASCII 必须 `sys.stdout.reconfigure(errors="replace")` 或只输出 ASCII。

## 文件结构

```
VexiiYeshenLinux/
├── y1/
│   ├── rtl/DdrMaster.scala           # AXI4 主口 + 块拷贝 FSM
│   ├── rtl_test/DdrMasterGen.scala   # 生成 gen/DdrMaster.v
│   ├── rtl_test/AxiMemModel.v        # AXI4 内存模型（tb 用；预载 + 转储）
│   ├── rtl_test/DdrMasterTb.v        # 装置：驱动 DdrMaster + 内存模型
│   ├── tools/run_ddrmaster_ab.sh     # 闸门：J1 字节级往返 + cyc_per_group + 负对照
│   ├── tools/predict_traffic.py      # J2 静态合成（仅当不做两时钟仿真时用）
│   └── reports/c2_ddr_master.md      # C2 结论（J1/J2/J3/J4 + 未验证项）
├── src/YeshenSocGlue.scala           # 加 NPU 黑盒 + 并入 merger + 窗口 + IRQ 源 3
└── scripts/check_addr_map.py         # 台账唯一来源（EXPECT）
```

---

### Task C2.0: 前置 —— 记录既有 SoC 的判据基线（回归要有 "before"）

**为什么**：C2.2 会改 `src/YeshenSocGlue.scala` ⇒ **重生成整块 SoC 网表**（设计文档 R3）。没有 "before" 指纹，之后"有没有回归"就只能靠感觉。

**Files:**
- Create: `y1/reports/c2_baseline.md`

- [ ] **Step 1: 跑既有台账闸门并记录**

```bash
cd /d/code/PDS/VexiiYeshenLinux
python scripts/check_addr_map.py ; echo "addr_map_exit=$?"
python scripts/check_addr_map.py -v > y1/reports/c2_baseline_addr_map.txt 2>&1 ; echo "verbose_exit=$?"
```

Expected: `PASS`，退出 0。**若本来就红，先如实报告并停下**（不能把别人的红当成我的 before）。

- [ ] **Step 2: 记录当前 SoC 侧产物指纹**

```bash
cd /d/code/PDS/VexiiYeshenLinux
ls -l rtl/YeshenSocGlue.v 2>/dev/null && md5sum rtl/YeshenSocGlue.v
ls -l sim/reglogs/*devmap*.log 2>/dev/null | tail -3
```

Expected: 拿到 `rtl/YeshenSocGlue.v` 的 md5 与最近一份 devmap 日志的路径/mtime（**这就是 after 要对比的 before**）。

- [ ] **Step 3: 写 `y1/reports/c2_baseline.md`** —— 台账 PASS 的证据、`YeshenSocGlue.v` 的 md5、最近 devmap 日志路径、以及"改胶合后这些都**必须**重跑并逐条对比"的说明。

- [ ] **Step 4: 提交**

```bash
cd /d/code/PDS/VexiiYeshenLinux
git add y1/reports/c2_baseline.md y1/reports/c2_baseline_addr_map.txt
GIT_AUTHOR_NAME="LiaoZiqi-GZFLS" GIT_AUTHOR_EMAIL="LiaoZiqi-GZFLS@users.noreply.github.com" \
GIT_COMMITTER_NAME="LiaoZiqi-GZFLS" GIT_COMMITTER_EMAIL="LiaoZiqi-GZFLS@users.noreply.github.com" \
git commit -m "feat(y1-c2): 前置基线 —— 既有 SoC 台账 PASS 与 YeshenSocGlue.v 指纹（改胶合后的回归基准）"
```

---

### Task C2.1a: AXI 读主口 + 读闸门

**Files:**
- Create: `y1/rtl/DdrMaster.scala`（本任务只做读路径；结构留给 C2.1b/c）
- Create: `y1/rtl_test/DdrMasterGen.scala`
- Create: `y1/rtl_test/AxiMemModel.v`
- Create: `y1/rtl_test/DdrReadTb.v`
- Create: `y1/tools/run_ddrread_ab.sh`

- [ ] **Step 1: 先写 AXI 内存模型 `AxiMemModel.v`**（装置与闸门共用，读/写两个 Task 都要它）

要求：
- 纯 Verilog，单时钟，**64 bit 数据 / 8 bit wstrb / 4 bit id**，支持 AXI4 突发（`awlen/arlen` 最多 15）；
- 预载：`+MEMFILE=`（每行一个十六进制字节，`$readmemh` 格式）；
- 转储：`+DUMPFILE=`，在收到一个 `+dump` 触发（或仿真结束时）把内存按同样格式写出，供闸门逐字节比对；
- **带自检**：收到超过 16 拍的突发、或地址未 32 B 对齐时，打 `MEM-ERROR` 并 `$fatal`（这样"主口违规"会响亮失败而不是悄悄通过）；
- 打印 `MEM rd=<n> wr=<n> maxburst=<n>` 统计，供闸门核对。

- [ ] **Step 2: 写 `DdrMaster` 的读路径**（冻结接口，C2.1b/c 沿用）

```scala
case class DdrMasterConfig(ADDR_W: Int = 28, DATA_W: Int = 64, ID_W: Int = 4, CHUNK_BYTES: Int = 128)

class DdrMaster(cfg: DdrMasterConfig) extends Component {
  val io = new Bundle {
    val start  = in  Bool()
    val src    = in  UInt(cfg.ADDR_W bits)   // 必须 32B 对齐
    val dst    = in  UInt(cfg.ADDR_W bits)   // 必须 32B 对齐（本任务未用）
    val len    = in  UInt(32 bits)           // 字节数，必须是 32B 的倍数
    val busy   = out Bool()
    val done   = out Bool()                  // 单拍脉冲
    val err    = out Bool()                  // 对齐/长度非法 ⇒ 立刻 err，不搬
    val cyc    = out UInt(32 bits)           // start 到 done 的拍数
    val rd_bytes = out UInt(32 bits)
    val wr_bytes = out UInt(32 bits)
    val buf_dout = out Vec (UInt(8 bits), cfg.CHUNK_BYTES)   // 块缓冲读出（C2.1c 给写路径用；此处供 tb 观察）
    val axi    = master(Axi4(Axi4Config(cfg.ADDR_W, cfg.DATA_W, idWidth = cfg.ID_W,
                     useId = true, useLen = true, useLock = false, useRegion = false, useQos = false,
                     awUserWidth = 0, arUserWidth = 0, wUserWidth = 0, bUserWidth = 0, rUserWidth = 0)))
  }
  noIoPrefix()
  // 契约（设计文档 §4）：单 outstanding；突发 16 拍 = 128 B；32B 对齐；读写不并发；W 与 AW 同门
}
```

读路径行为：`start` 后校验（`src`/`dst` 低 5 位为 0、`len % 32 == 0`、`len > 0`），非法则 `err` 单拍脉冲回 IDLE；合法则对每个 128 B 块发一笔 `AR`（`arlen = 15`），收 16 拍 `R` 进块缓冲，累计 `rd_bytes`；搬完 `done` 单拍脉冲，`cyc` = 拍数。

- [ ] **Step 3: 写装置 `DdrReadTb.v` 与闸门 `run_ddrread_ab.sh`**

装置：例化 `DdrMaster` + `AxiMemModel`，用 `+SRC= +LEN= +MEMFILE= +DUMPFILE=` 参数化；仿真结束后把**块缓冲收到的每个字节**按顺序打一行 `RDBLK <hh> ...`，并打 `RESULT: PASS|FAIL`（非 0 退出由 `$fatal`）。

闸门三件事：
1. **正对照**：内存里预置**非平凡**数据（`byte[i] = (i*131 + 7) & 0xFF`）；用 Python 独立算出"源码这段应该是什么"，与装置打印的 `RDBLK` **逐字节**比对，打 `MISMATCH=<n>`；
2. **对齐/长度负对照**：把 `+SRC` 设成未对齐（或 `+LEN` 设成非 32 的倍数），断言装置报 **`err`**（而不是静默照搬）；
3. **超长负对照**：把 `+LEN` 设为大于内存区域，断言装置**不会越界写/读**（内存模型会 `$fatal`）或按约定报错 —— 二选一但必须**明确断言其中一种**。

退出码：`0` 过，`1` 不符/仿真失败，`2` 负对照没抓住。

- [ ] **Step 4: 跑**

```bash
cd /d/code/PDS/VexiiYeshenLinux/y1
mkdir -p gen
printf 'Test/runMain DdrMasterGen D:/code/PDS/VexiiYeshenLinux/y1/gen\nexit\n' | bash sbt.sh 2>&1 | tail -6
bash tools/run_ddrread_ab.sh ; echo "gate_exit=$?"
python tools/check_dangling.py gen/DdrMaster.v ; echo "dangling_exit=$?"
```

Expected: `gate_exit=0`（含两个负对照）、`dangling_exit=0`。

- [ ] **Step 5: 提交**

```bash
cd /d/code/PDS/VexiiYeshenLinux
git add y1/rtl/DdrMaster.scala y1/rtl_test/DdrMasterGen.scala y1/rtl_test/AxiMemModel.v y1/rtl_test/DdrReadTb.v y1/tools/run_ddrread_ab.sh
GIT_AUTHOR_NAME="LiaoZiqi-GZFLS" GIT_AUTHOR_EMAIL="LiaoZiqi-GZFLS@users.noreply.github.com" \
GIT_COMMITTER_NAME="LiaoZiqi-GZFLS" GIT_COMMITTER_EMAIL="LiaoZiqi-GZFLS@users.noreply.github.com" \
git commit -m "feat(y1-c2): AXI 读主口 + Verilog AXI 内存模型（读闸门含对齐/长度负对照）"
```

---

### Task C2.1b: AXI 写主口 + 写闸门

**Files:**
- Modify: `y1/rtl/DdrMaster.scala`（加写路径）
- Create: `y1/rtl_test/DdrWriteTb.v`
- Create: `y1/tools/run_ddrwrite_ab.sh`

- [ ] **Step 1: 加写路径** —— 从块缓冲向 `axi.w` 发 16 拍（`awlen = 15`），等 `B` 响应，累计 `wr_bytes`。**必须遵守 P4：W 与 AW 同门**（同拍有效，或严格按"AW 握手成功后才发 W"的顺序 —— 选一种并写进注释，说明为什么桥能接受：桥是 `w.wready := wrState === sWrAgg`，`awready := wrState === sWrIdle`）。

- [ ] **Step 2: 写装置与闸门**

装置 `DdrWriteTb.v`：从 `+PATFILE=` 读一段数据**预置进块缓冲**（或用一个确定性的生成式），发一笔/多笔写，仿真结束后**转储内存**。
闸门 `run_ddrwrite_ab.sh`：
1. **正对照**：Python 独立算出"内存那段应该被写成什么"，与转储**逐字节**比对，打 `MISMATCH`；
2. **`wstrb` 负对照**：故意让某一拍 `wstrb` 少一个字节，断言比对**抓得到**（证明判据看的是字节，不是"整拍写没写"）；
3. **背靠背负对照**：连续两笔写不插入间隔，断言**两笔都到**（防止"第二笔被吞"这种单 outstanding 常见坑）。

退出码同上（0/1/2）。

- [ ] **Step 3: 跑 + 结构判据**

```bash
cd /d/code/PDS/VexiiYeshenLinux/y1
bash tools/run_ddrwrite_ab.sh ; echo "gate_exit=$?"
bash tools/run_ddrread_ab.sh ; echo "read_regression_exit=$?"   # 读路径不能被写路径改坏
python tools/check_dangling.py gen/DdrMaster.v | tail -1
md5sum gen/DdrMaster.v
printf 'Test/runMain DdrMasterGen D:/code/PDS/VexiiYeshenLinux/y1/gen\nexit\n' | bash sbt.sh >/dev/null 2>&1
md5sum gen/DdrMaster.v
```

Expected: 两个闸门都 0、dangling 0、两次 md5 一致。

- [ ] **Step 4: 提交**

```bash
cd /d/code/PDS/VexiiYeshenLinux
git add y1/rtl/DdrMaster.scala y1/rtl_test/DdrWriteTb.v y1/tools/run_ddrwrite_ab.sh
GIT_AUTHOR_NAME="LiaoZiqi-GZFLS" GIT_AUTHOR_EMAIL="LiaoZiqi-GZFLS@users.noreply.github.com" \
GIT_COMMITTER_NAME="LiaoZiqi-GZFLS" GIT_COMMITTER_EMAIL="LiaoZiqi-GZFLS@users.noreply.github.com" \
git commit -m "feat(y1-c2): AXI 写主口（含 wstrb 与背靠背负对照）"
```

---

### Task C2.1c: 块拷贝 + **J1 字节级往返** + 主口开销

**Files:**
- Modify: `y1/rtl/DdrMaster.scala`（把读/写串成块拷贝）
- Create: `y1/rtl_test/DdrCopyTb.v`
- Create: `y1/tools/run_ddrcopy_ab.sh`
- Create: `y1/tools/predict_traffic.py`

- [ ] **Step 1: 串成块拷贝** —— FSM：`IDLE → RD(chunk) → WR(chunk) → 下一块 / DONE`。**读写不并发**（P5）。

- [ ] **Step 2: 装置 `DdrCopyTb.v`** —— 预载内存（`+MEMFILE=`）→ 发 `start(src,dst,len)` → 等 `done` → **转储内存** + 打印 `CYC=<n> RD_BYTES=<n> WR_BYTES=<n> ERR=<b>`。

- [ ] **Step 3: 闸门 `run_ddrcopy_ab.sh` —— J1 + 主口开销**

1. **J1 正对照（字节级往返）**：
   - 预置数据用**非平凡模式** `byte[i] = (i*131 + 7) & 0xFF`（**不能用全 0** —— 全 0 会让"根本没搬"也通过）；
   - `LEN` **≥ 1 MB**（太小会让计数器数错混过去）；
   - Python 独立算出"源段应等于目标段"，与转储的**目标段逐字节**比对：
     - 断言 **目标段 == 源段**（`MISMATCH=0`）；
     - **并断言源段未被改动**（防"搬成了原地覆盖"这类假通过）。
2. **J1 负对照（必须一红）**：
   - (a) 把 `+DST` 偏 4 字节 ⇒ `MISMATCH` **非 0** 且能报出**首个不符偏移**；
   - (b) 把源数据改掉一个字节 ⇒ 同样必须被抓住。
3. **主口开销判据（J2 的仿真半边）**：
   - `LEN`、`RD_BYTES`、`WR_BYTES`、`CYC` 都从 TB 读出；
   - **⚠ 口径（2026-10-08 修正，原式子是错的）**：拷贝是**非重叠**的"8 B/拍读 + 8 B/拍写"，所以**每个 32 B 组的地板就是 8 拍**（R 4 拍 + W 4 拍）。因此**不能**用 `CYC / (LEN/32)`（那样算出来恒 ≥8，任何实现都"不过"）；
   - 正确口径是**主口自己额外加的拍数**：
     ```
     组数      groups      = LEN / 32
     数据拍数  data_beats   = LEN / 8 * 2      （读 LEN/8 拍 + 写 LEN/8 拍，拷贝不改字节数）
     cyc_per_group_added    = (CYC - data_beats) / groups
     ```
   - **判据：`cyc_per_group_added ≤ 2`** @100 MHz —— 即主口为每组 32 B 只**额外**花 ≤ 2 拍（20 ns），远小于桥自己的 116 ns/32 B；
   - 打印 `cyc_per_group_added`、`data_beats`、以及"主口开销占桥成本的百分比"。

- [ ] **Step 4: `predict_traffic.py` —— J2 的静态合成（**必须标"预测"**）**

**诚实性前提（必须写进脚本头与报告）**：桥的 116 ns/32 B 里 **60 ns 在 100 MHz 域、56 ns 在 125 MHz 域**，**单时钟仿真复现不了它**。所以：

- **档 (ii)（本计划默认）**：静态合成
  `预测 traffic 速率 = 32 B / (116 ns + cyc_per_group_added × 10 ns)`；
  判据：**≥ 220 MB/s**（= 275.9 的 80%），并**明确标注这是"预测而非实测"**。
  脚本用法：`predict_traffic.py <cyc_per_group_added>`，打印预测值、占上限的百分比、等价的有效拷贝速率（= 一半），以及是否过 80% 线。
- **档 (i)（可选，见 C2.4）**：两时钟仿真 + 行为级桥模型 ⇒ **实测**。若 C2.4 做了，报告里以实测为准并撤下"预测"标注。

- [ ] **Step 5: 跑**

```bash
cd /d/code/PDS/VexiiYeshenLinux/y1
bash tools/run_ddrcopy_ab.sh ; echo "copy_exit=$?"
python tools/predict_traffic.py <上一步打印的 cyc_per_group>
bash tools/run_ddrread_ab.sh  >/dev/null 2>&1 ; echo "read_regression_exit=$?"
bash tools/run_ddrwrite_ab.sh >/dev/null 2>&1 ; echo "write_regression_exit=$?"
python tools/check_dangling.py gen/DdrMaster.v | tail -1
```

Expected: `copy_exit=0`（J1 正对照 + 两个负对照）、`cyc_per_group ≤ 2`、预测 traffic ≥220 MB/s、两个回归 0、dangling 0。

- [ ] **Step 6: 提交**

```bash
cd /d/code/PDS/VexiiYeshenLinux
git add y1/rtl/DdrMaster.scala y1/rtl_test/DdrCopyTb.v y1/tools/run_ddrcopy_ab.sh y1/tools/predict_traffic.py
GIT_AUTHOR_NAME="LiaoZiqi-GZFLS" GIT_AUTHOR_EMAIL="LiaoZiqi-GZFLS@users.noreply.github.com" \
GIT_COMMITTER_NAME="LiaoZiqi-GZFLS" GIT_COMMITTER_EMAIL="LiaoZiqi-GZFLS@users.noreply.github.com" \
git commit -m "feat(y1-c2): 块拷贝 + J1 字节级往返（非平凡向量 ≥1MB + 两个负对照）+ 主口开销与 traffic 预测"
```

---

### Task C2.2: SoC 集成（黑盒 + 并入 merger + 窗口 + IRQ + 台账五处）

**前置**：C2.0 的 before 基线已在手。**本任务会重生成整块 SoC 网表**（设计文档 R3）。

**Files:**
- Modify: `src/YeshenSocGlue.scala`
- Modify: `scripts/check_addr_map.py` 的 `EXPECT`
- Modify: OpenSBI `config.mk` / tb 装载表 / `sw/buildroot-external/boards/naxmini/linux/linux_raw.dts` / 板级顶层（**台账五处一起改**）
- Modify: `board/yeshen_mini_soc.v`（黑盒例化与端口）

- [ ] **Step 1: 读既有 merger，按它的模板接 NPU 的内存主口**

```bash
grep -nE "merger|合并|§4|memRdBusy|a_cmdFork_fire" src/YeshenSocGlue.scala | head -20
sed -n '620,790p' src/YeshenSocGlue.scala
```

**照它的模板**（不要另写一套），把 NPU 的内存主口作为**第 N 个主**并入；**特别照抄 §764 那条"W 必须与 AW 同门"的纪律**。

- [ ] **Step 2: 加 NPU 黑盒与端口**
- NPU 作为 Verilog 黑盒进胶合（**本工程已有先例**：`VexiiRiscv` 就是黑盒网表进同一块，见 `board/yeshen_mini_soc.v:451`）；
- `DdrMaster` 的 AXI 主口接到 merger；`HostRegs` 的 AxiLite4 从口接寄存器窗；
- **逐条列端口位宽**并加一条"端口位宽自证"判据（防静默连错，设计文档 R4）。

- [ ] **Step 3: 寄存器窗 `0xF000C000` + IRQ 源 3**
- 窗口解码加进 `YeshenSocGlue`；
- `done`/`err` 合成一条 IRQ → `peripheral_externalInterrupts_port[3]`（照 `:88` 的源 2 写法）。

- [ ] **Step 4: 台账五处一起改，跑闸门（J4）**

```bash
cd /d/code/PDS/VexiiYeshenLinux
python scripts/check_addr_map.py ; echo "addr_map_exit=$?"
```

Expected: **PASS**（五处逐字相等）。**不过则 C2 不算完成。**

- [ ] **Step 5: 提交**

```bash
cd /d/code/PDS/VexiiYeshenLinux
git add src/YeshenSocGlue.scala scripts/check_addr_map.py board/yeshen_mini_soc.v sw/buildroot-external/boards/naxmini/linux/linux_raw.dts
# 其余台账两处按实际改动路径一并 add
GIT_AUTHOR_NAME="LiaoZiqi-GZFLS" GIT_AUTHOR_EMAIL="LiaoZiqi-GZFLS@users.noreply.github.com" \
GIT_COMMITTER_NAME="LiaoZiqi-GZFLS" GIT_COMMITTER_EMAIL="LiaoZiqi-GZFLS@users.noreply.github.com" \
git commit -m "feat(y1-c2): NPU 并入 YeshenSocGlue 内存 merger（寄存器窗 0xF000C000 / IRQ 源 3），台账五处对齐并通过闸门"
```

---

### Task C2.3: 含 NPU 的 SoC 级 dev_map + 既有判据回归 + C2 结论

**Files:**
- Create: `y1/reports/c2_ddr_master.md`
- Create: `y1/pds/devmap_soc_npu.tcl`（在既有 SoC devmap 脚本基础上加 NPU 源）

- [ ] **Step 1: 重生成 SoC 网表并对比 before 指纹**

```bash
cd /d/code/PDS/VexiiYeshenLinux
md5sum rtl/YeshenSocGlue.v
git diff --stat rtl/YeshenSocGlue.v 2>/dev/null | tail -3
```
Expected: 指纹**变了**（改了胶合就该变）；把 before/after 都记进报告。**若没变 ⇒ 说明改动没进生成链，停下查。**

- [ ] **Step 2: 跑含 NPU 的 SoC 级 dev_map**

```bash
cd /d/code/PDS/VexiiYeshenLinux
/c/Pango/PDS_2025.2-ads/bin/pds_shell.exe -file "D:/code/PDS/VexiiYeshenLinux/y1/pds/devmap_soc_npu.tcl" \
  > y1/pds/devmap_soc_npu.log 2>&1 ; echo "exit=$?"
grep -nE "Mapping Summary|Device Utilization Summary" -A 14 y1/pds/devmap_soc_npu.log
grep -nE "DRC-0018|Program Error" y1/pds/devmap_soc_npu.log | head
```

Expected: 出资源表、无 `DRC-0018`。**注意 M0 的教训**：`dev_map` 失败时**没有** `Device Utilization Summary`，数字要从 `Mapping Summary` + `GTP_*` 行取并注明来源。

- [ ] **Step 3: 结构判据 + 确定性 + 既有判据回归（R3）**

```bash
cd /d/code/PDS/VexiiYeshenLinux
python y1/tools/check_dangling.py rtl/YeshenSocGlue.v | tail -2
bash y1/tools/check_no_xilinx.sh rtl | tail -2
python scripts/check_addr_map.py ; echo "addr_map_exit=$?"
bash y1/tools/run_ddrcopy_ab.sh >/dev/null 2>&1 ; echo "copy_gate_exit=$?"
bash y1/tools/run_hostregs_ab.sh >/dev/null 2>&1 ; echo "hostregs_gate_exit=$?"
```

Expected: 全部 PASS/0。**若既有 SoC 判据（台账/结构）出现回归，先判"是我引入的还是本来就红"**（对比 C2.0 的 before），再决定修。

- [ ] **Step 4: 写 `y1/reports/c2_ddr_master.md`**，逐条对上设计文档的判据：
1. **J1 字节级往返**：向量、`LEN`、`MISMATCH`、两个负对照的结果与退出码；
2. **J2 吞吐**：用的是**哪一档**（(i) 两时钟实测 / (ii) 单时钟 + 静态合成）—— **必须标明**；给出 traffic 速率、占 275.9 MB/s 的百分比、以及是否 ≥220 MB/s；
3. **J3 结构**：dangling 0、无 Xilinx 残留、md5 确定性、`awlen/arlen ≤ 15` 且地址低 5 位对齐；
4. **J4 台账**：`check_addr_map.py` PASS 的原文；
5. **SoC 级资源**：含 NPU 的 LUT/FF/APM/DRM 与 before/after 对比；
6. **可复现命令 + 指纹**清单；
7. **未验证/已知缺口**（如实）：无板级实测、无时序、单 outstanding 下与 CPU 争用的份额未测（属 C5）、`fuse_both` 的流缓冲面积未复核（属 C3）。

- [ ] **Step 5: 提交**

```bash
cd /d/code/PDS/VexiiYeshenLinux
git add y1/reports/c2_ddr_master.md y1/pds/devmap_soc_npu.tcl
GIT_AUTHOR_NAME="LiaoZiqi-GZFLS" GIT_AUTHOR_EMAIL="LiaoZiqi-GZFLS@users.noreply.github.com" \
GIT_COMMITTER_NAME="LiaoZiqi-GZFLS" GIT_COMMITTER_EMAIL="LiaoZiqi-GZFLS@users.noreply.github.com" \
git commit -m "docs(y1-c2): C2 结论（J1 字节级往返 / J2 吞吐口径与档位 / J3 结构 / J4 台账 / SoC 级资源）"
```

---

### Task C2.4（条件）: 两时钟仿真 + 行为级桥模型 ⇒ J2 从"预测"升为"实测"

**前置**：仅当 **C2.1c 的 `cyc_per_group > 2`**，或**评审要求 J2 必须是实测**时才做。否则跳过，并在报告里写明"未做，理由 X"。

**Files:**
- Create: `y1/rtl_test/BridgeModel.v`（行为级：复现 4 相 CDC 握手 6 拍@100 / 7 拍@125、每笔 1 个 256-bit beat、单 outstanding）
- Create: `y1/rtl_test/DdrCopy2ClkTb.v`
- Create: `y1/tools/run_ddrcopy_2clk.sh`
- Modify: `y1/reports/c2_ddr_master.md`

- [ ] **Step 1: 写行为级桥模型**，并在注释里**逐条对上出处**（`src/soc/CDCQueue.scala` 的同步级数与握手门、`src/soc/DDR3Bridge.scala` 的单 outstanding/1 beat/32 B 分组），**说明它建模了什么、没建模什么**（没建模：DRAM 效率、bank 冲突、refresh —— 那些本来就要板级实测）。
- [ ] **Step 2: 写两时钟装置**（100 MHz AXI 侧 + 125 MHz DDR 侧），跑同一份 J1 向量。
- [ ] **Step 3: 判据**：① J1 也必须在两时钟下**字节级一致**（否则桥模型或主口有真问题）；② **实测 traffic 速率 ≥ 220 MB/s**；③ **行为模型自证**：把模型的 CDC 拍数改成 5/6（少一拍），断言实测速率**变化**（证明模型真的在计那 13 拍，而不是摆设）。
- [ ] **Step 4: 更新报告**，把 J2 从"预测"改为"实测"，并撤下预测标注；若实测与预测差 >20%，**两个数都留**并说明差异来源。
- [ ] **Step 5: 提交**（同环境变量）
```bash
git commit -m "feat(y1-c2): 两时钟仿真 + 行为级桥模型 —— J2 升为实测"
```

---

## 自查记录

1. **设计覆盖**：设计文档 §4 的 P1–P6 → C2.1a/1b/1c 的接口与 FSM 约束（尤其 P4 的 W-AW 同门在 C2.1b Step 1 明写）；§5 的窗口与 IRQ → C2.2 Step 3；§5 的台账五处 → C2.2 Step 4 + C2.3 Step 3；§8 的 J1/J2/J3/J4 → 分别在 C2.1a+C2.1c / C2.1c+C2.4 / C2.3 / C2.2；§9 的 R1 → C2.3 Step 4 的"未验证清单"（明确推给 C5）；R3 → C2.0 的 before + C2.3 的回归；R4 → C2.2 Step 2 的端口位宽自证。
2. **占位扫描**：无 TBD。`AxiMemModel.v` 与行为桥模型给了**逐条要求**（预载/转储/自检/统计），而非"实现即可"；`predict_traffic.py` 给了公式与判据阈值。C2.4 是**条件任务**且条件写死（`cyc_per_group > 2` 或评审要求），不是占位。
3. **类型一致性**：`DdrMaster` 的端口（`start/src/dst/len/busy/done/err/cyc/rd_bytes/wr_bytes/buf_dout/axi`）在 C2.1a 定义，C2.1b/C2.1c 只增行为不改签名；`DdrMasterConfig` 的 `CHUNK_BYTES=128` 与"16 拍突发"在两处一致；三个闸门的退出码约定（0/1/2）与 `y1/tools/` 既有的五个闸门一致；`check_dangling.py`（取文件）/`check_no_xilinx.sh`（取目录）的用法沿用 Y1 已建立的约定。
4. **诚实性补丁（写计划时发现并已修进设计文档）**：原来设计文档把"吞吐 ≥137.9 MB/s"混了 **traffic** 与**有效拷贝速率**两种口径（拷贝每份数据要过 2 倍 traffic）。已改成：**C2（空载）判 traffic ≥248 MB/s（= 275.9 的 90%）**，等价于有效拷贝 ≥124 MB/s；**50% 争用下的达标属 C5 的负载实测**。并且明确了 **J2 在单时钟下测不出桥的 116 ns/32 B**，因此给了 (i)/(ii) 两档并强制标注。
