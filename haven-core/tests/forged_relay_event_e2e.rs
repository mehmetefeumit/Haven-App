//! One relay that holds no key forges events on every plane the publish client
//! reads, and none of them is acted on.
//!
//! The relay pool skips verification for an event whose claimed id it has
//! verified before, so a relay first shows the client some validly signed event
//! under a subscription nobody opened (the prime) and then answers the real
//! `REQ` with anything it likes under that id. Two shapes cover what it can
//! forge: an event "by" any account, built over an event the relay signed
//! itself ([`forged_as`]), and a rewrite of a genuine event under the genuine
//! id ([`rewritten`]). Every test below was red before Haven verified each
//! relay event itself (`relay::verified`); group messages and the live-sync planes
//! have their own tests in `forged_group_event_e2e.rs`.
//!
//! No test waits on time: every fetch ends on the scripted relay's `EOSE`.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, OnceLock};

use haven_core::circle::{
    default_relays, set_default_relays_for_test, CircleManager, ProfileSyncOutcome,
};
use haven_core::nostr::mls::SessionManager;
use haven_core::profile::{
    fetch_profiles_assigned, profile_relay_pool_default, read_own_profile_on_relays,
    set_profile_relays_for_test, CachedProfile, OwnProfileOnRelays, PendingEdits, ProfileMetadata,
    ProfileRelaySalt, ProfileState,
};
use haven_core::relay::maintenance::build_kp_maintenance_events;
use haven_core::relay::scripted_relay::{Frame, ScriptedRelay};
use haven_core::relay::{
    discovery_relays, normalize_relay_url, set_discovery_relays_for_test, RelayManager,
};
use nostr::secp256k1::schnorr::Signature;
use nostr::{
    Event, EventBuilder, Filter, JsonUtil as _, Keys, Kind, Metadata, PublicKey, Tag, Timestamp,
};
use tempfile::TempDir;

mod helpers;
use helpers::{assert_no_needles, assert_some_line_from, capture_haven_log, haven_core_lines};

/// Injected profile clock (Unix seconds).
const NOW: i64 = 1_800_000_000;

fn signed(keys: &Keys, kind: Kind, content: &str, tags: Vec<Tag>, at: u64) -> Event {
    EventBuilder::new(kind, content)
        .tags(tags)
        .custom_created_at(Timestamp::from_secs(at))
        .sign_with_keys(keys)
        .expect("a locally built event signs")
}

/// An event "by" `victim` that no key of theirs signed, and the prime it
/// borrows its id from: an event the relay signed with a key of its own.
fn forged_as(
    victim: &PublicKey,
    kind: Kind,
    content: &str,
    tags: Vec<Tag>,
    at: u64,
) -> (Event, Event) {
    let prime = signed(&Keys::generate(), Kind::TextNote, "prime", vec![], at);
    let forged = Event::new(
        prime.id,
        *victim,
        Timestamp::from_secs(at),
        kind,
        tags,
        content,
        Signature::from_slice(&[7; 64]).expect("any 64 bytes parse as a signature"),
    );
    (prime, forged)
}

/// `genuine` with `rewrite` applied and its id and signature left as they were.
fn rewritten(genuine: &Event, rewrite: impl FnOnce(&mut Event)) -> Event {
    let mut forged = genuine.clone();
    rewrite(&mut forged);
    forged
}

/// The prime under a subscription nobody opened, then `answer`, then `EOSE`.
fn primed(prime: &Event, answer: Vec<Event>) -> Vec<Frame> {
    std::iter::once(Frame::Unasked(prime.clone()))
        .chain(answer.into_iter().map(Frame::Event))
        .chain(std::iter::once(Frame::Eose))
        .collect()
}

fn honest(answer: Vec<Event>) -> Vec<Frame> {
    answer
        .into_iter()
        .map(Frame::Event)
        .chain(std::iter::once(Frame::Eose))
        .collect()
}

/// A `REQ` for `author`'s events of `kind`.
fn asks(author: PublicKey, kind: Kind) -> impl Fn(&Filter) -> bool + Send + Sync + 'static {
    move |filter| {
        filter.authors.as_ref().is_some_and(|a| a.contains(&author))
            && filter.kinds.as_ref().is_some_and(|k| k.contains(&kind))
    }
}

