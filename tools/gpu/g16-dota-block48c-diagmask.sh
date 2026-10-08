#!/bin/bash
# Block 48 rounds 3-8 (manager; claude-kernel #76 e434de9 = #71 + asahi_m4.diag_mask, default 0x3f = #71 default).
# All arms on #76 (one kernel for the whole A/B), ta_sel6=0 unless noted, A4-prone behaviour args, no dump_render_*:
#   D:   diag_record=0 (A4 base)          S:   diag_record=0 + ta_sel6=2      R:   default (mask 0x3f, + my REC args)
#   M23: diag_mask=0x23 (stale classification + ktime/ring only)   M03: diag_mask=0x03 (classification, no ktime/ring)
#   M1d: diag_mask=0x1d (#63-like: everything but classification)
# Bits: 01 lane+stale counting, 02 stale classification, 04 retirement log, 08 slot history, 10 wedge detector, 20 ktime+ring.
# 6 rounds, no early stop. If #76 fails to boot, fall back to #71 with D/S/R only. Ignores R48_* env.
set -uo pipefail
cd /home/nsheth/Projects/asahi
R=artifacts/dota-compute-stall-20261007/ro-session/ro-session.sh
REC="asahi_m4.dep_stats=1 asahi_m4.dump_render_buffered=16 asahi_m4.dump_render_reg=0x15211 asahi_m4.dump_render_value=0x2d000000500 asahi_m4.dump_render_recent=48"
BEH="asahi_m4.context_sticky=0 asahi_m4.lifecycle=0 asahi_m4.cc_pattern=0"
K=artifacts/m4-linux/bits-7.3-76-diagmask; U="#76 SMP PREEMPT_DYNAMIC Thu Oct  8 19:29:01 EDT 2026"; kn=76; masks=1
r() { env G16_KEEP_LEASE=1 G16_TAG=$1 G16_KERNEL_ARTIFACT=$K "G16_EXPECT_UTS=$U" G16_BASE_ARGS=asahi_m4.dependency_kind=0 "G16_BOOT_EXTRA=$2" G16_TESTS=dota-quar0 G16_OVERLAY_BASE=/mnt/g16-external/codex-dota-overlay/$1 $R; }
last() { ls -td artifacts/dota-compute-stall-20261007/ro-session/$1-* 2>/dev/null | head -1; }
stalls() { local c=0; for d in artifacts/dota-compute-stall-20261007/ro-session/k48c-$kn-$1-*; do grep -qs "STALL in" $d/codex-dota-*/verdicts.txt && c=$((c+1)); done; echo $c; }
for n in 1 2 3 4 5 6; do
    r k48c-$kn-d-$n "$BEH asahi_m4.ta_sel6=0 asahi_m4.diag_record=0"
    if [ $n = 1 ] && [ $kn = 76 ] && [ ! -s "$(last k48c-76-d-1)/loaded-kernel.txt" ]; then
        echo "#76 failed to boot; falling back to #71 (D/S/R only)"
        K=artifacts/m4-linux/bits-7.3-71-diagoff; U="#71 SMP PREEMPT_DYNAMIC Thu Oct  8 18:27:11 EDT 2026"; kn=71; masks=0
        r k48c-$kn-d-$n "$BEH asahi_m4.ta_sel6=0 asahi_m4.diag_record=0"
    fi
    r k48c-$kn-s-$n "$BEH asahi_m4.ta_sel6=2 asahi_m4.diag_record=0"
    r k48c-$kn-r-$n "$BEH $REC asahi_m4.ta_sel6=0"
    if [ $masks = 1 ]; then
        r k48c-$kn-m23-$n "$BEH asahi_m4.ta_sel6=0 asahi_m4.diag_mask=0x23"
        r k48c-$kn-m03-$n "$BEH asahi_m4.ta_sel6=0 asahi_m4.diag_mask=0x03"
        r k48c-$kn-m1d-$n "$BEH asahi_m4.ta_sel6=0 asahi_m4.diag_mask=0x1d"
    fi
    echo "after round $((n + 2)) (#$kn): d=$(stalls d) s=$(stalls s) r=$(stalls r) m23=$(stalls m23) m03=$(stalls m03) m1d=$(stalls m1d)"
done
echo "block 48 (rounds 3-8) done at $(date -Is)"
