//! R9 (MUST) — privacy-config regression for the always-on live-sync engine.
//!
//! The engine `Client` is built (see `relay/live_sync/session.rs::build_engine_client`)
//! with two privacy-load-bearing options that this suite guards end-to-end over a
//! real in-process relay:
//!
//! - **`automatic_authentication(false)`** — the engine must NEVER answer a
//!   NIP-42 AUTH challenge with a client AUTH (`kind:22242`). Such an AUTH is a
//!   signed event carrying the user's Nostr identity; sending it to a relay that
//!   also serves the circle's `#h` traffic would let that relay (or a passive
//!   observer) link the nsec ↔ the circle. `engine_never_authenticates_to_an_auth_required_relay`
//!   proves it against a relay that REQUIRES AUTH to read: the engine reads
//!   nothing (it refuses to authenticate) while a control client that DOES
//!   authenticate reads the very same stored event — so the engine's silence is
//!   specifically the AUTH refusal, not a dead relay.
//!
//! - **no gossip (own-relays-only, PSI-8)** — the engine must connect to EXACTLY
//!   the configured circle ∪ inbox relay set and never a NIP-65-discovered relay,
//!   so it cannot silently fan the user's subscriptions out to relays they never
//!   chose. `engine_connects_only_to_configured_relays_never_gossip_discovered`
//!   proves the pool equals the configured union even after a kind:10002 relay
//!   list (authored by the engine's own identity) advertises a phantom relay.

use std::sync::Arc;
use std::time::Duration;

use haven_core::circle::CircleManager;
use haven_core::relay::live_sync::{CircleSpec, LiveSyncCore, LiveSyncEvent, SyncStatusReason};
use nostr::{Alphabet, EventBuilder, Filter, Keys, Kind, SingleLetterTag, Tag, TagKind, Timestamp};
use nostr_relay_builder::builder::{RelayBuilder, RelayBuilderNip42, RelayBuilderNip42Mode};
use nostr_relay_builder::{LocalRelay, MockRelay};
use nostr_sdk::pool::RelayNotification;
use nostr_sdk::{Client, ClientOptions, RelayPoolNotification};
use tempfile::TempDir;

/// Scales every wall-clock budget in this file.
///
/// **This is not what fixed the flake, and it must not be credited with it.**
/// The control read below used to expire in the coverage lane as
/// `Err(Elapsed(()))`, which looks exactly like a budget that is too small; it
/// was not. Measured against a 90s budget under the same load, that read either
/// completed in ~50ms or never completed at all — the stall is a lost race in
/// nostr-relay-pool's post-auth resubscribe, fixed where it happens (see
/// [`control_authenticates_then_reads`]). A bigger number would only have made
/// the same failure slower.
///
/// What the scale is for is the ordinary slowness of an instrumented build,
/// where every basic block carries a counter update. Both budget shapes here
/// tolerate it, for different reasons:
///
/// * A **delivery** budget bounds how long an arrival may take and FAILS on
///   expiry, so a larger one can only remove a false negative — an arrival that
///   never happens exhausts any budget. It also costs nothing when the arrival
///   comes, because the wait returns on the event.
/// * An **absence** window bounds how long something must NOT happen, so expiry
///   is its SUCCESS path and a timeout there is not a failure at all. A larger
///   one is a strictly STRONGER assertion. It does spend its full length on
///   every run, which is why each is scaled for a stated reason rather than by
///   habit.
///
/// Set by the coverage workflow and `scripts/ci/check_coverage.sh`. Absent or
/// unparsable means 1, so an ordinary `cargo test` keeps today's timings.
fn wait_scale() -> u32 {
    std::env::var("HAVEN_TEST_WAIT_SCALE")
        .ok()
        .and_then(|v| v.parse::<u32>().ok())
        .filter(|s| *s >= 1)
        .unwrap_or(1)
}

/// `base`, scaled for instrumented runs.
fn wait_budget(base: Duration) -> Duration {
    base * wait_scale()
}

/// Builds a `kind:445` carrying `#h = group_hex` (opaque ciphertext, random key).
fn kind445_with_h(group_hex: &str) -> nostr::Event {
    EventBuilder::new(Kind::Custom(445), "opaque-ciphertext")
        .tags([Tag::custom(
            TagKind::SingleLetter(SingleLetterTag::lowercase(Alphabet::H)),
            [group_hex.to_string()],
        )])
        .sign_with_keys(&Keys::generate())
        .unwrap()
}

