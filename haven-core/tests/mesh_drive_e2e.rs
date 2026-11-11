//! `Publishing::mesh_drive`: what the Bluetooth mesh brings in (plan §4.3,
//! §5.2, §7.5; T-SEC-1, T-SEC-2, T-SEC-5, T-PERF-2, T-STAT-1, T-BG-3,
//! T-INDEP-3).
//!
//! A packet reaches the engine only as a verified application message of the
//! very epoch whose key opened it; what it carries is stored by the one site
//! the relay planes store through; a drive calls no relay, whatever the
//! engine hands back; and what cannot be taken in is held, a bounded number
//! for each circle.
//!
//! Real MDK engines over `SQLCipher` stores, the real hand-off, and for the
//! radio the simulator's world of real mesh engines. Every drive here runs
//! through a transport that counts each call of every kind, and fails the
//! test if one was made.

#![allow(clippy::unwrap_used, clippy::expect_used)]

mod helpers;
#[allow(dead_code)]
#[path = "mesh_sim/world.rs"]
mod world;

use std::future::Future;
use std::pin::Pin;
use std::sync::atomic::{AtomicUsize, Ordering};

use base64::engine::general_purpose::STANDARD as BASE64;
use base64::Engine as _;
use chacha20poly1305::aead::{Aead, KeyInit};
use chacha20poly1305::{ChaCha20Poly1305, Key, Nonce};
use haven_core::circle::LastKnownLocation;
use haven_core::mesh::engine::{CircleSlot, Config};
use haven_core::mesh::event::parts_of;
use haven_core::mesh::packet::{cover_packet, wrap, Format, MeshKey, Packet, PacketId};
use haven_core::nostr::mls::types::IngestOutcome;
use haven_core::nostr::mls::types::{GroupId, LocationMessageResult, TransportMessage};
use haven_core::nostr::mls::MeshDrive;
use haven_core::relay::fanout::scripted::ScriptedFanout;
use haven_core::relay::fanout::{
    DriveMode, FanoutSend, FanoutTargetOutcome, Publishing, Taken, UnrecordedPublisher,
};
use haven_core::relay::{PublishResult, RelayResult};
use helpers::drive::{
    arrived_at, epoch, follows_the_eviction, has_fix, ngid, reads, roster, sealed_by, staged_ref,
    stored_fix, wait_out_the_engine, ManualClock, HOUR_MS,
};
use helpers::mesh::{handed_off, mesh_on, row_count, rows, wall_ms};
use helpers::stranded::{
    answer, confirm_and_die, held, latitude_of, parks, split, stage_relays, staged,
};
use helpers::{
    assert_no_needles, capture_haven_log_here, found_circle, haven_core_lines, setup_circle,
    CircleMember,
};
use nostr::{Event, EventBuilder, Keys, Kind, Tag};
use rand::rngs::OsRng;
use rand::RngCore as _;

const ONE: &str = "wss://one.mesh-drive.example.com";
const TWO: &str = "wss://two.mesh-drive.example.com";
/// Where [`handed_off`] seals its location.
const LATITUDE: f64 = 51.5;

/// Relays that take everything, behind a count of every call made to them:
/// a relay taken, a record's event sent, a location sent, an event with no
/// record published.
#[derive(Default)]
struct Relays {
    calls: AtomicUsize,
    inner: ScriptedFanout,
}

#[async_trait::async_trait]
impl FanoutSend for Relays {
    async fn take(&self, target: &str) -> Option<Taken> {
        self.calls.fetch_add(1, Ordering::SeqCst);
        self.inner.take(target).await
    }

    async fn publish(
        &self,
        target: &str,
        message: &TransportMessage,
        taken: Taken,
    ) -> FanoutTargetOutcome {
        self.calls.fetch_add(1, Ordering::SeqCst);
        self.inner.publish(target, message, taken).await
    }

    async fn publish_location(
        &self,
        event: &Event,
        targets: &[String],
    ) -> RelayResult<PublishResult> {
        self.calls.fetch_add(1, Ordering::SeqCst);
        self.inner.publish_location(event, targets).await
    }
}

impl UnrecordedPublisher for Relays {
    fn publish_unrecorded<'a>(
        &'a self,
        _event: &'a Event,
        _relays: &'a [String],
    ) -> Pin<Box<dyn Future<Output = bool> + Send + 'a>> {
        self.calls.fetch_add(1, Ordering::SeqCst);
        Box::pin(async { true })
    }
}

/// One drive of `member`'s mesh with `taken`, asked by a claimed foreground
/// — the mode in which a drive of the relay path may do anything — with no
/// end to its wake. Fails if the drive called a relay in any way.
async fn drive(member: &CircleMember, taken: Vec<Packet>) -> MeshDrive {
    let (relays, clock) = (Relays::default(), ManualClock::at(0));
    let driver = Publishing {
        fanout: &relays,
        publisher: &relays,
        clock: &*clock,
        deadline_ms: None,
        mode: &DriveMode::Full,
    };
    let drive = driver.mesh_drive(&member.circle, taken).await;
    assert!(
        relays.calls.load(Ordering::SeqCst) == 0,
        "a mesh drive called a relay"
    );
    drive
}

/// The exporter secret `member` stores for `group` at `epoch`.
fn secret_of(member: &CircleMember, group: &GroupId, epoch: u64) -> [u8; 32] {
    (rows(member, group).iter())
        .find(|row| row.0 == epoch)
        .expect("the member holds a key of that epoch")
        .2
}

/// `event` in a packet under the circle's key of `epoch`, with a nonce of
/// its own: what any member holding that key can make.
fn packet_under(member: &CircleMember, group: &GroupId, epoch: u64, event: &Event) -> Packet {
    let key = MeshKey::derive(&secret_of(member, group, epoch));
    let parts = parts_of(event, Format::Bridgeable).expect("an event a packet carries");
    wrap(&key, &parts, &mut OsRng).expect("fits")
}

/// What a member can make of any `kind:445` of its circle: the MLS message
/// `event` carries under the exporter secret `sealed`, sealed again under
/// `under`, in an event of the two tags a packet carries, signed by a key of
/// its own. It verifies, and peels under `under`.
fn disguised(event: &Event, routing: &[u8; 32], sealed: &[u8; 32], under: &[u8; 32]) -> Event {
    let content = BASE64.decode(&event.content).expect("base64");
    let (nonce, ciphertext) = content.split_at(12);
    let mls = ChaCha20Poly1305::new(Key::from_slice(sealed))
        .decrypt(Nonce::from_slice(nonce), ciphertext)
        .expect("the secret it was sealed under opens it");
    let mut content = [0_u8; 12].to_vec();
    OsRng.fill_bytes(&mut content);
    let ciphertext = ChaCha20Poly1305::new(Key::from_slice(under))
        .encrypt(Nonce::from_slice(&content), mls.as_slice())
        .expect("sealed");
    content.extend(ciphertext);
    let tag = |tag: [&str; 2]| Tag::parse(tag).expect("a tag");
    EventBuilder::new(Kind::Custom(445), BASE64.encode(content))
        .tags([
            tag(["h", &hex::encode(routing)]),
            tag([
                "expiration",
                &(event.created_at.as_secs() + 228).to_string(),
            ]),
        ])
        .custom_created_at(event.created_at)
        .sign_with_keys(&Keys::generate())
        .expect("signed")
}

