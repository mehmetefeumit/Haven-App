//! The publish-before-apply window must not eat what the engine replays out of
//! it.
//!
//! While a commit is staged, `cgka-engine` BUFFERS everything that arrives for
//! that group. Resolving the commit — `confirm_published` or `publish_failed` —
//! ends in `replay_buffered_messages`, which re-ingests the lot. Three things
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
//! # Which rung replays WHAT, measured at MDK `e391adc`
//!
//! The two rungs are not symmetric, and the asymmetry decides which scenario
//! each test can use:
//!
//! * `confirm_published` merges first, so the replay runs at epoch N+1. An
//!   application message from epoch N still decrypts (the engine retains past
//!   epochs), so a buffered peer LOCATION comes back. A buffered `SelfRemove`
//!   PROPOSAL does not: a proposal is valid only in its source epoch.
//! * `publish_failed` discards the staged commit and replays at the ORIGINAL
//!   epoch, so a buffered proposal is still applicable — which makes it the rung
//!   where a replayed peer leave reaches its auto-commit.
//!
//! The gap itself is staged the way the soak rig's `commit-gap` arm stages it:
//! an admin relay-list commit left unresolved.

use std::future::Future;
use std::pin::Pin;
use std::sync::Mutex;

use haven_core::circle::{
    CircleConfig, CircleManager, CommitToPublish, LastKnownLocation, MemberKeyPackage,
};
use haven_core::location::LocationMessage;
use haven_core::nostr::mls::storage::set_stored_message_write_fault_for_test;
use haven_core::nostr::mls::types::{GroupId, LocationMessageResult};
use haven_core::nostr::mls::StorageConfig;
use haven_core::relay::auto_commit::{AutoCommitPublisher, MAX_CONVERGENCE_RETICKS};
use haven_core::relay::maintenance::build_kp_maintenance_events;
use nostr::{Event, Keys};
use tempfile::TempDir;

mod helpers;
use helpers::{assert_no_needles, assert_some_line_from, capture_haven_log, haven_core_lines};

const GROUP_RELAY: &str = "wss://group.example.com";
const SECOND_RELAY: &str = "wss://group-two.example.com";
const THIRD_RELAY: &str = "wss://group-three.example.com";

// ============================================================================
// Fixture
// ============================================================================

/// A recording relay plane with a programmable OK-ack verdict, so the Rule-13
/// ladder is deterministic with no network.
struct FakePublisher {
    ack: Mutex<Vec<bool>>,
    published: Mutex<Vec<Event>>,
}

impl FakePublisher {
    /// `acks` is consumed one entry per publish; once exhausted every further
    /// publish answers with the last entry.
    fn new(acks: &[bool]) -> Self {
        Self {
            ack: Mutex::new(acks.to_vec()),
            published: Mutex::new(Vec::new()),
        }
    }

    fn published(&self) -> Vec<Event> {
        self.published.lock().unwrap().clone()
    }
}

