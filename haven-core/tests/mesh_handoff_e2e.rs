//! The publish hand-off to the Bluetooth mesh (plan §5.1; T-SEC-7,
//! T-INDEP-1b).
//!
//! A location's own send leaves one packet for the mesh engine, after its
//! send-time check and before its relay send, and nothing about the relay
//! send changes for it: not its answer, not its timing, not what the relays
//! are sent. What the relay path would not send never reaches the hand-off,
//! and what waits there is withdrawn when the circle falls silent.
//!
//! Real MDK engines over `SQLCipher` stores, a real `MeshEngine` for the
//! drain, and for the wire a loopback relay behind a front that records every
//! frame the product sends it.

#![allow(clippy::unwrap_used, clippy::expect_used)]

mod helpers;

use chrono::Timelike as _;
use haven_core::mesh::engine::{CircleSlot, Config, MeshEngine};
use haven_core::mesh::event::rebuild;
use haven_core::mesh::handoff::{Handoff, Op};
use haven_core::mesh::packet::{cover_packet, open, MeshKey, Packet};
use haven_core::nostr::mls::types::GroupId;
use haven_core::nostr::mls::SessionManager;
use haven_core::relay::fanout::scripted::{Answer, LocationAnswer, ScriptedFanout};
use haven_core::relay::fanout::{
    DriveMode, EvolutionStatus, LeaveStatus, LocationPublish, Publishing, LOCATION_SEND_MS,
};
use haven_core::relay::recording_front::RecordingFront;
use haven_core::relay::scripted_relay::ScriptedRelay;
use haven_core::relay::{RelayError, RelayManager};
use helpers::drive::{epoch, ngid, through, ManualClock, Recorder};
use helpers::mesh::{handed_off, mesh_on, rows, sealed, waiting};
use helpers::stranded::{split, stage_relays};
use helpers::{found_circle, setup_circle, CircleMember};
use nostr::{Event, JsonUtil as _};
use rand::rngs::StdRng;
use rand::SeedableRng;

const ONE: &str = "wss://one.mesh-handoff.example.com";
const TWO: &str = "wss://two.mesh-handoff.example.com";
const FULL: DriveMode = DriveMode::Full;

/// The packets waiting in `member`'s hand-off, leaving the purges.
fn offered(member: &CircleMember) -> Vec<(u32, Packet)> {
    (waiting(member).into_iter())
        .filter_map(|(slot, packet)| Some((slot, packet?)))
        .collect()
}

fn slot_of(member: &CircleMember, group: &GroupId) -> u32 {
    member
        .session()
        .mesh_slot_for_test(group)
        .expect("the circle has a slot")
        .0
}

/// Where the driver's clock must be set for `event` to expire `before_ms`
/// later.
fn before_expiry(event: &Event, before_ms: u64) -> u64 {
    let expires_ms = event.tags.expiration().expect("an expiration").as_secs() * 1_000;
    expires_ms - before_ms - ManualClock::ORIGIN
}

/// What the engine's owner does with a hand-off: every purge and every offer
/// applied, an offer living until its event's own expiration.
fn drain(engine: &mut MeshEngine<StdRng>, handoff: &Handoff, now_ms: u64) {
    for (slot, op) in handoff.take() {
        match op {
            Op::Offer { packet, .. } => engine.offer(slot, packet, u64::MAX, now_ms),
            Op::Purge => engine.purge(slot, now_ms),
        }
    }
}

