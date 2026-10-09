#!/bin/bash
# Manager 15:20: after claude-driver's Lethal slot -> block 66 (#108 ship gate) -> claude-driver's short #108 ship-check slot
# -> resume block 67 (paused) -> (dispatcher) block 68. The dispatcher's own block-66 step is disabled (decision "none").
cd /home/nsheth/Projects/asahi; L=tools/lease/lease.sh; B=3572540; H=tmp/leases/history.log; S=artifacts/dota-compute-stall-20261007/ro-session; free=0
while :; do
    if [ "$($L holder mini | cut -d' ' -f1)" = free ]; then free=$((free + 15)); else free=0; fi
    [ $free -ge 90 ] && break; [ "$(date +%H%M)" -ge 1610 ] && { echo "cap"; break; }; sleep 15
done
echo "$(date +%T) claude-driver slot over; block 66 start"; $S/block66.sh
start=$(wc -l < $H); t0=$(date +%s); echo "$(date +%T) block 66 done; claude-driver ship-check slot open"
until tail -n +$((start + 1)) $H | grep -q "release mini claude-driver"; do [ $(( $(date +%s) - t0 )) -gt 3600 ] && { echo "cap"; break; }; sleep 20; done
echo "$(date +%T) claude-driver ship-check slot over; resuming block67"; kill -CONT $B
