# 双目相机切换（CAM0/CAM1）—— 设计（VexiiYeshenLinux）

- 日期：2026-10-27
- 状态：设计已与用户确认，待审阅 spec
- 关联：`docs/superpowers/specs/2026-10-19-video-camera-lcd-overlay-design.md`（该 spec 把"第二路相机（CAM1）"列为非目标，本 spec 补上）、
  只读参考工程 `cam2lcd_200mini`（`rtl/cam2lcd2_top.v` + `docs/cam2lcd-dual-camera-switch.md`，交付 sbit `5e40c231f903dd875e221f18349141fc`，已在同一块板上验证过）

## 1. 目标与非目标

**目标**
1. J10 双目模组的 **CAM1** 接入：14 个引脚（PCLK/DATA[7:0]/HREF/VSYNC/SCL/SDA/RST）全部接上，独立 SCCB 初始化、独立复位。
2. **KEY2（B22）按键 + `VIDEO` 窗寄存器 `CAM_CTRL[0]` 同源控制**：按键翻转、软件可写可读，两者操作同一个位。
3. 切换后画面在**整帧边界**重启，屏幕经**事件驱动黑屏**过渡（不是定时黑屏），DDR 帧存**不落撕裂帧**。
4. 上电默认 CAM0 ⇒ 不按键时与现交付**逐位同行为**（Cam known-good `5df46d6b` 的视觉表现不变）。

**非目标**
- 角标/OSD 相机标识（用户明确不要）。
- 重定义任何板载 LED（8 根全有既定语义，见 §6.4）。
- 双目同时采集、双目立体配准、缩放/降噪、录制。
- 修改 vendor `camera.v` / `cmos_8_16bit` 的对外行为（零改动，只多例化一份）。

## 2. 用户已确认的决策

| # | 决策 | 说明 |
|---|---|---|
| D1 | **走方案 A**（双路常开 + 无毛刺时钟 mux） | 与已验证的参考工程同构；面积代价以 dev_map 实测为准 |
| D2 | **0.5 s 级别黑屏过渡，不画角标** | 用户选择"黑屏但画面干净" |
| D3 | **按键 + 寄存器同源** | 一个 `cam_sel` 位：KEY2 翻转它，软件也能读写它 |
| D4 | **黑屏由定时改事件驱动 + 掐写侧** | 用户确认"按推荐的补齐功能" |
| D5 | 交付到**上板验收** | RTL → dev_map → PnR → 比特流 → 上板（上板时机由用户给窗口） |
| D6 | 指示走**软件读回**，不占硬件 LED | E18 在本工程是 `led[3]`=Linux 心跳；牺牲诊断灯不划算 |

## 3. 现状（代码事实，全部已核对）

### 3.1 目标工程 `VexiiYeshenLinux`

| 事实 | 证据 |
|---|---|
| 只有 CAM0：`camera_{clk,data,href,vsync}_0` + `SCL_0/SDA_0/cam_rst_0` | `board/yeshen_mini_board_top.v:146-149`、`board/cam/video_passthrough.v:33-40` |
| 采集链 = `camera.v → 负边沿采样 → cmos_8_16bit → 裁列 128..1151 → fram_buf` | `board/cam/video_passthrough.v:131-183`、`:96-104`（裁列）、`:284-331`（fram_buf） |
| `cmos_8_16bit.pclk` 直接接 `camera_clk_0`（没有 mux） | `board/cam/video_passthrough.v:174-183` |
| 裁列：`cam_de_crop = cam_de && 128 ≤ col < 1152` | `board/cam/video_passthrough.v:102-111` |
| 帧同步 `frame_sof` 由"de 包络持续低 ~1.16 ms"生成（与相机相位自对齐） | `board/cam/video_passthrough.v:190-219` |
| 双 bank：`wr_bank = frame_cnt[0]`，`frame_toggle` 每帧翻转（ddr_clk 域） | `board/cam/video_passthrough.v:374-394` |
| 输出级：`de_r <= de_o`，RGB 由 `pix_ovl` 打一拍 | `board/cam/video_passthrough.v:425-448` |
| `cam_init_done`（CAM0）→ `STATUS[0]`，y1cam 首轮前最多等 5 s | `board/cam/video_passthrough.v:225`、`y1/tools/y1cam.c:72-73,151-152,844-852` |
| `VIDEO` 窗寄存器：`0x000 STATUS / 0x004 DBG / 0x008 OVERLAY_CTRL / 0x010..0x08F BOX / 0x090 VERSION`；**`0x00C` 空闲** | `board/cam/video_regs.v:1-30` |
| `sys_clk`(video) = `clk_in` = **27 MHz**；`video_regs` = `soc_clk` = **100 MHz**；`lcd_clk` = **51.923 MHz** | `board/yeshen_mini_board_top.v:105,184,774,798`；`constraints/yeshen_mini.fdc:201-216` |
| LED 全占用：`led[0]`PLL / `led[1]`DDR / `led[2]`装载 / `led[3]`=**E18=Linux 心跳** / `led[4]`y1cam / `led[5]`NPU / `led[6]`网口 / `led[7]`eth | `board/yeshen_mini_board_top.v:1043-1055`；`constraints/yeshen_mini.fdc:883-922` |

