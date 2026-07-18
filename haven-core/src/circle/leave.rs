//! Leave-circle planning (pure decision logic).
//!
//! Separates the "what to do" decision from the "do it" side effects in
//! [`CircleManager::leave_circle`]. A [`LeavePlan`] is the complete description
//! of how a given user should exit a given MLS group — the manager reads the
//! plan and then executes the matching sequence of MDK commits and relay
//! publishes.
//!
//! # Why a dedicated planning step
//!
//! The admin-leave path has multiple failure modes (sole admin with members,
//! sole member, orphaned MDK state) that each require a different sequence of
//! protocol steps. Embedding that branching inside the execution path made the
//! previous implementation rely on MDK error-message string matching. Planning
//! first, executing second makes the branching explicit and unit-testable.
//!
//! # Privacy
//!
//! [`LeavePlan`]'s `Debug` impl redacts the successor's public key to a
//! short 8-char prefix (via [`short_id`]) so log lines cannot be used to
//! correlate a user to a specific handoff.

use std::collections::BTreeSet;

use nostr::PublicKey;

use super::error::{CircleError, Result};
use super::manager::short_id;
use crate::nostr::mls::types::GroupId;
use crate::nostr::mls::SessionManager;

/// Planned exit strategy for a single user leaving a single circle.
pub enum LeavePlan {
    /// Caller is a non-admin member — issue `leave_group` directly.
    NonAdmin,
    /// Caller is the sole admin and at least one non-self member exists —
    /// promote `successor`, self-demote, then `leave_group` (two-commit
    /// handoff per MIP-03).
    AdminHandoff {
        /// Deterministically chosen member to receive admin rights.
        successor: PublicKey,
    },
    /// Caller is one of multiple admins — skip the promotion step and go
    /// straight to self-demote + `leave_group`. Also the resume path after
    /// a successful promote whose demote failed.
    AdminDemote,
    /// Caller is the sole remaining member — no one to hand off to. The
    /// group is abandoned: local state is cleaned up with no relay commit.
    Abandon,
    /// MDK has no record of the group (failed finalization or DB reset).
    /// Delete the orphaned local row and surface a non-error to the caller.
    OrphanLocalOnly,
}

impl std::fmt::Debug for LeavePlan {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::NonAdmin => f.write_str("NonAdmin"),
            Self::AdminHandoff { successor } => f
                .debug_struct("AdminHandoff")
                .field("successor", &short_id(&successor.to_bytes()))
                .finish(),
            Self::AdminDemote => f.write_str("AdminDemote"),
            Self::Abandon => f.write_str("Abandon"),
            Self::OrphanLocalOnly => f.write_str("OrphanLocalOnly"),
        }
    }
}

/// Chooses the [`LeavePlan`] for `self_pubkey` leaving `group_id`.
///
/// Maps the engine's `SelfRemove` admin gating (`AdminCannotSelfRemove` /
/// `AdminDepletion`) onto Haven's leave state machine: an admin must first
/// exit the admin set (self-demote, handing off if they are the sole admin)
/// before the engine will accept their `SendIntent::Leave`.
///
/// # Errors
///
/// Returns [`CircleError::Mls`] if engine queries fail for reasons other than
/// "group not found" (which maps to [`LeavePlan::OrphanLocalOnly`]).
pub async fn plan_leave(
    session: &SessionManager,
    group_id: &GroupId,
    self_pubkey: &PublicKey,
) -> Result<LeavePlan> {
    // Unknown group ⇒ orphaned local row; nothing to leave on the wire.
    if session
        .find_group(group_id)
        .await
        .map_err(|e| CircleError::Mls(e.to_string()))?
        .is_none()
    {
        return Ok(LeavePlan::OrphanLocalOnly);
    }

    // Admins are raw x-only pubkey bytes (Rule 4: never the MLS group id).
    let self_bytes = self_pubkey.to_bytes();
    let admins = session
        .admin_pubkeys(group_id)
        .await
        .map_err(|e| CircleError::Mls(e.to_string()))?;

    if !admins.iter().any(|a| a == &self_bytes) {
        return Ok(LeavePlan::NonAdmin);
    }

    // Multiple admins — skip promotion and go straight to self-demote.
    // This is also the retry path when a prior handoff's promote succeeded
    // but demote failed: the successor is now an admin, so AdminDemote
    // resumes cleanly without re-promoting.
    if admins.len() > 1 {
        return Ok(LeavePlan::AdminDemote);
    }

    // Sole admin: pick a successor from the remaining roster (or Abandon if we
    // are the only member left).
    let members: BTreeSet<PublicKey> = session
        .member_pubkeys(group_id)
        .await
        .map_err(|e| CircleError::Mls(e.to_string()))?
        .iter()
        .filter_map(|hex| PublicKey::from_hex(hex).ok())
        .collect();

    Ok(
        select_successor(&members, self_pubkey).map_or(LeavePlan::Abandon, |successor| {
            LeavePlan::AdminHandoff { successor }
        }),
    )
}

