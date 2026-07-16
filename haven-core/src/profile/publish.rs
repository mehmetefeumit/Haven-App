//! Building and publishing the local user's own public kind-0 metadata.
//!
//! # Publishing is unconditional (public-by-default)
//!
//! Saving a display name or photo publishes a public kind-0 profile
//! immediately — there is **no persisted consent flag and no publish-time
//! gate** (owner-directed, 2026-07-16; matching the White Noise reference app).
//! That a saved profile is public on the Nostr network is a **UI concern**: it
//! is disclosed to the user in onboarding and on the Identity settings page,
//! not enforced by a toggle in this layer.
//!
//! ## Builders
//!
//! * [`build_metadata_event`] — the full-profile builder. It applies the NIP-24
//!   name rule and adds **no** client/app-identifying tags — a public kind-0
//!   must never advertise "location app" (test-pinned).
//! * [`build_blank_metadata_event`] — the retraction builder (empty `{}`,
//!   bypasses the name rule). Together with
//!   [`build_nip09_deletion`](crate::relay::publishers::build_nip09_deletion)
//!   these form the retraction allowlist honored by
//!   `scripts/ci/check_profile_privacy_boundaries.sh`
//!   (`delete_public_profile` / `delete_my_public_profile` /
//!   `remove_my_profile_picture`). They emit blank/deletion content only and,
//!   per the retraction no-op gate, are reached only when
//!   `has_published_profile()` — a retraction must never mint the *first* public
//!   event for a pubkey that never published.
//!
//! No group identifiers ever appear here: kind-0 events carry no `h` tag and
//! no group id (test-pinned).

use nostr::{Event, EventBuilder, Filter, Keys, Kind, Metadata, PublicKey};

use super::config::{profile_read_relays, profile_write_relays, PROFILE_FETCH_TIMEOUT};
use super::error::{ProfileError, Result};
use super::merge::enforce_name_rule;
use super::types::ProfileMetadata;
use crate::relay::RelayManager;

// Re-exported for callers so the retraction path has a single import surface
// for the NIP-09 deletion builder (kind 5). It is a pure builder living in the
// relay layer; profile code reuses it verbatim rather than re-implementing it.
pub use crate::relay::publishers::build_nip09_deletion;

/// Builds a signed kind-0 metadata event for the local user's OWN profile.
///
/// Clones `meta`, applies the NIP-24 name rule
/// ([`enforce_name_rule`] — mirror a non-blank `display_name` into a blank
/// `name`), and signs with the user's Nostr identity `keys`. Adds **no**
/// client/app tags.
///
/// # Errors
///
/// Returns [`ProfileError::Build`] if signing fails.
pub fn build_metadata_event(keys: &Keys, meta: &ProfileMetadata) -> Result<Event> {
    let mut metadata = meta.as_metadata().clone();
    enforce_name_rule(&mut metadata);
    EventBuilder::metadata(&metadata)
        .sign_with_keys(keys)
        .map_err(ProfileError::build)
}

/// Builds a signed **blank** (`{}`) kind-0 event — the retraction builder used
/// by "delete public profile".
///
/// Deliberately bypasses [`enforce_name_rule`]: the whole point is to
/// republish an empty object that supersedes (replaceable-event semantics) any
/// previously published profile. Emits no name, no picture, no tags. Per the
/// retraction no-op gate it is only ever reached when a profile was actually
/// published.
///
/// # Errors
///
/// Returns [`ProfileError::Build`] if signing fails.
pub fn build_blank_metadata_event(keys: &Keys) -> Result<Event> {
    EventBuilder::metadata(&Metadata::default())
        .sign_with_keys(keys)
        .map_err(ProfileError::build)
}

