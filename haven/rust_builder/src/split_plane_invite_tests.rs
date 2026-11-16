//! An invitation crosses every plane it travels on, through the FFI's own
//! orchestration, to an invitee whose first inbox relay takes gift wraps and
//! serves them only to a client that authenticates — as `relay.damus.io` does
//! under strfry's default `restrictedReadKinds`. The invitee's own inbox reads
//! answer that relay's NIP-42 challenge with the identity key (owner-directed
//! 2026-11-16); nothing else Haven sends ever does.
//!
//! The invitee's lists go in through the user path and out through the
//! product's relay-list and `KeyPackage` maintenance; the inviter finds them
//! with the product lookup over this binary's discovery relay, which is no
//! account's relay, and invites with the driven create or add. The invitee
//! reads its inbox over the list its store holds, by the page fetch and by the
//! live engine's bus as `live_events` reads it, and takes each wrap in as Dart
//! does. Every relay sits behind a recording front, so each arm also proves its
//! own premise: the gate fired, the gated relay took the Welcome, and only an
//! own inbox read's connection ever answered a challenge.
//!
//! One world serves every arm: this binary's tests gate the E2E lanes. No wait
//! here is a sleep: each awaits a recorded frame or a product outcome, bounded
//! by a budget scaled for instrumented runs. No assertion message names a relay
//! or a key (Security Rule 15).

use super::maintenance_real_ffi_tests::{
    fetch_by_kind, install_test_seams, secret_bytes, DataDir, FrontedRelay, UNANSWERING_SEED,
};
use super::{
    AcceptFailureFfi, BacklogOutcomeFfi, CircleCreationOutcomeFfi, CircleManagerFfi, InboxReadFfi,
    InvitationFfi, KpMaintenanceActionFfi, LiveSyncFfi, MemberKeyPackageFfi,
    MemberLookupVerdictFfi, PublishStatusFfi, RelayGiftWrapFetchFfi, RelayListActionFfi,
    RelayManagerFfi, RelayTypeFfi,
};
use haven_core::nostr::mls::KEY_PACKAGE_REPLACEMENT_GRACE_SECS;
use haven_core::relay::live_sync::{LiveEvents, LiveSyncEvent};
use haven_core::relay::maintenance::{read_kp_lifetime, TrackedKpLifetime};
use haven_core::relay::recording_front::{RecordedFrame, RecordingFront};
use nostr::{Keys, Kind};
use std::sync::atomic::Ordering;
use std::time::Duration;

/// The longest a product outcome or a frame may take, unscaled.
const WAIT: Duration = Duration::from_mins(1);

/// [`WAIT`] scaled by `HAVEN_TEST_WAIT_SCALE` for instrumented runs, as the
/// e2e tests scale theirs. Absent or unparsable means 1.
fn budget() -> Duration {
    WAIT * std::env::var("HAVEN_TEST_WAIT_SCALE")
        .ok()
        .and_then(|v| v.parse::<u32>().ok())
        .filter(|s| *s >= 1)
        .unwrap_or(1)
}

async fn within<T>(what: &str, fut: impl std::future::Future<Output = T>) -> T {
    tokio::time::timeout(budget(), fut)
        .await
        .unwrap_or_else(|_| panic!("{what} did not finish within its budget"))
}

/// Two spellings of one relay: the store canonicalises what the user typed.
fn same_relay(a: &str, b: &str) -> bool {
    a.trim_end_matches('/') == b.trim_end_matches('/')
}

fn same_relays(a: &[String], b: &[&str]) -> bool {
    a.len() == b.len() && a.iter().zip(b).all(|(a, b)| same_relay(a, b))
}

/// Every relay of the test, each in one role.
struct World {
    /// The inviter's own inbox and `KeyPackage` relay.
    inviter_account: FrontedRelay,
    /// The invitee's first inbox relay: it gates gift-wrap reads.
    gated: FrontedRelay,
    /// The invitee's second inbox relay: it serves them.
    plain: FrontedRelay,
    /// A second gating relay, for the inbox every relay of which gates them.
    gated_too: FrontedRelay,
    /// A relay that refuses gift-wrap reads even once the reader authenticated.
    refusing: FrontedRelay,
    /// Where the circles' group traffic goes.
    location: FrontedRelay,
    /// This binary's discovery relay: no account's relay.
    discovery: String,
    /// Every product network call goes through this one handle, as Dart's do.
    relays: RelayManagerFfi,
}

