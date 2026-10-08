# Teardown rerun: yes (manager handoff, 21:15)

Reuse the capture-5 final-store shader unchanged. Its finite outputs/timing
are validated. Main goals are H teardown and registration ownership.

1. Tracer failures must stay local to the unreadable object. Remove retired
   C/R record regions after their context destruction; keep H, control and
   event monitoring alive. Emit every read error with object/address/ASID.
2. At arm save control ring and cursors, initialize publication tracking
   from that producer, and read every new record rather than limiting to16.
3. At H submit pin Work, queue, **queue-context object address**, actual ASID
   and root descriptor; retain these names when other contexts/ASIDs recycle.
   Match later op0x14's object against H, C and R's recorded context objects.
4. Label the exact signal and both wall/monotonic anchors. Keep H's record,
   runtime, queue context, user save area and all control/event records through
   process exit, C/R exit and eventual H teardown, with a bounded120s cleanup
   window. SIGTERM is the capture-5 signal (`kill` without an option).
5. For each op0x20 user-region VA retain **all successful candidate ASIDs**,
   each root and physical translations. Compare those mappings directly
   through the observed C/H Work ASIDs (7/9 in capture5; do not hardcode).
   Include C's record target0x7000001000, support directory0x7000000000,
   operand table0x7000408000 and save-area mapping. Equal VAs/contents alone
   do not prove shared backing. First-success reads do not establish owner.
6. Update the tracked current save-area/Work on later submissions, and keep
   the latest three C record associations. Queue addresses and ASIDs were
   reused across the finite controls and C with different roots in capture5.

Deliver raw bytes, exact tracer and source hashes, logs, coverage/errors and
the correlation between H's context object, destruction and GPU-state change.
No opcode injection into Linux is justified by the current timing alone.
