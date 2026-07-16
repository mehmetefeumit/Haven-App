//! Selection of the authoritative kind-0 metadata from a set of fetched events.
//!
//! Replaceable-event convergence (NIP-01): among the kind-0 events authored by
//! a given pubkey, the one with the greatest `created_at` wins; ties are broken
//! by the **lowest** event id (spec-correct — White Noise's `>=`-wins tie-break
//! is arguably non-compliant). Malformed content is skipped, not fatal.

use std::cmp::Ordering;

use nostr::{Event, JsonUtil, Kind, Metadata, PublicKey};

use super::types::{ProfileMetadata, ProfileState};

/// Selects the newest valid kind-0 metadata authored by `author` from `events`.
///
/// Returns a triple of:
/// * the [`ProfileState`] — [`ProfileState::Known`] when at least one valid
///   kind-0 (including an empty `{}` object) was found for `author`, otherwise
///   [`ProfileState::Unknown`];
/// * the winning [`ProfileMetadata`] (an empty default when `Unknown`);
/// * the winning event's `created_at` in Unix seconds (`0` when `Unknown`) —
///   the newer-wins gate the cache layer uses.
///
/// Selection rules:
/// * only events with `kind == 0` **and** `pubkey == author` are considered;
/// * events whose `content` does not parse as [`Metadata`] are skipped (a
///   malformed newest event does not shadow an older valid one);
/// * greatest `created_at` wins; on a tie, the lexicographically **lowest**
///   event id wins.
#[must_use]
pub fn parse_newest_metadata(
    events: &[Event],
    author: &PublicKey,
) -> (ProfileState, ProfileMetadata, i64) {
    let mut best: Option<(&Event, Metadata)> = None;

    for event in events {
        if event.kind != Kind::Metadata || event.pubkey != *author {
            continue;
        }
        // Malformed content is skipped, never fatal — a broken newest event
        // must not shadow an older, valid one.
        let Ok(metadata) = Metadata::from_json(&event.content) else {
            continue;
        };

        best = match best {
            None => Some((event, metadata)),
            Some((current, current_md)) => {
                if replaces(event, current) {
                    Some((event, metadata))
                } else {
                    Some((current, current_md))
                }
            }
        };
    }

    match best {
        Some((event, metadata)) => (
            ProfileState::Known,
            ProfileMetadata::from_metadata(metadata),
            i64::try_from(event.created_at.as_secs()).unwrap_or(i64::MAX),
        ),
        None => (ProfileState::Unknown, ProfileMetadata::default(), 0),
    }
}

/// Returns `true` if `candidate` should replace `current` as the winner:
/// strictly newer `created_at`, or an equal `created_at` with a lower id.
fn replaces(candidate: &Event, current: &Event) -> bool {
    match candidate.created_at.cmp(&current.created_at) {
        Ordering::Greater => true,
        Ordering::Less => false,
        Ordering::Equal => candidate.id < current.id,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use nostr::{EventBuilder, Keys, Tag, Timestamp};

    /// Builds a signed kind-0 event with an explicit `created_at`.
    fn kind0(keys: &Keys, content: &str, created_at: u64) -> Event {
        EventBuilder::new(Kind::Metadata, content)
            .custom_created_at(Timestamp::from(created_at))
            .sign_with_keys(keys)
            .expect("sign kind0")
    }

    #[test]
    fn newest_created_at_wins() {
        let keys = Keys::generate();
        let older = kind0(&keys, r#"{"name":"old"}"#, 1_000);
        let newer = kind0(&keys, r#"{"name":"new"}"#, 2_000);
        // Order should not matter — pass oldest-first.
        let (state, md, created) = parse_newest_metadata(&[older, newer], &keys.public_key());
        assert_eq!(state, ProfileState::Known);
        assert_eq!(md.name(), Some("new"));
        assert_eq!(created, 2_000);
    }

    #[test]
    fn tie_breaks_on_lowest_id() {
        let keys = Keys::generate();
        // Two same-`created_at` events; the winner is the lower event id.
        let a = kind0(&keys, r#"{"name":"a"}"#, 5_000);
        let b = kind0(&keys, r#"{"name":"b"}"#, 5_000);
        let expected = if a.id < b.id { "a" } else { "b" };
        let (_, md_ab, _) = parse_newest_metadata(&[a.clone(), b.clone()], &keys.public_key());
        assert_eq!(md_ab.name(), Some(expected));
        // Reverse order must yield the identical winner (deterministic).
        let (_, md_ba, _) = parse_newest_metadata(&[b, a], &keys.public_key());
        assert_eq!(md_ba.name(), Some(expected));
    }

    #[test]
    fn empty_object_is_known() {
        let keys = Keys::generate();
        let ev = kind0(&keys, "{}", 1_000);
        let (state, md, created) = parse_newest_metadata(&[ev], &keys.public_key());
        assert_eq!(
            state,
            ProfileState::Known,
            "blank {{}} is a resolved profile"
        );
        assert_eq!(md.resolve_display_name(), None);
        assert_eq!(created, 1_000);
    }

    #[test]
    fn malformed_skipped_not_error() {
        let keys = Keys::generate();
        // A newer but malformed kind-0 must be skipped, letting the older valid
        // one win — parsing never errors out.
        let valid = kind0(&keys, r#"{"name":"valid"}"#, 1_000);
        let malformed = kind0(&keys, "this is not json", 9_999);
        let (state, md, created) = parse_newest_metadata(&[valid, malformed], &keys.public_key());
        assert_eq!(state, ProfileState::Known);
        assert_eq!(md.name(), Some("valid"));
        assert_eq!(created, 1_000);
    }

    #[test]
    fn author_mismatch_dropped() {
        let alice = Keys::generate();
        let bob = Keys::generate();
        // Bob's kind-0 must never be attributed to Alice.
        let bob_event = kind0(&bob, r#"{"name":"bob"}"#, 5_000);
        let (state, _, created) = parse_newest_metadata(&[bob_event], &alice.public_key());
        assert_eq!(state, ProfileState::Unknown);
        assert_eq!(created, 0);
    }

    #[test]
    fn wrong_kind_dropped() {
        let keys = Keys::generate();
        // A non-metadata event from the same author is ignored.
        let note = EventBuilder::text_note("hello")
            .sign_with_keys(&keys)
            .expect("sign note");
        let (state, _, _) = parse_newest_metadata(&[note], &keys.public_key());
        assert_eq!(state, ProfileState::Unknown);
    }

    #[test]
    fn no_events_is_unknown() {
        let keys = Keys::generate();
        let (state, md, created) = parse_newest_metadata(&[], &keys.public_key());
        assert_eq!(state, ProfileState::Unknown);
        assert_eq!(md, ProfileMetadata::default());
        assert_eq!(created, 0);
    }

    #[test]
    fn unused_tag_helper_import_is_exercised() {
        // Keep the Tag import meaningful: a kind-0 with an extra tag still
        // parses to metadata from its content, ignoring tags.
        let keys = Keys::generate();
        let ev = EventBuilder::new(Kind::Metadata, r#"{"name":"tagged"}"#)
            .tag(Tag::alt("ignored"))
            .sign_with_keys(&keys)
            .expect("sign");
        let (state, md, _) = parse_newest_metadata(&[ev], &keys.public_key());
        assert_eq!(state, ProfileState::Known);
        assert_eq!(md.name(), Some("tagged"));
    }
}
