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

use nostr::{Event, EventBuilder, Keys, Metadata, Timestamp};

use super::error::{ProfileError, Result};
use super::merge::enforce_name_rule;
use super::types::ProfileMetadata;
use crate::relay::{PublishResult, RelayManager};

// Re-exported for callers so the retraction path has a single import surface
// for the NIP-09 deletion builder (kind 5). It is a pure builder living in the
// relay layer; profile code reuses it verbatim rather than re-implementing it.
pub use crate::relay::publishers::build_nip09_deletion;

/// Chooses a `created_at` for a republished kind-0 that deterministically
/// SUPERSEDES the previously published one under NIP-01 replaceable-event
/// semantics — even when the republish lands in the same Unix second.
///
/// kind-0 `created_at` has one-second resolution. A same-second edit would
/// otherwise tie the previous event on `created_at`, and NIP-01's tie-break
/// (keep the event with the lowest id) could retain the OLD event — so a relay
/// would serve the stale metadata and peers would re-resolve the stale
/// name/photo. `previous_created_at` is the `created_at` (Unix seconds) of the
/// freshest kind-0 this republish is built on top of, or `None` for a first
/// publish.
///
/// Returns `max(now, previous + 1)` — the standard robust replaceable-event
/// stamp (mirrors White Noise / NIP-01 client practice). In normal operation
/// `previous <= now`, so this is just `now`; the `+ 1` bump only engages on a
/// same-second (or clock-skewed-future) previous, keeping each edit at most one
/// second ahead so relays never reject it as future-dated.
fn superseding_created_at(previous_created_at: Option<u64>) -> Timestamp {
    let now = Timestamp::now();
    match previous_created_at {
        Some(prev) if prev >= now.as_secs() => Timestamp::from(prev.saturating_add(1)),
        _ => now,
    }
}

