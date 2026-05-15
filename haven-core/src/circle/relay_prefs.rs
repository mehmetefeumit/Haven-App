//! User-configurable relay preference types.
//!
//! This module defines the small types used by Haven's customizable relay
//! list feature. Relay preferences are stored per-user in the `SQLCipher`
//! `circles.db` (see [`crate::circle::storage_relay_prefs`]) and used by
//! the publish helpers in [`crate::relay::publishers`].
//!
//! # Categories
//!
//! Per the Marmot Protocol and NIP-17 / MIP-00, Haven distinguishes two
//! independent relay categories:
//!
//! * [`RelayType::Inbox`] — kind 10050 (NIP-17) — where Welcomes
//!   (gift-wrapped kind 1059) are delivered to this user.
//! * [`RelayType::KeyPackage`] — kind 10051 (MIP-00) — where this user's
//!   `KeyPackage` events (kind 30443/443) live.
//!
//! Haven intentionally does **not** publish kind 10002 (NIP-65). Haven is
//! single-purpose — it does not publish kind 0/1/3 events — so a NIP-65
//! list would expand the user's relay-side metadata footprint without
//! serving any Haven feature.

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
            _ => None,
        }
    }

    /// Returns the Nostr event kind associated with this category.
    ///
    /// * [`RelayType::Inbox`] → [`Kind::InboxRelays`] (10050)
    /// * [`RelayType::KeyPackage`] → [`Kind::MlsKeyPackageRelays`] (10051)
    #[must_use]
    pub const fn to_kind(self) -> Kind {
        match self {
            Self::Inbox => Kind::InboxRelays,
            Self::KeyPackage => Kind::MlsKeyPackageRelays,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn as_str_round_trip() {
        for t in [RelayType::Inbox, RelayType::KeyPackage] {
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
    }

    #[test]
    fn to_kind_maps_correctly() {
        assert_eq!(RelayType::Inbox.to_kind(), Kind::InboxRelays);
        assert_eq!(RelayType::KeyPackage.to_kind(), Kind::MlsKeyPackageRelays);
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
