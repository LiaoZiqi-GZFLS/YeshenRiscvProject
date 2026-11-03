# GUI 第二帧存：LCD 读源选择（RTL 半，2026-10-30）

> 目标：让 LCD 能显示一块**与相机无关**的帧存（GUI 画布），而不冻结相机写。
> 本文件只覆盖 **RTL/仿真** 部分；GUI 应用移植（R7）与出镜像、PnR/比特流（R8）
> 另记。

## 1. 结论先说

- 新增寄存器 `GUI_CTRL`（VIDEO 窗偏移 `0x09C`）bit0 = `gui_src`：
  **0 = 读相机 bank（默认，行为与旧版逐字相同）；1 = 读 GUI 帧存 `0x9200_0000`**。
- 换源在**读帧首**才生效（与 `rd_buf` 内部行指针复位同拍），一帧之内绝不会
  前半帧读相机、后半帧读 GUI ⇒ 不会出现上下半幅撕裂。
- **厂家 RTL 零改动**：mux 全部做在 `board/cam/video_passthrough.v`（组装层）。
  `board/cam/vendor/**` 逐字节未动（`git status board/cam/vendor/` 为空）。
- 闸门 U8 正档 + 负对照均已在仿真中跑过；负对照实测发火（见 §5）。

## 2. 地址口径（先把账算清）

| 项 | 值 | 依据 |
|---|---|---|
| DDR 在 CPU 物理空间的基址 | `0x8000_0000` | Video 侧 28-bit 字地址 `+0` |
| 字 = | **4 字节（32-bit）** | `rd_buf`：行步长 `DDR_ADDR_OFFSET = 64×256/32 = 512` 字 = 1024 px × 2 B |
| 相机 bank0 / bank1 | `0x9000_0000` / `0x9100_0000` | bank 位 = 字地址 **bit22**（`fram_buf.LINE_ADDR_WIDTH=22`），2^22 字 = 16 MiB |
| `FB_ADDR_WORD` | `28'h400_0000` 字 = **256 MiB** = `0x9000_0000 − 0x8000_0000` | |
| **GUI 帧存** | **`0x9200_0000`**（`GUI_BASE_WORD = 28'h0480_0000`） | 紧接两个相机 bank 之上 |
| GUI 窗大小 | 16 MiB（`0x9200_0000..0x92FF_FFFF`） | 读地址只取 `axi_araddr[21:0]` |
| 一帧实际占用 | 720 行 × 512 字 = 368,640 字 ≈ 1.41 MiB（远小于 16 MiB） | |
| 可见行窗口 | 帧存 **第 60..659 行**（`ROW_OFFSET=60`，显示 600 行） | `rd_buf` 行指针起点 = `ROW_OFFSET × 512` |

像素打包（GUI 应用必须照这个写）：

- 每个 32-bit 字 = 2 个 RGB565 像素，**低 16 位 = 左边的像素、高 16 位 = 右边的像素**；
- 依据（写侧无歧义）：`wr_buf` 的 `write_data <= {wr_data, wr_data_1d}` —— 当前像素
  （时间上更晚 = 右边）进高半，上一拍像素（更早 = 左边）进低半；读侧 `rd_buf`
  `PIX_WIDTH=16` 分支按"先低半后高半"逐拍吐出，两侧一致，U2 已逐像素（约 2.37M）验过；
- ⇒ 在**小端** CPU 上，直接 `uint16_t *fb`（`fb[y*1024+x]`）的布局正好对：
  偶数 x 落在低半、奇数 x 落在高半。**不需要字节交换、不需要手工拼字**；
- 565 → 888 是 `{(r[4:0],3'b0), (g[5:0],2'b0), (b[4:0],3'b0)}`，无抖动/无伽马。

所以 GUI 画布 = 一块 **1024×720、行跨 2048 B、可见区在第 60..659 行** 的 RGB565 位图。
画到 `0x9200_0000 + (60+y)*2048 + x*2` 就落在屏幕第 y 行。

## 3. RTL 改动（三处，全是自有文件）

### 3.1 `board/cam/video_regs.v`

- 新增 `A_GUICTRL = 12'h09C`、`output wire gui_src`、`reg gui_src_r`；
- 复位清 0；写口按 `wdata_q[0]` 更新；读回 `{31'd0, gui_src_r}`；高位忽略。

寄存器图（`0x090..0x09F`）：

