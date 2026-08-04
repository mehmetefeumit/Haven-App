//! The cursor-anchored catch-up sweep (M7), end-to-end over an in-process relay.
//!
//! `run_catchup_all_circles` is what a background wake and a foreground resume
//! run: fetch whatever a circle's relays hold since the persisted cursor, feed it
//! to the engine, persist any decrypted peer location, re-broadcast any auto-
//! commit, and advance the cursor to the fetch window's own open time (held back
//! at anything the window could not apply). Until this file the
//! only thing under test was the pure cursor arithmetic
//! (`cursor_advance_ms` / `hold_backs`); the sweep itself — the
//! fetch, the ingest, the persistence, and the cursor WRITE — ran nowhere.
//!
//! # What these tests assert against, and why not the counters
//!
//! [`CatchupOutcome`] is a presence-only tally, and one of its fields cannot
//! carry the weight an assertion would put on it: `cursors_advanced` counts a
//! cursor WRITE that returned `Ok`, and the write is
//! `update_sync_cursor_max` — an `INSERT … ON CONFLICT DO UPDATE … WHERE
//! excluded.last_synced_ms > sync_cursors.last_synced_ms`, which returns `Ok`
//! while changing nothing when the new value would move the cursor backwards.
//! So the tests below read the cursor back with `read_sync_cursor` and assert
//! its VALUE. The counters are asserted only where they are the thing being
//! described (a relay that did not respond, a deadline that was hit).
//!
//! # What a cursor VALUE may be asserted against, and what it may never be
//!
//! Never an event's `created_at`, nor anything derived from one. The outer
//! `kind:445` envelope is signed by a throwaway ephemeral key and its
//! `created_at` is bound to nothing the engine authenticates, so an advance read
//! off it is remotely writable in the one direction that strands legitimate
//! history permanently. The sweep therefore anchors every advance on a LOCAL
//! clock reading taken before the fetch window's REQ went out, and lets event
//! timestamps only HOLD IT BACK — see
//! [`haven_core::relay::cursor::cursor_ms_for_window`], which carries the full
//! argument.
//!
//! So an "it advanced" assertion here brackets the sweep with two readings of
//! the SAME clock the sweep uses (`chrono::Utc::now().timestamp()`, whole
//! seconds) and asserts the cursor lands in that closed interval. That pins the
//! value's PROVENANCE rather than its arithmetic, and it is strictly stronger
//! than an equality against the applied event: an implementation that read the
//! event's timestamp could not satisfy it, because [`wait_until_after`] puts a
//! whole second between the publish and the sweep. A "it held" assertion bounds
//! the cursor from ABOVE by the held event instead, which is the only direction
//! a remote timestamp is allowed to appear in.

use std::sync::Arc;
use std::time::Duration;

use haven_core::circle::{CircleConfig, CircleManager, MemberKeyPackage};
use haven_core::location::LocationMessage;
use haven_core::nostr::mls::types::GroupId;
use haven_core::relay::catchup::run_catchup_all_circles;
use haven_core::relay::live_sync::group_cursor_stream;
use haven_core::relay::maintenance::build_kp_maintenance_events;
use haven_core::relay::{allow_ws_loopback_for_test, RelayManager};
use nostr::Keys;
use nostr_relay_builder::MockRelay;
use tempfile::TempDir;

/// Alice (admin) + Bob as real co-members, each with their own MLS store, with
/// the circle's stored relays pointed wherever the test needs them — that relay
/// set is what the sweep fetches from and publishes to.
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
    fn cursor_stream(&self) -> String {
        group_cursor_stream(&hex::encode(self.nostr_group_id))
    }

    /// Alice's persisted cursor for this circle, or `None` while unseeded.
    fn alice_cursor(&self) -> Option<i64> {
        self.alice
            .read_sync_cursor(&self.cursor_stream())
            .expect("cursor read")
    }
}

