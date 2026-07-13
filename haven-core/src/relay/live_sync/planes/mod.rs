//! Subscription planes and relay-set bucketing.
//!
//! Two planes carry all live traffic:
//! - **Group** (`kind:445`, multiplexed by `#h`) — see [`group`].
//! - **Inbox** (`kind:1059`, by `#p`) — see [`inbox`].
//!
//! Circles are bucketed by their *normalized* relay set so circles sharing a
//! relay set collapse to a single multiplexed REQ on a single socket
//! (amplification reduction). Each bucket gets a stable, per-session subscription
//! id derived from an ephemeral salt so a relay cannot link a user's
//! subscriptions across app sessions (PSI-2).

pub mod group;
pub mod inbox;

use std::collections::BTreeMap;

use nostr::SubscriptionId;
use sha2::{Digest, Sha256};

use super::config::SUB_ID_PREFIX_BYTES;

/// Which plane a subscription belongs to.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PlaneKind {
    /// `kind:445` group messages (multiplexed by `#h`).
    Group,
    /// `kind:1059` gift-wrapped invitations (by `#p`).
    Inbox,
}

impl PlaneKind {
    /// The lowercase plane label embedded in subscription ids.
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Group => "group",
            Self::Inbox => "inbox",
        }
    }
}

/// A circle's identity for subscription bucketing.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CircleSpec {
    /// `hex(nostr_group_id)` — the pseudonymous id, never the MLS group id.
    pub group_id_hex: String,
    /// The circle's relay set (un-normalized; normalized during bucketing).
    pub relays: Vec<String>,
}

/// One multiplexed group subscription over a shared relay set.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GroupSubscription {
    /// Normalized, sorted, deduplicated relay URLs.
    pub relays: Vec<String>,
    /// The `hex(nostr_group_id)` values multiplexed into this REQ's `#h`.
    pub group_ids_hex: Vec<String>,
    /// Stable per-session subscription id.
    pub sub_id: SubscriptionId,
}

/// The single inbox subscription.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct InboxSubscription {
    /// Normalized, sorted, deduplicated inbox relay URLs.
    pub relays: Vec<String>,
    /// Stable per-session subscription id.
    pub sub_id: SubscriptionId,
}

/// Normalizes a relay URL for set comparison: trims surrounding whitespace,
/// lowercases, and strips any trailing `/`(s).
///
/// Connection still uses the original casing where it matters; this canonical
/// form is only for bucketing and dedup so `wss://R/` and `wss://r` collapse to
/// one connection.
#[must_use]
pub fn normalize_relay_url(url: &str) -> String {
    let trimmed = url.trim().trim_end_matches('/');
    trimmed.to_lowercase()
}

/// Normalizes, deduplicates, and sorts a relay set into a canonical vec.
#[must_use]
pub fn canonical_relay_set(relays: &[String]) -> Vec<String> {
    let mut set: Vec<String> = relays
        .iter()
        .map(|r| normalize_relay_url(r))
        .filter(|r| !r.is_empty())
        .collect();
    set.sort();
    set.dedup();
    set
}

/// Derives a stable, per-session, redaction-safe subscription id.
///
/// `sub_id = hex(SHA256(salt ‖ own_pubkey ‖ plane ‖ idx)[..8]) + "_{plane}_{idx}"`.
/// The 16-hex digest prefix sits at the `redact_hex_sequences` floor so a logged
/// sub-id is auto-redacted; the `_{plane}_{idx}` suffix discloses group-vs-inbox
/// to the relay *by design*. The salt is per-session ephemeral, so two sessions
/// for the same pubkey produce different ids (PSI-2).
#[must_use]
pub fn derive_sub_id(
    salt: &[u8; 16],
    own_pubkey: &[u8],
    plane: PlaneKind,
    idx: usize,
) -> SubscriptionId {
    let mut hasher = Sha256::new();
    hasher.update(salt);
    hasher.update(own_pubkey);
    hasher.update(plane.as_str().as_bytes());
    hasher.update(idx.to_le_bytes());
    let digest = hasher.finalize();
    let prefix = hex::encode(&digest[..SUB_ID_PREFIX_BYTES]);
    SubscriptionId::new(format!("{prefix}_{}_{idx}", plane.as_str()))
}

