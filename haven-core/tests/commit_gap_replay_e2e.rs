//! The publish-before-apply window must not eat what the engine replays out of
//! it.
//!
//! While a commit is staged, `cgka-engine` BUFFERS everything that arrives for
//! that group. The fanout driver's resolution of the commit — its confirm on a
//! relay's acknowledgement, or its rollback when every relay proved it refused
//! the commit — ends in `replay_buffered_messages`, which re-ingests the lot. Three things
//! come back through that door, and all three used to be dropped on the floor:
//!
//! * **peer locations.** The engine delivers `GroupEvent::MessageReceived` AT
//!   MOST ONCE and writes the content row `Processed` in the same breath, with
//!   no application-acknowledgement boundary. A resolution that folds the batch
//!   without persisting loses that fix for good — no redelivery, no retry, no
//!   later sweep recovers it.
//! * **`pending_convergence`.** A replayed peer `SelfRemove` proposal produces
//!   an EMPTY `publish` and a pending group; the eviction auto-commit only
//!   materialises on the following `advance_convergence`. Dropping the pending
//!   group is how a leave gets stuck with nobody committing it.
//! * **the local user's own re-proposed leave.** A peer commit landing while a
//!   leave request stands re-mints the `SelfRemove` for the accepted epoch.
//!   Dropping it leaves this device behind the engine's leave send gate with no
//!   proposal in flight.
//!
//! # Which rung replays WHAT, at MDK `fcc85edd`
//!
//! The two rungs are not symmetric, and the asymmetry decides which scenario
//! each test can use:
//!
//! * The confirm merges first, so the replay runs at epoch N+1. An
//!   application message from epoch N still decrypts (the engine retains past
//!   epochs), so a buffered peer LOCATION comes back. A buffered `SelfRemove`
//!   PROPOSAL does not: a proposal is valid only in its source epoch.
//! * The rollback discards the staged commit and replays at the ORIGINAL
//!   epoch, so a buffered proposal is still applicable — which makes it the rung
//!   where a replayed peer leave reaches its auto-commit.
//!
//! The gap itself is staged the way the soak rig's `commit-gap` arm stages it:
//! an admin relay-list commit recorded and left unresolved, then driven once
//! over a scripted transport.

use haven_core::circle::{CircleConfig, CircleManager, LastKnownLocation, MemberKeyPackage};
use haven_core::location::LocationMessage;
use haven_core::nostr::mls::storage::set_stored_message_write_fault_for_test;
use haven_core::nostr::mls::types::{GroupId, LocationMessageResult};
use haven_core::nostr::mls::StorageConfig;
use haven_core::relay::fanout::scripted::{Answer, ScriptedFanout};
use haven_core::relay::fanout::{DriveMode, ResumeOutcome};
use haven_core::relay::maintenance::build_kp_maintenance_events;
use haven_core::relay::retick::MAX_CONVERGENCE_RETICKS;
use nostr::{Event, JsonUtil, Keys};
use tempfile::TempDir;

mod helpers;
use helpers::drive::{through, ManualClock, Recorder};
use helpers::{assert_no_needles, assert_some_line_from, capture_haven_log, haven_core_lines};

const GROUP_RELAY: &str = "wss://group.example.com";
const SECOND_RELAY: &str = "wss://group-two.example.com";
const THIRD_RELAY: &str = "wss://group-three.example.com";

// ============================================================================
// Fixture
// ============================================================================

/// A co-member with their own real `SQLCipher` MLS store.
struct Peer {
    manager: CircleManager,
    keys: Keys,
}

impl Peer {
    fn hex(&self) -> String {
        self.keys.public_key().to_hex()
    }
}

struct Fixture {
    alice: CircleManager,
    alice_keys: Keys,
    alice_dir: TempDir,
    peers: Vec<Peer>,
    mls_group_id: GroupId,
    nostr_group_id: [u8; 32],
    _dirs: Vec<TempDir>,
}

impl Fixture {
    fn bob(&self) -> &Peer {
        &self.peers[0]
    }

    fn carol(&self) -> &Peer {
        &self.peers[1]
    }

    /// Alice's MLS database, for the stored-message write-fault injector.
    fn alice_db(&self) -> std::path::PathBuf {
        StorageConfig::new(self.alice_dir.path()).database_path()
    }

    fn rows(&self) -> Vec<LastKnownLocation> {
        self.alice
            .snapshot_last_known_for_circle(&self.nostr_group_id, now_secs())
            .expect("last-known snapshot")
    }

    /// Stages an admin relay-list commit under its fanout record and leaves
    /// it unresolved: the publish-before-apply window everything below
    /// arrives into.
    async fn stage_gap(&self, relays: &[&str]) -> Gap {
        let relays: Vec<String> = relays.iter().map(|r| (*r).to_string()).collect();
        let staged = self
            .alice
            .session()
            .update_relays_staging(&self.mls_group_id, relays, ManualClock::ORIGIN)
            .await
            .expect("the admin stages a relay-list commit");
        gap_of(&self.alice, &staged.fanouts).await
    }

