#!/bin/bash
# Block 69 (manager): pure-production A4 rate. Production #108 (artifacts/m4-linux/current) with production args only,
# system Mesa ed7603d for the desktop AND for Dota (variant inst = system ICD through the FEX thunks), robust KWin, no
# synthetic load, no diag. Arms: ONLINE (Steam online; the per-boot overlay makes Steam re-validate/download, i.e. the
# natural update load) vs OFFLINE (Steam offline, quiet). 3 each, interleaved.
set -uo pipefail
cd /home/nsheth/Projects/asahi
while [ -n "${WAIT_PID:-}" ] && kill -0 "$WAIT_PID" 2>/dev/null; do sleep 30; done
# Manager: ~45 min macOS HV slot for claude-driver/claude-kernel (Metal kind-4 recovery capture, xspin) after block 68.
# Wait for some other owner to acquire and then release the mini (cap 70 min).
H=tmp/leases/history.log; start=$(wc -l < $H); t0=$(date +%s)
until tail -n +$((start + 1)) $H | grep -E " acquire mini " | grep -vq " codex-dota " 2>/dev/null && tail -n +$((start + 1)) $H | grep -E " release mini " | grep -vq " codex-dota$"; do
    [ $(( $(date +%s) - t0 )) -gt 4200 ] && { echo "HV slot wait capped"; break; }; sleep 30; done
echo "HV capture slot over $(date +%T)"
S=artifacts/dota-compute-stall-20261007/ro-session; R=$S/ro-session.sh; L=tools/lease/lease.sh
K=artifacts/m4-linux/current; U="#108 SMP PREEMPT_DYNAMIC Fri Oct  9 14:05:12 EDT 2026"
for n in 1 2 3; do
  for arm in online offline; do
    t=k69-$arm-$n; off=; [ $arm = offline ] && off=1
    env G16_KEEP_LEASE=1 G16_STEAM_OFFLINE=$off G16_TAG=$t G16_KERNEL_ARTIFACT=$K "G16_EXPECT_UTS=$U" G16_BASE_ARGS=asahi_m4.dependency_kind=0 G16_TESTS=dota-inst G16_OVERLAY_BASE=/mnt/g16-external/codex-dota-overlay/$t $R
    v=$(ls -d $S/$t-*/codex-dota-*/verdicts.txt 2>/dev/null | tail -1)
    if [ -z "$v" ] || ! grep -qE "STALL in|NO-STALL" "$v"; then echo "SETUP FAILURE in $t (skip)"; continue; fi
    dl=$(grep -ch "Downloading\|Update Required\|Validating" ${v%/verdicts.txt}/steam-logs/content_log.txt 2>/dev/null)
    echo "$t ok: $(grep -hE 'STALL' "$v" | head -1) steam-content-lines=$dl $(grep -h '^driver-stamp' "$v" | cut -c1-90)"
    # Steam online must not update Dota itself (the library on the external disk is real, not the overlay).
    if ! grep -q '"buildid" "25817774"' "$v"; then echo "DOTA BUILD CHANGED in $t: $(grep -h '^dota-build' "$v" | cut -c1-120); stopping"; $L release mini codex-dota; exit 1; fi
  done
  echo "round $n: online=$(grep -ls 'STALL in' $S/k69-online-*/codex-dota-*/verdicts.txt 2>/dev/null | wc -l) offline=$(grep -ls 'STALL in' $S/k69-offline-*/codex-dota-*/verdicts.txt 2>/dev/null | wc -l)"
done
$L release mini codex-dota
echo "block 69 done at $(date -Is)"
