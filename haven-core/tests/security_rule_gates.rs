//! Security-rule gates that observe the wire, not the type system (Workstream D).
//!
//! Rules whose coverage was structural where it needed to be observational:
//!
//! * **Rule 11 — kind-445 nonce.** The label half of Rule 11 is a repo guard
//!   (`check_no_exporter_label_override.sh`); the nonce half had nothing. Here
//!   the nonces of a same-epoch burst are read back off the built events —
//!   across a session restart, because a nonce source can be distinct within one
//!   process and identical across launches. The same sample carries Rule 2 (a
//!   fresh ephemeral author key per message).
//! * **Rule 3 — kind-444 welcome stays UNSIGNED.** Asserted on the RAW decrypted
//!   rumor JSON: `nostr::UnsignedEvent` has no `sig` field at all, so peeling
//!   into one silently drops a stray signature and says nothing about the bytes
//!   that were wrapped.
//! * **Rule 5 — exporter retention.** The negative edge (an epoch-N ciphertext
//!   is dead at N+6) is
//!   `mls_e2e_security_tests::p3b_old_epoch_ciphertext_is_undecryptable_after_retention_window`.
//!   Here are the positive edge (it still decrypts at N+5) and the two constants
//!   that place that edge, which until now lived only in comments.
//! * **Rule 12 — the live plane's intake cap.** The catch-up sweep's half of
//!   Rule 12 (the paged FETCH bound) is `catchup_sweep_e2e`. The LIVE plane's
//!   half is the bounded receive→ingest queue, and it had nothing: not the cap's
//!   existence, and — the direction the rule is written about — not what
//!   overflowing it costs. The receive path can lose a delivery in one further
//!   way, above that queue: the pool's notification broadcast can overrun, and
//!   what it then reports is a bare count, with no event left to hold a cursor
//!   at. Both losses are gated here, on the cursor.
//! * **Rule 13 — publish-before-apply, read as a ROUTING rule.** A location may
//!   take the one-shot bounded fan-out because the next tick supersedes it; a
//!   commit may not, because a commit that is neither confirmed nor rolled back
//!   forks the group. Nothing in the type system stops the two paths from
//!   meeting, so the separation is asserted on the source.
//!
//! # Known limits of the source gates
//!
//! The gates that read source read TEXT, in the three trees a product build
//! compiles (`scanned_sources`). Three spellings pass them that should not,
//! each left because closing it means parsing Rust rather than matching it;
//! a change that uses one is a change to these gates:
//!
//! * a provided method added INSIDE `trait FanoutSend { … }` that calls a
//!   driver entry: it is not a `pub` line, so the surface pin of
//!   `relay/fanout.rs` does not list it, and its new name is in no ban list;
//! * a staging entry called through a function pointer
//!   (`let f = SessionManager::remove_members; f(…)`): callers are counted by
//!   the `.name(` and `::name(` spellings alone;
//! * `use Disposition::*; Stage { now_ms }`: construction sites of a
//!   disposition are located by the `Disposition::Stage {` spelling alone.
//!
//! The reader itself fails loudly rather than hide code: a test module it
//! cannot see the end of stops the gate that asked (`production_text`).

mod cargo_graph;
mod helpers;

use std::collections::HashSet;
use std::sync::atomic::AtomicBool;
use std::sync::Arc;

use base64::engine::general_purpose::STANDARD as BASE64;
use base64::Engine as _;
use haven_core::circle::CircleManager;
use haven_core::location::LocationMessage;
use haven_core::nostr::mls::types::{GroupId, LocationMessageResult, PublishWork};
use haven_core::nostr::mls::{
    app_message_past_epoch_limit, SessionManager, DEFAULT_MAX_PAST_EPOCHS,
};
use haven_core::relay::live_sync::config::WORKER_QUEUE_CAP;
use haven_core::relay::live_sync::supervisor::{intake_queue, run_receiver, RawSignal};
use haven_core::relay::live_sync::{group_cursor_stream, EngineProcessor, EventBus};
use nostr::nips::nip44;
use nostr::{
    Alphabet, Event, EventBuilder, JsonUtil as _, Keys, Kind, PublicKey, RelayUrl, SingleLetterTag,
    SubscriptionId, Tag, TagKind, Timestamp,
};
use nostr_sdk::RelayPoolNotification;
use serde_json::Value;
use tokio::sync::mpsc::error::TrySendError;
use tokio::sync::{broadcast, mpsc, watch};

use helpers::{
    cleanup_dir, setup_two_party_group, setup_two_party_group_capturing_welcome, unique_temp_dir,
    TwoPartyGroup,
};

/// A kind-445 `content` is `base64(nonce || ciphertext)` with a 12-byte
/// ChaCha20-Poly1305 nonce (MIP-04 / `transport-nostr-peeler`); the 16-byte AEAD
/// tag puts a floor of 28 decoded bytes under any well-formed event.
const NONCE_LEN: usize = 12;
const MIN_445_CONTENT_LEN: usize = NONCE_LEN + 16;

/// Enough sends per burst that a repeat would show, few enough that they all
/// stay inside ONE epoch — the fixed `group_event_key` Rule 11 forbids a repeat
/// under. Two bursts are taken, either side of a session restart.
const NONCE_SAMPLE: u8 = 32;

// `send_445` / `decrypt_445_content` / `advance_both` are local copies of the
// sibling `mls_e2e_security_tests` harness: each integration test is its own
// crate, so its private items cannot be shared, and `helpers` is compiled into
// every test binary in the directory, none of which need these.

/// Encrypts an inner location `content` and returns the publishable 445.
async fn send_445(sender: &SessionManager, gid: &GroupId, content: &str) -> Event {
    let effects = sender
        .send_location(gid, content.to_string())
        .await
        .expect("send location");
    let msg = effects
        .publish
        .iter()
        .find_map(|w| match w {
            PublishWork::ApplicationMessage { msg, .. } => Some(msg.clone()),
            _ => None,
        })
        .expect("application message publish work");
    SessionManager::transport_message_to_event(&msg).expect("transport → event")
}

/// The inner location content a receiver recovers from a 445, or `None`.
///
/// A deliberate near-twin of `mls_e2e_security_tests`'s helper of the same name,
/// NOT a stale copy, and the difference is the point: that file asserts five
/// NEGATIVE outcomes (`is_none()` — cross-group, aged-out epoch, tampered,
/// malformed), so an ingest error there must surface as `None` or the gate it
/// guards cannot be expressed. Every 445 here is one this test just built and
/// sent, so an ingest error is a broken harness rather than a result, and
/// swallowing it into `None` would let the nonce sample silently shrink.
/// Sharing one helper would force one of the two files to lie about what a
/// failure means.
async fn decrypt_445_content(receiver: &SessionManager, event: &Event) -> Option<String> {
    let ingest = receiver
        .process_event(event)
        .await
        .expect("ingest a 445")
        .ingested()
        // Every event here is a well-formed envelope: a pre-auth rejection would
        // make the gate below pass or fail for a reason that has nothing to do
        // with retention.
        .expect("a well-formed 445 must reach the engine, not Haven's pre-auth screen");
    let mut results: Vec<LocationMessageResult> = Vec::new();
    results.extend(
        ingest
            .effects
            .events
            .iter()
            .filter_map(SessionManager::location_result_from_event),
    );
    for gid in &ingest.effects.pending_convergence {
        if let Ok(more) = receiver.advance_convergence(gid).await {
            results.extend(
                more.events
                    .iter()
                    .filter_map(SessionManager::location_result_from_event),
            );
        }
    }
    results.into_iter().find_map(|r| match r {
        LocationMessageResult::Location { content, .. } => Some(content),
        _ => None,
    })
}

/// Advances BOTH parties by `count` admin routing commits, so the receiver's tip
/// — the epoch retention is measured against — really moves.
async fn advance_both(g: &TwoPartyGroup, count: u64) {
    for i in 0..count {
        let effects = g
            .alice
            .update_relays(&g.group_id, vec![format!("wss://epoch-{i}.example.com")])
            .await
            .expect("alice routing commit");
        let (commit, pending) = effects
            .publish
            .iter()
            .find_map(|w| match w {
                PublishWork::GroupEvolution { msg, pending, .. } => Some((msg.clone(), *pending)),
                _ => None,
            })
            .expect("group evolution");
        g.alice
            .confirm_published(pending)
            .await
            .expect("alice confirms");
        let commit_event =
            SessionManager::transport_message_to_event(&commit).expect("commit → event");
        // Served through its convergence window, as a receive plane does.
        g.bob
            .process_event_settled_for_test(&commit_event)
            .await
            .expect("bob ingests and converges the commit")
            .ingested()
            // A well-formed commit passes the only pre-auth screen left (the
            // structural one), and it carries no `expiration` for the relay
            // pool to judge (group history must outlive any TTL).
            .expect("a commit must reach the engine, not Haven's pre-auth screen");
    }
}

/// Whether the sample arrives in strictly increasing or strictly decreasing
/// order. Arrays compare lexicographically, i.e. as big-endian integers.
fn is_monotonic(nonces: &[[u8; NONCE_LEN]]) -> bool {
    nonces.windows(2).all(|w| w[0] < w[1]) || nonces.windows(2).all(|w| w[0] > w[1])
}

/// Sends [`NONCE_SAMPLE`] location 445s and appends each one's nonce to
/// `nonces`, checking Rule 2's fresh-ephemeral-author property on the same
/// sample (`authors` accumulates across bursts, so a restart may not reuse one
/// either).
async fn collect_nonce_burst(
    sender: &SessionManager,
    gid: &GroupId,
    identity: PublicKey,
    nonces: &mut Vec<[u8; NONCE_LEN]>,
    authors: &mut HashSet<String>,
) {
    for i in 0..NONCE_SAMPLE {
        let loc = LocationMessage::new(f64::from(i), f64::from(i))
            .to_string()
            .expect("serialize location");
        let event = send_445(sender, gid, &loc).await;

        // Rule 2 rides on the same sample: one fresh ephemeral author per 445.
        assert!(
            authors.insert(event.pubkey.to_hex()),
            "every kind-445 must carry a FRESH ephemeral author key (Rule 2)"
        );
        assert_ne!(
            event.pubkey, identity,
            "the Nostr identity key must never author a kind-445 (Rule 2)"
        );

        let decoded = BASE64
            .decode(&event.content)
            .expect("445 content is base64(nonce || ciphertext)");
        assert!(
            decoded.len() >= MIN_445_CONTENT_LEN,
            "a kind-445 must carry at least a {NONCE_LEN}-byte nonce and a 16-byte AEAD tag, \
             got {} bytes",
            decoded.len()
        );
        nonces.push(
            decoded[..NONCE_LEN]
                .try_into()
                .expect("the leading nonce bytes"),
        );
    }
}

// ============================================================================
// Rule 11 — kind-445 nonce is CSPRNG-random and never repeats under one epoch
// ============================================================================

#[tokio::test]
async fn rule11_kind_445_nonces_never_repeat_under_one_epoch_key() {
    let g = setup_two_party_group("rule11_nonce").await;
    let start_epoch = g.alice.epoch(&g.group_id).await.expect("epoch");
    let identity = g.alice_keys.public_key();

    let mut nonces: Vec<[u8; NONCE_LEN]> = Vec::new();
    let mut ephemeral_authors: HashSet<String> = HashSet::new();
    collect_nonce_burst(
        &g.alice,
        &g.group_id,
        identity,
        &mut nonces,
        &mut ephemeral_authors,
    )
    .await;

    assert_eq!(
        g.alice.epoch(&g.group_id).await.expect("epoch"),
        start_epoch,
        "the whole sample must sit in ONE epoch, or two nonces could repeat under \
         DIFFERENT group_event_keys and the gate below would prove nothing"
    );

    // The sample crosses a PROCESS-lifetime boundary, because the dangerous
    // mutation survives every within-run check: a nonce source that is distinct
    // per run but deterministic across restarts — a `SmallRng::seed_from_u64`
    // with a fixed seed, or a counter behind a per-process-random prefix —
    // repeats its whole sequence on the next launch, and the app restarting
    // does NOT advance the epoch, so that repeat lands under the SAME
    // group_event_key. Rule 11's total break, invisible to a one-session gate.
    let TwoPartyGroup {
        alice,
        alice_keys,
        alice_dir,
        bob_dir,
        group_id,
        ..
    } = g;
    // The Rule-14 LiveSessionGuard releases here, so the reopen below is a
    // legitimate second session over the same on-disk group, not a Rule-14
    // violation.
    drop(alice);
    let alice = SessionManager::new_unencrypted(&alice_dir, &alice_keys)
        .expect("reopen alice's session on the same MLS database");
    collect_nonce_burst(
        &alice,
        &group_id,
        identity,
        &mut nonces,
        &mut ephemeral_authors,
    )
    .await;

    assert_eq!(
        alice.epoch(&group_id).await.expect("epoch"),
        start_epoch,
        "restarting the app must not advance the epoch — that is exactly why a \
         nonce source that repeats across restarts repeats under ONE key"
    );

    // The UNION of both bursts: a nonce drawn before the restart must not come
    // back after it.
    let distinct: HashSet<[u8; NONCE_LEN]> = nonces.iter().copied().collect();
    assert_eq!(
        distinct.len(),
        nonces.len(),
        "a kind-445 nonce MUST NEVER repeat under a fixed epoch group_event_key (Rule 11)"
    );

    // A fixed-prefix + counter nonce is distinct too, and it leaks the send count
    // and collides across a re-derived prefix. Reject any byte position that never
    // varies: for a CSPRNG that costs p ≈ 256^-63 of a false failure.
    for pos in 0..NONCE_LEN {
        assert!(
            nonces.iter().any(|n| n[pos] != nonces[0][pos]),
            "nonce byte {pos} is identical across all {} sends — that is a fixed prefix, \
             not a CSPRNG draw (Rule 11)",
            nonces.len()
        );
    }
    // ...and reject the counter itself: 64 CSPRNG draws landing in order is 1/64!.
    assert!(
        !is_monotonic(&nonces),
        "the nonces arrive in monotonic order — that is a counter, not a CSPRNG draw (Rule 11)"
    );

    // Deliberately NOT asserted: byte-level uniformity. At this sample size no
    // distribution test can distinguish a CSPRNG from a biased source, so it would
    // buy flakiness and no power.
    cleanup_dir(&alice_dir);
    cleanup_dir(&bob_dir);
}

// ============================================================================
// Rule 3 — the kind-444 welcome rumor reaches the recipient UNSIGNED
// ============================================================================

#[tokio::test]
async fn rule3_welcome_rumor_json_carries_no_signature() {
    let g = setup_two_party_group_capturing_welcome("rule3_unsigned").await;
    let bob_secret = g.group.bob_keys.secret_key();
    let wrap = &g.bob_welcome_gift_wrap;
    assert_eq!(wrap.kind, Kind::GiftWrap, "the welcome ships in a 1059");

    // Peeled by hand rather than through `unwrap_welcome`: that returns an
    // `UnsignedEvent`, whose serde shape has no `sig` field, so it would drop a
    // signature the sender really put on the wire and report Rule 3 as held.
    let seal_json = nip44::decrypt(bob_secret, &wrap.pubkey, &wrap.content)
        .expect("decrypt the 1059 outer layer");
    let seal = Event::from_json(&seal_json).expect("the outer layer holds a seal event");
    assert_eq!(seal.kind, Kind::Seal, "layer 2 is the kind-13 seal");
    seal.verify()
        .expect("the SEAL is signed — Rule 3 constrains the rumor inside it, not this layer");

    let rumor_json =
        nip44::decrypt(bob_secret, &seal.pubkey, &seal.content).expect("decrypt the seal");
    let rumor: Value = serde_json::from_str(&rumor_json).expect("the rumor is JSON");
    let fields = rumor.as_object().expect("the rumor is a JSON object");
    assert_eq!(
        fields.get("kind").and_then(Value::as_u64),
        Some(444),
        "the innermost rumor is the kind-444 welcome"
    );
    assert!(
        !fields.contains_key("sig"),
        "the kind-444 welcome rumor MUST reach the recipient UNSIGNED (Rule 3 / MIP-02): \
         a signed welcome is republishable by anyone who receives it"
    );
    g.cleanup();
}

// ============================================================================
// Rule 5 — exporter-secret retention: the constants, and the positive edge
// ============================================================================

/// Pins the two numbers Rule 5's "5 past epochs" claim rests on, in BOTH
/// directions: widening keeps stale exporter secrets alive, narrowing silently
/// drops legitimate offline backlog.
#[test]
fn rule5_retention_constants_are_pinned() {
    assert_eq!(
        app_message_past_epoch_limit(),
        5,
        "the engine's accept window for a past-epoch application message is Rule 5's bound"
    );
    assert_eq!(
        DEFAULT_MAX_PAST_EPOCHS, 5,
        "the engine retains exactly 5 past epochs' exporter secrets (Rule 5)"
    );
    // The two must agree: a policy that accepts a message older than the epochs
    // whose keys still exist accepts a message it can never decrypt.
    assert_eq!(
        u64::try_from(DEFAULT_MAX_PAST_EPOCHS).expect("retention window fits a u64"),
        app_message_past_epoch_limit(),
        "the accept window must not outrun the exporter secrets that back it"
    );
}

/// The positive edge of the window whose negative edge (N+6) is
/// `mls_e2e_security_tests::p3b_old_epoch_ciphertext_is_undecryptable_after_retention_window`.
/// Without it, retention passing its gate would be indistinguishable from
/// retention of zero epochs.
#[tokio::test]
async fn rule5_epoch_n_ciphertext_still_decrypts_at_the_window_edge() {
    let g = setup_two_party_group("rule5_edge").await;
    let n = g.alice.epoch(&g.group_id).await.expect("epoch");

    let plaintext = LocationMessage::new(51.5074, -0.1278)
        .to_string()
        .expect("serialize location");
    let held = send_445(&g.alice, &g.group_id, &plaintext).await;

    // Driven off the pinned bound, so raising the limit past what the engine
    // keeps keys for fails HERE rather than shipping as a silent drop.
    let window = app_message_past_epoch_limit();
    advance_both(&g, window).await;
    assert_eq!(
        g.bob.epoch(&g.group_id).await.expect("epoch"),
        n + window,
        "bob's tip must sit exactly at the far edge of the retention window"
    );

    let recovered = decrypt_445_content(&g.bob, &held)
        .await
        .expect("a ciphertext exactly at the edge of the retention window must still decrypt");
    assert_eq!(
        recovered, plaintext,
        "the recovered location must be the one sealed {window} epochs ago, byte for byte"
    );
    g.cleanup();
}

// ============================================================================
// Rule 12 — the live plane's convergence-buffer intake cap
// ============================================================================

/// An event of `kind` carrying `#h = group_hex`, stamped at `created_at_secs`.
///
/// Never ingested by anything here: the receiver forwards or drops an event on
/// its envelope alone, so opaque content is what an intake-cap gate needs.
fn h_tagged(kind: Kind, group_hex: &str, created_at_secs: i64) -> Event {
    EventBuilder::new(kind, "opaque-ciphertext")
        .tags([Tag::custom(
            TagKind::SingleLetter(SingleLetterTag::lowercase(Alphabet::H)),
            [group_hex.to_string()],
        )])
        .custom_created_at(Timestamp::from(
            u64::try_from(created_at_secs).expect("a backlog timestamp is non-negative"),
        ))
        .sign_with_keys(&Keys::generate())
        .expect("sign an h-tagged event")
}

/// One `kind:445` routed at `group_hex` — a circle's genuine backlog.
fn backlog_445(group_hex: &str, created_at_secs: i64) -> Event {
    h_tagged(Kind::Custom(445), group_hex, created_at_secs)
}

/// Delivers `events` to the REAL [`run_receiver`] over a `notif_cap`-slot
/// notification broadcast and an intake queue of `queue_cap`, and returns how
/// many reached the far side.
///
/// Every notification is published BEFORE the receiver task is spawned, which is
/// what makes a `notif_cap` below `events.len()` a deterministic broadcast LAG
/// rather than a race: tokio overwrites the oldest values and reports `Lagged`
/// on the receiver's first `recv`. Completion is signalled by CLOSING the
/// notification channel, not by a sleep: tokio hands a broadcast receiver every
/// value still buffered before it reports `Closed`, so a joined receiver task
/// has provably seen everything that survived. The far side is never drained
/// while the receiver runs, which is what makes a `queue_cap` smaller than the
/// surviving count overflow deterministically.
async fn deliver_through_receiver(
    processor: Arc<EngineProcessor>,
    notif_cap: usize,
    queue_cap: usize,
    events: &[Event],
) -> usize {
    let (btx, brx) = broadcast::channel::<RelayPoolNotification>(notif_cap);
    let (tx, mut rx) = mpsc::channel::<RawSignal>(queue_cap);
    let (_cancel_tx, cancel_rx) = watch::channel(false);

    for event in events {
        btx.send(RelayPoolNotification::Message {
            relay_url: RelayUrl::parse("wss://relay.example").expect("relay url"),
            message: nostr::RelayMessage::Event {
                subscription_id: std::borrow::Cow::Owned(SubscriptionId::new("s_group_0")),
                event: std::borrow::Cow::Owned(event.clone()),
            },
        })
        .expect("the receiver built above holds a live subscription");
    }
    let handle = tokio::spawn(run_receiver(
        brx,
        tx,
        processor,
        Arc::new(AtomicBool::new(false)),
        // The wedged flag: irrelevant here (this harness keeps its worker end
        // alive), and asserted where it matters in
        // `supervisor::a_dead_worker_raises_the_wedged_flag_and_surfaces_a_status`.
        Arc::new(AtomicBool::new(false)),
        cancel_rx,
    ));
    drop(btx);
    handle.await.expect("the receiver task must join cleanly");

    rx.close();
    let mut delivered = 0;
    while rx.recv().await.is_some() {
        delivered += 1;
    }
    delivered
}

/// The widening/removing direction: the live plane's ingest must be BOUNDED.
///
/// Pins the cap both ways and then proves it is real rather than decorative — a
/// queue built the way production builds it refuses the `cap + 1`-th signal with
/// nothing draining it. Removing the bound is caught by construction instead:
/// an unbounded channel cannot satisfy [`intake_queue`]'s signature, so this
/// test stops compiling rather than passing.
///
/// The number itself is a resident-memory choice, not a protocol constant, so
/// what each direction costs is worth stating: widening it holds more
/// undecrypted events in RAM on a background wake, and narrowing it makes the
/// throttle below engage on ordinary bursts, paying a whole window's re-fetch
/// each time. A tuning pass (M11) must move this pin deliberately.
#[test]
fn rule12_live_intake_cap_is_pinned_and_really_bounds_the_queue() {
    assert_eq!(
        WORKER_QUEUE_CAP, 8192,
        "the live plane's Rule-12 intake cap must stay pinned in BOTH directions"
    );

    let eose = || RawSignal::EndOfStoredEvents {
        relay_url: RelayUrl::parse("wss://relay.example").expect("relay url"),
        subscription_id: SubscriptionId::new("s_group_0"),
    };
    let (tx, _rx) = intake_queue();
    for slot in 0..WORKER_QUEUE_CAP {
        assert!(
            tx.try_send(eose()).is_ok(),
            "the intake queue must accept its full advertised capacity; slot {slot} was refused"
        );
    }
    assert!(
        matches!(tx.try_send(eose()), Err(TrySendError::Full(_))),
        "the receive path's ingest MUST be bounded: an undrained queue accepted more than \
         WORKER_QUEUE_CAP signals, so a relay could make one REQ's replay unbounded in memory"
    );
}

/// The half Rule 12 cares most about: hitting the cap must THROTTLE, never
/// discard.
///
/// A dropped delivery reaches no worker and therefore no engine, so nothing else
/// in the pipeline records it. If it left no trace, this generation's `EOSE`
/// would advance the persisted cursor to the REQ's own open time straight over
/// it — and the catch-up sweep re-derives its floor from that SAME per-circle
/// cursor, only `GROUP_RESUBSCRIBE_BUFFER_SECS` (60 s) below it. An event
/// dropped out of a backlog replay, which is the only thing that overflows this
/// queue, would then be re-requested by no plane at all: silently discarded
/// offline backlog, permanently and across restarts.
///
/// So the assertion is on the cursor, not on a counter: the drop must pull the
/// advance back onto the OLDEST dropped event. The control arm — a roomy queue,
/// nothing dropped, cursor at the window's open time — is what stops this
/// passing on a cursor that simply never moves.
#[tokio::test]
async fn rule12_an_intake_drop_holds_the_cursor_instead_of_discarding_backlog() {
    let dir = unique_temp_dir("rule12_intake");
    let circle = Arc::new(
        CircleManager::new_unencrypted(&dir, &Keys::generate()).expect("open a circle manager"),
    );
    let processor = Arc::new(EngineProcessor::new(
        Arc::clone(&circle),
        EventBus::with_capacity(16),
    ));
    // A local reading in the recent past. `note_end_of_stored_events` caps its
    // advance at the wall clock, so a window that opened BEFORE `now` keeps that
    // cap inert however long the test takes — no timing race.
    let opened_at = chrono::Utc::now().timestamp() - 10;

    // ── Control: a queue with room drops nothing, so the EOSE advances to the
    //    REQ's own open time.
    let quiet = hex::encode([0x11u8; 32]);
    processor.note_subscription_opened(&quiet, opened_at);
    let delivered = deliver_through_receiver(
        Arc::clone(&processor),
        64,
        8,
        &[backlog_445(&quiet, opened_at - 100)],
    )
    .await;
    assert_eq!(delivered, 1, "a queue with room must forward, not drop");
    assert!(processor.note_end_of_stored_events(&quiet));
    assert_eq!(
        circle
            .read_sync_cursor(&group_cursor_stream(&quiet))
            .expect("read the quiet circle's cursor"),
        Some(opened_at * 1000),
        "with nothing dropped the advance is the window's own open time — the baseline the \
         gate below has to differ from"
    );

    // ── The rule: overflow the cap with an hours-old backlog replay.
    let flooded = hex::encode([0x22u8; 32]);
    processor.note_subscription_opened(&flooded, opened_at);
    let oldest = opened_at - 7_200;
    let delivered = deliver_through_receiver(
        Arc::clone(&processor),
        64,
        1,
        &[
            backlog_445(&flooded, opened_at - 100), // takes the single slot
            backlog_445(&flooded, opened_at - 3_600), // dropped
            // Dropped LAST and the oldest, so a hold-back that keeps whichever
            // drop it saw FIRST fails here rather than passing by arrival order.
            backlog_445(&flooded, oldest),
        ],
    )
    .await;
    assert_eq!(
        delivered, 1,
        "precondition: a cap-1 queue must have dropped two of the three deliveries, or the \
         assertion below is about nothing"
    );
    assert!(processor.note_end_of_stored_events(&flooded));
    assert_eq!(
        circle
            .read_sync_cursor(&group_cursor_stream(&flooded))
            .expect("read the flooded circle's cursor"),
        Some(oldest * 1000),
        "an event the intake cap dropped MUST hold its circle's cursor at itself (Rule 12): \
         advancing over it discards legitimate offline backlog that no plane ever re-requests"
    );

    cleanup_dir(&dir);
}

/// The BURST form of the same rule: a backlog bigger than the intake cap holds
/// the cursor ACROSS a pause.
///
/// A background burst downloads into the same bounded queue, and the pause that
/// follows it is the one moment the engine deliberately stops ingesting. The two
/// have to compose: an event the cap dropped must still bound the advance the
/// NEXT burst's `EOSE` issues, or a device that pauses every 72-168 s loses a
/// slice of every over-cap replay it ever takes — permanently, because the
/// catch-up sweep re-derives its floor from the same per-circle cursor.
///
/// What the pause contributes is `note_delivery_gap`, which SUPPRESSES the open
/// generation's advance and KEEPS its hold-back. A `forget_*` there drops the
/// hold-back with the anchor, and the next burst's advance sails over the
/// dropped events: this test is red for that mutation, at the cursor.
#[tokio::test]
async fn a_burst_backlog_larger_than_the_intake_cap_holds_the_cursor() {
    let dir = unique_temp_dir("rule12_burst_backlog");
    let circle = Arc::new(
        CircleManager::new_unencrypted(&dir, &Keys::generate()).expect("open a circle manager"),
    );
    let processor = Arc::new(EngineProcessor::new(
        Arc::clone(&circle),
        EventBus::with_capacity(16),
    ));
    let opened_at = chrono::Utc::now().timestamp() - 10;
    let group = hex::encode([0x44u8; 32]);

    // ── The burst downloads an over-cap replay. The queue keeps one and drops
    //    the rest; the oldest drop is what must bound every later advance.
    processor.note_subscription_opened(&group, opened_at);
    let oldest = opened_at - 7_200;
    let delivered = deliver_through_receiver(
        Arc::clone(&processor),
        64,
        1,
        &[
            backlog_445(&group, opened_at - 50),
            backlog_445(&group, opened_at - 1_800),
            backlog_445(&group, oldest),
        ],
    )
    .await;
    assert_eq!(
        delivered, 1,
        "precondition: a cap-1 queue must drop two of the three, or this test is about \
         nothing"
    );

    // ── The pause: suppress, never forget.
    processor.note_delivery_gap();

    // ── The next burst re-issues the REQ at a FRESH open time and its relay
    //    EOSEs. That advance must stop at the dropped event, not at the new
    //    REQ's open time.
    let next_open = chrono::Utc::now().timestamp();
    processor.note_subscription_opened(&group, next_open);
    assert!(
        processor.note_end_of_stored_events(&group),
        "the next burst's EOSE must be redeemable — otherwise nothing is being bounded"
    );

    assert_eq!(
        circle
            .read_sync_cursor(&group_cursor_stream(&group))
            .expect("read the circle's cursor"),
        Some(oldest * 1000),
        "an event the intake cap dropped must hold its circle's cursor at itself ACROSS \
         a pause (Rule 12). Advancing to the next burst's open time ({}) discards \
         legitimate offline backlog that no plane ever re-requests",
        next_open * 1000
    );

    cleanup_dir(&dir);
}

