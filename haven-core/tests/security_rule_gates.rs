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

    let pause = fn_body(&session, "pub async fn pause_subscriptions")
        .expect("session.rs must define pause_subscriptions");

    let resume =
        fn_body(&session, "async fn resume_burst").expect("session.rs must define resume_burst");
    for (name, body) in [("pause_subscriptions", &pause), ("resume_burst", &resume)] {
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
    }

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

    for (name, body) in [
        ("pause_subscriptions", "pub async fn pause_subscriptions"),
        ("resume_burst", "async fn resume_burst"),
    ] {
        let text =
            fn_body(&session, body).unwrap_or_else(|| panic!("session.rs must define {name}"));
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

/// OD4-c, structurally: the background/foreground split that keeps
/// removal-bearing auto-commits out of a burst cannot be edited away silently.
///
/// Three facts hold this up, and each is invisible when broken — a burst would
/// simply publish again, and no existing test would say so:
///
/// 1. the receive-side auto-commit resolution goes through the POLICY-taking
///    entry point, never the unconditional publisher;
/// 2. the policy comes from the session's typed `BurstKind`, set before any REQ
///    the open issues, so no event can be resolved under the previous open's
///    lifecycle;
/// 3. the redemption NEVER rolls a deferred eviction back. A rollback is a
///    permanent silent drop of the removal at the pinned MDK rev (the engine
///    drops its in-memory `SelfRemove` auto-commit schedule before staging,
///    `do_publish_failed` does not re-arm it, and a redelivered proposal
///    short-circuits to `Buffered`), so the only safe failure is to stay owed.
///
/// The behavioural proofs are in `od4c_removal_deferral_e2e`.
#[test]
fn od4c_a_background_burst_cannot_publish_a_removal_bearing_auto_commit() {
    let processor =
        production_source(&repo_root().join("haven-core/src/relay/live_sync/processor.rs"));
    let resolve = fn_body(&processor, "async fn resolve_publish_work")
        .expect("processor.rs must define resolve_publish_work");
    assert!(
        resolve.contains("resolve_receive_publish_work_with_policy"),
        "the receive path must resolve auto-commits through the POLICY-taking \
         entry point; without it a background burst publishes a removal-bearing \
         commit into a wake window the OS may end, and MDK's hydrate does not \
         recover one that is cut (OD4-c)"
    );
    assert!(
        !resolve.contains("resolve_receive_publish_work(&self.circle"),
        "the unconditional publisher must NOT be reachable from the receive \
         path: it is the pre-OD4-c behaviour and it is silent when restored"
    );
    assert!(
        resolve.contains("self.auto_commit_policy()"),
        "the policy must be READ from state, never assumed: one processor serves \
         both lifecycles over the same engine"
    );

    let session = production_source(&repo_root().join("haven-core/src/relay/live_sync/session.rs"));
    let resume =
        fn_body(&session, "async fn resume_burst").expect("session.rs must define resume_burst");
    let set = resume
        .find("set_background_burst")
        .expect("resume_burst must set the receive-side auto-commit lifecycle");
    assert!(
        resume[set..].starts_with("set_background_burst(matches!(kind, BurstKind::Background))"),
        "the lifecycle must be derived from the open's own typed BurstKind — the \
         same value the inbox fold reads — so the two cannot drift apart"
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
        !start.contains("redeem_removal_deferrals"),
        "`start` must not redeem a parked eviction commit: it cannot tell a \
         foreground launch from a background wake that cold-launched the process, \
         so redeeming here re-opens the publish-before-apply window in the \
         background. A FOREGROUND open is the only place that may publish one"
    );

    let manager = production_source(&repo_root().join("haven-core/src/circle/manager.rs"));
    let redeem = fn_body(&manager, "pub async fn redeem_removal_deferrals")
        .expect("manager.rs must define redeem_removal_deferrals");
    assert!(
        !redeem.contains("publish_failed"),
        "a deferred eviction must NEVER be rolled back. At MDK e391adc a rollback \
         drops the removal permanently and silently — the leaver stays in the \
         circle, still able to derive its keys — so an unacked publish stays owed \
         and is retried"
    );
    assert!(
        redeem.contains("self.confirm_published("),
        "precondition for the pin below: the body read here is the redemption \
         pass, which discharges by CONFIRMING"
    );
    assert!(
        !redeem.contains("self.clear_removal_deferral("),
        "and it must never clear by circle beside that confirm: the confirm's own \
         replay can record a SECOND-generation obligation under the same circle \
         (the map holds one entry per circle), so an ngid-scoped clear here would \
         delete it — leaving a staged, unpublished, no-longer-owed and \
         no-longer-reported eviction. The twin of the `note_epoch_changes` pin \
         below"
    );
}

/// The same guarantee, TREE-WIDE: no plane rolls a removal-bearing auto-commit
/// back, and every plane records the obligation before it opens the window.
///
/// The burst is one of four planes that can hold such a commit, and the three
/// others are what this gate exists for — the background catch-up sweep, the
/// foreground poll path, and the Android foreground service's publish cycle. Two
/// of them resolve the commit from DART, so the rule cannot live at a Rust call
/// site: it lives at the single rung all four go through
/// (`CircleManager::publish_failed`), and this pins that rung, the write-ahead
/// record that makes each plane's crash window visible, and the discharge that
/// keeps the record from crying wolf.
///
/// The behavioural proofs are in `od4c_removal_deferral_e2e` and
/// `selfremove_autopublish_e2e`.
#[test]
fn od4c_no_plane_can_roll_back_or_hide_a_removal_bearing_auto_commit() {
    let manager = production_source(&repo_root().join("haven-core/src/circle/manager.rs"));

    let fail = fn_body(&manager, "pub async fn publish_failed")
        .expect("manager.rs must define publish_failed");
    let guard = fail
        .find("keeps_its_removal_publish_owed")
        .expect("publish_failed must refuse to roll back an owed removal publish");
    let engine = fail
        .find("publish_failed(pending)")
        .expect("publish_failed must reach the engine rollback for every OTHER commit");
    assert!(
        guard < engine,
        "the owed-removal guard must be read BEFORE the engine rollback. At MDK \
         e391adc `do_publish_failed` drops a peer's `SelfRemove` eviction \
         permanently and silently — the schedule is cleared before staging, is \
         not re-armed, and a redelivered proposal short-circuits to Buffered — so \
         the leaver keeps deriving the circle's keys. This rung is where the four \
         planes (burst, catch-up sweep, foreground poll, foreground service) \
         converge, and two of them call it from Dart, so a per-call-site rule \
         cannot cover them"
    );

    let confirm = fn_body(&manager, "pub async fn confirm_published")
        .expect("manager.rs must define confirm_published");
    assert!(
        confirm.contains("discharge_owed_removal_publish"),
        "an APPLIED eviction must discharge its obligation. Every plane records \
         one before it publishes, so without this each peer-leave leaves a durable \
         row behind and the next foreground open reports a healthy circle \
         unrecoverable — a detector that cries wolf gets switched off"
    );

    let epoch_fold = fn_body(&manager, "fn note_epoch_changes")
        .expect("manager.rs must define note_epoch_changes");
    assert!(
        epoch_fold.contains("clear_orphaned_removal_deferral"),
        "the `EpochChanged` fold may clear only an ORPHANED obligation"
    );
    assert!(
        !epoch_fold.contains("self.clear_removal_deferral("),
        "and never a live one: an epoch move arriving while a park stands would \
         drop the only handle that can publish the staged commit, wedging the \
         circle while reporting nothing — a silent drop of the removal by another \
         route"
    );

    let auto = production_source(&repo_root().join("haven-core/src/relay/auto_commit.rs"));
    // The write-ahead rule lives at the policy-taking entry point, and the
    // unconditional wrapper must reach the ladder through it — otherwise a new
    // caller of the wrapper would get a publish with no record behind it.
    let wrapper = fn_body(&auto, "pub async fn resolve_receive_publish_work")
        .expect("auto_commit.rs must define resolve_receive_publish_work");
    assert!(
        wrapper.contains("resolve_receive_publish_work_with_policy"),
        "the unconditional entry point must delegate to the policy-taking one, \
         so the write-ahead record and the ladder's cap disposition cannot be \
         bypassed by calling it"
    );
    let resolve = fn_body(
        &auto,
        "pub async fn resolve_receive_publish_work_with_policy",
    )
    .expect("auto_commit.rs must define resolve_receive_publish_work_with_policy");
    let record = resolve
        .find("owe_removal_publish")
        .expect("the publishing planes must record the obligation");
    let publish = resolve
        .find("publish_then_resolve")
        .expect("the publishing planes must still publish");
    assert!(
        record < publish,
        "the record is WRITE-AHEAD or it is worthless: a wake window the OS ends \
         between SEND and OK leaves a staged removal-bearing commit MDK's hydrate \
         refuses to clear, and only a row written before the send survives to \
         report it"
    );
    // The ladder's cap. A cascade long enough to reach it costs O(k^3) to
    // stage (measured in `receive_ladder_e2e`: 116 s at nine leavers, past
    // fifteen minutes at seventeen), so what the cap DOES is pinned here
    // instead: it parks every commit it will not run, and it never rolls one
    // back. Both halves matter — a rollback is the permanent silent drop, and
    // an un-parked stop is the invisible wedge.
    let cap = resolve
        .find("RESOLVE_RUNAWAY_CAP")
        .expect("the ladder must have a runaway cap");
    let cap_arm = &resolve[cap..];
    let park = cap_arm
        .find("defer_removal_commit")
        .expect("the cap must PARK every commit it will not run");
    assert!(
        !cap_arm[..park].contains("publish_failed"),
        "the cap must not roll a commit back on its way to parking it: at MDK \
         e391adc that drops the removal permanently and silently"
    );

    let no_publisher = fn_body(&auto, "pub async fn park_or_rollback_receive_publish_work")
        .expect("auto_commit.rs must define park_or_rollback_receive_publish_work");
    assert!(
        no_publisher.contains("defer_removal_commit"),
        "a plane with no relay handle must PARK the eviction, not discard it"
    );

    assert_the_ffi_planes_record_before_the_handover(&manager);
    assert_nothing_reaches_past_the_fail_rung();
    assert_the_reanchor_sweep_reports_both_causes();

    // No background plane redeems. The foreground gate lives in session.rs and is
    // pinned above; this is the other half — a redemption reachable from the
    // catch-up sweep would re-open the publish-before-apply window inside exactly
    // the wake the deferral exists to avoid.
    let catchup = production_source(&repo_root().join("haven-core/src/relay/catchup.rs"));
    assert!(
        !catchup.contains("redeem_removal_deferrals"),
        "the catch-up sweep must not redeem an owed removal publish: it runs on \
         WorkManager / BGTask wakes and from a background isolate, and OD4-c \
         reserves the publish for a foreground open"
    );
}

/// The write-ahead ordering at the two surfacing sites that hand the commit to
/// DART. Past the hand-over this crate no longer decides when — or whether —
/// the publish happens, so a record written afterwards would never be written at
/// all for the crash this exists to catch.
fn assert_the_ffi_planes_record_before_the_handover(manager: &str) {
    for surfacing in [
        "async fn surface_auto_commit",
        "async fn collect_deferred_work",
    ] {
        let body = fn_body(manager, surfacing)
            .unwrap_or_else(|| panic!("manager.rs must define {surfacing}"));
        let record = body.find("owe_removal_publish").unwrap_or_else(|| {
            panic!("{surfacing} must record the obligation before it surfaces the commit")
        });
        let handover = body
            .find(".push(commit)")
            .unwrap_or_else(|| panic!("{surfacing} must surface the commit"));
        assert!(
            record < handover,
            "{surfacing} must record the obligation BEFORE the commit crosses \
             the FFI: the Dart plane's publish-before-apply window is the one \
             this crate cannot observe, and only a row written ahead of it \
             survives a process killed between SEND and OK"
        );
    }
}

/// The chokepoint is only a chokepoint while nothing reaches PAST it.
/// `CircleManager::session()` is `pub`, so a new plane could call the engine's
/// fail rung directly and skip the owed-removal guard in silence.
///
/// What is pinned is the GUARD, not a count: every production call that reaches
/// the engine's own `publish_failed` must sit in one of a reviewed set of
/// `CircleManager` functions, and each of those must consult
/// `keeps_its_removal_publish_owed` BEFORE it makes the call. A new call site
/// anywhere else, or one that skips the guard, discards a peer's eviction
/// permanently and silently and nothing else in the tree would notice.
///
/// Whitespace is squashed because the legitimate calls span several lines.
fn assert_nothing_reaches_past_the_fail_rung() {
    let mut sources = Vec::new();
    sources_under(&repo_root().join("haven-core/src"), "rs", &mut sources);
    sources_under(
        &repo_root().join("haven/rust_builder/src"),
        "rs",
        &mut sources,
    );
    let mut direct = Vec::new();
    for path in &sources {
        let squashed: String = production_source(path)
            .chars()
            .filter(|c| !c.is_whitespace())
            .collect();
        let hits = squashed.matches(".session.publish_failed(").count()
            + squashed.matches(".session().publish_failed(").count();
        for _ in 0..hits {
            direct.push(path.display().to_string());
        }
    }
    let manager_path = repo_root().join("haven-core/src/circle/manager.rs");
    assert!(
        direct
            .iter()
            .all(|path| path == &manager_path.display().to_string()),
        "only `CircleManager` may reach the engine's own `publish_failed`; found: {direct:?}"
    );

    // And `rollback_unfolded` must stay on the ENGINE's rung, never promoted to
    // `CircleManager::publish_failed`: `remove_members` reaches it while holding
    // `directory_lock` (non-reentrant) via `take_group_evolution` →
    // `surface_co_drained_auto_commits` → `surface_auto_commit`, and
    // `publish_failed` ends in a directory reconcile that takes the same lock.
    let unfolded: String = fn_body(
        &production_source(&manager_path),
        "async fn rollback_unfolded",
    )
    .expect("manager.rs must define rollback_unfolded")
    .chars()
    .filter(|c| !c.is_whitespace())
    .collect();
    assert!(
        !unfolded.contains("self.publish_failed("),
        "rollback_unfolded must not go through `CircleManager::publish_failed`: \
         the directory reconcile at the end of it takes a lock a caller already \
         holds, and the deadlock would look like a hung Remove Member"
    );

    // The reviewed set, and the guard each one must take first.
    let manager = production_source(&manager_path);
    let mut guarded_calls = 0usize;
    for signature in ["pub async fn publish_failed", "async fn rollback_unfolded"] {
        let body: String = fn_body(&manager, signature)
            .unwrap_or_else(|| panic!("manager.rs must define {signature}"))
            .chars()
            .filter(|c| !c.is_whitespace())
            .collect();
        let guard = body
            .find("keeps_its_removal_publish_owed(")
            .unwrap_or_else(|| panic!("{signature} must consult the owed-removal guard"));
        let call = body
            .find(".session.publish_failed(")
            .unwrap_or_else(|| panic!("{signature} must be the one making the call"));
        assert!(
            guard < call,
            "{signature} must take the owed-removal guard BEFORE it rolls back: a \
             removal-bearing commit discarded here is gone permanently and silently"
        );
        guarded_calls += body.matches(".session.publish_failed(").count();
    }
    assert_eq!(
        direct.len(),
        guarded_calls,
        "every production call to the engine's own `publish_failed` must live in \
         a guarded `CircleManager` function; {} found in the tree, {guarded_calls} \
         inside the reviewed set",
        direct.len()
    );
}

/// O3: a drained `GroupEvolution`'s welcomes are dropped — and never silently.
///
/// `CommitToPublish` carries no welcomes, so a queued Invite released by a
/// convergence drain hands back a commit whose invitees nobody will ever receive
/// a Welcome for. That is PRE-EXISTING (`collect_deferred_work` has the same
/// hole) and it is a named follow-up, not this change's business — but a
/// follow-up nobody can see is a bug that never gets fixed, so the fold must say
/// so every time it happens.
///
/// Pinned at source because the arm is reachable only through the engine's
/// jitter race: it needs a queued outbound Invite AND a `SelfRemove`
/// scheduled-but-not-yet-due at the instant the fold re-advances convergence
/// (`message_processor/mod.rs:216-221` returns early whenever the eviction IS
/// due). `manager.rs`'s own
/// `a_drained_group_evolution_is_surfaced_with_its_welcomes_noted` covers the
/// behaviour; this covers the trace.
#[test]
fn drained_group_evolution_welcomes_are_never_dropped_silently() {
    let manager = production_source(&repo_root().join("haven-core/src/circle/manager.rs"));
    let dispose = fn_body(&manager, "async fn dispose_publish_work")
        .expect("manager.rs must define dispose_publish_work");
    let guard = dispose
        .find("welcomes.is_empty()")
        .expect("the drained-evolution arm must test its welcomes");
    let warn = dispose[guard..]
        .find("log::warn!")
        .expect("and say so when there are any");
    let surfaced = dispose[guard..]
        .find("auto_commits.push")
        .expect("before it surfaces the commit without them");
    assert!(
        warn < surfaced,
        "the note belongs with the drop it describes, not after the hand-over"
    );
}

/// (i)'s half: the terminal verdict reaches the consumer for BOTH causes.
///
/// The engine announces its own verdict exactly once per session — after
/// `mark_unrecoverable`, every later convergence run short-circuits before the
/// arm that pushes the event — while the consumer acts only on a SECOND
/// observation, so it does not tell a user to rebuild a circle a peer already
/// healed. A sweep that reported only orphaned parks would therefore leave every
/// engine-declared group unreported forever.
fn assert_the_reanchor_sweep_reports_both_causes() {
    let processor =
        production_source(&repo_root().join("haven-core/src/relay/live_sync/processor.rs"));
    let report = fn_body(&processor, "pub fn report_unrecoverable_circles")
        .expect("processor.rs must define report_unrecoverable_circles");
    for cause in ["orphaned_removal_deferrals", "unrecoverable_circles"] {
        assert!(
            report.contains(cause),
            "the re-anchor sweep must report `{cause}`: a terminal verdict the \
             consumer needs twice, emitted once, is a wedged circle the user is \
             never told about"
        );
    }
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
/// nothing: the inbox stream re-requests a multi-day window on every REQ (49 h
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

/// `path`'s production source: everything before the in-file test module, with
/// comment lines removed so a gate matches CODE and never the prose describing
/// it.
///
/// The cut is at the test MODULE, not at the first `#[cfg(test)]` item: several
/// files gate a test-only static or clock override far above their test module
/// (`api.rs:1048`), and cutting there would hide most of the file from the gate
/// — silently, which is the failure mode a gate must not have.
fn production_source(path: &std::path::Path) -> String {
    let src =
        std::fs::read_to_string(path).unwrap_or_else(|e| panic!("read {}: {e}", path.display()));
    let mut out = String::with_capacity(src.len());
    let mut previous_gated = false;
    for line in src.lines() {
        let trimmed = line.trim_start();
        if previous_gated && trimmed.starts_with("mod tests") {
            break;
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
    out
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

/// (a) + (b): the two `AutoCommitPublisher` impls, which are where a staged
/// commit meets a transport.
fn assert_commit_publishers_keep_the_ladder(root: &std::path::Path) {
    let auto_commit = production_source(&root.join("haven-core/src/relay/auto_commit.rs"));

    let via_manager = block_after(&auto_commit, "impl AutoCommitPublisher for RelayManager {");
    assert!(
        via_manager.contains(concat!("publish", "_event(")),
        "the catch-up sweep publishes commits through the 3-attempt ladder; \
         found: {via_manager}",
    );
    assert!(
        !via_manager.contains(concat!("publish_location", "_event")),
        "a commit published on the location path would be re-sent never, and \
         confirmed or rolled back on one bounded attempt: {via_manager}",
    );

    let via_client = block_after(
        &auto_commit,
        "impl AutoCommitPublisher for nostr_sdk::Client {",
    );
    assert!(
        via_client.contains("send_event_to("),
        "the engine publishes over its own connected sockets: {via_client}",
    );
    assert!(
        via_client.contains("!output.success.is_empty()"),
        "\"acked\" means at least one relay returned OK, never merely that the \
         event was sent (Rule 13): {via_client}",
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

    let location_publish = concat!("publish_location", "_event");
    let pending_words = [
        "PendingStateRef",
        concat!("confirm", "_published"),
        concat!("publish", "_failed"),
    ];
    let mut files_reached: Vec<String> = Vec::new();
    for path in &sources {
        let src = production_source(path);
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

    assert!(
        files_reached
            .iter()
            .any(|f| f.ends_with("relay/manager.rs")),
        "the location publish itself has to be in scope or this gate reads \
         nothing: {files_reached:?}",
    );
    assert!(
        files_reached
            .iter()
            .any(|f| f.ends_with("rust_builder/src/api.rs")),
        "the FFI wrapper has to be in scope: it is the one place where the \
         location path and the staged-commit path share a file: {files_reached:?}",
    );
}

/// (c), Dart half: FILE-level, which is stricter than function-level — a file
/// that resolves a staged commit may not publish a location at all.
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
/// Listing only the FFI pair left the interface pair — the one the location
/// planes actually use — free to share a file with the one-shot publish, so the
/// gate's claim was false where it mattered most.
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

    let mut publishers: Vec<String> = Vec::new();
    for path in &sources {
        let src = std::fs::read_to_string(path).expect("read dart source");
        if !src.contains(concat!("publishLocation", "Event(")) {
            continue;
        }
        publishers.push(path.display().to_string().replace('\\', "/"));
        for word in [
            concat!("confirm", "Published("),
            concat!("publish", "Failed("),
            concat!("confirm", "PendingCommit("),
            concat!("fail", "PendingCommit("),
        ] {
            assert!(
                !src.contains(word),
                "{} publishes a location AND resolves a staged commit (`{word}`); \
                 keep the two planes in separate files so no caller carrying a \
                 pending ref can reach the one-shot publish",
                path.display(),
            );
        }
    }

    // Anti-vacuity, on the files the loop actually READ. `sources.len() > 50`
    // only proves the directory scan found Dart; it says nothing about the
    // `publishLocationEvent(` filter, so a rename of that method would leave
    // every file `continue`d and this gate passing while checking nothing.
    // Both known publishers are named: one is the foreground plane and one is
    // the foreground service, and each has its own reason to grow a
    // confirm/rollback next to its publish.
    for expected in [
        "services/location_sharing_service.dart",
        "services/background_location_task.dart",
    ] {
        assert!(
            publishers.iter().any(|f| f.ends_with(expected)),
            "{expected} no longer reaches the one-shot location publish, so this \
             gate read nothing there. Either the publish moved (point this at \
             its new home) or the method was renamed and the whole scan is \
             vacuous: {publishers:?}",
        );
    }
}

/// A location publish takes the one-shot fan-out; a COMMIT keeps the ladder.
///
/// The two paths differ in what a miss costs. A location that no relay acked is
/// superseded by the next tick within 168 s, so one bounded attempt is the
/// whole budget. A commit that is neither confirmed nor rolled back leaves the
/// group at an epoch its peers never received — Rule 13 — so it keeps the
/// 3-attempt ladder AND the confirm/rollback decision on a real OK-ack.
///
/// Nothing in the type system keeps them apart: both take an `&Event` and a
/// relay list. So the three predicates that DO keep them apart are asserted on
/// the source, where a reviewer would otherwise have to notice them.
#[test]
fn rule13_commits_keep_the_retry_ladder_and_locations_do_not() {
    let root = repo_root();
    assert_commit_publishers_keep_the_ladder(&root);
    assert_no_rust_function_publishes_a_location_and_a_commit(&root);
    assert_no_dart_file_publishes_a_location_and_a_commit(&root);
}
