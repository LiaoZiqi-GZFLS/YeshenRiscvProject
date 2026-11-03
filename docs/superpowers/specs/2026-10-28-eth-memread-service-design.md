# 以太网"硬件读存"服务（H2）设计

- 日期：2026-10-28
- 状态：设计定稿，待实施
- 动因：抓一帧帧存（1.2 MB）目前只能走 Linux + ssh，而这块板是**单核 RV32 + dropbear + 3% 丢包**，
  新连接 KEX 常卡 2–15 s、约一半会话卡死 25 s；`y1cam --loop` 还会把网络栈饿死。
  抓图因此成为相机调试的瓶颈。⇒ 让 **FPGA 自己回答 UDP 读请求**，完全不经过 Linux 协议栈。

## 1. 一句话

主机发一个 UDP 包 `read(物理地址, 长度)`，FPGA 用 DMA 引擎从 DDR 取数、按 UDP 分片直接回到主机；
抓 1.2 MB 一帧为**几十毫秒级**，且不依赖 ssh/TCP/内核网络栈。

## 2. 关键结论：不新增 AXI 主口

原本估 H2 最贵的一环是"往胶合块（`YeshenSocGlue.v`，Scala 生成）新增一个 AXI4 主口"。
**不需要**：`y1/rtl/DmaEngine.scala` 已经是"多通道 DDR↔stream"引擎，且已在 SoC 内
（CSR 窗 `0xF0006000`，ch2/ch3 = 相机留口，板级把 `wr_stream/rd_stream` 引到顶层）。
⇒ 本服务只做 **stream 消费 + 组包 + MAC 收发**，DDR 读由现有 DMA 引擎承担。

**已核（2026-10-28）**：`DmaEngine` 的每通道有 `rd_valid/rd_ready/rd_data` 与
`wr_valid/wr_ready/wr_data`（`DATA_W` 位宽），`NCH` 参数 1..4、当前取 2；
per-channel CSR 有 `SRC/DST/LEN/MODE/START/ABORT/STATUS(errCode/bytes)`。
⇒ **mem→stream 是现成能力**（就是我们需要的 `rd_*`），不需要新 AXI 主口。

**新增的小改动**：每笔请求的地址/长度都不同，而该 CSR 目前只由 CPU 侧的 `dmaAxi`
（AXI-Lite）写。为让 fabric 能"自己派活"，给 `DmaEngine` 加一个**极简 job 口**
（几个寄存器：`job_src/job_len/job_start/job_busy/job_done`，只有 ch2 用），
不碰 CPU 的 AXI-Lite 路径（也就不动胶合的端口表）。

## 3. 接管点：MAC 的 Wishbone（不是 GMII）

`board/liteeth_wrap.v` 里，RGMII↔GMII（`rgmii_interface`，含 GTP_ODDR/IDDR + IODELAY）与
MAC（`liteeth_mac_top`，PIO/槽模式 + 自带前导/FCS）都在；**CPU 是通过 Wishbone 槽接口办事的**：

```
RGMII ─ rgmii_interface ─ GMII ─ liteeth_mac_top ─┬─ wb_csr   （CSR：MAC 地址/长度/命令）
                                                  ├─ bus_rx  （2×0x800 接收槽）
                                                  └─ bus_tx  （2×0x800 发送槽）
                                                          │
                                              AXI-Lite 适配器（0xF0008000）── CPU
```

⇒ 在 **Wishbone 层做 mux**：服务使能时由 fabric FSM 驱动 `wb_csr/bus_rx/bus_tx`，CPU 侧适配器让路。
好处：**不碰 GMII、不写前导/FCS/CRC、不动 PHY 时序**（那些是这块板上最难、最容易回归的部分）。

## 4. 结构

```
host ──UDP──> [liteeth RX 槽] ──> 请求解析(帧头/校验/命令)
                                        │  cmd=read(addr,len,seq)
                                        ▼
                              程序化 DmaEngine（rd_stream）
                                        │  64bit 流
                                        ▼
                              UDP 组包器（16B 头 + ≤1472B 载荷）
                                        │  WB 写 bus_tx 槽
                                        ▼
host <──UDP── [liteeth TX] <── wb_csr 启动发送
```

- **请求包**（主机 → 板，UDP 目的端口 0x5942）16 B：
  `magic 'YMEM' | cmd(u32) | phys_addr(u32) | len(u32) | seq(u32)`
- **回包**（板 → 主机）每片 16 B 头 + 载荷：
  `magic 'YMEM' | seq(u32) | off(u32) | len(u16) | flags(u16: bit0=last)`
- **地址口径**：`phys_addr` 用 CPU 物理地址（如帧存 `0x9000_0000`），内部换算成 DDR 偏移
  `phys - 0x8000_0000`（与 NPU/`y1cam` 同口径，见 `docs/…` 台账）。

