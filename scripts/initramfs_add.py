#!/usr/bin/env python3
"""initramfs_add.py — 往 newc 格式的 initramfs(.cpio) 里**增/改**文件，不改动其余条目。

为什么不用 `cpio -id` 解包再打包：解包到普通用户会撞 `dev/console: Cannot mknod`
（镜像里带设备节点，WSL 非 root 无法创建）⇒ 设备节点会丢。本脚本按 newc 格式**逐条复制**，
只对 `--add` 指定的路径做替换/新增，其余字节级保留。

用法：
  python scripts/initramfs_add.py --in sw/images/rootfs.cpio --out /tmp/rootfs_v2.cpio \
      --add sw/buildroot-external/.../root/y1/y1cam:/root/y1/y1cam \
      --add sw/buildroot-external/.../etc/init.d/S99y1cam.sh:/etc/init.d/S99y1cam.sh

约定：
  · `src` 为宿主文件（普通文件/符号链接），`dst` 为镜像内绝对路径（去掉前导 /）；
  · 目标已存在 ⇒ 用新内容替换（沿用旧 inode 号）；
  · 目标不存在 ⇒ 追加新条目；父目录必须已存在（本脚本不 mkdir）；
  · **权限不能沿用宿主**（Windows 下 st_mode 只有 0o666，没有 x 位 —— 实踩：
    开机会话脚本与 /root/y1 下的程序因此全不可执行）。默认 0644，`--exec DST`
    或落在这几个目录（bin/ sbin/ usr/bin/ usr/sbin/ etc/init.d/ root/y1/）⇒ 0755。
"""
import argparse
import os
import stat
import sys

MAGIC = b"070701"
HDR = 110
EXEC_DIRS = ("bin/", "sbin/", "usr/bin/", "usr/sbin/", "etc/init.d/", "root/y1/")


def _mode_for(dst, exec_set):
    if dst in exec_set or dst.startswith(EXEC_DIRS):
        return 0o100755
    return 0o100644


def parse(raw):
    off = 0
    out = []
    while True:
        if raw[off:off + 6] != MAGIC:
            raise ValueError("bad magic at %d" % off)
        fields = [int(raw[off + 6 + 8 * i: off + 6 + 8 * (i + 1)], 16) for i in range(13)]
        (ino, mode, uid, gid, nlink, mtime, size, dmaj, dmin, rmaj, rmin, nsize, chk) = fields
        name = raw[off + HDR: off + HDR + nsize - 1].decode()
        p = off + HDR + nsize
        p = (p + 3) & ~3
        data = raw[p:p + size]
        p = (p + size + 3) & ~3
        out.append(dict(ino=ino, mode=mode, uid=uid, gid=gid, nlink=nlink, mtime=mtime,
                        dmaj=dmaj, dmin=dmin, rmaj=rmaj, rmin=rmin, name=name, data=data))
        off = p
        if name == "TRAILER!!!":
            break
    return out, off


def emit(entries):
    out = bytearray()
    for e in entries:
        name = e["name"].encode() + b"\0"
        fields = [e["ino"], e["mode"], e["uid"], e["gid"], e["nlink"], e["mtime"],
                  len(e["data"]), e["dmaj"], e["dmin"], e["rmaj"], e["rmin"], len(name), 0]
        out += MAGIC + b"".join(b"%08X" % f for f in fields)
        out += name
        while len(out) % 4:
            out += b"\0"
        out += e["data"]
        while len(out) % 4:
            out += b"\0"
    return bytes(out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--in", dest="src", required=True)
    ap.add_argument("--out", dest="dst", required=True)
    ap.add_argument("--add", action="append", default=[], metavar="SRC:DST")
    ap.add_argument("--exec", action="append", default=[], metavar="DST",
                    help="force mode 0755 for this dst (auto: bin/sbin/usr/bin/etc/init.d/root/y1)")
    a = ap.parse_args()
    exec_set = {d.lstrip("/") for d in a.exec}

    raw = open(a.src, "rb").read()
    entries, _ = parse(raw)
    trailer = entries[-1]
    body = entries[:-1]
    by_name = {e["name"]: i for i, e in enumerate(body)}

    next_ino = max([e["ino"] for e in entries if e["name"] != "TRAILER!!!"], default=0) + 1
    for spec in a.add:
        src, dst = spec.split(":", 1)
        dst = dst.lstrip("/")
        st = os.lstat(src)
        data = b""
        mode = _mode_for(dst, exec_set)
        links = 1
        if stat.S_ISLNK(st.st_mode):
            data = os.readlink(src).encode()
            mode = 0o120777
        else:
            data = open(src, "rb").read()
        e = dict(ino=next_ino, mode=mode & 0xFFFF, uid=0, gid=0, nlink=links, mtime=int(st.st_mtime),
                 dmaj=0, dmin=0, rmaj=0, rmin=0, data=data)
        if dst in by_name:
            old = body[by_name[dst]]
            e["ino"] = old["ino"]
            body[by_name[dst]] = dict(old, **e)
            print("replace %-48s %8d B  mode=%o" % (dst, len(data), mode & 0xFFFF))
        else:
            e["name"] = dst
            body.append(e)
            by_name[dst] = len(body) - 1
            next_ino += 1
            print("add     %-48s %8d B  mode=%o" % (dst, len(data), mode & 0xFFFF))
    open(a.dst, "wb").write(emit(body + [trailer]))
    print("wrote %s (%d entries, %d B)" % (a.dst, len(body) + 1, os.path.getsize(a.dst)))


main()
