#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""YuNet 的 DDR 激活流量模型（逐层往返，int8）。

用法：
    # 逐层往返基线
    PYTHONPATH='../third_party/yunet/deps' <py3.9> tools/ddr_traffic.py ../third_party/yunet/yunet.onnx baseline
    # 负对照（自检）：逐层和 == 打印总数；排除输入图像后总数恰好少 3*640*640
    ... tools/ddr_traffic.py ../third_party/yunet/yunet.onnx baseline --selftest
    # 融合策略（C0.2 新增）：fuse_pairs / chip_resident_set
    ... tools/ddr_traffic.py ../third_party/yunet/yunet.onnx fuse_pairs
    ... tools/ddr_traffic.py ../third_party/yunet/yunet.onnx chip_resident_set
    # 互补方向（C0.3 新增）：YuNet 原生块序 1×1(升维) → 3×3(分组/深度)
    ... tools/ddr_traffic.py ../third_party/yunet/yunet.onnx fuse_native
    # 两个方向一起（不做整图常驻）/ 两个方向 + 整图常驻（= fuse_all，行名已在报告里写明）
    ... tools/ddr_traffic.py ../third_party/yunet/yunet.onnx fuse_both
    ... tools/ddr_traffic.py ../third_party/yunet/yunet.onnx fuse_all
    # 打印融合结构（可融合对 + 被挡的对与原因）+ 单读者 guard 负对照 + 片上常驻预算
    ... tools/ddr_traffic.py ../third_party/yunet/yunet.onnx fuse_pairs --fusion-report

输出：逐层表 + 机器可读末行 `TOTAL_BYTES=<n>` + 统一单位（十进制 MB）预算对比行。

============================ 口径（冻结，勿改） ============================
每层 i：  traffic_i = bytes_in_i + bytes_out_i        (int8, 1 byte/element)
整网   ：  Σ traffic_i
不计：    权重（整网 50.3 KB 常驻片上，只装载一次）
只计一次：输入图像本身（1×3×640×640）
不含：    12 个输出头张量的后处理读写、突发对齐/填充浪费、权重装载

本模型是**下界**：
  刻意不计对齐/填充浪费，也不计后处理读写 ⇒ 真实实现的流量只会更高，
  本节数字是 DDR 带宽需求的地板，不是估计值。
==========================================================================

