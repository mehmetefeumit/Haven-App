//! A relay answers a per-author REQ with whatever it likes, and the relay pool
//! does not hold it to the filter (`verify_subscriptions` is off), so every
//! event a per-author fetch acts on must be checked against the author asked
//! for. The relay here substitutes: whatever REQ names an author, it answers
//! with every event registered for that author, whoever signed it and whatever
//! its kind. Each event is validly signed, so only Haven's own checks can tell
//! them apart (Marmot `transports/nostr.md:331-333`, `foundation/key-packages.md:126`).

use std::collections::HashMap;
use std::sync::{Arc, Mutex, OnceLock};

use base64::Engine as _;
use futures::{SinkExt, StreamExt};
use haven_core::nostr::mls::types::{KeyPackageAdmission, KeyPackageAdmissionRule};
use haven_core::nostr::mls::SessionManager;
use haven_core::relay::maintenance::{
    build_kp_maintenance_events, build_kp_maintenance_events_reusing,
};
use haven_core::relay::{allow_ws_loopback_for_test, set_discovery_relays_for_test, RelayManager};
use nostr::{Event, EventBuilder, Filter, Keys, Kind, PublicKey, Tag, Timestamp};
use tokio::net::TcpListener;
use tokio_tungstenite::tungstenite::Message;

mod helpers;
use helpers::twin_key_packages::{
    expired_lifetime, mint_unowned_like, pre_migration, Minted, Twin,
};

/// The relay set the 30443 template requires and never renders.
const OWN_RELAY: &str = "wss://own.example.com";

type Answers = Arc<Mutex<HashMap<PublicKey, Vec<Event>>>>;

struct Substituting {
    answers: Answers,
}

impl Substituting {
    fn answer(&self, asked_for: &Keys, events: Vec<Event>) {
        self.answers
            .lock()
            .unwrap()
            .insert(asked_for.public_key(), events);
    }
}

async fn serve(listener: TcpListener, answers: Answers) {
    loop {
        let Ok((tcp, _)) = listener.accept().await else {
            return;
        };
        let answers = Arc::clone(&answers);
        tokio::spawn(async move {
            let Ok(mut ws) = tokio_tungstenite::accept_async(tcp).await else {
                return;
            };
            while let Some(Ok(frame)) = ws.next().await {
                let Message::Text(text) = frame else { continue };
                let msg: serde_json::Value = serde_json::from_str(&text).expect("client JSON");
                if msg[0] != "REQ" {
                    continue;
                }
                let sub = msg[1].clone();
                let filter: Filter = serde_json::from_value(msg[2].clone()).expect("REQ filter");
                let substitutes: Vec<Event> = {
                    let answers = answers.lock().unwrap();
                    filter
                        .authors
                        .iter()
                        .flatten()
                        .filter_map(|author| answers.get(author))
                        .flatten()
                        .cloned()
                        .collect()
                };
                for event in &substitutes {
                    let out = serde_json::json!(["EVENT", sub, event]).to_string();
                    if ws.send(Message::text(out)).await.is_err() {
                        return;
                    }
                }
                let eose = serde_json::json!(["EOSE", sub]).to_string();
                if ws.send(Message::text(eose)).await.is_err() {
                    return;
                }
            }
        });
    }
}

/// The discovery plane is process-wide and one-shot, so the relay runs on a
/// thread of its own and outlives every test's runtime. Every test answers
/// for its own freshly generated author, so no test sees another's events.
fn discovery() -> &'static Substituting {
    static DISCOVERY: OnceLock<Substituting> = OnceLock::new();
    DISCOVERY.get_or_init(|| {
        let answers = Answers::default();
        let serving = Arc::clone(&answers);
        let (tx, rx) = std::sync::mpsc::channel();
        std::thread::spawn(move || {
            tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
                .expect("runtime")
                .block_on(async {
                    let listener = TcpListener::bind("127.0.0.1:0").await.expect("bind");
                    let url = format!("ws://{}", listener.local_addr().expect("local addr"));
                    tx.send(url).expect("hand the url over");
                    serve(listener, serving).await;
                });
        });
        let url = rx.recv().expect("discovery relay");
        let _ = allow_ws_loopback_for_test();
        set_discovery_relays_for_test(vec![url]).expect("install discovery");
        Substituting { answers }
    })
}

