//! O5's taxonomy, produced through the rig, and an explicit account of the arms
//! that have no case.
//!
//! Every receive-side arm below is reached by ingesting a REAL event on a REAL
//! device: no arm is "reached" by writing the state it describes into the store
//! and calling that a case. One exception is deliberate and named — the engine
//! raises `EngineError::ForkedEpoch` only when a same-epoch race finds no
//! retained recovery snapshot, and at MDK `e391adc` the snapshot map and the
//! `committed_from` set are pruned and cleared TOGETHER, so no sequence of
//! public calls separates them. That arm is therefore driven through the pure
//! [`classify_ingest`] with the engine's own error value, which is what the
//! classifier would receive.
//!
//! # The arms with no case here, and why
//!
//! Saying "one case per reachable arm" without saying which arms are
//! unreachable is a coverage claim nobody can check. At this pin the taxonomy
//! has exactly three arms this file does not produce:
//!
//! * **`ForwardDistance`** — the short-circuit that reports a stored
//!   `Retryable` row at an epoch at or below the tip. Reaching it needs a row
//!   staged as `Retryable` for content the device can now apply AND a fresh
//!   ingest of that same content, and the engine answers the second ingest of
//!   one MLS message from its recorded outcome instead. Phase 2, with the
//!   engine's own retry tick.
//! * **`SelfEvicted`** — this device's own leaf removed. It needs a removal
//!   commit, which is scenario S02/S21's machinery and not in this phase.
//! * **`Quarantined`** — measured, not assumed: the only induction the rig has
//!   is deleting a group's `OpenMLS` rows, and the engine resolves the
//!   transport group id BEFORE it consults the quarantine gate, so an event for
//!   a group with no hydrated state answers `Routing` instead. The test below
//!   pins both halves — the quarantine really is set, and the ingest really
//!   says routing — so the day the gate moves in front, it goes red and this
//!   bullet comes out.
//!
//! Everything else in [`Verdict`] has a case below, and the enumeration test at
//! the bottom is what keeps that sentence true.
//!
//! # Rule 15
//!
//! Nothing here formats a `haven_core` / `cgka_*` / `nostr` / `openmls` value.
//! The needle test at the bottom is the proof that the classifier's own output
//! carries nothing either — including in a PANIC message, which is where a
//! `{:?}` of a verdict would land.

#![allow(clippy::missing_panics_doc)]

use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::sync::atomic::AtomicUsize;
use std::sync::{Arc, Mutex};

use haven_core::circle::{CircleError, CircleManager};
use haven_core::location::LocationMessage;
use haven_core::nostr::mls::storage::{
    delete_openmls_group_state_for_test, is_session_live, openmls_group_keys_for_test,
    StorageConfig,
};
use haven_core::nostr::mls::types::{
    EngineError, EpochId, GroupId, IngestEffects, IngestOutcome, MessageState, OpenMlsContentKind,
    ScreenedIngest, SessionEffects, SessionError, StaleReason,
};
use haven_core::nostr::NostrError;
use haven_soak::nemesis::types::Fault;
use haven_soak::oracle::undecryptable::{
    classify, classify_ingest, classify_send, classify_session_send, Cause, Probe, StoredRow,
    Verdict,
};
use haven_soak::rig::circle::{build_circle, publish_and_resolve};
use haven_soak::rig::{
    install_process_globals, poll_until, CircleTag, DeviceTag, PublishVerdict, RelayPlane,
    RelayTag, RigError, SimCircle, SimDevice, Step,
};
use nostr::util::BoxedFuture;
use nostr::{
    Alphabet, Event, EventBuilder, EventId, Keys, Kind, SingleLetterTag, Tag, TagKind, Timestamp,
};
use nostr_relay_builder::builder::{PolicyResult, WritePolicy};
use nostr_relay_builder::{LocalRelay, RelayBuilder};

// ── A fault-free relay plane ────────────────────────────────────────────────

