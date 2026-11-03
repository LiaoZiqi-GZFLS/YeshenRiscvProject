# Y1 T-S3 实现计划 —— **让真帧跑得完**（旁路算子 tiling + 宽路 gather per-plane band + 整表预检）

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让真表 67 个单元在 tiled 几何（`WIDTH=34 / H_TILE=32`）下一路跑到尾（**零 err**），使 **S3**（PnR → 比特流 → 板 → 12 路 + G7）**一次跑完整帧**。

**Architecture:** ① 给 `BypassExec` 加一层"**每算子无 halo 的 2-D tile 循环**"（输出 tile 32×32、`pool` 的列方向再切 `WIDTH/2`；**复用既有 `outMem`，零新增宽存储**）；② 把 `UnitExec` 宽路 gather 的 band 索引从"8 平面**共享**"改成"**每平面各记** `(bandBase, idxW, idxB)`"，去掉 `HW%32==0` 前提；③ 新增**整表几何预检**（Python 快门 + 模拟真 `desc` 终证）。

**Tech Stack:** Chisel/SpinalHDL → Verilog（sbt，`bash y1/sbt.sh`）、iverilog/vvp（Git Bash）、Python 3（`/d/code/PDS/NaxYeshenLinux/sim/reglogs/lxvenv/Scripts/python.exe`）、PDS 2025.2 `pds_shell.exe`（dev_map/PnR）。

**Spec:** `docs/superpowers/specs/2026-10-14-y1-frame-runnable-design.md`（本计划的契约来源；冲突以 spec 为准并回写）。

**硬约束（每个任务都适用）**
- 描述符格式（8 字）、数值口径（PTQ / requant / `z_pad`）**一字不动**。
- **冻结工具禁改**：`tiling_ref.py` / `multipass_ref.py` / `bypass_ref.py` / `bypass_traffic.py` / `ddr_traffic.py` / `fusion_buffer.py` / `mac_ref.py` / `conv_unit_ref.py` / `desc_table.py`。黄金一律**复用**，**不写第三条参考**。
- `third_party/**` 与所有被参考仓库**只读**（复制不修改）。
- 提交用**单次** `GIT_AUTHOR_*`/`GIT_COMMITTER_*`（**绝不** `git config`）；**commit ≠ 授权 push**（不 push）。
- 每段收口都要：`dev_map`（断言 `Adm-4088=0`、`DRM ≤ 415`）+ 既有闸门全绿。
- **回归证书**：`run_bypass_ab.sh`（旧路径）与 12 个既有闸门必须仍全绿。

---

## 基线（开工前做一次，记进报告）

- [ ] **Step 0.1** 记录当前 `git log -1 --format=%H` 与 `gen/*.v` 的 `md5sum`（尤其 `NpuTop.v`=`656cccf9a029ea033758ff4e3b8b7785`）。
- [ ] **Step 0.2** 跑既有闸门存基线：`bash y1/tools/run_bypass_ab.sh`、`run_tiling2d_rtl_ab.sh`、`run_tiling2d_wide_ab.sh`、`run_roww_ab.sh` —— 期望全 `RESULT: PASS`。
- [ ] **Step 0.3** 记板级 `dev_map` 基线：`Adm-4088=0`、DRM **375.5/415 = 90.48%**（`y1/pds/devmap_c4a.log`）。

---

### Task T-S3a.1: 冻结旁路 tiling 的数据流契约 + TB `+TILED_B` 模式（**先红**）

**Files:**
- Modify: `y1/rtl/BypassExec.scala`（**只加文件头契约一节**，无行为改动）
- Modify: `y1/rtl_test/BypassTb.v`（加 `+TILED_B` 模式：装置**不喂**列流、由 DDR 供料；判据=跑完+无 err+`busy` 落 0）
- Create: `y1/tools/run_bypass_tile_ab.sh`（先只有 `--selftest` 与"装置未过"的占位，Goal 是**先红**）

- [ ] **Step 1: 写契约（`BypassExec.scala` 文件头）** —— 逐条写死下面这份口径（供后续所有任务引用）：
```
旁路 tiling（T-S3a）契约：
· tile 网格：输出 tile 32×32（tNtx=ceil(IMG_W/32)、tNty=ceil(IMG_H/32)；末 tile 取余）；
  · pool ：**输出** tile 宽再切 = WIDTH/2（=16），高 32 ⇒ 每 tile 输入 32(列)×64(行)；outPix=512 ≤ MAXPIX=1088；
  · resize/add/sigmoid：输出 tile 32×32 ⇒ resize 输入 16×16 / add,sigmoid 输入 == 输出；outPix=1024 ≤ 1088。
· 输入窗口（**无 halo**，逐算子）：pool 行 [2·oy0,2·oy1)、列 [2·ox0,2·ox1)；resize 行 [⌊oy0/2⌋,⌊oy1/2⌋)、
  列 [⌊ox0/2⌋,⌊ox1/2⌋)；add/sigmoid == 输出窗口。**恒偶对齐**（resize 的 oy0/ox0 偶由既有 isRz 要求保证）。
· 读：**按输入行跨步**发 32 B 对齐窗口读（band 基址 &~31；与 UnitExec gather 同一 idiom）。
· 写：**每输出行一笔 32 B 对齐 + wstrb 掩码**（DdrMaster.io.wstrb；与宽路 tile WR 同一 idiom）。
· 收料：tile 内按局部序 (q-1)·tw+(j-1) 存 outMem[0..outPixTile)；写回段起点 = DST + ((oy0+q)·IMG_W+ox0)·C。
· 兼容（**运行期二选一**）：outPix(整层) ≤ MAXPIX(1088) ∧ rowW(整层) ≤ WIDTH ∧ 对齐前提满足 ⇒ **走原整层路径**；
  否则走 tile。原路径**行为逐字节同形**（既有闸门零改动）。
· **行宽对账口径搬到 tile**：tile 内 rowW = tile 输入列数（pool ≤ 32、resize ≤ 16、逐点 ≤ 32）⇒ 恒 ≤ WIDTH；
  MaxPool 的"行宽偶数"改判 **tile 输入列数**（pool 输入列 = 2·tw_out = 32 ⇒ 偶）；outPix 改判 **tile 输出像素**。
· **通道维（★ 2026-10-14 实测发现，与空间维并列的另一半）**：真表旁路层 `C_IN=C_OUT ∈ {16, 64, 1}`
  （`MaxPool_5`=16、`MaxPool_18/25/32`+`Resize_43/49`=64、`Sigmoid_*`=1），而 `geomOk` 要求 `dw.cIn===C ∧ dw.cOut===C`（C=8）
  ⇒ **通道分块**：`cIn/8` 个 block（src/dst 平面偏移 `+8·HW`，planar 布局；与 UnitExec 宽路 ci-block 同 idiom）；
  `C_in=1` 的**逐点**算子用**布局折**把 8 个连续像素当一拍（`C_eff=8`，`tPix=⌈W/8⌉ ≤ 800 ≤ MAXPIX`），数值口径不动。
  四算子**通道独立** ⇒ 通道分块不引入跨通道状态、**不新增存储**。
```

