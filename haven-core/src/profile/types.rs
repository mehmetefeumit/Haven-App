//! Value types for the public-profile module.
//!
//! These types wrap the pinned `nostr` crate's [`Metadata`] and describe the
//! rows the cache layer ([`crate::circle::storage_profile`]) persists. Nothing
//! here performs I/O; the storage glue lives outside the module boundary so
//! `profile/` never imports `crate::circle`.

use std::fmt;

use nostr::Metadata;
use serde_json::Value;
use zeroize::Zeroizing;

use crate::directory::sanitize_display_name;

/// A thin, read-oriented wrapper over the Nostr kind-0 [`Metadata`] object.
///
/// Wrapping (rather than aliasing) lets the profile module expose a small,
/// intentional accessor surface — including the deprecated-field-aware
/// [`resolve_display_name`](Self::resolve_display_name) — while still
/// round-tripping every unknown field through `Metadata.custom`
/// (`#[serde(flatten)]`), so an edit-republish never drops metadata written by
/// another client.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct ProfileMetadata {
    inner: Metadata,
}

impl ProfileMetadata {
    /// Wraps an existing [`Metadata`].
    #[must_use]
    pub const fn from_metadata(inner: Metadata) -> Self {
        Self { inner }
    }

    /// Borrows the underlying [`Metadata`] (e.g. for `EventBuilder::metadata`).
    #[must_use]
    pub const fn as_metadata(&self) -> &Metadata {
        &self.inner
    }

    /// Consumes the wrapper, returning the underlying [`Metadata`].
    #[must_use]
    pub fn into_metadata(self) -> Metadata {
        self.inner
    }

    /// The NIP-01 `name` field, if present.
    #[must_use]
    pub fn name(&self) -> Option<&str> {
        self.inner.name.as_deref()
    }

    /// The NIP-24 `display_name` field, if present.
    #[must_use]
    pub fn display_name(&self) -> Option<&str> {
        self.inner.display_name.as_deref()
    }

    /// The `picture` URL field, if present.
    #[must_use]
    pub fn picture(&self) -> Option<&str> {
        self.inner.picture.as_deref()
    }

    /// The `about` field, if present.
    #[must_use]
    pub fn about(&self) -> Option<&str> {
        self.inner.about.as_deref()
    }

    /// Resolves the best human-readable name using the standard precedence:
    /// `display_name` → `name` → deprecated `custom["displayName"]` →
    /// deprecated `custom["username"]` → `None`.
    ///
    /// Empty / whitespace-only values are skipped so a blank field falls
    /// through to the next candidate. The deprecated keys are read defensively
    /// (they land in `custom` via `#[serde(flatten)]`) and are never written
    /// back.
    #[must_use]
    pub fn resolve_display_name(&self) -> Option<&str> {
        non_empty(self.inner.display_name.as_deref())
            .or_else(|| non_empty(self.inner.name.as_deref()))
            .or_else(|| self.custom_str("displayName"))
            .or_else(|| self.custom_str("username"))
    }

    /// Reads a non-empty string value from the `custom` map.
    fn custom_str(&self, key: &str) -> Option<&str> {
        non_empty(self.inner.custom.get(key).and_then(Value::as_str))
    }

    /// Returns a copy whose renderable name fields have been passed through
    /// [`sanitize_display_name`].
    ///
    /// Covers exactly the four fields
    /// [`resolve_display_name`](Self::resolve_display_name) can return — a
    /// sanitizer that stopped at `display_name` and `name` would be bypassed by
    /// a kind-0 that carries its payload in the deprecated keys instead.
    ///
    /// A deprecated key whose value sanitizes to nothing is emptied rather than
    /// removed: `custom` is what makes an edit-republish preserve fields
    /// written by other clients, so this must not become a path that deletes
    /// one. An empty string is already skipped by the precedence chain.
    ///
    /// `about` is deliberately untouched — it is never rendered (member-picker
    /// plan §7.2) — as are `website`, `nip05` and the lightning fields, which
    /// are identifiers rather than prose.
    #[must_use]
    pub fn sanitized(&self) -> Self {
        let mut inner = self.inner.clone();
        inner.display_name = sanitize_display_name(inner.display_name.take());
        inner.name = sanitize_display_name(inner.name.take());
        for key in ["displayName", "username"] {
            let Some(value) = inner.custom.get_mut(key) else {
                continue;
            };
            let Some(raw) = value.as_str() else { continue };
            let cleaned = sanitize_display_name(Some(raw.to_string())).unwrap_or_default();
            *value = Value::String(cleaned);
        }
        Self { inner }
    }
}

