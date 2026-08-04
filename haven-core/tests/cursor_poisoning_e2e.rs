//! Sync-cursor integrity against UNAUTHENTICATED input, in BOTH receive planes.
//!
//! # The defect these gates pin
//!
//! A circle's `nostr_group_id` is the `#h` tag of every one of its `kind:445`s,
//! so it is public to any relay observer. Anyone who has seen one can re-wrap
//! that ciphertext into a fresh event, signed by a throwaway key, carrying a
//! `created_at` of their choosing.
//!
//! Both halves of that attack used to poison the victim's PERSISTED per-circle
//! cursor, because both receive planes derived the cursor from the inbound
//! event's outer `created_at`:
//!
//! * WITH a past NIP-40 `expiration`, the event was dropped by Haven's own
//!   receiver-side screen — which runs before the signature, the ephemeral
//!   author or the ciphertext are looked at by anything — and that drop was
//!   reported as a synthetic `Stale`, which both cursor gates read as "advance
//!   past it".
//! * WITHOUT the expiration tag, the event reached the engine, the outer AEAD
//!   opened (same ciphertext, same exporter secret) and the genuine inner MLS
//!   message authenticated, so the engine returned a clean verdict — and the
//!   cursor advanced to the attacker's timestamp anyway. **No receive-side check
//!   binds the outer envelope's `created_at` to the inner message the engine
//!   authenticates**, for any outcome.
//!
//! Either way `since_for_stream` then derived every subsequent REQ floor from
//! the poisoned cursor, so every legitimate event below it fell outside every
//! future request — permanently, and across restarts, for the price of one
//! event. A stranded location merely ages out; a stranded COMMIT breaks the
//! epoch chain.
//!
//! # What replaced it, and what these gates therefore assert
//!
//! Neither plane derives an advance from an event any more. Each anchors on a
//! LOCAL clock reading taken when its observation window opened — the catch-up
//! fetch's open time, the live subscription's REQ time — and only ever redeems
//! that anchor once the window is known complete (`EOSE` in the live plane, a
//! non-truncated fetch from a reachable relay in the catch-up plane). Event
//! timestamps survive in one direction only: an event that could not be APPLIED
//! holds the anchor at or below itself.
//!
//! So every gate below comes in a matched pair:
//!
//! * a forgery — expired or not — moves NO cursor, whatever the engine made of
//!   it; and
//! * the plane still advances on its own trusted signal, so the first half is
//!   the anchor refusing to take a remote number and not this change having
//!   quietly broken cursor advance altogether.
//!
//! # Why the catch-up plane's expired case is NOT end-to-end here
//!
//! `MockRelay` is backed by `nostr-database`, whose `DatabaseHelper` rejects an
//! expired event on save and filters expired events out of every query
//! (`helper.rs:193,216`) — i.e. it is NIP-40-conformant, so it will not serve the
//! very input that screen exists to defend against. (That is the screen's own
//! premise: only a malicious or non-conformant relay replays past a TTL.) The
//! catch-up plane is therefore covered where it can be driven honestly: its
//! `ingest_one` classification and its cursor arithmetic are unit-tested in
//! `src/relay/catchup.rs`, and the end-to-end sweep gates below cover everything
//! a conformant relay CAN deliver — including the un-expired re-wrap, which is
//! the more dangerous half.

use std::sync::Arc;
use std::time::Duration;

use haven_core::circle::{CircleConfig, CircleManager, MemberKeyPackage};
use haven_core::location::LocationMessage;
use haven_core::nostr::mls::types::GroupId;
use haven_core::relay::catchup::run_catchup_all_circles;
use haven_core::relay::live_sync::{
    group_cursor_stream, EngineProcessor, EventBus, GroupProcessOutcome,
};
use haven_core::relay::maintenance::build_kp_maintenance_events;
use haven_core::relay::{allow_ws_loopback_for_test, RelayManager};
use nostr::{Event, EventBuilder, Keys, Tag, TagStandard, Timestamp};
use nostr_relay_builder::MockRelay;
use tempfile::TempDir;

// ============================================================================
// Fixture
// ============================================================================

