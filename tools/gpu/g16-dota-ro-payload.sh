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
# Desktop-driver A/B (manager): G16_DESKTOP_MESA=old bind-mounts the pre-eaa2141 system Mesa backup over the installed
# files for this boot only (RO root untouched), before post-boot starts KWin/Xwayland.
if [ -n "${G16_DESKTOP_MESA:-}" ]; then
    B=$G16_DESKTOP_MESA; [ "$B" = old ] && B=/root/mesa-backup-before-eaa2141; nb=0
    for a in aarch64 x86_64 i686 drirc-a64 drirc-x86; do
        [ -d $B/$a ] || continue
        while IFS= read -r f; do t=/${f#$B/$a/}; [ -e "$t" ] && mount --bind "$f" "$t" && nb=$((nb+1)); done < <(find $B/$a -type f)
    done
    echo "desktop-mesa $B: $nb files bind-mounted" >> "$observe/verdicts.txt"
fi
bash "$observe/post-boot.sh" > "$observe/post-boot.log" 2>&1
echo "desktop-mesa libgallium $(sha256sum /usr/lib64/libgallium-26.3.0-devel.so | cut -c1-16) $(strings /usr/lib64/libgallium-26.3.0-devel.so | grep -m1 -oE 'git-[0-9a-f]+')" >> "$observe/verdicts.txt"
( sleep 20; k=$(pgrep -n -x kwin_wayland); echo "kwin maps: $(grep -oE '/[^ ]*libgallium[^ ]*' /proc/$k/maps 2>/dev/null | sort -u | tr '\n' ' ') $(grep -c libgallium /proc/$k/maps 2>/dev/null)" >> "$observe/verdicts.txt" ) &

{ uname -a; cat /proc/cmdline; findmnt -no TARGET,FSTYPE,OPTIONS -T /; findmnt -no TARGET,FSTYPE,OPTIONS -T /home/nsheth; } > "$observe/kernel.txt"
systemctl is-active m4-kwin claude-headless input-forward-server > "$observe/services.txt"
sha256sum /usr/lib64/libvulkan_asahi.so /home/nsheth/g16-games/dota-shader-identity-20261006/driver/libvulkan_asahi.so > "$observe/drivers.sha256"

stalled() { dmesg > "$observe/.dmesg-probe" 2>/dev/null; grep -qE "sample=pretimeout|timeout without retirement|G16: hang" "$observe/.dmesg-probe"; }
finish_stall() {
    echo "STALL in $1 at $(date +%s.%N)" >> "$observe/verdicts.txt"
    ps -eo pid,ppid,user,comm,args --sort=pid > "$observe/ps-at-stall.txt" 2>&1
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
              grep -qF 'vatrace) ' "$R/dota-inner.sh" || sed -i 's|case "\$variant" in |case "$variant" in vatrace) export VK_DRIVER_FILES="$root/driver-vatrace/icd.json" HK_APPLE9_DUMP_MODE=0 HK_VA_TRACE=1 HK_COPY_TRACE=1 HK_PASS_TRACE=1280x720 HK_WSI_TRACE=1 HK_META_DUMP="$out/meta"; mkdir -p "$out/meta";; |' "$R/dota-inner.sh"
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
          # G16_DOTA_MODE (overlay-only): fixed = a plain 1280x720 window (no borderless/coop fullscreen);
          # fullscreen = exclusive fullscreen at the display size (1920x1080).
          V=/home/nsheth/g16-games/dota-civ-followup-20261006/dota-video-low.txt
          case "${G16_DOTA_MODE:-}" in
          fixed)
              sed -i -E 's/("setting\.(fullscreen|coop_fullscreen|nowindowborder)"\s+)"[01]"/\1"0"/' "$V" ;;
          fullscreen)
              sed -i -E 's/("setting\.fullscreen"\s+)"[01]"/\1"1"/; s/("setting\.(coop_fullscreen|nowindowborder)"\s+)"[01]"/\1"0"/; s/("setting\.defaultres"\s+)"[0-9]+"/\1"1920"/; s/("setting\.defaultresheight"\s+)"[0-9]+"/\1"1080"/' "$V"
              sed -i 's/ -windowed -w 1280 -h 720 / -fullscreen -w 1920 -h 1080 /' "$R/dota-inner.sh" ;;
          esac
          # Audio (manager 21:00: #68/#76 vs #92 differ only in MCA audio): record the audio devices, and optionally launch
          # Dota with -nosound.
          { echo "audio-cards $(aplay -l 2>/dev/null | grep -c '^card') $(aplay -l 2>/dev/null | grep '^card' | cut -c1-60 | tr '\n' ';')"; } >> "$observe/verdicts.txt"
          if [ "${G16_DOTA_NOSOUND:-}" = 1 ]; then
              sed -i 's| -novid | -novid -nosound |' "$R/dota-inner.sh"; chown nsheth:nsheth "$R/dota-inner.sh"
              echo "dota-nosound $(grep -c -- '-nosound' "$R/dota-inner.sh")" >> "$observe/verdicts.txt"
          fi
          if [ -n "${G16_DOTA_MODE:-}" ]; then
              chown nsheth:nsheth "$V" "$R/dota-inner.sh"
              { echo "dota-mode=$G16_DOTA_MODE"; grep -E 'setting\.(defaultres|defaultresheight|fullscreen|coop_fullscreen|nowindowborder)"' "$V"; grep -oE '\-(windowed|fullscreen) -w [0-9]+ -h [0-9]+' "$R/dota-inner.sh"; } >> "$observe/verdicts.txt"
          fi
          case "$variant" in quar*)
              # claude-driver's apple9/va-quarantine-debug 7835475b288 (8825824 + traces + HK_VA_QUARANTINE_MS).
              qms=${variant#quar}
              mkdir -p "$R/driver-quar"
              cp "$observe/extra/libvulkan_asahi.quar.so" "$R/driver-quar/libvulkan_asahi.so"
              printf '{"file_format_version": "1.0.0", "ICD": {"library_path": "./libvulkan_asahi.so", "api_version": "1.4.0"}}\n' > "$R/driver-quar/icd.json"
              grep -qF "quar$qms) " "$R/dota-inner.sh" || sed -i "s|case \"\\\$variant\" in |case \"\$variant\" in quar$qms) export VK_DRIVER_FILES=\"\$root/driver-quar/icd.json\" HK_APPLE9_DUMP_MODE=0 HK_VA_TRACE=1 HK_WSI_TRACE=1 HK_VA_QUARANTINE_MS=$qms;; |" "$R/dota-inner.sh"
              chown -R nsheth:nsheth "$R/driver-quar" "$R/dota-inner.sh"
              grep -o "quar$qms)[^;]*" "$R/dota-inner.sh" >> "$observe/verdicts.txt" ;;
          esac
          case "$variant" in pass)
              # Per-pass GPU timing for claude-compiler (claude-driver's pass-a64-ed7603d: ed7603d + perf + pass overlays,
              # aarch64, loaded through the FEX Vulkan thunks). HK_GPU_PASS_SPLIT=1 times each dispatch on its own.
              mkdir -p "$R/driver-pass"
              cp "$observe/extra2/libvulkan_asahi.so" "$R/driver-pass/libvulkan_asahi.so"
              printf '{"file_format_version": "1.0.0", "ICD": {"library_path": "./libvulkan_asahi.so", "api_version": "1.4.0"}}\n' > "$R/driver-pass/icd.json"
              grep -qF "pass) " "$R/dota-inner.sh" || sed -i "s|case \"\\\$variant\" in |case \"\$variant\" in pass) export VK_DRIVER_FILES=\"\$root/driver-pass/icd.json\" HK_APPLE9_DUMP_MODE=0 HK_GPU_PASS_SPLIT=1 HK_GPU_PASS_SHADER_DIR=\"\$out/shaders\" HK_GPU_BUSY_FILE_PASS=\"\$out/gpu-busy-%p.log\"; mkdir -p \"\$out/shaders\";; |" "$R/dota-inner.sh"
              # dota-inner.sh unsets HK_GPU_BUSY_FILE after the variant case; set it after that line for this variant.
              grep -qF 'HK_GPU_BUSY_FILE_PASS:+' "$R/dota-inner.sh" || sed -i 's|^unset HK_GPU_BUSY_FILE HK_TIMELINE_FILE$|unset HK_GPU_BUSY_FILE HK_TIMELINE_FILE; [ -n "${HK_GPU_BUSY_FILE_PASS:+x}" ] \&\& export HK_GPU_BUSY_FILE="$HK_GPU_BUSY_FILE_PASS"|' "$R/dota-inner.sh"
              chown -R nsheth:nsheth "$R/driver-pass" "$R/dota-inner.sh"
              { grep -o "pass)[^;]*;[^;]*" "$R/dota-inner.sh"; grep -n "HK_GPU_BUSY_FILE_PASS:+" "$R/dota-inner.sh"; } >> "$observe/verdicts.txt" ;;
          esac
          case "$variant" in x2)
              # A Dota ICD staged from the host for this session (G16_EXTRA2 dir with libvulkan_asahi.so), no extra env.
              mkdir -p "$R/driver-x2"
              cp "$observe/extra2/libvulkan_asahi.so" "$R/driver-x2/libvulkan_asahi.so"
              printf '{"file_format_version": "1.0.0", "ICD": {"library_path": "./libvulkan_asahi.so", "api_version": "1.4.0"}}\n' > "$R/driver-x2/icd.json"
              grep -qF "x2) " "$R/dota-inner.sh" || sed -i "s|case \"\\\$variant\" in |case \"\$variant\" in x2) export VK_DRIVER_FILES=\"\$root/driver-x2/icd.json\" HK_APPLE9_DUMP_MODE=0;; |" "$R/dota-inner.sh"
              chown -R nsheth:nsheth "$R/driver-x2" "$R/dota-inner.sh"
              grep -o "x2)[^;]*" "$R/dota-inner.sh" >> "$observe/verdicts.txt" ;;
          esac
          case "$variant" in stats)
              # claude-compiler's variant-stats build (8825824 + HK_APPLE9_VARIANT_STATS), not an A4 arm.
              mkdir -p "$R/driver-stats"
              cp "$observe/extra/libvulkan_asahi.stats.so" "$R/driver-stats/libvulkan_asahi.so"
              printf '{"file_format_version": "1.0.0", "ICD": {"library_path": "./libvulkan_asahi.so", "api_version": "1.4.0"}}\n' > "$R/driver-stats/icd.json"
              grep -qF "stats) " "$R/dota-inner.sh" || sed -i "s|case \"\\\$variant\" in |case \"\$variant\" in stats) export VK_DRIVER_FILES=\"\$root/driver-stats/icd.json\" HK_APPLE9_DUMP_MODE=0 HK_APPLE9_VARIANT_STATS=1;; |" "$R/dota-inner.sh"
              chown -R nsheth:nsheth "$R/driver-stats" "$R/dota-inner.sh"
              grep -o "stats)[^;]*" "$R/dota-inner.sh" >> "$observe/verdicts.txt" ;;
          esac
          case "$variant" in mode0) drv=$R/driver ;; quar*) drv=$R/driver-quar ;; stats) drv=$R/driver-stats ;; pass) drv=$R/driver-pass ;; x2) drv=$R/driver-x2 ;; fb0|fb1) drv=$R/driver-fb-a64 ;; inst) drv=/usr/lib64 ;; vatrace) drv=$R/driver-vatrace ;; exportid|exporthash) drv=$R/driver-export ;; fixed) drv=$R/driver-fixed ;; *) echo "bad variant $variant" >> "$observe/verdicts.txt"; continue ;; esac
          # run-variant.sh chowns the whole results tree; over an overlay that
          # copies up thousands of old files (ENOSPC). Give it a fresh tree.
          mkdir -p "$overlay/results-fresh" && chown nsheth:nsheth "$overlay/results-fresh"
          mount --bind "$overlay/results-fresh" "$R/results" || { echo "results bind failed" >> "$observe/verdicts.txt"; exit 1; }
          df -i /mnt/g16-external > "$observe/df-inodes-before.txt" 2>&1
          label=dota-ro-$(basename "$observe")
          # Screenshots of the game's display (manager): the capture card sees only the blanked HDMI output, so grab the
          # X display from session.env (Dota's Xwayland): one ~20 s into the game, rolling ones every 4 s (last 3 kept),
          # and one when the stall detector fires. Each grab has a timeout (the compositor may be frozen).
          mkdir -p "$observe/shots"; chmod 777 "$observe/shots"
          shot() { runuser -u nsheth -- env HOME=/home/nsheth bash -c 'source /home/nsheth/.local/state/m4/session.env
              o=$0; timeout 10 spectacle -b -n -f -o "$o.png" >/dev/null 2>&1 && [ -s "$o.png" ] && exit 0
              timeout 6 ffmpeg -loglevel error -y -f x11grab -i "$DISPLAY" -frames:v 1 "$o-x11.png" 2>/dev/null && exit 0
              timeout 6 xwd -root -silent > "$o.xwd" 2>/dev/null && [ -s "$o.xwd" ] && exit 0
              rm -f "$o.xwd"; timeout 6 import -window root "$o.png" 2>/dev/null' "$observe/shots/$1" < /dev/null; }
          ( for i in $(seq 1 180); do systemctl is-active --quiet dota-watch && break; sleep 1; done
            sleep 25; shot loading; k=0
            while systemctl is-active --quiet dota-watch; do
                if stalled; then shot stall; echo "shot at stall $(date +%T)" >> "$observe/shots/log"; break; fi
                k=$(( (k + 1) % 3 )); shot "last$k"; echo "last$k $(date +%T)" >> "$observe/shots/log"; sleep 4
            done ) > /dev/null 2>&1 &
          shotter=$!
          # Steam quiet base (manager): offline mode pre-seeded in the per-boot overlay before run-variant starts Steam.
          if [ "${G16_STEAM_OFFLINE:-}" = 1 ]; then
              LU=/home/nsheth/.local/share/Steam/config/loginusers.vdf
              sed -i -E 's/("WantsOfflineMode"[[:space:]]+)"0"/\1"1"/; s/("SkipOfflineModeWarning"[[:space:]]+)"0"/\1"1"/' "$LU"
              echo "steam-offline $(grep -cE '"(WantsOfflineMode|SkipOfflineModeWarning)"[[:space:]]+"1"' "$LU")/2" >> "$observe/verdicts.txt"
          fi
          # Synthetic Steam-like load during loading (manager): 120 s of direct sequential reads from the external disk plus
          # zstd -19 -T4 compression (download/decompress/stage stand-in), starting when the watcher starts.
          if [ "${G16_SYNTH_LOAD:-}" = 1 ]; then
              ( for i in $(seq 1 180); do systemctl is-active --quiet dota-watch && break; sleep 1; done
                big=/mnt/g16-external/codex-dota-replay-20261008/dota_frames_1_through_1800.gfxr
                timeout 120 dd if="$big" of=/dev/null bs=4M iflag=direct status=none &
                timeout 120 nice -n 5 zstd -q -19 -T4 -c "$big" > /dev/null &
                wait; echo "synth-load done $(date +%T)" >> "$observe/verdicts.txt" ) &
          fi
          # GPU keepalive (manager power arm): a separate tiny client submits one 64x64 pass every ~20 ms for the whole run,
          # so the GPU never idles off between desktop frames. Dota's pinned ICD.
          if [ "${G16_KEEPALIVE:-}" = 1 ]; then
              runuser -u nsheth -- env HOME=/home/nsheth bash -c 'source /home/nsheth/.local/state/m4/session.env; unset ASAHI_MESA_DEBUG LD_PRELOAD; export HK_EXPERIMENTAL_APPLE9=1 MESA_SHADER_CACHE_DISABLE=true; exec "$@"' _ \
                  "$rb" --passes 1 --inflight 1 --width 64 --height 64 --burst 1 --idle-ms 20 --seconds 900 --timeout-ms 30000 > "$observe/keepalive.log" 2>&1 &
              keepalive=$!; echo "keepalive pid $keepalive" >> "$observe/verdicts.txt"
          fi
          # On-demand work-log dumps (#100, diag_mask&4): Dota's loading-end burst lands ~170-180 s after dota-game starts
          # (stalled runs: detection at +188..194 s, 10 s after the stuck submit). G16_WORKLOG_DUMP="175 185 195" = seconds.
          if [ -n "${G16_WORKLOG_DUMP:-}" ]; then
              # dota-game exits right after launching; dota-watch starts with it and lives for the run.
              ( for i in $(seq 1 300); do systemctl is-active --quiet dota-watch && break; sleep 1; done; t0=$(date +%s)
                for t in $G16_WORKLOG_DUMP; do
                    while [ $(( $(date +%s) - t0 )) -lt "$t" ]; do sleep 0.5; done
                    systemctl is-active --quiet dota-watch || break
                    echo 1 > /sys/kernel/debug/asahi_g16/dump_retire && echo "worklog-dump +$t s $(date +%T.%N) uptime $(cut -d' ' -f1 /proc/uptime)" >> "$observe/verdicts.txt"
                done ) &
          fi
          # Optional loading-I/O throttle (manager): cap reads from the external disk for the Steam/muvm unit that serves
          # Dota's file I/O (G16_IO_THROTTLE, e.g. 50M).
          if [ -n "${G16_IO_THROTTLE:-}" ]; then
              dev=/dev/$(lsblk -no PKNAME "$(findmnt -no SOURCE /mnt/g16-external)" 2>/dev/null | head -1)
              ( for i in $(seq 1 120); do systemctl is-active --quiet g16-steam && break; sleep 1; done
                systemctl set-property --runtime g16-steam.service "IOReadBandwidthMax=$dev $G16_IO_THROTTLE" \
                  && echo "io-throttle g16-steam $dev $G16_IO_THROTTLE $(systemctl show -p IOReadBandwidthMax g16-steam.service)" >> "$observe/verdicts.txt" ) &
          fi
          EXPECT_DRIVER=$drv/libvulkan_asahi.so WATCH_LIMIT=300 WATCH_MIN_KB=2097152 \
              timeout 600 bash $R/run-variant.sh "$label" "$variant" > "$observe/dota-harness.log" 2>&1
          [ -n "${keepalive:-}" ] && { kill $keepalive 2>/dev/null; echo "keepalive: $(grep -c 'idle t=' "$observe/keepalive.log") submits, $(grep -h STALL "$observe/keepalive.log" | head -1)" >> "$observe/verdicts.txt"; }
          kill $shotter 2>/dev/null; ls "$observe/shots" | tr '\n' ' ' | sed 's/^/shots: /' >> "$observe/verdicts.txt"; echo >> "$observe/verdicts.txt"
          echo "dota variant=$variant rc=$?" >> "$observe/verdicts.txt"
          echo "driver-stamp $drv/libvulkan_asahi.so $(strings "$drv/libvulkan_asahi.so" | grep -m1 -oE 'git-[0-9a-f]+') $(sha256sum "$drv/libvulkan_asahi.so" | cut -c1-16)" >> "$observe/verdicts.txt"
          sleep 5; dmesg | grep "G16: queue deps" > "$observe/dep-stats.txt" 2>/dev/null
          grep -h "HK_APPLE9_VARIANT_STATS" "$R/results/$label/application.log" 2>/dev/null | tail -1 | sed 's/^/variant-stats-last: /' >> "$observe/verdicts.txt"
          grep -c "hk-va-quarantine pressure" "$R/results/$label/application.log" 2>/dev/null | sed 's/^/quarantine-pressure-lines=/' >> "$observe/verdicts.txt"
          cp -a "$R/results/$label" "$observe/dota-results" 2>/dev/null
          cp "/mnt/g16-external/SteamLibrary/steamapps/common/dota 2 beta/game/dota/console.log" "$observe/dota-console.log" 2>/dev/null
          A=/mnt/g16-external/SteamLibrary/steamapps/appmanifest_570.acf
          cp "$A" "$observe/appmanifest_570.acf" 2>/dev/null
          echo "dota-build $(grep -oE '"(buildid|LastUpdated|TargetBuildID)"[[:space:]]+"[0-9]+"' "$A" 2>/dev/null | tr -s ' \t' ' ' | tr '\n' ' ') steam.inf=$(grep -hE 'PatchVersion|ClientVersion' "/mnt/g16-external/SteamLibrary/steamapps/common/dota 2 beta/game/dota/steam.inf" 2>/dev/null | tr '\n' ' ') shadercache=$(stat -c '%s@%y' "/mnt/g16-external/SteamLibrary/steamapps/common/dota 2 beta/game/dota/shadercache/vulkan/shaders.cache.blob" 2>/dev/null)" >> "$observe/verdicts.txt"
          mkdir -p "$observe/steam-logs"
          cp -a /home/nsheth/.local/share/Steam/logs/{stderr.txt,console_log.txt,connection_log.txt,bootstrap_log.txt,content_log.txt} "$observe/steam-logs/" 2>/dev/null
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
    # Idle->busy (manager): bursts of 4 two-pass 1280x720 renders, GPU drained, then a multi-second idle; Dota's pinned ICD.
    # Dota loading-end shape (manager): after a drained idle, C compute Works (~ms each) back-to-back, then 4 renders.
    rb-cidle6|rb-cidle6x3|rb-cidle2)
        case $t in rb-cidle6) ms=6000 c=2 ;; rb-cidle6x3) ms=6000 c=3 ;; rb-cidle2) ms=2000 c=2 ;; esac
        run_user $t 330 env \
            $rb --passes 2 --inflight 4 --burst 4 --idle-ms $ms --pre-compute $c --compute-iters 20000 --seconds 300 --timeout-ms 15000 ;;
    # Block 62 (manager): the loading-end shape with Dota-like renders -- 2 kernel-resolved waits per render (already
    # signalled), heavy TA (4000 fullscreen instances per pass), 2-3 computes right before, after a 6 s drained idle, under
    # the synthetic host load (dd + zstd on the external disk, restarted every 120 s). rb-wlc6 = renders also wait on the
    # last compute (RAC-like control: no overlap).
    rb-wl6|rb-wl6x3|rb-wlc6|rb-wl6d|rb-wl6dx3)
        case $t in rb-wl6) c=2 x= ;; rb-wl6x3) c=3 x= ;; rb-wlc6) c=2 x=--wait-compute ;; rb-wl6d) c=2 x=--two-devices ;; rb-wl6dx3) c=3 x=--two-devices ;; esac
        big=/mnt/g16-external/codex-dota-replay-20261008/dota_frames_1_through_1800.gfxr
        mountpoint -q /mnt/g16-external || mount -o ro /dev/sda1 /mnt/g16-external
        ( while :; do timeout 120 dd if="$big" of=/dev/null bs=4M iflag=direct status=none & timeout 120 nice -n 5 zstd -q -19 -T4 -c "$big" > /dev/null; wait; done ) &
        loadpid=$!
        run_user $t 280 env $rb --passes 2 --inflight 4 --burst 4 --idle-ms 6000 --pre-compute $c --compute-iters 20000 \
            --render-waits 2 --instances 4000 $x --seconds 240 --timeout-ms 15000
        kill $loadpid 2>/dev/null; pkill -f "zstd -q -19 -T4 -c $big"; pkill -f "dd if=$big"
        echo "$t load stopped" >> "$observe/verdicts.txt" ;;
    rb-idle6|rb-idle2|rb-idle0)
        ms=${t#rb-idle}; ms=$((ms * 1000)); [ "$ms" = 0 ] && ms=1
        run_user $t 330 env \
            $rb --passes 2 --inflight 4 --burst 4 --idle-ms $ms --seconds 300 --timeout-ms 15000 ;;
    rp-firstbig)
        # Partner renders a 1280x720 swapchain throughout (like KWin/Xwayland drawing that shape); 20 fresh
        # processes each draw 60 small-only frames, then their first 1280x720 swapchain LOAD+blend pass.
        runuser -u nsheth -- env HOME=/home/nsheth bash -c 'source /home/nsheth/.local/state/m4/session.env; export HK_EXPERIMENTAL_APPLE9=1; exec "$0" --passes 3 --offscreen 0 --inflight 2 --mode fifo --seconds 400' "$rp" > "$observe/rp-partner.log" 2>&1 &
        partner=$!
        sleep 3
        cat > "$observe/rp-firstbig.sh" <<FB
