# -*- coding: utf-8 -*-
"""mk_score_card_v2.py -- 参数化版跑分卡拼装：plan0 取自指定基底镜像前 16 MiB，
plan1(LBA 32768) = 指定 CoreMark bin。不覆盖台账里的 sd_score_ctp.img。

用法: python -u sim/reglogs/mk_score_card_v2.py <coremark.bin> <base.img> <out.img>
"""
import hashlib
import os
import struct
import sys

HERE = os.path.abspath(os.path.dirname(__file__))
IM = os.path.abspath(os.path.join(HERE, '..', '..', 'sw', 'images'))
sys.path.insert(0, os.path.abspath(os.path.join(HERE, '..')))
from mk_sd_image import build_plan, crc32, ENT_CRC_OFF, HDR_CRC_OFF, HDR_CRC_LEN

SECTOR = 512
PLAN1_LBA = 32768

core_path, base_path, out_path = sys.argv[1], sys.argv[2], sys.argv[3]
base = open(base_path, 'rb').read()
need = PLAN1_LBA * SECTOR
if len(base) < need:
    # 基底镜像不足 16 MiB：plan0 各段都落在实际数据内，补零到 16 MiB 只是死区
    base = base + b'\x00' * (need - len(base))
linux = base[:need]
core = open(core_path, 'rb').read()

assert linux[:4] == b'YSLD', 'base plan0 magic'
n = struct.unpack('>I', linux[4:8])[0]
assert crc32(linux[:HDR_CRC_LEN]) == struct.unpack('>I', linux[HDR_CRC_OFF:HDR_CRC_OFF + 4])[0], 'linux hdr crc'

core_plan, tab = build_plan([(0x80000000, core)], PLAN1_LBA)
addr, sb, nb = tab[0]
assert addr == 0x80000000 and sb == PLAN1_LBA + 1 or sb >= PLAN1_LBA, tab
assert crc32(core_plan[:HDR_CRC_LEN]) == struct.unpack('>I', core_plan[HDR_CRC_OFF:HDR_CRC_OFF + 4])[0], 'core hdr crc'
pad = core + b'\x00' * (nb * SECTOR - len(core))
assert crc32(pad) == struct.unpack('>I', core_plan[ENT_CRC_OFF:ENT_CRC_OFF + 4])[0], 'core seg crc'

img = linux + core_plan
open(out_path, 'wb').write(img)
assert open(out_path, 'rb').read() == img, 'readback mismatch'


def md5(p):
    return hashlib.md5(open(p, 'rb').read()).hexdigest()


print("core bin : %s  %d B  md5 %s" % (core_path, len(core), md5(core_path)))
print("base img : %s  %d B  md5 %s  plan0 entries=%d" % (base_path, len(base), md5(base_path), n))
print("out  img : %s  %d B  md5 %s" % (out_path, len(img), md5(out_path)))
print("plan1    : 1 entry @0x80000000, start block %d, %d blocks, seg crc ok" % (sb, nb))
