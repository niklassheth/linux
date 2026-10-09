#!/bin/bash
# Block 71 (manager): production #92 hit A4 4/4 with Dota on the system driver; earlier lab statistics used the pinned trace
# driver 5567bc4 (quar0: HK_VA_TRACE/HK_WSI_TRACE). A/B on #92, production args, system Mesa ed7603d desktop, Steam offline,
# no load: Dota variant inst (system ICD) vs quar0 (pinned trace ICD). 3 each, interleaved. Relaunched while the last
# block 70c run finished (WAIT on it); holds the lease straight through.
set -uo pipefail
cd /home/nsheth/Projects/asahi
while kill -0 3900033 2>/dev/null; do sleep 15; done
S=artifacts/dota-compute-stall-20261007/ro-session; R=$S/ro-session.sh; L=tools/lease/lease.sh
K=artifacts/m4-linux/bits-7.3-92; U="#92 SMP PREEMPT_DYNAMIC Fri Oct  9 04:01:44 EDT 2026"
for n in 1 2 3; do
  for v in inst quar0; do
    t=k71-$v-$n
    env G16_KEEP_LEASE=1 G16_STEAM_OFFLINE=1 G16_TAG=$t G16_KERNEL_ARTIFACT=$K "G16_EXPECT_UTS=$U" G16_BASE_ARGS=asahi_m4.dependency_kind=0 G16_TESTS=dota-$v G16_OVERLAY_BASE=/mnt/g16-external/codex-dota-overlay/$t $R
    f=$(ls -d $S/$t-*/codex-dota-*/verdicts.txt 2>/dev/null | tail -1)
    if [ -z "$f" ] || ! grep -qE "STALL in|NO-STALL" "$f"; then echo "SETUP FAILURE in $t (skip)"; continue; fi
    k=${f%verdicts.txt}kernel.log
    echo "$t ok: $(grep -hE 'STALL' "$f" | head -1 | cut -c1-40) a4=$(grep -c 'hang flight.*blocked=0x0.*libkrun' $k) blocked0x2=$(grep -c 'hang flight.*blocked=0x2' $k) $(grep -h '^driver-stamp' "$f" | grep -o 'git-[0-9a-f]*')"
  done
  echo "round $n: inst=$(grep -ls 'STALL in' $S/k71-inst-*/codex-dota-*/verdicts.txt 2>/dev/null | wc -l) quar0=$(grep -ls 'STALL in' $S/k71-quar0-*/codex-dota-*/verdicts.txt 2>/dev/null | wc -l)"
done
$L release mini codex-dota
echo "block 71 done at $(date -Is)"
