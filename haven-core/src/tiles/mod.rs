//! Encrypted map-tile cache (`tiles.db`).
//!
//! This module backs Haven's `SQLCipher`-encrypted on-disk cache of map tiles.
//! It deliberately diverges from the avatar/circle storage pattern (WAL on,
//! `cipher_memory_security` off, read/write connection split) — see
//! [`storage`] for the rationale, all of which is owner-approved.
//!
//! # Privacy
//!
//! Map imagery is public, but the *areas* it reveals (and the sequence in which
//! a user views them) are a movement trace. The cache is keyed on
//! `(style, z, x, y, retina)` only — never a URL or `api_key` — and the rows are
//! encrypted at rest. No coordinate, cached byte, or key ever appears in a
//! surfaced error (Security Rule #6 / #8); see [`error`].

mod error;
mod storage;

pub use error::{Result as TileCacheResult, TileCacheError};
pub use storage::{TileCacheStorage, TileEntry, COARSE_ACCESS_BUMP_MS};
