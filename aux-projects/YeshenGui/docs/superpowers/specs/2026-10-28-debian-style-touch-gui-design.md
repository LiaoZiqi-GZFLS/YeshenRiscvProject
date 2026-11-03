# YeshenGui — Debian 风格触屏桌面（Phase S 设计）

日期：2026-10-28  
状态：设计已逐节确认；待用户评审本文档后进入实施计划  
范围：**Phase S（无 RTL、独立镜像）**；**Phase S6（终端已实现；英文屏幕键盘待触屏）**；**Phase R（独立 RTL 变体，后续）**
原始工程基线：spec 编写时为 `e79bcf0`；执行期间另一会话完成 camsw5 PnR 并提交到 `212d3a2`。用户确认后，S0 在 PnR 结束后重录基线为 `212d3a2` + `?? build/`（818 index files、52 个关键输入 artifact sha256），`verify_isolation.sh` PASS。**本项目不修改原工程**；后续若并发会话继续移动 HEAD/status，检查会红，确认后重录，不回退。隔离基线要求原工程 worktree 根、六个 `sw/images` 关键输入；不接受子目录/`.git` 目录/bare repo/无 artifact 的 root。

---

## 0. 一句话

在 **Vexii RV32 Linux 单板**上，用 **LVGL 自绘一个 Debian 风格桌面**（面板、窗口、Files/System/Settings），带 **2048 / Minesweeper / Snake** 三个触屏小游戏；先以**完全独立的镜像 + 主机模拟器**交付（不改 RTL、不影响现有相机/NPU 演示），触屏与相机切换留到后续的独立 RTL 变体。

---

## 1. 背景与动机

这块板子现在已经能跑 RV32 Linux、相机、LCD 和 YuNet NPU 演示，但界面是“相机直通 + 硬件框”，没有桌面感。用户希望：

- 一个**类似 Debian 的图形界面**，能看、能玩、适合 7 寸触屏演示；
- 带几个小游戏；
- 最终用上屏幕自带的 **GT911 电容触摸**；
- 后续还能加**终端 + 英文屏幕键盘**。

直接跑 Debian 不可行：Debian 的 RISC-V 官方端口是 riscv64（RV64GC/lp64d），本核是 RV32IMAC + Sv32，且没有 GPU/DRM/输入栈。因此本项目做的是 **Debian 风格的 UI**，不是 Debian 发行版。

用户明确要求：**目前先不动 RTL，先独立构建新的镜像，不影响之前的相机/NPU 演示**。因此拆成两阶段：

- **Phase S**：不动 RTL，独立镜像 + 主机模拟器；先把 UI/游戏/应用做出来。
- **Phase R**：以后新建独立 RTL 变体，加触摸引脚和 GUI 帧存控制；原 Vexii 工程仍零改动。

---

## 2. 目标

### 2.1 Phase S（本次实施范围）

1. 新建独立工程 `YeshenGui`，**对 `VexiiYeshenLinux` 只读**，前后哈希可证明零改动。
2. 主机 1024×600 SDL2 模拟器：同一套 LVGL UI，用鼠标模拟触摸，用于开发和验收。
3. 桌面壳：壁纸、顶部面板、桌面图标、窗口管理、Applications 菜单、Light/Dark 主题。
4. 应用：**System Info / Files / Settings**；Camera 只放 `Phase R` 占位卡片。
5. 游戏：**2048 / Minesweeper / Snake**，完整可玩，带主机单元测试。
6. 板端独立镜像 `sd_gui.img`：复用现有 `Image`/`fw_jump`/DTB 的副本，新 rootfs，能启动 GUI（手动或 `--demo`）；**不含触摸**。
7. 原 `sd.img`、相机 rootfs、bitstream、RTL 全部不动；构建前后用 **HEAD + `git status` + index OID 清单 + 52 个关键输入 artifact sha256** 对账，证明本项目零写入。

### 2.2 Phase S6（后续，仍无 RTL）

- 终端：PTY + `/bin/sh`，行式终端，约 100×30 字符、200 行 scrollback，最小 ANSI。
- **英文屏幕键盘**：QWERTY + 数字/符号 + Shift/Ctrl/Tab/Esc/Backspace/Enter/Space/方向键。
- 在 Phase S 镜像上追加，不改内核、不改 RTL。

### 2.3 Phase R（后续，独立 RTL 变体）

- 新建独立 RTL 工程/变体，加 CTP 4 线 + KEY3、gpiochip + i2c-gpio + goodix + PLIC + evdev。
- 加 `GUI_CTRL`（freeze / gui_bank / active_bank / vsync）和 LCD 读 bank 选择，实现双缓冲。
- 相机切换与返回：左上角长按 2 秒 + KEY3；GUI 默认，Camera 应用切到相机/NPU 演示。
- 同一套 `ui/` 只换平台层；原 Vexii 工程仍零改动。
- Phase R 需要单独 spec/plan，不在本次实施计划内。

---

## 3. 非目标

- 不启动真正的 Debian 发行版；不移植 riscv64 用户态。
- 不碰 Nax 线、不做 X11/Wayland/Matchbox/XFCE。
- Phase S **不做触摸**、不做相机切换、不做 GUI/相机同屏。
- 不做音频、Wi-Fi、蓝牙、CJK 字体、多用户、持久化设置、网络应用。
- 不做完整 ANSI/curses 终端；S6 只保证行式命令（`ls`、`cat`、`uname`、`ip addr` 等）。
- 不修改 `VexiiYeshenLinux` 的任何文件；不覆盖其 `sw/images/sd.img`、bitstream、构建输出。

---

## 4. 已定决策