### 3.2 引脚空闲性（已逐球 grep 确认占用数 = 0）

- CAM1 十四个球：`M21 / M22 / R23 / T23 / AB24 / P26 / M26 / AA24 / AB25 / U26 / U25 / AC24 / AC26 / Y25` —— `constraints/yeshen_mini.fdc` 中均未出现。
- `KEY2 = B22` —— 同样未出现（现有只有 `rst_board_n=C22`、`key1=C23`）。

### 3.3 参考工程做法（`cam2lcd_200mini`）

| 机制 | 位置 | 结论 |
|---|---|---|
| 两套 `camera.v`，各自 SCCB/复位 | `rtl/cam2lcd2_top.v:119-160` | 照搬 |
| `sel_cam` 在各自 PCLK 域 2FF，**下降沿**更新门控；`cam_clk_mux = (clk0&en0)｜(clk1&en1)` | `:268-278` | 照搬（无毛刺时钟的关键） |
| `cmos_rst_n = 所选 init_done & ~sw_rst`；释放后等新相机首个 VS | `:280-290`、`:325` | 照搬（**真正"对齐摄像头信号"的部分**） |
| **`pblank` 是纯计时器**（上电 40M、切换 13.5M @27 MHz），只在输出级拉黑，与 VSYNC/init_done/bank 无任何握手 | `:295-312`、`:768` | **不照搬**（改事件驱动，见 §5.3） |
| KEY2：2FF + 19 ms 电平消抖 + `k2_fired` 单次触发；边沿计数写法会永不触发 | `:245-264` | 照搬算法，时钟改为 soc_clk |
| 写侧不掐断（黑屏只在面板侧，DDR 照写） | 全文件 | **不照搬**（我们有 y1cam/NPU 并行取帧，见 §5.2） |

## 4. 架构

```
 J10 cam0 ─► camera_inst0 ─► SCL_0/SDA_0/cam_rst_0   init_done_0 ┐
 J10 cam1 ─► camera_inst1 ─► SCL_1/SDA_1/cam_rst_1   init_done_1 ┤
                        │ 各自 PCLK 负边沿采样（原样保留）        │
   cam_sel ─► 2FF@clk0 / 2FF@clk1 ─► 下降沿门控 en0/en1           │
             cam_clk_mux = (clk0 & en0) | (clk1 & en1) ◄──────────┘
                        │
             cmos_8_16bit（rst_n = 所选 init_done & ~sw_rst）
                        │ 裁列 128..1151
             写侧门 wr_en/wr_fsync（切换期关断）
                        │
             fram_buf 双 bank ─► overlay ─► 输出级（事件驱动黑屏）─► LCD
```

### 4.1 文件与改动点

