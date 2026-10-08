#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Run in the same native muvm guest as Steam. No shaders/queue submissions.
set -uo pipefail
stage=${1:?staging directory required}
case "$stage" in /home/nsheth/.cache/codex-dota-capture-*) ;; *) exit 64 ;; esac
unset LD_PRELOAD ASAHI_MESA_DEBUG AGX_MESA_DEBUG
unset LD_LIBRARY_PATH LIBGL_DRIVERS_PATH GBM_BACKENDS_PATH __EGL_VENDOR_LIBRARY_FILENAMES
export STEAM_RUNTIME_LOGGER=0
{
    printf 'guest pid=%s\n' "$$"
    uname -m
    command -v bash FEXInterpreter
    ls -l /mnt/g16-external/SteamLibrary/steamapps/common/SteamLinuxRuntime_sniper/_v2-entry-point
    env | sort | grep -E '^(FEX_|VK_|GFXRECON_|HOME=|LD_LIBRARY_PATH=)'
} > "$stage/guest-environment.txt" 2>&1

for mode in baseline unassisted page_guard; do
    (
        unset VK_INSTANCE_LAYERS VK_LAYER_PATH VK_ADD_LAYER_PATH GFXRECON_CAPTURE_FRAMES
        export VK_DRIVER_FILES=/usr/share/vulkan/icd.d/asahi_icd.aarch64.json
        export VK_LOADER_LAYERS_DISABLE='~implicit~' HK_EXPERIMENTAL_APPLE9=1
        export G16_PROBE_MAPS="$stage/native-$mode-maps.txt"
        if [ "$mode" != baseline ]; then
            export VK_INSTANCE_LAYERS=VK_LAYER_LUNARG_gfxreconstruct VK_ADD_LAYER_PATH=/home/nsheth/g16-games/gfxrecon-a64
            export GFXRECON_MEMORY_TRACKING_MODE="$mode"
            export GFXRECON_CAPTURE_FILE="$stage/native-$mode.gfxr" GFXRECON_CAPTURE_FILE_TIMESTAMP=false
            export GFXRECON_LOG_FILE="$stage/native-$mode-gfxrecon.log" GFXRECON_LOG_LEVEL=debug
        fi
        env | sort | grep -E '^(FEX_|VK_|GFXRECON_|HOME=|LD_LIBRARY_PATH=)'
        "$stage/g16-capture-probe-a64" "$mode"
    ) > "$stage/native-$mode.log" 2>&1
    printf 'native-%s rc=%s\n' "$mode" "$?" >> "$stage/probe-verdicts.txt"
done
for mode in baseline unassisted page_guard; do
    FEXInterpreter /bin/bash /mnt/g16-external/SteamLibrary/steamapps/common/SteamLinuxRuntime_sniper/_v2-entry-point \
        --verb=run -- /bin/bash "$stage/g16-capture-probe-inner.sh" "$stage" "$mode" \
        > "$stage/fex-$mode.log" 2>&1
    rc=$?
    printf '%s rc=%s\n' "$mode" "$rc" >> "$stage/probe-verdicts.txt"
done
