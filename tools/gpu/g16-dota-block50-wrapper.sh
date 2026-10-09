#!/bin/bash
# Wrapper (called at the end of block 53). Manager: skip block 54 and the replay+Steam block; free the mini for
# claude-driver's queue8 install, then claude-kernel's #83 gate.
/home/nsheth/Projects/asahi/tools/lease/lease.sh release mini codex-dota
echo "night queue done (block 54 + replay-steam skipped) at $(date -Is)"
