//! Local-first own-profile editing, proven over real sockets.
//!
//! The promise this binary pins is a pair: a save NEVER touches the network,
//! and only an explicit sync does — after which the app reports exactly the
//! coverage it got, never more. Every assertion is taken RELAY-SIDE (what
//! actually crossed a socket) rather than from the code's own return values,
//! because "we published" is precisely the claim under test.
//!
//! # Hermetic shape
//!
//! Three in-process relays back a `set_profile_relays_for_test` pool override.
//! The override is a process-global `OnceLock`, so it is installed exactly once
//! per binary (Check 12 of `check_profile_privacy_boundaries.sh` forbids
//! installing it from a lib test at all). The relays therefore have to outlive
//! any single `#[tokio::test]` runtime, so they run on a dedicated thread's
//! runtime; every test gets isolation from the OTHERS by using its own
//! identity, and the relay-side ledger is keyed by author.
//!
//! # No sleeps, no timing races
//!
//! Nothing here waits for time to pass. Where a test needs a sync to be
//! observably mid-flight it holds the relay's own admission point open with a
//! gate and releases it explicitly.

use std::collections::HashMap;
use std::net::SocketAddr;
use std::sync::{Arc, Mutex, PoisonError};

use haven_core::avatar::{process_own_avatar, StagedPicture};
use haven_core::circle::{CircleManager, ProfileSyncOutcome, RelayType};
use haven_core::profile::{
    allow_private_blossom_for_test, profile_relay_pool_default, set_blossom_server_for_test,
    set_profile_relays_for_test, PendingEdits, PROFILE_SYNC_BACKOFF_SECS,
};
use haven_core::relay::{allow_ws_loopback_for_test, normalize_relay_url};
use image::{codecs::jpeg::JpegEncoder, RgbImage};
use nostr::util::BoxedFuture;
use nostr::{Event, Keys};
use nostr_relay_builder::builder::RelayBuilder;
use nostr_relay_builder::prelude::{PolicyResult, WritePolicy};
use nostr_relay_builder::LocalRelay;
use tempfile::TempDir;
use tokio::sync::{mpsc, watch};

/// Pool size — exactly `PROFILE_POOL_MIN`, so every relay in it matters.
const POOL_SIZE: usize = 3;

/// Injected sync clock (Unix seconds). Only relative ordering matters.
const NOW: i64 = 1_800_000_000;

// ===========================================================================
// Relay-side ledger + admission gate
// ===========================================================================

/// Holds one author's admissions open until the test releases them.
#[derive(Clone, Debug)]
struct Gate {
    /// Fires once per admission reaching the gate.
    hit: mpsc::UnboundedSender<()>,
    /// Level-triggered release. A `watch` (not a `Notify`) because several
    /// relays reach the gate for the same event and all of them must be
    /// released by one signal, with no missed-wakeup window.
    open: watch::Receiver<bool>,
}

/// Every event each author has had admitted, and any gate armed for them.
///
/// Rows are recorded at ADMISSION — before the relay stores anything — so an
/// empty list means "no event for this author ever crossed a socket", which is
/// exactly the local-first promise. Each row is `(event id, content)`: one
/// publish reaches every pool relay, so the number of ROWS is the fan-out and
/// the number of DISTINCT ids is the number of kind-0s actually published.
#[derive(Debug, Default)]
struct EventLedger {
    admitted: Mutex<HashMap<String, Vec<(String, String)>>>,
    gates: Mutex<HashMap<String, Gate>>,
}

impl EventLedger {
    /// How many relay admissions this author's events accounted for.
    fn admissions(&self, author_hex: &str) -> usize {
        self.rows(author_hex).len()
    }

    /// The `content` of each DISTINCT event published by this author, in
    /// first-arrival order.
    fn published(&self, author_hex: &str) -> Vec<String> {
        let mut seen: Vec<String> = Vec::new();
        let mut out = Vec::new();
        for (id, content) in self.rows(author_hex) {
            if !seen.contains(&id) {
                seen.push(id);
                out.push(content);
            }
        }
        out
    }

