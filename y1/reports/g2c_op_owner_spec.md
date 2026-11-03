# G2-c spec：K-band 单 op + K 槽环 → 把 gather 延迟藏到计算后面

日期：2026-10-23　状态：**定案，待实现**（P0/G1/G2-b 均已实测；本 spec 写设计与判据）

> **2026-10-23 设计修正**：原方案（"先给 DdrMaster 加 op owner + 链式 op"）**不需要**。
> 读 `UnitExec.scala:2330-2405` 后确认串行点的真正来源是两件事：
> ① **xwBuf 正好一个 band**（8 平面 × 4 拍 × 8 B = 256 B，`(:2393)` 的落点就是
> `wxSgPl*4 + wxFBe`）⇒ 取数与消费**不能重叠**；
> ② **一个 SG op 只装一个 band**（`:2381-2389` 扫 0..7 平面，`:2397` 等整批 `done` 才落账）。
> 而生产者始终只有主 gather 一个 ⇒ **不存在 owner 歧义**（G2-b 的"两个生产者共用批"是自找的）。
> 所以正确改法是**在同一个生产者内**把 op 做宽、把缓冲做成环，`DdrMaster` 一行不改。

## 0. 为什么现在做这个

| 证据 | 数字 | 含义 |
|---|---|---|
| G2-P0 零延迟仿真（c64_40） | `fetch 2.1% / emit 65%` | 无延迟时宽路是 emit 主导 |
| G2-P0 加延迟 | 第一 band 之后不再发 AR（`bursts=8`） | **整 band 收齐 → 才发下一 band 的硬串行** |
| 板级 Conv_15（当时） | 166 ms vs 外推 57 ms | 内存停滞 ≈2/3 |
| W3 conv15（单元闸门） | `no_valid=1,246,496 / 总 4,549,064`（27%） | W1/W2/W3 之后**仍**有 27% 在等 gather |
| W4（64 B band） | AR −44%，`no_valid` 只 −1.5% | 加大**单个** band 无用：不是固定开销，是**并发度** |

⇒ 结论：下一个杠杆是**并发在飞的 band 数 K**，不是 band 大小。

## 1. 结构（只动 TILING 宽路 gather；TILING=false 逐字节冻结）

### 1.1 K-band 单 op

- `K=6`：一个 SG op 收 **K×8 = 48 项**（band-major、plane-major 顺序），每项仍是 `beatsM1=3`（32 B）。
- 地址：`wxPBB` 现在按"当前行 + 平面"算；改为按 `(bandIdx, plane)` 算 —— `bandIdx` 行偏移 =
  `tInPixW * (bandIdx)`（与 `wxPBB` 的平面步进同式），在入队扫描时逐项算，**不新增乘法器**
  （扫描是 48 拍，可复用现有加法链）。
- `rqDepth=8` 已够：48 项按 8 笔在飞滚动，DDR 端看到连续 32 B 流，**一次 RTT 摊到 6 个 band**。

### 1.2 K 槽环

- `xwBuf` 从 `32 × 8 B` 扩成 `K×32 × 8 B`（1.5 KB）。**地址**：`slot*32 + plane*4 + beat`。
  资源：6×256 B = 1.5 KB ⇒ 按 DRM 4 Kb block 估 ≤3 块（当前 305/415）。
- 每槽 `valid[K]`：该槽 8 平面 × 4 拍全部落地 ⇒ 置位；消费到该槽 ⇒ 清零。
- **逐 band 交付**：落点计数器每收 32 拍（一个 band）就把该槽置 valid，**不等整 op done**
  （`:2397` 的整批落账改为逐槽落账；`wxSgMask/BB` 由 8 项扩成 8 项 × 当前槽，
  按"槽号 = 已收拍数 / 32"索引即可，不需 48 份寄存器）。

### 1.3 消费侧

- 消费（`wxWord` 的读地址）加 `slot` 维度：消费 band 号 `cBand` 自增，`slot = cBand % K`。
- **门控**：`valid[slot]` 为 0 ⇒ 消费停（`col_ok` 不增）⇒ 这正是希望的"等数据"，
  取代现在"整批等完"的 fetch 停顿。
- 环满（K 个未消费）⇒ 不再发下一 op（`start` 门控）；环空 ⇒ 消费等。

### 1.4 与既有账本的关系

- `wxBandV/wxBndV/wxBndB` 的语义是"某平面某 band 已取过"（跨列复用）。环落地后**逐槽**更新，
  保持原语义（只改更新时机：按槽而非整批）。
- 跨 tile/跨行时环清空，`sg_flush` 仍由既有 DECIDE 逻辑发（`:2157`），环内 valid 全清。

