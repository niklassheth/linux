#!/bin/bash
# Block 49 (manager): Dota-free repros on #63 (last tree with confirmed A4), since the earlier negatives ran on #64
# (the A4-suppressing tree). Session 1: burst synthetics (rp-1burst rp-sburst rp-m1burst rp-msburst); session 2: gfxr
# replay exposure loop (replay-loop native x12, replay-loop-x86 x8). A4-prone args + recent ring. Stops at a stall.
set -uo pipefail
cd /home/nsheth/Projects/asahi
while [ -n "${WAIT_PID:-}" ] && kill -0 "$WAIT_PID" 2>/dev/null; do sleep 30; done
R=artifacts/dota-compute-stall-20261007/ro-session/ro-session.sh
X="asahi_m4.dep_stats=1 asahi_m4.context_sticky=0 asahi_m4.lifecycle=0 asahi_m4.cc_pattern=0 asahi_m4.dump_render_buffered=16 asahi_m4.dump_render_reg=0x15211 asahi_m4.dump_render_value=0x2d000000500 asahi_m4.dump_render_recent=48"
for s in 1 2; do
    if [ $s = 1 ]; then tag=k63-burst-1; tests="rp-1burst rp-sburst rp-m1burst rp-msburst"; else tag=k63-rloop-1; tests="replay-loop replay-loop-x86"; fi
    env G16_KEEP_LEASE=1 G16_TAG=$tag G16_KERNEL_ARTIFACT=artifacts/m4-linux/bits-7.3-63-wedge-r3 "G16_EXPECT_UTS=#63 SMP PREEMPT_DYNAMIC Thu Oct  8 15:26:58 EDT 2026" G16_BASE_ARGS=asahi_m4.dependency_kind=0 "G16_BOOT_EXTRA=$X" "G16_TESTS=$tests" G16_OVERLAY_BASE=/mnt/g16-external/codex-dota-overlay/$tag $R
    grep -qs "STALL in" "$(ls -td artifacts/dota-compute-stall-20261007/ro-session/$tag-* | head -1)"/codex-dota-*/verdicts.txt && { echo "$tag stalled; stopping"; break; }
done
/home/nsheth/Projects/asahi/tools/lease/lease.sh release mini codex-dota
echo "block 49 done at $(date -Is)"
