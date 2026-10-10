#!/bin/bash
# boot-119-fwtrace arm (asahi-03 pings when up): which R->C shapes the kernel holds (G16 rc release lines), and whether
# HK_PERFTEST=batch (Lethal's setting) is what makes the in-submission edge kernel-held.
cd "$(dirname "$0")"
CONFIGS="barrier 16;barrier 16 --r2c-src fragment;barrier 16 --event;semaphore 16" ./rc-bench-air.sh fw119-nobatch
HKP=batch CONFIGS="barrier 16;semaphore 16" ./rc-bench-air.sh fw119-batch
HKP=batch LOAD=cpu CONFIGS="barrier 16" ./rc-bench-air.sh fw119-batch-cpu
LOAD=cpu CONFIGS="barrier 16" ./rc-bench-air.sh fw119-nobatch-cpu
