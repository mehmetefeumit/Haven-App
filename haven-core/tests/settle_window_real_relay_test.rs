//! Real-`strfry` settle-window measurement — the authoritative real-relay
//! MEASUREMENT behind `COMMIT_SETTLE_WINDOW_SECS` (rollout §7 / Decision 7 /
//! amendment H2). A reproducible ON-DEMAND instrument, NOT a standing CI gate: no
//! lane runs it with `HAVEN_E2E_RELAY` set, so the always-on regression backstop
//! stays `settle_window_tuning_test.rs` (in-process) plus its
//! `COMMIT_SETTLE_WINDOW_SECS <= 10` const-assert — this file is only the
//! real-relay number those defer to.
//!
//! `settle_window_tuning_test.rs` measures the engine's `publish → observe`
//! pipeline over an *in-process* `nostr-relay-builder` relay and is explicit that
//! its p50/p99 are a strict LOWER BOUND on real propagation, deferring the
//! authoritative number to "the Phase-B real-strfry e2e". THIS is that
//! measurement: it drives the same probe through a real `strfry` daemon (the
//! identical `dockurr/strfry` image + `strfry.conf` the e2e lanes provision), so
//! the sampled latency includes strfry's real ingest → match → broadcast path and
//! real WebSocket framing, not just an in-memory Rust relay.
//!
//! # Fork-safety, not latency
//!
//! A two-admin convergence that *misses* the settle window forks PERMANENTLY (a
//! twin fork — same epoch/member set, differing only in the exporter secret, so
//! only cross-decrypt detects it; proven by
//! `manager.rs::rev1_or_m11_two_admin_window_miss_forks_but_in_window_converges`).
//! The window is therefore sized as `>= 2x` the p99 of real commit propagation; a
//! window below real p99 forks in the field. This test asserts that inequality
//! against a real relay and prints the measured value for the `config.rs` doc.
//!
//! # Scope of a localhost `strfry`
//!
//! Pointed at a localhost `strfry` (the local reproduction; the Flutter e2e
//! lanes' strfry is host-local too, reached over the emulator loopback), the
//! sample captures the real relay-daemon + WS-framing cost but NOT wide-area
//! network RTT nor relay fan-out under load. Those terms are reasoned about
//! separately in the `config.rs` doc: even adding a generous WAN budget to the
//! measured p99 keeps the fork-safety inequality `window > 2x p99` with margin. To
//! fold in true WAN RTT, point `HAVEN_E2E_RELAY` at a remote relay you operate —
//! never a public relay, since the probe publishes throwaway `kind:445` events.
//!
//! # Running
//!
//! Env-gated: with `HAVEN_E2E_RELAY` UNSET the test is a green no-op (so the
//! default `cargo test` needs no relay). SET but unreachable/misconfigured it
//! FAILS loudly but BOUNDED (~15 s): `Client::send_event` swallows per-relay send
//! failures (returns `Ok`), so the actual guard is the per-sample
//! `assert!(await_unprocessable)` — not `engine.start`/`send_event`, which both
//! return `Ok`. A `ws://` loopback relay is permitted ONLY in a debug build (the
//! WSS gate's loopback opt-in is a no-op stub in release), so run this in debug
//! (the default for `cargo test`); the numbers above are debug-build timings.
//!
//! ```text
//! # start the pinned relay (mirrors tooling/e2e/ci/start-strfry.sh)
//! HAVEN_E2E_RELAY=ws://127.0.0.1:7777 \
//!   cargo test --test settle_window_real_relay_test -- --nocapture
//! ```

use std::sync::Arc;
use std::time::{Duration, Instant};

use haven_core::circle::CircleManager;
use haven_core::relay::live_sync::{
    CircleSpec, LiveSyncCore, LiveSyncEvent, SyncStatusReason, COMMIT_SETTLE_WINDOW_SECS,
};
use nostr::{Alphabet, EventBuilder, Keys, Kind, SingleLetterTag, Tag, TagKind};
use nostr_sdk::Client;
use tempfile::TempDir;

/// Nearest-rank percentile over an ascending-sorted slice of millisecond
/// samples. `q_permille` is the quantile in per-mille (e.g. `990` == p99), kept
/// integer so the rank math needs no lossy float casts.
fn percentile(sorted_ms: &[f64], q_permille: usize) -> f64 {
    if sorted_ms.is_empty() {
        return 0.0;
    }
    let n = sorted_ms.len();
    // rank = ceil(q * n) via integer ceil-division, 1-indexed, clamped to [1, n].
    let rank = ((q_permille * n).div_ceil(1000)).clamp(1, n);
    sorted_ms[rank - 1]
}

/// A fresh, distinctly-signed `kind:445` carrying `#h = group_hex`. A fresh
/// signer per call ⇒ a distinct event id ⇒ no relay/pool dedup collision.
fn kind445_with_h(group_hex: &str) -> nostr::Event {
    EventBuilder::new(Kind::Custom(445), "opaque-ciphertext")
        .tags([Tag::custom(
            TagKind::SingleLetter(SingleLetterTag::lowercase(Alphabet::H)),
            [group_hex.to_string()],
        )])
        .sign_with_keys(&Keys::generate())
        .unwrap()
}

