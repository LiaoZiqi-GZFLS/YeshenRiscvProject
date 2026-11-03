#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""check_post_c.py —— **C 版后处理 vs Python 后处理** 逐框对账（Task 10 交付判据）。

============================ 这个脚本证什么 ============================
板内 `y1cam` 的 YuNet 后处理（反量化 → 去折叠 → decode → NMS）是**C 重写**的；
它必须与冻结口径 `yunet_post.postprocess` 在**同一组真实张量**上给出同一组框。
本脚本把这条链在主机上跑一遍（同源编译 `y1cam.c`，只把 main 换成 `-DPOST_C_HOST`）：

  1) 参考数据：`npu_frame_run.py --int8-tensors`（冻结 `quant_ref` 黄金）落 `.npz`（12 路
     **反量化**张量）+ `.json`（每路 scale/zp）。有脸图 ⇒ 必有检出；缺图则 `--no-face`。
  2) 写 raw：12 条记录，头 = `name[16] + int32 n + int32 c + float32 scale + int32 zp`，
     载荷 = `n*c` 个 int8，**通道平面**（`[c*N + p]`，= 板内 DDR 里 bbox/kps 的真实布局：
     `wgt_index.layout_fold` 的 `src_stride` / `readback_to_tensors.folded_read`）。
     值从 npz 反算：`q = rint(v/scale) + zp`（`v = (q-zp)*scale` 的逆），逐条 md5 可核。
  3) 编译主机版 C：`gcc -O2 -Wall -DPOST_C_HOST y1cam.c -o y1/build/post_c_host -lm`
     （Windows 宿主下走 `wsl -e`；与板内**同一份源码**）。
  4) Python 用 `YP.postprocess` 对同一组张量算框；C 用 `post_c_host` 算框。
     判据：**数量相等**；按 conf 降序逐对 **IoU ≥ 0.99**；**|Δconf| < 1e-4**。
  5) 负对照（两维各一发）：`post_c_host --shift-x 60`（框整体挪 60 px ⇒ IoU 判据必须红）、
     `--conf-add 0.01`（置信度整体加 0.01 ⇒ |Δconf| 判据必须红）。没发火 ⇒ 退 2（判据无牙）。
     演示完**还原**正常路径并复报绿。
     ★ 计划里草拟的"交换 cls/obj"是**数学恒等**（score = sqrt(cls·obj) 对称），不能当负对照。

打印：`POST_C: PASS dets=N iou_min=... conf_max=...`；红则 `POST_C: FAIL ...`。
退出码：0 = 正判据绿且负对照发火；1 = 正判据红；2 = 负对照没发火 / 前置缺失。

用法：
  python y1/tools/check_post_c.py                 # 自动找仓内人脸图
  python y1/tools/check_post_c.py --img X.jpg     # 指定图
  python y1/tools/check_post_c.py --no-face       # 无脸合成图（此时另加 synthetic 用例防"空过"）
  python y1/tools/check_post_c.py --skip-ref      # 复用已生成的 npz/json（省 2 分钟 ORT）
