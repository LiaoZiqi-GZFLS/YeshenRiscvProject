#!/usr/bin/env python3
"""3x3 int8 卷积的整数参考。
模式: dense | dw | group=N
用法: mac_ref.py <mode> <C_in> <C_out> <H> <W> <seed>
      mac_ref.py --selftest
输出: 三行 "X ..." / "W ..." / "Y ..."（十六进制字节，空格分隔）
注意: requant 口径是**测试夹具**（固定 >>6 + clamp），不是生产量化器。

========================= 算术契约（冻结，后续任务依赖） =========================
* 3x3 卷积，padding = 1，stride = 1；输入/权值 int8，累加 int32。
* requant（**仅测试夹具**，别当生产量化器）：
      y = max(-128, min(127, acc >> 6))
  其中 >> 必须是**算术右移**（有符号、向下取整），例如 -1 >> 6 == -1。
  真正的按层 scale / zero-point 方案是后面的事；这里固定 >>6 只是为了让装置有一个
  唯一、可逐字节对账的 int8 输出，**不得**被当成最终的量化口径。
* 模式：
    dense      group = 1
    dw         depthwise: group = C_in = C_out（每个输出通道只吃一个输入通道）
    group=N    group = N；要求 C_in % N == 0 且 C_out % N == 0；
               输出通道 co 吃第 g 组的输入通道，g = (co * N) / C_out。
* 张量展平顺序（**这是参考与装置之间的接口，改它就等于改硬件接口**）：
    X 展平为 [ci][y][x]
    W 展平为 [co][ci_local][ky][kx]，其中 ci_local 跑遍 co 所属组的 C_in/GROUP 个通道
       即 index = co * (C_in/GROUP) * 9 + ci_local * 9 + ky * 3 + kx
    Y 展平为 [co][y][x]
* 输出格式：每个张量一行，十六进制字节，空格分隔，前缀 "X " / "W " / "Y "，
  可直接喂给 Verilog 的 $readmemh（本脚本另外约定：每个字节一个十六进制 token）。

随机源是 seeded random.Random(seed) ⇒ 同一 seed 必然复现同一组向量。
因此**本文件一旦被硬件任务引用，随机抽样顺序不得再改**（改了等于换向量）。
"""
import sys
import random

# Windows 控制台是 GBK，非 ASCII 直接写会炸；统一换成可替换字符。
sys.stdout.reconfigure(errors="replace")
sys.stderr.reconfigure(errors="replace")

PAD = 1
K = 3
SHIFT = 6  # 测试夹具的固定右移位数

# 输入取满 int8 范围；权值刻意取小（仍是 int8）。
# 理由：>>6 之后若累加值动辄上万，Y 会大面积 clamp 到 0x7f/0x80，
# 错误的累加值同样被 clamp 掩盖 ⇒ 判据丧失分辨度。取小权值让 Y 铺满 [-128,127]，
# 逐字节对账才真的能抓到错误。
X_MIN, X_MAX = -128, 127
W_MIN, W_MAX = -4, 3


def parse_mode(mode, cin, cout):
    """把 mode 归一成 group 数，并做合法性检查。"""
    if mode == "dense":
        group = 1
    elif mode == "dw":
        if cin != cout:
            raise ValueError("dw 要求 C_in == C_out（group = C_in = C_out），得到 %d/%d" % (cin, cout))
        group = cin
    elif mode.startswith("group="):
        try:
            group = int(mode.split("=", 1)[1])
        except ValueError:
            raise ValueError("无法解析模式 %r" % mode)
    else:
        raise ValueError("未知模式 %r（只有 dense | dw | group=N）" % mode)
    if group <= 0:
        raise ValueError("group 必须为正，得到 %d" % group)
    if cin % group or cout % group:
        raise ValueError("要求 C_in %% N == 0 且 C_out %% N == 0，得到 C_in=%d C_out=%d N=%d"
                         % (cin, cout, group))
    return group


def requant(acc):
    """测试夹具量化：算术语义右移 SHIFT 位 + 夹到 int8。"""
    return max(-128, min(127, acc >> SHIFT))


