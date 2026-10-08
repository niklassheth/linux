#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Leased mini, fresh RO boot. Stage is tmpfs; all capture sizes are bounded.
set -euo pipefail
: "${G16_OBSERVATION_DIR:?set directory under /tmp}"
case "$G16_OBSERVATION_DIR" in /tmp/codex-dota-*) ;; *) exit 64 ;; esac
observe=$G16_OBSERVATION_DIR
capture_stage=${G16_CAPTURE_STAGE:-capture}
case "$capture_stage" in capture|dota) ;; *) exit 64 ;; esac
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
stage=/home/nsheth/.cache/codex-dota-capture-$(date +%Y%m%d_%H%M%S)
mkdir -p "$stage"
cp "$observe"/g16-capture-probe-{x64,a64,inner.sh,guest.sh} "$stage/"
cp "$observe"/g16-dota-capture-{inner.sh,guest.sh} "$stage/"
chown -R nsheth:nsheth "$stage"
cleanup() {
    rc=$?; trap - EXIT
    journalctl -b -u g16-steam --no-pager -o short-precise > "$observe/steam-service.log"
    cp "$games/steam.log" "$observe/steam-startup.log" 2>/dev/null || true
    cp "$games/steam-shutdown.log" "$observe/steam-guest-shutdown.log" 2>/dev/null || true
    m4-steam-shutdown 45 > "$observe/steam-shutdown.log" 2>&1 || true
    systemctl stop codex-dota-probe codex-dota-capture g16-steam 2>/dev/null || true
    cp -a "$stage" "$observe/probe-results"
    dmesg > "$observe/dmesg.txt"
    exit "$rc"
}
trap cleanup EXIT
m4-steam-shutdown 45
systemctl stop g16-steam 2>/dev/null || true
systemd-run --unit=g16-steam --collect --uid=nsheth --setenv=HOME=/home/nsheth /bin/bash /home/nsheth/g16-games/dota-shader-identity-20261006/steam-host.sh
sleep 75
systemctl show g16-steam -p ActiveState -p SubState -p MainPID > "$observe/steam-vm-before-launch.txt"
if ! systemctl is-active --quiet g16-steam; then
    printf 'INVALID: original Steam VM exited before launch\n' > "$observe/launch-path-verdict.txt"
    exit 2
fi
# Joining the running Steam VM is part of the reproduction path.
if [ "$capture_stage" = capture ]; then
cat > "$stage/probe-host.sh" <<'HOST'
#!/bin/bash
set -euo pipefail
source /home/nsheth/.local/state/m4/session.env
export M4_MUVM_MEM=6144 M4_MUVM_VRAM=2048 M4_MUVM_FEX_OVERLAY=/var/tmp/g16-steam-mesa.erofs
exec /usr/local/bin/m4-muvm /bin/bash "$1/g16-capture-probe-guest.sh" "$1" > "$1/probe-launch.log" 2>&1 < <(sleep 115)
HOST
chown nsheth:nsheth "$stage/probe-host.sh"
systemd-run --unit=codex-dota-probe --uid=nsheth --setenv=HOME=/home/nsheth -p RuntimeMaxSec=120 /bin/bash "$stage/probe-host.sh" "$stage"
for second in {1..125}; do
    grep -q '^page_guard rc=' "$stage/probe-verdicts.txt" 2>/dev/null && break
    sleep 1
done
journalctl -u codex-dota-probe --no-pager -o cat > "$observe/probe-service.log"
cat "$stage/probe-verdicts.txt" || true
grep -q '^baseline rc=0$' "$stage/probe-verdicts.txt"
grep -q 'device=Apple M4.*driver=Honeykrisp' "$stage/fex-baseline.log"
grep -q 'libvulkan_asahi' "$stage/fex-baseline-maps.txt"
exit 0
fi
# Dota has a 300 s deadline and 2 GiB capture limit. A failure is a diagnostic
# result, never counted as a clean run. Keep Steam's existing launch path.
label=dota-gfxr-codex-$(date +%H%M%S)
out=$results/$label
mkdir -p "$out"; chown nsheth:nsheth "$out"
cat > "$stage/capture-host.sh" <<'HOST'
#!/bin/bash
set -euo pipefail
source /home/nsheth/.local/state/m4/session.env
export M4_MUVM_MEM=6144 M4_MUVM_VRAM=2048 M4_MUVM_FEX_OVERLAY=/var/tmp/g16-steam-mesa.erofs
exec /usr/local/bin/m4-muvm /bin/bash "$1/g16-dota-capture-guest.sh" "$2" unassisted "$3" < <(sleep 295)
HOST
chown nsheth:nsheth "$stage/capture-host.sh"
systemd-run --unit=codex-dota-capture --uid=nsheth --setenv=HOME=/home/nsheth -p RuntimeMaxSec=300 /bin/bash "$stage/capture-host.sh" "$stage" "$label" 1800-1804
reason=deadline
for second in {1..305}; do
    if [ -f "$out/exit-status" ]; then reason=exited; break; fi
    bytes=$(du -sb "$out" | cut -f1)
    available=$(awk '/MemAvailable:/ {print $2}' /proc/meminfo)
    if [ "$bytes" -gt 2147483648 ] || [ "$available" -lt 2097152 ]; then reason=resource-limit; break; fi
    sleep 1
done
printf 'reason=%s\n' "$reason" > "$out/host-verdict.txt"
m4-steam-shutdown 45 || true
systemctl stop codex-dota-capture 2>/dev/null || true
cp -a "$out" "$observe/dota-results"
for console_path in dota/console.log core/console.log console.log; do
    console_source="/mnt/g16-external/SteamLibrary/steamapps/common/dota 2 beta/game/$console_path"
    [ ! -f "$console_source" ] || cp "$console_source" "$observe/dota-results/${console_path//\//-}"
done
if [ -s "$out/loaded-driver.txt" ] && grep -q 'libvulkan_asahi' "$out/loaded-driver.txt"; then
    printf 'driver-map=present; verify version and Vulkan init in application.log\n' >> "$observe/dota-results/host-verdict.txt"
else
    printf 'driver-map=missing; INVALID startup/capture attempt\n' >> "$observe/dota-results/host-verdict.txt"
fi
journalctl -u codex-dota-capture --no-pager -o cat > "$observe/capture-service.log"
systemctl is-active m4-kwin claude-headless input-forward-server > "$observe/services-after.txt" || true