/// Alice (admin) + Bob as real co-members, each with their own MLS store.
struct TwoMemberCircle {
    alice: Arc<CircleManager>,
    alice_keys: Keys,
    bob: Arc<CircleManager>,
    bob_keys: Keys,
    mls_group_id: GroupId,
    nostr_group_id: [u8; 32],
    _dirs: Vec<TempDir>,
}

impl TwoMemberCircle {
    /// The circle's PUBLIC routing id — the `#h` of every one of its kind-445s,
    /// and the key both planes anchor cursors by.
    fn group_hex(&self) -> String {
        hex::encode(self.nostr_group_id)
    }

    fn cursor_stream(&self) -> String {
        group_cursor_stream(&self.group_hex())
    }

    fn alice_cursor(&self) -> Option<i64> {
        self.alice
            .read_sync_cursor(&self.cursor_stream())
            .expect("cursor read")
    }

    /// Plants a known cursor value so a later read distinguishes "held" from
    /// "never written" — a `None`-vs-`None` assertion would pass even if the
    /// advance had been deleted outright.
    fn seed_alice_cursor(&self, ms: i64) {
        self.alice
            .advance_sync_cursor(&self.cursor_stream(), ms)
            .expect("seed cursor");
        assert_eq!(
            self.alice_cursor(),
            Some(ms),
            "precondition: the seed must be readable back"
        );
    }

    /// A genuine, MLS-authenticated `kind:445` location from Bob — the event an
    /// attacker gets to OBSERVE on the relay.
    async fn bob_location(&self, lat: f64, lon: f64) -> Event {
        self.bob
            .encrypt_location(
                &self.mls_group_id,
                &self.bob_keys.public_key(),
                &LocationMessage::new(lat, lon),
                300,
            )
            .await
            .expect("bob encrypts a location")
            .0
    }
}

async fn mint_member(
    inbox_relays: &[String],
) -> (Arc<CircleManager>, Keys, MemberKeyPackage, TempDir) {
    let dir = TempDir::new().unwrap();
    let keys = Keys::generate();
    let mgr = CircleManager::new_unencrypted(dir.path(), &keys).unwrap();
    let kp_event = build_kp_maintenance_events(
        mgr.session(),
        &keys,
        &["wss://kp.example.com".to_string()],
        None,
    )
    .await
    .expect("member key package")
    .event;
    let member = MemberKeyPackage {
        key_package_event: kp_event,
        inbox_relays: inbox_relays.to_vec(),
        nip65_relays: vec![],
    };
    (Arc::new(mgr), keys, member, dir)
}

async fn build_two_member_circle(group_relays: Vec<String>) -> TwoMemberCircle {
    let (bob, bob_keys, bob_member, bob_dir) =
        mint_member(&["wss://member-inbox.example.com".to_string()]).await;

    let alice_dir = TempDir::new().unwrap();
    let alice_keys = Keys::generate();
    let alice = Arc::new(CircleManager::new_unencrypted(alice_dir.path(), &alice_keys).unwrap());
    let config = CircleConfig::new("Cursor Integrity Circle").with_relays(group_relays.clone());
    let result = alice
        .create_circle(&alice_keys, vec![bob_member], &config, &group_relays)
        .await
        .expect("create circle");
    let mls_group_id = result.circle.mls_group_id.clone();
    let nostr_group_id = result.circle.nostr_group_id;
    alice
        .confirm_published(result.pending)
        .await
        .expect("alice confirms creation");

    let welcome = result
        .welcome_events
        .iter()
        .find(|w| w.recipient_pubkey == bob_keys.public_key().to_hex())
        .expect("welcome for bob");
    bob.process_gift_wrapped_invitation(&bob_keys, &welcome.event)
        .await
        .expect("process welcome");
    bob.accept_invitation(&welcome.event.id)
        .await
        .expect("accept");

    TwoMemberCircle {
        alice,
        alice_keys,
        bob,
        bob_keys,
        mls_group_id,
        nostr_group_id,
        _dirs: vec![alice_dir, bob_dir],
    }
}

// ============================================================================
// The forgery
// ============================================================================