/// The round trip: a real sealed location, handed off by its own send,
/// drained into a real engine and emitted in its circle's slot, opens under
/// the ring's key of a co-member and rebuilds, with the circle's routing id,
/// into the event byte for byte. A co-member an epoch ahead of the sender
/// reads it under its past key; no key but the epoch's opens it.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_sealed_location_travels_the_hand_off_and_the_engine_and_comes_back_whole() {
    let (admin, others, group) = split(setup_circle(3, &[ONE]).await);
    let (sender, ahead) = (&others[0], &others[1]);
    for device in [&admin, sender, ahead] {
        mesh_on(device).await;
    }
    // The admin and one member move an epoch on; the sender has not seen it.
    let (commit, pending) = stage_relays(admin.session(), &group, &[ONE, TWO]).await;
    (admin.session().confirm_published(pending).await).expect("applied");
    (ahead
        .session()
        .process_event_settled_for_test(&commit)
        .await)
        .expect("applied");
    let sealed_at = epoch(sender, &group).await;
    assert!(
        epoch(ahead, &group).await == sealed_at + 1,
        "premise: one member is an epoch ahead"
    );

    let transport = ScriptedFanout::default();
    let (outbox, clock) = (Recorder::acking(true), ManualClock::at(0));
    let driver = through(&transport, &outbox, &clock, &FULL);
    let event = sealed(&driver, sender, &group).await;
    let _ = waiting(sender);
    let (wraps, handoff) = (
        sender.session().mesh_costs_for_test().1,
        sender.session().mesh_handoff(),
    );
    assert!(matches!(
        driver.publish_location(&sender.circle, &event).await,
        LocationPublish::Sent(Ok(_))
    ));
    assert!(
        sender.session().mesh_costs_for_test().1 == wraps + 1,
        "a location's send sealed more or fewer than one packet for the mesh",
    );
    let sent = transport.location_calls();
    assert!(sent.len() == 1 && sent[0].event.as_json() == event.as_json());

    // The owner's drain, and the engine's next emission slot.
    let config = Config::default();
    let slot_end = config.emit_period_ms + config.emit_jitter_ms;
    let mut engine = MeshEngine::new(config, StdRng::seed_from_u64(11), 0);
    drain(&mut engine, &handoff, 0);
    assert!(engine.stats().outbox == 1 && handoff.take().is_empty());
    engine.advance(slot_end);
    let emitted: Vec<Packet> = (engine.store().ids())
        .filter_map(|id| engine.store().packet(&id))
        .collect();
    let [packet] = &emitted[..] else {
        panic!("the engine emitted more or fewer than the one packet it was handed");
    };
    assert!(
        engine.stats().outbox == 0,
        "the engine still holds a packet it emitted"
    );

    // Under the ring's key, with the routing id the ring recorded for it.
    let routing = ngid(sender, &group).await;
    for (reader, epoch_behind) in [(sender, sealed_at), (&admin, sealed_at), (ahead, sealed_at)] {
        let (circle, under, opened) = (reader.session().mesh_open_for_test(packet))
            .expect("a member of the circle opens the packet");
        assert!(circle == group && under == epoch_behind);
        assert!(
            opened.as_json() == event.as_json(),
            "the event did not come back byte for byte"
        );
    }
    // The same through the table's own row, with no help from the ring.
    let row = rows(ahead, &group)[1];
    assert!(row.0 == sealed_at && row.1 == routing);
    let parts = open(&MeshKey::derive(&row.2), packet).expect("the epoch's key opens it");
    assert!(
        rebuild(&parts, &routing).expect("it verifies").as_json() == event.as_json(),
        "the table's own row did not open the packet as the event"
    );
    // Not the next epoch's key, not another circle's routing id, not an
    // outsider's key.
    assert!(open(&MeshKey::derive(&rows(ahead, &group)[0].2), packet).is_none());
    assert!(rebuild(&parts, &[0x5a; 32]).is_none());
    let outsider = CircleMember::new();
    let _ = found_circle(&outsider, &[], &[TWO]).await;
    mesh_on(&outsider).await;
    assert!(outsider.session().mesh_open_for_test(packet).is_none());
}

