#!/usr/bin/env bash
# run_eth_service_gates.sh -- unit gate G2 for board/eth/eth_service.v
#
# Models: LiteEth slot port (csr/rx/tx on one WB slave, 32-bit word addressed,
# ack one cycle later), MAC slot CSRs (WRITER_SLOT/LENGTH/EV_PENDING w1c,
# READER_READY/SLOT/LENGTH/START), and the DmaEngine job port (a proper
# ready/valid source whose byte value is a known pattern of the address).
#
# The DMA model inserts 400-cycle gaps between beats (> the 255-cycle mid-frame
# timeout the first board build had), so a regression to timer-based end-of-frame
# detection is caught here instead of on the board.
#
# Positive judges
#   [1] 300 B read at 0x9000_0007 (UNALIGNED): 1 frame of 358 B, header
#       off=0/len=300/last=1, payload byte-exact, DMA job issued as
#       (0x10000000, 320)  -- head skip + tail rounding.
#   [2] 2000 B read at 0x9000_0000: 2 frames (1458 + 658), off 0/1400,
#       len 1400/600, last 0/1, both payloads byte-exact -- slot rotation.
#   [3] returns to idle; n_req counts both requests.
#
# Mutation controls (each must turn the gate RED for the intended reason)
#   m1_skip    head-alignment skip forced to 0    -> payload mismatch
#   m2_slot    slot base uses <<7 instead of <<9  -> frame 2 empty/mismatch
#   m3_poll    ignore WRITER_EV_PENDING           -> re-processes the same frame
#   m4_widx    no per-frame tx word reset         -> frame 2 misplaced
#   (tx-slot aliasing is NOT a mutation: the MAC decodes slots by address bit9 and
#    the reader uses slot[0], so rotating mod 4 aliases consistently -- the bench
#    models exactly that, which is why a mod-4 rotation cannot be turned red.)
#   m5_nobusy  no end-of-request check (leaves when tx_valid drops for one cycle)
#              -> frame abandoned mid-way (this is exactly the board failure of
#                 2026-10-28: a 255-cycle mid-frame timeout + >2.55 us DDR gaps)
#
# Exit codes: 0 all green; 1 red; 2 infrastructure.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
SVC=$ROOT/board/eth/eth_service.v
CORE=$ROOT/board/eth/eth_memread.v
TB=$HERE/tb_eth_service.v
OUT=${OUT:-/tmp/eth_svc_gates}
IVERILOG=${IVERILOG:-iverilog}
VVP=${VVP:-vvp}
PERL=${PERL:-perl}

mkdir -p "$OUT" || exit 2
for f in "$SVC" "$CORE" "$TB"; do [ -f "$f" ] || { echo "MISSING $f"; exit 2; }; done
command -v "$IVERILOG" >/dev/null 2>&1 || { echo "MISSING $IVERILOG"; exit 2; }

RED=0
say() { printf '%s\n' "$*"; }

build_and_run() {   # $1=tag $2=service-file
    local tag=$1 svc=$2
    "$IVERILOG" -g2012 -o "$OUT/$tag.vvp" "$TB" "$svc" "$CORE" >"$OUT/$tag.build.log" 2>&1 || {
        say "[$tag] BUILD FAIL"; sed -n '1,12p' "$OUT/$tag.build.log"; return 1; }
    "$VVP" -n "$OUT/$tag.vvp" >"$OUT/$tag.log" 2>&1
}

say "=== [1..3] positive: $SVC ==="
if ! build_and_run pos "$SVC"; then exit 1; fi
if grep -q '^RESULT: PASS' "$OUT/pos.log" && ! grep -q 'TBFAIL' "$OUT/pos.log"; then
    say "PASS  positive (358 B unaligned + 1458/658 B split, payloads byte-exact)"
    grep '^FRM#' "$OUT/pos.log" | sed 's/^/      /'
else
    say "FAIL  positive"; grep -m 10 'TBFAIL' "$OUT/pos.log"; RED=1
fi
md5sum "$SVC" | awk '{print "      svc md5 " $1}'

mutate() {  # $1=tag $2=old $3=new $4=required-pattern $5=desc
    local tag=$1 old=$2 new=$3 want=$4 desc=$5
    local m=$OUT/$tag.v
    cp "$SVC" "$m"
    if ! "$PERL" -0pe "s/\Q$old\E/$new/" "$m" > "$m.tmp"; then
        say "FAIL  $tag: perl substitution failed ($desc)"; rm -f "$m.tmp"; RED=1; return 1
    fi
    mv "$m.tmp" "$m"
    if cmp -s "$SVC" "$m"; then
        say "FAIL  $tag: mutation did not change the source ($desc)"; RED=1; return 1
    fi
    if ! build_and_run "$tag" "$m"; then
        say "FAIL  $tag: build broke under mutation ($desc)"; RED=1; return 1
    fi
    if grep -q '^RESULT: PASS' "$OUT/$tag.log"; then
        say "FAIL  $tag: gate stayed GREEN under mutation ($desc)"; RED=1; return 1
    fi
    if grep -q "$want" "$OUT/$tag.log"; then
        say "PASS  $tag: RED for the intended reason ($desc)"
    else
        say "FAIL  $tag: RED but not for the intended reason; want: $want"; RED=1
        grep -m 5 'TBFAIL' "$OUT/$tag.log"
    fi
}

say ""
say "=== [4] mutation controls (each must fire) ==="
mutate m1_skip \
    "d_skip    <= (j_addr_r - DDR_BASE) & 32'd31;" \
    "d_skip    <= 5'd0;" \
    "payload" \
    "head-alignment skip forced to 0"

mutate m2_slot \
    "wire [29:0] tx_adr_m = {19'd0, tx_slot, 9'd0} + {17'd0, tx_widx};" \
    "wire [29:0] tx_adr_m = {19'd0, tx_slot, 7'd0} + {17'd0, tx_widx};" \
    "payload" \
    "tx slot base shifted by 7 instead of 9"

mutate m3_poll \
    "if (wb_dn) st <= wb_rd[0] ? R_SLOT : S_IDLE;" \
    "if (wb_dn) st <= R_SLOT;" \
    "TBFAIL" \
    "ignores WRITER_EV_PENDING (re-processes the same frame)"

mutate m4_widx \
    "tx_bytes <= 12'd0;
                    tx_widx  <= 13'd0;" \
    "tx_bytes <= 12'd0;
                    tx_widx  <= tx_widx;" \
    "payload" \
    "no per-frame tx word reset"

mutate m5_nobusy     "end else if (!tx_valid && !core_busy) begin"     "end else if (!tx_valid) begin"     "payload"     "leaves the frame as soon as tx_valid is low (no end-of-request check)"

say ""
if [ "$RED" -eq 0 ]; then
    say "RESULT: ALL PASS (positive + 5 firing mutation controls)"
    exit 0
else
    say "RESULT: FAIL"
    exit 1
fi
