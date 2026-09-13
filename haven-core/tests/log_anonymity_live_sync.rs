//! Log anonymity over a REAL two-engine receive path (Security Rule 15).
//!
//! Two `CircleManager`s that are genuine co-members, two `LiveSyncCore`s over one
//! `MockRelay`, one location published through `RelayManager` and received by the
//! peer's engine — then every log line this crate emitted during that flow is
//! searched for the identifiers that were in scope while it ran: both pubkeys,
//! the `nostr_group_id`, the real MLS group id, the relay URL, the event ids, the
//! circle name and the coordinates, each in every encoding a "more helpful" log
//! line would reach for (hex, upper case, 8- and 16-char prefixes, `npub1…`,
//! base64 — see `helpers::assert_no_needles`).
//!
//! # Why the assertions narrow to `haven_core` targets
//!
//! [`helpers::LogSink`] captures EVERY target, because a dependency's line lands
//! in the same logcat / oslog as ours. But `nostr-relay-pool` logs relay URLs and
//! subscription state on its own targets, and no change inside `haven-core` can
//! silence them: the only lever is the log filter installed in
//! `rust_builder::api::init_app`. So this test asserts what this crate controls,
//! and the third-party residual is an `init_app` filter change (reported to the
//! agent owning that file), not something a source fix here could close.
//!
//! The two anti-vacuity anchors matter as much as the absences: a capture that
//! recorded nothing, or a receive path that never ran, would pass every
//! "contains no identifier" assertion trivially.

use std::sync::Arc;
use std::time::Duration;

use haven_core::circle::{CircleConfig, CircleManager, MemberKeyPackage};
use haven_core::location::LocationMessage;
use haven_core::relay::live_sync::{CircleSpec, LiveSyncCore, LiveSyncEvent};
use haven_core::relay::maintenance::build_kp_maintenance_events;
use haven_core::relay::RelayManager;
use nostr::{Event, Keys};
use nostr_relay_builder::MockRelay;
use tempfile::TempDir;

mod helpers;
use helpers::{assert_no_needles, assert_some_line_from, capture_haven_log, haven_core_lines};

/// The circle's user-authored name — user text, so it may never reach a log.
const CIRCLE_NAME: &str = "Needle Circle Zephyr";

/// Coordinates with digits that appear nowhere else in this file, so a match is
/// a leak and not a coincidence.
const NEEDLE_LAT: f64 = 12.345_678_9;
const NEEDLE_LON: f64 = -98.765_432_1;

/// Scales the two DELIVERY budgets below — the waits whose expiry FAILS the
/// test. Absent or unparsable means 1, so an ordinary `cargo test` keeps today's
/// timings; the coverage workflow raises it because an instrumented build is
/// slower per basic block, not because the path is racy.
fn wait_scale() -> u32 {
    std::env::var("HAVEN_TEST_WAIT_SCALE")
        .ok()
        .and_then(|v| v.parse::<u32>().ok())
        .filter(|s| *s >= 1)
        .unwrap_or(1)
}

