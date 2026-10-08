#!/bin/bash
# Block 48 (manager + claude-kernel): localise why the #68/#70 tree ran A4-clean (controls 3/3, =2 7/7). All ta_sel6=0.
#   T63:  #63 (last tree with confirmed A4), my usual A4-prone args
#   R71:  #71 (4de40e1 = #70 + diag_record knob), my usual args, recording on (as #70)
#   D71:  #71 diag_record=0, no dump_render_*/dep_stats (all optional recording off)
#   N71:  #71 diag_record=0 + no-RTC DTB (#33's; RTC/SPMI drivers don't bind), no dump_render_*/dep_stats
# 8 rounds (overnight, manager) of T63 R71 D71 N71 (~32 runs); no early stop (we need rates). If a #71 arm reaches
# >=3 stalls while another arm is at 0, a fifth arm S71 (that arm's args + ta_sel6=2) joins the remaining rounds. First R71 doubles as #71's boot test.
set -uo pipefail
cd /home/nsheth/Projects/asahi
while [ -n "${WAIT_PID:-}" ] && kill -0 "$WAIT_PID" 2>/dev/null; do sleep 30; done
R=artifacts/dota-compute-stall-20261007/ro-session/ro-session.sh
REC="asahi_m4.dep_stats=1 asahi_m4.dump_render_buffered=16 asahi_m4.dump_render_reg=0x15211 asahi_m4.dump_render_value=0x2d000000500 asahi_m4.dump_render_recent=48"
BEH="asahi_m4.context_sticky=0 asahi_m4.lifecycle=0 asahi_m4.cc_pattern=0"
U63="#63 SMP PREEMPT_DYNAMIC Thu Oct  8 15:26:58 EDT 2026"
U71="#71 SMP PREEMPT_DYNAMIC Thu Oct  8 18:27:11 EDT 2026"
r() { env G16_KEEP_LEASE=1 G16_TAG=$1 G16_KERNEL_ARTIFACT=$2 "G16_EXPECT_UTS=$3" G16_BASE_ARGS=asahi_m4.dependency_kind=0 "G16_BOOT_EXTRA=$4" G16_TESTS=dota-quar0 G16_OVERLAY_BASE=/mnt/g16-external/codex-dota-overlay/$1 $R; }
stalls() { local c=0; for d in artifacts/dota-compute-stall-20261007/ro-session/k48b-$1-*; do grep -qs "STALL in" $d/codex-dota-*/verdicts.txt && c=$((c+1)); done; echo $c; }
fifth=; fifth_k=; fifth_x=
for n in 1 2 3 4 5 6 7 8; do
    r k48b-t63-$n artifacts/m4-linux/bits-7.3-63-wedge-r3 "$U63" "$BEH $REC"
    r k48b-r71-$n artifacts/m4-linux/bits-7.3-71-diagoff "$U71" "$BEH $REC asahi_m4.ta_sel6=0"
    [ -s "$(ls -td artifacts/dota-compute-stall-20261007/ro-session/k48b-r71-$n-* | head -1)/loaded-kernel.txt" ] || { echo "#71 failed to boot; stopping"; break; }
    r k48b-d71-$n artifacts/m4-linux/bits-7.3-71-diagoff "$U71" "$BEH asahi_m4.ta_sel6=0 asahi_m4.diag_record=0"
    r k48b-n71-$n artifacts/m4-linux/bits-7.3-71-diagoff-nortc "$U71" "$BEH asahi_m4.ta_sel6=0 asahi_m4.diag_record=0"
    [ -n "$fifth" ] && r k48b-s71-$n "$fifth_k" "$U71" "$fifth_x asahi_m4.ta_sel6=2"
    st="t63=$(stalls t63) r71=$(stalls r71) d71=$(stalls d71) n71=$(stalls n71) s71=$(stalls s71)"
    echo "after round $n: $st"
    if [ -z "$fifth" ]; then
        for a in r71 d71 n71; do
            if [ "$(stalls $a)" -ge 3 ] && { [ "$(stalls t63)" = 0 ] || [ "$(stalls r71)" = 0 ] || [ "$(stalls d71)" = 0 ] || [ "$(stalls n71)" = 0 ]; }; then
                fifth=$a
                case $a in
                r71) fifth_k=artifacts/m4-linux/bits-7.3-71-diagoff; fifth_x="$BEH $REC" ;;
                d71) fifth_k=artifacts/m4-linux/bits-7.3-71-diagoff; fifth_x="$BEH asahi_m4.diag_record=0" ;;
                n71) fifth_k=artifacts/m4-linux/bits-7.3-71-diagoff-nortc; fifth_x="$BEH asahi_m4.diag_record=0" ;;
                esac
                echo "adding fifth arm S71 = $a + ta_sel6=2 from round $((n+1))"; break
            fi
        done
    fi
done
echo "block 48 done at $(date -Is)"
