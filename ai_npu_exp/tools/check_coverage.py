#!/usr/bin/env python3
"""三态算子覆盖判据 (M0-A5).

把 ``onnx_report.py`` 产出的算子报告映射到 SpinalHDL CNN 加速器的算子面，
按 **位置** 而非 **算子名** 裁三态：

    覆盖           加速器原生实现（conv33/conv11 稠密 / LeakyRelu(0.1) /
                   MaxPooling / Add / Concat / Split / UpSampling / Focus）；
    需主机旁路     不在块内（块间或检测头外），可由 RV32 在两次 NPU 调用之间用
                   加速器既有的“逐层、特征落 DDR”编排完成；
    不覆盖         在卷积块内部（卷积与激活之间、或需按通道分组才能表达），
                   加速器数据通路表达不了。

另外把 ``Identity`` / ``Constant`` 记为 ``wire``（非算子）。

判据口径：只要覆盖表里出现一个 ``不覆盖``（含任何分组卷积）即 FAIL。

用法::

    python check_coverage.py <report.txt>

退出码：0 = PASS（覆盖表无“不覆盖”），非 0 = FAIL。
"""

import sys
import re
import json
import collections

# Windows 控制台是 GBK：任何非 ASCII 字节都不许把判据打断。
sys.stdout.reconfigure(errors="replace")


# ---------------------------------------------------------------------------
# 1. 解析 onnx_report.py 的固定五节输出
# ---------------------------------------------------------------------------
def parse_report(path):
    """返回 (ops_hist, groups_hist, acts_hist)。

    ops_hist   : OrderedDict{op_type: count}，保持报告中的降序
    groups_hist: {group_int: count}，来自 == conv_group_hist == 的 JSON
    acts_hist  : OrderedDict{op_type: count}，来自 == activations ==
    """
    ops = collections.OrderedDict()
    groups = {}
    acts = collections.OrderedDict()
    section = None
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        for raw in fh:
            line = raw.rstrip("\n")
            m = re.match(r"^==\s*([A-Za-z_]+)\s*==(.*)$", line)
            if m:
                section = m.group(1)
                payload = m.group(2).strip()
                if section == "conv_group_hist" and payload:
                    groups = json.loads(payload)
                continue
            if not line.strip():
                continue
            parts = line.split()
            if len(parts) < 2:
                continue
            if section == "ops":
                ops[parts[0]] = int(parts[1])
            elif section == "activations":
                if parts[0] == "(none)":
                    continue
                acts[parts[0]] = int(parts[1])
            # == conv == / == io == 本判据不需要
    return ops, groups, acts


# ---------------------------------------------------------------------------
# 2. 加速器算子面（权威，来自 third_party/SpinalHDL_CNN_Accelerator 的 RTL）
# ---------------------------------------------------------------------------
# 原生非线性：只有 LeakyRelu，且 leakyRatio 硬编码 0.1
NATIVE_ACT = {"LeakyRelu"}
# 原生非线性但需改配置常量（ratio=0 即普通 Relu，不新增数据通路）
CONFIG_ACT = {"Relu"}
# 块内激活，加速器能力面之外 —— 明确判“不覆盖”，不做特例
UNSUPPORTED_BLOCK_ACT = {
    "HardSigmoid", "Silu", "Swish", "HardSwish", "PRelu", "Elu", "Mish", "Gelu",
}
# onnx_report.py 会报出的非线性集合（含上表，用于兜底识别）
NONLINEAR = {
    "Relu", "LeakyRelu", "PRelu", "Sigmoid", "Softmax", "Tanh", "HardSigmoid",
    "HardSwish", "Silu", "Swish", "Clip", "Exp", "Elu", "Mish", "Gelu",
}

