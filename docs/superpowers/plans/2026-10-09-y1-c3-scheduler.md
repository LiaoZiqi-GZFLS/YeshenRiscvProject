# Y1 · C3 实施计划：层调度器（DDR 描述符表 + 行流式融合缓冲 + 旁路算子）

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 C2 的「主机寄存器层 + DDR 块拷贝主口」扩成**层调度器** —— 主机在 DDR 写一张**描述符表**（整帧算子序列，含融合单元与旁路算子）、发一条命令，NPU 自己走表把整帧跑完，**帧末给一次中断**。

**Architecture:** 三块新硬件 + 一处主口扩展：① **描述符解析器**（取表 32 B/项 → 译码 → 校验）；② **行流式融合缓冲**（3 行窗口，`Mem` 结构 ⇒ 落 DRM，见 C3.0 报告）；③ **单元序列状态机**（按表推进 + 旁路算子编排点）；④ `DdrMaster` 加**流式模式**（RD/WR，可只读/只写）并把长度粒度放宽到 **32 B**（C2 已把这条写在注释里："放宽到 32 B 粒度是后续 C3 的事"）。LSTM 数值判据用 8→8 的既有 `Conv3x3Slice`（它已被 B4 验证），片上只搬 3 行窗口、不搬整张。

**Tech Stack:** Scala 2.12.18 / SpinalHDL 1.15.0 + sbt（本机 Coursier 的 `sbt.bat`，声明 1.10.0）；iverilog 13.0；PDS 2025.2 `dev_map`；`scripts/check_addr_map.py`（地址台账唯一闸门）；Python 3（`deps` venv）。

**设计依据：** `docs/superpowers/specs/2026-10-09-y1-c3-scheduler-design.md`（冻结参数、描述符语义、判据 S1–S6、风险 R1–R7、旁路算子裁决）

---

## 全局约定（每个 Task 都适用）

- **不上板**：本计划全部离线（仿真 + 综合/映射）。上板时机由用户给。
- **只读资产**：`third_party/**`、`y1/tools/ddr_traffic.py`（`fusion_buffer.py` 依赖它并 `assert len(units)==33`，**一个字都不改**）、`src/soc/DDR3Bridge.scala`、`src/soc/CDCQueue.scala` 是**输入约束**，不是待改对象。C3 若要"把旁路算子流量补进模型"（R6），**新建**脚本去 import 它，不改它。
- **提交**（本机无 git 身份，**不 push**，**绝不改 git config**）：
  ```bash
  GIT_AUTHOR_NAME="LiaoZiqi-GZFLS" GIT_AUTHOR_EMAIL="LiaoZiqi-GZFLS@users.noreply.github.com" \
  GIT_COMMITTER_NAME="LiaoZiqi-GZFLS" GIT_COMMITTER_EMAIL="LiaoZiqi-GZFLS@users.noreply.github.com" \
  git commit -m "<msg>"
  ```
- **判据必须带正负对照**（已知-good/已知-bad 两份输入，一绿一红）；**产物记指纹**（md5/字节数/行数）；**判据钉死在生成参数上时不匹配必须"响亮失败"**（Y1 已吃过 `WIDTH=640` 喂 `+IW=16` 的静默 `MISMATCH=2013`）。
- **生成器必须 `headerWithDate=false` 且 `headerWithRepoHash=false`**（否则头里嵌仓库 HEAD，指纹跨 commit 必变）。
- **sbt 走 stdin**：`printf '<cmd>\nexit\n' | bash sbt.sh`（`sbt.bat` 会吞掉带引号的参数）。
- **脚本打印非 ASCII 必须** `sys.stdout.reconfigure(errors="replace")` 或只输出 ASCII。
- **闸门退出码约定（沿用 Y1 既有 8 个闸门）**：`0` 过 / `1` 不符或仿真失败 / `2` 负对照没发火（闸门自身不可信）。

### 本档的两条**边界决定**（写进实现，评审时要看得见）

1. **权重不进描述符（8 个字已用满）。** 依据 `2026-10-08` Y1 spec §2：**整网权重 ≤ 50.3 KB 常驻片上**、无每层重载。所以 **C3 的数值判据（S2/S3/S4）用既有的 `we/waddr/wdin` 权重装载口带外预载**，描述符只承载**激活搬运 + 算子序**。"逐单元权重指针 / 与表同序的权重视图"由 **C4/M2 的转换器**决定（spec R3）。
   **⚠ 记为 spec 待补项**：冻结的 8 字格式里**没有权重指针**；本计划不改格式，把它作为 C4/M2 的开口项。若评审要求现在补，走 spec 修订（加第 9 个字或重排 w3 的高 16 位）。
2. **C3 只支持 8→8 的卷积单元**（`Conv3x3Slice` 的 `require(C_IN==8 && C_OUT==8)`）。C=16/32/64 的宽通道靠**多趟复用**（Y1 spec 已如此约定），属 C4。所有 S2/S3/S4 判据用 8→8、小几何（见各 Task）。

---

## 文件结构

```
VexiiYeshenLinux/
├── y1/
│   ├── rtl/
│   │   ├── DdrMaster.scala        # 【改】加 mode(COPY/RD/WR) + 流式端口 + 32 B 粒度
│   │   ├── DescDefs.scala         # 【新】描述符位打包常量 + 纯组合译码（单一真源）
│   │   ├── DescFetch.scala        # 【新】用 DdrMaster(RD) 取一个 32 B 描述符 → 8 个寄存器
│   │   ├── FusionBuf.scala        # 【新】3 行窗口 RAM（Mem 结构 ⇒ DRM）
│   │   ├── MaxPoolUnit.scala      # 【新】2x2/stride2 max（int8，逐点）
│   │   ├── ResizeUnit.scala       # 【新】x2 最近邻（int8，逐点）
│   │   ├── AddUnit.scala          # 【新】逐元素加 + clamp
│   │   ├── SigmoidUnit.scala      # 【新】int8 查表 sigmoid（定点口径冻结在文件头）
│   │   ├── UnitExec.scala         # 【新】单单元执行器（DDR→[FusionBuf]→Conv3x3Slice→DDR）
│   │   ├── LayerSched.scala       # 【新】单元序列 FSM（走表 + 旁路编排 + 帧末一次中断）
│   │   ├── HostRegs.scala         # 【改】加 DESC_ADDR(0x34) / DESC_COUNT(0x38)
│   │   └── NpuTop.scala           # 【改】例化 LayerSched，接事件/IRQ
│   ├── rtl_test/
│   │   ├── DescGen.scala  DescTb.v
│   │   ├── FusionBufGen.scala  FusionBufTb.v
│   │   ├── BypassGen.scala  BypassTb.v
│   │   ├── UnitExecGen.scala  UnitExecTb.v
│   │   ├── LayerSchedGen.scala  LayerSchedTb.v
│   │   └── (AxiMemModel.v / NpuTopTb.v 复用 C2 的，必要时加参数)
│   ├── tools/
│   │   ├── desc_table.py          # 【新】描述符打包/解包/校验（= C4/M2 的机器可读契约）
│   │   ├── bypass_traffic.py      # 【新】R6：把旁路算子流量补进流量模型（import ddr_traffic，不改它）
│   │   ├── bypass_ref.py          # 【新】MaxPool/Resize/Add/Sigmoid 的 Python 参考
│   │   ├── conv_unit_ref.py       # 【新】8→8 单/融合单元的 Python 参考（复用 mac_ref）
│   │   ├── run_desc_ab.sh  run_fusionbuf_ab.sh  run_bypass_ab.sh
│   │   ├── run_unitexec_ab.sh  run_sched_ab.sh  run_ddrmaster32_ab.sh
│   │   └── run_ddrread_ab.sh / run_ddrwrite_ab.sh / run_ddrcopy_ab.sh（回归，不改）
│   ├── pds/devmap_c3.tcl          # 【新】含 FusionBuf/旁路/调度器的 dev_map
│   └── reports/
│       ├── c3_descriptor_format.md   # 【新】冻结格式（C4/M2 契约）
│       ├── c3_traffic_full.md        # 【新】R6 补充后的流量模型
│       └── c3_scheduler.md           # 【新】C3 结论（S1–S6 + 缺口）
```

---

### Task C3.1: 前置基线 + R6 携带项（旁路算子流量补进模型，离线）

**为什么先做**：spec R6 明确指出 C0 的流量模型是**下界**（只计 Conv 的激活读写，不含旁路算子自身的激活 IO）⇒ 21.94 fps 会打折。这是**最便宜的离线补充**，且它输出的"整帧真流量"决定后面 S4 的判据口径。同时给 C3 立一条"before"基线（C3 要改 `DdrMaster.scala`，C2 的字节级闸门必须回归）。

**Files:**
- Create: `y1/tools/bypass_traffic.py`
- Create: `y1/reports/c3_traffic_full.md`
- Create: `y1/reports/c3_baseline.txt`

- [ ] **Step 1: 记录 C3 的 before 基线（C2 闸门全绿 + 网表指纹）**

