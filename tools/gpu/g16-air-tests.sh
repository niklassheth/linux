#!/bin/bash
# claude-dota Air test runner (run as the desktop user inside the headless
# session, with the session's Vulkan env). Usage: air-tests.sh OUTDIR TEST...
# Tests: rb-a rb-b rb-c rb-ovf rp-a rp-b rp-c cb-flight replay
# Stall signal: dmesg "timeout without retirement progress" or "sample=pretimeout"
# (the kernel's watchdog), NOT a program's own STALL line alone (rb-ovf's drain can
# exceed its fence timeout without any GPU hang). Stops at the first kernel stall,
# waits 25 s for the full hang dump, saves dmesg.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
out=$1; shift
mkdir -p "$out"
export HK_EXPERIMENTAL_APPLE9=1 MESA_SHADER_CACHE_DISABLE=true
TRACE=${TRACE:-/root/dota_frames_1_through_1800.gfxr}
kstall() { sudo -n dmesg 2>/dev/null > "$out/.probe" || dmesg > "$out/.probe" 2>/dev/null; grep -qE "sample=pretimeout|timeout without retirement" "$out/.probe"; }
run() { # name limit cmd...
    local name=$1 t=$2; shift 2
    "$@" > "$out/$name.log" 2>&1 & local pid=$! s=$SECONDS
    while kill -0 $pid 2>/dev/null; do
        if kstall; then echo "KERNEL-STALL in $name at +$((SECONDS - s))s" | tee -a "$out/verdicts.txt"; sleep 25; kill $pid 2>/dev/null; (sudo -n dmesg || dmesg) > "$out/dmesg.txt" 2>/dev/null; exit 0; fi
        [ $((SECONDS - s)) -lt "$t" ] || { kill $pid; echo "LIMIT $name" >> "$out/verdicts.txt"; break; }
        sleep 0.5
    done
    wait $pid; echo "$name rc=$? secs=$((SECONDS - s))" >> "$out/verdicts.txt"
}
for t in "$@"; do case $t in
    rb-a) run rb-a 90 "$here/render_burst" --passes 8 --inflight 4 --seconds 60 ;;
    rb-b) run rb-b 90 "$here/render_burst" --passes 1 --inflight 8 --seconds 60 ;;
    rb-c) run rb-c 90 "$here/render_burst" --passes 32 --inflight 2 --seconds 60 ;;
    rb-ovf) run rb-ovf 120 "$here/render_burst" --passes 4 --inflight 3 --instances 4000 --seconds 60 --timeout-ms 30000 ;;
    rp-a) run rp-a 90 "$here/render_present" --passes 3 --offscreen 4 --inflight 2 --mode fifo --seconds 60 ;;
    rp-b) run rp-b 90 "$here/render_present" --passes 3 --offscreen 8 --inflight 3 --mode mailbox --seconds 60 ;;
    rp-c) run rp-c 90 "$here/render_present" --passes 3 --offscreen 0 --inflight 3 --mode immediate --seconds 60 ;;
    cb-flight) run cb-flight 120 "$here/copy_burst" --split --interleave --inflight 8 --images 128 --mips 1 --size 64 --format bc3 --submits 400 ;;
    replay) run replay 240 "$here/gfxrecon-replay" --wsi wayland "$TRACE" ;;
    *) echo "unknown $t" >> "$out/verdicts.txt" ;;
esac; done
echo "NO-KERNEL-STALL" >> "$out/verdicts.txt"
(sudo -n dmesg || dmesg) > "$out/dmesg.txt" 2>/dev/null
