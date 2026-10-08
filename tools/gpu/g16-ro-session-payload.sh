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
# Live Dota needs a disk-backed upper (Sniper's runtime copies exhaust tmpfs):
# G16_OVERLAY_BASE on the external ext4 disk; the btrfs root stays read-only.
overlay=${G16_OVERLAY_BASE:-/tmp/codex-dota-home}
case "$overlay" in /tmp/codex-dota-*|/mnt/g16-external/codex-dota-overlay/*) ;; *) exit 64 ;; esac
case "$overlay" in /mnt/g16-external/*)
    # The external ext4 has few inodes (122k, nearly all used), so the overlay
    # upper lives in a sparse ext4 image file there (one inode), loop-mounted.
    # Only our own codex-dota-overlay directory is touched.
    ext=/dev/disk/by-uuid/c6a44aa2-0d3d-47ad-86e7-a31a70250e75
    for i in $(seq 1 60); do [ -b "$ext" ] && break; sleep 1; done
    if mountpoint -q /mnt/g16-external; then mount -o remount,rw /mnt/g16-external
    else mount -o rw "$ext" /mnt/g16-external; fi || { echo "external rw mount failed" >> "$observe/verdicts.txt"; dmesg | tail -20 >> "$observe/verdicts.txt"; exit 1; }
    df -i /mnt/g16-external > "$observe/df-inodes-start.txt" 2>&1
    rm -rf /mnt/g16-external/codex-dota-overlay
    mkdir -p /mnt/g16-external/codex-dota-overlay
    img=/mnt/g16-external/codex-dota-overlay/home.img
    truncate -s 40G "$img" && mkfs.ext4 -q -F "$img" || { echo "image mkfs failed" >> "$observe/verdicts.txt"; exit 1; }
    mkdir -p /tmp/codex-dota-loop
    mount -o loop "$img" /tmp/codex-dota-loop || { echo "loop mount failed" >> "$observe/verdicts.txt"; exit 1; }
    overlay=/tmp/codex-dota-loop/ov
    df -i /mnt/g16-external /tmp/codex-dota-loop >> "$observe/df-inodes-start.txt" 2>&1
    findmnt -no SOURCE,FSTYPE,OPTIONS /mnt/g16-external >> "$observe/verdicts.txt" ;;
esac
mkdir -p "$overlay/lower" "$overlay/upper" "$overlay/work"
mount --bind /home/nsheth "$overlay/lower"
mount -o remount,bind,ro "$overlay/lower"
mount -t overlay overlay -o "lowerdir=$overlay/lower,upperdir=$overlay/upper,workdir=$overlay/work" /home/nsheth || { echo "overlay mount failed" >> "$observe/verdicts.txt"; exit 1; }
mountpoint -q /mnt/g16-external || mount -o ro /dev/sda1 /mnt/g16-external 2>/dev/null || true
chmod 1777 "$observe"
sed 's/^loginctl enable-linger "$desktop_user"$/loginctl enable-linger "$desktop_user" || true/' /usr/local/bin/m4-post-boot > "$observe/post-boot.sh"
bash "$observe/post-boot.sh" > "$observe/post-boot.log" 2>&1
{ uname -a; cat /proc/cmdline; findmnt -no TARGET,FSTYPE,OPTIONS -T /; findmnt -no TARGET,FSTYPE,OPTIONS -T /home/nsheth; } > "$observe/kernel.txt"
systemctl is-active m4-kwin claude-headless input-forward-server > "$observe/services.txt"
sha256sum /usr/lib64/libvulkan_asahi.so /home/nsheth/g16-games/dota-shader-identity-20261006/driver/libvulkan_asahi.so > "$observe/drivers.sha256"

stalled() { dmesg > "$observe/.dmesg-probe" 2>/dev/null; grep -qE "sample=pretimeout|timeout without retirement|G16: hang" "$observe/.dmesg-probe"; }
finish_stall() {
    echo "STALL in $1 at $(date +%s.%N)" >> "$observe/verdicts.txt"
    sleep 25
    dmesg > "$observe/kernel.log"
    journalctl -k -b --no-pager > "$observe/kernel-journal.log" 2>&1
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
rb=$observe/render_burst
if [ -s "$observe/render_burst.c" ]; then
    cc -O2 -g -Wall -std=c11 -D_POSIX_C_SOURCE=200809L -I"$observe" -o "$rb" "$observe/render_burst.c" -lvulkan > "$observe/render_burst-build.log" 2>&1
    chmod 755 "$rb"
fi
rp=$observe/render_present
if [ -s "$observe/render_present.c" ]; then
    cc -O2 -g -Wall -std=c11 -D_POSIX_C_SOURCE=200809L -I"$observe" -o "$rp" "$observe/render_present.c" -lvulkan -lxcb > "$observe/render_present-build.log" 2>&1
    chmod 755 "$rp"
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
    cb-flight) run_user cb-flight 120 $cb --split --inflight 8 --images 128 --mips 1 --size 64 --format bc3 --submits 400 ;;
    cb-flight-inter) run_user cb-flight-inter 120 $cb --split --interleave --inflight 8 --images 128 --mips 1 --size 64 --format bc3 --submits 400 ;;
    cb-flight-q2) run_user cb-flight-q2 120 $cb --split --interleave --queues 2 --inflight 16 --images 128 --mips 2 --size 64 --format bc7 --submits 400 ;;
    dota|dota-*) R=/home/nsheth/g16-games/dota-shader-identity-20261006
          variant=mode0; [ "$t" = dota ] || variant=${t#dota-}
          if [ "$variant" = vatrace ]; then
              # claude-driver's apple9/va-trace 7b38f696d25 (c0828f3 + HK_VA_TRACE logging).
              # Installed and wired into dota-inner.sh inside the overlay only.
              mkdir -p "$R/driver-vatrace"
              cp "$observe/extra/libvulkan_asahi.vatrace.so" "$R/driver-vatrace/libvulkan_asahi.so"
              printf '{"file_format_version": "1.0.0", "ICD": {"library_path": "./libvulkan_asahi.so", "api_version": "1.4.0"}}\n' > "$R/driver-vatrace/icd.json"
              grep -qF 'vatrace) ' "$R/dota-inner.sh" || sed -i 's|case "\$variant" in |case "$variant" in vatrace) export VK_DRIVER_FILES="$root/driver-vatrace/icd.json" HK_APPLE9_DUMP_MODE=0 HK_VA_TRACE=1 HK_COPY_TRACE=1 HK_META_DUMP="$out/meta"; mkdir -p "$out/meta";; |' "$R/dota-inner.sh"
              chown -R nsheth:nsheth "$R/driver-vatrace" "$R/dota-inner.sh"
              grep -o 'vatrace)[^;]*' "$R/dota-inner.sh" >> "$observe/verdicts.txt"
          fi
          if [ "$variant" = exportid ] || [ "$variant" = exporthash ]; then
              # Export driver (a8c33e3-based, identity ring; af3ac8a/000e1ef/c8392e4). exportid dumps
              # all SPIR-V; exporthash dumps NIR/asm/bin for the hashes in extra/export-hashes.
              hashes=$(cat "$observe/extra/export-hashes" 2>/dev/null | tr -d ' \n')
              arm_id='exportid) export VK_DRIVER_FILES="$root/driver-export/icd.json" HK_APPLE9_DUMP_MODE=0 MESA_SPIRV_DUMP_PATH="$out/spirv";; '
              arm_hash="exporthash) export VK_DRIVER_FILES=\"\$root/driver-export/icd.json\" HK_APPLE9_DUMP_MODE=0 HK_APPLE9_EXPORT_GRAPHICS=$hashes HK_APPLE9_DUMP_HASH=${hashes%%,*} AGX_APPLE9_ASM_DIR=\"\$out/dump\" HK_APPLE9_DUMP_DIR=\"\$out/dump\" MESA_SPIRV_DUMP_PATH=\"\$out/spirv\";; "
              grep -qF 'exportid)' "$R/dota-inner.sh" || python3 - "$R/dota-inner.sh" "$arm_id$arm_hash" <<'PY'
import sys
p,arms=sys.argv[1],sys.argv[2]
s=open(p).read(); needle='case "$variant" in '
assert s.count(needle)==1
open(p,'w').write(s.replace(needle,needle+arms))
PY
              chown nsheth:nsheth "$R/dota-inner.sh"
              grep -oE '(exportid|exporthash)\)[^;]*' "$R/dota-inner.sh" >> "$observe/verdicts.txt"
          fi
          if [ "$variant" = fixed ]; then
              # claude-compiler's meta-copy helper-lane fix (apple9/meta-copy-helper-oob e77329b+2f3db1b),
              # installed and wired into dota-inner.sh inside the overlay only.
              mkdir -p "$R/driver-fixed"
              cp "$observe/extra/libvulkan_asahi.fixed.so" "$R/driver-fixed/libvulkan_asahi.so"
              printf '{"file_format_version": "1.0.0", "ICD": {"library_path": "./libvulkan_asahi.so", "api_version": "1.4.0"}}\n' > "$R/driver-fixed/icd.json"
              grep -qF 'fixed) ' "$R/dota-inner.sh" || sed -i 's|case "\$variant" in |case "$variant" in fixed) export VK_DRIVER_FILES="$root/driver-fixed/icd.json" HK_APPLE9_DUMP_MODE=0;; |' "$R/dota-inner.sh"
              chown -R nsheth:nsheth "$R/driver-fixed" "$R/dota-inner.sh"
              grep -o 'fixed)[^;]*' "$R/dota-inner.sh" >> "$observe/verdicts.txt"
              sha256sum "$R/driver-fixed/libvulkan_asahi.so" >> "$observe/verdicts.txt"
          fi
          case "$variant" in mode0) drv=$R/driver ;; fb0|fb1) drv=$R/driver-fb-a64 ;; inst) drv=/usr/lib64 ;; vatrace) drv=$R/driver-vatrace ;; exportid|exporthash) drv=$R/driver-export ;; fixed) drv=$R/driver-fixed ;; *) echo "bad variant $variant" >> "$observe/verdicts.txt"; continue ;; esac
          # run-variant.sh chowns the whole results tree; over an overlay that
          # copies up thousands of old files (ENOSPC). Give it a fresh tree.
          mkdir -p "$overlay/results-fresh" && chown nsheth:nsheth "$overlay/results-fresh"
          mount --bind "$overlay/results-fresh" "$R/results" || { echo "results bind failed" >> "$observe/verdicts.txt"; exit 1; }
          df -i /mnt/g16-external > "$observe/df-inodes-before.txt" 2>&1
          label=dota-ro-$(basename "$observe")
          EXPECT_DRIVER=$drv/libvulkan_asahi.so WATCH_LIMIT=300 WATCH_MIN_KB=2097152 \
              timeout 600 bash $R/run-variant.sh "$label" "$variant" > "$observe/dota-harness.log" 2>&1
          echo "dota variant=$variant rc=$?" >> "$observe/verdicts.txt"
          echo "driver-stamp $drv/libvulkan_asahi.so $(strings "$drv/libvulkan_asahi.so" | grep -m1 -oE 'git-[0-9a-f]+') $(sha256sum "$drv/libvulkan_asahi.so" | cut -c1-16)" >> "$observe/verdicts.txt"
          sleep 5; dmesg | grep "G16: queue deps" > "$observe/dep-stats.txt" 2>/dev/null
          cp -a "$R/results/$label" "$observe/dota-results" 2>/dev/null
          cp "/mnt/g16-external/SteamLibrary/steamapps/common/dota 2 beta/game/dota/console.log" "$observe/dota-console.log" 2>/dev/null
          mkdir -p "$observe/steam-logs"
          cp -a /home/nsheth/.local/share/Steam/logs/{stderr.txt,console_log.txt,connection_log.txt,bootstrap_log.txt} "$observe/steam-logs/" 2>/dev/null
          journalctl -b -u g16-steam -u dota-game -u dota-watch -u dota-collector --no-pager > "$observe/steam-logs/units.log" 2>&1
          df -i /mnt/g16-external /tmp/codex-dota-loop > "$observe/df-inodes-end.txt" 2>&1
          df -h /mnt/g16-external /tmp > "$observe/df.txt"
          stalled && finish_stall "$t" ;;
    rb-a) run_user rb-a 90 $rb --passes 8 --inflight 4 --seconds 60 ;;
    rb-b) run_user rb-b 90 $rb --passes 1 --inflight 8 --seconds 60 ;;
    rb-c) run_user rb-c 90 $rb --passes 32 --inflight 2 --seconds 60 ;;
    rb-clear) run_user rb-clear 90 $rb --passes 8 --inflight 4 --clear --seconds 60 ;;
    rb-small) run_user rb-small 90 $rb --passes 8 --inflight 4 --width 64 --height 64 --seconds 60 ;;
    rb-ovf) run_user rb-ovf 90 $rb --passes 4 --inflight 3 --instances 4000 --seconds 60 ;;
    rb-ovf2) run_user rb-ovf2 90 $rb --passes 1 --inflight 6 --instances 20000 --seconds 60 ;;
    rp-a) run_user rp-a 90 $rp --passes 3 --offscreen 4 --inflight 2 --mode fifo --seconds 60 ;;
    rp-b) run_user rp-b 90 $rp --passes 3 --offscreen 8 --inflight 3 --mode mailbox --seconds 60 ;;
    rp-c) run_user rp-c 90 $rp --passes 3 --offscreen 0 --inflight 3 --mode immediate --seconds 60 ;;
    replay) run_user replay 240 env HK_DEBUG=perf VK_DRIVER_FILES=/home/nsheth/g16-games/dota-shader-identity-20261006/driver/icd.json VK_LOADER_LAYERS_DISABLE='~implicit~' HK_PERFTEST=batch \
            /home/nsheth/g16-games/codex-dota-replay-20261008/gfxrecon-replay --wsi xcb /mnt/g16-external/codex-dota-replay-20261008/dota_frames_1_through_1800.gfxr ;;
    *) echo "unknown test $t" >> "$observe/verdicts.txt" ;;
    esac
done
echo "NO-STALL all tests" >> "$observe/verdicts.txt"
dmesg > "$observe/kernel.log"
journalctl -k -b --no-pager > "$observe/kernel-journal.log" 2>&1
