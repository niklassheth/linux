#!/bin/bash
# Manager: second claude-driver mesh slot (~20 min, parameter sweep) after block 48 round 4; then rounds 5-8 and block 50.
cd /home/nsheth/Projects/asahi/artifacts/dota-compute-stall-20261007/ro-session
while [ -n "${WAIT_PID:-}" ] && kill -0 "$WAIT_PID" 2>/dev/null; do sleep 15; done
unset WAIT_PID
R48C_ROUNDS=2 R48C_ONLY_ROUND=2 R48C_ONLY="s r m23 m03 m1d" ./block48.sh >> block48-console.log 2>&1
/home/nsheth/Projects/asahi/tools/lease/lease.sh release mini codex-dota
echo "round 4 done, lease released for claude-driver (sweep) at $(date -Is)"
sleep 120
R48C_ROUNDS="3 4 5 6" ./block48.sh >> block48-console.log 2>&1
./block50.sh >> block50-console.log 2>&1
echo "chain-mesh2 done at $(date -Is)"
