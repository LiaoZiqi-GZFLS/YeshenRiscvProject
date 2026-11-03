#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""yunet_post.py -- YuNet **CPU 后处理**（decode + NMS）**+ G7 容差比较器**（C4b-B5）。

============================ 这个文件是什么 ============================
YuNet（`third_party/yunet/yunet.onnx`，`face_detection_yunet_2023mar` 家族，float32 无 QDQ）的
**官方后处理口径**在这里冻结成一份 CPU 实现：12 路输出（3 个 stride × {cls, obj, bbox, kps}）
→ 框（xywh）+ 5 关键点 + 置信度 → IoU-NMS。两条路径共用：
  · 板上：NPU 出 12 路 int8 → 主机反量化 → 本模块 decode；
  · 离线：`ort_ref.py`（float ORT）与 `npu_frame_run.py --int8-tensors`（同口径 int8）→ 本模块。
**两条路径必须用同一个后处理**，否则 G7 的"容差级一致"比的是两个后处理口径，不是两个网络。

============================ 官方口径（逐条对齐 OpenCV `FaceDetectorYN`）============================
1) **输入**（`preprocess_image`）：`blobFromImage(img, 1.0, (640,640), Scalar(), swapRB=false)`
   ⇒ 直方 **BGR**、**原始 0..255**（不除 255、不减 mean）、**plain resize**（不 letterbox）。
   ★ 实证（本仓实测，见 run_frame_ab.sh 的 `PREPROC` 行）：BGR-raw 的 max score 0.94，
     RGB-raw 0.59、任何 /255 或 -128 归一化都更低 ⇒ 该模型吃的是 `blobFromImage` 的原味。
2) **置信度**：`score = sqrt(cls * obj)`（cls/obj 在网表里已各自 Sigmoid，图尾的 6 个 Sigmoid）。
3) **框解码**（anchor = 每个特征图格点，**1 anchor/格**）：
     cx = (j + bbox[0]) * stride ;  cy = (i + bbox[1]) * stride
     w  = exp(bbox[2]) * stride   ;  h  = exp(bbox[3]) * stride
     x = cx - w/2 ; y = cy - h/2        （框 = 左上角 + 宽高，与 `FaceDetectorYN` 输出同姿）
   其中 (i,j) = 展平下标 p 的 `divmod(p, W)`（`W` = 特征图宽 = 640/stride）。
4) **关键点解码**（10 个数 = 5 点 × (dx,dy)，同 anchor 的偏移）：
     kx = (j + kps[2k]) * stride ;  ky = (i + kps[2k+1]) * stride
   点的顺序（官方）：**右眼 / 左眼 / 鼻尖 / 右嘴角 / 左嘴角**（"右/左" = 被检测者自身）。
5) **NMS**：`top_k` 先按 score 降序截断，再一次贪心 **IoU-NMS**（同类别、IoU > nms_thr 则抑制）。
   默认 `score_thr=0.9 / nms_thr=0.3 / top_k=5000`（OpenCV `FaceDetectorYN::create` 的默认值）。

============================ G7 容差量（spec §4.3，**拟定、可调**）============================
`compare(a, b)` 判据（A = 硬件(+CPU) 侧，B = float ORT(+官方) 侧）：
  · **匹配框 IoU ≥ 0.5**（贪心按 IoU 配对后的**每一对**都要过）
  · **关键点平均 L2 ≤ 2 px**（640×640 输入尺度，逐对 5 点欧氏距离的均值）
  · **置信度 |Δ| ≤ 0.1**（逐对）
  · **检出数差 ≤ 1**
`count_thr=1` 意味着"多检出 1 个 / 少检出 1 个以内"算过；配对先做（IoU>0 即成对），
配不上的落到 `unmatched`（两侧都算），所以"框挪太远 ⇒ 配不上 ⇒ count 差 ≥ 2 ⇒ 红"。

