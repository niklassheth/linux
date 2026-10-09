#!/bin/bash
# Block 56 (manager; runs after block 57, on the desktop Mesa that reproduced there): host-reply-latency dose-response on #93 (#91 + always-on kind-6/7 event log in the hang report), NO load, Steam offline, diag_record=0, A4-prone behaviour:
#   event_delay_us = 0 / 10000 / 30000 / 100000, x4 each interleaved. Starts after block 55 and the morning hand-offs
#   (claude-kernel Wi-Fi check, claude-driver-mesh capture; manager: before asahi-03's copy): waits for each of their
#   releases after block 55 ends (max 2.5 h), then takes the lease.
set -uo pipefail
cd /home/nsheth/Projects/asahi
while [ -n "${WAIT_PID:-}" ] && kill -0 "$WAIT_PID" 2>/dev/null; do sleep 30; done
D=$(cat artifacts/dota-compute-stall-20261007/ro-session/block56-desktop 2>/dev/null); echo "desktop mesa: [${D:-new}]"
R=artifacts/dota-compute-stall-20261007/ro-session/ro-session.sh
BEH="asahi_m4.context_sticky=0 asahi_m4.lifecycle=0 asahi_m4.cc_pattern=0 asahi_m4.ta_sel6=0 asahi_m4.diag_record=0"
K=artifacts/m4-linux/bits-7.3-93-eventlog; U="#93 SMP PREEMPT_DYNAMIC Fri Oct  9 04:22:43 EDT 2026"
r() { env G16_KEEP_LEASE=1 G16_STEAM_OFFLINE=1 G16_DESKTOP_MESA=$D G16_TAG=$1 G16_KERNEL_ARTIFACT=$K "G16_EXPECT_UTS=$U" G16_BASE_ARGS=asahi_m4.dependency_kind=0 "G16_BOOT_EXTRA=$BEH asahi_m4.event_delay_us=$2" G16_TESTS=dota-quar0 G16_OVERLAY_BASE=/mnt/g16-external/codex-dota-overlay/$1 $R; }
stalls() { local c=0; for d in artifacts/dota-compute-stall-20261007/ro-session/k56-$1-*; do grep -qs "STALL in" $d/codex-dota-*/verdicts.txt && c=$((c+1)); done; echo $c; }
for n in 1 2 3 4; do
    r k56-d0-$n 0
    r k56-d10k-$n 10000
    r k56-d30k-$n 30000
    r k56-d100k-$n 100000
    echo "round $n: d0=$(stalls d0) d10k=$(stalls d10k) d30k=$(stalls d30k) d100k=$(stalls d100k)"
done
/home/nsheth/Projects/asahi/tools/lease/lease.sh release mini codex-dota
echo "block 56 done at $(date -Is)"