| 文件 | 改动 |
|---|---|
| `board/cam/cam_switch.v`（**新**） | 只做"两路 PCLK 域 2FF + 下降沿门控 + 时钟 mux + 数据/href/vsync mux + `sw_rst` + 所选 `init_done`"。无 fram_buf/显示逻辑 ⇒ 可独立跑 TB |
| `board/cam/video_passthrough.v` | 新增 cam1 端口；例化第二份 `camera.v`；用 `cam_switch` 的输出替换 `camera_clk_0`/`cam_d_sel` 等；写侧门 `sw_pending` FSM；事件驱动黑屏 FSM；输出 `cam_sel_o/cam_rdy_o/switch_busy_o` |
| `board/cam/video_regs.v` | 新增 `0x00C CAM_CTRL`；新增输入 `cam_sel_toggle`、`cam_rdy`、`switch_busy`；输出 `cam_sel` |
| `board/cam/key_toggle.v`（**新**） | KEY2 2FF + 19 ms 电平消抖 + 单次脉冲（soc_clk），输出 `toggle_pulse` |
| `board/yeshen_mini_board_top.v` | 新增 `key2` 与 cam1 的 7 组端口；例化 `key_toggle`；`cam_sel` 从 `u_video_regs` 连到 `u_video` |
| `constraints/yeshen_mini.fdc` | cam1 14 球 + `key2=B22` + `camera_clk_1` 根钟 + `cam_pixel_clk_1`（`-add`）+ 时钟组 |

vendor 目录 `board/cam/vendor/**` **零改动**。

## 5. 控制面与时序

### 5.1 `CAM_CTRL`（VIDEO 窗内偏移 `0x00C`）

| 位 | 属性 | 含义 |
|---|---|---|
| `[0]` | RW | `cam_sel`：0=CAM0（上电默认），1=CAM1。写入立即生效；按键翻转同一位 |
| `[1]` | RO | `ready`：所选相机 `init_done`（等价于旧 `STATUS[0]` 的语义，但跟随选择） |
| `[2]` | RO | `switch_busy`：切换/黑屏进行中（= `sw_pending` 经 2FF 到 soc_clk **或** `black`，两者同域后可组合） |
| `[31:3]` | RO | 0 |

- 读回整字 = `{29'b0, switch_busy, ready, cam_sel}`。
- `STATUS[0]`（旧口径）改为**所选相机**的 `init_done`，其余不变。
- 软件用法：`devmem 0xF000740C` 读；写 0/1 切相机。

### 5.2 KEY2 与消抖（`key_toggle.v`，soc_clk 100 MHz）

- `key2` 2FF 同步 → 低电平**持续计数** 1,900,000 拍（19 ms）→ 单次脉冲 `toggle_pulse`；松开（回高）清零、允许下一次。
- 只在 `toggle_pulse` 那拍翻转 `CAM_CTRL[0]`（与软件写同一寄存器，优先级：软件写 > 按键翻转）。
- **不采用**"只在变低那拍计数"的写法（参考工程踩过：计数器永远到不了阈值 ⇒ 按键完全无效）。

### 5.3 切换时序（一次切换的完整时间线）

| 段 | 机制 | 时限（标称） |
|---|---|---|
| T0 | `cam_sel` 变化（soc_clk） | 1 拍 |
| T1 | 2FF 到 `camera_clk_0/1`；各自**下降沿**更新 `en0/en1`；`cam_clk_mux` 换源 | ≤ 2 个 PCLK 周期 |
| T2 | `sw_rst` 拉高 | **1 ms**（soc_clk 100,000 拍） |
| T3 | `cmos_rst_n = 所选 init_done & ~sw_rst`；释放后 `cmos_8_16bit` 等**新相机首个 VS** 才出数据 | 相机自身时间 |
| T4 | **掐写侧**：`sw_pending` 置位 ⇒ `wr_en=0` 且 `wr_fsync=0`；新相机**首个 `frame_sof`** 清除 ⇒ 此后写入的都是整帧（DDR 无撕裂帧） | ~1 帧 |
| T5 | **黑屏**：`cam_sel` 变化立即拉黑；放行条件 = `所选 init_done` ∧ **切换后已写满 ≥2 帧**（ddr_clk 数 `frame_toggle` 边沿）∧ **`T_SETTLE=400 ms`** 计时到 | 典型 ~0.5 s |
| T6 | 放行当拍起 `de`/RGB 正常；`switch_busy` 清零 | — |

- 上电走同一条件（`T_SETTLE` 同样生效）：预计 **~0.7 s** 出画面（参考工程定时为 1.48 s）。
- `T_SETTLE` 存在的唯一理由是**新相机 AEC/AWB 收敛**（参考工程实测 0.3–1 s，属"只能靠时间、不能靠信号"的部分）；`T_SETTLE`、`≥2 帧` 都做成 localparam 便于上板调。
- 黑屏实现：输出级 `de_r <= de_o & ~black_l`，且 `black_l` 期间 `r/g/b` 强制 0（`black_l` 由 soc_clk 域 2FF 到 `lcd_clk`）。

