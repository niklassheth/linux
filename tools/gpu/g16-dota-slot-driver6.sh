#!/bin/bash
# claude-kernel #108 gate (running) -> claude-driver ~10 min (Lethal thunk VK_LOADER_DEBUG + capture-card check) -> #108 Dota
# timing (63b) -> resume block 67.
cd /home/nsheth/Projects/asahi; B67=3572540; H=tmp/leases/history.log; S=artifacts/dota-compute-stall-20261007/ro-session
w() { local who=$1 cap=$2 start t0; start=$(wc -l < $H); t0=$(date +%s)
  until tail -n +$((start + 1)) $H | grep -q "release mini $who"; do [ $(( $(date +%s) - t0 )) -gt $cap ] && { echo "cap $who"; break; }; sleep 20; done; }
grep -q "release mini claude-kernel" <(tail -n 3 $H) || w claude-kernel 1800
echo "$(date +%T) claude-kernel gate over; claude-driver short slot"; w claude-driver 1500
echo "$(date +%T) claude-driver over; block 63b (#108 Dota timing)"; $S/block63b.sh
echo "$(date +%T) resuming block67"; kill -CONT $B67