fn relay_tag(name: &str, url: &str) -> Vec<Tag> {
    vec![Tag::parse([name, url]).expect("a relay tag")]
}

fn urls(relays: &[&ScriptedRelay]) -> Vec<String> {
    relays.iter().map(|relay| relay.url().to_owned()).collect()
}

/// The discovery plane of this binary: a hostile indexer and an honest one.
/// The override is process-wide and one-shot, and every test asks about an
/// account of its own, so none sees another's script.
struct Discovery {
    hostile: ScriptedRelay,
    honest: ScriptedRelay,
}

fn discovery() -> &'static Discovery {
    static DISCOVERY: OnceLock<Discovery> = OnceLock::new();
    DISCOVERY.get_or_init(|| {
        let plane = Discovery {
            hostile: ScriptedRelay::start(),
            honest: ScriptedRelay::start(),
        };
        set_discovery_relays_for_test(urls(&[&plane.hostile, &plane.honest]))
            .expect("install the discovery plane once");
        plane
    })
}

/// The profile pool of this binary: one hostile relay and two that only record
/// what is published to them.
struct ProfilePool {
    hostile: ScriptedRelay,
    recording: [ScriptedRelay; 2],
}

fn profile_pool() -> &'static ProfilePool {
    static POOL: OnceLock<ProfilePool> = OnceLock::new();
    POOL.get_or_init(|| {
        let pool = ProfilePool {
            hostile: ScriptedRelay::start(),
            recording: [ScriptedRelay::start(), ScriptedRelay::start()],
        };
        let normalized: Vec<String> =
            urls(&[&pool.hostile, &pool.recording[0], &pool.recording[1]])
                .iter()
                .filter_map(|url| normalize_relay_url(url))
                .collect();
        assert_eq!(normalized.len(), 3, "a loopback url did not normalize");
        set_profile_relays_for_test(normalized).expect("install the profile pool once");
        pool
    })
}

/// Installs both planes and the account seed. Every test starts here, whatever
/// it goes on to dial: a lookup that falls through to the discovery plane, a
/// profile read that falls through to the profile pool, or an account or
/// circle that falls back to the seed relays, then reaches a relay of this
/// process and never a production host.
fn hermetic() -> (&'static Discovery, &'static ProfilePool) {
    static SEED: OnceLock<ScriptedRelay> = OnceLock::new();
    SEED.get_or_init(|| {
        let seed = ScriptedRelay::start();
        set_default_relays_for_test(vec![seed.url().to_owned()])
            .expect("install the account seed once");
        seed
    });
    (discovery(), profile_pool())
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

// ── Another account's relay lists (kinds 10050 and 10002) ───────────────────

/// A forged list newer than the genuine one would send the invitation, or the
/// `KeyPackage` lookup, to relays of the forger's choosing.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_forged_relay_list_never_replaces_the_one_its_owner_signed() {
    let (plane, _) = hermetic();
    let manager = RelayManager::new();

    let invitee = Keys::generate();
    let (prime, forged) = forged_as(
        &invitee.public_key(),
        Kind::InboxRelays,
        "",
        relay_tag("relay", "wss://attacker.example.com"),
        2_000,
    );
    plane.hostile.answer(
        asks(invitee.public_key(), Kind::InboxRelays),
        primed(&prime, vec![forged]),
    );
    plane.honest.answer(
        asks(invitee.public_key(), Kind::InboxRelays),
        honest(vec![signed(
            &invitee,
            Kind::InboxRelays,
            "",
            relay_tag("relay", "wss://genuine.example.com"),
            1_000,
        )]),
    );
    let inbox = manager
        .fetch_inbox_relays(&invitee.public_key().to_hex())
        .await
        .expect("the fetch runs");
    assert_eq!(inbox, ["wss://genuine.example.com"]);

    let (prime, forged) = forged_as(
        &invitee.public_key(),
        Kind::RelayList,
        "",
        relay_tag("r", "wss://attacker.example.com"),
        2_000,
    );
    plane.hostile.answer(
        asks(invitee.public_key(), Kind::RelayList),
        primed(&prime, vec![forged]),
    );
    plane.honest.answer(
        asks(invitee.public_key(), Kind::RelayList),
        honest(vec![signed(
            &invitee,
            Kind::RelayList,
            "",
            relay_tag("r", "wss://genuine.example.com"),
            1_000,
        )]),
    );
    let list = manager
        .fetch_nip65_relay_list(&invitee.public_key().to_hex())
        .await
        .expect("the fetch runs");
    assert_eq!(list.read, ["wss://genuine.example.com"]);
    assert_eq!(list.write, ["wss://genuine.example.com"]);
}

