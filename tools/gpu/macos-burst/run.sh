#!/bin/bash
# Guest side: two background Metal clients (641x361, 643x361) for contention, then the burst program in
# both modes (one command buffer per burst, then one per pass), 6 bursts each.
set -u
cd "$(dirname "$0")"
clang -fobjc-arc -O2 -framework Metal -framework Foundation -o xburst xburst.m || { echo COMPILE_FAIL; exit 1; }
./xburst client 641 361 40 > client1.log 2>&1 & c1=$!
./xburst client 643 361 40 > client2.log 2>&1 & c2=$!
sleep 3
./xburst one 6
./xburst split 6
wait $c1 $c2
cat client1.log client2.log
echo GUEST_DONE
