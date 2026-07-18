//! The receive supervisor: a RAW `client.notifications()` loop, decoupled from
//! ingest by a bounded channel.
//!
//! # Why a raw loop (not `handle_notifications`)
//!
//! `Client::handle_notifications` exits permanently on a single broadcast
//! `Lagged` (it treats both `Lagged` and `Closed` as a clean stop). A slow
//! `SQLCipher` ingest could lag the pool's notification channel and silently
//! kill the receive path forever. Instead [`run_receiver`] consumes
//! `client.notifications()` directly, treats `Lagged` as `continue` (the cursor
//! and catch-up replay anything skipped) and only `Closed`/`Shutdown` as a stop.
//! It also **decouples** receive from ingest: it only `try_send`s onto a bounded
//! channel so the notification consumer never blocks, while a separate
//! [`run_worker`] drains that channel and awaits the engine ingest.
//!
//! # Write serialization (Rule 14)
//!
//! Every MLS-mutating call runs through the one process-global
//! [`crate::nostr::mls::SessionManager`] behind its single `tokio` mutex, so the
//! engine ingest and any foreground send serialize automatically — no per-circle
//! write gate is needed anymore (plan §5.4).

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

use nostr::{Event, RelayUrl, SubscriptionId};
use nostr_sdk::RelayPoolNotification;
use tokio::sync::broadcast::error::RecvError;
use tokio::sync::{broadcast, mpsc, RwLock};

use super::event::SyncStatusReason;
use super::planes::PlaneKind;
use super::processor::EngineProcessor;
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

/// The ingest worker: drains `rx`, routes each event, and awaits the engine
/// ingest.
///
/// All MLS writes serialize through the one process-global session mutex
/// (Rule 14), so no per-circle gate is needed. Panic isolation runs the ingest
/// on a spawned task and treats a panicked join as a benign drop (the cursor +
/// catch-up replay anything skipped), so one adversarial event can never blind
/// the whole receive path.
pub async fn run_worker(
    mut rx: mpsc::Receiver<RawEvent>,
    router: Arc<RwLock<Router>>,
    processor: Arc<EngineProcessor>,
) {
    while let Some(raw) = rx.recv().await {
        // Resolve the subscription context (cloned so the router lock is not held
        // across the ingest).
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
                let group_hex = canonical_group_hex(&nostr_group_id);

                // Panic isolation: run the async ingest on a spawned task and join
                // it, so a panic deep in a MLS decrypt on adversarial ciphertext
                // is contained to this one event instead of killing the worker.
                let process_started = std::time::Instant::now();
                let processor_task = Arc::clone(&processor);
                let event = raw.event.clone();
                let joined = tokio::spawn(async move {
                    processor_task
                        .process_group_event(&event, &nostr_group_id)
                        .await
                })
                .await;

                // Diagnostic: log only the pseudonymous group prefix + duration +
                // presence-only outcome variant (Security Rule 6).
                let outcome_label = joined
                    .as_ref()
                    .map_or_else(|_| "panic".to_string(), |o| format!("{o:?}"));
                log::debug!(
                    "[live_sync::worker] process_group_event group={}… took {}ms → {}",
                    group_hex.get(..8).unwrap_or(group_hex.as_str()),
                    process_started.elapsed().as_millis(),
                    outcome_label
                );

                if joined.is_err() {
                    // The ingest task panicked; surface a status so the consumer
                    // is not silently blinded. The cursor did not advance, so the
                    // event is re-fetched on the next catch-up.
                    processor.emit_status(SyncStatusReason::Unprocessable);
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
    use std::sync::atomic::AtomicBool;
    use std::sync::Arc;
    use std::time::Duration;

    use nostr::{
        Alphabet, EventBuilder, Keys, Kind, RelayUrl, SingleLetterTag, SubscriptionId, Tag, TagKind,
    };
    use nostr_sdk::RelayPoolNotification;
    use tempfile::TempDir;
    use tokio::sync::{broadcast, mpsc, RwLock};

    use super::{run_receiver, run_worker, RawEvent};
    use crate::circle::CircleManager;
    use crate::relay::live_sync::{
        EngineProcessor, EventBus, LiveSyncEvent, Router, SyncStatusReason,
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
        let keys = Keys::generate();
        let circle = Arc::new(CircleManager::new_unencrypted(dir.path(), &keys).unwrap());
        let bus = EventBus::new();
        let mut rx = bus.subscribe();
        // The write gate / settle buffer are gone (plan §5.4): the engine's single
        // session mutex serializes writes, so the processor is (circle, bus).
        let processor = Arc::new(EngineProcessor::new(Arc::clone(&circle), bus.clone()));

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
        tokio::spawn(run_worker(worker_rx, Arc::clone(&router), processor));

        let raw = |content: &str| RawEvent {
            relay_url: RelayUrl::parse(&relay).unwrap(),
            subscription_id: sub.clone(),
            event: event_445(&group_hex, content),
        };
        // TWO panic events (each trips the `#[cfg(test)]` seam inside
        // `process_group_event`): the worker isolates each panic (the ingest runs
        // on a joined `tokio::spawn`, so a panicked join is a benign drop) and
        // emits a `Status { Unprocessable }` for each, THEN keeps draining. A dead
        // worker would surface at most ONE (or none) and then wedge, timing out at
        // seen < 2. Two panics (rather than one panic + one undecryptable event)
        // because the DM engine classifies a 445 for an unknown group as
        // `Ok(Stale)` — NOT an error — so an undecryptable event no longer emits a
        // Status; the panic seam is the stable, engine-independent proof of
        // continued draining. (Scary panic messages on stderr are expected.)
        tx.send(raw("__panic_for_test__")).await.unwrap();
        tx.send(raw("__panic_for_test__")).await.unwrap();

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
            "the worker must survive the FIRST panic (isolated join) AND keep \
             draining to process (and survive) the SECOND"
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
