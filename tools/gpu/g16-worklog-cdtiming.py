#!/usr/bin/env python3
# Dota loading-end burst: compute 2616..2618 submit/retire vs render 2816 submit (T), from the work log. Bounded.
import re,sys
kv=re.compile(r'([+\w]+)=((?:libkrun VM)|\S+)')
for path in sys.argv[1:]:
    txt=open(path,errors='replace').read(64<<20)
    S={};R={}
    for m in re.finditer(r'G16: worklog submitted (.*)',txt):
        d=dict(kv.findall(m.group(1)))
        if d.get('comm','').startswith('libkrun'): S[(d['ordinal'],d['render'])]=int(d['at'])
    for m in re.finditer(r'G16: worklog retired (.*)',txt):
        d=dict(kv.findall(m.group(1)))
        if d.get('comm','').startswith('libkrun'): R[(d['ordinal'],d['render'])]=int(d['retired'])
    T=S.get(('2816','true'))
    if not T: print(path.split('/')[0],': no 2816'); continue
    out=[]
    for o in ('2616','2617','2618'):
        s=S.get((o,'false')); r=R.get((o,'false'))
        if s: out.append(f"C{o} sub {(s-T)/1e3:+.0f}us ret {(r-T)/1e3:+.0f}us" if r else f"C{o} sub {(s-T)/1e3:+.0f}us ret -")
    r16=R.get(('2816','true'))
    print(f"{path.split('/')[0]}: "+'; '.join(out)+f"; R2816 ret {(r16-T)/1e3:+.0f}us" if r16 else f"{path.split('/')[0]}: "+'; '.join(out)+"; R2816 ret -")