/// Rule 15: a forgery is dropped without a word. The needles are everything
/// the relay chose — the address it planted, the event id, the account it
/// forged as, the signature, its own address.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_forged_relay_list_leaves_nothing_in_a_log() {
    let (plane, _) = hermetic();
    let invitee = Keys::generate();
    let (prime, forged) = forged_as(
        &invitee.public_key(),
        Kind::InboxRelays,
        "",
        relay_tag("relay", "wss://canary-attacker.example.com"),
        2_000,
    );
    plane.hostile.answer(
        asks(invitee.public_key(), Kind::InboxRelays),
        primed(&prime, vec![forged.clone()]),
    );

    let lines = capture_haven_log(async {
        let inbox = RelayManager::new()
            .fetch_inbox_relays(&invitee.public_key().to_hex())
            .await
            .expect("the fetch runs");
        assert!(
            inbox.is_empty(),
            "the scenario ran: the forged list was not taken"
        );
    })
    .await;

    // Haven's own lines: a dependency's are kept out of every sink by target
    // (`haven/rust_builder`'s logger), and the relays in this process log too.
    let ours = haven_core_lines(&lines);
    assert_some_line_from(&ours, "haven_core::relay::manager");
    assert_no_needles(
        &ours,
        &[
            "canary-attacker",
            &forged.id.to_hex(),
            &forged.pubkey.to_hex(),
            &forged.sig.to_string(),
            plane.hostile.url().trim_start_matches("ws://"),
        ],
    );
}

/// Where the check sits. The forgery borrows the GENUINE list's id, and the
/// pool keeps only the first event it sees under an id, so a check made on
/// what the pool hands back would find the forgery, refuse it, and have
/// nothing left: the genuine list was already thrown away as a repeat.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_forgery_under_the_genuine_lists_id_does_not_cost_the_genuine_list() {
    let (plane, _) = hermetic();
    let manager = RelayManager::new();
    let attacker_list = |genuine: &Event| {
        rewritten(genuine, |event| {
            event.tags = nostr::Tags::from_list(relay_tag("relay", "wss://attacker.example.com"));
        })
    };

    // On one socket, so the order is the relay's and not the scheduler's: the
    // forgery first, the genuine list behind it.
    let invitee = Keys::generate();
    let genuine = signed(
        &invitee,
        Kind::InboxRelays,
        "",
        relay_tag("relay", "wss://genuine.example.com"),
        1_000,
    );
    plane.hostile.answer(
        asks(invitee.public_key(), Kind::InboxRelays),
        primed(&genuine, vec![attacker_list(&genuine), genuine.clone()]),
    );
    let inbox = manager
        .fetch_inbox_relays(&invitee.public_key().to_hex())
        .await
        .expect("the fetch runs");
    assert_eq!(inbox, ["wss://genuine.example.com"]);

    // And across two relays, where either may answer first: the hostile one
    // forges, the honest one serves the list.
    let invitee = Keys::generate();
    let genuine = signed(
        &invitee,
        Kind::InboxRelays,
        "",
        relay_tag("relay", "wss://genuine.example.com"),
        1_000,
    );
    plane.hostile.answer(
        asks(invitee.public_key(), Kind::InboxRelays),
        primed(&genuine, vec![attacker_list(&genuine)]),
    );
    plane.honest.answer(
        asks(invitee.public_key(), Kind::InboxRelays),
        honest(vec![genuine]),
    );
    let inbox = manager
        .fetch_inbox_relays(&invitee.public_key().to_hex())
        .await
        .expect("the fetch runs");
    assert_eq!(inbox, ["wss://genuine.example.com"]);
}

// ── Another account's KeyPackage (kind 30443) ───────────────────────────────

