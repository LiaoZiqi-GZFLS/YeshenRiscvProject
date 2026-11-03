#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""y1_convert.py —— y1 C4a.3 **转换器**：`yunet.onnx` → 描述符表 + 权重 blob + 索引。

纯离线 Python：不产 RTL、不碰 SoC、不上板。

============================================================================
Step 1：冻结接口与「表序隐含权重」契约（逐字；要改走 spec 修订）
============================================================================
输入：`yunet.onnx` + `quant_ptq` 的每层参数（校准接口；本文件**逐字复用** `quant_ptq`）
输出（落 `y1/gen/` 下，gitignore）：
  ① `desc.bin`     —— 描述符表（**复用 `desc_table.pack_table`**；末尾自动哨兵）
  ② `wgt_blob.bin` —— 权重 blob，**按表序**连续排布；第 i 个消费权重的单元占用
                      **`N_i' = ceil32(N_i)`** 字节（`N_i = C_out*(C_in/GROUP)*9` 是**真实**字节数；
                      段内 `[N_i, N_i')` 补 **0**），起点 = `Σ_{j<i} N_j'`
                      ★ 2026-10-12（B0）：每单元段补齐到 32 B 倍 + 32 B 对齐 —— 主口 `DdrMaster` 的 RD 契约
                        是 `src%32==0 && len%32==0`（C3.3），旧紧凑布局里 `Conv_0` 段长 432 B、多数单元
                        起点 `≡16 (mod 32)` ⇒ 装载**响亮 err**。见 spec §4.2 的「布局修订（2026-10-12）」。
  ③ `wgt_index.json` —— 每个单元的名字/偏移/字节数（`nbytes`=**真实** N_i、`aligned_bytes`=**物理** N_i'；
                      G6 装载用 `offset/aligned_bytes`、G2 逐字节对账用 `nbytes`）
契约：**表序 == blob 序**（R4 的对冲：`wgt_index.json` + G6 的 blob 指纹 + G2 的逐层对账）

============================================================================
★ 新增约束（spec §4.4，2026-10-10 裁决）—— requant 乘子 `M` 的投递
============================================================================
冻结的 requant 是纯 `>>6`，但真实 per-tensor 量化的 requant 乘子是
`M = round( (s_x·s_w/s_y) · 2^(SHIFT+REQUANT_Q) )`，**纯移位表达不了**（见
`reports/c4a_quant.md` §11.3：层 0 实测 ratio≈2^-9，`>>6` 的粒度是 2^-6 ⇒ 纯移位整网偏差≈100%
且中间层塌成常数）。

**裁决**：`M` 按**表序**排在**权重 blob 之后**（同一个「权重信箱」地址区），用**既有的**
`WGT_ADDR/WGT_DATA/WGT_WE` 信箱装载，用描述符 `w7`（`[15:8]=LAYER_ID`）索引 ⇒
**8 字描述符格式一字未改**。

⇒ 本文件的两条落地物：
  · `gen/wgt_mult.bin`：`M` 区，**每项 1 个 32-bit 小端字**（下标 = 表序 = `LAYER_ID`），
    物理上紧跟在 `wgt_blob.bin` 之后（`wgt_index.json` 的 `mult.offset_in_mailbox = blob.bytes`）；
  · `wgt_index.json` 的 **`requant_mult` 段**：每项 `{layer_id, M, REQUANT_Q=24, ...}`。

★★ `w7` 的 `LAYER_ID` 语义**加重**（格式不变）★★
  C3 里 `LAYER_ID` 只是「遥测身份 = 最终表序」（`desc_table.build_table` 逐项写 i）；
  从 C4a.3 起它同时是 **requant 乘子索引**（`M` 表的下标）。⇒ 转换器必须保证
  `LAYER_ID == 表序下标`，否则硬件会把乘子装错层。

============================================================================
★ §4.5-A（2026-10-11 裁决）—— 权重**对称** + zero-point 中心化**转换器侧**落地
============================================================================
  权重侧（黄金 `quant_ref` 已按 §4.5-A 重建，commit `a77efb3`）：
    每层权重走 `quant_ptq.weight_params` / `quant_weight` ⇒ `z_w ≡ 0`、`s_w = max|w|/127`、
    `w_q ∈ [−127,127]`；**中心化权重 `c_q = w_q − z_w ≡ w_q` 恰落 int8**
    ⇒ 硬件 MAC 维持 int8×int8（**MAC 位宽零改动**）。激活仍 affine（零值纳入）。

  硬件「中心化」算术（本文件负责铺设索引元数据；RTL 侧无位宽变化）：
    z_w ≡ 0                        # 对称权重 ⇒ w_q 本身即中心化权重
    z_pad = z_x                    # 补位值 = 真实 0 的码点（**不是字节 0**），逐层不同
    bias_adj = round(bias/(s_x·s_w)) − z_x · Σ_all-taps w_q     # 每输出通道一个常数
    hw:  acc = Σ x_q·w_q + bias_adj (pad = z_pad) ≡ 黄金 Σ(x_q−z_x)(w_q−0) + round(bias/(s_x·s_w))
  ⇒ 本文件在 `wgt_index.json` 新增 **`centering` 段**（逐消费权重的单元）：
    `z_pad / bias_adj[] / s_x,z_x / s_w,z_w(=0) / s_y,z_y`（+ `sum_w_q_all_taps[]` 便于复核）。

  · 1×1 核落 3×3 布局的**补位抽头一律填 0**（§4.5-A：z_w≡0 ⇒ 中心化零的码点就是 0 ⇒ 零贡献）。
  · 等价性代数证在 `tools/center_equiv_probe.py`（200 组随机、`ALL_EQUAL`）；闸门再对**真网**逐字节复核
    （见 Step 3 的第 4 条正/负对照）。

============================================================================
Step 2：实现（复用冻结件，绝不重推规则）
============================================================================
  · **算子序 / 融合枚举 / 编码口径一律取自冻结件**：
    - 表（载荷项 + FLAGS 链角色 + 链首几何覆盖 + 地址向量）= **字面调用**
      `desc_table.build_table(gv)`（它自己再只读 `ddr_traffic` 的 `find_fusion_pairs*`）；
    - 位打包 / 哨兵 / 校验 = `desc_table.pack_table / pack / unpack / validate /
      desc_count_of / reference_words`（字面调用）；
    - 量化口径 = `quant_ptq.calibrate / affine_params / quant / dequant`（激活，affine）、
      `quant_ptq.weight_params / quant_weight`（权重，**对称** §4.5-A）、`SHIFT / require_shift`
      （字面调用）；
    - requant 乘子公式 = `quant_ref.scale_ratio_multiplier` + `quant_ref.REQUANT_Q`
      （**复用它的函数，不另写一份**）；
    - 校准参数（激活 `scale/zp`、权重 `s_w/z_w/q`（对称）、Resize scales、Reshape shape）=
      **字面复用** `quant_ref.Model`（与 C4a.2 的黄金参考**同一份**参数，不重推）。
  · `Transpose/Reshape` **折进寻址**：给每个消费者算 `(src_stride, src_order)`，**不产生单元**
    （写进 `wgt_index.json` 的 `layout_fold` 段；纯元数据）。
  · `Relu` 折进**生产者尾声**（冻结口径）：不占描述符；其**数值后果**落在生产者的 `M` 上 ——
    生产者的累加器**只做一次** requant 到「链上折进后的有效输出刻度」（`sy_eff`），
    见 `requant_fold_note`。`wgt_index.json` 同时给出不折的 `M_two_step`（= `quant_ref` 的逐节点口径）
    供 G3/C4a.4 对账。
  · 每层的 `IMG_W/IMG_H`：**conv 填输出尺寸**；**旁路算子填输出尺寸**；
    `IN_BYTES`：**一律填该单元实际要读的激活字节数**（`align32`）——
    conv 的 `IN_BYTES` 就是 `UnitExec` 的 `rdLen`（`rtl/UnitExec.scala:524`），
    旁路按 spec §3 的「旁路算子 `IN_BYTES` 填输入字节」口径（§3 的坑：冻结 `build_table`
    对旁路用的是 `align32(max(Σ读, 写))`，对 Resize/Add 会填成输出侧上界；本文件按 §3 改成输入侧）。
  · 表过 `validate`（字面调用）+ `pack/unpack` 往返 + 与 C4a.2 黄金（`c4a_ref_layers.json`）逐层对账。

============================================================================
Step 3：判据（`tools/run_convert_ab.sh`；每条都能被打红）
============================================================================
  1) `desc_table.validate` 通过 + `pack/unpack` 往返逐字段一致 + 独立字编码（`reference_words`）一致；
  2) 三态覆盖面表（覆盖/需主机旁路/不覆盖）与 **C3 冻结表逐项对账**（TYPE 直方图 / 载荷 67 /
     哨兵 68 / 旁路 4/2/2/6 / 融合 33 边 / 19 链 / 67 项 FLAGS 直方图）；
     `desc.bin` + `wgt_blob.bin` + `wgt_mult.bin` + `wgt_index.json` 记 md5/字节数；
  3) **负对照（必须发火）**：
     a. app 里改 1 个**权重**字节 ⇒ `wgt_blob.bin` 的 md5 必须变 **且** 与同口径参考的逐字节对账必须
        MISMATCH>0（证明"逐字节对账"不是橡皮章）；
     b. app 里改 1 个 **`M`** ⇒ `wgt_mult.bin` 的 md5 与 `requant_mult` 指纹必须变（§4.4 的新负对照）；
     c. `desc_count` 与哨兵不符 ⇒ `desc_table.validate` 必须**抛**（含"旧口径=表长含哨兵"那一档）。
  4) **§4.5 中心化的正/负对照（真网激活，字节级）**：
     正：取**非折进**的 conv 层（单元 `M` == 黄金节点口径），把真网激活码点喂进硬件算术
        （`Σ x_q·w_q + bias_adj`、pad=`z_pad`、`((acc·M)>>REQUANT_Q)>>SHIFT + z_y`、clamp）
        ⇒ 必须与黄金**逐字节一致**（`CENTER_EQUIV MISMATCH=0`），覆盖各 TYPE，含非零 `z_x` 的层；
     负 a：pad 用**字节 0** 代替 `z_pad` ⇒ MISMATCH>0；
     负 b：去掉 `−z_x·Σ w_q` 项（bias 不预调）⇒ MISMATCH>0；
     负 c：翻 1 bit 的 `z_pad` / `bias_adj` ⇒ `centering_fp`（进而是 `wgt_index.json` 指纹）必变。
  5) **★ H1 `SRC_ADDR` 折进（2026-10-12）**：被折进的源（`Relu` 尾声 / `Transpose-Reshape` 布局）
     没有自己的槽位 ⇒ 冻结建表器给的 `SRC_ADDR` 指向**从未被写过**的张量。本文件把每个消费者的
     `SRC_ADDR` 改到"生产者真正写过的 `DST_ADDR`"（`apply_src_addr_fold`）；
     正判据 `SRC_WRITTEN`：**每个 `SRC_ADDR` 都是表序更小描述符写过的 `DST`**（图输入除外）；
     负对照：改一条 `SRC_ADDR` 到"从未写过"的槽位 ⇒ `SRC_WRITTEN ok=0`（+ 红证据 `--inject badsrc ⇒ rc=1`）。
  6) **★★ A2（2026-10-16，spec `2026-10-16-y1-npu-v2-single-skeleton-design.md` §5.0）：
     宽 run 拆融合（de-fuse）** —— 真表 19 段极大链**全是宽的**（成员 C≠8；RTL `narrowShape` 为假），
     而 RTL 的**宽**路四条判据全带 `chain_len == 1` ⇒ 宽 run 在真帧上无通路（DISPATCH_ERR=54）。
     用户裁决：**宽 run 拆成 `plain`**（每成员一项、自己的几何），**窄 run 保留链**
     （RTL 窄链路径已逐字节验证、省流量）。
       · `defuse_wide_runs()`：扫 `head middle* tail` ⇒ run 里**只要有一个成员不是**
         `C_in==C_out==8 ∧ GROUP==1 ∧ 非 depthwise`（= RTL `narrowShape` 的镜像）⇒ **整段拆**：
         逐成员 `FLAGS := plain` + 写**自己的**几何（链首几何覆盖只对保留的窄链继续生效）；
       · 正判据 `DEFUSE_ALL_PLAIN`：被拆 run 的**每个**成员 `FLAGS==plain`；保留 run 必须全成员
         narrowShape 且 FLAGS 仍是合法 `head/middle*/tail`；判据与 `wgt_index.json` 的 `defuse` 段互证；
       · 负对照：把一个被拆成员的 `FLAGS` 塞回 `head` ⇒ 判据**必红**（+ 红证据 `--inject baddefuse ⇒ rc=1`）；
       · 随之而来的三件事（本文件逐条落实）：
         ① 中间张量**要有真实 DDR 地址** —— 实测（本文件闸门逐 run 断言）**每个链中/链尾的
            `SRC_ADDR` 恰 == 前一成员的 `DST_ADDR`**（冻结 bump arena 已逐张量分配，`chain_src_eq_prev_dst`
            19/19 成立）⇒ **分配器零改动**；高水位 `ARENA_TOP` 进判据（硬门：必须装进 NPU 预留区
            `0x8040_0000–0x8200_0000` = NPU `[0x0040_0000, 0x0200_0000)`）；
         ② H1 口径**简化**：`SRC_WRITTEN` 不再依赖"链中张量在描述符账上被写过"这一层间接
            （拆后每个中间张量**真的**由前驱写 DDR）；
         ③ 拆融合的**流量代价**由**冻结模型**（`ddr_traffic.py`，**只调用不编辑**）重新发出：
            `DEFUSE_TRAFFIC decoded_base==fuse_both / decoded_final==baseline`（两条都断言）。
  7) **★ A2 与 C3 冻结向量的差（强化版）**：合法差 = `{IN_BYTES, SRC_ADDR}`（全部项）
     ∪ `{FLAGS→plain, 6 个几何字段→own}`（**仅被拆的宽 run 成员**，且几何差只允许 middle/tail）；
     其余任何差 ⇒ `TABLE_DIFF_FIELDS_ALLOWED ok=0`（判据不放宽、只把 A2 的刻意差写死）。
  8) **★ A2 arena 硬门**：`ARENA_TOP`（冻结 bump 分配器高水位，NPU 地址）必须 ≤ `0x0200_0000`
     （= 物理 `0x8200_0000`，预留区上界）；超 ⇒ `ARENA_FIT ok=0`（**BLOCKED** 级）。

退出码：0 = PASS；1 = 判据红（mismatch）；2 = 负对照没发火；3 = 前置缺失。

用法（全仓唯一可用 Python 组合）：
    cd /d/code/PDS/VexiiYeshenLinux/y1
    PYTHONIOENCODING=utf-8 PYTHONPATH='./.pydeps;../third_party/yunet/deps' \
      /d/code/PDS/NaxYeshenLinux/sim/reglogs/lxvenv/Scripts/python.exe tools/y1_convert.py --gate
    bash y1/tools/run_convert_ab.sh
