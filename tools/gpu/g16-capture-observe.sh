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
results=$games/dota-shader-identity-20261006/results
chmod 1777 "$observe"
sed 's/^loginctl enable-linger "$desktop_user"$/loginctl enable-linger "$desktop_user" || true/' /usr/local/bin/m4-post-boot > "$observe/post-boot.sh"
bash "$observe/post-boot.sh" > "$observe/post-boot.log" 2>&1
systemctl is-active m4-kwin claude-headless input-forward-server > "$observe/services-before.txt"
uname -a > "$observe/kernel.txt"
cat /proc/cmdline >> "$observe/kernel.txt"
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
# Joining the running Steam VM is part of the reproduction path.
if [ "$capture_stage" = capture ]; then
cat > "$stage/probe-host.sh" <<'HOST'
#!/bin/bash
set -euo pipefail
source /home/nsheth/.local/state/m4/session.env
export M4_MUVM_MEM=6144 M4_MUVM_VRAM=2048 M4_MUVM_FEX_OVERLAY=/var/tmp/g16-steam-mesa.erofs
exec /usr/local/bin/m4-muvm /bin/bash "$1/g16-capture-probe-guest.sh" "$1"
HOST
chown nsheth:nsheth "$stage/probe-host.sh"
systemd-run --unit=codex-dota-probe --uid=nsheth --setenv=HOME=/home/nsheth -p RuntimeMaxSec=120 /bin/bash "$stage/probe-host.sh" "$stage"
for second in {1..125}; do
    systemctl is-active --quiet codex-dota-probe || break
    sleep 1
done
journalctl -u codex-dota-probe --no-pager -o cat > "$observe/probe-service.log"
cat "$stage/probe-verdicts.txt" || true
grep -q '^baseline rc=0$' "$stage/probe-verdicts.txt"
grep -q 'device=Apple M4.*driver=Honeykrisp' "$stage/fex-baseline.log"
grep -q 'libvulkan_asahi' "$stage/fex-baseline-maps.txt"
exit 0
fi
# Dota has a 150 s deadline and 2 GiB capture limit. A failure is a diagnostic
# result, never counted as a clean run. Keep Steam's existing launch path.
label=dota-gfxr-codex-$(date +%H%M%S)
out=$results/$label
mkdir -p "$out"; chown nsheth:nsheth "$out"
cat > "$stage/capture-host.sh" <<'HOST'
#!/bin/bash
set -euo pipefail
source /home/nsheth/.local/state/m4/session.env
export M4_MUVM_MEM=6144 M4_MUVM_VRAM=2048 M4_MUVM_FEX_OVERLAY=/var/tmp/g16-steam-mesa.erofs
exec /usr/local/bin/m4-muvm /bin/bash "$1/g16-dota-capture-guest.sh" "$2" unassisted
HOST
chown nsheth:nsheth "$stage/capture-host.sh"
systemd-run --unit=codex-dota-capture --uid=nsheth --setenv=HOME=/home/nsheth -p RuntimeMaxSec=150 /bin/bash "$stage/capture-host.sh" "$stage" "$label"
reason=deadline
for second in {1..155}; do
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
if [ -s "$out/loaded-driver.txt" ] && grep -q 'libvulkan_asahi' "$out/loaded-driver.txt"; then
    printf 'driver-map=present; verify version and Vulkan init in application.log\n' >> "$observe/dota-results/host-verdict.txt"
else
    printf 'driver-map=missing; INVALID startup/capture attempt\n' >> "$observe/dota-results/host-verdict.txt"
fi
journalctl -u codex-dota-capture --no-pager -o cat > "$observe/capture-service.log"
systemctl is-active m4-kwin claude-headless input-forward-server > "$observe/services-after.txt" || true