/// Records every event the relay ACCEPTED, which for a policy that never
/// rejects is exactly the set it stored and acknowledged.
#[derive(Debug, Clone, Default)]
struct AcceptLedger {
    accepted: Arc<Mutex<Vec<EventId>>>,
}

impl WritePolicy for AcceptLedger {
    fn admit_event<'a>(
        &'a self,
        event: &'a Event,
        _addr: &'a SocketAddr,
    ) -> BoxedFuture<'a, PolicyResult> {
        Box::pin(async move {
            self.accepted.lock().unwrap().push(event.id);
            PolicyResult::Accept
        })
    }
}

/// The plainest possible relay plane: a real in-process relay that breaks in no
/// way at all.
///
/// Deliberately NOT the rig's own `SimRelay`: these tests assert the
/// classifier, and a classifier case must not fail because a fault layer it
/// never uses changed. Its `apply` refuses every fault for the same reason — a
/// fault that silently did not fire is worse than one that could not.
struct PlainRelay {
    tag: RelayTag,
    url: String,
    ledger: AcceptLedger,
    _relay: LocalRelay,
}

impl PlainRelay {
    async fn start(tag: RelayTag) -> Self {
        let ledger = AcceptLedger::default();
        let relay = LocalRelay::new(
            RelayBuilder::default()
                .addr(IpAddr::V4(Ipv4Addr::LOCALHOST))
                .write_policy(ledger.clone()),
        );
        relay.run().await.expect("the relay binds");
        let url = relay.url().await.to_string();
        Self {
            tag,
            url,
            ledger,
            _relay: relay,
        }
    }
}

impl RelayPlane for PlainRelay {
    // Nothing here ever applies one: this double is a plain relay, and an
    // expectation floor over it would be a floor over an arm that never ran.
    fn faults_applied(&self) -> usize {
        0
    }

    fn tag(&self) -> RelayTag {
        self.tag
    }

    fn url(&self) -> &str {
        &self.url
    }

    async fn apply(&mut self, fault: Fault) -> Result<(), RigError> {
        match fault {
            Fault::Heal => Ok(()),
            _ => Err(RigError::Core(Step::ApplyFault)),
        }
    }

    fn witnessed_ok(&self, event_id: &EventId) -> bool {
        self.ledger.accepted.lock().unwrap().contains(event_id)
    }
}

// ── Fixture ─────────────────────────────────────────────────────────────────

/// Two devices, one relay, one real circle.
struct World {
    devices: Vec<SimDevice>,
    circle: SimCircle,
    relays: Vec<PlainRelay>,
}

impl World {
    async fn build(members: usize) -> Self {
        install_process_globals().expect("the ws:// loopback opt-in");
        let relays = vec![PlainRelay::start(RelayTag::new(0)).await];
        let urls: Vec<String> = relays.iter().map(|r| r.url().to_string()).collect();
        let devices: Vec<SimDevice> = (0..members)
            .map(|ordinal| {
                SimDevice::open(
                    DeviceTag::new(u32::try_from(ordinal).expect("small")),
                    &urls,
                )
                .expect("open a device")
            })
            .collect();
        // The rig's staged-commit counter. Nothing in this file reads it: the
        // quiescence predicate is the only consumer, and no oracle runs here.
        let outstanding = Arc::new(AtomicUsize::new(0));
        let circle = build_circle(CircleTag::new(0), &devices, &relays, &urls, &outstanding)
            .await
            .expect("build a circle");
        Self {
            devices,
            circle,
            relays,
        }
    }

    fn admin(&self) -> &SimDevice {
        &self.devices[0]
    }

    fn peer(&self) -> &SimDevice {
        &self.devices[1]
    }

    fn peer_mut(&mut self) -> &mut SimDevice {
        &mut self.devices[1]
    }

    const fn group(&self) -> &GroupId {
        self.circle.mls_group_id()
    }
}

