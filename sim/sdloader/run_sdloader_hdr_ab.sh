#!/usr/bin/env bash
# =============================================================================
# run_sdloader_hdr_ab.sh —— SdLoader 双计划头（hdrSel）单元闸门
#
# 造一张小卡：
#   LBA 0            : Linux 计划（3 项：a/b/c 到 0x80000000/0x80400000/0x80F80000）
#   LBA 32768 (16MiB): CoreMark 计划（1 项：a.bin 到 0x81000000 —— 地址不同，串台必现）
# 然后跑同一装置两次：SD_HDR=0 装 Linux 计划、SD_HDR=1 装 CoreMark 计划；
# 两次都必须 TEST PASSED（逐字节对账以所选头部为准）。
# 退出码：0 全绿；1 判据不符；2 造卡/构建失败。
# =============================================================================
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
img="$root/sim/reglogs/sd_boot_small.img"
LBA=32768

echo "== 造双计划小卡 =="
python3 - "$root" "$img" "$LBA" <<'MAKE_PY' || { echo "FATAL: 造卡失败"; exit 2; }
import os, struct, sys, time
root, out, lba = sys.argv[1], sys.argv[2], int(sys.argv[3])
SECTOR = 512
td = os.path.join(root, 'sim', 'sdloader', 'testdata')

def plan(entries, card_lba):
    table, body, blk = [], bytearray(), card_lba + 1
    for addr, data in entries:
        nb = (len(data) + SECTOR - 1) // SECTOR
        table.append((addr, blk, nb))
        body += data + b'\x00' * (nb * SECTOR - len(data))
        blk += nb
    hdr = bytearray(SECTOR); hdr[:4] = b'YSLD'
    struct.pack_into('>I', hdr, 4, len(entries))
    for i, (addr, sb, nb) in enumerate(table):
        struct.pack_into('>III', hdr, 8 + 12 * i, addr, sb, nb)
    return bytes(hdr) + bytes(body)

def rd(n):
    return open(os.path.join(td, n), 'rb').read()

linux = plan([(0x80000000, rd('a.bin')), (0x80400000, rd('b.bin')),
              (0x80F80000, rd('c.bin'))], 0)
core = plan([(0x81000000, rd('a.bin'))], lba)
off = lba * SECTOR
assert len(linux) <= off
data = linux + b'\x00' * (off - len(linux)) + core
with open(out, 'wb') as f:
    f.write(data); f.flush(); os.fsync(f.fileno())
for _ in range(5):
    back = open(out, 'rb').read()
    if len(back) == len(data) and back[off:off+4] == b'YSLD':
        break
    time.sleep(0.2)
else:
    raise SystemExit('readback mismatch')
print('  card = %d B; Linux @0, CoreMark @%d' % (len(data), lba))
MAKE_PY

run_case() { # run_case <hdr> <tag> <no_build>
  local hdr="$1" tag="$2" nb="$3"
  ( cd "$root" && NO_BUILD="$nb" SD_IMG="../reglogs/sd_boot_small.img" SD_HDR="$hdr" \
      bash sim/sdloader/run_unit.sh 8000000 > "$root/sim/reglogs/sdloader_hdr_${tag}.log" 2>&1 )
  local rc=$?
  cp "$root/sim/reglogs/sdloader_unit.log" "$root/sim/reglogs/sdloader_hdr_${tag}_sim.log" 2>/dev/null || true
  grep -aE "hdrSel=|RELEASED|DDR\[|对账：|TEST (PASSED|FAILED)" "$root/sim/reglogs/sdloader_hdr_${tag}_sim.log" | tail -4 | sed 's/^/  /'
  return $rc
}

fails=0
echo "== hdrSel=0（Linux 计划）=="
run_case 0 linux 0 || fails=$((fails+1))
echo "== hdrSel=1（CoreMark 计划）=="
run_case 1 core 1 || fails=$((fails+1))

if [ "$fails" -eq 0 ]; then echo "RESULT: PASS"; exit 0; else echo "RESULT: FAIL（$fails 处）"; exit 1; fi
