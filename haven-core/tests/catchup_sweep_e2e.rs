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

use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::Duration;

use haven_core::circle::{CircleConfig, CircleManager, MemberKeyPackage};
use haven_core::location::LocationMessage;
use haven_core::nostr::mls::types::GroupId;
use haven_core::relay::catchup::run_catchup_all_circles;
use haven_core::relay::live_sync::group_cursor_stream;
use haven_core::relay::maintenance::build_kp_maintenance_events;
use haven_core::relay::{allow_ws_loopback_for_test, RelayManager};
use nostr::{Event, EventBuilder, Keys, Kind, Tag, Timestamp};
use nostr_relay_builder::prelude::{
    BoxedFuture, MemoryDatabase, MemoryDatabaseOptions, NostrDatabase, PolicyResult, QueryPolicy,
};
use nostr_relay_builder::{LocalRelay, MockRelay, RelayBuilder};
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

    /// Where Alice's catch-up chase has to resume, or `None` when no sweep has
    /// run out of budget on this circle.
    fn alice_floor(&self) -> Option<i64> {
        self.alice
            .read_backfill_floor(&self.cursor_stream())
            .expect("floor read")
    }

    /// The peer locations Alice has actually decrypted and stored for this
    /// circle — the only end-to-end evidence that a given event was REACHED.
    fn alice_peer_locations(&self) -> Vec<haven_core::circle::LastKnownLocation> {
        self.alice
            .snapshot_last_known_for_circle(&self.nostr_group_id, chrono::Utc::now().timestamp())
            .expect("snapshot")
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
    let rows = fx.alice_peer_locations();
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
    let rows = fx.alice_peer_locations();
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

    // A tick, so the tally below is about the PROPOSAL and not about this
    // sweep's own doing. A window whose oldest event is dated in the sweep's own
    // opening second is re-asked once (see `Pager::bound_secs`), and the eviction
    // commit this sweep publishes mid-ingest is dated in that same second — so
    // without the separation the repeat sometimes hands our own re-broadcast
    // back, for one extra terminal ingest that moves nothing. Separating them
    // costs half a second and makes the count a fact rather than a coin flip.
    wait_until_after(i64::try_from(proposal.created_at.as_secs()).expect("created_at fits")).await;

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

// ─────────────────────────────────────────────────────────────────────────────
// Backward paging: a window larger than one page (Security Rule 12)
//
// NIP-01 `limit: n` serves the NEWEST n, so a circle holding more than the
// sweep's page limit gets its window truncated at the BOTTOM. Holding the cursor
// there stops the silent loss but retrieves nothing; the sweep therefore pages
// backwards, bounded above by the oldest event it has been served, until every
// responding relay answers short.
//
// These drive the real `run_catchup_all_circles` against relays holding more
// than one page: the happy path (everything retrieved, cursor advances), a
// poisoned paging boundary (must not curtail an honest relay's chase), a relay
// that CLAMPS our `limit` the way every strfry deployment does (the truncation
// signal must still fire), a relay that clamps BELOW our page size (the same
// hiding place, one step further down), a chase whose second page is never
// served (a failed read must not read as "drained"), a fetch cut off by its own
// timeout (a partial delivery must not read as a short page), a relay that
// answers only a LATER page (its unrequested top must not be waved through), a
// flood of future-dated events (must not freeze the cursor), an unpageable
// window (must terminate, and must NOT claim to have caught up), and a chase
// that spends the whole wake budget (must still apply what it fetched).
// ─────────────────────────────────────────────────────────────────────────────

/// The sweep's per-page fetch limit, mirrored from the private
/// `catchup::CATCHUP_MAX_EVENTS_PER_PAGE`.
///
/// A window larger than one page is the whole premise here, so the number has to
/// be named. It is deliberately the ONLY thing these tests take from the
/// implementation: nothing below asserts a page count, a request shape, or a
/// boundary value — only which events came back and where the cursor landed.
const PAGE_LIMIT: usize = 500;

/// A relay whose store the test seeds DIRECTLY, bypassing the socket.
///
/// Publishing a window larger than `PAGE_LIMIT` over the wire is not merely slow
/// — `MockRelay` rate-limits writes to 60 events per minute, so it is
/// impossible. Writing into the relay's own `MemoryDatabase` (shared with the
/// running relay by `Arc`) stages the same relay CONTENTS deterministically and
/// in milliseconds, and every read still goes through a real socket, a real REQ,
/// and the relay's real NIP-01 `limit` / `until` handling — which is the part
/// under test.
struct SeededRelay {
    _relay: LocalRelay,
    url: String,
    db: MemoryDatabase,
}

impl SeededRelay {
    async fn run() -> Self {
        Self::with_cap(None).await
    }

    /// `cap` is the relay's NIP-11 `limitation.max_limit`: a REQ asking for more
    /// is CLAMPED to it, never rejected (`nostr-relay-builder`'s
    /// `max_filter_limit`, which is strfry's `maxFilterLimit` behaviour).
    async fn with_cap(cap: Option<usize>) -> Self {
        let mut builder = RelayBuilder::default();
        if let Some(cap) = cap {
            builder = builder.max_filter_limit(cap);
        }
        Self::from_builder(builder).await
    }

    async fn from_builder(builder: RelayBuilder) -> Self {
        let _ = allow_ws_loopback_for_test();
        let db = MemoryDatabase::with_opts(MemoryDatabaseOptions {
            events: true,
            max_events: None,
        });
        let relay = LocalRelay::new(builder.database(db.clone()));
        relay.run().await.expect("seeded relay");
        let url = relay.url().await.to_string();
        Self {
            _relay: relay,
            url,
            db,
        }
    }

    /// Stores `events` verbatim. A rejected save would silently shrink the
    /// window under test, so each one is asserted.
    async fn seed(&self, events: &[Event]) {
        for ev in events {
            assert!(
                self.db.save_event(ev).await.expect("seed").is_success(),
                "the relay must really hold every seeded event, or the window \
                 under test is smaller than the test believes"
            );
        }
    }
}

/// A TCP endpoint in front of a running relay that REFUSES its first connection
/// and proxies every later one — one relay, reached on the second attempt.
///
/// Accepting and immediately dropping the socket produces the same
/// `RelayFetchOutcome` a connection timeout does (`responded == false`, no
/// events) without spending the timeout. `Relay::try_connect` makes exactly ONE
/// attempt per fetch and schedules no retry of its own, so "first connection =
/// first page" holds by construction rather than by timing.
struct ColdFirstConnect {
    url: String,
}

impl ColdFirstConnect {
    async fn in_front_of(relay_url: &str) -> Self {
        let (url, listener, target) = proxy_endpoint(relay_url, "the cold endpoint").await;
        tokio::spawn(async move {
            if let Ok((first, _)) = listener.accept().await {
                drop(first);
            }
            while let Ok((mut inbound, _)) = listener.accept().await {
                let Ok(mut outbound) = tokio::net::TcpStream::connect(&target).await else {
                    continue;
                };
                tokio::spawn(async move {
                    let _ = tokio::io::copy_bidirectional(&mut inbound, &mut outbound).await;
                });
            }
        });
        Self { url }
    }
}

/// Binds a loopback endpoint in front of `relay_url`, returning the `ws://` URL
/// to point a circle at, the listener to accept on, and the relay address to
/// dial.
///
/// Shared by both proxy fixtures below, which differ only in what they do with
/// the connections — not in how they stand in front of a relay.
async fn proxy_endpoint(relay_url: &str, what: &str) -> (String, tokio::net::TcpListener, String) {
    let target = relay_url
        .trim_start_matches("ws://")
        .trim_end_matches('/')
        .to_string();
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
        .await
        .unwrap_or_else(|e| panic!("bind {what}: {e}"));
    let url = format!("ws://{}", listener.local_addr().expect("local addr"));
    (url, listener, target)
}

/// What [`TamperedRelay`] does to the relay's side of the wire.
#[derive(Clone, Copy)]
enum Tamper {
    /// Forward everything unchanged. What a one-shot tamper becomes once it has
    /// fired.
    Verbatim,
    /// Forward this many of the relay's `EOSE`s, then drop the connection on the
    /// next one instead of passing it on.
    ///
    /// `forward_first` picks WHICH round of a chase gets cut, and one sweep
    /// spends one connection, so it is a per-connection count and needs no
    /// timing. Cutting a CONFIRMING round (`CutAtEose(1)`) is the sharp case: a
    /// confirming round is what licenses the cursor to advance, and its page is
    /// one we have already seen — so nothing about its CONTENT distinguishes
    /// "the relay confirmed there is nothing below" from "the relay died on the
    /// way to saying so".
    CutAtEose { forward_first: usize },
    /// Send every `EVENT` twice, so the relay answers with more events than the
    /// REQ's own `limit` permits — the NIP-01 violation the per-REQ intake cap
    /// exists to bound (Security Rule 12).
    DoubleEveryEvent,
    /// Swallow every `EOSE` and leave the socket open, so the read ends on its
    /// own fetch timeout with a page the relay never said was whole.
    ///
    /// The cut-off shape [`Tamper::CutAtEose`] cannot stage: there the socket
    /// dies and the read ends on the disconnect. Here nothing breaks — the relay
    /// simply never finishes — which is what a stalled upstream looks like.
    SwallowEose,
    /// Both of the above at once: more events than the REQ asked for, and no
    /// `EOSE` ever. The read gives up on its own intake cap while the relay is
    /// still mid-answer — the one shape where nothing else will close the REQ
    /// until the subscription's own timeout expires.
    FloodWithoutFinishing,
    /// Announce an `EOSE` for a subscription nobody asked for, before the
    /// relay's own answer.
    ///
    /// One pooled connection carries every REQ, so an `EOSE` for another
    /// subscription is an ordinary sight — including a late one for a REQ this
    /// device already gave up on.
    EoseForAnotherSubscription,
    /// Hold the relay's `EVENT`s back until its `EOSE` and then release them in
    /// REVERSE, so the delivery order is the opposite of the relay's.
    ///
    /// Delivery order is the relay's to choose and NIP-01 fixes none, so this is
    /// a conformant relay — one whose choice must not survive into what a caller
    /// reads.
    ReverseEveryPage,
}

/// A TCP endpoint in front of a running relay that forwards every WebSocket
/// frame verbatim except where [`Tamper`] says otherwise.
///
/// This stages the shapes no other fixture here can, chiefly: a relay that hands
/// over a real page and is then cut off mid-answer. The client receives every
/// `EVENT` the relay sent — the page is byte-for-byte the page a healthy relay
/// of the same size serves — and never receives the `EOSE` that would say the
/// page was all of it. `a_short_page_is_only_drained_when_the_relay_said_so`
/// runs the same relay both ways and asserts exactly that: same events,
/// different verdict.
///
/// Frame-accurate rather than byte-accurate: every edit lands on a frame
/// boundary chosen by CONTENT, so nothing here depends on how the kernel
/// happened to segment the stream. Server→client frames are never masked
/// (RFC 6455 §5.1), so the header is two bytes plus the extended length and
/// needs no unmasking.
struct TamperedRelay {
    url: String,
    /// NIP-01 `CLOSE`s this endpoint has seen the CLIENT send, over every
    /// connection. Read by the test that asserts a read which gave up early
    /// closes its own REQ.
    closes: Arc<AtomicUsize>,
}

impl TamperedRelay {
    async fn in_front_of(relay_url: &str, tamper: Tamper) -> Self {
        let (url, listener, target) = proxy_endpoint(relay_url, "the tampering endpoint").await;
        let closes = Arc::new(AtomicUsize::new(0));
        let counter = Arc::clone(&closes);
        tokio::spawn(async move {
            while let Ok((inbound, _)) = listener.accept().await {
                let Ok(outbound) = tokio::net::TcpStream::connect(&target).await else {
                    continue;
                };
                tokio::spawn(pipe_tampered(
                    inbound,
                    outbound,
                    tamper,
                    Arc::clone(&counter),
                ));
            }
        });
        Self { url, closes }
    }

    /// Blocks until the client has sent at least `n` `CLOSE`s, or fails.
    ///
    /// The bound is well under the SDK's own 10-second subscription timeout, so
    /// a `CLOSE` seen inside it cannot be the auto-closing handler's: it is the
    /// read's own.
    async fn await_closes(&self, n: usize) -> usize {
        let deadline = std::time::Instant::now() + Duration::from_secs(3);
        while self.closes.load(Ordering::Relaxed) < n && std::time::Instant::now() < deadline {
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        self.closes.load(Ordering::Relaxed)
    }
}

/// Pipes one client connection to `relay`, applying `tamper` to the relay's
/// frames on the way back and counting the client's `CLOSE`s on the way out.
async fn pipe_tampered(
    client: tokio::net::TcpStream,
    relay: tokio::net::TcpStream,
    mut tamper: Tamper,
    closes: Arc<AtomicUsize>,
) {
    use tokio::io::AsyncWriteExt;

    let (from_client, mut to_client) = client.into_split();
    let (mut from_relay, to_relay) = relay.into_split();
    tokio::spawn(count_client_closes(from_client, to_relay, closes));

    // The HTTP 101 upgrade is not framed, so it is forwarded verbatim; framing
    // starts immediately after the blank line that ends it.
    if forward_http_head(&mut from_relay, &mut to_client)
        .await
        .is_err()
    {
        return;
    }
    let mut held: Vec<Vec<u8>> = Vec::new();
    while let Ok((frame, payload_at)) = read_server_frame(&mut from_relay).await {
        let payload = &frame[payload_at..];
        match &mut tamper {
            Tamper::CutAtEose { forward_first } if payload.starts_with(br#"["EOSE""#) => {
                let Some(remaining) = forward_first.checked_sub(1) else {
                    return;
                };
                *forward_first = remaining;
            }
            Tamper::DoubleEveryEvent | Tamper::FloodWithoutFinishing
                if payload.starts_with(br#"["EVENT""#) =>
            {
                if to_client.write_all(&frame).await.is_err() {
                    return;
                }
            }
            Tamper::SwallowEose | Tamper::FloodWithoutFinishing
                if payload.starts_with(br#"["EOSE""#) =>
            {
                continue
            }
            Tamper::EoseForAnotherSubscription => {
                tamper = Tamper::Verbatim;
                if to_client
                    .write_all(&text_frame(br#"["EOSE","a-subscription-we-never-opened"]"#))
                    .await
                    .is_err()
                {
                    return;
                }
            }
            Tamper::ReverseEveryPage if payload.starts_with(br#"["EVENT""#) => {
                held.push(frame);
                continue;
            }
            Tamper::ReverseEveryPage if payload.starts_with(br#"["EOSE""#) => {
                for buffered in std::mem::take(&mut held).into_iter().rev() {
                    if to_client.write_all(&buffered).await.is_err() {
                        return;
                    }
                }
            }
            _ => {}
        }
        if to_client.write_all(&frame).await.is_err() {
            return;
        }
    }
}

/// Forwards the client's frames verbatim, tallying every NIP-01 `CLOSE`.
///
/// Client→server frames ARE masked (RFC 6455 §5.1), so the payload is unmasked
/// into a scratch copy to be read and the ORIGINAL bytes are what gets
/// forwarded.
async fn count_client_closes(
    mut from_client: tokio::net::tcp::OwnedReadHalf,
    mut to_relay: tokio::net::tcp::OwnedWriteHalf,
    closes: Arc<AtomicUsize>,
) {
    use tokio::io::AsyncWriteExt;

    // The client opens with an HTTP upgrade REQUEST, which is not framed either.
    if forward_http_head(&mut from_client, &mut to_relay)
        .await
        .is_err()
    {
        return;
    }
    while let Ok((frame, payload_at, mask)) = read_client_frame(&mut from_client).await {
        let payload: Vec<u8> = frame[payload_at..]
            .iter()
            .enumerate()
            .map(|(i, byte)| byte ^ mask[i % 4])
            .collect();
        if payload.starts_with(br#"["CLOSE""#) {
            closes.fetch_add(1, Ordering::Relaxed);
        }
        if to_relay.write_all(&frame).await.is_err() {
            return;
        }
    }
}

/// One unmasked text frame carrying `payload`.
fn text_frame(payload: &[u8]) -> Vec<u8> {
    assert!(
        payload.len() < 126,
        "a longer payload needs an extended length header this helper does not \
         write, and a silently malformed frame would prove nothing"
    );
    let mut frame = vec![0x81, u8::try_from(payload.len()).expect("payload fits")];
    frame.extend_from_slice(payload);
    frame
}

/// Copies one side's HTTP upgrade head through, up to and including the blank
/// line that terminates its headers.
///
/// Read a byte at a time so the copy stops EXACTLY on the header terminator and
/// the first WebSocket frame stays unread for the framing loop; written in one
/// go, so the peer's handshake sees the head as it was sent rather than as 130
/// one-byte arrivals.
async fn forward_http_head(
    from: &mut tokio::net::tcp::OwnedReadHalf,
    to: &mut tokio::net::tcp::OwnedWriteHalf,
) -> std::io::Result<()> {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    let mut head: Vec<u8> = Vec::new();
    loop {
        let mut byte = [0u8; 1];
        from.read_exact(&mut byte).await?;
        head.push(byte[0]);
        if head.ends_with(b"\r\n\r\n") {
            return to.write_all(&head).await;
        }
    }
}

/// Reads ONE masked client→server WebSocket frame, returning its bytes
/// verbatim, the offset at which its payload begins, and the masking key needed
/// to read that payload.
async fn read_client_frame(
    from_client: &mut tokio::net::tcp::OwnedReadHalf,
) -> std::io::Result<(Vec<u8>, usize, [u8; 4])> {
    use tokio::io::AsyncReadExt;

    let (mut frame, len) = read_frame_head(from_client).await?;
    assert_eq!(
        frame[1] & 0x80,
        0x80,
        "a client→server frame must be masked, or this proxy is misreading the \
         stream and every assertion behind it is meaningless"
    );
    let mut mask = [0u8; 4];
    from_client.read_exact(&mut mask).await?;
    frame.extend_from_slice(&mask);
    let payload_at = frame.len();
    frame.resize(payload_at + len, 0);
    from_client.read_exact(&mut frame[payload_at..]).await?;
    Ok((frame, payload_at, mask))
}

/// Reads ONE unmasked WebSocket frame, returning its bytes verbatim and the
/// offset at which its payload begins.
async fn read_server_frame(
    from_relay: &mut tokio::net::tcp::OwnedReadHalf,
) -> std::io::Result<(Vec<u8>, usize)> {
    use tokio::io::AsyncReadExt;

    let (mut frame, len) = read_frame_head(from_relay).await?;
    assert_eq!(
        frame[1] & 0x80,
        0,
        "a server→client frame must not be masked, or this proxy is misreading \
         the stream and every assertion behind it is meaningless"
    );
    let payload_at = frame.len();
    frame.resize(payload_at + len, 0);
    from_relay.read_exact(&mut frame[payload_at..]).await?;
    Ok((frame, payload_at))
}

/// Reads a frame's two-byte header plus any extended length, returning the
/// bytes read verbatim and the payload length they announce.
async fn read_frame_head(
    from: &mut tokio::net::tcp::OwnedReadHalf,
) -> std::io::Result<(Vec<u8>, usize)> {
    use tokio::io::AsyncReadExt;

    let mut head = [0u8; 2];
    from.read_exact(&mut head).await?;
    let mut frame = head.to_vec();
    let len = match head[1] & 0x7F {
        126 => {
            let mut ext = [0u8; 2];
            from.read_exact(&mut ext).await?;
            frame.extend_from_slice(&ext);
            usize::from(u16::from_be_bytes(ext))
        }
        127 => {
            let mut ext = [0u8; 8];
            from.read_exact(&mut ext).await?;
            frame.extend_from_slice(&ext);
            usize::try_from(u64::from_be_bytes(ext)).expect("frame length fits")
        }
        short => usize::from(short),
    };
    Ok((frame, len))
}

/// `count` `kind:445`s addressed to `h`, dated one second apart ending at
/// `newest_secs`, that every sweep classifies as `NoEvidence`.
///
/// Two `#h` tags: a conformant relay serves such an event to a `#h` REQ for
/// either value, and Haven's pure pre-engine parse then refuses it ("exactly one
/// h tag") without touching key material. That is deliberate — `NoEvidence`
/// contributes NOTHING in either cursor direction, so a window built from it
/// isolates the paging property under test from every hold-back. Junk the engine
/// takes instead would defer, and a deferral pins the cursor at the oldest event
/// whether or not paging works, making the advance assertion vacuous.
fn unparseable_window(h: &str, count: usize, newest_secs: i64) -> Vec<Event> {
    let signer = Keys::generate();
    (0..count)
        .map(|i| {
            let age = i64::try_from(count - 1 - i).expect("window size fits i64");
            let secs = newest_secs - age;
            EventBuilder::new(Kind::Custom(445), format!("b3BhcXVl-{i}"))
                .tags(vec![
                    Tag::parse(["h", h]).unwrap(),
                    Tag::parse(["h", &hex::encode([0x11u8; 32])]).unwrap(),
                ])
                .custom_created_at(Timestamp::from(u64::try_from(secs).unwrap()))
                .sign_with_keys(&signer)
                .unwrap()
        })
        .collect()
}

/// `layers` copies of the same `span`-second window, so a band can be filled
/// deeper than one event per second without spanning more wall-clock time.
///
/// Each layer is signed by its own throwaway key, so the ids differ and the
/// relay stores every one of them.
fn stacked_window(h: &str, span: usize, layers: usize, newest_secs: i64) -> Vec<Event> {
    (0..layers)
        .flat_map(|_| unparseable_window(h, span, newest_secs))
        .collect()
}

/// A window bigger than one page must be retrieved WHOLE, and only then may the
/// cursor advance.
///
/// Before backward paging this circle was stuck: the first page came back
/// saturated, the oldest events below it were never delivered, and the cursor
/// was held (correctly — advancing would have dropped them) sweep after sweep,
/// re-fetching a window that only grew.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_window_larger_than_one_page_is_retrieved_whole_and_then_advances() {
    let relay = SeededRelay::run().await;
    let relay_mgr = RelayManager::new();
    let fx = build_two_member_circle(vec![relay.url.clone()]).await;

    let backlog = PAGE_LIMIT + 88;
    let newest_secs = chrono::Utc::now().timestamp() - 60;
    let window = unparseable_window(&hex::encode(fx.nostr_group_id), backlog, newest_secs);
    let oldest_secs = i64::try_from(window[0].created_at.as_secs()).expect("created_at fits");
    relay.seed(&window).await;

    let swept_from = chrono::Utc::now().timestamp();
    let out = run_catchup_all_circles(&fx.alice, &relay_mgr, &fx.alice_keys.public_key(), 60).await;
    let swept_to = chrono::Utc::now().timestamp();

    assert!(
        swept_from > newest_secs,
        "precondition: the whole backlog must predate the window that fetches \
         it, so an advance read off an event could not land in the bracket below"
    );
    assert_eq!(out.circles_swept, 1);
    assert_eq!(
        out.events_rejected_pre_auth,
        backlog,
        "every event in the window must be retrieved and ingested — a single \
         page would have delivered only the newest {PAGE_LIMIT}, leaving the \
         oldest {} stranded below a floor no later sweep would ever lower",
        backlog - PAGE_LIMIT,
    );
    assert_eq!(out.events_applied, 0);
    assert_eq!(out.events_deferred, 0);
    assert_eq!(
        out.windows_truncated, 0,
        "the chase finished, so the window is complete — reporting it as \
         truncated would freeze this circle's cursor forever"
    );

    let cursor = fx.alice_cursor().expect("the completed window advanced");
    assert!(
        cursor >= swept_from * 1000 && cursor <= swept_to * 1000,
        "and the advance is still the fetch window's own open time, taken ONCE \
         before the first page rather than re-read per page (between \
         {swept_from} s and {swept_to} s); got {cursor} ms"
    );
    assert!(
        cursor > oldest_secs * 1000,
        "which is above the retrieved tail ({oldest_secs} s) — legitimate only \
         because that tail really was retrieved; got {cursor} ms"
    );
}

/// A relay that proposes an ANCIENT paging boundary must not curtail the chase
/// of the relay that is still visibly holding a backlog.
///
/// The next page's `until` is the one remotely-written number steering a
/// request: it is the oldest `created_at` of a page the relay itself cut short.
/// A relay whose full page bottoms out at an ancient timestamp therefore
/// proposes an ancient `until`, at which the following page legitimately comes
/// back SHORT. If "short page ⇒ window complete" were the rule, the sweep would
/// conclude the window was complete and advance the cursor past a backlog it
/// never retrieved — the silent loss Rule 12 forbids, re-introduced through the
/// termination condition.
///
/// The boundary is therefore the MAXIMUM across the relays that truncated, so
/// the chain descends only as fast as the slowest-draining relay allows. This
/// stages exactly that: a poisoned relay holding one page that bottoms out a day
/// ago, alongside an honest relay holding a page and a half of recent events.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_ancient_paging_boundary_cannot_curtail_another_relays_backlog() {
    let poisoned = SeededRelay::run().await;
    let honest = SeededRelay::run().await;
    let relay_mgr = RelayManager::new();
    let fx = build_two_member_circle(vec![poisoned.url.clone(), honest.url.clone()]).await;
    let h = hex::encode(fx.nostr_group_id);

    let now = chrono::Utc::now().timestamp();
    // The honest relay: more than one page of recent events, so its own page
    // comes back truncated with a RECENT bottom.
    let honest_backlog = PAGE_LIMIT + 88;
    let honest_window = unparseable_window(&h, honest_backlog, now - 60);
    honest.seed(&honest_window).await;

    // The poisoned relay: EXACTLY one page, so all of it is served at once and
    // its bottom is the ancient event — a full page proposing a boundary 23
    // hours below where the honest relay's tail actually starts.
    let mut poisoned_window = unparseable_window(&h, PAGE_LIMIT - 1, now - 30);
    poisoned_window.push(
        unparseable_window(&h, 1, now - 23 * 3600)
            .pop()
            .expect("the ancient event"),
    );
    assert_eq!(poisoned_window.len(), PAGE_LIMIT);
    poisoned.seed(&poisoned_window).await;

    let out = run_catchup_all_circles(&fx.alice, &relay_mgr, &fx.alice_keys.public_key(), 60).await;

    assert_eq!(
        out.events_rejected_pre_auth,
        honest_backlog + PAGE_LIMIT,
        "the honest relay's oldest {} events must still be retrieved: a paging \
         boundary is a claim about ONE relay's page, and the ancient one must \
         not be allowed to end the chase for the other",
        honest_backlog - PAGE_LIMIT,
    );
    assert_eq!(out.events_deferred, 0);
    assert_eq!(
        out.windows_truncated, 0,
        "both relays did drain, so the window really is complete here — the \
         defect this guards is a window called complete while short, not a \
         window needlessly held"
    );
    // The advance is what makes the count above load-bearing rather than
    // cosmetic: this sweep DOES move the cursor past the honest relay's tail,
    // and that is legitimate only because the tail was actually retrieved. Under
    // a boundary that followed the ancient proposal, the very same advance would
    // have happened over 88 events nobody ever fetched.
    assert!(
        fx.alice_cursor().is_some(),
        "a completed window advances, so the count above is the only thing \
         standing between this advance and a silent drop"
    );
}

/// A relay that CLAMPS our `limit` must not be able to hide its own backlog.
///
/// Truncation is detected as "the relay returned as many events as we asked
/// for", and NIP-11 lets a relay clamp a larger `limit` down to its
/// `limitation.max_limit` instead of rejecting the REQ. strfry ships that cap at
/// 500 — and all three of Haven's default relays run strfry, as does the E2E
/// harness. Ask for more than the cap and every page comes back one short of our
/// own limit however much backlog remains: the signal never fires, the chase
/// never starts, and the cursor sails over the tail. That is the Rule-12 silent
/// drop arrived at through the REQUEST rather than the response, and it is
/// invisible to every other test here, all of which run against an unclamped
/// relay.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_relay_that_clamps_our_limit_still_gets_fully_drained() {
    // Exactly the strfry default, and exactly `tooling/e2e/strfry.conf`.
    let relay = SeededRelay::with_cap(Some(500)).await;
    let relay_mgr = RelayManager::new();
    let fx = build_two_member_circle(vec![relay.url.clone()]).await;

    let backlog = PAGE_LIMIT + 100;
    let window = unparseable_window(
        &hex::encode(fx.nostr_group_id),
        backlog,
        chrono::Utc::now().timestamp() - 60,
    );
    let oldest_secs = i64::try_from(window[0].created_at.as_secs()).expect("created_at fits");
    relay.seed(&window).await;

    let out = run_catchup_all_circles(&fx.alice, &relay_mgr, &fx.alice_keys.public_key(), 60).await;

    assert_eq!(
        out.events_rejected_pre_auth, backlog,
        "a page that came back at the relay's cap is a page that was cut short, \
         and the sweep must chase it like any other — asking for more than a \
         relay serves cannot be allowed to turn every truncated page into a \
         'complete' one"
    );
    assert!(
        fx.alice_cursor()
            .is_some_and(|cursor| cursor > oldest_secs * 1000),
        "and only then may the cursor pass the tail at {oldest_secs} s; got {:?}",
        fx.alice_cursor(),
    );
}

/// A relay that serves the FIRST page and then fails to answer the second must
/// not be read as drained.
///
/// The blocking hole this closes needs no attacker: `fetch_events_per_relay`
/// reports a post-handshake fetch failure (a read that errors, or the SDK's
/// 10 s fetch timeout elapsing) as `responded == true` with zero events, which
/// is byte-for-byte what a relay holding nothing looks like. Mid-chase that is
/// catastrophic in a way it is not on the first page: page 1 already PROVED the
/// relay has a tail below the boundary, so treating page 2's silence as "nothing
/// left" advances the cursor over a backlog we have local proof exists, and the
/// next sweep's floor sits only `GROUP_RESUBSCRIBE_BUFFER_SECS` below the
/// cursor — a stranded COMMIT there breaks the epoch chain for good.
///
/// A `QueryPolicy` that refuses every bounded-below REQ stages exactly that: the
/// first page (which asks only for `until = window open`) is served in full, and
/// the chase's second page (`until = boundary`, strictly older) is closed
/// unanswered.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_chase_page_that_is_never_served_holds_the_cursor() {
    /// Refuses any REQ whose `until` is older than `serve_above`, i.e. every
    /// page of a backward chase but not the first.
    #[derive(Debug)]
    struct RefuseChasePages {
        serve_above: Timestamp,
    }

    impl QueryPolicy for RefuseChasePages {
        fn admit_query<'a>(
            &'a self,
            query: &'a nostr::Filter,
            _addr: &'a std::net::SocketAddr,
        ) -> BoxedFuture<'a, PolicyResult> {
            Box::pin(async move {
                match query.until {
                    Some(until) if until < self.serve_above => {
                        PolicyResult::Reject("chase page withheld".to_string())
                    }
                    _ => PolicyResult::Accept,
                }
            })
        }
    }

    let now = chrono::Utc::now().timestamp();
    let newest_secs = now - 60;
    let relay = SeededRelay::from_builder(RelayBuilder::default().query_policy(RefuseChasePages {
        // Above every seeded event, so only the un-chased first page passes.
        serve_above: Timestamp::from(u64::try_from(newest_secs).unwrap()),
    }))
    .await;
    let relay_mgr = RelayManager::new();
    let fx = build_two_member_circle(vec![relay.url.clone()]).await;

    let backlog = PAGE_LIMIT + 88;
    let window = unparseable_window(&hex::encode(fx.nostr_group_id), backlog, newest_secs);
    relay.seed(&window).await;

    let out = run_catchup_all_circles(&fx.alice, &relay_mgr, &fx.alice_keys.public_key(), 60).await;

    assert_eq!(
        out.events_rejected_pre_auth, PAGE_LIMIT,
        "precondition: the first page must have been served in full and the \
         chase page not at all — otherwise this asserts nothing about a failed \
         read"
    );
    assert_eq!(
        out.windows_truncated, 1,
        "a chase that produced nothing from the relay it was draining is an \
         unfinished window, not a finished one"
    );
    assert_eq!(
        fx.alice_cursor(),
        None,
        "and the cursor must not move: the {} events below the boundary are \
         reachable only while `since` stays below them",
        backlog - PAGE_LIMIT,
    );
}

