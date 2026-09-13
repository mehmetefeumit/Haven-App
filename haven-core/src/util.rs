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

/// Asserts that a `Debug` rendering discloses none of the given needles.
///
/// `assert_debug_redacted!(instance, "TypeName", &["needle", …])` renders
/// `instance` with `{:?}` and fails if any needle appears in it — as the
/// literal, upper/lower-cased, hex-encoded, or truncated to its first 8 or 16
/// characters, because a prefix of an identifier is still an identifier
/// (Security Rule 15). The rendering must also be non-empty and contain
/// `"TypeName"`, so the assertion cannot pass on an empty or unrelated string.
///
/// A `Debug` that deliberately renders something other than its type name (an
/// enum printing only a variant, a handle printing only its class) takes the
/// marker form, which keeps the type name in the invocation for
/// `scripts/ci/check_debug_impls_covered.sh` while checking a different
/// anti-vacuity anchor:
///
/// ```text
/// assert_debug_redacted!(plan, "LeavePlan", marker = "AdminHandoff", &[successor_hex]);
/// ```
#[cfg(any(test, feature = "test-utils"))]
#[macro_export]
macro_rules! assert_debug_redacted {
    ($instance:expr, $type_name:expr, marker = $marker:expr, $needles:expr) => {
        $crate::util::assert_rendering_redacted(
            "Debug",
            $type_name,
            $marker,
            &format!("{:?}", $instance),
            $needles,
        )
    };
    ($instance:expr, $type_name:expr, $needles:expr) => {
        $crate::util::assert_rendering_redacted(
            "Debug",
            $type_name,
            $type_name,
            &format!("{:?}", $instance),
            $needles,
        )
    };
}

/// Asserts that a `Display` rendering discloses none of the given needles.
///
/// The `Display` counterpart of [`assert_debug_redacted!`], with the same two
/// forms and the same needle expansion.
#[cfg(any(test, feature = "test-utils"))]
#[macro_export]
macro_rules! assert_display_redacted {
    ($instance:expr, $type_name:expr, marker = $marker:expr, $needles:expr) => {
        $crate::util::assert_rendering_redacted(
            "Display",
            $type_name,
            $marker,
            &format!("{}", $instance),
            $needles,
        )
    };
    ($instance:expr, $type_name:expr, $needles:expr) => {
        $crate::util::assert_rendering_redacted(
            "Display",
            $type_name,
            $type_name,
            &format!("{}", $instance),
            $needles,
        )
    };
}

/// Backs [`assert_debug_redacted!`] and [`assert_display_redacted!`].
///
/// # Panics
///
/// Panics — i.e. fails the calling test — if `rendering` is empty, does not
/// contain `marker`, or discloses any form of any needle. Also panics if
/// `needles` is empty or a needle is shorter than 4 characters, since neither
/// can prove a redaction happened.
#[cfg(any(test, feature = "test-utils"))]
pub fn assert_rendering_redacted(
    trait_name: &str,
    type_name: &str,
    marker: &str,
    rendering: &str,
    needles: &[&str],
) {
    assert!(
        !needles.is_empty(),
        "{type_name}: a redaction assertion with no needles proves nothing"
    );
    assert!(
        !rendering.is_empty(),
        "{type_name}'s {trait_name} rendering is empty"
    );
    assert!(
        marker.chars().count() >= 3,
        "{type_name}: the anchor {marker:?} is too short to distinguish one \
         rendering from another"
    );
    assert!(
        rendering.contains(marker),
        "{type_name}'s {trait_name} rendering {rendering:?} lacks the anchor {marker:?}, \
         so the redaction assertions below would pass on anything"
    );
    for needle in needles {
        assert!(
            needle.chars().count() >= 4,
            "{type_name}: needle {needle:?} is too short to prove a redaction"
        );
        for form in forbidden_forms(needle) {
            assert!(
                !rendering.contains(&form),
                "{type_name}'s {trait_name} rendering {rendering:?} discloses {form:?} \
                 (a form of {needle:?})"
            );
        }
    }
}

