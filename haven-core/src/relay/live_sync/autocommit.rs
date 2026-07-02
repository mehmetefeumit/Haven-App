//! Path-B auto-commit convergence (M6-2): the engine publishes + converges a
//! peer `SelfRemove` it auto-committed, in-Rust, without a Dart round-trip.
//!
//! When a peer's `SelfRemove` reaches the engine, MDK auto-commits it, leaving
//! the receiver holding its OWN unmerged pending commit ("regime 2"). Two members
//! doing this concurrently would each blind-merge their own commit and fork. So
//! [`super::processor::EngineProcessor::process_group_event`] opens a settle
//! window (under the worker's gate) the instant it sees the auto-commit, and
//! hands an [`AutoCommitWork`] to [`super::supervisor::run_worker`], which spawns
//! [`run_autocommit_converge`]. That task:
//!
//! 1. PUBLISHES the auto-commit so a sibling auto-committer can collect it as a
//!    competitor (Decision A — publish during the window, unconditionally);
//! 2. waits the settle window (no gate held);
//! 3. runs [`super::finalize::gated_converge`] with `CommitIntent::None` (we
//!    adopt a peer's change, nothing to re-stage), landing both members on the
//!    MIP-03 winner's branch;
//! 4. emits a post-converge `GroupUpdate{None}` for the UI (the roster changed).
//!
//! A publish failure or a converge error runs [`super::finalize::gated_abort`]
//! (clear the pending commit + close the window) so the circle is never left
//! wedged in regime 2.
//!
//! # Why in-Rust, not a Dart round-trip
//!
//! The auto-commit is *involuntary* (triggered by receiving someone else's
//! leave), so there may be no foreground flow to carry the converge to
//! completion. A Dart round-trip would dangle the pending commit if the app were
//! killed between the emit and the converge — the exact lifecycle this migration
//! fixes. In-Rust bounds the dangling window to the ≤8 s task lifetime; a
//! process kill mid-task self-heals on restart (the un-advanced cursor
//! re-delivers the `SelfRemove`; MDK's `stage_commit` overwrites the stale
//! pending commit and the engine re-runs path B).

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, PoisonError};
use std::time::Duration;

use nostr::{Event, JsonUtil};
use nostr_sdk::Client;

use crate::circle::{CircleManager, CommitIntent};
use crate::nostr::mls::types::GroupId;

use super::config::COMMIT_SETTLE_WINDOW_SECS;
use super::event::{LiveSyncEvent, SyncStatusReason};
use super::event_bus::EventBus;
use super::finalize::{gated_abort, gated_converge};
use super::gate::MlsWriteGate;
use super::session::engine_relay_allowed;
use super::settle::CommitSettleBuffer;

/// Bounded publish attempts for an auto-commit (initial + retries).
const PUBLISH_ATTEMPTS: u32 = 3;
/// Backoff between publish attempts.
const PUBLISH_BACKOFF: Duration = Duration::from_secs(2);
/// Per-attempt publish timeout.
const PUBLISH_TIMEOUT: Duration = Duration::from_secs(10);

/// The work item handed from `process_group_event` (which already opened the
/// settle window under the gate) to `run_worker`, which spawns the converge task.
///
/// Carries the real `mls_group_id` (in-crate only — never the FFI) for
/// `converge_commit`. `Debug` is presence-only (Security Rule 4/8).
#[derive(Clone, PartialEq, Eq)]
pub struct AutoCommitWork {
    /// The real MLS group id (in-crate only) for `converge_commit`.
    pub mls_group_id: GroupId,
    /// The circle's pseudonymous `nostr_group_id` (gate/settle key + UI event).
    pub nostr_group_id: Vec<u8>,
    /// The epoch the auto-commit was built from (pending didn't advance it).
    pub staged_epoch: u64,
    /// The staged auto-commit `kind:445` JSON to publish + converge.
    pub commit_json: String,
}

impl std::fmt::Debug for AutoCommitWork {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("AutoCommitWork")
            .field("staged_epoch", &self.staged_epoch)
            .finish_non_exhaustive()
    }
}

