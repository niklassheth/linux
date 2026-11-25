// SPDX-License-Identifier: GPL-2.0-only
// Copyright The Gravity Linux Contributors

//! Fast O(1) admission headroom pre-check, exact Ledger-aligned cap checks,
//! and atomic `(queue_cap, lane_cap)` configuration for G16 queues and lanes.
//!
//! Pure policy logic, host-tested. Evaluates capacity limits that cannot clear
//! until a flight retires (`retire_gen` advances) or a runtime cap knob
//! (`queue_cap`, `lane_cap`) changes.

use core::sync::atomic::{AtomicU64, Ordering};

/// Snapshot of every input that can unblock an unconditional capacity deferral.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct CapBlock {
    pub(crate) retire_gen: u64,
    pub(crate) queue_cap: u32,
    pub(crate) lane_cap: u32,
}

impl CapBlock {
    /// True while a prior unconditional capacity deferral is guaranteed to
    /// still fail (neither a retirement nor a cap change has occurred).
    #[inline]
    pub(crate) fn still_blocked(prev: Option<Self>, now: Self) -> bool {
        prev == Some(now)
    }
}

/// Every lane must stay below the firmware's 128-Work window for dependency
/// items (k24: 127 clean, 129 stalled), so at least one bound in `1..=127`
/// stays in force and `lane_cap` never exceeds 127.
#[inline]
pub(crate) const fn caps_safe(queue: u32, lane: u32) -> bool {
    lane <= 127 && ((queue >= 1 && queue <= 127) || (lane >= 1 && lane <= 127))
}

#[inline]
const fn pack_caps(queue: u32, lane: u32) -> u64 {
    ((queue as u64) << 32) | (lane as u64)
}

#[inline]
const fn unpack_caps(packed: u64) -> (u32, u32) {
    ((packed >> 32) as u32, packed as u32)
}

/// Atomic `(queue_cap, lane_cap)` pair backed by a single `AtomicU64`.
///
/// Updates validate the joint `caps_safe()` invariant inside a CAS loop so
/// concurrent debugfs writes to `queue_cap` and `lane_cap` can never leave
/// both caps disabled `(0, 0)`, and readers always observe a consistent pair.
pub(crate) struct CapPair(AtomicU64);

impl CapPair {
    pub(crate) const fn new(queue: u32, lane: u32) -> Self {
        Self(AtomicU64::new(pack_caps(queue, lane)))
    }

    #[inline]
    pub(crate) fn load(&self) -> (u32, u32) {
        unpack_caps(self.0.load(Ordering::Acquire))
    }

    pub(crate) fn init(&self, queue: u32, lane: u32) -> core::result::Result<(), ()> {
        if !caps_safe(queue, lane) {
            return Err(());
        }
        self.0.store(pack_caps(queue, lane), Ordering::Release);
        Ok(())
    }

    pub(crate) fn update_queue(&self, queue: u32) -> core::result::Result<(u32, u32), ()> {
        self.0
            .fetch_update(Ordering::AcqRel, Ordering::Acquire, |packed| {
                let (_, lane) = unpack_caps(packed);
                if !caps_safe(queue, lane) {
                    return None;
                }
                Some(pack_caps(queue, lane))
            })
            .map(|prev| (queue, unpack_caps(prev).1))
            .map_err(|_| ())
    }

    pub(crate) fn update_lane(&self, lane: u32) -> core::result::Result<(u32, u32), ()> {
        self.0
            .fetch_update(Ordering::AcqRel, Ordering::Acquire, |packed| {
                let (queue, _) = unpack_caps(packed);
                if !caps_safe(queue, lane) {
                    return None;
                }
                Some(pack_caps(queue, lane))
            })
            .map(|prev| (unpack_caps(prev).0, lane))
            .map_err(|_| ())
    }
}

/// Per-lane counters copied from `Ledger::lane` for a queue's three lanes.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(crate) struct LaneLoad {
    pub(crate) works: usize,
    pub(crate) load: usize,
    pub(crate) owned: usize,
}

/// Admission accounting for one Work, separating physical workqueue ring
/// entries (which include preludes such as `InitBM` and the fragment prelude)
/// from the firmware-window Work+dependency charges recorded in `Ledger::add()`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct FlightCharge {
    /// Physical workqueue ring entries written per lane (TA, 3D, compute).
    pub(crate) ring_entries: [u32; 3],
    /// Per-lane Ledger `load` charge: 1 Work + kept dependency items on that lane.
    pub(crate) lane_load: [u32; 3],
    /// Queue-wide Ledger `owned` charge: 1 Work + total kept dependency items.
    pub(crate) queue_owned: u32,
}

