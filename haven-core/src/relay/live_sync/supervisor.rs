//! The receive supervisor: a RAW `client.notifications()` loop, decoupled from
//! decrypt by a bounded channel, with the per-circle write gate held around the
//! MLS-mutating processor call.
//!
//! # Why a raw loop (not `handle_notifications`)
//!
//! `Client::handle_notifications` exits permanently on a single broadcast
//! `Lagged` (it treats both `Lagged` and `Closed` as a clean stop). A slow
//! `SQLCipher` decrypt could lag the pool's notification channel and silently
//! kill the receive path forever. Instead [`run_receiver`] consumes
//! `client.notifications()` directly, treats `Lagged` as `continue` (the cursor
//! and catch-up replay anything skipped) and only `Closed`/`Shutdown` as a stop.
//! It also **decouples** receive from decrypt: it only `try_send`s onto a
//! bounded channel so the notification consumer never blocks, while a separate
//! [`run_worker`] drains that channel and runs the (blocking) decrypt.
//!
//! # The write-gate contract (security/protocol must-fix)
//!
//! Every MLS-mutating call must be serialized against the foreground
//! finalize/converge writer that shares the same `CircleManager`. [`run_worker`]
//! acquires `gate.for_group(hex).lock().await` around
//! [`super::EngineProcessor::process_group_event`]; the foreground finalize site
//! (M6) MUST acquire the same per-circle lock around its converge/merge.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, PoisonError};

use nostr::{Event, RelayUrl, SubscriptionId};
use nostr_sdk::RelayPoolNotification;
use tokio::sync::broadcast::error::RecvError;
use tokio::sync::{broadcast, mpsc, RwLock};

use super::autocommit::{run_autocommit_converge, ConvergeInflightGuard, EngineHandles};
use super::event::SyncStatusReason;
use super::planes::PlaneKind;
use super::processor::{EngineProcessor, GroupProcessOutcome};
use super::router::Router;

/// One routed relay event handed from the receiver to the worker.
#[derive(Debug, Clone)]
pub struct RawEvent {
    /// Relay the event arrived on.
    pub relay_url: RelayUrl,
    /// Subscription it matched.
    pub subscription_id: SubscriptionId,
    /// The event itself (relay-public; first-seen, never our own — pool dedup).
    pub event: Event,
}

/// What the receiver loop should do with one pool notification.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NotifDisposition {
    /// A first-seen `Event`: extract + forward to the worker.
    Forward,
    /// The pool shut down: stop the loop cleanly.
    Stop,
    /// A `Message`/auth/other notification we don't act on.
    Ignore,
}

/// Classifies one pool notification (pure; testable without a runtime).
#[must_use]
pub const fn notification_disposition(n: &RelayPoolNotification) -> NotifDisposition {
    match n {
        RelayPoolNotification::Event { .. } => NotifDisposition::Forward,
        RelayPoolNotification::Shutdown => NotifDisposition::Stop,
        RelayPoolNotification::Message { .. } => NotifDisposition::Ignore,
    }
}

/// Extracts the `#h` tag value (`hex(nostr_group_id)`) from a `kind:445` event.
///
/// Returns `None` when the event carries no `#h` tag. Pure / allocation-light;
/// the engine routes by this value and never touches the real MLS group id.
#[must_use]
pub fn extract_group_id_hex(event: &Event) -> Option<String> {
    // A `#h` tag serializes as `["h", "<hex(nostr_group_id)>"]`.
    event.tags.iter().find_map(|t| {
        let slice = t.as_slice();
        if slice.first().map(String::as_str) == Some("h") {
            slice.get(1).cloned()
        } else {
            None
        }
    })
}

/// The canonical per-circle gate/settle key: lowercase hex of the decoded
/// `nostr_group_id` bytes, NOT the raw `#h` tag string (L2).
///
/// A relay could echo an uppercase `#h`; keying the gate by the raw tag would
/// then take a DIFFERENT `Arc<Mutex>` than the lowercase key the finalize site
/// and the path-B converge task use (`hex::encode(nostr_group_id)`), so the two
/// MLS writers would fail to serialize → fork. Routing the key through this
/// helper makes the invariant local instead of emergent.
#[must_use]
pub fn canonical_group_hex(nostr_group_id: &[u8]) -> String {
    hex::encode(nostr_group_id)
}

