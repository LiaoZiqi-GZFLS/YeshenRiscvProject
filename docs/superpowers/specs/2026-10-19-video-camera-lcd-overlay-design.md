# 摄像头直通 + 屏幕叠加 Yunet 检测框 —— 设计（VexiiYeshenLinux）

- 日期：2026-10-19
- 状态：设计待用户审阅
- 关联：`docs/superpowers/specs/2026-10-18-y1-cpu-soc-clock-split-design.md`、
  `cam2lcd_200mini/DELIVERY_REPORT.md`（只读参考工程）

## 1. 目标与非目标

**目标**
1. 双目相机的 **CAM0** 一路 1280×720 实时直通到 7 寸 1024×600 LCD（1:1 裁切，不缩放）。
2. 从相机画面**中央截取 640×640**，送 CPU 预处理 + 现有 Y1 NPU 做 YuNet 人脸检测。
3. 检测框由 **FPGA 在扫描路径上叠加**到屏幕画面上（CPU 只提供坐标）。
4. 现有功能不回退：Linux 启动 marker、CoreMark 5500（4.59 CM/MHz）、y1run 12/12。

**非目标（本期不做）**
- 第二路相机（CAM1）的采集/显示。
- 检测性能优化（当前 NPU 4.5 s/帧，接受秒级框更新）。
- 视频录制、V4L2 驱动、H.264、缩放显示。
- 俯仰/镜像/去畸变等图像处理。

## 2. 用户已确认的决策

| 项 | 决定 |
|---|---|
| 屏幕显示 | 厂家 1:1 裁切方式（1024×600 窗口，不缩放） |
| 检测节拍 | 先打通，接受 4–5 秒/次框更新 |
| 相机/接线 | 已接好，用 CAM0（J10） |
| DDR 接入 | 方案 A：DDR IP 256-bit 简化口前 2:1 仲裁 |

## 3. 现有资产与关键事实

- **参考工程 `cam2lcd_200mini`（只读，零改动）** 已上板验收：OV5640 CAM0 1280×720 RGB565
  → `camera`（SCCB 初始化表）→ `cmos_8_16bit` → 写侧裁列 → `wr_fram_buf`（双 bank）
  → DDR3 → `rd_fram_buf` → `sync_vg` 1024×600@51.923 MHz → LCD（J26）。11 条根因见其
  `DELIVERY_REPORT.md` §4（整流级、DUTYx==RATIOx、负边沿采样、短行回滚、消隐判帧尾等），
  复制时**逐条保留**。
- DDR：2×QN3B256M16H（32 bit，1 GB）；IP 用户口 256-bit、地址为 **32-bit 字地址**（28 bit）。
- 本 SoC 地址：内核 RAM `0x8040_0000..0x9000_0000`（DDR 偏移 4..256 MB）；
  NPU arena 28 MiB；寄存器窗 `0xF000_xxxx`；`0x7400–0x77FF` 空闲（`0x5000`/`0x7000` 是
  既有未译码洞探针，必须避开）。
- `DDR3Bridge` 的 DDR 侧：每笔 `AwLen=ArLen=0`（单 256-bit 拍），AR/ AW ID 固定 0，
  **不检查 RID、不接 WUSERO**；R 数据经 CDC FIFO 无条件入桥。
- 厂家视频侧：AW/AR 带 ID、W 无 B 通道、`axi_wusero_last` 反馈写完成、`axi_rid` 回读
  （`rd_ctrl` 不校验 RID）。
- 帧缓存地址算术（厂家 IP）：一行 1024 px × 2 B = 2048 B = **512 个 32-bit 字**
  （`DDR_ADDR_OFFSET`=512 字/行）；双 bank。

## 4. 系统架构

