#!/bin/bash
# rc_bench barrier16 on the Air: idle GPU vs GPU kept busy by a second client (render_burst, continuous 1280x720 passes),
# BG overrides render_burst's args (e.g. big multi-ms passes); busy-cpu-1 adds all-core CPU load for ~60 s.
# to see whether the in-submission R->C edge (compute_deps=1 hold until the render's completion notification) stretches
# toward Lethal's ~0.3-1 ms when the GPU has other work in flight. No reset, no lease (asahi-03 holds it).
set -uo pipefail
A=root@192.168.60.2; here=$(cd "$(dirname "$0")" && pwd); rd=/tmp/rc-busy
icd=${ICD:-/opt/mesa-apple9-air-ed7603d/share/vulkan/icd.d/asahi_icd.aarch64.json}
out=$here/../rc-bench-air/busy${TAG:+-$TAG}-$(date +%Y%m%d_%H%M%S); mkdir -p "$out"
ssh -o ConnectTimeout=5 $A "mkdir -p $rd" && scp -q $here/rc_bench.a64 $A:$rd/rc_bench && scp -q $here/render_burst.a64 $A:$rd/render_burst || exit 1
ssh $A "chmod +x $rd/*; uname -v" > $out/setup.txt 2>&1
run() { ssh $A "cd $rd && cur=\$(journalctl -k -n1 --show-cursor | sed -n 's/^-- cursor: //p'); VK_DRIVER_FILES=$icd HK_EXPERIMENTAL_APPLE9=1 timeout 120 ./rc_bench --mode barrier --edges 16 --frames 600; journalctl -k --no-pager -o short-monotonic --after-cursor=\"\$cur\" | tail -50" > $out/$1.txt 2>&1
  echo "== $1: $(grep -E 'frames/s|render-end -> compute|render pass' $out/$1.txt | tr '\n' ' ' | cut -c1-330)"; }
run idle-1
ssh $A "cd $rd && VK_DRIVER_FILES=$icd HK_EXPERIMENTAL_APPLE9=1 setsid ./render_burst ${BG:---passes 8 --inflight 4} --seconds 300 --timeout-ms 15000 > $rd/bg.log 2>&1 & echo \$! > $rd/bg.pid"; sleep 4
run busy-1
ssh $A "for i in \$(seq \$(nproc)); do timeout 60 sh -c 'while :; do :; done' & done" >/dev/null 2>&1 &
sleep 3; run busy-cpu-1; wait
run busy-2
ssh $A "kill \$(cat $rd/bg.pid) 2>/dev/null; sleep 1; tail -3 $rd/bg.log" > $out/bg-tail.txt 2>&1
run idle-2
ssh $A "pgrep -fa 'render_burs[t]|rc_benc[h]'; rm -rf $rd" >> $out/setup.txt 2>&1
echo "results: $out"