/// The outcome of one bounded wait: `Ok(true)` it happened, `Ok(false)` it was
/// refused or the bus closed, `Err` the budget elapsed with neither. Keeping the
/// three apart is what let this file's flake be diagnosed from CI output alone —
/// the failure printed `Err(Elapsed(()))`, which is the shape that says "nothing
/// ever came", not "it came late" and not "it was refused".
type WaitOutcome = Result<bool, tokio::time::error::Elapsed>;

/// Drives a NIP-42 control client at `url` through the two steps the engine
/// declines — authenticate, then read the stored `kind:445` — and reports each
/// separately, so a failure names which step did not happen.
///
/// The two steps are driven IN ORDER here, and that is a correctness
/// requirement, not tidiness. Left as one `subscribe`, the read depends on
/// nostr-relay-pool's post-auth recovery: `resubscribe()` re-sends a REQ only
/// for a subscription some other task has already flagged `closed`
/// (`Relay::should_resubscribe`), the flag is written by the `CLOSED
/// auth-required` handler on the message task, and the re-send is decided on the
/// auth ingester task. When that loses, the REQ is never re-sent and NOTHING
/// further arrives. Measured on this relay under saturating load, the read
/// either completed in ~50ms or never completed at all — 2 stalls in 12 runs
/// against a 90s budget, so "never" is not "slow" and no budget could have
/// bought it. That was this file's flake in the coverage lane.
async fn control_authenticates_then_reads(
    url: &str,
    budget: Duration,
) -> (WaitOutcome, WaitOutcome) {
    let control = Client::builder()
        .signer(Keys::generate())
        .opts(ClientOptions::default().automatic_authentication(true))
        .build();
    control.add_relay(url).await.unwrap();
    // Both receivers are opened BEFORE the first REQ. The challenge, the
    // authentication and the stored replay can all land within a few
    // milliseconds of it, and a notification missed because its receiver did not
    // exist yet is indistinguishable from one that never came.
    let control_relay = control.relay(url).await.expect("control relay handle");
    let mut auth_notifications = control_relay.notifications();
    let mut events = control.notifications();
    control.connect().await;

    // STEP 1 — provoke the challenge. This relay issues a NIP-42 challenge only
    // in ANSWER to a REQ (`nostr_relay_builder`'s `send_auth_and_close` emits
    // AUTH and `CLOSED auth-required` together), so there is no way to
    // authenticate before asking for something. The client answers on its own.
    control
        .subscribe(Filter::new().kind(Kind::Custom(445)), None)
        .await
        .expect("control subscribes");
    let authenticated = tokio::time::timeout(budget, async {
        loop {
            match auth_notifications.recv().await {
                Ok(RelayNotification::Authenticated) => break true,
                // A refusal and a dead bus are both terminal — neither can turn
                // into an `Authenticated` later.
                Ok(RelayNotification::AuthenticationFailed)
                | Err(tokio::sync::broadcast::error::RecvError::Closed) => break false,
                // Anything else, or a LAGGED bus, is not evidence either way.
                Ok(_) | Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => {}
            }
        }
    })
    .await;

    // STEP 2 — read on the now-authenticated session. Whichever REQ the relay
    // answers first, the event is delivered once and `events` — opened above —
    // is holding it.
    control
        .subscribe(Filter::new().kind(Kind::Custom(445)), None)
        .await
        .expect("control re-subscribes once authenticated");
    let read = tokio::time::timeout(budget, async {
        loop {
            match events.recv().await {
                Ok(RelayPoolNotification::Event { event, .. })
                    if event.kind == Kind::Custom(445) =>
                {
                    break true
                }
                Ok(_) | Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => {}
                Err(tokio::sync::broadcast::error::RecvError::Closed) => break false,
            }
        }
    })
    .await;

    (authenticated, read)
}