async fn minted_key_package(owner: &Keys) -> Event {
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

/// A superseded package is genuine content, so re-wrapping it as the newest
/// event of its slot would make the invitation one its owner can no longer
/// open — and a `client` label added to the wrapper would move it down the
/// ranking of an inviter that prefers unlabelled packages.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_superseded_key_package_rewrapped_as_the_newest_is_never_selected() {
    // With nothing invitable on the account's own relay the lookup goes on to
    // the discovery plane, which must be this process's.
    hermetic();
    let own_relay = ScriptedRelay::start();
    let owner = Keys::generate();
    let slot = hex::encode([5; 32]);
    let in_slot = |minted: &Event, at: u64| {
        let tags = minted
            .tags
            .iter()
            .map(|tag| match tag.as_slice()[0].as_str() {
                "d" => Tag::parse(["d", slot.as_str()]).expect("a d tag"),
                _ => tag.clone(),
            })
            .collect();
        signed(&owner, Kind::Custom(30443), &minted.content, tags, at)
    };
    let superseded = in_slot(&minted_key_package(&owner).await, 1_000);
    let newest = in_slot(&minted_key_package(&owner).await, 2_000);

    let mut tags = superseded.tags.clone().to_vec();
    tags.push(Tag::parse(["client", "another-app"]).expect("a client tag"));
    let (prime, rewrapped) = forged_as(
        &owner.public_key(),
        Kind::Custom(30443),
        &superseded.content,
        tags,
        3_000,
    );
    own_relay.answer(
        asks(owner.public_key(), Kind::Custom(30443)),
        primed(&prime, vec![rewrapped, newest.clone()]),
    );

    let selected = RelayManager::new()
        .fetch_keypackage_with_cascade(&owner.public_key().to_hex(), &urls(&[&own_relay]))
        .await
        .expect("the fetch runs")
        .expect("the account has a package");
    assert!(
        selected == newest,
        "the re-wrapped superseded package was selected over the slot's genuine newest"
    );
}

// ── Profiles (kind 0) ───────────────────────────────────────────────────────

fn profile(keys: &Keys, content: &str, at: u64) -> Event {
    signed(keys, Kind::Metadata, content, vec![], at)
}

/// A relay is asked for one member's profile and nothing else is asked of
/// anyone, so what it answers is the name and photo shown on the map.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_forged_profile_never_names_a_member() {
    hermetic();
    let assigned = ScriptedRelay::start();
    let pool = urls(&[&assigned]);
    let salt = ProfileRelaySalt::generate();
    let manager = RelayManager::new();

    // The forged profile also names a picture: the picture a member's avatar
    // is downloaded from is the one in the profile resolved here, so a forged
    // one would send the viewer to a host of the forger's choosing.
    let member = Keys::generate();
    let (prime, forged) = forged_as(
        &member.public_key(),
        Kind::Metadata,
        r#"{"display_name":"Forged","picture":"https://attacker.example.com/a.jpg"}"#,
        vec![],
        2_000,
    );
    let genuine = profile(&member, r#"{"display_name":"Genuine"}"#, 1_000);
    assigned.answer(
        asks(member.public_key(), Kind::Metadata),
        primed(&prime, vec![forged.clone(), genuine]),
    );
    let fetched = fetch_profiles_assigned(&manager, &[(member.public_key(), 0)], &salt, &pool, NOW)
        .await
        .expect("the cycle runs");
    let shown: Vec<_> = fetched
        .resolved
        .iter()
        .map(|profile| (profile.metadata.display_name(), profile.metadata.picture()))
        .collect();
    assert_eq!(shown, [(Some("Genuine"), None)]);

    // With nothing genuine to fall back on the forgery is a miss, not a name.
    let stranger = Keys::generate();
    let (prime, forged) = forged_as(
        &stranger.public_key(),
        Kind::Metadata,
        r#"{"display_name":"Forged"}"#,
        vec![],
        2_000,
    );
    assigned.answer(
        asks(stranger.public_key(), Kind::Metadata),
        primed(&prime, vec![forged]),
    );
    let fetched =
        fetch_profiles_assigned(&manager, &[(stranger.public_key(), 0)], &salt, &pool, NOW)
            .await
            .expect("the cycle runs");
    assert!(fetched.resolved.is_empty(), "a forged profile was resolved");
    assert!(
        fetched.missed == [stranger.public_key()],
        "the relay answered, so the member is a miss and not left unasked"
    );
}

