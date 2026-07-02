//! The commit settle buffer: collects same-epoch competitor commits so the
//! consumer can run deterministic MIP-03 convergence instead of forking.
//!
//! # Why this exists
//!
//! When two members each stage their own commit from a shared epoch N, MLS
//! permits only one to win. Without deterministic resolution the two members
//! eagerly merge their own commit, reach divergent N+1 states, and fork. The
//! engine instead buffers each member's competing siblings (keyed by the public
//! `nostr_group_id` hex and the staged epoch) for the duration of a short settle
//! window, then feeds the collected competitors to
//! `CircleManager::converge_commit`, which picks the single MIP-03 winner and
//! adopts it on both sides.
//!
//! # Which incoming events become competitors (M3b/M6 wiring contract)
//!
//! **While a settle window is open (regime 2), the processor buffers EVERY
//! incoming `kind:445` for the circle RAW — it does NOT classify commit-vs-
//! location first.** This is deliberate (design Decision C): the inner MLS
//! content type is not visible without a destructive decrypt, and blind-applying
//! a commit to classify it is exactly the fork this buffer prevents. So a
//! same-epoch commit is routed here rather than blind-applied (never bypassing
//! the MIP-03 winner rule); the trade-off is that ordinary Location `kind:445`
//! events that arrive during the window also land here as candidates.
//!
//! Passing non-commit candidates through is **fork-safe**, not just tolerated:
//! `converge_commit` orders competitors purely by `(created_at, id)`, but a
//! Location that wins the order key cannot advance the MLS epoch, so the
//! post-adopt epoch-advance guard rolls our commit back cleanly (`RolledBack`,
//! epoch unchanged) — no divergent state. Proven by
//! `finalize::tests::converge_with_a_winning_non_commit_competitor_rolls_back_without_forking`.
//!
//! **Liveness caveat (M11 flag-flip gate):** because Haven is a location app,
//! Locations routinely arrive within the ~8s window. Once `liveSyncEnabled` is
//! turned ON, a steady Location stream during the window can repeatedly win the
//! order key and roll back a genuine membership commit; with the bounded ≤2
//! re-stage this surfaces to the user as a retryable "failed to add/remove
//! member" (never a fork). Before the flag flips ON, either classify buffered
//! `kind:445` as commit-vs-location before insertion (e.g. a publish-time tag)
//! or add a flag-on starvation-liveness test proving a membership commit is not
//! permanently starved. Tracked under the M11 rollout gate.
//!
//! The classifier ([`crate::nostr::mls::classify_mdk_error`]) exists for the
//! defensive `Err` cases (a sibling arriving after we advanced surfaces as
//! `Err(WrongEpoch, is_commit=true)`; our own re-delivered commit as
//! `Err(OwnCommitPending)` / `Err(CannotDecryptOwnMessage)`, which MDK absorbs)
//! — but regime-2 routing gates on "a settle window is open," NOT on the error
//! class, since a live sibling commit decrypts fine as `Ok(Commit)`.
//!
//! # Retention is order-independent (fork-safety)
//!
//! The per-window bound ([`MAX_SETTLE_COMMITS`]) retains the competitors with
//! the **smallest MIP-03 order key** `(created_at, id)`, *not* the most recent
//! arrivals. The winner is the global minimum order key, so — for both members
//! that **receive the winner within the window** — it is retained regardless of
//! arrival order and both pick the same winner. A FIFO bound could evict the
//! winner on one side only and re-introduce the fork, so it is deliberately not
//! used. Cross-member convergence under *partial / late* delivery (the winner
//! reaches one member after its window flushes) is not this buffer's job: it
//! falls to the lossless cursor replay + `converge_commit` adopt path.
//!
//! The buffer holds only relay-public commit JSON; it never holds an exporter
//! secret or plaintext (Security Rule 5).

use std::collections::HashMap;

use super::config::{MAX_SETTLE_COMMITS, SETTLE_WINDOW_TTL_SECS};

/// A single buffered competitor commit. Relay-public fields only.
///
/// `Debug` is hand-written to be presence-only (the full event JSON is never
/// rendered), keeping the module's redaction discipline uniform even though the
/// fields are relay-public.
#[derive(Clone, PartialEq, Eq)]
pub struct BufferedCommit {
    /// The raw kind:445 event JSON (re-parsed by the FFI helper before use).
    pub event_json: String,
    /// MIP-03 ordering: the event's `created_at` (seconds).
    pub created_at_secs: u64,
    /// MIP-03 tie-break: the event's lowercase-hex id.
    pub id_hex: String,
}

