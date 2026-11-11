//! Local-first own-profile editing, proven over real sockets.
//!
//! The promise this binary pins is a pair: a save NEVER touches the network,
//! and only an explicit sync does — after which the app reports exactly the
//! coverage it got, never more. Every assertion is taken RELAY-SIDE (what
//! actually crossed a socket: distinct event ids, per-relay admissions, offers,
//! connections and REQs) rather than from the code's own return values,
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
//! identity, and the relay-side ledger is keyed by author. A test that needs a
//! relay it can script (refuse, lie, serve a newer copy) adds a
//! [`ScriptedRelay`] to ITS OWN account's Profile relays, beside the three.
//!
//! # One Blossom server per binary
//!
//! `set_blossom_server_for_test` is install-once, so one mock server serves the
//! whole binary and each test's mock is constrained to the bytes of its own
//! distinct JPEG: concurrent tests cannot answer each other.
//!
//! # No sleeps, no timing races
//!
//! Nothing here waits for time to pass. Where a test needs a sync to be
//! observably mid-flight it holds the relay's own admission point open with a
//! gate and releases it explicitly.

use std::collections::HashMap;
use std::net::SocketAddr;
use std::sync::atomic::{AtomicI64, Ordering};
use std::sync::{Arc, Mutex, PoisonError};

use haven_core::avatar::{process_own_avatar, StagedPicture};
use haven_core::circle::{
    CircleManager, ProfileSyncCommit, ProfileSyncOutcome, ProfileSyncReport, RelayType,
};
use haven_core::profile::{
    allow_private_blossom_for_test, build_metadata_event, profile_relay_pool_default,
    set_blossom_server_for_test, set_profile_relays_for_test, uncovered, CachedProfile,
    PendingEdits, ProfileMetadata, ProfileState, PROFILE_SYNC_BACKOFF_SECS,
};
use haven_core::relay::scripted_relay::{Frame, ScriptedRelay, Verdict};
use haven_core::relay::{allow_ws_loopback_for_test, normalize_relay_url};
use image::{codecs::jpeg::JpegEncoder, RgbImage};
use nostr::prelude::ToBech32 as _;
use nostr::util::BoxedFuture;
use nostr::{
    Event, EventBuilder, Filter, JsonUtil as _, Keys, Kind, Metadata, PublicKey, RelayUrl,
    Timestamp,
};
use nostr_relay_builder::builder::RelayBuilder;
use nostr_relay_builder::prelude::{PolicyResult, QueryPolicy, WritePolicy};
use nostr_relay_builder::LocalRelay;
use tempfile::TempDir;
use tokio::sync::{mpsc, watch};

mod helpers;
use helpers::{assert_no_needles, assert_some_line_from, capture_haven_log_here, haven_core_lines};

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
    /// How many `REQ`s named each author, counted when a relay is asked.
    queried: Mutex<HashMap<String, usize>>,
}

impl EventLedger {
    /// How many relay admissions this author's events accounted for.
    fn admissions(&self, author_hex: &str) -> usize {
        self.rows(author_hex).len()
    }

    /// How many `REQ`s naming this author the plane's relays have been asked.
    fn reqs(&self, author_hex: &str) -> usize {
        self.queried
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .get(author_hex)
            .copied()
            .unwrap_or(0)
    }

    /// The ids of the DISTINCT events this author has had admitted, in
    /// first-arrival order.
    fn ids(&self, author_hex: &str) -> Vec<String> {
        let mut seen: Vec<String> = Vec::new();
        for (id, _) in self.rows(author_hex) {
            if !seen.contains(&id) {
                seen.push(id);
            }
        }
        seen
    }

    /// `(admissions, REQs)` — everything this author has made the plane do.
    fn wire(&self, author_hex: &str) -> (usize, usize) {
        (self.admissions(author_hex), self.reqs(author_hex))
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

/// Counts the `REQ`s that name an author. Like the admission ledger it keys on
/// the author, so a test that reads "no REQ for me" is not disturbed by a
/// sibling test's traffic on the same relays.
#[derive(Debug)]
struct LedgerQueryPolicy {
    ledger: Arc<EventLedger>,
}

impl QueryPolicy for LedgerQueryPolicy {
    fn admit_query<'a>(
        &'a self,
        query: &'a Filter,
        _addr: &'a SocketAddr,
    ) -> BoxedFuture<'a, PolicyResult> {
        if let Some(authors) = &query.authors {
            let mut queried = self
                .ledger
                .queried
                .lock()
                .unwrap_or_else(PoisonError::into_inner);
            for author in authors {
                *queried.entry(author.to_hex()).or_default() += 1;
            }
        }
        Box::pin(async { PolicyResult::Accept })
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
                        let relay = LocalRelay::new(
                            RelayBuilder::default()
                                .write_policy(LedgerWritePolicy {
                                    ledger: Arc::clone(&ledger_for_relays),
                                })
                                .query_policy(LedgerQueryPolicy {
                                    ledger: Arc::clone(&ledger_for_relays),
                                }),
                        );
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
        ..PendingEdits::default()
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

/// A distinct 96x96 JPEG per `seed`, so each test's upload has bytes of its own.
fn jpeg(seed: u8) -> Vec<u8> {
    let mut img = RgbImage::new(96, 96);
    for (x, y, px) in img.enumerate_pixels_mut() {
        let r = u8::try_from(x % 256).unwrap_or(0);
        let g = u8::try_from(y % 256).unwrap_or(0);
        *px = image::Rgb([r, g, seed]);
    }
    let mut out = Vec::new();
    JpegEncoder::new_with_quality(std::io::Cursor::new(&mut out), 88)
        .encode_image(&img)
        .expect("encode jpeg");
    out
}

async fn sync(manager: &CircleManager, keys: &Keys, now: i64) -> ProfileSyncReport {
    manager
        .sync_own_profile(keys, move || now)
        .await
        .expect("sync runs")
}

fn signed(keys: &Keys, content: &str, at: u64) -> Event {
    EventBuilder::new(Kind::Metadata, content)
        .custom_created_at(Timestamp::from_secs(at))
        .sign_with_keys(keys)
        .expect("a locally built event signs")
}

/// Whether a published kind-0's content carries a `picture` field at all.
fn has_picture(content: &str) -> bool {
    serde_json::from_str::<serde_json::Value>(content)
        .expect("a kind-0 content is JSON")
        .get("picture")
        .is_some()
}

/// A `REQ` filter asking for `own`'s kind 0.
fn asks_own_profile(own: PublicKey) -> impl Fn(&Filter) -> bool + Send + Sync + 'static {
    move |filter| {
        filter.authors.as_ref().is_some_and(|a| a.contains(&own))
            && filter
                .kinds
                .as_ref()
                .is_some_and(|k| k.contains(&Kind::Metadata))
    }
}

// ---- the one Blossom server of this binary ----------------------------------

static BLOSSOM: tokio::sync::OnceCell<tokio::sync::Mutex<mockito::ServerGuard>> =
    tokio::sync::OnceCell::const_new();

async fn blossom() -> &'static tokio::sync::Mutex<mockito::ServerGuard> {
    BLOSSOM
        .get_or_init(|| async {
            // The upload path is SSRF-guarded, so the debug-only loopback
            // exemption has to be armed for it to be reachable at all.
            let _ = allow_private_blossom_for_test();
            let server = mockito::Server::new_async().await;
            set_blossom_server_for_test(server.url()).expect("install the Blossom override once");
            tokio::sync::Mutex::new(server)
        })
        .await
}