/// The RAW notifications receiver: forwards first-seen events onto `tx`, never
/// blocking on decrypt, surviving `Lagged`, stopping only on `Closed`/`Shutdown`
/// or the explicit `shutdown` flag.
pub async fn run_receiver(
    mut notifications: broadcast::Receiver<RelayPoolNotification>,
    tx: mpsc::Sender<RawEvent>,
    shutdown: Arc<AtomicBool>,
) {
    loop {
        if shutdown.load(Ordering::Acquire) {
            break;
        }
        match notifications.recv().await {
            Ok(n) => match notification_disposition(&n) {
                NotifDisposition::Forward => {
                    if let RelayPoolNotification::Event {
                        relay_url,
                        subscription_id,
                        event,
                    } = n
                    {
                        // try_send (never await) so the notification consumer
                        // cannot lag the pool; a full channel drops to cursor
                        // replay, never to a wedged receiver.
                        let _ = tx.try_send(RawEvent {
                            relay_url,
                            subscription_id,
                            event: *event,
                        });
                    }
                }
                NotifDisposition::Stop => break,
                NotifDisposition::Ignore => {}
            },
            // A lagged broadcast must NOT kill the receiver (the cursor +
            // catch-up are the net); the loop simply iterates again. Only a
            // closed channel stops it.
            Err(RecvError::Lagged(_)) => {}
            Err(RecvError::Closed) => break,
        }
    }
}

