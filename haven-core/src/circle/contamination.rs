//! The append-only contamination ledger for the profile/location plane split.
//!
//! # What "contaminated" means
//!
//! Haven separates the profile (kind-0) relay plane from the location
//! (kind-445 / kind-1059) plane: a relay must observe EITHER a user's encrypted
//! location traffic OR their profile queries, never both. A relay that sees
//! both can join "who this IP shares location with" against "who this IP looks
//! up", reconstructing the social graph Haven deliberately never publishes as a
//! kind-3 contact list (see [`crate::profile::relay_pool`]).
//!
//! A relay becomes **contaminated** the moment it is handed any location-plane
//! traffic — a circle's kind-445 routing set, a gift-wrapped Welcome (kind
//! 1059), an inbox (kind-10050) advertisement, or a `KeyPackage` (kind-30443)
//! publish — or any **discovery-plane** read. From then on it is permanently
//! excluded from the profile pool.
//!
//! # Why the discovery plane counts as contamination
//!
//! The discovery relays ([`crate::relay::discovery_relays`]) are read-only, but
//! what they are read FOR is the pre-group step of the location plane:
//! `fetch_relay_list` and `fetch_member_keypackage` (`crate::relay::manager`)
//! ask them for a specific pubkey's NIP-65 list and kind-30443 `KeyPackage`.
//! "This IP asked for pubkey X's `KeyPackage`" is a *stronger* co-membership
//! signal than a kind-0 lookup — it means an invitation to X is imminent — so a
//! relay that served both those queries and this account's kind-0 lookups can
//! run exactly the join the plane split exists to break.
//!
//! # Why the ledger is APPEND-ONLY
//!
//! Contamination is HISTORICAL, not a property of current configuration. A
//! relay that routed a circle's kind-445 last month saw those events, and
//! leaving the circle does not un-see them. Recomputing the excluded set from
//! live rows (`circles.relays`, `user_relays`) would shrink it over time and
//! silently re-admit a relay that already holds the user's encrypted traffic —
//! the exact cross-plane join the separation exists to break, re-created
//! quietly and with no failing test.
//!
//! So the ledger only ever grows, and no API can shrink it:
//!
//! * writes are `INSERT OR IGNORE`, so `first_seen` records the FIRST sighting
//!   and is never overwritten;
//! * there is deliberately **no `delete_circle` cascade** — leaving or deleting
//!   a circle must not drop the rows its relays created;
//! * there is deliberately **no row-removal method at all** on
//!   [`CircleStorage`] or [`crate::circle::CircleManager`]. The one case where
//!   forgetting is correct is LOGOUT — the identity those relays observed is
//!   itself being destroyed, so the next identity on this device has no shared
//!   history with them — and logout achieves it by deleting the whole
//!   `circles.db` file (plus its WAL/SHM/journal sidecars) in the FFI wipe,
//!   never by clearing the table in place. Pinned by
//!   `contaminated_ledger_is_append_only`.
//!
//! # Why the ledger is a FLAT URL SET
//!
//! The `contaminated_relays` table carries no circle / group column (pinned by
//! `contaminated_relays_table_has_no_circle_or_group_column` in
//! `super::storage_profile`). A per-circle ledger would record which relays
//! carry WHICH group — co-membership routing metadata that not even a local,
//! encrypted table should hold. Knowing only that a URL is contaminated is
//! sufficient to exclude it, so the group linkage is never stored at all.
//!
//! # Normalization is load-bearing
//!
//! Every URL is passed through [`crate::relay::normalize_relay_url`] before it
//! is inserted, and the exclusion filter normalizes again before comparing. Set
//! subtraction over raw strings fails **open**: a trailing slash or a
//! capitalised host would let a contaminated relay survive exclusion and start
//! serving profile traffic. See
//! `contaminated_ledger_normalizes_before_insert_and_compare`.
//!
//! [`CircleStorage`]: super::CircleStorage

use super::relay_prefs::RelayType;

