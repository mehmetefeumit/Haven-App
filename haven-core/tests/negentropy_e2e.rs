//! Haven's own NIP-77 pass (`relay::negentropy`), over real in-process relays
//! that speak NIP-77, behind an endpoint that records every frame and stages
//! the relays that do not ([`helpers::neg_wire`]).
//!
//! What each test holds is a promise of `INV-R-NEG-ADVERTISES-NOTHING`: what a
//! session tells a relay, whom the by-id ask goes to, how often a pass runs and
//! where, how a relay that declines is treated, how every session of a burst
//! ends, and that a commit a relay's cap buried below the live plane's floor is
//! recovered.
//!
//! No wait here is a sleep standing in for a duration: each is a bounded wait
//! on a condition, or on the wall clock crossing a second the test needs
//! crossed.

mod helpers;

use std::collections::HashSet;
use std::sync::Arc;
use std::time::Duration;

use haven_core::circle::{CircleConfig, CircleManager, MemberKeyPackage};
use haven_core::location::LocationMessage;
use haven_core::nostr::mls::types::GroupId;
use haven_core::relay::catchup::{run_catchup_all_circles, run_refused_refetch};
use haven_core::relay::live_sync::{group_cursor_stream, CircleSpec, Claim, LiveSyncCore};
use haven_core::relay::maintenance::build_kp_maintenance_events;
use haven_core::relay::negentropy::{
    NEG_NEGOTIATION_WAIT, NEG_PASS_SPACING_MS, NEG_REPLAY_BATCH, NEG_ROUTES_PER_PASS,
    NEG_ROUTE_WAIT, NEG_SET_LIMIT, NEG_WINDOW_SECS,
};
use haven_core::relay::{allow_ws_loopback_for_test, RelayManager};
use helpers::neg_wire::{Dir, Frame, NegPolicy, NegWire};
use helpers::{assert_no_needles, assert_some_line_from, capture_haven_log, haven_core_lines};
use nostr::{Event, EventBuilder, Keys, Kind, Tag, Timestamp};
use nostr_relay_builder::prelude::{MemoryDatabase, MemoryDatabaseOptions, NostrDatabase};
use nostr_relay_builder::{LocalRelay, RelayBuilder};
use tempfile::TempDir;

// ═══════════════════════════════════════════════════════════════════════════
// Harness
// ═══════════════════════════════════════════════════════════════════════════

/// A relay that speaks NIP-77, whose store the test seeds directly, with the
/// default 500-event cap on a REQ that names no `limit`.
struct SeededRelay {
    _relay: LocalRelay,
    url: String,
    db: MemoryDatabase,
}

/// Holds every REQ until `open` reads true.
#[derive(Debug)]
struct HeldQueries {
    open: tokio::sync::watch::Receiver<bool>,
}

impl nostr_relay_builder::builder::QueryPolicy for HeldQueries {
    fn admit_query<'a>(
        &'a self,
        _query: &'a nostr::Filter,
        _addr: &'a std::net::SocketAddr,
    ) -> nostr::util::BoxedFuture<'a, nostr_relay_builder::builder::PolicyResult> {
        Box::pin(async move {
            let _ = self.open.clone().wait_for(|open| *open).await;
            nostr_relay_builder::builder::PolicyResult::Accept
        })
    }
}

impl SeededRelay {
    async fn run() -> Self {
        Self::with(RelayBuilder::default()).await
    }

    /// A relay that answers no REQ until `open` reads true.
    async fn held(open: tokio::sync::watch::Receiver<bool>) -> Self {
        Self::with(RelayBuilder::default().query_policy(HeldQueries { open })).await
    }

    async fn with(builder: RelayBuilder) -> Self {
        let _ = allow_ws_loopback_for_test();
        let db = MemoryDatabase::with_opts(MemoryDatabaseOptions {
            events: true,
            max_events: None,
        });
        // `nostr-relay-builder` picks a free port when the relay is built and
        // binds it only when it runs, so a socket another test opened in
        // between can take it: that port is lost, and a fresh one is picked.
        let mut tries = 0;
        let relay = loop {
            let relay = LocalRelay::new(builder.clone().database(db.clone()));
            match relay.run().await {
                Ok(()) => break relay,
                Err(nostr_relay_builder::Error::IO(error))
                    if error.kind() == std::io::ErrorKind::AddrInUse && tries < 8 =>
                {
                    tries += 1;
                }
                Err(error) => panic!("seeded relay: {error:?}"),
            }
        };
        let url = relay.url().await.to_string();
        Self {
            _relay: relay,
            url,
            db,
        }
    }

    async fn seed(&self, events: &[Event]) {
        for event in events {
            assert!(
                self.db.save_event(event).await.expect("seed").is_success(),
                "the relay must hold every seeded event"
            );
        }
    }
}

/// `count` `kind:445`s dated `secs`, each under its own key, carrying two `h`
/// tags: Haven's screen refuses each before authentication.
fn junk(h: &str, count: usize, secs: u64) -> Vec<Event> {
    (0..count)
        .map(|i| {
            EventBuilder::new(Kind::Custom(445), format!("anVuaw-{i}"))
                .tags(vec![
                    Tag::parse(["h", h]).unwrap(),
                    Tag::parse(["h", &hex::encode([0x11u8; 32])]).unwrap(),
                ])
                .custom_created_at(Timestamp::from(secs))
                .sign_with_keys(&Keys::generate())
                .unwrap()
        })
        .collect()
}

fn now_secs() -> u64 {
    Timestamp::now().as_secs()
}

