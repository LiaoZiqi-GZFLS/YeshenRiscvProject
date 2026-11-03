# Y1 实施计划：**C4b —— 权重从 DDR 批量装载 + 整帧端到端上板**（G6/G7）

> **For agentic workers:** 用 `superpowers:subagent-driven-development` 逐任务执行。

**Goal:** 让硬件**吃下真网、算完整一帧**：③ 权重 blob（403,776 B）**从 DDR 批量装载**（不再逐字节信箱）、
④ 宿主侧输入/输出 + 前后处理、**整帧端到端与 float ORT 容差级一致**（G7）。

**前置（已收口，引用前复核）**
- C3：调度器/描述符/旁路算子/融合缓冲 —— **上板六级过**（`y1/reports/c3_board_bringup.md`）。
- C4a：转换器 + 通道覆盖 + depthwise + 布局折进 —— 全部离线闸门绿（`y1/reports/c4a_multipass.md`）；
  产物 `y1/gen/{desc.bin 2176B, wgt_blob.bin 403776B, wgt_index.json 186541B}`。
- NPU 独立时钟：`npu_clk` 50MHz，PnR `All Constraints Met`，**上板重验过**（`y1/reports/npu_clock.md` 附录 B）。

**设计依据：** `docs/superpowers/specs/2026-10-10-y1-c4-converter-and-coverage-design.md`
（§1 的 ③④ = 本计划的全部内容；§5 的 **G6/G7**；§4.4 的 `M` 表、§4.5 的 `z_pad/bias_adj`、§6 的 R1/R4）。

**本计划只做 C4b。C5（帧率/争用）在它之后。**

---

## 全局约定（与 C3/C4a 逐条相同）

- **只读资产**：`third_party/**` 与冻结工具（`ddr_traffic.py`/`fusion_buffer.py`/`bypass_traffic.py`/
  `mac_ref.py`/`bypass_ref.py`/`conv_unit_ref.py`/`desc_table.py`）—— import 复用，绝不改。
- **不改**：描述符格式、寄存器契约、C3 的调度语义；改 RTL 就要跑 15 单元闸门 + 台账 + dangling + **重跑 PnR**。
- **判据必须带正负对照**；产物记指纹（md5/字节数）；不匹配要**响亮失败**；闸门退出码 `0/1/2/3`。
- 生成器 `headerWithDate=false`/`headerWithRepoHash=false`。
- **Python**：`cd /d/code/PDS/VexiiYeshenLinux/y1 && PYTHONIOENCODING=utf-8 PYTHONPATH='./.pydeps;../third_party/yunet/deps' /d/code/PDS/NaxYeshenLinux/sim/reglogs/lxvenv/Scripts/python.exe <script>`。
- **上板**：`scripts/flash_and_verify.py --tag pnr_c4a_npuclk --com COM7`；登录 `scripts/uart_login_pw.py COM7 115200 yeshen`；
  板内命令走 `scripts/guest_cmd.py COM7 115200 "<cmd>"`（**逐条等 marker，不塞满 tty**）。
- **提交**：单次注入 `GIT_AUTHOR_*`/`GIT_COMMITTER_*`；**不 push**。
- ⚠ 板上内存口径（C3 实测冻结）：NPU 地址 `A` ↔ 物理 `0x80000000+A`；安全区 `0x8000_0000-0x803F_FFFF`。

---

### Task B1: **权重 blob 从 DDR 批量装载**（G6 的装载半）

**Files:** Modify `y1/rtl/{WeightStore,UnitExec,LayerSched,NpuTop,HostRegs}.scala`；Create `y1/rtl_test/WgtDmaTb.v` + `y1/tools/run_wgtdma_ab.sh`

- [ ] **Step 1 冻结数据流（写进 `UnitExec.scala` 文件头）**：每层开始前，NPU **用自己的 `DdrMaster`**
  从 DDR 读该层的权重段（起点 = 表序前缀和 `Σ_{j<i} N_j'`，**段长 `N_i' = ceil32(N_i)`、`N_i = C_out*(C_in/GROUP)*9`**；
  ★ **2026-10-12 B0 修订**：每单元段补齐到 32 B 倍、32 B 对齐，补位 `0`，见 spec §4.2 的布局修订 —— `DdrMaster`
  要求 `src%32==0 && len%32==0`，C3.3）灌进该切片的 `WeightStore`；
  **不再由 host 逐字节推信箱**（信箱保留为调试/覆盖口）。`wgt_index.json` 的 `offset/aligned_bytes`（物理）与
  `nbytes`（真实）是**对账基准**。
- [ ] **Step 2 判据** `run_wgtdma_ab.sh`：① 装载后 `WeightStore` 与 blob **逐字节相等**（按 `wgt_index.json` 逐单元对）；
  ② **装载字节数 == blob 大小**（多/少都要红）；③ **负对照**：改 blob 一个字节 ⇒ 必须红（且能定位到单元）。
- [ ] **Step 3 提交。**

### Task B2: **装载/计算重叠纪律 + `M`/`z_pad`/`bias_adj` 的投递**（G6 的另一半）

**Files:** Modify 同上 + `y1/reports/c4b_wgtdma.md`

- [ ] **Step 1**：把 §4.4 的 `M` 表与 §4.5 的 `z_pad`/`bias_adj` **也随 blob 同序从 DDR 走**（或明确记录"为什么仍走信箱"），
  并写清**重叠纪律**：第 i 层的权重装载可否与第 i-1 层的计算重叠（**若重叠**，给出互不踩的条件与判据）。