#!/bin/bash
for i in \$(seq 1 20); do echo "== attempt \$i"; "$rp" --warmup-small 60 --passes 3 --offscreen 0 --inflight 2 --mode fifo --seconds 6 --timeout-ms 4000 || echo "attempt \$i rc=\$?"; done
FB
        chmod 755 "$observe/rp-firstbig.sh"
        run_user rp-firstbig 300 "$observe/rp-firstbig.sh"
        kill $partner 2>/dev/null ;;
    rp-storm|rp-storm-rc)
        # Resize storm (manager, 2026-10-08): A4 in k51-q2000-1 was submitted within ~1 s of Dota's SUBOPTIMAL
        # (KWin growing the borderless window). Toggle a 1280x720 render_present window to 1920x1080 every
        # 700 ms while it keeps rendering 1280x720 offscreen + swapchain LOAD passes; a plain partner keeps
        # another client busy. rp-storm-rc also recreates the swapchain after SUBOPTIMAL (as Dota does).
        rc_flag=; [ "$t" = rp-storm-rc ] && rc_flag=--recreate
        runuser -u nsheth -- env HOME=/home/nsheth bash -c 'source /home/nsheth/.local/state/m4/session.env; export HK_EXPERIMENTAL_APPLE9=1; exec "$0" --passes 3 --offscreen 0 --inflight 2 --mode fifo --seconds 270' "$rp" > "$observe/$t-partner.log" 2>&1 &
        partner=$!
        sleep 3
        run_user $t 270 $rp --passes 3 --offscreen 4 --inflight 2 --mode fifo --seconds 240 --resize-ms 700 $rc_flag
        kill $partner 2>/dev/null; wait $partner 2>/dev/null
        grep -E "PASS|STALL|resizes=" "$observe/$t.log" | tail -1 | sed "s/^/$t: /" >> "$observe/verdicts.txt"
        grep -E "PASS|STALL|resizes=" "$observe/$t-partner.log" | tail -1 | sed "s/^/$t partner: /" >> "$observe/verdicts.txt" ;;
    rp-mstorm|rp-mstorm-rc)
        # Resize storm through Dota's path (manager): x86 render_present under FEX in m4-muvm (virtgpu native
        # context + muvm X11 bridge), heavier frames, IMMEDIATE like Dota; host aarch64 partner keeps KWin busy.
        rc_flag=; [ "$t" = rp-mstorm-rc ] && rc_flag=--recreate
        install -o nsheth -g nsheth -m 755 "$observe/extra/render_present.x86" /home/nsheth/.cache/render_present.x86
        printf '#!/bin/bash\n/home/nsheth/.cache/render_present.x86 --passes 3 --offscreen 6 --work 16 --inflight 3 --mode immediate --seconds 240 --timeout-ms 8000 --resize-ms 700 %s > /home/nsheth/.cache/%s.log 2>&1\necho "rc=$?" >> /home/nsheth/.cache/%s.log\n' "$rc_flag" "$t" "$t" > /home/nsheth/.cache/$t.sh
        chown nsheth:nsheth /home/nsheth/.cache/$t.sh; chmod 755 /home/nsheth/.cache/$t.sh; rm -f /home/nsheth/.cache/$t.log
        runuser -u nsheth -- env HOME=/home/nsheth bash -c 'source /home/nsheth/.local/state/m4/session.env; export HK_EXPERIMENTAL_APPLE9=1; exec "$0" --passes 3 --offscreen 0 --inflight 2 --mode fifo --seconds 280' "$rp" > "$observe/$t-partner.log" 2>&1 &
        partner=$!
        sleep 3
        run_user $t 300 m4-muvm /bin/bash /home/nsheth/.cache/$t.sh
        kill $partner 2>/dev/null; wait $partner 2>/dev/null
        cp /home/nsheth/.cache/$t.log "$observe/$t-guest.log" 2>/dev/null
        grep -E "PASS|STALL|resizes=|rc=" "$observe/$t-guest.log" | tail -2 | tr '\n' ' ' | sed "s/^/$t guest: /" >> "$observe/verdicts.txt"; echo >> "$observe/verdicts.txt"
        grep -E "PASS|STALL|resizes=" "$observe/$t-partner.log" | tail -1 | sed "s/^/$t partner: /" >> "$observe/verdicts.txt" ;;
    rp-burst|rp-mburst)
        # Burst synthetic (manager, 2026-10-08): A4 = firmware-wide wedge right after Dota's loading-end burst
        # (3x 1280x720 LOAD renders + its first-ever 1920x1080 render within ~100 us, after a COPY switch).
        # 45 fresh processes, 1920x1080 swapchain, 30 small warmup frames, then the burst. i%3==0: 1280x720 window
        # (COPY throughout); 1/2: 1920x1080 window (FLIP) resized to 1280x720 400/50 ms before the burst (FLIP->COPY,
        # Dota's sequence; claude-driver: COPY makes a Dota<->Xwayland fence ping-pong on the same image). A host partner renders throughout.
        # rp-mburst runs the attempts as x86 under FEX inside one m4-muvm (Dota's path).
        cat > /home/nsheth/.cache/$t.sh <<BURST
