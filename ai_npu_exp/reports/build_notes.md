# M0-B3 构建笔记：`sbt compile` 首次打通过程

**结论：** `ai_npu_exp/rtl_src/` 的 53 个 Scala 源（含 `config/Config.scala` 的 `useUram = false` 覆盖）
在 SpinalHDL 1.15.0 下**零改动**编译通过，`[success]`。

- **状态**：DONE
- **命令**：`cd ai_npu_exp/port && bash sbt.sh compile`
- **改动**：`build.sbt` **未增删任何依赖**；`override/` **未新增任何 API 适配**（即本文档除记录之外不含代码改动）

---

## 1. 实际执行

```bash
cd /d/code/PDS/VexiiYeshenLinux/ai_npu_exp/port
bash sbt.sh compile 2>&1 | tee /tmp/b3_compile.log | tail -60
```

**首次运行完整输出（13 行，未截断）：**

```
[info] welcome to sbt 1.10.0 (Eclipse Adoptium Java 17.0.20)
[info] loading project definition from D:\code\PDS\VexiiYeshenLinux\ai_npu_exp\port\project
[info] loading settings for project port from build.sbt ...
[info] set current project to ai_npu_exp_m0 (in build file:/D:/code/PDS/VexiiYeshenLinux/ai_npu_exp/port/)
[info] Executing in batch mode. For better performance use sbt's shell
[info] compiling 53 Scala sources to D:\code\PDS\VexiiYeshenLinux\ai_npu_exp\port\target\scala-2.12\classes ...
[warn] 7 deprecations (since 2022-12-31)
[warn] one deprecation (since 2024.12.31)
[warn] 8 deprecations in total; re-run with -deprecation for details
[warn] 51 feature warnings; re-run with -feature for details
[warn] four warnings found
[info] done compiling
[success] Total time: 25 s, completed 2026年10月8日 上午11:08:45
```

**收尾复跑（确认磁盘现状即该命令所报状态）：**

```
[info] loading settings for project port from build.sbt ...
[info] set current project to ai_npu_exp_m0 (in build file:/D:/code/PDS/VexiiYeshenLinux/ai_npu_exp/port/)
[info] compiling 53 Scala sources to D:\code\PDS\VexiiYeshenLinux\ai_npu_exp\port\target\scala-2.12\classes ...
[info] done compiling
[success] Total time: 16 s, completed 2026年10月8日 上午11:19:56
```

产物：`ai_npu_exp/port/target/scala-2.12/classes/` 下 **308 个 `.class`**（53 源），含 `Npu.class`、`config/`、`conv/`、`instruction/` 等包目录。

---

## 2. 依赖：**没有新增任何依赖**——但要记下 `commons-io` 的来路

按 B3 决策规则 (a) 先做了诊断：

```bash
grep -rn "org.apache.commons" ai_npu_exp/rtl_src | head
```

```
../rtl_src/wa/xip/axi/StreamDataWidthConvert.scala:4:import org.apache.commons.io.FileUtils
../rtl_src/wa/xip/debug/Ila.scala:4:import org.apache.commons.io.FileUtils
../rtl_src/wa/xip/math/AddSub.scala:4:import org.apache.commons.io.FileUtils
../rtl_src/wa/xip/math/DSP.scala:4:import org.apache.commons.io.FileUtils
../rtl_src/wa/xip/math/Mul.scala:5:import org.apache.commons.io.FileUtils
../rtl_src/wa/xip/memory/ip/BlockRam/TDRam.scala:4:import org.apache.commons.io.FileUtils
```

`commons-io` 确实**未被 `build.sbt` 声明**，所以规则 (a) 看起来会被触发。**但是编译直接通过了**——
即规则 (a) 的前提（`object FileUtils is not a member of package org.apache.commons.io`）**没有出现**。
因此**没有加那一行**，而是先查清它为什么不需要：

`spinalhdl-lib_2.12:1.15.0` 的 POM 自带 `commons-io:2.11.0`：

```xml
<!-- coursier cache: .../com/github/spinalhdl/spinalhdl-lib_2.12/1.15.0/spinalhdl-lib_2.12-1.15.0.pom -->
<dependency>
    <groupId>commons-io</groupId>
    <artifactId>commons-io</artifactId>
    <version>2.11.0</version>
</dependency>
```

而 `spinalhdl-core_2.12:1.15.0` 的 POM **不含** `commons-io`。也就是说：

- 编译期：`FileUtils` 由 `spinalhdl-lib` **传递依赖**提供（版本恰好就是规则 (a) 想加的那一行所写的 `2.11.0`）；
- 运行期（B4 生成 Verilog 要用到 `FileUtils`）：已实测在 classpath 上，
  `show Runtime / fullClasspath` 中含 `commons-io\commons-io\2.11.0\commons-io-2.11.0.jar`。

**给后续任务的提醒：** 这是**隐式传递**，不是显式声明。若哪天升级 SpinalHDL、或改用更严格的解析器
（例如排除传递依赖 / `provided`）导致 `commons-io` 掉出 classpath，规则 (a) 的那一行就是正确修法；
在 1.15.0 下当前不必加，加了也只是把传递依赖转成显式（无功能差异）。**本次遵循"不猜、不多改"，未加。**

## 3. API 适配：**零**

规则 (b) 未触发：克隆源码与 SpinalHDL 1.15.0 **无 API 不兼容**，`override/` 目录仍只有原来那一个文件：

```
ai_npu_exp/port/override/config/Config.scala   # B1 的 useUram = false
```

已核对该覆盖确实生效于生成副本：

```
ai_npu_exp/rtl_src/config/Config.scala:25:    val useUram = false // Pango 无 UltraRAM ...
ai_npu_exp/port/override/config/Config.scala:25:    val useUram = false // ...
```

因此**未新增任何 override 文件**，也**未改 RTL 语义**。

---

## 4. 首次依赖解析耗时

**几乎为零——依赖早已在本地 coursier 缓存里。** 首次运行全程 **35 s**（含 sbt 启动），
其中 sbt 报的编译任务 `Total time: 25 s`；日志里**没有任何 `[info] downloading` 行**。

缓存证据（`C:\Users\Ziqi\AppData\Local\Coursier\cache\v1\https\repo1.maven.org\maven2\...`）：

| 构件 | 缓存落地时间 |
|---|---|
| `spinalhdl-core_2.12-1.15.0.jar` | 2026-09-02 14:27:58 |
| `spinalhdl-lib_2.12-1.15.0.jar` | 2026-09-02 14:27:58 |
| `spinalhdl-idsl-plugin_2.12-1.15.0.jar` | 2026-09-02 14:27:58 |
| `commons-io-2.11.0.jar` | 2026-07-... （更早，非本次引入） |

即 1.15.0 全套 jar 在本任务之前（2026-09-02）就已入缓存，**本次未触发任何网络下载**；
`build.sbt` 里烘焙的 `127.0.0.1:7897` 代理这次没有实际流量可证。契约上的"首次解析可能要几分钟"
在本机**没有发生**，不要把它当作已完成解析的证据——真正的解析成本被前置了。

复跑耗时：25 s（首次，冷编译 53 源）→ 16 s（第二次，仍全量重编，因 scalacOptions 变了）→ 16 s（收尾复跑）。

---

## 5. 编译告警清单（后续任务需要知道）

`build.sbt` 未开 `-deprecation` / `-feature`，默认只报计数。为记录细节，用
`set Compile / scalacOptions ++= Seq("-deprecation","-feature")` 单独跑过一次（**只影响该次进程，未落盘到 `build.sbt`**），
得 **59 条告警**，可归为三类，**全部只涉及告警、不阻塞**，且**全部位于克隆源码内**（按硬规则不改）：

**(1) SpinalHDL 1.15.0 弃用 API —— 8 条，全部在 `instruction/Instruction.scala`：**

| 位置 | 弃用信息 |
|---|---|
| `Instruction.scala:98,100,104,106,111,113,127` | `method field in class RegInst is deprecated (since 2022-12-31): field(Bits/UInt/SInt(n bit)/Bool, acc) recommend` |
| `Instruction.scala:128:16` | `method apply in object HtmlGenerator is deprecated (since 2024.12.31): Use DocHtml instead of HtmlGenerator` |

即 7 条 `RegInst.field`（建议改用带类型的 `field(...)` 重载）+ 1 条 `HtmlGenerator`（建议改 `DocHtml`）。
**当前仍可用**，与编译成功不冲突；1.15.0 是最后一个保留它们的版本之一，**若未来升级 SpinalHDL，这里是最先爆的地方**。
B4 之后若要复现告警详情，用上面那条 `set` 命令（注意 Windows 下 `sbt.sh` 传参的坑，见第 6 节）。

**(2) `reflectiveCalls` 特性告警 —— 41 条**，均在 `conv/dataGenerate/FeatureGenerate.scala`
（`channelIn` / `colNumIn` / `start` 等 structural type 成员访问）。属 Scala 语言特性"未显式开启"提示，
非错误；消除方式是加 `import scala.language.reflectiveCalls` 或编译选项 `-language:reflectiveCalls`。

**(3) `postfixOps` 特性告警 —— 10 条**，例如 `wa/WaCounter.scala:10:32: postfix operator bits should be enabled`
（`.bits` 后缀写法）。同上，属语言特性提示。

> 注：`[warn] four warnings found` 这一行是 sbt 把上面几类聚合成 "deprecations/feature" 四组的汇总，
> 与实际 59 条明细不矛盾。

---

## 6. 操作坑（本任务踩到的，后续任务直接用）

1. **不要用 `bash sbt.sh 'set ... "..."'` 传带引号的 sbt 命令。**
   `sbt.sh` 最终 `exec sbt.bat "$@"`，Windows 批处理会把内层引号搅乱，结果是 cmd 报
   `此时不应有 compile。`（"compile was unexpected at this time"）——**命令根本没跑到 sbt**。
2. **改用 stdin 喂命令，且必须显式 `exit`：**
   ```bash
   printf 'set Compile / scalacOptions ++= Seq("-deprecation","-feature")\ncompile\nexit\n' | bash sbt.sh
   ```
   不加 `exit` 会进 sbt shell 模式，在 stdin EOF 后**空转刷 `>....`**，进程不退出（本次因此被挂死一次、需手动 kill）。
3. `set every scalacOptions ...` 会失败：`Reference to undefined setting: scalacOptions from Global / scalacOptions`。
   要用 **`set Compile / scalacOptions ...`**（sbt 1.x slash 语法，报错信息里也给了这个建议）。
4. 杀掉挂死的 sbt 后再启动，日志尾部可能出现
   `[error] server failed to start on local:sbt-server-...: Could not create lock for \\.\pipe\sbt-server-..._lock, error 5`。
   **无害**——本次该行出现时进程 `exit=0` 且编译已 `[success]`；是残留 sbt server 管道的锁竞争，不影响构建。

---

## 7. 现状自证（本任务结束时）

- `third_party/SpinalHDL_CNN_Accelerator`：**零改动**（本任务全程未写入该目录）。
- `ai_npu_exp/rtl_src/`：**生成副本**，被 `ai_npu_exp/.gitignore:1:rtl_src/` 忽略，**不入库**
  （`git check-ignore ai_npu_exp/rtl_src/config/Config.scala` 命中）。
- `ai_npu_exp/port/target/`：被根 `.gitignore:44:target/` 忽略，**不入库**。
- 所以 B3 的**唯一入库物 = 本文件**（`build.sbt` / `project/build.properties` / `sbt.sh` / `override/` 均无改动）。

---

## 8. 本任务对后续任务的净交付

- **M0 基线成立**：克隆源码（仅 `useUram = false` 一处覆盖）在 SpinalHDL 1.15.0 + JDK 17 + sbt 1.10.0 下可编译，
  53 源 → 308 class。**B4 可以直接在这个 classpath 上跑 `Npu` 生成 Verilog。**
- **无依赖缺口、无 API 适配缺口**——所以后续 Pango 化（B5–B9）需要处理的是 **Xilinx IP 原语**（`wa/xip/` 下的
  `sdpram` / sync FIFO / DSP / 乘法器 / XPM + 那些会写 tcl 的 `TotalTcl.scala`），
  **不是** 构建脚或 SpinalHDL 版本兼容问题。
- **`commons-io` 与 Xilinx IP 的耦合面已被查清，B9 会顺手把它清干净。**
  `org.apache.commons.io.FileUtils` 只在 **6 个文件**（`wa/xip/` 下的 `axi/StreamDataWidthConvert.scala`、
  `debug/Ila.scala`、`math/AddSub.scala`、`math/DSP.scala`、`math/Mul.scala`、`memory/ip/BlockRam/TDRam.scala`）
  出现，且**全部 7 处调用都是同一句**：

  ```scala
  FileUtils.forceMkdir(new File(filePath + File.separator + "tcl"))   // Mul.scala 里出现 2 次，其余各 1 次
  ```

  即 `commons-io` 仅被用来**建一个 `tcl` 输出目录**，无任何其它用途。所以：
  (i) B9 停用 Xilinx IP tcl 后，这 7 处调用点会一起消失，`commons-io` 变为无用传递依赖（不影响编译）；
  (ii) 若要提前去掉这个依赖，等价替换就是 `new java.io.File(...).mkdirs()`——语义一致、零风险。

  > 与任务描述的偏差：描述里点名的 `misc/TotalTcl.scala` **实际不含** `org.apache.commons.io` 的 import
  > （该文件只用 `java.io._` + `scala.io.Source`，`grep -rn "FileUtils\|commons" misc/` 为空）。
  > 真正的 6 个文件如上。**本文以实测为准。**

## 2026-10-08 追加：生成指纹必须关掉 `headerWithRepoHash`（B4 复核发现）

**症状**：B4 首次记录的两份指纹（`ed6d6ec` 下 `e06ceff8…`、`fd530aa` 下 `e9692223…`）在**跨 commit 时不一致**。逐字节定位：差异**只在 `Npu.v` 第 3 行** `// Git hash : <HEAD>`。

**为什么是硬伤**：B5–B8 每个 Pango 化改动都要靠"改动前后 md5 变了没有"来判断生效，并用"不改 RTL ⇒ md5 应完全相同"做负对照。头里带 HEAD 会让**每次 commit 后 md5 必然变化** ⇒ 判据退化成永真、负对照做不出来。

**修法**：`SpinalConfig(headerWithDate = false, headerWithRepoHash = false, ...)`（SpinalHDL 1.15.0 确有该参数，已用 `javap` 在 `spinalhdl-core_2.12-1.15.0.jar` 上核实字段 `headerWithRepoHash`）。

**验收**：改后必须满足"**跨 commit 稳定**"——同一次生成在 commit 前后 md5 相同。
<!-- probe: 无关提交，用于复核指纹跨 commit 稳定 -->
## 2026-10-08 复核结果：指纹跨 commit 已稳定（PASS）

`Npu.v` 的 md5 在三个 checkpoint 上完全相同：

