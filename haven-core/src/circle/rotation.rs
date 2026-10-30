//! Gates for the epoch-rotation REPAIR (`docs/EPOCH_ROTATION_REPAIR_PLAN.md`).
//!
//! # What this repairs
//!
//! `OpenMLS` caps how far a decryption ratchet may be wound forward
//! (`SenderRatchetConfiguration::maximum_forward_distance`, default 1000, which
//! MDK does not override; `docs/MDK_UPSTREAM_TRACKER.md` T-FORWARD-DISTANCE). A
//! member that has missed more than that many consecutive application messages
//! from one peer gets `SecretTreeError::TooDistantInTheFuture` for every later
//! message from that peer — permanently, because a ratchet cannot be rewound.
//!
//! The repair is a real self-update (`SendIntent::SelfUpdate`): a commit with
//! an `UpdatePath` that rotates this device's leaf key. That gives
//! post-compromise security for the leaf, and the new epoch's fresh
//! `encryption_secret` restarts every sender ratchet in the group at
//! generation 0. A self-update needs no admin (`protocol-core/group-setup.md`
//! 92), so any member may make it.
//!
//! # Why the decision is a pure function
//!
//! Every gate is a comparison over values read at one instant. Two members
//! that repair at the same epoch both commit; the engine's convergence picks
//! one branch and every replica lands on it (`protocol-core/convergence.md`
//! 355-362), so the gates bound how often a circle is repaired, not who may.

/// Minimum age of the group's last observed epoch change before a repair
/// rotation is allowed (gate 3).
///
/// An epoch change resets every sender ratchet in the group, so a circle whose
/// epoch moved recently cannot be far into exhausting one. The fastest a peer
/// can burn the 1000-generation budget is ~20 h — 50 publishes/hour, the
/// ceiling implied by the 72 s floor of the publish-cadence jitter
/// (`location::ttl`) — so nothing inside this window is close enough to
/// exhaustion for a commit to be worth its relay traffic and its fork risk.
/// Rounding the window up to a day rather than down to the 20 h floor costs at
/// most a few hours on the very worst cadence and buys a bound a human can
/// reason about.
pub const ROTATION_MIN_EPOCH_AGE_SECS: u64 = 24 * 60 * 60;

/// Minimum interval between two confirmed repair rotations of one circle
/// (gate 6).
///
/// A confirmed rotation IS an epoch change, so [`ROTATION_MIN_EPOCH_AGE_SECS`]
/// already rate-limits the happy path; this gate is what still holds when the
/// epoch-change observation is missing (a circle repaired on another device, a
/// storage row lost). Same window, so the two can never disagree about how
/// often a circle may be repaired.
pub const ROTATION_MIN_INTERVAL_SECS: u64 = 24 * 60 * 60;

