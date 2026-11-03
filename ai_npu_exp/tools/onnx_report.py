#!/usr/bin/env python3
"""Generic ONNX operator report (generalized from third_party/yunet/analyze_yunet.py).

Usage:
    python onnx_report.py <model.onnx>

Prints five sections in a FIXED order so downstream tooling can machine-judge:

    1. == io ==              per-line ``  in  <name> <shape>`` / ``  out <name> <shape>``
    2. == ops ==             per-line ``  <op_type> <count>``, count descending
    3. == conv ==            one line per Conv: ``  <idx> <name> group=.. k=.. s=.. p=.. d=..``
    4. == conv_group_hist == single line, JSON of {group: count} sorted by key
    5. == activations ==     only non-linear ops that ACTUALLY appear (else ``  (none)``)

The ``sys.stdout.reconfigure(errors="replace")`` call is REQUIRED on Windows: the
console codepage is GBK, and printing any non-ASCII byte would otherwise raise
UnicodeEncodeError (which can masquerade as "no output").
"""

import sys
import collections
import json

import onnx

# Windows console is GBK: never let a non-ASCII byte abort the report.
sys.stdout.reconfigure(errors="replace")

path = sys.argv[1]
m = onnx.load(path)
g = m.graph


def dims(t):
    return [d.dim_value if d.HasField("dim_value") else (d.dim_param or "?")
            for d in t.type.tensor_type.shape.dim]


# --- 1. io -----------------------------------------------------------------
print("== io ==")
for i in g.input:
    print(f"  in  {i.name} {dims(i)}")
for o in g.output:
    print(f"  out {o.name} {dims(o)}")

# --- 2. ops ----------------------------------------------------------------
hist = collections.Counter(n.op_type for n in g.node)
print("== ops ==")
for k, v in hist.most_common():
    print(f"  {k} {v}")

# --- 3. conv ---------------------------------------------------------------
print("== conv ==")
groups = collections.Counter()
idx = 0
for n in g.node:
    if n.op_type != "Conv":
        continue
    idx += 1
    a = {x.name: x for x in n.attribute}

    def gi(k, d=None):
        if k not in a:
            return d
        v = a[k]
        return list(v.ints) if v.ints else v.i

    grp = gi("group", 1)
    groups[grp] += 1
    print(f"  {idx} {n.name[:40]} group={grp} k={gi('kernel_shape')} "
          f"s={gi('strides')} p={gi('pads')} d={gi('dilations')}")

# --- 4. conv_group_hist ----------------------------------------------------
print(f"== conv_group_hist == {json.dumps(dict(sorted(groups.items())))}")

# --- 5. activations --------------------------------------------------------
# Candidate non-linear op types; only those ACTUALLY present are printed.
NONLINEAR = {"Relu", "LeakyRelu", "PRelu", "Sigmoid", "Softmax", "Tanh",
             "HardSigmoid", "HardSwish", "Silu", "Swish", "Clip", "Exp",
             "Elu", "Mish"}
print("== activations ==")
hit = {k: hist[k] for k in sorted(NONLINEAR) if hist.get(k)}
if not hit:
    print("  (none)")
for k, v in hit.items():
    print(f"  {k} {v}")
