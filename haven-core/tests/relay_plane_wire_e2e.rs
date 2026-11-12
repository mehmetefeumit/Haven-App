//! Every relay plane receives only its own traffic, across a circle's
//! lifecycle, judged on the wire by the one relay-plane judge
//! (`haven_local_relay::planes`, the matrix `haven-core/SECURITY.md` "The
//! relay-plane allow matrix" mirrors).
//!
//! Thirteen in-process relays, one per role, each behind a recording front
//! (`relay::recording_front`); the product is told only the fronts' addresses.
//! Three real engines on their own stores — Alice, the admin; Bob and Carol,
//! her invitees — run the account traffic, the lookups an invite makes, two
//! circles (one drawn from the location pool, one on a relay list that is then
//! changed), locations, a leave, both catch-up planes, the live plane and the
//! profile plane; Alice's relay lists also go to the discovery relay, as the
//! relay-list heal sends them (owner-directed 2026-11-12), and her key package
//! never does. The ground truth is the test's own: who listed which relay
//! and which routing each circle had, with `[added, removed)` in the step
//! counter, a routing recorded at the call that stages it. Every frame a front
//! recorded is judged; the run is clean, every row it drove was admitted
//! somewhere, every front saw a frame, every relay a client dialled is a
//! front, and no log line names a relay, an account or a circle. Then a
//! crossing is planted on each plane in turn, and each must be reported
//! exactly. Last, an invitee whose relay lists steer Alice onto other planes
//! pins what the product does today with such lists.
//!
//! One test, one world: every override it installs is install-once. No wait
//! here is a sleep: each awaits a recorded frame or a product outcome, bounded
//! by a budget scaled for instrumented runs.

mod helpers;

use std::sync::Arc;

use base64::engine::general_purpose::STANDARD as BASE64;
use base64::Engine as _;
use std::time::Duration;

use haven_core::circle::{
    set_location_relays_for_test, CircleConfig, CircleManager, MemberKeyPackage, RelayType,
};
use haven_core::location::LocationMessage;
use haven_core::nostr::mls::types::GroupId;
use haven_core::profile::{
    build_metadata_event, fetch_profiles_assigned, set_profile_relays_for_test, PendingEdits,
    ProfileMetadata,
};
use haven_core::relay::catchup::run_catchup_all_circles;
use haven_core::relay::dial_witness::{dials_cover_exactly, DialWatch};
use haven_core::relay::fanout::{
    disown_for_test, DriveMode, EvolutionStatus, FanoutSend, LeaveStatus, LocationPublish,
    LocationSeal, Publishing, RelayMappedFanout, WallClock,
};
use haven_core::relay::live_sync::{CircleSpec, LiveSyncCore};
use haven_core::relay::maintenance::{
    build_kp_maintenance_events, kp_event_d_tag, own_presence, read_kp_lifetime, OwnEventPresence,
    OwnRelayLists, TrackedKpSlot,
};
use haven_core::relay::recording_front::{RecordedFrame, RecordingFront};
use haven_core::relay::{
    allow_ws_loopback_for_test, build_nip65_relay_list_event, build_relay_list_event,
    set_discovery_relays_for_test, MemberLookup, RelayManager,
};
use haven_local_relay::planes::frame::Frame;
use haven_local_relay::planes::judge::{judge, Class, Finding, Judgement, Observed};
use haven_local_relay::planes::policy::{Plane, Row, Verb};
use haven_local_relay::planes::table::{List, PlaneTable, RelayIx, RelayMatch, RoutingEnd};
use helpers::{assert_no_needles, assert_some_line_from, capture_haven_log, haven_core_lines};
use nostr::prelude::ToBech32 as _;
use nostr::{Alphabet, Event, EventBuilder, Filter, Keys, Kind, SingleLetterTag, Tag, Timestamp};
use nostr_relay_builder::prelude::{MemoryDatabase, MemoryDatabaseOptions, NostrDatabase};
use nostr_relay_builder::{LocalRelay, RelayBuilder};
use tempfile::TempDir;

/// The longest any one awaited frame or outcome may take, unscaled.
const WAIT: Duration = Duration::from_secs(20);

/// The budget a catch-up sweep is given, unscaled, in the seconds the product
/// takes: room for its NIP-77 pass and the engine's convergence deadline.
const SWEEP_SECS: u64 = 30;

/// Scales every budget here for an instrumented build, the way
/// `live_sync_privacy_config_e2e.rs` does. Absent or unparsable means 1.
fn wait_scale() -> u32 {
    std::env::var("HAVEN_TEST_WAIT_SCALE")
        .ok()
        .and_then(|v| v.parse::<u32>().ok())
        .filter(|s| *s >= 1)
        .unwrap_or(1)
}

fn budget() -> Duration {
    WAIT * wait_scale()
}

fn sweep_secs() -> u64 {
    SWEEP_SECS * u64::from(wait_scale())
}

/// `fut`, failing the test with `what` past the budget.
async fn within<T>(what: &str, fut: impl std::future::Future<Output = T>) -> T {
    tokio::time::timeout(budget(), fut)
        .await
        .unwrap_or_else(|_| panic!("{what}: not within the budget"))
}

// ═══════════════════════════════════════════════════════════════════════════
// The world
// ═══════════════════════════════════════════════════════════════════════════