/// Builds a signed kind-0 metadata event for the local user's OWN profile.
///
/// Sanitizes `meta`'s name fields ([`ProfileMetadata::sanitized`]), applies the
/// NIP-24 name rule ([`enforce_name_rule`] — mirror a non-blank `display_name`
/// into a blank `name`), and signs with the user's Nostr identity `keys`. Adds
/// **no** client/app tags.
///
/// # The display-name sanitizer runs HERE on the publish side
///
/// This is the only builder that puts a *name* on the wire, so it is the one
/// place that can promise a name Haven publishes carries no bidi override and
/// no zero-width padding into anybody else's client. It has to be the builder
/// rather than a caller: the republish base is normally the freshly-fetched
/// relay copy and only falls back to the (already-sanitized) local row on a
/// total read miss, so sanitizing at a call site would make the published form
/// depend on network conditions.
///
/// A name with nothing renderable left sanitizes to `None`, and the field is
/// then simply OMITTED — the publish is never refused. Omission is what every
/// consumer's name precedence already handles (it falls through to the npub),
/// whereas refusing would strand the picture and bio edits riding the same
/// event. The deprecated `custom` name keys are emptied rather than removed for
/// the same reason [`ProfileMetadata::sanitized`] gives: `custom` is what makes
/// a republish preserve fields written by other clients.
///
/// `previous_created_at` is the `created_at` of the freshest kind-0 being
/// superseded (or `None` for a first publish). The event is stamped via
/// [`superseding_created_at`] so a same-second edit still wins the replaceable-
/// event race — otherwise peers could re-resolve the stale profile (the relay's
/// canonical replaceable event stays the old one on a `created_at` tie).
///
/// # Errors
///
/// Returns [`ProfileError::Build`] if signing fails.
pub fn build_metadata_event(
    keys: &Keys,
    meta: &ProfileMetadata,
    previous_created_at: Option<u64>,
) -> Result<Event> {
    // Sanitize BEFORE the name rule, never after. `enforce_name_rule` decides
    // blankness with `str::trim`, which removes neither U+202E (not whitespace,
    // so the rule would not fire and the published object would carry no `name`
    // at all) nor the LRM/ALM/ZWNJ/ZWJ/tag characters the sanitizer
    // deliberately KEEPS. Running the sanitizer first is therefore the only
    // reason the two fields can never disagree: it — and not `trim` — is what
    // resolves an unrenderable `name` to `None` for the rule to fill.
    let mut metadata = meta.sanitized().into_metadata();
    enforce_name_rule(&mut metadata);
    EventBuilder::metadata(&metadata)
        .custom_created_at(superseding_created_at(previous_created_at))
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
/// `previous_created_at` is the `created_at` of the profile being retracted, so
/// the blank republish is stamped via [`superseding_created_at`] and wins the
/// replaceable-event race even when the delete lands in the same second as the
/// last edit — otherwise the retraction could silently fail to take effect.
///
/// # Errors
///
/// Returns [`ProfileError::Build`] if signing fails.
pub fn build_blank_metadata_event(keys: &Keys, previous_created_at: Option<u64>) -> Result<Event> {
    EventBuilder::metadata(&Metadata::default())
        .custom_created_at(superseding_created_at(previous_created_at))
        .sign_with_keys(keys)
        .map_err(ProfileError::build)
}

/// Publishes an already-built profile event to the user's write relays,
/// returning WHICH relays took it.
///
/// This is the **shared transport** used by both the ordinary publish path and
/// the retraction path. Publishing is unconditional (public-by-default); the
/// public-profile disclosure is a UI concern surfaced in onboarding and the
/// Identity settings page, not a check performed here.
///
/// Fails closed on an empty relay set ([`ProfileError::NoRelays`]). A publish
/// that reaches none-accepted (every relay rejected / did not acknowledge)
/// surfaces from [`RelayManager::publish_profile_event`] as an error, which maps
/// to a generic [`ProfileError::Relay`] — the specific per-relay `OK=false`
/// reason is intentionally **not** surfaced (no leak of relay internals to the
/// UI).
///
/// The returned [`PublishResult`] is what lets a caller distinguish a FULL
/// publish (every relay accepted) from a partial one. That distinction is not
/// cosmetic: a profile edit accepted by two of eight relays is still the old
/// name for every peer whose private assignment salt points them elsewhere, so
/// the caller must keep such an edit pending rather than report it synced.
///
/// # Errors
///
/// * [`ProfileError::NoRelays`] if `write_relays` is empty.
/// * [`ProfileError::Relay`] if no relay accepted the event.
pub async fn publish_metadata(
    relay: &RelayManager,
    event: &Event,
    write_relays: &[String],
) -> Result<PublishResult> {
    if write_relays.is_empty() {
        return Err(ProfileError::NoRelays);
    }
    // `publish_profile_event` reports a fully-unacknowledged / all-rejected
    // publish as an `Err` after its bounded retries — `AllRelaysFailed`, a
    // timeout when some relay never answered, or `DeviceClockRejected` when the
    // relays blamed this device's timestamp — and only returns `Ok` when at
    // least one relay accepted. All are mapped the same way here (a kind-0
    // publish has no clock-specific remedy to offer), so the mapped error
    // already covers the `OK=false` case; the explicit `is_success` guard below
    // is defense in depth against a future change to that contract.
    let result = relay
        .publish_profile_event(event, write_relays)
        .await
        .map_err(ProfileError::relay)?;
    if result.is_success() {
        Ok(result)
    } else {
        Err(ProfileError::Relay(
            "no relay accepted the event".to_string(),
        ))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    // `Kind` is used only by the assertions below — importing it at file scope
    // would make it dead code in a release build now that the relay-resolution
    // helpers have moved out of this module.
    use nostr::{JsonUtil, Kind};

    fn md_from(json: &str) -> ProfileMetadata {
        ProfileMetadata::from_metadata(Metadata::from_json(json).expect("valid json"))
    }

    #[test]
    fn signs_with_identity_key() {
        let keys = Keys::generate();
        let md = md_from(r#"{"display_name":"Alice"}"#);
        let event = build_metadata_event(&keys, &md, None).expect("build");
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
        let event = build_metadata_event(&keys, &md, None).expect("build");
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
        let event = build_metadata_event(&keys, &md, None).expect("build");
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
    fn threaded_republish_strictly_supersedes_even_same_second() {
        // Regression (e2e_profile name-edit): kind-0 `created_at` is Unix
        // seconds, so a same-second edit that just reused now() would TIE the
        // previous event, and NIP-01's lowest-id tie-break could keep the OLD
        // one — a peer's forced re-fetch then resolves the stale name. Threading
        // the previous `created_at` must make the republish STRICTLY newer, so it
        // supersedes deterministically regardless of sub-second timing. No sleep:
        // the collision is forced by reusing `first.created_at` as the floor,
        // exactly as the publish orchestration does.
        let keys = Keys::generate();
        let first = build_metadata_event(&keys, &md_from(r#"{"display_name":"Alice"}"#), None)
            .expect("build 1");
        let second = build_metadata_event(
            &keys,
            &md_from(r#"{"display_name":"Alice Edited"}"#),
            Some(first.created_at.as_secs()),
        )
        .expect("build 2");
        assert!(
            second.created_at > first.created_at,
            "a threaded republish must be STRICTLY newer than its predecessor: \
             first={} second={}",
            first.created_at.as_secs(),
            second.created_at.as_secs(),
        );
        assert_ne!(first.id, second.id, "distinct events");
    }

    #[test]
    fn first_publish_stamps_now_when_no_previous() {
        // With no previous (`None`) the stamp is just now() — a first publish is
        // never artificially future-dated (which some relays would reject).
        let before = Timestamp::now().as_secs();
        let event =
            build_metadata_event(&Keys::generate(), &md_from(r#"{"display_name":"A"}"#), None)
                .expect("build");
        let ca = event.created_at.as_secs();
        assert!(
            ca >= before && ca <= Timestamp::now().as_secs(),
            "first publish stamps ~now (no future-dating): ca={ca}, before={before}"
        );
    }

    #[test]
    fn blank_republish_is_empty_object() {
        let keys = Keys::generate();
        let event = build_blank_metadata_event(&keys, None).expect("build blank");
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
        let event = build_metadata_event(&keys, &md, None).expect("build");
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

    // ---- the publish path sanitizes ----------------------------------------

    #[test]
    fn a_published_name_carries_no_bidi_override() {
        // The override IS the attack: it reorders everything after it, so one
        // name renders in a peer's client as a different name entirely. Haven
        // must never be the client that puts one on the wire.
        let keys = Keys::generate();
        let md = md_from(r#"{"display_name":"Ali\u202Ece"}"#);
        let event = build_metadata_event(&keys, &md, None).expect("build");
        let parsed = Metadata::from_json(&event.content).expect("content is metadata json");
        assert_eq!(parsed.display_name.as_deref(), Some("Alice"));
        assert!(
            !event.content.contains('\u{202E}'),
            "a bidi override reached the wire: {}",
            event.content
        );
    }

    #[test]
    fn a_published_name_is_capped_at_the_grapheme_limit() {
        let keys = Keys::generate();
        let md = ProfileMetadata::from_metadata(Metadata::new().display_name("a".repeat(60)));
        let event = build_metadata_event(&keys, &md, None).expect("build");
        let parsed = Metadata::from_json(&event.content).expect("metadata");
        assert_eq!(
            parsed.display_name.as_deref(),
            Some("a".repeat(48).as_str())
        );
        assert_eq!(
            parsed.name.as_deref(),
            Some("a".repeat(48).as_str()),
            "the mirrored `name` is capped too — the two fields never disagree"
        );
    }

    #[test]
    fn a_published_name_has_its_whitespace_collapsed() {
        // Visible in the EVENT, not merely in the local row: a name broken
        // across two lines reads as one name to the eye and as two very
        // different strings to anyone comparing them.
        let keys = Keys::generate();
        let md = md_from(r#"{"display_name":"  Ada\n\n  Lovelace  "}"#);
        let event = build_metadata_event(&keys, &md, None).expect("build");
        let parsed = Metadata::from_json(&event.content).expect("metadata");
        assert_eq!(parsed.display_name.as_deref(), Some("Ada Lovelace"));
    }

    #[test]
    fn a_name_that_sanitizes_to_nothing_publishes_no_name_at_all() {
        // The choice, pinned: OMIT the field rather than refuse the publish or
        // emit an empty string. An absent name is what every consumer's
        // precedence already handles — it falls through to the npub — whereas
        // refusing would strand the user's picture and bio edits on the device
        // behind a failure with no remedy the UI could offer.
        let keys = Keys::generate();
        let md = md_from(r#"{"display_name":"\u202E\u200B","picture":"https://x.test/y.jpg"}"#);
        let event = build_metadata_event(&keys, &md, None).expect("build");
        let parsed = Metadata::from_json(&event.content).expect("metadata");
        assert_eq!(parsed.display_name, None);
        assert_eq!(parsed.name, None, "no empty-string name is published");
        assert_eq!(
            parsed.picture.as_deref(),
            Some("https://x.test/y.jpg"),
            "the rest of the profile still publishes"
        );
        assert_eq!(
            ProfileMetadata::from_metadata(parsed).resolve_display_name(),
            None,
            "a consumer falls through the precedence to the npub"
        );
    }

    #[test]
    fn a_name_that_sanitizes_to_nothing_falls_through_to_the_next_candidate() {
        let keys = Keys::generate();
        let md = md_from(r#"{"name":"alice","display_name":"\u2066\u2069"}"#);
        let event = build_metadata_event(&keys, &md, None).expect("build");
        let parsed = Metadata::from_json(&event.content).expect("metadata");
        assert_eq!(parsed.display_name, None);
        assert_eq!(
            ProfileMetadata::from_metadata(parsed).resolve_display_name(),
            Some("alice")
        );
    }

    #[test]
    fn the_name_rule_mirrors_the_sanitized_display_name_over_an_invisible_name() {
        // The ordering proof. A `name` built only from characters the sanitizer
        // removes is NOT blank to `enforce_name_rule` (U+202E is not
        // whitespace), so running the rule LAST would leave the published object
        // with no `name` at all — the NIP-24 rule silently defeated by an
        // invisible field.
        let keys = Keys::generate();
        let md = md_from(r#"{"name":"\u202E","display_name":"Alice"}"#);
        let event = build_metadata_event(&keys, &md, None).expect("build");
        let parsed = Metadata::from_json(&event.content).expect("metadata");
        assert_eq!(parsed.name.as_deref(), Some("Alice"));
        assert_eq!(parsed.display_name.as_deref(), Some("Alice"));
    }

    /// The invisible characters the sanitizer deliberately KEEPS, none of which
    /// `str::trim` removes.
    const KEPT_INVISIBLES: &[char] = &[
        '\u{200E}',
        '\u{200F}',
        '\u{061C}',
        '\u{200C}',
        '\u{200D}',
        '\u{FE0F}',
        '\u{E0041}',
    ];

    #[test]
    fn the_name_rule_mirrors_over_a_name_of_kept_invisible_characters_too() {
        // The other half of the ordering proof, and the half the strip-list
        // example above cannot reach: `trim` removes no LRM, ALM, ZWNJ, ZWJ or
        // tag character, so a `name` built from those is not blank to the rule
        // either. Haven published `{"name":"\u{200E}","display_name":"Alice"}`
        // verbatim — two names that disagree, one of them invisible — until the
        // sanitizer stopped calling an unrenderable name non-empty.
        let keys = Keys::generate();
        for invisible in KEPT_INVISIBLES {
            assert!(
                !invisible.to_string().trim().is_empty(),
                "trim cannot see it"
            );
            let md = ProfileMetadata::from_metadata(
                Metadata::new()
                    .name(invisible.to_string())
                    .display_name("Alice"),
            );
            let event = build_metadata_event(&keys, &md, None).expect("build");
            let parsed = Metadata::from_json(&event.content).expect("metadata");
            assert_eq!(
                parsed.name.as_deref(),
                Some("Alice"),
                "U+{:04X} must not survive as a name",
                *invisible as u32
            );
            assert_eq!(parsed.display_name.as_deref(), Some("Alice"));
        }
    }

    #[test]
    fn a_profile_of_only_kept_invisible_characters_publishes_no_name() {
        // With nothing to mirror, both fields must be omitted rather than
        // published as invisible text a peer's client renders as a blank row.
        let keys = Keys::generate();
        for invisible in KEPT_INVISIBLES {
            let md = ProfileMetadata::from_metadata(
                Metadata::new()
                    .name(invisible.to_string())
                    .display_name(invisible.to_string()),
            );
            let event = build_metadata_event(&keys, &md, None).expect("build");
            let parsed = Metadata::from_json(&event.content).expect("metadata");
            assert_eq!(parsed.name, None, "U+{:04X}", *invisible as u32);
            assert_eq!(parsed.display_name, None, "U+{:04X}", *invisible as u32);
        }
    }

    #[test]
    fn sanitizing_covers_the_deprecated_name_keys_without_deleting_them() {
        // Every field the name precedence can return, or the sanitizer is
        // bypassed outright by a profile carrying its payload in the legacy
        // camelCase keys. They are EMPTIED rather than removed when nothing
        // renderable survives: `custom` is what makes a republish preserve
        // another client's fields, so this must not become a delete path.
        let keys = Keys::generate();
        let md = md_from(r#"{"displayName":"ca\u2066rol","username":"\uFEFF","about":"bio"}"#);
        let event = build_metadata_event(&keys, &md, None).expect("build");
        let parsed = Metadata::from_json(&event.content).expect("metadata");
        assert_eq!(
            parsed
                .custom
                .get("displayName")
                .and_then(serde_json::Value::as_str),
            Some("carol")
        );
        assert_eq!(
            parsed
                .custom
                .get("username")
                .and_then(serde_json::Value::as_str),
            Some(""),
            "the key survives so a republish does not drop another client's field"
        );
        assert_eq!(
            ProfileMetadata::from_metadata(parsed).resolve_display_name(),
            Some("carol"),
            "an emptied key is skipped by the precedence, never rendered blank"
        );
    }

    #[test]
    fn another_clients_field_survives_a_sanitizing_publish() {
        // The preservation invariant has to hold on the path that actually
        // REWRITES a field, not only on the untouched-name path.
        let keys = Keys::generate();
        let md = md_from(
            r#"{"display_name":"Ali\u202Ece","lud16":"alice@wallet","website":"https://a.test","bot":true}"#,
        );
        let event = build_metadata_event(&keys, &md, None).expect("build");
        let parsed = Metadata::from_json(&event.content).expect("metadata");
        assert_eq!(parsed.display_name.as_deref(), Some("Alice"));
        assert_eq!(parsed.lud16.as_deref(), Some("alice@wallet"));
        assert_eq!(parsed.website.as_deref(), Some("https://a.test"));
        assert_eq!(
            parsed
                .custom
                .get("bot")
                .and_then(serde_json::Value::as_bool),
            Some(true),
            "an unknown third-party field survives a sanitizing publish"
        );
    }

    #[test]
    fn republishing_an_already_clean_profile_is_byte_identical() {
        // The shape a real republish takes: the base is what the relays hold,
        // i.e. the content of the previous publish. Sanitization is idempotent,
        // so the second pass must not drift the payload by a single byte —
        // otherwise every republish would look like a changed profile to any
        // peer diffing it.
        let keys = Keys::generate();
        let md = md_from(
            r#"{"display_name":"  Ada\u202E\nLovelace  ","lud16":"ada@wallet","bot":true}"#,
        );
        let first = build_metadata_event(&keys, &md, None).expect("build 1");
        assert_eq!(
            Metadata::from_json(&first.content)
                .expect("metadata")
                .display_name
                .as_deref(),
            Some("Ada Lovelace"),
            "the first publish is what must already be sanitized"
        );
        let second = build_metadata_event(
            &keys,
            &md_from(&first.content),
            Some(first.created_at.as_secs()),
        )
        .expect("build 2");
        assert_eq!(
            second.content, first.content,
            "a republish of an already-sanitized profile changed the payload"
        );
    }

    #[tokio::test]
    async fn publish_metadata_fails_closed_on_empty_relays() {
        let keys = Keys::generate();
        let event = build_blank_metadata_event(&keys, None).expect("build");
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
            None,
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
