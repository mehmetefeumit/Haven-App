//! A relay plane: a real relay, the endpoint the devices dial, and the ledger
//! of what crossed it.
//!
//! Nothing here simulates a relay. [`SimRelay`] runs `nostr-relay-builder`'s
//! own `LocalRelay` over a real loopback socket, with a proxy in front that
//! owns the client-facing stream — which is where every fault lands, because
//! `nostr-relay-builder` has exactly two hook layers (build-time fields and
//! per-`EVENT`/per-`REQ` policy plugins) and neither can drop a frame, forge
//! one, or spell a machine-readable prefix of its own.
//!
//! # The two halves of a swallowed acknowledgement
//!
//! [`SimRelay::stored`] reads the relay's own store and
//! [`RelayPlane::witnessed_ok`] reads the client-facing ledger. Under
//! [`Fault::SwallowOk`] the first is true and the second is false, and that gap
//! IS the fault: Rule 13 says "acked" means a relay's acknowledgement REACHED
//! the publisher, never that the relay has the event.

mod forge;
mod ledger;
mod policies;
mod proxy;

pub use forge::{mint, Forgery};
pub use ledger::Ledger;
pub use policies::{oversize_message, NativeClosed, OVERSIZE_PREFIX};

use std::collections::BTreeMap;
use std::fmt;
use std::net::{IpAddr, Ipv4Addr};
use std::time::Duration;

use nostr::{Event, EventId, Filter};
use nostr_database::{DatabaseEventStatus, MemoryDatabase, MemoryDatabaseOptions, NostrDatabase};
use nostr_relay_builder::{LocalRelay, RelayBuilder};

use crate::nemesis::types::{Fault, RigCount};
use crate::relay::proxy::{arm_refuse_page, FaultState, Proxy};
use crate::rig::plane::RelayPlane;
use crate::rig::{sim_magnitude, DeviceTag, RelayTag, RigError, Step};

/// The most events a plane's relay serves for a REQ whose filter sets no
/// `limit`.
///
/// `nostr-relay-builder`'s `default_filter_limit`
/// (`nostr-relay-builder-0.44.1/src/builder.rs:225`, applied to a limitless
/// filter at `local/inner.rs:852-854`). The field is `pub(crate)` with no
/// getter, so no expression in this crate can read it: the value is written out
/// here with its citation, and `tests/relay_faults.rs` pins it on the wire — a
/// store one past it, a REQ with no limit, exactly the newest this many back.
/// S08 buries a commit under it; Haven's live group REQ sets no limit.
pub const RELAY_DEFAULT_REPLAY_CAP: usize = 500;

/// One relay the world can break.
///
/// One relay, several endpoints in front of it. The canonical endpoint is what
/// reaches STORAGE — `CircleConfig::with_relays`, a member's inbox relays,
/// `create_circle`'s relay argument — and therefore what a catch-up sweep
/// dials for every circle, because `run_catchup_all_circles` reads its list
/// out of storage and `resync_circle_relays_from_mdk` rewrites that row from
/// the engine's routing component after any group update. A device's OWN
/// endpoint is what its engine and its publish plane dial, so a fault aimed at
/// one device partitions that device and nothing else.
pub struct SimRelay {
    tag: RelayTag,
    ledger: Ledger,
    relay_url: String,
    canonical: Proxy,
    per_device: BTreeMap<DeviceTag, Proxy>,
    db: MemoryDatabase,
    // Kept alive deliberately: a `LocalRelay` shuts itself down when its last
    // handle is dropped, which would take the plane's store with it.
    _relay: LocalRelay,
}

impl SimRelay {
    /// Starts a healthy plane.
    ///
    /// # Errors
    ///
    /// [`RigError::Core`] with [`Step::ApplyFault`] — the rig's one
    /// classification for a relay plane — if the relay or its endpoint cannot
    /// be bound.
    pub async fn start(tag: RelayTag) -> Result<Self, RigError> {
        Self::build(tag, |builder| builder).await
    }

    /// Starts a plane that refuses every subscription from a build-time knob of
    /// the relay itself.
    ///
    /// This is the byte-fidelity control, not a fault: the knobs are consumed
    /// when the relay is built, so such a plane refuses for its whole life. Its
    /// value is that the `CLOSED` text it produces is the relay's own, which is
    /// what a forged one is compared against.
    ///
    /// # Errors
    ///
    /// As [`Self::start`].
    pub async fn start_refusing_natively(
        tag: RelayTag,
        native: NativeClosed,
    ) -> Result<Self, RigError> {
        Self::build(tag, |builder| native.configure(builder)).await
    }

