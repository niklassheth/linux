#!/usr/bin/env python3
from pathlib import Path
import datetime,importlib.util,json,re,subprocess,time
root=Path('/home/nsheth/g16-games/dota-shader-identity-20261006')
import sys
out=root/'results'/sys.argv[1]
spec=importlib.util.spec_from_file_location('capture',root/'capture-ring.py');capture=importlib.util.module_from_spec(spec);spec.loader.exec_module(capture)
decoder=capture.load_decoder(root/'shader-ring.py')
start=time.monotonic(); since=datetime.datetime.now().astimezone().isoformat(timespec='seconds')
(out/'watch-start.json').write_text(json.dumps({'since':since,'monotonic':start})+'\n')
proof=False; reason=None; fault=None
with (out/'host-memory.jsonl').open('w') as memory:
 while True:
  elapsed=time.monotonic()-start
  info={l.split(':')[0]:int(l.split()[1]) for l in Path('/proc/meminfo').read_text().splitlines()}
  memory.write(json.dumps({'elapsed':elapsed,'available_kb':info['MemAvailable'],'swap_free_kb':info['SwapFree']})+'\n');memory.flush()
  kernel=subprocess.check_output(['journalctl','-k','-b','--since',since,'--no-pager','-o','short-monotonic'],text=True)
  (out/'kernel.log').write_text(kernel)
  if re.search(r'G16:.*(?:async Work .*timeout|failed Event kind=|fault addr=)',kernel):
   reason='GPU timeout/fault'; m=re.search(r'G16: fault addr=(0x[0-9a-f]+)',kernel); fault=int(m.group(1),16) if m else None
  elif info["MemAvailable"]<int(__import__("os").environ.get("WATCH_MIN_KB","2097152")):reason="Host available memory below guard"
  elif (out/'exit-status').exists():reason='Game exited'
  elif elapsed>float(__import__("os").environ.get("WATCH_LIMIT","300")):reason="Observation limit"
  if reason:break
  if not proof and elapsed>10 and (out/'ring-control/open-files.json').exists():
   result=capture.capture(out,'startup','Live ring startup check',decoder,timeout=15)
   proof=True;print('Startup ring verified',result['valid_owners'],flush=True)
  if int(elapsed)%15==0:print(f'elapsed={elapsed:.0f}s available={info["MemAvailable"]//1024}MiB ring={proof}',flush=True)
  time.sleep(1)
 print(reason,flush=True)
 # Drivers without the shader-identity ring (anything but the pinned identity
 # build) have no ring files: still record the verdict, without owners.
 try:
  result=capture.capture(out,'terminal',reason,decoder,fault,timeout=20)
 except RuntimeError as e:
  print('terminal ring capture unavailable:',e,flush=True)
  result={'valid_owners':None,'ring':'unavailable'}
 if reason == 'GPU timeout/fault':
  # Preserve the client/ring for a second diagnostic window; these sampled
  # fields can prove progress when they advance, not execution when frozen.
  followup_start=time.monotonic()
  while time.monotonic()-followup_start < 20:
   kernel=subprocess.check_output(['journalctl','-k','-b','--since',since,'--no-pager','-o','short-monotonic'],text=True)
   (out/'kernel-followup.log').write_text(kernel)
   time.sleep(1)
  (out/'kernel.log').write_text(kernel)
  try:
   capture.capture(out,'followup',reason+' +20s',decoder,fault,timeout=20)
  except RuntimeError as error:
   (out/'followup-ring-error.txt').write_text(str(error)+'\n')
 terminal={'reason':reason,'fault':fault,'elapsed':time.monotonic()-start,'valid_owners':result['valid_owners'],'ring':result.get('ring','captured')}
 (out/'safe-to-stop.json').write_text(json.dumps(terminal,indent=2)+'\n');print(json.dumps(terminal),flush=True)
