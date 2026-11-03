# Y1-DMA **Phase-1** 判词 —— §3.5 合并点换成**真仲裁器**（加权配额 + 老化防饿死）

- 日期：2026-10-13
- 上游：`docs/superpowers/specs/2026-10-13-y1-soc-dma-engine-design.md`（§2 家底、**§3.1 裁决=C + 四相顺序**、
  §5 D4、§6 R2）、`docs/superpowers/plans/2026-10-13-y1-soc-dma-engine.md` **Phase 1（T1.1–T1.3）**、
  `y1/reports/dma_phase0.md`（Gate-P0 = CAN）
- 交付：`src/soc/MemArbiter.scala`（新）、`src/YeshenSocGlue.scala`（§3.5 改造）、`rtl/YeshenSocGlue.v`（重生成）、
  `sim/memarb/*`（新单元闸门）、`sim/glue_pbus/{tb_memmerge.cpp,run_memmerge_unit.sh,gen_glue.sh,negctl_memmerge.sh,memmerge_golden.txt}`（新）
- 本轮**不跑 PDS / PnR**（按任务口径：控制器跑 PnR）⇒ 面积只给**网表级**口径 + 待跑命令。

---

## 0) ★ Gate-P1 判词（先给结论）

> **成立。** §3.5 合并点的主人口选择已由"一个 `npuTurn` 位 + 组内固定优先级"换成 **`MemArbiter` 真仲裁器**：
> **加权轮转（配额）+ 老化提升（防饿死）**，**类可参数化**（Phase-2 的 DMA 引擎 = 加一个类 + 一个 `req` 连线）。
> 三条判据**全绿，且每条都有能翻红的负对照**：
>
> | 判据 | 阳性（本轮实测） | 负对照（必须翻红） |
> |---|---|---|
> | **有界等待 / 无饿死**（正） | 并发下每类最坏授权延迟 ≤ **14 拍**（上界 64）；单类最坏 **错过 3 次**授权机会 | NC_A/NC_MM1 **配额清零** ⇒ 该类 **0 笔授予**、跑不完 ⇒ 红 |
> | **配额（优先级）**（正） | 类间授予比 CPU:NPU = **2.001**（胶合层）/ CPU:NPU:DMA = **2.000:1.000:1.000**（单元层） | NC_B/NC_MM2 权重打歪 ⇒ 比掉到 ~1:1 ⇒ 红 |
> | **单主人逐字节不变**（回归） | 24 笔×3（含读写混）transcript 与**改动前网表**记的 golden **72 行 vs 72 行、差异 0 行** | 见 NC_D（单主人路径插气泡 ⇒ J4 红） |
>
> **代价（网表级）**：`rtl/YeshenSocGlue.v` **+23 个 FF 位**（5303 → 5326）、**+1 个模块**（`MemArbiter`）、
> +3 523 B（143 251 → 146 774）。折成器件占比 ≈ **+0.007% FF**（器件 319 600 FF）——**可忽略**。
> **时序未测（本轮无 PnR）** ⇒ R6 的"每相重跑 PnR"含本相，命令见 §6。
>
> **建议**：**继续 Phase-2**（多通道 DMA 引擎 + 客户端接入）。§3.5 的接口已经把"第 6 个主人"做成参数。

---

## 1) 仲裁策略（冻结）：**WRR（配额）+ 老化（防饿死）**

`src/soc/MemArbiter.scala` 是**纯调度逻辑**（不含任何 AXI 通道），接口三件事：
`req(c)`（第 c 类有请求）/ `free`（总线空闲、可授予）/ `pick`+`pickV`（本拍授予谁）。
调用方（`YeshenSocGlue` §3.5）负责**持有授权到事务完成**（`rlast`/`b`）——**一次仍只有一笔在飞**。

