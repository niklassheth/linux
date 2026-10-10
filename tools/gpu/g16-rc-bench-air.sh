#!/bin/bash
# Run rc_bench on the Air inside one of asahi-03's #119 hwdata boots. Usage: rc-bench-air.sh <arm-tag> <icd.json on Air>
# Builds natively on the Air, runs barrier16 / barrier64 / semaphore16 (1000 frames), collects the fw_trace lines.
set -uo pipefail
tag=$1; icd=$2; A=root@192.168.60.2; here=$(cd "$(dirname "$0")" && pwd)
out=$here/../rc-bench-air/$tag-$(date +%Y%m%d_%H%M%S); mkdir -p "$out"; rd=/tmp/rc-bench-$tag
ssh -o ConnectTimeout=5 $A "mkdir -p $rd" && scp -q $here/rc_bench.c $here/spirv.h $here/spin.h $A:$rd/ || exit 1
ssh $A "uname -v; cat /proc/cmdline; cd $rd && cc -O2 -std=c11 -D_POSIX_C_SOURCE=200809L -I. -o rc_bench rc_bench.c -lvulkan && echo built" > $out/setup.txt 2>&1
for cfg in "barrier 16" "barrier 64" "semaphore 16"; do set -- $cfg
  ssh $A "cd $rd && dmesg -c >/dev/null; VK_DRIVER_FILES=$icd HK_EXPERIMENTAL_APPLE9=1 timeout 120 ./rc_bench --mode $1 --edges $2 --frames 1000; dmesg" > $out/$1-$2.txt 2>&1
  echo "== $tag $1 x$2: $(grep -E 'frames/s|render-end -> compute' $out/$1-$2.txt | tr '\n' ' ')  rc-release-lines=$(grep -c 'rc release after notification' $out/$1-$2.txt)"
done
echo "results: $out"
