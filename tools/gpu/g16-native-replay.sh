#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# claude-dota native gfxrecon replay runner (2026-10-08), derived from
# native-replay-rw-20261008.sh. Adds G16_REPLAY_DRIVER (driver dir under the
# identity root, default 'driver') and G16_REPLAY_ENV (extra KEY=VAL words
# exported before the replay). Binary already on the mini; sha checked.
set -euo pipefail
workspace=/home/nsheth/Projects/asahi
: "${G16_KERNEL_ARTIFACT:?set frozen context214 test artifact}"
variant=${G16_TRIGGER_VARIANT:-mode0}
case "$variant" in mode0|fb1|inst|nocompress|export) ;; *) exit 64 ;; esac
sticky=${G16_CONTEXT_STICKY:?select A/B arm 0 or 1}
case "$sticky" in 0|1) ;; *) exit 64 ;; esac
preempt=${G16_RENDER_PREEMPT:?select A/B arm 0 or 1}
case "$preempt" in 0|1) ;; *) exit 64 ;; esac
boot_args="asahi_m4.dependency_kind=0 asahi_m4.debug_ctx=1 asahi_m4.context_sticky=$sticky asahi_m4.render_preempt=$preempt"
lease=$workspace/tools/lease/lease.sh
stamp=$(date +%Y%m%d_%H%M%S)
label=dota-replay-${G16_REPLAY_TAG:-x}-$stamp
local_output=$workspace/artifacts/dota-compute-stall-20261007/replay-${G16_REPLAY_TAG:-x}-$stamp
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
"$lease" wait mini codex-dota 15 "Dota native replay ${G16_REPLAY_TAG:-x}"
boot_attempted=0
inner_changed=0
cleanup() {
    rc=$?; trap - EXIT
    [ "$("$lease" holder mini)" = codex-dota ] || { echo 'lease lost; no hardware operations'; exit 1; }
    if [ "$boot_attempted" = 1 ]; then
        ssh "${ssh_options[@]}" "$mini" "systemctl stop codex-dota-replay codex-dota-replay-watch codex-dota-replay-collector 2>/dev/null || true" || true
        "$lease" renew mini codex-dota 15
        ssh "${ssh_options[@]}" "$mini" "m4-steam-shutdown 45; sleep 20; mkdir -p '$remote_output'; dmesg > '$remote_output/dmesg.txt'; journalctl -b -u g16-steam -u dota-game -u dota-watch -u dota-collector -u codex-dota-replay -u codex-dota-replay-watch -u codex-dota-replay-collector --no-pager > '$remote_output/units.log'" > "$local_output/final-shutdown.log" 2>&1 || true
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
expected=${G16_EXPECT_UTS:?set exact A/B kernel UTS}
loaded=$(ssh "${ssh_options[@]}" "$mini" 'uname -v')
printf 'expected=%s\nloaded=%s\n' "$expected" "$loaded" > "$local_output/loaded-kernel.txt"
[ "$loaded" = "$expected" ]
ssh "${ssh_options[@]}" "$mini" "mkdir -p '$remote_output'; m4-post-boot; uname -a; cat /proc/cmdline; findmnt -no TARGET,FSTYPE,OPTIONS -T /; systemctl is-active m4-kwin claude-headless input-forward-server" > "$local_output/setup.log" 2>&1
ssh "${ssh_options[@]}" "$mini" 'case ",$(findmnt -no OPTIONS /)," in *,rw,*) ;; *) exit 1 ;; esac; ! grep -Eq "asahi_m4\.(timeout_policy|compute_preempt|compute_save_slot|compute_private_pool|control_1b|render_barrier|retire_poll_ms)=" /proc/cmdline'
ssh "${ssh_options[@]}" "$mini" "grep -qw asahi_m4.context_sticky=$sticky /proc/cmdline"
ssh "${ssh_options[@]}" "$mini" "grep -qw asahi_m4.render_preempt=$preempt /proc/cmdline"

driver_dir=${G16_REPLAY_DRIVER:-driver}
replay_env=${G16_REPLAY_ENV:-}
: "${G16_REPLAY_TRACE:?set trace path on mini}"
remote_tool=/home/nsheth/g16-games/codex-dota-replay-20261008
ssh "${ssh_options[@]}" "$mini" "mkdir -p '$remote_tool' /home/nsheth/g16-games/dota-shader-identity-20261006/results/'$label'; chown -R nsheth:nsheth '$remote_tool' /home/nsheth/g16-games/dota-shader-identity-20261006/results/'$label'; test -s '$G16_REPLAY_TRACE'"
ssh "${ssh_options[@]}" "$mini" "chmod 755 '$remote_tool/gfxrecon-replay'; file '$remote_tool/gfxrecon-replay'; sha256sum '$remote_tool/gfxrecon-replay' '$G16_REPLAY_TRACE' /home/nsheth/g16-games/dota-shader-identity-20261006/$driver_dir/libvulkan_asahi.so; '$remote_tool/gfxrecon-replay' --version; m4-steam-shutdown 45" > "$local_output/replay-inputs.txt" 2>&1
cat > "$local_output/native-replay.sh" <<'NATIVE'
#!/bin/bash
set -uo pipefail
label=$1; trace=$2; driver_dir=$3; shift 3
root=$HOME/g16-games/dota-shader-identity-20261006
out=$root/results/$label
source "$HOME/.local/state/m4/session.env"
unset ASAHI_MESA_DEBUG AGX_MESA_DEBUG VK_INSTANCE_LAYERS VK_LAYER_PATH VK_ADD_LAYER_PATH LD_PRELOAD
export HK_EXPERIMENTAL_APPLE9=1 HK_PERFTEST=batch MESA_SHADER_CACHE_DISABLE=true
export VK_DRIVER_FILES=$root/$driver_dir/icd.json VK_LOADER_LAYERS_DISABLE='~implicit~'
export HK_SHADER_RING_DIR=/dev/shm
export HK_APPLE9_DUMP_MODE=0
mkdir -p "$out/dump"
for kv in "$@"; do export "${kv//@OUT@/$out}"; done
env | grep -E '^(HK_|AGX_|MESA_|ASAHI_|VK_)' | sort > "$out/replay-env.txt"
vulkaninfo --summary > "$out/renderer.txt" 2>&1
$HOME/g16-games/codex-dota-replay-20261008/gfxrecon-replay --wsi xcb "$trace" > "$out/application.log" 2>&1 &
pid=$!
printf '%s\n' "$pid" > "$out/guest-game.pid"
(
    while [ -r "/proc/$pid/maps" ]; do
        grep libvulkan_asahi "/proc/$pid/maps" > "$out/native-driver-maps.part" 2>/dev/null || true
        if [ -s "$out/native-driver-maps.part" ]; then
            mv "$out/native-driver-maps.part" "$out/native-driver-maps.txt"
            break
        fi
        sleep .1
    done
) &
wait "$pid"
status=$?
printf '%s\n' "$status" > "$out/exit-status"
exit "$status"
NATIVE
bash -n "$local_output/native-replay.sh"
scp "${ssh_options[@]}" -q "$local_output/native-replay.sh" "$mini:$remote_tool/native-replay.sh"
ssh "${ssh_options[@]}" "$mini" "chown nsheth:nsheth '$remote_tool/native-replay.sh'"
ssh "${ssh_options[@]}" "$mini" "systemd-run --unit=codex-dota-replay-collector --collect --uid=nsheth --setenv=HOME=/home/nsheth python3 /home/nsheth/g16-games/dota-shader-identity-20261006/collect-shader-ring-guest.py /home/nsheth/g16-games/dota-shader-identity-20261006/results/'$label'; sleep 1; systemd-run --unit=codex-dota-replay --collect --uid=nsheth --setenv=HOME=/home/nsheth bash '$remote_tool/native-replay.sh' '$label' '$G16_REPLAY_TRACE' '$driver_dir' $replay_env; systemd-run --unit=codex-dota-replay-watch --collect --setenv=WATCH_LIMIT=300 --setenv=WATCH_MIN_KB=2097152 python3 /home/nsheth/g16-games/dota-shader-identity-20261006/watch-dota.py '$label'; sleep 1; while systemctl is-active --quiet codex-dota-replay-watch; do sleep 1; done; cat /home/nsheth/g16-games/dota-shader-identity-20261006/results/'$label'/safe-to-stop.json; systemctl stop codex-dota-replay codex-dota-replay-collector" > "$local_output/replay-observer.log" 2>&1