/// How a relay entered the contamination ledger.
///
/// Recorded for **diagnostics only** — exclusion never branches on the source.
/// A relay contaminated by any one of these has seen location-plane traffic,
/// and that is the whole predicate.
///
/// The slugs are persisted in the `contaminated_relays.source` column, so
/// changing one is a breaking schema change (pinned by
/// `contamination_source_slugs_are_stable`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ContaminationSource {
    /// A circle's kind-445 routing relay set (`circles.relays`): the relay
    /// carries this account's encrypted location messages and its commits.
    CircleRouting,
    /// An inbox relay (kind 10050, NIP-17): the relay receives this account's
    /// gift-wrapped Welcomes.
    Inbox,
    /// A Welcome delivery relay resolved by the fail-closed cascade: the relay
    /// was handed a kind-1059 gift wrap addressed to an invitee.
    Welcome,
    /// A `KeyPackage` relay (kind 30443 + its NIP-65 advertisement): the relay
    /// carries this account's pre-group MLS init material.
    KeyPackage,
    /// A discovery-plane relay (`crate::relay::discovery_relays`): the relay
    /// served this account's read-only lookups of *other* users' NIP-65 relay
    /// lists and kind-30443 `KeyPackage`s — the pre-invitation step of the
    /// location plane, and a stronger co-membership signal than a kind-0
    /// lookup.
    Discovery,
}

impl ContaminationSource {
    /// Returns the canonical slug persisted in `contaminated_relays.source`.
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::CircleRouting => "circle_routing",
            Self::Inbox => "inbox",
            Self::Welcome => "welcome",
            Self::KeyPackage => "key_package",
            Self::Discovery => "discovery",
        }
    }

    /// Parses a persisted slug back into a [`ContaminationSource`].
    ///
    /// Returns `None` for an unrecognized slug. Callers reading the ledger for
    /// diagnostics should treat `None` as "unknown source" — never as "not
    /// contaminated", since the row's presence alone is the exclusion signal.
    #[must_use]
    pub fn parse(s: &str) -> Option<Self> {
        match s {
            "circle_routing" => Some(Self::CircleRouting),
            "inbox" => Some(Self::Inbox),
            "welcome" => Some(Self::Welcome),
            "key_package" => Some(Self::KeyPackage),
            "discovery" => Some(Self::Discovery),
            _ => None,
        }
    }

    /// Maps a user relay category to the contamination it implies, or `None`
    /// when the category carries **no** location-plane traffic.
    ///
    /// # Why this returns an `Option` instead of a total mapping
    ///
    /// [`RelayType::Profile`] must map to nothing: those relays ARE the profile
    /// pool, and recording them would make the pool subtract itself — every
    /// entry excluded, [`crate::profile::ProfileError::PoolUnderflow`] forever,
    /// and (if any caller ever "fixed" that by falling back) profile traffic
    /// pointed straight at the location plane.
    ///
    /// Expressing that as `Option` rather than a `if relay_type != Profile`
    /// check at each write site moves the rule into the type system: a caller
    /// physically has no source value to pass for the profile category. The
    /// `match` is exhaustive, so a new [`RelayType`] variant must state its
    /// intent here or fail to compile. Pinned by
    /// `profile_relays_are_not_recorded_as_contaminated`.
    ///
    /// [`Self::Discovery`] is unreachable from here on purpose: the discovery
    /// plane is a process constant, not a user-editable relay category, so it
    /// has no [`RelayType`] to map from. It is recorded by
    /// [`super::CircleStorage::refresh_contamination_ledger`] instead.
    #[must_use]
    pub const fn for_relay_type(relay_type: RelayType) -> Option<Self> {
        match relay_type {
            RelayType::Inbox => Some(Self::Inbox),
            RelayType::KeyPackage => Some(Self::KeyPackage),
            // The profile plane is the thing being PROTECTED, never recorded.
            RelayType::Profile => None,
        }
    }
}