#!/bin/bash
bin=\$1
for i in \$(seq 1 45); do
    case \$((i % 3)) in
    0) extra= ;;
    1) extra="--win-w 1920 --win-h 1080 --resize-w 1280 --resize-h 720 --burst-resize-ms 400" ;;
    2) extra="--win-w 1920 --win-h 1080 --resize-w 1280 --resize-h 720 --burst-resize-ms 50" ;;
    esac
    echo "== attempt \$i \$extra"
    "\$bin" --width 1280 --height 720 --swap-w 1920 --swap-h 1080 --warmup-small 30 --offscreen 3 --passes 1 --inflight 2 --mode immediate --seconds 4 --timeout-ms 4000 \$extra || echo "attempt \$i rc=\$?"
done
echo "burst loop done"
BURST
        chown nsheth:nsheth /home/nsheth/.cache/$t.sh; chmod 755 /home/nsheth/.cache/$t.sh
        install -o nsheth -g nsheth -m 755 "$observe/extra/render_present.x86" /home/nsheth/.cache/render_present.x86
        runuser -u nsheth -- env HOME=/home/nsheth bash -c 'source /home/nsheth/.local/state/m4/session.env; export HK_EXPERIMENTAL_APPLE9=1; exec "$0" --passes 3 --offscreen 0 --inflight 2 --mode fifo --seconds 600' "$rp" > "$observe/$t-partner.log" 2>&1 &
        partner=$!
        sleep 3
        if [ "$t" = rp-burst ]; then
            run_user $t 400 /home/nsheth/.cache/$t.sh "$rp"
        else
            run_user $t 500 m4-muvm /bin/bash -c "/home/nsheth/.cache/$t.sh /home/nsheth/.cache/render_present.x86 > /home/nsheth/.cache/$t-guest.log 2>&1"
            cp /home/nsheth/.cache/$t-guest.log "$observe/$t-guest.log" 2>/dev/null
        fi
        kill $partner 2>/dev/null; wait $partner 2>/dev/null
        f="$observe/$t.log"; [ "$t" = rp-mburst ] && f="$observe/$t-guest.log"
        echo "$t: attempts=$(grep -c '^== attempt' "$f" 2>/dev/null) pass=$(grep -c '^PASS' "$f" 2>/dev/null) stall=$(grep -c '^STALL' "$f" 2>/dev/null) fail=$(grep -c 'rc=' "$f" 2>/dev/null) first-big=$(grep -m1 -o 'first swapchain pass.*' "$f")" >> "$observe/verdicts.txt" ;;
    rp-sburst|rp-msburst|rp-1burst|rp-m1burst)
        # Split-submit burst (claude-compiler cadence): every 3rd frame, CLEAR + 2 LOAD 1280x720 passes into a freshly
        # discarded intermediate, each its own vkQueueSubmit, plus a 1920x1080 swapchain pass; two partner clients
        # (1280x720 fifo + 1920x1080 immediate). rp-msburst runs the burst process as x86/FEX in m4-muvm.
        install -o nsheth -g nsheth -m 755 "$observe/extra/render_present.x86" /home/nsheth/.cache/render_present.x86
        args="--width 1280 --height 720 --swap-w 1920 --swap-h 1080 --warmup-small 10 --burst-every 3 --split-burst --offscreen 3 --passes 1 --inflight 2 --mode immediate --seconds 120 --timeout-ms 4000"
        case "$t" in rp-1burst|rp-m1burst) args=${args/--split-burst /} ;; esac
        for pp in 1 2; do
            pargs="--passes 3 --offscreen 0 --inflight 2 --mode fifo --seconds 170"; [ $pp = 2 ] && pargs="--width 1920 --height 1080 --passes 2 --offscreen 2 --inflight 2 --mode immediate --seconds 170"
            runuser -u nsheth -- env HOME=/home/nsheth bash -c 'source /home/nsheth/.local/state/m4/session.env; export HK_EXPERIMENTAL_APPLE9=1; exec "$0" $1' "$rp" "$pargs" > "$observe/$t-partner$pp.log" 2>&1 &
            eval partner$pp=\$!
        done
        sleep 3
        if [ "$t" = rp-sburst ] || [ "$t" = rp-1burst ]; then
            run_user $t 180 $rp $args
        else
            printf '#!/bin/bash\n/home/nsheth/.cache/render_present.x86 %s > /home/nsheth/.cache/%s-guest.log 2>&1\n' "$args" "$t" > /home/nsheth/.cache/$t.sh; chown nsheth:nsheth /home/nsheth/.cache/$t.sh; chmod 755 /home/nsheth/.cache/$t.sh
            run_user $t 200 m4-muvm /bin/bash /home/nsheth/.cache/$t.sh
            cp /home/nsheth/.cache/$t-guest.log "$observe/$t-guest.log" 2>/dev/null
        fi
        kill $partner1 $partner2 2>/dev/null; wait $partner1 $partner2 2>/dev/null
        f="$observe/$t.log"; case "$t" in rp-msburst|rp-m1burst) f="$observe/$t-guest.log" ;; esac
        echo "$t: $(grep -E 'PASS|STALL' "$f" | tail -1) partners: $(grep -hE 'PASS|STALL|frames=' "$observe/$t-partner1.log" "$observe/$t-partner2.log" | tail -2 | tr '\n' ' ')" >> "$observe/verdicts.txt" ;;
    rp-a) run_user rp-a 90 $rp --passes 3 --offscreen 4 --inflight 2 --mode fifo --seconds 60 ;;
    rp-b) run_user rp-b 90 $rp --passes 3 --offscreen 8 --inflight 3 --mode mailbox --seconds 60 ;;
    rp-c) run_user rp-c 90 $rp --passes 3 --offscreen 0 --inflight 3 --mode immediate --seconds 60 ;;
    steam-update)
        # Dedicated update window (manager): Steam online alone, no Dota, until pending updates (CS2 730, any 570) are
        # Fully Installed or ~12 min pass; then a clean Steam shutdown. Library left clean for the offline arms.
        Rg=/home/nsheth/g16-games/dota-shader-identity-20261006
        m4-steam-shutdown 45; systemctl stop g16-steam 2>/dev/null; sleep 3
        systemd-run --unit=g16-steam --collect --uid=nsheth --setenv=HOME=/home/nsheth /bin/bash $Rg/steam-host.sh
        CL=/home/nsheth/.local/share/Steam/logs/content_log.txt; t0=$(date +%s)
        sleep 60
        while [ $(( $(date +%s) - t0 )) -lt 720 ]; do
            stalled && finish_stall "$t"
            last730=$(grep -a "AppID 730 state changed" "$CL" | tail -1); last570=$(grep -a "AppID 570 state changed" "$CL" | tail -1)
            case "$last730" in *"state changed : Fully Installed,"|*"state changed : Fully Installed, ") case "$last570" in *Update*) ;; *) break;; esac;; esac
            sleep 20
        done
        echo "steam-update after $(( $(date +%s) - t0 )) s: 730=[$(grep -a 'AppID 730 state changed' "$CL" | tail -1 | cut -c1-110)] 570=[$(grep -a 'AppID 570 state changed' "$CL" | tail -1 | cut -c1-110)]" >> "$observe/verdicts.txt"
        grep -aE "update started|starting commit|Fully Installed,|download rate" "$CL" | tail -30 > "$observe/steam-update-content.txt"
        m4-steam-shutdown 45; systemctl stop g16-steam 2>/dev/null ;;
    replay-steam)
        # Replay loop with the Steam client running (manager, 2026-10-08): live Dota runs alongside Steam (g16-steam,
        # steam-host.sh, in the same muvm VM; its UI renders ~300x650 on another slot), the replay sessions did not.
        # Start Steam exactly as run-variant.sh does, wait 75 s, then x86 replays inside m4-muvm (joining Steam's VM)
        # x8 and native replays x6 alongside it; then stop Steam cleanly.
        Rg=/home/nsheth/g16-games/dota-shader-identity-20261006
        m4-steam-shutdown 45; systemctl stop g16-steam 2>/dev/null; sleep 3
        if [ "${G16_STEAM_OFFLINE:-}" = 1 ]; then LU=/home/nsheth/.local/share/Steam/config/loginusers.vdf
            sed -i -E 's/("WantsOfflineMode"[[:space:]]+)"0"/\1"1"/; s/("SkipOfflineModeWarning"[[:space:]]+)"0"/\1"1"/' "$LU"; echo "steam-offline $(grep -cE '"(WantsOfflineMode|SkipOfflineModeWarning)"[[:space:]]+"1"' "$LU")/2" >> "$observe/verdicts.txt"; fi
        systemd-run --unit=g16-steam --collect --uid=nsheth --setenv=HOME=/home/nsheth /bin/bash $Rg/steam-host.sh
        sleep 75
        pgrep -af "steamwebhelper|steam.sh|ubuntu12_32/steam" | cut -c1-150 | head -5 > "$observe/$t-steam-procs.txt"
        mkdir -p "$observe/driver-trace"
        cp "$observe/extra/libvulkan_asahi.quar.so" "$observe/driver-trace/libvulkan_asahi.so"
        printf '{"file_format_version": "1.0.0", "ICD": {"library_path": "./libvulkan_asahi.so", "api_version": "1.4.0"}}\n' > "$observe/driver-trace/icd.json"
        chmod -R a+rX "$observe/driver-trace"; chmod 755 "$observe/extra/gfxrecon-replay.a64"; chmod a+rx "$observe" "$observe/extra"
        trace=/mnt/g16-external/codex-dota-replay-20261008/dota_frames_1_through_1800.gfxr
        cat > /home/nsheth/.cache/$t-x86.sh <<RL