/// Rule 13, structurally: the radio is never cut with a publish outstanding.
///
/// The gauge is the whole mechanism — the engine awaits `in_flight_publishes ==
/// 0` with NO cap immediately before every radio cut. A time-based cap there
/// would cut a commit between SEND and OK: `wait_for_ok` returns `Err`,
/// `publish_failed` rolls the group back to the prior epoch, and the relay may
/// already have stored and served that commit — a roster fork every couple of
/// minutes on a background device.
///
/// There are TWO cuts, not one: the pause, and the failure exit of a burst open
/// that had already connected. Both go through `terminate_all_relays`, so this
/// pins the ordering at every call of it rather than at the one the pause makes
/// — a second cut added without its drain is exactly the kind of thing that is
/// silent when broken.
///
/// A drive of the stored fanout records is counted on the same gauge for its
/// whole pass, and each cut also closes the pool the drive's calls ride — after
/// the gauge and after the engine's own radio, so no call of a drive is cut by
/// a pause: it has answered, or it was never begun.
///
/// The behavioural proof, over a real relay withholding a real OK, is
/// `live_sync_burst_e2e::pause_never_disconnects_while_an_auto_commit_awaits_its_ok`.
/// This is the SOURCE-level half: the two facts that make it work are asserted
/// where a reviewer would otherwise have to notice them, because both are silent
/// when broken.
#[test]
fn rule13_a_burst_never_pauses_with_a_pending_publish_outstanding() {
    let session =
        std::fs::read_to_string(repo_root().join("haven-core/src/relay/live_sync/session.rs"))
            .expect("read session.rs");

    let pause = pause_body(&session);

    let resume =
        fn_body(&session, "async fn resume_burst").expect("session.rs must define resume_burst");
    for (name, body) in [
        ("pause_subscriptions", pause.as_str()),
        ("resume_burst", resume),
    ] {
        let gauge = body
            .find("wait_publishes_drained")
            .unwrap_or_else(|| panic!("{name} must await the in-flight publish gauge"));
        let cut = body
            .find("terminate_all_relays")
            .unwrap_or_else(|| panic!("{name} must cut the radio — that is what it is for"));
        assert!(
            gauge < cut,
            "in {name} the in-flight publish gauge MUST be awaited BEFORE the radio is \
             cut: a disconnect while a commit is between SEND and OK makes wait_for_ok \
             return Err(PrematureExit)/Err(NotConnected), the commit rolls back to the \
             prior epoch, and the relay may already have served it — a roster fork \
             (Rule 13)"
        );
        assert!(
            !body.contains("client.disconnect()"),
            "{name} must cut the radio through `terminate_all_relays`, never a bare \
             `client.disconnect()`. One `disconnect` does not reliably stop a relay's \
             connection task: it fires the termination permit BEFORE storing \
             `Terminated`, so a preempted caller leaves the task armed on the crate's \
             retry schedule and it re-opens a socket mid-gap"
        );
        let pool = body
            .find("close_drive_pool")
            .unwrap_or_else(|| panic!("{name} must close the pool its fanout drives ride"));
        assert!(
            gauge < pool && cut < pool && body.matches("close_drive_pool").count() == 1,
            "in {name} the drive pool must be closed once, after the in-flight gauge has \
             drained and after the engine's own radio is cut: closed earlier it would cut \
             a drive's call between its send and its relay's answer"
        );
        // The wait nearest above the cut is the one that covers it: nothing
        // that could start a publish may sit between them.
        let nearest = body[..cut]
            .rfind("wait_publishes_drained")
            .expect("found above");
        for starts_a_publish in ["register_and_subscribe", ".connect()"] {
            assert!(
                !body[nearest..cut].contains(starts_a_publish),
                "in {name} `{starts_a_publish}` sits between the gauge wait and the radio cut",
            );
        }
    }

    assert_one_disconnect_closes_the_drive_pool(&session);

    let terminate = fn_body(&session, "async fn terminate_all_relays")
        .expect("session.rs must define terminate_all_relays");
    // Matched on call syntax, never the bare words: the function's own comments
    // explain why it yields rather than sleeps, and a guard that read prose
    // would fire on the explanation of the thing it is guarding against.
    for timer in ["sleep(", "timeout(", "Duration"] {
        assert!(
            !terminate.contains(timer),
            "the radio cut must hold no timer; it now uses `{timer}`. It runs \
             immediately after the UNCAPPED Rule-13 gauge wait, so a clock here would \
             be the engine choosing to delay a pause the caller has already paid an \
             unbounded wait for. Its bound is a ROUND COUNT, and each round yields"
        );
    }

    let processor =
        std::fs::read_to_string(repo_root().join("haven-core/src/relay/live_sync/processor.rs"))
            .expect("read processor.rs");
    let drive = fn_body(&processor, "pub(super) async fn drive_due(")
        .expect("processor.rs must define drive_due");
    let counted = drive
        .find("self.in_flight_publishes.fetch_add(1, Ordering::SeqCst);")
        .expect("a drive of the stored records must raise the in-flight gauge");
    let guarded = drive
        .find("let _gauge = PublishGauge(&self.in_flight_publishes, &self.publish_drained);")
        .expect("and lower it through the drop guard, however the pass ends");
    assert!(
        counted < guarded
            && guarded
                < drive
                    .find("Publishing {")
                    .expect("drive_due builds the driver"),
        "a drive must be on the gauge before it can reach a relay",
    );
    let wait = fn_body(&processor, "pub async fn wait_publishes_drained")
        .expect("processor.rs must define wait_publishes_drained");
    for capped in ["timeout", "sleep", "Duration"] {
        assert!(
            !wait.contains(capped),
            "the in-flight publish wait must stay UNCAPPED (Rule 13); it now mentions \
             `{capped}`. Its bound is the crate's own 10 s per-relay OK wait, never a \
             clock this engine chose"
        );
    }
}

/// Rule 14: pausing and re-opening a burst opens no second session.
///
/// One `AccountDeviceSession` per MLS database, across every isolate and
/// process. A burst model is where that could quietly break: rebuilding the core
/// per burst — instead of pausing and resuming ONE core — would re-run the
/// construction site every ~2 minutes and, worse, rotate the per-session sub-id
/// salt on every publish tick (a fresh relay-visible fingerprint, which PSI-2
/// declares intentional to avoid).
///
/// The construction site is already pinned to one place by
/// `check_mls_session_single_owner.sh`; what this adds is that the BURST path
/// contains no second one, and that the pause/burst methods live on the SAME
/// core rather than building one.
#[test]
fn rule14_pause_and_burst_open_no_second_session() {
    let session =
        std::fs::read_to_string(repo_root().join("haven-core/src/relay/live_sync/session.rs"))
            .expect("read session.rs");

    for (name, text) in [
        ("pause_subscriptions", pause_body(&session)),
        (
            "resume_burst",
            fn_body(&session, "async fn resume_burst")
                .expect("session.rs must define resume_burst")
                .to_owned(),
        ),
    ] {
        for forbidden in ["new_local", "AccountDeviceSession", "SessionManager::"] {
            assert!(
                !text.contains(forbidden),
                "{name} mentions `{forbidden}`: the burst must pause and re-open the ONE \
                 core it already has. Rebuilding a core per burst re-runs the Rule-14 \
                 session construction on every publish tick and rotates the sub-id salt \
                 with it"
            );
        }
    }
}

/// OD4-c, structurally: what keeps a removal-bearing auto-commit out of a
/// background burst cannot be edited away silently.
///
/// A burst makes no such commit at all — nothing is staged, so nothing can
/// be published or cut. Four facts hold that up, and each is invisible when
/// broken — a burst would simply stage again, and no existing test of another
/// plane would say so:
///
/// 1. the live plane keeps nothing for a drive, and asks for none, from a
///    receive its lifecycle answers with the mode that makes no commit
///    (`Lifecycle::receives`, pinned in the driver's gate);
/// 2. in that mode the plane's advance is the engine's inputs-only one,
///    which stages nothing, and so is every receive advance outside the
///    driver;
/// 3. a hold that records nothing makes no commit of the engine's own: the
///    auto-commit such a hold stages is undone, unsent, and a location asked
///    for is not sealed once an eviction is due;
/// 4. the lifecycle comes from the session's typed `BurstKind`, set before
///    any REQ the open issues, so no event is taken in under the previous
///    open's lifecycle.
///
/// The behavioural proofs are in `live_plane_drive_e2e`
/// (`a_started_session_and_a_burst_make_nothing_of_a_departure`) and
/// `live_sync_burst_e2e`.
#[test]
#[allow(clippy::too_many_lines)]
fn od4c_a_background_burst_cannot_publish_a_removal_bearing_auto_commit() {
    let squash = |text: &str| -> String { text.chars().filter(|c| !c.is_whitespace()).collect() };
    let processor =
        production_source(&repo_root().join("haven-core/src/relay/live_sync/processor.rs"));
    let flat = squash(&processor);
    let resolve =
        squash(fn_body(&processor, "async fn resolve(").expect("processor.rs must define resolve"));
    assert!(
        !flat.contains("resolve_publish_work") && !flat.contains("self.publisher"),
        "the live plane hands a batch to a publisher beside its driver again",
    );
    assert!(
        resolve.contains("ifself.driver.is_none()||mode!=DriveMode::Full{return;}")
            && resolve.find("ifself.driver.is_none()||mode!=DriveMode::Full{return;}")
                < resolve.find("self.keep_for_the_drive("),
        "a plane that makes no commit keeps a proposal for a drive, or asks for one, \
         from its receive path"
    );

    let manager = production_source(&repo_root().join("haven-core/src/nostr/mls/manager.rs"));
    let settle = squash(
        fn_body(&manager, "pub(crate) async fn settle_inputs_for_drive(")
            .expect("manager.rs must define settle_inputs_for_drive"),
    );
    assert!(
        settle
            .matches("session.advance_convergence_inputs(group_id)")
            .count()
            == 2
            && !settle.contains("session.advance_convergence(")
            && !settle.contains("session.send(")
            && settle.contains("DriveMode::FinishOnly,).await;"),
        "the advance of a plane that makes no commit is no longer the engine's \
         inputs-only one: the full advance stages a due eviction"
    );
    let holds = squash(
        fn_body(&manager, "pub(crate) async fn departure_holds_a_send(")
            .expect("manager.rs must define departure_holds_a_send"),
    );
    let away = squash(fn_body(&manager, "fn away_hold(").expect("away_hold"));
    assert!(
        squash(fn_body(&manager, "pub(crate) fn plane_stands(").expect("plane_stands"))
            == "{let_=self.live_plane.try_update(Ordering::SeqCst,Ordering::SeqCst,\
                |current|{(plane>=current>>2).then_some(plane<<2|standingasu64)});}"
            // A claim is taken only from a plane that is still only started:
            // one a pause or a stop has overtaken lowers nothing.
            && squash(fn_body(&manager, "pub(crate) fn plane_claimed(").expect("plane_claimed"))
                == "{let_=self.live_plane.compare_exchange(plane<<2|PlaneStanding::Launchedasu64,\
                    plane<<2|PlaneStanding::Foregroundasu64,Ordering::SeqCst,Ordering::SeqCst,);}"
            // A hold beside a plane that makes no commit hands back the
            // smaller slice: a burst's, a pause's, a session only started's.
            && squash(
                fn_body(&manager, "fn beside_a_plane_that_makes_none(")
                    .expect("beside_a_plane_that_makes_none")
            ) == "{letplane=self.plane_standing();plane==PlaneStanding::MakesNoneasu64\
                  ||plane==PlaneStanding::Launchedasu64}"
            // The one claim besides the live plane's: a bridge call that says
            // it is the foreground's, while it lasts, in a process with no
            // live plane (`relay::fanout::Claimed`); beside one, the plane's
            // own lifecycle decides and the word cannot widen it.
            && squash(
                fn_body(&manager, "fn away_from_the_foreground(")
                    .expect("away_from_the_foreground")
            ) == "{letplane=self.plane_standing();plane!=PlaneStanding::Foregroundasu64\
                  &&!(plane==PlaneStanding::Goneasu64\
                  &&self.bridge_claims.load(Ordering::SeqCst)>0)}"
            && squash(fn_body(&manager, "fn bridge_may_commit(").expect("bridge_may_commit"))
                == "{letplane=self.plane_standing();plane==PlaneStanding::Goneasu64\
                    ||plane==PlaneStanding::Foregroundasu64}"
            && holds.contains("letmakes_none=mode==DriveMode::FinishOnly;")
            // A refused eviction holds every send until it lands: inside its
            // wait, and after it while the engine still announces it ahead.
            && holds.contains(
                "letheld=departure_held(session.scheduled_self_remove_auto_commit_delay_ms(\
                 group_id).ok().flatten(),self.restage_wait_runs(group_id,now_ms),self.\
                 refusal_stands(group_id),makes_none,||self.departure_stands(group_id),);"
            )
            && squash(fn_body(&manager, "fn departure_held(").expect("departure_held"))
                == "{due_in_ms.is_some_and(|due_in_ms|{wait_runs||(due_in_ms>0&&refusal_stands)\
                    ||(makes_none&&due_in_ms==0&&departure_stands())})}"
            // What a circle was left waiting for is read by every call but
            // a claimed foreground's full one, with the engine held.
            && holds.contains(
                "ifself.away_hold(&session,group_id,mode).is_some()\
                 {returnOk(Some((ahead,true)));}"
            )
            // A leave, a routing collision (decision 250, a store that
            // cannot say included) and a removal left unmade hold every
            // call, a claimed foreground's too (decision 238); a relay change
            // applied away, every call but that one. The store's half is one
            // function, which the departure check's fast path reads too.
            && away
                == "{matchself.stored_hold(group_id,mode){StoredHold::Held(held)=>returnSome(held),S\
                    toredHold::Clear=>returnNone,StoredHold::AskTheRoster=>{}}ifremoval_unmade(&self\
                    .message_store,self.commit_notes.as_ref(),session,group_id,){returnSome(AwayHold\
                    ::RemovalUnmade);}self.relay_change_hold(group_id,mode)}"
            && squash(fn_body(&manager, "fn stored_hold(").expect("stored_hold"))
                == "{ifself.leaving(group_id){returnStoredHold::Held(AwayHold::Leaving);}ifself.rout\
                    ing_collided(group_id){returnStoredHold::Held(AwayHold::RoutingCollision);}if!se\
                    lf.commit_notes.removal_targets(group_id).is_some_and(|kept|kept.is_empty()){ret\
                    urnStoredHold::AskTheRoster;}self.relay_change_hold(group_id,mode).map_or(Stored\
                    Hold::Clear,StoredHold::Held)}"
            && squash(fn_body(&manager, "fn relay_change_hold(").expect("relay_change_hold"))
                == "{ifmode==DriveMode::Full&&!self.away_from_the_foreground(){returnNone;}\
                    self.awaits_foreground(group_id).then_some(AwayHold::RelayChange)}"
            && squash(fn_body(&manager, "pub(crate) fn routing_collided(").expect("routing_collided"))
                == "{self.commit_notes.stands(group_id,ChangeNote::RoutingCollision)!=Some(false)}"
            && holds.contains("matches!(self.stored_hold(group_id,DriveMode::Full),StoredHold::Clear)")
            && squash(
                fn_body(&manager, "async fn unstaged_beside_a_fanout(")
                    .expect("unstaged_beside_a_fanout")
            )
            .contains(
                "matches!(item,PublishWork::AutoPublish{..})||Self::has_unresolved_fanout(\
                 session,group_id)"
            ),
        "a location asked for while a burst shares the session is sealed with an eviction \
         due or with its circle waiting for the foreground, or the engine's own commit a \
         hold that records nothing stages is left staged"
    );
    // The hold is the newest plane's word: written from the live plane's one
    // lifecycle write and from its end, each under the plane's own number,
    // and from nowhere else in any tree a product build compiles.
    let mut writers = Vec::new();
    for file in scanned_sources() {
        let text = squash(&production_source(&file));
        let calls =
            text.matches(".plane_stands(").count() + text.matches(".plane_claimed(").count();
        if calls > 0 {
            writers.push((file.to_string_lossy().into_owned(), calls));
        }
    }
    assert!(
        writers.len() == 1
            && writers[0]
                .0
                .ends_with("haven-core/src/relay/live_sync/processor.rs")
            && writers[0].1 == 4
            && flat.contains(
                "implDropforEngineProcessor{fndrop(&mutself){\
                 self.circle.session().plane_stands(self.plane,PlaneStanding::Gone);\
                 self.circle.session().burst_ends(self.plane,None);}}"
            )
            && flat.contains("plane:PLANES.fetch_add(1,Ordering::SeqCst),")
            && flat.matches("PLANES").count() == 2,
        "the hold on a session's commits is written from somewhere other than the live \
         plane's lifecycle write and its end, or under a number that is not the plane's \
         own: a plane let go late could lower the hold of the burst that replaced it"
    );
    // A burst's end, which cuts every wake a drive or the bridge begins, is
    // written by the live plane alone and under its own number, the same rule.
    let mut ends = Vec::new();
    for file in scanned_sources() {
        let text = squash(&production_source(&file));
        let calls = text.matches(".burst_ends(").count();
        if calls > 0 {
            let own = text.matches(".burst_ends(self.plane,").count();
            ends.push((file.to_string_lossy().into_owned(), calls, own));
        }
    }
    assert!(
        ends.len() == 1
            && ends[0]
                .0
                .ends_with("haven-core/src/relay/live_sync/processor.rs")
            && ends[0].1 == ends[0].2,
        "a burst's end is written from somewhere other than the live plane, or under a \
         number that is not the plane's own",
    );
    let receive = squash(
        fn_body(&manager, "async fn advance_once_for_receive(")
            .expect("fn advance_once_for_receive"),
    );
    assert!(
        receive.contains("Box::pin(session.advance_convergence_inputs(group_id))")
            && !receive.contains("session.advance_convergence(group_id)"),
        "a receive plane's advance outside the driver makes the full advance: an eviction \
         left due would be staged from the background"
    );

    let session = production_source(&repo_root().join("haven-core/src/relay/live_sync/session.rs"));
    let resume =
        fn_body(&session, "async fn resume_burst").expect("session.rs must define resume_burst");
    let enter = fn_body(&session, "fn enter_burst(").expect("session.rs must define enter_burst");
    let set = resume
        .find("self.enter_burst(kind, ends)?;")
        .expect("resume_burst must set the receive-side lifecycle");
    assert!(
        enter.split_whitespace().collect::<String>().starts_with(
            "{self.processor.set_burst_end(ends);\
                 self.processor.set_background_burst(matches!(kind,BurstKind::Background));\
                 ifself.shutdown.load(Ordering::Acquire){self.repause();\
                 returnErr(LiveSyncError::NoSession);}Ok(())}"
        ),
        "the lifecycle must be derived from the open's own typed BurstKind — the \
         same value the inbox fold reads — so the two cannot drift apart; and a stop \
         that overtook the write must find its pause put back at it"
    );
    let subscribe = resume
        .find("register_and_subscribe")
        .expect("resume_burst must issue the REQs");
    assert!(
        set < subscribe,
        "the lifecycle must be set BEFORE the REQs this open issues, or an event \
         delivered by this open is resolved under the PREVIOUS open's policy"
    );
    let start = fn_body(&session, "pub async fn start").expect("session.rs must define start");
    assert!(
        !start.contains("serve_the_foreground"),
        "`start` serves its session as the foreground's: it cannot tell a foreground \
         launch from a background wake that cold-launched the process"
    );
}

/// A fanout is the only way a commit leaves the device (Security Rule 13).
///
/// Every commit is staged under its durable fanout record in the hold that
/// staged it and sent by the driver alone; a proposal too, except one no
/// record could be written for, which the driver publishes once, in the full
/// mode, through its publisher of unrecorded events. One `kind:445` leaves
/// with no record at all and is none of these: a fellow member's location
/// this device took in by Bluetooth, passed on by the driver's bridge (owner
/// decision D-7, `the_bridge_sends_once_and_reads_no_answer`). It is an
/// application message — the mesh's ingress admits nothing else — so no
/// commit and no proposal leaves that way. What once resolved a
/// commit beside it is gone — the circle manager's confirm, rollbacks and
/// relay-update finish, the receive ladder, the removal-deferral table and its
/// redemption — and so is every bridge symbol that handed one to Dart. The
/// plain publish entries refuse what the driver owns: the relay layer an event
/// that has a record, the bridge every kind 445. The engine's own plain
/// confirm is reached only for a commit whose record a relay already
/// acknowledged, and the engine's plain rollback only for a commit nothing was
/// ever sent for (pinned below). The behavioural proofs are
/// `fanout_driver_e2e::nothing_but_the_driver_sends_an_event_that_has_a_fanout_row`
/// and the bridge's `a_group_message_is_refused_before_any_relay_is_asked_and_nothing_else_is`.
#[test]
#[allow(clippy::too_many_lines)]
fn a_fanout_is_the_only_way_a_commit_leaves_the_device() {
    let squash = |text: &str| -> String { text.chars().filter(|c| !c.is_whitespace()).collect() };
    assert!(
        !repo_root()
            .join("haven-core/src/relay/auto_commit.rs")
            .exists(),
        "the receive ladder is back",
    );
    let manager = production_source(&repo_root().join("haven-core/src/circle/manager.rs"));
    for gone in [
        "fn confirm_published(",
        "fn publish_failed(",
        "fn publish_failed_on_receive(",
        "fn finalize_relay_update(",
        "fn owe_removal_publish(",
        "fn redeem_removal_deferrals(",
        "fn owed_removal_commits(",
        "fn orphaned_removal_deferrals(",
        "CommitToPublish",
    ] {
        assert!(
            !manager.contains(gone),
            "circle/manager.rs has `{gone}` again: a second way for a commit to be resolved",
        );
    }
    let storage = production_source(&repo_root().join("haven-core/src/circle/storage.rs"));
    assert!(
        storage.matches("deferred_removal_commits").count() == 1
            && storage.contains("DROP TABLE IF EXISTS deferred_removal_commits;"),
        "the removal-deferral table is named for anything but its drop",
    );
    let processor =
        production_source(&repo_root().join("haven-core/src/relay/live_sync/processor.rs"));
    assert!(
        !processor.contains("redeem_removal_deferrals") && !processor.contains("with_publisher"),
        "the live plane has a publisher of commits beside its driver again",
    );

    // The engine's plain application-message sends seal a kind 445 under no
    // record: built for tests alone.
    for (file, signature) in [
        (
            "haven-core/src/nostr/mls/manager.rs",
            "pub async fn create_message(",
        ),
        (
            "haven-core/src/nostr/mls/manager.rs",
            "pub async fn send_location(",
        ),
        (
            "haven-core/src/nostr/mls/context.rs",
            "pub async fn encrypt_event(",
        ),
    ] {
        let source = std::fs::read_to_string(repo_root().join(file)).expect("read the source");
        let at = source.find(signature).expect("the maker is defined");
        assert!(
            source[..at].trim_end().lines().last().map(str::trim)
                == Some("#[cfg(any(test, feature = \"test-utils\"))]"),
            "`{signature}` ships: a kind 445 with no record could leave the device",
        );
    }

    let bridge = production_source(&repo_root().join("haven/rust_builder/src/api.rs"));
    for gone in [
        "fn confirm_published(",
        "fn publish_failed(",
        "fn finalize_relay_update(",
        "fn decrypt_location_collecting_commits(",
        "struct PendingStateRefFfi",
        "struct CommitToPublishFfi",
        "fn publish_location_event(",
    ] {
        assert!(
            !bridge.contains(gone),
            "the bridge carries `{gone}` again: a staged commit could be resolved from Dart",
        );
    }
    let publish = squash(
        fn_body(&bridge, "pub async fn publish_event(").expect("the bridge defines publish_event"),
    );
    let refused = publish
        .find("ifevent.kind.as_u16()==haven_core::nostr::KIND_GROUP_MESSAGE{returnErr(refused(PublishRefusalFfi::GroupMessage));}")
        .expect("the bridge's plain publish refuses a kind 445");
    assert!(
        publish
            .find(".publish_event(&event,&relays)")
            .is_some_and(|sent| refused < sent),
        "the bridge's plain publish sends before it refuses a kind 445",
    );
    let relays = production_source(&repo_root().join("haven-core/src/relay/manager.rs"));
    let core_publish = squash(
        fn_body(&relays, "pub async fn publish_event(")
            .expect("the relay layer defines publish_event"),
    );
    assert!(
        core_publish.starts_with("{Self::refuse_fanout_owned(event)?;"),
        "the relay layer's plain publish does not refuse an event the driver owns first",
    );

    // The engine's plain confirm: a commit a relay already acknowledged
    // (`finish_confirmed_fanout`), or a test seam.
    let session = production_source(&repo_root().join("haven-core/src/nostr/mls/manager.rs"));
    let flat = squash(&session);
    assert_eq!(
        flat.matches("session.confirm_published(pending)").count(),
        3
    );
    for (signature, test_only) in [
        ("pub(crate) async fn finish_confirmed_fanout(", false),
        ("pub async fn confirm_published(", true),
        (
            "pub async fn confirm_published_past_its_fanout_for_test(",
            true,
        ),
    ] {
        let body = squash(fn_body(&session, signature).unwrap_or_else(|| panic!("{signature}")));
        assert!(
            body.contains("session.confirm_published(pending)"),
            "{signature}"
        );
        let at = session.find(signature).expect("checked");
        assert_eq!(
            session[..at]
                .trim_end()
                .ends_with("#[cfg(any(test, feature = \"test-utils\"))]"),
            test_only,
            "{signature} is compiled into the product, or its test gate moved",
        );
    }
    assert_the_session_rolls_back_only_for_the_driver_or_before_a_send();
    assert_an_unsent_commit_is_rolled_back_only_where_nothing_was_sent();
    assert_the_circle_read_reports_the_engines_durable_verdict();

    // No background plane makes a commit: the sweep every wake runs drives in
    // the mode that only finishes.
    let catchup = squash(&production_source(
        &repo_root().join("haven-core/src/relay/catchup.rs"),
    ));
    assert!(
        catchup.contains(
            "run_catchup_in(circle_mgr,relay_mgr,max_duration_secs,&DriveMode::FinishOnly,)"
        ),
        "the wake sweep is not the finish-only one",
    );
}

/// The rollback `CircleManager`'s rungs cannot see: the session's own.
///
/// A commit staged in staging mode is resolved inside `SessionManager`, past
/// every `CircleManager` rung the gate above reads, so a removal-bearing
/// commit can be rolled back there. What is pinned is every way it can
/// happen, and that there are no others:
///
/// * the fanout driver, on every frozen relay's proven refusal and only while
///   none was ever possibly exposed — one call site, under the one decision
///   that reads the record's exposure flag, with the circle told;
/// * before anything was sent, in the hold that staged the commit: its
///   record could not be written, a re-staging wait is running, or it was
///   staged beside a pending commit a relay may hold;
/// * before anything was sent, in a later hold: a commit that could be
///   neither recorded nor rolled back in its own hold and still has no
///   record, and a commit a failed advance staged and dropped;
/// * the legacy rung, which refuses a recorded commit before it does
///   anything.
///
/// In each the engine re-arms an eviction it rolls back; none is a drop.
fn assert_the_session_rolls_back_only_for_the_driver_or_before_a_send() {
    let squash = |text: &str| -> String { text.chars().filter(|c| !c.is_whitespace()).collect() };
    let session = production_source(&repo_root().join("haven-core/src/nostr/mls/manager.rs"));
    let plain = ".publish_failed_in(";
    let mut reviewed = 0;
    for signature in [
        "async fn publish_failed_holding(",
        "async fn stage_commits(",
        "async fn retry_unrecorded(",
        "async fn unstage_unsent(",
        "async fn unstaged_beside_a_fanout(",
        "pub async fn publish_failed_past_its_fanout_for_test(",
    ] {
        let body = squash(
            fn_body(&session, signature)
                .unwrap_or_else(|| panic!("the session must define {signature}")),
        );
        assert_eq!(
            body.matches(plain).count(),
            1,
            "{signature} must hold exactly one session-level rollback",
        );
        reviewed += 1;
    }
    assert_eq!(
        squash(&session).matches(plain).count(),
        reviewed,
        "a session-level rollback was added outside the reviewed functions: a \
         removal-bearing commit rolled back there is seen by no other gate",
    );
    let seam = session
        .find("pub async fn publish_failed_past_its_fanout_for_test(")
        .expect("the test seam exists");
    assert!(
        session[..seam]
            .trim_end()
            .ends_with("#[cfg(any(test, feature = \"test-utils\"))]"),
        "the rollback past a record is compiled into the product",
    );
    let legacy = squash(fn_body(&session, "async fn publish_failed_holding(").expect("checked"));
    assert!(
        legacy.find("refuse_fanout_owned(") < legacy.find(plain),
        "the legacy rung must refuse a recorded commit before it rolls anything back",
    );
    let hold = squash(fn_body(&session, "async fn stage_commits(").expect("checked"));
    assert!(
        hold.find("Some(Ok(id))=>{fanouts.push(id);continue;}") < hold.find(plain),
        "the staging hold must roll back only a commit it did not record: one \
         that has a record is the driver's, and may have been sent",
    );

    let fanout_form = ".publish_failed_fanout(";
    assert_eq!(squash(&session).matches(fanout_form).count(), 1);
    assert!(squash(
        fn_body(&session, "pub(crate) async fn roll_back_fanout(")
            .expect("the session must define roll_back_fanout")
    )
    .contains(fanout_form));
    let driver = production_source(&repo_root().join("haven-core/src/relay/fanout.rs"));
    let settle =
        squash(fn_body(&driver, "async fn settle(").expect("fanout.rs must define settle"));
    assert_eq!(
        squash(&driver).matches(".roll_back_fanout(").count(),
        1,
        "the driver must roll a recorded commit back from one place",
    );
    let arm = settle
        .find("Decision::RollBack=>{")
        .expect("the driver's settle must have a rollback arm");
    let leave = settle
        .find("Decision::Leave=>")
        .expect("and an arm that leaves the commit");
    let call = settle
        .find(".roll_back_fanout(")
        .expect("the rollback is made in settle");
    assert!(
        arm < call && call < leave,
        "the driver's rollback must sit under the one decision that allows it",
    );
    assert!(
        settle[arm..leave].contains("ChangeNote::RemovalUndone"),
        "a rolled-back removal must be told to its circle",
    );
    let decide = squash(fn_body(&driver, "fn decide(").expect("fanout.rs must define decide"));
    for needed in [
        "outcome.fanout_complete",
        "outcome.accepted_targets==0",
        "!fanout.possible_exposure()",
    ] {
        assert!(
            decide.contains(needed),
            "the rollback decision no longer requires `{needed}`: a commit a relay \
             may hold could be rolled back",
        );
    }
}