```bash
cd /d/code/PDS/VexiiYeshenLinux/y1
for g in run_ddrread_ab run_ddrwrite_ab run_ddrcopy_ab run_hostregs_ab run_nputop_ab; do
  bash tools/$g.sh >/dev/null 2>&1; echo "$g=$?"
done | tee ../y1/reports/c3_baseline.txt
md5sum gen/DdrMaster.v gen/NpuTop.v >> ../y1/reports/c3_baseline.txt
cat ../y1/reports/c3_baseline.txt
```
Expected: 五个 `=0`，两个 md5 落盘。**若本来就红，先如实报告并停下**（不能把别人的红当我的 before）。

- [ ] **Step 2: 写失败判据（先红）** —— `bypass_traffic.py` 的骨架 + 自检

期望行为：`python tools/bypass_traffic.py <yunet.onnx>` 打印
```
UNITS_BASE=33 BASE_BYTES=12576000
BYPASS_OPS maxpool=4 resize=2 add=2 sigmoid=6
BYPASS_BYTES=<x>
TOTAL_BYTES=<base+y> FPS_AT_275_9MBps=<z>
SELFTEST_BYPASS_OFF=12576000
```
其中 `SELFTEST_BYPASS_OFF` 是 `--no-bypass` 档，**必须逐字等于 `BASE_BYTES`**（正向证明"补进去的确实是旁路那部分"）。
先写一个只打印 `TOTAL_BYTES=0` 的桩，跑它，确认打印不符 ⇒ **判据先红**。

- [ ] **Step 2b: 实现** —— 逻辑（**只读** `ddr_traffic`，不改它）：

```python
# y1/tools/bypass_traffic.py
import sys, importlib.util
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent))
import ddr_traffic as dt                      # 只读：不改它一个字节

# 旁路算子的激活字节 = 它的输入张量字节 + 输出张量字节（int8：元素数 == 字节数）
BYPASS_TYPES = {"MaxPool": "maxpool", "Resize": "resize", "Add": "add", "Sigmoid": "sigmoid"}

def bypass_bytes(gv):
    tot = {}
    for n in gv.nodes:
        k = n.op_type
        if k in BYPASS_TYPES:
            # 输入/输出形状由 dt.GraphView.shape_of 统一取（与 ddr_traffic 同口径）
            binary = sum(dt.act_bytes(gv, t) for t in n.input if gv.shape_of(t))
            bout   = sum(dt.act_bytes(gv, t) for t in n.output)
            tot[k] = tot.get(k, 0) + binary + bout
    return tot
```
（`dt.act_bytes` / `dt.GraphView.shape_of` 若在 `ddr_traffic` 里是私有名，**照它的实际名字取**：先 `grep -n "def .*shape_of\|def .*act_bytes" y1/tools/ddr_traffic.py` 再写。若两者都不存在，就在本脚本里用 `onnx.shape_inference` 自算，**不碰 ddr_traffic**。）

- [ ] **Step 3: 跑 + 写报告 `c3_traffic_full.md`**

```bash
cd /d/code/PDS/VexiiYeshenLinux/y1
PYTHONIOENCODING=utf-8 PYTHONPATH='../third_party/yunet/deps' \
  /d/code/PDS/NaxYeshenLinux/sim/reglogs/lxvenv/Scripts/python.exe \
  tools/bypass_traffic.py ../third_party/yunet/yunet.onnx | tee ../y1/reports/c3_traffic_full.txt
python tools/bypass_traffic.py ../third_party/yunet/yunet.onnx --no-bypass
```
Expected: `BYPASS_OPS maxpool=4 resize=2 add=2 sigmoid=6`（与 spec §8 裁决的四个算子计数**逐字一致**）；`--no-bypass` 档 `12576000` 逐字等于 `BASE_BYTES`。

报告 `c3_traffic_full.md` 必须写清：**基础 12.576 MB 是下界**；补进旁路后 `TOTAL_BYTES`；对应 fps；**口径声明**（仍是不含 12 个头张量后处理的下界）；以及"S4 的判据用哪个数"。

- [ ] **Step 4: 提交**

```bash
cd /d/code/PDS/VexiiYeshenLinux
git add y1/tools/bypass_traffic.py y1/reports/c3_traffic_full.md y1/reports/c3_traffic_full.txt y1/reports/c3_baseline.txt
GIT_AUTHOR_NAME="LiaoZiqi-GZFLS" GIT_AUTHOR_EMAIL="LiaoZiqi-GZFLS@users.noreply.github.com" \
GIT_COMMITTER_NAME="LiaoZiqi-GZFLS" GIT_COMMITTER_EMAIL="LiaoZiqi-GZFLS@users.noreply.github.com" \
git commit -m "feat(y1-c3): R6 携带项 —— 旁路算子流量补进模型（基础 12.576 MB 是下界）+ C3 before 基线"
```

---

### Task C3.2: 冻结描述符位打包（Python 契约 + 报告）—— **C4/M2 的机器可读契约**

**为什么**：spec §3 冻结了**语义**、把**位打包留给计划**。这一任务就是那个打包，而且 `desc_table.py` 同时是**给 C4/M2 的单一真源**（R3 的落实）。RTL 侧的 `DescDefs.scala`（C3.4）必须与它逐字段一致 —— 两处用**同一组测试向量**交叉对账。

**Files:**
- Create: `y1/tools/desc_table.py`
- Create: `y1/reports/c3_descriptor_format.md`

- [ ] **Step 1: 冻结位打包（写进 `desc_table.py` 的模块 docstring，逐字）**

```
每项 8 个 32-bit 小端字（= 32 B）：
  w0 : [7:0]=TYPE  [15:8]=FLAGS  [31:16]=0
  w1 : [15:0]=IMG_W [31:16]=IMG_H
  w2 : [15:0]=C_IN  [31:16]=C_OUT
  w3 : [7:0]=GROUP  [11:8]=STRIDE [15:12]=PAD [31:16]=0
  w4 : [31:0]=SRC_ADDR
  w5 : [31:0]=DST_ADDR
  w6 : [31:0]=IN_BYTES
  w7 : [7:0]=QUANT_SHIFT [15:8]=LAYER_ID [31:16]=0

TYPE : 0x01 conv3x3 | 0x02 conv1x1 | 0x03 depthwise | 0x10 maxpool
     | 0x11 resize | 0x12 concat | 0x13 add | 0x14 sigmoid | 0xFF 哨兵
FLAGS: bit0=OUT_TO_DDR   (0 ⇒ 输出留给下一单元 = 融合单元的头)
       bit1=IN_FROM_PREV (1 ⇒ 输入取上一单元输出 = 融合单元的尾)
       融合单元 = 一对相邻项 (bit0=0, 且 bit1=0) 紧跟 (bit1=1)；它们之间不出现 DDR 中间张量
       bits[7:2] 保留 = 0
```

- [ ] **Step 2: 写失败判据（先红）** —— `desc_table.py` 的 API 与自检

API（冻结）：
```python
pack(d: dict) -> bytes            # 32 B（8 个小端字）
unpack(b: bytes) -> dict          # 逆
pack_table(descs: list) -> bytes  # 末尾自动追加哨兵项
validate(descs, desc_count, ddr_bytes) -> None | raise DescError()
```
`python tools/desc_table.py --selftest` 的判据（**四条，缺一不可**）：
1. **正向**：从 `ddr_traffic`（只读）取 `fuse_both` 的 33 个单元 + 4 类旁路算子，构表 → `pack` → `unpack` → **逐字段等于**原表（`ROUNDTRIP_BAD=0`）；
2. **负对照 A**（打包器自检）：把某项 `w6` 翻一个 bit 再 `unpack`，断言 `IN_BYTES` **变了**（证明打包不是橡皮图章）；
3. **负对照 B**（非法 TYPE）：把某项 TYPE 设成 `0x77` ⇒ `validate` 必须抛 `DescError`；
4. **负对照 C**（COUNT/哨兵不符）：`desc_count = len(descs)+1` ⇒ `validate` 必须抛。
先写空实现跑，确认 4 条全红。

- [ ] **Step 3: 实现**（含 `validate` 的完整规则；这些就是 S6 的 Python 侧）：

```python
VALID_TYPES = {0x01,0x02,0x03,0x10,0x11,0x12,0x13,0x14,0xFF}
def validate(descs, desc_count, ddr_bytes):
    # (1) COUNT 与哨兵自洽
    if desc_count != len(descs): raise DescError("DESC_COUNT %d != %d" % (desc_count, len(descs)))
    # (2) 非法 TYPE
    for i,d in enumerate(descs):
        if d["TYPE"] not in VALID_TYPES: raise DescError("bad TYPE 0x%02x @%d" % (d["TYPE"], i))
    # (3) 地址 32 B 对齐 + IN_BYTES 是 32 的整数倍且 > 0 + 落在 DDR 窗内
    for i,d in enumerate(descs):
        if d["SRC_ADDR"] % 32 or d["DST_ADDR"] % 32: raise DescError("addr misalign @%d" % i)
        if d["IN_BYTES"] % 32 or d["IN_BYTES"] == 0: raise DescError("IN_BYTES bad @%d" % i)
        if d["SRC_ADDR"]+d["IN_BYTES"] > ddr_bytes or d["DST_ADDR"]+d["IN_BYTES"] > ddr_bytes:
            raise DescError("addr OOB @%d" % i)
    # (4) 自环
    for i,d in enumerate(descs):
        if d["SRC_ADDR"] == d["DST_ADDR"]: raise DescError("self-loop @%d" % i)
    # (5) 融合对配对：bit0=0 的项必须紧跟 `bit1=1` 的项；bit1=1 的项前一项必须 bit0=0
    for i,d in enumerate(descs):
        if (d["FLAGS"] & 1) == 0 and (i+1 >= len(descs) or (descs[i+1]["FLAGS"] & 2) == 0):
            raise DescError("head without tail @%d" % i)
        if (d["FLAGS"] & 2) and (i == 0 or (descs[i-1]["FLAGS"] & 1)):
            raise DescError("tail without head @%d" % i)
    # (6) 哨兵项 FLAGS 必须为 0
```

