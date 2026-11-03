# P2 设计：宽路 gather 组 32 B → 128 B（16 拍 SG 项）

状态：spec（动手前钉死范围/判据）。上游证据见 `unit_trace.md` §5、`b3b_ddr_multi_txn.md` §8。

## 1. 问题（实测）

逐单元表（`unit_trace_run1.txt`）给出的 fill/replay 模型：

```
fill = L/32 + 11 拍/像素   （L = 每次 gather 的端到端延迟，实测 ≈ 990 拍）
replay = 2 拍/像素
```

- 宽路 gather 现在**每 32 个输入像素**发一批：8 个平面、每项 `sg_beatsM1=3`（**4 拍 = 32 B**）。
- `DdrMaster.CHUNK_BYTES=128`（qbuf 每槽 16 拍），但 SG 项只写前 4 拍 ⇒ **每个 128 B 槽浪费 96 B**。
- `rqDepth=4` ⇒ 8 项分两波；全帧 fill 像素·趟 ≈ 3.06 M ⇒ gather 约 **1.7 s / 2.17 s**。
- dw 的每一趟都是 fill（对角趟无 replay）⇒ 692 ms 几乎全是"11 拍计算 + ~31 拍 gather 等待"。

## 2. 设计

只改 **TILING=true** 的宽路 gather（`UnitExec.scala`）：

1. **组宽 128 B**：SG 项 `sg_beatsM1 := 15`（16 拍 × 8 B）；项地址 **128 B 对齐**（`& ~127`）。
   一个 128 B 组 = 128 个输入像素；宽度 <128 的行/窗口按平面连续地址自然跨行取。
2. **xwBuf 按组扩到 8 平面 × 16 字**（128 字 × 8 B = 1 KB）：
   - RD 落点 `plane*16 + beat`（`wxFBe` 4 位）；
   - 列读 `wxIdxW = wxGAbs[6:3]`、字节 `wxIdxB = wxGAbs[2:0]`、平面内下标 `wxPIDX(p)[6:0]`；
   - `wxBndB/wxSgBB` 记 128 B 组基址；`wxPNE` 仍是"本列该平面的组基址 ≠ 已装组基址"。
3. **重放/账本/EMIT 不动**：tileBuf、`wxSt` 相位、`wxSgGo/wxSgRd/wxSgDrn`、每趟清账本照旧。
   组没变时（同一 128 B 内的后续列）不发 AR，账本命中的平面不重取。
4. **TILING=false 逐字节不变**：`xwBuf` 尺寸用 `if (TILING) 128 else 32`，所有新下标只在
   `if (TILING)` 分支；三份 TILING=false 网表 md5 必须仍是 `7593b189/817ab5bb/5d2cd81a`。

不改 `DdrMaster`（`sg_beatsM1`/`sgQLen` 本来就是 4 位，128 B 突发 COPY 模式已在用）、
不改 `rqDepth`（留作下一片：把两波并一波）。

## 3. 预期与代价

- 每带延迟事件 **×1/4**（32→128 像素/批）：fill ≈ 990/128 + 11 = 18.7 拍/px（原 42）。
- 预测 RUN ≈ **1.3 s（−40%）**，dw 与低通道 dense 收益最大；1×1 64→64 主要吃 replay，收益小。
- 代价：xwBuf 256 B → 1 KB（+768 B 寄存器 ≈ +6 k FF）；`rd_data` 落点/列 mux 多 2 位下标。
- 过读：组尾最多多读 96 B（仍在 NPU arena 内；128 B 对齐、不跨 4 KB）。

## 4. 判据

1. **数值（先红后绿）**：`run_ddrmaster_sg_ab.sh`（组宽/对齐断言，负对照：把 beatsM1 改回 3
   必须数据错）、`run_b1_tilebuf_ab.sh`、B2 四档（c64/c16/dw/s2）、`run_x1skip_ab.sh`、
   `run_tiling2d_ab.sh`、`run_wgtblob_*`、`run_unitexec_ab.sh`、`run_dw_ab.sh`、`run_wide_*`、
   `run_multipass_ab.sh` 全 PASS。
2. **冻结**：TILING=false 三份 UnitExec md5 不变；全量重生成 48/48 确定性。
3. **资源/时序**：dev_map LUT ≤ 85%（当前 41%）、DRM 不涨穿；PnR All Met（npu ≥ 0）。
4. **上板 A/B**：`y1run --frames 1` RUN ns vs 基线 `2,167,760,940`（12/12 CRC 必须保持），
   `y1cam` NPU_MS 同向；逐单元表按单元复测，`Conv_3/16/20`（dw）与 `Conv_2/6`（低通道）
   应明显下降，`Conv_19` 基本不动 —— 这三组是"组宽"归因的正/负对照。

## 5. 影响面