    /// Starts a plane whose relay clamps every filter's `limit` to `max` itself.
    ///
    /// The byte-fidelity control for [`Fault::ClampLimit`], which has to be
    /// forged: a `QueryPolicy` answers `Accept`/`Reject` and cannot rewrite a
    /// `limit` (`nostr-relay-builder-0.44.1/src/builder.rs:98-103`), and the
    /// relay's own clamp runs before the policy loop ever sees the filter
    /// (`local/inner.rs:838-877`). So this knob (`builder.rs:306`) is only ever
    /// the comparison.
    ///
    /// # Errors
    ///
    /// As [`Self::start`].
    pub async fn start_clamping_natively(tag: RelayTag, max: RigCount) -> Result<Self, RigError> {
        Self::build(tag, |builder| builder.max_filter_limit(max.get())).await
    }

    async fn build(
        tag: RelayTag,
        configure: impl FnOnce(RelayBuilder) -> RelayBuilder,
    ) -> Result<Self, RigError> {
        // `events: true` is not the default: a default memory database is an id
        // tracker that stores nothing, and a plane that cannot serve a page
        // back would make every catch-up scenario vacuous.
        let db = MemoryDatabase::with_opts(MemoryDatabaseOptions {
            events: true,
            max_events: None,
        });
        let relay = LocalRelay::new(configure(
            RelayBuilder::default()
                .addr(IpAddr::V4(Ipv4Addr::LOCALHOST))
                .database(db.clone()),
        ));
        relay
            .run()
            .await
            .map_err(|_| RigError::Core(Step::ApplyFault))?;
        let ledger = Ledger::new();
        let relay_url = relay.url().await.to_string();
        let canonical = Proxy::start(&relay_url, ledger.clone(), None).await?;
        Ok(Self {
            tag,
            ledger,
            relay_url,
            canonical,
            per_device: BTreeMap::new(),
            db,
            _relay: relay,
        })
    }

    /// Everything this plane put on the wire, per direction.
    #[must_use]
    pub const fn ledger(&self) -> &Ledger {
        &self.ledger
    }

    /// Whether the relay's own store holds `event_id`.
    ///
    /// The other half of a swallowed acknowledgement, and the read-back an
    /// oracle needs to tell "the relay never got it" from "the relay got it and
    /// the client never heard so".
    ///
    /// # Errors
    ///
    /// [`RigError::Core`] with [`Step::Publish`]: the question this answers is
    /// whether a publish landed, and a store that cannot say is a plane that
    /// cannot grade one.
    pub async fn stored(&self, event_id: &EventId) -> Result<bool, RigError> {
        self.db
            .check_id(event_id)
            .await
            .map(|status| matches!(status, DatabaseEventStatus::Saved))
            .map_err(|_| RigError::Core(Step::Publish))
    }
}

impl SimRelay {
    /// The events this plane's store would serve for `filter`, in the order it
    /// would serve them.
    ///
    /// # Errors
    ///
    /// [`RigError::Core`] with [`Step::Publish`] if the store cannot answer.
    pub async fn stored_page(&self, filter: Filter) -> Result<Vec<Event>, RigError> {
        self.db
            .query(filter)
            .await
            .map(|events| events.into_iter().collect())
            .map_err(|_| RigError::Core(Step::Publish))
    }

    /// Writes `events` straight into the plane's store, as a relay that had
    /// already accepted them would hold them, and returns how many were NEWLY
    /// saved.
    ///
    /// Never through the client-facing proxy, and never through
    /// `LocalRelay::notify_event`, which fans an event out to live
    /// subscriptions without saving it (`nostr-relay-builder-0.44.1/src/local/mod.rs:59-67`):
    /// the point is a backlog that exists BEFORE anybody subscribes, so a seed
    /// reaches the store and no live subscriber. It is the store the builder
    /// was handed, which holds events only because [`Self::build`] asks for a
    /// full one.
    ///
    /// The count is exact because a duplicate is not an error: the store
    /// answers `Ok(SaveEventStatus::Rejected(Duplicate))`
    /// (`nostr-database-0.44.0/src/helper.rs:199-204`), so an arm reading
    /// "strictly more than N were stored" compares the return value.
    ///
    /// # Errors
    ///
    /// [`RigError::Core`] with [`Step::ApplyFault`] if the store refuses a
    /// write outright: a seed that did not land is a backlog that is not
    /// there.
    pub async fn store(&self, events: &[Event]) -> Result<usize, RigError> {
        let mut saved = 0;
        for event in events {
            let status = self
                .db
                .save_event(event)
                .await
                .map_err(|_| RigError::Core(Step::ApplyFault))?;
            saved += usize::from(status.is_success());
        }
        Ok(saved)
    }
}

