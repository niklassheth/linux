#!/usr/bin/env python3
# Summarize #100 G16 worklog dumps in a kernel.log: per dump, per-client retire/submit counts, KWin/Xwayland submit
# timeline, live flights. Bounded: reads at most 64 MB, keeps at most 200k entries.
import re, sys, collections
txt = open(sys.argv[1], errors='replace').read(64 << 20)
pat = re.compile(r'^\[\s*([\d.]+)\] .*G16: worklog (\w+) (.*)$', re.M)
kv = re.compile(r'([+\w]+)=((?:libkrun VM)|\S+)')
dumps, cur, last = [], None, None
for m in pat.finditer(txt):
    t = float(m.group(1))
    if cur is None or t - last > 1.0:
        cur = {'t': t, 'retired': [], 'submitted': [], 'live': [], 'queue': [], 'other': []}; dumps.append(cur)
    last = t
    kind = m.group(2); d = dict(kv.findall(m.group(3)))
    (cur[kind] if kind in cur else cur['other']).append(d)
    if sum(len(x['retired']) for x in dumps) > 200000: break
for i, d in enumerate(dumps):
    print(f"== dump {i} at dmesg {d['t']:.2f}s: {len(d['retired'])} retired, {len(d['submitted'])} submitted, {len(d['live'])} live")
    if d['submitted']:
        ats = [int(s['at']) for s in d['submitted'] if 'at' in s]; lo, hi = min(ats), max(ats)
        print(f"   submit window {lo/1e9:.3f}..{hi/1e9:.3f} s ({(hi-lo)/1e9:.2f} s)")
    c = collections.Counter((s.get('comm'), s.get('ctx'), s.get('render')) for s in d['submitted'])
    for (comm, ctx, r), n in sorted(c.items(), key=lambda x: -x[1]): print(f"   submitted {comm:14} ctx={ctx} render={r}: {n}")
    for comm in ('kwin_wayland', 'Xwayland'):
        ts = sorted(int(s['at']) for s in d['submitted'] if s.get('comm') == comm)
        if ts:
            gaps = [(b - a) / 1e6 for a, b in zip(ts, ts[1:])]
            print(f"   {comm}: {len(ts)} submits, max gap {max(gaps, default=0):.1f} ms, last at {ts[-1]/1e9:.3f}; waits={collections.Counter(s.get('waits') for s in d['submitted'] if s.get('comm')==comm)}")
    for l in d['live'][:12]: print(f"   live {l.get('comm')} ctx={l.get('ctx')} ord={l.get('ordinal')} render={l.get('render')} submitted={int(l.get('submitted',0))/1e9:.3f}")
    for q in d['queue'][:16]: print(f"   queue ctx={q.get('ctx')} tgid={q.get('tgid')} stage={q.get('stage')} +0={q.get('+0')} +0x30={q.get('+0x30')} +0x40={q.get('+0x40')} last={q.get('ordinal')}")
