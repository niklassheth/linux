#!/bin/bash
# Manager: block 49 (#63 Dota-free repros) after block 48 round 2, then block 48 rounds 3-8.
cd /home/nsheth/Projects/asahi/artifacts/dota-compute-stall-20261007/ro-session
while [ -n "${WAIT_PID:-}" ] && kill -0 "$WAIT_PID" 2>/dev/null; do sleep 15; done
unset WAIT_PID
[ -s "$(ls -td k48b-r71-1-* | head -1)/loaded-kernel.txt" ] || { echo "#71 failed to boot in r71-1; stopping chain"; exit 1; }
R48_ROUNDS="1 2" R48_SKIP_ROUND=1 R48_SKIP="t63 r71" ./block48.sh >> block48-console.log 2>&1
./block49.sh >> block49-console.log 2>&1
R48_ROUNDS="3 4 5 6 7 8" ./block48.sh >> block48-console.log 2>&1
echo "chain-48-49 done at $(date -Is)"