/// The later rollbacks of a commit nothing was ever sent for, and the one
/// engine call under every session-level rollback.
fn assert_an_unsent_commit_is_rolled_back_only_where_nothing_was_sent() {
    let squash = |text: &str| -> String { text.chars().filter(|c| !c.is_whitespace()).collect() };
    let session = production_source(&repo_root().join("haven-core/src/nostr/mls/manager.rs"));
    let plain = ".publish_failed_in(";
    // The two rollbacks of a commit no hold could record: tried again only
    // while it still has no record, and after a failed advance only for a
    // commit that very advance staged.
    let retry = squash(fn_body(&session, "async fn retry_unrecorded(").expect("checked"));
    assert!(
        retry.find("Self::has_fanout(session,pending).unwrap_or(true)") < retry.find(plain),
        "the retried rollback must let go of a commit that has been given a record",
    );
    let failed = squash(
        fn_body(&session, "async fn after_a_failed_advance(")
            .expect("the session must define after_a_failed_advance"),
    );
    assert!(
        failed.contains(".filter(|_|staged_before.is_none())")
            && failed.find("staged_before.is_none()") < failed.find(".unstage_unsent("),
        "a failed advance must roll back only a commit that advance itself staged: \
         one staged before it may have been published",
    );
    assert_eq!(
        squash(&session).matches(".unstage_unsent(").count(),
        1,
        "the rollback of an unsent commit is reached from somewhere other than a failed advance",
    );
    // The engine's own plain rollback has one call site under all of them.
    assert_eq!(
        squash(&session)
            .matches("session.publish_failed(pending)")
            .count(),
        1,
        "the engine's plain rollback is called outside `publish_failed_in`",
    );
    assert!(squash(
        fn_body(&session, "async fn publish_failed_in(").expect("publish_failed_in exists")
    )
    .contains("session.publish_failed(pending)"));
}

