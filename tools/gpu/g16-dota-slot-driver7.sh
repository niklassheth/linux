#!/bin/bash
# Manager 16:40: after the #108 Dota timing (63b) -> claude-kernel's #108 RO boot gate -> claude-driver's SPIR-V dump + rmp pair
# -> resume block 67 (then 68 via the dispatcher).
cd /home/nsheth/Projects/asahi; B67=3572540; H=tmp/leases/history.log; P63=3672693
w() { local who=$1 cap=$2 start t0; start=$3; t0=$(date +%s)
  until tail -n +$((start + 1)) $H | grep -q "release mini $who"; do [ $(( $(date +%s) - t0 )) -gt $cap ] && { echo "cap $who"; break; }; sleep 20; done; }
while kill -0 $P63 2>/dev/null; do sleep 15; done
s=$(wc -l < $H); echo "$(date +%T) 63b done; claude-kernel #108 gate"; w claude-kernel 1800 $s
s=$(wc -l < $H); echo "$(date +%T) claude-kernel over; claude-driver SPIR-V dump + rmp pair"; w claude-driver 3000 $s
echo "$(date +%T) resuming block67"; kill -CONT $B67
