#!/bin/bash
# Block 70 (claude-kernel): is the blocked=0x2 non-retirement (firmware notifier stops; k69-offline-1) caused by #108's
# compute_deps=2? Block-69 conditions (production args, system Mesa ed7603d for desktop + Dota, Steam offline, no load)
# on #108 with compute_deps=1 vs default (2), interleaved x3, stop on the first pair with cd2 blocked=0x2 and cd1 clean. Reports blocked=0x2 flights per run.
set -uo pipefail
cd /home/nsheth/Projects/asahi
while [ -n "${WAIT_PID:-}" ] && kill -0 "$WAIT_PID" 2>/dev/null; do sleep 30; done
S=artifacts/dota-compute-stall-20261007/ro-session; R=$S/ro-session.sh; L=tools/lease/lease.sh
K=artifacts/m4-linux/bits-7.3-108-computedeps2; U="#108 SMP PREEMPT_DYNAMIC Fri Oct  9 14:05:12 EDT 2026"
for n in 1 2 3; do
  b2=0; c1clean=0
  for arm in cd2 cd1; do
    t=k70-$arm-$n; x=; [ $arm = cd1 ] && x=asahi_m4.compute_deps=1
    env G16_KEEP_LEASE=1 G16_STEAM_OFFLINE=1 G16_TAG=$t G16_KERNEL_ARTIFACT=$K "G16_EXPECT_UTS=$U" G16_BASE_ARGS=asahi_m4.dependency_kind=0 "G16_BOOT_EXTRA=$x" G16_TESTS=dota-inst G16_OVERLAY_BASE=/mnt/g16-external/codex-dota-overlay/$t $R
    v=$(ls -d $S/$t-*/codex-dota-*/verdicts.txt 2>/dev/null | tail -1)
    if [ -z "$v" ] || ! grep -qE "STALL in|NO-STALL" "$v"; then echo "SETUP FAILURE in $t (skip)"; continue; fi
    k=${v%verdicts.txt}kernel.log
    nb=$(grep -c 'hang flight.*blocked=0x2' $k)
    echo "$t ok: $(grep -hE 'STALL' "$v" | head -1 | cut -c1-40) blocked0x2=$nb a4=$(grep -c 'hang flight.*blocked=0x0.*libkrun' $k)"
    [ $arm = cd2 ] && [ "$nb" -gt 0 ] && b2=1
    [ $arm = cd1 ] && grep -q "NO-STALL" "$v" && c1clean=1
  done
  echo "pair $n: cd2 blocked0x2=$b2, cd1 clean=$c1clean"
  if [ $b2 = 1 ] && [ $c1clean = 1 ]; then echo "DECISIVE: cd2 reproduced blocked=0x2 and cd1 was clean in pair $n; stopping"; break; fi
done
$L release mini codex-dota
echo "block 70 done at $(date -Is)"
