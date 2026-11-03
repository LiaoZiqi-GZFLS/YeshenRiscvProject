#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""gen_deq_header.py —— 12 路输出反量化 (scale, zp) → `y1/tools/y1_deq.h`（交付常量）。

============================ 这个脚本做什么 ============================
板内 `y1cam` 拿到 NPU 的 12 路 **int8** 输出后，必须用**与冻结参考同一对 (s,z)**
反量化才能得到和主机后处理同一个数的 float 张量。本脚本把这对参数从**冻结路径**里取出来，
按 `yunet_post.OUT_NAMES` 的顺序写成 C 头（`DEQ_SCALE[12]` / `DEQ_ZP[12]` / `DEQ_NAME[12]`）。

**冻结路径**（与 `npu_frame_run.deq_params` / `run_same_caliber_int8` 逐字同源）：
  1. `quant_ref.Model(onnx, synth=X)` 一次 ORT float，抓全部中间张量；
  2. `Model.build_params()` → per-tensor affine `(s,z)`（零值纳入口径，见 `quant_ptq.affine_params`）；
  3. `y1_caliber.apply_sigmoid_fix(P["act"], M.nodes)` —— 6 个 Sigmoid 的输入/输出刻度钉到
     冻结 LUT 的 Q3.4 / Q0.7（S4-B / D4）；**不调它就会和板上的 SigmoidUnit 不同源**。

标定输入 `X` 用 `yunet_post.synth_noface()`（确定性渐变图）：板内相机帧在烧片时不可知，
  头里的常量必须是**离线可复现**的一份；`synth_noface` 正是 `deq_params()` 不带缓存时的缺省口径。
  （注意：affine 刻度与标定图有关；换标定图 ⇒ 换头 ⇒ 必须重跑本脚本并入库。）

用法（cwd 任意；需要 numpy/onnx/onnxruntime 的 Python）：
  python y1/tools/gen_deq_header.py            # 写 y1/tools/y1_deq.h
  python y1/tools/gen_deq_header.py --check    # 只比对，不写（CI/回归用）
  python y1/tools/gen_deq_header.py --stdout   # 打到 stdout

判据：12 路全部拿到有限 (s,z)、s>0、zp∈[-128,127]；否则退 1（不写半个头）。
成功打印 `Y1_DEQ_OK`（带 md5）。
"""
import argparse
import hashlib
import io
import os
import sys

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import numpy as np                     # noqa: E402

import yunet_post as YP                # noqa: E402  （OUT_NAMES 的唯一来源）
import npu_frame_run as NFR            # noqa: E402  （deq_params：冻结路径的宿主入口）

OUT_H = os.path.join(HERE, "y1_deq.h")
HEADER_TOP = """/* generated: 12 output dequant params (scale,zp) */
/* 由 y1/tools/gen_deq_header.py 生成 —— 请勿手改（改标定口径就重跑脚本并入库）。
 *
 * 顺序 = yunet_post.OUT_NAMES = cls_8,cls_16,cls_32,obj_8,obj_16,obj_32,
 *                              bbox_8,bbox_16,bbox_32,kps_8,kps_16,kps_32
 * 口径 = 冻结 quant_ref affine（零值纳入）+ y1_caliber.apply_sigmoid_fix（Q3.4/Q0.7）；
 *        标定输入 = yunet_post.synth_noface()（确定性，可复现）。
 * 反量化（与 quant_ptq.dequant 同式）：x = (q - zp) * scale   —— 注意是减 zp，不是加。
 */
#ifndef Y1_DEQ_H
#define Y1_DEQ_H

#define Y1_DEQ_N 12

"""


def collect(img=None):
    """→ (names, scales, zps, meta)：走冻结路径取 12 路 (s,z)。

    ★ 2026-10-26：**必须与转换器同一张标定图**（`y1_convert.py --calib-image`）。此前这里
    硬编码 `synth_noface()`，而交付的 y1/gen 是用 `grace_hopper` 标定的 ⇒ bbox/kps 的
    (s,z) 全错（bbox_32 用 0.019831/−35 而非 0.020474/−18），板端框 ×1.35、中心偏 9 px。
    """
    if img:
        hwc = YP.preprocess_image(img)            # 与 y1_convert --calib-image 同一预处理（HWC BGR 0..255）
    else:
        hwc = YP.synth_noface()                   # 兼容旧口径（合成渐变图）

    deq, meta = NFR.deq_params(hwc)               # Model → build_params → apply_sigmoid_fix
    names = list(YP.OUT_NAMES)
    scales, zps = [], []
    bad = []
    for n in names:
        s, z = deq[n]
        s, z = float(s), int(z)
        if not np.isfinite(s) or s <= 0.0 or z < -128 or z > 127:
            bad.append("%s s=%r z=%r" % (n, s, z))
        scales.append(s)
        zps.append(z)
    if bad:
        raise SystemExit("FATAL: 12 路里有非法 (s,z)：%s" % "; ".join(bad))
    return names, scales, zps, meta


def render(names, scales, zps, meta):
    L = [HEADER_TOP]
    inp = (meta.get("act") or {}).get("_input", {})
    if inp:
        L.append("/* 标定输入：scale=%.9g zp=%d（仅供溯源；板内输入是 q = x - 128，同口径） */\n"
                 % (float(inp["scale"]), int(inp["zp"])))
    L.append("static const char *DEQ_NAME[Y1_DEQ_N] = {\n")
    for n in names:
        L.append('    "%s",\n' % n)
    L.append("};\n\n")
    L.append("static const float DEQ_SCALE[Y1_DEQ_N] = {\n")
    for i, s in enumerate(scales):
        L.append("    %.9gf,%s/* %s */\n" % (s, " " * 12, names[i]))
    L.append("};\n\n")
    L.append("static const int DEQ_ZP[Y1_DEQ_N] = {\n")
    for i, z in enumerate(zps):
        L.append("    %d,%s/* %s */\n" % (z, " " * (6 - len(str(z))), names[i]))
    L.append("};\n\n#endif /* Y1_DEQ_H */\n")
    return "".join(L)


def main(argv):
    ap = argparse.ArgumentParser(description="生成 y1_deq.h（12 路输出反量化常量）")
    ap.add_argument("--out", default=OUT_H)
    ap.add_argument("--img", default=None,
                    help="标定图（必须与 y1_convert --calib-image 相同）；缺省=合成 no-face")
    ap.add_argument("--check", action="store_true", help="只比对已有文件，不写")
    ap.add_argument("--stdout", action="store_true", help="打到 stdout，不写文件")
    args = ap.parse_args(argv[1:])

    names, scales, zps, meta = collect(args.img)
    txt = render(names, scales, zps, meta)
    md5 = hashlib.md5(txt.encode("utf-8")).hexdigest()

    for n, s, z in zip(names, scales, zps):
        print("  %-8s scale=%.9g zp=%d" % (n, s, z))

    if args.stdout:
        sys.stdout.write(txt)
        print("Y1_DEQ_OK md5=%s (stdout)" % md5)
        return 0

    old = None
    if os.path.isfile(args.out):
        with io.open(args.out, encoding="utf-8") as fh:
            old = fh.read()
    if args.check:
        same = (old == txt)
        print("Y1_DEQ_%s md5=%s out=%s" % ("OK" if same else "STALE", md5, args.out))
        return 0 if same else 1

    with io.open(args.out, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(txt)
    print("wrote %s (%d B, changed=%s)" % (args.out, len(txt.encode("utf-8")), old != txt))
    print("Y1_DEQ_OK md5=%s" % md5)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