- [ ] **Step 4: 写 `c3_descriptor_format.md`** —— 逐字抄 §1 的位表 + API + 六条 `validate` 规则 + "**C4/M2 的转换器必须产这个格式；要改走 spec 修订**（R3）"。

- [ ] **Step 5: 跑 + 提交**

```bash
cd /d/code/PDS/VexiiYeshenLinux/y1
PYTHONIOENCODING=utf-8 PYTHONPATH='../third_party/yunet/deps' \
  /d/code/PDS/NaxYeshenLinux/sim/reglogs/lxvenv/Scripts/python.exe tools/desc_table.py --selftest
echo "exit=$?"   # 期望 0；四条判据全绿（含三条负对照"发火"）
cd /d/code/PDS/VexiiYeshenLinux
git add y1/tools/desc_table.py y1/reports/c3_descriptor_format.md
GIT_AUTHOR_NAME="LiaoZiqi-GZFLS" GIT_AUTHOR_EMAIL="LiaoZiqi-GZFLS@users.noreply.github.com" \
GIT_COMMITTER_NAME="LiaoZiqi-GZFLS" GIT_COMMITTER_EMAIL="LiaoZiqi-GZFLS@users.noreply.github.com" \
git commit -m "feat(y1-c3): 冻结描述符位打包（8x32bit）+ 校验六规则 —— C4/M2 的机器可读契约"
```

---

### Task C3.3: `DdrMaster` 放宽到 32 B 粒度 + 流式模式（COPY 字节级不变）

**为什么**：① 一个描述符是 **32 B**，`DdrMaster` 现在要求 `len % 128 == 0`（它自己的注释写着"放宽到 32 B 粒度是后续 C3 的事"）；② 特征搬运要能**只读进片上**/ **只写出去**（描述符取表、激活流进融合缓冲），块拷贝的"读进去再写回来"对这两件事都不成立。

**Files:**
- Modify: `y1/rtl/DdrMaster.scala`
- Create: `y1/tools/run_ddrmaster32_ab.sh`（新闸门：32 B 粒度 + 两种流式模式）
- Create: `y1/rtl_test/DdrStreamTb.v`

- [ ] **Step 1: 改接口（新增端口；**旧端口一个不改**）**

```scala
// DdrMaster.io 新增：
val mode      = in  UInt(2 bits)   // 0=COPY(默认) 1=RD(只读→rdStream) 2=WR(只写←wrStream)
val rd_valid  = out Bool()          // RD 模式：块缓冲的 8 字节推出
val rd_ready  = in  Bool()
val rd_data   = out Bits(64 bits)
val wr_valid  = in  Bool()          // WR 模式：从流填块缓冲
val wr_ready  = out Bool()
val wr_data   = in  Bits(64 bits)
```

- [ ] **Step 2: 改行为（三处，**COPY 路径必须逐字节/逐拍不变**）**

1. **校验放宽**：`lenOk = (len % 32 == 0) && (len != 0)`（32 B 对齐由低 5 位为 0 保证，与 P3 同形）。
2. **尾块缩短突发**：把"每块恒 16 拍"改成"每块 `beats = min(16, remain/8)`"，`arlen/awlen = beats-1`；块缓冲仍 128 B，尾块只用前 `beats*8` 字节。地址仍 32 B 对齐（每次 += `beats*8`）。
   ```scala
   val beats   = Mux(remain >= U(128,32 bits), U(16,5 bits), (remain >> 3).resize(5))  // 1..16
   val arlen_r = (beats - 1).resize(8)
   // AR/AW 的 payload.len 从常量 U(ARLEN) 改成 arlen_r（COPY 且 len 是 128 倍数时恒 = 15 ⇒ 逐拍不变）
   ```
3. **两种流式模式**（在 R 之后 / W 之前插分支）：
   - `mode==1 (RD)`：R 收满本块后**不做 WR**，把块缓冲按拍推 `rd_data/rd_valid`（等 `rd_ready`），然后按 `remain` 决定下一块还是 DONE；`wr_bytes` 恒 0。
   - `mode==2 (WR)`：**不做 AR/R**，从 `wr_stream` 收 `beats` 拍填块缓冲，再走 AW/W/B；`rd_bytes` 恒 0。
   - `mode==0 (COPY)`：与 C2 完全相同。

- [ ] **Step 3: 写新闸门 `run_ddrmaster32_ab.sh`**（三作业，沿用 `AxiMemModel.v`）

1. **32 B 粒度正/负**：`len=32`（1 个描述符大小）− 读回 32 B 与 Python 黄金**逐字节**一致；`len=96`（3 拍）；正对照 `len=64`（`64 % 32 = 0`，**是 32 的倍数**，合法，必须过）与负对照 `len=48`（`48 % 32 = 16`，不是 32 的倍数 ⇒ **必须 err 且零搬运**）。⚠ 别把"48 合法"写进判据——48 非 32 的倍数，必须失败。
2. **RD 模式**：`mode=1, len=32` ⇒ 内存 `wr=0 bursts=1`，`rdStream` 推出的 32 B 与源逐字节一致。
3. **WR 模式**：`mode=2`，从流喂 32 B ⇒ 内存 `rd=0`，目标区 == 喂进的 32 B。
4. **回归**：`bash tools/run_ddrread_ab.sh && bash tools/run_ddrwrite_ab.sh && bash tools/run_ddrcopy_ab.sh` 三个仍 `=0`，且 `cyc_per_group_added ≤ 2` 不变（128 倍数长度的分块与旧逻辑同形）。

- [ ] **Step 4: 跑 + 确定性 + 提交**

```bash
cd /d/code/PDS/VexiiYeshenLinux/y1
printf 'Test/runMain DdrMasterGen D:/code/PDS/VexiiYeshenLinux/y1/gen\nexit\n' | bash sbt.sh 2>&1 | tail -4
bash tools/run_ddrmaster32_ab.sh ; echo "gate32=$?"
bash tools/run_ddrcopy_ab.sh ; echo "copy_reg=$?"
python tools/check_dangling.py gen/DdrMaster.v | tail -1
md5sum gen/DdrMaster.v   # 与 C3.1 基线对比：必须变（改了主口）
cd /d/code/PDS/VexiiYeshenLinux
git add y1/rtl/DdrMaster.scala y1/rtl_test/DdrStreamTb.v y1/tools/run_ddrmaster32_ab.sh
GIT_AUTHOR_NAME="LiaoZiqi-GZFLS" GIT_AUTHOR_EMAIL="LiaoZiqi-GZFLS@users.noreply.github.com" \
GIT_COMMITTER_NAME="LiaoZiqi-GZFLS" GIT_COMMITTER_EMAIL="LiaoZiqi-GZFLS@users.noreply.github.com" \
git commit -m "feat(y1-c3): DdrMaster 放宽到 32B 粒度 + RD/WR 流式模式（COPY 路径字节级不变，C2 三闸门回归）"
```

---

### Task C3.4: 描述符解析器（`DescDefs` + `DescFetch`）—— **S1 的 RTL 半**

**为什么**：S1 要求"主机写表 → NPU 读回并逐项回显"。本任务做取表 + 译码；与 `desc_table.py` 用**同一组向量**交叉对账（两处独立实现互相钉死）。

**Files:**
- Create: `y1/rtl/DescDefs.scala`
- Create: `y1/rtl/DescFetch.scala`
- Create: `y1/rtl_test/DescGen.scala`, `y1/rtl_test/DescTb.v`
- Create: `y1/tools/run_desc_ab.sh`

- [ ] **Step 1: `DescDefs.scala` —— 位打包常量 + 纯组合译码（单一真源）**

