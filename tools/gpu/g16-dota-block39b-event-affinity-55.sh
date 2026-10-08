#!/bin/bash
# Block 39b (runs 3-8 on #55 = #54 + stale-tag instrument; runs 1-2 were #54): event-index affinity A/B on #54 (claude-kernel 9a07986): Dota default mode, quar0 trace build (5567bc433e4),
# A4-prone defaults, recent ring with physical pages, fw_trace=256 on both arms. Arms: event_affinity=2 (A) x6,
# event_affinity=0 (C) x2 interleaved A A C A A C A A. Stops at the first event_affinity=2 stall.
set -uo pipefail
cd /home/nsheth/Projects/asahi
while [ -n "${WAIT_PID:-}" ] && kill -0 "$WAIT_PID" 2>/dev/null; do sleep 30; done
R=artifacts/dota-compute-stall-20261007/ro-session/ro-session.sh
r() { env G16_KEEP_LEASE=1 G16_TAG=$1 G16_KERNEL_ARTIFACT=artifacts/m4-linux/bits-7.3-55-stale "G16_EXPECT_UTS=#55 SMP PREEMPT_DYNAMIC Thu Oct  8 14:16:32 EDT 2026" G16_BASE_ARGS=asahi_m4.dependency_kind=0 "G16_BOOT_EXTRA=asahi_m4.dep_stats=1 asahi_m4.context_sticky=0 asahi_m4.lifecycle=0 asahi_m4.cc_pattern=0 asahi_m4.dump_render_buffered=16 asahi_m4.dump_render_reg=0x15211 asahi_m4.dump_render_value=0x2d000000500 asahi_m4.dump_render_recent=48 asahi_m4.fw_trace=256 asahi_m4.event_affinity=$2" G16_TESTS=dota-quar0 G16_OVERLAY_BASE=/mnt/g16-external/codex-dota-overlay/$1 $R; }
grep -qs "STALL in" artifacts/dota-compute-stall-20261007/ro-session/k54-ea2-2-*/codex-dota-*/verdicts.txt 2>/dev/null && { echo "run 2 (event_affinity=2) stalled; not continuing"; /home/nsheth/Projects/asahi/tools/lease/lease.sh release mini codex-dota; exit 0; }
n=2
for slot in C A A C A A; do
    n=$((n + 1))
    if [ $slot = A ]; then r k55-ea2-$n 2
        grep -q "STALL in" "$(ls -td artifacts/dota-compute-stall-20261007/ro-session/k55-ea2-$n-* | head -1)"/codex-dota-*/verdicts.txt 2>/dev/null && { echo "event_affinity=2 stalled in run $n; stopping"; break; }
    else r k55-ea0-$n 0; fi
done
/home/nsheth/Projects/asahi/tools/lease/lease.sh release mini codex-dota
echo "block 39 done at $(date -Is)"
