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

/// Encrypts an inner kind-9 location `content` and returns the publishable 445.
async fn send_445(sender: &SessionManager, gid: &GroupId, content: &str) -> Event {
    let effects = sender
        .send_location(gid, content.to_string())
        .await
        .expect("send location");
    let msg = effects
        .publish
        .iter()
        .find_map(|w| match w {
            PublishWork::ApplicationMessage { msg } => Some(msg.clone()),
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
        // Every event here is freshly built, so its NIP-40 expiration is far in
        // the future: a pre-auth rejection would make the gate below pass or
        // fail for a reason that has nothing to do with retention.
        .expect("a freshly-built 445 must reach the engine, not Haven's pre-auth screen");
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
        let ingest = g
            .bob
            .process_event(&commit_event)
            .await
            .expect("bob ingests commit")
            .ingested()
            // Commits carry no `expiration` tag (group history must outlive any
            // TTL), so the receiver-side screen cannot fire here.
            .expect("a commit must reach the engine, not Haven's pre-auth screen");
        for gid in &ingest.effects.pending_convergence {
            g.bob
                .advance_convergence(gid)
                .await
                .expect("bob converges the commit");
        }
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
        btx.send(RelayPoolNotification::Event {
            relay_url: RelayUrl::parse("wss://relay.example").expect("relay url"),
            subscription_id: SubscriptionId::new("s_group_0"),
            event: Box::new(event.clone()),
        })
        .expect("the receiver built above holds a live subscription");
    }
    let handle = tokio::spawn(run_receiver(
        brx,
        tx,
        processor,
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
/// nothing: the inbox stream re-requests a 7-day window on every REQ.
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