impl World {
    async fn start() -> Self {
        install_test_seams();
        let discovery = haven_core::relay::discovery_relays();
        assert!(
            discovery.len() == 1 && discovery[0].starts_with("ws://127.0.0.1:"),
            "the binary's discovery plane is one in-process relay",
        );
        let world = Self {
            inviter_account: FrontedRelay::run().await,
            gated: FrontedRelay::run_gating().await,
            plain: FrontedRelay::run().await,
            gated_too: FrontedRelay::run_gating().await,
            refusing: FrontedRelay::run_refusing().await,
            location: FrontedRelay::run().await,
            discovery: discovery[0].clone(),
            relays: RelayManagerFfi::new_instance()
                .await
                .expect("RelayManagerFfi::new_instance"),
        };
        let fronts = [
            world.inviter_account.front.url(),
            world.gated.front.url(),
            world.plain.front.url(),
            world.gated_too.front.url(),
            world.refusing.front.url(),
            world.location.front.url(),
        ];
        assert!(
            fronts.iter().all(|url| !same_relay(url, &world.discovery)),
            "the discovery relay is none of the accounts' relays",
        );
        world
    }

    fn fronts(&self) -> [&RecordingFront; 6] {
        [
            &self.inviter_account.front,
            &self.gated.front,
            &self.plain.front,
            &self.gated_too.front,
            &self.refusing.front,
            &self.location.front,
        ]
    }
}

/// One installation: its own SQLCipher directory, on the in-memory keyring.
struct Account {
    keys: Keys,
    // Declared before the directory, so the store closes before it is removed.
    circle: CircleManagerFfi,
    _dir: DataDir,
}

impl Account {
    fn new(tag: &str) -> Self {
        let keys = Keys::generate();
        let dir = DataDir::new(tag);
        let circle = CircleManagerFfi::new(dir.as_str(), secret_bytes(&keys))
            .expect("CircleManagerFfi::new");
        Self {
            keys,
            circle,
            _dir: dir,
        }
    }

    fn secret(&self) -> Vec<u8> {
        secret_bytes(&self.keys)
    }

    fn hex(&self) -> String {
        self.keys.public_key().to_hex()
    }

    async fn stored(&self, category: RelayTypeFfi) -> Vec<String> {
        self.circle
            .list_user_relays(category)
            .await
            .expect("the stored relay list")
    }
}

/// The inviter: its own relay for both of its lists, added as a user does.
async fn inviter(world: &World) -> Account {
    let alice = Account::new("split_plane_inviter");
    for category in [RelayTypeFfi::Inbox, RelayTypeFfi::Nip65] {
        alice
            .circle
            .add_user_relay(world.inviter_account.front.url().to_owned(), category)
            .await
            .expect("the inviter's own relay");
    }
    alice
}

/// An invitee whose lists the user typed, in order, and the product published:
/// both relay lists to its own relays and the discovery relay, then its
/// `KeyPackage` to its `KeyPackage` relays.
async fn invitee(world: &World, tag: &str, inbox: &[&str], key_packages: &[&str]) -> Account {
    let bob = Account::new(tag);
    for url in inbox {
        bob.circle
            .add_user_relay((*url).to_owned(), RelayTypeFfi::Inbox)
            .await
            .expect("an inbox relay");
    }
    for url in key_packages {
        bob.circle
            .add_user_relay((*url).to_owned(), RelayTypeFfi::Nip65)
            .await
            .expect("a KeyPackage relay");
    }
    // A category left empty would be seeded by the first tick with this
    // binary's unanswering seed; neither is, so the lists are exactly these.
    let stored_inbox = bob.stored(RelayTypeFfi::Inbox).await;
    let stored_kp = bob.stored(RelayTypeFfi::Nip65).await;
    assert!(
        same_relays(&stored_inbox, inbox) && same_relays(&stored_kp, key_packages),
        "the stored lists are what the user typed, in that order",
    );

    let lists = within(
        "the relay-list tick",
        world.relays.maintain_relay_list(&bob.circle, bob.secret()),
    )
    .await
    .expect("the relay-list tick runs");
    assert!(
        matches!(lists.inbox.action, RelayListActionFfi::Republished)
            && matches!(lists.key_package.action, RelayListActionFfi::Republished)
            && lists.inbox.own_confirmed
            && lists.key_package.own_confirmed,
        "the invitee's 10050 and 10002 were published to its own relays",
    );
    let kp = within(
        "the KeyPackage tick",
        world.relays.maintain_key_package(&bob.circle, bob.secret()),
    )
    .await
    .expect("the KeyPackage tick runs");
    assert_eq!(kp.action, KpMaintenanceActionFfi::RepublishedFreshD);
    assert!(
        usize::try_from(kp.relays_healed).is_ok_and(|healed| healed == key_packages.len()),
        "every KeyPackage relay acknowledged the invitee's package",
    );

    for (kind, category, stored) in [
        (Kind::InboxRelays, RelayTypeFfi::Inbox, &stored_inbox),
        (Kind::RelayList, RelayTypeFfi::Nip65, &stored_kp),
    ] {
        let held = fetch_by_kind(bob.keys.public_key(), kind, &world.discovery).await;
        let [list] = <[_; 1]>::try_from(held)
            .unwrap_or_else(|_| panic!("the discovery relay holds one list of each kind"));
        let urls = super::relay_list_urls_for(category, &list).expect("the list's relays");
        assert!(
            urls.len() == stored.len() && urls.iter().zip(stored).all(|(a, b)| same_relay(a, b)),
            "the discovery relay holds the stored list, in order",
        );
        assert!(
            !urls.iter().any(|url| same_relay(url, UNANSWERING_SEED)),
            "no seed relay reached a published list",
        );
    }
    bob
}