| # | 决策 | 说明 |
|---|---|---|
| D1 | 平台 = Vexii RV32 Linux | mainline `cpu_clk` 100MHz；Linux 可见约 224MiB（DTS 252MiB − NPU arena 28MiB）；1024×600 屏；GT911 触摸 |
| D2 | UI = LVGL 自绘 Debian 风格桌面 | 不用 X11/Wayland；触屏优先；英文界面 |
| D3 | 默认 Debian Light，Settings 可切 Dark | 红色强调色 `#A80030`；静态壁纸 |
| D4 | 应用 = System Info / Files / Settings | Camera 在 Phase S 仅占位，标 `Phase R` |
| D5 | 游戏 = 2048 / Minesweeper / Snake | 三个都做完整逻辑 + LVGL 前端 |
| D6 | 触摸输入栈 = Linux 输入栈（Phase R） | gpiochip + `i2c-gpio` + 主线 `goodix` + PLIC 源 5 + `/dev/input/eventX` |
| D7 | Phase S 完全不动 RTL | 主机模拟器 + 独立板端镜像；板端显示依赖“拔相机”测试 |
| D8 | 原 Vexii 零改动 | 新工程独立；构建只读原工程；前后哈希对账 |
| D9 | GUI 默认、相机可切（Phase R） | 返回 = 左上角长按 2 秒 + KEY3 物理兜底 |
| D10 | 终端 + 英文屏幕键盘 = Phase S6 | 终端已实现（2026-10-29）；OSK 待触屏 |

---

## 5. 现状与约束

### 5.1 硬件与系统

- 板卡：盘古 100K200K MINI（PG2L200H-6IFBB676）。
- CPU：VexiiRiscv RV32IMAC + Sv32；mainline `cpu_clk` = 100MHz。
- 内存：Linux 可见约 224MiB（DTS 声明 252MiB，扣掉 28MiB NPU arena 保留区）。
- 屏幕：7 寸 1024×600 RGB888 面板；现有视频链以 RGB565 帧存 + 3 拍输出寄存器驱动。
- 触摸：GT911 电容触摸，4 线 `CTP_SCL/CTP_SDA/CTP_RST/CTP_INT`；旧硬件测试已探到 GT911 应答 `3931`。
- 现有视频链：`camera → 裁列 → DDR 帧存（双 bank）→ LCD 扫描 + overlay`，由 `board/cam/video_passthrough.v` 组装；相机引擎上电后自己初始化传感器并持续写帧存，不依赖 Linux 进程。
- 帧存：物理 `0x9000_0000`（bank 0）/ `0x9100_0000`（bank 1），bank 跨度 16MiB；帧 1024×720、行 stride 2048B；LCD 显示第 60–659 行。
- 当前 mainline 的 RTL **没有**接 CTP 4 线；GPIO 控制器只把低 8 位用于 LED；内核没有 I2C/input/goodix 配置。
- 当前 CAM1 切换 PnR（`m_camsw4`）有负 setup slack；本项目不依赖它，Phase S 以单目 CAM0 的 known-good 视频链为基线。

### 5.2 软件与构建

- 内核：Linux 5.10.1（SpinalHDL/linux dev），rv32imac，uClibc-ng 用户态。
- 现有 rootfs：buildroot initramfs，约 2.57MiB（`rootfs.cpio`）；当前已知-good `sd.img` 为 8,791,040 B（约 8.38MiB）。
- initrd 窗口：`0x8300_0000–0x8380_0000`（8MiB）。
- 交叉工具链：WSL 的 `$HOME/vexii-build/buildroot/output/host/bin/riscv64-buildroot-linux-uclibc-*`（只读复用）。
- 装载链：TF → SdLoader 按块 0 装载表把 `fw_jump`/`Image`/DTB/rootfs 搬进 DDR。
- 现有启动脚本 `S99y1cam.sh` 会在 rcS 阶段自启 y1cam；新镜像在自己的 rootfs 副本里禁用它，不改原镜像。

### 5.3 关键约束

1. **Phase S 没有任何触摸路径**：CTP 4 线未进当前顶层/FDC，软件无法访问；不能声称“触屏可用”。
2. **Phase S 没有相机冻结**：相机引擎会持续覆盖帧存；板端显示测试必须拔掉 J10 相机模组，否则画面被覆盖。拔相机是测试手段，不是交付形态。
3. **原工程只读**：不修改 `VexiiYeshenLinux` 的源码、脚本、镜像、bitstream；构建前后用 **HEAD + `git status` + index OID 清单（`git ls-files -s`）+ 52 个关键输入 artifact sha256** 证明本项目零写入；check 模式只读（`GIT_OPTIONAL_LOCKS=0`）。六个 `sw/images` 关键输入必须全部存在；`--record` 拒绝嵌套仓库、无 artifact 的 worktree/fresh clone，check 拒绝为空或缺项的基线；继承的 `GIT_DIR`/`GIT_WORK_TREE` 会被清除。并发会话的已提交/未提交改动只记录、不回退。
4. **不重编内核**：Phase S 复用现有 `Image`/`fw_jump`；只换 rootfs 和（必要时）DTB。
5. **性能**：100MHz 单核、无 GPU；LVGL 必须用 16-bit、局部刷新、无重阴影/大透明，目标是“可演示”，不是 60fps。

---

## 6. 架构

### 6.1 工程结构

```
D:\code\PDS\YeshenGui\
  README.md
  docs/superpowers/specs/2026-10-28-debian-style-touch-gui-design.md
  ui\                       # 平台无关：LVGL 桌面、窗口、应用、游戏
    app.c / app.h
    theme.c / theme.h
    desktop.c / desktop.h
    wm.c / wm.h
    apps\
      system_info.c
      files.c
      settings.c
    games\
      game2048.c
      minesweeper.c
      snake.c
      game_core.h
  platform\
    platform.h              # display/input/time 抽象
    host_sdl.c              # 主机：SDL2 窗口 + 鼠标
    board_fb.c              # 板端：/dev/mem 帧存
    input_uart.c            # 板端 Phase S：串口键盘
    input_demo.c            # 板端 Phase S：自动演示
  host\
    CMakeLists.txt          # 主机模拟器构建（LVGL + SDL2）
  board\
    rootfs_overlay\         # 新镜像追加的文件（yshell、assets、S99gui.sh）
    dtb\                    # 必要时的新 DTB（16MiB initrd 窗口）
    mk_sd_gui.py            # 新 SD 镜像打包（只写 images/sd_gui.img）
  tests\
    test_game2048.c
    test_minesweeper.c
    test_snake.c
  scripts\
    build_host.sh
    build_board_app.sh
    build_board_image.sh
    fetch_lvgl.sh
    verify_isolation.sh
    test_isolation.sh
    test_fetch_lvgl.sh
  third_party\
    PINS.md                 # LVGL 版本/来源锁定
  images\                   # 构建产物（不入库）
  build\                    # 主机/交叉编译产物（不入库）
```