/// Publishes an already-built profile event to the user's write relays.
///
/// This is the **shared transport** used by both the ordinary publish path and
/// the retraction path. Publishing is unconditional (public-by-default); the
/// public-profile disclosure is a UI concern surfaced in onboarding and the
/// Identity settings page, not a check performed here.
///
/// Fails closed on an empty relay set ([`ProfileError::NoRelays`]). A relay
/// that reaches none-accepted (every relay rejected / did not acknowledge)
/// surfaces from [`RelayManager::publish_event`] as an error, which maps to a
/// generic [`ProfileError::Relay`] — the specific per-relay `OK=false` reason
/// is intentionally **not** surfaced (no leak of relay internals to the UI).
///
/// # Errors
///
/// * [`ProfileError::NoRelays`] if `write_relays` is empty.
/// * [`ProfileError::Relay`] if no relay accepted the event.
pub async fn publish_metadata(
    relay: &RelayManager,
    event: &Event,
    write_relays: &[String],
) -> Result<()> {
    if write_relays.is_empty() {
        return Err(ProfileError::NoRelays);
    }
    // `publish_event` collapses a fully-unacknowledged / all-rejected publish
    // into `Err(AllRelaysFailed)` after its bounded retries; it only returns
    // `Ok` when at least one relay accepted. So the mapped error already
    // covers the `OK=false` case; the explicit `is_success` guard below is
    // defense in depth against a future change to that contract.
    let result = relay
        .publish_event(event, write_relays)
        .await
        .map_err(ProfileError::relay)?;
    if result.is_success() {
        Ok(())
    } else {
        Err(ProfileError::Relay(
            "no relay accepted the event".to_string(),
        ))
    }
}

/// Resolves the user's own kind-0 write relays (NIP-65 kind 10002).
///
/// Fetches the user's replaceable relay list from the AUTH-free discovery
/// plane, extracts the **write**-capable relays
/// ([`RelayManager::extract_nip65_write_relays`]), and applies the
/// [`profile_write_relays`] fallback (discovery plane when the user configured
/// none). Never a circle's relays. A transient fetch failure degrades to the
/// discovery-plane fallback rather than erroring — profile publishing should
/// not hard-fail because a relay-list lookup blipped.
pub async fn resolve_write_relays(relay: &RelayManager, author: &PublicKey) -> Vec<String> {
    let filter = Filter::new().kind(Kind::RelayList).author(*author).limit(1);
    let events = relay
        .fetch_events(filter, &profile_read_relays(), Some(PROFILE_FETCH_TIMEOUT))
        .await
        .unwrap_or_default();
    let configured = events
        .first()
        .map(|event| RelayManager::extract_nip65_write_relays(&event.tags))
        .unwrap_or_default();
    profile_write_relays(&configured)
}

#[cfg(test)]
mod tests {
    use super::*;
    use nostr::JsonUtil;

    fn md_from(json: &str) -> ProfileMetadata {
        ProfileMetadata::from_metadata(Metadata::from_json(json).expect("valid json"))
    }