impl AutoCommitPublisher for FakePublisher {
    fn publish_auto_commit<'a>(
        &'a self,
        event: &'a Event,
        _relays: &'a [String],
    ) -> Pin<Box<dyn Future<Output = bool> + Send + 'a>> {
        Box::pin(async move {
            self.published.lock().unwrap().push(event.clone());
            let mut acks = self.ack.lock().unwrap();
            if acks.len() > 1 {
                acks.remove(0)
            } else {
                *acks.first().unwrap_or(&false)
            }
        })
    }
}

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

    /// Stages an admin relay-list commit and leaves it unresolved: the
    /// publish-before-apply window everything below arrives into.
    async fn stage_gap(&self, relays: &[&str]) -> CommitToPublish {
        let relays: Vec<String> = relays.iter().map(|r| (*r).to_string()).collect();
        self.alice
            .update_circle_relays(&self.mls_group_id, &relays)
            .await
            .expect("the admin stages a relay-list commit")
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
        .create_circle(&alice_keys, key_packages, &config, &relays)
        .await
        .expect("create circle");
    let mls_group_id = result.circle.mls_group_id.clone();
    let nostr_group_id = result.circle.nostr_group_id;
    alice
        .confirm_published(result.pending)
        .await
        .expect("alice confirms creation");

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
        .create_circle(&fixture.alice_keys, vec![member], &config, &relays)
        .await
        .expect("create the sibling circle");
    fixture
        .alice
        .confirm_published(result.pending)
        .await
        .expect("confirm the sibling create");
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

/// Arms or disarms the stored-message write fault on Alice's MLS database.
///
/// The engine pushes a decrypted message to its event buffer BEFORE it writes
/// that message's terminal row state, and `cgka-session` propagates the write
/// failure before `collect_effects` runs. So a faulted call returns `Err` with
/// its work STRANDED in the engine's global buffers — the shape a `ForkedEpoch`
/// mid-replay abort produces, reachable without two sibling commits.
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
        .encrypt_location(group, &peer.keys.public_key(), msg, 300)
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
    let staged = fx.stage_gap(&[GROUP_RELAY, SECOND_RELAY]).await;
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

    let ingest = fx
        .alice
        .confirm_published(staged.pending)
        .await
        .expect("confirm");

    assert!(
        located(&ingest.results, &fx.bob().hex()),
        "the replayed peer location must reach the caller, not be folded away"
    );
    let row = row_for(&fx.rows(), &fx.bob().hex())
        .expect("and it must be in the last-known store, because it is delivered exactly once");
    assert!((row.latitude - 51.5).abs() < 1e-9);
    assert!((row.longitude - (-0.12)).abs() < 1e-9);
}

