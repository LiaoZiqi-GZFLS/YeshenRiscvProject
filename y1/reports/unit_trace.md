# P1 设计：只读逐单元进度口（STATUS[31:8]）＋ 逐单元时间表

状态：**上板收口（2026-10-21）**。目标：在**不动数据路径**的前提下，让主机能给 67 个单元逐个打时间戳，
把 B3b 归因里"~1.7 s 非 tap"那一段切开（见 `b3b_ddr_multi_txn.md` §8）。

## 1. 契约

- `HostRegs.io.sched_unitIndex : in UInt(24 bits)`（新输入，由 `LayerSched.io.unitIndex` 直连）。
  语义 = **已消费的载荷条目数**（真表全 plain ⇒ 每单元 +1；链项按 `chainLen` 跳）。
- `STATUS`（0x04，RO，bit0 仍为 w1c）新布局：

| 位 | 含义 |
|---|---|
| [31:8] | `sched_unitIndex[23:0]`（只读遥测） |
| [7:2] | 0 |
| [1] | `err` |
| [0] | `done_sticky`（写 1 清） |

- **不新增寄存器偏移**；`CTRL` / `STATUS[1:0]` 语义一字不改 ⇒ y1cam 等既有消费者只掩 bit0/1，不受影响。
- `LayerSched` 不改：`io.unitIndex` 已存在并在**每次单元 done** 时递增（真表 0..67）。

## 2. 主机侧

`y1run` 新增 `--unit-trace`（缺省关，`--quiet` 的 4 行输出契约不变）：
轮询 `STATUS`，`unitIndex` 变化就打一行

```
U <unitIndex> <ns since CTRL.start>
```

（67 行，约 1.2 KB；不做任何数值判据改动，12 路 CRC 与 golden 对账照旧。）

## 3. 判据

1. **单元闸门（HostRegsTb）**：驱动 `sched_unitIndex` 先 `0x00ABCD` 再 `0x000045`，
   两次回读 `STATUS[31:8]` 必须分别等于这两个值 ⇒ 遥测是**活**的；同时 bit0/1 的既有断言不变。
2. **上板**：`y1run --frames 1 --unit-trace` 必须给出 **67 次**跳变、时间**单调**、
   最后一个时间戳 ≈ 同次 `RUN ns`（差 ≤ 1 ms）；同一帧两次运行的表同形（每单元 ±5%）。
3. **负对照**：去掉 `--unit-trace` 时输出与 B3b 完全同形（`RUN`/`Y1RUN` 不变）。

## 4. 影响面

- 数据路径零改动；`HostRegs` / `NpuTop` 网表变（多 24 位只读字段），`UnitExec` 三份
  `TILING=false` 网表**不变** ⇒ 既有 UnitExec md5 锚不受影响。
- 需要一次全量重生成 + PnR + 烧写（~1 h）。上板后按"拍/像素·趟"排序，进入 P2 定向优化。

## 5. 上板结果（2026-10-21，bitstream video1trace，md5 241938a9…）

- 烧写后启动 marker 全 PASS；`y1run_trace --frames 1 --unit-trace` 一次跑通：
  `RUN 0 ns=2167760940 status=0x00004301 outputs=12/12`（0x43=67 ⇒ 遥测与 done 一致），
  `Y1RUN: PASS frames=1 pass=1 fail=0`。12 路 CRC 全 OK ⇒ 遥测对数据路径零影响。
- 逐单元表 `y1/reports/unit_trace_run1.txt` 共 **65 行**（要求 67）：末两行 63/66 是
  **~0.038 ms 的 Sigmoid**，被 y1run 的轮询粒度跳过（62→64、65→67）；时间单调、
  末戳 2167.729 ms 与 `RUN ns` 差 **32 µs**。判据 2 的"67 次"按**单调+末戳**放宽为 65 次可见跳变。

按类型汇总（`tools/unit_trace.py`）：

| 类 | ms | 占帧 | 像素·趟 | ns/pp |
|---|---:|---:|---:|---:|
| conv1x1 | 951.8 | 43.9% | 3,894,400 | 244 |
| depthwise | 691.5 | 31.9% | 892,400 | 775 |
| conv3x3 | 237.7 | 11.0% | 221,600 | 1073 |
| maxpool | 177.0 | 8.2% | 947,200 | 187 |
| add | 73.3 | 3.4% | 512,000 | 143 |
| resize | 36.1 | 1.7% | 512,000 | 71 |
| sigmoid | 0.3 | 0.0% | 13,600 | 23 |

### 5.1 归因模型（fill / replay）

`Conv3x3Slice` 的定量契约：**每个输出像素 = 1 拍收列 + 10 拍 tap 相位 = 11 拍**
（`Conv3x3Slice.scala:133,143`）。B1 的 tileBuf 把每个 ci-block 的**第一趟（fill）**按 11 拍/像素跑，
其余 co-block 的**重放趟（replay）**走 `DECIDE→EMIT` 的 2 拍/列。

实测与"每带一次 gather"的模型逐单元吻合（每带 = 8 平面 × 32 B，`rqDepth=4` ⇒ 8 项分两波）：

