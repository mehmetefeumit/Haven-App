//! User-configurable relay preference types.
//!
//! This module defines the small types used by Haven's customizable relay
//! list feature. Relay preferences are stored per-user in the `SQLCipher`
//! `circles.db` (see [`crate::circle::storage_relay_prefs`]) and used by
//! the publish helpers in [`crate::relay::publishers`].
//!
//! # Categories
//!
//! Per the Marmot Protocol and NIP-17 / MIP-00, Haven distinguishes three
//! independent relay categories — two *publishable*, one *local-only*:
//!
//! * [`RelayType::Inbox`] — kind 10050 (NIP-17) — where Welcomes
//!   (gift-wrapped kind 1059) are delivered to this user.
//! * [`RelayType::KeyPackage`] — where this user's `KeyPackage` events
//!   (kind 30443) live, advertised on the wire as a **kind-10002 NIP-65
//!   list**. See the wire-kind note below — [`RelayType::to_kind`] does NOT
//!   return 10002 for this variant, and that is deliberate.
//! * [`RelayType::Profile`] — **no wire kind** — where this user's public
//!   profile (kind 0) is published and where other users' profiles are
//!   fetched from. Local-only policy; see below.
//!
//! # Wire kinds: why `to_kind()` disagrees with what is published
//!
//! Two earlier claims in this module were invalidated by later work and are
//! corrected here, because believing them leads to real mistakes:
//!
//! * Haven **does** publish kind 10002. The Dark Matter migration retired
//!   kind 10051 and moved `KeyPackage` discovery onto the standard NIP-65 list
//!   (see the protocol table in `CLAUDE.md`). That publish is built by
//!   [`crate::relay::build_nip65_relay_list_event`], reached through the FFI's
//!   `RelayTypeFfi::Nip65` route, which never consults [`RelayType::to_kind`].
//! * Haven **does** publish kind 0. The public-profile migration made a
//!   kind-0 profile unconditional on save (owner-directed); the old
//!   "single-purpose client, no kind 0/1/3" rationale no longer holds.
//!
//! [`RelayType::KeyPackage`] therefore still maps to kind **10051** here, and
//! must keep doing so: its one surviving production caller is the legacy
//! retraction in [`crate::relay::maintenance`], which publishes an EMPTY
//! kind-10051 to scrub a pre-Dark-Matter list. 10051 is the kind being
//! *retracted*, not one Haven advertises. Re-pointing this mapping at 10002
//! would make the cutover scrub the user's live NIP-65 list instead — pinned
//! by `no_relay_type_maps_to_nip65_kind_10002` in
//! `tests/relay_preferences_integration_test.rs`.
//!
//! # Why the profile category has no wire kind
//!
//! Haven separates the profile (kind-0) relay plane from the location
//! (kind-445 / kind-1059) plane: a relay must observe EITHER a user's
//! encrypted location traffic OR their profile queries, never both, because a
//! relay that sees both can join "who this IP shares location with" against
//! "who this IP looks up" (see [`crate::profile::relay_pool`]).
//!
//! Advertising the profile plane in a relay list would defeat that separation
//! outright — and far more cheaply than traffic analysis ever could. The list
//! is a *signed, replaceable, publicly fetchable* event authored by the
//! identity key: any observer could pull it and read off exactly which relays
//! carry that pubkey's profile traffic, then subtract them from the relays
//! carrying its location traffic. The link the separation exists to break
//! would be handed out, notarized, on request.
//!
//! So the profile category is structurally unpublishable rather than merely
//! "not published today": [`RelayType::to_kind`] returns `Option<Kind>` and
//! yields `None` for [`RelayType::Profile`]. There is no kind to pass to an
//! event builder, so no present or future caller can publish this list by
//! forgetting a policy check — the type system makes them handle it.

use nostr::Kind;

/// Category of relay preference managed per user.
///
/// Each variant corresponds to a distinct Nostr replaceable event kind that
/// advertises a list of relay URLs to other clients.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum RelayType {
    /// Inbox relays where this user receives gift-wrapped Welcomes
    /// (kind 10050, NIP-17).
    Inbox,
    /// Relays where this user publishes MLS `KeyPackage` events (kind 10051,
    /// MIP-00).
    KeyPackage,
    /// Relays that carry this user's public profile plane (kind 0) and serve
    /// other users' profile lookups.
    ///
    /// **Local-only policy — never advertised on the wire.** This category
    /// exists so the user can edit their profile relays on-device; it has no
    /// relay-list event kind, and [`RelayType::to_kind`] returns `None` for
    /// it. Publishing it would hand any observer a signed, public pointer
    /// joining this identity to its profile plane, reconstructing the exact
    /// cross-plane link the profile/location separation exists to break.
    Profile,
}