/// T-SEC-7: a seal the relay path answers `Superseded`, `Expired` or `Ended`
/// never reaches the hand-off, and seals nothing for the mesh.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_send_the_relay_path_refuses_never_reaches_the_hand_off() {
    let (admin, _others, group) = split(setup_circle(2, &[ONE]).await);
    mesh_on(&admin).await;
    let transport = ScriptedFanout::default();
    let (outbox, clock) = (Recorder::acking(true), ManualClock::at(0));
    let driver = through(&transport, &outbox, &clock, &FULL);
    let (_, _) = handed_off(&admin, &group).await;
    let wraps = admin.session().mesh_costs_for_test().1;
    let untouched = |what: &str| {
        assert!(
            offered(&admin).is_empty() && admin.session().mesh_costs_for_test().1 == wraps,
            "a send answered {what} left a packet for the mesh",
        );
        assert!(
            transport.location_call_count() == 0,
            "premise: no relay was sent it"
        );
    };

    // Superseded: the circle left the epoch the location was sealed at.
    let event = sealed(&driver, &admin, &group).await;
    let (_, pending) = stage_relays(admin.session(), &group, &[ONE, TWO]).await;
    (admin.session().confirm_published(pending).await).expect("applied");
    let _ = waiting(&admin);
    assert!(matches!(
        driver.publish_location(&admin.circle, &event).await,
        LocationPublish::Superseded
    ));
    untouched("Superseded");

    // Superseded: a commit of this device's is staged.
    let event = sealed(&driver, &admin, &group).await;
    let (_, pending) = stage_relays(admin.session(), &group, &[ONE]).await;
    assert!(matches!(
        driver.publish_location(&admin.circle, &event).await,
        LocationPublish::Superseded
    ));
    untouched("Superseded");
    (admin.session().publish_failed(pending).await).expect("rolled back");

    // Expired: a send begun now could not end before the event does.
    let event = sealed(&driver, &admin, &group).await;
    clock.set(before_expiry(&event, LOCATION_SEND_MS));
    assert!(matches!(
        driver.publish_location(&admin.circle, &event).await,
        LocationPublish::Expired
    ));
    untouched("Expired");
    clock.set(0);

    // Ended: its one send was already made.
    let event = sealed(&driver, &admin, &group).await;
    assert!(matches!(
        driver.publish_location(&admin.circle, &event).await,
        LocationPublish::Sent(Ok(_))
    ));
    let _ = (waiting(&admin), transport.location_calls());
    let wraps = admin.session().mesh_costs_for_test().1;
    assert!(matches!(
        driver.publish_location(&admin.circle, &event).await,
        LocationPublish::Ended
    ));
    assert!(offered(&admin).is_empty() && admin.session().mesh_costs_for_test().1 == wraps);
    assert!(
        transport.location_call_count() == 0,
        "a send that had ended was handed to a relay"
    );
}

/// What silences `device`'s circle; `admin` is the circle's admin, which
/// `device` may be.
type Silence = for<'a> fn(
    &'a CircleMember,
    &'a CircleMember,
    &'a GroupId,
) -> futures::future::BoxFuture<'a, ()>;