/// A sanitized photo and the content address Blossom will hand back for it.
struct Photo {
    staged: StagedPicture,
    sha_hex: String,
    url: String,
}

async fn photo(seed: u8) -> Photo {
    let staged = StagedPicture::from_processed(&process_own_avatar(&jpeg(seed)).expect("sanitize"));
    let sha_hex = hex::encode(staged.sha256());
    let url = format!("{}/{sha_hex}", blossom().await.lock().await.url());
    Photo {
        staged,
        sha_hex,
        url,
    }
}

/// Answers an upload of exactly this photo's bytes with `status`, `hits` times.
// The guard is held across the mock's creation by design.
#[allow(clippy::significant_drop_tightening)]
async fn upload_mock(photo: &Photo, status: usize, hits: usize) -> mockito::Mock {
    let descriptor = format!(
        r#"{{"url":"{}","sha256":"{}","size":{},"type":"image/jpeg","uploaded":1700000000}}"#,
        photo.url,
        photo.sha_hex,
        photo.staged.canonical().len(),
    );
    let mut server = blossom().await.lock().await;
    server
        .mock("PUT", "/upload")
        .match_body(photo.staged.canonical().to_vec())
        .with_status(status)
        .with_body(if status == 201 {
            descriptor
        } else {
            String::new()
        })
        .expect(hits)
        .create_async()
        .await
}

/// Publishes `photo` through a real sync (one PUT, every relay takes it).
async fn publish_photo(
    manager: &CircleManager,
    keys: &Keys,
    own_hex: &str,
    photo: &Photo,
    now: i64,
) {
    let upload = upload_mock(photo, 201, 1).await;
    manager
        .stage_own_profile_picture(own_hex, &photo.staged, now)
        .expect("stage the picture");
    let report = sync(manager, keys, now).await;
    assert_eq!(report.outcome, ProfileSyncOutcome::Published);
    assert!(!report.still_pending);
    upload.assert_async().await;
}

// ---- an account owing one relay its event -----------------------------------

/// An account whose first pass was taken by the three plane relays and refused
/// by one [`ScriptedRelay`] of its own: that relay is owed the event.
struct Scene {
    _dir: TempDir,
    manager: CircleManager,
    keys: Keys,
    own_hex: String,
    relay: ScriptedRelay,
    spares: Vec<ScriptedRelay>,
    first: Event,
    version: i64,
}

async fn scene(name: &str, refusal: &str, spares: usize) -> Scene {
    let plane = plane();
    let (dir, manager, keys, own_hex) = account();
    let add = |relay: ScriptedRelay| {
        manager
            .add_user_relay(relay.url(), RelayType::Profile)
            .expect("add the scripted relay");
        relay
    };
    let relay = add(ScriptedRelay::start());
    let spares: Vec<ScriptedRelay> = (0..spares).map(|_| add(ScriptedRelay::start())).collect();
    let refusal = refusal.to_owned();
    relay.on_publish(move |_| Verdict::Refuse(refusal.clone()));

    manager
        .stage_own_profile_edits(&own_hex, &name_edit(name), NOW)
        .expect("stage");
    let version = manager
        .pending_profile_sync(&own_hex)
        .unwrap()
        .expect("pending")
        .local_version;
    let report = sync(&manager, &keys, NOW).await;
    assert_eq!(report.outcome, ProfileSyncOutcome::Published);
    assert!(
        report.still_pending,
        "one relay refused it: it is still owed"
    );
    assert_eq!(relay.offers(), 1);
    assert!(relay.published().is_empty());
    let first = manager
        .profile_publish_debt(&keys.public_key(), version)
        .expect("debt read")
        .expect("the event is owed to the relay that refused it")
        .event;
    assert_eq!(plane.ledger.ids(&own_hex), [first.id.to_hex()]);
    Scene {
        _dir: dir,
        manager,
        keys,
        own_hex,
        relay,
        spares,
        first,
        version,
    }
}

impl Scene {
    fn serves(&self, frames: Vec<Frame>) {
        self.relay
            .answer(asks_own_profile(self.keys.public_key()), frames);
    }

    fn still_owed(&self) -> bool {
        self.manager
            .profile_publish_debt(&self.keys.public_key(), self.version)
            .expect("debt read")
            .is_some()
    }
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

    // (b) ...and NOTHING crossed a socket for this author, not even a read.
    assert!(
        plane.ledger.published(&own_hex).is_empty(),
        "a local save must not publish — it is the whole point of the outbox",
    );
    assert_eq!(plane.ledger.wire(&own_hex), (0, 0));
    let state = manager.profile_pending_state(&own_hex, NOW).unwrap();
    assert!(state.pending, "the save is queued");
    assert!(
        !manager
            .has_published_profile(&keys.public_key())
            .expect("gate read"),
        "an unpublished save must leave the retraction gate disarmed",
    );

    // (c) NON-VACUITY. Without this the zero above could just mean the relays
    // were unreachable, which would make the whole assertion worthless: the
    // SAME author over the SAME pool does publish, once told to.
    let report = sync(&manager, &keys, NOW + 1).await;
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
    let version = manager
        .pending_profile_sync(&own_hex)
        .unwrap()
        .expect("pending")
        .local_version;
    let report = sync(&manager, &keys, NOW).await;

    assert_eq!(report.outcome, ProfileSyncOutcome::Published);
    assert!(
        !report.still_pending,
        "full coverage of the newest version is the only thing that clears it",
    );