| checkpoint | md5 |
|---|---|
| 修复后、提交前（HEAD=`ed6d6ec`） | `5a42c06e3dc959ae2169197211280974` |
| 提交 `580a575` 之后重生成 | `5a42c06e3dc959ae2169197211280974` |
| 再叠一次无关提交后重生成 | `5a42c06e3dc959ae2169197211280974` |

⇒ **B5–B8 的"改动是否生效 / 负对照应完全相同"判据从此刻起是有效的**，不再是同义反复。
基线指纹：`gen/Npu.v` = **`5a42c06e3dc959ae2169197211280974`**（2,037,104 B，55,287 行，51 个 `module`）。

## 2026-10-08 B5：sdpram Pango 化（保 READ_LATENCY 契约 + 正负对照）

**结论：DONE。** `wa/xip/memory/xpm/sdpram` 不再实例化 Xilinx `xpm_memory_sdpram`，改为可综合的
SpinalHDL `Mem` + 显式流水；`Npu.v` 里 `xpm_memory_sdpram` **0 次**，指纹从 `5a42c06e…` 变为
`e2ad46ed…`（改动确实进了真网表）。读延迟契约 `doutb(t) = mem[addrb(t-READ_LATENCY)]` 由**从 Verilog 数出来**的
判据正负对照证明（4 条输出见下）。

**入库物：**
- `ai_npu_exp/port/override/wa/xip/memory/xpm/XPM_MEMORY_SDPRAM.scala`（新增覆盖，只改 `class sdpram` 体，XPM BlackBox 及其 `object` 原样保留且不再被实例化）
- `ai_npu_exp/rtl_test/SdpramTop.scala`（Test 源根下的最小装置 + 生成入口 `SdpramGen <outdir> <latency>`）
- `ai_npu_exp/tools/check_sdpram_latency.py`（判据：从 `SdpramTop.v` 的 `sdpram` 模块体里数 `doutPipe_<n>` 索引）
- 本文件

### 1. 契约怎么被证明（Step 4 四条输出，exit code 原文照抄）

装置：`SdpramTop(readLatency)` = 64bit/512 深写、64bit/512 深读，`readLatency` 由命令行给。

```
# 生成 lat=2：Test/runMain SdpramGen .../gen 2
$ python tools/check_sdpram_latency.py gen/SdpramTop.v 2
expected=2 detected=2 indices=[0, 1]
RESULT: PASS
pos_exit=0
```

```
# 生成 lat=3：Test/runMain SdpramGen .../gen 3
$ python tools/check_sdpram_latency.py gen/SdpramTop.v 3
expected=3 detected=3 indices=[0, 1, 2]
RESULT: PASS
neg_exit_A=0

$ python tools/check_sdpram_latency.py gen/SdpramTop.v 2
expected=2 detected=3 indices=[0, 1, 2]
RESULT: FAIL
neg_exit_B=1
```

- **正对照** `pos_exit=0`（detected=2）；**负对照** `neg_exit_A=0` / `neg_exit_B=1`（detected=3 ≠ 2）。
- ⇒ 判据**真的在读 Verilog**：同一个文件对 2 与 3 给出不同答案，且索引集合恰好是 `0..lat-1`；
  它不是常量、也不是对参数的回声。（若判据只是读常数，`neg_exit_B` 不会是 1。）
- 判据数的是**真寄存器**：`gen/SdpramTop.v` 里 `doutPipe_0 <= (enb ? rdBits : doutPipe_0)`、
  `doutPipe_1 <= (enPipe_0 ? doutPipe_0 : doutPipe_1)`、`assign doutb = doutPipe_1`；
  lat=3 时多一级 `doutPipe_2`。等 `enb ≡ 1` 时 `doutb(t) = mem[addrb(t-2)]`，与契约一致。
- 收尾把装置重新生成为 lat=2（`pos_exit=0`），树留在正对照状态。

> 与任务书给的命令形式的偏差：`bash sbt.sh "Test/runMain …"` 在本机**跑不起来**——
> `sbt.bat` 会把内层引号搅乱，sbt 报 `Not a valid command: Test`（与本文档 §6 记的坑同源）。
> 因此 test 入口用 stdin 喂命令 + 显式 `exit`，语义等价。

### 2. 与任务书给的代码的三处实测偏差（都必须知道）

**(1) `readSync(..., outputStage = false)` 在 SpinalHDL 1.15.0 里不存在。**
`Mem.scala`（v1.15.0）里根本没有 `outputStage` 这个名字，`readSync` 的第 4 个形参是
`clockCrossing: Boolean`；`javap` 也确认过签名是 `readSync(UInt, Bool, ReadUnderWritePolicy, boolean)`。
于是按任务书的决策规则取"组合读出"语义，落到 **`mem.readAsync(addrb)`**——这正是任务书注释
"outputStage=false ⇒ 读出是组合的"所描述的东西。**注意我并没有采用决策规则里"`outputStage=true` + 流水减一级"
那一支**，因为那会让判据的 `detected` 恒为 `READ_LATENCY-1`，与任务书自己的 Step 4 期望
（detected=2 / 3）自相矛盾；实测也证明那一支是错的（下条）。

**(2) 先试过 `readSyncMixedWidth(addr, doutPipe(0), enb)`，实测多一拍，契约会破。**
它看着最像"同步读 + 直接驱动第 0 级"，生成出来却是**两个**寄存器：

```verilog
always @(posedge clk) if(enb) mem_spinal_port1 <= mem[_zz_doutPipe_0];  // SpinalHDL 自己的读寄存器
always @(posedge clk)         doutPipe_0 <= mem_spinal_port1;            // 我这一级
```

即同步读口会自带一级寄存器，`doutb(t)` 会变成 `mem[addrb(t-3)]`（lat=2 时），契约直接破。
**所以最终版必须用组合读出**，`sdpram` 内**没有**任何隐藏寄存器：
`assign mem_spinal_port1 = mem[addrb]; doutPipe_0 <= (enb ? mem_spinal_port1 : doutPipe_0);`
（`mem_spinal_port1` 是 wire，不是寄存器——这是"判据数到的级数 = 真实延迟"的关键。）

**(3) 任务书的 `new Mem(Bits(WRITE_WIDTH bits), wordCount = WRITE_DEPTH)` 对 quant RAM 不成立。**
两个调用点里 `Weight.scala:326`（weight，128bit×256，读写同宽）可以用，但 `Weight.scala:344`
（quant：**128bit 写 / 512bit 读**，`addra` 9bit、`addrb` 7bit、`QUAN_M_DEPTH` 128）不行：
读口位宽与地址都不匹配。实测两条 SpinalHDL 硬限制：

- 混合位宽**写**口 → Verilog backend 直接报错：
  `Verilog backend can't emit toplevel/…/copyBias_ram/mem : Mem[128*512 bits] because of its mixed width ports`
  （`ComponentEmitterVerilog`：`if(memWrite.aspectRatio != 1) SpinalError(...)`）；
- 读得比 Mem 字宽 → `normalizeInputs` 里 `aspectRatio = mem.width/readWidth` 会算成 0 而被拒。

因此实现改成：**Mem 字宽 = 写位宽**（保证写口 `aspectRatio == 1`），读比写宽时用
`ratio = READ_WIDTH/WRITE_WIDTH` 个**并行子字读**拼出宽字，第 k 个子字地址 = `addrb*ratio + k`
（写不出的那一位用 `{addrb, k}` 直接拼，低地址进低位）。这与 XPM 非对称口的物理实现一致
（XPM 也是拆成多个 bank 并行读同一字地址）。网表实测：

```verilog
module sdpram_144 ( output [511:0] doutb, input [8:0] addra, input [6:0] addrb, input [127:0] dina, … );
  assign mem_spinal_port1 = mem[_zz_rdBits];      // _zz_rdBits   = {addrb,2'b00}
  assign mem_spinal_port2 = mem[_zz_rdBits_1];    // _zz_rdBits_1 = {addrb,2'b01}
  assign mem_spinal_port3 = mem[_zz_rdBits_2];
  assign mem_spinal_port4 = mem[_zz_rdBits_3];
  assign rdBits = {{{mem_spinal_port4,mem_spinal_port3},mem_spinal_port2},mem_spinal_port1};
  (* ram_style = "distributed" *) reg [127:0] mem [0:511];
```

**另外补了 3 条"宁可响亮失败"的 assert**（不在任务书给的代码里，但少了它们就是静默降级）：
`CLOCK_MODE == "common_clock"`（XPM 的 `independent_clock` 需要 CDC，SpinalHDL Mem 不提供）、
`MEMORY_TYPE ∈ {auto, block, distributed}`（Pango 无 URAM；`ultra`+`READ_LATENCY=12` 那条分支
因 `useUram=false` 覆盖已是死代码，但被改回来时必须炸而不是静默当 BRAM 用）、
`READ_WIDTH >= WRITE_WIDTH` 且比值为 2 的幂。两个调用点都满足（weight 1:1、quant 1:4）。

### 3. Step 5：改动确实进了真网表

```bash
$ printf 'runMain GenNpu D:/code/PDS/VexiiYeshenLinux/ai_npu_exp/gen\nexit\n' | bash sbt.sh
[info] GENNPU_DONE -> D:/code/PDS/VexiiYeshenLinux/ai_npu_exp/gen
[success] Total time: 7 s
$ md5sum gen/Npu.v
e2ad46ed2d5a4afba90e6f37566a37d0   # 基线（改动前）= 5a42c06e3dc959ae2169197211280974
$ grep -c "xpm_memory_sdpram" gen/Npu.v
0                                  # grep exit=1（无匹配）
$ md5sum gen/Npu.v
e2ad46ed2d5a4afba90e6f37566a37d0   # 两次读一致
```

| 量 | 改动前 | 改动后 |
|---|---|---|
| `gen/Npu.v` md5 | `5a42c06e3dc959ae2169197211280974` | `e2ad46ed2d5a4afba90e6f37566a37d0` |
| `xpm_memory_sdpram` 出现次数 | 若干 | **0** |
| `module` 数 / 行数 | 51 / 55,287 | 51 / 55,542 |
| `sdpram` 实例数 | — | **147**（144 weight + 3 quant）落在 **2** 个模块定义上（`sdpram` 128bit、`sdpram_144` 512bit） |

⇒ 只剩 **B6 的 FIFO** 还带 XPM（`xpm_fifo_sync` 一族，53 行引用），B5 这层的 XPM 原语已清零。

### 4. 未验证项 / 疑虑（写下来，别当已解决）

1. **`ram_style = "distributed"` 是最大风险。** SpinalHDL 对"组合读出"的 Mem 一律打这个属性
   （同一份网表里同步读出的 Mem 打的是 `ram_style = "block"`）。weight RAM 合计约 144×32kbit ≈ **4.7Mbit**，
   若 Pango 合成认这个属性，LUTRAM 装不下、dev_map 必炸。**本任务的判据只覆盖功能延迟契约，
   覆盖不了资源映射**；该风险应由 B10（`dev_map`）来判。若确实被认成 distributed，出路是
   把地址寄存器化改用同步读（此时存储器自带/外挂那一级要计入总延迟，判据与流水需一起重推），
   或对属性做后处理——**不要**静默把契约从 READ_LATENCY 改成别的数。
2. **读同时写同址的行为变了。** 原 XPM 包装里 `WRITE_MODE_B = "read_first"`；新的组合读出被
   SpinalHDL 强制 emit 成 **write-first**（`[Warning] … readAsync can only be write first into Verilog`），
   且 `readFirst` 对异步读口被显式拒绝。两个调用点的读地址来自读计数器、写地址来自装载计数器，
   正常流程不该同址同时，但这是**未做功能仿真确认**的语义差异。
3. **宽读的位序（低地址→低位）是我的判断**（与 XPM 非对称口的拼接顺序一致），
   它决定 quant RAM 里 16 个 32bit 通道的对应关系。B5 的判据只证延迟，**不证位序**；
   值得后续用功能仿真（而非延迟判据）核一次。
4. **`ratio > 1` 那条读路径只被"整网表生成"覆盖**（elaborate + Verilog emit 都过），
   没被 `SdpramTop` 覆盖——因为 Step 2 固定了装置几何（64/64，ratio=1）。
5. 生成时有 `[Warning] 1 signals were pruned`；已确认**不是** `doutPipe_*`
   （`doutPipe_0/doutPipe_1` 都在网表里，判据也数到了），无害。
6. **时钟域现在来自"组件自己的时钟域"而不是形参 `clka`。** 原包装把 `clka/clkb` 交给 XPM blackbox
   （所以模块上没有 clk 端口）；新实现里 `Mem` 用 `ClockDomain.current`（= 实例化点的域）。
   两个调用点传的 `clka = clkb = this.clockDomain`，与该域**同一个**，所以等价（网表里 `sdpram`
   只有一个 clk）；但"传进来的 clka 与实例化点的域不同"这种情况现在**没有 assert 能拦**——
   `CLOCK_MODE != common_clock` 只是必要条件。将来若有人在别的时钟域作用域里实例化它，需要重新审这一条。

## 2026-10-08 B5-fix：sdpram 改同步读 —— 异步读被标 `ram_style = "distributed"`，4.7Mbit 权重 RAM 上不了 BRAM

**结论：DONE。** B5 的延迟契约（`doutb(t) = mem[addrb(t-READ_LATENCY)]`）本来就是对的，但**实现方式**在
资源结构上留了个致命口子：读出走的是**组合读出**（`readAsync`），SpinalHDL 会给这种 Mem 打
`ram_style = "distributed"`，Pango/Xilinx 就会把它做成 **LUTRAM**。延迟判据看不到这一层，
所以 B5 当时"全绿"却带着一个会让 B10 资源报告变成无意义的伤。

### 1. 观察到的证据（改动前，`gen/Npu.v`）

权重 RAM（144 个 `sdpram_128bit×256` 实例）与 quant RAM（3 个 `sdpram_144`，512bit 读）两块都是：

```verilog
                               // 改动前，gen/Npu.v 里 sdpram / sdpram_144 两个模块体各一处
(* ram_style = "distributed" *) reg [127:0] mem [0:255];    // sdpram（权重，144 实例 × 128bit × 256）
(* ram_style = "distributed" *) reg [127:0] mem [0:511];    // sdpram_144（quant，3 实例）
```

同一份网表里 `ram_style = "block"` 出现 14 次（`rowMem` / `logic_ram` / `mem_0` / `mem_1` /
FIFO 内部的 `_zz_*`）——那些是上游源码**显式** `addAttribute("ram_style = \"block\"")` 的存储器。

**为什么这是硬伤：** 权重 RAM = 144 × 128bit × 256 ≈ **4.7 Mbit**。LUTRAM 要吃掉约 4.7Mbit/… 量级的
分布式存储，Pango PG2L200H 上根本装不下（dev_map 会直接爆，或退化成巨额 LUT 占用把时序和余量全毁）。
这不是"性能差一点"，而是"实现不出来"。原 Xilinx 路径是 `MEMORY_PRIMITIVE = "block"`（BRAM）。

