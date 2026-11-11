//! Member bridging (plan §5.5, owner decision D-7; T-BRIDGE-1..8, 10, 11):
//! `Publishing::publish_location_and_bridge` passes on to a circle's relays
//! the location a fellow member sent by Bluetooth alone.
//!
//! What is passed on is that member's own sealed event, byte for byte, once;
//! only an update the engine read for the first time, from a packet marked
//! as one a member may pass on; only behind this device's own send, to the
//! relays that took it; only in a drive whose relay receive completed; and
//! only while a location this device sealed at the same epoch could be sent.
//! Whatever one send of this device's does not pass on is dropped.
//!
//! Real MDK engines over `SQLCipher` stores and the real hand-off. Every
//! mesh drive here runs through a transport that fails the test if it is
//! called at all; every relay drive through one that records each location
//! it is handed and counts every other call.

#![allow(clippy::unwrap_used, clippy::expect_used)]

mod helpers;

use std::future::Future;
use std::pin::Pin;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};

use haven_core::location::LocationMessage;
use haven_core::mesh::event::parts_of;
use haven_core::mesh::packet::{wrap, Format, MeshKey, Packet};
use haven_core::nostr::mls::types::{GroupId, TransportMessage};
use haven_core::nostr::mls::MeshDrive;
use haven_core::relay::fanout::scripted::Answer;
use haven_core::relay::fanout::scripted::ScriptedFanout;
use haven_core::relay::fanout::{
    is_owned, DriveMode, FanoutClock as _, FanoutSend, FanoutTargetOutcome, LocationPublish,
    LocationSeal, Publishing, Taken, UnrecordedPublisher,
};
use haven_core::relay::{DeviceClockComplaint, PublishResult, RelayError, RelayResult};
use helpers::drive::{
    epoch, ngid, reads, records_of, stored_fix, take_in_disband, through, ManualClock, Recorder,
};
use helpers::mesh::{
    handed_off, mesh_on, packet_as, restamped, secret_of, waiting, wall_ms, WatchedRelays,
};
use helpers::removals::confirmed;
use helpers::stranded::{split, stage_relays};
use helpers::{
    assert_no_needles, capture_haven_log_here, haven_core_lines, setup_circle, CircleMember,
};
use nostr::{Event, EventId, JsonUtil as _};
use rand::rngs::OsRng;

const ONE: &str = "wss://one.mesh-bridge.example.com";
const TWO: &str = "wss://two.mesh-bridge.example.com";
/// Where [`handed_off`] seals its location.
const LATITUDE: f64 = 51.5;
/// Where a bridging device seals its own.
const OWN_LATITUDE: f64 = 48.1;
const SECOND_MS: u64 = 1_000;
/// How long after one update of a member the next is passed on.
const SENDER_GAP_MS: u64 = 72_000;

type Hook = Box<dyn FnOnce() + Send>;

/// The relays a relay drive sends through: every location it is handed is
/// kept with the relays it was handed it for, and every other call counted.
struct Relays {
    /// The relays that take a location; every one when `None`.
    takes: Mutex<Option<Vec<String>>>,
    /// Whether the relays that took a location are reported as the pool
    /// reports them — under another spelling than the circle's — beside one
    /// that is no relay of the circle.
    respelled: AtomicBool,
    /// The first send, counted from one, that is answered as a relay blaming
    /// this device's clock.
    blames_clock_from: AtomicUsize,
    /// Run while the send of that number, counted from one, is on its way.
    during: Mutex<Option<(usize, Hook)>>,
    sent: Mutex<Vec<(Event, Vec<String>)>>,
    other_calls: AtomicUsize,
    inner: ScriptedFanout,
}

impl Default for Relays {
    fn default() -> Self {
        Self {
            takes: Mutex::new(None),
            respelled: AtomicBool::new(false),
            blames_clock_from: AtomicUsize::new(usize::MAX),
            during: Mutex::new(None),
            sent: Mutex::new(Vec::new()),
            other_calls: AtomicUsize::new(0),
            inner: ScriptedFanout::default(),
        }
    }
}

#[async_trait::async_trait]
impl FanoutSend for Relays {
    async fn take(&self, target: &str) -> Option<Taken> {
        self.other_calls.fetch_add(1, Ordering::SeqCst);
        self.inner.take(target).await
    }

    async fn publish(
        &self,
        target: &str,
        message: &TransportMessage,
        taken: Taken,
    ) -> FanoutTargetOutcome {
        self.other_calls.fetch_add(1, Ordering::SeqCst);
        self.inner.publish(target, message, taken).await
    }

    async fn publish_location(
        &self,
        event: &Event,
        targets: &[String],
    ) -> RelayResult<PublishResult> {
        let nth = {
            let mut sent = self.sent.lock().unwrap();
            sent.push((event.clone(), targets.to_vec()));
            sent.len()
        };
        let hook = (self.during.lock().unwrap()).take_if(|(at, _)| *at == nth);
        if let Some((_, hook)) = hook {
            hook();
        }
        if nth >= self.blames_clock_from.load(Ordering::SeqCst) {
            return Err(RelayError::DeviceClockRejected {
                complaint: DeviceClockComplaint::Ahead,
            });
        }
        let takes = self.takes.lock().unwrap().clone();
        let (mut accepted, failed): (Vec<String>, Vec<String>) = (targets.iter().cloned())
            .partition(|target| takes.as_ref().is_none_or(|takes| takes.contains(target)));
        if accepted.is_empty() {
            return Err(RelayError::AllRelaysFailed);
        }
        if self.respelled.load(Ordering::SeqCst) {
            for relay in &mut accepted {
                *relay = relay.replace("mesh-bridge.example.com", "MESH-BRIDGE.Example.COM/");
            }
            accepted.push("wss://elsewhere.mesh-bridge.example.com".to_owned());
        }
        Ok(PublishResult {
            event_id: event.id,
            accepted_by: accepted,
            rejected_by: Vec::new(),
            failed,
        })
    }
}

