#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Run on the leased mini after a read-only boot. All writes go to tmpfs.
set -euo pipefail
unset ASAHI_MESA_DEBUG VK_DRIVER_FILES VK_ICD_FILENAMES LD_LIBRARY_PATH LD_PRELOAD
: "${G16_OBSERVATION_DIR:?set a directory under /tmp}"
case "$G16_OBSERVATION_DIR" in /tmp/codex-dota-*) ;; *) exit 64 ;; esac
observe=$G16_OBSERVATION_DIR
root_options=$(findmnt -no OPTIONS /)
case ",$root_options," in *,ro,*) ;; *) echo 'root is writable; refusing experiment' >&2; exit 1 ;; esac
[ "$(findmnt -no FSTYPE /tmp)" = tmpfs ] || { echo '/tmp is not tmpfs' >&2; exit 1; }
swapoff -a
if ! mountpoint -q /home; then
    root_source=$(findmnt -no SOURCE /)
    root_source=${root_source%%\[*}
    mount -o ro,subvol=home "$root_source" /home
fi
home_options=$(findmnt -no OPTIONS /home)
case ",$home_options," in *,ro,*) ;; *) echo '/home is writable; refusing experiment' >&2; exit 1 ;; esac
for desktop_dir in .config .local .cache; do
    overlay_dir=/run/codex-dota-overlay/$desktop_dir
    mkdir -p "$overlay_dir/upper" "$overlay_dir/work"
    mount -t overlay overlay -o "lowerdir=/home/nsheth/$desktop_dir,upperdir=$overlay_dir/upper,workdir=$overlay_dir/work" "/home/nsheth/$desktop_dir"
done
mkdir -p "$observe"
chmod 1777 "$observe"
sed -e 's/^loginctl enable-linger "$desktop_user"$/loginctl enable-linger "$desktop_user" || true/' -e 's/^runuser -u /timeout 15 runuser -u /' /usr/local/bin/m4-post-boot > "$observe/post-boot.sh"
bash "$observe/post-boot.sh" > "$observe/post-boot.log" 2>&1
sleep 8
systemctl is-active m4-kwin claude-headless input-forward-server
uname -a > "$observe/kernel.txt"
cat /proc/cmdline >> "$observe/kernel.txt"
findmnt -no TARGET,FSTYPE,OPTIONS -T / >> "$observe/kernel.txt"
findmnt -no TARGET,FSTYPE,OPTIONS -T /home >> "$observe/kernel.txt"
for compositor in $(pgrep -x kwin_wayland); do
    awk '/lib(EGL|GL|vulkan_asahi)/ {print}' "/proc/$compositor/maps" >> "$observe/kwin-maps.txt"
done
HK_EXPERIMENTAL_APPLE9=1 vulkaninfo --summary > "$observe/vulkaninfo.txt" 2>&1
grep -q 'deviceName.*Apple M4' "$observe/vulkaninfo.txt"
grep -q 'driverName.*Honeykrisp' "$observe/vulkaninfo.txt"

companion_pid= fault_pid=
cleanup() {
    rc=$?
    trap - EXIT
    for child in "$companion_pid" "$fault_pid"; do
        [ -z "$child" ] || kill "$child" 2>/dev/null || true
    done
    dmesg > "$observe/dmesg.txt"
    exit "$rc"
}
trap cleanup EXIT
cd "$observe"
cc -O2 -std=c11 -D_POSIX_C_SOURCE=200809L -o gpu_contend gpu_contend.c -lvulkan -lxcb
cc -O2 -o gpu_fault_test gpu_fault_test.c -lvulkan
cube() {
    local name=$1 rc=0
    printf '%s %s\n' "$name" "$(date -Is)" >> "$observe/cube-start-times.txt"
    runuser -u nsheth -- env G16_CUBE_LOG="$observe/$name.log" bash -c '
        source /home/nsheth/.local/state/m4/session.env
        HK_EXPERIMENTAL_APPLE9=1 timeout 20 vkcube --c 120 > "$G16_CUBE_LOG" 2>&1
    ' || rc=$?
    echo "$name rc=$rc" | tee -a "$observe/verdicts.txt"
    return "$rc"
}
cube baseline
HK_EXPERIMENTAL_APPLE9=1 timeout 100 ./gpu_contend --seconds 80 --work 32 --cwork 32 --draws 2 > companion.log 2>&1 &
companion_pid=$!
sleep 10
kill -0 "$companion_pid"
# This is a diagnostic run of the existing reproducer, not a claim of recovery.
date -Is > hang-start.txt
HK_EXPERIMENTAL_APPLE9=1 timeout 75 ./gpu_fault_test hang > fault.log 2>&1 &
fault_pid=$!
sleep 15
cube during15 || true
sleep 20
cube after35 || true
systemctl is-active m4-kwin claude-headless input-forward-server > services-after.txt || true
kill "$companion_pid" "$fault_pid" 2>/dev/null || true
wait "$companion_pid" || echo "companion rc=$?" >> verdicts.txt
wait "$fault_pid" || echo "fault rc=$?" >> verdicts.txt
companion_pid= fault_pid=
cube after-client-exit || true
tail -n 8 companion.log
cat fault.log