impl std::fmt::Debug for BufferedCommit {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("BufferedCommit")
            .field("created_at_secs", &self.created_at_secs)
            .field("id_hex", &self.id_hex)
            .field("event_json", &"<redacted>")
            .finish()
    }
}

impl BufferedCommit {
    /// The MIP-03 order key `(created_at, id)`; the minimum is the winner.
    const fn order_key(&self) -> (u64, &str) {
        (self.created_at_secs, self.id_hex.as_str())
    }
}

/// One open settle window for a single circle.
#[derive(Debug, Clone)]
struct SettleWindow {
    /// The epoch our own staged commit was built from. A competitor observed
    /// after the local epoch advances past this is irrelevant and dropped.
    staged_epoch: u64,
    /// Wall-clock deadline (unix ms) after which the window flushes.
    deadline_ms: i64,
    /// Retained competitors (bounded, order-key-minimal, deduped by id).
    competitors: Vec<BufferedCommit>,
}

/// Per-circle settle windows keyed by `hex(nostr_group_id)`.
#[derive(Debug, Default)]
pub struct CommitSettleBuffer {
    windows: HashMap<String, SettleWindow>,
}

impl CommitSettleBuffer {
    /// Creates an empty buffer.
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Opens (or replaces) the settle window for `group_id_hex`, returning any
    /// competitors that were buffered under a **prior** open window for the same
    /// circle.
    ///
    /// Called by the consumer right after it stages and publishes its own commit
    /// at `staged_epoch`; `deadline_ms` is when the window should flush. If a
    /// prior window was still open (the consumer re-staged without taking), its
    /// un-converged competitors are **returned, not silently dropped**, so the
    /// caller can run a final convergence on them rather than forking. An empty
    /// vec means there was no prior window (the common case).
    #[must_use]
    pub fn begin_window(
        &mut self,
        group_id_hex: &str,
        staged_epoch: u64,
        deadline_ms: i64,
    ) -> Vec<BufferedCommit> {
        self.windows
            .insert(
                group_id_hex.to_string(),
                SettleWindow {
                    staged_epoch,
                    deadline_ms,
                    competitors: Vec::new(),
                },
            )
            .map(|w| w.competitors)
            .unwrap_or_default()
    }

    /// Buffers a competitor commit for `group_id_hex`, if a relevant window is
    /// open.
    ///
    /// Returns `true` if it was retained. A competitor is **ignored** when:
    /// - no window is open for the circle (the slower adopt path handles it), or
    /// - `observed_local_epoch` has advanced past the window's staged epoch (we
    ///   already moved on), or
    /// - it duplicates an already-retained commit id.
    ///
    /// When retention would exceed [`MAX_SETTLE_COMMITS`], the competitor with
    /// the **largest** order key is evicted, so the retained set is the
    /// order-key-minimal subset (see the module docs).
    pub fn insert_competitor(
        &mut self,
        group_id_hex: &str,
        commit: BufferedCommit,
        observed_local_epoch: u64,
    ) -> bool {
        let Some(window) = self.windows.get_mut(group_id_hex) else {
            return false;
        };
        if observed_local_epoch > window.staged_epoch {
            return false;
        }
        if window.competitors.iter().any(|c| c.id_hex == commit.id_hex) {
            return false;
        }

        window.competitors.push(commit);

        if window.competitors.len() > MAX_SETTLE_COMMITS {
            // Evict the worst (largest order key); keep the minimal subset. The
            // winner (global minimum) can never be the evicted maximum.
            if let Some((worst_idx, _)) = window
                .competitors
                .iter()
                .enumerate()
                .max_by(|(_, a), (_, b)| a.order_key().cmp(&b.order_key()))
            {
                window.competitors.swap_remove(worst_idx);
            }
        }
        true
    }