### 2. 根因（读的是 SpinalHDL 1.15.0 的字节码，不是猜）

`spinal.core.internals.PhaseDeviceDefault.onMemReadAsync()` 的逻辑是：**只要这个 Mem 有异步读口**，
且 Mem 的 tags 里还没有 `ram_style`，就 `mem.addAttribute("ram_style", "distributed")`。
同步读口**什么都不打**。所以：

- 想拿到 `ram_style = "block"`，"改成同步读"是**必要但不充分**的；
- 必须自己请求（这也正是上游对 BRAM 存储器的统一写法，见 §1 那 14 处）。

⇒ 本次改动 = **同步读（readSync）** ＋ **显式请求 `ram_style = "block"`**，两件事缺一不可。

### 3. 新的读出结构（`port/override/wa/xip/memory/xpm/XPM_MEMORY_SDPRAM.scala`，只动 `class sdpram`）

- 读出：`mem.readSync(address = <addr>, enable = io.enb)` —— 地址寄存、数据下一拍出，**1 拍**；
  这就是能映射到 BRAM 的形状。`readSync` 的 `enable` 自己负责"`enb` 低时保持"，
  所以第 0 级流水不再需要 `Mux(io.enb, …)`。
- 显式流水缩到 **`READ_LATENCY - 1` 级**：`doutPipe_0 … doutPipe_{READ_LATENCY-2}`。
  `io.doutb` = 最后一级；`READ_LATENCY == 1` 时没有显式级，直接取同步读的结果
  （Vec 长度 0，不做零长度索引）。
- **总延迟不变**：1（存储器同步读）+ (READ_LATENCY − 1)（显式流水）= `READ_LATENCY`。
  `READ_LATENCY == 2` 时网表是：`mem_spinal_port1 <= mem[addrb]`（enb 门控）→
  `doutPipe_0 <= rdBits` → `assign doutb = doutPipe_0`，即 `doutb(t) = mem[addrb(t-2)]`。
- **宽读结构原样保留**：`ratio = READ_WIDTH/WRITE_WIDTH`（quant RAM 是 1:4）仍是 `ratio` 个并行子字读，
  第 k 个子字地址 `{addrb, k}`、低地址→低位、`reverse.reduceLeft(_ ## _)` 拼接，只是每个子字读
  从 `readAsync` 变成 `readSync`（都还是 1 拍，算术不变）。`ratio == 1` 的快路径不变。
- 构造函数签名、`xpm_memory_sdpram` BlackBox 与 `object`：**未动**。

### 4. 一个必须记下来的实现坑（SpinalHDL 的 val 命名）

`val doutPipe = Vec(...)` / `val enPipe = Vec(...)` **必须留在组件体顶层**。第一版把它们放进了
Scala 的 `if (READ_LATENCY == 1) … else …` 块里，结果显式流水寄存器全退化成 `_zz_doutb` /
`_zz_doutb_1` / `_zz_doutb_2`（val 名没生效），判据一个 `doutPipe_<n>` 都数不到。
把 Vec 建到顶层、只在 `if` 里做赋值即可（`READ_LATENCY == 1` 时 Vec 长度为 0，不建任何寄存器）。

### 5. 判据 `tools/check_sdpram_latency.py` 被加强（这是本节的真正教训）

旧判据只数 `doutPipe_<n>` 索引 ⇒ **只有延迟一个维度**，正是它让 B5 带着 distributed 过闸。
新判据从 `gen/SdpramTop.v` 的 `module sdpram … endmodule` 体里判**两件事**，`expected` 现在指**总延迟**：

1. **资源结构（硬失败，与延迟无关）**：体内必须有 `ram_style = "block"`，且**不能**有
   `ram_style = "distributed"`；只要出现 `distributed` 就 FAIL（4.7Mbit 不可能是 LUTRAM）。
2. **总延迟**：`detected = 1（存储器同步读那一拍） + 不同 doutPipe_<n> 索引个数`，与 `expected` 比较。

输出格式保持 `expected=… detected=… indices=…`（另加 `ram_style=[…]`），失败 exit≠0，
保留 `sys.stdout.reconfigure(errors="replace")`，报错文案改成 ASCII（中文在 GBK 控制台上会糊）。

**四条输出（原文照抄）：**

```
$ python tools/check_sdpram_latency.py gen/SdpramTop.v 2      # 正对照（lat=2 生成）
expected=2 detected=2 indices=[0] ram_style=['block']
RESULT: PASS
pos_exit=0

$ python tools/check_sdpram_latency.py gen/SdpramTop.v 3      # 负对照 A（lat=3 生成）
expected=3 detected=3 indices=[0, 1] ram_style=['block']
RESULT: PASS
neg_exit_A=0

$ python tools/check_sdpram_latency.py gen/SdpramTop.v 2      # 负对照 B（同一文件对 2 的期望）
expected=2 detected=3 indices=[0, 1] ram_style=['block']
RESULT: FAIL (latency: detected != expected)
neg_exit_B=1
```

**新判据对"资源结构"那一维也有正负对照**（构造文件，不在仓内）：

```
$ python tools/check_sdpram_latency.py /tmp/pre_fix_shape.v 2     # 复原成改动前的形状
expected=2 detected=3 indices=[0, 1] ram_style=['distributed']
RESULT: FAIL (resource: ram_style = "distributed" present -- this can never be BRAM)
exit=1
```

`pre_fix_shape.v` 是把 §1 那份改动前网表的形状（`(* ram_style = "distributed" *) reg [63:0] mem [0:511];`
＋ `doutPipe_0/doutPipe_1`）复原出来的最小文件。**同一份形状：旧判据 `detected=2 == expected` ⇒ PASS
（就是 B5 当时过闸的那一幕），新判据 FAIL**。注意报的是资源结构而不是延迟 —— 新判据把资源检查放在
延迟之前，先红在哪就说在哪。要复原真件：`git show f30ff7e:ai_npu_exp/port/override/…/XPM_MEMORY_SDPRAM.scala`
（B5 那版）贴回 `rtl_src/` 再 `SdpramGen … 2` 即可。

下一条 `neg_dist.v` 是为了排除"FAIL 只是因为新判据多算了那 1 拍"：它 `detected == expected == 3`，
纯靠 distributed 才红。两条放一起才能说清"资源检查与延迟无关"：

```
$ python tools/check_sdpram_latency.py /tmp/neg_dist.v 3          # distributed + detected=3 == expected
expected=3 detected=3 indices=[0, 1] ram_style=['distributed']
RESULT: FAIL (resource: ram_style = "distributed" present -- this can never be BRAM)
exit=1

$ python tools/check_sdpram_latency.py /tmp/neg_noblock.v 2       # 无 block 属性（同步读但没请求）
expected=2 detected=2 indices=[0] ram_style=[]
RESULT: FAIL (resource: no ram_style = "block" in the module body)
exit=1
```

`neg_noblock.v` 排除另一个误解："改成同步读就自动有 block 属性"——见 §2，同步读**什么都不打**，
所以必须显式请求，这正是本 fix 的两半。

⇒ 新判据**不再只看延迟**：延迟全对但存储映射错了，也会红。

### 6. 改动确实进了真网表（Step 5）

```bash
$ printf 'runMain GenNpu D:/code/PDS/VexiiYeshenLinux/ai_npu_exp/gen\nexit\n' | bash sbt.sh
[info] GENNPU_DONE -> D:/code/PDS/VexiiYeshenLinux/ai_npu_exp/gen
[success] Total time: 5 s
$ md5sum gen/Npu.v
9127b394c17bac4db93b6eae9727551c    # 两次生成一致（确定性仍在）
$ grep -o 'ram_style = "[a-z]*"' gen/Npu.v | sort | uniq -c
     16 ram_style = "block"
```

| 量 | 改动前（B5） | 改动后（B5-fix） |
|---|---|---|
| `gen/Npu.v` md5 | `e2ad46ed2d5a4afba90e6f37566a37d0` | **`9127b394c17bac4db93b6eae9727551c`** |
| `ram_style = "distributed"` | 2（sdpram + sdpram_144） | **0** |
| `ram_style = "block"` | 14 | **16**（+ 两块 sdpram） |
| `xpm_memory_sdpram` 引用 | 0 | 0 |
| sdpram 实例 / 模块定义 | 147 / 2 | 147 / 2（未变） |
| 行数 | 55,542 | 55,549 |

改动后的两块存储器形状（`gen/Npu.v`）：

```verilog
// sdpram（weight，128bit×256，144 实例）—— 真网表原文
  reg        [127:0]  mem_spinal_port1;
  wire       [127:0]  rdBits;
  reg        [127:0]  doutPipe_0;
  (* ram_style = "block" *) reg [127:0] mem [0:255];
  always @(posedge clk) if(enb) mem_spinal_port1 <= mem[_zz_rdBits];   // 同步读：1 拍
  assign rdBits = mem_spinal_port1;
  assign doutb = doutPipe_0;                                           // + 显式 1 级 = 总 2 拍

// sdpram_144（quant，128bit 写 / 512bit 读，3 实例）—— 宽读结构原样保留，四个子字各一个同步读口
  reg        [127:0]  mem_spinal_port1;  ...  reg [127:0] mem_spinal_port4;
  always @(posedge clk) if(enb) mem_spinal_port1 <= mem[_zz_rdBits];   // _zz_rdBits   = {addrb,2'b00}
  ...                                                                  // _zz_rdBits_1 = {addrb,2'b01} …
  assign rdBits = {{{mem_spinal_port4,mem_spinal_port3},mem_spinal_port2},mem_spinal_port1};
  reg        [511:0]  doutPipe_0;
  (* ram_style = "block" *) reg [127:0] mem [0:511];
```

### 7. 未验证项 / 疑虑（写下来，别当已解决）

1. **`ram_style = "block"` 只是"请求"，不是"保证"。B10/dev_map 必须确认权重真落进 BRAM 块。**
   `ram_style` 是 Vivado/Xilinx 的属性名；Pango PDS 是否认它、以及在认识的情况下会不会照样
   把 128bit×256 拆成其它形式，**本次没有综合**，所以**未证实**。B10 要用 dev_map 的输出
   （EBR 块数 / 每块的深度-位宽表）核对：144 个 128×256 权重 RAM 期望落在 EBR 上，
   且不该出现量级异常的 LUT 占用。若 Pango 不认这个属性，出路是换/加 Pango 认识的属性
   （B9/B10 阶段处理），**不要**把它当成已解决。
2. **读写同址的行为**：同步读口下同址同时读写是 write-first（`readSync` 的 `readUnderWrite` 默认
   `dontCare`，SpinalHDL 会 emit 成 write-first）。与 B5 记的同一条差异，量级/方向没变，
   仍未做功能仿真确认。
3. **延迟契约仍只由"数寄存器"证明**，没有做时序级功能仿真（跑 `mem[addrb(t-2)]` 的波形）。
   本节的判据是结构性的，能排除"多一拍/少一拍"和"存储映射错"，但排除不了数据路径接错。
4. `ratio > 1` 的宽读路径仍只被整网表生成覆盖（装置是 64/64，ratio=1）。
5. B5 的其余疑虑（val 命名只影响网表可读性/判据、时钟域来自组件自身而非形参）不变。

## 2026-10-08 B6：sync FIFO Pango 化（StreamFifo，对外 IO 不变，`xpm_*` 残留清零）

**结论：DONE（附 2 条需 B10 承接的疑虑）。** `wa/WaFifo.scala` 的 `WaXpmSyncFifo` 不再实例化 Xilinx
`xpm_fifo_sync`（经 `FifoSync` 包装），改为可综合的 SpinalHDL `StreamFifo`；**对外 IO 名/方向/位宽逐条不变**，
唯一调用点 `conv/compute/ConvCompute.scala:120` **一行未改**。`Npu.v` 里 `xpm_*` 任何形式的引用 **0 次**
（B5 清了存储器、本节清了 FIFO），指纹 `9127b394…` → **`ad7312d6…`**（改动确实进了真网表，且两次生成一致）。

**入库物：**
- `ai_npu_exp/port/override/wa/WaFifo.scala`（新增覆盖：**只**改 `case class WaXpmSyncFifo` 的体，
  `object WaStreamFifo` / `class WaStreamFifo` 及文件其余部分与 `rtl_src` 逐字节相同，CRLF 亦同）
- 本文件

### 1. 替换的统一口径（原来的 3 条语义都保住）

| 原语义（XPM 包装） | 新实现（StreamFifo） |
|---|---|
| 写延迟 1 拍：`wr_en := RegNext(dataIn.fire)`、`din := RegNext(dataIn.payload)` | 同左（`push.valid := RegNext(dataIn.fire)`、`push.payload := RegNext(dataIn.payload)`，网表里是 `dataIn_valid_regNext` / `dataIn_payload_regNext`） |
| fwft 读、`rd_en` 推读 | `pop.ready := rd_en`（标准 StreamFifo 的 pop 握手；数据宽度/深度不变） |
| `sReady = wr_data_count + sCount < DEPTH-10`；`mReady = rd_data_count >= mCount` | `fifo.io.occupancy + sCount < DEPTH-10`；`fifo.io.occupancy >= mCount`（`occupancy` 与 XPM 的 `wr_data_count` 同义：已存字数） |

用到的 `XPM_FIFO_SYNC_CONFIG` 字段名（读 `rtl_src/wa/xip/memory/xpm/XPM_FIFO_SYNC.scala` 确认）：
`WR_DATA_COUNT_WIDTH`(12) / `RD_DATA_COUNT_WIDTH`(12) / `WRITE_DATA_WIDTH`(128) / `READ_DATA_WIDTH`(128) /
`FIFO_WRITE_DEPTH`(2048)。**写读同宽**（调用点两处传的都是 `convConfig.FEATURE_S_DATA_WIDTH`＝128），
故用普通 `StreamFifo`；为了不留"静默降级"，加了一条 Scala 级硬检查（不当就 elaboration 直接炸）：

```scala
require(config.WRITE_DATA_WIDTH == config.READ_DATA_WIDTH,
    "Pango 化后的 WaXpmSyncFifo 只支持写读同宽（StreamFifo 无位宽转换）")
```

### 2. `StreamFifo` API 适配：**0 处改名，任务书给的 `occupancy` 是对的**

用 `javap` 读 `spinalhdl-lib_2.12-1.15.0.jar` 核实（不是猜）：`StreamFifo.io` 的匿名 Bundle 实现
`StreamFifoInterface[T]`，成员是 `push` / `pop` / `flush` / **`occupancy`** / `availability`（都 `UInt`）。
因此 `fifo.io.occupancy` 直接可用，**不需要**改成别的名字。另外两条实测事实：
`io.flush` 有 `default(False)`，我们不管它，网表里由子模块内部 `assign` 成 `1'b0`（`StreamFifo_1` 实例上
`.io_flush (1'b0)`）；`StreamFifo` 默认 `withAsyncRead = false` ⇒ **同步读**（这正是我们要的形状，见 §3）。
**刻意没有用 `withAsyncRead=true` 去模仿 fwft**：异步读会被 `PhaseDeviceDefault.onMemReadAsync` 打上
`ram_style = "distributed"`，2048×128bit 的 FIFO 变 LUTRAM 是灾难（与 B5-fix 同一条教训）。

