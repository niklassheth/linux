#!/bin/bash
# Block 67 (manager): defaults on #110 (= #109 + render_class knob, off) (worksnap + 3D-side snapshots: 3d_work, 3d_micro, 3d_queue,
# lane pointer pages), non-robust desktop, load repro. 3 pairs; any stall in either arm yields the 3D-side state.
# record, buffer manager, support header and TA queue struct at retirement for Dota ordinals 2800-2840 and live at the
# wedge). Non-robust desktop, load repro, diag_mask=0x04; dumps at +116/124/132 s give clean comparisons. Runs until >=2
# stalled and >=2 clean with the burst captured (cap 8).
set -uo pipefail
cd /home/nsheth/Projects/asahi
while [ -n "${WAIT_PID:-}" ] && kill -0 "$WAIT_PID" 2>/dev/null; do sleep 30; done
S=artifacts/dota-compute-stall-20261007/ro-session; R=$S/ro-session.sh
BEH="asahi_m4.context_sticky=0 asahi_m4.lifecycle=0 asahi_m4.cc_pattern=0 asahi_m4.ta_sel6=0 asahi_m4.diag_mask=0x04 asahi_m4.snap_from=2800 asahi_m4.snap_to=2840 asahi_m4.snap_comm=0x6e75726b62696c log_buf_len=8M loglevel=4"
K=${G16_K:?kernel artifact dir}; U=$(sed "s/ (.*//" $K/UTS)
# Manager 15:05: defaults only, until 2 stalls with 3D-side worksnaps + 1 clean run (cap 8).
st=0; cl=0
for n in 1 2 3 4 5 6 7 8; do
    t=k67b-def-$n
    env G16_KEEP_LEASE=1 G16_STEAM_OFFLINE=1 G16_SYNTH_LOAD=1 G16_IO_THROTTLE=50M "G16_WORKLOG_DUMP=116 124 132" G16_DESKTOP_MESA=old G16_TAG=$t G16_KERNEL_ARTIFACT=$K "G16_EXPECT_UTS=$U" G16_BASE_ARGS=asahi_m4.dependency_kind=0 "G16_BOOT_EXTRA=$BEH" G16_TESTS=dota-quar0 G16_OVERLAY_BASE=/mnt/g16-external/codex-dota-overlay/$t $R
    v=$(ls -d $S/$t-*/codex-dota-*/verdicts.txt 2>/dev/null | tail -1); k=${v%/verdicts.txt}/kernel.log
    if [ -z "$v" ] || ! grep -q "desktop-mesa libgallium c67094aff03da189" "$v" || ! grep -qE "STALL in|NO-STALL" "$v" || ! grep -q "G16: worklog" "$k"; then
        echo "SETUP FAILURE in $t (skip)"; continue; fi
    if grep -q "STALL in" "$v"; then st=$((st + 1)); else cl=$((cl + 1)); fi
    echo "$t ok: $(grep -hE 'STALL' "$v" | head -1) worksnap3d-lines=$(grep -c 'worksnap .*3d_' "$k") (stalled=$st clean=$cl)"
    [ $st -ge 2 ] && [ $cl -ge 1 ] && break
done
tools/lease/lease.sh release mini codex-dota
echo "block 67 done at $(date -Is)"