    /// Removes and returns the competitors for `group_id_hex`, but only if the
    /// open window matches `staged_epoch`.
    ///
    /// A mismatch (or no window) returns an empty vec and leaves any
    /// non-matching window in place; the consumer always takes with the epoch it
    /// opened the window with.
    pub fn take_competitors(
        &mut self,
        group_id_hex: &str,
        staged_epoch: u64,
    ) -> Vec<BufferedCommit> {
        match self.windows.get(group_id_hex) {
            Some(w) if w.staged_epoch == staged_epoch => self
                .windows
                .remove(group_id_hex)
                .map(|w| w.competitors)
                .unwrap_or_default(),
            _ => Vec::new(),
        }
    }

    /// Drops the window for `group_id_hex` entirely (e.g. on leave/unsubscribe).
    pub fn close_window(&mut self, group_id_hex: &str) {
        self.windows.remove(group_id_hex);
    }

    /// Removes windows whose deadline (plus [`SETTLE_WINDOW_TTL_SECS`] grace)
    /// has passed, returning the `(group_id_hex, staged_epoch)` of each pruned
    /// window so the caller can run a final convergence on it.
    ///
    /// TODO(M8): this has NO running caller yet (unit-test only). When the M8
    /// maintenance cadence wires it, the caller MUST `clear_pending_commit` for
    /// each pruned window (needs a `nostr_group_id → mls_group_id` lookup) — a
    /// pruned path-B window otherwise wedges the member in regime 2. Until then
    /// the `WindowCloseGuard` covers path-B in-process; the path-A
    /// foreground-crash window is the only residual (self-heals on next
    /// delivery). Tracked in the WN migration ledger under M8.
    pub fn prune_expired(&mut self, now_ms: i64) -> Vec<(String, u64)> {
        let grace_ms = SETTLE_WINDOW_TTL_SECS.saturating_mul(1000);
        let mut pruned = Vec::new();
        self.windows.retain(|group_id_hex, window| {
            if now_ms.saturating_sub(window.deadline_ms) > grace_ms {
                pruned.push((group_id_hex.clone(), window.staged_epoch));
                false
            } else {
                true
            }
        });
        pruned
    }

    /// Returns the deadline of `group_id_hex`'s open window, if any.
    #[must_use]
    pub fn window_deadline(&self, group_id_hex: &str) -> Option<i64> {
        self.windows.get(group_id_hex).map(|w| w.deadline_ms)
    }

    /// Whether a window is open for `group_id_hex`.
    #[must_use]
    pub fn has_window(&self, group_id_hex: &str) -> bool {
        self.windows.contains_key(group_id_hex)
    }

    /// The staged epoch of `group_id_hex`'s open window, if any.
    ///
    /// The engine processor uses this both as the regime-2 signal (a window is
    /// open ⇒ buffer raw, do not decrypt) and as the `observed_local_epoch` for
    /// [`Self::insert_competitor`] (during a window no merge occurs, so the local
    /// epoch equals the staged epoch).
    #[must_use]
    pub fn window_staged_epoch(&self, group_id_hex: &str) -> Option<u64> {
        self.windows.get(group_id_hex).map(|w| w.staged_epoch)
    }