/// Future-dated events must not be able to freeze a circle's cursor.
///
/// A circle's `#h` is its PUBLIC `nostr_group_id`, so any observer can mint
/// `kind:445`s at a `created_at` of its choosing. Were the first page unbounded
/// above, a page-full of future-dated forgeries would fill it, put the paging
/// boundary at or above the band's ceiling, and halt the chase on arrival — the
/// cursor frozen for the price of one publish, and re-frozen on every wake for
/// as long as the relay serves them. Bounding every page by the window's own
/// open time puts them outside the request entirely.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_flood_of_future_dated_events_cannot_freeze_the_cursor() {
    let relay = SeededRelay::run().await;
    let relay_mgr = RelayManager::new();
    let fx = build_two_member_circle(vec![relay.url.clone()]).await;
    let h = hex::encode(fx.nostr_group_id);

    let now = chrono::Utc::now().timestamp();
    // A full page of forgeries dated an hour ahead, plus three genuine events in
    // the window that must still be delivered and applied.
    relay
        .seed(&unparseable_window(&h, PAGE_LIMIT, now + 3600))
        .await;
    relay.seed(&unparseable_window(&h, 3, now - 120)).await;

    let swept_from = chrono::Utc::now().timestamp();
    let out = run_catchup_all_circles(&fx.alice, &relay_mgr, &fx.alice_keys.public_key(), 60).await;
    let swept_to = chrono::Utc::now().timestamp();

    assert_eq!(
        out.events_rejected_pre_auth, 3,
        "only the three events inside the window may be fetched; the future-\
         dated page is outside the band the anchor can vouch for"
    );
    assert_eq!(
        out.windows_truncated, 0,
        "and no page was truncated, so nothing freezes"
    );
    let cursor = fx.alice_cursor().expect("the window still advances");
    assert!(
        cursor >= swept_from * 1000 && cursor <= swept_to * 1000,
        "the cursor advances to the window's own open time (between \
         {swept_from} s and {swept_to} s) rather than stalling at the forgeries \
         or being dragged up to them; got {cursor} ms"
    );
}