/// Each way a circle falls silent on mesh, and whether the circle's admin is
/// the device it is tried on.
fn silences() -> [(&'static str, bool, Silence); 10] {
    [
        ("a leave", false, |member, _, group| {
            Box::pin(async move {
                let transport = ScriptedFanout::default();
                transport.answer(ONE, [Answer::Silent]);
                let (outbox, clock) = (Recorder::acking(true), ManualClock::at(0));
                let left = through(&transport, &outbox, &clock, &FULL)
                    .leave(&member.circle, group, &member.keys.public_key())
                    .await
                    .expect("the leave is accepted");
                assert!(left.status == LeaveStatus::Proposed, "premise: proposed");
            })
        }),
        (
            "a leave asked for that cannot be proposed yet",
            true,
            |admin, _, group| {
                Box::pin(async move {
                    // The circle's only admin, in a drive that makes no commit:
                    // the intent is marked and nothing is staged or recorded.
                    let transport = ScriptedFanout::default();
                    let (outbox, clock) = (Recorder::acking(true), ManualClock::at(0));
                    let left = through(&transport, &outbox, &clock, &DriveMode::FinishOnly)
                        .leave(&admin.circle, group, &admin.keys.public_key())
                        .await;
                    assert!(
                        left.is_err() && transport.calls().is_empty() && outbox.handed().is_empty(),
                        "premise: the leave was asked for and nothing was made of it",
                    );
                })
            },
        ),
        ("sharing turned off", false, |member, _, _| {
            Box::pin(async move { member.session().mesh_sharing_stopped() })
        }),
        (
            "an epoch change of this device's making",
            true,
            |admin, _, group| {
                Box::pin(async move {
                    let (_, pending) = stage_relays(admin.session(), group, &[ONE, TWO]).await;
                    (admin.session().confirm_published(pending).await).expect("applied");
                })
            },
        ),
        (
            "an epoch change another member made",
            false,
            |member, admin, group| {
                Box::pin(async move {
                    let (commit, pending) = stage_relays(admin.session(), group, &[ONE, TWO]).await;
                    (admin.session().confirm_published(pending).await).expect("applied");
                    (member
                        .session()
                        .process_event_settled_for_test(&commit)
                        .await)
                        .expect("applied");
                })
            },
        ),
        ("a commit staged for the relays", true, |admin, _, group| {
            Box::pin(async move {
                let transport = ScriptedFanout::default();
                transport.answer(ONE, [Answer::Silent]);
                let (outbox, clock) = (Recorder::acking(true), ManualClock::at(0));
                let staged = through(&transport, &outbox, &clock, &FULL)
                    .update_relays(&admin.circle, group, &[ONE.to_string(), TWO.to_string()])
                    .await
                    .expect("the change is staged");
                assert!(
                    staged.status == EvolutionStatus::Unresolved,
                    "premise: awaiting relays"
                );
            })
        }),
        ("a fetched commit held unread", false, |member, _, group| {
            Box::pin(async move {
                (member.session())
                    .hold_pager_commits_for_test(group, &[nostr::EventId::all_zeros()]);
            })
        }),
        (
            "stored replay a live REQ holds",
            false,
            |member, _, group| {
                Box::pin(async move { member.session().hold_live_replay_for_test(group) })
            },
        ),
        ("the circle's end", false, |member, _, group| {
            Box::pin(async move {
                (member.circle.complete_leave(group, 1_800_000_000).await).expect("left");
            })
        }),
        ("mesh turned off", false, |member, _, _| {
            Box::pin(async move { assert!(member.session().mesh_off().await) })
        }),
    ]
}

/// T-SEC-7: leave, sharing-off, an epoch change, a hold and mesh-off each
/// empty the circle's slot — the packet waiting in the hand-off goes, and one
/// the engine already holds is purged before its next emission.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_circle_that_falls_silent_has_its_slot_emptied() {
    for (what, by_admin, silence) in silences() {
        let (admin, others, group) = split(setup_circle(2, &[ONE]).await);
        let device = if by_admin { &admin } else { &others[0] };
        let other = found_circle(device, &[], &[TWO]).await;
        mesh_on(device).await;
        let (slot, other_slot) = (slot_of(device, &group), slot_of(device, &other));
        let handoff = device.session().mesh_handoff();
        let config = Config::default();
        let slot_end = config.emit_period_ms + config.emit_jitter_ms;
        let mut engine = MeshEngine::new(config, StdRng::seed_from_u64(3), 0);
        let put = |packet: &Packet| handoff.offer(CircleSlot(slot), packet.clone(), u64::MAX);

        // One packet the engine already holds, one still in the hand-off.
        let (_, held) = handed_off(device, &group).await;
        put(&held);
        drain(&mut engine, &handoff, 0);
        let (_, waits) = handed_off(device, &group).await;
        put(&waits);
        assert!(
            engine.stats().outbox == 1,
            "premise: the engine holds the circle's packet"
        );

        silence(device, &admin, &group).await;

        let left: Vec<(u32, Option<Packet>)> = (handoff.take().into_iter())
            .map(|(slot, op)| match op {
                Op::Offer { packet, .. } => (slot.0, Some(packet)),
                Op::Purge => (slot.0, None),
            })
            .collect();
        assert!(
            left.contains(&(slot, None)) && left.iter().all(|(_, packet)| packet.is_none()),
            "{what} left the circle's packet waiting for the mesh",
        );
        // Only sharing-off and mesh-off are every circle's.
        let whole_device = matches!(what, "sharing turned off" | "mesh turned off");
        assert!(
            left.contains(&(other_slot, None)) == whole_device,
            "{what} emptied another circle's slot, or left it full",
        );

        // The owner applies what it took: the engine's own copy goes before
        // its next emission.
        for (slot, _) in left {
            engine.purge(CircleSlot(slot), 0);
        }
        engine.advance(slot_end);
        assert!(
            engine.stats().outbox == 0
                && !engine.store().holds(&held.id())
                && !engine.store().holds(&waits.id()),
            "{what} did not keep the circle's packet from the engine's next emission",
        );
    }
}

