#!/bin/bash
# Block 38: resize storm (render_present --resize-ms 700, +partner; rp-storm then rp-storm-rc), no Dota, #51 without unmap_full_inval; was: Block 36: unmap_full_inval=2 (kernel ASID + vmalle1os flush on every bind/unbind), quar0 x4; was: Block 35 VA quarantine A/B on #51 (A4-prone defaults, ring on), claude-driver's apple9/va-quarantine-debug
# 7835475b288 (8825824 + traces + HK_VA_QUARANTINE_MS): quar2000 x8 vs quar0 x2 (same library), HK_VA_TRACE +
# HK_WSI_TRACE on. Stops at the first quar2000 stall.
set -uo pipefail
cd /home/nsheth/Projects/asahi
while [ -n "${WAIT_PID:-}" ] && kill -0 "$WAIT_PID" 2>/dev/null; do sleep 30; done
R=artifacts/dota-compute-stall-20261007/ro-session/ro-session.sh
r() { env G16_KEEP_LEASE=1 G16_TAG=$1 G16_KERNEL_ARTIFACT=artifacts/m4-linux/bits-7.3-51-ringinval "G16_EXPECT_UTS=#51 SMP PREEMPT_DYNAMIC Thu Oct  8 12:53:09 EDT 2026" G16_BASE_ARGS=asahi_m4.dependency_kind=0 "G16_BOOT_EXTRA=asahi_m4.dep_stats=1 asahi_m4.context_sticky=0 asahi_m4.lifecycle=0 asahi_m4.cc_pattern=0 asahi_m4.dump_render_buffered=16 asahi_m4.dump_render_reg=0x15211 asahi_m4.dump_render_value=0x2d000000500 asahi_m4.dump_render_recent=48" "G16_TESTS=$2" G16_OVERLAY_BASE=/mnt/g16-external/codex-dota-overlay/$1 $R; }
for n in 1 2; do r k51-storm-$n "rp-storm rp-storm-rc"
    grep -q "STALL in" "$(ls -td artifacts/dota-compute-stall-20261007/ro-session/k51-storm-$n-* | head -1)"/codex-dota-*/verdicts.txt 2>/dev/null && { echo "storm stalled in session $n; stopping"; break; }
done
echo "block 38 done at $(date -Is)"