fn signed(keys: &Keys, kind: Kind, content: &str, tags: Vec<Tag>, at: u64) -> Event {
    EventBuilder::new(kind, content)
        .tags(tags)
        .custom_created_at(Timestamp::from_secs(at))
        .sign_with_keys(keys)
        .expect("a locally built event signs")
}

fn inbox_list(keys: &Keys, relay: &str, at: u64) -> Event {
    let tag = Tag::parse(["relay", relay]).unwrap();
    signed(keys, Kind::InboxRelays, "", vec![tag], at)
}

fn nip65_list(keys: &Keys, relay: &str, at: u64) -> Event {
    let tag = Tag::parse(["r", relay]).unwrap();
    signed(keys, Kind::RelayList, "", vec![tag], at)
}

/// A real `KeyPackage` whose MLS credential names `owner`, as a 30443 signed by
/// `signer` — the two differ only when a test forges the binding. Content and
/// tags are the production builder's, so nothing but the binding can refuse
/// a forged one.
async fn key_package(owner: &Keys, signer: &Keys, at: u64) -> Event {
    let (event, _) = minted_key_package(owner).await;
    signed(
        signer,
        Kind::Custom(30443),
        &event.content,
        event.tags.clone().to_vec(),
        at,
    )
}

/// `owner`'s own published 30443 and the wire bytes of the package it carries.
async fn minted_key_package(owner: &Keys) -> (Event, Vec<u8>) {
    let dir = tempfile::TempDir::new().unwrap();
    let session = SessionManager::new_unencrypted(dir.path(), owner).expect("session");
    let built = build_kp_maintenance_events(&session, owner, &[OWN_RELAY.to_owned()], None, None)
        .await
        .expect("mint a key package");
    (built.event, built.key_package.bytes().to_vec())
}

/// `event` with its tag named `name` replaced by `values`.
fn retagged(event: &Event, name: &str, values: &[&str]) -> Vec<Tag> {
    event
        .tags
        .iter()
        .map(|tag| {
            if tag.as_slice()[0] == name {
                Tag::parse(std::iter::once(name).chain(values.iter().copied())).unwrap()
            } else {
                tag.clone()
            }
        })
        .collect()
}

