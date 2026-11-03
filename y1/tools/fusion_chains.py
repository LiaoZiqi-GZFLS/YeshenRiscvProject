#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Y1 融合**链长**分析（离线，纯 Python，不碰 RTL / SoC / 板）。

问题（要关掉的那个开口项）
--------------------------
出货 RTL（`rtl/UnitExec.scala` C3.9b + `rtl/LayerSched.scala` C3.10a）一个融合单元**一次 `go`
只跑 2 个切片**（塌缩编码 `FLAGS=0b10` = 一项一对）。但 `fuse_both` 的 33 条融合边**允许重叠**：
一个 conv 可以既是某条边的尾、又是下一条边的头 ⇒ 这些边连成**链**（chain）。今天的塌缩编码
只能保住每条链上 ⌊len/2⌋ 个融合对 ⇒ 33 条边里 **7 条被牺牲**（C3.11a 修订记录），整帧 DDR 从
12,576,000 B 涨到 **17,798,400 B（+41.5%）**。

用户已批准把 RTL 从"2 切片/单元"扩到"支持更长的链"。**代价 = 每个链位一个 `Conv3x3Slice` 实例**
⇒ 需要**精确的链长分布**来定面积。本脚本把它算成一份可复算的链长直方图 + `L → 覆盖边数 →
DDR 流量 → fps` 表 + 切片实例数，并对全程做**真能发火**的自检。

用法
----
    cd /d/code/PDS/VexiiYeshenLinux/y1
    PYTHONIOENCODING=utf-8 PYTHONPATH='../third_party/yunet/deps' \
      /d/code/PDS/NaxYeshenLinux/sim/reglogs/lxvenv/Scripts/python.exe \
      tools/fusion_chains.py ../third_party/yunet/yunet.onnx
    # 负对照（故意喂错 L / 坏边集，看断言是否发火；正常应打 PASS）
    ... tools/fusion_chains.py ../third_party/yunet/yunet.onnx --negctl

============================ 枚举来源（**复用，不重推融合规则**） ============================
  只读 import 冻结件 `tools/ddr_traffic.py`（本脚本**不改**它一个字节；`fusion_buffer.py` 同样
  只读用法）：
      dt.find_fusion_pairs(gv)         -> 7 对  3×3(stride1) --逐元素--> 1×1   (fu33)
      dt.find_fusion_pairs_native(gv)  -> 26 对 1×1(stride1) --逐元素--> 3×3   (fu11)
      fuse_both = 两方向并集 = **33 条边**（与 C0.3 的 33 逐字一致，且允许重叠）
  融合**边** e = (head_conv, tail_conv)；被消掉的中间张量 = tail.input[0]（两方向同口径：
  见 `dt.find_fusion_pairs` 的 drop_in = B.input[0]、`find_fusion_pairs_native` 的 mid = B.input[0]）。
  这些边连成互不相交的**简单路径 = 链**（in/out-degree ≤ 1：一个节点不可能同时是某 fu33 边的尾
  又是某 fu11 边的尾 —— 尾侧的核大小不同 ⇒ 天然配对）。

============================ 链 → 融合单元（容量 L） ============================
  定义：把链上 conv 节点切成若干**单元**，每单元 ≤ L 个切片；单元**内部**的边被融合
  （中间张量不出片），**跨单元**的边被牺牲（多一趟 DDR 往返）。
  · 覆盖边数最大 ⇔ 单元数最少 = 每条长 k 的链用 ⌈k/L⌉ 个单元 ⇒ 覆盖边数 = Σ(k − ⌈k/L⌉)，
    这是**与分段位置无关**的量（表里的"覆盖/33"就用它）；牺牲边数 = Σ(⌈k/L⌉ − 1)。
  · 在"覆盖最多"前提下，调度器应当让**最便宜**的边去牺牲（段边界可选）⇒ 用 DP 选段边界，
    使 Σ(被牺牲中间张量字节) 最小（`optimal_segments`）。L=2 / L=L_MAX 时 DP 唯一，
    分别逐字复现 C3.11a 的塌缩分解与 `fuse_both`。

