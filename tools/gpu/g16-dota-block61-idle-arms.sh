#!/bin/bash
# Block 61 (manager: idle->busy causal arms), #101 (work log + rebinds + wake snapshots), diag_mask=0x04, non-robust
# desktop 8825824 (~33% A4 under load), Steam offline, synthetic load, 50M cap. Interleaved x5:
#   ID   event_affinity=2 context_sticky=1: Dota's queue keeps its event index and slot across the loading-end idle
#   KA   GPU keepalive: a tiny client submitting every ~20 ms for the whole run (no idle-off between frames)
#   CTRL #101 defaults (baseline with wake snapshots)
set -uo pipefail
cd /home/nsheth/Projects/asahi
while [ -n "${WAIT_PID:-}" ] && kill -0 "$WAIT_PID" 2>/dev/null; do sleep 30; done
S=artifacts/dota-compute-stall-20261007/ro-session; R=$S/ro-session.sh
BASE="asahi_m4.lifecycle=0 asahi_m4.cc_pattern=0 asahi_m4.ta_sel6=0 asahi_m4.diag_mask=0x04 log_buf_len=8M loglevel=4"
K=artifacts/m4-linux/bits-7.3-101-worklog2; U="#101 SMP PREEMPT_DYNAMIC Fri Oct  9 11:33:00 EDT 2026"
r() { local tag=$1 extra=$2; shift 2
    env G16_KEEP_LEASE=1 G16_STEAM_OFFLINE=1 G16_SYNTH_LOAD=1 G16_IO_THROTTLE=50M "G16_WORKLOG_DUMP=116 124 132" G16_DESKTOP_MESA=old "$@" G16_TAG=$tag G16_KERNEL_ARTIFACT=$K "G16_EXPECT_UTS=$U" G16_BASE_ARGS=asahi_m4.dependency_kind=0 "G16_BOOT_EXTRA=$BASE $extra" G16_TESTS=dota-quar0 G16_OVERLAY_BASE=/mnt/g16-external/codex-dota-overlay/$tag $R; }
chk() { local v k; v=$(ls -d $S/$1-*/codex-dota-*/verdicts.txt 2>/dev/null | tail -1); k=${v%/verdicts.txt}/kernel.log
    if [ -z "$v" ] || ! grep -q "desktop-mesa libgallium c67094aff03da189" "$v" || ! grep -qE "STALL in|NO-STALL" "$v" || ! grep -q "G16: worklog" "$k"; then
        echo "SETUP FAILURE in $1 (verdicts=$v)"; tools/lease/lease.sh release mini codex-dota; exit 1; fi
    case $1 in *-ka-*) n=$(grep -h '^keepalive:' "$v" | awk '{print $2}'); [ "${n:-0}" -gt 1000 ] || { echo "SETUP FAILURE in $1 (keepalive submits=${n:-0})"; tools/lease/lease.sh release mini codex-dota; exit 1; } ;; esac
    echo "$1 ok: $(grep -hE "STALL" "$v" | head -1) wakes=$(grep -c 'G16: worklog wake' "$k") $(grep -h '^keepalive:' "$v")"; }
stalls() { local c=0; for d in $S/k61-$1-*; do grep -qs "STALL in" $d/codex-dota-*/verdicts.txt && c=$((c+1)); done; echo $c; }
for n in 1 2 3 4 5; do
    r k61-id-$n "asahi_m4.context_sticky=1 asahi_m4.event_affinity=2"; chk k61-id-$n
    r k61-ka-$n "asahi_m4.context_sticky=0" G16_KEEPALIVE=1; chk k61-ka-$n
    r k61-ctrl-$n "asahi_m4.context_sticky=0"; chk k61-ctrl-$n
    echo "round $n: id=$(stalls id) ka=$(stalls ka) ctrl=$(stalls ctrl)"
done
tools/lease/lease.sh release mini codex-dota
echo "block 61 done at $(date -Is)"