### 6.2 平台抽象

UI 不直接碰 SDL、`/dev/mem`、UART 或 evdev。唯一接口：

```c
typedef struct {
    int width, height;
    uint16_t *pixels;   // RGB565
    int stride_px;
} ui_surface_t;

void     platform_init(int width, int height);
void     platform_flush(const ui_surface_t *surface,
                        int x1, int y1, int x2, int y2);
uint32_t platform_time_ms(void);
void     platform_delay_ms(uint32_t ms);

/* Phase S 板端返回 false；host 把鼠标映射为单点触摸 */
bool     platform_poll_touch(int *x, int *y, bool *pressed);

/* Phase S 板端 UART 键盘；host 可用于调试 */
bool     platform_poll_key(ui_key_t *key);
```

- `ui/` 只依赖 `platform.h` 和 LVGL。
- 主机：`platform_flush` 把 LVGL 像素拷进 SDL2 纹理；`platform_poll_touch` 返回鼠标坐标/按下。
- 板端 Phase S：`platform_flush` 把像素写到 DDR 帧存的两个 bank（见 §6.4）；`platform_poll_touch` 恒 false；`platform_poll_key` 读 UART 或自动演示。
- 板端 Phase R：`platform_poll_touch` 从 `/dev/input/eventX` 读 goodix 事件；`platform_flush` 改为写后 bank + bank flip。

### 6.3 主机模拟器（Phase S 主验收）

- 环境：WSL（Ubuntu）+ SDL2 + WSLg；1024×600 窗口，鼠标左键按下/拖动/抬起映射成单点触摸。
- **S0 门**：必须先验证 WSLg 能显示 SDL2 窗口；若不能，停止并报告，不进入 UI 开发。
- 支持 `--demo` 自动巡演、`--screenshot <path>` 输出 PPM/PNG，用于验收与回归。
- 主机侧也可以用键盘驱动 UI（Tab/方向键/Enter/Esc），便于无鼠标调试；这不是交付要求。
- 主机与板端共用 `ui/`、游戏 core、字体/主题/资源；只链接不同的 platform。

### 6.4 板端 Phase S 运行时

- 镜像：现有 `fw_jump`/`Image`/DTB + 新 rootfs；新文件 `images/sd_gui.img`。
- 启动：保留 getty 在 ttyS0；默认**不自动启动** GUI，避免与登录争用串口。用户登录后执行：
  - `/root/gui/yshell`：交互模式，读 ttyS0 键盘；
  - `/root/gui/yshell --demo`：无人值守自动巡演，适合上板展示。
- 可选 `S99gui.sh`：仅当 `/etc/y1gui.autostart` 存在时启动 `yshell --demo`；默认不创建该文件。
- 显示：`yshell` 打开 `/dev/mem`，映射 `0x9000_0000` 与 `0x9100_0000`；LVGL flush 把 1024×600 RGB565 写到两个 bank 的第 60–659 行。Phase S 无 bank flip，两个 bank 都写，保证不管 LCD 当前读哪个 bank 都能看到；不保证无撕裂。
- 输入：UART 键盘（Tab/方向键/Enter/Esc/快捷字母）或 `--demo`；无触摸。
- **板端显示验收前提**：拔掉 J10 相机模组，让相机写侧不启动；若 LCD 仍显示桌面，则通过；若 LCD 不扫描/不显示，则记录“Phase S 板端显示 blocked”，把显示验收推迟到 Phase R，主机模拟器仍是 Phase S 的 UI 验收。**不允许**在相机连接、画面被覆盖时谎报通过。
- 不启动 y1cam；新 rootfs 的 staging 副本中移除 `S99y1cam.sh`；原 rootfs 不动。
- **“GUI 默认、可切相机”是 Phase R 的产品行为**；Phase S 只提供手动启动与 `--demo`，因为无触摸、且要避免与串口 getty 争用。

### 6.5 隔离与构建原则

- 新工程只读原工程：
  - 读取 `VexiiYeshenLinux/sw/images/{Image,fw_jump.bin,linux.dtb,rootfs*.cpio}`、`sw/buildroot-external/...` 的 DTS/脚本作为参考；
  - 读取 WSL 的交叉工具链；
  - **不写** `VexiiYeshenLinux` 下任何路径。
- 新 rootfs 从现有 known-good rootfs 解包（WSL 内，保留模式/属主），加 `board/rootfs_overlay/`，再打 `rootfs_gui.cpio.gz`。
- 新 SD 镜像只写 `YeshenGui/images/sd_gui.img`；绝不覆盖 `VexiiYeshenLinux/sw/images/sd.img`。
- 构建前后运行 `scripts/verify_isolation.sh`：
  - `git -C VexiiYeshenLinux rev-parse HEAD` 与基线一致；
  - `git -C VexiiYeshenLinux status --porcelain`（staged/unstaged/untracked）与基线逐字一致；
  - tracked 文件的 index OID（`git ls-files -s` 的 mode/OID/stage/path）与基线一致；不 hash 工作区字节，避免原工程 `core.autocrlf=true` + CRLF 混合造成假警报；
  - 关键 artifact（六个 `sw/images/{Image,fw_jump.bin,linux.dtb,rootfs.cpio,rootfs_v2.cpio,sd.img}` 文件必须全部存在，`deliver/sbits/*.sbit` 存在时一并记录）sha256 与基线一致；check 拒绝为空或缺少任一必需项的基线；
  - check 模式只读：`GIT_OPTIONAL_LOCKS=0`，不刷新、不写入原工程 `.git/index`；
  - 若发现并发会话改动原工程（HEAD 移动，或 status/index/artifact 变化），停止并报告，不回退别人的改动；经用户确认后重新 `--record` 基线。

### 6.6 Phase R 边界（后续）

Phase R 新建独立 RTL 工程/变体，**不修改原 Vexii**。预期改动：