```scala
object DescType { val CONV3=0x01; val CONV1=0x02; val DW=0x03; val MAXPOOL=0x10
                  val RESIZE=0x11; val CONCAT=0x12; val ADD=0x13; val SIGMOID=0x14; val SENTINEL=0xFF }
object DescFlags { val OUT_TO_DDR = 0; val IN_FROM_PREV = 1 }   // 位号

case class DescWords(w0..w7: Bits(32 bits)) {
  def tpe:    UInt = w0(7 downto 0).asUInt
  def flags:  UInt = w0(15 downto 8).asUInt
  def imgW:   UInt = w1(15 downto 0).asUInt
  def imgH:   UInt = w1(31 downto 16).asUInt
  def cIn:    UInt = w2(15 downto 0).asUInt
  def cOut:   UInt = w2(31 downto 16).asUInt
  def group:  UInt = w3(7 downto 0).asUInt
  def stride: UInt = w3(11 downto 8).asUInt
  def pad:    UInt = w3(15 downto 12).asUInt
  def srcA:   UInt = w4.asUInt;  def dstA: UInt = w5.asUInt;  def inBytes: UInt = w6.asUInt
  def qShift: UInt = w7(7 downto 0).asUInt
  def layerId:UInt = w7(15 downto 8).asUInt
  def isSentinel: Bool = tpe === U(DescType.SENTINEL, 8 bits)
  def head: Bool = flags(DescFlags.OUT_TO_DDR) === False   // 纯表达式，勿用多语句赋值
  def tail: Bool = flags(DescFlags.IN_FROM_PREV)
}
```

要求：**全部是纯表达式**（`Cat`/切片），**不得**用多语句赋值构造只读字 —— `HostRegs` 已吃过这个坑（会生成敏感表为空的 `always @(*)`，iverilog 停在 X）。

- [ ] **Step 2: `DescFetch.scala` —— 用 DdrMaster(RD) 取一个 32 B 描述符**

```scala
case class DescFetch() extends Component {
  val io = new Bundle {
    val go     = in  Bool()                 // 与 descAddr 同拍有效
    val descAddr = in UInt(28 bits)          // 32 B 对齐
    val words  = out Vec(Bits(32 bits), 8)   // 小端：word(i) = 第 i 个 32-bit 字
    val words_valid = out Bool()
    val busy   = out Bool(); val err = out Bool()
    val ddr    = master(Axi4(...))           // 与 DdrMaster 同形，或直接包一个 DdrMaster(mode=1)
  }
}
```
实现：内部例化一个 `DdrMaster`，`mode=1(RD)`、`src=descAddr`、`len=32`；把 `rd_data/rd_valid/rd_ready` 的 **4 拍 8 字节**按小端拼成 8 个 32-bit 字（`word(2k)=data[k]低32`，`word(2k+1)=data[k]高32`）。`err` 透传。

- [ ] **Step 3: 装置 + 闸门 `run_desc_ab.sh`**

装置 `DescTb.v`：例化 `DescFetch` + `AxiMemModel`；`+MEMFILE=`（预载一张表）+ `+DESC_ADDR=`；打印 `W0..W7` 与 `RESULT: PASS|FAIL`。
闸门：
1. **向量来源**：`desc_table.py` 生成表字节（`--emit-hex`），Python 侧同时算出**期望的 8 个字**；
2. **正对照**：装置打印的 `W0..W7` 与 Python 期望**逐字**一致（`WORD_BAD=0`）；
3. **负对照 A**：把表里 `w6` 翻一个 bit ⇒ 装置 `W6` 与期望**不同**（证明闸门看的是位，不是"取到了没"）；
4. **负对照 B**：`+DESC_ADDR=` 给一个**未 32 B 对齐**的地址 ⇒ 断言 `err` 且 `WORDS_VALID=0`。
5. **交叉对账**：RTL 译出的字段（`tpe/cIn/...`）与 `desc_table.unpack` 的字段**逐字段相等**（把 RTL 打印的字段与 Python 的对照）。

- [ ] **Step 4: 跑 + 提交**

```bash
cd /d/code/PDS/VexiiYeshenLinux/y1
printf 'Test/runMain DescGen D:/code/PDS/VexiiYeshenLinux/y1/gen\nexit\n' | bash sbt.sh 2>&1 | tail -4
bash tools/run_desc_ab.sh ; echo "desc_gate=$?"        # 期望 0
python tools/check_dangling.py gen/DescFetch.v | tail -1
cd /d/code/PDS/VexiiYeshenLinux
git add y1/rtl/DescDefs.scala y1/rtl/DescFetch.scala y1/rtl_test/DescGen.scala y1/rtl_test/DescTb.v y1/tools/run_desc_ab.sh
GIT_AUTHOR_NAME="LiaoZiqi-GZFLS" GIT_AUTHOR_EMAIL="LiaoZiqi-GZFLS@users.noreply.github.com" \
GIT_COMMITTER_NAME="LiaoZiqi-GZFLS" GIT_COMMITTER_EMAIL="LiaoZiqi-GZFLS@users.noreply.github.com" \
git commit -m "feat(y1-c3): 描述符解析器（DescFetch=32B 取表 + DescDefs 纯组合译码），与 desc_table.py 交叉对账"
```

---

### Task C3.5: 行流式融合缓冲 `FusionBuf`（3 行窗口，RAM 结构 ⇒ DRM）

**为什么**：C3.0 判定融合单元的中间张量**必须行流式**（整块 1.6 MB / 356 DRM 无法双缓冲），且缓冲**必须落 RAM 结构**（30,720 B 按 FF 是 245,760 > 空闲 215,004；且 **PDS 忽略 `ram_style`** ⇒ 只能靠结构逼）。本任务只证**功能**；"真的落 DRM"由 S5（C3.13）的 `dev_map` 证。

**Files:**
- Create: `y1/rtl/FusionBuf.scala`
- Create: `y1/rtl_test/FusionBufGen.scala`, `y1/rtl_test/FusionBufTb.v`
- Create: `y1/tools/run_fusionbuf_ab.sh`

- [ ] **Step 1: 冻结接口（生产者的写口 = 一列 C 个通道；消费者的读口 = 某行某列的 C 个通道）**

```scala
class FusionBuf(val C: Int = 8, val WIDTH: Int = 64) extends Component {
  val io = new Bundle {
    // 生产口：写入 (row, col) 一列的 C 个通道（row 由模块内部 3 行指针轮转，外部只给 col 推进）
    val wr_col  = in  UInt(log2Up(WIDTH) bits)
    val wr_data = in  Vec(SInt(8 bits), C)
    val wr_en   = in  Bool()
    val wr_row_adv = in Bool()          // 写完一整行 ⇒ 行轮转（3 行环形）
    // 消费口：读 (row, col) 一列的 C 个通道；row 0=最老
    val rd_row  = in  UInt(2 bits)
    val rd_col  = in  UInt(log2Up(WIDTH) bits)
    val rd_data = out Vec(SInt(8 bits), C)
    // 自报（供装置钉死参数，防"生成参数不符"静默错判）
    val imgC    = out UInt(16 bits)     // = C
    val imgW    = out UInt(16 bits)     // = WIDTH
  }
  // 存储：必须写成**可寻址 RAM**
  //   val mem = Mem(SInt(8 bits), 3 * WIDTH * C)         // 3 行 x WIDTH 列 x C 通道
  //   写：mem.write(addr, data)  读：同步读（Mem 同步读会得到 block-RAM 标签；PDS 忽略 ram_style）
  //   ★ 不要照抄 LineBuffer 的"每列一条竖直移位寄存器 + 组合读"——那会继续落 FF（C3.0 §4）
}
```
地址编排：`addr(row,col,ci) = row*(WIDTH*C) + col*C + ci`。环形行指针 `row_ptr: UInt(2 bits)`，`wr_col` 到 `WIDTH-1` 且 `wr_row_adv` ⇒ `row_ptr += 1`。

- [ ] **Step 2: 装置 + 闸门（Python 独立模型 + 三条负对照）**

装置：按 `+W +H +C` 写 `H` 行（每行 `WIDTH` 列，每列 `C` 通道，值 = `f(row,col,ci)` 非平凡函数），然后读回**若干窗口**并全部打印。
闸门 `run_fusionbuf_ab.sh`：
1. **非退化前提**：断言 `H > 3`（否则"整张 = 一个窗口"，流式退化成无意义）且**相邻三行内容两两不同**（行内容 = 行号 ⇒ 一行移位必改变窗口）；
2. **正向**：读回窗口与 Python 模型**逐字节**一致（`MISMATCH=0`）；
3. **负对照 A（陈旧行）**：读一个**尚未被写过的**窗口位置，断言读到的是**复位值 0**（不是上一轮的残值）—— 这条证明"环形行指针"没有把旧行当新行；
4. **负对照 B（行序交换）**：把 `wr_row_adv` 提前一行 ⇒ 窗口内容必须**变化**（判据抓得到）；
5. **参数自报**：`imgC/imgW` 与 `+C/+W` 不符 ⇒ 装置 `$fatal`（Y1 的"宽度钉死"教训）。

- [ ] **Step 3: 跑 + 提交**