/// Blocks until the wall clock has ticked strictly past `secs`.
async fn wait_until_after(secs: u64) {
    while now_secs() <= secs {
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
}

/// Waits (bounded) until `cond` holds; whether it held.
async fn poll_until(mut cond: impl FnMut() -> bool) -> bool {
    let deadline = tokio::time::Instant::now() + Duration::from_secs(20);
    while !cond() {
        if tokio::time::Instant::now() >= deadline {
            return false;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    true
}

async fn mint_member(inbox: &[String]) -> (Arc<CircleManager>, Keys, MemberKeyPackage, TempDir) {
    let dir = TempDir::new().unwrap();
    let keys = Keys::generate();
    let mgr = CircleManager::new_unencrypted(dir.path(), &keys).unwrap();
    let member = package_of(&mgr, &keys, inbox).await;
    (Arc::new(mgr), keys, member, dir)
}

async fn package_of(mgr: &CircleManager, keys: &Keys, inbox: &[String]) -> MemberKeyPackage {
    let kp_event = build_kp_maintenance_events(
        mgr.session(),
        keys,
        &["wss://kp.example.com".to_string()],
        None,
        None,
    )
    .await
    .expect("member key package")
    .event;
    MemberKeyPackage {
        key_package_event: kp_event,
        inbox_relays: inbox.to_vec(),
        nip65_relays: vec![],
    }
}

/// Alice (admin) and Bob, real co-members of one or more circles.
struct Pair {
    alice: Arc<CircleManager>,
    alice_keys: Keys,
    bob: Arc<CircleManager>,
    bob_keys: Keys,
    _dirs: Vec<TempDir>,
}

/// One circle of a [`Pair`].
struct Joined {
    mls_group_id: GroupId,
    nostr_group_id: [u8; 32],
}

impl Joined {
    fn hex(&self) -> String {
        hex::encode(self.nostr_group_id)
    }
}

async fn pair() -> Pair {
    let (bob, bob_keys, _, bob_dir) =
        mint_member(&["wss://member-inbox.example.com".to_string()]).await;
    let alice_dir = TempDir::new().unwrap();
    let alice_keys = Keys::generate();
    let alice = Arc::new(CircleManager::new_unencrypted(alice_dir.path(), &alice_keys).unwrap());
    Pair {
        alice,
        alice_keys,
        bob,
        bob_keys,
        _dirs: vec![alice_dir, bob_dir],
    }
}

impl Pair {
    /// A circle Alice founds on `relays` and Bob joins.
    async fn circle(&self, relays: &[String]) -> Joined {
        let member = package_of(
            &self.bob,
            &self.bob_keys,
            &["wss://member-inbox.example.com".to_string()],
        )
        .await;
        let result = self
            .alice
            .create_circle(
                &self.alice_keys,
                vec![member],
                &CircleConfig::new("Reconciled Circle").with_relays(relays.to_vec()),
            )
            .await
            .expect("create circle");
        let _ = self.alice.land_staged_for_test().await;
        let welcome = result
            .welcome_events
            .iter()
            .find(|w| w.recipient_pubkey == self.bob_keys.public_key().to_hex())
            .expect("welcome for bob");
        self.bob
            .process_gift_wrapped_invitation(&self.bob_keys, &welcome.event)
            .await
            .expect("process welcome");
        self.bob
            .accept_invitation(&welcome.event.id)
            .await
            .expect("accept");
        Joined {
            mls_group_id: result.circle.mls_group_id.clone(),
            nostr_group_id: result.circle.nostr_group_id,
        }
    }

    /// One confirmed admin commit of Alice's in `circle`, keeping its relays.
    async fn commit(&self, circle: &Joined, relays: &[String]) -> Event {
        self.alice
            .update_relays_for_test(&circle.mls_group_id, relays)
            .await
            .expect("alice makes a commit")
    }

    async fn bob_epoch(&self, circle: &Joined) -> u64 {
        self.bob
            .group_epoch(&circle.mls_group_id)
            .await
            .expect("epoch")
    }
}

/// Steps the clock a pass's spacing is read on past the spacing, so the next
/// wake may begin a pass.
fn step_pass_clock(mgr: &CircleManager, at_ms: &mut u64) {
    *at_ms += NEG_PASS_SPACING_MS + 1_000;
    mgr.session().set_legacy_clock_for_test(*at_ms);
}

fn start_clock(mgr: &CircleManager) -> u64 {
    let at = now_secs() * 1_000;
    mgr.session().set_legacy_clock_for_test(at);
    at
}

/// The decoded base-128 varint negentropy uses, most significant group first.
fn varint(bytes: &mut &[u8]) -> u64 {
    let mut value = 0u64;
    loop {
        let byte = bytes[0];
        *bytes = &bytes[1..];
        value = (value << 7) | u64::from(byte & 0x7f);
        if byte & 0x80 == 0 {
            return value;
        }
    }
}

/// The (mode, item count) of every range of a negentropy message: mode 0 is
/// `Skip`, 1 `Fingerprint`, 2 `IdList` (negentropy 0.5.0 `lib.rs`).
fn ranges(message_hex: &str) -> Vec<(u64, u64)> {
    let raw = hex::decode(message_hex).expect("a negentropy message is hex");
    assert_eq!(raw[0], 0x61, "protocol version 1");
    let mut rest = &raw[1..];
    let mut out = Vec::new();
    while !rest.is_empty() {
        let _timestamp = varint(&mut rest);
        let prefix = usize::try_from(varint(&mut rest)).unwrap();
        rest = &rest[prefix..];
        let mode = varint(&mut rest);
        let count = match mode {
            0 => 0,
            1 => {
                rest = &rest[16..];
                1
            }
            2 => {
                let count = varint(&mut rest);
                rest = &rest[usize::try_from(count).unwrap() * 32..];
                count
            }
            other => panic!("unknown negentropy mode {other}"),
        };
        out.push((mode, count));
    }
    out
}

/// The `#h` value a `NEG-OPEN` frame's filter names.
fn neg_open_route(frame: &Frame) -> String {
    let json = frame.json().expect("json");
    json[2]["#h"][0]
        .as_str()
        .expect("a NEG-OPEN filter names one routing id")
        .to_string()
}

/// The ids every by-id REQ on `wire` asked for, one list per REQ.
fn by_id_asks(wire: &NegWire) -> Vec<Vec<String>> {
    wire.frames_of(Dir::ToRelay, "REQ")
        .into_iter()
        .filter_map(|frame| {
            let json = frame.json()?;
            let ids = json.get(2)?.get("ids")?.as_array()?.clone();
            Some(
                ids.iter()
                    .filter_map(|id| id.as_str().map(str::to_string))
                    .collect(),
            )
        })
        .collect()
}

/// A circle whose commit Bob has not applied, under a pile of junk in the
/// second above it that fills every page the pager can ask for: the commit is
/// reachable by NIP-77 alone. Returns the commit.
async fn bury(pair: &Pair, circle: &Joined, relays: &[&SeededRelay], urls: &[String]) -> Event {
    let commit = pair.commit(circle, urls).await;
    let above = commit.created_at.as_secs() + 1;
    for relay in relays {
        relay.seed(&junk(&circle.hex(), 500, above)).await;
    }
    wait_until_after(above).await;
    commit
}

fn crate_source(package: &str, file: &str) -> String {
    let metadata = std::process::Command::new(env!("CARGO"))
        .args(["metadata", "--format-version", "1", "--offline"])
        .current_dir(env!("CARGO_MANIFEST_DIR"))
        .output()
        .expect("run cargo metadata");
    assert!(metadata.status.success(), "cargo metadata failed");
    let metadata: serde_json::Value =
        serde_json::from_slice(&metadata.stdout).expect("cargo metadata JSON");
    let manifest = metadata["packages"]
        .as_array()
        .expect("packages")
        .iter()
        .find(|candidate| candidate["name"] == package)
        .and_then(|candidate| candidate["manifest_path"].as_str())
        .expect("the crate is in the graph");
    std::fs::read_to_string(std::path::Path::new(manifest).with_file_name(file))
        .expect("read the crate's source")
}

// ═══════════════════════════════════════════════════════════════════════════
// The pins
// ═══════════════════════════════════════════════════════════════════════════

/// Haven's pass is a port of MDK's, with MDK's numbers: an MDK bump that moves
/// one fails here and is re-read before it lands. The refusal texts are the
/// pool's and negentropy's own, as compared.
#[test]
fn neg_constants_match_mdk() {
    let adapter = crate_source("transport-nostr-adapter", "src/sdk_client.rs");
    for (literal, ours) in [
        (
            format!(
                "const SDK_RECONCILIATION_WAIT: Duration = Duration::from_secs({});",
                NEG_ROUTE_WAIT.as_secs()
            ),
            "NEG_ROUTE_WAIT",
        ),
        (
            format!(
                "const SDK_RECONCILIATION_NEGOTIATION_WAIT: Duration = Duration::from_millis({});",
                NEG_NEGOTIATION_WAIT.as_millis()
            ),
            "NEG_NEGOTIATION_WAIT",
        ),
        (
            format!("const SDK_RECONCILIATION_REPLAY_BATCH: usize = {NEG_REPLAY_BATCH};"),
            "NEG_REPLAY_BATCH",
        ),
        (
            "const SDK_RECONCILIATION_SET_LIMIT: usize = 16_384;".to_string(),
            "NEG_SET_LIMIT",
        ),
    ] {
        assert!(adapter.contains(&literal), "{ours} no longer matches MDK's");
    }
    assert_eq!(
        NEG_SET_LIMIT,
        storage_sqlite::TRANSPORT_RECONCILIATION_MAX_ITEMS_PER_ROUTE
    );
    assert_eq!(
        NEG_WINDOW_SECS,
        storage_sqlite::TRANSPORT_RECONCILIATION_RETENTION_SECS
    );
    assert_eq!(NEG_ROUTES_PER_PASS, 4);
    assert!(crate_source("nostr-relay-pool", "src/relay/error.rs")
        .contains(r#"Self::NegentropyNotSupported => f.write_str("negentropy not supported"),"#));
    assert!(crate_source("negentropy", "src/error.rs")
        .contains(r#"write!(f, "server does not support our negentropy protocol version")"#));
}

// ═══════════════════════════════════════════════════════════════════════════
// What a session tells a relay, and whom the by-id ask goes to
// ═══════════════════════════════════════════════════════════════════════════

/// Bob holds ids of the circle (MDK's inventory is not empty), yet every
/// session opens with the empty set's message and never sends an id or a
/// fingerprint after it; the follow-up by-id REQ goes only to the relay that
/// reported the commit, names only that, and carries the circle's `#h`.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_negentropy_session_advertises_nothing_the_device_holds() {
    let (relay_a, relay_b) = (SeededRelay::run().await, SeededRelay::run().await);
    let wire_a = NegWire::in_front_of(&relay_a.url, NegPolicy::Forward).await;
    let wire_b = NegWire::in_front_of(&relay_b.url, NegPolicy::Forward).await;
    let urls = vec![wire_a.url.clone(), wire_b.url.clone()];
    let pair = pair().await;
    let circle = pair.circle(&urls).await;
    let commit = pair.commit(&circle, &urls).await;
    relay_a.seed(std::slice::from_ref(&commit)).await;
    let above = commit.created_at.as_secs() + 1;
    let pile = junk(&circle.hex(), 500, above);
    relay_a.seed(&pile).await;
    relay_b.seed(&pile).await;
    pair.bob
        .session()
        .record_neg_items_for_test(
            circle.nostr_group_id,
            &pile[..3]
                .iter()
                .map(|event| (event.id, event.created_at.as_secs()))
                .collect::<Vec<_>>(),
        )
        .await;
    assert_eq!(
        pair.bob
            .session()
            .neg_inventory_for_test(circle.nostr_group_id)
            .await
            .len(),
        3,
        "premise: the device holds ids of this routing"
    );
    wait_until_after(above).await;
    let before = pair.bob_epoch(&circle).await;

    let _ = run_catchup_all_circles(&pair.bob, &RelayManager::new(), 60).await;

    assert_eq!(
        pair.bob_epoch(&circle).await,
        before + 1,
        "premise: the pass recovered the commit"
    );
    for wire in [&wire_a, &wire_b] {
        let opens = wire.frames_of(Dir::ToRelay, "NEG-OPEN");
        assert!(!opens.is_empty(), "premise: a session was opened");
        for open in opens {
            assert_eq!(
                open.json().unwrap()[3],
                "6100000200",
                "a session opened with something other than the empty set's message"
            );
        }
        for message in wire.frames_of(Dir::ToRelay, "NEG-MSG") {
            let hex = message.json().unwrap()[2].as_str().unwrap().to_string();
            assert!(
                ranges(&hex)
                    .iter()
                    .all(|range| *range == (0, 0) || *range == (2, 0)),
                "a client message carried an id or a fingerprint"
            );
        }
    }
    assert_eq!(
        by_id_asks(&wire_a),
        vec![vec![commit.id.to_hex()]],
        "the relay that holds the commit is asked for it, and for nothing else"
    );
    assert_eq!(
        by_id_asks(&wire_b),
        Vec::<Vec<String>>::new(),
        "a relay is asked by id only for ids it reported itself"
    );
    let ask = wire_a
        .frames_of(Dir::ToRelay, "REQ")
        .into_iter()
        .find_map(|frame| frame.json().filter(|json| json[2].get("ids").is_some()))
        .unwrap();
    assert_eq!(
        ask[2]["#h"][0],
        circle.hex(),
        "the by-id ask names its circle"
    );
}

/// What Bob asks of a relay depends on this circle alone: an id he processed
/// in ANOTHER circle, reported for this one, is still asked for — a relay
/// cannot learn from the ask which other circles Bob is in.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn the_ask_never_consults_what_another_circle_processed() {
    let probed = SeededRelay::run().await;
    let other_relay = SeededRelay::run().await;
    let pair = pair().await;
    let other = pair.circle(std::slice::from_ref(&other_relay.url)).await;
    let (theirs, _, _) = pair
        .alice
        .seal_location_for_test(&other.mls_group_id, &LocationMessage::new(48.85, 2.35))
        .await
        .expect("alice seals in the other circle");
    pair.bob
        .session()
        .process_event(&theirs)
        .await
        .expect("bob processes it there");
    assert!(
        pair.bob.session().engine_processed(&theirs.id),
        "premise: the id is processed on this device"
    );
    let wire =
        NegWire::in_front_of(&probed.url, NegPolicy::Answer(vec![theirs.id.to_bytes()])).await;
    let _probed_circle = pair.circle(std::slice::from_ref(&wire.url)).await;

    let _ = run_catchup_all_circles(&pair.bob, &RelayManager::new(), 60).await;

    assert!(
        by_id_asks(&wire)
            .iter()
            .any(|ask| ask.contains(&theirs.id.to_hex())),
        "the ask left out an id because another circle processed it: a relay \
         reporting another circle's ids learns which of them this device holds"
    );
}

/// A session's subscription id is fresh each time: across passes, across a
/// fresh publish pool, and across routes. Each is 32 lowercase hex characters
/// and carries no routing id and no key.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn negentropy_subscription_ids_are_not_stable_across_sessions() {
    let relay = SeededRelay::run().await;
    let wire = NegWire::in_front_of(&relay.url, NegPolicy::Forward).await;
    let pair = pair().await;
    let first = pair.circle(std::slice::from_ref(&wire.url)).await;
    let second = pair.circle(std::slice::from_ref(&wire.url)).await;
    let mut at = start_clock(&pair.bob);
    let pool = RelayManager::new();
    let _ = run_catchup_all_circles(&pair.bob, &pool, 60).await;
    step_pass_clock(&pair.bob, &mut at);
    let _ = run_catchup_all_circles(&pair.bob, &pool, 60).await;
    step_pass_clock(&pair.bob, &mut at);
    let _ = run_catchup_all_circles(&pair.bob, &RelayManager::new(), 60).await;

    let opens = wire.frames_of(Dir::ToRelay, "NEG-OPEN");
    assert_eq!(
        opens.len(),
        6,
        "premise: two routes in each of three passes"
    );
    let ids: HashSet<String> = opens
        .iter()
        .map(|open| open.json().unwrap()[1].as_str().unwrap().to_string())
        .collect();
    assert_eq!(ids.len(), opens.len(), "a subscription id was used twice");
    let secrets = [
        first.hex(),
        second.hex(),
        pair.bob_keys.public_key().to_hex(),
        pair.alice_keys.public_key().to_hex(),
    ];
    for id in &ids {
        assert!(
            id.len() == 32
                && id
                    .chars()
                    .all(|c| c.is_ascii_hexdigit() && !c.is_ascii_uppercase()),
            "a subscription id is not 32 lowercase hex characters"
        );
        for secret in &secrets {
            assert!(!secret.contains(id.as_str()) && !id.contains(&secret[..16]));
        }
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// Relays that decline, and how often a pass runs
// ═══════════════════════════════════════════════════════════════════════════

/// A relay that declines NIP-77 outright — by `NOTICE`, or by a `NEG-ERR`
/// naming the protocol version — is asked once for the life of the process,
/// across passes and publish pools. One that only stays silent is asked once
/// per pass and is never written off.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_relay_that_declines_negentropy_is_asked_once_per_process() {
    let relays = [
        SeededRelay::run().await,
        SeededRelay::run().await,
        SeededRelay::run().await,
    ];
    let declining = NegWire::in_front_of(
        &relays[0].url,
        NegPolicy::Notice("ERROR: bad msg: unknown cmd".into()),
    )
    .await;
    let old_version = NegWire::in_front_of(
        &relays[1].url,
        NegPolicy::NegErr("server does not support our negentropy protocol version".into()),
    )
    .await;
    let silent = NegWire::in_front_of(&relays[2].url, NegPolicy::Silent).await;
    let pair = pair().await;
    let _circle = pair
        .circle(&[
            declining.url.clone(),
            old_version.url.clone(),
            silent.url.clone(),
        ])
        .await;
    let mut at = start_clock(&pair.bob);
    let pool = RelayManager::new();
    for _ in 0..3 {
        let _ = run_catchup_all_circles(&pair.bob, &pool, 60).await;
        step_pass_clock(&pair.bob, &mut at);
    }
    let _ = run_catchup_all_circles(&pair.bob, &RelayManager::new(), 60).await;

    assert_eq!(declining.frames_of(Dir::ToRelay, "NEG-OPEN").len(), 1);
    assert_eq!(old_version.frames_of(Dir::ToRelay, "NEG-OPEN").len(), 1);
    assert_eq!(
        silent.frames_of(Dir::ToRelay, "NEG-OPEN").len(),
        4,
        "a relay that only stayed silent was written off"
    );
}

/// Six routings: a pass takes four, a wake inside the spacing takes none, and
/// the next pass takes the two left and wraps to the first two. The
/// refused-object refetch opens no session at all.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn negentropy_runs_at_most_four_routes_per_quantum_and_only_inside_a_wake() {
    let relay = SeededRelay::run().await;
    let wire = NegWire::in_front_of(&relay.url, NegPolicy::Forward).await;
    let alice_dir = TempDir::new().unwrap();
    let alice_keys = Keys::generate();
    let alice = Arc::new(CircleManager::new_unencrypted(alice_dir.path(), &alice_keys).unwrap());
    let mut routes = Vec::new();
    let mut dirs = Vec::new();
    for _ in 0..6 {
        let (_member, _, package, dir) = mint_member(std::slice::from_ref(&relay.url)).await;
        dirs.push(dir);
        let result = alice
            .create_circle(
                &alice_keys,
                vec![package],
                &CircleConfig::new("Spaced").with_relays(vec![wire.url.clone()]),
            )
            .await
            .expect("create circle");
        routes.push(hex::encode(result.circle.nostr_group_id));
    }
    let _ = alice.land_staged_for_test().await;
    routes.sort();
    let opened = |from: usize| -> Vec<String> {
        let mut seen: Vec<String> = wire.frames_of(Dir::ToRelay, "NEG-OPEN")[from..]
            .iter()
            .map(neg_open_route)
            .collect();
        seen.sort();
        seen
    };
    let mut at = start_clock(&alice);
    let pool = RelayManager::new();

    let _ = run_catchup_all_circles(&alice, &pool, 60).await;
    let first = opened(0);
    assert_eq!(
        first,
        routes[..4].to_vec(),
        "the first pass takes the first four"
    );

    let _ = run_catchup_all_circles(&alice, &pool, 60).await;
    assert_eq!(
        opened(4),
        Vec::<String>::new(),
        "a wake inside the spacing runs no pass"
    );

    step_pass_clock(&alice, &mut at);
    let _ = run_catchup_all_circles(&alice, &pool, 60).await;
    let mut wrapped = vec![
        routes[4].clone(),
        routes[5].clone(),
        routes[0].clone(),
        routes[1].clone(),
    ];
    wrapped.sort();
    assert_eq!(opened(4), wrapped, "the next pass takes the rest and wraps");

    step_pass_clock(&alice, &mut at);
    let _ = run_refused_refetch(&alice, &pool, 60).await;
    assert_eq!(
        opened(8),
        Vec::<String>::new(),
        "the refused-object refetch opened a session"
    );
    drop(dirs);
}

/// A circle MDK holds unrecoverable takes nothing a relay brings: no plane
/// follows it. The sweep leaves it out — no REQ, no NIP-77 route, no
/// refetch — and so does a live session the app lists it to, and its
/// absence moves nothing of it: its cursor stands and what it is owed stays
/// owed. Routable again, it is swept from where it stood.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[allow(clippy::too_many_lines)]
async fn no_plane_follows_an_unrecoverable_circle_and_its_absence_moves_nothing() {
    let relay = SeededRelay::run().await;
    let wire = NegWire::in_front_of(&relay.url, NegPolicy::Forward).await;
    let dir = TempDir::new().unwrap();
    let keys = Keys::generate();
    let alice = Arc::new(CircleManager::new_unencrypted(dir.path(), &keys).unwrap());
    let mut circles = Vec::new();
    let mut member_dirs = Vec::new();
    for _ in 0..2 {
        let (_member, _, package, member_dir) = mint_member(std::slice::from_ref(&relay.url)).await;
        member_dirs.push(member_dir);
        let created = alice
            .create_circle(
                &keys,
                vec![package],
                &CircleConfig::new("Followed").with_relays(vec![wire.url.clone()]),
            )
            .await
            .expect("create circle");
        circles.push((
            created.circle.mls_group_id,
            hex::encode(created.circle.nostr_group_id),
        ));
    }
    let _ = alice.land_staged_for_test().await;
    let ((dead, dead_hex), (_live, live_hex)) = (circles[0].clone(), circles[1].clone());
    let pool = RelayManager::new();
    let mut at = start_clock(&alice);
    let _ = run_catchup_all_circles(&alice, &pool, 60).await;
    let stream = group_cursor_stream(&dead_hex);
    let cursor = alice.read_sync_cursor(&stream).expect("read");
    assert!(
        cursor.is_some(),
        "premise: the first sweep left the circle a cursor"
    );
    let owed = junk(&dead_hex, 1, now_secs())[0].id;
    alice.session().record_refused_for_test(&dead, &[owed]);
    wait_until_after(now_secs()).await;

    drop(Arc::try_unwrap(alice).unwrap_or_else(|_| panic!("alice's manager is shared")));
    let halt = |halted| {
        haven_core::nostr::mls::storage::set_group_unrecoverable_for_test(
            &haven_core::nostr::mls::StorageConfig::new(dir.path()).database_path(),
            &haven_core::nostr::mls::StorageConfig::test_sqlcipher_key().expect("test key"),
            &dead,
            halted,
        )
        .expect("the halt is written");
    };
    halt(true);
    let alice = Arc::new(CircleManager::new_unencrypted(dir.path(), &keys).unwrap());
    let names_dead = |from: usize| {
        wire.frames()[from..]
            .iter()
            .filter(|frame| frame.dir == Dir::ToRelay && frame.text.contains(&dead_hex))
            .count()
    };

    let from = wire.frames().len();
    step_pass_clock(&alice, &mut at);
    let swept = run_catchup_all_circles(&alice, &pool, 60).await;
    assert!(
        swept.circles_swept == 1 && names_dead(from) == 0,
        "the sweep asked a relay for an unrecoverable circle",
    );

    let from = wire.frames().len();
    step_pass_clock(&alice, &mut at);
    let core = LiveSyncCore::new_local(
        Arc::clone(&alice),
        keys.public_key(),
        Arc::new(RelayManager::new()),
    );
    core.start(
        &[dead_hex.clone(), live_hex.clone()].map(|group_id_hex| CircleSpec {
            group_id_hex,
            relays: vec![wire.url.clone()],
        }),
        &[],
    )
    .await
    .expect("the session starts");
    core.claim_foreground(Claim::Foreground).await;
    let _ = core.wait_backlog_settled().await;
    assert!(
        core.processor()
            .for_test()
            .entry_pass_ended(Duration::from_secs(20))
            .await,
        "premise: the foreground entry's pass ran"
    );
    let live_asked = wire.frames()[from..]
        .iter()
        .any(|frame| frame.dir == Dir::ToRelay && frame.text.contains(&live_hex));
    assert!(
        live_asked && names_dead(from) == 0,
        "a live session listed an unrecoverable circle the app named, or ran a NIP-77 route for it",
    );
    let _ = core.stop().await;
    assert!(
        alice.read_sync_cursor(&stream).expect("read") == cursor
            && alice.session().refused_redeliveries(&dead, 16) == [owed],
        "an unrecoverable circle's absence moved its cursor or ended what it was owed",
    );

    drop(core);
    drop(Arc::try_unwrap(alice).unwrap_or_else(|_| panic!("alice's manager is shared")));
    halt(false);
    let alice = Arc::new(CircleManager::new_unencrypted(dir.path(), &keys).unwrap());
    let from = wire.frames().len();
    step_pass_clock(&alice, &mut at);
    let swept = run_catchup_all_circles(&alice, &pool, 60).await;
    let since = wire.frames()[from..]
        .iter()
        .filter(|frame| frame.dir == Dir::ToRelay && frame.verb().as_deref() == Some("REQ"))
        .filter_map(|frame| {
            let json = frame.json()?;
            let filter = json.get(2)?;
            filter
                .get("#h")?
                .as_array()?
                .iter()
                .any(|h| h == &dead_hex)
                .then(|| filter.get("since").and_then(serde_json::Value::as_i64))?
        })
        .min();
    assert!(
        swept.circles_swept == 2
            && since.is_some_and(|since| since * 1_000 <= cursor.unwrap_or(i64::MAX))
            && by_id_asks(&wire)
                .iter()
                .any(|ask| ask.contains(&owed.to_hex())),
        "a circle routable again was not swept from where it stood, or what it was owed was \
         not asked for",
    );
    drop(member_dirs);
}

/// A circle MDK held unrecoverable, which no plane follows, is followed
/// again the moment a Welcome repairs it in place: a live session lists it
/// at once, not at its next start or foreground entry.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[allow(clippy::too_many_lines)]
async fn a_circle_a_welcome_repairs_in_place_is_followed_again_at_once() {
    use haven_core::relay::fanout::scripted::{Answer, ScriptedFanout};
    use haven_core::relay::fanout::{DriveMode, EvolutionStatus};
    use helpers::drive::{through, ManualClock, Recorder};

    let relay = SeededRelay::run().await;
    let wire = NegWire::in_front_of(&relay.url, NegPolicy::Forward).await;
    let inbox = vec!["wss://member-inbox.example.com".to_string()];
    let alice_dir = TempDir::new().unwrap();
    let alice_keys = Keys::generate();
    let alice = Arc::new(CircleManager::new_unencrypted(alice_dir.path(), &alice_keys).unwrap());
    let (bob, bob_keys, package, bob_dir) = mint_member(&inbox).await;
    let created = alice
        .create_circle(
            &alice_keys,
            vec![package],
            &CircleConfig::new("Repaired").with_relays(vec![wire.url.clone()]),
        )
        .await
        .expect("create circle");
    let _ = alice.land_staged_for_test().await;
    let group = created.circle.mls_group_id.clone();
    let routing = hex::encode(created.circle.nostr_group_id);
    let welcome = created
        .welcome_events
        .iter()
        .find(|w| w.recipient_pubkey == bob_keys.public_key().to_hex())
        .expect("welcome for bob");
    bob.process_gift_wrapped_invitation(&bob_keys, &welcome.event)
        .await
        .expect("process welcome");
    bob.accept_invitation(&welcome.event.id)
        .await
        .expect("accept");
    drop(Arc::try_unwrap(bob).unwrap_or_else(|_| panic!("bob's manager is shared")));
    haven_core::nostr::mls::storage::set_group_unrecoverable_for_test(
        &haven_core::nostr::mls::StorageConfig::new(bob_dir.path()).database_path(),
        &haven_core::nostr::mls::StorageConfig::test_sqlcipher_key().expect("test key"),
        &group,
        true,
    )
    .expect("the halt is written");
    let bob = Arc::new(CircleManager::new_unencrypted(bob_dir.path(), &bob_keys).unwrap());
    let names_it = |from: usize| {
        wire.frames()[from..]
            .iter()
            .any(|frame| frame.dir == Dir::ToRelay && frame.text.contains(&routing))
    };

    let from = wire.frames().len();
    let core = LiveSyncCore::new_local(
        Arc::clone(&bob),
        bob_keys.public_key(),
        Arc::new(RelayManager::new()),
    );
    core.start(
        &[CircleSpec {
            group_id_hex: routing.clone(),
            relays: vec![wire.url.clone()],
        }],
        &[],
    )
    .await
    .expect("bob's engine starts");
    assert!(
        !names_it(from),
        "premise: the halted circle is not followed"
    );

    let clock = ManualClock::at(0);
    let transport = ScriptedFanout::default();
    transport.answer(&wire.url, [Answer::Accepted]);
    let outbox = Recorder::acking(true);
    let removed = through(&transport, &outbox, &clock, &DriveMode::Full)
        .remove_members(&alice, &group, &[bob_keys.public_key().to_hex()])
        .await
        .expect("alice removes bob");
    assert_eq!(removed.status, EvolutionStatus::Confirmed, "premise");
    let package = package_of(&bob, &bob_keys, &inbox).await;
    let transport = ScriptedFanout::default();
    transport.answer(&wire.url, [Answer::Accepted]);
    let outbox = Recorder::acking(true);
    let _ = through(&transport, &outbox, &clock, &DriveMode::Full)
        .add_members(&alice, &group, &[package])
        .await
        .expect("alice invites bob again");
    let wrap = outbox
        .handed()
        .into_iter()
        .map(|(event, _)| event)
        .find(|event| event.kind.as_u16() == 1059)
        .expect("premise: the Welcome was sent");

    let seen = core.follows_for_test();
    let from = wire.frames().len();
    bob.process_gift_wrapped_invitation(&bob_keys, &wrap)
        .await
        .expect("the invitation is held");
    bob.accept_invitation(&wrap.id)
        .await
        .expect("the Welcome repairs the halted copy");
    assert!(
        tokio::time::timeout(Duration::from_secs(20), core.follows_ended_for_test(seen))
            .await
            .is_ok()
            && poll_until(|| names_it(from)).await,
        "a circle a Welcome repaired in place was not followed again until a later start",
    );
    let _ = core.stop().await;
    drop(alice_dir);
}

// ═══════════════════════════════════════════════════════════════════════════
// The live plane
// ═══════════════════════════════════════════════════════════════════════════

/// Bob's engine over `urls`, started and settled, then paused: the state a
/// background wake finds.
async fn paused_engine(pair: &Pair, circle: &Joined, urls: &[String]) -> LiveSyncCore {
    let core = LiveSyncCore::new_local(
        Arc::clone(&pair.bob),
        pair.bob_keys.public_key(),
        Arc::new(RelayManager::new()),
    );
    core.start(
        &[CircleSpec {
            group_id_hex: circle.hex(),
            relays: urls.to_vec(),
        }],
        &[],
    )
    .await
    .expect("bob's engine starts");
    let _ = core.wait_backlog_settled().await;
    core.pause_subscriptions().await.expect("pause");
    core
}

/// The relay caps Bob's burst REQ at 500 events, all of them junk newer than
/// Alice's commit, so the burst's stored replay ends without it and the cursor
/// passes it (C8). The burst's own pass recovers it before the seal: when the
/// wait returns, Bob is at the commit's epoch. Against a relay that declines
/// NIP-77 the same burst leaves Bob behind, which is what the pass is for.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_commit_buried_past_the_relay_cap_is_recovered_by_reconciliation() {
    for speaks_nip77 in [true, false] {
        let relay = SeededRelay::run().await;
        let policy = if speaks_nip77 {
            NegPolicy::Forward
        } else {
            NegPolicy::Notice("ERROR: bad msg: unknown cmd".into())
        };
        let wire = NegWire::in_front_of(&relay.url, policy).await;
        let urls = vec![wire.url.clone()];
        let pair = pair().await;
        let circle = pair.circle(&urls).await;
        let core = paused_engine(&pair, &circle, &urls).await;
        let before = pair.bob_epoch(&circle).await;
        let commit = bury(&pair, &circle, &[&relay], &urls).await;
        relay.seed(std::slice::from_ref(&commit)).await;

        core.open_background_burst().await.expect("burst opens");
        let _ = core.wait_backlog_settled().await;

        let after = pair.bob_epoch(&circle).await;
        if speaks_nip77 {
            assert_eq!(
                after,
                before + 1,
                "the burst sealed behind a commit a relay held below its floor"
            );
            assert!(
                !pair
                    .bob
                    .session()
                    .holds_unread_input_for_test(&circle.mls_group_id),
                "what the pass fetched is all taken in when the wait returns"
            );
        } else {
            assert_eq!(
                after, before,
                "premise: without NIP-77 the relay's cap really buries the commit"
            );
        }
        core.pause_subscriptions().await.expect("pause");
        let _ = core.stop().await;
    }
}

/// The same burial, recovered at a live foreground entry: the drive task runs
/// the entry's one pass.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_foreground_entry_recovers_a_buried_commit_once() {
    let relay = SeededRelay::run().await;
    let wire = NegWire::in_front_of(&relay.url, NegPolicy::Forward).await;
    let urls = vec![wire.url.clone()];
    let pair = pair().await;
    let circle = pair.circle(&urls).await;
    let core = paused_engine(&pair, &circle, &urls).await;
    let before = pair.bob_epoch(&circle).await;
    let commit = bury(&pair, &circle, &[&relay], &urls).await;
    relay.seed(std::slice::from_ref(&commit)).await;

    core.resume_after_background(Claim::Foreground)
        .await
        .expect("foreground entry");
    let bob = Arc::clone(&pair.bob);
    let gid = circle.mls_group_id.clone();
    let mut recovered = false;
    for _ in 0..200 {
        if bob.group_epoch(&gid).await.expect("epoch") == before + 1 {
            recovered = true;
            break;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    assert!(
        recovered,
        "the foreground entry's pass did not recover the commit"
    );
    let _ = core.stop().await;
}

/// A live foreground runs one pass at its entry and none for the half hour
/// after it, however many drives and health ticks it makes; the next entry
/// runs the next.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_steady_foreground_runs_no_pass_after_its_entrys() {
    let relay = SeededRelay::run().await;
    let wire = NegWire::in_front_of(&relay.url, NegPolicy::Forward).await;
    let urls = vec![wire.url.clone()];
    let pair = pair().await;
    let circle = pair.circle(&urls).await;
    let core = paused_engine(&pair, &circle, &urls).await;
    let mut at = start_clock(&pair.bob);
    core.resume_after_background(Claim::Foreground)
        .await
        .expect("foreground entry");
    assert!(
        poll_until(|| wire.frames_of(Dir::ToRelay, "NEG-OPEN").len() == 1).await,
        "premise: the entry ran its pass"
    );
    // Thirty minutes of a foreground's ticks, each past the spacing.
    for _ in 0..30 {
        at += 60_000;
        pair.bob.session().set_legacy_clock_for_test(at);
        let _ = core.maintain_subscription_health(Claim::Foreground).await;
        core.processor().for_test().request_drive();
    }
    core.pause_subscriptions().await.expect("pause");
    step_pass_clock(&pair.bob, &mut at);
    core.resume_after_background(Claim::Foreground)
        .await
        .expect("the next entry");
    assert!(
        poll_until(|| wire.frames_of(Dir::ToRelay, "NEG-OPEN").len() >= 2).await,
        "premise: the next entry ran its pass"
    );
    assert_eq!(
        wire.frames_of(Dir::ToRelay, "NEG-OPEN").len(),
        2,
        "the steady foreground ran a pass of its own"
    );
    let _ = core.stop().await;
}

/// Three relays: one completes its session, one never answers the opening
/// message, one refuses it. By the time the burst's pause returns, every
/// session it opened has ended — by NEG-CLOSE, by NEG-ERR, or by its socket's
/// close (the pool sends no NEG-CLOSE for a session it gave up on) — and the
/// drive pool the pass ran on holds no connected relay, the read the iOS
/// background lane makes between bursts.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn every_negentropy_session_of_a_burst_ends_before_the_pause_returns() {
    let relays = [
        SeededRelay::run().await,
        SeededRelay::run().await,
        SeededRelay::run().await,
    ];
    let complete = NegWire::in_front_of(&relays[0].url, NegPolicy::Forward).await;
    let stalled = NegWire::in_front_of(&relays[1].url, NegPolicy::Silent).await;
    let refused = NegWire::in_front_of(&relays[2].url, NegPolicy::NegErr("blocked".into())).await;
    let urls = vec![
        complete.url.clone(),
        stalled.url.clone(),
        refused.url.clone(),
    ];
    let pair = pair().await;
    let circle = pair.circle(&urls).await;
    let core = paused_engine(&pair, &circle, &urls).await;

    core.open_background_burst().await.expect("burst opens");
    let _ = core.wait_backlog_settled().await;
    assert!(
        core.drive_pool_connected_relays()
            .await
            .is_some_and(|connected| connected > 0),
        "premise: the burst's pass dialled the drive pool"
    );
    core.pause_subscriptions().await.expect("pause");
    assert_eq!(
        core.drive_pool_connected_relays().await,
        Some(0),
        "a drive-pool socket outlived the pause"
    );

    for wire in [&complete, &stalled, &refused] {
        let opens = wire.frames_of(Dir::ToRelay, "NEG-OPEN");
        assert_eq!(opens.len(), 1, "premise: the burst opened one session here");
        let open = &opens[0];
        let sub = open.json().unwrap()[1].clone();
        let ended_in_band = wire.frames().iter().any(|frame| {
            frame.conn == open.conn
                && frame.json().is_some_and(|json| {
                    json[1] == sub
                        && ((frame.dir == Dir::ToRelay && json[0] == "NEG-CLOSE")
                            || (frame.dir == Dir::ToClient && json[0] == "NEG-ERR"))
                })
        });
        let ended = ended_in_band || poll_until(|| wire.closed_conns().contains(&open.conn)).await;
        assert!(ended, "a session outlived the burst that opened it");
    }
    assert!(
        !stalled
            .frames()
            .iter()
            .any(|frame| frame.json().is_some_and(|json| json[0] == "NEG-CLOSE")),
        "premise: the stalled session was never closed in band, so only its \
         socket's close can have ended it"
    );
    let _ = core.stop().await;
}

// ═══════════════════════════════════════════════════════════════════════════
// Ids judged final for a route
// ═══════════════════════════════════════════════════════════════════════════

/// More than one batch of junk the screen refuses, reported by the relay below
/// every page the pager reads: each is asked for once, judged, and never asked
/// again, so the window completes within a few passes instead of being held
/// for ever by ids no fetch can resolve.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_flood_of_unscreenable_ids_is_judged_once_and_the_window_completes() {
    let relay = SeededRelay::run().await;
    let wire = NegWire::in_front_of(&relay.url, NegPolicy::Forward).await;
    let pair = pair().await;
    let circle = pair.circle(std::slice::from_ref(&wire.url)).await;
    let old = now_secs() - 2 * 86_400;
    let flood = 300;
    relay.seed(&junk(&circle.hex(), flood, old)).await;
    let above = now_secs() + 1;
    relay.seed(&junk(&circle.hex(), 500, above)).await;
    wait_until_after(above).await;
    let stream = group_cursor_stream(&circle.hex());
    let mut at = start_clock(&pair.bob);
    let pool = RelayManager::new();

    let mut completed_on = None;
    for pass in 1..=5 {
        let out = run_catchup_all_circles(&pair.bob, &pool, 60).await;
        if out.windows_truncated == 0 {
            completed_on = Some(pass);
            break;
        }
        step_pass_clock(&pair.bob, &mut at);
    }
    let completed_on = completed_on.expect("the window never completed");
    assert!(
        completed_on > 1,
        "premise: one batch could not judge the whole flood"
    );
    assert!(pair.bob.read_sync_cursor(&stream).unwrap().is_some());
    let asked: Vec<String> = by_id_asks(&wire).into_iter().flatten().collect();
    let distinct: HashSet<&String> = asked.iter().collect();
    assert_eq!(
        asked.len(),
        distinct.len(),
        "a judged id was asked for again"
    );
    assert_eq!(
        asked.len(),
        flood,
        "each id below the pager was asked for once"
    );
}

/// An expired location the relay still reports, and the pool drops when it is
/// served, is asked for once: absent from an answer the relay finished, it is
/// that relay's unserved id from then on, and the window completes.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_expired_id_a_relay_reports_is_asked_once_and_holds_nothing() {
    let relay = SeededRelay::run().await;
    let wire = NegWire::in_front_of(&relay.url, NegPolicy::Forward).await;
    let pair = pair().await;
    let circle = pair.circle(std::slice::from_ref(&wire.url)).await;
    // A relay refuses an event already past its expiration, so this one
    // expires just after it is stored, as a peer's location does.
    let expiry_secs = now_secs() + 2;
    let expired = EventBuilder::new(Kind::Custom(445), "ZXhwaXJlZA")
        .tags(vec![
            Tag::parse(["h", &circle.hex()]).unwrap(),
            Tag::expiration(Timestamp::from(expiry_secs)),
        ])
        .custom_created_at(Timestamp::from(now_secs() - 86_400 * 2))
        .sign_with_keys(&Keys::generate())
        .unwrap();
    relay.seed(std::slice::from_ref(&expired)).await;
    wait_until_after(expiry_secs).await;
    let above = now_secs() + 1;
    relay.seed(&junk(&circle.hex(), 500, above)).await;
    wait_until_after(above).await;
    let mut at = start_clock(&pair.bob);
    let pool = RelayManager::new();

    let first = run_catchup_all_circles(&pair.bob, &pool, 60).await;
    step_pass_clock(&pair.bob, &mut at);
    let _ = run_catchup_all_circles(&pair.bob, &pool, 60).await;

    assert_eq!(
        by_id_asks(&wire),
        vec![vec![expired.id.to_hex()]],
        "the expired id is asked for once, across two passes"
    );
    assert_eq!(
        first.windows_truncated, 0,
        "an id a relay reported and did not serve holds the window"
    );
}

