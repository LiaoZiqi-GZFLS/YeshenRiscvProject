# G2-b spec：gather 行带环前瞻（K 个 band 在飞）

日期：2026-10-23　状态：**实施中**　前置：G1（ci 影子预取）−1.94% 已回退；G2（NHWC）暂缓

## 1. 结论性事实（G2-P0 实测）

1. **零延迟仿真**（c64_40 tiled，64/64，8×8 趟）：`CYCLES=1,836,614`，
   `fetch 39,360 (2.1%) / emit 1,193,536 (65.0%) / decide 125,424 (6.8%) / 其余 26.1%`。
   ⇒ 无内存延迟时宽路是 **emit（切片消费 ~4 拍/列）主导**。
2. **加延迟后 DUT 在第一 band 之后不再发 AR**（模型统计 `bursts=8`）⇒ gather 是
   **“整 band 收齐 → 才发下一 band”的硬串行**，每个 band 的一次往返完全暴露。
3. 板级 Conv_15：166 ms vs 零延迟外推 ~57 ms ⇒ **内存停滞 ≈2/3**；G1 只值 −4% 与此一致。

## 2. 目标与账

- 每行 band = 32 像素 × 8 通道 = **256 B**；emit 侧消费 ≈34 列 × ~4 拍 ≈ **140 拍/行**；
- 板级单流实测 ≈700 拍/band（≈640 冷延迟 + 传输）；而**聚合**带宽 22–24 MB/s 对应
  **≈34 拍/band**（256 B ÷ 22 MB/s ≈ 0.63 µs @54 MHz）。
- ⇒ **只要有 5–6 个 band 同时在飞**，band 到达速率就能跟上 emit（34 < 140 拍/band），fill 被藏住。
- 上限由 DDR 总流量决定：**35.5 MB（读 17.7 + 写 17.8）/ 22–24 MB/s ≈ 1.5–1.6 s**
  ⇒ 目标帧 **2.034 → ~1.6 s（−22%）**；若写路径/视频竞争更轻，可更低。

## 3. 设计（只动 TILING 路径；TILING=false 逐字节冻结）

### 3.1 结构

- **环缓冲**：`pfRing[K][32]`，每个 band 32 列 × 8 B = 256 B；`K=6` ⇒ 1.5 KB（DRAM/FF 皆可），
  另加每槽 `{valid, bandBase, row, colBase}` 身份寄存器。
- **独立预取 FSM**（照 G1 影子机的手法，全部新代码**追加在类尾**，不动既有行 ⇒ 冻结 md5 不变）：
  - 触发：主 gather 进入某个 tile 的第 1 行（`wRow==0`，`wCol==0`）时，扫 `r = 1..K`，
    把第 `r` 行第一个 band 的身份/地址算好入队（**只算地址，不发 AR**）；
  - 发放：`pfIss < pfTgt` 时用**自己的** SG 批次（8 平面 × 32 B）依次下发，`rqDepth=8` 允许 8 笔在飞；
  - 落地：`rd_data` 直达 `pfRing[slot]`，每收完 8 项置 `slot.valid`；
  - 与主 gather 共用 `DdrMaster`：主 gather 只在 `wxSt==2` 时发 start；预取在 `wxSt!=2` 时发，
    并沿用 G1 的两条承重约束（`when(pfAct){ rd_ready := True }`、`when(pfSt =/= 0){ sg_flush := False }`）。
- **命中快路**：主 gather 的 DECIDE 若 `wxNeedB` 且环中有 `bandBase == wxBB` 的有效槽 ⇒
  **跳过 FETCH**（`wxSt := EMIT`），列数据改从 `pfRing[slot]` 取（覆盖 `mpu.io.x`）；
  未命中 ⇒ 走既有 FETCH（行为不变），并把该 band 记入“未命中”计数（诊断口）。
