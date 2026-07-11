//! P-15 (plan A6): empirical lower-bound justification for
//! `COMMIT_SETTLE_WINDOW_SECS` (`haven-core/src/relay/live_sync/config.rs:61`).
//!
//! Measures the engine's `publish → observe` pipeline latency over an in-process
//! `MockRelay`, sampled N times, and asserts the settle window sits safely ABOVE
//! `2×p99` (the fork-safety lower bound) and at/below the membership-op UX ceiling.
//!
//! # What the in-process relay does and does NOT bound
//!
//! This uses `nostr-relay-builder`'s loopback, in-process relay. Its testing
//! options expose only `unresponsive_connection` (a connect-time stall) and
//! `send_random_events` (noise) — NEITHER injects per-event WAN fan-out latency.
//! So the measured p50/p99 bound ONLY the engine's local receive pipeline
//! (loopback WS framing + the pool→receiver broadcast hop + the receiver→worker
//! mpsc + decrypt-attempt + bus emit). They are a strict LOWER BOUND on real
//! strfry WAN propagation.
//!
//! The default `MockRelay` throttles ingestion to `notes_per_minute = 60` (a
//! token bucket), which would rate-limit the throughput sweep; this test builds
//! a `LocalRelay` with the limit raised. That is an in-process test artifact —
//! it does not affect per-event latency (which is what we sample) or the WAN
//! caveat above.
//!
//! Two SANITY bounds guard the LOCAL pipeline (neither is a WAN-latency claim):
//!   * LOWER — `window > 2×p99`: the window must dwarf the fastest-possible
//!     pipeline. It trips only if the window constant shrank toward the measured
//!     p99 (sub-second) or a CATASTROPHIC stall inflated local p99 past ~4 s
//!     (`window/2`). Its enormous headroom (8000 ms vs ~10 ms) is why the upper
//!     bound below also exists.
//!   * UPPER — `p99 < 1000 ms`: a ~200× ceiling over the observed ~3–5 ms local
//!     p99 that catches a pipeline-latency REGRESSION of hundreds of ms (which the
//!     lower bound's headroom would otherwise hide), while staying non-flaky under
//!     CI scheduling noise.
//!
//! Neither validates production WAN latency; the authoritative WAN p99 gate is the
//! Phase-B real-strfry e2e (rollout §7 / scenario b), NOT this test.
//!
//! Run with `--nocapture` to record the numbers for the A9 tuning doc:
//! `cargo test --test settle_window_tuning_test -- --nocapture`.

use std::sync::Arc;
use std::time::{Duration, Instant};

use haven_core::circle::CircleManager;
use haven_core::relay::live_sync::{
    CircleSpec, LiveSyncCore, LiveSyncEvent, SyncStatusReason, COMMIT_SETTLE_WINDOW_SECS,
};
use nostr::{Alphabet, EventBuilder, Keys, Kind, SingleLetterTag, Tag, TagKind};
use nostr_relay_builder::builder::RateLimit;
use nostr_relay_builder::{LocalRelay, RelayBuilder};
use nostr_sdk::Client;
use tempfile::TempDir;

/// The window itself must stay `<=` this so the full membership op (window +
/// publish + converge) fits the ~12 s responsive budget (rollout §7).
const WINDOW_UX_CEILING_SECS: u64 = 10;

/// Compile-time UX-budget guard (the A6 upper bound): a change that raised the
/// window past the ceiling fails the BUILD, not merely this test.
const _: () = assert!(COMMIT_SETTLE_WINDOW_SECS <= WINDOW_UX_CEILING_SECS);

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
/// signer per call ⇒ a distinct event id ⇒ no pool-dedup collision.
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
async fn p15_settle_window_exceeds_local_pipeline_p99_and_fits_ux_budget() {
    // Measured samples + warm-up (cold-connect) samples to discard.
    const SAMPLES: usize = 100;
    const WARMUP: usize = 5;
    // The upper (UX-budget) bound is enforced at COMPILE TIME by the
    // `WINDOW_UX_CEILING_SECS` const-assert above; this test measures the lower
    // (fork-safety) bound.

    // The engine enforces a WSS-only gate; arm the debug-only loopback opt-in so
    // the in-process `ws://127.0.0.1` relay is permitted for this test.
    let _ = haven_core::relay::allow_ws_loopback_for_test();
    // Raise the default 60-notes/minute ingestion cap so the throughput sweep is
    // not throttled (an in-process artifact; does not affect per-event latency).
    let relay = LocalRelay::new(RelayBuilder::default().rate_limit(RateLimit {
        max_reqs: 500,
        notes_per_minute: 1_000_000,
    }));
    relay.run().await.expect("local relay starts");
    let url = relay.url().await.to_string();

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
        .expect("engine starts and subscribes");

    // Let the REQ register on the relay before publishing (mirrors the e2e test).
    tokio::time::sleep(Duration::from_millis(500)).await;

    let publisher = Client::builder().build();
    publisher.add_relay(&url).await.unwrap();
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
            .expect("publish kind:445");
        assert!(
            await_unprocessable(&mut rx).await,
            "sample {i} must traverse the full receive path (publish → observe)"
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
        "P-15 MEASUREMENT (MockRelay in-process LOWER BOUND — NOT WAN): \
         n={SAMPLES} p50={p50:.2}ms p99={p99:.2}ms max={max:.2}ms | \
         COMMIT_SETTLE_WINDOW_SECS={COMMIT_SETTLE_WINDOW_SECS}s ({window_ms:.0}ms) | \
         2xp99={:.2}ms",
        2.0 * p99
    );

    // Lower-bound fork-safety sanity: the window must dwarf the local p99. This
    // does NOT validate WAN p99 (see the module doc) — that is the Phase-B gate.
    assert!(
        window_ms > 2.0 * p99,
        "settle window ({window_ms:.0}ms) must exceed 2x the local p99 ({:.0}ms); \
         a failure means the window shrank or the pipeline stalled",
        2.0 * p99
    );

    // Upper-bound regression guard: the local p99 must stay far below a ~200x
    // ceiling over its observed value (~3-5 ms). The lower bound's enormous
    // headroom (8000 ms vs ~10 ms) would hide a pipeline-latency regression of
    // hundreds of ms; this ceiling catches such a stall while staying non-flaky
    // under CI scheduling noise. It is a LOCAL-pipeline guard, NOT a WAN claim.
    assert!(
        p99 < 1000.0,
        "local pipeline p99 ({p99:.0}ms) must stay under the 1000ms regression \
         ceiling (observed ~3-5ms); a failure means the receive pipeline stalled"
    );

    engine.stop().await;
}