```bash
cd /d/code/PDS/VexiiYeshenLinux/y1
printf 'Test/runMain FusionBufGen D:/code/PDS/VexiiYeshenLinux/y1/gen\nexit\n' | bash sbt.sh 2>&1 | tail -4
bash tools/run_fusionbuf_ab.sh ; echo "fbuf_gate=$?"
cd /d/code/PDS/VexiiYeshenLinux
git add y1/rtl/FusionBuf.scala y1/rtl_test/FusionBufGen.scala y1/rtl_test/FusionBufTb.v y1/tools/run_fusionbuf_ab.sh
GIT_AUTHOR_NAME="LiaoZiqi-GZFLS" GIT_AUTHOR_EMAIL="LiaoZiqi-GZFLS@users.noreply.github.com" \
GIT_COMMITTER_NAME="LiaoZiqi-GZFLS" GIT_COMMITTER_EMAIL="LiaoZiqi-GZFLS@users.noreply.github.com" \
git commit -m "feat(y1-c3): 行流式融合缓冲 FusionBuf（3 行窗口、可寻址 RAM 结构），含陈旧行/行序负对照"
```

---

### Task C3.6: 旁路算子 —— `MaxPool` + `Resize`

**Files:**
- Create: `y1/rtl/MaxPoolUnit.scala`, `y1/rtl/ResizeUnit.scala`
- Create: `y1/tools/bypass_ref.py`（先只做 maxpool/resize 两个参考）
- Create: `y1/rtl_test/BypassGen.scala`, `y1/rtl_test/BypassTb.v`
- Create: `y1/tools/run_bypass_ab.sh`

- [ ] **Step 1: 冻结行为（写进各文件头）**

- `MaxPoolUnit`：2×2 / stride 2，int8 取最大，**无量化**（激活值直接透传）；输入 `(C,W,H)`，输出 `(C, W/2, H/2)`。要求 `W,H` 偶数。
- `ResizeUnit`：**×2 最近邻**（YuNet 的 `Resize` 是上采样 2×，`nearest`）；输出 `(C, 2W, 2H)`，`out[c][2y+dy][2x+dx] = in[c][y][x]`。
两者**逐点**处理（一拍一个输出像素的 C 通道），接口与 `Conv3x3Slice` 的 `x/x_valid/x_ready` + `y/y_valid` **同形**（便于 `UnitExec` 统一接）。

```scala
class MaxPoolUnit(val C: Int = 8) extends Component {
  val io = new Bundle {
    val x = in Vec(SInt(8 bits), C); val x_valid = in Bool(); val x_ready = out Bool()
    val y = out Vec(SInt(8 bits), C); val y_valid = out Bool()
    val imgC = out UInt(16 bits)
  }
}
```

- [ ] **Step 2: 写 `bypass_ref.py`（Python 参考，含 `--selftest`）**

`maxpool_ref(t, C, W, H)` / `resize2x_ref(t, C, W, H)` 逐点实现；`--selftest` 用**非平凡**输入（值 = `(i*131+7)&0xFF` 的 int8 解释 + 局部极大点）自检：断言输出与"朴素三重循环"逐点一致，且**输出不是常数**（防退化）。

- [ ] **Step 3: 闸门 `run_bypass_ab.sh`**（同一装置跑两个算子，参数化 `+OP=maxpool|resize`）

1. **正向**：输出与 `bypass_ref` **逐点**一致（`MISMATCH=0`）；向量**非平凡**（断言输入非常数、且 maxpool 的输出**不等于**输入的任何"整块平移"—— 防混叠）；
2. **负对照 A**：装置里把 `MaxPoolUnit` 的 2×2 窗口改成"取左上角"（网表突变或用 `+MUTATE=` 参数） ⇒ `MISMATCH>0`；
3. **负对照 B（Resize 相位）**：把 `out[c][2y+dy][2x+dx]` 的 `dy/dx` 极性反过来 ⇒ `MISMATCH>0`。

- [ ] **Step 4: 跑 + 提交**

```bash
cd /d/code/PDS/VexiiYeshenLinux/y1
printf 'Test/runMain BypassGen D:/code/PDS/VexiiYeshenLinux/y1/gen\nexit\n' | bash sbt.sh 2>&1 | tail -4
bash tools/run_bypass_ab.sh ; echo "bypass1_gate=$?"
cd /d/code/PDS/VexiiYeshenLinux
git add y1/rtl/MaxPoolUnit.scala y1/rtl/ResizeUnit.scala y1/tools/bypass_ref.py y1/rtl_test/BypassGen.scala y1/rtl_test/BypassTb.v y1/tools/run_bypass_ab.sh
GIT_AUTHOR_NAME="LiaoZiqi-GZFLS" GIT_AUTHOR_EMAIL="LiaoZiqi-GZFLS@users.noreply.github.com" \
GIT_COMMITTER_NAME="LiaoZiqi-GZFLS" GIT_COMMITTER_EMAIL="LiaoZiqi-GZFLS@users.noreply.github.com" \
git commit -m "feat(y1-c3): 旁路算子 MaxPool(2x2/s2) + Resize(x2 nearest)，Python 参考 + 相位/窗口负对照"
```

---

### Task C3.7: 旁路算子 —— `Add` + `Sigmoid`（含定点口径冻结）

**Files:**
- Create: `y1/rtl/AddUnit.scala`, `y1/rtl/SigmoidUnit.scala`
- Modify: `y1/tools/bypass_ref.py`（加 `add_ref` / `sigmoid_ref`）
- Modify: `y1/rtl_test/BypassTb.v`、`y1/tools/run_bypass_ab.sh`（加两个 `+OP=`）

- [ ] **Step 1: 冻结 `Add` 与 `Sigmoid` 的口径（写进文件头，这是"硬件怎么算"的唯一真源）**

- `AddUnit`：两路 int8 逐点相加 + clamp 到 `[-128,127]`（**饱和**，不回绕）。两路输入由 `UnitExec` 提供（一路来自 `IN_FROM_PREV`/融合缓冲，一路来自 `SRC_ADDR`）。
- `SigmoidUnit`：**int8 输入 = 定点 x（Q3.4，步长 1/16）**，输出 **int8（Q0.7，步长 1/128）**；
  `out = round(127 * sigmoid(x/16))`，用**256 项查表**（`Mem(SInt(8 bits), 256)`，表由 `bypass_ref.sigmoid_lut()` 生成并落 `gen/sigmoid_lut.hex`）。
  ⚠ 表必须**导出成文件**并由装置 `$readmemh` 载入（否则 RTL 里硬编码 256 个常量，无法与 Python 对账、也无法复核）。
  ⚠ "Q3.4/Q0.7"是本计划的**冻结选择**；yuNet 实际的 sigmoid 缩放由 C4/M2 的量化参数决定 ⇒ 记为 C4 开口项（与 R6 同档）。

- [ ] **Step 2: `bypass_ref.py` 加两个参考 + `sigmoid_lut()`**

`add_ref(a,b,C,W,H)` 饱和加；`sigmoid_lut()` 返回 256 个 int8（`x=-128..127`）；`sigmoid_ref(t)` = 查表。`--selftest` 追加：断言饱和点（`127+127→127`、`-128+-128→-128`）与表中点（`x=0 → 64`）成立。

- [ ] **Step 3: 闸门追加两作业**

1. **Add 正向**：两路非平凡输入（断言两路**不相等**，否则加法退化成 ×2）→ 输出 == `add_ref`；负对照：把 clamp 改成**回绕**（`&0xFF`）⇒ `MISMATCH>0`；
2. **Sigmoid 正向**：全 256 个码点**逐个**过一遍 → 输出 == LUT；负对照：查表地址取反（`x → -x`）⇒ `MISMATCH>0`；
3. **LUT 指纹**：`gen/sigmoid_lut.hex` 的 md5 记进报告，且重生成两次一致（确定性）。

- [ ] **Step 4: 跑 + 提交**

```bash
cd /d/code/PDS/VexiiYeshenLinux/y1
printf 'Test/runMain BypassGen D:/code/PDS/VexiiYeshenLinux/y1/gen\nexit\n' | bash sbt.sh 2>&1 | tail -4
bash tools/run_bypass_ab.sh ; echo "bypass2_gate=$?"
bash tools/run_bypass_ab.sh >/dev/null 2>&1   # 回归：MaxPool/Resize 不能被改坏
cd /d/code/PDS/VexiiYeshenLinux
git add y1/rtl/AddUnit.scala y1/rtl/SigmoidUnit.scala y1/tools/bypass_ref.py y1/rtl_test/BypassTb.v y1/rtl_test/BypassGen.scala y1/tools/run_bypass_ab.sh
GIT_AUTHOR_NAME="LiaoZiqi-GZFLS" GIT_AUTHOR_EMAIL="LiaoZiqi-GZFLS@users.noreply.github.com" \
GIT_COMMITTER_NAME="LiaoZiqi-GZFLS" GIT_COMMITTER_EMAIL="LiaoZiqi-GZFLS@users.noreply.github.com" \
git commit -m "feat(y1-c3): 旁路算子 Add(饱和) + Sigmoid(Q3.4->Q0.7 查表)，含回绕/极性负对照与 LUT 指纹"
```

---

### Task C3.8: 单单元执行器 `UnitExec`（不融合的 3×3 dense conv）—— **S2**

**为什么**：这是"走表把一层跑完"的第一条端到端通路：`SRC_ADDR` 的激活 → 片上 3 行窗口 → `Conv3x3Slice` → `DST_ADDR`。融合（S3）与旁路（S4）都是在它之上加分支。

