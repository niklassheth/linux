#!/bin/bash
# Block 52 (manager, after the Steam-download finding): 1) dedicated Steam update window (Steam online alone, no Dota,
# until the pending CS2/Dota updates are installed); 2) quiet base, Steam OFFLINE in every arm: D (#76 diag_record=0) x4
# vs DL (D + synthetic Steam-like load during loading: 50 MB/s read cap + direct sequential reads + zstd -19 -T4) x4;
# 3) if DL reproduces A4 (>=2/4 and more than D): SL (ta_sel6=2 + load), M03L (diag_mask=0x03 + load), DL x4 each;
# 4) block 50 (replay + Steam, offline).
set -uo pipefail
cd /home/nsheth/Projects/asahi
while [ -n "${WAIT_PID:-}" ] && kill -0 "$WAIT_PID" 2>/dev/null; do sleep 15; done
unset WAIT_PID
R=artifacts/dota-compute-stall-20261007/ro-session/ro-session.sh
BEH="asahi_m4.context_sticky=0 asahi_m4.lifecycle=0 asahi_m4.cc_pattern=0"
K76=artifacts/m4-linux/bits-7.3-76-diagmask; U76="#76 SMP PREEMPT_DYNAMIC Thu Oct  8 19:29:01 EDT 2026"
D="$BEH asahi_m4.ta_sel6=0 asahi_m4.diag_record=0"
r() { env G16_KEEP_LEASE=1 G16_STEAM_OFFLINE=${OFF:-1} G16_SYNTH_LOAD=${LOAD:-} G16_IO_THROTTLE=${THR:-} G16_TAG=$1 G16_KERNEL_ARTIFACT=$K76 "G16_EXPECT_UTS=$U76" G16_BASE_ARGS=asahi_m4.dependency_kind=0 "G16_BOOT_EXTRA=$2" G16_TESTS=${3:-dota-quar0} G16_OVERLAY_BASE=/mnt/g16-external/codex-dota-overlay/$1 $R; }
stalls() { local c=0; for d in artifacts/dota-compute-stall-20261007/ro-session/k52-$1-*; do grep -qs "STALL in" $d/codex-dota-*/verdicts.txt && c=$((c+1)); done; echo $c; }
OFF=0 r k52-steamupd-1 "$D" steam-update
for n in 1 2 3 4; do
    r k52-d-$n "$D"
    LOAD=1 THR=50M r k52-dl-$n "$D"
    echo "base round $n: d=$(stalls d) dl=$(stalls dl)"
done
if [ "$(stalls dl)" -ge 2 ] && [ "$(stalls dl)" -gt "$(stalls d)" ]; then
    echo "DL reproduces A4; A/B under load"
    for n in 5 6 7 8; do
        LOAD=1 THR=50M r k52-sl-$n "$BEH asahi_m4.ta_sel6=2 asahi_m4.diag_record=0"
        LOAD=1 THR=50M r k52-m03l-$n "$BEH asahi_m4.ta_sel6=0 asahi_m4.diag_mask=0x03"
        LOAD=1 THR=50M r k52-dl-$n "$D"
        echo "load round $n: dl=$(stalls dl) sl=$(stalls sl) m03l=$(stalls m03l)"
    done
fi
echo "block 52 done at $(date -Is)"
./artifacts/dota-compute-stall-20261007/ro-session/block50.sh
