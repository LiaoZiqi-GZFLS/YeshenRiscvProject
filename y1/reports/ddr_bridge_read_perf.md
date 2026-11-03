# DDR3Bridge 读吞吐 / 延迟曲线（2026-10-22）

装置 `y1/rtl_test/DdrBridgeReadPerfTb.v` + `rtl/DDR3Bridge.v`（iverilog）：
- AXI 侧 100 MHz：背靠背 32 B 读（arlen=3），在飞 ≤ K；DDR 侧 125 MHz：**流水化**读模型
  （AR 队列 8 深，每笔 `due=cyc+LAT`，到期按序每拍回一个 256 bit beat；不建 rready，靠桥的
  `inflightR` 信用兜住）。
- 测「首笔 AR → 最后一拍 R」的 AXI 时钟数。

## 曲线（K=4，32 B 读）

| LAT（ddr 拍，125 MHz） | B/cycle（100 MHz） | MB/s | dbgMaxOutR |
|---:|---:|---:|---:|
| 10 | 0.662 | 529.9 | 4 |
| 40 | 0.332 | 265.8 | 4 |
| 160 | 0.111 | 88.8 | 4 |
| 320 | 0.059 | 47.0 | 4 |
| **640** | **0.030** | **24.2** | 4 |

- 吞吐 ≈ `4 × 32 B / LAT`（桥的读在飞被 `DEPTH=4` 钉住）；桥内拆分/CDC 开销在 LAT=10 时仍有 530 MB/s。
- **板级 NPU 取数 ~22–24 MB/s 对应 LAT ≈ 640 ddr 拍（≈5.1 µs）**：32 B 散读跨 8 个平面
  （DRAM 页缺失）的冷访问延迟。这与 B2 map 里“冷 32 B 突发 2.08 µs”同一量级（IP/DRAM 侧）。

## 结论与候选

- 桥的读在飞是**结构性乘数**：LAT 不变时把 4 → 8/16，吞吐按比例上升。
- 候选（优先级）：
  1. **读侧 DEPTH 4→8**（写侧维持 4）：`rdQ/arCdc/rCdc/outR` 信用一起抬；若 IP 的 AR 队列吃得下
     8 笔，取数 ~24 → ~48 MB/s，预期整帧 2.07 → ~1.6 s。
  2. 若 IP 只吃 4 笔（arready 反压），则收益为零 ⇒ 需要另一个方向：
     **减少冷页缺失**（行向/通道分块布局，让同一页内的 128 B 连续读替代 4 次散读）。
- 先做 1（改动局部、语义不变），板级一次 A/B 即可判 IP 是否能吃 8。

## RDEPTH=8 对照（2026-10-22，`src/soc/DDR3Bridge.scala` 读侧独立档位）

> **结局（2026-10-22）**：上板 A/B **零收益**（−0.002%）⇒ 产品路径已回退到 DEPTH=4 / BN=4。
> 本节保留仿真方法与数据作记录；结论见文末“上板 A/B”一节。

改动：`rdQ=2×RDEPTH`、`arCdc/rCdc` 深度 = `RDEPTH`、`outR < RDEPTH`、`rFree = RDEPTH − rCdc.sOcc`；
写侧仍 `DEPTH=4`。`dbgOutR/dbgMaxOutR` 加宽到 4 bit。桥单元闸门（Verilator，AXI_W=64，ddr=100/125MHz）
**TEST PASSED ×2**。

同一装置、同一模型（K=8，32 B 读）：

| LAT（ddr 拍） | DEPTH=4 | **RDEPTH=8** | 倍数 |
|---:|---:|---:|---:|
| 160 | 88.8 MB/s | **176.8 MB/s** | 2.0× |
| 320 | 47.0 | **93.8** | 2.0× |
| 640 | 24.2 | **48.4** | 2.0× |

- 128 B 突发（ALEN=15，K=4）在 LAT=640 也到 **49.7 MB/s**（桥把每笔拆 4 个 32 B DDR 命令，
  在飞 DDR 命令由 RDEPTH 限 8）。
- **前提**：真 DDR IP 的 AR 队列得吃 8 笔；若 `io_ddrArReady` 只吃 4（反压），收益归零。
- 上板 A/B（tag `video1p6`）：`y1run` vs **2,074.4 ms（P5）**；≥5% 才保留；12/12 CRC 必过。
  若无效 ⇒ 回到“减少冷页缺失”（行向/通道分块布局）方向。