"""
import argparse
import hashlib
import io
import json
import os
import re
import struct
import subprocess
import sys

import numpy as np

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

HERE = os.path.dirname(os.path.abspath(__file__))
Y1 = os.path.dirname(HERE)
REPO = os.path.dirname(Y1)
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import yunet_post as YP                      # noqa: E402  （后处理口径只此一份）

IS_WIN = (os.name == "nt")
BUILD = os.path.join(Y1, "build")
WORK = os.path.join(BUILD, "post_c")
SRC = os.path.join(HERE, "y1cam.c")
EXE = os.path.join(BUILD, "post_c_host")
IOU_MIN = 0.99
CONF_MAX = 1e-4

CAND_IMAGES = [
    os.path.join(REPO, "ai_npu_exp", "deps_export", "matplotlib", "mpl-data", "sample_data",
                 "grace_hopper.jpg"),
    os.path.join(REPO, "third_party", "yolov5_v3.0", "inference", "images", "zidane.jpg"),
]


def wsl_path(p):
    """Windows 绝对路径 → WSL 的 /mnt/<drive>/...；非 Windows 原样返回。"""
    p = os.path.abspath(p).replace("\\", "/")
    if IS_WIN and len(p) > 1 and p[1] == ":":
        return "/mnt/" + p[0].lower() + p[2:]
    return p


def run(cmd, env=None, quiet=False):
    p = subprocess.run(cmd, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    raw = p.stdout.decode("utf-8", "replace")
    # WSL 的 localhost 代理提示会混进 stderr（多行、编码乱）⇒ 逐行丢掉
    out = "\n".join(ln for ln in raw.splitlines()
                    if not ln.startswith("wsl:") and "\ufffd" not in ln)
    if not quiet:
        for ln in out.strip().splitlines()[-6:]:
            print("    | " + ln)
    return p.returncode, out


# ============================ 1) 参考数据（冻结 quant_ref）============================
def gen_reference(img, npz, js):
    """跑 npu_frame_run --int8-tensors 落 npz/json（子进程；不碰板）。"""
    env = os.environ.copy()
    sep = ";" if IS_WIN else ":"
    deps = [HERE, os.path.join(Y1, ".pydeps"),
            os.path.join(REPO, "third_party", "yunet", "deps"),
            os.path.join(REPO, "ai_npu_exp", "deps_export")]
    env["PYTHONPATH"] = sep.join([d for d in deps if os.path.isdir(d)] +
                                 ([env["PYTHONPATH"]] if env.get("PYTHONPATH") else []))
    env["PYTHONIOENCODING"] = "utf-8"
    cmd = [sys.executable, "-u", os.path.join(HERE, "npu_frame_run.py"), "--int8-tensors",
           "--npz", npz, "--json", js]
    cmd += (["--img", img] if img else ["--no-face"])
    print("[ref] " + " ".join(cmd[1:]))
    return run(cmd, env=env)


# ============================ 2) raw 张量（板内布局）============================
def write_raw(path, tensors, params, order):
    """12 路 → raw 记录（通道平面 int8）。params[name] = (scale, zp)。返回逐条指纹。"""
    rows = []
    with open(path, "wb") as f:
        for name in order:
            v = np.asarray(tensors[name], dtype=np.float64)
            if v.ndim == 3:
                v = v[0]
            n, c = int(v.shape[0]), int(v.shape[1])
            s, z = params[name]
            s = float(s)
            q = np.clip(np.rint(v / s).astype(np.int64) + int(z), -128, 127).astype(np.int8)
            assert q.shape == (n, c), (name, q.shape)
            raw = np.ascontiguousarray(q.T.reshape(-1)) if c > 1 else np.ascontiguousarray(q.reshape(-1))
            rec = struct.pack("<16siifi", name.encode("ascii"), n, c, s, int(z))
            f.write(rec)
            f.write(raw.tobytes())
            rows.append({"name": name, "n": n, "c": c, "scale": s, "zp": int(z),
                         "md5": hashlib.md5(raw.tobytes()).hexdigest()[:12]})
    return rows


# ============================ 3) 主机 C（同一份源码）============================
def build_host():
    cmd = ("gcc -O2 -Wall -DPOST_C_HOST -o '%s' '%s' -lm"
           % (wsl_path(EXE), wsl_path(SRC)))
    if IS_WIN:
        rc, _ = run(["wsl", "-e", "bash", "-lc", cmd])
    else:
        rc, _ = run(["/bin/bash", "-lc", cmd])
    if rc != 0 or not os.path.isfile(EXE):
        raise SystemExit("FATAL: 主机构建失败（%s）" % EXE)
    print("[host] %s  %d B" % (EXE, os.path.getsize(EXE)))


def run_host(raw, extra=None):
    args = ["--raw", wsl_path(raw)] + list(extra or [])
    if IS_WIN:
        cmd = ["wsl", "-e", wsl_path(EXE)] + args
    else:
        cmd = [EXE] + args
    rc, out = run(cmd, quiet=True)
    dets = []
    for ln in out.splitlines():
        m = re.match(r"DET (\d+) conf=([-\d.eE+]+) box=\[([-\d.eE+]+),([-\d.eE+]+),"
                     r"([-\d.eE+]+),([-\d.eE+]+)\]", ln)
        if m:
            g = [float(x) for x in m.groups()[1:]]
            dets.append({"conf": g[0], "box": g[1:5]})
    info = [ln for ln in out.splitlines() if ln.startswith("POST_C_HOST")]
    return rc, dets, info


# ============================ 4) 判据 ============================
def iou_xywh(a, b):
    ax, ay, aw, ah = a
    bx, by, bw, bh = b
    ix = max(0.0, min(ax + aw, bx + bw) - max(ax, bx))
    iy = max(0.0, min(ay + ah, by + bh) - max(ay, by))
    inter = ix * iy
    ua = aw * ah + bw * bh - inter
    return float(inter / ua) if ua > 0 else 0.0


def compare(py_dets, c_dets):
    """按 conf 降序逐对比较 → (ok, iou_min, conf_max, reason)。"""
    a = sorted(py_dets, key=lambda d: -d["conf"])
    b = sorted(c_dets, key=lambda d: -d["conf"])
    if len(a) != len(b):
        return False, 0.0, float("inf"), "数量不等 %d vs %d" % (len(a), len(b))
    if not a:
        return True, 1.0, 0.0, ""
    ious, cds = [], []
    for da, db in zip(a, b):
        ious.append(iou_xywh(da["box"], db["box"]))
        cds.append(abs(float(da["conf"]) - float(db["conf"])))
    iou_min, conf_max = min(ious), max(cds)
    bad = []
    if iou_min < IOU_MIN:
        bad.append("iou_min=%.6f < %.2f" % (iou_min, IOU_MIN))
    if conf_max >= CONF_MAX:
        bad.append("conf_max=%.3e >= %.0e" % (conf_max, CONF_MAX))
    return (not bad), iou_min, conf_max, "; ".join(bad)


def show(name, dets):
    for k, d in enumerate(dets[:5]):
        print("    %s #%d conf=%.6f box=[%.2f,%.2f,%.2f,%.2f]"
              % (name, k, d["conf"], *d["box"]))
    if len(dets) > 5:
        print("    %s ... (%d dets)" % (name, len(dets)))


# ============================ 5) 合成单 anchor 用例（防"空过"）============================
def synthetic_tensors():
    """yunet_post.selftest 的同款：stride32 的 anchor(10,10) 命中 ⇒ 手算框 (288,272,64,96)。"""
    N = {}
    for st in YP.STRIDES:
        nn = (YP.NCH // st) ** 2
        for k, c in YP.LITTLE.items():
            N["%s_%d" % (k, st)] = np.zeros((1, nn, c), dtype=np.float64)
    for k in ("cls", "obj"):
        N["%s_32" % k][0, 210, 0] = 1.0
    N["bbox_32"][0, 210] = [0.0, 0.0, np.log(2.0), np.log(3.0)]
    return N


def main(argv):
    ap = argparse.ArgumentParser(description="C vs Python 后处理对账（y1cam 主机版）")
    ap.add_argument("--img", default=None, help="人脸图；缺省自动找仓内样例")
    ap.add_argument("--no-face", action="store_true", help="确定性无脸合成图")
    ap.add_argument("--skip-ref", action="store_true", help="复用 <work>/outs.npz / outs.json")
    ap.add_argument("--tag", default="", help="打印前缀")
    args = ap.parse_args(argv[1:])

    tag = ("%s " % args.tag) if args.tag else ""
    os.makedirs(WORK, exist_ok=True)
    npz = os.path.join(WORK, "outs.npz")
    js = os.path.join(WORK, "outs.json")
    raw = os.path.join(WORK, "outs.raw")

    img = None if args.no_face else (args.img or next((p for p in CAND_IMAGES if os.path.isfile(p)), None))
    if not args.no_face and img is None:
        print("!! 找不到人脸样例图 ⇒ 退回 --no-face（对账仍做，但人脸方向缺样例）")
        args.no_face = True

    print("== %scheck_post_c: C 后处理 vs Python 后处理 ==" % tag)
    print("[cfg] score_thr=%.2f nms_thr=%.2f top_k=%d；判据 iou>=%.2f conf<%.0e"
          % (YP.SCORE_THR, YP.NMS_THR, YP.TOP_K, IOU_MIN, CONF_MAX))

    if not (args.skip_ref and os.path.isfile(npz) and os.path.isfile(js)):
        rc, _ = gen_reference(img, npz, js)
        if rc != 0:
            if not args.no_face:
                print("!! 真脸参考生成失败 ⇒ 退回 --no-face（记限制）")
                rc, _ = gen_reference(None, npz, js)
            if rc != 0:
                print("POST_C: FAIL 参考数据生成失败")
                return 2
    tensors = {k: v for k, v in np.load(npz, allow_pickle=False).items()}
    with io.open(js, encoding="utf-8") as fh:
        meta = json.load(fh)["meta"]
    params = {n: (float(meta[n]["scale"]), int(meta[n]["zp"])) for n in YP.OUT_NAMES}
    src = ("face:%s" % os.path.basename(img)) if img else "synthetic:no-face"
    print("[ref] %s  tensors_npz=%s" % (src, npz))

    py = YP.postprocess(tensors, YP.SCORE_THR, YP.NMS_THR, YP.TOP_K)
    rows = write_raw(raw, tensors, params, YP.OUT_NAMES)
    print("[raw] %s (%d B) 12 记录（通道平面 int8）：" % (raw, os.path.getsize(raw)))
    for r in rows:
        print("    %-8s n=%-5d c=%-2d s=%.8g zp=%-4d int8_md5=%s"
              % (r["name"], r["n"], r["c"], r["scale"], r["zp"], r["md5"]))
    print("[py] dets=%d" % len(py))
    show("py", py)

    build_host()
    rc, cdet, info = run_host(raw)
    for ln in info:
        print("[c ] " + ln)
    if rc != 0:
        print("POST_C: FAIL C 主机程序退 %d" % rc)
        return 1
    print("[c ] dets=%d" % len(cdet))
    show("c ", cdet)

    ok, iou_min, conf_max, why = compare(py, cdet)
    line = ("POST_C: %s dets=%d iou_min=%.6f conf_max=%.3e"
            % ("PASS" if ok else "FAIL", len(py), iou_min, conf_max))
    if not ok:
        print(line + "  reason=" + why)
        return 1
    print(line)

    # ---- 负对照的"靶子"：真实样例 0 检出（无脸图）时，先补一个合成单 anchor 用例 ----
    neg_raw, neg_py = raw, py
    if len(py) == 0:
        print("[synthetic] 真实样例 0 检出 ⇒ 追加单 anchor 用例（防止判据空过）")
        syn = synthetic_tensors()
        # cls/obj 落在 [0,1] ⇒ s=1/127；bbox 要装下 ln3=1.0986，用 s=0.02（否则被 int8 上限削平）
        sparams = {n: ((0.02 if n.startswith("bbox_") else 1.0 / 127.0), 0) for n in YP.OUT_NAMES}
        sraw = os.path.join(WORK, "synthetic.raw")
        write_raw(sraw, syn, sparams, YP.OUT_NAMES)
        # Python 侧用**同一份 int8 反量化后的张量**（与 C 看到的输入逐字节一致）
        st = {}
        for n in YP.OUT_NAMES:
            v = np.asarray(syn[n], dtype=np.float64)
            if v.ndim == 3:
                v = v[0]
            s, z = sparams[n]
            q = np.clip(np.rint(v / s).astype(np.int64) + z, -128, 127)
            st[n] = ((q - z) * s).reshape(1, v.shape[0], v.shape[1])
        sp = YP.postprocess(st, YP.SCORE_THR, YP.NMS_THR, YP.TOP_K)
        rc, sc, _ = run_host(sraw)
        s_ok, s_iou, s_conf, s_why = compare(sp, sc)
        print("[synthetic] py=%d c=%d iou_min=%.6f conf_max=%.3e %s"
              % (len(sp), len(sc), s_iou, s_conf, s_why))
        # 手算：anchor(10,10)@s32、bbox=(0,0,ln2,ln3) ⇒ 框 (288,272,64,96)。
        # int8 量化（s=1/127）把 ln2/ln3 落到 88/98 码点 ⇒ 宽高差 ~0.03 px，故用 1 px 容差。
        near = (len(sp) == 1 and abs(sp[0]["box"][0] - 288.0) < 1.0
                and abs(sp[0]["box"][1] - 272.0) < 1.0
                and abs(sp[0]["box"][2] - 64.0) < 1.0
                and abs(sp[0]["box"][3] - 96.0) < 1.0)
        if not (rc == 0 and s_ok and near):
            print("POST_C: FAIL synthetic 用例不绿")
            return 1
        print("POST_C: PASS dets=%d iou_min=%.6f conf_max=%.3e（synthetic 单 anchor）"
              % (len(sp), s_iou, s_conf))
        neg_raw, neg_py = sraw, sp

    # ---- 负对照：两个维度各打一发（IoU / conf），每发都必须红 ----
    # ★ 计划里草拟的"交换 cls/obj"是数学恒等（score = sqrt(cls·obj) 对称），不作负对照。
    negs = [("--shift-x 60（框整体 +60 px）", ["--shift-x", "60"], "iou"),
            ("--conf-add 0.01（置信度整体 +0.01）", ["--conf-add", "0.01"], "conf")]
    fired = 0
    for label, extra, dim in negs:
        rc, ndet, _ = run_host(neg_raw, extra)
        n_ok, n_iou, n_conf, n_why = compare(neg_py, ndet)
        good = (rc == 0 and not n_ok and dim in n_why)
        print("[negctl] %s ⇒ dets=%d compare=%s（%s）%s"
              % (label, len(ndet), "FAIL" if not n_ok else "PASS", n_why or "无差异",
                 "OK" if good else "NO-FIRE"))
        if good:
            fired += 1
    if fired != len(negs):
        print("POST_C: FAIL 负对照只发火 %d/%d（判据无牙）" % (fired, len(negs)))
        return 2
    print("POST_C negctl: OK（%d/%d 发火：IoU 与 conf 两个维度都咬得住）" % (fired, len(negs)))

    # ---- 还原：正常路径复报绿（日志以绿收尾） ----
    rc, cdet2, _ = run_host(raw)
    ok2, iou2, conf2, why2 = compare(py, cdet2)
    if not (rc == 0 and ok2):
        print("POST_C: FAIL 还原后正常路径红（%s）" % (why2 or "rc=%d" % rc))
        return 1
    print("POST_C: PASS dets=%d iou_min=%.6f conf_max=%.3e（还原复核）"
          % (len(py), iou2, conf2))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