| 机制 | 做什么 | 为什么 |
|---|---|---|
| **① 加权轮转（WRR）** | 每类一个**权重**`WEIGHTS(c)`；轮转指针服务完一类的配额才换下一类。持续争用 ⇒ 授予次数比 = **权重比** | 这就是 spec §6 R2 要的"**优先级/配额**"：`Seq(2,1,1)` = CPU 组:NPU:DMA ≈ 2:1:1 |
| **② 老化提升** | 每类一个 `age(c)`：**每当"它想要 + 总线空闲、却没被授予"（= 错过一次授权机会）就 +1**（饱和）；`age ≥ AGE_MAX` ⇒ 进 **starving** 集合、**压过配额直接当选**（多个取 `age` 最大者）；被授予/撤销请求则清零 | **防饿死**：任何**连续**有请求的类，最迟在 **`AGE_MAX + 1` 次授权机会**内必得一次授予（有界等待） |
| **③ 权重 0 = 结构性不可达** | 权重 0 的类**既不进轮转、也不进老化提升** ⇒ 永远拿不到授予 | 负对照打的就是这一处（"配额退化 ⇒ 饿死"是可证的结构事实，不是巧合） |
| **④ 类内优先级** | CPU 组：LSU 写 > LSU 读 > Fetch 读；NPU：写 > 读 | **改前就有的**固定优先级，Phase-1 一字未动（只在"类之间"换仲裁） |

### 1.1 有界等待的**证明口径**（不是"看起来还行"）

- **WRR 本体**：稳态下每类在每个"总权重 `W = Σweight` 的轮次里至少出现 `weight(c)` 次 ⇒ 连续请求的类
  最多**被跳过 `W-1` 次**（`(2,1,1)` ⇒ ≤ 3 次）。
- **老化守卫**：把"跳过次数"硬压到 `AGE_MAX`；`AGE_MAX = 32` 时，`(2,1,1)` 下老化**从不触发**
  （实测 `starveCyc = 0/0/0`，见 §2.1）⇒ **配额不被扰动**；而若权重被打成"一类独大"，老化会把它
  拉回有界（这正是 `AGE_MAX` 存在的意义：**与权重无关的硬上界**）。
- **折算到拍数**：授权机会只在"总线空闲"那拍出现，而空闲来自"上一笔事务完成" ⇒
  **最坏授权延迟 ≤ `AGE_MAX ×（单笔事务上限）` + 常数**。

### 1.2 ★ 开发中实测到一个**反直觉的真坑**（已修，写进文件头）

第一版把 `age` 写成"**有请求却没被授予就每拍 +1**"。后果：**总线正忙（`free=0`）时所有在等的类一起加计**，
于是**刚被服务过的类在下一段忙碌里又攒满 `age`**；多种类同时 starving 时按"类号小者"tie-break ⇒
**类号小的那个垄断**，低优先类**真的被饿死**（实测 `longTX` 作业：DMA 拿 0 笔、starving 拍了 199 971 次）。
修法两条：① 计数口径改成**授权机会**（只在 `free` 的拍上加）；② tie-break 改成**取 `age` 最大者**
（"最久的那个"才是防饿死）。**⇒ "每拍加计"看着更保守，实际更饿死**。

---

## 2) 判据（先红后绿；正负对照逐条）

### 2.1 单元闸门 `sim/memarb/`（`MemArbiter` 单独判，N=3 / W=(2,1,1) / AGE_MAX=32）

装置把它当"授权调度器"判：每拍给 `req/free`，采 `pick/pickV`；授予后让总线忙 `T∈[1,3]` 拍。

