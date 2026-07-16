//! Small, dependency-free utility helpers shared across modules.
//!
//! This module deliberately imports nothing from `crate::circle`,
//! `crate::nostr::mls`, or the MLS/MDK layer: it holds pure functions that
//! several subsystems (MLS error surfacing, live-sync, the public-profile
//! module) need without creating a dependency edge into any of those modules.

/// Redacts long hex sequences from error/log messages to prevent leakage of
/// MLS group IDs, key material, sha256 digests, or full-length pubkeys.
///
/// Replaces any contiguous ASCII-hex run of 16+ characters with `[REDACTED]`.
/// Runs shorter than 16 characters (e.g. short error codes) are preserved.
/// This is the single canonical redactor used by every error type's `Debug`
/// impl and by the FFI boundary (Security Rule 6 / 8).
#[must_use]
pub fn redact_hex_sequences(msg: &str) -> String {
    let bytes = msg.as_bytes();
    let mut result = String::with_capacity(msg.len());
    let mut i = 0;

    while i < bytes.len() {
        if bytes[i].is_ascii_hexdigit() {
            let start = i;
            while i < bytes.len() && bytes[i].is_ascii_hexdigit() {
                i += 1;
            }
            if i - start >= 16 {
                result.push_str("[REDACTED]");
            } else {
                result.push_str(&msg[start..i]);
            }
        } else {
            result.push(bytes[i] as char);
            i += 1;
        }
    }

    result
}

#[cfg(test)]
mod tests {
    use super::redact_hex_sequences;

    #[test]
    fn redact_hex_sequences_preserves_short_hex() {
        assert_eq!(
            redact_hex_sequences("error code abcd1234"),
            "error code abcd1234"
        );
    }

    #[test]
    fn redact_hex_sequences_redacts_long_hex() {
        let msg = "group 0123456789abcdef0123456789abcdef not found";
        let redacted = redact_hex_sequences(msg);
        assert_eq!(redacted, "group [REDACTED] not found");
        assert!(!redacted.contains("0123456789"));
    }

    #[test]
    fn redact_hex_sequences_handles_no_hex() {
        assert_eq!(
            redact_hex_sequences("plain error message"),
            "plain error message"
        );
    }

    #[test]
    fn redact_hex_sequences_redacts_trailing_hex() {
        let msg = "error: 0123456789abcdef0123456789abcdef";
        assert_eq!(redact_hex_sequences(msg), "error: [REDACTED]");
    }

    #[test]
    fn redact_hex_sequences_preserves_15_char_hex() {
        // 15 hex chars should NOT be redacted (threshold is 16).
        assert_eq!(
            redact_hex_sequences("id=0123456789abcde end"),
            "id=0123456789abcde end"
        );
    }

    #[test]
    fn redact_hex_sequences_redacts_16_char_hex() {
        // Exactly 16 hex chars SHOULD be redacted.
        assert_eq!(
            redact_hex_sequences("id=0123456789abcdef end"),
            "id=[REDACTED] end"
        );
    }
}