/// The decrypt worker: drains `rx`, routes each event, and runs the processor
/// with the per-circle write gate held (the MLS-write serialization must-fix).
///
/// On a path-B auto-commit it spawns the in-Rust converge task from `handles`.
pub async fn run_worker(
    mut rx: mpsc::Receiver<RawEvent>,
    router: Arc<RwLock<Router>>,
    processor: Arc<EngineProcessor>,
    handles: EngineHandles,
) {
    while let Some(raw) = rx.recv().await {
        // Resolve the subscription context (cloned so the router lock is not
        // held across the decrypt).
        let ctx = {
            router
                .read()
                .await
                .lookup(raw.relay_url.as_str(), &raw.subscription_id)
                .cloned()
        };
        let Some(ctx) = ctx else { continue };

        match ctx.plane {
            PlaneKind::Inbox => processor.process_inbox_event(&raw.event),
            PlaneKind::Group => {
                let Some(routed_hex) = extract_group_id_hex(&raw.event) else {
                    continue;
                };
                // Drop an `#h` this subscription did not multiplex (a relay
                // echoing an unrequested circle).
                if !ctx.group_ids_hex.contains(&routed_hex) {
                    continue;
                }
                let Ok(nostr_group_id) = hex::decode(&routed_hex) else {
                    continue;
                };
                // L2: key the gate by the canonical lowercase hex of the decoded
                // bytes, NOT the raw `#h` tag string, so it matches the finalize
                // site + the path-B converge task and they genuinely serialize.
                let group_hex = canonical_group_hex(&nostr_group_id);
                // THE write-gate must-fix: hold the per-circle lock around the
                // MLS-mutating processor call so the engine never races the
                // foreground converge/finalize writer on shared MDK state.
                let lock = handles.gate.for_group(&group_hex);
                let guard = lock.lock().await;
                // Snapshot whether a settle window already exists for this circle
                // BEFORE the call (under the gate). A window that pre-exists our
                // call belongs to ANOTHER writer — a foreground finalize that
                // opened its window under the gate and then released it during its
                // publish+wait phase (regime 2). We must never close that window
                // (doing so drops its fork protection). Only the regime-1
                // AutoCommit path inside `process_group_event` opens a window, and
                // that path is reached only when NO window pre-existed. So
                // `!had_window_before` is exactly "any window now present was
                // opened by THIS call" — the only window a panic-close may touch.
                let had_window_before = {
                    let sb = handles
                        .settle
                        .lock()
                        .unwrap_or_else(PoisonError::into_inner);
                    sb.window_staged_epoch(&group_hex).is_some()
                };
                // Panic isolation (symmetric to surviving Lagged): a panic deep
                // in MDK decrypt on adversarial ciphertext must NOT kill the
                // worker — that would silently blind the whole receive path
                // (the receiver would keep filling a never-drained channel). The
                // processor call is synchronous, so `AssertUnwindSafe` is sound.
                let process_started = std::time::Instant::now();
                let outcome = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                    processor.process_group_event(&raw.event, &nostr_group_id)
                }));
                // Diagnostic (M11 e2e triage): time each engine decrypt/process AND
                // record the outcome variant, so the drive log distinguishes
                // `Buffered` (regime 2 — a settle window is open, so the event is NOT
                // decrypted/delivered) from `Processed` (regime 1 — decrypted + emitted
                // on the bus) from `AutoCommitStaged`. A circle whose live locations
                // never surface but whose events all log `Buffered` is stuck in an
                // open settle window; `Processed` events that never reach the UI point
                // downstream (bus→FFI stream→Dart consumer). The elapsed ms already
                // ruled out slow/starved decrypt (all << 1 s). `GroupProcessOutcome`'s
                // `Debug` is presence-only for the path-B work item (redacted), so this
                // logs only the pseudonymous group prefix + duration + variant — never
                // decrypted content or key material (Security Rule 6).
                let outcome_label = outcome
                    .as_ref()
                    .map_or_else(|_| "panic".to_string(), |o| format!("{o:?}"));
                log::debug!(
                    "[live_sync::worker] process_group_event group={}… took {}ms → {}",
                    group_hex.get(..8).unwrap_or(group_hex.as_str()),
                    process_started.elapsed().as_millis(),
                    outcome_label
                );

                match outcome {
                    Ok(GroupProcessOutcome::AutoCommitStaged(work)) => {
                        // Path B: process_group_event opened the settle window
                        // under the gate; release the gate, then spawn the in-Rust
                        // publish+converge task. Detached — bounded to one per
                        // circle (a sibling auto-commit for the same circle hits
                        // the open window → regime 2 → buffered, no 2nd spawn).
                        drop(guard);
                        // Register the in-flight converge BEFORE spawning (the
                        // guard's fetch_add) and MOVE the guard into the future so
                        // it is owned from creation and drops only when the whole
                        // task — incl. `gated_converge` — returns. `stop`'s drain
                        // then provably waits for any epoch-advancing converge.
                        let inflight_guard =
                            ConvergeInflightGuard::new(Arc::clone(&handles.converge_inflight));
                        let converge_handles = handles.clone();
                        let converge_work = *work;
                        tokio::spawn(async move {
                            let _inflight_guard = inflight_guard;
                            run_autocommit_converge(converge_handles, converge_work).await;
                        });
                    }
                    Ok(_) => drop(guard),
                    Err(_) => {
                        // M2: a panic MAY have opened a settle window
                        // (`begin_window` runs before the `AutoCommitStaged`
                        // return) without spawning the converge task → the circle
                        // would wedge in regime 2 forever. Defensively close the
                        // window — but ONLY if THIS call opened it
                        // (`!had_window_before`), and while STILL HOLDING the gate
                        // so a concurrent foreground finalize cannot open/displace
                        // a window in the gap. This never clobbers another writer's
                        // in-flight window (which would itself cause the fork this
                        // milestone prevents). (A dangling pending commit from an
                        // MDK panic mid-auto-commit self-heals via `stage_commit`
                        // overwrite on the next delivery + `propose_leave`'s
                        // pre-clear.)
                        if !had_window_before {
                            let mut sb = handles
                                .settle
                                .lock()
                                .unwrap_or_else(PoisonError::into_inner);
                            sb.close_window(&group_hex);
                        }
                        drop(guard);
                        processor.emit_status(SyncStatusReason::Unprocessable);
                    }
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use nostr::{Alphabet, EventBuilder, Keys, Kind, SingleLetterTag};

    fn commit_event_with_h(h_value: &str) -> Event {
        EventBuilder::new(Kind::Custom(445), "ciphertext")
            .tags(vec![nostr::Tag::custom(
                nostr::TagKind::SingleLetter(SingleLetterTag::lowercase(Alphabet::H)),
                [h_value],
            )])
            .sign_with_keys(&Keys::generate())
            .unwrap()
    }

    #[test]
    fn extract_h_tag_reads_the_group_hex() {
        let ev = commit_event_with_h("aa00bb11");
        assert_eq!(extract_group_id_hex(&ev), Some("aa00bb11".to_string()));
    }

    #[test]
    fn canonical_group_hex_is_lowercase_regardless_of_tag_case() {
        // L2: an uppercase #h tag decodes to the same bytes and re-encodes to the
        // SAME lowercase gate key the finalize/path-B sites use, so all MLS
        // writers for a circle take one Arc<Mutex> and serialize.
        let bytes = [0xAB, 0xCD, 0xEFu8];
        assert_eq!(canonical_group_hex(&bytes), "abcdef");
        // Both an upper- and lower-cased #h tag canonicalize identically.
        let from_upper = canonical_group_hex(&hex::decode("ABCDEF").unwrap());
        let from_lower = canonical_group_hex(&hex::decode("abcdef").unwrap());
        assert_eq!(from_upper, from_lower);
        assert_eq!(from_upper, "abcdef");
    }

    #[test]
    fn extract_h_tag_absent_yields_none() {
        let ev = EventBuilder::new(Kind::Custom(445), "x")
            .sign_with_keys(&Keys::generate())
            .unwrap();
        assert_eq!(extract_group_id_hex(&ev), None);
    }

    #[test]
    fn notification_disposition_classifies_each_arm() {
        let ev = commit_event_with_h("aa00");
        let event_notif = RelayPoolNotification::Event {
            relay_url: RelayUrl::parse("wss://relay.example").unwrap(),
            subscription_id: SubscriptionId::new("sub"),
            event: Box::new(ev),
        };
        assert_eq!(
            notification_disposition(&event_notif),
            NotifDisposition::Forward
        );
        assert_eq!(
            notification_disposition(&RelayPoolNotification::Shutdown),
            NotifDisposition::Stop
        );
    }
}

/// Panic-isolation (R6 / GAP-A) and Lagged/Closed-survival (R7 / GAP-B+F) tests
/// that drive the real `run_worker` / `run_receiver` loops with in-process
/// channels — no relay needed, fully deterministic.
#[cfg(test)]
mod supervisor_isolation_tests {
    use std::collections::HashSet;
    use std::sync::atomic::{AtomicBool, AtomicUsize};
    use std::sync::{Arc, Mutex};
    use std::time::Duration;

    use nostr::{
        Alphabet, EventBuilder, Keys, Kind, RelayUrl, SingleLetterTag, SubscriptionId, Tag, TagKind,
    };
    use nostr_sdk::{Client, RelayPoolNotification};
    use tempfile::TempDir;
    use tokio::sync::{broadcast, mpsc, RwLock};

    use super::{run_receiver, run_worker, RawEvent};
    use crate::circle::CircleManager;
    use crate::relay::live_sync::{
        CommitSettleBuffer, EngineHandles, EngineProcessor, EventBus, LiveSyncEvent, MlsWriteGate,
        Router, SyncStatusReason,
    };

    /// A `kind:445` carrying `#h = group_hex`, with `content`.
    fn event_445(group_hex: &str, content: &str) -> nostr::Event {
        EventBuilder::new(Kind::Custom(445), content)
            .tags(vec![Tag::custom(
                TagKind::SingleLetter(SingleLetterTag::lowercase(Alphabet::H)),
                [group_hex.to_string()],
            )])
            .sign_with_keys(&Keys::generate())
            .unwrap()
    }

    /// R6 (GAP-A): a panic deep in the decrypt call (via the `#[cfg(test)]`
    /// content sentinel) must be CAUGHT by `run_worker`'s `catch_unwind` — the
    /// worker surfaces `Unprocessable` and KEEPS DRAINING, so a single adversarial
    /// event can never silently blind the receive path. Proven by requiring the
    /// worker to also process the NEXT event (>= 2 `Unprocessable` emits). A dead
    /// worker would emit at most one, then wedge (the harness times out at 0/1).
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn run_worker_survives_a_processor_panic_and_keeps_processing() {
        let dir = TempDir::new().unwrap();
        let circle = Arc::new(CircleManager::new_unencrypted(dir.path()).unwrap());
        let settle = Arc::new(Mutex::new(CommitSettleBuffer::new()));
        let bus = EventBus::new();
        let mut rx = bus.subscribe();
        let processor = Arc::new(EngineProcessor::new(
            Arc::clone(&circle),
            Arc::clone(&settle),
            bus.clone(),
        ));

        let group_hex = hex::encode([0x99u8; 32]);
        let sub = SubscriptionId::new("s_group_0");
        let relay = "wss://relay.example".to_string();
        let router = Arc::new(RwLock::new(Router::new()));
        router.write().await.register_group(
            std::slice::from_ref(&relay),
            &sub,
            &HashSet::from([group_hex.clone()]),
        );

        let (tx, worker_rx) = mpsc::channel::<RawEvent>(16);
        let handles = EngineHandles {
            client: Client::builder().build(),
            circle,
            gate: Arc::new(MlsWriteGate::new()),
            settle,
            bus,
            shutdown: Arc::new(AtomicBool::new(false)),
            converge_inflight: Arc::new(AtomicUsize::new(0)),
        };
        tokio::spawn(run_worker(
            worker_rx,
            Arc::clone(&router),
            processor,
            handles,
        ));

        let raw = |content: &str| RawEvent {
            relay_url: RelayUrl::parse(&relay).unwrap(),
            subscription_id: sub.clone(),
            event: event_445(&group_hex, content),
        };
        // 1) The panic event trips the `#[cfg(test)]` seam inside
        //    `process_group_event`; `catch_unwind` must recover it (a scary panic
        //    message on stderr is expected — the worker survives it).
        tx.send(raw("__panic_for_test__")).await.unwrap();
        // 2) A normal undecryptable event for the SAME circle.
        tx.send(raw("normal-undecryptable")).await.unwrap();

        let mut seen = 0usize;
        while let Ok(Ok(ev)) = tokio::time::timeout(Duration::from_secs(3), rx.recv()).await {
            if matches!(
                ev,
                LiveSyncEvent::Status {
                    reason: SyncStatusReason::Unprocessable
                }
            ) {
                seen += 1;
            }
            if seen >= 2 {
                break;
            }
        }
        assert!(
            seen >= 2,
            "the worker must survive the panic (catch_unwind) AND process the next event"
        );
    }

    /// R7 (GAP-B+F): a broadcast `Lagged` must NOT kill `run_receiver` (the cursor
    /// + catch-up are the net), and a `Closed` channel must stop it cleanly. We
    /// overfill a cap-4 broadcast BEFORE the receiver is polled so its first
    /// `recv()` yields `Lagged`, then require a post-lag MARKER to still be
    /// forwarded; then drop the sender and require the task to exit.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn run_receiver_survives_lagged_then_stops_on_closed() {
        let (btx, brx) = broadcast::channel::<RelayPoolNotification>(4);
        let (mtx, mut mrx) = mpsc::channel::<RawEvent>(64);
        let shutdown = Arc::new(AtomicBool::new(false));

        let notif = |content: &str| {
            let ev = event_445("aa00", content);
            let id = ev.id;
            (
                id,
                RelayPoolNotification::Event {
                    relay_url: RelayUrl::parse("wss://relay.example").unwrap(),
                    subscription_id: SubscriptionId::new("s"),
                    event: Box::new(ev),
                },
            )
        };

        // Overfill the cap-4 channel with the receiver un-polled ⇒ first recv() = Lagged.
        for i in 0..6 {
            let (_, n) = notif(&format!("junk{i}"));
            btx.send(n).unwrap();
        }
        let handle = tokio::spawn(run_receiver(brx, mtx, Arc::clone(&shutdown)));

        // A distinctive event AFTER the lag.
        let (marker_id, marker) = notif("MARKER");
        btx.send(marker).unwrap();

        // The receiver must swallow Lagged and still forward the post-lag marker.
        let mut forwarded = false;
        while let Ok(Some(raw)) = tokio::time::timeout(Duration::from_secs(2), mrx.recv()).await {
            if raw.event.id == marker_id {
                forwarded = true;
                break;
            }
        }
        assert!(
            forwarded,
            "run_receiver must keep forwarding after a Lagged (never treat it as fatal)"
        );

        // Closed → clean stop: dropping the last sender ends the loop.
        drop(btx);
        tokio::time::timeout(Duration::from_secs(2), handle)
            .await
            .expect("run_receiver must exit promptly on Closed")
            .expect("the receiver task must join cleanly");
    }
}