#!/bin/bash
for i in \$(seq 1 8); do
    echo "== replay \$i \$(date +%T)"
    /opt/mesa-apple9-x86/gfxrecon-replay --wsi xcb -m rebind --sfa "$trace" > /home/nsheth/.cache/$t-last.log 2>&1
    echo "rc=\$? \$(grep -oE 'Frame: [0-9]+' /home/nsheth/.cache/$t-last.log | tail -1)"
done
RL
        cat > /home/nsheth/.cache/$t-a64.sh <<RL
#!/bin/bash
for i in \$(seq 1 6); do
    echo "== replay \$i \$(date +%T)"
    env VK_DRIVER_FILES="$observe/driver-trace/icd.json" VK_LOADER_LAYERS_DISABLE='~implicit~' HK_PERFTEST=batch \
        "$observe/extra/gfxrecon-replay.a64" --wsi xcb -m rebind --sfa "$trace" > /home/nsheth/.cache/$t-a64-last.log 2>&1
    echo "rc=\$? \$(grep -oE 'Frame: [0-9]+' /home/nsheth/.cache/$t-a64-last.log | tail -1)"
done
RL
        chown nsheth:nsheth /home/nsheth/.cache/$t-x86.sh /home/nsheth/.cache/$t-a64.sh; chmod 755 /home/nsheth/.cache/$t-x86.sh /home/nsheth/.cache/$t-a64.sh; rm -f /home/nsheth/.cache/$t-guest.log
        run_user $t-x86 400 m4-muvm /bin/bash -c "/home/nsheth/.cache/$t-x86.sh > /home/nsheth/.cache/$t-guest.log 2>&1"
        cp /home/nsheth/.cache/$t-guest.log "$observe/$t-x86-guest.log" 2>/dev/null
        run_user $t-a64 300 /home/nsheth/.cache/$t-a64.sh
        m4-steam-shutdown 45; systemctl stop g16-steam 2>/dev/null
        echo "$t: steam-procs=$(wc -l < "$observe/$t-steam-procs.txt") x86 replays=$(grep -c '^== replay' "$observe/$t-x86-guest.log" 2>/dev/null) ok=$(grep -c '^rc=0 Frame: 116' "$observe/$t-x86-guest.log" 2>/dev/null) a64 replays=$(grep -c '^== replay' "$observe/$t-a64.log") ok=$(grep -c '^rc=0 Frame: 116' "$observe/$t-a64.log")" >> "$observe/verdicts.txt" ;;
    replay-loop|replay-loop-x86)
        # Exposure loop (A4 is ~40% per live run): the full gfxr trace (116 frames, ~27 s) replayed back to back,
        # -m rebind --sfa, native trace driver (replay-loop) or x86 in m4-muvm (replay-loop-x86), up to 12 times,
        # stopping at a G16 hang.
        mkdir -p "$observe/driver-trace"
        cp "$observe/extra/libvulkan_asahi.quar.so" "$observe/driver-trace/libvulkan_asahi.so"
        printf '{"file_format_version": "1.0.0", "ICD": {"library_path": "./libvulkan_asahi.so", "api_version": "1.4.0"}}\n' > "$observe/driver-trace/icd.json"
        chmod -R a+rX "$observe/driver-trace"; chmod 755 "$observe/extra/gfxrecon-replay.a64"; chmod a+rx "$observe" "$observe/extra"
        trace=/mnt/g16-external/codex-dota-replay-20261008/dota_frames_1_through_1800.gfxr
        if [ "$t" = replay-loop ]; then
            cat > /home/nsheth/.cache/$t.sh <<RL
