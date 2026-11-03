import sys, numpy as np
sys.path.insert(0, 'tools')
import quant_ref as Q

def requant(acc, M, zy):
    return Q.requant_int(acc, M, zy)

rng = np.random.default_rng(7)
ok = True
for trial in range(200):
    CO, CIoG, KH, KW = 4, 3, 3, 3
    grp = 1
    CI = CIoG * grp
    H = W = 8
    sx = float(rng.uniform(1e-3, 5e-3)); sy = float(rng.uniform(1e-3, 5e-3))
    zx = int(rng.integers(-128, 128)); zy = int(rng.integers(-128, 128))
    sw = float(rng.uniform(1e-3, 5e-3)); zw = int(rng.integers(-128, 128))
    xq = rng.integers(-128, 128, size=(1, CI, H, W)).astype(np.int8)
    wq = rng.integers(-128, 128, size=(CO, CIoG, KH, KW)).astype(np.int8)
    w = {"q": wq, "scale": sw, "zp": zw, "float": None}
    bias = rng.uniform(-1, 1, size=(CO,))
    pads = (1, 1, 1, 1); strides = (1, 1)
    # golden
    y_gold = Q.conv_vec(xq, w, sx, sy, zw, zx, bias, pads, strides, grp, zy)
    # "hardware" form: centered weights c=wq-zw ; pad with zx ; bias' = b0 - zx*sum_all(c)
    c = wq.astype(np.int64) - zw
    pt, pl, pb, pr = pads
    xp = np.pad(xq.astype(np.int64), ((0,0),(0,0),(pt,pb),(pl,pr)), constant_values=zx)
    acc = np.zeros((CO, H+pt+pb-KH+1, W+pl+pr-KW+1), dtype=np.int64)
    Ho, Wo = acc.shape[1], acc.shape[2]
    for co in range(CO):
        for ci in range(CI):
            for ky in range(KH):
                for kx in range(KW):
                    acc[co] += c[co, ci, ky, kx] * xp[0, ci, ky:ky+Ho, kx:kx+Wo]
    b0 = np.round(bias / (sx * sw)).astype(np.int64)
    sumc = c.reshape(CO, -1).sum(axis=1)          # sum of ALL taps per co
    bprime = b0 - zx * sumc
    acc = acc + bprime[:, None, None]
    M = Q.scale_ratio_multiplier((sx * sw) / sy)
    y_hw = requant(acc, M, zy).reshape(1, CO, Ho, Wo)
    if not np.array_equal(y_gold, y_hw):
        ok = False
        d = int(np.abs(y_gold.astype(int) - y_hw.astype(int)).max())
        print("TRIAL %d MISMATCH maxdiff=%d zx=%d zw=%d" % (trial, d, zx, zw))
        break
print("ALL_EQUAL" if ok else "FAILED", "trials=200")