**Files:**
- Create: `y1/rtl/UnitExec.scala`
- Create: `y1/tools/conv_unit_ref.py`（复用 `mac_ref.py`）
- Create: `y1/rtl_test/UnitExecGen.scala`, `y1/rtl_test/UnitExecTb.v`
- Create: `y1/tools/run_unitexec_ab.sh`

- [ ] **Step 1: 冻结 `UnitExec` 的接口与数据流（写进文件头）**

```scala
class UnitExec(val C: Int = 8, val WIDTH: Int = 64) extends Component {
  val io = new Bundle {
    // 一个"单元"的输入（来自描述符）
    val go      = in  Bool()
    val d       = in  DescWords           // w0..w7（来自 DescFetch）
    val wgt_base= in  UInt(16 bits)        // 带外：本单元权重在 WeightStore 的基址（C4 开口项）
    // 权重装载口（带外预载，直通 Conv3x3Slice）
    val we = in Bool(); val waddr = in UInt(16 bits); val wdin = in SInt(8 bits)
    // 激活侧：从 FusionBuf 读（融合时）或从 DDR 读（不融合时）
    val fb_rd_row = out UInt(2 bits); val fb_rd_col = out UInt(16 bits)
    val fb_rd_data= in  Vec(SInt(8 bits), C)
    val fb_wr_col = out UInt(16 bits); val fb_wr_data = out Vec(SInt(8 bits), C); val fb_wr_en = out Bool()
    val fb_row_adv= out Bool()
    // 结果：写回 DDR（交给 DdrMaster WR 模式）或交给下一单元（FusionBuf）
    val out_valid = out Bool(); val out_data = out Vec(SInt(8 bits), C)
    val done = out Bool(); val err = out Bool()
    // DDR 侧（RD/WR 流式）
    val ddr = master(Axi4(...))
  }
}
```

数据流（不融合的 3×3 dense，S2）：
1. `DdrMaster(mode=RD, src=d.srcA, len=d.w6)` 逐块读激活进 `FusionBuf`（**作为本单元的输入 3 行窗口**）；
2. `Conv3x3Slice` 从 `FusionBuf` 按列读（`x(ci) = fb_rd_data(ci)`，`rd_row` 轮转、`rd_col` 推进），`x_valid` 由"窗口已就绪"门控；
3. `y_valid` 时把 `y` 写进**输出缓冲**（本任务复用 `FusionBuf` 的第二块 `Mem`，或直接流给 `DdrMaster(mode=WR, dst=d.dstA)`）；
4. **S2 的判据是数值**：`MISMATCH=0`（不是性能），所以本任务允许"先整张读进 FusionBuf（`W×H` 行窗口 = 3 行足够，因为 Conv3x3Slice 自己带行缓冲）" —— 用 `+ROWS_LIVE=3` 固定。

⚠ **尺寸约束**（写进 TB 断言）：`d.w6 % 128 == 0`（S2/S3/S4 的几何都取 128 倍数；32 B 粒度的通用路径由 C3.3 提供，但本任务先走全块以减少混淆）。

- [ ] **Step 2: `conv_unit_ref.py`** —— 8→8 dense 3×3 的 Python 参考：`>>6` + clamp（与 `mac_ref.py` 同口径），并**把权重与偏置写成一个可被 TB/装置复用的 `wgt.hex`**（这样"带外预载权重"有确定来源）。

- [ ] **Step 3: 装置 + 闸门 `run_unitexec_ab.sh`**

装置：例化 `UnitExec` + `AxiMemModel`；预载：激活进 src 区、权重从 `+WGTFILE=` 经 `we/waddr/wdin` 装载；给一个描述符（`+D*=` 或从表读）；`+CTRL=` 起跑；转储内存。
闸门（S2）：
1. **正向**：dst 区与 `conv_unit_ref` 的黄金**逐点**一致（`MISMATCH=0`）；几何 `C_IN=C_OUT=8, W=64, H=4, SHIFT=6`，`IN_BYTES=2048`；
2. **src 未改**（`SRC_UNCHANGED_BAD=0`）；**邻居未动**（`NEIGHBOR_BAD=0`）；
3. **负对照 A**：把 `QUANT_SHIFT` 从 6 改成 5 ⇒ `MISMATCH>0`（证明判据真的看数值）；
4. **负对照 B**：把权重 `wgt.hex` 翻一个字节 ⇒ `MISMATCH>0`。

- [ ] **Step 4: 跑 + 提交**

```bash
cd /d/code/PDS/VexiiYeshenLinux/y1
printf 'Test/runMain UnitExecGen D:/code/PDS/VexiiYeshenLinux/y1/gen\nexit\n' | bash sbt.sh 2>&1 | tail -4
bash tools/run_unitexec_ab.sh ; echo "unitexec_gate=$?"
python tools/check_dangling.py gen/UnitExec.v | tail -1
cd /d/code/PDS/VexiiYeshenLinux
git add y1/rtl/UnitExec.scala y1/tools/conv_unit_ref.py y1/rtl_test/UnitExecGen.scala y1/rtl_test/UnitExecTb.v y1/tools/run_unitexec_ab.sh
GIT_AUTHOR_NAME="LiaoZiqi-GZFLS" GIT_AUTHOR_EMAIL="LiaoZiqi-GZFLS@users.noreply.github.com" \
GIT_COMMITTER_NAME="LiaoZiqi-GZFLS" GIT_COMMITTER_EMAIL="LiaoZiqi-GZFLS@users.noreply.github.com" \
git commit -m "feat(y1-c3): 单单元执行器（DDR->FusionBuf->Conv3x3->DDR）S2 数值对账 8->8 dense 3x3"
```

---

### Task C3.9: 融合单元（1×1→3×3 一对）—— **S3**

**Files:**
- Modify: `y1/rtl/UnitExec.scala`（加"输入取上一单元输出"与"输出留给下一单元"两个分支）
- Create: `y1/tools/run_fuse_ab.sh`

- [ ] **Step 1: 加融合分支**

- **头单元**（`FLAGS.bit0 = 0`）：输出**不写 DDR**，`y_valid` 直接喂 `FusionBuf` 的生产口（行轮转）；
- **尾单元**（`FLAGS.bit1 = 1`）：输入**不读 DDR**，`Conv3x3Slice` 的 `x` 来自 `FusionBuf` 的读口；
- 两个单元之间**零 DDR 中间张量**。

- [ ] **Step 2: 闸门 `run_fuse_ab.sh`（S3 的两条判据）**

几何：`conv1x1(8→8, W=64,H=4)` → `conv3x3(8→8, W=64,H=4)`；中间张量 `= 8·4·64 = 2048 B`，落在 `MID_ADDR`。
1. **结果一致**：与"分两步、中间张量落 DDR"的 Python 参考**逐点一致**（`MISMATCH=0`）—— 参考由 `conv_unit_ref` 串两次得到；
2. **中间张量真的没落 DDR**：
   - 内存模型 `MEM rd=<n> wr=<n>` 的读写字节数 == 预期（**少掉的正好是中间张量的 `2×2048`**）；判据：`WR_BYTES == 期望值`（写出 = 头单元输出不落 DDR，只落尾单元输出）；
   - **断言 `MID_ADDR` 区间逐字节 == 预载值**（`MID_UNCHANGED_BAD=0`）；
3. **负对照**：把 `FLAGS.bit0` 强行置 1（头单元也落 DDR）⇒ `WR_BYTES` **变大**、`MID_UNCHANGED_BAD>0`（判据两侧都发火）。

- [ ] **Step 3: 跑 + 提交**

```bash
cd /d/code/PDS/VexiiYeshenLinux/y1
printf 'Test/runMain UnitExecGen D:/code/PDS/VexiiYeshenLinux/y1/gen\nexit\n' | bash sbt.sh 2>&1 | tail -4
bash tools/run_fuse_ab.sh ; echo "fuse_gate=$?"
bash tools/run_unitexec_ab.sh >/dev/null 2>&1 ; echo "s2_regression=$?"
cd /d/code/PDS/VexiiYeshenLinux
git add y1/rtl/UnitExec.scala y1/tools/run_fuse_ab.sh
GIT_AUTHOR_NAME="LiaoZiqi-GZFLS" GIT_AUTHOR_EMAIL="LiaoZiqi-GZFLS@users.noreply.github.com" \
GIT_COMMITTER_NAME="LiaoZiqi-GZFLS" GIT_COMMITTER_EMAIL="LiaoZiqi-GZFLS@users.noreply.github.com" \
git commit -m "feat(y1-c3): 融合单元（1x1->3x3）S3 —— 结果一致 + 中间张量零落 DDR（两条判据 + 双向发火）"
```

---

### Task C3.10: 单元序列 FSM `LayerSched`（含旁路算子、**帧内零中断**）—— **S4**

**Files:**
- Create: `y1/rtl/LayerSched.scala`
- Create: `y1/rtl_test/LayerSchedGen.scala`, `y1/rtl_test/LayerSchedTb.v`
- Create: `y1/tools/run_sched_ab.sh`