/// `event`, a commit or a proposal of `group`, as a member can hand it to the
/// mesh. `[sealed, outer, key]` are epochs: the one whose secret `event` is
/// sealed under, the one whose secret it is sealed under again
/// ([`disguised`]), and the one whose key the packet is put under.
async fn smuggled(
    member: &CircleMember,
    group: &GroupId,
    event: &Event,
    [sealed, outer, key]: [u64; 3],
) -> Packet {
    let event = disguised(
        event,
        &ngid(member, group).await,
        &secret_of(member, group, sealed),
        &secret_of(member, group, outer),
    );
    packet_under(member, group, key, &event)
}

/// How many events `member`'s mesh drives handed its engine so far.
fn ingests(member: &CircleMember) -> usize {
    member.session().mesh_reads_for_test().1
}

/// `member`'s four counts: both totals, then both since mesh was turned on.
fn counts(member: &CircleMember) -> [u64; 4] {
    let counts = member.circle.mesh_counts().expect("the counts are read");
    [
        counts.from_circles_total,
        counts.passed_on_total,
        counts.from_circles_since_on,
        counts.passed_on_since_on,
    ]
}

/// The last-known rows `member` keeps for `group`, without the instant each
/// was written.
async fn stored(member: &CircleMember, group: &GroupId) -> Vec<LastKnownLocation> {
    let id = ngid(member, group).await;
    let mut rows = member
        .circle
        .snapshot_last_known_for_circle(&id, chrono::Utc::now().timestamp())
        .expect("the store is read");
    for row in &mut rows {
        row.updated_at = 0;
    }
    rows
}

fn locations(results: &[LocationMessageResult]) -> usize {
    (results.iter())
        .filter(|result| matches!(result, LocationMessageResult::Location { .. }))
        .count()
}

/// The packets a drive settled, with the verdict of each, in an order of
/// their own.
fn settled(drive: &MeshDrive) -> Vec<(PacketId, bool)> {
    let mut read = drive.read.clone();
    read.sort_unstable();
    read
}

fn sorted(mut read: Vec<(PacketId, bool)>) -> Vec<(PacketId, bool)> {
    read.sort_unstable();
    read
}

/// A location one member sent, wrapped by its own send's hand-off, is taken
/// in by another through a mesh drive and stored exactly as the copy a third
/// took from a relay is. The same update a second time, in the same packet
/// or in one under a fresh nonce, or after a relay delivered it, is stored
/// once; it is counted once where the mesh brought it first, and not at all
/// where a relay did.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_location_arrives_by_mesh_stored_as_a_relayed_one_is_and_counted_once() {
    let (admin, others, group) = split(setup_circle(4, &[ONE]).await);
    let (sender, by_mesh, by_relay) = (&others[0], &others[1], &others[2]);
    for device in [&admin, sender, by_mesh, by_relay] {
        mesh_on(device).await;
    }
    let (event, packet) = handed_off(sender, &group).await;
    let sealed_at = epoch(sender, &group).await;

    assert!(
        reads(by_relay, &event).await,
        "premise: a relay's copy is read"
    );
    let taken = drive(by_mesh, vec![packet.clone()]).await;
    assert!(
        taken.read == [(packet.id(), true)] && !taken.errored,
        "a packet of this device's circle was not read"
    );
    assert!(
        has_fix(&taken.replayed, sender, LATITUDE) && locations(&taken.replayed) == 1,
        "the drive did not hand back the one location it took in"
    );
    assert!(stored_fix(by_mesh, &group, sender, LATITUDE).await);
    assert!(
        stored(by_mesh, &group).await == stored(by_relay, &group).await,
        "a location that came by mesh is stored otherwise than the same one from a relay"
    );
    assert!(
        arrived_at(by_mesh, &group).await.is_some(),
        "a location that came by mesh did not stamp its circle's arrival"
    );
    assert!(taken.from_circles == 1 && counts(by_mesh) == [1, 0, 1, 0]);

    // The same packet again, then the same event under a fresh nonce.
    let again = drive(by_mesh, vec![packet.clone()]).await;
    let rewrapped = packet_under(sender, &group, sealed_at, &event);
    assert!(rewrapped.id() != packet.id(), "premise: another packet");
    let other = drive(by_mesh, vec![rewrapped.clone()]).await;
    assert!(again.read == [(packet.id(), true)] && other.read == [(rewrapped.id(), true)]);
    assert!(
        locations(&again.replayed) + locations(&other.replayed) == 0,
        "an update the engine holds was handed back again"
    );
    assert!(
        again.from_circles + other.from_circles == 0 && counts(by_mesh) == [1, 0, 1, 0],
        "an update was counted more than once"
    );
    assert_eq!(stored(by_mesh, &group).await.len(), 1);

    // After a relay delivered it: both packets of it in one drive.
    let late = drive(by_relay, vec![packet.clone(), rewrapped.clone()]).await;
    assert!(settled(&late) == sorted(vec![(packet.id(), true), (rewrapped.id(), true)]));
    assert!(
        locations(&late.replayed) == 0 && stored(by_relay, &group).await.len() == 1,
        "a copy a relay delivered first was stored or handed back again"
    );
    assert!(
        late.from_circles == 0 && counts(by_relay) == [0; 4],
        "an update a relay delivered first was counted as one the mesh brought"
    );
}

