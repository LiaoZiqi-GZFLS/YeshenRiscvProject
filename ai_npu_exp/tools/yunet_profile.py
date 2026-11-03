"""从 YuNet 的 ONNX 图算出真实算力画像（MAC 数 / 权重 / 激活内存 / 分组卷积占比）。

用法：
    PYTHONPATH=../third_party/yunet/deps \
      /d/code/PDS/NaxYeshenLinux/sim/reglogs/lxvenv/Scripts/python.exe \
      tools/yunet_profile.py ../third_party/yunet/yunet.onnx
"""
import sys, collections
import onnx
from onnx import shape_inference

sys.stdout.reconfigure(errors="replace")
path = sys.argv[1]
m = onnx.load(path)
mi = shape_inference.infer_shapes(m)
vi = {v.name: v for v in list(mi.graph.value_info) + list(mi.graph.input) + list(mi.graph.output)}


def shape_of(name):
    v = vi.get(name)
    if v is None:
        return None
    d = v.type.tensor_type.shape.dim
    return [x.dim_value if x.HasField("dim_value") else 0 for x in d]


inits = {i.name: i for i in mi.graph.initializer}


def nbytes(t):
    n = 1
    for d in t.dims:
        n *= d
    return n * (1 if t.data_type == onnx.TensorProto.INT8
                else 2 if t.data_type in (onnx.TensorProto.FLOAT16, onnx.TensorProto.INT16)
                else 4 if t.data_type in (onnx.TensorProto.FLOAT, onnx.TensorProto.INT32)
                else 1)


rows = []
tot_macs = 0
tot_weights = 0
group_hist = collections.Counter()
macs_by_group = collections.Counter()
macs_by_region = collections.Counter()

for n in mi.graph.node:
    if n.op_type != "Conv":
        continue
    a = {x.name: x for x in n.attribute}

    def gi(k, d=None):
        if k not in a:
            return d
        v = a[k]
        return list(v.ints) if v.ints else v.i

    ishp, oshp = shape_of(n.input[0]), shape_of(n.output[0])
    if not ishp or not oshp or len(ishp) < 4 or len(oshp) < 4:
        continue
    c_in, c_out = ishp[1], oshp[1]
    h_out, w_out = oshp[2], oshp[3]
    kh, kw = gi("kernel_shape", [1, 1])
    grp = gi("group", 1)
    macs = kh * kw * (c_in // grp) * c_out * h_out * w_out
    wts = kh * kw * (c_in // grp) * c_out

    region = "backbone" if "backbone" in n.name else ("neck" if "neck" in n.name else ("head" if "bbox_head" in n.name else "?"))
    rows.append((n.name, c_in, c_out, grp, kh, kw, h_out, w_out, macs, wts, region))
    tot_macs += macs
    tot_weights += wts
    group_hist[grp] += 1
    macs_by_group[("depthwise" if grp == c_in == c_out else ("grouped" if grp > 1 else "dense"))] += macs
    macs_by_region[region] += macs

print("== YuNet 640x640 算力画像 ==")
print(f"Conv 层数            : {len(rows)}")
print(f"总 MAC               : {tot_macs:,}  ({tot_macs/1e6:.1f} M-MAC, {tot_macs/1e6:.1f} M-MAC = {2*tot_macs/1e6:.1f} M-FLOP)")
print(f"总权重元素           : {tot_weights:,}  ({tot_weights/1024:.1f} K 元素, int8 ≈ {tot_weights/1024:.1f} KB)")
print(f"group 直方图         : {dict(sorted(group_hist.items()))}")
print()
print("按类型切 MAC：")
for k, v in macs_by_group.most_common():
    print(f"  {k:10s} {v:>12,}  ({100*v/tot_macs:5.1f}%)")
print("按区域切 MAC：")
for k, v in macs_by_region.most_common():
    print(f"  {k:10s} {v:>12,}  ({100*v/tot_macs:5.1f}%)")
print()

# 激活内存：最大的中间张量
best = []
for n in mi.graph.node:
    for o in n.output:
        s = shape_of(o)
        if s and len(s) == 4:
            best.append((s[1] * s[2] * s[3], s, n.op_type, n.name))
best.sort(reverse=True)
print("最大的几个中间张量（int8 字节）：")
for cnt, s, op, nm in best[:6]:
    print(f"  {str(s):26s} = {cnt:>10,} 元素 ≈ {cnt/1024/1024:5.2f} MB   {op} {nm[:36]}")
print()

print("== 吞吐换算（单个推理的 MAC 数）==")
for name, macs_per_cycle in [("1 MAC/cycle", 1), ("8x8=64 MAC/cycle", 64), ("16x16=256 MAC/cycle", 256), ("32x32=1024 MAC/cycle", 1024)]:
    for f in (100e6, 200e6):
        t = tot_macs / (macs_per_cycle * f)
        print(f"  {name:22s} @{f/1e6:3.0f} MHz -> {t*1000:8.2f} ms/帧  ({1/t:7.2f} fps)")
print()
print("== 权重与激活的片上可行性 ==")
print(f"  权重 {tot_weights/1024:.1f} KB → 按 36 Kbit DRM 计约需 {tot_weights*8/36/1024:.1f} 个 DRM（本器件 415 个）")
print(f"  最大中间张量 {best[0][0]/1024/1024:.2f} MB → 远超片上，必须落到 DDR 流式读写")
print()

# 激活流量：逐层 Conv 的输入+输出张量字节之和（int8）。这是"层间特征落 DDR"式设计的真实瓶颈。
# 只统计 Conv 的输入/输出（非 Conv 节点会重复计同一张量，故不计）。
tot_traffic = 0
for n in mi.graph.node:
    if n.op_type != "Conv":
        continue
    for nm in (n.input[0], n.output[0]):
        s = shape_of(nm)
        if s and len(s) == 4:
            tot_traffic += s[1] * s[2] * s[3]
print("== 层间激活流量（决定 DDR 带宽下限，比 MAC 数更可能是真瓶颈）==")
print(f"  Conv 输入+输出合计（int8）: {tot_traffic:,} B ≈ {tot_traffic/1024/1024:.1f} MB/帧")
for bw in (200e6, 500e6, 1e9, 1.6e9, 2.5e9):
    print(f"    有效带宽 {bw/1e6:6.0f} MB/s -> {tot_traffic/bw*1000:8.1f} ms/帧  ({bw/tot_traffic:6.2f} fps)")
print()
print("== 面积粗算（MAC 阵列 + 权重存储）==")
print(f"  权重常驻片上只需 ≈ {tot_weights/1024:.1f} KB（int8），即 ~11 个 DRM —— 可以整网常驻，无需每层重载")
print("  ⇒ 面积几乎完全由「MAC 阵列规模」这一个旋钮决定；阵列小则面积小，代价是 fps")
