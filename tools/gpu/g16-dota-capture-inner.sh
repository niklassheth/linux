#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Derived from our lab's Dota launch path, retaining muvm/FEX Vulkan thunks.
# Run inside the Steam runtime, not directly on the host. No reset here.
set -uo pipefail
label=${1:?capture label required}
mode=${2:-unassisted}
case "$label" in dota-gfxr-codex-*) ;; *) exit 64 ;; esac
case "$mode" in unassisted|page_guard) ;; *) exit 64 ;; esac
frames=${G16_CAPTURE_FRAMES:-300-304}
[[ "$frames" =~ ^([1-9][0-9]*)-([1-9][0-9]*)$ ]] || exit 64
frame_start=${BASH_REMATCH[1]}
frame_end=${BASH_REMATCH[2]}
[ "$frame_end" -ge "$frame_start" ] && [ $((frame_end - frame_start)) -lt 10 ] || exit 64
root=$HOME/g16-games/dota-shader-identity-20261006
out=$root/results/$label
mkdir -p "$out"
unset LD_PRELOAD ASAHI_MESA_DEBUG AGX_MESA_DEBUG VK_INSTANCE_LAYERS VK_LAYER_PATH
unset HK_GPU_BUSY_FILE HK_TIMELINE_FILE HK_CMD_DIAG HK_WAIT_WATCHDOG_FILE
unset HK_CPU_DIAG HK_CPU_PHASES HK_WAIT_COUNTERS HK_USC_TRACE HK_WINDOW_COUNTER_FILE
unset HK_APPLE9_DUMP_HASH HK_APPLE9_DUMP_DIR MESA_SPIRV_DUMP_PATH
unset HK_APPLE9_FRAGMENT_BARRIER HK_APPLE9_ATTACHMENTS
unset AGX_SPILL_COALESCE AGX_SPILL_NO_LOOP_HANDLING
export HK_PERFTEST=batch HK_EXPERIMENTAL_APPLE9=1 MESA_SHADER_CACHE_DISABLE=true
export HK_APPLE9_DUMP_MODE=0
export VK_DRIVER_FILES=/usr/share/vulkan/icd.d/asahi_icd.aarch64.json
export VK_LOADER_LAYERS_DISABLE='~implicit~'
export VK_INSTANCE_LAYERS=VK_LAYER_LUNARG_gfxreconstruct
export GFXRECON_CAPTURE_FILE="$out/dota.gfxr" GFXRECON_CAPTURE_FILE_TIMESTAMP=false
export GFXRECON_CAPTURE_FRAMES=$frames
export GFXRECON_MEMORY_TRACKING_MODE=$mode GFXRECON_LOG_FILE="$out/gfxrecon.log"
export GFXRECON_LOG_LEVEL=debug
export SteamAppId=570 SteamGameId=570 SDL_VIDEO_DRIVER=x11 SDL_VIDEODRIVER=x11
export ENABLE_PATHMATCH=1 MANGOHUD=0
export FEX_APP_CONFIG="$HOME/g16-games/fex-vulkan.json" FEX_SILENTLOG=1 FEX_OUTPUTLOG=stderr
cd '/mnt/g16-external/SteamLibrary/steamapps/common/dota 2 beta/game'
export LD_LIBRARY_PATH="$HOME/g16-games/thunk-guest-lib:$PWD/bin/linuxsteamrt64"
printf 'memory_mode=%s frames=%s thunk_config=%s icd=%s\n' "$mode" "$GFXRECON_CAPTURE_FRAMES" "$FEX_APP_CONFIG" "$VK_DRIVER_FILES" > "$out/capture-inputs.txt"
ulimit -Ss 2048
./bin/linuxsteamrt64/dota2 -steam -vulkan -novid -netcon -netconport 2122 \
    -console -condebug -windowed -w 1280 -h 720 +fps_max 30 +fps_max_ui 30 \
    +sv_lan 1 +sv_cheats 1 +map dota > "$out/application.log" 2>&1 &
pid=$!
printf '%s\n' "$pid" > "$out/guest-game.pid"
# Probe while the process is alive, retaining early maps even on a fast crash.
# Finding the expected driver remains the host harness's explicit validity gate.
(
    while [ -r "/proc/$pid/maps" ]; do
        grep -o '/[^ ]*libvulkan_asahi[^ ]*' "/proc/$pid/maps" 2>/dev/null | sort -u > "$out/loaded-driver.txt.part"
        if [ -s "$out/loaded-driver.txt.part" ]; then
            mv "$out/loaded-driver.txt.part" "$out/loaded-driver.txt"
            grep -E 'lib(vulkan|VkLayer)|FEX' "/proc/$pid/maps" > "$out/capture-maps.txt" || true
        fi
        sleep 0.2
    done
    rm -f "$out/loaded-driver.txt.part"
) &
maps_pid=$!
wait "$pid"
status=$?
kill "$maps_pid" 2>/dev/null || true
wait "$maps_pid" 2>/dev/null || true
printf '%s\n' "$status" > "$out/exit-status"
exit "$status"
