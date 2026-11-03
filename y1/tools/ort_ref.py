#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""ort_ref.py -- **float ORT 基线**（C4b-B5 Step 3 的"float 参考"半）。

============================ 做什么 ============================
同一张输入（真脸图 / 确定性"无人脸"图）：
  1) 预处理成 `blobFromImage(1.0, (640,640), swapRB=false)` 口径的 **(1,3,640,640) BGR-raw float32**；
  2) 跑 **真 onnxruntime**（`y1/.pydeps` 的 1.19.2，不是 numpy 假前向）⇒ 12 路 float 输出；
  3) 走 **`yunet_post` 的官方后处理**（decode + IoU-NMS）⇒ 框/关键点/置信度；
  4) 落盘 JSON（G7 的 B 侧基线）+ 可选落 12 路张量 .npz（供比较器做"真数据对"）。

============================ 判据（离线可证的部分）============================
  · ORT 会话真起得来、12 路输出形状/名字与 `yunet_post.OUT_NAMES` 一致；
  · **正方向**：真脸图（`third_party/yolov5_v3.0/inference/images/zidane.jpg` 或
    `.../grace_hopper.jpg`）⇒ 检出数 ≥ 1（score 由 `--score-thr` 控，默认用官方 0.9）；
  · **反方向**：确定性"无人脸"图 ⇒ 检出数 == 0。
这两条方向一起给出"后处理不是退化的（不是永远 0、也不是永远有）"的**真数据**证据。

