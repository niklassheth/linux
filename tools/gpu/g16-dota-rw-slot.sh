#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Manager-authorized rw trigger runs: original installed harness, default GPU
# behavior. Firmware-setup/recovery experiments must use the separate RO runner.
set -euo pipefail
workspace=/home/nsheth/Projects/asahi
: "${G16_KERNEL_ARTIFACT:?set frozen production20+213 diagnostic image}"
variant=${G16_TRIGGER_VARIANT:-mode0}
case "$variant" in mode0|fb1|inst|nocompress|export) ;; *) exit 64 ;; esac
sticky=${G16_CONTEXT_STICKY:-0}
case "$sticky" in 0) ;; 1) [ "${G16_STICKY_RW_APPROVED:-0}" = 1 ] || { echo 'sticky behavior experiment needs explicit rw authorization'; exit 64; } ;; *) exit 64 ;; esac
boot_args='asahi_m4.dependency_kind=0 asahi_m4.debug_ctx=1'
[ "$sticky" = 0 ] || boot_args="$boot_args asahi_m4.context_sticky=1"
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
inner_changed=0
cleanup() {
    rc=$?; trap - EXIT
    [ "$("$lease" holder mini)" = codex-dota ] || { echo 'lease lost; no hardware operations'; exit 1; }
    if [ "$boot_attempted" = 1 ]; then
        "$lease" renew mini codex-dota 15
        ssh "${ssh_options[@]}" "$mini" "m4-steam-shutdown 45; mkdir -p '$remote_output'; dmesg > '$remote_output/dmesg.txt'; journalctl -b -u g16-steam -u dota-game -u dota-watch -u dota-collector --no-pager > '$remote_output/units.log'" > "$local_output/final-shutdown.log" 2>&1 || true
        timeout 120 scp "${ssh_options[@]}" -q -r "$mini:$remote_output" "$local_output/" 2>/dev/null || true
        timeout 120 scp "${ssh_options[@]}" -q -r "$mini:/home/nsheth/g16-games/dota-shader-identity-20261006/results/$label" "$local_output/" 2>/dev/null || true
        if [ "$inner_changed" = 1 ]; then
            ssh "${ssh_options[@]}" "$mini" "cp -p '$remote_output/dota-inner.original.sh' /home/nsheth/g16-games/dota-shader-identity-20261006/dota-inner.sh" || rc=1
        fi
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
timeout 240 env -u KERNEL_BUILD IMAGE="$G16_KERNEL_ARTIFACT/Image.gz" DTB="$G16_KERNEL_ARTIFACT/t8132-j773g.dtb" EXTRA_ARGS="$boot_args" "$workspace/gravity-bootloader/m4-linux/boot.sh" > "$local_output/test-boot.log" 2>&1
wait_ssh
expected=$(sed -n 's/^#define UTS_VERSION "\(.*\)"$/\1/p' "$G16_KERNEL_ARTIFACT/utsversion.h")
loaded=$(ssh "${ssh_options[@]}" "$mini" 'uname -v')
printf 'expected=%s\nloaded=%s\n' "$expected" "$loaded" > "$local_output/loaded-kernel.txt"
[ "$loaded" = "$expected" ]
ssh "${ssh_options[@]}" "$mini" "mkdir -p '$remote_output'; m4-post-boot; uname -a; cat /proc/cmdline; findmnt -no TARGET,FSTYPE,OPTIONS -T /; systemctl is-active m4-kwin claude-headless input-forward-server" > "$local_output/setup.log" 2>&1
ssh "${ssh_options[@]}" "$mini" 'case ",$(findmnt -no OPTIONS /)," in *,rw,*) ;; *) exit 1 ;; esac; ! grep -Eq "asahi_m4\.(timeout_policy|compute_preempt|compute_save_slot|compute_private_pool|control_1b|render_barrier|render_preempt|retire_poll_ms)=" /proc/cmdline'
if [ "$sticky" = 1 ]; then
    ssh "${ssh_options[@]}" "$mini" 'grep -qw asahi_m4.context_sticky=1 /proc/cmdline'
fi
expected_driver=/home/nsheth/g16-games/dota-shader-identity-20261006/driver/libvulkan_asahi.so
if [ "$variant" = fb1 ]; then expected_driver=/home/nsheth/g16-games/dota-shader-identity-20261006/driver-fb-a64/libvulkan_asahi.so; fi
if [ "$variant" = inst ]; then expected_driver=/usr/lib64/libvulkan_asahi.so; fi
if [ "$variant" = export ]; then
    : "${G16_EXPORT_DRIVER:?set diagnostic aarch64 Vulkan library}"
    expected_driver=/home/nsheth/g16-games/dota-shader-identity-20261006/driver-export/libvulkan_asahi.so
    ssh "${ssh_options[@]}" "$mini" "mkdir -p /home/nsheth/g16-games/dota-shader-identity-20261006/driver-export; cp -p /home/nsheth/g16-games/dota-shader-identity-20261006/dota-inner.sh '$remote_output/dota-inner.original.sh'"
    scp "${ssh_options[@]}" -q "$mini:$remote_output/dota-inner.original.sh" "$local_output/dota-inner.original.sh"
    python3 - "$local_output" <<'PY'
import json, sys
from pathlib import Path
out = Path(sys.argv[1])
original = (out / 'dota-inner.original.sh').read_text()
needle = 'case "$variant" in '
assert original.count(needle) == 1
arm = 'export) export VK_DRIVER_FILES="$root/driver-export/icd.json" HK_APPLE9_DUMP_MODE=0 HK_APPLE9_EXPORT_GRAPHICS=0x7f829920,0x0a00d1f7 HK_APPLE9_EXPORT_DRAW_HASH=0x0a00d1f7 AGX_APPLE9_ASM_DIR="$out/dump" MESA_SPIRV_DUMP_PATH="$out/spirv";; '
(out / 'dota-inner.export.sh').write_text(original.replace(needle, needle + arm))
(out / 'export-icd.json').write_text(json.dumps({'file_format_version':'1.0.0', 'ICD':{'library_path':'./libvulkan_asahi.so','api_version':'1.4.0'}}) + '\n')
PY
    bash -n "$local_output/dota-inner.export.sh"
    scp "${ssh_options[@]}" -q "$G16_EXPORT_DRIVER" "$mini:$expected_driver"
    scp "${ssh_options[@]}" -q "$local_output/export-icd.json" "$mini:/home/nsheth/g16-games/dota-shader-identity-20261006/driver-export/icd.json"
    inner_changed=1
    scp "${ssh_options[@]}" -q "$local_output/dota-inner.export.sh" "$mini:/home/nsheth/g16-games/dota-shader-identity-20261006/dota-inner.sh"
fi
ssh "${ssh_options[@]}" "$mini" "sha256sum '$expected_driver'; file '$expected_driver'; sha256sum /home/nsheth/g16-games/dota-shader-identity-20261006/{run-variant.sh,watch-dota.py,collector.sh,game.sh,steam-host.sh,dota-inner.sh}" > "$local_output/harness-driver-inputs.txt"
timeout 600 ssh "${ssh_options[@]}" "$mini" "EXPECT_DRIVER='$expected_driver' WATCH_LIMIT='${G16_WATCH_LIMIT:-300}' WATCH_MIN_KB=2097152 bash /home/nsheth/g16-games/dota-shader-identity-20261006/run-variant.sh '$label' '$variant'" > "$local_output/harness.log" 2>&1
