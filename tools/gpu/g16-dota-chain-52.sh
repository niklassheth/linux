#!/bin/bash
# Chain on #52 (history/comm/at= ring): storm session 2, then (if no storm repro) inv2 3-4, fixed x2, first-big.
cd /home/nsheth/Projects/asahi/artifacts/dota-compute-stall-20261007/ro-session
while [ -n "${WAIT_PID:-}" ] && kill -0 "$WAIT_PID" 2>/dev/null; do sleep 15; done
unset WAIT_PID
storm_stalled() { grep -qs "STALL in" k51-storm-*/codex-dota-*/verdicts.txt k52-storm-*/codex-dota-*/verdicts.txt; }
storm_stalled && { echo "storm session 1 reproduced A4; stopping chain for re-plan at $(date -Is)"; exit 0; }
./block38b.sh > block38b-console.log 2>&1
storm_stalled && { echo "storm reproduced A4; stopping chain for re-plan at $(date -Is)"; exit 0; }
./block36c.sh > block36c-console.log 2>&1
./block37b.sh > block37b-console.log 2>&1
./block34b.sh > block34b-console.log 2>&1
echo "chain done at $(date -Is)"
