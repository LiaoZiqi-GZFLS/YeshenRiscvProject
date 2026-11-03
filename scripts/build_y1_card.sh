#!/usr/bin/env bash
# =============================================================================
# build_y1_card.sh —— 生成带 Y1 第 5 槽 payload 的 TF 卡镜像（sd_y1.img）
#
# 第 5 槽：0x81E00000 = y1_payload.bin（NPU arena 尾部 no-map 区；SdLoader 上电直载）
# 其余四槽与既有装载链完全一致（fw_jump/Image/dtb/rootfs.cpio），顺序不变 ⇒ 旧偏移不受影响。
#
# 前置：
#   · y1run 已装进 rootfs overlay 并重建过 rootfs.cpio（root/y1/y1run 在 cpio 里）
#   · sw/images/{fw_jump.bin,Image,linux.dtb,rootfs.cpio} 已是最新
# 用法（Git Bash，Windows 侧）：
#   bash scripts/build_y1_card.sh
# 产物：sw/images/sd_y1.img（不覆盖既有 sd.img）
# =============================================================================
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IM="$ROOT/sw/images"
Y1="$ROOT/y1"
Y1_PY="${Y1_PY:-/d/code/PDS/NaxYeshenLinux/sim/reglogs/lxvenv/Scripts/python.exe}"
[ -x "$Y1_PY" ] || { echo "!! 缺 Y1_PY（带 numpy/onnx 的 Python）：$Y1_PY"; exit 2; }

for f in fw_jump.bin Image linux.dtb rootfs.cpio; do
  [ -s "$IM/$f" ] || { echo "!! 缺 $IM/$f"; exit 2; }
done

echo "== 1/3 生成 payload（no-face 夹具 + 逐字节黄金） =="
( cd "$Y1" && PYTHONPATH='./.pydeps;../third_party/yunet/deps' \
    "$Y1_PY" -u tools/build_board_payload.py --no-face \
    --golden-raw fixtures/s4c_noface_raw --out build/y1_payload.bin )
cp -f "$Y1/build/y1_payload.bin" "$IM/y1_payload.bin"

echo "== 2/3 校验 y1run 在 rootfs.cpio 里 =="
python - "$IM/rootfs.cpio" <<'PY'
import sys
b=open(sys.argv[1],'rb').read(); off=0; found=None
while off+110<=len(b) and b[off:off+6]==b'070701':
    def f(i): return int(b[off+i:off+i+8],16)
    ns=f(94); fs=f(54); name=b[off+110:off+110+ns-1].decode('latin1')
    if name=='root/y1/y1run': found=fs
    off=((off+110+ns+3)&~3); off=(off+fs+3)&~3
if found is None: raise SystemExit('!! rootfs.cpio 里没有 root/y1/y1run（先重建 rootfs）')
print('   root/y1/y1run = %d B OK' % found)
PY

echo "== 3/3 生成 sd_y1.img（5 槽） =="
python "$ROOT/sim/mk_sd_image.py" --out "$IM/sd_y1.img" \
  --entry 0x80000000="$IM/fw_jump.bin" \
  --entry 0x82000000="$IM/Image" \
  --entry 0x82F80000="$IM/linux.dtb" \
  --entry 0x83000000="$IM/rootfs.cpio" \
  --entry 0x81E00000="$IM/y1_payload.bin"

echo "== 逐段回读校验（块 0 表 + 每段字节） =="
python - "$IM" <<'PY'
import hashlib, os, struct, sys
d=sys.argv[1]; img=open(os.path.join(d,'sd_y1.img'),'rb').read()
assert img[:4]==b'YSLD'
n=struct.unpack('>I',img[4:8])[0]
src={0x80000000:'fw_jump.bin',0x82000000:'Image',0x82F80000:'linux.dtb',
     0x83000000:'rootfs.cpio',0x81E00000:'y1_payload.bin'}
for i in range(n):
    addr,sb,nb=struct.unpack('>III',img[8+12*i:8+12*i+12])
    seg=img[sb*512:(sb+nb)*512]
    cur=open(os.path.join(d,src[addr]),'rb').read()
    assert seg[:len(cur)]==cur, 'segment mismatch @0x%08X'%addr
    print('  0x%08X  blk %5d..%-5d  %8d B  md5=%s' % (addr,sb,sb+nb-1,len(cur),
          hashlib.md5(cur).hexdigest()))
print('sd_y1.img: %d B  md5=%s' % (len(img), hashlib.md5(img).hexdigest()))
PY
echo DONE
