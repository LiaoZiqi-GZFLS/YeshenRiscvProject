# YeshenGui 技术文档

日期：2026-10-30  
适用：YeshenGui（原 VexiiGui）/ Vexii RV32 Linux / 盘古 676 200K MINI  
状态：桌面、终端、OSK、触屏、相机返回已上板可用；性能调优未收口；gui2 板测未做。

---

## 1. 目标与范围

在 Vexii（RV32IMAC + Sv32，100 MHz，1024×600 LCD，GT911 电容触摸）上提供一套
Debian 风格桌面：

- 桌面、窗口管理器、Files / System Info / Settings / Terminal；
- 2048 / Minesweeper / Snake；
- 真实 PTY 终端 + 英文屏幕键盘（OSK）；
- 触摸操作、相机 ↔ GUI 切换及返回；
- 全程不修改原 `VexiiYeshenLinux` 参考仓库，RTL、内核、镜像均为独立副本。

本文记录最终软件结构、触屏链路、板级流程、问题复盘和已知限制，供后续维护/交接使用。

---

## 2. 总体架构

```text
+----------------------------- 板端 (100 MHz RV32) -----------------------------+
|  LVGL 9.2 UI                                                                 |
|    desktop / wm / apps / games / terminal / OSK                              |
|    platform:  board_fb (DDR framebuffer + GUI_CTRL)                          |
|               board_touch (evdev goodix) / input_uart (UART keys)            |
|               board_touch: KEY4 (gpio-keys KEY_F13)                          |
+------------------------------- Linux 5.10 ----------------------------------+
|  goodix  -> /dev/input/event1        gpio-keys -> /dev/input/event0          |
|  i2c-gpio (i2c-ctp)                  gpio-yeshen-ctp (13-line gpiochip)      |
+------------------------------- RTL (touch2) --------------------------------+
|  CTP INT/RST/SCL/SDA (AE21/AD21/AF22/AE22), KEY4 B20, PLIC source 5          |
|  video: camera -> DDR frame banks; GUI_CTRL (freeze + gui_bank)              |
+-----------------------------------------------------------------------------+
```

主机侧另有一套 SDL2 模拟器（同一份 `ui/` 代码），用于不接板时开发/截图。

---

## 3. 软件模块

### 3.1 UI 与窗口

- `ui/desktop.c`：壁纸、图标、顶部面板、底部任务栏、应用菜单、相机热角。
- `ui/wm.c`：窗口创建/焦点/最小化/关闭，内容对象接收键盘焦点。
- `ui/apps/`：Files、System Info、Settings、Terminal。
- `ui/games/`：2048、Minesweeper、Snake；核心逻辑在 `ui/games/core/`，有独立单测。
- `ui/theme.c`：Debian 风格浅色/深色主题。

### 3.2 平台抽象

`platform/platform.h` 定义：

- `platform_flush()`：把 LVGL RGB565 局部缓冲写入 DDR 帧存；
- `platform_poll_touch()`：host 返回 SDL 鼠标，板端返回 goodix evdev；
- `platform_poll_key()`：UART 键盘 + KEY4；
- `platform_set_camera_mode()`：写 `GUI_CTRL`，切换 LCD 读相机/GUI。

### 3.3 终端

- `ui/apps/terminal_core.c`：屏幕模型（100×200 行滚动、CSI/OSC 剥离、CR/LF/BS/TAB）。
- `ui/apps/terminal.c`：
  - 通过 `posix_openpt` + `fork` + `setsid` + `TIOCSCTTY` 启动 `/bin/sh`；
  - **本地行编辑**：shell 侧关闭 `ECHO`，输入只在 Enter 时整行写入 PTY；
  - 退格真正删除、左右键移动插入点、Tab 插 4 空格、Ctrl+C 发送 `0x03`；
  - 白色 2 px 竖线光标，只有终端聚焦时显示；
  - 字体 **unscii_8**（8 px 字宽、9 px 行高），100 列可完整显示；
  - 光标/输入行用独立 label 叠在屏幕模型最后一行，避免整屏重排。
- 已知限制：没有命令历史（上下键不发）；不实现完整 ANSI 光标/清屏，只做最小行模型。

### 3.4 屏幕键盘（OSK）

- 终端聚焦时显示 LVGL 英文键盘，失焦/关闭/`Hide` 隐藏；
- 工具栏：`Hide`、`Ctrl+C`、`Tab`、`Esc`、方向键；
- 键盘 `1#` / `abc` / `ABC` 切层；切层时用事件 `param` 的按钮 id + mode 变化判定，避免旧 bug“切层多打一个字符”；
- 显示时缩小终端滚动区并 `TIOCSWINSZ` 更新 shell 行列；
- 硬件键与 OSK 共用 `terminal_handle_key()`。

### 3.5 输入与滑动