/// The engine handles the converge task needs. All fields are cheap clones
/// (`Client`/`EventBus` are `Arc`-internal) so the spawned task owns its copy and
/// borrows nothing from the worker's stack.
#[derive(Clone)]
pub struct EngineHandles {
    /// The engine client (for the publish).
    pub client: Client,
    /// The shared MLS-state owner (for `converge_commit`).
    pub circle: Arc<CircleManager>,
    /// The per-circle write gate (serializes vs the engine worker + foreground).
    pub gate: Arc<MlsWriteGate>,
    /// The shared settle buffer.
    pub settle: Arc<Mutex<CommitSettleBuffer>>,
    /// The event bus (for the post-converge UI emit).
    pub bus: EventBus,
    /// The session shutdown flag — the task bails to abort if `stop` ran.
    pub shutdown: Arc<AtomicBool>,
}

/// Closes a circle's settle window on drop — but ONLY if it is still THIS task's
/// window (same `staged_epoch`), so a normal completion (which already closed it
/// via `gated_converge`/`gated_abort`) is a no-op and a newer window opened by a
/// foreground finalize is never clobbered. The close is synchronous (std settle
/// mutex, poison-recovered); no MDK mutation happens here.
struct WindowCloseGuard {
    settle: Arc<Mutex<CommitSettleBuffer>>,
    hex: String,
    staged_epoch: u64,
}

impl Drop for WindowCloseGuard {
    fn drop(&mut self) {
        let mut sb = self.settle.lock().unwrap_or_else(PoisonError::into_inner);
        // Only close OUR window: if it was already closed (success) this is None;
        // if a newer window (different epoch) is open, leave it untouched.
        if sb.window_staged_epoch(&self.hex) == Some(self.staged_epoch) {
            sb.close_window(&self.hex);
        }
    }
}

/// Publishes + converges an auto-committed peer `SelfRemove`, in-Rust, under the
/// per-circle gate.
///
/// Spawned (detached) by `run_worker`; the engine has no `JoinSet`, and the task
/// is bounded to one per circle (a second auto-commit for the same circle hits
/// the open window → regime 2 → buffered, no second spawn).
pub async fn run_autocommit_converge(handles: EngineHandles, work: AutoCommitWork) {
    // Liveness backstop: guarantee THIS task's settle window is closed on EVERY
    // exit — normal, abort, OR a panic inside `gated_converge` (e.g. MDK on
    // adversarial ciphertext). `tokio::spawn` swallows a task panic, so without
    // this guard a panic after the window opened (in `process_group_event`) would
    // wedge the circle in regime 2 (buffer-not-decrypt) for the rest of the
    // process lifetime. The window is in-memory, so this fully closes the
    // in-process wedge; a dangling pending commit self-heals via cursor
    // re-delivery + MDK `stage_commit` overwrite.
    let _window_guard = WindowCloseGuard {
        settle: Arc::clone(&handles.settle),
        hex: hex::encode(&work.nostr_group_id),
        staged_epoch: work.staged_epoch,
    };

    // Shutting down (stop_session ran): abort cleanly — do not mutate MLS state
    // or publish after the session was torn down.
    if handles.shutdown.load(Ordering::Acquire) {
        gated_abort(
            &handles.gate,
            &handles.settle,
            &handles.circle,
            &work.mls_group_id,
            &work.nostr_group_id,
        )
        .await;
        return;
    }

    // 1. Publish the auto-commit during the window so a sibling auto-committer
    //    collects it (required for cross-member convergence).
    let relays = handles
        .circle
        .get_circle(&work.mls_group_id)
        .ok()
        .flatten()
        .map_or_else(Vec::new, |c| c.circle.relays);
    if !publish_commit(&handles.client, &relays, &work.commit_json).await {
        // Could not publish → don't leave a dangling pending commit / open window.
        gated_abort(
            &handles.gate,
            &handles.settle,
            &handles.circle,
            &work.mls_group_id,
            &work.nostr_group_id,
        )
        .await;
        handles.bus.send(LiveSyncEvent::Status {
            reason: SyncStatusReason::RelayError,
        });
        return;
    }

    // 2. Wait the settle window so a concurrent sibling auto-commit buffers. NO
    //    gate/settle guard is held across this sleep (holding the gate would block
    //    the engine worker + foreground for the whole window).
    tokio::time::sleep(Duration::from_secs(COMMIT_SETTLE_WINDOW_SECS)).await;

    if handles.shutdown.load(Ordering::Acquire) {
        gated_abort(
            &handles.gate,
            &handles.settle,
            &handles.circle,
            &work.mls_group_id,
            &work.nostr_group_id,
        )
        .await;
        return;
    }

    // 3. Converge under the gate (intent None — adopting a peer's change).
    let converged = gated_converge(
        &handles.gate,
        &handles.settle,
        &handles.circle,
        &work.mls_group_id,
        &work.nostr_group_id,
        &work.commit_json,
        work.staged_epoch,
        &CommitIntent::None,
    )
    .await
    .is_ok();

    if converged {
        // UI: the roster changed (a member left). The commit is applied; the FFI
        // consumer just refreshes — it owes no publish/merge.
        handles.bus.send(LiveSyncEvent::GroupUpdate {
            nostr_group_id: work.nostr_group_id,
            evolution_event_json: None,
        });
    } else {
        // Convergence failed (e.g. an unparseable competitor); leave nothing
        // dangling and surface a status.
        gated_abort(
            &handles.gate,
            &handles.settle,
            &handles.circle,
            &work.mls_group_id,
            &work.nostr_group_id,
        )
        .await;
        handles.bus.send(LiveSyncEvent::Status {
            reason: SyncStatusReason::Unprocessable,
        });
    }
}

