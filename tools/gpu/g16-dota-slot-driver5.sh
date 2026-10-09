#!/bin/bash
# After claude-driver's #108 ship checks: claude-kernel's ~5 min #108 RO boot gate, then the #108 Dota timing (63b), then resume
# block 67 (paused).
cd /home/nsheth/Projects/asahi; L=tools/lease/lease.sh; B67=3572540; H=tmp/leases/history.log; S=artifacts/dota-compute-stall-20261007/ro-session
start=$(wc -l < $H); t0=$(date +%s)
until tail -n +$((start + 1)) $H | grep -q "release mini claude-driver"; do [ $(( $(date +%s) - t0 )) -gt 3600 ] && { echo cap; break; }; sleep 20; done
echo "$(date +%T) claude-driver ship checks over; claude-kernel #108 boot gate"
start=$(wc -l < $H); t0=$(date +%s)
until tail -n +$((start + 1)) $H | grep -q "release mini claude-kernel"; do [ $(( $(date +%s) - t0 )) -gt 1800 ] && { echo cap; break; }; sleep 20; done
echo "$(date +%T) claude-kernel gate over; block 63b (#108 Dota timing)"; $S/block63b.sh
echo "$(date +%T) resuming block67"; kill -CONT $B67