async fn mint_member(relays: &[String]) -> (Arc<CircleManager>, Keys, MemberKeyPackage, TempDir) {
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
        inbox_relays: relays.to_vec(),
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
    let config = CircleConfig::new("Catch-up Sweep Circle").with_relays(group_relays.clone());
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

/// Blocks until the local wall clock has ticked strictly PAST `secs`, read from
/// the same clock and at the same whole-second precision the sweep's anchor uses
/// (`chrono::Utc::now().timestamp()`).
///
/// The sweep's advance is the fetch window's open time; the pre-fix rule used
/// the applied event's `created_at` instead. Those two values are only
/// DISTINGUISHABLE once a whole second separates them, so a test that means to
/// pin the advance's provenance has to put one there. Without it the test passes
/// under either rule whenever the publish and the sweep fall in the same second
/// — which is most of the time, making the assertion silently vacuous and, if
/// stated as an equality against the event, flaky at every second boundary.
///
/// Waiting for the tick rather than sleeping a fixed 1.5 s makes the separation
/// a guarantee instead of a probability, and costs half a second on average.
/// It is also the real shape of a catch-up: the backlog is always older than the
/// sweep that fetches it.
async fn wait_until_after(secs: i64) {
    while chrono::Utc::now().timestamp() <= secs {
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
}

/// A running in-process relay plus a `RelayManager` pointed at it — the same
/// pair the background wake hands to the sweep.
async fn relay_under_test() -> (MockRelay, String, RelayManager) {
    let _ = allow_ws_loopback_for_test();
    let relay = MockRelay::run().await.expect("mock relay");
    let url = relay.url().await.to_string();
    (relay, url, RelayManager::new())
}

/// The sweep's whole job on the receive side: fetch a peer's `kind:445`, apply
/// it, persist the decrypted location, and advance the cursor to the FETCH
/// WINDOW's own open time — never to the event's remotely-chosen `created_at`.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_peer_location_is_applied_persisted_and_moves_the_cursor() {
    let (_relay, url, relay_mgr) = relay_under_test().await;
    let fx = build_two_member_circle(vec![url.clone()]).await;

    assert_eq!(
        fx.alice_cursor(),
        None,
        "precondition: the cursor is unseeded, so a later Some() is this sweep's \
         doing and not a leftover"
    );

    let (loc_event, _, _) = fx
        .bob
        .encrypt_location(
            &fx.mls_group_id,
            &fx.bob_keys.public_key(),
            &LocationMessage::new(52.370_216, 4.895_168),
            300,
        )
        .await
        .expect("bob encrypts a location");
    relay_mgr
        .publish_event(&loc_event, std::slice::from_ref(&url))
        .await
        .expect("bob's location reaches the relay");

    // Put a whole second between the event and the window that fetches it, so
    // the event's `created_at` and the window's open time are distinguishable
    // values rather than the same one (see `wait_until_after`).
    let created_secs = i64::try_from(loc_event.created_at.as_secs()).expect("created_at fits i64");
    wait_until_after(created_secs).await;

    // The bracket. Both readings come from the SAME clock and the SAME
    // precision as the sweep's own anchor and clamp
    // (`chrono::Utc::now().timestamp()`), so the interval below is exact and
    // carries no rounding slack in either direction.
    let swept_from = chrono::Utc::now().timestamp();
    let out = run_catchup_all_circles(&fx.alice, &relay_mgr, &fx.alice_keys.public_key(), 20).await;
    let swept_to = chrono::Utc::now().timestamp();

    assert!(
        swept_from > created_secs,
        "precondition: the window must open strictly AFTER the event was \
         published ({created_secs} s), or an advance read off the event would \
         land inside the interval asserted below and the whole gate would be \
         vacuous"
    );

    assert_eq!(out.circles_swept, 1);
    assert_eq!(
        out.events_applied, 1,
        "the peer location must be applied, not deferred"
    );
    assert_eq!(out.events_deferred, 0);
    assert_eq!(
        out.windows_truncated, 0,
        "a one-event window is nowhere near the per-circle cap"
    );

    // Persisted, and attributed to Bob rather than to whoever swept.
    let rows = fx
        .alice
        .snapshot_last_known_for_circle(&fx.nostr_group_id, chrono::Utc::now().timestamp())
        .expect("snapshot");
    assert_eq!(rows.len(), 1, "exactly one peer row");
    assert_eq!(rows[0].sender_pubkey, fx.bob_keys.public_key().to_hex());
    assert!((rows[0].latitude - 52.370_216).abs() < 1e-9);
    assert!((rows[0].longitude - 4.895_168).abs() < 1e-9);
    assert!(
        rows[0].purge_after > rows[0].timestamp,
        "the retention horizon must be derived by the upsert, never the 0 the \
         sweep passes in — a 0 would make the row read as already purged"
    );

    // The cursor VALUE, not the counter (see this file's header).
    //
    // PROVENANCE, not equality: the advance is the fetch window's own open time,
    // a local clock reading no remote party can write, so it must fall inside
    // the bracket taken around the call. This is a strictly stronger statement
    // than "the cursor equals the applied event's created_at" was — that
    // equality pinned an arithmetic coincidence, this pins where the value comes
    // from, and the precondition above makes it unsatisfiable by any
    // implementation that reads the event's timestamp.
    let cursor = fx.alice_cursor().expect("the sweep wrote a cursor");
    assert!(
        cursor >= swept_from * 1000 && cursor <= swept_to * 1000,
        "the cursor must land on the fetch window's own open time (between \
         {swept_from} s and {swept_to} s), so the next sweep resumes from where \
         this one asked rather than re-ingesting or skipping ahead; got {cursor} ms"
    );
    assert!(
        cursor > created_secs * 1000,
        "and strictly ABOVE the applied event's created_at ({created_secs} s) — \
         which is what proves the advance is not being read off the event, whose \
         outer envelope is signed by a throwaway key and bound to nothing the \
         engine authenticates; got {cursor} ms"
    );

    // Monotonic-max and the clamp, at this call site rather than only in the
    // storage layer's unit tests. A second sweep over the same relay contents
    // re-fetches the same event (the next `since` keeps a lookback buffer below
    // the cursor) and must never hand the write a smaller number — a regression
    // here would re-open a window the device had already closed. Nor may
    // repeated sweeps ever park the cursor above the local wall clock, where
    // `since_for_stream` pins every subsequent REQ floor at `now`.
    let again_from = chrono::Utc::now().timestamp();
    let _ = run_catchup_all_circles(&fx.alice, &relay_mgr, &fx.alice_keys.public_key(), 20).await;
    let again_to = chrono::Utc::now().timestamp();
    let cursor_again = fx.alice_cursor().expect("the cursor is still readable");
    assert!(
        cursor_again >= cursor,
        "monotonic-max: a re-sweep must never LOWER the persisted cursor \
         ({cursor} ms → {cursor_again} ms)"
    );
    assert!(
        cursor_again <= again_to * 1000,
        "and the clamp holds across sweeps: no advance may park the cursor above \
         the local clock ({again_to} s); got {cursor_again} ms, for a window \
         opened at or after {again_from} s"
    );
}

/// The sweep must not persist the sweeper's OWN location as a peer row: a
/// self-echo would render the user twice on their own map, once at a stale
/// position.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_own_echo_is_never_persisted_as_a_peer_row() {
    let (_relay, url, relay_mgr) = relay_under_test().await;
    let fx = build_two_member_circle(vec![url.clone()]).await;

    let (own_event, _, _) = fx
        .alice
        .encrypt_location(
            &fx.mls_group_id,
            &fx.alice_keys.public_key(),
            &LocationMessage::new(1.0, 2.0),
            300,
        )
        .await
        .expect("alice encrypts her own location");
    relay_mgr
        .publish_event(&own_event, std::slice::from_ref(&url))
        .await
        .expect("alice's own location reaches the relay");

    let out = run_catchup_all_circles(&fx.alice, &relay_mgr, &fx.alice_keys.public_key(), 20).await;

    assert_eq!(out.circles_swept, 1);
    let rows = fx
        .alice
        .snapshot_last_known_for_circle(&fx.nostr_group_id, chrono::Utc::now().timestamp())
        .expect("snapshot");
    assert!(
        rows.is_empty(),
        "the sweeper's own echo must never become a last-known row"
    );
}

