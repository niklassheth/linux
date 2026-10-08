# Capture 6 independent audit — Codex, 2026-10-07 22:18 EDT

Input: `../g16-timeout-recovery-20261007/capture6/trace.jsonl.zst`, associated
tracer, anchors and README. Reproducer: own topic's
`tools/gpu/g16-capture6-audit.py`. Output: `capture6-audit.json`.
Reconstructed snapshot changes assert the previous bytes before applying each
delta. All 8901 records parse; the control stream has exactly 82–89 after arm.

## Teardown and continuing execution

H is queue 0xfffffc20c06b24c0, queue-context object 0xfffffc20c05081c0,
ASID 9. Neither op14 names that object in the observed 147 s after SIGTERM.
The two op14 records name C's c0508180 and R's c0508080, as the manager reports.
C/R destruction unmaps their record rings and removes the C ASID root. No
monitor/control/doorbell errors are recorded.

H's runtime has 201 distinct observed values. It reaches 0xb7325dd1 at
host-relative 136.9259 s, up from 0x615e9645 at 76.9365 s, a 24.003 MHz delta rate.
H queue-context byte ranges+0xe and+0x2f change 384 times through 188.2758 s.
C/R progress while H has this continuing live state. This supports firmware
time-slicing and the manager's focus on admission/scheduling setup rather than
trying to destroy the running job as the first fix.

Limits: the monitor observes memory, not firmware write sites. The assertion
that+0x9c is written only at lane switches is an external behavioral model,
not directly proved by this trace. Field cadence alone does not identify a
quantum. No op14 within this interval does not establish that macOS never
cancels H, and SIGTERM is not itself proof of the guest process's final exit.
Our consumed early destroys did not evict H in the Linux test; that remains a
separate negative rather than a reason to assume Metal uses the same abort path.

## Registration attribution and private mappings

Control 82 is op20 with+4=8 and VA 0x7000408000. Through ASID 7 it maps to
PA 0x1015d4f4000 and the bytes/hash match C's pinned operand table. The same VA
through ASID 8 has a different page/hash, so first-success-ASID attribution from
capture5 was wrong. H receives no new op20 in this observation window.

| Mapping VA | C PA | H PA |
| --- | --- | --- |
| save 0x100001e8000 | 0x101e090c000 | 0x1015fec4000 |
| support 0x7000000000 | 0x10159600000 | 0x1023ab90000 |
| operand 0x7000408000 | 0x1015d4f4000 | 0x101a7e88000 |

Support-directory and target VAs are within the same 16 KiB page in each client.
Identical VAs/content therefore do not mean shared physical storage. H still
has operand/support mappings; absence of a C-style control registration is not
absence of those mappings. A separate op20 for every compute client is not
established as necessary for the observed coexistence.

## Initial queue/context narrowing and op1b

The first 64 bytes of H's context at its first doorbell are byte-identical to
our `g16_queue::context()` initializer. See `capture6-initial-context.json`.
Its static native-priority profile is +0x30/+0x34/+0x48=2 and+0x4c=0xffffffff;
the remaining+0x54..+0xa0 and+0xac..+0xfc initial words are zero. UUID 0x406
and address-valued fields differ legitimately. This narrows the search: there
is no visible missing host-authored flag in that context prefix, and no extra
initial descriptor tail quantum appears in this sample. It does not exclude
global setup, another allocation or a per-Work scheduling requirement.

Arm cursors are 82/82/82. Op1b pairs (0,1),(0,2),(1,1),(1,2),(2,1),(2,2)
remain in historical slots 74..79. None of the new records 82..89 is op1b.
Capture5 similarly retained old slots 66..71. Neither trace establishes those
records' publication timing or semantics. The queued Linux test publishes all
six before opening registrations, with native priority and valid zeroed record
storage; even success would need a follow-up to isolate these variables.
