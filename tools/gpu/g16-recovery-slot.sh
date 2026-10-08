#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Host-side lease, read-only observation, production restore. No Mesa changes.
set -euo pipefail
workspace=/home/nsheth/Projects/asahi
if [ -n "${G16_KERNEL_ARTIFACT:-}" ]; then
    kernel_image=$G16_KERNEL_ARTIFACT/Image.gz
    kernel_dtb=$G16_KERNEL_ARTIFACT/t8132-j773g.dtb
    kernel_uts=$G16_KERNEL_ARTIFACT/utsversion.h
else
    : "${G16_KERNEL_BUILD:?set a private build tree or immutable G16_KERNEL_ARTIFACT}"
    kernel_image=$G16_KERNEL_BUILD/arch/arm64/boot/Image.gz
    kernel_dtb=$G16_KERNEL_BUILD/arch/arm64/boot/dts/apple/t8132-j773g.dtb
    kernel_uts=$G16_KERNEL_BUILD/include/generated/utsversion.h
fi
[ -s "$kernel_image" ] && [ -s "$kernel_dtb" ] && [ -s "$kernel_uts" ]
lease=$workspace/tools/lease/lease.sh
owner=codex-dota
mode=${G16_SLOT_MODE:-recovery}
control_1b=${G16_CONTROL_1B:-0}
case "$control_1b" in 0|1) ;; *) exit 64 ;; esac
case "$mode" in recovery|capture|dota) ;; *) exit 64 ;; esac
stamp=$(date +%Y%m%d_%H%M%S)
local_output=$workspace/artifacts/dota-compute-stall-20261007/observe-$stamp
remote_output=/tmp/codex-dota-$stamp
mkdir -p "$local_output"
sha256sum "$kernel_image" "$kernel_dtb" > "$local_output/boot-inputs.sha256"
ssh_options=(-o BatchMode=yes -o ConnectTimeout=5)
mini=root@192.168.50.2
wait_ssh() {
    for retry in {1..60}; do
        ssh "${ssh_options[@]}" "$mini" true 2>/dev/null && return 0
        sleep 2
    done
    return 1
}
"$lease" wait mini "$owner" 15 "$mode: production17 plus rebased213; RO root"
boot_attempted=0
cleanup() {
    rc=$?
    trap - EXIT
    if [ "$("$lease" holder mini)" != "$owner" ]; then
        echo 'lease lost; cannot reset hardware owned by another agent' >&2
        exit 1
    fi
    if [ "$boot_attempted" = 1 ]; then
        "$lease" renew mini "$owner" 15
        timeout 120 scp "${ssh_options[@]}" -q -r "$mini:$remote_output" "$local_output/" 2>/dev/null || true
        restored=0
        for restore_attempt in 1 2 3; do
            [ "$("$lease" holder mini)" = "$owner" ] || break
            "$lease" renew mini "$owner" 15
            if timeout 240 env -u IMAGE -u DTB -u KERNEL_BUILD EXTRA_ARGS=asahi_m4.dependency_kind=0 "$workspace/gravity-bootloader/m4-linux/boot.sh" > "$local_output/production-boot-$restore_attempt.log" 2>&1 && wait_ssh && ssh "${ssh_options[@]}" "$mini" 'm4-post-boot; systemctl is-active input-forward-server m4-kwin claude-headless' > "$local_output/production-services-$restore_attempt.log" 2>&1; then
                restored=1
                break
            fi
        done
        if [ "$restored" != 1 ]; then
            echo 'production restoration failed after retries; inspect logs' >&2
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
experiment_args="asahi_m4.dependency_kind=0 asahi_m4.debug_ctx=1 $readonly_args"
if [ "$mode" = recovery ]; then
    experiment_args="$experiment_args asahi_m4.timeout_policy=3 asahi_m4.compute_preempt=1"
    if [ "$control_1b" = 1 ]; then
        # Valid zeroed record storage is paired with the new global setup,
        # matching the captured firmware-output record rather than a null VA.
        experiment_args="$experiment_args asahi_m4.control_1b=1 asahi_m4.compute_save_slot=1"
    fi
fi
boot_attempted=1
timeout 240 env -u KERNEL_BUILD IMAGE="$kernel_image" DTB="$kernel_dtb" EXTRA_ARGS="$experiment_args" "$workspace/gravity-bootloader/m4-linux/boot.sh" > "$local_output/test-boot.log" 2>&1
wait_ssh
expected_uts=$(sed -n 's/^#define UTS_VERSION "\(.*\)"$/\1/p' "$kernel_uts")
loaded_uts=$(ssh "${ssh_options[@]}" "$mini" 'uname -v')
loaded_cmdline=$(ssh "${ssh_options[@]}" "$mini" 'cat /proc/cmdline')
printf 'expected: %s\nloaded: %s\ncmdline: %s\n' "$expected_uts" "$loaded_uts" "$loaded_cmdline" > "$local_output/loaded-kernel.txt"
[ -n "$expected_uts" ] && [ "$loaded_uts" = "$expected_uts" ] || { echo 'wrong kernel booted; see loaded-kernel.txt' >&2; exit 1; }
required_arguments=(asahi_m4.debug_ctx=1)
if [ "$mode" = recovery ]; then required_arguments+=(asahi_m4.timeout_policy=3 asahi_m4.compute_preempt=1); fi
if [ "$control_1b" = 1 ]; then required_arguments+=(asahi_m4.control_1b=1 asahi_m4.compute_save_slot=1); fi
for required_argument in "${required_arguments[@]}"; do
    case " $loaded_cmdline " in *" $required_argument "*) ;; *) echo "missing $required_argument" >&2; exit 1 ;; esac
done
# /tmp must be tmpfs before staging sources or running any GPU program.
ssh "${ssh_options[@]}" "$mini" "test \"\$(findmnt -no FSTYPE /tmp)\" = tmpfs && mkdir -p '$remote_output'"
lab=$workspace/tmp/cs2-memory-lab-20261005/lab
if [ "$mode" = recovery ]; then
    scp "${ssh_options[@]}" -q "$lab/gpu-contend/gpu_contend.c" "$lab/gpu-contend/spirv.h" "$lab/gpu-fault-test/gpu_fault_test.c" "$lab/gpu-fault-test/fault.spv.inc" "$(dirname "$0")/g16-recovery-observe.sh" "$mini:$remote_output/"
else
    scp "${ssh_options[@]}" -q "$(dirname "$0")"/g16-capture-probe-{a64,x64,guest.sh,inner.sh} "$(dirname "$0")"/g16-dota-capture-{guest.sh,inner.sh} "$(dirname "$0")/g16-capture-observe.sh" "$mini:$remote_output/"
fi
observe_script=g16-recovery-observe.sh
if [ "$mode" != recovery ]; then observe_script=g16-capture-observe.sh; fi
timeout 600 ssh "${ssh_options[@]}" "$mini" "G16_CAPTURE_STAGE='$mode' G16_OBSERVATION_DIR='$remote_output' bash '$remote_output/$observe_script'" > "$local_output/observation.log" 2>&1