impl UnrecordedPublisher for Relays {
    fn publish_unrecorded<'a>(
        &'a self,
        _event: &'a Event,
        _relays: &'a [String],
    ) -> Pin<Box<dyn Future<Output = bool> + Send + 'a>> {
        self.other_calls.fetch_add(1, Ordering::SeqCst);
        Box::pin(async { true })
    }
}

/// A member with internet: its relays, the clock its relay drives read, and
/// the locations of its own it sent.
struct Bridger<'a> {
    member: &'a CircleMember,
    group: &'a GroupId,
    relays: Relays,
    clock: Arc<ManualClock>,
    /// Whether a test set the clock ([`Self::at`]). Until one does, each
    /// drive reads the device's own: the events its fellow members seal are
    /// stamped by that, and a clock left where the test began would fall
    /// behind them by however long the test has run.
    pinned: AtomicBool,
    own: Mutex<Vec<EventId>>,
}

impl<'a> Bridger<'a> {
    /// `member`, with mesh on, caught up with `group`, its clock at the
    /// device's own.
    async fn new(member: &'a CircleMember, group: &'a GroupId) -> Self {
        mesh_on(member).await;
        member.session().mark_caught_up_for_test(group);
        let bridger = Self {
            member,
            group,
            relays: Relays::default(),
            clock: ManualClock::at(0),
            pinned: AtomicBool::new(false),
            own: Mutex::new(Vec::new()),
        };
        bridger.clock();
        bridger
    }

    /// Sets the clock of this member's drives, milliseconds since the Unix
    /// epoch, for the rest of the test.
    fn at(&self, now_ms: u64) {
        self.pinned.store(true, Ordering::SeqCst);
        self.clock.set(now_ms - ManualClock::ORIGIN);
    }

    /// The clock a drive reads: where a test set it, or else the device's
    /// own as it now stands.
    fn clock(&self) -> &ManualClock {
        if !self.pinned.load(Ordering::SeqCst) {
            self.clock.set(wall_ms() - ManualClock::ORIGIN);
        }
        &self.clock
    }

    /// One mesh drive with `taken`, in the mode in which a relay drive may
    /// do anything. Fails if it called a relay in any way.
    async fn takes_in(&self, taken: Vec<Packet>) -> MeshDrive {
        let relays = WatchedRelays::default();
        let driver = Publishing {
            fanout: &relays,
            publisher: &relays,
            clock: self.clock(),
            deadline_ms: None,
            mode: &DriveMode::Full,
        };
        let drive = driver.mesh_drive(&self.member.circle, taken).await;
        assert!(relays.calls() == 0, "a mesh drive called a relay");
        drive
    }

    fn driver(&self) -> Publishing<'_, Relays> {
        Publishing {
            fanout: &self.relays,
            publisher: &self.relays,
            clock: self.clock(),
            deadline_ms: None,
            mode: &DriveMode::Full,
        }
    }

    /// A location of this member's own, sealed for its relays.
    async fn seals(&self) -> Event {
        let fix = LocationMessage::new(OWN_LATITUDE, 11.5);
        let outcome = (self.driver())
            .seal_location(&self.member.circle, self.group, &fix)
            .await
            .expect("the seal runs");
        match outcome.seal {
            LocationSeal::Sealed { event, .. } => {
                self.own.lock().unwrap().push(event.id);
                *event
            }
            LocationSeal::Deferred(held) => panic!("premise: the send is sealed, not {held:?}"),
        }
    }

    /// One relay drive's send: a location of this member's own, sealed and
    /// sent, with what it kept of its fellow members' passed on. `received`
    /// is whether the drive's relay receive completed before it.
    async fn publishes(&self, received: bool) -> LocationPublish {
        let own = self.seals().await;
        (self.driver())
            .publish_location_and_bridge(&self.member.circle, &own, received)
            .await
    }

    /// Every location the relays were handed since this was last asked that
    /// is not this member's own: what was passed on, with the relays it was
    /// handed to. Fails if anything but a location was sent.
    fn passed_on(&self) -> Vec<(Event, Vec<String>)> {
        assert!(
            self.relays.other_calls.load(Ordering::SeqCst) == 0,
            "a send of a location made some other relay call"
        );
        let own = self.own.lock().unwrap();
        (std::mem::take(&mut *self.relays.sent.lock().unwrap()).into_iter())
            .filter(|(event, _)| !own.contains(&event.id))
            .collect()
    }

    /// The events this member keeps to pass on.
    fn keeps(&self) -> Vec<EventId> {
        (self.member.session()).mesh_bridge_waiting_for_test(self.group)
    }

    /// A drive that takes `packets` in and then sends, its receive
    /// completed: what it passed on.
    async fn bridges(&self, packets: Vec<Packet>) -> Vec<(Event, Vec<String>)> {
        let _ = self.takes_in(packets).await;
        assert!(matches!(
            self.publishes(true).await,
            LocationPublish::Sent(Ok(_))
        ));
        self.passed_on()
    }
}

fn ids(sent: &[(Event, Vec<String>)]) -> Vec<EventId> {
    sent.iter().map(|(event, _)| event.id).collect()
}

