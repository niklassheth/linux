#!/bin/bash
# Block 63 (manager, for claude-compiler): Dota per-pass GPU timing, in-match (+map dota after loading), production kernel
# (#92) and production desktop (system Mesa ed7603d), Steam offline, no load. Dota on claude-driver's pass-overlay build
# (pass-a64-ed7603d), HK_GPU_PASS_SPLIT=1, busy file + shader binaries copied back in dota-results/.
set -uo pipefail
cd /home/nsheth/Projects/asahi
while [ -n "${WAIT_PID:-}" ] && kill -0 "$WAIT_PID" 2>/dev/null; do sleep 30; done
S=artifacts/dota-compute-stall-20261007/ro-session; R=$S/ro-session.sh
P=artifacts/dota-pass-timing-20261009/pass-a64-ed7603d
(cd $P && sha256sum -c --quiet SHA256SUMS) || { echo "pass driver checksum failed"; exit 1; }
env G16_STEAM_OFFLINE=1 G16_EXTRA2=$P G16_TAG=k63-pass-1 G16_KERNEL_ARTIFACT=artifacts/m4-linux/current \
    "G16_EXPECT_UTS=#92 SMP PREEMPT_DYNAMIC Fri Oct  9 04:01:44 EDT 2026" G16_BASE_ARGS=asahi_m4.dependency_kind=0 \
    G16_TESTS=dota-pass G16_OVERLAY_BASE=/mnt/g16-external/codex-dota-overlay/k63-pass-1 $R
d=$(ls -d $S/k63-pass-1-*/codex-dota-* 2>/dev/null | tail -1)
echo "k63-pass-1: $(grep -hE 'STALL|NO-STALL' $d/verdicts.txt 2>/dev/null | tr '\n' ' ') busy-files=$(ls $d/dota-results/gpu-busy-*.log 2>/dev/null | wc -l) GPU_PASS=$(cat $d/dota-results/gpu-busy-*.log 2>/dev/null | grep -c GPU_PASS) shaders=$(ls $d/dota-results/shaders 2>/dev/null | wc -l)"
echo "block 63 done at $(date -Is)"