| 偏移 | 名字 | 位 |
|---|---|---|
| `0x090` | VERSION | RO `0x0001_0001` |
| `0x094` | ETH_CTRL | `[0]` eth_en（H2 读存服务独占） |
| `0x098` | RST_CTRL | `[0]` rst_req（软复位） |
| `0x09C` | **GUI_CTRL** | `[0]` **gui_src** |

> 注：参考变体 `YeshenGuiRtl2` 把 GUI 控制放在 `0x094`，在主线上那是 `ETH_CTRL`，
> 会撞车 ⇒ 本条主线统一用 `0x09C`。

### 3.2 `board/cam/video_passthrough.v`

- 参数新增 `GUI_BASE_WORD = 28'h480_0000`；
- 端口新增 `input wire gui_src`（soc_clk 域）；
- 换源锁存（**关键**）：

```verilog
// ddr_clk 域：vs_reg 3FF（与 rd_buf 内部 wr_fsync_1d..3d 同源同钟同深度）
always @(posedge ddr_clk) begin
    gui_s1 <= gui_src;  gui_s2 <= gui_s1;
    gui_fs1 <= vs_reg;  gui_fs2 <= gui_fs1;  gui_fs3 <= gui_fs2;
end
wire rd_frame_rst = ~gui_fs3 & gui_fs2;      // = rd_buf 的 wr_rst
always @(posedge ddr_clk) begin
    if (!ddr_rstn)         gui_sel_ddr <= 1'b0;
    else if (rd_frame_rst) gui_sel_ddr <= gui_s2;
end
```

  为什么必须是这条链：`rd_buf` 在 `ddr_clk` 上对 `rd_fsync(=vs_reg)` 打三拍、取
  `~d3 & d2` 作 `wr_rst` 把行指针复位到 `ROW_OFFSET`。只有把选择位锁在**同一拍**，
  地址 mux 与行指针才会同时切换（否则会出现"新源地址 + 旧行指针"的一行错位）。

- 读地址 mux：

```verilog
wire [27:0] ar_cam = axi_araddr + FB_ADDR_WORD;
wire [27:0] ar_gui = GUI_BASE_WORD + {6'd0, axi_araddr[21:0]};
assign ddr_araddr  = gui_sel_ddr ? ar_gui : ar_cam;
```

  低 22 位就是 bank 内字偏移（bank 位在 bit22）。**写地址不动**：相机永远写自己的
  `0x9000_0000/0x9100_0000` 两个 bank，GUI 区只读不写。

- 黑屏掩码：`wire lcd_black = cam_black & ~gui_sel_lcd;`
  （`gui_sel_lcd` 是 lcd 域 2FF + 帧首锁存）。相机切换时的 ~0.5 s 黑屏窗不该把
  GUI 画面一起吃掉，否则切相机时 GUI 会闪黑。

### 3.3 `board/yeshen_mini_board_top.v`

`video_regs.gui_src` → `u_video.gui_src`，新增一根 `gui_src_w`，无新引脚。

## 4. 与参考变体 `YeshenGuiRtl2` 的差异（有意为之）

| 项 | 参考变体（R6） | 本条主线 |
|---|---|---|
| 改在哪一层 | 改 `rd_buf.v` / `fram_buf.v`（厂家 RTL） | 只改组装层 `video_passthrough.v` |
| 锁存点 | `rd_buf` 内部 `wr_rst` 同拍锁 `bank_r`/`src_sel_r` | 组装层复刻同一 `wr_rst` 链 |
| 寄存器 | `GUI_CTRL` @ `0x094`（bit1 = gui_bank） | `GUI_CTRL` @ `0x09C`（只有 bit0） |
| 语义 | 读源 + GUI bank 选择，且**删除**相机写冻结 | 相机写冻结早已在 V1 移除；本版只加读源 |

原因：`board/cam/vendor/**` 是厂家交付件，本仓一贯零改动（同 V1-T1 的复制原则）；
同一语义完全可以在组装层等价实现，且不产生第二份 vendor 分叉。

## 5. 验证

```
cd sim/video && bash run_video_gates.sh
```

新增 **U8**（`tb_gui_src.v`，装置要点）：

- 只读 DDR 应答器按地址区域返回常量像素：相机区 → `0x1080`，GUI 区 → `0x2A55`，
  其余 → 记账（`ar_unknown`）；不做存储，因此 0x480_0000 这样的大地址不会撞模型窗口。