/// One real, routable location event from `device`.
async fn location(device: &SimDevice, group: &GroupId) -> Event {
    device
        .manager()
        .expect("manager")
        .encrypt_location(
            group,
            &device.keys.public_key(),
            &LocationMessage::new(48.85, 2.35),
            60,
        )
        .await
        .expect("encrypt")
        .0
}

// ── Haven's own pre-authentication screens ──────────────────────────────────

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn an_expired_event_is_screened_before_the_engine() {
    // Fed to the seam directly, and that is not a shortcut: a relay drops an
    // expired event before it ever notifies a client, so no delivery path can
    // produce this arm.
    let world = World::build(2).await;
    let expired = EventBuilder::new(Kind::Custom(445), "never read: the screen runs first")
        .tags([
            Tag::custom(
                TagKind::SingleLetter(SingleLetterTag::lowercase(Alphabet::H)),
                [hex::encode(world.circle.nostr_group_id())],
            ),
            Tag::expiration(Timestamp::from(1)),
        ])
        .sign_with_keys(&Keys::generate())
        .expect("sign");

    assert!(
        classify(world.peer(), &expired, StoredRow::Unknown)
            .await
            .expect("classify")
            == Verdict::Expired,
        "an event past its NIP-40 expiration is screened before the engine"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn an_unparseable_envelope_is_a_pre_auth_rejection() {
    let world = World::build(2).await;
    let unroutable = EventBuilder::new(Kind::Custom(445), "no routing tag")
        .sign_with_keys(&Keys::generate())
        .expect("sign");

    assert!(
        classify(world.peer(), &unroutable, StoredRow::Unknown)
            .await
            .expect("classify")
            == Verdict::PreAuth,
        "an unparseable envelope is a pre-authentication rejection"
    );
}

// ── The engine's own outcomes ───────────────────────────────────────────────

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn an_event_for_an_unheld_group_is_routing() {
    let world = World::build(2).await;
    let foreign = EventBuilder::new(Kind::Custom(445), "for a circle this device does not hold")
        .tags([Tag::custom(
            TagKind::SingleLetter(SingleLetterTag::lowercase(Alphabet::H)),
            [hex::encode([7u8; 32])],
        )])
        .sign_with_keys(&Keys::generate())
        .expect("sign");

    assert!(
        classify(world.peer(), &foreign, StoredRow::Unknown)
            .await
            .expect("classify")
            == Verdict::Routing,
        "an event for a group this device does not hold is a routing outcome"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_co_members_location_applies_and_a_second_look_is_a_duplicate() {
    let world = World::build(2).await;
    let sent = location(world.admin(), world.group()).await;

    assert!(
        classify(world.peer(), &sent, StoredRow::Unknown)
            .await
            .expect("classify")
            == Verdict::Applied,
        "a co-member's real location must apply"
    );
    // The duplicate is the SUBJECT here, not an accident: re-delivery is what a
    // relay does, and the classifier must call it a duplicate rather than
    // re-classifying the content.
    assert!(
        classify(world.peer(), &sent, StoredRow::Unknown)
            .await
            .expect("classify")
            == Verdict::Duplicate,
        "a re-delivery of the same content is a duplicate, never a re-classification"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_devices_own_publication_is_an_own_echo() {
    let world = World::build(2).await;
    let sent = location(world.admin(), world.group()).await;

    assert!(
        classify(world.admin(), &sent, StoredRow::Unknown)
            .await
            .expect("classify")
            == Verdict::OwnEcho,
        "a device's own publication echoed back is an own echo"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn an_event_ingested_during_a_publish_before_apply_transition_is_a_commit_gap() {
    // Rule 12's shape, at the smallest scale that produces it. NOT a message
    // from a higher epoch: the kind-445 outer layer is keyed by the sender's
    // epoch exporter, so a device an epoch behind cannot even peel one (see the
    // peel-failure case below). The engine's buffering outcome is the
    // publish-before-apply transition — a commit staged here and not yet
    // resolved — and a caller that read that as junk would drop a message the
    // group is about to apply.
    let world = World::build(2).await;
    let sent = location(world.peer(), world.group()).await;
    let staged = world
        .admin()
        .manager()
        .expect("manager")
        .update_circle_relays(world.group(), &["wss://gap.invalid".to_string()])
        .await
        .expect("stage a commit");

    let got = classify(world.admin(), &sent, StoredRow::Unknown)
        .await
        .expect("classify");
    assert!(
        got == Verdict::CommitGap,
        "an event the engine may not apply yet is a named gap, never a drop"
    );

    // Left staged on purpose until here, and resolved now: a pending state that
    // is neither confirmed nor rolled back forks the group.
    world
        .admin()
        .manager()
        .expect("manager")
        .publish_failed(staged.pending)
        .await
        .expect("the staged commit rolls back");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_group_whose_state_was_deleted_quarantines_and_then_answers_routing() {
    // The induction S13 uses, at unit scale: the store is CLOSED, the group's
    // OpenMLS rows are removed, and the session is reopened. The quarantine IS
    // set — and an inbound event for that group still classifies as ROUTING,
    // not as `Quarantined`, because the engine resolves the transport group id
    // before it consults the quarantine gate and a group with no hydrated state
    // resolves to nothing (measured at this pin; `ingest.rs`'s gate sits after
    // `group_id_for_transport_group_id`).
    //
    // Both halves are asserted. The day the engine consults the gate first,
    // this test goes red and `Verdict::Quarantined` becomes reachable — which
    // is exactly when the module header above must stop listing it.
    let mut world = World::build(2).await;
    let sealed = location(world.admin(), world.group()).await;

    let db = world.peer().session_db_path();
    let key = StorageConfig::test_sqlcipher_key().expect("the test store key");
    let dir = world.peer().dir.path().to_path_buf();
    let keys = world.peer().keys.clone();
    drop(world.peer_mut().take_manager());
    assert!(
        wait_until_released(&db).await,
        "the store must really be closed: a live session holds its own \
         connection and its own hydrated state"
    );

    let group_keys = openmls_group_keys_for_test(&db, &key).expect("the store's group keys");
    let [only] = group_keys.as_slice() else {
        panic!("one circle must add exactly one group key, or the induction no longer aims");
    };
    let removed = delete_openmls_group_state_for_test(&db, &key, only).expect("the delete runs");
    assert!(removed > 0, "a delete that matched nothing induces nothing");

    let reopened = CircleManager::new_unencrypted(&dir, &keys).expect("the store reopens");
    world.peer_mut().restore_manager(Arc::new(reopened));

    assert!(
        !world
            .peer()
            .session()
            .expect("session")
            .quarantined_group_ids()
            .await
            .is_empty(),
        "the reopen must really have frozen a group, or the induction no longer \
         reaches the state S13 grades"
    );
    let got = classify(world.peer(), &sealed, StoredRow::Unknown)
        .await
        .expect("classify");
    assert!(
        got == Verdict::Routing,
        "a group whose state was deleted resolves to nothing before the \
         quarantine gate is consulted, so the honest answer is a routing outcome"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_forged_kind_445_for_a_held_group_fails_to_peel() {
    // P-L2. Everything about this envelope is well formed — kind 445, exactly
    // one `h` naming a circle this device really holds, a fresh ephemeral
    // author, and a base64 payload long enough to carry a nonce and a tag — so
    // the pre-authentication screens pass it and the rejection happens where it
    // should: at the exporter-keyed AEAD, which no forger can satisfy.
    //
    // A FIXED payload rather than a sampled one: the verdict must not depend on
    // a draw, and no 33-byte string decrypts under a key the forger never had.
    let world = World::build(2).await;
    let forged = EventBuilder::new(Kind::Custom(445), FORGED_445_PAYLOAD)
        .tags([Tag::custom(
            TagKind::SingleLetter(SingleLetterTag::lowercase(Alphabet::H)),
            [hex::encode(world.circle.nostr_group_id())],
        )])
        .sign_with_keys(&Keys::generate())
        .expect("sign");

    assert!(
        classify(world.peer(), &forged, StoredRow::Unknown)
            .await
            .expect("classify")
            == Verdict::PeelFailed,
        "a well-formed envelope this device cannot open is a peel failure, which \
         is what tells a scenario the ciphertext was foreign rather than the \
         envelope malformed"
    );
}

/// 44 base64 characters — 33 bytes, enough for a 12-byte nonce, a 16-byte tag
/// and a few bytes of ciphertext, so the peel reaches the AEAD instead of
/// stopping at a length check.
const FORGED_445_PAYLOAD: &str = "c29ha0ZvcmdlZDQ0NVBheWxvYWRUaGF0V2lsbE5ldmVy";

/// Waits, bounded, for a closed store to release its Rule-14 guard.
async fn wait_until_released(db: &std::path::Path) -> bool {
    poll_until(RELEASE_BOUND, RELEASE_POLL, || async {
        is_session_live(db)
            .map(|live| !live)
            .map_err(|_| RigError::Core(Step::ReadSessionLiveness))
    })
    .await
    .expect("the liveness read")
    .is_some()
}

/// The same bound the rig's own restart uses: the guard goes when the last task
/// holding a manager handle finishes, which is not instantaneous.
const RELEASE_BOUND: std::time::Duration = std::time::Duration::from_secs(30);

/// How often that is re-read.
const RELEASE_POLL: std::time::Duration = std::time::Duration::from_millis(20);

// ── P-M1: the branch-loss controls come from a genuine race ─────────────────

/// Both co-admins commit from one epoch; the loser's branch is discarded, and
/// only the stored row says so.
///
/// Produced by a REAL same-epoch commit race — never by planting a row, which
/// would assert the fixture rather than the engine.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_same_epoch_race_is_classified_as_a_branch_loss() {
    let world = World::build(2).await;
    promote_to_admin(&world).await;

    let admin_commit = commit_relay_update(&world, world.admin(), "wss://admin.invalid").await;
    let peer_commit = commit_relay_update(&world, world.peer(), "wss://peer.invalid").await;

    let mut verdicts = Vec::new();
    for (device, commit) in [(world.admin(), &peer_commit), (world.peer(), &admin_commit)] {
        // The row is LOCATED, not guessed: the engine keys it on the peeled MLS
        // content, which no holder of the signed event can compute.
        let verdict = {
            let before = classify(device, commit, StoredRow::Unknown)
                .await
                .expect("classify");
            if before == Verdict::Applied {
                // The winner applied the peer's branch; there is no stale row.
                Verdict::Applied
            } else {
                // The loser's row is the one the locator finds.
                let record = device
                    .session()
                    .expect("session")
                    .stored_convergence_input_for_test(world.group(), OpenMlsContentKind::Commit, 1)
                    .await
                    .expect("the losing device holds the row its ingest wrote");
                let probe = Probe::Read(
                    device
                        .session()
                        .expect("session")
                        .stored_message_record_for_test(&record.id)
                        .await
                        .expect("read the row"),
                );
                // Re-classified from the SAME outcome shape, with the row named.
                // `classify` already consumed the one ingest this event gets, so
                // the outcome is re-stated rather than re-ingested — a second
                // ingest would answer AlreadySeen.
                classify_ingest(&Ok(stale_at_epoch()), probe)
            }
        };
        verdicts.push(verdict);
    }

    assert!(
        verdicts
            .iter()
            .filter(|v| **v == Verdict::PastEpochOrBranchLoss { branch_loss: true })
            .count()
            == 1,
        "a same-epoch race costs exactly one branch, and the probe is what says which"
    );
    assert!(
        verdicts.iter().filter(|v| **v == Verdict::Applied).count() == 1,
        "and the other device applies the surviving branch"
    );
}

/// An `AlreadyAtEpoch` whose row the caller cannot name must never read as
/// "no branch was lost".
#[test]
fn an_unnamed_row_refuses_to_guess_the_branch_loss() {
    assert!(
        classify_ingest(&Ok(stale_at_epoch()), Probe::Unnamed)
            == Verdict::Defect(Cause::BranchLossUndetermined),
        "an unnamed row leaves the branch-loss bit undetermined, never false"
    );
    assert!(
        classify_ingest(&Ok(stale_at_epoch()), Probe::Unreadable)
            == Verdict::Defect(Cause::ProbeUnreadable),
        "and a row the store refused is reported as such"
    );
}

// ── The fork arm, and Rule 15 over the classifier's own output ──────────────

#[test]
fn a_forked_epoch_error_is_a_fork() {
    assert!(
        classify_ingest(&Err(forked_epoch(&[0xab; 32], 3, 4)), Probe::Unnamed) == Verdict::Fork,
        "the engine's own fork error is the only thing that makes a fork verdict"
    );
    // Every other engine failure is a defect, never swept into the fork arm:
    // reporting a fork that did not happen would send a scenario looking for a
    // divergence nothing produced.
    assert!(
        classify_ingest(
            &Err(SessionError::Engine(EngineError::Backend("x".into()))),
            Probe::Unnamed
        ) == Verdict::Defect(Cause::EngineFailure),
        "every other engine failure is a defect, never swept into the fork arm"
    );
}

/// Acceptance 3b: a needle-shaped group id and two absolute epochs are forced
/// through the fork path, and neither the verdict's rendering nor the PANIC
/// message a failed assertion on it produces carries any of them.
///
/// The panic half is the point. `EngineError::ForkedEpoch`'s own `Debug` prints
/// the group id and its `Display` prints both epochs, so any classifier that
/// carried the error into its verdict — or that `expect`ed on it — would put all
/// three into the next assertion failure, i.e. into a CI log. A verdict with
/// no payload cannot.
#[test]
fn fork_classification_leaks_no_identifier() {
    const NEEDLE: [u8; 32] = [0x5a; 32];
    const LAST_STABLE: u64 = 987_654_321;
    const CONFLICTING: u64 = 123_456_789;
    let needles = [
        hex::encode(NEEDLE),
        hex::encode(NEEDLE).to_uppercase(),
        LAST_STABLE.to_string(),
        CONFLICTING.to_string(),
    ];

    let verdict = classify_ingest(
        &Err(forked_epoch(&NEEDLE, LAST_STABLE, CONFLICTING)),
        Probe::Unnamed,
    );
    assert!(verdict == Verdict::Fork, "the fork path really ran");

    let rendered = format!("{verdict:?}");
    assert!(
        rendered.contains("Fork"),
        "an empty rendering would pass every absence below trivially"
    );
    // The panic text a failed assertion on this verdict would emit. Deliberately
    // provoked and caught: this IS the leak surface acceptance 3b is about, and
    // the assertions below are what protect it.
    // log-scan-ok: the panic is the subject — it renders a value-free Verdict on
    // purpose, and the needle assertions below prove it carries nothing.
    let panicked = std::panic::catch_unwind(|| {
        assert_eq!(
            verdict,
            Verdict::Expired,
            "deliberate: capture the panic text"
        );
    })
    .expect_err("the assertion must fail so there is a panic to read");
    let panic_text = panicked
        .downcast_ref::<String>()
        .cloned()
        .unwrap_or_default();
    assert!(
        panic_text.contains("Fork"),
        "the captured panic must really render the verdict"
    );

    for needle in &needles {
        for text in [&rendered, &panic_text] {
            assert!(
                !text.contains(needle.as_str()),
                "the classifier's output carries a planted identifier or an \
                 absolute epoch (Security Rule 15)"
            );
        }
    }
}

// ── The send side ───────────────────────────────────────────────────────────

/// A REAL deferral: one stored row gating the circle stops the engine
/// encrypting, and the classifier names that rather than an opaque failure.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_gated_send_is_classified_as_deferred() {
    let world = World::build(2).await;
    // A real commit first: a circle's create leaves a welcome, not a commit row,
    // and the gate this test is about counts stored CONVERGENCE inputs.
    commit_relay_update(&world, world.admin(), "wss://gate.invalid").await;
    let session = world.admin().session().expect("session");
    let source = session
        .stored_convergence_input_for_test(world.group(), OpenMlsContentKind::Commit, 0)
        .await
        .expect("the admin holds the commit it just made");
    session
        .stage_convergence_input_for_test(&source, MessageState::Created, 0)
        .await
        .expect("stage it as a gating row");

    let error = world
        .admin()
        .manager()
        .expect("manager")
        .encrypt_location(
            world.group(),
            &world.admin().keys.public_key(),
            &LocationMessage::new(51.5, -0.12),
            60,
        )
        .await
        .expect_err("a gating row must stop the engine encrypting");
    assert!(
        classify_send(&error) == Verdict::SendDeferred,
        "a gated send is a named deferral, not an opaque failure"
    );
}

#[test]
fn the_two_epoch_state_refusals_stay_apart() {
    // Opposite handling: one clears on its own, the other never does, so
    // folding them together would put a caller in a retry loop that cannot
    // succeed.
    assert!(
        classify_session_send(&NostrError::EpochNotStable) == Verdict::EpochNotStable,
        "a group state that will settle on its own invites a retry"
    );
    assert!(
        classify_session_send(&NostrError::EpochUnrecoverable) == Verdict::EpochUnrecoverable,
        "and one that never will must not, or the caller loops forever"
    );
    assert!(
        classify_send(&CircleError::NotFound("<redacted>".into()))
            == Verdict::Defect(Cause::OpaqueSendError),
        "a send failure the product expresses only as prose stops here; Haven \
         forbids classifying error text, which interpolates remote-authored \
         strings"
    );
}

// ── The enumeration ─────────────────────────────────────────────────────────

/// Which of the two things the module header says an arm is.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Coverage {
    /// A case above reaches it through the rig.
    Produced,
    /// The header says why the rig cannot reach it at this pin.
    DeclaredUnreachable,
}

/// An exhaustive match, which is the point: a variant added to [`Verdict`] does
/// not COMPILE here until somebody has decided which of the two it is, so the
/// header's account of this file cannot go stale in silence.
const fn coverage(verdict: Verdict) -> Coverage {
    match verdict {
        Verdict::Expired
        | Verdict::PreAuth
        | Verdict::Applied
        | Verdict::CommitGap
        | Verdict::Duplicate
        | Verdict::PastEpochOrBranchLoss { .. }
        | Verdict::OwnEcho
        | Verdict::Routing
        | Verdict::PeelFailed
        | Verdict::Fork
        | Verdict::SendDeferred
        | Verdict::EpochNotStable
        | Verdict::EpochUnrecoverable
        | Verdict::Defect(_) => Coverage::Produced,
        Verdict::ForwardDistance | Verdict::SelfEvicted | Verdict::Quarantined => {
            Coverage::DeclaredUnreachable
        }
    }
}

#[test]
fn every_verdict_arm_is_produced_above_or_named_unreachable_in_the_header() {
    // The whole taxonomy, written out so the set this file leaves unproduced
    // and the set the header EXPLAINS are compared rather than assumed to
    // agree. The match above is what stops an arm being forgotten; this is
    // what stops one joining the unreachable side without its paragraph.
    const EVERY_ARM: [Verdict; 17] = [
        Verdict::Expired,
        Verdict::PreAuth,
        Verdict::Applied,
        Verdict::CommitGap,
        Verdict::ForwardDistance,
        Verdict::Duplicate,
        Verdict::PastEpochOrBranchLoss { branch_loss: true },
        Verdict::OwnEcho,
        Verdict::SelfEvicted,
        Verdict::Quarantined,
        Verdict::Routing,
        Verdict::PeelFailed,
        Verdict::Fork,
        Verdict::SendDeferred,
        Verdict::EpochNotStable,
        Verdict::EpochUnrecoverable,
        Verdict::Defect(Cause::EngineFailure),
    ];
    const NAMED_IN_THE_HEADER: [Verdict; 3] = [
        Verdict::ForwardDistance,
        Verdict::SelfEvicted,
        Verdict::Quarantined,
    ];

    let unreachable: Vec<Verdict> = EVERY_ARM
        .into_iter()
        .filter(|verdict| coverage(*verdict) == Coverage::DeclaredUnreachable)
        .collect();
    assert!(
        unreachable == NAMED_IN_THE_HEADER,
        "the arms with no case in this file must be exactly the ones the module \
         header names and explains, in its own order"
    );
    // Anti-vacuity: a `coverage` that answered `DeclaredUnreachable` for
    // everything would satisfy nothing above, and one that answered `Produced`
    // for everything would empty the list rather than disagree with it.
    assert!(
        EVERY_ARM.len() - unreachable.len() >= 10,
        "most of the taxonomy is reached by a case here, and a run where it is \
         not means the enumeration stopped describing this file"
    );
}

// ── Helpers ─────────────────────────────────────────────────────────────────

/// The engine's own "you are past this epoch" outcome, restated.
const fn stale_at_epoch() -> ScreenedIngest {
    ScreenedIngest::Ingested(IngestEffects {
        outcome: IngestOutcome::Stale {
            reason: StaleReason::AlreadyAtEpoch {
                current: EpochId(0),
                msg_epoch: EpochId(0),
            },
        },
        effects: SessionEffects {
            events: Vec::new(),
            publish: Vec::new(),
            queued: Vec::new(),
            pending_convergence: Vec::new(),
        },
    })
}

/// The engine's own fork error, with caller-chosen values so a test can plant
/// needles in it.
fn forked_epoch(group: &[u8], last_stable: u64, conflicting: u64) -> SessionError {
    SessionError::Engine(EngineError::ForkedEpoch {
        group_id: GroupId::new(group.to_vec()),
        last_stable: EpochId(last_stable),
        conflicting_epoch: EpochId(conflicting),
    })
}

/// Makes the second device an admin so both can commit from one epoch.
///
/// Published and resolved on a WITNESSED acknowledgement, never confirmed
/// outright: Rule 13 says "acked" means a relay's `OK` reached the publisher,
/// and a fixture that confirmed a commit nobody acked would be teaching the
/// thing this tree forbids.
async fn promote_to_admin(world: &World) {
    let handoff = world
        .admin()
        .manager()
        .expect("manager")
        .propose_admin_handoff(world.group(), &world.peer().keys.public_key())
        .await
        .expect("hand over the admin bit");
    let (verdict, _) = publish_and_resolve(
        world.admin(),
        &world.relays,
        handoff.pending,
        std::slice::from_ref(&handoff.commit_event),
    )
    .await
    .expect("the handoff publishes");
    assert!(
        verdict == PublishVerdict::Confirmed,
        "a commit is confirmed only on an acknowledgement that reached us"
    );
    world
        .peer()
        .manager()
        .expect("manager")
        .decrypt_location(&handoff.commit_event)
        .await
        .expect("the peer applies the handoff");
}

/// A relay-list commit staged by `device` and resolved on a witnessed `OK`.
async fn commit_relay_update(world: &World, device: &SimDevice, relay: &str) -> Event {
    let manager = device.manager().expect("manager");
    let staged = manager
        .update_circle_relays(world.group(), &[relay.to_string()])
        .await
        .expect("stage a commit");
    let (verdict, _) = publish_and_resolve(
        device,
        &world.relays,
        staged.pending,
        std::slice::from_ref(&staged.commit_event),
    )
    .await
    .expect("the commit publishes");
    assert!(
        verdict == PublishVerdict::Confirmed,
        "Rule 13: a commit is merged only after a relay acknowledged it"
    );
    staged.commit_event
}
