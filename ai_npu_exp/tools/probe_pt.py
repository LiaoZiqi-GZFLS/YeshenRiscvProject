import sys, os
sys.stdout.reconfigure(errors="replace")
sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..",
                                                "..", "third_party", "yolov5_v3.0")))
import torch

ckpt = torch.load(sys.argv[1], map_location="cpu", weights_only=False)
print("ckpt type      :", type(ckpt).__name__)
model = ckpt["model"] if isinstance(ckpt, dict) and "model" in ckpt else ckpt
print("model type     :", type(model).__name__)
mods = list(model.modules())
print("module count   :", len(mods))
classes = sorted({type(m).__name__ for m in mods})
print("module classes :", classes)
print("nc / anchors   :", getattr(model, "nc", None), getattr(model, "anchors", None))
