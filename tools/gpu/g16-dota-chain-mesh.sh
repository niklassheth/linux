#!/bin/bash
# Manager: finish block 48 round 3 (M03, M1d), give claude-driver a ~40 min mini slot (Metal mesh M0-M3 captures),
# then block 48 rounds 4-8 and block 50 (replay + Steam).
cd /home/nsheth/Projects/asahi/artifacts/dota-compute-stall-20261007/ro-session
while [ -n "${WAIT_PID:-}" ] && kill -0 "$WAIT_PID" 2>/dev/null; do sleep 15; done
unset WAIT_PID
R48C_ROUNDS=1 R48C_ONLY_ROUND=1 R48C_ONLY="m03 m1d" ./block48.sh >> block48-console.log 2>&1
/home/nsheth/Projects/asahi/tools/lease/lease.sh release mini codex-dota
echo "round 3 done, lease released for claude-driver at $(date -Is)"
sleep 120 # claude-driver's lease waiter (30 s poll) takes the mini; our next ro-session then waits for its release
R48C_ROUNDS="2 3 4 5 6" ./block48.sh >> block48-console.log 2>&1
./block50.sh >> block50-console.log 2>&1
echo "chain-mesh done at $(date -Is)"