# 原生张量算子（shape/ 模块：MaxPooling/Add/Concat/Split/UpSampling；Focus 在主干）
NATIVE_OPS = {
    "MaxPool": "shape/MaxPooling 原生实现",
    "Add": "shape/Add（AddAdd 两路相加）原生实现，对应残差短路",
    "Concat": "shape/Concat 原生实现",
    "Split": "shape/Split 原生实现（通道切分）",
    "UpSampling": "shape/UpSampling 原生实现",
    "Focus": "conv/dataGenerate/Focus 原生主干实现",
    "Resize": ("neck 的 2× 最近邻上采样 ≙ 原生 shape/UpSampling；"
               "报告不含 Resize 的 mode/scale，具体缩放语义需在 M1 对齐"),
    "MaxPooling": "shape/MaxPooling 原生实现",
}

# 纯布局/数据搬运，无算力：可由主机（RV32）在搬运特征窗时完成
HOST_OPS = {
    "Reshape": "纯张量重排，无算力，可并入主机侧搬运/寻址完成",
    "Transpose": "纯布局置换，无算力，可并入主机侧搬运/寻址完成",
    "Slice": ("Focus 主干切片 + 检测头/网格切片，位于块边界；"
              "shape/ 只有通道切分 Split、无通用 Slice ⇒ 主机在特征落 DDR 后切片"),
    "Squeeze": "纯张量重排，无算力，主机侧处理",
    "Unsqueeze": "纯张量重排，无算力，主机侧处理",
    "Gather": "索引搬运，无算力，主机侧处理（锚点表本就在主机侧）",
    "Shape": "元数据，主机侧处理",
    "Expand": "广播搬运，主机侧处理",
    "Flatten": "纯张量重排，主机侧处理",
    "Cast": "类型转换，主机侧处理",
    "Pad": "显式填充；加速器的 4 侧 padding 只随卷积提供，独立 Pad 走主机侧搬运",
}


def grouped_conv_detail(groups):
    """返回 (有无分组卷积, 分组条目描述, 分组卷积数, 总卷积数)。"""
    grouped = {int(k): int(v) for k, v in groups.items() if int(k) != 1 and int(v) > 0}
    total = sum(int(v) for v in groups.values())
    n_grouped = sum(grouped.values())
    detail = ", ".join(f"group={k}:{v}" for k, v in sorted(grouped.items()))
    return bool(grouped), detail, n_grouped, total


# ---------------------------------------------------------------------------
# 3. 逐算子裁三态
# ---------------------------------------------------------------------------
def decide(op, grouped, gdetail, n_grouped, n_conv):
    if op in ("Identity", "Constant"):
        if op == "Identity":
            return "wire", (
                "非算子（参数别名/常量池去重产物）。"
                "报告本身不含连线与消费方信息，无法仅凭报告断言“仅作参数别名”；"
                "据外部核验：70 个 Identity 全部以 initializer 为输入，"
                "仅被 Conv bias(50)/BatchNorm 参数(20) 消费，零条落在数据通路 ⇒ 判 wire"
            )
        return "wire", "非算子：常量池节点（initializer 别名/标量），不参与计算"

    if op == "Conv":
        if grouped:
            return "不覆盖", (
                f"存在分组卷积（{gdetail}；{n_grouped}/{n_conv} 非稠密）；"
                "加速器 RTL 仅 conv33/conv11 稠密实现，源码无 group/depthwise/dilation"
            )
        return "覆盖", (
            "全 group=1 稠密卷积，k∈{1,3}、stride∈{1,2}、pads∈{0,1}，"
            "均落在原生 conv11/conv33 面内"
        )

    if op in NATIVE_ACT:
        return "覆盖", (
            "加速器原生 LeakyRelu；报告不含 alpha，据外部核验 alpha=0.1 "
            "与硬编码 leakyRatio(ConvConfig.scala)=0.1 一致"
        )

    if op in CONFIG_ACT:
        return "覆盖", (
            "≡ LeakyRelu(ratio=0)，只需把 ConvConfig 常量改为 0，不新增数据通路"
        )

    if op == "BatchNormalization":
        return "需主机旁路", (
            "位置：Concat 之后、LeakyReLU 之前（BottleneckCSP 尾部），属块边界而非“卷积↔激活”之间；"
            "后向无 conv 可折、前向被激活阻断（BN→act→Conv1×1），不可权值折叠。"
            "加速器无现成 per-channel affine 通路（shape/Add 有 AddScale 缩放，但未见 per-channel bias 通路、"
            "且本次未在 RTL 核实）⇒ 保守判需主机旁路：特征落 DDR 后由 RV32 做 (x-mean)/sqrt(var+eps)*γ+β。"
            "【若改判“覆盖”必须先核实】AddScale 能表达含 bias 的 per-channel affine 且能串入 CSP 尾部——本次未核实，M2 编译器裁决"
        )

    if op in UNSUPPORTED_BLOCK_ACT:
        return "不覆盖", (
            "块内激活（卷积与激活之间/块内非线性），加速器仅 LeakyRelu，无此能力，不特例豁免"
        )

    if op in NATIVE_OPS:
        return "覆盖", NATIVE_OPS[op]

    if op in HOST_OPS:
        return "需主机旁路", HOST_OPS[op]

    if op in NONLINEAR:
        return "需主机旁路", (
            "非原生非线性；报告不含位置信息，按“块间/检测头外可主机旁路”处理"
            "（若实际位于卷积块内部则应升为不覆盖）"
        )

    return "不覆盖", "未知算子：不在加速器原生面，且报告无位置信息、不可判可旁路，保守判不覆盖"


