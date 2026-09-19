//! In-crate doubles for the three environment planes.
//!
//! They exist so the rig's own behaviour can be asserted without an oracle, a
//! scenario or a scanner in the picture. Only the ENVIRONMENT is doubled: the
//! relay behind [`TestRelay`] is a real in-process relay over a real socket,
//! and the devices that talk to it are real.
//!
//! What the relay double does NOT do is simulate the fault catalogue: it
//! records every fault it is handed and models exactly one of them
//! ([`Fault::SwallowOk`], with [`Fault::Heal`] undoing it), because that is the
//! one the rig itself branches on (Rule 13). Everything else is the fault
//! layer's own subject and is tested there, against the frame bytes.

use std::collections::HashSet;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};

use nostr::{EventId, Filter};
use nostr_relay_builder::MockRelay;
use nostr_sdk::{Client, RelayPoolNotification};

use crate::nemesis::types::Fault;
use crate::rig::plane::{CapturedLine, LogDrain, RelayPlane, TimelineRecord, TimelineSink};
use crate::rig::{RelayTag, RigError};

/// A real in-process relay, plus a witness of what it broadcast.
pub struct TestRelay {
    tag: RelayTag,
    url: String,
    witnessed: Arc<Mutex<HashSet<EventId>>>,
    swallow_ok: Arc<AtomicBool>,
    applied: Arc<Mutex<Vec<Fault>>>,
    /// A counter sampled every time this plane is asked for its Rule-13
    /// evidence, and the samples. The only way to observe a value that exists
    /// solely WHILE a publish is resolving, without a sleep or a second task
    /// racing the first.
    watching: Option<Arc<AtomicUsize>>,
    observed: Arc<Mutex<Vec<usize>>>,
    // Both are kept alive deliberately: dropping the relay closes the socket,
    // and dropping the witness client ends the subscription that fills the set.
    _relay: MockRelay,
    _witness: Client,
}

impl TestRelay {
    /// Starts a relay and the client that witnesses what it broadcasts.
    ///
    /// # Panics
    ///
    /// If the relay or its witness cannot start: a test that cannot build its
    /// own environment has nothing to assert.
    pub async fn start(tag: RelayTag) -> Self {
        let relay = MockRelay::run().await.expect("mock relay runs");
        let url = relay.url().await.to_string();

        let witness = Client::builder().build();
        witness.add_relay(&url).await.expect("witness adds relay");
        witness.connect().await;
        witness
            .subscribe(Filter::new(), None)
            .await
            .expect("witness subscribes");

        let witnessed = Arc::new(Mutex::new(HashSet::new()));
        let sink = Arc::clone(&witnessed);
        let mut notifications = witness.notifications();
        tokio::spawn(async move {
            while let Ok(notification) = notifications.recv().await {
                if let RelayPoolNotification::Event { event, .. } = notification {
                    sink.lock()
                        .unwrap_or_else(std::sync::PoisonError::into_inner)
                        .insert(event.id);
                }
            }
        });

        Self {
            tag,
            url,
            witnessed,
            swallow_ok: Arc::new(AtomicBool::new(false)),
            applied: Arc::new(Mutex::new(Vec::new())),
            watching: None,
            observed: Arc::new(Mutex::new(Vec::new())),
            _relay: relay,
            _witness: witness,
        }
    }

    /// Starts a relay whose acknowledgements never reach a client.
    pub async fn start_swallowing_acks(tag: RelayTag) -> Self {
        let relay = Self::start(tag).await;
        relay.swallow_ok.store(true, Ordering::Release);
        relay
    }

    /// Starts a relay that samples `counter` whenever it is asked whether it
    /// witnessed an `OK`.
    pub async fn start_watching(tag: RelayTag, counter: Arc<AtomicUsize>) -> Self {
        let mut relay = Self::start(tag).await;
        relay.watching = Some(counter);
        relay
    }

    /// What the watched counter read each time this plane was consulted.
    pub fn observed(&self) -> Vec<usize> {
        self.observed
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .clone()
    }

    /// Every fault this plane was handed, in order.
    pub fn applied(&self) -> Vec<Fault> {
        self.applied
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .clone()
    }
}

impl RelayPlane for TestRelay {
    fn tag(&self) -> RelayTag {
        self.tag
    }

    fn url(&self) -> &str {
        &self.url
    }

    async fn apply(&mut self, fault: Fault) -> Result<(), RigError> {
        self.applied
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .push(fault);
        match fault {
            Fault::SwallowOk => self.swallow_ok.store(true, Ordering::Release),
            Fault::Heal => self.swallow_ok.store(false, Ordering::Release),
            _ => {}
        }
        Ok(())
    }

    fn faults_applied(&self) -> usize {
        // The same rule the real plane applies: a heal is not a fault.
        self.applied()
            .iter()
            .filter(|fault| !matches!(fault, Fault::Heal))
            .count()
    }

    fn witnessed_ok(&self, event_id: &EventId) -> bool {
        if let Some(counter) = &self.watching {
            self.observed
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .push(counter.load(Ordering::Acquire));
        }
        if self.swallow_ok.load(Ordering::Acquire) {
            // The relay has it; the client never heard so. Rule 13 says that is
            // not an ack.
            return false;
        }
        self.witnessed
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .contains(event_id)
    }
}

/// A timeline that keeps what it was given.
#[derive(Clone, Default)]
pub struct RecordingTimeline {
    records: Arc<Mutex<Vec<TimelineRecord>>>,
}

impl RecordingTimeline {
    /// Everything recorded so far.
    pub fn records(&self) -> Vec<TimelineRecord> {
        self.records
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .clone()
    }
}

impl TimelineSink for RecordingTimeline {
    fn record(&self, record: TimelineRecord) {
        self.records
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .push(record);
    }
}

/// A log drain the test fills by hand.
#[derive(Clone, Default)]
pub struct StubDrain {
    lines: Arc<Mutex<Vec<CapturedLine>>>,
}

impl StubDrain {
    /// Adds a line for a later drain.
    pub fn push(&self, line: CapturedLine) {
        self.lines
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .push(line);
    }
}

impl LogDrain for StubDrain {
    fn drain_since(&self, from: u64) -> Vec<CapturedLine> {
        self.lines
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .iter()
            .filter(|line| line.seq >= from)
            .cloned()
            .collect()
    }
}
