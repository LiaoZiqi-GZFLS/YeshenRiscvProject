# 上板日志说明

均为原始抓取或工具输出，未做内容改写（仅个别文件来自 UART 抓取）。

| 文件 | 时间 | 判据 |
|---|---|---|
| `fv_flash.out` | 2026-11-03 23:24 | PDS `cfg_program` 输出：`Finish program …pds_cpu130_20261102.sbit`，`The done bit is 1`，耗时 7.7 s；随后 scan chain 读到 done=1 |
| `fv_boot.txt` | 2026-11-03 23:24–23:30 | 固化后串口抓取：Linux 6.18.60 启动、`YGUI-BOOT`、`VEXIIYESHEN-OK`（23:30 有一次重新上电后的再次启动） |
| `bootsel_C_live_20261104.log` | 2026-11-04 00:36 | UART 抓取（从中段开始）：`YGUI-BOOT` / `GPU-UNIT-ON` / `VEXIIYESHEN-OK` |
| `bootsel_C_live_20261104b.log` | 2026-11-04 01:02 | SdLoader 菜单 `C=CoreMark` 输出：ITERS=20000，Total ticks 3,427,438,024，583.526233 iter/s，crcfinal `0x382f`，`Correct operation validated` |
| `write_sd_raw_sd_score_618zbb_i20000_elev.out` | 2026-11-04 00:55 | 跑分卡 raw 写入回读：`WROTE 16840192` / `CARD VERIFY PASS`，两侧 sha256 均为 `f7407be2…` |
| `pnr_cpu130_seed0.log` | 2026-11-02 | cpu130 PnR 运行日志（单种子 `-gplace_times 1`），完整 PDS 工程目录未归档 |
| `gen_sbit_cpu130.log` | 2026-11-02 | 从 cpu130 PnR 工程生成比特流的日志 |

## 关键行

```
# fv_flash.out
[2026.11.03 23:24:05]Finish program D:/code/PDS/VexiiYeshenLinux/deliver/sbits/pds_cpu130_20261102.sbit
The done bit is 1
This device configure situation (done bit): 1

# bootsel_C_live_20261104b.log
Iterations/Sec   : 583.526233
Iterations       : 20000
[0]crcfinal      : 0x382f
Correct operation validated.
CoreMark 1.0 : 583.526233 / GCC11.2.1 20211120 -Ofast-upstream / STATIC
5.84 Coremark/MHz
```

> 日志中的 `5.84 Coremark/MHz` 是 CoreMark 二进制按其 `EE_TICKS_PER_SEC=100 MHz` 计时基准打印的值；CPU 实际 130.645 MHz。比赛换算口径以赛事规定为准。