- 顶层/FDC：CTP `SCL/SDA/RST/INT`（AF22/AE22/AD21/AE21）+ KEY3（A22）；GPIO 位映射 SCL=8、SDA=9、RST=10、INT=11、KEY3=12。
- GPIO 控制器加最小 gpiochip 驱动（支持开漏模拟）；DTS 加 `i2c-gpio` + `goodix@5d` + 固定 3.3V regulator；内核开 `GPIOLIB/I2C/INPUT/EVDEV/GOODIX`；CTP_INT 接 PLIC 源 5。
- `video_regs` 加 `GUI_CTRL`：`freeze`、`gui_bank`、`active_bank`、`vsync_count`；`rd_buf` 读 bank 在 LCD 帧边界锁存；GUI 双缓冲。
- GUI 默认；Camera 应用切到相机/NPU；返回 = 左上角长按 2 秒 + KEY3。
- 同一套 `ui/` 只换 platform 的 touch/flush 实现；R0 先做触摸冒烟，再集成桌面。
- Phase R 的完整设计在单独的 Phase R spec 中给出。

---

## 7. 桌面 UI 设计

### 7.1 画布与布局

- 画布 1024×600；顶部面板 40px；底部任务栏 36px；桌面区 1024×524。
- 触摸目标最小 48×48px；正文 14px，按钮 16px，标题 20px，时钟/分数 24px。

```
┌──────────────────────────────────────────────────────────────┐
│ (红色漩涡) Applications  Games  Files  System  Settings   CPU 12% MEM 38%  14:32 │ 40
├──────────────────────────────────────────────────────────────┤
│  ┌────────┐   ┌──────────────────────────────────────────┐   │
│  │ Files  │   │ 2048                              —  ×   │   │
│  ├────────┤   │  ┌────┬────┬────┬────┐                 │   │
│  │ System │   │  │ 2  │ 4  │ 8  │ 16 │                 │   │
│  ├────────┤   │  ├────┼────┼────┼────┤                 │   │
│  │ Games  │   │  │ ...│    │    │    │                 │   │
│  ├────────┤   │  └────┴────┴────┴────┘                 │   │
│  │Settings│   │  Score 1024              [New Game]     │   │
│  ├────────┤   └──────────────────────────────────────────┘   │
│  │ Camera │                                                  │
│  └────────┘                                                  │
├──────────────────────────────────────────────────────────────┤
│ [2048] [Files]                              Show Desktop      │ 36
└──────────────────────────────────────────────────────────────┘
```

### 7.2 顶部面板 / 桌面 / 任务栏

- 顶部面板：左侧 Debian 风格漩涡 + `Applications`；中间快捷启动 `Games / Files / System / Settings`；右侧 `CPU xx%`、`MEM xx%`、`HH:MM`。CPU/内存每 2 秒刷新；时钟每分钟。
- 桌面图标：左侧 2 列 × 3 行，96×96px 磁贴 + 标签：`Files`、`System`、`Games`、`Settings`、`Camera`（`Phase R` 徽标）。
- 底部任务栏：运行中的窗口按钮、`Show Desktop`；点击窗口按钮聚焦/最小化；无窗口时只显示 `Show Desktop` 和版本号。
- Applications 菜单：左侧 320px 滑出；分组 `Games / Accessories / System`；每行 56px，图标 + 英文名；点空白处关闭。

### 7.3 窗口管理

- 窗口固定 900×460，居中；标题栏 36px，左侧标题，右侧 `—`（最小化）和 `×`（关闭），命中区 48px。
- 拖动标题栏移动；点击窗口聚焦；最多同时 3 个窗口；新窗口置顶；关闭后焦点回到上一个窗口。
- 游戏窗口最大化到桌面区（1024×524 内，保留 8px 边距）；应用窗口固定 900×460。
- 不做自由缩放、不做贴边、不做多桌面；这些对 7 寸触屏不是必需。

### 7.4 主题

默认 **Debian Light**，Settings 可切 **Dark**。

| 元素 | Debian Light | Dark |
|---|---|---|
| 壁纸底 | `#121820` 深墨蓝 + 右侧低对比红漩涡 | 同左，漩涡更暗 |
| 顶部面板/任务栏 | `#E9EDF2` | `#1F2933` |
| 面板文字 | `#1F2933` | `#F5F7FA` |
| 窗口背景 | `#F7F9FC` | `#2B3440` |
| 窗口边框 | `#C9D1DB` | `#3E4C59` |
| 标题栏 | `#DDE3EA` | `#34414F` |
| 正文文字 | `#1F2933` | `#F5F7FA` |
| 强调色 | `#A80030` | `#E5484D` |
| 成功/警告 | `#2E7D32` / `#E0A100` | `#4CAF50` / `#FFC107` |

- 窗口 8px 圆角、1px 边框、无重阴影；大面积不透明，避免 alpha 混合拖慢 100MHz CPU。
- 壁纸为静态 1024×600 RGB565 资源，放在 `ui/assets/`；提供 `Debian Ink`（默认深色）与 `Debian Paper`（浅色）两张，由 Settings 切换；rootfs gzip 后计入预算。
- Debian 品牌仅作“风格参考”：使用自绘红色漩涡，不宣称是 Debian 官方发行版；System Info 里写 `Vexii Debian-style Desktop`。

### 7.5 字体与图标

- 字体：LVGL 内置 Montserrat 14/16/20/24；英文 ASCII；不引入 CJK 字体。
- 图标：LVGL 内置符号 + 5 个 56px 圆角色块（白符号，嵌在 96×96 磁贴内）：
  - Files：文件夹符号，蓝色底；
  - System：信息/芯片符号，灰色底；
  - Games：游戏手柄/播放符号，红色底；
  - Settings：齿轮，灰蓝底；
  - Camera：摄像机，绿色底 + 右上 `Phase R` 小徽标。
- 不引入大 PNG 图标集；壁纸除外。图标用 LVGL 绘制，缩放清晰、内存小。

### 7.6 应用

#### System Info

- 布局：两列信息卡；每行 `label: value`，14px；顶部一个 Debian 风格漩涡 + `Vexii Debian-style Desktop`。
- 内容：CPU 频率（构建时板级常量 100MHz）、CPU 负载（`/proc/loadavg`）、内存 `MemTotal/MemAvailable`、uptime、IP（`getifaddrs()` 读 IPv4）、MAC（`/sys/class/net/eth0/address`）、内核版本（`uname`）、板卡型号、固件/构建版本。
- 刷新：每 1 秒读一次；不阻塞 UI；读失败显示 `n/a`，不崩溃。