/// Re-wraps an OBSERVED genuine `kind:445` under a throwaway key with an
/// attacker-chosen `created_at`.
///
/// This is the real attack shape, not a synthetic one: the outer ciphertext is
/// copied verbatim off the relay, the `#h` routing tag is the circle's public
/// `nostr_group_id`, and the signing key is a fresh key belonging to nobody. The
/// attacker is not a member and holds no MLS secret.
///
/// `expired` toggles the single tag that decides which side of the
/// authentication boundary the event is judged on, and nothing else.
fn rewrap(observed: &Event, created_at_secs: u64, expired: bool) -> Event {
    let mut tags: Vec<Tag> = observed
        .tags
        .iter()
        .filter(|t| !matches!(t.as_standardized(), Some(TagStandard::Expiration(_))))
        .cloned()
        .collect();
    if expired {
        // An hour in the past: far beyond any plausible clock-skew grace, so
        // this test does not encode the exact grace constant.
        tags.push(Tag::expiration(Timestamp::from(
            Timestamp::now().as_secs() - 3600,
        )));
    }
    EventBuilder::new(observed.kind, observed.content.clone())
        .tags(tags)
        .custom_created_at(Timestamp::from(created_at_secs))
        .sign_with_keys(&Keys::generate())
        .expect("re-sign the observed ciphertext")
}

fn now_secs() -> i64 {
    i64::try_from(Timestamp::now().as_secs()).unwrap()
}

fn secs_of(event: &Event) -> i64 {
    i64::try_from(event.created_at.as_secs()).unwrap()
}

// ============================================================================
// Live-sync plane (EngineProcessor)
// ============================================================================

/// HEADLINE: a forged 445 whose `expiration` has passed is dropped before any
/// authentication and moves the persisted cursor NOWHERE.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn livesync_a_forged_expired_445_does_not_move_the_cursor() {
    let fx = build_two_member_circle(vec!["wss://group.example.com".to_string()]).await;
    let processor = EngineProcessor::new(Arc::clone(&fx.alice), EventBus::new());
    // A live REQ generation, so this circle CAN advance — otherwise every
    // assertion below would hold vacuously.
    processor.note_subscription_opened(&fx.group_hex(), now_secs());

    let floor = (now_secs() - 7200) * 1000;
    fx.seed_alice_cursor(floor);

    let observed = fx.bob_location(52.370_216, 4.895_168).await;
    // The attacker dates the forgery at "now": every genuine event that arrived
    // while this device was offline sits BELOW it, and would be buried.
    let forged = rewrap(&observed, Timestamp::now().as_secs(), true);

    let outcome = processor
        .process_group_event(&forged, &fx.nostr_group_id)
        .await;

    assert_eq!(
        outcome,
        GroupProcessOutcome::RejectedBeforeAuth,
        "the forgery must be reported as a PRE-AUTHENTICATION rejection, never as \
         an engine outcome"
    );
    assert_eq!(
        fx.alice_cursor(),
        Some(floor),
        "an unauthenticated event must not move the cursor one millisecond"
    );
}

/// THE OTHER HALF, and the one that survived the first fix: the byte-identical
/// re-wrap MINUS the `expiration` tag reaches the engine, opens under the real
/// exporter secret, authenticates as a genuine inner MLS message — and must
/// STILL move no cursor.
///
/// This is the attack that made the per-event advance untenable. The engine's
/// verdict is honest and says nothing at all about the outer `created_at` the
/// attacker chose; only the subscription's own EOSE anchor may move the cursor.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn livesync_the_same_forgery_without_the_expiration_tag_moves_no_cursor() {
    let fx = build_two_member_circle(vec!["wss://group.example.com".to_string()]).await;
    let processor = EngineProcessor::new(Arc::clone(&fx.alice), EventBus::new());
    processor.note_subscription_opened(&fx.group_hex(), now_secs());

    let floor = (now_secs() - 7200) * 1000;
    fx.seed_alice_cursor(floor);

    let observed = fx.bob_location(52.370_216, 4.895_168).await;
    // Dated at "now", far above the victim's floor: exactly the value that used
    // to bury every genuine event that arrived while the device was offline.
    let unexpired = rewrap(&observed, Timestamp::now().as_secs(), false);

    let outcome = processor
        .process_group_event(&unexpired, &fx.nostr_group_id)
        .await;

    assert!(
        matches!(
            outcome,
            GroupProcessOutcome::Applied | GroupProcessOutcome::Stale
        ),
        "precondition: this forgery really does reach the engine and get a clean \
         verdict ({outcome:?}) — that is what makes the cursor assertion below \
         the interesting one",
    );
    assert_eq!(
        fx.alice_cursor(),
        Some(floor),
        "an engine verdict is not evidence about the OUTER created_at: nothing \
         binds the two, so no delivered event may advance the cursor",
    );
}

