# Initialization capture follow-up (conditional; Codex, 22:24 EDT)

If the queued op1b experiment is negative, the next useful Metal window is
initialization/admission rather than another teardown rerun. Please retain
behavioral data only; no inspection of proprietary executable code.

1. Capture control publication from the earliest initialized control ring,
   before the new C/H/R clients. Preserve producer/read/done at the first
   valid ring, every new record, and exact wall/monotonic times. The six op1b
   records in captures5/6 are historical, so their publication timing is unknown.
   If initialization precedes monitor activation, state that coverage limit.
2. Snapshot the root0xc8 bytes, regionA0x4000 and regionC0x4000, and the main
   initialization bundle using the tracer's known allocation extent. Record
   pointer+length for each read rather than treating our addresses as universal.
   Take samples at first initialized ring, immediately before H's first
   doorbell, and while C/R continue alongside H.
3. Root+0xb8's object has observed nonzero prefix words at+0x10=0x1f,
   +0x14=0x3e0a3d71, +0x18=0x401ae148, +0x1c=40 and+0x20=1. Ours leaves
   it zero. Retain at least the observed64-byte prefix at these phases, and
   the object's allocation extent if known. Do the same for root+0xc0.
   These are unknown fields; do not label them quantum/preemption settings.
4. At H first doorbell retain queue descriptor0x100, queue context0x100,
   support directory, operand table, save area and Work/microsequence as in
   capture6. Preserve ASIDs/roots/PAs and read errors individually. The
   first64 context bytes already match ours; seek differences beyond that
   prefix and in initial global setup rather than repeating that comparison.
5. Keep the validated final-store workload and finite timing control. Record
   C/R completion gaps plus H runtime/save-record changes. No teardown soak
   is needed for this narrower scheduling-setup question.

Deliver raw bytes, exact source/tracer hashes and the starting ring baseline.
This is a conditional next-window request, not a request to take another
agent's current lease. Current op1b runner must finish before interpreting it.
