#!/bin/bash
# claude-dota RO test session: boot G16_KERNEL_ARTIFACT with a read-only root
# plus G16_BOOT_EXTRA, run payload.sh G16_TESTS, collect, restore production.
set -euo pipefail
workspace=/home/nsheth/Projects/asahi
here=$workspace/artifacts/dota-compute-stall-20261007/ro-session
: "${G16_KERNEL_ARTIFACT:?}" "${G16_EXPECT_UTS:?}" "${G16_TESTS:?}"
tag=${G16_TAG:-x}
lease=$workspace/tools/lease/lease.sh
stamp=$(date +%Y%m%d_%H%M%S)
local_output=$here/$tag-$stamp
remote_output=/tmp/codex-dota-$tag-$stamp
mkdir -p "$local_output"
mini=root@192.168.50.2
ssh_options=(-o BatchMode=yes -o ConnectTimeout=5)
wait_ssh() { for retry in {1..60}; do ssh "${ssh_options[@]}" "$mini" true 2>/dev/null && return 0; sleep 2; done; return 1; }
"$lease" wait mini codex-dota 30 "RO session $tag"
boot_attempted=0
cleanup() {
    rc=$?; trap - EXIT
    [ "$("$lease" holder mini)" = codex-dota ] || { echo 'lease lost'; exit 1; }
    if [ "$boot_attempted" = 1 ]; then
        timeout 120 scp "${ssh_options[@]}" -q -r "$mini:$remote_output" "$local_output/" 2>/dev/null || true
        restored=0
        for attempt in 1 2 3; do
            "$lease" renew mini codex-dota 20
            if timeout 240 env -u IMAGE -u DTB -u KERNEL_BUILD EXTRA_ARGS=asahi_m4.dependency_kind=0 "$workspace/gravity-bootloader/m4-linux/boot.sh" > "$local_output/production-boot-$attempt.log" 2>&1 && wait_ssh && ssh "${ssh_options[@]}" "$mini" 'm4-post-boot; uname -a; systemctl is-active m4-kwin claude-headless input-forward-server' > "$local_output/production-services-$attempt.log" 2>&1; then
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
# Steam lives in muvm on the RW production boot; stop it cleanly before reset.
ssh "${ssh_options[@]}" "$mini" 'm4-steam-shutdown 45' > "$local_output/steam-shutdown.log" 2>&1 || true
sha256sum "$G16_KERNEL_ARTIFACT/Image.gz" "$G16_KERNEL_ARTIFACT/t8132-j773g.dtb" > "$local_output/boot-inputs.sha256"
boot_attempted=1
ro_args="ro systemd.mask=systemd-remount-fs.service systemd.mask=home.mount systemd.mask=boot.mount systemd.mask=boot-efi.mount systemd.mask=var-swap-swapfile.swap systemd.mask=systemd-growfs-root.service"
timeout 240 env -u KERNEL_BUILD IMAGE="$G16_KERNEL_ARTIFACT/Image.gz" DTB="$G16_KERNEL_ARTIFACT/t8132-j773g.dtb" EXTRA_ARGS="asahi_m4.dependency_kind=0 asahi_m4.debug_ctx=1 ${G16_BOOT_EXTRA:-} $ro_args" "$workspace/gravity-bootloader/m4-linux/boot.sh" > "$local_output/test-boot.log" 2>&1
wait_ssh
loaded=$(ssh "${ssh_options[@]}" "$mini" 'uname -v')
printf 'expected=%s\nloaded=%s\n' "$G16_EXPECT_UTS" "$loaded" > "$local_output/loaded-kernel.txt"
[ "$loaded" = "$G16_EXPECT_UTS" ]
ssh "${ssh_options[@]}" "$mini" "mkdir -p '$remote_output'"
scp "${ssh_options[@]}" -q "$here/payload.sh" "$mini:$remote_output/payload.sh"
"$lease" renew mini codex-dota 30
timeout 900 ssh "${ssh_options[@]}" "$mini" "bash '$remote_output/payload.sh' '$remote_output' '$G16_TESTS'" > "$local_output/payload-console.log" 2>&1 || true
