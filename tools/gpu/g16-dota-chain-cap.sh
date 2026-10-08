#!/bin/bash
# After the macOS probe: yield to claude-kernel's R5 slot, then the traced Metal burst capture, then blocks 41b and 43.
cd /home/nsheth/Projects/asahi/artifacts/dota-compute-stall-20261007/ro-session
while [ -n "${WAIT_PID:-}" ] && kill -0 "$WAIT_PID" 2>/dev/null; do sleep 15; done
unset WAIT_PID
sleep 75 # let claude-kernel's lease waiter (30 s poll) take the gap first
../macos-burst-capture/hv-capture.sh > ../macos-burst-capture/hv-capture-console.log 2>&1
echo "capture done at $(date -Is)"
sleep 20
./block41b.sh > block41b-console.log 2>&1
./block43.sh > block43-console.log 2>&1
echo "chain-cap done at $(date -Is)"