- **边界**：环只覆盖**同一 tile 内、同一 ci** 的行；换 ci/换 tile/末行 ⇒ 退化为既有路径（不做跨 tile）。

### 3.2 与既有账本的关系

- `wxBndV/wxBndB`（平面 band 账本）**一个字节不动**：命中时仍按“已装”记账（数据确实在环里）；
- `gather_bytes` 口径不变（交付字节数不变，只是来源从 xwBuf 换成 pfRing）；
- AR 总数**不变**（同样 8 项/band，只是提前发）——本片不减少任何读。

## 4. 闸门

1. **单元级**（复用 `run_b1_tilebuf_ab.sh`）：逐字节 == 冻结黄金；`GATHER_BYTES` 逐值不变；
   新增诊断 `PF_HIT/PF_MISS`（`UE_PF` ifdef）——正例命中率 >80%，负对照（把命中关掉）必须仍逐字节对
   且周期变长（红点唯一）。
2. **tiling2d**：s=1 六几何 + s=2 32×32 + 两负对照（环只在 s=1 开，s=2 走既有路径）。
3. **冻结**：`TILING=false` 三份 md5 不变（`7593b189/817ab5bb/5d2cd81a`）。
4. **板级 A/B**：`y1run --frames 2` vs **2,074.4 ms**；判据 **≥10% 才保留**、12/12 CRC、屏不回归；
   `--unit-trace` 看 conv1x1/dw 的 ns/pp 是否向零延迟值靠拢。

## 5. 风险与止损

| 风险 | 对策 |
|---|---|
| 预取把 DDR 打满，反而挤掉写/视频 ⇒ 总时间不降 | 板级 A/B 先跑；`PF` 可关（desc/参数）一次编译两档 |
| 环命中判定错 ⇒ 数据错 | 命中键 = 绝对 band 基址 + ci + 行号；逐字节闸门 + 负对照 |
| 与主 gather 抢 `DdrMaster` / `sg_flush` 误清 | 沿用 G1 的两条承重约束（已在上板验证过其中断语义） |
| 时序（新增比较/环地址） | 比较与选择都在 `npu_clk` 54 MHz 下，预计余量大；dev_map 看 LUT 增幅 ≤3% |
| 收益 <10% | 回退全部 G2-b 改动并留档（同 G1 的净结算） |

## 6. 切片

- **G2-b-1**：环 + 预取 FSM + 命中快路（仿真闸门全绿，含负对照）；
- **G2-b-2**：dev_map + PnR（All Met）+ 比特流；
- **G2-b-3**：板级 A/B（判据 §4.4）+ 逐单元表；
- **G2-b-4**：净值结算（保留 / 回退 + 留档）。

## 7. 实现记录（2026-10-23）

落地形态（全部追加在 `UnitExec.scala` 类尾，`TILING=false` 三份 md5 仍冻结）：

- `pfMem` = 6 槽 × 32 字 × 8 B（与 `xwBuf` 同形 `[plane][word]`），`pfBase/pfRowS/pfV` 每槽身份；
- 预取 FSM：IDLE（算下一行地址）→ SCAN（8 项一拍一项入 SG 队）→ WAIT（4 拍/项落环）→ done 后
  `pfNext+1`；触发条件 `pfNext ∈ (wRow, wRow+K)`、行在窗口内、主口空闲；
- 命中：DECIDE 比较 `(行号, band 基址)` ⇒ 直接 `wxSt:=EMIT`；列数据从环取（覆盖 `mpu.io.x`）；
- 主 gather 让路：预取批在飞时 DECIDE 原地等（不打 orphan/不 flush）；预取期间 `rd_ready=1`、`sg_flush=0`。

**踩到并修掉的两个真 bug**（都由逐字节对账抓出，TB 自身的 `RESULT: PASS` 抓不到）：

