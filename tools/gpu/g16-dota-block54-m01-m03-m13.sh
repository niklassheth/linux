#!/bin/bash
# Block 54 (claude-kernel's split, after block 53): under the load repro (Steam offline + synthetic load + 50M cap, #76),
#   M01L: diag_mask=0x01 (lane table + stale counting only)   M03L: 0x03 (+ stale classification)
#   M13L: 0x13 (0x03 + wedge detector's 250 ms mutex-holding sampling)
# x4 each, interleaved. M01L ~0 -> the lane-table work on the submit path (delay before publish_render) suppresses A4;
# M13L stalling -> the wedge sampler cancels it (explains RL 0x3f stalling).
set -uo pipefail
cd /home/nsheth/Projects/asahi
R=artifacts/dota-compute-stall-20261007/ro-session/ro-session.sh
BEH="asahi_m4.context_sticky=0 asahi_m4.lifecycle=0 asahi_m4.cc_pattern=0 asahi_m4.ta_sel6=0"
K76=artifacts/m4-linux/bits-7.3-76-diagmask; U76="#76 SMP PREEMPT_DYNAMIC Thu Oct  8 19:29:01 EDT 2026"
r() { env G16_KEEP_LEASE=1 G16_STEAM_OFFLINE=1 G16_SYNTH_LOAD=1 G16_IO_THROTTLE=50M G16_TAG=$1 G16_KERNEL_ARTIFACT=$K76 "G16_EXPECT_UTS=$U76" G16_BASE_ARGS=asahi_m4.dependency_kind=0 "G16_BOOT_EXTRA=$2" G16_TESTS=dota-quar0 G16_OVERLAY_BASE=/mnt/g16-external/codex-dota-overlay/$1 $R; }
stalls() { local c=0; for d in artifacts/dota-compute-stall-20261007/ro-session/$1-*; do grep -qs "STALL in" $d/codex-dota-*/verdicts.txt && c=$((c+1)); done; echo $c; }
for n in 1 2 3 4; do
    r k54-m01l-$n "$BEH asahi_m4.diag_mask=0x01"
    r k54-m03l-$n "$BEH asahi_m4.diag_mask=0x03"
    r k54-m13l-$n "$BEH asahi_m4.diag_mask=0x13"
    echo "round $n: m01l=$(stalls k54-m01l) m03l=$(stalls k54-m03l) m13l=$(stalls k54-m13l)"
done
echo "block 54 done at $(date -Is)"