    /// Drives the window's record once in the full mode, every relay
    /// answering `answer`: `Accepted` confirms it and `Refused` rolls it back.
    async fn resolve(&self, answer: Answer) -> ResumeOutcome {
        let transport = ScriptedFanout::default();
        for relay in [GROUP_RELAY, SECOND_RELAY, THIRD_RELAY] {
            transport.answer(relay, [answer]);
        }
        let outbox = Recorder::acking(true);
        let clock = ManualClock::at(0);
        through(&transport, &outbox, &clock, &DriveMode::Full)
            .resume(&self.alice)
            .await
    }
}

impl Fixture {
    /// The window's commit refused by every relay it was sent to, and
    /// everything after it acknowledged — the eviction its rollback replays
    /// into existence among it — driven until the drive asks for nothing
    /// more. The circle has heard its relays out, as an eviction left due is
    /// staged only then. The driver's clock is moved to each time the drive
    /// names (the wait a refusal earns runs on it), and the engine's own
    /// deadline, which runs on a real clock nothing can set, is waited out.
    /// Every call the transport was asked to make.
    async fn roll_back_then_accept(&self) -> Vec<haven_core::relay::fanout::scripted::Call> {
        let transport = ScriptedFanout::default();
        for relay in [GROUP_RELAY, SECOND_RELAY, THIRD_RELAY] {
            transport.answer(relay, [Answer::Refused, Answer::Accepted]);
        }
        let outbox = Recorder::acking(true);
        let clock = ManualClock::at(0);
        let driver = through(&transport, &outbox, &clock, &DriveMode::Full);
        self.alice
            .session()
            .mark_caught_up_for_test(&self.mls_group_id);
        let mut calls = Vec::new();
        let mut at = 0;
        for _ in 0..12 {
            let resumed = driver.resume(&self.alice).await;
            calls.extend(transport.calls());
            let Some(after) = resumed.retry_after_ms else {
                return calls;
            };
            at += after;
            clock.set(at);
            let session = self.alice.session();
            let engine = match session
                .eviction_due_after_for_test(&self.mls_group_id)
                .await
            {
                Some(wait) => Some(wait),
                None => session.receive_retick_after(&self.mls_group_id).await,
            };
            tokio::time::sleep(engine.unwrap_or_default() + std::time::Duration::from_millis(5))
                .await;
        }
        panic!("the drive never stopped asking to be run again");
    }
}

/// A commit staged under its fanout record: the event its relays are sent.
struct Gap {
    commit: Event,
}

/// The one record in `fanouts`, as the event its relays are sent.
async fn gap_of(alice: &CircleManager, fanouts: &[haven_core::nostr::mls::types::FanoutId]) -> Gap {
    let [id] = fanouts else {
        panic!("one record, got {}", fanouts.len());
    };
    let probe = alice
        .session()
        .fanout_probe_for_test(id)
        .await
        .expect("the record is read")
        .expect("the record is stored");
    Gap {
        commit: Event::from_json(&probe.payload).expect("a signed event"),
    }
}

fn now_secs() -> i64 {
    chrono::Utc::now().timestamp()
}

async fn mint_member() -> (CircleManager, Keys, MemberKeyPackage, TempDir) {
    let dir = TempDir::new().unwrap();
    let keys = Keys::generate();
    let manager = CircleManager::new_unencrypted(dir.path(), &keys).unwrap();
    let key_package_event = build_kp_maintenance_events(
        manager.session(),
        &keys,
        &["wss://kp.example.com".to_string()],
        None,
        None,
    )
    .await
    .expect("key package")
    .event;
    let member = MemberKeyPackage {
        key_package_event,
        inbox_relays: vec!["wss://member-inbox.example.com".to_string()],
        nip65_relays: vec![],
        nip65_write_relays: vec![],
    };
    (manager, keys, member, dir)
}

/// A circle of `peer_count + 1` members built through the PUBLIC API (create →
/// confirm → welcome → accept), so every MLS row under test is one production
/// actually wrote.
async fn build_circle(name: &str, peer_count: usize) -> Fixture {
    let relays = vec![GROUP_RELAY.to_string()];
    let mut peers = Vec::new();
    let mut key_packages = Vec::new();
    let mut dirs = Vec::new();
    for _ in 0..peer_count {
        let (manager, keys, member, dir) = mint_member().await;
        peers.push(Peer { manager, keys });
        key_packages.push(member);
        dirs.push(dir);
    }

    let alice_dir = TempDir::new().unwrap();
    let alice_keys = Keys::generate();
    let alice = CircleManager::new_unencrypted(alice_dir.path(), &alice_keys).unwrap();
    let config = CircleConfig::new(name).with_relays(relays.clone());
    let result = alice
        .create_circle(&alice_keys, key_packages, &config)
        .await
        .expect("create circle");
    let mls_group_id = result.circle.mls_group_id.clone();
    let nostr_group_id = result.circle.nostr_group_id;

    for peer in &peers {
        let welcome = result
            .welcome_events
            .iter()
            .find(|w| w.recipient_pubkey == peer.hex())
            .expect("a welcome for each member");
        peer.manager
            .process_gift_wrapped_invitation(&peer.keys, &welcome.event)
            .await
            .expect("peer holds the welcome");
        peer.manager
            .accept_invitation(&welcome.event.id)
            .await
            .expect("peer accepts");
    }

    Fixture {
        alice,
        alice_keys,
        alice_dir,
        peers,
        mls_group_id,
        nostr_group_id,
        _dirs: dirs,
    }
}

