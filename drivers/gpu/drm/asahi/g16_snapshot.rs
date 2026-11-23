// SPDX-License-Identifier: GPL-2.0-only
// Copyright The Gravity Linux Contributors

//! Fixed-capacity snapshot of firmware words read once per retirement scan.
//!
//! Pure table logic, host-tested.

/// Firmware words read once per retirement scan (per-lane stamps and ring
/// cursors are shared by every flight on the lane). Fixed-size with no
/// allocation per scan; addresses beyond capacity fall back to direct reads
/// without evicting earlier entries.
#[derive(Clone)]
pub(crate) struct WordSnapshot<const N: usize> {
    words: [(u64, u32); N],
    len: usize,
}

impl<const N: usize> Default for WordSnapshot<N> {
    fn default() -> Self {
        Self {
            words: [(0, 0); N],
            len: 0,
        }
    }
}

impl<const N: usize> WordSnapshot<N> {
    /// Reset the snapshot for a new scan.
    pub(crate) fn clear(&mut self) {
        self.len = 0;
    }

    /// Return the cached value for `address`, or read it once via `read` and
    /// cache it if room remains.
    pub(crate) fn read_with<E>(
        &mut self,
        address: u64,
        read: impl FnOnce(u64) -> Result<u32, E>,
    ) -> Result<u32, E> {
        if let Some(&(_, value)) = self.words[..self.len].iter().find(|(a, _)| *a == address) {
            return Ok(value);
        }
        let value = read(address)?;
        if self.len < N {
            self.words[self.len] = (address, value);
            self.len += 1;
        }
        Ok(value)
    }

    /// A value seen by this snapshot, without reading.
    pub(crate) fn peek(&self, address: u64) -> Option<u32> {
        self.words[..self.len]
            .iter()
            .find(|(a, _)| *a == address)
            .map(|&(_, v)| v)
    }

    /// Remove a cached address (used when recycled queue storage resets its
    /// lane firmware stamps).
    pub(crate) fn forget(&mut self, address: u64) {
        if let Some(pos) = self.words[..self.len]
            .iter()
            .position(|(a, _)| *a == address)
        {
            self.len -= 1;
            self.words[pos] = self.words[self.len];
        }
    }
}
