//! A relay that holds no key cannot make a device lose a group message, a
//! commit or an invitation by forging a copy of it.
//!
//! A kind-445 a relay rewrites is not readable and not believed — the MLS layer
//! sees to that. What a forgery could do instead is take the genuine event's
//! place: every id-keyed memory between the socket and the group state (the
//! pager's seen set, the engine's seen set and its stored deferred row, the
//! refused-object ledger) recorded the forgery's verdict under the genuine id,
//! and the genuine event then read as a repeat (Security Rule 12). The catch-up
//! sweep, the refused-object redelivery and both live planes are driven here
//! against real MLS circles; every test was red, in at least one of its
//! shapes, before Haven verified each relay event itself (`relay::verified`).
//!
//! No test waits on time: a sweep ends on its relays' `EOSE`, a live plane is
//! read after the engine's own backlog settle.

use std::sync::{Arc, OnceLock};

use haven_core::circle::{
    default_relays, set_default_relays_for_test, CircleConfig, CircleManager, MemberKeyPackage,
};
use haven_core::location::LocationMessage;
use haven_core::nostr::mls::types::GroupId;
use haven_core::nostr::mls::{REFETCH_SPACING_BASE_SECS, REFETCH_SPACING_CAP_SECS};
use haven_core::profile::{profile_relay_pool_default, set_profile_relays_for_test};
use haven_core::relay::catchup::{run_catchup_all_circles, run_refused_refetch};
use haven_core::relay::live_sync::{BacklogOutcome, CircleSpec, LiveSyncCore, LiveSyncEvent};
use haven_core::relay::maintenance::build_kp_maintenance_events;
use haven_core::relay::scripted_relay::{Frame, ScriptedRelay};
use haven_core::relay::{
    discovery_relays, normalize_relay_url, set_discovery_relays_for_test, RelayManager,
};
use nostr::{Event, EventBuilder, Filter, JsonUtil as _, Keys, Kind, Tag};
use tempfile::TempDir;
use tokio::sync::broadcast::error::TryRecvError;

mod helpers;
use helpers::{assert_no_needles, assert_some_line_from, capture_haven_log, haven_core_lines};

/// Alice (admin) and Bob, real co-members with a store each, in a circle whose
/// relay list is the test's.
struct Circle {
    alice: Arc<CircleManager>,
    alice_keys: Keys,
    bob: Arc<CircleManager>,
    bob_keys: Keys,
    mls_group_id: GroupId,
    nostr_group_id: [u8; 32],
    _dirs: [TempDir; 2],
}

/// Alice creates the circle and invites Bob: the circle, and the gift wrap Bob
/// has yet to open.
async fn invite(relays: Vec<String>) -> (Circle, Event) {
    let bob_dir = TempDir::new().expect("temp dir");
    let bob_keys = Keys::generate();
    let bob = CircleManager::new_unencrypted(bob_dir.path(), &bob_keys).expect("bob opens");
    let key_package_event = build_kp_maintenance_events(
        bob.session(),
        &bob_keys,
        &["wss://kp.example.com".to_owned()],
        None,
        None,
    )
    .await
    .expect("bob's key package")
    .event;
    let member = MemberKeyPackage {
        key_package_event,
        inbox_relays: vec!["wss://member-inbox.example.com".to_owned()],
        nip65_relays: vec![],
    };

    let alice_dir = TempDir::new().expect("temp dir");
    let alice_keys = Keys::generate();
    let alice = CircleManager::new_unencrypted(alice_dir.path(), &alice_keys).expect("alice opens");
    let config = CircleConfig::new("Forged Event Circle").with_relays(relays.clone());
    let created = alice
        .create_circle(&alice_keys, vec![member], &config)
        .await
        .expect("create the circle");
    // As the app's driven create leaves it: the founding Welcomes sent from
    // their records and acknowledged, so no later drive sends them.
    let _ = alice.land_staged_for_test().await;
    let circle = Circle {
        alice: Arc::new(alice),
        alice_keys,
        bob: Arc::new(bob),
        bob_keys,
        mls_group_id: created.circle.mls_group_id.clone(),
        nostr_group_id: created.circle.nostr_group_id,
        _dirs: [alice_dir, bob_dir],
    };
    (circle, created.welcome_events[0].event.clone())
}

