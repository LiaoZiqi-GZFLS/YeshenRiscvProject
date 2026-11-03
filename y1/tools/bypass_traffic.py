#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""R6 携带项：把「旁路算子自身的激活读写」补进 DDR 流量模型（离线；只读 ddr_traffic）。

背景（spec R6）
--------------
C0 的流量模型（`ddr_traffic.py` 的 `fuse_both` 策略）**只计 Conv 的 input[0]/output[0]
激活读写** ⇒ 它明确是一条**下界**：不含旁路算子（MaxPool/Resize/Add/Sigmoid）自身在
DDR 上的激活 IO，也不含 12 个头张量的后处理。所以 12.576 MB/帧 ⇒ 21.94 fps 会打折。

本脚本在不改动 `ddr_traffic.py` **一个字节**的前提下（只 `import` 它、只读它的
`GraphView` 与 `STRATEGIES`），把「旁路算子自身的激活流量」这块**加**上去，得到更接近
真实的整帧流量。它不碰 RTL / SoC / 板。

口径（与 ddr_traffic 同源，冻结）
--------------------------------
  · 形状来源：`dt.GraphView.shape_of`（onnx.shape_inference 推断，与 ddr_traffic 完全同源）；
  · 字节口径：int8，**元素数 == 字节数**。注意 `tensor_bytes` 把**所有维相乘**，而
    `ddr_traffic.act_bytes` 只乘 C/H/W（丢掉 N）；两者**只有 N==1 时才相同**（本网 N==1，
    故口径同源）。这是**继承来**的口径，别当成"通用等价"；
  · 每个旁路算子计：Σ(输入张量字节) + Σ(输出张量字节)。
    一个消费者记一次真读（共享张量被两个旁路算子读 ⇒ 记两次，正是"真流量"的来源）；
  · 形状无法推断的张量（Resize 的 roi / scales / sizes 常量）**不计**；
  · 秩：ddr_traffic 的 `act_bytes` 只认 4 维（特征图）。旁路里 Sigmoid 的头张量是
    3 维 `[1,6400,1]`；本脚本按「元素数 == 字节数」对**任意秩**求和（同源形状 + 同口径），
    这样 Sigmoid 的读/写也被如实计入（C3.7 的 SigmoidUnit 确实要读 int8、写 int8）。
  · BASE_BYTES 用 `fuse_both`（33 单元融合，不做整图常驻）——与 C0 报告逐字一致，
    并**硬断言** == 12576000（对不上就停，不"修"这个数）。

仍是下界
--------
补进旁路后仍然**只是下界**：不含 12 个头张量的后处理（decode/NMS）读写、不含突发对齐/
填充浪费、不含权重装载（整网权重常驻片上，只装载一次）。真实流量只会更高。

用法
----
    PYTHONIOENCODING=utf-8 PYTHONPATH='../third_party/yunet/deps' <py3.9> \
        tools/bypass_traffic.py ../third_party/yunet/yunet.onnx
        tools/bypass_traffic.py ../third_party/yunet/yunet.onnx --no-bypass
        tools/bypass_traffic.py ../third_party/yunet/yunet.onnx --drop-op sigmoid   # 单算子负对照
        tools/bypass_traffic.py ../third_party/yunet/yunet.onnx --overlap-advisory # 仅诊断（默认入判）

机器可读输出
------------
**前 5 行**是稳定契约（逐字；C0/C3 对账依赖它们）：
    UNITS_BASE=<n> BASE_BYTES=<n>
    BYPASS_OPS maxpool=<n> resize=<n> add=<n> sigmoid=<n>
    BYPASS_BYTES=<n>
    TOTAL_BYTES=<n> FPS_AT_275_9MBps=<f>
    SELFTEST_BYPASS_OFF=<n>          # --no-bypass 档总额；逐字 == BASE_BYTES（正向下界证明）