```
OV5640 CAM0 (J10, 1280×720 RGB565, DVP 8bit, SCCB 初始化)
  │ camera.v（厂家 248 条表；等 ddr_init_done）
  ▼
cmos_8_16bit（8→16 拼对、每行重锚、negdege 采样；厂家修 ⑧）
  │ cam_pixel_clk = camera_clk/2
  ▼
写侧中心裁列 128..1151（1024 列）× 全 720 行
  ▼
wr_fram_buf ──(256-bit 简化 AXI)──┐
                                  │
rd_fram_buf ──(256-bit 简化 AXI)──┤
   ▲                              ▼
   │                     DDR 2:1 仲裁器（core_clk 125M）
   │                              │
   │                              ▼
   │                        ddr3_test（1 GB）
   │
sync_vg 1024×600@51.923MHz（行偏移 60）→ RGB565→888 → 叠加引擎 → LCD（J26）

CPU（Linux, cpu_clk 108M）── 轮询 VIDEO CSR（帧计数/bank）
  ├── 快照中央 640×640 → 预处理 int8 → NPU arena → 启动 Y1 NPU（npu_clk 56.25M）
  └── 读 12 路输出 → YuNet 解码 + NMS → 写 BOX 寄存器
```

**时钟域**：`camera_clk_0`（输入）→ `cam_pixel_clk`（÷2）；`core_clk` 125 MHz（DDR IP 输出，
视频帧存与仲裁器）；`lcd_pclk` 51.923 MHz（新 PLL）；`soc_clk` 100 MHz（CSR/glue）；
`cpu_clk` 108 MHz；`npu_clk` 56.25 MHz。全部异步组已在 FDC 声明（新增 lcd_pclk /
camera_clk 两组）。

**复位**：相机路径复位 = `ddr_init_done`（厂家要求，防止 PHY 未就绪时写链被常量折叠）；
显示/叠加复位 = `soc_resetn` + `ddr_init_done`；CSR 复位 = `soc_rst`。

## 5. 视频采集与显示

### 5.1 复制清单（参考仓库零改动）
- `rtl/camera/{camera.v,camera_data.v}`（SCCB 初始化 + 720p 表）
- `rtl/tutorial/{cmos_8_16bit.v,fram_buf.v,wr_buf.v,rd_buf.v,wr_ctrl.v,rd_ctrl.v,wr_cmd_trans.v,wr_rd_ctrl_top.v}`
- `ip/wr_fram_buf/{wr_fram_buf.v,rtl/*}`、`ip/rd_fram_buf/{rd_fram_buf.v,rtl/*}`
- `rtl/sync_vg.v`（1024×600 时序；H_SYNC=20/V_SYNC=3 等厂家参数）
- `rtl/pll_80m.v` → 复制为 `board/pll_lcd.v`：VCO = 27×2×25 = 1350 MHz，
  `RATIO0=26/DUTY0=26` → **51.923 MHz**（DUTYx==RATIOx 铁约定），输出经 `GTP_CLKBUFG`。

### 5.2 定点改动（只在副本上做，逐条写注释）
1. **写侧中心裁列**：在 `cmos_8_16bit` 输出的 16-bit 像素域按列计数（`col_cnt`，每行
   空白期清零）：`cam_de1024 = cam_de && (col_cnt >= 128) && (col_cnt < 1152)`，
   替代厂家 `col_cnt < 1024`。行全部写入（`V_NUM=720`）。
2. **读侧行偏移**：`rd_buf` 新增 `ROW_OFFSET=60`；帧复位时
   `wr_cnt <= ROW_OFFSET * DDR_ADDR_OFFSET`，读 600 行 → 显示相机第 60..659 行。
3. **帧存地址**：帧存直接接 DDR IP（**字地址域**，单位 = 32-bit 字）。
   取 DDR 字节偏移 `0x1000_0000`（内核 RAM 之上）⇒
   `ADDR_OFFSET = 0x1000_0000 >> 2 = 0x0400_0000` 字（28-bit 可表示）。
   CPU 侧经 `0x8000_0000` 别名访问同一区域 = **物理 `0x9000_0000`**。