/// A window the pager CANNOT finish must terminate the sweep and hold the
/// cursor — never quietly report itself as caught up.
///
/// A full page of events all sharing one `created_at` is the shape that breaks
/// the `until` chain: the next page can only be requested at that same second,
/// and a relay is free to answer it with the same events forever. Real or
/// hostile, the answer must be the same — stop asking, keep what was fetched,
/// and leave the cursor exactly where it was so the next sweep re-opens the same
/// window rather than skipping over it.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_window_the_pager_cannot_finish_holds_the_cursor_and_says_so() {
    let relay = SeededRelay::run().await;
    let relay_mgr = RelayManager::new();
    let fx = build_two_member_circle(vec![relay.url.clone()]).await;

    // One second, more than one page of events in it.
    let pileup = PAGE_LIMIT + 88;
    let at_secs = chrono::Utc::now().timestamp() - 300;
    let window = unparseable_window(&hex::encode(fx.nostr_group_id), pileup, at_secs)
        .into_iter()
        .map(|ev| {
            EventBuilder::new(ev.kind, ev.content.clone())
                .tags(ev.tags.to_vec())
                .custom_created_at(Timestamp::from(u64::try_from(at_secs).unwrap()))
                .sign_with_keys(&Keys::generate())
                .unwrap()
        })
        .collect::<Vec<_>>();
    relay.seed(&window).await;

    assert_eq!(
        fx.alice_cursor(),
        None,
        "precondition: the cursor is unseeded, so a Some() below would be this \
         sweep's doing"
    );

    // Terminating at all is half the property: an `until` chain that trusted the
    // relay to descend would re-request this same second forever.
    let out = run_catchup_all_circles(&fx.alice, &relay_mgr, &fx.alice_keys.public_key(), 60).await;

    assert_eq!(
        out.windows_truncated, 1,
        "an unfinished chase must be REPORTED as unfinished, not rounded down \
         to a clean sweep"
    );
    assert!(
        out.events_rejected_pre_auth >= PAGE_LIMIT,
        "ingest still runs on what was fetched, so the engine makes progress \
         even on a window that cannot complete; got {}",
        out.events_rejected_pre_auth,
    );
    assert!(
        out.events_rejected_pre_auth < pileup,
        "precondition: this window must really be unfinishable — if the whole \
         pileup came back, the assertion above proves nothing about holding"
    );
    assert_eq!(
        fx.alice_cursor(),
        None,
        "and the cursor must not move one millisecond: the un-retrieved \
         remainder is only reachable while `since` still sits below it"
    );
}

