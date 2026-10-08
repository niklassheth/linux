#!/bin/bash
# Block 34b (rewritten 2026-10-08 13:5x): burst synthetic (rp-burst native + rp-mburst muvm), then claude-compiler stats run.
set -uo pipefail
cd /home/nsheth/Projects/asahi
while [ -n "${WAIT_PID:-}" ] && kill -0 "$WAIT_PID" 2>/dev/null; do sleep 30; done
R=artifacts/dota-compute-stall-20261007/ro-session/ro-session.sh
env G16_KEEP_LEASE=1 G16_TAG=k52-burst-1 G16_KERNEL_ARTIFACT=artifacts/m4-linux/bits-7.3-52-history "G16_EXPECT_UTS=#52 SMP PREEMPT_DYNAMIC Thu Oct  8 13:19:57 EDT 2026" G16_BASE_ARGS=asahi_m4.dependency_kind=0 "G16_BOOT_EXTRA=asahi_m4.dep_stats=1 asahi_m4.context_sticky=0 asahi_m4.lifecycle=0 asahi_m4.cc_pattern=0 asahi_m4.dump_render_buffered=16 asahi_m4.dump_render_reg=0x15211 asahi_m4.dump_render_value=0x2d000000500 asahi_m4.dump_render_recent=48" "G16_TESTS=rp-burst rp-mburst" $R
env G16_TAG=k52-stats-1 G16_KERNEL_ARTIFACT=artifacts/m4-linux/bits-7.3-52-history "G16_EXPECT_UTS=#52 SMP PREEMPT_DYNAMIC Thu Oct  8 13:19:57 EDT 2026" G16_BASE_ARGS=asahi_m4.dependency_kind=0 "G16_BOOT_EXTRA=asahi_m4.dep_stats=1 asahi_m4.context_sticky=0 asahi_m4.lifecycle=0 asahi_m4.cc_pattern=0 asahi_m4.dump_render_buffered=16 asahi_m4.dump_render_reg=0x15211 asahi_m4.dump_render_value=0x2d000000500 asahi_m4.dump_render_recent=48" G16_TESTS=dota-stats G16_OVERLAY_BASE=/mnt/g16-external/codex-dota-overlay/k52-stats-1 $R
echo "block 34b done at $(date -Is)"
