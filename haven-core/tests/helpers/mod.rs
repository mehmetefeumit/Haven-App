//! Reusable test helpers for the Dark Matter MLS integration tests.
//!
//! These helpers drive REAL MLS crypto over `SessionManager::new_unencrypted()`
//! storage. Each `SessionManager` instance simulates a separate device with its
//! own hydrated `AccountDeviceSession`. No mocking is needed.
//!
//! # Dark Matter port (DM-5a)
//!
//! The pre-migration helpers built on the deleted `MdkManager` (sync, interior
//! mutable). The engine is now `async` + `&mut`, so every group op is `async`.
//! The two-party fixture is two in-memory-ish `SessionManager`s: Bob mints a
//! kind-30443 `KeyPackage` event, Alice creates the group with it and confirms
//! the pending create (publish-before-apply), and Bob ingests the engine-produced
//! gift-wrapped (1059) welcome to join. `create_key_package` /
//! `merge_pending_commit` / `process_welcome` / `accept_welcome` /
//! `get_pending_welcomes` are gone; the flow below is their re-expression.
//!
//! Each integration test binary compiles this module independently and only uses
//! a subset of the helpers, so `dead_code` is silenced at the module level.

#![allow(dead_code)]

pub mod drive;
pub mod neg_wire;
pub mod removals;
pub mod stranded;
pub mod twin_key_packages;

use std::env;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Mutex, MutexGuard, Once, PoisonError};

use base64::engine::general_purpose::STANDARD as BASE64;
use base64::Engine as _;
use haven_core::nostr::mls::types::{
    GroupEvent, GroupId, LocationGroupConfig, PublishWork, SessionEffects, TransportMessage,
    WelcomeAcceptance,
};
use haven_core::nostr::mls::SessionManager;
use haven_core::nostr::NostrError;
use haven_core::relay::maintenance::build_kp_maintenance_events;
use nostr::prelude::ToBech32 as _;
use nostr::{Event, JsonUtil as _, Keys, PublicKey};

/// Atomic counter for unique test directory names.
static HELPER_COUNTER: AtomicU64 = AtomicU64::new(0);

/// Creates a unique temporary directory for test isolation.
pub fn unique_temp_dir(prefix: &str) -> PathBuf {
    let id = HELPER_COUNTER.fetch_add(1, Ordering::SeqCst);
    env::temp_dir().join(format!(
        "haven_g_test_{}_{}_{}",
        prefix,
        std::process::id(),
        id
    ))
}

/// Removes a temporary test directory. Ignores errors silently.
pub fn cleanup_dir(dir: &PathBuf) {
    let _ = std::fs::remove_dir_all(dir);
}

/// Mints a signed kind-30443 `KeyPackage` event for a device.
///
/// Uses the DM-2b maintenance builder — the real publish path — so a party's
/// `KeyPackage` is produced exactly as in production. The event `content` is
/// base64 of the TLS-serialized MLS `KeyPackage`; `SessionManager` parses it back
/// via [`SessionManager::key_package_from_event`].
pub async fn create_key_package_event(
    session: &SessionManager,
    keys: &Keys,
    relays: &[String],
) -> Event {
    build_kp_maintenance_events(session, keys, relays, None, None)
        .await
        .expect("build key package event")
        .event
}

/// Extracts the sole `FoundingGroupCreated { welcomes }` from create effects: a
/// founding create is canonical on return, with no pending ref to confirm.
fn take_group_created(effects: &SessionEffects) -> Vec<TransportMessage> {
    for work in &effects.publish {
        if let PublishWork::FoundingGroupCreated { welcomes } = work {
            return welcomes.clone();
        }
    }
    panic!("create_group produced no FoundingGroupCreated publish work");
}

/// The first gift-wrapped (1059) Welcome a founding create produced.
pub fn first_welcome_event(effects: &SessionEffects) -> Event {
    SessionManager::transport_message_to_event(&take_group_created(effects)[0])
        .expect("welcome to event")
}

/// Result of setting up a two-party MLS group.
pub struct TwoPartyGroup {
    pub alice: SessionManager,
    pub alice_keys: Keys,
    pub alice_dir: PathBuf,
    pub bob: SessionManager,
    pub bob_keys: Keys,
    pub bob_dir: PathBuf,
    pub group_id: GroupId,
    pub nostr_group_id: [u8; 32],
}

impl TwoPartyGroup {
    /// Cleans up all temporary directories.
    pub fn cleanup(&self) {
        cleanup_dir(&self.alice_dir);
        cleanup_dir(&self.bob_dir);
    }
}