/// T-INDEP-1b: `publish_location` answers the same, and takes no virtual
/// time more, whatever becomes of the hand-off: mesh off, mesh on, the
/// hand-off full and never drained, dropped by its owner, and the key ring's
/// lock held by another thread for the whole call.
#[tokio::test(flavor = "current_thread", start_paused = true)]
async fn a_location_send_answers_the_same_whatever_becomes_of_the_hand_off() {
    enum Mesh {
        Off,
        On,
        Full,
        Dropped,
        RingHeld,
    }
    for answer in [LocationAnswer::Accepted, LocationAnswer::Unanswered] {
        let mut seen = Vec::new();
        for mesh in [
            Mesh::Off,
            Mesh::On,
            Mesh::Full,
            Mesh::Dropped,
            Mesh::RingHeld,
        ] {
            let (admin, _others, group) = split(setup_circle(2, &[ONE, TWO]).await);
            if !matches!(mesh, Mesh::Off) {
                mesh_on(&admin).await;
            }
            let transport = ScriptedFanout::default();
            transport.answer_locations(answer);
            let (outbox, clock) = (Recorder::acking(true), ManualClock::at(0));
            let driver = through(&transport, &outbox, &clock, &FULL);
            let event = sealed(&driver, &admin, &group).await;
            let handoff = admin.session().mesh_handoff();
            let _ = handoff.take();
            let mut rng = StdRng::seed_from_u64(5);
            match mesh {
                Mesh::Full => {
                    for slot in 0..Handoff::SLOTS {
                        handoff.offer(CircleSlot(slot), cover_packet(&mut rng), u64::MAX);
                    }
                }
                Mesh::Dropped => drop(handoff),
                _ => {}
            }

            // Another thread holds the ring's lock from before the call until
            // it is told the call has returned — or, so that a send that waits
            // for it fails here rather than hangs, until a watchdog lets go.
            let (locked, returned) = (std::sync::mpsc::channel(), std::sync::mpsc::channel::<()>());
            let holder = matches!(mesh, Mesh::RingHeld).then(|| {
                let circle = std::sync::Arc::clone(&admin.circle);
                let holder = std::thread::spawn(move || {
                    let _held = circle.session().hold_mesh_ring_for_test();
                    locked.0.send(()).expect("the test waits");
                    (returned.1.recv_timeout(std::time::Duration::from_mins(1))).is_ok()
                });
                locked.1.recv().expect("the ring's lock is held");
                holder
            });
            let wraps = admin.session().mesh_costs_for_test().1;
            let before = tokio::time::Instant::now();
            let sent = driver.publish_location(&admin.circle, &event).await;
            let _ = returned.0.send(());
            if let Some(holder) = holder {
                assert!(
                    holder.join().expect("the holder ends"),
                    "a location's send waited for the key ring's lock",
                );
            }
            assert!(
                tokio::time::Instant::now() == before,
                "a location's send took virtual time for the mesh",
            );

            let calls = transport.location_calls();
            assert!(
                calls.len() == 1 && calls[0].event.as_json() == event.as_json(),
                "the relays were not handed the sealed event once",
            );
            let handed = offered(&admin);
            let slot = admin
                .session()
                .mesh_slot_for_test(&group)
                .map(|slot| slot.0);
            let wrapped = admin.session().mesh_costs_for_test().1 - wraps;
            match mesh {
                Mesh::Off => assert!(handed.is_empty() && slot.is_none() && wrapped == 0),
                Mesh::RingHeld => assert!(
                    handed.is_empty() && wrapped == 0,
                    "a send that found the ring's lock held waited for it, or offered anyway",
                ),
                Mesh::Full => assert!(handed.len() == Handoff::SLOTS as usize && wrapped == 1),
                Mesh::On | Mesh::Dropped => assert!(handed.len() == 1 && wrapped == 1),
            }
            seen.push(match sent {
                LocationPublish::Sent(Ok(result)) => {
                    (true, result.accepted_by, calls[0].targets.clone())
                }
                LocationPublish::Sent(Err(RelayError::AllRelaysFailed)) => {
                    (false, Vec::new(), calls[0].targets.clone())
                }
                _ => panic!("the send was not made"),
            });
        }
        assert!(
            seen.iter().all(|outcome| *outcome == seen[0])
                && seen[0].0 == (answer == LocationAnswer::Accepted)
                && seen[0].2 == [ONE, TWO],
            "a location's send answered differently for what became of the hand-off",
        );
    }
}