/// The own profile read back from the pool is the base an edit is merged onto,
/// and the merged object is signed with the identity key. A forged copy would
/// be laundered into a genuine profile carrying fields of the forger's
/// choosing — a payment address among them — under a timestamp it chose too.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_forged_own_profile_is_never_merged_into_the_one_haven_signs() {
    let (_, pool) = hermetic();
    let dir = TempDir::new().expect("temp dir");
    let keys = Keys::generate();
    let manager = CircleManager::new_unencrypted(dir.path(), &keys).expect("manager opens");
    let own = keys.public_key();

    let forged_at = Timestamp::now().as_secs() + 86_400;
    let (prime, forged) = forged_as(
        &own,
        Kind::Metadata,
        r#"{"display_name":"Forged","lud16":"canary@attacker.example.com"}"#,
        vec![],
        forged_at,
    );
    pool.hostile
        .answer(asks(own, Kind::Metadata), primed(&prime, vec![forged]));

    let edit = PendingEdits {
        display_name: Some("Mine".to_owned()),
        ..PendingEdits::default()
    };
    manager
        .stage_own_profile_edits(&own.to_hex(), &edit, NOW)
        .expect("stage the edit");
    let report = manager
        .sync_own_profile(&keys, || NOW)
        .await
        .expect("the sync runs");
    assert_eq!(report.outcome, ProfileSyncOutcome::Published);

    let published: Vec<Event> = [&pool.hostile, &pool.recording[0], &pool.recording[1]]
        .into_iter()
        .flat_map(ScriptedRelay::published)
        .filter(|event| event.pubkey == own)
        .collect();
    assert_eq!(published.len(), 3, "the profile goes to every pool relay");
    for event in published {
        assert!(
            event.verify().is_ok(),
            "Haven published an event it did not sign"
        );
        assert!(event.content.contains("Mine"));
        assert!(
            !event.content.contains("canary"),
            "a field from a forged profile was signed and published"
        );
        assert!(
            event.created_at.as_secs() < forged_at,
            "the published timestamp was steered by a forged profile"
        );
    }
}

/// Not a forgery, and so not something verification can refuse: a pool relay
/// answers with an OLD copy of the user's own profile while the others hold
/// nothing. The profile this device published since is the newer one, so the
/// next edit is merged onto that, and nothing the user removed is signed back.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_superseded_own_profile_is_never_the_base_of_the_next_edit() {
    let (_, pool) = hermetic();
    let dir = TempDir::new().expect("temp dir");
    let keys = Keys::generate();
    let manager = CircleManager::new_unencrypted(dir.path(), &keys).expect("manager opens");
    let own = keys.public_key();
    let edit = |display_name: Option<&str>, about: Option<&str>| PendingEdits {
        display_name: display_name.map(str::to_owned),
        about: about.map(str::to_owned),
        ..PendingEdits::default()
    };
    let published_by_now = || -> Vec<Event> {
        pool.recording[0]
            .published()
            .into_iter()
            .filter(|event| event.pubkey == own)
            .collect()
    };

    // The profile as this device last published it: a name, and nothing else.
    manager
        .stage_own_profile_edits(&own.to_hex(), &edit(Some("Mine"), None), NOW)
        .expect("stage the name");
    let first = manager.sync_own_profile(&keys, || NOW).await.expect("sync");
    assert_eq!(first.outcome, ProfileSyncOutcome::Published);
    let current = published_by_now().pop().expect("the first publish");

    // One relay still serves last month's copy, payment address and all.
    let stale = profile(
        &keys,
        r#"{"display_name":"Old","lud16":"old@wallet.example.com","website":"https://old.example.com"}"#,
        current.created_at.as_secs() - 2_592_000,
    );
    pool.hostile
        .answer(asks(own, Kind::Metadata), honest(vec![stale]));

    manager
        .stage_own_profile_edits(&own.to_hex(), &edit(None, Some("bio")), NOW + 1)
        .expect("stage the bio");
    let second = manager
        .sync_own_profile(&keys, || NOW + 1)
        .await
        .expect("sync");
    assert_eq!(second.outcome, ProfileSyncOutcome::Published);

    let republished = published_by_now().pop().expect("the second publish");
    assert!(republished.id != current.id && republished.created_at > current.created_at);
    assert!(republished.content.contains("Mine") && republished.content.contains("bio"));
    assert!(
        !republished.content.contains("lud16") && !republished.content.contains("website"),
        "a field of a superseded copy was signed back into the profile"
    );
}

