//! Error types for the avatar subsystem.
//!
//! All variants are deliberately data-light: their `Display`/`Debug` output
//! must never echo image bytes, content hashes, hex of image content, MLS
//! group IDs, or any other sensitive material (Security Rule 6 / 8). Where a
//! variant wraps a lower-level error string, that string is sourced from
//! storage/IO only — never from image content — and the FFI boundary further
//! sanitizes everything via `redact_hex_sequences`.

use thiserror::Error;

/// Result alias for avatar operations.
pub type Result<T> = std::result::Result<T, AvatarError>;

/// Errors that can occur in the avatar pipeline and storage.
#[derive(Error, Debug)]
pub enum AvatarError {
    /// The input exceeded the configured pre-decode byte-size cap. The actual
    /// size is intentionally omitted to avoid any side channel on the content.
    #[error("avatar input too large")]
    InputTooLarge,

    /// The input did not match the JPEG/PNG/WebP magic-byte allowlist (e.g.
    /// SVG, GIF, or arbitrary data). The detected format is intentionally not
    /// reported.
    #[error("unsupported avatar image format")]
    UnsupportedFormat,

    /// Decoding failed (corrupt image, exceeded decode limits, or an
    /// unsupported internal feature). The underlying decoder message is NOT
    /// surfaced — it could echo attacker-controlled bytes.
    #[error("failed to decode avatar image")]
    Decode,

    /// Re-encoding the canonical or thumbnail image failed.
    #[error("failed to encode avatar image")]
    Encode,

    /// The canonical encode could not be brought under the byte budget even at
    /// the lowest configured quality.
    #[error("avatar could not be compressed within the size budget")]
    TooLargeAfterEncode,

    /// A storage / database operation failed. The wrapped string comes from
    /// the `SQLite` layer (never image content) and is further redacted at the
    /// FFI boundary.
    #[error("avatar storage error: {0}")]
    Storage(String),

    /// Invalid input that is neither an image nor a storage failure (e.g. a
    /// malformed pubkey or group id at the boundary).
    #[error("invalid avatar input")]
    InvalidInput,
}