/// A 30443 of `keys` carrying `package`, tagged as `like` is but for the slot
/// and the `KeyPackageRef`: valid wherever the package itself is.
fn twin_event(keys: &Keys, like: &Event, package: &Minted, slot: u8, at: u64) -> Event {
    let slot = hex::encode([slot; 32]);
    let key_package_ref = hex::encode(&package.key_package_ref);
    let mut tags = retagged(like, "d", &[&slot]);
    tags = tags
        .into_iter()
        .map(|tag| {
            if tag.as_slice()[0] == "i" {
                Tag::parse(["i", key_package_ref.as_str()]).unwrap()
            } else {
                tag
            }
        })
        .collect();
    let content = base64::engine::general_purpose::STANDARD.encode(&package.bytes);
    signed(keys, Kind::Custom(30443), &content, tags, at)
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_substituted_inbox_list_is_never_taken_for_the_invitees() {
    let relay = discovery();
    let (invitee, attacker) = (Keys::generate(), Keys::generate());
    relay.answer(
        &invitee,
        vec![inbox_list(&attacker, "wss://attacker.example", 2_000)],
    );

    let listed = RelayManager::new()
        .fetch_inbox_relays(&invitee.public_key().to_hex())
        .await
        .expect("the fetch runs");
    assert!(
        listed.is_empty(),
        "another author's 10050 was taken for the invitee's inbox"
    );

    let genuine = Keys::generate();
    relay.answer(
        &genuine,
        vec![
            inbox_list(&genuine, "wss://genuine.example", 1_000),
            inbox_list(&attacker, "wss://attacker.example", 3_000),
            // The invitee's own signature on the wrong kind is not their list.
            signed(
                &genuine,
                Kind::TextNote,
                "",
                vec![Tag::parse(["relay", "wss://note.example"]).unwrap()],
                4_000,
            ),
        ],
    );
    let listed = RelayManager::new()
        .fetch_inbox_relays(&genuine.public_key().to_hex())
        .await
        .expect("the fetch runs");
    assert_eq!(listed, ["wss://genuine.example"]);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_substituted_nip65_list_is_never_taken_for_the_invitees() {
    let relay = discovery();
    let (invitee, attacker) = (Keys::generate(), Keys::generate());
    relay.answer(
        &invitee,
        vec![nip65_list(&attacker, "wss://attacker.example", 2_000)],
    );

    let listed = RelayManager::new()
        .fetch_nip65_relay_list(&invitee.public_key().to_hex())
        .await
        .expect("the fetch runs");
    assert!(
        listed.read.is_empty() && listed.write.is_empty(),
        "another author's 10002 was taken for the invitee's relay list"
    );

    let genuine = Keys::generate();
    relay.answer(
        &genuine,
        vec![
            nip65_list(&genuine, "wss://genuine.example", 1_000),
            nip65_list(&attacker, "wss://attacker.example", 3_000),
            signed(
                &genuine,
                Kind::TextNote,
                "",
                vec![Tag::parse(["r", "wss://note.example"]).unwrap()],
                4_000,
            ),
        ],
    );
    let listed = RelayManager::new()
        .fetch_nip65_relay_list(&genuine.public_key().to_hex())
        .await
        .expect("the fetch runs");
    assert_eq!(listed.read, ["wss://genuine.example"]);
    assert_eq!(listed.write, ["wss://genuine.example"]);
}

/// The attack itself: the inviter asks for the invitee's `KeyPackage` and a
/// relay hands back one it can sign — its own, or the invitee's re-signed. The
/// Welcome goes to the event's author, so either would put the wrong account
/// in the circle or strand the invitation.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_substituted_key_package_is_never_selected() {
    let relay = discovery();
    let (invitee, attacker) = (Keys::generate(), Keys::generate());
    relay.answer(
        &invitee,
        vec![
            key_package(&attacker, &attacker, 2_000).await,
            key_package(&invitee, &attacker, 3_000).await,
        ],
    );

    let picked = RelayManager::new()
        .fetch_keypackage(&invitee.public_key().to_hex())
        .await
        .expect("the fetch runs");
    assert!(
        picked.is_none(),
        "a key package the invitee did not sign was selected"
    );

    let genuine = Keys::generate();
    let own = key_package(&genuine, &genuine, 1_000).await;
    relay.answer(
        &genuine,
        vec![
            own.clone(),
            key_package(&attacker, &attacker, 2_000).await,
            key_package(&genuine, &attacker, 3_000).await,
        ],
    );
    let picked = RelayManager::new()
        .fetch_keypackage(&genuine.public_key().to_hex())
        .await
        .expect("the fetch runs")
        .expect("the invitee's own key package is found");
    assert_eq!(picked.id, own.id);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_key_package_whose_credential_is_not_its_author_is_rejected() {
    let relay = discovery();
    let (invitee, other) = (Keys::generate(), Keys::generate());
    relay.answer(&invitee, vec![key_package(&other, &invitee, 2_000).await]);

    let picked = RelayManager::new()
        .fetch_keypackage(&invitee.public_key().to_hex())
        .await
        .expect("the fetch runs");
    assert!(
        picked.is_none(),
        "a key package whose MLS credential names another account was selected"
    );
}

/// An invitee's write relays are theirs to name, so they are dialled for the
/// lookup and never join the shared publish pool, which would otherwise hold
/// every invitee's relays for the life of the process.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_invitees_relays_are_dialled_for_the_lookup_and_never_kept_in_the_shared_pool() {
    discovery();
    let invitee = Keys::generate();
    let own = key_package(&invitee, &invitee, 1_000).await;
    let answers = Answers::default();
    answers
        .lock()
        .unwrap()
        .insert(invitee.public_key(), vec![own.clone()]);
    let listener = TcpListener::bind("127.0.0.1:0").await.expect("bind");
    let write = format!("ws://{}", listener.local_addr().expect("local addr"));
    let server = tokio::spawn(serve(listener, answers));

    let manager = RelayManager::new();
    let picked = manager
        .fetch_keypackage_with_cascade(&invitee.public_key().to_hex(), std::slice::from_ref(&write))
        .await
        .expect("the fetch runs")
        .expect("the key package is served by the invitee's write relay");
    server.abort();

    assert_eq!(
        picked.id, own.id,
        "only the write relay holds it, so it was really dialled"
    );
    let write = nostr::RelayUrl::parse(&write).unwrap();
    assert!(
        manager
            .get_relay_status()
            .await
            .iter()
            .all(|status| nostr::RelayUrl::parse(&status.url).ok().as_ref() != Some(&write)),
        "the invitee's relay stayed in the shared pool"
    );
}

/// The "is our event published on this relay" check counts only events that
/// match what it asked for: another author's event of the kind is not ours.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_substituted_event_never_reads_as_published() {
    discovery();
    let (account, attacker) = (Keys::generate(), Keys::generate());
    let answers = Answers::default();
    answers.lock().unwrap().insert(
        account.public_key(),
        vec![inbox_list(&attacker, "wss://attacker.example", 2_000)],
    );
    let listener = TcpListener::bind("127.0.0.1:0").await.expect("bind");
    let url = format!("ws://{}", listener.local_addr().expect("local addr"));
    let server = tokio::spawn(serve(listener, Arc::clone(&answers)));
    let asked = Filter::new()
        .kind(Kind::InboxRelays)
        .author(account.public_key());

    let manager = RelayManager::new();
    let check = manager
        .check_event_on_relay(&url, asked.clone())
        .await
        .expect("the check runs");
    assert!(
        !check.found && check.event_count == 0,
        "another author's event was counted as ours being published"
    );

    answers.lock().unwrap().insert(
        account.public_key(),
        vec![
            inbox_list(&attacker, "wss://attacker.example", 2_000),
            inbox_list(&account, "wss://genuine.example", 1_000),
        ],
    );
    let check = manager
        .check_event_on_relay(&url, asked)
        .await
        .expect("the check runs");
    server.abort();
    assert!(check.found);
    assert_eq!(check.event_count, 1);
    assert_eq!(check.newest_timestamp, Some(1_000));
}