/// Returns the string only if it is present and not whitespace-only.
fn non_empty(value: Option<&str>) -> Option<&str> {
    value.filter(|s| !s.trim().is_empty())
}

/// Tri-state knowledge of a pubkey's public profile.
///
/// `Unknown` distinguishes "we have never successfully fetched a kind-0 for
/// this pubkey" (so a refetch is warranted) from `Known`, which includes the
/// case of a fetched-but-empty `{}` kind-0 (the user published a deliberately
/// blank profile — do not keep hammering the relays for it).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ProfileState {
    /// No kind-0 has been successfully resolved for this pubkey yet.
    Unknown,
    /// A kind-0 was resolved (possibly an empty `{}` object).
    Known,
}

impl ProfileState {
    /// Maps to the integer stored in the `profiles.state` column
    /// (`0 = Unknown`, `1 = Known`).
    #[must_use]
    pub const fn as_db_value(self) -> i64 {
        match self {
            Self::Unknown => 0,
            Self::Known => 1,
        }
    }

    /// Maps back from the stored integer; any value other than `1` is treated
    /// as `Unknown` (fail-safe toward refetch).
    #[must_use]
    pub const fn from_db_value(value: i64) -> Self {
        if value == 1 {
            Self::Known
        } else {
            Self::Unknown
        }
    }
}

/// A cached profile row, keyed by pubkey (hex) — never by circle/group.
#[derive(Clone, Debug)]
pub struct CachedProfile {
    /// Lowercase hex of the profile owner's Nostr pubkey.
    pub pubkey_hex: String,
    /// The resolved metadata (empty default when `state == Unknown`).
    pub metadata: ProfileMetadata,
    /// Whether a kind-0 has been resolved for this pubkey.
    pub state: ProfileState,
    /// `created_at` of the winning kind-0 event (`0` when unknown) — the
    /// newer-wins gate for cache updates.
    pub event_created_at: i64,
    /// Unix seconds when this row was last written — the TTL base.
    pub fetched_at: i64,
}

/// A processed profile picture: the source URL, its content-addressed sha256,
/// and the re-encoded render tiers.
///
/// The canonical (full-res) and thumbnail byte buffers are wrapped in
/// [`Zeroizing`] to mirror `ProcessedAvatar` — the image pipeline never weakens
/// its zeroization guarantees even though public-profile pictures are, by
/// design, publicly visible.
pub struct ProfilePicture {
    /// The public picture URL (Blossom or other https host). Never crosses the
    /// FFI boundary — only the decoded bytes do.
    pub url: String,
    /// Lowercase hex of the sha256 over the exact downloaded bytes (Blossom's
    /// content-address commitment).
    pub sha256_hex: String,
    /// Re-encoded canonical (full-res) render bytes.
    pub canonical: Zeroizing<Vec<u8>>,
    /// Re-encoded thumbnail render bytes (map markers / member tiles).
    pub thumbnail: Zeroizing<Vec<u8>>,
}

impl fmt::Debug for ProfilePicture {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        // Redact the byte buffers and the sha256 (a long hex run); keep the URL
        // scheme/host visible for diagnostics but not the bytes.
        f.debug_struct("ProfilePicture")
            .field("url", &self.url)
            .field("sha256_hex", &"<redacted>")
            .field("canonical", &"<redacted>")
            .field("thumbnail", &"<redacted>")
            .finish()
    }
}

/// A sparse set of user-initiated edits to the own profile.
///
/// `None` means "leave this field untouched"; `Some("")` (or a whitespace-only
/// string) means "clear this field". [`crate::profile::merge::merge_edits`]
/// applies these against the freshest fetched metadata so unknown fields (and
/// untouched known fields) are preserved on republish.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct ProfileEdits {
    /// New `display_name`, or clear when `Some("")`.
    pub display_name: Option<String>,
    /// New `about`, or clear when `Some("")`.
    pub about: Option<String>,
    /// New `picture` URL, or clear when `Some("")`.
    pub picture: Option<String>,
}

#[cfg(test)]
mod tests {
    use super::*;
    use nostr::JsonUtil;

    fn md_from(json: &str) -> ProfileMetadata {
        ProfileMetadata::from_metadata(Metadata::from_json(json).expect("valid json"))
    }

    #[test]
    fn accessors_expose_standard_fields() {
        let md = md_from(
            r#"{"name":"alice","display_name":"Alice","about":"hi","picture":"https://x/y.jpg"}"#,
        );
        assert_eq!(md.name(), Some("alice"));
        assert_eq!(md.display_name(), Some("Alice"));
        assert_eq!(md.about(), Some("hi"));
        assert_eq!(md.picture(), Some("https://x/y.jpg"));
    }

