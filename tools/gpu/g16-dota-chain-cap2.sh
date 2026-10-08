#!/bin/bash
# After chain-cap (capture run 1 compile-failed): rerun the traced Metal burst capture with the fixed xburst.m.
cd /home/nsheth/Projects/asahi/artifacts/dota-compute-stall-20261007/ro-session
while [ -n "${WAIT_PID:-}" ] && kill -0 "$WAIT_PID" 2>/dev/null; do sleep 15; done
../macos-burst-capture/hv-capture.sh > ../macos-burst-capture/hv-capture2-console.log 2>&1
echo "chain-cap2 done at $(date -Is)"