/// A relay that cannot be reached is TALLIED and never fatal — and, critically,
/// never advances the cursor: a silent advance over a window that was never
/// fetched would skip that backlog permanently.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_unreachable_relay_is_tallied_and_holds_the_cursor() {
    // Port 1 refuses immediately, so this needs no network and cannot hang on a
    // connect timeout. Still a well-formed `wss://`, so it passes URL validation
    // and genuinely exercises the fetch path rather than the reject path.
    let dead = "wss://127.0.0.1:1".to_string();
    let fx = build_two_member_circle(vec![dead]).await;
    let relay_mgr = RelayManager::new();

    let out = run_catchup_all_circles(&fx.alice, &relay_mgr, &fx.alice_keys.public_key(), 20).await;

    assert_eq!(out.circles_swept, 1, "the circle was attempted");
    assert!(
        out.relay_errors >= 1,
        "a relay that did not respond must be tallied"
    );
    assert_eq!(out.events_applied, 0);
    assert_eq!(
        fx.alice_cursor(),
        None,
        "nothing was fetched, so nothing may be marked as caught up"
    );
}

/// An already-expired deadline stops the sweep before any circle, and says so.
/// The wake paths call this with a budget; exceeding it must degrade to "did
/// less", never to "claimed to have caught up".
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_expired_deadline_sweeps_nothing_and_reports_it() {
    let (_relay, url, relay_mgr) = relay_under_test().await;
    let fx = build_two_member_circle(vec![url]).await;

    let out = run_catchup_all_circles(&fx.alice, &relay_mgr, &fx.alice_keys.public_key(), 0).await;

    assert!(out.deadline_hit, "a zero budget is an immediate deadline");
    assert_eq!(out.circles_swept, 0);
    assert_eq!(out.events_applied, 0);
    assert_eq!(
        fx.alice_cursor(),
        None,
        "a sweep that did nothing must not move the cursor"
    );
}