### 3. Step 2：FIFO 存储器的属性 —— **第一遍无属性，第二遍显式请求 block**

**第一遍（只换 FIFO，不加属性）实测**（`gen/Npu.v` md5 `643c66fbb28794a8a4ad970666909a8f`）：

```verilog
// module StreamFifo_1（就是新的 feature FIFO，9 个 WaXpmSyncFifo 实例共用这一个定义）
  ...
  reg [127:0] logic_ram [0:2047];        // ← 无任何 ram_style 标签
$ grep -o 'ram_style = "[a-z]*"' gen/Npu.v | sort | uniq -c
     16 ram_style = "block"              // 与基线同为 16，说明新 FIFO **没**被标 distributed，也**没**被标 block
```

⇒ 新 FIFO 存储器是 **未打标签（no attribute）**，**不是** `distributed`。这与 B5-fix 的根因一致：
SpinalHDL 1.15.0 只给"异步读"的 Mem 打 `distributed`，**同步读什么都不打**。
单块 = 2048×128bit = **256 Kbit**，9 个实例合计 **2.25 Mbit**（≥ 512 深、远超"大"的门槛），
所以按任务书规则 **显式请求 `block`**，写法照上游对 StreamFifo 内部 Mem 的既有做法
（`shape/Add.scala:100`、`shape/Shape.scala:109`、`shape/UpSampling.scala:47` 都是 `xxx.logic.ram.addAttribute(...)`）：

```scala
fifo.logic.ram.addAttribute("ram_style = \"block\"")   // StreamFifo 的内部 Mem 就叫 logic.ram（javap 已核实有 public ram() 访问器）
```

**第二遍（加了属性）实测**（最终件，md5 `ad7312d6ba9dfc1433d1a5ef83cb4a76`）：

```verilog
  (* ram_style = "block" *) reg [127:0] logic_ram [0:2047];   // module StreamFifo_1
```

**`ram_style` 直方图（最终件）：**

```
$ grep -o 'ram_style = "[a-z]*"' gen/Npu.v | sort | uniq -c
     17 ram_style = "block"        // 基线 16 + 新 FIFO 这一块；"distributed" 0 次
```

**裁决：新 feature FIFO 的存储器带 `ram_style = "block"`（16→17），`distributed` 全设计 0 次。**
存储形状也是 BRAM 可推断的同步读（不是组合读出）：
`always @(posedge clk) if(logic_pop_sync_readPort_cmd_valid) logic_ram_spinal_port1 <= logic_ram[cmd_payload];`

任务书 Step 2 的两条命令在本仓的原文输出（第二条为空：新 FIFO 的内部 Mem 在网表里叫 `logic_ram`
而不是 `mem [0:N]` —— 那是 `StreamFifo` 内部 `logic` Area 里名为 `ram` 的 Mem）：

```
$ grep -o 'ram_style = "[a-z]*"' gen/Npu.v | sort | uniq -c
     17 ram_style = "block"
$ grep -nE "mem \[0:[0-9]+\]" gen/Npu.v | grep -iE "fifo|_zz_" | head -20
(无输出；grep exit=1)
```

### 4. 对外 IO 逐条比对（`ConvCompute.scala` 无需改动）

新网表里 `WaXpmSyncFifo` 的端口表与旧件一致（名字/方向/位宽全同，声明顺序也保持原样）：

```verilog
module WaXpmSyncFifo (
  input  wire [11:0]   sCount,        // in UInt(WR_DATA_COUNT_WIDTH=12)
  input  wire [11:0]   mCount,        // in UInt(RD_DATA_COUNT_WIDTH=12)
  output reg           sReady,        // out(Reg(Bool()))
  output reg           mReady,        // out(Reg(Bool()))
  input  wire          dataIn_valid,  // slave Flow(...)
  input  wire [127:0]  dataIn_payload,
  input  wire          rd_en,
  output wire [127:0]  dout,          // out UInt(READ_DATA_WIDTH=128)
  input  wire          clk, input wire reset, input wire softReset
  ...
  reg dataIn_valid_regNext; reg [127:0] dataIn_payload_regNext;   // 1 拍写延迟原样保留
  StreamFifo_1 fifo ( .io_push_valid(dataIn_valid_regNext), .io_push_payload(dataIn_payload_regNext), .io_pop_ready(rd_en), ... );
  assign dout = fifo_io_pop_payload;
```

覆盖文件与 `rtl_src` 原件的差异**只在 `WaXpmSyncFifo` 的体内**（`diff` 全文可见；`head -47` **逐字节相同**，
含 CRLF）。`WaXpmSyncFifo` 模块实例数：**9**（`KERNEL_NUM = 9`，与改动前一致）。

### 5. Step 3：闸门（改动进了真网表 + 确定性）

```bash
$ bash port/apply_pango_port.sh
override: config/Config.scala
override: wa/WaFifo.scala
override: wa/xip/memory/xpm/XPM_MEMORY_SDPRAM.scala
applied 3 override(s) into /d/code/PDS/VexiiYeshenLinux/ai_npu_exp/rtl_src
$ cd port && printf 'runMain GenNpu D:/code/PDS/VexiiYeshenLinux/ai_npu_exp/gen\nexit\n' | bash sbt.sh 2>&1 | tail -3
[info] [Warning] 258 signals were pruned. You can call printPruned on the backend report to get more informations.
[info] GENNPU_DONE -> D:/code/PDS/VexiiYeshenLinux/ai_npu_exp/gen
[success] Total time: 9 s, completed 2026年10月8日 上午11:52:50
$ md5sum gen/Npu.v
ad7312d6ba9dfc1433d1a5ef83cb4a76 *gen/Npu.v
$ grep -o "xpm_[a-z_]*" gen/Npu.v | sort | uniq -c ; echo "(expect no output = zero xpm residue)"
(无输出 = 0)
# 确定性复跑（同一条生成命令再来一次）
$ md5sum gen/Npu.v
ad7312d6ba9dfc1433d1a5ef83cb4a76 *gen/Npu.v     # 与上一次完全相同
```

| 量 | 改动前（B5-fix 基线） | 第一遍（只换 FIFO） | 最终（+ `ram_style=block`） |
|---|---|---|---|
| `gen/Npu.v` md5 | `9127b394c17bac4db93b6eae9727551c` | `643c66fbb28794a8a4ad970666909a8f` | **`ad7312d6ba9dfc1433d1a5ef83cb4a76`** |
| `xpm_*`（任何形式） | `1 xpm_fifo_sync` + `52 xpm_fifo_sync_` | **0** | **0** |
| `ram_style = "block"` | 16 | 16 | **17** |
| `ram_style = "distributed"` | 0 | 0 | 0 |
| 模块数 / 行数 / 字节 | 51 / 55,549 / — | — | 51 / 55,592 / 2,055,315 |
| `WaXpmSyncFifo` 实例（模块定义） | 9（1） | 9（1） | 9（1） |
| `[Warning] N signals were pruned` | 1（B5） | 258 | 258 |

`xpm` 字样在网表里剩下的**只是 Scala 类名/实例名** `WaXpmSyncFifo`（故意不改名，才能让调用点零改动），
**没有任何 Xilinx 原语**：`grep -oi "[a-z_]*xpm[a-z_]*" gen/Npu.v | sort | uniq -c` ⇒
`18 WaXpmSyncFifo` + `8 WaXpmSyncFifo_` + `128 waXpmSyncFifo_`（全是标识符，不是 `xpm_fifo_sync` 一类）。
`FifoSync` 模块本身也已从网表消失（`grep -c "^module FifoSync" gen/Npu.v` ⇒ 0）。

### 6. 未验证项 / 疑虑（写下来，别当已解决）

1. **读侧时序与 fwft 不同：新 FIFO 的 `dout` 比原来多约 1 拍。** 原 XPM 是 `READ_MODE = fwft`、
   `FIFO_READ_LATENCY = 0`（首字直接落出）；新实现是标准 `StreamFifo`（同步读 + `addressGen`/`readArbitration`
   的 pop 握手，`io_pop_valid = logic_pop_sync_readArbitration_translated_valid`），从写到 `dout` 可见
   大致 2 拍（写寄存 1 拍 + 存储器同步读 1 拍）而不是 XPM 的 ~1 拍。**这是刻意的**：想要 fwft 就得用
   `withAsyncRead=true`，而异步读会被标 `distributed` ⇒ 2.25Mbit 的 FIFO 变 LUTRAM（见 §2）。
   两者都被 `sReady`/`mReady` 阈值 + `rd_en` 握手包着，多 1 拍 FIFO 深度不影响功能，但
   **这不是功能仿真结论**：本任务只证"接口不变 + 原语清零 + 确定性"，**没有跑功能仿真/比对波形**。
   若后续要做等价性验证，这里是最该看的点。
2. **`ram_style = "block"` 只是"请求"，不是"保证"。** 与 B5-fix 第 7 条同一性质：`ram_style` 是
   Vivado/Xilinx 的属性名，Pango PDS 认不认、以及认了之后会不会照做，**本次没有综合**。B10 的 `dev_map`
   必须核对 9 × 2048×128bit 的 FIFO 落在 EBR 上（而不是被拆成 LUTRAM），**不要**把它当成已解决。
3. **顺带发现：本仓还有 4 处"上游没打属性"的 FIFO/存储 Mem（不在 B6 范围内，未动）。**
   最终件 `gen/Npu.v` 里未打 `ram_style` 的存储有：`StreamFifo_10` 的 `logic_ram [0:4095]`（128bit，
   **512 Kbit**，1 实例）、`StreamFifo_14` 的 `logic_ram [0:31]`、`StreamFifo` 的 `logic_ram [0:15]`、
   `MaxPooling` 的 `channelMem [0:31]`。前两个小，但 **`logic_ram [0:4095]` 那块量级不小**。
   它们不是 Xilinx 原语（是上游 `WaStreamFifo`/`StreamFifo` 用法），也**不是 B6 的交付物**——
   按"不猜、不多改"原则本次只记录。**B10 读资源报告时请一并核对这 4 块**；若 Pango 对未标属性的大 Mem
   默认做成 LUTRAM，那是另一个必须单独开的任务（改它们会牵动别的模块的语义与验证）。
   参考：同一份网表里 `StreamFifo_6`（4096 深）与 `StreamFifo_13`（2048 深）**被上游显式标了 block**，
   说明"标 vs 不标"在同一份设计里确实同时存在，不是本次实现引入的。
4. `[Warning] 258 signals were pruned`（基线 B5 是 1）：都来自去掉 XPM 包装后不再被驱动的原 BlackBox 输出
   （`almost_empty`/`dbiterr`/`sbiterr`/`underflow`/`wr_ack`/`prog_*` 等既没接出去也没用的线）。
   已确认是"没用即删"的正常行为——`sReady`/`mReady`/`dout` 一个都没被删（§4 的端口表与赋值都在）。
5. `WaXpmSyncFifo` 这个名字现在是**历史遗留名**（内部已无 XPM）。**刻意保留**：改名会让
   `ConvCompute.scala` 与网表里的 9 个实例名一起变，违背"调用方零改动"的验收条件。B9（停用 Xilinx IP tcl）
   若想连名字一起洗，那是另一个决定，需要同时改调用点。

---

## 2026-10-08 B7：MAC DSP Pango 化（行为模型，6 级流水契约带正负对照；`dsp_macro` 清零）

**结论：** 计算路径上的 Xilinx `dsp_macro` IP 已从 MAC 里移除，换成**等延迟（6 级）**的行为级
乘法流水；`ConvCompute.scala` 调用点**零改动**（`DSP` 对外 IO 不变），`gen/Npu.v` 里 `dsp_macro` 字样
= 0，`mulWeight`（被实例化的 Xilinx IP 模块名）字样 = 0，Xilinx 的 DSP tcl 不再生成。

- **状态**：DONE
- **交付物**：`port/override/wa/xip/math/DSP.scala`（覆盖件）、`rtl_test/DspTop.scala`（判据装置）、
  `tools/check_dsp_latency.py`（判据）、本节
- **契约**：原 IP `(A+D)*B`，`pipeline_options By_Tier`，`tier_1..tier_6` 全 `true` ⇒ **6 级流水**。
  行为模型与它**级数相同**（不是近似、不是少 1 拍）；调用点不感知。

### 1. 被替换的 Verilog（原文，`else` = 非 `dsp2x` 分支）

`rtl_src/wa/xip/math/DSP.scala` 的 `else` 分支末尾，原来直接实例化一个**未定义的 Xilinx IP 模块**
（模块名 = `componentName`，本仓恒为 `mulWeight`），Pango 综合会因找不到该模块而失败：

```verilog
          assign din =  $signed({d,16'd0});
          mulWeight mulWeight_inst (          // ← 上游唯一一处 create_ip dsp_macro 生成的 IP 实例
            .CLK(CLK),  // input wire CLK
            .A(ain),      // input wire [7 : 0] A
            .B({1'b0,b}),      // input wire [8 : 0] B
            .D(din),      // input wire [24 : 0] D
            .P(pout)      // output wire [33 : 0] P
          );
endmodule
```

对应 tcl（`object DSP.genTcl`）：`create_ip -name dsp_macro ... CONFIG.instruction1 {(A+D)*B}
CONFIG.pipeline_options {By_Tier} CONFIG.tier_1 {true} ... CONFIG.tier_6 {true}` —— **tier_1..tier_6 全 true
= 6 拍**，这是"6 级"这个数字的唯一来源。

### 2. 新的行为级流水（替代上面的实例化）

`(A+D)*B` 的算术模型照搬，加上 `DSP_STAGES`（默认 6）级顺序移位寄存器；寄存器名固定
`dspPipe_0..dspPipe_(N-1)`，`pout` 由最后一级驱动（内部名 `pout` 与下游 wrapper 的舍入逻辑都不动）：

```verilog
          wire  signed       [25:0]  dspSum;
          assign dspSum = ain + din;                        // A(8b signed) + D(25b signed, = d<<16)
          wire  signed       [33:0]  dspProd;
          assign dspProd = dspSum * $signed({1'b0,b});      // (A+D)*B，两个操作数都 $signed ⇒ 有符号乘

          reg  signed       [33:0] dspPipe_0;   // 6 级：DSP_STAGES 插值而来
          reg  signed       [33:0] dspPipe_1;
          reg  signed       [33:0] dspPipe_2;
          reg  signed       [33:0] dspPipe_3;
          reg  signed       [33:0] dspPipe_4;
          reg  signed       [33:0] dspPipe_5;

          always@(posedge CLK)begin
              dspPipe_0 <= dspProd;
              dspPipe_1 <= dspPipe_0;
              dspPipe_2 <= dspPipe_1;
              dspPipe_3 <= dspPipe_2;
              dspPipe_4 <= dspPipe_3;
              dspPipe_5 <= dspPipe_4;
          end
          assign pout = dspPipe_5;
```