/// A fresh application message `sender` seals and hands nobody, in an event
/// stamped as any member can stamp one — sealed at `created_at`, to live
/// `life_secs` — and a packet of it a member may pass on.
async fn stamped(
    sender: &CircleMember,
    group: &GroupId,
    created_at: u64,
    life_secs: u64,
) -> (Event, Packet) {
    let sealed_at = epoch(sender, group).await;
    let inner = helpers::drive::sealed_by(sender, group, LATITUDE).await;
    let event = restamped(
        &inner,
        &ngid(sender, group).await,
        &secret_of(sender, group, sealed_at),
        created_at,
        life_secs,
    );
    let packet = packet_as(sender, group, sealed_at, &event, Format::Bridgeable);
    (event, packet)
}

/// T-BRIDGE-1: a fellow member's update that reached this device by mesh is
/// handed to the circle's relays behind this device's own send — the
/// member's own sealed event, byte for byte, once — and a third member reads
/// it from there as it reads any. No record of it is written. The same
/// update again — in the same packet, in one under a fresh nonce, at later
/// drives — is never passed on a second time.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_fellow_members_update_is_passed_on_to_the_relays_once_byte_for_byte() {
    let (admin, others, group) = split(setup_circle(4, &[ONE, TWO]).await);
    let (sender, far) = (&others[0], &others[2]);
    mesh_on(sender).await;
    let bridger = Bridger::new(&others[1], &group).await;
    let (event, packet) = handed_off(sender, &group).await;
    let sealed_at = epoch(sender, &group).await;

    let taken = bridger.takes_in(vec![packet.clone()]).await;
    assert!(taken.read == [(packet.id(), true)] && taken.from_circles == 1);
    assert!(
        bridger.keeps() == [event.id],
        "a fellow member's update was not kept to be passed on"
    );
    assert!(
        bridger.relays.sent.lock().unwrap().is_empty(),
        "an update was passed on with no send of this device's own"
    );

    let publish = bridger.publishes(true).await;
    let LocationPublish::Sent(Ok(answer)) = &publish else {
        panic!("premise: this device's own send was taken");
    };
    let own = *bridger.own.lock().unwrap().last().expect("sealed");
    assert!(
        answer.event_id == own && answer.accepted_by == [ONE, TWO],
        "the answer is not this device's own send's"
    );
    let all: Vec<EventId> = ids(&bridger.relays.sent.lock().unwrap());
    assert!(
        all == [own, event.id],
        "the update was not sent once, behind this device's own"
    );
    let passed = bridger.passed_on();
    assert!(
        passed.len() == 1 && passed[0].0.as_json() == event.as_json(),
        "what was passed on is not the member's own sealed event, byte for byte"
    );
    assert!(
        passed[0].1 == [ONE, TWO],
        "the update was not handed to the relays that took this device's own send"
    );
    assert!(
        reads(far, &passed[0].0).await && stored_fix(far, &group, sender, LATITUDE).await,
        "a member reading the relay did not take the passed-on update in"
    );
    assert!(
        !is_owned(&event.id)
            && (records_of(bridger.member, &group).await.iter())
                .all(|record| record.event_id != event.id),
        "a record was written for an event this device did not seal"
    );
    assert!(bridger.keeps().is_empty());

    // The same update again, and again under a fresh nonce: a duplicate to
    // the engine, kept by nothing, sent by no later drive.
    let rewrapped = packet_as(sender, &group, sealed_at, &event, Format::Bridgeable);
    assert!(rewrapped.id() != packet.id(), "premise: another packet");
    for again in [packet, rewrapped] {
        bridger.at(wall_ms() + SENDER_GAP_MS);
        assert!(
            bridger.bridges(vec![again]).await.is_empty() && bridger.keeps().is_empty(),
            "an update was passed on a second time"
        );
    }
    drop(admin);
}

/// What one send does not pass on is dropped, and an update a drive held —
/// its wake had ended — is passed on once, by the drive that takes it in.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_update_waits_for_one_send_and_one_held_is_passed_on_when_it_is_taken_in() {
    let (admin, others, group) = split(setup_circle(3, &[ONE]).await);
    let sender = &others[0];
    mesh_on(sender).await;
    let bridger = Bridger::new(&others[1], &group).await;

    // Held: the drive's wake had ended before its ingest.
    let (event, packet) = handed_off(sender, &group).await;
    let relays = WatchedRelays::default();
    let ended = Publishing {
        fanout: &relays,
        publisher: &relays,
        clock: &*bridger.clock,
        deadline_ms: Some(bridger.clock.now_ms() - 1),
        mode: &DriveMode::Full,
    };
    let held = (ended.mesh_drive(&bridger.member.circle, vec![packet])).await;
    assert!(held.read.is_empty() && relays.calls() == 0 && bridger.keeps().is_empty());
    assert!(matches!(
        bridger.publishes(true).await,
        LocationPublish::Sent(Ok(_))
    ));
    assert!(
        bridger.passed_on().is_empty(),
        "an update the engine has not taken in was passed on"
    );
    assert!(
        ids(&bridger.bridges(Vec::new()).await) == [event.id],
        "an update held for a later drive was not passed on when it was taken in"
    );

    // A send whose wake has no room for another: what waited is dropped.
    let (_, packet) = handed_off(sender, &group).await;
    let _ = bridger.takes_in(vec![packet]).await;
    assert_eq!(bridger.keeps().len(), 1);
    bridger.at(wall_ms() + SENDER_GAP_MS + SECOND_MS);
    let own = bridger.seals().await;
    let short = Publishing {
        deadline_ms: Some(bridger.clock.now_ms() + SECOND_MS),
        ..bridger.driver()
    };
    assert!(matches!(
        (short.publish_location_and_bridge(&bridger.member.circle, &own, true)).await,
        LocationPublish::Sent(Ok(_))
    ));
    assert!(
        bridger.passed_on().is_empty() && bridger.keeps().is_empty(),
        "a send was begun for an update the wake could not see through, or it waits still"
    );
    assert!(bridger.bridges(Vec::new()).await.is_empty());

    // An update the engine read and did not keep is held: kept to be passed
    // on by nothing, since its packet is not settled.
    let (_, packet) = handed_off(sender, &group).await;
    (bridger.member.session()).leave_next_mesh_ingest_unkept_for_test();
    let unkept = bridger.takes_in(vec![packet]).await;
    assert!(
        unkept.read.is_empty() && bridger.keeps().is_empty(),
        "an update whose packet is still held was kept to be passed on"
    );
    drop(admin);
}