/// The event `db` holds under `event_id`.
///
/// [`RigError::Core`] with [`Step::ApplyFault`] if the store cannot answer or
/// holds no such event — the only caller is a forgery that copies an OBSERVED
/// ciphertext, and a copy of nothing is a fault that did not fire.
async fn stored_event(db: &MemoryDatabase, event_id: &EventId) -> Result<Event, RigError> {
    db.query(Filter::new().id(*event_id))
        .await
        .map_err(|_| RigError::Core(Step::ApplyFault))?
        .into_iter()
        .next()
        .ok_or(RigError::Core(Step::ApplyFault))
}

impl RelayPlane for SimRelay {
    fn tag(&self) -> RelayTag {
        self.tag
    }

    fn url(&self) -> &str {
        self.canonical.url()
    }

    /// Binds a listener of `device`'s own in front of the same relay, over the
    /// same store and the same ledger. Idempotent: a device provisioned twice
    /// keeps the endpoint its engine already dials.
    async fn provision(&mut self, device: DeviceTag) -> Result<(), RigError> {
        if self.per_device.contains_key(&device) {
            return Ok(());
        }
        let proxy = Proxy::start(&self.relay_url, self.ledger.clone(), Some(device)).await?;
        self.per_device.insert(device, proxy);
        Ok(())
    }

    fn url_for(&self, device: DeviceTag) -> &str {
        self.per_device
            .get(&device)
            .map_or_else(|| self.canonical.url(), Proxy::url)
    }

    fn last_rebind(&self) -> Option<(u32, Duration)> {
        let (attempts, wait) = self.ledger().rebind();
        (attempts > 0).then_some((attempts, wait))
    }

    fn faults_applied(&self) -> usize {
        self.ledger.faults_applied()
    }

    async fn apply(&mut self, fault: Fault) -> Result<(), RigError> {
        self.apply_to(None, fault).await
    }

    async fn apply_for(&mut self, device: DeviceTag, fault: Fault) -> Result<(), RigError> {
        self.apply_to(Some(device), fault).await
    }

    fn witnessed_ok(&self, event_id: &EventId) -> bool {
        self.ledger.witnessed_ok(event_id)
    }
}

impl SimRelay {
    /// Applies `fault` to every endpoint of the plane for `None` — an outage
    /// or a refusal is the RELAY's, and a device's own endpoint fronts the
    /// same relay — or to one device's endpoint alone.
    ///
    /// A device with no endpoint here is refused, not provisioned: a fault
    /// armed on a listener nobody dials would count towards an arm's floor
    /// while changing nothing any engine sees, which is a fault that did not
    /// fire wearing the record of one that did.
    async fn apply_to(&mut self, device: Option<DeviceTag>, fault: Fault) -> Result<(), RigError> {
        let Self {
            ledger,
            canonical,
            per_device,
            db,
            ..
        } = self;
        let mut endpoints: Vec<&mut Proxy> = match device {
            None => std::iter::once(canonical)
                .chain(per_device.values_mut())
                .collect(),
            Some(device) => vec![per_device.get_mut(&device).ok_or(RigError::UnknownTarget)?],
        };
        let applied = apply_inner(&mut endpoints, db, ledger, fault).await;
        // Recorded once per fault, however many endpoints took it, and only
        // once the plane really reached the state the fault names — never for
        // a heal: a fault that could not be applied did not fire, and healing
        // is what makes a fault a fault.
        if applied.is_ok() && !matches!(fault, Fault::Heal) {
            ledger.note_fault(fault.label());
        }
        applied
    }
}

