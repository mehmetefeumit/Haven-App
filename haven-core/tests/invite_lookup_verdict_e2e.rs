//! An invite lookup tells "this person has no `KeyPackage`" from "the relays
//! that would hold one did not finish answering"
//! (`RelayManager::lookup_member_for_invite`). The first ends the invite; the
//! second is worth a retry, so reporting it as the first strands an invitee
//! whose package is there.
//!
//! The relays are scripted (`relay::scripted_relay`): each answers `EOSE`,
//! `CLOSED`, nothing, or is not there, as a test says. Every test asks about
//! an account of its own, so the shared discovery plane's scripts never meet.

mod helpers;

use std::sync::OnceLock;
use std::time::Duration;

use base64::Engine as _;
use haven_core::circle::set_default_relays_for_test;
use haven_core::nostr::mls::types::KeyPackageAdmissionRule;
use haven_core::nostr::mls::SessionManager;
use haven_core::relay::fanout::ReinviteLookup;
use haven_core::relay::maintenance::build_kp_maintenance_events;
use haven_core::relay::scripted_relay::{Frame, ScriptedRelay};
use haven_core::relay::{set_discovery_relays_for_test, MemberLookup, RelayManager};
use helpers::twin_key_packages::pre_migration;
use helpers::{assert_no_needles, assert_some_line_from, capture_haven_log, haven_core_lines};
use nostr::prelude::ToBech32 as _;
use nostr::{Event, EventBuilder, Filter, Keys, Kind, PublicKey, Tag, Timestamp};
use tempfile::TempDir;

/// The discovery plane of this binary: two indexers, installed once.
struct Discovery {
    a: ScriptedRelay,
    b: ScriptedRelay,
}

impl Discovery {
    fn urls(&self) -> [String; 2] {
        [self.a.url().to_owned(), self.b.url().to_owned()]
    }
}

/// Installs the discovery plane and the account seed, so nothing a lookup
/// falls back to is a production host.
fn discovery() -> &'static Discovery {
    static PLANE: OnceLock<Discovery> = OnceLock::new();
    PLANE.get_or_init(|| {
        let plane = Discovery {
            a: ScriptedRelay::start(),
            b: ScriptedRelay::start(),
        };
        set_discovery_relays_for_test(plane.urls().to_vec()).expect("install discovery once");
        set_default_relays_for_test(vec![plane.a.url().to_owned()]).expect("install the seed once");
        plane
    })
}

/// A `REQ` for `author`'s events of `kind`.
fn asks(author: PublicKey, kind: Kind) -> impl Fn(&Filter) -> bool + Send + Sync + 'static {
    move |filter| {
        filter.authors.as_ref().is_some_and(|a| a.contains(&author))
            && filter.kinds.as_ref().is_some_and(|k| k.contains(&kind))
    }
}

fn served(events: Vec<Event>) -> Vec<Frame> {
    events
        .into_iter()
        .map(Frame::Event)
        .chain(std::iter::once(Frame::Eose))
        .collect()
}

/// Relay-authored text: it must never reach a log (Security Rule 15).
const CLOSED_TEXT: &str = "blocked: closed-for-needle-7f3a";

fn closed() -> Vec<Frame> {
    vec![Frame::Closed(CLOSED_TEXT.to_owned())]
}

fn signed(keys: &Keys, kind: Kind, content: &str, tags: Vec<Tag>, at: u64) -> Event {
    EventBuilder::new(kind, content)
        .tags(tags)
        .custom_created_at(Timestamp::from_secs(at))
        .sign_with_keys(keys)
        .expect("a locally built event signs")
}

fn nip65(keys: &Keys, write: &str) -> Event {
    let tag = Tag::parse(["r", write]).expect("an r tag");
    signed(keys, Kind::RelayList, "", vec![tag], 1_000)
}

fn inbox(keys: &Keys, relay: &str) -> Event {
    let tag = Tag::parse(["relay", relay]).expect("a relay tag");
    signed(keys, Kind::InboxRelays, "", vec![tag], 1_000)
}

async fn key_package(owner: &Keys) -> Event {
    let dir = TempDir::new().expect("temp dir");
    let session = SessionManager::new_unencrypted(dir.path(), owner).expect("session");
    build_kp_maintenance_events(
        &session,
        owner,
        &["wss://own.example.com".to_owned()],
        None,
        None,
    )
    .await
    .expect("mint a key package")
    .event
}

/// What a new circle of an inviter requires.
async fn rule() -> KeyPackageAdmissionRule {
    let dir = TempDir::new().expect("temp dir");
    SessionManager::new_unencrypted(dir.path(), &Keys::generate())
        .expect("session")
        .key_package_admission_rule(None)
        .await
        .expect("the rule for a new circle")
}