// ═══════════════════════════════════════════════════════════════════════════
// Log anonymity (Security Rule 15)
// ═══════════════════════════════════════════════════════════════════════════

/// A burst whose pass recovers a buried commit from one relay, is refused by
/// a second with planted text, and is answered by a third with a planted
/// count of ids, writes none of the relays, the routing id, the commit's id,
/// the refusal's text or the count into any log line.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn negentropy_logs_no_identifier() {
    const PLANTED: &str = "planted-negerr-7f3a9c";
    let relays = [
        SeededRelay::run().await,
        SeededRelay::run().await,
        SeededRelay::run().await,
    ];
    let recovers = NegWire::in_front_of(&relays[0].url, NegPolicy::Forward).await;
    let refuses = NegWire::in_front_of(&relays[1].url, NegPolicy::NegErr(PLANTED.into())).await;
    let counted: Vec<[u8; 32]> = (0..1337).map(|_| rand::random()).collect();
    let answers = NegWire::in_front_of(&relays[2].url, NegPolicy::Answer(counted)).await;
    let urls = vec![
        recovers.url.clone(),
        refuses.url.clone(),
        answers.url.clone(),
    ];
    let pair = pair().await;
    let circle = pair.circle(&urls).await;
    let core = paused_engine(&pair, &circle, &urls).await;
    let before = pair.bob_epoch(&circle).await;
    let commit = bury(&pair, &circle, &[&relays[0]], &urls).await;
    relays[0].seed(std::slice::from_ref(&commit)).await;

    let lines = capture_haven_log(async {
        core.open_background_burst().await.expect("burst opens");
        let _ = core.wait_backlog_settled().await;
        core.pause_subscriptions().await.expect("pause");
    })
    .await;

    assert_eq!(
        pair.bob_epoch(&circle).await,
        before + 1,
        "premise: the pass ran"
    );
    assert!(
        !refuses.frames_of(Dir::ToClient, "NEG-ERR").is_empty(),
        "premise: the refusal was sent"
    );
    // Haven's own lines: the test's proxies log their own handshakes.
    let lines = haven_core_lines(&lines);
    assert_some_line_from(&lines, "haven_core");
    let hosts: Vec<String> = urls
        .iter()
        .map(|url| url.trim_start_matches("ws://").to_string())
        .collect();
    let mut needles: Vec<&str> = urls.iter().map(String::as_str).collect();
    needles.extend(hosts.iter().map(String::as_str));
    let routing = circle.hex();
    let commit_id = commit.id.to_hex();
    needles.extend([routing.as_str(), commit_id.as_str(), PLANTED, "1337"]);
    assert_no_needles(&lines, &needles);
    let _ = core.stop().await;
}

