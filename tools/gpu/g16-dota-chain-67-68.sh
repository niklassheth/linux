#!/bin/bash
# Manager 16:45: after the #108 Dota timing (63b) -> claude-driver's SPIR-V dump + rmp pair -> blocks 67 then 68 on #111
# (= production #108 + the diag knobs; falls back to #110 if #111 isn't staged within 60 min of claude-driver's release).
cd /home/nsheth/Projects/asahi; H=tmp/leases/history.log; S=artifacts/dota-compute-stall-20261007/ro-session; P63=3672693
while kill -0 $P63 2>/dev/null; do sleep 15; done
s=$(wc -l < $H); t0=$(date +%s); echo "$(date +%T) 63b done; claude-driver slot"
until tail -n +$((s + 1)) $H | grep -q "release mini claude-driver"; do [ $(( $(date +%s) - t0 )) -gt 3000 ] && { echo cap; break; }; sleep 20; done
K=; t0=$(date +%s); until K=$(ls -d artifacts/m4-linux/bits-7.3-111* 2>/dev/null | head -1) && [ -s "$K/UTS" ] && [ -s "$K/Image.gz" ]; do
    [ $(( $(date +%s) - t0 )) -gt 3600 ] && { K=artifacts/m4-linux/bits-7.3-110-renderclass; echo "#111 not staged; using #110"; break; }; sleep 30; done
echo "$(date +%T) kernel for 67/68: $K ($(cat $K/UTS))"
G16_K=$K $S/block67.sh; G16_K=$K $S/block68.sh
echo "chain done $(date -Is)"
