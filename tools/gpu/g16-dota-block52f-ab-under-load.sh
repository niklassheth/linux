#!/bin/bash
# Block 52f: block 52e round 7 remainder (DL, RL), then a claude-driver window (~20 min, Metal mesh UAT dumps), then round 8. Was block 52e (claude-kernel): rounds 6-8 of the A/B under load (Steam offline + synthetic load + 50M cap, #76) with an
# added same-conditions control RL (#76 default recording, diag_mask 0x3f, ta_sel6=0). Round 6 resumes after M03L-6.
#   SL: ta_sel6=2 diag_record=0   M03L: diag_mask=0x03   DL: diag_record=0   RL: default recording (0x3f)
set -uo pipefail
cd /home/nsheth/Projects/asahi
while [ -n "${WAIT_PID:-}" ] && kill -0 "$WAIT_PID" 2>/dev/null; do sleep 15; done
unset WAIT_PID
R=artifacts/dota-compute-stall-20261007/ro-session/ro-session.sh
BEH="asahi_m4.context_sticky=0 asahi_m4.lifecycle=0 asahi_m4.cc_pattern=0"
K76=artifacts/m4-linux/bits-7.3-76-diagmask; U76="#76 SMP PREEMPT_DYNAMIC Thu Oct  8 19:29:01 EDT 2026"
r() { env G16_KEEP_LEASE=1 G16_STEAM_OFFLINE=1 G16_SYNTH_LOAD=1 G16_IO_THROTTLE=50M G16_TAG=$1 G16_KERNEL_ARTIFACT=$K76 "G16_EXPECT_UTS=$U76" G16_BASE_ARGS=asahi_m4.dependency_kind=0 "G16_BOOT_EXTRA=$2" G16_TESTS=dota-quar0 G16_OVERLAY_BASE=/mnt/g16-external/codex-dota-overlay/$1 $R; }
stalls() { local c=0; for d in artifacts/dota-compute-stall-20261007/ro-session/k52-$1-*; do grep -qs "STALL in" $d/codex-dota-*/verdicts.txt && c=$((c+1)); done; echo $c; }
L=/home/nsheth/Projects/asahi/tools/lease/lease.sh
round() { local n=$1 skip=$2
    case " $skip " in *" sl "*) ;; *) r k52-sl-$n "$BEH asahi_m4.ta_sel6=2 asahi_m4.diag_record=0";; esac
    case " $skip " in *" m03l "*) ;; *) r k52-m03l-$n "$BEH asahi_m4.ta_sel6=0 asahi_m4.diag_mask=0x03";; esac
    r k52-dl-$n "$BEH asahi_m4.ta_sel6=0 asahi_m4.diag_record=0"
    r k52-rl-$n "$BEH asahi_m4.ta_sel6=0"
    echo "load round $n: dl=$(stalls dl) sl=$(stalls sl) m03l=$(stalls m03l) rl=$(stalls rl)"; }
round 7 "sl m03l"
$L release mini codex-dota; echo "released for claude-driver window at $(date -Is)"
other=; for i in $(seq 1 30); do h=$($L holder mini | awk '{print $1}'); [ -n "$h" ] && [ "$h" != codex-dota ] && { other=$h; break; }; sleep 30; done
if [ -n "$other" ]; then echo "window taken by $other"; while [ "$($L holder mini | awk '{print $1}')" = "$other" ]; do sleep 30; done; echo "window ended at $(date -Is)"; else echo "nobody took the window in 15 min; continuing"; fi
round 8 ""
echo "block 52f done at $(date -Is)"
./artifacts/dota-compute-stall-20261007/ro-session/block50.sh