```
=== MemArbiter 单元判决（N=3, W=(2,1,1), AGE_MAX=32, BOUND_OPP<=6, BOUND_CYC<=40）===
  [JOB stress ] grants CPU=32445  NPU=15136  DMA=19022  | maxLat 12/16/16 cyc | maxMiss 2/3/3 | starveCyc 0/0/0
  [JOB full   ] grants CPU=33316  NPU=16657  DMA=16657  | maxLat 12/16/16 cyc | maxMiss 2/3/3 | starveCyc 0/0/0
  [QUOTA] CPU:NPU = 2.000 (期望 ~2.0) | DMA:NPU = 1.000 (期望 ~1.0)
  [GUARD] 正常权重下各 starving 拍数 = 0/0/0（应为 0 ⇒ 配额不被老化扰动）
  [SINGLE CPU] grants=10000 maxLat=2 maxMiss=0（另两类 0 授予）
  [SINGLE NPU] grants=10000 maxLat=2 maxMiss=0（另两类 0 授予）
  [SINGLE DMA] grants=10000 maxLat=2 maxMiss=0（另两类 0 授予）
=== TEST PASSED ===
```

- **J1 有界等待**：每类最坏 `miss`（错过的授权机会）= **2/3/3 ≤ 6**（WRR 理论上界 3）；最坏 `lat` = **16 拍 ≤ 40**。
- **J2 无饿死**：三类各 ≥ 15 136 笔授予。
- **J3 配额**：满争用下 `CPU:NPU:DMA = 2.000:1.000:1.000`（**权重比精确到 3 位小数**）。
- **J4 单主人不变性**：只有一类有请求时，它 **miss = 0**（每个空闲拍都被授予，零附加延迟）、另两类 **0 授予**。
- **J6 守卫不扰动配额**：正常权重下三类 `starving 拍数 = 0` ⇒ 老化不触发 ⇒ 配额就是权重比。

**负对照 4 条（全部按期望翻红）**：

| NC | 打法（源码单行变异 + 重生成） | 结果 |
|---|---|---|
| **NC_A ★ 必须** | `GEN_WEIGHTS = Seq(2,1,1)` → `Seq(2,1,0)`（第 3 类配额清零） | **J1「某类一次都没被授予（等待=无界）」+ J2「授予 < 下限」** 翻红 |
| NC_B 配额比打歪 | `Seq(1,1,1)` | J3（CPU:NPU 不在 2:1 窗口）翻红 |
| NC_C 授权门与空闲脱钩 | `io.pickV := io.free && anyReq` → `:= anyReq` | J5（出现 pickV=1 而 free=0）翻红 |
| NC_D 单主人插气泡 | `io.pickV` 额外要求 `budget =/= 0` | J4（单主人出现附加延迟 / 授予次数塌掉）翻红 |

### 2.2 胶合层闸门 `sim/glue_pbus/`（`YeshenSocGlue` 网表，真三个主口驱动 + 64bit INCR 内存模型）

```
=== YeshenSocGlue 内存合并点判决（真仲裁，BOUND_MM=64 拍）===
  [REGRESS] 单主人 transcript：golden 72 行 / now 72 行，差异 0 行
  --- C1：cpuLsu + npuMem 同时各跑 300 笔 ---
  [LAT] 主 1：maxAr=9 maxAw=2（读 150 / 写 150）
  [LAT] 主 2：maxAr=10 maxAw=14（读 150 / 写 150）
  [LAT] C1 最坏授权延迟 = 14 拍（上界 64）
  --- C2：cpuFetch + npuMem 同时各跑 300 笔 ---
  [LAT] 主 0：maxAr=9 maxAw=0（读 300 / 写 0）
  [LAT] 主 2：maxAr=9 maxAw=13（读 150 / 写 150）
  [LAT] C2 最坏授权延迟 = 13 拍（上界 64）
  [DISC] io_mem：AR=798 AW=474 W=1422 B=474 rlast=798
  --- J_MM4：cpuLsu + npuMem 持续争用 30000 拍 ---
  [QUOTA] 类间授予比 CPU(cpuLsu):NPU = 4000:1999 = 2.001（权重 2:1 ⇒ 期望 ~2.0）
=== TEST PASSED ===
```

