#!/bin/bash
# One #121 host-priority arm (asahi-03 boots it): rc_bench under all-core CPU load, batched (Lethal's HK_PERFTEST=batch)
# and unbatched, semaphore16 + barrier16. Usage: h121-arm.sh <arm: def|irq|pump|hp|all>
cd "$(dirname "$0")"; arm=${1:?arm}
HKP=batch LOAD=cpu CONFIGS="barrier 16;semaphore 16" ./rc-bench-air.sh h121-$arm-batch-cpu
LOAD=cpu CONFIGS="barrier 16;semaphore 16" ./rc-bench-air.sh h121-$arm-nobatch-cpu