4. **双 bank 容量与跨度**：一行 = 1024 px × 2 B = 2048 B = 512 字；一个 bank 的**帧数据**
   = 720 行 × 512 字 = 368,640 字（0x168000 B）。但厂家 `wr_buf/rd_buf` 的 bank 位是
   **字地址 bit22**（`{frame_cnt[0], rd_cnt}`，`LINE_ADDR_WIDTH=22`）⇒ **bank 间距 = 2^22 字
   = 16 MiB**，不是 0x168000。bank0 = `0x9000_0000`，bank1 = `0x9100_0000`；
   CPU 侧需映射 `0x9000_0000..0x9200_0000`（32 MiB）才能覆盖两个 bank。
   快照缓冲放 `0x9040_0000`（bank0 内未用的 4 MiB 处），与帧数据不冲突。
5. **FPGA 帧状态输出**：`fram_buf` 内的写侧帧计数 `wr_frame_cnt_bus`（bank = bit0；
   读侧读的是 `~wr_frame_cnt_bus[0]`，见厂家修 ④）引出到视频 CSR。

### 5.3 引脚（全部来自官方 fdc，已核对与现有 103 脚无冲突）
- 相机：`camera_clk_0` L22、`camera_data_0[7:0]` M24/R22/K26/K25/M25/N19/T24/R21、
  `camera_href_0` T25、`camera_vsync_0` L23、`SCL_0` P19、`SDA_0` R20、`cam_rst_0` T22。
- LCD：`lcd_r/g/b[7:0]`、`lcd_de` AC23、`lcd_hs` AD26、`lcd_vs` AD25、`lcd_pclk` AC19、
  `lcd_pwm` AC22（常亮）。
- **唯一冲突**：厂家 `cam_led0=A20` 与现有 `led[0]`；本设计不接相机 LED，A20 保持 `led[0]`。
- 约束：新增 `create_clock camera_clk_0`、`create_generated_clock cam_pixel_clk`
  （camera_clk/2）、`create_clock lcd_pclk`（`u_pll_lcd/u_gpll/CLKOUT0`，19.259 ns），
  三组与现有全体时钟异步。

## 6. DDR 2:1 仲裁器（核心新逻辑）

**位置**：`ddr3_test` 用户口前；`{DDR3Bridge, 视频}` 二选一。`core_clk` 125 MHz。

**协议**：简化 AXI（无 B）、每侧 `AW/W/AR/R` 各一组；写侧 `axi_wusero_last` 作为写完成。

**仲裁规则**
- **写命令**（AW+W 成对）：仅当选中侧 `awvalid && wvalid` 时授予；一次授予覆盖
  `awlen+1` 拍 W（桥侧恒 1 拍，视频侧最多 16 拍）；期间 `wusero_last` 只回送给当前侧。
- **读命令**（AR）：空闲时授予一侧，等其 `arlen+1` 拍 R 返回（按 RID 路由）后释放。
  写通道与读通道相互独立，可以同时在 IP 上重叠（IP 本身有独立通道）。
- **ID**：桥侧固定 0；视频侧 AR ID 固定 **1**。R 数据按 `axi_rid` 分流：
  `rid==1` → 视频，其余 → DDR3Bridge（桥忽略 RID，因此必须由仲裁器隔离）。
- **优先级**：IP 的读/写通道相互独立，仲裁器只做**同通道二选一**（读：视频 vs 桥；
  写：视频 vs 桥），按轮转避免单侧饿死。跨通道的 IP 内部调度不在本模块控制范围内；
  显示侧靠厂家 rd_buf 的行缓冲吸收突发（厂家已实测 15.7 fps 采集 + 60.8 fps 显示）。
- **带宽账**：显示读 74.7 MB/s（1024×600×2×60.8）、相机写 29.5 MB/s（1280×720×2×15.7）、
  NPU/CPU 峰值 < 100 MB/s；DDR 理论 4 GB/s（256 bit×125 MHz），余量充足。

**遥测**：`aw_stall_cycles`、`ar_stall_cycles`、每侧 burst 计数、读 FIFO 欠载计数
（引出到视频 CSR；欠载 >0 即判显示异常）。