/// T-BRIDGE-3, 4, 5, and T-SEC-1 at the bridge: nothing is passed on that
/// is not a fellow member's update the engine read for the first time, from
/// packets that all say a member may pass it on — not a mesh-only seal, not
/// an update one packet marked as never passed on, not one a relay had
/// delivered, not this device's own, not a commit a member wrapped, not an
/// event that does not verify.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn nothing_but_a_new_update_marked_for_it_is_ever_passed_on() {
    let (admin, others, group) = split(setup_circle(3, &[ONE]).await);
    let sender = &others[0];
    mesh_on(sender).await;
    let bridger = Bridger::new(&others[1], &group).await;
    let sealed_at = epoch(sender, &group).await;
    let routing = ngid(sender, &group).await;
    let secret = secret_of(sender, &group, sealed_at);
    let mut taken_in = 0;

    // A mesh-only seal: format 0x01 by the sender's own phone.
    let (relays, clock) = (WatchedRelays::default(), ManualClock::at(0));
    let radio = Publishing {
        fanout: &relays,
        publisher: &relays,
        clock: &*clock,
        deadline_ms: None,
        mode: &DriveMode::Full,
    };
    let fix = LocationMessage::new(LATITUDE, -0.12);
    let outcome = (radio.seal_for_mesh(&sender.circle, &group, &fix).await).expect("sealed");
    let LocationSeal::Sealed { event, .. } = outcome.seal else {
        panic!("premise: sealed for the mesh alone");
    };
    let _ = waiting(sender);
    assert!(matches!(
        radio.publish_location(&sender.circle, &event).await,
        LocationPublish::MeshOnly
    ));
    let mesh_only: Vec<Packet> = (waiting(sender).into_iter())
        .filter_map(|(_, packet)| packet)
        .collect();
    assert!(mesh_only.len() == 1, "premise: one packet for the mesh");
    taken_in += bridger.takes_in(mesh_only).await.from_circles;
    assert!(
        taken_in == 1 && bridger.keeps().is_empty(),
        "a location sealed for the mesh alone was kept to be passed on"
    );

    // Sent to relays by its sender, and marked by some member as one never
    // to pass on — alone, before the packet that allows it, and after it.
    let (alone, _) = handed_off(sender, &group).await;
    let (before, allows_before) = handed_off(sender, &group).await;
    let (after, allows_after) = handed_off(sender, &group).await;
    let never = |event: &Event| packet_as(sender, &group, sealed_at, event, Format::NeverBridged);
    let marked = vec![
        never(&alone),
        never(&before),
        allows_before,
        allows_after,
        never(&after),
    ];
    taken_in += bridger.takes_in(marked).await.from_circles;
    assert!(
        taken_in == 4 && bridger.keeps().is_empty(),
        "an update one packet marked as never passed on was kept to be passed on"
    );

    // A relay delivered it first.
    let (relayed, packet) = handed_off(sender, &group).await;
    assert!(
        reads(bridger.member, &relayed).await,
        "premise: read from a relay"
    );
    assert_eq!(bridger.takes_in(vec![packet]).await.from_circles, 0);
    assert!(
        bridger.keeps().is_empty(),
        "an update a relay had delivered was kept to be passed on"
    );

    // This device's own, wrapped again by a member.
    let own = bridger.seals().await;
    let echo = packet_as(sender, &group, sealed_at, &own, Format::Bridgeable);
    assert_eq!(bridger.takes_in(vec![echo]).await.from_circles, 0);
    assert!(
        bridger.keeps().is_empty(),
        "this device's own update was kept to be passed on"
    );

    // A commit a member wrapped as a location, and an event that does not
    // verify: neither reaches the engine.
    let (commit, _pending) = stage_relays(admin.session(), &group, &[ONE, TWO]).await;
    let created = commit.created_at.as_secs();
    let wrapped = restamped(&commit, &routing, &secret, created, 228);
    let (genuine, _) = handed_off(sender, &group).await;
    let mut forged = parts_of(&genuine, Format::Bridgeable).expect("a location");
    forged.sig[9] ^= 0x04;
    let unsealed = vec![
        packet_as(sender, &group, sealed_at, &wrapped, Format::Bridgeable),
        wrap(&MeshKey::derive(&secret), &forged, &mut OsRng).expect("fits"),
    ];
    assert_eq!(bridger.takes_in(unsealed).await.from_circles, 0);
    assert!(
        bridger.keeps().is_empty(),
        "a commit or a forged event was kept to be passed on"
    );

    assert!(
        matches!(
            (bridger.driver())
                .publish_location_and_bridge(&bridger.member.circle, &own, true)
                .await,
            LocationPublish::Sent(Ok(_))
        ) && bridger.passed_on().is_empty(),
        "something that is no new update marked for it was passed on"
    );
}

