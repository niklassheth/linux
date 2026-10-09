#!/usr/bin/env python3
# Dota's loading-end burst (render 2816) shape per run: Dota submits from -0.5 s to +20 ms, with durations. Bounded.
import re,sys
kv=re.compile(r'([+\w]+)=((?:libkrun VM)|\S+)')
for path in sys.argv[1:]:
    txt=open(path,errors='replace').read(64<<20)
    S={};R={}
    for m in re.finditer(r'G16: worklog submitted (.*)',txt):
        d=dict(kv.findall(m.group(1))); S[(d['tgid'],d['ctx'],d['ordinal'],d['render'])]=d
    for m in re.finditer(r'G16: worklog retired (.*)',txt):
        d=dict(kv.findall(m.group(1))); R[(d['tgid'],d['ordinal'],d['render'])]=d
    v=sorted(S.values(),key=lambda d:int(d['at']))
    c=[int(d['at']) for d in v if d['comm'].startswith('libkrun') and d['render']=='true' and d['ordinal']=='2816']
    name=path.split('/')[0]
    if not c: print(name,': 2816 not in dumps'); continue
    T=c[0]; out=[]
    for d in v:
        t=int(d['at'])-T
        if -0.5e9<t<0.02e9 and d['comm'].startswith('libkrun'):
            r=R.get((d['tgid'],d['ordinal'],d['render']))
            out.append(f"{'R' if d['render']=='true' else 'C'}{d['ordinal']}@{t/1e3:+.0f}us" + (f"({(int(r['retired'])-int(r['submitted']))/1e6:.1f}ms)" if r else "(-)") + (f"[held {d['held_us']}]" if d.get('held_us','-1')!='-1' else ''))
    pre=sum(1 for o in out if o.startswith('C') and '@-' in o)
    print(f"{name}: computes-before={pre}: "+' '.join(out))
