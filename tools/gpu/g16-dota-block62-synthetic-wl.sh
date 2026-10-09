#!/bin/bash
# Block 62 (manager): richer synthetic loading-end shape -- Dota-like renders (2 waits, heavy TA) after a 6 s idle with
# 2-3 computes right before, under synthetic host load; rb-wl6d/rb-wl6dx3 = computes from a second VkDevice (own VM, as Dota).
set -uo pipefail
cd /home/nsheth/Projects/asahi
while [ -n "${WAIT_PID:-}" ] && kill -0 "$WAIT_PID" 2>/dev/null; do sleep 30; done
S=artifacts/dota-compute-stall-20261007/ro-session; R=$S/ro-session.sh
BEH="asahi_m4.context_sticky=0 asahi_m4.lifecycle=0 asahi_m4.cc_pattern=0 asahi_m4.ta_sel6=0 asahi_m4.diag_mask=0x04 log_buf_len=8M loglevel=4"
K=artifacts/m4-linux/bits-7.3-103-renderaftercompute; U="#103 SMP PREEMPT_DYNAMIC Fri Oct  9 11:54:29 EDT 2026"
for n in 1 2; do
    env G16_KEEP_LEASE=1 G16_DESKTOP_MESA=old G16_TAG=k62-wl-$n G16_KERNEL_ARTIFACT=$K "G16_EXPECT_UTS=$U" G16_BASE_ARGS=asahi_m4.dependency_kind=0 "G16_BOOT_EXTRA=$BEH" "G16_TESTS=rb-wl6d rb-wl6dx3 rb-wl6" G16_OVERLAY_BASE=/tmp/codex-dota-k62-$n $R
    v=$(ls $S/k62-wl-$n-*/codex-dota-*/verdicts.txt 2>/dev/null | tail -1)
    echo "k62-wl-$n: $(grep -hE 'STALL|TIMEOUT|NO-STALL' $v 2>/dev/null | tr '\n' ' ') bursts=$(grep -h 'burst .* idle' ${v%/verdicts.txt}/rb-wl*.log 2>/dev/null | wc -l)"
done
echo "block 62 done at $(date -Is)"
tools/lease/lease.sh release mini codex-dota
