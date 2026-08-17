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
        let target = relay_url
            .trim_start_matches("ws://")
            .trim_end_matches('/')
            .to_string();
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
            .await
            .expect("bind the cold endpoint");
        let url = format!("ws://{}", listener.local_addr().expect("local addr"));
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

/// A fetch the SDK's own timeout cut off must not be read as "the relay had
/// nothing more".
///
/// `RelayPool::fetch_events_from` collects a merged stream and returns
/// `Ok(collected)` however that stream ended — its per-relay errors are logged
/// and dropped inside the driver task, and the whole subscription is wrapped in
/// the fetch timeout. So a relay that accepts the REQ and then goes quiet
/// produces a page byte-for-byte identical to a complete short answer, and the
/// window it belongs to reads as complete: the cursor advances over a backlog
/// the relay is still visibly holding, and the next sweep's floor sits above it
/// for good.
///
/// A query policy that holds every REQ past the fetch timeout stages exactly
/// that. It costs this test that timeout in wall-clock, which is the price of
/// driving the real primitive rather than asserting against a mock of it — and
/// it is what keeps the sweep's cut-off threshold honest now that the threshold
/// IS the primitive's timeout rather than a copy of it: grow that timeout past
/// what this policy stalls for and the relay answers in full, which fails the
/// first precondition below rather than quietly weakening the rule.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_fetch_cut_off_by_its_own_timeout_is_not_read_as_a_complete_window() {
    /// Accepts every REQ but answers no sooner than `hold` — longer than the
    /// fetch timeout, so the fetch is cut off mid-subscription with whatever it
    /// has (here: nothing).
    #[derive(Debug)]
    struct StallEveryQuery {
        hold: Duration,
    }

    impl QueryPolicy for StallEveryQuery {
        fn admit_query<'a>(
            &'a self,
            _query: &'a nostr::Filter,
            _addr: &'a std::net::SocketAddr,
        ) -> BoxedFuture<'a, PolicyResult> {
            Box::pin(async move {
                tokio::time::sleep(self.hold).await;
                PolicyResult::Accept
            })
        }
    }

    let relay = SeededRelay::from_builder(RelayBuilder::default().query_policy(StallEveryQuery {
        hold: Duration::from_secs(30),
    }))
    .await;
    let relay_mgr = RelayManager::new();
    let fx = build_two_member_circle(vec![relay.url.clone()]).await;

    let backlog = 7;
    let window = unparseable_window(
        &hex::encode(fx.nostr_group_id),
        backlog,
        chrono::Utc::now().timestamp() - 60,
    );
    relay.seed(&window).await;

    let out = run_catchup_all_circles(&fx.alice, &relay_mgr, &fx.alice_keys.public_key(), 60).await;

    assert_eq!(
        out.events_rejected_pre_auth, 0,
        "precondition: the stalled fetch must really have delivered nothing, or \
         this asserts nothing about a cut-off read"
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
        "and the cursor must not move: the {backlog} events this relay is still \
         holding are reachable only while `since` stays below them"
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

    let rows = fx
        .alice
        .snapshot_last_known_for_circle(&fx.nostr_group_id, chrono::Utc::now().timestamp())
        .expect("snapshot");
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