// ═══════════════════════════════════════════════════════════════════════════
// A judged id belongs to the routing it was fetched for
// ═══════════════════════════════════════════════════════════════════════════

/// An event naming two circles' routing ids, refused by the screen when one
/// circle's pager fetched it, is judged for that circle alone: the other
/// circle's pass still asks for it, so what one routing's pass asks a relay
/// never depends on what arrived for another (AM-R4-1).
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_screen_refusal_fetched_for_one_circle_is_still_asked_for_by_another() {
    let (relay_a, relay_b) = (SeededRelay::run().await, SeededRelay::run().await);
    let wire_b = NegWire::in_front_of(&relay_b.url, NegPolicy::Silent).await;
    let pair = pair().await;
    let a = pair.circle(std::slice::from_ref(&relay_a.url)).await;
    let b = pair.circle(std::slice::from_ref(&wire_b.url)).await;
    let both = EventBuilder::new(Kind::Custom(445), "Ym90aA")
        .tags(vec![
            Tag::parse(["h", &a.hex()]).unwrap(),
            Tag::parse(["h", &b.hex()]).unwrap(),
        ])
        .custom_created_at(Timestamp::from(now_secs() - 60))
        .sign_with_keys(&Keys::generate())
        .unwrap();
    relay_a.seed(std::slice::from_ref(&both)).await;
    let mut at = start_clock(&pair.bob);
    let pool = RelayManager::new();

    let first = run_catchup_all_circles(&pair.bob, &pool, 60).await;
    assert!(
        first.events_rejected_pre_auth >= 1,
        "premise: circle A's pager fetched the event and the screen refused it"
    );
    wire_b.set_policy(NegPolicy::Answer(vec![both.id.to_bytes()]));
    step_pass_clock(&pair.bob, &mut at);
    let _ = run_catchup_all_circles(&pair.bob, &pool, 60).await;

    assert!(
        by_id_asks(&wire_b)
            .iter()
            .any(|ask| ask.contains(&both.id.to_hex())),
        "circle B's pass left out an id circle A's pager judged: what one \
         routing's pass asks depended on another routing's traffic"
    );
}

