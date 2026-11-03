# YeshenRiscvProject

夜神（YeshenRiscv）RV32 处理器 / SoC 的 2026 年处理器设计比赛提交仓库。

本仓库冻结的是**已上板验证的 130zbb 版本**：2026-11-02 构建、2026-11-03 固化进 SPI flash、2026-11-03/04 上板启动并完成 CoreMark 20,000 次迭代。硬件源码取自 `VexiiYeshenLinux` 提交 `2b48ca9`（Zbb+Zbs 核 + CPU 130.645 MHz 定档），交付比特流、SPI 烧录文件、TF 卡镜像与附属工程源码一并归档。

## 1. 平台与关键指标

| 项 | 值 |
|---|---|
| FPGA / 板卡 | 盘古676 200K MINI，PG2L200H-6IFBB676（Logos2，-6 速度等级） |
| CPU | RV32IMAC + Zbb + Zbs（含 S/U、Sv32、Zicbom），2 decoder / 2 lane |
| CPU 缓存 | I$ 32 KiB（64 sets × 8 ways × 64 B）、D$ 16 KiB（64 sets × 4 ways × 64 B） |
| CPU 主频 | **130.645 MHz**（PLL RATIO0=7.75 / DUTY0=7；FDC `cpu_clk` 7.000 ns 过约束拉布局，交付频点 7.6543 ns） |
| SoC 时钟 | soc_clk 100.000 MHz；npu_clk 60.000 MHz；gpu_clk 101.25 MHz；DDR ref_clk 125 MHz |
| 存储 | DDR3 1 GiB；启动介质 TF 卡（SPI 模式） |
| 加速器 | Y1 自研 YuNet NPU（NpuTop）+ GPU 2D/3D（tri_raster 两拍流水） |
| 外设 | UART 115200、LiteEth、GPIO、GT911 触屏、摄像头、LCD |
| 软件栈 | SdLoader → OpenSBI → Linux 6.18.60 → Buildroot 2026.02.3（uClibc，`zbb_zbs`）→ LVGL 桌面 |
| 资源（130zbb dev_map） | LUT 98,529.5 / 159,800（62%）、FF 129,618（41%）、DRM 316（77%）、APM 293（40%） |
| 时序（130zbb PnR） | 仅 `cpu_clk` 一项在 7.000 ns 过约束下为负（−0.413 ns）；按交付频点 7.6543 ns 计余量 +0.241 ns；soc / npu / gpu / core / rgmii 全正 |

## 2. 上板验证记录

| 项 | 证据 | 结果 |
|---|---|---|
| SPI flash 固化 | [`deliver/logs/fv_flash.out`](deliver/logs/fv_flash.out) | `pds_cpu130_20261102.sbit` 烧写 7.7 s，done bit = 1 |
| 固化后读回 | `cpu130_20261103_rb.sfc` | 读回与源文件 md5 相同：`89f4e1f0…` |
| 冷启动 | [`deliver/logs/fv_boot.txt`](deliver/logs/fv_boot.txt) | Linux 6.18.60 启动，`VEXIIYESHEN-OK` |
| GUI 启动 | [`deliver/logs/bootsel_C_live_20261104.log`](deliver/logs/bootsel_C_live_20261104.log) | `YGUI-BOOT` / `YGUI-PRESENT async` / `GPU-UNIT-ON` |
| CoreMark | [`deliver/logs/bootsel_C_live_20261104b.log`](deliver/logs/bootsel_C_live_20261104b.log) | ITERS=20000，crcfinal `0x382f`，`Correct operation validated` |

CoreMark 原始结果（照录日志）：

```
2K performance run parameters for coremark.
CoreMark Size    : 666
Total ticks      : 3427438024
Total time (secs): 34.274380
Iterations/Sec   : 583.526233
Iterations       : 20000
Compiler version : GCC11.2.1 20211120
Compiler flags   : -Ofast-upstream
Memory location  : STATIC
seedcrc          : 0xe9f5
[0]crcfinal      : 0x382f
Correct operation validated.
CoreMark 1.0 : 583.526233 / GCC11.2.1 20211120 -Ofast-upstream / STATIC
5.84 Coremark/MHz
```