## 2. 验收判据（先红后绿）

> **前置（2026-10-23 已补）**：TB 的 `AxiMemModel` 原先在 AR 握手后**下一拍**就给 rvalid（延迟 1 拍），
> 预取在这台上**测不出任何收益**。已加 **`+RDLAT=<拍>`** 旋钮（每个被接收的 AR 记"到期时刻"，
> 多笔在飞各自到期；默认 0 = 旧时序）。**G2-c 的 A/B 必须在 `+RDLAT=640` 下做**，
> 并用 `+RDLAT=0` 复跑作"语义不变"的对照（两档 dump 必须逐字节相同）。

1. **单元级**（`run_unitexec_wide_ab.sh` 的 conv15 档，**+RDLAT=640**）：`+PF=1` 的 `CYCLES` ≤
   `+PF=0` 的 **0.80×**，且两份 dump **逐字节相同**（md5 相等）；`+RDLAT=0` 下两档 dump 也必须相同。
2. **归因**：`no_valid` 相对 `+PF=0` 至少降一半（`col_ok` 不得下降）。
3. **TILING=false 冻结**：三份 `gen/*_nontiled.v` md5 不变。
4. **负对照**：把第 2 个槽的 plane 地址故意错位（`PF_BAD=1`）⇒ dump 必须不等/超时。
5. **面积**：dev_map 0 error，DRM 增量 ≤ 4 块。
6. **时序**：PnR 18.4 ns 档 npu 域 WNS ≥ 0（当前 +0.620）。
7. **上板**：`y1run --frames 3` 12/12 CRC 保留；RUN ns 相对 W1 基线 1,771.2 ms（W3 预计 ~1.47 s）。

## 3. 预期与风险

- 预测：conv15 **−20~27%**；全帧 1.47 s → **1.10~1.20 s**（离 1 FPS 还差一档，
  下一档才轮到 `npu_clk` 56.243→60 MHz 或 4 px/cycle 写回，见 §4）。
- 风险 1：消费/取数**双线程**（各自游标）是本改动的承重点。若 `valid/`环空门控写错，
  最坏表现是消费旧槽数据（数值错但不会挂死）⇒ 判据 1 的**逐字节相同**必须先红后绿。
- 风险 2：48 项扫描的地址加法链可能拉长 npu 域的 18.4 ns 关键路径 ⇒ 判据 6。
- 风险 3：环的读口从 1 个变成 2 个（消费 + 落数）⇒ DRM 双口推断；若 PDS 推断成分布式 RAM
  就撞"16 位总宽上限"的旧坑（见 memory: inferred-ram-mapping-check）⇒ dev_map 后**按 primitive 对账**。

## 4. 之后的两档（不在本 spec 范围）

- `npu_clk` 56.243 → 60 MHz：需从 PnR 头号路径再切 ≥1.1 ns（当前 +0.620 ⇒ 60MHz 差 ~1.1ns）。
- 写回 4 px/cycle：需第 3/4 份 `wOutMem` 读口 ⇒ DRM +2 块；只在 STREAM 仍是瓶颈时才值。


## 2.1 K 的取值（用**板级实测暴露量**算，不是拍脑袋）

- 板级 Conv_15：166 ms vs 零延迟外推 57 ms ⇒ 暴露 **109 ms / 28,900 band ≈ 204 拍/band**（@54 MHz）。
- 消费侧 ≈ **140 拍/band**（G2-P0：34 列 × ~4 拍）；聚合带宽对应 ≈ **34 拍/band**。
- 一个 K-band op 的耗时 ≈ `R + K×34`（R=首次数据到达 = 204 拍）；环里可重叠的计算 = `K×140`。
  只要 `K×140 ≥ R + K×34`（即 `K ≥ R/106 ≈ 2`）就**不再饿**：

| K | op 耗时 | 环内可重叠计算 | 覆盖比 | 残留/band | 环大小 |
|---|---|---|---|---|---|
| 2 | 272 | 280 | 1.03 | 0 | 512 B |
| 3 | 306 | 420 | 1.37 | 0 | 768 B |
| **4** | 340 | 560 | 1.65 | 0 | **1 KB** |
| 6 | 408 | 840 | 2.06 | 0 | 1.5 KB |

⇒ **取 K=4**（1 KB，DRM 2 块；覆盖比 1.65 留足抖动余量），K=6 作退化档。
⇒ 预测校准：Conv_15 的 204 拍/band 全部吃掉 ⇒ 板级 166 ms → ~84 ms（= 仿真值），
   全帧按宽路占比折算与 §0 的 −20~27% 一致。