def conv_core(group, cin, cout, h, w, x, wt):
    """给定展平的 X / W，返回**未量化**的 int32 累加结果（展平 [co][y][x]）。"""
    cpg = cin // group    # 每个输出组拥有的输入通道数
    opg = cout // group   # 每个组负责的输出通道数
    acc = [0] * (cout * h * w)
    for co in range(cout):
        g = (co * group) // cout          # 契约里写死的组映射
        assert g == co // opg, "组映射不一致"
        ci_base = g * cpg
        w_base = co * cpg * 9
        for ci_local in range(cpg):
            ci = ci_base + ci_local
            x_base = ci * h * w
            w_base_l = w_base + ci_local * 9
            for ky in range(K):
                for kx in range(K):
                    kv = wt[w_base_l + ky * K + kx]
                    if kv == 0:
                        continue
                    for y in range(h):
                        iy = y + ky - PAD
                        if iy < 0 or iy >= h:
                            continue
                        for xo in range(w):
                            ix = xo + kx - PAD
                            if ix < 0 or ix >= w:
                                continue
                            acc[(co * h + y) * w + xo] += kv * x[x_base + iy * w + ix]
    return acc


def conv3x3(mode, cin, cout, h, w, seed):
    """返回 (x, wt, acc)：X 展平、W 展平、未量化的 int32 累加（展平 [co][y][x]）。"""
    group = parse_mode(mode, cin, cout)
    cpg = cin // group
    rng = random.Random(seed)
    x = [rng.randint(X_MIN, X_MAX) for _ in range(cin * h * w)]
    wt = [rng.randint(W_MIN, W_MAX) for _ in range(cout * cpg * 9)]
    acc = conv_core(group, cin, cout, h, w, x, wt)
    return x, wt, acc


def dump(name, flat):
    """一个张量 = 一行：'<name> hh hh ...'，字节按二进制补码低 8 位输出。"""
    return "%s %s" % (name, " ".join("%02x" % (v & 0xFF) for v in flat))


# ------------------------------- 自测 -----------------------------------------

FAILS = []


def chk(cond, msg):
    if cond:
        print("  PASS  " + msg)
    else:
        print("  FAIL  " + msg)
        FAILS.append(msg)