/// The OTHER direction a forgery could attack: a pre-authentication rejection
/// must not HOLD the cursor back either.
///
/// Hold-backs exist for events that were delivered but not applied, and they are
/// deliberately allowed to take a remote `created_at` — lowering the advance is
/// safe. But a screened event is not an un-applied message: there is nothing to
/// come back for. If it held, one forged 445 dated far in the past would pin the
/// circle's cursor for the whole subscription generation — the same denial the
/// advance-side fix exists to prevent, bought from the other end.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn livesync_a_forged_expired_445_cannot_hold_the_cursor_back_either() {
    let fx = build_two_member_circle(vec!["wss://group.example.com".to_string()]).await;
    let processor = EngineProcessor::new(Arc::clone(&fx.alice), EventBus::new());

    let floor = (now_secs() - 7200) * 1000;
    fx.seed_alice_cursor(floor);
    let opened_at = now_secs();
    processor.note_subscription_opened(&fx.group_hex(), opened_at);

    let observed = fx.bob_location(1.0, 2.0).await;
    // Expired AND dated well below the anchor, so a hold-back would be visible.
    let forged = rewrap(&observed, u64::try_from(now_secs() - 5400).unwrap(), true);
    assert_eq!(
        processor
            .process_group_event(&forged, &fx.nostr_group_id)
            .await,
        GroupProcessOutcome::RejectedBeforeAuth,
        "precondition: the screen really fired"
    );

    assert!(processor.note_end_of_stored_events(&fx.group_hex()));
    assert_eq!(
        fx.alice_cursor(),
        Some(opened_at * 1000),
        "the screened event must contribute nothing in EITHER direction — the \
         generation still redeems its full anchor",
    );
}

/// The anti-vacuity control for both gates above: the plane DOES advance, on the
/// signal it actually trusts — the relay's end-of-stored-events for the open
/// REQ, redeemed against the LOCAL instant that REQ was issued.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn livesync_eose_advances_the_cursor_to_the_req_open_time() {
    let fx = build_two_member_circle(vec!["wss://group.example.com".to_string()]).await;
    let processor = EngineProcessor::new(Arc::clone(&fx.alice), EventBus::new());

    let floor = (now_secs() - 7200) * 1000;
    fx.seed_alice_cursor(floor);

    let opened_at = now_secs();
    processor.note_subscription_opened(&fx.group_hex(), opened_at);
    assert!(
        processor.note_end_of_stored_events(&fx.group_hex()),
        "EOSE on an open generation must be redeemed"
    );

    assert_eq!(
        fx.alice_cursor(),
        Some(opened_at * 1000),
        "the advance is the REQ's own open time — a local clock reading no relay \
         or event author can influence",
    );
}

/// A genuine, MLS-authenticated peer location is applied — and still does not
/// move the cursor by itself. The advance is the EOSE anchor's alone.
///
/// This is the behaviour change that closes the hole: "the engine applied it" is
/// a statement about the INNER message, and the cursor is a statement about the
/// OUTER timeline. They were conflated.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn livesync_a_genuine_peer_location_is_applied_but_does_not_move_the_cursor() {
    let fx = build_two_member_circle(vec!["wss://group.example.com".to_string()]).await;
    let processor = EngineProcessor::new(Arc::clone(&fx.alice), EventBus::new());

    let floor = (now_secs() - 7200) * 1000;
    fx.seed_alice_cursor(floor);
    let opened_at = now_secs();
    processor.note_subscription_opened(&fx.group_hex(), opened_at);

    let loc_event = fx.bob_location(52.370_216, 4.895_168).await;
    assert_eq!(
        processor
            .process_group_event(&loc_event, &fx.nostr_group_id)
            .await,
        GroupProcessOutcome::Applied,
        "precondition: the engine really applied it"
    );
    assert_eq!(
        fx.alice_cursor(),
        Some(floor),
        "even a genuine application message moves no cursor on its own"
    );

    // ...and the generation's own EOSE still advances normally afterwards, so
    // this is a redirection of the signal, not its removal.
    assert!(processor.note_end_of_stored_events(&fx.group_hex()));
    assert_eq!(fx.alice_cursor(), Some(opened_at * 1000));
}