#### Files

- 布局：顶部面包屑（`/root` > `...`），下方列表，每行 48px：图标、名称、大小/修改时间；右侧可选预览区（文本文件前 20 行）。
- 根目录：默认 `/root`；可进入 `/etc`、`/`；只读；不提供删除/重命名/写文件。
- 样例文件：`/root/README.txt`、`/etc/os-release`、`/proc/version` 等；目录项用 LVGL 符号区分文件夹/文本/未知。
- 交互：点目录进入；点文本文件预览；`..` 返回上级；预览滚动。

#### Settings

- 分组：
  - **Appearance**：Theme（Light/Dark）、Wallpaper（`Debian Ink` 默认深色 / `Debian Paper` 浅色变体）。
  - **System**：Reboot、About。
  - **Phase R（灰显）**：Brightness、Camera switch，右侧标 `Phase R`，点击弹说明，不执行。
- About：版本、构建日期、LVGL 版本、原始 Vexii commit、免责声明“Debian-style demo, not Debian”。
- 设置只保存在内存（重启恢复默认）；不做持久化。

#### Camera（Phase S 占位）

- 桌面/面板入口保留，打开一个 900×460 的信息卡片：
  - 标题 `Camera / NPU Demo`
  - 说明 `Available in Phase R (requires RTL: camera freeze + touch)`。
  - 按钮 `Close`。
- Phase S 不启动 y1cam、不切相机、不冻结帧存。

### 7.7 交互与键盘兜底

- 触摸（Phase R）：单点；点按、拖动、长按；无多指手势要求。
- 键盘（Phase S 板端 UART / host 调试）：
  - `Tab` / `Shift+Tab`：焦点前进/后退；
  - 方向键：在图标/列表/棋盘内移动；
  - `Enter`：激活；
  - `Esc`：关闭窗口/返回上级；
  - `g` / `f` / `i` / `s`：打开 Games / Files / System / Settings；
  - `1` / `2` / `3`：打开 2048 / Minesweeper / Snake；
  - `q`：退出当前游戏到桌面；`Ctrl+C` 仅在**非终端焦点**时退出 yshell（终端聚焦时 Ctrl+C 送 PTY，见 §9.1）。
- 焦点环：2px 强调色描边 + 轻微底色，保证键盘可见；触摸点击也会设置焦点。
- 无 hover-only 交互；所有按钮按下有视觉反馈（颜色/缩放 100ms）。

### 7.8 性能预算

- LVGL 16-bit；2 个 draw buffer，每个 1024×40；`LV_DISP_DEF_REFR_PERIOD` 30ms。
- 静态桌面（时钟/CPU 更新）目标 ≥30fps；窗口拖动 10–15fps；Snake 8–10 tick/s；2048/Minesweeper 事件驱动。
- 动画 150ms；若连续 2 秒 FPS 低于目标，自动关闭窗口开关动画（不做重阴影/模糊）。
- 禁止大面积 alpha、禁止每帧重绘壁纸；窗口移动只重绘受影响区域。
- Phase S 板端写两个 bank，全屏 flush 约 2.4MB；用局部刷新限制到变化区域。

### 7.9 资源预算

- 新 rootfs gzip 后目标 ≤7.5MiB（现有 8MiB initrd 窗口留余量）。
- 若超过 7.5MiB：在 `board/dtb/` 生成新 DTB，把 `linux,initrd-end` 改到 `0x8400_0000`（16MiB 窗口），更新装载表；**不重编内核、不改 RTL**。
- LVGL + UI + 资源预计增加 3–5MiB；壁纸/字体/图标是主要项，必要时降低壁纸色深或改程序化壁纸。

---

## 8. 游戏设计

### 8.1 2048

- 棋盘 4×4；磁贴 80px、间距 8px；棋盘 360×360；窗口内容居中。
- 规则：标准 2048；每次移动所有磁贴向方向滑动并合并一次；新磁贴 2/4（90%/10%）；达成 2048 弹 `You win` + `Continue` / `Restart`；无合法移动弹 `Game over`。
- 操作：滑动（上/下/左/右）+ 四个 64px 方向按钮兜底；键盘方向键。
- 顶栏：`Score`、`Best (session)`、`New Game`。
- 视觉：暖色数字块（2 `#EEE4DA`、4 `#EDE0C8`、8 `#F2B179`、16 `#F59563`、32 `#F67C5F`、64 `#F65E3B`、128 `#EDCF72`、256 `#EDCC61`、512 `#EDC850`、1024 `#EDC53F`、2048 `#EDC22E`）；数字深色/浅色自动对比。
- 动画：合并/滑动 100ms；掉帧时瞬切。

### 8.2 Minesweeper

- 棋盘 10×10；30 颗雷；格子 36px；棋盘 360×360。
- 规则：首点安全（首点若是雷，把该雷移到第一个非雷格，保持雷数不变）；空白格 flood-fill 展开；数字 1–8；旗子；胜利 = 所有非雷格翻开；失败 = 翻到雷。
- 操作：点按翻开；长按 400ms 插旗/取消旗；键盘：方向键移动光标，`Enter` 翻开，`f` 插旗。
- 顶栏：`Mines left`、`Time`（秒）、`Reset`。
- 视觉：未翻开 `#B8C4D0`，已翻开 `#E9EDF2`，旗子红色，雷黑色；数字 1–8 用固定颜色；数字+颜色双编码。
- 无动画；胜负覆盖层带 `Play again`。

### 8.3 Snake

- 网格 20×15；格子 24px；棋盘 480×360；居中。
- 规则：撞墙/撞自己结束；吃食物 +1 长度、+10 分；每吃 5 个食物 tick 缩短 5ms（下限 80ms）；初始 130ms；暂停/继续。
- 操作：滑动（上/下/左/右）+ 屏幕 D-pad；键盘方向键；`p` 暂停。
- 顶栏：`Score`、`Speed`、`Pause`。
- 视觉：深色网格 `#1F2933`，蛇身 `#A80030`，蛇头 `#E5484D`，食物 `#2E7D32`；只重绘变化的格子（LVGL canvas 局部刷新）。
- 开始覆盖层：`Swipe or use D-pad to start`；结束覆盖层：`Game over` + `Restart`。

