#!/usr/bin/env python3
"""Export the YOLOv5 v3.0 checkpoint to ONNX (opset 11) with the Detect head in
`export` mode: the graph ends at the RAW conv outputs of the three detection
layers -- no anchor decode, no grid building, no NMS.

Usage:
    python export_onnx.py <weights.pt> <out.onnx>

Environment notes (all hard-won, all verified by running this script):

  1. IMPORTS. The yolov5 v3.0 repo (``third_party/yolov5_v3.0``) must be put on
     ``sys.path`` via an ABSOLUTE path, because torch's DLL loader rejects a
     relative entry on Windows with ``OSError: [WinError 87]``. The path is
     derived from ``__file__`` so it works from any cwd. The dependency dirs are
     supplied through PYTHONPATH, and on Windows the entries MUST be separated
     by ``;`` -- CPython splits PYTHONPATH on ``os.pathsep``, so the POSIX-looking
     ``a:b`` form is treated as ONE directory and ``import torch`` fails with
     ModuleNotFoundError.

  2. ``torch.load(..., weights_only=False)`` is REQUIRED: the release asset
     holds pickled custom classes (models.common.*, models.yolo.Model), not bare
     tensors. Safe here because the file is the pinned ultralytics/yolov5 v3.0
     release asset (sha256 in reports/model_provenance.md).

  3. The checkpoint is stored in **float16** (7,468,157 fp16 params ~ 14.9 MB,
     file 15,184,597 B). ``model.float()`` is therefore mandatory, otherwise the
     ONNX would carry fp16 initializers.

  4. The Detect head of this checkpoint carries NO ``export`` attribute in its
     pickled ``__dict__`` (i.e. the weights were saved by code newer than the
     v3.0 tag, which does not set it at construction time -- see point 5). The
     *class* resolved here IS v3.0's ``models.yolo.Detect``, whose ``forward``
     reads ``self.export``, so a plain attribute assignment is enough; the
     dry-run below proves the decode branch was actually taken/not taken.

  5. The same checkpoint's ``models.common.Conv`` modules use
     ``torch.nn.Hardswish`` as activation (51 of them) and only the 8
     ``BottleneckCSP`` use ``nn.LeakyReLU(0.1)`` -- it does NOT match the v3.0
     tag source, which uses ``nn.LeakyReLU(0.1)`` everywhere. The unpickled
     Hardswish objects were created by a torch whose ``nn.Hardswish`` had no
     ``inplace`` attribute, so under torch 2.8 they raise
     ``AttributeError: 'Hardswish' object has no attribute 'inplace'``. The
     shim below restores the missing default (``inplace=False``). It is
     behaviour-neutral: hardswish(x) either way.

No NMS wrapper is ever added here.
"""

import os
import sys

# Windows console codepage is GBK; never let a non-ASCII byte abort the run.
sys.stdout.reconfigure(errors="replace")

# MUST be an absolute path (docstring point 1).
_YOLO_V3 = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..",
                                       "third_party", "yolov5_v3.0"))
sys.path.insert(0, _YOLO_V3)

import torch  # noqa: E402  (import order matters: sys.path first)
import torch.nn as nn  # noqa: E402


def compat_shim(model):
    """Make a checkpoint pickled by an older torch loadable by torch 2.x.

    Only restores defaults that the old pickler never stored; no maths changes.
    """

    def fix(mod):
        if isinstance(mod, nn.Hardswish) and not hasattr(mod, "inplace"):
            mod.inplace = False  # old torch's Hardswish was always out-of-place
            return True
        return False

    return sum(fix(m) for m in model.modules())


def main():
    if len(sys.argv) != 3:
        print("usage: export_onnx.py <weights.pt> <out.onnx>")
        return 2
    weights, out = sys.argv[1], sys.argv[2]

    print("torch          :", torch.__version__)
    print("yolov5 v3.0    :", _YOLO_V3)
    print("weights        :", os.path.abspath(weights))

    # weights_only=False: the checkpoint holds pickled custom classes (point 2).
    ckpt = torch.load(weights, map_location="cpu", weights_only=False)
    model = ckpt["model"] if isinstance(ckpt, dict) and "model" in ckpt else ckpt
    model = model.float()  # point 3: checkpoint is fp16
    model.eval()
    print("model type     :", type(model).__name__)

    n_fixed = compat_shim(model)
    print("hardswish shim :", n_fixed, "module(s) got inplace=False")

    # --- put the Detect head into export mode --------------------------------
    export_mode = False
    if hasattr(model, "model"):
        head = model.model[-1]
        head.export = True  # point 4: assignment is enough, see dry run below
        export_mode = bool(getattr(head, "export", False))
        print("detect head    :", type(head).__name__,
              "-> export =", export_mode)
    else:
        # Minimal adaptation for a bare (non-Model) object: nothing to switch on.
        print("model has no .model attribute (not a yolov5 Model wrapper); "
              "exporting as-is (NOT in export mode)")

    # --- dry run ------------------------------------------------------------
    # Export mode is *proved*, not assumed: with the decode branch taken the head
    # returns a list of nl=(1,na,ny,nx,no) tensors; without it, the sigmoid/
    # grid/anchors decode returns (torch.cat(z,1), x).
    img = torch.zeros(1, 3, 640, 640)
    with torch.no_grad():
        y = model(img)
    if isinstance(y, (list, tuple)) and len(y) == 3 and tuple(y[0].shape)[-1] == 85:
        shapes = [tuple(t.shape) for t in y]
        print("dry-run outputs:", len(y), "raw head tensors,", shapes)
        print("decode skipped : YES (no sigmoid/grid/anchor ops will be traced)")
    else:
        shapes = [tuple(t.shape) for t in y] if isinstance(y, (list, tuple)) \
            else [tuple(y.shape)]
        print("dry-run output :", shapes,
              "-> WARNING: looks like the DECODE path, not export mode")

    # --- export -------------------------------------------------------------
    torch.onnx.export(
        model,
        img,
        out,
        opset_version=11,
        input_names=["input"],
        output_names=["output"],
        do_constant_folding=True,
    )

    print("exported       :", os.path.abspath(out))
    print("bytes          :", os.path.getsize(out))
    print("detect export  :", "yes" if export_mode else "no")
    return 0


if __name__ == "__main__":
    sys.exit(main())