> 计时口径：CoreMark 裸机端 `EE_TICKS_PER_SEC = 100 MHz`（与板级 DTB `timebase-frequency` 一致）；日志中的 `5.84 Coremark/MHz` 由二进制按该计时基准打印。CPU 实际主频 130.645 MHz，换算口径以比赛规定为准。

## 3. 交付物与指纹

全部交付物的 md5 / 大小清单见 [`deliver/MANIFEST.md`](deliver/MANIFEST.md)。核心件：

| 件 | 文件 | 大小 | md5 |
|---|---|---|---|
| 比特流（JTAG） | `deliver/bitstream/pds_cpu130_20261102.sbit` | 9,188,552 | `89f4e1f09ae1c2337605e7ef9e967164` |
| SPI 烧录文件（XT25BF128） | `deliver/spi/cpu130_20261103.sfc` | 9,188,552 | `89f4e1f09ae1c2337605e7ef9e967164` |
| zbb 标准 TF 卡 | `deliver/images/sd_y1_618_zbb.img` | 14,944,256 | `72c0d92b1a2345ee2537df1765044a7d` |
| CoreMark 跑分卡 | `deliver/images/sd_score_618zbb_i20000.img` | 16,840,192 | `03a0c1a19e5ee546bb7ad2fe17316675` |

`.sfc` 与 `.sbit` 逐字节相同（PDS `cfg_gen_sfc` 仅做容器转换），两者 md5 一致；固化后的独立读回 `cpu130_20261103_rb.sfc` 也与源文件一致。

## 4. 目录结构

```
.
├── README.md                本文件
├── docs/                    主工程设计/上板/实验报告（源自 2b48ca9）
│   └── PROVENANCE.md        版本、指纹与已知偏差说明
├── rtl/ board/ src/         主 SoC 源码（核网表、胶合、板级顶层/PLL/CDC、Chisel 胶合）
├── constraints/ pds/        FDC 约束与 PDS 2025.2 流程脚本
├── scripts/ sim/ sw/        构建/镜像/验证脚本，buildroot 外部树，OpenSBI 平台
├── y1/                      NPU 源码与生成网表（NpuTop/DmaEngine/CDC）
├── third_party/             构建所需第三方 IP（DDR3 IP、LiteEth、RGMII；上游核见 PINS.md）
├── software/image-build/    内核与根文件系统构建补充件（zbb defconfig、kzbb.sh、DTB 反编译）
├── deliver/                 比特流 / SPI 文件 / 镜像 / 组件 / 上板日志 / 校验清单
└── aux-projects/                     附属工程源码
    ├── YeshenGui/           LVGL 9.2 桌面（ui/platform/board，LVGL src 子集）
    ├── YeshenGuiKernel/     内核配置、驱动补丁、DTS（触屏工作线）
    └── YeshenGuiTouch/      触屏独立 RTL 工程（board/rtl/gen 源码）
```

## 5. 烧写与启动

**JTAG 直接配置（掉电丢失）**

```bash
# PDS 2025.2 的 cfg 流程；或直接使用 PDS GUI 的 Program 功能
cfg_connect -ip 127.0.0.1 -port 62000
cfg_scan_chain
cfg_program -file deliver/bitstream/pds_cpu130_20261102.sbit
```

**SPI flash 永久固化（XT25BF128）**

```bash
# 参考 deliver/spi/program_cpu130_flash.tcl
cfg_gen_sfc -sbit deliver/bitstream/pds_cpu130_20261102.sbit \
            -sfc deliver/spi/cpu130_20261103.sfc \
            -device_name XT25BF128 -sbit_start_address 0
# 读回前必须先 assign（Configuration-0016）
cfg_jtag_flash_assign_file -file deliver/spi/cpu130_20261103.sfc -device_index 0
cfg_jtag_flash_erase -device_index 0
cfg_jtag_flash_program -device_index 0
cfg_jtag_flash_verify -device_index 0
```

