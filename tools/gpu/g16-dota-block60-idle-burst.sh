#!/bin/bash
# Block 60 (manager): synthetic repro of the loading-end shape -- after a drained 6 s idle, 2-3 compute Works then 4 renders
# (rb-cidle6, rb-cidle6x3), plus a render-only idle control (rb-idle6), ~5 min each.
# rb-idle2 = 2 s), ~5 min each, on #101 diag_mask=0x04 (wake snapshots) (hang dumps carry the work log), non-robust desktop, no load.
set -uo pipefail
cd /home/nsheth/Projects/asahi
while [ -n "${WAIT_PID:-}" ] && kill -0 "$WAIT_PID" 2>/dev/null; do sleep 30; done
S=artifacts/dota-compute-stall-20261007/ro-session; R=$S/ro-session.sh
BEH="asahi_m4.context_sticky=0 asahi_m4.lifecycle=0 asahi_m4.cc_pattern=0 asahi_m4.ta_sel6=0 asahi_m4.diag_mask=0x04 log_buf_len=8M loglevel=4"
K=artifacts/m4-linux/bits-7.3-101-worklog2; U="#101 SMP PREEMPT_DYNAMIC Fri Oct  9 11:33:00 EDT 2026"
for n in 1 2; do
    env G16_KEEP_LEASE=1 G16_DESKTOP_MESA=old G16_TAG=k60-idle-$n G16_KERNEL_ARTIFACT=$K "G16_EXPECT_UTS=$U" G16_BASE_ARGS=asahi_m4.dependency_kind=0 "G16_BOOT_EXTRA=$BEH" "G16_TESTS=rb-cidle6 rb-cidle6x3 rb-idle6" G16_OVERLAY_BASE=/tmp/codex-dota-k60-$n $R
    v=$(ls $S/k60-idle-$n-*/codex-dota-*/verdicts.txt 2>/dev/null | tail -1)
    echo "k60-idle-$n: $(grep -hE 'STALL|TIMEOUT|NO-STALL' $v 2>/dev/null | tr '\n' ' ') bursts=$(grep -h 'burst .* idle' ${v%/verdicts.txt}/rb-idle*.log 2>/dev/null | wc -l)"
done
echo "block 60 done at $(date -Is)"