async fn apply_inner(
    endpoints: &mut [&mut Proxy],
    db: &MemoryDatabase,
    ledger: &Ledger,
    fault: Fault,
) -> Result<(), RigError> {
    match fault {
        Fault::Down => {
            for endpoint in endpoints {
                endpoint.take_down().await;
            }
            Ok(())
        }
        Fault::Up => {
            for endpoint in endpoints {
                endpoint.bring_up().await?;
            }
            Ok(())
        }
        // The relay keeps running and forgets: an outage is `Down`, and
        // conflating the two would make a scenario that scheduled one prove
        // the other. The store is the plane's, so a wipe aimed at a device's
        // endpoint forgets for every endpoint.
        Fault::WipeStore => db
            .wipe()
            .await
            .map_err(|_| RigError::Core(Step::ApplyFault)),
        Fault::Closed(prefix) => {
            edit_all(endpoints, |state| state.closed = Some(prefix));
            Ok(())
        }
        // Sent on every endpoint that has a listener; a notice nobody at all
        // received did not happen.
        Fault::Notice(text) => reached_any(endpoints.iter().map(|endpoint| endpoint.notice(text))),
        Fault::SwallowOk => {
            edit_all(endpoints, |state| state.swallow_ok = true);
            Ok(())
        }
        Fault::DoubleEveryEvent => {
            edit_all(endpoints, |state| state.double_events = true);
            Ok(())
        }
        Fault::ReversePages => {
            edit_all(endpoints, |state| state.reverse_pages = true);
            Ok(())
        }
        Fault::EoseForAnotherSubscription => {
            edit_all(endpoints, |state| state.cross_eose = true);
            Ok(())
        }
        // The source is resolved from this plane's OWN store, because "an
        // observed ciphertext" means one this relay really carried: a rewrap
        // of an event nobody published is a synthetic shape, and the arm
        // asking for one has mis-aimed its fault.
        //
        // Delivered by the relay's own rule (NIP-01): onto every open
        // subscription whose filter matches it, so an injection naming one
        // chosen by the harness would be discarded by the client or land
        // where no relay would put it. Recorded once per injection, not once
        // per frame or per endpoint: an arm asks the plane to forge ONE
        // event, and it is the event — not the delivery — it later has to be
        // able to name. Never saved, which is the whole point — an injected
        // event is one an adversary put on the wire, and a later catch-up
        // sweep must not find it in the plane's pages.
        Fault::Inject(forgery) => {
            let source = match forgery.source() {
                Some(event_id) => Some(stored_event(db, &event_id).await?),
                None => None,
            };
            let forged = forge::mint(forgery, source.as_ref())?;
            let matching = ledger.subscriptions_matching(&forged);
            if matching.is_empty() {
                return Err(RigError::Core(Step::ApplyFault));
            }
            ledger.note_injected(forged.id);
            reached_any(
                endpoints
                    .iter()
                    .map(|endpoint| endpoint.broadcast_event(&forged, &matching)),
            )
        }
        Fault::RefuseOversize { max_bytes } => {
            edit_all(endpoints, |state| {
                state.max_event_bytes = Some(max_bytes.bytes());
            });
            Ok(())
        }
        Fault::DropClass(class) => {
            edit_all(endpoints, |state| state.drop_class = Some(class));
            Ok(())
        }
        Fault::ClampLimit(n) => {
            edit_all(endpoints, |state| state.clamp_limit = Some(n.get()));
            Ok(())
        }
        // One arming for every endpoint, so each connection on each of them
        // counts from this call.
        Fault::RefusePage { nth } => {
            let armed = arm_refuse_page(nth);
            edit_all(endpoints, |state| state.refuse_page = Some(armed));
            Ok(())
        }
        Fault::ColdFirstConnect => {
            edit_all(endpoints, |state| state.cold_first_connect = true);
            Ok(())
        }
        // A heal restores BEHAVIOUR, endpoint included. It cannot restore a
        // wiped store: nothing un-forgets, and pretending otherwise would hide
        // the one fault whose damage outlives it.
        Fault::Heal => {
            for endpoint in endpoints {
                endpoint.edit(|state| *state = FaultState::default());
                endpoint.bring_up().await?;
            }
            Ok(())
        }
    }
}

/// Edits every endpoint's fault state the same way.
fn edit_all(endpoints: &mut [&mut Proxy], change: impl Fn(&mut FaultState)) {
    for endpoint in endpoints {
        endpoint.edit(&change);
    }
}

/// `Ok` if any endpoint delivered; the frame reached somebody. `Err` only if
/// every endpoint refused, which is a fault that did not fire.
fn reached_any(outcomes: impl Iterator<Item = Result<(), RigError>>) -> Result<(), RigError> {
    // Folded, never searched: a search stops at the first live endpoint and
    // leaves the frame unsent on every endpoint after it — in a multi-device
    // world, every engine but one.
    if outcomes.fold(false, |reached, outcome| reached | outcome.is_ok()) {
        Ok(())
    } else {
        Err(RigError::Core(Step::ApplyFault))
    }
}

// The handle, whether the endpoint is open, and bucketed counts. The URL is a
// loopback address and still an address: Rule 15 names hosts and IPs outright,
// and this type shares an evidence file with the subject's own lines.
impl fmt::Debug for SimRelay {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("SimRelay")
            .field("tag", &self.tag)
            .field("accepting", &self.canonical.is_up())
            .field("device_endpoints", &sim_magnitude(self.per_device.len()))
            .field("ledger", &self.ledger)
            .finish_non_exhaustive()
    }
}