**TF 卡写入与启动**

- 将 `deliver/images/*.img` 以 raw 方式写入 TF 卡（如 `dd` / Win32DiskImager / `sim/board/write_sd.ps1`）。
- 上电后 UART0（115200 8N1）出现 `[Y1] L=Linux C=CoreMark >` 菜单：`L` 启动 Linux，`C` 运行 CoreMark（仅跑分卡包含 plan1）。
- 标准 zbb 卡包含 5 段：`fw_jump` / `Image.618.zbb` / `linux.618.dtb` / `rootfs_618_zbb.cpio` / `y1_payload.bin`。

## 6. 从源码重建

- **工具链**：PDS 2025.2（`pds_shell`）；Linux 侧 buildroot 2026.02.3 + GCC 13.4.0（uClibc）。
- **PDS 工程**：`pds/run_devmap_yeshen.tcl`、`pds/run_pnr_yeshen.tcl`。脚本内 `set root` 原为原工作区绝对路径，迁移后需改成仓库根目录。
- **核网表**：`rtl/vexiiriscv/VexiiRiscv.v` 已随仓库提供；如需重生成，按 `third_party/PINS.md` 克隆上游 `VexiiRiscv`（含 `ext/SpinalHDL` 子模块）后执行 `scripts/gen_core.sh`。上游仓库体积大，未随本仓库分发。
- **镜像**：内核 `linux-6.18.60` + `software/image-build/naxmini_618_zbb_defconfig` + `software/image-build/kzbb.sh`；DTB 的实际内容见 `software/image-build/linux.618.zbb.decompiled.dts`（由交付 DTB 反编译）。
- **NpuTop / DmaEngine**：`y1/gen/*.v` 为生成物，已随仓库提供；`y1/rtl/` 为对应的 SpinalHDL 源码。

## 7. 附属工程说明

| 目录 | 内容 | 与主工程的关系 |
|---|---|---|
| `aux-projects/YeshenGui` | LVGL 9.2 桌面（窗口管理、文件、设置、终端、游戏；host 模拟器 + 板端 platform 层） | 板端 GUI 应用，独立构建；LVGL 仅保留 `src/` 及构建所需头文件 |
| `aux-projects/YeshenGuiKernel` | 触屏工作线的内核配置、DTS 与驱动补丁 | 触屏/内核 bring-up 参考；主工程的最终补丁在 `sw/buildroot-external/patches/linux/` |
| `aux-projects/YeshenGuiTouch` | 触屏独立 RTL 工程（board/rtl/gen 源码，CTP 推挽 SCL 等改动） | 触屏 bring-up 的独立工程；最终 RTL 已并入主工程 |

未包含：`YeshenGuiRtl` / `YeshenGuiRtl2` 两份 700 MB 级独立 RTL 副本（与主工程重复）；253 MB 的 LLM 大卡（超过 GitHub 单文件 100 MB 限制）；`third_party/VexiiRiscv` 上游仓库（见 PINS.md）。

## 8. 第三方组件与许可

- VexiiRiscv（上游 RISC-V 核生成器）及 SpinalHDL：见 `third_party/PINS.md` 记录的 SHA；本仓库仅分发生成后的网表。
- Pango DDR3 IP、LiteEth MAC、厂家摄像头 IP：按原厂许可随工程使用。
- LVGL 9.2：MIT，见 `aux-projects/YeshenGui/third_party/lvgl/LICENCE.txt`。
- Linux 6.18.60、Buildroot 2026.02.3、OpenSBI、U-Boot 工具链组件：遵循各自上游许可。

## 9. 安全与再分发

交付的 `rootfs_618_zbb.cpio` 与两张 TF 卡镜像包含板级默认登录口令和 dropbear 主机密钥（嵌入式交付镜像的常规内容）。本仓库为私有仓库；若要公开仓库或再分发这些镜像，请先替换/删除其中的口令与密钥。
