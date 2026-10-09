#!/bin/bash
while [ -d /proc/3707574 ] && [ "$(awk '{print $3}' /proc/3707574/stat)" != Z ]; do sleep 10; done
[ "$(/home/nsheth/Projects/asahi/tools/lease/lease.sh holder mini | cut -d' ' -f1)" = codex-dota ] && /home/nsheth/Projects/asahi/tools/lease/lease.sh release mini codex-dota
echo "block 67 stopped (manager) $(date -Is)"
