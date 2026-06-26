//! Error types for encrypted map-tile cache (`tiles.db`) operations.
//!
//! This module defines errors that can occur while opening, reading, writing,
//! evicting, or wiping the dedicated `SQLCipher`-encrypted tile cache.
//!
//! # Privacy
//!
//! Tile coordinates `(z, x, y)`, the cached PNG bytes, and the database
//! encryption key are all sensitive: a single z15 coordinate pins a location
//! to roughly a kilometre, and a sequence of them is a movement trace. The
//! `Display` and `Debug` impls in this module are written by hand so that
//! **no** coordinate, byte buffer, or key material can ever appear in a
//! surfaced error string (Security Rule #6 / #8). Only fixed, generic
//! messages are emitted.

use std::fmt;

/// Error type for tile-cache operations.
///
/// Every variant is either data-free or carries only a storage/IO string that
/// originates from the `SQLite`/filesystem layer (never tile coordinates,
/// cached bytes, or the encryption key).
pub enum TileCacheError {
    /// Storage operation failed (lock poisoning, `SQLite` failure surfaced as a
    /// generic message). The contained string never carries tile coordinates,
    /// cached bytes, or key material.
    Storage(String),

    /// The supplied encryption key was not a 64-character hex string.
    ///
    /// Data-free so the rejected key bytes can never be reconstructed from the
    /// error.
    InvalidKey,

    /// The database could not be decrypted with the supplied key.
    ///
    /// Surfaced when a `SELECT` against `sqlite_master` fails immediately after
    /// `PRAGMA key`, which `SQLCipher` reports for a wrong key or a corrupt
    /// header. Triggers the FFI layer's disposable-cache recovery.
    DecryptFailed,

    /// The on-disk schema version did not match the one this build expects.
    ///
    /// A future build may have bumped `PRAGMA user_version`; rather than risk
    /// reading an incompatible layout, the FFI layer drops and recreates the
    /// cache. Data-free.
    SchemaVersionMismatch,

    /// A filesystem operation failed (e.g. deleting a sidecar during recovery).
    ///
    /// The contained string is an `std::io` message and never carries tile
    /// coordinates or cached bytes.
    Io(String),
}

impl fmt::Display for TileCacheError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        // Fixed, generic messages only — never interpolate coordinates, bytes,
        // or key material (Security Rule #8). The `Storage`/`Io` strings are
        // sourced from the SQLite/filesystem layers, which do not see tile
        // coordinates or cached bytes.
        match self {
            Self::Storage(_) => f.write_str("tile cache storage error"),
            Self::InvalidKey => f.write_str("tile cache key invalid"),
            Self::DecryptFailed => f.write_str("tile cache decrypt failed"),
            Self::SchemaVersionMismatch => f.write_str("tile cache schema version mismatch"),
            Self::Io(_) => f.write_str("tile cache io error"),
        }
    }
}

impl fmt::Debug for TileCacheError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        // Mirror Display: the variant name alone is safe, but the wrapped
        // strings must NOT be printed via the derived Debug because a future
        // SQLite message could conceivably embed a value passed in a query.
        // Keeping Debug as opaque as Display closes that gap.
        match self {
            Self::Storage(_) => f.write_str("Storage(<redacted>)"),
            Self::InvalidKey => f.write_str("InvalidKey"),
            Self::DecryptFailed => f.write_str("DecryptFailed"),
            Self::SchemaVersionMismatch => f.write_str("SchemaVersionMismatch"),
            Self::Io(_) => f.write_str("Io(<redacted>)"),
        }
    }
}

impl std::error::Error for TileCacheError {}

impl From<rusqlite::Error> for TileCacheError {
    fn from(err: rusqlite::Error) -> Self {
        // Reduce to a generic storage message: rusqlite's Display can echo back
        // bound parameter values in some error shapes, so we never forward it
        // verbatim. The category alone is enough for diagnostics.
        let _ = err;
        Self::Storage("sqlite error".to_string())
    }
}

impl From<std::io::Error> for TileCacheError {
    fn from(err: std::io::Error) -> Self {
        Self::Io(err.kind().to_string())
    }
}

/// Result type alias for tile-cache operations.
pub type Result<T> = std::result::Result<T, TileCacheError>;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn display_is_generic_for_every_variant() {
        let cases = [
            (
                TileCacheError::Storage("z15/16384/10000".to_string()),
                "tile cache storage error",
            ),
            (TileCacheError::InvalidKey, "tile cache key invalid"),
            (TileCacheError::DecryptFailed, "tile cache decrypt failed"),
            (
                TileCacheError::SchemaVersionMismatch,
                "tile cache schema version mismatch",
            ),
            (
                TileCacheError::Io("14/9000/5000".to_string()),
                "tile cache io error",
            ),
        ];
        for (err, expected) in cases {
            assert_eq!(err.to_string(), expected);
        }
    }

    #[test]
    fn display_and_debug_never_leak_wrapped_payload() {
        // A coordinate-shaped payload smuggled into a Storage/Io error must not
        // survive to either Display or Debug output.
        let coord = "z15/16384/10000";
        let storage = TileCacheError::Storage(coord.to_string());
        let io = TileCacheError::Io(coord.to_string());
        for err in [storage, io] {
            let display = err.to_string();
            let debug = format!("{err:?}");
            assert!(
                !display.contains(coord),
                "Display must not leak the wrapped payload: {display}"
            );
            assert!(
                !debug.contains(coord),
                "Debug must not leak the wrapped payload: {debug}"
            );
        }
    }

    #[test]
    fn debug_reports_variant_names_without_payload() {
        assert_eq!(format!("{:?}", TileCacheError::InvalidKey), "InvalidKey");
        assert_eq!(
            format!("{:?}", TileCacheError::DecryptFailed),
            "DecryptFailed"
        );
        assert_eq!(
            format!("{:?}", TileCacheError::SchemaVersionMismatch),
            "SchemaVersionMismatch"
        );
        assert_eq!(
            format!("{:?}", TileCacheError::Storage("x".to_string())),
            "Storage(<redacted>)"
        );
        assert_eq!(
            format!("{:?}", TileCacheError::Io("x".to_string())),
            "Io(<redacted>)"
        );
    }

    #[test]
    fn implements_std_error() {
        fn assert_error<E: std::error::Error>() {}
        assert_error::<TileCacheError>();
    }

    #[test]
    fn io_error_conversion_uses_kind_not_path() {
        let io = std::io::Error::new(std::io::ErrorKind::NotFound, "/secret/path/tiles.db");
        let err = TileCacheError::from(io);
        let display = err.to_string();
        assert!(!display.contains("/secret/path"));
        assert_eq!(display, "tile cache io error");
    }
}
