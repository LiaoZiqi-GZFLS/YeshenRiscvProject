# Y1-C3.7 报告 —— 旁路算子 Add(饱和) + Sigmoid(Q3.4→Q0.7 查表)：冻结口径、LUT 指纹与旁路闸门证据

**Status: DONE**

**一句话**：C3.7 把 YuNet 的 `Add`（残差加）与 `Sigmoid` 做成两个**纯组合、零寄存器**的旁路算子，
各自的**唯一算术自由度**被冻结成一句可复核的话（`Add` = **饱和** `clamp8(a+b)`、不回绕；
`Sigmoid` = **256 项查表** `floor(127*sigmoid(x/16)+0.5)`、地址 `x ^ 0x80`），
并由 `y1/tools/run_bypass_ab.sh` 的**负对照**（`addwrap` 把饱和改回绕、`siginv` 把查表地址取反）
**逐字节钉住**；`gen/sigmoid_lut.hex` 的指纹 **`1b5866866686a1d2c81c98ac1ded4d4a`** 两次重生成一致
且与 RTL 运行期真正读的那份 `.bin` 逐字节相同。本报告**只做文档/报告收口**，**不改 RTL 行为**。

> 本报告是 C3.7 的**报告侧**收口（Plan Step 3.3 要求"`gen/sigmoid_lut.hex` 的 md5 记进报告"），
> 同时把"五单元速率/端口表"的**唯一契约**（C3.8/C3.10 要读的那一份）钉在 RTL 文件头里
> （见 §1 与 `rtl/{Conv3x3Slice,MaxPoolUnit,ResizeUnit,AddUnit,SigmoidUnit}.scala`）。

---

## 1) 旁路单元与各自冻结的"口径"（硬件怎么算的唯一真源）

C3.1（`reports/c3_traffic_full.md` §3.3）计进每帧流量的**四类旁路算子**是 `MaxPool / Resize / Add /
Sigmoid`（共 14 个算子、`BYPASS_BYTES=6,945,600` 的读+写）。它们 + 卷积切片 `Conv3x3Slice`
一起构成**速率表里的五个单元**。每个单元的"算术自由度"与冻结取值：

| 单元 | 冻结口径（唯一真源在 RTL 文件头） | 量化 / 自由度 |
|:--|:--|:--|
| `MaxPoolUnit` | **2×2 / stride 2 取最大**，int8 | **无量化**：激活值原样透传（max 天然落在 int8 内，不做 scale/zero-point，也不 clamp） |
| `ResizeUnit`  | **×2 最近邻** `out[2y+dy][2x+dx]=in[y][x]` | **无量化、无插值**：输出 = 输入像素**逐位复制**（int8 原样透传） |
| `AddUnit`     | **`y = clamp8(x_a + x_b)`，夹到 `[-128,127]`（饱和、不回绕）** | **无量化**（无 scale/zero-point/移位）；中间和用 **9 位二补数**（`int8+int8∈[-256,254]`）；**唯一自由度 = 饱和 vs 回绕**（真实数据上 `127+127` 必然出现 ⇒ 专门有一条负对照） |
| `SigmoidUnit` | **`lut[k] = floor(127*sigmoid((k-128)/16) + 0.5)`，`k=0..255`；`out = lut[x ^ 0x80]`** | 输入 **Q3.4**（步长 1/16）⇒ 输出 **Q0.7**（步长 1/128，值域 `[0,1)`）；取整 = **四舍五入、`.5` 向上**（**非** Python `round()` 的银行家舍入）；`127*sigmoid(·)∈[0,127]` ⇒ **永不越界**（无饱和逻辑）；**唯一自由度 = 查表地址/表本身** |

**速率/端口表（五单元，唯一契约）**：C3.8/C3.10 **不得假定单一速率模型**，五个单元各不同，
且**目前没有任何闸门钉住时延/x_ready 占空**。这份表已**逐字统一**在五个 RTL 文件头：