/// How long a circle must have been free of inbound group traffic before a
/// repair rotation may commit (gate 4, the time half).
///
/// # What this window actually is: a cheap liveness filter
///
/// It is anchored to "when did we last hear ANYTHING authenticated from this
/// circle", not to any proposal, so it cannot be described as a delivery-skew
/// bound on a specific message: a proposal that never reached this device is
/// closed by nothing in this half, however long the window is. What it buys is
/// cheaper and honest — it keeps the repair off a circle that is visibly busy
/// right now, which is when a concurrent commit is most likely and when the
/// user is least likely to need a repair at all.
///
/// # What actually closes the same-epoch race
///
/// 1. **Every proposal this device ingested** is closed by the EXACT half,
///    [`RotationInputs::pending_proposal`] — a durable, restart-proof storage
///    read that keeps declining until the departure commits. It matters for
///    privacy, not only for races: the self-update takes in no stored
///    proposal, so a repair that won the epoch over a pending `SelfRemove`
///    would leave the leaver reading for one more epoch.
/// 2. **A commit another member makes at the same epoch** is resolved by the
///    engine's convergence. The self-update is `Ordinary`, so a tied
///    privileged commit — an admin's removal or invite — wins over it, and
///    between two ordinary commits the lower committer wins
///    (`protocol-core/convergence.md` 358-362). Whichever commit wins is itself
///    an epoch change, which resets every sender ratchet, so the repair's
///    purpose is met either way.
///
/// **Residual: one extra epoch, never a fork.** When the repair loses, its
/// 24-hour rate limit was nonetheless spent (the charge happens at the fanout
/// driver's confirm, before any branch selection can be known), so that
/// circle waits a day for its next repair. Not charging would let a losing
/// commit be retried in a loop.
///
/// So this half is a cheap filter in front of an engine guarantee, which is
/// why it is sized for cheapness rather than for coverage.
///
/// # Why it MUST stay below the publish-cadence floor
///
/// Sizing it like a cadence (a peer's worst-case inter-publish gap) would make
/// the repair unreachable on exactly the circles it exists to fix: a peer whose
/// messages this device can no longer decrypt is still publishing every
/// [`MIN_UPDATE_INTERVAL_SECS`]-or-so seconds, so a window at or above that
/// floor is re-armed before it can ever expire. The gate would then be
/// permanently CLOSED — the mirror image of the defect where it is permanently
/// open. `quiescence_window_cannot_be_held_shut_by_a_live_peer` pins the
/// relation; do not raise this above that floor.
///
/// # The window is per-CIRCLE, but the traffic is per-PEER
///
/// The stamp advances on any peer's authenticated event, and Haven publishes
/// each circle on an INDEPENDENT jittered schedule per member (the
/// decorrelation from `location/ttl.rs`). So the probability that a circle is
/// quiet for `ROTATION_QUIESCENCE_SECS` falls off with the number of live peers:
/// with N peers each publishing every 72-168 s, the expected quiet window
/// shrinks roughly as 1/N, and around **N >= 4** this gate becomes hard to open
/// at all. That is a known ceiling on the repair's reach in larger circles, not
/// a bug — a circle with four live, decryptable peers is not the C4 case — but
/// it is the reason it is sized as small as it is.
pub const ROTATION_QUIESCENCE_SECS: u64 = 30;

/// Why a repair rotation was declined.
///
/// Fieldless by construction: a skip is surfaced to the UI and to logs, and no
/// variant may carry a group id, a pubkey or an epoch (Security Rules 4/6/8).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SkipReason {
    /// The engine's epoch state for this group is not `Stable` but is expected
    /// to become so on its own — a commit is staged, merging, or recovering
    /// (gate 2). Retryable: the caller may offer the repair again shortly.
    EpochNotStable,
    /// The engine has frozen this group at its last stable epoch and refuses to
    /// apply or ingest further group state (MDK's persisted `unrecoverable`).
    /// The one terminal reason.
    ///
    /// Deliberately NOT folded into [`Self::EpochNotStable`]: this one never
    /// clears by waiting, so surfacing it as "try again shortly" would put the
    /// user in a retry loop that cannot succeed. The exit is being added to
    /// the circle again, which MDK's rejoin repairs in place.
    EpochUnrecoverable,
    /// The group's epoch changed too recently for a ratchet to be exhausted
    /// (gate 3).
    RecentEpochChange,
    /// The circle produced an MLS-authenticated inbound group event too recently
    /// to rule out a peer committing at the same epoch (gate 4, time half).
    RecentInboundTraffic,
    /// A stored proposal is still waiting for a commit, so a remaining member
    /// may auto-commit it at any moment (gate 4, exact half).
    PendingProposal,
    /// This circle was already repaired inside the rate limit (gate 6).
    RotatedRecently,
}

/// The verdict of [`rotation_decision`].
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RotationDecision {
    /// Author the self-update.
    Rotate,
    /// Do nothing, for this reason.
    Skip(SkipReason),
}