- 数据路径语义不变（同一字节、同一账本、同一趟序）；只改**取数粒度**。
- 不碰旁路算子（maxpool/add/resize 286 ms，另立 BypassExec SG 片）与 1×1 数据流。

## 6. 实施记录（2026-10-21）

- RTL：`sg_beatsM1=15`、地址 `& ~127`、`xwBuf` 128 字、`wxFBe` 4 位、`wxPIDX[6:0]`/`wxIdxW[6:3]`、
  RD 落点 `plane*16+beat`；TILING=false 三份网表 md5 仍 `7593b189/817ab5bb/5d2cd81a`。
- **观测口径修正**：`gather_fetch_bytes` 原来按每项 32 B 记账（`wxSgEnq<<5`），现在一项取 128 B
  ⇒ 改 `<<7`。c64_40x40 的实测：**1856 项 = 237,568 B**，与"逐列模拟 128 B 组账本"模型逐字节相等
  （旧模型 196,608/32=6144 项已失效）。
- 闸门前置随设计更新：`run_b2_halo_ab.sh` 的 fexp 模型改 128 B 组（`a & ~127`，每新组 +128）；
  c64_40x40 的 halo 命中被组吸收（hit/nohit 同为 237,568）⇒ 取数红点改由 c16_160x160 承担
  （nohit 2,162,688 ≠ 正对照 2,064,384）。

### 6.1 闸门与资源（2026-10-21）

| 项 | 结果 |
|---|---|
| TILING=false 三网表 | `7593b189/817ab5bb/5d2cd81a` **逐字节不变** |
| 确定性 | 全量重生成两次 **48/48 逐字节一致** |
| `run_b1_tilebuf_ab` | PASS（含 NEUTRAL 三份 IDENTICAL、正/负对照） |
| `run_b2_halo_ab` | PASS：c64 fetch 237,568、c16 2,064,384、dw 331,776、s2 199,680，均 == 128 B 组模型；c16 nohit 2,162,688 ⇒ `+FEXP` 红点发火；G7 CYC **−0.4%**（halo 命中被 128 B 组吸收，属预期） |
| `run_x1skip_ab` / `run_x1center_ab` / `run_dci_ab` / `run_dwpack_ab` / `run_wgtblob_tiled_ab` | PASS |
| `run_chain_wide_ab` | **RED（继承）**：宽链 T-S3f 未实现 ⇒ 设计上的先红闸门，与本次改动无关 |
| dev_map（tag p2g128） | **0 error**；LUT **82,331/159,800 (52%)**（B3b 80,750 ⇒ +1,581）、FF 116,721 (37%)、DRM **273/415 (66%)**、APM 263/740 (36%) |
| PnR（tag video1p2g） | 进行中 |

### 6.2 PnR（tag `video1p2g`，FRESH + speed）

- `YESHENMINI_PNR_DONE`，**All constraints met**（`.rtr` Performance Summary，slack 全正）：

| 时钟 | 要求 | 实测 | slack |
|---|---:|---:|---:|
| soc_clk | 100 MHz | 107.81 MHz | **+0.724** |
| cpu_clk | 100 MHz | 106.96 MHz | **+0.651** |
| npu_clk | 54.35 MHz | **56.41 MHz** | **+0.674**（B3b +0.696 / P1 +0.572） |

- 比特流：`sim/reglogs/pds_video1p2g_p10.000/prj_tasks/pnr_1/generate_bitstream/yeshen_mini_board_top.sbit`，
  9,188,552 B，md5 `4697ce32986630e6b00fff6761298524`。

## 7. 板级结果与回退（2026-10-21）

- `video1p2g` 上板：`RUN 0 ns=2,427,504,250`（**2.4275 s**），12/12 CRC OK，status=0x4301。
  对照 `video1trace`（P1）基线 **2,167,760,940 ns** ⇒ **慢 12.0%**，P2 **净亏**。
- 根因（与闸门模型一致）：34 像素窗口 + 行距 >128 B ⇒ **每行都换 128 B 组**，一行取 128 B，
  而 32 B 带口径一行只需 2×32 B。取数放大：c64 **+21%**、c16 **+167%**、dw **+54%**、s2 **+129%**
  （B2 闸门 `GATHER_FETCH_BYTES` 实测值与新模型逐字节一致）。
- **决定：回退**（`git checkout 4c51e5f^ -- UnitExec/B2/tiling2d_wide`），保留 P1 只读遥测；
  本文件保留为负结果档。下一步候选：`rqDepth 4→8`（不加取数字节，只把每带两波并一波）。
- 过程教训：板子是**多会话共用**；为 NPU A/B 连续烧写前必须先确认相机线是否正在用板
  （本次覆盖了 `cam2lcd` 的比特流，导致屏幕画面变化）。
