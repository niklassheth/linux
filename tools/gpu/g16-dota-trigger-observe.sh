#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Leased mini, fresh RO boot. Stage is tmpfs; all capture sizes are bounded.
set -euo pipefail
: "${G16_OBSERVATION_DIR:?set directory under /tmp}"
case "$G16_OBSERVATION_DIR" in /tmp/codex-dota-*) ;; *) exit 64 ;; esac
observe=$G16_OBSERVATION_DIR
capture_stage=trigger
case ",$(findmnt -no OPTIONS /)," in *,ro,*) ;; *) exit 1 ;; esac
[ "$(findmnt -no FSTYPE /tmp)" = tmpfs ] || exit 1
swapoff -a
if ! mountpoint -q /home; then
    root_source=$(findmnt -no SOURCE /); root_source=${root_source%%\[*}
    mount -o ro,subvol=home "$root_source" /home
fi
case ",$(findmnt -no OPTIONS /home)," in *,ro,*) ;; *) exit 1 ;; esac
for desktop_dir in .config .local .cache; do
    overlay_dir=/run/codex-dota-overlay/$desktop_dir
    mkdir -p "$overlay_dir/upper" "$overlay_dir/work"
    mount -t overlay overlay -o "lowerdir=/home/nsheth/$desktop_dir,upperdir=$overlay_dir/upper,workdir=$overlay_dir/work" "/home/nsheth/$desktop_dir"
done
games=/home/nsheth/g16-games
mkdir -p /run/codex-dota-games/upper /run/codex-dota-games/work
mount -t overlay overlay -o "lowerdir=$games,upperdir=/run/codex-dota-games/upper,workdir=/run/codex-dota-games/work" "$games"
# The RO boot does not automatically provide the external game volume.
# Mount its backing read-only before starting muvm, then use a tmpfs upper
# for runtime locks, game logs and Steam metadata.
external=/mnt/g16-external
mountpoint -q "$external" || mount -o ro /dev/disk/by-label/USB4-TEST "$external"
case ",$(findmnt -no OPTIONS "$external")," in *,ro,*) ;; *) exit 1 ;; esac
mkdir -p /run/codex-dota-external/upper /run/codex-dota-external/work
mount -t overlay overlay -o "lowerdir=$external,upperdir=/run/codex-dota-external/upper,workdir=/run/codex-dota-external/work" "$external"
test -r "$external/SteamLibrary/steamapps/common/SteamLinuxRuntime_sniper/_v2-entry-point"
results=$games/dota-shader-identity-20261006/results
chmod 1777 "$observe"
if [ "$capture_stage" = trigger ]; then
    # Match run-variant.sh's scene-quality input inside the temporary Steam
    # overlay. Preserve the exact file used without modifying persistent home.
    video_source=$games/dota-civ-followup-20261006/dota-video-low.txt
    video_target=/home/nsheth/.local/share/Steam/userdata/147853552/570/local/cfg/video.txt
    test -r "$video_source"
    cp "$video_source" "$video_target"
    chown nsheth:nsheth "$video_target"
    cp "$video_source" "$observe/dota-video-input.txt"
fi
sed -e 's/^loginctl enable-linger "$desktop_user"$/loginctl enable-linger "$desktop_user" || true/' -e 's/^runuser -u /timeout 15 runuser -u /' /usr/local/bin/m4-post-boot > "$observe/post-boot.sh"
bash "$observe/post-boot.sh" > "$observe/post-boot.log" 2>&1
systemctl is-active m4-kwin claude-headless input-forward-server > "$observe/services-before.txt"
uname -a > "$observe/kernel.txt"
cat /proc/cmdline >> "$observe/kernel.txt"
findmnt -R /mnt/g16-external > "$observe/external-mount.txt"
find /usr/share/vulkan /home/nsheth/.local/share/vulkan /usr/local/share/vulkan -type f -name "*.json" > "$observe/vulkan-manifests.txt" 2>&1 || true
findmnt -no TARGET,FSTYPE,OPTIONS -T / >> "$observe/kernel.txt"
findmnt -no TARGET,FSTYPE,OPTIONS -T /home >> "$observe/kernel.txt"
findmnt -t btrfs -no TARGET,OPTIONS >> "$observe/kernel.txt"
root=$games/dota-shader-identity-20261006
variant=${G16_TRIGGER_VARIANT:-mode0}
case "$variant" in mode0|fb1) ;; *) exit 64 ;; esac
label=dota-trigger-codex-$(date +%Y%m%d_%H%M%S)
mkdir -p "$observe/harness-original"
for file in steam-host.sh game.sh collector.sh run-variant.sh dota-guest.sh dota-inner.sh watch-dota.py capture-ring.py collect-shader-ring-guest.py shader-ring.py; do
    cp "$root/$file" "$observe/harness-original/$file"
done
sha256sum "$observe/harness-original/"* > "$observe/harness-inputs.sha256"
mkdir -p "$root/codex-original"
for file in steam-host.sh game.sh collector.sh; do
    cp "$root/$file" "$root/codex-original/$file"
    cat > "$root/$file" <<HOST
#!/bin/bash
set -euo pipefail
exec /bin/bash "$root/codex-original/$file" "\$@" < <(sleep 900)
HOST
    chown nsheth:nsheth "$root/$file"
done
cp "$observe/g16-dota-trigger-watch.py" "$root/watch-dota.py"
chown nsheth:nsheth "$root/watch-dota.py"
expected_driver=$root/driver/libvulkan_asahi.so
if [ "$variant" = fb1 ]; then expected_driver=$root/driver-fb-a64/libvulkan_asahi.so; fi
file "$expected_driver" > "$observe/driver-elf.txt"
sha256sum "$expected_driver" > "$observe/driver.sha256"
strings "$expected_driver" | grep -E '^Mesa .*git-|^AGX_SHADER_RING path=' > "$observe/driver-version.txt" || true
cleanup() {
    rc=$?; trap - EXIT
    m4-steam-shutdown 45 > "$observe/steam-shutdown.log" 2>&1 || true
    systemctl stop dota-game dota-collector dota-watch g16-steam 2>/dev/null || true
    journalctl -b -u g16-steam -u dota-game -u dota-collector -u dota-watch --no-pager -o short-precise > "$observe/units.log"
    cp "$games/steam.log" "$observe/steam-startup.log" 2>/dev/null || true
    [ ! -d "$root/results/$label" ] || cp -a "$root/results/$label" "$observe/trigger-results"
    dmesg > "$observe/dmesg.txt"
    exit "$rc"
}
trap cleanup EXIT
WATCH_LIMIT=300 WATCH_MIN_KB=2097152 EXPECT_DRIVER="$expected_driver" bash "$root/run-variant.sh" "$label" "$variant" > "$observe/trigger-harness.log" 2>&1
systemctl is-active m4-kwin claude-headless input-forward-server > "$observe/services-after.txt" || true