- [ ] **Step 2 判据**：`M`/`z_pad`/`bias_adj` 装完与 `wgt_index.json` 逐项相等；**重叠**时给"总装载拍数 vs 不重叠"两个数；
  负对照：故意让某层装载晚一拍 ⇒ 必须红（证明重叠是有纪律的，不是碰巧）。
- [ ] **Step 3**：全回归（15 闸门 + 台账 + dangling）+ 重跑 PnR（`All Constraints Met`）+ 提交。

### Task B3: **输入布局**（DDR → NPU 期望的 ci-block-planar）

**Files:** Python 宿主工具（新建）+ 必要时 RTL

- [ ] **Step 1**：确认真网输入的期望布局：conv 首层 `C_in=3`、后续层 `C_in` 为 8 的倍数；
  多趟通路的 `wide_x` 现在是**谁喂**（C4a.5b 记：`LayerSched` 系 0，DDR→ci-block-planar **gather 属 C4b**）⇒ 本任务实现它。
- [ ] **Step 2 判据**：**宿主写一批已知图 → NPU 读到的 ci-block-planar 与参考逐字节对**；
  负对照：布局写错（通道序反）⇒ 必须红。
- [ ] **Step 3**：提交。

### Task B4: **布局算子在 RTL 侧**（Transpose/Reshape 的 strided read）—— 条件任务

- [ ] **Step 1**：C4a.7 只在**转换器**侧算好 `(src_stride, src_order)`。**判**：B3 的布局是否已把转置吸收掉；
  若**没有**，在 RTL 侧实现 strided read（`DdrMaster` 读地址按 `src_stride` 跳）。
- [ ] **Step 2 判据**：折进寻址后的张量 == 显式转置（逐字节）；**DDR 读+写字节数不增**（打印两个数）；负对照：`src_order` 写反 ⇒ 红。
- [ ] **Step 3**（若需要）：全回归 + PnR + 提交。

### Task B5: **宿主驱动 + CPU 后处理 + ORT 参考**（G7 的宿主半）

**Files:** Create `y1/tools/npu_frame_run.py`（板上整帧驱动）+ `y1/tools/yunet_post.py`（CPU decode/NMS）+ `y1/tools/ort_ref.py`（float ORT + 官方后处理）+ `y1/tools/run_frame_ab.sh`

- [ ] **Step 1**：驱动：把 640×640×3 int8 输入写 DDR（安全区）→ 写 `desc.bin` 到 DDR → 配 `DESC_ADDR/DESC_COUNT`
  → `CTRL.start` → 等 done/IRQ → 读 12 路输出到主机。
- [ ] **Step 2**：后处理：按 YuNet 官方口径 decode 框/关键点 + NMS（**CPU**，不进硬件）。
- [ ] **Step 3 判据** `run_frame_ab.sh`（**离线可跑的部分**）：同口径 `quant_ref` 与后处理管线在**离线**上对得上；
  `ort_ref` 出 float 基线。退出码 `0/1/2/3`。
- [ ] **Step 4**：提交。

### Task B6: **G7 整帧端到端上板 + 容差 + 负对照**

- [ ] **Step 1**：上板跑整帧（**大 blob 走网络/分段**，别用 UART 硬灌 —— R5）。硬件(+CPU 后处理) vs **float ORT(+官方后处理)**：
  **匹配框 IoU ≥ 0.5**、**关键点平均 L2 ≤ 2 px**（640×640 尺度）、**置信度 |Δ| ≤ 0.1**、**检出数差 ≤ 1**。
- [ ] **Step 2 负对照**：喂**无人脸**的图 ⇒ **无检测**（且正对照是同一张有脸图能检出）。
- [ ] **Step 3**：给出**整帧 DDR 流量与帧时**（**声明下界/上界口径**）；与 C4a 的 `ddr_traffic` 模型合账。
- [ ] **Step 4**：提交。

### Task B7: **C4b 收口** —— O1/O2 + 报告 + 面积/时序回归

- [ ] **Step 1**：**O1**（Relu 折进尾声 vs 黄金两步的 ±1 码）与 **O2**（旁路 `QUANT_SHIFT` 占位值）**定案并写清**（不得留悬）。
- [ ] **Step 2**：全回归（15 单元 + C4a 8 闸门 + C4b 闸门 + 台账 + dangling）+ **重跑 PnR**（`All Constraints Met`）+ 面积 Δ 表。
- [ ] **Step 3**：`y1/reports/c4b_frame.md`：G6/G7 证据 + **能证/不能证**（不能证：真摄像头/Y5；fps 归属见 C5）。

---

## 自查记录

1. **覆盖面**：§1 的 ③（权重从 DDR）→ B1/B2；④（宿主 I/O + 前后处理）→ B3/B5；布局 RTL → B4；
   G6 → B1/B2；**G7 → B5/B6**；R5（UART 脆弱）→ B6 Step 1 的"大 blob 走网络"。
2. **占位**：无 TBD；未定处（B2 的 M 表来源、B4 是否必要）**给了判据与两选一**，执行时按实测定并记录。
3. **诚实标注**：G7 的容差数值（IoU/L2/conf/检出数）是 spec §4.3 拟定的、**可调**；达不到先查校准口径。
