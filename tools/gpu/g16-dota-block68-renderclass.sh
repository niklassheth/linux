#!/bin/bash
# Block 68 (see below); kernel #110 (= #109 + render_class knob, off) (worksnap + 3D-side snapshots: 3d_work, 3d_micro, 3d_queue,
# lane pointer pages), non-robust desktop, load repro. 3 pairs; any stall in either arm yields the 3D-side state.
# record, buffer manager, support header and TA queue struct at retirement for Dota ordinals 2800-2840 and live at the
# wedge). Non-robust desktop, load repro, diag_mask=0x04; dumps at +116/124/132 s give clean comparisons. Runs until >=2
# stalled and >=2 clean with the burst captured (cap 8).
set -uo pipefail
cd /home/nsheth/Projects/asahi
while [ -n "${WAIT_PID:-}" ] && kill -0 "$WAIT_PID" 2>/dev/null; do sleep 30; done
# claude-driver's Lethal kernel A/B slot (retry; its first attempt failed instantly) between blocks 67 and 68.
H=tmp/leases/history.log; start=$(wc -l < $H); t0=$(date +%s)
until tail -n +$((start + 1)) $H | grep -q "release mini claude-driver"; do [ $(( $(date +%s) - t0 )) -gt 3000 ] && break; sleep 30; done
echo "claude-driver slot over $(date +%T)"
S=artifacts/dota-compute-stall-20261007/ro-session; R=$S/ro-session.sh
BEH="asahi_m4.context_sticky=0 asahi_m4.lifecycle=0 asahi_m4.cc_pattern=0 asahi_m4.ta_sel6=0 asahi_m4.diag_mask=0x04 asahi_m4.snap_from=2800 asahi_m4.snap_to=2840 asahi_m4.snap_comm=0x6e75726b62696c log_buf_len=8M loglevel=4"
K=artifacts/m4-linux/bits-7.3-110-renderclass; U="#110 SMP PREEMPT_DYNAMIC Fri Oct  9 14:17:18 EDT 2026"
# Block 68 (claude-kernel's firmware-side switch control, after block 67): render_class=2 puts every new queue (KWin,
# Xwayland, Dota) in one firmware priority class, so there is no class arbitration between their 3D. 3 pairs vs default.
for n in 1 2 3; do
  for arm in rc2 rcd; do
    t=k68-$arm-$n; x=; [ $arm = rc2 ] && x=asahi_m4.render_class=2
    env G16_KEEP_LEASE=1 G16_STEAM_OFFLINE=1 G16_SYNTH_LOAD=1 G16_IO_THROTTLE=50M "G16_WORKLOG_DUMP=116 124 132" G16_DESKTOP_MESA=old G16_TAG=$t G16_KERNEL_ARTIFACT=$K "G16_EXPECT_UTS=$U" G16_BASE_ARGS=asahi_m4.dependency_kind=0 "G16_BOOT_EXTRA=$BEH asahi_m4.debug_ctx=1 $x" G16_TESTS=dota-quar0 G16_OVERLAY_BASE=/mnt/g16-external/codex-dota-overlay/$t $R
    v=$(ls -d $S/$t-*/codex-dota-*/verdicts.txt 2>/dev/null | tail -1); k=${v%/verdicts.txt}/kernel.log
    if [ -z "$v" ] || ! grep -q "desktop-mesa libgallium c67094aff03da189" "$v" || ! grep -qE "STALL in|NO-STALL" "$v"; then echo "SETUP FAILURE in $t (skip)"; continue; fi
    echo "$t ok: $(grep -hE 'STALL' "$v" | head -1) priorities=$(grep -o 'priority=[0-9]' "$k" | sort | uniq -c | tr '\n' ' ')"
  done
  echo "round $n: rc2=$(grep -ls 'STALL in' $S/k68-rc2-*/codex-dota-*/verdicts.txt 2>/dev/null | wc -l) rcd=$(grep -ls 'STALL in' $S/k68-rcd-*/codex-dota-*/verdicts.txt 2>/dev/null | wc -l)"
done
tools/lease/lease.sh release mini codex-dota
echo "block 68 done at $(date -Is)"
