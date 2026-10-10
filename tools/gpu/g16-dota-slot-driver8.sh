#!/bin/bash
# Manager 21:10: ~50 min claude-driver slot (#118 hwdata_macos, #117, thkd-r1 Lethal arms) after block 72's round 2.
cd /home/nsheth/Projects/asahi; L=tools/lease/lease.sh; B=3942088; H=tmp/leases/history.log; S=artifacts/dota-compute-stall-20261007/ro-session
until grep -q "^round 2:" $S/block72-console.log; do sleep 2; done
kill -STOP $B; echo "$(date +%T) block72 paused after round 2"
C=$(pgrep -P $B -f "ro-session[.]sh")
[ -n "$C" ] && { echo "a round-3 run already started ($C); letting it finish"; while [ -d /proc/$C ] && [ "$(awk '{print $3}' /proc/$C/stat)" != Z ]; do sleep 10; done; }
start=$(wc -l < $H)
[ "$($L holder mini | cut -d' ' -f1)" = codex-dota ] && $L release mini codex-dota; echo "$(date +%T) released for claude-driver"
t0=$(date +%s); until tail -n +$((start + 1)) $H | grep -q "release mini claude-driver"; do [ $(( $(date +%s) - t0 )) -gt 4200 ] && { echo cap; break; }; sleep 20; done
echo "$(date +%T) claude-driver slot over; resuming block72"; kill -CONT $B