### 8.4 共享框架与测试

- 每个游戏拆成**纯逻辑 core**（不依赖 LVGL）和 **LVGL 前端**：
  - `game2048_core.c`：`init/seed/move/score/status`；
  - `mines_core.c`：`init/seed/reveal/flag/status`；
  - `snake_core.c`：`init/seed/set_dir/tick/status`。
- PRNG：xorshift32，固定 seed 可复现；Minesweeper 首点安全；2048 新磁贴用 PRNG；Snake 食物位置用 PRNG。
- 主机单元测试（`tests/`）：
  - 2048：初始两格、四方向移动/合并、单次合并、分数、无合法移动、New Game、达成 2048。
  - Minesweeper：首点安全、雷数、flood-fill、插旗、胜利、失败、Reset。
  - Snake：移动、吃食物、增长、撞墙、自撞、暂停/继续、速度变化。
- 前端只做绘制/输入映射；core 的测试不链接 LVGL。
- 会话内 Best 分数只存内存；重启清零。

### 8.5 游戏验收

- 主机模拟器上三款都能完整玩一局；鼠标/键盘均可操作。
- core 单元测试全绿；把任一规则改坏，对应测试必须红（负对照）。
- 退出/重开/暂停无软锁；Snake 不丢方向；Minesweeper 长按不误触翻格；2048 合并分数正确。

---

## 9. Phase S6：终端 + 英文屏幕键盘（后续）

> 本节是后续追加项；不进入 Phase S 首批实施计划，但 UI 架构（窗口、焦点、键盘层）要为它留位置。

### 9.1 终端

> **2026-10-29 结果：已实现。** 实际为 100×28 字符、LVGL 内置 `unscii_16`
> 等宽字体、200 行 scrollback；`t` 打开，`Ctrl+W` 关闭。主机
> `--terminal-test` 自动执行 `uname -a` 并截图；板端实测 `/dev/pts/0` 上
> 有 `sh` 子进程（PPid = yshell），UART 键盘输入和 LCD 显示均通过。

- 窗口：最大化到桌面区（1008×508，桌面区内）；顶部 36px 标题栏；打开时启动 `/bin/sh`。
- PTY：`posix_openpt` + `fork`（未用 `forkpty`）；父进程读写 master；子进程 `setsid`/`TIOCSCTTY`/`execve("/bin/sh")`。
- 终端缓冲：100 列 × 28 行可见；200 行 scrollback；LVGL `unscii_16` ASCII 等宽字体（8×16）。
- 最小 ANSI：可打印字符、`\n`、`\r`、`\b`、`\t`；剥离 CSI/OSC/字符集转义；不支持全屏 curses（`top`、`vi` 不作为验收）。
- 输入：屏幕键盘（Phase R 触屏，待做）/ host 键盘 / Phase S UART 键盘；Ctrl+C 发送 0x03，Ctrl+D 发送 0x04；方向键发送 `ESC [ A/B/C/D`。
- 焦点：终端聚焦时所有键进 PTY；`Ctrl+W` 关闭窗口，`c`/`t`/`q` 作为普通文本发给 shell。
- 退出：关闭窗口发送 SIGHUP/终止子进程；子进程退出显示 `[shell exited - Ctrl+W closes]`。

**验收证据（2026-10-29）：** `tests/test_terminal_core.c` 覆盖 CR/LF/BS/TAB/换行、
CSI/OSC 剥离、100 列折行、200 行 scrollback；主机 `--terminal-test` 输出
`uname -a` 截图；板端 `ps` 显示 `sh`（PPid yshell）且 fd0/fd1 指向
`/dev/pts/0`。板测通过 RAM 上传新 yshell，未改动卡片。

### 9.2 英文屏幕键盘

- 布局：底部 1024×240；QWERTY 三行 + 数字/符号行 + 功能行。
- 键尺寸 64×48px，间距 6px；功能键（Shift/Ctrl/Tab/Esc/Backspace/Enter/Space/方向键）加大。
- 仅英文 ASCII；Shift 切换大小写/符号；Ctrl 为粘滞键；无 Alt、无 CJK、无语音。
- 终端获得焦点时键盘滑出；关闭终端或点键盘上的 `Hide` 收起；键盘不遮挡当前输入行：OSK 弹出时终端内容区从 1024×524 缩到 1024×284（约 100×17 字符），输入行始终可见。
- 验收：用屏幕键盘/鼠标在终端输入 `ls`、`uname -a`、`ip addr`；Ctrl+C 中断 `sleep 100`；方向键历史可用；无软锁。

### 9.3 约束

- 不修改内核；PTY/`/bin/sh` 由现有 busybox 提供。
- Phase S 板端无触摸时，终端可用 UART 键盘；屏幕键盘在 host 模拟器和 Phase R 触屏上验收。

---

## 10. 构建与打包

### 10.1 主机模拟器

- `scripts/build_host.sh`：WSL 内 `cmake -S host -B build/host` + `make -j`；链接 LVGL（`third_party/lvgl`）与 SDL2；产物 `build/host/yshell_host`。
- LVGL 版本：**LVGL 9.2.x**；S0 在 `third_party/PINS.md` 固定 release tag、来源 URL 与 commit OID，不允许浮动；`fetch_lvgl.sh` 要求 tag 与 HEAD 都等于该 OID 且 tracked 工作树干净。
- 运行：`build/host/yshell_host`；鼠标左键 = 触摸；`--demo` 自动巡演；`--screenshot out.ppm` 截图。
- S0 门：WSLg 显示 1024×600 窗口成功；失败则停止并报告，不进入 S1。

### 10.2 交叉编译

- 工具链（只读）：`$HOME/vexii-build/buildroot/output/host/bin/riscv64-buildroot-linux-uclibc-gcc`。
- `scripts/build_board_app.sh`：`-O2 -march=rv32imac -mabi=ilp32`；LVGL 静态链接；产物 `board/rootfs_overlay/root/gui/yshell`。
- 不链接 SDL2；板端只用 `platform/board_fb.c` + `input_uart.c` + `input_demo.c`。
- 检查 `readelf -h` 的 Machine/Flags 与现有用户态一致；`strings` 冒烟检查版本串。