    fn rows(&self, author_hex: &str) -> Vec<(String, String)> {
        self.admitted
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .get(author_hex)
            .cloned()
            .unwrap_or_default()
    }

    /// Arms a gate for one author, returning its hit signal and its release.
    ///
    /// The caller MUST keep the returned `watch::Sender` alive: dropping it
    /// releases the gate (a closed channel cannot hold a relay hostage).
    fn arm_gate(&self, author_hex: &str) -> (mpsc::UnboundedReceiver<()>, watch::Sender<bool>) {
        let (hit, hit_rx) = mpsc::unbounded_channel();
        let (open_tx, open) = watch::channel(false);
        self.gates
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .insert(author_hex.to_string(), Gate { hit, open });
        (hit_rx, open_tx)
    }
}

/// Records — and optionally gates — every event a relay is asked to admit.
#[derive(Debug)]
struct LedgerWritePolicy {
    ledger: Arc<EventLedger>,
}

impl WritePolicy for LedgerWritePolicy {
    fn admit_event<'a>(
        &'a self,
        event: &'a Event,
        _addr: &'a SocketAddr,
    ) -> BoxedFuture<'a, PolicyResult> {
        Box::pin(async move {
            let author = event.pubkey.to_hex();
            // Both locks are released before the await below — a std guard held
            // across an await would deadlock the whole relay.
            let gate = {
                self.ledger
                    .admitted
                    .lock()
                    .unwrap_or_else(PoisonError::into_inner)
                    .entry(author.clone())
                    .or_default()
                    .push((event.id.to_hex(), event.content.clone()));
                self.ledger
                    .gates
                    .lock()
                    .unwrap_or_else(PoisonError::into_inner)
                    .get(&author)
                    .cloned()
            };
            if let Some(mut gate) = gate {
                let _ = gate.hit.send(());
                while !*gate.open.borrow_and_update() {
                    if gate.open.changed().await.is_err() {
                        break;
                    }
                }
            }
            PolicyResult::Accept
        })
    }
}

// ===========================================================================
// The shared hermetic profile plane
// ===========================================================================

/// The in-process profile relay pool for this binary.
struct ProfilePlane {
    ledger: Arc<EventLedger>,
}

static PLANE: std::sync::OnceLock<ProfilePlane> = std::sync::OnceLock::new();

/// Starts (once) the hermetic profile plane and installs the pool override.
///
/// The relays live on their own runtime, parked forever: each `#[tokio::test]`
/// builds and tears down its own runtime, so a relay started inside one test
/// would stop serving the moment that test finished.
fn plane() -> &'static ProfilePlane {
    PLANE.get_or_init(|| {
        let _ = allow_ws_loopback_for_test();
        let ledger = Arc::new(EventLedger::default());
        let ledger_for_relays = Arc::clone(&ledger);
        let (tx, rx) = std::sync::mpsc::sync_channel(1);
        std::thread::Builder::new()
            .name("haven-profile-plane".to_string())
            .spawn(move || {
                let runtime = tokio::runtime::Builder::new_multi_thread()
                    .enable_all()
                    .build()
                    .expect("relay runtime");
                let relays = runtime.block_on(async {
                    let mut started = Vec::with_capacity(POOL_SIZE);
                    for _ in 0..POOL_SIZE {
                        let relay = LocalRelay::new(RelayBuilder::default().write_policy(
                            LedgerWritePolicy {
                                ledger: Arc::clone(&ledger_for_relays),
                            },
                        ));
                        relay.run().await.expect("local relay runs");
                        let url = relay.url().await.to_string();
                        started.push((relay, url));
                    }
                    started
                });
                let urls: Vec<String> = relays.iter().map(|(_, url)| url.clone()).collect();
                tx.send(urls).expect("hand the URLs to the test thread");
                // Keep the runtime (and therefore the relays) alive for the
                // whole binary.
                loop {
                    std::thread::park();
                }
            })
            .expect("spawn the relay thread");

        let urls: Vec<String> = rx
            .recv()
            .expect("the relays started")
            .iter()
            .filter_map(|url| normalize_relay_url(url))
            .collect();
        assert_eq!(
            urls.len(),
            POOL_SIZE,
            "every loopback relay URL must normalize, or the pool underflows",
        );
        set_profile_relays_for_test(urls).expect("install the pool override once per process");
        ProfilePlane { ledger }
    })
}

