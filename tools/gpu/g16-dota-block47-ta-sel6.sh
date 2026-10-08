#!/bin/bash
# Block 47: ta_sel6 A/B on #69 (abd0f0e = production #68 + asahi_m4.ta_sel6: re-publish the TVB buffer-manager init
# item (TA sel6) on a pool's first render larger than any before, as Metal does). Live Dota default mode, quar0 trace
# build, A4-prone settings, recent ring, fw_trace=512. ta_sel6=1 (A) x6 vs 0 (C) x2: A A C A A C A A; stops at the
# first =1 stall or a failed boot (first run doubles as #69's boot test).
set -uo pipefail
cd /home/nsheth/Projects/asahi
while [ -n "${WAIT_PID:-}" ] && kill -0 "$WAIT_PID" 2>/dev/null; do sleep 30; done
R=artifacts/dota-compute-stall-20261007/ro-session/ro-session.sh
X="asahi_m4.dep_stats=1 asahi_m4.context_sticky=0 asahi_m4.lifecycle=0 asahi_m4.cc_pattern=0 asahi_m4.dump_render_buffered=16 asahi_m4.dump_render_reg=0x15211 asahi_m4.dump_render_value=0x2d000000500 asahi_m4.dump_render_recent=48 asahi_m4.fw_trace=512"
last() { ls -td artifacts/dota-compute-stall-20261007/ro-session/$1-* | head -1; }
n=0
for slot in A A C A A C A A; do
    n=$((n + 1))
    if [ $slot = A ]; then tag=k69-s6on-$n; v=1; else tag=k69-s6off-$n; v=0; fi
    env G16_KEEP_LEASE=1 G16_TAG=$tag G16_KERNEL_ARTIFACT=artifacts/m4-linux/bits-7.3-69-sel6 "G16_EXPECT_UTS=#69 SMP PREEMPT_DYNAMIC Thu Oct  8 17:17:46 EDT 2026" G16_BASE_ARGS=asahi_m4.dependency_kind=0 "G16_BOOT_EXTRA=$X asahi_m4.ta_sel6=$v" G16_TESTS=dota-quar0 G16_OVERLAY_BASE=/mnt/g16-external/codex-dota-overlay/$tag $R
    d=$(last $tag)
    [ -s "$d/loaded-kernel.txt" ] || { echo "#69 failed to boot in $tag; stopping"; break; }
    [ $slot = A ] && grep -qs "STALL in" "$d"/codex-dota-*/verdicts.txt && { echo "ta_sel6=1 stalled in run $n; stopping"; break; }
done
echo "block 47 done at $(date -Is)"
