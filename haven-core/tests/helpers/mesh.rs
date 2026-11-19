//! The mesh key ring and the publish hand-off as a test reads them: the ring
//! through the session's seams, the `mesh_keys` table through a connection of
//! the test's own, and the hand-off through the drain the engine's owner
//! makes.

use std::future::Future;
use std::pin::Pin;
use std::sync::atomic::{AtomicUsize, Ordering};

use base64::engine::general_purpose::STANDARD as BASE64;
use base64::Engine as _;
use chacha20poly1305::aead::{Aead, KeyInit};
use chacha20poly1305::{ChaCha20Poly1305, Key, Nonce};
use haven_core::location::LocationMessage;
use haven_core::mesh::event::parts_of;
use haven_core::mesh::handoff::Op;
use haven_core::mesh::packet::{wrap, Format, MeshKey, Packet};
use haven_core::nostr::mls::types::{GroupId, PublishWork, SessionEffects, TransportMessage};
use haven_core::relay::fanout::scripted::ScriptedFanout;
use haven_core::relay::fanout::{
    DriveMode, FanoutSend, FanoutTargetOutcome, LocationPublish, LocationSeal, Publishing, Taken,
    UnrecordedPublisher,
};
use haven_core::relay::{PublishResult, RelayResult};
use nostr::{Event, EventBuilder, EventId, Keys, Kind, Tag, Timestamp};
use rand::rngs::OsRng;
use rand::RngCore as _;

use super::drive::{through, ManualClock, Recorder, HOUR_MS};
use super::removals::store;
use super::CircleMember;

/// Relays that take everything, behind a count of every call made to them,
/// of every kind: a relay taken, a record's event sent, a location sent, an
/// event with no record published.
#[derive(Default)]
pub struct WatchedRelays {
    calls: AtomicUsize,
    inner: ScriptedFanout,
}

impl WatchedRelays {
    /// How many calls of any kind were made.
    pub fn calls(&self) -> usize {
        self.calls.load(Ordering::SeqCst)
    }
}

#[async_trait::async_trait]
impl FanoutSend for WatchedRelays {
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

impl UnrecordedPublisher for WatchedRelays {
    fn publish_unrecorded<'a>(
        &'a self,
        _event: &'a Event,
        _relays: &'a [String],
    ) -> Pin<Box<dyn Future<Output = bool> + Send + 'a>> {
        self.calls.fetch_add(1, Ordering::SeqCst);
        Box::pin(async { true })
    }
}

/// `device`, which asked to leave `group`, after a commit of the circle's
/// admin moved the circle on: what the engine's full advance hands back —
/// its leave, minted again for the epoch reached — as a call that died
/// before recording it leaves it, and the id of that proposal's event.
pub async fn a_leave_minted_again(
    device: &CircleMember,
    admin: &CircleMember,
    peer: &CircleMember,
    group: &GroupId,
    relay: &str,
) -> (SessionEffects, EventId) {
    let transport = ScriptedFanout::default();
    transport.answer(
        relay,
        [haven_core::relay::fanout::scripted::Answer::Accepted; 8],
    );
    let (outbox, clock) = (Recorder::acking(true), ManualClock::at(0));
    let _ = through(&transport, &outbox, &clock, &DriveMode::Full)
        .leave(&device.circle, group, &device.keys.public_key())
        .await
        .expect("the leave is proposed");
    let commit = super::removals::confirmed(
        admin,
        &admin
            .session()
            .remove_members(group, &[peer.pubkey_hex()])
            .await
            .expect("the admin removes the peer"),
    )
    .await;
    let _ = (device.session().process_event(&commit).await).expect("the commit is taken in");
    let mut minted =
        (device.session().settle_receive_for_test(group).await).expect("the commit is applied");
    // A receive advance takes inputs only; the full one mints the leave again.
    minted.publish.extend(
        (device.session().advance_convergence(group).await)
            .expect("the full advance")
            .publish,
    );
    let proposal = minted
        .publish
        .iter()
        .find_map(|work| match work {
            PublishWork::Proposal { msg, .. } => EventId::from_slice(msg.id.as_slice()).ok(),
            _ => None,
        })
        .expect("premise: the engine minted the leave again for the epoch the commit reached");
    (minted, proposal)
}

/// One `mesh_keys` row: its epoch, routing id and secret.
pub type KeyRow = (u64, [u8; 32], [u8; 32]);

/// The device's own clock, which a session reads when it is handed none.
pub fn wall_ms() -> u64 {
    u64::try_from(chrono::Utc::now().timestamp_millis()).expect("after 1970")
}

/// Turns `member`'s mesh on for an hour.
pub async fn mesh_on(member: &CircleMember) {
    assert!(
        member.session().mesh_on_until(wall_ms() + HOUR_MS).await,
        "premise: mesh is on",
    );
}

/// The epochs `member`'s ring holds a key for in `group`, newest first.
pub fn epochs(member: &CircleMember, group: &GroupId) -> Vec<u64> {
    (member.session().mesh_key_epochs_for_test(group).iter())
        .map(|(epoch, _)| *epoch)
        .collect()
}

/// `member`'s `mesh_keys` rows for `group`, newest first, read from the
/// table itself.
pub fn rows(member: &CircleMember, group: &GroupId) -> Vec<KeyRow> {
    let store = store(member);
    let mut statement = store
        .prepare(
            "SELECT epoch, routing_id, secret FROM mesh_keys
             WHERE mls_group_id = ?1 ORDER BY epoch DESC",
        )
        .expect("the table exists");
    statement
        .query_map([group.as_slice()], |row| {
            Ok((
                u64::try_from(row.get::<_, i64>(0)?).expect("an epoch"),
                row.get::<_, [u8; 32]>(1)?,
                row.get::<_, [u8; 32]>(2)?,
            ))
        })
        .expect("the rows are read")
        .collect::<Result<_, _>>()
        .expect("each row is read")
}