// ── Validation before ranking, and the ranking itself ───────────────────────

/// A candidate that is expired, or whose tags say something its package does
/// not, is never selected, however recently it was published: the older valid
/// package in another slot is (`foundation/key-packages.md:65-75`).
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn invalid_or_mismatched_kp_never_selected() {
    let relay = discovery();
    let invitee = Keys::generate();
    let (own, bytes) = minted_key_package(&invitee).await;
    let valid = signed(
        &invitee,
        own.kind,
        &own.content,
        own.tags.clone().to_vec(),
        1_000,
    );

    let expired = mint_unowned_like(
        &bytes,
        &invitee,
        Twin {
            lifetime: Some(expired_lifetime()),
            last_resort: true,
            without_component: None,
        },
    );
    let live = mint_unowned_like(
        &bytes,
        &invitee,
        Twin {
            lifetime: None,
            last_resort: true,
            without_component: None,
        },
    );
    let live_event = twin_event(&invitee, &own, &live, 3, 0);
    let invalid = vec![
        // Nothing wrong but its lifetime.
        twin_event(&invitee, &own, &expired, 2, 9_000),
        // Tags that claim a component the package does not carry.
        signed(
            &invitee,
            own.kind,
            &live_event.content,
            retagged(&live_event, "app_components", &["0x8001", "0x8fff"]),
            8_000,
        ),
    ];

    relay.answer(&invitee, invalid.clone());
    assert!(
        RelayManager::new()
            .fetch_keypackage(&invitee.public_key().to_hex())
            .await
            .expect("the fetch runs")
            .is_none(),
        "an expired or mis-tagged package was selected"
    );

    let mut all = invalid;
    all.push(valid.clone());
    relay.answer(&invitee, all);
    let picked = RelayManager::new()
        .fetch_keypackage(&invitee.public_key().to_hex())
        .await
        .expect("the fetch runs")
        .expect("the valid package is found past the invalid ones");
    assert_eq!(picked.id, valid.id);
}

