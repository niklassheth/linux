#!/bin/bash
# Block 58 (manager-approved bisect of block 57): which desktop GL-robustness commit lowers the A4 rate.
# Desktop (KWin/Xwayland) Mesa A = 8825824+2229add (robust context/reset status), B = A+dea4fdd (per-batch fence-error
# poll for robust contexts). Same load repro as block 57: #76 diag_record=0, Steam offline, synthetic load, 50M cap.
# x4 each, interleaved. Trees are host-staged by claude-driver and rsynced to the external disk by ro-session.sh.
set -uo pipefail
cd /home/nsheth/Projects/asahi
while [ -n "${WAIT_PID:-}" ] && kill -0 "$WAIT_PID" 2>/dev/null; do sleep 30; done
M=/home/nsheth/Projects/asahi/artifacts/desktop-mesa
t0=$(date +%s); until [ -s $M/mesa-6757a3d/SHA256SUMS ] && [ -s $M/mesa-13a77ea/SHA256SUMS ]; do
    [ $(( $(date +%s) - t0 )) -gt 7200 ] && { echo "trees not staged"; exit 1; }; sleep 60; done
R=artifacts/dota-compute-stall-20261007/ro-session/ro-session.sh
BEH="asahi_m4.context_sticky=0 asahi_m4.lifecycle=0 asahi_m4.cc_pattern=0 asahi_m4.ta_sel6=0 asahi_m4.diag_record=0"
K=artifacts/m4-linux/bits-7.3-76-diagmask; U="#76 SMP PREEMPT_DYNAMIC Thu Oct  8 19:29:01 EDT 2026"
r() { env G16_KEEP_LEASE=1 G16_STEAM_OFFLINE=1 G16_SYNTH_LOAD=1 G16_IO_THROTTLE=50M G16_DESKTOP_MESA_HOST=$2 G16_TAG=$1 G16_KERNEL_ARTIFACT=$K "G16_EXPECT_UTS=$U" G16_BASE_ARGS=asahi_m4.dependency_kind=0 "G16_BOOT_EXTRA=$BEH" G16_TESTS=dota-quar0 G16_OVERLAY_BASE=/mnt/g16-external/codex-dota-overlay/$1 $R; }
stalls() { local c=0; for d in artifacts/dota-compute-stall-20261007/ro-session/k58-$1-*; do grep -qs "STALL in" $d/codex-dota-*/verdicts.txt && c=$((c+1)); done; echo $c; }
# Abort the block if a run did not reach Dota with the intended desktop libgallium (setup failure = skip, not a result).
chk() { local v; v=$(ls -d artifacts/dota-compute-stall-20261007/ro-session/$1-*/codex-dota-*/verdicts.txt 2>/dev/null | tail -1)
    if [ -z "$v" ] || ! grep -q "desktop-mesa libgallium $2" "$v" || ! grep -qE "STALL in|NO-STALL" "$v"; then
        echo "SETUP FAILURE in $1 (verdicts=$v); aborting block 58"; tools/lease/lease.sh release mini codex-dota; exit 1; fi; echo "$1 ok: $(grep -hE "STALL" "$v" | head -1)"; }
for n in 1 2 3 4; do
    r k58-rob-$n $M/mesa-6757a3d; chk k58-rob-$n b165f92cbd49c291
    r k58-poll-$n $M/mesa-13a77ea; chk k58-poll-$n f6b4757b0b778508
    echo "round $n: rob(2229add)=$(stalls rob) poll(+dea4fdd)=$(stalls poll)"
done
tools/lease/lease.sh release mini codex-dota
echo "block 58 done at $(date -Is)"
