#!/bin/bash
# Block 51 = block 48 rounds 5-8 (manager, after the ~17:00 base-rate drop): 4 rounds of 7 arms, no early stop.
#   T63: #63 (tonight's base rate on the old tree)   D: #76 diag_record=0   DIO: D + 50 MB/s read cap on the external disk
#   for the Steam/muvm unit (slower loading, as before the 134 GB delete?)   S: D + ta_sel6=2   R: #76 default recording
#   M23 / M03: #76 diag_mask 0x23 / 0x03. All with the A4-prone behaviour args; screenshots + dota build in every run.
set -uo pipefail
cd /home/nsheth/Projects/asahi
while [ -n "${WAIT_PID:-}" ] && kill -0 "$WAIT_PID" 2>/dev/null; do sleep 15; done
if [ -n "${B51_YIELD:-}" ]; then /home/nsheth/Projects/asahi/tools/lease/lease.sh release mini codex-dota; echo "yielded lease at $(date -Is)"; sleep 60; fi
R=artifacts/dota-compute-stall-20261007/ro-session/ro-session.sh
REC="asahi_m4.dep_stats=1 asahi_m4.dump_render_buffered=16 asahi_m4.dump_render_reg=0x15211 asahi_m4.dump_render_value=0x2d000000500 asahi_m4.dump_render_recent=48"
BEH="asahi_m4.context_sticky=0 asahi_m4.lifecycle=0 asahi_m4.cc_pattern=0"
K76=artifacts/m4-linux/bits-7.3-76-diagmask; U76="#76 SMP PREEMPT_DYNAMIC Thu Oct  8 19:29:01 EDT 2026"
K63=artifacts/m4-linux/bits-7.3-63-wedge-r3; U63="#63 SMP PREEMPT_DYNAMIC Thu Oct  8 15:26:58 EDT 2026"
r() { env G16_KEEP_LEASE=1 G16_TAG=$1 G16_KERNEL_ARTIFACT=$2 "G16_EXPECT_UTS=$3" G16_BASE_ARGS=asahi_m4.dependency_kind=0 "G16_BOOT_EXTRA=$4" G16_IO_THROTTLE="${5:-}" G16_TESTS=dota-quar0 G16_OVERLAY_BASE=/mnt/g16-external/codex-dota-overlay/$1 $R; }
stalls() { local c=0; for d in artifacts/dota-compute-stall-20261007/ro-session/k51r-$1-*; do grep -qs "STALL in" $d/codex-dota-*/verdicts.txt && c=$((c+1)); done; echo $c; }
for n in ${B51_ROUNDS:-5 6 7 8}; do
    sk=; [ "$n" = "${B51_SKIP_ROUND:-}" ] && sk=" ${B51_SKIP:-} "
    want() { case "$sk" in *" $1 "*) return 1;; *) return 0;; esac; }
    want t63 && r k51r-t63-$n $K63 "$U63" "$BEH $REC"
    want d && r k51r-d-$n $K76 "$U76" "$BEH asahi_m4.ta_sel6=0 asahi_m4.diag_record=0"
    want dio && r k51r-dio-$n $K76 "$U76" "$BEH asahi_m4.ta_sel6=0 asahi_m4.diag_record=0" 50M
    want s && r k51r-s-$n $K76 "$U76" "$BEH asahi_m4.ta_sel6=2 asahi_m4.diag_record=0"
    want r && r k51r-r-$n $K76 "$U76" "$BEH $REC asahi_m4.ta_sel6=0"
    want m23 && r k51r-m23-$n $K76 "$U76" "$BEH asahi_m4.ta_sel6=0 asahi_m4.diag_mask=0x23"
    want m03 && r k51r-m03-$n $K76 "$U76" "$BEH asahi_m4.ta_sel6=0 asahi_m4.diag_mask=0x03"
    echo "after round $n: t63=$(stalls t63) d=$(stalls d) dio=$(stalls dio) s=$(stalls s) r=$(stalls r) m23=$(stalls m23) m03=$(stalls m03)"
done
echo "block 51 done at $(date -Is)"
./artifacts/dota-compute-stall-20261007/ro-session/block50.sh
