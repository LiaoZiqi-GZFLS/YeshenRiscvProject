# NpuMemCdc R 通道吞吐量化（2026-10-22）

目标：回答“NPU 取数 22–24 MB/s 是不是被 NpuMemCdc 的 R 通道（8 B/拍、4 lanes 四相）卡住”。

## 装置
`y1/rtl_test/NpuMemCdcPerfTb.v` + `y1/gen/NpuMemCdc.v`（iverilog）：
- npu_clk 侧：读主口背靠背发 `NAR` 笔 READ（`arlen=ALEN`，地址 +32B 递增），R 端 `rready=1` 全速收；
  统计首笔 AR 握手到最后一拍 R 的**拍数**。
- cpu_clk 侧：极简读从口（8 深 AR 队列、按序回 R），每笔首拍前插 `+LAT` 拍；
  数据只是递增计数器（本装置**只测速率**）。
- 默认时钟：cpu 100 MHz / npu 54 MHz（板级值）。

## 结果（4 拍突发 = 32 B）

| LAT（cpu 拍/笔） | beats/cycle (npu) | B/cycle | MB/s @54 MHz |
|---:|---:|---:|---:|
| 1 / 2 / 4 / 8 | **0.444** | **3.55** | **191.8** |
| 16 | 0.336 | 2.69 | 145.2 |
| 64 | 0.106 | 0.85 | 45.7 |

- 16 拍突发（`ALEN=15`）与 4 拍突发**同吞吐**（LAT≤8 时都是 0.444 beats/cycle）。
- AR 接受率 0.111 笔/cycle（1 笔/9 拍），不是限流点。
- 0.444 beats/cycle ≈ 4 beats / 9 npu 拍 = 4 lanes × 8 B / 单道四相往返（~9 拍）。

## 结论
- **NpuMemCdc 本身能到 ~192 MB/s（板级 npu_clk 54 MHz），约为板级实测取数 ~22–24 MB/s 的 8–9 倍
  ⇒ 它不是取数瓶颈**；“加 lanes”这条方向可以停。
- 瓶颈在 **DDR 侧读服务**（DDR3Bridge/IP/DRAM 的 32 B 事务与在飞数）：桥侧 DEPTH=4 的
  32 B 读在真实 IP 延迟下只跑出 ~0.4 B/npu 拍。
- 下一步该量的是桥：`DdrMaster`/`DDR3Bridge` 读 32 B 事务的**延迟-吞吐曲线**（在飞 1/2/4/8 对照），
  以及同样在飞数下 32 B vs 128 B 连续突发的差别；再决定“加桥 DEPTH”还是“改取数事务形状”。