- [ ] **Step 2: TB 加 `+TILED_B`** —— `BypassTb.v` 增加一个模式（照抄 `UnitExecWideTb.v` 的 `+TILED_W`：`AxiMemModel` 供料/落盘、`+SRC/+DST/+INB/+CIN/+COUT/+TYPE/+GROUP`、判据=收工+无 err+`busy` 落 0）。**先不实现 RTL tile** ⇒ 期望本模式**红**（`err` 或超时）。

- [ ] **Step 3: 跑一次确认先红** `bash y1/tools/run_bypass_tile_ab.sh`（此时脚本只做 iverilog 编译 + 跑一个 `maxpool 16ch 160×160` 作业）⇒ 期望 `JUDGE-RED`（`err` 或 timeout）。把这条输出存进报告。

- [ ] **Step 4: 提交** `feat(y1-bypass): T-S3a 契约 + TB +TILED_B（先红）`

---

### Task T-S3a.2: 实现旁路 tile 循环（`BypassExec`）

> **执行顺序（2026-10-14 修订）**：本任务**分三小步**（`geomOk` 的两个前提耦合，且 `C_in=1` 是另一套机制）：
> **T-S3a.2a = 通道分块**（`cIn ∈ {16,64}` 的 `cIn/8` 块；src/dst 平面偏移 `+8·HW`）⇒ 用**小的** C=16/64 whole-layer 形状证死；
> **T-S3a.2b = 空间 tile**（行跨步窗口读 + 掩码行写回）⇒ 用真表大形状（160×160/80×80/…）证死；
> **T-S3a.2c = `C_in=1` 逐点（`Sigmoid_*`）** —— 布局折"8 像素 = 一拍"（`C_eff=8`）⇒ 用 W=400/1600/6400、H=1 证死。
> 每小步各自 commit。
>
> **T-S3a.2d（★ 2026-10-15 由 2a 实现中实测发现，追加）**：真表还有 **`Add_44`/`Add_50`（`C_IN=C_OUT=64`、`src2k=1`）**。
> 2a 之后它们仍**响亮 err**：多块要求 **planar 路径**，而 `planarOk` 在布局模式下**禁用 Add**（E1 的 B 趟 `io.src2` 走线性路径、没有 gather）。
> ⇒ 需要给 Add 的**第二源**也做一份行跨步 planar gather（或在多块下把 `src2` 也用同一套寻址）。归属本任务、单列一小步。
>
> **T-S3a.2d 收口（2026-10-15）**：**已落地**。口径 = **tile 的两趟**（`BypassExec` 的 `tPass`）——
> A 趟读 `SRC`（行跨步平面 gather）把列**原样**落 `outMem[tPixN]`、B 趟读 **`io.src2 + blkSrcR`**
> （**同一套**行跨步平面 gather + **同一个**通道块偏移累加器）并以 `x_a = outMem[tPixN]` /
> `x_b = 本拍 B 列` 同拍相加（`clamp8(A+B)`）⇒ **复用 `outMem`、0 新增宽存储**（DRM 余量约束）。
> `tileOpOk` 放 `Add ∧ addTwoSrc`；`planarOk` **一字未改**（布局模式下的 `Add` 永远走 tile；
> `src2k == 0`（列交织）或 `inCols % 32 != 0` ⇒ 仍旧**响亮 err + 零搬运**）。
> 闸门 = `tools/run_bypass_tile_ab.sh` 的 2 个 add 形状（C=64 40×40/80×80、`+SRC2=`/`+SRC2K=1`，
> 黄金仍**复用** `bypass_ref.py` 的 `add_nontrivial/split_add/add_ref/to_tensor`）+ **负对照③**
> （B 源丢 `blkSrcR` ⇒ 错配全部落在块 1 及以后、`FIRST_BAD == 8·outPix`、`maxpool` 档逐字节不变 = 外科式）。
> 先红证据：**同一张闸门**在改动前的 `gen/BypassExec_w34.v` 上 6 档绿、2 个 add 档 `err=1 rd=0 wr=0`。
> 网表 md5（重生成后）：`BypassExec.v 50eedf28cf4d88120675f1ccc5e2bfe9` /
> `BypassExec_w34.v 360698965fbec70b6c236b8b3e640c70` / `LayerSched.v 6523f5c1d89017fa7de7fe1b956871ef` /
> `NpuTop.v 8fa93d5d02924302d448b987bbff6c9b`（`gen/` 不入库 ⇒ 只记指纹）。

**Files:**
- Modify: `y1/rtl/BypassExec.scala`（**主改动**：tile FSM + 行跨步窗口读 + 掩码行写回）
- Modify: `y1/rtl_test/BypassExecGen.scala`（`gen/BypassExec_w34.v`：`C=8 WIDTH=34 IMG_H_MAX=32`；`gen/BypassExec.v` 仍按旧参数）

