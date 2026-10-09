#!/bin/bash
# Block 66 (claude-kernel, ship gate for #108): compute_deps=2 (firmware items only for a compute's waits on its own
# queue's render lanes) vs compute_deps=1 (in-kernel control) on #108 (= production #92 + pump_prio + mode 2 default),
# through the A4 repro: non-robust desktop, Steam offline, synthetic load, 50M cap, A4-prone args as blocks 52-61.
# 5 interleaved pairs. No diag logs on this production-based kernel.
set -uo pipefail
cd /home/nsheth/Projects/asahi
while [ -n "${WAIT_PID:-}" ] && kill -0 "$WAIT_PID" 2>/dev/null; do sleep 30; done
S=artifacts/dota-compute-stall-20261007/ro-session; R=$S/ro-session.sh; L=tools/lease/lease.sh
BASE="asahi_m4.context_sticky=0 asahi_m4.lifecycle=0 asahi_m4.cc_pattern=0 asahi_m4.ta_sel6=0"
K=artifacts/m4-linux/bits-7.3-108-computedeps2; U="#108 SMP PREEMPT_DYNAMIC Fri Oct  9 14:05:12 EDT 2026"
r() { env G16_KEEP_LEASE=1 G16_STEAM_OFFLINE=1 G16_SYNTH_LOAD=1 G16_IO_THROTTLE=50M G16_DESKTOP_MESA=old G16_TAG=$1 G16_KERNEL_ARTIFACT=$K "G16_EXPECT_UTS=$U" G16_BASE_ARGS=asahi_m4.dependency_kind=0 "G16_BOOT_EXTRA=$BASE $2" G16_TESTS=dota-quar0 G16_OVERLAY_BASE=/mnt/g16-external/codex-dota-overlay/$1 $R
    local v; v=$(ls -d $S/$1-*/codex-dota-*/verdicts.txt 2>/dev/null | tail -1)
    if [ -z "$v" ] || ! grep -q "desktop-mesa libgallium c67094aff03da189" "$v" || ! grep -qE "STALL in|NO-STALL" "$v"; then echo "SETUP FAILURE in $1 (counted as skip)"; return; fi
    echo "$1 ok: $(grep -hE 'STALL' "$v" | head -1)"; }
n_st() { grep -ls 'STALL in' $S/k66-$1-*/codex-dota-*/verdicts.txt 2>/dev/null | wc -l; }
for n in 1 2 3 4 5; do
    r k66-cd2-$n ""
    r k66-cd1-$n asahi_m4.compute_deps=1
    echo "pair $n: cd2=$(n_st cd2) cd1=$(n_st cd1)"
done
# #108 ship check: the per-pass Dota timing (as k63-pass-1 on #92) on #108; releases the lease at its end.
$S/block63b.sh
echo "block 66 done at $(date -Is)"
