#!/usr/bin/env bash
# =============================================================================
# build_boot_card.sh —— 双计划 TF 卡镜像（Linux 默认 + CoreMark 裸核）
#
# 布局（与 docs/superpowers/specs/2026-10-18-y1-boot-plan-select-design.md 一致）：
#   LBA 0            : Linux 计划头（= sd_y1.img 原样，5 项）
#   LBA 1..          : Linux 数据（不变）
#   LBA 32768 (16MiB): CoreMark 计划头（1 项：0x80000000=coremark_rv32_i10.bin）
#   LBA 32769..      : CoreMark 数据
#
# 前置：sw/images/sd_y1.img + CoreMark bin
# 用法：bash scripts/build_boot_card.sh
#   CORE_BIN=.../coremark_rv32_i4100.bin OUT=.../sd_boot_score.img bash scripts/build_boot_card.sh
# 产物：sw/images/sd_boot.img（默认 CoreMark = ITERS=10 CRC 档）
# =============================================================================
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IM="$ROOT/sw/images"
LBA=32768
CORE_BIN="${CORE_BIN:-$IM/coremark_rv32_i10.bin}"
OUT="${OUT:-$IM/sd_boot.img}"
[ -s "$IM/sd_y1.img" ] || { echo "!! 缺 $IM/sd_y1.img"; exit 2; }
[ -s "$CORE_BIN" ] || { echo "!! 缺 $CORE_BIN（先构建 sw/coremark-rv32）"; exit 2; }

# 全部在一个 Python 进程里：拼好、验完、落盘、再读回验。
# （本机实测：写完文件后**下一个进程**偶尔会读到旧的/截断的内容 ⇒ 不跨进程交接中间文件。）
python - "$IM" "$LBA" "$CORE_BIN" "$OUT" <<'PY'
import hashlib, os, struct, sys, time
im, lba, core_bin_path, out_path = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
SECTOR = 512
sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(im))), 'sim'))
from mk_sd_image import build_plan, crc32, ENT_CRC_OFF, HDR_CRC_OFF, HDR_CRC_LEN

linux = open(os.path.join(im, 'sd_y1.img'), 'rb').read()
core_bin = open(core_bin_path, 'rb').read()
core_plan, _core_tab = build_plan([(0x80000000, core_bin)], lba)

# 两级 CRC 必须随镜像一起落到卡上（装载器会当场校验；内核/厂商段已在 sd_y1.img 里）
assert crc32(core_plan[:HDR_CRC_LEN]) == struct.unpack('>I', core_plan[HDR_CRC_OFF:HDR_CRC_OFF + 4])[0], \
    'CoreMark plan header CRC self-check failed'
_sb, _nb = _core_tab[0][1], _core_tab[0][2]
_o = (_sb - lba - 1) * SECTOR          # core_plan 的块 0 是表头 ⇒ 数据从输出偏移 512 起
assert crc32(core_plan[_o:_o + _nb * SECTOR]) == \
    struct.unpack('>I', core_plan[ENT_CRC_OFF:ENT_CRC_OFF + 4])[0], 'CoreMark plan segment CRC self-check failed'
assert crc32(linux[:HDR_CRC_LEN]) == struct.unpack('>I', linux[HDR_CRC_OFF:HDR_CRC_OFF + 4])[0], \
    'Linux plan header CRC missing (rebuild sd_y1.img with the current mk_sd_image.py)'

off = lba * SECTOR
assert len(linux) <= off, 'Linux plan %d B > %d B offset' % (len(linux), off)
img = linux + b'\x00' * (off - len(linux)) + core_plan

def hdr(block):
    o = block * SECTOR
    assert img[o:o+4] == b'YSLD', 'bad magic @ LBA %d' % block
    n = struct.unpack('>I', img[o+4:o+8])[0]
    assert 1 <= n <= 8, 'bad entry count %d @ LBA %d' % (n, block)
    return [struct.unpack('>III', img[o+8+12*i:o+20+12*i]) for i in range(n)]

lin, core = hdr(0), hdr(lba)
assert len(lin) == 5 and len(core) == 1, 'unexpected plan sizes'
assert img[:len(linux)] == linux, 'Linux plan bytes changed'
assert img[len(linux):off] == b'\x00' * (off - len(linux)), 'padding not zero'
for (a, sb, nb) in core:
    seg = img[sb*SECTOR:(sb+nb)*SECTOR]
    assert len(seg) == nb*SECTOR, 'CoreMark segment out of range'
    assert seg[:len(core_bin)] == core_bin, 'CoreMark segment mismatch'
    assert seg[len(core_bin):] == b'\x00' * (len(seg)-len(core_bin)), 'CoreMark padding not zero'
    print('  CoreMark: addr=%#010x  blk %d..%d  %d B  md5=%s' %
          (a, sb, sb+nb-1, len(core_bin), hashlib.md5(core_bin).hexdigest()))

out = out_path
with open(out, 'wb') as f:
    f.write(img); f.flush(); os.fsync(f.fileno())

for _ in range(5):
    back = open(out, 'rb').read()
    if len(back) == len(img) and back[off:off+4] == b'YSLD':
        break
    time.sleep(0.2)
else:
    raise SystemExit('written image readback mismatch after retries')
assert back == img, 'written image differs from built image'
print('  %s = %d B (%d blocks), md5=%s' %
      (os.path.basename(out), len(back), (len(back)+SECTOR-1)//SECTOR, hashlib.md5(back).hexdigest()))
print('  Linux: %d entries, %d B; CoreMark @ LBA %d' % (len(lin), len(linux), lba))
print('  PASS')
PY