1. `pfHitR` 原写法在 `wxRun` 每拍更新（EMIT 时为 0）⇒ 切片在 EMIT 停 ≥2 拍时第 2 拍起读回
   `xwBuf` 旧值（12/102,400 字节错）。修为**只在 DECIDE 更新**。
2. 命中覆盖没排除 **pad 列**（`wxPad = !(wxRowOk && wxInWin)`）⇒ 窗口外列主路径给 `z_pad`、
   环却给真实字节（397/102,400 字节错）。修为 `pfHit` 必须 `!wxPad`。

## 9. 止损结论（2026-10-23）：**未收敛，已回退**

三次 FSM 交互修复后仍未通过单元闸门：

| 轮次 | 现象 | 修复 | 结果 |
|---|---|---|---|
| 1 | 12/102,400 字节错 | `pfHitR` 只在 DECIDE 更新 | 仍错（换成 397 B） |
| 2 | 397/102,400 字节错 | `pfHit` 排除 `wxPad` 列 | **0 错**，但 `GATHER_FETCH_BYTES` 未降 ⇒ 零命中 |
| 3 | 3.65M 拍挂死（`dstate=12/rd_valid=1/rd_ready=0`） | 预取指针**每 tile 行扫描复位** + FSM 跨相位排空 | 仍挂（5.9M 拍） |
| 4 | 同上 | 预取只在主 gather **EMIT** 启动（防抢批） | **仍挂（12M 拍超时，输出 102,003/102,400 错）** |

**根因判断**：预取与主 gather **共享同一个 `DdrMaster` 的单批（mode=3）语义** —— `done`/`rd_valid`/`rd_ready`
没有“批 owner”标识，两个 FSM 各自解释同一个 `done`，在趟边界/相位交替处必然出现所有权错位。
这需要改 `DdrMaster` 契约（加 owner 位或两套独立 SG 队列），已超出一片 RTL 改动的范围。

**处置**：源码回退到 G2-b 之前（`git checkout -- y1/rtl/UnitExec.scala`），网表重生成后
`TILING=false` 三份 md5 仍为 `7593b189/817ab5bb/5d2cd81a`、`UnitExec_tiled` 回到 `f01da4da`。
**重做前的前提**：先给 `DdrMaster` 的 SG 批加 owner/独立队列，再谈 ring 预取。

**保留的有效结论**（与实现无关，已独立成立）：
1. 零延迟下宽路是 **emit 主导**（fetch 2.1%、emit 65.0%）；
2. gather **整 band 收齐才发下一 band**（加延迟后不再发 AR）；
3. 因此换布局（NHWC）只值“缩短一次往返的传输段”，真正的杠杆是**让多个 band 同时在飞**；
4. 板级上限 ≈ 总流量 / 22–24 MB/s ≈ 1.5–1.6 s（−22%）——目标本身仍成立，只是实现路径需要先改 `DdrMaster` 契约。

## 10. G2-c 探针（2026-10-23）：owner 端口**在生成阶段被丢弃**

独立探针（`DdrOwnerProbe`：直接 `new DdrMaster(..., withOwner = true)`）：
`if (withOwner)` 块内的 `println` **确实执行**（说明分支成立），但生成的 `DdrOwnerProbe.v`
里**找不到 `sg_owner/batchOwner/batch_owner` 任何一个** ⇒ **端口在 elaboration/生成阶段被丢弃**，
不是"TILING 取到 false"的问题。`UnitExec` 以 `withOwner = TILING` 例化时同理（tiled 网表也无该端口，
且 md5 不变）。

**下一步（重做 G2-c 时）**：把 owner 端口声明放进 **`io` Bundle 内部**（`val io = new Bundle { ... }`）
并显式 `setName`，或在 `DdrMasterConfig` 层加开关；当前"类尾 `if (withOwner) in Bool()`"的写法不可用。
探针源码与改动已清理（避免死代码），结论留在本页。

（本页 §10 之后若重做，请先复现"探针里端口可见"再动 UnitExec。）
