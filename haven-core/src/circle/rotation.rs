//! Gates for the epoch-rotation REPAIR (`docs/EPOCH_ROTATION_REPAIR_PLAN.md`).
//!
//! # What this repairs, and what it is not
//!
//! `OpenMLS` caps how far a decryption ratchet may be wound forward
//! (`SenderRatchetConfiguration::maximum_forward_distance`, default 1000, which
//! MDK does not override). A member that has missed more than that many
//! consecutive application messages from one peer gets
//! `SecretTreeError::TooDistantInTheFuture` for every later message from that
//! peer — permanently, because a ratchet cannot be rewound and a Haven circle's
//! epoch only moves when its membership changes.
//!
//! The one commit Haven can author to escape that is a byte-identical
//! `UpdateAppComponents(admin-policy.v1)`: applying it derives a fresh
//! `encryption_secret`, so every sender ratchet in the group restarts at
//! generation 0. That is a **ratchet reset**, and calling it anything else would
//! be false: the commit carries no `UpdatePath` (`force_self_update` defaults
//! false and an `AppDataUpdate` is not path-required), so it rotates no leaf key
//! and provides **no** post-compromise security and no new forward secrecy.
//! Never describe it as "key rotation" in code, comments, logs or user copy.
//!
//! # Why the decision is a pure function
//!
//! Every gate is a comparison over values read at one instant, and the one
//! property that matters — that two members can never both decide to commit —
//! is a property of the decision, not of the engine. Keeping it pure is what
//! makes that property property-testable over rosters the engine would need a
//! fork to produce.

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
///    read that keeps declining until the departure commits.
/// 2. **A proposal that reached a peer but not us** is closed by the ENGINE, not
///    by this window — though less absolutely than it first looks, so the claim
///    is scoped here rather than overstated.
///
///    At the `fork_recovery` seam the tie IS decided by priority: both commits
///    carry the same `source_epoch`, `CommitOrderingKey::cmp`
///    (`traits/engine.rs`) breaks the tie on `priority`, and the LOWEST key wins
///    (`fork_recovery.rs`: a candidate `>=` the incumbent loses). This rotation
///    is an `UpdateAppComponents(admin-policy.v1)`, which
///    `commit_ordering_priority_for_staged` (`app_components.rs`) classifies
///    `Privileged`; a SelfRemove-only auto-commit is `Ordinary`, and
///    `Privileged` is declared first, so it sorts below and the rotation wins.
///
///    The CONVERGENCE selector is not that seam and does not agree by
///    construction: it consults priority only FIFTH, after commit depth,
///    witness quorum, valid depth and app-witness score. So the rotation
///    usually wins, not always. Either way one branch converges and every
///    replica lands on it — the outcome that matters here is convergence, not
///    which commit won.
///
///    **Residual: one extra epoch, never a fork.** When the rotation loses, the
///    24-hour rate limit was nonetheless spent on a commit that did not survive
///    (the charge happens at `confirm_published`, before any branch selection
///    can be known), so that circle waits a day for its next repair. That is
///    the honest cost of charging on the confirm rather than on the outcome,
///    and it is preferred to the alternative: not charging would let a losing
///    commit be retried in a loop. The pre-existing cross-restart twin fork
///    (M11 §H2, `EpochManager::committed_from` being in-memory) is unchanged by
///    this unit and is the only fork-shaped risk here.
///
/// So this half is defence in depth over an engine guarantee, which is why it is
/// sized for cheapness rather than for coverage.
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
/// it is the reason this half must never be the only thing standing between two
/// committers, and the reason it is sized as small as it is.
pub const ROTATION_QUIESCENCE_SECS: u64 = 30;

/// Why a repair rotation was declined.
///
/// Fieldless by construction: a skip is surfaced to the UI and to logs, and no
/// variant may carry a group id, a pubkey or an epoch (Security Rules 4/6/8).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SkipReason {
    /// The caller is not the circle's only admin (gate 1). Either somebody else
    /// can commit — so this device must not — or an admin handoff is mid-flight.
    NotSoleAdmin,
    /// The engine's epoch state for this group is not `Stable` but is expected
    /// to become so on its own — a commit is staged, merging, or recovering
    /// (gate 2). Retryable: the caller may offer the repair again shortly.
    EpochNotStable,
    /// The engine has frozen this group at its last stable epoch and refuses to
    /// apply or ingest further group state (`EpochState::Unrecoverable`).
    ///
    /// Deliberately NOT folded into [`Self::EpochNotStable`]: this one never
    /// clears by waiting, so surfacing it as "try again shortly" would put the
    /// user in a retry loop that cannot succeed. The only exits are a verified
    /// repair path the engine does not expose to Haven, or leaving and being
    /// re-added.
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
    /// Author the byte-identical admin-policy commit.
    Rotate,
    /// Do nothing, for this reason.
    Skip(SkipReason),
}

