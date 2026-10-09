#!/bin/bash
# Wrapper (called at the end of block 53): block 54 (M01L/M03L/M13L split) first, then the replay+Steam block only if
# it is still before 05:00 (leaves the morning for claude-driver's queue8 install, claude-kernel's #83 gate, asahi-03).
cd /home/nsheth/Projects/asahi/artifacts/dota-compute-stall-20261007/ro-session
./block54.sh >> block54-console.log 2>&1
if [ "$(date +%H)" -lt 5 ]; then ./block50-replay-steam.sh >> block50-console.log 2>&1; else echo "skipping block 50 (late)"; fi
/home/nsheth/Projects/asahi/tools/lease/lease.sh release mini codex-dota
echo "night queue done at $(date -Is)"
