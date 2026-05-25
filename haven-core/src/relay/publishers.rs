//! Pure event-building helpers for user relay list publishing.
//!
//! This module provides protocol-correct construction of replaceable relay
//! list events (kind 10050 inbox, kind 10051 `KeyPackage`) and their
//! "empty replacement" + NIP-09 deletion counterparts used when the user
//! opts out of publishing.
//!
//! All functions are pure and synchronous — they take input data and return
//! either the built event or a typed error. The actual storage gating
//! (toggle reads, target unioning, event id recording) and the relay
//! publishing live at the FFI boundary so the toggle integrity check, the
//! signing operation, and the choice of publish targets are atomic from
//! Dart's perspective: Dart cannot publish without first calling Rust, and
//! Rust will not produce an event when the toggle is off.
//!
//! # Why "user list ∪ defaults"
//!
//! Marmot's MIP-00 leaves the question of *where* a user's kind 10051 itself
//! should be published implementation-defined. A naive implementation that
//! publishes 10051 only to the user's chosen `KeyPackage` relays creates a
//! bootstrap problem: a stranger with only the user's pubkey has nowhere
//! safe to query for the list. Haven publishes 10050 and 10051 to the
//! deduplicated union of the user's list and [`default_relays`] so a
//! cold-start invite by pubkey always finds the list on at least one
//! widely-queried relay.
//!
//! # `created_at` monotonicity
//!
//! Replaceable events are superseded by `created_at`. To defeat clock skew
//! when the user toggles publishing rapidly OFF→ON→OFF, the unpublish
//! helpers compute `created_at = max(now, last_published_at + 1)`.

use chrono::Utc;
use nostr::{nips::nip09::EventDeletionRequest, EventBuilder, EventId, Keys, Tag, Timestamp};

use crate::circle::relay_prefs::RelayType;
use crate::circle::types::default_relays;

/// Errors raised by event-building helpers.
///
/// Kept separate from the relay manager's error type because these errors
/// occur before any network traffic — they wrap signing or tag-construction
/// failures only.
#[derive(Debug, thiserror::Error)]
pub enum PublisherError {
    /// Failed to construct or sign the event. The inner string is suitable
    /// for `debug!` logging but excluded from `Display` so the FFI boundary
    /// does not leak internal details.
    #[error("failed to build relay list event")]
    Build(String),
}

/// Result type alias.
pub type PublisherResult<T> = std::result::Result<T, PublisherError>;

/// Returns the deduplicated union of the user's relays and the default
/// relay list ([`default_relays`]).
///
/// Order is preserved by first occurrence: the user's list comes first, then
/// any defaults not already present. This keeps publishes targeted at the
/// user's preferred relays when both succeed but still hits a public
/// discovery relay for the bootstrap case.
///
/// Defense in depth: dedup keys are computed via [`dedup_key`] which
/// lowercases the scheme + host so a future caller bypassing
/// `normalize_url` cannot produce duplicates that would defeat this set.
/// The original URL string is preserved in the output so the publish
/// targets remain bit-for-bit what the user configured.
#[must_use]
pub fn compute_publish_targets(user_relays: &[String]) -> Vec<String> {
    let defaults = default_relays();
    let mut out = Vec::with_capacity(user_relays.len() + defaults.len());
    let mut seen = std::collections::HashSet::new();
    for url in user_relays {
        if seen.insert(dedup_key(url)) {
            out.push(url.clone());
        }
    }
    for url in defaults {
        if seen.insert(dedup_key(&url)) {
            out.push(url);
        }
    }
    out
}