- 触摸：`platform_poll_touch()` 读 evdev，缩放到 1024×600；
- 自定义游戏滑动（`ui/app.c` `touch_cb`）：
  - 仅 Snake/2048/Minesweeper 焦点；
  - 按下记录起点，移动 ≥28 px 立即压方向键（取主导轴），一次按压只发一次；
- LVGL 原生手势作为辅助（各游戏 `gesture_cb`，默认阈值 50 px）；
- UART 方向键 / D-pad / KEY4 切换为兜底。

---

## 4. 触屏硬件与 RTL

### 4.1 引脚（权威表）

| 信号 | 引脚 | 说明 |
|---|---|---|
| CTP_INT | AE21 | GT911 中断，低有效；RTL 2FF 同步后取反送 PLIC |
| CTP_RST | AD21 | GT911 复位，低有效；RTL 始终由 DATA_OUT[10] 驱动 |
| CTP_SCL | AF22 | I2C SCL；**RTL 推挽输出**（面板无 SCL 上拉） |
| CTP_SDA | AE22 | I2C SDA；RTL 开漏 |
| KEY4 | B20 | 物理返回键（低有效），GPIO12 |
| KEY3 | A22 | 原理图/丝印 KEY3，但**本 RTL 未接**（见 §8） |

### 4.2 GPIO / PLIC

- GPIO 控制器 `0xF0002000` 从 8 位扩到 **13 位**：
  - bit0–7 LED、bit8 SCL、bit9 SDA、bit10 RST、bit11 INT、bit12 KEY4；
- 新增 **PLIC source 5**（GT911），`ctp_irq = ~ctp_int_sync`，PLIC 电平高有效；
- CTP/KEY4 输入均经 2FF 同步。

### 4.3 独立 RTL

- 工程：`YeshenGuiTouch`（`YeshenGuiRtl` 的独立副本，原 `VexiiYeshenLinux` 零改动）。
- 关键改动：13 位 GPIO、PLIC NDEV=5、CTP/KEY4 引脚、SCL 推挽、SDA 开漏、FDC 仅新增 5 个引脚。
- PnR（tag `touch2`，strategy 1 / seed 1）：**All Constraints Met**，最小 Setup Slow **+0.215 ns**；
  sbit `85dbe37d…`，9,188,552 B。

---

## 5. 内核与 DTB

独立工程：`YeshenGuiKernel`（内核源为独立副本，参考 Linux 未改）。

关键配置：

- `I2C`、`I2C_GPIO`、`I2C_CHARDEV`、`GPIOLIB`、`INPUT_EVDEV`、`TOUCHSCREEN_GOODIX`、
  `KEYBOARD_GPIO_POLLED`、自写 `GPIO_YESHEN_CTP`；
- DTS：`gpio@f0002000`（13 线）、`i2c-ctp`（i2c-gpio）、`goodix@0x14`、`key3`（KEY_F13，实际接 B20/KEY4）。

触屏能工作的关键约束：

1. **地址 0x14**：FPGA INT 为纯输入，面板 INT strap 为高，扫描确认 0x5D NAK、0x14 ACK；
2. `i2c-gpio,scl-open-drain`：否则 i2c-gpio 强制开漏模拟，SCL 高电平=切回输入；
3. `scl-gpios` 不带 `GPIO_OPEN_DRAIN`；`sda-gpios` 保留 OPEN_DRAIN（高=输入，读 ACK）；
4. goodix `reset-gpios` 必须 **ACTIVE_HIGH**（驱动按物理 0=复位、1=释放）；
5. gpiochip 对 **SCL 输出方向回读 DATA_OUT**：IOB 不回环输出，i2c-algo-bit 的 `sclhi()` 需要读高；
6. `i2c-gpio,delay-us=20`（约 25 kHz，当前值；100 kHz 未验证）；
7. 触摸 rootfs 必须删除参考 `S99leds.sh`，否则它每秒写整个 DATA_OUT，清掉 RST/SCL/SDA。

产物：

| 文件 | 大小 | sha256 |
|---|---|---|
| `Image.touch` | 6,147,692 B | `5a3d8fa1…` |
| `linux_touch.dtb` | 2,991 B | `f3669997…` |

---

## 6. 相机 ↔ GUI 切换

RTL 为 freeze/bank 方案：

- `GUI_CTRL` 位于 video 窗口 `0xF0007400 + 0x494`（CPU 地址 `0xF0007494`）；
- bit0=1：冻结相机写，LCD 读 `gui_bank` 指定 bank；
- bit1=`gui_bank`，当前软件始终为 0，LCD 读 bank0；
- GUI 帧存：bank0 `0x9000_0000`、bank1 `0x9100_0000`，显示行 60–659；
- 应用现在只写 bank0，flush 成本减半；进入相机模式时 `platform_flush` 跳过写。