/// Canonicalizes a batch of relay URLs for the ledger, dropping rejects.
///
/// Each entry goes through [`crate::relay::normalize_relay_url`] — the single
/// canonical form shared with the storage layer's `UNIQUE (url, relay_type)`
/// index and with the profile pool's exclusion filter. Duplicates that collapse
/// to the same canonical URL are emitted once, preserving first-seen order.
///
/// # Why dropping unnormalizable entries is not a fail-open hole
///
/// An entry that cannot be canonicalized (empty, credential-bearing, plaintext
/// `ws://` outside the debug loopback opt-in, unparseable) is skipped rather
/// than recorded. That is safe precisely because
/// [`crate::profile::resolve_profile_pool`] drops the same inputs on the
/// *configured* side: a URL that cannot be normalized can never appear in the
/// usable profile pool either, so there is nothing for its missing ledger row
/// to fail to exclude.
#[must_use]
pub(crate) fn canonical_urls(urls: &[String]) -> Vec<String> {
    let mut out: Vec<String> = Vec::with_capacity(urls.len());
    for raw in urls {
        let Some(url) = crate::relay::normalize_relay_url(raw) else {
            continue;
        };
        if !out.contains(&url) {
            out.push(url);
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Every variant, spelled out. The exhaustive `match` below turns "added a
    /// variant but forgot this list" into a COMPILE error, so the iterating
    /// tests can never silently skip a new source.
    const ALL_SOURCES: [ContaminationSource; 5] = [
        ContaminationSource::CircleRouting,
        ContaminationSource::Inbox,
        ContaminationSource::Welcome,
        ContaminationSource::KeyPackage,
        ContaminationSource::Discovery,
    ];

    #[test]
    fn all_sources_is_exhaustive() {
        for s in ALL_SOURCES {
            match s {
                // Adding a variant breaks this match; extend ALL_SOURCES.
                ContaminationSource::CircleRouting
                | ContaminationSource::Inbox
                | ContaminationSource::Welcome
                | ContaminationSource::KeyPackage
                | ContaminationSource::Discovery => {}
            }
        }
        assert_eq!(ALL_SOURCES.len(), 5);
    }

    #[test]
    fn contamination_source_slugs_are_stable() {
        // Persisted in SQLite — changing a slug is a breaking schema change.
        assert_eq!(
            ContaminationSource::CircleRouting.as_str(),
            "circle_routing"
        );
        assert_eq!(ContaminationSource::Inbox.as_str(), "inbox");
        assert_eq!(ContaminationSource::Welcome.as_str(), "welcome");
        assert_eq!(ContaminationSource::KeyPackage.as_str(), "key_package");
        assert_eq!(ContaminationSource::Discovery.as_str(), "discovery");
    }

    #[test]
    fn slug_round_trips() {
        for s in ALL_SOURCES {
            assert_eq!(ContaminationSource::parse(s.as_str()), Some(s));
        }
        assert_eq!(ContaminationSource::parse("profile"), None);
        assert_eq!(ContaminationSource::parse(""), None);
        assert_eq!(ContaminationSource::parse("Inbox"), None); // case-sensitive
    }

    #[test]
    fn relay_type_mapping_covers_the_location_plane_only() {
        assert_eq!(
            ContaminationSource::for_relay_type(RelayType::Inbox),
            Some(ContaminationSource::Inbox)
        );
        assert_eq!(
            ContaminationSource::for_relay_type(RelayType::KeyPackage),
            Some(ContaminationSource::KeyPackage)
        );
        assert_eq!(
            ContaminationSource::for_relay_type(RelayType::Profile),
            None,
            "profile relays are the pool being protected — never ledger entries"
        );
    }

    #[test]
    fn canonical_urls_normalizes_and_deduplicates() {
        let input = vec![
            "wss://Relay.Example/".to_string(),
            "wss://relay.example".to_string(),
            "  wss://Other.Example  ".to_string(),
        ];
        assert_eq!(
            canonical_urls(&input),
            vec![
                "wss://relay.example".to_string(),
                "wss://other.example".to_string()
            ],
        );
    }

    #[test]
    fn canonical_urls_drops_unrecordable_entries() {
        // Rejects mirror `resolve_profile_pool`'s configured-side rejects, so a
        // dropped entry can never be a pool member that goes unexcluded.
        let input = vec![
            String::new(),
            "   ".to_string(),
            "not-a-url".to_string(),
            "wss://user:pass@relay.example".to_string(),
            "wss://good.example".to_string(),
        ];
        assert_eq!(
            canonical_urls(&input),
            vec!["wss://good.example".to_string()]
        );
        // The dropped spellings are equally unusable as pool entries.
        for bad in &input[..4] {
            assert_eq!(
                crate::profile::resolve_profile_pool(
                    &[
                        bad.clone(),
                        "wss://a.example".to_string(),
                        "wss://b.example".to_string(),
                        "wss://c.example".to_string(),
                    ],
                    &[],
                )
                .expect("3 valid survive")
                .len(),
                3
            );
        }
    }
}
