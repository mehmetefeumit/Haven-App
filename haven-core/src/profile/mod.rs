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

pub mod assignment;
pub mod blossom;
pub mod config;
pub mod consent;
pub mod error;
pub mod fetch;
pub mod merge;
pub mod parse;
pub mod picture_cache;
pub mod publish;
pub mod relay_pool;
pub mod types;

pub use assignment::{
    assigned_relay, assigned_relay_for_attempt, rank_relays, ProfileRelaySalt,
    PROFILE_MAX_RELAY_RANK,
};
pub use blossom::{
    allow_private_blossom_for_test, download_profile_picture, require_https, upload_profile_picture,
};
pub use config::{
    blossom_server, set_blossom_server_for_test, AVATAR_MIME, BLOSSOM_AUTH_EXPIRY_SECS,
    BLOSSOM_TIMEOUT, DEFAULT_BLOSSOM_SERVER, PROFILE_AUTHOR_FETCH_TIMEOUT, PROFILE_BATCH_DEADLINE,
    PROFILE_FETCH_TIMEOUT, PROFILE_INTER_REQ_JITTER_MS, PROFILE_MAX_INFLIGHT_RELAYS,
    PROFILE_PER_AUTHOR_LIMIT, PROFILE_PICTURE_MAX_DOWNLOAD_BYTES,
};
pub use consent::has_published_profile;
pub use error::{ProfileError, Result};
pub use fetch::{fetch_profiles_assigned, AssignedFetch};
pub use merge::{enforce_name_rule, merge_edits};
pub use parse::parse_newest_metadata;
pub use picture_cache::{picture_is_current, picture_sync_action, PictureSyncAction};
pub use publish::{
    build_blank_metadata_event, build_metadata_event, build_nip09_deletion, publish_metadata,
};
pub use relay_pool::{
    production_profile_relays, profile_relay_pool_default, resolve_profile_pool,
    set_profile_relays_for_test, PRODUCTION_PROFILE_RELAYS, PROFILE_POOL_MIN,
};
pub use types::{CachedProfile, ProfileEdits, ProfileMetadata, ProfilePicture, ProfileState};