/// Derives a stable, per-session, redaction-safe subscription id for a circle
/// added mid-session via `LiveSyncCore::subscribe_circle` (a "dynamic
/// singleton").
///
/// `sub_id = hex(SHA256(salt ‖ own_pubkey ‖ "group_dyn" ‖ group_id_hex)[..N]) +
/// "_group_dyn"`, where `N` = [`SUB_ID_PREFIX_BYTES`] (so the redaction-floor
/// coupling can never silently drift from the base-bucket derivation).
///
/// Keyed by the pseudonymous `group_id_hex` — NEVER a positional index — with a
/// `"group_dyn"` domain separator, so it can never collide with a base bucket's
/// [`derive_sub_id`] (which hashes `plane ‖ idx`). An idx collision would
/// NIP-01-clobber a live bucket's `#h` filter, so the hex key is load-bearing.
/// Two circles differ by their hex; the same circle is stable within a session
/// (same salt), and the salt is per-session ephemeral so it is unlinkable across
/// sessions (PSI-2). The 16-hex prefix sits at the `redact_hex_sequences` floor
/// so a logged id auto-redacts; the `_group_dyn` suffix discloses only "a
/// dynamically-added group sub" — the relay already sees the mid-session REQ
/// arrive — and never the `group_id_hex` itself (Security Rule 4/6).
#[must_use]
pub fn derive_dynamic_group_sub_id(
    salt: &[u8; 16],
    own_pubkey: &[u8],
    group_id_hex: &str,
) -> SubscriptionId {
    let mut hasher = Sha256::new();
    hasher.update(salt);
    hasher.update(own_pubkey);
    hasher.update(b"group_dyn");
    hasher.update(group_id_hex.as_bytes());
    let digest = hasher.finalize();
    let prefix = hex::encode(&digest[..SUB_ID_PREFIX_BYTES]);
    SubscriptionId::new(format!("{prefix}_group_dyn"))
}