// ═══════════════════════════════════════════════════════════════════════════
// A pause or a stop ends a foreground entry's pass
// ═══════════════════════════════════════════════════════════════════════════

/// Bob's engine after a foreground entry whose REQs the relay holds: the
/// drive task is waiting for the entry's replay, its pass not yet run.
async fn entry_waiting_for_its_replay(
    pair: &Pair,
    circle: &Joined,
    urls: &[String],
    hold: &tokio::sync::watch::Sender<bool>,
) -> LiveSyncCore {
    let core = paused_engine(pair, circle, urls).await;
    hold.send(false).expect("hold the relay's answers");
    core.resume_after_background(Claim::Foreground)
        .await
        .expect("foreground entry");
    let processor = core.processor();
    assert!(
        poll_until(|| processor.for_test().negentropy_steps().0 == 1).await,
        "premise: the drive task waits for the entry's replay"
    );
    core
}

/// The user leaves the app while the entry's pass waits for its replay: the
/// pause returns, and the pass dials nothing, opens no session and asks for
/// nothing after it — no presence between wakes (INV-R-BACKGROUND-PRESENCE-ONLY-AT-PUBLISH).
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_foreground_pass_the_pause_overtakes_dials_nothing_after_it() {
    let (open, held) = tokio::sync::watch::channel(true);
    let relay = SeededRelay::held(held).await;
    let wire = NegWire::in_front_of(&relay.url, NegPolicy::Forward).await;
    let urls = vec![wire.url.clone()];
    let pair = pair().await;
    let circle = pair.circle(&urls).await;
    let _ = start_clock(&pair.bob);
    let core = entry_waiting_for_its_replay(&pair, &circle, &urls, &open).await;

    core.pause_subscriptions().await.expect("pause");
    let (connections, frames) = (wire.connections(), wire.frames().len());
    open.send(true).expect("the relay answers again");
    let processor = core.processor();
    assert!(
        poll_until(|| processor.for_test().negentropy_steps().1 == 1).await,
        "premise: the drive task finished with the entry's pass"
    );

    // The pause's own CLOSEs may still be on the wire; anything that asks a
    // relay for something is not.
    let asked: Vec<Option<String>> = wire.frames()[frames..]
        .iter()
        .filter(|frame| frame.dir == Dir::ToRelay)
        .map(Frame::verb)
        .filter(|verb| verb.as_deref() != Some("CLOSE"))
        .collect();
    assert!(
        asked.is_empty(),
        "the device asked a relay for something after the pause returned: {asked:?}"
    );
    assert_eq!(
        wire.connections(),
        connections,
        "a socket was opened after the pause returned"
    );
    assert!(wire.frames_of(Dir::ToRelay, "NEG-OPEN").is_empty());
    let _ = core.stop().await;
}

