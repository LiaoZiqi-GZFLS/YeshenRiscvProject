# P3 设计：gather 队列 `rqDepth 4→8`（不加取数字节）

状态：RTL 已改、单元/数值闸门进行中；未上板。

## 1. 问题与依据（P1 实测）

P1 逐单元表拟合：`fill = L/32 + 11 拍/像素`、`L ≈ 990 拍/带`。其中 **L 由“8 项分两波”构成**
（`DdrMaster rqDepth=4`，而一批 gather 有 8 个平面项）⇒ 每带相当于 **2×~495 拍**的端到端等待。
fill 占全帧 ~80%（≈1.7 s）。

P2（组宽 32 B→128 B）想靠“更大的组”摊薄，但 34 px 窗口 + 行距 >128 B ⇒ 每行换组、取数放大 2–4×，
板级 **2.4275 s vs 2.1678 s（+12%）**，已回退（`5f59403`）。结论：**不能加字节，只能提并发**。

## 2. 改动（一处参数）

`UnitExec.scala`：`new DdrMaster(ddrCfg, rqDepth = (if (TILING) 8 else 4))`。

- TILING（宽路 gather）用 **8 槽**：一批 8 项一波发完，不再分两波；
- TILING=false 仍是 4 槽 ⇒ **三份冻结网表逐字节不变**（`7593b189/817ab5bb/5d2cd81a`）。
- 队列数据缓冲 `qbuf` 4×128 B → 8×128 B（+512 B 寄存器 ≈ +4 k FF）；槽指针 3 位。
- 取数字节、burst 长度、组宽、账本语义**全部不变**。

## 3. 预期与风险

- 预期 fill：`(495 + 32·11/8?)` 级别 → 约 **26–30 拍/像素**（原 42）⇒ RUN **1.7–1.9 s**。
- 风险：若 glue/桥对单 owner 的在飞读上限仍是 4，则此改动无收益（板级 A/B 一次即可证伪）。
- 面积：+4 k FF；时序看 PnR（npu 域原本 +0.57~0.67 ns）。

## 4. 判据

1. TILING=false 三网表 md5 不变；tiled 网表 `b0081e7c → f01da4da`（8 槽 `qbuf_7` 存在）。
2. B1 tilebuf / B2 halo（c64/c16/dw/s2 + 负对照）/ x1skip / x1center / dwpack / wgtblob_tiled /
   tiling2d_wide 全 PASS（行为不变，纯并发度）。
3. dev_map 0 error；PnR All Met；比特流出带（tag `video1p4rq8`，**同时含相机 P4 画质改动**）。
4. 上板（等窗口）：`y1run --frames 1` RUN ns vs **2,167,760,940**，12/12 CRC；
   `--unit-trace` 看 dw / 低通道 dense 的下降幅度；相机画质另行目视。
   NPU RUN 与传感器配置无关，故同一次 PnR 可同时服务两件事。

## 5. 构建结果（2026-10-21，tag `video1p4rq8`）

- **dev_map：PASS，0 error**。资源：**LUT 80,605 (51%)**、FF 110,614 (35%)、DRM 273 (66%)、APM 263 (36%)。
  与 P2 那版相比 FF 少 6.1k（xwBuf 回退生效），LUT 与 B3b 基线持平。
- **PnR：All constraints met**（`report_timing` Performance Summary，slack 全正）：

| 时钟 | 要求 | 实测 | slack |
|---|---:|---:|---:|
| soc_clk | 100 MHz | 108.42 MHz | **+0.777** |
| cpu_clk | 100 MHz | 107.75 MHz | **+0.719** |
| npu_clk | 54.35 MHz | **56.09 MHz** | **+0.572** |
| camera_clk_0 | 100 MHz | 132.10 MHz | +1.215 |
| lcd_clk | 51.92 MHz | 57.50 MHz | +1.868 |

- 比特流：`sim/reglogs/pds_video1p4rq8_p10.000/prj_tasks/pnr_1/generate_bitstream/yeshen_mini_board_top.sbit`，
  9,188,552 B，md5 `d41adeda1a50dfbb5cbd83b28113ea5e`。
- 本带同时含**相机 P4**（`data_init.v`，AGC 1×/曝光 1216）。上板判据：`y1run` RUN ns vs
  `2,167,760,940`、12/12 CRC；相机画面另行目视。**未上板**，等窗口。

## 6. 上板结果（2026-10-21，`video1p4rq8` / d41adeda）

- 烧写一次成功（done bit=1），启动 marker 8/8、ping/ssh PASS；`y1run_trace --frames 2 --unit-trace`：
  **RUN 1 ns=2,167,938,030**（status=0x00004301）、**12/12 CRC**、`Y1RUN: PASS frames=2 pass=2 fail=0`。
- 对照 P1 基线 `2,167,760,940` ⇒ **+177,090 ns = +0.008%**（噪声级）。
  ⇒ **rqDepth 4→8 单独零收益**，与 spec §4 的风险预判一致：DDR 侧在飞能力被更下游限住。
- 当时板上相机/屏仍在跑（VIDEO `STATUS` 帧序号 10 s 走 168 帧 ≈ 16.8 fps）⇒ 这次 RUN 是
  **带视频 DDR 流量**的读数，与 B3b 以来所有 NPU 数字同口径。
- **根因（P4 查清）**：板级 `ddr_arbiter_2to1` 的读通道是 **AR 串行（单笔 outstanding）**，
  把 DDR3Bridge 内 DEPTH=4 的结构性多未完成压成 1 ⇒ 每个 32B 散读都要等一次完整往返。
  见 `y1/reports/p4_ddr_arb_mo.md`。

### 6.1 rqDepth=8 的处置

**保留**，作为 P4 解锁 4 笔在飞之后的**供给侧队列**（桥一次只收 4 笔；NPU 侧多出的 4 笔
在 credit 释放的下一拍即可递交，避免每波一个发令气泡）。P3 单独的净收益仍是 0，
若 P4 的板级 A/B 也无效，则 P3 与 P4 一起回退。