/// A copy read for a publish is a copy this device has read, whether or not
/// the publish then lands. Another client removed a field; this device reads
/// that newer copy to merge its edit onto, and no relay takes the publish. On
/// the retry the only relay to answer is one that never took the newer copy.
/// Had the newer copy been forgotten with the failed publish, the old one
/// would tie the row and be the base, and the removed field would be signed
/// back, superseding the other client's profile everywhere.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_newer_copy_read_for_a_publish_that_failed_is_what_the_retry_builds_on() {
    let (_, pool) = hermetic();
    let dir = TempDir::new().expect("temp dir");
    let keys = Keys::generate();
    let manager = CircleManager::new_unencrypted(dir.path(), &keys).expect("manager opens");
    let own = keys.public_key();
    let now = Timestamp::now().as_secs();

    // What this device holds: the profile as it was, payment address and all.
    let held = profile(
        &keys,
        r#"{"display_name":"Mine","lud16":"old@wallet.example.com"}"#,
        now - 1_000,
    );
    manager
        .upsert_profile(&CachedProfile {
            pubkey_hex: own.to_hex(),
            metadata: ProfileMetadata::from_metadata(
                Metadata::from_json(&held.content).expect("metadata"),
            ),
            state: ProfileState::Known,
            event_created_at: i64::try_from(held.created_at.as_secs()).expect("a timestamp"),
            fetched_at: NOW,
        })
        .expect("cache the held profile");
    // Another client has removed the address since; one relay serves that.
    let newer = profile(&keys, r#"{"display_name":"Mine"}"#, now - 500);
    let newer_at = i64::try_from(newer.created_at.as_secs()).expect("a timestamp");
    pool.recording[0].answer(asks(own, Kind::Metadata), honest(vec![newer]));
    // No relay takes this account's publish, for now.
    let refusing = Arc::new(AtomicBool::new(true));
    for relay in [&pool.hostile, &pool.recording[0], &pool.recording[1]] {
        let refusing = Arc::clone(&refusing);
        relay.refuse(move |event| event.pubkey == own && refusing.load(Ordering::SeqCst));
    }

    let bio = PendingEdits {
        about: Some("bio".to_owned()),
        ..PendingEdits::default()
    };
    manager
        .stage_own_profile_edits(&own.to_hex(), &bio, NOW)
        .expect("stage the bio");
    let failed = manager.sync_own_profile(&keys, || NOW).await.expect("sync");
    assert_eq!(failed.outcome, ProfileSyncOutcome::PublishFailed);
    assert_eq!(
        manager
            .pending_profile_sync(&own.to_hex())
            .expect("outbox read")
            .map(|pending| pending.edits),
        Some(bio),
        "the edit is still queued, as saved"
    );
    let row = manager
        .get_profile(&own.to_hex())
        .expect("row read")
        .expect("the own row");
    assert_eq!(
        (
            row.metadata.as_metadata().about.as_deref(),
            row.metadata.as_metadata().lud16.as_deref()
        ),
        (Some("bio"), None),
        "the row is the newer copy with the queued edit still on it"
    );
    assert_eq!(row.event_created_at, newer_at);

    // The retry: the relay that had the newer copy answers with nothing, and
    // one that never took it serves the old copy.
    pool.recording[0].answer(asks(own, Kind::Metadata), honest(vec![]));
    pool.hostile
        .answer(asks(own, Kind::Metadata), honest(vec![held]));
    refusing.store(false, Ordering::SeqCst);
    let retried = manager
        .sync_own_profile(&keys, || NOW + 1)
        .await
        .expect("sync");
    assert_eq!(retried.outcome, ProfileSyncOutcome::Published);

    let published: Vec<Event> = pool.recording[1]
        .published()
        .into_iter()
        .filter(|event| event.pubkey == own)
        .collect();
    assert_eq!(
        published.len(),
        1,
        "anti-vacuity: the first publish reached no relay"
    );
    assert!(published[0].content.contains("Mine") && published[0].content.contains("bio"));
    assert!(
        !published[0].content.contains("lud16"),
        "a field another client removed was signed back into the profile"
    );
}

