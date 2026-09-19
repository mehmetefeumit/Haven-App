//! What each relay plane actually put on the wire, per direction.
//!
//! The ledger is the only Rule-13 evidence the rig has. The engine's own
//! re-issue bookkeeping is `#[cfg(test)] pub(crate)` inside haven-core and the
//! repair queue is invisible from here, so "did a relay acknowledge this?" and
//! "did the client re-issue that REQ?" are answerable only from the frames that
//! crossed the proxy.
//!
//! # Client-facing, and that word is the whole invariant
//!
//! [`Ledger::witnessed_ok`] records an `["OK", …, true, …]` **after it was
//! written towards the client**. Under a swallowed-`OK` fault the relay stores
//! the event and emits its acknowledgement, and the client never hears it — a
//! ledger that answered from the relay's side would let the rig confirm a
//! commit nobody acked, which is the confidentiality-relevant half of Rule 13,
//! not a bookkeeping detail.
//!
//! # Rule 15
//!
//! The ledger HOLDS event ids, subscription ids and relay-authored text,
//! because the oracles need to compare them; it RENDERS none of them. Its
//! `Debug` is bucketed counts, and the only renderable name for an event is the
//! [`EventTag`] it mints in observation order.

use std::collections::hash_map::Entry;
use std::collections::HashMap;
use std::fmt;
use std::sync::{Arc, Mutex, PoisonError};
use std::time::Duration;

use nostr::{EventId, SubscriptionId};

use crate::rig::{sim_magnitude, EventTag};

/// The frames one relay plane carried, per direction.
///
/// Cheap to clone: every clone reads and writes the same ledger, because the
/// proxy's connection tasks and the scenario reading them are different tasks.
#[derive(Clone, Default)]
pub struct Ledger {
    inner: Arc<Mutex<Inner>>,
}

#[derive(Default)]
struct Inner {
    /// Event ids whose `OK … true` was written towards the client.
    acked: Vec<EventId>,
    /// `EVENT` frames written towards the client, per event.
    delivered: HashMap<EventId, usize>,
    /// `EVENT` frames the client sent towards the relay, per event.
    published: HashMap<EventId, usize>,
    /// `REQ`s the client sent, per subscription. Counted where they ARRIVE,
    /// not where they are forwarded: a `CLOSED` fault answers a REQ without
    /// forwarding it, and the re-issue evidence is about what the client did.
    reqs: HashMap<SubscriptionId, usize>,
    /// `CLOSED` messages written towards the client, in order.
    closed: Vec<String>,
    /// `NOTICE` texts written towards the client, in order.
    notices: Vec<String>,
    /// `EOSE` frames written towards the client.
    eose: usize,
    /// The faults this plane really took, by label, in order. Heals are not
    /// among them: healing is what makes a fault a fault, and a floor that
    /// counted the recovery would be met by a plane nothing was ever done to.
    faults: Vec<&'static str>,
    /// Observation-order handles, so a scenario can name an event without
    /// rendering its id.
    tags: HashMap<EventId, EventTag>,
    next_tag: u64,
    /// How many attempts the last `Up` needed to take its port back, and how
    /// long it waited. The wait IS the measurement — an accept loop releases
    /// its listener when the task that owns it is dropped, so a rebind that
    /// takes several attempts is worth seeing rather than hiding behind a
    /// retry.
    rebind_attempts: u32,
    rebind_wait: Duration,
}

impl Ledger {
    /// A ledger with nothing in it.
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    fn with<T>(&self, f: impl FnOnce(&mut Inner) -> T) -> T {
        let mut inner = self.inner.lock().unwrap_or_else(PoisonError::into_inner);
        f(&mut inner)
    }

    /// Whether this plane's client-facing stream carried `["OK", id, true, …]`.
    #[must_use]
    pub fn witnessed_ok(&self, event_id: &EventId) -> bool {
        self.with(|inner| inner.acked.contains(event_id))
    }

    /// How many `EVENT` frames naming `event_id` were written towards the
    /// client. Two is a duplicate on the wire, whatever the client's own
    /// de-duplication then does with it.
    #[must_use]
    pub fn delivered(&self, event_id: &EventId) -> usize {
        self.with(|inner| inner.delivered.get(event_id).copied().unwrap_or_default())
    }

    /// How many `EVENT` frames naming `event_id` the client sent.
    #[must_use]
    pub fn published(&self, event_id: &EventId) -> usize {
        self.with(|inner| inner.published.get(event_id).copied().unwrap_or_default())
    }

    /// Every event the client published, by id.
    ///
    /// The ids, because the swallowed-ack proof is per event and its two halves
    /// are read by id: the relay's store on one side, this ledger's acks on the
    /// other. Held and returned, never rendered — the caller names one in a
    /// report through [`Self::tag_of`].
    #[must_use]
    pub fn published_ids(&self) -> Vec<EventId> {
        self.with(|inner| inner.published.keys().copied().collect())
    }

