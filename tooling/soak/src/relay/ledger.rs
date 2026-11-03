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
//!
//! # The plane record
//!
//! Beside the per-direction counts, every client→relay data frame is kept for
//! oracle O7 (`oracle/planes.rs`), recorded at the proxy's one choke point
//! BEFORE anything parses it, under the endpoint and the connection it came
//! on. A frame is kept as the projection the relay-plane judge reads: an
//! event without its content and signature, a filter with its `since` and
//! `until` zeroed, a `NEG-MSG` without its message. The key is (endpoint,
//! connection, projected text), and the text keeps the subscription id — G6
//! needs it to match a `CLOSE` — so a REQ re-issued on its connection is one
//! entry, but every reconnect is a new connection and every
//! `RelayManager::fetch_events` call a new subscription id: shapes grow with
//! faults and fetches, i.e. with a world's length. What bounds them is
//! [`PLANE_SHAPES_CAP`] and [`PLANE_IDS_CAP`], past which the record is FULL
//! and O7 answers that the rig could not hold its evidence (rc 2), never a
//! silent drop.

use std::collections::hash_map::Entry;
use std::collections::{BTreeMap, HashMap};
use std::fmt;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, PoisonError};
use std::time::Duration;

use nostr::filter::MatchEventOptions;
use nostr::{Event, EventId, Filter, SubscriptionId};
use serde_json::Value;

use crate::rig::{sim_magnitude, DeviceTag, EventTag};

/// The most distinct non-EVENT frame shapes one plane's record holds.
///
/// Shapes grow with reconnects and fetches (module docs). Measured single
/// arms peak at 66 shapes a plane; the long nemesis worlds are measured by the
/// nightly run, and the cap is re-pinned only from a measured high-water mark,
/// never lowered by hand.
pub const PLANE_SHAPES_CAP: usize = 4096;

/// The most distinct event ids one plane's record holds: the events clients
/// sent it, the ones seeded into its store and the ones it forged. A 900-s
/// nightly world sends a plane O(10³).
pub const PLANE_IDS_CAP: usize = 65_536;

/// One global order over every recorded frame of every plane: the instant O7
/// judges a frame at, comparable with the instant the rig staged a routing.
static PLANE_INSTANT: AtomicU64 = AtomicU64::new(0);

/// Connections are numbered across every plane, so two planes' connections
/// never share the number a `CLOSE` is matched on.
static NEXT_CONNECTION: AtomicU64 = AtomicU64::new(0);

/// The next instant of the plane record's order.
#[must_use]
pub fn plane_instant() -> u64 {
    PLANE_INSTANT.fetch_add(1, Ordering::AcqRel)
}

/// A number no other connection of this process carries.
#[must_use]
pub fn next_connection() -> u64 {
    NEXT_CONNECTION.fetch_add(1, Ordering::Relaxed)
}

/// Which endpoint of a plane a frame crossed: the canonical one, a device's
/// own, or one of a device's alias endpoints (by slot).
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum EndpointId {
    /// What storage names: catch-up sweeps and the rig's inbox reads dial it.
    Canonical,
    /// A device's own endpoint.
    Own(DeviceTag),
    /// A device's alias endpoint, by slot (`rig/address_map.rs`).
    Alias(DeviceTag, u16),
}

impl EndpointId {
    /// The device whose endpoint this is; `None` for the canonical one.
    #[must_use]
    pub const fn device(self) -> Option<DeviceTag> {
        match self {
            Self::Canonical => None,
            Self::Own(device) | Self::Alias(device, _) => Some(device),
        }
    }
}

/// One recorded frame. No `Debug`: the text holds pubkeys, routing ids and
/// event ids.
pub struct PlaneFrame {
    /// The endpoint it crossed.
    pub endpoint: EndpointId,
    /// The connection it came on.
    pub conn: u64,
    /// When it first arrived, in [`plane_instant`]'s order.
    pub at: u64,
    /// Its judged projection, as JSON text.
    pub text: String,
}

/// Everything one plane recorded, ordered by arrival. No `Debug`, for
/// [`PlaneFrame`]'s reason.
pub struct PlaneRecord {
    /// Every distinct frame, first arrival first.
    pub frames: Vec<PlaneFrame>,
    /// Every event this plane carried, was seeded with or forged: its id,
    /// kind and `#h`, for the judge's event index.
    pub events: Vec<(String, u16, Option<String>)>,
    /// Whether a cap was hit, so the record is incomplete.
    pub full: bool,
}