/// The seam a harness awaits before it grades a device just brought to the
/// foreground answers that the entry's pass has ended only once it has:
/// not while the pass waits for its replay, and as soon as it has run.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_entry_pass_is_reported_ended_only_once_it_has_run() {
    let (open, held) = tokio::sync::watch::channel(true);
    let relay = SeededRelay::held(held).await;
    let wire = NegWire::in_front_of(&relay.url, NegPolicy::Forward).await;
    let urls = vec![wire.url.clone()];
    let pair = pair().await;
    let circle = pair.circle(&urls).await;
    let _ = start_clock(&pair.bob);
    let core = entry_waiting_for_its_replay(&pair, &circle, &urls, &open).await;
    let processor = core.processor();

    assert!(
        !processor
            .for_test()
            .entry_pass_ended(Duration::from_millis(200))
            .await,
        "an entry pass still waiting for its replay was reported ended"
    );
    open.send(true).expect("the relay answers again");
    assert!(
        processor
            .for_test()
            .entry_pass_ended(Duration::from_secs(20))
            .await
            && processor.for_test().negentropy_steps() == (1, 1)
            && !wire.frames_of(Dir::ToRelay, "NEG-OPEN").is_empty(),
        "an entry pass that ran was not reported ended"
    );
    let _ = core.stop().await;
}

