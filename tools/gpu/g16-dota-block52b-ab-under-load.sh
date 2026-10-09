#!/bin/bash
# Block 52b: resume block 52's A/B under load after a ~10 min claude-driver slot (Metal object->mesh payload read).
# Round 5 remainder (M03L, DL), then rounds 6-8 (SL, M03L, DL), all Steam offline + synthetic load + 50M cap; then block 50.
set -uo pipefail
cd /home/nsheth/Projects/asahi
while [ -n "${WAIT_PID:-}" ] && kill -0 "$WAIT_PID" 2>/dev/null; do sleep 15; done
unset WAIT_PID
/home/nsheth/Projects/asahi/tools/lease/lease.sh release mini codex-dota; echo "yielded lease to claude-driver at $(date -Is)"; sleep 60
R=artifacts/dota-compute-stall-20261007/ro-session/ro-session.sh
BEH="asahi_m4.context_sticky=0 asahi_m4.lifecycle=0 asahi_m4.cc_pattern=0"
K76=artifacts/m4-linux/bits-7.3-76-diagmask; U76="#76 SMP PREEMPT_DYNAMIC Thu Oct  8 19:29:01 EDT 2026"
D="$BEH asahi_m4.ta_sel6=0 asahi_m4.diag_record=0"
r() { env G16_KEEP_LEASE=1 G16_STEAM_OFFLINE=1 G16_SYNTH_LOAD=1 G16_IO_THROTTLE=50M G16_TAG=$1 G16_KERNEL_ARTIFACT=$K76 "G16_EXPECT_UTS=$U76" G16_BASE_ARGS=asahi_m4.dependency_kind=0 "G16_BOOT_EXTRA=$2" G16_TESTS=dota-quar0 G16_OVERLAY_BASE=/mnt/g16-external/codex-dota-overlay/$1 $R; }
stalls() { local c=0; for d in artifacts/dota-compute-stall-20261007/ro-session/k52-$1-*; do grep -qs "STALL in" $d/codex-dota-*/verdicts.txt && c=$((c+1)); done; echo $c; }
for n in 5 6 7 8; do
    [ $n = 5 ] || r k52-sl-$n "$BEH asahi_m4.ta_sel6=2 asahi_m4.diag_record=0"
    r k52-m03l-$n "$BEH asahi_m4.ta_sel6=0 asahi_m4.diag_mask=0x03"
    r k52-dl-$n "$D"
    echo "load round $n: dl=$(stalls dl) sl=$(stalls sl) m03l=$(stalls m03l)"
done
echo "block 52b done at $(date -Is)"
./artifacts/dota-compute-stall-20261007/ro-session/block50.sh