- **J_MM1 并发多主 + 有界等待**：C1/C2 两套并发配置下，**每个主口 300 笔全部完成且逐字节对**
  （读回 vs 装置独立算出的图案），最坏授权延迟 **14 / 13 拍**。
  ⚠️ **为什么不做 `cpuLsu + cpuFetch` 同时背靠背**：CPU 组**类内**仍是改前的固定优先级（LSU 让位 Fetch 之外），
  两主都背靠背时 Fetch 必然让位给 LSU —— 这是**改前就有的设计**（Phase-1 不动它），
  **不是本相引入的饥饿**（见 §5 残余）。C2 用 `cpuFetch + npuMem` 单独证明 Fetch 主方也**有界**。
- **J_MM2 单主人逐字节不变（回归）**：见 §3。
- **J_MM3 纪律**：`AR 与 AW 从不同拍`（读写互斥，§4 的【纪律②】）、每笔读恰一次 `rlast` 且在末拍、
  每笔写恰一次 B、读响应恒 OKAY —— 全绿（AR=798 / AW=474 / W=1422 / B=474 / rlast=798）。
- **J_MM4 类间配额**：持续争用 30 000 拍 ⇒ `CPU:NPU = 4000:1999 = 2.001`。

**负对照 2 条（全部按期望翻红）**：

| NC | 打法 | 结果（实测） |
|---|---|---|
| **NC_MM1 ★ 必须** | `ARB_WEIGHTS = Seq(2,1,1)` → `Seq(2,0,1)`（**类 1 = NPU** 配额清零） | **`npuMem` 0/300 拿不到授权** → 「作业没跑完」「主 2 没跑完」+ J_MM4 一起翻红 |
| NC_MM2 配额比打歪 | → `Seq(1,1,1)` | J_MM4（授予比不在 2:1 窗口）翻红 |

（两次负对照跑完都 **恢复源码 + 重生成网表**，核对 `rtl/YeshenSocGlue.v` 的 md5 与跑前**逐字节一致**：
`93af17cd003a7573415b6fa39f562941`。）

---

## 3) 单主人回归：**逐字节不变**怎么证的

`memmerge_golden.txt` 是**改动前**网表（`6e64f8c:rtl/YeshenSocGlue.v`）跑同一装置记下的**规范 transcript**：
每笔事务一行 `TX <主号> <R|W> addr=… len=… beats=… data=<逐拍 16 进制>`（**完成序 + 地址 + 长度 + 每一拍数据**）。
改动后同装置 `--compare` 逐行比：

```
[REGRESS] 单主人 transcript：golden 72 行 / now 72 行，差异 0 行
```

⇒ 三个主口各自单独跑（cpuFetch 24 读 / cpuLsu 12 读+12 写 / npuMem 12 读+12 写，突发长度 0..3 混）
**顺序、地址、长度、逐拍数据全同**。「逐字节」= transcript 逐行比 + 装置内的**逐字节对账**双保险。
（**比的是数据/顺序，不是拍数** —— 拍数本可因仲裁多一个 turnaround 而合理地变；本轮实测没变。）

---

## 4) 回归 + 记账

### 4.1 15 个单元闸门 + 台账 + dangling（实跑）

```
run_ddrmaster32_ab=0 run_desc_ab=0      run_fusionbuf_ab=0 run_bypass_ab=0   run_unitexec_ab=0
run_fuse_head_ab=0  run_fuse_ab=0       run_chain_ab=0      run_sched_ab=0    run_nputop_ab=0
run_nputop_sched_ab=0 run_hostregs_ab=0 run_ddrcopy_ab=0    run_ddrread_ab=0  run_ddrwrite_ab=0
```
（15/15 `rc=0`。）

```
python scripts/check_addr_map.py        -> PASS: address ledger consistent (16 sites reconciled)  rc=0
python y1/tools/check_dangling.py rtl/YeshenSocGlue.v
    -> defined modules: 12 | distinct instantiated: 11 | total dangling instances: 0 | RESULT: PASS
python y1/tools/check_dangling.py y1/gen/{NpuTop,LayerSched,UnitExec,MultiPassUnit,DwUnit}.v
    -> 五处全 RESULT: PASS
```
（台账站点数仍 **16** —— 本相**没有**动地址窗/`EXPECT`/`check()`，故 +0。）