/// T-INDEP-1b on the wire: with mesh on, a relay is sent what it is sent
/// with mesh off — the same frames, in the same order, on as many
/// connections.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_relay_is_sent_the_same_frames_with_mesh_on_and_off() {
    /// One frame as a relay can tell it from another: its verb, and for an
    /// event its kind, its tag names, how long it lives and how long its
    /// content is.
    type Shape = (String, Option<(u64, Vec<String>, u64, usize)>);
    fn shape(text: &str) -> Shape {
        let frame: serde_json::Value = serde_json::from_str(text).expect("a JSON frame");
        let verb = frame[0].as_str().expect("a verb").to_owned();
        let event = serde_json::from_value::<Event>(frame[1].clone())
            .ok()
            .map(|event| {
                let expires = event.tags.expiration().expect("an expiration").as_secs();
                (
                    u64::from(event.kind.as_u16()),
                    event
                        .tags
                        .iter()
                        .map(|tag| tag.as_slice()[0].clone())
                        .collect(),
                    expires - event.created_at.as_secs(),
                    event.content.len(),
                )
            });
        (verb, event)
    }

    let mut wires = Vec::new();
    for mesh in [false, true] {
        let relay = ScriptedRelay::start();
        let front = RecordingFront::start(relay.url());
        let (admin, _others, group) = split(setup_circle(2, &[front.url()]).await);
        if mesh {
            mesh_on(&admin).await;
        }
        let pool = RelayManager::new();
        let transport = pool.fanout_transport();
        let (outbox, clock) = (Recorder::acking(true), ManualClock::at(0));
        let driver = Publishing {
            fanout: &transport,
            publisher: &outbox,
            clock: &*clock,
            deadline_ms: None,
            mode: &FULL,
        };
        for _ in 0..2 {
            // To the whole second: a location's JSON is as long as the
            // digits of its instants, and whether those end in zeros is
            // chance, not something a relay is sent for mesh being on.
            let mut fix = haven_core::location::LocationMessage::new(51.5, -0.12);
            for instant in [&mut fix.timestamp, &mut fix.expires_at] {
                *instant = instant.with_nanosecond(0).expect("a whole second");
            }
            let outcome = driver
                .seal_location(&admin.circle, &group, &fix)
                .await
                .expect("the seal runs");
            let haven_core::relay::fanout::LocationSeal::Sealed { event, .. } = outcome.seal else {
                panic!("premise: the send is sealed");
            };
            assert!(matches!(
                driver.publish_location(&admin.circle, &event).await,
                LocationPublish::Sent(Ok(_))
            ));
        }
        assert!(
            offered(&admin).len() == usize::from(mesh),
            "premise: mesh is on, or off"
        );
        assert!(
            relay.published().len() == 2,
            "premise: the relay took both locations"
        );
        let frames: Vec<_> = front
            .frames()
            .iter()
            .map(|frame| (frame.conn, shape(&frame.text)))
            .collect();
        wires.push((front.connections(), frames));
    }
    assert!(
        wires[0] == wires[1]
            && wires[0]
                .1
                .iter()
                .filter(|(_, (verb, _))| verb == "EVENT")
                .count()
                == 2,
        "a relay was sent something else with mesh on than with mesh off",
    );
}

/// What the hand-off costs, counted: a batch and a send that find the engine
/// where the ring has it derive no key and write no row, and a send seals
/// exactly one packet.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_unchanged_circle_costs_no_derivation_and_no_write_and_a_send_one_seal() {
    let (admin, others, group) = split(setup_circle(2, &[ONE]).await);
    let member = &others[0];
    mesh_on(&admin).await;
    mesh_on(member).await;
    let (_, pending) = stage_relays(admin.session(), &group, &[ONE, TWO]).await;
    (admin.session().confirm_published(pending).await).expect("applied");
    let kept = rows(&admin, &group);
    let (derived, wrapped, written) = admin.session().mesh_costs_for_test();

    // Engine batches that move no epoch: a peer's location taken in, a
    // drain, and every circle's key brought in line again.
    for _ in 0..3 {
        let (_, _) = handed_off(member, &group).await;
        let fix = helpers::drive::sealed_by(member, &group, 12.5).await;
        assert!(
            helpers::drive::reads(&admin, &fix).await,
            "premise: the fix is taken in"
        );
        let _ = admin.session().drain().await;
    }
    assert!(
        admin.session().mesh_costs_for_test() == (derived, wrapped, written)
            && rows(&admin, &group) == kept,
        "an engine batch that changed no key derived one or wrote a row",
    );

    // Sends: one seal each, and still nothing derived or written.
    for sent in 1..=3 {
        let (_, _) = handed_off(&admin, &group).await;
        assert!(
            admin.session().mesh_costs_for_test() == (derived, wrapped + sent, written),
            "a send derived a key, wrote a row, or sealed other than one packet",
        );
    }

    // The same with more circles keyed: a send touches its own circle's key
    // and slot and no other's. (An allocation count would need a counting
    // global allocator, which is `unsafe`; what is counted is what would
    // grow with the circles if the hand-off walked them.)
    for _ in 0..6 {
        let _ = found_circle(&admin, &[], &[TWO]).await;
    }
    mesh_on(&admin).await;
    let (derived, wrapped, written) = admin.session().mesh_costs_for_test();
    let _ = waiting(&admin);
    let (_, _) = handed_off(&admin, &group).await;
    assert!(
        admin.session().mesh_costs_for_test() == (derived, wrapped + 1, written),
        "with more circles keyed a send derived a key, wrote a row, or sealed more than once",
    );
    assert!(rows(&admin, &group) == kept, "a send changed a stored key");
}

