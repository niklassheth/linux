#!/usr/bin/env python3
# Per stuck flight in a hang report: stage stamps (done?) and each firmware wait item (satisfied?). Bounded.
import re,sys
for path in sys.argv[1:]:
    lines=open(path,errors='replace').read(64<<20).splitlines()[:400000]
    print('==',path.split('/')[0]); cur=None; seen=0
    for l in lines:
        m=re.search(r'hang flight Work=(\S+) context=(\d+) .*?ordinal=(\d+) .*?comm=(.*)$',l)
        if m:
            if cur: print('  '+cur)
            seen+=1
            if seen>12: cur=None; break
            cur=f"{m.group(4)[:9]:9} ctx={m.group(2)} ord={m.group(3)}:"; continue
        if cur is None: continue
        m=re.search(r'stage (\d) fw stamp \S+=(0x[0-9a-f]+) want (0x[0-9a-f]+)',l)
        if m: cur+=f" s{m.group(1)}={'done' if int(m.group(2),16)>=int(m.group(3),16) else 'PENDING'}"; continue
        m=re.search(r'waits on (\w+) stamp \S+=(0x[0-9a-f]+) want (0x[0-9a-f]+) event (\d+)',l)
        if m: cur+=f" | wait {m.group(1)} ev{m.group(4)} {'sat' if int(m.group(2),16)>=int(m.group(3),16) else 'UNSAT'}"; continue
        if 'G16:' in l and not l.split('G16:')[1].startswith('  '):
            print('  '+cur); cur=None
    if cur: print('  '+cur)