### 10.3 新 rootfs 与 SD 镜像

`scripts/build_board_image.sh` 在 WSL 内执行：

1. **基线对账**：运行 `scripts/verify_isolation.sh`，记录原工程 HEAD、`git status`（默认模式，未跟踪目录折叠为一行）、tracked 文件的 index OID（`git ls-files -s`）与 52 个关键输入 artifact sha256（6 个 `sw/images` 必须全部存在，加 `deliver/sbits/*.sbit`；不展开全部 `sw/images`，`build/` 内容不在范围；嵌套仓库/无 artifact 的 worktree/fresh clone 不能 `--record`）；check 模式只读（`GIT_OPTIONAL_LOCKS=0`，不写原工程 `.git/index`）；`--root` 必须是 worktree 根（子目录、`.git` 目录或 bare repo 直接拒绝）；任何预先存在的并发改动只记录、不回退。
2. **复制输入**：从 `VexiiYeshenLinux/sw/images/` 复制当前 v2 卡的 known-good 组件：`Image`、`fw_jump.bin`、`linux.dtb`、`rootfs_v2.cpio`（v2 卡 rootfs 基线；S0 用启动 marker 确认它与当前 `sd.img` 一致，并记录 sha256）到 `YeshenGui/images/`。
3. **解包 rootfs**：在 WSL 原生文件系统（`$HOME/yeshen-gui-build/rootfs`）解包 cpio；保留模式/属主；确认 `/init` 与 `/bin/sh` 存在且可执行。
4. **应用 overlay**：复制 `board/rootfs_overlay/` 到 staging；移除 staging 中的 `etc/init.d/S99y1cam.sh`（只删副本）；保留 getty/ssh；加入 `/root/gui/yshell`、`/root/gui/assets/`、可选 `S99gui.sh`。
5. **打 cpio**：`find . | cpio -o -H newc | gzip -9 > images/rootfs_gui.cpio.gz`；回读 mode，确保 `/init`、`/bin/sh`、`yshell` 为 0755。禁止在 Windows 侧打 cpio（会丢 x 位）。
6. **DTB**：若 `rootfs_gui.cpio.gz` > 7.5MiB，复制现有 DTS，改 `linux,initrd-end = 0x84000000`，用 `dtc` 生成 `images/linux_gui.dtb`；否则复用现有 DTB。
7. **新 SD 镜像**：`board/mk_sd_gui.py` 按现有装载表格式生成 `images/sd_gui.img`，只写该文件；装载表条目：`fw_jump@0x80000000`、`Image@0x82000000`、DTB@`0x82F80000`、rootfs@`0x83000000`。块数与文件大小一致。
8. **隔离复核**：再次运行 `verify_isolation.sh`；原工程 HEAD/status/index OID/关键输入 artifact hash 必须与基线一致。若不一致，停止并报告（不回退并发改动；不要在未确认时自动重录，经用户确认后才重新记录基线）。

### 10.4 板端运行

- 将 `images/sd_gui.img` 写到**另一张** TF 卡（不覆盖现有相机卡）；插卡、上电、串口登录。
- 运行 `/root/gui/yshell`（交互）或 `/root/gui/yshell --demo`（自动巡演）。
- 板端显示测试：拔掉 J10 相机模组；观察 LCD 是否显示桌面；串口日志应有 `YGUI-BOOT` 与 `YGUI-FB-OK` 标记。
- 若相机连接：画面会被相机覆盖，这是已知限制；不要把它当作 GUI 失败或成功。

---

## 11. 测试与验收

### 11.1 主机

- **单元测试**：`tests/` 三个 core 测试；`ctest`/`make test`；固定 seed；负对照改坏规则必须红。
- **UI 冒烟**：`yshell_host --demo` 自动打开/关闭每个应用和游戏；`--screenshot` 保存关键界面（桌面、Applications、2048、Minesweeper、Snake、System、Files、Settings）；检查无崩溃、无 LVGL assert。
- **性能**：FPS 计数、帧时间；静态桌面 ≥30fps，拖窗 ≥10fps；低于目标时记录并降动画。
- **键盘**：Tab/方向/Enter/Esc/快捷键可完成所有主要操作。

### 11.2 板端 Phase S

- 串口 marker：`YGUI-BOOT`（进程启动）、`YGUI-FB-OK`（帧存 mmap/首帧写入）、`YGUI-EXIT`（正常退出）。
- 进程存活：`ps` 能看到 `yshell`；无崩溃重启循环。
- 显示：拔 J10 后 LCD 显示桌面；若失败，记录 `BOARD-DISPLAY-BLOCKED`，显示验收推迟到 Phase R。
- 隔离：`verify_isolation.sh` 仅在基线与当前状态对齐时通过（HEAD/status/index OID/52 个关键输入 artifact hash 与 S0 基线一致，六个 `sw/images` 输入必须齐全，check 模式不写原工程 `.git/index`）；若并发会话改了原工程，检查会红，记录并报告，经用户确认后才重新对齐基线，不回退。
- 现有相机镜像/bitstream：未重烧、未覆盖；用 sha256 证明。

### 11.3 负对照

- 把 2048 合并规则改坏 → 对应单元测试必须红。
- 把 Minesweeper 首点安全去掉 → 测试必须红。
- 把 Snake 撞墙判定去掉 → 测试必须红。
- 在**临时副本**的 worktree 根上改一个文件，用 `verify_isolation.sh --root <temp-copy>` 检查 → 必须红；**不修改原工程**。
- 相机连接时覆盖 → 记录为“已知限制”，不算通过；拔相机后显示才可判过。

### 11.4 Phase S 验收清单

