#!/bin/bash
# Block 50 (morning, after block 48 rounds 3-8): replay loop with the Steam client running (replay-steam), on #71
# diag_record=0 (D71) and on #63. The Steam overlay layer is already off in live Dota (VK_LOADER_LAYERS_DISABLE='~implicit~',
# no LD_PRELOAD, direct exec), so the remaining live-only ingredient tested here is the running Steam client itself.
set -uo pipefail
cd /home/nsheth/Projects/asahi
while [ -n "${WAIT_PID:-}" ] && kill -0 "$WAIT_PID" 2>/dev/null; do sleep 30; done
R=artifacts/dota-compute-stall-20261007/ro-session/ro-session.sh
BEH="asahi_m4.context_sticky=0 asahi_m4.lifecycle=0 asahi_m4.cc_pattern=0"
for s in d71 t63; do
    if [ $s = d71 ]; then K=artifacts/m4-linux/bits-7.3-71-diagoff; U="#71 SMP PREEMPT_DYNAMIC Thu Oct  8 18:27:11 EDT 2026"; X="$BEH asahi_m4.ta_sel6=0 asahi_m4.diag_record=0"
    else K=artifacts/m4-linux/bits-7.3-63-wedge-r3; U="#63 SMP PREEMPT_DYNAMIC Thu Oct  8 15:26:58 EDT 2026"; X="$BEH asahi_m4.dump_render_recent=48"; fi
    tag=$s-rsteam-1
    env G16_STEAM_OFFLINE=1 G16_KEEP_LEASE=1 G16_TAG=$tag G16_KERNEL_ARTIFACT=$K "G16_EXPECT_UTS=$U" G16_BASE_ARGS=asahi_m4.dependency_kind=0 "G16_BOOT_EXTRA=$X" G16_TESTS=replay-steam G16_OVERLAY_BASE=/mnt/g16-external/codex-dota-overlay/$tag $R
    grep -qs "STALL in" "$(ls -td artifacts/dota-compute-stall-20261007/ro-session/$tag-* | head -1)"/codex-dota-*/verdicts.txt && { echo "$tag stalled; stopping"; break; }
done
/home/nsheth/Projects/asahi/tools/lease/lease.sh release mini codex-dota
echo "block 50 done at $(date -Is)"
