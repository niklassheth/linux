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
          case "$variant" in stats)
              # claude-compiler's variant-stats build (8825824 + HK_APPLE9_VARIANT_STATS), not an A4 arm.
              mkdir -p "$R/driver-stats"
              cp "$observe/extra/libvulkan_asahi.stats.so" "$R/driver-stats/libvulkan_asahi.so"
              printf '{"file_format_version": "1.0.0", "ICD": {"library_path": "./libvulkan_asahi.so", "api_version": "1.4.0"}}\n' > "$R/driver-stats/icd.json"
              grep -qF "stats) " "$R/dota-inner.sh" || sed -i "s|case \"\\\$variant\" in |case \"\$variant\" in stats) export VK_DRIVER_FILES=\"\$root/driver-stats/icd.json\" HK_APPLE9_DUMP_MODE=0 HK_APPLE9_VARIANT_STATS=1;; |" "$R/dota-inner.sh"
              chown -R nsheth:nsheth "$R/driver-stats" "$R/dota-inner.sh"
              grep -o "stats)[^;]*" "$R/dota-inner.sh" >> "$observe/verdicts.txt" ;;
          esac
          case "$variant" in mode0) drv=$R/driver ;; quar*) drv=$R/driver-quar ;; stats) drv=$R/driver-stats ;; fb0|fb1) drv=$R/driver-fb-a64 ;; inst) drv=/usr/lib64 ;; vatrace) drv=$R/driver-vatrace ;; exportid|exporthash) drv=$R/driver-export ;; fixed) drv=$R/driver-fixed ;; *) echo "bad variant $variant" >> "$observe/verdicts.txt"; continue ;; esac
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
          grep -h "HK_APPLE9_VARIANT_STATS" "$R/results/$label/application.log" 2>/dev/null | tail -1 | sed 's/^/variant-stats-last: /' >> "$observe/verdicts.txt"
          grep -c "hk-va-quarantine pressure" "$R/results/$label/application.log" 2>/dev/null | sed 's/^/quarantine-pressure-lines=/' >> "$observe/verdicts.txt"
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
    rp-a) run_user rp-a 90 $rp --passes 3 --offscreen 4 --inflight 2 --mode fifo --seconds 60 ;;
    rp-b) run_user rp-b 90 $rp --passes 3 --offscreen 8 --inflight 3 --mode mailbox --seconds 60 ;;
    rp-c) run_user rp-c 90 $rp --passes 3 --offscreen 0 --inflight 3 --mode immediate --seconds 60 ;;
    replay-rb|replay-rb-x86)
        # Content-exact replay toward Dota's loading-end burst (manager (a), 2026-10-08). Earlier replays died at
        # API call 113517 (vkCreateBuffer OUT_OF_DEVICE_MEMORY) still in frame 1, so they never reached the burst.
        # -m rebind --sfa remaps capture-time memory; the trace driver (5567bc4) logs 1280x720 passes (HK_PASS_TRACE).
        # replay-rb-x86: the x86 gfxrecon-replay under FEX inside m4-muvm (Dota's path).
        mkdir -p "$observe/driver-trace"
        cp "$observe/extra/libvulkan_asahi.quar.so" "$observe/driver-trace/libvulkan_asahi.so"
        printf '{"file_format_version": "1.0.0", "ICD": {"library_path": "./libvulkan_asahi.so", "api_version": "1.4.0"}}\n' > "$observe/driver-trace/icd.json"
        chmod -R a+rX "$observe/driver-trace"; chmod 755 "$observe/extra/gfxrecon-replay.a64"; chmod a+rx "$observe" "$observe/extra"
        trace=/mnt/g16-external/codex-dota-replay-20261008/dota_frames_1_through_1800.gfxr
        if [ "$t" = replay-rb ]; then
            run_user $t 600 env VK_DRIVER_FILES="$observe/driver-trace/icd.json" VK_LOADER_LAYERS_DISABLE='~implicit~' HK_PERFTEST=batch HK_PASS_TRACE=1280x720 HK_WSI_TRACE=1 \
                "$observe/extra/gfxrecon-replay.a64" --wsi xcb -m rebind --sfa "$trace"
        else
            run_user $t 600 m4-muvm /opt/mesa-apple9-x86/gfxrecon-replay --wsi xcb -m rebind --sfa "$trace"
        fi
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