#!/bin/bash
for i in \$(seq 1 12); do
    echo "== replay \$i \$(date +%T)"
    env VK_DRIVER_FILES="$observe/driver-trace/icd.json" VK_LOADER_LAYERS_DISABLE='~implicit~' HK_PERFTEST=batch \
        "$observe/extra/gfxrecon-replay.a64" --wsi xcb -m rebind --sfa "$trace" > /home/nsheth/.cache/$t-last.log 2>&1
    echo "rc=\$? \$(grep -oE 'Frame: [0-9]+' /home/nsheth/.cache/$t-last.log | tail -1)"
done
RL
            chown nsheth:nsheth /home/nsheth/.cache/$t.sh; chmod 755 /home/nsheth/.cache/$t.sh
            run_user $t 420 /home/nsheth/.cache/$t.sh
        else
            cat > /home/nsheth/.cache/$t.sh <<RL
#!/bin/bash
for i in \$(seq 1 8); do
    echo "== replay \$i \$(date +%T)"
    /opt/mesa-apple9-x86/gfxrecon-replay --wsi xcb -m rebind --sfa "$trace" > /home/nsheth/.cache/$t-last.log 2>&1
    echo "rc=\$? \$(grep -oE 'Frame: [0-9]+' /home/nsheth/.cache/$t-last.log | tail -1)"