/// Finding 1 of the design's review, T-BRIDGE-6 and T-BRIDGE-10. A member
/// is removed by a commit that is on the relays and that this device has
/// not fetched; an offline member, who cannot know, goes on sending by
/// mesh. Nothing of that member's is handed to the relays — where the
/// removed member could read it — by a drive whose relay receive did not
/// complete; what was kept goes when a receive begins and when the removal
/// is taken in; and what arrives after it, sealed at the epoch this device
/// has left, is not sent.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_member_removed_by_a_commit_not_yet_fetched_is_never_handed_an_update_by_the_relays() {
    let (admin, others, group) = split(setup_circle(4, &[ONE]).await);
    let (sender, removed) = (&others[0], &others[2]);
    mesh_on(sender).await;
    let bridger = Bridger::new(&others[1], &group).await;
    let removal = (admin.session())
        .remove_members(&group, &[removed.pubkey_hex()])
        .await
        .expect("the admin removes a member");
    let commit = confirmed(&admin, &removal).await;
    let mut never_sent = Vec::new();
    let mut update = async || {
        let (event, packet) = handed_off(sender, &group).await;
        never_sent.push(event.id);
        (event, packet)
    };

    // The drive's receive did not complete: the caller says so.
    let (event, packet) = update().await;
    assert!(
        reads(removed, &event).await,
        "premise: the removed member can still read what the offline member seals"
    );
    let _ = bridger.takes_in(vec![packet]).await;
    assert!(bridger.keeps() == [event.id], "premise: kept");
    assert!(matches!(
        bridger.publishes(false).await,
        LocationPublish::Sent(Ok(_))
    ));
    assert!(
        bridger.passed_on().is_empty() && bridger.keeps().is_empty(),
        "a drive whose receive did not complete passed an update on, or kept it for a later one"
    );

    // A receive begins: what was kept under the last one goes.
    let (event, packet) = update().await;
    let _ = bridger.takes_in(vec![packet]).await;
    assert!(bridger.keeps() == [event.id], "premise: kept");
    (bridger.member.session()).forget_caught_up_for_test(&group);
    assert!(
        bridger.keeps().is_empty(),
        "what was kept under one receive outlived the start of the next"
    );
    // While it runs, and when it fails, nothing is kept and nothing sent —
    // whatever the caller says of it.
    let (_, packet) = update().await;
    assert_eq!(bridger.takes_in(vec![packet]).await.from_circles, 1);
    assert!(
        bridger.keeps().is_empty(),
        "an update was kept before any receive had completed"
    );
    assert!(matches!(
        bridger.publishes(true).await,
        LocationPublish::Sent(Ok(_))
    ));
    assert!(
        bridger.passed_on().is_empty(),
        "a drive whose receive this session never saw complete passed an update on"
    );

    // The receive completes without the commit — the relay had not served
    // it — and then brings it: the epoch moves, and what was kept goes.
    (bridger.member.session()).mark_caught_up_for_test(&group);
    let (event, packet) = update().await;
    let _ = bridger.takes_in(vec![packet]).await;
    assert!(bridger.keeps() == [event.id], "premise: kept");
    (bridger.member.session())
        .process_event_settled_for_test(&commit)
        .await
        .expect("the removal is taken in");
    assert!(
        bridger.keeps().is_empty(),
        "what was kept at an epoch this device has left was not dropped"
    );

    // Sealed at the epoch this device has left, arriving after it: kept —
    // this device still reads it — and never sent.
    let (event, packet) = update().await;
    let _ = bridger.takes_in(vec![packet]).await;
    assert!(
        bridger.keeps() == [event.id],
        "premise: an update of a past epoch is read and kept"
    );
    assert!(matches!(
        bridger.publishes(true).await,
        LocationPublish::Sent(Ok(_))
    ));
    assert!(
        bridger.passed_on().is_empty() && bridger.keeps().is_empty(),
        "an update sealed at an epoch this device has left was passed on"
    );

    let sent = ids(&bridger.relays.sent.lock().unwrap());
    assert!(
        never_sent.iter().all(|id| !sent.contains(id)),
        "the relays were handed an update the removed member can read"
    );
}