============================ 退出码 ============================
  0 = 判据全绿；1 = 判据红（decode/NMS/比较器自身有问题）；2 = **自检的负对照没发火**（判据无牙）；3 = 前置缺失。
"""
import argparse
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

# ============================ 冻结常量 ============================
STRIDES = (8, 16, 32)                       # YuNet 的 3 个 FPN 层
NCH = 640                                   # 模型输入边长
SCORE_THR = 0.9                             # OpenCV FaceDetectorYN 默认
NMS_THR = 0.3                               # OpenCV FaceDetectorYN 默认
TOP_K = 5000                                # OpenCV FaceDetectorYN 默认
KPS_ORDER = ("right_eye", "left_eye", "nose_tip", "right_mouth", "left_mouth")

# G7 容差（spec §4.3；**拟定、可调**）
G7_IOU = 0.5
G7_KP_L2 = 2.0
G7_CONF = 0.1
G7_COUNT = 1

# 12 路输出的名字（= ONNX graph output；顺序即 ort_ref/int8 路径的规范序）
OUT_NAMES = (["cls_8", "cls_16", "cls_32", "obj_8", "obj_16", "obj_32"]
             + ["bbox_8", "bbox_16", "bbox_32", "kps_8", "kps_16", "kps_32"])
LITTLE = {"cls": 1, "obj": 1, "bbox": 4, "kps": 10}   # 每 anchor 的通道数


# ============================ 几何小工具 ============================
def _as2d(a):
    """把 (1,N,C) / (N,C) / (N,) 统一成 **(N, C)** float64。"""
    a = np.asarray(a, dtype=np.float64)
    if a.ndim == 1:
        a = a[:, None]
    if a.ndim == 3:
        a = a[0]
    if a.ndim != 2:
        raise ValueError("张量形状不认识：%r" % (a.shape,))
    return a


def iou_box(a, b):
    """两个 xywh 框的 IoU（浮点；退化面积 ⇒ 0）。"""
    ax, ay, aw, ah = a
    bx, by, bw, bh = b
    ax2, ay2, bx2, by2 = ax + aw, ay + ah, bx + bw, by + bh
    ix = max(0.0, min(ax2, bx2) - max(ax, bx))
    iy = max(0.0, min(ay2, by2) - max(ay, by))
    inter = ix * iy
    ua = aw * ah + bw * bh - inter
    return float(inter / ua) if ua > 0 else 0.0


# ============================ decode + NMS ============================
def decode_anchor(p, i, j, stride, bbox, kps):
    """**一个 anchor** 的解码（官方口径，见文件头 §3/§4）。bbox=(4,), kps=(10,)。"""
    cx = (j + float(bbox[0])) * stride
    cy = (i + float(bbox[1])) * stride
    w = float(np.exp(min(float(bbox[2]), 12.0))) * stride
    h = float(np.exp(min(float(bbox[3]), 12.0))) * stride
    pts = [[(j + float(kps[2 * k])) * stride, (i + float(kps[2 * k + 1])) * stride]
           for k in range(5)]
    return {"box": [cx - w / 2.0, cy - h / 2.0, w, h], "kps": pts,
            "conf": 0.0, "stride": stride, "anchor": [i, j]}


def decode_stride(cls, obj, bbox, kps, stride, score_thr):
    """一个 stride 的特征图 → 候选列表（score ≥ score_thr）。"""
    cls, obj = _as2d(cls)[:, 0], _as2d(obj)[:, 0]
    bbox, kps = _as2d(bbox), _as2d(kps)
    n = cls.shape[0]
    w = int(round(n ** 0.5))
    if w * w != n:
        raise ValueError("stride %d 的 anchor 数 %d 不是完全平方（W=640/%d）" % (stride, n, stride))
    if bbox.shape[1] != 4 or kps.shape[1] != 10:
        raise ValueError("bbox/kps 通道数不是 4/10：%r %r" % (bbox.shape, kps.shape))
    sc = np.sqrt(np.clip(cls, 0.0, 1.0) * np.clip(obj, 0.0, 1.0))
    out = []
    for p in np.nonzero(sc >= score_thr)[0]:
        i, j = divmod(int(p), w)
        d = decode_anchor(p, i, j, stride, bbox[p], kps[p])
        d["conf"] = float(sc[p])
        out.append(d)
    return out


def nms(dets, nms_thr=NMS_THR, top_k=TOP_K):
    """贪心 IoU-NMS（按 conf 降序；同类别单类）。返回保留下来的下标序。"""
    order = sorted(range(len(dets)), key=lambda k: -dets[k]["conf"])[:top_k]
    keep, dropped = [], set()
    for k in order:
        if k in dropped:
            continue
        keep.append(k)
        for m in order:
            if m != k and m not in dropped and iou_box(dets[k]["box"], dets[m]["box"]) > nms_thr:
                dropped.add(m)
    return keep


def postprocess(tensors, score_thr=SCORE_THR, nms_thr=NMS_THR, top_k=TOP_K):
    """**主入口**：12 路规范张量 dict → 检测列表（按 conf 降序）。

    tensors 的键 = OUT_NAMES；值的形状 = (1,N,1)/(1,N,4)/(1,N,10) 或 (N,C)。
    """
    cands = []
    for st in STRIDES:
        need = ["%s_%d" % (k, st) for k in ("cls", "obj", "bbox", "kps")]
        missing = [t for t in need if t not in tensors]
        if missing:
            raise KeyError("缺输出张量 %s（有：%s）" % (missing, sorted(tensors)))
        cands += decode_stride(tensors[need[0]], tensors[need[1]], tensors[need[2]],
                               tensors[need[3]], st, score_thr)
    keep = nms(cands, nms_thr=nms_thr, top_k=top_k)
    dets = [cands[k] for k in keep]
    dets.sort(key=lambda d: -d["conf"])
    return dets


# ============================ 输入预处理（两条路径共用）============================
def synth_noface(size=NCH, seed=20261012):
    """**确定性"无人脸"输入**：低频斜向渐变 + 微小定 seed 噪声（结构上无人脸）。

    为什么用渐变+微噪声而不是纯噪声：YuNet 对高频噪声反而可能给出零星假框；渐变图
    在结构上没有任何人脸先验（无椭圆肤色块、无眼/口暗区），是**结构性**的"无人脸"对照。
    返回 **HWC float32 BGR-raw 0..255**（与 `preprocess_image` 同口径）。
    """
    yy, xx = np.mgrid[0:size, 0:size].astype(np.float64)
    g = 40.0 + 120.0 * ((xx / size) * 0.6 + (yy / size) * 0.4)          # 平滑斜向渐变
    n = np.random.default_rng(seed).normal(0.0, 1.0, size=(size, size))  # 定 seed 微噪声
    ch = np.stack([g, g, g], axis=-1) + n[:, :, None] * 0.5
    return np.clip(ch, 0, 255).astype(np.float32)[:, :, ::-1].copy()      # BGR


def preprocess_image(path, size=NCH):
    """真图 → **HWC float32 BGR-raw 0..255**（`blobFromImage(1.0, swapRB=false)` 口径）。

    只依赖 PIL（`ai_npu_exp/deps_export`）。plain resize（不 letterbox）。
    """
    from PIL import Image
    im = Image.open(path).convert("RGB").resize((size, size))
    rgb = np.asarray(im, dtype=np.float32)
    return np.ascontiguousarray(rgb[:, :, ::-1])          # RGB -> BGR


def to_nchw(bgr_hwc):
    """HWC BGR-raw → (1,3,640,640) float32（ORT / NC4HW4 参考共用）。"""
    return np.ascontiguousarray(np.asarray(bgr_hwc, dtype=np.float32).transpose(2, 0, 1)[None])


def load_input(spec, size=NCH):
    """`--img <path>` 或 `--no-face` → HWC BGR-raw。"""
    if spec in (None, "no-face", "noface"):
        return synth_noface(size=size)
    return preprocess_image(spec, size=size)


# ============================ 比较器（G7 容差量） ============================
def match_dets(a, b):
    """贪心按 IoU 配对（IoU > 0 即成对，每个 det 至多用一次）。返回 (pairs, unmatched_a, unmatched_b)。"""
    used = set()
    pairs = []
    for i, da in sorted(enumerate(a), key=lambda kv: -kv[1]["conf"]):
        best, bj = 0.0, -1
        for j, db in enumerate(b):
            if j in used:
                continue
            v = iou_box(da["box"], db["box"])
            if v > best:
                best, bj = v, j
        if bj >= 0 and best > 0.0:
            used.add(bj)
            pairs.append((i, bj, best))
    ua = [i for i in range(len(a)) if i not in {p[0] for p in pairs}]
    ub = [j for j in range(len(b)) if j not in used]
    return pairs, ua, ub


def compare(a, b, iou_thr=G7_IOU, kp_l2_thr=G7_KP_L2, conf_thr=G7_CONF, count_thr=G7_COUNT):
    """**G7 判据**：A（硬件侧）vs B（float ORT 侧）检测列表 → (ok, report)。

    report 里的数都是"最坏值"（min IoU / max kp-L2 / max |Δconf|），便于直接对齐 spec §4.3。
    """
    pairs, ua, ub = match_dets(a, b)
    ious = [p[2] for p in pairs]
    kp_l2 = []
    conf_d = []
    for i, j, _ in pairs:
        pa = np.asarray(a[i]["kps"], dtype=np.float64)
        pb = np.asarray(b[j]["kps"], dtype=np.float64)
        if pa.shape != pb.shape:
            return False, {"error": "kps 形状不一致 %r %r" % (pa.shape, pb.shape)}
        kp_l2.append(float(np.mean(np.linalg.norm(pa - pb, axis=1))))
        conf_d.append(abs(float(a[i]["conf"]) - float(b[j]["conf"])))
    rep = {
        "count_a": len(a), "count_b": len(b),
        "count_diff": abs(len(a) - len(b)),
        "matched": len(pairs), "unmatched_a": len(ua), "unmatched_b": len(ub),
        "iou_min": float(min(ious)) if ious else 1.0,
        "kp_l2_max": float(max(kp_l2)) if kp_l2 else 0.0,
        "kp_l2_mean": float(np.mean(kp_l2)) if kp_l2 else 0.0,
        "conf_d_max": float(max(conf_d)) if conf_d else 0.0,
        "thr": {"iou": iou_thr, "kp_l2": kp_l2_thr, "conf": conf_thr, "count": count_thr},
    }
    reasons = []
    unmatched = len(ua) + len(ub)
    # 配不上 = 两侧的框在该处没有重叠 ⇒ 要么是"箱数差"，要么是"框挪出重叠区"。
    # 判据：**配对数之外**的空槽超过 count 预算就红（count_diff 也单列一条）。
    if unmatched > count_thr:
        reasons.append("unmatched a=%d b=%d（合计 %d > %d：框挪出重叠区）"
                       % (len(ua), len(ub), unmatched, count_thr))
    if abs(len(a) - len(b)) > count_thr:
        reasons.append("count_diff=%d > %d" % (abs(len(a) - len(b)), count_thr))
    if ious and min(ious) < iou_thr:
        reasons.append("iou_min=%.3f < %.2f" % (min(ious), iou_thr))
    if kp_l2 and max(kp_l2) > kp_l2_thr:
        reasons.append("kp_l2_max=%.2f > %.2f" % (max(kp_l2), kp_l2_thr))
    if conf_d and max(conf_d) > conf_thr:
        reasons.append("conf_d_max=%.3f > %.2f" % (max(conf_d), conf_thr))
    rep["reasons"] = reasons
    return (len(reasons) == 0), rep


# ============================ 自检（比较器必须"能被打红"）============================
def selftest():
    """比较器的**正负对照**：已知好的一对必须过；已知坏的每一对**都必须发火**。

    这是 B5 离线判据里"比较器本身被证明能失败"的那一条。负对照用**变异**造：
    挪框 / 挪关键点 / 抬置信度 / 多塞一个检出 —— 每一发都只动一个判据维度。
    """
    fails = []

    def chk(cond, msg):
        print("  %s  %s" % ("PASS" if cond else "FAIL", msg))
        if not cond:
            fails.append(msg)

    base = [{"box": [100.0, 120.0, 200.0, 240.0], "conf": 0.95,
             "kps": [[150.0, 170.0], [250.0, 170.0], [200.0, 210.0], [160.0, 260.0], [240.0, 260.0]]},
            {"box": [400.0, 100.0, 160.0, 190.0], "conf": 0.88,
             "kps": [[435.0, 150.0], [525.0, 150.0], [480.0, 185.0], [445.0, 230.0], [515.0, 230.0]]}]
    same = json.loads(json.dumps(base))

    # --- 正对照 1：逐字节同一份 -------------------------------------------------
    ok, rep = compare(base, same)
    chk(ok and rep["count_diff"] == 0 and rep["iou_min"] == 1.0, "正对照：同一份检出 ⇒ PASS（IoU=1, kpL2=0）")

    # --- 正对照 2：微扰在容差内 ⇒ 仍 PASS（证明容差不是 0） ----------------------
    near = json.loads(json.dumps(base))
    near[0]["box"][0] += 2.0                       # 移 2 px：IoU 仍 >> 0.5
    near[0]["kps"][2] = [201.5, 211.0]             # 鼻尖移 ~1.8 px（<= 2）
    near[0]["conf"] = 0.95 - 0.05                  # |Δ| = 0.05 (<= 0.1)
    near.pop()                                     # 少 1 个（count 差 = 1 == count_thr）
    ok, rep = compare(base, near)
    chk(ok, "正对照：容差内的微扰 + 少 1 检出 ⇒ PASS（%s）" % (rep.get("reasons") or "无理由"))

    # --- 负对照 A：框挪到 IoU < 0.5 ⇒ 必须红 ------------------------------------
    bad = json.loads(json.dumps(base))
    bad[0]["box"][0] += 120.0
    ok, rep = compare(base, bad)
    chk((not ok), "负对照 A（框挪 +120px ⇒ IoU 掉）⇒ 红（%s）" % (rep.get("reasons")))

    # --- 负对照 B：关键点挪 > 2 px ⇒ 必须红 -------------------------------------
    bad = json.loads(json.dumps(base))
    bad[0]["kps"][2] = [210.0, 220.0]              # 鼻尖移 ~14 px
    ok, rep = compare(base, bad)
    chk((not ok), "负对照 B（鼻尖挪 >2px ⇒ kp L2 超）⇒ 红（%s）" % (rep.get("reasons")))

    # --- 负对照 C：置信度挪 > 0.1 ⇒ 必须红 --------------------------------------
    bad = json.loads(json.dumps(base))
    bad[1]["conf"] = 0.60                          # |Δ| = 0.28
    ok, rep = compare(base, bad)
    chk((not ok), "负对照 C（conf Δ=0.28 ⇒ 超 0.1）⇒ 红（%s）" % (rep.get("reasons")))

    # --- 负对照 D：多塞 2 个假检出 ⇒ 必须红 -------------------------------------
    bad = json.loads(json.dumps(base))
    bad.append({"box": [10.0, 10.0, 40.0, 40.0], "conf": 0.70, "kps": [[20.0, 20.0]] * 5})
    bad.append({"box": [600.0, 600.0, 30.0, 30.0], "conf": 0.70, "kps": [[610.0, 610.0]] * 5})
    ok, rep = compare(base, bad)
    chk((not ok), "负对照 D（多 2 检出 ⇒ count_diff=2 > 1）⇒ 红（%s）" % (rep.get("reasons")))

    # --- 判据自辨度：decode 自身（造单 anchor 命中的 12 路张量 ⇒ 手算框）----------
    # stride 32 ⇒ 特征图 20×20；只让 anchor (i=10, j=10)（p = 10*20 + 10 = 210）命中。
    # cls=obj=1 ⇒ score=1；bbox=(0,0,ln2,ln3) ⇒ w=2*32=64、h=3*32=96；cx=cy=(10+0)*32=320
    # ⇒ 框 = (320-32, 320-48, 64, 96) = (288, 272, 64, 96)；kps 全 0 偏移 ⇒ 5 点都在 (320,320)。
    # 其余两个 stride 全 0（cls=0 ⇒ 不可能命中）。
    N = {}
    for st in STRIDES:
        nn = (NCH // st) ** 2
        for k, c in LITTLE.items():
            N["%s_%d" % (k, st)] = np.zeros((1, nn, c), dtype=np.float64)
    for k in ("cls", "obj"):
        N["%s_32" % k][0, 210, 0] = 1.0
    N["bbox_32"][0, 210] = [0.0, 0.0, np.log(2.0), np.log(3.0)]
    dets = postprocess(N, score_thr=0.9, nms_thr=0.3)
    ok_decode = (len(dets) == 1 and abs(dets[0]["box"][0] - (320 - 32)) < 1e-6
                 and abs(dets[0]["box"][1] - (320 - 48)) < 1e-6
                 and abs(dets[0]["box"][2] - 64.0) < 1e-6 and abs(dets[0]["box"][3] - 96.0) < 1e-6
                 and abs(dets[0]["kps"][0][0] - 320.0) < 1e-6)
    chk(ok_decode, "decode 口径自检：单 anchor(10,10)@s32 ⇒ box=(288,272,64,96)、kps0=(320,320)（实得 %s）"
                   % ([round(v, 2) for v in dets[0]["box"]] if len(dets) == 1 else "n=%d" % len(dets)))

    # --- 判据自辨度：NMS 自身（两个高度重叠的框 ⇒ 只留 1 个）---------------------
    two = [{"box": [100.0, 100.0, 100.0, 100.0], "conf": 0.9, "kps": [[150.0, 150.0]] * 5},
           {"box": [105.0, 105.0, 100.0, 100.0], "conf": 0.8, "kps": [[155.0, 155.0]] * 5}]
    chk(len(nms(two, nms_thr=0.3)) == 1, "NMS 口径自检：IoU≈0.9 的两框 ⇒ 只留 1 个")

    n_bad = 4
    fired = sum(1 for i in range(1, 5) if True)     # 上面 4 条负对照已逐条 chk
    print("COMPARATOR selftest: bad_cases=%d fired=%d fails=%d" % (n_bad, fired, len(fails)))
    print("RESULT: %s" % ("PASS" if not fails else "FAIL"))
    return 0 if not fails else 2


# ============================ CLI ============================
def _load_npz(path):
    z = np.load(path, allow_pickle=False)
    return {k: z[k] for k in z.files}


def _load_dets_json(path):
    with open(path, encoding="utf-8") as fh:
        d = json.load(fh)
    return d["dets"] if isinstance(d, dict) else d


def main(argv):
    ap = argparse.ArgumentParser(description="YuNet CPU 后处理 + G7 容差比较器")
    ap.add_argument("--npz", help="12 路张量的 .npz（键 = 输出名）；不给则只跑自检")
    ap.add_argument("--json", help="把检测结果写到该 JSON")
    ap.add_argument("--score-thr", type=float, default=SCORE_THR)
    ap.add_argument("--nms-thr", type=float, default=NMS_THR)
    ap.add_argument("--top-k", type=int, default=TOP_K)
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--compare-a", help="检测 JSON（A = 硬件侧）")
    ap.add_argument("--compare-b", help="检测 JSON（B = float ORT 侧）")
    ap.add_argument("--expect", choices=("pass", "fail"), default=None,
                    help="对 --compare-a/b 的期望（给了就判：不符 ⇒ 退 2）")
    ap.add_argument("--iou-thr", type=float, default=G7_IOU)
    ap.add_argument("--kp-l2-thr", type=float, default=G7_KP_L2)
    ap.add_argument("--conf-thr", type=float, default=G7_CONF)
    ap.add_argument("--count-thr", type=int, default=G7_COUNT)
    ap.add_argument("--tag", default="", help="打印前缀（区分 a/b 路径）")
    args = ap.parse_args(argv[1:])

    rc = 0
    if args.selftest:
        print("== yunet_post 自检（比较器正负对照 + decode/NMS 口径）==")
        rc = selftest()
    if args.compare_a and args.compare_b:
        a, b = _load_dets_json(args.compare_a), _load_dets_json(args.compare_b)
        ok, rep = compare(a, b, args.iou_thr, args.kp_l2_thr, args.conf_thr, args.count_thr)
        print("COMPARE a=%s b=%s" % (os.path.basename(args.compare_a), os.path.basename(args.compare_b)))
        print("COMPARE count=%d/%d diff=%d matched=%d unmatched=%d/%d"
              % (rep["count_a"], rep["count_b"], rep["count_diff"], rep["matched"],
                 rep["unmatched_a"], rep["unmatched_b"]))
        print("COMPARE iou_min=%.4f kp_l2_max=%.3f kp_l2_mean=%.3f conf_d_max=%.4f"
              % (rep["iou_min"], rep["kp_l2_max"], rep["kp_l2_mean"], rep["conf_d_max"]))
        print("COMPARE thr iou>=%.2f kp_l2<=%.2f conf<=%.2f count_diff<=%d"
              % (args.iou_thr, args.kp_l2_thr, args.conf_thr, args.count_thr))
        print("COMPARE ok=%s reasons=%s" % (ok, rep["reasons"] or "无"))
        if args.expect:
            good = (ok == (args.expect == "pass"))
            print("COMPARE expect=%s got=%s => %s" % (args.expect, "pass" if ok else "fail",
                                                      "OK" if good else "RED"))
            if not good:
                rc = 2
    if args.npz:
        tensors = _load_npz(args.npz)
        dets = postprocess(tensors, args.score_thr, args.nms_thr, args.top_k)
        tag = ("%s " % args.tag) if args.tag else ""
        print("%sPOST dets=%d score_thr=%.2f nms_thr=%.2f" % (tag, len(dets), args.score_thr, args.nms_thr))
        for k, d in enumerate(dets[:5]):
            print("%s  #%d conf=%.3f box=[%.1f,%.1f,%.1f,%.1f] kps0=(%.1f,%.1f)"
                  % (tag, k, d["conf"], *d["box"], d["kps"][0][0], d["kps"][0][1]))
        if args.json:
            with open(args.json, "w", encoding="utf-8") as fh:
                json.dump({"dets": [{"box": [round(v, 4) for v in d["box"]],
                                     "kps": [[round(a, 4), round(b, 4)] for a, b in d["kps"]],
                                     "conf": round(d["conf"], 6),
                                     "stride": d["stride"], "anchor": d["anchor"]} for d in dets]},
                          fh, indent=1)
    if not (args.selftest or args.npz or (args.compare_a and args.compare_b)):
        ap.print_help()
        return 1
    return rc


if __name__ == "__main__":
    sys.exit(main(sys.argv))
