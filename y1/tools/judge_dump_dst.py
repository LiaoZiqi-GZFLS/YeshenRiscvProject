"""dump 与黄金逐字节对账（run_b1/b2 系列闸门里的同一口径，抽成独立脚本便于单作业复跑）。

用法：python judge_dump_dst.py <work> <name> <tag> <dst> <len>
  · dump = <work>/<name>.<tag>.dump（一行一字节十六进制）
  · gold = <work>/<name>/gold.hex
  · pre  = <work>/<name>/pre.hex（要求 DST 段前后 32 B 邻居不变）
输出：MISMATCH=<n> NEIGHBOR_BAD=<n>
"""
import sys


def load(p):
    out = []
    for line in open(p, encoding="utf-8", errors="replace"):
        s = line.strip()
        if not s:
            continue
        try:
            out.append(int(s, 16) & 0xFF)
        except ValueError:
            out.append(-1)
    return out


def main():
    work, name, tag, dst, ln = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4]), int(sys.argv[5])
    d = load(work + "/" + name + "." + tag + ".dump")
    g = load(work + "/" + name + "/gold.hex")
    pre = load(work + "/" + name + "/pre.hex")
    k = min(ln, len(g), max(0, len(d) - dst))
    mm = sum(1 for i in range(k) if d[dst + i] != g[i]) + max(0, ln - k)
    nb = sum(1 for j in range(32) if d[dst - 32 + j] != pre[dst - 32 + j]) if dst >= 32 else 0
    nb += sum(1 for j in range(32) if d[dst + k + j] != pre[dst + k + j]) if dst + k + 32 <= len(d) else 0
    print("MISMATCH=%d NEIGHBOR_BAD=%d" % (mm, nb))


main()
