#!/bin/bash
# Block 42: flush_each A/B on #61 (claude-kernel 6e7d048 = #55 tree + flush_each). Dota default mode, quar0 trace build,
# A4-prone settings, recent ring. flush_each=1 (A) x6 vs =0 (C) x2: A A C A A C A A; stops at the first =1 stall or a
# failed boot. Then claude-compiler's variant-stats rerun (k55-stats-1 hit A4 at 42 s before any stats line).
# Runs right after block 41 session 1 (manager), before the split-burst session (block 41b).
set -uo pipefail
cd /home/nsheth/Projects/asahi
while [ -n "${WAIT_PID:-}" ] && kill -0 "$WAIT_PID" 2>/dev/null; do sleep 30; done

R=artifacts/dota-compute-stall-20261007/ro-session/ro-session.sh
K="G16_KERNEL_ARTIFACT=artifacts/m4-linux/bits-7.3-61-flusheach"
U="G16_EXPECT_UTS=#61 SMP PREEMPT_DYNAMIC Thu Oct  8 15:11:48 EDT 2026"
X="asahi_m4.dep_stats=1 asahi_m4.context_sticky=0 asahi_m4.lifecycle=0 asahi_m4.cc_pattern=0 asahi_m4.dump_render_buffered=16 asahi_m4.dump_render_reg=0x15211 asahi_m4.dump_render_value=0x2d000000500 asahi_m4.dump_render_recent=48"
r() { env G16_KEEP_LEASE=1 G16_TAG=$1 "$K" "$U" G16_BASE_ARGS=asahi_m4.dependency_kind=0 "G16_BOOT_EXTRA=$X asahi_m4.flush_each=$2" G16_TESTS=dota-$3 G16_OVERLAY_BASE=/mnt/g16-external/codex-dota-overlay/$1 $R; }
last() { ls -td artifacts/dota-compute-stall-20261007/ro-session/$1-* | head -1; }
n=0
for slot in A A C A A C A A; do
    n=$((n + 1))
    if [ $slot = A ]; then tag=k61-fe1-$n; r $tag 1 quar0; else tag=k61-fe0-$n; r $tag 0 quar0; fi
    [ -s "$(last $tag)/loaded-kernel.txt" ] || { echo "#61 failed to boot in $tag; stopping"; break; }
    [ $slot = A ] && grep -q "STALL in" "$(last $tag)"/codex-dota-*/verdicts.txt 2>/dev/null && { echo "flush_each=1 stalled in run $n; stopping"; break; }
done
r k61-stats-1 0 stats
/home/nsheth/Projects/asahi/tools/lease/lease.sh release mini codex-dota
echo "block 42 done at $(date -Is)"
