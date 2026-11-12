//! The durable pending-edit set behind local-first profile editing.
//!
//! A profile edit is applied to the local cache immediately and published
//! later, so the edit itself has to survive in a form that can be replayed onto
//! whatever the relays turn out to be holding at publish time. That form is
//! [`PendingEdits`]: a sparse, serializable set of the fields the user actually
//! touched, accumulated across saves until one publish lands.
//!
//! Nothing here performs I/O or touches a relay. It is the pure half of the
//! outbox: the storage layer persists [`PendingEdits`] as JSON and reads it
//! back as a [`PendingSnapshot`], and the sync orchestration resolves the base
//! object to merge onto via [`merge_base`].

use std::cmp::Reverse;

use nostr::{Event, JsonUtil, Kind, Metadata, PublicKey, RelayUrl};
use serde::{Deserialize, Serialize};

use super::types::{CachedProfile, ProfileEdits, ProfileMetadata};

/// The fields of the local user's own profile that have been edited but not yet
/// published.
///
/// `None` means "this field was never touched since the last successful
/// publish"; `Some(value)` is the value to publish (an empty / whitespace-only
/// string clears the field — see
/// [`merge_edits`](crate::profile::merge::merge_edits)).
///
/// The picture is deliberately NOT a field here: a staged picture is bytes in
/// the cache, and its URL does not exist until the Blossom upload succeeds. The
/// storage layer tracks "a picture is staged" as its own flag and the URL is
/// supplied at publish time via [`Self::to_edits`].
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct PendingEdits {
    /// Pending `display_name`, or `None` when untouched.
    #[serde(default)]
    pub display_name: Option<String>,
    /// Pending `about`, or `None` when untouched.
    #[serde(default)]
    pub about: Option<String>,
    /// A photo removal is pending: publish an empty `picture` unless an
    /// uploaded URL supersedes it.
    #[serde(default)]
    pub clear_picture: bool,
    /// The `local_version` the pending removal was staged at.
    #[serde(default)]
    pub clear_version: i64,
    /// A pass already signed these edits afresh because a relay refused the
    /// owed copy as too old. Once per edit: a relay refusing every timestamp
    /// would otherwise force a new event onto the healthy relays every pass.
    #[serde(default)]
    pub resigned: bool,
}

impl PendingEdits {
    /// Folds a newer save onto this one, field by field.
    ///
    /// The newer value wins wherever it names a field; where it does not, the
    /// older pending value survives. Accumulating (rather than replacing) is
    /// what stops a second save from silently discarding an earlier unpublished
    /// one: editing the name and then the bio must publish BOTH, not just the
    /// bio.
    #[must_use]
    pub fn accumulate(&self, newer: &Self) -> Self {
        Self {
            display_name: newer
                .display_name
                .clone()
                .or_else(|| self.display_name.clone()),
            about: newer.about.clone().or_else(|| self.about.clone()),
            clear_picture: self.clear_picture || newer.clear_picture,
            clear_version: self.clear_version.max(newer.clear_version),
            resigned: newer.resigned,
        }
    }

    /// Whether nothing is pending.
    #[must_use]
    pub const fn is_empty(&self) -> bool {
        self.display_name.is_none() && self.about.is_none() && !self.clear_picture
    }

    /// Widens the pending set into the full [`ProfileEdits`] to publish,
    /// attaching the picture URL resolved at sync time. Without one, a pending
    /// removal publishes an empty `picture`; otherwise the published `picture`
    /// field is left untouched.
    #[must_use]
    pub fn to_edits(&self, picture: Option<String>) -> ProfileEdits {
        ProfileEdits {
            display_name: self.display_name.clone(),
            about: self.about.clone(),
            picture: picture.or_else(|| self.clear_picture.then(String::new)),
        }
    }
}

