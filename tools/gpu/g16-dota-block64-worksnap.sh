#!/bin/bash
# Block 64 (manager): what the stuck Work waits on. #106 (= #105 + RAC idle fix, same defaults) (wait sources per submit; worksnap of TA Work, microsequence, scene
# record, buffer manager, support header and TA queue struct at retirement for Dota ordinals 2800-2840 and live at the
# wedge). Non-robust desktop, load repro, diag_mask=0x04; dumps at +116/124/132 s give clean comparisons. Runs until >=2
# stalled and >=2 clean with the burst captured (cap 8).
set -uo pipefail
cd /home/nsheth/Projects/asahi
while [ -n "${WAIT_PID:-}" ] && kill -0 "$WAIT_PID" 2>/dev/null; do sleep 30; done
# claude-compiler's CTS rerun goes first (after claude-kernel's #106 boot check); wait for its release (cap 45 min).
H=tmp/leases/history.log; t0=$(date +%s)
until grep -q "release mini claude-compiler" <(tail -n +${HSTART:-$(wc -l < $H)} $H); do [ $(( $(date +%s) - t0 )) -gt 2700 ] && break; sleep 30; done
echo "claude-compiler slot over $(date +%T)"
S=artifacts/dota-compute-stall-20261007/ro-session; R=$S/ro-session.sh
BEH="asahi_m4.context_sticky=0 asahi_m4.lifecycle=0 asahi_m4.cc_pattern=0 asahi_m4.ta_sel6=0 asahi_m4.diag_mask=0x04 asahi_m4.snap_from=2800 asahi_m4.snap_to=2840 asahi_m4.snap_comm=0x6e75726b62696c log_buf_len=8M loglevel=4"
K=artifacts/m4-linux/bits-7.3-106-worksnap-rac; U="#106 SMP PREEMPT_DYNAMIC Fri Oct  9 13:35:50 EDT 2026"
st=0; cl=0
for n in 1 2 3 4 5 6 7 8; do
    t=k64-snap-$n
    env G16_KEEP_LEASE=1 G16_STEAM_OFFLINE=1 G16_SYNTH_LOAD=1 G16_IO_THROTTLE=50M "G16_WORKLOG_DUMP=116 124 132" G16_DESKTOP_MESA=old G16_TAG=$t G16_KERNEL_ARTIFACT=$K "G16_EXPECT_UTS=$U" G16_BASE_ARGS=asahi_m4.dependency_kind=0 "G16_BOOT_EXTRA=$BEH" G16_TESTS=dota-quar0 G16_OVERLAY_BASE=/mnt/g16-external/codex-dota-overlay/$t $R
    v=$(ls -d $S/$t-*/codex-dota-*/verdicts.txt 2>/dev/null | tail -1); k=${v%/verdicts.txt}/kernel.log
    if [ -z "$v" ] || ! grep -q "desktop-mesa libgallium c67094aff03da189" "$v" || ! grep -qE "STALL in|NO-STALL" "$v" || ! grep -q "G16: worklog" "$k"; then
        echo "SETUP FAILURE in $t"; tools/lease/lease.sh release mini codex-dota; exit 1; fi
    snaps=$(grep -c "worksnap" "$k"); waits=$(grep -c "worklog   wait" "$k")
    if grep -q "STALL in" "$v"; then st=$((st + 1)); r=STALL; else r=clean; grep -q "worksnap retired.*ordinal=281[6-9]" "$k" && cl=$((cl + 1)); fi
    echo "$t ok: $r worksnap-lines=$snaps wait-lines=$waits (stalled=$st clean-with-burst=$cl)"
    [ $st -ge 2 ] && [ $cl -ge 2 ] && break
done
tools/lease/lease.sh release mini codex-dota
echo "block 64 done at $(date -Is)"
