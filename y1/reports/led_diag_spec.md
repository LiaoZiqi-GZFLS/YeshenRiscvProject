# LED 诊断口 spec（led[7:0] = 3 硬件事实 + 4 软件位 + 网口）

日期：2026-10-23。状态：**设计定案，RTL/FDC 已改，PnR 待跑，未上板**。

## 目标

让肉眼可见的板载 LED 反映「SD 装载 → Linux 活着 → 业务在跑」这条链，
同时不丢现有的硬件事实位。用户口径：**led0~4 明显可见**，其余可能偏暗。

## 引脚（官方依据，不猜）

| LED | 引脚 | 依据 |
|---|---|---|
| led[0] | A20 | 官方 2_7/2_8 `led[0]`；手册 P36 LED0 |
| led[1] | C18 | 官方 2_7/2_8 `led[1]`；手册 P36（手册记作 LED2） |
| led[2] | C19 | 官方 2_7/2_8 `led[2]`；手册 P36（手册记作 LED1） |
| led[3] | E18 | 官方 2_7/2_8 `led[3]`；手册 P36 LED3 |
| led[4] | A17 | 官方 2_7/2_8 `led[4]`（fdc 末段注释原文，本工程此前不用） |
| led[5] | A18 | 同上 `led[5]` |
| led[6] | C17 | 同上 `led[6]` |
| led[7] | B17 | 同上 `led[7]` |

- 极性：**高 = 亮**（既有 led[0]=pll_lock 上板即亮 ⇒ 已实证，不另立假设）。
- A17/A18/C17/B17 在现 fdc 里只出现在注释段（全量扫描 A17/A18/C17/B17 各 1 次）⇒ 与
  DDR/CAM/LCD/TF/UART 引脚无冲突（PDS 的 LOC 重复会直接报错，是硬判据）。
- 引脚表以官方 .fdc 为准；**led[5..7] 是否真的焊了灯待上板目视**（不影响功能）。

## 语义（定案）

| 灯 | 来源 | 含义 |
|---|---|---|
| led[0] | `pll_lock_100m`（硬件） | 板级 PLL 锁定。常亮 = 时钟树活着 |
| led[1] | `ddr_init_done`（硬件） | DDR3 初始化完成 |
| led[2] | `load_active`（硬件） | SD/UART 装载器当主人（CPU 被扣复位）。亮 = 正在从卡装载 |
| led[3] | **GPIO[0]（软件心跳）** | Linux 1 Hz 翻转。**闪 = 内核在跑；定住 = 内核挂/死循环** |
| led[4] | **GPIO[1]（软件）** | y1cam（YuNet 循环）进程在跑 |
| led[5] | **GPIO[2]（软件）** | NPU 最近一帧 done（y1cam 每帧翻转一次） |
| led[6] | **GPIO[3]（软件）** | 网络就绪（`eth0` operstate=up，含 ssh 可用） |
| led[7] | `eth_rgmii_alive`（硬件） | PHY 的 RXC 在翻转（PHY 侧时钟活着） |

上电默认：led[0] 随 PLL 亮、led[1] 随 DDR 亮、led[2] 装载期亮；GPIO 复位值 0 ⇒ led[3..6] 全灭，
直到 Linux 写 GPIO。**"全灭"本身就是诊断信息**（内核没起到用户态）。

## 软件接口（GPIO 已在 SoC 内，无需新 RTL 寄存器）

`GPIO_BASE = 0xF000_2000`（`src/YeshenSocGlue.scala:61`），寄存器（`src/peripheral/GPIO.scala`）：

| 偏移 | 名称 | 用法 |
|---|---|---|
| +0x04 | DATA_OUT | 低 8 位 = 引脚输出 |
| +0x08 | DIRECTION | 写 0xFF ⇒ 低 8 位全输出 |

板级只把 SoC 的 `gpio_out[7:0]` 接到 LED（见改法），`gpio_in` 仍拉 0。

- 引导脚本 `/etc/init.d/S99leds.sh`（新增，0755）：
  - `devmem 0xF0002008 32 0xFF`（方向）；`devmem 0xF0002004 32 <v>`（输出）；
  - 每 500 ms 采一次状态：心跳位按秒翻转；y1cam pid 存活 ⇒ bit1；`/sys/class/net/eth0/operstate=up` ⇒ bit3；
  - NPU 帧完成位 bit2 由 y1cam 自己写（它知道每帧结束），脚本**只读不抢**该位 —— 两个写者会互相覆盖，
    因此 **bit2 也归脚本**：脚本读 y1cam 的计数文件 `/run/y1cam.frames`，变化即翻转 bit2。单一写者。
  - 脚本自身失败不影响系统（busybox devmem 不在就静默退出，kmsg 记一行）。

## 改法（改动面）

1. `board/yeshen_mini_board_top.v`：端口 `output wire [3:0] led` → `[7:0]`；
   `.gpio_out()` / `.gpio_dir()` 改成接 `wire [7:0] gpio_out / gpio_dir`；
   `assign led = {eth_rgmii_alive, gpio_out[3:0], load_active, ddr_init_done, pll_lock_100m}`。
2. `constraints/yeshen_mini.fdc`：取消末段 led[4..7] 注释（官方 LOC），头部注释同步为 led[7:0]。
3. rootfs：新增 `etc/init.d/S99leds.sh` + y1cam 写 `/run/y1cam.frames`（若 y1cam 尚无该文件，脚本
   退化为只看 pid，bit2 保持灭 —— **不阻塞**）。
4. **不需要**改 Scala/glue：GPIO 外设与 AXI-Lite 解码早已存在，本次只是把它的输出接出来。

## 验收（上板时）

1. PnR：`led[4..7]` 有 LOC、无重复；时序不劣化（soc 域 WNS 不低于改动前）。
2. 不上电即可判：**改前后 `led[3:0]` 的既有三灯行为完全不变**（PLL/DDR/loader）。
3. 上板：
   - 断电 → 上电：led[1] 在 DDR 初始化后亮；装载期 led[2] 亮；进 Linux 后 led[2] 灭、led[3] 开始 1 Hz 闪。
   - 用户态写 GPIO 位图（`devmem 0xF0002004 32 0x0F`）⇒ led[3..6] 同亮；写 0 ⇒ 同灭（正对照）。
   - 负对照：`kill -STOP` 掉 S99leds ⇒ 心跳定住；`kill` y1cam ⇒ led[4] 灭。
4. 网络位：拔网线 ⇒ led[6] 灭；插回 ⇒ 亮（`operstate` 判据，不用 ping）。

## 静态自检（2026-10-23，已跑）

- **端口 ↔ 引脚集合**：顶层 49 个端口名 vs FDC 49 个 `p:` 基名，**两边差集为空**；
  `led` 的 0..7 八只全部有 LOC（A20/C18/C19/E18/A17/A18/C17/B17），其余总线索引完整。
- **dev_map**（tag led1）：0 error，LUT 83,703.5/159,800（53%）、FF 115,026（36%）、
  APM 263/740（36%）、**DRM 305/415（74%）**、IO **146/400**（改前 142，+4 即新增 led[4..7]）。
- 极性：led0=PLL lock 在改前板上即常亮 ⇒ 高有效；本次语义未动 led[0..2]。
- `sh -n` 两条开机脚本通过；`rcS` 是 `. S*.sh` 源执行 ⇒ S99leds 的循环已在后台子进程里（否则 init 卡死）。