/// The roles, one relay each, in the order the table registers them.
#[derive(Clone, Copy, PartialEq, Eq)]
enum R {
    AInbox,
    AKp,
    Disc,
    P0,
    P1,
    P2,
    LocA,
    LocB,
    LocC,
    BInbox,
    BWrite,
    CInbox,
    CWrite,
}

const ROLES: [R; 13] = [
    R::AInbox,
    R::AKp,
    R::Disc,
    R::P0,
    R::P1,
    R::P2,
    R::LocA,
    R::LocB,
    R::LocC,
    R::BInbox,
    R::BWrite,
    R::CInbox,
    R::CWrite,
];

const fn role_name(role: usize) -> &'static str {
    match role {
        0 => "alice's inbox",
        1 => "alice's key-package relay",
        2 => "discovery",
        3 => "profile 0",
        4 => "profile 1",
        5 => "profile 2",
        6 => "circle A's location relay",
        7 => "circle B's first location relay",
        8 => "circle B's second location relay",
        9 => "bob's inbox",
        10 => "bob's NIP-65 write relay",
        11 => "carol's inbox",
        12 => "carol's NIP-65 write relay",
        _ => "no role",
    }
}

/// One relay: the in-process relay, its store, and the front the product is
/// told about.
struct Relay {
    _server: LocalRelay,
    db: MemoryDatabase,
    front: RecordingFront,
}

impl Relay {
    async fn run() -> Self {
        let db = MemoryDatabase::with_opts(MemoryDatabaseOptions {
            events: true,
            max_events: None,
        });
        // `nostr-relay-builder` picks a free port when the relay is built and
        // binds it only when it runs, so a socket opened in between can take
        // it: that port is lost, and a fresh one is picked.
        let mut tries = 0;
        let relay = loop {
            let relay = LocalRelay::new(RelayBuilder::default().database(db.clone()));
            let started = relay.run().await;
            if let Err(nostr_relay_builder::Error::IO(error)) = &started {
                if error.kind() == std::io::ErrorKind::AddrInUse && tries < 8 {
                    tries += 1;
                    continue;
                }
            }
            assert!(started.is_ok(), "an in-process relay did not start");
            break relay;
        };
        let front = RecordingFront::start(&relay.url().await.to_string());
        Self {
            _server: relay,
            db,
            front,
        }
    }

    /// Writes `events` straight into the store — an indexer's copy, or a pile
    /// of junk — so no front records them.
    async fn seed(&self, events: &[Event]) {
        for event in events {
            assert!(
                self.db.save_event(event).await.expect("seed").is_success(),
                "the relay must hold every seeded event"
            );
        }
    }
}

struct World {
    relays: Vec<Relay>,
    /// Per step, each front's frame count when it began.
    marks: Vec<Vec<usize>>,
    table: PlaneTable,
}

impl World {
    async fn build() -> Self {
        let mut relays = Vec::new();
        for _ in ROLES {
            relays.push(Relay::run().await);
        }
        let mut table = PlaneTable::new(RelayMatch::Authority);
        for relay in &relays {
            table
                .add_relay(relay.front.url())
                .expect("a front's address is a relay url");
        }
        let marks = vec![vec![0; relays.len()]];
        Self {
            relays,
            marks,
            table,
        }
    }

    fn url(&self, role: R) -> String {
        self.relays[role as usize].front.url().to_owned()
    }

    fn urls(&self) -> Vec<String> {
        ROLES.iter().map(|role| self.url(*role)).collect()
    }

    fn front(&self, role: R) -> &RecordingFront {
        &self.relays[role as usize].front
    }

    const fn ix(role: R) -> RelayIx {
        RelayIx(role as u32)
    }

    /// The step now running.
    fn step(&self) -> u64 {
        u64::try_from(self.marks.len() - 1).unwrap_or(u64::MAX)
    }

    /// Begins the next step: what a front records from here on was sent in it.
    fn next(&mut self) -> u64 {
        self.marks.push(
            self.relays
                .iter()
                .map(|relay| relay.front.frames().len())
                .collect(),
        );
        self.step()
    }

    /// Every recorded frame with what the judge needs of it, in step order and
    /// each front's arrival order; every event a front saw is indexed.
    fn recorded(&mut self) -> Vec<(RelayIx, u64, u64, Frame, RecordedFrame)> {
        let mut out = Vec::new();
        for (role, relay) in self.relays.iter().enumerate() {
            for (n, recorded) in relay.front.frames().into_iter().enumerate() {
                let at = self
                    .marks
                    .iter()
                    .rposition(|mark| mark[role] <= n)
                    .unwrap_or(0);
                let conn = (u64::try_from(role).unwrap_or(u64::MAX) << 32)
                    | u64::try_from(recorded.conn).unwrap_or(u64::MAX);
                let frame = Frame::parse(&recorded.text);
                out.push((
                    RelayIx(u32::try_from(role).unwrap_or(u32::MAX)),
                    conn,
                    u64::try_from(at).unwrap_or(u64::MAX),
                    frame,
                    recorded,
                ));
            }
        }
        out.sort_by_key(|(relay, _, at, _, _)| (*at, *relay));
        for (_, _, _, _, recorded) in &out {
            if let Some(event) = sent_event(recorded) {
                index(&mut self.table, &event);
            }
        }
        out
    }