/// The same, overtaken by a stop (a logout): the stop drains every task,
/// and nothing is sent after it.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_stop_during_a_foreground_pass_drains_and_dials_nothing() {
    let (open, held) = tokio::sync::watch::channel(true);
    let relay = SeededRelay::held(held).await;
    let wire = NegWire::in_front_of(&relay.url, NegPolicy::Forward).await;
    let urls = vec![wire.url.clone()];
    let pair = pair().await;
    let circle = pair.circle(&urls).await;
    let _ = start_clock(&pair.bob);
    let core = entry_waiting_for_its_replay(&pair, &circle, &urls, &open).await;

    let stopped = core.stop().await;
    let (connections, frames) = (wire.connections(), wire.frames().len());
    open.send(true).expect("the relay answers again");

    assert_eq!(
        stopped,
        haven_core::relay::live_sync::StopOutcome::Drained,
        "a foreground pass kept the session's tasks past its stop"
    );
    assert_eq!(
        wire.connections(),
        connections,
        "a socket was opened after the stop"
    );
    assert!(
        wire.frames()[frames..]
            .iter()
            .filter(|frame| frame.dir == Dir::ToRelay)
            .all(|frame| frame.verb().as_deref() == Some("CLOSE")),
        "the device asked a relay for something after the stop returned"
    );
    assert!(wire.frames_of(Dir::ToRelay, "NEG-OPEN").is_empty());
}