/// Among valid candidates a package that is not last-resort is preferred to a
/// fresher last-resort one, then the more recently published, then the lower
/// `KeyPackageRef` (`foundation/key-packages.md:68-70`,
/// `transports/nostr.md:316-318`).
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn selection_prefers_non_last_resort_then_fresh_then_lower_ref() {
    let relay = discovery();
    let invitee = Keys::generate();
    let (own, bytes) = minted_key_package(&invitee).await;
    let twin = |last_resort| {
        mint_unowned_like(
            &bytes,
            &invitee,
            Twin {
                lifetime: None,
                last_resort,
                without_component: None,
            },
        )
    };
    let fetch = || async {
        RelayManager::new()
            .fetch_keypackage(&invitee.public_key().to_hex())
            .await
            .expect("the fetch runs")
            .expect("a package is selected")
            .id
    };

    let single_use_old = twin_event(&invitee, &own, &twin(false), 2, 1_000);
    let single_use_new = twin_event(&invitee, &own, &twin(false), 3, 2_000);
    let last_resort_newest = twin_event(&invitee, &own, &twin(true), 4, 9_000);
    relay.answer(
        &invitee,
        vec![last_resort_newest, single_use_old, single_use_new.clone()],
    );
    assert_eq!(
        fetch().await,
        single_use_new.id,
        "the fresher of the two packages that are not last-resort"
    );

    let (a, b) = (twin(true), twin(true));
    let lower = if a.key_package_ref < b.key_package_ref {
        5
    } else {
        6
    };
    let (a, b) = (
        twin_event(&invitee, &own, &a, 5, 5_000),
        twin_event(&invitee, &own, &b, 6, 5_000),
    );
    let expected = if lower == 5 { a.id } else { b.id };
    relay.answer(&invitee, vec![b, a]);
    assert_eq!(fetch().await, expected, "a tie goes to the lower ref");
}

/// The message-retention component every Haven circle requires (0x8005).
const RETENTION_COMPONENT: u16 = 0x8005;

/// A valid 30443 of `keys` in `slot` whose package does not support
/// [`RETENTION_COMPONENT`]: nothing wrong with it, and no Haven circle can
/// admit it.
fn retentionless(keys: &Keys, like: &Event, bytes: &[u8], slot: u8, at: u64) -> Event {
    let twin = mint_unowned_like(
        bytes,
        keys,
        Twin {
            lifetime: None,
            last_resort: true,
            without_component: Some(RETENTION_COMPONENT),
        },
    );
    let event = twin_event(keys, like, &twin, slot, 0);
    let dropped = format!("0x{RETENTION_COMPONENT:04x}");
    let components: Vec<String> = like
        .tags
        .iter()
        .find(|tag| tag.as_slice()[0] == "app_components")
        .expect("an app_components tag")
        .as_slice()[1..]
        .iter()
        .filter(|id| **id != dropped)
        .cloned()
        .collect();
    let components: Vec<&str> = components.iter().map(String::as_str).collect();
    signed(
        keys,
        Kind::Custom(30443),
        &event.content,
        retagged(&event, "app_components", &components),
        at,
    )
}

/// `event` as another app would publish it: the same package and tags plus
/// that app's `client` label.
fn labelled(keys: &Keys, event: &Event, at: u64) -> Event {
    let mut tags = event.tags.clone().to_vec();
    tags.push(Tag::parse(["client", "another-app"]).unwrap());
    signed(keys, Kind::Custom(30443), &event.content, tags, at)
}

/// An inviter's session, and what it requires of a package for a new circle
/// and for one it already has.
struct Inviter {
    session: SessionManager,
    _dir: tempfile::TempDir,
}

impl Inviter {
    fn new() -> Self {
        let dir = tempfile::TempDir::new().unwrap();
        let session =
            SessionManager::new_unencrypted(dir.path(), &Keys::generate()).expect("session");
        Self { session, _dir: dir }
    }

    /// The rule for a new circle, and the rule of an existing one.
    async fn rules(&self) -> [KeyPackageAdmissionRule; 2] {
        let (member, _) = minted_key_package(&Keys::generate()).await;
        let config = haven_core::nostr::mls::LocationGroupConfig::new("Existing")
            .with_relay(OWN_RELAY)
            .with_admin(self.session.identity_pubkey().to_hex());
        let created = self
            .session
            .create_group(
                vec![SessionManager::key_package_from_event(&member).expect("parse")],
                config,
            )
            .await
            .expect("an existing circle");
        [
            self.session
                .key_package_admission_rule(None)
                .await
                .expect("the rule for a new circle"),
            self.session
                .key_package_admission_rule(Some(&created.group_id))
                .await
                .expect("the rule of the existing circle"),
        ]
    }
}