## 5. 与 Linux 的关系（独占）

- 服务**使能时 Linux 的网络失效**（MAC 归 fabric）。这是"独占模式"的固有代价。
- 逃生阀：VIDEO 窗 `0xF0007500` 加一个 `ETH_DBG_CTRL` 寄存器
  （bit0 en / bit1 busy / bit2 done-sticky / [31:8] 计数），CPU 可用 `devmem` 关掉服务；
  但**关之前必须先拿回网络**——所以再加一条**空闲超时自动交还**：连续 `IDLE_MS`（默认 20 s）
  没收到合法请求 ⇒ 自动把 MAC 还给 Linux；收到请求则续期。这样 ssh 仍然可用（抓图时独占）。
- 抓图期间不跑 `y1cam --loop`（它本来就会饿死网络）。

## 6. 判据（闸门）

- **G1 单元闸门**（iverilog，新增 `sim/eth/tb_eth_memread.v`）：
  请求解析（magic/长度/越界拒绝）、组包头字段、`last` 标志、CRC 交给 MAC（不重复算）。
  正例 3 个（单包 / 多包 / 长度非整数倍）+ 负对照 2 个（magic 错 ⇒ 不回包；len 超上限 ⇒ 报错回包）。
- **G2 板级闭环**：主机脚本对一个**已知图案**的 DDR 区域（先写 `0xA5A5_5A5A` 递增值）求读，
  逐字节对账；再读帧存，`md5` 与 `y1cam --dump` 同区域一致（同语义黄金）。
- **G3 回归**：`run_video_gates.sh` 全绿；`y1run` 12/12 不受影响（服务空闲时 MAC 已还给 Linux）。

## 7. 切片（每片一个交付物）

1. **S1**：`eth_memread.v` 请求解析 + 组包器（纯逻辑，无 MAC/DMA），配 G1 闸门。
2. **S2**：Wishbone mux + 与 `liteeth_wrap` 的接线；`ETH_DBG_CTRL` 寄存器 + 空闲交还定时器。
3. **S3**：接 DmaEngine `rd_stream`（相机留口通道），地址换算与非对齐处理。
4. **S4**：主机脚本 `scripts/eth_memread.py`（raw UDP，分片重组 + 重传/超时）。
5. **S5**：dev_map → PnR → 上板；G2/G3 判据；报告回填。

## 8. 风险与备选

- **R1（已关闭）**：ch2 的 `rd_stream` 与 per-channel CSR 都在（见 §2）；地址粒度按 DMA 的
  32B 组口径对齐，非对齐头/尾由包装层按单拍处理。若后续发现 DMA 的最小粒度/对齐要求不可用，
  再退回"新增 AXI4 主口"（贵，3–5 天）。
- **R2**：Wishbone mux 与 CPU 侧适配器的握手互斥（不能双驱动）——用"服务 busy 时 CPU 侧 ready 全 0"的硬互斥。
- **R3**：空闲交还后 Linux 驱动可能需要重新协商 link——先按"不重新初始化，只换数据通路"做，
  上板若不恢复再考虑 `ifconfig down/up`（板内有 root）。

---

## 9. 实施台账（2026-10-28 实读结果，S1/S3 前置已落地）

### 9.1 已交付

| 件 | 提交 | 判据 |
|---|---|---|
| `board/eth/eth_memread.v` + `sim/eth/tb_eth_memread.v` + `sim/eth/run_eth_gates.sh` | `425931e` | G1：42 + 1458 + 1458 + 258 B 逐字节；IPv4 校验独立重算；4 条 in-TB 负对照 + **4 条变异对照各自为预期原因变红** |
| 作业导出 `o_go/o_addr/o_len/o_seq` | `61574bf` | 同上仍全绿 |
| DMA 30bit 地址 + 硬件作业口 + 胶合 30bit | `7d1fe40` | `run_dmaeng_ab.sh` D1/D2 PASS；`check_addr_map.py` 18 点 PASS；`check_dup_modules.py` PASS |

### 9.2 实读到的 MAC 槽契约（**下一步写 glue 时照这个，不要再猜**）

- 槽口是 **32bit 字寻址 + 4bit 字节使能**：`liteeth_wrap` 里 `rx_adr = tx_adr = {19'd0, addr[12:2]}`。
- rx 区 = 字地址 `0x000..0x7FF`（4 槽 × `0x800` B，**槽号 = 字地址 bit10:9**）；
  tx 区 = 字地址 `0x000..0x3FF`（2 槽，**槽号 = bit9**）。DTS：`rx-slots=4 / tx-slots=2 / slot-size=0x800`。