/// The inviter's product lookup of `bob`, for `group` or a new circle.
async fn look_up(
    world: &World,
    alice: &Account,
    bob: &Account,
    group: Option<Vec<u8>>,
) -> MemberKeyPackageFfi {
    let lookup = within(
        "the invite lookup",
        world
            .relays
            .fetch_member_keypackage(bob.hex(), &alice.circle, group),
    )
    .await
    .expect("the lookup runs");
    assert_eq!(lookup.verdict, MemberLookupVerdictFfi::Found);
    let member = lookup.member.expect("a found member");
    let stored_inbox = bob.stored(RelayTypeFfi::Inbox).await;
    let stored_kp = bob.stored(RelayTypeFfi::Nip65).await;
    // The two lists are ordered differently, so this tells the 10050 from the
    // 10002 it could otherwise have been read from.
    assert!(
        member.inbox_relays.len() == stored_inbox.len()
            && member
                .inbox_relays
                .iter()
                .zip(&stored_inbox)
                .all(|(a, b)| same_relay(a, b)),
        "the Welcome's relays are the invitee's published 10050, in order",
    );
    assert!(
        member.nip65_write_relays.len() == stored_kp.len()
            && member
                .nip65_write_relays
                .iter()
                .zip(&stored_kp)
                .all(|(a, b)| same_relay(a, b)),
        "the 10002 found is the invitee's own",
    );
    member
}

/// A driven create of a circle holding `members`, on the location relay.
async fn create(
    world: &World,
    alice: &Account,
    members: Vec<MemberKeyPackageFfi>,
    name: &str,
) -> CircleCreationOutcomeFfi {
    let created = within(
        "the create",
        world.relays.create_circle_driven(
            &alice.circle,
            alice.secret(),
            members,
            name.to_owned(),
            None,
            "location_sharing".to_owned(),
            vec![world.location.front.url().to_owned()],
            true,
        ),
    )
    .await
    .expect("the create runs");
    assert!(
        created.circle.is_some() && created.refusal.is_none(),
        "the circle was created",
    );
    created
}

fn json(frame: &RecordedFrame) -> Option<serde_json::Value> {
    serde_json::from_str(&frame.text).ok()
}

fn names(list: &serde_json::Value, wanted: &serde_json::Value) -> bool {
    list.as_array().is_some_and(|list| list.contains(wanted))
}

/// Whether `frame` is a `REQ` for `pubkey`'s gift wraps; with its `since`.
fn inbox_req(frame: &RecordedFrame, pubkey: &str) -> Option<Option<u64>> {
    let frame = json(frame)?;
    let frame = frame.as_array()?;
    if frame.first()?.as_str()? != "REQ" {
        return None;
    }
    frame.get(2..)?.iter().find_map(|filter| {
        (names(&filter["kinds"], &serde_json::json!(1059))
            && names(&filter["#p"], &serde_json::json!(pubkey)))
        .then(|| filter["since"].as_u64())
    })
}

/// The ids of the gift wraps for `pubkey` a client published here.
fn published_wraps(front: &RecordingFront, pubkey: &str) -> Vec<String> {
    front
        .frames()
        .iter()
        .filter_map(json)
        .filter(|frame| frame[0] == "EVENT" && frame[1]["kind"] == 1059)
        .filter(|frame| {
            frame[1]["tags"].as_array().is_some_and(|tags| {
                tags.iter()
                    .any(|tag| tag[0] == "p" && tag[1].as_str() == Some(pubkey))
            })
        })
        .filter_map(|frame| frame[1]["id"].as_str().map(str::to_owned))
        .collect()
}

/// How many of `pubkey`'s gift-wrap reads this gating front refused with an
/// `AUTH` challenge and `CLOSED auth-required:`.
fn refused_reads(front: &RecordingFront, pubkey: &str) -> usize {
    front
        .refused()
        .iter()
        .filter(|frame| inbox_req(frame, pubkey).is_some())
        .count()
}

/// Waits until this gating front has refused at least `n` of `pubkey`'s
/// gift-wrap reads, woken by each frame: a refused read is recorded as refused
/// before it is recorded at all.
async fn await_refused_reads(front: &RecordingFront, pubkey: &str, n: usize) {
    within(
        "the gate's refusal",
        front.wait_for(|_| refused_reads(front, pubkey) >= n),
    )
    .await;
}