async fn circle_on(relays: Vec<String>) -> Circle {
    let (circle, gift_wrap) = invite(relays).await;
    circle.bob_joins_with(&gift_wrap).await;
    circle
}

impl Circle {
    async fn bob_joins_with(&self, gift_wrap: &Event) {
        self.bob
            .process_gift_wrapped_invitation(&self.bob_keys, gift_wrap)
            .await
            .expect("bob previews the invitation");
        self.bob
            .accept_invitation(&gift_wrap.id)
            .await
            .expect("bob accepts it");
    }

    /// The relay Bob's sweep reads first: the first of his stored list.
    async fn bobs_first_relay(&self) -> String {
        let circles = self.bob.get_visible_circles().await.expect("bob's circles");
        circles[0].circle.relays[0].clone()
    }

    async fn epoch(&self, member: &CircleManager) -> u64 {
        member
            .group_epoch(&self.mls_group_id)
            .await
            .expect("the group has an epoch")
    }

    /// One confirmed admin commit from Alice (Rule 13), as a relay stores it.
    async fn alice_commits(&self, relays: &[String]) -> Event {
        self.alice
            .update_relays_for_test(&self.mls_group_id, relays)
            .await
            .expect("alice makes a relay-list commit")
    }

    async fn location_from(&self, member: &CircleManager, latitude: f64) -> Event {
        member
            .seal_location_for_test(
                &self.mls_group_id,
                &LocationMessage::new(latitude, 4.895_168),
            )
            .await
            .expect("a member encrypts a location")
            .0
    }

    fn spec(&self, relay: &ScriptedRelay) -> CircleSpec {
        CircleSpec {
            group_id_hex: hex::encode(self.nostr_group_id),
            relays: vec![relay.url().to_owned()],
        }
    }
}

/// `genuine` under its own id and signature with other content: the id no
/// longer matches the fields.
fn other_content(genuine: &Event) -> Event {
    let mut forged = genuine.clone();
    forged.content.push('A');
    forged
}

/// `genuine` under its own id with another signature: the id still matches,
/// so only a signature check tells it apart.
fn other_signature(genuine: &Event) -> Event {
    let mut forged = genuine.clone();
    forged.sig = EventBuilder::text_note("another event")
        .sign_with_keys(&Keys::generate())
        .expect("a locally built event signs")
        .sig;
    forged
}

type Forge = fn(&Event) -> Event;

const SHAPES: [(&str, Forge); 2] = [("content", other_content), ("signature", other_signature)];

fn asks_for_kind(kind: Kind) -> impl Fn(&Filter) -> bool + Send + Sync + 'static {
    move |filter| filter.kinds.as_ref().is_some_and(|k| k.contains(&kind))
}

fn frames(unasked: Option<&Event>, answer: Vec<Event>) -> Vec<Frame> {
    unasked
        .cloned()
        .map(Frame::Unasked)
        .into_iter()
        .chain(answer.into_iter().map(Frame::Event))
        .chain(std::iter::once(Frame::Eose))
        .collect()
}

/// A hostile relay and an honest one, the hostile one listed first. A circle
/// keeps its relay list sorted, so which of two relays is asked — and read —
/// first is a fact about their addresses.
fn hostile_listed_before_honest() -> (ScriptedRelay, ScriptedRelay, Vec<String>) {
    let (a, b) = (ScriptedRelay::start(), ScriptedRelay::start());
    let (hostile, honest) = if a.url() < b.url() { (a, b) } else { (b, a) };
    let relays = vec![hostile.url().to_owned(), honest.url().to_owned()];
    (hostile, honest, relays)
}

