# GT911 电容触摸搬进主线（2026-10-30）

> 目标：主线（`VexiiYeshenLinux`）自己带触摸，不再依赖 `YeshenGuiTouch` 那份独立 RTL。
> 触摸链路本来就已在 `YeshenGuiTouch` 上板验过（`sd_gui_touch.img` + sbit `85dbe37d…`），
> 这里做的是**把它按主线现状重做一遍**（主线的 GPIO/PLIC 与那份副本已有差异），
> 四层同改：胶合源码 → 板级 → 约束 → 内核。

## 1. 四个 GPIO 位与四个引脚（与 YeshenGuiTouch 逐格相同）

| 信号 | 引脚（J26） | 方向 | RTL 实现 | GPIO 位 |
|---|---|---|---|---|
| CTP_INT | AE21（33） | 输入，低有效 | `soc_clk` 2FF → **反相** → PLIC 源 5 | bit11（回读原样=低有效） |
| CTP_RST | AD21（34） | 输出 | `gpio_out[10]` 直驱 | bit10 |
| CTP_SCL | AF22（35） | **推挽** | `gpio_dir[8] ? gpio_out[8] : 1'bz` | bit8 |
| CTP_SDA | AE22（36） | **真开漏** | `(gpio_dir[9] && !gpio_out[9]) ? 1'b0 : 1'bz` | bit9 |

- SCL 必须**推挽**：面板 J26 侧没有 SCL 上拉，纯开漏永远拉不起（YeshenGuiTouch 实测）。
  `gpio-yeshen-ctp.c` 在 SCL 是输出时把"驱动值"回读给 i2c-algo-bit（IOB 不回环）。
- SDA 保持真开漏：高=切输入，才能读到面板 ACK。
- KEY3（A22）本板丝印未接 ⇒ bit12 恒 0（保留位，不引 `gpio-keys`）。

## 2. RTL 改法（胶合**源码**改 + 重生成，不手改网表）

1. `src/peripheral/PlicAlite.scala`：`NDEV 4→5`、新增 `ctpIrq` 输入 → `srcIn(5)`。
   CLAIM 候选位宽本来就是 3 bit（`i.U(3.W)`），源 5 不需要再加宽。
2. `src/YeshenSocGlue.scala`：新增 `io.ctpIrq`；裸 GPIO 端口 **8→13 位**
   （原来只有 `gpio_out[7:0]` 出胶合，bit8..12 恒 0 —— 这一步不做，CTP 的 SCL/SDA/RST
   永远推不动）。
3. `rtl/YeshenSocGlue.v` 重生成。**先证生成链可复现**：改任何东西之前把当前源码重生成
   一遍，与已提交网表 sha256 相同（`30e5f80e…`）⇒ 之后 diff 里的每一行都能归因到本轮改动。
   本次净变化 120/94 行，全部落在 PLIC 的 priority/enable/pending/claim 与 GPIO 端口宽度上。

板级（`board/yeshen_mini_soc.v` / `board/yeshen_mini_board_top.v`）：
- Soc 包装层 `gpio_in/out/dir` 8→13、新增 `ctpIrq` 端口；
- 顶层加四端口 + 三态 + 2FF（见 §1 表）；LED 仍用 `gpio_out[0..3]`，一个字节都没动。

约束（`constraints/yeshen_mini.fdc`）：AE21/AD21/AF22/AE22 四脚，3.3V LVCMOS33；
主线此前**未占用**这四个球（grep 全表 0 命中）。

## 3. 软件改法

| 层 | 文件 | 内容 |
|---|---|---|
| 内核驱动 | `patches/linux/0003-gpio-add-yeshen-ctp-controller.patch` | 新增 `drivers/gpio/gpio-yeshen-ctp.c`（13 线 gpiochip，DATA_IN/OUT/DIR 三个寄存器）+ Kconfig/Makefile 各一条 |
| DTS | `linux_raw.dts` | `gpio@f0002000`(`yeshen,ctp-gpio`,ngpios=13)、`i2c-ctp`(`i2c-gpio`,`scl-open-drain`)、`touchscreen@14`(`goodix,gt911`, `interrupts=<5>`)；`riscv,ndev` 4→5 |
| 内核配置 | `linux_raw.config` | `GPIOLIB/OF_GPIO/GPIO_CDEV/GPIO_YESHEN_CTP/I2C/I2C_CHARDEV/I2C_GPIO/INPUT/INPUT_EVDEV/INPUT_TOUCHSCREEN/TOUCHSCREEN_GOODIX` |

⚠️ 这些符号在原配置里**一个都没有**（早期最小化配置）——`olddefconfig` 会补依赖，
但构建后必须回读 `.config` 确认全部 `=y`（`build_images.sh` 已经会打印生效项）。

## 4. 验证

| 判据 | 结果 |
|---|---|
| 补丁 apply 干跑 | OK；落地驱动与 `YeshenGuiKernel/drivers/gpio/gpio-yeshen-ctp.c` **cmp 相同** |
| DTS 两段 cpp + dtc | 通过，DTB **2996 B**；反编译确认 `gpio@f0002000` / `i2c-ctp` / `goodix interrupts=<5>` / `riscv,ndev=<5>` 均在 |
| dev_map（tag `ctp1`） | **0 error**；LUT 88,151.5（56%）、FF 119,644、DRM 312、APM 257、**IO 165**（= gui1 的 161 + 4 个 CTP 脚） |
| PnR（tag `ctp1`，strategy 1） | **4 颗种子全跑完，0% 收敛**；最好 seed 0 = **−0.010 ns**（1 端点）；比特流已出：<br>`pds_ctp1_p10.000/prj_tasks/pnr_1/generate_bitstream/yeshen_mini_board_top.sbit`<br>9,188,552 B / sha256 `20933fc4…` |