/// T-SEC-1, and what is not this device's: a packet whose event does not
/// verify under the routing id of the key that opened it — a signature that
/// is not the event's, an event of another circle — is read and dropped
/// before the engine; a cover packet and one under a key this device does
/// not hold are not read. None is counted, and the engine sees none.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_packet_that_carries_no_authentic_event_of_its_keys_circle_never_reaches_the_engine() {
    let (admin, others, group) = split(setup_circle(2, &[ONE]).await);
    let reader = &others[0];
    let elsewhere = found_circle(&admin, &[reader], &[TWO]).await;
    mesh_on(&admin).await;
    mesh_on(reader).await;
    let (event, packet) = handed_off(&admin, &group).await;
    let sealed_at = epoch(&admin, &group).await;
    let parts = parts_of(&event, Format::Bridgeable).expect("a location");
    let key = MeshKey::derive(&secret_of(&admin, &group, sealed_at));

    let mut resigned = parts.clone();
    resigned.sig[7] ^= 0x10;
    let forged = wrap(&key, &resigned, &mut OsRng).expect("fits");
    let mut retimed = parts.clone();
    retimed.created_at += 1;
    let altered = wrap(&key, &retimed, &mut OsRng).expect("fits");
    // The circle's own event, under the key of another circle of the same
    // two members: it opens, and is rebuilt under that circle's routing id.
    let misrouted = packet_under(&admin, &elsewhere, epoch(&admin, &elsewhere).await, &event);
    let cover = cover_packet(&mut OsRng);
    let foreign = wrap(&MeshKey::derive(&[0x42; 32]), &parts, &mut OsRng).expect("fits");

    let taken = drive(
        reader,
        vec![
            forged.clone(),
            altered.clone(),
            misrouted.clone(),
            cover.clone(),
            foreign.clone(),
        ],
    )
    .await;
    assert!(
        taken.read
            == [
                (forged.id(), true),
                (altered.id(), true),
                (misrouted.id(), true),
                (cover.id(), false),
                (foreign.id(), false),
            ],
        "a packet was not answered for as what it is"
    );
    assert!(
        ingests(reader) == 0 && taken.replayed.is_empty() && !taken.errored,
        "an event that does not verify reached the engine"
    );
    assert!(taken.from_circles == 0 && counts(reader) == [0; 4]);
    for circle in [&group, &elsewhere] {
        assert_eq!(reader.session().mesh_held_for_test(circle), 0);
        assert!(stored(reader, circle).await.is_empty());
    }

    // The engine never saw the event: the authentic packet is still new.
    let taken = drive(reader, vec![packet]).await;
    assert!(ingests(reader) == 1 && has_fix(&taken.replayed, &admin, LATITUDE));
}

/// The circle's admin commits a relay change and applies it; every member
/// of `apply` takes it in from a relay. Returns the commit.
async fn committed(admin: &CircleMember, group: &GroupId, apply: &[&CircleMember]) -> Event {
    let relays: &[&str] = if epoch(admin, group).await % 2 == 0 {
        &[ONE]
    } else {
        &[ONE, TWO]
    };
    let (commit, pending) = stage_relays(admin.session(), group, relays).await;
    (admin.session().confirm_published(pending).await).expect("the commit is applied");
    for member in apply {
        (member
            .session()
            .process_event_settled_for_test(&commit)
            .await)
            .expect("the member applies the commit");
    }
    commit
}

/// T-SEC-2, with the two cases the design's review demanded. A commit and a
/// proposal a member wrapped as a location — under the key of their own
/// epoch, where every check but the last passes — never reach the engine;
/// neither does a commit of the current epoch sealed again under a past
/// epoch's secret and wrapped under that epoch's key, nor a commit handed
/// over ahead of the proposal it commits. No relay is called, and the circle
/// then takes each real commit from the relay path: one the engine had been
/// handed ahead of its proposal would have been dropped for good.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_commit_or_a_proposal_a_member_wrapped_never_reaches_the_engine() {
    let (admin, others, group) = split(setup_circle(3, &[ONE]).await);
    let (victim, leaver) = (&others[0], &others[1]);
    for device in [&admin, victim, leaver] {
        mesh_on(device).await;
    }
    let first = epoch(&admin, &group).await;
    let dropped = |taken: MeshDrive, packets: &[&Packet]| {
        let ids: Vec<_> = packets.iter().map(|packet| (packet.id(), true)).collect();
        assert!(
            settled(&taken) == sorted(ids) && taken.replayed.is_empty() && !taken.errored,
            "a wrapped commit or proposal was not read and dropped"
        );
        assert!(
            ingests(victim) == 0 && taken.from_circles == 0,
            "a wrapped commit or proposal reached the engine, or was counted as an update"
        );
    };

    // A commit under the key of its own epoch.
    let commit = committed(&admin, &group, &[leaver]).await;
    let wrapped = smuggled(&admin, &group, &commit, [first, first, first]).await;
    dropped(drive(victim, vec![wrapped.clone()]).await, &[&wrapped]);
    assert_eq!(epoch(victim, &group).await, first);
    (victim
        .session()
        .process_event_settled_for_test(&commit)
        .await)
        .expect("applied");
    assert!(
        epoch(victim, &group).await == first + 1,
        "the circle did not take the real commit from the relay path"
    );

    // A commit of the current epoch under the past epoch's key: sealed
    // again under that epoch's secret, so that it peels, and as it was.
    let commit = committed(&admin, &group, &[leaver]).await;
    let resealed = smuggled(&admin, &group, &commit, [first + 1, first, first]).await;
    let as_sealed = smuggled(&admin, &group, &commit, [first + 1, first + 1, first]).await;
    dropped(
        drive(victim, vec![resealed.clone(), as_sealed.clone()]).await,
        &[&resealed, &as_sealed],
    );
    (victim
        .session()
        .process_event_settled_for_test(&commit)
        .await)
        .expect("applied");
    assert_eq!(epoch(victim, &group).await, first + 2);

    // A proposal, and the commit of it ahead of the proposal itself.
    let leave = (leaver.circle.propose_leave(&group).await)
        .expect("the member proposes its leave")
        .expect("a first leave in this epoch proposes");
    assert!(matches!(
        answer(admin.session(), &leave).await,
        IngestOutcome::Processed
    ));
    wait_out_the_engine(&admin, &group).await;
    let advanced = (admin.session().stage_unrecorded_for_test(&group).await)
        .expect("the admin's advance runs");
    let (eviction, pending) = staged(&advanced);
    (admin.session().confirm_published(pending).await).expect("the eviction is applied");
    let now = first + 2;
    let ahead = smuggled(&admin, &group, &eviction, [now, now, now]).await;
    let proposal = smuggled(&admin, &group, &leave, [now, now, now]).await;
    dropped(
        drive(victim, vec![ahead.clone(), proposal.clone()]).await,
        &[&ahead, &proposal],
    );
    assert!(epoch(victim, &group).await == now && roster(victim, &group).await.len() == 3);

    follows_the_eviction(victim, &leave, &eviction).await;
    assert!(
        epoch(victim, &group).await == first + 3 && roster(victim, &group).await.len() == 2,
        "the circle did not converge through the relay path after the wrapped commit"
    );
    // And it still shares: the next location comes in by mesh.
    let (_, packet) = handed_off(&admin, &group).await;
    assert!(has_fix(
        &drive(victim, vec![packet]).await.replayed,
        &admin,
        LATITUDE
    ));
}