**负对照**：仲裁器 TB 里故意让写侧持续占线（读优先失效），确认欠载计数会涨；恢复后归零。

## 7. 寄存器与地址台账

新增胶合窗 **`VIDEO_BASE = 0xF000_7400`**（1 KiB，`VIDEO_MASK = 0xFFFF_FC00`；
`AxiLite4` 从口；下游接
`board/video_regs.v`）。台账五处按既有流程同步：
`scripts/check_addr_map.py`、`src/YeshenSocGlue.scala`（常量/解码/下游端口）、
`board/yeshen_mini_soc.v`、`docs` 台账、glue 单测。

| 偏移 | 名称 | 读写 | 内容 |
|---:|---|---|---|
| 0x000 | STATUS | RO | [0] init_done；[1] 当前写 bank；[31:8] 24-bit 帧序号（帧完成时 +1） |
| 0x004 | IRQ/欠载 | RO | [0] 帧完成 sticky；[15:8] 显示欠载计数；[31:16] 仲裁写饥饿计数 |
| 0x008 | OVERLAY_CTRL | RW | [0] 使能；[1] 提交（写 1 切到后备 bank）；[15:8] box 数量（0..16） |
| 0x010..0x08F | BOX[16] | RW | 每 box 8 B：x1,y1, x2,y2（各 16-bit，屏幕坐标，小端） |
| 0x090 | VERSION | RO | 0x0001_0001 |

- 双 bank box 表（2×128 B BRAM）：CPU 写后备 bank，写 `OVERLAY_CTRL.commit=1` 后由
  下一个 `lcd_vs` 上升沿切换，避免撕裂。
- 所有跨域：`frame_seq/bank` 用 toggle 握手从 core_clk 到 soc_clk；`OVERLAY_CTRL` 用
  2FF + vsync 切换；box BRAM 双时钟（写 soc_clk / 读 lcd_pclk）。

## 8. 叠加引擎

- 插入点：`rd_fram_buf` 输出的 RGB565 之后、`565→888` 之前；在 `lcd_pclk` 域。
- 坐标：`screen_x = crop_x + 192`，`screen_y = crop_y − 20`（推导：相机裁剪 +320/+40，
  显示窗口 −128/−60）；`screen` 范围 `x∈[0,1024), y∈[0,600)`，越界裁剪。
- 画法：对 16 个 box 做边框比较（每 box 4 条边、厚度 2 px），命中输出绿色
  `RGB565=0x07E0`；不为内部填色。
- 资源：16 个 box × 4 个 16-bit 比较 → 打一拍流水；box 表从 BRAM 读，扫描期间地址
  由 `lcd_hs/vs` 重建。
- 未使能时旁路（bypass 多路器用 `OVERLAY_CTRL[0]`）。

## 9. 软件检测循环（板内 Linux 用户态 C）

**程序**：`y1/tools/y1cam.c`（新增；不修改 `y1run.c`）。

**循环（每轮 ~4.5 s）**
1. 读 `VIDEO_STATUS` 帧序号；等到序号变化；取 `bank = ~STATUS[1]`（当前未被写的 bank）。
2. **快照**：从 `0x9000_0000 + bank*0x0100_0000` 读相机第 40..679 行、第 320..959 列
   （即帧存内列 192..831、行 40..679）→ 800 KB RGB565 到 `0x9040_0000`；
   拷贝期间写者在另一 bank，稳定窗口约 63 ms，实测拷贝 <30 ms。
3. **预处理**（与主机同口径，逐字节对账）：
   RGB565→RGB888 → NHWC → NPU 的 ci-block-planar int8（含 `y1_convert.py` 的量化和
   `derive_layout` 的布局块），写入 NPU arena 的**固定 input 地址**（复用 payload 的 desc/权重）。
4. **启动 NPU**：按 payload 的邮箱记录重新编程（地址不变、input 地址固定），写 CTRL.start，
   等 PLIC IRQ（源 3）或轮询 done。