/// Publishes `commit_json` to the circle's relays via the (already-connected)
/// engine `Client`, with a bounded retry.
///
/// - WSS-gates every target (mirrors the engine's H1 start gate); a plaintext
///   `ws://` is skipped (the loopback opt-in still permits a test relay).
/// - `add_relay`s each target before sending (idempotent): a relay that joined
///   `Circle.relays` after `start` via a `resync` may not be in the pool yet, and
///   `send_event_to` fails closed (`RelayNotFound`) if any target is absent.
/// - Treats "relays reached but none acknowledged" (empty `success` set) as
///   retryable — the cold-connection failure mode — so a first publish is not
///   silently dropped.
///
/// Returns `true` once at least one relay accepts the event.
async fn publish_commit(client: &Client, relays: &[String], commit_json: &str) -> bool {
    let Ok(event) = Event::from_json(commit_json) else {
        return false;
    };
    let targets: Vec<&String> = relays.iter().filter(|r| engine_relay_allowed(r)).collect();
    if targets.is_empty() {
        return false;
    }
    for url in &targets {
        let _ = client.add_relay(url.as_str()).await;
    }
    client.connect().await;

    for attempt in 0..PUBLISH_ATTEMPTS {
        if attempt > 0 {
            tokio::time::sleep(PUBLISH_BACKOFF).await;
        }
        let send = tokio::time::timeout(
            PUBLISH_TIMEOUT,
            client.send_event_to(targets.iter().map(|s| s.as_str()), &event),
        )
        .await;
        if let Ok(Ok(output)) = send {
            // At least one relay accepted ⇒ done. An empty success set means the
            // relays were reached but none acked (cold connection) — retry.
            if !output.success.is_empty() {
                return true;
            }
        }
    }
    false
}

#[cfg(test)]
mod tests {
    use std::sync::atomic::AtomicBool;

    use nostr::{EventBuilder, Keys, Kind};
    use nostr_relay_builder::MockRelay;
    use nostr_sdk::Client;
    use tempfile::TempDir;

    use crate::circle::CircleManager;

    use super::*;

