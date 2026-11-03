#!/usr/bin/env python3
"""mk_sd_gui.py -- build the YeshenGui TF-card image consumed by SdLoader.

Copy of VexiiYeshenLinux/sim/mk_sd_image.py (kept byte-for-byte apart from this
header and the reference-output guard below); the table format and CRC logic are
unchanged. The guard refuses any --out under VexiiYeshenLinux, so a GUI build can
never overwrite the read-only reference's images.

Layout (from src/peripheral/SdLoader.scala file header; SdSpi hands out one 32-bit word
with byte 0 in the MSB, so every field on the card is BIG-ENDIAN):
  block 0 (512 B):
    off 0      : 'Y','S','L','D'          (magic)
    off 4      : u32 entry count (1..8)
    off 8+12*i : u32 target DDR byte address (MUST be 32B aligned)
                 u32 start block (absolute LBA)
                 u32 block count
    off 128+4*i: u32 CRC32 of entry i's **padded** payload (blocks*512 bytes), zlib flavor
    off 160    : u32 CRC32 of block-0 bytes 0..159 (guards the table itself: a flipped
                 target address would pass every payload CRC yet boot from the wrong place)
  blocks 1..  : the images, in the order given, each zero-padded up to a 512 B boundary.

The loader verifies both levels in hardware while streaming (no extra reads); a mismatch
stops the CPU from being released with errCode 7 (header) / 8 (segment).

Usage:
  python mk_sd_gui.py --out images/sd_gui.img \
      --entry 0x80000000=images/fw_jump.bin \
      --entry 0x82000000=images/Image \
      --entry 0x82F80000=images/linux_gui.dtb \
      --entry 0x83000000=images/rootfs_gui.cpio.gz

Then write the .img to a card at LBA 0 (raw, not a filesystem).
"""
import argparse
import os
import struct
import zlib

SECTOR = 512
MAGIC = b"YSLD"
ENT_CRC_OFF = 128        # 8 x u32, one per entry
HDR_CRC_OFF = 160        # u32 over block-0 bytes 0..159
HDR_CRC_LEN = HDR_CRC_OFF

REFERENCE_NAME = "VexiiYeshenLinux"


def guard_output(path):
    """Refuse to write anywhere inside the read-only reference checkout.

    Checked on both the literal absolute path and its real path so a relative
    path or a symlinked output directory cannot slip past the string test.
    """
    for candidate in (os.path.abspath(path), os.path.realpath(path)):
        parts = os.path.normpath(candidate).replace("\\", "/").split("/")
        if REFERENCE_NAME in parts:
            raise SystemExit(
                f"refusing to overwrite VexiiYeshenLinux images: {candidate}")


def crc32(data):
    """Same flavor as the RTL engine: reflected 0xEDB88320, init/final 0xFFFFFFFF."""
    return zlib.crc32(data) & 0xFFFFFFFF


def build_plan(entries, card_lba=0):
    """entries: [(ddr_addr, bytes)] -> (image_bytes, table).

    `card_lba` = absolute LBA where block 0 of this plan lives (0 for the Linux plan,
    32768 for the CoreMark plan); start blocks in the table are absolute.
    """
    table = []
    body = bytearray()
    blk = card_lba + 1                      # block 0 holds the table
    segs = []
    for addr, data in entries:
        nblk = (len(data) + SECTOR - 1) // SECTOR
        seg = data + b"\x00" * (nblk * SECTOR - len(data))
        table.append((addr, blk, nblk))
        segs.append(seg)
        body += seg
        blk += nblk

    hdr = bytearray(SECTOR)
    hdr[0:4] = MAGIC
    struct.pack_into(">I", hdr, 4, len(entries))
    for i, (addr, sb, nb) in enumerate(table):
        struct.pack_into(">III", hdr, 8 + 12 * i, addr, sb, nb)
        struct.pack_into(">I", hdr, ENT_CRC_OFF + 4 * i, crc32(segs[i]))
    struct.pack_into(">I", hdr, HDR_CRC_OFF, crc32(bytes(hdr[:HDR_CRC_LEN])))
    return bytes(hdr) + bytes(body), table


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--card-lba", type=int, default=0,
                    help="plan placed at this absolute card LBA (start blocks in the header become N+1..); header itself stays at block 0 of the output")
    ap.add_argument("--entry", action="append", default=[], metavar="ADDR=FILE")
    a = ap.parse_args()
    guard_output(a.out)
    if not (1 <= len(a.entry) <= 8):
        raise SystemExit(f"need 1..8 entries, got {len(a.entry)}")

    ents = []
    for e in a.entry:
        addr_s, path = e.split("=", 1)
        addr = int(addr_s, 0)
        if addr & 0x1F:
            raise SystemExit(f"addr {addr:#x} is not 32B aligned")
        with open(path, "rb") as f:
            data = f.read()
        if not data:
            raise SystemExit(f"{path} is empty")
        ents.append((addr, path, data))

    img, table = build_plan([(addr, data) for addr, _, data in ents], a.card_lba)
    with open(a.out, "wb") as f:
        f.write(img)

    # self-check: re-read what landed on disk and verify both CRC levels the hardware will check
    back = open(a.out, "rb").read()
    assert back == img, f"{a.out}: readback differs"
    pl = a.card_lba * SECTOR
    assert crc32(back[pl:pl + HDR_CRC_LEN]) == struct.unpack(">I", back[pl + HDR_CRC_OFF:pl + HDR_CRC_OFF + 4])[0], "header CRC mismatch"
    for i, (_, sb, nb) in enumerate(table):
        # 本文件只含这一个 plan（表头在自己偏移 0）⇒ 段在文件里的偏移要减掉 card_lba
        o = sb * SECTOR - pl
        seg = back[o:o + nb * SECTOR]
        want = struct.unpack(">I", back[pl + ENT_CRC_OFF + 4 * i:pl + ENT_CRC_OFF + 4 * i + 4])[0]
        assert len(seg) == nb * SECTOR and crc32(seg) == want, f"entry {i} CRC mismatch"

    print(f"wrote {a.out}: {len(img)} B ({len(img) // SECTOR} blocks)")
    for i, ((addr, path, data), (_, sb, nb)) in enumerate(zip(ents, table)):
        print(f"  {path}: {len(data):8d} B -> {addr:#010X}  blk {sb}..{sb + nb - 1} ({nb} blk)"
              f"  crc32={crc32(back[sb * SECTOR - pl:(sb + nb) * SECTOR - pl]):08X}")
    print(f"  header crc32={struct.unpack('>I', back[pl + HDR_CRC_OFF:pl + HDR_CRC_OFF + 4])[0]:08X}")


if __name__ == "__main__":
    main()
