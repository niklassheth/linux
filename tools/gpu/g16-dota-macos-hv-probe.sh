#!/bin/bash
# Feasibility probe for the macOS Dota burst capture (no tracer, no GPU workload):
# reset the mini, chainload m1n1 (NO_DISPLAY build), boot the 25G83 guest under the HV, wait for guest SSH,
# check for Steam/Dota and a GUI session, exit the HV cleanly, then restore production Linux (RO) and release.
# Usage: hv-probe.sh   (takes and releases the mini lease as codex-dota)
set -u
A=/home/nsheth/Projects/asahi
O=$A/artifacts/dota-compute-stall-20261007/macos-burst-capture
G=nsheth@192.168.1.206
SSHO=(-o UserKnownHostsFile=/home/nsheth/.ssh/known_hosts_m1n1_macos -o ConnectTimeout=5 -o BatchMode=yes)
stamp=$(date +%Y%m%d_%H%M%S)
xnu_log=$A/logs/xnu_serial_${stamp}.log
hv_log=$A/logs/hv_run_${stamp}.log
fifo=/tmp/claude-1000/-home-nsheth-Projects-asahi/d6d5d692-0850-42f6-b678-4dbff20e0026/scratchpad/hvin.$$
export LEASE_OWNER=codex-dota
$A/tools/lease/lease.sh wait mini codex-dota 40 "XNU feasibility probe for macOS Dota burst capture" || exit 1
echo "xnu_log=$xnu_log hv_log=$hv_log"
cd "$A/m1n1" || exit 1
ssh -o ConnectTimeout=5 -o BatchMode=yes root@192.168.50.2 'm4-steam-shutdown 45; sync; echo s > /proc/sysrq-trigger; echo u > /proc/sysrq-trigger' 2>/dev/null || true
ssh 192.168.1.166 'sudo -n /opt/homebrew/bin/macvdmtool reboot serial' || exit 1
for i in $(seq 120); do [ -e /dev/m1n1 ] && break; sleep 1; done
sleep 2
set -o pipefail
uv run --with-requirements requirements.txt python proxyclient/tools/chainload.py -r build/m1n1.bin 2>&1 | tail -n 3 || exit 1
set +o pipefail
for i in $(seq 60); do [ -e /dev/m1n1-xnu ] && break; sleep 1; done
stty -F /dev/m1n1-xnu raw -echo
cat /dev/m1n1-xnu >"$xnu_log" &
xnu_pid=$!
mkfifo "$fifo"; exec 9<>"$fifo"
export PYTHONPATH=$A/m1n1/proxyclient M1N1DEVICE=/dev/m1n1
uv run --with-requirements requirements.txt python -u proxyclient/tools/run_guest.py \
   -s "$A/kdks/25G82-root/System/Library/Kernels/kernel.release.t8132.dSYM/Contents/Resources/DWARF/kernel.release.t8132" \
   "$A/kernelcache.25G83.mac16g" serial=3 <&9 >"$hv_log" 2>&1 &
guest_pid=$!
up=0
for i in $(seq 90); do
   kill -0 "$guest_pid" 2>/dev/null || { echo "guest exited early"; break; }
   ssh "${SSHO[@]}" "$G" true 2>/dev/null && { up=1; break; }
   sleep 10
done
if [ $up = 1 ]; then
   echo "guest up after ~$((i * 10))s"
   sleep 30
   ssh "${SSHO[@]}" "$G" 'sw_vers; echo "== users"; who; echo "== gui"; pgrep -lx WindowServer; pgrep -lx loginwindow; pgrep -lx Dock; launchctl print gui/501 2>&1 | head -5
      echo "== steam"; ls -d /Applications/Steam.app "$HOME/Library/Application Support/Steam" 2>&1
      ls "$HOME/Library/Application Support/Steam/steamapps/common/" 2>&1 | head
      ls -d "$HOME/Library/Application Support/Steam/steamapps/common/dota 2 beta/game/bin/osx64" 2>&1
      grep -h "\"name\"\|SizeOnDisk\|StateFlags" "$HOME/Library/Application Support/Steam/steamapps/appmanifest_570.acf" 2>&1 | head
      echo "== loginusers"; grep -c AccountName "$HOME/Library/Application Support/Steam/config/loginusers.vdf" 2>&1
      echo "== disk"; df -h / "$HOME" | tail -2
      echo "== displays"; system_profiler SPDisplaysDataType 2>/dev/null | grep -E "Chipset|Resolution|Display Type|Online" | head
      echo "== autologin"; defaults read /Library/Preferences/com.apple.loginwindow autoLoginUser 2>&1' > "$O/probe-$stamp.txt" 2>&1
   cat "$O/probe-$stamp.txt"
fi
if kill -0 "$guest_pid" 2>/dev/null; then
   kill -INT "$guest_pid"; sleep 3
   printf 'hv.exit()\n' >&9; sleep 10
   printf '\x04' >&9
   exec 9>&-
   for i in $(seq 40); do kill -0 "$guest_pid" 2>/dev/null || break; sleep 1; done
   kill -0 "$guest_pid" 2>/dev/null && echo "!! HV still running after exit request"
fi
grep -m1 "All CPUs exited" "$hv_log" || echo "no 'All CPUs exited' in hv log"
sleep 2; kill "$xnu_pid" 2>/dev/null; wait "$xnu_pid" 2>/dev/null
rm -f "$fifo"
for p in $(pgrep -f "[b]in/python -u proxyclient/tools/run_guest.py"); do kill "$p"; done
# Restore production #20 with the RO root + post-boot (payload "restore"), as ro-session does.
cd "$A"
R=$A/artifacts/dota-compute-stall-20261007/ro-session
ro_args="ro systemd.mask=systemd-remount-fs.service systemd.mask=home.mount systemd.mask=boot.mount systemd.mask=boot-efi.mount systemd.mask=var-swap-swapfile.swap systemd.mask=systemd-growfs-root.service"
timeout 240 env -u IMAGE -u DTB -u KERNEL_BUILD EXTRA_ARGS="asahi_m4.dependency_kind=0 $ro_args" gravity-bootloader/m4-linux/boot.sh > "$O/linux-boot-$stamp.log" 2>&1; echo "boot rc=$?"
for i in $(seq 40); do ssh -o ConnectTimeout=3 -o BatchMode=yes root@192.168.50.2 true 2>/dev/null && break; sleep 10; done
d=/tmp/codex-dota-restore-$stamp
ssh -o BatchMode=yes root@192.168.50.2 "mkdir -p $d" && scp -q -o BatchMode=yes "$R/payload.sh" root@192.168.50.2:$d/payload.sh && \
  ssh -o BatchMode=yes root@192.168.50.2 "bash $d/payload.sh $d restore; uname -v; findmnt -no OPTIONS /; systemctl is-active m4-kwin claude-headless input-forward-server" > "$O/restore-$stamp.log" 2>&1
tail -5 "$O/restore-$stamp.log"
$A/tools/lease/lease.sh release mini codex-dota
echo PROBE_DONE