| 单元 | 进料占空 | 出料占空 | 时延 |
|:--|:--|:--|:--|
| `Conv3x3Slice` | `x_ready` 占空 **1/11**（1 拍收列 + 10 拍阵列，~9%） | ~9%（1 列 / 11 拍） | 阵列流水 |
| `MaxPoolUnit`  | `x_ready ≡ 1`（**100% 吃**） | 1 像素 / 4 拍输入（**25%**） | **同拍**（凑齐窗口那一拍，组合输出、无输出寄存器） |
| `ResizeUnit`   | **20%**（2W 收 / 10W 一拍周期） | **80%** | **落后 ≈ 一个输入行对**（≈2W 拍） |
| `AddUnit`      | `x_ready ≡ 1`（100% 吃） | 1 列 / 1 拍（100%） | **0 拍（组合）**；**要求两路 operand valid 同拍** |
| `SigmoidUnit`  | `x_ready ≡ 1`（100% 吃） | 1 列 / 1 拍（100%） | **0 拍（组合查表）** |

⇒ **`Add` 与 `Sigmoid` 都是 1:1（进出同拍、`x_ready ≡ 1`）；差别只在 `Add` 额外要求两路 operand
`valid` 同拍**（本单元不做速率匹配 —— 若两路速率不等，对齐/缓冲由 C3.8 的 `UnitExec` 负责）。
> ⚠ 订正记录：旧文件头曾写"Add 是四者里唯一 1:1"，**错**（`SigmoidUnit` 同样 `x_ready≡1`、1 列/拍、
> 同拍出）。本次把 `AddUnit` / `MaxPoolUnit` / `ResizeUnit` / `SigmoidUnit` 四个文件头的速率表
> **统一成上面这一份五单元表**（旧文件头或写"四个单元"、或写"三个单元"、或漏掉 `Sigmoid`）。

---

## 2) LUT 指纹与三向钉死（Plan Step 3.3）

**`gen/sigmoid_lut.hex` md5 = `1b5866866686a1d2c81c98ac1ded4d4a`**（384 B / 256 项，十六进制文本）。

**确定性证据**（闸门 `0c)` 步，逐字）：
```text
SIG_LUT_MD5=1b5866866686a1d2c81c98ac1ded4d4a  （重生成 #1=1b5866866686a1d2c81c98ac1ded4d4a / #2=1b5866866686a1d2c81c98ac1ded4d4a；gen/ 里那份必须与两次都一致）
```
即：`bypass_ref.py --genlut=` **重生成两次** ⇒ 两次 md5 一致（**确定性**），且与 `gen/` 里那份
**逐字节相同**（`cmp -s`）；`--lutfile` 再断言"导出文件 == 冻结公式"（256 项逐项比）。

**三向钉死**（三份拷贝互相约束，任一侧改坏都发火）：

| # | 副本 | 生成者 | 闸门判据 |
|:--|:--|:--|:--|
| ① | `gen/<网表>.v_toplevel_lut.bin`（RTL **运行期真的在读**的表；256 行、每行 8 个二进制字符） | SpinalHDL 对 `Mem.init` 的产物 | `--lutbin=①` 断言 **RTL 的 Mem 初值 == 冻结公式**（`SigmoidUnit` 与 `SigmoidUnit_w6` 两份都比） |
| ② | `gen/sigmoid_lut.hex`（**Python 侧导出**） | `bypass_ref.py --genlut=`（同一条 `floor(v+0.5)` 公式） | `--lutfile=②` 断言"② == 冻结公式"；两次重生成 == ② |
| ③ | 装置**自算**（`rtl_test/BypassTb.v`） | 装置用 `+LUTFILE=` **`$readmemh` 载入 ②** 后**自己**查表算期望 | 装置打印 `LUT-XCHK=0`（逐字节对账）且 `LUT-CODES=256`（跑满 256 个码点） |

对账关系：①② 与**外部冻结公式**比（不是恒等式），③（装置）与 ② 比，再看 DUT 输出与 ③ 比。
⚠ 任一侧改坏都会发火 —— 负对照 `siginv`（把地址取反）即"装置侧 `LUT-XCHK` 变值 + 闸门侧 `MISMATCH`
变值"。

---

## 3) 网表 md5（**as observed**；RTL 注释改动不影响生成物，但**要让闸门重跑一遍刷新**）

以下为本次收口时**实测**的网表指纹（`md5sum gen/<file>`）。**标注：re-run the gate to refresh**
（若日后再改 RTL 代码——非注释——这些值会变，重跑 `run_bypass_ab.sh` 后按实测更新本表）：