口径与 `ai_npu_exp/tools/yunet_profile.py` 的「层间激活流量」一节逐字一致：
只走 Conv 节点，累加该节点 input[0] 与 output[0] 的 4 维张量元素数
（= NCHW 单样本的 C*H*W，int8 即字节数），形状由 onnx.shape_inference 推断得到。
"""
import sys
import collections
import onnx
from onnx import shape_inference

# Windows 控制台是 GBK，非 ASCII 直接写会炸；统一换成可替换字符。
sys.stdout.reconfigure(errors="replace")
sys.stderr.reconfigure(errors="replace")

# ---- 板级常量（来自静态分析口径；本模型不改这两个数，只做换算） ----
DDR_MBPS = 275.9          # SoC DDR 桥可持续带宽（MB/s，十进制 1e6 B/s；见 partA/ddr_path_ceiling.md）
TARGET_FPS = 10.0         # 目标帧率（C0.2 判定用的档）
FPS_TIER15 = 15.0         # 15fps 档（C0.3 判定用；预算 = 275.9/15 = 18.39 MB/帧）
BUDGET_MB_PER_FRAME = DDR_MBPS / TARGET_FPS   # = 27.59 MB/帧（十进制）；> 此数即超预算
MIB = 1024 * 1024

# ---- 片上常驻预算（策略 chip_resident_set 用；**假设**，面积闸门后续须复核） ----
# 推导（依据 y1/reports/g1_area.md 的实测与 SoC 基线）：
#   切片 WIDTH=640: DRM 0/415；SoC 基线: DRM 23.5/415；切片 LUT 26447/159800=17%
#   可用 DRM36K = 415 - 23.5(SoC) - 0(切片) = 391.5 个
#   1 个 DRM36K = 36 Kbit = 36864 bit = 4608 B
#   可用片上 RAM = 391.5 * 4608 = 1,804,032 B ≈ 1.72 MiB
#   只取一半做激活缓冲（另一半留给整个加速器的仲裁/对齐/权重暂存）⇒ ≈ 880 KiB
#   2 块缓冲（生产者→消费者双缓冲，最坏只需同时驻留"当前输入 + 当前输出"两块）
#   ⇒ 单张上限 = 880 KiB / 2 ≈ 440 KiB，取整到自然形状 80*80*64 = 409,600 B = 400 KiB
#   ⇒ 2 * 400 KiB = 800 KiB ≤ 880 KiB（占可用 DRAM 的 45%）
BUDGET_BYTES = 409600     # 单张特征图常驻上限（int8）
CHIP_BUFFERS = 2          # 同时驻留的缓冲块数（双缓冲模型）


# ============================ 形状访问层 ============================
class GraphView(object):
    """把 ONNX 图的形状/字节数查询包一层，供各 strategy 复用。"""

    def __init__(self, onnx_path):
        self.path = onnx_path
        m = onnx.load(onnx_path)
        mi = shape_inference.infer_shapes(m)
        # 与参考脚本一致：value_info + input + output 三处合并
        self.vi = {v.name: v
                   for v in list(mi.graph.value_info) + list(mi.graph.input) + list(mi.graph.output)}
        self.graph_input_names = [i.name for i in mi.graph.input]
        self.conv_nodes = [n for n in mi.graph.node if n.op_type == "Conv"]
        # 全节点列表与消费者表：张量 -> 消费它的节点下标（用于扇出判定，融合策略要用）
        self.nodes = list(mi.graph.node)
        self.consumers = collections.defaultdict(list)
        for i, n in enumerate(self.nodes):
            for t in n.input:
                if t:
                    self.consumers[t].append(i)
        self.graph_output_names = [o.name for o in mi.graph.output]

    def shape_of(self, name):
        v = self.vi.get(name)
        if v is None:
            return None
        d = v.type.tensor_type.shape.dim
        return [x.dim_value if x.HasField("dim_value") else 0 for x in d]

    def act_bytes(self, name):
        """激活张量的 int8 字节数；不是 4 维（NCHW）则返回 None（表示"不参与计数"）。"""
        s = self.shape_of(name)
        if not s or len(s) != 4:
            return None
        return s[1] * s[2] * s[3]

    def consumers_of(self, name):
        """消费张量 name 的节点下标列表（空列表 ⇒ 无消费者）。"""
        return self.consumers.get(name, [])


# ============================ 结果行 ============================
Row = collections.namedtuple("Row", "idx name bytes_in bytes_out traffic")


def compute_rows(gv, exclude_tensors=()):
    """逐层往返：traffic = bytes_in + bytes_out。

    exclude_tensors: 若某张量在集合里，则它作为 Conv 输入时不计入（用于负对照：
                     排除输入图像本身，验证它恰好被计了一次）。
    """
    exclude_tensors = set(exclude_tensors)
    rows = []
    for idx, n in enumerate(gv.conv_nodes):
        b_in = 0 if n.input[0] in exclude_tensors else (gv.act_bytes(n.input[0]) or 0)
        b_out = gv.act_bytes(n.output[0]) or 0
        rows.append(Row(idx, n.name, b_in, b_out, b_in + b_out))
    return rows


# ============================ 策略注册表 ============================
# 本任务只实现 baseline；后续任务在此表里加融合策略，接口不变。
STRATEGIES = {}


def register(name):
    def deco(fn):
        STRATEGIES[name] = fn
        return fn
    return deco


@register("baseline")
def strategy_baseline(gv):
    """逐层往返基线：每层读写各自的输入与输出，不在层间复用。"""
    return compute_rows(gv, exclude_tensors=())


# ============================ 融合策略（C0.2） ============================
# 逐元素、形状保持的算子：可以"穿透"融合（中间张量不出片）。
ELEMENTWISE_OPS = ("Relu", "Sigmoid", "Clip", "LeakyRelu", "PRelu", "HardSigmoid")


def conv_ints(node, key):
    for a in node.attribute:
        if a.name == key:
            return list(a.ints)
    return None


def conv_kernel(node):
    return conv_ints(node, "kernel_shape")


def conv_strides(node):
    st = conv_ints(node, "strides")
    return [1, 1] if st is None else st


def _consumer_summary(gv, tensor):
    """把某个张量的消费者按算子类型汇总成 op×n 的可读串（用于被挡原因）。"""
    cnt = collections.Counter(gv.nodes[i].op_type for i in gv.consumers_of(tensor))
    return "+".join("%s×%d" % (k, v) if v > 1 else k for k, v in cnt.items())


def compute_rows_fused(gv, drop_out=(), drop_in=()):
    """在逐层往返口径上，把若干中间张量从 DDR 计账里去掉（口径/格式/TOTAL_BYTES 不变）：
       drop_out: 这些 Conv 名称的输出留在片上 ⇒ 不计它的「写」；
       drop_in : 这些输入张量名从片上读     ⇒ 不计它的「读」。
    """
    drop_out = set(drop_out)
    drop_in = set(drop_in)
    rows = []
    for idx, n in enumerate(gv.conv_nodes):
        b_in = 0 if n.input[0] in drop_in else (gv.act_bytes(n.input[0]) or 0)
        b_out = 0 if n.name in drop_out else (gv.act_bytes(n.output[0]) or 0)
        rows.append(Row(idx, n.name, b_in, b_out, b_in + b_out))
    return rows


def find_fusion_pairs(gv, enforce_single_reader=True):
    """找「3×3( stride1 ) --(逐元素)--► 1×1」可融合对，并给出每个 3×3 的裁决。

    融合规则（可复算）：
      1) 单元 = (A, B)：A 是 3×3 卷积且 strides=[1,1]，B 是紧随其后的 1×1 卷积；
      2) A.output 经"只含逐元素算子(Relu/Sigmoid/...)"的链条到达 B.input[0]；
      3) 链条上**每一个**张量（A.output 及每个逐元素输出）消费者数 == 1
         ⇒ 中间张量不被别处需要，可整段留在片上；
    被挡的按**首先触发**的那条 guard 记录原因。

    enforce_single_reader=False 时**临时**关掉第 3) 条（负对照用；默认 True，行为不变）。

    显式不跨的四个边界与其理由：
      MaxPool —— 下采样改变图尺寸，融合单元输出的坐标基础被打断；
      Resize  —— 上采样同理，且引入插值状态；
      Add     —— 残差把两条路径相加，中间张量还有第二个读者（fan-out），必须落片；
      Concat  —— 拼接把多张图合成一张，边界不再是"一对一"数据流（本图无 Concat，规则保留）。
    """
    by_idx = gv.nodes
    fusible, blocked = [], []
    for A in gv.conv_nodes:
        if conv_kernel(A) != [3, 3]:
            continue
        st = conv_strides(A)
        if st != [1, 1]:
            blocked.append((A, "3×3 步长 %s≠1（下采样）" % st))
            continue
        cur = A.output[0]
        reason = None
        while reason is None:
            cons = gv.consumers_of(cur)
            if len(cons) == 0:
                reason = "无消费者（悬空/图输出）"
                break
            if len(cons) > 1 and enforce_single_reader:
                reason = ("扇出 %d（消费者 %s）⇒ 中间张量被别处需要，必须落片"
                          % (len(cons), _consumer_summary(gv, cur)))
                break
            node = by_idx[cons[0]]
            if node.op_type in ELEMENTWISE_OPS:
                cur = node.output[0]
                continue
            if node.op_type == "Conv":
                if conv_kernel(node) == [1, 1]:
                    fusible.append((A, node))
                else:
                    reason = "消费者是卷积 %s（非 1×1）" % conv_kernel(node)
                break
            reason = "跨越 %s 边界（%s ⇒ 中间张量必须落片）" % (node.op_type, node.name)
        if reason is not None:
            blocked.append((A, reason))
    return fusible, blocked


@register("fuse_pairs")
def strategy_fuse_pairs(gv):
    """两两融合：可融合的「3×3 → 1×1」单元视为一个整体，单元内部中间张量不出片
       ⇒ 该 3×3 的输出（写）与紧随 1×1 的输入（读）均不计 DDR（省 2×size）。
       规则与 guard 见 find_fusion_pairs。"""
    fusible, _ = find_fusion_pairs(gv)
    drop_out = set(A.name for (A, B) in fusible)
    drop_in = set(B.input[0] for (A, B) in fusible)
    return compute_rows_fused(gv, drop_out=drop_out, drop_in=drop_in)


def chip_resident_tensors(gv):
    """可整张常驻片上的特征图：(tensor, producer_conv, [reader_conv,...])。
       条件：由某个 Conv 产出；消费者**全是** Conv（且都以它为 input[0]）；
             字节数 ≤ BUDGET_BYTES。"""
    out = []
    for n in gv.conv_nodes:
        T = n.output[0]
        size = gv.act_bytes(T)
        if size is None or size > BUDGET_BYTES:
            continue
        readers, ok = [], True
        for ci in gv.consumers_of(T):
            c = gv.nodes[ci]
            if c.op_type == "Conv" and c.input[0] == T:
                readers.append(c)
            else:
                ok = False
                break
        if ok and readers:
            out.append((T, n, readers))
    return out


@register("chip_resident_set")
def strategy_chip_resident_set(gv):
    """在 fuse_pairs 之上，再把「≤ BUDGET_BYTES 的整张特征图」常驻片上：
       该图的产出（写）与消费（读）都不走 DDR ⇒ 省 2×size。
       BUDGET_BYTES 的来源见文件顶部注释（面积假设，面积闸门后续须复核）。"""
    fusible, _ = find_fusion_pairs(gv)
    drop_out = set(A.name for (A, B) in fusible)
    drop_in = set(B.input[0] for (A, B) in fusible)
    for T, producer, readers in chip_resident_tensors(gv):
        drop_out.add(producer.name)
        drop_in.add(T)          # 每个 reader 读的都是同一个 T
    return compute_rows_fused(gv, drop_out=drop_out, drop_in=drop_in)


# ============================ 互补方向融合（C0.3） ============================
def find_fusion_pairs_native(gv, enforce_single_reader=True):
    """找 YuNet **原生块序**的「1×1(升维) --(逐元素)--► 3×3(分组/深度)」可融合对。

    融合规则（可复算，逐条可查；本图 N1/N2/N3/N5 **一条都没触发**）：
      N0 单元 = (A, B)：A 是 1×1 卷积（kernel==[1,1]，升维/投影），
         B 是以 A 的输出（可经逐元素链）为 input[0] 的 3×3 卷积（kernel==[3,3]）；
      N1 步长：A.strides == [1,1] **且** B.strides == [1,1]。
         A 步长 >1 会改变中间张量的空间尺寸（"同一片"的前提没了）；B 步长 >1 会把
         下采样塞进融合单元、边界重述会变。二者都判 blocked（记录原因）。
         **本图 26 对的 A、B 步长全为 [1,1] ⇒ N1 不触发。**
      N2 可穿透：A.output 到 B.input[0] 的链上只含逐元素算子（Relu/Sigmoid/…），
         逐元素形状保持、不引入新边界。**本图 26 对全是直接相邻（链为空）⇒ N2 不触发。**
      N3 单读者（**承担证明责任的那条**）：链上每一个张量 consumers_of(t) == 1。
         >1 个消费者 ⇒ 中间张量还被别处需要、**必须落片**（写不能省），
         "既不写也不读 ⇒ 省 2×size" 这条结论不成立。负对照见 negctl_reader_guard()。
         **本图 26 对全部满足（readers=1）⇒ N3 不触发（但它正是 2× 记法的依据）。**
      N4 分组：B 允许是分组/深度卷积（group ≥ 1；本图 group ∈ {1,4,10,16,32,64}）。
         融合**与 group 无关**：消掉的只是"A 输出张量"这一个 DDR 边界，张量尺寸直接从
         图里读（C_in×H×W，int8 即字节数），与 group 内部怎么分通道无关；
         唯一要求是 C_out(A) == C_in(B)（本例由 shape 推断保证，逐对断言）。
         注意 group==C_in（深度）只是 group>1 的特例，本图 26 对里既有 group=C_in 的
         （如 Conv_3/Conv_7 group=16=C_in），也有 group<C_in 的分组卷积
         （如 Conv_10 group=32、C_in=128）——两者走**同一**条账，不做区分。
      N5 不跨边界：链上不得出现 Concat / MaxPool / Resize / Add（残差把两条路径相加，
         中间张量有第二个读者 ⇒ 撞 N3）以及任何非卷积终端。**本图 26 对无此情形 ⇒ N5 不触发。**

    被挡的按**首先触发**的那条 guard 记录原因。

    返回 fusible = [(A_1x1, B_3x3, mid_tensor, chain)]，blocked = [(A, reason)]。
    mid_tensor == B.input[0]；chain 为被消掉的中间张量列表（链为空时 == [mid_tensor]）。
    """
    fusible, blocked = [], []
    for A in gv.conv_nodes:
        if conv_kernel(A) != [1, 1]:
            continue
        stA = conv_strides(A)
        if stA != [1, 1]:
            blocked.append((A, "N1 1×1 步长 %s≠1（改变中间张量空间尺寸）" % stA))
            continue
        cur = A.output[0]
        chain = []
        reason = None
        B = None
        while reason is None:
            chain.append(cur)
            cons = gv.consumers_of(cur)
            if len(cons) == 0:
                reason = "无消费者（悬空/图输出）"
                break
            if len(cons) > 1 and enforce_single_reader:
                reason = ("N3 扇出 %d（消费者 %s）⇒ 中间张量被别处需要，必须落片"
                          % (len(cons), _consumer_summary(gv, cur)))
                break
            node = gv.nodes[cons[0]]
            if node.op_type in ELEMENTWISE_OPS:
                cur = node.output[0]
                continue
            if node.op_type == "Conv":
                if conv_kernel(node) != [3, 3]:
                    reason = "消费者是卷积 %s（非 3×3）" % conv_kernel(node)
                elif conv_strides(node) != [1, 1]:
                    reason = "N1 3×3 步长 %s≠1（下采样）" % conv_strides(node)
                else:
                    B = node
                break
            reason = "N5 跨越 %s 边界（%s ⇒ 中间张量必须落片）" % (node.op_type, node.name)
        if B is not None and reason is None:
            fusible.append((A, B, cur, list(chain)))
        else:
            blocked.append((A, reason))
    return fusible, blocked


def _native_pair_saving(gv, A, B, mid, chain):
    """单对 1×1→3×3 的 DDR 记账省量（B）。
       本图 26 对链为空（chain == [mid]）⇒ 该张量被记两次（A 的"写" + B 的"读"）
       ⇒ 省 2×size(mid)。链上有逐元素张量时，A.output 只被记一次（逐元素不算 Conv 行），
       故此处显式断言"链为空"，避免把 2× 用错地方。"""
    assert len(chain) == 1, \
        "1×1→3×3 融合单元的中间链不为空（%r）：2×size 记账需要复核" % (chain,)
    mid_b = gv.act_bytes(mid)
    assert mid_b is not None, "中间张量 %r 不是 4 维张量，不能按激活计账" % (mid,)
    assert gv.act_bytes(A.output[0]) == gv.act_bytes(B.input[0]), \
        "C_out(1×1)=%r ≠ C_in(3×3)=%r" % (gv.act_bytes(A.output[0]), gv.act_bytes(B.input[0]))
    return 2 * mid_b


def _fusion_drop_sets(gv):
    """两个方向（3×3→1×1 与 1×1→3×3）的融合 drop 集合的**并集**。
       两个方向的 drop 对象互不相同（各消自己那条边界上的张量），故并集即相加，无重复计。"""
    fu33, _ = find_fusion_pairs(gv)
    fu11, _ = find_fusion_pairs_native(gv)
    drop_out = set(A.name for (A, B) in fu33)
    drop_in = set(B.input[0] for (A, B) in fu33)
    for (A, B, mid, chain) in fu11:
        _native_pair_saving(gv, A, B, mid, chain)   # 逐对复核（含 C_out==C_in 断言）
        drop_out.add(A.name)
        drop_in.add(mid)
    return drop_out, drop_in


# 策略名 → 一句话说明（打印出来，避免 fuse_all 那行被误读成"只融合"）
STRATEGY_DESC = {
    "baseline": "逐层往返，无融合、无片上常驻",
    "fuse_pairs": "只融合 3×3→1×1（7 对）",
    "fuse_native": "只融合 1×1→3×3（26 对，YuNet 原生块序）",
    "chip_resident_set": "3×3→1×1 融合 + ≤400KiB 整图常驻",
    "fuse_both": "两个方向都融合（33 对），不做整图常驻",
    "fuse_all": "两个方向都融合（33 对）+ ≤400KiB 整图常驻",
}


@register("fuse_native")
def strategy_fuse_native(gv):
    """互补方向：把可融合的「1×1 → 3×3」单元视为一个整体，单元内部中间张量不出片
       ⇒ 该 1×1 的输出（写）与紧随 3×3 的输入（读）均不计 DDR（省 2×size）。
       规则与 guard 见 find_fusion_pairs_native。"""
    fusible, _ = find_fusion_pairs_native(gv)
    drop_out, drop_in = set(), set()
    for (A, B, mid, chain) in fusible:
        _native_pair_saving(gv, A, B, mid, chain)
        drop_out.add(A.name)
        drop_in.add(mid)
    return compute_rows_fused(gv, drop_out=drop_out, drop_in=drop_in)


@register("fuse_both")
def strategy_fuse_both(gv):
    """两个方向（3×3→1×1 与 1×1→3×3）在各自合法处都融合；**不做**整图常驻。"""
    drop_out, drop_in = _fusion_drop_sets(gv)
    return compute_rows_fused(gv, drop_out=drop_out, drop_in=drop_in)


@register("fuse_all")
def strategy_fuse_all(gv):
    """fuse_both **再叠加** chip_resident_set：两个方向都融合，且把 ≤ BUDGET_BYTES 的
       整张特征图常驻片上（写与读都不走 DDR）⇒ 省量是可叠加的，但**多了一个面积假设**
       （400 KiB×2 缓冲），面积闸门须复核。"""
    drop_out, drop_in = _fusion_drop_sets(gv)
    for T, producer, readers in chip_resident_tensors(gv):
        drop_out.add(producer.name)
        drop_in.add(T)
    return compute_rows_fused(gv, drop_out=drop_out, drop_in=drop_in)


# ============================ 打印 ============================
def print_table(rows):
    hdr = "%-4s %-44s %12s %12s %12s" % ("idx", "name", "in_B", "out_B", "traffic_B")
    print(hdr)
    print("-" * len(hdr))
    for r in rows:
        print("%-4d %-44s %12d %12d %12d" % (r.idx, r.name[:44], r.bytes_in, r.bytes_out, r.traffic))
    print("-" * len(hdr))
    print("%-4s %-44s %12d %12d %12d" % ("", "SUM(%d layers)" % len(rows),
                                         sum(r.bytes_in for r in rows),
                                         sum(r.bytes_out for r in rows),
                                         sum(r.traffic for r in rows)))


def print_summary(rows, strategy):
    total = sum(r.traffic for r in rows)
    mb = total / MIB
    fps_exact = DDR_MBPS / mb
    print()
    print("== 策略 %s：层间激活流量（决定 DDR 带宽下限，比 MAC 数更可能是真瓶颈）==" % strategy)
    print("TOTAL_BYTES=%d" % total)
    print("  每帧 = %d B ≈ %.1f MB/帧（1024² 口径；%.4f MB）" % (total, mb, mb))
    print("  隐含 fps @%.1f MB/s ≈ %.2f（%.1f ÷ %.4f；本模型是下界，真实只会更低）"
          % (DDR_MBPS, fps_exact, DDR_MBPS, mb))
    print("  预算 ≤ %.1f MB/帧 @%.0f fps ⇒ 本基线 %.1f MB/帧，超出 %.2f×，只能跑 ≈%.1f fps"
          % (BUDGET_MB_PER_FRAME, TARGET_FPS, mb, mb / BUDGET_MB_PER_FRAME, fps_exact))
    return total


# ============================ 统一单位 / 融合结构 打印 ============================
def print_unit_note(rows, strategy):
    """统一单位（十进制 MB，1 MB=1e6 B）的预算对比行；与板级 275.9 MB/s 同口径。
       注意：上面 print_summary 那条旧行是 1024²（MiB）口径，两者不可混用。
       之后两行是本任务（C0.3）新增的**并列**信息：策略说明 + 15fps 档预算，原行未改。"""
    total = sum(r.traffic for r in rows)
    mb = total / 1e6
    fps = DDR_MBPS / mb
    over = mb / BUDGET_MB_PER_FRAME
    print("  [统一单位] 十进制 MB（1 MB=1e6 B，与 275.9 MB/s 同口径）："
          "%.4f MB/帧；隐含 %.2f fps；预算 %.2f MB/帧 ⇒ %s（%.3f×）"
          % (mb, fps, BUDGET_MB_PER_FRAME,
             "达标" if mb <= BUDGET_MB_PER_FRAME else "超预算", over))
    print("  [策略] %s = %s" % (strategy, STRATEGY_DESC.get(strategy, "（未登记说明）")))
    b15 = DDR_MBPS / FPS_TIER15
    print("  [15fps 档] 预算 %.2f MB/帧（=%.1f÷%.0f）⇒ %s；余量 %+.1f%%"
          % (b15, DDR_MBPS, FPS_TIER15,
             "达标" if mb <= b15 else "超预算",
             100.0 * (fps / FPS_TIER15 - 1.0)))


def print_fusion_report(gv, negctl=True):
    fusible, blocked = find_fusion_pairs(gv)
    n3 = sum(1 for n in gv.conv_nodes if conv_kernel(n) == [3, 3])
    print()
    print("== 融合结构（规则：3×3 stride1 --逐元素--► 1×1）==")
    print("3×3 卷积 %d 个：可融合 %d 对，被挡 %d 个" % (n3, len(fusible), len(blocked)))
    print("-- 可融合对（中间张量不出片，省 2×size）--")
    print("%-9s %-9s %10s  %s" % ("3x3", "1x1", "mid_B", "mid_tensor"))
    tot = 0
    for (A, B) in fusible:
        T = A.output[0]
        s = gv.act_bytes(T) or 0
        tot += 2 * s
        print("%-9s %-9s %10d  %s" % (A.name, B.name, s, T))
    print("  可融合省下合计 = %d B（%.4f MB）" % (tot, tot / 1e6))
    print("-- 被挡（按首先触发的 guard）--")
    print("%-9s %10s  %s" % ("3x3", "out_B", "blocked_by"))
    for (A, reason) in blocked:
        print("%-9s %10d  %s" % (A.name, gv.act_bytes(A.output[0]) or 0, reason))
    print("FUSED %d pairs saved=%d blocked=%d" % (len(fusible), tot, len(blocked)))

    print_fusion_report_native(gv)
    if negctl:
        negctl_reader_guard(gv)
    print_additive_note(gv)


def print_fusion_report_native(gv):
    """互补方向（1×1→3×3）的逐对自证：中间张量、读者数、省量，并与 2×size 断言对账。"""
    fusible, blocked = find_fusion_pairs_native(gv)
    n1 = sum(1 for n in gv.conv_nodes if conv_kernel(n) == [1, 1])
    print()
    print("== 互补融合结构（规则：1×1 stride1 --逐元素--► 3×3 stride1；YuNet 原生块序）==")
    print("1×1 卷积 %d 个：可融合 %d 对，被挡 %d 个" % (n1, len(fusible), len(blocked)))
    print("  注意：3×3 侧允许 group>1（本图 group∈{1,4,10,16,32,64}）；"
          "融合只消掉 'A 的输出张量' 这一条 DDR 边界，与 group 如何分通道无关。")
    print("-- 可融合对（中间张量不出片；读者数必须 ==1；省量断言 == 2×mid_B）--")
    print("%-9s %-9s %8s %8s %10s  %s" % ("1x1", "3x3", "grp", "readers", "mid_B", "assert"))
    tot = 0
    ok_all = True
    for (A, B, mid, chain) in fusible:
        s = _native_pair_saving(gv, A, B, mid, chain)
        mid_b = gv.act_bytes(mid) or 0
        readers = len(gv.consumers_of(mid))
        grp = 1
        for a in B.attribute:
            if a.name == "group":
                grp = a.i
        ok = (readers == 1) and (s == 2 * mid_b)
        ok_all &= ok
        tot += s
        print("%-9s %-9s %8d %8d %10d  %s（2×%d=%d）"
              % (A.name, B.name, grp, readers, mid_b,
                 "OK" if ok else "FAIL", mid_b, 2 * mid_b))
    print("  可融合省下合计 = %d B（%.4f MB）" % (tot, tot / 1e6))
    print("-- 被挡（按首先触发的 guard；N1 步长 / N3 扇出 / N5 边界）--")
    if blocked:
        print("%-9s %10s  %s" % ("1x1", "out_B", "blocked_by"))
        for (A, reason) in blocked:
            print("%-9s %10d  %s" % (A.name, gv.act_bytes(A.output[0]) or 0, reason))
    else:
        print("（无：本图 26 个 1×1 全部可融合，N1/N2/N5 一条都没触发）")
    print("断点自证：逐对 读者数==1 且 省量==2×mid_B : %s" % ("PASS" if ok_all else "FAIL"))
    print("FUSED %d pairs saved=%d blocked=%d" % (len(fusible), tot, len(blocked)))
    return ok_all


def _fuse_pairs_drop_sets(gv, enforce_single_reader=True):
    """3×3→1×1 方向的 drop 集合（enforce_single_reader 只给负对照用）。"""
    fusible, _ = find_fusion_pairs(gv, enforce_single_reader=enforce_single_reader)
    return (set(A.name for (A, B) in fusible),
            set(B.input[0] for (A, B) in fusible))


def _native_drop_sets(gv, enforce_single_reader=True):
    """1×1→3×3 方向的 drop 集合（enforce_single_reader 只给负对照用）。"""
    fusible, _ = find_fusion_pairs_native(gv, enforce_single_reader=enforce_single_reader)
    drop_out, drop_in = set(), set()
    for (A, B, mid, chain) in fusible:
        _native_pair_saving(gv, A, B, mid, chain)
        drop_out.add(A.name)
        drop_in.add(mid)
    return drop_out, drop_in


def negctl_reader_guard(gv):
    """负对照：**临时**关掉"单读者" guard，量出账目确实因此改变（证明它不是装饰），
       量完立刻复位并逐对复核复位（靠默认参数，没有任何持久改动）。

       量的两把尺子：
         (1) 逐对"声称值" = Σ 2×size（与 --fusion-report 的 FUSED 行同口径）；
         (2) **模型级**省量 = baseline_total − 该策略 TOTAL（真账）。
    """
    base = sum(r.traffic for r in STRATEGIES["baseline"](gv))
    print()
    print("== 负对照：单读者 guard 关掉会怎样（量完立刻复位）==")
    specs = (("3x3->1x1", _fuse_pairs_drop_sets,
              lambda fu: sum(2 * (gv.act_bytes(B.input[0]) or 0) for (A, B) in fu),
              lambda p: p[1].input[0], find_fusion_pairs),
             ("1x1->3x3", _native_drop_sets,
              lambda fu: sum(_native_pair_saving(gv, A, B, mid, ch)
                             for (A, B, mid, ch) in fu),
              lambda p: p[2], find_fusion_pairs_native))
    before, changed = {}, False
    for label, dset_fn, claim_fn, mid_of, finder in specs:
        fu_on, bl_on = finder(gv, enforce_single_reader=True)
        before[label] = (fu_on, bl_on)
        fu_off, bl_off = finder(gv, enforce_single_reader=False)
        c_on, c_off = claim_fn(fu_on), claim_fn(fu_off)
        do_on, di_on = dset_fn(gv, True)
        do_off, di_off = dset_fn(gv, False)
        t_on = sum(r.traffic for r in compute_rows_fused(gv, drop_out=do_on, drop_in=di_on))
        t_off = sum(r.traffic for r in compute_rows_fused(gv, drop_out=do_off, drop_in=di_off))
        new = [p for p in fu_off if p not in fu_on]
        print("NEGCTL %-9s guard=ON  n=%-2d 逐对声称=%-9d blocked=%-2d 模型 TOTAL=%-9d 模型省量=%d"
              % (label, len(fu_on), c_on, len(bl_on), t_on, base - t_on))
        print("NEGCTL %-9s guard=OFF n=%-2d 逐对声称=%-9d blocked=%-2d 模型 TOTAL=%-9d 模型省量=%d"
              % (label, len(fu_off), c_off, len(bl_off), t_off, base - t_off))
        dt = t_off - t_on
        print("         Δ逐对声称=%+d   Δ模型省量=%+d%s"
              % (c_off - c_on, -dt,
                 "（关 guard 后模型 TOTAL 从 %d 变到 %d ⇒ 账目确实改变，这条 guard 不是装饰）"
                 % (t_on, t_off) if dt else "（本方向没有变化）"))
        if not new:
            print("         （本方向无新增对：26 个 1×1 的中间张量本来就全是单读者 ⇒ 这条 guard")
            print("           在本方向上不触发，但它正是 2×size 记法成立的依据）")
        for p in new:
            T = mid_of(p)
            r = len(gv.consumers_of(T))
            nb = gv.act_bytes(T) or 0
            print("         新增对 %s：readers=%d（≠1）mid=%s %d B"
                  % (p[0].name, r, T, nb))
            print("            逐对表声称 2×size=%d B；但该张量的 [写] 只有在 [全部 %d 个读者]"
                  "都从片上取时才可省" % (2 * nb, r))
            print("            ⇒ 一个 [成对融合] 最多只敢声称 1×size=%d B（比 2×size 小一半）；"
                  "剩下的 (r-1)×size 属于 [整图常驻] 的裁决，不是本 guard 能背书的事"
                  % nb)
        if t_off != t_on:
            changed = True
    # 复位复核：再按默认（guard 开）跑一遍，必须与最初逐对完全一致
    restored = True
    for label, finder in (("3x3->1x1", find_fusion_pairs), ("1x1->3x3", find_fusion_pairs_native)):
        fu2, bl2 = finder(gv)          # 默认参数（guard 开）
        restored &= (fu2 == before[label][0]) and (bl2 == before[label][1])
    print("NEGCTL 断言：关 guard 后**账目确实改变**（模型 TOTAL 变了）: %s"
          % ("PASS" if changed else "FAIL"))
    print("NEGCTL guard 已复位（默认 enforce_single_reader=True；逐对复核一致）: %s"
          % ("PASS" if restored else "FAIL"))
    return changed and restored


def print_additive_note(gv):
    """把"叠加效果"摊成集合级可复算的账：
       为什么 fuse_all == fuse_both（片上常驻被 1×1→3×3 融合**完全覆盖**）。"""
    fu33, _ = find_fusion_pairs(gv)
    fu11, _ = find_fusion_pairs_native(gv)
    d_out33 = set(A.name for (A, B) in fu33)
    d_in33 = set(B.input[0] for (A, B) in fu33)
    d_out11 = set(A.name for (A, B, mid, ch) in fu11)
    d_in11 = set(mid for (A, B, mid, ch) in fu11)
    res = chip_resident_tensors(gv)
    res_out = set(p.name for (T, p, rs) in res)
    res_in = set(T for (T, p, rs) in res)
    s33 = sum(2 * (gv.act_bytes(B.input[0]) or 0) for (A, B) in fu33)
    s11 = sum(_native_pair_saving(gv, A, B, mid, ch) for (A, B, mid, ch) in fu11)
    sres = sum(2 * (gv.act_bytes(T) or 0) for (T, p, rs) in res)
    ov_out, ov_in = len(d_out33 & d_out11), len(d_in33 & d_in11)
    fully_covered = (len(res_in & d_in11) == len(res_in)) and (len(res_out & d_out11) == len(res_out))
    print()
    print("== 叠加关系（集合级，可复算）==")
    print("fuse_pairs  : drop_out %d 节点 / drop_in %d 张量，省 %d B"
          % (len(d_out33), len(d_in33), s33))
    print("fuse_native : drop_out %d 节点 / drop_in %d 张量，省 %d B"
          % (len(d_out11), len(d_in11), s11))
    print("两方向 drop 交集：节点 %d 个、张量 %d 个 ⇒ 省量%s（%d + %d = %d B）"
          % (ov_out, ov_in, "可直接相加" if (ov_out == 0 and ov_in == 0) else "需去重",
             s33, s11, s33 + s11))
    print("chip_resident: %d 节点 / %d 张量，省 %d B；落在 native drop 集合内的：节点 %d、张量 %d"
          % (len(res_out), len(res_in), sres,
             len(res_out & d_out11), len(res_in & d_in11)))
    print("   ⇒ 22 张常驻张量的 [写] 与 [读] 是否全部已被 1×1→3×3 融合覆盖：%s"
          % ("是（增量 0 B）" if fully_covered else "否（需要逐张复核）"))
    print("   ⇒ fuse_all 相对 fuse_both 的增量 = %d B；理由是 %d 个 native 中间张量里有 %d 张"
          " ≤400KiB（正是常驻集），另 %d 张 >400KiB 常驻不下、只能靠流式融合消掉"
          % (0 if fully_covered else -1, len(d_in11), len(res_in), len(d_in11) - len(res_in)))


def print_chip_budget(gv):
    res = chip_resident_tensors(gv)
    saved = sum(2 * (gv.act_bytes(T) or 0) for (T, _, _) in res)
    print()
    print("== 片上常驻预算（chip_resident_set）==")
    print("单张上限 BUDGET_BYTES=%d B（= %.1f KiB = 100×80×80 int8）；缓冲数=%d；"
          "推导见脚本顶部注释（面积假设，闸门后续复核）"
          % (BUDGET_BYTES, BUDGET_BYTES / 1024.0, CHIP_BUFFERS))
    print("可常驻特征图 %d 张，省 DDR = %d B（%.4f MB）" % (len(res), saved, saved / 1e6))
    print("%-7s %-9s %s" % ("tensor", "producer", "readers"))
    for (T, producer, readers) in res:
        print("%-7s %-9s %s" % (T, producer.name, ",".join(r.name for r in readers)))


# ============================ 负对照自检 ============================
def selftest(gv, strategy):
    """负对照：让 31942400 不能是"碰巧"得来。"""
    ok_all = True

    rows = STRATEGIES[strategy](gv)
    printed_total = sum(r.traffic for r in rows)

    # (a) 逐层和 == 打印总数（独立于 print_summary 的路径再算一遍）
    flat = 0
    for r in rows:
        flat += r.bytes_in
        flat += r.bytes_out
    a_ok = (flat == printed_total)
    ok_all &= a_ok
    print("[selftest] (a) 逐层 traffic 求和 == 打印总数 : %s（%d vs %d）"
          % ("PASS" if a_ok else "FAIL", flat, printed_total))

    # (b) 排除输入图像本身后，总数恰好少 3*640*640
    img_name = gv.graph_input_names[0]
    img_shape = gv.shape_of(img_name)
    rows_no_img = compute_rows(gv, exclude_tensors={img_name})
    total_no_img = sum(r.traffic for r in rows_no_img)
    delta = printed_total - total_no_img
    expected = 3 * 640 * 640
    b_ok = (delta == expected)
    ok_all &= b_ok
    print("[selftest] (b) 排除输入图像后总数差 == 3*640*640 : %s"
          % ("PASS" if b_ok else "FAIL"))
    print("           输入张量 %s shape=%s；差值 = %d，期望 = %d"
          % (img_name, img_shape, delta, expected))
    if img_shape != [1, 3, 640, 640]:
        print("           注意：输入 shape 不是 [1,3,640,640]，期望值假设需要复核")

    print("[selftest] 合计：%s" % ("PASS" if ok_all else "FAIL"))
    return 0 if ok_all else 1


# ============================ main ============================
def main(argv):
    args = [a for a in argv[1:] if not a.startswith("--")]
    flags = [a for a in argv[1:] if a.startswith("--")]

    if len(args) < 1:
        print(__doc__)
        print("可用策略：%s" % ", ".join(sorted(STRATEGIES)))
        return 2

    onnx_path = args[0]
    strategy = args[1] if len(args) > 1 else "baseline"
    if strategy not in STRATEGIES:
        print("未知策略 %r；可用：%s" % (strategy, ", ".join(sorted(STRATEGIES))))
        return 2

    gv = GraphView(onnx_path)

    if "--selftest" in flags:
        return selftest(gv, strategy)

    rows = STRATEGIES[strategy](gv)
    print_table(rows)
    print_summary(rows, strategy)
    print_unit_note(rows, strategy)
    if "--fusion-report" in flags:
        print_fusion_report(gv)
        print_chip_budget(gv)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
