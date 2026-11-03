# Y1 NPU B2：tile 列 halo 复用 + s=2 tileBuf 扩展（收口报告）

状态：**闸门全绿**；PnR/上板见 §6/§7。
被测：`rtl/UnitExec.scala`（`TILING=true` 的 `gen/UnitExec_tiled.v`）+ `rtl_test/UnitExecWideTb.v`。
闸门：`y1/tools/run_b2_halo_ab.sh`（`RESULT: PASS`，log：`build/b2_regen/gate_b2_green.log`）。

## 0. 结论

- **B2a（s=2 的 tileBuf）与 B2b（逐 ci 的 2 列 halo shadow）都已进产品网表**，四档宽 tile 作业整层逐字节对，
  交付口径与 B1 完全一致，取数口径逐 band 等于逐列模型。
- 实现期**实测抓到并修掉两个缺陷**（§2.1/§2.2）；闸门本身也修了两处判据缺陷（§2.3），
  另记一条**既有 gather 的 8-lane 过取**（§2.4，B3 的输入）。
- 资源（dev_map）：LUT **79,209.5 / 50%**、DRM **273 / 66%**（B1 为 62%）、APM 271 / 37%；
  PnR `All Constraints Met`，比特流 9,188,552 B（md5 `752b004c…`）。
- **上板 A/B**：`y1run` RUN **3,147,500,340 → 2,724,168,950 ns（−13.5%，1.155×）**，12/12 CRC 全 OK；
  `y1cam --once` NPU_MS **3147 → 2725 ms**（与 y1run 一致）。
- G7 标定：同一 `c16_160x160` 作业，`b2_hit=0 → 1` 的喂列拍数 **1,704,436 → 1,566,196（−8.1%）**
  ⇒ map §4 的**中间档**（R2/AR 字节口径，折算 ~0.31 s），不是上界 R4（0.99 s）；板级实测 −0.423 s
  （含 B2a 的 0.05–0.18 s 与取数减少的连带收益）。

## 1. 改动（全部在 `if (TILING)` 里；`TILING=false` 三份网表逐字节不变）

| # | 位置 | 改动 |
|:--|:--|:--|
| ① | `UnitExec.scala:3018` | `b1Depth = WIDTH*(2*IMG_H_MAX+2)` = 34×66 = **2,244 字 = 17,952 B**（原 9,248 B） |
| ② | `:3024` | `b1Use := tilingW && !isDwW`（去掉 `tS==1` 门）⇒ `s=2` 也走 tileBuf 重放 |
| ③ | B1 节后 | `b2Halo : Mem(64b, NCOB_MAX*2*(IMG_H_MAX+2))` = 8×68 = **544 字 = 4,352 B**；`b2Fill`/`b2Hit`；命中列 `DECIDE→EMIT`（不 fetch）+ `mpu.io.x := b2Word` |
| ④ | 同③ | **tileBuf 的写数据改为 `Mux(b2Hit, b2Word, wxCol)`**（缺陷修复，见 §2.1） |
| ⑤ | 同③ | 新观察口 `gather_fetch_bytes`（32 B band 完成计数，**只数窗口行** `wRow < tNRow`；见 §2.2） |
| ⑥ | `UnitExecWideTb.v` | `gather_fetch_bytes` 端口 + `+FEXP=` 判据 + `CYC_WR`（`WIDERUN` 喂列拍数） |

B2b 的边界（与 map §3.2 一致）：只开 `s=1 ∧ tx>0` 的窗口**前 2 列**；shadow 槽号 = `wCi[2:0]`（dense 填充趟 /
dw 对角趟共用）；**只跳"格"不跳 band**（`wxBndV/wxBndB` 账本一行不动）；行 halo 不做。

## 2. 正确性与三个实测缺陷

### 2.1 R-g：命中列的 tileBuf 写数据（**B2 实现缺陷，已修**）