/// T-SEC-5: an application message whose inner epoch is not the epoch of
/// the key its packet opened under never reaches the engine — whichever way
/// it is off, and however many there are — so a member cannot fill the
/// engine's buffer of input for other epochs by mesh. An honest seal always
/// carries the epoch of its key: one of the epoch the reader stands on, and
/// one of a sender an epoch behind, are both taken in.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_application_message_of_another_epoch_than_its_keys_never_reaches_the_engine() {
    let (admin, others, group) = split(setup_circle(3, &[ONE]).await);
    let (behind, victim) = (&others[0], &others[1]);
    for device in [&admin, behind, victim] {
        mesh_on(device).await;
    }
    let routing = ngid(&admin, &group).await;
    let first = epoch(&admin, &group).await;
    // One member stays an epoch behind; the victim holds both epochs' keys.
    let (earlier, earlier_packet) = handed_off(behind, &group).await;
    committed(&admin, &group, &[victim]).await;
    let (later, later_packet) = handed_off(&admin, &group).await;
    let (past, current) = (
        secret_of(&admin, &group, first),
        secret_of(&admin, &group, first + 1),
    );

    let mut flood = Vec::new();
    for _ in 0..50 {
        // Sealed at the current epoch, under the past epoch's key; and sealed
        // at the past epoch, under the current one's.
        let ahead = disguised(&later, &routing, &current, &past);
        flood.push(packet_under(&admin, &group, first, &ahead));
        let stale = disguised(&earlier, &routing, &past, &current);
        flood.push(packet_under(&admin, &group, first + 1, &stale));
    }
    let taken = drive(victim, flood.clone()).await;
    assert!(
        settled(&taken) == sorted(flood.iter().map(|packet| (packet.id(), true)).collect()),
        "a packet of this circle was not read and dropped"
    );
    assert!(
        ingests(victim) == 0 && held(victim.session(), &group).await.is_empty(),
        "an application message of another epoch than its key's reached the engine"
    );
    assert!(taken.from_circles == 0 && counts(victim) == [0; 4]);
    assert_eq!(victim.session().mesh_held_for_test(&group), 0);
    assert!(stored(victim, &group).await.is_empty());

    // The honest ones: each under the key of the epoch it was sealed at.
    let taken = drive(victim, vec![later_packet, earlier_packet]).await;
    assert!(
        ingests(victim) == 2 && taken.read.len() == 2 && locations(&taken.replayed) == 2,
        "an honest seal did not pass: its inner epoch is not its key's"
    );
    assert!(
        stored_fix(victim, &group, behind, LATITUDE).await,
        "the update of a member one epoch behind was not read"
    );
    assert!(stored_fix(victim, &group, &admin, LATITUDE).await);
    assert_eq!(counts(victim), [2, 0, 2, 0]);
}

/// An update sealed at an epoch the reader has left more than the engine's
/// window behind opens under no key, and is not this device's to read.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_update_sealed_before_the_window_is_not_read() {
    let (admin, others, group) = split(setup_circle(3, &[ONE]).await);
    let (behind, reader) = (&others[0], &others[1]);
    for device in [&admin, behind, reader] {
        mesh_on(device).await;
    }
    let (_, packet) = handed_off(behind, &group).await;
    let another = packet_under(
        behind,
        &group,
        epoch(behind, &group).await,
        &sealed_by(behind, &group, 12.5).await,
    );
    // Five epochs on its key is still held, and the update is read.
    for _ in 0..5 {
        committed(&admin, &group, &[reader]).await;
    }
    let taken = drive(reader, vec![packet.clone()]).await;
    assert!(
        taken.read == [(packet.id(), true)] && taken.from_circles == 1,
        "an update inside the window was not opened"
    );
    // A sixth, and the key is gone with the engine's own.
    committed(&admin, &group, &[reader]).await;
    let (opens, taken_in) = reader.session().mesh_reads_for_test();
    let taken = drive(reader, vec![another.clone()]).await;
    assert!(
        taken.read == [(another.id(), false)] && taken.replayed.is_empty(),
        "an update sealed before the window was read"
    );
    let (opens_after, taken_in_after) = reader.session().mesh_reads_for_test();
    assert!(taken_in_after == taken_in && counts(reader)[0] == 1);
    // T-PERF-2: one open a key the ring holds, counted.
    let keys = reader.session().mesh_key_epochs_for_test(&group).len();
    assert!(
        keys == 6 && opens_after - opens == keys,
        "a packet no key opens was not tried once under each key the ring holds"
    );
}

/// A circle with a commit of this device's pending takes nothing in by mesh
/// (Security Rules 12 and 13.4): its packets are held, a bounded number that
/// is the circle's own, and it is not driven. Another circle is read in the
/// same drive as if nothing were held. Either resolution of the commit
/// releases what is held, a bounded share of it a drive.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_circle_awaiting_its_own_commit_holds_a_bounded_number_and_starves_no_other() {
    // The session's bounds: packets held for one circle, and events one
    // drive offers the engine for one circle.
    const HELD: usize = 64;
    const A_DRIVE: usize = 32;
    let (admin, others, group) = split(setup_circle(2, &[ONE]).await);
    let sender = &others[0];
    let other = found_circle(&admin, &[sender], &[TWO]).await;
    mesh_on(&admin).await;
    mesh_on(sender).await;
    let sealed_at = epoch(sender, &group).await;
    let mut packets = Vec::new();
    for index in 0..HELD + 5 {
        let fix = sealed_by(sender, &group, latitude_of(index)).await;
        packets.push(packet_under(sender, &group, sealed_at, &fix));
    }
    let (_, elsewhere) = handed_off(sender, &other).await;

    let (_, pending) = stage_relays(admin.session(), &group, &[ONE, TWO]).await;
    let taken = drive(&admin, packets[..3].to_vec()).await;
    assert!(
        taken.read.is_empty() && taken.replayed.is_empty() && ingests(&admin) == 0,
        "a circle awaiting its own commit took a packet in"
    );
    assert_eq!(admin.session().mesh_held_for_test(&group), 3);
    assert!(
        staged_ref(&admin, &group).await.is_some(),
        "the drive resolved the pending commit"
    );

    // Past the circle's quota its own oldest go, and the other circle's
    // packet is taken in beside them.
    let mut more = packets[3..].to_vec();
    more.push(elsewhere.clone());
    let taken = drive(&admin, more).await;
    let mut gone: Vec<_> = packets[..5]
        .iter()
        .map(|packet| (packet.id(), true))
        .collect();
    gone.push((elsewhere.id(), true));
    assert!(
        settled(&taken) == sorted(gone),
        "the held circle did not give up its own oldest packets, or cost the other its own"
    );
    assert_eq!(admin.session().mesh_held_for_test(&group), HELD);
    assert!(ingests(&admin) == 1 && has_fix(&taken.replayed, sender, LATITUDE));
    assert!(stored_fix(&admin, &other, sender, LATITUDE).await);
    assert!(stored(&admin, &group).await.is_empty());
    assert!(
        taken.from_circles == 1 && counts(&admin)[0] == 1,
        "an update the engine has not read was counted"
    );

    // The commit is acknowledged: a drive takes its share in, the next the
    // rest, each counted as the engine reads it.
    (admin.session().confirm_published(pending).await).expect("the commit is applied");
    let taken = drive(&admin, Vec::new()).await;
    assert!(
        taken.read.len() == A_DRIVE && ingests(&admin) == 1 + A_DRIVE,
        "a drive offered the engine more or fewer of a circle's events than its share"
    );
    assert!(
        locations(&taken.replayed) == A_DRIVE
            && taken.from_circles == u64::try_from(A_DRIVE).unwrap()
    );
    let taken = drive(&admin, Vec::new()).await;
    assert!(taken.read.len() == HELD - A_DRIVE && admin.session().mesh_held_for_test(&group) == 0);
    assert_eq!(stored(&admin, &group).await.len(), 1);
    // The five the quota pushed out were never read, and are not counted.
    assert_eq!(counts(&admin)[0], u64::try_from(HELD + 1).unwrap());

    // A commit that is rolled back releases what it held as well.
    let late = sealed_by(sender, &group, 77.25).await;
    let late = packet_under(sender, &group, sealed_at, &late);
    let (_, pending) = stage_relays(admin.session(), &group, &[ONE]).await;
    assert!(drive(&admin, vec![late.clone()]).await.read.is_empty());
    (admin.session().publish_failed(pending).await).expect("the commit is rolled back");
    let taken = drive(&admin, Vec::new()).await;
    assert!(taken.read == [(late.id(), true)] && has_fix(&taken.replayed, sender, 77.25));
}