    // The wire carries the edit — one event, to every relay in the pool, after
    // the whole pool was read for a base.
    let published = plane.ledger.published(&own_hex);
    assert_eq!(published.len(), 1, "one kind-0, not one per retry round");
    assert_eq!(
        plane.ledger.admissions(&own_hex),
        POOL_SIZE,
        "a peer's assignment salt is private, so the publish must reach EVERY \
         pool relay, not a subset",
    );
    assert!(
        plane.ledger.reqs(&own_hex) >= POOL_SIZE,
        "the pass must read every pool relay before it signs",
    );
    assert!(
        published[0].contains("Fully Synced"),
        "the published payload must carry the saved name: {}",
        published[0],
    );

    // And the local state agrees with it.
    assert!(manager.pending_profile_sync(&own_hex).unwrap().is_none());
    assert!(
        manager
            .profile_publish_debt(&keys.public_key(), version)
            .unwrap()
            .is_none(),
        "a fully covered event owes nothing",
    );
    let state = manager.profile_pending_state(&own_hex, NOW).unwrap();
    assert!(!state.pending);
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
    sync(&manager, &keys, NOW).await;
    let before = plane.ledger.wire(&own_hex);
    assert_eq!(
        before.0, POOL_SIZE,
        "anti-vacuity: the first pass published"
    );