/// The epochs of [`rows`].
pub fn row_epochs(member: &CircleMember, group: &GroupId) -> Vec<u64> {
    rows(member, group).iter().map(|row| row.0).collect()
}

/// How many rows `member`'s `mesh_keys` table holds, for any circle.
pub fn row_count(member: &CircleMember) -> i64 {
    store(member)
        .query_row("SELECT COUNT(*) FROM mesh_keys", [], |row| row.get(0))
        .expect("the table exists")
}

/// The deadline `member`'s store holds, as it is stored.
pub fn stored_deadline(member: &CircleMember) -> Option<String> {
    use rusqlite::OptionalExtension as _;
    store(member)
        .query_row(
            "SELECT value FROM user_settings WHERE key = 'mesh_on_until'",
            [],
            |row| row.get(0),
        )
        .optional()
        .expect("the setting is read")
}

/// What waits in `member`'s hand-off, taken as the engine's owner takes it:
/// each slot with its packet, or `None` for a purge.
pub fn waiting(member: &CircleMember) -> Vec<(u32, Option<Packet>)> {
    (member.session().mesh_handoff().take().into_iter())
        .map(|(slot, op)| match op {
            Op::Offer { packet, .. } => (slot.0, Some(packet)),
            Op::Purge => (slot.0, None),
        })
        .collect()
}

/// A location `member` seals through `driver`.
pub async fn sealed(
    driver: &Publishing<'_, ScriptedFanout>,
    member: &CircleMember,
    group: &GroupId,
) -> Event {
    let outcome = driver
        .seal_location(&member.circle, group, &LocationMessage::new(51.5, -0.12))
        .await
        .expect("the seal runs");
    match outcome.seal {
        LocationSeal::Sealed { event, .. } => *event,
        LocationSeal::Deferred(_) => panic!("premise: the send is sealed"),
    }
}

/// A location `member` seals and sends to relays that take it, and the one
/// packet that send left for the mesh.
pub async fn handed_off(member: &CircleMember, group: &GroupId) -> (Event, Packet) {
    let (transport, outbox) = (ScriptedFanout::default(), Recorder::acking(true));
    let clock = ManualClock::at(0);
    let driver = through(&transport, &outbox, &clock, &DriveMode::Full);
    let event = sealed(&driver, member, group).await;
    let _ = waiting(member);
    assert!(
        matches!(
            driver.publish_location(&member.circle, &event).await,
            LocationPublish::Sent(Ok(_))
        ),
        "premise: the location is sent",
    );
    let slot = member
        .session()
        .mesh_slot_for_test(group)
        .map(|slot| slot.0);
    match &waiting(member)[..] {
        [(at, Some(packet))] if Some(*at) == slot => (event, packet.clone()),
        _ => panic!("the send left no packet, or more than its own, for the mesh"),
    }
}

/// The exporter secret `member` stores for `group` at `epoch`.
pub fn secret_of(member: &CircleMember, group: &GroupId, epoch: u64) -> [u8; 32] {
    (rows(member, group).iter())
        .find(|row| row.0 == epoch)
        .expect("the member holds a key of that epoch")
        .2
}

/// `event` in a packet of `format` under the circle's key of `epoch`, with a
/// nonce of its own: what any member holding that key can make.
pub fn packet_as(
    member: &CircleMember,
    group: &GroupId,
    epoch: u64,
    event: &Event,
    format: Format,
) -> Packet {
    let key = MeshKey::derive(&secret_of(member, group, epoch));
    let parts = parts_of(event, format).expect("an event a packet carries");
    wrap(&key, &parts, &mut OsRng).expect("fits")
}

/// What a member can make of any `kind:445` of its circle: the MLS message
/// `event` carries under the exporter secret `secret`, sealed again under it
/// with a nonce of its own, in an event of the two tags a packet carries —
/// stamped `created_at` and expiring `life_secs` later — signed by a key of
/// its own. It verifies, and peels under `secret`.
pub fn restamped(
    event: &Event,
    routing: &[u8; 32],
    secret: &[u8; 32],
    created_at: u64,
    life_secs: u64,
) -> Event {
    let content = BASE64.decode(&event.content).expect("base64");
    let (nonce, ciphertext) = content.split_at(12);
    let cipher = ChaCha20Poly1305::new(Key::from_slice(secret));
    let mls = cipher
        .decrypt(Nonce::from_slice(nonce), ciphertext)
        .expect("the secret it was sealed under opens it");
    let mut content = [0_u8; 12].to_vec();
    OsRng.fill_bytes(&mut content);
    let ciphertext = cipher
        .encrypt(Nonce::from_slice(&content), mls.as_slice())
        .expect("sealed");
    content.extend(ciphertext);
    let tag = |tag: [&str; 2]| Tag::parse(tag).expect("a tag");
    EventBuilder::new(Kind::Custom(445), BASE64.encode(content))
        .tags([
            tag(["h", &hex::encode(routing)]),
            tag(["expiration", &(created_at + life_secs).to_string()]),
        ])
        .custom_created_at(Timestamp::from_secs(created_at))
        .sign_with_keys(&Keys::generate())
        .expect("signed")
}
