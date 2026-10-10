#!/bin/bash
# Block 72 (manager factor sweep): why ~60% A4 on production vs ~5% in blocks 55-59 (robust desktop)? Steam offline, system
# ICD for Dota (inst), system Mesa desktop, production args (on #92 sticky/lifecycle/cc_pattern defaults = the 55-59 args).
#   A  #92 production
#   C  #92 + synthetic dd+zstd load + IOReadBandwidthMax=50M on g16-steam (the exact 55-59 load conditions)
#   D  #76 (the 55-59 kernel line, test/ta-sel6-68) with diag_record=0, no load
#   E  #92 production with Dota launched -nosound (claude-kernel: #68->#92 differ only in MCA audio, BT resume, brcmfmac)
# 4 runs per arm, interleaved. Starts after claude-driver's Lethal slot (release mini claude-driver).
set -uo pipefail
cd /home/nsheth/Projects/asahi
while [ -n "${WAIT_PID:-}" ] && kill -0 "$WAIT_PID" 2>/dev/null; do sleep 30; done
H=tmp/leases/history.log; start=$(wc -l < $H); t0=$(date +%s)
until tail -n +$((start + 1)) $H | grep -q "release mini claude-driver"; do [ $(( $(date +%s) - t0 )) -gt 3600 ] && { echo "driver slot wait capped"; break; }; sleep 30; done
echo "claude-driver slot over $(date +%T)"
S=artifacts/dota-compute-stall-20261007/ro-session; R=$S/ro-session.sh; L=tools/lease/lease.sh
K92=artifacts/m4-linux/bits-7.3-92; U92="#92 SMP PREEMPT_DYNAMIC Fri Oct  9 04:01:44 EDT 2026"
K76=artifacts/m4-linux/bits-7.3-76-diagmask; U76="#76 SMP PREEMPT_DYNAMIC Thu Oct  8 19:29:01 EDT 2026"
r() { env G16_KEEP_LEASE=1 G16_STEAM_OFFLINE=1 "$@" $R; }
for n in 1 2 3 4; do
  for arm in A C D E; do
    t=k72-$arm-$n
    case $arm in
      A) r G16_TAG=$t G16_KERNEL_ARTIFACT=$K92 "G16_EXPECT_UTS=$U92" G16_BASE_ARGS=asahi_m4.dependency_kind=0 G16_TESTS=dota-inst G16_OVERLAY_BASE=/mnt/g16-external/codex-dota-overlay/$t ;;
      C) r G16_SYNTH_LOAD=1 G16_IO_THROTTLE=50M G16_TAG=$t G16_KERNEL_ARTIFACT=$K92 "G16_EXPECT_UTS=$U92" G16_BASE_ARGS=asahi_m4.dependency_kind=0 G16_TESTS=dota-inst G16_OVERLAY_BASE=/mnt/g16-external/codex-dota-overlay/$t ;;
      E) r G16_DOTA_NOSOUND=1 G16_TAG=$t G16_KERNEL_ARTIFACT=$K92 "G16_EXPECT_UTS=$U92" G16_BASE_ARGS=asahi_m4.dependency_kind=0 G16_TESTS=dota-inst G16_OVERLAY_BASE=/mnt/g16-external/codex-dota-overlay/$t ;;
      D) r G16_TAG=$t G16_KERNEL_ARTIFACT=$K76 "G16_EXPECT_UTS=$U76" G16_BASE_ARGS=asahi_m4.dependency_kind=0 G16_BOOT_EXTRA=asahi_m4.diag_record=0 G16_TESTS=dota-inst G16_OVERLAY_BASE=/mnt/g16-external/codex-dota-overlay/$t ;;
    esac
    v=$(ls -d $S/$t-*/codex-dota-*/verdicts.txt 2>/dev/null | tail -1)
    if [ -z "$v" ] || ! grep -qE "STALL in|NO-STALL" "$v"; then echo "SETUP FAILURE in $t (skip)"; continue; fi
    k=${v%verdicts.txt}kernel.log
    echo "$t ok: $(grep -hE 'STALL' "$v" | head -1 | cut -c1-40) a4=$(grep -c 'hang flight.*blocked=0x0.*libkrun' $k) blocked0x2=$(grep -c 'hang flight.*blocked=0x2' $k) $(grep -h '^audio-cards\|^dota-nosound' "$v" | tr '\n' ' ' | cut -c1-90)"
  done
  echo "round $n: A=$(grep -ls 'STALL in' $S/k72-A-*/codex-dota-*/verdicts.txt 2>/dev/null | wc -l) C=$(grep -ls 'STALL in' $S/k72-C-*/codex-dota-*/verdicts.txt 2>/dev/null | wc -l) D=$(grep -ls 'STALL in' $S/k72-D-*/codex-dota-*/verdicts.txt 2>/dev/null | wc -l) E=$(grep -ls 'STALL in' $S/k72-E-*/codex-dota-*/verdicts.txt 2>/dev/null | wc -l)"
done
$L release mini codex-dota
echo "block 72 done at $(date -Is)"