/// A relay that hangs up on every connection before the handshake. Its port
/// stays bound for the life of the test, so no other relay of this process can
/// come to answer on it.
async fn relay_that_never_answers() -> String {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
        .await
        .expect("bind a port");
    let url = format!("ws://{}", listener.local_addr().expect("local address"));
    tokio::spawn(async move {
        while let Ok((connection, _)) = listener.accept().await {
            drop(connection);
        }
    });
    url
}

/// Points the discovery plane, the profile pool and the account seed of this
/// binary at relays of its own that hold nothing. No test here means to reach
/// any of them; every test starts here so that a path which did would find a
/// relay of this process and never a production host.
fn hermetic() {
    static PLANES: OnceLock<[ScriptedRelay; 3]> = OnceLock::new();
    PLANES.get_or_init(|| {
        let relays = [
            ScriptedRelay::start(),
            ScriptedRelay::start(),
            ScriptedRelay::start(),
        ];
        let urls: Vec<String> = relays
            .iter()
            .filter_map(|relay| normalize_relay_url(relay.url()))
            .collect();
        assert_eq!(urls.len(), 3, "a loopback url did not normalize");
        set_default_relays_for_test(urls[..1].to_vec()).expect("install the account seed");
        set_discovery_relays_for_test(urls[..1].to_vec()).expect("install the discovery plane");
        set_profile_relays_for_test(urls).expect("install the profile pool");
        relays
    });
}

/// The three relay lists this crate falls back to are production hosts unless
/// a test overrides them. `hermetic` overrides all three, and this is what
/// says so when one is dropped.
#[test]
fn every_fallback_relay_list_of_this_binary_is_a_relay_of_its_own() {
    hermetic();
    for fallback in [
        default_relays(),
        discovery_relays(),
        profile_relay_pool_default(),
    ] {
        assert!(!fallback.is_empty(), "a fallback list read as empty");
        for relay in fallback {
            assert!(
                relay.starts_with("ws://127.0.0.1:"),
                "a production relay is reachable from a test of this binary"
            );
        }
    }
}

// ── The catch-up sweep ──────────────────────────────────────────────────────

/// The hostile relay is listed first, so its copy of the commit is the one the
/// sweep reads first, and the honest relay's genuine copy arrives as a repeat
/// of that id.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_forged_copy_of_a_commit_does_not_cost_the_commit() {
    hermetic();
    let mut lost = Vec::new();
    for (shape, forge) in SHAPES {
        let (hostile, honest, relays) = hostile_listed_before_honest();
        let fx = circle_on(relays.clone()).await;
        let before = fx.epoch(&fx.bob).await;

        let commit = fx.alice_commits(&relays).await;
        hostile.answer(
            asks_for_kind(Kind::Custom(445)),
            frames(Some(&commit), vec![forge(&commit)]),
        );
        honest.answer(asks_for_kind(Kind::Custom(445)), frames(None, vec![commit]));

        assert!(
            fx.bobs_first_relay().await == hostile.url(),
            "precondition: the sweep reads the hostile relay first"
        );
        let _ = run_catchup_all_circles(&fx.bob, &RelayManager::new(), 60).await;
        if fx.epoch(&fx.bob).await != before + 1 {
            lost.push(shape);
        }
    }
    assert!(
        lost.is_empty(),
        "a forgery from the first-listed relay cost the device the commit, in \
         these shapes: {lost:?}"
    );
}

