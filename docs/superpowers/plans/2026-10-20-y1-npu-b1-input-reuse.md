# Y1-NPU B1 实施计划：宽层输入 tile 跨 co-block 复用

依据：`docs/superpowers/specs/2026-10-20-y1-npu-b-input-reuse-design.md`
基线：`y1cam` NPU 4.66 s/帧（0.215 fps）；**RTL 实口径**输入读 38.84 MB / 2.55×（B1 可省 ~24 MB）；工具表口径 68.65 MB / 4.50×（dw 对角趟被多算）。

## 任务（微切片，逐片交付物 + 闸门）

- **B1-T0 读计数基线**：新增 `y1/tools/read_account.py`（按 desc/wgt_index 算每单元
  nominal inB、co-block 重读 inB×nCo、总帧读字节）；正控 = 当前 67 MB、负控 = 把 nCo 改成 1
  时数值变（打印两行）。**交付物**：报告表 + 闸门 `run_read_account_ab.sh`。
- **B1-T1 RTL tileBuf**：`UnitExec.scala` 宽层加 8 KB tileBuf（8 ch × 34 × 34 B），
  `wide_x` 首次流式写入 tileBuf；同一 cib 的后续 cob 从 tileBuf 重放（不再发 DDR 读）。
  保持 `wide_x/x_valid/x_ready` 对外逐拍契约；窄层/旁路不动。
- **B1-T2 宽层 TB 闸门**：Conv_15 形状（C_in=32,C_out=64,160²）端到端逐字节 == 冻结黄金；
  新计数口 `gather_bytes` = nominal（不是 ×8）；tileBuf=9,248 B；scope=XDMA_EN=1；负控（cob 每次都重读）=> 计数红 + 数值仍对。
- **B1-T3 regen + 冻结检查**：所有网表重生成、md5 ×2 确定性；TILING=false 三网表 md5 不变；
  既有 9 道闸门全 PASS。
- **B1-T4 dev_map + PnR**：`YESHENMINI_SYNTH_MODE=speed`；记录 DRM/LUT 增量；
  `All Constraints Met` + 比特流。
- **B1-T5 上板 A/B**：同 C runner 跑 `y1cam --once`；`npu_ms` 与 12/12 输出 CRC 对账；
  目标 ≤2.1 s（≥0.47 fps）；报告写回 spec §5。

## 风险
- tileBuf 形状必须覆盖真实 tile（32×32 + halo 2 行/列）与 s=2；先在 B1-T0 用真实表核对
  最大 tile 与通道块。
- 重放顺序为 `cib 外、cob 内`；部分和 `PSB[cob]` 必须跨 cib 保留（NCOB=8 已够），
  但 `start` 只在 cib 首趟清相位——要在 TB 中显式验证跨 cob 的累加。
