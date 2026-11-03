# Y1-Boot 报告 —— TF 双计划（Linux / CoreMark 裸核）+ 上电 UART 选择

日期：2026-10-18　规格：`docs/superpowers/specs/2026-10-18-y1-boot-plan-select-design.md`

**Status: RTL/闸门 DONE；PnR 与上板见 §6/§7。**

---

## 0) 交付物

| 文件 | 说明 |
|:--|:--|
| `src/peripheral/BootSel.scala` | 1s 窗口选择器：115200 提示 + 8N1 RX + 超时 |
| `src/peripheral/SdLoader.scala` | `hdrSel` 运行期选头（0=块 0，1=`coreHdrLba`=32768） |
| `src/peripheral/SdSpi.scala` | **连带修**：初始化后首块 CMD17 的地址折算用旧 `sdhcR` |
| `src/YeshenSocGlue.scala` | BootSel 接线、`bootWait`、SD 使能门控、UART 四级优先、`io_bootTimeout` |
| `board/yeshen_mini_soc.v` | `io_bootTimeout = 100_000_000`（1.0 s @100 MHz） |
| `sw/coremark-rv32/` | RV32 端口（`lw/sw`、`rv32imac_zicsr/ilp32`），ITERS=10 CRC 档 |
| `scripts/build_boot_card.sh` | 双计划卡构建 + 同进程自检 + 回读 |
| `sim/sdloader/run_sdloader_hdr_ab.sh` | 双头 A/B 闸门（`hdrSel=0/1` 都逐字节 PASS） |
| `y1/rtl_test/BootSelTb.v` + `y1/tools/run_bootsel_ab.sh` | 提示串逐字节 + 4 用例 + 突变负对照 |

## 1) 卡布局与指纹

| 区域 | LBA | 内容 |
|:--|--:|:--|
| Linux 计划头 | 0 | `YSLD` + 5 项（与 `sd_y1.img` 逐字节相同） |
| CoreMark 计划头 | 32768（16 MiB） | `YSLD` + 1 项：`0x80000000 = coremark_rv32_i10.bin` |
| CoreMark 数据 | 32769..32776 | 60,360 B（8 块，尾 0 填充） |

- `sw/images/sd_boot.img`：16,838,144 B，md5 `60a3914eeec8316a10d43f64da5ee7c8`
- `sw/images/coremark_rv32_i10.bin`：60,360 B，md5 `3bc45fcaa4810e4492d3c3afc720058c`，entry `0x80000000`
- `build_boot_card.sh` 每次构建都做：两块头 magic/项数/地址/块号、Linux 段逐字节不变、
  填充全 0、CoreMark 段回读 md5、落盘后再读回整图比对。结果 `PASS`。

## 2) 选择器时序（板上）

- `loadModeLatch` 置起后 `BootSel` 立即发 28 字节提示
  `\r\n[Y1] L=Linux C=CoreMark > `（115200，位周期 868 拍）；
- 窗口 1.0 s（`io_bootTimeout`）内收到 `C/c` ⇒ `sel=1`；`L/l` ⇒ `sel=0`；其它字节忽略；
- 提示发完且 `done` ⇒ `lineFree=1` ⇒ 放 SD 装载器；窗口内 CPU 一直被 `loadWait` 扣复位；
- 超时/无输入 ⇒ `sel=0`（Linux），与旧卡完全兼容。

## 3) 闸门证据

### 3.1 BootSel（`y1/tools/run_bootsel_ab.sh`，Windows iverilog）

```
CASE timeout: sel=0 elapsed=400002
CASE C: sel=1 elapsed=266478
CASE L: sel=0 elapsed=266478
CASE Z: sel=0 elapsed=400002
RESULT: PASS
DECODE: 112 bytes
DECODE_OK: 4/4 prompts byte-exact
---- 负对照（io_sel 强制 0）----
TBFAIL: 'C' sel=0 (want 1)
NEG-OK：突变网表按期望翻红
```

### 3.2 SdLoader 双头（`sim/sdloader/run_sdloader_hdr_ab.sh`）

一张小卡：Linux 计划 @0（3 项，13,824 B）/ CoreMark 计划 @32768（1 项，4,096 B，目的地址
故意不同）。同一装置跑两次：

```
hdrSel=0: RELEASED @cyc=2844771, 对账 checked=13824 bad=0（表项数 3） => TEST PASSED
hdrSel=1: RELEASED @cyc=1229334, 对账 checked=4096  bad=0（表项数 1） => TEST PASSED
RESULT: PASS
```