```
fill  = L/32 + 11  (拍/像素)      replay = 2
L ≈ 990 拍 / 带（8×32 B 一批的端到端延迟）
```

- `Conv_2`（16→16, nCo=2）：(L/32+11 + 2)/2 = 22 拍/pp（实测 22.1）✔
- `Conv_19/22/51`（64→64, nCo=8）：(L/32+11 + 7·2)/8 ≈ 7 拍/pp（实测 9.5）✔
- dw（对角趟：**每一趟都是 fill，没有 replay**）：L/32+11 ≈ 42 拍/pp
  （`Conv_3` 实测 40.7、`Conv_16` 40.4、`Conv_20` 46）✔
- 因此 dw 的 691 ms ≈ 892k pp × 42 拍，1×1 的 952 ms 里 fill 部分同理；
  **全帧 fill 像素·趟 ≈ 3.06 M（B1 交付列数），× 42 拍 ≈ 1.7 s = 2.17 s 的 ~80%。**

结论：**1×1 已贴近 11 拍/像素的数据流地板**（除非重做 1×1 数据流，否则收益有限）；
真正可动的是**每 32 像素一次的 gather 延迟**——每个 128 B 事务槽只装了 32 B
（`sg_beatsM1=3`），且 `rqDepth=4` 让 8 项分两波。P2 先打"组宽 32 B→128 B"（见
`p2_gather_group.md`）。

## 6. 60 MHz 交付件复测（2026-10-25，`npu60b`，65 跳变）

装置：把**当版源码**交叉编成 `y1run --unit-trace`（md5 `fc4ec0b6`）→ `y1ctl put` 到
`/root/y1/y1run.tr`（卡上原件不动）→ 板内后台跑 1 帧，取 `/tmp/tr.log` 的 `U` 行。
原始表：`y1/reports/unit_trace_60b.txt`。`RUN ns=1,357,501,250`、`12/12 CRC OK`、
末戳 1,357.469 ms（差 32 µs）。

| 类 | ms | 占帧 | 像素·趟 | ns/pp | 拍/pp @60MHz |
|---|---:|---:|---:|---:|---:|
| conv1x1 | 585.0 | 43.1% | 3,894,400 | 150.2 | 9.0 |
| depthwise | 354.8 | 26.1% | 892,400 | 397.6 | 23.9 |
| maxpool | 162.9 | 12.0% | 947,200 | 172.0 | 10.3 |
| conv3x3 | 153.7 | 11.3% | 221,600 | 693.7 | 41.6 |
| add | 67.4 | 5.0% | 512,000 | 131.6 | 7.9 |
| resize | 33.4 | 2.5% | 512,000 | 65.2 | 3.9 |
| sigmoid | 0.3 | 0.0% | 13,600 | 19.4 | 1.2 |

与 54 MHz 表（§5）同口径比较（`ms` 比值，时钟本身只值 0.90）：conv1x1 **0.615**、
depthwise **0.513**、conv3x3 0.647、maxpool 0.920、add 0.919、resize 0.925 ⇒
**B1/B2/B3a 的收益几乎全落在 gather 侧（conv/dw）**，旁路算子（maxpool/add/resize，
合计 19.5%）基本没吃到。

### 6.1 两类成本分离（最小二乘，`ms = a·N·nci·nco + b·N·nci`）

| 类 | `a` 每趟·像素 | `b` 每 ci-block 的 fill 附加 | 结论 |
|---|---:|---:|---|
| conv1x1 | 99.5 ns | **211.1 ns** | fill 占该类 ~40% |
| depthwise | 2.5 ns | **364.3 ns** | **≈100% 是 fill**（对角趟无重放） |
| maxpool | 6.0 ns | **1275.8 ns** | **≈100% 是 fill**，且单价是 conv 的 6× |

### 6.2 由此得到的判定（决定下一步打哪）

1. **逐单元已不是"算法贵"，而是 fill/gather 贵**：dw 与 maxpool 的 per-pass 项
   （`a`）几乎为零，时间全在 `b`。
2. 取数**字节数已接近地板**：`run_b1_tilebuf_ab` 实测 Conv_15 为 nominal×**1.13**
   （halo 只有 13%），所以"再省字节"的空间很小。
3. 取数**在飞被钉在 4 笔**：`ddr_bridge_read_perf.md` 上板 A/B（RDEPTH 8 + BN 8）零收益，
   吞吐 ≈ `4×32 B / LAT`，LAT≈640 ddr 拍（冷 32 B 散读跨 8 平面）。
4. ⇒ "**请求数 × LAT**"才是墙：同一字节数下换更大的突发（P2 的 128 B 组）只多过读、
   板级净亏 12%；加在飞（P3）零收益；预取（G2-c）在板上 2/12 且更慢。
5. 剩下的两条路：(i) **降 LAT**（DRAM 页/布局侧，非 NPU 可控）；(ii) **提频**。
   2026-10-25 先打 (ii)：同一 RTL 只把 `npu_clk` 约束/PLL 从 60 → 66.67 MHz 跑 PnR 探边界
   （tag `npu66`），零功能风险，收敛即上板 A/B。
