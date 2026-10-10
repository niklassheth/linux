#!/bin/bash
# Final hand-off (user decision: the mini goes to Codex). Wait for the last block-72 run (k72-D-2), then boot production
# #92 (artifacts/m4-linux/current) read-WRITE with the default args, run m4-post-boot, verify, release the lease.
cd /home/nsheth/Projects/asahi; L=tools/lease/lease.sh
while kill -0 4022667 2>/dev/null; do sleep 10; done
echo "$(date +%T) k72-D-2 done; lease holder: $($L holder mini)"
[ "$($L holder mini | cut -d' ' -f1)" = codex-dota ] || $L wait mini codex-dota 20 "final rw production restore for hand-off to Codex"
$L renew mini codex-dota 20
ssh -o BatchMode=yes -o ConnectTimeout=5 root@192.168.50.2 'm4-steam-shutdown 45' >/dev/null 2>&1 || true
ok=0
for a in 1 2 3; do
  if LEASE_OWNER=codex-dota timeout 240 env -u IMAGE -u DTB -u KERNEL_BUILD EXTRA_ARGS=asahi_m4.dependency_kind=0 gravity-bootloader/m4-linux/boot.sh > /tmp/claude-1000/final-restore-boot-$a.log 2>&1; then
    for i in $(seq 1 60); do ssh -o BatchMode=yes -o ConnectTimeout=5 root@192.168.50.2 true 2>/dev/null && break; sleep 2; done
    if ssh -o BatchMode=yes root@192.168.50.2 'm4-post-boot >/dev/null 2>&1; uname -v; findmnt -no OPTIONS /; systemctl is-active m4-kwin claude-headless input-forward-server; strings /usr/lib64/libgallium-26.3.0-devel.so | grep -m1 -o "git-[0-9a-f]\{10\}"'; then ok=1; break; fi
  fi
  echo "attempt $a failed"
done
echo "restore ok=$ok"
[ $ok = 1 ] && $L release mini codex-dota && echo "$(date +%T) released"