/// How full one plane's record ran: distinct shapes and distinct event ids.
/// Compared against the caps in process; rendered only bucketed.
#[derive(Clone, Copy, PartialEq, Eq)]
pub struct PlaneHighWater {
    /// Distinct non-EVENT shapes.
    pub shapes: usize,
    /// Distinct event ids.
    pub ids: usize,
}

impl fmt::Debug for PlaneHighWater {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("PlaneHighWater")
            .field("shapes", &sim_magnitude(self.shapes))
            .field("ids", &sim_magnitude(self.ids))
            .finish()
    }
}

struct PlaneLog {
    first_seen: HashMap<(EndpointId, u64, String), u64>,
    events: BTreeMap<String, (u16, Option<String>)>,
    shapes: usize,
    shapes_cap: usize,
    ids_cap: usize,
    full: bool,
}

impl Default for PlaneLog {
    fn default() -> Self {
        Self {
            first_seen: HashMap::new(),
            events: BTreeMap::new(),
            shapes: 0,
            shapes_cap: PLANE_SHAPES_CAP,
            ids_cap: PLANE_IDS_CAP,
            full: false,
        }
    }
}

impl PlaneLog {
    fn index(&mut self, id: String, kind: u16, h: Option<String>) {
        if self.events.contains_key(&id) {
            return;
        }
        if self.events.len() >= self.ids_cap {
            self.full = true;
            return;
        }
        self.events.insert(id, (kind, h));
    }

    fn note(
        &mut self,
        endpoint: EndpointId,
        conn: u64,
        text: String,
        event: Option<(String, u16, Option<String>)>,
    ) {
        if self.full {
            return;
        }
        let key = (endpoint, conn, text);
        if self.first_seen.contains_key(&key) {
            return;
        }
        match event {
            Some((id, kind, h)) => {
                self.index(id, kind, h);
                if self.full {
                    return;
                }
            }
            None if self.shapes >= self.shapes_cap => {
                self.full = true;
                return;
            }
            None => self.shapes += 1,
        }
        self.first_seen.insert(key, plane_instant());
    }
}

/// The judged projection of a client frame, and the event it carries if it
/// is an `EVENT`. Total: a frame that is not a JSON array is kept verbatim
/// (an empty text for a binary one), and the judge calls it unknown.
fn project(payload: Option<&str>) -> (String, Option<(String, u16, Option<String>)>) {
    let Some(text) = payload else {
        return (String::new(), None);
    };
    let Ok(Value::Array(mut frame)) = serde_json::from_str::<Value>(text) else {
        return (text.to_owned(), None);
    };
    let mut event = None;
    match frame.first().and_then(Value::as_str) {
        Some("EVENT") => {
            if let Some(Value::Object(object)) = frame.get_mut(1) {
                object.remove("content");
                object.remove("sig");
                event = indexed(object);
            }
        }
        Some("REQ" | "NEG-OPEN") => {
            for filter in frame.iter_mut().skip(2) {
                if let Value::Object(filter) = filter {
                    for key in ["since", "until"] {
                        if let Some(value) = filter.get_mut(key) {
                            *value = Value::from(0_u64);
                        }
                    }
                }
            }
        }
        Some("NEG-MSG") => {
            if let Some(message) = frame.get_mut(2) {
                *message = Value::String(String::new());
            }
        }
        _ => {}
    }
    (Value::Array(frame).to_string(), event)
}

/// The id, kind and first `h` of an event object, when it has the first two.
fn indexed(object: &serde_json::Map<String, Value>) -> Option<(String, u16, Option<String>)> {
    let id = object.get("id")?.as_str()?.to_owned();
    let kind = u16::try_from(object.get("kind")?.as_u64()?).ok()?;
    let h = object
        .get("tags")
        .and_then(Value::as_array)
        .and_then(|tags| {
            tags.iter()
                .find_map(|tag| match tag.as_array().map(Vec::as_slice) {
                    Some([name, value, ..]) if name == "h" => value.as_str().map(str::to_owned),
                    _ => None,
                })
        });
    Some((id, kind, h))
}

/// The id, kind and first `h` of `event`.
fn index_of(event: &Event) -> (String, u16, Option<String>) {
    let h = event.tags.iter().find_map(|tag| {
        let parts = tag.as_slice();
        (parts.first().map(String::as_str) == Some("h"))
            .then(|| parts.get(1).cloned())
            .flatten()
    });
    (event.id.to_hex(), event.kind.as_u16(), h)
}