- CSR 在 **mac 窗**（`0xF000_3000`），字节偏移（内核驱动为准）：
  `WRITER_SLOT 0x00`、`WRITER_LENGTH 0x04`、`WRITER_EV_PENDING 0x10`（w1c）、
  `READER_START 0x18`、`READER_READY 0x1C`、`READER_SLOT 0x24`、`READER_LENGTH 0x28`；
  写口字地址 = 字节 >> 2。
- 发一帧的顺序：**先写满 tx 槽**（字写，尾字用 sel 收窄）→ 读 `READER_READY`（等 1）→
  `READER_SLOT` → `READER_LENGTH` → `READER_START=1`。收一帧的顺序：
  读 `WRITER_SLOT`/`WRITER_LENGTH` → 读 rx 槽（4 B/笔）→ 写 `WRITER_EV_PENDING=1` 清 pending。

### 9.3 为什么必须先改 DMA 地址位宽（已关闭的风险 R1'）

**所有 SoC 侧主口都是 28bit 字节地址**（NPU / DMA / 胶合零扩展 4 位），只能到 DDR 偏移
`0..256 MiB`；**相机帧存在 `0x9000_0000`（偏移 `0x1000_0000`）⇒ 28bit 够不着**。
`7d1fe40` 把 DMA 提到 30bit（胶合 `NpuAxi64(30)`、零扩展 2 位），并给 JOB_CH(=1) 加了硬件作业口：
`job_valid/ready/addr/len/done/err`，语义 = CSR `start` 的同一套影子快照 + 记录清除，
但 mode 钉 `RD`、dst 钉 0。**未接线时 `job_valid` 必须显式钉 0**（悬空 X 会把该通道的 CSR 启动路径毒死，
`DmaEngineTb` JOB 5 抓到过）。

### 9.4 剩余实现（S2/S3 的板级胶合）——**下一步从这里开始**

新文件 `board/eth/eth_service.v`（soc_clk 单域），三块：

1. **WB 引擎**：一次一笔（`cyc/stb` 拉起 → 等 `ack` → 捕获 `dat_r`）。目标 `tgt`：0=csr 1=rx 2=tx。
2. **RX 读帧**：`WRITER_EV_PENDING` 轮询 → `WRITER_SLOT/LENGTH` → 每笔 4 B 读槽 →
   逐字节喂 `eth_memread` 的 `rx_*`（`sop` 首字节、`eop` 末字节）→ 清 pending。
3. **TX 写帧**：`eth_memread` 的 `tx_valid/tx_data/tx_eop` → 组 32bit 字（尾字用 `sel`）→ 写槽 →
   `READER_READY/SLOT/LENGTH/START`；`tx_ready` 由服务给（背压天然）。
4. **DMA 取数器**：`o_go` 锁存 `o_addr/o_len` → `job_addr = (addr-DDR_BASE) & ~31`、
   `job_len = ((addr&31)+len+31) & ~31` → 64bit 流灌 16 深字节 FIFO →
   `d_skip=(addr&31)` 静默丢弃 → 交付 `len` 字节（`pay_valid/pay_data`）→ 余下丢弃到 `job_done`。
5. **独占开关**：`liteeth_wrap` 加 `svc_en` 输入 + 服务 WB 主口，内部把 `csr/rx/tx` 三组信号
   二选一；`svc_en=1` 时把 CPU 侧 ready 全压 0（硬互斥）。开关寄存器落在 **VIDEO 窗**（Verilog，
   `board/cam/video_regs.v`，免 Scala 重生成）；先做 `en`，空闲 20 s 自动交还可后置。

⚠️ 本轮曾起草 `eth_service.v` 但 FSM 未收敛（RX 喂字节 / TX 收尾 / 启动序列三处缺口），
**已删除、未入库**；下一版按 9.4 的五个子块分开写、每块配一条单元判据（WB 引擎 / RX 读帧 / TX 写帧 / 取数器 / 整帧闭环）。

### 9.5 已实现（2026-10-28 第二轮）与上板步骤

