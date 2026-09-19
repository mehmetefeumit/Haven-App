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

pub use ledger::Ledger;
pub use policies::NativeClosed;

use std::fmt;
use std::net::{IpAddr, Ipv4Addr};
use std::time::Duration;

use nostr::EventId;
use nostr_database::{DatabaseEventStatus, MemoryDatabase, MemoryDatabaseOptions, NostrDatabase};
use nostr_relay_builder::{LocalRelay, RelayBuilder};

use crate::nemesis::types::Fault;
use crate::relay::proxy::{FaultState, Proxy};
use crate::rig::plane::RelayPlane;
use crate::rig::{RelayTag, RigError, Step};

/// One relay the world can break.
pub struct SimRelay {
    tag: RelayTag,
    ledger: Ledger,
    proxy: Proxy,
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
        let proxy = Proxy::start(&relay.url().await.to_string(), ledger.clone()).await?;
        Ok(Self {
            tag,
            ledger,
            proxy,
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
    pub async fn stored_page(&self, filter: nostr::Filter) -> Result<Vec<nostr::Event>, RigError> {
        self.db
            .query(filter)
            .await
            .map(|events| events.into_iter().collect())
            .map_err(|_| RigError::Core(Step::Publish))
    }
}

impl RelayPlane for SimRelay {
    fn tag(&self) -> RelayTag {
        self.tag
    }

    fn url(&self) -> &str {
        self.proxy.url()
    }

    fn last_rebind(&self) -> Option<(u32, Duration)> {
        let (attempts, wait) = self.ledger().rebind();
        (attempts > 0).then_some((attempts, wait))
    }

    fn faults_applied(&self) -> usize {
        self.ledger.faults_applied()
    }

    async fn apply(&mut self, fault: Fault) -> Result<(), RigError> {
        let applied = self.apply_inner(fault).await;
        // Recorded only once the plane really reached the state the fault
        // names, and never for a heal: a fault that could not be applied did
        // not fire, and healing is what makes a fault a fault.
        if applied.is_ok() && !matches!(fault, Fault::Heal) {
            self.ledger.note_fault(fault.label());
        }
        applied
    }

    fn witnessed_ok(&self, event_id: &EventId) -> bool {
        self.ledger.witnessed_ok(event_id)
    }
}

impl SimRelay {
    async fn apply_inner(&mut self, fault: Fault) -> Result<(), RigError> {
        match fault {
            Fault::Down => {
                self.proxy.take_down().await;
                Ok(())
            }
            Fault::Up => self.proxy.bring_up().await,
            // The relay keeps running and forgets: an outage is `Down`, and
            // conflating the two would make a scenario that scheduled one prove
            // the other.
            Fault::WipeStore => self
                .db
                .wipe()
                .await
                .map_err(|_| RigError::Core(Step::ApplyFault)),
            Fault::Closed(prefix) => {
                self.proxy.edit(|state| state.closed = Some(prefix));
                Ok(())
            }
            Fault::Notice(text) => self.proxy.notice(text),
            Fault::SwallowOk => {
                self.proxy.edit(|state| state.swallow_ok = true);
                Ok(())
            }
            Fault::DoubleEveryEvent => {
                self.proxy.edit(|state| state.double_events = true);
                Ok(())
            }
            Fault::ReversePages => {
                self.proxy.edit(|state| state.reverse_pages = true);
                Ok(())
            }
            Fault::EoseForAnotherSubscription => {
                self.proxy.edit(|state| state.cross_eose = true);
                Ok(())
            }
            // A heal restores BEHAVIOUR, endpoint included. It cannot restore a
            // wiped store: nothing un-forgets, and pretending otherwise would
            // hide the one fault whose damage outlives it.
            Fault::Heal => {
                self.proxy.edit(|state| *state = FaultState::default());
                self.proxy.bring_up().await
            }
        }
    }
}

// The handle, whether the endpoint is open, and bucketed counts. The URL is a
// loopback address and still an address: Rule 15 names hosts and IPs outright,
// and this type shares an evidence file with the subject's own lines.
impl fmt::Debug for SimRelay {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("SimRelay")
            .field("tag", &self.tag)
            .field("accepting", &self.proxy.is_up())
            .field("ledger", &self.ledger)
            .finish_non_exhaustive()
    }
}
