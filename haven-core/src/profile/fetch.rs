//! Bounded, one-shot batched fetch of public kind-0 metadata by author.
//!
//! [`fetch_profiles`] resolves *other* users' public profiles from the
//! AUTH-free discovery plane. It is deliberately **not** a standing
//! subscription: each call issues a small number of one-shot `REQ`s and
//! returns. Callers pass the union of all known member pubkeys across every
//! circle (see the plan §1.7) so the relay never sees a clean per-circle
//! roster partition.
//!
//! # Fail-closed
//!
//! An empty author set OR an empty relay set returns `Ok(vec![])` — the fetch
//! path never falls back to a hardcoded relay. This mirrors the publish
//! path's fail-closed stance: Haven would rather resolve nothing than dial an
//! unintended relay.
//!
//! # `authors`, never `#p`
//!
//! The filter uses [`Filter::authors`] (the event *author* field), NEVER
//! [`Filter::pubkey`] (the `#p` recipient tag). Getting this wrong would
//! query for events *addressed to* the pubkeys rather than *authored by*
//! them — the exact gotcha called out in `CLAUDE.md`. A unit test pins the
//! built filter's JSON shape (`authors` + `kinds:[0]`, no `#p`).
//!
//! # No NIP-42 AUTH
//!
//! The [`RelayManager`] is constructed with no signer (`Client::builder()`),
//! so a relay's NIP-42 AUTH challenge can never be satisfied on this path —
//! the fetch cannot be attributed to the local user's identity. The read
//! relays are the AUTH-free discovery plane. There is no AUTH-enabling knob on
//! this path; an AUTH-requiring relay simply yields no events (proven by an
//! integration test).

use std::collections::HashMap;

use nostr::{Event, Filter, Kind, PublicKey};

use super::config::{PROFILE_FETCH_MAX_AUTHORS, PROFILE_FETCH_TIMEOUT};
use super::error::{ProfileError, Result};
use super::parse::parse_newest_metadata;
use super::types::{CachedProfile, ProfileState};
use crate::relay::RelayManager;

/// Fetches the newest public kind-0 metadata for each of `authors`.
///
/// Chunks the (de-duplicated) author set into `REQ`s of at most
/// [`PROFILE_FETCH_MAX_AUTHORS`], each a single
/// `Filter::authors(..).kind(Kind::Metadata).limit(..)`. Returned events are
/// bucketed by author and reduced with [`parse_newest_metadata`]; only authors
/// for whom a valid kind-0 was resolved appear in the result (as
/// [`ProfileState::Known`] rows stamped `fetched_at = now`). Authors with no
/// resolved kind-0 are **omitted** — the caller marks those [`ProfileState::Unknown`]
/// so a blank fetched row never masks a genuine miss.
///
/// `now` is the Unix-seconds timestamp stamped into `fetched_at` (injected so
/// tests are deterministic — mirrors the avatar ingest clock pattern).
///
/// # Errors
///
/// * Returns `Ok(vec![])` (never an error) when `authors` or `profile_relays`
///   is empty (fail-closed — no hardcoded relay fallback).
/// * Returns [`ProfileError::Relay`] if a chunk's relay fetch fails.
pub async fn fetch_profiles(
    relay: &RelayManager,
    authors: &[PublicKey],
    profile_relays: &[String],
    now: i64,
) -> Result<Vec<CachedProfile>> {
    // Fail-closed: no authors or no relays ⇒ resolve nothing (never a
    // hardcoded relay fallback).
    if authors.is_empty() || profile_relays.is_empty() {
        return Ok(Vec::new());
    }

    let unique = dedup_authors(authors);
    let mut events: Vec<Event> = Vec::new();
    for chunk in author_chunks(&unique) {
        let filter = build_profile_filter(chunk);
        let fetched = relay
            .fetch_events(filter, profile_relays, Some(PROFILE_FETCH_TIMEOUT))
            .await
            .map_err(ProfileError::relay)?;
        events.extend(fetched);
    }

    Ok(assemble_profiles(&unique, events, now))
}

/// De-duplicates `authors` by value, preserving first-seen order.
///
/// The union across circles can repeat a pubkey (a member of two circles);
/// collapsing duplicates keeps each `REQ` filter tight.
fn dedup_authors(authors: &[PublicKey]) -> Vec<PublicKey> {
    let mut seen: std::collections::HashSet<PublicKey> = std::collections::HashSet::new();
    let mut out = Vec::with_capacity(authors.len());
    for author in authors {
        if seen.insert(*author) {
            out.push(*author);
        }
    }
    out
}

/// Splits `authors` into chunks of at most [`PROFILE_FETCH_MAX_AUTHORS`].
fn author_chunks(authors: &[PublicKey]) -> impl Iterator<Item = &[PublicKey]> {
    authors.chunks(PROFILE_FETCH_MAX_AUTHORS)
}

/// Builds the single metadata filter for one author chunk.
///
/// Uses `authors` (author field), a `kind:0` constraint, and a defensive
/// `limit` (four per author) so a non-pruning relay that returns multiple
/// historical revisions per pubkey is still bounded. NEVER uses `#p`.
fn build_profile_filter(chunk: &[PublicKey]) -> Filter {
    let limit = chunk.len().saturating_mul(4).max(1);
    Filter::new()
        .authors(chunk.iter().copied())
        .kind(Kind::Metadata)
        .limit(limit)
}