/// Q-4 of the design's review, and T-BRIDGE-8: an update is passed on only
/// when this device's own send was taken by a relay, only to the relays that
/// took it — the circle's own, under the circle's spelling — and what the
/// relays answer for it reaches nothing.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_update_is_passed_on_only_to_the_relays_that_took_this_devices_own_send() {
    let (admin, others, group) = split(setup_circle(3, &[ONE, TWO]).await);
    let sender = &others[0];
    mesh_on(sender).await;
    let bridger = Bridger::new(&others[1], &group).await;
    let next = async |bridger: &Bridger<'_>| {
        let (event, packet) = handed_off(sender, &group).await;
        let _ = bridger.takes_in(vec![packet]).await;
        assert!(bridger.keeps() == [event.id], "premise: kept");
        event
    };

    // No relay took this device's own send.
    let _ = next(&bridger).await;
    *bridger.relays.takes.lock().unwrap() = Some(Vec::new());
    assert!(matches!(
        bridger.publishes(true).await,
        LocationPublish::Sent(Err(_))
    ));
    assert!(
        bridger.passed_on().is_empty() && bridger.keeps().is_empty(),
        "an update was passed on, or kept, though no relay took this device's own send"
    );

    // One of two did, reported as a pool reports it — another spelling —
    // beside a relay that is none of the circle's.
    let event = next(&bridger).await;
    *bridger.relays.takes.lock().unwrap() = Some(vec![TWO.to_owned()]);
    bridger.relays.respelled.store(true, Ordering::SeqCst);
    assert!(matches!(
        bridger.publishes(true).await,
        LocationPublish::Sent(Ok(_))
    ));
    let passed = bridger.passed_on();
    assert!(ids(&passed) == [event.id], "premise: passed on");
    assert!(
        passed[0].1 == [TWO],
        "the update was handed to a relay that had not taken this device's own send, to one \
         that is not the circle's, or under another spelling than the circle's"
    );
    *bridger.relays.takes.lock().unwrap() = None;
    bridger.relays.respelled.store(false, Ordering::SeqCst);

    // This device's own send went to the mesh alone, and then was one no
    // record is stored for: neither is a send a relay took.
    let _ = next(&bridger).await;
    let fix = LocationMessage::new(OWN_LATITUDE, 11.5);
    let sealed = (bridger.driver())
        .seal_for_mesh(&bridger.member.circle, &group, &fix)
        .await
        .expect("sealed");
    let LocationSeal::Sealed { event: own, .. } = sealed.seal else {
        panic!("premise: sealed for the mesh alone");
    };
    bridger.own.lock().unwrap().push(own.id);
    for answer in ["mesh-only", "ended"] {
        let publish = (bridger.driver())
            .publish_location_and_bridge(&bridger.member.circle, &own, true)
            .await;
        assert!(match answer {
            "mesh-only" => matches!(publish, LocationPublish::MeshOnly),
            _ => matches!(publish, LocationPublish::Ended),
        });
        assert!(
            bridger.passed_on().is_empty() && bridger.keeps().is_empty(),
            "an update was passed on behind a send no relay was handed"
        );
        let _ = next(&bridger).await;
    }

    // The relays blame this device's clock for the passed-on event: the
    // answer of this device's own send is its own, and the event is not
    // sent again.
    let event = (bridger.member.session()).mesh_bridge_waiting_for_test(&group)[0];
    bridger.at(wall_ms() + SENDER_GAP_MS);
    bridger.relays.blames_clock_from.store(2, Ordering::SeqCst);
    let publish = bridger.publishes(true).await;
    assert!(
        matches!(&publish, LocationPublish::Sent(Ok(own)) if own.accepted_by == [ONE, TWO]),
        "what the relays answered for a passed-on event reached this device's own answer"
    );
    assert!(ids(&bridger.passed_on()) == [event], "premise: handed over");
    bridger
        .relays
        .blames_clock_from
        .store(usize::MAX, Ordering::SeqCst);
    assert!(
        bridger.bridges(Vec::new()).await.is_empty(),
        "an event the relays refused was sent again"
    );
    drop(admin);
}

/// T-BRIDGE-2 and T-BRIDGE-11, on the clock of the drive that sends: an
/// event is passed on up to — and not at — 218 seconds after it was sealed;
/// never when it declares a longer life than a location's 228 seconds, and
/// never when it is stamped further ahead of this device's clock than a send
/// takes. Each is an event any member can stamp as it likes.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_event_is_passed_on_only_inside_the_window_its_own_stamps_give() {
    let (admin, others, group) = split(setup_circle(3, &[ONE]).await);
    let sender = &others[0];
    mesh_on(sender).await;
    let bridger = Bridger::new(&others[1], &group).await;
    // Every stamp is counted from one instant, behind the device's clock,
    // so that this device's own sends — sealed at that clock — are in time
    // wherever the drive's clock is set here.
    let sealed = wall_ms() / SECOND_MS - 100;
    let sealed_ms = sealed * SECOND_MS;

    for (what, created_at, life_secs, drive_at_ms) in [
        ("at 218 seconds", sealed, 228, sealed_ms + 218_000),
        ("long past its life", sealed, 228, sealed_ms + 300_000),
        ("declaring 229 seconds", sealed, 229, sealed_ms + SECOND_MS),
        (
            "declaring a year",
            sealed,
            31_536_000,
            sealed_ms + SECOND_MS,
        ),
        (
            "stamped ahead of the clock",
            sealed + 20,
            228,
            sealed_ms + 20_000 - 10_001,
        ),
    ] {
        let (event, packet) = stamped(sender, &group, created_at, life_secs).await;
        bridger.at(drive_at_ms);
        let _ = bridger.takes_in(vec![packet]).await;
        assert!(bridger.keeps() == [event.id], "premise: kept, {what}");
        assert!(matches!(
            bridger.publishes(true).await,
            LocationPublish::Sent(Ok(_))
        ));
        assert!(
            bridger.passed_on().is_empty() && bridger.keeps().is_empty(),
            "an event was passed on {what}"
        );
    }

    // One millisecond inside each bound, a gap apart.
    for (what, created_at, life_secs, drive_at_ms) in [
        (
            "stamped a send's length ahead",
            sealed + 100,
            228,
            sealed_ms + 100_000 - 10_000,
        ),
        ("just before 218 seconds", sealed, 228, sealed_ms + 217_999),
    ] {
        let (event, packet) = stamped(sender, &group, created_at, life_secs).await;
        bridger.at(drive_at_ms);
        assert!(
            ids(&bridger.bridges(vec![packet]).await) == [event.id],
            "an event in its window was not passed on: {what}"
        );
    }
    drop(admin);
}