/// The id of the package selected for `asked` from the discovery plane: for
/// the invite target whose rule is `rule`, or with no target in mind.
async fn selected(asked: &str, rule: Option<&KeyPackageAdmissionRule>) -> Option<nostr::EventId> {
    let manager = RelayManager::new();
    match rule {
        Some(rule) => manager.fetch_keypackage_for_invite(asked, &[], rule).await,
        None => manager.fetch_keypackage_with_cascade(asked, &[]).await,
    }
    .expect("the fetch runs")
    .map(|event| event.id)
}

/// `foundation/key-packages.md:65-66,72-75`: an incompatible candidate is
/// rejected BEFORE selection, and freshness never overrides capability
/// compatibility. Creating a circle and adding to an existing one both ask
/// with the target's own rule (MDK's `KeyPackageRequirements`).
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_fresher_package_the_circle_cannot_admit_never_beats_an_older_one_it_can() {
    let relay = discovery();
    let invitee = Keys::generate();
    let (own, bytes) = minted_key_package(&invitee).await;
    let admissible = signed(
        &invitee,
        own.kind,
        &own.content,
        own.tags.clone().to_vec(),
        1_000,
    );
    let fresher = retentionless(&invitee, &own, &bytes, 2, 9_000);
    let asking = Inviter::new();
    let rules = asking.rules().await;
    let asked = invitee.public_key().to_hex();

    relay.answer(&invitee, vec![fresher.clone(), admissible.clone()]);
    assert_eq!(
        selected(&asked, None).await,
        Some(fresher.id),
        "anti-vacuity: with no target the fresher package is a valid candidate and wins"
    );
    assert_eq!(
        asking.session.key_package_admission(&fresher, None).await,
        KeyPackageAdmission::Unusable,
        "anti-vacuity: and a Haven circle cannot admit it"
    );
    for rule in &rules {
        assert_eq!(
            selected(&asked, Some(rule)).await,
            Some(admissible.id),
            "the package the target can admit is the one selected"
        );
    }

    // Nothing admissible: the valid package is handed back so the inviter is
    // told it cannot be used, rather than "not found" — and it is refused.
    relay.answer(&invitee, vec![fresher.clone()]);
    for rule in &rules {
        assert_eq!(selected(&asked, Some(rule)).await, Some(fresher.id));
    }
}

/// The `client`-label tier orders packages the target ADMITS. A package with
/// no label that the circle cannot admit never displaces a labelled one it
/// can: requirements come first.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_unlabelled_package_the_circle_cannot_admit_never_beats_a_labelled_one_it_can() {
    let relay = discovery();
    let invitee = Keys::generate();
    let (own, bytes) = minted_key_package(&invitee).await;
    let other_app = labelled(&invitee, &own, 1_000);
    let unlabelled = retentionless(&invitee, &own, &bytes, 2, 9_000);
    let asking = Inviter::new();
    let rules = asking.rules().await;

    for order in [
        vec![unlabelled.clone(), other_app.clone()],
        vec![other_app.clone(), unlabelled.clone()],
    ] {
        relay.answer(&invitee, order);
        for rule in &rules {
            let picked = RelayManager::new()
                .fetch_keypackage_for_invite(&invitee.public_key().to_hex(), &[], rule)
                .await
                .expect("the fetch runs")
                .expect("a package is selected");
            assert_eq!(picked.id, other_app.id);
        }
    }
}

/// With both admissible, the package no app labelled is selected over a
/// fresher labelled one, for a new circle and for an existing one.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_admissible_unlabelled_package_beats_a_fresher_admissible_labelled_one() {
    let relay = discovery();
    let invitee = Keys::generate();
    let (own, _) = minted_key_package(&invitee).await;
    let (second, _) = minted_key_package(&invitee).await;
    let unlabelled = signed(
        &invitee,
        own.kind,
        &own.content,
        own.tags.clone().to_vec(),
        1_000,
    );
    let other_app = labelled(&invitee, &second, 9_000);
    let asking = Inviter::new();

    relay.answer(&invitee, vec![other_app, unlabelled.clone()]);
    for rule in &asking.rules().await {
        let picked = RelayManager::new()
            .fetch_keypackage_for_invite(&invitee.public_key().to_hex(), &[], rule)
            .await
            .expect("the fetch runs")
            .expect("a package is selected");
        assert_eq!(picked.id, unlabelled.id);
    }
}