    #[test]
    fn signs_with_identity_key() {
        let keys = Keys::generate();
        let md = md_from(r#"{"display_name":"Alice"}"#);
        let event = build_metadata_event(&keys, &md).expect("build");
        assert_eq!(event.kind, Kind::Metadata);
        assert_eq!(
            event.pubkey,
            keys.public_key(),
            "kind-0 must be signed by the identity key"
        );
        assert!(event.verify().is_ok(), "event must be a valid signature");
    }

    #[test]
    fn name_rule_mirrors_display_name_into_name() {
        let keys = Keys::generate();
        let md = md_from(r#"{"display_name":"Alice"}"#);
        let event = build_metadata_event(&keys, &md).expect("build");
        let parsed = Metadata::from_json(&event.content).expect("content is metadata json");
        assert_eq!(
            parsed.name.as_deref(),
            Some("Alice"),
            "blank name mirrors display_name (NIP-24)"
        );
    }

    #[test]
    fn event_contains_no_group_or_client_identifying_tags() {
        // Security review F9: a public kind-0 must not carry a group id, an `h`
        // tag, or any client/app-identifying tag that advertises "location app".
        let keys = Keys::generate();
        let md = md_from(r#"{"display_name":"Alice","about":"hi"}"#);
        let event = build_metadata_event(&keys, &md).expect("build");
        assert!(
            event.tags.is_empty(),
            "a Haven kind-0 carries NO tags at all (no h/group/client tag): {:?}",
            event.tags
        );
        let json = event.as_json().to_lowercase();
        for needle in ["\"h\"", "haven", "location", "\"client\"", "group"] {
            assert!(
                !json.contains(needle),
                "kind-0 must not advertise `{needle}`: {json}"
            );
        }
    }

    #[test]
    fn fresh_created_at_each_call() {
        // Two publishes of the same content must not collide on created_at in a
        // way that breaks replaceable supersession — each build stamps now().
        let keys = Keys::generate();
        let md = md_from(r#"{"display_name":"Alice"}"#);
        let first = build_metadata_event(&keys, &md).expect("build 1");
        std::thread::sleep(std::time::Duration::from_millis(1100));
        let second = build_metadata_event(&keys, &md).expect("build 2");
        assert!(
            second.created_at >= first.created_at,
            "later publish is not older"
        );
        assert_ne!(first.id, second.id, "distinct events (distinct created_at)");
    }

    #[test]
    fn blank_republish_is_empty_object() {
        let keys = Keys::generate();
        let event = build_blank_metadata_event(&keys).expect("build blank");
        assert_eq!(event.kind, Kind::Metadata);
        assert_eq!(
            event.content, "{}",
            "retraction republishes an empty object"
        );
        assert_eq!(event.pubkey, keys.public_key());
        assert!(event.tags.is_empty());
    }

    #[test]
    fn no_partial_delete_of_other_clients_fields() {
        // Building from freshest metadata that includes another client's field
        // (lud16) must preserve it — the builder never drops modeled/custom
        // fields it does not touch.
        let keys = Keys::generate();
        let md = md_from(r#"{"display_name":"Alice","lud16":"alice@wallet","bot":true}"#);
        let event = build_metadata_event(&keys, &md).expect("build");
        let parsed = Metadata::from_json(&event.content).expect("metadata");
        assert_eq!(parsed.lud16.as_deref(), Some("alice@wallet"));
        assert_eq!(
            parsed
                .custom
                .get("bot")
                .and_then(serde_json::Value::as_bool),
            Some(true),
            "unknown custom field survives the build"
        );
    }

    #[tokio::test]
    async fn publish_metadata_fails_closed_on_empty_relays() {
        let keys = Keys::generate();
        let event = build_blank_metadata_event(&keys).expect("build");
        let relay = RelayManager::new();
        let err = publish_metadata(&relay, &event, &[])
            .await
            .expect_err("empty relays must fail closed");
        assert!(matches!(err, ProfileError::NoRelays));
    }

    #[tokio::test]
    async fn publish_metadata_publishes_without_any_consent_gate() {
        // Publishing is unconditional (public-by-default): there is no consent
        // flag to satisfy and no `ConsentRequired` path. `publish_metadata` is
        // the ONLY transport, and its sole precondition is a non-empty relay
        // set — the presence of relays is what carries it through to a real
        // publish attempt. With an empty relay set it fails closed (NoRelays,
        // never a consent error), proving the gate is gone rather than hidden.
        let keys = Keys::generate();
        let event = build_metadata_event(
            &keys,
            &ProfileMetadata::from_metadata(Metadata::new().display_name("Alice")),
        )
        .expect("build");
        let relay = RelayManager::new();
        let err = publish_metadata(&relay, &event, &[])
            .await
            .expect_err("empty relays fail closed on NoRelays, not any consent gate");
        assert!(
            matches!(err, ProfileError::NoRelays),
            "the only remaining precondition is a non-empty relay set"
        );
    }
}