/// A circle made while mesh is on has no key from the batch that founded it
/// — its row is saved after — so its first send installs one. That send
/// writes no row: the relay send behind it waits on no store. The next engine
/// batch, of any kind, saves it.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_send_installs_a_missed_key_in_memory_and_the_next_batch_saves_it() {
    let admin = CircleMember::new();
    mesh_on(&admin).await;
    let group = found_circle(&admin, &[], &[ONE]).await;
    assert!(
        admin.session().mesh_key_epochs_for_test(&group).is_empty()
            && rows(&admin, &group).is_empty(),
        "premise: the circle has no key yet",
    );

    let written = admin.session().mesh_costs_for_test().2;
    let (event, packet) = handed_off(&admin, &group).await;
    let at = epoch(&admin, &group).await;
    assert!(
        (admin.session().mesh_open_for_test(&packet)).is_some_and(|(circle, under, opened)| {
            circle == group && under == at && opened.as_json() == event.as_json()
        }),
        "the circle's first send was not wrapped under the key of its epoch",
    );
    assert!(
        rows(&admin, &group).is_empty() && admin.session().mesh_costs_for_test().2 == written,
        "a location's send wrote the key it installed to the store",
    );

    let _ = admin.session().drain().await;
    assert!(
        rows(&admin, &group).len() == 1 && rows(&admin, &group)[0].0 == at,
        "the key a send installed was not saved by the next engine batch",
    );
}

/// What silences a circle inside a send's hold, after its check.
type MidCheck = Box<dyn FnOnce(&SessionManager) + Send>;

/// A circle is silenced with no engine hold — sharing stopped, a leave
/// asked, fetched input held. One silenced after a send's check began and
/// before the send's key sync read the circle's turn is handed nothing by
/// that send: the location was sealed before the circle fell silent. The
/// relay send is made all the same.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_circle_silenced_while_a_send_checked_is_handed_nothing_by_that_send() {
    let (admin, _others, group) = split(setup_circle(2, &[ONE]).await);
    mesh_on(&admin).await;
    let transport = ScriptedFanout::default();
    let (outbox, clock) = (Recorder::acking(true), ManualClock::at(0));
    let driver = through(&transport, &outbox, &clock, &FULL);
    let held = group.clone();
    let silences: [(MidCheck, usize); 3] = [
        // Nothing falls silent: the send is handed off.
        (Box::new(|_| {}), 1),
        (Box::new(SessionManager::mesh_sharing_stopped), 0),
        (
            Box::new(move |session| session.hold_pager_commits_for_test(&held, &[])),
            0,
        ),
    ];
    for (silence, handed_off) in silences {
        let event = sealed(&driver, &admin, &group).await;
        let _ = waiting(&admin);
        admin.session().after_send_check_for_test(silence);
        assert!(matches!(
            driver.publish_location(&admin.circle, &event).await,
            LocationPublish::Sent(Ok(_))
        ));
        assert!(
            offered(&admin).len() == handed_off,
            "a send handed the mesh a location of a circle silenced while it checked, or \
             handed it nothing with no circle silenced"
        );
    }
}