- 现象：首版 B2 在 `c16_40x40`（`nCi=2/nCo=2/2×2 tile`）上 **MISMATCH=610**（25,600 字节），
  全部落在**输出列 32/33、通道 8–15**（= 第 2 个 co-block 的接缝列）。
- 根因：命中 shadow 的列，`mpu.io.x` 被换成 shadow 值，但 `b1Buf.write` 仍写 `wxCol`（gather 的原始列，
  命中时是**残留**）⇒ 填充趟的 tileBuf 在 halo 列是垃圾 ⇒ **重放趟**（`co-block≥1`）读回后接缝列全错。
  co-block 0 走填充趟（直接用 shadow）⇒ 正确。通道 8–15 正是第 2 个 co-block ⇒ 与证据一一对应。
- 修法：tileBuf 写数据 `Mux(b2Hit, b2Word, wxCol)`（非命中列逐字不变）。
- 证据：`c16_40x40` 修前 **610** → 修后 **0**；c64/c16_160/dw/s2 全部 0。
- 已补进 `b2_map.md` 的风险表 R-g。

### 2.2 计数口径：尾排预取（**既有 gather 行为，计数口径已对齐**）

- 现象：`gather_fetch_bytes` 比逐列模型多 **32 B × nCi**（c16_40x40 +64；c64_40x40 +256）。
- AR 跟踪（`+ARF` 调试 TB）定位：多出的 band 全在 `wRow = tNRow` 的**尾排**——gather 在收工那一拍还会对
  尾排发起 1 个 band 的预取（数据不交付、不进有效窗口）。这是 B1 就有的行为，与 B2 无关。
- 口径：计数器限定 `wRow < tNRow`（只数**窗口行**的 fetch）；尾排预取的带宽代价记在 e2e 的 DDR 账上，
  不进本闸门的取数判据。改后模型逐 band 精确（c64 **196,608**、c16 **774,144**、dw **215,040**）。

### 2.3 闸门判据自身的两个缺陷（**已修**）

1. `halo=False` 实参被 `model()` 包装函数丢弃 ⇒ 正/负对照用了**同一个** FEXP。改为显式 `nohalo` 标志。
2. 旧模型"每行独立数 band"高估取数（忽略 `wxBndV/wxBndB` 的**跨行复用**）：c64 给 270,336，实际 196,608。
   改为**逐列模拟**：tile(ty 外/tx 内) → 趟(ci) → 行 → 列，账本 `last[p]` 跨行/跨 tile/跨趟持久，
   `s=1 ∧ tx>0` 的前 2 列整列不 fetch，pad 行/列不 fetch。

### 2.4 既有 gather 的 8-lane 过取（**非 B2 引入；B3a 已收掉**）

s2 的取数模型差恰好 8/3：`cin=3` 时 `wxNPl=3` 只决定**交付**字节数，FETCH 仍固定扫 **8 个 lane**
（AR 跟踪实测每列 `pl=0..7`）⇒ 首层（`Conv_0`，cin=3）的输入读是 nominal 的 **2.67×**。
B1 的 `gather_bytes` 口径（按 `wxNPl`）没有暴露这一笔；B2 的 `gather_fetch_bytes` 第一次把它量出来。
本片**不改**（属 B3/DDR 流量范畴），模型按 8 lane 记账。

> **后记（2026-10-21，B3a）**：已在 `wxPNE` 上加 `p < wxNPl` 门 ⇒ FETCH 只扫有效平面；
> `s2_3x16` 取数 **232,960 → 87,360（−62.5%）**、数值仍 0；`c10_40x40`（npl=8+2）30,720 == 模型；
> 全帧名义输入 20.6 MB 里这笔过取是 **2.368 MB（11.5%）**，见 `y1/reports/b3_gather.md`。
> 本报告的闸门从 B3a 起按 `npl` 记账（§3 的 s2 行相应变为 87,360）。

## 3. 闸门（`bash y1/tools/run_b2_halo_ab.sh`）