async fn look_up(who: &Keys) -> MemberLookup {
    RelayManager::lookup_member_for_invite(&who.public_key().to_hex(), &rule().await)
        .await
        .expect("the lookup runs")
}

const fn verdict(lookup: &MemberLookup) -> &'static str {
    match lookup {
        MemberLookup::Found(_) => "found",
        MemberLookup::NotFound => "not found",
        MemberLookup::Incomplete => "incomplete",
    }
}

/// A loopback address nothing listens on.
fn dead_relay() -> String {
    let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("bind");
    let port = listener.local_addr().expect("local addr").port();
    drop(listener);
    format!("ws://127.0.0.1:{port}")
}

/// Every discovery relay answered every REQ with `EOSE` and nothing else: the
/// account has no 10002, so discovery holds its packages, and it has none.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn every_relay_finishing_empty_is_not_found() {
    discovery();
    let invitee = Keys::generate();
    assert_eq!(verdict(&look_up(&invitee).await), "not found");
}

/// D5: one indexer ends the REQs for the 10002 and the packages with `CLOSED`
/// while the other answers empty. It said nothing about the person, so the
/// lookup cannot say they have no package.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_indexer_closing_the_req_is_incomplete_not_absent() {
    let plane = discovery();
    let invitee = Keys::generate();
    for kind in [Kind::RelayList, Kind::Custom(30443)] {
        plane.a.answer(asks(invitee.public_key(), kind), closed());
    }
    assert_eq!(verdict(&look_up(&invitee).await), "incomplete");
}

/// Both indexers close the 10002 REQ: the write set is unknown, so even an
/// empty package answer from both proves nothing.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_unanswered_relay_list_is_incomplete() {
    let plane = discovery();
    let invitee = Keys::generate();
    plane
        .a
        .answer(asks(invitee.public_key(), Kind::RelayList), closed());
    plane
        .b
        .answer(asks(invitee.public_key(), Kind::RelayList), closed());
    assert_eq!(verdict(&look_up(&invitee).await), "incomplete");
}

/// The person names one write relay and it is down: discovery answering
/// empty does not prove they have no package, since it is not where they put
/// it.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_dead_write_relay_is_incomplete() {
    let plane = discovery();
    let invitee = Keys::generate();
    plane.a.answer(
        asks(invitee.public_key(), Kind::RelayList),
        served(vec![nip65(&invitee, &dead_relay())]),
    );
    assert_eq!(verdict(&look_up(&invitee).await), "incomplete");
}

/// A write relay that connects and never answers withholds the verdict, and
/// the same relay answering empty gives it.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_connected_silent_write_relay_is_incomplete() {
    let plane = discovery();
    let (silent, answering) = (ScriptedRelay::start(), ScriptedRelay::start());
    // Kept, so the hold never opens.
    let (_held, never) = tokio::sync::watch::channel(false);

    let invitee = Keys::generate();
    silent.answer(
        asks(invitee.public_key(), Kind::Custom(30443)),
        vec![Frame::Hold(never)],
    );
    plane.a.answer(
        asks(invitee.public_key(), Kind::RelayList),
        served(vec![nip65(&invitee, silent.url())]),
    );
    let lookup = RelayManager::lookup_member_for_invite_within(
        &invitee.public_key().to_hex(),
        &rule().await,
        Duration::from_secs(2),
    )
    .await
    .expect("the lookup runs");
    assert_eq!(verdict(&lookup), "incomplete");
    assert!(silent.connections() > 0, "the write relay was dialled");

    let control = Keys::generate();
    plane.a.answer(
        asks(control.public_key(), Kind::RelayList),
        served(vec![nip65(&control, answering.url())]),
    );
    assert_eq!(
        verdict(&look_up(&control).await),
        "not found",
        "anti-vacuity: the same lookup over a write relay that answers proves absence"
    );
}

/// The write set holds the person's packages, so it alone decides: it
/// answered empty, and discovery refusing to answer changes nothing.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_live_empty_write_relay_is_not_found_whatever_discovery_says() {
    let plane = discovery();
    let write = ScriptedRelay::start();
    let invitee = Keys::generate();
    plane.a.answer(
        asks(invitee.public_key(), Kind::RelayList),
        served(vec![nip65(&invitee, write.url())]),
    );
    plane
        .a
        .answer(asks(invitee.public_key(), Kind::Custom(30443)), closed());
    plane
        .b
        .answer(asks(invitee.public_key(), Kind::Custom(30443)), closed());
    assert_eq!(verdict(&look_up(&invitee).await), "not found");
    assert!(write.connections() > 0, "the write relay was asked");
}