关键设计点：
- **位段对齐不变**：`D = d<<16`，所以 `d*b` 项自然落在 `pout[31:16]`、`A*b` 落在 `pout[15:0]`，
  下游 wrapper 的"低 16 位 + 高 16 位（用 `a1[15]` 做舍入）"读到的东西与原来一致。乘积 26×9=35bit，
  截到 34bit = 原 `P/pout` 位宽；wrapper 只用 `pout[31:0]`，故截断不影响可用位。
- **必须有符号乘**：`$signed({1'b0,b})` 强制两个操作数都是有符号，否则 `dspSum` 为负时 Verilog 会按无符号
  乘、低位结果错。
- **级数是参数化的**：`class DSP(componentName, clockDomain2X = null, stages: Int = 6)`，
  体内 `val DSP_STAGES: Int = stages` 插值进字符串。默认 6 = 生产值；`DspTop(stages)` 可任意传，
  负对照就是传 5。**不是把 6 硬编码进字符串**。`object DSP.genTcl` 变 no-op（原 `create_ip` 逻辑整体
  注释保留），`DSP.apply` 签名不变 ⇒ 两个调用点（`ConvCompute.scala:177` / `:187`）编译无需改。

### 3. 判据 `tools/check_dsp_latency.py`（Step 4 闸门：正 + 负对照，四条输出原文照抄）

判据逻辑：在 `module DSP` 体内数不同 `dspPipe_<n>` 索引 ⇒ `detected`；要求 `detected == expected`
且索引恰为 `0..expected-1`（连续、从 0 起，排除"乱改寄存器"）。

```bash
$ bash port/apply_pango_port.sh   # 覆盖件进 rtl_src
$ cd port && printf 'Test/runMain DspGen .../gen 6\nexit\n' | bash sbt.sh 2>&1 | tail -6
[info] [Done] at 0.421
[info] DSPGEN_DONE stages=6
[success] Total time: 5 s, completed 2026年10月8日 上午11:57:43
$ python tools/check_dsp_latency.py gen/DspTop.v 6 ; echo "pos_exit=$?"
expected=6 detected=6 indices=[0, 1, 2, 3, 4, 5]
RESULT: PASS
pos_exit=0                                    # 正对照：6 级，检出 6，PASS
# 负对照：stages = 5
$ printf 'Test/runMain DspGen .../gen 5\nexit\n' | (cd port && bash sbt.sh) 2>&1 | tail -3
[success] Total time: 2 s, completed 2026年10月8日 上午11:57:52
$ python tools/check_dsp_latency.py gen/DspTop.v 5 ; echo "neg_exit_A=$?"
expected=5 detected=5 indices=[0, 1, 2, 3, 4]
RESULT: PASS
neg_exit_A=0                                  # 负对照 A：真做 5 级时，按 5 判 = PASS
$ python tools/check_dsp_latency.py gen/DspTop.v 6 ; echo "neg_exit_B=$?"
expected=6 detected=5 indices=[0, 1, 2, 3, 4]
RESULT: FAIL
neg_exit_B=1                                  # 负对照 B：真做 5 级却按 6 判 = FAIL（判据真的会咬）
# 还原为 6
$ printf 'Test/runMain DspGen .../gen 6\nexit\n' | (cd port && bash sbt.sh) 2>&1 | grep DSPGEN_DONE
[info] DSPGEN_DONE stages=6
$ python tools/check_dsp_latency.py gen/DspTop.v 6 ; echo "restored_exit=$?"
expected=6 detected=6 indices=[0, 1, 2, 3, 4, 5]
RESULT: PASS
restored_exit=0
```

四条输出与 exit：**`pos_exit=0`（检 6）、`neg_exit_A=0`（检 5）、`neg_exit_B=1`（检 5≠6）、
`restored_exit=0`**。判据正负对照都成立，且是**结构性**证明（数寄存器），**不是仿真结论**。

### 4. Step 5：改动确实进了真网表

```bash
$ bash port/apply_pango_port.sh
override: config/Config.scala
override: wa/WaFifo.scala
override: wa/xip/math/DSP.scala
override: wa/xip/memory/xpm/XPM_MEMORY_SDPRAM.scala
applied 4 override(s) into .../rtl_src
$ cd port && printf 'runMain GenNpu .../gen\nexit\n' | bash sbt.sh 2>&1 | tail -6
[info] [Warning] 258 signals were pruned. ...
[info] GENNPU_DONE -> D:/code/PDS/VexiiYeshenLinux/ai_npu_exp/gen
[success] Total time: 9 s, completed 2026年10月8日 上午11:58:42
$ md5sum gen/Npu.v
c6df8278ecd73706097e2d7fdc1cbdd5 *gen/Npu.v
# 确定性复跑（同一条生成命令再来一次）
$ md5sum gen/Npu.v
c6df8278ecd73706097e2d7fdc1cbdd5 *gen/Npu.v     # 完全相同 ⇒ 确定性
```

| 量 | B7 前（B6 基线） | B7 后 |
|---|---|---|
| `gen/Npu.v` md5 | `ad7312d6ba9dfc1433d1a5ef83cb4a76` | **`c6df8278ecd73706097e2d7fdc1cbdd5`**（不同） |
| `dsp_macro` 计数 | 0 | **0** |
| `mulWeight mulWeight_inst`（Xilinx IP 实例）| 1 | **0** |
| `module DSP` 定义数 | 1 | **1**（恰好一个，1152 个实例共用同一份体） |
| `^  DSP dSP_` 实例数（MAC 阵列）| 1152 | **1152** |
| `xpm_*` 残留 | 0 | 0 |
| 模块数 / 行数 | 51 / 55,592 | 51 / 55,618（+26 行 = 注释 + 6 级流水） |
| 网表非 ASCII 行 | 0 | **0**（新注释全用 ASCII） |
| `[Warning] N signals were pruned` | 258 | 258 |

**DSP 实例计数命令与结果**（B10 预测 DSP/APM 预算用）：
```bash
$ grep -cE "^  DSP dSP_" gen/Npu.v
1152
```
= `KERNEL_NUM × (COMPUTE_CHANNEL_OUT_NUM/2) × COMPUTE_CHANNEL_IN_NUM` = `9 × (16/2) × 16` = **1152**，
与 `GenNpu.scala` 里 `ConvConfig(8, 16, 16, ...)` 对得上。**即 Pango 上需要 1152 个乘法单元
（DSP48 等价物 / APM）。** 顺带在真网表上跑判据也通过：`check_dsp_latency.py gen/Npu.v 6` ⇒ PASS。

**Xilinx tcl 是否不再生成**：是。先删掉旧的 `port/verilog/tcl/generatemulWeight.tcl` 再重跑 GenNpu，
文件**没有被重建**（`port/verilog/tcl/` 里 13 个 tcl 全是 Mul/AddSub 等 B8 范畴的，
DSP 的那一个消失）；`genTcl` 已变 no-op。（`port/verilog/` 在 `.gitignore` 里，不入库。）

### 5. 未验证项 / 疑虑（写下来，别当已解决）

1. **"6 级"是结构性等价，不是功能等价。** 判据只证"寄存器级数 = 上游 tier 数 = 6"，**没有跑仿真**
   比对 `(A+D)*B` 的数值/时序波形。行为模型的位段推导（`d*b` 落 `[31:16]`、`A*b` 落 `[15:0]`、
   舍入用 `a1[15]`）是**按原 IP 语义读出来的**，未与 Xilinx 仿真器对照。若后续做等价性验证，这里是最该看的点。
2. **时序含义的差异（不是延迟差异，是"级间怎么切"）。** 原 IP 的 6 级是 `By_Tier` 把
   `(A+D)` 与乘、加折叠进 6 个 tier；新模型是"整组合乘积 → 6 级纯寄存"。**总延迟同为 6**（这是契约），
   但每拍的逻辑深度分布不同 ⇒ 同一时钟约束下新模型的**关键路径更长**（一整拍里做完了加法+乘法）。
   Pango 综合（B10）若时序紧，需要**在该乘法内部再插寄存器**（会改变级数，属另一个决定，必须重做判据正负对照）。
   本次不做，只按契约保 6 拍。
3. **`$signed` 乘法在 Pango 综合器的推断**：新模型是一个 26×9 的有符号乘，Pango 会不会把它映射到 APM/DSP，
   还是铺成 LUT 阵列，**本次没有综合**。B10 的 `dev_map` 要核对这 1152 个乘是否落到硬乘法器上。
4. **`module DSP` 只有 1 份（B7 前也只有 1 份）。** 任务书预期"去掉 `componentName` 后会从多份变 1 份"，
   但实测 **B7 前已经是 1 份**：两个调用点传的 `componentName` 恰好都是 `"mulWeight"`，内联体本已相同，
   SpinalHDL 已按内容去重。**不是本次改动带来的**，据实记录。真正的收益是：体内那个
   `mulWeight mulWeight_inst`（未定义模块）被彻底删掉（计数 1→0），Pango 不再因缺模块而失败。
5. `genTcl` 用 Scala 块注释整体停用（`/* B7-noop-begin ... B7-noop-end */`），体里没有 `*/`，安全；
   相关 `import java.io._` / `FileUtils` / `filePath` 变成未使用（仅告警，不影响编译与生成）。

---

## 2026-10-08 B8：乘法器 Pango 化（行为乘法 + 位段语义；`mult_gen` 清零；判据带正负对照）

### 0. 一句话结论

`rtl_src/wa/xip/math/Mul.scala` 里的 Xilinx `mult_gen` IP 换成**等拍数、等位段**的行为乘法。
`gen/Npu.v` 里 5 个 Mul 模块**从「只被实例化、没有定义」变成各有一份模块体**，`mult_gen` 计数 0，
`port/verilog/tcl/` 里 5 个乘法 tcl 消失且**重跑不再生成**。

判据 `tools/check_mul.py` 只证**结构性**（流水级数 + 位段边界 [msb:lsb]），**不证数值等价**——
数值另用 iverilog 临时交叉验证（§6，非交付物）。

### 1. 选型：形状 **(a)**（仍是 BlackBox + `setInlineVerilog`），不是 (b) 普通 Component

三条理由，按重要性排：

1. **IO 契约逐字不变**。`Mul` 的端口是 `A`/`B`/`P`/`CLK`（`noIoPrefix` + `mapClockDomain(clockDomain, io.CLK)`）。
   改成普通 `Component` 后，SpinalHDL 会按时钟域**自己**生成 `clk`/`reset` 端口，`CLK` 这个显式输入端口
   就保不住，注册域还得另接 —— 那就动了 5 个调用点的前提（虽然 Scala 侧 `m.io.A <> io.A` 看着一样，
   但生成物端口名/复位行为变了）。BlackBox 路线**调用点一行都不用改**。
2. **与 B7（DSP）同形状**，判据/回溯口径一致，减少 B10/B12 的解释成本。
3. **能逐字控制发出的 Verilog**，包括 `mulPipe_<n>` 寄存器名和 `[msb:lsb]` 切片文本 —— 判据才数得准、看得见。
   普通 Component 路线要靠 SpinalHDL 的命名推导去凑 `mulPipe_n`，脆。

类构造参数新增 `outMsb` / `outLsb` / `pipelineStage`；**`object Mul.apply` 的两个重载签名一字未动**
（重载 1 → 位段 `[P_WIDTH-1:0]`，等于原 tcl 的 `OutputWidthHigh=P_WIDTH-1` + 默认 `OutputWidthLow=0`，
所以「无切片」这一路无需新参数）。

### 2. 发出的行为 Verilog（`scaleMul` = `Quan.scala:99`，原文照抄）

```verilog
module scaleMul (
  input  wire [47:0] A,
  input  wire [31:0] B,
  output wire [31:0] P,
  input  wire CLK
);

  wire signed [47:0] aExt;
  assign aExt = $signed(A);
  wire signed [32:0] bExt;
  assign bExt = $signed({1'b0, B});

  wire signed [79:0] prod;
  assign prod = aExt * bExt;

  reg  signed [79:0] mulPipe_0;   // ... mulPipe_1 .. mulPipe_7（共 8 = 原 CONFIG.PipeStages）
  always @(posedge CLK) begin
    mulPipe_0 <= prod;            // 整条流水搬的是**完整乘积**（80 位）
    mulPipe_1 <= mulPipe_0;
    /* ... */
    mulPipe_7 <= mulPipe_6;
  end

  assign P = mulPipe_7[79:48];    // 位段在**输出**选，和 IP 的 OutputWidthLow/High 一致
endmodule
```

要点：
* 两个操作数先各自抬成**显式有符号**（signed → `$signed(x)`；Unsigned → `$signed({1'b0,x})`）再相乘。
  直接写 signed × unsigned 会被 Verilog 按**无符号**算，有符号操作数为负时低位全错 —— 这正是要防的静默错误。
* `prod` 声明宽度 = `A_WIDTH+B_WIDTH`，即上下文宽度 ⇒ 精确积（|A·B| < 2^(A+B-1)，装得下），不是低位截断。
* 流水搬**完整乘积**（寄存器宽 = A+B），位段在输出选。原 IP 也是「内部流水 + 输出选位段」，同构。

### 3. 判据 `tools/check_mul.py`：相对任务书模板的两处改动（**都是加强**）

* (a) module 名正则按实现实际发出的名字匹配：`MulTop` 里 `componentName = "mul"` ⇒ 命中模板的 `mul\w*`，
  正则**原样未放宽**。另加一个**可选**第 5 参用于在**真网表** `gen/Npu.v` 上点名检查
  `scaleMul`/`concatMul`/... （它们不以 `mul` 开头，默认正则匹配不到；不传时行为完全不变）。
* (b) 模板只查「module 体内**任意**出现 `[msb:lsb]`」。但 `P` 的端口声明 `output wire [31:0] P` 本身就在体内，
  会让 `(31,0)` 这类期望**蒙混过关**（LeakyRelu 那一路恰好就是 32→`[31:0]`，实测确实能蒙混）。
  所以**额外要求**该切片出现在**驱动 `P` 的赋值语句**里（`assign P = mulPipe_N[...]`）。两条取与。

**「完整乘积、无切片」怎么表达**：不需要 `--full`。原 tcl 里重载 1 设 `OutputWidthHigh = P_WIDTH-1`、
不设 `OutputWidthLow`（默认 0），所以「无切片」== 位段 `[P_WIDTH-1:0]`；实现里也**显式**发出
`assign P = mulPipe_N[P_WIDTH-1:0];`。于是传 `<P_WIDTH-1> <0>` 就精确表达「完整乘积」，且照样能做负对照。
（任务书模板里那个 `[--full]` 占位因此没实现。）

### 4. Step 4 闸门：单 Mul 小装置 `ai_npu_exp/rtl_test/MulTop.scala` 上的控制