- [ ] **Step 1: tile FSM** —— 在 `BypassPhase` 后加 tile 相位（`TILESTART/TILERD/TILECALC/TILEWR/TILENEXT`），只在本 layer 判定"走 tile"时启用；`io.busy/done/err` 的对外语义不变（整层收工才 `done`）。
- [ ] **Step 2: 行跨步窗口读** —— 与 `UnitExec` 宽路 gather 同 idiom：`src = SRC + iy·(inWi·C) + aLo·C`、`len = (aHi-aLo)·C`（`aLo/aHi` 是 tile 输入列的 32 B 对齐区间）；`src/len` **寄存**（DdrMaster 的 CHK 在 `start` 下一拍读）。
- [ ] **Step 3: 掩码行写回** —— `len = ceil32(tw·C)`、`dst = DST + ((oy0+q)·IMG_W+ox0)·C`、`wstrb` 按段内偏移掩掉 tile 外字节。
- [ ] **Step 4: 对账搬移** —— `geomOk` 增一条"tile 分支"，`rowWOk`/`outPix ≤ MAXPIX` 按 **tile 口径**判（见 T-S3a.1 Step 1 契约最后两条）。
- [ ] **Step 4b: 通道分块（★ 契约最后一节）** —— `cIn/8` 个 channel block（src/dst 平面偏移 `+8·HW`）；`C_in=1` 的逐点算子（`Sigmoid_*`）用布局折"8 像素 = 一拍"。`geomOk` 把 `dw.cIn===C ∧ dw.cOut===C` 换成"`cIn % 8 == 0 ∨ cIn == 1`"（或等价的 block 口径），并在**收工**时按 block 数推进。
- [ ] **Step 5: 重生成 + 闸门转绿** `bash y1/tools/run_bypass_tile_ab.sh` ⇒ 期望 `RESULT: PASS`（`maxpool` **C=16** 160×160 与 gold 逐字节）。
- [ ] **Step 6: 提交** `feat(y1-bypass): T-S3a 旁路 tile 循环（行跨步窗口读 + 掩码行写回；复用 outMem）`

---

### Task T-S3a.3: 闸门 `run_bypass_tile_ab.sh`（正 + 两条负对照 + 退出码）

**Files:**
- Modify: `y1/tools/run_bypass_tile_ab.sh`
- Create: `y1/rtl_test/BypassTileGen.scala`（若需要：产 `gen/BypassExec_w34.v` 的 tiled 档；否则复用 `BypassExecGen`）

- [ ] **Step 1: 正对照（真表旁路形状）** —— `bypass_ref.py` 出整层黄金（**冻结参考，不写第三条**），RTL 走 tile：
  `maxpool` **C=16** 160×160（`MaxPool_5`）/ **C=64** 80×80 / **C=64** 40×40 / **C=64** 20×20；`resize` **C=64** 80×80 / 40×40；
  `add`；`sigmoid` **C=1** W=6400/1600/400（`H=1`，走布局折）。判据：`DST` 逐字节 == 黄金（`MISMATCH=0`）、邻居未动。
- [ ] **Step 2: 负对照①（漏一个 tile 行）** —— 网表突变 `tNty-1 -> tNty-2` ⇒ `MISMATCH>0` 且错配**定位在被漏的 tile 行带**。
- [ ] **Step 3: 负对照②（输入窗口对齐错一格）** —— 网表突变 pool 的窗口起点 `2·oy0 -> 2·oy0+1` ⇒ `MISMATCH>0`（证明"窗口对齐"这一条真在起作用）。
- [ ] **Step 4: 退出码** `0`=全过 / `1`=正对照红 / `2`=负对照没发火 / `3`=前置缺失。跑 `bash y1/tools/run_bypass_tile_ab.sh` ⇒ 期望 `RESULT: PASS`、`exit 0`。
- [ ] **Step 5: 提交** `test(y1-bypass): T-S3a 闸门（真表旁路形状 + 漏 tile 行/窗口错位 两负对照）`

---

### Task T-S3a.4: 回归 + `dev_map` + 报告 + 提交

**Files:**
- Create: `y1/reports/c4b_bypass_tile.md`
- Modify（如需要）: `y1/pds/devmap_c4a.tcl` / `pnr_c4a.tcl` 的源清单（若新增网表）

- [ ] **Step 1** 重生成全部网表（`UnitExecGen`/`LayerSchedGen`/`NpuTopGen`/`BypassExecGen`）并记 `md5sum`；同源重跑一次确认确定性（2×）。
- [ ] **Step 2** 跑 12 个既有闸门 + `run_bypass_ab.sh` + `run_bypass_tile_ab.sh` + `check_dangling.py`（带网表参数）/`check_dup_modules.py`/`check_no_xilinx.sh gen` ⇒ 全 `PASS`。
- [ ] **Step 3** 板级 `dev_map`（`/c/Pango/PDS_2025.2-ads/bin/pds_shell.exe -file D:/code/PDS/VexiiYeshenLinux/y1/pds/devmap_c4a.tcl`，cwd = 仓根）⇒ 断言 `Adm-4088=0`、`DRM ≤ 415`；记与基线的 Δ。
- [ ] **Step 4** 写 `y1/reports/c4b_bypass_tile.md`：正/负对照逐条证据 + `dev_map` 全表 + **能证/不能证**。
- [ ] **Step 5** 提交 `feat(y1-bypass): T-S3a 收口（旁路 tile 逐字节 + dev_map 记账）`

---

### Task T-S3b.1: 宽路 gather 的 per-plane band（`UnitExec`）—— 去掉 `HW%32==0`

**Files:**
- Modify: `y1/rtl/UnitExec.scala`（`wxBBR/wxIdx` → 每平面 `(bandBase, idxW, idxB)`；`tilingWideC` 去掉 `tHW32(4:0)===0`）
- Modify: `y1/tools/run_tiling2d_wide_ab.sh`（正对照**加 20×20 形状**；加负对照）