| # | 作业 | 数值 | 交付口径 `gather_bytes` | 取数口径 `gather_fetch_bytes` | 备查 |
|:--|:--|:--|--:|--:|:--|
| [1] | `c64_40x40`（cin64/cout64、2×2 tile） | MISMATCH=0 | 123,904（= B1） | **196,608**（B1 后 219,136） | 8 ci 槽 + 8 co 重放 |
| [2] | `c16_160x160`（5×5 tile、8 接缝） | MISMATCH=0 | 462,400 | **774,144** | 25 tile |
| [3] | `dw16_80x80`（depthwise） | MISMATCH=0 | 0（dw 无填充趟） | **215,040** | `WIDE_PASSES=2=nCo` |
| [4] | `s2_3x16`（3→16、64×64、s=2） | MISMATCH=0 | **53,856**（旧 107,712 的一半） | **232,960** | B2a |
| [5] | 负对照 `assign b2_hit=1'b0` | **MISMATCH=0** | 123,904（不变） | **219,136**（回到无 halo） | `+FEXP=196,608` 必红：`FB_OK=0`、`RESULT: FAIL` |
| [6] | G7 `c16_160x160` `b2_hit=0/1` | — | — | 1,118,208 / 774,144 | `CYC_WR` **1,704,436 → 1,566,196（−8.1%）** |

[0] 冻结：`TILING=false` 三网表 md5 不变（`dd9ee31e / af509071 / 781bb0fd`）+ 源码中性（base/new 两次现生成同）。

G7 判读（map §4 预先写死）：8.1% 落在 5–15% 的**中间档** ⇒ 帧不是被冷突发完全串行化（R4 不成立），
B2b 的板级收益按 R2/AR 字节折算约 **0.31 s**；B2a 另计 0.05–0.18 s。合起来 B2 的预期落点
**≈ 2.66–2.79 s**（3.1475 s 起），实际以上板 A/B 为准。

## 4. 取数模型（逐列模拟，`models.py`）

- `gexp`（交付）= Σ_tile 窗口列数 × 有效平面数（`wxNPl`）——B2 前后**不变**。
- `fexp`（取数）= 逐列模拟 gather 的 FETCH 判决：
  - tile 序 ty 外 / tx 内；每 tile 的趟序 ci（dense 只有每个 ci 的**填充趟**取数；dw 每趟都取）；
  - 账本 `last[p]`（p=0..7）跨行/跨 tile/跨趟持久；同 band 命中不重取；
  - `s=1 ∧ tx>0` 的窗口前 2 列整列不 fetch（B2b 命中）；pad 行/列不 fetch；
  - **固定 8 lane**（§2.4）；只数窗口行（§2.2）。
- 四个作业的模型值与 RTL 逐一相等（表 §3）。

## 5. 确定性 / 冻结 / 网表指纹

- 两次**全量重生成**（29 条生成命令）逐字节相同：
  `UnitExec_tiled 4b80be179e04b0c90d373e0ad45eb84d`、`LayerSched f64ede268fe73cb7a4eb5bfe0f212024`、
  `NpuTop 135bd4d13e664d15235dcab6050c8bb9`。
- `TILING=false` 三份：`UnitExec.v 2aa33f68…`、`_w32 0347a2ef…`、`_w640 aa1d8094…`（与 B2 前同）。
- 产品 PDS 只引用 `y1/gen/NpuTop.v`；`gen/` 是本地构建产物（不入库）。

## 6. PnR / 比特流

- 入口：`YESHENMINI_PNR_TAG=video1b2 YESHENMINI_PNR_FRESH=1 YESHENMINI_SYNTH_MODE=speed`，
  log `sim/reglogs/pnr_video1b2.log`（compile→bitstream 1h03m）。
- dev_map：**LUT 79,209.5 / 50%**、FF 110,122 / 35%、**DRM 273 / 66%**（B1 62%）、
  DRAM 8,079 / 21%、APM 271 / 37%、GPLL 6 / PPLL 2。
