#!/bin/bash
# Block 41 (manager (a)): content-exact gfxr replay toward Dota's loading-end burst with -m rebind --sfa
# (earlier replays died at API 113517 in frame 1). Native aarch64 (trace driver, HK_PASS_TRACE) and x86 in m4-muvm.
# Session 2: split-submit burst synthetic (rp-sburst native, rp-msburst muvm) with two partner clients.
# #55, A4-prone settings, recent ring. 2 sessions, stops at the first stall.
set -uo pipefail
cd /home/nsheth/Projects/asahi
while [ -n "${WAIT_PID:-}" ] && kill -0 "$WAIT_PID" 2>/dev/null; do sleep 30; done
R=artifacts/dota-compute-stall-20261007/ro-session/ro-session.sh
for n in 1 2; do
    tests="replay-rb replay-rb-x86"; tag=k55-replay-$n; [ $n = 2 ] && { tests="rp-sburst rp-msburst"; tag=k55-sburst-1; }
    env G16_KEEP_LEASE=1 G16_TAG=$tag G16_KERNEL_ARTIFACT=artifacts/m4-linux/bits-7.3-55-stale "G16_EXPECT_UTS=#55 SMP PREEMPT_DYNAMIC Thu Oct  8 14:16:32 EDT 2026" G16_BASE_ARGS=asahi_m4.dependency_kind=0 "G16_BOOT_EXTRA=asahi_m4.dep_stats=1 asahi_m4.context_sticky=0 asahi_m4.lifecycle=0 asahi_m4.cc_pattern=0 asahi_m4.dump_render_buffered=16 asahi_m4.dump_render_reg=0x15211 asahi_m4.dump_render_value=0x2d000000500 asahi_m4.dump_render_recent=48" "G16_TESTS=$tests" G16_OVERLAY_BASE=/mnt/g16-external/codex-dota-overlay/$tag $R
    grep -q "STALL in" "$(ls -td artifacts/dota-compute-stall-20261007/ro-session/$tag-* | head -1)"/codex-dota-*/verdicts.txt 2>/dev/null && { echo "replay stalled in session $n; stopping"; break; }
done
/home/nsheth/Projects/asahi/tools/lease/lease.sh release mini codex-dota
echo "block 41 done at $(date -Is)"
