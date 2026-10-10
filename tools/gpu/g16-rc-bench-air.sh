#!/bin/bash
# Run rc_bench on the Air inside one of asahi-03's #119 hwdata boots. Usage: rc-bench-air.sh <arm-tag> <icd.json on Air>
# LOAD=cpu|mixed runs host load on the Air during each run (stress-ng if present, else shell fallbacks).
# CONFIGS overrides the run list (default "barrier 16;barrier 64;semaphore 16").
# Copies the host cross-built rc_bench.a64 (mini sysroot), runs barrier16 / barrier64 / semaphore16 (1000 frames), collects the fw_trace lines.
set -uo pipefail
tag=$1; icd=${2:-/opt/mesa-apple9-air-ed7603d/share/vulkan/icd.d/asahi_icd.aarch64.json}; A=root@192.168.60.2; here=$(cd "$(dirname "$0")" && pwd)
out=$here/../rc-bench-air/$tag-$(date +%Y%m%d_%H%M%S); mkdir -p "$out"; rd=/tmp/rc-bench-$tag
ssh -o ConnectTimeout=5 $A "mkdir -p $rd" && scp -q $here/rc_bench.a64 $A:$rd/rc_bench || exit 1
ssh $A "uname -v; cat /proc/cmdline; chmod +x $rd/rc_bench; sha256sum $rd/rc_bench" > $out/setup.txt 2>&1
case "${LOAD:-}" in
  cpu) lcmd='if command -v stress-ng >/dev/null; then stress-ng --cpu $(nproc) --timeout 600s >/dev/null 2>&1 & else for i in $(seq $(nproc)); do (while :; do :; done) & done; fi' ;;
  mixed) lcmd='if command -v stress-ng >/dev/null; then stress-ng --cpu $(( $(nproc) / 2 )) --vm 2 --vm-bytes 512M --hdd 1 --hdd-bytes 256M --temp-path /tmp --timeout 600s >/dev/null 2>&1 & else for i in $(seq $(( $(nproc) / 2 ))); do (while :; do :; done) & done; (while :; do dd if=/dev/zero of=/tmp/rcload bs=1M count=256 conv=fsync status=none; rm -f /tmp/rcload; done) & (while :; do head -c 512M /dev/zero | tail -c 1 >/dev/null; done) & fi' ;;
  *) lcmd=: ;;
esac
ssh $A "command -v stress-ng || echo no-stress-ng; nproc" >> $out/setup.txt 2>&1
IFS=';' read -ra cfgs <<< "${CONFIGS:-barrier 16;barrier 64;semaphore 16}"
for cfg in "${cfgs[@]}"; do set -- $cfg; m=$1; e=$2; shift 2; x="$*"; nm="$m-$e$(echo "$x" | tr -d " -" | sed "s/^./-&/")"
  # Per-run kernel-log delta via a journal cursor (keeps the ring buffer intact for asahi-03's checks).
  ssh $A "setsid bash -c '$lcmd; wait' >/dev/null 2>&1 & echo \$! > $rd/load.pid; sleep 3" ; ssh $A "cd $rd && cur=\$(journalctl -k -n1 --show-cursor | sed -n 's/^-- cursor: //p'); VK_DRIVER_FILES=$icd HK_EXPERIMENTAL_APPLE9=1 ${HKP:+HK_PERFTEST=$HKP} timeout 120 ./rc_bench --mode $m --edges $e --frames 1000 $x; sleep 1; journalctl -k --no-pager -o short-monotonic --after-cursor=\"\$cur\"" > $out/$nm.txt 2>&1
  ssh $A "pkill -P \$(cat $rd/load.pid) 2>/dev/null; kill -- -\$(cat $rd/load.pid) 2>/dev/null; pkill -f 'stress-n[g]|rclo[a]d|while [:]; do [:]' 2>/dev/null; uptime" >> $out/$nm.txt 2>&1
  echo "== $tag $nm: $(grep -E 'frames/s|render-end -> compute' $out/$nm.txt | tr '\n' ' ')  rc-release-lines=$(grep -c 'rc release after notification' $out/$nm.txt)"
done
echo "results: $out"