    fn synthetic_commit_json() -> String {
        EventBuilder::new(Kind::Custom(445), "opaque-commit")
            .sign_with_keys(&Keys::generate())
            .unwrap()
            .as_json()
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn publish_commit_sends_to_the_relay() {
        let _ = crate::relay::allow_ws_loopback_for_test();
        let relay = MockRelay::run().await.unwrap();
        let url = relay.url().await.to_string();
        let client = Client::builder().build();

        let ok = publish_commit(&client, &[url], &synthetic_commit_json()).await;
        assert!(ok, "publish must succeed against a reachable relay");
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn publish_commit_fails_with_no_relays() {
        let client = Client::builder().build();
        assert!(!publish_commit(&client, &[], &synthetic_commit_json()).await);
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn publish_commit_filters_plaintext_ws_non_loopback() {
        // A non-loopback ws:// is WSS-gated out → no targets → fail closed
        // (without ever opening a plaintext standing connection).
        let client = Client::builder().build();
        let ok = publish_commit(
            &client,
            &["ws://malicious.example".to_string()],
            &synthetic_commit_json(),
        )
        .await;
        assert!(!ok, "a plaintext ws:// target must be filtered out");
    }

    #[test]
    fn window_close_guard_closes_its_own_window_on_drop() {
        // Liveness backstop (marmot H1/H2): a dropped/panicked task closes its
        // window so the circle isn't wedged in regime 2.
        let settle = Arc::new(Mutex::new(CommitSettleBuffer::new()));
        let hex = "aa00".to_string();
        let _ = settle.lock().unwrap().begin_window(&hex, 5, i64::MAX);
        {
            let _g = WindowCloseGuard {
                settle: Arc::clone(&settle),
                hex: hex.clone(),
                staged_epoch: 5,
            };
            assert!(settle.lock().unwrap().has_window(&hex));
        } // guard drops here
        assert!(
            !settle.lock().unwrap().has_window(&hex),
            "the guard closes its own window on drop"
        );
    }

    #[test]
    fn window_close_guard_never_clobbers_a_newer_window() {
        // If our window was already closed and a foreground finalize opened a
        // NEW window (different epoch) for the same circle, the guard must leave
        // it untouched.
        let settle = Arc::new(Mutex::new(CommitSettleBuffer::new()));
        let hex = "aa00".to_string();
        {
            let _g = WindowCloseGuard {
                settle: Arc::clone(&settle),
                hex: hex.clone(),
                staged_epoch: 5,
            };
            // A newer (epoch-9) window appears after ours was already closed.
            let _ = settle.lock().unwrap().begin_window(&hex, 9, i64::MAX);
        } // guard drops here
        let staged = settle.lock().unwrap().window_staged_epoch(&hex);
        assert_eq!(
            staged,
            Some(9),
            "the guard must not clobber a newer (different-epoch) window"
        );
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn converge_task_bails_to_abort_when_shutting_down() {
        // S4: if the session is shutting down, the task must abort cleanly (no
        // publish, no 8s wait, no post-stop MLS mutation beyond the idempotent
        // clear/close). gated_abort on a circle with no such group is a no-op.
        let dir = TempDir::new().unwrap();
        let circle = Arc::new(CircleManager::new_unencrypted(dir.path()).unwrap());
        let handles = EngineHandles {
            client: Client::builder().build(),
            circle,
            gate: Arc::new(MlsWriteGate::new()),
            settle: Arc::new(Mutex::new(CommitSettleBuffer::new())),
            bus: EventBus::new(),
            shutdown: Arc::new(AtomicBool::new(true)), // already shutting down
        };
        let work = AutoCommitWork {
            mls_group_id: GroupId::from_slice(&[0xAB; 32]),
            nostr_group_id: vec![0xAB; 32],
            staged_epoch: 1,
            commit_json: synthetic_commit_json(),
        };
        // Must return promptly (the shutdown branch), not block on the window.
        tokio::time::timeout(
            std::time::Duration::from_secs(2),
            run_autocommit_converge(handles, work),
        )
        .await
        .expect("shutdown bail must return without the settle wait");
    }
}