/// Waits for exactly one `Status{Unprocessable}` — the engine observed +
/// routed + processed our undecryptable event. Ignores other statuses; returns
/// `false` on timeout / channel close.
async fn await_unprocessable(rx: &mut tokio::sync::broadcast::Receiver<LiveSyncEvent>) -> bool {
    tokio::time::timeout(Duration::from_secs(5), async {
        loop {
            match rx.recv().await {
                Ok(LiveSyncEvent::Status {
                    reason: SyncStatusReason::Unprocessable,
                }) => break true,
                Ok(_) => {} // Connected / other status — keep waiting
                Err(_) => break false,
            }
        }
    })
    .await
    .unwrap_or(false)
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn p15_real_strfry_settle_window_exceeds_p99() {
    const SAMPLES: usize = 100;
    const WARMUP: usize = 5;

    // Env-gated: no relay configured ⇒ green no-op (keeps default `cargo test`
    // relay-free). A configured-but-unreachable/misconfigured relay FAILS below
    // (loud, bounded ~15 s) via the per-sample `assert!(await_unprocessable)` —
    // NOT via `engine.start`/`send_event`, which both return `Ok` (connect is
    // fire-and-forget; per-relay send failures are captured in the send output).
    let Some(url) = std::env::var("HAVEN_E2E_RELAY")
        .ok()
        .filter(|s| !s.is_empty())
    else {
        println!(
            "SKIP p15_real_strfry_settle_window_exceeds_p99: set \
             HAVEN_E2E_RELAY=ws://127.0.0.1:7777 (a real strfry daemon) to run the \
             authoritative settle-window measurement"
        );
        return;
    };

    // The engine enforces a WSS-only relay gate; arm the debug-only loopback
    // opt-in so a `ws://127.0.0.1` strfry is permitted (a no-op for a `wss://` URL).
    let _ = haven_core::relay::allow_ws_loopback_for_test();

    // Engine over an empty MLS store, subscribed to one circle. An undecryptable
    // 445 (no matching MLS group) yields Status{Unprocessable} — our probe.
    let dir = TempDir::new().unwrap();
    let circle = Arc::new(CircleManager::new_unencrypted(dir.path()).unwrap());
    let engine = LiveSyncCore::new_local(circle, Keys::generate().public_key());
    let group_hex = hex::encode([0x5Au8; 32]);
    engine
        .start(
            &[CircleSpec {
                group_id_hex: group_hex.clone(),
                relays: vec![url.clone()],
            }],
            &[],
        )
        .await
        .expect("engine starts and subscribes to the real relay");

    // Let the REQ register on the relay before publishing (mirrors the e2e test).
    tokio::time::sleep(Duration::from_millis(500)).await;

    let publisher = Client::builder().build();
    publisher
        .add_relay(&url)
        .await
        .expect("add the real relay to the publisher");
    publisher.connect().await;

    let mut rx = engine.bus().subscribe();
    let mut samples_ms: Vec<f64> = Vec::with_capacity(SAMPLES);

    for i in 0..(WARMUP + SAMPLES) {
        // Drain any stale bus events so each sample times only its own publish.
        while rx.try_recv().is_ok() {}

        let event = kind445_with_h(&group_hex);
        let t0 = Instant::now();
        publisher
            .send_event(&event)
            .await
            .expect("publish kind:445 to the real relay");
        assert!(
            await_unprocessable(&mut rx).await,
            "sample {i} must traverse the full path (publish → real strfry → engine observe)"
        );
        let elapsed_ms = t0.elapsed().as_secs_f64() * 1000.0;
        if i >= WARMUP {
            samples_ms.push(elapsed_ms);
        }
    }

    samples_ms.sort_by(|a, b| a.partial_cmp(b).unwrap());
    let p50 = percentile(&samples_ms, 500);
    let p99 = percentile(&samples_ms, 990);
    let max = *samples_ms.last().unwrap();
    // Lossless: the window (8000 ms) is far below f64's exact-integer range.
    let window_ms = f64::from(u32::try_from(COMMIT_SETTLE_WINDOW_SECS).unwrap()) * 1000.0;

    // A9 tuning record — greppable, always emitted (visible under `--nocapture`).
    println!(
        "P-15 REAL-STRFRY MEASUREMENT (relay={url}): \
         n={SAMPLES} p50={p50:.2}ms p99={p99:.2}ms max={max:.2}ms | \
         COMMIT_SETTLE_WINDOW_SECS={COMMIT_SETTLE_WINDOW_SECS}s ({window_ms:.0}ms) | \
         2xp99={:.2}ms",
        2.0 * p99
    );

    // Fork-safety gate: the window MUST exceed 2x the measured p99 of real
    // propagation. A window below real p99 forks a two-admin window-miss
    // permanently (see the module doc). This is the authoritative assertion the
    // in-process tuning test defers to.
    assert!(
        window_ms > 2.0 * p99,
        "settle window ({window_ms:.0}ms) must exceed 2x the real-relay p99 ({:.0}ms) \
         for fork-safety; a failure means COMMIT_SETTLE_WINDOW_SECS is too small for \
         this relay's propagation",
        2.0 * p99
    );

    engine.stop().await;
}
