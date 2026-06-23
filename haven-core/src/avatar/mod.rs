//! Private profile-picture (avatar) subsystem — Milestone M1 (local, zero
//! network).
//!
//! This module implements the **local foundation** of Haven's private avatar
//! feature: the image pipeline (decode → strip metadata → downscale →
//! re-encode), decode-bomb defenses, content hashing, and thumbnail
//! derivation. Storage of the resulting blobs lives in
//! [`crate::circle::storage_avatar`] (it shares `CircleStorage`'s single
//! `SQLCipher` connection and lock-once discipline).
//!
//! # M2 — Encrypted broadcast (this module set)
//!
//! [`chunk`] and [`manifest`] add the kind-9 wire schema, fixed-count padded
//! chunking, and constant-time-verified reassembly that let an avatar travel
//! to other circle members over the existing kind-445 MLS transport. The
//! send/receive plumbing (`build_avatar_share`, `ingest_incoming_avatar_message`)
//! lives in [`crate::circle::manager`]; epoch re-share scheduling and
//! anti-entropy are deferred to M3 (Dart-layer orchestration).
//!
//! # Security
//!
//! `unsafe` code is forbidden in this module (it self-enforces the crate-wide
//! `deny(unsafe_code)`), all plaintext byte buffers are `Zeroizing`, and no
//! image bytes / content hashes / hex of image content are ever logged.

#![forbid(unsafe_code)]

pub mod chunk;
pub mod config;
pub mod error;
pub mod image;
pub mod manifest;

pub use chunk::{build_chunks, ReassembledAvatar, Reassembler, SerializedChunk};
pub use config::{
    avatar_reassembly_timeout_secs, DecodeLimits, AVATAR_CANONICAL_MAX_BYTES, AVATAR_CHUNK_COUNT,
    AVATAR_CHUNK_PAYLOAD_BYTES, AVATAR_CHUNK_WIRE_BYTES, AVATAR_JPEG_QUALITY_FLOOR,
    AVATAR_JPEG_QUALITY_START, AVATAR_MAX_ORPHAN_BYTES, AVATAR_MIME,
    AVATAR_REASSEMBLY_TIMEOUT_SECS, AVATAR_THUMB_EDGE_PX, AVATAR_THUMB_JPEG_QUALITY,
    AVATAR_TIER_EDGE_PX,
};
pub use error::{AvatarError, Result};
pub use image::{content_hash, process_inbound_avatar, process_own_avatar, ProcessedAvatar};
pub use manifest::{
    AvatarChunk, AvatarClear, AvatarInner, AvatarManifest, AVATAR_SCHEMA_VERSION, AVATAR_T_TAG,
    TYPE_CHUNK, TYPE_CLEAR, TYPE_MANIFEST,
};