/// A genuine engine `Buffered` HOLDS the generation's advance at itself, so the
/// un-applied message is re-requested.
///
/// Produced the way the engine actually produces one — Alice stages a commit and
/// does not confirm it, so her group sits in the publish-before-apply transition
/// and inbound traffic is buffered rather than applied.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn livesync_a_buffered_message_holds_the_cursor_below_itself() {
    let fx = build_two_member_circle(vec!["wss://group.example.com".to_string()]).await;
    let processor = EngineProcessor::new(Arc::clone(&fx.alice), EventBus::new());

    let floor = (now_secs() - 7200) * 1000;
    fx.seed_alice_cursor(floor);
    let opened_at = now_secs();
    processor.note_subscription_opened(&fx.group_hex(), opened_at);

    // Stage a commit and deliberately never confirm it (Rule 13: no relay ack).
    let _staged = fx
        .alice
        .update_circle_relays(&fx.mls_group_id, &["wss://group2.example.com".to_string()])
        .await
        .expect("alice stages a routing commit");

    // The buffered event is dated an HOUR below the REQ open time (only the
    // outer envelope is re-wrapped; the ciphertext, and so the engine's verdict,
    // is untouched). Without that separation the hold-back and the raw anchor
    // would land in the same second and the assertion below would hold whether
    // or not the hold-back existed at all.
    let observed = fx.bob_location(48.85, 2.35).await;
    let buffered_secs = now_secs() - 3600;
    let loc_event = rewrap(&observed, u64::try_from(buffered_secs).unwrap(), false);
    let outcome = processor
        .process_group_event(&loc_event, &fx.nostr_group_id)
        .await;

    assert_eq!(
        outcome,
        GroupProcessOutcome::Buffered,
        "precondition: this must really be the engine buffering — otherwise the \
         cursor assertion below proves nothing"
    );
    assert_eq!(
        fx.alice_cursor(),
        Some(floor),
        "a buffered message must not advance the cursor on delivery"
    );

    // The generation's EOSE is now capped at the buffered event, never at the
    // REQ open time, so the next REQ comes back for it.
    assert!(processor.note_end_of_stored_events(&fx.group_hex()));
    assert_eq!(
        fx.alice_cursor(),
        Some(buffered_secs * 1000),
        "the un-applied event must cap the advance at itself, not let the anchor \
         redeem its full {opened_at} s",
    );
}

/// A hard ingest failure holds its generation back too.
///
/// The engine never saw this event — the transport parse failed — so unlike a
/// `Stale` verdict there is no engine-side retention behind it and nothing has
/// decided anything about it. The conservative reading is the only safe one: the
/// event is re-requested, at the cost of a wider window.
///
/// (This is also the one hold-back an unauthenticated party can mint at will, so
/// it is where the design's cost lands: a stall, never a skip, and floored by the
/// monotonic cursor write — see this file's header.)
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn livesync_an_unprocessable_event_holds_the_cursor_below_itself() {
    let fx = build_two_member_circle(vec!["wss://group.example.com".to_string()]).await;
    let processor = EngineProcessor::new(Arc::clone(&fx.alice), EventBus::new());

    let floor = (now_secs() - 7200) * 1000;
    fx.seed_alice_cursor(floor);
    let opened_at = now_secs();
    processor.note_subscription_opened(&fx.group_hex(), opened_at);

    // `!` is outside every base64 alphabet, so the transport conversion fails
    // before the engine is reached. Dated an hour below the anchor so the
    // hold-back is unmistakable.
    let unparseable_secs = now_secs() - 3600;
    let junk = EventBuilder::new(nostr::Kind::Custom(445), "!!!!not-base64!!!!")
        .tags(vec![Tag::parse(["h", &fx.group_hex()]).unwrap()])
        .custom_created_at(Timestamp::from(u64::try_from(unparseable_secs).unwrap()))
        .sign_with_keys(&Keys::generate())
        .expect("sign junk");

    assert_eq!(
        processor
            .process_group_event(&junk, &fx.nostr_group_id)
            .await,
        GroupProcessOutcome::Unprocessable,
        "precondition: this must be a hard ingest failure, not an engine verdict"
    );
    assert_eq!(
        fx.alice_cursor(),
        Some(floor),
        "an unprocessable event advances nothing on delivery"
    );

    assert!(processor.note_end_of_stored_events(&fx.group_hex()));
    assert_eq!(
        fx.alice_cursor(),
        Some(unparseable_secs * 1000),
        "and it caps the generation's anchor at itself rather than letting it \
         redeem its full {opened_at} s",
    );
}