/// A fresh identity plus its own manager, sharing the hermetic pool.
fn account() -> (TempDir, CircleManager, Keys, String) {
    let dir = TempDir::new().expect("temp dir");
    let keys = Keys::generate();
    let manager = CircleManager::new_unencrypted(dir.path(), &keys).expect("manager opens");
    let own_hex = keys.public_key().to_hex();
    (dir, manager, keys, own_hex)
}

fn name_edit(display_name: &str) -> PendingEdits {
    PendingEdits {
        display_name: Some(display_name.to_string()),
        about: None,
    }
}

/// A loopback URL that refuses every connection: bind an ephemeral port to
/// reserve it, then drop the listener before returning.
fn dead_relay_url() -> String {
    let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("bind ephemeral port");
    let port = listener.local_addr().expect("local addr").port();
    drop(listener);
    format!("ws://127.0.0.1:{port}")
}

fn sample_jpeg() -> Vec<u8> {
    let mut img = RgbImage::new(96, 96);
    for (x, y, px) in img.enumerate_pixels_mut() {
        let r = u8::try_from(x % 256).unwrap_or(0);
        let g = u8::try_from(y % 256).unwrap_or(0);
        *px = image::Rgb([r, g, 42]);
    }
    let mut out = Vec::new();
    JpegEncoder::new_with_quality(std::io::Cursor::new(&mut out), 88)
        .encode_image(&img)
        .expect("encode jpeg");
    out
}

