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

/// Prints the variant name only — the derived `Debug` printed `Storage`'s
/// `SQLite` payload, which can echo the pubkey a failing row was keyed by, into
/// every panic and `expect` message (Security Rule 15).
impl std::fmt::Debug for AvatarError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(match self {
            Self::InputTooLarge => "InputTooLarge",
            Self::UnsupportedFormat => "UnsupportedFormat",
            Self::Decode => "Decode",
            Self::Encode => "Encode",
            Self::TooLargeAfterEncode => "TooLargeAfterEncode",
            Self::Storage(_) => "Storage(<redacted>)",
            Self::InvalidInput => "InvalidInput",
        })
    }
}

/// Errors that can occur in the avatar pipeline and storage.
#[derive(Error)]
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

    /// A storage / database operation failed. The wrapped string comes from the
    /// `SQLite` layer, which can echo a bound parameter, so it is kept for
    /// programmatic use and rendered by neither `Display` nor `Debug`
    /// (Security Rule 15).
    #[error("avatar storage error")]
    Storage(String),

    /// Invalid input that is neither an image nor a storage failure (e.g. a
    /// malformed pubkey or group id at the boundary).
    #[error("invalid avatar input")]
    InvalidInput,
}

#[cfg(test)]
mod tests {
    use super::AvatarError;

    #[test]
    fn avatar_error_display_redacts_the_wrapped_storage_detail() {
        // `Display` reaches Dart through `From<AvatarError> for CircleError`, and
        // a SQLite message can echo the bound pubkey the row was keyed by.
        let pubkey_hex = "7f6e5d4c3b2a19087f6e5d4c3b2a19087f6e5d4c3b2a19087f6e5d4c3b2a1908";
        let err = AvatarError::Storage(format!("UNIQUE failed: avatars.{pubkey_hex}"));
        crate::assert_display_redacted!(
            &err,
            "AvatarError",
            marker = "avatar storage error",
            &[pubkey_hex, "UNIQUE failed"]
        );
        crate::assert_debug_redacted!(
            &err,
            "AvatarError",
            marker = "Storage",
            &[pubkey_hex, "UNIQUE failed"]
        );
        assert_eq!(err.to_string(), "avatar storage error");
    }

    #[test]
    fn every_other_variant_is_data_free_in_both_renderings() {
        // Each carries no payload at all, so there is nothing a rendering could
        // echo — pinned so a later variant cannot quietly gain one, through
        // either trait.
        let cases = [
            (AvatarError::InputTooLarge, "InputTooLarge"),
            (AvatarError::UnsupportedFormat, "UnsupportedFormat"),
            (AvatarError::Decode, "Decode"),
            (AvatarError::Encode, "Encode"),
            (AvatarError::TooLargeAfterEncode, "TooLargeAfterEncode"),
            (AvatarError::InvalidInput, "InvalidInput"),
        ];
        for (err, variant) in cases {
            let display = err.to_string();
            assert!(!display.is_empty());
            assert!(
                display.chars().all(|c| c.is_ascii_lowercase() || c == ' '),
                "a data-free message is fixed lowercase prose: {display}"
            );
            assert_eq!(format!("{err:?}"), variant);
        }
    }
}
