#!/bin/bash
# Block 57 (manager): desktop-driver A/B under the load repro. A4 wedges all clients and the load-arm base rate dropped
# (DL91 0/4) after KWin/Xwayland moved to system Mesa eaa2141 at 03:13. #76 diag_record=0, Steam offline, synthetic
# load + 50M cap; OLD = pre-eaa2141 system Mesa (8825824) bind-mounted per boot (G16_DESKTOP_MESA=old), NEW = eaa2141.
# x4 each, interleaved. Writes the reproducing setting to block56-desktop for block 56. Starts after block 55 and the
# hand-offs (claude-kernel Wi-Fi, claude-driver-mesh capture), keyed off their releases (max 2.5 h).
set -uo pipefail
cd /home/nsheth/Projects/asahi
while [ -n "${WAIT_PID:-}" ] && kill -0 "$WAIT_PID" 2>/dev/null; do sleep 30; done
H=/home/nsheth/Projects/asahi/tmp/leases/history.log; start=$(wc -l < $H); t0=$(date +%s)
for who in claude-kernel claude-driver-mesh; do
    until tail -n +$((start + 1)) $H | grep -q "release mini $who"; do
        [ $(( $(date +%s) - t0 )) -gt 9000 ] && { echo "hand-off wait timed out at $who"; break 2; }; sleep 60; done
    echo "$who done ($(date +%T))"
done
R=artifacts/dota-compute-stall-20261007/ro-session/ro-session.sh
BEH="asahi_m4.context_sticky=0 asahi_m4.lifecycle=0 asahi_m4.cc_pattern=0 asahi_m4.ta_sel6=0 asahi_m4.diag_record=0"
K=artifacts/m4-linux/bits-7.3-76-diagmask; U="#76 SMP PREEMPT_DYNAMIC Thu Oct  8 19:29:01 EDT 2026"
r() { env G16_KEEP_LEASE=1 G16_STEAM_OFFLINE=1 G16_SYNTH_LOAD=1 G16_IO_THROTTLE=50M G16_DESKTOP_MESA=$2 G16_TAG=$1 G16_KERNEL_ARTIFACT=$K "G16_EXPECT_UTS=$U" G16_BASE_ARGS=asahi_m4.dependency_kind=0 "G16_BOOT_EXTRA=$BEH" G16_TESTS=dota-quar0 G16_OVERLAY_BASE=/mnt/g16-external/codex-dota-overlay/$1 $R; }
stalls() { local c=0; for d in artifacts/dota-compute-stall-20261007/ro-session/k57-$1-*; do grep -qs "STALL in" $d/codex-dota-*/verdicts.txt && c=$((c+1)); done; echo $c; }
for n in 1 2 3 4; do
    r k57-old-$n old
    r k57-new-$n ""
    echo "round $n: old=$(stalls old) new=$(stalls new)"
done
if [ "$(stalls old)" -gt "$(stalls new)" ]; then echo old > artifacts/dota-compute-stall-20261007/ro-session/block56-desktop; else : > artifacts/dota-compute-stall-20261007/ro-session/block56-desktop; fi
echo "block 57 done at $(date -Is); block 56 desktop=[$(cat artifacts/dota-compute-stall-20261007/ro-session/block56-desktop)]"
