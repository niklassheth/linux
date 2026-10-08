#!/bin/bash
# Block 44: #62 (claude-kernel recovery build A, c31a7b9) wedge detection + wedge_recover=1, flush_each=0, Dota default
# mode, quar0 trace build, A4-prone settings, recent ring. Up to 6 runs; stops at the first run that logs an A4 wedge
# (recovered or not) or stalls, or at a failed boot (first run doubles as #62's boot test).
set -uo pipefail
cd /home/nsheth/Projects/asahi
while [ -n "${WAIT_PID:-}" ] && kill -0 "$WAIT_PID" 2>/dev/null; do sleep 30; done
sleep 75 # yield: claude-kernel polls the lease every 30 s for its serial-boot slot
R=artifacts/dota-compute-stall-20261007/ro-session/ro-session.sh
X="asahi_m4.dep_stats=1 asahi_m4.context_sticky=0 asahi_m4.lifecycle=0 asahi_m4.cc_pattern=0 asahi_m4.dump_render_buffered=16 asahi_m4.dump_render_reg=0x15211 asahi_m4.dump_render_value=0x2d000000500 asahi_m4.dump_render_recent=48 asahi_m4.flush_each=0 asahi_m4.wedge_recover=1"
last() { ls -td artifacts/dota-compute-stall-20261007/ro-session/$1-* | head -1; }
for n in 1 2 3 4 5 6; do
    tag=k62-wr1-$n
    env G16_KEEP_LEASE=1 G16_TAG=$tag G16_KERNEL_ARTIFACT=artifacts/m4-linux/bits-7.3-62-wedge "G16_EXPECT_UTS=#62 SMP PREEMPT_DYNAMIC Thu Oct  8 15:22:19 EDT 2026" G16_BASE_ARGS=asahi_m4.dependency_kind=0 "G16_BOOT_EXTRA=$X" G16_TESTS=dota-quar0 G16_OVERLAY_BASE=/mnt/g16-external/codex-dota-overlay/$tag $R
    d=$(last $tag)
    [ -s "$d/loaded-kernel.txt" ] || { echo "#62 failed to boot in $tag; stopping"; break; }
    grep -qs "A4 wedge" "$d"/codex-dota-*/kernel.log && { echo "wedge logged in $tag; stopping"; break; }
    grep -qs "STALL in" "$d"/codex-dota-*/verdicts.txt && { echo "stall in $tag; stopping"; break; }
done
echo "block 44 done at $(date -Is)"