/// A relay that caps its `limit` BELOW our page size must not be able to hide a
/// backlog either.
///
/// `a_relay_that_clamps_our_limit_still_gets_fully_drained` above covers the cap
/// we ask AT (strfry's 500): the page comes back at our own limit, so "the relay
/// returned as many events as I asked for" still fires. One relay configured a
/// single step lower defeats that count outright — every page arrives short of
/// our limit no matter how much is left behind it, so the chase never starts and
/// the cursor sails over the tail. That is the same Rule-12 silent drop, and
/// nothing about 500 makes it special: the sweep must not be relying on knowing
/// any relay's cap.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_relay_that_caps_below_our_page_size_still_gets_fully_drained() {
    // Well under `PAGE_LIMIT`, so no page can ever reach our own limit.
    let relay = SeededRelay::with_cap(Some(100)).await;
    let relay_mgr = RelayManager::new();
    let fx = build_two_member_circle(vec![relay.url.clone()]).await;

    let backlog = 250;
    let window = unparseable_window(
        &hex::encode(fx.nostr_group_id),
        backlog,
        chrono::Utc::now().timestamp() - 60,
    );
    let oldest_secs = i64::try_from(window[0].created_at.as_secs()).expect("created_at fits");
    relay.seed(&window).await;

    let out = run_catchup_all_circles(&fx.alice, &relay_mgr, &fx.alice_keys.public_key(), 60).await;

    assert_eq!(
        out.events_rejected_pre_auth, backlog,
        "every event must be retrieved from a relay that serves only 100 at a \
         time: a page that came back SHORT of our limit while the relay still \
         held more is indistinguishable from a drained one by count alone, so \
         the chase has to be driven by what the pages still CONTRIBUTE"
    );
    assert_eq!(
        out.windows_truncated, 0,
        "and the chase must still finish, or the fix would have traded a silent \
         drop for a permanently frozen cursor"
    );
    assert!(
        fx.alice_cursor()
            .is_some_and(|cursor| cursor > oldest_secs * 1000),
        "only a drained window may pass the tail at {oldest_secs} s; got {:?}",
        fx.alice_cursor(),
    );
}

/// A delivery the fetch timeout cut off must not be read as "the relay had
/// nothing more".
///
/// A relay that hands over part of a page and then goes quiet is reachable, and
/// what arrives is a page — a shorter one, byte-for-byte indistinguishable from
/// a complete short answer. Read as an ANSWER, it licenses the advance and the
/// cursor sails over the rest of what that relay is still visibly holding, with
/// the next sweep's floor sitting above it for good.
///
/// It is not an answer, because the relay never said it had finished: only its
/// NIP-01 `EOSE` says that, and this one never sends one. A SECOND, healthy
/// relay answers the same window in full, so "at least one relay finished" is
/// satisfied and cannot be what holds the window — the hold is attributable to
/// the cut-off delivery and to nothing else.
///
/// An endpoint that forwards every `EVENT` and swallows the `EOSE` stages
/// exactly that, over a socket that never breaks. It costs this test the fetch
/// timeout in wall-clock, which is the price of driving the real primitive
/// rather than asserting against a mock of it.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_fetch_cut_off_by_its_own_timeout_is_not_read_as_a_complete_window() {
    let honest = SeededRelay::run().await;
    let backing = SeededRelay::run().await;
    let stalled = TamperedRelay::in_front_of(&backing.url, Tamper::SwallowEose).await;
    let relay_mgr = RelayManager::new();
    let fx = build_two_member_circle(vec![honest.url.clone(), stalled.url.clone()]).await;
    let h = hex::encode(fx.nostr_group_id);

    // Disjoint stores at the SAME timestamps: read in full, this window is
    // complete, which is what makes the hold below the cut-off's doing.
    let each = 3;
    let newest_secs = chrono::Utc::now().timestamp() - 60;
    honest
        .seed(&unparseable_window(&h, each, newest_secs))
        .await;
    backing
        .seed(&unparseable_window(&h, each, newest_secs))
        .await;

    let out = run_catchup_all_circles(&fx.alice, &relay_mgr, &fx.alice_keys.public_key(), 60).await;

    assert_eq!(
        out.events_rejected_pre_auth,
        each * 2,
        "precondition: BOTH relays handed over their whole store, so this is a \
         cut-off DELIVERY and not a relay that answered nothing"
    );
    assert!(
        out.relay_errors >= 1,
        "a relay that never finished answering is a failed read, tallied like \
         one — being reachable is not the same as having answered"
    );
    assert_eq!(
        out.windows_truncated, 1,
        "a fetch that ran out its own timeout retrieved an unknown fraction of \
         what the relay holds, so the window is INCOMPLETE — the one thing it \
         must not be is silently complete"
    );
    assert_eq!(
        fx.alice_cursor(),
        None,
        "and the cursor must not move: whatever that relay had not sent when the \
         timeout expired is reachable only while `since` stays below it"
    );
}

/// THE INVARIANT, at the primitive: a page is `drained` only when the relay
/// itself said it had served everything it stores for that REQ.
///
/// One relay, one store, one filter, reached two ways — straight, and through an
/// endpoint that ends the connection on the relay's `EOSE` frame instead of
/// forwarding it. Every `EVENT` is delivered identically in both runs, so the
/// two pages are the same page; the ONLY difference on the wire is whether the
/// relay's "that was all of it" arrived. Anything that reads a page's CONTENT to
/// decide whether the relay is drained cannot tell these two apart, which is
/// exactly why the flag has to come from somewhere else.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_short_page_is_only_drained_when_the_relay_said_so() {
    let relay = SeededRelay::run().await;
    let cut = TamperedRelay::in_front_of(&relay.url, Tamper::CutAtEose { forward_first: 0 }).await;
    let h = hex::encode([0x7Au8; 32]);
    let window = unparseable_window(&h, 4, chrono::Utc::now().timestamp() - 60);
    relay.seed(&window).await;

    let filter = nostr::Filter::new()
        .kind(Kind::Custom(445))
        .custom_tag(nostr::SingleLetterTag::lowercase(nostr::Alphabet::H), h)
        .limit(500);
    let relay_mgr = RelayManager::new();

    let straight = relay_mgr
        .fetch_events_per_relay(filter.clone(), std::slice::from_ref(&relay.url))
        .await
        .expect("the per-relay fetch never fails as a whole");
    let severed = relay_mgr
        .fetch_events_per_relay(filter, std::slice::from_ref(&cut.url))
        .await
        .expect("the per-relay fetch never fails as a whole");

    let ids = |outcomes: &[haven_core::relay::RelayFetchOutcome]| {
        let mut ids: Vec<_> = outcomes
            .iter()
            .flat_map(|o| o.events.iter().map(|e| e.id))
            .collect();
        ids.sort_unstable();
        ids
    };
    let mut expected: Vec<_> = window.iter().map(|e| e.id).collect();
    expected.sort_unstable();
    assert_eq!(
        ids(&straight),
        expected,
        "precondition: the relay really does serve the whole window"
    );
    assert_eq!(
        ids(&severed),
        expected,
        "precondition: cutting at the EOSE must not cost a single EVENT — if it \
         did, the two pages would differ in CONTENT and the assertion below \
         would be provable the easy way"
    );

    assert!(
        straight[0].responded && severed[0].responded,
        "both reachable"
    );
    assert!(
        straight[0].drained,
        "the relay signalled end-of-stored-events, which is the only thing that \
         makes a page the whole of what a relay holds"
    );
    assert!(
        !severed[0].drained,
        "and it did not reach us here, so this identical page is a PREFIX of an \
         unknown whole — the tail of which a cursor advance would step over \
         permanently"
    );
}

/// A relay that sends MORE than the REQ asked for is throttled at the REQ's own
/// limit, and the throttled page is not mistaken for a finished one
/// (Security Rule 12).
///
/// Reading a relay's own message stream is a place an unbounded intake could
/// appear: NIP-01 says a relay must respect `limit`, and nothing but the client
/// makes it. An endpoint that sends every `EVENT` twice stages a relay that does
/// not, and the read must stop at the limit rather than growing with whatever a
/// relay feels like sending to a device on a background wake.
///
/// Stopping is throttling and NOT a drop: the read ends short of the relay's
/// `EOSE`, so the page is reported unfinished, the cursor holds, and the next
/// sweep asks for the same window again. Rule 12's other half — never silently
/// discard legitimate backlog — is what that buys.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_relay_that_overruns_the_req_limit_is_capped_and_not_called_finished() {
    let relay = SeededRelay::run().await;
    let doubled = TamperedRelay::in_front_of(&relay.url, Tamper::DoubleEveryEvent).await;
    let h = hex::encode([0x6Cu8; 32]);
    relay
        .seed(&unparseable_window(
            &h,
            6,
            chrono::Utc::now().timestamp() - 60,
        ))
        .await;

    let asked_for = 4;
    let filter = nostr::Filter::new()
        .kind(Kind::Custom(445))
        .custom_tag(nostr::SingleLetterTag::lowercase(nostr::Alphabet::H), h)
        .limit(asked_for);
    let relay_mgr = RelayManager::new();
    let overrun = relay_mgr
        .fetch_events_per_relay(filter.clone(), std::slice::from_ref(&doubled.url))
        .await
        .expect("the per-relay fetch never fails as a whole")
        .remove(0);

    // The cap counts ARRIVALS, not events kept, and this relay sends each event
    // twice — so the exact boundary is half the limit, reached on the arrival
    // that would have been the (limit + 1)th. Asserting the boundary and not
    // merely "fewer than we asked for" is what makes an off-by-one in the cap
    // visible: one extra admitted arrival is one more event here.
    assert_eq!(
        overrun.events.len(),
        asked_for / 2,
        "the read must stop on the arrival that spends the REQ's own limit, \
         however much the relay keeps sending"
    );
    assert!(
        !overrun.drained,
        "and a page cut short by our own cap is not the relay's whole answer — \
         calling it one would advance a cursor over the part we refused to take"
    );

    // The control: the same relay behaving, so the assertions above are about
    // the overrun and not about the cap firing on every read.
    let behaving = relay_mgr
        .fetch_events_per_relay(filter, std::slice::from_ref(&relay.url))
        .await
        .expect("the per-relay fetch never fails as a whole")
        .remove(0);
    assert_eq!(behaving.events.len(), asked_for);
    assert!(behaving.drained);
}

/// An `EOSE` for SOMEBODY ELSE'S subscription does not end this read.
///
/// One pooled connection carries every REQ this device issues, and its
/// notification stream carries every relay message on it — including the `EOSE`
/// for a REQ that ended early and whose auto-close handler is still running, so
/// this needs no attacker and no exotic relay. Read as our own, it ends the read
/// wherever it lands: the page comes back short and, worse, comes back DRAINED
/// — the one flag that licenses a cursor to advance over whatever had not
/// arrived yet.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_eose_for_another_subscription_does_not_finish_this_read() {
    let relay = SeededRelay::run().await;
    let confusing =
        TamperedRelay::in_front_of(&relay.url, Tamper::EoseForAnotherSubscription).await;
    let h = hex::encode([0x4Eu8; 32]);
    let window = unparseable_window(&h, 4, chrono::Utc::now().timestamp() - 60);
    relay.seed(&window).await;

    let filter = nostr::Filter::new()
        .kind(Kind::Custom(445))
        .custom_tag(nostr::SingleLetterTag::lowercase(nostr::Alphabet::H), h)
        .limit(500);
    let outcome = RelayManager::new()
        .fetch_events_per_relay(filter, std::slice::from_ref(&confusing.url))
        .await
        .expect("the per-relay fetch never fails as a whole")
        .remove(0);

    assert_eq!(
        outcome.events.len(),
        window.len(),
        "the read must keep going: the whole page arrived AFTER the stray \
         end-of-stored-events, so a read that stopped at it would have thrown \
         away every event this relay served"
    );
    assert!(
        outcome.drained,
        "and the relay's OWN end-of-stored-events is what finishes it, which \
         arrived last"
    );
}

/// A page comes back in an order this device chose, whatever order the relay
/// served it in.
///
/// NIP-01 fixes no delivery order, so arrival order is the relay's to pick — and
/// a caller that resolves an ambiguity positionally (the `KeyPackage` probe
/// takes the FIRST entry for a `d` slot) would then be letting the relay pick
/// which of two events a maintenance decision reads. One relay, one store, two
/// deliveries: straight, and through an endpoint that releases the same page
/// backwards.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_page_is_ordered_by_this_device_and_not_by_the_relay() {
    let relay = SeededRelay::run().await;
    let backwards = TamperedRelay::in_front_of(&relay.url, Tamper::ReverseEveryPage).await;
    let h = hex::encode([0x5Du8; 32]);
    relay
        .seed(&unparseable_window(
            &h,
            5,
            chrono::Utc::now().timestamp() - 60,
        ))
        .await;

    let filter = nostr::Filter::new()
        .kind(Kind::Custom(445))
        .custom_tag(nostr::SingleLetterTag::lowercase(nostr::Alphabet::H), h)
        .limit(500);
    let relay_mgr = RelayManager::new();
    let straight = relay_mgr
        .fetch_events_per_relay(filter.clone(), std::slice::from_ref(&relay.url))
        .await
        .expect("the per-relay fetch never fails as a whole")
        .remove(0);
    let reversed = relay_mgr
        .fetch_events_per_relay(filter, std::slice::from_ref(&backwards.url))
        .await
        .expect("the per-relay fetch never fails as a whole")
        .remove(0);

    let order = |o: &haven_core::relay::RelayFetchOutcome| {
        o.events
            .iter()
            .map(|e| (e.created_at.as_secs(), e.id))
            .collect::<Vec<_>>()
    };
    let mut newest_first = order(&straight);
    assert!(
        newest_first.len() > 1,
        "precondition: a one-event page has no order to get wrong"
    );
    newest_first.sort_by(|a, b| b.cmp(a));
    assert_eq!(
        order(&straight),
        newest_first,
        "a page is handed back newest first, by created_at and then by id"
    );
    assert_eq!(
        order(&reversed),
        newest_first,
        "...and the relay reversing its delivery changes nothing, because the \
         order is not the relay's to choose"
    );
}