/// Haven answers a relay's challenge only on an own inbox read's connection
/// (owner-directed 2026-11-16): every connection that sent an `AUTH` sent
/// nothing but valid answers under one key, `CLOSE`s and `REQ`s for that
/// key's gift wraps — no `EVENT` and no other `REQ` — so neither the publish
/// client nor a group plane ever authenticated.
fn assert_only_own_inbox_reads_authenticated(world: &World) {
    for front in world.fronts() {
        let frames = front.frames();
        let answering: std::collections::BTreeSet<usize> = frames
            .iter()
            .filter(|frame| json(frame).is_some_and(|frame| frame[0] == "AUTH"))
            .map(|frame| frame.conn)
            .collect();
        for conn in answering {
            let on: Vec<&RecordedFrame> = frames.iter().filter(|f| f.conn == conn).collect();
            let signers: std::collections::BTreeSet<String> = on
                .iter()
                .filter_map(|frame| json(frame))
                .filter(|frame| frame[0] == "AUTH")
                .map(|frame| {
                    let answer: nostr::Event = nostr::JsonUtil::from_json(frame[1].to_string())
                        .expect("an answer to a challenge is an event");
                    assert!(answer.verify().is_ok(), "an answer to a challenge verifies");
                    answer.pubkey.to_hex()
                })
                .collect();
            let [signer] = <[_; 1]>::try_from(signers.into_iter().collect::<Vec<_>>())
                .unwrap_or_else(|_| panic!("one connection answers under one key"));
            for frame in on {
                let verb = json(frame).and_then(|frame| frame[0].as_str().map(str::to_owned));
                assert!(
                    matches!(verb.as_deref(), Some("AUTH" | "CLOSE"))
                        || inbox_req(frame, &signer).is_some(),
                    "a connection that answered a challenge carried more than \
                     the answering key's own gift-wrap reads",
                );
            }
        }
    }
}

/// How many challenges `pubkey` answered on this front.
fn answers_from(front: &RecordingFront, pubkey: &str) -> usize {
    front
        .frames()
        .iter()
        .filter_map(json)
        .filter(|frame| frame[0] == "AUTH" && frame[1]["pubkey"].as_str() == Some(pubkey))
        .count()
}

fn wrap_id(wrap_json: &str) -> String {
    serde_json::from_str::<nostr::Event>(wrap_json)
        .expect("a gift wrap is an event")
        .id
        .to_hex()
}

/// The invitee's page fetch, over the inbox list its store holds and the
/// window Dart asks for.
async fn read_inbox(world: &World, bob: &Account) -> Vec<RelayGiftWrapFetchFfi> {
    let inbox = bob.stored(RelayTypeFfi::Inbox).await;
    let since = super::now_secs() - super::inbox_gift_wrap_lookback_secs();
    within(
        "the inbox read",
        world
            .relays
            .fetch_gift_wraps_per_relay(&bob.circle, inbox, Some(since)),
    )
    .await
    .expect("the inbox read runs")
}

/// The page fetch of an inbox of two relays, the first or both gating reads:
/// each read served once the invitee answered its challenge, and each the
/// same one Welcome.
async fn read_inbox_through_its_gate(world: &World, bob: &Account) -> String {
    let [first, second] = <[_; 2]>::try_from(read_inbox(world, bob).await)
        .unwrap_or_else(|_| panic!("one answer per inbox relay"));
    assert!(
        first.read == InboxReadFfi::Served && second.read == InboxReadFfi::Served,
        "a gated inbox relay's read is served once the invitee authenticated",
    );
    let [wrap] = <[_; 1]>::try_from(first.events)
        .unwrap_or_else(|_| panic!("the gated inbox relay serves the one Welcome"));
    assert!(
        second.events.len() == 1 && wrap_id(&second.events[0]) == wrap_id(&wrap),
        "both inbox relays serve the same one Welcome",
    );
    wrap
}

/// Takes `wrap` in as Dart does, and finds the invitation it opened held.
async fn take_in(alice: &Account, bob: &Account, wrap: &str) -> InvitationFfi {
    let intake = bob
        .circle
        .process_gift_wrapped_invitation(bob.secret(), wrap.to_owned())
        .await
        .expect("the intake runs");
    assert!(intake.failure.is_none(), "the Welcome opened");
    let invitation = intake.invitation.expect("the Welcome is a new invitation");
    let id = hex::decode(wrap_id(wrap)).expect("an event id");
    let pending = bob
        .circle
        .get_pending_invitations()
        .await
        .expect("the pending invitations");
    assert!(
        pending
            .iter()
            .any(|held| held.mls_group_id == id && held.inviter_pubkey == alice.hex()),
        "the invitation is held, from the inviter",
    );
    invitation
}