/// Everything the gates read, gathered at one instant.
///
/// A struct rather than eight positional arguments so the call site names each
/// value, and so a later gate cannot be added by silently widening a tuple.
#[derive(Clone, Copy, Debug)]
pub struct RotationInputs {
    /// Whether the engine holds this group `unrecoverable`.
    ///
    /// The one non-`Stable` state the decision itself weighs; the transient
    /// ones (`PendingPublish` / `Merging` / `Recovering`) are refused by the
    /// send, read through MDK's `epoch_state` getter under the send's own lock
    /// (`SessionManager::repair_self_update_staging`). See
    /// `docs/EPOCH_ROTATION_REPAIR_PLAN.md` §4 gate 2 and §6.
    pub group_is_unrecoverable: bool,
    /// Unix seconds of the last epoch change observed for this circle, or
    /// `None` if none has been observed since the row was created.
    pub last_epoch_change_at: Option<u64>,
    /// Unix seconds of the last CONFIRMED repair rotation of this circle.
    pub last_rotation_at: Option<u64>,
    /// Unix seconds of the last MLS-AUTHENTICATED inbound group event for this
    /// circle (`CircleStorage::note_inbound_group_event`). Never a 445 the
    /// pre-auth screen rejected or the engine failed on — both are mintable by
    /// any observer of the circle's public `#h`, and either would hand that
    /// observer a way to hold this gate shut.
    pub last_inbound_event_at: Option<u64>,
    /// Whether a stored proposal for this circle is still awaiting a commit.
    pub pending_proposal: bool,
    /// Now, in Unix seconds.
    pub now: u64,
}

/// Decides whether this device may author a repair for one circle.
///
/// Gates are evaluated in the order they are numbered in
/// `docs/EPOCH_ROTATION_REPAIR_PLAN.md` §4, so the reported reason is the first
/// one that fails rather than an arbitrary one. There is no gate 1: a
/// self-update needs no admin.
#[must_use]
pub const fn rotation_decision(inputs: &RotationInputs) -> RotationDecision {
    // Gate 2 — the engine will accept a staged commit. Only the terminal state
    // is observable before the send; the transient ones surface as a typed
    // rejection of the self-update.
    if inputs.group_is_unrecoverable {
        return RotationDecision::Skip(SkipReason::EpochUnrecoverable);
    }
    // Gate 3 — the epoch has been still long enough for exhaustion to be
    // possible at all.
    if within(
        inputs.last_epoch_change_at,
        inputs.now,
        ROTATION_MIN_EPOCH_AGE_SECS,
    ) {
        return RotationDecision::Skip(SkipReason::RecentEpochChange);
    }
    // Gate 4 — nobody else is about to commit.
    if within(
        inputs.last_inbound_event_at,
        inputs.now,
        ROTATION_QUIESCENCE_SECS,
    ) {
        return RotationDecision::Skip(SkipReason::RecentInboundTraffic);
    }
    if inputs.pending_proposal {
        return RotationDecision::Skip(SkipReason::PendingProposal);
    }
    // Gate 6 — one repair per circle per window.
    if within(
        inputs.last_rotation_at,
        inputs.now,
        ROTATION_MIN_INTERVAL_SECS,
    ) {
        return RotationDecision::Skip(SkipReason::RotatedRecently);
    }
    RotationDecision::Rotate
}

