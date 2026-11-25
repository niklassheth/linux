// SPDX-License-Identifier: GPL-2.0-only
// Copyright The Gravity Linux Contributors

//! Monotonic 64-bit epoch tracking and half-ring admission control for the
//! 256-entry G16 firmware control channel (channel 12: SGX head `0xd640c0`,
//! ack `0xd640c8`, tail `0xd60060`).
//!
//! Enforces a strict `< 128` (`<= 127`) unacknowledged in-flight window across
//! every control-channel producer (queue context destruction and TVB
//! growth/memory-limit replies) so wrapping 8-bit hardware cursors always map
//! unambiguously to monotonic 64-bit epochs without modular wrap aliasing.
//! Pure state logic, host-tested.

/// Number of entries in the hardware control channel ring.
pub(crate) const CAPACITY: u32 = 256;
/// Maximum unacknowledged entries allowed in flight relative to either
/// firmware cursor (`head` or `ack`), strictly less than `CAPACITY / 2`.
pub(crate) const MAX_IN_FLIGHT: u64 = 127;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct ControlRing {
    head: u64,
    ack: u64,
    tail: u64,
}

impl ControlRing {
    pub(crate) const fn new(initial: u64) -> Self {
        Self {
            head: initial,
            ack: initial,
            tail: initial,
        }
    }

    /// Observe the hardware `(head, ack, tail)` cursors and advance the
    /// monotonic 64-bit `head` and `ack` epochs. Rejects out-of-range cursors,
    /// unexpected tail divergence, or a firmware cursor overtaking `tail`.
    pub(crate) fn observe(
        &mut self,
        hw_head: u32,
        hw_ack: u32,
        hw_tail: u32,
    ) -> core::result::Result<(), ()> {
        if hw_head >= CAPACITY || hw_ack >= CAPACITY || hw_tail >= CAPACITY {
            return Err(());
        }
        if hw_tail != (self.tail & (CAPACITY as u64 - 1)) as u32 {
            return Err(());
        }
        let head_delta =
            u64::from((hw_head + CAPACITY - (self.head & (CAPACITY as u64 - 1)) as u32) & (CAPACITY - 1));
        let ack_delta =
            u64::from((hw_ack + CAPACITY - (self.ack & (CAPACITY as u64 - 1)) as u32) & (CAPACITY - 1));
        if self.head + head_delta > self.tail || self.ack + ack_delta > self.tail {
            return Err(());
        }
        self.head += head_delta;
        self.ack += ack_delta;
        Ok(())
    }

    /// Whether another control-channel message can be enqueued without
    /// exceeding `MAX_IN_FLIGHT` unacknowledged entries against either cursor.
    #[inline]
    pub(crate) fn has_room(&self) -> bool {
        self.tail - self.head < MAX_IN_FLIGHT && self.tail - self.ack < MAX_IN_FLIGHT
    }

    /// Current ring write slot index and next hardware tail register value.
    #[inline]
    pub(crate) fn next_slot(&self) -> (u32, u32) {
        let mask = CAPACITY as u64 - 1;
        ((self.tail & mask) as u32, ((self.tail + 1) & mask) as u32)
    }

    /// Record that one entry was published to the hardware tail register and
    /// return the monotonic epoch that acknowledges it.
    #[inline]
    pub(crate) fn commit(&mut self) -> u64 {
        self.tail += 1;
        self.tail
    }

    /// Whether both firmware cursors have reached monotonic epoch `target`.
    #[inline]
    pub(crate) fn reached(&self, target: u64) -> bool {
        self.head >= target && self.ack >= target
    }

    /// Whether every published control message has been read and acknowledged.
    #[inline]
    pub(crate) fn drained(&self) -> bool {
        self.head == self.tail && self.ack == self.tail
    }
}