/// Sets up a complete two-party MLS group (Alice creates, Bob joins).
///
/// 1. Creates separate `SessionManager`s for Alice and Bob.
/// 2. Bob mints a kind-30443 `KeyPackage` event.
/// 3. Alice creates the group with Bob's `KeyPackage` (canonical on return).
/// 4. Bob ingests the engine-produced gift-wrapped (1059) welcome to join.
pub async fn setup_two_party_group(prefix: &str) -> TwoPartyGroup {
    let relays = vec!["wss://relay.test.com".to_string()];

    let alice_dir = unique_temp_dir(&format!("{prefix}_alice"));
    let alice_keys = Keys::generate();
    let alice = SessionManager::new_unencrypted(&alice_dir, &alice_keys)
        .expect("should create alice session");

    let bob_dir = unique_temp_dir(&format!("{prefix}_bob"));
    let bob_keys = Keys::generate();
    let bob =
        SessionManager::new_unencrypted(&bob_dir, &bob_keys).expect("should create bob session");

    let bob_kp_event = create_key_package_event(&bob, &bob_keys, &relays).await;
    let bob_kp = SessionManager::key_package_from_event(&bob_kp_event).expect("parse bob kp");

    let config = LocationGroupConfig::new("Test Group")
        .with_description("Integration test group")
        .with_relay("wss://relay.test.com")
        .with_admin(alice_keys.public_key().to_hex());

    let created = alice
        .create_group(vec![bob_kp], config)
        .await
        .expect("should create group");
    let group_id = created.group_id.clone();
    let (nostr_group_id, _) = alice.group_routing(&group_id).await.expect("routing");

    let welcomes = take_group_created(&created.effects);

    // Bob joins by ingesting the (still-encrypted) gift-wrapped welcome.
    let welcome_event =
        SessionManager::transport_message_to_event(&welcomes[0]).expect("welcome to event");
    assert!(
        matches!(
            bob.accept_welcome(&welcome_event)
                .await
                .expect("bob accepts welcome"),
            WelcomeAcceptance::Ingested(_)
        ),
        "a fresh welcome is ingested"
    );

    TwoPartyGroup {
        alice,
        alice_keys,
        alice_dir,
        bob,
        bob_keys,
        bob_dir,
        group_id,
        nostr_group_id,
    }
}

/// A two-party group plus the gift-wrapped (1059) welcome Bob ingested to join.
///
/// Used by tests that need to inspect the welcome delivery itself. Under the DM
/// stack Haven only ever sees the outer 1059 gift wrap; the inner unsigned
/// kind-444 rumor is peeled inside the engine (the MIP-02 unsigned-444 invariant
/// is re-expressed as a black-box gate in `mls_e2e_security_tests`).
pub struct TwoPartyGroupWithWelcome {
    pub group: TwoPartyGroup,
    /// The kind-1059 gift wrap the engine produced for Bob during creation.
    pub bob_welcome_gift_wrap: Event,
}

impl TwoPartyGroupWithWelcome {
    pub fn cleanup(&self) {
        self.group.cleanup();
    }
}

/// Like [`setup_two_party_group`] but also returns the 1059 gift wrap Bob joined
/// through, so tests can assert protocol properties of the welcome delivery.
pub async fn setup_two_party_group_capturing_welcome(prefix: &str) -> TwoPartyGroupWithWelcome {
    let relays = vec!["wss://relay.test.com".to_string()];

    let alice_dir = unique_temp_dir(&format!("{prefix}_alice"));
    let alice_keys = Keys::generate();
    let alice = SessionManager::new_unencrypted(&alice_dir, &alice_keys)
        .expect("should create alice session");

    let bob_dir = unique_temp_dir(&format!("{prefix}_bob"));
    let bob_keys = Keys::generate();
    let bob =
        SessionManager::new_unencrypted(&bob_dir, &bob_keys).expect("should create bob session");

    let bob_kp_event = create_key_package_event(&bob, &bob_keys, &relays).await;
    let bob_kp = SessionManager::key_package_from_event(&bob_kp_event).expect("parse bob kp");

    let config = LocationGroupConfig::new("Test Group")
        .with_description("Integration test group")
        .with_relay("wss://relay.test.com")
        .with_admin(alice_keys.public_key().to_hex());

    let created = alice
        .create_group(vec![bob_kp], config)
        .await
        .expect("should create group");
    let group_id = created.group_id.clone();
    let (nostr_group_id, _) = alice.group_routing(&group_id).await.expect("routing");

    let welcomes = take_group_created(&created.effects);

    let welcome_event =
        SessionManager::transport_message_to_event(&welcomes[0]).expect("welcome to event");
    assert!(
        matches!(
            bob.accept_welcome(&welcome_event)
                .await
                .expect("bob accepts welcome"),
            WelcomeAcceptance::Ingested(_)
        ),
        "a fresh welcome is ingested"
    );

    TwoPartyGroupWithWelcome {
        group: TwoPartyGroup {
            alice,
            alice_keys,
            alice_dir,
            bob,
            bob_keys,
            bob_dir,
            group_id,
            nostr_group_id,
        },
        bob_welcome_gift_wrap: welcome_event,
    }
}