/// The window anchor may not push the cursor past the local clock either.
///
/// A relay accepts a `created_at` up to ~`now + 900 s`, and a co-member whose
/// clock runs fast needs no relay's cooperation at all. A cursor parked in the
/// future is not merely cosmetic: `since_for_stream` caps the derived REQ floor
/// at `now`, so for the whole duration of the skew every fetch floor sits at
/// `now` and catch-up degrades to "only what is published after each fetch".
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn livesync_a_future_dated_event_cannot_push_the_cursor_past_now() {
    let fx = build_two_member_circle(vec!["wss://group.example.com".to_string()]).await;
    let processor = EngineProcessor::new(Arc::clone(&fx.alice), EventBus::new());

    let floor = (now_secs() - 7200) * 1000;
    fx.seed_alice_cursor(floor);
    let opened_at = now_secs();
    processor.note_subscription_opened(&fx.group_hex(), opened_at);

    let observed = fx.bob_location(1.0, 2.0).await;
    // Inside a spec-conformant relay's forward tolerance, so this is reachable
    // without a malicious relay at all.
    let future = Timestamp::now().as_secs() + 900;
    let event = rewrap(&observed, future, false);

    let before = now_secs();
    let outcome = processor
        .process_group_event(&event, &fx.nostr_group_id)
        .await;
    assert!(
        matches!(
            outcome,
            GroupProcessOutcome::Applied | GroupProcessOutcome::Stale
        ),
        "precondition: the engine authenticates this one ({outcome:?})",
    );
    assert!(processor.note_end_of_stored_events(&fx.group_hex()));

    let after = now_secs();
    let cursor = fx.alice_cursor().expect("the cursor advanced");
    assert!(
        cursor <= after * 1000,
        "the cursor must be clamped to the local clock; got {cursor} ms for an \
         event dated {future} s"
    );
    assert!(
        cursor >= before * 1000,
        "the clamp must land ON now, not reset the cursor to zero; got {cursor} ms"
    );
}

/// The persistence half of the defect: the poisoned cursor survived restarts, so
/// its fix has to as well. The held floor must still be there after a fresh
/// `CircleManager` reopens the same on-disk store.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn livesync_the_held_cursor_survives_a_restart() {
    let dir = TempDir::new().unwrap();
    let alice_keys = Keys::generate();
    let alice = Arc::new(CircleManager::new_unencrypted(dir.path(), &alice_keys).unwrap());

    let (bob, bob_keys, bob_member, _bob_dir) =
        mint_member(&["wss://member-inbox.example.com".to_string()]).await;
    let relays = vec!["wss://group.example.com".to_string()];
    let config = CircleConfig::new("Restart Circle").with_relays(relays.clone());
    let result = alice
        .create_circle(&alice_keys, vec![bob_member], &config, &relays)
        .await
        .expect("create circle");
    let mls_group_id = result.circle.mls_group_id.clone();
    let nostr_group_id = result.circle.nostr_group_id;
    alice
        .confirm_published(result.pending)
        .await
        .expect("confirm");
    let welcome = result
        .welcome_events
        .iter()
        .find(|w| w.recipient_pubkey == bob_keys.public_key().to_hex())
        .expect("welcome for bob");
    bob.process_gift_wrapped_invitation(&bob_keys, &welcome.event)
        .await
        .expect("welcome");
    bob.accept_invitation(&welcome.event.id)
        .await
        .expect("join");

    let stream = group_cursor_stream(&hex::encode(nostr_group_id));
    let floor = (now_secs() - 7200) * 1000;
    alice.advance_sync_cursor(&stream, floor).expect("seed");

    let observed = bob
        .encrypt_location(
            &mls_group_id,
            &bob_keys.public_key(),
            &LocationMessage::new(9.0, 9.0),
            300,
        )
        .await
        .expect("bob encrypts")
        .0;
    let forged = rewrap(&observed, Timestamp::now().as_secs(), true);

    let processor = EngineProcessor::new(Arc::clone(&alice), EventBus::new());
    assert_eq!(
        processor
            .process_group_event(&forged, &nostr_group_id)
            .await,
        GroupProcessOutcome::RejectedBeforeAuth,
        "precondition: the forgery really was screened"
    );

    drop(processor);
    drop(alice);
    tokio::time::sleep(Duration::from_millis(50)).await;

    let reopened = CircleManager::new_unencrypted(dir.path(), &alice_keys).expect("reopen");
    assert_eq!(
        reopened.read_sync_cursor(&stream).expect("cursor read"),
        Some(floor),
        "the un-poisoned floor must be what persists — the original defect's \
         damage was durable, so its fix has to be too"
    );
}

