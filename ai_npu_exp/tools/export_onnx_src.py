#!/usr/bin/env python3
"""Build YOLOv5s *from the tag-v3.0 source* (``models/yolov5s.yaml``) with random
weights and export it to ONNX (opset 11), Detect head in ``export`` mode.

Usage:
    python export_onnx_src.py <out.onnx>

Why this replaces the asset-derived export (``export_onnx.py``)
--------------------------------------------------------------
The release asset ``v3.0/yolov5s.pt`` is **not** the product of the tag-v3.0
code: its 51 ``models.common.Conv`` activations are ``nn.Hardswish``.
Un-exported that becomes ``HardSigmoid + Mul`` in the ONNX, i.e. an activation
the accelerator does not have (it hardcodes ``LeakyReLU(ratio=0.1)``); only the
8 ``BottleneckCSP`` inner activations survive as ``LeakyReLU``. The tag-v3.0
source, by contrast, is all-``nn.LeakyReLU(0.1)`` (``models/common.py:26,58``).

Operator coverage is a property of the **graph**, not of the weights, and the
whole point of M0 Part A is to compare "the graph of the family we claim the
accelerator targets" against the accelerator's op set. So building the graph
from the source we make the claim about -- with random initialisation -- is both
sufficient and strictly more honest than trusting a mislabelled asset. Random
weights also guarantee the graph matches the source by construction, which is
exactly what removes the false negative this sub-task exists to avoid.

Environment notes (hard-won, unchanged from ``export_onnx.py``)
--------------------------------------------------------------
1. ``third_party/yolov5_v3.0`` must go on ``sys.path`` via an ABSOLUTE path
   (derived from ``__file__``): a relative entry makes torch's DLL loader raise
   ``OSError: [WinError 87]``.
2. ``PYTHONPATH`` on this Windows shell MUST use ``;`` as separator (CPython
   splits it on ``os.pathsep``).
3. ``Model(cfg, ch=3, nc=80)`` matches tag v3.0's signature verbatim --
   ``def __init__(self, cfg='yolov5s.yaml', ch=3, nc=None)`` -- so no adaptation
   of ``Model.__init__`` was needed.
4. Passing an EXISTING absolute ``*.yaml`` path means ``Model.__init__`` only
   does ``open(cfg)``; ``attempt_download`` is never reached, so no network I/O.
5. Construction must be wrapped in ``torch.no_grad()`` -- see the inline note at
   the call site. This is the only divergence from a raw ``Model(...)`` call, and
   it touches neither the module tree nor the traced graph.
5. The Detect head is put in export mode via a plain attribute assignment
   (``self.export`` is read by ``Detect.forward``); the graph then ends at the
   three RAW head tensors -- no anchor decode, no grid, no sigmoid, no NMS.
"""

import collections
import os
import sys

# Windows console codepage is GBK; never let a non-ASCII byte abort the run.
sys.stdout.reconfigure(errors="replace")

_REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
_YOLO_V3 = os.path.join(_REPO, "third_party", "yolov5_v3.0")
_YAML = os.path.join(_YOLO_V3, "models", "yolov5s.yaml")

# MUST be absolute (docstring point 1).
sys.path.insert(0, _YOLO_V3)

import torch  # noqa: E402  (import order matters: sys.path first)
from models.yolo import Model  # noqa: E402


def main():
    if len(sys.argv) != 2:
        print("usage: export_onnx_src.py <out.onnx>")
        return 2
    out = sys.argv[1]

    if not os.path.isfile(_YAML):
        print("FATAL: yaml not found:", _YAML)
        return 2

    print("torch          :", torch.__version__)
    print("yolov5 v3.0    :", _YOLO_V3)
    print("yaml           :", _YAML)

    # --- build the graph FROM THE SOURCE YAML, random weights ---------------
    # Point 3: signature is v3.0's own; point 4: absolute yaml path => no download.
    #
    # MINIMAL ADAPTATION (the only one), forced by modern torch and applied HERE
    # rather than in third_party/ (which is read-only):
    #   tag-v3.0 `Model.__init__` ends with `self._initialize_biases()`, whose
    #       b = mi.bias.view(m.na, -1); b[:, 4] += ...
    #   mutates a VIEW of a leaf Parameter that requires grad. torch >= 1.9
    #   rejects that with
    #       RuntimeError: a view of a leaf Variable that requires grad is being
    #       used in an in-place operation.
    #   (The asset path never hit this: unpickling never runs _initialize_biases.)
    #   Wrapping construction in `torch.no_grad()` exempts the in-place update
    #   from that autograd guard. It changes NO module structure, NO activation
    #   type and NO forward graph -- the delivered artifact is unaffected; bias
    #   initialisation values are irrelevant to an op-coverage graph anyway.
    with torch.no_grad():
        model = Model(_YAML, ch=3, nc=80)
    model.eval()
    print("model type     :", type(model).__name__)
    # v3.0's Model keeps nc inside `self.yaml` (there is no `self.nc` attribute),
    # so read it from there rather than from the object.
    print("nc / ch        :", model.yaml["nc"], model.yaml.get("ch", 3))
    print("stride         :", [float(s) for s in model.stride])

    # --- PyTorch-side activation inventory (corroboration, BEFORE export) ---
    # This is the check that would have caught the asset/source mismatch: the
    # tag-v3.0 source must show LeakyReLU everywhere and ZERO Hardswish.
    cls_counts = collections.Counter(type(m).__name__ for m in model.modules())
    print("--- module-class inventory (torch side) ---")
    for k, v in sorted(cls_counts.items(), key=lambda kv: (-kv[1], kv[0])):
        print(f"  {k:20s} {v}")
    acts = collections.Counter(
        type(m.act).__name__ for m in model.modules() if hasattr(m, "act"))
    print("act inventory  :", dict(sorted(acts.items())))
    print("LeakyReLU mods :", cls_counts.get("LeakyReLU", 0))
    print("Hardswish mods :", cls_counts.get("Hardswish", 0))
    for m in model.modules():
        if hasattr(m, "act") and type(m.act).__name__ != "LeakyReLU":
            print("  UNEXPECTED act:", type(m).__name__, type(m.act).__name__)

    # --- put the Detect head into export mode (point 5) ---------------------
    head = model.model[-1]
    head.export = True
    print("detect head    :", type(head).__name__,
          "-> export =", bool(head.export))

    # --- dry run: prove the decode branch is NOT taken ----------------------
    img = torch.zeros(1, 3, 640, 640)
    with torch.no_grad():
        y = model(img)
    if isinstance(y, (list, tuple)) and len(y) == 3 and tuple(y[0].shape)[-1] == 85:
        print("dry-run outputs:", [tuple(t.shape) for t in y],
              "-> raw head tensors, decode SKIPPED")
    else:
        print("dry-run output :",
              [tuple(t.shape) for t in y] if isinstance(y, (list, tuple))
              else [tuple(y.shape)],
              "-> WARNING: looks like the DECODE path")

    # --- export -------------------------------------------------------------
    torch.onnx.export(
        model,
        img,
        out,
        opset_version=11,
        input_names=["input"],
        do_constant_folding=True,
    )

    print("exported       :", os.path.abspath(out))
    print("bytes          :", os.path.getsize(out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