/// Drives `session`'s view of `group_id` forward to at least `target_epoch`.
///
/// DM re-expression of the deleted `self_update` ritual: the engine has no
/// `self_update`, so the epoch is advanced with real admin `update_relays`
/// (`UpdateAppComponents(nostr-routing.v1)`) commits — each is a genuine commit
/// that advances the epoch by one on confirm, WITHOUT changing membership. The
/// caller MUST be an admin of `group_id`. Alternates the relay set each round so
/// no commit is a no-op. Returns the epoch reached.
pub async fn advance_epoch_to_at_least(
    session: &SessionManager,
    group_id: &GroupId,
    target_epoch: u64,
    max_iters: usize,
) -> u64 {
    let mut epoch = session.epoch(group_id).await.expect("epoch");
    for i in 0..max_iters {
        if epoch >= target_epoch {
            break;
        }
        // Two distinct valid relay sets, alternated, so each update is a real
        // routing change (never a rejected no-op).
        let relays = if i % 2 == 0 {
            vec!["wss://relay-a.test.com".to_string()]
        } else {
            vec!["wss://relay-b.test.com".to_string()]
        };
        let effects = session
            .update_relays(group_id, relays)
            .await
            .expect("update_relays should advance the epoch");
        for work in &effects.publish {
            if let PublishWork::GroupEvolution { pending, .. } = work {
                session
                    .confirm_published(*pending)
                    .await
                    .expect("confirm relay-update commit");
            }
        }
        epoch = session.epoch(group_id).await.expect("epoch");
    }
    assert!(
        epoch >= target_epoch,
        "epoch did not advance to target within the safety cap (reached={epoch}, \
         target={target_epoch})"
    );
    epoch
}

/// Asserts a `NostrError` is a genuine MLS decryption/processing failure and NOT
/// a "group not found" error.
///
/// DM note: the engine redacts hex sequences in error strings (Rule 6/8) and its
/// decrypt-failure taxonomy differs from old MDK, so this checks the surviving
/// distinction — a `MdkError` that is not a group-not-found — rather than the old
/// substring set.
pub fn assert_is_decryption_failure(err: &NostrError, context: &str) {
    match err {
        NostrError::MdkError(msg) => {
            let lower = msg.to_lowercase();
            assert!(
                !lower.contains("group not found") && !lower.contains("unknown group"),
                "{context}: failure must be a decryption/processing error, not \
                 group-not-found (got MdkError: {msg:?})"
            );
        }
        NostrError::Decryption(_) | NostrError::InvalidEvent(_) => {}
        other => {
            panic!("{context}: expected a decryption/processing error, got {other:?}")
        }
    }
}

/// Asserts a published kind:445 `event` leaks NO raw MLS group ID — not in any
/// tag, not anywhere in the serialized JSON — while the privacy-preserving
/// `expected_nostr_group_id` IS present (Rule 4 / Security Rule #4).
pub fn assert_no_raw_mls_group_id_leak(
    event: &Event,
    raw_mls_group_id: &[u8],
    expected_nostr_group_id: &[u8],
) {
    let raw_mls_hex = hex::encode(raw_mls_group_id);
    let nostr_hex = hex::encode(expected_nostr_group_id);
    assert_ne!(
        nostr_hex, raw_mls_hex,
        "nostr_group_id must differ from the raw MLS group ID for the scan to be meaningful"
    );

    let json = event.as_json();
    assert!(
        !json.contains(&raw_mls_hex),
        "raw MLS group ID must NOT appear anywhere in the kind:445 event JSON"
    );
    for tag in event.tags.iter() {
        for part in tag.as_slice() {
            assert!(
                !part.contains(&raw_mls_hex),
                "raw MLS group ID must NOT appear in any tag of a kind:445 event"
            );
        }
    }
    assert!(
        json.contains(&nostr_hex),
        "the privacy-preserving nostr_group_id should appear in the kind:445 event"
    );
}

/// Convenience: fold a batch of engine [`GroupEvent`]s into the sender pubkeys of
/// any received location messages (hex), for delivery assertions.
pub fn location_senders(events: &[GroupEvent]) -> Vec<String> {
    events
        .iter()
        .filter_map(|e| match e {
            GroupEvent::MessageReceived { sender, .. } => Some(hex::encode(sender.as_slice())),
            _ => None,
        })
        .collect()
}

// ── In-process log capture (log anonymity, Security Rule 15) ────────────────
//
// Promoted out of `od4c_removal_deferral_e2e.rs`, where it began life as a
// warn-only, `haven_core`-only capture. It captures EVERY target and EVERY
// level now: the anonymity promise is about what lands in a log, and a line
// only a dependency emits still lands there. Callers narrow with
// [`haven_core_lines`] when the assertion is about what THIS crate wrote.

/// One captured log record.
#[derive(Clone, Debug)]
pub struct LogLine {
    /// The record's level, retained so a test can assert WHICH level said it.
    pub level: log::Level,
    /// The emitting target (`haven_core::relay::live_sync`, `nostr_relay_pool`, …).
    pub target: String,
    /// The rendered message.
    pub message: String,
}