- 三档：`cam → gui → cam`，每档**故意在帧中途**改 `gui_src`，等 2 帧后逐像素比 1 帧。
- 判据（全 0 才算过）：`ar_unknown` / `mixed_frame`（同一帧内读源变化，且距上一笔
  AR < 10000 ddr 拍）/ `aw_gui`（写地址落进 GUI 区）；每档还必须真的看到该档的 AR。

实测输出（`sim/reglogs/video_gates_gui.log` + `/tmp/video_gates/u8.log`）：

```
GUI_SRC: phase src=0 exp=1080 good=614400 bad=0 dARcam=2404 dARgui=0
GUI_SRC: phase src=1 exp=2a55 good=614400 bad=0 dARcam=0 dARgui=2404
GUI_SRC: phase src=0 exp=1080 good=614400 bad=0 dARcam=2404 dARgui=0
GUI_SRC: ar_cam=16828 ar_gui=7212 ar_unknown=0 aw_gui=0 mixed_frame=0 frames=11
GUI_SRC: PASS
```

（`SETTLE=2 / NCHK=1` ⇒ 每档只逐像素比 1 帧 = 614,400 px；`dARcam/dARgui` = 该档内
进入对应区域的读命令数。）

负对照实测（`sed` 把 `else if (rd_frame_rst) gui_sel_ddr <= gui_s2;` 改成
`else gui_sel_ddr <= gui_s2;`，`-DFAST` 只跑一次换源）：

```
GUI_SRC: phase src=1 exp=2a55 good=614144 bad=256 dARcam=1 dARgui=2403
GUI_SRC: PHASE FAIL src=1 bad_px=256
GUI_SRC: ar_cam=4809 ar_gui=2403 ar_unknown=0 aw_gui=0 mixed_frame=1 frames=4
GUI_SRC: FAIL unknown=0 aw_gui=0 mixed=1 cam=4809 gui=2403
```

坏 DUT 上 `mixed_frame=1`（帧内跨区读）且切换那一帧有 256 px 读到旧源 ——
说明两条判据都真的长着眼睛。

> ⚠️ U8 正档单跑约 **10–12 分钟**（11 个 LCD 帧 + 相机写侧），是全套闸门里最长的两条之一
> （另一条是 U2）。负对照 `-DFAST` 约 3 分钟。

另外 `U4`（VIDEO_REGS）新增第 9 组：`GUI_CTRL` 复位值 0、写 1/写 0、高位忽略、
复位清 0 —— 已知全过。

## 6. PDS 侧进展

### 6.1 camfix5 = 本轮的 All-Met 基线（**不含** GUI RTL）

`YESHENMINI_STRATEGY=1`（`gplace_times 4 / saved_outcome 4 /
pick_first_timing_convergence_seed true`）seed 0 收敛：

```
Design Summary : All Constraints Met.
 cpu_clk  +0.470   soc_clk +0.607   npu_clk +0.311   core_clk +0.712
 core_clk -> phy_dq_sysclk_0  +0.114   （camfix4 是 −0.031）
 core_clk -> phy_dq_sysclk_1  +0.073
 hold: 全正（core_clk->phy_dq_sysclk_0 +1.032）
```
资源：LUT 87,789.5（55.02%）/ FF 119,606（37.42%）/ DRM 312（75.18%）/
APM 257（34.73%）/ USCM 13（40.6%）。
比特流 `sim/reglogs/pds_camfix5_p10.000/prj_tasks/pnr_1/generate_bitstream/yeshen_mini_board_top.sbit`
（9,188,552 B，sha256 前 8 位 `0634d9a6`）。
⇒ 这颗只作为"strategy 1 能收敛、phy_dq 那条来回摆的路径这次是正的"的证据；
**交付比特流必须换成带 GUI 的 `gui1`**。

### 6.2 gui1 = 带 GUI 读源选择的 dev_map

```
python scripts/check_devmap.py sim/reglogs/devmap_gui1.log
PASS: dev_map 0 error
LUT 87,809.5（55%） FF 119,599（38%） DRM 312（76%） APM 257（35%） USCM 13
```
GUI 功能的净代价：**+20 LUT / −7 FF**（其余不变），可以忽略。
PnR（同样 strategy 1）随后跑；判定同样看 `.rtr` 的 `Design Summary`。