| 网表 | md5（full） |
|:--|:--|
| `gen/AddUnit.v`       | `82dfdfe250dd0c16caab2a4295fa557d` |
| `gen/AddUnit_w5.v`    | `1f8bc13e994ef743ac1ffa4b49e88b5e` |
| `gen/SigmoidUnit.v`   | `52d4a4d45961d004bb5206cb1a5a0ae2` |
| `gen/SigmoidUnit_w6.v`| `6d4a8c3b0e699a9d151362a54903f691` |

> 本步**只改 RTL 注释**（文件头文档块），**数据通路零改动** ⇒ 上述 `.v` 与 `gen/sigmoid_lut.hex`
> 均**未变**（§2 的指纹即可佐证）。`gen/` 不入库（`y1/.gitignore` 的 `gen/`）。

---

## 4) 逐算子闸门证据（`tools/run_bypass_ab.sh`，8 用例全 PASS，exit 0）

覆盖 **4 算子 × 2 形状**，每例 = 正对照 + 各自负对照 + 自检 + 自报 + 张冠李戴。
**正对照**全部 `MISMATCH=0`（装置输出逐字节 == 参考黄金）；`SigmoidUnit` 两例另有装置侧
`LUT-XCHK=0` 且 `LUT-CODES=256`（全码点穷举）。

**负对照**（网表突变，scratch 拷贝，**每一发都必须"精确命中突变预测 + != 黄金 + 装置自报 FAIL"**）：

| 负对照 | 算子 | 突变（唯一自由度） | 变值字节数（as observed） |
|:--|:--|:--|:--|
| A `topleft` | MaxPool | 窗口取最大 ⇒ **恒取左上角** | W=4: **6** / W=6: **13** |
| B `bank`   | Resize  | `dy` 行手取反（换行缓冲） | W=4: **128** / W=6: **288** |
| B `col`    | Resize  | `dx` 源列配对取反 | W=4: **128** / W=6: **288** |
| **C `addwrap`** | **Add** | **把饱和关掉（`clampHi/clampLo` 恒 0）⇒ 饱和变回绕** | W=4,H=4: **8**（`SAT_EVENTS=8`）；W=5,H=3: **7**（`SAT_EVENTS=7`） |
| **D `siginv`**  | **Sigmoid** | **查表地址取反（`lutIdx := 0 - lutIdx`）⇒ `x→-x`** | W=4: **254** / W=6: **381** 字节（**码点数恒 254/256**，与"表在 `x→-x` 下不对称、不动点 = `{x=0, x=-128}`"一致） |

**Add 特有的两条**（见 `rtl/AddUnit.scala` 文件头）：
- **非退化/可饱和前提**：向量里显式断言"**两路不相等**"（否则加法退化成 ×2）+ **`SAT_EVENTS > 0`**
  （否则"饱和 vs 回绕"输出完全相同 ⇒ 判据是橡皮章）；
- **单边停住 `+STALLB=1`**（`x_b_valid` 恒 0）⇒ DUT **一列不吃、一颗不出** —— 这是
  "消费/`y_valid` 同时看**两路** valid"的**唯一**判据（正常跑两路总是同拍齐，错误行为在其它作业里**永不可观测**），实测 `喂入=0 / 采集=0`。

**负对照 "只动读/选侧"的边界**（诚实记录）：A 只改选角、B 只改选源行/列、C 只改 clamp 选择、
D 只改查表地址；各自的**输入侧计数器/自报端口**只由正对照覆盖 ⇒ "负对照全绿"**不等于**"状态机被证明"。

**复现**（exit 码见 §8）：`cd y1 && bash tools/run_bypass_ab.sh` ⇒ `RESULT: PASS`、exit **0**、8 个 `CASE = OK`。

---

## 5) O1 开口项（`Add` 双输入 vs 描述符单 `SRC_ADDR`）—— 交 C4/M2

**缺口**：`AddUnit` 是**双输入**单元（`x_a` + `x_b` 各一路 valid，`x_ready` 共享），
而 C3.2 冻结的描述符格式**只有一个 `SRC_ADDR`**，**表达不了第二路源**。本网的两个 `Add`
（`Add_44`/`Add_50`）**两路都来自 DDR**（`MaxPool` 的输出 + `Resize` 的输出，是两个独立单元）。

