#!/usr/bin/env bash
#=============================================================================
# run_eth_gates.sh -- H2-S1 unit gate (G1) for board/eth/eth_memread.v
#
# Judges
#   [0] build: iverilog compiles the DUT + TB (SV-2012).
#   [1] positive: RESULT: PASS and zero TBFAIL lines.
#       Covers: ARP reply (42 B, oper/sha/spa/tha/tpa), UDP read 3000 B -> exactly 3 frames
#       (off 0/1400/2800, len 1400/1400/200, last 0/0/1), IPv4 fields + header checksum
#       recomputed independently in the TB, payload byte-exact, done_seq.
#   [2] negative controls (in-TB): bad magic / len=0 / below-base / past-window
#       => no reply frame and err_cnt increments exactly once each.
#   [3] mutation controls (each must turn the gate RED, and the *intended* judge must be
#       the one that fires -- an unrelated break does NOT count):
#         M1 last-flag dropped        -> "last flag not set" must appear
#         M2 magic check removed      -> "NEG magic: replied anyway" must appear
#         M3 idle pay_rd guard removed-> "UDP payload byte" must appear (stream shifted)
#         M4 reply dport forced to MY_PORT -> "dport is not requester port 5000" must appear
#
# Exit codes: 0 all green; 1 red (positive or a mutation did not fire); 2 infrastructure.
# All output is ASCII (a GBK console mangles UTF-8).
#=============================================================================
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
RTL=$ROOT/board/eth/eth_memread.v
TB=$HERE/tb_eth_memread.v
OUT=${OUT:-/tmp/eth_gates}

IVERILOG=${IVERILOG:-iverilog}
VVP=${VVP:-vvp}
PERL=${PERL:-perl}

mkdir -p "$OUT" || exit 2
[ -f "$RTL" ] || { echo "MISSING $RTL"; exit 2; }
[ -f "$TB" ]  || { echo "MISSING $TB";  exit 2; }
command -v "$IVERILOG" >/dev/null 2>&1 || { echo "MISSING $IVERILOG"; exit 2; }

RED=0
say() { printf '%s\n' "$*"; }

build_and_run() {   # $1=tag  $2=rtl-file -> echoes log path
    local tag=$1 rtl=$2
    "$IVERILOG" -g2012 -o "$OUT/$tag.vvp" "$TB" "$rtl" >"$OUT/$tag.build.log" 2>&1 || {
        say "[$tag] BUILD FAIL"; sed -n '1,12p' "$OUT/$tag.build.log"; return 1; }
    "$VVP" -n "$OUT/$tag.vvp" >"$OUT/$tag.log" 2>&1
}

#-----------------------------------------------------------------------------
# [1] positive
#-----------------------------------------------------------------------------
say "=== [1] positive: $RTL ==="
if ! build_and_run pos "$RTL"; then exit 1; fi
if grep -q '^RESULT: PASS' "$OUT/pos.log" && ! grep -q 'TBFAIL' "$OUT/pos.log"; then
    say "PASS  positive (4 frames: 42 + 1458 + 1458 + 258, payload byte-exact)"
else
    say "FAIL  positive"; grep -m 12 'TBFAIL' "$OUT/pos.log"; RED=1
fi
md5sum "$RTL" | awk '{print "      rtl md5 " $1}'

#-----------------------------------------------------------------------------
# [3] mutation controls
#-----------------------------------------------------------------------------
mutate() {  # $1=tag $2=literal-old $3=literal-new $4=required-pattern $5=desc
    local tag=$1 old=$2 new=$3 want=$4 desc=$5
    local mrtl=$OUT/$tag.v
    cp "$RTL" "$mrtl"
    "$PERL" -0pe "s/\Q$old\E/$new/" "$mrtl" > "$mrtl.tmp" || return 2
    mv "$mrtl.tmp" "$mrtl"
    if cmp -s "$RTL" "$mrtl"; then
        say "FAIL  $tag: mutation did not change the source ($desc)"; RED=1; return 1
    fi
    if ! build_and_run "$tag" "$mrtl"; then
        say "FAIL  $tag: build broke under mutation ($desc)"; RED=1; return 1
    fi
    if grep -q '^RESULT: PASS' "$OUT/$tag.log"; then
        say "FAIL  $tag: gate stayed GREEN under mutation ($desc) -- judge is not load-bearing"; RED=1
        return 1
    fi
    if grep -q "$want" "$OUT/$tag.log"; then
        say "PASS  $tag: RED for the intended reason ($desc)"
    else
        say "FAIL  $tag: RED but not for the intended reason; expected pattern: $want"; RED=1
        grep -m 6 'TBFAIL' "$OUT/$tag.log"
    fi
}

say ""
say "=== [3] mutation controls (each must fire) ==="
mutate m1_last \
    "16'd57:by=is_last ? 8'h01 : 8'h00;" \
    "16'd57:by=8'h00;" \
    "last flag not set" \
    "reply never sets the last flag"

mutate m2_magic \
    "if (rx_magic == MAGIC && rx_len_ok && rx_rng_ok) begin" \
    "if (rx_len_ok && rx_rng_ok) begin" \
    "NEG magic: replied anyway" \
    "accepts any magic"

mutate m3_idlepay \
    "wire pay_phase = (kind == 1'b0) && (idx != 16'd0) && (bidx >= HDR_BYTES);" \
    "wire pay_phase = (kind == 1'b0) && (bidx >= HDR_BYTES);" \
    "IDLE: pay_rd asserted" \
    "pay_rd fires while idle (stream silently consumed)"

mutate m4_dport \
    "16'd36:by=s_port[15:8];  16'd37:by=s_port[7:0];" \
    "16'd36:by=MY_PORT[15:8]; 16'd37:by=MY_PORT[7:0];" \
    "dport is not requester port 5000" \
    "reply dport echoes MY_PORT instead of the requester"

# M5：撤掉"只有被接收才撤 valid"的门控（回到逐拍硬清）⇒ 在 tx_ready 有空拍时必丢字节
mutate m5_txhold     "            if (tx_ready) begin
                tx_valid <= 1'b0;
                tx_sop   <= 1'b0;
                tx_eop   <= 1'b0;
            end"     "            tx_valid <= 1'b0; tx_sop <= 1'b0; tx_eop <= 1'b0;"     "UDP payload byte"     "clears tx_valid/sop/eop every cycle instead of on accept"

say ""
if [ "$RED" -eq 0 ]; then
    say "RESULT: ALL PASS (positive + 4 firing mutation controls)"
    exit 0
else
    say "RESULT: FAIL"
    exit 1
fi
