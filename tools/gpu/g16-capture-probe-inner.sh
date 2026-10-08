#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Run inside Sniper's x86 shell; use the exact Dota Vulkan-thunk path.
set -uo pipefail
ulimit -c 0
stage=${1:?staging directory required}
mode=${2:?baseline/unassisted/page_guard required}
case "$stage" in /home/nsheth/.cache/codex-dota-capture-*) ;; *) exit 64 ;; esac
case "$mode" in baseline|unassisted|page_guard) ;; *) exit 64 ;; esac
unset LD_PRELOAD ASAHI_MESA_DEBUG AGX_MESA_DEBUG VK_LAYER_PATH VK_ADD_LAYER_PATH VK_INSTANCE_LAYERS
unset GFXRECON_CAPTURE_FRAMES GFXRECON_CAPTURE_TRIGGER GFXRECON_CAPTURE_TRIGGER_FRAMES
export FEX_APP_CONFIG="$HOME/g16-games/fex-vulkan.json" FEX_SILENTLOG=1 FEX_OUTPUTLOG=stderr
export VK_DRIVER_FILES=/usr/share/vulkan/icd.d/asahi_icd.aarch64.json
export VK_LOADER_LAYERS_DISABLE='~implicit~' HK_EXPERIMENTAL_APPLE9=1
export LD_LIBRARY_PATH="$HOME/g16-games/thunk-guest-lib:/mnt/g16-external/SteamLibrary/steamapps/common/dota 2 beta/game/bin/linuxsteamrt64"
export G16_PROBE_MAPS="$stage/fex-$mode-maps.txt"
if [ "$mode" != baseline ]; then
    export VK_INSTANCE_LAYERS=VK_LAYER_LUNARG_gfxreconstruct VK_ADD_LAYER_PATH=/home/nsheth/g16-games/gfxrecon-a64
    export GFXRECON_MEMORY_TRACKING_MODE="$mode"
    export GFXRECON_CAPTURE_FILE="$stage/fex-$mode.gfxr" GFXRECON_CAPTURE_FILE_TIMESTAMP=false
    export GFXRECON_LOG_FILE="$stage/fex-$mode-gfxrecon.log" GFXRECON_LOG_LEVEL=debug
fi
printf 'probe_path=muvm/SteamVM/FEX/Sniper/thunks mode=%s icd=%s config=%s\n' "$mode" "$VK_DRIVER_FILES" "$FEX_APP_CONFIG"
"$stage/g16-capture-probe-x64" "$mode"
rc=$?
printf 'probe rc=%s\n' "$rc"
exit "$rc"