// ============================================================================
// Catch-up plane (run_catchup_all_circles), over an in-process relay
// ============================================================================

async fn relay_under_test() -> (MockRelay, String, RelayManager) {
    let _ = allow_ws_loopback_for_test();
    let relay = MockRelay::run().await.expect("mock relay");
    let url = relay.url().await.to_string();
    (relay, url, RelayManager::new())
}

/// The sweep's advance — the control every "must not advance" gate is measured
/// against, driven through the real fetch + ingest + cursor write.
///
/// It lands on the FETCH WINDOW's open time, not on the applied event: the sweep
/// asked the relay for everything since its floor and got it, so what it has
/// earned the right to claim is that local instant.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn catchup_a_completed_window_advances_to_its_own_open_time() {
    let (_relay, url, relay_mgr) = relay_under_test().await;
    let fx = build_two_member_circle(vec![url.clone()]).await;

    let floor = (now_secs() - 7200) * 1000;
    fx.seed_alice_cursor(floor);

    let loc_event = fx.bob_location(52.370_216, 4.895_168).await;
    relay_mgr
        .publish_event(&loc_event, std::slice::from_ref(&url))
        .await
        .expect("bob's location reaches the relay");

    // Let the wall clock tick past the event's `created_at` second, so the two
    // candidate advance values (the event vs the window) are distinguishable.
    // This is also the real shape of a catch-up: the backlog is older than the
    // sweep that fetches it.
    tokio::time::sleep(Duration::from_millis(1_500)).await;

    let before = now_secs();
    let out = run_catchup_all_circles(&fx.alice, &relay_mgr, &fx.alice_keys.public_key(), 20).await;
    let after = now_secs();

    assert_eq!(out.circles_swept, 1);
    assert_eq!(out.events_applied, 1);
    assert_eq!(
        out.events_rejected_pre_auth, 0,
        "a live event must not trip the receiver-side screen"
    );
    let cursor = fx.alice_cursor().expect("the sweep advanced the cursor");
    assert!(
        cursor >= before * 1000 && cursor <= after * 1000,
        "the advance must be the window's own open time (between {before} s and \
         {after} s); got {cursor} ms",
    );
    assert!(
        cursor > secs_of(&loc_event) * 1000,
        "and it is strictly ABOVE the applied event's created_at, which is what \
         proves the advance is not being read off the event",
    );
}