契约行之后是**自检行**（不在前 5 行契约内，但**都参与 exit code**）：
    OVERLAP_PROBE bypass_inputs=<N> produced_by_fused_drop=<k>
    SELFTEST_SUM_OK=<0|1>            # 主路径求和 == 第二遍独立重算 == 冻结总额
    SELFTEST_FROZEN_OK=<0|1>         # 逐类/总额/整帧逐字等于本文件内冻结常量
    SELFTEST_DROP_OK=<0|1>           # 去掉任一类后 TOTAL 的变化量 == 该类冻结贡献（逐类）

    OVERLAP_PROBE 说明：旁路算子的输入张量共 N 条，其中由 fuse_both drop 集合内（在片上、
    不落 DDR 的 Conv 节点，即融合单元的边界）的节点产出的有 k 条。期望 k==0：旁路输入来自
    Relu/Reshape，而不是融合单元里的 Conv 输出 ⇒ 基础模型只计 Conv 的读写、旁路补的是旁路
    算子自己发起的读写，两者不重叠、不双重计数。k 由计算得出（不硬编码）。
    默认 `k != 0` ⇒ RESULT: FAIL、exit 1（诊断档须显式 `--overlap-advisory`，只打印不判）。

判据为什么"真能发火"
--------------------
自检不再是自己比自己（同一量恒等），而是拿**计算值**去比**外部冻结常量**
（`BASE_BYTES_FROZEN`/`BYPASS_BYTES_FROZEN`/`BYPASS_CLASS_FROZEN`/`TOTAL_BYTES_FROZEN`），
外加一遍**独立遍历**（`independent_class_bytes`：直接读 `gv.shape_of` 求积，不复用主路径的
`per` 字典）。任一不符 ⇒ `RESULT: FAIL`、exit 1。改坏字节模型（如让 `tensor_bytes` 返回常数）
会被这些冻结值/独立重算当场抓住。
"""
import sys
from pathlib import Path

# 非 ASCII 输出规则：Windows 控制台是 GBK，未解码字节会触发 UnicodeEncodeError。
sys.stdout.reconfigure(encoding="utf-8", errors="replace")
sys.stderr.reconfigure(encoding="utf-8", errors="replace")

# 只读导入冻结工具：不改它一个字节。
sys.path.insert(0, str(Path(__file__).resolve().parent))
import ddr_traffic as dt  # noqa: E402  (只读：GraphView 形状层 + STRATEGIES["fuse_both"])

# ---- 常量：与 ddr_traffic 同源 ----
DDR_MBPS = dt.DDR_MBPS                       # 275.9 MB/s（十进制 1e6 B/s）
BASE_STRATEGY = "fuse_both"                  # C0 报告口径：33 单元融合、不做整图常驻
BASE_BYTES_FROZEN = 12576000                 # C0 冻结值；对不上就停（不"修"这个数）

# ---- 冻结期望值（**外部**常量；判据拿计算值来比它们，绝不自己比自己） ----
# 来源：C3.1 报告 §3.1/§4 的逐类明细（本网 yunet.onnx，int8，N==1）。改坏字节模型 ⇒ 不符 ⇒ FAIL。
BYPASS_CLASS_FROZEN = {"maxpool": 4736000, "resize": 640000, "add": 1536000, "sigmoid": 33600}
BYPASS_BYTES_FROZEN = 6945600                # = Σ BYPASS_CLASS_FROZEN
TOTAL_BYTES_FROZEN = 19521600                # = BASE_BYTES_FROZEN + BYPASS_BYTES_FROZEN
# 冻结常量自身的算术闭合（防止手工誊抄错位）：
assert sum(BYPASS_CLASS_FROZEN.values()) == BYPASS_BYTES_FROZEN
assert BASE_BYTES_FROZEN + BYPASS_BYTES_FROZEN == TOTAL_BYTES_FROZEN

# 旁路算子：op_type -> 短名（spec §2 裁决"进硬件"的四类）
BYPASS_TYPES = {"MaxPool": "maxpool", "Resize": "resize", "Add": "add", "Sigmoid": "sigmoid"}
ORDER = ["maxpool", "resize", "add", "sigmoid"]   # 打印顺序（固定）


# ============================ 形状/字节访问 ============================
def tensor_bytes(gv, name):
    """张量的 int8 字节数 = 形状各维乘积（元素数）；形状取不到 ⇒ 0（不计）。

    形状与 ddr_traffic 同源（gv.shape_of）；对任意秩成立（见文件头"口径"一节）。
    注意：本函数**把 N 也乘进去**，而 `ddr_traffic.act_bytes` 丢掉 N（只乘 C/H/W）；
    两者只有在 N==1 时才相同——本网 N==1（继承口径），别当成通用等价。
    """
    s = gv.shape_of(name)
    if not s:
        return 0
    n = 1
    for d in s:
        n *= d
    return n


def bypass_per_op(gv, drop=()):
    """旁路算子按类聚合的 DDR 激活字节 + 算子计数。

    drop: 要从账里去掉的旁路类（小写短名）—— 用于 --no-bypass / --drop-op 负对照。
    返回 (per_op_bytes: dict, op_counts: dict)。
    """
    drop = set(drop)
    per = {k: 0 for k in ORDER}
    counts = {k: 0 for k in ORDER}
    for n in gv.nodes:
        k = BYPASS_TYPES.get(n.op_type)
        if k is None:
            continue
        counts[k] += 1                    # 算子计数是"图的固有事实"，不受 drop 影响
        if k in drop:
            continue
        b = 0
        for t in list(n.input) + list(n.output):
            b += tensor_bytes(gv, t)
        per[k] += b
    return per, counts


def independent_class_bytes(gv, drop=()):
    """**第二遍独立遍历**：逐类求旁路字节，但**不复用** `bypass_per_op` / `tensor_bytes`。

    直接读 `gv.shape_of` 自己求各维乘积（不经主路径的 `per` 字典，也不经 `tensor_bytes`），
    作为对主路径的对账。两条路径必须一致；若有人改坏 `tensor_bytes`（如返回常数），
    这里就会与主路径/冻结值分叉 ⇒ 判据发火。
    """
    drop = set(drop)
    tot = {k: 0 for k in ORDER}
    for n in gv.nodes:
        k = BYPASS_TYPES.get(n.op_type)
        if k is None or k in drop:
            continue
        acc = 0
        for t in list(n.input) + list(n.output):
            shp = gv.shape_of(t)
            if not shp:
                continue
            p = 1
            for d in shp:            # 与 tensor_bytes 同口径：所有维相乘（含 N；本网 N==1）
                p *= d
            acc += p
        tot[k] += acc
    return tot


# ============================ 重叠探针（真实可运行） ============================
def build_producer_map(gv):
    """扫描 ONNX 节点列表，建立 tensor -> 产出它的节点 的映射（首个产出者胜出）。

    旁路算子的输入张量有些没有产出者（Resize 的 roi/scales/sizes 是常量初始化器），
    查不到即返回 None —— 它们永远不可能命中"融合单元边界"，如实处理即可。
    """
    producer = {}
    for n in gv.nodes:
        for t in n.output:
            if t and t not in producer:
                producer[t] = n
    return producer


def public_fused_drop_out(gv):
    """「在片上、不落 DDR 的 Conv 输出」集合 —— 由**公开注册的策略**推导（不用私有 API）。

    定义：某个 Conv 的输出**写**在 `baseline` 里 >0，在 `fuse_both` 里 == 0 —— 即被融合
    drop 掉的输出，也就是"融合单元的边界"。等价于私有 `ddr_traffic._fusion_drop_sets` 的
    drop_out（本网 = 33 个 Conv 节点），但只依赖公开的 `dt.STRATEGIES`，对私有函数改名免疫。
    只读，不改冻结文件。
    """
    base_rows = list(dt.STRATEGIES["baseline"](gv))
    fused_by_idx = {r.idx: r for r in dt.STRATEGIES["fuse_both"](gv)}
    out = set()
    for r in base_rows:
        f = fused_by_idx.get(r.idx)
        if f is not None and r.bytes_out > 0 and f.bytes_out == 0:
            out.add(r.name)
    return out


def overlap_probe(gv):
    """量「旁路算子输入」与「fuse_both 留在片上、不落 DDR 的 Conv 输出（融合单元边界）」的重叠。

    fuse_both 的 drop 集合由**公开策略推导**（`public_fused_drop_out`：baseline 的写 >0 到
    fuse_both 的写 ==0），其元素就是"在片上、不落 DDR"的 Conv 节点名字（= 融合单元的边界）。

    返回 (bypass_inputs, produced_by_fused_drop, detail)：
      · bypass_inputs          = 全部旁路算子的输入张量条数（含常量输入；空名不算）；
      · produced_by_fused_drop = 其中产出者节点名落在 drop_out 的条数（**计算得到，不硬编码**）；
      · detail                 = 命中的 (op_type, op_name, tensor, producer_name) 列表。
    """
    producer = build_producer_map(gv)
    drop_out = public_fused_drop_out(gv)        # 只读 + 公开 API：融合单元的边界（节点名集合）
    n_inputs = 0
    detail = []
    for n in gv.nodes:
        if n.op_type not in BYPASS_TYPES:
            continue
        for t in n.input:
            if not t:
                continue
            n_inputs += 1
            p = producer.get(t)
            if p is not None and p.name in drop_out:
                detail.append((n.op_type, n.name, t, p.name))
    return n_inputs, len(detail), detail


def base_bytes(gv):
    """BASE_BYTES = fuse_both 的 TOTAL（逐字复现 C0 的 12,576,000）。"""
    return sum(r.traffic for r in dt.STRATEGIES[BASE_STRATEGY](gv))


def units_base(gv):
    """fuse_both 的"单元"数：3x3->1x1 对 + 1x1->3x3 对（与 fusion_buffer 的 33 一致）。"""
    fu33, _ = dt.find_fusion_pairs(gv)
    fu11, _ = dt.find_fusion_pairs_native(gv)
    return len(fu33) + len(fu11)


def fps(total_bytes):
    return DDR_MBPS * 1e6 / total_bytes


# ============================ main ============================
def parse_args(argv):
    args = []
    opts = {"no_bypass": False, "drop_op": [], "overlap_advisory": False}
    i = 1
    while i < len(argv):
        a = argv[i]
        if a == "--no-bypass":
            opts["no_bypass"] = True
        elif a == "--overlap-advisory":
            # 诊断档：OVERLAP_PROBE 只打印不判（默认=入判，ov_hit!=0 ⇒ FAIL）。
            opts["overlap_advisory"] = True
        elif a == "--drop-op":
            i += 1
            if i >= len(argv):
                raise SystemExit("--drop-op 需要一个算子类（maxpool/resize/add/sigmoid）")
            k = argv[i].strip().lower()
            if k not in ORDER:
                raise SystemExit("--drop-op 未知算子类 %r；可用：%s" % (k, ", ".join(ORDER)))
            opts["drop_op"].append(k)
        elif a.startswith("--"):
            raise SystemExit("未知参数 %r" % a)
        else:
            args.append(a)
        i += 1
    return args, opts


def main(argv):
    args, opts = parse_args(argv)
    if not args:
        print(__doc__)
        return 2
    onnx_path = args[0]

    gv = dt.GraphView(onnx_path)

    # ---- 冻结口径自证：BASE 必须逐字 == 12576000，否则停下报错（不"修"数） ----
    base = base_bytes(gv)
    if base != BASE_BYTES_FROZEN:
        print("FATAL: BASE_BYTES=%d ≠ 冻结值 %d（ddr_traffic 口径变了？停下，不修这个数）"
              % (base, BASE_BYTES_FROZEN))
        return 2
    ub = units_base(gv)

    per_full, counts = bypass_per_op(gv)          # 全量（不做任何 drop）
    bypass_full = sum(per_full.values())
    indep_full = independent_class_bytes(gv)      # 第二遍独立遍历（不经 tensor_bytes/per）

    # ---- 冻结期望值判据（真能发火）：拿计算值去比**外部冻结常量** + 独立重算 ----
    indep_ok = all(indep_full[k] == per_full[k] for k in ORDER)
    frozen_class_ok = all(per_full[k] == BYPASS_CLASS_FROZEN[k] for k in ORDER)
    frozen_bypass_ok = (bypass_full == BYPASS_BYTES_FROZEN)
    frozen_total_ok = (base + bypass_full == TOTAL_BYTES_FROZEN)
    frozen_ok = indep_ok and frozen_class_ok and frozen_bypass_ok and frozen_total_ok

    # ---- 负对照 (1)：关掉旁路 ⇒ 总额必须逐字回到**冻结** base（只算一次，YAGNI） ----
    per_off, _ = bypass_per_op(gv, drop=ORDER)
    bypass_off = sum(per_off.values())            # == 0
    selftest_bypass_off = base + bypass_off       # == base
    off_proof_ok = (bypass_off == 0) and (selftest_bypass_off == BASE_BYTES_FROZEN)

    # ---- 本档的 drop（--no-bypass 优先于 --drop-op） ----
    drop = ORDER if opts["no_bypass"] else opts["drop_op"]
    per, _ = bypass_per_op(gv, drop=drop)
    bypass = sum(per.values())
    total = base + bypass

    # ---- 稳定前 5 行（机器可读契约） ----
    print("UNITS_BASE=%d BASE_BYTES=%d" % (ub, base))
    print("BYPASS_OPS maxpool=%d resize=%d add=%d sigmoid=%d"
          % (counts["maxpool"], counts["resize"], counts["add"], counts["sigmoid"]))
    print("BYPASS_BYTES=%d" % bypass)
    print("TOTAL_BYTES=%d FPS_AT_275_9MBps=%.4f" % (total, fps(total)))
    print("SELFTEST_BYPASS_OFF=%d" % selftest_bypass_off)

    # ---- 诊断（契约行之后）：旁路输入 vs fuse_both 融合单元边界的重叠探针 ----
    ov_inputs, ov_hit, ov_detail = overlap_probe(gv)
    print("OVERLAP_PROBE bypass_inputs=%d produced_by_fused_drop=%d%s"
          % (ov_inputs, ov_hit, "  [advisory: 未入判]" if opts["overlap_advisory"] else ""))
    for (op, opname, tensor, prod) in ov_detail:
        print("  OVERLAP_HIT %s(%s) in=%s produced_by=%s（融合单元边界内 ⇒ 需复核）"
              % (op, opname, tensor, prod))

    # ---- 逐算子明细（人读） ----
    print()
    print("== 逐算子明细（int8，元素数 == 字节数；含本档 drop 后的实账） ==")
    print("  %-9s %8s %14s" % ("op_type", "n_ops", "bytes"))
    for k in ORDER:
        print("  %-9s %8d %14d%s"
              % (k, counts[k], per[k], "   [DROPPED]" if k in set(drop) else ""))
    print("  %-9s %8s %14d" % ("TOTAL", "-", bypass))

    # ---- 自检 (2)：主路径求和 == 第二遍独立重算 == 冻结总额（不是"自己比自己"） ----
    sum_ok = (sum(per_full.values()) == bypass_full) \
        and (bypass_full == sum(indep_full.values())) \
        and indep_ok \
        and (bypass_full == BYPASS_BYTES_FROZEN)
    print()
    print("SELFTEST_SUM_OK=%d" % (1 if sum_ok else 0))

    # ---- 自检 (4)：逐类/总额/整帧 逐字等于冻结期望值（+ 独立重算一致） ----
    print("== SELFTEST_FROZEN：计算值必须逐字等于文件内冻结常量（破口径即红） ==")
    for k in ORDER:
        print("  %-9s computed=%-10d frozen=%-10d indep=%-10d %s"
              % (k, per_full[k], BYPASS_CLASS_FROZEN[k], indep_full[k],
                 "OK" if (per_full[k] == BYPASS_CLASS_FROZEN[k] and indep_full[k] == per_full[k])
                 else "MISMATCH"))
    print("  %-9s computed=%-10d frozen=%-10d %s"
          % ("BYPASS", bypass_full, BYPASS_BYTES_FROZEN,
             "OK" if frozen_bypass_ok else "MISMATCH"))
    print("  %-9s computed=%-10d frozen=%-10d %s"
          % ("TOTAL", base + bypass_full, TOTAL_BYTES_FROZEN,
             "OK" if frozen_total_ok else "MISMATCH"))
    print("SELFTEST_FROZEN_OK=%d" % (1 if frozen_ok else 0))

    # ---- 自检 (3)：去掉任一类 ⇒ TOTAL 恰好变化"该类**冻结**贡献"（逐类正负对照） ----
    print("== SELFTEST_DROP：逐类去掉后 TOTAL 的变化量必须 == 该类冻结贡献 ==")
    drop_ok = True
    full_total = base + bypass_full
    for k in ORDER:
        per_k, _ = bypass_per_op(gv, drop=[k])
        t_k = base + sum(per_k.values())
        delta = full_total - t_k
        ok = (delta == per_full[k]) and (per_full[k] == BYPASS_CLASS_FROZEN[k])
        drop_ok &= ok
        print("  drop %-9s dTOTAL=%-10d contribution=%-10d frozen=%-9d %s"
              % (k, delta, per_full[k], BYPASS_CLASS_FROZEN[k], "OK" if ok else "MISMATCH"))
    # 全关 ⇒ 必须逐字等于冻结 base（per_off 上面已算过，这里复用，不再重复遍历）
    all_off = base + bypass_off
    off_ok = (all_off == base) and off_proof_ok
    drop_ok &= off_ok
    print("  drop ALL (旁路全关) TOTAL=%d BASE=%d %s" % (all_off, base, "OK" if off_ok else "MISMATCH"))
    print("SELFTEST_DROP_OK=%d" % (1 if drop_ok else 0))

    # ---- 口径声明 ----
    print()
    print("== 口径 ==")
    print("  BASE_BYTES=%d 是下界（只计 Conv 的输入/输出激活读写；见 ddr_traffic 文件头）" % base)
    print("  BYPASS_BYTES=%d 是旁路算子自身激活 IO（MaxPool/Resize/Add/Sigmoid 的读+写）" % bypass_full)
    print("  TOTAL_BYTES=%d（base + bypass）；隐含 fps @%.1f MB/s ≈ %.4f"
          % (full_total, DDR_MBPS, fps(full_total)))
    print("  仍不含：12 个头张量的后处理（decode/NMS）读写、突发对齐/填充浪费、权重装载")

    # ---- 判据汇总：任一条不符 ⇒ RESULT: FAIL、exit 1 ----
    ov_ok = True if opts["overlap_advisory"] else (ov_hit == 0)
    print()
    print("SELFTEST_OVERLAP_OK=%d%s" % (1 if ov_ok else 0,
          "   [advisory：--overlap-advisory，未入判]" if opts["overlap_advisory"] else ""))
    ok = bool(sum_ok) and bool(drop_ok) and bool(frozen_ok) and bool(ov_ok)
    print("RESULT: %s" % ("PASS" if ok else "FAIL"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