/// The open-time repair gives a record to an admin's own removal only, and
/// a stored record is driven only through the entries named here: the live
/// plane while its session is in the foreground, the bridge's `*_driven`
/// entries, and the catch-up sweep.
///
/// A record restores its commit as pending at the next open; the circle's
/// sends wait and its inbound traffic is held unread, and only a drive ends
/// that. So the repair stays as narrow as it was: an admin's own removal is
/// dead on this device with or without a record, so its record costs
/// nothing; an eviction with no record leaves a circle that another member's
/// commit heals, and any other commit is cleared by MDK.
///
/// Whoever widens the repair or adds a way to the driver rewrites this gate
/// in that change: it fails on any change to which commits the repair
/// covers, and on any way to the driver other than those named here. They
/// are pinned by structure, not by a name scan a rename could pass:
///
/// * which files may import anything of the driver's at all, and exactly
///   what — no rename, no glob;
/// * in the live plane, the one function that builds a `Publishing`, with
///   the lifecycle's answer read before it;
/// * who runs that function (the session's drive task, and nothing else), and
///   who may ask for a run: a staging, and each caller that claims the
///   foreground — a start, a foreground open, the heal's claim, the health
///   tick;
/// * that the lifecycle answers yes for the foreground alone, that nothing
///   enters it but on its caller's claim (`Claim::Foreground`, which the
///   bridge makes from one `foreground` flag and nothing else names), and
///   that a pause and a stop leave it;
/// * that the sweep the bridge calls drives in the mode that makes no
///   commit.
#[test]
#[allow(clippy::too_many_lines)]
fn the_live_planes_foreground_is_the_one_product_driver_and_the_open_repairs_a_removal_only() {
    let squash = |text: &str| -> String { text.chars().filter(|c| !c.is_whitespace()).collect() };
    let session = production_source(&repo_root().join("haven-core/src/nostr/mls/manager.rs"));
    let repair = squash(
        fn_body(&session, "fn try_recordless_removals(")
            .expect("the open-time repair is try_recordless_removals"),
    );
    assert!(
        repair.contains(
            "letremoves=source==group.epoch.0&&store.own_commit_intent(&origin)?\
             .is_some_and(|intent|matches!(intent.intent,SendIntent::RemoveMembers{..}));\
             if!removes{ifstore.own_commit_intent(&origin)?.is_some(){let_=notes.note(\
             &group_id,ChangeNote::ChangeUndone);}continue;}"
        ) && repair.find("if!removes{") < repair.find("commit_fanout(")
            && repair.matches("continue;}").count() >= 1
            && !repair.contains("evicts"),
        "the open-time repair no longer covers an admin's own removal and nothing else: \
         widening it and giving every configuration a foreground drive are one change",
    );
    // A trial record takes a pending ref of its own making: the one place
    // one is made is the repair, so a second repair shows here.
    assert_eq!(
        squash(&session).matches("PendingStateRef::new(").count(),
        1,
        "a second function gives a commit found without a record one",
    );

    // Who names anything of the driver's module, and exactly what: a drive is
    // made of nothing but what `relay::fanout` exports, so a file that names
    // none of it cannot drive, under any name. Only the live plane's
    // processor names `Publishing`; nothing names a drive entry.
    let names: [(&str, &[&str]); 23] = [
        // `Still` is what a pass decided under, read again where the act is
        // made. The other names are its test seams'
        // (`#[cfg(any(test, feature = "test-utils"))]`), which drive as the
        // bridge does, over scripted transports.
        (
            "haven-core/src/circle/manager.rs",
            &[
                "DriveMode",
                "EvolutionOutcome",
                "EvolutionStatus",
                "FanoutClock",
                "FixedClock",
                "LOCATION_SEND_MS",
                "LocationSeal",
                "Publishing",
                "RecoveryCause",
                "Refusing",
                "RepairOutcome",
                "Still",
                "WallClock",
                "fanout_row_let_go_for_test",
                "scripted",
                "scripted::Accepting",
                "scripted::Inert",
                "scripted::Refusing",
                "scripted::{Accepting",
                "scripted::{FixedClock",
            ],
        ),
        (
            "haven-core/src/nostr/mls/manager.rs",
            &[
                "BurstEnd",
                "CONFIRM_ATTEMPTS",
                "DriveMode",
                "ModeSource",
                "RESTAGE_BASE_MS",
                "RETRY_MAX_MS",
                "Still",
                "interrupted",
                "own",
                "release",
            ],
        ),
        // The mesh key ring: how long one location send takes, a constant,
        // for the window a fellow member's update may be passed on in.
        (
            "haven-core/src/nostr/mls/manager/mesh.rs",
            &["LOCATION_SEND_MS"],
        ),
        // The sweep: read like every other file. What it may name of the
        // driver is this, and what it does with it is counted further down.
        (
            "haven-core/src/relay/catchup.rs",
            &[
                "BUSY_RETRY_MS",
                "DriveMode",
                "FanoutClock",
                "FanoutSend",
                "Publishing",
                "ResumeOutcome",
                "Still",
                "WallClock",
            ],
        ),
        (
            "haven-core/src/relay/live_sync/drive.rs",
            &[
                "DriveMode",
                "FanoutClock",
                "FanoutSend",
                "FanoutTargetOutcome",
                "ModeSource",
                "Taken",
                "UnrecordedPublisher",
                "WallClock",
                "interrupted",
            ],
        ),
        (
            "haven-core/src/relay/live_sync/processor.rs",
            &[
                "BUSY_RETRY_MS",
                "BurstEnd",
                "DriveMode",
                "FanoutClock",
                "ModeSource",
                "Publishing",
                "RESUME_BUDGET_MS",
                "ResumeOutcome",
                "Still",
                "WallClock",
                // Every wake the plane drives in is cut at its burst's end,
                // and a network return makes unreachable relays due.
                "wake_deadline",
                "wake_unreachable",
            ],
        ),
        (
            "haven-core/src/relay/live_sync/session.rs",
            &["RelayMappedFanout", "UnrecordedPublisher", "WallClock"],
        ),
        (
            "haven-core/src/relay/manager.rs",
            &[
                "FanoutSend",
                "FanoutTargetOutcome",
                "GATE_WAIT_SECS",
                "Taken",
                "is_owned",
                "not_exposed",
                "publish_to_target",
                "self",
            ],
        ),
        // The bridge's `*_driven` entries: each builds a `Publishing` over its
        // manager's own client and a `Claimed` mode, and calls one of the
        // driver's entries (`every_transport_holding_entry_drives_due_fanouts`
        // in the bridge pins which).
        (
            "haven/rust_builder/src/api.rs",
            &[
                "Claimed",
                "EvolutionOutcome",
                "EvolutionStatus",
                "EvolutionStatus as _",
                "FanoutClock",
                "LeaveOutcome",
                "LeaveStatus as _",
                "LocationPublish",
                "LocationPublish as _",
                "LocationSeal as _",
                "PollOutcome",
                "Publishing",
                "RESUME_BUDGET_MS",
                "RecoveryCause",
                "RecoveryCause as _",
                "Reinvite",
                "ReinviteResult as _",
                "RepairOutcome as _",
                "ResumeOutcome",
                "SealOutcome",
                "SendHeld",
                "SendHeld as _",
                "WallClock",
                "wake_deadline",
            ],
        ),
        // The soak rig is not shipped, and it is read all the same: what it
        // names of the driver is what a copy of it into the product would.
        (
            "tooling/soak/src/oracle/bounds.rs",
            &["AMBIGUOUS_RETRY_BASE_MS", "MDK_CALL_CEILING_SECS"],
        ),
        // Every commit the rig makes goes through the product's driver
        // (`rig/circle.rs` `DeviceDriver`, and the world's entries over it).
        (
            "tooling/soak/src/rig/circle.rs",
            &[
                "Claimed",
                "EvolutionStatus",
                "FanoutClock",
                "FanoutSend",
                "FanoutTargetOutcome",
                "Publishing",
                "RESUME_BUDGET_MS",
                "RelayMappedFanout",
                "Taken",
                "UnrecordedPublisher",
                "WallClock",
            ],
        ),
        ("tooling/soak/src/rig/device.rs", &["RelayMappedFanout"]),
        // The mesh plane turns a device's mesh on by the device's clock.
        (
            "tooling/soak/src/rig/mesh.rs",
            &["FanoutClock as _", "WallClock"],
        ),
        (
            "tooling/soak/src/rig/world.rs",
            &[
                "FanoutClock",
                "LeaveStatus",
                "LocationPublish",
                "PollOutcome",
                "ResumeOutcome",
                "SealOutcome",
                "WallClock",
            ],
        ),
        // The settle loop waits for a reopened device's own drive to let a
        // row go before stepping the clock; the seam drives nothing.
        (
            "tooling/soak/src/scenarios/mod.rs",
            &[
                "FanoutClock",
                "LocationSeal",
                "SendHeld",
                "fanout_row_let_go_for_test",
            ],
        ),
        (
            "tooling/soak/src/scenarios/s05_publish_confirm.rs",
            &["FanoutClock as _", "WallClock"],
        ),
        (
            "tooling/soak/src/scenarios/s14_restart_race.rs",
            &[
                "DriveMode",
                "FanoutClock",
                "FanoutStatus",
                "WallClock",
                "drive_due",
                "drive_one",
            ],
        ),
        (
            "tooling/soak/src/scenarios/s18_swallowed_ok.rs",
            &["LocationPublish", "LocationSeal", "SendHeld"],
        ),
        (
            "tooling/soak/src/scenarios/s19_duplicate_reorder.rs",
            &["FanoutClock as _", "WallClock"],
        ),
        (
            "tooling/soak/src/scenarios/s22_oversized_event.rs",
            &[
                "FanoutClock as _",
                "LocationSeal",
                "RETRY_MAX_MS",
                "SendHeld",
                "WallClock",
            ],
        ),
        (
            "tooling/soak/src/scenarios/s24_routing_collision.rs",
            &[
                "DriveMode",
                "FanoutClock as _",
                "FanoutStatus",
                "LeaveStatus",
                "LocationSeal",
                "WallClock",
                "drive_one",
            ],
        ),
        // The two mesh scenarios read the driver's answers; their sends and
        // their mesh drives are the world's entries over `DeviceDriver`.
        (
            "tooling/soak/src/scenarios/s27_mesh_independence.rs",
            &[
                "FanoutClock",
                "LocationPublish",
                "LocationSeal",
                "SendHeld",
                "WallClock",
            ],
        ),
        (
            "tooling/soak/src/scenarios/s28_member_bridging.rs",
            &["LocationPublish", "WallClock"],
        ),
    ];
    let files = scanned_sources();
    let root = repo_root().to_string_lossy().replace('\\', "/");
    let mut found = Vec::new();
    for file in &files {
        let name = file.to_string_lossy().replace('\\', "/");
        let name = name.trim_start_matches(&format!("{root}/")).to_string();
        if name.ends_with("relay/fanout.rs") {
            continue;
        }
        let source = production_source(file);
        let mut uses = names_after(&source, "fanout::");
        uses.sort();
        uses.dedup();
        if !uses.is_empty() {
            found.push((name.clone(), uses));
        }
        // The sweep declares two of these names itself; what it does with
        // them is counted at the end of this gate.
        if name.ends_with("relay/catchup.rs") {
            continue;
        }
        let text = squash(&source);
        for other_way in [
            "run_catchup_in_foreground",
            "run_catchup_driving",
            "ascatchup",
            "catchup::*",
            "fanoutas",
        ] {
            assert!(
                !text.contains(other_way),
                "{name} names `{other_way}`: a drive of stored records, or a module that has \
                 one under another name",
            );
        }
    }
    found.sort();
    let expected: Vec<(String, Vec<String>)> = names
        .iter()
        .map(|(file, items)| {
            (
                (*file).to_owned(),
                items.iter().map(|item| (*item).to_owned()).collect(),
            )
        })
        .collect();
    assert_eq!(
        found, expected,
        "what is found of the fanout driver's module, and by which file, has changed: a \
         renamed or glob import shows here as itself. The open-time repair and the \
         product's drives of stored records change together, in one change that rewrites \
         this gate",
    );

    // The live plane: one function builds a `Publishing`, and reads the
    // lifecycle first.
    let processor =
        production_source(&repo_root().join("haven-core/src/relay/live_sync/processor.rs"));
    let flat = squash(&processor);
    let drive = squash(
        fn_body(&processor, "pub(super) async fn drive_due(")
            .expect("processor.rs defines drive_due"),
    );
    assert_eq!(
        (
            flat.matches("Publishing{").count(),
            flat.matches(".settle_staged(").count(),
            flat.matches(".resume(").count(),
            drive.matches("Publishing{").count(),
            drive.matches(".settle_staged(").count(),
            drive.matches(".resume(").count(),
        ),
        (1, 1, 1, 1, 1, 1),
        "the live plane builds or uses a driver outside `drive_due`",
    );
    // The leash is built first and the pass begins on its word alone: the
    // lifecycle read apart from it could say yes to a pass whose leash then
    // read finish-only and, the foreground returning, full again. Whether
    // the pass takes what was kept for a full drive's one publish is read
    // from that same leash, once.
    let gate = drive
        .find(
            "letleash=Leash::over(&self.lifecycle,self.halt.clone());\
             if!leash.runs(){return;}",
        )
        .expect("the live plane's drive must ask its leash whether it may run");
    assert!(
        drive.contains("letfull=leash.mode()==DriveMode::Full;")
            // The pass's budget, which a burst's measured end only narrows
            // (`relay::fanout::wake_deadline`, the bridge's too).
            && drive.contains(
                "letdeadline_ms=crate::relay::fanout::wake_deadline(&self.circle,clock,RESUME_BUDGET_MS);"
            )
            // Declared once: nothing else writes it.
            && drive.matches("deadline_ms=").count() == 1
            && drive.contains("deadline_ms:Some(deadline_ms),mode:&leash,")
            && drive.contains(
                "letproposals=iffull{std::mem::take(&mut*self.unrecorded.lock()\
             .unwrap_or_else(PoisonError::into_inner),)}else{Vec::new()};"
            )
            && drive.matches("leash.mode()").count() == 1,
        "a pass that only finishes takes what was kept for a full drive's one publish, \
         or reads its mode again to widen",
    );
    assert!(
        gate < drive.find("Publishing{").expect("counted above")
            && gate
                < drive
                    .find("attempt_queued_changes(")
                    .expect("the queue's attempt")
            && !drive.contains("self.lifecycle.get()")
            && drive.matches("letleash=").count() == 1
            // Four leashes in the plane, each taken where its pass begins:
            // the drive's; the one a staging hold keeps what it could not
            // record under; and the ones a full advance and a staging
            // ingest read again once they have the engine.
            && flat.matches("Leash::over(").count() == 4
            && squash(fn_body(&processor, "async fn advance(").expect("advance")).contains(
                "DriveMode::Full=>{letleash=Leash::over(&self.lifecycle,None);session\
                 .advance_for_drive_while(group_id,now_ms,Still::new(&leash,DriveMode::Full))\
                 .await}"
            ),
        "the live plane's drive does something before it has asked its leash, reads the \
         lifecycle apart from it, or rebinds the leash it hands its driver; or a pass of the \
         plane's runs on no leash of its own",
    );
    assert!(
        drive.find("self.in_flight_publishes.fetch_add(1,Ordering::SeqCst)") < Some(gate),
        "the drive must be counted before it reads the lifecycle: a pause flips the \
         lifecycle and then waits on that count",
    );
    let stages = squash(fn_body(&processor, "fn staging(").expect("processor.rs defines staging"));
    assert!(
        stages == "{(self.now_ms(),self.lifecycle.get().receives())}"
            && flat.matches(".process_event_staging(").count() == 1
            && flat.matches(".advance_for_drive(").count() == 0
            && flat.matches(".advance_for_drive_while(").count() == 1
            && flat.matches(".settle_inputs_for_drive(").count() == 1
            && flat.matches(".fold_staged(").count() == 1
            // The come-back after an open is the one place a mode is given
            // that the lifecycle's own answer is not: inputs only in any
            // lifecycle, an eviction left due being the drive's alone.
            && squash(
                fn_body(&processor, "pub(super) async fn come_back_if_owed(&self)")
                    .expect("processor.rs defines the come-back"),
            )
            .contains("self.drain_open_advance_as((self.now_ms(),DriveMode::FinishOnly)).await;")
            && flat.matches("DriveMode::FinishOnly").count() == 2,
        "the live plane records what it stages somewhere the lifecycle did not decide",
    );
    // The mode the lifecycle answered with is the one each staging call is
    // made in: the full advance is the full mode's alone, and the plane that
    // makes no commit advances inputs only.
    let advance =
        squash(fn_body(&processor, "async fn advance(").expect("processor.rs defines advance"));
    assert!(
        advance.contains(
            "matchmode{DriveMode::Full=>{letleash=Leash::over(&self.lifecycle,None);session\
             .advance_for_drive_while(group_id,now_ms,Still::new(&leash,DriveMode::Full))\
             .await}\
             DriveMode::FinishOnly=>session.settle_inputs_for_drive(group_id,now_ms).await,}"
        ) && squash(fn_body(&processor, "async fn ingest(").expect("processor.rs defines ingest"))
            .contains(
                "letbegan=Leash::over(&self.lifecycle,None);self.circle.session()\
                 .process_event_staging(event,now_ms,Still::new(&began,mode)).await"
            )
            && squash(fn_body(&processor, "async fn resolve(").expect("resolve"))
                .contains(".fold_staged(unrecorded,false,now_ms,Still::new(&began,mode))"),
        "a staging call of the live plane is made in a mode other than its lifecycle's",
    );

    // The lifecycle itself: the full mode for the foreground alone, in both
    // questions. A burst and a session only started receive and drive in
    // the mode that only finishes; a pause receives what is still in flight
    // in it and drives nothing.
    let lifecycle = production_source(&repo_root().join("haven-core/src/relay/live_sync/drive.rs"));
    for (question, answer) in [
        (
            "pub const fn receives(self)",
            "{matchself{Self::Foreground=>DriveMode::Full,\
             Self::Launched|Self::Burst|Self::Background=>DriveMode::FinishOnly,}}",
        ),
        (
            "pub const fn drives(self)",
            "{matchself{Self::Foreground=>Some(DriveMode::Full),\
             Self::Launched|Self::Burst=>Some(DriveMode::FinishOnly),\
             Self::Background=>None,}}",
        ),
    ] {
        assert_eq!(
            squash(fn_body(&lifecycle, question).expect(question)),
            answer,
            "{question} no longer answers the full mode for the foreground alone: a \
             background lifecycle that stages under a record or begins a full drive is a \
             change to this gate, the manifest and the reviews, not to one line",
        );
    }
    assert_eq!(
        squash(&lifecycle).matches("DriveMode::Full").count(),
        5,
        "the full mode is named in the live plane's lifecycle and leash somewhere this \
         gate does not pin",
    );
    // Everything that writes the lifecycle, or reads it back: a writer whose
    // arms were swapped would put a burst in the foreground under every pin
    // above.
    for (source, signature, body) in [
        (
            &lifecycle,
            "pub(super) const fn new()",
            "{Self{state:AtomicU8::new(Lifecycle::Launchedasu8),changes:AtomicU64::new(0),}}",
        ),
        (
            &lifecycle,
            "pub(super) fn get(&self)",
            "{matchself.state.load(Ordering::SeqCst){xifx==Lifecycle::Foregroundasu8=>\
             Lifecycle::Foreground,xifx==Lifecycle::Burstasu8=>Lifecycle::Burst,\
             xifx==Lifecycle::Backgroundasu8=>Lifecycle::Background,\
             _=>Lifecycle::Launched,}}",
        ),
        (
            &lifecycle,
            "pub(super) fn prove_foreground(&self)",
            "{letproven=self.state.compare_exchange(Lifecycle::Launchedasu8,\
             Lifecycle::Foregroundasu8,Ordering::SeqCst,Ordering::SeqCst,).is_ok();\
             ifproven{self.changes.fetch_add(1,Ordering::SeqCst);}proven}",
        ),
        // Every change counts, whichever way: a pass belongs to the stretch
        // it began in, so a burst paused, a started session claimed and a
        // foreground ended each end the passes begun before them.
        (
            &lifecycle,
            "pub(super) fn set(&self, lifecycle: Lifecycle)",
            "{letwas=self.state.swap(lifecycleasu8,Ordering::SeqCst);\
             ifwas!=lifecycleasu8{self.changes.fetch_add(1,Ordering::SeqCst);}}",
        ),
        (
            &lifecycle,
            "pub(super) fn changes(&self)",
            "{self.changes.load(Ordering::SeqCst)}",
        ),
        // The one writer on the processor: it tells the session's legacy
        // holds where the plane now stands — FIRST on the way into a
        // lifecycle that makes no commit and LAST on the way out of one, so
        // no legacy hold finds the lifecycle narrowed and the session not
        // yet told.
        (
            &processor,
            "fn enter(&self, lifecycle: Lifecycle)",
            "{letstanding=matchlifecycle{Lifecycle::Launched=>PlaneStanding::Launched,\
             Lifecycle::Foreground=>PlaneStanding::Foreground,\
             Lifecycle::Burst|Lifecycle::Background=>PlaneStanding::MakesNone,};\
             letnarrows=standing==PlaneStanding::MakesNone;\
             ifnarrows{self.circle.session().plane_stands(self.plane,standing);}\
             iflifecycle!=Lifecycle::Burst{self.circle.session().burst_ends(self.plane,None);}\
             self.lifecycle.set(lifecycle);\
             if!narrows{self.circle.session().plane_stands(self.plane,standing);}}",
        ),
        (
            &processor,
            "pub(super) fn note_launched(&self)",
            "{self.enter(Lifecycle::Launched);}",
        ),
        (
            &processor,
            "pub(super) fn prove_foreground(&self)",
            "{letproven=self.lifecycle.prove_foreground();\
             ifproven{self.circle.session().plane_claimed(self.plane);}proven}",
        ),
        (
            &processor,
            "pub(super) fn leave_foreground(&self)",
            "{self.enter(Lifecycle::Background);\
             self.forget_what_only_the_foreground_does();}",
        ),
        (
            &processor,
            "pub(super) fn set_background_burst(&self, background: bool)",
            "{self.enter(ifbackground{Lifecycle::Burst}else{Lifecycle::Foreground});\
             ifbackground{self.forget_what_only_the_foreground_does();}}",
        ),
    ] {
        assert_eq!(
            squash(fn_body(source, signature).expect(signature)),
            body,
            "{signature} writes or reads the session's lifecycle differently",
        );
    }
    assert_eq!(
        (
            flat.matches("self.lifecycle.set(").count(),
            flat.matches("self.enter(").count(),
            flat.matches("self.lifecycle.prove_foreground()").count(),
            squash(&lifecycle).matches("self.state.").count(),
            flat.matches(".plane_stands(").count() + flat.matches(".plane_claimed(").count(),
        ),
        (1, 3, 1, 3, 4),
        "the session's lifecycle is written from somewhere this gate does not pin, or the \
         session's legacy holds are told of it from somewhere else",
    );
    // The writers, and the drive, are the SESSION's: each can put a
    // processor in the foreground, or drive one, with no claim, so none is
    // callable from outside `live_sync` in a shipped build, and across every
    // scanned tree each is called where this gate names and nowhere else.
    // The one way in from outside is the test seam, which no shipped build
    // has.
    let writers = [
        ("note_launched", "pub(super) fn note_launched(&self)"),
        ("prove_foreground", "pub(super) fn prove_foreground(&self)"),
        ("leave_foreground", "pub(super) fn leave_foreground(&self)"),
        (
            "set_background_burst",
            "pub(super) fn set_background_burst(&self, background: bool)",
        ),
        ("request_drive", "pub(super) fn request_drive(&self)"),
        ("drive_due", "pub(super) async fn drive_due(&self)"),
    ];
    let root = repo_root().to_string_lossy().replace('\\', "/");
    let mut called: Vec<(String, &str, usize)> = Vec::new();
    for (writer, declared) in writers {
        assert!(
            processor.contains(declared)
                && processor.matches(&format!("fn {writer}(")).count() == 2,
            "`{writer}` is callable from outside the live-sync module, or declared \
             somewhere but on the processor and its test seam",
        );
        for file in scanned_sources() {
            let name = file.to_string_lossy().replace('\\', "/");
            let name = name.trim_start_matches(&format!("{root}/")).to_owned();
            let calls = squash(&production_source(&file))
                .matches(&format!(".{writer}("))
                .count();
            if calls > 0 {
                called.push((name, writer, calls));
            }
        }
    }
    let seam = processor
        .find("pub const fn for_test(&self) -> SessionsPart<'_>")
        .expect("the processor's test seam");
    assert!(
        processor[..seam]
            .trim_end()
            .ends_with("#[cfg(any(test, feature = \"test-utils\"))]\n    #[must_use]")
            && processor.matches("SessionsPart(self)").count() == 1
            && processor
                .matches("#[cfg(any(test, feature = \"test-utils\"))]\nimpl SessionsPart<'_>")
                .count()
                == 1,
        "the session's part of the processor is handed out in a shipped build",
    );
    assert_eq!(
        called,
        // In the processor: the test seam's own hand-on of each, the
        // lifecycle cell's compare-and-swap, the worker's request for a
        // drive once it has staged something, and a network return's, at most
        // once a minute and only in a lifecycle that drives on a timer
        // (`network_back`). In the session: the start's
        // tail; the one place a claim is taken; a stop, a pause and a failed
        // open; the one open; the seven who ask for a drive — a start, a start
        // into a burst, a session served as the foreground's, a background
        // open, a health tick whose claim promoted nothing, and a release of
        // relays silent past `EOSE_WAIT` or a narrowing to the relays that
        // took a REQ connected, either completing a circle's coverage as an
        // `EOSE` does; and the drive task. In
        // the worker: the drive asked for once every relay of a group
        // subscription has sent its end of stored events, which is when an
        // eviction left due may first be staged.
        [
            ("processor.rs", "note_launched", 1),
            ("session.rs", "note_launched", 1),
            ("processor.rs", "prove_foreground", 2),
            ("session.rs", "prove_foreground", 1),
            ("processor.rs", "leave_foreground", 1),
            ("session.rs", "leave_foreground", 3),
            ("processor.rs", "set_background_burst", 1),
            ("session.rs", "set_background_burst", 1),
            ("processor.rs", "request_drive", 3),
            ("session.rs", "request_drive", 7),
            ("supervisor.rs", "request_drive", 1),
            ("processor.rs", "drive_due", 1),
            ("session.rs", "drive_due", 1),
        ]
        .map(|(file, writer, calls)| {
            (
                format!("haven-core/src/relay/live_sync/{file}"),
                writer,
                calls,
            )
        }),
        "a writer of the session's lifecycle, or its drive, is called from somewhere this \
         gate does not name",
    );
    // A leash is taken in the mode its lifecycle drives in and belongs to
    // that stretch of it: it reads full only if it began full and nothing
    // has changed since, so it can narrow and never widen, and one taken in
    // a burst or a started session never reads full at all. Once its
    // lifecycle has changed the pass takes no relay and has no budget left
    // (`ModeSource::stands`, pinned with the driver below); what has no
    // record is published only while it reads full; and the attempt of a
    // queued change reads it before each circle's advance.
    let leash = squash(&lifecycle);
    assert!(
        leash.contains(
            "implModeSourceforLeash<'_>{fnmode(&self)->DriveMode{matchself.began{\
             Some((DriveMode::Full,at))ifat==self.lifecycle.changes()=>DriveMode::Full,\
             _=>DriveMode::FinishOnly,}}\
             fnstands(&self)->bool{self.began.is_some_and(|(_,at)|at==self.lifecycle.changes())}}"
        ) && leash.contains(
            "pub(super)fnover(lifecycle:&'aLifecycleCell,halt:Option<watch::Receiver<bool>>)->Self{\
             letchanges=lifecycle.changes();\
             letbegan=lifecycle.get().drives().map(|mode|(mode,changes));\
             Self{lifecycle,halt,began,}}"
        ) && leash.contains("pub(super)constfnruns(&self)->bool{self.began.is_some()}")
            && leash.contains(
                "asyncfntake(&self,target:&str)->Option<Taken>{\
                 if!self.leash.stands(){returnNone;}"
            )
            && leash.contains("taken.filter(|_|self.leash.stands())")
            && leash
                .matches("ifself.leash.mode()!=DriveMode::Full{returnfalse;}")
                .count()
                == 1
            && leash.matches("began").count() == 6
            && drive.contains("letleash=Leash::over(&self.lifecycle,self.halt.clone());")
            && drive.contains("mode:&leash,")
            && drive.contains("self.attempt_queued_changes(clock.now_ms(),&leash).await;"),
        "a pass under way when its lifecycle changes still takes a relay or publishes what \
         has no record, or a leash can widen",
    );
    // And the driver gives a pass that no longer stands no budget: no
    // confirm of a stored acknowledgement and no call is begun by it.
    let fanout = production_source(&repo_root().join("haven-core/src/relay/fanout.rs"));
    let drive_one_row =
        squash(fn_body(&fanout, "async fn drive<T: FanoutSend + ?Sized>(").expect("fanout drive"));
    assert!(
        squash(fn_body(&fanout, "fn budget(").expect("fanout.rs defines budget"))
            == "{ifmode.stands(){deadline_ms}else{Some(0)}}"
            && squash(&fanout).contains("fnstands(&self)->bool{true}")
            && drive_one_row.matches("budget(mode,deadline_ms)").count() == 3
            && drive_one_row
                .matches(
                    "send_what_is_due(circle,transport,clock,deadline_ms,mode,before,&mutfanout,)"
                )
                .count()
                == 1
            // Three times through `budget`, twice as a step's field name,
            // and once raw: the calls already out keep their wake's end.
            && drive_one_row.matches("deadline_ms").count() == 6
            // Each step carries where its mode was read, for the act it
            // decides on to read again with the engine held.
            && drive_one_row.matches("source:mode,").count() == 2,
        "a step of the drive reads the wake's end past the pass's standing: a pass that \
         outlived its lifecycle would begin a confirm or a call",
    );
    // No act that may not outlive the lifecycle it was decided under is made
    // on a mode read before the wait for the engine: the bound, a confirm, a
    // rollback and a Welcome's hand-over each read it again with the engine
    // held, and are not made when it no longer holds.
    let fanout_flat = squash(&fanout);
    let session_flat = squash(&production_source(
        &repo_root().join("haven-core/src/nostr/mls/manager.rs"),
    ));
    let settle = squash(fn_body(&fanout, "async fn settle(").expect("fanout.rs defines settle"));
    assert!(
        fanout_flat.contains(
            "pub(crate)fnholds(&self)->bool{self.source.stands()&&self.source.mode()==self.decided}"
        ) && settle.contains("letstill=Still::new(step.source,mode);")
            && settle.contains(
                "ifat_its_bound&&!end_untaken_targets(session,fanout,clock,still).await?{\
                 returnOk(Settled::Inert);}"
            )
            && squash(
                fn_body(&fanout, "async fn end_untaken_targets(")
                    .expect("fanout.rs defines end_untaken_targets"),
            )
            .contains("if!session.put_fanout_while(fanout,still).await?{returnOk(false);}")
            && settle.contains(
                "letSome(resolution)=circle.confirm_fanout(fanout,clock.now_ms(),mode,still)\
                 .awaitelse{returnOk(Settled::Inert);};"
            )
            && settle.contains(
                "letSome(resolution)=circle.roll_back_fanout(fanout,clock.now_ms(),still)\
                 .awaitelse{returnOk(Settled::Inert);};"
            )
            && settle.contains(
                "letSome(handed)=session.hand_over_welcomes(fanout,clock.now_ms(),still)\
                 .await?else{returnOk(Settled::Inert);};"
            )
            && session_flat.matches("if!still.holds(){").count() == 5
            && [
                "pub(crate) async fn put_fanout_while(",
                "pub(crate) async fn confirm_fanout(",
                "pub(crate) async fn roll_back_fanout(",
                "pub(crate) async fn hand_over_welcomes(",
                "pub(crate) async fn advance_for_drive_while(",
            ]
            .iter()
            .all(|entry| {
                let body = squash(
                    fn_body(
                        &production_source(
                            &repo_root().join("haven-core/src/nostr/mls/manager.rs"),
                        ),
                        entry,
                    )
                    .unwrap_or_else(|| panic!("manager.rs defines {entry}")),
                );
                // Held first — the engine, or the session's lock — then read.
                body.find("self.engine().await")
                    .or_else(|| body.find("self.reading().await"))
                    .zip(body.find("if!still.holds(){"))
                    .is_some_and(|(held, read)| held < read)
            }),
        "an act of a pass is made on a mode read before it waited for the engine: a \
         rollback, the bound, a confirm, a Welcome's hand-over or a full advance could be \
         made behind a pause",
    );
    // What a hold hands back for the drive is kept only while the foreground
    // it began under stands, read under the lock the end of the foreground
    // clears under.
    let resolve =
        squash(fn_body(&processor, "async fn resolve(").expect("processor.rs defines resolve"));
    assert!(
        resolve.find("letbegan=Leash::over(&self.lifecycle,None);") < resolve.find(".fold_staged(")
            && resolve.contains("self.keep_for_the_drive(&began,handed_back.proposals);")
            && squash(fn_body(&processor, "fn keep_for_the_drive(").expect("keep_for_the_drive"))
                == "{letmutkept=self.unrecorded.lock().unwrap_or_else(PoisonError::into_inner);\
                  ifbegan.mode()==DriveMode::Full{kept.extend(proposals);}}"
            && flat.matches("self.unrecorded.lock()").count() == 3,
        "a proposal handed back after the foreground ended is kept for a later one, or \
         something else writes what is kept for the drive",
    );
    let attempt = squash(
        fn_body(&processor, "async fn attempt_queued_changes(")
            .expect("processor.rs defines attempt_queued_changes"),
    );
    assert!(
        attempt.find("ifpass.mode()!=DriveMode::Full{break;}")
            < attempt.find(".drain_convergence("),
        "a queued change is attempted without the pass's mode being read first",
    );

    // Who runs a drive, who asks for one, and who claims the foreground.
    let core = production_source(&repo_root().join("haven-core/src/relay/live_sync/session.rs"));
    let core_flat = squash(&core);
    assert_eq!(
        (
            core_flat.matches(".drive_due()").count(),
            squash(fn_body(&core, "async fn run_drive(").expect("session.rs defines run_drive"))
                .matches(".drive_due()")
                .count(),
            core_flat.matches("run_drive(").count(),
            squash(fn_body(&core, "fn spawn_supervisor(").expect("spawn_supervisor"))
                .matches("tokio::spawn(run_drive(")
                .count(),
        ),
        (1, 1, 2, 1),
        "a drive is run from somewhere other than the session's one drive task",
    );
    let resume =
        squash(fn_body(&core, "async fn resume_burst(").expect("session.rs defines resume_burst"));
    let health = squash(
        fn_body(&core, "pub async fn maintain_subscription_health(")
            .expect("session.rs defines maintain_subscription_health"),
    );
    let take_claim =
        squash(fn_body(&core, "fn take_claim(").expect("session.rs defines take_claim"));
    let serve = squash(
        fn_body(&core, "fn serve_the_foreground(")
            .expect("session.rs defines serve_the_foreground"),
    );
    let start = squash(fn_body(&core, "async fn start_in(").expect("session.rs defines start_in"));
    let begin =
        squash(fn_body(&core, "fn begin_started(").expect("session.rs defines begin_started"));
    // The release's own body: the method hands it to the free function the
    // repair task and a burst's wait share.
    let release = squash(
        fn_body(&core, "async fn release_silent_relays(\n")
            .expect("session.rs defines release_silent_relays"),
    );
    // A narrowing to the relays that took a REQ connected, when every one of
    // them had already answered: no later `EOSE` asks for that drive.
    let cover = squash(fn_body(&core, "async fn cover(").expect("session.rs defines cover"));
    assert_eq!(
        (
            core_flat.matches(".request_drive()").count(),
            release.matches(".request_drive()").count(),
            cover.matches(".request_drive()").count(),
            begin.matches(".request_drive()").count(),
            serve.matches(".request_drive()").count(),
            resume.matches(".request_drive()").count(),
            health.matches(".request_drive()").count(),
            start.matches(".request_drive()").count(),
            core_flat.matches(".prove_foreground()").count(),
            take_claim.matches(".prove_foreground()").count(),
            core_flat.matches(".set_background_burst(").count(),
        ),
        (7, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1),
        "a drive is asked for, or the foreground entered, somewhere this gate does not \
         name",
    );
    // The foreground is entered on a caller's claim and on nothing else. The
    // three ways in, each behind `Claim::Foreground`:
    //
    // 1. a session that was only started, by the claim its caller makes once
    //    the start has returned — and never one a stop has overtaken. The
    //    claim that promotes is served as the foreground's, once: a circle
    //    that can no longer move is named, and a drive is asked for;
    assert_eq!(
        take_claim,
        "{claim==Claim::Foreground&&!self.shutdown.load(Ordering::Acquire)\
         &&self.processor.prove_foreground()}",
        "a claim is taken without the claim, or behind a stop",
    );
    // Nothing in it waits: it runs under the lifecycle lock, which a pause
    // and a stop take first. The publishes it owes are the drive's to make,
    // and so is the entry's one NIP-77 pass, owed here and nowhere else.
    assert_eq!(
        core_flat.matches(".owe_negentropy()").count(),
        1,
        "a NIP-77 pass is owed somewhere other than a foreground entry",
    );
    assert_eq!(
        serve, "{self.processor.owe_negentropy();self.processor.request_drive();}",
        "a session that has become the foreground's is not served as one: no drive is asked \
         for — or it publishes under the lifecycle lock",
    );
    assert_eq!(
        (
            core_flat.matches("self.take_claim(claim)").count(),
            core_flat.matches("self.serve_the_foreground()").count(),
            squash(fn_body(&core, "pub async fn claim_foreground(").expect("claim_foreground")),
        ),
        (
            2,
            3,
            "{let_lifecycle=self.lifecycle.lock().await;\
             ifself.take_claim(claim){self.serve_the_foreground();}}"
                .to_owned(),
        ),
        "a claim is taken somewhere other than the claim's own entry and the health tick, \
         or outside the lifecycle lock, or a session is served as the foreground's with no \
         claim behind it",
    );
    // 2. the health tick, for the session and for its drive: a tick whose
    //    claim promoted nothing asks for a drive and nothing more;
    assert!(
        health.contains(
            "ifself.take_claim(claim){self.serve_the_foreground();}\
             elseifclaim==Claim::Foreground{self.processor.request_drive();}drop(lifecycle);"
        ),
        "the health tick enters the foreground, or asks for a drive, without its \
         caller's claim",
    );
    // 3. a foreground open, whose kind exists only for a caller that claims:
    //    nothing names it but the one constructor and the open's own reads.
    assert_eq!(
        (
            squash(fn_body(&core, "const fn claimed(").expect("BurstKind::claimed")),
            core_flat.matches("BurstKind::claimed(claim)").count(),
            core_flat.matches("Self::Foreground").count(),
            core_flat.matches("BurstKind::Background,").count(),
            core_flat.matches("self.resume_burst(").count(),
        ),
        (
            "{matchclaim{Claim::Foreground=>Some(Self::Foreground),Claim::Nothing=>None,}}"
                .to_owned(),
            3,
            1,
            // The two background opens, a start into a burst entering it, and
            // that start's read of the inbox fold.
            4,
            5,
        ),
        "the foreground kind of an open is made without a claim, or an open has a \
         caller this gate does not name",
    );
    // The third reading of a claim's kind opens nothing: the health tick moves a
    // circle onto its routing only for a caller that claims the foreground, under
    // the acquisition that has read the pause, never ahead of its probe.
    let follow =
        "ifBurstKind::claimed(claim).is_some(){self.repair_plane().follow_routing_locked().await;}";
    assert!(
        health.matches(follow).count() == 1
            && health
                .find(
                    "letlifecycle=self.lifecycle.lock().await;\
                     ifself.paused.load(Ordering::Acquire){returnOk(SubscriptionHealthOutcome::paused());}"
                )
                .zip(health.find(follow))
                .is_some_and(|(read, followed)| read < followed)
            && !health.contains("self.follow_routing()"),
        "the routing is followed by a health tick whose caller claims nothing, outside \
         the lock a pause takes, or ahead of the probe",
    );
    // The burst opens: the old one gives no budget; the one that carries the
    // caller's measured budget measures it from the call and sets it as the
    // burst is entered, under the lock — a pause holding the lock first
    // writes a lifecycle that would clear it.
    assert_eq!(
        (
            squash(fn_body(&core, "pub async fn open_background_burst(").expect("open")),
            squash(fn_body(&core, "pub async fn open_background_burst_within(").expect("within")),
            squash(fn_body(&core, "fn enter_burst(").expect("enter_burst"))
                .starts_with("{self.processor.set_burst_end(ends);"),
            core_flat.matches("set_burst_end(").count(),
        ),
        (
            "{letlifecycle=self.lifecycle.lock().await;\
             self.resume_burst(&lifecycle,BurstKind::Background,INBOX_BURSTS_PER_REQ,None,).await}"
                .to_owned(),
            "{letends=self.processor.burst_end(Some(budget_ms));\
             letlifecycle=self.lifecycle.lock().await;\
             self.resume_burst(&lifecycle,BurstKind::Background,INBOX_BURSTS_PER_REQ,ends,).await}"
                .to_owned(),
            true,
            1,
        ),
        "a background open is made other than as a burst, with another burst's budget, or \
         with its budget set outside the lock",
    );
    assert_eq!(
        squash(
            fn_body(&core, "pub async fn resume_after_background(")
                .expect("session.rs defines resume_after_background")
        ),
        "{letSome(kind)=BurstKind::claimed(claim)else{returnErr(LiveSyncError::NotForeground);};\
         letlifecycle=self.lifecycle.lock().await;\
         self.resume_burst(&lifecycle,kind,INBOX_BURSTS_PER_REQ,None).await}",
        "the foreground re-anchor is made for a caller that claimed nothing, or touches \
         the session before it has refused one",
    );
    assert!(
        health.contains(
            "matchBurstKind::claimed(claim){Some(kind)=>{self.resume_burst(&lifecycle,kind,\
             INBOX_BURSTS_PER_REQ,None).await?;HealthAction::Resubscribed}\
             None=>HealthAction::AwaitingForeground,}"
        ),
        "the health tick's whole-session repair is made without its caller's claim, or \
         reports a health it did not find",
    );
    // An open is served as the foreground's only when its kind is the
    // foreground's; a background burst's open asks for its drive, which the
    // leash holds to the mode that only finishes.
    assert!(
        resume.ends_with(
            "ifmatches!(kind,BurstKind::Foreground){self.serve_the_foreground();}\
             else{self.processor.request_drive();}Ok(())}"
        ) && !resume.contains("report_unrecoverable_circles"),
        "a background burst's open reports a circle, or a foreground open is not served as \
         one",
    );
    assert!(
        health.find(
            "ifself.paused.load(Ordering::Acquire){returnOk(SubscriptionHealthOutcome::paused());}"
        ) < health.find("self.take_claim(claim)")
            && health.rfind("self.lifecycle.lock().await") < health.find("self.take_claim(claim)"),
        "the health tick claims the foreground for a paused session, or outside the lock \
         a pause takes",
    );
    // The come-back an open owes is owed before its first REQ: the worker
    // takes it at the open's first relay EOSE, which can beat the subscribe.
    assert!(
        start
            .find("ifburst{self.processor.owe_come_back();}")
            .zip(start.find("self.register_and_subscribe("))
            .is_some_and(|(owed, issued)| owed < issued)
            && resume
                .find("self.processor.owe_come_back();")
                .zip(resume.find("self.register_and_subscribe("))
                .is_some_and(|(owed, issued)| owed < issued)
            && start.matches("owe_come_back").count() == 1
            && resume.matches("owe_come_back").count() == 1,
        "an open owes its come-back after its REQs went out: a relay's EOSE that comes \
         first finds none owed, and the circle is not come back for",
    );
    assert!(
        start.ends_with(
            "ifburst{self.processor.request_drive();}\
             elseif!self.shutdown.load(Ordering::Acquire){self.begin_started();}Ok(())}"
        )
            // A start into a burst is in the burst from before its first socket.
            && start
                .find("ifburst{self.enter_burst(BurstKind::Background,ends)?;}")
                .zip(start.find("self.client.connect().await;"))
                .is_some_and(|(burst, connect)| burst < connect)
            && squash(fn_body(&core, "pub async fn start(").expect("start"))
                == "{self.start_in(circles,inbox_relays,false,None).await}"
            && squash(fn_body(&core, "pub async fn start_into_burst(").expect("start_into_burst"))
                == "{letends=self.processor.burst_end(budget_ms);\
                    self.start_in(circles,inbox_relays,true,ends).await}"
            && begin == "{self.processor.note_launched();self.processor.request_drive();}"
            && core_flat.matches("self.begin_started()").count() == 1
            && !start.contains("set_background_burst")
            && !start.contains("prove_foreground")
            && !start.contains("serve_the_foreground")
            && !start.contains("laim")
            && squash(&core).contains(
                "pubasyncfnstart(&self,circles:&[CircleSpec],inbox_relays:&[String],)\
                 ->LiveSyncResult<()>{"
            ),
        "`start` enters the foreground, is served as one or takes a claim: it takes \
         seconds, cannot tell a foreground launch from a background wake that \
         cold-launched the process, and leaves a session only started — whose one \
         drive only finishes — and never behind a stop that has just ended it",
    );
    let pause = squash(&pause_body(&core));
    assert!(
        pause.find("self.processor.leave_foreground();")
            < pause.find("self.processor.wait_publishes_drained().await;")
            && pause.find("self.terminate_all_relays().await;")
                < pause.find("self.close_drive_pool().await;"),
        "a pause must end the foreground before it waits for the drive under way, and \
         close the drive's pool only after that wait",
    );
    // `stop` is its bounded body (`stop_within`), and nothing else.
    assert_eq!(
        squash(fn_body(&core, "pub async fn stop(").expect("session.rs defines stop")),
        "{self.stop_within(Self::STOP_LOCK_BUDGET).await}",
    );
    let stop =
        squash(fn_body(&core, "async fn stop_within(").expect("session.rs defines stop_within"));
    assert!(
        stop.contains("self.processor.leave_foreground();")
            && stop.find("self.processor.leave_foreground();")
                < stop.find("self.cancel_tx.send_replace(true);"),
        "a stop must end the foreground before it cancels the drive under way",
    );
    assert_eq!(
        core_flat.matches("BurstKind::Foreground,").count(),
        0,
        "a caller opens the session as the foreground by naming the kind itself",
    );
    // Wherever the foreground kind can be named at all.
    let foreground_kinds: Vec<(String, usize)> = scanned_sources()
        .iter()
        .filter_map(|file| {
            let count = production_source(file)
                .matches("BurstKind::Foreground")
                .count();
            let name = file.to_string_lossy().replace('\\', "/");
            (count > 0).then(|| {
                (
                    name.trim_start_matches(&format!("{root}/")).to_owned(),
                    count,
                )
            })
        })
        .collect();
    assert_eq!(
        foreground_kinds,
        [("haven-core/src/relay/live_sync/session.rs".to_owned(), 2)],
        "the foreground kind of a burst is named somewhere new",
    );
    // The timer: the drive task wakes itself on the last drive's own hint.
    let run = squash(fn_body(&core, "async fn run_drive(").expect("checked"));
    assert!(
        run.contains("()=processor.drive_requested()=>{}()=processor.drive_due_again()=>{}}processor.drive_due().await;"),
        "the drive task no longer wakes on a request and on its own hint alone",
    );
    let timer = squash(
        fn_body(&processor, "pub async fn drive_due_again(")
            .expect("processor.rs defines drive_due_again"),
    );
    assert!(
        // In the foreground and inside a burst, which a pause ends: a session
        // only started runs the one drive its start asks for, and a timer
        // there would be a standing contact with a relay from a process
        // nobody may be looking at.
        timer.contains(
            "(Some(driver),Some(at_ms))ifmatches!(self.lifecycle.get(),\
             Lifecycle::Foreground|Lifecycle::Burst)=>"
        ) && drive.contains(
                ".filter(|wait|*wait>0).map(|wait|{clock.now_ms().saturating_add(wait.max(DRIVE_TIMER_FLOOR_MS))});"
            ),
        "the drive timer arms in a session only started or in a pause, on a hint of zero, or \
         below its floor",
    );

    the_drivers_public_surface_is_pinned();
    every_driver_is_given_its_mode_by_name();
    the_rig_drives_as_the_bridge_does();
    // The poll plane's and the location send's entries on the driver are
    // called by the bridge's `*_driven` entries alone, once each, on the
    // `Claimed` mode their caller's word makes — and by nothing else, in any
    // spelling, in any tree.
    for file in scanned_sources() {
        let name = file.to_string_lossy().replace('\\', "/");
        if name.ends_with("relay/fanout.rs") {
            continue;
        }
        let text = squash(&production_source(&file));
        if name.ends_with("haven/rust_builder/src/api.rs") {
            assert!(
                text.matches(".ingest_for_poll(").count() == 1
                    && text.matches(".seal_location(").count() == 1
                    && !text.contains("::ingest_for_poll")
                    && !text.contains("::seal_location"),
                "the bridge reaches the driver's poll or send entry beside its `*_driven` one",
            );
            continue;
        }
        // The circle manager's test seams, over scripted transports.
        if name.ends_with("haven-core/src/circle/manager.rs") {
            let plain = production_source(&file);
            for call in [".ingest_for_poll(", ".seal_location("] {
                for (at, _) in plain.match_indices(call) {
                    let body = enclosing_fn(&plain, at);
                    assert!(
                        body.lines()
                            .next()
                            .unwrap_or_default()
                            .contains("_for_test"),
                        "{name} reaches `{call}` outside a test seam",
                    );
                }
            }
            assert!(
                !text.contains("::ingest_for_poll") && !text.contains("::seal_location"),
                "{name} names the driver's poll or send entry by its path",
            );
            continue;
        }
        // The soak rig (never shipped): its world's one poll entry and one
        // send entry, over its one driver builder's full mode.
        if name.ends_with("tooling/soak/src/rig/world.rs") {
            assert!(
                text.matches(".ingest_for_poll(").count() == 1
                    && text.matches(".seal_location(").count() == 1
                    && !text.contains("::ingest_for_poll")
                    && !text.contains("::seal_location"),
                "the soak world reaches the driver's poll or send entry beside its own one",
            );
            continue;
        }
        for call in [
            ".ingest_for_poll(",
            "::ingest_for_poll",
            ".seal_location(",
            "::seal_location(",
            "::seal_location,",
            "::seal_location)",
        ] {
            assert!(
                !text.contains(call),
                "{name} reaches `{call}`: the poll and send entries on the driver are \
                 wired to a caller in the change that gives that caller its mode, and \
                 rewrites this gate",
            );
        }
    }

    // The bridge: the sweep every wake runs, which drives nothing, and its
    // `*_driven` entries, whose drives run on their caller's `Claimed` word
    // (`every_driver_is_given_its_mode_by_name`).
    let bridge = squash(&production_source(
        &repo_root().join("haven/rust_builder/src/api.rs"),
    ));
    assert!(
        bridge.contains("catchup::run_catchup_all_circles(")
            && !bridge.contains("run_catchup_in_foreground")
            && !bridge.contains("run_catchup_driving")
            && !bridge.contains("drive_due(")
            && !bridge.contains("drive_one("),
        "the bridge reaches a drive of stored records other than through a `*_driven` \
         entry's `Publishing`: nothing in its sweep can tell a background wake from the \
         foreground",
    );
    // The sweep that drives is called by nothing in its own file but itself;
    // the refetch builds its own plane, in the mode that only finishes.
    let sweep = squash(&production_source(
        &repo_root().join("haven-core/src/relay/catchup.rs"),
    ));
    assert_eq!(
        (
            sweep.matches("run_catchup_driving(").count(),
            sweep.matches("run_catchup_in_foreground(").count(),
            sweep.matches("Plane::driving(").count(),
        ),
        (2, 1, 2),
        "the sweep that drives is reached from another entry of the catch-up plane",
    );
    // Everything the sweep's file does with the driver, counted: two
    // literals (the sweep's, in the mode its entry names, and the
    // refetch's), one full mode handed (the foreground entry's) besides the
    // arm of the sweep's own advance and the decision that arm asks again
    // with the engine held, three that only finish (the wake's entry, the
    // refetch, the advance's other arm), one resume and one settlement (both
    // on a driver it was HANDED), and no drive entry called by name — a
    // `drive_due(…)` dropped into it shows here.
    let unattended = squash(
        fn_body(
            &production_source(&repo_root().join("haven-core/src/relay/catchup.rs")),
            "pub async fn run_catchup_all_circles(",
        )
        .expect("catchup.rs defines run_catchup_all_circles"),
    );
    assert_eq!(
        (
            sweep.matches("Publishing{").count(),
            sweep.matches("&DriveMode::Full").count(),
            sweep.matches("DriveMode::Full").count(),
            sweep.matches("DriveMode::FinishOnly").count(),
            sweep.matches(".resume(").count(),
            sweep.matches(".settle_staged(").count(),
            sweep.matches("drive_due(").count(),
            sweep.matches("drive_one(").count(),
            sweep.matches("drive_rows(").count(),
        ),
        (2, 1, 3, 3, 1, 1, 0, 0, 0),
        "the catch-up plane builds, or is handed, a driver somewhere new",
    );
    // The sweep every wake runs drives in the mode that only finishes:
    // nothing in it can tell a background wake from the foreground.
    assert!(
        unattended.contains(
            "run_catchup_in(circle_mgr,relay_mgr,max_duration_secs,&DriveMode::FinishOnly,)"
        ),
        "the sweep every wake runs drives in a mode that can make a commit",
    );
    for driven in [
        "DriveMode::Full",
        "Publishing",
        "driving(",
        ".resume(",
        ".settle_staged(",
    ] {
        assert!(
            !unattended.contains(driven),
            "the sweep every wake runs names `{driven}`: nothing in it can tell a \
             background wake from the foreground",
        );
    }
}

