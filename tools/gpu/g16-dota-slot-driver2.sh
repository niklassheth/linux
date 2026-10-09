#!/bin/bash
# Manager: pause block 67 after k67-def-2 for claude-driver's ~35-40 min #107/#108 Lethal slot, then resume.
cd /home/nsheth/Projects/asahi; L=tools/lease/lease.sh; B=3572540; C=3578621; H=tmp/leases/history.log
kill -STOP $B; echo "$(date +%T) block67 stopped; waiting for k67-def-2 ($C)"
while [ -d /proc/$C ] && [ "$(awk '{print $3}' /proc/$C/stat)" != Z ]; do sleep 10; done
start=$(wc -l < $H)
[ "$($L holder mini | cut -d' ' -f1)" = codex-dota ] && $L release mini codex-dota; echo "$(date +%T) released for claude-driver"
t0=$(date +%s)
until tail -n +$((start + 1)) $H | grep -q "release mini claude-driver"; do [ $(( $(date +%s) - t0 )) -gt 3300 ] && { echo "cap"; break; }; sleep 20; done
echo "$(date +%T) claude-driver done; resuming block67"; kill -CONT $B