### 配套：板级仲裁器必须同档（BN=8）

桥抬到 8 后，**板级 `ddr_arbiter_2to1` 的 `BN=4` 仍会把桥的 8 笔掐回 4**（2026-10-22 发现）。
已改：`b_out/v_out` 加宽到 4 bit；板级例化 `#(.AW(28), .BN(8))`（视频侧仍 1）。
闸门：`run_video_gates.sh` 新增 **U1c**（BN=8，8 笔桥 AR ⇒ `MO_PEAK=8` PASS；BN=1 负对照仍必红）。
⇒ 上板 A/B 必须用 `video1p7`（桥 RDEPTH=8 + 仲裁器 BN=8），否则 A/B 无意义。

## PnR `video1p7`（2026-10-22）

- 入口：`YESHENMINI_PNR_TAG=video1p7 YESHENMINI_PNR_FRESH=1 YESHENMINI_SYNTH_MODE=speed`，
  seed 0，**1h02m43s**。
- 时序：**All Constraints Met**；npu_clk 18.4 ns → 18.316 ns（**+0.084**，54.60 MHz）、
  cpu_clk +0.507、soc_clk +0.733。
- 比特流：`sim/reglogs/pds_video1p7_p10.000/prj_tasks/pnr_1/generate_bitstream/yeshen_mini_board_top.sbit`
  （9,188,552 B，md5 `773e59e2edf53b371476b6eca76923e6`）。
- 资源 vs `video1p5`（P5 基线）：LUT 80,659.5 → **81,557（+897，51%→52%）**；FF 110,631 → 112,919
  （+2,288）；APM 271、DRM 273、Distributed RAM 8,079 **不变**。
- DDR 控制器（`ips_ddrc_top`，Pango 加密 IP，`third_party/ddr3_ip_200h/.../rtl/mcdq_ctrl/*.vp`）
  **AR 队列深度不可读** ⇒ “IP 是否吃得下 8 笔”只能由上板 A/B 直接判。
- 上板 A/B：见下节（**零收益，已回退**）。

## 上板 A/B（2026-10-22，tag `video1p7`）——零收益 ⇒ 回退

- 烧写：done bit=1；启动 marker **8/8**（SD/SDR、OpenSBI、Linux、LiteEth、dropbear、用户态、登录提示符）；
  ping/ssh PASS。
- 视频活性：`VIDEO.STATUS` 5 s 内 seq 3470→3550（**16 fps**）、`init_done=1` ⇒ 相机/屏未被 NPU 饿死。

| 档 | `y1run --frames 2` RUN（ns） | 均值 | CRC |
|---|---:|---:|---|
| P5 基线（桥 4 在飞 / BN=4） | 2,074,548,660 / 2,074,386,530 | 2,074,467,595 | 12/12 ×2 |
| **`video1p7`（桥 8 在飞 / BN=8）** | 2,074,289,030 / 2,074,547,430 | 2,074,418,230 | 12/12 ×2 |
| Δ | −259,630 / +160,900 | **−49,365（−0.002%）** | — |

- **判据（事先约定 ≥5% 才保留）不达标**，差值在噪声内（±0.013%）。
- 归因：单元仿真里同 LAT 下 8 在飞 = 2×（§RDEPTH=8）；板级为 0 ⇒ **桥的读在飞档位不是限制项**，
  实际在飞被**下游**（仲裁器 → DDR IP 的 AR 接收）压在 ≤4。注：IP 加密、桥的 `dbgMaxOutR` 未接 CSR，
  该上限**未直接测量**，是由“仿真 2× vs 板级 0”反推。
- **回退（净值结算）**：`src/soc/DDR3Bridge.scala`/`rtl/DDR3Bridge.v` 恢复读侧 `DEPTH=4`，
  `board/cam/ddr_arbiter_2to1.v`/`board/yeshen_mini_board_top.v` 恢复 `BN=4`，`run_video_gates.sh`
  撤掉 U1c（它只对 BN=8 布局有意义）。保留 `DdrBridgeReadPerfTb.v` 与本报告作研究记录。
  回退后：桥单元闸门 **TEST PASSED ×2（100/125 MHz）**、视频闸门全 PASS。
- **下一步**：不再加在飞；转“**减少冷页缺失**”（行向/通道分块布局，把 4 次 32 B 散读并成同页 128 B）。
