# Y1-Boot：TF 双槽位（Linux / CoreMark 裸核）+ 上电 UART 选择

日期：2026-10-18　上游：用户 2026-10-18 的四项路线（先做槽位切换）

## 1. 目标与非目标

**目标**
- 一张 TF 卡上同时放 **Linux 计划**与 **CoreMark 裸核计划**；上电时用串口在 **1 s 窗口**内选
  （`L`→Linux，`C`→CoreMark，无输入→默认 Linux）。
- CoreMark 裸核镜像由 **RV32** 工具链重建（现有 `sw/coremark` 是 RV64，不能直接用），
  先以 `ITERATIONS=10` 的 CRC 档验收；正式分数档另建（ITERS≥4100）。

**非目标**
- 不做 SD 卡上的文件系统/动态菜单（仍是裸块 + 固定头部）。
- 不改 Linux/OpenSBI 的入口地址与既有 4 槽布局。
- 不做 CPU/SoC 时钟拆分（下一片）。

## 2. 卡布局

| 区域 | LBA | 内容 |
|---|---|---|
| Linux 计划头 | **0** | `YSLD` + 5 项（fw/Image/dtb/rootfs/y1_payload），**与 sd_y1.img 逐字节相同** |
| Linux 数据 | 1..~20743 | 不变 |
| （填充） | ..32767 | 0 |
| CoreMark 计划头 | **32768**（16 MiB） | `YSLD` + 1 项：`0x80000000=coremark.bin` |
| CoreMark 数据 | 32769.. | RV32 CoreMark 镜像 |

- `SdLoader` 的 `hdrLba` 由构造参数变为**运行期输入** `hdrSel`：
  `sel=0 → hdrLba=0`；`sel=1 → hdrLba=32768`（常量 `CoreHdrLba`）。
- `mk_sd_image.py` 增 `--card-lba N`：头部仍写在输出镜像的块 0，但表里的 `start block` 全部 `+N`
  ⇒ 既有的 Linux 计划（N=0）字节不变；CoreMark 计划（N=32768）可直接拼到卡偏移。
- **连带修一个潜伏缺陷（hdrSel=1 首次暴露）**：`SdSpi` 在 CMD58 里用寄存器 `sdhcR` 给
  "初始化后的首块 CMD17"折算地址，而该寄存器本拍才赋值 ⇒ 首块永远走 SDSC 口径
  （`lba<<9`）。Linux 头在 LBA 0 时两种口径同址，所以一直没露；CoreMark 头在 32768 就被
  放大成 `0x01000000`。修法：用刚采到的 `rspAcc(30)` 本体参与 Mux（`SdSpi.scala`）。

## 3. 选择器（`BootSel`，RTL）

- 新模块 `src/peripheral/BootSel.scala`：在 `active`（loadModeLatch）期间
  - **TX 提示**：115200（baudDiv=54 → 位周期 868 拍 @100 MHz），一发一条
    `\r\n[Y1] L=Linux C=CoreMark > `；
  - **RX**：复用 UartLoader 的 8N1 采样（起点中点复核、LSB 先），`C/c`→sel=1，`L/l`→sel=0，
    其它字节忽略；
  - **超时**：1.0 s（100M 拍）→ sel=0（Linux）。
  - 输出 `sel`、`done`（锁存）、`lineFree = done && !txBusy`、`owner/txd`。
- **CPU 复位**：`loadActive` 增加"选择窗口"项 ⇒ `bootWait = loadModeLatch && !bootSel.lineFree`，
  `loadActive = bootWait || sdEnable || uartEnable`。窗口内 CPU 仍扣复位，避免从 DDR 野跑。
- **UART 夺线**：`io.uart_txd = Mux(bootSel.owner, bootSel.txd, Mux(sdReport.owner, …, …))`；
  `sdEnable` 改为 `loadModeLatch && bootSel.lineFree && !sdDone`（提示发完才开始装卡）。
- 失败/无卡：SD 失败仍回退 UART 装载器（既有逻辑不变）。

## 4. CoreMark RV32

- 新建 `sw/coremark-rv32/`：复制 `sw/coremark`（RV64 版保留给 Nax），改：
  - `start.S`：`ld/sd`→`lw/sw`、8→4 字节步进；仍 `_start` @0x80000000、清 `.bss`、`call main`。
  - 构建 flags：`-march=rv32imac_zicsr -mabi=ilp32`（WSL 的 `riscv64-unknown-elf-gcc 13.2` 有 rv32 多库）。
  - UART/定时器已对：`UART_BASE=0xF0001000`、`EE_TICKS_PER_SEC=100e6`、`rdtime`→CLINT mtime。
- 产物：`sw/images/coremark_rv32_i10.bin`（CRC 档）；`build_coremark.sh` 支持 `ITERS=`。
- 验收：串口打印 `CoreMark ... Iterations/Sec` 与 CRC；同镜像重复跑 CRC 一致。

## 5. 闸门与验收

1. **BootSel 单元**（新 `run_bootsel_ab.sh`）：
   - 提示串按 115200 解出完整前缀；
   - 发 `C` → `sel=1`；发 `L` → `sel=0`；发 `Z` → 忽略、超时后 `sel=0`；
   - 负对照：窗口内不发 → `sel=0` 且 `done` 只在超时后置起。
2. **卡镜像自检**（新 `build_boot_card.sh`）：
   - 两处头部 magic/项数/地址/块号合法；Linux 段与 `sd_y1.img` **逐字节相同**；
   - CoreMark 段回读 md5 与源文件相同；两计划不重叠。
3. **SdLoader 单元**：既有 `run_sdloader_unit.sh`/`run_sdloader_dma_unit.sh` 全绿（hdrSel=0 默认不回归）；
   新增 `run_sdloader_hdr_ab.sh`：一张小卡上放两个头（Linux @0 三表项 / CoreMark @32768 一项，
   目的地址不同），同一装置分别以 `hdrSel=0/1` 跑，**两次都逐字节 PASS** —— 若选择器失效，
   第二次会装成 Linux 计划，判据自红（这就是"选择器有鉴别力"的证据）。
   装置侧另外修了一处 32 位溢出（`spi_dataPtr = spi_arg * 512u`，LBA 32768 时乘积 >2^32 被截成 0，
   卡模型把块 0 当 32768 回）—— 这是**装置**缺陷，不是 DUT 缺陷；修前它把 DUT 的正确读数伪装成
   "坏 magic"。
4. **集成**：glue 重生成 + `run_memmerge_unit.sh` golden 0 差异；dev_map 0 error；PnR speed
   `All Constraints Met`（18.4 ns / 54 MHz）。
5. **上板**：默认启动 → Linux 全 marker；上电发 `C` → CoreMark 裸核打印 + CRC；
   发 `L` → Linux 如常。三种各一次，串口报文为证。

## 6. 风险与边界

- **卡要重写**（新增 16 MiB 偏移处的计划）⇒ 需要读卡器/重烧卡；这一步由用户安排。
- 上电窗口 +1 s（提示发完即装载；无输入走默认）。
- UART RX 悬空/噪声：只认 `L/C` 两种字节，其它一律忽略，超时默认 Linux。
- CoreMark 的 RV32 端口是"新代码"：先 ITERS=10 对 CRC，再跑正式分数；正式分数的 CRC 与
  ITERS=10 的各阶段 CRC 相同（`crclist 0xe714 / crcmatrix 0x1fd7 / crcstate 0x8e3a`；
  **`crcfinal` 随迭代数累计，不能跨 ITERS 比较**——2026-10-18 板上实测纠正）。
EOF