/// The durable form. A location sent one epoch ahead is kept by the engine
/// until its commit arrives. A relay that replays the location under another
/// signature needs no prime — the honest delivery was the prime — and the
/// engine filed the forgery's rejection against the kept row, so the location
/// was never read: not when its commit arrived, and not when it was served
/// again.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_forged_copy_of_a_held_location_does_not_cost_it_when_its_commit_arrives() {
    hermetic();
    let (hostile, honest, relays) = hostile_listed_before_honest();
    let fx = circle_on(relays.clone()).await;
    let relay_mgr = RelayManager::new();
    let group_events = || asks_for_kind(Kind::Custom(445));
    let delivered = || {
        fx.bob
            .snapshot_last_known_for_circle(&fx.nostr_group_id, chrono::Utc::now().timestamp())
            .expect("bob's stored peer locations")
    };

    let commit = fx.alice_commits(&relays).await;
    let location = fx.location_from(&fx.alice, 52.370_216).await;

    // The location alone: Bob is an epoch behind and can only keep it.
    honest.answer(group_events(), frames(None, vec![location.clone()]));
    let _ = run_catchup_all_circles(&fx.bob, &relay_mgr, 60).await;
    assert!(delivered().is_empty(), "precondition: the location is held");

    // The forged copy, from the relay listed first.
    hostile.answer(
        group_events(),
        frames(None, vec![other_signature(&location)]),
    );
    assert!(
        fx.bobs_first_relay().await == hostile.url(),
        "precondition: the sweep reads the hostile relay first"
    );
    let _ = run_catchup_all_circles(&fx.bob, &relay_mgr, 60).await;

    // The commit at last, and the location served once more beside it.
    honest.answer(group_events(), frames(None, vec![location, commit]));
    let _ = run_catchup_all_circles(&fx.bob, &relay_mgr, 60).await;

    let rows = delivered();
    assert!(
        rows.len() == 1 && rows[0].sender_pubkey == fx.alice_keys.public_key().to_hex(),
        "the held location was never delivered: a forged copy of it was filed \
         against the row the engine kept"
    );
}

// ── The refused-object redelivery ───────────────────────────────────────────

/// An object the engine refused for a local bound is owed another delivery
/// until it arrives or every relay has said it holds none. A forged answer is
/// neither.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_forged_answer_does_not_discharge_a_refused_object() {
    const START_MS: u64 = 1_790_000_000_000;
    hermetic();
    let hostile = ScriptedRelay::start();
    let fx = circle_on(vec![
        hostile.url().to_owned(),
        relay_that_never_answers().await,
    ])
    .await;
    let relay_mgr = RelayManager::new();
    let owed = EventBuilder::new(Kind::Custom(445), "b3BhcXVl")
        .tag(Tag::parse(["h", &hex::encode(fx.nostr_group_id)]).expect("an h tag"))
        .sign_with_keys(&Keys::generate())
        .expect("a locally built event signs");
    let session = fx.bob.session();
    // An id a sweep could not discharge is asked for again only after a
    // wait, so "still owed" is read once that wait is over.
    session.set_legacy_clock_for_test(START_MS);
    session.record_refused_for_test(&fx.mls_group_id, &[owed.id]);
    let still_owed = || {
        session
            .refused_redeliveries(&fx.mls_group_id, 8)
            .contains(&owed.id)
    };
    let asked_by_id = {
        let id = owed.id;
        move |filter: &Filter| filter.ids.as_ref().is_some_and(|ids| ids.contains(&id))
    };

    hostile.answer(asked_by_id, frames(Some(&owed), vec![other_content(&owed)]));
    let _ = run_refused_refetch(&fx.bob, &relay_mgr, 20).await;
    assert!(
        !still_owed(),
        "premise: an id just asked for is not asked for again at once"
    );
    let wait_secs = u64::try_from(REFETCH_SPACING_BASE_SECS).expect("a minute");
    session.set_legacy_clock_for_test(START_MS + wait_secs * 1_000);
    assert!(
        still_owed(),
        "a forged answer discharged an object one relay never answered for"
    );

    // The object itself does discharge it, so "still owed" above is the
    // forgery's doing and not a ledger that never lets go.
    hostile.answer(asked_by_id, frames(None, vec![owed.clone()]));
    let _ = run_refused_refetch(&fx.bob, &relay_mgr, 20).await;
    // Read past the longest wait there is: gone, not waiting.
    let longest_secs = u64::try_from(REFETCH_SPACING_CAP_SECS).expect("a day");
    session.set_legacy_clock_for_test(START_MS + (wait_secs + 2 * longest_secs) * 1_000);
    assert!(!still_owed(), "the redelivered object was not taken");
}