/// Polls `condition` until it holds or `base` (scaled) elapses.
async fn wait_until<F, Fut>(base: Duration, mut condition: F) -> bool
where
    F: FnMut() -> Fut,
    Fut: std::future::Future<Output = bool>,
{
    let deadline = tokio::time::Instant::now() + base * wait_scale();
    while tokio::time::Instant::now() < deadline {
        if condition().await {
            return true;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    condition().await
}

/// Waits for `bus` to deliver a decrypted location for `group_id` from `sender`.
async fn wait_for_location(
    bus: &mut tokio::sync::broadcast::Receiver<LiveSyncEvent>,
    want_group_id: &[u8],
    want_sender: &str,
    base: Duration,
) -> bool {
    let deadline = tokio::time::Instant::now() + base * wait_scale();
    while tokio::time::Instant::now() < deadline {
        match tokio::time::timeout(Duration::from_millis(250), bus.recv()).await {
            Ok(Ok(LiveSyncEvent::Location {
                nostr_group_id,
                sender_pubkey,
                ..
            })) if nostr_group_id == want_group_id && sender_pubkey == want_sender => return true,
            // The sender is gone: no later event can arrive.
            Ok(Err(tokio::sync::broadcast::error::RecvError::Closed)) => return false,
            // Some other event, a lagged receiver, or the poll window expiring.
            Ok(Ok(_) | Err(tokio::sync::broadcast::error::RecvError::Lagged(_))) | Err(_) => {}
        }
    }
    false
}

/// A genuine two-member circle (Alice admin + Bob co-member), each with their own
/// real MLS store.
struct TwoMemberCircle {
    alice: Arc<CircleManager>,
    alice_keys: Keys,
    bob: Arc<CircleManager>,
    bob_keys: Keys,
    mls_group_id: haven_core::nostr::mls::types::GroupId,
    nostr_group_id: [u8; 32],
    _alice_dir: TempDir,
    _bob_dir: TempDir,
}

/// Builds Alice + Bob as real co-members through the PUBLIC circle API (create →
/// confirm → welcome → accept), so the receive path below decrypts a real
/// location from a real member.
async fn build_two_member_circle(relays: &[String]) -> TwoMemberCircle {
    let bob_dir = TempDir::new().unwrap();
    let bob_keys = Keys::generate();
    let bob = CircleManager::new_unencrypted(bob_dir.path(), &bob_keys).unwrap();
    let bob_kp_event = build_kp_maintenance_events(
        bob.session(),
        &bob_keys,
        &["wss://kp.example.com".to_string()],
        None,
        None,
    )
    .await
    .expect("bob key package")
    .event;
    let bob_member = MemberKeyPackage {
        key_package_event: bob_kp_event,
        inbox_relays: vec!["wss://member-inbox.example.com".to_string()],
        nip65_relays: vec![],
    };

    let alice_dir = TempDir::new().unwrap();
    let alice_keys = Keys::generate();
    let alice = CircleManager::new_unencrypted(alice_dir.path(), &alice_keys).unwrap();
    let config = CircleConfig::new(CIRCLE_NAME).with_relays(relays.to_vec());
    let result = alice
        .create_circle(&alice_keys, vec![bob_member], &config, relays)
        .await
        .expect("create circle");
    let mls_group_id = result.circle.mls_group_id.clone();
    let nostr_group_id = result.circle.nostr_group_id;
    alice
        .confirm_published(result.pending)
        .await
        .expect("alice confirms creation");

    let welcome = &result.welcome_events[0];
    bob.process_gift_wrapped_invitation(&bob_keys, &welcome.event)
        .await
        .expect("bob processes welcome");
    bob.accept_invitation(&welcome.event.id)
        .await
        .expect("bob accepts");

    TwoMemberCircle {
        alice: Arc::new(alice),
        alice_keys,
        bob: Arc::new(bob),
        bob_keys,
        mls_group_id,
        nostr_group_id,
        _alice_dir: alice_dir,
        _bob_dir: bob_dir,
    }
}

/// Every identifier that was in scope while the flow ran, in the spellings a log
/// line could carry it in. `assert_no_needles` expands each into its case, hex,
/// prefix, `npub` and base64 forms, so truncation is covered without listing it.
fn needles(fx: &TwoMemberCircle, url: &str, location_event: &Event) -> Vec<String> {
    let mut out = vec![
        fx.alice_keys.public_key().to_hex(),
        fx.bob_keys.public_key().to_hex(),
        hex::encode(fx.nostr_group_id),
        hex::encode(fx.mls_group_id.as_slice()),
        CIRCLE_NAME.to_owned(),
        location_event.id.to_hex(),
        url.to_owned(),
        url.trim_end_matches('/').to_owned(),
    ];
    // The relay by host and by port separately: a line that drops the scheme
    // still names the endpoint.
    let authority = url
        .split_once("://")
        .map_or(url, |(_, rest)| rest)
        .trim_end_matches('/');
    if let Some((host, port)) = authority.rsplit_once(':') {
        out.push(host.to_owned());
        out.push(format!(":{port}"));
    }
    // Coordinates at every precision a rounding "summary" would use, in both
    // orders.
    for places in 3_usize..=7 {
        out.push(format!("{NEEDLE_LAT:.places$}"));
        out.push(format!("{NEEDLE_LON:.places$}"));
    }
    out.push(format!("{NEEDLE_LAT},{NEEDLE_LON}"));
    out.push(format!("{NEEDLE_LON},{NEEDLE_LAT}"));
    out
}

/// Asserts the subscribe diagnostic states a bucketed MAGNITUDE, never a roster.
///
/// It used to join one alias handle per circle, so the line's cardinality was the
/// account's exact circle count — a disclosure no per-value redaction can fix,
/// because the NUMBER of handles was the leak.
fn assert_subscribe_states_a_bucket_not_a_roster(ours: &[helpers::LogLine]) {
    let subscribe_lines: Vec<&str> = ours
        .iter()
        .filter(|l| l.message.contains("register_and_subscribe"))
        .map(|l| l.message.as_str())
        .collect();
    assert!(
        !subscribe_lines.is_empty(),
        "the subscribe diagnostic must still be emitted, or the assertions below \
         hold over nothing"
    );
    for line in &subscribe_lines {
        let Some((_, stated)) = line.rsplit_once("circles=") else {
            panic!("the subscribe diagnostic lost its circles field: {line}")
        };
        assert!(
            ["0", "1", "2-4", "5+"].contains(&stated.trim()),
            "the subscribe diagnostic must state a bucket token, not a count or a \
             roster, but said {stated:?}: {line}"
        );
        assert!(
            !line.contains("circle#"),
            "the subscribe diagnostic must not list per-circle handles — one per \
             circle IS the circle count: {line}"
        );
    }
    // This fixture subscribes exactly one circle, so the bucket is pinned to a
    // value: an assertion that accepted any token would also accept a line that
    // stopped reporting the set it was added to report.
    assert!(
        subscribe_lines.iter().any(|l| l.ends_with("circles=1")),
        "the one-circle subscribe must read circles=1: {subscribe_lines:?}"
    );
}

/// A real receive path names no user, circle, relay, event or position.
///
/// The flow is the shipped one end to end: two engines subscribe over one relay,
/// `RelayManager` publishes Alice's kind-445, Bob's engine receives, routes,
/// decrypts and emits it, a mid-session (un)subscribe runs, and both engines tear
/// down. Every `haven_core` line that produced is then searched for the values
/// that were in hand while it ran.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_two_engine_receive_path_logs_no_identifier() {
    let _ = haven_core::relay::allow_ws_loopback_for_test();
    let relay = MockRelay::run().await.expect("mock relay");
    let url = relay.url().await.to_string();
    let relays = vec![url.clone()];

    // Outside the capture: the fixture's own create/join lines belong to the
    // circle module, and the event id has to be known to be a needle.
    let fx = build_two_member_circle(&relays).await;
    let group_hex = hex::encode(fx.nostr_group_id);
    let location = LocationMessage::new(NEEDLE_LAT, NEEDLE_LON);
    let (location_event, _, _) = fx
        .alice
        .encrypt_location(
            &fx.mls_group_id,
            &fx.alice_keys.public_key(),
            &location,
            300,
        )
        .await
        .expect("alice encrypts a location for the circle");

    let spec = CircleSpec {
        group_id_hex: group_hex.clone(),
        relays: relays.clone(),
    };
    let alice_engine = LiveSyncCore::new_local(Arc::clone(&fx.alice), fx.alice_keys.public_key());
    let bob_engine = LiveSyncCore::new_local(Arc::clone(&fx.bob), fx.bob_keys.public_key());
    let mut bob_bus = bob_engine.bus().subscribe();

    let delivered = Arc::new(std::sync::atomic::AtomicBool::new(false));
    let observed = Arc::clone(&delivered);
    let lines = capture_haven_log(async {
        alice_engine
            .start(std::slice::from_ref(&spec), &[])
            .await
            .expect("alice engine starts");
        bob_engine
            .start(std::slice::from_ref(&spec), &[])
            .await
            .expect("bob engine starts");
        // A condition, not a duration: both REQs must be registered on the pool
        // before the 445 goes out, or the relay has nobody to deliver it to.
        assert!(
            wait_until(Duration::from_secs(10), || async {
                bob_engine.pool_subscription_count().await > 0
                    && alice_engine.pool_subscription_count().await > 0
            })
            .await,
            "both engines must register their REQ before the publish"
        );

        // The shipped publish path, so `RelayManager`'s own lines are in the
        // capture too.
        let manager = RelayManager::new();
        manager
            .publish_event(&location_event, &relays)
            .await
            .expect("the mock relay accepts the location");

        observed.store(
            wait_for_location(
                &mut bob_bus,
                &fx.nostr_group_id,
                &fx.alice_keys.public_key().to_hex(),
                Duration::from_secs(20),
            )
            .await,
            std::sync::atomic::Ordering::SeqCst,
        );

        // The mid-session subscribe/unsubscribe pair: the two remaining places a
        // group id is in hand on this plane.
        alice_engine
            .subscribe_circle(&spec)
            .await
            .expect("mid-session subscribe");
        alice_engine
            .unsubscribe_circle(&group_hex)
            .await
            .expect("mid-session unsubscribe");

        let _ = alice_engine.stop().await;
        let _ = bob_engine.stop().await;
    })
    .await;

    // Anti-vacuity, before any absence is believed: the receive path really ran…
    assert!(
        delivered.load(std::sync::atomic::Ordering::SeqCst),
        "Bob's engine must receive, decrypt and emit Alice's kind-445 — without a \
         real delivery the absences below prove nothing"
    );
    let ours = haven_core_lines(&lines);
    // …and it really logged, on both planes whose lines are the subject here.
    assert_some_line_from(&ours, "haven_core::relay::live_sync");
    assert_some_line_from(&ours, "haven_core::relay::manager");
    assert!(
        ours.iter().any(|l| l.message.contains("circle#")),
        "a line that must say WHICH circle uses a per-process alias handle, so at \
         least one `circle#` handle is expected; without one this test would pass \
         on a plane that simply stopped saying anything"
    );

    assert_subscribe_states_a_bucket_not_a_roster(&ours);

    let needles = needles(&fx, &url, &location_event);
    assert_no_needles(
        &ours,
        &needles.iter().map(String::as_str).collect::<Vec<_>>(),
    );
}

/// A `log::Log` that discards everything — stands in for "some other crate
/// already grabbed the process-wide logger slot before `capture_haven_log`
/// got a chance to".
struct DecoyLogger;

impl log::Log for DecoyLogger {
    fn enabled(&self, _metadata: &log::Metadata<'_>) -> bool {
        true
    }
    fn log(&self, _record: &log::Record<'_>) {}
    fn flush(&self) {}
}

/// `capture_haven_log` must refuse to run rather than silently capture
/// nothing when another logger already owns the process: that refusal is the
/// only thing standing between a foreign logger and every `assert_no_needles`
/// call in this file passing vacuously (nothing captured, nothing to find).
///
/// The precondition — another logger already installed — cannot be staged in
/// THIS process: the receive-path test above also calls `capture_haven_log`
/// and shares its one-per-process `log` slot, so grabbing it here first would
/// make that test's pass/fail depend on test-execution order. A freshly
/// spawned copy of this same binary gets its own slot instead, and `--exact`
/// keeps the child to just this one test.
#[test]
fn capture_haven_log_refuses_a_process_whose_logger_is_already_taken() {
    const MARKER: &str = "HAVEN_LOG_SINK_TAKEOVER_CHILD";
    const TEST_NAME: &str = "capture_haven_log_refuses_a_process_whose_logger_is_already_taken";

    if std::env::var_os(MARKER).is_some() {
        // Child branch: win the process-wide slot first, then let
        // `capture_haven_log` discover it is taken and panic.
        log::set_boxed_logger(Box::new(DecoyLogger))
            .expect("nothing else has touched the logger yet in this fresh process");
        let runtime = tokio::runtime::Builder::new_current_thread()
            .build()
            .expect("build a runtime for the one async call under test");
        runtime.block_on(capture_haven_log(async {}));
        panic!("capture_haven_log must have panicked above and never returned here");
    }

    let exe = std::env::current_exe().expect("this test binary's own path");
    let output = std::process::Command::new(exe)
        .args(["--exact", TEST_NAME, "--nocapture"])
        .env(MARKER, "1")
        .output()
        .expect("spawn the child process");

    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        !output.status.success(),
        "the child must fail: stdout={stdout}\nstderr={stderr}"
    );
    let combined = format!("{stdout}{stderr}");
    assert!(
        combined.contains("another logger already owns this process"),
        "the child did not report the expected refusal: {combined}"
    );
}
