#!/bin/bash
# Block 70b (manager 18:15): three-way per round under block-69 conditions (production args, system Mesa for desktop +
# Dota, Steam offline): #108 cd2, #108 cd1 (until decisive: cd2 blocked=0x2 with cd1 clean in one round), and #114
# (queue cap) at defaults. Continue until #114 has >=4 offline runs with zero blocked=0x2, then 2 #114 runs with Steam
# online (#114's Dota ship gate). Relaunched while k70-cd2-1 ran (WAIT_PID); round 1 continues after it.
set -uo pipefail
cd /home/nsheth/Projects/asahi
while kill -0 3817611 2>/dev/null; do sleep 15; done
S=artifacts/dota-compute-stall-20261007/ro-session; R=$S/ro-session.sh; L=tools/lease/lease.sh
K108=artifacts/m4-linux/bits-7.3-108-computedeps2; U108="#108 SMP PREEMPT_DYNAMIC Fri Oct  9 14:05:12 EDT 2026"
K114=artifacts/m4-linux/bits-7.3-114-queuecap; U114=$(sed "s/ (.*//" $K114/UTS)
res() { local v k; v=$(ls -d $S/$1-*/codex-dota-*/verdicts.txt 2>/dev/null | tail -1)
  if [ -z "$v" ] || ! grep -qE "STALL in|NO-STALL" "$v"; then echo "SETUP FAILURE in $1 (skip)"; NB=-1; return; fi
  k=${v%verdicts.txt}kernel.log; NB=$(grep -c 'hang flight.*blocked=0x2' $k); CLEAN=0; grep -q NO-STALL "$v" && CLEAN=1
  echo "$1 ok: $(grep -hE 'STALL' "$v" | head -1 | cut -c1-40) blocked0x2=$NB a4=$(grep -c 'hang flight.*blocked=0x0.*libkrun' $k)"
  grep -q '"buildid" "25817774"' "$v" || { echo "DOTA BUILD CHANGED in $1; stopping"; $L release mini codex-dota; exit 1; }; }
r() { env G16_KEEP_LEASE=1 G16_STEAM_OFFLINE=$3 G16_TAG=$1 G16_KERNEL_ARTIFACT=$2 "G16_EXPECT_UTS=$4" G16_BASE_ARGS=asahi_m4.dependency_kind=0 "G16_BOOT_EXTRA=$5" G16_TESTS=dota-inst G16_OVERLAY_BASE=/mnt/g16-external/codex-dota-overlay/$1 $R; res $1; }
decisive=0; ok114=0; on114=0
res k70-cd2-1; b2=0; [ "$NB" -gt 0 ] && b2=1
for n in 1 2 3 4 5 6; do
  if [ $decisive = 0 ]; then
    [ $n = 1 ] || { r k70-cd2-$n $K108 1 "$U108" ""; b2=0; [ "$NB" -gt 0 ] && b2=1; }
    r k70-cd1-$n $K108 1 "$U108" asahi_m4.compute_deps=1; c1=$CLEAN
    [ $b2 = 1 ] && [ $c1 = 1 ] && { decisive=1; echo "DECISIVE: cd2 blocked=0x2 with cd1 clean in round $n"; }
  fi
  r k70-q114-$n $K114 1 "$U114" ""; [ "$NB" = 0 ] && ok114=$((ok114 + 1))
  echo "round $n: decisive=$decisive #114 offline zero-blocked=$ok114"
  [ $ok114 -ge 4 ] && [ $decisive = 1 -o $n -ge 3 ] && break
done
for m in 1 2; do r k70-q114on-$m $K114 "" "$U114" ""; [ "$NB" = 0 ] && on114=$((on114 + 1)); done
echo "#114 gate: offline zero-blocked $ok114, online zero-blocked $on114/2"
$L release mini codex-dota
echo "block 70b done at $(date -Is)"