/// The retraction gate reads "is my profile on the relays?": a forged copy
/// must not answer yes, and a relay that answered with only a forgery has
/// answered — it holds nothing.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_forged_own_profile_is_not_a_published_one() {
    hermetic();
    let relays = [ScriptedRelay::start(), ScriptedRelay::start()];
    let own = Keys::generate().public_key();
    for relay in &relays {
        let (prime, forged) = forged_as(
            &own,
            Kind::Metadata,
            r#"{"display_name":"Forged"}"#,
            vec![],
            2_000,
        );
        relay.answer(asks(own, Kind::Metadata), primed(&prime, vec![forged]));
    }

    let read = read_own_profile_on_relays(
        &RelayManager::new(),
        own,
        &urls(&[&relays[0], &relays[1]]),
        NOW,
    )
    .await;
    assert!(
        matches!(read, OwnProfileOnRelays::Absent),
        "a forged own profile read as published, or as a relay left unasked"
    );
}

// ── The per-relay read and the status read ──────────────────────────────────

/// The read every maintenance probe, the catch-up pager and the invitation
/// poll are built on. A forgery is dropped as if the relay had withheld it:
/// the relay still answered, its page is still whole, and the genuine event
/// it sent behind the forgery — under the same id — is still read.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_per_relay_read_drops_a_forgery_and_keeps_what_follows_it() {
    hermetic();
    let relay = ScriptedRelay::start();
    let author = Keys::generate();
    let genuine = signed(&author, Kind::Custom(445), "genuine", vec![], 1_000);
    let forged = rewritten(&genuine, |event| event.content = "forged".to_owned());
    relay.answer(
        asks(author.public_key(), Kind::Custom(445)),
        primed(&genuine, vec![forged, genuine.clone()]),
    );

    let outcomes = RelayManager::new()
        .fetch_events_per_relay(
            Filter::new()
                .author(author.public_key())
                .kind(Kind::Custom(445)),
            &urls(&[&relay]),
        )
        .await
        .expect("the read never fails as a whole");
    let [outcome] = outcomes.as_slice() else {
        panic!("one relay was asked, so one outcome is owed");
    };
    assert!(outcome.responded && outcome.drained);
    assert!(
        outcome.events == [genuine],
        "the page is not exactly the genuine event the relay sent behind its forgery"
    );
}

/// Two genuine events of one second: NIP-01 keeps the lower id. The page puts
/// that one first whichever the relay sent first, because a maintenance probe
/// reads the first event of a slot as the slot's.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_per_relay_page_puts_the_event_nip01_keeps_first_whatever_the_relay_sent_first() {
    hermetic();
    let author = Keys::generate();
    let mut pair = [
        signed(
            &author,
            Kind::InboxRelays,
            "",
            relay_tag("relay", "wss://one.example.com"),
            1_000,
        ),
        signed(
            &author,
            Kind::InboxRelays,
            "",
            relay_tag("relay", "wss://two.example.com"),
            1_000,
        ),
    ];
    pair.sort_by_key(|event| event.id);
    let [kept, discarded] = pair;

    for sent in [
        vec![kept.clone(), discarded.clone()],
        vec![discarded.clone(), kept.clone()],
    ] {
        let relay = ScriptedRelay::start();
        relay.answer(asks(author.public_key(), Kind::InboxRelays), honest(sent));
        let outcomes = RelayManager::new()
            .fetch_events_per_relay(
                Filter::new()
                    .author(author.public_key())
                    .kind(Kind::InboxRelays),
                &urls(&[&relay]),
            )
            .await
            .expect("the read never fails as a whole");
        assert!(
            outcomes[0].events == [kept.clone(), discarded.clone()],
            "the page does not lead with the lower id of a same-second pair"
        );
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_forged_event_never_reads_as_published_on_a_relay() {
    hermetic();
    let relay = ScriptedRelay::start();
    let own = Keys::generate().public_key();
    let (prime, forged) = forged_as(
        &own,
        Kind::InboxRelays,
        "",
        relay_tag("relay", "wss://own.example.com"),
        2_000,
    );
    relay.answer(asks(own, Kind::InboxRelays), primed(&prime, vec![forged]));

    let check = RelayManager::new()
        .check_event_on_relay(
            relay.url(),
            Filter::new().author(own).kind(Kind::InboxRelays),
        )
        .await
        .expect("the check runs");
    assert!(!check.found && check.event_count == 0);
}