#[tokio::test(flavor = "multi_thread")]
async fn the_same_on_publish_failed() {
    let fx = build_circle("Replay Rollback Circle", 1).await;
    let staged = fx.stage_gap(&[GROUP_RELAY, SECOND_RELAY]).await;
    let event = peer_location(
        fx.bob(),
        &fx.mls_group_id,
        &LocationMessage::new(48.85, 2.35),
    )
    .await;
    buffered_by_alice(&fx, &event).await;

    let ingest = fx
        .alice
        .publish_failed(staged.pending)
        .await
        .expect("rollback");

    assert!(
        located(&ingest.results, &fx.bob().hex()),
        "a commit no relay acked still replays what arrived behind it"
    );
    assert!(
        row_for(&fx.rows(), &fx.bob().hex()).is_some(),
        "and the fix is persisted on this rung too"
    );
    assert!(
        !ingest
            .results
            .iter()
            .any(|r| matches!(r, LocationMessageResult::GroupUpdate { .. })),
        "a rollback prepends no epoch event: the group is back where it started, \
         and reporting an epoch change here would park the repair gate for a day"
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn the_persisted_row_exists_the_instant_confirm_returns() {
    let fx = build_circle("Replay Instant Circle", 1).await;
    let staged = fx.stage_gap(&[GROUP_RELAY, SECOND_RELAY]).await;
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
    let _ingest = fx
        .alice
        .confirm_published(staged.pending)
        .await
        .expect("confirm");
    let rows = fx.rows();

    assert!(
        row_for(&rows, &fx.bob().hex()).is_some(),
        "the durable write happens inside the confirm, before it returns"
    );
}

// ============================================================================
// 4-5. The convergence the batch leaves pending
// ============================================================================

#[tokio::test(flavor = "multi_thread")]
async fn a_peer_self_remove_replayed_in_a_resolution_batch_reaches_a_published_auto_commit() {
    let fx = build_circle("Replay Leave Circle", 2).await;
    let staged = fx.stage_gap(&[GROUP_RELAY, SECOND_RELAY]).await;
    let proposal = fx
        .bob()
        .manager
        .propose_leave(&fx.mls_group_id)
        .await
        .expect("bob proposes leave");
    buffered_by_alice(&fx, &proposal).await;

    // The rollback rung, because a confirm would move the epoch past the
    // proposal's source epoch and the replay would have nothing applicable.
    let ingest = fx
        .alice
        .publish_failed(staged.pending)
        .await
        .expect("rollback");

    assert_eq!(
        ingest.auto_commits.len(),
        1,
        "the eviction only ever materialises on the convergence the batch left \
         pending; dropping it is how a leave gets stuck with nobody committing it"
    );
    assert!(
        fx.alice.owed_removal_commits().contains(&fx.nostr_group_id),
        "and it is surfaced with its publish recorded as owed, so a process \
         killed mid-publish reports the wedge instead of hiding it"
    );

    let publisher = FakePublisher::new(&[true]);
    let commit = ingest.auto_commits.into_iter().next().unwrap();
    assert!(
        publisher
            .publish_auto_commit(&commit.commit_event, &[GROUP_RELAY.to_string()])
            .await,
        "precondition: the fake relay acks"
    );
    fx.alice
        .confirm_published(commit.pending)
        .await
        .expect("confirm the eviction");

    assert!(
        !fx.alice
            .get_members(&fx.mls_group_id)
            .await
            .expect("roster")
            .iter()
            .any(|m| m.pubkey == fx.bob().hex()),
        "the leaver is out"
    );
    fx.alice
        .encrypt_location(
            &fx.mls_group_id,
            &fx.alice_keys.public_key(),
            &LocationMessage::new(1.0, 2.0),
            300,
        )
        .await
        .expect("and the circle can send again, which only a merged commit allows");
}

#[tokio::test(flavor = "multi_thread")]
async fn pending_convergence_from_a_resolution_batch_is_not_dropped() {
    let fx = build_circle("Replay Convergence Circle", 2).await;
    let staged = fx.stage_gap(&[GROUP_RELAY, SECOND_RELAY]).await;
    let proposal = fx
        .bob()
        .manager
        .propose_leave(&fx.mls_group_id)
        .await
        .expect("bob proposes leave");
    buffered_by_alice(&fx, &proposal).await;

    let ingest = fx
        .alice
        .publish_failed(staged.pending)
        .await
        .expect("rollback");

    assert_eq!(
        ingest.auto_commits.len(),
        1,
        "what the drain released is handed back, not dropped — and it only ever \
         materialises on the convergence the batch left pending"
    );

    // Nothing is left for the caller to discover: the drain happened INSIDE the
    // resolution, which is the whole point — a caller that has to remember to
    // advance convergence is a caller that will forget.
    let leftover = fx
        .alice
        .session()
        .advance_convergence(&fx.mls_group_id)
        .await
        .expect("advance convergence");
    assert!(
        leftover.publish.is_empty() && leftover.pending_convergence.is_empty(),
        "the resolution must leave no pending convergence group behind"
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
    let staged = fx.stage_gap(&[GROUP_RELAY, SECOND_RELAY]).await;
    let event = peer_location(fx.bob(), &fx.mls_group_id, &stale).await;
    buffered_by_alice(&fx, &event).await;
    fx.alice
        .confirm_published(staged.pending)
        .await
        .expect("confirm");

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
    let staged = fx.stage_gap(&[GROUP_RELAY, THIRD_RELAY]).await;
    let event = peer_location(fx.bob(), &fx.mls_group_id, &older).await;
    buffered_by_alice(&fx, &event).await;
    fx.alice
        .confirm_published(staged.pending)
        .await
        .expect("confirm");

    let row = row_for(&fx.rows(), &fx.bob().hex()).expect("the row is still there");
    assert_eq!(
        row.timestamp,
        fresh.timestamp.timestamp(),
        "a late replay must not drag the map back to where the peer used to be"
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn the_batch_is_keyed_off_each_events_own_group() {
    // Keying the persist off anything but each event's own `group_id` files a
    // peer under the wrong circle — visible to members of a circle that peer is
    // not in, which is the privacy failure, not merely a wrong pin.
    let fx = build_circle("Keyed First Circle", 1).await;
    let sibling = add_sibling_circle(&fx, "Keyed Sibling Circle").await;

    let staged = fx.stage_gap(&[GROUP_RELAY, SECOND_RELAY]).await;
    let first_event = peer_location(
        fx.bob(),
        &fx.mls_group_id,
        &LocationMessage::new(51.5, -0.12),
    )
    .await;
    buffered_by_alice(&fx, &first_event).await;

    // Strand the SIBLING circle's location in the engine's global event buffer,
    // so one resolution really does drain two circles at once.
    write_fault(&fx, true);
    let sibling_event = peer_location(
        &sibling.peer,
        &sibling.mls_group_id,
        &LocationMessage::new(-33.86, 151.21),
    )
    .await;
    assert!(
        fx.alice
            .session()
            .process_event(&sibling_event)
            .await
            .is_err(),
        "precondition: the write fault must abort the sibling ingest"
    );
    write_fault(&fx, false);

    let ingest = fx
        .alice
        .confirm_published(staged.pending)
        .await
        .expect("confirm");
    assert!(
        located(&ingest.results, &fx.bob().hex()) && located(&ingest.results, &sibling.peer.hex()),
        "precondition: one batch really did carry both circles' locations"
    );

    let first_row = row_for(&fx.rows(), &fx.bob().hex()).expect("first circle's row");
    assert!((first_row.latitude - 51.5).abs() < 1e-9);
    let sibling_rows = fx
        .alice
        .snapshot_last_known_for_circle(&sibling.nostr_group_id, now_secs())
        .expect("sibling snapshot");
    let sibling_row = row_for(&sibling_rows, &sibling.peer.hex()).expect("sibling circle's row");
    assert!((sibling_row.latitude - (-33.86)).abs() < 1e-9);
    assert!(
        row_for(&fx.rows(), &sibling.peer.hex()).is_none()
            && row_for(&sibling_rows, &fx.bob().hex()).is_none(),
        "and neither peer appears under the other circle's id"
    );
}

// ============================================================================
// 8. The error path
// ============================================================================

#[tokio::test(flavor = "multi_thread")]
async fn a_failed_resolution_still_folds_what_the_engine_had_already_delivered() {
    // The engine's effect buffers are one-shot and GLOBAL, and a call that
    // fails mid-way leaves everything it already emitted in them: the caller
    // gets an `Err` and no effects while a peer location sits there with its
    // durable row written. Recovering that batch is what stops the failure
    // taking a delivered-exactly-once fix down with it.
    let fx = build_circle("Replay Fault Circle", 1).await;
    let sibling = add_sibling_circle(&fx, "Fault Sibling Circle").await;
    let staged = fx.stage_gap(&[GROUP_RELAY, SECOND_RELAY]).await;

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
        "precondition: the fault strands the sibling location in the engine"
    );
    let outcome = fx.alice.confirm_published(staged.pending).await;
    write_fault(&fx, false);

    assert!(
        outcome.is_err(),
        "precondition: the fault must really have failed the confirm"
    );
    let rows = fx
        .alice
        .snapshot_last_known_for_circle(&sibling.nostr_group_id, now_secs())
        .expect("sibling snapshot");
    assert!(
        row_for(&rows, &sibling.peer.hex()).is_some(),
        "the stranded fix is persisted by the failed resolution's own drain — \
         nothing will ever deliver it again"
    );

    // A confirm may have merged before it failed, so the original error stands:
    // no retry, and above all no `publish_failed`, which would discard a commit
    // the group may already have. The staged commit is still staged, which is
    // exactly what a rollback would have undone.
    assert!(
        fx.alice
            .encrypt_location(
                &fx.mls_group_id,
                &fx.alice_keys.public_key(),
                &LocationMessage::new(1.0, 2.0),
                300,
            )
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
// Measured at MDK `e391adc`, that re-proposal cannot reach a publish-resolution
// batch, because a device cannot hold a durable leave request AND a staged
// commit at the same time:
//
// * `stage_due_self_remove_auto_commit` (`ingest.rs:1139-1142`) returns `false`
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
// * the fold's `Proposal` arm IS exercised — from the SEND path, where a LEAVE
//   the engine queued behind an unsettleable convergence row is released by the
//   repair's own `advance_convergence` and comes back through this very arm
//   (`send_path_drain_e2e::a_deferred_send_still_hands_back_its_drained_proposals`);
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
    let removal = fx
        .alice
        .remove_members(&fx.mls_group_id, std::slice::from_ref(&bob_hex))
        .await
        .expect("alice removes bob");
    buffered_by_alice(&fx, &event).await;

    fx.alice
        .confirm_published(removal.pending)
        .await
        .expect("confirm the removal");

    assert!(
        row_for(&fx.rows(), &bob_hex).is_none(),
        "a departed member gets no pin"
    );
    // The control: the SAME window, for a member who is still in the circle,
    // does land — so the absence above is the filter and not a dead path.
    let carol_hex = fx.carol().hex();
    let staged = fx.stage_gap(&[GROUP_RELAY, SECOND_RELAY]).await;
    let carol_event = peer_location(
        fx.carol(),
        &fx.mls_group_id,
        &LocationMessage::new(41.39, 2.17),
    )
    .await;
    buffered_by_alice(&fx, &carol_event).await;
    fx.alice
        .confirm_published(staged.pending)
        .await
        .expect("confirm");
    assert!(
        row_for(&fx.rows(), &carol_hex).is_some(),
        "precondition: a remaining member's replayed fix DOES land"
    );
}

// ============================================================================
// 16. The obligation a confirm's own replay records
// ============================================================================

#[tokio::test(flavor = "multi_thread")]
async fn redeem_removal_deferrals_does_not_erase_an_obligation_its_own_confirm_recorded() {
    // Two leavers, one after the other. Redeeming the FIRST eviction confirms
    // it, and that confirm's own replay stages the SECOND. An ngid-scoped clear
    // after the confirm would delete the obligation the confirm had just
    // recorded — the map holds one entry per circle — leaving a staged,
    // unpublished, no-longer-owed and no-longer-reported eviction: this very
    // wedge, re-armed and invisible.
    let fx = build_circle("Redeem Cascade Circle", 2).await;
    let bob = fx.bob();
    let carol = fx.carol();

    let bob_leave = bob
        .manager
        .propose_leave(&fx.mls_group_id)
        .await
        .expect("bob proposes leave");
    fx.alice
        .session()
        .process_event(&bob_leave)
        .await
        .expect("alice ingests bob's proposal");
    carol
        .manager
        .session()
        .process_event(&bob_leave)
        .await
        .expect("carol ingests bob's proposal");

    let gen1 = stage_eviction_commit(&fx.alice, &fx.mls_group_id).await;
    assert!(
        fx.alice.owe_removal_publish(&gen1),
        "precondition: the first obligation is recorded"
    );

    // Carol applies the first eviction, reaching the epoch the confirm is about
    // to reach, and proposes her own leave THERE — so the proposal Alice buffers
    // is applicable the moment her replay runs.
    carol
        .manager
        .session()
        .process_event(&gen1.commit_event)
        .await
        .expect("carol applies the first eviction");
    let carol_leave = carol
        .manager
        .propose_leave(&fx.mls_group_id)
        .await
        .expect("carol proposes leave at the new epoch");
    buffered_by_alice(&fx, &carol_leave).await;

    // The first publish acks and is confirmed; the second (the one the confirm's
    // own replay stages) does not, so it must STAY owed.
    let publisher = FakePublisher::new(&[true, false]);
    let confirmed = fx.alice.redeem_removal_deferrals(&publisher, None).await;

    assert_eq!(confirmed, 1, "exactly the acked eviction was confirmed");
    assert_eq!(
        publisher.published().len(),
        2,
        "and the one its replay staged was published too, by the pass that owns \
         the publisher"
    );
    assert!(
        fx.alice.owed_removal_commits().contains(&fx.nostr_group_id),
        "the second obligation survives the pass that recorded it"
    );
    assert!(
        fx.alice.orphaned_removal_deferrals().is_empty(),
        "and it is redeemable, not a wedge: this session still holds its ref"
    );
    assert!(
        fx.alice
            .encrypt_location(
                &fx.mls_group_id,
                &fx.alice_keys.public_key(),
                &LocationMessage::new(1.0, 2.0),
                300,
            )
            .await
            .is_err(),
        "the obligation describes a REAL staged commit: the circle cannot send \
         while it stands"
    );
}

/// Drains convergence until the jitter-delayed `SelfRemove` auto-commit is
/// staged, returning it as the [`CommitToPublish`] a plane would publish.
///
/// The engine re-queues the group until a real wall-clock due time passes, so a
/// single advance would strand the eviction.
async fn stage_eviction_commit(manager: &CircleManager, group: &GroupId) -> CommitToPublish {
    for _ in 0..40 {
        let effects = manager
            .session()
            .advance_convergence(group)
            .await
            .expect("advance convergence");
        if let Some((msg, pending)) = effects.publish.iter().find_map(|w| match w {
            haven_core::nostr::mls::types::PublishWork::AutoPublish { msg, pending } => {
                Some((msg.clone(), *pending))
            }
            _ => None,
        }) {
            let commit_event =
                haven_core::nostr::mls::SessionManager::transport_message_to_event(&msg)
                    .expect("commit event");
            return CommitToPublish {
                commit_event,
                pending,
            };
        }
        tokio::time::sleep(std::time::Duration::from_millis(25)).await;
    }
    panic!("the SelfRemove auto-commit never surfaced within the jitter window");
}

// ============================================================================
// 18 / 22 / 23 / 24. The fold's own rules
// ============================================================================

#[tokio::test(flavor = "multi_thread")]
async fn no_pending_ref_is_surfaced_twice_by_one_fold() {
    let fx = build_circle("Replay Once Circle", 2).await;
    let staged = fx.stage_gap(&[GROUP_RELAY, SECOND_RELAY]).await;
    let proposal = fx
        .bob()
        .manager
        .propose_leave(&fx.mls_group_id)
        .await
        .expect("bob proposes leave");
    buffered_by_alice(&fx, &proposal).await;

    // A fold that spans generations: the seed batch, the advance that releases
    // the eviction, and the re-ticks in between.
    let ingest = fx
        .alice
        .publish_failed(staged.pending)
        .await
        .expect("rollback");

    let mut refs: Vec<_> = ingest.auto_commits.iter().map(|c| c.pending).collect();
    let surfaced = refs.len();
    refs.sort_by_key(|r| format!("{r:?}"));
    refs.dedup();
    assert_eq!(
        refs.len(),
        surfaced,
        "a ref surfaced twice would be published twice and confirmed twice — the \
         second confirm applying a commit the first already merged"
    );
    assert_eq!(
        surfaced, 1,
        "precondition: the fold really did surface work"
    );
}

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
    let staged = fx.stage_gap(&[GROUP_RELAY, SECOND_RELAY]).await;
    fx.alice
        .confirm_published(staged.pending)
        .await
        .expect("confirm");
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
    let staged = fx.stage_gap(&[GROUP_RELAY, THIRD_RELAY]).await;
    let event = peer_location(
        fx.bob(),
        &fx.mls_group_id,
        &LocationMessage::new(52.37, 4.89),
    )
    .await;
    buffered_by_alice(&fx, &event).await;
    fx.alice
        .confirm_published(staged.pending)
        .await
        .expect("confirm");
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
    fx.alice
        .confirm_published(staged.pending)
        .await
        .expect("confirm");
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
        .process_event(&staged.commit_event)
        .await
        .expect("bob applies alice's confirmed commit");
    let staged = fx.stage_gap(&[GROUP_RELAY, THIRD_RELAY]).await;
    let proposal = fx
        .bob()
        .manager
        .propose_leave(&fx.mls_group_id)
        .await
        .expect("bob proposes leave");
    buffered_by_alice(&fx, &proposal).await;
    let ingest = fx
        .alice
        .publish_failed(staged.pending)
        .await
        .expect("rollback");
    assert_eq!(
        ingest.auto_commits.len(),
        1,
        "precondition: the drain really ran, so the budget below is the budget \
         of a call that had convergence to do"
    );
    assert!(
        fx.alice.convergence_reticks() <= MAX_CONVERGENCE_RETICKS,
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

    let staged = fx.stage_gap(&[GROUP_RELAY, SECOND_RELAY]).await;
    let event = peer_location(fx.bob(), &fx.mls_group_id, &LocationMessage::new(1.5, 2.5)).await;
    buffered_by_alice(&fx, &event).await;
    fx.alice
        .confirm_published(staged.pending)
        .await
        .expect("confirm");
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
    let lines = capture_haven_log(async {
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
        needles.push(staged.commit_event.id.to_hex());
        let event = peer_location(
            fx.bob(),
            &fx.mls_group_id,
            &LocationMessage::new(64.135_666, -21.895_222),
        )
        .await;
        needles.push("64.135666".to_string());
        needles.push("21.895222".to_string());
        buffered_by_alice(&fx, &event).await;
        fx.alice
            .confirm_published(staged.pending)
            .await
            .expect("confirm");

        // …a rollback whose drained batch re-ticks convergence and surfaces an
        // eviction…
        fx.bob()
            .manager
            .session()
            .process_event(&staged.commit_event)
            .await
            .expect("bob applies alice's confirmed commit");
        let staged = fx.stage_gap(&[GROUP_RELAY, THIRD_RELAY]).await;
        let proposal = fx
            .bob()
            .manager
            .propose_leave(&fx.mls_group_id)
            .await
            .expect("bob proposes leave");
        buffered_by_alice(&fx, &proposal).await;
        let ingest = fx
            .alice
            .publish_failed(staged.pending)
            .await
            .expect("rollback");
        assert_eq!(
            ingest.auto_commits.len(),
            1,
            "precondition: the drained-batch path really ran"
        );

        // …and the two owed-removal reports, which name circles by construction.
        let _ = fx.alice.owed_removal_commits();
        let _ = fx.alice.orphaned_removal_deferrals();

        // …and the SEND drain, which runs on every publish cycle: a send that
        // the engine accepts folds through `note_send_drain` and
        // `surface_co_drained_auto_commits` holding this circle's ids and the
        // fix's coordinates. The eviction the rollback surfaced has to be
        // resolved first or the send never reaches them at all — a staged
        // commit makes the engine refuse it outright — so it is published and
        // confirmed here, which also puts the Rule-13 ladder under the capture.
        //
        // Neither helper emits a line on this rung: they log a failed persist
        // and an unrecordable obligation, and neither happens on a healthy
        // send. So what this leg pins is the SILENCE of the highest-frequency
        // drain there is — a diagnostic added to either helper later lands in
        // this capture and has to survive the needles. The `expect` below is
        // its control: that rung is the only one on which they run.
        let commit = ingest
            .auto_commits
            .into_iter()
            .next()
            .expect("the rollback surfaced the eviction");
        let publisher = FakePublisher::new(&[true]);
        assert!(
            publisher
                .publish_auto_commit(&commit.commit_event, &[GROUP_RELAY.to_string()])
                .await,
            "precondition: the fake relay acks"
        );
        fx.alice
            .confirm_published(commit.pending)
            .await
            .expect("confirm the eviction");
        fx.alice
            .encrypt_location(
                &fx.mls_group_id,
                &fx.alice_keys.public_key(),
                &LocationMessage::new(64.135_666, -21.895_222),
                300,
            )
            .await
            .expect("the send is accepted, which is the rung that drains");
    })
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