/// A slot's newest event stands for the slot across the whole cascade. When
/// the account's own relays serve a newer event that is no candidate, the
/// discovery plane still serving the event it replaced does not bring that
/// one back: its owner may have deleted the key.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_slot_superseded_on_the_accounts_relays_is_not_revived_by_the_discovery_plane() {
    let relay = discovery();
    let invitee = Keys::generate();
    let (own, _) = minted_key_package(&invitee).await;
    let superseded = signed(
        &invitee,
        own.kind,
        &own.content,
        own.tags.clone().to_vec(),
        1_000,
    );
    // The same slot, newer, and carrying no package at all.
    let newest = signed(&invitee, own.kind, "", own.tags.clone().to_vec(), 9_000);

    let answers = Answers::default();
    answers
        .lock()
        .unwrap()
        .insert(invitee.public_key(), vec![newest]);
    let listener = TcpListener::bind("127.0.0.1:0").await.expect("bind");
    let write = format!("ws://{}", listener.local_addr().expect("local addr"));
    let server = tokio::spawn(serve(listener, answers));
    relay.answer(&invitee, vec![superseded.clone()]);

    let asked = &invitee.public_key().to_hex();
    let fetch = |write_relays: Vec<String>| async move {
        RelayManager::new()
            .fetch_keypackage_with_cascade(asked, &write_relays)
            .await
            .expect("the fetch runs")
            .map(|event| event.id)
    };
    assert_eq!(
        fetch(Vec::new()).await,
        Some(superseded.id),
        "anti-vacuity: on its own the discovery plane's copy is a valid candidate"
    );
    assert_eq!(
        fetch(vec![write]).await,
        None,
        "the slot was superseded where the account publishes"
    );
    server.abort();
}

/// A peer whose only package is a pre-migration one is handed back so the
/// picker can say they need to update — and is never invitable; a current
/// package, however old, is preferred to it.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_peer_with_only_a_pre_migration_package_needs_to_update() {
    let relay = discovery();
    let (invitee, other) = (Keys::generate(), Keys::generate());
    let legacy = |owner: &Keys, at| {
        let content = base64::engine::general_purpose::STANDARD.encode(pre_migration(owner));
        let slot = Tag::identifier("a".repeat(64));
        signed(&invitee, Kind::Custom(30443), &content, vec![slot], at)
    };
    let own_legacy = legacy(&invitee, 9_000);

    relay.answer(&invitee, vec![own_legacy.clone()]);
    let picked = RelayManager::new()
        .fetch_keypackage(&invitee.public_key().to_hex())
        .await
        .expect("the fetch runs")
        .expect("the pre-migration package is handed back");
    assert_eq!(picked.id, own_legacy.id);
    let dir = tempfile::TempDir::new().unwrap();
    let asking = SessionManager::new_unencrypted(dir.path(), &other).expect("session");
    assert_eq!(
        asking.key_package_admission(&picked, None).await,
        KeyPackageAdmission::NeedsUpdate
    );

    // A pre-migration package naming another account is nobody's to update.
    relay.answer(&invitee, vec![legacy(&other, 9_000)]);
    assert!(RelayManager::new()
        .fetch_keypackage(&invitee.public_key().to_hex())
        .await
        .expect("the fetch runs")
        .is_none());

    let (own, _) = minted_key_package(&invitee).await;
    let current = signed(
        &invitee,
        own.kind,
        &own.content,
        own.tags.clone().to_vec(),
        1_000,
    );
    relay.answer(&invitee, vec![own_legacy, current.clone()]);
    let picked = RelayManager::new()
        .fetch_keypackage(&invitee.public_key().to_hex())
        .await
        .expect("the fetch runs")
        .expect("the current package is found");
    assert_eq!(picked.id, current.id);
    assert_eq!(
        asking.key_package_admission(&picked, None).await,
        KeyPackageAdmission::Admissible
    );
}

/// Haven signs and publishes Current-profile packages only.
#[test]
fn kp_publish_refuses_legacy_bytes() {
    let keys = Keys::generate();
    assert!(build_kp_maintenance_events_reusing(
        &keys,
        &pre_migration(&keys),
        &[OWN_RELAY.to_owned()],
        &"a".repeat(64),
        None,
    )
    .is_err());
}