impl RelayType {
    /// Returns the canonical string slug used for storage and FFI.
    ///
    /// The slug is used as the value of the `relay_type` column in the
    /// `user_relays` table and as the discriminant when (de)serializing
    /// across the FFI boundary.
    #[must_use]
    pub const fn as_str(&self) -> &'static str {
        match self {
            Self::Inbox => "inbox",
            Self::KeyPackage => "key_package",
            Self::Profile => "profile",
        }
    }

    /// Parses a slug back into a [`RelayType`].
    ///
    /// Returns `None` if the input is not a recognized slug. Callers at the
    /// FFI boundary should map `None` to a user-visible "invalid relay type"
    /// error rather than panicking.
    #[must_use]
    pub fn parse(s: &str) -> Option<Self> {
        match s {
            "inbox" => Some(Self::Inbox),
            "key_package" => Some(Self::KeyPackage),
            "profile" => Some(Self::Profile),
            _ => None,
        }
    }

    /// Returns the Nostr relay-list kind that advertises this category, or
    /// `None` when the category must never be advertised on the wire.
    ///
    /// * [`RelayType::Inbox`] → <code>Some([Kind::InboxRelays])</code> (10050)
    /// * [`RelayType::KeyPackage`] →
    ///   <code>Some([Kind::MlsKeyPackageRelays])</code> (10051)
    /// * [`RelayType::Profile`] → **`None`** — local-only, see the module docs.
    ///
    /// # Why this returns an `Option`
    ///
    /// A total `-> Kind` would force every category to name *some* kind, and
    /// the only way to add a local-only category under that signature is to
    /// pick a placeholder and rely on every call site remembering a separate
    /// "is this publishable?" check. Anyone who forgets publishes the profile
    /// plane. Returning `None` moves that check into the type system: there is
    /// no `Kind` to hand an [`nostr::EventBuilder`], so the omission is a
    /// compile error rather than a silent, signed, public privacy leak.
    ///
    /// Callers that hold a `Result` should map `None` to an error; callers that
    /// iterate categories should skip it. Never substitute a fallback kind.
    #[must_use]
    pub const fn to_kind(self) -> Option<Kind> {
        match self {
            Self::Inbox => Some(Kind::InboxRelays),
            Self::KeyPackage => Some(Kind::MlsKeyPackageRelays),
            // No wire kind exists for the profile plane, by design. Do NOT
            // invent one — see the module-level "Why the profile category has
            // no wire kind".
            Self::Profile => None,
        }
    }

    /// Returns `true` when a relay list for this category may be published.
    ///
    /// Equivalent to `self.to_kind().is_some()`, named for call sites that
    /// branch on publishability without needing the kind itself.
    #[must_use]
    pub const fn is_publishable(self) -> bool {
        self.to_kind().is_some()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Every variant, spelled out. The exhaustive `match` below makes adding a
    /// variant without extending this list a COMPILE error, so the tests that
    /// iterate it can never silently skip a new category.
    const ALL_VARIANTS: [RelayType; 3] =
        [RelayType::Inbox, RelayType::KeyPackage, RelayType::Profile];

    #[test]
    fn all_variants_is_exhaustive() {
        for t in ALL_VARIANTS {
            match t {
                // Adding a variant breaks this match; extend ALL_VARIANTS.
                RelayType::Inbox | RelayType::KeyPackage | RelayType::Profile => {}
            }
        }
        assert_eq!(ALL_VARIANTS.len(), 3);
    }

    #[test]
    fn as_str_round_trip() {
        for t in ALL_VARIANTS {
            assert_eq!(RelayType::parse(t.as_str()), Some(t));
        }
    }

    #[test]
    fn parse_unknown_returns_none() {
        assert_eq!(RelayType::parse("nip65"), None);
        assert_eq!(RelayType::parse(""), None);
        assert_eq!(RelayType::parse("Inbox"), None); // case-sensitive
    }

    #[test]
    fn slug_values_are_stable() {
        // These slugs are persisted in SQLite — changing them is a breaking
        // schema change. Pin the values explicitly.
        assert_eq!(RelayType::Inbox.as_str(), "inbox");
        assert_eq!(RelayType::KeyPackage.as_str(), "key_package");
        assert_eq!(RelayType::Profile.as_str(), "profile");
    }

    #[test]
    fn to_kind_maps_correctly() {
        assert_eq!(RelayType::Inbox.to_kind(), Some(Kind::InboxRelays));
        assert_eq!(
            RelayType::KeyPackage.to_kind(),
            Some(Kind::MlsKeyPackageRelays)
        );
    }

    #[test]
    fn profile_relay_type_has_no_publishable_kind() {
        // THE invariant of this category. A relay list naming the profile
        // relays is a signed, replaceable, publicly fetchable event authored by
        // the identity key — publishing one would join this pubkey to its
        // profile plane for any observer who asks, which is strictly more
        // damaging than the traffic analysis the plane separation defends
        // against. There must therefore be NO kind to hand an EventBuilder.
        assert_eq!(
            RelayType::Profile.to_kind(),
            None,
            "profile relays are local-only policy and must never be publishable"
        );
        assert!(!RelayType::Profile.is_publishable());

        // ...and no OTHER variant may quietly become the profile plane's
        // publish vehicle by sharing its slug or its kind.
        for t in ALL_VARIANTS {
            if t == RelayType::Profile {
                continue;
            }
            assert!(
                t.is_publishable(),
                "{} lost its wire kind; publishable categories must keep one",
                t.as_str()
            );
        }
    }

    #[test]
    fn profile_kind_is_not_reachable_through_any_slug() {
        // Defense in depth against a future "profile" alias slug that parses to
        // a publishable variant (which would let stored profile rows be
        // published under someone else's kind).
        let parsed = RelayType::parse("profile").expect("profile slug must parse");
        assert_eq!(parsed, RelayType::Profile);
        assert_eq!(parsed.to_kind(), None);
    }

    #[test]
    fn copy_semantics() {
        // RelayType is Copy — pass by value freely.
        let t = RelayType::Inbox;
        let _a = t;
        let _b = t; // would not compile if Copy was removed
        assert_eq!(t, RelayType::Inbox);
    }
}