/// THE ATTACK, end to end through the real sweep: an un-expired re-wrap dated
/// far in the future is fetched, reaches the engine, gets a clean verdict — and
/// cannot drag the cursor past the window's open time.
///
/// Under the old contiguous-prefix rule this single event moved the persisted
/// cursor to its own `created_at`, and `since_for_stream` then stranded every
/// genuine event below it on every subsequent sweep, across restarts.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn catchup_a_rewrapped_forgery_cannot_drag_the_cursor_forward() {
    let (_relay, url, relay_mgr) = relay_under_test().await;
    let fx = build_two_member_circle(vec![url.clone()]).await;

    let floor = (now_secs() - 7200) * 1000;
    fx.seed_alice_cursor(floor);

    let observed = fx.bob_location(1.0, 2.0).await;
    // A relay accepts `created_at` up to roughly `now + 900 s`, so this needs no
    // malicious relay at all — and a peer with a fast clock reaches it by
    // accident.
    let future = Timestamp::now().as_secs() + 900;
    let forged = rewrap(&observed, future, false);
    relay_mgr
        .publish_event(&forged, std::slice::from_ref(&url))
        .await
        .expect("the forgery reaches the relay");

    let before = now_secs();
    let out = run_catchup_all_circles(&fx.alice, &relay_mgr, &fx.alice_keys.public_key(), 20).await;
    let after = now_secs();

    assert_eq!(
        out.events_applied, 1,
        "precondition: the forgery really was fetched and given an engine verdict"
    );
    let cursor = fx.alice_cursor().expect("the cursor advanced");
    assert!(
        cursor <= after * 1000,
        "the forged created_at ({future} s) must not appear in the cursor; got \
         {cursor} ms",
    );
    assert!(
        cursor >= before * 1000,
        "and the window's own advance must still happen (not a reset to zero); \
         got {cursor} ms",
    );
}

/// The availability direction, which the old rule got wrong: a window whose
/// events are ALL undecryptable must still advance.
///
/// The sweep fetched the whole window, so it is caught up to the open time
/// whatever the engine made of the contents. Under the contiguous-prefix rule
/// this was fine only because an undecryptable 445 counted as "applied"; making
/// it hold instead — the tempting hardening — would freeze the cursor of any
/// client temporarily unable to decrypt and grow its window until `saturated`
/// froze it permanently.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn catchup_a_window_of_only_undecryptable_events_still_advances() {
    let (_relay, url, relay_mgr) = relay_under_test().await;
    let fx = build_two_member_circle(vec![url.clone()]).await;

    let floor = (now_secs() - 7200) * 1000;
    fx.seed_alice_cursor(floor);

    // Valid base64, routed at the circle's public `#h`, but not this group's
    // ciphertext — the engine reports `Stale { PeelFailed }`.
    let junk = EventBuilder::new(
        nostr::Kind::Custom(445),
        "bm90LWEtY2lwaGVydGV4dC1qdXN0LXBhZGRlZC1nYXJiYWdlLWJ5dGVz",
    )
    .tags(vec![Tag::parse(["h", &fx.group_hex()]).unwrap()])
    .sign_with_keys(&Keys::generate())
    .expect("sign junk");
    relay_mgr
        .publish_event(&junk, std::slice::from_ref(&url))
        .await
        .expect("the junk reaches the relay");

    let before = now_secs();
    let out = run_catchup_all_circles(&fx.alice, &relay_mgr, &fx.alice_keys.public_key(), 20).await;

    assert_eq!(
        out.events_deferred, 0,
        "an engine verdict is not a deferral"
    );
    let cursor = fx.alice_cursor().expect("the cursor advanced");
    assert!(
        cursor >= before * 1000,
        "an all-undecryptable window must not wedge the cursor; got {cursor} ms",
    );
}

/// A relay that could not be reached must hold the cursor: an empty window from
/// nowhere is not the same claim as an empty window from a relay.
///
/// This is the gate that stops the window-open anchor from waving through an
/// outage — the one case where "no events" carries no information at all.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn catchup_an_unreachable_relay_holds_the_cursor() {
    // Port 1 refuses immediately: no network, no connect-timeout hang, and still
    // a well-formed `wss://` so it exercises the fetch path.
    let fx = build_two_member_circle(vec!["wss://127.0.0.1:1".to_string()]).await;
    let relay_mgr = RelayManager::new();

    let floor = (now_secs() - 7200) * 1000;
    fx.seed_alice_cursor(floor);

    let out = run_catchup_all_circles(&fx.alice, &relay_mgr, &fx.alice_keys.public_key(), 20).await;

    assert_eq!(out.circles_swept, 1, "the circle was attempted");
    assert!(out.relay_errors >= 1, "the non-responder is tallied");
    assert_eq!(
        fx.alice_cursor(),
        Some(floor),
        "nothing was reached, so nothing may be claimed as caught up",
    );
}