| 件 | 提交 | 判据 |
|---|---|---|
| `board/eth/eth_service.v`（WB 引擎 + RX 读帧 + TX 写帧 + DMA 取数） | `4a372da` | G2：300 B **非对齐**读 → 1 帧 358 B（job 0x10000000/320）；2000 B 读 → 1458+658 B 两帧（off 0/1400、len 1400/600、last 0/1），载荷逐字节；空闲返回 + n_req；**4 条变异对照各自为预期原因变红** |
| `eth_memread` 的 tx 背压缺陷（真 bug） | `4a372da` | 旧代码逐拍硬清 `tx_valid/sop/eop` ⇒ `tx_ready=0` 的拍会**丢掉已装上的字节**并以新载荷字节重发同一位置（实测丢 30%）。G1 的 `tx_ready` 恒 1 结构性地看不见；现在 TB 用**周期 5**的缺口（周期 8 会与 core 的 2 拍节奏相位锁定，3216 次只停 1 次），m5 变异对照变红 |
| 板级接线（VIDEO ETH_EN → 服务独占 MAC 槽） | `a92bbe1` | dev_map 通过：LUT 87,451.5/159,800 (55%)、FF 38%、DRM 305/415 (74%)、APM 36% |
| 主机客户端 `scripts/eth_memread.py` | `28bf7bc` | 编解码自检（build_request/parse_frame 对冻结线格式） |

**上板步骤（PWR 之后按这个顺序，别颠倒）**

1. 先在**网络还活着**时把对照拉下来（可选，做 G2b 才需要）：
   `python scripts/board_ssh.py ... ` 或既有 ddmem 流程，存一份同区域参考。
2. **UART 控制台**（COM，root/yeshen）关掉网卡并开启服务：
   ```
   ifconfig eth0 down
   devmem 0xF0007494 32 1      # VIDEO+0x094 bit0 = ETH_EN（服务独占 MAC 槽）
   ```
   ⚠️ 从这一刻起 Linux 侧没有网络（这是**有意**的独占模式）；控制台仍在。
3. **主机**发请求（默认对端 192.168.1.110:22850）：
   ```
   python scripts/eth_memread.py --board 192.168.1.110 --addr 0x90000000 --len 819200 --out fb.bin
   ```
   G2a（已知图案）：先用 console/`devmem` 往 DDR 写一段递增值，再读回逐字节比对。
4. 交还：`devmem 0xF0007494 32 0` → `ifconfig eth0 up`（服务在 `en=0` 时全部输出闲置）。

**已知限制（本版有意不做）**：① 没有空闲 20 s 自动交还（交还靠上面的 devmem 写 0）；
② 一次只服务一条请求，服务期间新请求排在 rx 的 4 个槽里等；
③ `svc_en` 切换是"软件先把 netdev 拉下"的契约（两拍同步只防毛刺，不替软件兜在飞事务）。

### 9.6 上板验收（2026-10-28，bitstream `cbe6aa14…`）

**交付件**：`sim/reglogs/pds_devmap_p10.000/prj_tasks/pnr_1/generate_bitstream/yeshen_mini_board_top.sbit`
9,188,552 B，md5 **cbe6aa1495a301461557e66130a134c7**；PnR All Constraints Met
（soc_clk 106.4 MHz/+0.173，cpu 105.2，npu 62.4）。dev_map：LUT 55% / FF 38% / DRM 74% / APM 36%。

| 判据 | 结果 |
|---|---|
| 烧写 + 启动（8 项 marker） | PASS（含 SDR/misoHi、OpenSBI、Linux 5.10、liteeth slots、dropbear、登录） |
| **G2a 静态图案 64 B**（CPU `devmem` 写 0x801F0000） | **逐字节 MATCH**（作业 addr 0x001F0000/len 64） |
| **G2b 4 KiB 已知图案**（`0x5A^(i*13)`，CPU 写 → 服务读） | **逐字节 MATCH**（md5 `9a997be8…`，3 帧 1458+1458+1458，跨 tx 槽轮转） |
| **G2c 整帧 800 KB**（0x90000000 相机帧存） | **100% 收齐 586 帧，0.73 s（1.1 MB/s）**；PNG 见 `fb.png` |
| 交还（ETH_EN=0 → eth0 up） | PASS：`eth0 … inet addr:192.168.1.110`，ssh 恢复 |

**上板抓出的两个真缺陷（都已修 + 进 G2 变异对照）**
1. **帧中途的定时器弃帧**：`T_WAIT` 用"255 拍没有 tx 字节"判定请求结束；板上 DDR 取数
   在帧内会有 >2.55 µs 间隙 ⇒ 服务弃帧、core 卡半帧、DMA 通道常 busy（实测 BYTES=0x290、
   errCode=0）。改成"`tx_valid` 低 **且 core 不忙**"才结束。
2. **tx 槽跨度**：`slot<<7` 写成半个槽（应为 `<<9`）；只有 slot 0 恰好对。

**未决/边界**：`800 KB` 的图内容呈横向条纹/杂色 —— 与相机线（#517 CAM0 花屏）同源，
**不是本服务的数据通路问题**（静态图案 64 B / 4 KiB 双向逐字节已证）。tx 槽按 bit9 别名
一致（mod-4 旋转不是缺陷）。客户端当前逐帧串行，1.1 MB/s；要快可后续做批量请求/多帧在飞。
