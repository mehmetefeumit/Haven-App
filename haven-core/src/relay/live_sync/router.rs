//! Routes incoming relay events to their subscription context.
//!
//! Keyed by `(relay_url, subscription_id)`, the router records what each live
//! REQ is for: which plane, and (for the group plane) exactly which
//! `hex(nostr_group_id)` values that REQ multiplexes. An incoming group event
//! whose `#h` is not in the matching context is dropped without decryption — a
//! defense against a relay echoing an event for a circle we did not ask about.
//!
//! Registration happens *before* the REQ is issued; if the subscribe call
//! fails, [`Router::rollback_subscription`] removes the context so no stale
//! entry leaks.

use std::collections::{HashMap, HashSet};

use nostr::SubscriptionId;

use super::planes::PlaneKind;

/// What a single live subscription is for.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SubCtx {
    /// The plane this REQ serves.
    pub plane: PlaneKind,
    /// For [`PlaneKind::Group`]: the `hex(nostr_group_id)` values multiplexed
    /// into this REQ. Empty for the inbox plane.
    pub group_ids_hex: HashSet<String>,
}

/// Maps `(relay_url, subscription_id)` to its [`SubCtx`].
#[derive(Debug, Default)]
pub struct Router {
    subs: HashMap<(String, SubscriptionId), SubCtx>,
    /// How many REQ registrations this router has recorded, ever.
    ///
    /// The pause's drain marker travels through the ingest queue and can be
    /// ABANDONED (its ack is bounded, the lifecycle lock is not held until it
    /// is processed), so the worker may reach a marker after a LATER burst has
    /// already registered its own REQs. The count is what tells those two
    /// apart; see [`Self::clear_if_unchanged`].
    registrations: u64,
}

impl Router {
    /// Creates an empty router.
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Registers `ctx` for `(relay_url, sub_id)`, replacing any prior entry.
    pub fn register(&mut self, relay_url: &str, sub_id: &SubscriptionId, ctx: SubCtx) {
        self.registrations = self.registrations.wrapping_add(1);
        self.subs
            .insert((relay_url.to_string(), sub_id.clone()), ctx);
    }

    /// Registers the same group context across every relay in `relays` (one
    /// multiplexed REQ replicated to each relay in the bucket).
    pub fn register_group(
        &mut self,
        relays: &[String],
        sub_id: &SubscriptionId,
        group_ids_hex: &HashSet<String>,
    ) {
        for relay in relays {
            self.register(
                relay,
                sub_id,
                SubCtx {
                    plane: PlaneKind::Group,
                    group_ids_hex: group_ids_hex.clone(),
                },
            );
        }
    }

    /// Looks up the context for an incoming event.
    #[must_use]
    pub fn lookup(&self, relay_url: &str, sub_id: &SubscriptionId) -> Option<&SubCtx> {
        self.subs.get(&(relay_url.to_string(), sub_id.clone()))
    }

    /// Whether an incoming group event on `(relay_url, sub_id)` carrying `#h ==
    /// group_id_hex` was actually requested. `false` for an unknown sub, an
    /// inbox sub, or an `#h` we did not multiplex — all of which must be dropped
    /// without decryption.
    #[must_use]
    pub fn is_group_event_wanted(
        &self,
        relay_url: &str,
        sub_id: &SubscriptionId,
        group_id_hex: &str,
    ) -> bool {
        self.lookup(relay_url, sub_id).is_some_and(|ctx| {
            ctx.plane == PlaneKind::Group && ctx.group_ids_hex.contains(group_id_hex)
        })
    }

    /// Removes one `(relay_url, sub_id)` entry, returning the prior context.
    pub fn remove(&mut self, relay_url: &str, sub_id: &SubscriptionId) -> Option<SubCtx> {
        self.subs.remove(&(relay_url.to_string(), sub_id.clone()))
    }

    /// Removes a subscription id across every relay (rollback on a failed
    /// subscribe, or teardown of a multiplexed REQ). Returns how many entries
    /// were removed.
    pub fn rollback_subscription(&mut self, sub_id: &SubscriptionId) -> usize {
        let before = self.subs.len();
        self.subs.retain(|(_, id), _| id != sub_id);
        before - self.subs.len()
    }

    /// Removes every registered subscription (session teardown).
    pub fn clear(&mut self) {
        self.subs.clear();
    }

    /// How many REQ registrations this router has recorded.
    ///
    /// Read by [`super::session::LiveSyncCore::pause_subscriptions`] under the
    /// lifecycle lock, carried on its drain marker, and compared here.
    #[must_use]
    pub const fn registrations(&self) -> u64 {
        self.registrations
    }

