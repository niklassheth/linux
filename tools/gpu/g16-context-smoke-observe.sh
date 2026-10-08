#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Read-only root smoke test, temporary home overlay, no game runtime.
set -euo pipefail
: "${G16_OBSERVATION_DIR:?}"
observe=$G16_OBSERVATION_DIR
case "$observe" in /tmp/codex-dota-*) ;; *) exit 64 ;; esac
case ",$(findmnt -no OPTIONS /)," in *,ro,*) ;; *) exit 1 ;; esac
[ "$(findmnt -no FSTYPE /tmp)" = tmpfs ]
swapoff -a
if ! mountpoint -q /home; then
    source=$(findmnt -no SOURCE /); source=${source%%\[*}
    mount -o ro,subvol=home "$source" /home
fi
case ",$(findmnt -no OPTIONS /home)," in *,ro,*) ;; *) exit 1 ;; esac
overlay=/tmp/codex-dota-smoke-home
mkdir -p "$overlay/lower" "$overlay/upper" "$overlay/work"
mount --bind /home/nsheth "$overlay/lower"
mount -o remount,bind,ro "$overlay/lower"
mount -t overlay overlay -o "lowerdir=$overlay/lower,upperdir=$overlay/upper,workdir=$overlay/work" /home/nsheth
chmod 1777 "$observe"
trap 'm4-steam-shutdown 45 || true; dmesg > "$observe/kernel.log"' EXIT
sed 's/^loginctl enable-linger "$desktop_user"$/loginctl enable-linger "$desktop_user" || true/' /usr/local/bin/m4-post-boot > "$observe/post-boot.sh"
bash "$observe/post-boot.sh" > "$observe/post-boot.log" 2>&1
uname -a > "$observe/kernel.txt"
cat /proc/cmdline >> "$observe/kernel.txt"
findmnt -no TARGET,FSTYPE,OPTIONS -T / >> "$observe/kernel.txt"
findmnt -no TARGET,FSTYPE,OPTIONS -T /home >> "$observe/kernel.txt"
systemctl is-active m4-kwin claude-headless input-forward-server > "$observe/services-before.txt"
unset ASAHI_MESA_DEBUG VK_DRIVER_FILES VK_ICD_FILENAMES LD_PRELOAD LD_LIBRARY_PATH
HK_EXPERIMENTAL_APPLE9=1 vulkaninfo --summary > "$observe/vulkaninfo-native.txt" 2>&1
grep -q 'deviceName.*Apple M4' "$observe/vulkaninfo-native.txt"
grep -q 'driverName.*Honeykrisp' "$observe/vulkaninfo-native.txt"
guest_stage=/home/nsheth/.cache/codex-context-smoke
mkdir -p "$guest_stage"
cat > "$guest_stage/run.sh" <<'GUEST'
#!/bin/bash
set -euo pipefail
out=/home/nsheth/.cache/codex-context-smoke
trap 'echo "$?" > "$out/exit-status"' EXIT
FEXInterpreter /usr/bin/vulkaninfo --summary > "$out/vulkaninfo-x86.log" 2>&1
FEXInterpreter /usr/bin/vkcube --c 120 > "$out/vkcube-x86.log" 2>&1
GUEST
chown -R nsheth:nsheth "$guest_stage"
runuser -u nsheth -- env G16_SMOKE_OUTPUT="$observe" bash -c '
    set -euo pipefail
    source /home/nsheth/.local/state/m4/session.env
    HK_EXPERIMENTAL_APPLE9=1 timeout 30 vkcube --c 120 > "$G16_SMOKE_OUTPUT/vkcube-native.log" 2>&1
    echo "native vkcube rc=0 frames=120" > "$G16_SMOKE_OUTPUT/verdicts.txt"
    timeout 90 m4-muvm /bin/bash /home/nsheth/.cache/codex-context-smoke/run.sh > "$G16_SMOKE_OUTPUT/muvm-host.log" 2>&1
' < <(sleep 180)
for retry in {1..60}; do
    [ ! -s "$guest_stage/exit-status" ] || break
    sleep 1
done
cp -a "$guest_stage" "$observe/guest-results"
[ "$(cat "$guest_stage/exit-status")" = 0 ]
grep -q 'deviceName.*Apple M4' "$guest_stage/vulkaninfo-x86.log"
grep -q 'driverName.*Honeykrisp' "$guest_stage/vulkaninfo-x86.log"
grep -q 'Selected GPU.*Apple M4' "$guest_stage/vkcube-x86.log"
echo 'x86 guest vkcube rc=0 frames=120' >> "$observe/verdicts.txt"
systemctl is-active m4-kwin claude-headless input-forward-server > "$observe/services-after.txt"