/// A stop that lands while the foreground pass is still dialling — the one
/// stretch between the pass's dial and its fetch where it reads no fence —
/// ends the pass there: the stop drains every task, and no session is opened
/// after it, even once the slow relay answers the dial.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_stop_while_a_foreground_pass_dials_opens_no_session_after_it() {
    let (open, held) = tokio::sync::watch::channel(true);
    let relay = SeededRelay::held(held).await;
    let wire = NegWire::in_front_of(&relay.url, NegPolicy::Forward).await;
    let urls = vec![wire.url.clone()];
    let pair = pair().await;
    let circle = pair.circle(&urls).await;
    let _ = start_clock(&pair.bob);
    let core = entry_waiting_for_its_replay(&pair, &circle, &urls, &open).await;
    wire.hold_new_connections();
    open.send(true).expect("the entry's replay comes in");
    assert!(
        poll_until(|| wire.held() == 1).await,
        "premise: the pass is dialling the relay"
    );

    let stopped = core.stop().await;
    wire.release_connections();
    let processor = core.processor();
    assert!(
        poll_until(|| wire.held() == 0).await,
        "premise: the slow relay answered the dial"
    );

    assert_eq!(
        stopped,
        haven_core::relay::live_sync::StopOutcome::Drained,
        "a foreground pass kept the session's tasks past its stop"
    );
    assert_eq!(
        processor.for_test().negentropy_steps().1,
        0,
        "the pass ran on past the stop instead of ending where it stood"
    );
    assert!(
        wire.frames_of(Dir::ToRelay, "NEG-OPEN").is_empty(),
        "a session was opened after the stop"
    );
}