/// One consistent read of the outbox: what is pending, at which local version.
///
/// `local_version` is the counter the commit path compares against
/// (compare-and-set): a sync may only clear the pending set for the exact
/// version it published, so an edit saved WHILE that publish was in flight
/// stays pending instead of being reported as synced.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct PendingSnapshot {
    /// The local edit counter this snapshot was taken at.
    pub local_version: i64,
    /// The accumulated unpublished field edits.
    pub edits: PendingEdits,
    /// Whether sanitized picture bytes are staged for upload.
    pub picture_staged: bool,
}

/// Resolves the metadata object a pending sync must merge its edits onto, plus
/// the `created_at` floor that keeps the republish strictly superseding.
///
/// `fetched` is the newest kind-0 any relay answered with during this sync;
/// `local` is the cached row (which already carries the pending edits applied
/// optimistically). The callers cache `fetched` into that row first when it
/// is newer, so a publish that fails after this still leaves the row at the
/// newest copy read. The base is `fetched` when it is at least as new as the
/// local row, so fields written by ANOTHER client are preserved whenever they
/// are reachable, and `local` otherwise.
///
/// # Why an older answer is not the base
///
/// A relay may serve a superseded copy of our own profile — genuinely signed,
/// so nothing about the event refuses it — while the relays holding the newest
/// are slow or down. Merging onto it would sign back, under the identity key,
/// every field removed since: a payment address, a photo, a name. The local
/// row is the record of the newer own event: its whole metadata object, the
/// fields Haven does not model included, as this device published or fetched
/// it, with the edits being synced already on top (pinned by
/// `the_cached_own_row_keeps_every_field_of_the_event_it_records`).
///
/// The returned floor is `max(fetched.created_at, local.created_at)` in BOTH
/// branches — never just the chosen base's. Falling back to a local row while
/// stamping only the local `created_at` would let a republish tie or lose the
/// NIP-01 replaceable-event race against a newer event we already knew about,
/// and the edit would silently fail to take effect.
///
/// # What a total read miss costs, precisely
///
/// When no relay returned a kind-0 the base is our own stale copy, so relative
/// to the true newest object:
///
/// * a field another client **added** since our last successful fetch is
///   **lost** (we republish without it), and
/// * a field another client **changed** is **reverted** to the value we last
///   saw — the stronger of the two, and the one that reads as data loss rather
///   than staleness.
///
/// Neither can produce a malformed profile: the output is always a complete,
/// well-formed object built from metadata this device previously read.
///
/// This requires a TOTAL relay read failure (every pool relay unreachable or
/// silent), and the alternative — refusing to publish — strands the user's own
/// edit on their device for as long as they are offline, which is the failure
/// this whole path exists to remove. Accepted deliberately; pinned by test.
#[must_use]
pub fn merge_base(
    fetched: Option<&CachedProfile>,
    local: Option<&CachedProfile>,
) -> (ProfileMetadata, Option<u64>) {
    let floor = [fetched, local]
        .into_iter()
        .flatten()
        // A negative stored `created_at` is not a Nostr timestamp; drop it
        // rather than saturating it into a floor that would future-date the
        // republish.
        .filter_map(|cp| u64::try_from(cp.event_created_at).ok())
        .max();
    let stale = |fetched: &CachedProfile| {
        local.is_some_and(|local| fetched.event_created_at < local.event_created_at)
    };
    let base = fetched
        .filter(|fetched| !stale(fetched))
        .or(local)
        .map_or_else(ProfileMetadata::default, |cp| cp.metadata.clone());
    (base, floor)
}

/// How a relay's answer to an own-author `REQ` stands against the event we
/// sent it.
#[derive(Debug, PartialEq, Eq)]
pub enum Served {
    /// The newest own kind-0 it serves is ours.
    Holds,
    /// It serves an own kind-0 that NIP-01 orders after ours.
    Newer,
    /// It serves only older own kind-0s, or none.
    Lacks,
}