**交叉引用**：`reports/c3_descriptor_format.md` **§7 开口项 O1**（该文件 §0 与 §8 也点名）。
处置建议（**不得各自就地发明字段**）：spec 修订补一个源地址字段/约定（如 `SRC_ADDR + IN_BYTES`
连续放），或由转换器设法让一路落在片上。**本任务不改描述符格式** —— 这是**C4/M2 的转换器**项（spec 修订候选），
也是 `c3_descriptor_format.md` 状态为 `DONE_WITH_CONCERNS` 的原因之一。

RTL 侧只把"第二路源是谁"**留作开口项**：C3.8 的 `UnitExec` 里"A 路 = `IN_FROM_PREV`/融合缓冲、
B 路 = `SRC_ADDR`"只是**候选接法**，从不落到格式字段。

---

## 6) `Q3.4 → Q0.7` 是**计划选择**，不是 YuNet 的真实刻度（C4/M2 项）

`SigmoidUnit` 的输入 Q3.4 / 输出 Q0.7 是**本计划的冻结选择**（plan 总约定第 4 条），
**不是 spec / 不是 YuNet 实测的 sigmoid scale/zero-point**。YuNet 实际刻度由 **C4/M2 的量化器**
决定 ⇒ **记为 C4 开口项**（与 `c3_descriptor_format.md` 的 §7 O4 `QUANT_SHIFT` 占位口径同档）。
**换刻度 = 换这张表**（一个生成期常量），**数据通路不变** —— 这正是"查表"选择的余量所在。

---

## 7) 前向要求（给 C3.12 / C3.13）—— RTL 的 ROM 初值是**运行期相对路径**

`SigmoidUnit` 的 ROM **不是硬编码常量**：SpinalHDL 1.15 对 `Mem(SInt(8),256).init(...)` 的产物是

```verilog
initial begin $readmemb("<Netlist>.v_toplevel_lut.bin", lut); end
```

即 RTL **运行期**从一个生成出来的初值文件载入（`gen/<网表名>.v_toplevel_lut.bin`）。
该路径是 **CWD 相对**（裸文件名）、且 `gen/` **不入库**（gitignored）。

⇒ **C3.12（并入 NpuTop）/ C3.13（面积闸门）要求**：
1. **PDS / 综合流程必须把 `<Netlist>.v_toplevel_lut.bin` 摆到源文件旁边**（综合工具的 CWD / 搜索路径里），
   否则 ROM 初始化读到**全 X**（`$readmemb` 缺文件只发 warning）⇒ 网表跑出来全错；
2. **面积闸门必须断言"ROM 能读回非 X"**（例如对地址 0 / 中点地址 128 / 末尾地址 255 各读一次，
   断言非 X 且等于冻结表值）—— 别只数面积、别让"全 X 的 ROM"混过闸门。

（仿真侧这条已由闸门兜住：`judge_sigmoid` 会把 `.bin` 拷进 vvp 工作目录、缺失时**当场报红**。）

---

## 8) 复现命令与退出码

```bash
cd /d/code/PDS/VexiiYeshenLinux/y1            # 从 y1 跑
bash tools/run_bypass_ab.sh ; echo "bypass=$?"        # ⇒ RESULT: PASS ; bypass=0（8 个 CASE = OK）
cd /d/code/PDS/VexiiYeshenLinux               # 从 repo 根跑（脚本自带 CWD 无关化）
bash y1/tools/run_bypass_ab.sh ; echo "from_root=$?"  # ⇒ RESULT: PASS ; from_root=0
```

退出码（与 Y1 既有闸门一致）：`0` = 全过（4 算子 × 2 形状：正对照 + 全部负对照发火 + 自检 + 结构
+ LUT 指纹）；`1` = 对账不符/编译或仿真失败/装置未 PASS/网表不存在/LUT 副本对不上；
`2` = 负对照没发火/比较器自检不过/装置自检没接在回路上 ⇒ **闸门自身不可信**；
`3` = 向量/维度自检失败（用例写错，或参考自身自检没过）。

**本次实测**：`y1/` 下 `bypass=0`；repo 根下 `from_root=0`（两次均 `RESULT: PASS`）。
