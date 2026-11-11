//! Retraction no-op predicate for public-profile publishing.
//!
//! Publishing a public profile is **unconditional** (public-by-default, with an
//! ambient disclosure surfaced in the UI — owner-directed, 2026-07-16); there is
//! no persisted consent flag and no publish-time gate. The one invariant that
//! remains here is the **retraction no-op gate**: the ungated "delete/remove"
//! actions must never mint a *first* public event for a pubkey that never
//! published anything. [`has_published_profile`] is the pure predicate those
//! actions consult, kept in this `crate::circle`-free module so the invariant
//! has a single, testable home (the persisted lookup lives in
//! [`crate::circle::storage_profile`], which delegates the boolean decision
//! here).

/// Whether this pubkey has an existing public footprint worth retracting.
///
/// The ungated retraction actions ("delete public profile", "remove profile
/// picture") consult this predicate and become a **no-op** when it is `false`,
/// so a retraction can never CREATE the very first public event for a pubkey
/// that never published anything.
///
/// * `published_kind0` — a kind-0 row exists in `published_events` for this
///   pubkey (Haven published a profile at some point);
/// * `has_known_picture` — a picture with a REAL public URL is cached. Bytes
///   staged for an upload that has not happened yet do NOT count: nothing
///   public exists for them, so retracting them would be the first public
///   event;
/// * `seen_kind0` — a resolved kind-0 is cached for this pubkey (an imported
///   identity whose profile was published by another client). Without it, an
///   imported account with a profile but no locally-recorded publish would
///   treat "delete my public profile" as a no-op and leave the profile up.
#[must_use]
pub const fn has_published_profile(
    published_kind0: bool,
    has_known_picture: bool,
    seen_kind0: bool,
) -> bool {
    published_kind0 || has_known_picture || seen_kind0
}

/// What one read of every pool relay found of the local user's own kind-0.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OwnReadVerdict {
    /// At least one relay served a copy.
    Found,
    /// Every relay ended its answer and none served one.
    Absent,
    /// No copy was served and at least one relay did not end its answer.
    Unanswered,
}

/// What a sync does with a pending set that carries no saved content (a photo
/// removal alone, or an owed deletion blank).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RetractionGate {
    /// Build on what is known and publish.
    Publish,
    /// Nothing public exists: level the pending set locally, send nothing.
    Settle,
    /// Keep it pending on the retry ladder.
    Hold,
}

/// Decides a retraction-only publish.
///
/// It never mints a first public event (`!published_here` publishes only on a
/// copy actually read) and never overwrites a profile this device cannot see
/// (`published_here` with neither a copy read nor a dated own row holds).
#[must_use]
pub const fn retraction_gate(
    published_here: bool,
    read: OwnReadVerdict,
    local_dated: bool,
) -> RetractionGate {
    match (read, published_here) {
        (OwnReadVerdict::Found, _) => RetractionGate::Publish,
        (_, true) if local_dated => RetractionGate::Publish,
        (OwnReadVerdict::Absent, false) => RetractionGate::Settle,
        _ => RetractionGate::Hold,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn remove_when_no_profile_is_noop() {
        // Nothing published, no publicly-hosted picture and no kind-0 ever seen
        // → retraction gate is false, so the caller performs no publish (no new
        // public footprint).
        assert!(!has_published_profile(false, false, false));
    }

    #[test]
    fn has_published_profile_true_when_kind0_or_picture_or_seen() {
        // Each arm arms the gate on its own — in particular the third, which is
        // the only thing that arms it for an imported identity whose profile
        // was published by another client.
        assert!(has_published_profile(true, false, false));
        assert!(has_published_profile(false, true, false));
        assert!(has_published_profile(false, false, true));
        assert!(has_published_profile(true, true, true));
    }

    // ---- the retraction gate ------------------------------------------------

    #[test]
    fn the_retraction_gate_never_mints_and_never_overwrites_an_unseen_profile() {
        use OwnReadVerdict::{Absent, Found, Unanswered};
        use RetractionGate::{Hold, Publish, Settle};

        // (published_here, read, local_dated) -> gate. `!published_here` with a
        // dated row cannot occur (a dated row is itself the third arm of
        // `has_published_profile`), so those cells are not pinned.
        let table = [
            // A relay copy was found: there is a profile to build on.
            (false, Found, false, Publish),
            (true, Found, false, Publish),
            (true, Found, true, Publish),
            // Published here and the row is dated: the row is the base.
            (true, Absent, true, Publish),
            (true, Unanswered, true, Publish),
            // Published here but nothing visible to build on: never overwrite
            // a profile this device cannot see.
            (true, Absent, false, Hold),
            (true, Unanswered, false, Hold),
            // Never published and every relay said so: nothing to retract.
            (false, Absent, false, Settle),
            // Never published and the read did not finish: could not ask.
            (false, Unanswered, false, Hold),
        ];
        for (published_here, read, local_dated, expected) in table {
            assert_eq!(
                retraction_gate(published_here, read, local_dated),
                expected,
                "published_here={published_here} read={read:?} local_dated={local_dated}",
            );
        }

        // The two promises, over every cell rather than the pinned ones.
        for published_here in [false, true] {
            for read in [Found, Absent, Unanswered] {
                for local_dated in [false, true] {
                    let gate = retraction_gate(published_here, read, local_dated);
                    if !published_here && read != Found {
                        assert_ne!(gate, Publish, "a retraction minted a first public event");
                    }
                    if published_here && read != Found && !local_dated {
                        assert_eq!(gate, Hold, "an unseen profile was overwritten");
                    }
                }
            }
        }
    }
}