`hdrSel=1` 时日志显示 `sdlLba=32768`；若选择器失效，它会装成 Linux 计划（地址/长度都对不上），
这一对用例本身就是鉴别力证据。

### 3.3 回归

| 闸门 | 结果 |
|:--|:--|
| `sim/glue_pbus/run_unit.sh`（pBus 枚举） | `TEST PASSED` |
| `sim/glue_pbus/run_memmerge_unit.sh` | `TEST PASSED`（`[REGRESS] 0 行`） |
| `sim/sdloader/run_sdloader_dma_unit.sh` | `TEST PASSED` |
| `sim/sdloader/run_sdloader_hdr_ab.sh` | `RESULT: PASS` |
| `y1/tools/run_bootsel_ab.sh` | `RESULT: PASS`（正 + 突变负） |

glue 网表：`rtl/YeshenSocGlue.v` md5 `80a43909ec02bbdda40d451e725bb302`，连跑两次 `gen_glue.sh`
一致（确定性）。

## 4) 过程中抓到的两个缺陷

### 4.1 DUT：`SdSpi` 首块地址口径（潜伏，已修）

`pCmd58` 里 `sdhcR := rspAcc(30)` 后**同一拍**就用 `sdhcR` 给首块 CMD17 折算：
寄存器旧值（0）⇒ 走 `lba<<9`。Linux 头在 LBA 0，两种口径同址 ⇒ 板上一路正常；CoreMark 头在
32768 就被放大成 `0x01000000`，卡模型回块 0 ⇒ 解析出 Linux 表。
修法：用刚采到的 `val ccs = rspAcc(30)` 直接参与 Mux（`src/peripheral/SdSpi.scala`）。

### 4.2 装置：卡模型 32 位溢出（已修）

`spi_dataPtr = spi_arg * 512u`：LBA 32768 时乘积 = 2^33，被截成 0 ⇒ 卡模型又把块 0 当 32768 回。
它把 DUT 的**正确**读数伪装成"坏 magic"（errR=2）。修法：`uint64_t` + 显式 `(uint64_t)` 乘。
**这是装置缺陷，不是 DUT 缺陷**；修好后 DUT 侧才暴露 4.1。

## 5) 面积 / 时序（boot1 = 8 KiB 基线）

- dev_map：LUT 73,239（46%）/ FF 102,967（33%）/ DRAM 7,872（20%）/ DRM 241.5（59%）/ APM 269（37%）
- PnR（speed 档，tag `boot1`）：**All Constraints Met**
  - `cpu_clk` WNS **+0.819 ns**（66,272 endpoints）
  - `npu_clk` WNS **+0.857 ns**（325,988 endpoints）
- 比特流：`yeshen_mini_board_top.sbit`，9,188,552 B，md5 **`ede37d2878347babbf4ce0cce95b7fd5`**

## 6) 上板三用例（已完成）

板：盘古676 200K MINI；两版比特流 + `sd_boot_score5500.img`（Linux 计划 + CoreMark ITERS=5500）。

| 用例 | 结果 |
|:--|:--|
| 默认（不按键，超时 1 s） | 提示 → SD 装载 → OpenSBI → Linux → LiteEth → dropbear → 用户态 marker → 登录：**PASS** |
| 显式 `L` | 提示 → 同上：**PASS** |
| 显式 `C`（cpufast） | CoreMark `459.208865 iter/s`、**4.59 CoreMark/MHz**、11.977 s、`crcfinal 0x33ff`：**PASS** |
| 显式 `C`（boot1 基线） | `164.318539 iter/s`、**1.64 CoreMark/MHz**、33.472 s、同 CRC：**PASS** |

- 卡：`sd_boot_score5500.img`，md5 `c92e967a2e5b44e07244b4fd582bce71`；
  CoreMark bin `fd1dd52d83207cbc8521b6e75e5edf05`。
- 板上 `crcfinal` 随 ITERS 累计（5500 → `0x33ff`）；判据用阶段 CRC（`e714/1fd7/8e3a`）与
  "Correct operation validated"。
- 详细 CPU A/B、面积/时序见 `y1/reports/cpu_maxipc.md`。

## 7) 后续（用户路线，未开工）

- CoreMark 正式分数档（ITERS≥4100）与 score 报告；
- CPU/SoC 时钟拆分（3 条 AXI 异步桥）；
- 摄像头→LCD 直通 + 中央 640×640 → NPU → box 叠加。
