#!/bin/bash
# Block 35: VA quarantine A/B on #51 (A4-prone defaults, ring on), claude-driver's apple9/va-quarantine-debug
# 7835475b288 (8825824 + traces + HK_VA_QUARANTINE_MS): quar2000 x8 vs quar0 x2 (same library), HK_VA_TRACE +
# HK_WSI_TRACE on. Stops at the first quar2000 stall.
set -uo pipefail
cd /home/nsheth/Projects/asahi
while [ -n "${WAIT_PID:-}" ] && kill -0 "$WAIT_PID" 2>/dev/null; do sleep 30; done
R=artifacts/dota-compute-stall-20261007/ro-session/ro-session.sh
r() { env G16_KEEP_LEASE=1 G16_TAG=$1 G16_KERNEL_ARTIFACT=artifacts/m4-linux/bits-7.3-51-ringinval "G16_EXPECT_UTS=#51 SMP PREEMPT_DYNAMIC Thu Oct  8 12:53:09 EDT 2026" G16_BASE_ARGS=asahi_m4.dependency_kind=0 "G16_BOOT_EXTRA=asahi_m4.dep_stats=1 asahi_m4.context_sticky=0 asahi_m4.lifecycle=0 asahi_m4.cc_pattern=0 asahi_m4.dump_render_buffered=16 asahi_m4.dump_render_reg=0x15211 asahi_m4.dump_render_value=0x2d000000500 asahi_m4.dump_render_recent=48" G16_TESTS=dota-$2 G16_OVERLAY_BASE=/mnt/g16-external/codex-dota-overlay/$1 $R; }
n=0
for slot in Q Q Q C Q Q Q C Q Q; do
    n=$((n + 1))
    if [ $slot = Q ]; then r k51-q2000-$n quar2000
        grep -q "STALL in" "$(ls -td artifacts/dota-compute-stall-20261007/ro-session/k51-q2000-$n-* | head -1)"/codex-dota-*/verdicts.txt 2>/dev/null && { echo "quar2000 stalled in run $n; stopping"; break; }
    else r k51-q0-$n quar0; fi
done
echo "block 35 done at $(date -Is)"