```
$ python tools/check_mul.py gen/MulTop.v 8 79 48          # Quan 配置（生成 48 32 32 s 8 79 48）
module=mul
expected_stages=8 detected_stages=8 indices=[0, 1, 2, 3, 4, 5, 6, 7]
expected_slice=[79:48] slices_found=[(31, 0), (32, 0), (47, 0), (79, 0), (79, 48)]
P-assign slices=[(79, 48)] (need [79:48])
RESULT: PASS
quan_exit=0
```
```
$ python tools/check_mul.py gen/MulTop.v 6 63 31          # 任务书负对照（错位段 + 错级数）
expected_stages=6 detected_stages=8 indices=[0, 1, 2, 3, 4, 5, 6, 7]
expected_slice=[63:31] slices_found=[(31, 0), (32, 0), (47, 0), (79, 0), (79, 48)]
RESULT: FAIL
wrong_cfg_exit=1
```
另加两条**只错一项**的负对照，证明两个检查各自独立起作用（任务书那一条是两项同时错，分不清是谁在报）：
```
$ python tools/check_mul.py gen/MulTop.v 8 63 31          # 级数对(8)、位段错
RESULT: FAIL   slice_only_exit=1
$ python tools/check_mul.py gen/MulTop.v 7 79 48          # 位段对([79:48])、级数错
RESULT: FAIL   stages_only_exit=1
```
Concat 配置（生成 `32 32 33 s 6 63 31`）：
```
$ python tools/check_mul.py gen/MulTop.v 6 63 31          # 正
RESULT: PASS
concat_exit=0
$ python tools/check_mul.py gen/MulTop.v 8 79 48          # 任务书负对照
RESULT: FAIL
wrong_cfg2_exit=1
$ python tools/check_mul.py gen/MulTop.v 6 79 48          # 级数对(6)、位段错
RESULT: FAIL
concat_slice_only_exit=1
```
无切片一路（LeakyRelu `16 16 32 s 3 31 0`）：
```
$ python tools/check_mul.py gen/MulTop.v 3 31 0           # 正
RESULT: PASS   leaky_exit=0
$ python tools/check_mul.py gen/MulTop.v 3 31 15          # 负
RESULT: FAIL   leaky_neg_exit=1
```
（这一路 `slices_found=[(15,0),(16,0),(31,0)]` —— 里面那个 `(31,0)` 就是 `P` 端口声明蒙出来的，
所以 §3(b) 那条「必须落在 P 赋值语句上」的加强是必要的：真正的 `P-assign slices=[(31,0)]` 才是位段证据。）

### 5. Step 5：改动确实进了真网表 `gen/Npu.v`

```
$ md5sum gen/Npu.v
c6df8278ecd73706097e2d7fdc1cbdd5   # 改动前（与任务书给的基准一致，已自行核对）
ba916dcc59f47529537c2278dd3f6dba   # 改动后
# 确定性复跑（同一条 GenNpu 命令再来一次）⇒ 仍是 ba916dcc59f47529537c2278dd3f6dba（稳定）
```

| 量 | 改动前 | 改动后 |
|---|---|---|
| `grep -c "mult_gen" gen/Npu.v` | 0 | 0（见下方诚实说明） |
| `^module <name> (` 的 Mul 模块**定义数** | 0 | **5**（scaleMul / concatMul / addMul / leakyReluMul / shapeCount1 各 1 份） |
| Mul **实例数** | 65 | **65** |
| `port/verilog/tcl/` 文件数 | 13（其中 5 个含 `mult_gen`） | **8**（乘法 tcl 全删且重跑**不重建**） |
| 模块总数 / 行数 | 51 / 55,618 | 56 / 55,865（+5 模块、+247 行） |
| 网表非 ASCII 行 | 0 | **0**（新注释全 ASCII） |

**乘法器实例数 = 65**（B10 的 DSP/APM 预算用）：
```bash
$ for n in scaleMul concatMul addMul leakyReluMul shapeCount1; do ...
scaleMul=16  concatMul=16  addMul=16  leakyReluMul=16  shapeCount1=1     # 合计 65
```
对应 `Quan.scala` 通道并行 16、`Concat.scala`/`Add.scala`/`LeakyRelu` 各 16、`Shape.scala` 1。

**判据直接在真网表上跑**（用第 5 参点名，5 个模块全 PASS，负对照全 FAIL）：
```
scaleMul      (8, 79, 48) PASS / (8, 63, 31) FAIL      P-assign=[(79,48)]
concatMul     (6, 63, 31) PASS / (6, 79, 48) FAIL      P-assign=[(63,31)]
addMul        (6, 63,  0) PASS                          P-assign=[(63,0)]
leakyReluMul  (3, 31,  0) PASS                          P-assign=[(31,0)]
shapeCount1   (3, 16,  0) PASS / (4, 16, 0) FAIL        P-assign=[(16,0)]
```

**诚实说明（重要）**：任务书预期「`mult_gen` 计数 0」是**改动后**的证据，但**改动前就已经是 0**
—— 因为 SpinalHDL 对 BlackBox 只写**实例**（用 `componentName` 当模块名，如 `scaleMul mulScale_0 (...)`），
从不写 IP 本名。所以「mult_gen 清零」这条 grep **不具区分度**。真正区分改动的是：
① md5 变化；② 5 个 Mul 模块**从 0 份定义变成 5 份定义**；③ 5 个乘法 tcl 消失且不再重建。
（B7 的 `dsp_macro` 同理。）

**每个 Mul 模块只发 1 份体、被 N 个实例共用**（16 实例共用 1 份 `scaleMul`），符合 BlackBox 定义的正常行为。

### 6. 附（**非交付物**，临时做完即删）：iverilog 数值交叉验证

结构性判据证不了数值，所以临时在 `gen/_mul_simcheck/`（gitignored）写了个一次性装置：
从 `gen/Npu.v` 抠出目标 Mul 模块，用 `iverilog -g2012` + `vvp` 跑 310 个向量
（10 个边界：A/B 的 max/min、0、±1；300 个随机），逐拍与 **Python 任意精度**算出的期望值比对
（两套独立实现，所以能抓位段/截断错误），跑完即删。

正对照（期望 = `((A*B) mod 2^(A+B)) >> lsb`，取 P_WIDTH 位）：
```
Quan.scala:99      scaleMul     st=8 slice=[79:48] errors=0  PASS
Concat.scala:114   concatMul    st=6 slice=[63:31] errors=0  PASS
Add.scala:213      addMul       st=6 slice=[63:0]  errors=0  PASS
LeakyRelu.scala:36 leakyReluMul st=3 slice=[31:0]  errors=0  PASS
Shape.scala:99     shapeCount1  st=3 slice=[16:0]  errors=0  PASS
```
负对照（期望故意改成**天真的低 P_WIDTH 位截断** `prod[P_WIDTH-1:0]`）：
```
scaleMul   errors=305  ← 305 个向量全错 ⇒ 位段一旦写错必被抓   (PASS(neg))
concatMul  errors=305  ← 同上                                  (PASS(neg))
addMul     errors=0    ← 该路 msb=P_WIDTH-1、lsb=0，两者本就相等 (负对照在此路是恒等的)
leakyReluMul errors=0  ← 同上
shapeCount1  errors=0  ← 同上
```
即：这个数值判据**恰好在那两个真正危险的位段配置上**（`[79:48]`、`[63:31]`）有区分度，
而在「完整乘积」那三路上按构造就该无区分度。结论：本实现的位段语义**数值上正确**，不是恰好过判据。

### 7. 未验证项 / 疑虑（写下来，别当已解决）

1. **流水搬的是完整乘积，寄存器比「搬切片」宽。** 宽 = `A_WIDTH+B_WIDTH`（80/64/64/32/17），
   合计 FF ≈ `16×8×80 + 16×6×64 + 16×6×64 + 16×3×32 + 1×3×17` = **24,115**。
   若改成「先切片再进流水」，则为 ≈ 14,995（省 ~9,120 FF）。选宽的理由是与 IP 同构（IP 内部流水也是全宽），
   **这是一处有意的资源/保真取舍，B10 若 FF 吃紧可以在这里省**（改的话要重跑本判据正负对照）。
2. **Pango 会不会把 `aExt*bExt` 落到硬乘法器（APM/DSP）没综合过。** 25 个窄的 + 40 个宽的乘法
   （65 个实例），铺成 LUT 阵还是落 APM，只有 B10 的 `dev_map` 能回答。
3. **数值验证是「模块级」的，不是整网表级。** 只证了 5 个 Mul 模块自身的位段/符号性；
   没证 `Quan.scala`/`Concat.scala` 这些调用点**外面**的连线是否按同样语义用 P（那是调用点的事，
   本次一行未改，属于「没动就不该更坏」）。整网表数值等价需要跑端到端仿真，M0 不在范围。
4. **符号性对 unsigned B 的处理是「零扩展 1 位再当有符号」。** 对 `PortBType=Unsigned` 语义正确
   （B 恒非负 ⇒ 值不变）。若将来出现 B 为 signed 的调用（当前 5 个调用点全是 unsigned B），
   走的是 `$signed(B)` 分支，也被数值/结构判据覆盖的同一套代码路径，但没有实测用例。
5. **`Shape.scala:99` 的位宽是动态的**（`6/11/17`，由指令寄存器推出）。本次只验证了
   `GenNpu` 这一组配置下的 `6/11/17`；`require` 会在位段越界时**在展开期报错**（fail fast），
   所以别的配置若越界不会静默出错 —— 但没跑过别的配置。

---

## 2026-10-08 B9：停用 Xilinx IP tcl 生成 + 「无 Xilinx 残留」可执行判据（正负对照）

### 0. 一句话结论

- **8 个残留 tcl 的来源查清**：7 个来自 `wa/xip/math/AddSub.scala` 的 `object AddSub.genTcl`
  （`create_ip -name c_addsub`），1 个来自 `wa/xip/axi/StreamDataWidthConvert.scala` 的
  `object StreamDataWidthConvert.genTcl`（`create_ip -name axis_dwidth_converter`）；
  汇总器另有一个 `misc/TotalTcl.scala` 的 `genTotalTcl`（本次 `GenNpu` 入口不经过它）。
  三者全部用 override 变 no-op（**公开签名一字未改**，无 call site 需要改）。
- **新生成不再产出任何 tcl**：`port/verilog/` **整个目录都不再出现**（不是「空目录」）。
- **判据落盘**：`ai_npu_exp/tools/check_no_xilinx.sh <gen_dir>` ⇒ PASS / `exit 0`；
  负对照（真代码含 `xpm_fifo_sync`）⇒ FAIL / `exit 1`。
- `gen/Npu.v` 的 md5 **改动前 = 改动后 = `ba916dcc59f47529537c2278dd3f6dba`（不变）**。
- **一个真实问题（finding，B9 不修，只如实报）**：两个 emitter 所在的**类**
  （`class AddSub` / `class StreamDataWidthConvert`）**同时是仍在数据通路里被真实例化的
  Xilinx IP 黑盒**，且 `gen/Npu.v` 里**没有任何模块定义**（113 处悬空实例）。见第 3 节。

### 1. Step 1：谁在发这 8 个 tcl

命令：`grep -rn "PrintWriter\|forceMkdir\|create_ip\|get_ips" rtl_src | grep -v "^rtl_src/config"`

| tcl 文件 | emitter | `create_ip` 的 IP 本名 | 调用点（componentName） |
|---|---|---|---|
| `generateAddZero.tcl`     | `object AddSub.genTcl`                | c_addsub             | `conv/compute/Quan.scala:158`（"AddZero"） |
| `generatebiasAdd.tcl`     | `object AddSub.genTcl`                | c_addsub             | `conv/compute/Quan.scala:81`（"biasAdd"） |
| `generateaddAdd.tcl`      | `object AddSub.genTcl`                | c_addsub             | `shape/Add.scala:192`（"addAdd"） |
| `generateaddAdd64_64.tcl` | `object AddSub.genTcl`                | c_addsub             | `shape/Add.scala:147`（"addAdd64_64"） |
| `generateconcatAdd.tcl`   | `object AddSub.genTcl`                | c_addsub             | `shape/Concat.scala:91`（"concatAdd"） |
| `generateleakyAddZ3.tcl`  | `object AddSub.genTcl`                | c_addsub             | `conv/compute/activation/LeakyRelu.scala:150`（"leakyAddZ3"） |
| `generateleakySubZ3.tcl`  | `object AddSub.genTcl`                | c_addsub             | `conv/compute/activation/LeakyRelu.scala:27`（"leakySubZ3"） |
| `generateconv11DataCvt.tcl` | `object StreamDataWidthConvert.genTcl` | axis_dwidth_converter | `conv/dataGenerate/FeatureWidthConvert.scala:82`（"conv11DataCvt"） |

外加 `misc/TotalTcl.scala:7 genTotalTcl` —— 扫 `*.tcl` 拼成 `totalIpTcl.tcl` / `totalIpTclList.txt`
（被克隆自己的 `Npu.scala:186` / `top.scala:10` 调用；我们跑的是 `rtl_gen/GenNpu.scala`，不经过，
所以它不在那 8 个里，但一并停用）。

**「纯记账」还是「也在数据通路」——两个都成立，必须分开说：**

- `object AddSub.genTcl` / `object StreamDataWidthConvert.genTcl` **本身**是纯记账（只写 tcl）；
- 但它们所在的**类** `class AddSub` / `class StreamDataWidthConvert` 都 `extends BlackBox`，
  **在设计里被真实例化**（AddZero / addAdd / … / conv11DataCvt），**且 `gen/Npu.v` 里模块定义为 0**。
  ⇒ 按任务书 Step 2 的口径，这属于「emitter 也是被例化的 Xilinx BlackBox」那一支。**是真实问题。**

### 2. Step 2：怎么停的（override 清单 + 手法）

新增 3 个覆盖文件（每个都有克隆对应物，apply 脚本硬校验）：

- `port/override/wa/xip/math/AddSub.scala` —— `private def genTcl(...)` 函数体整体包在
  `/* B9-noop-begin ... B9-noop-end */` 里（与 B7/B8 同手法），**签名与可见性不变**。
- `port/override/wa/xip/axi/StreamDataWidthConvert.scala` —— 同上，`genTcl` 变 no-op。
- `port/override/misc/TotalTcl.scala` —— `def genTotalTcl` 函数体整体注释，**类名/构造签名/方法签名不变**
  （`Npu.scala:186` / `top.scala:10` 仍调用它，必须保持可编译）。

`bash port/apply_pango_port.sh` ⇒ `applied 8 override(s) into .../rtl_src`
（B5–B8 的 5 个 + 本次 3 个）。**无任何 public 签名被改，无 call site 需要编辑。**
（`FileUtils` / `filePath` / `java.io._` / `scala.io.Source` 变成未使用 import，仅告警，不影响编译。）

### 3. 真实问题（finding）：AddSub / StreamDataWidthConvert 仍是数据通路里的 Xilinx IP