def selftest():
    """两（三）个小规模、手算可验证的用例 —— 让参考自身可独立被检验。

    注意：这里比较的是 requant **之前**的累加值，因为 >>6 会把 4/6/9 全变成 0，
    量化之后无法区分越界 tap 数。夹具的 >>6 只在 main 里施加。
    """
    # 用例 1：dense 1->1, 3x3, 权值全 +1, 输入全 +1, 零填充。
    # 每个输出 = 落在边界内的 tap 个数：角 4、边 6、心 9。
    x = [1] * 9
    wt = [1] * 9
    acc = conv_core(1, 1, 1, 3, 3, x, wt)
    print("[selftest] case1 dense 1x1 3x3 pad=1 全 1（比较 requant 前）")
    chk(acc == [4, 6, 4, 6, 9, 6, 4, 6, 4],
        "越界 tap 计数 角4/边6/心9，得到 %s" % acc)
    chk([requant(v) for v in acc] == [0] * 9,
        "夹具 >>6 之后 4/6/9 全部变 0（说明自测必须比 requant 前）")

    # 用例 2：dw 2->2, 3x3, 只有中心权 = 1 ⇒ 输出通道 i 只依赖输入通道 i。
    # 若组映射错成 dense，通道 0 的中心会是 1+2=3，本用例就会抓到。
    x = [1] * 9 + [2] * 9                 # [ci][y][x]，ch0=1, ch1=2
    wt = [0] * 9 + [0] * 9
    wt[4] = 1                             # co=0, ci_local=0, 中心
    wt[9 + 4] = 1                         # co=1, ci_local=0, 中心
    acc = conv_core(2, 2, 2, 3, 3, x, wt)
    print("[selftest] case2 dw 2->2 3x3 单位中心权（比较 requant 前）")
    chk(acc[0:9] == [1] * 9, "输出通道 0 只吃输入通道 0（应全 1），得到 %s" % acc[0:9])
    chk(acc[9:18] == [2] * 9, "输出通道 1 只吃输入通道 1（应全 2），得到 %s" % acc[9:18])
    chk(acc[4] == 1, "通道间无串扰（若按 dense 会得 1+2=3），得到 %d" % acc[4])

    # 用例 3：group=2, 4->4 ⇒ co 0,1 吃第 0 组（输入通道 0,1），co 2,3 吃第 1 组（2,3）。
    x = [1] * 9 + [2] * 9 + [3] * 9 + [4] * 9
    cpg = 4 // 2
    wt = [0] * (4 * cpg * 9)
    for co in range(4):
        wt[co * cpg * 9 + 4] = 1          # 每个 co 只取本组 ci_local=0 的中心
    acc = conv_core(2, 4, 4, 3, 3, x, wt)
    print("[selftest] case3 group=2 4->4 3x3（比较 requant 前）")
    chk(acc[0:18] == [1] * 18, "co 0,1 取第 0 组 ⇒ 只看输入通道 0（应全 1）")
    chk(acc[18:36] == [3] * 18, "co 2,3 取第 1 组 ⇒ 只看输入通道 2（应全 3）")

    # 用例 4：展平索引口径的边界自检（W 的 co 步长 = (C_in/GROUP)*9）。
    x, wt, acc = conv3x3("group=2", 4, 4, 2, 2, 12345)
    chk(len(x) == 4 * 2 * 2, "X 长度 = C_in*H*W = 16，得到 %d" % len(x))
    chk(len(wt) == 4 * 2 * 9, "W 长度 = C_out*(C_in/GROUP)*9 = 72，得到 %d" % len(wt))
    chk(len(acc) == 4 * 2 * 2, "Y 长度 = C_out*H*W = 16，得到 %d" % len(acc))

    # 用例 5：seed 可复现性。
    a = conv3x3("dense", 2, 2, 2, 2, 7)
    b = conv3x3("dense", 2, 2, 2, 2, 7)
    c = conv3x3("dense", 2, 2, 2, 2, 8)
    chk(a == b, "同一 seed 复现同一向量")
    chk(a != c, "不同 seed 给出不同向量（负对照的前提）")

    if FAILS:
        print("SELFTEST: FAIL (%d)" % len(FAILS))
        return 1
    print("SELFTEST: PASS")
    return 0


# ------------------------------- 入口 -----------------------------------------

def usage():
    print(__doc__)


def main(argv):
    if "--selftest" in argv[1:]:
        return selftest()
    if len(argv) != 7:
        usage()
        return 2
    try:
        mode, cin, cout, h, w = argv[1], int(argv[2]), int(argv[3]), int(argv[4]), int(argv[5])
        seed = int(argv[6])
    except ValueError:
        print("FATAL: 参数必须是整数（mode 除外）", file=sys.stderr)
        return 2
    if min(cin, cout, h, w) <= 0:
        print("FATAL: C_in/C_out/H/W 必须为正", file=sys.stderr)
        return 2
    try:
        group = parse_mode(mode, cin, cout)
    except ValueError as e:
        print("FATAL: %s" % e, file=sys.stderr)
        return 2

    x, wt, acc = conv3x3(mode, cin, cout, h, w, seed)
    out = [requant(a) for a in acc]

    # 只有三行输出（供 grep / $readmemh 消费），维度信息走 stderr。
    print(dump("X", x))
    print(dump("W", wt))
    print(dump("Y", out))

    sat = sum(1 for v in out if v in (127, -128))
    print("# dims mode=%s group=%d C_in=%d C_out=%d H=%d W=%d seed=%d | "
          "X=%d W=%d Y=%d | clamp@127/-128=%d/%d"
          % (mode, group, cin, cout, h, w, seed,
             len(x), len(wt), len(out), sat, sum(1 for v in out if v == -128)),
          file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
