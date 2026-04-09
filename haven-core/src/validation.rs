//! FFI-boundary input validation helpers.
//!
//! These functions exist as a single place to validate untrusted data
//! flowing from the Flutter/Dart side into `haven-core`. Keeping them
//! here (instead of in `rust_builder`) makes them unit-testable from
//! `cargo test -p haven-core`.
//!
//! All validators return `Result<T, String>` — the `String` error type
//! matches the FFI boundary convention (see the `*Ffi` wrappers in
//! `rust_builder::api`). Error messages never contain secret material.

/// Parses a byte slice as a 32-byte `nostr_group_id`.
///
/// # Errors
///
/// Returns `Err` with a descriptive message if the slice is not
/// exactly 32 bytes long.
pub fn parse_nostr_group_id(bytes: &[u8]) -> Result<[u8; 32], String> {
    <[u8; 32]>::try_from(bytes).map_err(|_| {
        format!(
            "Invalid nostr_group_id length: expected 32, got {}",
            bytes.len()
        )
    })
}

/// Validates a hex-encoded Nostr public key.
///
/// Accepts both upper- and lowercase hex so callers that happen to
/// normalize case upstream don't accidentally get rejected here.
/// Callers that need a canonical form should run [`normalize_pubkey_hex`]
/// on the validated input.
///
/// # Errors
///
/// Returns `Err` if `value` is not exactly 64 characters or contains
/// any non-hex byte.
pub fn validate_pubkey_hex(value: &str, field: &str) -> Result<(), String> {
    if value.len() != 64 {
        return Err(format!(
            "Invalid {field} length: expected 64 hex chars, got {}",
            value.len()
        ));
    }
    if !value.bytes().all(|b: u8| b.is_ascii_hexdigit()) {
        return Err(format!("Invalid {field}: must be hexadecimal"));
    }
    Ok(())
}

/// Returns the lowercase form of a validated hex pubkey.
///
/// Call [`validate_pubkey_hex`] first — this function does not
/// re-validate its input and will happily lowercase anything.
#[must_use]
pub fn normalize_pubkey_hex(value: &str) -> String {
    value.to_ascii_lowercase()
}

/// Validates a precision label produced by
/// [`crate::location::LocationPrecision::label`].
///
/// # Errors
///
/// Returns `Err` if `value` is not one of `"Private"`, `"Standard"`,
/// or `"Enhanced"`.
pub fn validate_precision_label(value: &str) -> Result<(), String> {
    crate::location::LocationPrecision::from_label(value).map(|_| ())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_valid_nostr_group_id() {
        let bytes = [0u8; 32];
        let parsed = parse_nostr_group_id(&bytes).expect("32 bytes is valid");
        assert_eq!(parsed, bytes);
    }

    #[test]
    fn rejects_wrong_length_nostr_group_id() {
        assert!(parse_nostr_group_id(&[0u8; 16]).is_err());
        assert!(parse_nostr_group_id(&[0u8; 33]).is_err());
        assert!(parse_nostr_group_id(&[]).is_err());
    }

    #[test]
    fn accepts_lowercase_pubkey_hex() {
        let pk = "a".repeat(64);
        assert!(validate_pubkey_hex(&pk, "pubkey").is_ok());
    }

    #[test]
    fn accepts_uppercase_pubkey_hex() {
        let pk = "A".repeat(64);
        assert!(validate_pubkey_hex(&pk, "pubkey").is_ok());
    }

    #[test]
    fn accepts_mixed_case_pubkey_hex() {
        let pk = format!("{}{}", "a".repeat(32), "A".repeat(32));
        assert!(validate_pubkey_hex(&pk, "pubkey").is_ok());
    }

    #[test]
    fn rejects_short_pubkey_hex() {
        let pk = "a".repeat(63);
        assert!(validate_pubkey_hex(&pk, "pubkey").is_err());
    }

    #[test]
    fn rejects_non_hex_pubkey() {
        let pk = "z".repeat(64);
        assert!(validate_pubkey_hex(&pk, "pubkey").is_err());
    }

    #[test]
    fn normalizes_pubkey_hex_to_lowercase() {
        let upper: String = "ABCD".repeat(16);
        assert_eq!(normalize_pubkey_hex(&upper), "abcd".repeat(16));
    }

    #[test]
    fn accepts_canonical_precision_labels() {
        assert!(validate_precision_label("Private").is_ok());
        assert!(validate_precision_label("Standard").is_ok());
        assert!(validate_precision_label("Enhanced").is_ok());
    }

    #[test]
    fn rejects_unknown_precision_labels() {
        assert!(validate_precision_label("private").is_err());
        assert!(validate_precision_label("").is_err());
        assert!(validate_precision_label("Extreme").is_err());
    }

    #[test]
    fn precision_label_round_trip() {
        use crate::location::LocationPrecision;
        for p in [
            LocationPrecision::Private,
            LocationPrecision::Standard,
            LocationPrecision::Enhanced,
        ] {
            let label = p.label();
            assert_eq!(
                LocationPrecision::from_label(label).expect("canonical label"),
                p
            );
        }
    }
}