/// Orders what a relay served against `ours` by NIP-01 replaceable order
/// (later `created_at`, then the lower id).
///
/// An OK is no evidence: relays answer OK true to an older replaceable they
/// will not store. An own kind-0 whose content is not metadata is skipped, as
/// [`parse_newest_metadata`](super::parse::parse_newest_metadata) skips it.
#[must_use]
pub fn served_against(own: &PublicKey, ours: &Event, served: &[Event]) -> Served {
    let newest = served
        .iter()
        .filter(|e| {
            e.pubkey == *own && e.kind == Kind::Metadata && Metadata::from_json(&e.content).is_ok()
        })
        .max_by_key(|e| (e.created_at, Reverse(e.id)));
    match newest {
        Some(e) if e.id == ours.id => Served::Holds,
        Some(e) if (e.created_at, Reverse(e.id)) > (ours.created_at, Reverse(ours.id)) => {
            Served::Newer
        }
        _ => Served::Lacks,
    }
}

/// The pool relays, as given and in pool order, that `covered` does not name.
///
/// Compared in parsed form, so a trailing slash or a host's case cannot make a
/// covered relay owed again.
#[must_use]
pub fn uncovered(pool: &[String], covered: &[String]) -> Vec<String> {
    let parsed = |url: &str| RelayUrl::parse(url).ok();
    let covered: Vec<Option<RelayUrl>> = covered.iter().map(|c| parsed(c)).collect();
    pool.iter()
        .filter(|relay| {
            let relay = parsed(relay);
            relay.is_none() || !covered.contains(&relay)
        })
        .cloned()
        .collect()
}