**既有 glue 回归**（`rtl/YeshenSocGlue.v` 换新后重跑）：
`sim/glue_pbus/run_unit.sh`（pBus 译码）与 `run_npu_unit.sh`（NPU 寄存器窗）= **TEST PASSED**。

### 4.2 ★ 闸门运行环境的一个坑（顺手记下，避免下次误判）

15 个 `run_*_ab.sh` 里有 13 个要**同时**有 `python`（不是 `python3`）与 `iverilog`：
- 在 **WSL** 里跑 ⇒ `python: command not found` / `python3` 读不到 `desc_table.TABLE_MD5_FROZEN`
  ⇒ **13/15 假红**（`rc=1/2/3`；只有 `run_fusionbuf_ab`/`run_bypass_ab` 两个不受影响）。
- 在 **git-bash（Windows）** 里跑 ⇒ 走 `/c/msys64/ucrt64/bin/{python3,iverilog}` ⇒ **15/15 rc=0**。
⇒ **本相的 15 闸门读数取自 git-bash**；WSL 那份日志只作"环境不对"的对照，**不算判据**。

### 4.3 面积 Δ（**网表级**口径，− PDS）

| 口径 | 改前 `rtl/YeshenSocGlue.v` | 交付 | Δ |
|---|---|---|---|
| `reg` 语句数 | 359 | 367 | **+8** |
| **FF 位宽合计** | **5 303** | **5 326** | **+23** |
| 模块数 | 11 | 12 | **+1**（`MemArbiter` 独立成模块） |
| 行数 / 字节 | 4 572 / 143 251 | 4 702 / 146 774 | +130 行 / **+3 523 B** |

- +23 位 FF 的构成**逐位对得上**：`MemArbiter` 的 `turn(2)+budget(2)+age×3(18)=22` 位，加 `owner` **3→4 位**（+1）。
- 折算：+23 FF ≈ **+0.007%**（器件 319 600 FF；板级现用 113 382 FF = 36%）。**板级的紧资源是 CLMA/CLMS**
  （C3/C4b 在 ~90–91%），本相增项是**寄存器 + 窄 mux/比较器**（不是进位链）⇒ 对 CLMS 影响应小，**但未测**。
- **时序未测**。新增关键路径：`age(c) >= AGE_MAX` 的 6 位比较 + `starveIdx` 的 3 路 `age` 比较 + 3 路 `req` 扫描。

---

## 5) 能证 / 不能证

**能证（本轮实测）**
1. §3.5 的主人选择是**真仲裁器**：类可参数、配额 = 权重（实测 2.000/2.001 精确对齐）、
   防饿死有**与权重无关的硬上界**（`AGE_MAX`），且正常权重下不触发（不扰动配额）。
2. **并发多主有界等待**：胶合层两套并发配置下每主 300 笔全部完成、逐字节对、最坏授权延迟 ≤ 14 拍。
3. **单主人逐字节不变**：与改动前网表的 golden transcript **72/72 行、差异 0**。
4. **每条判据都能翻红**（单元 4 条 + 胶合 2 条负对照，全部按期望红）。
5. 既有互联未受影响：15 单元闸门 + 台账（16 站点）+ dangling + 两个 glue 既有装置全绿。
6. 面积代价**很小且逐位可解释**：+23 FF / +1 模块。

**不能证 / 有条件**
1. **时序/器件面积未测**（本轮无 PnR）⇒ R6 **未关闭**，见 §6。
2. **胶合层只覆盖了两个类**（CPU 组 / NPU）：第三类（DMA）在**胶合层**没有客户端可驱（`dmaPend=false`），
   **三类的公平性只有在单元闸门里**用合成请求证过。Phase-2 接上真 DMA 客户端后要**在胶合层重证一遍**。
