#!/bin/bash
# After block 64: claude-driver's Lethal slot, then block 67 (manager: render_preempt=0 vs default on #109), then claude-driver's Lethal slot (#107 A/B/C + #108), then (manager) block 66 (#108 A4 ship gate) before
# block 65 if #108 restores Lethal fps, else block 65 only. Decision file: ro-session/next-after-driver = "66" or "65"
# (written by claude-dota from claude-driver's result; default 65 after a 30 min wait).
cd /home/nsheth/Projects/asahi
while [ -n "${WAIT_PID:-}" ] && kill -0 "$WAIT_PID" 2>/dev/null; do sleep 30; done
S=artifacts/dota-compute-stall-20261007/ro-session; H=tmp/leases/history.log; start=$(wc -l < $H); t0=$(date +%s)
until tail -n +$((start + 1)) $H | grep -q "release mini claude-driver"; do [ $(( $(date +%s) - t0 )) -gt 3600 ] && break; sleep 30; done
echo "claude-driver slot over $(date +%T)"
echo "block 67 (#110 defaults) start $(date +%T)"; $S/block67.sh; echo "block 68 (render_class=2 vs default) start $(date +%T)"; $S/block68.sh
t1=$(date +%s); until [ -s $S/next-after-driver ]; do [ $(( $(date +%s) - t1 )) -gt 1800 ] && echo none > $S/next-after-driver; sleep 20; done
d=$(cat $S/next-after-driver); echo "decision: $d ($(date +%T))"
# Manager 15:05: block 65 (RAC) dropped.
if [ "$d" = 66 ]; then $S/block66.sh; else echo "block 66 skipped (#108 does not help Lethal)"; fi
echo "dispatch done $(date -Is)"
