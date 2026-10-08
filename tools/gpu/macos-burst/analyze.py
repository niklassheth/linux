#!/usr/bin/env python3
"""analyze.py trace.jsonl: firmware-facing sequence around xburst's 1280x720 bursts (Metal, m1n1 HV tracer)."""
import collections, json, sys
recs = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
recs = [r for r in recs if 'host_time' in r]
recs.sort(key=lambda r: r['host_time'])
def item_str(it):
    if it.get('selector') == 4:
        return f"DEP(k={it['kind']} ev={it['event']:#x} wait={it['wait']:#x})"
    return f"sel{it.get('selector')}"
def rdesc(r):
    w, h = r['dimensions']
    tag = {(1280,720):'B720', (1920,1080):'B1080', (298,452):'small', (641,361):'cl1', (643,361):'cl2'}.get((w,h), f"{w}x{h}")
    ta, td = r['TA'], r['3D']
    bm = td.get('buffer_manager_changed_runs') or []
    return (f"{tag:6s} q{r['queue_id']} ctx{td.get('context_id')} ord{r['ordinal']} db{r.get('doorbell_ordinal')} "
            f"TA[{' '.join(item_str(i) for i in ta.get('items', []))}] 3D[{' '.join(item_str(i) for i in td.get('items', []))}]"
            f"{' BMchg' if bm else ''} pair={r.get('pair_transition')}")
renders = [r for r in recs if r['kind'] == 'render']
print(len(recs), "timed records;", collections.Counter(r['kind'] for r in recs))
print("render sizes:", collections.Counter(tuple(r['dimensions']) for r in renders))
# windows: each first B720 of a burst (preceded by a 'small' render or a gap > 50 ms)
b720 = [i for i, r in enumerate(recs) if r['kind'] == 'render' and tuple(r['dimensions']) == (1280, 720)]
starts = [i for k, i in enumerate(b720) if k == 0 or recs[i]['host_time'] - recs[b720[k-1]]['host_time'] > 0.05]
print("bursts found:", len(starts))
for n, i in enumerate(starts[:int(sys.argv[2]) if len(sys.argv) > 2 else 4]):
    t0 = recs[i]['host_time']
    print(f"\n== burst {n} at {t0:.6f}")
    lo = i
    while lo > 0 and (t0 - recs[lo-1]['host_time']) < 0.05: lo -= 1
    for r in recs[max(0, lo-4):i+16]:
        dt = (r['host_time'] - t0) * 1e3
        if r['kind'] == 'render': print(f"  {dt:+9.3f} ms  {rdesc(r)}")
        else: print(f"  {dt:+9.3f} ms  {r['kind']} {r.get('value', ''):#x}" if isinstance(r.get('value'), int) else f"  {dt:+9.3f} ms  {r['kind']}")