/// With no circles there is nothing to sweep and no relay traffic at all — the
/// shape a wake takes on a fresh install, which must be a clean no-op rather
/// than an error.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn no_circles_is_a_clean_no_op() {
    let dir = TempDir::new().unwrap();
    let keys = Keys::generate();
    let mgr = CircleManager::new_unencrypted(dir.path(), &keys).unwrap();

    let out = run_catchup_all_circles(&mgr, &RelayManager::new(), &keys.public_key(), 20).await;

    assert_eq!(out, haven_core::relay::CatchupOutcome::default());
}

/// Rule 13 on the background path: the sweep does not merely READ. Ingesting a
/// peer's `SelfRemove` proposal surfaces a jitter-delayed auto-commit, which the
/// sweep must publish to the circle's relays and confirm only on an ack — so the
/// rest of the group receives the eviction instead of the sweeper forking.
///
/// This is what the re-tick loop inside `ingest_one` exists for: the auto-commit
/// is not due at ingest time, and a single `advance_convergence` would drain the
/// group out of the pending set and strand the commit unpublished.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_peer_leave_is_committed_and_re_broadcast_by_the_sweep() {
    let (_relay, url, relay_mgr) = relay_under_test().await;
    let fx = build_two_member_circle(vec![url.clone()]).await;
    let bob_hex = fx.bob_keys.public_key().to_hex();
    let epoch_before = fx
        .alice
        .session()
        .epoch(&fx.mls_group_id)
        .await
        .expect("epoch");

    let proposal = fx
        .bob
        .propose_leave(&fx.mls_group_id)
        .await
        .expect("bob proposes leave");
    relay_mgr
        .publish_event(&proposal, std::slice::from_ref(&url))
        .await
        .expect("the leave proposal reaches the relay");

    let out = run_catchup_all_circles(&fx.alice, &relay_mgr, &fx.alice_keys.public_key(), 20).await;

    assert_eq!(out.events_applied, 1, "the proposal itself is applied");
    assert!(
        !fx.alice
            .session()
            .member_pubkeys(&fx.mls_group_id)
            .await
            .expect("roster")
            .contains(&bob_hex),
        "the sweep must drive the eviction to completion, not leave the leaver \
         in the roster until the app is next opened"
    );
    assert_eq!(
        fx.alice
            .session()
            .epoch(&fx.mls_group_id)
            .await
            .expect("epoch"),
        epoch_before + 1,
        "the epoch advances exactly once, on the confirmed eviction commit"
    );

    // The commit really went out: a fresh reader of the relay finds a 445 that
    // is not the proposal Bob published. Without the publish half, Alice would
    // have evicted Bob locally and nobody else would ever know (the fork).
    let fetched = relay_mgr
        .fetch_events_per_relay(
            haven_core::relay::live_sync::planes::group::group_filter(
                std::slice::from_ref(&hex::encode(fx.nostr_group_id)),
                0,
            ),
            std::slice::from_ref(&url),
        )
        .await
        .expect("relay read-back");
    let ids: Vec<_> = fetched
        .iter()
        .flat_map(|fo| fo.events.iter().map(|e| e.id))
        .collect();
    assert!(
        ids.iter().any(|id| *id != proposal.id),
        "the eviction commit must have been PUBLISHED to the circle's relays, \
         not just applied locally (Rule 13 / the roster fork)"
    );

    // Idempotence: a second sweep over the same relay contents must not
    // re-apply anything or move the epoch again.
    let epoch_after = fx
        .alice
        .session()
        .epoch(&fx.mls_group_id)
        .await
        .expect("epoch");
    let again =
        run_catchup_all_circles(&fx.alice, &relay_mgr, &fx.alice_keys.public_key(), 20).await;
    assert_eq!(again.events_deferred, 0, "nothing should be left pending");
    assert_eq!(
        fx.alice
            .session()
            .epoch(&fx.mls_group_id)
            .await
            .expect("epoch"),
        epoch_after,
        "re-sweeping already-seen events must be inert"
    );

    // The relay keeps serving the same events, so a bounded settle is enough for
    // the second sweep to have drained; no assertion depends on the wait.
    tokio::time::sleep(Duration::from_millis(50)).await;
}