    /// Number of competitors currently retained for `group_id_hex`.
    #[must_use]
    pub fn competitor_count(&self, group_id_hex: &str) -> usize {
        self.windows
            .get(group_id_hex)
            .map_or(0, |w| w.competitors.len())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const G: &str = "aa00"; // a stand-in hex(nostr_group_id)
    const EPOCH: u64 = 5;

    fn commit(created_at: u64, id: &str) -> BufferedCommit {
        BufferedCommit {
            event_json: format!("{{\"id\":\"{id}\"}}"),
            created_at_secs: created_at,
            id_hex: id.to_string(),
        }
    }

    /// Opens a fresh window and asserts nothing was displaced (the common case);
    /// pins that a first `begin_window` never reports phantom competitors.
    fn open(buf: &mut CommitSettleBuffer, group: &str, epoch: u64, deadline: i64) {
        assert!(buf.begin_window(group, epoch, deadline).is_empty());
    }

    #[test]
    fn no_window_means_competitor_is_ignored() {
        let mut buf = CommitSettleBuffer::new();
        assert!(!buf.insert_competitor(G, commit(100, "0a"), EPOCH));
        assert_eq!(buf.competitor_count(G), 0);
    }

    #[test]
    fn buffers_competitors_under_open_window_keyed_by_group_and_epoch() {
        let mut buf = CommitSettleBuffer::new();
        open(&mut buf, G, EPOCH, 1_000);
        assert!(buf.insert_competitor(G, commit(100, "0a"), EPOCH));
        assert!(buf.insert_competitor(G, commit(101, "0b"), EPOCH));
        assert_eq!(buf.competitor_count(G), 2);

        let taken = buf.take_competitors(G, EPOCH);
        assert_eq!(taken.len(), 2);
        // Window consumed.
        assert!(!buf.has_window(G));
    }

    #[test]
    fn take_with_wrong_epoch_returns_empty_and_keeps_window() {
        let mut buf = CommitSettleBuffer::new();
        open(&mut buf, G, EPOCH, 1_000);
        buf.insert_competitor(G, commit(100, "0a"), EPOCH);

        assert!(buf.take_competitors(G, EPOCH + 1).is_empty());
        assert!(buf.has_window(G), "non-matching take must not consume");
        assert_eq!(buf.take_competitors(G, EPOCH).len(), 1);
    }

    #[test]
    fn dedupes_competitor_by_id() {
        let mut buf = CommitSettleBuffer::new();
        open(&mut buf, G, EPOCH, 1_000);
        assert!(buf.insert_competitor(G, commit(100, "0a"), EPOCH));
        assert!(!buf.insert_competitor(G, commit(100, "0a"), EPOCH));
        assert_eq!(buf.competitor_count(G), 1);
    }

    #[test]
    fn drops_competitor_observed_after_local_epoch_advance() {
        let mut buf = CommitSettleBuffer::new();
        open(&mut buf, G, EPOCH, 1_000);
        // Local epoch already advanced past the staged epoch → irrelevant.
        assert!(!buf.insert_competitor(G, commit(100, "0a"), EPOCH + 1));
        assert_eq!(buf.competitor_count(G), 0);
    }

    #[test]
    fn bound_retains_order_key_minimal_subset_not_fifo() {
        let mut buf = CommitSettleBuffer::new();
        open(&mut buf, G, EPOCH, 1_000);
        // Insert MAX+ commits in DESCENDING created_at (worst first), so a FIFO
        // bound would evict the EARLIEST (the winner). Order-key retention must
        // instead keep the smallest created_at.
        let total = MAX_SETTLE_COMMITS + 4;
        for i in 0..total {
            let created_at = u64::try_from(total - i).unwrap(); // descending
            let id = format!("{i:04x}");
            buf.insert_competitor(G, commit(created_at, &id), EPOCH);
        }
        assert_eq!(buf.competitor_count(G), MAX_SETTLE_COMMITS);

        let taken = buf.take_competitors(G, EPOCH);
        let min_created = taken.iter().map(|c| c.created_at_secs).min().unwrap();
        // The global-minimum created_at (== 1) must survive eviction.
        assert_eq!(min_created, 1, "winner (min order key) must be retained");
        // And the evicted ones are the largest created_at values.
        let max_created = taken.iter().map(|c| c.created_at_secs).max().unwrap();
        assert!(
            max_created <= u64::try_from(MAX_SETTLE_COMMITS).unwrap(),
            "the largest order keys were evicted, not the smallest"
        );
    }

    #[test]
    fn global_min_winner_survives_flood_in_any_arrival_order() {
        // Fork-safety corollary: two members converge iff both retain the
        // global-minimum order-key commit (the MIP-03 winner). Prove it survives
        // a flood whether it arrives FIRST, LAST, or in the MIDDLE — the only
        // way two members could diverge is if order-dependent eviction dropped
        // the winner on one side.
        let total = MAX_SETTLE_COMMITS + 8;
        let winner = commit(1, "0000"); // smallest created_at AND smallest id

        for winner_pos in [0usize, total / 2, total - 1] {
            let mut buf = CommitSettleBuffer::new();
            open(&mut buf, G, EPOCH, 1_000);
            for inserted in 0..total {
                if inserted == winner_pos {
                    buf.insert_competitor(G, winner.clone(), EPOCH);
                } else {
                    // Strictly-larger order keys (created_at >= 2).
                    let id = format!("{:04x}", inserted + 16);
                    let created_at = u64::try_from(inserted).unwrap() + 2;
                    buf.insert_competitor(G, commit(created_at, &id), EPOCH);
                }
            }
            assert_eq!(buf.competitor_count(G), MAX_SETTLE_COMMITS);
            let taken = buf.take_competitors(G, EPOCH);
            assert!(
                taken.contains(&winner),
                "winner inserted at position {winner_pos} must survive the flood"
            );
        }
    }

    #[test]
    fn prune_expired_removes_past_deadline_windows_and_reports_them() {
        let mut buf = CommitSettleBuffer::new();
        let deadline = 1_000_i64;
        open(&mut buf, G, EPOCH, deadline);
        let grace_ms = SETTLE_WINDOW_TTL_SECS * 1000;

        // Just inside grace → not pruned.
        assert!(buf.prune_expired(deadline + grace_ms).is_empty());
        assert!(buf.has_window(G));

        // Past grace → pruned and reported.
        let pruned = buf.prune_expired(deadline + grace_ms + 1);
        assert_eq!(pruned, vec![(G.to_string(), EPOCH)]);
        assert!(!buf.has_window(G));
    }

    #[test]
    fn close_window_purges() {
        let mut buf = CommitSettleBuffer::new();
        open(&mut buf, G, EPOCH, 1_000);
        buf.insert_competitor(G, commit(1, "0a"), EPOCH);
        buf.close_window(G);
        assert!(!buf.has_window(G));
        assert_eq!(buf.competitor_count(G), 0);
    }

    #[test]
    fn never_buffers_across_groups() {
        let mut buf = CommitSettleBuffer::new();
        open(&mut buf, G, EPOCH, 1_000);
        // A different group has no window → ignored.
        assert!(!buf.insert_competitor("bb11", commit(1, "0a"), EPOCH));
        assert_eq!(buf.competitor_count("bb11"), 0);
    }

    #[test]
    fn reopening_window_returns_prior_competitors_and_clears_them() {
        // begin_window must NOT silently drop an open window's un-converged
        // competitors (a silent drop would degrade convergence → fork). It
        // returns them so the caller can converge them, and the new window
        // starts empty.
        let mut buf = CommitSettleBuffer::new();
        open(&mut buf, G, EPOCH, 1_000);
        buf.insert_competitor(G, commit(100, "0a"), EPOCH);
        buf.insert_competitor(G, commit(101, "0b"), EPOCH);

        // Re-stage at the next epoch without taking → prior competitors surface.
        let displaced = buf.begin_window(G, EPOCH + 1, 2_000);
        assert_eq!(
            displaced.len(),
            2,
            "prior competitors must be returned, not dropped"
        );

        // The new window starts empty and at the new epoch.
        assert_eq!(buf.competitor_count(G), 0);
        assert_eq!(buf.window_deadline(G), Some(2_000));
        assert!(
            buf.take_competitors(G, EPOCH).is_empty(),
            "old epoch is gone"
        );
    }

    #[test]
    fn window_deadline_reports_open_window_and_none_otherwise() {
        let mut buf = CommitSettleBuffer::new();
        assert_eq!(buf.window_deadline(G), None);
        open(&mut buf, G, EPOCH, 5_000);
        assert_eq!(buf.window_deadline(G), Some(5_000));
        assert_eq!(buf.window_deadline("other"), None);
    }

    #[test]
    fn prune_expired_removes_only_the_expired_window_among_several() {
        let mut buf = CommitSettleBuffer::new();
        let grace_ms = SETTLE_WINDOW_TTL_SECS.saturating_mul(1000);
        open(&mut buf, "g_expired", EPOCH, 1_000);
        open(&mut buf, "g_live", EPOCH, 1_000_000);

        // Past grace for g_expired but not for g_live.
        let pruned = buf.prune_expired(1_000 + grace_ms + 1);
        assert_eq!(pruned, vec![("g_expired".to_string(), EPOCH)]);
        assert!(!buf.has_window("g_expired"));
        assert!(buf.has_window("g_live"), "the live window must survive");
    }

    #[test]
    fn prune_before_deadline_keeps_all_windows() {
        let mut buf = CommitSettleBuffer::new();
        open(&mut buf, G, EPOCH, 10_000);
        assert!(buf.prune_expired(5_000).is_empty());
        assert!(buf.has_window(G));
    }
}