5. **后处理**：读 12 路输出，移植 `y1_npu_postprocess.py` 的 YuNet 解码（strides 8/16/32、
   priors、cls/obj/bbox/kps）+ NMS → 保留 score ≥ 阈值的前 16 个框。
6. **写框**：坐标映射到屏幕（§8），越界裁剪；写 BOX 后备 bank → `commit`。
7. 记录耗时（采集等待/快照/预处理/NPU/后处理）到串口；下一轮。

**判据**
- 预处理正确性：同一快照分别走板内 C 与主机 Python，int8 输入数组 **CRC32 逐字节相等**。
- 后处理正确性：同一输出张量分别走 C 与 Python，框数/IoU/置信度一致（IoU≥0.99）。
- 端到端：屏幕框与主机 golden 框位置一致（允许 1 px 取整）。

## 10. 复位、时钟域与 CDC

| 跨越 | 机制 |
|---|---|
| camera_clk → core_clk | 厂家 wr_buf 的双口 RAM + 指针（已验证） |
| core_clk → lcd_pclk | 厂家 rd_buf 双口 RAM；帧同步 `rd_fsync` |
| core_clk → soc_clk（帧序号/bank/欠载计数） | toggle 握手 + 快照寄存器 |
| soc_clk → lcd_pclk（overlay ctrl/box） | box BRAM 双时钟；ctrl 2FF + vsync 切换 |
| soc_clk → core_clk（无） | 不需要 |

## 11. 验证计划

**单元（仿真）**
- U1 `tb_ddr_arbiter.v`：桥/视频并发随机流量，逐拍比对两侧读数据与写数据（DDR 模型）；
  写侧长 burst、读优先/饥饿让位、RID 分流；负对照：去掉 RID 分流 → 桥收到视频数据（必红）。
- U2 `tb_video_path.v`：测试图（彩条+移动块）→ 写侧裁列/行偏移 → framebuf → 读回，
  逐像素比对裁切窗口；负对照：行偏移=0 → 图错位（必红）。
- U3 `tb_overlay.v`：box 坐标边界（0,0/1023,599/越界/厚度 2px/多框重叠）、使能旁路；
  负对照：坐标 +1 → 命中区移动（必红）。
- U4 `tb_video_regs.v`：CSR 读写、双 bank commit 只在 vsync 生效、跨域稳定性。

**集成（PDS）**
- dev_map：无 ERROR；LUT/FF/DRM 增量记录（判据：LUT < 80%、DRM < 80%）。
- PnR：全部时钟 MET（cpu 108、soc 100、npu 54.35、lcd 51.923、camera、core 125）。
- 回归：Linux 8 marker、CoreMark 5500 4.59 CM/MHz（±0.5%）、y1run 12/12。

**上板**
- V1 直通：屏幕连续画面，帧计数 15 Hz 递增，欠载=0；拔相机 → 无画面（负对照）；
  跑 CoreMark/Linux 与显示并发，显示不花屏。
- V2 静止帧检测：同一快照的 int8 CRC 与主机相等；框与 golden 一致；无人脸画面 → 0 框。
- V3 连续循环：10 分钟长跑，帧序号/检测轮数单调；人脸移动时框秒级跟随；无挂死。

## 12. 风险与对策

| 风险 | 对策 |
|---|---|
| 仲裁器破坏 CPU/NPU 读数据（RID 路由错） | U1 负对照 + 板上 CoreMark/y1run 回归；RID 分流做断言 |
| 显示欠载/撕裂 | 读优先 + 欠载计数；双 bank + 快照；负对照饿死显示 |
| 相机 SCCB 初始化受 DDR init 影响 | 沿用厂家 `ddr_init_done` 门控；V1 先单独验证相机 |
| 帧缓存地址/字地址单位错 | 单独 TB 比对 1024×720 每行地址步进 = 512 字 |
| 预处理量化与主机不一致 | 同快照逐字节 CRC 对账（唯一权威） |
| 资源/时序超限 | 先 dev_map 判据再 PnR；相机/LCD 域独立异步 |
| 帧缓存与内核内存冲突 | 帧存放在内核 window 之上（0x9000_0000），不加入 DTS memory |