- [ ] **Step 1: FSM 行为（走表 + 编排）**

```
IDLE --go--> FETCH(i=0)          : DescFetch(descAddr + i*32)
FETCH --> CHK                     : 哨兵？ i==DESC_COUNT ？ COUNT 与哨兵是否自洽（否则 err）
CHK   --> EXEC                    : 按 TYPE 分派
EXEC  --> NEXT                    : UnitExec / MaxPoolUnit / ResizeUnit / AddUnit / SigmoidUnit 跑完
NEXT  --> FETCH(i+1) / FRAME_DONE : 表尾 + DESC_COUNT 用完 ⇒ FRAME_DONE
FRAME_DONE --> IDLE               : frameDone **单拍脉冲**（中断由 NpuTop 锁成保持电平）
```
**关键纪律**：`frameDone` **只在整帧末尾**抬一次；**帧内任何单元完成都不抬中断**（S4 的"帧内中断计数 == 0"）。

- [ ] **Step 2: 闸门 `run_sched_ab.sh`（S4 的三条判据 + 计数）**

序列（3 个单元）：`conv3x3(8→8, W=32,H=8)` → `maxpool(2x2)` → `conv1x1(8→8)`。
1. **结果一致**：末张量与 Python 参考（`conv_unit_ref` + `bypass_ref.maxpool_ref` 串联）**逐点一致**（`MISMATCH=0`）；
2. **旁路算子不是"跑完没报错"**：单独断言 maxpool 那一段的输出与 `maxpool_ref` **逐点**一致（不能只验整链）；
3. **帧内中断计数 == 0**：TB 对**顶层 `irq` 的上升沿**计数——`IRQ_RISES == 1` 且**唯一的上升沿在末单元 done 之后**（`IRQ_AT_FRAME_END=1`、`IRQ_INTRA_FRAME=0`）；再补一条 `IRQ_HELD_AFTER_50=1`（保持电平，不是单拍脉冲）；
4. **负对照 A**：把某个中间单元也抬 `frameDone`（网表突变）⇒ `IRQ_INTRA_FRAME > 0` ⇒ 闸门必须报红；
5. **负对照 B**：把表里 `DESC_COUNT` 少写 1 ⇒ 断言 `err`（走到哨兵时 COUNT 不符）。

- [ ] **Step 3: 跑 + 提交**

```bash
cd /d/code/PDS/VexiiYeshenLinux/y1
printf 'Test/runMain LayerSchedGen D:/code/PDS/VexiiYeshenLinux/y1/gen\nexit\n' | bash sbt.sh 2>&1 | tail -4
bash tools/run_sched_ab.sh ; echo "sched_gate=$?"
bash tools/run_fuse_ab.sh >/dev/null 2>&1 ; echo "s3_regression=$?"
python tools/check_dangling.py gen/LayerSched.v | tail -1
cd /d/code/PDS/VexiiYeshenLinux
git add y1/rtl/LayerSched.scala y1/rtl_test/LayerSchedGen.scala y1/rtl_test/LayerSchedTb.v y1/tools/run_sched_ab.sh
GIT_AUTHOR_NAME="LiaoZiqi-GZFLS" GIT_AUTHOR_EMAIL="LiaoZiqi-GZFLS@users.noreply.github.com" \
GIT_COMMITTER_NAME="LiaoZiqi-GZFLS" GIT_COMMITTER_EMAIL="LiaoZiqi-GZFLS@users.noreply.github.com" \
git commit -m "feat(y1-c3): 单元序列 FSM LayerSched —— S4 多单元+旁路算子+帧内中断计数==0（含突变负对照）"
```

---

### Task C3.11: 非法表（越界/自环/非法 TYPE/COUNT 不符）—— **S6**

**Files:**
- Modify: `y1/rtl/LayerSched.scala`（加 CHK 的六条校验）
- Modify: `y1/tools/run_sched_ab.sh`（加负作业）

- [ ] **Step 1: 把 `desc_table.validate` 的六条规则**逐条**在 RTL 的 CHK 态实现**（同一个判据两处独立实现：Python 侧 C3.2、RTL 侧这里）。RTL 侧读的是 `DescWords` 的字段，规则同 §C3.2 Step 3 的 (1)–(6)。

- [ ] **Step 2: 闸门加四道负作业（每道都必须"响亮 err + 零搬运"）**

对每一种非法表：断言 `status.err=1`、`MEM rd=0 wr=0 bursts=0`、无 `done`、`irq` 抬起（err 也锁电平，与 C2 的 NpuTop 同口径）。四种表：**(a)** TYPE=`0x77`；**(b)** `SRC_ADDR==DST_ADDR`（自环）；**(c)** `DESC_COUNT` 与哨兵不符；**(d)** `DST_ADDR+IN_BYTES` 越出 DDR 窗。**正对照**：合法表**不得**报 err（`ERR_SEEN=0`）。

- [ ] **Step 3: 跑 + 提交**

```bash
cd /d/code/PDS/VexiiYeshenLinux/y1
printf 'Test/runMain LayerSchedGen D:/code/PDS/VexiiYeshenLinux/y1/gen\nexit\n' | bash sbt.sh 2>&1 | tail -4
bash tools/run_sched_ab.sh ; echo "sched_gate=$?"   # 含正/负全作业
cd /d/code/PDS/VexiiYeshenLinux
git add y1/rtl/LayerSched.scala y1/tools/run_sched_ab.sh
GIT_AUTHOR_NAME="LiaoZiqi-GZFLS" GIT_AUTHOR_EMAIL="LiaoZiqi-GZFLS@users.noreply.github.com" \
GIT_COMMITTER_NAME="LiaoZiqi-GZFLS" GIT_COMMITTER_EMAIL="LiaoZiqi-GZFLS@users.noreply.github.com" \
git commit -m "feat(y1-c3): 非法表校验六规则（S6）—— 四道负作业响亮 err + 零搬运，合法表不报 err"
```

---

### Task C3.12: 并入 `NpuTop` + `HostRegs`（`DESC_ADDR`/`DESC_COUNT`）

**Files:**
- Modify: `y1/rtl/HostRegs.scala`（加两个 RW 档）
- Modify: `y1/rtl/NpuTop.scala`（例化 `LayerSched`，把 `frameDone` 锁成 IRQ）
- Create: `y1/tools/run_nputop_sched_ab.sh`

- [ ] **Step 1: `HostRegs` 加 `DESC_ADDR`(0x34) / `DESC_COUNT`(0x38)**

照既有 10 个 RW 档的**同一种写法**（`Reg(UInt(32 bits))` + `bus.readAndWrite(...)`），**只用纯 `Cat` 表达式**构造只读字；导出 `io.desc_addr` / `io.desc_count`。既有 13 格的语义与地址**一个都不动**（`run_hostregs_ab.sh` 必须仍全绿）。

- [ ] **Step 2: `NpuTop` 例化 `LayerSched`**

- `LayerSched.io.axilite` 侧不需要（寄存器在 `HostRegs`）；给 `LayerSched` 传 `descAddr/descCount/start/soft_reset`；
- `LayerSched.frameDone` → 与 C2 的 `ddrMaster.done|err` **同口径**锁成保持电平 `irqR`（事件置 1、`CTRL.soft_reset` 清 0）；
- `LayerSched.err` → 并入 `errSticky` → `STATUS.bit1`；
- **保留 C2 的块拷贝通路**（`CTRL.start` 若 `DESC_COUNT=0` 则走旧的块拷贝语义）—— 或更干净：`C3` 起 `CTRL.start` 一律走调度器；**二选一，选一种并写进注释**；选后者时必须确认 `run_nputop_ab.sh`（C2 的端到端块拷贝闸门）**仍然 PASS**，否则说明契约变了，要按新契约更新它。

- [ ] **Step 3: 台账同步（若地址窗/IRQ 有变）**

```bash
cd /d/code/PDS/VexiiYeshenLinux
python scripts/check_addr_map.py ; echo "addr_map_exit=$?"      # 期望 PASS
```
`DESC_ADDR/DESC_COUNT` 在**既有的** `0xF000C000` 窗内 ⇒ 若窗口/PLIC 源不变，台账**应无改动**；**若 PASS，就是"没动台账"的正向证据**（写进报告）。

- [ ] **Step 4: 端到端闸门 `run_nputop_sched_ab.sh`**

主机经 AxiLite4 写 `DESC_ADDR/DESC_COUNT` → 写 `CTRL.start` → 轮询 `STATUS` 看 `done`、顶层 `irq` 抬起 → 转储内存与 Python 黄金**逐点**一致。含：① 正对照；② 非法表负对照（经 `STATUS.err` 观察到）；③ **C2 回归**（`run_nputop_ab.sh` + `run_ddrcopy_ab.sh` 仍 `=0`）。

- [ ] **Step 5: 跑 + 提交**

