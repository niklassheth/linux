#!/usr/bin/env python3
# worksnap diff: stuck live Work(s) vs retired snapshots (same and other runs). For each (region, offset, byte) report
# bytes whose stuck value never occurs among the retired controls. Bounded: 64 MB per file, 200 snapshots.
import re,sys,collections
pat=re.compile(r'G16: worksnap   (live|retired) ordinal=(\d+) (\w+)\+0x([0-9a-f]+): \[([0-9a-f, ]+)\]')
hdr=re.compile(r'G16: worksnap (live|retired) tgid=\d+ comm=(.*?) ctx=\d+ ordinal=(\d+) Work=(\S+)')
def load(path):
    snaps=collections.OrderedDict(); cur=None; dumpi=0
    for l in open(path,errors='replace').read(64<<20).splitlines():
        h=hdr.search(l)
        if h:
            cur=(h.group(1),h.group(3),h.group(4)); 
            if cur not in snaps and len(snaps)<200: snaps[cur]={}
            continue
        m=pat.search(l)
        if m and cur in snaps and m.group(1)==cur[0] and m.group(2)==cur[1]:
            off=int(m.group(4),16)
            for i,b in enumerate(m.group(5).split(',')):
                b=b.strip()
                if b: snaps[cur][(m.group(3),off+i)]=int(b,16)
    return snaps
stuck_path=sys.argv[1]; ords=sys.argv[2].split(','); ctl_paths=sys.argv[3:]
S=load(stuck_path)
live=[(k,v) for k,v in S.items() if k[0]=='live' and k[1] in ords]
# Controls: every retired snapshot, plus live (in-flight) snapshots of Works that did not hang (other ordinals, other runs).
ctl=[v for k,v in S.items() if k[0]=='retired' or k[1] not in ords]
nlive=sum(1 for k in S if k[0]=='live' and k[1] not in ords)
for p in ctl_paths:
    L=load(p); ctl+=list(L.values()); nlive+=sum(1 for k in L if k[0]=='live')
print(f"live stuck snapshots: {[k[1] for k,_ in live]}; controls: {len(ctl)} (of which live in-flight: {nlive})")
for k,v in live:
    novel=[]
    for key,val in sorted(v.items()):
        seen=set(c[key] for c in ctl if key in c)
        if seen and val not in seen: novel.append((key,val,sorted(seen)[:6],len(seen)))
    print(f"== live ord {k[1]} Work {k[2]}: {len(v)} bytes, {len(novel)} novel")
    for (reg,off),val,seen,n in novel[:60]: print(f"   {reg}+0x{off:03x}: stuck {val:#04x}  controls({n}) {['%#04x'%s for s in seen]}")