    /// Clears every entry IF nothing has been registered since `seen`, and
    /// reports whether it did.
    ///
    /// The pause's drain marker rides the ingest queue behind that burst's
    /// backlog, and the pause's wait for its ack is BOUNDED — a worker still
    /// draining after [`super::config::RELAY_LIFECYCLE_OP_TIMEOUT_SECS`] leaves
    /// the marker queued while the pause clears the router itself and returns,
    /// releasing the lifecycle lock. The next burst then opens and registers its
    /// own REQs; if the abandoned marker cleared the router at THAT point, the
    /// burst would route nothing at all — every event and every `EOSE` would
    /// find no context — while believing it was subscribed. The lifecycle lock
    /// cannot prevent this: it orders the two CALLS, and the marker outlives the
    /// one that sent it.
    ///
    /// So the authority to clear is scoped to the registration state the pause
    /// observed. A marker that names an older count is stale by construction and
    /// clears nothing.
    pub fn clear_if_unchanged(&mut self, seen: u64) -> bool {
        if self.registrations != seen {
            return false;
        }
        self.subs.clear();
        true
    }

    /// Number of registered `(relay, sub)` entries.
    #[must_use]
    pub fn len(&self) -> usize {
        self.subs.len()
    }

    /// Whether the router has no registered subscriptions.
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.subs.is_empty()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sub(id: &str) -> SubscriptionId {
        SubscriptionId::new(id)
    }

    fn group_ids(ids: &[&str]) -> HashSet<String> {
        ids.iter().map(|s| (*s).to_string()).collect()
    }

    #[test]
    fn registers_and_looks_up_group_context() {
        let mut r = Router::new();
        let id = sub("abc_group_0");
        r.register_group(
            &["wss://r1".to_string(), "wss://r2".to_string()],
            &id,
            &group_ids(&["aa00", "bb11"]),
        );
        assert_eq!(r.len(), 2); // one per relay

        let ctx = r.lookup("wss://r1", &id).unwrap();
        assert_eq!(ctx.plane, PlaneKind::Group);
        assert!(ctx.group_ids_hex.contains("aa00"));
    }

    #[test]
    fn drops_group_event_for_unmultiplexed_h_tag() {
        let mut r = Router::new();
        let id = sub("abc_group_0");
        r.register_group(&["wss://r1".to_string()], &id, &group_ids(&["aa00"]));

        assert!(r.is_group_event_wanted("wss://r1", &id, "aa00"));
        // An `#h` we never asked for → dropped.
        assert!(!r.is_group_event_wanted("wss://r1", &id, "ff99"));
        // Unknown relay/sub → dropped.
        assert!(!r.is_group_event_wanted("wss://other", &id, "aa00"));
        assert!(!r.is_group_event_wanted("wss://r1", &sub("nope"), "aa00"));
    }

    #[test]
    fn inbox_sub_is_never_a_wanted_group_event() {
        let mut r = Router::new();
        let id = sub("abc_inbox_0");
        r.register(
            "wss://r1",
            &id,
            SubCtx {
                plane: PlaneKind::Inbox,
                group_ids_hex: HashSet::new(),
            },
        );
        assert!(!r.is_group_event_wanted("wss://r1", &id, "aa00"));
    }

    #[test]
    fn rollback_removes_sub_across_all_relays_no_leak() {
        let mut r = Router::new();
        let id = sub("abc_group_0");
        r.register_group(
            &["wss://r1".to_string(), "wss://r2".to_string()],
            &id,
            &group_ids(&["aa00"]),
        );
        assert_eq!(r.rollback_subscription(&id), 2);
        assert!(r.is_empty(), "no context may leak after rollback");
    }

    #[test]
    fn a_clear_is_authorised_only_for_the_registration_state_it_named() {
        let mut r = Router::new();
        let id = sub("abc_group_0");
        r.register_group(&["wss://r1".to_string()], &id, &group_ids(&["aa00"]));
        let seen = r.registrations();

        // A later burst registers its own REQ: the marker the earlier pause
        // abandoned must clear nothing, or that burst routes no event at all.
        r.register_group(
            &["wss://r1".to_string()],
            &sub("abc_group_1"),
            &group_ids(&["bb11"]),
        );
        assert!(
            !r.clear_if_unchanged(seen),
            "a marker naming an older registration count must not clear a later \
             burst's router"
        );
        assert_eq!(r.len(), 2, "and it must leave every entry in place");

        // The same marker against the state it WAS authorised for still clears,
        // so this is a generation check and not a blanket refusal.
        let now = r.registrations();
        assert!(r.clear_if_unchanged(now));
        assert!(r.is_empty());
    }

    #[test]
    fn remove_returns_prior_context() {
        let mut r = Router::new();
        let id = sub("abc_group_0");
        r.register_group(&["wss://r1".to_string()], &id, &group_ids(&["aa00"]));
        let removed = r.remove("wss://r1", &id).unwrap();
        assert_eq!(removed.plane, PlaneKind::Group);
        assert!(r.is_empty());
    }
}
