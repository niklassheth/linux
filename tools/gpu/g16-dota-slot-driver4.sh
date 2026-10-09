#!/bin/bash
# Manager 16:25: block 66 stopped after the running run -> claude-driver's #108 ship checks -> #108 Dota timing (63b) ->
# resume block 67 (paused).
cd /home/nsheth/Projects/asahi; L=tools/lease/lease.sh; B67=3572540; C=3655049; H=tmp/leases/history.log; S=artifacts/dota-compute-stall-20261007/ro-session
while [ -d /proc/$C ] && [ "$(awk '{print $3}' /proc/$C/stat)" != Z ]; do sleep 10; done
start=$(wc -l < $H)
[ "$($L holder mini | cut -d' ' -f1)" = codex-dota ] && $L release mini codex-dota
echo "$(date +%T) block 66 stopped early (manager); claude-driver ship-check slot open"
t0=$(date +%s); until tail -n +$((start + 1)) $H | grep -q "release mini claude-driver"; do [ $(( $(date +%s) - t0 )) -gt 3600 ] && { echo cap; break; }; sleep 20; done
echo "$(date +%T) claude-driver ship checks over; block 63b (#108 Dota timing)"; $S/block63b.sh
echo "$(date +%T) resuming block67"; kill -CONT $B67
