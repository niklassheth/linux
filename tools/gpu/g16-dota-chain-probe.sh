#!/bin/bash
# After block 45: macOS feasibility probe (XNU guest under m1n1), then the held blocks 41b and 43.
cd /home/nsheth/Projects/asahi/artifacts/dota-compute-stall-20261007/ro-session
while [ -n "${WAIT_PID:-}" ] && kill -0 "$WAIT_PID" 2>/dev/null; do sleep 30; done
unset WAIT_PID
../macos-burst-capture/hv-probe.sh > ../macos-burst-capture/hv-probe-console.log 2>&1
echo "probe done at $(date -Is)"
./block41b.sh > block41b-console.log 2>&1
./block43.sh > block43-console.log 2>&1
echo "chain-probe done at $(date -Is)"