3. **CPU 组类内仍是固定优先级**（LSU > Fetch）：两主都**背靠背**时 Fetch 会让位给 LSU。
   这是**改前就有的设计**，Phase-1 未改（也没要求改）。⇒ 若 Phase-2/3 要"Fetch 与 LSU 也要公平"，
   那是在**类内**再加一层轮转（另一次改动），本相没有做、也没有声称做过。
4. **"装载器 / DMA"这一路（§4 的 `memSel` 一热 mux）本轮未动**：它现在仍是"装载器 vs CPU"的
   一热选通（板级语义上两者本就互斥：装载期 CPU 被扣复位）。**Phase-2 接 DMA 时这里是下一个改造点**（见 §7）。
5. **不是真 IP/真板**：内存模型是本装置的行为模型（固定 1 拍读延迟 + INCR），
   真 `DDR3Bridge` 的多未完成时序未在板上验。

---

## 6) 待跑的 PnR（**控制器执行**，本轮不跑）

```bash
# 工作目录 = D:/code/PDS/VexiiYeshenLinux（前置：rtl/YeshenSocGlue.v 已按新源码重生成，md5 见 §7）
/c/Pango/PDS_2025.2-ads/bin/pds_shell.exe -file y1/pds/pnr_c4a.tcl \
    > y1/pds/pnr_dma_p1.log 2>&1 ; echo "exit=$?"

# 面积（dev_map，同一 tcl 的 integrated 档；与 C4b 的权威读数对照算 Δ）
/c/Pango/PDS_2025.2-ads/bin/pds_shell.exe -file y1/pds/devmap_c4a.tcl \
    > y1/pds/devmap_dma_p1.log 2>&1 ; echo "exit=$?"
# 取数：grep -nE "Device Utilization Summary" -A 14 y1/pds/devmap_dma_p1.log
# 判据：report_timing 的 "All Constraints Met" + 结束标记 YESHENMINI_PNR_C4A_DONE
#      + Device Utilization 的 CLMA/CLMS/LUT/FF/APM/DRM 与 C4b 基线（LUT 61 530.5 / FF 113 382 /
#        APM 273 / DRAM 1 767 / DRM 32.5 / CLMA ~90%）逐项 Δ —— 本相预期 Δ 极小（+23 FF 级）
```

---

## 7) Phase-2 必须接的线（本节是给下一相的**接口单**）

1. **仲裁器侧（`src/YeshenSocGlue.scala` §3.5）——加第 6 个主人只需三处**：
   ```scala
   private val dmaPend = false.B          // ← 改成：DMA 引擎的 (awvalid || arvalid)
   ...
   is(2.U) {                              // ← 现在留空的 DMA 分支：写优先
     when(dmaAwValid) { owner := OWN_DMA_WR }.otherwise { owner := OWN_DMA_RD }
   }
   ```
   `OWN_DMA_RD/WR`（6/7）**已在本相预留**，`owner` 已是 **4 位**；`MemArbiter` **一字不改**
   （`N=3`、`WEIGHTS=(2,1,1)` 已把 DMA 的配额位留好）。
   DMA 的 AXI 口形状建议直接复用 `DdrMaster`（`ADDR_W=28/DATA_W=64/ID_W=4`，与 `npuMem` 同款 ⇒ 本子句的
   `Mux` 分支照抄 NPU 即可，含 **28→32 位零扩展**与 **id 丢弃**）。
2. **§4 的 `memSel` 一热 mux（`:1040-1078`）**：DMA 引擎若接在**最终主口**（而不是 §3.5），
   这里就是下一个改造点 —— 用**同一个 `MemArbiter`**（类 = {CPU 组, 装载器, DMA}）替换
   `Mux(memSel, …)`，并把**装载器的直连 ready/bvalid**（`:1033-1038`）按 ownership 加门。
   ⚠️ 本相**没动这一处**（见 §5.4）——它现在靠"装载期 CPU 被扣复位"维持正确性。