```bash
cd /d/code/PDS/VexiiYeshenLinux/y1
printf 'Test/runMain NpuTopGen D:/code/PDS/VexiiYeshenLinux/y1/gen\nexit\n' | bash sbt.sh 2>&1 | tail -4
printf 'Test/runMain HostRegsGen D:/code/PDS/VexiiYeshenLinux/y1/gen\nexit\n' | bash sbt.sh 2>&1 | tail -4
bash tools/run_hostregs_ab.sh ; echo "hostregs_reg=$?"
bash tools/run_nputop_ab.sh   ; echo "nputop_c2_reg=$?"
bash tools/run_nputop_sched_ab.sh ; echo "nputop_sched=$?"
cd /d/code/PDS/VexiiYeshenLinux
git add y1/rtl/HostRegs.scala y1/rtl/NpuTop.scala y1/tools/run_nputop_sched_ab.sh
GIT_AUTHOR_NAME="LiaoZiqi-GZFLS" GIT_AUTHOR_EMAIL="LiaoZiqi-GZFLS@users.noreply.github.com" \
GIT_COMMITTER_NAME="LiaoZiqi-GZFLS" GIT_COMMITTER_EMAIL="LiaoZiqi-GZFLS@users.noreply.github.com" \
git commit -m "feat(y1-c3): 层调度器并入 NpuTop + HostRegs(DESC_ADDR/DESC_COUNT)；端到端与 C2 双回归"
```

---

### Task C3.13: **S5 面积闸门** + C3 结论报告

**为什么**：spec §6 R1/R2 的**残留风险**就是"这四条新数据通路 + 描述符解析器的面积未估"，S5 就是它的判据；且 C3.0 的承重条件"缓冲真的落 DRM 不在 FF"只能在这里证。

**Files:**
- Create: `y1/pds/devmap_c3.tcl`
- Create: `y1/reports/c3_area.md`
- Create: `y1/reports/c3_scheduler.md`

- [ ] **Step 1: 写 `devmap_c3.tcl`**（在既有 `y1/pds/devmap_soc_npu.tcl` 基础上加 C3 源：`FusionBuf` / 旁路四单元 / `LayerSched` / `UnitExec` 等）。**顶层取"最坏参数"**：`FusionBuf(C=64, WIDTH=160)`（3 行 = 30,720 B ⇒ 期望 ≥7 DRM）。

- [ ] **Step 2: 跑 dev_map（**注意 M0 教训**：`dev_map` 在 DRC 中止时**不打印** `Device Utilization Summary`，数字要从 `Mapping Summary` + `GTP_*` 行取并注明来源）**

```bash
cd /d/code/PDS/VexiiYeshenLinux
/c/Pango/PDS_2025.2-ads/bin/pds_shell.exe -file "D:/code/PDS/VexiiYeshenLinux/y1/pds/devmap_c3.tcl" \
  > y1/pds/devmap_c3.log 2>&1 ; echo "exit=$?"
grep -nE "Device Utilization Summary|Mapping Summary" -A 14 y1/pds/devmap_c3.log
grep -nE "DRC-00|Program Error" y1/pds/devmap_c3.log | head
```

- [ ] **Step 3: S5 的三条判据（**缺一不可**）**

1. **DRM 用量 ≥ 7 块**（证明 3 行窗口真的进去了），且 **SoC + C3 ≤ 415**；
2. **断言缓冲真的在 DRM、不在 FF** —— 看三样：**`DRM` 用量**（≥7）、**`Adm-4088`（DRM 不够转 LUTRAM）条数**（应为 0 或明确计数）、**`LUTs as dram`**（若 >0 说明落了 LUTRAM，要改结构）；
3. **汇总面积**：LUT/FF/APM/DRM 全表 + 与 C2 基线（SoC+NPU）的 **Δ**。
   **⚠ PDS 忽略 `ram_style`** ⇒ 若实测落到 FF/LUTRAM，**改结构**（尺寸/端口形态，见 §C3.5 的 `Mem` 写法），**不要加属性**。
   **⚠ 若超出预算** ⇒ 按 spec R1 的退路：**只给最重的两个旁路算子加硬件**（MaxPool/Resize），其余（Add/Sigmoid）由主机在帧末做 —— 并**如实修正 spec**（走 spec 修订）。

- [ ] **Step 4: 回归 + 写 `c3_area.md` / `c3_scheduler.md`**

```bash
cd /d/code/PDS/VexiiYeshenLinux
python scripts/check_addr_map.py ; echo "addr_map=$?"
for g in run_ddrmaster32_ab run_desc_ab run_fusionbuf_ab run_bypass_ab run_unitexec_ab run_fuse_ab run_sched_ab run_nputop_sched_ab run_nputop_ab run_ddrcopy_ab; do
  bash y1/tools/$g.sh >/dev/null 2>&1; echo "$g=$?"
done
python y1/tools/check_dangling.py rtl/YeshenSocGlue.v | tail -1
bash y1/tools/check_no_xilinx.sh rtl | tail -1
```
Expected: 全部 0。

`c3_scheduler.md` 必须逐条对上 S1–S6：**每条判据的向量、命令、结果、正负对照退出码**；S5 给 DRM 明细与"是否落 DRM"的三样证据；**复现命令 + 产物指纹清单**；**如实列缺口**：
- 未上板、无时序、无 PnR；
- **权重指针不在描述符**（C4/M2 开口项，与本计划的总约定第 1 条一致）；
- **Sigmoid 的 Q3.4→Q0.7 是冻结选择**，真值由 C4/M2 的量化参数决定；
- 只支持 8→8 卷积单元（宽通道靠多趟，属 C4）；
- C5 的 CPU 争用份额、真实 fps 未测。

- [ ] **Step 5: 提交**

```bash
cd /d/code/PDS/VexiiYeshenLinux
git add y1/pds/devmap_c3.tcl y1/pds/devmap_c3.log y1/reports/c3_area.md y1/reports/c3_scheduler.md
GIT_AUTHOR_NAME="LiaoZiqi-GZFLS" GIT_AUTHOR_EMAIL="LiaoZiqi-GZFLS@users.noreply.github.com" \
GIT_COMMITTER_NAME="LiaoZiqi-GZFLS" GIT_COMMITTER_EMAIL="LiaoZiqi-GZFLS@users.noreply.github.com" \
git commit -m "docs(y1-c3): S5 面积闸门（DRM>=7 + 缓冲真的落 DRM）+ C3 结论（S1-S6 + 缺口清单）"
```

---

## 自查记录

1. **设计覆盖**：spec §3 描述符语义 → C3.2（位打包）+ C3.4（RTL 译码）；§4 三块新增（解析器/融合缓冲/序列 FSM）→ C3.4 / C3.5 / C3.10；§4 复用 → C3.8/C3.9 用 `Conv3x3Slice`、C3.3 扩 `DdrMaster`（spec 未写"扩主口"但 `DdrMaster.scala:67` 自述"放宽到 32 B 粒度是后续 C3 的事" ⇒ 有出处）；§5 S1 → C3.4；S2 → C3.8；S3 → C3.9；S4 → C3.10；S5 → C3.13；S6 → C3.11 + C3.2 Step 3；§6 R1/R2 → C3.13（含退路）；R3 → C3.2 的 `desc_table.py` + `c3_descriptor_format.md`（C4/M2 契约）；R5 → C3.13 Step 3 的第 2 条；**R6 → C3.1**；R7 → 明确推给 C5。
2. **占位扫描**：无 TBD。每个 RTL Task 给了**具体接口（Scala 骨架）+ 行为契约 + 判据**；每个 Python Task 给了**可运行的代码骨架**；每个闸门都写死了**正对照 + ≥1 条负对照 + 退出码**。C3.13 的"超预算退路"是**条件分支且条件写死**（S5 判据），不是占位。
3. **类型一致性**：`DescWords`（C3.4 定义）在 C3.8/C3.9/C3.10/C3.11 只被读、不改签名；`FusionBuf` 的 `wr_col/wr_data/wr_en/wr_row_adv` 与 `rd_row/rd_col/rd_data`（C3.5 定义）在 C3.8/C3.9 原样使用；`UnitExec` 的 `go/d/wgt_base/we-waddr-wdin/fb_*/out_*/done/err/ddr`（C3.8 定义）在 C3.9 只加分支不改签名；旁路四单元的 `x/x_valid/x_ready/y/y_valid`（C3.6/C3.7）与 `Conv3x3Slice` 同形 ⇒ `LayerSched`（C3.10）可以统一接；`DdrMaster` 的 `mode/rd_*/wr_*`（C3.3）在 C3.4/C3.8 沿用；闸门退出码 `0/1/2` 与 Y1 既有 8 个闸门一致；`desc_table.validate` 的六条规则在 Python（C3.2）与 RTL（C3.11）两处**逐条对应**。
4. **诚实性记录（写计划时发现、需评审确认的两处）**：
   - **描述符没有权重指针**（8 字已满）。本计划不改格式，C3 的数值判据用带外预载；把它显式记为 **C4/M2 开口项**（总约定第 1 条 + C3.13 缺口清单）。若评审要求现在补，走 **spec 修订**。
   - **Sigmoid 的定点刻度（Q3.4→Q0.7）是本计划的冻结选择**，非 spec 冻结值；真值属 C4/M2 的量化参数。已在 C3.7 Step 1 与 C3.13 缺口清单两处声明。