/// A circle holding input a relay plane fetched and has not taken in takes
/// nothing in by mesh either; once that input is in, what was held is.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_circle_holding_fetched_input_unread_takes_nothing_in_by_mesh() {
    let (admin, others, group) = split(setup_circle(3, &[ONE]).await);
    let (sender, reader) = (&others[0], &others[1]);
    for device in [&admin, sender, reader] {
        mesh_on(device).await;
    }
    let (_, packet) = handed_off(sender, &group).await;
    let commit = committed(&admin, &group, &[]).await;
    reader
        .session()
        .hold_pager_commits_for_test(&group, &[commit.id]);

    let taken = drive(reader, vec![packet.clone()]).await;
    assert!(
        taken.read.is_empty() && ingests(reader) == 0 && taken.replayed.is_empty(),
        "a circle holding fetched input unread took a packet in"
    );
    assert_eq!(reader.session().mesh_held_for_test(&group), 1);

    (reader
        .session()
        .process_event_settled_for_test(&commit)
        .await)
        .expect("applied");
    let taken = drive(reader, Vec::new()).await;
    assert!(taken.read == [(packet.id(), true)] && has_fix(&taken.replayed, sender, LATITUDE));
}

/// An ingest that fails leaves its packet held, never read: it is offered
/// again at the next drive, which answers for it.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_packet_whose_ingest_failed_is_held_and_offered_again() {
    let (admin, others, group) = split(setup_circle(2, &[ONE]).await);
    let reader = &others[0];
    mesh_on(&admin).await;
    mesh_on(reader).await;
    let (_, packet) = handed_off(&admin, &group).await;

    reader.session().fail_next_ingest_for_test();
    let taken = drive(reader, vec![packet.clone()]).await;
    assert!(
        taken.errored && taken.read.is_empty(),
        "a packet whose ingest failed was reported read"
    );
    assert!(ingests(reader) == 1 && reader.session().mesh_held_for_test(&group) == 1);

    let taken = drive(reader, Vec::new()).await;
    assert!(
        taken.read == [(packet.id(), true)] && !taken.errored,
        "a held packet was not offered again, or not answered for"
    );
    assert!(ingests(reader) == 2 && reader.session().mesh_held_for_test(&group) == 0);
    // The engine read it in the ingest that failed, and announces an update
    // once: what an error lost is not counted, and never twice.
    assert!(counts(reader)[0] == 0, "a held packet was counted again");
}

/// An ingest that fails ends its circle's turn in that drive: the circle's
/// other events are not asked of the engine and stay held, and the next
/// drive offers them again.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_ingest_that_fails_ends_its_circles_turn_in_that_drive() {
    let (admin, others, group) = split(setup_circle(2, &[ONE]).await);
    let reader = &others[0];
    mesh_on(&admin).await;
    mesh_on(reader).await;
    let (_, first) = handed_off(&admin, &group).await;
    let (_, second) = handed_off(&admin, &group).await;

    reader.session().fail_next_ingest_for_test();
    let taken = drive(reader, vec![first, second]).await;
    assert!(
        taken.errored && taken.read.is_empty() && ingests(reader) == 1,
        "a circle whose ingest failed was asked again in the same drive"
    );
    assert_eq!(reader.session().mesh_held_for_test(&group), 2);

    let taken = drive(reader, Vec::new()).await;
    assert!(
        !taken.errored && ingests(reader) == 3 && reader.session().mesh_held_for_test(&group) == 0,
        "what a failed ingest left held was not offered again"
    );
}

/// A packet whose event the engine did not keep — it answered a want of
/// room — is held, never read (Security Rule 12), and offered again.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_packet_whose_event_the_engine_did_not_keep_is_held_and_offered_again() {
    let (admin, others, group) = split(setup_circle(2, &[ONE]).await);
    let reader = &others[0];
    mesh_on(&admin).await;
    mesh_on(reader).await;
    let (_, packet) = handed_off(&admin, &group).await;

    reader.session().leave_next_mesh_ingest_unkept_for_test();
    let taken = drive(reader, vec![packet.clone()]).await;
    assert!(
        taken.read.is_empty() && !taken.errored,
        "a packet whose event the engine did not keep was reported read"
    );
    assert_eq!(reader.session().mesh_held_for_test(&group), 1);

    let taken = drive(reader, Vec::new()).await;
    assert!(taken.read == [(packet.id(), true)] && ingests(reader) == 2);
    assert_eq!(reader.session().mesh_held_for_test(&group), 0);
}

/// A wake that has ended begins no ingest: what opened is held for the next
/// drive.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_drive_whose_wake_has_ended_holds_what_it_opened() {
    let (admin, others, group) = split(setup_circle(2, &[ONE]).await);
    let reader = &others[0];
    mesh_on(&admin).await;
    mesh_on(reader).await;
    let (_, packet) = handed_off(&admin, &group).await;

    let (relays, clock) = (Relays::default(), ManualClock::at(1_000));
    let ended = Publishing {
        fanout: &relays,
        publisher: &relays,
        clock: &*clock,
        deadline_ms: Some(ManualClock::ORIGIN + 999),
        mode: &DriveMode::Full,
    };
    let taken = ended.mesh_drive(&reader.circle, vec![packet.clone()]).await;
    assert!(taken.read.is_empty() && ingests(reader) == 0 && taken.from_circles == 0);
    assert_eq!(relays.calls.load(Ordering::SeqCst), 0);

    let taken = drive(reader, Vec::new()).await;
    assert!(taken.read == [(packet.id(), true)] && has_fix(&taken.replayed, &admin, LATITUDE));
    assert!(
        taken.from_circles == 1,
        "an update is counted when it is read"
    );
}