/// Accepts `invitation` and finds the invitee in the circle on both sides.
async fn join(alice: &Account, bob: &Account, invitation: &InvitationFfi, group: &[u8]) {
    let accepted = bob
        .circle
        .accept_invitation(invitation.mls_group_id.clone())
        .await
        .expect("the accept runs");
    assert!(accepted.failure.is_none(), "the invitation was accepted");
    let joined = accepted.joined.expect("the invitee joined");
    assert!(
        joined.circle.mls_group_id == group,
        "the invitee joined the inviter's circle",
    );
    for pubkey in [alice.hex(), bob.hex()] {
        assert!(
            joined.members.iter().any(|member| member.pubkey == pubkey),
            "the invitee's roster holds both of them",
        );
    }
    assert!(
        alice
            .circle
            .get_members(group.to_vec())
            .await
            .expect("the inviter's roster")
            .iter()
            .any(|member| member.pubkey == bob.hex()),
        "the inviter's roster holds the invitee",
    );
}

/// A live-sync handle over an invitee that holds no circle, and the inbox list
/// its store holds.
async fn live_over_no_circle(bob: &Account) -> (LiveSyncFfi, Vec<String>) {
    let live = LiveSyncFfi::new_instance(&bob.circle, bob.hex()).expect("a live-sync handle");
    assert!(
        bob.circle
            .get_circles()
            .await
            .expect("the circles")
            .is_empty(),
        "premise: the invitee holds no circle",
    );
    (live, bob.stored(RelayTypeFfi::Inbox).await)
}

/// The installed session's bus, read as `live_events` reads it: the first
/// consumer, which starts at the session's construction.
fn consumer() -> LiveEvents {
    let core = super::live_session_core()
        .expect("the session slot")
        .expect("the started session");
    let events = core.events();
    drop(core);
    events
}

/// The foreground session over no circle, its consumer taken once the start
/// has returned — the order Dart attaches in.
async fn start_live(bob: &Account) -> (LiveSyncFfi, LiveEvents) {
    let (live, inbox) = live_over_no_circle(bob).await;
    within("the live start", live.start_session(Vec::new(), inbox))
        .await
        .expect("a session with no circle starts");
    (live, consumer())
}

/// A background wake that finds no session, its consumer taken only once every
/// inbox relay has answered its stored replay: the worker is serial, so
/// whatever they held is already on the bus, ahead of anything reading it.
async fn start_burst_and_settle(bob: &Account) -> (LiveSyncFfi, LiveEvents) {
    let (live, inbox) = live_over_no_circle(bob).await;
    let budget_ms = u64::try_from(budget().as_millis()).expect("a budget in milliseconds");
    within(
        "the burst start",
        live.start_session_into_burst(Vec::new(), inbox, budget_ms),
    )
    .await
    .expect("a burst over no circle starts");
    assert_eq!(
        within("the backlog wait", live.wait_backlog_settled()).await,
        Ok(BacklogOutcomeFfi::Settled),
        "premise: every inbox relay answered before the bus was read",
    );
    (live, consumer())
}

/// The next Welcome the bus carries.
async fn next_welcome(events: &mut LiveEvents) -> String {
    within("a Welcome on the live bus", async {
        loop {
            match events.recv().await {
                Some(LiveSyncEvent::Welcome { gift_wrap_json }) => return gift_wrap_json,
                Some(_) => {}
                None => panic!("the live bus closed before a Welcome arrived"),
            }
        }
    })
    .await
}

async fn stop_live(live: &LiveSyncFfi) {
    within("the live stop", live.stop_session())
        .await
        .expect("the session stops");
}

/// Leaves the process globals as the test found them however it ends: the
/// maintenance clock on the wall clock, and no live session installed for the
/// next test to stop.
struct MaintenanceClock;

impl MaintenanceClock {
    fn set(&self, secs: u64) {
        super::MAINTENANCE_CLOCK_OVERRIDE_SECS.store(secs, Ordering::Relaxed);
    }
}