- [ ] **Step 1: RTL** —— `FETCH` 逐平面已算 `wxFAdrR`；把 `bandBase = wxFAdrR & ~31`、`idx = wxFAdrR[4:0]` **按平面存**（`wxBBR(pl)` / `wxIdxW(pl)(2b)` / `wxIdxB(pl)(3b)`，各 8 项）；`EMIT` 时 `wxCol(cl) = xwBuf(cl*4 + wxIdxW(cl))(wxIdxB(cl))`。`rd_ready` 与 `wxOrphan` 语义**不动**。
- [ ] **Step 2: 去掉前提** —— `tilingWideC` 删掉 `(tHW32(4 downto 0) === U(0, 5 bits))`（其余前提一字不动）；band 缓冲仍**单份**（8 平面串行取）。
- [ ] **Step 3: 正对照加 20×20** —— `run_tiling2d_wide_ab.sh` 的作业表加 `c64_20x20`（64→64 20×20 s=1）与 `c10_20x20`（10ch dw 20×20）；期望逐字节 `MISMATCH=0`。
- [ ] **Step 4: 负对照（有牙）** —— 网表突变：把 `EMIT` 的 per-plane 索引退回**共享**（用 `wxIdxW(0)/wxIdxB(0)`）⇒ 在 `HW%32≠0` 的形状上必红；在 `HW%32==0` 的形状上不提（那是旧口径本来就对的）⇒ 脚本对"红在 20×20、不红在 40×40"两条都要断言。
- [ ] **Step 5** 重生成 + `bash y1/tools/run_tiling2d_wide_ab.sh` ⇒ `RESULT: PASS`；`bash y1/tools/run_tiling2d_rtl_ab.sh`（窄路共用同一网表）⇒ `PASS`。
- [ ] **Step 6: 提交** `feat(y1-tiling): T-S3b 宽路 gather per-plane band（去 HW%32==0 前提；20×20 逐字节）`

---

### Task T-S3b.2: 回归 + `dev_map` + 报告 + 提交

**Files:**
- Modify: `y1/reports/c4b_tiling_s2.md`（追加 §13）或 Create `y1/reports/c4b_band_perplane.md`

- [ ] **Step 1** 重生成 + 确定性（2×）+ 12 闸门全绿 + 3 检查器全绿。
- [ ] **Step 2** 板级 `dev_map` ⇒ `Adm-4088=0`、`DRM ≤ 415`（断言**零新增宽存储**：`LUTs as dram` 与 DRM 与 T-S3a 后**基本持平**）。
- [ ] **Step 3** 报告 + 提交 `feat(y1-tiling): T-S3b 收口（per-plane band 记账）`

---

### Task T-S3c.1: 整表几何预检（判据 C）

**Files:**
- Create: `y1/tools/frame_preflight.py`（读 `gen/wgt_index.json` 或 `desc.bin`，逐单元走几何对账）
- Create: `y1/tools/run_preflight_ab.sh`

- [ ] **Step 1** `frame_preflight.py`：对 **67 个单元**逐条算 `inW`/`outPix`/`HW`/`nCo` 并判
  `UnitExec: inWOk | wideGeomOk | tilingWideC | tilingOkC` 与 `BypassExec: rowWOk | outPix≤MAXPIX | planarOk`
  ⇒ 打印 `PREFLIGHT_ERR=<n>` 与逐条 `unit -> 走哪条路 / 为何 err`。**其口径断言必须与 RTL 逐条对齐**（脚本头写明每条 predicate 的 RTL 行号）。
- [ ] **Step 2（终证）** 用**模拟跑真 `desc` 序列**核对：把真 `desc.bin`（67 条）喂 `LayerSched`（`run_nputop_sched_ab.sh` 的装置或 `run_frame_ab.sh`）⇒ 期望**每一步都不举 `err`**（`errSticky` 恒 0）。这条是"S3 一次跑完"的**权威证书**；Python 预检只是快速门。
- [ ] **Step 3** `run_preflight_ab.sh`：正对照=真表零 err；负对照=手工把某条 `IMG_W` 改 ±1 ⇒ Python 预检**必红**（证明它有牙）。
- [ ] **Step 4: 提交** `feat(y1-frame): T-S3c 整表几何预检（Python 快门 + 真 desc 模拟终证）`

> **★ 执行记录（2026-10-15，回写）**：Step 1/3 **已落地**（`y1/tools/frame_preflight.py` +
> `y1/tools/run_preflight_ab.sh`，报告 `y1/reports/c4b_frame_preflight.md`）。
> **Step 2（模拟真 67 条序列）defer**：现有装置（`NpuTopSchedTb.v` 64 KiB / 3 条目小表；`LayerSchedTb.v`）
> 不支持"真张量 + 逐层权重 + 真编程序列"这一档，改造量 ≥ 新建整帧装置 ⇒ 按约定**不做假证**，
> 并把"Python 预检 vs RTL 的口径漂移"记为开口项（报告 §5.3）。
> **判据被改写**（真表**不是**零 err）：正对照 = `UNIT` 口径的 ERR 集合**恰好** `{29}`（`Resize_43`
> 撞 `BypassExec.tileAliOk`，`BypassExec.scala:607`）—— 冻结在 `EXPECT_UNIT_ERR_UNITS`，
> 既抓新缺口也抓"缺口修好却没重新锚定"；另加 `DISPATCH` 口径锚 `DISPATCH_ERR=54`（宽层链无通路：
> RTL 宽路四条判据全带 `chain_len==1`，`UnitExec.scala:1236/1426/1451/1650`）。
> ⇒ **T-S3c.2 的"S3 收口"在本片之后仍不能开工**：先修 `Resize_43` 那一类（旁路 tile 的 per-plane band）
> 并裁决宽层链（报告 §7 / spec §9）。

---

### Task T-S3c.2: 收口（把"能跑完"这件事钉死）

**Files:**
- Create: `y1/reports/c4b_frame_runnable.md`