/// Deterministically selects the lexicographically-smallest non-self member.
///
/// The leaving admin and every observer evaluating the same membership view
/// must agree on the same successor. Using the smallest byte-order pubkey
/// gives all nodes the same answer from public group state, so the resulting
/// handoff commit lands in the same epoch for everyone.
///
/// Observers that temporarily disagree on the member set (concurrent admin
/// leaves, a member add landing between two clients' fetch cycles) can still
/// propose different successors in the short term. MDK resolves that through
/// standard MLS commit conflict handling — losing commits retry against the
/// new epoch — so the group is **eventually consistent** after one full
/// observe → commit → retry cycle, not divergence-free in the instant.
#[must_use]
pub fn select_successor(
    members: &BTreeSet<PublicKey>,
    self_pubkey: &PublicKey,
) -> Option<PublicKey> {
    members.iter().find(|m| *m != self_pubkey).copied()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sorted_pks(n: usize) -> Vec<PublicKey> {
        let mut keys: Vec<PublicKey> = (0..n)
            .map(|_| nostr::Keys::generate().public_key())
            .collect();
        keys.sort();
        keys
    }

    #[test]
    fn select_successor_picks_lex_smallest_non_self() {
        let keys = sorted_pks(3);
        let members: BTreeSet<_> = keys.iter().copied().collect();

        // Self is the middle member — expect the smallest member as successor.
        let successor = select_successor(&members, &keys[1]).expect("successor");
        assert_eq!(successor, keys[0]);
    }

    #[test]
    fn select_successor_excludes_self_even_if_lex_smallest() {
        let keys = sorted_pks(3);
        let members: BTreeSet<_> = keys.iter().copied().collect();

        // Self is the smallest member — expect the next one up.
        let successor = select_successor(&members, &keys[0]).expect("successor");
        assert_eq!(successor, keys[1]);
    }

    #[test]
    fn select_successor_returns_none_when_alone() {
        let self_key = nostr::Keys::generate().public_key();
        let mut members = BTreeSet::new();
        members.insert(self_key);
        assert!(select_successor(&members, &self_key).is_none());
    }

    #[test]
    fn select_successor_returns_none_for_empty_membership() {
        let self_key = nostr::Keys::generate().public_key();
        let members = BTreeSet::new();
        assert!(select_successor(&members, &self_key).is_none());
    }

    #[test]
    fn debug_impl_redacts_successor_pubkey() {
        let keys = sorted_pks(2);
        let plan = LeavePlan::AdminHandoff { successor: keys[0] };
        let debug_str = format!("{plan:?}");
        // Only the 8-char short id should appear.
        let full_hex = keys[0].to_hex();
        assert!(
            !debug_str.contains(&full_hex),
            "debug output leaked full pubkey: {debug_str}"
        );
        assert!(debug_str.contains("AdminHandoff"));
    }

    #[test]
    fn debug_impl_simple_variants() {
        assert_eq!(format!("{:?}", LeavePlan::NonAdmin), "NonAdmin");
        assert_eq!(format!("{:?}", LeavePlan::AdminDemote), "AdminDemote");
        assert_eq!(format!("{:?}", LeavePlan::Abandon), "Abandon");
        assert_eq!(
            format!("{:?}", LeavePlan::OrphanLocalOnly),
            "OrphanLocalOnly"
        );
    }
}