/// R9 (privacy, `automatic_authentication(false)`): against a relay that requires
/// a NIP-42 AUTH to READ, the engine never sends a client AUTH (`kind:22242`) and
/// therefore reads NOTHING — while a control client that authenticates reads the
/// same stored event, proving the engine's silence is the AUTH refusal (no
/// nsec↔circle linkage), not a broken relay.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn engine_never_authenticates_to_an_auth_required_relay() {
    let _ = haven_core::relay::allow_ws_loopback_for_test();

    // A relay that requires NIP-42 AUTH to READ. In Read mode, WRITES need no
    // auth, so the event below is stored and served only to a reader that auths.
    let relay = LocalRelay::new(RelayBuilder::default().nip42(RelayBuilderNip42 {
        mode: RelayBuilderNip42Mode::Read,
    }));
    relay.run().await.expect("run auth-required relay");
    let url = relay.url().await.to_string();

    let group_hex = hex::encode([0x42u8; 32]);

    // Publish the circle's kind:445 WITHOUT authenticating (write is unguarded in
    // Read mode) so a stored, matching event exists behind the read-AUTH gate.
    let publisher = Client::builder().build();
    publisher.add_relay(&url).await.unwrap();
    publisher.connect().await;
    publisher
        .send_event(&kind445_with_h(&group_hex))
        .await
        .expect("publish (a write needs no auth on a read-only-auth relay)");

    // The engine subscribes. Its client has automatic_authentication(false), so on
    // the relay's AUTH challenge it sends NO client AUTH and its REQ is CLOSED
    // (auth-required) — it can never read the stored event.
    let dir = TempDir::new().unwrap();
    let circle =
        Arc::new(CircleManager::new_unencrypted(dir.path(), &nostr::Keys::generate()).unwrap());
    let engine = LiveSyncCore::new_local(circle, Keys::generate().public_key());
    let mut rx = engine.bus().subscribe(); // before start: capture any content emit
    engine
        .start(
            &[CircleSpec {
                group_id_hex: group_hex.clone(),
                relays: vec![url.clone()],
            }],
            &[],
        )
        .await
        .expect("start");

    // ONE budget, bound once and spent on every wait in this test: the engine's
    // silence here, and the control's authentication and read below. The
    // engine's silence is only evidence against the window the control was
    // given to READ — drain the engine for 8s while granting the control 32 and
    // an auto-auth regression that answered at 9s would pass. A single binding
    // cannot drift; the separate literals this replaced could, and scaling only
    // one of them would have done exactly that.
    let budget = wait_budget(Duration::from_secs(8));

    // Drain the whole window so a slow auto-auth REGRESSION (one that answered
    // the AUTH challenge only after a few seconds) cannot slip past a too-short
    // negative window. The engine must surface NO content (no Location, no
    // Unprocessable); a delivered event would prove it authenticated to read.
    // Connecting/Connected statuses are ignored, and the timeout always elapses
    // (the engine stays silent) — which is the point, and why an `Elapsed` here
    // is discarded rather than asserted on.
    let mut content_emits = 0usize;
    let _ = tokio::time::timeout(budget, async {
        loop {
            match rx.recv().await {
                Ok(
                    LiveSyncEvent::Status {
                        reason: SyncStatusReason::Unprocessable,
                    }
                    | LiveSyncEvent::Location { .. },
                ) => content_emits += 1,
                Ok(_) => {}      // Connecting / Connected / other — keep waiting
                Err(_) => break, // bus closed
            }
        }
    })
    .await;
    assert_eq!(
        content_emits, 0,
        "an engine that refuses NIP-42 AUTH must read NOTHING from an auth-required relay"
    );

    // CONTROL: a client WITH automatic_authentication(true) + a signer DOES send a
    // kind:22242 AUTH and, with it, reads the SAME stored event — so the read
    // gate is real and AUTH is the only thing unlocking it.
    let (control_authenticated, control_got_event) =
        control_authenticates_then_reads(&url, budget).await;
    assert_eq!(
        control_authenticated,
        Ok(true),
        "the control client must complete the very NIP-42 AUTH the engine declines; \
         without it the read below would say nothing about the gate"
    );
    assert_eq!(
        control_got_event,
        Ok(true),
        "an authenticating control client reads the stored event — the relay + event are live behind AUTH"
    );

    // Teardown only: every assertion has already run. The outcome is not
    // asserted here because the drain contract itself is pinned by
    // `join_tasks_*` and the `stop_*` unit tests in
    // `src/relay/live_sync/session.rs`, and by the same-store restart
    // assertions in `live_sync_cursor_replay_e2e`.
    let _ = engine.stop().await;
}