impl Drop for MaintenanceClock {
    fn drop(&mut self) {
        super::MAINTENANCE_CLOCK_OVERRIDE_SECS.store(0, Ordering::Relaxed);
        if let Ok(mut slot) = super::SESSION.write() {
            slot.take();
        }
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn split_plane_invites_reach_an_invitee_whose_first_inbox_relay_gates_reads() {
    let _keyring_guard = super::SHARED_KEYRING_TEST_LOCK.lock().await;
    let clock = MaintenanceClock;
    let world = World::start().await;
    let alice = inviter(&world).await;

    let group = first_inbox_relay_gates_reads(&world, &alice).await;
    every_inbox_relay_gates_reads(&world, &alice).await;
    an_inbox_relay_refusing_after_authentication_serves_nothing(&world, &alice).await;
    a_fresh_invitee_hears_a_welcome_live(&world, &alice, group).await;
    a_superseded_key_package_opens_only_within_its_grace(&world, &alice, &clock).await;
    a_welcome_stored_before_the_session_reaches_it(&world, &alice).await;
}

/// (a) The Welcome reaches both inbox relays: the page fetch reads it from
/// the first, which gates reads, once the invitee answered its challenge, and
/// from the second; the live engine reads it too. Returns the circle.
async fn first_inbox_relay_gates_reads(world: &World, alice: &Account) -> Vec<u8> {
    let gated = world.gated.front.url();
    let plain = world.plain.front.url();
    let bob = invitee(world, "split_plane_a", &[gated, plain], &[plain, gated]).await;
    let member = look_up(world, alice, &bob, None).await;
    assert!(
        same_relay(&member.inbox_relays[0], gated),
        "premise: the gating relay is the first inbox relay",
    );
    let created = create(world, alice, vec![member], "Gated first").await;
    assert!(
        created.welcomes_sent == 1 && created.welcomes_total == 1,
        "an inbox relay acknowledged the one Welcome",
    );
    let group = created.circle.expect("the circle").mls_group_id;

    let wrap = read_inbox_through_its_gate(world, &bob).await;
    assert!(
        answers_from(&world.gated.front, &bob.hex()) >= 1,
        "premise: the gated relay was read after the invitee's answer",
    );
    // Compared, never rendered: a failure must not print an event id.
    assert!(
        published_wraps(&world.gated.front, &bob.hex()) == [wrap_id(&wrap)],
        "premise: the gated relay was sent the Welcome, and took it",
    );
    let invitation = take_in(alice, &bob, &wrap).await;

    let (live, mut events) = start_live(&bob).await;
    let heard = next_welcome(&mut events).await;
    stop_live(&live).await;
    assert!(
        wrap_id(&heard) == wrap_id(&wrap),
        "the live engine read the same Welcome past the gate",
    );
    let again = bob
        .circle
        .process_gift_wrapped_invitation(bob.secret(), heard)
        .await
        .expect("the intake runs");
    assert!(
        again.invitation.is_none() && again.failure.is_none(),
        "the Welcome read twice is held once",
    );
    assert!(
        bob.circle
            .get_pending_invitations()
            .await
            .expect("the pending invitations")
            .len()
            == 1,
        "the one invitation is held once",
    );

    join(alice, &bob, &invitation, &group).await;
    // The page fetch's read before its answer, and the live session's REQ.
    await_refused_reads(&world.gated.front, &bob.hex(), 2).await;
    assert_only_own_inbox_reads_authenticated(world);
    group
}

/// (b) An inbox every relay of which gates gift-wrap reads: the page fetch
/// answers each relay's challenge, every read is served, and the Welcome they
/// hold opens. The inviter counted it sent: a gating relay acknowledges the
/// write (strfry does).
async fn every_inbox_relay_gates_reads(world: &World, alice: &Account) {
    let gated = world.gated.front.url();
    let gated_too = world.gated_too.front.url();
    let plain = world.plain.front.url();
    let bob = invitee(world, "split_plane_b", &[gated, gated_too], &[plain, gated]).await;
    let member = look_up(world, alice, &bob, None).await;
    let created = create(world, alice, vec![member], "Gated only").await;
    assert!(
        created.welcomes_sent == 1 && created.welcomes_total == 1,
        "a gating relay acknowledges the Welcome it will not serve",
    );
    for front in [&world.gated.front, &world.gated_too.front] {
        assert!(
            published_wraps(front, &bob.hex()).len() == 1,
            "premise: each gating inbox relay took the Welcome",
        );
    }

    let wrap = read_inbox_through_its_gate(world, &bob).await;
    take_in(alice, &bob, &wrap).await;
    for front in [&world.gated.front, &world.gated_too.front] {
        await_refused_reads(front, &bob.hex(), 1).await;
        assert!(
            answers_from(front, &bob.hex()) >= 1,
            "premise: each gated relay was read after the invitee's answer",
        );
    }
    assert_only_own_inbox_reads_authenticated(world);
}

/// (b') An inbox whose one relay refuses gift-wrap reads even once the reader
/// authenticated: the page fetch answers its challenge, asks again, and reads
/// it `Refused` with nothing served; no invitation is held. The inviter still
/// counts the Welcome sent — the relay acknowledged the write.
async fn an_inbox_relay_refusing_after_authentication_serves_nothing(
    world: &World,
    alice: &Account,
) {
    let refusing = world.refusing.front.url();
    let plain = world.plain.front.url();
    let bob = invitee(world, "split_plane_b2", &[refusing], &[plain, refusing]).await;
    let member = look_up(world, alice, &bob, None).await;
    let created = create(world, alice, vec![member], "Refused after auth").await;
    assert!(
        created.welcomes_sent == 1 && created.welcomes_total == 1,
        "the refusing relay acknowledges the Welcome it will not serve",
    );
    assert!(
        published_wraps(&world.refusing.front, &bob.hex()).len() == 1,
        "premise: the refusing inbox relay took the Welcome",
    );

    let [read] = <[_; 1]>::try_from(read_inbox(world, &bob).await)
        .unwrap_or_else(|_| panic!("one answer per inbox relay"));
    assert!(
        read.read == InboxReadFfi::Refused && read.events.is_empty(),
        "a relay refusing an authenticated read is typed refused, and served nothing",
    );
    assert!(
        bob.circle
            .get_pending_invitations()
            .await
            .expect("the pending invitations")
            .is_empty(),
        "no invitation came of an inbox nothing can be read from",
    );
    // The read before the answer, and the one after it.
    await_refused_reads(&world.refusing.front, &bob.hex(), 2).await;
    assert!(
        answers_from(&world.refusing.front, &bob.hex()) == 1,
        "the refusal came after the invitee answered the relay's challenge",
    );
    assert_only_own_inbox_reads_authenticated(world);
}

/// (c) An invitee that has never had a circle starts its session with none,
/// the inbox REQ still goes out, and an invite made after the start surfaces
/// on the bus, read past the gated first relay.
async fn a_fresh_invitee_hears_a_welcome_live(world: &World, alice: &Account, group: Vec<u8>) {
    let gated = world.gated.front.url();
    let plain = world.plain.front.url();
    let bob = invitee(world, "split_plane_c", &[gated, plain], &[plain, gated]).await;
    let (live, mut events) = start_live(&bob).await;
    let pubkey = bob.hex();
    within(
        "the inbox REQ",
        world
            .plain
            .front
            .wait_for(|frames| frames.iter().any(|f| inbox_req(f, &pubkey).is_some())),
    )
    .await;
    await_refused_reads(&world.gated.front, &pubkey, 1).await;

    let member = look_up(world, alice, &bob, Some(group.clone())).await;
    let added = within(
        "the invite",
        world
            .relays
            .add_members_driven(&alice.circle, group.clone(), vec![member], true),
    )
    .await
    .expect("the invite runs");
    assert!(
        added.status == PublishStatusFfi::Confirmed
            && added.welcomes_delivered == 1
            && added.welcomes_total == 1,
        "the invite was applied and its Welcome acknowledged",
    );

    let wrap = next_welcome(&mut events).await;
    stop_live(&live).await;
    assert!(
        published_wraps(&world.gated.front, &pubkey) == [wrap_id(&wrap)],
        "premise: the gated relay was sent the Welcome, and took it",
    );
    let invitation = take_in(alice, &bob, &wrap).await;
    join(alice, &bob, &invitation, &group).await;
    assert_only_own_inbox_reads_authenticated(world);
}

/// (d) An inviter that fetched a `KeyPackage` just before the invitee's
/// replacement landed: its Welcome opens while the superseded package's grace
/// runs — on a tick at the grace's last second — and once a tick at its end
/// has passed, the invitation is the typed `NeedsNewInvite`.
async fn a_superseded_key_package_opens_only_within_its_grace(
    world: &World,
    alice: &Account,
    clock: &MaintenanceClock,
) {
    let gated = world.gated.front.url();
    let plain = world.plain.front.url();
    let within_grace = invitee(world, "split_plane_d1", &[gated, plain], &[plain, gated]).await;
    let past_grace = invitee(world, "split_plane_d2", &[gated, plain], &[plain, gated]).await;
    let stale_within = look_up(world, alice, &within_grace, None).await;
    let stale_past = look_up(world, alice, &past_grace, None).await;

    // Each package's replacement is acknowledged on a tick at the later of
    // their rotation instants, so both graces start there.
    let mut replaced_at = 0;
    let mut superseded = Vec::new();
    for bob in [&within_grace, &past_grace] {
        let tracked = bob
            .circle
            .inner
            .session()
            .tracked_key_package()
            .await
            .expect("the lifecycle record")
            .expect("a tracked package");
        let TrackedKpLifetime::Known(lifetime) = read_kp_lifetime(&tracked.package) else {
            panic!("the tracked package has a readable lifetime");
        };
        replaced_at = replaced_at.max(lifetime.rotate_at());
        superseded.push(tracked.package);
    }
    clock.set(replaced_at);
    for (bob, old) in [&within_grace, &past_grace].into_iter().zip(&superseded) {
        let rotated = within(
            "the rotation tick",
            world.relays.maintain_key_package(&bob.circle, bob.secret()),
        )
        .await
        .expect("the tick runs");
        assert!(
            rotated.action == KpMaintenanceActionFfi::RotatedExpiringMaterial
                && rotated.relays_healed >= 1,
            "premise: a relay acknowledged the replacement",
        );
        let current = bob
            .circle
            .inner
            .session()
            .tracked_key_package()
            .await
            .expect("the lifecycle record")
            .expect("a tracked package");
        assert!(
            current.package != *old,
            "premise: the fetched package is superseded",
        );
    }
    let opens = create(world, alice, vec![stale_within], "Within grace").await;
    let lapsed = create(world, alice, vec![stale_past], "Past grace").await;
    assert!(
        opens.welcomes_sent == 1 && lapsed.welcomes_sent == 1,
        "an inbox relay acknowledged each Welcome",
    );

    clock.set(replaced_at + KEY_PACKAGE_REPLACEMENT_GRACE_SECS - 1);
    within(
        "the tick at the grace's last second",
        world
            .relays
            .maintain_key_package(&within_grace.circle, within_grace.secret()),
    )
    .await
    .expect("the tick runs");
    let wrap = read_inbox_through_its_gate(world, &within_grace).await;
    let invitation = take_in(alice, &within_grace, &wrap).await;
    join(
        alice,
        &within_grace,
        &invitation,
        &opens.circle.expect("the circle").mls_group_id,
    )
    .await;

    clock.set(replaced_at + KEY_PACKAGE_REPLACEMENT_GRACE_SECS);
    within(
        "the tick at the grace's end",
        world
            .relays
            .maintain_key_package(&past_grace.circle, past_grace.secret()),
    )
    .await
    .expect("the tick runs");
    let wrap = read_inbox_through_its_gate(world, &past_grace).await;
    let invitation = take_in(alice, &past_grace, &wrap).await;
    let accepted = past_grace
        .circle
        .accept_invitation(invitation.mls_group_id.clone())
        .await
        .expect("the accept runs");
    assert!(
        accepted.joined.is_none() && accepted.failure == Some(AcceptFailureFfi::NeedsNewInvite),
        "a Welcome to a package past its grace is the typed NeedsNewInvite",
    );
    assert!(
        past_grace
            .circle
            .get_pending_invitations()
            .await
            .expect("the pending invitations")
            .is_empty(),
        "the dead invitation was resolved like a decline",
    );
    clock.set(0);
    for bob in [&within_grace, &past_grace] {
        await_refused_reads(&world.gated.front, &bob.hex(), 1).await;
        assert!(
            published_wraps(&world.gated.front, &bob.hex()).len() == 1,
            "premise: the gated relay was sent the Welcome, and took it",
        );
    }
    assert_only_own_inbox_reads_authenticated(world);
}

/// (e) A Welcome stored before the invitee's session starts — sent while the
/// app was not running — reaches the session's first consumer even when that
/// consumer attaches only after the session took the Welcome in; one the bus
/// carried but nobody took in reaches it again after a stop and a start,
/// because the inbox cursor, though it moved, did not pass it.
async fn a_welcome_stored_before_the_session_reaches_it(world: &World, alice: &Account) {
    let gated = world.gated.front.url();
    let plain = world.plain.front.url();
    let bob = invitee(world, "split_plane_e", &[gated, plain], &[plain, gated]).await;
    let pubkey = bob.hex();
    let member = look_up(world, alice, &bob, None).await;
    let created = create(world, alice, vec![member], "Stored first").await;
    assert!(
        created.welcomes_sent == 1,
        "an inbox relay acknowledged the Welcome",
    );
    let stored = published_wraps(&world.plain.front, &pubkey);
    assert!(stored.len() == 1, "premise: the Welcome was stored first");
    let inbox_cursor = || {
        bob.circle
            .inner
            .read_sync_cursor(haven_core::relay::cursor::STREAM_INBOX_1059)
            .expect("the inbox cursor")
    };
    assert!(
        inbox_cursor().is_none(),
        "premise: a fresh inbox has no cursor",
    );

    let (live, mut events) = start_burst_and_settle(&bob).await;
    let heard = next_welcome(&mut events).await;
    assert!(
        [wrap_id(&heard)] == *stored,
        "the stored Welcome reached the session's first consumer",
    );
    stop_live(&live).await;
    drop(events);
    assert!(
        inbox_cursor().is_some(),
        "premise: the served inbox relay's EOSE moved the inbox cursor",
    );

    let opened_before = world.plain.front.connections();
    let (live, mut events) = start_live(&bob).await;
    let heard_again = next_welcome(&mut events).await;
    stop_live(&live).await;
    assert!(
        wrap_id(&heard_again) == wrap_id(&heard),
        "the Welcome nobody took in reached the restarted session",
    );
    let created_at = serde_json::from_str::<nostr::Event>(&heard)
        .expect("a gift wrap is an event")
        .created_at
        .as_secs();
    let floors: Vec<Option<u64>> = world
        .plain
        .front
        .frames()
        .iter()
        .filter(|frame| frame.conn >= opened_before)
        .filter_map(|frame| inbox_req(frame, &pubkey))
        .collect();
    assert!(
        !floors.is_empty()
            && floors
                .iter()
                .all(|since| since.is_none_or(|since| since <= created_at)),
        "the restarted inbox REQ asks from at or before the wrap it did not take in",
    );

    let invitation = take_in(alice, &bob, &heard_again).await;
    join(
        alice,
        &bob,
        &invitation,
        &created.circle.expect("the circle").mls_group_id,
    )
    .await;
    assert!(
        published_wraps(&world.gated.front, &pubkey) == stored,
        "premise: the gated relay was sent the Welcome, and took it",
    );
    // Each session's inbox REQ.
    await_refused_reads(&world.gated.front, &pubkey, 2).await;
    assert_only_own_inbox_reads_authenticated(world);
}
