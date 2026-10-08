#!/bin/bash
# Block 45 (manager): perf_base=10 (pin the perf controller's base pstate to the top) single-variable A/B on #63
# (a0da92b) with wedge_recover=0 (detection logs only), flush_each=0, Dota default mode, quar0 trace build, A4-prone
# settings, recent ring. perf_base=10 (A) x6 vs default (C) x2: A A C A A C A A; stops at the first A stall.
set -uo pipefail
cd /home/nsheth/Projects/asahi
while [ -n "${WAIT_PID:-}" ] && kill -0 "$WAIT_PID" 2>/dev/null; do sleep 30; done
R=artifacts/dota-compute-stall-20261007/ro-session/ro-session.sh
X="asahi_m4.dep_stats=1 asahi_m4.context_sticky=0 asahi_m4.lifecycle=0 asahi_m4.cc_pattern=0 asahi_m4.dump_render_buffered=16 asahi_m4.dump_render_reg=0x15211 asahi_m4.dump_render_value=0x2d000000500 asahi_m4.dump_render_recent=48 asahi_m4.flush_each=0 asahi_m4.wedge_recover=0"
last() { ls -td artifacts/dota-compute-stall-20261007/ro-session/$1-* | head -1; }
n=0
for slot in A A C A A C A A; do
    n=$((n + 1))
    if [ $slot = A ]; then tag=k63-pb10-$n; extra="$X asahi_m4.perf_base=10"; else tag=k63-pb0-$n; extra="$X"; fi
    env G16_KEEP_LEASE=1 G16_TAG=$tag G16_KERNEL_ARTIFACT=artifacts/m4-linux/bits-7.3-63-wedge-r3 "G16_EXPECT_UTS=#63 SMP PREEMPT_DYNAMIC Thu Oct  8 15:26:58 EDT 2026" G16_BASE_ARGS=asahi_m4.dependency_kind=0 "G16_BOOT_EXTRA=$extra" G16_TESTS=dota-quar0 G16_OVERLAY_BASE=/mnt/g16-external/codex-dota-overlay/$tag $R
    d=$(last $tag)
    [ -s "$d/loaded-kernel.txt" ] || { echo "#63 failed to boot in $tag; stopping"; break; }
    [ $slot = A ] && grep -qs "STALL in" "$d"/codex-dota-*/verdicts.txt && { echo "perf_base=10 stalled in run $n; stopping"; break; }
done
echo "block 45 done at $(date -Is)"