    /// How many `REQ`s the client sent for `subscription_id`.
    ///
    /// One per key is a subscription; more than one is a re-issue, which is the
    /// only evidence the rig has that a closed subscription was retried.
    #[must_use]
    pub fn reqs_for(&self, subscription_id: &SubscriptionId) -> usize {
        self.with(|inner| inner.reqs.get(subscription_id).copied().unwrap_or_default())
    }

    /// Every `REQ` the client sent, over every subscription.
    #[must_use]
    pub fn reqs(&self) -> usize {
        self.with(|inner| inner.reqs.values().sum())
    }

    /// The `CLOSED` messages the client was sent, in order.
    ///
    /// Returned verbatim because byte fidelity is the point: a scenario that
    /// asserts the engine reacts to `rate-limited:` proves nothing if the
    /// harness spells it differently from a relay.
    #[must_use]
    pub fn closed_messages(&self) -> Vec<String> {
        self.with(|inner| inner.closed.clone())
    }

    /// The `NOTICE` texts the client was sent, in order.
    #[must_use]
    pub fn notices(&self) -> Vec<String> {
        self.with(|inner| inner.notices.clone())
    }

    /// How many `EOSE` frames the client was sent.
    #[must_use]
    pub fn eose(&self) -> usize {
        self.with(|inner| inner.eose)
    }

    /// How many faults this plane really took.
    ///
    /// The expectation floor's observation half. An arm DECLARES how many
    /// faults it means to apply and the plane RECORDS how many it took, so the
    /// two halves of "the schedule actually fired" come from different places —
    /// an arm that miscounts its own faults can no longer satisfy the floor it
    /// wrote.
    #[must_use]
    pub fn faults_applied(&self) -> usize {
        self.with(|inner| inner.faults.len())
    }

    /// Those faults' labels, in order. Literals from this crate.
    #[must_use]
    pub fn faults(&self) -> Vec<&'static str> {
        self.with(|inner| inner.faults.clone())
    }

    /// This event's handle, minted in observation order the first time the
    /// ledger saw it in either direction.
    #[must_use]
    pub fn tag_of(&self, event_id: &EventId) -> Option<EventTag> {
        self.with(|inner| inner.tags.get(event_id).copied())
    }

    /// How many bind attempts the last `Up` needed, and how long it waited.
    /// `(0, ZERO)` until a plane has come back up.
    #[must_use]
    pub fn rebind(&self) -> (u32, Duration) {
        self.with(|inner| (inner.rebind_attempts, inner.rebind_wait))
    }

    pub(crate) fn note_ok(&self, event_id: EventId, status: bool) {
        self.with(|inner| {
            inner.tag(event_id);
            if status {
                inner.acked.push(event_id);
            }
        });
    }

    pub(crate) fn note_delivered(&self, event_id: EventId) {
        self.with(|inner| {
            inner.tag(event_id);
            *inner.delivered.entry(event_id).or_default() += 1;
        });
    }

    pub(crate) fn note_published(&self, event_id: EventId) {
        self.with(|inner| {
            inner.tag(event_id);
            *inner.published.entry(event_id).or_default() += 1;
        });
    }

    pub(crate) fn note_req(&self, subscription_id: SubscriptionId) {
        self.with(|inner| *inner.reqs.entry(subscription_id).or_default() += 1);
    }

    pub(crate) fn note_closed(&self, message: String) {
        self.with(|inner| inner.closed.push(message));
    }

    pub(crate) fn note_notice(&self, text: String) {
        self.with(|inner| inner.notices.push(text));
    }

    pub(crate) fn note_eose(&self) {
        self.with(|inner| inner.eose += 1);
    }

    /// Records a fault this plane really took. Called only once the plane has
    /// reached the state the fault names: a fault that could not be applied did
    /// not fire, and a floor met by one would be a fiction.
    pub(crate) fn note_fault(&self, label: &'static str) {
        self.with(|inner| inner.faults.push(label));
    }

    pub(crate) fn note_rebind(&self, attempts: u32, waited: Duration) {
        self.with(|inner| {
            inner.rebind_attempts = attempts;
            inner.rebind_wait = waited;
        });
    }
}

impl Inner {
    // Minted once and never moved: a handle that changed between two sightings
    // of the same event would make the determinism table meaningless.
    fn tag(&mut self, event_id: EventId) {
        if let Entry::Vacant(slot) = self.tags.entry(event_id) {
            slot.insert(EventTag::new(self.next_tag));
            self.next_tag += 1;
        }
    }
}

