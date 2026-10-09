#!/bin/bash
while [ -d /proc/3559558 ] && [ "$(awk '{print $3}' /proc/3559558/stat)" != Z ]; do sleep 10; done
[ "$(/home/nsheth/Projects/asahi/tools/lease/lease.sh holder mini | cut -d' ' -f1)" = codex-dota ] && /home/nsheth/Projects/asahi/tools/lease/lease.sh release mini codex-dota
echo "block 64 stopped early (manager) done at $(date -Is)" >> block64-console.log