/// A read that gives up before the relay finishes CLOSES its own REQ.
///
/// The auto-closing subscription's handler is a separate task with its own
/// receiver: it learns nothing from this read stopping, and closes only when its
/// own 10-second timeout expires. Until then the relay keeps streaming a REQ
/// nobody is reading into a bounded broadcast channel the NEXT page's read
/// shares — which is how that read gets pushed into `Lagged`, reported
/// unfinished, and made to hold the very cursor it was fetching for. Paid in
/// battery and data on a background wake, and self-inflicted.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_read_that_gives_up_early_closes_its_own_req() {
    let relay = SeededRelay::run().await;
    let doubled = TamperedRelay::in_front_of(&relay.url, Tamper::FloodWithoutFinishing).await;
    let h = hex::encode([0x3Fu8; 32]);
    relay
        .seed(&unparseable_window(
            &h,
            6,
            chrono::Utc::now().timestamp() - 60,
        ))
        .await;

    let filter = nostr::Filter::new()
        .kind(Kind::Custom(445))
        .custom_tag(nostr::SingleLetterTag::lowercase(nostr::Alphabet::H), h)
        .limit(4);
    // Bound to a variable on purpose: dropping the manager tears the pool down,
    // and a `CLOSE` still queued on the writer would go with it.
    let relay_mgr = RelayManager::new();
    let capped = relay_mgr
        .fetch_events_per_relay(filter, std::slice::from_ref(&doubled.url))
        .await
        .expect("the per-relay fetch never fails as a whole")
        .remove(0);
    assert!(
        !capped.drained,
        "precondition: this read really did give up before the relay finished"
    );

    assert!(
        doubled.await_closes(1).await >= 1,
        "a REQ this device stopped reading must be closed by this device: \
         nothing else will until the subscription's own timeout, and the relay \
         streams into a channel nobody is draining for as long as it is open"
    );
}

/// The same cut, driven through the real sweep, on the round that DECIDES: a
/// confirming page nobody said was finished must hold the circle's cursor, where
/// the identical page WITH its `EOSE` advances it.
///
/// This is the loss the flag exists to prevent, stated end to end, and the
/// confirming round is where it bites hardest. A chase ends when a round brings
/// back nothing new — so the page that licenses the advance is, by construction,
/// a page of events we ALREADY HOLD, and a relay that died on the way to saying
/// "there is nothing below this" serves a byte-identical one. Every other guard
/// in the sweep is looking at content and sees no difference. It needs no
/// attacker either: a dropped radio, a relay restart, an overloaded upstream.
///
/// Both circles run against the SAME relay process holding the SAME events, and
/// the cut lands on the SAME round of the SAME chase, so the only variable left
/// is whether that round's `EOSE` arrived.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_confirming_page_cut_off_before_the_relay_finished_holds_the_cursor() {
    let relay = SeededRelay::run().await;
    // Round 1 (the page) is confirmed; round 2 (the confirmation) is cut.
    let cut = TamperedRelay::in_front_of(&relay.url, Tamper::CutAtEose { forward_first: 1 }).await;
    let relay_mgr = RelayManager::new();

    let severed_fx = build_two_member_circle(vec![cut.url.clone()]).await;
    let whole_fx = build_two_member_circle(vec![relay.url.clone()]).await;
    let backlog = 4;
    let newest = chrono::Utc::now().timestamp() - 60;
    for ngid in [severed_fx.nostr_group_id, whole_fx.nostr_group_id] {
        relay
            .seed(&unparseable_window(&hex::encode(ngid), backlog, newest))
            .await;
    }

    let severed = run_catchup_all_circles(
        &severed_fx.alice,
        &relay_mgr,
        &severed_fx.alice_keys.public_key(),
        60,
    )
    .await;
    assert_eq!(
        severed.events_rejected_pre_auth, backlog,
        "precondition: the whole window really was retrieved, so the cut landed \
         on the CONFIRMING round and the sweep held for that reason alone"
    );
    assert_eq!(
        severed.windows_truncated, 1,
        "the round that would have completed this window never finished, so the \
         sweep must report that it could not establish it drained the circle"
    );
    assert_eq!(
        severed_fx.alice_cursor(),
        None,
        "and the cursor must hold: whatever the relay had not sent when the \
         connection died is reachable only while `since` stays below it"
    );

    // The control, without which the assertions above would pass just as well
    // for an implementation that never advances anything.
    let opened_at = chrono::Utc::now().timestamp();
    let whole = run_catchup_all_circles(
        &whole_fx.alice,
        &relay_mgr,
        &whole_fx.alice_keys.public_key(),
        60,
    )
    .await;
    let closed_at = chrono::Utc::now().timestamp();
    assert_eq!(
        whole.events_rejected_pre_auth, backlog,
        "the same window, over an uncut connection"
    );
    assert_eq!(whole.windows_truncated, 0);
    let advanced = whole_fx.alice_cursor().expect("the whole window advances");
    assert!(
        (opened_at * 1000..=closed_at * 1000).contains(&advanced),
        "and it advances to the window's own open time, not to any event: got \
         {advanced} ms outside [{opened_at}, {closed_at}] s",
    );
}

/// A relay that DID finish answering cannot vouch for one that did not.
///
/// The gap between the sweep's two rules, which this is the only test to sit in.
/// A healthy relay finishes every round here, so "at least one relay answered"
/// is satisfied and cannot be what holds the window; only the OTHER relay's
/// unfinished confirming page can. A circle's relay list is user-editable and
/// most circles carry several, so "one good relay makes the round good" would
/// let a single flaky entry silently cost the circle whatever only it held.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_relay_that_finished_cannot_vouch_for_one_that_was_cut_off() {
    let honest = SeededRelay::run().await;
    let flaky = SeededRelay::run().await;
    let cut = TamperedRelay::in_front_of(&flaky.url, Tamper::CutAtEose { forward_first: 1 }).await;
    let relay_mgr = RelayManager::new();
    let fx = build_two_member_circle(vec![honest.url.clone(), cut.url.clone()]).await;
    let h = hex::encode(fx.nostr_group_id);

    // Disjoint stores at the SAME timestamps, so both relays bottom out at the
    // same second and the chase's confirming round asks both of them the same
    // question. Read in full, that round completes the window; that is what
    // makes the hold below attributable to the cut and to nothing else.
    let newest = chrono::Utc::now().timestamp() - 60;
    let each = 3;
    honest.seed(&unparseable_window(&h, each, newest)).await;
    flaky.seed(&unparseable_window(&h, each, newest)).await;

    let out = run_catchup_all_circles(&fx.alice, &relay_mgr, &fx.alice_keys.public_key(), 60).await;

    assert_eq!(
        out.events_rejected_pre_auth,
        each * 2,
        "precondition: BOTH relays handed over their whole store, so the window \
         is held on the strength of one missing end-of-stored-events alone"
    );
    assert_eq!(out.windows_truncated, 1);
    assert_eq!(
        fx.alice_cursor(),
        None,
        "one relay finishing says nothing about what the other still had to send"
    );
}

/// A relay whose delivery is cut off on EVERY sweep holds the cursor for the
/// sweep it happened in — and must not hold it for ever.
///
/// The freeze needs neither an adversary nor an exotic relay: a page that never
/// reaches its `EOSE` is what this device's own intake cap produces against a
/// relay that overruns a REQ's `limit`, what a relay behind a lossy link
/// produces, and what one entry in a user-editable relay list produces by
/// omitting six bytes. The evidence then repeats on the next sweep, and the one
/// after: the cursor never moves, the window only grows, and the circle is out
/// of service permanently — strictly worse than the residual the hold was
/// protecting, and free to cause.
///
/// So the hold is a delay: after enough consecutive sweeps held on nothing but
/// that evidence, the offending relay is treated as UNREACHED, which is the
/// treatment a relay that answered nothing at all already gets. Both halves are
/// asserted here, because either alone is satisfied by a broken implementation
/// — one by a sweep that never holds, the other by a sweep that never advances.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_relay_cut_off_on_every_sweep_holds_the_cursor_but_not_for_ever() {
    let honest = SeededRelay::run().await;
    let backing = SeededRelay::run().await;
    // Sends every EVENT twice, so it answers with more than the REQ's own limit
    // and trips THIS device's intake cap. The read then stops short of the
    // relay's `EOSE` — a cut-off delivery with no adversary, no dropped socket,
    // and nothing that varies between sweeps.
    let broken = TamperedRelay::in_front_of(&backing.url, Tamper::DoubleEveryEvent).await;
    let relay_mgr = RelayManager::new();
    let fx = build_two_member_circle(vec![honest.url.clone(), broken.url.clone()]).await;
    let h = hex::encode(fx.nostr_group_id);

    // Dated inside the resubscribe buffer, so an advanced cursor still asks for
    // them: the cut-off recurs on every sweep instead of ageing out of the
    // window, which is what makes "not for ever" a property of the rule rather
    // than of the calendar. Deep enough that DOUBLING the page overruns a
    // 500-event REQ; if that page limit ever grows, the first assertion below
    // fails loudly rather than quietly staging nothing.
    let newest = chrono::Utc::now().timestamp() - 5;
    honest.seed(&unparseable_window(&h, 3, newest)).await;
    backing.seed(&stacked_window(&h, 5, 51, newest)).await;

    // The wake budget a background catch-up actually gets: a tolerance that only
    // works when a sweep may run for a minute would not work at all, because one
    // relay that never answers costs a fetch timeout per round.
    let mut advanced_on: Option<usize> = None;
    let mut still_unfinished = false;
    for sweep in 1..=6 {
        let out =
            run_catchup_all_circles(&fx.alice, &relay_mgr, &fx.alice_keys.public_key(), 25).await;
        if sweep == 1 {
            assert_eq!(
                fx.alice_cursor(),
                None,
                "a page nobody said was finished is a prefix of an unknown \
                 whole, so the sweep it arrived in must hold: whatever that \
                 relay had not sent is reachable only while `since` stays below \
                 it"
            );
        }
        if advanced_on.is_none() && fx.alice_cursor().is_some() {
            advanced_on = Some(sweep);
            // The relay is still being cut off on the sweep that advanced, so
            // the advance is the tolerance running out and not the relay
            // quietly healing.
            still_unfinished = out.relay_errors >= 1;
        }
    }

    let advanced_on = advanced_on.unwrap_or_else(|| {
        panic!(
            "six sweeps and the cursor never moved: one relay that omits its \
             end-of-stored-events has frozen this circle, and every later sweep \
             will re-fetch a window that only grows"
        )
    });
    assert!(
        advanced_on > 1,
        "...but not on the first sweep either, or the hold is not real"
    );
    assert!(
        still_unfinished,
        "precondition: that relay had still not finished a read when the sweep \
         advanced, so the advance is the bounded tolerance and not the fixture \
         healing itself"
    );
}