/// A package on the write relay is found, with the lists a Welcome is routed
/// by.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_package_on_the_write_relay_is_found_with_the_lists() {
    let plane = discovery();
    let write = ScriptedRelay::start();
    let invitee = Keys::generate();
    let package = key_package(&invitee).await;
    write.answer(
        asks(invitee.public_key(), Kind::Custom(30443)),
        served(vec![package.clone()]),
    );
    plane.a.answer(
        asks(invitee.public_key(), Kind::RelayList),
        served(vec![nip65(&invitee, write.url())]),
    );
    plane.b.answer(
        asks(invitee.public_key(), Kind::InboxRelays),
        served(vec![inbox(&invitee, "wss://inbox.example.com")]),
    );
    let MemberLookup::Found(member) = look_up(&invitee).await else {
        panic!("the package on the write relay was not found");
    };
    assert_eq!(member.key_package_event.id, package.id);
    assert_eq!(member.inbox_relays, ["wss://inbox.example.com"]);
    assert_eq!(member.nip65_write_relays, [write.url()]);
}

/// A package no circle can take is still found — the caller says "needs to
/// update" — and never reads as "no account", however the rest answered.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn only_a_pre_migration_package_is_found() {
    let plane = discovery();
    let invitee = Keys::generate();
    let content = base64::engine::general_purpose::STANDARD.encode(pre_migration(&invitee));
    let legacy = signed(
        &invitee,
        Kind::Custom(30443),
        &content,
        vec![Tag::identifier("a".repeat(64))],
        1_000,
    );
    plane.a.answer(
        asks(invitee.public_key(), Kind::Custom(30443)),
        served(vec![legacy.clone()]),
    );
    plane
        .b
        .answer(asks(invitee.public_key(), Kind::Custom(30443)), closed());
    let MemberLookup::Found(member) = look_up(&invitee).await else {
        panic!("a pre-migration package read as no package");
    };
    assert_eq!(member.key_package_event.id, legacy.id);
}

/// A re-invite looks up on a client of its own: it finds a package exactly as
/// an invite does, and the shared manager it was asked through never dials
/// the person's relays or the discovery plane.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_reinvite_lookup_leaves_the_shared_pool_untouched() {
    let plane = discovery();
    let fixture = helpers::setup_circle(2, &["wss://location.example.com"]).await;
    let admin = fixture.admin();
    let write = ScriptedRelay::start();
    let invitee = Keys::generate();
    let package = key_package(&invitee).await;
    write.answer(
        asks(invitee.public_key(), Kind::Custom(30443)),
        served(vec![package.clone()]),
    );
    plane.a.answer(
        asks(invitee.public_key(), Kind::RelayList),
        served(vec![nip65(&invitee, write.url())]),
    );

    let shared = RelayManager::new();
    let found = shared
        .member(
            &admin.circle,
            &fixture.group,
            &invitee.public_key().to_hex(),
        )
        .await
        .expect("the package is found");
    assert_eq!(found.key_package_event.id, package.id);
    assert!(
        shared
            .member(
                &admin.circle,
                &fixture.group,
                &Keys::generate().public_key().to_hex(),
            )
            .await
            .is_none(),
        "no package is no member"
    );
    assert!(
        shared.get_relay_status().await.is_empty(),
        "the shared pool dialled a relay of the lookup"
    );
}

/// No log line names the person, a relay, or what a relay said, on any of
/// the verdicts.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_lookup_logs_no_person_relay_or_relay_text() {
    let plane = discovery();
    let write = ScriptedRelay::start();
    let dead = dead_relay();
    let (found, closing, stranded) = (Keys::generate(), Keys::generate(), Keys::generate());
    write.answer(
        asks(found.public_key(), Kind::Custom(30443)),
        served(vec![key_package(&found).await]),
    );
    plane.a.answer(
        asks(found.public_key(), Kind::RelayList),
        served(vec![nip65(&found, write.url())]),
    );
    plane
        .a
        .answer(asks(closing.public_key(), Kind::Custom(30443)), closed());
    plane.a.answer(
        asks(stranded.public_key(), Kind::RelayList),
        served(vec![nip65(&stranded, &dead)]),
    );

    let mut seen = Vec::new();
    let lines = capture_haven_log(async {
        for who in [&found, &closing, &stranded] {
            seen.push(verdict(&look_up(who).await));
        }
    })
    .await;
    assert_eq!(seen, ["found", "incomplete", "incomplete"], "premise");

    let haven = haven_core_lines(&lines);
    assert_some_line_from(&haven, "haven_core");
    // The relay's own words, without the `blocked:` prefix any refusal shares.
    let said = CLOSED_TEXT.trim_start_matches("blocked: ").to_owned();
    let mut needles: Vec<String> = vec![write.url().to_owned(), dead, said];
    needles.extend(plane.urls());
    for who in [&found, &closing, &stranded] {
        needles.push(who.public_key().to_hex());
        needles.push(who.public_key().to_bech32().expect("an npub"));
    }
    let needles: Vec<&str> = needles.iter().map(String::as_str).collect();
    assert_no_needles(&haven, &needles);
}