## 7. 还没做（后续）

1. **gui1 的 PnR / 比特流**：dev_map 已过（§6.2），PnR 已按 strategy 1 启动；
   判据同 camfix5（`.rtr` 的 `Design Summary : All Constraints Met` +
   `core_clk→phy_dq_sysclk_0/1` 不得翻负）。
2. **GUI 应用移植（R7）—— 寄存器偏移这一步已做（2026-10-30）**：
   `YeshenGui` 提交 `e0ab541` 把偏移做成编译期可选，新增 `GUI_VARIANT=mainline`
   （`-DBOARD_GUI_MAINLINE=ON` → `-DVIDEO_GUI_CTRL_OFF=0x49CUL`），产物
   `board/variants/mainline/yshell`（1,123,620 B，sha256 `2cc11f8b…`）。
   - 反汇编实证：`s_gui_ctrl = page + 1180 (0x49C)`，且映射 `0x9200_0000`；
     缺省档仍是 `page + 1172 (0x494)` + 映射 `fb0/fb1`。
   - 零回归：`board_fb.c` 改前/改后同路径同 `-I` 编出的 `.o` **字节相同**；
     default 整份重编 sha256 `324423275f079c24…` 与 staged 一致。
   - 其余（终端/OSK/热角/LVGL）原样可用，无需改动。
3. **主线上还缺的输入/返回通路（**不是偏移问题**，要单独决策）**：
   - **触摸**：主线 RTL 没有 GT911 / `i2c-gpio` / GPIO 控制器（那套只在
     `YeshenGuiTouch` 变体里）⇒ 主线 GUI 目前只能显示 + 串口键鼠。要触屏得把
     CTP 四线 + 13 位 GPIO + PLIC 源搬进主线（独立 RTL 任务）。
   - **返回相机**：参考变体用「左上角热角（触摸）+ KEY4(B20)」；主线只有 KEY2
     （双目切换）⇒ 主线上切回相机需要一个软件口子（UART 命令 / 退出 app 时把
     `gui_src` 写回 0）。
   - **串口键盘**：`platform/input_uart.c` 缺省打开 `/dev/ttyS0`，与 getty 抢读；
     主线镜像要决定是关 getty 还是走 ssh/命令行开关。
4. **出镜像**：把 `yshell(mainline)` + `S99gui.sh` 塞进主线 rootfs overlay 后
   `bash scripts/build_images.sh --only images` 重建；当前 `sd_ab_k2_rst.img`
   与源码一致，直接重建是空跑。
5. **撕裂**：GUI 区是单缓冲（与参考变体一致）。应用侧要避开读帧窗口（60 fps 下每帧
   16.4 ms，可见区约 11.5 ms）；需要更稳的话再上双缓冲（RTL 侧只改基址即可，无需
   改协议）。

## 8. 2026-10-30 追加：KEY4 返回键 + 相机应用 + 显示/触摸服务（ctp2）

### 8.1 KEY4（B20）进主线

- 板级顶层新增 `input key4`（B20，低有效、有源上拉）→ `soc_clk` 2FF →
  `gpio_in[12]`（原来恒 0 的保留位）。**KEY4 是唯一空闲按键**：KEY0=C22 是复位、
  KEY1=C23 是装载 strap、KEY2=B22 是硬件双目切换（同源 `CAM_CTRL[0]`）、KEY3=A22 未接。
- FDC 加 `p_key4 = B20`；端口/FDC 集合脚本核对 **166 == 166**，差集为空。
- 内核：DTS 加 `gpio-keys-polled`（`&gpio_ctp 12 GPIO_ACTIVE_LOW`，`linux,code = KEY_F13`，
  `poll-interval = 20`），config 加 `CONFIG_INPUT_KEYBOARD` + `CONFIG_KEYBOARD_GPIO_POLLED`；
  DTB 反编译实证 `gpios = <0x04 0x0c 0x01>`、`linux,code = <0xb7>`。
- 应用：KEY4/热角统一走 `desktop_camera_leave()`（停 y1cam → 清 overlay → `gui_src=1` → 重绘）。

### 8.2 ctp2 构建（含 GUI 读源 + CTP + KEY4）

