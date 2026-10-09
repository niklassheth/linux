#!/bin/bash
# Block 55 (manager + claude-kernel #91 5b3f58f = #76 + event_delay_us + pump_prio + ring/control cursors in the hang
# report): host-latency arms, all diag_record=0, Steam offline, A4-prone behaviour args:
#   DE2000: no load, event_delay_us=2000 (does host latency alone trigger A4?)
#   PL:     load (synthetic + 50M cap), pump_prio=2 (FIFO pump: does fast servicing suppress it?)
#   DL91:   load, defaults (same-kernel control for PL)
#   DE10k:  no load, event_delay_us=10000 (dose-response)
# 4 rounds. Starts after claude-driver's queue8 install and claude-kernel's #83 gate have used the mini (waits for a
# claude-kernel release after block 53 ends, max 3 h), then takes the lease.
set -uo pipefail
cd /home/nsheth/Projects/asahi
while [ -n "${WAIT_PID:-}" ] && kill -0 "$WAIT_PID" 2>/dev/null; do sleep 30; done
H=/home/nsheth/Projects/asahi/tmp/leases/history.log; t0=$(date +%s); start=$(wc -l < $H)
until tail -n +$((start + 1)) $H | grep -q "release mini claude-kernel"; do [ $(( $(date +%s) - t0 )) -gt 10800 ] && { echo "no #83 gate seen in 3 h; proceeding"; break; }; sleep 60; done
echo "gate done or timed out at $(date -Is); starting"
R=artifacts/dota-compute-stall-20261007/ro-session/ro-session.sh
BEH="asahi_m4.context_sticky=0 asahi_m4.lifecycle=0 asahi_m4.cc_pattern=0 asahi_m4.ta_sel6=0 asahi_m4.diag_record=0"
K=artifacts/m4-linux/bits-7.3-91-hostlatency; U="#91 SMP PREEMPT_DYNAMIC Fri Oct  9 02:30:35 EDT 2026"
r() { env G16_KEEP_LEASE=1 G16_STEAM_OFFLINE=1 G16_SYNTH_LOAD=${LOAD:-} G16_IO_THROTTLE=${THR:-} G16_TAG=$1 G16_KERNEL_ARTIFACT=$K "G16_EXPECT_UTS=$U" G16_BASE_ARGS=asahi_m4.dependency_kind=0 "G16_BOOT_EXTRA=$BEH $2" G16_TESTS=dota-quar0 G16_OVERLAY_BASE=/mnt/g16-external/codex-dota-overlay/$1 $R; }
stalls() { local c=0; for d in artifacts/dota-compute-stall-20261007/ro-session/k55-$1-*; do grep -qs "STALL in" $d/codex-dota-*/verdicts.txt && c=$((c+1)); done; echo $c; }
for n in 1 2 3 4; do
    r k55-de2000-$n "asahi_m4.event_delay_us=2000"
    [ $n = 1 ] && [ ! -s "$(ls -td artifacts/dota-compute-stall-20261007/ro-session/k55-de2000-1-* | head -1)/loaded-kernel.txt" ] && { echo "#91 failed to boot; stopping"; break; }
    LOAD=1 THR=50M r k55-pl-$n "asahi_m4.pump_prio=2"
    LOAD=1 THR=50M r k55-dl91-$n ""
    r k55-de10k-$n "asahi_m4.event_delay_us=10000"
    echo "round $n: de2000=$(stalls de2000) pl=$(stalls pl) dl91=$(stalls dl91) de10k=$(stalls de10k)"
done
/home/nsheth/Projects/asahi/tools/lease/lease.sh release mini codex-dota
echo "block 55 done at $(date -Is)"
