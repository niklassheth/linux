#!/bin/bash
# Remote payload (root) for ro-session.sh: RO root, tmpfs home overlay, then
# the selected tests. Stops at the first GPU stall, waits for the kernel hang
# dump, saves dmesg. Usage: payload.sh OUTDIR "test test ..."
set -uo pipefail
observe=$1; tests=$2
case "$observe" in /tmp/codex-dota-*) ;; *) exit 64 ;; esac
tests=${tests:-}
case ",$(findmnt -no OPTIONS /)," in *,ro,*) ;; *) echo "root not ro"; exit 1 ;; esac
swapoff -a
if ! mountpoint -q /home; then
    source=$(findmnt -no SOURCE /); source=${source%%\[*}
    mount -o ro,subvol=home "$source" /home
fi
overlay=/tmp/codex-dota-home
mkdir -p "$overlay/lower" "$overlay/upper" "$overlay/work"
mount --bind /home/nsheth "$overlay/lower"
mount -o remount,bind,ro "$overlay/lower"
mount -t overlay overlay -o "lowerdir=$overlay/lower,upperdir=$overlay/upper,workdir=$overlay/work" /home/nsheth
mountpoint -q /mnt/g16-external || mount -o ro /dev/sda1 /mnt/g16-external 2>/dev/null || true
chmod 1777 "$observe"
sed 's/^loginctl enable-linger "$desktop_user"$/loginctl enable-linger "$desktop_user" || true/' /usr/local/bin/m4-post-boot > "$observe/post-boot.sh"
bash "$observe/post-boot.sh" > "$observe/post-boot.log" 2>&1
{ uname -a; cat /proc/cmdline; findmnt -no TARGET,FSTYPE,OPTIONS -T /; findmnt -no TARGET,FSTYPE,OPTIONS -T /home/nsheth; } > "$observe/kernel.txt"
systemctl is-active m4-kwin claude-headless input-forward-server > "$observe/services.txt"
sha256sum /usr/lib64/libvulkan_asahi.so /home/nsheth/g16-games/dota-shader-identity-20261006/driver/libvulkan_asahi.so > "$observe/drivers.sha256"

stalled() { dmesg | grep -qE "sample=pretimeout|timeout without retirement|G16: hang"; }
finish_stall() {
    echo "STALL in $1 at $(date +%s.%N)" >> "$observe/verdicts.txt"
    sleep 25
    dmesg > "$observe/kernel.log"
    exit 0
}
run_user() { # name timeout cmd...
    local name=$1 t=$2; shift 2
    runuser -u nsheth -- env HOME=/home/nsheth bash -c 'source /home/nsheth/.local/state/m4/session.env; unset ASAHI_MESA_DEBUG AGX_MESA_DEBUG LD_PRELOAD VK_INSTANCE_LAYERS; export HK_EXPERIMENTAL_APPLE9=1 MESA_SHADER_CACHE_DISABLE=true; exec "$@"' _ "$@" > "$observe/$name.log" 2>&1 &
    local pid=$! start=$SECONDS
    while kill -0 $pid 2>/dev/null; do
        if stalled; then sleep 2; pkill -P $pid; kill $pid 2>/dev/null; finish_stall "$name"; fi
        [ $((SECONDS - start)) -lt "$t" ] || { kill $pid; pkill -P $pid; echo "TIMEOUT-LIMIT $name" >> "$observe/verdicts.txt"; break; }
        sleep 0.5
    done
    wait $pid; echo "$name rc=$? secs=$((SECONDS - start))" >> "$observe/verdicts.txt"
    stalled && finish_stall "$name"
}
cb=$observe/copy_burst
if [ -s "$observe/copy_burst.c" ]; then
    cc -O2 -g -Wall -std=c11 -D_POSIX_C_SOURCE=200809L -o "$cb" "$observe/copy_burst.c" -lvulkan > "$observe/copy_burst-build.log" 2>&1
    chmod 755 "$cb"; sha256sum "$cb" >> "$observe/drivers.sha256"
fi
[ "$tests" != restore ] || { echo "RESTORED ro production" >> "$observe/verdicts.txt"; exit 0; }
for t in $tests; do
    case $t in
    cb-one) run_user cb-one 120 env HK_DEBUG=perf $cb --images 64 --mips 9 --format bc3 --submits 40 ;;
    cb-split) run_user cb-split 120 env HK_DEBUG=perf $cb --split --images 512 --mips 1 --size 128 --format bc3 --submits 20 ;;
    cb-split4) run_user cb-split4 120 env HK_DEBUG=perf $cb --split --images 512 --mips 4 --size 128 --format bc3 --submits 20 ;;
    cb-splitrc) run_user cb-splitrc 120 env HK_DEBUG=perf $cb --split --recreate --images 256 --mips 8 --size 128 --format bc7 --submits 20 ;;
    cb-inter) run_user cb-inter 120 env HK_DEBUG=perf $cb --interleave --images 128 --mips 6 --size 128 --format bc3 --submits 60 ;;
    cb-inter-split) run_user cb-inter-split 120 env HK_DEBUG=perf $cb --interleave --split --images 256 --mips 3 --size 64 --format bc3 --submits 60 ;;
    cb-inter-q2) run_user cb-inter-q2 120 env HK_DEBUG=perf $cb --interleave --split --queues 2 --images 256 --mips 3 --size 64 --format bc7 --submits 60 ;;
    replay) run_user replay 240 env HK_DEBUG=perf VK_DRIVER_FILES=/home/nsheth/g16-games/dota-shader-identity-20261006/driver/icd.json VK_LOADER_LAYERS_DISABLE='~implicit~' HK_PERFTEST=batch \
            /home/nsheth/g16-games/codex-dota-replay-20261008/gfxrecon-replay --wsi xcb /mnt/g16-external/codex-dota-replay-20261008/dota_frames_1_through_1800.gfxr ;;
    *) echo "unknown test $t" >> "$observe/verdicts.txt" ;;
    esac
done
echo "NO-STALL all tests" >> "$observe/verdicts.txt"
dmesg > "$observe/kernel.log"