    fn judge(&mut self) -> Judgement {
        let recorded = self.recorded();
        judge(
            &self.table,
            recorded.iter().map(|(relay, conn, at, frame, _)| Observed {
                relay: *relay,
                conn: *conn,
                sender: None,
                at: *at,
                frame,
            }),
        )
        .unwrap_or_else(|unusable| panic!("the table is unusable: {unusable:?}"))
    }
}

/// The event an `EVENT` frame carried.
fn sent_event(recorded: &RecordedFrame) -> Option<Event> {
    let value: serde_json::Value = serde_json::from_str(&recorded.text).ok()?;
    if value.get(0)?.as_str()? != "EVENT" {
        return None;
    }
    serde_json::from_value(value.get(1)?.clone()).ok()
}

fn index(table: &mut PlaneTable, event: &Event) {
    let h = event
        .tags
        .iter()
        .find(|tag| tag.as_slice().first().map(String::as_str) == Some("h"))
        .and_then(|tag| tag.as_slice().get(1).cloned());
    table.index_event(&event.id.to_hex(), event.kind.as_u16(), h.as_deref());
}

/// A finding as a test compares it: where, what verb, which row, what class.
type Seen = (u32, Verb, Option<Row>, Class);

const fn seen(finding: &Finding) -> Seen {
    (finding.relay.0, finding.verb, finding.row, finding.class)
}

/// The findings, by role and row id: never a value (Security Rule 15).
fn render(findings: &[Seen]) -> String {
    findings
        .iter()
        .map(|(relay, verb, row, class)| {
            format!(
                "{} {} on {} ({})",
                class.name(),
                verb.name(),
                role_name(*relay as usize),
                row.map_or("no row", Row::id),
            )
        })
        .collect::<Vec<_>>()
        .join("; ")
}

// ═══════════════════════════════════════════════════════════════════════════
// The accounts
// ═══════════════════════════════════════════════════════════════════════════

struct Device {
    circle: Arc<CircleManager>,
    keys: Keys,
    pool: RelayManager,
    _dir: TempDir,
}

impl Device {
    fn new() -> Self {
        let dir = TempDir::new().expect("temp dir");
        let keys = Keys::generate();
        let circle = Arc::new(CircleManager::new_unencrypted(dir.path(), &keys).expect("circle"));
        Self {
            circle,
            keys,
            pool: RelayManager::new(),
            _dir: dir,
        }
    }

    fn hex(&self) -> String {
        self.keys.public_key().to_hex()
    }

    /// Its own lists, as its relay settings hold them.
    fn lists(&self, inbox: &str, key_packages: &str) {
        self.circle
            .add_user_relay(inbox, RelayType::Inbox)
            .expect("the inbox row");
        self.circle
            .add_user_relay(key_packages, RelayType::KeyPackage)
            .expect("the key-package row");
    }

    async fn key_package(&self, relays: &str) -> Event {
        build_kp_maintenance_events(
            self.circle.session(),
            &self.keys,
            &[relays.to_owned()],
            None,
            None,
        )
        .await
        .expect("a key package")
        .event
    }

    /// The relay lists it publishes, built as the product builds them.
    fn relay_lists(&self, inbox: &[String], write: &[String]) -> [Event; 2] {
        [
            build_relay_list_event(&self.keys, RelayType::Inbox, inbox, None).expect("10050"),
            build_nip65_relay_list_event(&self.keys, write, None).expect("10002"),
        ]
    }

    /// The product's driver over this device's publish pool and `transport`.
    fn driver<'a, T: FanoutSend>(&'a self, transport: &'a T) -> Publishing<'a, T> {
        Publishing {
            fanout: transport,
            publisher: &self.pool,
            clock: &WallClock,
            deadline_ms: None,
            mode: &DriveMode::Full,
        }
    }

    /// Looks `who` up the way the app's invite does
    /// (`RelayManagerFfi::fetch_member_keypackage`): both relay lists from the
    /// discovery plane, then the key package from the NIP-65 write relays,
    /// falling back to discovery.
    async fn look_up(&self, who: &str, target: Option<&GroupId>) -> MemberKeyPackage {
        let admit = self
            .circle
            .session()
            .key_package_admission_rule(target)
            .await
            .expect("the admission rule");
        match RelayManager::lookup_member_for_invite(who, &admit)
            .await
            .expect("the key-package lookup")
        {
            MemberLookup::Found(member) => *member,
            MemberLookup::NotFound | MemberLookup::Incomplete => {
                panic!("a key package is found")
            }
        }
    }

    /// Fetches its gift wraps from `inbox` as the poll does, and joins every
    /// circle they invite it to.
    async fn join_from(&self, inbox: &str) -> usize {
        let wraps = self
            .pool
            .fetch_events(
                Filter::new()
                    .kind(Kind::GiftWrap)
                    .pubkey(self.keys.public_key())
                    .limit(1000),
                &[inbox.to_owned()],
                Some(budget()),
            )
            .await
            .expect("the inbox answers");
        for wrap in &wraps {
            self.circle
                .process_gift_wrapped_invitation(&self.keys, wrap)
                .await
                .expect("the invitation is held");
            self.circle
                .accept_invitation(&wrap.id)
                .await
                .expect("the invitation is accepted");
        }
        wraps.len()
    }

    async fn epoch(&self, group: &GroupId) -> u64 {
        self.circle.group_epoch(group).await.expect("an epoch")
    }