/// Returns the dedup key for a relay URL — scheme + host lowercased,
/// path/query/fragment preserved as-is. Pure-Dart-equivalent lives in
/// `relay_url_validator.dart`; both must agree on what counts as "the
/// same relay" or storage-vs-publish dedup will diverge.
fn dedup_key(url: &str) -> String {
    url.find("://").map_or_else(
        || url.to_ascii_lowercase(),
        |scheme_end| {
            let scheme = &url[..scheme_end];
            let after = &url[scheme_end + 3..];
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

/// Builds a signed replaceable relay list event.
///
/// Per MIP-00 (kind 10051) and NIP-17 (kind 10050), each entry is a tag of
/// the form `["relay", "<wss_url>"]` (singular `relay`, NOT `r` like
/// NIP-65's kind 10002). The `content` is empty.
///
/// # Errors
///
/// Returns [`PublisherError::Build`] if signing fails. Tag parsing for
/// well-formed URLs cannot fail; we still propagate any error from
/// `Tag::parse` defensively.
pub fn build_relay_list_event(
    keys: &Keys,
    relay_type: RelayType,
    urls: &[String],
    created_at: Option<i64>,
) -> PublisherResult<nostr::Event> {
    let tags: Vec<Tag> = urls
        .iter()
        .map(|url| {
            Tag::parse(["relay", url.as_str()])
                .map_err(|e| PublisherError::Build(format!("relay tag: {e}")))
        })
        .collect::<PublisherResult<Vec<Tag>>>()?;

    let kind = relay_type.to_kind();
    let mut builder = EventBuilder::new(kind, "").tags(tags);
    if let Some(ts) = created_at {
        let ts = u64::try_from(ts).unwrap_or(0);
        builder = builder.custom_created_at(Timestamp::from_secs(ts));
    }
    builder
        .sign_with_keys(keys)
        .map_err(|e| PublisherError::Build(format!("sign: {e}")))
}

/// Builds the "empty replacement" event used to unpublish a relay list.
///
/// The event has the same `kind` as the list (10050 / 10051) but no `relay`
/// tags and empty content. Per Nostr replaceable-event semantics, relays
/// that honor NIP-01 will supersede the previous list with this empty
/// version, effectively unpublishing it.
///
/// `last_published_at` is the Unix-second timestamp of the previous
/// publication, if known. The new event uses
/// `created_at = max(now, last_published_at + 1)` to defeat clock skew.
///
/// # Errors
///
/// Returns [`PublisherError::Build`] if signing fails.
pub fn build_unpublish_event(
    keys: &Keys,
    relay_type: RelayType,
    last_published_at: Option<i64>,
) -> PublisherResult<nostr::Event> {
    let now = Utc::now().timestamp();
    let created_at_secs = match last_published_at {
        Some(prev) if prev >= now => prev + 1,
        _ => now,
    };
    let created_at_u = u64::try_from(created_at_secs).unwrap_or(0);
    EventBuilder::new(relay_type.to_kind(), "")
        .custom_created_at(Timestamp::from_secs(created_at_u))
        .sign_with_keys(keys)
        .map_err(|e| PublisherError::Build(format!("sign: {e}")))
}

/// Builds a NIP-09 (kind 5) deletion event referencing a single event id.
///
/// Used by the unpublish flow as a best-effort signal to cooperative
/// relays. Must be sent in addition to (not instead of) the empty
/// replacement event because relay support for NIP-09 deletion of
/// replaceable events varies.
///
/// # Errors
///
/// Returns [`PublisherError::Build`] if signing fails.
pub fn build_nip09_deletion(keys: &Keys, event_id: EventId) -> PublisherResult<nostr::Event> {
    let request = EventDeletionRequest::new().ids(vec![event_id]);
    EventBuilder::delete(request)
        .sign_with_keys(keys)
        .map_err(|e| PublisherError::Build(format!("sign deletion: {e}")))
}

#[cfg(test)]
mod tests {
    use super::*;
    use nostr::Kind;

    fn keys() -> Keys {
        Keys::generate()
    }

    #[test]
    fn compute_targets_dedupes_and_preserves_order() {
        // This test asserts behavior against the runtime default list — which
        // is `PRODUCTION_DEFAULT_RELAYS` in non-overridden builds but could
        // be a test override. Compare against `default_relays()` to stay
        // correct regardless.
        let user = vec![
            "wss://custom.example.com".to_string(),
            "wss://relay.damus.io".to_string(),
        ];
        let out = compute_publish_targets(&user);
        // Custom comes first (user order), then defaults that weren't already there.
        assert_eq!(out[0], "wss://custom.example.com");
        assert_eq!(out[1], "wss://relay.damus.io");
        // Each default appears exactly once.
        for relay in default_relays() {
            let count = out.iter().filter(|u| *u == &relay).count();
            assert_eq!(count, 1, "default {relay} must appear exactly once");
        }
    }

    #[test]
    fn compute_targets_with_empty_user_returns_defaults() {
        let out = compute_publish_targets(&[]);
        let defaults = default_relays();
        assert_eq!(out.len(), defaults.len());
        for relay in defaults {
            assert!(out.contains(&relay));
        }
    }

    #[test]
    fn compute_targets_dedupes_within_user() {
        let user = vec![
            "wss://x.example.com".to_string(),
            "wss://x.example.com".to_string(),
        ];
        let out = compute_publish_targets(&user);
        let count = out.iter().filter(|u| u == &"wss://x.example.com").count();
        assert_eq!(count, 1);
    }

    #[test]
    fn compute_targets_dedupes_case_only_differences() {
        // Defense-in-depth regression: even if a future caller bypasses
        // `normalize_url` and inserts a mixed-case URL into the user
        // list, dedup against default_relays() must still collide.
        let user = vec!["WSS://Relay.Damus.IO".to_string()];
        let out = compute_publish_targets(&user);
        // Exactly one entry containing relay.damus.io (regardless of case).
        let count = out
            .iter()
            .filter(|u| u.to_ascii_lowercase().contains("relay.damus.io"))
            .count();
        assert_eq!(
            count, 1,
            "case-only differing URLs must dedup against defaults"
        );
    }

    #[test]
    fn compute_targets_preserves_user_url_casing_in_output() {
        // The output preserves the user's original (potentially
        // miscased) string — we dedup on a canonicalized key but emit
        // what the user actually configured.
        let user = vec!["WSS://My.Custom.Example.com".to_string()];
        let out = compute_publish_targets(&user);
        assert_eq!(out[0], "WSS://My.Custom.Example.com");
    }

    #[test]
    fn build_inbox_event_has_relay_tags_and_empty_content() {
        let k = keys();
        let urls = vec![
            "wss://a.example.com".to_string(),
            "wss://b.example.com".to_string(),
        ];
        let event = build_relay_list_event(&k, RelayType::Inbox, &urls, None).unwrap();
        assert_eq!(event.kind, Kind::InboxRelays);
        assert_eq!(event.content, "");
        // Two `relay` tags.
        let relay_tags: Vec<&Tag> = event
            .tags
            .iter()
            .filter(|t| {
                let s = t.as_slice();
                !s.is_empty() && s[0] == "relay"
            })
            .collect();
        assert_eq!(relay_tags.len(), 2);
        // Tag form is ["relay", url] — singular, NOT "r".
        assert_eq!(relay_tags[0].as_slice()[0], "relay");
    }

    #[test]
    fn build_keypackage_event_uses_kind_10051() {
        let k = keys();
        let urls = vec!["wss://a.example.com".to_string()];
        let event = build_relay_list_event(&k, RelayType::KeyPackage, &urls, None).unwrap();
        assert_eq!(event.kind, Kind::MlsKeyPackageRelays);
    }

    #[test]
    fn build_unpublish_event_has_no_relay_tags() {
        let k = keys();
        let event = build_unpublish_event(&k, RelayType::KeyPackage, None).unwrap();
        assert_eq!(event.kind, Kind::MlsKeyPackageRelays);
        assert_eq!(event.content, "");
        let has_relay = event.tags.iter().any(|t| {
            let s = t.as_slice();
            !s.is_empty() && s[0] == "relay"
        });
        assert!(!has_relay, "unpublish event must have no relay tags");
    }

    #[test]
    fn build_unpublish_increments_over_clock_skew() {
        let k = keys();
        let now = Utc::now().timestamp();
        // Pretend the previous publish has a timestamp in the future
        // (simulating a clock that was ahead during the prior call).
        let future = now + 3600;
        let event = build_unpublish_event(&k, RelayType::Inbox, Some(future)).unwrap();
        // created_at must be strictly greater than the previous one so
        // replaceable-event semantics mean this supersedes.
        let created_at = i64::try_from(event.created_at.as_secs()).unwrap();
        assert!(created_at > future);
    }

    #[test]
    fn build_unpublish_uses_now_when_no_prior() {
        let k = keys();
        let before = Utc::now().timestamp();
        let event = build_unpublish_event(&k, RelayType::Inbox, None).unwrap();
        let after = Utc::now().timestamp();
        let created_at = i64::try_from(event.created_at.as_secs()).unwrap();
        assert!(created_at >= before && created_at <= after);
    }

    #[test]
    fn build_nip09_references_id() {
        let k = keys();
        let dummy = nostr::EventBuilder::new(Kind::TextNote, "")
            .sign_with_keys(&k)
            .unwrap();
        let deletion = build_nip09_deletion(&k, dummy.id).unwrap();
        assert_eq!(deletion.kind, Kind::EventDeletion);
        // The deletion references the dummy event id via an `e` tag.
        let has_ref = deletion.tags.iter().any(|t| {
            let s = t.as_slice();
            s.len() >= 2 && s[0] == "e" && s[1] == dummy.id.to_hex()
        });
        assert!(has_ref);
    }
}
