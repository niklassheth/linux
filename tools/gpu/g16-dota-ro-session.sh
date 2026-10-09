#!/bin/bash
# claude-dota RO test session: boot G16_KERNEL_ARTIFACT with a read-only root
# plus G16_BOOT_EXTRA, run payload.sh G16_TESTS, collect, restore production.
set -euo pipefail
workspace=/home/nsheth/Projects/asahi
here=$workspace/artifacts/dota-compute-stall-20261007/ro-session
: "${G16_KERNEL_ARTIFACT:?}" "${G16_EXPECT_UTS:?}" "${G16_TESTS:?}"
tag=${G16_TAG:-x}
lease=$workspace/tools/lease/lease.sh
# boot.sh (gravity-bootloader 492f011) refuses unless LEASE_OWNER holds the lease.
export LEASE_OWNER=codex-dota
stamp=$(date +%Y%m%d_%H%M%S)
local_output=$here/$tag-$stamp
remote_output=/tmp/codex-dota-$tag-$stamp
mkdir -p "$local_output"
mini=root@192.168.50.2
ssh_options=(-o BatchMode=yes -o ConnectTimeout=5)
wait_ssh() { for retry in {1..60}; do ssh "${ssh_options[@]}" "$mini" true 2>/dev/null && return 0; sleep 2; done; return 1; }
"$lease" wait mini codex-dota 30 "RO session $tag"
ro_args="ro systemd.mask=systemd-remount-fs.service systemd.mask=home.mount systemd.mask=boot.mount systemd.mask=boot-efi.mount systemd.mask=var-swap-swapfile.swap systemd.mask=systemd-growfs-root.service"
boot_attempted=0
cleanup() {
    rc=$?; trap - EXIT
    [ "$("$lease" holder mini)" = codex-dota ] || { echo 'lease lost'; exit 1; }
    if [ "$boot_attempted" = 1 ]; then
        timeout 120 scp "${ssh_options[@]}" -q -r "$mini:$remote_output" "$local_output/" 2>/dev/null || true
        restored=0
        for attempt in 1 2 3; do
            "$lease" renew mini codex-dota 20
            # Read-only root rule (btrfs damage, 2026-10-08): restore production
            # #20 with an RO root and the same tmpfs home overlay + post-boot.
            restore_dir=/tmp/codex-dota-restore-$stamp
            if timeout 240 env -u IMAGE -u DTB -u KERNEL_BUILD EXTRA_ARGS="asahi_m4.dependency_kind=0 $ro_args" "$workspace/gravity-bootloader/m4-linux/boot.sh" > "$local_output/production-boot-$attempt.log" 2>&1 && wait_ssh && ssh "${ssh_options[@]}" "$mini" "mkdir -p $restore_dir" && scp "${ssh_options[@]}" -q "$here/payload.sh" "$mini:$restore_dir/payload.sh" && ssh "${ssh_options[@]}" "$mini" "bash $restore_dir/payload.sh $restore_dir restore; uname -a; cat /proc/cmdline; findmnt -no OPTIONS /; systemctl is-active m4-kwin claude-headless input-forward-server" > "$local_output/production-services-$attempt.log" 2>&1; then
                restored=1; break
            fi
        done
        [ "$restored" = 1 ] || rc=1
    fi
    [ "${G16_KEEP_LEASE:-0}" = 1 ] || "$lease" release mini codex-dota
    echo "results: $local_output"
    exit "$rc"
}
trap cleanup EXIT
# Stop Steam (muvm) cleanly before any reset, whatever is booted.
ssh "${ssh_options[@]}" "$mini" 'm4-steam-shutdown 45' > "$local_output/steam-shutdown.log" 2>&1 || true
sha256sum "$G16_KERNEL_ARTIFACT/Image.gz" "$G16_KERNEL_ARTIFACT/t8132-j773g.dtb" > "$local_output/boot-inputs.sha256"
boot_attempted=1
timeout 240 env -u KERNEL_BUILD IMAGE="$G16_KERNEL_ARTIFACT/Image.gz" DTB="$G16_KERNEL_ARTIFACT/t8132-j773g.dtb" EXTRA_ARGS="${G16_BASE_ARGS-asahi_m4.dependency_kind=0 asahi_m4.debug_ctx=1} ${G16_BOOT_EXTRA:-} $ro_args" "$workspace/gravity-bootloader/m4-linux/boot.sh" > "$local_output/test-boot.log" 2>&1
wait_ssh
loaded=$(ssh "${ssh_options[@]}" "$mini" 'uname -v')
printf 'expected=%s\nloaded=%s\n' "$G16_EXPECT_UTS" "$loaded" > "$local_output/loaded-kernel.txt"
[ "$loaded" = "$G16_EXPECT_UTS" ]
ssh "${ssh_options[@]}" "$mini" "mkdir -p '$remote_output'"
scp "${ssh_options[@]}" -q "$here/payload.sh" "$mini:$remote_output/payload.sh"
scp "${ssh_options[@]}" -q "$here/../copy-burst/copy_burst.c" "$mini:$remote_output/copy_burst.c"
[ -d "$here/extra" ] && scp "${ssh_options[@]}" -q -r "$here/extra" "$mini:$remote_output/"
scp "${ssh_options[@]}" -q "$here/../render-burst/render_burst.c" "$here/../render-burst/render_present.c" "$here/../render-burst/spirv.h" "$mini:$remote_output/"
# Host-staged desktop Mesa tree: sync to the external disk (before the payload, so no copy I/O during the run).
if [ -n "${G16_DESKTOP_MESA_HOST:-}" ]; then
    mesa_remote=/mnt/g16-external/codex-dota-mesa/$(basename "$G16_DESKTOP_MESA_HOST")
    ssh "${ssh_options[@]}" "$mini" "{ mountpoint -q /mnt/g16-external && mount -o remount,rw /mnt/g16-external || mount -o rw /dev/sda1 /mnt/g16-external; } && mkdir -p $mesa_remote" > "$local_output/desktop-mesa-sync.log" 2>&1
    rsync -a --delete -e "ssh ${ssh_options[*]}" "$G16_DESKTOP_MESA_HOST/" "$mini:$mesa_remote/" >> "$local_output/desktop-mesa-sync.log" 2>&1
    ssh "${ssh_options[@]}" "$mini" "cd $mesa_remote && sha256sum -c --quiet SHA256SUMS" >> "$local_output/desktop-mesa-sync.log" 2>&1
    G16_DESKTOP_MESA=$mesa_remote
fi
"$lease" renew mini codex-dota 30
timeout 900 ssh "${ssh_options[@]}" "$mini" "G16_OVERLAY_BASE='${G16_OVERLAY_BASE:-}' G16_DOTA_MODE='${G16_DOTA_MODE:-}' G16_IO_THROTTLE='${G16_IO_THROTTLE:-}' G16_STEAM_OFFLINE='${G16_STEAM_OFFLINE:-}' G16_SYNTH_LOAD='${G16_SYNTH_LOAD:-}' G16_WORKLOG_DUMP='${G16_WORKLOG_DUMP:-}' G16_KEEPALIVE='${G16_KEEPALIVE:-}' G16_DESKTOP_MESA='${G16_DESKTOP_MESA:-}' bash '$remote_output/payload.sh' '$remote_output' '$G16_TESTS'" > "$local_output/payload-console.log" 2>&1 || true
