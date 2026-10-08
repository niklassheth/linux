#!/bin/bash
# Block 40: claude-compiler variant-stats Dota run (non-A4), after block 39.
set -uo pipefail
cd /home/nsheth/Projects/asahi
while [ -n "${WAIT_PID:-}" ] && kill -0 "$WAIT_PID" 2>/dev/null; do sleep 30; done
R=artifacts/dota-compute-stall-20261007/ro-session/ro-session.sh
env G16_TAG=k54-stats-1 G16_KERNEL_ARTIFACT=artifacts/m4-linux/bits-7.3-54-events "G16_EXPECT_UTS=#54 SMP PREEMPT_DYNAMIC Thu Oct  8 13:57:36 EDT 2026" G16_BASE_ARGS=asahi_m4.dependency_kind=0 "G16_BOOT_EXTRA=asahi_m4.dep_stats=1 asahi_m4.context_sticky=0 asahi_m4.lifecycle=0 asahi_m4.cc_pattern=0 asahi_m4.dump_render_buffered=16 asahi_m4.dump_render_reg=0x15211 asahi_m4.dump_render_value=0x2d000000500 asahi_m4.dump_render_recent=48" G16_TESTS=dota-stats G16_OVERLAY_BASE=/mnt/g16-external/codex-dota-overlay/k54-stats-1 $R
echo "block 40 done at $(date -Is)"