/// A relay that answers only a LATER page of the chase must not be counted
/// towards completeness.
///
/// Every page but the first is bounded above by the previous page's boundary, so
/// a relay that produced nothing for the first page and then answers a chase
/// page was never asked for anything ABOVE that boundary. Reading its short
/// answer as "drained" advances the cursor over the part of its store nobody
/// requested — reachable inside a single chain, and needing no attacker: one
/// relay slow to answer the first REQ is enough.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_relay_that_answers_only_a_later_page_cannot_complete_the_window() {
    /// Refuses any REQ whose `until` is at or above `serve_below`: the window's
    /// unbounded-looking FIRST page, and nothing beneath it.
    #[derive(Debug)]
    struct RefuseTheFirstPage {
        serve_below: Timestamp,
    }

    impl QueryPolicy for RefuseTheFirstPage {
        fn admit_query<'a>(
            &'a self,
            query: &'a nostr::Filter,
            _addr: &'a std::net::SocketAddr,
        ) -> BoxedFuture<'a, PolicyResult> {
            Box::pin(async move {
                match query.until {
                    Some(until) if until < self.serve_below => PolicyResult::Accept,
                    _ => PolicyResult::Reject("first page withheld".to_string()),
                }
            })
        }
    }

    let now = chrono::Utc::now().timestamp();
    let honest = SeededRelay::run().await;
    // Serves anything the chase asks for, nothing the opening page does.
    let late =
        SeededRelay::from_builder(RelayBuilder::default().query_policy(RefuseTheFirstPage {
            serve_below: Timestamp::from(u64::try_from(now - 30).unwrap()),
        }))
        .await;
    let relay_mgr = RelayManager::new();
    let fx = build_two_member_circle(vec![honest.url.clone(), late.url.clone()]).await;
    let h = hex::encode(fx.nostr_group_id);

    // The honest relay holds a page and a half, so the first page is truncated
    // and the chase's boundary lands at its bottom, `PAGE_LIMIT - 1` s below its
    // newest event.
    let honest_backlog = PAGE_LIMIT + 88;
    let honest_newest = now - 60;
    honest
        .seed(&unparseable_window(&h, honest_backlog, honest_newest))
        .await;
    let boundary_secs = honest_newest - i64::try_from(PAGE_LIMIT - 1).unwrap();

    // The late relay holds events on BOTH sides of that boundary: three below it
    // (which the chase page reaches, so it speaks) and three above it (which
    // only the first page would have covered, so they are never requested at
    // all — this is the loss).
    let below = unparseable_window(&h, 3, boundary_secs - 40);
    let above = unparseable_window(&h, 3, now - 100);
    late.seed(&below).await;
    late.seed(&above).await;

    let out = run_catchup_all_circles(&fx.alice, &relay_mgr, &fx.alice_keys.public_key(), 60).await;

    assert_eq!(
        out.events_rejected_pre_auth,
        honest_backlog + below.len(),
        "precondition: exactly the honest backlog plus the late relay's three \
         events BELOW the boundary may have been retrieved — its three above it \
         were requested by nobody, which is the whole point"
    );
    assert_eq!(
        out.windows_truncated, 1,
        "a relay that was silent for the opening page and then answers a chase \
         page has given an answer about a range narrower than the window; the \
         window cannot be called complete on the strength of it"
    );
    assert_eq!(
        fx.alice_cursor(),
        None,
        "and the cursor must hold, so the next sweep asks this relay for the \
         whole window again"
    );
}

/// Alice (the circle's admin) authors a chain of two commits — add a member,
/// then remove them — and publishes both to `relay_url`. Returns the removed
/// member's pubkey and the SECOND commit's `created_at`, which is a whole second
/// above the first's so that which one a relay serves first is a fact about
/// their timestamps rather than a tie-break.
async fn alice_adds_then_removes(
    fx: &TwoMemberCircle,
    relay_mgr: &RelayManager,
    relay_url: &str,
) -> (String, i64) {
    let relays = [relay_url.to_string()];
    let (_charlie, charlie_keys, charlie_member, _charlie_dir) =
        mint_member(&["wss://charlie-inbox.example.com".to_string()]).await;
    let charlie_hex = charlie_keys.public_key().to_hex();

    let add = fx
        .alice
        .add_members_with_welcomes(
            &fx.alice_keys,
            &fx.mls_group_id,
            vec![charlie_member],
            &relays,
        )
        .await
        .expect("alice adds charlie");
    relay_mgr
        .publish_event(&add.commit_event, &relays)
        .await
        .expect("the add commit reaches the relay");
    fx.alice
        .confirm_published(add.pending)
        .await
        .expect("alice confirms the add");
    wait_until_after(i64::try_from(add.commit_event.created_at.as_secs()).expect("fits")).await;

    let remove = fx
        .alice
        .remove_members(&fx.mls_group_id, std::slice::from_ref(&charlie_hex))
        .await
        .expect("alice removes charlie");
    relay_mgr
        .publish_event(&remove.commit_event, &relays)
        .await
        .expect("the remove commit reaches the relay");
    fx.alice
        .confirm_published(remove.pending)
        .await
        .expect("alice confirms the removal");

    (
        charlie_hex,
        i64::try_from(remove.commit_event.created_at.as_secs()).expect("created_at fits"),
    )
}

/// Two DEPENDENT commits split across pages: the later one arrives FIRST, and
/// what the sweep does with it.
///
/// Pages descend, so a chase hands the engine a chain of commits backwards. That
/// is the ordering cost the per-page ingest pays (`fetch_and_ingest` argues why
/// it is worth paying), and nothing else drives it: every other paging test here
/// uses envelopes the pre-engine parse refuses, which can have no predecessor at
/// all.
///
/// What actually happens is not buffering. A `kind:445`'s OUTER layer is keyed
/// by the MLS exporter of the epoch it was SENT in, so a commit authored one
/// epoch ahead of the receiver does not reach the inner MLS layer to be buffered
/// there — it fails to peel, which the engine reports as `Stale` and the sweep
/// therefore does NOT hold the cursor at (the module's "What is deliberately NOT
/// held back": the engine keeps it as a retryable row, and holding would freeze
/// every client temporarily unable to decrypt). Nor does the predecessor landing
/// a page later release it inside this sweep.
///
/// So the pair converges on the sweep AFTER this one, and the cost of the
/// descending order is a re-fetch rather than a loss. This test pins that whole
/// sequence, because every part of it is load-bearing and none of it is the
/// obvious guess.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn two_dependent_commits_split_across_pages_converge_on_the_next_sweep() {
    // Two events per page, so the two commits land in pages of their own below
    // two filler events.
    let relay = SeededRelay::with_cap(Some(2)).await;
    let relay_mgr = RelayManager::new();
    let fx = build_two_member_circle(vec![relay.url.clone()]).await;
    let cursor_stream = group_cursor_stream(&hex::encode(fx.nostr_group_id));
    let bob_epoch_before = fx.bob.group_epoch(&fx.mls_group_id).await.expect("epoch");
    let (charlie_hex, second_secs) = alice_adds_then_removes(&fx, &relay_mgr, &relay.url).await;

    // Two filler events above both commits, so page 1 is spent on them, page 2
    // delivers the SECOND commit alone and page 3 its predecessor.
    let newest_filler = second_secs + 2;
    relay
        .seed(&unparseable_window(
            &hex::encode(fx.nostr_group_id),
            2,
            newest_filler,
        ))
        .await;
    wait_until_after(newest_filler).await;

    let out = run_catchup_all_circles(&fx.bob, &relay_mgr, &fx.bob_keys.public_key(), 60).await;

    assert_eq!(out.circles_swept, 1);
    assert_eq!(
        out.events_rejected_pre_auth, 2,
        "precondition: both fillers must have been retrieved, or the commits \
         were never split across pages and nothing below is about ordering"
    );
    assert_eq!(
        out.events_applied, 2,
        "precondition: both commits reached the engine and got a verdict from it"
    );
    assert_eq!(
        fx.bob.group_epoch(&fx.mls_group_id).await.expect("epoch"),
        bob_epoch_before + 1,
        "only the PREDECESSOR can apply on arrival: the later commit's outer \
         layer is keyed by an epoch Bob had not reached when it was handed to \
         him, and the predecessor landing a page later does not re-drive it \
         inside this sweep"
    );
    assert!(
        fx.bob
            .session()
            .member_pubkeys(&fx.mls_group_id)
            .await
            .expect("roster")
            .contains(&charlie_hex),
        "which is visible in the roster: the removal has not taken effect yet"
    );
    assert_eq!(
        out.events_deferred, 0,
        "and it is NOT a deferral: an unpeelable event is `Stale`, which the \
         sweep deliberately does not hold the cursor at — holding would freeze \
         the cursor of any client temporarily unable to decrypt"
    );
    assert_eq!(
        out.windows_truncated, 0,
        "the chase itself finished, so the out-of-order delivery cost the window \
         nothing"
    );
    assert!(
        fx.bob
            .read_sync_cursor(&cursor_stream)
            .expect("cursor read")
            .is_some_and(|ms| ms > second_secs * 1000),
        "so the cursor really does pass the un-applied commit — which is what \
         makes the next sweep, and not this one, the recovery; got {:?}",
        fx.bob.read_sync_cursor(&cursor_stream),
    );

    // The recovery, and the reason passing it above is not a loss: the next
    // sweep's floor is `GROUP_RESUBSCRIBE_BUFFER_SECS` below the cursor, so both
    // commits are re-requested — and this time the predecessor is already
    // applied, so the successor peels.
    let again = run_catchup_all_circles(&fx.bob, &relay_mgr, &fx.bob_keys.public_key(), 60).await;
    assert_eq!(
        again.events_applied, 2,
        "precondition: the pair really was re-fetched rather than resolved out \
         of thin air"
    );
    assert_eq!(
        fx.bob.group_epoch(&fx.mls_group_id).await.expect("epoch"),
        bob_epoch_before + 2,
        "the pair converges on the sweep after the one that fetched it"
    );
    assert!(
        !fx.bob
            .session()
            .member_pubkeys(&fx.mls_group_id)
            .await
            .expect("roster")
            .contains(&charlie_hex),
        "and the removal has taken effect"
    );
}

/// A relay the FIRST page could not REACH must not freeze the window when a
/// later page reaches it.
///
/// This is the complement of
/// `a_relay_that_answers_only_a_later_page_cannot_complete_the_window`, and what
/// separates them is whether the relay was ASKED. A relay that answered "nothing
/// in this range" about the whole window and then speaks about a narrower one
/// has contradicted itself, and must not help call the window complete. A relay
/// the fetch never got a socket to answered nothing about anything: it is the
/// unreachable relay `cursor_advance_ms` deliberately advances past, and reading
/// its later answer as a contradiction turns one slow connect into a frozen
/// circle.
///
/// That needs no attacker and no exotic relay. `fetch_events_per_relay` reports
/// a handshake that did not complete inside its connection timeout exactly like
/// an empty answer — `responded == false`, no events — and the background wake
/// builds a FRESH relay pool every time it runs, so page 1 is always that pool's
/// first connect to a relay and page 2 is a retry. A relay whose first connect
/// reliably needs longer than the timeout (a cold DNS lookup, a radio still
/// leaving idle) is then silent on page 1 and speaks on page 2 on EVERY wake:
/// the window never completes, the cursor never advances, and the backlog grows
/// unfinishable — a self-inflicted outage, permanent, and nobody's doing.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_relay_unreachable_for_the_first_page_does_not_freeze_the_window() {
    let relay = SeededRelay::run().await;
    // The SAME relay behind a cold front door, so the two entries hold the same
    // events and the only difference between them is that one missed page 1.
    let cold = ColdFirstConnect::in_front_of(&relay.url).await;
    let relay_mgr = RelayManager::new();
    let fx = build_two_member_circle(vec![relay.url.clone(), cold.url.clone()]).await;

    // Dated a minute back so the first round has somewhere to descend TO: a
    // window whose whole content sits in the sweep's opening second cannot be
    // completed by any relay (see the module docs' paging section), which would
    // make the assertions below unreachable for a reason this test is not about.
    let newest_secs = chrono::Utc::now().timestamp() - 60;
    let window = unparseable_window(&hex::encode(fx.nostr_group_id), 3, newest_secs);
    relay.seed(&window).await;

    let out = run_catchup_all_circles(&fx.alice, &relay_mgr, &fx.alice_keys.public_key(), 60).await;

    assert_eq!(
        out.relay_errors, 1,
        "precondition: exactly one fetch must have gone unanswered — the cold \
         relay's FIRST page — or this test is not driving the sequence it \
         describes"
    );
    assert_eq!(
        out.events_rejected_pre_auth,
        window.len(),
        "precondition: the window itself must have been retrieved in full, so \
         nothing below is explained by an empty fetch"
    );
    assert_eq!(
        out.windows_truncated, 0,
        "a relay that could not be REACHED for the opening page has said nothing \
         to contradict; the window it never entered must still be able to \
         complete"
    );
    assert!(
        fx.alice_cursor()
            .is_some_and(|cursor| cursor > newest_secs * 1000),
        "and the cursor must advance past the window it did retrieve — holding \
         here would repeat on every wake, because every wake's first page is a \
         cold connect; got {:?}",
        fx.alice_cursor(),
    );
}