/// A second circle inside Alice's OWN store, with its own peer.
///
/// The engine's effect buffers are GLOBAL, so a batch really can span circles —
/// which is why everything below keys off each event's own `group_id`.
struct Sibling {
    peer: Peer,
    mls_group_id: GroupId,
    nostr_group_id: [u8; 32],
    _dir: TempDir,
}

async fn add_sibling_circle(fixture: &Fixture, name: &str) -> Sibling {
    let relays = vec![GROUP_RELAY.to_string()];
    let (manager, keys, member, dir) = mint_member().await;
    let config = CircleConfig::new(name).with_relays(relays.clone());
    let result = fixture
        .alice
        .create_circle(&fixture.alice_keys, vec![member], &config)
        .await
        .expect("create the sibling circle");
    let welcome = &result.welcome_events[0];
    manager
        .process_gift_wrapped_invitation(&keys, &welcome.event)
        .await
        .expect("sibling peer holds the welcome");
    manager
        .accept_invitation(&welcome.event.id)
        .await
        .expect("sibling peer accepts");
    Sibling {
        peer: Peer { manager, keys },
        mls_group_id: result.circle.mls_group_id.clone(),
        nostr_group_id: result.circle.nostr_group_id,
        _dir: dir,
    }
}

/// Arms or disarms the stored-message write fault on Alice's MLS database: any
/// call that updates a stored message row fails with `Err`.
fn write_fault(fixture: &Fixture, armed: bool) {
    let key = StorageConfig::test_sqlcipher_key().expect("test key");
    set_stored_message_write_fault_for_test(&fixture.alice_db(), &key, armed)
        .expect("set the stored-message write fault");
}

/// A location message with an explicit age, so freshness and expiry are pinned
/// to values rather than to when the test happens to run.
fn aged_location(lat: f64, lon: f64, age_secs: i64, ttl_secs: i64) -> LocationMessage {
    let mut msg = LocationMessage::new(lat, lon);
    msg.timestamp = chrono::Utc::now() - chrono::Duration::seconds(age_secs);
    msg.expires_at = msg.timestamp + chrono::Duration::seconds(ttl_secs);
    msg
}

/// `sender` encrypts one location into `group`, ready to be handed to Alice.
async fn peer_location(peer: &Peer, group: &GroupId, msg: &LocationMessage) -> Event {
    peer.manager
        .seal_location_for_test(group, msg)
        .await
        .expect("the peer must encrypt rather than queue")
        .0
}

/// Hands `event` to Alice's engine and requires the gap to have BUFFERED it —
/// the precondition without which every assertion below would be about an
/// ordinary delivery.
async fn buffered_by_alice(fixture: &Fixture, event: &Event) {
    let screened = fixture
        .alice
        .session()
        .process_event(event)
        .await
        .expect("alice's engine takes the event");
    let ingest = screened.ingested().expect("the event is MLS-authenticated");
    assert!(
        matches!(
            ingest.outcome,
            haven_core::nostr::mls::types::IngestOutcome::Buffered { .. }
        ),
        "precondition: the staged commit must really have buffered this event, \
         or the replay under test never happens"
    );
}

fn row_for(rows: &[LastKnownLocation], sender_hex: &str) -> Option<LastKnownLocation> {
    rows.iter().find(|r| r.sender_pubkey == sender_hex).cloned()
}

fn located(results: &[LocationMessageResult], sender_hex: &str) -> bool {
    results.iter().any(|r| {
        matches!(
            r,
            LocationMessageResult::Location { sender_pubkey, .. } if sender_pubkey == sender_hex
        )
    })
}

// ============================================================================
// 1-3. The location itself
// ============================================================================

#[tokio::test(flavor = "multi_thread")]
async fn peer_location_during_a_staged_commit_surfaces_on_confirm() {
    let fx = build_circle("Replay Confirm Circle", 1).await;
    fx.stage_gap(&[GROUP_RELAY, SECOND_RELAY]).await;
    let event = peer_location(
        fx.bob(),
        &fx.mls_group_id,
        &LocationMessage::new(51.5, -0.12),
    )
    .await;
    buffered_by_alice(&fx, &event).await;
    assert!(
        fx.rows().is_empty(),
        "precondition: nothing is in the store before the window resolves"
    );

    let ingest = fx.resolve(Answer::Accepted).await;

    assert!(
        located(&ingest.replayed, &fx.bob().hex()),
        "the replayed peer location must reach the caller, not be folded away"
    );
    let row = row_for(&fx.rows(), &fx.bob().hex())
        .expect("and it must be in the last-known store, because it is delivered exactly once");
    assert!((row.latitude - 51.5).abs() < 1e-9);
    assert!((row.longitude - (-0.12)).abs() < 1e-9);
}