### 4.1 ctp1 的 4 颗种子（同一 netlist）

| seed | Setup(Slow) WNS | 布线时长 |
|---|---|---|
| **0（最终采用，Best）** | **−0.010** | 12m39s |
| 1 | −0.041 | 46m31s |
| 2 | −0.016 | 11m37s |
| 3 | −0.016 | 11m29s |

违例永远是同一条弧：`core_clk → phy_dq_sysclk_0`，**1 个端点**
（`ddrphy_control_path_adj/adj_addr[*]` → `outbuft_addr0/outbuft_odt` 的 TX 缓冲，DDR3 PHY 内部）。
逻辑级数 2、逻辑 0.567 ns、**布线 5.607 ns（90.8%）**；预算来自厂家 `ddr_test.fdc` 的
`set_multicycle_path 2` + `set_clock_uncertainty 0.4`（**我们与厂家逐条等价**，未加宽松）。

已知限制与先例：camfix4 以同一条弧 **−0.031** 上板，DDR 全功能正常（相机帧/NPU/Linux 启动）。
**没有**对该弧做 false_path / 放宽 MC / 降 uncertainty。

> 关于"过约束"：本流程的 `YESHENMINI_*_PERIOD` **只改 `cpu_clk`**，对这条 DDR 域弧无作用；
> 而 `core_clk` 是 ref_clk 生成的 125 MHz（`×16 ÷16`），压低它会把该弧的 2 周期预算
> 一起压小（8→7 ns ⇒ 预算 10→8.75 ns），方向相反。

资源增量口径：相对 `gui1`（GUI 读源选择，LUT 87,809.5）本轮 **+342 LUT / +45 FF / +4 IO**，
主要是 PLIC 源 5 的 claim/pending 比较链；DRM/APM 不变。

## 5. 上板前两件必办项（**已做**，2026-10-30）

### 5.1 `S99leds.sh` 不再踩 CTP 四位

老版本启动就 `devmem 0xF0002008 32 0xFF` 写 DIRECTION（= 把 bit8..12 全清成输入）、
之后每秒又整字写 DATA_OUT。两处都改成**读-改-写**，只碰 bit0..3：

```sh
d=$(devmem $((GPIO + 8)) 32); devmem $((GPIO + 8)) 32 $(( (d | 0xF) & 0xFFFFFFFF ))
o=$(devmem $((GPIO + 4)) 32); devmem $((GPIO + 4)) 32 $(( (o & ~0xF) | v ))
```

顺手修一个被这次改动**暴露**的老 bug：`led[5] = NPU busy` 原来读的是 DATA_IN 的 bit8，
那一位现在是 CTP_SCL（I2C 时钟会跳）⇒ 改成按注释本意读 NPU CSR `0xF000C000` 的 bit8。

### 5.2 镜像已重建（内核 + rootfs + 卡）

`REBUILD_PKGS=linux bash scripts/build_images.sh`（WSL，约 3 min，ccache 热）：

| 产物 | 大小 | md5 |
|---|---|---|
| `sw/images/Image` | 6,172,660 | `32470cd5…` |
| `sw/images/linux.dtb` | **2996** | `b52ffec9…` |
| `sw/images/rootfs.cpio` | 3,785,728 | `a11ca75a…` |
| `sw/images/sd_ab_k2_ctp.img` | 33,554,432 | `110f0049…` |

判据：
- 内核 `.config` 里 9 个符号全 `=y`（`GPIO_YESHEN_CTP` / `I2C_GPIO` / `TOUCHSCREEN_GOODIX` …），
  `strings Image | grep yeshen,ctp-gpio` = 1（驱动真进了镜像）
- `rootfs.cpio` 里有 `root/gui/yshell`（1,123,620 B，0755）、`etc/init.d/S99gui.sh`、
  新版 `S99leds.sh`（2547 B）
- 卡镜像双计划（LBA0 / LBA32768）各自：表头 CRC 自检通过 + **5 段逐字节**回读一致

`S99gui.sh` 默认**不自启**（yshell 的串口键盘会与 getty 抢 `/dev/ttyS0`）。手动起：

```
setsid /root/gui/yshell --demo </dev/null >/tmp/gui.log 2>&1 &
```

### 5.3 剩下真正要在板上做的

1. 烧 `ctp1` 比特流（sha256 `20933fc4…`）+ 写 `sd_ab_k2_ctp.img`（md5 `110f0049…`）——**成对**。
   **卡已写**（2026-10-30 16:29）：PhysicalDrive2（USB 7.4 GB）`WROTE 33554432` /
   `read back 33554432` / `file sha == card sha == 44973615…` / **CARD VERIFY PASS**。
   ⚠️ 同一天 17:0x 又按用户要求把**跑分卡** `sd_score_ctp.img` 写到了同一张卡上
   （计划 1 = CoreMark ITERS=5500），所以卡上现在不是 GUI 镜像；GUI 镜像随时可重写回。
   卡台账见 [boot-cards.md](boot-cards.md)。
2. 上电后按序验：`i2cdetect -y <bus>` 看到 0x14 → `goodix` 绑定 → `/dev/input/event*` 有事件
   → 起 yshell 点一下看坐标。
3. 若要"全 Met"：事后用 `YESHENMINI_PNR_GSEED=<n>` 逐颗补试（4 颗均值 −0.02，出正需要运气，
   但 camfix5 曾到 +0.114）；不影响本轮先上板验触摸。

> 写卡提权：`Start-Process -Verb RunAs` 不能与 `-RedirectStandardOutput` 同用
> （ShellExecute 参数集互斥）⇒ 包装脚本改成提权 `cmd /c powershell … > log 2>&1`。
