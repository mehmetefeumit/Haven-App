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
/// * `has_known_picture` — a non-empty picture is cached / was uploaded.
#[must_use]
pub const fn has_published_profile(published_kind0: bool, has_known_picture: bool) -> bool {
    published_kind0 || has_known_picture
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn remove_when_no_profile_is_noop() {
        // Nothing published and no cached picture → retraction gate is false, so
        // the caller performs no publish (no new public footprint).
        assert!(!has_published_profile(false, false));
    }

    #[test]
    fn has_published_profile_true_when_kind0_or_picture() {
        assert!(has_published_profile(true, false));
        assert!(has_published_profile(false, true));
        assert!(has_published_profile(true, true));
    }
}
