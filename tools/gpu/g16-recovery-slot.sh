#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Host-side lease, read-only observation, production restore. No Mesa changes.
set -euo pipefail
workspace=/home/nsheth/Projects/asahi
: "${G16_KERNEL_BUILD:?set the absolute private kernel build tree}"
[ -s "$G16_KERNEL_BUILD/arch/arm64/boot/Image.gz" ]
[ -s "$G16_KERNEL_BUILD/arch/arm64/boot/dts/apple/t8132-j773g.dtb" ]
lease=$workspace/tools/lease/lease.sh
owner=codex-dota
stamp=$(date +%Y%m%d_%H%M%S)
local_output=$workspace/artifacts/dota-compute-stall-20261007/observe-$stamp
remote_output=/tmp/codex-dota-$stamp
mkdir -p "$local_output"
ssh_options=(-o BatchMode=yes -o ConnectTimeout=5)
mini=root@192.168.50.2
wait_ssh() {
    for retry in {1..60}; do
        ssh "${ssh_options[@]}" "$mini" true 2>/dev/null && return 0
        sleep 2
    done
    return 1
}
"$lease" wait mini "$owner" 25 'compute teardown with native priority; diagnostic kernel; RO root'
boot_attempted=0
cleanup() {
    rc=$?
    trap - EXIT
    if [ "$("$lease" holder mini)" != "$owner" ]; then
        echo 'lease lost; cannot reset hardware owned by another agent' >&2
        exit 1
    fi
    if [ "$boot_attempted" = 1 ]; then
        scp "${ssh_options[@]}" -q -r "$mini:$remote_output" "$local_output/" 2>/dev/null || true
        "$lease" renew mini "$owner" 15
        if ! env -u IMAGE -u DTB -u KERNEL_BUILD EXTRA_ARGS=asahi_m4.dependency_kind=0 "$workspace/gravity-bootloader/m4-linux/boot.sh" > "$local_output/production-boot.log" 2>&1; then
            echo 'production restore boot failed' >&2
            rc=1
        elif ! wait_ssh || ! ssh "${ssh_options[@]}" "$mini" 'm4-post-boot; systemctl is-active input-forward-server m4-kwin claude-headless' > "$local_output/production-services.log" 2>&1; then
            echo 'production post-boot verification failed' >&2
            rc=1
        fi
    fi
    "$lease" release mini "$owner"
    echo "observation logs: $local_output"
    exit "$rc"
}
trap cleanup EXIT
readonly_args='ro systemd.mask=systemd-remount-fs.service systemd.mask=home.mount systemd.mask=boot.mount systemd.mask=boot-efi.mount systemd.mask=var-swap-swapfile.swap systemd.mask=systemd-growfs-root.service'
# Prior policy-3 capture used compute_preempt=0. This arm asks whether native
# priority enables teardown even when it has not enabled compute time-slicing.
experiment_args="asahi_m4.dependency_kind=0 asahi_m4.timeout_policy=3 asahi_m4.compute_preempt=1 $readonly_args"
boot_attempted=1
env -u IMAGE -u DTB KERNEL_BUILD="$G16_KERNEL_BUILD" EXTRA_ARGS="$experiment_args" "$workspace/gravity-bootloader/m4-linux/boot.sh" > "$local_output/test-boot.log" 2>&1
wait_ssh
expected_uts=$(sed -n 's/^#define UTS_VERSION "\(.*\)"$/\1/p' "$G16_KERNEL_BUILD/include/generated/utsversion.h")
loaded_uts=$(ssh "${ssh_options[@]}" "$mini" 'uname -v')
[ -n "$expected_uts" ] && [ "$loaded_uts" = "$expected_uts" ] || { echo 'wrong kernel booted' >&2; exit 1; }
ssh "${ssh_options[@]}" "$mini" 'test "$(cat /sys/module/asahi_m4/parameters/timeout_policy)" = 3 && test "$(cat /sys/module/asahi_m4/parameters/compute_preempt)" = 1'
# /tmp must be tmpfs before staging sources or running any GPU program.
ssh "${ssh_options[@]}" "$mini" "test \"\$(findmnt -no FSTYPE /tmp)\" = tmpfs && mkdir -p '$remote_output'"
lab=$workspace/tmp/cs2-memory-lab-20261005/lab
scp "${ssh_options[@]}" -q "$lab/gpu-contend/gpu_contend.c" "$lab/gpu-contend/spirv.h" "$lab/gpu-fault-test/gpu_fault_test.c" "$lab/gpu-fault-test/fault.spv.inc" "$(dirname "$0")/g16-recovery-observe.sh" "$mini:$remote_output/"
ssh "${ssh_options[@]}" "$mini" "G16_OBSERVATION_DIR='$remote_output' bash '$remote_output/g16-recovery-observe.sh'" > "$local_output/observation.log" 2>&1
