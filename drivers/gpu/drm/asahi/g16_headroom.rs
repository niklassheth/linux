// SPDX-License-Identifier: GPL-2.0-only
// Copyright The Gravity Linux Contributors

//! Fast O(1) admission headroom pre-check for G16 queues and lanes.
//!
//! Pure policy logic, host-tested. Evaluates only unconditional lower-bound
//! capacity limits that cannot clear until a flight retires (`retire_gen`
//! advances) or a runtime cap knob (`queue_cap`, `lane_cap`) changes.

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

/// Per-lane counters copied from `Ledger::lane` for a queue's three lanes.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(crate) struct LaneLoad {
    pub(crate) works: usize,
    pub(crate) load: usize,
    pub(crate) owned: usize,
}

/// Reason a command cannot pass the lower-bound capacity check.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum HeadroomBlock {
    /// Work alias window exhausted with nothing in flight (permanent ENOSPC).
    WorkSpaceExhausted,
    /// Work alias window full while flights are in flight (pressure bit 64).
    WorkSpaceBusy,
    /// Global flight or ledger capacity full (pressure bit 128).
    FlightsFull,
    /// Queue's total owned entries + minimum command entries > QUEUE_CAP (bit 16).
    QueueCap,
    /// Target stage lane has >= max_lane_works unretired flights (bit 16).
    LaneWorks,
    /// Target stage lane's load + 1 > LANE_CAP (bit 32).
    LaneCap,
}

/// Check unconditional lower-bound headroom for one render (`render = true`,
/// minimum 2 queue entries across TA+3D and 1 entry per active stage) or
/// compute (`render = false`, minimum 1 queue entry and 1 entry on stage 2).
///
/// Returns `Ok(())` when the command may proceed to full preparation and exact
/// dependency-aware `reserve_flight()`, or `Err(HeadroomBlock)` when admission
/// is guaranteed to fail regardless of dependency elision or `initbm`.
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
    if let Some(lanes) = lanes {
        if queue_cap != 0 {
            let outstanding = lanes[0].owned + lanes[1].owned + lanes[2].owned;
            let min_new = if render { 2 } else { 1 };
            if outstanding + min_new > queue_cap {
                return Err(HeadroomBlock::QueueCap);
            }
        }
        let stages: &[usize] = if render { &[0, 1] } else { &[2] };
        for &stage in stages {
            if max_lane_works != 0 && lanes[stage].works >= max_lane_works {
                return Err(HeadroomBlock::LaneWorks);
            }
            if lane_cap != 0 && lanes[stage].load + 1 > lane_cap {
                return Err(HeadroomBlock::LaneCap);
            }
        }
    }
    Ok(())
}