    let report = sync(&manager, &keys, NOW + 1).await;
    assert_eq!(report.outcome, ProfileSyncOutcome::NothingPending);
    assert!(!report.still_pending);
    assert_eq!(
        plane.ledger.wire(&own_hex),
        before,
        "an idempotent sync must neither publish nor read — every resume \
         trigger calls it",
    );
    assert_eq!(plane.ledger.ids(&own_hex).len(), 1);
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
        tokio::spawn(async move { manager.sync_own_profile(&keys, || NOW).await })
    };
    let second = {
        let manager = Arc::clone(&manager);
        let keys = keys.clone();
        tokio::spawn(async move { manager.sync_own_profile(&keys, || NOW).await })
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
async fn a_partial_ack_stays_pending_and_owes_only_the_relay_that_missed_it() {
    let plane = plane();
    let (_dir, manager, keys, own_hex) = account();

    // One extra relay that refuses every connection. The pool is now four, and
    // only three of them can ever acknowledge.
    let dead = dead_relay_url();
    manager
        .add_user_relay(&dead, RelayType::Profile)
        .expect("add the unreachable relay");
    let pool = manager.usable_profile_relays().expect("pool resolves");
    assert_eq!(pool.len(), POOL_SIZE + 1);

    manager
        .stage_own_profile_edits(&own_hex, &name_edit("Partially Synced"), NOW)
        .expect("stage");
    let version = manager
        .pending_profile_sync(&own_hex)
        .unwrap()
        .expect("pending")
        .local_version;
    let report = sync(&manager, &keys, NOW).await;

    assert_eq!(
        report.outcome,
        ProfileSyncOutcome::Published,
        "one ack is a real publish; calling it a failure would be as dishonest \
         as calling it synced",
    );
    assert!(
        report.still_pending,
        "a peer assigned to the relay that missed it still reads the OLD name",
    );
    let ids = plane.ledger.ids(&own_hex);
    assert_eq!(ids.len(), 1);
    assert_eq!(
        plane.ledger.admissions(&own_hex),
        POOL_SIZE,
        "only the reachable relays could take it — that IS the partial coverage",
    );

    // The ledger owes exactly the relay that missed it, with the very event the
    // others took.
    let debt = manager
        .profile_publish_debt(&keys.public_key(), version)
        .unwrap()
        .expect("the event is owed");
    assert_eq!(debt.event.id.to_hex(), ids[0]);
    assert_eq!(debt.covered.len(), POOL_SIZE);
    let owed = uncovered(&pool, &debt.covered);
    assert_eq!(owed.len(), 1);
    assert_eq!(
        RelayUrl::parse(&owed[0]).expect("owed url"),
        RelayUrl::parse(&dead).expect("dead url"),
        "the dead relay is the only one still owed",
    );

    let state = manager.profile_pending_state(&own_hex, NOW).unwrap();
    assert!(state.pending, "not synced");
    assert!(
        manager.has_published_profile(&keys.public_key()).unwrap(),
        "but published somewhere"
    );
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
    let version = manager
        .pending_profile_sync(&own_hex)
        .unwrap()
        .expect("pending")
        .local_version;

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

    let report = sync(&manager, &keys, NOW).await;

    assert_eq!(report.outcome, ProfileSyncOutcome::PoolUnderflow);
    assert!(report.still_pending, "the save is queued, never discarded");
    assert_eq!(
        plane.ledger.wire(&own_hex),
        (0, 0),
        "fail-closed means nothing crossed a socket — not even to the two pool \
         relays that stayed clean",
    );

    let state = manager.profile_pending_state(&own_hex, NOW).unwrap();
    assert!(state.pending);
    assert!(
        !manager.has_published_profile(&keys.public_key()).unwrap(),
        "nothing reached any relay"
    );
    assert!(
        manager
            .profile_publish_debt(&keys.public_key(), version)
            .unwrap()
            .is_none(),
        "no event was ever signed, so none is owed",
    );
    assert!(
        !state.retry_due,
        "an underflowed pool is terminal until the user changes something, so \
         the ladder must advance here too: without it every resume trigger \
         re-materializes the identity secret to reach this same answer",
    );
    assert!(
        manager
            .profile_pending_state(&own_hex, NOW + PROFILE_SYNC_BACKOFF_SECS[0])
            .unwrap()
            .retry_due,
        "the first rung must still come due — a pool the user repairs may not \
         stay unpublished forever",
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
async fn a_staged_picture_uploads_once_and_publishes_its_real_url() {
    let plane = plane();
    let (_dir, manager, keys, own_hex) = account();

    let photo = photo(42).await;
    let upload = upload_mock(&photo, 201, 1).await;

    manager
        .stage_own_profile_picture(&own_hex, &photo.staged, NOW)
        .expect("stage the picture");
    // Before the sync: the photo renders locally and nothing has been uploaded.
    assert!(
        !upload.matched_async().await,
        "staging a photo must not upload it — the save is local",
    );
    assert!(manager.profile_picture_is_staged(&own_hex).unwrap());
    assert!(manager.has_current_picture(&own_hex, None).unwrap());

    let report = sync(&manager, &keys, NOW).await;
    assert_eq!(report.outcome, ProfileSyncOutcome::Published);
    assert!(!report.still_pending);
    upload.assert_async().await;

    // The published kind-0 carries the URL the upload resolved to — not a
    // placeholder, and not the local cache's empty marker.
    let published = plane.ledger.published(&own_hex);
    assert_eq!(published.len(), 1);
    assert!(
        published[0].contains(&photo.sha_hex),
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
        Some(photo.url.as_str()),
    );
    assert_eq!(
        manager
            .get_profile_picture_url(&own_hex)
            .unwrap()
            .as_deref(),
        Some(photo.url.as_str()),
        "the cached row must be re-stamped with the real URL, or the next \
         freshness check would treat the just-uploaded photo as stale",
    );
    assert!(!manager.profile_picture_is_staged(&own_hex).unwrap());

    // A second sync must not re-upload: `expect(1)` above would fail if it did.
    let again = sync(&manager, &keys, NOW + 1).await;
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
        tokio::spawn(async move { manager.sync_own_profile(&keys, || NOW).await })
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
    assert_eq!(plane.ledger.admissions(&own_hex), POOL_SIZE);

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
        tokio::spawn(async move { manager.sync_own_profile(&keys, || NOW + 2).await })
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

// ===========================================================================
// The ledger: an identical re-send, and what a read-back decides
// ===========================================================================

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_retry_resends_the_identical_event_only_to_the_relay_that_has_not_served_it() {
    let plane = plane();
    let sc = scene("Resent", "blocked: not today", 1).await;
    let before = plane.ledger.wire(&sc.own_hex);
    let spare = (sc.spares[0].connections(), sc.spares[0].offers());

    sc.relay.on_publish(|_| Verdict::Keep);
    sc.serves(vec![Frame::Event(sc.first.clone()), Frame::Eose]);
    let report = sync(&sc.manager, &sc.keys, NOW + 1).await;

    assert_eq!(report.outcome, ProfileSyncOutcome::Published);
    assert!(!report.still_pending);
    let kept: Vec<_> = sc.relay.published().iter().map(|e| e.id).collect();
    assert_eq!(
        kept,
        [sc.first.id],
        "the very event pass 1 signed, byte for byte"
    );
    assert_eq!(sc.relay.offers(), 2, "refused once, then re-sent once");
    assert_eq!(
        plane.ledger.wire(&sc.own_hex),
        before,
        "the relays that already serve it saw no admission and no REQ",
    );
    assert_eq!(
        (sc.spares[0].connections(), sc.spares[0].offers()),
        spare,
        "a relay that already serves it is not even connected to",
    );
    assert_eq!(
        plane.ledger.ids(&sc.own_hex),
        [sc.first.id.to_hex()],
        "one kind-0 in all",
    );
    assert!(sc
        .manager
        .pending_profile_sync(&sc.own_hex)
        .unwrap()
        .is_none());
    assert!(!sc.still_owed());
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn an_owed_relay_that_acks_but_serves_a_newer_copy_redirects_onto_it() {
    let plane = plane();
    let sc = scene("Redirected", "blocked: not today", 0).await;

    // Another client wrote a newer profile that this relay serves, and the
    // relay answers our re-send with khatru's `OK true` regardless.
    let foreign = signed(
        &sc.keys,
        r#"{"display_name":"Other Client","website":"https://other.example.com"}"#,
        sc.first.created_at.as_secs() + 100,
    );
    sc.relay.on_publish(|_| Verdict::KeepSaying(String::new()));
    sc.serves(vec![Frame::Event(foreign.clone()), Frame::Eose]);
    let report = sync(&sc.manager, &sc.keys, NOW + 1).await;

    assert_eq!(report.outcome, ProfileSyncOutcome::Published);
    assert!(!report.still_pending);
    let kept = sc.relay.published();
    assert_eq!(kept.len(), 2, "the re-send, then the redirected event");
    assert_eq!(kept[0].id, sc.first.id);
    let second = &kept[1];
    assert!(second.verify().is_ok());
    assert!(second.content.contains("Redirected"), "our pending name");
    assert!(second.content.contains("other.example.com"), "their field");
    assert!(!second.content.contains("Other Client"), "our edit wins");
    assert!(
        second.created_at > foreign.created_at,
        "it supersedes theirs"
    );
    let ids = plane.ledger.ids(&sc.own_hex);
    assert_eq!(ids.len(), 2);
    assert_eq!(ids[1], second.id.to_hex());
    assert_eq!(
        plane.ledger.admissions(&sc.own_hex),
        2 * POOL_SIZE,
        "the new event reached every plane relay too",
    );
    assert!(sc
        .manager
        .pending_profile_sync(&sc.own_hex)
        .unwrap()
        .is_none());
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn an_owed_relay_that_acks_but_serves_nothing_stays_owed() {
    let plane = plane();
    let sc = scene("Not Served", "blocked: not today", 0).await;
    let before = plane.ledger.wire(&sc.own_hex);

    sc.relay.on_publish(|_| Verdict::Keep);
    sc.serves(vec![Frame::Eose]);
    let report = sync(&sc.manager, &sc.keys, NOW + 1).await;

    assert_eq!(report.outcome, ProfileSyncOutcome::PublishFailed);
    assert!(report.still_pending, "an OK is no evidence of storage");
    assert_eq!(plane.ledger.wire(&sc.own_hex), before);
    assert_eq!(plane.ledger.ids(&sc.own_hex).len(), 1);
    assert!(sc.still_owed(), "the event is still owed to that relay");
    let rung = |n: usize| NOW + 1 + PROFILE_SYNC_BACKOFF_SECS[n];
    assert!(
        !sc.manager
            .profile_pending_state(&sc.own_hex, rung(0))
            .unwrap()
            .retry_due,
        "the second failure sits on the second rung",
    );
    assert!(
        sc.manager
            .profile_pending_state(&sc.own_hex, rung(1))
            .unwrap()
            .retry_due
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_relay_that_served_our_id_without_eose_counts_as_covered() {
    let plane = plane();
    let sc = scene("Served Quietly", "blocked: not today", 0).await;
    let before = plane.ledger.wire(&sc.own_hex);

    // The relay sends our event and never its EOSE: the read ends at its
    // bound, and the event it did send still shows the relay holds it.
    let (_never_opened, held) = watch::channel(false);
    sc.relay.on_publish(|_| Verdict::Keep);
    sc.serves(vec![Frame::Event(sc.first.clone()), Frame::Hold(held)]);
    let report = sync(&sc.manager, &sc.keys, NOW + 1).await;

    assert_eq!(report.outcome, ProfileSyncOutcome::Published);
    assert!(!report.still_pending);
    assert!(!sc.still_owed());
    let kept: Vec<_> = sc.relay.published().iter().map(|e| e.id).collect();
    assert_eq!(kept, [sc.first.id]);
    assert_eq!(plane.ledger.wire(&sc.own_hex), before);
    assert_eq!(plane.ledger.ids(&sc.own_hex).len(), 1);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn an_owed_relay_refusing_the_event_as_too_old_gets_one_freshly_signed() {
    let plane = plane();
    let sc = scene("Aged", "blocked: not today", 0).await;

    let stale = sc.first.id;
    sc.relay.on_publish(move |event| {
        if event.id == stale {
            Verdict::Refuse("invalid: event too old".to_owned())
        } else {
            Verdict::Keep
        }
    });
    let report = sync(&sc.manager, &sc.keys, NOW + 1).await;

    assert_eq!(report.outcome, ProfileSyncOutcome::Published);
    assert!(!report.still_pending);
    let kept = sc.relay.published();
    assert_eq!(kept.len(), 1, "only the fresh event was ever kept there");
    assert_ne!(kept[0].id, sc.first.id);
    assert!(kept[0].content.contains("Aged"));
    assert!(kept[0].created_at > sc.first.created_at);
    assert_eq!(
        sc.relay.offers(),
        3,
        "refused, refused as old, then the fresh one"
    );
    let ids = plane.ledger.ids(&sc.own_hex);
    assert_eq!(ids.len(), 2, "one new id in total");
    assert_eq!(ids[1], kept[0].id.to_hex());
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_second_timestamp_refusal_does_not_resign_again() {
    let plane = plane();
    let sc = scene("Hostile Clock", "blocked: not today", 0).await;

    // A relay that refuses everything as too old is hostile or broken: it may
    // cost the healthy relays one fresh event, never one per pass.
    let offered: Arc<Mutex<Vec<nostr::EventId>>> = Arc::default();
    let log = Arc::clone(&offered);
    sc.relay.on_publish(move |event| {
        log.lock()
            .unwrap_or_else(PoisonError::into_inner)
            .push(event.id);
        Verdict::Refuse("invalid: event too old".to_owned())
    });
    let second = sync(&sc.manager, &sc.keys, NOW + 1).await;
    assert_eq!(second.outcome, ProfileSyncOutcome::Published);
    assert!(second.still_pending);
    let after_second = plane.ledger.wire(&sc.own_hex);
    assert_eq!(plane.ledger.ids(&sc.own_hex).len(), 2, "one fresh signing");

    let third = sync(&sc.manager, &sc.keys, NOW + 2).await;
    assert_eq!(third.outcome, ProfileSyncOutcome::PublishFailed);
    assert!(third.still_pending);

    let offered = offered
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .clone();
    assert_eq!(offered.len(), 3);
    assert_eq!(offered[0], sc.first.id, "pass 2 re-sent the original");
    assert_ne!(offered[1], sc.first.id, "and re-signed once");
    assert_eq!(
        offered[2], offered[1],
        "pass 3 re-sent that one, unsigned again"
    );
    assert_eq!(plane.ledger.ids(&sc.own_hex).len(), 2, "no third event");
    assert_eq!(
        plane.ledger.wire(&sc.own_hex),
        after_second,
        "the healthy relays were not touched by the third pass",
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn an_owed_relay_refusing_the_event_as_future_dated_gets_no_fresh_signing() {
    let plane = plane();
    let sc = scene("Future Dated", "blocked: not today", 0).await;
    let before = plane.ledger.wire(&sc.own_hex);

    // An event signed now is no less future-dated to that relay than the one
    // it refused, so a re-sign would only cost the healthy relays an event.
    sc.relay
        .on_publish(|_| Verdict::Refuse("invalid: event is in the future".to_owned()));
    let report = sync(&sc.manager, &sc.keys, NOW + 1).await;

    assert_eq!(report.outcome, ProfileSyncOutcome::PublishFailed);
    assert!(report.still_pending);
    assert!(
        sc.still_owed(),
        "the relay is still owed the event it refused"
    );
    assert_eq!(sc.relay.offers(), 2, "refused, then the same event re-sent");
    assert_eq!(
        plane.ledger.ids(&sc.own_hex),
        [sc.first.id.to_hex()],
        "no event was signed afresh",
    );
    assert_eq!(plane.ledger.wire(&sc.own_hex), before);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn an_owed_relay_that_never_answers_is_the_only_one_dialled() {
    let plane = plane();
    let (_dir, manager, keys, own_hex) = account();
    manager
        .add_user_relay(&dead_relay_url(), RelayType::Profile)
        .expect("add the unreachable relay");
    manager
        .stage_own_profile_edits(&own_hex, &name_edit("Owed To The Dead"), NOW)
        .expect("stage");
    let first = sync(&manager, &keys, NOW).await;
    assert_eq!(first.outcome, ProfileSyncOutcome::Published);
    assert!(first.still_pending);
    let before = plane.ledger.wire(&own_hex);

    let second = sync(&manager, &keys, NOW + 1).await;

    assert_eq!(second.outcome, ProfileSyncOutcome::PublishFailed);
    assert!(second.still_pending);
    assert_eq!(
        plane.ledger.wire(&own_hex),
        before,
        "the relays that serve it are neither asked nor sent anything",
    );
    assert_eq!(plane.ledger.ids(&own_hex).len(), 1);
    let rung = |n: usize| NOW + 1 + PROFILE_SYNC_BACKOFF_SECS[n];
    assert!(
        !manager
            .profile_pending_state(&own_hex, rung(0))
            .unwrap()
            .retry_due,
        "the ladder advanced to the second rung",
    );
    assert!(
        manager
            .profile_pending_state(&own_hex, rung(1))
            .unwrap()
            .retry_due
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_relay_leaving_the_pool_ends_its_debt() {
    let plane = plane();
    let sc = scene("Left Behind", "blocked: not today", 1).await;
    let before = plane.ledger.wire(&sc.own_hex);
    let (connections, offers) = (sc.relay.connections(), sc.relay.offers());
    let spare_offers = sc.spares[0].offers();

    assert!(sc
        .manager
        .remove_user_relay(sc.relay.url(), RelayType::Profile)
        .expect("the user removes the relay"));
    let report = sync(&sc.manager, &sc.keys, NOW + 1).await;

    assert_ne!(report.outcome, ProfileSyncOutcome::PublishFailed);
    assert!(
        !report.still_pending,
        "every relay left in the pool serves it"
    );
    assert!(sc
        .manager
        .pending_profile_sync(&sc.own_hex)
        .unwrap()
        .is_none());
    assert!(!sc.still_owed());
    assert_eq!(plane.ledger.wire(&sc.own_hex), before, "no network at all");
    assert_eq!(
        (sc.relay.connections(), sc.relay.offers()),
        (connections, offers),
        "the removed relay is never dialled again",
    );
    assert_eq!(sc.spares[0].offers(), spare_offers);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_newer_copy_a_fetch_cached_supersedes_the_owed_event() {
    let plane = plane();
    let sc = scene("Superseding", "blocked: not today", 0).await;
    let before = plane.ledger.reqs(&sc.own_hex);

    // A fetch cached a newer profile from another client while the event was
    // owed: re-sending the owed one could only put a superseded profile back.
    let at = sc.first.created_at.as_secs() + 1_000;
    let cached = CachedProfile {
        pubkey_hex: sc.own_hex.clone(),
        metadata: ProfileMetadata::from_metadata(
            Metadata::from_json(
                r#"{"display_name":"Fetched","website":"https://fetched.example.com"}"#,
            )
            .expect("metadata"),
        ),
        state: ProfileState::Known,
        event_created_at: i64::try_from(at).expect("a timestamp"),
        fetched_at: NOW,
    };
    assert!(sc.manager.upsert_profile_if_newer(&cached).unwrap());
    sc.relay.on_publish(|_| Verdict::Keep);
    let report = sync(&sc.manager, &sc.keys, NOW + 1).await;

    assert_eq!(report.outcome, ProfileSyncOutcome::Published);
    assert!(!report.still_pending);
    let kept = sc.relay.published();
    assert_eq!(kept.len(), 1);
    assert_eq!(sc.relay.offers(), 2, "the owed event was never re-sent");
    assert_ne!(kept[0].id, sc.first.id);
    assert!(kept[0].content.contains("Superseding"));
    assert!(kept[0].content.contains("fetched.example.com"));
    assert!(kept[0].created_at.as_secs() > at);
    assert_eq!(plane.ledger.ids(&sc.own_hex).len(), 2);
    assert!(
        plane.ledger.reqs(&sc.own_hex) >= before + POOL_SIZE,
        "a full pass reads the whole pool again",
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_partial_row_from_before_the_ledger_is_published_by_a_full_pass() {
    let plane = plane();
    let (_dir, manager, keys, own_hex) = account();
    let pool = manager.usable_profile_relays().expect("pool resolves");
    manager
        .stage_own_profile_edits(&own_hex, &name_edit("Legacy Partial"), NOW)
        .expect("stage");
    let version = manager
        .pending_profile_sync(&own_hex)
        .unwrap()
        .expect("pending")
        .local_version;

    // A row a pre-ledger build left: published at this version, covered by one
    // relay, and no owed event to re-send.
    let merged = manager.get_profile(&own_hex).unwrap().unwrap().metadata;
    let never_sent = build_metadata_event(&keys, &merged, None).expect("builds");
    manager
        .commit_profile_sync(&ProfileSyncCommit {
            pubkey: &keys.public_key(),
            version,
            merged: &merged,
            event: &never_sent,
            uploaded_picture: None,
            covered: &pool[..1],
            pool: &pool,
            complete: false,
            now: NOW,
        })
        .expect("the legacy partial commit");
    assert!(
        manager
            .profile_pending_state(&own_hex, NOW)
            .unwrap()
            .pending
    );
    assert!(manager
        .profile_publish_debt(&keys.public_key(), version)
        .unwrap()
        .is_none());
    assert_eq!(plane.ledger.wire(&own_hex), (0, 0), "anti-vacuity");

    let report = sync(&manager, &keys, NOW + 1).await;

    assert_eq!(report.outcome, ProfileSyncOutcome::Published);
    assert!(!report.still_pending);
    assert_eq!(plane.ledger.ids(&own_hex).len(), 1);
    assert_eq!(
        plane.ledger.admissions(&own_hex),
        POOL_SIZE,
        "a full pass: the whole pool is sent the event",
    );
    assert!(
        plane.ledger.reqs(&own_hex) >= POOL_SIZE,
        "after reading it all"
    );
}

// ===========================================================================
// Upload decoupled from the text publish
// ===========================================================================

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn an_upload_failure_still_publishes_the_pending_name_and_keeps_the_photo_staged() {
    let plane = plane();
    let (_dir, manager, keys, own_hex) = account();
    let photo = photo(20).await;
    let down = upload_mock(&photo, 500, 1).await;

    manager
        .stage_own_profile_edits(&own_hex, &name_edit("Name Before Photo"), NOW)
        .expect("stage the name");
    manager
        .stage_own_profile_picture(&own_hex, &photo.staged, NOW + 1)
        .expect("stage the picture");
    let first = sync(&manager, &keys, NOW + 2).await;

    assert_eq!(first.outcome, ProfileSyncOutcome::Published);
    assert!(first.still_pending, "the photo is still owed");
    down.assert_async().await;
    let published = plane.ledger.published(&own_hex);
    assert_eq!(published.len(), 1);
    assert!(published[0].contains("Name Before Photo"));
    assert!(!published[0].contains(&photo.sha_hex), "no picture yet");
    assert!(manager.profile_picture_is_staged(&own_hex).unwrap());

    down.remove_async().await;
    let up = upload_mock(&photo, 201, 1).await;
    let second = sync(&manager, &keys, NOW + 3).await;

    assert_eq!(second.outcome, ProfileSyncOutcome::Published);
    assert!(!second.still_pending);
    up.assert_async().await;
    let published = plane.ledger.published(&own_hex);
    assert_eq!(published.len(), 2);
    assert!(published[1].contains(&photo.sha_hex));
    assert!(!manager.profile_picture_is_staged(&own_hex).unwrap());
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn an_upload_failure_after_a_removal_publishes_the_removal_not_the_old_picture_on_the_wire() {
    let plane = plane();
    let (_dir, manager, keys, own_hex) = account();
    let old = photo(250).await;
    let new = photo(130).await;
    publish_photo(&manager, &keys, &own_hex, &old, NOW).await;

    // Remove A, pick B, and Blossom is down for B.
    manager
        .stage_own_picture_removal(&own_hex, NOW + 1)
        .expect("remove the photo");
    manager
        .stage_own_profile_picture(&own_hex, &new.staged, NOW + 2)
        .expect("pick another");
    let down = upload_mock(&new, 500, 1).await;
    let first = sync(&manager, &keys, NOW + 3).await;

    assert_eq!(first.outcome, ProfileSyncOutcome::Published);
    assert!(first.still_pending, "B is owed");
    down.assert_async().await;
    let published = plane.ledger.published(&own_hex);
    assert_eq!(published.len(), 2);
    assert!(
        !has_picture(&published[1]) && !published[1].contains(&old.sha_hex),
        "'untouched' would leave A on every relay: {}",
        published[1],
    );
    let snapshot = manager
        .pending_profile_sync(&own_hex)
        .unwrap()
        .expect("B owed");
    assert!(snapshot.picture_staged);
    assert!(!snapshot.edits.clear_picture, "A's removal went out");

    down.remove_async().await;
    let up = upload_mock(&new, 201, 1).await;
    let second = sync(&manager, &keys, NOW + 4).await;
    assert!(!second.still_pending);
    up.assert_async().await;
    let published = plane.ledger.published(&own_hex);
    assert_eq!(published.len(), 3);
    assert!(published[2].contains(&new.sha_hex) && !published[2].contains(&old.sha_hex));
}

// ===========================================================================
// Photo removal: local, then owed
// ===========================================================================

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_photo_removal_is_local_and_the_next_sync_publishes_the_cleared_picture() {
    let plane = plane();
    let (_dir, manager, keys, own_hex) = account();
    let photo = photo(70).await;
    publish_photo(&manager, &keys, &own_hex, &photo, NOW).await;
    assert!(plane.ledger.published(&own_hex)[0].contains(&photo.sha_hex));
    let before = plane.ledger.wire(&own_hex);

    let row = manager
        .stage_own_picture_removal(&own_hex, NOW + 1)
        .expect("remove the photo");

    assert_eq!(row.metadata.picture(), None, "instant on screen");
    assert_eq!(
        plane.ledger.wire(&own_hex),
        before,
        "and nothing crossed a socket"
    );
    assert!(manager.get_profile_picture(&own_hex).unwrap().is_none());
    assert!(manager.get_profile_picture_url(&own_hex).unwrap().is_none());
    assert!(
        manager
            .profile_pending_state(&own_hex, NOW + 1)
            .unwrap()
            .pending
    );

    let report = sync(&manager, &keys, NOW + 2).await;
    assert_eq!(report.outcome, ProfileSyncOutcome::Published);
    assert!(!report.still_pending);
    let published = plane.ledger.published(&own_hex);
    assert_eq!(published.len(), 2);
    assert!(
        !has_picture(&published[1]),
        "the cleared picture: {}",
        published[1]
    );
    assert_eq!(
        sync(&manager, &keys, NOW + 3).await.outcome,
        ProfileSyncOutcome::NothingPending,
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_photo_removal_by_an_account_that_never_published_publishes_nothing() {
    let plane = plane();
    let (_dir, manager, keys, own_hex) = account();
    let photo = photo(100).await;
    manager
        .stage_own_profile_picture(&own_hex, &photo.staged, NOW)
        .expect("stage the picture");
    manager
        .stage_own_picture_removal(&own_hex, NOW + 1)
        .expect("remove it again");

    let report = sync(&manager, &keys, NOW + 2).await;

    assert_eq!(report.outcome, ProfileSyncOutcome::NothingPending);
    assert!(!report.still_pending);
    assert_eq!(
        plane.ledger.admissions(&own_hex),
        0,
        "a removal must never mint a first public event",
    );
    assert!(manager.pending_profile_sync(&own_hex).unwrap().is_none());
    assert!(!manager.has_published_profile(&keys.public_key()).unwrap());
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_never_published_account_keeps_a_photo_whose_upload_failed_after_a_removal() {
    let plane = plane();
    let (_dir, manager, keys, own_hex) = account();
    let removed = photo(160).await;
    let kept = photo(161).await;
    manager
        .stage_own_profile_picture(&own_hex, &removed.staged, NOW)
        .expect("pick a photo");
    manager
        .stage_own_picture_removal(&own_hex, NOW + 1)
        .expect("remove it");
    manager
        .stage_own_profile_picture(&own_hex, &kept.staged, NOW + 2)
        .expect("pick another");
    let down = upload_mock(&kept, 500, 1).await;

    // Every relay answers that it holds nothing, so the removal alone would
    // settle; the photo the user saved after it must not settle with it.
    let first = sync(&manager, &keys, NOW + 3).await;

    assert_eq!(first.outcome, ProfileSyncOutcome::UploadFailed);
    assert!(first.still_pending);
    down.assert_async().await;
    assert!(manager.profile_picture_is_staged(&own_hex).unwrap());
    assert_eq!(
        plane.ledger.admissions(&own_hex),
        0,
        "nothing was ever public: nothing is sent",
    );
    let rung = NOW + 3 + PROFILE_SYNC_BACKOFF_SECS[0];
    assert!(
        !manager
            .profile_pending_state(&own_hex, rung - 1)
            .unwrap()
            .retry_due,
        "the failure took the first rung of the ladder",
    );
    assert!(
        manager
            .profile_pending_state(&own_hex, rung)
            .unwrap()
            .retry_due
    );

    down.remove_async().await;
    let up = upload_mock(&kept, 201, 1).await;
    let second = sync(&manager, &keys, rung).await;

    assert_eq!(second.outcome, ProfileSyncOutcome::Published);
    assert!(!second.still_pending);
    up.assert_async().await;
    let published = plane.ledger.published(&own_hex);
    assert_eq!(published.len(), 1);
    assert!(published[0].contains(&kept.sha_hex));
    assert!(!published[0].contains(&removed.sha_hex));
    assert!(!manager.profile_picture_is_staged(&own_hex).unwrap());
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_removal_staged_while_a_publish_is_in_flight_is_neither_lost_nor_reported_synced() {
    let plane = plane();
    let (_dir, manager, keys, own_hex) = account();
    let manager = Arc::new(manager);
    let photo = photo(190).await;
    publish_photo(&manager, &keys, &own_hex, &photo, NOW).await;

    manager
        .stage_own_profile_edits(&own_hex, &name_edit("Mid Flight"), NOW + 1)
        .expect("stage a name");
    let (mut hit, open) = plane.ledger.arm_gate(&own_hex);
    let inflight = {
        let manager = Arc::clone(&manager);
        let keys = keys.clone();
        tokio::spawn(async move { manager.sync_own_profile(&keys, || NOW + 1).await })
    };
    hit.recv().await.expect("the publish reached a relay");
    manager
        .stage_own_picture_removal(&own_hex, NOW + 2)
        .expect("remove the photo mid-flight");
    open.send(true).expect("release the gate");
    let first = inflight.await.expect("task").expect("sync");

    assert_eq!(first.outcome, ProfileSyncOutcome::Published);
    assert!(
        first.still_pending,
        "the removal is not part of what landed"
    );
    assert!(
        manager
            .pending_profile_sync(&own_hex)
            .unwrap()
            .expect("owed")
            .edits
            .clear_picture,
        "the removal was not lost",
    );

    let second = sync(&manager, &keys, NOW + 3).await;
    assert!(!second.still_pending);
    let published = plane.ledger.published(&own_hex);
    assert_eq!(published.len(), 3);
    assert!(published[1].contains("Mid Flight"));
    assert!(!has_picture(&published[2]), "{}", published[2]);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_removal_landing_before_the_staged_picture_is_read_sends_nothing_that_pass() {
    let plane = plane();
    let (_dir, manager, keys, own_hex) = account();
    let published_photo = photo(150).await;
    let staged_photo = photo(151).await;
    publish_photo(&manager, &keys, &own_hex, &published_photo, NOW).await;
    manager
        .stage_own_profile_picture(&own_hex, &staged_photo.staged, NOW + 1)
        .expect("pick another");
    let before = plane.ledger.wire(&own_hex);

    // The removal lands after the pass read the outbox: what it read no
    // longer describes the outbox, and building on it would re-sign the
    // published photo to every relay.
    let remover = own_hex.clone();
    manager.during_next_profile_sync_for_test(move |manager| {
        manager
            .stage_own_picture_removal(&remover, NOW + 2)
            .expect("remove the photo mid-pass");
    });
    let first = sync(&manager, &keys, NOW + 3).await;

    assert_eq!(first.outcome, ProfileSyncOutcome::PublishFailed);
    assert!(first.still_pending, "the removal is owed");
    assert_eq!(
        plane.ledger.wire(&own_hex),
        before,
        "the pass sent nothing and asked nothing",
    );
    assert!(
        manager
            .profile_pending_state(&own_hex, NOW + 3)
            .unwrap()
            .retry_due,
        "the removal is a fresh edit: the ladder was not advanced",
    );

    let second = sync(&manager, &keys, NOW + 4).await;
    assert_eq!(second.outcome, ProfileSyncOutcome::Published);
    assert!(!second.still_pending);
    let published = plane.ledger.published(&own_hex);
    assert_eq!(published.len(), 2);
    assert!(!has_picture(&published[1]), "{}", published[1]);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_slow_sync_dates_its_backoff_from_when_it_ends() {
    let plane = plane();
    let (_dir, manager, keys, own_hex) = account();
    let manager = Arc::new(manager);
    manager
        .add_user_relay(&dead_relay_url(), RelayType::Profile)
        .expect("add the unreachable relay");
    manager
        .stage_own_profile_edits(&own_hex, &name_edit("Slow"), NOW)
        .expect("stage");

    let clock = Arc::new(AtomicI64::new(NOW));
    let (mut hit, open) = plane.ledger.arm_gate(&own_hex);
    let pass = {
        let manager = Arc::clone(&manager);
        let keys = keys.clone();
        let clock = Arc::clone(&clock);
        tokio::spawn(async move {
            manager
                .sync_own_profile(&keys, move || clock.load(Ordering::SeqCst))
                .await
        })
    };
    hit.recv().await.expect("the pass reached a relay");
    let slow = PROFILE_SYNC_BACKOFF_SECS[0] + 10;
    clock.fetch_add(slow, Ordering::SeqCst);
    open.send(true).expect("release the gate");
    let report = pass.await.expect("task").expect("sync");
    assert!(report.still_pending, "the dead relay is owed");

    let end = NOW + slow;
    let state = manager.profile_pending_state(&own_hex, end).unwrap();
    assert!(state.pending);
    assert!(
        !state.retry_due,
        "a backoff dated from the pass's start would already be due"
    );
    assert!(
        manager
            .profile_pending_state(&own_hex, end + PROFILE_SYNC_BACKOFF_SECS[0])
            .unwrap()
            .retry_due
    );
}

// ===========================================================================
// Rule 15
// ===========================================================================

#[tokio::test]
async fn a_resend_and_a_redirect_log_no_relay_url_event_id_or_pubkey() {
    let mut needles: Vec<String> = Vec::new();
    let lines = capture_haven_log_here(async {
        let mut note = |sc: &Scene, events: &[&Event]| {
            needles.push(sc.own_hex.clone());
            needles.push(sc.keys.public_key().to_bech32().expect("npub"));
            needles.push(sc.relay.url().to_owned());
            needles.extend(sc.manager.usable_profile_relays().expect("pool"));
            needles.extend(events.iter().map(|e| e.id.to_hex()));
        };

        // A plain re-send, whose refusal and acknowledgement both carry prose
        // with a URL in it.
        let resend = scene(
            "Logged Resend",
            "blocked: see wss://leak.example/refused",
            0,
        )
        .await;
        resend
            .relay
            .on_publish(|_| Verdict::KeepSaying("ok: see wss://leak.example/acked".to_owned()));
        resend.serves(vec![Frame::Event(resend.first.clone()), Frame::Eose]);
        assert!(
            !sync(&resend.manager, &resend.keys, NOW + 1)
                .await
                .still_pending
        );
        note(&resend, &[&resend.first]);

        // And a redirect onto another client's newer copy.
        let redirect = scene(
            "Logged Redirect",
            "blocked: see wss://leak.example/refused",
            0,
        )
        .await;
        let foreign = signed(
            &redirect.keys,
            r#"{"display_name":"Other","website":"https://other.example.com"}"#,
            redirect.first.created_at.as_secs() + 100,
        );
        redirect
            .relay
            .on_publish(|_| Verdict::KeepSaying("ok: see wss://leak.example/acked".to_owned()));
        redirect.serves(vec![Frame::Event(foreign.clone()), Frame::Eose]);
        assert!(
            !sync(&redirect.manager, &redirect.keys, NOW + 1)
                .await
                .still_pending
        );
        let redirected = redirect.relay.published().last().cloned().expect("kept");
        note(&redirect, &[&redirect.first, &foreign, &redirected]);
    })
    .await;

    needles.push("wss://leak.example".to_owned());
    needles.push("leak.example".to_owned());
    let ours = haven_core_lines(&lines);
    assert_some_line_from(&ours, "haven_core::circle::profile_sync");
    let needles: Vec<&str> = needles.iter().map(String::as_str).collect();
    assert_no_needles(&ours, &needles);
}