    /// Seals a location for `group` and sends it through `transport`.
    async fn share<T: FanoutSend>(&self, transport: &T, group: &GroupId) -> Event {
        let driver = self.driver(transport);
        let sealed = driver
            .seal_location(&self.circle, group, &LocationMessage::new(48.85, 2.35))
            .await
            .expect("the seal runs");
        let LocationSeal::Sealed { event, .. } = sealed.seal else {
            panic!("a location the circle should take was deferred");
        };
        assert!(
            matches!(
                driver.publish_location(&self.circle, &event).await,
                LocationPublish::Sent(Ok(_))
            ),
            "a location was not acknowledged",
        );
        *event
    }

    fn engine(&self) -> LiveSyncCore {
        LiveSyncCore::new_local(
            Arc::clone(&self.circle),
            self.keys.public_key(),
            Arc::new(RelayManager::new()),
        )
    }
}

fn spec(h: [u8; 32], relays: &[String]) -> CircleSpec {
    CircleSpec {
        group_id_hex: hex::encode(h),
        relays: relays.to_vec(),
    }
}

/// How many of `frames` have the verb `verb` and a first filter carrying
/// `key`.
fn count(frames: &[RecordedFrame], verb: &str, key: &str) -> usize {
    frames
        .iter()
        .filter(|frame| {
            serde_json::from_str::<serde_json::Value>(&frame.text).is_ok_and(|value| {
                value.get(0).and_then(serde_json::Value::as_str) == Some(verb)
                    && value.get(2).is_some_and(|filter| filter.get(key).is_some())
            })
        })
        .count()
}

/// `count`-many `kind:445`s dated `secs`, each under its own key, carrying two
/// `h` tags: Haven's screen refuses each before authentication.
fn junk(h: &str, count: usize, secs: u64) -> Vec<Event> {
    (0..count)
        .map(|i| {
            EventBuilder::new(Kind::Custom(445), format!("anVuaw-{i}"))
                .tags(vec![
                    Tag::parse(["h", h]).expect("a tag"),
                    Tag::parse(["h", &hex::encode([0x11u8; 32])]).expect("a tag"),
                ])
                .custom_created_at(Timestamp::from(secs))
                .sign_with_keys(&Keys::generate())
                .expect("junk signs")
        })
        .collect()
}

/// What the relay-list heal sends `relay` for `lists`: the probe of the
/// author's own list, then the list.
async fn heal_onto(device: &Device, relay: &str, lists: &[&Event]) {
    for event in lists {
        let probe = Filter::new()
            .kind(event.kind)
            .author(device.keys.public_key())
            .limit(4);
        device
            .pool
            .fetch_events(probe, &[relay.to_owned()], Some(budget()))
            .await
            .expect("the heal's probe");
        device
            .pool
            .publish_event(event, &[relay.to_owned()])
            .await
            .expect("the relay list is published");
    }
}

/// The rows the lifecycle drives, each of which must be admitted at least
/// once: a row nobody sent would pass vacuously.
const DRIVEN: [Row; 15] = [
    Row::Ev445Commit,
    Row::Ev445Location,
    Row::Ev1059,
    Row::Ev30443,
    Row::Ev10002,
    Row::Ev10050,
    Row::Ev0,
    Row::Req445H,
    Row::Req445Ids,
    Row::Req1059P,
    Row::Req30443A,
    Row::Req10002A,
    Row::Req10050A,
    Row::Req0A,
    Row::Neg445H,
];