/// A chase that spends the whole wake budget must still APPLY the pages it
/// managed to fetch.
///
/// The deadline is the real bound on a long chase (eight sequential rounds do
/// not fit a 20–25 s wake), so a badly backlogged circle routinely runs out of
/// time mid-chase. Fetching every page before ingesting any turns that into a
/// livelock: the deadline lands during the chase, the ingest loop then defers
/// every fetched event without touching one of them, and the next wake — with
/// the cursor untouched and the same backlog waiting — repeats it. The circle
/// never converges, so a stranded commit stays stranded however many wakes go by.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_chase_that_spends_the_wake_budget_still_applies_what_it_fetched() {
    /// Answers every REQ, a fixed `delay` later. Slow enough that the wake
    /// budget below buys a few rounds and not the whole chase, so the deadline
    /// lands mid-chase by construction rather than by racing the machine.
    #[derive(Debug)]
    struct DelayEveryQuery {
        delay: Duration,
    }

    impl QueryPolicy for DelayEveryQuery {
        fn admit_query<'a>(
            &'a self,
            _query: &'a nostr::Filter,
            _addr: &'a std::net::SocketAddr,
        ) -> BoxedFuture<'a, PolicyResult> {
            Box::pin(async move {
                tokio::time::sleep(self.delay).await;
                PolicyResult::Accept
            })
        }
    }

    let relay = SeededRelay::from_builder(RelayBuilder::default().query_policy(DelayEveryQuery {
        delay: Duration::from_secs(1),
    }))
    .await;
    let relay_mgr = RelayManager::new();
    let fx = build_two_member_circle(vec![relay.url.clone()]).await;

    // Five pages of backlog against a three-second budget: the chase cannot
    // finish, and the first page is fetched with seconds of budget to spare.
    let backlog = 5 * PAGE_LIMIT;
    let window = unparseable_window(
        &hex::encode(fx.nostr_group_id),
        backlog,
        chrono::Utc::now().timestamp() - 60,
    );
    relay.seed(&window).await;

    let out = run_catchup_all_circles(&fx.alice, &relay_mgr, &fx.alice_keys.public_key(), 3).await;

    assert!(
        out.deadline_hit,
        "precondition: the wake budget must really have run out mid-chase"
    );
    // Deliberately "> 0" and not a page count. What the livelock was is
    // "applied NOTHING", and this counter can only be reached by an event that
    // really went through the engine, so any non-zero value refutes it. A floor
    // of one whole page would instead be asserting that this machine can ingest
    // 500 events inside the budget the fetch left over — a property of the
    // machine, not of the sweep, and the kind of assertion that is green until
    // it is flaky on a loaded runner.
    assert!(
        out.events_rejected_pre_auth > 0,
        "a sweep that spent its budget fetching must still have ingested what it \
         fetched — applying nothing at all means the next wake starts exactly \
         here and the circle never converges"
    );
    assert!(
        out.events_rejected_pre_auth < backlog,
        "precondition: the chase must really have been cut short, or this proves \
         nothing about a deadline landing mid-chase"
    );
    assert_eq!(
        out.windows_truncated, 1,
        "the window is still incomplete, so progress on the ingest side must not \
         have bought it a cursor advance"
    );
    assert_eq!(fx.alice_cursor(), None, "and the cursor holds");
}

/// A genuine peer location that lands in a LATER page is still applied, still
/// persisted, and still leaves a completed window behind it.
///
/// Every other paging test here is built from envelopes the pre-engine parse
/// refuses, which isolates the paging rule but never puts a real MLS message
/// through a chase. Two things need it. The chase now feeds the engine page by
/// page, newest page first, so a genuine event in the OLDEST page is delivered
/// after events that are newer than it — the ordering cost of ingesting as we go
/// rather than banking the whole union. And a relay serving two events at a time
/// is the clamped shape that a size-driven chase never chases at all: it hands
/// back the newest two, looks drained, and the location three pages down is
/// never fetched by this or any later sweep.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_genuine_location_in_a_later_page_is_still_applied_and_persisted() {
    // Two events per page, so four events make a four-round chase — no
    // 500-event seeding needed to reach one.
    let relay = SeededRelay::with_cap(Some(2)).await;
    let relay_mgr = RelayManager::new();
    let fx = build_two_member_circle(vec![relay.url.clone()]).await;

    let (loc_event, _, _) = fx
        .bob
        .encrypt_location(
            &fx.mls_group_id,
            &fx.bob_keys.public_key(),
            &LocationMessage::new(48.858_37, 2.294_481),
            300,
        )
        .await
        .expect("bob encrypts a location");
    relay_mgr
        .publish_event(&loc_event, std::slice::from_ref(&relay.url))
        .await
        .expect("bob's location reaches the relay");
    let loc_secs = i64::try_from(loc_event.created_at.as_secs()).expect("created_at fits");

    // Three unparseable events, one per second, all NEWER than the location, so
    // the location is the OLDEST thing in the window and the chase reaches it
    // only on its third page.
    let newest_junk = loc_secs + 3;
    relay
        .seed(&unparseable_window(
            &hex::encode(fx.nostr_group_id),
            3,
            newest_junk,
        ))
        .await;
    wait_until_after(newest_junk).await;

    let out = run_catchup_all_circles(&fx.alice, &relay_mgr, &fx.alice_keys.public_key(), 60).await;

    assert_eq!(
        out.events_applied, 1,
        "the genuine location must reach the engine even though three newer \
         events were handed over before it"
    );
    assert_eq!(
        out.events_rejected_pre_auth, 3,
        "precondition: all three newer events must have been retrieved too, or \
         the location was not in a later page at all"
    );
    assert_eq!(out.events_deferred, 0);
    assert_eq!(
        out.windows_truncated, 0,
        "and the chase finished, so the out-of-order delivery cost the window \
         nothing"
    );

    let rows = fx.alice_peer_locations();
    assert_eq!(rows.len(), 1, "exactly one peer row");
    assert_eq!(rows[0].sender_pubkey, fx.bob_keys.public_key().to_hex());
    assert!((rows[0].latitude - 48.858_37).abs() < 1e-9);
    assert!((rows[0].longitude - 2.294_481).abs() < 1e-9);

    assert!(
        fx.alice_cursor()
            .is_some_and(|cursor| cursor > newest_junk * 1000),
        "and the completed window advances past everything it retrieved; got {:?}",
        fx.alice_cursor(),
    );
}

// ─────────────────────────────────────────────────────────────────────────────
// Resuming the descent across sweeps (Security Rule 12)
//
// The page budget bounds one sweep's chase, so a circle holding more backlog
// than that budget can retrieve has an oldest tail that a sweep restarting at
// the newest end would fetch on no wake at all. Nothing is dropped — the cursor
// holds — but nothing reaches it either, and the circle quietly stops
// converging. A halted chase therefore persists the `until` it stopped at, and
// the next sweep spends a SECOND pass resuming there.
//
// These drive the real `run_catchup_all_circles` over successive sweeps: the
// backlog is walked down to its oldest event, the same backlog with the floor
// thrown away never is, and a relay serving forged timestamps cannot move the
// floor out of the band this device asked in.
// ─────────────────────────────────────────────────────────────────────────────

/// A sweep count no scenario below needs, so exhausting it is a failure rather
/// than a shrug. The deepest descent here finishes in three.
const MAX_SWEEPS: usize = 8;

/// A backlog `span` seconds deep holding TWO events per second, all strictly
/// newer than `oldest_secs` and none of them newer than `oldest_secs + span`.
///
/// Two per second rather than one because the chase descends by SECONDS, not by
/// events: a backlog deep enough to outlast a sweep's page budget therefore
/// costs a test the wall-clock seconds it spans, waiting for the sweep's own
/// anchor to rise above it. Packing the events makes the same budget bind over
/// half the span.
fn packed_window(h: &str, span: usize, oldest_secs: i64) -> Vec<Event> {
    stacked_window(
        h,
        span,
        2,
        oldest_secs + i64::try_from(span).expect("span fits i64"),
    )
}

/// A circle whose relay holds a backlog deeper than one sweep's page budget,
/// with the PEER'S LOCATION as its oldest event.
///
/// "Reached" is then not a counter: it is the peer's decrypted coordinates
/// appearing in Alice's store, which can only happen once a sweep has paged all
/// the way down to it. The relay clamps every `limit` to four, so the budget
/// binds over a span a test can afford to wait out.
struct BackloggedCircle {
    _relay: SeededRelay,
    relay_mgr: RelayManager,
    fx: TwoMemberCircle,
    /// The newest second the backlog occupies, already in the past.
    newest_secs: i64,
}

impl BackloggedCircle {
    async fn build() -> Self {
        let relay = SeededRelay::with_cap(Some(4)).await;
        let relay_mgr = RelayManager::new();
        let fx = build_two_member_circle(vec![relay.url.clone()]).await;

        let (loc_event, _, _) = fx
            .bob
            .encrypt_location(
                &fx.mls_group_id,
                &fx.bob_keys.public_key(),
                &LocationMessage::new(-33.856_78, 151.215_28),
                300,
            )
            .await
            .expect("bob encrypts a location");
        relay_mgr
            .publish_event(&loc_event, std::slice::from_ref(&relay.url))
            .await
            .expect("bob's location reaches the relay");
        let loc_secs = i64::try_from(loc_event.created_at.as_secs()).expect("created_at fits");

        let span = 15;
        let newest_secs = loc_secs + i64::try_from(span).expect("span fits i64");
        relay
            .seed(&packed_window(
                &hex::encode(fx.nostr_group_id),
                span,
                loc_secs,
            ))
            .await;
        wait_until_after(newest_secs).await;

        Self {
            _relay: relay,
            relay_mgr,
            fx,
            newest_secs,
        }
    }
}

/// A window bigger than one sweep can retrieve is walked DOWN to its oldest
/// event over successive sweeps.
///
/// The stall this closes: every sweep restarted the chase at the newest end of
/// the same `since`, so the newest pages were fetched over and over while the
/// oldest tail was fetched by nobody. The cursor correctly refused to advance
/// over it, which is what kept it reachable — and also what kept the window from
/// ever shrinking, so the circle stopped converging without a single error.
///
/// Bob's location is the OLDEST thing in the window, under a backlog deeper than
/// one sweep's page budget. So "reached" is not a counter here: it is the peer's
/// decrypted coordinates appearing in Alice's store, which can only happen once
/// a sweep has actually paged all the way down to it.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_backlog_bigger_than_one_sweep_is_walked_down_to_its_oldest_event() {
    let backlogged = BackloggedCircle::build().await;
    let (fx, relay_mgr, newest_secs) = (
        &backlogged.fx,
        &backlogged.relay_mgr,
        backlogged.newest_secs,
    );

    let mut floors: Vec<i64> = Vec::new();
    let mut reached_on: Option<usize> = None;
    let mut finished_at: Option<i64> = None;
    for sweep in 1..=MAX_SWEEPS {
        let resumed_at = fx.alice_floor();
        run_catchup_all_circles(&fx.alice, relay_mgr, &fx.alice_keys.public_key(), 60).await;
        if reached_on.is_none() && !fx.alice_peer_locations().is_empty() {
            reached_on = Some(sweep);
        }
        if let Some(floor) = fx.alice_floor() {
            floors.push(floor);
        } else {
            // No floor left: this sweep's descent reached the bottom of the band
            // it resumed into, which is the only thing that clears one.
            finished_at = resumed_at;
            break;
        }
    }

    let reached_on = reached_on.unwrap_or_else(|| {
        panic!(
            "the oldest event must be reached: {MAX_SWEEPS} sweeps left it \
             unfetched, which is the descent never resuming"
        )
    });
    assert!(
        reached_on > 1,
        "precondition: one sweep's budget must NOT be enough for this backlog, \
         or the resumption is doing no work and every assertion here is vacuous"
    );
    assert!(
        floors.windows(2).all(|pair| pair[1] < pair[0]),
        "each sweep must resume BELOW where the last one stopped — a floor that \
         does not descend is a circle re-fetching the same band forever; got \
         {floors:?}"
    );

    let rows = fx.alice_peer_locations();
    assert_eq!(rows.len(), 1, "exactly one peer row");
    assert_eq!(rows[0].sender_pubkey, fx.bob_keys.public_key().to_hex());
    assert!((rows[0].latitude - -33.856_78).abs() < 1e-9);
    assert!((rows[0].longitude - 151.215_28).abs() < 1e-9);

    // And the sweep that finished a descent claimed ONLY the band it drained. A
    // resumed pass covers `[since, floor]`, not the whole window, so the cursor
    // may not land on the sweep's own open time: everything above the floor
    // still has to be asked for again. Landing there instead would step over
    // whatever the top-down pass ran out of budget before reaching.
    let resumed_at = finished_at.expect("a descent that reached the bottom");
    let cursor = fx
        .alice_cursor()
        .expect("a drained band advances the cursor");
    assert!(
        cursor <= resumed_at * 1000,
        "the advance must not exceed the band the pass resumed into \
         ({resumed_at} s); got {cursor} ms",
    );
    assert!(
        resumed_at < newest_secs,
        "precondition: that band really is a strict subset of the window, so \
         the bound above is a restriction and not a tautology"
    );

    // ...AND THE CIRCLE THEN CATCHES UP. Reaching the oldest event is only half
    // the promise: a sweep that keeps re-fetching the same window for ever has
    // not caught the circle up, it has paid for it repeatedly.
    //
    // The completing descent above could claim no more than the band it resumed
    // into, which sits inside the backlog — so `since` comes back below the
    // whole of it, the next top-down pass runs out of budget in the same place,
    // and a sweep counting only what ONE pass finished has nothing left to
    // learn. That is a limit cycle, not convergence: byte-for-byte the same
    // three sweeps, for ever, with the cursor pinned where it is now.
    //
    // What breaks it is composition — a sweep's own passes retrieving a
    // contiguous band that comes down to meet the cursor covers the whole
    // window between them, even though neither did alone. The cursor then rises
    // ABOVE every event in the backlog, which no event's own timestamp could
    // ever license and the cycle can never reach.
    assert!(
        cursor <= newest_secs * 1000,
        "precondition: the descent has NOT caught the circle up yet, so the \
         convergence below is this loop's doing and not already true"
    );
    let mut caught_up = false;
    for _ in 1..=MAX_SWEEPS {
        run_catchup_all_circles(&fx.alice, relay_mgr, &fx.alice_keys.public_key(), 60).await;
        if fx.alice_cursor().is_some_and(|ms| ms > newest_secs * 1000) {
            caught_up = true;
            break;
        }
    }
    assert!(
        caught_up,
        "the circle must converge, not cycle: {MAX_SWEEPS} further sweeps left \
         the cursor at {:?} ms, at or below the backlog's newest event \
         ({newest_secs} s), so every one of them re-fetched and re-ingested the \
         whole window for nothing",
        fx.alice_cursor()
    );
}