返回方式：

- 触屏：相机模式下按住**左上角 64×64 区域 2 秒**（盲按，GUI 不可见）；
- 物理 **KEY4（B20）**：只回 GUI，不反向进相机；
- UART `c`：桌面焦点下切换相机/GUI（Terminal 焦点时 `c` 是文本）。

---

## 7. 构建、镜像与烧写

### 7.1 构建

```bash
# 主机模拟器
bash scripts/build_host.sh
bash tests/run_tests.sh

# 板端 yshell
bash scripts/build_board_app.sh

# 触屏 GUI 镜像（使用 YeshenGuiKernel/out 的 Image/DTB）
bash scripts/build_board_image_touch.sh
```

### 7.2 产物（当前状态）

| 产物 | 说明 |
|---|---|
| `images/sd_gui_touch.img` | 卡上现有 GUI touch 镜像，8,438,272 B / 16,481 块，sha `14954727…`；**其 yshell 是旧的 5ce2f536** |
| `images/rootfs_gui_touch.cpio.gz` | 2,152,221 B，`53c9d89d…` |
| `images/linux_touch.dtb` | 2,991 B，`f3669997…` |
| `images/Image.touch` | 6,147,692 B，`5a3d8fa1…` |
| 最新干净 yshell | 1,123,640 B，`32442327…`（源码 commit `da753fb`；未重新打包进镜像） |
| `YeshenTouchTest/images/sd_touch_test.img` | 无 GUI 最小测试镜像，7,863,808 B，`786851fd…` |
| `YeshenTouchTest/images/sd_touch_diag.img` | goodix blacklist 诊断镜像，7,863,808 B，`2adf09f6…` |
| touch2 sbit | `85dbe37d…`，9,188,552 B |

默认对（`7092e495…` + `sd_gui.img f4dfc96d…`）与 gui2 对未动；旧触屏 sbit/镜像已作废。

### 7.3 正确的板级流程（重要）

1. 上电（FPGA 可能是基础比特流，Linux 仍可从卡启动）；
2. 用 `cdt_cfg_shell` 烧 `touch2`；
3. **不要按复位键**。FPGA 重配后 SdLoader 自动重新引导 Linux（约 4 s 到 login）；
4. 卡上镜像若是 GUI touch，登录后手动启动 `/root/gui/yshell`（无 autostart）。

> 这块板的复位键会清掉 JTAG 比特流；断电/复位后必须重烧 `touch2`，且烧完不能按复位。

卡写入使用 Windows 提权脚本：

```powershell
D:\code\PDS\YeshenGui\scripts\write_sd_card.ps1 -Disk 2 -Part 1 -Letter E `
  -Img D:\code\PDS\YeshenGui\images\sd_gui_touch.img