/// The clean judgement's own assertions: no finding, every driven row
/// admitted, the key-package lookup both on an invitee's write relay and on
/// discovery, both of an account's relay lists on discovery, every front
/// reached.
fn assert_clean(world: &mut World) {
    let judgement = world.judge();
    let findings: Vec<Seen> = judgement.findings.iter().map(seen).collect();
    assert!(
        findings.is_empty(),
        "the lifecycle crossed a plane: {}",
        render(&findings)
    );
    let hit = |row: Row, relay: Option<R>| {
        judgement.hits.iter().any(|((ix, r, _), n)| {
            *r == row && *n > 0 && relay.is_none_or(|role| *ix == World::ix(role))
        })
    };
    for row in DRIVEN {
        assert!(
            hit(row, None),
            "row {} was never admitted: the lifecycle did not drive it",
            row.id()
        );
    }
    assert!(
        hit(Row::Req30443A, Some(R::BWrite)) && hit(Row::Req30443A, Some(R::Disc)),
        "a key package was not looked up both on an invitee's write relay and on discovery",
    );
    assert!(
        hit(Row::Ev10002, Some(R::Disc)) && hit(Row::Ev10050, Some(R::Disc)),
        "an account's relay lists did not both reach discovery",
    );
    for role in ROLES {
        assert!(
            !world.front(role).frames().is_empty(),
            "{} received no frame: a dead plane passes any judgement",
            role_name(role as usize),
        );
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// The test
// ═══════════════════════════════════════════════════════════════════════════

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn every_relay_plane_receives_only_its_own_traffic_across_a_circle_lifecycle() {
    let _ = allow_ws_loopback_for_test();
    let Ok(watch) = DialWatch::arm() else {
        panic!("this binary arms the dial witness once");
    };
    let mut needles: Vec<String> = Vec::new();
    let lines = capture_haven_log(Box::pin(lifecycle_then_plants(&watch, &mut needles))).await;
    let haven = haven_core_lines(&lines);
    assert_some_line_from(&haven, "haven_core");
    let needles: Vec<&str> = needles.iter().map(String::as_str).collect();
    assert_no_needles(&haven, &needles);
}

#[allow(clippy::too_many_lines)]
async fn lifecycle_then_plants(watch: &DialWatch, needles: &mut Vec<String>) {
    let mut w = World::build().await;
    set_discovery_relays_for_test(vec![w.url(R::Disc)]).expect("the discovery override");
    set_profile_relays_for_test(vec![w.url(R::P0), w.url(R::P1), w.url(R::P2)])
        .expect("the profile override");
    set_location_relays_for_test(vec![w.url(R::LocA)]).expect("the location override");

    let (alice, bob, carol) = (Device::new(), Device::new(), Device::new());
    alice.lists(&w.url(R::AInbox), &w.url(R::AKp));
    bob.lists(&w.url(R::BInbox), &w.url(R::BWrite));
    carol.lists(&w.url(R::CInbox), &w.url(R::CWrite));
    needles.extend(w.urls());
    for device in [&alice, &bob, &carol] {
        needles.push(device.hex());
        needles.push(device.keys.public_key().to_bech32().expect("an npub"));
    }

    // Step 0, the ground truth before anything is sent: each account's own
    // lists; the invitees' lists as their indexer copies name them; the
    // shared planes. An account's own list is also its invitee view.
    {
        let t = &mut w.table;
        for (device, inbox, write) in [
            (&alice, R::AInbox, R::AKp),
            (&bob, R::BInbox, R::BWrite),
            (&carol, R::CInbox, R::CWrite),
        ] {
            let pk = device.hex();
            t.add_account(&pk);
            t.add(List::OwnInbox(&pk), World::ix(inbox), 0);
            t.add(List::OwnKeyPackage(&pk), World::ix(write), 0);
        }
        for (device, inbox, write) in [(&bob, R::BInbox, R::BWrite), (&carol, R::CInbox, R::CWrite)]
        {
            let pk = device.hex();
            t.add(List::InviteeInbox(&pk), World::ix(inbox), 0);
            t.add(List::InviteeNip65Write(&pk), World::ix(write), 0);
        }
        t.add(List::Discovery, World::ix(R::Disc), 0);
        for p in [R::P0, R::P1, R::P2] {
            t.add(List::Profile, World::ix(p), 0);
        }
        assert!(
            t.declare_overlap(Plane::OwnInbox, Plane::InviteeInbox)
                && t.declare_overlap(Plane::OwnKeyPackage, Plane::InviteeNip65Write),
            "an invitee who is an account of the run shares its own lists",
        );
    }
    // The indexer's copies: Bob's and Carol's lists, and Carol's key package,
    // which her own write relay never got.
    let carol_kp = carol.key_package(&w.url(R::CWrite)).await;
    let mut indexed = Vec::new();
    indexed.extend(bob.relay_lists(&[w.url(R::BInbox)], &[w.url(R::BWrite)]));
    indexed.extend(carol.relay_lists(&[w.url(R::CInbox)], &[w.url(R::CWrite)]));
    indexed.push(carol_kp);
    w.relays[R::Disc as usize].seed(&indexed).await;
    for event in &indexed {
        index(&mut w.table, event);
    }

    // Step 1: each account's own traffic on its own lists. Bob's key package
    // to his key-package relay; Alice's key package and relay lists, and the
    // relay settings check of her own relays and the lookup relay.
    w.next();
    let bob_kp = bob.key_package(&w.url(R::BWrite)).await;
    bob.pool
        .publish_event(&bob_kp, &[w.url(R::BWrite)])
        .await
        .expect("bob's key package is published");
    let alice_kp = alice.key_package(&w.url(R::AKp)).await;
    let [alice_10050, alice_10002] = alice.relay_lists(&[w.url(R::AInbox)], &[w.url(R::AKp)]);
    for (event, relay) in [
        (&alice_kp, R::AKp),
        (&alice_10002, R::AKp),
        (&alice_10050, R::AInbox),
    ] {
        alice
            .pool
            .publish_event(event, &[w.url(relay)])
            .await
            .expect("alice's own event is published");
    }
    // Her relay lists go to the discovery relay too, after the heal's probe
    // there; her key package does not (plant 6 below).
    Box::pin(heal_onto(
        &alice,
        &w.url(R::Disc),
        &[&alice_10002, &alice_10050],
    ))
    .await;
    let (slot, kp_id) = (
        kp_event_d_tag(&alice_kp).expect("a slot"),
        alice_kp.id.to_hex(),
    );
    let package = BASE64
        .decode(&alice_kp.content)
        .expect("the 30443 content is base64");
    let (inbox, key_packages, lookup) = ([w.url(R::AInbox)], [w.url(R::AKp)], [w.url(R::Disc)]);
    let rows = Box::pin(own_presence(
        &alice.pool,
        &alice.keys.public_key(),
        &OwnRelayLists {
            inbox: &inbox,
            key_package: &key_packages,
            lookup: &lookup,
        },
        Some(TrackedKpSlot {
            d_tag: &slot,
            event_id: &kp_id,
            created_at: alice_kp.created_at.as_secs(),
            adopted: false,
            replacement_owed: false,
        }),
        read_kp_lifetime(&package),
    ))
    .await;
    assert!(
        rows[0].inbox_relay_list == OwnEventPresence::Current
            && rows[1].key_package == OwnEventPresence::Current
            && rows[1].relay_list == OwnEventPresence::Current
            && rows[2].relay_list == OwnEventPresence::Current
            && rows[2].inbox_relay_list == OwnEventPresence::Current,
        "the relay settings check does not find what was just published",
    );

    // Step 2: Alice looks her invitees up, as an invite does.
    w.next();
    let bob_member = alice.look_up(&bob.hex(), None).await;
    assert!(
        bob_member.inbox_relays == [w.url(R::BInbox)],
        "premise: the lookup read bob's inbox list",
    );

    // Step 3: circle A drawn from the location pool, circle B on a list Alice
    // names, each with Bob. A routing is recorded at the call that stages it.
    let step = w.next();
    let alice_transport = alice.pool.fanout_transport();
    let driver = alice.driver(&alice_transport);
    let a = driver
        .create_circle(
            &alice.circle,
            &alice.keys,
            vec![bob_member.clone()],
            &CircleConfig::new("A"),
        )
        .await
        .expect("circle A is created")
        .circle;
    let b = driver
        .create_circle(
            &alice.circle,
            &alice.keys,
            vec![bob_member],
            &CircleConfig::new("B").with_relays([w.url(R::LocB)]),
        )
        .await
        .expect("circle B is created")
        .circle;
    assert!(
        a.relays == [w.url(R::LocA)] && b.relays == [w.url(R::LocB)],
        "premise: A was drawn from the location pool and B kept the list it was given",
    );
    let (a_h, b_h) = (hex::encode(a.nostr_group_id), hex::encode(b.nostr_group_id));
    needles.extend([a_h.clone(), b_h.clone()]);
    w.table.add_routing(&a_h, World::ix(R::LocA), step);
    w.table.add_routing(&b_h, World::ix(R::LocB), step);
    let (a_gid, b_gid) = (a.mls_group_id.clone(), b.mls_group_id.clone());
    needles.extend([hex::encode(a_gid.as_slice()), hex::encode(b_gid.as_slice())]);

    // Step 4: Bob polls his inbox and joins both; Alice's and Bob's live
    // planes subscribe to both circles and to their inboxes. Bob's then
    // stops, and stays stopped until his catch-up: what he misses is what his
    // NIP-77 pass must fetch by id.
    w.next();
    assert_eq!(
        bob.join_from(&w.url(R::BInbox)).await,
        2,
        "premise: bob joins both circles"
    );
    let specs = [
        spec(a.nostr_group_id, &a.relays),
        spec(b.nostr_group_id, &b.relays),
    ];
    let alice_engine = alice.engine();
    alice_engine
        .start(&specs, &[w.url(R::AInbox)])
        .await
        .expect("alice's live plane starts");
    let bob_engine = bob.engine();
    bob_engine
        .start(&specs, &[w.url(R::BInbox)])
        .await
        .expect("bob's live plane starts");
    within(
        "both live planes subscribe to circle A",
        w.front(R::LocA).wait_for(|f| count(f, "REQ", "#h") >= 2),
    )
    .await;
    within(
        "both live planes subscribe to circle B",
        w.front(R::LocB).wait_for(|f| count(f, "REQ", "#h") >= 2),
    )
    .await;
    within(
        "alice's live plane subscribes to her inbox",
        w.front(R::AInbox).wait_for(|f| count(f, "REQ", "#p") >= 1),
    )
    .await;
    within(
        "bob's live plane subscribes to his inbox",
        w.front(R::BInbox).wait_for(|f| count(f, "REQ", "#p") >= 2),
    )
    .await;
    let _ = bob_engine.stop().await;

    // Step 5: Carol, whose key package only the discovery plane holds, is
    // looked up and invited to both circles, and joins from her inbox.
    w.next();
    for gid in [&a_gid, &b_gid] {
        let carol_member = alice.look_up(&carol.hex(), Some(gid)).await;
        assert!(
            carol_member.inbox_relays == [w.url(R::CInbox)],
            "premise: the lookup read carol's inbox list",
        );
        let added = driver
            .add_members(&alice.circle, gid, &[carol_member])
            .await
            .expect("carol is invited");
        assert!(
            added.status == EvolutionStatus::Confirmed && added.welcomes_sent == 1,
            "an invitation was not acknowledged",
        );
    }
    assert_eq!(
        carol.join_from(&w.url(R::CInbox)).await,
        2,
        "premise: carol joins both circles"
    );

    // Step 6: locations in both circles, Bob's plane stopped.
    w.next();
    let carol_transport = carol.pool.fanout_transport();
    let alice_in_a = alice.share(&alice_transport, &a_gid).await;
    let alice_in_b = alice.share(&alice_transport, &b_gid).await;
    let carol_in_a = carol.share(&carol_transport, &a_gid).await;
    needles.extend([alice_in_a.id, alice_in_b.id, carol_in_a.id].map(|id| id.to_hex()));

    // Step 7: circle B moves to another relay; the move's commit goes to the
    // routing it leaves, which stays kept, and the next location to the new.
    let step = w.next();
    w.table.add_routing(&b_h, World::ix(R::LocC), step);
    let moved = driver
        .update_relays(&alice.circle, &b_gid, &[w.url(R::LocC)])
        .await
        .expect("circle B's relays change");
    assert!(
        moved.status == EvolutionStatus::Confirmed,
        "the relay change was not acknowledged"
    );
    w.table.retire_routing(
        &b_h,
        World::ix(R::LocB),
        RoutingEnd {
            removed: step,
            stands_until: None,
            kept_until: None,
            // No location may reach the routing B leaves from here on: B's one
            // earlier location (step 6) was acknowledged before this step, a
            // location goes once per relay, and nobody else shares in B. A
            // seal instant would admit one sealed in the change's second.
            left_at_secs: None,
        },
    );
    needles.push(alice.share(&alice_transport, &b_gid).await.id.to_hex());

    // Step 8: Carol catches up and applies the move: a peer commit is held for
    // MDK's quiescence window (tracker T-CONVERGENCE-CLOCK) before it applies,
    // so the wall clock has crossed the second Alice's location in A was
    // sealed in — the second step 9 buries it under.
    w.next();
    let _ = run_catchup_all_circles(&carol.circle, &carol.pool, sweep_secs()).await;
    assert!(
        carol.epoch(&b_gid).await == alice.epoch(&b_gid).await,
        "premise: carol's catch-up applied the relay change",
    );
    let buried_at = alice_in_a.created_at.as_secs() + 1;
    assert!(
        Timestamp::now().as_secs() >= buried_at,
        "premise: a peer commit applied after the location was sealed, so its second has passed",
    );

    // Step 9: everything Bob missed in circle A lies under a page of junk in
    // the second above it, which fills the pager's page: his NIP-77 pass is
    // what finds it, and he asks the relay for it by id.
    w.next();
    let pile = junk(&a_h, 500, buried_at);
    w.relays[R::LocA as usize].seed(&pile).await;
    for event in &pile {
        index(&mut w.table, event);
    }
    let _ = run_catchup_all_circles(&bob.circle, &bob.pool, sweep_secs()).await;
    assert!(
        bob.epoch(&a_gid).await == alice.epoch(&a_gid).await
            && bob.epoch(&b_gid).await == alice.epoch(&b_gid).await,
        "premise: bob's catch-up brought him to both circles' epochs",
    );

    // Step 10: Bob shares in A and leaves B.
    w.next();
    let bob_transport = bob.pool.fanout_transport();
    bob.share(&bob_transport, &a_gid).await;
    let left = bob
        .driver(&bob_transport)
        .leave(&bob.circle, &b_gid, &bob.keys.public_key())
        .await
        .expect("bob's leave runs");
    assert!(
        left.status == LeaveStatus::Proposed,
        "bob's leave was not proposed"
    );

    // Step 11: Alice saves and syncs her profile; Bob reads it from his
    // profile pool.
    w.next();
    let now = i64::try_from(Timestamp::now().as_secs()).expect("now");
    alice
        .circle
        .stage_own_profile_edits(
            &alice.hex(),
            &PendingEdits {
                display_name: Some("Quiet Wanderer".to_owned()),
                ..PendingEdits::default()
            },
            now,
        )
        .expect("the edit is staged");
    let synced = alice
        .circle
        .sync_own_profile(&alice.keys, || now)
        .await
        .expect("the sync runs");
    assert!(
        synced.outcome == haven_core::circle::ProfileSyncOutcome::Published
            && !synced.still_pending,
        "the profile did not reach the whole profile pool"
    );
    let read = fetch_profiles_assigned(
        &bob.pool,
        &[(alice.keys.public_key(), 0)],
        &bob.circle.profile_relay_salt().expect("bob's salt"),
        &bob.circle
            .usable_profile_relays()
            .expect("bob's profile pool"),
        now,
    )
    .await
    .expect("bob's profile read");
    assert!(
        read.resolved.len() == 1
            && read.resolved[0].metadata.display_name() == Some("Quiet Wanderer"),
        "bob did not read alice's profile",
    );

    // Step 12: the live plane stops; nothing else is sent.
    w.next();
    let _ = alice_engine.stop().await;

    // The clean judgement.
    assert_clean(&mut w);
    if let Err(message) = dials_cover_exactly(&watch.dials(), &w.urls()) {
        panic!("{message}");
    }

    // ── The plants: each a crossing of one plane, reported exactly ──────────
    let mut expected: Vec<Seen> = Vec::new();
    let mut plant = |w: &mut World, ordinal: usize, what: &str, also: &[Seen]| {
        expected.extend_from_slice(also);
        expected.sort();
        let judgement = w.judge();
        let mut found: Vec<Seen> = judgement.findings.iter().map(seen).collect();
        found.sort();
        assert!(
            found == expected,
            "plant {ordinal} ({what}): expected [{}], the judge reported [{}]",
            render(&expected),
            render(&found),
        );
    };

    // Plant 1: Alice's kind 0 on circle A's location relay.
    w.next();
    let kind0 = build_metadata_event(
        &alice.keys,
        &ProfileMetadata::from_metadata(nostr::Metadata::new().display_name("Quiet Wanderer")),
        None,
    )
    .expect("a kind 0");
    alice
        .pool
        .publish_event(&kind0, &[w.url(R::LocA)])
        .await
        .expect("the relay takes it");
    plant(
        &mut w,
        1,
        "a profile on a location relay",
        &[(
            R::LocA as u32,
            Verb::Event,
            Some(Row::Ev0),
            Class::CrossedEvent,
        )],
    );

    // Plant 2: a location of A, sent by the product's own fanout transport
    // behind a map that turns A's relay into Alice's inbox.
    w.next();
    let (loc_a, a_inbox) = (w.url(R::LocA), w.url(R::AInbox));
    let mapped = RelayMappedFanout::new(alice.pool.fanout_transport(), move |target| {
        if target == loc_a {
            a_inbox.clone()
        } else {
            target.to_owned()
        }
    });
    alice.share(&mapped, &a_gid).await;
    plant(
        &mut w,
        2,
        "a location on an inbox",
        &[(
            R::AInbox as u32,
            Verb::Event,
            Some(Row::Ev445Location),
            Class::CrossedEvent,
        )],
    );

    // Plant 3: Carol's Welcome on Bob's inbox. The driver no longer owns it
    // (its record ended on the acknowledgement); the disown makes that so
    // whatever the record's state, so the plain publish takes it.
    w.next();
    let carol_welcome = w
        .front(R::CInbox)
        .frames()
        .iter()
        .find_map(|frame| sent_event(frame).filter(|event| event.kind == Kind::GiftWrap))
        .expect("carol's welcome was recorded");
    disown_for_test(&carol_welcome.id);
    alice
        .pool
        .publish_event(&carol_welcome, &[w.url(R::BInbox)])
        .await
        .expect("the relay takes it");
    plant(
        &mut w,
        3,
        "a welcome on another invitee's inbox",
        &[(
            R::BInbox as u32,
            Verb::Event,
            Some(Row::Ev1059),
            Class::CrossedEvent,
        )],
    );

    // Plant 4: circle A's traffic asked of a profile relay.
    w.next();
    let _ = alice
        .pool
        .fetch_events(
            Filter::new()
                .kind(Kind::Custom(445))
                .custom_tag(SingleLetterTag::lowercase(Alphabet::H), a_h.clone()),
            &[w.url(R::P0)],
            Some(budget()),
        )
        .await
        .expect("the relay answers");
    plant(
        &mut w,
        4,
        "a circle's REQ on a profile relay",
        &[(
            R::P0 as u32,
            Verb::Req,
            Some(Row::Req445H),
            Class::CrossedRequest,
        )],
    );

    // Plant 5: Bob's key package asked of Alice's inbox.
    w.next();
    let _ = alice
        .pool
        .fetch_events(
            Filter::new()
                .kind(Kind::Custom(30443))
                .author(bob.keys.public_key()),
            &[w.url(R::AInbox)],
            Some(budget()),
        )
        .await
        .expect("the relay answers");
    plant(
        &mut w,
        5,
        "a key-package lookup on an inbox",
        &[(
            R::AInbox as u32,
            Verb::Req,
            Some(Row::Req30443A),
            Class::CrossedRequest,
        )],
    );

    // Plant 6: Alice's key package on the discovery relay, which takes her
    // relay lists and nothing else of hers.
    w.next();
    Box::pin(alice.pool.publish_event(&alice_kp, &[w.url(R::Disc)]))
        .await
        .expect("the relay takes it");
    plant(
        &mut w,
        6,
        "a key package on discovery",
        &[(
            R::Disc as u32,
            Verb::Event,
            Some(Row::Ev30443),
            Class::CrossedEvent,
        )],
    );

    // Plant 7, last: an invitee whose lists steer an invite. Dave's inbox
    // list names circle A's location relay and a profile relay ahead of
    // Alice's inbox (the seed every install shares, so that overlap is
    // declared), and his NIP-65 write set names the profile relay; his ground
    // truth is the shared seed alone. Today the product follows the lists —
    // the recorded product finding "Welcome/lookup steering" (PLAN_v2 §4
    // finding 1; owner decision OQ-1: no product change in this work): the
    // key-package lookup asks the profile relay, and the Welcome goes to the
    // first relay of the list, the location relay, whose acknowledgement ends
    // its delivery. When the drop rule lands, this set becomes empty: the
    // lookup falls to discovery and the Welcome goes to the seed inbox alone.
    let step = w.next();
    let dave = Device::new();
    needles.push(dave.hex());
    let dave_kp = dave.key_package(&w.url(R::P0)).await;
    let mut steered = vec![dave_kp];
    steered.extend(dave.relay_lists(
        &[w.url(R::LocA), w.url(R::P0), w.url(R::AInbox)],
        &[w.url(R::P0)],
    ));
    w.relays[R::Disc as usize].seed(&steered).await;
    for event in &steered {
        index(&mut w.table, event);
    }
    w.table
        .add(List::InviteeInbox(&dave.hex()), World::ix(R::AInbox), step);
    w.table.add(
        List::InviteeNip65Write(&dave.hex()),
        World::ix(R::AKp),
        step,
    );
    let dave_member = alice.look_up(&dave.hex(), Some(&a_gid)).await;
    let invited = driver
        .add_members(&alice.circle, &a_gid, &[dave_member])
        .await
        .expect("dave's invitation runs");
    assert!(
        invited.status == EvolutionStatus::Confirmed && invited.welcomes_sent == 1,
        "premise: dave's invitation was acknowledged",
    );
    plant(
        &mut w,
        7,
        "an invitee's lists steering the invite",
        &[
            (
                R::P0 as u32,
                Verb::Req,
                Some(Row::Req30443A),
                Class::CrossedRequest,
            ),
            (
                R::LocA as u32,
                Verb::Event,
                Some(Row::Ev1059),
                Class::CrossedEvent,
            ),
        ],
    );
}