    #[test]
    fn sanitized_cleans_every_field_the_name_precedence_can_return() {
        let md = md_from(
            r#"{"display_name":"Ali\u202Ece","name":"bo\u200Bb",
                "displayName":"ca\u2066rol","username":"da\uFEFFve",
                "about":"bio\u202E","website":"https://example.test/x"}"#,
        );
        let clean = md.sanitized();

        assert_eq!(clean.display_name(), Some("Alice"));
        assert_eq!(clean.name(), Some("bob"));
        assert_eq!(clean.custom_str("displayName"), Some("carol"));
        assert_eq!(clean.custom_str("username"), Some("dave"));

        // Deliberately untouched: `about` is never rendered, and `website` is
        // an identifier rather than prose.
        assert_eq!(clean.about(), Some("bio\u{202E}"));
        assert_eq!(
            clean.as_metadata().website.as_deref(),
            Some("https://example.test/x")
        );
    }

    #[test]
    fn sanitized_empties_an_unrenderable_deprecated_key_without_deleting_it() {
        let md = md_from(r#"{"displayName":"\u202E","username":42,"canary":"keep"}"#);
        let clean = md.sanitized();

        assert!(
            clean.as_metadata().custom.contains_key("displayName"),
            "the key must survive so a republish does not drop another client's field"
        );
        assert_eq!(clean.resolve_display_name(), None);
        // A non-string value is left exactly as it arrived — there is no name
        // in it to sanitize.
        assert_eq!(
            clean
                .as_metadata()
                .custom
                .get("username")
                .and_then(Value::as_i64),
            Some(42)
        );
        assert_eq!(clean.custom_str("canary"), Some("keep"));
    }

    #[test]
    fn sanitized_is_idempotent() {
        let md = md_from(r#"{"display_name":"  Ada\u202E\nLovelace  ","name":"ada"}"#);
        let once = md.sanitized();
        assert_eq!(once.display_name(), Some("Ada Lovelace"));
        assert_eq!(once.sanitized(), once);
    }

    #[test]
    fn resolve_display_name_prefers_display_then_name() {
        let both = md_from(r#"{"name":"alice","display_name":"Alice B"}"#);
        assert_eq!(both.resolve_display_name(), Some("Alice B"));

        let name_only = md_from(r#"{"name":"alice"}"#);
        assert_eq!(name_only.resolve_display_name(), Some("alice"));
    }

    #[test]
    fn resolve_display_name_skips_blank_display_name() {
        let md = md_from(r#"{"name":"alice","display_name":"   "}"#);
        assert_eq!(md.resolve_display_name(), Some("alice"));
    }

    #[test]
    fn deprecated_displayname_username_resolve() {
        // Deprecated camelCase keys land in `custom` and are read defensively.
        let dn = md_from(r#"{"displayName":"Legacy DN"}"#);
        assert_eq!(dn.resolve_display_name(), Some("Legacy DN"));

        let un = md_from(r#"{"username":"legacy_un"}"#);
        assert_eq!(un.resolve_display_name(), Some("legacy_un"));

        // Standard fields still outrank the deprecated ones.
        let mixed = md_from(r#"{"display_name":"Modern","displayName":"Legacy"}"#);
        assert_eq!(mixed.resolve_display_name(), Some("Modern"));
    }

    #[test]
    fn resolve_display_name_none_when_absent() {
        let md = md_from("{}");
        assert_eq!(md.resolve_display_name(), None);
    }

    #[test]
    fn profile_state_db_round_trip() {
        assert_eq!(ProfileState::Unknown.as_db_value(), 0);
        assert_eq!(ProfileState::Known.as_db_value(), 1);
        assert_eq!(ProfileState::from_db_value(0), ProfileState::Unknown);
        assert_eq!(ProfileState::from_db_value(1), ProfileState::Known);
        // Any unexpected value fails safe toward refetch.
        assert_eq!(ProfileState::from_db_value(42), ProfileState::Unknown);
    }

    #[test]
    fn profile_picture_debug_redacts_bytes() {
        let pic = ProfilePicture {
            url: "https://blossom.example/abc".to_string(),
            sha256_hex: "deadbeef".repeat(8),
            canonical: Zeroizing::new(vec![1, 2, 3]),
            thumbnail: Zeroizing::new(vec![4, 5, 6]),
        };
        let debug = format!("{pic:?}");
        assert!(debug.contains("https://blossom.example/abc"));
        assert!(!debug.contains("deadbeef"));
        assert!(!debug.contains('1'));
    }
}