/// Every shape a needle could plausibly reach a rendering in.
///
/// Mirrors `haven-core/tests/helpers/mod.rs::needle_forms`: the two live in
/// different crates' test surfaces and must agree, or a leak caught by the
/// in-process log capture would slip past a `Debug` assertion.
#[cfg(any(test, feature = "test-utils"))]
fn forbidden_forms(needle: &str) -> Vec<String> {
    use base64::engine::general_purpose::STANDARD as BASE64;
    use base64::Engine as _;
    use nostr::nips::nip19::ToBech32 as _;

    let text_as_hex = hex::encode(needle.as_bytes());
    let mut forms = vec![
        needle.to_string(),
        needle.to_uppercase(),
        needle.to_lowercase(),
        text_as_hex.clone(),
    ];
    // A hex needle also travels as base64 and, at 32 bytes, as `npub1…`:
    // a rendering that re-encoded the value would otherwise pass.
    if let Ok(bytes) = hex::decode(needle) {
        forms.push(BASE64.encode(&bytes));
        if let Ok(pubkey) = nostr::PublicKey::from_slice(&bytes) {
            forms.extend(pubkey.to_bech32().ok());
        }
    }
    for base in [needle, text_as_hex.as_str()] {
        let width = base.chars().count();
        for edge in [8, 16] {
            if width > edge {
                forms.push(base.chars().take(edge).collect());
                // The SUFFIX too: truncating from the front is as common a
                // mistake as truncating from the back, and both leave an
                // identifier.
                forms.push(base.chars().skip(width - edge).collect());
            }
        }
    }
    // A run of 3 or fewer characters matches too much to be evidence.
    forms.retain(|form| form.chars().count() >= 4);
    forms.sort();
    forms.dedup();
    forms
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

    /// A type whose `Debug` leaks exactly what the caller asks it to, so the
    /// redaction assertion itself can be tested in both directions.
    struct Rendered(&'static str);

    impl std::fmt::Debug for Rendered {
        fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
            f.write_str(self.0)
        }
    }

    impl std::fmt::Display for Rendered {
        fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
            f.write_str(self.0)
        }
    }

    const NEEDLE_PUBKEY: &str = "e1d9e8e1e35d8a5a1a1dbe6d3e0aa1b9f5f0f2a3b4c5d6e7f8091a2b3c4d5e6f";

    #[test]
    fn assert_debug_redacted_accepts_a_redacted_rendering() {
        crate::assert_debug_redacted!(
            Rendered("Rendered { pubkey: <redacted> }"),
            "Rendered",
            &[NEEDLE_PUBKEY, "Ada Lovelace"]
        );
    }

    #[test]
    #[should_panic(expected = "discloses")]
    fn assert_debug_redacted_catches_a_full_value() {
        crate::assert_debug_redacted!(
            Rendered("Rendered { pubkey: e1d9e8e1e35d8a5a1a1dbe6d3e0aa1b9f5f0f2a3b4c5d6e7f8091a2b3c4d5e6f }"),
            "Rendered",
            &[NEEDLE_PUBKEY]
        );
    }

    #[test]
    #[should_panic(expected = "discloses")]
    fn assert_debug_redacted_catches_an_eight_char_prefix() {
        crate::assert_debug_redacted!(
            Rendered("Rendered { pubkey: e1d9e8e1... }"),
            "Rendered",
            &[NEEDLE_PUBKEY]
        );
    }

    #[test]
    #[should_panic(expected = "discloses")]
    fn assert_debug_redacted_catches_a_case_change() {
        crate::assert_debug_redacted!(
            Rendered("Rendered { name: ADA LOVELACE }"),
            "Rendered",
            &["Ada Lovelace"]
        );
    }

    #[test]
    #[should_panic(expected = "discloses")]
    fn assert_debug_redacted_catches_a_hex_encoded_value() {
        crate::assert_debug_redacted!(
            Rendered("Rendered { name: 416461204c6f76656c616365 }"),
            "Rendered",
            &["Ada Lovelace"]
        );
    }

    #[test]
    #[should_panic(expected = "discloses")]
    fn assert_debug_redacted_catches_a_base64_re_encoding() {
        // base64 of the 32 bytes the hex needle decodes to.
        crate::assert_debug_redacted!(
            Rendered("Rendered { pubkey: 4dno4eNdiloaHb5tPgqhufXw8qO0xdbn+AkaKzxNXm8= }"),
            "Rendered",
            &[NEEDLE_PUBKEY]
        );
    }

    #[test]
    #[should_panic(expected = "discloses")]
    fn assert_debug_redacted_catches_an_npub_re_encoding() {
        crate::assert_debug_redacted!(
            Rendered(
                "Rendered { pubkey: npub1u8v73c0rtk995xsaheknuz4ph86lpu4rknzadelcpydzk0zdtehsppv8pq }"
            ),
            "Rendered",
            &[NEEDLE_PUBKEY]
        );
    }

    #[test]
    #[should_panic(expected = "discloses")]
    fn assert_debug_redacted_catches_a_suffix() {
        crate::assert_debug_redacted!(
            Rendered("Rendered { pubkey: ...3c4d5e6f }"),
            "Rendered",
            &[NEEDLE_PUBKEY]
        );
    }

    #[test]
    #[should_panic(expected = "too short to distinguish")]
    fn assert_debug_redacted_rejects_a_two_char_anchor() {
        crate::assert_debug_redacted!(Rendered("Re"), "Rendered", marker = "Re", &[NEEDLE_PUBKEY]);
    }

    #[test]
    #[should_panic(expected = "lacks the anchor")]
    fn assert_debug_redacted_rejects_a_rendering_without_the_type_name() {
        crate::assert_debug_redacted!(Rendered("<redacted>"), "Rendered", &[NEEDLE_PUBKEY]);
    }

    #[test]
    #[should_panic(expected = "proves nothing")]
    fn assert_debug_redacted_rejects_an_empty_needle_list() {
        crate::assert_debug_redacted!(Rendered("Rendered"), "Rendered", &[]);
    }

    #[test]
    #[should_panic(expected = "too short")]
    fn assert_debug_redacted_rejects_a_three_char_needle() {
        crate::assert_debug_redacted!(Rendered("Rendered"), "Rendered", &["abc"]);
    }

    #[test]
    fn assert_debug_redacted_marker_form_anchors_on_the_marker() {
        crate::assert_debug_redacted!(
            Rendered("AdminHandoff { successor: peer#a91f3c }"),
            "LeavePlan",
            marker = "AdminHandoff",
            &[NEEDLE_PUBKEY]
        );
    }

    #[test]
    fn assert_display_redacted_accepts_a_redacted_rendering() {
        crate::assert_display_redacted!(
            Rendered("Rendered: the circle could not be read"),
            "Rendered",
            &[NEEDLE_PUBKEY]
        );
    }

    #[test]
    #[should_panic(expected = "Display rendering")]
    fn assert_display_redacted_catches_a_leak() {
        crate::assert_display_redacted!(
            Rendered("Rendered: wss://relay.example.com refused"),
            "Rendered",
            &["wss://relay.example.com"]
        );
    }

    #[test]
    fn assert_display_redacted_marker_form_anchors_on_the_marker() {
        crate::assert_display_redacted!(
            Rendered("cache entry unreadable"),
            "TileCacheError",
            marker = "unreadable",
            &[NEEDLE_PUBKEY]
        );
    }
}
