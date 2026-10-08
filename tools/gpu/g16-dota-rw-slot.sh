#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Manager-authorized rw trigger runs: original installed harness, default GPU
# behavior. Firmware-setup/recovery experiments must use the separate RO runner.
set -euo pipefail
workspace=/home/nsheth/Projects/asahi
: "${G16_KERNEL_ARTIFACT:?set frozen production20+213 diagnostic image}"
variant=${G16_TRIGGER_VARIANT:-mode0}
case "$variant" in mode0|fb1) ;; *) exit 64 ;; esac
lease=$workspace/tools/lease/lease.sh
stamp=$(date +%Y%m%d_%H%M%S)
label=dota-trigger-rw-$stamp
local_output=$workspace/artifacts/dota-compute-stall-20261007/rw-$stamp
remote_output=/tmp/codex-dota-rw-$stamp
mkdir -p "$local_output"
mini=root@192.168.50.2
ssh_options=(-o BatchMode=yes -o ConnectTimeout=5)
wait_ssh() {
    for retry in {1..60}; do
        ssh "${ssh_options[@]}" "$mini" true 2>/dev/null && return 0
        sleep 2
    done
    return 1
}
"$lease" wait mini codex-dota 15 "Dota trigger rw: production20+213, default behavior, original harness"
boot_attempted=0
cleanup() {
    rc=$?; trap - EXIT
    [ "$("$lease" holder mini)" = codex-dota ] || { echo 'lease lost; no hardware operations'; exit 1; }
    if [ "$boot_attempted" = 1 ]; then
        "$lease" renew mini codex-dota 15
        ssh "${ssh_options[@]}" "$mini" "m4-steam-shutdown 45; mkdir -p '$remote_output'; dmesg > '$remote_output/dmesg.txt'; journalctl -b -u g16-steam -u dota-game -u dota-watch -u dota-collector --no-pager > '$remote_output/units.log'" > "$local_output/final-shutdown.log" 2>&1 || true
        timeout 120 scp "${ssh_options[@]}" -q -r "$mini:$remote_output" "$local_output/" 2>/dev/null || true
        timeout 120 scp "${ssh_options[@]}" -q -r "$mini:/home/nsheth/g16-games/dota-shader-identity-20261006/results/$label" "$local_output/" 2>/dev/null || true
        restored=0
        for attempt in 1 2 3; do
            "$lease" renew mini codex-dota 15
            if timeout 240 env -u IMAGE -u DTB -u KERNEL_BUILD EXTRA_ARGS=asahi_m4.dependency_kind=0 "$workspace/gravity-bootloader/m4-linux/boot.sh" > "$local_output/production-boot-$attempt.log" 2>&1 && wait_ssh && ssh "${ssh_options[@]}" "$mini" 'm4-post-boot; uname -a; systemctl is-active m4-kwin claude-headless input-forward-server' > "$local_output/production-services-$attempt.log" 2>&1; then
                restored=1; break
            fi
        done
        [ "$restored" = 1 ] || rc=1
    fi
    "$lease" release mini codex-dota
    echo "observation logs: $local_output"
    exit "$rc"
}
trap cleanup EXIT
sha256sum "$G16_KERNEL_ARTIFACT/Image.gz" "$G16_KERNEL_ARTIFACT/t8132-j773g.dtb" > "$local_output/boot-inputs.sha256"
boot_attempted=1
timeout 240 env -u KERNEL_BUILD IMAGE="$G16_KERNEL_ARTIFACT/Image.gz" DTB="$G16_KERNEL_ARTIFACT/t8132-j773g.dtb" EXTRA_ARGS='asahi_m4.dependency_kind=0 asahi_m4.debug_ctx=1' "$workspace/gravity-bootloader/m4-linux/boot.sh" > "$local_output/test-boot.log" 2>&1
wait_ssh
expected=$(sed -n 's/^#define UTS_VERSION "\(.*\)"$/\1/p' "$G16_KERNEL_ARTIFACT/utsversion.h")
loaded=$(ssh "${ssh_options[@]}" "$mini" 'uname -v')
printf 'expected=%s\nloaded=%s\n' "$expected" "$loaded" > "$local_output/loaded-kernel.txt"
[ "$loaded" = "$expected" ]
ssh "${ssh_options[@]}" "$mini" "mkdir -p '$remote_output'; m4-post-boot; uname -a; cat /proc/cmdline; findmnt -no TARGET,FSTYPE,OPTIONS -T /; systemctl is-active m4-kwin claude-headless input-forward-server" > "$local_output/setup.log" 2>&1
ssh "${ssh_options[@]}" "$mini" 'case ",$(findmnt -no OPTIONS /)," in *,rw,*) ;; *) exit 1 ;; esac; ! grep -Eq "asahi_m4\.(timeout_policy|compute_preempt|compute_save_slot|compute_private_pool|control_1b|render_barrier|render_preempt|retire_poll_ms)=" /proc/cmdline'
expected_driver=/home/nsheth/g16-games/dota-shader-identity-20261006/driver/libvulkan_asahi.so
if [ "$variant" = fb1 ]; then expected_driver=/home/nsheth/g16-games/dota-shader-identity-20261006/driver-fb-a64/libvulkan_asahi.so; fi
ssh "${ssh_options[@]}" "$mini" "sha256sum '$expected_driver'; file '$expected_driver'; sha256sum /home/nsheth/g16-games/dota-shader-identity-20261006/{run-variant.sh,watch-dota.py,collector.sh,game.sh,steam-host.sh,dota-inner.sh}" > "$local_output/harness-driver-inputs.txt"
timeout 600 ssh "${ssh_options[@]}" "$mini" "EXPECT_DRIVER='$expected_driver' WATCH_LIMIT=300 WATCH_MIN_KB=2097152 bash /home/nsheth/g16-games/dota-shader-identity-20261006/run-variant.sh '$label' '$variant'" > "$local_output/harness.log" 2>&1