### 5.4 写侧门（`sw_pending`，cam_pixel_clk 域）

```
sel 变化 ──► sw_pending = 1   （wr_en / wr_fsync 全关，DDR 不收半帧）
所选 init_done & !sw_rst & 首个 frame_sof ──► sw_pending = 0
```

- `fram_buf` 的 `wr_fsync`（`cam_fsync`）与 `wr_en`（`cam_de_crop`）**同门控**，避免"有 fsync 无数据"的空帧翻转 bank。
- 副作用（明示）：切换窗口内 y1cam 若正在等 `seq` 前进，会多等约 0.5–1 s（其每轮超时 5 s，安全）。

## 6. 引脚、时钟与约束

### 6.1 CAM1 引脚（J10；与 CAM0 同一连接器，参考工程已实测）

| 信号 | 球号 | 信号 | 球号 |
|---|---|---|---|
| `camera_clk_1` | M21 | `camera_data_1[7]` | AB25 |
| `camera_data_1[0]` | M22 | `camera_href_1` | U26 |
| `camera_data_1[1]` | R23 | `camera_vsync_1` | U25 |
| `camera_data_1[2]` | T23 | `SCL_1` | AC24 |
| `camera_data_1[3]` | AB24 | `SDA_1` | Y25 |
| `camera_data_1[4]` | P26 | `cam_rst_1` | AC26 |
| `camera_data_1[5]` | M26 | | |
| `camera_data_1[6]` | AA24 | | |

`KEY2 = B22`（INPUT / LVCMOS33 / `PAP_IO_NONE TRUE`，照抄 `key1` 四条属性）。

### 6.2 时钟约束

```
create_clock -name {camera_clk_1} [get_ports {camera_clk_1}] -period {10.000}
create_generated_clock -name {cam_pixel_clk_1} -source [get_ports {camera_clk_1}] \
  [get_pins {u_video/g_camera.u_cmos16/pixel_clk}] -master_clock [get_clocks {camera_clk_1}] \
  -multiply_by {1} -divide_by {2} -add
```

- 既有 `cam_pixel_clk`（source `camera_clk_0`）保持不变；两座派生钟落在同一 pin ⇒ PDS 会给 `SDC-2025` 提示（参考工程同样如此，**良性**，但要在 PnR 报告里确认时序仍 MET）。
- `camera_clk_0`、`camera_clk_1` 之间加 `set_clock_groups -asynchronous`；两者与 `lcd_clk`/`soc_clk`/`core_clk` 的关系沿用既有异步组（只新增 clk1 的成员身份）。

### 6.3 时钟域与 CDC 表

| 信号 | 源域 | 目标域 | 打拍 |
|---|---|---|---|
| `cam_sel` | soc_clk | camera_clk_0/1 | 2FF + 下降沿门控（`cam_switch`） |
| `cam_sel` | soc_clk | ddr_clk | 2FF（算"切换后帧数"） |
| `cam_sel` | soc_clk | lcd_clk | 2FF（黑屏边沿） |
| `init_done_0/1` | sys_clk(27M) | soc_clk | 2FF |
| `wr_frames_ok` | ddr_clk | soc_clk | 2FF 电平 |
| `black` | soc_clk | lcd_clk | 2FF 电平 |

### 6.4 相机指示（无硬件 LED）

- 读 `CAM_CTRL[0]` 即知当前相机；`y1cam` 在遥测里多打一行 `CAM=n`（纯打印，不改协议/命令行）。
- 8 根 LED 一根不动（`led[3]=E18` 是 Linux 心跳，不是空闲灯）。

## 7. 验证计划（正负对照）