/// Buckets circles by shared relay set and builds the per-bucket group
/// subscriptions plus the single inbox subscription.
///
/// Circles whose canonical relay set is identical collapse into one
/// [`GroupSubscription`] (one multiplexed `#h` REQ). Buckets are ordered by
/// their relay-set key so the assigned `idx` — and therefore the derived
/// [`SubscriptionId`] — is deterministic within a session.
#[must_use]
pub fn build_relay_set_subscriptions(
    salt: &[u8; 16],
    own_pubkey: &[u8],
    circles: &[CircleSpec],
    inbox_relays: &[String],
) -> (Vec<GroupSubscription>, InboxSubscription) {
    // Group circles' hex ids by their canonical relay set. BTreeMap keeps the
    // bucket order deterministic (sorted by the joined relay-set key).
    let mut buckets: BTreeMap<Vec<String>, Vec<String>> = BTreeMap::new();
    for circle in circles {
        let key = canonical_relay_set(&circle.relays);
        if key.is_empty() {
            continue; // a circle with no usable relays cannot be subscribed
        }
        buckets
            .entry(key)
            .or_default()
            .push(circle.group_id_hex.clone());
    }

    let group_subs = buckets
        .into_iter()
        .enumerate()
        .map(|(idx, (relays, mut group_ids_hex))| {
            group_ids_hex.sort();
            group_ids_hex.dedup();
            GroupSubscription {
                relays,
                group_ids_hex,
                sub_id: derive_sub_id(salt, own_pubkey, PlaneKind::Group, idx),
            }
        })
        .collect();

    let inbox = InboxSubscription {
        relays: canonical_relay_set(inbox_relays),
        sub_id: derive_sub_id(salt, own_pubkey, PlaneKind::Inbox, 0),
    };

    (group_subs, inbox)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn circle(id: &str, relays: &[&str]) -> CircleSpec {
        CircleSpec {
            group_id_hex: id.to_string(),
            relays: relays.iter().map(|r| (*r).to_string()).collect(),
        }
    }

    #[test]
    fn normalize_lowercases_and_strips_trailing_slash() {
        assert_eq!(normalize_relay_url("wss://Relay.IO/"), "wss://relay.io");
        assert_eq!(normalize_relay_url("  wss://relay.io  "), "wss://relay.io");
        // Multiple trailing slashes collapse (pins the strip-all behavior).
        assert_eq!(normalize_relay_url("wss://relay.io///"), "wss://relay.io");
        // Whitespace-only / empty normalize to empty (filtered by canonical set).
        assert_eq!(normalize_relay_url("   "), "");
    }

    #[test]
    fn sub_id_commits_to_pubkey_so_two_users_cannot_be_linked_under_one_salt() {
        // PSI-2: even if a salt leaked, two users' sub-ids must differ because
        // the derivation hashes the pubkey. A regression dropping own_pubkey
        // from the digest would collide here.
        let salt = [5u8; 16];
        let a = derive_sub_id(&salt, &[1u8; 32], PlaneKind::Group, 0);
        let b = derive_sub_id(&salt, &[2u8; 32], PlaneKind::Group, 0);
        assert_ne!(
            a, b,
            "different pubkeys under one salt must yield different sub-ids"
        );
    }

    #[test]
    fn canonical_set_dedupes_normalized_duplicates() {
        let set = canonical_relay_set(&[
            "wss://A/".to_string(),
            "wss://a".to_string(),
            "wss://b".to_string(),
        ]);
        assert_eq!(set, vec!["wss://a".to_string(), "wss://b".to_string()]);
    }

    #[test]
    fn circles_sharing_a_relay_set_collapse_to_one_multiplexed_sub() {
        let salt = [7u8; 16];
        let pk = [9u8; 32];
        let circles = vec![
            circle("aa00", &["wss://r1", "wss://r2"]),
            circle("bb11", &["wss://R2/", "wss://r1"]), // same set, different order/case
            circle("cc22", &["wss://r3"]),              // distinct set
        ];
        let (groups, _inbox) = build_relay_set_subscriptions(&salt, &pk, &circles, &[]);

        // Two buckets: {r1,r2} (aa00+bb11 multiplexed) and {r3} (cc22).
        assert_eq!(groups.len(), 2);
        let multiplexed = groups
            .iter()
            .find(|g| g.relays == vec!["wss://r1".to_string(), "wss://r2".to_string()])
            .expect("shared-relay bucket present");
        assert_eq!(
            multiplexed.group_ids_hex,
            vec!["aa00".to_string(), "bb11".to_string()]
        );
    }

    #[test]
    fn sub_ids_differ_across_salts_but_are_stable_within_a_session() {
        let pk = [1u8; 32];
        let a = derive_sub_id(&[1u8; 16], &pk, PlaneKind::Group, 0);
        let a_again = derive_sub_id(&[1u8; 16], &pk, PlaneKind::Group, 0);
        let b = derive_sub_id(&[2u8; 16], &pk, PlaneKind::Group, 0);

        assert_eq!(a, a_again, "same salt+inputs → stable id within a session");
        assert_ne!(a, b, "different salt → different id across sessions");
    }

    #[test]
    fn sub_id_discriminates_plane_and_index_and_is_redactable() {
        let salt = [3u8; 16];
        let pk = [4u8; 32];
        let g0 = derive_sub_id(&salt, &pk, PlaneKind::Group, 0);
        let g1 = derive_sub_id(&salt, &pk, PlaneKind::Group, 1);
        let i0 = derive_sub_id(&salt, &pk, PlaneKind::Inbox, 0);

        assert_ne!(g0, g1);
        assert_ne!(g0, i0);
        // Plane suffix is disclosed by design; the hex prefix is >= 16 chars so
        // it auto-redacts in logs.
        assert!(g0.to_string().ends_with("_group_0"));
        assert!(i0.to_string().ends_with("_inbox_0"));
        let full = g0.to_string();
        let hex_part = full.split('_').next().unwrap();
        assert_eq!(hex_part.len(), SUB_ID_PREFIX_BYTES * 2);
        assert!(
            !crate::nostr::mls::redact_hex_sequences(&full).contains(hex_part),
            "16-hex sub-id prefix must be redactable"
        );
    }

    #[test]
    fn derive_dynamic_group_sub_id_stable_collision_free_redactable() {
        let salt = [3u8; 16];
        let pk = [4u8; 32];
        let a = derive_dynamic_group_sub_id(&salt, &pk, "aa00");
        let a_again = derive_dynamic_group_sub_id(&salt, &pk, "aa00");
        let b = derive_dynamic_group_sub_id(&salt, &pk, "bb11");
        // Stable per (salt, pk, hex); differs per hex.
        assert_eq!(a, a_again, "same salt+pk+hex → stable id within a session");
        assert_ne!(a, b, "different circle hex → different dynamic sub-id");

        // Never equals a base-bucket id for ANY idx (the "group_dyn" domain
        // separator + `_group_dyn` suffix rule out a NIP-01-clobbering collision).
        for idx in 0..16 {
            assert_ne!(
                a,
                derive_sub_id(&salt, &pk, PlaneKind::Group, idx),
                "a dynamic singleton must never collide with a base bucket (idx {idx})"
            );
        }

        // Redaction-safe: the 16-hex prefix sits at the redaction floor.
        let full = a.to_string();
        assert!(
            full.ends_with("_group_dyn"),
            "suffix discloses plane only: {full}"
        );
        let hex_part = full.split('_').next().unwrap();
        assert_eq!(hex_part.len(), SUB_ID_PREFIX_BYTES * 2);
        assert!(
            !crate::nostr::mls::redact_hex_sequences(&full).contains(hex_part),
            "the dynamic sub-id prefix must be redactable"
        );
    }

    #[test]
    fn inbox_relays_are_normalized_into_one_subscription() {
        let (_groups, inbox) = build_relay_set_subscriptions(
            &[0u8; 16],
            &[0u8; 32],
            &[],
            &["wss://Inbox/".to_string()],
        );
        assert_eq!(inbox.relays, vec!["wss://inbox".to_string()]);
    }

    #[test]
    fn circle_with_no_relays_is_skipped() {
        let circles = vec![circle("aa00", &[])];
        let (groups, _inbox) = build_relay_set_subscriptions(&[0u8; 16], &[0u8; 32], &circles, &[]);
        assert!(groups.is_empty());
    }
}
