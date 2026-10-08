#!/bin/bash
# Block 48 rounds 3-8 (manager, after k48b-d71-1 showed #70-tree default recording suppresses A4), all on #71:
#   D71: diag_record=0, ta_sel6=0 (A4 base)      S71: diag_record=0, ta_sel6=2      R71: default recording, ta_sel6=0
#   (+ C71: diag_record=0 with only the stale-tag classification on, once claude-kernel provides a split knob: set
#    C71_ARGS in block48-c71.args to enable.)  Interleaved, 6 rounds, no early stop. Ignores R48_* env (rounds 1-2 done).
set -uo pipefail
cd /home/nsheth/Projects/asahi
R=artifacts/dota-compute-stall-20261007/ro-session/ro-session.sh
REC="asahi_m4.dep_stats=1 asahi_m4.dump_render_buffered=16 asahi_m4.dump_render_reg=0x15211 asahi_m4.dump_render_value=0x2d000000500 asahi_m4.dump_render_recent=48"
BEH="asahi_m4.context_sticky=0 asahi_m4.lifecycle=0 asahi_m4.cc_pattern=0"
U71="#71 SMP PREEMPT_DYNAMIC Thu Oct  8 18:27:11 EDT 2026"
K71=artifacts/m4-linux/bits-7.3-71-diagoff
r() { env G16_KEEP_LEASE=1 G16_TAG=$1 G16_KERNEL_ARTIFACT=$2 "G16_EXPECT_UTS=$3" G16_BASE_ARGS=asahi_m4.dependency_kind=0 "G16_BOOT_EXTRA=$4" G16_TESTS=dota-quar0 G16_OVERLAY_BASE=/mnt/g16-external/codex-dota-overlay/$1 $R; }
stalls() { local c=0; for d in artifacts/dota-compute-stall-20261007/ro-session/k48c-$1-*; do grep -qs "STALL in" $d/codex-dota-*/verdicts.txt && c=$((c+1)); done; echo $c; }
for n in 1 2 3 4 5 6; do
    r k48c-d71-$n $K71 "$U71" "$BEH asahi_m4.ta_sel6=0 asahi_m4.diag_record=0"
    r k48c-s71-$n $K71 "$U71" "$BEH asahi_m4.ta_sel6=2 asahi_m4.diag_record=0"
    r k48c-r71-$n $K71 "$U71" "$BEH $REC asahi_m4.ta_sel6=0"
    if [ -s artifacts/dota-compute-stall-20261007/ro-session/block48-c71.args ]; then
        c=$(cat artifacts/dota-compute-stall-20261007/ro-session/block48-c71.args)
        ck=$(sed -n 1p <<<"$c"); cu=$(sed -n 2p <<<"$c"); ca=$(sed -n 3p <<<"$c")
        r k48c-c71-$n "$ck" "$cu" "$BEH $ca"
    fi
    echo "after round $((n + 2)): d71=$(stalls d71) s71=$(stalls s71) r71=$(stalls r71) c71=$(stalls c71)"
done
echo "block 48 (rounds 3-8) done at $(date -Is)"
