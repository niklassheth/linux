#!/bin/bash
# Run rc_bench on the Air inside one of asahi-03's #119 hwdata boots. Usage: rc-bench-air.sh <arm-tag> <icd.json on Air>
# Copies the host cross-built rc_bench.a64 (mini sysroot), runs barrier16 / barrier64 / semaphore16 (1000 frames), collects the fw_trace lines.
set -uo pipefail
tag=$1; icd=${2:-/opt/mesa-apple9-air-ed7603d/share/vulkan/icd.d/asahi_icd.aarch64.json}; A=root@192.168.60.2; here=$(cd "$(dirname "$0")" && pwd)
out=$here/../rc-bench-air/$tag-$(date +%Y%m%d_%H%M%S); mkdir -p "$out"; rd=/tmp/rc-bench-$tag
ssh -o ConnectTimeout=5 $A "mkdir -p $rd" && scp -q $here/rc_bench.a64 $A:$rd/rc_bench || exit 1
ssh $A "uname -v; cat /proc/cmdline; chmod +x $rd/rc_bench; sha256sum $rd/rc_bench" > $out/setup.txt 2>&1
for cfg in "barrier 16" "barrier 64" "semaphore 16"; do set -- $cfg
  ssh $A "cd $rd && dmesg -c >/dev/null; VK_DRIVER_FILES=$icd HK_EXPERIMENTAL_APPLE9=1 timeout 120 ./rc_bench --mode $1 --edges $2 --frames 1000; dmesg" > $out/$1-$2.txt 2>&1
  echo "== $tag $1 x$2: $(grep -E 'frames/s|render-end -> compute' $out/$1-$2.txt | tr '\n' ' ')  rc-release-lines=$(grep -c 'rc release after notification' $out/$1-$2.txt)"
done
echo "results: $out"