实测（`gen/Npu.v`，把「例化行」与「模块定义」分开数）：

```
name           instances  definitions
AddZero              16        0
addAdd               16        0
addAdd64_64          16        0
biasAdd              16        0
concatAdd            16        0
conv11DataCvt         1        0
leakyAddZ3           16        0
leakySubZ3           16        0
------------------------------------
合计 = 16*7 + 1 = 113 处实例, 0 份定义
```

即它们是**悬空黑盒**：Xilinx 流程里靠 B9 刚停掉的 `create_ip` 生成 XCI 来补上这些模块体；
Pango 侧**没有任何东西会补**。

- **同类教训**：B7 笔记里讲过 —— 换掉 Mul 之后「体内那个 `mulWeight mulWeight_inst`（未定义模块）
  被彻底删掉，Pango 不再因缺模块而失败」。B7/B8 把 Mul/DSP 换成了真 SpinalHDL 模块
  （`gen/Npu.v` 里 `module scaleMul/concatMul/addMul/leakyReluMul/shapeCount1` **有定义**），
  但 **`AddSub`（c_addsub）与 `StreamDataWidthConvert`（axis_dwidth_converter）这两类**
  **不在任务书点名的四原语里，B5–B8 没碰** ⇒ 残留至今。
- **后果（要写进 B10 的输入）**：B10 的 `dev_map` 很可能因「找不到模块 `AddZero` / `biasAdd` / …」
  直接失败。要真上 Pango，得把这两个黑盒也像 B7/B8 那样换成行为级实现 —— 那是**一个新的移植任务**，
  **B9 范围内不修，只报**。
- **为什么 B9 的判据抓不到它**：`check_no_xilinx.sh` 按「Xilinx 原语/IP 的**本名**」判
  （`xpm_*` / `dsp_macro` / `mult_gen` / `blk_mem_gen` / `c_addsub` / `axis_dwidth_converter` /
  `create_ip` / `get_ips`）；而 SpinalHDL 对 BlackBox **只写实例、写的是 `componentName`**
  （`AddZero addZero_0 (...)`），**从不写 IP 本名**。所以**名字判据看不见它**。
  实测：把 8 个 `componentName` 也加进 pattern，判据立刻 FAIL（命中 **113**）。
  任务书 Step 2 括号里说「这时 check_no_xilinx.sh 应该 FAIL」——
  对「**名字含 IP 本名**的原语」（B5–B8 那四种）成立；对「**用 componentName 命名的黑盒**」不成立。
  这条口径记在这里，免得后人以为判据在骗人。

### 4. Step 3/4：闸门（命令与输出原文照抄）

```bash
$ bash port/apply_pango_port.sh          # applied 8 override(s)
$ rm -rf port/verilog                    # 清掉历史 tcl
$ (cd port; printf 'runMain GenNpu .../gen\nexit\n' | bash sbt.sh)   # => [success]
$ ls -la port/verilog/tcl   # => 目录不存在（连 port/verilog 都不存在）
$ ls -la port/verilog       # => absent
$ md5sum gen/Npu.v          # => ba916dcc59f47529537c2278dd3f6dba  (== 改动前)
$ bash tools/check_no_xilinx.sh gen
xilinx-residual hits: 0
RESULT: PASS
judge_exit=0
```

**负对照（证明判据非空转）**：临时目录放一个**真代码**含 `xpm_fifo_sync` 的 `.v`：

```bash
$ tmp=$(mktemp -d); printf 'module foo; xpm_fifo_sync u (.clk(c)); endmodule\n' > $tmp/residue.v
$ bash tools/check_no_xilinx.sh $tmp
HIT /tmp/.../residue.v
1:  xpm_fifo_sync u (.clk(c));
xilinx-residual hits: 1
RESULT: FAIL
neg_exit=1
```

**剥注释口径（判据不做假阳性）**：`gen/DspTop.v`（B7 的单 DSP 小装置产物）留了一行
`// B7: this used to be a Xilinx dsp_macro IP instance ...` —— 那是**移除记录**、不是残留。
判据先剥 `/* */` 与 `//` 再匹配，故不计命中；负对照证明剥注释后仍有区分度。

### 5. 未验证项 / 疑虑（写下来，别当已解决）

1. **AddSub / StreamDataWidthConvert 黑盒仍在数据通路**（第 3 节）——B9 **未修**。B10 的 `dev_map`
   会撞上；要么先在 B10 前补一个「AddSub Pango 化」任务，要么确认 dev_map 对悬空黑盒的容忍度。
2. **判据按名字判，天然抓不到「用 componentName 命名的黑盒」**。要真正把「无 Xilinx 残留」
   变成结构判据，应再加一条「实例化名 ⊆ 已定义模块名」（悬空黑盒检查）。本次未做。
3. **md5 不变 ⇒ 本次改动对网表零扰动**。这只说明「停 tcl 不影响网表」，
   **不构成**「AddSub 黑盒无害」的证据；两者是独立的事。
4. `misc/TotalTcl.scala` 的覆盖在本次 `GenNpu` 路径上**没有被执行到**（入口不调它），
   所以它的 no-op 只是「防未来回归 + 保编译」，没有生成物层面的对照。


---

## 2026-10-08 B9b：AddSub / StreamDataWidthConvert 行为化（清 113 个悬空实例；结构判据 + 数值交叉验证）

### 0. 一句话结论

B9 报的 finding（`class AddSub` = Xilinx `c_addsub`、`class StreamDataWidthConvert` =
Xilinx `axis_dwidth_converter`，**113 处实例 / 0 份模块定义**）已修：两类黑盒都改成
**行为级实现**（仍是 BlackBox + `setInlineVerilog`，与 B7/B8 同形状），

- `gen/Npu.v`：`defined modules: 64 | distinct instantiated: 63`，**悬空 0**（改前 56 / 63 / 113）；
- **8 个调用点一行未改**（`object XXX.apply` 签名逐字不变），实例端口名/方向/位宽逐字节相同
  （改前/改后 `biasAdd addSub (.A/.B/.S/.CLK)` 与 `conv11DataCvt dataCvt (.s_axis_*/.m_axis_*/.aclk/.aresetn)`
  连**行号都没变** —— 模块体是追加到文件尾部的）；
- `bash tools/check_no_xilinx.sh gen` ⇒ PASS/0；`port/verilog`（tcl 目录）**仍然不存在**；
- md5 `ba916dcc59f47529537c2278dd3f6dba` → **`fe303ee095a1592285af3c076c919817`**（确定性复跑不变）。

- **状态**：DONE
- **交付物**：`port/override/wa/xip/math/AddSub.scala`、`port/override/wa/xip/axi/StreamDataWidthConvert.scala`
  （均为**扩写**，原有 B9 no-op 注释全保留）、`rtl_test/AddSubTop.scala`、`rtl_test/DwcTop.scala`、
  `tools/check_addsub_latency.py`、`tools/check_dwc_latency.py`、**新增结构判据** `tools/check_dangling.py`、本节。
  数值交叉验证装置在 `gen/b9b/sim/crosscheck.py`（gitignored，**非交付物**，与 B8 §6 同性质）。

### 1. 两个 IP 的契约（逐条给 tcl 证据）

#### 1.1 `AddSub` ← `create_ip -name c_addsub -version 12.0`

| 契约 | 值 | 证据 |
|---|---|---|
| IO | `A`(in) / `B`(in) / `S`(out) / `CLK`(in)，`noIoPrefix` | 类定义 + 网表实例（`biasAdd addSub (.A(dataInTemp_0[47:0]) .B(...) .S(...) .CLK(clk))`） |
| 运算 | `S = A ± B`（静态） | tcl `CONFIG.Add_Mode {$ADD_MODE}`，`ADD_MODE ∈ {Add, Subtract}`；7 个调用点里只有 `leakySubZ3` 是 `Subtract` |
| 符号性 | `A_TYPE`/`B_TYPE` 各自 `signed`/`Unsigned` | tcl `CONFIG.A_Type`/`CONFIG.B_Type`；调用点：仅 `addAdd64_64` 是 signed/signed，其余 signed/Unsigned |
| 输出宽度 | `S_WIDTH = CONFIG.Out_Width`。**7 个配置全部 `S_WIDTH == max(A_WIDTH,B_WIDTH)`**，即比精确和/差**少 1 位** ⇒ 进位/借位被丢弃，`S = 全精度结果[S_WIDTH-1:0]`（模 2^S_WIDTH 补码） | tcl `CONFIG.Out_Width {$P_WIDTH}`；`Out_Width` 就是端口 S 的物理位宽，硬件只能丢 MSB、不可能"多"一位做饱和 |
| 流水 | **`CONFIG.Latency` = 顺序寄存器级数**，7 个调用点 = `1`(biasAdd/AddZero/leakySubZ3/leakyAddZ3)、`2`(addAdd/concatAdd)、`5`(addAdd64_64，源码写 `2 + 3`) | tcl `CONFIG.Latency {$PIPELINE_STAGE}` + 调用点实参。**旁证（延迟读数的自洽性）**：`LeakyRelu.scala` 用 `Delay(subOut, 3)` 去对齐 `Mul`（`PipeStages=3`）的输出，而 `subOut` 本身是 `AddSub ... Latency=1` 的输出 ⇒「Latency=N ⇒ N 个寄存器 ⇒ 输出晚 N 拍」这一读法与调用点的拍数对齐逻辑完全一致（若 c_addsub 实际是 N+1 拍，这里就会错 1 拍）。 |

IE：`CONFIG.CE {false}`（无 CE）、`CONFIG.Implementation {DSP48|Fabric}` 只影响映射资源、不影响功能。
**未采用的另一种读数**：把 `S` 理解为"饱和"。饱和只在 `Out_Width > max(A,B)` 时才可能与截断不同；
本设计 7 个配置全部 `Out_Width == max(A,B)`，故取截断（详见 §5 疑虑 2）。

#### 1.2 `StreamDataWidthConvert` ← `create_ip -name axis_dwidth_converter -version 1.1`

| 契约 | 值 | 证据 |
|---|---|---|
| IO | `s_axis_tdata/tvalid/tready` + `m_axis_tdata/tvalid/tready` + `aclk`/`aresetn` | 类定义（`setName` 过）+ 网表实例 `conv11DataCvt dataCvt (... s_axis_tdata(sData_payload[127:0]) ... m_axis_tdata(...[1023:0]) ...)` |
| 方向/比例 | **1:8 升宽（narrow→wide）**，S=128、M=1024 | 调用点 `FeatureWidthConvert.scala:65,66`：`S_DATA_WIDTH = COMPUTE_CHANNEL_NUM*8 = 128`、`M_DATA_WIDTH = 8*S_DATA_WIDTH = 1024`；tcl `CONFIG.S_TDATA_NUM_BYTES {16}` / `CONFIG.M_TDATA_NUM_BYTES {128}`（128/8=16、1024/8=128 ⇔ S<M，只能是升宽） |
| 旁带 | 无 tkeep/tlast，**只有 tdata/tvalid/tready** | tcl `CONFIG.HAS_MI_TKEEP {0}` + 类 IO（blackbox 没有 keep/last 端口） |
| **流水** | **tcl 里没有任何延迟键** ⇒ **IP 固有拍数不可从 tcl 推出**（该 IP 是同步流转换器、内部有寄存器，但 `set_property -dict [list ...]` 里只有 `S_TDATA_NUM_BYTES`/`M_TDATA_NUM_BYTES`/`HAS_MI_TKEEP` 三个键） | `object StreamDataWidthConvert.genTcl` 原文（B9 已注释，`rtl_src/` 里是活的） |
| 打包顺序 | **最先被接收的窄拍落在宽字低位**（`m_axis_tdata[127:0]`） | 1) AXI4-Stream 的 byte-lane 约定（TDATA 字节序 = 地址递增序 ⇒ 先到的窄拍在低字节道）；2) 调用点 `FeatureWidthConvert.scala:88` 把 `mData.payload` `subdivideIn(8 slices)(i)` 当作第 i 条通道，slice 0 = `[127:0]` = 最低位 ⇒ beat 0 必须落 slice 0。**这条不是从 tcl 推出的**，是从消费方 + AXI 约定推出的（§5 疑虑 1） |

**所以本任务的"延迟"只有 AddSub 是从 tcl 读出来的确切数字**；DWC 的"8 级"是**结构上必须的存储级数**
（升宽 1:8 至少要把 8 个窄拍收齐才能拼出一个宽拍），**不是** Xilinx IP 的固有拍数（那个无从得知）。

### 2. 实现（都是"仍是 BlackBox + `setInlineVerilog`"，与 B7/B8 同形状）

#### 2.1 AddSub（寄存器名 `addPipe_0 … addPipe_{N-1}`，N = `CONFIG.Latency`）

```verilog
module biasAdd (                     // 例：Quan.scala:81  48/48/48 signed/unsigned, Latency=1, Add
  input  wire [47:0] A,
  input  wire [47:0] B,
  output wire [47:0] S,
  input  wire CLK
);
  wire signed [48:0] aExt;  assign aExt = $signed(A);            // signed   → 保持二补数
  wire signed [48:0] bExt;  assign bExt = $signed({1'b0, B});    // Unsigned → 零扩展 1 位后当有符号
  wire signed [48:0] addSubSum;  assign addSubSum = aExt + bExt; // Subtract 时是 aExt - bExt
  reg  signed [48:0] addPipe_0;
  always @(posedge CLK) begin addPipe_0 <= addSubSum; end
  assign S = addPipe_0[47:0];                                    // Out_Width 截断（丢进位）
endmodule
```

- 两个操作数先各自抬成**显式有符号**再加减：漏掉 `$signed` 时 `signed ± unsigned` 会被 Verilog 按**无符号**算
  （B8 同款坑）。这里在数值上**恰好不可区分**（§4 NEG-b / §5 疑虑 2），但仍按契约写对，
  避免将来出现"结果被加宽"的配置时静默出错。
- 中间宽度 = `max(A_WIDTH,B_WIDTH)+1`（精确装得下），`S` 在输出端取 `[S_WIDTH-1:0]`。
- `PIPELINE_STAGE=0`（= `Latency=0` 组合）也支持（此时不发寄存器、直接 assign）。
- 类构造参数新增 `pipelineStage` / `addMode`（都有默认值）；`object AddSub.apply` **签名一字未改**，
  只是把原来"只喂给 tcl"的 `PIPELINE_STAGE`/`ADD_MODE` 同时喂给行为模型。
- `require`：`PIPELINE_STAGE >= 0`、`S_WIDTH <= FULL_WIDTH`、`Add_Mode ∈ {Add,Subtract}` ⇒ 越界/错配置**展开期报错**，不静默。

#### 2.2 StreamDataWidthConvert（槽位寄存器 `dwcPipe_0 … dwcPipe_{N-1}`，N = 8；另有 `dwcCount`）

