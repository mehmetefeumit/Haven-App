//! Public Nostr profiles (kind-0 metadata + Blossom pictures).
//!
//! This module implements Haven's migration to standard public Nostr profiles:
//! kind-0 metadata (`name` / `display_name` / `picture` / `about`) published
//! under the user's Nostr identity key, profile pictures hosted on a Blossom
//! server, and member profiles resolved from relays by pubkey. It is an
//! owner-directed reversal of Haven's "no public profiles" posture: publishing
//! is **public-by-default** (unconditional on save, no consent toggle;
//! disclosed to the user in onboarding + the Identity settings page), matching
//! the White Noise reference app. See `docs/PUBLIC_PROFILE_MIGRATION_PLAN.md`.
//!
//! # Import boundary (load-bearing — CI-enforced)
//!
//! To structurally guarantee key separation (kind-0 / kind-24242 are signed by
//! the **Nostr identity key only**, never the MLS signing key or an
//! exporter-secret-derived key) and group-identifier privacy, this module has a
//! hard import boundary. No source file under `profile/` may import any of:
//!
//! * the circle module (`crate::circle`) — the cache glue instead lives in
//!   [`crate::circle::storage_profile`] as an extension of `CircleStorage`, so a
//!   `ProfileStore` here would violate the boundary. `profile/` only defines the
//!   row *types*.
//! * the MLS manager module (the `crate::nostr` MLS layer) — the shared
//!   [`redact_hex_sequences`] helper was relocated to [`crate::util`] precisely
//!   so [`error`] can redact without reaching into it.
//! * the MDK / exporter-secret layers — no MLS/MDK handle is ever reachable
//!   from here.
//!
//! Importing `crate::avatar` (pure image sanitization), `crate::relay`
//! (discovery-plane read relays / NIP-65 extraction), `nostr`, and
//! `crate::util` is permitted.
//!
//! [`redact_hex_sequences`]: crate::util::redact_hex_sequences

pub mod blossom;
pub mod config;
pub mod consent;
pub mod error;
pub mod fetch;
pub mod merge;
pub mod parse;
pub mod picture_cache;
pub mod publish;
pub mod types;

pub use blossom::{
    allow_private_blossom_for_test, download_profile_picture, require_https, upload_profile_picture,
};
pub use config::{
    blossom_server, profile_read_relays, profile_write_relays, self_merge_base_relays,
    set_blossom_server_for_test, AVATAR_MIME, BLOSSOM_AUTH_EXPIRY_SECS, BLOSSOM_TIMEOUT,
    DEFAULT_BLOSSOM_SERVER, PROFILE_FETCH_MAX_AUTHORS, PROFILE_FETCH_TIMEOUT,
    PROFILE_PICTURE_MAX_DOWNLOAD_BYTES, PROFILE_TTL_SECS,
};
pub use consent::has_published_profile;
pub use error::{ProfileError, Result};
pub use fetch::fetch_profiles;
pub use merge::{enforce_name_rule, merge_edits};
pub use parse::parse_newest_metadata;
pub use picture_cache::{picture_is_current, picture_sync_action, PictureSyncAction};
pub use publish::{
    build_blank_metadata_event, build_metadata_event, build_nip09_deletion, publish_metadata,
    resolve_write_relays,
};
pub use types::{CachedProfile, ProfileEdits, ProfileMetadata, ProfilePicture, ProfileState};