/// The foreground is a claim the app makes, and one thing makes it on this
/// side of the bridge: `foreground_claim`, from the `foreground` flag of the
/// FFI entry it was called by. So `Claim::Foreground` is named by that one
/// function, by the three places the session acts on it, and by the soak
/// rig, which stands in for an app whose lifecycle reads `resumed` — and by
/// nothing else, in any tree. A core entry that enters the foreground has one
/// caller in the bridge, which hands it that function's answer and whose
/// whole body is pinned: a flag re-assigned on the way would otherwise read
/// the same. A START is not one of them: it takes seconds, and carries no
/// claim at all.
#[test]
#[allow(clippy::too_many_lines)]
fn the_foreground_is_claimed_through_the_bridge_alone() {
    let squash = |text: &str| -> String { text.chars().filter(|c| !c.is_whitespace()).collect() };
    let root = repo_root().to_string_lossy().replace('\\', "/");
    let mut claims: Vec<(String, usize)> = Vec::new();
    let mut entries: Vec<(String, String)> = Vec::new();
    for file in scanned_sources() {
        let name = file.to_string_lossy().replace('\\', "/");
        let name = name.trim_start_matches(&format!("{root}/")).to_owned();
        let text = squash(&production_source(&file));
        let count = text.matches("Claim::Foreground").count();
        if count > 0 {
            claims.push((name.clone(), count));
        }
        if name.ends_with("relay/live_sync/session.rs") {
            continue;
        }
        for entry in [
            ".resume_after_background(",
            ".maintain_subscription_health(",
            ".claim_foreground(",
        ] {
            for (at, _) in text.match_indices(entry) {
                let argument: String = text[at + entry.len()..]
                    .chars()
                    .take_while(|c| *c != ')')
                    .collect();
                entries.push((name.clone(), format!("{entry}{argument})")));
            }
        }
    }
    assert_eq!(
        claims,
        [
            ("haven/rust_builder/src/api.rs", 1),
            ("haven-core/src/relay/live_sync/session.rs", 3),
            ("tooling/soak/src/rig/device.rs", 2),
            ("tooling/soak/src/scenarios/s03_lost_commit.rs", 1),
            ("tooling/soak/src/scenarios/s17_closed_prefixes.rs", 2),
            ("tooling/soak/src/scenarios/s25_silent_relays.rs", 1),
        ]
        .map(|(file, count)| (file.to_owned(), count)),
        "the foreground claim is named somewhere new: only the bridge may make it, from \
         its caller's flag",
    );
    assert_eq!(
        entries,
        [
            (
                "haven/rust_builder/src/api.rs",
                ".resume_after_background(foreground_claim(foreground)",
            ),
            (
                "haven/rust_builder/src/api.rs",
                ".maintain_subscription_health(foreground_claim(foreground)",
            ),
            (
                "haven/rust_builder/src/api.rs",
                ".claim_foreground(foreground_claim(foreground)",
            ),
            (
                "tooling/soak/src/rig/device.rs",
                ".resume_after_background(Claim::Foreground)",
            ),
            // A started engine claims the foreground as the app's does once
            // it is in front of its user (the rig drives as the bridge does).
            (
                "tooling/soak/src/rig/device.rs",
                ".claim_foreground(Claim::Foreground)",
            ),
            (
                "tooling/soak/src/scenarios/s03_lost_commit.rs",
                ".maintain_subscription_health(Claim::Foreground)",
            ),
            (
                "tooling/soak/src/scenarios/s17_closed_prefixes.rs",
                ".maintain_subscription_health(Claim::Foreground)",
            ),
            (
                "tooling/soak/src/scenarios/s17_closed_prefixes.rs",
                ".maintain_subscription_health(Claim::Foreground)",
            ),
            (
                "tooling/soak/src/scenarios/s25_silent_relays.rs",
                ".maintain_subscription_health(Claim::Foreground)",
            ),
        ]
        .map(|(file, call)| (file.to_owned(), call.to_owned())),
        "an entry that can put a session in the foreground has a caller this gate does \
         not name, or one that does not hand it the bridge's claim",
    );
    let bridge_source = production_source(&repo_root().join("haven/rust_builder/src/api.rs"));
    let bridge = squash(&bridge_source);
    assert_eq!(
        (
            squash(
                fn_body(&bridge_source, "const fn foreground_claim(").expect("foreground_claim")
            ),
            bridge.matches("foreground_claim(").count(),
            bridge.matches("foreground_claim(foreground)").count(),
            bridge
                .matches(".start(&circles,&inbox_relays).await")
                .count(),
            bridge.matches(".start(").count(),
        ),
        (
            "{ifforeground{Claim::Foreground}else{Claim::Nothing}}".to_owned(),
            4,
            3,
            1,
            1,
        ),
        "the bridge makes the foreground claim from something other than its caller's \
         flag, or starts a session with a claim",
    );
    let entry = |signature: &str| {
        let at = bridge_source
            .find(signature)
            .unwrap_or_else(|| panic!("the bridge no longer declares `{signature}`"));
        squash(&enclosing_fn(&bridge_source, at))
    };
    assert!(
        !entry("pub async fn start_session(").contains("foreground")
            && !entry("pub async fn start_session(").contains("Claim"),
        "a session start carries a claim again: it is read seconds before the start acts \
         on it, and a pause in between never reaches the core",
    );
    // Each of the three, WHOLE: the flag is the entry's own parameter, handed
    // on once and never assigned on the way.
    for (signature, whole) in [
        (
            "pub async fn resume_after_background(&self, foreground: bool)",
            "pubasyncfnresume_after_background(&self,foreground:bool)->Result<(),String>{\
             letcore=SESSION.read().map_err(|_|\"sessionlockpoisoned\".to_string())?\
             .as_ref().map(Arc::clone);matchcore{Some(core)=>core\
             .resume_after_background(foreground_claim(foreground)).await\
             .map_err(|e|e.to_string()),None=>Err(\"noactivelive-syncsession\"\
             .to_string()),}}",
        ),
        (
            "pub async fn claim_foreground(&self, foreground: bool)",
            "pubasyncfnclaim_foreground(&self,foreground:bool)->Result<(),String>{\
             letSome(core)=live_session_core()?else{returnErr(\"noactivelive-syncsession\"\
             .to_string());};core.claim_foreground(foreground_claim(foreground)).await;\
             Ok(())}",
        ),
        (
            "pub async fn maintain_subscription_health(",
            "pubasyncfnmaintain_subscription_health(foreground:bool,)->\
             Result<SubscriptionHealthOutcomeFfi,String>{letSome(core)=live_session_core()?\
             else{returnOk(haven_core::relay::live_sync::SubscriptionHealthOutcome::\
             engine_off().into());};letoutcome=core\
             .maintain_subscription_health(foreground_claim(foreground)).await\
             .map_err(|e|e.to_string())?;Ok(outcome.into())}",
        ),
    ] {
        assert_eq!(
            entry(signature),
            squash(whole),
            "`{signature}` is no longer exactly its caller's `foreground` flag handed to \
             the core once",
        );
    }
}

/// The Rust sources the driver gates read: the core, the bridge, and the
/// soak rig.
fn scanned_sources() -> Vec<std::path::PathBuf> {
    let mut files = Vec::new();
    for tree in [
        "haven-core/src",
        "haven/rust_builder/src",
        "tooling/soak/src",
    ] {
        sources_under(&repo_root().join(tree), "rs", &mut files);
    }
    files.retain(|file| !file.to_string_lossy().contains("frb_generated"));
    files.sort();
    files
}

/// Everything `relay/fanout.rs` declares that code outside it can reach, in
/// the order it declares it: a wrapper added there — a public
/// `drive_stored` on the relay manager, say, that calls the resume — is
/// named by no import and by no banned word anywhere else, and shows here.
#[allow(clippy::too_many_lines)]
fn the_drivers_public_surface_is_pinned() {
    let driver = production_source(&repo_root().join("haven-core/src/relay/fanout.rs"));
    let mut surface: Vec<String> = Vec::new();
    for line in driver.lines() {
        let line = line.trim();
        let declared = [
            "pub async fn ",
            "pub fn ",
            "pub const fn ",
            "pub(crate) async fn ",
            "pub(crate) const fn ",
            "pub(crate) fn ",
            "pub(super) async fn ",
            "pub(super) fn ",
            "pub(super) const fn ",
            "pub(in ",
            "pub struct ",
            "pub enum ",
            "pub trait ",
            "pub const ",
            "pub static ",
            "pub type ",
            "pub mod ",
            "pub use ",
        ]
        .iter()
        .find_map(|kind| line.strip_prefix(kind).map(|rest| (*kind, rest)));
        if let Some((kind, rest)) = declared {
            let name: String = rest
                .chars()
                .take_while(|c| c.is_alphanumeric() || *c == '_')
                .collect();
            surface.push(format!("{}{name}", kind.trim_start_matches("pub ")));
        } else if line.starts_with("impl") {
            surface.push(line.trim_end_matches('{').trim().to_owned());
        }
    }
    let expected = [
        "const MDK_ATTEMPTS_PER_CALL",
        "const MDK_CALL_CEILING_SECS",
        "enum FanoutTargetOutcome",
        "pub(crate) async fn publish_to_target",
        "impl Answers",
        "pub(crate) fn possibly_exposed",
        "const INTERRUPTED",
        "pub(crate) fn interrupted",
        "pub(super) fn not_exposed",
        "enum DriveMode",
        "trait ModeSource",
        "impl ModeSource for DriveMode",
        "struct Claimed",
        "impl<'a> Claimed<'a>",
        "fn new",
        "impl Drop for Claimed<'_>",
        "impl ModeSource for Claimed<'_>",
        "impl<'a> Still<'a>",
        "pub(crate) const fn new",
        "pub(crate) const fn always",
        "pub(crate) fn holds",
        "pub(crate) const fn decided",
        "pub(crate) fn own",
        "pub(crate) fn release",
        "fn is_owned",
        "impl Driving",
        "impl Drop for Driving",
        // Test seams: a held row, the wait on its release, and a hook before
        // a change's own drive. None drives anything.
        "struct RowHoldForTest",
        "fn hold_fanout_row_for_test",
        "async fn a_row_is_waited_for_test",
        "async fn fanout_row_let_go_for_test",
        "fn before_next_change_drive_for_test",
        "trait FanoutSend",
        "struct Taken",
        "impl Taken",
        "pub(super) const fn holding",
        "const fn nothing",
        "trait FanoutClock",
        "struct WallClock",
        "impl FanoutClock for WallClock",
        "const AMBIGUOUS_RETRY_BASE_MS",
        "const RETRY_MAX_MS",
        "const UNAVAILABLE_RETRY_DELAY_MS",
        "const UNAVAILABLE_PROMPT_CALLS",
        "const RATE_LIMITED_RETRY_BASE_MS",
        "const RATE_LIMITED_JITTER_DIVISOR",
        "const CONFIRM_ATTEMPTS",
        "const FANOUT_BOUND_MS",
        "const RESTAGE_BASE_MS",
        "const GATE_WAIT_SECS",
        "const ROW_BUDGET_MS",
        "const FOLD_BUDGET_MS",
        "const PUBLISHER_BUDGET_MS",
        "const BUSY_RETRY_MS",
        "enum FanoutStatus",
        "struct DriveOutcome",
        "impl DriveOutcome",
        "async fn drive_one",
        "struct DueOutcome",
        "async fn drive_due",
        "const LOCATION_SEND_MS",
        "enum LocationPublish",
        "async fn wake_unreachable",
        "enum EvolutionStatus",
        "struct EvolutionOutcome",
        // A driven create's answer (R1a): its founding Welcomes sent from
        // their records.
        "struct CreateOutcome",
        "impl std::fmt::Debug for EvolutionOutcome",
        "enum RepairOutcome",
        "enum SendHeld",
        // The recovery read: a fact and its ranking, no drive.
        "enum RecoveryCause",
        "struct RecoveryFacts",
        "const fn worst_recovery",
        "const LEAVE_BOUND_MS",
        "enum LeaveStatus",
        "struct LeaveOutcome",
        "impl LeaveOutcome",
        "enum LocationSeal",
        "impl std::fmt::Debug for LocationSeal",
        "struct SealOutcome",
        "impl std::fmt::Debug for SealOutcome",
        "impl std::fmt::Debug for RepairOutcome",
        "struct ResumeOutcome",
        "enum ReinviteResult",
        "struct Reinvite",
        "trait ReinviteLookup",
        "impl ReinviteLookup for super::RelayManager",
        "struct PollOutcome",
        "impl PollOutcome",
        "const RESUME_BUDGET_MS",
        // A burst's end and the deadline it cuts a wake to: no drive of its
        // own, read by every wake that drives (`wake_deadline`).
        "struct BurstEnd",
        "impl BurstEnd",
        "pub(crate) fn after",
        "pub(crate) fn on",
        "fn wake_deadline",
        "trait UnrecordedPublisher",
        "impl UnrecordedPublisher for super::RelayManager",
        "struct Publishing",
        "impl From<Pass> for ResumeOutcome",
        "impl<T: FanoutSend + ?Sized> Publishing<'_, T>",
        "async fn remove_members",
        "async fn update_relays",
        "async fn admin_handoff",
        "async fn self_demote",
        "async fn leave",
        "async fn resume_leave",
        "async fn repair_rotation",
        "async fn create_circle",
        "async fn add_members",
        "async fn resume",
        "async fn reinvite",
        "async fn settle_staged",
        "async fn circle_recovery",
        "async fn ingest_for_poll",
        "async fn seal_location",
        // The seal for the mesh alone: it calls no relay
        // (`a_seal_for_the_mesh_names_nothing_that_reaches_a_relay`).
        "async fn seal_for_mesh",
        "async fn publish_location",
        "async fn mesh_drive",
        // A location's own send, then the bridge: the one send of an event
        // this device did not seal (`the_bridge_sends_once_and_reads_no_answer`).
        "async fn publish_location_and_bridge",
        "mod scripted",
        "enum Answer",
        "struct Call",
        "enum LocationAnswer",
        "struct LocationCall",
        "struct ScriptedFanout",
        "impl Default for ScriptedFanout",
        "impl ScriptedFanout",
        "fn answer",
        "fn calls",
        "fn park_next_location",
        "fn location_call_count",
        "fn answer_locations",
        "fn location_calls",
        "fn call_count",
        "fn most_at_once",
        "fn park",
        "fn unpark",
        "async fn parked",
        "fn release",
        // The scripted transports the circle manager's test seams drive over.
        "struct FixedClock",
        "impl super::FanoutClock for FixedClock",
        "struct Accepting",
        "impl Accepting",
        "fn sent",
        "fn handed",
        "impl FanoutSend for Accepting",
        "impl crate::relay::fanout::UnrecordedPublisher for Accepting",
        "struct Refusing",
        "impl FanoutSend for Refusing",
        "impl crate::relay::fanout::UnrecordedPublisher for Refusing",
        "struct Inert",
        "impl FanoutSend for Inert",
        "impl crate::relay::fanout::UnrecordedPublisher for Inert",
        "impl FanoutSend for ScriptedFanout",
        "struct RelayMappedFanout",
        "impl<T> RelayMappedFanout<T>",
        "fn new",
        "impl<T: FanoutSend> FanoutSend for RelayMappedFanout<T>",
        "fn disown_for_test",
    ];
    assert_eq!(
        surface, expected,
        "what `relay/fanout.rs` declares for the rest of the crate has changed: a new way \
         to a drive is added here before anything can call it",
    );
}

/// Every driver is built with its mode written out. The compiler requires
/// the field; what it cannot require is that nobody inherits it — a
/// `..other` in the literal, a `Default`, a constructor that picks one — or
/// that a site keeps the mode it was reviewed with.
/// The soak rig's driver is built as the bridge's is: the `Claimed` mode its
/// caller's `true` and the live plane's standing make, under the bridge's
/// budget — so what the soak grades is the bridge's drive.
fn the_rig_drives_as_the_bridge_does() {
    let squash = |text: &str| -> String { text.chars().filter(|c| !c.is_whitespace()).collect() };
    let rig = squash(&production_source(
        &repo_root().join("tooling/soak/src/rig/circle.rs"),
    ));
    assert!(
        rig.matches("mode:Claimed::new(device.manager()?,true),")
            .count()
            == 1
            && rig.matches("Claimed::new(").count() == 1
            && rig
                .matches("deadline_ms:Some(self.clock.now_ms().saturating_add(RESUME_BUDGET_MS)),")
                .count()
                == 1,
        "the soak rig drives in a mode or under a budget the bridge does not",
    );
}

#[allow(clippy::too_many_lines)]
fn every_driver_is_given_its_mode_by_name() {
    let squash = |text: &str| -> String { text.chars().filter(|c| !c.is_whitespace()).collect() };
    let root = repo_root().to_string_lossy().replace('\\', "/");
    let mut built = Vec::new();
    for file in scanned_sources() {
        let name = file.to_string_lossy().replace('\\', "/");
        let name = name.trim_start_matches(&format!("{root}/")).to_owned();
        let source = squash(&production_source(&file));
        assert!(
            !source.contains("DefaultforPublishing") && !source.contains("->Publishing<"),
            "{name} builds a driver somewhere other than a literal that names its mode",
        );
        for (at, _) in source.match_indices("Publishing{") {
            let literal = block_after(&source[at..], "Publishing{");
            assert!(
                !literal.contains(".."),
                "{name} builds a driver that inherits fields: {literal}",
            );
            let mode = literal
                .split("mode:")
                .nth(1)
                .unwrap_or_else(|| panic!("{name} builds a driver with no mode"))
                .trim_end_matches('}')
                .trim_end_matches(',')
                .to_owned();
            built.push((name.clone(), mode));
        }
    }
    built.sort();
    let expected = [
        // The circle manager's test seams (`#[cfg(any(test, feature =
        // "test-utils"))]`), each over a scripted transport: never shipped.
        ("haven-core/src/circle/manager.rs", "&DriveMode::FinishOnly"),
        ("haven-core/src/circle/manager.rs", "&DriveMode::FinishOnly"),
        ("haven-core/src/circle/manager.rs", "&DriveMode::Full"),
        ("haven-core/src/circle/manager.rs", "&DriveMode::Full"),
        ("haven-core/src/circle/manager.rs", "&DriveMode::Full"),
        ("haven-core/src/circle/manager.rs", "&DriveMode::Full"),
        ("haven-core/src/circle/manager.rs", "&DriveMode::Full"),
        ("haven-core/src/circle/manager.rs", "&DriveMode::Full"),
        ("haven-core/src/circle/manager.rs", "&DriveMode::Full"),
        ("haven-core/src/circle/manager.rs", "&DriveMode::Full"),
        // The recovery read's seam, over `Inert`: it drives nothing, and the
        // mode is the caller's `foreground`, as the bridge's `Claimed`.
        ("haven-core/src/circle/manager.rs", "&mode"),
        // The refetch, which a burst asks for too, and the sweep in the mode
        // its entry names: the wake's in the one that only finishes.
        ("haven-core/src/relay/catchup.rs", "&DriveMode::FinishOnly"),
        ("haven-core/src/relay/catchup.rs", "drive_mode"),
        ("haven-core/src/relay/live_sync/processor.rs", "&leash"),
        // The bridge's driver entries: the `Claimed` mode their caller's word
        // and the live plane's standing make, held by its one builder.
        ("haven/rust_builder/src/api.rs", "&self.mode"),
        // The soak rig's one builder (never shipped): the `Claimed` mode a
        // caller's `true` and the live plane's standing make, as the bridge's.
        ("tooling/soak/src/rig/circle.rs", "&self.mode"),
    ]
    .map(|(file, mode)| (file.to_owned(), mode.to_owned()));
    let bridge = squash(&production_source(
        &repo_root().join("haven/rust_builder/src/api.rs"),
    ));
    assert!(
        bridge
            .matches("mode:haven_core::relay::fanout::Claimed::new(&circle.inner,foreground),")
            .count()
            == 1
            && bridge.matches("Claimed::new(").count() == 1,
        "the bridge's driver takes its mode from something other than its caller's word",
    );
    assert_eq!(
        built, expected,
        "a driver is built somewhere new, or with a different mode: the full mode is for \
         a caller whose claim that the app is `resumed` stands",
    );
    // The NAME each literal is handed must be the binding this gate reads:
    // a second source of a mode, or a `let` that shadows the one above the
    // literal, passes every text pin there is.
    let mut sources: Vec<(String, usize)> = Vec::new();
    for file in scanned_sources() {
        let name = file.to_string_lossy().replace('\\', "/");
        let name = name.trim_start_matches(&format!("{root}/")).to_owned();
        let count = squash(&production_source(&file))
            .matches("implModeSourcefor")
            .count();
        if count > 0 {
            sources.push((name, count));
        }
    }
    assert_eq!(
        sources,
        [
            // A mode, and the bridge's `Claimed`, which can only narrow.
            ("haven-core/src/relay/fanout.rs", 2),
            ("haven-core/src/relay/live_sync/drive.rs", 1),
        ]
        .map(|(file, count)| (file.to_owned(), count)),
        "something new can answer for a driver's mode: a mode is its own source, and the \
         live plane's leash is the one that can change",
    );
    let processor =
        production_source(&repo_root().join("haven-core/src/relay/live_sync/processor.rs"));
    let live = squash(fn_body(&processor, "pub(super) async fn drive_due(").expect("drive_due"));
    assert!(
        live.matches("letleash=").count() == 1
            && live.contains("letleash=Leash::over(&self.lifecycle,self.halt.clone());"),
        "the live plane hands its driver a leash other than the one taken over the \
         session's lifecycle when the pass began",
    );
}

/// The item names that follow `prefix` in `source`: `fanout::Name`, each of
/// `fanout::{A, B, self}`, and `fanout::*`. A renamed item comes back whole
/// (`"B as C"`), so its caller can refuse it.
fn names_after(source: &str, prefix: &str) -> Vec<String> {
    let ident = |c: char| c.is_alphanumeric() || c == '_';
    let mut names = Vec::new();
    for (at, _) in source.match_indices(prefix) {
        // `fanout::` as a path segment only, never the tail of a longer name.
        if source[..at].chars().next_back().is_some_and(ident) {
            continue;
        }
        let rest = source[at + prefix.len()..].trim_start();
        if let Some(list) = rest.strip_prefix('{') {
            let end = list.find('}').unwrap_or(list.len());
            names.extend(
                list[..end]
                    .split(',')
                    .map(|name| name.split_whitespace().collect::<Vec<_>>().join(" "))
                    .filter(|name| !name.is_empty()),
            );
        } else {
            let end = rest
                .find(|c: char| !ident(c) && c != '*')
                .unwrap_or(rest.len());
            let renamed = rest[end..].trim_start().starts_with("as ");
            names.push(if renamed {
                format!("{} as _", &rest[..end])
            } else {
                rest[..end].to_owned()
            });
        }
    }
    names
}

/// Every product caller of an entry that records what the engine stages as a
/// durable fanout, by file and function.
///
/// A record nothing drives is the hazard: its commit is restored as pending
/// at every open, its circle's sends wait and its inbound traffic is held
/// unread. So a staging entry may be called only from a path that also
/// reaches a drive — the driver's own send-side entries, the sweep that
/// drives, and the live plane in the lifecycle that drives — and a new
/// caller shows here before it ships. `advance_for_drive` has a guard of its
/// own (`scripts/ci/check_advance_convergence_sites.sh` A4).
///
/// Two callers drive nothing, by design: the mesh's ingress
/// (`Publishing::mesh_drive`) and the seal for the mesh alone
/// (`Publishing::seal_for_mesh`), which may call no relay. Neither records a
/// commit, so nothing either leaves holds a circle: the ingest and its fold,
/// and the seal, are finish-only (`a_mesh_drive_names_nothing_that_reaches_a_relay`,
/// `a_seal_for_the_mesh_names_nothing_that_reaches_a_relay`), and in that
/// mode staging records a proposal alone. A proposal's record holds neither
/// sends nor inbound traffic, and the next relay drive sends it. The seal's
/// own record is a location's: its send ends it, and a drive ends one a dead
/// process left.
#[test]
#[allow(clippy::too_many_lines)]
fn every_caller_of_a_staging_entry_is_a_path_that_drives() {
    let squash = |text: &str| -> String { text.chars().filter(|c| !c.is_whitespace()).collect() };
    let entries = [
        ".process_event_staging(",
        ".staging_ingest(",
        ".ingest_from_mesh(",
        ".send_staging(",
        ".send_staging_keeping(",
        ".requeue_removal_staging(",
        ".add_members_staging(",
        ".remove_members_staging(",
        ".update_relays_staging(",
        ".repair_self_update_staging(",
        ".post_join_self_update_staging(",
        ".change_admin_policy_staging(",
        ".admin_change(",
        ".update_circle_relays_staging(",
        ".propose_admin_handoff_staging(",
        ".propose_self_demote_staging(",
        ".repair_epoch_rotation_staging(",
        ".fold_staged(",
        ".serve_deadlines(",
        ".seal_location_staging(",
        ".send_location_staging(",
        ".repair_deferred_send_staging(",
        ".settle_inputs_for_drive(",
        ".stage_due_eviction(",
    ];
    let root = repo_root().to_string_lossy().replace('\\', "/");
    let mut callers = Vec::new();
    for file in scanned_sources() {
        let name = file.to_string_lossy().replace('\\', "/");
        let name = name.trim_start_matches(&format!("{root}/")).to_string();
        let source = production_source(&file);
        for entry in entries {
            for (at, _) in source.match_indices(entry) {
                let body = enclosing_fn(&source, at);
                let header = body.lines().next().unwrap_or_default();
                let function = header
                    .split("fn ")
                    .nth(1)
                    .and_then(|rest| rest.split(['(', '<']).next())
                    .unwrap_or_default();
                callers.push(format!(
                    "{name}: {function} -> {}",
                    &entry[1..entry.len() - 1]
                ));
            }
        }
        // A staging entry taken as a value, or called by its path
        // (`Type::entry(&x, …)`), is a call the scan above cannot follow.
        let flat = squash(&source);
        for entry in entries {
            let bare = format!("::{}", &entry[1..entry.len() - 1]);
            for spelling in [",", ")", "("] {
                assert!(
                    !flat.contains(&format!("{bare}{spelling}")),
                    "{name} names {bare} by its path: its caller cannot be pinned",
                );
            }
        }
    }
    callers.sort();
    let expected = [
        // The session's own staging forms of its sends.
        "haven-core/src/circle/manager.rs: add_members_staging -> add_members_staging",
        // A change of the circle's admins, which stages nothing when the
        // circle already has them.
        "haven-core/src/circle/manager.rs: admin_change -> change_admin_policy_staging",
        // The fold's own advance, for a call that makes no new commit.
        "haven-core/src/circle/manager.rs: advance_as -> settle_inputs_for_drive",
        "haven-core/src/circle/manager.rs: fold_into -> fold_staged",
        // The post-join self-update MDK's obligation owes, in a full resume.
        "haven-core/src/circle/manager.rs: post_join_self_update_staging -> fold_staged",
        "haven-core/src/circle/manager.rs: post_join_self_update_staging -> post_join_self_update_staging",
        "haven-core/src/circle/manager.rs: propose_admin_handoff_staging -> admin_change",
        "haven-core/src/circle/manager.rs: propose_self_demote_staging -> admin_change",
        "haven-core/src/circle/manager.rs: removal_staging -> remove_members_staging",
        "haven-core/src/circle/manager.rs: removal_staging -> requeue_removal_staging",
        "haven-core/src/circle/manager.rs: repair_deferred_send_staging -> serve_deadlines",
        "haven-core/src/circle/manager.rs: repair_epoch_rotation_staging -> fold_staged",
        "haven-core/src/circle/manager.rs: repair_epoch_rotation_staging -> repair_deferred_send_staging",
        "haven-core/src/circle/manager.rs: repair_epoch_rotation_staging -> repair_deferred_send_staging",
        "haven-core/src/circle/manager.rs: repair_epoch_rotation_staging -> repair_self_update_staging",
        "haven-core/src/circle/manager.rs: seal_location_staging -> send_location_staging",
        "haven-core/src/circle/manager.rs: serve_deadlines -> fold_staged",
        "haven-core/src/circle/manager.rs: stage_due_eviction -> fold_staged",
        "haven-core/src/circle/manager.rs: update_circle_relays_staging -> update_relays_staging",
        // A test seam that lands what it stages through the driver's own
        // drive (`land_staged_for_test`).
        "haven-core/src/circle/manager.rs: update_relays_for_test -> update_relays_staging",
        "haven-core/src/nostr/mls/manager.rs: add_members_staging -> send_staging",
        // The full advance that finds the foreground ended once it has the
        // engine: it settles as the plane that makes no commit does.
        "haven-core/src/nostr/mls/manager.rs: advance_for_drive_while -> settle_inputs_for_drive",
        // The mesh's ingest: finish-only, so it records no commit.
        "haven-core/src/nostr/mls/manager.rs: ingest_from_mesh -> staging_ingest",
        // A relay's event, through the body it shares with the mesh's.
        "haven-core/src/nostr/mls/manager.rs: process_event_staging -> staging_ingest",
        "haven-core/src/nostr/mls/manager.rs: process_event_staging_for_test -> process_event_staging",
        "haven-core/src/nostr/mls/manager.rs: remove_members_staging -> send_staging",
        "haven-core/src/nostr/mls/manager.rs: requeue_removal_staging -> send_staging_keeping",
        "haven-core/src/nostr/mls/manager.rs: send_location_staging_for_test -> send_location_staging",
        "haven-core/src/nostr/mls/manager.rs: send_staging -> send_staging_keeping",
        "haven-core/src/nostr/mls/manager.rs: update_relays_staging -> send_staging",
        // The sweep that drives.
        "haven-core/src/relay/catchup.rs: advance -> settle_inputs_for_drive",
        "haven-core/src/relay/catchup.rs: ingest -> process_event_staging",
        "haven-core/src/relay/catchup.rs: resolve -> fold_staged",
        // The driver's send-side entries, its poll and send entries, and
        // its resume.
        "haven-core/src/relay/fanout.rs: add_members -> add_members_staging",
        "haven-core/src/relay/fanout.rs: hand_over -> propose_admin_handoff_staging",
        "haven-core/src/relay/fanout.rs: ingest_for_poll -> fold_staged",
        "haven-core/src/relay/fanout.rs: ingest_for_poll -> process_event_staging",
        // The mesh's ingress, which drives nothing (see above).
        "haven-core/src/relay/fanout.rs: mesh_drive -> fold_staged",
        "haven-core/src/relay/fanout.rs: mesh_drive -> ingest_from_mesh",
        "haven-core/src/relay/fanout.rs: post_join -> post_join_self_update_staging",
        "haven-core/src/relay/fanout.rs: reinvite_one -> stage_due_eviction",
        "haven-core/src/relay/fanout.rs: reissue_withdrawn -> stage_due_eviction",
        "haven-core/src/relay/fanout.rs: remove_members -> remove_members_staging",
        "haven-core/src/relay/fanout.rs: repair_rotation -> repair_epoch_rotation_staging",
        "haven-core/src/relay/fanout.rs: requeue_removal -> requeue_removal_staging",
        "haven-core/src/relay/fanout.rs: resume -> serve_deadlines",
        "haven-core/src/relay/fanout.rs: resume -> stage_due_eviction",
        // The seal for the mesh alone, which drives nothing (see above).
        "haven-core/src/relay/fanout.rs: seal_for_mesh -> seal_location_staging",
        "haven-core/src/relay/fanout.rs: seal_location -> repair_deferred_send_staging",
        "haven-core/src/relay/fanout.rs: seal_location -> seal_location_staging",
        "haven-core/src/relay/fanout.rs: step_down -> propose_self_demote_staging",
        "haven-core/src/relay/fanout.rs: update_relays -> update_circle_relays_staging",
        // The live plane, where the lifecycle has said how it receives:
        // the inputs-only advance is the plane's that makes no commit.
        "haven-core/src/relay/live_sync/processor.rs: advance -> settle_inputs_for_drive",
        "haven-core/src/relay/live_sync/processor.rs: ingest -> process_event_staging",
        "haven-core/src/relay/live_sync/processor.rs: resolve -> fold_staged",
        // The bridge's directory test, in a module this reader keeps (its
        // `#[cfg(test)]` is followed by a second attribute): it stages an add
        // and refuses it, so its circle reads a change in flight.
        "haven/rust_builder/src/api.rs: the_picker_reconcile_never_asks_for_the_withdrawing_mode -> add_members_staging",
        // The soak rig's arms that stage one commit under its record and then
        // have the product's driver drive it (never shipped): S05's failed
        // confirm, S14's restart race, S19's commit gap, S22's oversized
        // commit and S24's routing collision.
        "tooling/soak/src/scenarios/s05_publish_confirm.rs: confirm_err -> update_circle_relays_staging",
        "tooling/soak/src/scenarios/s14_restart_race.rs: stage_and_drive_unacknowledged -> update_relays_staging",
        "tooling/soak/src/scenarios/s19_duplicate_reorder.rs: commit_gap -> update_circle_relays_staging",
        "tooling/soak/src/scenarios/s22_oversized_event.rs: stage -> update_circle_relays_staging",
        "tooling/soak/src/scenarios/s24_routing_collision.rs: rotate_onto -> send_staging",
    ];
    assert_eq!(
        callers,
        expected.map(str::to_owned),
        "an entry that records a durable fanout has a caller this gate does not name: a \
         record nothing drives holds its circle's sends and its inbound traffic",
    );

    // Two ways to the same recording that the list above does not see,
    // because neither is a method named in it: the fold a staging send folds
    // into, and the DISPOSITION a fold is handed — one that records, handed
    // on somewhere new, would write a record on a path nothing drives.
    let manager = production_source(&repo_root().join("haven-core/src/circle/manager.rs"));
    let by_fn = |token: &str| -> Vec<String> {
        let mut found: Vec<String> = manager
            .match_indices(token)
            .map(|(at, _)| {
                let body = enclosing_fn(&manager, at);
                let header = body.lines().next().unwrap_or_default();
                header
                    .split("fn ")
                    .nth(1)
                    .and_then(|rest| rest.split(['(', '<']).next())
                    .unwrap_or_default()
                    .to_owned()
            })
            .collect();
        found.sort();
        found
    };
    assert_eq!(
        (
            by_fn(".fold_into("),
            by_fn("Disposition::recording("),
            by_fn("Disposition::Stage {"),
            by_fn("Disposition::Settle {"),
            squash(fn_body(&manager, "const fn recording(").expect("Disposition::recording")),
            squash(&manager)
                .matches("Self::Stage{now_ms,still}")
                .count()
                + squash(&manager).matches("Self::Settle{now_ms}").count(),
        ),
        (
            vec![
                "seal_location_staging".to_owned(),
                "seal_location_staging".to_owned(),
                "seal_location_staging".to_owned(),
            ],
            vec!["fold_staged".to_owned(), "settle_fanout".to_owned()],
            // Matched in the advance, and made in one place besides the
            // constructor: the full drive's own re-staging of a due eviction.
            vec!["advance_as".to_owned(), "stage_due_eviction".to_owned()],
            // And the inputs-only one a seal drains parked rows with.
            vec!["advance_as".to_owned(), "seal_location_staging".to_owned()],
            "{matchstill.decided(){DriveMode::Full=>Self::Stage{now_ms,still},\
             DriveMode::FinishOnly=>Self::Settle{now_ms},}}"
                .to_owned(),
            2,
        ),
        "the fold of a staging send is reached from a new path, or a disposition that \
         records is made or handed on somewhere new",
    );
}