/// Records every log line this process emits, for tests that assert what a
/// diagnostic does and does not say.
///
/// Process-wide rather than thread-local: these tests run on multi-thread
/// runtimes, where the future under test may resume on a different worker than
/// the one that started it.
pub struct LogSink;

/// Every line this binary has emitted since the logger went in. Append-only: a
/// capturing test remembers where its own window began, so two running side by
/// side each see a superset of their own lines and neither can empty the
/// other's buffer.
static CAPTURED: Mutex<Vec<LogLine>> = Mutex::new(Vec::new());

/// Poison-tolerant lock: a test that panics while the capture is armed must not
/// turn every later capture into a second panic that hides the first.
fn lock<T>(mutex: &'static Mutex<T>) -> MutexGuard<'static, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

impl log::Log for LogSink {
    fn enabled(&self, _metadata: &log::Metadata<'_>) -> bool {
        true
    }

    fn log(&self, record: &log::Record<'_>) {
        lock(&CAPTURED).push(LogLine {
            level: record.level(),
            target: record.target().to_owned(),
            message: record.args().to_string(),
        });
    }

    fn flush(&self) {}
}

/// Runs `body` and returns the log lines emitted during it — a superset of
/// `body`'s own if another test logs alongside it, which is why assertions on
/// the result look for a line rather than count them.
pub async fn capture_haven_log(body: impl std::future::Future<Output = ()>) -> Vec<LogLine> {
    static INSTALL: Once = Once::new();
    /// Whether OUR logger won the process-wide slot. `log` permits exactly one
    /// per process and reports the loser only through an `Err` that a `let _ =`
    /// throws away, so a second installer would leave this capture seeing
    /// NOTHING and every assertion below vacuously green. Record the verdict and
    /// fail on it instead.
    static OWNS_LOGGER: AtomicBool = AtomicBool::new(false);

    INSTALL.call_once(|| {
        OWNS_LOGGER.store(
            log::set_boxed_logger(Box::new(LogSink)).is_ok(),
            Ordering::SeqCst,
        );
        log::set_max_level(log::LevelFilter::Trace);
    });
    assert!(
        OWNS_LOGGER.load(Ordering::SeqCst),
        "another logger already owns this process, so this capture sees nothing \
         at all. `log` permits exactly one; whoever installed the other one has \
         to route through LogSink instead."
    );
    // The window starts at the current end of the buffer, so the lines returned
    // are the ones `body` emitted.
    let from = lock(&CAPTURED).len();
    body.await;
    lock(&CAPTURED)[from..].to_vec()
}

/// The subset of `lines` this crate itself emitted.
///
/// A dependency's lines are captured (they reach the same logcat / oslog) but
/// are not something a change in `haven-core` can fix, so an anonymity
/// assertion about Haven's own diagnostics narrows to these first.
#[must_use]
pub fn haven_core_lines(lines: &[LogLine]) -> Vec<LogLine> {
    lines
        .iter()
        .filter(|l| l.target.starts_with("haven_core"))
        .cloned()
        .collect()
}

/// Every encoding of `needle` a log line could plausibly carry: the value
/// itself, its case variants, its 8- and 16-character prefixes, and — when it
/// decodes as hex — its base64, `npub1…` and raw-byte-slice renderings.
///
/// Truncation is not redaction, so the prefixes are needles in their own right:
/// this is what makes `.get(..8)` a failure rather than a pass. Neither is
/// `{:?}`: an id is a `[u8; 32]` or a `GroupId` in this crate long before it is
/// a hex string, so the likeliest accidental leak prints `[225, 217, 232, …]`
/// and matches no hex needle at all.
fn needle_forms(needle: &str) -> Vec<String> {
    let mut forms = vec![
        needle.to_owned(),
        needle.to_lowercase(),
        needle.to_uppercase(),
    ];
    // Per-width, not gated on the whole needle being >= 16: a 10-15 char
    // subscription id or `d` slot still has an 8-char prefix worth truncating
    // to, and never got one under a single all-or-nothing length gate.
    for base in [needle.to_lowercase(), needle.to_uppercase()] {
        for width in [8, 16] {
            if base.chars().count() > width {
                forms.push(base.chars().take(width).collect());
            }
        }
    }
    if let Ok(bytes) = hex::decode(needle) {
        forms.push(BASE64.encode(&bytes));
        forms.push(format!("{bytes:?}"));
        if let Ok(pk) = PublicKey::from_slice(&bytes) {
            forms.extend(pk.to_bech32().ok());
        }
    }
    forms.sort_unstable();
    forms.dedup();
    forms
}

/// Asserts no line in `lines` carries any `needle`, in any of the encodings
/// [`needle_forms`] enumerates.
///
/// # Panics
///
/// Panics if `needles` is empty or holds a needle shorter than four characters
/// — either would make the assertion vacuous or match arbitrary prose.
pub fn assert_no_needles(lines: &[LogLine], needles: &[&str]) {
    assert!(
        !needles.is_empty(),
        "assert_no_needles with no needle asserts nothing"
    );
    for needle in needles {
        assert!(
            needle.chars().count() >= 4,
            "needle {needle:?} is too short to distinguish an identifier from prose"
        );
        for form in needle_forms(needle) {
            for line in lines {
                assert!(
                    !line.message.contains(&form),
                    "log line from {} carries {form:?} (an encoding of {needle:?}): {}",
                    line.target,
                    line.message
                );
            }
        }
    }
}

/// Asserts at least one captured line came from a target starting with
/// `target_prefix` — the anti-vacuity half of [`assert_no_needles`], which a
/// capture that recorded nothing at all would otherwise pass.
pub fn assert_some_line_from(lines: &[LogLine], target_prefix: &str) {
    assert!(
        lines.iter().any(|l| l.target.starts_with(target_prefix)),
        "no captured line came from {target_prefix:?}, so an absence assertion \
         over these {} line(s) proves nothing",
        lines.len()
    );
}
// ── A circle built through the public circle API ─────────────────────────────

/// One member of a [`CircleFixture`]: a circle manager over its own stores.
pub struct CircleMember {
    pub circle: std::sync::Arc<haven_core::circle::CircleManager>,
    pub keys: Keys,
    pub dir: tempfile::TempDir,
}

impl CircleMember {
    pub fn new() -> Self {
        let dir = tempfile::TempDir::new().expect("temp dir");
        let keys = Keys::generate();
        let circle = std::sync::Arc::new(
            haven_core::circle::CircleManager::new_unencrypted(dir.path(), &keys)
                .expect("circle manager"),
        );
        Self { circle, keys, dir }
    }

    pub fn session(&self) -> &SessionManager {
        self.circle.session()
    }

    pub fn pubkey_hex(&self) -> String {
        self.keys.public_key().to_hex()
    }

    /// Ends this member's process and starts another over the same stores.
    pub fn reopen(self) -> Self {
        let Self { circle, keys, dir } = self;
        drop(
            std::sync::Arc::try_unwrap(circle)
                .unwrap_or_else(|_| panic!("the member's manager is still shared")),
        );
        let circle = std::sync::Arc::new(
            haven_core::circle::CircleManager::new_unencrypted(dir.path(), &keys)
                .expect("the stores reopen"),
        );
        Self { circle, keys, dir }
    }
}

impl CircleMember {
    /// Ends this member's process, marks `group` unrecoverable in its MLS
    /// store as MDK's convergence persists a halt, and starts another over
    /// the same stores, which re-seeds the halt at the open.
    pub fn halted(self, group: &GroupId) -> Self {
        let Self { circle, keys, dir } = self;
        drop(
            std::sync::Arc::try_unwrap(circle)
                .unwrap_or_else(|_| panic!("the member's manager is still shared")),
        );
        haven_core::nostr::mls::storage::set_group_unrecoverable_for_test(
            &haven_core::nostr::mls::StorageConfig::new(dir.path()).database_path(),
            &haven_core::nostr::mls::StorageConfig::test_sqlcipher_key().expect("test key"),
            group,
            true,
        )
        .expect("the halt is persisted");
        let circle = std::sync::Arc::new(
            haven_core::circle::CircleManager::new_unencrypted(dir.path(), &keys)
                .expect("the stores reopen"),
        );
        Self { circle, keys, dir }
    }
}

/// A circle of real co-members, the first of whom created it and is its admin.
pub struct CircleFixture {
    pub members: Vec<CircleMember>,
    pub group: GroupId,
}

impl CircleFixture {
    pub fn admin(&self) -> &CircleMember {
        &self.members[0]
    }
}

/// Builds a circle of `size` members whose routing component names `relays`.
/// Nothing is dialled: every member joins from its Welcome in process.
pub async fn setup_circle(size: usize, relays: &[&str]) -> CircleFixture {
    setup_circle_of((0..size).map(|_| CircleMember::new()).collect(), relays).await
}

/// As [`setup_circle`], of `members` as given: the first creates the circle.
pub async fn setup_circle_of(members: Vec<CircleMember>, relays: &[&str]) -> CircleFixture {
    let invitees: Vec<&CircleMember> = members[1..].iter().collect();
    let group = found_circle(&members[0], &invitees, relays).await;
    CircleFixture { members, group }
}

/// A circle `founder` creates with `invitees`, each joining from its Welcome
/// in process. A member may found, or be invited to, more than one. The
/// create is the driven one the app makes, its founding Welcomes sent from
/// their records and acknowledged at once, so none is left owed.
pub async fn found_circle(
    founder: &CircleMember,
    invitees: &[&CircleMember],
    relays: &[&str],
) -> GroupId {
    let relays: Vec<String> = relays.iter().map(ToString::to_string).collect();
    let inbox = vec!["wss://member-inbox.example.com".to_string()];
    let mut invited = Vec::new();
    for member in invitees {
        invited.push(haven_core::circle::MemberKeyPackage {
            key_package_event: create_key_package_event(member.session(), &member.keys, &inbox)
                .await,
            inbox_relays: inbox.clone(),
            nip65_relays: Vec::new(),
        });
    }
    let transport = haven_core::relay::fanout::scripted::ScriptedFanout::default();
    let publisher = drive::Recorder::acking(true);
    let clock = drive::ManualClock::at(0);
    let created = haven_core::relay::fanout::Publishing {
        fanout: &transport,
        publisher: &publisher,
        clock: &*clock,
        deadline_ms: None,
        mode: &haven_core::relay::fanout::DriveMode::Full,
    }
    .create_circle(
        &founder.circle,
        &founder.keys,
        invited,
        &haven_core::circle::CircleConfig::new("Fixture").with_relays(relays.clone()),
    )
    .await
    .expect("the circle is created");
    assert_eq!(
        created.welcomes_sent,
        invitees.len(),
        "a founding Welcome was left owed"
    );
    let handed = publisher.handed();
    for member in invitees {
        let (welcome, _) = handed
            .iter()
            .find(|(event, _)| {
                event.tags.iter().any(|tag| {
                    tag.as_slice().first().is_some_and(|name| name == "p")
                        && tag.as_slice().get(1) == Some(&member.pubkey_hex())
                })
            })
            .expect("a welcome for each member");
        member
            .circle
            .process_gift_wrapped_invitation(&member.keys, welcome)
            .await
            .expect("the invitation is held");
        member
            .circle
            .accept_invitation(&welcome.id)
            .await
            .expect("the member joins");
    }
    created.circle.mls_group_id
}

/// A store of notes that refuses to write on demand.
#[derive(Default)]
pub struct BalkyNotes {
    /// While set, what stands cannot be read: [`Self::peek`] answers as a
    /// store that failed does, with nothing.
    pub unreadable: std::sync::atomic::AtomicBool,
    pub refusing: std::sync::atomic::AtomicBool,
    pub untold: std::sync::Mutex<Vec<haven_core::nostr::mls::ChangeNote>>,
    pub removal_targets: std::sync::Mutex<Vec<haven_core::nostr::mls::types::MemberId>>,
}

impl haven_core::nostr::mls::KeptInput for BalkyNotes {}

impl haven_core::nostr::mls::CommitNotes for BalkyNotes {
    fn set_removes_nobody(&self, _: &GroupId, _: bool) -> bool {
        true
    }

    fn removes_nobody(&self, _: &GroupId) -> bool {
        false
    }

    fn mark_repair(&self, _: &GroupId, _: bool) -> bool {
        !self.refusing.load(Ordering::SeqCst)
    }

    fn repair_marked(&self, _: &GroupId) -> Option<bool> {
        (!self.unreadable.load(Ordering::SeqCst)).then_some(false)
    }

    fn keep_dropped_removal(
        &self,
        _: &GroupId,
        _: &haven_core::nostr::mls::types::MessageId,
    ) -> bool {
        !self.refusing.load(Ordering::SeqCst)
    }

    fn take_dropped_removal(
        &self,
        _: &GroupId,
        _: &haven_core::nostr::mls::types::MessageId,
    ) -> Option<bool> {
        (!self.unreadable.load(Ordering::SeqCst)).then_some(false)
    }

    fn note(&self, _: &GroupId, note: haven_core::nostr::mls::ChangeNote) -> bool {
        if self.refusing.load(Ordering::SeqCst) {
            return false;
        }
        self.untold.lock().expect("notes").push(note);
        true
    }

    fn note_all(&self, groups: &[&GroupId], note: haven_core::nostr::mls::ChangeNote) -> bool {
        if self.refusing.load(Ordering::SeqCst) {
            return false;
        }
        self.untold
            .lock()
            .expect("notes")
            .extend(groups.iter().map(|_| note));
        true
    }

    fn peek(&self, _: &GroupId) -> Vec<haven_core::nostr::mls::ChangeNote> {
        if self.unreadable.load(Ordering::SeqCst) {
            return Vec::new();
        }
        self.untold.lock().expect("notes").clone()
    }

    fn stands(&self, group_id: &GroupId, note: haven_core::nostr::mls::ChangeNote) -> Option<bool> {
        (!self.unreadable.load(Ordering::SeqCst)).then(|| self.peek(group_id).contains(&note))
    }

    fn notice(&self, group_id: &GroupId) -> haven_core::nostr::mls::ChangeNotice {
        let readable = !self.unreadable.load(Ordering::SeqCst);
        let bits = self
            .peek(group_id)
            .iter()
            .fold(0, |bits, note| bits | note.bit());
        haven_core::nostr::mls::ChangeNotice::read(bits, readable.then_some(0))
    }

    fn acknowledge(
        &self,
        group_id: &GroupId,
        notice: &haven_core::nostr::mls::ChangeNotice,
    ) -> bool {
        if notice.seen().is_none() {
            return false;
        }
        for note in haven_core::nostr::mls::ChangeNote::of(notice.dropped_bits()) {
            self.clear(group_id, note);
        }
        true
    }

    fn clear(&self, _: &GroupId, note: haven_core::nostr::mls::ChangeNote) {
        self.untold
            .lock()
            .expect("notes")
            .retain(|told| *told != note);
        if note == haven_core::nostr::mls::ChangeNote::QueuedRemovalDropped {
            self.removal_targets.lock().expect("targets").clear();
        }
    }

    fn keep_removal_targets(
        &self,
        _: &GroupId,
        targets: &[haven_core::nostr::mls::types::MemberId],
        _set_aside_epoch: u64,
        _asks: u32,
    ) -> bool {
        if self.refusing.load(Ordering::SeqCst) {
            return false;
        }
        self.removal_targets
            .lock()
            .expect("targets")
            .extend_from_slice(targets);
        true
    }

    fn leaving(&self, _: &GroupId) -> Option<bool> {
        (!self.unreadable.load(Ordering::SeqCst)).then_some(false)
    }

    fn circle_stands(&self, _: &GroupId) -> Option<bool> {
        (!self.unreadable.load(Ordering::SeqCst)).then_some(true)
    }

    /// This store keeps no route.
    fn keep_welcome_route(&self, _: &GroupId, _: &str, _: &[String], _: Option<u64>) -> bool {
        false
    }

    fn welcome_route(
        &self,
        _: &GroupId,
        _: &str,
    ) -> Result<Option<haven_core::nostr::mls::KeptWelcomeRoute>, haven_core::nostr::mls::RouteUnread>
    {
        Ok(None)
    }

    fn forget_welcome_route(&self, _: &GroupId, _: &str) {}

    fn removal_targets(&self, _: &GroupId) -> Option<Vec<haven_core::nostr::mls::types::MemberId>> {
        (!self.unreadable.load(Ordering::SeqCst))
            .then(|| self.removal_targets.lock().expect("targets").clone())
    }

    /// Every target counts as asked for as often as it may be: this store
    /// keeps no count.
    fn kept_removals(&self, group_id: &GroupId) -> Option<Vec<haven_core::nostr::mls::KeptTarget>> {
        self.removal_targets(group_id).map(|targets| {
            targets
                .into_iter()
                .map(|member| haven_core::nostr::mls::KeptTarget {
                    member,
                    set_aside_epoch: 0,
                    asks: haven_core::nostr::mls::MAX_REQUEUE_ATTEMPTS,
                })
                .collect()
        })
    }

    fn take_out_removal_targets(
        &self,
        _: &GroupId,
        members: &[haven_core::nostr::mls::types::MemberId],
        _epoch: u64,
        _by: Option<&haven_core::nostr::mls::types::MessageId>,
    ) -> bool {
        let mut targets = self.removal_targets.lock().expect("targets");
        let before = targets.len();
        targets.retain(|target| !members.contains(target));
        targets.len() != before
    }

    /// This store forgets who was taken out: nothing comes back.
    fn bring_back_removal_targets(
        &self,
        _: &GroupId,
        _: &haven_core::nostr::mls::types::MessageId,
        _: u32,
    ) -> bool {
        false
    }

    /// Every target of this store counts as asked for as often as it may be.
    fn spend_removal_asks(&self, _: &GroupId, _: u32) -> bool {
        true
    }

    fn spend_target_asks(
        &self,
        _: &GroupId,
        _: &[haven_core::nostr::mls::types::MemberId],
        _: u32,
    ) -> bool {
        true
    }

    fn taken_out_by(
        &self,
        _: &GroupId,
        _: &haven_core::nostr::mls::types::MemberId,
    ) -> Option<haven_core::nostr::mls::types::MessageId> {
        None
    }

    fn forget_gone_removal_targets(&self, _: &GroupId, _before_epoch: u64) {}

    fn count_removal_asks(
        &self,
        _: &GroupId,
        _: &[haven_core::nostr::mls::types::MemberId],
    ) -> Option<Vec<(haven_core::nostr::mls::types::MemberId, u32)>> {
        None
    }

    fn refund_removal_asks(
        &self,
        _: &GroupId,
        _: &[(haven_core::nostr::mls::types::MemberId, u32)],
    ) {
    }

    fn settle_removal(&self, _: &GroupId) {
        if !self.refusing.load(Ordering::SeqCst) {
            self.untold
                .lock()
                .expect("notes")
                .retain(|told| *told != haven_core::nostr::mls::ChangeNote::QueuedRemovalDropped);
        }
    }

    fn restage_wait(&self, _: &GroupId) -> Option<haven_core::nostr::mls::RestageWait> {
        None
    }

    fn set_restage_wait(&self, _: &GroupId, _: Option<haven_core::nostr::mls::RestageWait>) {}
}

// ── Self-tests for the log-anonymity capture helpers above ──────────────────
//
// `LogSink`/`capture_haven_log` back every `assert_no_needles` call across the
// `log_anonymity_*` suite; a defect here would silently weaken all of them.
// These exercise the pure assertion logic directly over hand-built `LogLine`s
// (no real logger install), so they are safe to compile into every binary
// that pulls in `mod helpers;` without racing anyone's `capture_haven_log`
// call for the process-wide `log` slot — see `log_anonymity_live_sync.rs` for
// the one probe (`OWNS_LOGGER` under a competing logger) that genuinely needs
// an isolated process and lives there instead.
#[cfg(test)]
mod log_capture_self_tests {
    use base64::Engine as _;
    use nostr::prelude::ToBech32 as _;

    use super::{assert_no_needles, assert_some_line_from, LogLine};

    fn line(target: &str, message: &str) -> LogLine {
        LogLine {
            level: log::Level::Debug,
            target: target.to_owned(),
            message: message.to_owned(),
        }
    }

    const NEEDLE_HEX: &str = "e1d9e8e1e35d8a5a1a1dbe6d3e0aa1b9f5f0f2a3b4c5d6e7f8091a2b3c4d5e6f";

    #[test]
    #[should_panic(expected = "carries")]
    fn catches_the_literal_value() {
        assert_no_needles(
            &[line("haven_core::x", &format!("leaked {NEEDLE_HEX}"))],
            &[NEEDLE_HEX],
        );
    }

    #[test]
    #[should_panic(expected = "carries")]
    fn catches_an_upper_case_recasing() {
        assert_no_needles(
            &[line(
                "haven_core::x",
                &format!("leaked {}", NEEDLE_HEX.to_uppercase()),
            )],
            &[NEEDLE_HEX],
        );
    }

    #[test]
    #[should_panic(expected = "carries")]
    fn catches_an_eight_char_prefix() {
        assert_no_needles(
            &[line("haven_core::x", &format!("evt={}", &NEEDLE_HEX[..8]))],
            &[NEEDLE_HEX],
        );
    }

    #[test]
    #[should_panic(expected = "carries")]
    fn catches_a_sixteen_char_prefix() {
        assert_no_needles(
            &[line(
                "haven_core::x",
                &format!("group={}", &NEEDLE_HEX[..16]),
            )],
            &[NEEDLE_HEX],
        );
    }

    #[test]
    #[should_panic(expected = "carries")]
    fn catches_a_base64_encoding_of_a_hex_needle() {
        // Computed with the SAME encoder `needle_forms` uses internally, not
        // hand-derived, so this proves the conversion is wired in rather than
        // asserting a string this test happened to get right by hand.
        let bytes = hex::decode(NEEDLE_HEX).expect("test vector is hex");
        let leaked = super::BASE64.encode(&bytes);
        assert_no_needles(
            &[line("haven_core::x", &format!("leaked: {leaked}"))],
            &[NEEDLE_HEX],
        );
    }

    #[test]
    #[should_panic(expected = "carries")]
    fn catches_an_npub_encoding_of_a_hex_needle() {
        let npub = super::PublicKey::parse(NEEDLE_HEX)
            .expect("test vector is a valid pubkey")
            .to_bech32()
            .expect("encodes as npub");
        assert_no_needles(
            &[line("haven_core::x", &format!("peer {npub} connected"))],
            &[NEEDLE_HEX],
        );
    }

    #[test]
    #[should_panic(expected = "carries")]
    fn catches_a_debug_byte_slice_rendering_of_a_hex_needle() {
        // The shape `{:?}` on a `[u8; 32]`, a `GroupId` or a `Vec<u8>` prints —
        // which is what a group id, an event id and a key all are in this crate
        // before anyone hex-encodes them. Built with the same `{:?}` the leak
        // would use rather than hand-written, so it proves the form is wired in.
        let bytes = hex::decode(NEEDLE_HEX).expect("test vector is hex");
        assert_no_needles(
            &[line("haven_core::x", &format!("group {bytes:?} advanced"))],
            &[NEEDLE_HEX],
        );
    }

    #[test]
    fn passes_when_the_needle_never_appears() {
        // Must not panic — the anti-vacuity half of these tests: a helper that
        // flagged everything would "catch" every case above for the wrong
        // reason.
        assert_no_needles(
            &[line("haven_core::x", "nothing sensitive here")],
            &[NEEDLE_HEX],
        );
    }

    #[test]
    #[should_panic(expected = "asserts nothing")]
    fn rejects_an_empty_needle_list() {
        assert_no_needles(&[line("haven_core::x", "anything")], &[]);
    }

    #[test]
    #[should_panic(expected = "too short")]
    fn rejects_a_needle_shorter_than_four_chars() {
        assert_no_needles(&[line("haven_core::x", "abc")], &["abc"]);
    }

    #[test]
    #[should_panic(expected = "no captured line came from")]
    fn assert_some_line_from_fails_on_an_empty_capture() {
        assert_some_line_from(&[], "haven_core::relay");
    }

    #[test]
    fn assert_some_line_from_passes_when_a_matching_target_exists() {
        assert_some_line_from(
            &[line("haven_core::relay::live_sync", "ok")],
            "haven_core::relay",
        );
    }
}