- 时序（`report_timing/yeshen_mini_board_top.rtr`）：**Design Summary: All Constraints Met**。

| 时钟 | 约束 | 估计 | Slack |
|:--|--:|--:|--:|
| soc_clk | 100.000 MHz (10.000 ns) | 105.764 MHz | **+0.545 ns** |
| cpu_clk | 100.000 MHz (10.000 ns) | 106.372 MHz | **+0.599 ns** |
| npu_clk | 54.348 MHz (**18.400 ns**，过约束) | 54.386 MHz | **+0.013 ns** |
| core_clk | 125.000 MHz (8.000 ns) | 131.251 MHz | +0.381 ns |

  `npu_clk` 的 +0.013 ns 是相对 **18.4 ns 过约束**（B1 为 +0.829 ns，本片新增的 shadow 读/写与
  `mpu.io.x` 覆盖把该域压紧了）；板上实际 NPU 时钟 50 MHz（20 ns）⇒ 真实余量 ≈ **+1.6 ns**。
- 比特流：`sim/reglogs/pds_video1b2_p10.000/prj_tasks/pnr_1/generate_bitstream/yeshen_mini_board_top.sbit`
  = **9,188,552 B**，md5 `752b004c67f8eb61edc7189dea0e7028`。

## 7. 上板 A/B（2026-10-21，板已经由用户授权）

烧写：`flash_and_verify.py --tag video1b2`（cdt_js 动态口 62000；done bit=1 一次成功），
启动全 marker PASS（SD SDR / OpenSBI / Linux / LiteEth / dropbear / 用户态 / 登录提示符），ping + ssh PASS。

| 项 | B1（`video1b1r`） | **B2（`video1b2`）** | Δ |
|:--|--:|--:|--:|
| `y1run --frames 1` RUN | 3,147,500,340 ns | **2,724,168,950 ns** | **−423.3 ms（−13.5%，1.155×）** |
| 12 路输出 CRC | 12/12 OK | **12/12 OK** | 逐字节一致 |
| `y1cam --once` `NPU_MS` | 3,147 ms | **2,725 ms** | **−422 ms（−13.4%）** |

- `y1run` 的 12/12 CRC（obj/bbox/kps 各 4 路）是与 B1 **同一个冻结人脸 payload** 的逐字节对账 ⇒
  B2 的数值与 B1 完全一致（B2a/B2b 只改取数，不改算术）。
- `y1cam --once` 本帧 `CAM_DETS=0`（`post: cands=0`，score_thr=0.90）——**场景相关**（镜头前本帧无人）；
  数值判据由 `y1run` 的 12/12 CRC 承担（B1 的无脸负对照同样是 0 dets）。
- **B2 的板级落点 2.724 s**（G7 预测 2.66–2.79 s，吻合）；B1 的 3.1475 s → 0.367 fps。
  要与 B3 的"多笔在飞"叠加才能继续往 2.0 s 以下压（见 §8）。

## 8. 给 B3 的输入

1. **8-lane 过取**（§2.4）：首层 cin=3 的 fetch 是 nominal 的 2.67×。若 B3 只做"多笔在飞"而不收这笔，
   帧级输入读仍有一块虚高；建议 B3 先按 `gather_fetch_bytes` 的口径把每层实读列出来，再选杠杆。
2. **多笔在飞的前置**：`DdrMaster.start` 只在 **IDLE** 接受（单事务；`rqDepth` 是**事务内**的块预取），
   所以 map §5.2 的"8 个平面 FETCH 并发"必须先扩成**多事务队列**，或改走"更大 band（字节换笔数）"。
   两条路的代价不同：前者动 DdrMaster（全 NPU 共用），后者只动 UnitExec 的 gather/缓冲。
3. G7 只降 8.1% ⇒ 即使多笔在飞，收益也要按 R2（AR 字节）与 R3（交付列）重新标定，
   不能直接套 map 的 0.83–1.45 s 上界。