// ── The live group plane ────────────────────────────────────────────────────

/// Every decrypted location on `bus` so far, as `(sender, content)`.
fn locations(bus: &mut tokio::sync::broadcast::Receiver<LiveSyncEvent>) -> Vec<(String, String)> {
    let mut seen = Vec::new();
    loop {
        match bus.try_recv() {
            Ok(LiveSyncEvent::Location {
                sender_pubkey,
                content,
                ..
            }) => seen.push((sender_pubkey, content)),
            Ok(_) | Err(TryRecvError::Lagged(_)) => {}
            Err(TryRecvError::Empty | TryRecvError::Closed) => return seen,
        }
    }
}

/// Alice's engine reads `answer` as the stored replay of its group REQ, and
/// what reached the bus by the time that replay settled.
async fn live_locations(
    fx: &Circle,
    relay: &ScriptedRelay,
    answer: Vec<Frame>,
) -> Vec<(String, String)> {
    relay.answer(asks_for_kind(Kind::Custom(445)), answer);
    let engine = LiveSyncCore::new_local(
        Arc::clone(&fx.alice),
        fx.alice_keys.public_key(),
        Arc::new(haven_core::relay::RelayManager::new()),
    );
    let mut bus = engine.bus().subscribe();
    engine
        .start(&[fx.spec(relay)], &[])
        .await
        .expect("the engine starts");
    assert_eq!(engine.wait_backlog_settled().await, BacklogOutcome::Settled);
    let seen = locations(&mut bus);
    let _ = engine.stop().await;
    seen
}

/// The prime, the forgery, then the genuine location — and the genuine one
/// first. Either way the bus carries the genuine location once and nothing
/// else.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn the_live_group_plane_delivers_the_genuine_location_beside_a_forgery_of_it() {
    hermetic();
    let mut wrong = Vec::new();
    for (shape, forge) in SHAPES {
        for forgery_first in [true, false] {
            let relay = ScriptedRelay::start();
            let fx = circle_on(vec![relay.url().to_owned()]).await;
            let genuine = fx.location_from(&fx.bob, 52.370_216).await;
            let answer = if forgery_first {
                frames(Some(&genuine), vec![forge(&genuine), genuine.clone()])
            } else {
                frames(None, vec![genuine.clone(), forge(&genuine)])
            };

            let seen = live_locations(&fx, &relay, answer).await;
            let genuine_once = seen.len() == 1
                && seen[0].0 == fx.bob_keys.public_key().to_hex()
                && seen[0].1.contains("52.370216");
            if !genuine_once {
                wrong.push((shape, forgery_first));
            }
        }
    }
    assert!(
        wrong.is_empty(),
        "the live plane did not deliver exactly the genuine location, once, for \
         these (forgery, sent first): {wrong:?}"
    );
}

/// Rule 15 over the live plane: a forgery is dropped without a word. The
/// needles are everything the relay chose — the forged content, the event id,
/// the signing key, its own address.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_forgery_on_the_live_plane_leaves_nothing_in_a_log() {
    hermetic();
    let relay = ScriptedRelay::start();
    let fx = circle_on(vec![relay.url().to_owned()]).await;
    let genuine = fx.location_from(&fx.bob, 52.370_216).await;
    let mut forged = genuine.clone();
    forged.content = "canary-forged-content".to_owned();

    let answer = frames(Some(&genuine), vec![forged.clone(), genuine.clone()]);
    let lines = capture_haven_log(async {
        let seen = live_locations(&fx, &relay, answer).await;
        assert_eq!(
            seen.len(),
            1,
            "the scenario ran: the genuine location arrived"
        );
    })
    .await;

    // Haven's own lines: a dependency's are kept out of every sink by target
    // (`haven/rust_builder`'s logger), and the relay in this process logs too.
    let ours = haven_core_lines(&lines);
    assert_some_line_from(&ours, "haven_core::relay::live_sync");
    assert_no_needles(
        &ours,
        &[
            &forged.content,
            &forged.id.to_hex(),
            &forged.pubkey.to_hex(),
            &forged.sig.to_string(),
            relay.url().trim_start_matches("ws://"),
        ],
    );
}