- [ ] **Step 1** 全量重生成（`UnitExecGen`/`LayerSchedGen`/`NpuTopGen`/`BypassExecGen`/CDC/DMA）→ `md5sum` 记账 + 确定性 2×。
- [ ] **Step 2** 全闸门（12 + bypass + bypass_tile + preflight + `run_tiling2d_*`）+ 3 检查器 ⇒ 全绿。
- [ ] **Step 3** 板级 `dev_map` + **PnR**（`YESHENMINI_SYNTH_MODE=speed`，`/c/Pango/PDS_2025.2-ads/bin/pds_shell.exe -file y1/pds/pnr_c4a.tcl`，cwd=仓根）⇒ `All Constraints Met` + 比特流指纹。**长命令用托管后台 + 完成标记**（`YESHENMINI_PNR_C4A_DONE`）+ 产物 + 退出码。
- [ ] **Step 4** 报告 `c4b_frame_runnable.md`：**能证**（整表零 err + 面积/时序 + 比特流）/**不能证**（未上板 ⇒ fps/G7 留给 S3）。
- [ ] **Step 5: 提交** `feat(y1-frame): T-S3c 收口（真帧可跑：整表零 err + PnR/比特流）`

---

### Task T-S3d: **`权重 blob × tiled 宽` 的仿真挂住**（**先查**，spec §3.5）

**Files:**
- Modify: `y1/rtl_test/UnitExecWideTb.v`（若挂起是 TB 的 blob 供料缺口）
- Modify: `y1/rtl/UnitExec.scala`（若挂起在 RTL 的 `WGTLD/WGTRUN → WIDERUN` 衔接）
- Create/Modify: `y1/tools/run_wgtblob_tiled_ab.sh`

- [ ] **Step 1: 复现** —— `UnitExecWideTb` + `gen/UnitExec_tiled.v`，64→64 40×40，`+TILED_W +WBASE` ⇒ 记录"4M 拍不收工、无 done 无 err、只发一笔 128 B 权重突发"的逐拍签名（`wSt`/`wlRun`/`dstate`）。
- [ ] **Step 2: 二分归因** —— 三档对照：① `+WBASE` 无 `+TILED_W`；② `+TILED_W` 无 `+WBASE`；③ 两者都有。定位是"组合"还是某一侧。
- [ ] **Step 3: 修 + 判据** —— 该组合一条**正对照**（收工 + `DST` 逐字节 == 冻结参考）× 一条**负对照**（少装一段权重 ⇒ 必红）。`gen/UnitExec_tiled.v` 的 md5 记账；`TILING=false` 三网表逐字节不变。
- [ ] **Step 4: 提交**

---

### Task T-S3e: 旁路 tile 的 **per-plane band**（`Resize_43`，spec §3.4）

**Files:**
- Modify: `y1/rtl/BypassExec.scala`（tile 的平面索引按平面各记 `(bandBase, idx)`；去掉 `inCols%32==0` 的 tile 前提）
- Modify: `y1/tools/run_bypass_tile_ab.sh`（加 `resize` **40×40** 正对照 + per-plane 负对照两侧）

- [ ] **Step 1: 红** —— 加 `resize` 40×40（真表 `Resize_43` 形状）⇒ 期望装置 `err`（当前无路）。存红证据。
- [ ] **Step 2: 修** —— 与 T-S3b **同一套** per-plane band。
- [ ] **Step 3: 绿 + 负对照** —— 逐字节 == 冻结参考；负对照：退回共享索引 ⇒ `HW%32≠0` 红、`HW%32==0` 绿（两侧）。
- [ ] **Step 4: 回归 + 提交**

---

### Task T-S3f: **宽链**（`chain_len>1` 的宽路，spec §3.3 —— 用户裁决 A）

**Files:**
- Modify: `y1/rtl/UnitExec.scala`（`WIDERUN` + 多趟编排从 `chain_len==1` 扩到整链：逐片行锁步 + `FusionBuf` 中间张量零 DDR）
- Modify: `y1/rtl_test/UnitExecWideTb.v` / `UnitExecGen.scala`（链档 TB / 网表）
- Create: `y1/tools/run_chain_wide_ab.sh`

- [ ] **Step 1: 冻结数据流（写进 `UnitExec.scala` 文件头）** —— 宽链 = `head middle* tail`，几何只取链首；每片（ci/co 趟）在**链内**交错行锁步；中间张量在 `FusionBuf`，**结构性零 DDR**。
- [ ] **Step 2: 判据** `run_chain_wide_ab.sh`
  1. **真表 run 形状**逐字节 == 整层黄金（黄金复用冻结参考；`16→16` 链长 2、`64→64` 链长 4/6、`64→10` 链长 2、`64→4`/`64→1` 链长 2）；
  2. **负对照**：链长截短（少跑一片）⇒ 必红，且**定位**在缺失的那一片的输出上；
  3. 既有窄链闸门（`run_chain_ab.sh`）与其它 19 闸门全绿；`TILING=false` 三网表逐字节不变。
- [ ] **Step 3: 回归 + `dev_map` + 报告 + 提交**

---

### Task A'-1（★ 2026-10-15，T-S3f 裁决 A' 的**第一片：接口/口径钉死**；本片 = 设计 + 离线，**不改 RTL 行为**）

> 输入：spec §3.6（口径修订范围）+ `y1/reports/ts3f_red_first.txt`（B1/B2/B3 实测）+ 本片的
> `y1/reports/ts3g_chain_caliber.md`（19-run 标定表 + 参考 #2 校准证据）。
> 本节的每一条都给了 **file:line**；实现片（A'-2）按此逐条落地，不再重新裁决接口。

**A'-1.0 现状接口（精确读数，链 = `head middle* tail` 塌缩成一次 `go`）**

`LayerSched` 今天交给 `UnitExec` 的东西**恰好四样**（别无其它）：

| # | 量 | 端口/寄存器 | 位宽 | 来源（file:line） |
|:--|:--|:--|:--|:--|
| 1 | 链描述符 8 字 | `unitExec.io.desc(0..7) <= unitDescR(0..7)` | 8×32 | `LayerSched.scala:450-453`；锁存点 = plain 分支 `:716`、链尾分支 `:793-795`（**链首** 8 字，仅 `w5` 换成**链尾** `DST_ADDR`） |
| 2 | 链长 | `unitExec.io.chain_len := chainLenR` | UInt(16) | `LayerSched.scala:473`；链尾定案 `chainLenR := chainCnt+1` `:787` |
| 3 | 权重段**起点**（帧前缀和） | `unitExec.io.wgt_dma_addr := Mux(wgtBlobBaseR != 0, wgtPtrR.resize(28), 0)` | 28 | `LayerSched.scala:538-539`；`wgtBlobBaseR` = 信箱区域 6（主机编程）`:493-500`；`wgtPtrR` 帧首 = base `:635`、每单元推进 `:829` |
| 4 | 权重信箱 | `wgt_sel/wgt_addr/wgt_data/wgt_we` 直通 | — | `LayerSched.scala:561-564`（`wide_x` 在调度器侧**钉 0**`:567-568` ⇒ 真帧宽层必须 `XDMA_EN=1`，激活自己 gather） |

`UnitExec` 侧的消费（几何**全部**取自链描述符 = **链首**）：
· `dw = DescWords(io.desc(0..7))` `UnitExec.scala:696-697`；几何 `C_IN/C_OUT/GROUP/IMG_W/IMG_H/QUANT_SHIFT/LAYER_ID`
  只此一份；`chainLen = io.chain_len` `:1128`、`hasTail` `:1132`、`chainOk` `:1140-1141`。
· 链上**逐片几何一致**由 `LayerSched.geomEq`（`LayerSched.scala:393-395`，在 `:769` 强制）保证 —— 这条
  与冻结 `desc_table.py:147` 的"链首几何覆盖"是**同一个口径的两处实现**；真表 run 是**异型**（B1）⇒ 两处都要改。
· 宽路四条判据**全带 `chainLen == 1`**：`wideGeomOk :1426-1429` / `wgtLoadOk :1451-1452` /
  `tilingWideC :1650-1656` / 派发分支 `:2020-2024`；`strideChainOk :745`（`s>1` 只许单单元）。
· 权重段长/装载：窄路 `wgtLen = chain_len * WGT_SEG`（`WGT_SEG=NENTRY=576`）`:527/:933`；
  宽路 `ceil32(N_i)` `:943-948`、`wgtBaseR := io.wgt_dma_addr` `:2644`、`wgtLenR := Mux(dmaWide, wgtWideRdLen, wgtLen)` `:2649`；
  **每片基址不传、每片段长不传**（装载器只认链首 N_i）⇒ B2 的根。
· 帧级指针推进 `LayerSched.scala:829` = `chainLen × nWgtR`，`nWgtR := nWgtFetch`（`:718`/`:798`）=
  `(cOut × perGroup) × 9`（`:556-557`，**未对齐**的真实 N_i）。实测（`ts3g_chain_calib.txt` §帧级指针）：
  真表 53 个消费权重的单元里 **52/53** 的指针落点 ≠ blob 实际偏移（第 2 个起全部错位）—— **B2 在帧级也存在**，
  不只是链内。

**A'-1.1 逐片几何投递（每片自己的几何送到需要它的那一片）**

· **LayerSched 在 CHAINSCAN 已经逐条取回每个成员描述符**（`CHAINSCAN/CHAINSCANW`，`LayerSched.scala:749-807`；
  它甚至已经逐条对过 `geomEq` 与 `fieldsOk`）。新增锁存（每扫到一项就落一槽，`k=0` 为链首）：
  `chainCin(16) / chainCout(16) / chainGrp(8) / chainQsh(8) / chainLid(8) / chainDw(1) / chain1x1(1)`
  共 `L_MAX × 59 bit` 的**寄存器数组**（`L_MAX=8` ⇒ 472 bit；值直接从当拍 `descFetch.io.words` 的
  `dw`/`fetchDw` 译码取，零新译码逻辑）。
· **UnitExec 新增入参**（专用端口，**不碰 8 字描述符线格式**）：
  `chain_cin :: Vec(UInt(16 bits), L_MAX)`、`chain_cout :: Vec(UInt(16 bits), L_MAX)`、
  `chain_grp :: Vec(UInt(8 bits), L_MAX)`、`chain_qsh :: Vec(UInt(8 bits), L_MAX)`、
  `chain_lid :: Vec(UInt(8 bits), L_MAX)`、`chain_dw :: Vec(Bool(), L_MAX)`、`chain_1x1 :: Vec(Bool(), L_MAX)`。
  槽 0（链首）与链描述符**冗余**（便于统一索引）；`go` 那一刻断言"槽 0 == 链描述符译码值"，不一致 ⇒
  响亮 err（纵深防御，绝不让两条来源静默分叉）。
· **逐片 requant 参数免费搭车**：每片自己的 `M/z_pad/z_y/bias_adj` 用 `chain_lid(k)` 索引**现有**的
  按 `LAYER_ID` 参数表（`mzRam`/`biasMem`，`UnitExec.scala:761-779`；邮箱区域 2/3/4/5 由主机按
  `LAYER_ID` 投递，`npu_frame_run.py:359-374`）——**零新增存储**，只把"读表下标"从链首一个值改成逐片值。
· **LayerSched 的链校验改写**（RTL 侧与 `desc_table` 解冻同步）：`geomEq`（6 字段与链首全等）→
  **可链谓词**：`IMG_W/IMG_H/STRIDE/PAD` 全 run 相等 ∧ `C_OUT(k) == C_IN(k+1)`（内部边界）；
  `C_IN/C_OUT/GROUP/QUANT_SHIFT` 逐片自由。不合 ⇒ 仍**响亮 err + 零搬运**（`CHAINSCANW` 相位不变）。
· **8 字格式自证**：以上全是**专用端口**，`desc.bin`/`DescWords`/`pack`/`unpack`/`LayerSched` 的
  取表口径**一字不动**（E1 的 `w3[31:16]` 保留位写法是"如果必须走上表"的备选；本设计**不需要**）。

**A'-1.2 逐片权重段基址（B2 的修法；无新外部编程）**

· 冻结转换器契约（`y1_convert.py:13-20` + `:600-612`，`wgt_index.json` `contract.blob_layout`）：
  第 i 段长 = `ceil32(N_i)`、`N_i = C_out*(C_in/GROUP)*9`、`offset_i = Σ_{j<i} ceil32(N_j)`。
  **本片实测**（`tools/chain_wide_ref.py --selftest` 的 L0）：53/53 片的 `aligned_bytes == ceil32(nbytes)`、
  偏移 == 前缀和、总和 == blob 字节数（404064）⇒ **逐片基址可片上推导，不需要任何新投递**：
  ```
  base(0)   = io.wgt_dma_addr（链首基址，端口与口径不变）
  N(k)      = chain_cout(k) * cg(k) * 9,  cg(k) = Mux(chain_grp(k)==1, chain_cin(k), 1)   // 与装载器既有 cig 同式
  len(k)    = (N(k)+31) & ~31             // ceil32；同时就是该片 RD 长度（DdrMaster len%32==0）
  base(k+1) = base(k) + len(k)
  ```
  （`GROUP ∉ {1, C_in}` 在 `go` 那一刻已有 `grpOkW` 响亮拦截，本式无需通用除法。）
· **帧级指针同步修**：`LayerSched.wgtPtrR` 的推进从 `chainLen × N_head` 改成 `Σ_k len(k)`：
  plain ⇒ `ceil32(nWgtFetch)`；链 ⇒ 在 `CHAINSCAN` 沿链**累加**一个新寄存器 `nWgtAlignAcc`（`:829` 的
  一处替换）。理由 = A'-1.0 末条的实测（52/53 错位）。
· **"权重重信箱/表内保留位"idiom 的落点**（逐字回答 spec §3.6-2）：外部唯一编程点仍是
  `WGT_BLOB_BASE`（邮箱区域 6，`LayerSched.scala:490-500`，**沿用**）；每片基址**不进描述符、
  不进邮箱** —— 由 A'-1.1 的逐片几何 + 上式推导。**备选**（仅当将来收敛器改口径）：把每片
  `len(k)` 骑在各成员自己 `w3[31:16]` 保留位上（E1 `SRC2_K` 的同一手法，`y1_convert.py:736`
  "pack 不搬 w3 高位 ⇒ 按字偏移 OR 进去"；RTL 侧在 `CHAINSCANW` 顺手锁存）——本设计**判定不需要**。
· **逐片 RD 长度**：装载器今天的 `wgtWideRdLen` 用的是链首 `dw`（`:943-948`）；实现片把它改成
  逐片 `len(k)`（同一表达式，喂 `chain_cin/cout/grp(k)`）。

**A'-1.3 `desc_table.py` 最小解冻范围（**本片不动它**；实现片一次提交）**

| # | 位置 | 现状 | 解冻后 | 不动 |
|:--|:--|:--|:--|:--|
| a | `build_table` `desc_table.py:736-741` | 同 run 内 6 字段一律覆盖为**链首**值 | 逐成员写**自己的**几何（`IMG_W/IMG_H/C_IN/C_OUT/GROUP/QUANT_SHIFT`） | 其余字段生成/槽位记账 |
| b | `validate` 规则 (5) `:334-349`（`_geom_key` `:278-280` / `:345-346`） | run 内 6 字段与链首**全等**，否则 `chain geom mismatch @i` | **可链谓词**：`IMG_W/IMG_H/STRIDE/PAD` 全 run 相等 ∧ `C_OUT(i)==C_IN(i+1)`（内部边界）∧ 长度 ≤ `CHAIN_L_MAX`；`C_IN/C_OUT/GROUP/QUANT_SHIFT` 逐片自由 | 规则 (1)(2)(3)(4)(6)、`pack/unpack` 位打包、`reference_words`、`desc_count_of` |
| c | `--selftest` 负探针 `:929`（`R5 chain geom mismatch @2`）+ 表 md5 锚（`:406-`） | 拿"几何不同"当非法 | 改瞄**可链性**违反（如 `C_OUT(i) != C_IN(i+1)` 或 `STRIDE/PAD` 不等）⇒ 必红；表 md5 锚随 (a) 重冻 | 探针框架/计数器 |

· **"逐成员段长的记账"在 `desc_table.py` 里本来就**不存在**（它只做位打包/校验；段长记账在冻结转换器
  `y1_convert.py:576-619` 的 blob 前缀和）⇒ 该条对 `desc_table.py` = **零改动**（证据：本片 L0 断言全过）。
· **本片为何不动 `desc_table.py`**（硬约束允可、但结论=不动，理由给足）：
  (i) 它同时是 `--selftest` 的表生成器与校验器，**单独放宽 (b) 而不改 (a)/(c)** 会让冻结自检的
      R5 负探针瞄在"解冻后已合法"的条件上 ⇒ 自检自身失真（红或失声）；三者必须同一提交；
  (ii) 仓内现有产物（`desc.bin`）仍是"链首覆盖"表；解冻后**没有正对照用户**（真转换器
      `y1_convert.py` 写 own 几何只在它自己的 `units` 记录里）⇒ 提前解冻 = 放宽一个没人走的闸；
  (iii) spec §3.6 明写这属于"修口径 + 实现宽链"的同一步；本片按"设计 + 离线"边界收口。

**A'-1.4 B3（调度结构）与接口的关系**

A'-1.1/.2 的投递**对两种候选调度都充分**（逐片行锁步镜像 / 切片串行 + 嵌套窗口）：无论哪种，
每片要的东西都是"自己的几何 + 自己的基址 + 自己的 M/z"。B3 之下的调度裁决（以及 §3.6 里
"每 (tile,片) 权重重载 vs 驻留"的取舍）留 A'-2 设计；本片只钉**数据面接口**，不含调度选择。

**A'-1.5 判据（A'-2 的验收契约；本片先给可判的骨架）**

1. **黄金缺口（B1）已解**：`y1/tools/chain_wide_ref.py`（**参考 #2**，显式声明，见其文件头）
   —— 同型特例逐字节 == 冻结 `chain_l`/`chain_l_naive`；真表非折进成员与冻结 #1 逐层黄金建立
   **实测**逐字节关系（3×3/dw=identity、1×1=(+1,+1) 相位），折进口径差异逐片计数记账。
   闸门正对照 = 参考 #2 的链黄金；另加一条"冻结输入锚定"正对照（喂冻结 #1 的 head 输入张量、
   比 tail 张量，相位按记录）。
2. **负对照**：链长截短 / 某片基址偏一段（`base(k)` 用 `chainLen×N_head` 或漏一片 `len`）⇒ 必红，
   且错配**定位到该片**（逐片 md5 对账）。
3. `TILING=false` 三网表逐字节不变；既有闸门全绿（含 `run_chain_ab.sh` —— 本片已把它重新锚绿，
   证书 `reports/ts3g_chain_gate_green.txt`）。
4. 每片 `chain_*` 端口 vs 表内容的对账（槽 0 冗余断言）也进网表判据。

---

## 交接（本计划之后 = **S3**）

- 上板（烧写 + `npu_frame_run.py --run` + 12 路 + G7 容差）**需要用户给时机**（板占用纪律：先查同 cwd 的 running 会话 / 进程 / JTAG 口）。
- **S2b-ii**（宽路 tile 的 23× 流量 → 窗口片上留住）**不在本计划**：它只影响 fps，不挡 G7；待 S3 跑通后另立。

---

## 自查记录

1. **spec 覆盖**：spec §3.1/§3.1.1 → T-S3a.1/A.2；§3.2 → T-S3b.1；§4-A → T-S3a.3；§4-B → T-S3b.1 Step 3/4；§4-C → T-S3c.1；§4-D → T-S3a.4 Step 3 + T-S3b.2 Step 2；§5-R1 → T-S3a.1 契约"复用 outMem" + T-S3b.2 Step 2 的"零新增宽存储"断言；§5-R5 → §3.1.1 的 pool 列切（T-S3a.1 Step 1 契约）。
2. **占位扫描**：无 TBD。每条判据都写死**正对照 + ≥1 条能发火的负对照 + 退出码**。
3. **类型一致性**：`outMem`（BypassExec，`= WIDTH·IMG_H_MAX` 字）在 T-S3a 全程**不改尺寸**；`MAXPIX`/`tile outPix` 同名同义；`wxBBR/wxIdx` 在 T-S3b 用 `wxIdxW/wxIdxB` 的 per-plane 版本（旧的共享名不再出现）；`run_bypass_tile_ab.sh` 用的是 `BypassExec_w34.v`（`WIDTH=34`），与板级 `LayerSched` 同参。
4. **一处诚实标注**：判据 C 的 Python 预检与 RTL 是**两套口径**（漂移风险）⇒ spec §4-C 要求**模拟真 `desc` 终证**兜底，本计划 T-S3c.1 Step 2 落实。

---

### Task A'-3（★ 2026-10-16，A'-2 的**实现片**：宽链引擎）—— **BLOCKED（板级 LUT 墙）**

> 输入：spec §3.3/§3.6（裁决 A'）、本计划 Task A'-1（接口钉死）+ A'-2（已落地）、
> §3.7（`PartialSumBuf` 收窄 ⇒ B3 的**权重常驻项**解除）、`reports/ts3f_red_first.txt`（B1/B2/B3）。
> 本片 = **设计 + 测量**（`y1/reports/ts3h_wide_chain_engine.md`）；RTL/`gen/` **一字未动**。

**结论**：忠实镜像的结构可钉死（见报告 §2：逐片趟引擎 + 跨片行锁步 + 嵌套窗口 `T = 34-2L` +
逐行部分和 + 宽字环；数值等价可推 ⇒ 可对参考 #2 逐字节），但**实测**两件事挡在闸门前：

1. **W1（LUT，硬）**：镜像 = `L_MAX=8` 片并发引擎；实测单片 ≈ **6,202 LUT**（`c3_area.md` §10），
   `+8` 片 ≈ **+49,616** vs 板级余量 **35,692**（`devmap_c4a_s37.log`）⇒ **超 ≈14k**。
   ⇒ "新增片引擎"这一档**装不进器件**。
2. **W2（唯一的在预算变体 = 合体，需裁决）**：窄链的 `slices(0..7)` 在宽跑时**全闲** ⇒ 共用片阵列
   ΔLUT = 仲裁器 + 编排（余量内），但要打开 7 组**逐字节冻结面**（`UnitExec.scala:1094-1112/2464/
   2467-2524/2535-2554/2575-2576/2705-2706` + 参数逐片读回 761-923）⇒ 与 pin 死的"镜像、不发明
   平行设计"冲突 ⇒ 停在此处交用户裁决。

**DRM（W3）**：逐片常驻权重段（真表最坏 Σ=112,320 / 闸门 c64_L4=147,456 / naive 294,912 B）
+ 逐行部分和 69,632 + 环 45,696 = 228–410 KB vs 余量 ≈376 KB（2,244 B/块，取保守）⇒ 逐跑 sizing
的共享池**过**、naive **不过**（R1"零新增宽存储"须松动）。**拍数（W4）**：闸门 `c64_L4` ≈2.1–2.2M
拍 > `+TMT=2M`（夹具旋钮，抬到 3M 即可）；真帧 L=8 160×160 run ≈ 1 s/run（fps 开口项已有）。

**finisher 子步清单**：见报告 §8（S1 夹具 → S2 段 RAM+装载器 → S3 逐片参数 → S4 行部分和+环
（经仲裁器接 `slices(i)`）→ S5 行锁步编排 → S6 判据/回归/`dev_map`）。