/// An event the engine cannot ingest at all must be counted as DEFERRED and must
/// HOLD the cursor at or below itself — never be skipped past.
///
/// This is the Rule-12 property at the level of a single event: the sweep cannot
/// tell an un-ingestable event apart from one that will apply once a missing
/// commit arrives, so it must assume the latter. Advancing over it would push
/// `since` past an event that was never applied, and if the event were a commit
/// the epoch chain would be stranded with nothing left to re-fetch it.
///
/// # What "held" means now, and why the test proves it directly
///
/// The sweep's advance is anchored on the FETCH WINDOW's open time, not on any
/// event, so "held" is no longer the same statement as "the cursor is still
/// unset" — a deferral caps the advance at that event rather than suppressing it
/// entirely. That cap is exactly as strong, because `since` is an inclusive
/// lower bound: a cursor sitting ON the deferred event still re-requests it,
/// with no reliance on the clock-skew buffer at all.
///
/// So this asserts the property the old `cursor == None` was only a proxy for:
/// a SECOND sweep must see the same event again.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_uningestable_event_defers_and_holds_the_cursor() {
    let (_relay, url, relay_mgr) = relay_under_test().await;
    let fx = build_two_member_circle(vec![url.clone()]).await;
    let hex_gid = hex::encode(fx.nostr_group_id);

    // A well-formed, correctly-addressed `kind:445` that no group key can open:
    // exactly what a hostile or confused relay can inject into the window.
    let junk = nostr::EventBuilder::new(nostr::Kind::Custom(445), "opaque-ciphertext")
        .tags([nostr::Tag::custom(
            nostr::TagKind::SingleLetter(nostr::SingleLetterTag::lowercase(nostr::Alphabet::H)),
            [hex_gid],
        )])
        .sign_with_keys(&Keys::generate())
        .expect("sign junk 445");
    relay_mgr
        .publish_event(&junk, std::slice::from_ref(&url))
        .await
        .expect("the junk event reaches the relay");
    let junk_secs = i64::try_from(junk.created_at.as_secs()).expect("created_at fits");

    let out = run_catchup_all_circles(&fx.alice, &relay_mgr, &fx.alice_keys.public_key(), 20).await;

    assert_eq!(out.circles_swept, 1);
    assert_eq!(
        out.events_deferred, 1,
        "an event the engine could not ingest is deferred, not applied"
    );
    assert_eq!(out.events_applied, 0);
    let cursor = fx
        .alice_cursor()
        .expect("the window still advanced somewhere");
    assert!(
        cursor <= junk_secs * 1000,
        "the cursor must not move PAST an event that was never applied; got \
         {cursor} ms for an event dated {junk_secs} s",
    );

    // The property that actually matters: the next sweep still sees it.
    let again =
        run_catchup_all_circles(&fx.alice, &relay_mgr, &fx.alice_keys.public_key(), 20).await;
    assert_eq!(
        again.events_deferred, 1,
        "the un-applied event must be re-fetched by the next sweep — that is \
         what holding the cursor is FOR",
    );
}