```verilog
module conv11DataCvt (
  input  wire [127:0]  s_axis_tdata, input wire s_axis_tvalid, output wire s_axis_tready,
  output wire [1023:0] m_axis_tdata, output wire m_axis_tvalid, input wire m_axis_tready,
  input  wire aclk, input wire aresetn
);
  reg  [127:0] dwcPipe_0 .. dwcPipe_7;   // slot k = 本包第 k 个窄拍（slot 0 = 最先到的拍）
  reg  [3:0]   dwcCount;
  assign dwcFull   = (dwcCount == 4'd8);
  assign dwcDrain  = dwcFull & m_axis_tready;
  assign dwcAccept = s_axis_tvalid & s_axis_tready;
  assign dwcWrIdx  = dwcDrain ? 4'd0 : dwcCount;      // 取走那一拍同时进新拍 ⇒ 新拍落 slot 0
  assign m_axis_tvalid = dwcFull;
  assign s_axis_tready = (~dwcFull) | m_axis_tready;  // 满且下游不取 ⇒ 真背压
  always @(posedge aclk) begin ... 按 dwcWrIdx 索引写槽；drain 时 dwcCount<=accept?1:0 ... end
  assign dwcData = {dwcPipe_7, ..., dwcPipe_1, dwcPipe_0};  // 递减 ⇒ slot 0 在低位
  assign m_axis_tdata = dwcData[1023:0];
endmodule
```

**这里踩过一个真坑（记下来）**：第一版用"有效位移位串 + 每拍无脑移位"。它在**背靠背**
（drain 与 accept 同一拍）时会把上一包的 7 个旧槽留在原地，只把新拍塞进最高槽 ⇒ 输出一个
"1 个新拍 + 7 个旧拍"的**串包字**，而 Verilog 不会报错。改成"**按 `dwcWrIdx` 索引写入 + drain 时把
写指针复位到 0**"后，背靠背第二包从 slot 0 开始重新填满，包边界保持。这个 bug 是**先被推理发现、
再由 §4 的 iverilog 握手用例确认修好**的（`transferred=4`、`errors=0`）。

- `require`：`mDataWidth > sDataWidth` 且整除（**只实现升宽**；本设计不存在降宽配置，真出现会展开期报错）。
- 类构造参数新增 `dwcStages`（默认 0 = 自动取比例 R）、`newestAtMsb`（默认 false，**仅供判据负对照**）；
  `object StreamDataWidthConvert.apply` **签名一字未改**、生产路径走默认值。
- 小坑：`class` 里 `import spinal.lib._` 把 `spinal.lib.math` 带进作用域，`math.max(...)` 会被解析成包名
  （实测编译错：`object max is not a member of package spinal.lib.math`）⇒ 必须写 `scala.math.max`。

#### 2.3 两个 `object ...genTcl` 仍是 no-op（B9 成果保留）

函数体依旧整体包在 `/* B9-noop-begin … B9-noop-end */` 里，签名与可见性不变。
**B9 停 tcl（不再让 Vivado 去生成 IP）+ B9b 行为化（模块体补上）** 合起来才算把这两类 Xilinx IP 从设计里去掉。

### 3. 判据（交付物）与正负对照

- `tools/check_addsub_latency.py <v> <期望级数> [模块名] [add|sub]`：数 `addPipe_<n>` 索引
  （必须 == `0..N-1` 连续），可选点名模块（用于真网表）、可选校验加还是减。
- `tools/check_dwc_latency.py <v> <期望级数> [S] [M] [模块名]`：① 数 `dwcPipe_<n>` 索引；
  ② 端口位宽必须 `s_axis_tdata[S-1:0]`/`m_axis_tdata[M-1:0]` 且 `S<M`（方向=升宽）；
  ③ 驱动 `dwcData` 的 concat 里索引必须**严格递减** `N-1..0`（= 最先到的拍在低位）。三项互相独立。
- `tools/check_dangling.py <v>...`（**新增，结构判据**）：解析出「已定义模块集合」与「被例化的模块名集合」，
  `被例化 ∉ 已定义` 即悬空 ⇒ FAIL。**为什么需要它**：`check_no_xilinx.sh` 按 **IP 本名**判，
  而 SpinalHDL 对 BlackBox 只写**实例**、模块名是 `componentName`（`AddZero addZero_0 (...)`），
  **从不写 `c_addsub`** ⇒ 名字判据**结构上看不见**悬空黑盒（B9 §3 已记这条口径）。

#### 3.1 `check_dangling.py` 非空转证明（改前 / 改后 / 合成负对照）

```
# 改前（B9 结束时的 gen/Npu.v，改动前实测原文）
$ python tools/check_dangling.py gen/Npu.v
defined modules: 56 | distinct instantiated: 63
--- INSTANTIATED BUT UNDEFINED (dangling) ---
  AddZero                      x16
  addAdd                       x16
  addAdd64_64                  x16
  biasAdd                      x16
  concatAdd                    x16
  conv11DataCvt                x1
  leakyAddZ3                   x16
  leakySubZ3                   x16
total dangling instances: 113
RESULT: FAIL        (exit 1)
# 改后
$ python tools/check_dangling.py gen/Npu.v
defined modules: 64 | distinct instantiated: 63
--- no dangling instances ---
total dangling instances: 0
RESULT: PASS        (exit 0)
# 合成负对照（临时文件：真代码里的一个未定义例化，跑完即删）
$ python tools/check_dangling.py <tmp>/residue.v
defined modules: 2 | distinct instantiated: 1
--- INSTANTIATED BUT UNDEFINED (dangling) ---
  somethingUndefined           x1
total dangling instances: 1
RESULT: FAIL        (exit 1)
```

改前的 **113 / 8 个名字**与 B9 §3 独立数出来的**完全一致**（56/63 也一样）⇒ 解析器口径与人工口径对齐，
不是自己编的数字。

#### 3.2 AddSub 控制（`rtl_test/AddSubTop.scala` + `Test/runMain AddSubGen <dir> aW bW sW aType bType stages op`）

```
# 正对照：LeakyRelu.scala:27 的真实配置 16 8 16 s u 1 sub
$ python tools/check_addsub_latency.py gen/b9b/as1sub/AddSubTop.v 1
expected_stages=1 detected_stages=1 indices=[0]           RESULT: PASS   pos_exit=0
$ python tools/check_addsub_latency.py gen/b9b/as1sub/AddSubTop.v 2
expected_stages=2 detected_stages=1 indices=[0]           RESULT: FAIL   neg_stage_exit=1
$ python tools/check_addsub_latency.py gen/b9b/as1sub/AddSubTop.v 1 addsub add
expected_stages=1 detected_stages=1 indices=[0]
expected_op=add found=False opposite_op_present=True      RESULT: FAIL   neg_op_exit=1
# 级数生成物的正负对照（Add.scala:147 的真实配置 64 64 64 s s 5 add）
$ python tools/check_addsub_latency.py gen/b9b/as5add/AddSubTop.v 5
expected_stages=5 detected_stages=5 indices=[0,1,2,3,4]   RESULT: PASS   st5_exit=0
$ python tools/check_addsub_latency.py gen/b9b/as4add/AddSubTop.v 4   # 真做 4 级、按 4 判
expected_stages=4 detected_stages=4 indices=[0,1,2,3]     RESULT: PASS   st4_exit=0
$ python tools/check_addsub_latency.py gen/b9b/as4add/AddSubTop.v 5   # 真做 4 级、按 5 判
expected_stages=5 detected_stages=4 indices=[0,1,2,3]     RESULT: FAIL   st4_as5_exit=1
```

**真网表上逐个点名（7 个模块全 PASS / exit 0）**：

```
AddZero      expected_stages=1 detected_stages=1  op=add found -> PASS
addAdd       expected_stages=2 detected_stages=2  op=add found -> PASS
addAdd64_64  expected_stages=5 detected_stages=5  op=add found -> PASS
biasAdd      expected_stages=1 detected_stages=1  op=add found -> PASS
concatAdd    expected_stages=2 detected_stages=2  op=add found -> PASS
leakyAddZ3   expected_stages=1 detected_stages=1  op=add found -> PASS
leakySubZ3   expected_stages=1 detected_stages=1  op=sub found -> PASS
```

#### 3.3 DWC 控制（`rtl_test/DwcTop.scala` + `Test/runMain DwcGen <dir> sW mW stages reverse`）

```
$ python tools/check_dwc_latency.py gen/b9b/dwc8/DwcTop.v 8 128 1024       # 生产配置 1:8
expected_stages=8 detected_stages=8 indices=[0..7]
narrow_to_wide=True  packing_order=[7,6,5,4,3,2,1,0]      RESULT: PASS   dwc_pos_exit=0
$ python tools/check_dwc_latency.py gen/b9b/dwc7/DwcTop.v 7 128 1024       # 真做 7 级、按 7 判
expected_stages=7 detected_stages=7 indices=[0..6]        RESULT: PASS   dwc7_exit=0
$ python tools/check_dwc_latency.py gen/b9b/dwc7/DwcTop.v 8 128 1024       # 真做 7 级、按 8 判
expected_stages=8 detected_stages=7
packing_order=[6,5,4,3,2,1,0] (need [7..0])               RESULT: FAIL   dwc7_as8_exit=1
$ python tools/check_dwc_latency.py gen/b9b/dwc8rev/DwcTop.v 8 128 1024    # 打包顺序反向
expected_stages=8 detected_stages=8
packing_order=[0,1,2,3,4,5,6,7] (need [7..0])             RESULT: FAIL   dwc_rev_exit=1
$ python tools/check_dwc_latency.py gen/b9b/dwc8/DwcTop.v 8 1024 128       # 方向判错
expected_s_axis_tdata=1024 declared=128 narrow_to_wide=False  RESULT: FAIL  dwc_dir_exit=1
```

**真网表**：`python tools/check_dwc_latency.py gen/Npu.v 8 128 1024 conv11DataCvt` ⇒ PASS（exit 0），
三项（级数/方向/打包顺序）都过。

### 4. 数值 / 握手交叉验证（**临时装置，非交付物**；`gen/b9b/sim/crosscheck.py`，iverilog -g2012 + vvp）

结构性判据证不了数值，所以**额外**做了这一层（与 B8 §6 同性质，保留在 gitignored 目录里可复跑）：

```
1) AddSub（模块体从 gen/Npu.v 抠出；每配置 56~60 个向量：边界 lo/hi/±1/0/255/256 + 随机）
AddZero      Quan.scala:158       lat=1 16/8/16 s/u ADD vectors=60 errors=0 -> PASS
biasAdd      Quan.scala:81        lat=1 48/48/48 s/u ADD vectors=60 errors=0 -> PASS
addAdd       Add.scala:192        lat=2 32/32/32 s/u ADD vectors=59 errors=0 -> PASS
concatAdd    Concat.scala:91      lat=2 32/32/32 s/u ADD vectors=59 errors=0 -> PASS
addAdd64_64  Add.scala:147        lat=5 64/64/64 s/s ADD vectors=56 errors=0 -> PASS
leakyAddZ3   LeakyRelu.scala:150  lat=1 16/8/16 s/u ADD vectors=60 errors=0 -> PASS
leakySubZ3   LeakyRelu.scala:27   lat=1 16/8/16 s/u SUB vectors=60 errors=0 -> PASS
   每个配置再打两条负对照：
     NEG-a（期望按 L-1 拍算，即少一个寄存器）：有差别的向量数 = 51~59 ⇒ 数值判据对拍数敏感
     NEG-b（把有符号 A 当无符号算）：两种期望逐向量完全相同（见 §5 疑虑 2）
2) conv11DataCvt（1:8 升宽；复位 + s_valid 恒 1 + 下游停 3 拍后放行；激励/监视都在 posedge 采样）
POS (模块体取真网表)       transferred=4 beats=37 first_mvalid=16 errors=0 -> PASS
NEG (打包顺序反的变异体)   transferred=4 beats=37 first_mvalid=16 errors=8 -> FAIL（期望 FAIL）
```

即：**这层不仅证了算术**（含唯一的 Subtract 路径、含 5 级 64/64 的路径），**也顺带在数值上确认了拍数**
（`first_mvalid` 必须恰好 = 第 8 个窄拍被接收的下一拍；对齐差 1 拍会立刻全错），
以及 DWC 的**打包顺序、停流时数据保持、真背压、背靠背不串包**（4 个包全对）。

### 5. 未验证项 / 疑虑（写下来，别当已解决）

1. **DWC 的"8 级"不是从 tcl 读出来的，也不是 IP 的固有拍数。** tcl 里**没有延迟键**，所以 Xilinx
   `axis_dwidth_converter` 自己的流水深度**无从得知**（它内部还有一个输出寄存器，实际拍数可能 ≥8）。
   本实现主张的是：**IO 契约逐字不变 + AXI 打包顺序正确 + 结构上必须的 8 级存储 + 背靠背/背压行为**，
   **不主张与 IP 逐拍等价**。整链路的拍数对齐若敏感，需拿 Xilinx 仿真核对（M0 做不到 —— 没有 IP）。
2. **`S = 全精度结果[S_WIDTH-1:0]`（截断）这一读数未与 IP 对照。** 依据是 `Out_Width` 的物理含义
   （端口 S 只有 S_WIDTH 位，硬件只能丢 MSB）+ 7 个配置全是 `Out_Width == max(A,B)`（装不下进位）。
   另一个有意思的**诚实结论**：这些位宽下「A 按有符号 / 按无符号」**在数值上不可区分** ——
   因为 `S_WIDTH = max(A,B)` 只保留低位，而二补数加减是模 2^N 的（§4 的 NEG-b 逐向量验证了这一点）。
   也就是说本实现里的 `$signed` 写法**当前不产生可观测差异**；它只在"结果被加宽"时才重要，
   属于"按契约写对、防未来配置"的防御性写法。若哪天出现 `S_WIDTH > max(A,B)` 的调用点，**必须重做这条读数**。
3. **`class AddSub` 的符号性只在类/bundle 层面体现**，生成物端口仍是 `wire [N-1:0]`（与 B8 的 Mul 同）。
   调用点把 S 当 `SInt`/`UInt` 用，位型不变；本判据不校验"下游怎么解释 S"。
4. **Pango 会不会把 `aExt ± bExt`、以及 DWIDTH 的宽 concat + 索引写 mux 映射得合理没综合过**
   （B10 的 `dev_map` 才回答）。资源上要有心理准备：AddSub 共 113 个实例（16×7+1），
   其中 `biasAdd` 是 48 位×16、`addAdd64_64` 是 64 位×16；DWC 是 8×128 位寄存器 + 8 个 128 位比较器。
5. **B10 的前置条件已满足但未验证**：本节判据证明"网表里没有悬空模块"，**不等于**"Pango `dev_map` 一定过"
   —— 还有别的失败模式（资源、时序、Pango 不支持的写法）。这层留给 B10 实测。
6. `check_no_xilinx.sh` 仍然只判名字；**结构口径由 `check_dangling.py` 补**，两条都 PASS 才算"无残留"。
   B9 §5 疑虑 2 提到的"应再加一条结构判据"到此关闭。