3. **判据（Phase-2 必做）**：① 真三客户端并存下**在胶合层**重证公平性（补 §5.2）；
   ② `D1/D2/D5`（三向搬运逐字节 / `bytes_moved` 对账 / PLIC 源 4）；③ **D3**：SD 装载器改走引擎后
   同一镜像装载结果**逐字节相同**；④ 台账站点数 +1（IP 窗/IRQ 源 4）。
4. **本相留下的既有坑（非本相引入）**：CPU 组类内固定优先级 ⇒ Fetch 在 LSU 背靠背时让位（§5.3）；
   若 Phase-2/3 要改，是在**类内**加轮转，属于**另一次**改动。

---

## 8) 改动面 + 指纹（`md5sum`）

| 文件 | md5 | 说明 |
|---|---|---|
| `src/soc/MemArbiter.scala` | `6e9e97160facb7d07505b8096f47ee07` | **新增**：真仲裁器（WRR + 老化）；`object MemArbiter` 里带单元网表生成入口 |
| `src/YeshenSocGlue.scala` | `b3cc9827fa522f4afb8865c392371449` | §3.5 改造（`npuTurn` → `MemArbiter`；`owner` 3→4 位） |
| `rtl/YeshenSocGlue.v` | `93af17cd003a7573415b6fa39f562941` | 由新源码重生成；负对照跑完**逐字节恢复**到本 md5 |
| `sim/memarb/tb_memarb.cpp` | `b71576dd9f92d4d428a672a316fda1eb` | **新增**：单元闸门装置（J1–J6） |
| `sim/memarb/run_unit.sh` | `822c5954c9a20d13262c158556b9684d` | **新增**；仓库根自推 |
| `sim/memarb/gen_memarb.sh` | `7ce8db3d8b4282f6f666abd183b8940d` | **新增**；仓库根自推 |
| `sim/memarb/negctl_memarb.sh` | `3b10ff0de2eb7323e640a1272243a83e` | **新增**：NC_A..NC_D |
| `sim/memarb/patch_exact.py` | `71405ec28a7ed98643bb8397bebbcc0e` | 复制自 `sim/ddr3bridge/`（未改） |
| `sim/glue_pbus/tb_memmerge.cpp` | `ff27c3b922541712142bda55b7c9fdff` | **新增**：胶合层内存合并点装置（J_MM1–J_MM4） |
| `sim/glue_pbus/run_memmerge_unit.sh` | `35be0a71f8220a7b27c56109a2d8d0c6` | **新增**；仓库根自推 |
| `sim/glue_pbus/gen_glue.sh` | `ead42290a7fb10ac7a157d28da38abcb` | **新增**：胶合网表重生成（与 `build_all.sh` glue 阶段同条命令） |
| `sim/glue_pbus/negctl_memmerge.sh` | `3a03719a68dde18d871fa0c5b9a33ec3` | **新增**：NC_MM1 / NC_MM2 |
| `sim/glue_pbus/memmerge_golden.txt` | `67357c8814b5388a51a0ace8f982285a` | **新增**：改动前网表的单主人 golden transcript（72 行） |

- **只读纪律**：`third_party/**`（含 PDS 的 DDR3 IP）与冻结 Python 工具
  （`ddr_traffic.py`/`fusion_buffer.py`/`bypass_traffic.py`/`mac_ref.py`/`bypass_ref.py`/`conv_unit_ref.py`/`desc_table.py`）
  **一字未动**。
- 板级 `board/yeshen_mini_board_top.v`、`board/yeshen_mini_soc.v`、`constraints/**`、
  `scripts/check_addr_map.py`、`y1/rtl/**`、`y1/gen/**` **一字未动**（台账站点数仍 16）。
- `rtl/YeshenSocGlue.v` 的**端口表一字未增**（本相没有加观察口：授权延迟在装置的 top 端口上量，
  不需要穿透网表内部信号）⇒ 板级例化不需要任何改动。
