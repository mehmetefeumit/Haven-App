//! The single canonical form for relay URLs.
//!
//! Relay URLs are compared as SET MEMBERS in several security-relevant places —
//! the storage layer's `UNIQUE (url, relay_type)` index, and the profile
//! plane's contamination exclusion
//! ([`crate::profile::relay_pool::resolve_profile_pool`]). Every one of those
//! comparisons fails OPEN if two spellings of the same relay do not collapse to
//! the same string: a duplicate row, or — far worse — a contaminated relay that
//! survives exclusion and starts receiving profile traffic alongside the user's
//! encrypted location traffic.
//!
//! So there is exactly ONE normalization implementation, here, and every caller
//! delegates to it. [`crate::circle::storage_relay_prefs::normalize_url`] keeps
//! its richer user-facing error messages for the interactive add path but
//! produces byte-identical output, because it calls [`canonicalize`] for the
//! final form.

use nostr::RelayUrl;

/// Canonicalizes an already-parsed relay URL to Haven's normal form.
///
/// Lowercases the scheme and authority while preserving path/query/fragment
/// case, then strips a sole trailing slash on the root path. `nostr::RelayUrl`
/// does some canonicalization but does not lowercase the host on every
/// nostr-sdk version and may preserve the root's trailing slash, either of
/// which would defeat a set comparison.
#[must_use]
pub fn canonicalize(canonical: &str) -> String {
    strip_root_trailing_slash(&lowercase_scheme_and_host(canonical))
}

/// Normalizes a raw relay URL, or returns `None` if it must be rejected.
///
/// Applies the same rules as
/// [`crate::circle::storage_relay_prefs::normalize_url`] — empty input,
/// plaintext `ws://` (outside the debug-only loopback opt-in), and embedded
/// credentials are all rejected — but reports rejection as `None` rather than a
/// user-presentable error, for callers that filter rather than validate.
#[must_use]
pub fn normalize_relay_url(input: &str) -> Option<String> {
    let trimmed = input.trim();
    if trimmed.is_empty() {
        return None;
    }
    // Reject plaintext ws:// unless the debug-only hermetic-test opt-in is
    // armed for this host. In release builds `ws_loopback_allowed_for_test` is
    // a `const fn` returning false, so this collapses to an unconditional
    // rejection — identical to the storage path.
    let lower_prefix = trimmed
        .chars()
        .take(5)
        .collect::<String>()
        .to_ascii_lowercase();
    if lower_prefix.starts_with("ws://") && !crate::relay::ws_loopback_allowed_for_test(trimmed) {
        return None;
    }
    // `RelayUrl::parse` accepts `user:pass@host`; reject so credentials never
    // reach storage, logs, or a comparison key.
    if trimmed.contains('@') {
        return None;
    }
    let parsed = RelayUrl::parse(trimmed).ok()?.to_string();
    Some(canonicalize(&parsed))
}

/// Lowercases the scheme and host of a URL, preserving path/query/fragment case.
///
/// Operates on the parsed canonical form, so there is always a `://` separator
/// and a host segment.
fn lowercase_scheme_and_host(canonical: &str) -> String {
    canonical.find("://").map_or_else(
        || canonical.to_ascii_lowercase(),
        |scheme_end| {
            let scheme = &canonical[..scheme_end];
            let after = &canonical[scheme_end + 3..];
            // Host runs until the first '/', '?', or '#'.
            let host_end = after.find(['/', '?', '#']).unwrap_or(after.len());
            let host = &after[..host_end];
            let rest = &after[host_end..];
            format!(
                "{}://{}{}",
                scheme.to_ascii_lowercase(),
                host.to_ascii_lowercase(),
                rest
            )
        },
    )
}

/// Strips a sole trailing slash on the root path.
///
/// `wss://x.example/` and `wss://x.example` must collide. A trailing slash on a
/// deeper path (`wss://x.example/foo/`) is preserved — that path *is* the path.
fn strip_root_trailing_slash(canonical: &str) -> String {
    if let Some(scheme_end) = canonical.find("://") {
        let after = &canonical[scheme_end + 3..];
        if let Some(path_start) = after.find('/') {
            let path = &after[path_start..];
            if path == "/" {
                return canonical[..scheme_end + 3 + path_start].to_string();
            }
        }
    }
    canonical.to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn case_and_trailing_slash_collapse_to_one_form() {
        let expected = normalize_relay_url("wss://relay.example").expect("valid");
        for spelling in [
            "wss://Relay.Example",
            "wss://RELAY.EXAMPLE/",
            "  wss://relay.example/  ",
            "WSS://relay.example",
        ] {
            assert_eq!(
                normalize_relay_url(spelling).as_deref(),
                Some(expected.as_str()),
                "spelling {spelling:?} did not collapse to the canonical form",
            );
        }
    }

    #[test]
    fn deeper_path_keeps_its_trailing_slash() {
        let normalized = normalize_relay_url("wss://relay.example/foo/").expect("valid");
        assert!(normalized.ends_with("/foo/"), "got {normalized}");
    }

    #[test]
    fn rejects_empty_credentials_and_plaintext_ws() {
        for bad in ["", "   ", "wss://user:pass@relay.example", "not-a-url"] {
            assert!(normalize_relay_url(bad).is_none(), "accepted {bad:?}");
        }
        // ws:// is rejected in release; in debug it needs the loopback opt-in,
        // which this test never arms.
        assert!(normalize_relay_url("ws://relay.example").is_none());
    }

    #[test]
    fn agrees_with_the_storage_layer_normalizer() {
        // THE invariant: if these two ever diverge, contaminated relays survive
        // profile-pool exclusion and the plane separation fails open.
        for url in [
            "wss://relay.example",
            "wss://Relay.Example/",
            "wss://relay.example:7777",
            "wss://relay.example/foo",
        ] {
            let storage = crate::circle::storage_relay_prefs::normalize_url(url)
                .expect("valid for the storage path");
            let shared = normalize_relay_url(url).expect("valid for the shared path");
            assert_eq!(storage, shared, "normalizers diverged on {url}");
        }
    }
}
