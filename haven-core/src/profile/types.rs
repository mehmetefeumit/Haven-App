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