#[tokio::test(flavor = "multi_thread")]
async fn the_same_on_a_rollback() {
    let fx = build_circle("Replay Rollback Circle", 1).await;
    fx.stage_gap(&[GROUP_RELAY, SECOND_RELAY]).await;
    let event = peer_location(
        fx.bob(),
        &fx.mls_group_id,
        &LocationMessage::new(48.85, 2.35),
    )
    .await;
    buffered_by_alice(&fx, &event).await;

    let ingest = fx.resolve(Answer::Refused).await;

    assert!(
        located(&ingest.replayed, &fx.bob().hex()),
        "a commit no relay acked still replays what arrived behind it"
    );
    assert!(
        row_for(&fx.rows(), &fx.bob().hex()).is_some(),
        "and the fix is persisted on this rung too"
    );
    assert!(
        !ingest
            .replayed
            .iter()
            .any(|r| matches!(r, LocationMessageResult::GroupUpdate { .. })),
        "a rollback prepends no epoch event: the group is back where it started, \
         and reporting an epoch change here would park the repair gate for a day"
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn the_persisted_row_exists_the_instant_confirm_returns() {
    let fx = build_circle("Replay Instant Circle", 1).await;
    fx.stage_gap(&[GROUP_RELAY, SECOND_RELAY]).await;
    let event = peer_location(
        fx.bob(),
        &fx.mls_group_id,
        &LocationMessage::new(35.68, 139.69),
    )
    .await;
    buffered_by_alice(&fx, &event).await;

    // NOTHING runs between the confirm and the read: a process killed here has
    // already lost its chance at a redelivery, so "persisted later" is not a
    // weaker promise, it is a different one.
    let _ingest = fx.resolve(Answer::Accepted).await;
    let rows = fx.rows();

    assert!(
        row_for(&rows, &fx.bob().hex()).is_some(),
        "the durable write happens inside the confirm, before it returns"
    );
}

// ============================================================================
// 4-5. The convergence the batch leaves pending
// ============================================================================

/// A peer's leave buffered behind a staged commit is replayed by the commit's
/// rollback — the rung that replays at the original epoch, where the proposal
/// is still applicable — and the eviction it brings is made by the drive's
/// own schedule, sent once and applied. Nothing is left pending: the
/// convergence the replayed batch opened was not dropped, and no commit was
/// made of it twice.
#[tokio::test(flavor = "multi_thread")]
async fn a_peer_self_remove_replayed_by_a_rollback_reaches_a_sent_eviction_once() {
    let fx = build_circle("Replay Leave Circle", 2).await;
    let staged = fx.stage_gap(&[GROUP_RELAY, SECOND_RELAY]).await;
    let proposal = fx
        .bob()
        .manager
        .propose_leave(&fx.mls_group_id)
        .await
        .expect("bob proposes leave")
        .expect("a first leave in this epoch proposes");
    buffered_by_alice(&fx, &proposal).await;

    let evictions = fx
        .roll_back_then_accept()
        .await
        .into_iter()
        .filter(|call| call.event_id != staged.commit.id)
        .count();
    assert_eq!(
        evictions, 1,
        "the eviction the replayed leave brought was not sent exactly once"
    );
    assert!(
        !fx.alice
            .get_members(&fx.mls_group_id)
            .await
            .expect("roster")
            .iter()
            .any(|m| m.pubkey == fx.bob().hex()),
        "the leaver is not out"
    );
    fx.alice
        .seal_location_for_test(&fx.mls_group_id, &LocationMessage::new(1.0, 2.0))
        .await
        .expect("and the circle can send again, which only a merged commit allows");
    let leftover = fx
        .alice
        .session()
        .advance_convergence(&fx.mls_group_id)
        .await
        .expect("advance convergence");
    assert!(
        leftover.publish.is_empty() && leftover.pending_convergence.is_empty(),
        "the resolution left a pending convergence group behind"
    );
}

// ============================================================================
// 6-7. Retention and per-event keying
// ============================================================================

#[tokio::test(flavor = "multi_thread")]
async fn an_expired_replayed_location_is_persisted_and_cannot_overwrite_a_fresher_row() {
    let fx = build_circle("Replay Expiry Circle", 1).await;

    // Already past its freshness window when it is replayed. The post-decrypt
    // path applies no expiry filter at all — Haven's NIP-40 screen is a
    // pre-ingest screen over the OUTER event — and dropping it here would throw
    // away the only fix a peer who has since gone offline will ever send.
    let stale = aged_location(59.33, 18.07, 3_600, 600);
    fx.stage_gap(&[GROUP_RELAY, SECOND_RELAY]).await;
    let event = peer_location(fx.bob(), &fx.mls_group_id, &stale).await;
    buffered_by_alice(&fx, &event).await;
    let _ = fx.resolve(Answer::Accepted).await;

    let row = row_for(&fx.rows(), &fx.bob().hex())
        .expect("an expired fix is still the last place that peer was known to be");
    assert_eq!(row.timestamp, stale.timestamp.timestamp());

    // A fresher row already in the store survives an older replayed fix: the
    // upsert ranks a fix by `min(timestamp, ceiling)`, so arriving late does
    // not make a replay fresh — and a replay is by definition late.
    let fresh = aged_location(10.0, 20.0, 0, 900);
    fx.alice
        .upsert_last_known_location(&LastKnownLocation {
            nostr_group_id: fx.nostr_group_id,
            sender_pubkey: fx.bob().hex(),
            latitude: fresh.latitude,
            longitude: fresh.longitude,
            geohash: fresh.geohash.clone(),
            display_name: None,
            timestamp: fresh.timestamp.timestamp(),
            expires_at: fresh.expires_at.timestamp(),
            purge_after: 0,
            updated_at: now_secs(),
        })
        .expect("seed a fresher row");

    let older = aged_location(59.33, 18.07, 1_800, 600);
    fx.stage_gap(&[GROUP_RELAY, THIRD_RELAY]).await;
    let event = peer_location(fx.bob(), &fx.mls_group_id, &older).await;
    buffered_by_alice(&fx, &event).await;
    let _ = fx.resolve(Answer::Accepted).await;

    let row = row_for(&fx.rows(), &fx.bob().hex()).expect("the row is still there");
    assert_eq!(
        row.timestamp,
        fresh.timestamp.timestamp(),
        "a late replay must not drag the map back to where the peer used to be"
    );
}

// One batch persisting each location under its own circle is pinned in
// `circle::manager::tests::one_batch_persists_each_location_under_its_own_circle`:
// at MDK v0.10.4 no public call returns two circles' locations in one batch, so
// the fold is driven there directly with real events from both.

// ============================================================================
// 8. The error path
// ============================================================================

#[tokio::test(flavor = "multi_thread")]
async fn a_failed_resolution_resolves_nothing_and_strands_nothing() {
    // A storage fault mid-call fails the engine call with nothing half-emitted:
    // MDK v0.10.4 writes a message's durable rows before it hands the message
    // back, so the aborted ingest delivers no location and leaves no batch in
    // the engine's buffers for a later call to drain (the stranding the fault
    // produced at v0.9.4, which `SessionManager::drain` recovers). The confirm
    // the fault fails is not retried and not rolled back.
    let fx = build_circle("Replay Fault Circle", 1).await;
    let sibling = add_sibling_circle(&fx, "Fault Sibling Circle").await;
    fx.stage_gap(&[GROUP_RELAY, SECOND_RELAY]).await;

    write_fault(&fx, true);
    let sibling_event = peer_location(
        &sibling.peer,
        &sibling.mls_group_id,
        &LocationMessage::new(41.9, 12.49),
    )
    .await;
    assert!(
        fx.alice
            .session()
            .process_event(&sibling_event)
            .await
            .is_err(),
        "precondition (seam-6 canary): the write fault really aborts the ingest"
    );
    let outcome = fx.resolve(Answer::Accepted).await;
    write_fault(&fx, false);

    assert!(
        outcome.errored,
        "precondition: the fault must really have failed the confirm"
    );
    assert!(
        fx.alice.session().drain().await.events.is_empty(),
        "nothing the aborted calls began is left for a later call to hand back"
    );
    let rows = fx
        .alice
        .snapshot_last_known_for_circle(&sibling.nostr_group_id, now_secs())
        .expect("sibling snapshot");
    assert!(
        row_for(&rows, &sibling.peer.hex()).is_none(),
        "and no half-ingested fix was written"
    );

    // A confirm may have merged before it failed, so the stored record decides:
    // no retry in the same call, and above all no rollback, which would discard
    // a commit the group may already have. The staged commit is still staged, which is
    // exactly what a rollback would have undone.
    assert!(
        fx.alice
            .seal_location_for_test(&fx.mls_group_id, &LocationMessage::new(1.0, 2.0))
            .await
            .is_err(),
        "the failed confirm resolved nothing: the commit is still staged"
    );
}

// ============================================================================
// 9. The re-proposed leave — NOT TESTED, and why
// ============================================================================
//
// `DecryptedIngest::proposals` carries the local user's own re-proposed leave: a
// `SelfRemove` proposal is valid only in its source epoch, so a peer commit
// landing while a leave request stands re-mints it, and dropping that wedges the
// leave behind the engine's send gate.
//
// At MDK `fcc85edd`, that re-proposal cannot reach a publish-resolution
// batch, because a device cannot hold a durable leave request AND a staged
// commit at the same time:
//
// * `stage_due_self_remove_auto_commit` (`ingest.rs:1995-1998`) returns `false`
//   and DROPS its schedules the moment a leave request exists, so a leaver never
//   stages a peer eviction — the only staged commit a non-admin can have;
// * `do_send` refuses a `Leave` while the group is not `Stable`, so a device
//   with a staged commit cannot acquire a leave request either.
//
// The remaining route was measured directly (a plain member with a standing
// leave request applies a peer commit, then the batch is read both plainly and
// out of the engine's stranded buffer): `publish` came back EMPTY both times.
//
// The field and its fold arm are KEPT, and not as dead code. Two reasons:
//
// * the fold's `Proposal` arm IS exercised — from the SEND path, where the
//   user's own leave comes back through this very arm
//   (`circle::manager::tests::a_drained_proposal_is_handed_back_never_dropped`);
// * the funnel is not atomic. It takes and releases the session mutex once per
//   call, so a `Leave` another task proposes between a resolution and the
//   funnel's next `advance_convergence` lands in a global buffer this fold is
//   the one drain of — a narrow window, but a real one, and a silently dropped
//   user leave is a far worse failure than an occasionally-empty field
//   (Rule 12).
//
// What is untested is only the RESOLUTION-batch origin. Do not delete the field
// as unreachable, and do not read the absence of a test here as coverage.

// ============================================================================
// 14. The departed member
// ============================================================================

#[tokio::test(flavor = "multi_thread")]
async fn a_replayed_location_for_a_member_removed_at_the_next_epoch_is_not_persisted() {
    // Bob's fix is sealed at epoch N and buffered behind Alice's staged commit
    // — which REMOVES him. By the time the replay runs he has no leaf, so the
    // engine cannot attribute the message and never delivers it, and Haven's
    // own roster filter stands behind that. Either way the promise is the same
    // and it is the promise that matters: a departed member gets no pin.
    let fx = build_circle("Replay Departed Circle", 2).await;
    let bob_hex = fx.bob().hex();
    let event = peer_location(
        fx.bob(),
        &fx.mls_group_id,
        &LocationMessage::new(55.75, 37.62),
    )
    .await;
    fx.alice
        .session()
        .remove_members_staging(
            &fx.mls_group_id,
            std::slice::from_ref(&bob_hex),
            ManualClock::ORIGIN,
        )
        .await
        .expect("alice stages bob's removal under its record");
    buffered_by_alice(&fx, &event).await;

    let _ = fx.resolve(Answer::Accepted).await;

    assert!(
        row_for(&fx.rows(), &bob_hex).is_none(),
        "a departed member gets no pin"
    );
    // The control: the SAME window, for a member who is still in the circle,
    // does land — so the absence above is the filter and not a dead path.
    let carol_hex = fx.carol().hex();
    fx.stage_gap(&[GROUP_RELAY, SECOND_RELAY]).await;
    let carol_event = peer_location(
        fx.carol(),
        &fx.mls_group_id,
        &LocationMessage::new(41.39, 2.17),
    )
    .await;
    buffered_by_alice(&fx, &carol_event).await;
    let _ = fx.resolve(Answer::Accepted).await;
    assert!(
        row_for(&fx.rows(), &carol_hex).is_some(),
        "precondition: a remaining member's replayed fix DOES land"
    );
}

// ============================================================================
// 16. The obligation a confirm's own replay records
// ============================================================================

/// Two leavers, one after the other. The drive that sends the FIRST eviction
/// confirms it on its relay's acknowledgement, and that confirm's own replay
/// applies the SECOND leaver's proposal, whose eviction the drive's schedule
/// then makes under a record of its own. A relay that does not answer it
/// leaves that record standing — staged, recorded, and the circle's sends
/// waiting behind it — never erased by the pass that made it.
#[tokio::test(flavor = "multi_thread")]
#[allow(clippy::too_many_lines)]
async fn a_drives_confirm_that_brings_the_next_eviction_leaves_it_recorded() {
    let fx = build_circle("Drive Cascade Circle", 2).await;
    let bob = fx.bob();
    let carol = fx.carol();
    let bob_leave = bob
        .manager
        .propose_leave(&fx.mls_group_id)
        .await
        .expect("bob proposes leave")
        .expect("a first leave in this epoch proposes");
    carol
        .manager
        .session()
        .process_event(&bob_leave)
        .await
        .expect("carol ingests bob's proposal");
    // Alice's poll records the first eviction, and sends nothing: the leave
    // taken in, its circle caught up, the driving advance served at each
    // deadline the engine announces.
    let _ = fx.alice.ingest_staging_for_test(&bob_leave).await;
    fx.alice.session().mark_caught_up_for_test(&fx.mls_group_id);
    let mut gen1 = None;
    for _ in 0..12 {
        let _ = fx
            .alice
            .session()
            .advance_for_drive(&fx.mls_group_id, ManualClock::ORIGIN)
            .await;
        let ids = fx
            .alice
            .session()
            .fanout_ids_for_test(&fx.mls_group_id)
            .await
            .expect("the records are read");
        if !ids.is_empty() {
            gen1 = Some(gap_of(&fx.alice, &ids).await.commit);
            break;
        }
        let wait = fx
            .alice
            .session()
            .eviction_due_after_for_test(&fx.mls_group_id)
            .await
            .unwrap_or_default();
        tokio::time::sleep(wait + std::time::Duration::from_millis(5)).await;
    }
    let gen1 = gen1.expect("the first eviction is recorded");

    // Carol applies the first eviction, reaching the epoch the confirm is about
    // to reach, and proposes her own leave THERE — so the proposal Alice buffers
    // is applicable the moment her replay runs.
    carol
        .manager
        .session()
        .process_event_settled_for_test(&gen1)
        .await
        .expect("carol applies the first eviction");
    let carol_leave = carol
        .manager
        .propose_leave(&fx.mls_group_id)
        .await
        .expect("carol proposes leave at the new epoch")
        .expect("a first leave in this epoch proposes");
    buffered_by_alice(&fx, &carol_leave).await;

    // The first send is acknowledged; the second is not answered.
    let transport = ScriptedFanout::default();
    transport.answer(GROUP_RELAY, [Answer::Accepted, Answer::Silent]);
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let driver = through(&transport, &outbox, &clock, &DriveMode::Full);
    let mut second = Vec::new();
    for _ in 0..12 {
        let _ = driver.resume(&fx.alice).await;
        second = fx
            .alice
            .session()
            .fanout_ids_for_test(&fx.mls_group_id)
            .await
            .expect("the records are read");
        if !second.is_empty() {
            break;
        }
        let wait = fx
            .alice
            .session()
            .eviction_due_after_for_test(&fx.mls_group_id)
            .await
            .unwrap_or_default();
        tokio::time::sleep(wait + std::time::Duration::from_millis(5)).await;
    }

    let calls = transport.calls();
    assert!(
        calls.len() == 2 && calls[0].event_id == gen1.id && calls[1].event_id != gen1.id,
        "the first eviction and then the one its confirm brought were not each sent once"
    );
    assert!(
        !fx.alice
            .get_members(&fx.mls_group_id)
            .await
            .expect("roster")
            .iter()
            .any(|m| m.pubkey == bob.hex()),
        "the acknowledged eviction was not applied"
    );
    assert_eq!(
        gap_of(&fx.alice, &second).await.commit.id,
        calls[1].event_id,
        "the second eviction's record does not survive the pass that made it"
    );
    assert!(
        fx.alice
            .seal_location_for_test(&fx.mls_group_id, &LocationMessage::new(1.0, 2.0))
            .await
            .is_err(),
        "the record describes a REAL staged commit: the circle cannot send while \
         it stands"
    );
}

// ============================================================================
// 18 / 22 / 23 / 24. The fold's own rules
// ============================================================================

#[tokio::test(flavor = "multi_thread")]
async fn a_replayed_message_received_stamps_the_quiescence_gate_but_the_own_epoch_change_does_not()
{
    // The epoch-rotation repair declines while a peer might commit at the same
    // epoch. A peer message replayed out of the window is MLS-authenticated
    // evidence that a peer IS active — indistinguishable from the same message
    // arriving a moment later — so it stamps. This device's own commit being
    // applied is not, and stamping on it would let every local repair hold the
    // gate shut for itself.
    let fx = build_circle("Replay Quiescence Circle", 1).await;
    assert!(
        fx.alice
            .circle_rotation_state(&fx.nostr_group_id)
            .expect("rotation state")
            .last_inbound_event_at_ms
            .is_none(),
        "precondition: nothing inbound has been observed yet"
    );

    // A resolution carrying ONLY this device's own epoch change.
    fx.stage_gap(&[GROUP_RELAY, SECOND_RELAY]).await;
    let _ = fx.resolve(Answer::Accepted).await;
    assert!(
        fx.alice
            .circle_rotation_state(&fx.nostr_group_id)
            .expect("rotation state")
            .last_inbound_event_at_ms
            .is_none(),
        "our own applied commit is not inbound traffic"
    );
    assert!(
        fx.alice
            .circle_rotation_state(&fx.nostr_group_id)
            .expect("rotation state")
            .last_epoch_change_seen_at_ms
            .is_some(),
        "precondition: the epoch change WAS recorded, so the absence above is \
         the split and not a dead write site"
    );

    // …and the same resolution carrying a replayed peer message.
    fx.stage_gap(&[GROUP_RELAY, THIRD_RELAY]).await;
    let event = peer_location(
        fx.bob(),
        &fx.mls_group_id,
        &LocationMessage::new(52.37, 4.89),
    )
    .await;
    buffered_by_alice(&fx, &event).await;
    let _ = fx.resolve(Answer::Accepted).await;
    assert!(
        fx.alice
            .circle_rotation_state(&fx.nostr_group_id)
            .expect("rotation state")
            .last_inbound_event_at_ms
            .is_some(),
        "a replayed peer message is peer activity and holds the repair gate"
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn a_quiet_confirm_performs_zero_sleeps_and_a_leave_pays_one_budget() {
    let fx = build_circle("Replay Budget Circle", 2).await;

    let staged = fx.stage_gap(&[GROUP_RELAY, SECOND_RELAY]).await;
    let event = peer_location(
        fx.bob(),
        &fx.mls_group_id,
        &LocationMessage::new(43.7, 7.26),
    )
    .await;
    buffered_by_alice(&fx, &event).await;
    let _ = fx.resolve(Answer::Accepted).await;
    assert_eq!(
        fx.alice.convergence_reticks(),
        0,
        "a circle with nothing pending must pay no delay at all: this runs on \
         every confirm, on battery"
    );

    // Bob catches up to the epoch Alice's rollback will return to, so the leave
    // he proposes is applicable the moment her replay runs.
    fx.bob()
        .manager
        .session()
        .process_event_settled_for_test(&staged.commit)
        .await
        .expect("bob applies alice's confirmed commit");
    fx.stage_gap(&[GROUP_RELAY, THIRD_RELAY]).await;
    let proposal = fx
        .bob()
        .manager
        .propose_leave(&fx.mls_group_id)
        .await
        .expect("bob proposes leave")
        .expect("a first leave in this epoch proposes");
    buffered_by_alice(&fx, &proposal).await;
    let before = fx.alice.convergence_reticks();
    let _ = fx.resolve(Answer::Refused).await;
    assert!(
        fx.alice
            .session()
            .eviction_due_after_for_test(&fx.mls_group_id)
            .await
            .is_some()
            || !fx
                .alice
                .get_members(&fx.mls_group_id)
                .await
                .expect("roster")
                .iter()
                .any(|m| m.pubkey == fx.bob().hex()),
        "precondition: the drain really ran, so the budget below is the budget \
         of a call that had convergence to do"
    );
    assert!(
        fx.alice.convergence_reticks() - before <= MAX_CONVERGENCE_RETICKS,
        "the budget is per CALL, not per batch and not per generation: a cascade \
         must not multiply it"
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn the_sender_hex_comparison_is_lowercase_on_both_sides() {
    // The self-echo filter compares the MLS-authenticated `sender` against
    // `identity_pubkey()`. They are the same 32 bytes, and this pins that both
    // sides render them the same way — a mismatch would file this device's own
    // fix as a peer's, on every circle.
    let fx = build_circle("Replay Hex Circle", 1).await;
    let identity = fx.alice.session().identity_pubkey().to_hex();
    let self_id = hex::encode(fx.alice.session().self_id().await.as_slice());
    assert_eq!(identity, self_id);
    assert_eq!(identity, identity.to_lowercase());
    assert_eq!(identity.len(), 64);

    fx.stage_gap(&[GROUP_RELAY, SECOND_RELAY]).await;
    let event = peer_location(fx.bob(), &fx.mls_group_id, &LocationMessage::new(1.5, 2.5)).await;
    buffered_by_alice(&fx, &event).await;
    let _ = fx.resolve(Answer::Accepted).await;
    assert!(
        row_for(&fx.rows(), &identity).is_none(),
        "and no row is ever written for this device itself"
    );
}

// ============================================================================
// 25. Rule 15
// ============================================================================

#[tokio::test(flavor = "multi_thread")]
async fn publish_resolution_leaks_no_identifier() {
    let mut needles: Vec<String> = Vec::new();
    let lines = Box::pin(capture_haven_log(async {
        let fx = build_circle("Bramblewick Hollow", 2).await;
        needles.push("Bramblewick Hollow".to_string());
        needles.push(hex::encode(fx.mls_group_id.as_slice()));
        needles.push(hex::encode(fx.nostr_group_id));
        needles.push(fx.alice_keys.public_key().to_hex());
        needles.push(fx.bob().hex());
        needles.push(fx.carol().hex());
        needles.push(GROUP_RELAY.to_string());
        needles.push(SECOND_RELAY.to_string());

        // A confirm carrying a replayed peer location.
        let staged = fx.stage_gap(&[GROUP_RELAY, SECOND_RELAY]).await;
        needles.push(staged.commit.id.to_hex());
        let event = peer_location(
            fx.bob(),
            &fx.mls_group_id,
            &LocationMessage::new(64.135_666, -21.895_222),
        )
        .await;
        needles.push("64.135666".to_string());
        needles.push("21.895222".to_string());
        buffered_by_alice(&fx, &event).await;
        let _ = fx.resolve(Answer::Accepted).await;

        // …a rollback whose drained batch re-ticks convergence and surfaces an
        // eviction…
        fx.bob()
            .manager
            .session()
            .process_event_settled_for_test(&staged.commit)
            .await
            .expect("bob applies alice's confirmed commit");
        let staged = fx.stage_gap(&[GROUP_RELAY, THIRD_RELAY]).await;
        let proposal = fx
            .bob()
            .manager
            .propose_leave(&fx.mls_group_id)
            .await
            .expect("bob proposes leave")
            .expect("a first leave in this epoch proposes");
        buffered_by_alice(&fx, &proposal).await;
        needles.push(staged.commit.id.to_hex());

        // …and the SEND drain, which runs on every publish cycle. The eviction
        // the rollback replays into existence has to be resolved first or the
        // send never reaches it at all — a staged commit makes the engine
        // refuse it outright — so it is made, sent and confirmed here, which
        // also puts the driver's resolution of it under the capture.
        let calls = fx.roll_back_then_accept().await;
        assert!(
            calls.iter().any(|call| call.event_id != staged.commit.id),
            "precondition: the drained-batch path really ran and made the eviction"
        );
        for call in &calls {
            needles.push(call.event_id.to_hex());
        }
        fx.alice
            .seal_location_for_test(
                &fx.mls_group_id,
                &LocationMessage::new(64.135_666, -21.895_222),
            )
            .await
            .expect("the send is accepted, which is the rung that drains");
    }))
    .await;

    let refs: Vec<&str> = needles.iter().map(String::as_str).collect();
    assert_some_line_from(&lines, "haven_core");
    assert_no_needles(&haven_core_lines(&lines), &refs);

    // openmls renders its KDF labels — group id and all — at trace level. It is
    // the one known third-party logger on this path and the release log silencer
    // is the only lever over it, so the set is PINNED: a new third-party logger
    // here must be reviewed, never inherited.
    let roots: std::collections::BTreeSet<&str> = lines
        .iter()
        .filter_map(|l| l.target.split("::").next())
        .filter(|root| *root != "haven_core")
        .collect();
    assert_eq!(roots, std::collections::BTreeSet::from(["openmls"]));
}
