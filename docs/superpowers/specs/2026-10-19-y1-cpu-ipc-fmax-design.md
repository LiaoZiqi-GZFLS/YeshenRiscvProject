# Y1 CPU：CoreMark/MHz 提升 + 模块综合频率提升 —— 设计

- 日期：2026-10-19
- 状态：用户已确认设计，进入实施
- 基准：`VexiiYeshenLinux` 当前核（`rtl/vexiiriscv/VexiiRiscv.v`，md5 `24dfc978afb437f5f08024873dbc3a9c`）
- 范围：纯仿真 + ADS 模块综合；不烧板、不跑全 PnR、不改 CoreMark 编译器 flag

## 1. 目标与非目标

**目标**

1. **第一阶段**：在核心模块综合 Fmax **不低于基线**的前提下，提高 CoreMark/MHz（当前仿真基线 4.4723）。
2. **第二阶段**：在最终 CM/MHz 不低于 4.4723 的前提下，提高模块综合 Fmax（当前基线 108.79 MHz）。
3. 交付 CM/MHz vs Fmax 的帕累托前沿（至少：最高 IPC、最高 Fmax、平衡点），由用户选择最终配置。

**非目标**

- 板级烧写、Linux 启动验证、y1run 回归（本阶段只保证模块综合口径）。
- 全 PnR 频率认证（模块综合与 PnR 基线相差约 1.6%，最终上板前仍需一次 PnR）。
- 修改 CoreMark 二进制或编译选项（保证与既有基线同口径）。
- 修改 `third_party/VexiiRiscv` 原仓库（配置变体在本地副本中生成；RTL 改动在独立副本中做，patch 入仓）。

## 2. 基线证据

| 项 | 数值 | 来源 |
|---|---|---|
| 核网表 | md5 `24dfc978afb437f5f08024873dbc3a9c`，29,693 行 | `rtl/vexiiriscv/VexiiRiscv.v` |
| CoreMark 仿真 | 2,235,970 ticks / 10 iter → **4.4723 CM/MHz**；CRC `e714/1fd7/8e3a`，`crcfinal 0xfcaf` | `sim/reglogs/cpu_coremark_i10_lat1.log` |
| 模块综合 | **108.7903 MHz** @ 10 ns 请求，slack **+0.808** | `sim/reglogs/pds_syn_core_probe` |
| PnR 交叉校验 | cpu_clk 107.0893 MHz（WNS +0.662） | `sim/reglogs/pds_pnr_c4a_cpufast_p10.000` |
| 综合头号路径 | `BranchPlugin_BRANCH_CTRL_lane1` → `PcPlugin_self_increment/D`，19 级，logic 2.68 ns / route 6.33 ns | 同上 |
| PnR 头号路径 | late ALU SRC1 → ADD_SUB → BranchPlugin COND → History → BTB/RAS → FetchL1 bank mux，22 级 | `yeshen_mini_board_top.rtr` |

测量口径：

- 仿真：`sim/cpu_coremark`，i10、`mem_lat=1`，`CoreMark/MHz = iterations × 10^6 / Total ticks`。
- 模块综合：核顶层单独 `synthesize -ads`，10 ns 时钟，`Fmax Summary` + `Setup Path Summary`。
- 资源：综合报告 `synthesize_resource_utilization.db` / `resource_usage.db`。

## 3. 实施阶段

### Phase 0：基线锁定与流水线

- `scripts/core_profiles/base.args` 保存当前核完整生成参数。
- `scripts/gen_core_variant.sh`：在 `sim/reglogs/vexii_perf_repo`（`third_party/VexiiRiscv` 的独立副本）中生成网表到 `sim/reglogs/variants/<tag>.v`；原仓库零改动。
- `scripts/bench_core.sh`：WSL Verilator 独立 `obj_dir` 构建 + CoreMark 运行 + 分数/CRC 解析。
- `scripts/synth_core.sh`：PDS 核模块单独综合 + Fmax/关键路径/资源解析。
- **基线三重证明**：base profile 生成网表 md5 必须逐字节等于 `24dfc978…`；仿真 ticks/CRC 复现；综合 Fmax/slack 复现。

### Phase 1：提高 IPC，频率不降（硬门）

候选变体（每项单独 A/B，均基于 base）：

| 变体 | 参数 | 预期机制 |
|---|---|---|
| gshare8k / gshare16k | `--gshare-bytes 8192/16384` | 增大条件分支历史表，降别名 |
| gshare_banks2 | `--gshare-banks 2` | 分 bank，缩短读路径（偏时序） |
| btb1024 / btb2048 | `--btb-sets 1024/2048` | 增大 BTB 容量，降冲突 |
| btb1024_g8k | 组合 | 容量叠加 |
| sb8 | `--lsu-l1-store-buffer-slots 8 --lsu-l1-store-buffer-ops 64` | 提高 store 吞吐 |
| fetch_refill2 | `--fetch-l1-refill-count 2` | 提高 I$ 填充带宽（不带 NL 预取） |
| lsu_refill2 | `--lsu-l1-refill-count 2` | 提高 D$ 填充带宽 |
| div_ipc | `--div-ipc` | 除法 IPC 优先实现 |
| decoders4 | `--decoders 4 --lanes 2` | 加宽取指/解码（执行宽度不变） |
| regfile_async | `--regfile-async` | 异步寄存器堆，缩短取操作数延迟（时序风险） |