impl FlightCharge {
    /// Exact charge for a render Work (TA + 3D). Matches `Ledger::add()`:
    /// preludes (`InitBM`, fragment prelude) consume ring entries only.
    #[inline]
    pub(crate) const fn render(initbm: bool, ta_deps: u32, frag_deps: u32) -> Self {
        Self {
            ring_entries: [1 + initbm as u32 + ta_deps, 2 + frag_deps, 0],
            lane_load: [1 + ta_deps, 1 + frag_deps, 0],
            queue_owned: 1 + ta_deps + frag_deps,
        }
    }

    /// Exact charge for a compute Work (CDM). Matches `Ledger::add()`.
    #[inline]
    pub(crate) const fn compute(cdm_deps: u32) -> Self {
        Self {
            ring_entries: [0, 0, 1 + cdm_deps],
            lane_load: [0, 0, 1 + cdm_deps],
            queue_owned: 1 + cdm_deps,
        }
    }
}

/// Reason a command cannot pass the capacity check.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum HeadroomBlock {
    /// Work alias window exhausted with nothing in flight (permanent ENOSPC).
    WorkSpaceExhausted,
    /// Work alias window full while flights are in flight (pressure bit 64).
    WorkSpaceBusy,
    /// Global flight or ledger capacity full (pressure bit 128).
    FlightsFull,
    /// Non-empty queue's owned entries + command charge > QUEUE_CAP (bit 16).
    QueueCap,
    /// Target stage lane has >= max_lane_works unretired flights (bit 16).
    LaneWorks,
    /// Non-empty target stage lane's load + lane charge > LANE_CAP (bit 32).
    LaneCap,
}

/// Check unconditional lower-bound headroom for one render or compute command
/// (minimum `queue_owned = 1` and minimum `lane_load = 1` on each target stage,
/// matching `Ledger::add()`).
///
/// An empty queue (`outstanding == 0`) or empty target lane (`load == 0`) is
/// never cap-blocked, guaranteeing forward progress under tight caps such as
/// `queue_cap = 1` or `lane_cap = 1` instead of stalling until timeout.
#[allow(clippy::too_many_arguments)]
pub(crate) fn check_headroom(
    render: bool,
    work_space_left: bool,
    flights_len: usize,
    max_flights: usize,
    ledger_has_room: bool,
    queue_cap: usize,
    max_lane_works: usize,
    lane_cap: usize,
    lanes: Option<[LaneLoad; 3]>,
) -> core::result::Result<(), HeadroomBlock> {
    if !work_space_left {
        return Err(if flights_len == 0 {
            HeadroomBlock::WorkSpaceExhausted
        } else {
            HeadroomBlock::WorkSpaceBusy
        });
    }
    if flights_len >= max_flights || !ledger_has_room {
        return Err(HeadroomBlock::FlightsFull);
    }
    let min_charge = if render {
        FlightCharge::render(false, 0, 0)
    } else {
        FlightCharge::compute(0)
    };
    check_exact_caps(render, min_charge, queue_cap, max_lane_works, lane_cap, lanes)
}

/// Check exact queue and per-lane capacity limits against `charge` using the
/// same units as `Ledger::add()`.
///
/// An empty queue (`outstanding == 0`) or empty target lane (`load == 0`)
/// always admits its first valid Work (at most 1 Work + 2 deps = 3 items, well
/// below the firmware's 128-Work window) so `queue_cap = 1` or `lane_cap = 1`
/// can never deadlock an idle queue into a 30 s device timeout.
pub(crate) fn check_exact_caps(
    render: bool,
    charge: FlightCharge,
    queue_cap: usize,
    max_lane_works: usize,
    lane_cap: usize,
    lanes: Option<[LaneLoad; 3]>,
) -> core::result::Result<(), HeadroomBlock> {
    let Some(lanes) = lanes else {
        return Ok(());
    };
    if queue_cap != 0 {
        let outstanding = lanes[0].owned + lanes[1].owned + lanes[2].owned;
        if outstanding > 0 && outstanding + charge.queue_owned as usize > queue_cap {
            return Err(HeadroomBlock::QueueCap);
        }
    }
    let stages: &[usize] = if render { &[0, 1] } else { &[2] };
    for &stage in stages {
        if max_lane_works != 0 && lanes[stage].works >= max_lane_works {
            return Err(HeadroomBlock::LaneWorks);
        }
        if lane_cap != 0 {
            let load = lanes[stage].load;
            if load > 0 && load + charge.lane_load[stage] as usize > lane_cap {
                return Err(HeadroomBlock::LaneCap);
            }
        }
    }
    Ok(())
}