## 13. 分阶段交付（供实现计划展开）

- **V1-a**：复制视频 RTL/IP + pll_lcd + 引脚/时钟约束；U2/U3/U4 闸门。
- **V1-b**：DDR 2:1 仲裁器 + U1 闸门；并入 board top/soc；glue 加 VIDEO 窗 + 台账。
- **V1-c**：dev_map + PnR + 上板直通验收（V1 判据）。
- **V2-a**：`y1cam` 快照 + 预处理；int8 CRC 对账（板内 C vs 主机 Python）。
- **V2-b**：NPU 启动 + 后处理移植；框对账；叠加落屏。
- **V3**：连续循环 + 长跑 + 回归收口 + 报告。

## 14. 实施记录（V1，2026-10-19）

**资产复制**：厂家视频 RTL/IP 复制到 `board/cam/vendor/`，`board/cam/vendor/.gitattributes`
置 `* -text` 保证入库 blob 与来源逐字节一致（40 个文件；`SHA256SUMS` 全对；参考仓库
`cam2lcd_200mini` 复制前后 sha256 全量 diff 为空）。唯一改动：`rd_buf.v` 增加 `ROW_OFFSET`，
`fram_buf.v` 透传。

**实现偏差（相对本 spec 初稿，均已验证）**
1. 厂家简化 AXI 的地址单位是 **32-bit 字**，每个 256-bit beat 地址 **+8**（16-beat burst 跨
   128 字）。行为模型 `sim/video/ddr_model.v` 按此建模；仲裁器只搬命令/数据，不做地址推进。
2. 写侧裁列/行偏移在包装层实现；`fram_buf` 无 `ADDR_OFFSET` 端口，帧存基址
   `0x0400_0000`（字）在组装层 AXI 边界相加（CPU 物理 `0x9000_0000`）。
3. `lcd_clk` PLL：厂家 `pll_80m` 的 VCO=1350 MHz **超出 GTP_GPLL 上限 1200 MHz**（dev_map
   DRC-2064）。改为 **VCO=1012.5 MHz（27×2×18.75）/ RATIO0=19.5 / DUTY0=19**，仍精确
   51.9230769 MHz（RATIO0 在 1/8 网格上）⇒ DRC 清零。
4. FDC 的 `cam_pixel_clk` 引脚路径：`cmos_8_16bit` 在 generate 作用域内，实际路径是
   `u_video/g_camera.u_cmos16/pixel_clk`（不是 `u_video/u_cmos16/...`）。
5. DDR3Bridge 简化写口**没有 WVALID**（IP 侧也无该端口）；仲裁器桥侧 `b_wvalid` 接桥的
   `awvalid` 作为"数据已到"的等价指示。
6. VIDEO 窗最终地址 **`0xF000_7400`（1 KiB，掩码 `0xFFFF_FC00`）**：`0x5000`/`0x7000`
   是既有"未译码洞"探针，必须避开。

**单元闸门（全绿）**
- U1 `tb_ddr_arbiter`：桥/视频写读、RID 分流、多拍写、wlast 路由；负对照（去掉 RID 分流）
  必红。`DDR_ARB: PASS`。
- U2 `tb_video_path`：2,368,008 像素逐像素比对；`ROW_OFFSET=0` 红（2,368,008 mismatch），
  `ROW_OFFSET=60` 绿；叠加接入后仍 PASS。
- U3 `tb_overlay`：边框命中/内部/外部/旁路/双 bank 切换；2px→3px 变异必红。
- U4 `tb_video_regs`：CTRL/BOX/VERSION 读写、帧事件 seq、commit 单拍；`VIDEO_REGS: PASS`。
- 汇总 `sim/video/run_video_gates.sh` → `VIDEO_GATES: ALL PASS`。