/// The drive calls no relay even when its ingest hands back input a relay
/// plane left stranded: the stranded locations come back with the one the
/// packet carried, all stored, and nothing the hand-back leads to is sent.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_drive_that_hands_back_stranded_relay_input_still_calls_no_relay() {
    let (admin, others, group) = split(setup_circle(3, &[ONE]).await);
    mesh_on(&admin).await;
    mesh_on(&others[0]).await;
    // Two locations parked behind a commit of the admin's, then stranded by
    // a confirm whose transaction landed and nothing after it.
    let source = epoch(&admin, &group).await;
    let (_, pending) = stage_relays(admin.session(), &group, &[ONE, TWO]).await;
    for (index, sender) in others.iter().enumerate() {
        let fix = sealed_by(sender, &group, latitude_of(index)).await;
        assert!(parks(admin.session(), &fix).await, "premise: parked unread");
    }
    let admin = (confirm_and_die(admin, pending, source + 1).await).reopen();
    assert!(
        held(admin.session(), &group).await.len() == 2,
        "premise: two locations are stranded"
    );
    let fix = sealed_by(&others[0], &group, 33.75).await;
    let packet = packet_under(&others[0], &group, source, &fix);

    // `drive` fails the test if a relay is called in any way.
    let taken = drive(&admin, vec![packet.clone()]).await;
    assert!(taken.read == [(packet.id(), true)] && !taken.errored);
    assert!(
        has_fix(&taken.replayed, &others[0], 33.75)
            && has_fix(&taken.replayed, &others[0], latitude_of(0))
            && has_fix(&taken.replayed, &others[1], latitude_of(1)),
        "the drive did not hand back what its hold released"
    );
    assert!(stored_fix(&admin, &group, &others[1], latitude_of(1)).await);
    assert_eq!(stored(&admin, &group).await.len(), 2);
    assert!(held(admin.session(), &group).await.is_empty());
}

/// A drive brings the ring in line with the engine before it reads: a
/// circle joined since the last batch that named it is read at once, and a
/// deadline that has passed with nothing to see it opens nothing and leaves
/// no key, in memory or in the table.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_drive_reads_a_circle_joined_since_and_nothing_once_the_deadline_has_passed() {
    let (admin, others, group) = split(setup_circle(2, &[ONE]).await);
    let reader = &others[0];
    mesh_on(&admin).await;
    mesh_on(reader).await;
    let joined = found_circle(&admin, &[reader], &[TWO]).await;
    assert!(
        reader
            .session()
            .mesh_key_epochs_for_test(&joined)
            .is_empty(),
        "premise: no batch has named the circle joined since mesh went on"
    );
    let (_, packet) = handed_off(&admin, &joined).await;
    let taken = drive(reader, vec![packet.clone()]).await;
    assert!(
        taken.read == [(packet.id(), true)] && has_fix(&taken.replayed, &admin, LATITUDE),
        "a drive did not read a circle joined since the last batch that named it"
    );

    let (_, late) = handed_off(&admin, &group).await;
    reader
        .session()
        .set_legacy_clock_for_test(wall_ms() + 2 * HOUR_MS);
    let taken = drive(reader, vec![late.clone()]).await;
    assert!(
        taken.read == [(late.id(), false)] && taken.replayed.is_empty(),
        "a drive opened a packet after the mesh's deadline had passed"
    );
    assert!(
        row_count(reader) == 0
            && reader.session().mesh_key_epochs_for_test(&group).is_empty()
            && reader.session().mesh_on_until_for_test() == 0,
        "a drive past the deadline left a key in memory or in the table"
    );
}

/// T-STAT-1: "from your circles" counts an update when the engine reads it
/// for the first time, and never again — whoever replays its packet, however
/// many of a circle's packets are replayed in a cycle, across a restart and
/// across mesh being turned off and on.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_cycle_of_replayed_packets_counts_each_update_once_whatever_comes_between() {
    // More than any bound the session keeps for a circle, and a drive's
    // share of a circle at a time.
    const UPDATES: usize = 300;
    const A_DRIVE: usize = 30;
    let (admin, mut others, group) = split(setup_circle(2, &[ONE]).await);
    let mut reader = others.remove(0);
    mesh_on(&admin).await;
    mesh_on(&reader).await;
    let sealed_at = epoch(&admin, &group).await;
    let mut packets = Vec::new();
    for index in 0..UPDATES {
        let fix = sealed_by(&admin, &group, latitude_of(index)).await;
        packets.push(packet_under(&admin, &group, sealed_at, &fix));
    }
    let updates = u64::try_from(UPDATES).unwrap();
    let cycle = |reader: &CircleMember| {
        let (circle, packets) = (std::sync::Arc::clone(&reader.circle), packets.clone());
        async move {
            let (relays, clock) = (Relays::default(), ManualClock::at(0));
            let driver = Publishing {
                fanout: &relays,
                publisher: &relays,
                clock: &*clock,
                deadline_ms: None,
                mode: &DriveMode::Full,
            };
            let mut counted = 0;
            for share in packets.chunks(A_DRIVE) {
                let taken = driver.mesh_drive(&circle, share.to_vec()).await;
                assert!(taken.read.len() == share.len() && !taken.errored);
                counted += taken.from_circles;
            }
            assert_eq!(relays.calls.load(Ordering::SeqCst), 0);
            counted
        }
    };

    assert!(cycle(&reader).await == updates && counts(&reader) == [updates, 0, updates, 0]);
    assert!(
        cycle(&reader).await == 0 && counts(&reader) == [updates, 0, updates, 0],
        "a replayed cycle of a circle's packets was counted again"
    );

    reader = reader.reopen();
    assert!(
        cycle(&reader).await == 0 && counts(&reader) == [updates, 0, updates, 0],
        "updates read before a restart were counted again after it"
    );

    assert!(reader.session().mesh_off().await);
    mesh_on(&reader).await;
    assert!(
        cycle(&reader).await == 0 && counts(&reader) == [updates, 0, 0, 0],
        "updates read before mesh was turned off were counted again once it was on"
    );
}

/// An update of this device's own that a member wraps again and hands back
/// by mesh is read, and is no update from its circles: it is not counted,
/// and nothing is handed back or stored for it.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn this_devices_own_update_a_member_wrapped_again_is_not_counted() {
    let (admin, others, group) = split(setup_circle(2, &[ONE]).await);
    let member = &others[0];
    mesh_on(&admin).await;
    mesh_on(member).await;
    let (own, packet) = handed_off(&admin, &group).await;
    let wrapped = packet_under(member, &group, epoch(&admin, &group).await, &own);
    assert!(wrapped.id() != packet.id(), "premise: another packet");

    let taken = drive(&admin, vec![packet.clone(), wrapped.clone()]).await;
    assert!(
        settled(&taken) == sorted(vec![(packet.id(), true), (wrapped.id(), true)]),
        "a packet of this device's own update was not read"
    );
    assert!(
        taken.from_circles == 0 && counts(&admin) == [0; 4],
        "this device's own update was counted as one from its circles"
    );
    assert!(locations(&taken.replayed) == 0 && stored(&admin, &group).await.is_empty());
}