// ── The live inbox plane ────────────────────────────────────────────────────

/// The inbox plane hands every gift wrap it receives to the app, which
/// de-duplicates by id: a forged wrap under a genuine id, delivered first,
/// would be the copy the app keeps.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn the_live_inbox_plane_delivers_only_the_genuine_gift_wrap() {
    hermetic();
    let relay = ScriptedRelay::start();
    let dir = TempDir::new().expect("temp dir");
    let keys = Keys::generate();
    let manager = Arc::new(CircleManager::new_unencrypted(dir.path(), &keys).expect("opens"));
    let genuine = EventBuilder::new(Kind::GiftWrap, "b3BhcXVl")
        .tag(Tag::public_key(keys.public_key()))
        .sign_with_keys(&Keys::generate())
        .expect("a locally built event signs");
    relay.answer(
        asks_for_kind(Kind::GiftWrap),
        frames(
            Some(&genuine),
            vec![other_content(&genuine), genuine.clone()],
        ),
    );

    let engine = LiveSyncCore::new_local(
        Arc::clone(&manager),
        keys.public_key(),
        Arc::new(haven_core::relay::RelayManager::new()),
    );
    let mut bus = engine.bus().subscribe();
    engine
        .start(&[], &[relay.url().to_owned()])
        .await
        .expect("the engine starts");
    assert_eq!(engine.wait_backlog_settled().await, BacklogOutcome::Settled);
    let mut welcomes = Vec::new();
    loop {
        match bus.try_recv() {
            Ok(LiveSyncEvent::Welcome { gift_wrap_json }) => welcomes.push(gift_wrap_json),
            Ok(_) | Err(TryRecvError::Lagged(_)) => {}
            Err(TryRecvError::Empty | TryRecvError::Closed) => break,
        }
    }
    let _ = engine.stop().await;

    assert!(
        welcomes == [genuine.as_json()],
        "the inbox plane handed on something other than the genuine gift wrap, once"
    );
}

// ── Rule 3 ──────────────────────────────────────────────────────────────────

/// A Welcome is an unsigned kind-444 rumor inside a seal inside a gift wrap,
/// and only the wrap is ever a relay event. The check is on relay events and
/// nowhere else, so a real invitation still arrives through both reads of the
/// verifying client, previews, and is accepted.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_invitation_with_its_unsigned_welcome_still_arrives_and_is_accepted() {
    hermetic();
    let inbox = ScriptedRelay::start();
    let (fx, gift_wrap) = invite(vec![inbox.url().to_owned()]).await;
    inbox.answer(
        asks_for_kind(Kind::GiftWrap),
        frames(None, vec![gift_wrap.clone()]),
    );
    let relays = [inbox.url().to_owned()];
    let addressed_to_bob = Filter::new()
        .kind(Kind::GiftWrap)
        .pubkey(fx.bob_keys.public_key());

    let manager = RelayManager::new();
    let pooled = manager
        .fetch_events(addressed_to_bob.clone(), &relays, None)
        .await
        .expect("the pooled fetch runs");
    let per_relay = manager
        .fetch_events_per_relay(addressed_to_bob, &relays)
        .await
        .expect("the per-relay read runs");
    assert!(
        pooled == [gift_wrap.clone()] && per_relay[0].events == [gift_wrap],
        "the gift wrap did not arrive through both reads"
    );

    fx.bob_joins_with(&pooled[0]).await;
    assert_eq!(fx.epoch(&fx.bob).await, fx.epoch(&fx.alice).await);
}

