# 实施计划：**通用 SoC DMA 引擎（方案 C）** —— DDR/互联放开 + 真仲裁 + 多通道

> **For agentic workers:** 用 `superpowers:subagent-driven-development` 逐任务执行。

**Goal:** 一个**多通道 DMA 引擎**（DDR↔外设块搬运），并把**承重的两件**一并做掉：**DDR 桥放开多未完成**、
**§3.5 一热 mux 换成真仲裁** —— 使并发真能换带宽。

**设计依据：** `docs/superpowers/specs/2026-10-13-y1-soc-dma-engine-design.md`（§2 家底、**§3.1 已裁决=C + 四相顺序**、§5 D1–D6、§6 风险）。

**⚠ 顺序是本计划的核心**：**Phase-0（承重前提）判不出来，就不要往下做**（§3.1 R5）。

---

## 全局约定（沿用 C3/C4 计划）

- **只读资产**：`third_party/**` 与冻结工具（`ddr_traffic.py`/`fusion_buffer.py`/`bypass_traffic.py`/`mac_ref.py`/`bypass_ref.py`/`conv_unit_ref.py`/`desc_table.py`）。
- **每相都**：15 个单元闸门 + `check_addr_map.py` + `check_dangling.py` 全绿；**改了 RTL 就重跑 PnR**；产物记指纹。
- **判据必须带正负对照**；闸门退出码 `0/1/2/3`；生成器 `headerWithDate=false`/`headerWithRepoHash=false`。
- **Python**：`cd y1 && PYTHONIOENCODING=utf-8 PYTHONPATH='./.pydeps;../third_party/yunet/deps' /d/code/PDS/NaxYeshenLinux/sim/reglogs/lxvenv/Scripts/python.exe <script>`。
- **上板**：`scripts/flash_and_verify.py --tag <TAG> --com COM7`；板内命令走 `scripts/guest_cmd.py COM7 115200 "<cmd>"`。
- **提交**：单次注入 `GIT_AUTHOR_*`/`GIT_COMMITTER_*`；**不 push**。

---

## Phase 0 —— ★ 承重前提：**DDR 桥放开多未完成**（判得出"能不能"）

**Files:** Modify `src/soc/DDR3Bridge.scala`；TB `sim/ddr3bridge/`；`y1/reports/dma_phase0.md`

- [ ] **T0.1 先冻结红线（写进文件头）**：现状是 **单未完成 + 每 AXI 突发拆成 `ceil(beats/4)` 笔单 beat**
  （因 DDR 侧 W 无 `wvalid/wready`、跨域是电平式 `CDCPipe`；`:36-58` 记着两个真坑）。
  本轮要把它放开到 **AW/W/AR/R 各能多未完成**，且**不改 DDR IP 的对外口**。
- [ ] **T0.2 实现**：给每条通道加 **FIFO**（"电平握手一次一份" → "FIFO 攒拍 + 独立发单 beat"），
  按 DDR 侧的**固定节拍**发单 beat；读通道按 `rid`/顺序回收。**保持地址语义**（首址 32B 对齐、地址 +8 字/beat 不变）。
- [ ] **T0.3 判据（先红后绿）**：`sim/ddr3bridge/` 既有闸门（含 **NC3** 负对照）全绿；
  **新增**：背靠背 N 笔（读/写/读写混）**逐字节对** + **未完成计数 > 1 的证据**（波形/自报计数）；
  **负对照**：把 FIFO 深度改 1 ⇒ 退化回单 outstanding（证明"深度"是承重的）。
- [ ] **T0.4 回归 + 记账**：15 单元闸门 + 台账 + dangling；`dev_map` 面积 Δ；**重跑 PnR**（`All Constraints Met`）。
- [ ] **T0.5 ★ 判词（Gate-P0）**：明确回答 **"DDR 侧能不能多未完成、放开后带宽/时序/面积各是多少"**。
  **判不出或收益为 0 ⇒ 停，回 §3.1 的退路（A 口径）**。

## Phase 1 —— §3.5 换**真仲裁**（`owner` 位宽 + 优先级/配额）

**Files:** Modify `src/YeshenSocGlue.scala`（`:744-871` 合并点、`:1040-1078` `memSel`）

- [ ] **T1.1**：把一热 `memSel` 换成真仲裁（非阻塞、带优先级/配额：CPU 组 > NPU > DMA，或可配），`owner` 位宽加宽。
- [ ] **T1.2 判据**：多主口并发时的**公平性/无饥饿**（正）；**负对照**：把配额打乱 ⇒ 可观测的饥饿/退化 ⇒ 必红；
  且**单主口行为与现在逐字节相同**（回归）。
- [ ] **T1.3**：全回归 + PnR + 记账。

## Phase 2 —— **多通道 DMA 引擎** + 客户端接入

**Files:** Create `src/peripheral/DmaEngine.scala`（+ 生成/闸门 `sim/dmaeng/`）；Modify `src/peripheral/SdLoader.scala`、`board/liteeth_wrap.v`（rx/tx 槽）、`YeshenSocGlue.scala`（窗 + 主口 + IRQ）、`PlicAlite.scala`（NDEV 3→4）

- [ ] **T2.1 引擎**：CSR 形状**沿用 `DdrMaster`**（`src/dst/len/mode/done/err/bytes/cycles`）+ **多通道**（每通道独立 desc 寄存器）
  + **`abort`** + **DDR 描述符环**（§3.1 的 B 形态，作为通道队列）。
- [ ] **T2.2 客户端**：① **SD 装载器**改走引擎（**D3：同一镜像装载结果与现在逐字节相同**）；
  ② **网络**（rx 槽→DDR / DDR→tx 槽）；③ 相机留口。
- [ ] **T2.3 判据**：D1（三向背靠背逐字节）/ D2（`bytes_moved` 对账 + 非法参数响亮 err）/ D5（源 4 中断 claim/complete）。
- [ ] **T2.4**：台账五件套（`EXPECT` + `check()` + `YeshenMap` + DTS）+ 全回归 + PnR。

## Phase 3 —— 收口

- [ ] **T3.1 D6 速度口径**：同样 1 MB 的 **CPU 占用 / 墙上时间**（引擎 vs ssh+`ddmem` vs 逐字 `devmem`），声明上/下界；
  **NPU 帧 + DMA 同时**的退化（R2）。
- [ ] **T3.2**：全回归 + 上板（时机由用户给）+ `y1/reports/dma_engine.md`（能证/不能证）。

---

## 自查记录

1. **顺序即纪律**：Phase-0 是承重前提（§3.1）；**Gate-P0 不达标不许往下**。
2. **不动 DDR IP**：只改 `DDR3Bridge` 的对内实现，DDR IP 的对外口一字不改（T0.1）。
3. **诚实标注**：C 的收益**未经实测**（Phase-0 判）；若为 0，退回 A 口径并如实记录。
4. **不阻塞 Y1 整帧**：整帧堵在"真几何重生成网表 + PnR + 重烧"（F1 已定位），与本计划的 Phase-0 并行互不依赖。
