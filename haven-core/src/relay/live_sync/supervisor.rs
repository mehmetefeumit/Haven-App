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

use super::autocommit::{run_autocommit_converge, EngineHandles};
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
                let outcome = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                    processor.process_group_event(&raw.event, &nostr_group_id)
                }));

                match outcome {
                    Ok(GroupProcessOutcome::AutoCommitStaged(work)) => {
                        // Path B: process_group_event opened the settle window
                        // under the gate; release the gate, then spawn the in-Rust
                        // publish+converge task. Detached — bounded to one per
                        // circle (a sibling auto-commit for the same circle hits
                        // the open window → regime 2 → buffered, no 2nd spawn).
                        drop(guard);
                        tokio::spawn(run_autocommit_converge(handles.clone(), *work));
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
