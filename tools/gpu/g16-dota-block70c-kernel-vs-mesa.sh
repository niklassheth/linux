#!/bin/bash
# Block 70b (manager 18:15): three-way per round under block-69 conditions (production args, system Mesa for desktop +
# Dota, Steam offline): #108 cd2, #108 cd1 (until decisive: cd2 blocked=0x2 with cd1 clean in one round), and #114
# (queue cap) at defaults. Continue until #114 has >=4 offline runs with zero blocked=0x2, then 2 #114 runs with Steam
# online (#114's Dota ship gate). Relaunched while k70-cd2-1 ran (WAIT_PID); round 1 continues after it.
set -uo pipefail
cd /home/nsheth/Projects/asahi
while kill -0 3854767 2>/dev/null; do sleep 15; done
S=artifacts/dota-compute-stall-20261007/ro-session; R=$S/ro-session.sh; L=tools/lease/lease.sh
K108=artifacts/m4-linux/bits-7.3-108-computedeps2; U108="#108 SMP PREEMPT_DYNAMIC Fri Oct  9 14:05:12 EDT 2026"
K92=artifacts/m4-linux/bits-7.3-92; U92="#92 SMP PREEMPT_DYNAMIC Fri Oct  9 04:01:44 EDT 2026"
res() { local v k; v=$(ls -d $S/$1-*/codex-dota-*/verdicts.txt 2>/dev/null | tail -1)
  if [ -z "$v" ] || ! grep -qE "STALL in|NO-STALL" "$v"; then echo "SETUP FAILURE in $1 (skip)"; NB=-1; return; fi
  k=${v%verdicts.txt}kernel.log; NB=$(grep -c 'hang flight.*blocked=0x2' $k); CLEAN=0; grep -q NO-STALL "$v" && CLEAN=1
  echo "$1 ok: $(grep -hE 'STALL' "$v" | head -1 | cut -c1-40) blocked0x2=$NB a4=$(grep -c 'hang flight.*blocked=0x0.*libkrun' $k)"
  grep -q '"buildid" "25817774"' "$v" || { echo "DOTA BUILD CHANGED in $1; stopping"; $L release mini codex-dota; exit 1; }; }
r() { env G16_KEEP_LEASE=1 G16_DESKTOP_MESA=${DM:-} G16_STEAM_OFFLINE=$3 G16_TAG=$1 G16_KERNEL_ARTIFACT=$2 "G16_EXPECT_UTS=$4" G16_BASE_ARGS=asahi_m4.dependency_kind=0 "G16_BOOT_EXTRA=$5" G16_TESTS=dota-inst G16_OVERLAY_BASE=/mnt/g16-external/codex-dota-overlay/$1 $R; res $1; }
# Block 70c (18:55): #114 failed (k70-q114-2 blocked=0x2 at render 281 = offline-1's position). Third arm -> production #92
# control under the same conditions (system Mesa ed7603d is also new today). Relaunched while k70-cd2-3 ran.
K111=artifacts/m4-linux/bits-7.3-111-a4diag-on-108; U111=$(sed "s/ (.*//" $K111/UTS)
SNAP="asahi_m4.diag_mask=0x04 asahi_m4.snap_from=270 asahi_m4.snap_to=310 asahi_m4.snap_comm=0x6e75726b62696c log_buf_len=8M loglevel=4"
# Manager 19:00: four arms per round. cd2 now on #111 (= #108 + diag line, same defaults) with worksnap/work logs over Dota
# renders 270-310, so a blocked=0x2 run captures render 281 and neighbours; cd1 on #108; #92 + system Mesa ed7603d;
# #92 + pre-ed7603d system Mesa (eaa2141 backup, bind-mounted for desktop and Dota's system ICD).
res k70-cd2-3
# Manager 19:20: cd1 dropped; #111 cd2 only until one blocked=0x2 capture; #92 new vs old Mesa x3 each.
cap=0; [ "$NB" -gt 0 ] && cap=0   # k70-cd2-3 is #108 (no snaps): doesn't count as a capture
for n in 3 4 5; do
  if [ $cap = 0 ]; then r k70-cd2d-$n $K111 1 "$U111" "$SNAP"; [ "$NB" -gt 0 ] && { cap=1; echo "CAPTURE: blocked=0x2 with snaps in k70-cd2d-$n"; }; fi
  r k70-p92-$n $K92 1 "$U92" ""
  DM=/root/mesa-backup-before-ed7603d r k70-p92old-$n $K92 1 "$U92" ""
  t() { grep -l 'hang flight.*blocked=0x2' $S/k70-$1-*/codex-dota-*/kernel.log 2>/dev/null | wc -l; }
  echo "round $n: blocked=0x2 runs: cd2d=$(t cd2d) p92=$(t p92) p92old=$(t p92old); A4 runs: p92=$(grep -l 'hang flight.*blocked=0x0.*libkrun' $S/k70-p92-*/codex-dota-*/kernel.log 2>/dev/null | wc -l) p92old=$(grep -l 'hang flight.*blocked=0x0.*libkrun' $S/k70-p92old-*/codex-dota-*/kernel.log 2>/dev/null | wc -l)"
done
$L release mini codex-dota
echo "block 70c done at $(date -Is)"
