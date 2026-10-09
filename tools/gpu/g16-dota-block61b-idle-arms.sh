#!/bin/bash
# Block 61b: continues block 61 after k61-ctrl-1; RAC moves to #104 (render_after_compute matches the same tgid).
# Block 61 (manager: idle->busy causal arms), #103 (work log + rebinds + wake snapshots), diag_mask=0x04, non-robust
# desktop 8825824 (~33% A4 under load), Steam offline, synthetic load, 50M cap. Interleaved x5:
#   ID   event_affinity=2 context_sticky=1: Dota's queue keeps its event index and slot across the loading-end idle
#   KA   GPU keepalive: a tiny client submitting every ~20 ms for the whole run (no idle-off between frames)
#   RAC  render_after_compute=1 (#103): the first render after an idle waits for the same VM's in-flight compute
#   CTRL defaults (#103 = #101 with the knob off; baseline with wake snapshots)
# Kernel #103 for all arms.
set -uo pipefail
cd /home/nsheth/Projects/asahi
while [ -n "${WAIT_PID:-}" ] && kill -0 "$WAIT_PID" 2>/dev/null; do sleep 30; done
S=artifacts/dota-compute-stall-20261007/ro-session; R=$S/ro-session.sh
BASE="asahi_m4.lifecycle=0 asahi_m4.cc_pattern=0 asahi_m4.ta_sel6=0 asahi_m4.diag_mask=0x04 log_buf_len=8M loglevel=4"
K=artifacts/m4-linux/bits-7.3-103-renderaftercompute; U="#103 SMP PREEMPT_DYNAMIC Fri Oct  9 11:54:29 EDT 2026"
K104=artifacts/m4-linux/bits-7.3-104-racTgid; U104="#104 SMP PREEMPT_DYNAMIC Fri Oct  9 12:48:12 EDT 2026"
r() { local tag=$1 extra=$2; shift 2
    local k=$K u=$U; case $tag in k61-rac-*) k=$K104 u=$U104 ;; esac
    env G16_KEEP_LEASE=1 G16_STEAM_OFFLINE=1 G16_SYNTH_LOAD=1 G16_IO_THROTTLE=50M "G16_WORKLOG_DUMP=116 124 132" G16_DESKTOP_MESA=old "$@" G16_TAG=$tag G16_KERNEL_ARTIFACT=$k "G16_EXPECT_UTS=$u" G16_BASE_ARGS=asahi_m4.dependency_kind=0 "G16_BOOT_EXTRA=$BASE $extra" G16_TESTS=dota-quar0 G16_OVERLAY_BASE=/mnt/g16-external/codex-dota-overlay/$tag $R; }
chk() { local v k; v=$(ls -d $S/$1-*/codex-dota-*/verdicts.txt 2>/dev/null | tail -1); k=${v%/verdicts.txt}/kernel.log
    if [ -z "$v" ] || ! grep -q "desktop-mesa libgallium c67094aff03da189" "$v" || ! grep -qE "STALL in|NO-STALL" "$v" || ! grep -q "G16: worklog" "$k"; then
        echo "SETUP FAILURE in $1 (verdicts=$v)"; tools/lease/lease.sh release mini codex-dota; exit 1; fi
    case $1 in *-ka-*) n=$(grep -h '^keepalive:' "$v" | awk '{print $2}'); [ "${n:-0}" -gt 1000 ] || { echo "SETUP FAILURE in $1 (keepalive submits=${n:-0})"; tools/lease/lease.sh release mini codex-dota; exit 1; } ;; esac
    echo "$1 ok: $(grep -hE "STALL" "$v" | head -1) wakes=$(grep -c 'G16: worklog wake' "$k") held=$(grep -c 'held_us=[0-9]' "$k") $(grep -h '^keepalive:' "$v")"; }
stalls() { local c=0; for d in $S/k61-$1-*; do grep -qs "STALL in" $d/codex-dota-*/verdicts.txt && c=$((c+1)); done; echo $c; }
# Manager 13:25: cut to RAC/CTRL rounds 2-3, block 62 dropped, claude-driver window after round 3.
# Manager plan (13:00): after round 1 only RAC vs CTRL; block 62 (synthetic) after round 2; a ~45 min claude-driver window
# after round 4; any RAC stall stops the block at once.
L=tools/lease/lease.sh; H=tmp/leases/history.log
rac() { r k61-rac-$1 "asahi_m4.context_sticky=0 asahi_m4.render_after_compute=1"; chk k61-rac-$1
    if grep -qs "STALL in" $S/k61-rac-$1-*/codex-dota-*/verdicts.txt; then echo "RAC STALLED in k61-rac-$1: hypothesis killed; stopping"; $L release mini codex-dota; exit 0; fi; }
# Relaunched while k61-rac-2 was running (WAIT_PID = that session): check it, then continue.
chk k61-rac-2
if grep -qs "STALL in" $S/k61-rac-2-*/codex-dota-*/verdicts.txt; then echo "RAC STALLED in k61-rac-2: hypothesis killed; stopping"; $L release mini codex-dota; exit 0; fi
for n in 2 3; do
    [ $n = 2 ] || rac $n
    r k61-ctrl-$n "asahi_m4.context_sticky=0"; chk k61-ctrl-$n
    echo "round $n: rac(#104, from 2)=$(stalls rac) ctrl=$(stalls ctrl) id=$(stalls id) ka=$(stalls ka)"
    if [ $n = 3 ]; then
        $L release mini codex-dota; start=$(wc -l < $H); t0=$(date +%s); echo "claude-driver window open $(date +%T)"
        until tail -n +$((start + 1)) $H | grep -q "release mini claude-driver"; do [ $(( $(date +%s) - t0 )) -gt 3300 ] && break; sleep 30; done
        echo "claude-driver window closed $(date +%T)"
    fi
done
tools/lease/lease.sh release mini codex-dota
echo "block 61 done at $(date -Is)"
