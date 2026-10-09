#!/bin/bash
# Block 53 (manager): firm up the M03L lead under the load repro. After DL-8: release for claude-driver's ~10 min
# heap-walk window (waits up to 15 min for a holder, then until it releases), then M03L (#76 diag_mask=0x03) x6 vs
# DL (#76 diag_record=0) x6 interleaved, Steam offline + synthetic load + 50M cap; then block 50.
set -uo pipefail
cd /home/nsheth/Projects/asahi
while [ -n "${WAIT_PID:-}" ] && kill -0 "$WAIT_PID" 2>/dev/null; do sleep 15; done
unset WAIT_PID
L=/home/nsheth/Projects/asahi/tools/lease/lease.sh
$L release mini codex-dota; echo "released for claude-driver window at $(date -Is)"
other=; for i in $(seq 1 30); do h=$($L holder mini | awk '{print $1}'); [ -n "$h" ] && [ "$h" != free ] && [ "$h" != codex-dota ] && { other=$h; break; }; sleep 30; done
if [ -n "$other" ]; then echo "window taken by $other"; while [ "$($L holder mini | awk '{print $1}')" = "$other" ]; do sleep 30; done; echo "window ended at $(date -Is)"; else echo "nobody took the window in 15 min; continuing"; fi
R=artifacts/dota-compute-stall-20261007/ro-session/ro-session.sh
BEH="asahi_m4.context_sticky=0 asahi_m4.lifecycle=0 asahi_m4.cc_pattern=0"
K76=artifacts/m4-linux/bits-7.3-76-diagmask; U76="#76 SMP PREEMPT_DYNAMIC Thu Oct  8 19:29:01 EDT 2026"
r() { env G16_KEEP_LEASE=1 G16_STEAM_OFFLINE=1 G16_SYNTH_LOAD=1 G16_IO_THROTTLE=50M G16_TAG=$1 G16_KERNEL_ARTIFACT=$K76 "G16_EXPECT_UTS=$U76" G16_BASE_ARGS=asahi_m4.dependency_kind=0 "G16_BOOT_EXTRA=$2" G16_TESTS=dota-quar0 G16_OVERLAY_BASE=/mnt/g16-external/codex-dota-overlay/$1 $R; }
stalls() { local c=0; for d in artifacts/dota-compute-stall-20261007/ro-session/$1-*; do grep -qs "STALL in" $d/codex-dota-*/verdicts.txt && c=$((c+1)); done; echo $c; }
for n in 1 2 3 4 5 6; do
    r k53-m03l-$n "$BEH asahi_m4.ta_sel6=0 asahi_m4.diag_mask=0x03"
    r k53-dl-$n "$BEH asahi_m4.ta_sel6=0 asahi_m4.diag_record=0"
    echo "round $n: k53 m03l=$(stalls k53-m03l) dl=$(stalls k53-dl) | totals m03l=$(( $(stalls k52-m03l) + $(stalls k53-m03l) )) dl=$(( $(stalls k52-dl) + $(stalls k53-dl) ))"
done
echo "block 53 done at $(date -Is)"
./artifacts/dota-compute-stall-20261007/ro-session/block50.sh