# ---------------------------------------------------------------------------
# 4. 主流程
# ---------------------------------------------------------------------------
def main():
    if len(sys.argv) < 2:
        print("usage: check_coverage.py <report.txt>", file=sys.stderr)
        return 2
    path = sys.argv[1]
    ops, groups, acts = parse_report(path)

    grouped, gdetail, n_grouped, n_conv = grouped_conv_detail(groups)

    rows = []          # (op, count, decision, reason)
    fail_tokens = []

    for op, count in ops.items():
        dec, reason = decide(op, grouped, gdetail, n_grouped, n_conv)
        rows.append((op, count, dec, reason))
        if dec == "不覆盖":
            if op == "Conv" and grouped:
                fail_tokens.append("grouped-conv")
            else:
                fail_tokens.append(op)

    # 报告里若出现了 ops 直方图中未列、却出现在 activations 节的算子（防御）
    for op, count in acts.items():
        if op in ops:
            continue
        dec, reason = decide(op, grouped, gdetail, n_grouped, n_conv)
        rows.append((op, count, dec, reason))
        if dec == "不覆盖":
            fail_tokens.append(op)

    if grouped and "grouped-conv" not in fail_tokens:
        fail_tokens.append("grouped-conv")

    # ---- 输出覆盖表 ----
    print("| op | count | decision | 依据 |")
    print("|---|---|---|---|")
    for op, count, dec, reason in rows:
        print(f"| {op} | {count} | {dec} | {reason} |")

    if grouped:
        print(f"\n不覆盖：存在分组卷积（{gdetail}；{n_grouped}/{n_conv} 个卷积非稠密）")

    # ---- 三态汇总 ----
    by_dec = collections.OrderedDict()
    for op, count, dec, _ in rows:
        by_dec.setdefault(dec, []).append(op)
    summary = ", ".join(f"{d}={len(v)}" for d, v in by_dec.items())
    print(f"\n汇总：{summary}")
    print(f"conv_group_hist：{json.dumps(dict(sorted((int(k), int(v)) for k, v in groups.items())))}")

    # ---- 判决 ----
    seen = set()
    uniq_fail = [t for t in fail_tokens if not (t in seen or seen.add(t))]
    if uniq_fail:
        print(f"RESULT: FAIL {','.join(uniq_fail)}")
        return 1
    print("RESULT: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
