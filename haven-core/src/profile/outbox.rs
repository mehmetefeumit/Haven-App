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
        }
    }

    /// Whether nothing is pending.
    #[must_use]
    pub const fn is_empty(&self) -> bool {
        self.display_name.is_none() && self.about.is_none()
    }

    /// Widens the pending set into the full [`ProfileEdits`] to publish,
    /// attaching the picture URL resolved at sync time (`None` leaves the
    /// published `picture` field untouched).
    #[must_use]
    pub fn to_edits(&self, picture: Option<String>) -> ProfileEdits {
        ProfileEdits {
            display_name: self.display_name.clone(),
            about: self.about.clone(),
            picture,
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
/// optimistically). The base is `fetched` when the relays answered with a
/// profile and `local` otherwise, so fields written by ANOTHER client are
/// preserved whenever they are reachable.
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
    let base = fetched
        .or(local)
        .map_or_else(ProfileMetadata::default, |cp| cp.metadata.clone());
    (base, floor)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::profile::merge::merge_edits;
    use crate::profile::types::ProfileState;
    use nostr::{JsonUtil, Metadata};

    fn edits(display_name: Option<&str>, about: Option<&str>) -> PendingEdits {
        PendingEdits {
            display_name: display_name.map(str::to_string),
            about: about.map(str::to_string),
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
        let older_fetch = row(r#"{"display_name":"Fetched"}"#, 100);
        let newer_local = row(r#"{"display_name":"Local"}"#, 900);
        let (base, floor) = merge_base(Some(&older_fetch), Some(&newer_local));
        assert_eq!(
            base.display_name(),
            Some("Fetched"),
            "the relay answer is still the base",
        );
        assert_eq!(floor, Some(900), "but the floor is the newest of the two");

        let (_, floor_local_branch) = merge_base(None, Some(&newer_local));
        assert_eq!(floor_local_branch, Some(900));
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
}