/// T-BRIDGE-7: a member who floods the mesh gets the newest of its updates
/// passed on, and then none for 72 seconds of the sending drive's clock.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_flooding_member_gets_its_newest_update_passed_on_once_a_gap() {
    let (admin, others, group) = split(setup_circle(3, &[ONE]).await);
    let sender = &others[0];
    mesh_on(sender).await;
    let bridger = Bridger::new(&others[1], &group).await;
    // Every event is stamped from this one instant, so that how long the
    // test runs decides nothing.
    let start = wall_ms() / SECOND_MS * SECOND_MS;
    bridger.at(start);

    let mut flood = Vec::new();
    for before_secs in [3, 2, 1] {
        flood.push(stamped(sender, &group, start / SECOND_MS - before_secs, 228).await);
    }
    let newest = (flood.iter())
        .map(|(event, _)| (event.created_at, event.id))
        .max()
        .expect("three")
        .1;
    let packets: Vec<Packet> = flood.into_iter().map(|(_, packet)| packet).collect();
    assert_eq!(bridger.takes_in(packets).await.from_circles, 3);
    assert!(
        bridger.keeps() == [newest],
        "more than the newest update of one member was kept to be passed on"
    );
    assert_eq!(ids(&bridger.bridges(Vec::new()).await), [newest]);

    for (after_ms, passes) in [
        (0, false),
        (SENDER_GAP_MS - 1, false),
        (SENDER_GAP_MS, true),
    ] {
        let (event, packet) = stamped(sender, &group, start / SECOND_MS, 228).await;
        bridger.at(start + after_ms);
        let passed = ids(&bridger.bridges(vec![packet]).await);
        assert!(
            passed == if passes { vec![event.id] } else { Vec::new() },
            "{after_ms} ms after one update of a member was passed on, the next was \
             {passed:?}"
        );
        assert!(bridger.keeps().is_empty());
    }
    drop(admin);
}

/// Each update is checked against the engine immediately before its own
/// send: what happens while an earlier one is on its way — a receive begins,
/// fetched input is held unread — stops the ones behind it.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn what_happens_while_one_update_is_sent_stops_the_ones_behind_it() {
    let (admin, others, group) = split(setup_circle(3, &[ONE]).await);
    let peer = &others[0];
    mesh_on(&admin).await;
    mesh_on(peer).await;
    let bridger = Bridger::new(&others[1], &group).await;
    let mut now = wall_ms();

    for unread in [false, true] {
        let mut packets = Vec::new();
        for sender in [&admin, peer] {
            packets.push(handed_off(sender, &group).await.1);
        }
        now += SENDER_GAP_MS;
        bridger.at(now);
        let _ = bridger.takes_in(packets).await;
        assert!(bridger.keeps().len() == 2, "premise: one of each member");
        let (circle, at) = (Arc::clone(&bridger.member.circle), group.clone());
        // Its own send is the first; the first passed on, the second.
        *bridger.relays.during.lock().unwrap() = Some((
            2,
            Box::new(move || {
                if unread {
                    let fetched = EventId::from_byte_array([0x5a; 32]);
                    (circle.session()).hold_pager_commits_for_test(&at, &[fetched]);
                } else {
                    circle.session().forget_caught_up_for_test(&at);
                }
            }),
        ));
        assert!(matches!(
            bridger.publishes(true).await,
            LocationPublish::Sent(Ok(_))
        ));
        assert!(
            bridger.passed_on().len() == 1 && bridger.keeps().is_empty(),
            "an update was passed on after {}",
            if unread {
                "fetched input was held unread"
            } else {
                "a receive of its circle had begun"
            }
        );
        (bridger.member.session()).mark_caught_up_for_test(&group);
    }
}

/// What silences a circle on mesh drops what it kept to pass on: the user
/// stopped sharing, fetched input is held unread, the epoch moved, mesh
/// went off, a leave was asked — after which nothing is kept either — and
/// the circle was disbanded.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn what_silences_a_circle_drops_what_it_kept_to_pass_on() {
    let (admin, others, group) = split(setup_circle(3, &[ONE]).await);
    let sender = &others[0];
    mesh_on(sender).await;
    let bridger = Bridger::new(&others[1], &group).await;
    let session = bridger.member.session();
    let kept = async |bridger: &Bridger<'_>| {
        let (event, packet) = handed_off(sender, &group).await;
        let _ = bridger.takes_in(vec![packet]).await;
        assert!(bridger.keeps() == [event.id], "premise: kept");
    };

    kept(&bridger).await;
    session.mesh_sharing_stopped();
    assert!(
        bridger.keeps().is_empty(),
        "kept though the user stopped sharing"
    );

    let (commit, pending) = stage_relays(admin.session(), &group, &[ONE, TWO]).await;
    (admin.session().confirm_published(pending).await).expect("applied");
    kept(&bridger).await;
    session.hold_pager_commits_for_test(&group, &[commit.id]);
    assert!(
        bridger.keeps().is_empty(),
        "kept though fetched input is held unread"
    );
    for member in [bridger.member, sender] {
        (member
            .session()
            .process_event_settled_for_test(&commit)
            .await)
            .expect("applied");
    }

    kept(&bridger).await;
    let (commit, pending) = stage_relays(admin.session(), &group, &[ONE]).await;
    (admin.session().confirm_published(pending).await).expect("applied");
    (session.process_event_settled_for_test(&commit).await).expect("applied");
    assert!(bridger.keeps().is_empty(), "kept across an epoch change");
    (sender
        .session()
        .process_event_settled_for_test(&commit)
        .await)
        .expect("applied");

    kept(&bridger).await;
    assert!(session.mesh_off().await);
    assert!(bridger.keeps().is_empty(), "kept though mesh went off");
    mesh_on(bridger.member).await;

    kept(&bridger).await;
    let (transport, outbox, clock) = (
        ScriptedFanout::default(),
        Recorder::acking(true),
        ManualClock::at(0),
    );
    transport.answer(ONE, [Answer::Accepted; 8]);
    let _ = through(&transport, &outbox, &clock, &DriveMode::Full)
        .leave(
            &bridger.member.circle,
            &group,
            &bridger.member.keys.public_key(),
        )
        .await
        .expect("the leave is asked");
    assert!(bridger.keeps().is_empty(), "kept though a leave was asked");
    let (_, packet) = handed_off(sender, &group).await;
    let _ = bridger.takes_in(vec![packet]).await;
    assert!(
        bridger.keeps().is_empty(),
        "an update was kept to be passed on for a circle this device asked to leave"
    );
}

