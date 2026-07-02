//! Deterministic adopt-winner convergence for concurrent MLS commits.
//!
//! Haven forks the MLS group when two members, from a shared epoch N, each
//! stage their OWN commit and eagerly merge it on publish-success: they reach
//! divergent N+1 states and each then drops the other's sibling commit,
//! desyncing permanently. This module provides the pure pieces of the fix — the
//! outcome/intent types and the MIP-03 winner rule — used by
//! [`crate::circle::CircleManager::converge_commit`], which clears the loser's
//! pending commit and adopts the winner so both sides land on the SAME epoch
//! with the SAME exporter secret.
//!
//! The winner rule reads only relay-public commit fields, so it is identical on
//! every member and leaks no secret material.

use nostr::{Event, PublicKey};

/// Outcome of a convergence attempt over a staged commit.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CommitConvergence {
    /// Our commit won (or there was no competitor): our pending commit was
    /// merged and the epoch advanced.
    ///
    /// Publication: a pre-M3 eager caller publishes our commit on this result; an
    /// M6 settle-window caller has ALREADY published it during the window (see
    /// [`crate::circle::CircleManager::converge_commit`] "Publication ordering").
    Merged,
    /// A competitor won: our pending commit was cleared and the winner was
    /// adopted (we advanced onto the winner's branch).
    ///
    /// Publication: a pre-M3 eager caller must NOT publish ours. An M6
    /// settle-window caller already published ours during the window — harmless
    /// (a losing commit at the stale epoch is dropped by peers via MDK
    /// `WrongEpoch`); it must not RE-publish, and (if `intent_still_pending`)
    /// re-stages the unsatisfied membership change from the new epoch.
    AdoptedWinner {
        /// `true` when our original membership intent was NOT satisfied by the
        /// winner and should be re-staged (the caller bounds the retries).
        intent_still_pending: bool,
    },
    /// Neither merged nor cleanly adopted (a degenerate / mid-convergence
    /// case). Any pending commit was cleared so nothing dangles; the caller
    /// should re-fetch and retry. Never leaves a pending commit behind.
    RolledBack,
}

/// The membership goal a staged commit was trying to achieve.
///
/// Used to decide [`CommitConvergence::AdoptedWinner::intent_still_pending`]
/// from the post-adopt roster, so a loser whose change the winner did not also
/// make can re-stage it.
#[derive(Debug, Clone)]
pub enum CommitIntent {
    /// A self-update (or any non-membership commit); nothing to re-satisfy.
    None,
    /// Remove these members; still pending while any remain in the group.
    RemoveMembers(Vec<PublicKey>),
    /// Add these members; still pending while any are absent from the group.
    AddMembers(Vec<PublicKey>),
}

/// MIP-03 commit ordering key: `(created_at seconds, lowercase-hex event id)`.
///
/// Reads ONLY relay-public fields (never secret / leaf / exporter material) and
/// is byte-for-byte identical to MDK's `is_better_candidate`
/// (`epoch_snapshots.rs:297,323`), so the Haven-layer winner and any MDK
/// internal rollback resolution always pick the SAME commit. It is a plain
/// total order over public data — NOT timing-sensitive.
fn commit_order_key(event: &Event) -> (u64, String) {
    (event.created_at.as_secs(), event.id.to_hex())
}

/// Returns whether `our_commit` is the MIP-03 winner over itself plus
/// `competing` (minimum `created_at`, then lexicographically-minimum hex id).
///
/// Concurrent commits always have distinct event ids, so the order key is
/// unique and the `<=` comparison yields exactly one winner.
#[must_use]
pub fn our_commit_wins(our_commit: &Event, competing: &[Event]) -> bool {
    let ours = commit_order_key(our_commit);
    competing.iter().all(|c| ours <= commit_order_key(c))
}

/// Returns the MIP-03 winning commit among `competing`, or `None` if empty.
#[must_use]
pub fn winning_commit(competing: &[Event]) -> Option<&Event> {
    competing
        .iter()
        .min_by(|a, b| commit_order_key(a).cmp(&commit_order_key(b)))
}

#[cfg(test)]
mod tests {
    use super::*;
    use nostr::{EventBuilder, Keys, Kind, Timestamp};

    /// Builds a synthetic kind:445 commit with a controlled `created_at` and a
    /// real (random) event id, for exercising the public-field winner rule.
    fn commit_at(created_at_secs: u64) -> Event {
        EventBuilder::new(Kind::Custom(445), "")
            .custom_created_at(Timestamp::from(created_at_secs))
            .sign_with_keys(&Keys::generate())
            .expect("sign synthetic commit")
    }

    #[test]
    fn earlier_created_at_wins_from_both_sides() {
        let early = commit_at(1000);
        let late = commit_at(2000);

        assert!(our_commit_wins(&early, std::slice::from_ref(&late)));
        assert!(!our_commit_wins(&late, std::slice::from_ref(&early)));

        // The absolute winner is the same regardless of argument order.
        assert_eq!(
            winning_commit(&[early.clone(), late.clone()]).unwrap().id,
            early.id
        );
        assert_eq!(winning_commit(&[late, early.clone()]).unwrap().id, early.id);
    }

    #[test]
    fn equal_created_at_breaks_tie_on_min_hex_id_consistently() {
        // Same timestamp, distinct ids → lexicographically-minimum hex id wins,
        // and the winner is identical regardless of which side asks / arg order.
        let a = commit_at(1000);
        let b = commit_at(1000);
        let a_is_winner = a.id.to_hex() < b.id.to_hex();
        let expected_winner_id = if a_is_winner { a.id } else { b.id };

        if a_is_winner {
            assert!(our_commit_wins(&a, std::slice::from_ref(&b)));
            assert!(!our_commit_wins(&b, std::slice::from_ref(&a)));
        } else {
            assert!(our_commit_wins(&b, std::slice::from_ref(&a)));
            assert!(!our_commit_wins(&a, std::slice::from_ref(&b)));
        }
        assert_eq!(
            winning_commit(&[a.clone(), b.clone()]).unwrap().id,
            expected_winner_id
        );
        assert_eq!(winning_commit(&[b, a]).unwrap().id, expected_winner_id);
    }

    #[test]
    fn hex_id_ordering_matches_raw_byte_ordering() {
        // A 32-byte fixed-length lowercase-hex id sorts identically to its raw
        // bytes, so Haven's `id.to_hex()` winner matches MDK's resolution. Pin
        // it so a future variable-length / uppercase-hex change fails loudly.
        for _ in 0..64 {
            let a = commit_at(1000);
            let b = commit_at(1000);
            assert_eq!(
                a.id.to_hex().cmp(&b.id.to_hex()),
                a.id.as_bytes().cmp(b.id.as_bytes()),
                "hex id ordering must equal raw byte ordering"
            );
        }
    }

    #[test]
    fn no_competitor_means_we_win() {
        let only = commit_at(1000);
        assert!(our_commit_wins(&only, &[]));
        assert!(winning_commit(&[]).is_none());
    }
}