/// What the mesh brings arms no walk of a circle's history and moves none:
/// the walk is armed by the same unreadable event from a relay whether a
/// peer's update came by mesh in between, by a relay, or not at all. When a
/// walk is armed is something the circle's relays see.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn what_the_mesh_brings_arms_no_history_walk_and_moves_none() {
    #[derive(Clone, Copy, PartialEq)]
    enum Brought {
        Nothing,
        ByARelay,
        ByMesh,
    }
    // What arms a walk: MDK's run of events a device cannot open.
    const RUN: usize = 8;
    for brought in [Brought::Nothing, Brought::ByARelay, Brought::ByMesh] {
        let (admin, others, group) = split(setup_circle(3, &[ONE]).await);
        let (behind, peer) = (&others[0], &others[1]);
        mesh_on(behind).await;
        mesh_on(peer).await;
        // The circle moves on without `behind`, and without `peer`, whom
        // the commit removes and who goes on sending at the epoch it left.
        let _ = (admin.circle)
            .remove_members_for_test(&group, &[peer.pubkey_hex()])
            .await
            .expect("the admin removes the peer");
        let relayed = |event: Event| async move {
            let _ = (behind.session())
                .process_event_staging_for_test(&event, 0, &DriveMode::Full)
                .await
                .expect("the ingest runs");
        };
        for index in 0..RUN - 1 {
            relayed(sealed_by(&admin, &group, latitude_of(index)).await).await;
        }
        let (event, packet) = handed_off(peer, &group).await;
        match brought {
            Brought::Nothing => {}
            Brought::ByARelay => relayed(event).await,
            Brought::ByMesh => {
                let taken = drive(behind, vec![packet]).await;
                assert!(
                    has_fix(&taken.replayed, peer, LATITUDE),
                    "premise: the mesh brought a peer's update at the circle's epoch"
                );
            }
        }
        assert!(
            behind.session().stall_arms_for_test() == 0,
            "a walk was armed one event short of a run, or by what the mesh brought"
        );
        relayed(sealed_by(&admin, &group, latitude_of(RUN)).await).await;
        assert!(
            behind.session().stall_arms_for_test() == 1,
            "when a walk is armed turned on what came between, by any carrier"
        );
    }
}

/// A peer's update at the circle's epoch ends the `Stalled` reading — this
/// device read a peer — whether a relay or the mesh brought it.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_peers_update_ends_the_stalled_reading_whichever_carrier_brought_it() {
    for by_mesh in [false, true] {
        let (admin, mut others, group) = split(setup_circle(2, &[ONE]).await);
        let mut reader = others.remove(0);
        mesh_on(&admin).await;
        mesh_on(&reader).await;
        // Three walks the relays answered in full with nothing that moved
        // this device, as a process before this one counted them.
        helpers::removals::store(&reader)
            .execute(
                "INSERT INTO epoch_stall_evidence VALUES (?1, ?2, 3, 1, ?3)",
                rusqlite::params![
                    group.as_slice(),
                    i64::try_from(epoch(&reader, &group).await).unwrap(),
                    i64::try_from(wall_ms()).unwrap(),
                ],
            )
            .expect("the evidence is stored");
        reader = reader.reopen();
        assert!(
            reader.session().stalled_for_test(&group),
            "premise: the circle reads as stalled"
        );

        let (event, packet) = handed_off(&admin, &group).await;
        if by_mesh {
            let _ = drive(&reader, vec![packet]).await;
        } else {
            assert!(reads(&reader, &event).await);
        }
        assert!(
            !reader.session().stalled_for_test(&group),
            "a circle whose peer this device has just read still reads as stalled"
        );
    }
}

/// A proposal the drive's hold is handed back with no record — the store
/// refused the write — is not sent by the drive and is not lost: the next
/// relay drive sends it, once, to its own circle's relays.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_proposal_the_drive_could_write_no_record_for_is_sent_by_the_next_relay_drive() {
    use haven_core::nostr::mls::storage::set_fanout_write_fault_naming_for_test;
    use haven_core::relay::fanout::scripted::Answer;
    use helpers::drive::{records_of, through, Recorder};
    use helpers::mesh::a_leave_minted_again;
    use helpers::stranded::mls_db;

    let (device, admin_a, admin_b, peer) = (
        CircleMember::new(),
        CircleMember::new(),
        CircleMember::new(),
        CircleMember::new(),
    );
    let group_a = found_circle(&admin_a, &[&device, &peer], &[ONE]).await;
    let group_b = found_circle(&admin_b, &[&device], &[TWO]).await;
    let (minted, proposal) = a_leave_minted_again(&device, &admin_a, &peer, &group_a, ONE).await;
    mesh_on(&device).await;
    mesh_on(&admin_b).await;
    let (_, packet) = handed_off(&admin_b, &group_b).await;

    let (db, key) = mls_db(device.dir.path());
    set_fanout_write_fault_naming_for_test(&db, &key, ONE, true).expect("arm");
    device.session().strand_effects_for_test(minted);
    // `drive` fails the test if a relay is called in any way.
    let taken = drive(&device, vec![packet.clone()]).await;
    set_fanout_write_fault_naming_for_test(&db, &key, ONE, false).expect("disarm");
    assert!(taken.read == [(packet.id(), true)] && has_fix(&taken.replayed, &admin_b, LATITUDE));
    assert!(
        (records_of(&device, &group_a).await.iter()).all(|record| record.event_id != proposal),
        "premise: no record was written for the proposal"
    );

    let (transport, outbox) = (ScriptedFanout::default(), Recorder::acking(true));
    transport.answer(ONE, [Answer::Accepted; 8]);
    let clock = ManualClock::at(0);
    let _ = through(&transport, &outbox, &clock, &DriveMode::Full)
        .resume(&device.circle)
        .await;
    let sent: Vec<_> = (outbox.handed().into_iter())
        .filter(|(event, _)| event.id == proposal)
        .collect();
    assert!(
        sent.len() == 1 && sent[0].1 == [ONE],
        "a proposal the drive could not record was lost, sent twice, or sent to another \
         circle's relays"
    );
}