/// Everything the gates read, gathered at one instant.
///
/// A struct rather than eight positional arguments so the call site names each
/// value, and so a later gate cannot be added by silently widening a tuple.
#[derive(Clone, Copy, Debug)]
pub struct RotationInputs<'a> {
    /// The local member identity, as raw bytes (the engine's `MemberId`).
    pub self_id: &'a [u8],
    /// The group's admin set exactly as the engine reports it (raw x-only
    /// pubkeys).
    pub admins: &'a [[u8; 32]],
    /// Whether the engine has reported this group `Unrecoverable`.
    ///
    /// The engine exposes no epoch-state getter at MDK `e391adc`, so this is the
    /// one non-`Stable` state the caller can observe out of band; the others
    /// (`PendingPublish` / `Merging` / `Recovering`) arrive only as a typed
    /// rejection of the send itself. See `docs/EPOCH_ROTATION_REPAIR_PLAN.md`
    /// §4 gate 2 and §6.
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

/// Decides whether this device may author a repair rotation for one circle.
///
/// Gates are evaluated in the order they are numbered in
/// `docs/EPOCH_ROTATION_REPAIR_PLAN.md` §4, so the reported reason is the first
/// one that fails rather than an arbitrary one.
///
/// # Divergence safety
///
/// Gate 1 is `admins == [self]`, which selects **at most one** member per admin
/// set: a set with two admins elects nobody, and a set with one elects only that
/// one. Two members can therefore both decide to rotate only if their admin-set
/// views are disjoint singletons — `{A}` here and `{B}` there — which Haven's
/// own handoff cannot produce, because
/// [`propose_admin_handoff`](super::CircleManager::propose_admin_handoff)
/// promotes the successor into the existing set (`{A}` → `{A, B}`) before
/// [`propose_self_demote`](super::CircleManager::propose_self_demote) drops the
/// predecessor, so every intermediate view shares an admin with its neighbour.
///
/// This is deliberately NOT a "lowest pubkey commits" election. That rule would
/// elect a committer out of `{A, B}` — and Haven circles have exactly one admin,
/// so the only member the engine would accept a commit from is that admin.
#[must_use]
pub fn rotation_decision(inputs: &RotationInputs<'_>) -> RotationDecision {
    // Gate 1 — the caller is the group's only admin.
    if inputs.admins.len() != 1 || inputs.admins[0].as_slice() != inputs.self_id {
        return RotationDecision::Skip(SkipReason::NotSoleAdmin);
    }
    // Gate 2 — the engine will accept a staged commit. Only the terminal state
    // is observable before the send; the transient ones surface as a typed
    // rejection of `update_admin_policy`.
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
    use proptest::prelude::*;

    /// Day 20 000 (2024-10-04) in Unix seconds. Every clock in these tests is an
    /// explicit value, so a gate boundary lands on an exact second rather than
    /// on whatever the wall clock happened to be.
    const NOW: u64 = 20_000 * 86_400;

    fn key(byte: u8) -> [u8; 32] {
        [byte; 32]
    }

    /// Inputs with every gate open, so a test that flips ONE field is testing
    /// that field.
    fn passing<'a>(self_id: &'a [u8; 32], admins: &'a [[u8; 32]]) -> RotationInputs<'a> {
        RotationInputs {
            self_id: self_id.as_slice(),
            admins,
            group_is_unrecoverable: false,
            last_epoch_change_at: Some(NOW - ROTATION_MIN_EPOCH_AGE_SECS),
            last_rotation_at: Some(NOW - ROTATION_MIN_INTERVAL_SECS),
            last_inbound_event_at: Some(NOW - ROTATION_QUIESCENCE_SECS),
            pending_proposal: false,
            now: NOW,
        }
    }

    #[test]
    fn the_sole_admin_rotates_when_every_gate_is_open() {
        let me = key(1);
        let admins = [me];
        assert_eq!(
            rotation_decision(&passing(&me, &admins)),
            RotationDecision::Rotate
        );
    }

    #[test]
    fn a_never_observed_timestamp_does_not_block_a_rotation() {
        // A fresh install, or a circle whose health row was dropped, must be
        // repairable: `None` is "no evidence", never "too recent".
        let me = key(1);
        let admins = [me];
        let mut inputs = passing(&me, &admins);
        inputs.last_epoch_change_at = None;
        inputs.last_rotation_at = None;
        inputs.last_inbound_event_at = None;
        assert_eq!(rotation_decision(&inputs), RotationDecision::Rotate);
    }

    // ── Gate 1 ───────────────────────────────────────────────────────────────

    #[test]
    fn a_non_admin_never_rotates() {
        let me = key(1);
        let other = key(2);
        let admins = [other];
        assert_eq!(
            rotation_decision(&passing(&me, &admins)),
            RotationDecision::Skip(SkipReason::NotSoleAdmin)
        );
    }

    #[test]
    fn an_admin_pair_elects_nobody_in_either_lexicographic_order() {
        // The divergence-safety pin. `{A}` elects A; `{A, B}` elects NEITHER,
        // whichever way the engine happens to have ordered the set — so a member
        // whose view has gained a second admin (a handoff in flight) stops
        // rotating the instant it sees the pair, without needing to agree with
        // anyone about the ordering.
        let a = key(0x0A);
        let b = key(0xB0);
        assert!(a < b, "fixture: A must sort below B");

        assert_eq!(
            rotation_decision(&passing(&a, &[a])),
            RotationDecision::Rotate,
            "the sole admin of {{A}} rotates"
        );
        for pair in [[a, b], [b, a]] {
            for me in [a, b] {
                assert_eq!(
                    rotation_decision(&passing(&me, &pair)),
                    RotationDecision::Skip(SkipReason::NotSoleAdmin),
                    "no member of a two-admin view may rotate, in any ordering"
                );
            }
        }
    }

    #[test]
    fn the_lowest_pubkey_is_not_elected_out_of_an_admin_pair() {
        // Negative control for the rule this deliberately is NOT. A
        // "lowest pubkey commits" election would hand `{A, B}` to A; every
        // Haven circle has exactly one admin, so the only member the engine
        // would accept a commit from is that admin, and electing A here would
        // produce a commit the group rejects — or, worse, a second committer
        // during a handoff.
        let low = key(0x01);
        let high = key(0xFF);
        assert!(low < high, "fixture: `low` must sort below `high`");
        assert_eq!(
            rotation_decision(&passing(&low, &[low, high])),
            RotationDecision::Skip(SkipReason::NotSoleAdmin),
            "the lowest pubkey must NOT be elected out of a two-admin set"
        );
    }

    // ── Gates 2, 3, 4, 6 ─────────────────────────────────────────────────────

    #[test]
    fn an_epoch_change_inside_the_window_skips_and_the_boundary_is_inclusive() {
        let me = key(1);
        let admins = [me];
        let mut inputs = passing(&me, &admins);

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
        let me = key(1);
        let admins = [me];
        let mut inputs = passing(&me, &admins);

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
        // that nobody will commit while an uncommitted proposal is stored.
        let me = key(1);
        let admins = [me];
        let mut inputs = passing(&me, &admins);
        inputs.last_inbound_event_at = Some(0);
        inputs.pending_proposal = true;
        assert_eq!(
            rotation_decision(&inputs),
            RotationDecision::Skip(SkipReason::PendingProposal)
        );
    }

    #[test]
    fn a_rotation_inside_the_rate_limit_skips_and_the_boundary_is_inclusive() {
        let me = key(1);
        let admins = [me];
        let mut inputs = passing(&me, &admins);

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
        let me = key(1);
        let admins = [me];
        for field in 0..3 {
            let mut inputs = passing(&me, &admins);
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
        // "you are not the owner" outranks "try again later".
        let me = key(1);
        let admins = [key(2)];
        let mut inputs = passing(&me, &admins);
        inputs.group_is_unrecoverable = true;
        inputs.last_epoch_change_at = Some(NOW);
        inputs.last_inbound_event_at = Some(NOW);
        inputs.last_rotation_at = Some(NOW);
        inputs.pending_proposal = true;
        assert_eq!(
            rotation_decision(&inputs),
            RotationDecision::Skip(SkipReason::NotSoleAdmin)
        );
    }

    // ── The divergence property ──────────────────────────────────────────────

    /// Runs the decision for `me` against `admins`, with every other gate open.
    fn rotates(me: &[u8; 32], admins: &[[u8; 32]]) -> bool {
        rotation_decision(&passing(me, admins)) == RotationDecision::Rotate
    }

    proptest! {
        #[test]
        fn one_admin_set_elects_at_most_one_member(
            admins in prop::collection::vec(any::<[u8; 32]>(), 0..4),
            outsiders in prop::collection::vec(any::<[u8; 32]>(), 0..3),
        ) {
            // The shared-view case: whatever the engine reports as the admin
            // set, no two members of the circle may both decide to commit.
            //
            // The candidate set is the ADMINS themselves plus some outsiders,
            // never independently random keys. Two random 32-byte arrays
            // essentially never collide, so a candidate set drawn independently
            // of the admin set would make gate 1 unreachable and this property
            // vacuous — it would pass against a decision that elected every
            // admin in a set of three.
            let mut candidates = admins.clone();
            candidates.extend(outsiders.iter().copied());
            candidates.sort_unstable();
            candidates.dedup();
            let electors: Vec<_> = candidates
                .iter()
                .filter(|m| rotates(m, &admins))
                .collect();
            prop_assert!(
                electors.len() <= 1,
                "an admin set elected {} committers: {admins:?} / {candidates:?}",
                electors.len()
            );
        }

        #[test]
        fn intersecting_divergent_views_elect_at_most_one_member(
            anchor in any::<[u8; 32]>(),
            extras in prop::collection::vec(prop::collection::vec(any::<[u8; 32]>(), 0..3), 1..5),
            members in prop::collection::vec(any::<[u8; 32]>(), 1..6),
        ) {
            // The DIVERGENT case. Each member evaluates its own admin-set view,
            // and the views need not agree — but every one of them contains
            // `anchor`, which is the invariant Haven's handoff actually
            // maintains: `propose_admin_handoff` promotes the successor INTO the
            // existing set before `propose_self_demote` drops the predecessor,
            // so no two views along a handoff are disjoint.
            //
            // Under that hypothesis at most one member may rotate — and it can
            // only ever be `anchor`, because every view contains it and gate 1
            // requires the view to be exactly `[self]`.
            let views: Vec<Vec<[u8; 32]>> = extras
                .iter()
                .map(|extra| {
                    let mut view = vec![anchor];
                    view.extend(extra.iter().copied());
                    view
                })
                .collect();

            // Same anti-vacuity rule: the candidates are the keys that actually
            // appear in the views, plus outsiders — never independent randoms.
            let mut candidates = vec![anchor];
            for extra in &extras {
                candidates.extend(extra.iter().copied());
            }
            candidates.extend(members.iter().copied());
            candidates.sort_unstable();
            candidates.dedup();

            // DISTINCT members, not (member, view) pairs: the same member
            // rotating under several of its own views is one committer, and the
            // property is that no SECOND member ever joins it.
            let mut electors: Vec<[u8; 32]> = Vec::new();
            for member in &candidates {
                if views.iter().any(|view| rotates(member, view)) {
                    prop_assert_eq!(
                        *member, anchor,
                        "only the admin every view agrees on may rotate"
                    );
                    electors.push(*member);
                }
            }
            prop_assert!(
                electors.len() <= 1,
                "intersecting views elected {} committers",
                electors.len()
            );
        }
    }

    #[test]
    fn disjoint_singleton_views_both_elect_and_only_a_rolled_back_commit_reaches_them() {
        // The honest boundary of the property above, pinned rather than left
        // implicit: two members DO both rotate when their views are disjoint
        // singletons.
        //
        // Haven's own two-commit handoff cannot produce that state on its own —
        // `propose_admin_handoff` yields `{A, B}` before `propose_self_demote`
        // drops the predecessor, and the demote refuses to empty the admin set,
        // so every view along the sequence shares an admin with its neighbour.
        //
        // It IS reachable through the pre-existing twin-fork window, and saying
        // otherwise would overstate the guarantee: a commit the relays actually
        // accepted, that its author never learned of and rolled back
        // (`publish_failed`), leaves the peers on a branch the author is not on
        // (`docs/EPOCH_ROTATION_REPAIR_PLAN.md` §2, M11 §H2). A handoff resolved
        // that way puts the successor's view at `{A, B}` while the author's has
        // snapped back to `{A}`; a further admin action on the successor's
        // branch reaches `{B}`, and the two views are then disjoint singletons.
        //
        // That window is not this unit's to close — it predates the repair and
        // applies to every Haven commit — but the gate must not be described as
        // if it were closed.
        let a = key(0x0A);
        let b = key(0xB0);
        assert!(rotates(&a, &[a]));
        assert!(rotates(&b, &[b]));
    }

    #[test]
    fn skip_reasons_carry_no_identifiers() {
        // Fieldless by construction, so the derived `Debug` is the variant name
        // and nothing else. A later field addition has to face this assertion
        // rather than quietly start printing a group id through a log line
        // (Security Rules 4/8).
        for (reason, name) in [
            (SkipReason::NotSoleAdmin, "NotSoleAdmin"),
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
        let me = key(1);
        let admins = [me];
        let mut inputs = passing(&me, &admins);
        inputs.group_is_unrecoverable = true;
        assert_eq!(
            rotation_decision(&inputs),
            RotationDecision::Skip(SkipReason::EpochUnrecoverable)
        );
    }
}