done
RL
            chown nsheth:nsheth /home/nsheth/.cache/$t.sh; chmod 755 /home/nsheth/.cache/$t.sh; rm -f /home/nsheth/.cache/$t-guest.log
            run_user $t 420 m4-muvm /bin/bash -c "/home/nsheth/.cache/$t.sh > /home/nsheth/.cache/$t-guest.log 2>&1"
            cp /home/nsheth/.cache/$t-guest.log "$observe/$t-guest.log" 2>/dev/null; cat "$observe/$t-guest.log" >> "$observe/$t.log" 2>/dev/null
        fi
        echo "$t: replays=$(grep -c '^== replay' "$observe/$t.log") ok=$(grep -c '^rc=0 Frame: 116' "$observe/$t.log") results=$(grep '^rc=' "$observe/$t.log" | sort | uniq -c | tr '\n' ' ')" >> "$observe/verdicts.txt" ;;
    replay-rb|replay-rb-x86|replay-sfa)
        # Content-exact replay toward Dota's loading-end burst (manager (a), 2026-10-08). Earlier replays died at
        # API call 113517 (vkCreateBuffer OUT_OF_DEVICE_MEMORY) still in frame 1, so they never reached the burst.
        # -m rebind --sfa remaps capture-time memory; the trace driver (5567bc4) logs 1280x720 passes (HK_PASS_TRACE).
        # replay-rb-x86: the x86 gfxrecon-replay under FEX inside m4-muvm (Dota's path).
        mkdir -p "$observe/driver-trace"
        cp "$observe/extra/libvulkan_asahi.quar.so" "$observe/driver-trace/libvulkan_asahi.so"
        printf '{"file_format_version": "1.0.0", "ICD": {"library_path": "./libvulkan_asahi.so", "api_version": "1.4.0"}}\n' > "$observe/driver-trace/icd.json"
        chmod -R a+rX "$observe/driver-trace"; chmod 755 "$observe/extra/gfxrecon-replay.a64"; chmod a+rx "$observe" "$observe/extra"
        trace=/mnt/g16-external/codex-dota-replay-20261008/dota_frames_1_through_1800.gfxr
        # Progress sampler: replay read_bytes / state / wchan every 20 s (CPU-side halts vs slow trace I/O).
        ( while sleep 20; do p=$(pgrep -n -f "gfxrecon-replay" || true); [ -n "$p" ] || continue
            echo "$(date +%T) pid=$p $(grep -E '^read_bytes' /proc/$p/io 2>/dev/null) state=$(awk '{print $3}' /proc/$p/stat 2>/dev/null) wchan=$(cat /proc/$p/wchan 2>/dev/null) cpu=$(ps -o %cpu= -p $p)"; done ) > "$observe/$t-progress.log" 2>&1 &
        sampler=$!
        case "$t" in
        replay-rb) mode="-m rebind --sfa" ;;
        replay-sfa) mode="--sfa" ;;
        esac
        if [ "$t" != replay-rb-x86 ]; then
            run_user $t 400 env VK_DRIVER_FILES="$observe/driver-trace/icd.json" VK_LOADER_LAYERS_DISABLE='~implicit~' HK_PERFTEST=batch HK_PASS_TRACE=1280x720 HK_WSI_TRACE=1 \
                "$observe/extra/gfxrecon-replay.a64" --wsi xcb --log-level info $mode "$trace"
        else
            printf '#!/bin/bash\nls -la %s > /home/nsheth/.cache/%s-guest.log 2>&1\nHK_PASS_TRACE=1280x720 HK_WSI_TRACE=1 /opt/mesa-apple9-x86/gfxrecon-replay --wsi xcb --log-level info -m rebind --sfa %s >> /home/nsheth/.cache/%s-guest.log 2>&1\necho "rc=$?" >> /home/nsheth/.cache/%s-guest.log\n' "$trace" "$t" "$trace" "$t" "$t" > /home/nsheth/.cache/$t.sh
            chown nsheth:nsheth /home/nsheth/.cache/$t.sh; chmod 755 /home/nsheth/.cache/$t.sh; rm -f /home/nsheth/.cache/$t-guest.log
            run_user $t 400 m4-muvm /bin/bash /home/nsheth/.cache/$t.sh
            cp /home/nsheth/.cache/$t-guest.log "$observe/$t-guest.log" 2>/dev/null; cat "$observe/$t-guest.log" >> "$observe/$t.log" 2>/dev/null
        fi
        kill $sampler 2>/dev/null
        echo "$t: last-frame=$(grep -oE 'Frame: [0-9]+' "$observe/$t.log" | tail -1) fatal=$(grep -m1 -oE 'API call at index: [0-9]+.*' "$observe/$t.log" | cut -c1-140) pass1280=$(grep -c 'hk-pass' "$observe/$t.log")" >> "$observe/verdicts.txt" ;;
    replay) run_user replay 240 env HK_DEBUG=perf VK_DRIVER_FILES=/home/nsheth/g16-games/dota-shader-identity-20261006/driver/icd.json VK_LOADER_LAYERS_DISABLE='~implicit~' HK_PERFTEST=batch \
            /home/nsheth/g16-games/codex-dota-replay-20261008/gfxrecon-replay --wsi xcb /mnt/g16-external/codex-dota-replay-20261008/dota_frames_1_through_1800.gfxr ;;
    *) echo "unknown test $t" >> "$observe/verdicts.txt" ;;
    esac
done
echo "NO-STALL all tests" >> "$observe/verdicts.txt"
ps -eo pid,ppid,user,comm,args --sort=pid > "$observe/ps-at-end.txt" 2>&1
dmesg > "$observe/kernel.log"
journalctl -k -b --no-pager > "$observe/kernel-journal.log" 2>&1