/// The four counts survive a restart; turning mesh on again starts the two
/// counted since it was turned on, and touches neither total.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn the_counts_survive_a_restart_and_turning_mesh_on_starts_the_since_on_pair_alone() {
    let (admin, mut others, group) = split(setup_circle(2, &[ONE]).await);
    let mut reader = others.remove(0);
    mesh_on(&admin).await;
    mesh_on(&reader).await;
    for _ in 0..3 {
        let (_, packet) = handed_off(&admin, &group).await;
        let _ = drive(&reader, vec![packet]).await;
    }
    reader.circle.fold_mesh_counts(0, 11);
    assert_eq!(counts(&reader), [3, 11, 3, 11]);

    reader = reader.reopen();
    assert!(
        counts(&reader) == [3, 11, 3, 11],
        "a restart with mesh on changed a count"
    );
    // Asked for again while it is on: the deadline moves, nothing starts.
    mesh_on(&reader).await;
    assert_eq!(counts(&reader), [3, 11, 3, 11]);

    assert!(reader.session().mesh_off().await);
    mesh_on(&reader).await;
    assert!(
        counts(&reader) == [3, 11, 0, 0],
        "turning mesh on did not start the since-on counts, or changed a total"
    );
    let (_, packet) = handed_off(&admin, &group).await;
    let _ = drive(&reader, vec![packet]).await;
    reader = reader.reopen();
    assert_eq!(counts(&reader), [4, 11, 1, 0]);
}

/// Log anonymity (Security Rule 15): a drive that reads, drops, holds and
/// takes in logs no identifier of the circle, the members, the events, the
/// packets or the relays, in any encoding.
#[tokio::test]
async fn a_mesh_drive_logs_no_identifier() {
    let (admin, others, group) = split(setup_circle(2, &[ONE]).await);
    let reader = &others[0];
    mesh_on(&admin).await;
    mesh_on(reader).await;
    let routing = ngid(&admin, &group).await;
    let sealed_at = epoch(&admin, &group).await;
    let own = secret_of(&admin, &group, sealed_at);
    let (event, packet) = handed_off(&admin, &group).await;
    let (held_event, held_packet) = handed_off(&admin, &group).await;
    let commit = committed(&admin, &group, &[]).await;
    let wrapped = packet_under(
        &admin,
        &group,
        sealed_at,
        &disguised(&commit, &routing, &own, &own),
    );
    let mut forged = parts_of(&event, Format::Bridgeable).expect("a location");
    forged.sig[3] ^= 1;
    let forged = wrap(&MeshKey::derive(&own), &forged, &mut OsRng).expect("fits");
    let cover = cover_packet(&mut OsRng);

    let lines = capture_haven_log_here(async {
        let taken = drive(
            reader,
            vec![
                packet.clone(),
                wrapped.clone(),
                forged.clone(),
                cover.clone(),
            ],
        )
        .await;
        assert!(taken.read.len() == 4 && locations(&taken.replayed) == 1);
        // One held behind fetched input, then released and taken in.
        reader
            .session()
            .hold_pager_commits_for_test(&group, &[commit.id]);
        assert!(drive(reader, vec![held_packet.clone()])
            .await
            .read
            .is_empty());
        (reader
            .session()
            .process_event_settled_for_test(&commit)
            .await)
            .expect("applied");
        assert_eq!(drive(reader, Vec::new()).await.read.len(), 1);
    })
    .await;

    let mut needles = vec![
        hex::encode(group.as_slice()),
        hex::encode(routing),
        hex::encode(own),
        admin.pubkey_hex(),
        reader.pubkey_hex(),
        ONE.trim_start_matches("wss://").to_owned(),
    ];
    for event in [&event, &held_event, &commit] {
        needles.extend([event.id.to_hex(), event.pubkey.to_hex()]);
    }
    for packet in [&packet, &held_packet, &wrapped, &forged, &cover] {
        needles.push(hex::encode(packet.id().0));
    }
    let needles: Vec<&str> = needles.iter().map(String::as_str).collect();
    assert!(!lines.is_empty(), "the capture recorded nothing");
    assert_no_needles(&haven_core_lines(&lines), &needles);
}

/// T-STAT-1, T-BG-3 and T-INDEP-3, over real mesh engines on the simulator's
/// radio: a member's update crosses a phone that is in none of its circles
/// and reaches a co-member with no relay involved at all. Read long after
/// its lifetime ended, it is taken in and stored once; the phone that could
/// not read it counts it as passed on, the phone that could does not, and
/// "from your circles" is one on the co-member's phone and none on the
/// other's. The relay's copy, when relays answer again, is a duplicate.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_update_crosses_a_stranger_by_radio_and_is_read_after_its_lifetime_with_relays_down() {
    use world::{Radio, Reader, World};
    let (admin, others, group) = split(setup_circle(2, &[ONE]).await);
    let receiver = &others[0];
    let stranger = CircleMember::new();
    let _ = found_circle(&stranger, &[], &[TWO]).await;
    for device in [&admin, receiver, &stranger] {
        mesh_on(device).await;
    }
    let (event, packet) = handed_off(&admin, &group).await;

    let mut world = World::new();
    let config = Config::default();
    let life_ms = config.life_ms;
    let phones: Vec<_> = (0..3)
        .map(|seed| world.phone(config.clone(), 40 + seed, Reader::Absent))
        .collect();
    let (from, hop, to) = (phones[0], phones[1], phones[2]);
    world.link(from, hop, Radio::instant(512));
    world.link(hop, to, Radio::instant(512));
    world.drive(from, |engine, now| {
        engine.offer(CircleSlot(0), packet.clone(), u64::MAX, now);
    });
    // Nobody reads for two lifetimes: no app was running.
    world.run_until(2 * life_ms);

    let mut passed_on = Vec::new();
    for (phone, device, ours) in [(hop, &stranger, false), (to, receiver, true)] {
        let taken = world.drive(phone, |engine, _| engine.take_unread(usize::MAX));
        assert!(
            taken.iter().any(|carried| carried.id() == packet.id()),
            "the update did not reach a phone two hops away, or was dropped unread"
        );
        let read = drive(device, taken).await;
        assert!(
            read.read.contains(&(packet.id(), ours))
                && read.read.iter().filter(|(_, opened)| *opened).count() == usize::from(ours),
            "a phone read a packet that is not its circles', or missed the one that is"
        );
        let before = world.settled(phone).stats().passed_on;
        world.drive(phone, |engine, _| engine.mark_read(packet.id(), ours));
        passed_on.push(world.settled(phone).stats().passed_on - before);
        assert_eq!(counts(device)[0], u64::from(ours));
        assert_eq!(locations(&read.replayed), usize::from(ours));
    }
    assert!(
        passed_on == [1, 0],
        "the phone that could not read the update did not count it passed on, or the one that \
         could did"
    );
    assert!(stored_fix(receiver, &group, &admin, LATITUDE).await);
    assert_eq!(stored(receiver, &group).await.len(), 1);

    // Relays answer again: their copy is a duplicate, and the row is one.
    assert!(!reads(receiver, &event).await);
    assert!(stored(receiver, &group).await.len() == 1 && counts(receiver)[0] == 1);
}