- [ ] 主机模拟器 1024×600 可运行，桌面/三游戏/三应用全部可用。
- [ ] 游戏 core 单元测试全绿，负对照会红。
- [ ] 板端 `sd_gui.img` 能启动；运行 `yshell` 后打出 `YGUI-BOOT`。
- [ ] 拔相机时 LCD 显示桌面（或记录 `BOARD-DISPLAY-BLOCKED` 并明确延期）。
- [ ] 本项目对原 `VexiiYeshenLinux` 零写入；HEAD/status/index OID/52 个关键输入 artifact hash 与 S0 基线一致（并发会话改动只记录，不回退）。
- [ ] 现有 `sd.img`/bitstream 未被覆盖。
- [ ] 触摸明确标为 Phase R，未在 Phase S 声称可用。

---

## 12. 里程碑

| 里程碑 | 交付物 | 门 |
|---|---|---|
| **S0** | 新工程骨架、LVGL 锁定、WSLg+SDL2 窗口、平台接口、隔离脚本 | 主机窗口能显示；原工程 HEAD/status/index OID/52 个关键输入 artifact hash 基线记录；否则停止 |
| **S1** | 桌面壳：壁纸/面板/桌面图标/窗口管理/Applications/Light-Dark | 主机截图通过；无 LVGL assert |
| **S2** | System Info / Files / Settings / Camera 占位 | 三个应用可打开/关闭；读失败不崩溃 |
| **S3** | 2048 / Minesweeper / Snake + core 单元测试 | 三款可玩；测试全绿；负对照红 |
| **S4** | 新 rootfs + `sd_gui.img` + 板端启动/显示测试 + 隔离复核 | 运行 `yshell` 后 `YGUI-BOOT`；拔相机显示通过或记录 blocked；本项目对原工程零写入、基线一致 |
| **S5** | 性能/触摸目标/主题/稳定性打磨 | 达到 §7.8 预算；验收清单全过 |
| **S6**（后续） | 终端 + 英文屏幕键盘 | §9.2 验收 |
| **R0–R3**（后续） | 独立 RTL 变体：触摸冒烟 → freeze/bank → 集成 → 相机切换 | 单独 Phase R spec/plan |

---

## 13. 风险与缓解

| 风险 | 影响 | 缓解 |
|---|---|---|
| WSLg/SDL2 不可用 | 主机模拟器无法显示 | S0 先验证；失败则停止并报告，换 host 显示方案前不写 UI |
| 现有交叉工具链/镜像缺失 | 板端镜像无法构建 | S0 记录工具链与镜像 sha256；缺失则从原工程只读复制/重装，不修改原工程 |
| 相机连接时覆盖帧存 | 板端看不到 GUI | 拔 J10 做 Phase S 显示测试；正式解决在 Phase R 的 freeze/bank |
| LCD 在无相机时不扫描 | Phase S 板端显示 blocked | 明确记录并延期到 Phase R；主机模拟器仍是 UI 验收 |
| rootfs 超过 8MiB | 装载失败 | 目标 gzip ≤7.5MiB；超出则新 DTB 16MiB 窗口；不重编内核 |
| LVGL 在 100MHz 下慢 | 界面卡顿 | 16-bit、局部刷新、无重阴影/大透明、自动关动画；必要时降低壁纸复杂度 |
| 终端 ANSI 复杂 | S6 终端不兼容全屏程序 | 只做行式 + 最小 ANSI；验收限定 `ls`/`uname`/`ip`/`cat`；文档写明 |
| Phase R 触摸栈集成失败 | 触屏不可用 | R0 先做 `/dev/input/eventX` 冒烟；失败则回退到 RTL I2C/用户态方案（Phase R 重新决策） |
| 原工程被并发会话修改 | 隔离检查误报 | 只记录、不回退；与用户确认后再继续；本项目不写原工程 |
| 板端/主机字体/资源不一致 | 视觉差异 | 字体/资源放在 `ui/assets/`，两端共用；S1 截图对账 |

---

## 14. 假设

1. 主机有可用的 WSL + SDL2 + WSLg，能显示 1024×600 窗口。
2. 原工程的交叉工具链与 known-good `Image`/`fw_jump`/DTB/rootfs 在构建时可用；构建只读它们。
3. 用户有另一张 TF 卡可用于 `sd_gui.img`，不会覆盖现有相机卡。
4. 板端 Phase S 显示测试可以拔掉 J10 相机模组；若不允许拔，板端显示验收自动延到 Phase R。
5. 原工程在构建期间可能被并发会话改动；`verify_isolation.sh` 会发现 HEAD/status/index OID/52 个关键输入 artifact hash 变化并停止；check 模式只读（`GIT_OPTIONAL_LOCKS=0`）；经用户确认后重新记录基线，不回退别人的改动；`--root` 只接受 worktree 根（不是子目录或 `.git` 目录），且 `--record` 要求六个 `sw/images` 关键输入全部存在。
6. 本机 Git 提交使用单次环境变量注入既有作者身份，不修改全局/仓库 config。

---

## 15. 参考

- 原始工程：`D:\code\PDS\VexiiYeshenLinux`
  - 视频链：`board/cam/video_passthrough.v`、`board/cam/video_regs.v`
  - 帧存/显示：`docs/reports/camera-switch.md`（`0x90000000` 采样、bank 跨度 16MiB）
  - 启动脚本：`sw/buildroot-external/boards/naxmini/linux/rootfs_overlay/etc/init.d/S99y1cam.sh`
  - DTS：`sw/buildroot-external/boards/naxmini/linux/linux_raw.dts`
  - 构建：`scripts/build_images.sh`、`scripts/build_all.sh`
- 硬件测试（触摸/引脚）：`D:\code\PDS\docs\盘古676-200mini-硬件约束与上板测试报告.md`
- GT911 探测实现：`D:\code\PDS\hw_test_200mini\rtl\i2c_probe.v`
- 既有 I2C/GPIO 参考：`VexiiYeshenLinux/src/peripheral/GPIO.scala`

---

## 16. 术语

- **Phase S**：无 RTL、独立镜像 + 主机模拟器的软件阶段。
- **Phase S6**：终端 + 英文屏幕键盘的后续软件阶段。
- **Phase R**：独立 RTL 变体，加入触摸、GUI freeze/bank、相机切换。
- **known-good**：当前板上已经验证能跑相机/NPU/Linux 的镜像/比特流组合。
- **bank**：DDR 帧存的两个 16MiB 分区；LCD 读其中一个，相机写另一个。
