#!/bin/bash
# Block 65 (manager): valid RAC test on #106 (render_after_compute idle test fixed). 4 pairs RAC/CTRL, non-robust desktop,
# load repro, diag_mask=0x04 (held_us in the work log). Runs after block 64 and claude-driver's ~25 min Lethal kernel A/B slot. The first RAC
# run must show render 2816 held (held_us >= 0), else stop.
set -uo pipefail
cd /home/nsheth/Projects/asahi
while [ -n "${WAIT_PID:-}" ] && kill -0 "$WAIT_PID" 2>/dev/null; do sleep 30; done
S=artifacts/dota-compute-stall-20261007/ro-session; R=$S/ro-session.sh; L=tools/lease/lease.sh
BASE="asahi_m4.context_sticky=0 asahi_m4.lifecycle=0 asahi_m4.cc_pattern=0 asahi_m4.ta_sel6=0 asahi_m4.diag_mask=0x04 log_buf_len=8M loglevel=4"
K=artifacts/m4-linux/bits-7.3-106-worksnap-rac; U="#106 SMP PREEMPT_DYNAMIC Fri Oct  9 13:35:50 EDT 2026"
r() { env G16_KEEP_LEASE=1 G16_STEAM_OFFLINE=1 G16_SYNTH_LOAD=1 G16_IO_THROTTLE=50M "G16_WORKLOG_DUMP=116 124 132" G16_DESKTOP_MESA=old G16_TAG=$1 G16_KERNEL_ARTIFACT=$K "G16_EXPECT_UTS=$U" G16_BASE_ARGS=asahi_m4.dependency_kind=0 "G16_BOOT_EXTRA=$BASE $2" G16_TESTS=dota-quar0 G16_OVERLAY_BASE=/mnt/g16-external/codex-dota-overlay/$1 $R
    local v k; v=$(ls -d $S/$1-*/codex-dota-*/verdicts.txt 2>/dev/null | tail -1); k=${v%/verdicts.txt}/kernel.log
    if [ -z "$v" ] || ! grep -q "desktop-mesa libgallium c67094aff03da189" "$v" || ! grep -qE "STALL in|NO-STALL" "$v" || ! grep -q "G16: worklog" "$k"; then
        echo "SETUP FAILURE in $1"; $L release mini codex-dota; exit 1; fi
    h2816=$(grep "worklog submitted.*comm=libkrun.*ordinal=2816 render=true" "$k" | grep -o "held_us=-\?[0-9]*" | head -1)
    echo "$1 ok: $(grep -hE 'STALL' "$v" | head -1) held=$(grep -c 'held_us=[0-9]' "$k") 2816:${h2816:-not-in-log}"; }
for n in 1 2 3 4; do
    r k65-rac-$n asahi_m4.render_after_compute=1
    if [ $n = 1 ] && ! echo "$h2816" | grep -q "held_us=[0-9]"; then echo "RAC did not hold 2816 (${h2816:-absent}); stopping"; $L release mini codex-dota; exit 1; fi
    r k65-ctrl-$n ""
    echo "pair $n: rac=$(grep -ls 'STALL in' $S/k65-rac-*/codex-dota-*/verdicts.txt | wc -l) ctrl=$(grep -ls 'STALL in' $S/k65-ctrl-*/codex-dota-*/verdicts.txt | wc -l)"
done
$L release mini codex-dota
echo "block 65 done at $(date -Is)"