**胶合**：VIDEO 窗加入 `src/YeshenSocGlue.scala` 并重生成；胶合四套单测（pbus/npu/dma/
memmerge）全 PASS；台账 `check_addr_map.py` PASS（18 sites）；`videoAxi` 端口 32-bit、
窗内偏移低 10 位；0x5000/0x7000 仍 DECERR 且 `videoAxi_*valid=0`。

**dev_map（tag `devmap`）**：0 error / 0 DRC；LUT 78,947（50%）、FF 110,097（35%）、
DRM 263.5（64%）、APM 263（36%）、IO 142（36%）。相对 clock-split 基线：LUT +2,727、
DRM +8。

**软件（Task 9/10）**
- `y1_common.h` 抽取后 y1run 上板 `12/12`（4.508 s，输出行为不变）。
- `y1cam` 快照/预处理：C 与 Python 同口径 CRC 相等（`bc927663`），B/R 对调负对照变红。
- `gen_deq_header.py` → `y1_deq.h`：12 路反量化 `x=(q−zp)·scale`（cls/obj 为 Q0.7）。
- C 版 YuNet 解码+NMS：与 `yunet_post.postprocess` 对账 `PASS dets=1 iou=1.000000`；
  shift/conf 两个负对照均发火；bbox/kps 按**通道平面** `p+c·N` 去折叠。
- 板级 V2（快照 CRC、NPU 12/12、框叠加）待 `video1` 比特流上板。

### 14.1 相机点亮与显示错位根因（2026-10-19）

**相机链路（已证通）**
- 屏幕上能看到 OV5640 彩条（`0x503D=0x80`）⇒ SCCB、DVP、cmos 整流、帧存写读、
  LCD 时序全链路有效；"全暗/单 bit"是曝光与相机复位相位问题的表象。
- 相机复位必须带**上电脉冲**：`cam_rstn = rst_board_n & pll_lock_lcd`（`e006c21`）。
  厂家 `camera.v` 的 PWDN→RESET→21ms→SCCB 序列依赖 rst 的这次释放沿。

**显示"错位分块+闪烁移动"根因（仲裁器 `wusero_last` 归属）**
- 判据：把厂家交付的纯视频比特流 `cam2lcd_200mini/deliver_fix31`（md5
  `de2cb43d…`，无 CPU、无仲裁器）烧到同一块板 → 画面**稳定** ⇒ 摄像头/LCD/DDR/
  接线全部无罪，问题在集成层。
- 厂家 `wr_ctrl`：`cmd_cnt` 只在 `wlast && wvalid && wready` **同拍**递减，而
  `axi_wvalid = axi_wready`（`wr_ctrl.v:130/180/182`）⇒ IP 的 `axi_wusero_last`
  与最后一拍 W **同拍**。
- 旧仲裁器用"最后一拍时锁存的 `last_sel`"回送 wlast；同拍时该寄存器还是**上一笔**
  写的属主。每当桥写后紧接一笔视频写，这笔视频写的 `wlast` 被错送到桥侧 ⇒
  厂家 `wr_cmd_trans` 的 `wr_cnt/wr_addr/wr_len` 少推进一步 ⇒ 行内 4 个 16-beat
  突发记账错位 ⇒ 屏幕上成块错位；错位随 CPU/网络流量（桥写插入时机）变化 ⇒ 闪烁移动。
- 修复：`wowner = (wst==W_DATA) ? wsel : last_sel`（同拍用当拍属主，晚一拍用兜底），
  并把桥侧 `m_wvalid` 改为 `b_wvalid` 组合直通（桥写 FIFO 空拍不送脏数据、不丢拍）。
- 证据：先改仿真模型为同拍语义 → U1 红（`b_wl=2, v_wl=0`）；修 RTL 后 U1 绿；
  另加"桥 W 空拍 burst"用例（逐拍数据+wlast 计数）锁死。
- 重建：`video1fix1`（100MHz CPU、彩条仍开启）→ 上板先验"静态彩条稳定"，
  再关彩条验实时画面与 NPU 框。