/// Two dispositions run side by side in the catch-up plane and in the live
/// plane, and one commit or proposal is never sent by both.
///
/// Every plane the sweep runs drives what it records: no sweep has a
/// ladder. What keeps a recorded commit or proposal the driver's alone is
/// pinned here at source, and by behaviour in `catchup_sweep_e2e` and
/// `live_plane_drive_e2e`:
///
/// * the sweep's disposition folds what no record could be written for and
///   hands everything to the driver's `settle_staged`; the wake's sweep and
///   the refetch drive in the mode that makes no commit;
/// * staging takes every commit and proposal it records OUT of the work it
///   hands back, and registers the event as the driver's in the same hold;
/// * the publish client refuses a fanout-owned event first, in
///   `relay::manager`'s own
///   `every_method_that_publishes_a_callers_event_refuses_a_fanout_owned_one_first`.
#[test]
fn a_commit_or_proposal_a_sweep_records_is_sent_by_the_driver_alone() {
    let squash = |text: &str| -> String { text.chars().filter(|c| !c.is_whitespace()).collect() };
    let sweep = production_source(&repo_root().join("haven-core/src/relay/catchup.rs"));
    let resolve = squash(
        fn_body(&sweep, "async fn resolve(").expect("catchup.rs must define Plane::resolve"),
    );
    assert!(
        resolve.contains(".fold_staged(unrecorded,false,")
            && resolve.ends_with(
                ".settle_staged(circle_mgr,recorded,handed_back).await;driven.report(&outcome);}"
            ),
        "the sweep disposes of a batch other than through the driver",
    );
    let refetch = squash(
        fn_body(&sweep, "pub async fn run_refused_refetch(")
            .expect("catchup.rs must define run_refused_refetch"),
    );
    assert!(
        refetch.contains("mode:&DriveMode::FinishOnly,}")
            && refetch.contains("Plane::driving(relay_mgr,&publishing,deadline)"),
        "the refetch, which a background wake runs, makes a commit",
    );

    let session = production_source(&repo_root().join("haven-core/src/nostr/mls/manager.rs"));
    for (signature, own) in [
        (
            "fn put_commit_fanout(",
            "crate::relay::fanout::own(fanout.message_id());",
        ),
        (
            "fn put_proposal_fanout(",
            "crate::relay::fanout::own(fanout.message_id());",
        ),
    ] {
        let body = squash(fn_body(&session, signature).unwrap_or_else(|| panic!("{signature}")));
        assert!(
            body.find("session.put_outbound_fanout(&fanout)") < body.find(own),
            "{signature} must make a recorded event the driver's alone in the hold \
             that records it",
        );
    }
    let stage = squash(fn_body(&session, "async fn stage_commits(").expect("stage_commits"));
    assert!(
        stage.contains("Ok(id)=>proposals.push(id),") && stage.contains("Err(_)=>kept.push(item),"),
        "a recorded proposal must leave the work handed back, and only an \
         unrecorded one stay in it",
    );

    the_live_plane_sends_what_it_records_from_its_drive_alone();
    the_driver_and_its_entries_hand_no_commit_to_a_publisher();
}

/// The driver's own half: nothing it folds is handed to a ladder. Every
/// engine call behind its entries records what it stages, so the one thing
/// its publisher of unrecorded things is handed besides a Welcome is a
/// proposal no record could be written for — never a commit — and the
/// staging forms of the location send and of its repair surface nothing to
/// the legacy obligation table.
fn the_driver_and_its_entries_hand_no_commit_to_a_publisher() {
    let squash = |text: &str| -> String { text.chars().filter(|c| !c.is_whitespace()).collect() };
    let driver = production_source(&repo_root().join("haven-core/src/relay/fanout.rs"));
    let flat = squash(&driver);
    assert!(
        !flat.contains("publish_then_resolve")
            && !flat.contains("RESOLVE_RUNAWAY_CAP")
            && !flat.contains(".confirm_published(")
            && !flat.contains(".publish_failed(")
            && flat.matches(".publish_unrecorded(").count() == 1,
        "the driver runs a publish-and-resolve ladder again, or hands its publisher \
         something from a second place",
    );
    let unrecorded =
        squash(fn_body(&driver, "async fn send_unrecorded(").expect("fanout.rs: send_unrecorded"));
    assert!(
        unrecorded.starts_with(
            "{ifself.mode.mode()!=DriveMode::Full||!self.allows(PUBLISHER_BUDGET_MS){returnNone;}"
        ) && unrecorded.contains(".publish_unrecorded("),
        "something with no record is published outside the full mode, or outside \
         `send_unrecorded`",
    );
    let dispose = squash(fn_body(&driver, "async fn dispose(").expect("fanout.rs: dispose"));
    assert!(
        dispose.contains("letDecryptedIngest{results:replayed,proposals,}=handed_back;")
            && !dispose.contains("pending"),
        "the driver's disposition takes a commit up again",
    );
    let manager = production_source(&repo_root().join("haven-core/src/circle/manager.rs"));
    for signature in [
        "pub(crate) async fn seal_location_staging(",
        "pub(crate) async fn repair_deferred_send_staging(",
        "pub(crate) async fn stage_due_eviction(",
        "async fn fold_into(",
    ] {
        let body = squash(fn_body(&manager, signature).unwrap_or_else(|| panic!("{signature}")));
        for legacy in [
            "surface_co_drained_auto_commits",
            "owe_removal_publish",
            "collect_deferred_work",
            "surface_auto_commit",
            ".advance_convergence(",
            ".advance_for_receive(",
            "fold_resolved_publish(",
            ".send_location(",
            "Disposition::HandBack",
        ] {
            assert!(
                !body.contains(legacy),
                "{signature} reaches `{legacy}`: a staging form hands nothing to a ladder \
                 and writes nothing into the legacy obligation table",
            );
        }
    }
}

/// No product path leaves a change of a group queued unsaid — which is what
/// lets a session open retire every one it finds
/// (`retire_queued_group_changes`). Each legacy entry that can queue one
/// takes it back in the hold that queued it, and the entries that answer
/// "queued" — the driver's send-side ones — are called only by the bridge's
/// `*_driven` entries, once each, whose typed outcome says `Queued` to the
/// app: a change left queued there is retired, told, at the next open, a cost
/// the app's screens state (W9n).
#[test]
#[allow(clippy::too_many_lines)]
fn no_product_path_leaves_a_group_change_queued() {
    let squash = |text: &str| -> String { text.chars().filter(|c| !c.is_whitespace()).collect() };
    let root = repo_root().to_string_lossy().replace('\\', "/");
    for file in scanned_sources() {
        let name = file.to_string_lossy().replace('\\', "/");
        let name = name.trim_start_matches(&format!("{root}/")).to_owned();
        if name.ends_with("relay/fanout.rs") || name.starts_with("tooling/soak/") {
            continue;
        }
        let text = squash(&production_source(&file));
        // The driver's send-side entries, by the three names nothing else
        // has, and the other three in the only files that can name a driver.
        let names_a_driver =
            name.ends_with("relay/catchup.rs") || name.ends_with("relay/live_sync/processor.rs");
        let the_bridge = name.ends_with("haven/rust_builder/src/api.rs");
        // The circle manager's test seams drive as the bridge does, over
        // scripted transports; nothing else of it may.
        let seams_only = name.ends_with("haven-core/src/circle/manager.rs");
        let plain = production_source(&file);
        for entry in [".admin_handoff(", ".self_demote(", ".repair_rotation("] {
            if the_bridge {
                assert_eq!(
                    text.matches(entry).count(),
                    1,
                    "{name} calls the driver's `{entry}` beside its one `*_driven` entry",
                );
                continue;
            }
            if seams_only {
                for (at, _) in plain.match_indices(entry) {
                    let header = enclosing_fn(&plain, at);
                    let header = header.lines().next().unwrap_or_default();
                    assert!(
                        header.contains("_for_test("),
                        "{name} calls the driver's `{entry}` outside a test seam",
                    );
                }
                continue;
            }
            assert!(!text.contains(entry), "{name} calls the driver's `{entry}`");
        }
        for entry in [".remove_members(", ".add_members(", ".update_relays("] {
            assert!(
                !names_a_driver || !text.contains(entry),
                "{name} calls the driver's `{entry}`",
            );
        }
        // The session's own sends that keep what the engine queues, by
        // METHOD NAME: whatever the receiver is called, and by path as well as
        // by dot. The circle manager's entries of the same names take a
        // queued change back, so each file's calls are counted, and a new one
        // — whichever it reaches — is named here before it ships.
        if name.ends_with("nostr/mls/manager.rs") {
            continue;
        }
        // Today: the bridge's `*_driven` entries' one call each of the
        // driver's `add_members`, `remove_members` and `update_relays`, and
        // the circle manager's test seams' one call each of the driver's
        // `add_members` and `remove_members`.
        for (method, allowed) in [
            (
                "add_members",
                usize::from(seams_only) + usize::from(the_bridge),
            ),
            (
                "remove_members",
                usize::from(seams_only) + usize::from(the_bridge),
            ),
            ("update_relays", usize::from(the_bridge)),
        ] {
            assert_eq!(
                text.matches(&format!(".{method}(")).count()
                    + text.matches(&format!("::{method}(")).count(),
                allowed,
                "{name} calls `{method}` somewhere new: on the session it leaves a queued \
                 change queued",
            );
            if seams_only {
                for (at, _) in plain.match_indices(&format!(".{method}(")) {
                    let header = enclosing_fn(&plain, at);
                    assert!(
                        header
                            .lines()
                            .next()
                            .unwrap_or_default()
                            .contains("_for_test("),
                        "{name} calls `{method}` outside a test seam",
                    );
                }
            }
        }
        // And the plain send, which takes any intent: only the session's own
        // file builds one, so nothing else has a change to hand it.
        assert!(
            !text.contains("SendIntent::")
                && !text.contains(".send(intent")
                && !text.contains("SessionManager::send("),
            "{name} builds or sends an intent itself: the session's entries are the only \
             way to one, and each is counted above",
        );
    }
    // The epoch-rotation repair is a self-update the session asks for, and
    // the hold that asks retires the one the engine queued in its place; no
    // plain admin-policy send is left to keep one.
    let manager = production_source(&repo_root().join("haven-core/src/circle/manager.rs"));
    let flat = squash(&manager);
    let repair = squash(
        fn_body(
            &manager,
            "pub(crate) async fn repair_epoch_rotation_staging(",
        )
        .expect("repair_epoch_rotation_staging"),
    );
    let session = production_source(&repo_root().join("haven-core/src/nostr/mls/manager.rs"));
    let ask =
        squash(fn_body(&session, "async fn send_self_update_now(").expect("send_self_update_now"));
    assert!(
        !flat.contains(".update_admin_policy(")
            && repair.contains(".repair_self_update_staging(")
            && ask
                .find(".send(SendIntent::SelfUpdate{")
                .is_some_and(|send| Some(send)
                    < ask.find("self.retire_queued_self_updates(session,group_id)")),
        "a self-update the engine queued is kept past the hold that asked for it",
    );
    let open = squash(
        fn_body(&session, "fn settle_fanouts_before_open(").expect("settle_fanouts_before_open"),
    );
    let sweep = squash(
        fn_body(&session, "fn retire_queued_group_changes(").expect("retire_queued_group_changes"),
    );
    assert!(
        open.ends_with(
            "letswept=ifnotes_are_kept{retire_queued_group_changes(store,notes)}else{Ok(())};\
             repaired.and(swept)}"
        ) && open
            .find(
                "letrepaired=try_recordless_removals(store,own_identity,&settled_groups,\
                 highest_ref,notes);"
            )
            .is_some_and(|repair| Some(repair) < open.find("retire_queued_group_changes("))
            && session.matches("try_recordless_removals(").count() == 2
            && session.matches("retire_queued_group_changes(").count() == 2
            // A removal is said as one, and everybody it names is kept
            // beside the note — what holds the circle's sends away from the
            // foreground while one of them is still listed: both written
            // before the change is deleted.
            && sweep.contains(
                "letnamed:&[MemberId]=match&queued.intent{\
                 SendIntent::RemoveMembers{members,..}=>members,_=>&[],};\
                 letdropped=ifnamed.is_empty(){ChangeNote::QueuedChangeDropped}\
                 else{ChangeNote::QueuedRemovalDropped};"
            )
            && sweep
                .find(
                    "iftold&&((!named.is_empty()\
                     &&!notes.keep_removal_targets(&group_id,named,set_aside_epoch,\
                     asks_spent(&queued),))||!notes.note(&group_id,dropped)){break;}"
                )
                .zip(sweep.find("store.delete_queued_outbound_intent("))
                .is_some_and(|(told, deleted)| told < deleted)
            // And read again once the engine can say who is listed, in the
            // open itself: a removal of nobody still in the circle holds
            // nothing.
            && squash(fn_body(&session, "fn open_session(").expect("open_session"))
                .find("settle_fanouts_after_open(&message_store,&session);")
                .zip(
                    squash(fn_body(&session, "fn open_session(").expect("open_session")).find(
                        "forgroup_idinmessage_store.list_groups().unwrap_or_default(){\
                         let_=removal_unmade(&message_store,commit_notes.as_ref(),&session,\
                         &group_id);}"
                    )
                )
                .is_some_and(|(settled, read)| settled < read)
            && sweep.contains(
                "ifletErr(e)=store.delete_queued_outbound_intent(&queued.id){\
                 iftold&&!told_before{notes.clear(&group_id,dropped);}\
                 returnErr(e);}"
            ),
        "the open no longer retires a queued change; retires one before its circle is \
         told, ahead of the removal repair or behind a note that dies with the process; \
         does not say a removal as one, or lets its circle be sealed for from the \
         background; or leaves a note standing for a change it could not delete",
    );
    // The driver's one product caller of a removal, decision 180's re-queue,
    // reaches the engine only through the staging form that takes back what
    // the engine queues, in the hold that queued it.
    let fanout = production_source(&repo_root().join("haven-core/src/relay/fanout.rs"));
    let requeue = squash(
        fn_body(&fanout, "async fn requeue_set_aside_removals(")
            .expect("requeue_set_aside_removals"),
    );
    let ask = squash(fn_body(&fanout, "async fn requeue_removal(").expect("requeue_removal"));
    let keeping =
        squash(fn_body(&session, "async fn send_staging_keeping(").expect("send_staging_keeping"));
    assert!(
        requeue.contains("self.requeue_removal(circle,&group_id,&named)")
            && !requeue.contains(".remove_members(")
            && ask.contains(".requeue_removal_staging(")
            && !ask.contains(".remove_members_staging(")
            && squash(
                fn_body(&session, "pub(crate) async fn requeue_removal_staging(")
                    .expect("requeue_removal_staging")
            )
            .contains("now_ms,false,)")
            && keeping.contains(
                "iflet(false,Ok(staged))=(keep_queued,&staged){\
                 self.take_back_queued(&mutsession,&staged.effects);}drop(session);"
            ),
        "decision 180's re-queue can leave a removal queued: it no longer reaches the engine \
         only through the staging form that takes back what the engine queues",
    );
}

/// The live plane's half of
/// `a_commit_or_proposal_a_sweep_records_is_sent_by_the_driver_alone`: its
/// disposition of a batch sends nothing, and its drive sends through the
/// drive pool alone.
fn the_live_plane_sends_what_it_records_from_its_drive_alone() {
    let squash = |text: &str| -> String { text.chars().filter(|c| !c.is_whitespace()).collect() };
    let processor =
        production_source(&repo_root().join("haven-core/src/relay/live_sync/processor.rs"));
    let resolve =
        squash(fn_body(&processor, "async fn resolve(").expect("processor.rs must define resolve"));
    assert!(
        !squash(&processor).contains("resolve_publish_work("),
        "the live plane has a ladder again",
    );
    for sender in ["publisher", "publish_proposals(", "publish_unrecorded("] {
        assert!(
            !resolve.contains(sender),
            "the live plane's disposition reaches `{sender}`: what it records is the \
             drive's alone to send",
        );
    }
    let drive = squash(
        fn_body(&processor, "pub(super) async fn drive_due(")
            .expect("processor.rs defines drive_due"),
    );
    assert!(
        drive.contains("Leashed{inner:driver.fanout.as_ref(),")
            && drive.contains("LeashedPublisher{inner:driver.publisher.as_ref(),")
            && drive.contains("Publishing{fanout:&fanout,publisher:&publisher,")
            && !drive.contains("self.publisher"),
        "the live plane's drive must send through the drive pool alone, never through the \
         engine's own client",
    );
    let core = squash(&production_source(
        &repo_root().join("haven-core/src/relay/live_sync/session.rs"),
    ));
    assert!(
        core.contains(
            "letdriver=LiveDriver::over(&drive_pool);\
             Self::assemble(circle,own_pubkey,driver,Some(drive_pool))"
        ),
        "the session's driver must be built over the drive pool it was handed",
    );
    let pool = squash(&production_source(
        &repo_root().join("haven-core/src/relay/live_sync/drive.rs"),
    ));
    assert!(
        pool.contains(
            "pubfnover(pool:&Arc<RelayManager>)->Self{Self{fanout:Arc::new(\
             pool.fanout_transport()),publisher:Arc::clone(pool)asArc<dynUnrecordedPublisher>,"
        ),
        "the product's driver must be the pool's own fanout transport and publish ladder",
    );
}

/// The drive pool is closed with ONE `disconnect`, which stops a relay's
/// connection task reliably only when that task has no retry schedule.
fn assert_one_disconnect_closes_the_drive_pool(session: &str) {
    let manager = std::fs::read_to_string(repo_root().join("haven-core/src/relay/manager.rs"))
        .expect("read manager.rs");
    let squashed = |body: &str| body.split_whitespace().collect::<String>();
    assert_eq!(
        squashed(
            fn_body(session, "async fn close_drive_pool").expect("session.rs closes the pool")
        ),
        "{ifletSome(pool)=&self.drive_pool{pool.shutdown().await;}}",
        "the drive pool is closed through `RelayManager::shutdown` and nothing else",
    );
    assert_eq!(
        squashed(fn_body(&manager, "pub async fn shutdown").expect("manager.rs has shutdown")),
        "{self.client.disconnect().await;}",
        "`RelayManager::shutdown` is one `disconnect`",
    );
    let options = fn_body(&manager, "fn publish_relay_options")
        .expect("manager.rs must define publish_relay_options");
    assert!(
        options.contains(".reconnect(false)"),
        "a publish relay must be registered with reconnection off: the drive pool is closed \
         with one `disconnect`, which leaves a reconnecting relay's task armed on the \
         crate's retry schedule, so it would re-open a socket inside a background gap",
    );
}

/// (i)'s half: the user is told a circle MDK halted, on every read and after
/// every restart, from MDK's persisted verdict — never from an in-memory set
/// a one-shot announcement filled, which a rejoin could not clear and a
/// restart forgot.
fn assert_the_circle_read_reports_the_engines_durable_verdict() {
    let manager = production_source(&repo_root().join("haven-core/src/circle/manager.rs"));
    for read in [
        "pub async fn get_circles(",
        "pub(crate) async fn engine_state(",
    ] {
        let body = fn_body(&manager, read).unwrap_or_else(|| panic!("{read}"));
        assert!(
            body.contains("self.session.unrecoverable(")
                && body.contains("CircleEngineState::Unrecoverable"),
            "{read} does not read MDK's durable unrecoverable verdict"
        );
    }
    // The one circle's read is that read.
    assert!(
        fn_body(&manager, "pub async fn get_circle(")
            .expect("get_circle")
            .contains("self.engine_state(mls_group_id)"),
        "pub async fn get_circle( does not read MDK's durable unrecoverable verdict"
    );
    assert!(
        !manager.contains("unrecoverable_groups"),
        "a product path reads an in-memory unrecoverable set"
    );
    let session = production_source(&repo_root().join("haven-core/src/nostr/mls/manager.rs"));
    let read = fn_body(&session, "pub(crate) async fn unrecoverable(").expect("the durable read");
    assert!(
        read.contains(".group_record(") && read.contains(".unrecoverable"),
        "the verdict is not MDK's persisted flag"
    );
    let processor =
        production_source(&repo_root().join("haven-core/src/relay/live_sync/processor.rs"));
    assert!(
        !processor.contains("report_unrecoverable_circles"),
        "a sweep repeats the verdict on the bus: the circle read already carries it"
    );
}

/// Every wake a drive runs in is cut at the end of the background burst the
/// live plane is in: the plane's own drive and every bridge entry's
/// `Publishing` take their deadline from `relay::fanout::wake_deadline`, so a
/// seal or drive Dart begins inside an iOS burst never begins work the OS
/// would cut (T-FOREGROUND-PEEL).
#[test]
fn every_wake_a_drive_runs_in_is_cut_at_the_burst_end() {
    let squash = |text: &str| -> String { text.chars().filter(|c| !c.is_whitespace()).collect() };
    let bridge = squash(&production_source(
        &repo_root().join("haven/rust_builder/src/api.rs"),
    ));
    let processor = squash(&production_source(
        &repo_root().join("haven-core/src/relay/live_sync/processor.rs"),
    ));
    assert_eq!(
        (
            bridge.matches("deadline_ms:").count(),
            bridge
                .matches("deadline_ms:Some(haven_core::relay::fanout::wake_deadline(self.circle,&self.clock,")
                .count(),
        ),
        (1, 1),
        "a bridge entry's wake is not cut at the live plane's burst end",
    );
    assert!(
        processor.contains(
            "letdeadline_ms=crate::relay::fanout::wake_deadline(&self.circle,clock,RESUME_BUDGET_MS);"
        ) && processor.matches("deadline_ms:").count() == 1,
        "the live plane's drive is not cut at its burst end",
    );
}

/// The pause's whole body in the order it runs: `pause_subscriptions`, with
/// the body of the `pause_locked` it delegates to spliced in where it calls it.
fn pause_body(session: &str) -> String {
    let wrapper = fn_body(session, "pub async fn pause_subscriptions(")
        .expect("session.rs must define pause_subscriptions");
    let Some(call) = wrapper.find("self.pause_locked(") else {
        return wrapper.to_owned();
    };
    let locked = fn_body(session, "async fn pause_locked(")
        .expect("pause_subscriptions delegates to a pause_locked session.rs must define");
    format!("{}{locked}{}", &wrapper[..call], &wrapper[call..])
}

/// The body of `fn <name>` in `src`, brace-balanced, or `None`.
fn fn_body<'a>(src: &'a str, signature: &str) -> Option<&'a str> {
    let start = src.find(signature)?;
    let open = start + src[start..].find('{')?;
    let mut depth = 0usize;
    for (offset, ch) in src[open..].char_indices() {
        match ch {
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if depth == 0 {
                    return Some(&src[open..=open + offset]);
                }
            }
            _ => {}
        }
    }
    None
}

/// The other direction of the same hold-back: only an event this plane would
/// actually have INGESTED may hold a cursor.
///
/// The drop is recorded before any routing, so the screen has to be made here or
/// it does not exist. A `kind:1059` carrying a stray `#h` is the reachable case:
/// the inbox REQ filters on kind and `#p` alone, so a fully conformant relay
/// delivers a wrap addressed to this account whatever `#h` its author put on it,
/// and a circle's `#h` is its PUBLIC `nostr_group_id`. Holding on that would let
/// an event the worker discards unread stall a circle it names — the shape
/// P0-5's `RejectedBeforeAuth` arm exists to refuse. A dropped wrap loses
/// nothing: the inbox stream re-requests a multi-day window on every REQ (96 h
/// on a re-anchor, 7 d on a cold start).
#[tokio::test]
async fn rule12_an_intake_drop_of_a_foreign_kind_holds_no_circle() {
    let dir = unique_temp_dir("rule12_stray_h");
    let circle = Arc::new(
        CircleManager::new_unencrypted(&dir, &Keys::generate()).expect("open a circle manager"),
    );
    let processor = Arc::new(EngineProcessor::new(
        Arc::clone(&circle),
        EventBus::with_capacity(16),
    ));
    let opened_at = chrono::Utc::now().timestamp() - 10;

    let target = hex::encode([0x33u8; 32]);
    processor.note_subscription_opened(&target, opened_at);
    let delivered = deliver_through_receiver(
        Arc::clone(&processor),
        64,
        1,
        &[
            h_tagged(Kind::GiftWrap, &target, opened_at - 100), // takes the single slot
            h_tagged(Kind::GiftWrap, &target, opened_at - 7_200), // dropped
        ],
    )
    .await;
    assert_eq!(
        delivered, 1,
        "precondition: a cap-1 queue must have dropped the second delivery, or the assertion \
         below is about nothing"
    );
    assert!(processor.note_end_of_stored_events(&target));
    assert_eq!(
        circle
            .read_sync_cursor(&group_cursor_stream(&target))
            .expect("read the target circle's cursor"),
        Some(opened_at * 1000),
        "a dropped event of a kind the group plane never ingests MUST NOT hold that circle's \
         cursor: anyone who reads a circle's public `#h` could otherwise stall it with traffic \
         the worker would have discarded unread"
    );

    cleanup_dir(&dir);
}

