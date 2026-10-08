#!/bin/bash
# Block 46: gfxr replay exposure loop (full trace replays cleanly in ~27 s): native x12 + x86/muvm x8 per session,
# on #64 (wedge detection log-only, A4-prone settings, recent ring). 2 sessions, stops at the first stall.
set -uo pipefail
cd /home/nsheth/Projects/asahi
while [ -n "${WAIT_PID:-}" ] && kill -0 "$WAIT_PID" 2>/dev/null; do sleep 30; done
R=artifacts/dota-compute-stall-20261007/ro-session/ro-session.sh
X="asahi_m4.dep_stats=1 asahi_m4.context_sticky=0 asahi_m4.lifecycle=0 asahi_m4.cc_pattern=0 asahi_m4.dump_render_buffered=16 asahi_m4.dump_render_reg=0x15211 asahi_m4.dump_render_value=0x2d000000500 asahi_m4.dump_render_recent=48"
for n in 1 2; do
    tag=k64-rloop-$n
    env G16_KEEP_LEASE=1 G16_TAG=$tag G16_KERNEL_ARTIFACT=artifacts/m4-linux/bits-7.3-64-probefix "G16_EXPECT_UTS=#64 SMP PREEMPT_DYNAMIC Thu Oct  8 16:06:27 EDT 2026" G16_BASE_ARGS=asahi_m4.dependency_kind=0 "G16_BOOT_EXTRA=$X" "G16_TESTS=replay-loop replay-loop-x86" G16_OVERLAY_BASE=/mnt/g16-external/codex-dota-overlay/$tag $R
    grep -qs "STALL in" "$(ls -td artifacts/dota-compute-stall-20261007/ro-session/$tag-* | head -1)"/codex-dota-*/verdicts.txt && { echo "replay loop stalled in session $n; stopping"; break; }
done
/home/nsheth/Projects/asahi/tools/lease/lease.sh release mini codex-dota
echo "block 46 done at $(date -Is)"