/// Loads a persisted owed kind-0 only if it is still a genuine own metadata
/// event: the bytes must hash to their id under a valid signature.
#[must_use]
pub fn owed_event_from_json(json: &str, own: &PublicKey) -> Option<Event> {
    Event::from_json(json)
        .ok()
        .filter(|e| e.verify().is_ok() && e.pubkey == *own && e.kind == Kind::Metadata)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::profile::merge::merge_edits;
    use crate::profile::publish::build_metadata_event;
    use crate::profile::types::ProfileState;
    use nostr::{JsonUtil, Keys, Metadata};

    fn edits(display_name: Option<&str>, about: Option<&str>) -> PendingEdits {
        PendingEdits {
            display_name: display_name.map(str::to_string),
            about: about.map(str::to_string),
            ..PendingEdits::default()
        }
    }

    fn row(json: &str, created_at: i64) -> CachedProfile {
        CachedProfile {
            pubkey_hex: "ab".repeat(32),
            metadata: ProfileMetadata::from_metadata(
                Metadata::from_json(json).expect("valid json"),
            ),
            state: ProfileState::Known,
            event_created_at: created_at,
            fetched_at: 0,
        }
    }

    // ---- accumulate --------------------------------------------------------

    #[test]
    fn accumulate_lets_the_newer_value_win() {
        let out = edits(Some("Old"), None).accumulate(&edits(Some("New"), None));
        assert_eq!(out.display_name.as_deref(), Some("New"));
    }

    #[test]
    fn accumulate_keeps_an_earlier_unpublished_edit_to_another_field() {
        // THE reason this is an accumulate and not a replace: renaming and then
        // editing the bio must publish both. A replace would drop the rename
        // with no error anywhere.
        let out = edits(Some("Renamed"), None).accumulate(&edits(None, Some("bio")));
        assert_eq!(out.display_name.as_deref(), Some("Renamed"));
        assert_eq!(out.about.as_deref(), Some("bio"));
    }

    #[test]
    fn accumulate_preserves_a_pending_clear() {
        // `Some("")` means "clear this field" — it is a real pending edit and
        // must not be mistaken for "untouched" and dropped.
        let out = edits(None, None).accumulate(&edits(Some(""), None));
        assert_eq!(out.display_name.as_deref(), Some(""));
        assert!(!out.is_empty(), "a pending clear is pending work");
    }

    #[test]
    fn accumulate_of_two_empty_sets_stays_empty() {
        let out = PendingEdits::default().accumulate(&PendingEdits::default());
        assert!(out.is_empty());
        assert_eq!(out, PendingEdits::default());
    }

    // ---- to_edits ----------------------------------------------------------

    #[test]
    fn to_edits_carries_the_pending_fields_and_the_supplied_picture() {
        let out = edits(Some("Alice"), Some("hi")).to_edits(Some("https://x/y.jpg".to_string()));
        assert_eq!(
            out,
            ProfileEdits {
                display_name: Some("Alice".to_string()),
                about: Some("hi".to_string()),
                picture: Some("https://x/y.jpg".to_string()),
            }
        );
    }

    #[test]
    fn to_edits_without_a_picture_leaves_the_published_picture_untouched() {
        // `None` (not `Some("")`) — a sync that uploaded nothing must not clear
        // a picture the user still has.
        assert_eq!(edits(Some("Alice"), None).to_edits(None).picture, None);
    }

    // ---- serde -------------------------------------------------------------

    #[test]
    fn pending_edits_round_trip_through_json() {
        // The outbox row persists this as JSON; a round-trip that lost the
        // distinction between "untouched" and "clear" would republish the
        // wrong object.
        for original in [
            PendingEdits::default(),
            edits(Some("Alice"), None),
            edits(Some(""), Some("bio")),
        ] {
            let json = serde_json::to_string(&original).expect("serialize");
            let back: PendingEdits = serde_json::from_str(&json).expect("deserialize");
            assert_eq!(back, original, "round-trip changed the pending set: {json}");
        }
    }

    #[test]
    fn an_empty_json_object_deserializes_as_nothing_pending() {
        // The column's default value is `{}`; it must read back as "nothing
        // pending" rather than failing the read and stranding the outbox.
        let back: PendingEdits = serde_json::from_str("{}").expect("deserialize");
        assert!(back.is_empty());
    }

    // ---- merge_base --------------------------------------------------------

    #[test]
    fn merge_base_prefers_the_fetched_row() {
        let fetched = row(r#"{"display_name":"Fetched"}"#, 200);
        let local = row(r#"{"display_name":"Local"}"#, 100);
        let (base, floor) = merge_base(Some(&fetched), Some(&local));
        assert_eq!(base.display_name(), Some("Fetched"));
        assert_eq!(floor, Some(200));
    }

    #[test]
    fn merge_base_falls_back_to_local_on_a_total_read_miss() {
        let local = row(r#"{"display_name":"Local"}"#, 100);
        let (base, floor) = merge_base(None, Some(&local));
        assert_eq!(base.display_name(), Some("Local"));
        assert_eq!(floor, Some(100));
    }

    #[test]
    fn merge_base_floors_on_the_newest_row_in_both_branches() {
        // The floor is what makes the republish supersede under NIP-01. Taking
        // only the CHOSEN base's `created_at` would let a fallback republish
        // tie the newer event we already knew about, and the edit would
        // silently not take effect.
        let newer_fetch = row(r#"{"display_name":"Fetched"}"#, 900);
        let older_local = row(r#"{"display_name":"Local"}"#, 100);
        let (_, floor) = merge_base(Some(&newer_fetch), Some(&older_local));
        assert_eq!(floor, Some(900));

        let older_fetch = row(r#"{"display_name":"Fetched"}"#, 100);
        let newer_local = row(r#"{"display_name":"Local"}"#, 900);
        let (_, floor) = merge_base(Some(&older_fetch), Some(&newer_local));
        assert_eq!(floor, Some(900), "the floor is the newest of the two");

        let (_, floor_local_branch) = merge_base(None, Some(&newer_local));
        assert_eq!(floor_local_branch, Some(900));
    }

    #[test]
    fn merge_base_takes_a_newer_local_row_over_a_stale_fetched_one() {
        // A relay may answer with an OLD copy of our own profile: genuinely
        // signed, and superseded. The local row records a newer own event, so
        // merging onto the relay's copy would sign back every field removed
        // since — a payment address, a photo, a field another client dropped.
        let stale = row(
            r#"{"display_name":"Old","lud16":"old@wallet","picture":"https://old.example/a.jpg","gone":true}"#,
            100,
        );
        let local = row(r#"{"display_name":"Me"}"#, 900);
        let (base, floor) = merge_base(Some(&stale), Some(&local));
        let republished = merge_edits(&base, &edits(None, Some("bio")).to_edits(None));
        let published = republished.as_metadata();
        assert_eq!(republished.display_name(), Some("Me"));
        assert_eq!(published.about.as_deref(), Some("bio"));
        assert_eq!(published.lud16, None);
        assert_eq!(published.picture, None);
        assert!(!published.custom.contains_key("gone"));
        assert_eq!(floor, Some(900));
    }

    #[test]
    fn merge_base_takes_the_fetched_row_on_a_tie_and_when_nothing_is_cached() {
        // Equal `created_at` is the same event, or one we cannot order: the
        // relay's copy carries the name as typed and anything another client
        // wrote in that second.
        let fetched = row(
            r#"{"display_name":"Fetched","website":"https://w.example"}"#,
            500,
        );
        let local = row(r#"{"display_name":"Local"}"#, 500);
        let (base, floor) = merge_base(Some(&fetched), Some(&local));
        assert_eq!(base.display_name(), Some("Fetched"));
        assert_eq!(floor, Some(500));

        let (base, floor) = merge_base(Some(&fetched), None);
        assert_eq!(base.display_name(), Some("Fetched"));
        assert_eq!(floor, Some(500));
    }

    #[test]
    fn merge_base_without_any_row_is_a_first_publish() {
        let (base, floor) = merge_base(None, None);
        assert_eq!(base, ProfileMetadata::default());
        assert_eq!(floor, None, "no floor ⇒ the event is stamped `now`");
    }

    #[test]
    fn merge_base_ignores_a_negative_stored_created_at() {
        // A negative value is not a Nostr timestamp. Saturating it into `0`
        // would be harmless, but converting it into a floor at all would be
        // asserting knowledge we do not have.
        let local = row("{}", -5);
        assert_eq!(merge_base(None, Some(&local)).1, None);
    }

    #[test]
    fn a_total_read_miss_reverts_a_field_another_client_changed() {
        // The documented, accepted cost — asserted rather than described, so a
        // future change to the fallback cannot quietly make the doc a lie.
        // Our stale copy holds the OLD website; the true newest (unreachable)
        // holds a new one. Republishing from the fallback reverts it.
        let local = row(
            r#"{"display_name":"Me","website":"https://old.example"}"#,
            10,
        );
        let (base, _) = merge_base(None, Some(&local));
        let republished = merge_edits(&base, &edits(Some("Me v2"), None).to_edits(None));
        assert_eq!(
            republished.as_metadata().website.as_deref(),
            Some("https://old.example"),
            "the stale value is republished — a concurrent change is REVERTED, \
             not merely missing",
        );
        assert_eq!(republished.display_name(), Some("Me v2"));
    }

    #[test]
    fn the_published_name_is_the_same_whether_the_base_was_fetched_or_local() {
        // The asymmetry this closes. The base is normally the freshly-FETCHED
        // relay copy, which carries the name exactly as it was typed
        // (`newest_own_copy` builds it in memory and never touches the DB
        // sanitizer), and falls back to the SANITIZED local row only when every
        // pool relay is unreachable. Sanitizing in the builder is what makes
        // both paths emit the same bytes, so what leaves the device does not
        // depend on network conditions.
        let keys = Keys::generate();
        let fetched = row(r#"{"display_name":"Ali\u202Ece"}"#, 100);
        let local = row(r#"{"display_name":"Alice"}"#, 100);

        let publish = |fetched: Option<&CachedProfile>| {
            let (base, floor) = merge_base(fetched, Some(&local));
            let merged = merge_edits(&base, &PendingEdits::default().to_edits(None));
            build_metadata_event(&keys, &merged, floor)
                .expect("build")
                .content
        };

        assert_eq!(
            publish(Some(&fetched)),
            publish(None),
            "the published payload changed with the relay read outcome"
        );
    }

    #[test]
    fn a_total_read_miss_never_produces_a_malformed_object() {
        // The other half of the promise: whatever is lost, the published object
        // is always a complete, well-formed kind-0 payload.
        let local = row(
            r#"{"display_name":"Me","lud16":"me@wallet","bot":true}"#,
            10,
        );
        let (base, _) = merge_base(None, Some(&local));
        let republished = merge_edits(&base, &edits(None, Some("bio")).to_edits(None));
        let json = republished.as_metadata().as_json();
        let reparsed = Metadata::from_json(&json).expect("republished payload is valid metadata");
        assert_eq!(reparsed.about.as_deref(), Some("bio"));
        assert_eq!(reparsed.lud16.as_deref(), Some("me@wallet"));
        assert_eq!(
            reparsed
                .custom
                .get("bot")
                .and_then(serde_json::Value::as_bool),
            Some(true),
            "unknown fields this device DID see still survive the fallback",
        );
    }

    // ---- the pending photo removal -----------------------------------------

    use nostr::{Event, EventBuilder, Kind, PublicKey, Timestamp};

    fn removal(clear_version: i64) -> PendingEdits {
        PendingEdits {
            clear_picture: true,
            clear_version,
            ..PendingEdits::default()
        }
    }

    #[test]
    fn a_pending_clear_survives_accumulate_and_json_and_old_rows_decode_without_it() {
        // The removal is a pending edit like the others: a later save must not
        // swallow it, and a row written before it existed must still decode.
        let folded = removal(3).accumulate(&edits(Some("Renamed"), None));
        assert!(folded.clear_picture, "a later save dropped the removal");
        assert_eq!(folded.clear_version, 3);
        assert_eq!(folded.display_name.as_deref(), Some("Renamed"));
        let folded = PendingEdits::default().accumulate(&removal(2));
        assert!(folded.clear_picture && folded.clear_version == 2);

        // A newer removal wins the version either way round, so a removal
        // staged after a new photo is still published.
        assert_eq!(removal(2).accumulate(&removal(5)).clear_version, 5);
        assert_eq!(removal(5).accumulate(&removal(2)).clear_version, 5);

        assert!(
            !removal(1).is_empty(),
            "a lone removal is pending work, or nothing would publish it"
        );
        let json = serde_json::to_string(&removal(4)).expect("serialize");
        let back: PendingEdits = serde_json::from_str(&json).expect("deserialize");
        assert_eq!(back, removal(4), "round-trip changed the removal: {json}");

        let old: PendingEdits =
            serde_json::from_str(r#"{"display_name":"Alice","about":null}"#).expect("old row");
        assert!(!old.clear_picture);
        assert_eq!(old.clear_version, 0);
        assert_eq!(old.display_name.as_deref(), Some("Alice"));
    }

    #[test]
    fn a_fresh_save_resets_the_resigned_mark_and_old_rows_decode_without_it() {
        let resigned = PendingEdits {
            resigned: true,
            ..edits(Some("Signed Twice"), None)
        };
        let folded = resigned.accumulate(&edits(None, Some("bio")));
        assert!(!folded.resigned, "a new edit earns one fresh signing again");
        assert_eq!(folded.display_name.as_deref(), Some("Signed Twice"));
        assert!(
            PendingEdits::default().accumulate(&resigned).resigned,
            "the newer set's mark is the one kept",
        );
        assert!(
            PendingEdits {
                resigned: true,
                ..PendingEdits::default()
            }
            .is_empty(),
            "the mark alone is not pending work",
        );
        let json = serde_json::to_string(&resigned).expect("serialize");
        let back: PendingEdits = serde_json::from_str(&json).expect("deserialize");
        assert_eq!(back, resigned, "round-trip lost the mark: {json}");
        let old: PendingEdits =
            serde_json::from_str(r#"{"display_name":"Alice","clear_picture":true}"#)
                .expect("old row");
        assert!(!old.resigned);
    }

    #[test]
    fn to_edits_clears_the_picture_for_a_pending_removal() {
        assert_eq!(removal(1).to_edits(None).picture.as_deref(), Some(""));
        assert_eq!(
            removal(1)
                .to_edits(Some("https://x/new.jpg".to_string()))
                .picture
                .as_deref(),
            Some("https://x/new.jpg"),
            "an uploaded URL wins over a removal staged before it"
        );
        assert_eq!(
            edits(Some("Alice"), None).to_edits(None).picture,
            None,
            "without a removal the published picture stays untouched"
        );
        let base = row(
            r#"{"display_name":"Me","picture":"https://x/old.jpg"}"#,
            100,
        )
        .metadata;
        let published = merge_edits(&base, &removal(1).to_edits(None));
        assert_eq!(published.picture(), None, "the removal strips the picture");
        assert_eq!(published.display_name(), Some("Me"));
    }

    // ---- served_against / uncovered -----------------------------------------

    fn kind0(keys: &Keys, content: &str, created_at: u64) -> Event {
        EventBuilder::new(Kind::Metadata, content)
            .custom_created_at(Timestamp::from(created_at))
            .sign_with_keys(keys)
            .expect("sign kind0")
    }

    /// Two events of one author at one second: `(lower id, higher id)`.
    fn tied_pair(keys: &Keys, created_at: u64) -> (Event, Event) {
        let a = kind0(keys, r#"{"name":"tie-a"}"#, created_at);
        let b = kind0(keys, r#"{"name":"tie-b"}"#, created_at);
        if a.id < b.id {
            (a, b)
        } else {
            (b, a)
        }
    }

    #[test]
    fn served_against_holds_only_for_our_own_id() {
        let keys = Keys::generate();
        let own = keys.public_key();
        let ours = kind0(&keys, r#"{"name":"ours"}"#, 100);
        let older = kind0(&keys, r#"{"name":"older"}"#, 50);
        assert_eq!(
            served_against(&own, &ours, std::slice::from_ref(&ours)),
            Served::Holds
        );
        assert_eq!(
            served_against(&own, &ours, &[older, ours.clone()]),
            Served::Holds,
            "an older revision beside ours does not change the verdict"
        );

        // The relay serves an event NIP-01 ranks below ours at the same second:
        // it does not hold ours, whatever its OK said.
        let (lower, higher) = tied_pair(&keys, 200);
        assert_eq!(served_against(&own, &lower, &[higher]), Served::Lacks);
    }

    #[test]
    fn served_against_reads_a_later_created_at_as_newer() {
        let keys = Keys::generate();
        let own = keys.public_key();
        let ours = kind0(&keys, r#"{"name":"ours"}"#, 100);
        let later = kind0(&keys, r#"{"name":"later"}"#, 101);
        assert_eq!(
            served_against(&own, &ours, std::slice::from_ref(&later)),
            Served::Newer
        );
        assert_eq!(
            served_against(&own, &ours, &[ours.clone(), later]),
            Served::Newer,
            "serving ours as well does not hide the newer copy"
        );
    }

    #[test]
    fn served_against_reads_a_tie_with_a_lower_id_as_newer() {
        // NIP-01 keeps the lowest id on a tie, so a relay serving the lower id
        // has replaced ours even though both are dated alike.
        let keys = Keys::generate();
        let own = keys.public_key();
        let (lower, higher) = tied_pair(&keys, 300);
        assert_eq!(served_against(&own, &higher, &[lower]), Served::Newer);
    }

    #[test]
    fn served_against_reads_older_or_nothing_as_lacking() {
        let keys = Keys::generate();
        let own = keys.public_key();
        let ours = kind0(&keys, r#"{"name":"ours"}"#, 100);
        assert_eq!(served_against(&own, &ours, &[]), Served::Lacks);
        let older = kind0(&keys, r#"{"name":"older"}"#, 99);
        assert_eq!(served_against(&own, &ours, &[older]), Served::Lacks);
    }

    #[test]
    fn served_against_ignores_an_own_kind0_whose_content_is_not_metadata() {
        // The redirect caches through `newest_own_copy`, which skips such an
        // event: read as newer, it would redirect onto nothing and force a
        // fresh whole-pool signing on every pass.
        let keys = Keys::generate();
        let own = keys.public_key();
        let ours = kind0(&keys, r#"{"name":"ours"}"#, 100);
        let malformed = kind0(&keys, "not metadata", 900);
        assert_eq!(
            served_against(&own, &ours, std::slice::from_ref(&malformed)),
            Served::Lacks
        );
        assert_eq!(
            served_against(&own, &ours, &[malformed, ours.clone()]),
            Served::Holds
        );
    }

    #[test]
    fn served_against_ignores_other_authors_and_kinds() {
        // A relay may answer a single-author REQ with anything. Only our own
        // kind-0s order against ours.
        let keys = Keys::generate();
        let own = keys.public_key();
        let ours = kind0(&keys, r#"{"name":"ours"}"#, 100);
        let stranger = kind0(&Keys::generate(), r#"{"name":"theirs"}"#, 900);
        let own_note = EventBuilder::new(Kind::TextNote, "hello")
            .custom_created_at(Timestamp::from(900))
            .sign_with_keys(&keys)
            .expect("sign note");
        assert_eq!(
            served_against(&own, &ours, &[stranger.clone(), own_note.clone()]),
            Served::Lacks,
            "another author's or another kind's newer event was read as ours"
        );
        assert_eq!(
            served_against(&own, &ours, &[stranger, own_note, ours.clone()]),
            Served::Holds
        );
    }

    #[test]
    fn uncovered_compares_relays_in_their_parsed_form() {
        let pool = vec![
            "wss://a.example".to_string(),
            "wss://B.example/".to_string(),
            "wss://c.example".to_string(),
        ];
        let covered = vec![
            "wss://A.example/".to_string(),
            "wss://b.example".to_string(),
        ];
        assert_eq!(
            uncovered(&pool, &covered),
            vec!["wss://c.example".to_string()],
            "a trailing slash or a host's case made a covered relay owed again"
        );
        assert_eq!(uncovered(&pool, &pool), Vec::<String>::new());
        assert_eq!(uncovered(&pool, &[]), pool, "pool order is kept");
        assert_eq!(
            uncovered(&pool[..1], &["wss://other.example".to_string()]),
            vec!["wss://a.example".to_string()],
            "a relay outside the pool covers nothing in it"
        );
    }

    // ---- owed_event_from_json ----------------------------------------------

    #[test]
    fn owed_event_from_json_refuses_a_tampered_signature_another_author_and_another_kind() {
        let keys = Keys::generate();
        let own: PublicKey = keys.public_key();
        let event = kind0(&keys, r#"{"name":"owed"}"#, 100);
        assert_eq!(
            owed_event_from_json(&event.as_json(), &own),
            Some(event.clone()),
            "anti-vacuity: an untouched owed event loads"
        );

        let tampered = event
            .as_json()
            .replace(r#"{\"name\":\"owed\"}"#, r#"{\"name\":\"forged\"}"#);
        assert_ne!(tampered, event.as_json(), "the tamper changed nothing");
        assert_eq!(
            owed_event_from_json(&tampered, &own),
            None,
            "bytes that do not hash to their id are not ours to send"
        );

        assert_eq!(
            owed_event_from_json(&event.as_json(), &Keys::generate().public_key()),
            None,
            "an event of another author"
        );
        let note = EventBuilder::new(Kind::TextNote, "owed")
            .sign_with_keys(&keys)
            .expect("sign note");
        assert_eq!(
            owed_event_from_json(&note.as_json(), &own),
            None,
            "an own event of another kind"
        );
        assert_eq!(owed_event_from_json("not json", &own), None);
        assert_eq!(owed_event_from_json("", &own), None);
    }
}