```

它会校验目标为 USB、容量、镜像大小，卸载卷、裸写、flush、回读 SHA 并打印 `CARD VERIFY PASS`。

---

## 8. 板测结果

### 8.1 通过项

- 干净 A/B（诊断镜像 + 冷上电 + 烧 touch2 不按复位）：
  - `i2cdetect -y 0` **只报 0x14**；
  - `i2ctransfer -y 0 w2@0x14 0x81 0x40 r2` 返回 **`0x39 0x31`**。
- 正常测试镜像：goodix 读到 **ID 911, version 1060**，注册 `/dev/input/event1`，gt911 IRQ 正常；
- 四角原始坐标（`ABS x=0..1023 y=0..599`）：左上 ~(55,117)、右上 ~(913,52)、左下 ~(86,563)、右下 ~(918,523)，方向正常；
- GUI：触摸图标/打开窗口、Terminal、OSK 输入、Ctrl+C、Hide、左上角 2 s 热角、KEY4 切换均通过；
- 终端：本地行编辑、退格、左右键、光标竖线、unscii_8 长行显示通过。

### 8.2 已知问题

| 问题 | 现象/原因 | 状态 |
|---|---|---|
| 触摸延迟/按住停顿 | 按住约 1–2 s 内画面停顿后恢复；FPS 标记仍走，gt911 中断计数在停顿期间不增长 | 未收口；待排查渲染/IRQ/面板侧 |
| 滑动不灵敏 | 自定义 28 px + LVGL 手势；游戏内仍偶发难触发 | 未收口 |
| 性能 | 终端场景 FPS 可到 ~49 fps；游戏/大窗口重绘仍慢 | 部分优化 |
| 物理 KEY3 | 丝印 KEY3=A22 未接；实际返回键是 KEY4=B20 | 已文档化，未改 RTL |
| gui2 变体 | 第二帧存 A/B 未上板 | 待窗口 |
| 相机卡 | 原相机镜像备份 `74b029c0…` 未恢复 | 待恢复 |
| 隔离基线 | 参考 `VexiiYeshenLinux` 被其他会话改动，基线未重录 | 未重录 |

> 2026-10-30 发现另一会话占用 COM7/板子（`flash_and_verify.py --tag rst1` + `listen_uart.py`）。上板前必须确认无其他会话占用；不要抢占 UART/JTAG。

---

## 9. 问题复盘（触屏为什么折腾了这么多轮）

| # | 根因 | 证据 | 修法 |
|---|---|---|---|
| 1 | 参考 `S99leds.sh` 每秒写整个 GPIO DATA_OUT | RST/SCL/SDA 被清 0，goodix 无 ACK | touch rootfs 删除该脚本 |
| 2 | 面板 SCL 无上拉，RTL 用开漏 | SCL 永远不高；hw_test J26 定案用推挽 | RTL `assign ctp_scl = gpio_dir[8] ? gpio_out[8] : 1'bz` |
| 3 | i2c-gpio 忽略 specifier 的 OPEN_DRAIN | 无属性时强制开漏模拟，SCL 高=输入 | DTS 加 `i2c-gpio,scl-open-drain` |
| 4 | gpiolib 对 OPEN_DRAIN 的高电平实现为切输入 | SCL 不能推挽 | SCL 去 OPEN_DRAIN；SDA 保留 |
| 5 | IOB 不回环输出，`i2c-algo-bit` 的 `sclhi()` 等 SCL 读高 | 采样 OUT 才看到 SCL 实际未驱动 | gpiochip 对 SCL 输出方向回读 DATA_OUT |
| 6 | goodix `reset-gpios` 极性 | 驱动最后把 RST 按低，面板保持复位 | 改 `GPIO_ACTIVE_HIGH` |
| 7 | GT911 地址 | INT strap 高，0x5D NAK、0x14 ACK | DTS `touchscreen@14` |
| 8 | 复位键清 JTAG 比特流 | 烧完按复位 → 触摸全 0/无 ACK | 烧完**不按复位**，SdLoader 自动重启 |
| 9 | 失败传输把 GT911 锁在 SDA 低 | 用户态扫描也全地址 ACK、ID 0 | 冷上电（断电）后重新烧 touch2，goodix blacklist 下先验总线 |

关键结论：**硬件/RTL/总线本身正常**（0x14 ACK、ID 3931/911 均读到）；之前大量“硬件坏”的迹象是
软件时序/复位/比特流丢失造成的连锁状态。

---

## 10. 操作手册（板端）

```sh
# 登录 root / yeshen 后
/root/gui/yshell        # 交互 GUI
                       # 终端：点 Terminal 图标；OSK 自动出现
                       # 相机：桌面按 c 或 Camera 图标
                       # 返回：左上角 64x64 长按 2 s，或 KEY4(B20)
                       # Ctrl+W 关闭终端
```

- GUI 无 autostart；重启后需手动运行。
- 终端中 `c` 是普通字符；要切相机先在桌面/非终端焦点按 `c`。
- KEY3（A22）无事件；用 KEY4。
- 卡片写回：`bash build/restore_tf.sh`（相机备份 `74b029c0…`，20,935 块）。

---

## 11. 后续工作

1. **性能/交互**（优先级最高）：
   - 触摸延迟/按住停顿：用 fast7 的 `YGUI-SLOW`/`YGUI-TOUCH` 日志定位是 handler、flush 还是面板侧；必要时 i2c 100 kHz（delay-us 5）并限制 goodix 最大触点数；
   - 游戏重绘：考虑 canvas/位图棋盘代替 300 个对象；
   - 滑动：调整自定义阈值/采样，或在游戏内改为 pointer 位移直接驱动。
2. **打包**：用最新干净 yshell `32442327…` 重新生成 GUI touch 镜像并写入卡；当前卡仍是 `14954727…`（旧 yshell）。
3. **KEY3**：如必须用丝印 KEY3，把 RTL key 从 B20 改到 A22，重跑 `touch3` PnR（需新 sbit）。
4. **gui2 第二帧存 A/B** 上板。
5. **相机卡恢复** 与隔离基线重录（需用户确认）。

---

## 12. 参考文件

- `docs/superpowers/specs/2026-10-29-touch-input-design.md`：触屏设计/结果
- `docs/touch-bringup.md`：板级步骤与验收
- `README.md`：构建/运行入口
- `YeshenTouchTest/README.md`：最小测试镜像
- `tools/touch_scan.c`、`tools/gpio_sample.c`、`YeshenTouchTest/touch_test.c`、`key_test.c`
- RTL：`YeshenGuiTouch/board/yeshen_mini_board_top.v`、`YeshenGuiTouch/constraints/yeshen_mini.fdc`
- 内核：`YeshenGuiKernel/dts/linux_touch.dts`、`drivers/gpio/gpio-yeshen-ctp.c`