/// One NIP-77 frame, by the side that sent it and its verb.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum NegFrame {
    /// A client's `NEG-OPEN` the plane passed on to the relay.
    Open,
    /// A client's `NEG-MSG`.
    ClientMessage,
    /// A client's `NEG-CLOSE`: a session it finished.
    Close,
    /// The relay's `NEG-MSG`, written towards the client.
    RelayMessage,
    /// The relay's `NEG-ERR`, written towards the client.
    Error,
    /// A client's `NEG-OPEN` the plane answered itself, as a relay that does
    /// not speak NIP-77 (`Fault::RefusesNegentropy`), and never passed on.
    Refused,
}

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
    /// The message of every `OK … false` written towards the client, per
    /// event. Verbatim, because a refusal's machine-readable prefix is what a
    /// client branches on and a forged refusal is only worth what its shape is.
    refusals: HashMap<EventId, String>,
    /// `EVENT` frames written towards the client, per event and per ENDPOINT:
    /// `None` is the plane's canonical endpoint, `Some` a device's own. The
    /// endpoint is the device dimension a partition arm reads — "dev#0's
    /// socket never carried it" is a different fact from "the plane never
    /// wrote it".
    delivered: HashMap<EventId, HashMap<Option<DeviceTag>, usize>>,
    /// `EVENT` frames the client sent towards the relay, per event.
    published: HashMap<EventId, usize>,
    /// Events this plane forged onto a subscription, in injection order.
    injected: Vec<EventId>,
    /// `REQ`s the client sent, per subscription. Counted where they ARRIVE,
    /// not where they are forwarded: a `CLOSED` fault answers a REQ without
    /// forwarding it, and the re-issue evidence is about what the client did.
    reqs: HashMap<SubscriptionId, usize>,
    /// The filters each open subscription asked for, latest `REQ` wins — which
    /// is a relay's own rule for a re-issued subscription id. Held so an
    /// injection can be delivered the way a relay delivers: onto every
    /// subscription whose filter matches it.
    filters: HashMap<SubscriptionId, Vec<Filter>>,
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
    /// How many listens the last `Up` made on the port its endpoint held while
    /// down — one, as nothing else can bind that port — and how long it took.
    rebind_attempts: u32,
    rebind_wait: Duration,
    /// Connections an endpoint dropped before their handshake under
    /// `ColdFirstConnect`: armed is not fired, and this is the firing.
    refused_connects: usize,
    /// Connections an endpoint held unanswered under `Unanswering`.
    unanswered_connects: usize,
    /// `EOSE` frames kept from the client under `WithholdEose`.
    withheld_eose: usize,
    /// NIP-77 frames, per endpoint and kind.
    neg: HashMap<(Option<DeviceTag>, NegFrame), usize>,
    /// Every client→relay data frame, for O7.
    planes: PlaneLog,
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

    /// The message of the `OK … false` this plane wrote for `event_id`, if it
    /// wrote one.
    ///
    /// The other shape of "not acked", and NOT the same evidence as a
    /// swallowed acknowledgement: under a swallowed `OK` the relay stored the
    /// event and the client heard nothing at all, so there is no refusal here;
    /// under a refusal the client heard `OK false` and the store holds nothing.
    /// Both answer [`Self::witnessed_ok`] with `false` — Rule 13's disposition
    /// is the same — and an arm that needs to tell them apart reads this and
    /// the store.
    #[must_use]
    pub fn refusal(&self, event_id: &EventId) -> Option<String> {
        self.with(|inner| inner.refusals.get(event_id).cloned())
    }

    /// Every open subscription whose filter `event` matches.
    ///
    /// A relay's own delivery rule (NIP-01): an event goes to every
    /// subscription that asked for it. Empty means nobody asked, which is what
    /// makes an injection onto nothing a fault that did not fire.
    #[must_use]
    pub fn subscriptions_matching(&self, event: &Event) -> Vec<SubscriptionId> {
        self.with(|inner| {
            let mut matching: Vec<SubscriptionId> = inner
                .filters
                .iter()
                .filter(|(_, filters)| {
                    filters
                        .iter()
                        .any(|filter| filter.match_event(event, MatchEventOptions::new()))
                })
                .map(|(subscription_id, _)| subscription_id.clone())
                .collect();
            // A map has no order and an injection's frames are written in the
            // order they come back, so they are sorted: two runs of one seed
            // must put the same bytes on the wire in the same order.
            matching.sort_by(|a, b| a.as_str().cmp(b.as_str()));
            matching
        })
    }

    /// How many `EVENT` frames naming `event_id` were written towards the
    /// client, over every endpoint of this plane. Two is a duplicate on the
    /// wire, whatever the client's own de-duplication then does with it.
    #[must_use]
    pub fn delivered(&self, event_id: &EventId) -> usize {
        self.with(|inner| {
            inner
                .delivered
                .get(event_id)
                .map_or(0, |endpoints| endpoints.values().sum())
        })
    }

    /// Whether an `EVENT` frame naming `event_id` was written towards
    /// `device`'s OWN endpoint.
    ///
    /// The partition evidence: a device whose endpoint is dropping a class
    /// must never have been sent a frame of that class, and a device whose
    /// endpoint was healed must have been. A device with no endpoint of its
    /// own on this plane was sent nothing through one.
    #[must_use]
    pub fn delivered_to(&self, device: DeviceTag, event_id: &EventId) -> bool {
        self.with(|inner| {
            inner
                .delivered
                .get(event_id)
                .is_some_and(|endpoints| endpoints.contains_key(&Some(device)))
        })
    }

    /// How many `EVENT` frames naming `event_id` the client sent.
    #[must_use]
    pub fn published(&self, event_id: &EventId) -> usize {
        self.with(|inner| inner.published.get(event_id).copied().unwrap_or_default())
    }

    /// Every event this plane INJECTED, in injection order.
    ///
    /// The adversary's side of the wire: an injected event is one no member
    /// published and no store holds, so a scenario that wants to classify what
    /// its victim made of it has nowhere else to learn its id. Held and
    /// returned, never rendered.
    #[must_use]
    pub fn injected_ids(&self) -> Vec<EventId> {
        self.with(|inner| inner.injected.clone())
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

    /// How many listens the last `Up` made, and how long it took.
    /// `(0, ZERO)` until a plane has come back up.
    #[must_use]
    pub fn rebind(&self) -> (u32, Duration) {
        self.with(|inner| (inner.rebind_attempts, inner.rebind_wait))
    }

    /// How many connections were dropped before their handshake.
    #[must_use]
    pub fn refused_connects(&self) -> usize {
        self.with(|inner| inner.refused_connects)
    }

    /// How many connections were accepted and never answered.
    #[must_use]
    pub fn unanswered_connects(&self) -> usize {
        self.with(|inner| inner.unanswered_connects)
    }

    /// How many `EOSE` frames were kept from the client.
    #[must_use]
    pub fn withheld_eose(&self) -> usize {
        self.with(|inner| inner.withheld_eose)
    }

    /// How many NIP-77 frames of `frame` crossed `device`'s endpoint (`None`:
    /// the plane's canonical one).
    #[must_use]
    pub fn neg(&self, device: Option<DeviceTag>, frame: NegFrame) -> usize {
        self.with(|inner| inner.neg.get(&(device, frame)).copied().unwrap_or(0))
    }

    /// How many NIP-77 frames of `frame` crossed any endpoint of the plane.
    #[must_use]
    pub fn neg_total(&self, frame: NegFrame) -> usize {
        self.with(|inner| {
            inner
                .neg
                .iter()
                .filter(|((_, seen), _)| *seen == frame)
                .map(|(_, count)| count)
                .sum()
        })
    }

    pub(crate) fn note_neg(&self, device: Option<DeviceTag>, frame: NegFrame) {
        self.with(|inner| *inner.neg.entry((device, frame)).or_default() += 1);
    }

    pub(crate) fn note_ok(&self, event_id: EventId, status: bool, message: &str) {
        self.with(|inner| {
            inner.tag(event_id);
            if status {
                inner.acked.push(event_id);
            } else {
                inner.refusals.insert(event_id, message.to_owned());
            }
        });
    }

    pub(crate) fn note_delivered(&self, device: Option<DeviceTag>, event_id: EventId) {
        self.with(|inner| {
            inner.tag(event_id);
            *inner
                .delivered
                .entry(event_id)
                .or_default()
                .entry(device)
                .or_default() += 1;
        });
    }

    pub(crate) fn note_injected(&self, event: &Event) {
        self.with(|inner| {
            inner.tag(event.id);
            inner.injected.push(event.id);
            let (id, kind, h) = index_of(event);
            inner.planes.index(id, kind, h);
        });
    }

    /// Indexes an event written straight into the plane's store: a by-id
    /// fetch of it is judged by the circle it carries, as a published one is.
    pub(crate) fn note_seeded(&self, event: &Event) {
        self.with(|inner| {
            let (id, kind, h) = index_of(event);
            inner.planes.index(id, kind, h);
        });
    }

    /// Records one client→relay data frame as it arrived on `endpoint`'s
    /// connection `conn`, before anything parses it: `payload` is its text,
    /// `None` for a binary frame.
    pub(crate) fn note_plane_frame(&self, endpoint: EndpointId, conn: u64, payload: Option<&str>) {
        let (text, event) = project(payload);
        self.with(|inner| inner.planes.note(endpoint, conn, text, event));
    }

    /// Everything the plane record holds, first arrival first.
    #[must_use]
    pub fn plane_record(&self) -> PlaneRecord {
        self.with(|inner| {
            let mut frames: Vec<PlaneFrame> = inner
                .planes
                .first_seen
                .iter()
                .map(|((endpoint, conn, text), at)| PlaneFrame {
                    endpoint: *endpoint,
                    conn: *conn,
                    at: *at,
                    text: text.clone(),
                })
                .collect();
            frames.sort_by_key(|frame| frame.at);
            PlaneRecord {
                frames,
                events: inner
                    .planes
                    .events
                    .iter()
                    .map(|(id, (kind, h))| (id.clone(), *kind, h.clone()))
                    .collect(),
                full: inner.planes.full,
            }
        })
    }

    /// How full the plane record ran.
    #[must_use]
    pub fn plane_high_water(&self) -> PlaneHighWater {
        self.with(|inner| PlaneHighWater {
            shapes: inner.planes.shapes,
            ids: inner.planes.events.len(),
        })
    }

    /// Lowers the plane record's caps: how a test makes a record full without
    /// filling it.
    pub fn set_plane_caps(&self, shapes: usize, ids: usize) {
        self.with(|inner| {
            inner.planes.shapes_cap = shapes;
            inner.planes.ids_cap = ids;
        });
    }

    pub(crate) fn note_published(&self, event_id: EventId) {
        self.with(|inner| {
            inner.tag(event_id);
            *inner.published.entry(event_id).or_default() += 1;
        });
    }

    pub(crate) fn note_req(&self, subscription_id: SubscriptionId, filters: Vec<Filter>) {
        self.with(|inner| {
            *inner.reqs.entry(subscription_id.clone()).or_default() += 1;
            inner.filters.insert(subscription_id, filters);
        });
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

    pub(crate) fn note_refused_connect(&self) {
        self.with(|inner| inner.refused_connects += 1);
    }

    pub(crate) fn note_unanswered_connect(&self) {
        self.with(|inner| inner.unanswered_connects += 1);
    }

    pub(crate) fn note_withheld_eose(&self) {
        self.with(|inner| inner.withheld_eose += 1);
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
                .field("refused", &sim_magnitude(inner.refusals.len()))
                .field("delivered", &sim_magnitude(inner.delivered.len()))
                .field("published", &sim_magnitude(inner.published.len()))
                .field("injected", &sim_magnitude(inner.injected.len()))
                .field("reqs", &sim_magnitude(inner.reqs.len()))
                .field("closed", &sim_magnitude(inner.closed.len()))
                .field("notices", &sim_magnitude(inner.notices.len()))
                .field("eose", &sim_magnitude(inner.eose))
                .field("faults", &sim_magnitude(inner.faults.len()))
                .field("refused_connects", &sim_magnitude(inner.refused_connects))
                .field(
                    "unanswered_connects",
                    &sim_magnitude(inner.unanswered_connects),
                )
                .field("withheld_eose", &sim_magnitude(inner.withheld_eose))
                .field("neg", &sim_magnitude(inner.neg.values().sum()))
                .field(
                    "plane_frames",
                    &sim_magnitude(inner.planes.first_seen.len()),
                )
                .field("plane_full", &inner.planes.full)
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
        ledger.note_ok(an_event_id(1), true, "");
        ledger.note_ok(an_event_id(2), false, "invalid: event too large");
        assert!(ledger.witnessed_ok(&an_event_id(1)));
        assert!(
            !ledger.witnessed_ok(&an_event_id(2)),
            "a rejection is not an acknowledgement"
        );
        assert!(!ledger.witnessed_ok(&an_event_id(3)));
    }

    #[test]
    fn a_refusal_is_recorded_verbatim_and_a_silence_is_not_a_refusal() {
        let ledger = Ledger::new();
        ledger.note_ok(an_event_id(1), true, "");
        ledger.note_ok(an_event_id(2), false, "invalid: event too large");
        assert_eq!(
            ledger.refusal(&an_event_id(2)).as_deref(),
            Some("invalid: event too large"),
            "a client branches on the machine-readable prefix, so it is kept as it was written"
        );
        assert_eq!(
            ledger.refusal(&an_event_id(1)),
            None,
            "an acknowledgement is not a refusal"
        );
        assert_eq!(
            ledger.refusal(&an_event_id(3)),
            None,
            "a swallowed OK leaves NO frame at all, which is the evidence that tells it \
             apart from a refusal"
        );
    }

    #[test]
    fn an_injection_goes_to_every_subscription_that_asked_for_it_and_no_other() {
        let ledger = Ledger::new();
        let event = nostr::EventBuilder::new(nostr::Kind::Custom(445), "x")
            .tags(vec![
                nostr::Tag::parse(["h", &hex::encode([7u8; 32])]).expect("a tag")
            ])
            .sign_with_keys(&nostr::Keys::generate())
            .expect("signs");

        let wanted = SubscriptionId::new("wants-445s");
        let other = SubscriptionId::new("wants-profiles");
        ledger.note_req(
            wanted.clone(),
            vec![Filter::new().kind(nostr::Kind::Custom(445))],
        );
        ledger.note_req(other, vec![Filter::new().kind(nostr::Kind::Metadata)]);

        assert_eq!(
            ledger.subscriptions_matching(&event),
            vec![wanted.clone()],
            "a relay puts an event on the subscriptions whose filter matches it, and no others"
        );

        // A re-issued REQ replaces its own filters, as a relay's does.
        ledger.note_req(wanted, vec![Filter::new().kind(nostr::Kind::Metadata)]);
        assert!(
            ledger.subscriptions_matching(&event).is_empty(),
            "an injection nobody subscribed for is a fault that did not fire"
        );
    }

    #[test]
    fn delivery_and_publication_are_counted_per_direction() {
        let ledger = Ledger::new();
        ledger.note_published(an_event_id(1));
        ledger.note_delivered(None, an_event_id(1));
        ledger.note_delivered(None, an_event_id(1));
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
    fn a_delivery_is_answered_per_endpoint_and_summed_over_the_plane() {
        let ledger = Ledger::new();
        let (alice, bob, carol) = (DeviceTag::new(0), DeviceTag::new(1), DeviceTag::new(2));
        ledger.note_delivered(Some(alice), an_event_id(1));
        ledger.note_delivered(Some(bob), an_event_id(1));
        ledger.note_delivered(Some(bob), an_event_id(1));
        ledger.note_delivered(None, an_event_id(2));
        assert!(ledger.delivered_to(alice, &an_event_id(1)));
        assert!(ledger.delivered_to(bob, &an_event_id(1)));
        assert!(
            !ledger.delivered_to(carol, &an_event_id(1)),
            "a device whose endpoint never carried the frame was not sent it, whatever the \
             plane wrote elsewhere"
        );
        assert!(
            !ledger.delivered_to(alice, &an_event_id(2)),
            "a frame the canonical endpoint wrote reached no device's own endpoint"
        );
        assert_eq!(
            ledger.delivered(&an_event_id(1)),
            3,
            "the plane-wide count is the sum over every endpoint"
        );
        assert_eq!(ledger.delivered(&an_event_id(2)), 1);
    }

    #[test]
    fn reqs_are_counted_per_subscription_and_in_total() {
        let ledger = Ledger::new();
        let one = SubscriptionId::new("one");
        let other = SubscriptionId::new("other");
        ledger.note_req(one.clone(), Vec::new());
        ledger.note_req(one.clone(), Vec::new());
        ledger.note_req(other.clone(), Vec::new());
        assert_eq!(ledger.reqs_for(&one), 2);
        assert_eq!(ledger.reqs_for(&other), 1);
        assert_eq!(ledger.reqs(), 3);
    }

    #[test]
    fn a_handle_is_minted_once_per_event_in_observation_order() {
        let ledger = Ledger::new();
        ledger.note_published(an_event_id(7));
        ledger.note_delivered(None, an_event_id(8));
        ledger.note_delivered(Some(DeviceTag::new(1)), an_event_id(7));
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
        other.note_ok(an_event_id(4), true, "");
        assert!(ledger.witnessed_ok(&an_event_id(4)));
    }

    /// A forged 445 under a key belonging to nobody, its `#h` a planted
    /// routing id.
    fn an_injected_event() -> Event {
        nostr::EventBuilder::new(nostr::Kind::Custom(445), "x")
            .tags(vec![
                nostr::Tag::parse(["h", &"cd".repeat(32)]).expect("a tag")
            ])
            .sign_with_keys(&nostr::Keys::generate())
            .expect("signs")
    }

    #[test]
    fn rendering_a_ledger_buckets_its_counts_and_names_nothing_it_carried() {
        let ledger = Ledger::new();
        ledger.note_ok(an_event_id(1), true, "");
        ledger.note_delivered(Some(DeviceTag::new(0)), an_event_id(1));
        ledger.note_published(an_event_id(1));
        ledger.note_req(SubscriptionId::new("needle-subscription"), Vec::new());
        ledger.note_closed("rate-limited: needle-text".to_string());
        ledger.note_notice("npub1needleneedle".to_string());
        // The two fields nothing else in this file plants into: a refusal's
        // message is relay-authored prose, and an injected id is the only event
        // id that reaches the ledger without a member having published it.
        ledger.note_ok(an_event_id(2), false, "invalid: needle-refusal-prose");
        let injected = an_injected_event();
        ledger.note_injected(&injected);
        // And the plane record, which holds whole frames: a relay URL, a
        // pubkey and a routing id, each planted.
        let pubkey = "ab".repeat(32);
        ledger.note_plane_frame(
            EndpointId::Own(DeviceTag::new(0)),
            7,
            Some(&format!(
                r#"["REQ","needle-sub",{{"kinds":[10050],"authors":["{pubkey}"]}}]"#
            )),
        );
        ledger.note_plane_frame(
            EndpointId::Alias(DeviceTag::new(0), 3),
            7,
            Some(r#"["EVENT",{"id":"x","kind":10002,"tags":[["r","wss://needle.example.com"]]}]"#),
        );

        let rendered = format!("{ledger:?}");
        assert!(rendered.contains("Ledger"), "{rendered}");
        assert!(rendered.contains("acked"), "{rendered}");
        // The counts still render, or "carries nothing" would be satisfied by a
        // rendering that dropped the two fields instead of bucketing them.
        assert!(rendered.contains(r#"refused: "1""#), "{rendered}");
        assert!(rendered.contains(r#"injected: "1""#), "{rendered}");
        assert!(rendered.contains(r#"plane_frames: "2-4""#), "{rendered}");
        let event_hex = hex::encode([1u8; 32]);
        let injected_hex = injected.id.to_hex();
        let routing = "cd".repeat(32);
        for needle in [
            "needle",
            "npub1",
            "rate-limited",
            "invalid:",
            "wss://",
            event_hex.as_str(),
            injected_hex.as_str(),
            pubkey.as_str(),
            routing.as_str(),
            "0101",
        ] {
            assert!(
                !rendered.contains(needle),
                "a ledger rendering must carry no value it holds"
            );
        }
        let water = format!("{:?}", ledger.plane_high_water());
        assert!(water.contains(r#"ids: "2-4""#), "bucketed: {water}");
    }

    fn texts(ledger: &Ledger) -> Vec<String> {
        ledger
            .plane_record()
            .frames
            .into_iter()
            .map(|frame| frame.text)
            .collect()
    }

    #[test]
    fn a_reissued_req_is_one_shape_and_a_new_connection_is_another() {
        let ledger = Ledger::new();
        let own = EndpointId::Own(DeviceTag::new(1));
        for since in [10, 20, 30] {
            ledger.note_plane_frame(
                own,
                1,
                Some(&format!(
                    r##"["REQ","s",{{"kinds":[445],"#h":["aa"],"since":{since}}}]"##
                )),
            );
        }
        assert_eq!(
            texts(&ledger),
            vec![r##"["REQ","s",{"#h":["aa"],"kinds":[445],"since":0}]"##.to_owned()],
            "a re-issue differs only in its window, so it is one entry with its key set kept"
        );
        ledger.note_plane_frame(
            own,
            2,
            Some(r##"["REQ","s",{"kinds":[445],"#h":["aa"],"since":40}]"##),
        );
        ledger.note_plane_frame(
            EndpointId::Canonical,
            2,
            Some(r##"["REQ","s",{"kinds":[445],"#h":["aa"],"since":40}]"##),
        );
        let record = ledger.plane_record();
        assert_eq!(record.frames.len(), 3, "per (endpoint, connection)");
        assert!(
            record.frames.windows(2).all(|pair| pair[0].at < pair[1].at),
            "kept in arrival order"
        );
        assert_eq!(ledger.plane_high_water().shapes, 3);
    }

    #[test]
    fn an_event_is_kept_without_its_content_and_signature_and_indexed_by_its_h() {
        let ledger = Ledger::new();
        let own = EndpointId::Own(DeviceTag::new(0));
        let frame = r#"["EVENT",{"id":"e1","pubkey":"p","kind":445,"created_at":5,"content":"secret","sig":"s","tags":[["h","aa"]]}]"#;
        ledger.note_plane_frame(own, 1, Some(frame));
        ledger.note_plane_frame(own, 1, Some(frame));
        let record = ledger.plane_record();
        assert_eq!(record.frames.len(), 1, "a re-send is the same event");
        assert!(!record.frames[0].text.contains("secret"));
        assert!(!record.frames[0].text.contains("\"sig\""));
        assert!(record.frames[0].text.contains("\"pubkey\":\"p\""));
        assert_eq!(
            record.events,
            vec![("e1".to_owned(), 445, Some("aa".to_owned()))]
        );
        assert_eq!(
            ledger.plane_high_water(),
            PlaneHighWater { shapes: 0, ids: 1 }
        );
    }

    #[test]
    fn every_frame_is_kept_unparsed_binary_and_continuations_included() {
        let ledger = Ledger::new();
        let own = EndpointId::Own(DeviceTag::new(0));
        ledger.note_plane_frame(own, 1, Some("not json"));
        ledger.note_plane_frame(own, 1, Some(r#"["COUNT","c",{"kinds":[1]}]"#));
        ledger.note_plane_frame(own, 1, Some(r#"["AUTH",{}]"#));
        ledger.note_plane_frame(own, 1, None);
        ledger.note_plane_frame(own, 1, Some(r#"["NEG-MSG","n","6162"]"#));
        ledger.note_plane_frame(own, 1, Some(r#"["NEG-MSG","n","6364"]"#));
        assert_eq!(
            texts(&ledger),
            vec![
                "not json".to_owned(),
                r#"["COUNT","c",{"kinds":[1]}]"#.to_owned(),
                r#"["AUTH",{}]"#.to_owned(),
                String::new(),
                r#"["NEG-MSG","n",""]"#.to_owned(),
            ],
            "nothing is skipped for failing to parse, and a reconciliation round is one shape"
        );
    }

    #[test]
    fn a_full_record_says_so_and_keeps_nothing_further() {
        let ledger = Ledger::new();
        ledger.set_plane_caps(1, 1);
        let own = EndpointId::Own(DeviceTag::new(0));
        ledger.note_plane_frame(own, 1, Some(r#"["CLOSE","a"]"#));
        assert!(!ledger.plane_record().full);
        ledger.note_plane_frame(own, 1, Some(r#"["CLOSE","b"]"#));
        let record = ledger.plane_record();
        assert!(record.full, "the cap is never a silent drop");
        assert_eq!(record.frames.len(), 1);

        let ids = Ledger::new();
        ids.set_plane_caps(PLANE_SHAPES_CAP, 1);
        ids.note_injected(&an_injected_event());
        ids.note_seeded(&an_injected_event());
        assert!(ids.plane_record().full, "seeded and forged ids count too");
    }

    #[test]
    fn an_endpoint_names_its_device_and_the_canonical_one_none() {
        let dev = DeviceTag::new(2);
        assert_eq!(EndpointId::Canonical.device(), None);
        assert_eq!(EndpointId::Own(dev).device(), Some(dev));
        assert_eq!(EndpointId::Alias(dev, 4).device(), Some(dev));
        assert_eq!(
            format!("{:?}", EndpointId::Alias(dev, 4)),
            "Alias(simdev#2, 4)"
        );
    }
}