| # | 层 | 判据 | 负对照 |
|---|---|---|---|
| V1 | 仿真 `cam_switch` 独立 TB | 两路合成 PCLK（不同频/不同相位）+ 假 VS/DE/HREF：①切源时 `cam_clk_mux` **无窄脉冲**（逐拍检查"换源瞬间两路 en 均为 0"）②`sw_rst` 宽度 = 1 ms ③数据/href/vsync 跟随 `sel`，且切换后数据从新源的帧首开始 | 把门控短路成裸 mux 的突变体**必须判红**（证明判据能抓毛刺） |
| V2 | Lint | Verilator 对 `board/cam/*` + `board/yeshen_mini_board_top.v` 零 warning 级错误 | — |
| V3 | 综合 | dev_map：`check_dangling` 零悬空；LUT/FF/DRM 增量相对当前基线记账；cam1 的 IO 全部出现在端口表 | — |
| V4 | 时序 | PnR 100 MHz 全角 `All Constraints Met`；WNS 与基线对比 | — |
| V5 | 上板 | ①不按键：屏幕表现与 Cam known-good 一致 ②按 KEY2：~0.5 s 黑屏后出现新画面；`led[3]` 心跳不断 ③再按一次回 CAM0 ④`y1run` 12/12 CRC 或整帧 G7 不变 ⑤`devmem` 读回 `CAM_CTRL` 与画面一致 | 负对照：拔掉 CAM1 时按切换应**不黑屏死锁**（`init_done_1` 不来 ⇒ 停在黑屏但 `switch_busy=1` 可读，且再按一次能回 CAM0） |

> 第 ⑤/负对照这条是真实风险：CAM1 没插/坏了，`init_done_1` 永不来。设计允许"停在黑屏"，但必须**可再按一次退回 CAM0**（`sw_pending`/`black` 都随 `sel` 复位，不锁死）。

## 8. 风险与对策

| # | 风险 | 对策 |
|---|---|---|
| R1 | 门控后的 PCLK 送 `GTP_IDDR_E1`（`cmos_8_16bit` 内部）引起时序/功能问题 | 参考工程同构已上板验证；PnR 关注 `SDC-2025` 与 `cam_pixel_clk*` 的 WNS；上板首测先验 CAM0 单路不变 |
| R2 | 第二份 `camera.v` 带来 LUT/ROM 翻倍 | dev_map 实测记账；若增量不可接受再议方案 B（本 spec 不实现） |
| R3 | `init_done` 语义改为"所选相机" ⇒ `STATUS[0]` 在切换期短暂为 0 | y1cam 仅在首轮等 `init_done`（5 s 超时），切换期 <1 s，安全；文档写明 |
| R4 | 切换期写侧门控让 `frame_toggle`/`seq` 停 ≈1 s | y1cam 每轮等 seq 的超时 5 s；NPU 是逐次 `go`，不依赖连续帧 |
| R5 | 两颗相机同时上电发热/功耗 | 参考工程已验证；如需省功耗再谈"未选中相机 PWDN"（本期不做） |
| R6 | 引脚与 J10 上其它外设冲突（TF 卡等） | 已逐球确认 14 球在 FDC 中为空；TF 卡在 J25（2026-10 定案） |

## 9. 分阶段交付（供实现计划展开）

| 阶段 | 内容 | 出口判据 |
|---|---|---|
| S1 | `cam_switch.v` + 独立 TB + 负对照 | V1 PASS |
| S2 | `video_passthrough` 接入（cam1/第二份 camera/mux/掐写/黑屏） | V1 复跑 + V2 PASS |
| S3 | `video_regs` + `key_toggle` + board top + FDC | V2/V3 PASS |
| S4 | PnR + 比特流 | V4 PASS + sbit 指纹 |
| S5 | 上板验收（用户给窗口） | V5 全项 + 报告 |

## 10. 交付物

- RTL：§4.1 六个文件
- 仿真：`cam_switch` TB + 负对照脚本与输出
- 面积/时序：dev_map 摘要（相对基线增量）+ PnR 报告关键行
- 比特流 + md5
- 报告：`docs/reports/camera-switch.md`（含上板记录、按键实测、回归结果）

## 11. 已知限制

- 切换会有约 0.5 s 黑屏（事件驱动 + 400 ms 收敛窗），不是无缝切换。
- 两路画面相似时只能靠"画面内容/读回寄存器"区分（无角标，用户选择）。
- CAM1 缺失时按切换会停在黑屏（`switch_busy=1`），需再按一次回 CAM0；这是设计内的可恢复状态，不是死锁。