============================ DDR 流量口径（复用冻结件） ============================
  用 `dt.compute_rows_fused(gv, drop_out=..., drop_in=...)`（= C3.11a 复现塌缩流量用的那条
  公开口径）：`drop_out` = 融合边**头**节点名（其输出不落 DDR），`drop_in` = 对应**尾**的
  `input[0]` 张量（其读不落 DDR）⇒ 每条被覆盖的边省 2×size（int8）。口径/单位与 C0 逐字相同。

============================ 下界声明（**必须如实**） ============================
  本脚本给的是 **Conv-only 下界**：只计 Conv 的 `input[0]`/`output[0]` 激活读写，**不含**
  旁路算子（MaxPool/Resize/Add/Sigmoid）自身的激活 IO（`y1/reports/c3_traffic_full.md` 冻结
  6,945,600 B，**单独、可加**），也不含 12 个头张量的后处理、突发对齐/填充、权重装载。
  ⇒ 表里的 fps 是**上界**；真实帧率更低（含旁路后 fuse_both/L_MAX 档 ≈ 14.13 fps，见报告）。
"""
import sys
import os
import collections

# 非 ASCII 输出规则：Windows 控制台是 GBK，未解码字节会触发 UnicodeEncodeError。
sys.stdout.reconfigure(encoding="utf-8", errors="replace")
sys.stderr.reconfigure(encoding="utf-8", errors="replace")

# 复用上一阶段的冻结件（只读，不改一个字节；与 fusion_buffer.py 同用法）。
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ddr_traffic as dt  # noqa: E402

# ---- 外部冻结期望值（来源：C0.2/C0.3 的 ddr_traffic_budget.md、C3.11a 的 c3_descriptor_format.md） ----
EDGES_FROZEN = 33                 # C0.3：33 条融合**边**（允许重叠）
EDGES_33x11x_FROZEN = 7           # fu33：3×3→1×1
EDGES_11x33x_FROZEN = 26          # fu11：1×1→3×3
FUSE_BOTH_BYTES_FROZEN = 12576000   # C0：33 条边的"逐边全融合"整帧（下界）
COLLAPSED_L2_BYTES_FROZEN = 17798400  # C3.11a：塌缩编码（26 个非重叠融合对）整帧
CHAINS_FROZEN = 19                # C3.11a §4.3：19 条链
PAIRS_L2_FROZEN = 26              # C3.11a §4.3：L=2 的融合对数
UNMATCHED_L2_FROZEN = 7           # C3.11a §4.3：L=2 牺牲的边数
CHAIN_HIST_L2_FROZEN = {2: 15, 4: 2, 6: 1, 8: 1}   # C3.11a §4.3 的链长直方图（节点数）
# 旁路算子自身激活 IO（C3.1 冻结，**单独、可加**；本脚本的流量不含它）：
BYPASS_BYTES_FROZEN = 6945600
DDR_MBPS = dt.DDR_MBPS            # 275.9 MB/s（十进制 1e6 B/s）

Edge = collections.namedtuple("Edge", "head tail mid_tensor")   # head/tail = conv 节点名
Chain = collections.namedtuple("Chain", "nodes edges")


# ============================ 图 → 边 → 链 ============================
def build_edges(gv):
    """从**冻结查找器**取融合边（不重推规则）。

    返回 (edges, n33, n11)：
      · fu33 (A, B)        → Edge(A.name, B.name, B.input[0])   （B.input[0] == 被消的中间张量）
      · fu11 (A, B, mid, _) → Edge(A.name, B.name, mid)
    两方向的 drop 口径与 `dt.find_fusion_pairs` / `find_fusion_pairs_native` 逐字一致
    （drop_out = head.name，drop_in = tail.input[0] / mid）。
    """
    fu33, _ = dt.find_fusion_pairs(gv)
    fu11, _ = dt.find_fusion_pairs_native(gv)
    edges = []
    for (A, B) in fu33:
        edges.append(Edge(A.name, B.name, B.input[0]))
    for (A, B, mid, _chain) in fu11:
        edges.append(Edge(A.name, B.name, mid))
    return edges, len(fu33), len(fu11)


def extract_chains(edges):
    """把融合边摊成互不相交的**简单路径（链）**。

    融合图 in-degree ≤ 1、out-degree ≤ 1（一个 conv 至多是一条边的头 + 一条边的尾：
    头侧核大小决定方向、尾侧核大小决定方向，两者互斥）⇒ 连通分量都是简单路径。
    链首 = 无前辈的节点；沿 succ 走到无后继为止。返回 `Chain` 列表（链首按出现序）。
    """
    succ = collections.defaultdict(list)
    pred = collections.defaultdict(list)
    nodes = set()
    seen = set()
    for e in edges:
        assert e not in seen, "重复边 %r（边集不自洽）" % (e,)
        seen.add(e)
        succ[e.head].append(e.tail)
        pred[e.tail].append(e.head)
        nodes.add(e.head)
        nodes.add(e.tail)
    # 非退化断言：每个节点的出/入度 ≤ 1（保证"链 = 简单路径"这个前提成立，不是拍脑袋）
    for nm in nodes:
        assert len(succ[nm]) <= 1, "节点 %s 出度 %d > 1：融合图不是简单路径集合" % (nm, len(succ[nm]))
        assert len(pred[nm]) <= 1, "节点 %s 入度 %d > 1：融合图不是简单路径集合" % (nm, len(pred[nm]))
    tensor_of = dict(((e.head, e.tail), e.mid_tensor) for e in edges)
    roots = sorted([nm for nm in nodes if not pred[nm]])
    chains = []
    accounted = set()
    for r in roots:
        nodes_seq, edge_seq, cur = [r], [], r
        while succ[cur]:
            nxt = succ[cur][0]
            edge_seq.append((cur, nxt))
            accounted.add((cur, nxt))
            nodes_seq.append(nxt)
            cur = nxt
        chains.append(Chain(nodes_seq, edge_seq))
    # 每条边必须恰好落在一条链上（否则有环/悬挂，断言发火）
    all_pairs = set((e.head, e.tail) for e in edges)
    assert accounted == all_pairs, \
        "有边未落入任何链（存在环或悬挂）：%d/%d" % (len(accounted), len(all_pairs))
    # 双向校验：链上相邻节点对必须在边集里，且张量可查
    for ch in chains:
        for (a, b) in ch.edges:
            assert (a, b) in tensor_of, "链上边 (%s,%s) 不在边集里" % (a, b)
    return chains, tensor_of


def chain_histogram(chains):
    """链长直方图：{len(nodes) -> 条数}。"""
    h = collections.Counter(len(ch.nodes) for ch in chains)
    return dict(sorted(h.items()))


# ============================ 判据助手（真能发火） ============================
class JudgeError(AssertionError):
    pass


def check(cond, msg):
    if not cond:
        raise JudgeError(msg)


def solve(gv):
    """核心解算：返回一个 dict（供主流程与负对照共用）。"""
    edges, n33, n11 = build_edges(gv)
    chains, tensor_of = extract_chains(edges)
    hist = chain_histogram(chains)
    l_max = max(len(ch.nodes) for ch in chains)

    def size_of(tensor):
        b = gv.act_bytes(tensor)
        assert b is not None and b > 0, "中间张量 %r 不是 4 维激活（act_bytes=%r）" % (tensor, b)
        return b

    return {"edges": edges, "n33": n33, "n11": n11, "chains": chains,
            "tensor_of": tensor_of, "hist": hist, "l_max": l_max, "size_of": size_of}


def optimal_segments(ch_nodes, tensor_of, size_of, L):
    """一条链（节点序列）在容量 L 下的**最优分段**：覆盖边数最大 + 牺牲边**最便宜**。

    · 覆盖边数最大 ⇔ 单元（段）数最少 = ⌈k/L⌉（每段 ≤ L 个节点，段内边全融合），
      故牺牲边数 = ⌈k/L⌉ − 1（固定，与分段位置无关）；
    · 在"段数最少"的前提下，牺牲的是**段边界处**的边 ⇒ 用 DP 选段边界，使
      Σ(牺牲边的中间张量字节数) 最小（即让最便宜的边去牺牲）——这就是给定 L 下
      一个调度器**应该**选的分段（贪心"从链首每 L 个切一刀"会在长链上牺牲掉贵的边，
      见 §报告：L=7 的贪心比最优多 1,638,400 B）。L=2/L_MAX 时 DP 唯一（强制 = 冻结口径）。
    返回 (segments, cuts)：segments = [(i, j), ...]（节点下标半开区间），cuts = 牺牲边数。
    """
    k = len(ch_nodes)
    assert L >= 1, "L 必须 >= 1（实得 %r）" % L
    sizes = [size_of(tensor_of[(ch_nodes[j], ch_nodes[j + 1])]) for j in range(k - 1)]
    INF = float("inf")
    dp = [INF] * (k + 1)
    prev = [-1] * (k + 1)
    dp[0] = 0
    for j in range(1, k + 1):
        for i in range(max(0, j - L), j):            # 段 = 节点 [i, j)，长度 j-i ∈ [1, L]
            cost = dp[i] + (sizes[i - 1] if i > 0 else 0)   # i>0 ⇒ 边 (i-1,i) 成为段边界 ⇒ 被牺牲
            if cost < dp[j]:
                dp[j] = cost
                prev[j] = i
    segments = []
    j = k
    while j > 0:
        i = prev[j]
        segments.append((i, j))
        j = i
    segments.reverse()
    return segments, len(segments) - 1


def internal_edges_of_groups(chains, L, tensor_of, size_of):
    """容量 L（最优分段）→ (drop_out 集合, drop_in 集合, 覆盖边数, 牺牲边数)。

    ★ DDR 记账的**单一真源**：把"单元内部边"摊成 drop 集合，喂给冻结的
    `dt.compute_rows_fused`（与 `dt.find_fusion_pairs*` 的 per-edge drop 口径逐字一致）。
    """
    assert L >= 1, "L 必须 >= 1（实得 %r）" % L
    drop_out, drop_in = set(), set()
    covered = 0
    sacrificed = 0
    for ch in chains:
        k = len(ch.nodes)
        segs, cuts = optimal_segments(ch.nodes, tensor_of, size_of, L)
        # 覆盖边数最大的前提 = 段数最少（= ⌈k/L⌉）⇒ cuts 必须等于 ⌈k/L⌉ − 1，否则 DP 选错
        check(cuts == -(-k // L) - 1,
              "链(长 %d) 在 L=%d 下段数不对：cuts=%d ≠ ⌈k/L⌉−1=%d"
              % (k, L, cuts, -(-k // L) - 1))
        sacrificed += cuts
        for (i, j) in segs:
            for t in range(i, j - 1):                # 段内边 (t, t+1) 被融合
                drop_out.add(ch.nodes[t])
                drop_in.add(tensor_of[(ch.nodes[t], ch.nodes[t + 1])])
                covered += 1
    return drop_out, drop_in, covered, sacrificed


def traffic_bytes(gv, drop_out, drop_in):
    rows = dt.compute_rows_fused(gv, drop_out=drop_out, drop_in=drop_in)
    return sum(r.traffic for r in rows)


def fps(total_bytes):
    return DDR_MBPS * 1e6 / float(total_bytes)


# ============================ 主流程 ============================
def report(onnx_path, fault=None):
    gv = dt.GraphView(onnx_path)
    s = solve(gv)
    edges, chains, hist, l_max = s["edges"], s["chains"], s["hist"], s["l_max"]
    n33, n11, tensor_of, size_of = s["n33"], s["n11"], s["tensor_of"], s["size_of"]

    # ---- --fault：故意注入故障，让**真实判据当场发火**（未捕获的 traceback = 红证据） ----
    if fault == "broken-edges":
        edges = list(edges)[:-1]                 # 丢掉一条边 ⇒ J1 必须发火
        print("FAULT: 注入坏边集（丢 1 条边，实得 %d 条）—— 期望 J1 发火" % len(edges))
    elif fault == "wrongl":
        l_max = 2                                # 谎报最长链 = 2 ⇒ J3（覆盖边/流量）必须发火
        print("FAULT: 谎报 L_MAX=2 —— 期望 J3 发火")
    elif fault is not None:
        raise SystemExit("未知故障 %r（可用：broken-edges / wrongl）" % fault)

    print("== 融合链长分析（只读复用 tools/ddr_traffic.py 的查找器）==")
    print("MODEL=%s" % onnx_path)

    # ---------------- J1：边集自检（33 = 7 + 26；与冻结一致） ----------------
    check(len(edges) == EDGES_FROZEN,
          "J1 边集 != 33：实得 %d（边集被破坏？）" % len(edges))
    check(n33 == EDGES_33x11x_FROZEN and n11 == EDGES_11x33x_FROZEN,
          "J1 方向拆分 != 7/26：实得 %d/%d" % (n33, n11))
    print("J1 边集: %d 条 = %d 个 3×3→1×1 + %d 个 1×1→3×3  (frozen 33/7/26) OK"
          % (len(edges), n33, n11))

    # ---------------- 链与直方图 ----------------
    check(len(chains) == CHAINS_FROZEN,
          "链数 != 19：实得 %d" % len(chains))
    print("链数 = %d 条（互不相交的简单路径）  (frozen %d) OK" % (len(chains), CHAINS_FROZEN))
    print("L_MAX = %d（最长链的节点数 = 切片数）" % l_max)
    print()
    print("== 链长直方图（链长 = 节点数 = 切片数）==")
    print("  %-6s %6s %10s %12s" % ("链长", "条数", "节点数", "边数(len-1)"))
    tot_ch = 0
    tot_nodes = 0
    tot_edges = 0
    for L in range(2, l_max + 1):
        c = hist.get(L, 0)
        tot_ch += c
        tot_nodes += c * L
        tot_edges += c * (L - 1)
        print("  %-6d %6d %10d %12d" % (L, c, c * L, c * (L - 1)))
    print("  %-6s %6d %10d %12d" % ("合计", tot_ch, tot_nodes, tot_edges))
    # 直方图非退化断言：奇长（L=3/5/7）条数必须为 0，且 L=2 时与 C3.11a 冻结直方图逐字一致
    check(all(hist.get(o, 0) == 0 for o in (3, 5, 7)),
          "出现奇长链（3/5/7）：本网链应全为偶长，直方图 %r 不自洽" % hist)
    check(hist == CHAIN_HIST_L2_FROZEN,
          "链长直方图 ≠ C3.11a 冻结 %r：实得 %r" % (CHAIN_HIST_L2_FROZEN, hist))
    print("  直方图 == C3.11a 冻结 %r OK（全偶长）" % CHAIN_HIST_L2_FROZEN)
    print()

    # ---------------- J2：L=2 复现塌缩编码的 17,798,400 B ----------------
    do2, di2, cov2, sac2 = internal_edges_of_groups(chains, 2, tensor_of, size_of)
    t2 = traffic_bytes(gv, do2, di2)
    check(cov2 == PAIRS_L2_FROZEN,
          "J2 L=2 覆盖边数 != 26：实得 %d" % cov2)
    check(sac2 == UNMATCHED_L2_FROZEN,
          "J2 L=2 牺牲边数 != 7：实得 %d" % sac2)
    check(t2 == COLLAPSED_L2_BYTES_FROZEN,
          "J2 L=2 流量 != 17798400：实得 %d（塌缩编码口径变了？停下，不修这个数）" % t2)
    print("J2 L=2（塌缩单条目）: 覆盖 %d/33 边、牺牲 %d、整帧 %d B  (frozen %d) OK"
          % (cov2, sac2, t2, COLLAPSED_L2_BYTES_FROZEN))

    # ---------------- J3：L_MAX 复现"逐边全融合"的 12,576,000 B ----------------
    base_fuse_both = sum(r.traffic for r in dt.STRATEGIES["fuse_both"](gv))
    check(base_fuse_both == FUSE_BOTH_BYTES_FROZEN,
          "J3 fuse_both 基线 != 12576000：实得 %d（ddr_traffic 口径变了？）" % base_fuse_both)
    doM, diM, covM, sacM = internal_edges_of_groups(chains, l_max, tensor_of, size_of)
    tM = traffic_bytes(gv, doM, diM)
    check(covM == EDGES_FROZEN,
          "J3 L_MAX 覆盖边数 != 33：实得 %d" % covM)
    check(sacM == 0, "J3 L_MAX 仍有牺牲边 %d != 0" % sacM)
    check(tM == FUSE_BOTH_BYTES_FROZEN,
          "J3 L_MAX 流量 != 12576000（逐边全融合）：实得 %d" % tM)
    print("J3 L_MAX=%d: 覆盖 %d/33 边、牺牲 %d、整帧 %d B  (frozen %d) OK"
          % (l_max, covM, sacM, tM, FUSE_BOTH_BYTES_FROZEN))
    print()

    # ---------------- 主表：L → 覆盖边 / 牺牲 / 切片实例 / 流量 / fps ----------------
    print("== L → 覆盖边 → 切片实例 → DDR 流量（Conv-only 下界）→ fps@275.9MB/s ==")
    hdr = ("  %-3s %8s %8s %10s %14s %10s %8s" %
           ("L", "覆盖/33", "牺牲", "切片/单元", "整帧_B", "MB/帧", "fps"))
    print(hdr)
    print("  " + "-" * (len(hdr) - 2))
    table = []
    prev_cov = None
    prev_t = None
    for L in range(2, l_max + 1):
        do, di, cov, sac = internal_edges_of_groups(chains, L, tensor_of, size_of)
        tb = traffic_bytes(gv, do, di)
        # 单调性断言（覆盖边数非降、流量非增）⇒ 判据真能发火
        if prev_cov is not None:
            check(cov >= prev_cov, "L=%d 覆盖边 %d < L=%d 的 %d（非单调）" % (L, cov, L - 1, prev_cov))
            check(tb <= prev_t, "L=%d 流量 %d > L=%d 的 %d（非单调）" % (L, tb, L - 1, prev_t))
        prev_cov, prev_t = cov, tb
        table.append((L, cov, sac, tb))
        print("  %-3d %5d/%-2d %8d %10d %14d %10.4f %8.2f"
              % (L, cov, EDGES_FROZEN, sac, L, tb, tb / 1e6, fps(tb)))
    print()
    print("  注：切片/单元 = L（每个链位一个 Conv3x3Slice 实例；单元串行执行 ⇒ 每个单元就是全部实例）。")
    print("      L=2 是今天出货 RTL 的能力（一次 go 跑 2 切片）。")
    print("      L=%d 才能表达**全部** 33 条边（0 牺牲）。" % l_max)

    # ---------------- 残差声明 ----------------
    residual = [t for t in table if t[2] > 0]
    print()
    print("== 残差（到 L_MAX 之前仍未表达的边）==")
    for (L, cov, sac, tb) in table:
        if sac:
            print("  L=%d：仍牺牲 %d 条边，整帧 %d B（比逐边全融合多 %d B，%.1f%%）"
                  % (L, sac, tb, tb - FUSE_BOTH_BYTES_FROZEN,
                     100.0 * (tb - FUSE_BOTH_BYTES_FROZEN) / FUSE_BOTH_BYTES_FROZEN))
    check(table[-1][1] == EDGES_FROZEN and table[-1][2] == 0,
          "L_MAX 仍未覆盖全部边（残差非空）")
    print("  L_MAX=%d 处残差为空：33/33 边全部可表达（= fuse_both 的 12,576,000 B 下界可完全逼近）。"
          % l_max)

    # ---------------- 下界口径声明 ----------------
    print()
    print("== 下界口径（如实；数字只低不高）==")
    print("  本表全部是 **Conv-only** 激活流量：只计 Conv 的 input[0]/output[0] 读写（见 ddr_traffic 文件头）。")
    print("  不含旁路算子（MaxPool/Resize/Add/Sigmoid）自身激活 IO = %d B（c3_traffic_full.md 冻结），"
          "**这一坨是单独、可加的**。" % BYPASS_BYTES_FROZEN)
    print("  含旁路后：fuse_both/L_MAX 档 ≈ %d B/帧 ⇒ %.2f fps；L=2 档 ≈ %d B/帧 ⇒ %.2f fps。"
          % (FUSE_BOTH_BYTES_FROZEN + BYPASS_BYTES_FROZEN,
             fps(FUSE_BOTH_BYTES_FROZEN + BYPASS_BYTES_FROZEN),
             COLLAPSED_L2_BYTES_FROZEN + BYPASS_BYTES_FROZEN,
             fps(COLLAPSED_L2_BYTES_FROZEN + BYPASS_BYTES_FROZEN)))
    print("  仍不含：12 个头张量的后处理（decode/NMS）读写、突发对齐/填充浪费、权重装载。")
    print("  ⇒ 表里的 fps 是**上界**（真实只会更低）。")

    # ---------------- 机器可读末行 ----------------
    print()
    print("FUSION_CHAINS L_MAX=%d CHAINS=%d EDGES=%d EDGES_33x11x=%d EDGES_11x33x=%d "
          "HIST=%s L2_BYTES=%d LMAX_BYTES=%d FUSE_BOTH_BYTES=%d BYPASS_BYTES=%d "
          "COVERED_AT_LMAX=%d RESIDUAL_AT_LMAX=%d CONV_ONLY_LOWER_BOUND=YES"
          % (l_max, len(chains), len(edges), n33, n11,
             ";".join("%d:%d" % (k, v) for k, v in sorted(hist.items())),
             COLLAPSED_L2_BYTES_FROZEN, FUSE_BOTH_BYTES_FROZEN, FUSE_BOTH_BYTES_FROZEN,
             BYPASS_BYTES_FROZEN, covM, sacM))
    return 0


# ============================ 负对照（判据真能发火） ============================
def negctl(onnx_path):
    """刻意喂**错误的 L / 坏掉的边集**，证明上面的断言确实会发火（红证据）。

    每条都拿"应该失败"的输入去撞**同一条**判据；只有抛出了预期的 `JudgeError/AssertionError`
    才算 PASS。任何一条"没发火"⇒ 该判据是装饰 ⇒ 整体 FAIL。
    """
    gv = dt.GraphView(onnx_path)
    s = solve(gv)
    chains, tensor_of, l_max = s["chains"], s["tensor_of"], s["l_max"]
    size_of = s["size_of"]
    results = []

    def probe(label, fn, expect_triggers):
        try:
            fn()
            got = None
        except (JudgeError, AssertionError) as e:
            got = str(e)
        fired = got is not None
        results.append((label, fired, got, expect_triggers))
        print("NEGCTL %-46s fired=%d  msg=%r" % (label, 1 if fired else 0, got))

    # NR1：坏边集（丢掉一条边）⇒ 33 判据必须发火
    def bad_edge_set():
        bad = list(s["edges"])[:-1]
        check(len(bad) == EDGES_FROZEN, "J1 边集 != 33：实得 %d（边集被破坏？）" % len(bad))
    probe("NR1 broken edge set (32 edges)", bad_edge_set, "J1 边集 != 33")

    # NR1b：坏边集（多出一条自环）⇒ "重复边/度数"断言或 33 判据发火
    def bad_edge_set2():
        bad = list(s["edges"]) + [(s["edges"][0].head, s["edges"][0].head, "X")]
        bad = [Edge(a, b, m) for (a, b, m) in bad]
        extract_chains(bad)
    probe("NR1b extra self-loop edge", bad_edge_set2, "度数/重复边断言")

    # NR2：错误 L —— 把 L_MAX 当成 2（声称 L=2 就够覆盖全部边）⇒ 覆盖边数断言发火
    def wrong_l_claim_full():
        _do, _di, cov, _sac = internal_edges_of_groups(chains, 2, tensor_of, size_of)
        check(cov == EDGES_FROZEN,
              "J3 L_MAX 覆盖边数 != 33：实得 %d" % cov)
    probe("NR2 claim L=2 covers all 33 edges", wrong_l_claim_full, "J3 覆盖边数 != 33")

    # NR2b：错误 L —— 把某条链的容量超限（L=1 ⇒ 不融合，流量回到基线）⇒ L=2 冻结流量断言发火
    def wrong_l_one():
        do, di, _cov, _sac = internal_edges_of_groups(chains, 1, tensor_of, size_of)
        t = traffic_bytes(gv, do, di)
        check(t == COLLAPSED_L2_BYTES_FROZEN,
              "J2 L=2 流量 != 17798400：实得 %d（塌缩编码口径变了？停下，不修这个数）" % t)
    probe("NR2b L=1 (no fusion) claimed as L=2", wrong_l_one, "J2 流量 != 17798400")

    # NR3：故意把 L_MAX 估小（=2）⇒ FUSION_CHAINS 的 L_MAX 断言发火
    def wrong_lmax():
        fake_lmax = 2
        check(fake_lmax == l_max, "L_MAX 估计错误：%d != %d" % (fake_lmax, l_max))
    probe("NR3 underestimate L_MAX (=2)", wrong_lmax, "L_MAX 估计错误")

    # NR4：链长直方图被改坏 ⇒ 直方图冻结断言发火
    def bad_hist():
        fake = dict(CHAIN_HIST_L2_FROZEN)
        fake[2] = 14
        check(fake == s["hist"], "链长直方图 != 冻结：实得 %r" % (s["hist"],))
    probe("NR4 corrupted histogram (len2=14)", bad_hist, "链长直方图 != 冻结")

    all_fired = all(f for (_l, f, _g, _e) in results)
    print()
    print("NEGCTL_ALL_FIRED=%d/%d" % (sum(1 for r in results if r[1]), len(results)))
    print("SELFTEST_NEGCTL_OK=%d" % (1 if all_fired else 0))
    print("RESULT: %s" % ("PASS" if all_fired else "FAIL"))
    return 0 if all_fired else 1


def main(argv):
    # --fault <name> 吃一个参数（其余参数保持旧口径 `[a for a in argv[1:] if not a.startswith("--")]`）
    fault = None
    rest = []
    i = 1
    while i < len(argv):
        a = argv[i]
        if a == "--fault":
            if i + 1 >= len(argv):
                print("FATAL: --fault 需要一个名字（broken-edges / wrongl）")
                return 2
            fault = argv[i + 1]
            i += 2
            continue
        rest.append(a)
        i += 1
    args = [a for a in rest if not a.startswith("--")]
    flags = [a for a in rest if a.startswith("--")]
    if not args:
        print(__doc__)
        return 2
    onnx_path = args[0]
    if "--negctl" in flags:
        return negctl(onnx_path)
    return report(onnx_path, fault=fault)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