/// The COARSE half of the same rule: a loss the receive path cannot attribute to
/// any event must still not cost the backlog.
///
/// The pool hands the receiver its notifications over a broadcast, and a
/// broadcast that overruns reports a COUNT — no event, so no `created_at` to
/// hold a cursor at and no `#h` to hold it for. The per-event hold-back above is
/// unreachable here, and with nothing in its place every open generation's
/// `EOSE` advances its circle's cursor straight over events this process never
/// saw: the Rule-12 loss again, one layer up, and just as permanent (the
/// catch-up sweep re-derives its floor from the same per-circle cursor).
///
/// So the receiver suppresses the pending advance of EVERY generation open at
/// that moment, and the arms below are what "as wide as the ignorance" has to
/// mean: the circle that WAS delivered to does not advance; a co-multiplexed
/// circle
/// that nothing was delivered on does not advance either (the skip is not
/// attributable, so a rule narrowed to the circles named by surviving events
/// would advance that one over a skipped commit); the inbox does not advance
/// (one notification stream carries both planes). The control run — the same
/// deliveries over a broadcast with room, nothing skipped — still advances all
/// three, which is what stops this passing on cursors that simply never move.
/// The final arm requires the NEXT REQ to advance again: the suppression is a
/// stall scoped to the generations it hit, not a wedge someone can hold open.
#[tokio::test]
async fn rule12_a_delivery_gap_suppresses_every_open_generation() {
    let dir = unique_temp_dir("rule12_delivery_gap");
    let circle = Arc::new(
        CircleManager::new_unencrypted(&dir, &Keys::generate()).expect("open a circle manager"),
    );
    let processor = Arc::new(EngineProcessor::new(
        Arc::clone(&circle),
        EventBus::with_capacity(16),
    ));
    // A local reading in the recent past, so the advance's clamp at the wall
    // clock stays inert however long the test takes — no timing race.
    let opened_at = chrono::Utc::now().timestamp() - 10;
    let delivered_to = hex::encode([0x44u8; 32]);
    let co_multiplexed = hex::encode([0x55u8; 32]);
    let replay: Vec<Event> = (1..=6)
        .map(|i| backlog_445(&delivered_to, opened_at - i * 600))
        .collect();
    let group_cursor = |circle_hex: &str| {
        circle
            .read_sync_cursor(&group_cursor_stream(circle_hex))
            .expect("read a circle's cursor")
    };
    let inbox_cursor = || {
        circle
            .read_sync_cursor(haven_core::relay::cursor::STREAM_INBOX_1059)
            .expect("read the inbox cursor")
    };

    // ── Control: the same replay over a broadcast with room for it. Nothing is
    //    skipped, so every open generation redeems its EOSE.
    processor.note_subscription_opened(&delivered_to, opened_at);
    processor.note_subscription_opened(&co_multiplexed, opened_at);
    processor.note_inbox_subscription_opened(opened_at);
    let delivered = deliver_through_receiver(Arc::clone(&processor), 64, 64, &replay).await;
    assert_eq!(
        delivered,
        replay.len(),
        "precondition: a broadcast with room must skip nothing, or the control arm is not a \
         control"
    );
    assert!(processor.note_end_of_stored_events(&delivered_to));
    assert!(processor.note_end_of_stored_events(&co_multiplexed));
    assert!(processor.note_inbox_end_of_stored_events());
    assert_eq!(group_cursor(&delivered_to), Some(opened_at * 1000));
    assert_eq!(group_cursor(&co_multiplexed), Some(opened_at * 1000));
    assert_eq!(
        inbox_cursor(),
        Some(opened_at * 1000),
        "with nothing skipped every generation advances to its REQ's own open time — the \
         baseline the gate below has to differ from"
    );

    // ── The rule: the SAME replay over a 2-slot broadcast, published before the
    //    receiver is polled, so four deliveries are skipped and all the receiver
    //    ever learns is a count.
    let resumed_at = opened_at + 5;
    processor.note_subscription_opened(&delivered_to, resumed_at);
    processor.note_subscription_opened(&co_multiplexed, resumed_at);
    processor.note_inbox_subscription_opened(resumed_at);
    let delivered = deliver_through_receiver(Arc::clone(&processor), 2, 64, &replay).await;
    assert_eq!(
        delivered, 2,
        "precondition: a 2-slot broadcast must have skipped four of the six deliveries \
         outright, or there is no unattributable loss to assert about"
    );

    assert!(
        !processor.note_end_of_stored_events(&delivered_to),
        "an EOSE whose generation was open across a delivery skip MUST NOT advance a cursor \
         (Rule 12): the skipped events carry no timestamp anything can hold at, so advancing \
         discards them from every future REQ"
    );
    assert!(
        !processor.note_end_of_stored_events(&co_multiplexed),
        "a skip is attributable to NO circle, so a co-multiplexed circle nothing was delivered \
         on must be suppressed too — it is exactly the circle whose skipped commit nothing \
         else would ever re-request"
    );
    assert!(
        !processor.note_inbox_end_of_stored_events(),
        "one notification stream carries both planes, so a skip on it can have swallowed a \
         gift wrap: the inbox generation must be suppressed with the group ones"
    );
    assert_eq!(
        group_cursor(&delivered_to),
        Some(opened_at * 1000),
        "a suppressed generation must leave the cursor exactly where the last honest advance \
         put it — never forward over the skip, and never backward either"
    );
    assert_eq!(group_cursor(&co_multiplexed), Some(opened_at * 1000));
    assert_eq!(inbox_cursor(), Some(opened_at * 1000));

    // ── And the stall is bounded to those generations: the next REQ re-arms, so
    //    a party that could sustain a skip buys a repeated re-fetch of a window
    //    we already hold, never a cursor frozen for the session.
    processor.note_subscription_opened(&delivered_to, resumed_at);
    processor.note_inbox_subscription_opened(resumed_at);
    assert!(processor.note_end_of_stored_events(&delivered_to));
    assert!(processor.note_inbox_end_of_stored_events());
    assert_eq!(group_cursor(&delivered_to), Some(resumed_at * 1000));
    assert_eq!(inbox_cursor(), Some(resumed_at * 1000));

    cleanup_dir(&dir);
}

// ---------------------------------------------------------------------------
// Rule 13 — publish-before-apply, read as a ROUTING rule.
// ---------------------------------------------------------------------------

/// The repository root, one level above this crate.
fn repo_root() -> std::path::PathBuf {
    std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("haven-core sits inside the repository")
        .to_path_buf()
}

/// `path`'s production source: everything outside its `#[cfg(test)]` modules,
/// with comment lines removed so a gate matches CODE and never the prose
/// describing it.
///
/// What is cut is each test MODULE, to its closing brace, and nothing else: not
/// from the first `#[cfg(test)]` item on — several files gate a test-only
/// static or clock override far above their test module (`api.rs:1048`) — and
/// not from the first test module on either: the bridge's live-sync entries sit
/// BELOW its first one. Either cut would hide shipped code from a gate —
/// silently, which is the failure mode a gate must not have.
fn production_source(path: &std::path::Path) -> String {
    let src =
        std::fs::read_to_string(path).unwrap_or_else(|e| panic!("read {}: {e}", path.display()));
    production_text(&src, &path.display().to_string())
}

/// [`production_source`] of `src`, named `name` in a finding.
///
/// A skip that does not end where the test module does would hide whatever
/// follows — shipped code — from every gate, silently. So it fails loudly
/// instead: while a module is skipped, a line indented no deeper than the
/// module's own header that is not its closing brace means the closer was not
/// recognised (`} // tests`), or that the "module" was never one (a
/// `#[cfg(test)]` and a `mod x {` inside a block comment or a string); and a
/// skip still open at the end of the file means the same.
fn production_text(src: &str, name: &str) -> String {
    let mut out = String::with_capacity(src.len());
    let mut previous_gated = false;
    // The line that closes the test module being skipped, the header's
    // indentation and its line. Reading goes on after the closer: the bridge
    // has shipped code below its first test module, and a scan that stopped
    // there read none of it.
    let mut skipped: Option<(String, usize, usize)> = None;
    for (index, line) in src.lines().enumerate() {
        let trimmed = line.trim_start();
        let depth = line.len() - trimmed.len();
        if let Some((closer, header_depth, _)) = &skipped {
            if line == closer {
                skipped = None;
            } else {
                assert!(
                    trimmed.is_empty() || depth > *header_depth,
                    "{name}:{}: inside a skipped test module, a line no deeper than the \
                     module's header is not its closing brace: the skip would run on over \
                     whatever follows",
                    index + 1,
                );
            }
            out.push('\n');
            continue;
        }
        if previous_gated && trimmed.starts_with("mod ") && trimmed.ends_with('{') {
            skipped = Some((format!("{}}}", &line[..depth]), depth, index + 1));
            previous_gated = false;
            out.push('\n');
            continue;
        }
        previous_gated = trimmed.starts_with("#[cfg(test)]");
        // Keep the line (blanked) rather than dropping it, so the brace and
        // indentation shape the slicers rely on is unchanged.
        if trimmed.starts_with("//") {
            out.push('\n');
            continue;
        }
        out.push_str(line);
        out.push('\n');
    }
    if let Some((_, _, opened)) = skipped {
        panic!("{name}:{opened}: a skipped test module is not closed before the end of the file");
    }
    out
}

#[test]
fn the_gate_reader_skips_a_test_module_and_reads_on_behind_it() {
    let read = production_text(
        "fn shipped() {}\n#[cfg(test)]\nmod tests {\n    fn hidden() {}\n\n}\nfn also_shipped() {}\n",
        "case",
    );
    assert!(read.contains("fn shipped()") && read.contains("fn also_shipped()"));
    assert!(!read.contains("hidden"));
}

#[test]
#[should_panic(expected = "is not its closing brace")]
fn the_gate_reader_refuses_a_test_module_closed_with_a_trailing_comment() {
    let _ = production_text(
        "#[cfg(test)]\nmod tests {\n    fn hidden() {}\n} // tests\npub fn shipped() {}\n}\n",
        "case",
    );
}

#[test]
#[should_panic(expected = "is not its closing brace")]
fn the_gate_reader_refuses_a_test_module_that_is_only_text() {
    let _ = production_text(
        "/*\n#[cfg(test)]\nmod tests {\n*/\npub fn shipped() {}\nfn other() {\n}\n",
        "case",
    );
}

#[test]
#[should_panic(expected = "is not closed before the end of the file")]
fn the_gate_reader_refuses_a_test_module_left_open_at_the_end_of_the_file() {
    let _ = production_text(
        "fn shipped() {}\n#[cfg(test)]\nmod tests {\n    fn hidden() {}\n",
        "case",
    );
}

/// The `{ … }` block introduced by `header`, brace-matched.
fn block_after(src: &str, header: &str) -> String {
    let start = src
        .find(header)
        .unwrap_or_else(|| panic!("`{header}` is gone; the gate below no longer reads anything"));
    let mut depth = 0usize;
    let mut end = None;
    for (offset, ch) in src[start..].char_indices() {
        match ch {
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if depth == 0 {
                    end = Some(start + offset + 1);
                    break;
                }
            }
            _ => {}
        }
    }
    src[start..end.expect("an impl block that never closes would not compile")].to_string()
}

/// The body of the Rust `fn` enclosing the byte offset `at`.
///
/// Reads rustfmt's shape — a `fn` line and the `}` at the same indentation —
/// which `cargo fmt --check` enforces in CI, so no brace counting can be
/// confused by a `{}` inside a format string.
fn enclosing_fn(src: &str, at: usize) -> String {
    let lines: Vec<&str> = src.lines().collect();
    let line_of = src[..at].matches('\n').count();
    let (header, indent) = (0..=line_of)
        .rev()
        .find_map(|i| {
            let line = lines[i];
            let trimmed = line.trim_start();
            let is_fn = trimmed.starts_with("fn ")
                || trimmed.starts_with("async fn ")
                || trimmed.starts_with("pub fn ")
                || trimmed.starts_with("pub async fn ")
                || trimmed.starts_with("pub(crate) fn ")
                || trimmed.starts_with("pub(crate) async fn ");
            is_fn.then(|| (i, line.len() - trimmed.len()))
        })
        .unwrap_or_else(|| panic!("no enclosing fn above line {}", line_of + 1));
    let closer = format!("{}}}", " ".repeat(indent));
    let end = (header..lines.len())
        .find(|i| lines[*i] == closer)
        .unwrap_or(lines.len() - 1);
    lines[header..=end].join("\n")
}

/// Every `.rs` / `.dart` file under `dir`, recursively.
fn sources_under(dir: &std::path::Path, extension: &str, out: &mut Vec<std::path::PathBuf>) {
    for entry in
        std::fs::read_dir(dir).unwrap_or_else(|e| panic!("read_dir {}: {e}", dir.display()))
    {
        let path = entry.expect("dir entry").path();
        if path.is_dir() {
            sources_under(&path, extension, out);
        } else if path.extension().and_then(|e| e.to_str()) == Some(extension) {
            out.push(path);
        }
    }
}

/// How many Welcomes a change sent, and how many it carries, are exact counts
/// of the people invited (Security Rule 15). They are handed to the app as
/// numbers and reach nothing that renders text: in the core and the bridge no
/// formatting call — a log line, a formatted string, a panic, a `Debug`
/// field, a `to_string` — names either one. The hand-written `Debug`s of the
/// outcomes that carry them are pinned beside the driver
/// (`an_outcomes_debug_redacts_everything_but_where_the_change_stands`), and
/// no type that carries one derives `Debug`.
#[test]
fn the_counts_of_welcomes_sent_and_carried_reach_no_log_and_no_string() {
    const COUNTS: [&str; 2] = ["welcomes_sent", "welcomes_total"];
    const RENDERERS: [&str; 15] = [
        "log::trace!(",
        "log::debug!(",
        "log::info!(",
        "log::warn!(",
        "log::error!(",
        "format!(",
        "format_args!(",
        "write!(",
        "writeln!(",
        "print!(",
        "println!(",
        "eprintln!(",
        "panic!(",
        ".field(",
        ".expect(",
    ];
    let root = repo_root();
    let mut files = Vec::new();
    for dir in ["haven-core/src", "haven/rust_builder/src"] {
        sources_under(&root.join(dir), "rs", &mut files);
    }
    let mut carriers = 0;
    for path in files {
        let src = production_source(&path);
        if !COUNTS.iter().any(|count| src.contains(count)) {
            continue;
        }
        carriers += 1;
        for renderer in RENDERERS {
            for (at, _) in src.match_indices(renderer) {
                let arguments = parenthesised(&src[at + renderer.len() - 1..]);
                assert!(
                    !COUNTS.iter().any(|count| arguments.contains(count)),
                    "{}: `{renderer}…)` renders a count of Welcomes",
                    path.display()
                );
            }
        }
        for count in COUNTS {
            assert!(
                !src.contains(&format!("{count}.to_string()")),
                "{}: a count of Welcomes is turned into a string",
                path.display()
            );
        }
        // A type that carries one never derives `Debug`.
        for (at, _) in src.match_indices("#[derive(") {
            let derive = &src[at..at + src[at..].find(']').expect("a derive closes")];
            let item = block_after(&src[at..], "{");
            assert!(
                !(derive.contains("Debug") && COUNTS.iter().any(|count| item.contains(count))),
                "{}: a type carrying a count of Welcomes derives `Debug`",
                path.display()
            );
        }
    }
    assert!(
        carriers > 0,
        "nothing names the counts any more; this gate reads nothing"
    );
}

/// The `( … )` group `src` opens with, parenthesis-matched.
fn parenthesised(src: &str) -> &str {
    let mut depth = 0usize;
    for (offset, ch) in src.char_indices() {
        match ch {
            '(' => depth += 1,
            ')' => {
                depth -= 1;
                if depth == 0 {
                    return &src[..=offset];
                }
            }
            _ => {}
        }
    }
    src
}

/// (a) + (b): a commit leaves through its fanout alone
/// (`a_fanout_is_the_only_way_a_commit_leaves_the_device`); the one product
/// `UnrecordedPublisher`, which sends what has no record, answers sent only
/// on a relay's OK and never takes the location path.
fn assert_commit_publishers_keep_the_ladder(root: &std::path::Path) {
    let driver = production_source(&root.join("haven-core/src/relay/fanout.rs"));
    assert_eq!(
        driver.matches("impl UnrecordedPublisher for").count(),
        1,
        "a second product publisher of what has no record",
    );
    let via_manager = block_after(
        &driver,
        "impl UnrecordedPublisher for super::RelayManager {",
    );
    assert!(
        via_manager.contains(concat!("publish", "_event(")),
        "what has no record is published through the publish client's ladder; \
         found: {via_manager}",
    );
    assert!(
        via_manager.contains(".is_ok_and(|result| result.is_success())"),
        "\"acked\" means at least one relay returned OK, never merely that the \
         event was sent (Rule 13): {via_manager}",
    );
    assert!(
        !via_manager.contains(concat!("publish_location", "_event")),
        "something published on the location path would be re-sent never: {via_manager}",
    );
}

/// (c), Rust half: no FUNCTION publishes a location and resolves a staged
/// commit.
///
/// Function-scoped rather than file-scoped because `api.rs` legitimately holds
/// both planes — it is the FFI surface for all of them — and that file is
/// exactly where a convenient shortcut between them would be written.
fn assert_no_rust_function_publishes_a_location_and_a_commit(root: &std::path::Path) {
    let mut sources = Vec::new();
    sources_under(&root.join("haven-core/src"), "rs", &mut sources);
    sources_under(&root.join("haven/rust_builder/src"), "rs", &mut sources);
    // The FRB dispatcher is one generated function over every FFI method, so it
    // names both planes by construction. It mirrors `api.rs`, which IS scanned,
    // and is never hand-edited.
    sources.retain(|path| {
        !path
            .file_name()
            .and_then(|n| n.to_str())
            .is_some_and(|n| n.starts_with("frb_generated"))
    });

    // The legacy entry, the transport both entries share, the driver's own
    // send of a recorded location, and the entry that passes a fellow
    // member's mesh update on behind it — the one the bridge calls.
    let location_publishes = [
        concat!("publish_location", "_event"),
        concat!("send_", "location("),
        concat!(".publish_", "location("),
        concat!(".publish_location", "_and_bridge("),
    ];
    let pending_words = [
        "PendingStateRef",
        concat!("confirm", "_published"),
        concat!("publish", "_failed"),
    ];
    let mut files_reached: Vec<String> = Vec::new();
    for path in &sources {
        let src = production_source(path);
        for location_publish in location_publishes {
            let mut from = 0;
            while let Some(offset) = src[from..].find(location_publish) {
                let at = from + offset;
                from = at + location_publish.len();
                let body = enclosing_fn(&src, at);
                for word in pending_words {
                    assert!(
                        !body.contains(word),
                        "{} publishes a location from a function that also handles \
                         `{word}`; a staged commit resolved on one bounded attempt \
                         is exactly the Rule 13 fork:\n{body}",
                        path.display(),
                    );
                }
                files_reached.push(path.display().to_string().replace('\\', "/"));
            }
        }
    }

    assert!(
        files_reached
            .iter()
            .any(|f| f.ends_with("relay/manager.rs")),
        "the location publish itself has to be in scope or this gate reads \
         nothing: {files_reached:?}",
    );
    assert!(
        files_reached.iter().any(|f| f.ends_with("relay/fanout.rs")),
        "the driver's own send of a recorded location has to be in scope: {files_reached:?}",
    );
    assert!(
        files_reached
            .iter()
            .any(|f| f.ends_with("rust_builder/src/api.rs")),
        "the FFI wrapper has to be in scope: it is the one place where the \
         location path and the staged-commit path share a file: {files_reached:?}",
    );
}

/// (c), Dart half: no app Dart file resolves a staged commit at all — the
/// driver does, in Rust — and the two planes that send a location are found
/// by their call to the driver's one send.
///
/// The generated bindings are excluded: they DECLARE every FFI method and so
/// name both planes by construction, and they hold no call sites.
///
/// # Both spellings of "resolve a staged commit"
///
/// Dart reaches the resolution two ways: straight through the FFI
/// (`CircleManagerFfi.confirmPublished` / `.publishFailed`) and through
/// `CircleService.confirmPendingCommit` / `.failPendingCommit`, the interface
/// the foreground poll planes hold because they own no Rust-side relay handle.
/// Both pairs are listed: listing one would leave the other free.
fn assert_no_dart_file_publishes_a_location_and_a_commit(root: &std::path::Path) {
    let mut sources = Vec::new();
    sources_under(&root.join("haven/lib/src"), "dart", &mut sources);
    sources.retain(|path| {
        !path
            .to_string_lossy()
            .replace('\\', "/")
            .contains("/lib/src/rust/")
    });
    assert!(
        sources.len() > 50,
        "the Dart scan found almost nothing, so it proves nothing: {}",
        sources.len(),
    );

    // Since the ladder went (W9o-1b) no app Dart resolves a staged commit at
    // all: every commit is confirmed or rolled back in Rust, by the driver,
    // on a relay's acknowledgement (Security Rule 13). So the words are
    // absent from every file, not only from the ones that send a location.
    let mut publishers: Vec<String> = Vec::new();
    for path in &sources {
        let src = std::fs::read_to_string(path).expect("read dart source");
        for word in [
            concat!("confirm", "Published("),
            concat!("publish", "Failed("),
            concat!("confirm", "PendingCommit("),
            concat!("fail", "PendingCommit("),
        ] {
            assert!(
                !src.contains(word),
                "{} resolves a staged commit (`{word}`) in Dart: the driver confirms or \
                 rolls back every commit in Rust, on a relay's acknowledgement",
                path.display(),
            );
        }
        if [
            concat!("publishSealed", "Location("),
            concat!(".publish", "Location("),
        ]
        .iter()
        .any(|send| src.contains(send))
        {
            publishers.push(path.display().to_string().replace('\\', "/"));
        }
    }

    // Anti-vacuity, on the files the loop actually READ: the two planes that
    // send a location through the driver's one send — the foreground's
    // service and the Android service — are found by their call, so a rename
    // that hides them fails here instead of leaving the scan reading nothing.
    for expected in [
        "services/location_sharing_service.dart",
        "services/background_location_task.dart",
    ] {
        assert!(
            publishers.iter().any(|f| f.ends_with(expected)),
            "{expected} no longer reaches the driver's location send, so this gate read \
             nothing there. Either the send moved (point this at its new home) or it was \
             renamed: {publishers:?}",
        );
    }
}

/// A location publish takes the one-shot fan-out; a COMMIT keeps its retries.
///
/// The two paths differ in what a miss costs. A location that no relay acked is
/// superseded by the next tick within 168 s, so one bounded attempt is the
/// whole budget. A commit that is neither confirmed nor rolled back leaves the
/// group at an epoch its peers never received — Rule 13 — so its fanout
/// record keeps each relay's retry schedule AND the confirm/rollback decision
/// on a real OK-ack.
///
/// Nothing in the type system keeps them apart: both take an `&Event` and a
/// relay list. So the predicates that DO keep them apart are asserted on
/// the source, where a reviewer would otherwise have to notice them.
///
/// A location has a durable record too, and it is not a retry: the record
/// ends with the one send it is for, whatever that send was answered, and a
/// record a process's death leaves is deleted unsent.
#[test]
fn rule13_commits_keep_the_retry_ladder_and_locations_do_not() {
    let root = repo_root();
    assert_commit_publishers_keep_the_ladder(&root);
    assert_no_rust_function_publishes_a_location_and_a_commit(&root);
    assert_no_dart_file_publishes_a_location_and_a_commit(&root);
    assert_a_completed_location_send_is_never_made_again(&root);
}

/// (d): a location's record ends with its send.
///
/// What keeps it a single send is pinned here: the transport makes ONE
/// attempt a relay; the record's own send deletes the record as soon as the
/// transport has answered, on every answer; and a drive hands no location to
/// a transport at all — a record it finds, a dead process's included, is
/// deleted.
fn assert_a_completed_location_send_is_never_made_again(root: &std::path::Path) {
    let squash = |text: &str| text.split_whitespace().collect::<String>();
    let manager = production_source(&root.join("haven-core/src/relay/manager.rs"));
    assert!(
        squash(&manager).contains("constLOCATION_PUBLISH_ATTEMPTS:u32=1;")
            && squash(fn_body(&manager, "async fn send_location(").expect("send_location"))
                .contains("publish_with_retry(LOCATION_PUBLISH_ATTEMPTS,Duration::ZERO,"),
        "a location's transport makes more than one attempt a relay",
    );
    let fanout = production_source(&root.join("haven-core/src/relay/fanout.rs"));
    let own =
        squash(fn_body(&fanout, "pub async fn publish_location(").expect("the record's own send"));
    assert!(
        own.matches(".publish_location(").count() == 1
            && own.contains(
                "letsent=self.fanout.publish_location(event,&record.relays).await;\
                 let_=session.end_location(&message).await;LocationPublish::Sent(sent)"
            ),
        "a location's own send no longer ends its record with the transport's answer, \
         whatever that answer is: a send that returned could be made again",
    );
    // A location sealed for the mesh alone leaves between the hand-off and
    // the transport, its record ended: nothing stands between the two that
    // could let it through to a relay, and nothing is left to send later.
    assert!(
        own.contains(
            "session.mesh_offer(event,&record);ifrecord.mesh_only{\
             let_=session.end_location(&message).await;returnLocationPublish::MeshOnly;}\
             letsent=self.fanout.publish_location(event,&record.relays).await;"
        ) && own.matches("mesh_only").count() == 1,
        "a location sealed for the mesh alone is no longer turned back, its record ended, \
         immediately before the one relay send",
    );
    let drive =
        squash(fn_body(&fanout, "async fn settle_locations(").expect("the drive's location pass"));
    assert!(
        !drive.contains("publish_location")
            && !drive.contains("transport")
            && drive.contains("let_=session.end_location(record.id.message()).await;"),
        "a drive sends a location record it finds, or keeps one: a fix whose send another \
         process began could be sent again, after its user stopped sharing",
    );
}

/// The mesh's ingress sends nothing (Security Rule 13.1; the mesh design's
/// review, finding 2): `Publishing::mesh_drive` names neither transport and
/// none of the driver's functions that reach one, takes its events in the
/// finish-only mode alone, and folds what the engine hands back without an
/// advance. When a relay hears from this device may not follow from a packet
/// anyone in radio range can replay. `tests/mesh_drive_e2e.rs` counts the
/// calls; this reads the paths those runs do not take.
#[test]
fn a_mesh_drive_names_nothing_that_reaches_a_relay() {
    let fanout = production_source(&repo_root().join("haven-core/src/relay/fanout.rs"));
    let body: String = fn_body(&fanout, "pub async fn mesh_drive(")
        .expect("the mesh drive")
        .split_whitespace()
        .collect();
    for sends in [
        "self.fanout",
        "self.publisher",
        "settle(",
        "settle_staged(",
        "drive_rows(",
        "drive_due(",
        "drive_one(",
        "send_unrecorded(",
        "unblock(",
        "absorb(",
        "dispose(",
        "deliver_welcomes(",
        "resume(",
        "publish_location(",
        "process_event_staging(",
        "DriveMode::Full",
        "self.mode",
    ] {
        assert!(
            !body.contains(sends),
            "`mesh_drive` names `{sends}`: a mesh packet could then make this device call a \
             relay, or commit",
        );
    }
    assert!(
        body.contains("Still::always(&DriveMode::FinishOnly)")
            && body.contains("circle.fold_staged(effects,false,now_ms,still)")
            && body.matches("ingest_from_mesh(").count() == 1
            && body.contains("for(_,event)insession.order_for_ingest(&group_id,events).await{"),
        "`mesh_drive` no longer takes each event in once, in the order every receive plane \
         takes a circle's events in, finish-only, with no advance",
    );
    // The update a packet carried is taken out of the hold's batch and folded
    // by the one fold that stamps no inbound arrival: whether this device
    // makes an epoch-rotation repair — a commit its relays see — may not turn
    // on what a phone in radio range sent. And it is counted, and kept to be
    // passed on, only where its packet is settled.
    let circles = production_source(&repo_root().join("haven-core/src/circle/manager.rs"));
    let update: String = fn_body(&circles, "pub(crate) async fn fold_mesh_update(")
        .expect("the fold of a mesh update")
        .split_whitespace()
        .collect();
    assert!(
        body.contains(
            "ifletSome(update)=update{(drive.replayed).extend(circle.fold_mesh_update(update)\
             .await);}"
        ) && update == "{self.fold_resolved_batch(std::slice::from_ref(&update)).await}"
            && circles.matches("fold_mesh_update(").count() == 1,
        "an update the mesh brought is folded where an inbound arrival is stamped",
    );
    assert!(
        body.contains(
            "iftaken_in{drive.from_circles+=u64::from(new);\
             session.mesh_taken_in(&group_id,&event,update.as_ref(),&mutdrive);}"
        ) && body.matches("from_circles+=").count() == 1,
        "an update is counted, or kept to be passed on, though its packet is still held",
    );
    let manager = production_source(&repo_root().join("haven-core/src/nostr/mls/manager.rs"));
    let ingest: String = fn_body(&manager, "pub(crate) async fn ingest_from_mesh(")
        .expect("the mesh ingest")
        .split_whitespace()
        .collect();
    let relayed: String = fn_body(&manager, "async fn staging_ingest(")
        .expect("the staging ingest")
        .split_whitespace()
        .collect();
    assert!(
        ingest.contains("letstill=Still::always(&DriveMode::FinishOnly);")
            && ingest.contains("self.staging_ingest(event,now_ms,still,true).await?")
            && relayed.contains("&result,mode==DriveMode::Full,);"),
        "the mesh ingest is no longer finish-only, or an ingest in that mode feeds the stall \
         detector",
    );
    // A location's send reads how often a circle fell silent BEFORE its
    // send-time check, and hands that to the key sync after it: a circle
    // silenced while the check ran — with no engine hold — gets no hand-off.
    let send: String = fn_body(&manager, "pub(crate) async fn location_to_send(")
        .expect("the send-time check")
        .split_whitespace()
        .collect();
    let (read, check, sync) = (
        send.find("letsilences=self.mesh_silences(&application.group_id);"),
        send.find("self.location_may_be_sent("),
        send.find("self.mesh_turn(&*session,&application.group_id,now_ms,silences)"),
    );
    assert!(
        read.is_some() && read < check && check < sync,
        "a send no longer reads the ring's silences before its check and hands them to its \
         key sync after it",
    );
}