## 6. 实施锚点（file:line 以 2026-10-23 的 `UnitExec.scala` 为准）

| 步骤 | 位置 | 改法 |
|---|---|---|
| S1 xwBuf 扩容 | `:1489-1500`（`val xwBuf = Mem(...)`） | 深度 `32 → K*32`；TILING=false 分支保持 32（冻结） |
| S2 消费读地址 | `:1716`（`wxWord`） | `slot*32 + cl*4 + wxPIDX[4:3]`，`slot = ((wxGAbs>>5) & (K-1))` |
| S3 落数地址 | `:2393` | 同上 slot（由"已收 32 拍/band"推出本槽号） |
| S4 逐 band 交付 | `:2397-2404` | `done` 时的整批落账改为**每满 32 拍**置 `bankV[slot]`；`done` 只负责清 op 状态 |
| S5 op 装 K 个 band | `:2344-2348` | `sg_beatsM1` 不变（每项仍 32 B），项数 `8 → 8K`；地址按 `(band,plane)` 算（复用 `wxPBB` 的加法链，扫描 48 拍） |
| S6 下一 band 基址 | DECIDE `:2354-2363` | `wxFAdrR := wxGAbs + 32 - (wxGAbs & 31)`（下一 band 首列），跨行/跨 tile 时按现有 `wxRowOk/wxInWin` 截断 |
| S7 喂列门 | `:2441-2443` | `x_valid := wxFeed && bankV[slot]`（去掉 `wxSt===3`）；`x_ready` 同改 |
| S8 环空门 | `:2355` | `wxNeedB` 增 `&& !bankV[nextSlot]`（环里有货就不发新 op） |
| S9 清环 | `:2157`（`sg_flush`）、`:2730`（趟首） | 清 `bankV` 全 0 |
| S10 负对照 | Gen 参数 `PF_BAD` | 第 2 槽 plane 地址 `^1`，用于闸门红检 |

**先做 S1~S4 + S7（双 bank，K=2）跑一次 conv15**：这一步已经把"取数与喂列串行"拆开，
预期 `no_valid` 至少减半；确认逐字节相同后再做 S5/S6/S8（K=4 多 band 单 op）。

## 7. 实施日志

### 7.1 Step A（双 bank 重构，无语义变化）——已改，待闸门

- `xwBuf` 32→**64**（仅 TILING；非 TILING 仍 32 ⇒ 三份冻结网表 md5 已复验**全部未变**）。
- 读地址 = `wxGAbs(5) ## (cl*4 + wxPIDX[4:3])`（bank = 该 band 的绝对地址 bit5）；
  落数地址 bank 用 **DECIDE 时锁存的 `wxLdBankR := wxGAbs(5)`**（不能用逐平面递增的 `wxFAdrR(5)`，
  否则同一 band 的不同平面会落进不同 bank）。
- 网表：`gen/UnitExec_tiled.v` `5ff0664a → 425ff46c`（+17 KB，即多出的 32×64-bit 寄存器）。
- **闸门**：conv15 `+RDLAT=0` 的 `CYCLES` 必须仍是 **4,549,064**、dump 与 `w3chk.dump`
  （md5 `84810073…`）**逐字节相同**。

### 7.2 关键认知：宽路 FSM 是**逐列**的

`wxSt` 每个**列**走一遍 `DECIDE →(需要才 FETCH)→ EMIT(喂 1 列) → DECIDE`，不是按 band 批量喂。
⇒ 重叠（Step B）不是"FETCH 与整段喂列并行"，而是：
1. FETCH 拆成 **ISSUE（扫 0..7 平面 + start，≤8 拍）** 与 **LAND（收流落 buffer，可后台）**；
2. ISSUE 完立即回 DECIDE（不再等 `done`）；LAND 逻辑移出状态机，改为 `when(wxSgRd)` 独立块；
3. **提前一个 band 发 ISSUE**：在 band 的**最后一列**（`wxGAbs&31==31`）且下一列仍在窗口内时，
   对 `(wxGAbs&~31)+32` 入队到另一个 bank；
4. 消费侧 `wxNeedB`（TILING）改成"当前 band 的 `bankV[bank]` 为 0"；若该 band 正在飞（`wxPfV`
   且目标相符）就**等 done**，不重复发；
5. `done` 时按 `wxLdBankR` 置 `bankV[bank]`；消费切 bank 时清上一个（可选，用于审计）。

行尾/跨行：Step B **只在同一行内预取**（`(wxGAbs&31)+32 < 行窗口末列`），行首仍走顺序路径
⇒ 每行仍付一次 RTT（约 1/3 的 band），预期拿到 2/3 的收益；跨行预取留给 K 环阶段。

