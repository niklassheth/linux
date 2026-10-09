#!/bin/bash
# Block 59 (manager plan (b)): what a non-robust KWin does around Dota's loading-end burst. #100 (work logs), diag_mask=0x04
# only (retire log 2048 + submit ring + per-queue cursors; dumped at hang and on demand at +175/185/195 s after dota-game).
# Desktop: NON-ROBUST 8825824 (bind-mounted /root backup; ~33% A4 under load) vs ROBUST eaa2141 (host-staged pinned tree).
# Load repro: Steam offline, synthetic load, 50M cap. Interleaved x6. Aborts on setup failure (no verdict, wrong
# libgallium, or no work-log dump).
set -uo pipefail
cd /home/nsheth/Projects/asahi
while [ -n "${WAIT_PID:-}" ] && kill -0 "$WAIT_PID" 2>/dev/null; do sleep 30; done
S=artifacts/dota-compute-stall-20261007/ro-session; R=$S/ro-session.sh
BEH="asahi_m4.context_sticky=0 asahi_m4.lifecycle=0 asahi_m4.cc_pattern=0 asahi_m4.ta_sel6=0 asahi_m4.diag_mask=0x04 log_buf_len=8M loglevel=4"
K=artifacts/m4-linux/bits-7.3-100-worklog; U="#100 SMP PREEMPT_DYNAMIC Fri Oct  9 10:38:47 EDT 2026"
r() { env G16_KEEP_LEASE=1 G16_STEAM_OFFLINE=1 G16_SYNTH_LOAD=1 G16_IO_THROTTLE=50M "G16_WORKLOG_DUMP=175 185 195" "$2=$3" G16_TAG=$1 G16_KERNEL_ARTIFACT=$K "G16_EXPECT_UTS=$U" G16_BASE_ARGS=asahi_m4.dependency_kind=0 "G16_BOOT_EXTRA=$BEH" G16_TESTS=dota-quar0 G16_OVERLAY_BASE=/mnt/g16-external/codex-dota-overlay/$1 $R; }
chk() { local v k; v=$(ls -d $S/$1-*/codex-dota-*/verdicts.txt 2>/dev/null | tail -1); k=${v%/verdicts.txt}/kernel.log
    if [ -z "$v" ] || ! grep -q "desktop-mesa libgallium $2" "$v" || ! grep -qE "STALL in|NO-STALL" "$v" || ! grep -q "G16: worklog" "$k"; then
        echo "SETUP FAILURE in $1 (verdicts=$v)"; tools/lease/lease.sh release mini codex-dota; exit 1; fi
    echo "$1 ok: $(grep -hE "STALL" "$v" | head -1) worklog-lines=$(grep -c 'G16: worklog' "$k") dumps=$(grep -c worklog-dump "$v")"; }
stalls() { local c=0; for d in $S/k59-$1-*; do grep -qs "STALL in" $d/codex-dota-*/verdicts.txt && c=$((c+1)); done; echo $c; }
for n in 1 2 3 4 5 6; do
    r k59-nonrob-$n G16_DESKTOP_MESA old; chk k59-nonrob-$n c67094aff03da189
    r k59-rob-$n G16_DESKTOP_MESA_HOST /home/nsheth/Projects/asahi/artifacts/desktop-mesa/mesa-eaa2141; chk k59-rob-$n dcdd17616f552c60
    echo "round $n: nonrobust=$(stalls nonrob) robust=$(stalls rob)"
done
tools/lease/lease.sh release mini codex-dota
echo "block 59 done at $(date -Is)"