/// The NIP-77 pass asks each relay by id for a commit the pager cannot reach.
/// The relay listed first answers with a forged copy under the commit's id,
/// after the pool has already verified that id once: Haven's own check still
/// drops the forgery before any id-keyed memory (Security Rule 16), and the
/// genuine copy is the one applied.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_forged_copy_served_to_a_reconciliation_fetch_never_reaches_the_engine() {
    use nostr_relay_builder::prelude::{MemoryDatabase, MemoryDatabaseOptions, NostrDatabase};
    use nostr_relay_builder::{LocalRelay, RelayBuilder};

    let _ = haven_core::relay::allow_ws_loopback_for_test();
    let mut backing = Vec::new();
    let mut wires = Vec::new();
    for _ in 0..2 {
        let db = MemoryDatabase::with_opts(MemoryDatabaseOptions {
            events: true,
            max_events: None,
        });
        let relay = LocalRelay::new(RelayBuilder::default().database(db.clone()));
        relay.run().await.expect("relay");
        let url = relay.url().await.to_string();
        wires.push(
            helpers::neg_wire::NegWire::in_front_of(&url, helpers::neg_wire::NegPolicy::Forward)
                .await,
        );
        backing.push((relay, db));
    }
    // The forger is the relay Bob's routing lists first.
    let order: Vec<usize> = if wires[0].url < wires[1].url {
        vec![0, 1]
    } else {
        vec![1, 0]
    };
    let urls: Vec<String> = order.iter().map(|at| wires[*at].url.clone()).collect();
    let (forger, honest) = (&wires[order[0]], &wires[order[1]]);
    let circle = circle_on(urls.clone()).await;
    let commit = circle.alice_commits(&urls).await;
    let routing = hex::encode(circle.nostr_group_id);
    let above = commit.created_at.as_secs() + 1;
    let pile: Vec<Event> = (0..500)
        .map(|i| {
            EventBuilder::new(Kind::Custom(445), format!("cGlsZQ-{i}"))
                .tags(vec![
                    Tag::parse(["h", &routing]).unwrap(),
                    Tag::parse(["h", &hex::encode([0x11u8; 32])]).unwrap(),
                ])
                .custom_created_at(nostr::Timestamp::from(above))
                .sign_with_keys(&Keys::generate())
                .unwrap()
        })
        .collect();
    for (_, db) in &backing {
        for event in std::iter::once(&commit).chain(&pile) {
            assert!(db.save_event(event).await.expect("seed").is_success());
        }
    }
    while nostr::Timestamp::now().as_secs() <= above {
        tokio::time::sleep(std::time::Duration::from_millis(20)).await;
    }
    // The pool has verified the genuine copy once: it checks no later copy
    // under that id itself (`T-POOL-VERIFY-CACHE`). Haven's verification drops
    // the forgery, and the screen's id check behind it would too.
    let relay_mgr = RelayManager::new();
    let seen = relay_mgr
        .fetch_events_per_relay(
            Filter::new().id(commit.id),
            std::slice::from_ref(&honest.url),
        )
        .await
        .expect("the pool reads the genuine copy");
    assert_eq!(
        seen[0].events.len(),
        1,
        "premise: the pool saw the genuine copy"
    );
    forger.forge(&[commit.id.to_hex()]);
    let before = circle.epoch(&circle.bob).await;

    let _ = run_catchup_all_circles(&circle.bob, &relay_mgr, 60).await;

    assert!(
        forger
            .frames_of(helpers::neg_wire::Dir::ToClient, "EVENT")
            .iter()
            .any(|frame| frame.text.contains("Zm9yZ2Vk")),
        "premise: the forger served its copy"
    );
    assert_eq!(
        circle.epoch(&circle.bob).await,
        before + 1,
        "the forged copy took the commit's place"
    );
}