"""
import argparse
import hashlib
import json
import os
import struct
import sys
from collections import Counter

import numpy as np

# Windows 控制台是 GBK：非 ASCII 输出统一换成可替换字符。
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

# ---- 唯一真源（逐字复用；只读，绝不改）------------------------------------------------
import desc_table as dtab          # 位打包 / 哨兵 / 六规则 / 建表编码口径 / 独立字编码
import ddr_traffic as dt           # 算子序（GraphView.nodes）+ 融合枚举（find_fusion_pairs*）
import quant_ptq as ptq            # 量化口径（calibrate/affine_params/quant/dequant/SHIFT/require_shift）
import quant_ref as qref           # 同口径整网参考（校准参数 + requant 乘子公式 + REQUANT_Q）
import y1_caliber as ycal          # ★ S4-B：标定域 + Sigmoid 冻结 LUT 口径（宿主侧补正）

REQUANT_Q = qref.REQUANT_Q         # = 24（§4.4 冻结）
SHIFT = ptq.SHIFT                  # = 6（冻结；逐 conv 层 require_shift 断言）

# 故障注入（**只给红证据用**，绝不改上面的口径）：`--inject <name>`
#   noinbytes —— 跳过 spec §3 要求的 IN_BYTES 改写（⇒ 与 C3 冻结向量的差不止 IN_BYTES ⇒ 判据必须红）
#   nofold    —— 忽略 Relu 折进（⇒ folded_units=0 != 15 ⇒ 折进判据必须红）
#   nodiv     —— 关掉"改 1 个权重字节"的负对照（⇒ FIRED=0 ⇒ 退出码必须 2）
#   nobadorder —— 关掉 G5「反转 src_order」的负对照（⇒ FIRED=0 ⇒ --layout 退出码必须 2）
#   badsrc    —— H1：把某条 SRC_ADDR 打到一个"从未被写过"的槽位（⇒ SRC_WRITTEN ok=0 ⇒ 退出码必须 1）
#   badk      —— E1：把一个 Add 的 SRC2_K 改错（off-by-one）⇒ SRC2 判据必须红（退出码必须 1）
#   baddefuse —— A2：把一个**被拆的宽 run 成员**的 FLAGS 塞回 `head` ⇒ DEFUSE 判据必须红（退出码必须 1）
INJECTS = ("none", "noinbytes", "nofold", "nodiv", "nobadorder", "badsrc", "badk", "baddefuse")
INJECT = "none"

# ---- ★★ A2（2026-10-16）：NPU 预留区（物理 0x8040_0000–0x8200_0000 = NPU [0x0040_0000, 0x0200_0000)）----
#   来源：`tools/npu_frame_run.py` 的 H2/H2b 注释（DTS reserved-memory）与 spec §5.0。
ARENA_CARVE_NPU_LO = 0x00400000        # 物理 0x8040_0000
ARENA_CARVE_NPU_HI = 0x02000000        # 物理 0x8200_0000（预留区上界 = 内核 RAM 下界）

DEFAULT_ONNX = os.path.abspath(os.path.join(_HERE, "..", "..", "third_party", "yunet", "yunet.onnx"))
DEFAULT_REF = os.path.abspath(os.path.join(_HERE, "..", "reports", "c4a_ref_layers.json"))
DEFAULT_OUT = os.path.abspath(os.path.join(_HERE, "..", "gen"))
# ★★ S4-B（2026-10-17）：标定输入。缺省 = `quant_ref` 的合成 U[0,1)（既有闸门逐字节不变）；
#   给真图路径 ⇒ 用**与黄金同一张 0..255 真图**标定（修 D1：输入域 1/255 vs 1.0）。
CALIB_IMAGE = os.environ.get("Y1_CALIB_IMAGE") or None
SIG_FIX = os.environ.get("Y1_SIG_FIX", "1") != "0"      # 1 = 把 Sigmoid 钉到冻结 LUT 口径（D4）

# 不占描述符的算子：逐元素（折进生产者尾声）+ 布局（折进寻址）—— 与 desc_table 逐字同源
LAYOUT_OPS = ("Transpose", "Reshape")
FOLD_OPS = tuple(dtab.EPILOGUE_OPS)              # = dt.ELEMENTWISE_OPS 去掉 Sigmoid（Sigmoid 是旁路单元）
SKIP_OPS = FOLD_OPS + LAYOUT_OPS
CONV_TYPES = (dtab.TYPE_CONV3X3, dtab.TYPE_CONV1X1, dtab.TYPE_DEPTHWISE)

# ---- C3 冻结期望值（来源：spec §2/§3；reports/c3_descriptor_format.md §4.5 的逐字打印）----
#   这些是**外部**常量：本文件的判据拿**计算值**比它们（不是自己比自己）。
#   `reports/c3_descriptor_format.md:357` 逐字：conv3x3=7 conv1x1=26 depthwise=20 maxpool=4 resize=2 add=2 sigmoid=6
C3_TYPE_HIST_FROZEN = {dtab.TYPE_CONV3X3: 7, dtab.TYPE_CONV1X1: 26, dtab.TYPE_DEPTHWISE: 20,
                       dtab.TYPE_MAXPOOL: 4, dtab.TYPE_RESIZE: 2, dtab.TYPE_ADD: 2,
                       dtab.TYPE_SIGMOID: 6}
#   ONNX 图的算子直方图（spec §3 逐字：Conv53/Relu15/MaxPool4/Resize2/Add2/Transpose12/Reshape12/Sigmoid6）
ONNX_OP_HIST_FROZEN = {"Conv": 53, "Relu": 15, "MaxPool": 4, "Resize": 2, "Add": 2,
                       "Transpose": 12, "Reshape": 12, "Sigmoid": 6}

# ============================ 小工具 ============================
def md5_bytes(b):
    return hashlib.md5(b).hexdigest()


def md5_file(path):
    h = hashlib.md5()
    with open(path, "rb") as fh:
        for blk in iter(lambda: fh.read(65536), b""):
            h.update(blk)
    return h.hexdigest()


def sha1_text(s):
    return hashlib.sha1(s.encode("utf-8")).hexdigest()


def align32(n):
    return (n + 31) & ~31


def _hist(values):
    h = Counter(values)
    return dict(sorted(h.items()))


def chw_of_shape(s):
    """形状 → `(C, H, W, 元素数)`；**与 `desc_table._chw` 逐字同款**（4 维按 NCHW 丢 N，
    非 4 维按扁平单通道）。这里独立实现一遍，用于拿**黄金 JSON 的形状**做对账。"""
    if not s:
        return None
    n = 1
    for d in s:
        n *= d
    if len(s) == 4:
        return s[1], s[2], s[3], n
    return 1, 1, n, n


def rowmajor_strides(shape):
    st = [1] * len(shape)
    for i in range(len(shape) - 2, -1, -1):
        st[i] = st[i + 1] * shape[i + 1]
    return st


# ============================ 逐节点的自有几何（复用 desc_table 的冻结规则） ============================
def node_type_of(gv, n):
    """节点的 `(TYPE, GROUP)`：**字面复用** `desc_table._conv_type` 的判据（含 depthwise 提升），
    再做一次 3×3 + group==C_in==C_out>1 ⇒ depthwise 的同一提升（与 `build_table` 逐字同款）。"""
    if n.op_type == "Conv":
        tpe, grp = dtab._conv_type(n)
        ci = dtab._chw(gv, n.input[0])[0]
        co = dtab._chw(gv, n.output[0])[0]
        if tpe == dtab.TYPE_CONV3X3 and grp == ci == co and grp > 1:
            tpe = dtab.TYPE_DEPTHWISE
        return tpe, grp
    if n.op_type in dtab.BYPASS_TYPE:
        return dtab.BYPASS_TYPE[n.op_type], 1
    return None, None


def activation_inputs(gv, n, init_names):
    """该单元的**激活**输入张量（排除 initializer 常量；Resize 的 roi/scales、Reshape 的 shape 都不是）。"""
    out = []
    for t in n.input:
        if not t or t in init_names:
            continue
        s = gv.shape_of(t)
        if not s:
            continue
        out.append(t)
    return out


def tensor_elems(gv, t):
    s = gv.shape_of(t)
    if not s:
        return 0
    n = 1
    for d in s:
        n *= d
    return int(n)


def fold_chain(gv, n):
    """生产者 `n` 的输出经 **`Relu` 折进链**后的**有效输出张量**与折进的算子名。

    冻结口径（`desc_table.EPILOGUE_OPS`）：逐元素算子不占描述符，折进生产者的输出后处理。
    **单读者守卫**（与 `ddr_traffic.find_fusion_pairs` 的 N3 同源）：链上每个张量必须恰有 1 个
    消费者；否则中间张量被别处需要、必须落片 ⇒ **不折**（该生产者的输出刻度 = 自身刻度）。

    返回 `(有效输出张量名, [折进的算子名...])`；不折时 `(n.output[0], [])`。
    """
    cur = n.output[0]
    folded = []
    seen = set()
    while cur not in seen:
        seen.add(cur)
        cons = gv.consumers_of(cur)
        if len(cons) != 1:
            break
        nxt = gv.nodes[cons[0]]
        if nxt.op_type not in FOLD_OPS:
            break
        folded.append(nxt.name)
        cur = nxt.output[0]
    return cur, folded


# ============================ ★ H1：SRC_ADDR 折进（让每个源都指向"被写过的缓冲"）============================
# 根因（测自 B5 `555a387`）：`desc_table.build_table` 对每一项取 `SRC_ADDR = slot(node.input[0])`
# —— 这是**节点原始的输入张量**。但被折进的算子不占描述符：
#   · `Relu`（逐元素）折进**生产者尾声** ⇒ 生产者的 DST 落在自己的输出张量槽位，而消费者读的
#     `Relu` 输出张量**没有任何描述符写过**；
#   · `Transpose/Reshape`（布局）折进**寻址** ⇒ 消费者读的"折叠视图"张量同样**无人写**。
# ⇒ 表里 34 项的 `SRC_ADDR` 指向从未写过的槽位（6 个 Sigmoid + 28 个 Relu 消费者）。
# 这正是 `c4a_coverage.md` §O3（DST 侧）的 **SRC 侧孪生**。
#
# 修法（本任务）：对每个消费者，沿"被折进算子"的链**回溯**到第一个**占描述符**的生产者，
# 令 `SRC_ADDR := 该生产者的 DST_ADDR`（= `slot(源头真张量)`）。折进读必须是**连续展平**
# （Relu = 恒等；布局链需 `view` 的逐元素偏移恰为 0..N-1）——否则是 **B4/RTL 的 strided 读题目**，
# 转换器**响亮拒绝**（不静默产出一张读不对的表）。
def _fold_producer_map(gv):
    """张量 → 产出它的节点（折进链回溯用；与 `_layout_producer_map` 同款）。"""
    prod = {}
    for n in gv.nodes:
        for t in n.output:
            if t:
                prod[t] = n
    return prod


def _resolve_fold_source(gv, tensor, prod):
    """从消费者的输入张量 `tensor` 沿**被折进算子**回溯到第一个非折进张量。

    被折进 = `SKIP_OPS`（`Relu/Clip/...` 逐元素 + `Transpose/Reshape` 布局）。回溯到的张量若由某个
    **描述符**产出，则该消费者的 `SRC_ADDR` 必须 = 那个描述符的 `DST_ADDR`（这才是"被写过的缓冲"）。

    ★ 多读者不阻止寻址解：被折进的中间张量**没有自己的槽位**，它的字节就住在生产者的 DST 里；
      多个消费者**读同一段缓冲**是合法的（无论 Relu 的刻度是否折进，地址都一样）。刻度的折进口径
      另属 `requant_mult`/O1。
    返回 `(resolved_tensor, chain)`；`chain` = [{tensor,node,op}...]（外→内）。
    """
    chain = []
    cur = tensor
    seen = set()
    while cur not in seen:
        seen.add(cur)
        p = prod.get(cur)
        if p is None or p.op_type not in SKIP_OPS:
            break
        chain.append({"tensor": cur, "node": p.name, "op": p.op_type})
        cur = p.input[0]
    return cur, chain


def _fold_is_contiguous(gv, tensor):
    """折进读是否**连续展平**（⇒ 一条 SRC_ADDR 的线性读就能等价）。返回 `(ok, why)`。

    · 链上无布局算子（纯逐元素尾声，如 Relu）⇒ **恒等**，必连续；
    · 链上有 `Transpose/Reshape` ⇒ 用 `layout_addressing` 的 `(view_shape, src_stride)` 算逐元素偏移，
      必须恰为 `0..N-1`（= C4a.7 说的"这里退化成连续展平"）；否则是 strided 读（B4/RTL 题目）。
    """
    prod = _fold_producer_map(gv)
    nodes, _src_t = _layout_chain_nodes(gv, tensor, prod)
    if not nodes:
        return True, "identity（逐元素尾声折进）"
    view_shape, strides, _order = layout_addressing(gv, nodes)
    n = int(np.prod(view_shape))
    ax = np.indices(view_shape)
    lin = np.zeros(list(view_shape), dtype=np.int64)
    for k, st in enumerate(strides):
        lin = lin + ax[k] * int(st)
    ok = bool(np.array_equal(lin.reshape(-1), np.arange(n, dtype=np.int64)))
    return ok, "layout view=%s stride=%s order=%s" % (list(view_shape), list(strides), _order)


def apply_src_addr_fold(gv, descs, units):
    """★ H1：把每个消费者的 `SRC_ADDR` 改到它**生产者真正写过的** DST。返回改写清单。

    只对"源张量不是任何描述符的输出、且能回溯到某个描述符输出"的项动手（= 被折进的源）。
    图输入/常量（回溯到头也不是描述符输出）**保持原样**（主机提供）。
    """
    prod = _fold_producer_map(gv)
    out2idx = {}
    for i, u in enumerate(units):
        out2idx.setdefault(u["out_tensor"], i)
    rewrites = []
    for i, u in enumerate(units):
        it = u["in_tensor"]
        if it in out2idx:
            continue                                     # 源本就是某描述符的输出 ⇒ SRC 已 = 它 DST
        if prod.get(it) is None:
            continue                                     # 图输入/常量 ⇒ 主机提供
        resolved, chain = _resolve_fold_source(gv, it, prod)
        if resolved not in out2idx:
            continue                                     # 回溯到头仍是外部 ⇒ 保持原样
        ok, why = _fold_is_contiguous(gv, it)
        if not ok:
            raise SystemExit("FATAL: 单元 %d(%s) 的源折进不是连续展平（%s）；"
                             "strided 读属 B4/RTL 题目，转换器拒绝"
                             % (i, u["name"], why))
        j = out2idx[resolved]
        new_src = descs[j]["DST_ADDR"]
        if descs[i]["SRC_ADDR"] != new_src:
            rewrites.append({"desc_idx": i, "unit": u["name"], "op": u["op"],
                             "in_tensor": it, "chain": [c["node"] for c in chain],
                             "chain_ops": [c["op"] for c in chain],
                             "producer": units[j]["name"], "producer_idx": j,
                             "old_src": int(descs[i]["SRC_ADDR"]), "new_src": int(new_src)})
            descs[i]["SRC_ADDR"] = int(new_src)
    return rewrites


def _descriptor_sourced_indices(gv, units):
    """`units` 里"源是某描述符的输出（直接或经折进回溯）"的下标（= SRC_ADDR 必须被改对/查对的那批）。"""
    o2i = {}
    for j, u in enumerate(units):
        o2i.setdefault(u["out_tensor"], j)
    prod = _fold_producer_map(gv)
    idxs = []
    for i, u in enumerate(units):
        it = u["in_tensor"]
        if it in o2i:
            idxs.append(i)
        elif prod.get(it) is not None and _resolve_fold_source(gv, it, prod)[0] in o2i:
            idxs.append(i)
    return idxs


def check_src_written(gv, descs, units):
    """★ H1 正判据：**每一项的 `SRC_ADDR` 都必须是更早（表序更小）描述符写过的 DST**。

    例外：源是**图输入/常量**（主机提供，不经描述符）⇒ 允许。
    返回 `{"checked", "external", "offenders": [...]}`（offender 逐条打印给判据）。
    """
    prod = _fold_producer_map(gv)
    out2idx = {}
    for i, u in enumerate(units):
        out2idx.setdefault(u["out_tensor"], i)
    written = set()
    external = 0
    offenders = []
    for i, d in enumerate(descs):
        src = int(d["SRC_ADDR"])
        it = units[i]["in_tensor"]
        src_is_desc_out = it in out2idx
        if not src_is_desc_out and prod.get(it) is not None:
            resolved, _ch = _resolve_fold_source(gv, it, prod)
            src_is_desc_out = resolved in out2idx
        if src_is_desc_out:
            if src not in written:
                # 找出本该写它的生产者的 DST（若已折进，改写后必相等；不等 ⇒ offender）
                offenders.append({"desc_idx": i, "unit": units[i]["name"], "op": units[i]["op"],
                                  "src": src, "in_tensor": it})
        else:
            external += 1
        written.add(int(d["DST_ADDR"]))
    return {"checked": len(descs), "external": external, "offenders": offenders}


# ============================ ★ E1：`Add` 第二路源的「表内偏移」约定（2026-10-13）============================
# 背景：`Add` 是唯一双输入单元，冻结格式只有**一个** `SRC_ADDR`（O1）。E1 用 **`w3[31:16]`**
#   这段**真正闲置**的保留位编 `SRC2_K`（见 spec §4.6）：
#     · `SRC2_K == 0` ⇒ 没有第二路源（缺省；所有非 `Add` 项恒为 0）；
#     · `SRC2_K == k > 0` ⇒ 仅 `Add` 有意义：第二路源 = **表序下行 `k` 位那条描述符的 `DST_ADDR`**。
#   `pack` 不搬运 w3 高位（不是 14 字段之一）⇒ 本文件在 `pack_table` 之后按**字偏移** OR 进去；
#   8 字格式 / `FIELD_ORDER` / `pack`·`unpack` 往返**一字未改**。
def resolve_add_src2(gv, descs, units, payload_nodes, init_names):
    """★ E1：为每个 `Add` 解析第二路真激活输入 → 表内偏移 `k = 本表序 − 生产者表序`。返回记录列表。

    第 2 路 = ONNX `node.input[1]` 里那个真激活（`input[0]` 就是 `units[i]["in_tensor"]`）；沿
    **被折进链**（Relu/布局）回溯到第一个**占描述符**的生产者（与 H1 的 `_resolve_fold_source` 同款）
    ⇒ `k = i − j`。要求 `k ≥ 1`；回溯不到描述符输出 ⇒ **响亮拒绝**（不静默产出读不对的表）。
    """
    prod = _fold_producer_map(gv)
    out2idx = {}
    for i, u in enumerate(units):
        out2idx.setdefault(u["out_tensor"], i)
    recs = []
    for i, u in enumerate(units):
        if u["op"] != "Add":
            continue
        n = payload_nodes[i]
        ins = [t for t in n.input if t and t not in init_names and gv.shape_of(t)]
        if len(ins) < 2:
            raise SystemExit("FATAL: Add %d(%s) 只有 %d 路真激活输入（需要 2）" % (i, u["name"], len(ins)))
        t2 = ins[1]
        resolved, chain = _resolve_fold_source(gv, t2, prod)
        if resolved not in out2idx:
            raise SystemExit("FATAL: Add %d(%s) 的第 2 路源 %s 回溯不到描述符输出" % (i, u["name"], t2))
        j = out2idx[resolved]
        k = i - j
        if k <= 0:
            raise SystemExit("FATAL: Add %d(%s) 的第 2 路生产者表序 %d 不小于自己 %d（k=%d）"
                             % (i, u["name"], j, i, k))
        recs.append({"desc_idx": i, "unit": u["name"], "second_tensor": t2,
                     "chain": [c["node"] for c in chain], "chain_ops": [c["op"] for c in chain],
                     "producer": units[j]["name"], "producer_idx": j, "k": int(k),
                     "src2_addr": int(descs[j]["DST_ADDR"])})
    return recs


def read_src2k(desc_blob, ndesc):
    """从**已落字的描述符字节**里读回每项的 `SRC2_K`（`w3[31:16]`，小端字 3）—— 判据读**产物**而非内存 dict。"""
    k_of = {}
    for i in range(ndesc):
        w3 = struct.unpack_from("<I", bytes(desc_blob), i * dtab.DESC_BYTES + 12)[0]
        k_of[i] = (w3 >> 16) & 0xFFFF
    return k_of


def check_src2(gv, units, payload_nodes, init_names, k_of):
    """★ E1 正判据：`Add` 的 `k` 必须 == `表序 − 图推导的生产者表序`（且 ≥ 1）；**非 `Add` 必须 == 0**。

    返回 `{"adds","offenders"}`（offender 逐条打印给判据）。这条比"地址被写过"更强：它钉的是
    **语义正确的那条生产者**（改 k ⇒ 立刻红），而不是"某个被写过的地址"。
    """
    prod = _fold_producer_map(gv)
    out2idx = {}
    for i, u in enumerate(units):
        out2idx.setdefault(u["out_tensor"], i)
    offenders = []
    adds = 0
    for i, u in enumerate(units):
        k = int(k_of.get(i, 0))
        if u["op"] != "Add":
            if k != 0:
                offenders.append({"desc_idx": i, "unit": u["name"], "op": u["op"], "k": k, "want": 0})
            continue
        adds += 1
        n = payload_nodes[i]
        ins = [t for t in n.input if t and t not in init_names and gv.shape_of(t)]
        t2 = ins[1] if len(ins) >= 2 else None
        j = None
        if t2 is not None:
            resolved, _ch = _resolve_fold_source(gv, t2, prod)
            j = out2idx.get(resolved)
        want = (i - j) if j is not None else None
        if want is None or k != want or k < 1:
            offenders.append({"desc_idx": i, "unit": u["name"], "op": u["op"], "k": k, "want": want,
                              "producer": (units[j]["name"] if j is not None else None)})
    return {"adds": adds, "offenders": offenders}


# ============================ ★★ A2：宽 run 拆融合（de-fuse；spec §5.0）============================
# 背景（spec §5.0 的裁决记录）：真表 19 段极大链**全部是宽的**（成员 `C≠8`）⇒ RTL 的**宽**路
# （`wideGeomOk`/`wgtLoadOk`/`tilingOkC`/`tilingWideC` 全带 `chain_len == 1`）在真帧上**无通路**
# （`frame_preflight` 的 DISPATCH_ERR=54）。用户裁决 = **宽 run 拆成 `plain`**（复用已逐字节
# 验证的"宽单点"路径），**窄 run 保留链**（窄链路径已逐字节验证、且省流量）。
#
# 判据（本文件的 `--gate` + 新负对照）：
#   · `DEFUSE_ALL_PLAIN`  —— 被拆 run 的每个成员 `FLAGS==plain`；保留 run 全成员 narrowShape
#     且 FLAGS 仍是合法 `head middle* tail`（与 `wgt_index.json` 的 `defuse` 段互证）；
#   · `CHAIN_ADDRS`       —— 每个 run（拆前）逐成员 `SRC == 前一成员 DST`（中间张量有真实地址；
#     冻结 bump arena 的分配证据）；
#   · `DEFUSE_TRAFFIC`    —— **调用**冻结 `ddr_traffic` 的两个 strategy：拆后表的按-flag 流量
#     == `baseline`（拆融合的代价，**实测口径**），拆前（冻结向量）== `fuse_both`（两向都断言）；
#   · `ARENA_FIT`         —— 分配器高水位 ≤ 预留区上界（NPU `0x0200_0000`）；
#   · `NEGCTL_DEFUSE_HEAD`—— 把一个被拆成员塞回 `head` ⇒ 判据必红（在闸门里当场发火）。

def own_geometry(gv, n, init_names):
    """载荷节点的**自有几何**（与主循环里 `own` 逐字同源：几何取输出张量、`C_IN` 取输入张量；
    `TYPE/GROUP` 走 `node_type_of`，含 depthwise 提升）。

    ★ 含 `QUANT_SHIFT`（= `desc_table.QUANT_SHIFT_BY_TYPE[TYPE]`，冻结口径；conv 类恒 6）——
    拆融合要把 `CHAIN_GEOM_FIELDS` 六个字段**整个**写成 own，QUANT_SHIFT 必须在同一份字典里
    （不许"按链首抄一份"这种口径混入）。"""
    tpe, grp = node_type_of(gv, n)
    ins = activation_inputs(gv, n, init_names)
    in_t, out_t = ins[0], n.output[0]
    img_w, img_h, c_in, c_out = dtab._geom(gv, in_t, out_t)
    return {"TYPE": tpe, "IMG_W": img_w, "IMG_H": img_h, "C_IN": c_in, "C_OUT": c_out, "GROUP": grp,
            "QUANT_SHIFT": dtab.QUANT_SHIFT_BY_TYPE[tpe]}


def narrow_shape_of(own):
    """RTL `narrowShape` 的 Python 镜像（`rtl/UnitExec.scala:1384-1385` 逐字同式）：

        `C_in == C_out == 8 ∧ GROUP == 1 ∧ 非 depthwise`
        （= 窄通路能表示的那个形状；其余一律走宽通路 ⇒ 宽路的 `chain_len == 1` 前提把链挡住）。
    ★ 与 `frame_preflight.unit_exec()` 的 `narrow` 同式 —— 两处独立实现，闸门拿它交叉对账。
    """
    return (own["C_IN"] == 8 and own["C_OUT"] == 8 and own["GROUP"] == 1
            and own["TYPE"] != dtab.TYPE_DEPTHWISE)


def run_spans(descs):
    """FLAGS 扫描：`(plain | head middle* tail)*` ⇒ `[(head_idx, length), ...]`。

    与冻结校验器 `desc_table.validate` 规则 (5) 和 `rtl/LayerSched.scala` 的 CHAINSCAN 同口径；
    非法结构（head 无 tail / middle、tail 无前驱）⇒ **响亮拒绝**（不静默产出别的形状）。
    """
    spans = []
    i, n = 0, len(descs)
    while i < n:
        f = descs[i]["FLAGS"] & dtab.FLAGS_SEMANTIC_MASK
        if f == dtab.FLAGS_PLAIN:
            spans.append((i, 1))
            i += 1
            continue
        if f in (dtab.FLAGS_MIDDLE, dtab.FLAGS_TAIL):
            raise SystemExit("FATAL: A2 扫链失败：%s 无前驱 @%d（表结构非法）"
                             % ("middle" if f == dtab.FLAGS_MIDDLE else "tail", i))
        j = i
        while j < n and (descs[j]["FLAGS"] & dtab.FLAGS_SEMANTIC_MASK) in (dtab.FLAGS_HEAD,
                                                                          dtab.FLAGS_MIDDLE):
            j += 1
        if j >= n or (descs[j]["FLAGS"] & dtab.FLAGS_SEMANTIC_MASK) != dtab.FLAGS_TAIL:
            raise SystemExit("FATAL: A2 扫链失败：head 无 tail @%d（表结构非法）" % i)
        spans.append((i, j - i + 1))
        i = j + 1
    return spans


def defuse_wide_runs(gv, descs, payload_nodes, init_names):
    """★★ A2：把**宽 run**（run 里只要有一个成员不是 RTL `narrowShape`）逐成员拆成 `plain`。

    · 摊开（de-fuse）时逐成员写**自己的**几何（链首几何覆盖**不再**作用于被拆成员）；
    · **窄 run 原样保留**（它能在 RTL 上跑且省流量）；
    · 返回记录（进 `wgt_index.json` 的 `defuse` 段 + 闸门判据）—— 表里一个字节都不假装：
      `runs` 逐段记 `{head, len, defused, members:[{idx,name,narrow,own}]}`。
    """
    spans = run_spans(descs)
    rec = {"runs": [], "defused_runs": 0, "defused_members": 0,
           "kept_runs": 0, "kept_members": 0, "wide_members": 0, "narrow_members": 0,
           "policy": "宽 run（任一成员非 narrowShape: C_in==C_out==8∧GROUP==1∧非dw）整段拆成 plain；"
                     "窄 run 保留 head middle* tail"}
    for (h, L) in spans:
        if L == 1:
            continue                                   # plain 单点：不是链，无需记录
        members = []
        all_narrow = True
        for t in range(h, h + L):
            n = payload_nodes[t]
            own = own_geometry(gv, n, init_names)
            nr = narrow_shape_of(own)
            all_narrow &= nr
            members.append({"idx": t, "name": n.name, "narrow": bool(nr), "own": own})
        for m in members:
            if m["narrow"]:
                rec["narrow_members"] += 1
            else:
                rec["wide_members"] += 1
        if all_narrow:
            rec["kept_runs"] += 1
            rec["kept_members"] += L
            rec["runs"].append({"head": h, "len": L, "defused": False, "members": members})
            continue
        # 宽 run ⇒ 整段拆：逐成员 FLAGS := plain + 写自己的几何
        for m in members:
            d = descs[m["idx"]]
            d["FLAGS"] = dtab.FLAGS_PLAIN
            for k in dtab.CHAIN_GEOM_FIELDS:
                d[k] = int(m["own"][k])
        rec["defused_runs"] += 1
        rec["defused_members"] += L
        rec["runs"].append({"head": h, "len": L, "defused": True, "members": members})
    return rec


def check_defuse(descs, defuse):
    """A2 正判据：被拆 run 的每个成员 `FLAGS==plain`；保留 run 全成员 narrowShape 且
    FLAGS 仍是合法 `head middle* tail`；记录与表逐项互证。返回 offender 列表（空 = 绿）。"""
    offenders = []
    for r in defuse["runs"]:
        for k, m in enumerate(r["members"]):
            fl = descs[m["idx"]]["FLAGS"] & dtab.FLAGS_SEMANTIC_MASK
            if r["defused"]:
                if fl != dtab.FLAGS_PLAIN:
                    offenders.append({"idx": m["idx"], "name": m["name"],
                                      "why": "被拆宽 run 成员应为 plain，实际 0b%02d" % fl})
            else:
                want = (dtab.FLAGS_HEAD if k == 0 else
                        (dtab.FLAGS_TAIL if k == r["len"] - 1 else dtab.FLAGS_MIDDLE))
                if not m["narrow"] or fl != want:
                    offenders.append({"idx": m["idx"], "name": m["name"],
                                      "why": "保留窄 run 成员应 narrow 且 FLAGS=0b%02d，实际 narrow=%d 0b%02d"
                                             % (want, 1 if m["narrow"] else 0, fl)})
    return offenders


def check_chain_addrs(descs, defuse):
    """A2 地址判据：每个 run（拆前结构）逐成员 `SRC == 前一成员 DST` —— 中间张量有**真实**地址
    （冻结 bump arena 已逐张量分配；拆后每个成员成为真 DDR 写-读对）。返回 (checked, bad)。"""
    checked, bad = 0, []
    for r in defuse["runs"]:
        for k in range(1, r["len"]):
            a = descs[r["members"][k - 1]["idx"]]["DST_ADDR"]
            b = descs[r["members"][k]["idx"]]["SRC_ADDR"]
            checked += 1
            if a != b:
                bad.append({"run_head": r["head"], "member": r["members"][k]["idx"],
                            "src": b, "prev_dst": a})
    return checked, bad


def defuse_traffic(gv, descs, payload_nodes, init_names):
    """A2 流量判据的**译码侧**：按表的 FLAGS 复算 conv 侧 DDR 流量（head 只计读、tail 只计写、
    plain/middle 各自计）—— 与冻结 `ddr_traffic.compute_rows_fused` 同式（那条口径的逐字节镜像）。"""
    tot = 0
    for n, d in zip(payload_nodes, descs):
        if n.op_type != "Conv":
            continue
        ins = activation_inputs(gv, n, init_names)
        b_in = tensor_elems(gv, ins[0])
        b_out = tensor_elems(gv, n.output[0])
        fl = d["FLAGS"] & dtab.FLAGS_SEMANTIC_MASK
        tot += (b_in if fl in (dtab.FLAGS_HEAD, dtab.FLAGS_PLAIN) else 0)
        tot += (b_out if fl in (dtab.FLAGS_PLAIN, dtab.FLAGS_TAIL) else 0)
    return tot



def build(onnx_path):
    """产出 `(descs, info, index, blobs)`。

    表 = **字面调用** `desc_table.build_table(gv)`（零重推）；本函数只做三件事：
      ① 按表序把权重落成 blob（`N_i = C_out*(C_in/GROUP)*9`，冻结布局）；
      ② 算每项的 requant 乘子 `M`（复用 `quant_ref.scale_ratio_multiplier`）；
      ③ 收集索引元数据（供 G6/G2/G1），并把 `IN_BYTES` 按 spec §3 口径改成"输入激活字节数"。
    """
    gv = dt.GraphView(onnx_path)
    descs, info = dtab.build_table(gv)          # ★ 冻结建表器（含 FLAGS 链角色 + 链首几何覆盖）

    # 校准参数：字面复用 quant_ref.Model（与 C4a.2 的黄金**同一份**参数）
    # ★★ S4-B：`CALIB_IMAGE` 给出时用**真图（0..255）**标定 —— 与驱动的输入码点同域。
    if CALIB_IMAGE:
        ref = qref.Model(onnx_path, synth=ycal.calib_nchw(CALIB_IMAGE))
    else:
        ref = qref.Model(onnx_path)
    ref.build_params()
    act, wts = ref.act, ref.weights
    # ★★ S4-B（D4）：把 6 个 Sigmoid 的输入/输出刻度钉到 SigmoidUnit 冻结 LUT 的 Q3.4/Q0.7。
    sig_fix = ycal.apply_sigmoid_fix(act, ref.nodes) if SIG_FIX else []
    print("CALIBER calib_image=%s sig_fix=%d (%s)" % (
        CALIB_IMAGE or "synth U[0,1)", len(sig_fix),
        ",".join(c["sigmoid"] for c in sig_fix)))
    init_names = set(ref.init.keys())

    # 载荷节点（= 表序，与 build_table 的 `order` 逐字同源：跳过逐元素/布局算子）
    payload_nodes = [n for n in gv.nodes if n.op_type not in SKIP_OPS]
    if len(payload_nodes) != len(descs):
        raise SystemExit("FATAL: 载荷节点数 %d != 表项数 %d" % (len(payload_nodes), len(descs)))

    # ---- ★★ A2（2026-10-16，spec §5.0）：**宽 run 拆融合** —— 宽 run 逐成员改写成 `plain`，窄 run 保留链 ----
    defuse = defuse_wide_runs(gv, descs, payload_nodes, init_names)
    defused_members = set(m["idx"] for r in defuse["runs"] if r["defused"] for m in r["members"])
    if INJECT == "baddefuse":                     # 故障注入：把一个被拆成员塞回 `head` ⇒ DEFUSE 判据必红
        kd = next(iter(sorted(defused_members)))
        for r in defuse["runs"]:
            if r["defused"]:
                kd = r["members"][-1]["idx"]      # 最靠后成员（原来不是链首 ⇒ 是"故意塞进来的 head"）
                break
        descs[kd]["FLAGS"] = dtab.FLAGS_HEAD

    gv_in = getattr(ref, "input_name", None)
    if gv_in:
        act.setdefault(gv_in, act.get(gv_in))

    blob = bytearray()
    mult_words = []
    units = []
    requant = []
    centering_units = []                           # §4.5：逐消费权重的单元的 z_pad/bias_adj/刻度
    img_ins = []                                   # 每项：该单元要读的激活输入张量
    for i, (n, d) in enumerate(zip(payload_nodes, descs)):
        tpe, grp = node_type_of(gv, n)
        if tpe != d["TYPE"]:
            raise SystemExit("FATAL: 表项 %d 的 TYPE 0x%02x != 自有判据 0x%02x（%s）"
                             % (i, d["TYPE"], tpe, n.name))
        # ---- 自有几何（`build_table` 的 `_geom` 口径：几何取输出张量、C_IN 取输入张量）----
        ins = activation_inputs(gv, n, init_names)
        in_t, out_t = ins[0], n.output[0]
        own = own_geometry(gv, n, init_names)      # ★ A2：与拆融合 pass 同一份实现（单一真源）

        # ---- 权重 blob（只 conv 类消费权重）----
        wgt = None
        bias = None
        if n.op_type == "Conv":
            wname = n.input[1]
            bname = n.input[2] if len(n.input) > 2 else None
            arr = ref.init[wname]
            # ★ §4.5-A（2026-10-11 裁决）：权重**对称**量化 —— **消费黄金的**权重
            #   （`quant_ref.Model.build_params` 用 `weight_params/quant_weight` 产出：
            #    z_w ≡ 0、s_w = max|w|/127、w_q ∈ [−127,127]），本文件不重推。
            wref = wts.get(wname)
            if wref is None:
                raise SystemExit("FATAL: 单元 %d(%s) 的权重 %s 不在 quant_ref 权重表里" % (i, n.name, wname))
            sw, zw = float(wref["scale"]), int(wref["zp"])
            q = np.asarray(wref["q"], dtype=np.int8)
            # 自证：同一对称口径由冻结 `quant_ptq.weight_params/quant_weight` 重算 ⇒ 必须与黄金逐字节一致
            sw2, zw2 = ptq.weight_params(arr)
            q2 = ptq.quant_weight(arr, sw2)
            sym_ok = bool(zw == 0 and zw2 == 0 and float(sw) == float(sw2)
                          and np.array_equal(q, q2))
            if not sym_ok:
                raise SystemExit("FATAL: 单元 %d(%s) 黄金权重非对称 / 与 weight_params 不符"
                                 "（z_w=%d/%d s_w=%r/%r）" % (i, n.name, zw, zw2, sw, sw2))
            co_, cg_, kh_, kw_ = q.shape
            n_i = int(co_ * cg_ * 9)                            # 冻结：N_i = C_out*(C_in/GROUP)*9（真实）
            # ★ 2026-10-12（B0）：物理段长 = ceil32(N_i)（DdrMaster 的 src%32/len%32 契约，spec §4.2 修订）
            n_i_al = align32(n_i)
            # 冻结布局 `weightAddr = co*(C_in/GROUP)*9 + ciLocal*9 + ky*3 + kx`（spec §3）
            # 1×1 核 → 单抽头落在 (ky,kx)=(0,0)；其余 8 个抽头填 **0**
            #   （§4.5-A：z_w ≡ 0 ⇒「中心化零」的码点就是 0 ⇒ 补位天然零贡献；与旧口径「填 z_w」至此重合）。
            padded = np.zeros((co_, cg_, 9), dtype=np.int8)
            for ky in range(kh_):
                for kx in range(kw_):
                    padded[:, :, ky * 3 + kx] = q[:, :, ky, kx]
            off = len(blob)                                     # 起点 = Σ_{j<i} N_j'（前一单元已补齐 ⇒ 恒 32 B 对齐）
            blob += padded.tobytes()                            # 段内 [0, N_i)：真实权重
            blob += b"\x00" * (n_i_al - n_i)                    # 段内 [N_i, N_i')：补 0
            ptq.require_shift(n.name, SHIFT)                    # ★ 冻结：逐层 shift == 6
            wgt = {"name": wname, "shape": [int(v) for v in arr.shape], "dtype": str(arr.dtype),
                   "scale": float(sw), "zp": int(zw), "elems": int(arr.size),
                   "nbytes": n_i, "aligned_bytes": n_i_al, "offset": off,
                   "md5": md5_bytes(padded.tobytes()),
                   "pad_taps": int(n_i - arr.size), "align_pad": int(n_i_al - n_i), "pad_value": int(zw),
                   "symmetric": True, "matches_quant_ref": sym_ok}
            # bias：**不进 blob**（冻结的 8 字描述符没有 bias 字段；`quant_ref` 把 bias 折进
            # "累加器单位" `round(bias/(s_x·s_w))`）⇒ 这里只记**名字/形状/md5**，供 C4a.5/C4b 定位。
            if bname:
                ba = np.ascontiguousarray(ref.init[bname], dtype=np.float32)
                bias = {"name": bname, "shape": [int(v) for v in ba.shape],
                        "dtype": str(ba.dtype), "md5": md5_bytes(ba.tobytes()),
                        "in_blob": False}

            # ---- §4.5 中心化元数据（z_pad / bias_adj / 刻度；逐单元）----
            #   z_w ≡ 0 ⇒ w_q 本身即中心化权重；补位值 = 真 0 的码点 z_x；
            #   bias_adj = round(bias/(s_x·s_w)) − z_x·Σ_all-taps w_q（每输出通道一个常数）。
            sx_c = float(act[in_t]["scale"])
            zx_c = int(act[in_t]["zp"])
            sy_c = float(act[out_t]["scale"])
            zy_c = int(act[out_t]["zp"])
            sum_wq = np.asarray(padded, dtype=np.int64).reshape(co_, -1).sum(axis=1)   # 每通道全抽头和
            if bname is not None:
                barr = np.asarray(ref.biases[bname], dtype=np.float64).reshape(-1)
                # 与黄金 `conv_vec` 逐字同源：np.round(bias/(s_x·s_w))（banker's rounding）
                b0 = np.round(barr / (sx_c * float(sw))).astype(np.int64)
            else:
                b0 = np.zeros(co_, dtype=np.int64)
            bias_adj = b0 - np.int64(zx_c) * sum_wq
            centering_units.append({
                "layer_id": i, "name": n.name, "in_tensor": in_t, "out_tensor": out_t,
                "s_x": sx_c, "z_x": zx_c, "z_pad": zx_c,
                "s_w": float(sw), "z_w": int(zw),
                "s_y": sy_c, "z_y": zy_c,
                "bias_name": bname,
                "sum_w_q_all_taps": [int(v) for v in sum_wq],
                "bias_round": [int(v) for v in b0],
                "bias_adj": [int(v) for v in bias_adj],
                "bias_adj_formula": "round(bias/(s_x*s_w)) - z_x*sum_all_taps(w_q)",
            })

        # ---- requant 乘子 M（复用 quant_ref.scale_ratio_multiplier）----
        out_eff, folded = fold_chain(gv, n)
        if INJECT == "nofold":                                 # 故障注入：忽略 Relu 折进
            out_eff, folded = n.output[0], []
        sx = float(act[in_t]["scale"])
        sy_eff = float(act[out_eff]["scale"]) if out_eff in act else float(act[out_t]["scale"])
        sy_own = float(act[out_t]["scale"])
        # §4.5：给中心化条目补硬件口径的**有效输出刻度**（与 requant_mult 的 `M` 同源）
        if centering_units and centering_units[-1]["layer_id"] == i:
            centering_units[-1]["s_y_eff"] = float(sy_eff)
            centering_units[-1]["z_y_eff"] = int(act[out_eff]["zp"]) if out_eff in act else int(act[out_t]["zp"])
        m2_info = None
        if tpe in CONV_TYPES:
            ratio = (sx * float(wgt["scale"])) / sy_eff
            ratio_own = (sx * float(wgt["scale"])) / sy_own
        elif tpe in (dtab.TYPE_MAXPOOL, dtab.TYPE_RESIZE):
            ratio = sx / sy_eff                     # 无权重 ⇒ s_w = 1（与 quant_ref 逐字同款）
            ratio_own = sx / sy_own
        elif tpe == dtab.TYPE_ADD:
            sb = float(act[n.input[1]]["scale"])
            ratio = sx / sy_eff
            ratio_own = sx / sy_own
            m2_info = {"M2": qref.scale_ratio_multiplier(sb / sy_eff),
                       "M2_two_step": qref.scale_ratio_multiplier(sb / sy_own),
                       "ratio2": sb / sy_eff}
        elif tpe == dtab.TYPE_SIGMOID:
            ratio = 0.0                             # Sigmoid 走 256 项 LUT（无 requant 乘子）
            ratio_own = 0.0
        else:
            raise SystemExit("FATAL: 未知 TYPE 0x%02x（%s）" % (tpe, n.name))
        M_f = qref.scale_ratio_multiplier(ratio) if ratio else 0
        M_o = qref.scale_ratio_multiplier(ratio_own) if ratio_own else 0
        if not (0 <= M_f < (1 << 32)):
            raise SystemExit("FATAL: 单元 %d 的 M=%d 超出 32 bit（%s）" % (i, M_f, n.name))
        mult_words.append(struct.pack("<I", M_f))
        requant.append({"layer_id": i, "M": int(M_f), "REQUANT_Q": int(REQUANT_Q),
                        "name": n.name, "op": n.op_type, "type": dtab.TYPE_NAME.get(tpe, "?"),
                        "ratio": float(ratio), "M_two_step": int(M_o),
                        "folded_ops": list(folded), "sy_eff": float(sy_eff),
                        "sy_own": float(sy_own)})
        if m2_info:
            requant[-1].update(m2_info)

        # ---- IN_BYTES：该单元实际要读的**激活**字节数（spec §3 的坑；conv 即 UnitExec 的 rdLen）----
        in_bytes_frozen = int(d["IN_BYTES"])
        in_bytes_expected = align32(max(tensor_elems(gv, t) for t in ins)) if ins else 0
        in_bytes = in_bytes_expected
        if INJECT == "noinbytes":                              # 故障注入：不做 spec §3 的改写
            in_bytes = in_bytes_frozen
        if in_bytes_expected == 0:
            raise SystemExit("FATAL: 单元 %d(%s) 的 IN_BYTES 算成 0" % (i, n.name))
        d["IN_BYTES"] = int(in_bytes)
        if d["LAYER_ID"] != i:
            raise SystemExit("FATAL: 表项 %d 的 LAYER_ID=%d != 表序（乘子索引必须 = 表序）"
                             % (i, d["LAYER_ID"]))

        img_ins.append([in_t, out_t])
        units.append({"idx": i, "name": n.name, "op": n.op_type,
                      "type": dtab.TYPE_NAME.get(tpe, "?"), "type_code": int(tpe),
                      "flags": int(d["FLAGS"]),
                      "flags_name": {0: "head", 1: "plain", 2: "middle", 3: "tail"}[d["FLAGS"] & 3],
                      "defused_wide_run": bool(i in defused_members),
                      "layer_id": i, "own": own,
                      "table_geom": {k: int(d[k]) for k in dtab.CHAIN_GEOM_FIELDS},
                      "in_bytes": int(in_bytes), "in_bytes_frozen": in_bytes_frozen,
                      "in_bytes_expected": int(in_bytes_expected),
                      "in_tensor": in_t, "out_tensor": out_t,
                      "weight": wgt, "bias": bias, "folded_ops": list(folded), "out_eff_tensor": out_eff,
                      "M": int(M_f)})

    mult_blob = b"".join(mult_words)

    # ---- ★ H1：SRC_ADDR 折进 —— 让每个源都指向"生产者真正写过的缓冲"（治 §O3 的 SRC 侧孪生）----
    src_fold = apply_src_addr_fold(gv, descs, units)
    if INJECT == "badsrc":                        # 故障注入：把某条 SRC 打到"从未写过"的槽位
        k = _descriptor_sourced_indices(gv, units)[0]
        descs[k]["SRC_ADDR"] = 0x0F000000          # 32B 对齐、在 28bit 窗内、但在 arena 之外（无人写）
    # ---- ★ E1（2026-10-13）：Add 第二路源的「表内偏移」k → w3[31:16]（保留位，8 字不变；spec §4.6）----
    src2_recs = resolve_add_src2(gv, descs, units, payload_nodes, init_names)
    if INJECT == "badk" and src2_recs:            # 故障注入：把一个 Add 的 k 改错（off-by-one）⇒ 判据必红
        src2_recs[0]["k"] = int(src2_recs[0]["k"]) + 1
    desc_blob = bytearray(dtab.pack_table(descs))
    for r in src2_recs:                           # `pack` 不搬 w3 高位 ⇒ 按**字偏移** OR 进去
        off = r["desc_idx"] * dtab.DESC_BYTES + 12
        w3 = struct.unpack_from("<I", desc_blob, off)[0]
        struct.pack_into("<I", desc_blob, off, w3 | ((int(r["k"]) & 0xFFFF) << 16))
    desc_blob = bytes(desc_blob)
    full = descs + [dict(dtab.SENTINEL)]

    # ---- 布局折进寻址（Transpose/Reshape）：给每个消费者算 (src_stride, src_order)，不产生单元 ----
    layout_fold = compute_layout_fold(gv)

    index = {
        "artifact": "wgt_index.json",
        "contract": {
            "table_seq_eq_blob_seq": "desc 表序 == 权重 blob 序（R4 对冲：wgt_index + G6 blob 指纹 + G2 逐层对账）",
            "weight_layout": "weightAddr = co*(C_out 轴)*(C_in/GROUP)*9 + ciLocal*9 + ky*3 + kx（spec §3 冻结）",
            "N_i": "N_i = C_out*(C_in/GROUP)*9（**真实**字节数，逐单元；1×1 核的其余 8 抽头补 **0** —— "
                   "§4.5-A：z_w≡0，中心化零的码点就是 0）。★ 2026-10-12（B0）**物理**段长 = "
                   "`aligned_bytes = ceil32(N_i)`，段起点 = Σ_{j<i} aligned_bytes（每单元段 32 B 对齐、补位 **0**）"
                   "—— 主口 DdrMaster 的 `src%32==0 && len%32==0` 契约（C3.3）；见 spec §4.2「布局修订」。",
            "blob_layout": "aligned：offset_i = Σ_{j<i} ceil32(N_j)，段内 [0,N_i) 真实 / [N_i,ceil32(N_i)) 补 0；"
                           "nbytes=真实、aligned_bytes=物理；blob 总长 = Σ ceil32(N_i)",
            "mult_region": "M 区紧随权重 blob（offset_in_mailbox = blob.bytes），每项 1 个 32-bit 小端字，"
                           "下标 = 表序 = 描述符 w7 的 LAYER_ID；走 WGT_ADDR/WGT_DATA/WGT_WE 信箱",
            "requant": "y = clamp( ((acc*M) >> REQUANT_Q) >> SHIFT + z_y, -128, 127 )；SHIFT=6 REQANT_Q=24",
            "centering": "§4.5-A：权重对称（z_w≡0）⇒ w_q 即中心化权重；pad = z_pad(=z_x)；"
                         "bias_adj = round(bias/(s_x·s_w)) − z_x·Σ_all-taps w_q；"
                         "hw: acc = Σ x_q·w_q + bias_adj ≡ 黄金 Σ(x_q−z_x)w_q + round(bias/(s_x·s_w))。"
                         "见 `centering` 段（逐消费权重的单元）",
        },
        "model": {"onnx": onnx_path, "md5": md5_file(onnx_path)},
        "table": {"file": "desc.bin", "bytes": len(desc_blob), "md5": md5_bytes(desc_blob),
                  "payload": len(descs), "items": len(full),
                  "desc_count": dtab.desc_count_of(full),
                  "sentinel_index": len(full) - 1},
        "blob": {"file": "wgt_blob.bin", "bytes": len(blob), "md5": md5_bytes(bytes(blob)),
                 "units": sum(1 for u in units if u["weight"] is not None),
                 "sum_N": int(sum(u["weight"]["nbytes"] for u in units if u["weight"] is not None)),
                 "sum_N_aligned": int(sum(u["weight"]["aligned_bytes"] for u in units if u["weight"] is not None)),
                 "pad_overhead": int(sum(u["weight"]["aligned_bytes"] - u["weight"]["nbytes"]
                                         for u in units if u["weight"] is not None)),
                 "align": 32},
        "mult": {"file": "wgt_mult.bin", "bytes": len(mult_blob), "md5": md5_bytes(mult_blob),
                 "words": len(mult_words), "requant_q": int(REQUANT_Q),
                 "offset_in_mailbox": len(blob)},
        "units": units,
        "requant_mult": requant,
        "centering": centering_units,
        "layout_fold": layout_fold,
        "src_addr_fold": src_fold,
        "src2_add": src2_recs,
        "defuse": defuse,
    }
    index["fingerprints"] = {
        "desc_md5": index["table"]["md5"],
        "blob_md5": index["blob"]["md5"],
        "mult_md5": index["mult"]["md5"],
        "mailbox_bytes": len(blob) + len(mult_blob),
        "mailbox_md5": md5_bytes(bytes(blob) + mult_blob),
        "requant_fp": requant_fp(requant),
        "centering_fp": centering_fp(centering_units),
        "units_fp": sha1_text(json.dumps(units, ensure_ascii=False, sort_keys=True)),
    }
    blobs = {"desc": desc_blob, "blob": bytes(blob), "mult": mult_blob}
    return descs, info, index, blobs, full, ref, gv, payload_nodes, units, requant


def requant_fp(requant):
    """`requant_mult` 段（只取决定性的三个键）的指纹 —— §4.4 负对照"改 1 个 M ⇒ 指纹必须变"。"""
    core = [{"layer_id": r["layer_id"], "M": r["M"], "REQUANT_Q": r["REQUANT_Q"]} for r in requant]
    return sha1_text(json.dumps(core, sort_keys=True))


def centering_fp(centering):
    """`centering` 段（只取决定性的三个键）的指纹 —— §4.5 负对照"翻 1 bit 的 z_pad/bias_adj ⇒ 必变"。"""
    core = [{"layer_id": c["layer_id"], "z_pad": c["z_pad"], "bias_adj": c["bias_adj"]} for c in centering]
    return sha1_text(json.dumps(core, sort_keys=True))


def compute_layout_fold(gv):
    """`Transpose/Reshape` 折进寻址：给**每个消费者**算 `(src_stride, src_order)`，**不产生单元**。

    - `src_tensor/src_shape`：布局链**源头**的真张量（真正在 DDR 里按行主序存的）；
    - `src_stride`：把源头张量按行主序索引时，**消费侧每条轴**的元素步长；
    - `src_order`：链上**最后一个** `Transpose` 的轴序（`null` = 该位置由 `Reshape` 收尾、线性序不变）；
    - `view_shape`：消费侧看到的形状（折进寻址读出的张量形状）；
    - 口径与 `layout_addressing`（C4a.7/G5 的验证器）**逐字同源** ⇒ 闸门比的就是同一条口径。
    """
    prod = _layout_producer_map(gv)
    out = []
    for n in gv.nodes:
        for t in n.input:
            if not t or t not in prod:
                continue
            nodes, src_t = _layout_chain_nodes(gv, t, prod)
            if not nodes:
                continue
            src_shape = list(gv.shape_of(src_t) or [])
            view_shape, strides, order = layout_addressing(gv, nodes)
            out.append({"consumer": n.name, "consumer_op": n.op_type,
                        "dst_tensor": t, "dst_shape": gv.shape_of(t),
                        "layout_ops": [p.name for p in nodes],
                        "src_tensor": src_t, "src_shape": src_shape,
                        "src_stride": strides, "src_order": order,
                        "view_shape": view_shape})
    return out


# ============================ 布局折进寻址的验证（C4a.7 / G5） ============================
# 口径：`Transpose/Reshape` **折进寻址** = 消费者按 `src_stride` 直接 strided 读生产者的
# **线性 DDR 缓冲**，不落中间张量、不产生描述符单元、不产生额外 DDR 搬运。下面把这条口径
# 钉死（判据 = `tools/run_layout_ab.sh`）：
#   · layout_addressing —— 从布局链（源头→外）算 `(view_shape, src_stride, src_order)`；
#   · folded_read       —— 折进寻址的"读"（把线性源头张量按步长索引出 view_shape 的张量）；
#   · layout_verify     —— 判据 1：逐个位置比：折进读 == 显式转置/重排参考（逐字节）；
#   · layout_traffic    —— 判据 2：折进的 DDR 读+写 == 0；"不折进"（显式单元）读+写 = Σ(n_in+n_out)；
#   · layout_negctl     —— 判据 3：把 `src_order` 写反 ⇒ 必须红。

def _layout_producer_map(gv):
    """张量 → 产出它的节点（布局链回溯用）。"""
    prod = {}
    for n in gv.nodes:
        for t in n.output:
            if t:
                prod[t] = n
    return prod


def _layout_chain_nodes(gv, tensor, prod):
    """从消费者输入张量 `tensor` 反向收集布局链，返回 `(nodes_src_to_out, src_tensor)`。"""
    chain = []
    cur = tensor
    while True:
        p = prod.get(cur)
        if p is None or p.op_type not in LAYOUT_OPS:
            break
        chain.append(p)
        cur = p.input[0]
    return list(reversed(chain)), cur


def _layout_transpose_perm(node, ndim, reverse_perm=False):
    """`Transpose` 的轴序（`perm` 缺省 = 全反转）；`reverse_perm=True` 把它**写反**（负对照）。"""
    perm = dtab._node_int_attr(node, "perm", None)
    if perm is None:
        perm = list(range(ndim - 1, -1, -1))
    perm = list(perm)
    if reverse_perm:
        perm = list(reversed(perm))
    return perm


def layout_addressing(gv, nodes, reverse_perm=False):
    """从布局链（源头→外）算折进寻址 `(view_shape, src_stride, src_order)`。

    `reverse_perm=True` 把每个 `Transpose` 的 `perm` 写反（G5 负对照）。
    """
    src_shape = list(gv.shape_of(nodes[0].input[0]) or [])
    shape, strides = list(src_shape), rowmajor_strides(src_shape)
    order = None
    for p in nodes:
        if p.op_type == "Transpose":
            perm = _layout_transpose_perm(p, len(shape), reverse_perm)
            shape = [shape[k] for k in perm]
            strides = [strides[k] for k in perm]
            order = list(perm)
        else:                                          # Reshape：线性序不变 ⇒ 步长按新形状重算
            shape = list(gv.shape_of(p.output[0]) or shape)
            strides = rowmajor_strides(shape)
            order = None
    return shape, strides, order


def layout_apply_chain(src, nodes, gv, reverse_perm=False):
    """显式 numpy 参考：把布局链（源头→外）逐算子执行（`Transpose` 用 `perm`、`Reshape` 用推断形状）。
    `reverse_perm=True` 把每个 `Transpose` 的 `perm` 写反（负对照）。"""
    x = src
    for p in nodes:
        if p.op_type == "Transpose":
            x = np.transpose(x, _layout_transpose_perm(p, x.ndim, reverse_perm))
        else:
            x = np.reshape(x, list(gv.shape_of(p.output[0])))
    return x


def folded_read(src, view_shape, src_stride):
    """折进寻址的**读**：`src` 是源头真张量的**线性存储**（生产者写进 DDR 的缓冲）；消费侧按
    `src_stride`（每条轴在源头线性缓冲里的元素步长）索引出 `view_shape` 张量 —— 这正是
    "Transpose/Reshape 折进寻址"的硬件语义（消费者直接 strided 读生产者缓冲，不落中间张量）。"""
    flat = np.ascontiguousarray(src).reshape(-1)
    ax = np.indices(view_shape)
    lin = np.zeros(list(view_shape), dtype=np.int64)
    for k, st in enumerate(src_stride):
        lin = lin + ax[k] * int(st)
    return flat[lin]


def _layout_src_samples(src_shape):
    """确定性源头样本：① 唯一 id（排列级敏感，任何寻址错都显形）② int8 字节图案（"逐字节"口径）。"""
    n = 1
    for d in src_shape:
        n *= int(d)
    ids = np.arange(n, dtype=np.int64).reshape(src_shape)
    pat = ((np.arange(n) * 181 + 97) & 0xFF).astype(np.uint8).view(np.int8).reshape(src_shape)
    return ids, pat, n


def layout_verify(gv):
    """G5 判据 1：每个含 `Transpose/Reshape` 的位置，**折进寻址的读 == 显式转置参考**（逐字节）。"""
    prod = _layout_producer_map(gv)
    rows = []
    for idx, e in enumerate(compute_layout_fold(gv)):
        nodes, _src_t = _layout_chain_nodes(gv, e["dst_tensor"], prod)
        ids, pat, n = _layout_src_samples(e["src_shape"])
        exp_ids = layout_apply_chain(ids, nodes, gv)
        exp_pat = layout_apply_chain(pat, nodes, gv)
        got_ids = folded_read(ids, e["view_shape"], e["src_stride"])
        got_pat = folded_read(pat, e["view_shape"], e["src_stride"])
        shape_ok = (list(exp_ids.shape) == list(e["view_shape"]) and
                    list(exp_pat.shape) == list(e["view_shape"]))
        mm_id = int(np.count_nonzero(exp_ids.reshape(-1) != got_ids.reshape(-1)))
        mm_pat = int(np.count_nonzero(exp_pat.reshape(-1) != got_pat.reshape(-1)))
        rows.append({"idx": idx, "consumer": e["consumer"], "consumer_op": e["consumer_op"],
                     "ops": e["layout_ops"], "src": e["src_tensor"], "src_shape": list(e["src_shape"]),
                     "view_shape": list(e["view_shape"]), "src_stride": list(e["src_stride"]),
                     "src_order": e["src_order"], "elems": n, "shape_ok": shape_ok,
                     "mm_id": mm_id, "mm_pat": mm_pat, "mismatch": mm_id + mm_pat})
    return rows


def layout_traffic(gv):
    """G5 判据 2：折进寻址后布局算子的 DDR 读+写 == **0**（无额外搬运）；"不折进"对照 = 每个布局
    算子当**显式单元**：读输入 + 写输出。口径复用**冻结** `ddr_traffic.GraphView`（激活 int8、
    1 字节/元素；numel = C*H*W）。另给整网锚：冻结模型的推荐调度 `fuse_both`（本就不含布局算子）
    ± Σ(布局搬运)。"""
    ops = [n for n in gv.nodes if n.op_type in LAYOUT_OPS]
    rows = []
    ur = uw = 0
    for n in ops:
        ni, no = tensor_elems(gv, n.input[0]), tensor_elems(gv, n.output[0])
        ur += ni
        uw += no
        rows.append({"op": n.name, "type": n.op_type, "in": n.input[0], "out": n.output[0],
                     "n_in": ni, "n_out": no})
    net = sum(r.traffic for r in dt.STRATEGIES["fuse_both"](gv))
    return {"ops": rows, "folded_read": 0, "folded_write": 0,
            "unfolded_read": ur, "unfolded_write": uw,
            "folded_total": 0, "unfolded_total": ur + uw,
            "net_folded": net, "net_unfolded": net + ur + uw}


def layout_negctl(gv, disable=False):
    """G5 判据 3：把 `src_order` 写反 ⇒ 必须红。对每个 `src_order != None` 的位置（折进寻址由
    `Transpose` 轴序驱动），用**写反的轴序**重建寻址，与**正确的显式参考**逐字节比 ⇒ MISMATCH 必 > 0。
    `disable=True` 时改回正确轴序（故障注入 ⇒ MISMATCH=0 ⇒ `--layout` 退出码必须 2）。"""
    prod = _layout_producer_map(gv)
    rows = []
    for e in compute_layout_fold(gv):
        if e["src_order"] is None:
            continue
        nodes, _src_t = _layout_chain_nodes(gv, e["dst_tensor"], prod)
        ids, _pat, _n = _layout_src_samples(e["src_shape"])
        correct = folded_read(ids, e["view_shape"], e["src_stride"])
        if disable:
            bview, bstride, border = list(e["view_shape"]), list(e["src_stride"]), e["src_order"]
        else:
            bview, bstride, border = layout_addressing(gv, nodes, reverse_perm=True)
        bad = folded_read(ids, bview, bstride)
        mm = int(np.count_nonzero(correct.reshape(-1) != bad.reshape(-1)))
        rows.append({"consumer": e["consumer"], "src_order": e["src_order"], "rev_order": border,
                     "mismatch": mm, "stride_changed": list(bstride) != list(e["src_stride"])})
    return rows


def layout_gate(args):
    """G5 布局折进寻址闸门（C4a.7）：折进==显式（逐字节）+ 搬运不增 + 反转 src_order 负对照。"""
    gv = dt.GraphView(args.onnx)
    entries = compute_layout_fold(gv)
    rows = layout_verify(gv)
    trav = layout_traffic(gv)
    neg = layout_negctl(gv, disable=(INJECT == "nobadorder"))

    n_t = sum(1 for n in gv.nodes if n.op_type == "Transpose")
    n_r = sum(1 for n in gv.nodes if n.op_type == "Reshape")
    n_src = len({e["src_tensor"] for e in entries})
    print("LAYOUT_FOLD entries=%d ops_transpose=%d ops_reshape=%d srcs=%d"
          % (len(entries), n_t, n_r, n_src))
    for r in rows:
        print("LAYOUT_POS idx=%d consumer=%-14s op=%-9s ops=%-32s src=%-4s src_shape=%-14s "
              "stride=%-22s order=%-12s view=%-14s elems=%d shape_ok=%d MISMATCH=%d"
              % (r["idx"], r["consumer"], r["consumer_op"], ",".join(r["ops"]), r["src"],
                 r["src_shape"], r["src_stride"], r["src_order"], r["view_shape"],
                 r["elems"], 1 if r["shape_ok"] else 0, r["mismatch"]))
    n_exact = sum(1 for r in rows if r["shape_ok"] and r["mismatch"] == 0)
    mm_tot = sum(r["mismatch"] for r in rows)
    elems = sum(r["elems"] for r in rows)
    print("LAYOUT_EQUIV entries=%d byte_exact=%d MISMATCH_total=%d elems=%d"
          % (len(rows), n_exact, mm_tot, elems))

    not_inc = trav["folded_total"] <= trav["unfolded_total"]
    print("LAYOUT_TRAFFIC_FOLDED read=%d write=%d total=%d"
          % (trav["folded_read"], trav["folded_write"], trav["folded_total"]))
    print("LAYOUT_TRAFFIC_UNFOLDED read=%d write=%d total=%d"
          % (trav["unfolded_read"], trav["unfolded_write"], trav["unfolded_total"]))
    print("LAYOUT_TRAFFIC ops=%d folded_total=%d unfolded_total=%d delta=%d not_increased=%d"
          % (len(trav["ops"]), trav["folded_total"], trav["unfolded_total"],
             trav["unfolded_total"] - trav["folded_total"], 1 if not_inc else 0))
    print("LAYOUT_TRAFFIC_NET fuse_both_folded=%d fuse_both_unfolded=%d delta=%d"
          % (trav["net_folded"], trav["net_unfolded"], trav["net_unfolded"] - trav["net_folded"]))
    for i, o in enumerate(trav["ops"]):
        print("LAYOUT_TRAFFIC_OP idx=%d op=%-14s type=%-9s in=%-4s out=%-4s n_in=%d n_out=%d"
              % (i, o["op"], o["type"], o["in"], o["out"], o["n_in"], o["n_out"]))

    reversible = sum(1 for e in entries if e["src_order"] is not None)
    fired = sum(1 for r in neg if r["mismatch"] > 0)
    print("NEGCTL_LAYOUT_ORDER reversible=%d fired=%d trivial_insensitive=%d"
          % (reversible, fired, len(entries) - reversible))
    for r in neg:
        print("NEGCTL_LAYOUT_ORDER_DETAIL consumer=%-14s src_order=%s rev=%s stride_changed=%d mismatch=%d"
              % (r["consumer"], r["src_order"], r["rev_order"],
                 1 if r["stride_changed"] else 0, r["mismatch"]))

    # 判据 0：不产生单元 —— 载荷节点数 == 冻结期望（= Σ C3 TYPE 直方图 = 67），且无布局算子进载荷。
    pay = [n for n in gv.nodes if n.op_type not in SKIP_OPS]
    lay_in_pay = [n for n in pay if n.op_type in LAYOUT_OPS]
    exp_pay = sum(C3_TYPE_HIST_FROZEN.values())
    print("LAYOUT_NO_UNITS payload_nodes=%d expected=%d layout_in_payload=%d onnx_T=%d onnx_R=%d"
          % (len(pay), exp_pay, len(lay_in_pay), n_t, n_r))

    # 与持久化索引对账（外部产物 `gen/wgt_index.json` 的 `layout_fold` 段）。
    idx_path = os.path.join(args.out, "wgt_index.json")
    idx_ok, idx_n, idx_src, idx_named = 1, 0, "absent", 0
    if os.path.exists(idx_path):
        with open(idx_path, encoding="utf-8") as fh:
            ix = json.load(fh)
        lf = ix.get("layout_fold", [])
        idx_n, idx_src = len(lf), "gen/wgt_index.json"
        norm = lambda e: (e["consumer"], tuple(e["src_stride"]),
                          tuple(e["src_order"]) if e["src_order"] else None, tuple(e["view_shape"]))
        idx_ok = 1 if ([norm(e) for e in entries] == [norm(e) for e in lf]
                       and idx_n == len(entries)) else 0
        idx_named = sum(1 for u in ix.get("units", [])
                        if u.get("name", "").startswith(("Transpose", "Reshape")))
    print("LAYOUT_INDEX_AGREE ok=%d entries=%d recomputed=%d units_layout_named=%d src=%s"
          % (idx_ok, idx_n, len(entries), idx_named, idx_src))

    # ---------------- 判决 ----------------
    problems, neg_fail = [], []
    if not rows:
        problems.append("没有任何含 Transpose/Reshape 的位置（退化）")
    if mm_tot != 0 or n_exact != len(rows):
        problems.append("折进寻址 != 显式参考（MISMATCH_total=%d byte_exact=%d/%d）"
                        % (mm_tot, n_exact, len(rows)))
    if any(r["elems"] == 0 for r in rows):
        problems.append("有位置的元素数为 0（退化）")
    if not not_inc:
        problems.append("折进反而增加了 DDR 读+写（%d > %d）"
                        % (trav["folded_total"], trav["unfolded_total"]))
    if trav["unfolded_total"] == 0:
        problems.append("不折进对照的搬运量为 0（负对照无意义）")
    if len(pay) != exp_pay or lay_in_pay:
        problems.append("布局算子进了描述符载荷（payload=%d expected=%d layout_in_payload=%d）"
                        % (len(pay), exp_pay, len(lay_in_pay)))
    if idx_ok != 1 or idx_named != 0:
        problems.append("与 gen/wgt_index.json 的 layout_fold 不一致或出现布局命名单元（ok=%d named=%d）"
                        % (idx_ok, idx_named))
    if reversible == 0:
        neg_fail.append("没有可反转的 src_order（负对照无意义）")
    if fired != reversible:
        neg_fail.append("反转 src_order 未全部发火（fired=%d / reversible=%d）" % (fired, reversible))

    print("==========================================================================")
    if problems:
        for p in problems:
            print("JUDGE-RED: %s" % p)
        print("RESULT: FAIL")
        return 1
    if neg_fail:
        for p in neg_fail:
            print("NEGCTL-FAIL: %s" % p)
        print("RESULT: FAIL")
        return 2
    print("布局折进寻址（C4a.7/G5）：%d 个位置（Transpose %d + Reshape %d，源头 %d 张）折进 "
          "(src_stride, src_order) —— 折进==显式逐字节（MISMATCH=0）；折进搬运 %d B vs 不折进 %d B"
          "（不增）；反转 src_order %d/%d 发火"
          % (len(rows), n_t, n_r, n_src, trav["folded_total"], trav["unfolded_total"], fired, reversible))
    print("RESULT: PASS")
    return 0


# ============================ 与 C4a.2 黄金参考逐层对账 ============================
def cross_check_ref(ref_json, gv, descs, payload_nodes, units):
    """表 vs `c4a_ref_layers.json`（G2 精神：**外部**黄金，不是自己比自己）。

    1) **层序**：`json.layers` 去掉逐元素/布局算子后的子序列，必须与表序**逐项同名同算子**；
    2) **几何**：链首/plain 项的 `(C_IN,C_OUT,IMG_W,IMG_H)` 必须等于黄金的形状（按 `_chw` 口径）；
       链中/链尾项的**表内几何 = 链首**（冻结口径），其**自有几何**另记进 `wgt_index.json`；
    3) **权重**：blob 读回 + 同 `(scale,zp)` 反量化，必须复现黄金参考量化出来的权重（逐字节 + 逐点）。
    """
    with open(ref_json, encoding="utf-8") as fh:
        ref = json.load(fh)
    layers = ref["layers"]
    shape_of = {}
    for r in layers:
        shape_of[r["tensor"]] = list(r["shape"])
    # 图输入不在 layers 里（它没有产出它的节点）
    for vi in gv.graph_input_names:
        s = gv.shape_of(vi)
        if s:
            shape_of.setdefault(vi, list(s))

    kept = [r for r in layers if r["op"] not in SKIP_OPS]
    problems = []
    if [r["name"] for r in kept] != [n.name for n in payload_nodes]:
        problems.append("层序不一致：kept=%d payload=%d" % (len(kept), len(payload_nodes)))
    if len(kept) != len(descs):
        problems.append("黄金载荷 %d != 表项 %d" % (len(kept), len(descs)))

    n_head_plain = 0
    n_chain = 0
    for i, (r, d, n) in enumerate(zip(kept, descs, payload_nodes)):
        own_ci = chw_of_shape(shape_of.get(n.input[0])) if shape_of.get(n.input[0]) else None
        own_co = chw_of_shape(shape_of.get(r["tensor"]))
        if own_co is None or own_ci is None:
            problems.append("项 %d(%s) 的黄金形状缺失" % (i, r["name"]))
            continue
        exp = (own_ci[0], own_co[0], own_co[2], own_co[1])     # (C_IN, C_OUT, IMG_W, IMG_H)
        if (d["FLAGS"] & 3) in (dtab.FLAGS_HEAD, dtab.FLAGS_PLAIN):
            n_head_plain += 1
            got = (d["C_IN"], d["C_OUT"], d["IMG_W"], d["IMG_H"])
            if got != exp:
                problems.append("项 %d(%s) 几何 %s != 黄金 %s" % (i, r["name"], got, exp))
            if d["TYPE"] != units[i]["own"]["TYPE"]:
                problems.append("项 %d(%s) TYPE 与自有几何不符" % (i, r["name"]))
        else:
            n_chain += 1
            # 链中/链尾：表内几何必须等于**链首**（validate 规则 (5) 已管）；这里核对自有几何已记账
            if tuple(units[i]["own"][k] for k in ("C_IN", "C_OUT", "IMG_W", "IMG_H")) != exp:
                problems.append("项 %d(%s) 自有几何记账与黄金不符" % (i, r["name"]))
    return {"kept": len(kept), "golden_checked": n_head_plain, "chain_members": n_chain,
            "problems": problems}


def cross_check_weights(blob, units, ref, mut_blob=None):
    """blob 读回 → 同 `(scale,zp)` 反量化 → 必须复现黄金参考量化出来的权重。

    `mut_blob` 给了就检查**变异的 blob**（负对照：必须 MISMATCH>0）。
    逐单元返回 `(checked, mismatch, pad_bad)`：
      · `mismatch` = 真实抽头的码点与参考 `q` 不等的**单元数**；
      · `pad_bad`  = 补位抽头不是 `z_w` 的单元数。
        ★ §4.5-A（2026-10-11）：权重对称 ⇒ 黄金 `r["zp"] ≡ 0`，**补位填 0 与填 `z_w` 至此重合**
          （两者的码点都是 0）；判据用黄金的 `r["zp"]` 作期望 ⇒ `z_w≠0` 的口径若复现即红。
    """
    b = blob if mut_blob is None else mut_blob
    checked = mismatch = pad_bad = 0
    for u in units:
        w = u["weight"]
        if w is None:
            continue
        checked += 1
        seg = np.frombuffer(b[w["offset"]:w["offset"] + w["nbytes"]], dtype=np.int8)
        pad = seg.reshape(-1, 9)                       # (CO*CG, 9) —— 冻结布局：每 (co,ci) 占 9 字节
        r = ref.weights[w["name"]]
        q = r["q"]                                     # (CO, CG, kh, kw)
        co, cg, kh, kw = q.shape
        real = np.empty((co, cg, kh, kw), dtype=np.int8)
        for ky in range(kh):
            for kx in range(kw):
                real[:, :, ky, kx] = pad[:, ky * 3 + kx].reshape(co, cg)
        if not np.array_equal(real, q):
            mismatch += 1
        # 本网只有 1×1 / 3×3 核 ⇒ 真实抽头恒落在下标 0..kh*kw-1（3×3 填满；1×1 只用 (0,0)）
        assert kh * kw in (1, 9), "冻结布局的口径只覆盖 1×1/3×3 核（收到 %dx%d）" % (kh, kw)
        if kh * kw < 9 and not np.all(pad[:, kh * kw:] == np.int8(r["zp"])):
            pad_bad += 1
        # 反量化复现（黄金口径：dequant(code, s_w, z_w)）
        if not np.allclose(ptq.dequant(real, w["scale"], w["zp"]),
                           ptq.dequant(q, r["scale"], r["zp"]), rtol=0, atol=0):
            mismatch += 1
    return {"checked": checked, "mismatch": mismatch, "pad_bad": pad_bad}


# ============================ §4.5 中心化：真网字节级等价复核 ============================
def hw_conv_variants(x_q, wseg, pads, strides, KH, KW, group, z_pad, bias_ok, bias_raw, M, z_y):
    """硬件「中心化」算术的三个变体（同一段真网激活 / 权重，§4.5-A）：

      · ok   ：pad = `z_pad`（= z_x），bias = `bias_adj`  → **应**逐字节复现黄金；
      · pad0 ：pad = **字节 0**，bias = `bias_adj`        → 负对照 a（必须 MISMATCH>0）；
      · drop ：pad = `z_pad`，bias = `bias_raw`（无 −z_x·Σw_q 项）→ 负对照 b（必须 MISMATCH>0）。

    算术逐字：`acc = Σ x_q·w_q`（补位按给定码点）+ bias；
              `y = clamp( ((acc·M) >> REQUANT_Q) >> SHIFT + z_y, -128, 127 )`。
    `wseg`：(CO, CG, 9) int8（冻结布局；1×1 核的其余 8 抽头为 0 ⇒ 零贡献）。
    """
    pt, pl, pb, pr = pads
    sh, sw = strides
    CI, H, W = x_q.shape[1], x_q.shape[2], x_q.shape[3]
    CO, CG, _ = wseg.shape
    Ho = (H + pt + pb - KH) // sh + 1
    Wo = (W + pl + pr - KW) // sw + 1
    cog, cig = CO // group, CI // group

    def run(padval, badj):
        xp = np.pad(x_q.astype(np.int64), ((0, 0), (0, 0), (pt, pb), (pl, pr)),
                    constant_values=int(padval))
        acc = np.zeros((CO, Ho, Wo), dtype=np.int64)
        for gi in range(group):
            for cil in range(cig):
                ca = gi * cig + cil
                for ky in range(KH):
                    for kx in range(KW):
                        xs = xp[0, ca, ky:ky + sh * Ho:sh, kx:kx + sw * Wo:sw]
                        wcol = wseg[gi * cog:(gi + 1) * cog, cil, ky * 3 + kx].astype(np.int64)
                        acc[gi * cog:(gi + 1) * cog] += wcol[:, None, None] * xs
        acc += np.asarray(badj, dtype=np.int64)[:, None, None]
        y = ((acc * np.int64(M)) >> REQUANT_Q) >> SHIFT
        return np.clip(y + np.int64(z_y), -128, 127).astype(np.int8).reshape(1, CO, Ho, Wo)

    return run(z_pad, bias_ok), run(0, bias_ok), run(z_pad, bias_raw)


def center_equiv(ref, blob, units, requant, centering):
    """§4.5 正/负对照（真网激活，字节级）：硬件中心化算术 == 黄金？

    取**非折进**的 conv 单元（其 `M` == 黄金节点口径 `M_two_step`），用**黄金整网**在该层输入张量上的
    真激活码点 `x_q`、真权重（blob 读回）、`z_pad`/`bias_adj`（`centering` 段）走硬件算术
    ⇒ 逐字节复现黄金该节点输出。返回逐单元明细 + 两种负对照的 MISMATCH 汇总。
    """
    params = {"act": ref.act, "weights": ref.weights, "biases": ref.biases,
              "rsz_scales": ref.rsz_scales, "reshape_shape": ref.reshape_shape}
    T, _ = qref.run_net(ref, params, naive=False)
    node_by_name = {n.name: n for n in ref.nodes}
    req = {r["layer_id"]: r for r in requant}
    cent = {c["layer_id"]: c for c in centering}

    # 选层：非折进的 conv 单元（"单元自己的 M" == 黄金节点口径），按 TYPE 各取至多 2 个
    sel = []
    seen_type = {}
    for u in units:
        if u["weight"] is None:
            continue
        if req[u["idx"]]["folded_ops"]:
            continue                                    # 折进单元：单元 M != 黄金节点口径（见报告 O1）
        t = u["type_code"]
        if seen_type.get(t, 0) >= 2:
            continue
        seen_type[t] = seen_type.get(t, 0) + 1
        sel.append(u)

    rows = []
    mism_ok = mism_pad0 = mism_drop = 0
    elems = nz = 0
    for u in sel:
        idx = u["idx"]
        n = node_by_name[u["name"]]
        in_t, out_t = u["in_tensor"], u["out_tensor"]
        x_q = np.asarray(T[in_t], dtype=np.int8)
        y_gold = np.asarray(T[out_t], dtype=np.int8)
        c = cent[idx]
        w = u["weight"]
        co = u["own"]["C_OUT"]
        cg = u["own"]["C_IN"] // u["own"]["GROUP"]
        wseg = np.frombuffer(blob[w["offset"]:w["offset"] + w["nbytes"]],
                             dtype=np.int8).reshape(co, cg, 9)
        KH, KW = int(w["shape"][2]), int(w["shape"][3])          # 与黄金 conv_vec 同源（取权重形状）
        pads = qref.attr_ints(n, "pads", [0, 0, 0, 0])
        strides = qref.attr_ints(n, "strides", [1, 1])
        grp = qref.attr_int(n, "group", 1)
        y_ok, y_pad0, y_drop = hw_conv_variants(x_q, wseg, pads, strides, KH, KW, grp,
                                                c["z_pad"], c["bias_adj"], c["bias_round"],
                                                int(req[idx]["M"]), int(c["z_y"]))
        m_ok = int(np.count_nonzero(y_ok != y_gold))
        m_pad0 = int(np.count_nonzero(y_pad0 != y_gold))
        m_drop = int(np.count_nonzero(y_drop != y_gold))
        mism_ok += m_ok
        mism_pad0 += m_pad0
        mism_drop += m_drop
        elems += int(y_gold.size)
        if c["z_x"] != 0:
            nz += 1
        rows.append({"layer_id": idx, "name": u["name"], "type": u["type"],
                     "z_x": int(c["z_x"]), "z_pad": int(c["z_pad"]), "M": int(req[idx]["M"]),
                     "elems": int(y_gold.size), "mism": m_ok,
                     "neg_pad0_mism": m_pad0, "neg_dropterm_mism": m_drop})
    return {"units": len(sel), "elems": elems, "mism_ok": mism_ok,
            "neg_pad0_mism": mism_pad0, "neg_dropterm_mism": mism_drop,
            "nonzero_zx": nz, "rows": rows}


# ============================ 三态覆盖面表（G1） ============================
def coverage_table(gv, descs, info):
    """覆盖 / 需主机旁路 / 不覆盖，与 C3 冻结表**逐项对账**。

    分界（与 C3 的冻结口径同源，spec §2 的表 + `desc_table` 的 TYPE 表）：
      · **覆盖**   = 有冻结 TYPE 码、进描述符表的单元（conv3x3/conv1x1/depthwise/maxpool/resize/
                     add/sigmoid）；`Relu` 亦判**覆盖**（`✅ 折进生产者尾声`，不占描述符但数据通路有它）；
      · **需主机旁路** = 不进描述符、由转换器折进寻址（`Transpose/Reshape`），必要时主机搬一次；
      · **不覆盖** = 既无单元、又无折进办法（`Concat`，本网 0 个）。
    """
    op_hist = _hist(n.op_type for n in gv.nodes)
    type_hist = _hist(d["TYPE"] for d in descs)
    rows = [
        ("Conv(conv3x3)", 7, "覆盖", "TYPE 0x01 ×7", "desc_table 的 3×3 稠密档；C3 已交付"),
        ("Conv(conv1x1)", 26, "覆盖", "TYPE 0x02 ×26", "C3 已交付"),
        ("Conv(depthwise)", 20, "覆盖", "TYPE 0x03 ×20",
         "表/编码已覆盖；本代 RTL 单元待 C4a.6（§2 的『通道覆盖』缺口）"),
        ("MaxPool", 4, "覆盖", "TYPE 0x10 ×4", "C3.6 已交付 + 板上 PASS"),
        ("Resize", 2, "覆盖", "TYPE 0x11 ×2", "C3.6 已交付"),
        ("Add", 2, "覆盖", "TYPE 0x13 ×2", "C3.7 已交付"),
        ("Sigmoid", 6, "覆盖", "TYPE 0x14 ×6", "C3.7 已交付（256 项 LUT）"),
        ("Relu", 15, "覆盖", "表内 0 项（无 TYPE 码）", "折进生产者尾声（spec §2 的 ✅）"),
        ("Transpose", 12, "需主机旁路", "表内 0 项（折进寻址）",
         "转换器给消费者算 (src_stride, src_order)，见 layout_fold"),
        ("Reshape", 12, "需主机旁路", "表内 0 项（折进寻址）", "同上（线性序不变 ⇒ 换形状/步长）"),
        ("Concat", 0, "不覆盖", "表内 0 项（0x12 未实现）", "本网 0 个 ⇒ 不阻塞（C4 边界）"),
    ]
    # 表项按 TYPE 归并到「覆盖」行（conv 三类分开）
    type_to_row = {dtab.TYPE_CONV3X3: 0, dtab.TYPE_CONV1X1: 1, dtab.TYPE_DEPTHWISE: 2,
                   dtab.TYPE_MAXPOOL: 3, dtab.TYPE_RESIZE: 4, dtab.TYPE_ADD: 5, dtab.TYPE_SIGMOID: 6}
    cov_items = sum(type_hist.get(t, 0) for t in type_to_row)
    checks = {
        "onnx_op_hist": (op_hist == ONNX_OP_HIST_FROZEN, "%s vs frozen %s"
                         % (op_hist, ONNX_OP_HIST_FROZEN)),
        "type_hist": (type_hist == C3_TYPE_HIST_FROZEN, "%s vs frozen %s"
                      % ({dtab.TYPE_NAME[k]: v for k, v in type_hist.items()},
                         {dtab.TYPE_NAME[k]: v for k, v in C3_TYPE_HIST_FROZEN.items()})),
        "payload": (len(descs) == dtab.PAYLOAD_FROZEN, "%d vs frozen %d" % (len(descs), dtab.PAYLOAD_FROZEN)),
        "desc_total": (len(descs) + 1 == dtab.DESC_TOTAL_FROZEN,
                       "%d vs frozen %d" % (len(descs) + 1, dtab.DESC_TOTAL_FROZEN)),
        "bypass_ops": (info["bypass_nodes"] == dtab.BYPASS_OPS_FROZEN,
                       "%s vs frozen %s" % (info["bypass_nodes"], dtab.BYPASS_OPS_FROZEN)),
        "covered_items": (cov_items == dtab.PAYLOAD_FROZEN,
                          "覆盖项 %d vs 载荷 %d" % (cov_items, dtab.PAYLOAD_FROZEN)),
        "flags_hist": (info["flags_hist"] == dtab.FLAGS_HIST_FROZEN,
                       "%s vs frozen %s" % (info["flags_hist"], dtab.FLAGS_HIST_FROZEN)),
        "chains": (info["chains"] == dtab.CHAINS_FROZEN and info["runs"] == dtab.RUNS_FROZEN
                   and info["units"] == dtab.UNITS_FROZEN and info["covered_edges"] == dtab.COVERED_EDGES_FROZEN,
                   "chains=%d runs=%d edges=%d covered=%d"
                   % (info["chains"], info["runs"], info["units"], info["covered_edges"])),
        "traffic": (info["chain_bytes"] == dtab.CHAIN_BYTES_FROZEN,
                    "chain_bytes=%d vs frozen %d" % (info["chain_bytes"], dtab.CHAIN_BYTES_FROZEN)),
    }
    n_covered = cov_items + op_hist.get("Relu", 0)
    n_host = op_hist.get("Transpose", 0) + op_hist.get("Reshape", 0)
    n_uncovered = op_hist.get("Concat", 0) + 0
    totals = {"覆盖": n_covered, "需主机旁路": n_host, "不覆盖": n_uncovered,
              "nodes": sum(op_hist.values()),
              "覆盖_进表项": cov_items, "覆盖_折进尾声": op_hist.get("Relu", 0)}
    if n_covered + n_host + n_uncovered != totals["nodes"]:
        checks["state_sum"] = (False, "三态之和 %d != 节点数 %d"
                               % (n_covered + n_host + n_uncovered, totals["nodes"]))
    return rows, checks, totals


# ============================ 落盘 ============================
def dump(out_dir, blobs, index):
    os.makedirs(out_dir, exist_ok=True)
    paths = {}
    for key, fname in (("desc", "desc.bin"), ("blob", "wgt_blob.bin"), ("mult", "wgt_mult.bin")):
        p = os.path.join(out_dir, fname)
        with open(p, "wb") as fh:
            fh.write(blobs[key])
        paths[key] = p
    p = os.path.join(out_dir, "wgt_index.json")
    with open(p, "w", encoding="utf-8") as fh:
        json.dump(index, fh, ensure_ascii=False, indent=1, sort_keys=False)
    paths["index"] = p
    return paths


# ============================ 闸门 ============================
def gate(args):
    problems = []       # 判据红
    neg = []            # 负对照没发火
    if not os.path.isfile(args.onnx):
        print("FATAL: 缺 ONNX %s" % args.onnx, file=sys.stderr)
        return 3
    if not os.path.isfile(args.ref):
        print("FATAL: 缺 C4a.2 黄金 %s（先跑 tools/run_quant_ref.sh）" % args.ref, file=sys.stderr)
        return 3

    descs, info, index, blobs, full, ref, gv, payload_nodes, units, requant = build(args.onnx)
    print("CONVERT onnx=%s md5=%s" % (os.path.basename(args.onnx), index["model"]["md5"]))
    print("CONVERT nodes=%d payload=%d desc_items=%d desc_bytes=%d"
          % (len(gv.nodes), len(descs), len(full), len(blobs["desc"])))

    # ---------------- 1) 冻结校验 + 往返 ----------------
    ddr = dtab.DDR_BYTES
    val_msg = ""
    try:
        dtab.validate(full, dtab.desc_count_of(full), ddr)     # ★ 字面调用冻结的 validate
        val_ok = True
    except dtab.DescError as e:
        val_ok, val_msg = False, str(e)
    print("TABLE_VALIDATE ok=%d desc_count=%d msg=%s" % (1 if val_ok else 0, dtab.desc_count_of(full), val_msg))
    if not val_ok:
        problems.append("validate 未过：%s" % val_msg)

    rt_bad = 0
    raw_bad = 0
    k_of = read_src2k(blobs["desc"], len(descs))          # ★ E1：从产物字节里读回每项的 SRC2_K
    for i, d in enumerate(descs):
        got = dtab.unpack(blobs["desc"][i * dtab.DESC_BYTES:(i + 1) * dtab.DESC_BYTES])
        if any(got[k] != d[k] for k in dtab.FIELD_ORDER):
            rt_bad += 1
        words = struct.unpack_from("<8I", blobs["desc"], i * dtab.DESC_BYTES)
        expw = dtab.reference_words(d)
        if k_of.get(i, 0):                                   # w3 高 16 位 = SRC2_K（pack 不搬 ⇒ 期望字要补上）
            expw = list(expw)
            expw[3] = expw[3] | ((k_of[i] & 0xFFFF) << 16)
        if list(words) != expw:
            raw_bad += 1
        # 保留位：w0[31:16] 与 w7[31:16] 必须为 0；w3[31:16] 现在是 SRC2_K（非保留，单独判）
        if (words[0] & 0xFFFF0000) or (words[7] & 0xFFFF0000):
            raw_bad += 1
    sent_ok = dtab.unpack(blobs["desc"][-dtab.DESC_BYTES:]) == dtab.SENTINEL
    print("ROUNDTRIP_BAD=%d RAW_WORD_BAD=%d SENTINEL_OK=%d" % (rt_bad, raw_bad, 1 if sent_ok else 0))
    if rt_bad or raw_bad or not sent_ok:
        problems.append("pack/unpack 往返不一致（rt=%d raw=%d sent=%d）" % (rt_bad, raw_bad, sent_ok))

    # ---------------- 2) 三态覆盖面表 + 指纹 ----------------
    rows, checks, totals = coverage_table(gv, descs, info)
    print("COVERAGE_STATES 覆盖=%d 需主机旁路=%d 不覆盖=%d nodes=%d"
          % (totals["覆盖"], totals["需主机旁路"], totals["不覆盖"], totals["nodes"]))
    print("COVERAGE_SPLIT 进表项=%d 折进尾声(Relu)=%d"
          % (totals["覆盖_进表项"], totals["覆盖_折进尾声"]))
    for name, cnt, decision, c3, why in rows:
        print("COVERAGE_ROW %-16s onnx=%-3d %-6s c3=%s" % (name, cnt, decision, c3))
    for k, (ok, detail) in checks.items():
        print("COVERAGE_CHECK %-14s ok=%d %s" % (k, 1 if ok else 0, detail))
        if not ok:
            problems.append("三态覆盖对账红：%s（%s）" % (k, detail))

    print("TABLE_BYTES=%d TABLE_MD5=%s" % (index["table"]["bytes"], index["table"]["md5"]))
    # ---- 冻结建表器复用自证 + 与 C3 冻结向量逐字段差（只允许 IN_BYTES 不同，spec §3 的坑）----
    frozen_descs, _ = dtab.build_table(gv)               # 第二遍（第一遍的返回值已被本文件就地改过）
    frozen_blob = dtab.pack_table(frozen_descs)
    frozen_md5 = md5_bytes(frozen_blob)
    diff_items = []
    diff_fields = Counter()
    for i, (a, b) in enumerate(zip(frozen_descs, descs)):
        fs = [k for k in dtab.FIELD_ORDER if a[k] != b[k]]
        if fs:
            diff_items.append((i, payload_nodes[i].name, payload_nodes[i].op_type, fs))
            diff_fields.update(fs)
    print("TABLE_ENCODER_REUSE frozen_md5=%s frozen_const=%s matches=%d"
          % (frozen_md5, dtab.TABLE_MD5_FROZEN, 1 if frozen_md5 == dtab.TABLE_MD5_FROZEN else 0))
    print("TABLE_DIFF_VS_C3_FROZEN items=%d fields=%s"
          % (len(diff_items), dict(diff_fields)))
    for i, nm, op, fs in diff_items:
        print("TABLE_DIFF_ITEM idx=%d %s(%s) fields=%s frozen_in_bytes=%d ours=%d"
              % (i, nm, op, fs, units[i]["in_bytes_frozen"], units[i]["in_bytes"]))
    if frozen_md5 != dtab.TABLE_MD5_FROZEN:
        problems.append("冻结建表器的产物 != 冻结 md5 %s（编码口径被动过）" % dtab.TABLE_MD5_FROZEN)
    # ★★ A2：与 C3 冻结向量的**刻意**差异 = {IN_BYTES(§3), SRC_ADDR(H1 折进重写)}
    #   ∪ {FLAGS→plain, 6 个几何字段→own}（**仅被拆的宽 run 成员**；且几何差只允许出现在冻结角色为
    #   middle/tail（链首覆盖）的成员上，链首在冻结表里本来就是 own 几何 ⇒ 出现差即越界）。
    #   逐项验签名 —— 放宽的是"A2 的刻意差"，其余仍是"多一处就红"。
    defused_set = set(m["idx"] for r in index["defuse"]["runs"] if r["defused"] for m in r["members"])
    own_by_idx = {u["idx"]: u["own"] for u in units}
    diff_excess = []
    for i, (a, b) in enumerate(zip(frozen_descs, descs)):
        extra = [k for k in dtab.FIELD_ORDER
                 if a[k] != b[k] and k not in ("IN_BYTES", "SRC_ADDR")]
        if not extra:
            continue
        if i not in defused_set:
            diff_excess.append((i, extra, "非被拆成员"))
            continue
        role = a["FLAGS"] & dtab.FLAGS_SEMANTIC_MASK
        if "FLAGS" not in extra:
            diff_excess.append((i, extra, "被拆成员未带 FLAGS 差（角色没换？）"))
            continue
        if role == dtab.FLAGS_PLAIN or (b["FLAGS"] & dtab.FLAGS_SEMANTIC_MASK) != dtab.FLAGS_PLAIN:
            diff_excess.append((i, extra, "FLAGS 差不是『链角色→plain』"))
            continue
        geo = [k for k in extra if k in dtab.CHAIN_GEOM_FIELDS]
        if len(geo) + 1 != len(extra):
            diff_excess.append((i, extra, "差字段不在允许集"))
            continue
        for k in geo:
            if role == dtab.FLAGS_HEAD or b[k] != int(own_by_idx[i][k]):
                diff_excess.append((i, [k], "几何差不是 own（或出现在链首）"))
                break
    print("TABLE_DIFF_FIELDS_ALLOWED ok=%d fields=%s allowed=%s extra=%s"
          % (1 if not diff_excess else 0, dict(diff_fields),
             "{IN_BYTES,SRC_ADDR}|{FLAGS->plain,6geom->own 限被拆宽run成员}",
             [(i, f, w) for i, f, w in diff_excess]))
    if diff_excess:
        problems.append("与 C3 冻结向量的差超出 A2 允许集：%s" % diff_excess)
    index["table_diff_vs_c3_frozen"] = {
        "frozen_md5": frozen_md5, "frozen_const": dtab.TABLE_MD5_FROZEN,
        "items": [{"idx": i, "name": nm, "op": op, "fields": fs} for i, nm, op, fs in diff_items],
        "fields_hist": dict(diff_fields),
        "allowed": "{IN_BYTES, SRC_ADDR}（全部项）∪ {FLAGS→plain, IMG_W/IMG_H/C_IN/C_OUT/GROUP/QUANT_SHIFT→own}"
                   "（**仅 A2 被拆的宽 run 成员**；几何差只允许出现在冻结角色为 middle/tail 的成员上）",
        "n_defused_members": len(defused_set),
        "note": "本文件把 IN_BYTES 改成『该单元实际要读的激活字节数』（spec §3 的坑；"
                "conv 的 IN_BYTES 就是 UnitExec 的 rdLen），按 **H1** 把被折进源（Relu 尾声 / "
                "Transpose-Reshape 布局）的 SRC_ADDR 改到『生产者真正写过的 DST』，并按 **A2**"
                "（spec §5.0）把宽 run 逐成员拆成 plain + 写 own 几何。其余字段与 C3 冻结向量逐字节相同。",
    }

    # ---- ★ H1：SRC_ADDR 折进 —— 正判据（每个源都写在读之前）+ 负对照（改一条 SRC ⇒ 必发火）----
    sf = index.get("src_addr_fold", [])
    print("SRC_ADDR_FOLD rewrites=%d units=%d" % (len(sf), len(units)))
    for r in sf[:6]:
        print("SRC_ADDR_FOLD_ITEM desc_idx=%d %s(%s) in_t=%s chain=%s producer=%s SRC 0x%08X -> 0x%08X"
              % (r["desc_idx"], r["unit"], r["op"], r["in_tensor"], ",".join(r["chain"]),
                 r["producer"], r["old_src"], r["new_src"]))
    sw = check_src_written(gv, descs, units)
    print("SRC_WRITTEN ok=%d checked=%d offenders=%d external=%d"
          % (1 if not sw["offenders"] else 0, sw["checked"], len(sw["offenders"]), sw["external"]))
    for o in sw["offenders"][:8]:
        print("SRC_WRITTEN_BAD desc_idx=%d %s %s src=0x%08X in_tensor=%s"
              % (o["desc_idx"], o["unit"], o["op"], o["src"], o["in_tensor"]))
    if sw["offenders"]:
        problems.append("H1 正判据红：%d 项的 SRC_ADDR 不是更早描述符写过的 DST" % len(sw["offenders"]))
    # 负对照 e：把一条 SRC_ADDR 打到"从未被写过"的槽位 ⇒ SRC_WRITTEN 必须变红
    k_src = _descriptor_sourced_indices(gv, units)[0]
    mut_src = [dict(d) for d in descs]
    mut_src[k_src]["SRC_ADDR"] = 0x0F000000
    sw_mut = check_src_written(gv, mut_src, units)
    fired_src = len(sw_mut["offenders"]) > 0
    print("NEGCTL_SRC_ADDR desc_idx=%d %s SRC 0x%08X -> 0x0F000000 offenders=%d (须 >0) FIRED=%d"
          % (k_src, units[k_src]["name"], descs[k_src]["SRC_ADDR"],
             len(sw_mut["offenders"]), 1 if fired_src else 0))
    if not fired_src:
        neg.append("H1 负对照（改一条 SRC_ADDR）没发火")

    # ---- ★ E1（2026-10-13）：Add 第二路源 = w3[31:16] 的「表内偏移」k —— 正判据 + 负对照 ----
    init_names = set(ref.init.keys())
    sc = check_src2(gv, units, payload_nodes, init_names, k_of)
    print("SRC2_ADD adds=%d records=%d" % (sc["adds"], len(index.get("src2_add", []))))
    for r in index.get("src2_add", []):
        print("SRC2_ADD_ITEM desc_idx=%d %s second_t=%s producer=%s(idx=%d) k=%d SRC2=0x%08X"
              % (r["desc_idx"], r["unit"], r["second_tensor"], r["producer"], r["producer_idx"],
                 r["k"], r["src2_addr"]))
    print("SRC2_CORRECT ok=%d adds=%d offenders=%d"
          % (1 if not sc["offenders"] else 0, sc["adds"], len(sc["offenders"])))
    for o in sc["offenders"][:8]:
        print("SRC2_CORRECT_BAD desc_idx=%d %s %s k=%d want=%s producer=%s"
              % (o["desc_idx"], o["unit"], o["op"], o["k"], o.get("want"), o.get("producer")))
    if sc["offenders"]:
        problems.append("E1 正判据红：%d 个 Add 的 SRC2_K 与图推导的生产者不符" % len(sc["offenders"]))
    # 负对照 f：把一个 Add 的 k 改错（off-by-one，落到邻近但**非**生产者那条的 DST）⇒ SRC2_CORRECT 必红
    if index.get("src2_add"):
        a0 = index["src2_add"][0]
        mut_blob = bytearray(blobs["desc"])
        off0 = a0["desc_idx"] * dtab.DESC_BYTES + 12
        w3m = struct.unpack_from("<I", mut_blob, off0)[0]
        struct.pack_into("<I", mut_blob, off0, (w3m & 0xFFFF) | (((a0["k"] + 1) & 0xFFFF) << 16))
        sc_mut = check_src2(gv, units, payload_nodes, init_names, read_src2k(bytes(mut_blob), len(descs)))
        fired_k = len(sc_mut["offenders"]) > 0
        print("NEGCTL_SRC2_K desc_idx=%d %s k %d -> %d offenders=%d (须 >0) FIRED=%d"
              % (a0["desc_idx"], a0["unit"], a0["k"], a0["k"] + 1,
                 len(sc_mut["offenders"]), 1 if fired_k else 0))
        if not fired_k:
            neg.append("E1 负对照（改一个 Add 的 k）没发火")
    else:
        neg.append("E1 负对照（改一个 Add 的 k）无 Add 记录 ⇒ 无意义")

    # ---------------- ★★ A2：宽 run 拆融合（de-fuse）—— 正判据 + 地址 + arena 硬门 + 流量 + 负对照 ----------------
    defuse = index["defuse"]
    print("DEFUSE_RUNS total=%d defused=%d kept_narrow=%d defused_members=%d kept_members=%d "
          "wide_members=%d narrow_members=%d"
          % (len(defuse["runs"]), defuse["defused_runs"], defuse["kept_runs"],
             defuse["defused_members"], defuse["kept_members"],
             defuse["wide_members"], defuse["narrow_members"]))
    for r in defuse["runs"]:
        if r["defused"]:
            print("DEFUSE_RUN_DEFUSED head=%d len=%d members=%s narrow=%s"
                  % (r["head"], r["len"], [m["idx"] for m in r["members"]],
                     [1 if m["narrow"] else 0 for m in r["members"]]))
    for r in defuse["runs"]:
        if not r["defused"]:
            print("DEFUSE_RUN_KEPT head=%d len=%d members=%s" % (r["head"], r["len"],
                                                                 [m["idx"] for m in r["members"]]))
    # 正判据（a）：被拆 run 全成员 plain；保留 run 全成员 narrow 且角色合法（与 `defuse` 段互证）
    off_def = check_defuse(descs, defuse)
    print("DEFUSE_ALL_PLAIN ok=%d defused_runs=%d offenders=%d"
          % (1 if not off_def else 0, defuse["defused_runs"], len(off_def)))
    for o in off_def[:8]:
        print("DEFUSE_BAD idx=%d %s why=%s" % (o["idx"], o["name"], o["why"]))
    if off_def:
        problems.append("A2 正判据红：%d 个成员的 FLAGS 与 defuse 记录不符" % len(off_def))
    # 地址判据：每个（拆前）run 逐成员 `SRC == 前一成员 DST`（中间张量的真实地址来自冻结 bump arena）
    n_addr, bad_addr = check_chain_addrs(descs, defuse)
    print("DEFUSE_CHAIN_ADDRS ok=%d checked=%d" % (1 if not bad_addr else 0, n_addr))
    for b in bad_addr[:8]:
        print("DEFUSE_CHAIN_ADDRS_BAD run@%d member=%d src=0x%08X prev_dst=0x%08X"
              % (b["run_head"], b["member"], b["src"], b["prev_dst"]))
    if bad_addr:
        problems.append("A2 地址判据红：%d 个链中张量的 SRC != 前驱 DST" % len(bad_addr))
    # 负对照 g：把一个被拆成员塞回 `head` ⇒ 正判据必红
    kd = sorted(m["idx"] for r in defuse["runs"] if r["defused"] for m in r["members"])[0]
    mut_dd = [dict(d) for d in descs]
    mut_dd[kd]["FLAGS"] = dtab.FLAGS_HEAD
    off_mut = check_defuse(mut_dd, defuse)
    fired_defuse = len(off_mut) > 0
    print("NEGCTL_DEFUSE_HEAD desc_idx=%d %s FLAGS plain -> head offenders=%d (须 >0) FIRED=%d"
          % (kd, units[kd]["name"], len(off_mut), 1 if fired_defuse else 0))
    if not fired_defuse:
        neg.append("A2 负对照（被拆成员塞回 head）没发火")
    # ★★ A2 arena 硬门：分配器高水位必须装进 NPU 预留区（物理 0x8040_0000–0x8200_0000 = 28 MB）
    arena_top = int(info["arena_top"])
    _phys = 0x80000000
    print("ARENA_TOP npu=0x%08X phys=0x%08X carve_npu=[0x%08X,0x%08X) carve_phys=[0x%08X,0x%08X) "
          "headroom=%d B tensors=%d"
          % (arena_top, _phys + arena_top, ARENA_CARVE_NPU_LO, ARENA_CARVE_NPU_HI,
             _phys + ARENA_CARVE_NPU_LO, _phys + ARENA_CARVE_NPU_HI,
             ARENA_CARVE_NPU_HI - arena_top, info["arena_tensors"]))
    print("ARENA_FIT ok=%d arena=[0x%08X,0x%08X) top<=0x%08X"
          % (1 if arena_top <= ARENA_CARVE_NPU_HI else 0, dtab.TENSOR_BASE, arena_top,
             ARENA_CARVE_NPU_HI))
    if arena_top > ARENA_CARVE_NPU_HI:
        problems.append("A2 arena 硬门红：高水位 0x%08X > 预留区上界 0x%08X（BLOCKED）"
                        % (arena_top, ARENA_CARVE_NPU_HI))
    # ★★ A2 流量：**调用**冻结 `ddr_traffic` 的 strategy（只读；不编辑）；两向都断言。
    frozen_unfused = sum(r.traffic for r in dt.STRATEGIES["baseline"](gv))
    frozen_fused = sum(r.traffic for r in dt.STRATEGIES["fuse_both"](gv))
    dec_base = defuse_traffic(gv, frozen_descs, payload_nodes, init_names)
    dec_final = defuse_traffic(gv, descs, payload_nodes, init_names)
    _fps = lambda b: dt.DDR_MBPS * 1e6 / float(b)
    print("DEFUSE_TRAFFIC frozen_baseline=%d frozen_fuse_both=%d decoded_frozen_base=%d "
          "decoded_final=%d cost=%d B/frame (%.2f MB)"
          % (frozen_unfused, frozen_fused, dec_base, dec_final,
             frozen_unfused - frozen_fused, (frozen_unfused - frozen_fused) / 1e6))
    print("DEFUSE_FPS fps_bandwidth_fused=%.4f fps_bandwidth_de_fused=%.4f (275.9 MB/s ÷ MB)"
          % (_fps(frozen_fused), _fps(frozen_unfused)))
    if dec_base != frozen_fused or dec_final != frozen_unfused:
        problems.append("A2 流量判据红：decoded_frozen_base=%d(期望 %d) decoded_final=%d(期望 %d)"
                        % (dec_base, frozen_fused, dec_final, frozen_unfused))

    print("WGT_BLOB_BYTES=%d WGT_BLOB_MD5=%s WGT_UNITS=%d SUM_N=%d SUM_N_ALIGNED=%d PAD_OVERHEAD=%d"
          % (index["blob"]["bytes"], index["blob"]["md5"], index["blob"]["units"], index["blob"]["sum_N"],
             index["blob"]["sum_N_aligned"], index["blob"]["pad_overhead"]))
    print("WGT_MULT_BYTES=%d WGT_MULT_MD5=%s MULT_WORDS=%d REQUANT_Q=%d"
          % (index["mult"]["bytes"], index["mult"]["md5"], index["mult"]["words"], REQUANT_Q))
    print("MAILBOX_BYTES=%d MAILBOX_MD5=%s" % (index["fingerprints"]["mailbox_bytes"],
                                               index["fingerprints"]["mailbox_md5"]))
    print("REQUANT_FP=%s UNITS_FP=%s" % (index["fingerprints"]["requant_fp"],
                                         index["fingerprints"]["units_fp"]))
    if index["blob"]["bytes"] != index["blob"]["sum_N_aligned"]:
        problems.append("blob 字节数 %d != Σ ceil32(N_i) %d（对齐布局）"
                        % (index["blob"]["bytes"], index["blob"]["sum_N_aligned"]))
    if index["blob"]["sum_N"] + index["blob"]["pad_overhead"] != index["blob"]["sum_N_aligned"]:
        problems.append("对齐账不平：ΣN %d + 补位 %d != ΣN' %d"
                        % (index["blob"]["sum_N"], index["blob"]["pad_overhead"], index["blob"]["sum_N_aligned"]))
    # IN_BYTES 口径判据（spec §3 的坑）：每项都必须 == align32(该单元要读的激活字节数)
    in_bytes_bad = [u for u in units if u["in_bytes"] != u["in_bytes_expected"]]
    print("IN_BYTES_RULE ok=%d checked=%d patched_vs_c3=%d"
          % (1 if not in_bytes_bad else 0, len(units),
             sum(1 for u in units if u["in_bytes"] != u["in_bytes_frozen"])))
    for u in in_bytes_bad[:8]:
        print("IN_BYTES_BAD idx=%d %s got=%d expected=%d"
              % (u["idx"], u["name"], u["in_bytes"], u["in_bytes_expected"]))
    if in_bytes_bad:
        problems.append("IN_BYTES 口径红：%d 项 != 输入激活字节数" % len(in_bytes_bad))
    # 表序 == LAYER_ID == M 表下标（§4.4 的乘子索引契约）
    lid_bad = [u for u in units if u["layer_id"] != u["idx"]]
    print("LAYER_ID_EQ_TABLE_IDX ok=%d checked=%d" % (1 if not lid_bad else 0, len(units)))
    if lid_bad:
        problems.append("LAYER_ID != 表序（乘子索引契约破裂）：%d 项" % len(lid_bad))
    # 表序隐含权重（★ 2026-10-12 B0：对齐布局）：第 i 个消费权重的单元起点 = Σ_{j<i} ceil32(N_j)（**契约**，逐项断言）
    run = 0
    off_bad = []
    for u in units:
        if u["weight"] is None:
            continue
        if u["weight"]["offset"] != run or u["weight"]["offset"] % 32 != 0:
            off_bad.append((u["idx"], u["name"], u["weight"]["offset"], run))
        run += u["weight"]["aligned_bytes"]
    print("BLOB_OFFSET_CUM_SUM ok=%d units=%d total=%d (aligned)"
          % (1 if not off_bad else 0, index["blob"]["units"], run))
    for i, nm, got, exp in off_bad[:8]:
        print("BLOB_OFFSET_BAD idx=%d %s got=%d expected=%d" % (i, nm, got, exp))
    if off_bad or run != index["blob"]["bytes"]:
        problems.append("表序隐含权重契约破裂：offset 不是 Σ ceil32(N_j)（%d 项）或总长 %d != blob"
                        % (len(off_bad), run))

    # ---------------- 3) 与 C4a.2 黄金对账 ----------------
    xr = cross_check_ref(args.ref, gv, descs, payload_nodes, units)
    print("CROSS_REF_SEQ kept=%d golden_geom_checked=%d chain_members=%d problems=%d"
          % (xr["kept"], xr["golden_checked"], xr["chain_members"], len(xr["problems"])))
    for p in xr["problems"][:8]:
        print("CROSS_REF_PROBLEM %s" % p)
    if xr["problems"]:
        problems.append("与 c4a_ref_layers.json 对账红（%d 条）" % len(xr["problems"]))

    xw = cross_check_weights(blobs["blob"], units, ref)
    print("XCHECK_WEIGHTS checked=%d mismatch=%d pad_bad=%d" % (xw["checked"], xw["mismatch"], xw["pad_bad"]))
    if xw["mismatch"] or xw["pad_bad"]:
        problems.append("blob 与同口径参考权重对账红（mismatch=%d pad_bad=%d）" % (xw["mismatch"], xw["pad_bad"]))

    # 折进对账（Relu 折进生产者尾声的数值后果）
    n_fold = sum(1 for r in requant if r["folded_ops"])
    n_Mdiff = sum(1 for r in requant if r["M"] != r["M_two_step"])
    Ms = [r["M"] for r in requant if r["M"]]
    n_relu = ONNX_OP_HIST_FROZEN["Relu"]
    print("REQUANT_FOLD folded_units=%d M_differs_from_two_step=%d units=%d relu_nodes=%d"
          % (n_fold, n_Mdiff, len(requant), n_relu))
    print("REQUANT_RANGE M_min=%d M_max=%d M_zero(sigmoid)=%d SHIFT=%d REQUANT_Q=%d"
          % (min(Ms), max(Ms), sum(1 for r in requant if r["M"] == 0), SHIFT, REQUANT_Q))
    # 判据：网里 15 个 Relu 必须**全部**折进生产者尾声（冻结口径），一个不落
    if n_fold != n_relu:
        problems.append("Relu 折进数 %d != 网里 Relu 节点数 %d（折进口径没落实）" % (n_fold, n_relu))

    # ---------------- 3.5) §4.5-A 中心化：正对照（真网字节级等价）+ 负对照 a/b ----------------
    cen = index["centering"]
    nz_total = sum(1 for c in cen if c["z_x"] != 0)
    pad_hist = Counter(c["z_pad"] for c in cen)
    print("CENTERING units=%d nonzero_z_x=%d z_pad_distinct=%d z_w_all_zero=%d centering_fp=%s"
          % (len(cen), nz_total, len(pad_hist),
             1 if all(c["z_w"] == 0 for c in cen) else 0, index["fingerprints"]["centering_fp"]))
    print("CENTERING_PAD_Z_DIST %s" % dict(sorted(pad_hist.items())))
    if not cen or not all(c["z_w"] == 0 for c in cen):
        problems.append("§4.5-A 不成立：权重 z_w 非全 0 或 centering 段为空")
    ce = center_equiv(ref, blobs["blob"], units, requant, cen)
    print("CENTER_EQUIV units=%d elems=%d nonzero_z_x=%d MISMATCH=%d "
          "neg_pad0_mism=%d neg_dropterm_mism=%d"
          % (ce["units"], ce["elems"], ce["nonzero_zx"], ce["mism_ok"],
             ce["neg_pad0_mism"], ce["neg_dropterm_mism"]))
    for r in ce["rows"]:
        print("CENTER_UNIT layer_id=%d %-10s %-9s z_x=%4d z_pad=%4d M=%d elems=%d mism=%d"
              % (r["layer_id"], r["name"], r["type"], r["z_x"], r["z_pad"], r["M"],
                 r["elems"], r["mism"]))
        print("CENTER_UNIT_NEG layer_id=%d %s pad0_mism=%d dropterm_mism=%d"
              % (r["layer_id"], r["name"], r["neg_pad0_mism"], r["neg_dropterm_mism"]))
    # 正对照：硬件中心化算术必须**逐字节** == 黄金；且必须**至少**含一个非零 z_x 的层
    if ce["units"] < 3 or ce["mism_ok"] != 0 or ce["nonzero_zx"] < 1 or ce["elems"] == 0:
        problems.append("§4.5 正对照红：units=%d MISMATCH=%d nonzero_z_x=%d elems=%d"
                        % (ce["units"], ce["mism_ok"], ce["nonzero_zx"], ce["elems"]))
    # 负对照 a / b（必须发火）
    fired_ce_a = ce["neg_pad0_mism"] > 0
    fired_ce_b = ce["neg_dropterm_mism"] > 0
    print("NEGCTL_CENTER_PAD0 mism=%d (须 >0) FIRED=%d" % (ce["neg_pad0_mism"], 1 if fired_ce_a else 0))
    print("NEGCTL_CENTER_DROPTERM mism=%d (须 >0) FIRED=%d" % (ce["neg_dropterm_mism"], 1 if fired_ce_b else 0))
    if not fired_ce_a:
        neg.append("§4.5 负对照 a（pad 用字节 0 代替 z_pad）没发火")
    if not fired_ce_b:
        neg.append("§4.5 负对照 b（去掉 −z_x·Σ w_q 项）没发火")

    # ---------------- 4) 负对照（每条都必须发火） ----------------
    # 4a. 改 1 个权重字节 ⇒ blob md5 必须变，且逐字节对账必须 MISMATCH>0
    first_w = next(u for u in units if u["weight"] is not None)
    mut = bytearray(blobs["blob"])
    mut[first_w["weight"]["offset"]] ^= 0x01
    if INJECT == "nodiv":                                  # 故障注入：关掉这条负对照
        mut = bytearray(blobs["blob"])
    md5_before = md5_bytes(blobs["blob"])
    md5_after = md5_bytes(bytes(mut))
    xw_mut = cross_check_weights(blobs["blob"], units, ref, mut_blob=bytes(mut))
    fired_w = (md5_after != md5_before) and (xw_mut["mismatch"] > 0)
    print("NEGCTL_WEIGHT_FLIP unit=%s byte_off=%d md5_before=%s md5_after=%s blob_changed=%d "
          "xcheck_mismatch=%d (须 >0) FIRED=%d"
          % (first_w["name"], first_w["weight"]["offset"], md5_before, md5_after,
             1 if md5_after != md5_before else 0, xw_mut["mismatch"], 1 if fired_w else 0))
    if not fired_w:
        neg.append("改 1 个权重字节没能打红（blob md5 或逐字节对账）")

    # 4b. 改 1 个 M ⇒ wgt_mult.bin md5 + requant_mult 指纹必须变（§4.4 新增）
    mut_m = bytearray(blobs["mult"])
    k = next(i for i, r in enumerate(requant) if r["M"] != 0)
    mut_m[4 * k] ^= 0x01
    mut_requant = [dict(r) for r in requant]
    mut_requant[k]["M"] = struct.unpack_from("<I", bytes(mut_m), 4 * k)[0]
    fired_m = (md5_bytes(bytes(mut_m)) != md5_bytes(blobs["mult"])
               and requant_fp(mut_requant) != requant_fp(requant)
               and mut_requant[k]["M"] != requant[k]["M"])
    print("NEGCTL_MULT_FLIP layer_id=%d M %d -> %d mult_md5_changed=%d requant_fp_changed=%d FIRED=%d"
          % (k, requant[k]["M"], mut_requant[k]["M"],
             1 if md5_bytes(bytes(mut_m)) != md5_bytes(blobs["mult"]) else 0,
             1 if requant_fp(mut_requant) != requant_fp(requant) else 0,
             1 if fired_m else 0))
    if not fired_m:
        neg.append("改 1 个 M 没能打红（wgt_mult md5 或 requant 指纹）")

    # 4c. desc_count 与哨兵不符 ⇒ validate 必须抛（含"旧口径 = 表长含哨兵"那一档）
    n_payload = dtab.desc_count_of(full)
    raised = {}
    for tag, dc in (("count_len_incl_sentinel", len(full)), ("count_payload_minus_1", n_payload - 1)):
        try:
            dtab.validate(full, dc, ddr)
            raised[tag] = ""
        except dtab.DescError as e:
            raised[tag] = str(e)
    fired_c = all(raised.values()) and raised["count_len_incl_sentinel"].startswith("DESC_COUNT")
    print("NEGCTL_DESC_COUNT desc_count=%d(sentinel idx=%d) incl_sentinel_raise=%d msg=%r "
          "minus1_raise=%d msg=%r FIRED=%d"
          % (n_payload, len(full) - 1,
             1 if raised["count_len_incl_sentinel"] else 0, raised["count_len_incl_sentinel"],
             1 if raised["count_payload_minus_1"] else 0, raised["count_payload_minus_1"],
             1 if fired_c else 0))
    if not fired_c:
        neg.append("desc_count 与哨兵不符时 validate 没抛")

    # 4d. §4.5 负对照 c：翻 1 bit 的 z_pad / bias_adj ⇒ centering 指纹（索引指纹）必须变
    fp0 = centering_fp(cen)
    ck = next((i for i, c in enumerate(cen) if c["z_pad"] != 0), 0)
    mut_z = [dict(c) for c in cen]
    mut_z[ck]["z_pad"] = int(cen[ck]["z_pad"]) ^ 1
    ck2 = next((i for i, c in enumerate(cen) if len(c["bias_adj"]) and c["bias_adj"][0] != 0), 0)
    mut_b = [dict(c) for c in cen]
    mut_b[ck2]["bias_adj"] = list(cen[ck2]["bias_adj"])
    mut_b[ck2]["bias_adj"][0] = int(mut_b[ck2]["bias_adj"][0]) ^ 1
    fp_z, fp_b = centering_fp(mut_z), centering_fp(mut_b)
    fired_ce_c = (fp_z != fp0) and (fp_b != fp0) and (int(mut_z[ck]["z_pad"]) != int(cen[ck]["z_pad"]))
    print("NEGCTL_CENTER_FP_FLIP z_pad_off=%d z_pad_fp_changed=%d bias_adj_off=%d bias_adj_fp_changed=%d "
          "fp_before=%s FIRED=%d"
          % (ck, 1 if fp_z != fp0 else 0, ck2, 1 if fp_b != fp0 else 0, fp0, 1 if fired_ce_c else 0))
    if not fired_ce_c:
        neg.append("§4.5 负对照 c（翻 1 bit 的 z_pad/bias_adj）没让指纹变")

    # ---------------- 5) 落盘 ----------------
    paths = dump(args.out, blobs, index)
    for key in ("desc", "blob", "mult", "index"):
        p = paths[key]
        print("ARTIFACT %-10s %s bytes=%d md5=%s"
              % (key, p, os.path.getsize(p), md5_file(p)))
    print("ARTIFACT_INDEX requant_fp=%s" % index["fingerprints"]["requant_fp"])
    print("ARTIFACT_INDEX requant_md5=%s layout_fold_entries=%d"
          % (index["fingerprints"]["requant_fp"], len(index["layout_fold"])))

    # ---------------- 判决 ----------------
    print("==========================================================================")
    if problems:
        for p in problems:
            print("JUDGE-RED: %s" % p)
        print("RESULT: FAIL")
        return 1
    if neg:
        for p in neg:
            print("NEGCTL-FAIL: %s" % p)
        print("RESULT: FAIL")
        return 2
    print("收敛：表 %d B(%d 项) / 权重 %d B(%d 单元) / M %d B(%d 字) —— 表序 == blob 序；"
          "三态覆盖对账逐项一致；与 C4a.2 黄金层序/几何/权重逐字节一致"
          % (index["table"]["bytes"], len(full), index["blob"]["bytes"], index["blob"]["units"],
             index["mult"]["bytes"], index["mult"]["words"]))
    print("RESULT: PASS")
    return 0


def main(argv):
    global INJECT, CALIB_IMAGE
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("--onnx", default=DEFAULT_ONNX)
    ap.add_argument("--ref", default=DEFAULT_REF)
    ap.add_argument("--out", default=DEFAULT_OUT)
    ap.add_argument("--gate", action="store_true")
    ap.add_argument("--layout", action="store_true",
                    help="G5（C4a.7）：Transpose/Reshape 折进寻址的闸门（折进==显式 + 搬运不增 + 负对照）")
    ap.add_argument("--inject", default="none", choices=INJECTS,
                    help="故障注入（只给红证据；绝不改口径）")
    ap.add_argument("--calib-image", default=CALIB_IMAGE,
                    help="S4-B：用该真图（0..255）做激活标定（缺省 = quant_ref 合成 U[0,1)）")
    args = ap.parse_args(argv[1:])
    INJECT = args.inject
    CALIB_IMAGE = args.calib_image
    if args.layout:
        return layout_gate(args)
    if not args.gate:
        print(__doc__)
        return 2
    return gate(args)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