/// R9 (privacy, no gossip): the engine connects to EXACTLY the configured circle
/// ∪ inbox relay set and never adopts a NIP-65-discovered relay — even after a
/// kind:10002 relay list authored by the engine's own identity advertises a
/// phantom relay. With gossip compiled off (own-relays-only, PSI-8) the pool
/// stays the configured union; a gossip-enabled build could grow it.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn engine_connects_only_to_configured_relays_never_gossip_discovered() {
    let _ = haven_core::relay::allow_ws_loopback_for_test();

    // Three DISTINCT configured relays: two for the circle group + one inbox.
    let r_group1 = MockRelay::run().await.expect("group relay 1");
    let r_group2 = MockRelay::run().await.expect("group relay 2");
    let r_inbox = MockRelay::run().await.expect("inbox relay");
    let g1 = r_group1.url().await.to_string();
    let g2 = r_group2.url().await.to_string();
    let inbox = r_inbox.url().await.to_string();

    let identity = Keys::generate();
    let dir = TempDir::new().unwrap();
    let circle =
        Arc::new(CircleManager::new_unencrypted(dir.path(), &nostr::Keys::generate()).unwrap());
    let engine = LiveSyncCore::new_local(circle, identity.public_key());
    engine
        .start(
            &[CircleSpec {
                group_id_hex: hex::encode([0x33u8; 32]),
                relays: vec![g1.clone(), g2.clone()],
            }],
            std::slice::from_ref(&inbox),
        )
        .await
        .expect("start");

    // Poll until ALL three configured relays are connected. A DELIVERY budget —
    // its expiry fails the assertion below — held as a DEADLINE rather than an
    // iteration count, so the bound is a stated span of wall clock that scales,
    // not a probe count whose wall-clock meaning drifts with how long a probe
    // happens to take.
    let deadline = tokio::time::Instant::now() + wait_budget(Duration::from_secs(8));
    let mut ready = false;
    while tokio::time::Instant::now() < deadline {
        let s = engine.relay_health().await;
        if s.total == 3 && s.connected == 3 {
            ready = true;
            break;
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    assert!(
        ready,
        "the engine must connect to EXACTLY the 3 configured (group ∪ inbox) relays"
    );

    // Publish a NIP-65 relay list (kind:10002) authored by OUR identity to g1,
    // advertising a phantom relay the engine was never configured with. A
    // gossip-enabled client could discover + add it; the engine (gossip OFF) must
    // ignore it.
    let publisher = Client::builder().build();
    publisher.add_relay(&g1).await.unwrap();
    publisher.connect().await;
    let relay_list = EventBuilder::new(Kind::RelayList, "")
        .tags([Tag::custom(
            TagKind::SingleLetter(SingleLetterTag::lowercase(Alphabet::R)),
            ["wss://phantom-gossip-relay.invalid".to_string()],
        )])
        .custom_created_at(Timestamp::now())
        .sign_with_keys(&identity)
        .expect("sign nip-65");
    publisher
        .send_event(&relay_list)
        .await
        .expect("publish nip-65 relay list");

    // Over a settling window the pool stays EXACTLY the configured union — the
    // phantom relay is never adopted (no gossip discovery). An ABSENCE window:
    // scaling it only lengthens the interval the phantom must stay out of, and
    // an instrumented build is exactly where a discovery slow enough to land
    // after a fixed 1.5s would hide.
    let settle_until = tokio::time::Instant::now() + wait_budget(Duration::from_millis(1_500));
    while tokio::time::Instant::now() < settle_until {
        tokio::time::sleep(Duration::from_millis(100)).await;
        let s = engine.relay_health().await;
        assert_eq!(
            s.total, 3,
            "the engine must never adopt a gossip-discovered relay (own-relays-only)"
        );
    }

    // NB (F2): no positive gossip control (a `.gossip(true)` client that DOES
    // adopt the phantom) is included. Reliably driving nostr-sdk's outbox/gossip
    // discovery needs an author-triggered NIP-65 resolution whose timing and
    // pool-add semantics are version-specific, and a non-resolvable `.invalid`
    // phantom is not deterministically pool-added — so a positive control would be
    // flaky and would test the SDK, not Haven. The differential is instead
    // guaranteed structurally: gossip is compiled OFF for the engine client
    // (own-relays-only, PSI-8 — see `session.rs::build_engine_client`), so the
    // `total == 3` invariant above holds by construction, not by chance
    // non-discovery. The NIP-65 event IS live on g1 (the control-authored publish
    // succeeded), so "never adopted" is a genuine refusal, not an unfetched list.
    // Teardown only: every assertion has already run. The outcome is not
    // asserted here because the drain contract itself is pinned by
    // `join_tasks_*` and the `stop_*` unit tests in
    // `src/relay/live_sync/session.rs`, and by the same-store restart
    // assertions in `live_sync_cursor_replay_e2e`.
    let _ = engine.stop().await;
}