退出码：0 = 出基线且方向判据过；1 = 判据红；3 = 前置缺失（缺 onnxruntime / 模型 / 图）。
"""
import argparse
import hashlib
import json
import os
import sys

import numpy as np

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

import yunet_post as YP   # noqa: E402  （后处理口径只此一份）

_H1 = os.path.abspath(os.path.join(_HERE, "..", ".."))
DEFAULT_ONNX = os.path.join(_H1, "third_party", "yunet", "yunet.onnx")
# 仓内**真脸图**（只读；两张都是公开样例图，不是我们造的）：
#   ① `grace_hopper.jpg`：matplotlib `mpl-data/sample_data` 里的经典**真照片**（640×640 plain resize
#      下 max score ≈ 0.94 ⇒ 官方 0.9 阈值下能检出）；
#   ② `zidane.jpg`：YOLOv5 仓的经典样例（两个人脸；plain resize 下 max score ≈ 0.88 —— 见 §注：
#      **低于官方 0.9 默认阈值** ⇒ 用默认阈值时 0 检出，这是阈值敏感性的诚实证据，不是 bug）。
FACE_IMGS = [
    os.path.join(_H1, "ai_npu_exp", "deps_export", "matplotlib", "mpl-data",
                 "sample_data", "grace_hopper.jpg"),
    os.path.join(_H1, "third_party", "yolov5_v3.0", "inference", "images", "zidane.jpg"),
]


def make_session(onnx_path):
    import onnxruntime as ort
    so = ort.SessionOptions()
    so.log_severity_level = 3
    return ort.InferenceSession(onnx_path, so, providers=["CPUExecutionProvider"])


def run_float(sess, blob):
    """(1,3,640,640) → {输出名: ndarray}。"""
    names = [o.name for o in sess.get_outputs()]
    out = sess.run(None, {sess.get_inputs()[0].name: blob})
    return {nm: np.asarray(v) for nm, v in zip(names, out)}


def pick_face(paths=FACE_IMGS):
    for p in paths:
        if os.path.isfile(p):
            return p
    return None


def main(argv):
    ap = argparse.ArgumentParser(description="float ORT 基线（+官方后处理）")
    ap.add_argument("--onnx", default=DEFAULT_ONNX)
    ap.add_argument("--img", default=None, help="真脸图路径；--no-face 时忽略")
    ap.add_argument("--no-face", action="store_true", help="用确定性'无人脸'合成图")
    ap.add_argument("--out", default=None, help="基线 JSON 落点")
    ap.add_argument("--tensors-npz", default=None, help="12 路 float 张量落点（供比较器）")
    ap.add_argument("--score-thr", type=float, default=YP.SCORE_THR)
    ap.add_argument("--nms-thr", type=float, default=YP.NMS_THR)
    ap.add_argument("--top-k", type=int, default=YP.TOP_K)
    args = ap.parse_args(argv[1:])

    if not os.path.isfile(args.onnx):
        print("FATAL: 缺模型 %s" % args.onnx)
        return 3
    try:
        import onnxruntime  # noqa: F401
    except Exception as e:
        print("FATAL: 起不来 onnxruntime（%s）；请确认 PYTHONPATH 含 y1/.pydeps" % e)
        return 3

    if args.no_face:
        img, src = "no-face", "synth:synth_noface(seed=20261012)"
        hwc = YP.synth_noface()
    else:
        img = args.img or pick_face()
        if not img or not os.path.isfile(img):
            print("FATAL: 找不到真脸图（--img 指定，或用仓内的 %s）" % (FACE_IMGS,))
            return 3
        src = os.path.relpath(img, _H1).replace("\\", "/")
        try:
            hwc = YP.preprocess_image(img)
        except Exception as e:
            print("FATAL: 解不了图 %s（PIL 在 ai_npu_exp/deps_export；%s）" % (img, e))
            return 3

    blob = YP.to_nchw(hwc)
    in_md5 = hashlib.md5(blob.tobytes()).hexdigest()

    try:
        sess = make_session(args.onnx)
    except Exception as e:
        print("FATAL: ORT 会话起不来：%s" % e)
        return 3

    tens = run_float(sess, blob)
    missing = [n for n in YP.OUT_NAMES if n not in tens]
    if missing:
        print("FATAL: ORT 输出缺 %s（实有 %s）" % (missing, sorted(tens)))
        return 1

    dets = YP.postprocess(tens, args.score_thr, args.nms_thr, args.top_k)

    print("ORT model=%s" % os.path.relpath(args.onnx, _H1).replace("\\", "/"))
    print("ORT input=%s  nchw_md5=%s  shape=%s" % (src, in_md5, list(blob.shape)))
    print("ORT outputs=%s" % " ".join("%s%s" % (n, list(tens[n].shape)) for n in YP.OUT_NAMES))
    print("ORT score_thr=%.2f nms_thr=%.2f top_k=%d" % (args.score_thr, args.nms_thr, args.top_k))
    print("ORT FLOAT_DETS=%d" % len(dets))
    for k, d in enumerate(dets[:5]):
        print("  #%d conf=%.4f box=[%.1f,%.1f,%.1f,%.1f] kps=%s"
              % (k, d["conf"], *d["box"],
                 [[round(a, 1), round(b, 1)] for a, b in d["kps"]]))

    if args.tensors_npz:
        np.savez(args.tensors_npz, **{n: tens[n] for n in YP.OUT_NAMES})
        print("ORT tensors_npz=%s" % args.tensors_npz)
    if args.out:
        with open(args.out, "w", encoding="utf-8") as fh:
            json.dump({"src": src, "nchw_md5": in_md5, "score_thr": args.score_thr,
                       "nms_thr": args.nms_thr, "top_k": args.top_k,
                       "dets": [{"box": [round(v, 4) for v in d["box"]],
                                 "kps": [[round(a, 4), round(b, 4)] for a, b in d["kps"]],
                                 "conf": round(d["conf"], 6)} for d in dets]}, fh, indent=1)
        print("ORT baseline_json=%s" % args.out)

    # ---- 方向判据（本发）----
    if args.no_face:
        ok = (len(dets) == 0)
        print("ORT_DIRECTION no_face_expected_0 got=%d => %s" % (len(dets), "OK" if ok else "RED"))
    else:
        ok = (len(dets) >= 1)
        print("ORT_DIRECTION real_face_expected_ge1 got=%d => %s" % (len(dets), "OK" if ok else "RED"))
    print("ORT_RESULT: %s" % ("PASS" if ok else "FAIL"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