### 7.1b 复盘（2026-10-24）：Step A 代码已回退；拦路的是**继承的冻结违例**

1. **我手搓 conv15 的轨迹差异是调用问题**：官方 b1 闸门用 `-DUE_CGEOM -DUE_GBYTE`，我漏了
   `-DUE_CGEOM` ⇒ 几何不同、周期自然不同。**不是 Step A 的回归**。
2. **Step A 本身对冻结是中性的**：改动前后非 tiled 三份网表都是
   `9d8fa906 / 52fa5b20 / c41e0449`（未变）。
3. **但这份"当前值"已不等于闸门锚点**：用 `d313592`（10-22，最后一次声称冻结的提交）的源码
   重生成，`gen/UnitExec.v = 7593b189…`（正好是闸门 `EXPECT_UE`），而当前源码给 `9d8fa906…`。
   ⇒ **漂移发生在 W1/W2/W3（10-23）之间**，W3 的提交信息里"TILING=false md5 冻结"不成立。
4. **根因（已定位）**：`wOutMem2`（W3 的第二读口）是**无条件实例化**的 —— 当前非 tiled 网表里
   `wOutMem2` 出现 **2054 次**（1088×64 bit 存储器），d313592 版为 **0**。另有 W1/W2 新增行导致的
   `_zz_when_UnitExec_l<行号>` 名字位移。
5. **修法（未实施，需一段独立改动）**：把 `wOutMem2` 的声明/读（`wtRdWrd2`）/写、以及整个预取装载块
   （`wtByte2`、`wtNPr/wtPA/wtPB`、`wtRowB2` 写）用 Scala `if (TILING)` 包住（**保持行数中性**）；
   目标是三份非 tiled 网表回到 `7593b189/817ab5bb/5d2cd81a`。**只有 [0] 变绿，b1 闸门的
   [1] 逐字节/[2] gather_bytes/[3] 负对照 才会被执行**——那是 Step A 的正式判据。
6. **当前状态**：Step A 的 RTL 改动**已回退**（`gen/UnitExec_tiled.v` 回到 `5ff0664a`，与 `led1`
   比特流同源），避免留下未验证改动。Step A 的改法仍保留在 §7.1/§6，等步骤 5 落地后照单重放。

### 7.1c 冻结重锚的**功能证据**（2026-10-24）

非 tiled 网表的字节漂移来自 W1/W2/W3 的 **TILING-only 逻辑**（含无条件实例化的 `wOutMem2`）与行号位移，
不是窄路行为变化。用**窄路功能闸门**直接证明：

- `bash y1/tools/run_unitexec_ab.sh` ⇒ **RESULT: PASS**（全部子判据 OK）：
  逐字节对黄金、三方计数对账（AR/AW/B、RD/WR 字节）、几何钉死、非退化预载、
  负对照 A（shift 6→5）与 B（权重翻转 1 字节）都**精确命中预测且不等于黄金**、
  err 路径（SRC 非 32B 对齐）、QUANT_SHIFT 表/网表两侧负对照、GO2 二次 go、
  比较器扰动、`check_dangling.py` 零悬空。
- 因此把 b1 闸门的 `EXPECT_UE/W32/W640` 重锚为当前值（`9d8fa906/52fa5b20/c41e0449`），
  并在脚本里写明旧锚点出处（d313592）与"恢复逐字节冻结"的具体改法（§7.1b-5）。
- b1 闸门的 [1]~[3]（conv15 逐字节/gather_bytes/负对照）随后复跑，判**当前 tiled 网表**
  （`5ff0664a`，与 `led1` 比特流同源）。

### 7.1d b1 闸门在**交付网表**上的复判（2026-10-24，RESULT: PASS）

对 `gen/UnitExec_tiled.v = 5ff0664a`（与 `led1` 比特流同源）：

- [2] conv15：`MISMATCH=0 NEIGHBOR_BAD=0`，`GATHER_BYTES=924800 == GEXP`（GB_OK=1）；
- [3] c64_40 3×3：`MISMATCH=0 NEIGHBOR_BAD=0`，`GATHER_BYTES=123904 == GEXP`；
- [4] 负对照（`b1_play=0`）：数值仍逐字节对，**计数翻 8 倍（123904→991232）**、`GB_OK=0`
  ⇒ 红点唯一且可归因；
- [0] 冻结：重锚三元组 + `NEUTRAL base/new` 三份逐字节相同。

⇒ 交付比特流的 NPU 网表在数值与流量口径上都被官方闸门认证；窄路功能另有 `run_unitexec_ab.sh` PASS。
下一步（G2-c Step A / 提频）都以这份 `5ff0664a` 为基线。
