#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Run in the native muvm guest; the inner script runs in Steam's x86 runtime.
set -uo pipefail
label=${1:?capture label required}
mode=${2:-unassisted}
frames=${3:-1-5}
case "$label" in dota-gfxr-codex-*) ;; *) exit 64 ;; esac
case "$mode" in unassisted|page_guard) ;; *) exit 64 ;; esac
inner=$(cd "$(dirname "$0")" && pwd)/g16-dota-capture-inner.sh
out=$HOME/g16-games/dota-shader-identity-20261006/results/$label
mkdir -p "$out"
unset LD_LIBRARY_PATH LIBGL_DRIVERS_PATH GBM_BACKENDS_PATH __EGL_VENDOR_LIBRARY_FILENAMES
unset LD_PRELOAD ASAHI_MESA_DEBUG HK_GPU_BUSY_FILE HK_TIMELINE_FILE
export STEAM_RUNTIME_LOGGER=0
FEXInterpreter /bin/bash /mnt/g16-external/SteamLibrary/steamapps/common/SteamLinuxRuntime_sniper/_v2-entry-point \
    --verb=run -- /bin/bash "$inner" "$label" "$mode" "$frames" > "$out/runtime.log" 2>&1
status=$?
printf '%s\n' "$status" > "$out/runtime-exit-status"
exit "$status"