/// A disbanded circle keeps nothing to pass on.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_disbanded_circle_keeps_nothing_to_pass_on() {
    let (admin, others, group) = split(setup_circle(3, &[ONE]).await);
    let sender = &others[0];
    mesh_on(sender).await;
    let bridger = Bridger::new(&others[1], &group).await;
    let (event, packet) = handed_off(sender, &group).await;
    let _ = bridger.takes_in(vec![packet]).await;
    assert!(bridger.keeps() == [event.id], "premise: kept");

    let commit = helpers::drive::disband(&admin, &group).await;
    take_in_disband(bridger.member, &group, &commit).await;
    assert!(
        bridger.keeps().is_empty(),
        "a disbanded circle still keeps an update to pass on"
    );
    let (_, packet) = handed_off(sender, &group).await;
    let _ = bridger.takes_in(vec![packet]).await;
    assert!(bridger.keeps().is_empty());
}

/// With mesh off the bridge's entry is the record's own send and nothing
/// else: the one location, to its record's relays, and the same answer.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn with_mesh_off_the_entry_is_a_locations_own_send_and_nothing_more() {
    let (admin, others, group) = split(setup_circle(2, &[ONE, TWO]).await);
    let member = &others[0];
    member.session().mark_caught_up_for_test(&group);
    let bridger = Bridger {
        member,
        group: &group,
        relays: Relays::default(),
        clock: ManualClock::at(0),
        pinned: AtomicBool::new(false),
        own: Mutex::new(Vec::new()),
    };

    let plain = bridger.seals().await;
    let publish = (bridger.driver())
        .publish_location(&member.circle, &plain)
        .await;
    assert!(matches!(publish, LocationPublish::Sent(Ok(_))));
    let second = bridger.seals().await;
    let publish = (bridger.driver())
        .publish_location_and_bridge(&member.circle, &second, true)
        .await;
    assert!(matches!(publish, LocationPublish::Sent(Ok(_))));

    let sent = std::mem::take(&mut *bridger.relays.sent.lock().unwrap());
    assert!(
        sent.len() == 2 && sent[0].0.id == plain.id && sent[1].0.id == second.id,
        "with mesh off the entry sent something beside this device's own location"
    );
    assert!(sent[0].1 == sent[1].1 && sent[1].1 == [ONE, TWO]);
    assert_eq!(bridger.relays.other_calls.load(Ordering::SeqCst), 0);
    assert!(
        (member.session().location_records_for_test(&group).await)
            .expect("the store is read")
            .is_empty(),
        "the entry left a location's record behind"
    );
    drop(admin);
}

/// Passing an update on logs no identifier (Security Rule 15): no circle,
/// member, event, packet or relay.
#[tokio::test]
async fn passing_an_update_on_logs_no_identifier() {
    let (admin, others, group) = split(setup_circle(3, &[ONE]).await);
    let sender = &others[0];
    mesh_on(sender).await;
    let bridger = Bridger::new(&others[1], &group).await;
    let (event, packet) = handed_off(sender, &group).await;
    let (stale, stale_packet) = stamped(sender, &group, wall_ms() / SECOND_MS - 400, 228).await;

    let lines = capture_haven_log_here(async {
        let passed = bridger
            .bridges(vec![packet.clone(), stale_packet.clone()])
            .await;
        assert!(
            ids(&passed) == [event.id],
            "premise: one passed on, one not"
        );
        // And a drive that drops what it kept.
        let (_, packet) = handed_off(sender, &group).await;
        let _ = bridger.takes_in(vec![packet]).await;
        let _ = bridger.publishes(false).await;
    })
    .await;

    let mut needles = vec![
        hex::encode(group.as_slice()),
        hex::encode(ngid(sender, &group).await),
        admin.pubkey_hex(),
        sender.pubkey_hex(),
        bridger.member.pubkey_hex(),
        ONE.trim_start_matches("wss://").to_owned(),
        hex::encode(packet.id().0),
        hex::encode(stale_packet.id().0),
    ];
    for event in [&event, &stale] {
        needles.extend([event.id.to_hex(), event.pubkey.to_hex()]);
    }
    needles.extend(bridger.own.lock().unwrap().iter().map(EventId::to_hex));
    let needles: Vec<&str> = needles.iter().map(String::as_str).collect();
    assert!(!lines.is_empty(), "the capture recorded nothing");
    assert_no_needles(&haven_core_lines(&lines), &needles);
}