/// Buckets `events` by author and reduces each requested author's bucket with
/// [`parse_newest_metadata`], returning a [`CachedProfile`] only for authors
/// that resolved to a [`ProfileState::Known`] kind-0.
fn assemble_profiles(requested: &[PublicKey], events: Vec<Event>, now: i64) -> Vec<CachedProfile> {
    let mut by_author: HashMap<PublicKey, Vec<Event>> = HashMap::new();
    for event in events {
        by_author.entry(event.pubkey).or_default().push(event);
    }

    let mut out = Vec::new();
    for author in requested {
        let Some(bucket) = by_author.get(author) else {
            continue; // no events for this author — caller marks Unknown
        };
        let (state, metadata, event_created_at) = parse_newest_metadata(bucket, author);
        if state == ProfileState::Known {
            out.push(CachedProfile {
                pubkey_hex: author.to_hex(),
                metadata,
                state,
                event_created_at,
                fetched_at: now,
            });
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use nostr::{EventBuilder, JsonUtil, Keys, Timestamp};

    fn keys_n(n: usize) -> Vec<Keys> {
        (0..n).map(|_| Keys::generate()).collect()
    }

    fn kind0(keys: &Keys, content: &str, created_at: u64) -> Event {
        EventBuilder::new(Kind::Metadata, content)
            .custom_created_at(Timestamp::from(created_at))
            .sign_with_keys(keys)
            .expect("sign kind0")
    }

    #[tokio::test]
    async fn empty_authors_returns_empty() {
        let relay = RelayManager::new();
        let out = fetch_profiles(&relay, &[], &["wss://x.example".to_string()], 100)
            .await
            .expect("empty authors is Ok");
        assert!(out.is_empty());
    }

    #[tokio::test]
    async fn empty_relays_fails_closed() {
        let relay = RelayManager::new();
        let author = Keys::generate().public_key();
        // A non-empty author set with NO relays must resolve nothing and never
        // touch the network (fail-closed; no hardcoded fallback).
        let out = fetch_profiles(&relay, &[author], &[], 100)
            .await
            .expect("empty relays is Ok(empty), never an error");
        assert!(out.is_empty());
    }

    #[test]
    fn filter_is_kind0_authors_only_not_pubkey_tag() {
        // Pins the `CLAUDE.md` #p gotcha: the filter must key on the event
        // AUTHOR, never the `#p` recipient tag.
        let author = Keys::generate().public_key();
        let json = build_profile_filter(&[author]).as_json();
        assert!(
            json.contains("\"authors\""),
            "must filter by author: {json}"
        );
        assert!(
            json.contains("\"kinds\":[0]"),
            "must be kind:0 only: {json}"
        );
        assert!(
            !json.contains("\"#p\""),
            "must NOT carry a #p pubkey tag (that filters recipients, not authors): {json}"
        );
    }

    #[test]
    fn filter_has_defensive_limit() {
        let authors: Vec<PublicKey> = keys_n(3).iter().map(Keys::public_key).collect();
        let json = build_profile_filter(&authors).as_json();
        // 3 authors * 4 = limit 12.
        assert!(
            json.contains("\"limit\":12"),
            "defensive limit expected: {json}"
        );
    }

    #[test]
    fn chunks_over_500() {
        let authors: Vec<PublicKey> = keys_n(501).iter().map(Keys::public_key).collect();
        let chunks: Vec<&[PublicKey]> = author_chunks(&authors).collect();
        assert_eq!(chunks.len(), 2, "501 authors ⇒ two REQs");
        assert_eq!(chunks[0].len(), PROFILE_FETCH_MAX_AUTHORS);
        assert_eq!(chunks[1].len(), 1);
    }

    #[test]
    fn dedup_collapses_repeats_preserving_order() {
        let ks = keys_n(3);
        let a = ks[0].public_key();
        let b = ks[1].public_key();
        let c = ks[2].public_key();
        let out = dedup_authors(&[a, b, a, c, b]);
        assert_eq!(out, vec![a, b, c], "first-seen order, no repeats");
    }

    #[test]
    fn assemble_returns_only_resolved_authors_absent_left_for_unknown() {
        let ks = keys_n(2);
        let present = &ks[0];
        let absent = ks[1].public_key();
        let events = vec![kind0(present, r#"{"name":"present"}"#, 1_000)];
        let out = assemble_profiles(&[present.public_key(), absent], events, 42);
        assert_eq!(out.len(), 1, "only the author with events is returned");
        assert_eq!(out[0].pubkey_hex, present.public_key().to_hex());
        assert_eq!(out[0].state, ProfileState::Known);
        assert_eq!(out[0].fetched_at, 42, "now is stamped into fetched_at");
        assert_eq!(out[0].event_created_at, 1_000);
        assert!(
            !out.iter().any(|p| p.pubkey_hex == absent.to_hex()),
            "an author with no events must be absent (caller marks Unknown)"
        );
    }

    #[test]
    fn assemble_picks_newest_per_author() {
        let ks = keys_n(1);
        let author = &ks[0];
        let events = vec![
            kind0(author, r#"{"name":"old"}"#, 1_000),
            kind0(author, r#"{"name":"new"}"#, 2_000),
        ];
        let out = assemble_profiles(&[author.public_key()], events, 7);
        assert_eq!(out.len(), 1);
        assert_eq!(out[0].metadata.name(), Some("new"));
    }

    #[test]
    fn assemble_ignores_unrequested_author_events() {
        // A relay returning an event for a pubkey we did not ask about must be
        // ignored (defensive).
        let ks = keys_n(2);
        let requested = &ks[0];
        let intruder = &ks[1];
        let events = vec![
            kind0(requested, r#"{"name":"wanted"}"#, 1_000),
            kind0(intruder, r#"{"name":"unwanted"}"#, 5_000),
        ];
        let out = assemble_profiles(&[requested.public_key()], events, 1);
        assert_eq!(out.len(), 1);
        assert_eq!(out[0].pubkey_hex, requested.public_key().to_hex());
    }
}