// ===========================================================================
// Tests
// ===========================================================================

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_local_save_publishes_nothing_until_a_sync_asks_for_it() {
    let plane = plane();
    let (_dir, manager, keys, own_hex) = account();

    let row = manager
        .stage_own_profile_edits(&own_hex, &name_edit("Locally Saved"), NOW)
        .expect("stage the edit");

    // (a) The save is immediately visible locally...
    assert_eq!(row.metadata.display_name(), Some("Locally Saved"));
    assert_eq!(
        manager
            .get_profile(&own_hex)
            .unwrap()
            .unwrap()
            .metadata
            .display_name(),
        Some("Locally Saved"),
    );

    // (b) ...and NOTHING crossed a socket for this author.
    assert!(
        plane.ledger.published(&own_hex).is_empty(),
        "a local save must not publish — it is the whole point of the outbox",
    );
    let state = manager.profile_pending_state(&own_hex, NOW).unwrap();
    assert!(state.pending, "the save is queued");
    assert!(!state.partial, "and it has reached no relay at all");
    assert!(
        !manager
            .has_published_profile(&keys.public_key())
            .expect("gate read"),
        "an unpublished save must leave the retraction gate disarmed",
    );

    // (c) NON-VACUITY. Without this the zero above could just mean the relays
    // were unreachable, which would make the whole assertion worthless: the
    // SAME author over the SAME pool does publish, once told to.
    let report = manager
        .sync_own_profile(&keys, NOW + 1)
        .await
        .expect("sync runs");
    assert_eq!(report.outcome, ProfileSyncOutcome::Published);
    assert_eq!(
        plane.ledger.published(&own_hex).len(),
        1,
        "exactly one kind-0 for this author, and only after the explicit sync",
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_fully_acked_sync_publishes_the_pending_version_and_clears_the_marker() {
    let plane = plane();
    let (_dir, manager, keys, own_hex) = account();

    manager
        .stage_own_profile_edits(&own_hex, &name_edit("Fully Synced"), NOW)
        .expect("stage");
    let report = manager
        .sync_own_profile(&keys, NOW)
        .await
        .expect("sync runs");

    assert_eq!(report.outcome, ProfileSyncOutcome::Published);
    assert_eq!(
        (report.relays_acked, report.relays_attempted),
        (
            u32::try_from(POOL_SIZE).unwrap(),
            u32::try_from(POOL_SIZE).unwrap()
        ),
        "every pool relay must have been asked, and every one acknowledged",
    );
    assert!(
        !report.still_pending,
        "full coverage of the newest version is the only thing that clears it",
    );

    // The wire carries the edit — one event, to every relay in the pool.
    let published = plane.ledger.published(&own_hex);
    assert_eq!(published.len(), 1, "one kind-0, not one per retry round");
    assert_eq!(
        plane.ledger.admissions(&own_hex),
        POOL_SIZE,
        "a peer's assignment salt is private, so the publish must reach EVERY \
         pool relay, not a subset",
    );
    assert!(
        published[0].contains("Fully Synced"),
        "the published payload must carry the saved name: {}",
        published[0],
    );

    // And the local state agrees with it.
    assert!(manager.pending_profile_sync(&own_hex).unwrap().is_none());
    let state = manager.profile_pending_state(&own_hex, NOW).unwrap();
    assert!(!state.pending && !state.partial);
    let stored = manager.get_profile(&own_hex).unwrap().unwrap();
    assert_eq!(stored.metadata.display_name(), Some("Fully Synced"));
    assert!(
        stored.event_created_at > 0,
        "the committed row must carry the REAL published created_at, or the \
         next edit cannot supersede it",
    );
    assert!(
        manager.has_published_profile(&keys.public_key()).unwrap(),
        "a published profile is one a retraction may legitimately delete",
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_sync_with_nothing_pending_touches_no_relay() {
    let plane = plane();
    let (_dir, manager, keys, own_hex) = account();

    manager
        .stage_own_profile_edits(&own_hex, &name_edit("Once"), NOW)
        .expect("stage");
    manager
        .sync_own_profile(&keys, NOW)
        .await
        .expect("first sync");

    let report = manager
        .sync_own_profile(&keys, NOW + 1)
        .await
        .expect("second sync");
    assert_eq!(report.outcome, ProfileSyncOutcome::NothingPending);
    assert_eq!((report.relays_acked, report.relays_attempted), (0, 0));
    assert!(!report.still_pending);
    assert_eq!(
        plane.ledger.published(&own_hex).len(),
        1,
        "an idempotent sync must not re-publish — every resume trigger calls it",
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn two_concurrent_syncs_publish_exactly_one_kind0() {
    let plane = plane();
    let (_dir, manager, keys, own_hex) = account();
    let manager = Arc::new(manager);

    manager
        .stage_own_profile_edits(&own_hex, &name_edit("Raced"), NOW)
        .expect("stage");

    let first = {
        let manager = Arc::clone(&manager);
        let keys = keys.clone();
        tokio::spawn(async move { manager.sync_own_profile(&keys, NOW).await })
    };
    let second = {
        let manager = Arc::clone(&manager);
        let keys = keys.clone();
        tokio::spawn(async move { manager.sync_own_profile(&keys, NOW).await })
    };
    let reports = [
        first.await.expect("task 1").expect("sync 1"),
        second.await.expect("task 2").expect("sync 2"),
    ];

    assert_eq!(
        plane.ledger.published(&own_hex).len(),
        1,
        "the sync lock must serialize the two passes; a second kind-0 would be \
         a duplicate publish of the same edit to every pool relay",
    );
    let published = reports
        .iter()
        .filter(|r| r.outcome == ProfileSyncOutcome::Published)
        .count();
    let nothing = reports
        .iter()
        .filter(|r| r.outcome == ProfileSyncOutcome::NothingPending)
        .count();
    assert_eq!(
        (published, nothing),
        (1, 1),
        "the loser observes the committed state, so it reports honestly rather \
         than claiming a publish it did not make: {reports:?}",
    );
    assert!(reports.iter().all(|r| !r.still_pending));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_partial_ack_reports_its_coverage_and_stays_pending() {
    let plane = plane();
    let (_dir, manager, keys, own_hex) = account();

    // One extra relay that refuses every connection. The pool is now four, and
    // only three of them can ever acknowledge.
    manager
        .add_user_relay(&dead_relay_url(), RelayType::Profile)
        .expect("add the unreachable relay");
    assert_eq!(
        manager
            .usable_profile_relays()
            .expect("pool resolves")
            .len(),
        POOL_SIZE + 1,
    );

    manager
        .stage_own_profile_edits(&own_hex, &name_edit("Partially Synced"), NOW)
        .expect("stage");
    let report = manager
        .sync_own_profile(&keys, NOW)
        .await
        .expect("sync runs");

    assert_eq!(
        report.outcome,
        ProfileSyncOutcome::Published,
        "one ack is a real publish; calling it a failure would be as dishonest \
         as calling it synced",
    );
    assert_eq!(
        (report.relays_acked, report.relays_attempted),
        (
            u32::try_from(POOL_SIZE).unwrap(),
            u32::try_from(POOL_SIZE + 1).unwrap()
        ),
    );
    assert!(
        report.still_pending,
        "a peer assigned to the relay that refused us still reads the OLD name",
    );
    assert_eq!(plane.ledger.published(&own_hex).len(), 1);
    assert_eq!(
        plane.ledger.admissions(&own_hex),
        POOL_SIZE,
        "only the reachable relays could take it — that IS the partial coverage",
    );

    let state = manager.profile_pending_state(&own_hex, NOW).unwrap();
    assert!(state.pending, "not synced");
    assert!(state.partial, "but published somewhere");
    assert!(
        !state.retry_due,
        "and the persisted ladder paces the opportunistic re-publish, so a \
         foreground trigger cannot re-dial the whole pool every time",
    );
    assert!(
        manager
            .profile_pending_state(&own_hex, NOW + PROFILE_SYNC_BACKOFF_SECS[0])
            .unwrap()
            .retry_due,
        "the first rung must eventually come due",
    );
    // The pending set survives, so the re-publish still carries the edit.
    assert_eq!(
        manager
            .pending_profile_sync(&own_hex)
            .unwrap()
            .expect("still pending")
            .edits,
        name_edit("Partially Synced"),
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn an_underflowed_pool_publishes_nothing_and_paces_the_retry() {
    let plane = plane();
    let (_dir, manager, keys, own_hex) = account();

    manager
        .stage_own_profile_edits(&own_hex, &name_edit("Fail Closed"), NOW)
        .expect("stage");

    // Contaminate ONE pool relay: the hermetic pool is exactly PROFILE_POOL_MIN,
    // so a single location-plane use of a pool relay is enough to underflow it.
    // Adding it to a location category records that contamination in the same
    // transaction, which is what the exclusion filter reads.
    let contaminated = profile_relay_pool_default()
        .first()
        .cloned()
        .expect("the hermetic pool is installed");
    manager
        .add_user_relay(&contaminated, RelayType::Inbox)
        .expect("record the contamination");
    assert!(
        manager.usable_profile_relays().is_err(),
        "the pool must really be unusable, or this test proves nothing",
    );

    let report = manager
        .sync_own_profile(&keys, NOW)
        .await
        .expect("sync runs");

    assert_eq!(report.outcome, ProfileSyncOutcome::PoolUnderflow);
    assert_eq!((report.relays_acked, report.relays_attempted), (0, 0));
    assert!(report.still_pending, "the save is queued, never discarded");
    assert_eq!(
        plane.ledger.admissions(&own_hex),
        0,
        "fail-closed means nothing crossed a socket — not even to the two pool          relays that stayed clean",
    );

    let state = manager.profile_pending_state(&own_hex, NOW).unwrap();
    assert!(state.pending);
    assert!(!state.partial, "nothing reached any relay");
    assert!(
        !state.retry_due,
        "an underflowed pool is terminal until the user changes something, so          the ladder must advance here too: without it every resume trigger          re-materializes the identity secret to reach this same answer",
    );
    assert!(
        manager
            .profile_pending_state(&own_hex, NOW + PROFILE_SYNC_BACKOFF_SECS[0])
            .unwrap()
            .retry_due,
        "the first rung must still come due — a pool the user repairs may not          stay unpublished forever",
    );
    assert_eq!(
        manager
            .pending_profile_sync(&own_hex)
            .unwrap()
            .expect("still pending")
            .edits,
        name_edit("Fail Closed"),
        "the queued edit survives a pass that never reached the network",
    );

    // The FFI answers an underflowed pool from local state alone (it never
    // reaches this body), and advances the SAME ladder through the manager
    // pass-through. A repeat must therefore climb a rung rather than restart
    // one, or a persistently unusable pool would still be re-asked every 30s.
    manager
        .record_profile_sync_attempt(&own_hex, NOW + 1)
        .expect("record the pre-checked attempt");
    assert!(
        !manager
            .profile_pending_state(&own_hex, NOW + 1 + PROFILE_SYNC_BACKOFF_SECS[0])
            .unwrap()
            .retry_due,
        "the second attempt must sit on the SECOND rung, not the first",
    );
    assert!(
        manager
            .profile_pending_state(&own_hex, NOW + 1 + PROFILE_SYNC_BACKOFF_SECS[1])
            .unwrap()
            .retry_due,
        "and the ladder must still come due",
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
// The mockito `Server` (and its mock guard) must live for the WHOLE test so the
// sync's HTTP round-trip can reach it; "drop it earlier" would delete the
// server the upload is aimed at. Same false positive the blossom.rs test module
// silences.
#[allow(clippy::significant_drop_tightening)]
async fn a_staged_picture_uploads_once_and_publishes_its_real_url() {
    let plane = plane();
    let (_dir, manager, keys, own_hex) = account();

    // A loopback Blossom. The upload path is SSRF-guarded, so the debug-only
    // loopback exemption has to be armed for it to be reachable at all.
    let _ = allow_private_blossom_for_test();
    let mut blossom = mockito::Server::new_async().await;
    let raw = sample_jpeg();
    let staged = StagedPicture::from_processed(&process_own_avatar(&raw).expect("sanitize"));
    let sha_hex = hex::encode(staged.sha256());
    let expected_url = format!("{}/{sha_hex}", blossom.url());
    let descriptor = format!(
        r#"{{"url":"{expected_url}","sha256":"{sha_hex}","size":{},"type":"image/jpeg","uploaded":1700000000}}"#,
        staged.canonical().len(),
    );
    let upload = blossom
        .mock("PUT", "/upload")
        .with_status(201)
        .with_body(descriptor)
        .expect(1)
        .create_async()
        .await;
    set_blossom_server_for_test(blossom.url()).expect("install the Blossom override once");

    manager
        .stage_own_profile_picture(&own_hex, &staged, NOW)
        .expect("stage the picture");
    // Before the sync: the photo renders locally and nothing has been uploaded.
    assert!(
        !upload.matched_async().await,
        "staging a photo must not upload it — the save is local",
    );
    assert!(manager.profile_picture_is_staged(&own_hex).unwrap());
    assert!(manager.has_current_picture(&own_hex, None).unwrap());

    let report = manager
        .sync_own_profile(&keys, NOW)
        .await
        .expect("sync runs");
    assert_eq!(report.outcome, ProfileSyncOutcome::Published);
    assert!(!report.still_pending);
    upload.assert_async().await;

    // The published kind-0 carries the URL the upload resolved to — not a
    // placeholder, and not the local cache's empty marker.
    let published = plane.ledger.published(&own_hex);
    assert_eq!(published.len(), 1);
    assert!(
        published[0].contains(&sha_hex),
        "the published picture must be the content address the sanitizer \
         produced: {}",
        published[0],
    );
    assert_eq!(
        manager
            .get_profile(&own_hex)
            .unwrap()
            .unwrap()
            .metadata
            .picture(),
        Some(expected_url.as_str()),
    );
    assert_eq!(
        manager
            .get_profile_picture_url(&own_hex)
            .unwrap()
            .as_deref(),
        Some(expected_url.as_str()),
        "the cached row must be re-stamped with the real URL, or the next \
         freshness check would treat the just-uploaded photo as stale",
    );
    assert!(!manager.profile_picture_is_staged(&own_hex).unwrap());

    // A second sync must not re-upload: `expect(1)` above would fail if it did.
    let again = manager
        .sync_own_profile(&keys, NOW + 1)
        .await
        .expect("second sync");
    assert_eq!(again.outcome, ProfileSyncOutcome::NothingPending);
    upload.assert_async().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_delete_during_an_inflight_sync_cannot_resurrect_the_profile() {
    // The race this closes: a sync that started before a retraction would
    // republish the deleted metadata with a NEWER `created_at`, so the relays
    // would serve the profile the user just deleted while every local check
    // reported the delete had succeeded. The defence is that both bodies run
    // under one lock, and this proves both halves of that.
    let plane = plane();
    let (_dir, manager, keys, own_hex) = account();
    let manager = Arc::new(manager);

    // ---- Phase A: the sync really does hold the lock across its network body.
    manager
        .stage_own_profile_edits(&own_hex, &name_edit("In Flight"), NOW)
        .expect("stage");
    let (mut hit, open) = plane.ledger.arm_gate(&own_hex);
    let inflight = {
        let manager = Arc::clone(&manager);
        let keys = keys.clone();
        tokio::spawn(async move { manager.sync_own_profile(&keys, NOW).await })
    };
    hit.recv()
        .await
        .expect("the sync reached a relay's admission point");
    // It is now provably INSIDE its critical section — the publish has reached
    // a relay, which happens strictly after the lock was taken. Nothing else
    // may enter until it leaves.
    assert!(
        manager.profile_sync_lock().try_lock().is_err(),
        "the sync body must run under the profile sync lock; without it a \
         retraction could interleave into the middle of a publish",
    );
    open.send(true).expect("release the gate");
    let report = inflight
        .await
        .expect("task")
        .expect("sync completes once released");
    assert_eq!(report.outcome, ProfileSyncOutcome::Published);
    assert_eq!(plane.ledger.published(&own_hex).len(), 1);
    assert_eq!(
        plane.ledger.admissions(&own_hex),
        POOL_SIZE,
        "only the reachable relays could take it — that IS the partial coverage",
    );

    // ---- Phase B: a retraction that runs under the lock is never overtaken.
    // Phase A established that the sync's snapshot read happens under the lock,
    // so holding the lock across the cancel forces the ordering: the sync can
    // only observe the state the retraction left behind.
    manager
        .stage_own_profile_edits(&own_hex, &name_edit("Should Never Be Published"), NOW + 1)
        .expect("stage a second edit");
    let guard = manager.profile_sync_lock().lock().await;
    let overtaking = {
        let manager = Arc::clone(&manager);
        let keys = keys.clone();
        tokio::spawn(async move { manager.sync_own_profile(&keys, NOW + 2).await })
    };
    // The retraction's cancel half, run exactly where the FFI retraction runs
    // it: inside the lock.
    manager
        .clear_profile_sync_state(&own_hex)
        .expect("cancel the pending edit");
    drop(guard);

    let overtaken = overtaking
        .await
        .expect("task")
        .expect("the queued sync completes");
    assert_eq!(
        overtaken.outcome,
        ProfileSyncOutcome::NothingPending,
        "the sync must observe the cancelled state, not the snapshot it wanted",
    );
    let published = plane.ledger.published(&own_hex);
    assert_eq!(
        published.len(),
        1,
        "the retracted edit must never reach a relay: {published:?}",
    );
    assert!(!published[0].contains("Should Never Be Published"));
    assert!(manager.pending_profile_sync(&own_hex).unwrap().is_none());
}