/// The negative control: the SAME backlog, with the resume point thrown away
/// between sweeps, is never reached however many sweeps run.
///
/// Without this, the test above would pass for an implementation that simply got
/// lucky with budgets — it pins that the persisted resume point is what does the
/// work, and it is the stall itself, stated as a failing behaviour.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn the_same_backlog_is_never_reached_when_the_resume_point_is_discarded() {
    let backlogged = BackloggedCircle::build().await;
    let (fx, relay_mgr) = (&backlogged.fx, &backlogged.relay_mgr);

    for _ in 0..MAX_SWEEPS {
        run_catchup_all_circles(&fx.alice, relay_mgr, &fx.alice_keys.public_key(), 60).await;
        fx.alice
            .clear_backfill_floor(&fx.cursor_stream())
            .expect("discard the resume point");
    }

    assert!(
        fx.alice_peer_locations().is_empty(),
        "a sweep that always restarts at the newest end re-fetches the same top \
         of the window forever: {MAX_SWEEPS} of them must leave the oldest event \
         exactly where it was"
    );
    assert_eq!(
        fx.alice_cursor(),
        None,
        "and the cursor must hold throughout — the tail is reachable only while \
         `since` stays below it, which is what makes the stall a stall and not a \
         loss"
    );
}

/// A relay serving forged timestamps cannot move the persisted floor out of the
/// band this device asked in.
///
/// The floor is the one piece of new state that survives a sweep, so the first
/// question about it is what a remote party can do to its value. Two shapes are
/// free to any observer of the circle's PUBLIC `#h`:
///
/// * a FUTURE-dated event, which as a resume point would sit above the window and
///   strand everything under it; and
/// * an ANCIENT one padding a page, which proposes a paging boundary far below
///   where the honest relays' backlogs actually stop — and, taken as the resume
///   point, would send the next sweep straight past them.
///
/// Neither reaches the floor. Every page is bounded above by the window's own
/// open time, so the future event is never in an answer at all; and the paging
/// boundary is the MAXIMUM across contributing relays, so the honest relay's
/// bottom is what the chain descends by. The floor is then the `until` this
/// device ISSUED — always inside `[since, window open]`, never a number a relay
/// handed us.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_forged_timestamp_cannot_drag_the_backfill_floor_out_of_our_own_band() {
    let poisoned = SeededRelay::with_cap(Some(2)).await;
    let honest = SeededRelay::with_cap(Some(2)).await;
    let relay_mgr = RelayManager::new();
    let fx = build_two_member_circle(vec![poisoned.url.clone(), honest.url.clone()]).await;
    let h = hex::encode(fx.nostr_group_id);

    let now = chrono::Utc::now().timestamp();
    let newest_secs = now - 60;
    honest.seed(&unparseable_window(&h, 21, newest_secs)).await;

    // One event an hour old — inside the window, an hour below where the honest
    // relay's backlog stops — and one a day in the future.
    let ancient_secs = now - 3600;
    poisoned
        .seed(&unparseable_window(&h, 1, ancient_secs))
        .await;
    poisoned
        .seed(&unparseable_window(&h, 1, now + 86_400))
        .await;

    let first =
        run_catchup_all_circles(&fx.alice, &relay_mgr, &fx.alice_keys.public_key(), 60).await;

    assert_eq!(
        first.events_rejected_pre_auth, 10,
        "precondition: exactly the honest relay's newest nine plus the ancient \
         event may come back — the future-dated one is outside the band every \
         page is bounded by, so it is never served, never ingested, and can \
         never be anything's boundary"
    );
    let floor = fx
        .alice_floor()
        .expect("a halted chase leaves a resume point");
    assert!(
        floor > ancient_secs,
        "the resume point must not be dragged to the forged bottom at \
         {ancient_secs} s: a sweep resuming there would page straight past the \
         honest relay's remaining backlog; got {floor} s"
    );
    assert!(
        floor <= newest_secs,
        "and it must sit inside the band we asked in, at or below the window's \
         newest event ({newest_secs} s); got {floor} s"
    );
    assert_eq!(
        fx.alice_cursor(),
        None,
        "precondition: this window is not finished, so nothing here is explained \
         by an advance"
    );

    // The second sweep resumes, and the forged bottom is no more able to pull the
    // floor down on a resumed pass than on the first one.
    run_catchup_all_circles(&fx.alice, &relay_mgr, &fx.alice_keys.public_key(), 60).await;
    let resumed = fx
        .alice_floor()
        .expect("the descent is still unfinished, so it still has a resume point");
    assert!(
        resumed < floor,
        "the descent must have progressed past {floor} s; got {resumed} s"
    );
    assert!(
        resumed > ancient_secs,
        "and it must still be walking the honest relay's backlog rather than \
         having jumped to the forged bottom at {ancient_secs} s; got {resumed} s"
    );
}

/// A resume point the cursor has since risen past is not resumed into — and is
/// REPAIRED, so the backfill is not switched off for that circle for good.
///
/// Nothing exotic gets a floor into that state: live sync writes the same cursor
/// stream this sweep reads, so a foreground session can raise the cursor above a
/// floor a background wake left behind. What is left is a request ceiling BELOW
/// the band anybody will ask about again.
///
/// Resuming there would be a claim about nothing: the pass would ask
/// `[since, floor]` with the ceiling under the floor, be handed an empty answer,
/// call the chase finished and report that it drained the circle. And leaving
/// the value alone is no better — the storage write only ever LOWERS a floor, so
/// every later sweep would refuse the same stale number and this circle would
/// never resume a descent again.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_resume_point_the_cursor_has_passed_is_refused_and_repaired() {
    let relay = SeededRelay::with_cap(Some(4)).await;
    let relay_mgr = RelayManager::new();
    let fx = build_two_member_circle(vec![relay.url.clone()]).await;
    let h = hex::encode(fx.nostr_group_id);
    let stream = fx.cursor_stream();

    // A backlog no single pass can drain, so the sweep below really does halt
    // and really does have a resume point to record.
    let span = 20;
    let newest_secs = chrono::Utc::now().timestamp() - 5;
    relay
        .seed(&packed_window(
            &h,
            span,
            newest_secs - i64::try_from(span).expect("span fits i64"),
        ))
        .await;

    // A cursor well above the whole backlog's bottom, and a floor beneath the
    // REQ floor that cursor derives — exactly what a foreground session leaves
    // behind when it advances past a background wake's resume point.
    let cursor_secs = newest_secs - 300;
    let stale_floor = cursor_secs - 400;
    fx.alice
        .advance_sync_cursor(&stream, cursor_secs * 1000)
        .expect("seed a cursor a live session could have written");
    fx.alice
        .lower_backfill_floor(&stream, stale_floor)
        .expect("a resume point from an earlier, lower cursor");

    let out = run_catchup_all_circles(&fx.alice, &relay_mgr, &fx.alice_keys.public_key(), 60).await;

    assert_eq!(
        out.windows_truncated, 1,
        "the sweep must not read a floor below its own REQ floor as a band it \
         drained: the empty answer to a request whose ceiling sits under its \
         floor says nothing about this circle at all"
    );
    let repaired = fx
        .alice_floor()
        .expect("a halted chase still leaves a resume point");
    assert!(
        repaired > stale_floor,
        "and the spent floor must be replaced rather than kept: the write can \
         only ever LOWER one, so a stale value left in place refuses every later \
         resume and disables this circle's backfill permanently; got \
         {repaired} s, still at or below the stale {stale_floor} s"
    );

    // The repair is what the next sweep needs: it resumes into the fresh point
    // and drives the descent below it, which is the behaviour the stale floor
    // had been blocking.
    run_catchup_all_circles(&fx.alice, &relay_mgr, &fx.alice_keys.public_key(), 60).await;
    let descended = fx.alice_floor();
    assert!(
        descended.is_none_or(|f| f < repaired),
        "the descent must have resumed at {repaired} s and gone below it (or \
         reached the bottom and cleared it); got {descended:?}"
    );
}

/// A relay that CLAMPS our `limit` and holds a one-second pile-up at the chase's
/// boundary must not be able to hide everything beneath it.
///
/// The hiding place `drained` and the contribution rule between them still left
/// open, and it needs no attacker. NIP-11 `limitation.max_limit` lets a relay
/// clamp our `limit` to its own, and `limit: n` serves the NEWEST n — so a relay
/// whose cap sits at or below the number of events sharing the boundary second
/// answers the identical page every round. Every event in it is one we already
/// hold, so nothing CONTRIBUTES; the page never reaches OUR limit, so nothing
/// looks truncated either. Read as "the relays are drained", the sweep declared
/// the window COMPLETE and advanced the cursor over the entire backlog
/// underneath — the Rule-12 silent drop, with the next sweep's floor then
/// sitting above everything it lost.
///
/// Two events share the boundary second against a relay capping at two, so the
/// repeat is exact, and six more sit below where no page would ever have been
/// issued.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_clamped_pile_up_at_the_boundary_cannot_hide_the_backlog_under_it() {
    let relay = SeededRelay::with_cap(Some(2)).await;
    let relay_mgr = RelayManager::new();
    let fx = build_two_member_circle(vec![relay.url.clone()]).await;
    let h = hex::encode(fx.nostr_group_id);

    let boundary_secs = chrono::Utc::now().timestamp() - 60;
    let beneath = 6;
    // Exactly the relay's cap, sharing one second: the page it serves for
    // `until = boundary` is the page it already served, to the byte.
    relay.seed(&unparseable_window(&h, 1, boundary_secs)).await;
    relay.seed(&unparseable_window(&h, 1, boundary_secs)).await;
    relay
        .seed(&unparseable_window(&h, beneath, boundary_secs - 1))
        .await;

    let out = run_catchup_all_circles(&fx.alice, &relay_mgr, &fx.alice_keys.public_key(), 60).await;

    assert_eq!(
        out.events_rejected_pre_auth,
        2 + beneath,
        "every event beneath the pile-up must still be retrieved: a page of \
         nothing but events we already hold is a relay that is drained OR one \
         clamping at a pile-up, and the two are the same bytes — so the chase \
         has to ASK one second lower rather than assume the first"
    );
    assert_eq!(
        fx.alice_cursor(),
        None,
        "and until it has, nothing may claim the window: an advance here would \
         put the next sweep's floor above the {beneath} events below the pile-up, \
         permanently"
    );

    // The second sweep resumes below where this one ran out of budget and
    // finishes the band, which is what turns the hold above into a delay rather
    // than a stall.
    let again =
        run_catchup_all_circles(&fx.alice, &relay_mgr, &fx.alice_keys.public_key(), 60).await;
    assert_eq!(again.windows_truncated, 0, "the resumed descent finished");
    assert!(
        fx.alice_cursor().is_some(),
        "so the circle converges instead of holding forever"
    );
}
