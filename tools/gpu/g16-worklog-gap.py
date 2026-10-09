#!/usr/bin/env python3
# For each worklog'd run: Dota's render idle gaps >1 s and what happens to the first burst after each gap. Bounded.
import re,sys
kv=re.compile(r'([+\w]+)=((?:libkrun VM)|\S+)')
for path in sys.argv[1:]:
    txt=open(path,errors='replace').read(64<<20)
    S={};R={}
    for m in re.finditer(r'G16: worklog submitted (.*)',txt):
        d=dict(kv.findall(m.group(1))); S[(d['tgid'],d['ctx'],d['ordinal'],d['at'])]=d
    for m in re.finditer(r'G16: worklog retired (.*)',txt):
        d=dict(kv.findall(m.group(1))); R[(d['tgid'],d['ordinal'],d['render'])]=d
    dr=sorted((d for d in S.values() if d['comm'].startswith('libkrun') and d['render']=='true'),key=lambda d:int(d['at']))
    print('==',path.split('/')[0])
    for a,b in zip(dr,dr[1:]):
        g=(int(b['at'])-int(a['at']))/1e9
        if g>1.0:
            burst=[d for d in dr if 0<=int(d['at'])-int(b['at'])<5e6]
            info=[]
            for d in burst[:4]:
                r=R.get((d['tgid'],d['ordinal'],'true'))
                info.append(f"{d['ordinal']}@ctx{d['ctx']}:" + (f"{(int(r['retired'])-int(r['submitted']))/1e6:.1f}ms" if r else 'never'))
            others=sorted(set(d['comm'][:7] for d in S.values() if int(a['at'])<int(d['at'])<int(b['at'])))
            print(f"  gap {g:.2f}s before ord {b['ordinal']} (prev {a['ordinal']}), burst {len(burst)} renders: {' '.join(info)}; others in gap: {others}")
