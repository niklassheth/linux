// SPDX-License-Identifier: GPL-2.0-only
// Copyright The Gravity Linux Contributors

//! Per-lane firmware wait tracking (kind-aware and monotonic) and in-flight
//! producer user-timestamp coverage checks.
//!
//! Pure state machine, host-tested.

use crate::g16_stamp;

/// The latest firmware dependency wait recorded on one lane for one producer
/// stamp address.
///
/// Firmware `kind = 1` waits (dynamic dependency graph) wait for both the
/// producer Work and its post-Work user timestamp writes, whereas `kind = 0`
/// waits (internal wait) release as soon as the producer Work ends. Therefore
/// `kind = 1` is strictly stronger than `kind = 0`:
/// - `any_value` tracks the latest stamp waited on by kind 0 or kind 1.
/// - `kind1_value` tracks the latest stamp waited on specifically by kind 1.
///
/// Both advance strictly monotonically in `g16_stamp::reached` order.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct WaitedStamp {
    pub(crate) address: u64,
    pub(crate) any_value: u32,
    pub(crate) kind1_value: Option<u32>,
}

/// Per-lane (`0` = TA, `1` = 3D, `2` = Compute) record of the latest waits
/// actually published into each lane's firmware ring.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(crate) struct LaneWaits {
    slots: [[Option<WaitedStamp>; 2]; 3],
}

/// Distance past which a remembered stamp is pruned before it can approach the
/// half-range wrap boundary (`0x8000_0000`) of `g16_stamp::reached`. In-flight
/// Works are bounded by `MAX_FLIGHTS` (1024 * 0x100 = 0x4_0000).
const PRUNE_DISTANCE: u32 = 0x4000_0000;

impl LaneWaits {
    pub(crate) const fn new() -> Self {
        Self {
            slots: [[None; 2]; 3],
        }
    }

    /// Record that a published Work on `lane` emitted a firmware dependency
    /// item for `(address, value)` with `kind` (0 or 1). Older waits never
    /// regress the tracked stamp values, and a `kind = 0` wait never updates
    /// `kind1_value`.
    pub(crate) fn note(&mut self, lane: usize, address: u64, value: u32, kind: u32) {
        let slots = &mut self.slots[lane];
        if let Some(entry) = slots.iter_mut().flatten().find(|w| w.address == address) {
            if g16_stamp::reached(value, entry.any_value) {
                entry.any_value = value;
            }
            if kind >= 1
                && entry
                    .kind1_value
                    .is_none_or(|prev| g16_stamp::reached(value, prev))
            {
                entry.kind1_value = Some(value);
            }
        } else {
            slots[1] = slots[0];
            slots[0] = Some(WaitedStamp {
                address,
                any_value: value,
                kind1_value: (kind >= 1).then_some(value),
            });
        }
    }

    /// Whether an earlier published Work on `lane` already emitted a firmware
    /// dependency item on `address` covering `value` with wait strength at
    /// least `required_kind` (0 or 1).
    pub(crate) fn covers(&self, lane: usize, address: u64, value: u32, required_kind: u32) -> bool {
        self.slots[lane]
            .iter()
            .flatten()
            .find(|w| w.address == address)
            .is_some_and(|w| {
                if required_kind >= 1 {
                    w.kind1_value.is_some_and(|v| g16_stamp::reached(v, value))
                } else {
                    g16_stamp::reached(w.any_value, value)
                }
            })
    }

    /// Drop any remembered stamp on `address` that has fallen into the old
    /// quarter-ring behind `current`, preventing 32-bit stamp wraparound from
    /// ever making an ancient wait appear newer than a live stamp.
    pub(crate) fn prune(&mut self, address: u64, current: u32) {
        let stale = |v: u32| {
            g16_stamp::reached(current, v) && current.wrapping_sub(v) >= PRUNE_DISTANCE
        };
        for lane in &mut self.slots {
            for slot in lane.iter_mut() {
                let Some(entry) = slot else { continue };
                if entry.address != address {
                    continue;
                }
                if stale(entry.any_value) {
                    *slot = None;
                } else if entry.kind1_value.is_some_and(stale) {
                    entry.kind1_value = None;
                }
            }
        }
    }
}

/// Find the latest stamp value (in `g16_stamp::reached` order) among in-flight
/// timestamped Works on `dep_address` covered by `dep_value`.
pub(crate) fn latest_covered_timestamp(
    flights: impl IntoIterator<Item = (u64, u32)>,
    dep_address: u64,
    dep_value: u32,
) -> Option<u32> {
    let mut latest: Option<u32> = None;
    for (address, value) in flights {
        if address == dep_address && g16_stamp::reached(dep_value, value) {
            latest = Some(match latest {
                Some(prev) if g16_stamp::reached(prev, value) => prev,
                _ => value,
            });
        }
    }
    latest
}

/// Whether `dep` covers an in-flight Work with user timestamps that has NOT
/// yet been serialized by a prior `kind = 1` wait on `lane`.
pub(crate) fn has_uncovered_timestamps(
    waited: &LaneWaits,
    lane: usize,
    flights: impl IntoIterator<Item = (u64, u32)>,
    dep_address: u64,
    dep_value: u32,
) -> bool {
    let Some(ts_val) = latest_covered_timestamp(flights, dep_address, dep_value) else {
        return false;
    };
    !waited.covers(lane, dep_address, ts_val, 1)
}
