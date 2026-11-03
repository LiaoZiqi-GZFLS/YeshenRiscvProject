#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""push_gui_assets.py -- 把 YeshenGui 的 /root/gui/assets 推到板上（临时修复，不改 rootfs）。

板上 rootfs 是 initramfs，重启会丢；持久修复是把它塞进
sw/buildroot-external/.../rootfs_overlay/root/gui/assets（见同一提交）。
"""
import io
import os
import sys
import tarfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "scripts"))
import board_ssh  # noqa: E402

SRC = os.path.abspath(os.path.join(ROOT, "..", "YeshenGui", "board",
                                   "rootfs_overlay", "root", "gui", "assets"))

buf = io.BytesIO()
with tarfile.open(fileobj=buf, mode="w:gz") as tf:
    tf.add(SRC, arcname="assets")
data = buf.getvalue()
print("tar.gz %d B from %s" % (len(data), SRC))

rc, out = board_ssh.put_bytes("/tmp/gui_assets.tgz", data)
print("put rc=%s %s" % (rc, out.strip()[:120]))

rc, out, err = board_ssh.run("cd /root/gui && tar xzf /tmp/gui_assets.tgz && ls -l assets | head -5; "
                             "md5sum assets/*.bin", timeout=120)
print(out.decode("utf-8", "replace"))
if rc != 0:
    print("ERR:", err[:200])
    sys.exit(1)