| 项 | 结果 |
|---|---|
| dev_map（tag `ctp2`） | 0 error；LUT **88,083**（56%）/ FF 119,648 / DRM 312 / APM 257 / **IO 166** |
| PnR（tag `ctp2`，strategy 1） | **All Constraints Met**（soc +0.462 / cpu +0.609 / npu +0.557 / core +0.506；`phy_dq_sysclk_0→core_clk` **+3.299**，ctp1 的那条 −0.010 弧不再出现） |
| 比特流 | `sim/reglogs/pds_ctp2_p10.000/prj_tasks/pnr_1/generate_bitstream/yeshen_mini_board_top.sbit`<br>9,188,552 B，sha256 `c01d6a6f30300956b0862de5dc8bf61b1907c498442c97a6b77b401725eededa` |

> dev_map 启动后只改过本文件的**注释**（§8.1 的端口数说明），逻辑未动。

### 8.3 应用：相机卡片 + 开机进桌面

- 相机卡片进入时二选一：**Detect faces**（拉起 `/root/y1/y1cam --loop --quiet`）或
  **Plain view**（停 y1cam + `OVERLAY_CTRL=0` 清框）；CAM0/CAM1 按钮写 `CAM_CTRL[0]`
  并落 `/etc/y1cam.default`，开机默认 **CAM1**。
- 开机自启：`/etc/y1gui.autostart` + `S99gui.sh` 以 `--no-uart` 启动（不抢 getty 的
  ttyS0）；`S99y1cam.sh` 改为默认**不**自启（只有 `/etc/y1cam.autostart` 存在才起）。
- 桌面默认浅色壁纸；CPU% 改成 `/proc/stat` 真占用（旧版用 loadavg，恒显 100%）。

### 8.4 显示/触摸服务模块（解决“一行行刷新、触摸迟钝”）

- `platform/board_present.c`：`flush_cb` 只把条带拷进 4 个缓存 staging 槽就返回
  （LVGL 立刻可复用 draw buffer），独立线程按序把槽写进 DDR。UI 线程不再被
  uncached 写阻塞；`pthread_create`/malloc 失败自动退回同步 flush。
- `platform/board_touch.c`：触摸独立线程 `poll()` evdev 维护 `(x,y,pressed)` 快照；
  `EVIOCGABS` 从“每样本两次 ioctl”改为开设备时查一次；无线程时退回同步 drain。
- 离线闸门（host）：40 帧 × 6 条带、sink 故意慢 800 µs → 最终帧逐像素 PASS；
  反向对照（队列改 LIFO 的变异版）→ 512,000/614,400 像素 FAIL。
- 仍是单缓冲：`flush` 期间的撕裂边要等 RTL 第二个 GUI bank（`GUI_CTRL[1]`）才能消。

### 8.5 镜像与卡（含以上全部）

| 产物 | 大小 | md5 |
|---|---|---|
| `Image` | 6,205,492 | `235d2593bb2851ff88310bebcc30bf41` |
| `linux.dtb` | 3,183 | `e09b154d9e07985ece9e7f2c946b13be` |
| `rootfs.cpio` | 6,439,936 | `94e7c47b938f1bfe9682f8005900d996` |
| `sd_ab_k2_ctp.img` | 33,554,432 | `c8f08f9ae676d3c7892315ae5e57d06f` |
| `sd_score_ctp.img` | 16,838,144 | `824bbae7f6be6b077d7852bffca05539` |

`rootfs.cpio` 里 `root/gui/yshell` 1,319,892 B（`--no-uart` 版），`etc/y1gui.autostart`
存在，`S99gui.sh`/`S99y1cam.sh` 为新版。

### 8.6 上板首轮：`Plain view` 崩溃（OVERLAY_CTRL 偏移写错）—— 已修

现象：点相机卡片的 **Plain view** 后界面“卡住”（LCD 停在最后一帧）。

证据链（全部来自板端）：
- `dmesg`：`yshell[93]: unhandled signal 11 code 0x2 at 0x0001ff8c`，`cause 00000007`
  （Store/AMO access fault），`badaddr` = `s_overlay_ctrl` = **视频页基址 + 0x008**。
- `addr2line 0x1ff8c` → `platform_clear_overlay`；反汇编该处正是 `sw zero,0(a5)`。
- `devmem 0xF0007408` → `0x0`（可读）；`devmem 0xF0007008` → **Segmentation fault**。