每个变体：

1. 生成到独立网表；netlist md5 必须与 base 不同，否则判为无效变体。
2. Verilator 仿真；阶段 CRC 必须精确匹配；记录 ticks、CM/MHz、Δ%。
3. 分数 > 4.4723 的变体跑模块综合；**Fmax ≥ 108.79 MHz** 才进入 Phase 2 候选池。
4. 若仿真卡死：先用 base 在同台架做 known-good 对照，再判定变体无效；不允许直接改 RTL 掩盖。

### Phase 2：提高频率 / 帕累托

先做时序旋钮（每项同样过仿真 CRC + 模块综合）：

| 变体 | 参数 | 攻击路径 |
|---|---|---|
| relaxed_btb | `--relaxed-btb` | BTB 预测应用推迟一拍，缩短 read→jump 路径 |
| relaxed_btb_hit | `--relaxed-btb-hit` | BTB hit 计算推迟一拍 |
| relaxed_branch | `--relaxed-branch` | lane1 早分支判决推迟一拍 |
| tags_async | `--fetch-l1-tags-read-async --lsu-l1-tags-read-async` | 标签异步读，缩短查找路径 |
| mmu_sync | `--mmu-sync-read` | MMU 存储同步读 |
| ways4 | `--fetch-l1-ways 4` | 缩短 I$ way mux（容量降到 16 KiB） |
| disp2 | `--dispatcher-at 2` | 派发加一级，切分调度路径 |
| 组合 | 上述有效项组合 | 帕累托前沿 |

若仍不足以提升 Fmax，则建本地 RTL fork（`sim/reglogs/vexii_perf_fork`，原仓库零改动），只动综合/PnR 共同指出的关键路径：

1. 分支判决 → PC 更新 / 前端 valid（寄存器化或切分组合逻辑）。
2. 分支历史 → BTB/RAS → FetchL1 bank mux（预测更新延后一拍或拆分）。
3. RAS 深度 4 → 8/16（`Param.scala` 当前硬编码 4）。
4. GShare history width 12 → 14/16（当前硬编码 12）。

每项 RTL 改动必须：

- 仿真 CRC 全对；
- 留下“改前/改后”的模块综合关键路径与 Fmax；
- patch 落盘到 `scripts/patches/`，记录 base commit `ecfd4930bb079af4dea0dba49417f0ad2822dfe8`；
- 若 IPC 回退，保留为帕累托点，不直接丢弃。

## 4. 判据与负对照

- **正判据**：`crcfinal` 存在；`[0]crclist/crcmatrix/crcstate` 精确等于 `e714/1fd7/8e3a`；ticks 可复现。
- **频率判据**：ADS `synthesize -ads` 10 ns；`Fmax Summary` 对比 108.7903 MHz；Phase 1 硬门，Phase 2 帕累托。
- **负对照**：
  - 变体 md5 与 base 相同 ⇒ 该变体无效（参数未生效），不是“参数没影响”。
  - 用 base 网表在同一台架复跑，必须复现 2,235,970 ticks。
  - 关键路径报告必须能指出具体 startpoint/endpoint；没有路径差异的“频率提升”判为不可信。
- **确定性**：同一 profile 连续生成两次，网表 md5 必须一致。

## 5. 风险与边界

| 风险 | 处理 |
|---|---|
| 模块综合比 PnR 乐观约 1.6% | 只做相对比较；Phase 1 要求 Fmax 不降，Phase 2 报告绝对 Fmax 并注明口径 |
| 变体导致仿真挂死 | 同台架 base known-good 对照 + 握手状态定位；不先改 RTL |
| 参数被静默忽略 | 强制检查变体 md5 不同；记录生成参数与行数 |
| 本地 RTL fork 与上游漂移 | 固定 base commit，patch 入仓，原仓库零改动 |
| 面积超限 | 记录 LUT/FF/DRAM/DRM/APM；若某变体资源增长过大，在帕累托表中标注 |

## 6. 交付物

- `scripts/core_profiles/*.args`：所有变体参数。
- `scripts/gen_core_variant.sh`、`scripts/bench_core.sh`、`scripts/synth_core.sh`、`scripts/parse_synth_timing.py`。
- `y1/reports/cpu_perf_ipc_fmax.md`：基线、变体矩阵、关键路径、复现命令、帕累托表。
- 最终选定的 profile 与（如使用）RTL patch；在用户拍板前不修改 `rtl/vexiiriscv/VexiiRiscv.v` 与 `scripts/gen_core.sh` 的默认配置。

## 7. 已确认决策

| 项 | 决定 |
|---|---|
| 改动范围 | 配置优先；必要时本地 RTL 副本，原 `third_party/VexiiRiscv` 零改动 |
| 频率判据 | ADS 模块综合 Fmax（10 ns，核顶层单独综合） |
| 第二阶段取舍 | 交付帕累托前沿，由用户选择；不预设固定 IPC 换频率比例 |
