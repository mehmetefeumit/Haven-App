//! Image-sanitization pipeline for public profile pictures.
//!
//! This module is the pure, local image pipeline: decode → strip metadata
//! (EXIF/GPS/XMP) → center-crop → downscale → re-encode to JPEG, with
//! decode-bomb defenses, content hashing, and thumbnail derivation. It has no
//! network path and no group/MLS awareness.
//!
//! After the public-profile migration (see
//! `docs/PUBLIC_PROFILE_MIGRATION_PLAN.md`) the old MLS in-group avatar
//! broadcast (padded kind-9 chunk/manifest wire schema and per-sender
//! reassembly) is gone; the sanitizer that survives here is reused by
//! [`crate::profile::blossom`] to re-encode both the user's own picture before
//! a public Blossom upload and any untrusted picture downloaded from a member's
//! chosen host.
//!
//! # Security
//!
//! `unsafe` code is forbidden in this module (it self-enforces the crate-wide
//! `deny(unsafe_code)`), all plaintext byte buffers are `Zeroizing`, and no
//! image bytes / content hashes / hex of image content are ever logged.

#![forbid(unsafe_code)]

pub mod config;
pub mod error;
pub mod image;

pub use config::{
    DecodeLimits, AVATAR_CANONICAL_MAX_BYTES, AVATAR_JPEG_QUALITY_FLOOR, AVATAR_JPEG_QUALITY_START,
    AVATAR_MIME, AVATAR_THUMB_EDGE_PX, AVATAR_THUMB_JPEG_QUALITY, AVATAR_TIER_EDGE_PX,
};
pub use error::{AvatarError, Result};
pub use image::{content_hash, process_inbound_avatar, process_own_avatar, ProcessedAvatar};