根因：VIDEO CSR 窗从 **`0xF000_7400`** 起，`/dev/mem` 只允许按页（`0xF000_7000`）映射。
我按“窗口内偏移”定义了 `OVERLAY_CTRL=0x008`，却忘了它是**从窗口基址**算的 ⇒ 实际写到
`0xF000_7008`，落在 SoC **不译码**的空洞里 ⇒ 总线错误 ⇒ 进程被杀。CAM_CTRL(0x40C)、
GUI_CTRL(0x49C) 当时写对了，所以只有“清 overlay”这一条路会崩。

修复：
- `VIDEO_OVERLAY_CTRL_OFF = 0x408`（页内偏移 = 0x400 + 0x008）。
- 三个偏移加编译期断言：`_Static_assert(off >= 0x400, "must sit in 0xF0007400..77FF")`，
  以后再加视频寄存器漏加 0x400 会直接编译失败。

修复后镜像/卡（同一份二进制 `yshell` md5 `231bd4abb7caa300b9a025a9380dec97`）：

| 产物 | 大小 | md5 |
|---|---|---|
| `rootfs.cpio` | 6,439,936 | `19e511a87cd2c8d2169020b76d5d546f` |
| `sd_ab_k2_ctp.img` | 33,554,432 | `4cb35b7f3b4ff5e344c041c6567a93fe` |
| `sd_score_ctp.img` | 16,838,144 | `6817cf9a4e752879de7c7a1ca7dbf991` |
| `Image` | 6,205,492 | `93893709f302c3b11c9e4f7764b6bdf4`（重编时间戳变动，配置未变） |

### 8.7 上板第二轮：人脸检测无框 —— 卡上 y1cam 是 10-23 旧构建

现象：Detect faces 进入相机态后看不到检测框。

取证：
- `getprop`/`ls -l /root/y1/y1cam` → **10-23 21:20** 的 83,268 B 二进制；而 `y1/tools/y1cam.c`
  最后修改 **10-28 01:41**，关键提交 `60b4ee3`（live face detection：反量化口径 +
  BOX 字序 + 阈值 0.65）**没有烘进卡**。
- 旧二进制残留的 BOX0 = `{0x000001E3, 0x01690344}` → x 0..361、**y 483..836（越界且未裁剪）**，
  与现源码 `map_boxes()` 的 `x+192 / y-20 + 裁剪到 1023/599` 不一致。
- 另一份快照（`y1cam --once --dump`，640×640）取回转 PNG 后确认：无人时画面是房间/白衬衫，
  `dets=0` 属正确行为（不是检测坏）。

修复与验证：
- `bash y1/tools/build_y1cam.sh --install` 重建 → 95,568 B，md5 `9cb5a2557bbe043b3a3393c263c9cddf`
  （`strings | grep -- --loop` = 2）。
- 板上真人测试（新二进制）：连续 **20 个 2 s 采样** `OVERLAY_CTRL=0x0101`（en=1、count=1），
  BOX 解码 **x 369→563、y 60→284**（194×224，全部在 1024×600 内），`GUI_CTRL=0` ⇒ 框随帧提交，
  用户目视确认绿框正常。

附带改进：`yshell` 把 y1cam 的 stdout/stderr 从 `/dev/null` 改成 `/tmp/y1cam.log`
（`CAMRUN`/`CAM_DETS` 遥测是现场区分“没人脸”与“链路坏”的唯一依据）。

### 8.8 交付镜像与卡（2026-10-30 定稿）

| 产物 | 大小 | md5 |
|---|---|---|
| `rootfs.cpio` | 6,452,224 | `b82005849e2dfbb39c7b4023cfe88891` |
| `sd_ab_k2_ctp.img` | 33,554,432 | `9fca5c089e2171a9b50cfd1b2783e7d6` |
| `sd_score_ctp.img`（已写卡） | 16,838,144 | `844b3ed1c4780dfa1ec0f36ba8f753e6`（sha256 `78C434AA…262FF`，CARD VERIFY PASS） |
| `Image` | 6,205,492 | `8d0cab8bdb82787d0ba149fcebdfa017` |
| `linux.dtb` | 3,183 | `e09b154d9e07985ece9e7f2c946b13be` |

卡内关键二进制：`root/gui/yshell` md5 `0eebfe98f8b8702529882691c1ea181b`（1,319,892 B，
含 OVERLAY_CTRL 0x408 修复 + y1cam 日志）、`root/y1/y1cam` md5 `9cb5a2557bbe043b3a3393c263c9cddf`。