/// What a relay is asked does not turn on what the mesh brought (the mesh
/// design's rule that the relay path is the same with mesh on and off): an
/// event a packet carried is noted nowhere the relay path reads what it has
/// seen, and a circle's unread input is held before the circle falls silent.
/// `tests/negentropy_e2e.rs` compares the frames a relay is sent; this reads
/// the paths that run does not take.
#[test]
fn what_the_mesh_brings_is_noted_nowhere_the_relay_path_reads() {
    let manager = production_source(&repo_root().join("haven-core/src/nostr/mls/manager.rs"));
    let relayed: String = fn_body(&manager, "async fn staging_ingest(")
        .expect("the staging ingest")
        .split_whitespace()
        .collect();
    // What a relay is asked may not turn on what the mesh brought: an event
    // a packet carried never reaches the notes a relay's event leaves — the
    // NIP-77 pass's memory, the pager's hold, the stall detector's arm — and
    // the engine's word that it let the event go is taken out of its batch
    // before the batch is noted, so that it is owed no refetch.
    let body = |signature: &str| -> String {
        fn_body(&manager, signature)
            .unwrap_or_else(|| panic!("{signature}"))
            .split_whitespace()
            .collect()
    };
    assert!(
        relayed.contains(
            "ifletOk(batch)=&mutresult{batch.effects.events.retain(|refused|{!matches!(refused,\
             GroupEvent::TransportObjectResourceRefused{message_id,..}if*message_id==id)});}}\
             else{self.note_ingested("
        ) && relayed.contains("letmutresult=self.ingest_faulted(result);iffrom_mesh{")
            && relayed.matches("note_ingested(").count() == 1
            && manager.matches("self.staging_ingest(").count() == 2
            && body("pub(crate) async fn process_event_staging(")
                == "{self.staging_ingest(event,now_ms,still,false).await}",
        "an event the mesh brought is noted as one a relay served, or a relay's as the mesh's",
    );
    // A circle falls silent on mesh only once its hold stands: a seal that
    // begins after the silence then reads the hold.
    for signature in [
        "pub(crate) fn hold_pager_commits<'a>(",
        "pub(crate) fn hold_live_replay(",
    ] {
        let text = body(signature);
        let (stands, silenced) = (
            text.find("self.unread()"),
            text.find("self.mesh_keys.silence(group_id);"),
        );
        assert!(
            stands.is_some()
                && stands < silenced
                && text.ends_with("self.mesh_keys.silence(group_id);}"),
            "a circle is silenced on mesh before its unread input is held",
        );
    }
}

/// The seal for the mesh alone sends nothing (plan §7.7 R1): a burst whose
/// receive failed may put a location on the radio, and may not make this
/// device call a relay — not for a commit of its own that is pending, not
/// for a record its hold wrote, not for a repair. `Publishing::seal_for_mesh`
/// names neither transport and none of the driver's functions that reach
/// one, seals in the finish-only mode whatever its caller's, and marks what
/// it seals as the mesh's alone in the hold that records it.
/// `tests/mesh_only_e2e.rs` counts the calls; this reads the paths those
/// runs do not take.
#[test]
fn a_seal_for_the_mesh_names_nothing_that_reaches_a_relay() {
    let fanout = production_source(&repo_root().join("haven-core/src/relay/fanout.rs"));
    let body: String = fn_body(&fanout, "pub async fn seal_for_mesh(")
        .expect("the seal for the mesh")
        .split_whitespace()
        .collect();
    for sends in [
        "self.fanout",
        "self.publisher",
        "settle(",
        "settle_staged(",
        "drive_rows(",
        "drive_due(",
        "drive_one(",
        "send_unrecorded(",
        "unblock(",
        "absorb(",
        "dispose(",
        "deliver_welcomes(",
        "resume(",
        "older(",
        "publish_location(",
        "repair_deferred_send_staging(",
        "DriveMode::Full",
        "self.mode",
    ] {
        assert!(
            !body.contains(sends),
            "`seal_for_mesh` names `{sends}`: a seal for the mesh alone could then make this \
             device call a relay, or commit",
        );
    }
    let (off, staging) = (
        body.find("if!session.mesh_is_on(now_ms){returnOk(deferred(SendHeld::Nothing,None));}"),
        body.find(".seal_location_staging("),
    );
    assert!(
        off.is_some() && off < body.find(".await") && off < staging,
        "`seal_for_mesh` asks the engine for something before it has read that mesh is on",
    );
    assert!(
        body.contains(
            ".seal_location_staging(group_id,location,now_ms,\
             Still::always(&DriveMode::FinishOnly),self.clock,self.deadline_ms,true,)"
        ) && body.contains(
            ".sealed_or_held(circle,group_id,sealed,departure_due,&DriveMode::FinishOnly,)"
        ),
        "`seal_for_mesh` no longer seals finish-only, marked as the mesh's alone",
    );
    // The mark is kept with the record's entry in the hold that writes the
    // record, and read back by the send-time check — from the session, which
    // a process that did not seal the location does not share.
    let manager = production_source(&repo_root().join("haven-core/src/nostr/mls/manager.rs"));
    let record: String = fn_body(&manager, "fn record_location(")
        .expect("the record's hold")
        .split_whitespace()
        .collect();
    let send: String = fn_body(&manager, "pub(crate) async fn location_to_send(")
        .expect("the send-time check")
        .split_whitespace()
        .collect();
    assert!(
        record.contains(".insert(recorded.id.message().clone(),mesh_only);")
            && send.contains("letmay_be_sent=sealed_here.is_some()&&self.location_may_be_sent(")
            && send.contains("mesh_only:sealed_here==Some(true),"),
        "the mesh-only mark is no longer written with the record and read at its send",
    );
    // The other seal — the relay path's — marks nothing.
    let relayed: String = fn_body(&fanout, "pub async fn seal_location(")
        .expect("the relay path's seal")
        .split_whitespace()
        .collect();
    assert!(
        relayed.contains("self.clock,self.deadline_ms,false,)"),
        "the relay path's seal marks its location as the mesh's alone",
    );
}

/// Member bridging (plan §5.5, owner decision D-7; Security Rule 13.1 as
/// amended): the one send of a `kind:445` this device did not seal, and the
/// one with no fanout record. What keeps it to that is pinned here:
///
/// - it has one way in, `Publishing::publish_location_and_bridge`, which
///   makes this device's own send first and hands the bridge only the relays
///   that took it — so a drive that publishes nothing of its own passes
///   nothing on, and no relay is told of a circle by this device that has not
///   just taken this device's own update of it;
/// - the bridge takes what the circle kept once, sends each event once,
///   immediately behind its own check against the engine, and reads no
///   answer: no record, no retry, nothing for the health model or the
///   clock-skew detector;
/// - the record's own send (`publish_location`) is untouched by it, and
///   nothing else in the three source trees reaches the session's two bridge
///   entries.
///
/// `tests/mesh_bridge_e2e.rs` holds the behaviour; this reads the paths
/// those runs do not take.
#[test]
fn the_bridge_sends_once_and_reads_no_answer() {
    let squash = |text: &str| -> String { text.split_whitespace().collect() };
    let fanout = production_source(&repo_root().join("haven-core/src/relay/fanout.rs"));
    let entry = squash(
        fn_body(&fanout, "pub async fn publish_location_and_bridge(").expect("the bridge's entry"),
    );
    assert!(
        entry
            == "{letpublish=self.publish_location(circle,event).await;\
                ifletSome(group_id)=circle.group_of_event(event){\
                letaccepted=match&publish{\
                LocationPublish::Sent(Ok(sent))=>sent.accepted_by.as_slice(),_=>&[],};\
                self.bridge_locations(circle,&group_id,accepted,received).await;}publish}",
        "the bridge's entry no longer makes this device's own send first, hands the bridge \
         the relays that took it and no others, and answers with its own send's answer \
         alone: {entry}",
    );
    let bridge = squash(fn_body(&fanout, "async fn bridge_locations(").expect("the bridge"));
    assert!(
        bridge.matches(".publish_location(").count() == 1
            && bridge.contains("let_=self.fanout.publish_location(&event,&targets).await;")
            && bridge.matches("mesh_bridge_take(").count() == 1
            && bridge.contains("forupdateinsession.mesh_bridge_take(group_id,received){")
            && bridge.contains(
                "ifletSome((event,targets))=session.mesh_bridge_check(group_id,update,relays,\
                 now_ms,mode).await{let_=self.fanout.publish_location(&event,&targets).await;}"
            ),
        "the bridge no longer takes what waits once and sends each event once, straight \
         behind its own check, reading no answer: {bridge}",
    );
    for reads in [
        "end_location",
        "record",
        "Pass",
        "pass.",
        "clock_rejected",
        "self.publisher",
        "send_unrecorded(",
        "drive_rows(",
        "settle(",
        "absorb(",
        "retry",
    ] {
        assert!(
            !bridge.contains(reads),
            "the bridge names `{reads}`: a passed-on event could then be recorded, retried, \
             or its answer read",
        );
    }
    assert!(
        fanout.matches("bridge_locations(").count() == 2,
        "the bridge has a caller beside `publish_location_and_bridge`: an update could be \
         passed on by a drive that sent nothing of its own",
    );
    for file in scanned_sources() {
        let name = file.to_string_lossy().replace('\\', "/");
        let source = production_source(&file);
        for entry in ["mesh_bridge_take(", "mesh_bridge_check("] {
            let named = source.matches(entry).count();
            let allowed = usize::from(
                name.ends_with("haven-core/src/relay/fanout.rs")
                    || name.ends_with("haven-core/src/nostr/mls/manager.rs"),
            );
            assert!(
                named == allowed,
                "{name} names `{entry}` {named} time(s): the bridge is its one caller",
            );
        }
    }
    // What is kept to be passed on is checked against the engine as a
    // location of this device's own is, at the epoch it was sealed at, and
    // handed to no relay but the circle's own that took this device's send.
    let manager = production_source(&repo_root().join("haven-core/src/nostr/mls/manager.rs"));
    let check = squash(
        fn_body(&manager, "pub(crate) async fn mesh_bridge_check(").expect("the bridge's check"),
    );
    assert!(
        check.contains("let(event,epoch,sender)=update.in_time(now_ms)?;")
            && check.contains(
                "self.location_may_be_sent(&mutsession,group_id,EpochId(epoch),now_ms,mode)\
                 &&self.caught_up(group_id)&&!self.holds_unread_input(group_id);"
            )
            && check.contains("fanout_targets(&session,group_id)")
            && check.contains("accepted.contains(&url)")
            && check.contains("self.mesh_keys.bridges(group_id,&sender,now_ms)"),
        "the bridge's check no longer reads, in one hold, what a location's own send reads: \
         {check}",
    );
}

/// MDK's own host, `marmot-account/src/runtime.rs`. Haven may not depend on
/// that crate; its source ships in the same repository, at the pinned
/// revision.
fn mdk_host_source() -> String {
    mdk_source("marmot-account/src/runtime.rs")
}

/// A file of MDK's, by its path under the crates directory of the checkout
/// cargo resolved the MDK crates this one links from.
fn mdk_source(file: &str) -> String {
    let metadata = cargo_graph::host_metadata();
    let manifest = metadata["packages"]
        .as_array()
        .expect("packages")
        .iter()
        .find(|package| package["name"] == "transport-nostr-adapter")
        .and_then(|package| package["manifest_path"].as_str())
        .expect("the adapter is in the graph");
    let crates = std::path::Path::new(manifest)
        .parent()
        .and_then(std::path::Path::parent)
        .expect("the MDK crates directory");
    std::fs::read_to_string(crates.join(file)).expect("read MDK's source")
}

/// Three things of MDK's that Haven's handling of what the engine parks,
/// refuses and errs on rests on, each re-read at a bump.
///
/// The streaming read: Haven lists a circle's parked rows, and looks for a
/// proposal of the current epoch, with `visit_messages_in_states`, and
/// counts on its three properties — the state filter is in SQL, rows come in
/// insert order, and the visit stops when its visitor says so. Without the
/// first a look decodes every row in every state; without the last two it
/// decodes every matching row. The filter bounds decoding, not reading:
/// `SQLite` walks the circle's insert-order index and tests each row's state,
/// so a look with nothing to stop on steps over the circle's whole history.
///
/// The admission rule: every commit at or above the circle's epoch enters
/// convergence before anything else is done with it. It is why the engine's
/// second mint of a leave (`ingest.rs`, beside the commit it applies there)
/// is not reached from a relay's delivery, and so why a plane that makes no
/// commit hands nothing back from an ingest to be published.
///
/// The record-then-err order: the engine stores an opened message's row and
/// its processed id in ONE transaction and only then asks `OpenMLS` to
/// process it, so an error from there — a generation further ahead than the
/// forward distance, here a thousand — leaves the engine holding its own
/// record of the event. Haven ends its copy on exactly that.
#[test]
fn mdks_visitor_admission_rule_and_record_before_processing_are_what_haven_counts_on() {
    let squash = |text: &str| text.split_whitespace().collect::<String>();
    let store = squash(&mdk_source("storage-sqlite/src/storage/messages.rs"));
    let visit = &store[store
        .find("fnvisit_messages_in_states(")
        .expect("MDK's SQLite store no longer has its own streaming read")..];
    let visit = &visit[..visit[1..].find("fn").map_or(visit.len(), |next| next + 1)];
    assert!(
        visit.contains("WHEREgroup_id=?1ANDepoch>=?2ANDstateIN({})ORDERBYinsert_order")
            && visit.contains("forrowinrows{if!visitor(decode_message_columns(")
            && visit.contains("{break;}"),
        "MDK's streaming read no longer filters by state in SQL, visits in insert order, or \
         stops when its visitor says so: re-read `stranded_rows` and `proposal_stands`",
    );
    assert!(
        squash(&mdk_source("traits/src/storage.rs")).contains(
            "fnvisit_messages_in_states(&self,group_id:&GroupId,states:&[MessageState],\
             at_or_after_epoch:EpochId,visitor:&mutdynFnMut(MessageRecord)->bool,)\
             ->StorageResult<()>"
        ),
        "the streaming read's signature changed",
    );

    let ingest = squash(&mdk_source("cgka-engine/src/message_processor/ingest.rs"));
    assert!(
        ingest.contains(
            "letcommit_should_enter_convergence=ifmsg_content_type==ContentType::Commit{\
             ifmsg_epoch>=current_epoch{true}else{"
        ) && ingest.contains(
            "ifcommit_should_enter_convergence{returnreported(\
             self.buffer_openmls_message_into_convergence("
        ),
        "MDK no longer sends every commit at or above the circle's epoch into convergence \
         first: re-read whether an ingest can now mint a leave for a relay's delivery",
    );
    let recorded = ingest
        .find(
            "matchself.storage.with_transaction(|_storage|{\
             self.persist_openmls_wire_message_with_processed_transport_id(",
        )
        .expect("the row and its processed id are no longer written in one transaction");
    let processed = ingest[recorded..]
        .find("mls_group.process_message(&provider,proto)")
        .expect("the message is no longer processed after its record is written");
    assert!(
        ingest[recorded + processed..].contains(
            "self.update_stored_message_state(&msg.id,MessageState::Retryable)?;\
             returnErr(EngineError::Backend(format!("
        ),
        "MDK no longer records an opened message before it processes it, or no longer \
         answers an unclassified processing failure with an error: re-read `hand_back`",
    );
    assert!(
        squash(&mdk_source("cgka-engine/src/wire_format.rs"))
            .contains("pubconstDEFAULT_MAXIMUM_FORWARD_DISTANCE:u32=1_000;"),
        "MDK's forward distance changed: the recipe a test errs the engine with changes too",
    );
}

/// What Haven's departure read leaves out is what MDK never leaves a proposal
/// still to be committed in. `proposal_stands` reads a circle's `Created`,
/// `Retryable` and `ConvergenceDeferred` rows and not its `Processed` ones,
/// where every location ends, because MDK marks a proposal `Processed` only
/// where a commit consumes it: a convergence pass accepts only what its
/// selected branch consumed, written with the group record that branch moves
/// on, and the confirm of this device's own commit marks what it consumed
/// inside the transaction that merges it and writes the new epoch. And it
/// asks MDK's existence probe first, which must stay a probe with no ordering:
/// an ordered read walks the group's rows.
#[test]
fn mdk_marks_a_proposal_processed_only_where_a_commit_consumes_it() {
    let squash = |text: &str| text.split_whitespace().collect::<String>();
    let canonical = squash(&mdk_source("cgka-engine/src/canonicalization.rs"));
    assert!(
        canonical.matches("result.accepted_proposals.push(").count() == 1
            && canonical.contains(
                "}elseifcontext.selected_consumed_proposal_ids.contains(&message.message_id)\
                 {result.accepted_proposals.push(message.message_id.clone());}"
            ),
        "MDK's convergence now accepts a proposal its selected branch did not consume: \
         re-read `UNRESOLVED` in `proposal_stands`",
    );
    let projection = squash(&mdk_source("cgka-engine/src/openmls_projection.rs"));
    assert!(
        projection
            .matches("persist_openmls_canonicalization_dispositions(")
            .count()
            == 1
            && projection.contains(
                "update_group_record_from_replay(storage,group_id,&output)?;\
                 persist_openmls_canonicalization_dispositions(storage,result)?;"
            ),
        "MDK no longer writes a pass's dispositions with the group record they move",
    );
    let publish = squash(&mdk_source("cgka-engine/src/publish.rs"));
    let confirm = publish
        .find("self.storage.with_transaction(|storage|->Result<(),EngineError>{")
        .expect("the confirm no longer runs in one transaction");
    let written = publish[confirm..]
        .find("storage.put_group(&g)?;")
        .expect("the confirm no longer writes the group record");
    let confirm = &publish[confirm..confirm + written];
    assert!(
        confirm.contains("mark_consumed_proposal_records_processed(")
            && confirm.contains("merge_pending_commit(&tx_provider)")
            && confirm.contains("g.epoch=EpochId(mls_group.epoch().as_u64());"),
        "MDK no longer marks what its own commit consumed in the transaction that merges it \
         and writes the new epoch",
    );
    let store = squash(&mdk_source("storage-sqlite/src/storage/messages.rs"));
    let probe = &store[store
        .find("fnhas_messages_in_states(")
        .expect("MDK's SQLite store no longer has its existence probe")..];
    let probe = &probe[..probe[1..].find("fn").map_or(probe.len(), |next| next + 1)];
    assert!(
        probe.contains(
            "SELECTEXISTS(SELECT1FROMcgka_messagesWHEREgroup_id=?1ANDepoch>=?2ANDstateIN({}))"
        ) && !probe.contains("ORDERBY"),
        "MDK's existence probe is no longer an unordered EXISTS: re-read `proposal_stands`",
    );
}

/// What Haven reads of MDK's one-attempt reservation is still what MDK means
/// by it. MDK has no accessor for the reservation, so Haven reads the stored
/// convergence pass and the queue through the second handle and applies
/// MDK's own two conditions by hand (`reservation_held`, `changes_group`):
/// a bump that changes either leaves a narrow plane retiring a queued change
/// the engine no longer holds its circle for, or keeping one it does.
#[test]
fn mdks_reservation_is_still_the_two_conditions_haven_reads() {
    let squash = |text: &str| text.split_whitespace().collect::<String>();
    // The kinds of change a pass is reserved for.
    let kinds = |source: &str, function: &str| -> Vec<String> {
        squash(fn_body(source, function).unwrap_or_else(|| panic!("`{function}` is gone")))
            .split("SendIntent::")
            .skip(1)
            .map(|rest| rest.split('{').next().unwrap_or_default().to_owned())
            .collect()
    };
    let mdk = mdk_source("cgka-engine/src/message_processor/mod.rs");
    let haven = production_source(&repo_root().join("haven-core/src/nostr/mls/manager.rs"));
    let reserved = kinds(&mdk, "fn is_admin_group_state_intent(");
    assert_eq!(
        reserved,
        [
            "Invite",
            "RemoveMembers",
            "UpdateAppComponents",
            "UpdateGroupData",
            "EnableDisbanding",
            "Disband",
        ],
        "MDK reserves a circle's next pass for other kinds of change than it did",
    );
    assert_eq!(
        kinds(&haven, "const fn changes_group("),
        reserved,
        "Haven's list of the changes that hold a pass is no longer MDK's",
    );

    // Where the reservation is held: a completed pass whose fairness slot is
    // still available, while such a change is queued — and nowhere a third
    // condition.
    let pass = squash(
        fn_body(
            &mdk_source("cgka-engine/src/distributed_convergence.rs"),
            "fn load_or_open_convergence_pass(",
        )
        .expect("MDK opens a convergence pass in `load_or_open_convergence_pass`"),
    );
    assert!(
        pass.contains(
            "ifletSome(pass)=previous.as_ref()&&pass.phase==ConvergencePassPhase::Completed\
             &&pass.fairness_slot_available{"
        ) && pass.contains(
            ".any(|record|crate::message_processor::is_admin_group_state_intent(&record.intent))\
             {returnOk((Some(pass.clone()),false));}"
        ),
        "MDK no longer holds its reservation on a completed pass with its slot left while a \
         change of the group is queued: re-read `reservation_held` and `reservation_freezes`",
    );
    // And the drain's own reading of it (`AdminReservation`, which orders a
    // queued change of the group ahead of maintenance): the same two
    // conditions, and only a change of the group passes it.
    let load =
        squash(fn_body(&mdk, "    fn load<S: StorageProvider>(").expect("AdminReservation::load"));
    let permits =
        squash(fn_body(&mdk, "    fn permits(&self, intent: &SendIntent)").expect("permits"));
    assert!(
        mdk.matches("struct AdminReservation {").count() == 1
            && load.contains(
                "pass.phase==cgka_traits::ConvergencePassPhase::Completed\
                 &&pass.fairness_slot_available"
            )
            && permits.contains("!self.available||is_admin_group_state_intent(intent)")
            && squash(&mdk)
                .matches("AdminReservation::load(self,group_id)")
                .count()
                == 1,
        "MDK's drain reads its reservation on other conditions, or in more places, than the \
         two Haven applies: re-read `reservation_held`",
    );
    assert!(
        squash(fn_body(&haven, "fn reservation_held<E>(").expect("fn reservation_held")).contains(
            "Ok(Some(pass))ifpass.phase==cgka_traits::ConvergencePassPhase::Completed\
                 &&pass.fairness_slot_available"
        ),
        "Haven reads the reservation on other conditions than MDK holds it on",
    );
}

/// The figures Security Rule 13's fanout rules are written in. Changing one
/// changes what a relay is sent and how long a commit can hold a circle: it
/// is a decision, made here in the open, never a tweak beside the code.
#[test]
fn rule13_fanout_constants_are_pinned() {
    use haven_core::relay::fanout::{
        AMBIGUOUS_RETRY_BASE_MS, BUSY_RETRY_MS, CONFIRM_ATTEMPTS, FANOUT_BOUND_MS, GATE_WAIT_SECS,
        MDK_ATTEMPTS_PER_CALL, MDK_CALL_CEILING_SECS, RATE_LIMITED_JITTER_DIVISOR,
        RATE_LIMITED_RETRY_BASE_MS, RESTAGE_BASE_MS, RESUME_BUDGET_MS, RETRY_MAX_MS, ROW_BUDGET_MS,
        UNAVAILABLE_PROMPT_CALLS, UNAVAILABLE_RETRY_DELAY_MS,
    };
    // An applied commit's record ends, and a pending commit no relay was
    // reached for is undone, one day after staging.
    assert_eq!(FANOUT_BOUND_MS, 24 * 60 * 60 * 1_000);
    // A busy store is asked to confirm at most four times in one drive.
    assert_eq!(CONFIRM_ATTEMPTS, 4);
    // A relay whose answer proved nothing: 30 s, doubling, an hour at most.
    assert_eq!(AMBIGUOUS_RETRY_BASE_MS, 30_000);
    assert_eq!(RETRY_MAX_MS, 3_600_000);
    // A relay that could not be reached: 5 s three times, then as above.
    assert_eq!(UNAVAILABLE_RETRY_DELAY_MS, 5_000);
    assert_eq!(UNAVAILABLE_PROMPT_CALLS, 3);
    // A relay that said "not now": a minute, doubling, stretched by a quarter.
    assert_eq!(RATE_LIMITED_RETRY_BASE_MS, 60_000);
    assert_eq!(RATE_LIMITED_JITTER_DIVISOR, 4);
    // What one call of MDK's relay client is: three sends, twenty seconds.
    assert_eq!(MDK_ATTEMPTS_PER_CALL, 3);
    assert_eq!(MDK_CALL_CEILING_SECS, 20);
    // A call waits five seconds for a relay another send holds, and is asked
    // again five seconds after it gave up.
    assert_eq!(GATE_WAIT_SECS, 5);
    assert_eq!(BUSY_RETRY_MS, 5_000);
    // A row is begun only while a wake has its longest possible run left:
    // the wait for the relay, MDK's ceiling, and six one-second deadlines.
    assert_eq!(ROW_BUDGET_MS, 31_000);
    assert_eq!(RESUME_BUDGET_MS, 62_000);
    // A refused eviction is staged again after a minute, doubling.
    assert_eq!(RESTAGE_BASE_MS, 60_000);

    // `min(2, n)` distinct relays: the count frozen into a commit's record,
    // for one, two and three relays and for two spellings of one.
    let manager = production_source(&repo_root().join("haven-core/src/nostr/mls/manager.rs"));
    let required = fn_body(&manager, "fn required_acks(").expect("fn required_acks exists");
    assert!(
        required.contains(".min(2)"),
        "a commit's record no longer freezes min(2, distinct relays) as the \
         acknowledgements its fanout is retried for (owner decision OD-2)",
    );
}

/// The five figures Haven copied from MDK's host by value are still MDK's.
/// A bump that moves one fails here, where the difference can be read and
/// decided, instead of leaving Haven pacing by a number nobody chose.
#[test]
fn mdk_fanout_pacing_constants_have_not_drifted() {
    use haven_core::relay::fanout::{
        AMBIGUOUS_RETRY_BASE_MS, CONFIRM_ATTEMPTS, FANOUT_BOUND_MS, RETRY_MAX_MS,
        UNAVAILABLE_RETRY_DELAY_MS,
    };
    let source = mdk_host_source();
    let product = |expression: &str| -> u64 {
        expression
            .split(" * ")
            .map(|factor| factor.replace('_', "").parse::<u64>().expect("a factor"))
            .product()
    };
    for (declaration, ours) in [
        (
            "const FROZEN_FANOUT_AMBIGUOUS_RETRY_BASE_MS: u64 = ",
            AMBIGUOUS_RETRY_BASE_MS,
        ),
        (
            "const FROZEN_FANOUT_AMBIGUOUS_RETRY_MAX_MS: u64 = ",
            RETRY_MAX_MS,
        ),
        (
            "const FROZEN_FANOUT_UNAVAILABLE_RETRY_DELAY_MS: u64 = ",
            UNAVAILABLE_RETRY_DELAY_MS,
        ),
        // In seconds, and MDK's bound on its Welcome records only: its host
        // retries a commit's fanout without end.
        (
            "const TRANSPORT_FANOUT_RETENTION_SECS: u64 = ",
            FANOUT_BOUND_MS / 1_000,
        ),
        (
            "const MAX_CONFIRM_ATTEMPTS: u32 = ",
            u64::from(CONFIRM_ATTEMPTS),
        ),
    ] {
        let value = source
            .split(declaration)
            .nth(1)
            .and_then(|rest| rest.split(';').next())
            .unwrap_or_else(|| panic!("MDK's host no longer declares `{declaration}…`"));
        assert_eq!(
            product(value),
            ours,
            "MDK's host changed a figure Haven copied by value: `{declaration}{value}`",
        );
    }
    // The rule the confirm retry copies: only a transient error, and one
    // fewer than the bound of them.
    assert!(
        source.contains("Err(e) if e.is_transient() && attempt + 1 < MAX_CONFIRM_ATTEMPTS =>"),
        "MDK's host no longer retries a fanout's confirm on a transient error alone",
    );
}