// Bucketed counts and nothing else: this type holds every event id, every
// subscription id and every relay-authored string the plane carried, and it
// shares an evidence file with the subject's own lines.
impl fmt::Debug for Ledger {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        self.with(|inner| {
            f.debug_struct("Ledger")
                .field("acked", &sim_magnitude(inner.acked.len()))
                .field("delivered", &sim_magnitude(inner.delivered.len()))
                .field("published", &sim_magnitude(inner.published.len()))
                .field("reqs", &sim_magnitude(inner.reqs.len()))
                .field("closed", &sim_magnitude(inner.closed.len()))
                .field("notices", &sim_magnitude(inner.notices.len()))
                .field("eose", &sim_magnitude(inner.eose))
                .field("faults", &sim_magnitude(inner.faults.len()))
                .finish_non_exhaustive()
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn an_event_id(byte: u8) -> EventId {
        EventId::from_slice(&[byte; 32]).expect("32 bytes is an event id")
    }

    #[test]
    fn an_ok_is_witnessed_only_when_it_carried_a_true_status() {
        let ledger = Ledger::new();
        ledger.note_ok(an_event_id(1), true);
        ledger.note_ok(an_event_id(2), false);
        assert!(ledger.witnessed_ok(&an_event_id(1)));
        assert!(
            !ledger.witnessed_ok(&an_event_id(2)),
            "a rejection is not an acknowledgement"
        );
        assert!(!ledger.witnessed_ok(&an_event_id(3)));
    }

    #[test]
    fn delivery_and_publication_are_counted_per_direction() {
        let ledger = Ledger::new();
        ledger.note_published(an_event_id(1));
        ledger.note_delivered(an_event_id(1));
        ledger.note_delivered(an_event_id(1));
        assert_eq!(ledger.published(&an_event_id(1)), 1);
        assert_eq!(ledger.delivered(&an_event_id(1)), 2);
        assert_eq!(ledger.delivered(&an_event_id(9)), 0);
        assert_eq!(
            ledger.published_ids(),
            vec![an_event_id(1)],
            "a delivery is not a publication, and the swallowed-ack proof reads the publications"
        );
    }

    #[test]
    fn reqs_are_counted_per_subscription_and_in_total() {
        let ledger = Ledger::new();
        let one = SubscriptionId::new("one");
        let other = SubscriptionId::new("other");
        ledger.note_req(one.clone());
        ledger.note_req(one.clone());
        ledger.note_req(other.clone());
        assert_eq!(ledger.reqs_for(&one), 2);
        assert_eq!(ledger.reqs_for(&other), 1);
        assert_eq!(ledger.reqs(), 3);
    }

    #[test]
    fn a_handle_is_minted_once_per_event_in_observation_order() {
        let ledger = Ledger::new();
        ledger.note_published(an_event_id(7));
        ledger.note_delivered(an_event_id(8));
        ledger.note_delivered(an_event_id(7));
        assert_eq!(ledger.tag_of(&an_event_id(7)), Some(EventTag::new(0)));
        assert_eq!(ledger.tag_of(&an_event_id(8)), Some(EventTag::new(1)));
        assert_eq!(ledger.tag_of(&an_event_id(9)), None);
    }

    #[test]
    fn messages_and_notices_are_kept_verbatim_and_in_order() {
        let ledger = Ledger::new();
        ledger.note_closed("rate-limited: too many REQs".to_string());
        ledger.note_closed("auth-required: you must auth".to_string());
        ledger.note_notice("held for the harness".to_string());
        ledger.note_eose();
        assert_eq!(
            ledger.closed_messages(),
            vec![
                "rate-limited: too many REQs".to_string(),
                "auth-required: you must auth".to_string()
            ]
        );
        assert_eq!(ledger.notices(), vec!["held for the harness".to_string()]);
        assert_eq!(ledger.eose(), 1);
    }

    #[test]
    fn faults_are_counted_as_they_are_taken_and_named_by_their_labels() {
        let ledger = Ledger::new();
        assert_eq!(ledger.faults_applied(), 0);
        ledger.note_fault("down");
        ledger.note_fault("swallow-ok");
        assert_eq!(ledger.faults_applied(), 2);
        assert_eq!(
            ledger.faults(),
            vec!["down", "swallow-ok"],
            "the observation half of an expectation floor is what this plane really took"
        );
    }

    #[test]
    fn a_rebind_records_what_it_cost() {
        let ledger = Ledger::new();
        assert_eq!(ledger.rebind(), (0, Duration::ZERO));
        ledger.note_rebind(3, Duration::from_millis(40));
        assert_eq!(ledger.rebind(), (3, Duration::from_millis(40)));
    }

    #[test]
    fn clones_share_one_ledger() {
        let ledger = Ledger::new();
        let other = ledger.clone();
        other.note_ok(an_event_id(4), true);
        assert!(ledger.witnessed_ok(&an_event_id(4)));
    }

    #[test]
    fn rendering_a_ledger_buckets_its_counts_and_names_nothing_it_carried() {
        let ledger = Ledger::new();
        ledger.note_ok(an_event_id(1), true);
        ledger.note_delivered(an_event_id(1));
        ledger.note_published(an_event_id(1));
        ledger.note_req(SubscriptionId::new("needle-subscription"));
        ledger.note_closed("rate-limited: needle-text".to_string());
        ledger.note_notice("npub1needleneedle".to_string());

        let rendered = format!("{ledger:?}");
        assert!(rendered.contains("Ledger"), "{rendered}");
        assert!(rendered.contains("acked"), "{rendered}");
        let event_hex = hex::encode([1u8; 32]);
        for needle in [
            "needle",
            "npub1",
            "rate-limited",
            event_hex.as_str(),
            "0101",
        ] {
            assert!(
                !rendered.contains(needle),
                "a ledger rendering must carry no value it holds"
            );
        }
    }
}