/// Whether `at` is a real observation that lies within `window` seconds of
/// `now`.
///
/// `None` — never observed — is NOT "within the window": a circle that has never
/// seen an epoch change, never heard a peer, or never been repaired must not be
/// blocked forever by the absence of a timestamp.
///
/// A timestamp in the FUTURE counts as within the window. That is the fail-safe
/// direction: a clock that jumped backwards (or a peer stamp copied from a fast
/// clock) would otherwise read as "ancient" and license a rotation on evidence
/// the device does not have.
const fn within(at: Option<u64>, now: u64, window: u64) -> bool {
    match at {
        None => false,
        Some(at) if at >= now => true,
        Some(at) => now - at < window,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::location::ttl::MIN_UPDATE_INTERVAL_SECS;

    /// Day 20 000 (2024-10-04) in Unix seconds. Every clock in these tests is an
    /// explicit value, so a gate boundary lands on an exact second rather than
    /// on whatever the wall clock happened to be.
    const NOW: u64 = 20_000 * 86_400;

    /// Inputs with every gate open, so a test that flips ONE field is testing
    /// that field.
    const fn passing() -> RotationInputs {
        RotationInputs {
            group_is_unrecoverable: false,
            last_epoch_change_at: Some(NOW - ROTATION_MIN_EPOCH_AGE_SECS),
            last_rotation_at: Some(NOW - ROTATION_MIN_INTERVAL_SECS),
            last_inbound_event_at: Some(NOW - ROTATION_QUIESCENCE_SECS),
            pending_proposal: false,
            now: NOW,
        }
    }

    #[test]
    fn any_member_rotates_when_every_gate_is_open() {
        // No input names the caller or the circle's admins: a self-update
        // needs no admin (`protocol-core/group-setup.md` 92).
        assert_eq!(rotation_decision(&passing()), RotationDecision::Rotate);
    }

    #[test]
    fn a_never_observed_timestamp_does_not_block_a_rotation() {
        // A fresh install, or a circle whose health row was dropped, must be
        // repairable: `None` is "no evidence", never "too recent".
        let mut inputs = passing();
        inputs.last_epoch_change_at = None;
        inputs.last_rotation_at = None;
        inputs.last_inbound_event_at = None;
        assert_eq!(rotation_decision(&inputs), RotationDecision::Rotate);
    }

    // ── Gates 2, 3, 4, 6 ─────────────────────────────────────────────────────

    #[test]
    fn an_epoch_change_inside_the_window_skips_and_the_boundary_is_inclusive() {
        let mut inputs = passing();

        inputs.last_epoch_change_at = Some(NOW - ROTATION_MIN_EPOCH_AGE_SECS + 1);
        assert_eq!(
            rotation_decision(&inputs),
            RotationDecision::Skip(SkipReason::RecentEpochChange)
        );

        inputs.last_epoch_change_at = Some(NOW - ROTATION_MIN_EPOCH_AGE_SECS);
        assert_eq!(
            rotation_decision(&inputs),
            RotationDecision::Rotate,
            "exactly one window old is old enough"
        );
    }

    #[test]
    fn inbound_traffic_inside_the_quiescence_window_skips() {
        let mut inputs = passing();

        inputs.last_inbound_event_at = Some(NOW - ROTATION_QUIESCENCE_SECS + 1);
        assert_eq!(
            rotation_decision(&inputs),
            RotationDecision::Skip(SkipReason::RecentInboundTraffic)
        );

        inputs.last_inbound_event_at = Some(NOW - ROTATION_QUIESCENCE_SECS);
        assert_eq!(rotation_decision(&inputs), RotationDecision::Rotate);
    }

    #[test]
    fn a_pending_proposal_skips_however_quiet_the_circle_is() {
        // The auto-committer race is closed by the PROPOSAL, not by the clock:
        // a remaining member stages the eviction commit from inside its own next
        // send, which may be a full publish cycle away. Silence is not evidence
        // that nobody will commit while an uncommitted proposal is stored — and
        // a self-update takes in no proposal, so one that won the epoch would
        // leave a leaver reading for one more.
        let mut inputs = passing();
        inputs.last_inbound_event_at = Some(0);
        inputs.pending_proposal = true;
        assert_eq!(
            rotation_decision(&inputs),
            RotationDecision::Skip(SkipReason::PendingProposal)
        );
    }

    #[test]
    fn a_rotation_inside_the_rate_limit_skips_and_the_boundary_is_inclusive() {
        let mut inputs = passing();

        inputs.last_rotation_at = Some(NOW - ROTATION_MIN_INTERVAL_SECS + 1);
        assert_eq!(
            rotation_decision(&inputs),
            RotationDecision::Skip(SkipReason::RotatedRecently)
        );

        inputs.last_rotation_at = Some(NOW - ROTATION_MIN_INTERVAL_SECS);
        assert_eq!(rotation_decision(&inputs), RotationDecision::Rotate);
    }

    #[test]
    fn a_timestamp_in_the_future_blocks_rather_than_licenses() {
        // A backwards clock jump must not manufacture a rotation: a stamp the
        // device reads as "in the future" is evidence it cannot age, so every
        // window treats it as fresh.
        for field in 0..3 {
            let mut inputs = passing();
            let ahead = Some(NOW + 1);
            let expected = match field {
                0 => {
                    inputs.last_epoch_change_at = ahead;
                    SkipReason::RecentEpochChange
                }
                1 => {
                    inputs.last_inbound_event_at = ahead;
                    SkipReason::RecentInboundTraffic
                }
                _ => {
                    inputs.last_rotation_at = ahead;
                    SkipReason::RotatedRecently
                }
            };
            assert_eq!(rotation_decision(&inputs), RotationDecision::Skip(expected));
        }
    }

    #[test]
    fn the_first_failing_gate_is_the_one_reported() {
        // Ordering matters for what the UI tells the user, so it is pinned:
        // the terminal reason outranks every "try again later".
        let mut inputs = passing();
        inputs.group_is_unrecoverable = true;
        inputs.last_epoch_change_at = Some(NOW);
        inputs.last_inbound_event_at = Some(NOW);
        inputs.last_rotation_at = Some(NOW);
        inputs.pending_proposal = true;
        assert_eq!(
            rotation_decision(&inputs),
            RotationDecision::Skip(SkipReason::EpochUnrecoverable)
        );
    }

    #[test]
    fn skip_reasons_carry_no_identifiers() {
        // Fieldless by construction, so the derived `Debug` is the variant name
        // and nothing else. A later field addition has to face this assertion
        // rather than quietly start printing a group id through a log line
        // (Security Rules 4/8).
        for (reason, name) in [
            (SkipReason::EpochNotStable, "EpochNotStable"),
            (SkipReason::RecentEpochChange, "RecentEpochChange"),
            (SkipReason::EpochUnrecoverable, "EpochUnrecoverable"),
            (SkipReason::RecentInboundTraffic, "RecentInboundTraffic"),
            (SkipReason::PendingProposal, "PendingProposal"),
            (SkipReason::RotatedRecently, "RotatedRecently"),
        ] {
            assert_eq!(format!("{reason:?}"), name);
        }
    }

    #[test]
    fn quiescence_window_cannot_be_held_shut_by_a_live_peer() {
        // The defect this pins is the mirror image of an inert gate, and it is
        // just as fatal: a peer whose messages this device can no longer decrypt
        // is still PUBLISHING, and every one of those publishes is an inbound
        // group event once the circle is healthy again. A quiescence window at
        // or above the publish-cadence floor is therefore re-armed before it can
        // expire, and the repair becomes unreachable on exactly the circles it
        // exists to fix.
        assert!(
            std::hint::black_box(ROTATION_QUIESCENCE_SECS)
                < std::hint::black_box(MIN_UPDATE_INTERVAL_SECS),
            "the quiescence window ({ROTATION_QUIESCENCE_SECS}s) must stay strictly below the \
             publish-cadence floor ({MIN_UPDATE_INTERVAL_SECS}s), or a live peer holds the \
             repair shut forever"
        );
    }

    #[test]
    fn an_unrecoverable_group_is_declined_as_terminal_not_as_busy() {
        // The two non-`Stable` answers must never collapse into one: "busy" tells
        // the user to try again, and `Unrecoverable` never clears by waiting.
        let mut inputs = passing();
        inputs.group_is_unrecoverable = true;
        assert_eq!(
            rotation_decision(&inputs),
            RotationDecision::Skip(SkipReason::EpochUnrecoverable)
        );
    }
}
