#!/usr/bin/env python3
"""bake_yshell_into_card.py —— 把当前的 yshell 二进制烘进 TF 卡镜像的 rootfs。

做法（不改任何构建链、不重跑 buildroot）：
  1) 解析基准卡镜像的 YSLD 计划表，抽出 5 个 blob（fw_jump/Image/dtb/rootfs/payload）；
  2) 直接**就地改 newc cpio**：把 `root/gui/yshell` 这一项的数据换成新二进制
     （保留其余所有项的模式/属主/时间戳；不落盘解包 ⇒ 不需要 root，也不会碰设备节点）；
  3) 用 mk_sd_image.build_plan 用**同样的地址**重新拼计划（重算两级 CRC）；
  4) 读回校验：计划头/每段 CRC、rootfs 里 yshell 的数据 md5 == 新二进制。

用法：
  python scripts/bake_yshell_into_card.py \
      --base sw/images/sd_gpu0.img \
      --yshell ../YeshenGui/board/variants/mainline_gpu/yshell \
      --out sw/images/sd_gui3d.img
"""
import argparse
import hashlib
import os
import struct
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "sim"))
from mk_sd_image import build_plan, crc32, HDR_CRC_LEN, HDR_CRC_OFF, ENT_CRC_OFF  # noqa: E402

SECTOR = 512
ROOTFS_ADDR = 0x83000000
YSHELL_NAME = b"root/gui/yshell"


def cpio_walk(buf):
    """遍历 newc cpio，产出 (name, header_start, data_start, filesize, header_bytes)。"""
    off = 0
    while off + 110 <= len(buf) and buf[off:off + 6] == b"070701":
        fields = [int(buf[off + 6 + 8 * i: off + 14 + 8 * i], 16) for i in range(13)]
        namesize, filesize = fields[11], fields[6]
        name = buf[off + 110: off + 110 + namesize - 1]
        # newc：(固定头 110 + 名字长度) 补齐到 4 的倍数（对齐的是**绝对偏移**，不是名字长度）
        dstart = off + 110 + namesize
        dstart += (-dstart) & 3
        yield name, off, dstart, filesize, buf[off:off + 110]
        if name == b"TRAILER!!!":
            return
        off = dstart + ((filesize + 3) & ~3)
    raise SystemExit("cpio 解析失败：不是 newc 或已截断")


def cpio_repack(buf, replace):
    """replace: {name: (data, mode)}；保留其它项原样。"""
    out = bytearray()
    done = set()
    for name, hstart, dstart, filesize, hdr in cpio_walk(buf):
        if name in replace:
            data, mode = replace[name]
            f = [int(hdr[6 + 8 * i: 14 + 8 * i], 16) for i in range(13)]
            f[1], f[6] = mode, len(data)
            hdr = b"070701" + b"".join(b"%08X" % v for v in f)
            out += hdr + name + b"\0"
            out += b"\0" * ((-len(out)) & 3)
            out += data
            out += b"\0" * ((-len(out)) & 3)
            done.add(name)
        else:
            end = dstart + filesize
            out += buf[hstart:end]
            out += b"\0" * ((-len(out)) & 3)
    missing = set(replace) - done
    if missing:
        raise SystemExit("cpio 里找不到：%s" % ", ".join(x.decode() for x in missing))
    return bytes(out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", required=True, help="基准卡镜像（其 rootfs 里除 yshell 外都算 known-good）")
    ap.add_argument("--yshell", required=True)
    ap.add_argument("--out", required=True)
    a = ap.parse_args()

    ys = open(a.yshell, "rb").read()
    ys_md5 = hashlib.md5(ys).hexdigest()
    print("== 新 yshell: %d B md5=%s" % (len(ys), ys_md5))

    img = open(a.base, "rb").read()
    if img[:4] != b"YSLD":
        raise SystemExit("基准镜像不是 YSLD 计划卡")
    n = struct.unpack(">I", img[4:8])[0]
    ents = [struct.unpack(">III", img[8 + 12 * i: 20 + 12 * i]) for i in range(n)]
    print("   基准计划: %d 项 %s" % (n, ["0x%08X/%d blk" % (e[0], e[2]) for e in ents]))

    addrs, blobs = [], []
    for addr, sb, nb in ents:
        blob = img[sb * SECTOR:(sb + nb) * SECTOR]
        addrs.append(addr)
        blobs.append(blob)

    try:
        ri = addrs.index(ROOTFS_ADDR)
    except ValueError:
        raise SystemExit("计划里没有 0x%08X（rootfs）" % ROOTFS_ADDR)

    old = blobs[ri]
    has = [nm for nm, *_ in cpio_walk(old) if nm == YSHELL_NAME]
    if not has:
        raise SystemExit("rootfs 里没有 %s" % YSHELL_NAME.decode())

    new_rootfs = cpio_repack(old, {YSHELL_NAME: (ys, 0o100755)})
    print("   rootfs: %d -> %d B" % (len(old), len(new_rootfs)))
    blobs[ri] = new_rootfs

    out, table = build_plan(list(zip(addrs, blobs)), 0)
    open(a.out, "wb").write(out)
    print("== 写出 %s (%d B)" % (a.out, len(out)))

    # ---- 读回校验 ----
    back = open(a.out, "rb").read()
    assert back[:4] == b"YSLD" and struct.unpack(">I", back[4:8])[0] == n
    assert crc32(back[:HDR_CRC_LEN]) == struct.unpack(">I", back[HDR_CRC_OFF:HDR_CRC_OFF + 4])[0], "头 CRC"
    for i, (_, sb, nb) in enumerate(table):
        seg = back[sb * SECTOR:(sb + nb) * SECTOR]
        want = struct.unpack(">I", back[ENT_CRC_OFF + 4 * i: ENT_CRC_OFF + 4 * i + 4])[0]
        assert crc32(seg) == want, "第 %d 段 CRC" % i
    rb = back[table[ri][1] * SECTOR:(table[ri][1] + table[ri][2]) * SECTOR]
    got = None
    for name, _, dstart, filesize, _ in cpio_walk(rb):
        if name == YSHELL_NAME:
            got = rb[dstart:dstart + filesize]
    assert got is not None, "读回找不到 yshell"
    md5 = hashlib.md5(got).hexdigest()
    assert md5 == ys_md5, "读回 yshell md5 不符"
    print("== 校验：头 CRC + %d 段 CRC + rootfs 内 yshell md5=%s OK" % (n, md5))
    print("   镜像 md5=%s" % hashlib.md5(back).hexdigest())


if __name__ == "__main__":
    main()
