//! The receive supervisor: a RAW `client.notifications()` loop, decoupled from
//! ingest by a bounded channel.
//!
//! # Why a raw loop (not `handle_notifications`)
//!
//! `Client::handle_notifications` exits permanently on a single broadcast
//! `Lagged` (it treats both `Lagged` and `Closed` as a clean stop). A slow
//! `SQLCipher` ingest could lag the pool's notification channel and silently
//! kill the receive path forever. Instead [`run_receiver`] consumes
//! `client.notifications()` directly, treats `Lagged` as `continue` (losing
//! deliveries beats losing the plane, and what the skip costs the CURSOR is
//! suppressed — see the `Lagged` arm) and only `Closed`/`Shutdown` as a stop.
//! It also **decouples**
//! receive from ingest: it only `try_send`s onto a bounded channel so the
//! notification consumer never blocks, while a separate [`run_worker`] drains
//! that channel and awaits the engine ingest.
//!
//! # The intake cap (Security Rule 12)
//!
//! That bounded channel is the live plane's intake cap
//! ([`super::config::WORKER_QUEUE_CAP`]). A `try_send` onto a full queue drops
//! the DELIVERY, so the drop must not also cost the BACKLOG: the dropped event
//! holds its circle's cursor generation ([`note_intake_drop`]) and the next REQ
//! asks for it again. Nothing downstream can do this instead — a dropped event
//! reaches no worker and no engine, and this generation's `EOSE` would otherwise
//! advance the persisted cursor straight over it.
//!
//! A broadcast `Lagged` on the notification stream is the same loss with no
//! event left to hold: it reports a count. The receiver suppresses the pending
//! advance of every generation open at that moment instead, which is as narrow
//! as an unattributable skip allows (see the `Lagged` arm).
//!
//! # Write serialization (Rule 14)
//!
//! Every MLS-mutating call runs through the one process-global
//! [`crate::nostr::mls::SessionManager`] behind its single `tokio` mutex, so the
//! engine ingest and any foreground send serialize automatically — no per-circle
//! write gate is needed anymore (plan §5.4).

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

use nostr::{Event, Kind, PublicKey, RelayMessage, RelayUrl, SubscriptionId};
use nostr_sdk::RelayPoolNotification;
use tokio::sync::broadcast::error::RecvError;
use tokio::sync::{broadcast, mpsc, oneshot, watch, RwLock};

use super::config::WORKER_QUEUE_CAP;
use super::event::SyncStatusReason;
use super::planes::{group::GROUP_EVENT_KIND, PlaneKind};
use super::processor::EngineProcessor;
use super::repair::{ClosedKind, RepairKey, RepairQueue};
use super::router::{Router, SubCtx};

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

/// What the receiver hands the worker: a delivered event, a relay's
/// end-of-stored-events for one subscription, or a relay ending one.
///
/// All three are carried on the SAME channel deliberately. EOSE is the live
/// plane's only cursor-advance signal (see [`super::anchor`]), and it must be
/// observed AFTER every stored event the relay sent before it — a separate
/// channel would race the backlog and let the cursor claim events the worker
/// has not ingested yet. A `CLOSED` rides it for the mirror-image reason: it
/// triggers a re-issue, which opens a FRESH anchor generation, and an EOSE the
/// relay sent before the `CLOSED` must be redeemed against the generation it
/// actually belongs to. On a side channel the re-issue could overtake that EOSE
/// and let it anchor the new generation at the new REQ's open time — a
/// completeness claim the new REQ never made.
///
/// # What one channel does NOT fix
///
/// FIFO only orders what is IN this channel. The re-issue itself runs on the
/// repair task, and a bucket's anchor is keyed by circle while a repair
/// re-subscribes ONE relay — so a co-bucketed relay's EOSE for the OLD REQ can
/// still arrive after the repair opened a new generation, and redeem it. That
/// residual is closed in [`super::anchor::CursorAnchors::open_generation`],
/// which carries an un-applied hold-back across the generation boundary, and NOT
/// by this ordering. Do not read the paragraph above as covering it.
///
/// `RawEvent` is boxed so the channel's slot size is set by the small EOSE
/// variant rather than by a whole `nostr::Event`: the queue is bounded at
/// [`super::config`]'s worker cap and a `try_send` that finds it full DROPS the
/// signal, so keeping the per-slot cost low is what keeps that cap meaningful.
///
/// # Why this enum is not `Clone`
///
/// [`Self::Pause`] carries a one-shot ack the worker consumes exactly once.
/// Cloning a signal would either duplicate a marker (two clears, one ack) or
/// require an ack that can be dropped silently — and a pause whose ack is lost
/// blocks the lifecycle lock until its bound elapses. Nothing in the receive
/// path clones a signal, so the capability is simply not offered.
#[derive(Debug)]
pub enum RawSignal {
    /// A first-seen event on a live subscription.
    Event(Box<RawEvent>),
    /// A relay finished replaying its stored events for one subscription.
    EndOfStoredEvents {
        /// Relay that sent the EOSE.
        relay_url: RelayUrl,
        /// Subscription it terminates the stored phase of.
        subscription_id: SubscriptionId,
    },
    /// A relay ended one subscription (`CLOSED`).
    ///
    /// Carries the CLASSIFICATION, never the relay's free-text reason: the text
    /// is attacker-chosen and has exactly one use here — the NIP-01
    /// machine-readable prefix that says whether nostr-relay-pool deleted the
    /// subscription (see [`ClosedKind`]) — so it is resolved at the edge and
    /// never travels further.
    SubscriptionClosed {
        /// Relay that ended it.
        relay_url: RelayUrl,
        /// Subscription it named. Not yet known to be ours.
        subscription_id: SubscriptionId,
        /// Whether the pool deleted the subscription or merely marked it closed.
        kind: ClosedKind,
    },
    /// The session is pausing: drain everything already queued, THEN clear the
    /// router and burn the open generations' advances, and ack.
    ///
    /// # Why it rides the intake queue instead of being done by the caller
    ///
    /// The worker resolves the router at PROCESSING time, so a caller that
    /// cleared the router directly would drop every stored event still sitting
    /// in the intake queue — the undrained backlog of a burst whose relay was
    /// still replaying — burn the generation, and re-download the same window on
    /// the next burst. That is the silent loss of legitimate offline backlog
    /// Security Rule 12 forbids.
    ///
    /// Behind the marker, FIFO does the work: everything queued AHEAD of it —
    /// including an inline auto-commit and its OK wait — is processed first, so
    /// an acked marker means "every downloaded event has been applied, and no
    /// further ingest can start".
    Pause {
        /// The [`Router::registrations`] count the pause read while it held the
        /// lifecycle lock — the ONLY router state this marker may clear.
        ///
        /// The pause's wait for the ack is bounded, so a worker still draining
        /// when it expires leaves this marker queued while the pause clears the
        /// router itself and returns. A later burst then opens and registers its
        /// own REQs, and an unconditional clear here would wipe THOSE — a total
        /// receive outage for that burst, with every endpoint reading as
        /// subscribed. See [`Router::clear_if_unchanged`].
        registrations: u64,
        /// Fired once the marker has been resolved (cleared, or recognised as
        /// stale) and any suppression applied.
        ack: oneshot::Sender<()>,
    },
}

/// What the receiver loop should do with one pool notification.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NotifDisposition {
    /// A first-seen `Event`: extract + forward to the worker.
    Forward,
    /// A relay's `EOSE`: forward to the worker as a cursor-anchor signal.
    ForwardEose,
    /// A relay's `CLOSED`: forward to the worker, which screens it against the
    /// live router and, if it names one of OUR subscriptions, requests a repair.
    ForwardClosed,
    /// The pool shut down: stop the loop cleanly.
    Stop,
    /// A relay message / auth / other notification we don't act on.
    Ignore,
}

/// Classifies one pool notification (pure; testable without a runtime).
///
/// Two relay messages are singled out of the `Message` arm.
///
/// `EndOfStoredEvents` is the only one the live plane trusts for anything: it is
/// the relay stating that it has handed over everything it stored for a REQ,
/// which is what lets the cursor advance to that REQ's LOCAL open time instead
/// of to an event's remotely-chosen `created_at`.
///
/// `Closed` is the only one that can END a REQ. nostr-relay-pool deletes the
/// subscription for most `CLOSED` reasons and never re-issues it, not even on a
/// later socket reconnect — a permanent receive blackout behind a `Connected`
/// relay (see [`super::repair`]). Forwarding it is what lets the worker repair
/// it. It carries a subscription id, so the worker can hold the relay to a
/// subscription this session actually owns; naming an id we never issued buys a
/// relay nothing.
///
/// `Notice` deliberately stays `Ignore`. It is free text chosen by the relay
/// with no subscription id and no machine-readable form, so it identifies
/// nothing to repair — acting on it would hand every relay a lever to trigger
/// work and status churn on demand, which is precisely what the `CLOSED` screen
/// exists to deny.
#[must_use]
pub const fn notification_disposition(n: &RelayPoolNotification) -> NotifDisposition {
    match n {
        RelayPoolNotification::Event { .. } => NotifDisposition::Forward,
        RelayPoolNotification::Shutdown => NotifDisposition::Stop,
        RelayPoolNotification::Message { message, .. } => match message {
            RelayMessage::EndOfStoredEvents(_) => NotifDisposition::ForwardEose,
            RelayMessage::Closed { .. } => NotifDisposition::ForwardClosed,
            _ => NotifDisposition::Ignore,
        },
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

/// Whether `event` is what `ctx`'s REQ actually asked for — the LOCAL re-check
/// of the subscription filter, and the ONLY one the engine has.
///
/// The engine `Client` deliberately does not enable nostr-sdk's
/// `verify_subscriptions` (see [`super::session`] for why: it drops the first
/// stored events of every fresh REQ), so a relay's answer is held to the filter
/// it was given HERE instead — before any decrypt or peel, and without a race,
/// because the router context is registered before the REQ goes out.
///
/// Only the IDENTITY dimensions of each filter are re-checked, never `since`.
/// The floor bounds how MUCH a relay sends, not what it is allowed to say: an
/// event below it is either one the cursor has already passed (harmless) or, on
/// the group plane, still MLS-authenticated before anything is applied. A second
/// local copy of the floor could drift from the live REQ and would then drop
/// legitimate events — a worse failure than the one it would prevent.
#[must_use]
pub fn plane_wants_event(ctx: &SubCtx, event: &Event, own_pubkey: &PublicKey) -> bool {
    match ctx.plane {
        // An `#h` this REQ never multiplexed is a relay echoing a circle we did
        // not ask about.
        PlaneKind::Group => {
            event.kind == GROUP_EVENT_KIND
                && extract_group_id_hex(event).is_some_and(|hex| ctx.group_ids_hex.contains(&hex))
        }
        // A gift wrap is authored by a throwaway key by construction (NIP-59),
        // so the `#p` routing tag — never the author — is what says it is ours.
        PlaneKind::Inbox => {
            event.kind == Kind::GiftWrap && event.tags.public_keys().any(|pk| pk == own_pubkey)
        }
    }
}

/// Builds the receive→ingest queue at the Rule-12 intake cap
/// ([`WORKER_QUEUE_CAP`]).
///
/// The cap lives behind a constructor rather than inline at the one call site so
/// that "the live plane's ingest is BOUNDED" is a property something other than
/// `session.rs` can observe: an unbounded queue is the shape Rule 12 forbids,
/// and swapping one in here changes this signature rather than passing silently.
#[must_use]
pub fn intake_queue() -> (mpsc::Sender<RawSignal>, mpsc::Receiver<RawSignal>) {
    mpsc::channel(WORKER_QUEUE_CAP)
}

/// Holds the circle of an event the intake cap just dropped at that event's
/// `created_at`, so the drop costs a re-fetch instead of the backlog (Rule 12).
///
/// Screened by kind and keyed by the RAW `#h`, so it accepts exactly what
/// [`plane_wants_event`] accepts on the group plane — which is what makes it
/// safe: an event the worker would have discarded cannot conjure a hold-back.
/// The anchor table's keys ARE the (lowercase) hexes the REQ was issued with, so
/// [`CursorAnchors::note_unapplied`] no-ops on any other tag. The kind screen is
/// load-bearing rather than belt-and-braces: the inbox REQ filters on kind and
/// `#p` alone, so a fully conformant relay will deliver a `kind:1059` carrying
/// whatever `#h` its author chose. A dropped gift wrap needs no hold-back of its
/// own — the inbox stream's multi-day lookback re-requests it (49 h on a
/// re-anchor, 7 d on a cold start; see [`super::anchor::InboxAnchor`]).
///
/// [`CursorAnchors::note_unapplied`]: super::anchor::CursorAnchors::note_unapplied
fn note_intake_drop(processor: &EngineProcessor, event: &Event) {
    if event.kind != GROUP_EVENT_KIND {
        return;
    }
    let Some(routed_hex) = extract_group_id_hex(event) else {
        return;
    };
    processor.note_dropped_before_ingest(
        &routed_hex,
        i64::try_from(event.created_at.as_secs()).unwrap_or(i64::MAX),
    );
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

/// Records that the ingest worker has exited, so a dead receive plane stops
/// reading as a live one.
///
/// The intake channel reporting `Closed` means [`run_worker`] returned — it
/// cannot be restarted, and every later delivery would go nowhere. Two things
/// have to happen, and neither is optional:
///
/// * `wedged` makes [`super::session::LiveSyncCore::is_running`] answer `false`,
///   which is the signal the Dart self-heal uses to rebuild the session. It is
///   the ONLY channel that distinguishes this from any other relay trouble, so
///   the status below does not have to.
/// * a bus status, so the failure is visible rather than silent.
///   [`SyncStatusReason::RelayError`] is used deliberately: this unit cannot add
///   an FFI variant, and of the existing ones it is the only generic failure
///   signal — `SessionStopped` would read as an intentional teardown and mute
///   the very restart this needs.
fn report_worker_gone(processor: &EngineProcessor, wedged: &AtomicBool) {
    wedged.store(true, Ordering::Release);
    processor.emit_status(SyncStatusReason::RelayError);
    log::warn!("[live_sync::receiver] ingest worker exited; receive plane is down");
}

/// The RAW notifications receiver: forwards first-seen events onto `tx`, never
/// blocking on decrypt, surviving `Lagged`, stopping only on `Closed`/`Shutdown`,
/// the explicit `shutdown` flag, or `cancel`.
///
/// # Why `cancel` exists (and why `shutdown` is not enough)
///
/// `shutdown` is polled at the TOP of the loop, so a task parked in
/// `notifications.recv().await` never observes it. Before this parameter the
/// only other wake path was the pool's `Shutdown` notification — and that is
/// **not guaranteed to arrive**. `RelayPool::shutdown` latches an atomic
/// *before* awaiting `force_remove_all_relays()` and only then sends the
/// notification, so a caller that bounds the shutdown with a timeout (as
/// `LiveSyncCore::stop_inner` does) can drop the future in between: the
/// notification is never sent, and because the latch is already set, no retry
/// will ever send it.
///
/// That leaves this task parked forever holding its `mpsc::Sender`, which keeps
/// `run_worker` alive, which holds `Arc<EngineProcessor>` → `Arc<CircleManager>`
/// → the Rule-14 `LiveSessionGuard`. The result is an unowned MLS writer and a
/// database no isolate can ever reopen. `cancel` is the independent wake that
/// breaks that cycle.
///
/// # Why the receiver needs the processor
///
/// Only to hold a cursor generation back for a delivery this loop lost: at the
/// event the full intake queue forced it to drop ([`note_intake_drop`]), or —
/// when the notification stream skipped an unattributable set — across every
/// generation then open. The receiver still routes nothing and ingests nothing.
/// It shares the `Arc` graph the `mpsc::Sender` already keeps alive, so it adds
/// no new lifetime edge for `cancel` to break.
///
/// # `wedged`
///
/// Raised when the intake channel reports `Closed` — the worker has exited, so
/// nothing downstream will ever ingest again. Before this flag existed the
/// receiver matched only `TrySendError::Full` and a dead worker fell through
/// silently while `is_running()` (a shutdown flag) still answered `true`, so
/// neither the Dart self-heal nor the health tick had any reason to restart the
/// session. See [`super::session::LiveSyncCore::is_running`].
pub async fn run_receiver(
    mut notifications: broadcast::Receiver<RelayPoolNotification>,
    tx: mpsc::Sender<RawSignal>,
    processor: Arc<EngineProcessor>,
    shutdown: Arc<AtomicBool>,
    wedged: Arc<AtomicBool>,
    mut cancel: watch::Receiver<bool>,
) {
    loop {
        if shutdown.load(Ordering::Acquire) {
            break;
        }
        let notification = tokio::select! {
            biased;
            // `wait_for` evaluates the CURRENT value, so a cancel raised before
            // this receiver was created is still observed. `changed()` would
            // mark the value seen at subscribe time and miss exactly that case
            // — which is the case that matters, because `stop` raises cancel
            // before it touches anything else.
            _ = cancel.wait_for(|cancelled| *cancelled) => break,
            received = notifications.recv() => received,
        };
        match notification {
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
                        // replay, never to a wedged receiver. Rule 12: the drop
                        // must THROTTLE, so the dropped event holds its circle's
                        // generation — nothing else records it, and the EOSE
                        // would otherwise advance the cursor straight over it.
                        match tx.try_send(RawSignal::Event(Box::new(RawEvent {
                            relay_url,
                            subscription_id,
                            event: *event,
                        }))) {
                            Err(mpsc::error::TrySendError::Full(RawSignal::Event(dropped))) => {
                                note_intake_drop(&processor, &dropped.event);
                            }
                            Err(mpsc::error::TrySendError::Closed(_)) => {
                                report_worker_gone(&processor, &wedged);
                                break;
                            }
                            Ok(()) | Err(mpsc::error::TrySendError::Full(_)) => {}
                        }
                    }
                }
                NotifDisposition::ForwardEose => {
                    if let RelayPoolNotification::Message {
                        relay_url,
                        message: RelayMessage::EndOfStoredEvents(subscription_id),
                    } = n
                    {
                        // Dropped on a full channel like any other signal — and
                        // dropping it is the SAFE direction: a missed EOSE only
                        // means the cursor does not advance this generation, so
                        // the next REQ re-requests a wider window.
                        if let Err(mpsc::error::TrySendError::Closed(_)) =
                            tx.try_send(RawSignal::EndOfStoredEvents {
                                relay_url,
                                subscription_id: subscription_id.into_owned(),
                            })
                        {
                            report_worker_gone(&processor, &wedged);
                            break;
                        }
                    }
                }
                NotifDisposition::ForwardClosed => {
                    if let RelayPoolNotification::Message {
                        relay_url,
                        message:
                            RelayMessage::Closed {
                                subscription_id,
                                message,
                            },
                    } = n
                    {
                        // Classify at the edge: the reason is attacker-chosen
                        // free text whose only use is its NIP-01 prefix, so it
                        // is resolved here and never travels further.
                        match tx.try_send(RawSignal::SubscriptionClosed {
                            relay_url,
                            subscription_id: subscription_id.into_owned(),
                            kind: ClosedKind::classify(&message),
                        }) {
                            Ok(()) => {}
                            Err(mpsc::error::TrySendError::Closed(_)) => {
                                report_worker_gone(&processor, &wedged);
                                break;
                            }
                            // A full intake queue drops this CLOSED, and unlike a
                            // dropped EOSE that is NOT self-correcting: the REQ
                            // stays deleted at the relay and no repair is
                            // scheduled. It is nonetheless the right trade here,
                            // and the floor is not the 15-minute tick's delivery
                            // arm but its PRESENCE arm: the deleted REQ is gone
                            // from `client.subscriptions()`, so
                            // `subscriptions_live < subscriptions_expected` fires
                            // deterministically on the very next tick — no
                            // waiting out a silence window.
                            //
                            // The alternative — recording the repair straight
                            // from this loop — is rejected on Rule 12: the
                            // receiver holds no router, so it cannot tell one of
                            // OUR subscription ids from an id a relay invented,
                            // and a relay that floods CLOSEDs for arbitrary ids
                            // while the queue is full would grow the backoff
                            // table without bound. Losing a repair the presence
                            // arm re-derives beats accepting relay-writable
                            // unbounded state.
                            Err(mpsc::error::TrySendError::Full(_)) => {
                                log::warn!(
                                    "[live_sync::receiver] intake full; a relay CLOSED was \
                                     dropped — the health tick's subscription-presence arm \
                                     is the backstop"
                                );
                            }
                        }
                    }
                }
                NotifDisposition::Stop => break,
                NotifDisposition::Ignore => {}
            },
            // A lagged broadcast must NOT kill the receiver; the loop simply
            // iterates again. Only a closed channel stops it.
            //
            // Rule 12, coarsely: `Lagged` reports a COUNT, not the events, so
            // there is no `created_at` to hold a cursor at and no circle to hold
            // — but "an unknown set was skipped" is still expressible. Every
            // generation still OWED an advance loses it, so no EOSE this session
            // has yet to redeem moves a cursor past events the process never
            // saw, and the next REQ, floored on the untouched cursor, asks for
            // them again. The price is one window re-fetch per affected circle;
            // the alternative is the silent backlog loss the rule names,
            // permanent and across restarts.
            //
            // Reaching this needs the pool's `POOL_NOTIF_CAP` broadcast to
            // overrun while this loop — which does nothing but `try_send` and,
            // on overflow, one anchor write — is unscheduled. Not necessarily
            // 8192 EVENTS, though: the pool broadcasts every relay MESSAGE too,
            // and those cost the sender no signature, so a connected relay can
            // reach the cap with chatter. That is why the suppression is the
            // safe side of the trade — under exactly that flood, advancing
            // would let the flooder choose which of its own deliveries we lose
            // for good.
            Err(RecvError::Lagged(_)) => processor.note_delivery_gap(),
            Err(RecvError::Closed) => break,
        }
    }
}

/// Records a relay ending one of OUR subscriptions: a visible status plus a
/// scheduled re-issue.
///
/// The caller MUST have resolved a router context for `(relay_url, sub_id)`
/// first. That lookup is the ownership screen: a `CLOSED` naming an id this
/// session never issued finds no context and never reaches here, so a relay
/// cannot make Haven re-subscribe — or even allocate a backoff entry — by
/// inventing a subscription id.
///
/// Reached only in FIFO order behind every event and `EOSE` the relay sent ahead
/// of the `CLOSED`, which is why they share one channel: the re-issue this
/// schedules opens a fresh anchor generation, and the preceding `EOSE` must be
/// redeemed against the generation it belongs to first (see [`RawSignal`]).
///
/// # Order of the two effects
///
/// The repair is SCHEDULED before the status is emitted, and that order is a
/// contract, not an accident: a consumer seeing `RelayError` may rely on the
/// repair already being queued. Emitting first published a state that had not
/// happened yet — which made an observer that used the status as its
/// happens-before edge race the scheduling under load.
pub(crate) fn note_subscription_closed(
    processor: &EngineProcessor,
    repair: &RepairQueue,
    key: &RepairKey,
    kind: ClosedKind,
) {
    repair.note_closed(key, kind);
    processor.emit_status(SyncStatusReason::RelayError);
    // Presence-only (Security Rules 4/6): never the relay, the sub-id, the `#h`,
    // or the relay's free-text reason.
    log::warn!(
        "[live_sync::worker] a relay ended one of our subscriptions (kind={kind:?}); repair scheduled"
    );
}

/// Redeems a relay's `EOSE` against the cursor anchor of every stream that REQ
/// serves.
///
/// The live plane's ONLY cursor-advance signal, on BOTH planes. It is redeemed
/// in the worker, after it has already drained every stored event the relay sent
/// ahead of it on the same channel, so the advance can never claim an event this
/// worker has not ingested.
///
/// # Why the GROUP plane waits for every relay and the INBOX plane does not
///
/// A group bucket REQ is issued to several relays and its circles hold ONE
/// generation each, so the first relay's `EOSE` would advance the cursor over a
/// window a slower co-bucketed relay had not served — and the next REQ's floor
/// is only [`crate::relay::cursor::GROUP_RESUBSCRIBE_BUFFER_SECS`] (60 s) below
/// that cursor, so an event older than a minute is then never asked for again.
/// The advance therefore waits for every relay that accepted the REQ
/// ([`EngineProcessor::note_eose_endpoint`]).
///
/// The inbox is deliberately left on the first `EOSE`. Its recovery window is
/// the lookback, not the buffer: every re-subscribe asks for
/// `cursor − INBOX_RESUBSCRIBE_LOOKBACK_SECS` (49 h), so a wrap a slow inbox
/// relay had not yet replayed is re-requested by the next REQ for two days —
/// there is no permanent skip to close. Waiting instead would pin the inbox
/// cursor on one silent relay and make every REQ replay that 49-hour window,
/// which is the cost P1 bounded it to avoid.
fn anchor_end_of_stored_events(processor: &EngineProcessor, ctx: &SubCtx, key: &RepairKey) {
    match ctx.plane {
        PlaneKind::Group => {
            if !processor.note_eose_endpoint(key) {
                // Presence-only: some relay that accepted this REQ has not
                // finished replaying, so no circle on it may advance yet.
                log::debug!(
                    "[live_sync::worker] EOSE recorded; the REQ's other relays have not \
                     answered, so no cursor advances"
                );
                return;
            }
            for group_hex in &ctx.group_ids_hex {
                if processor.note_end_of_stored_events(group_hex) {
                    log::debug!(
                        "[live_sync::worker] EOSE anchored cursor group={}…",
                        group_hex.get(..8).unwrap_or(group_hex.as_str()),
                    );
                }
            }
        }
        // The inbox cursor used to be advanced by the FOREGROUND, from the gift
        // wrap's own `created_at` — a field anyone who knows this user's
        // (published) npub can choose freely, and one whose FUTURE direction
        // pins every later inbox REQ floor at `now`, where NIP-59's mandatory
        // backdating makes every genuine wrap invisible. It anchors here now, on
        // the inbox REQ's local open time, exactly like a group bucket.
        PlaneKind::Inbox => {
            if processor.note_inbox_end_of_stored_events() {
                log::debug!("[live_sync::worker] EOSE anchored inbox cursor");
            }
        }
    }
}

/// Resolves one pause drain marker: clears the router it was authorised for,
/// burns those generations' advances, and acks.
///
/// Only the registration state the pause OBSERVED may be cleared. A pause whose
/// ack timed out has already cleared the router itself and released the
/// lifecycle lock, so this marker can reach the worker after a LATER burst
/// registered its own REQs — and clearing those would leave that burst routing
/// nothing at all while every endpoint still read as subscribed.
///
/// `note_delivery_gap`, NEVER `forget_*`: a `forget` DROPS the generation's
/// un-applied hold-back, so a future-epoch event this burst buffered would stop
/// bounding the next burst's advance and the cursor would move straight over it.
/// Suppressing burns the advance and KEEPS the hold-back for the generation the
/// next burst opens. A STALE marker suppresses nothing: the pause that sent it
/// already burned the generations it interrupted, and burning again here would
/// cost the current burst an advance for a window it did serve.
async fn resolve_pause_marker(
    router: &RwLock<Router>,
    processor: &EngineProcessor,
    registrations: u64,
    ack: oneshot::Sender<()>,
) {
    if router.write().await.clear_if_unchanged(registrations) {
        processor.note_delivery_gap();
    } else {
        // Presence-only.
        log::warn!(
            "[live_sync::worker] a drain marker from an abandoned pause arrived after a \
             later burst opened; leaving that burst's router alone"
        );
    }
    // A dropped receiver means the pause gave up waiting and already ran its own
    // fallback; the resolution above is then simply idempotent.
    let _ = ack.send(());
}

/// The ingest worker: drains `rx`, routes each event, and awaits the engine
/// ingest.
///
/// All MLS writes serialize through the one process-global session mutex
/// (Rule 14), so no per-circle gate is needed. Panic isolation runs the ingest
/// on a spawned task and treats a panicked join as a benign drop (the cursor +
/// catch-up replay anything skipped), so one adversarial event can never blind
/// the whole receive path.
///
/// `own_pubkey` is this session's identity key — the `#p` the inbox REQ asked
/// for, and therefore what [`plane_wants_event`] holds an inbound gift wrap to.
///
/// `repair` is where a `CLOSED` for one of OUR subscriptions is recorded; the
/// session's repair task re-issues it under the lifecycle lock.
pub async fn run_worker(
    mut rx: mpsc::Receiver<RawSignal>,
    router: Arc<RwLock<Router>>,
    processor: Arc<EngineProcessor>,
    repair: Arc<RepairQueue>,
    own_pubkey: PublicKey,
) {
    while let Some(signal) = rx.recv().await {
        // The pause marker carries no `(relay, sub)` and must be handled BEFORE
        // the router lookup — the lookup is exactly what it is about to make
        // impossible. Everything queued ahead of it has already been processed
        // by the time we get here (this loop is serial), which is the whole
        // content of the ack.
        if let RawSignal::Pause { registrations, ack } = signal {
            resolve_pause_marker(&router, &processor, registrations, ack).await;
            continue;
        }

        let key = match &signal {
            RawSignal::Event(raw) => RepairKey {
                relay_url: raw.relay_url.clone(),
                sub_id: raw.subscription_id.clone(),
            },
            RawSignal::EndOfStoredEvents {
                relay_url,
                subscription_id,
            }
            | RawSignal::SubscriptionClosed {
                relay_url,
                subscription_id,
                ..
            } => RepairKey {
                relay_url: relay_url.clone(),
                sub_id: subscription_id.clone(),
            },
            // Handled above; the marker never reaches the router.
            RawSignal::Pause { .. } => continue,
        };

        // Resolve the subscription context (cloned so the router lock is not held
        // across the ingest).
        let ctx = {
            router
                .read()
                .await
                .lookup(key.relay_url.as_str(), &key.sub_id)
                .cloned()
        };
        let Some(ctx) = ctx else { continue };

        // This REQ endpoint is carrying traffic. Recorded for anything the
        // router resolved — a CLOSED excepted, which is the relay ENDING the
        // REQ, not serving it.
        if !matches!(signal, RawSignal::SubscriptionClosed { .. }) {
            processor.note_delivery(&key);
        }

        let raw = match signal {
            RawSignal::Event(raw) => *raw,
            RawSignal::SubscriptionClosed { kind, .. } => {
                // This endpoint will send nothing more on this REQ, so a burst
                // waiting on it has its answer — waiting for an `EOSE` that can
                // no longer come would spend the whole backlog budget.
                processor.note_endpoint_settled(&key);
                note_subscription_closed(&processor, &repair, &key, kind);
                continue;
            }
            RawSignal::EndOfStoredEvents { .. } => {
                anchor_end_of_stored_events(&processor, &ctx, &key);
                // Recorded AFTER the anchor, and after every stored event this
                // relay sent ahead of the EOSE was ingested by this serial loop:
                // that ordering is what lets a burst treat a settled endpoint as
                // "its backlog is applied" rather than merely "downloaded".
                processor.note_endpoint_settled(&key);
                continue;
            }
            // Unreachable: handled at the top of the loop.
            RawSignal::Pause { .. } => continue,
        };

        // Hold the relay to the filter this REQ was issued with. Nothing else
        // does: the engine `Client` runs without `verify_subscriptions`, so an
        // unrequested event dropped here is an unrequested event never peeled,
        // decrypted, or put on the bus.
        if !plane_wants_event(&ctx, &raw.event, &own_pubkey) {
            continue;
        }

        match ctx.plane {
            // Panic-isolated like the group arm below, and for the same reason:
            // `process_inbox_event` serializes the wrap with `Event::as_json`,
            // which is an infallible-looking wrapper over a `try_as_json`
            // `unwrap`. It is synchronous, so `catch_unwind` is the isolation a
            // joined `tokio::spawn` provides over there. `AssertUnwindSafe` is
            // sound here because the only state touched is a broadcast send,
            // which a panic in serialization cannot leave torn.
            PlaneKind::Inbox => {
                if std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                    processor.process_inbox_event(&raw.event);
                }))
                .is_err()
                {
                    // Surface it rather than swallow it; the inbox cursor did
                    // not advance, so the next REQ's lookback re-fetches.
                    processor.emit_status(SyncStatusReason::InboxError);
                }
            }
            PlaneKind::Group => {
                // Screened above, so the `#h` is present and multiplexed by this
                // REQ; re-read it for the routing id.
                let Some(routed_hex) = extract_group_id_hex(&raw.event) else {
                    continue;
                };
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

    fn giftwrap_routed_to(recipient: &nostr::PublicKey) -> Event {
        EventBuilder::new(Kind::GiftWrap, "sealed")
            .tags(vec![nostr::Tag::public_key(*recipient)])
            .sign_with_keys(&Keys::generate())
            .unwrap()
    }

    fn group_ctx(group_ids_hex: &[&str]) -> SubCtx {
        SubCtx {
            plane: PlaneKind::Group,
            group_ids_hex: group_ids_hex.iter().map(|h| (*h).to_string()).collect(),
        }
    }

    fn inbox_ctx() -> SubCtx {
        SubCtx {
            plane: PlaneKind::Inbox,
            group_ids_hex: std::collections::HashSet::new(),
        }
    }

    /// The group REQ asks for `kind:445` carrying one of ITS `#h` values; every
    /// other shape a relay could put on that socket is unrequested.
    #[test]
    fn group_plane_wants_only_a_445_for_a_multiplexed_h_tag() {
        let stranger = Keys::generate().public_key();
        let ctx = group_ctx(&["aa00", "bb11"]);

        assert!(plane_wants_event(
            &ctx,
            &commit_event_with_h("aa00"),
            &stranger
        ));
        // An `#h` this REQ never multiplexed — a relay echoing a circle we did
        // not ask about.
        assert!(!plane_wants_event(
            &ctx,
            &commit_event_with_h("ff99"),
            &stranger
        ));
        // A 445 with no `#h` at all cannot be routed to a circle.
        let no_h = EventBuilder::new(Kind::Custom(445), "x")
            .sign_with_keys(&Keys::generate())
            .unwrap();
        assert!(!plane_wants_event(&ctx, &no_h, &stranger));
        // Right routing tag, wrong kind: the group REQ asked for 445 only.
        let wrong_kind = EventBuilder::new(Kind::Custom(446), "x")
            .tags(vec![nostr::Tag::custom(
                nostr::TagKind::SingleLetter(SingleLetterTag::lowercase(Alphabet::H)),
                ["aa00"],
            )])
            .sign_with_keys(&Keys::generate())
            .unwrap();
        assert!(!plane_wants_event(&ctx, &wrong_kind, &stranger));
    }

    /// The inbox REQ asks for `kind:1059` routed at OUR `#p`. A wrap addressed
    /// to somebody else is not ours to peel, whatever socket it arrives on.
    #[test]
    fn inbox_plane_wants_only_a_giftwrap_routed_at_our_own_p_tag() {
        let own = Keys::generate().public_key();
        let ctx = inbox_ctx();

        assert!(plane_wants_event(&ctx, &giftwrap_routed_to(&own), &own));
        // Routed at a stranger: never asked for.
        let stranger = Keys::generate().public_key();
        assert!(!plane_wants_event(
            &ctx,
            &giftwrap_routed_to(&stranger),
            &own
        ));
        // No routing tag at all.
        let untagged = EventBuilder::new(Kind::GiftWrap, "sealed")
            .sign_with_keys(&Keys::generate())
            .unwrap();
        assert!(!plane_wants_event(&ctx, &untagged, &own));
        // Our `#p`, but not a gift wrap: the inbox consumer peels with NIP-59
        // alone, so anything else on this REQ is a relay speaking out of turn.
        let wrong_kind = EventBuilder::new(Kind::Custom(445), "x")
            .tags(vec![nostr::Tag::public_key(own)])
            .sign_with_keys(&Keys::generate())
            .unwrap();
        assert!(!plane_wants_event(&ctx, &wrong_kind, &own));
    }

    /// A gift wrap must never be accepted on a GROUP subscription (nor a 445 on
    /// the inbox one): the plane decides what the REQ asked for, not the event.
    #[test]
    fn a_plane_never_accepts_the_other_plane_s_events() {
        let own = Keys::generate().public_key();
        assert!(!plane_wants_event(
            &group_ctx(&["aa00"]),
            &giftwrap_routed_to(&own),
            &own
        ));
        assert!(!plane_wants_event(
            &inbox_ctx(),
            &commit_event_with_h("aa00"),
            &own
        ));
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

    #[test]
    fn eose_and_closed_are_forwarded_and_every_other_relay_message_is_ignored() {
        // EOSE is the live plane's ONLY cursor-advance signal, so dropping it
        // into the `Message` catch-all would silently freeze every per-circle
        // cursor. CLOSED is the only message that ENDS a REQ, and the pool never
        // re-issues most of them — dropping it into the catch-all is what made
        // the receive blackout permanent. The complement matters just as much:
        // no other relay message may be mistaken for either.
        let relay_url = RelayUrl::parse("wss://relay.example").unwrap();
        let eose = RelayPoolNotification::Message {
            relay_url: relay_url.clone(),
            message: RelayMessage::EndOfStoredEvents(std::borrow::Cow::Owned(SubscriptionId::new(
                "sub",
            ))),
        };
        assert_eq!(
            notification_disposition(&eose),
            NotifDisposition::ForwardEose
        );

        let closed = RelayPoolNotification::Message {
            relay_url: relay_url.clone(),
            message: RelayMessage::Closed {
                subscription_id: std::borrow::Cow::Owned(SubscriptionId::new("sub")),
                message: std::borrow::Cow::Borrowed("closed"),
            },
        };
        assert_eq!(
            notification_disposition(&closed),
            NotifDisposition::ForwardClosed,
            "a CLOSED must reach the worker: the pool deleted the subscription \
             and will never re-issue it"
        );

        for other in [
            // Free relay text naming no subscription: it identifies nothing to
            // repair, so acting on it would be a relay-triggered work lever.
            RelayMessage::Notice(std::borrow::Cow::Borrowed("hello")),
            RelayMessage::Ok {
                event_id: nostr::EventId::all_zeros(),
                status: false,
                message: std::borrow::Cow::Borrowed("rejected"),
            },
            RelayMessage::Auth {
                challenge: std::borrow::Cow::Borrowed("challenge"),
            },
        ] {
            assert_eq!(
                notification_disposition(&RelayPoolNotification::Message {
                    relay_url: relay_url.clone(),
                    message: other,
                }),
                NotifDisposition::Ignore,
                "only EOSE and CLOSED are acted on",
            );
        }
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

    use super::{run_receiver, run_worker, RawEvent, RawSignal};
    use crate::circle::CircleManager;
    use crate::relay::live_sync::repair::{ClosedKind, RepairKey, RepairQueue};
    use crate::relay::live_sync::{
        EngineProcessor, EventBus, LiveSyncEvent, PlaneKind, Router, SubCtx, SyncStatusReason,
    };

    /// A bare processor over a throwaway MLS database, for the receiver tests
    /// that exercise the loop's LIFECYCLE rather than its cursor side effects.
    /// The `TempDir` comes back with it because dropping it would delete the
    /// database out from under the still-running receiver.
    fn bare_processor() -> (Arc<EngineProcessor>, TempDir) {
        let dir = TempDir::new().unwrap();
        let circle =
            Arc::new(CircleManager::new_unencrypted(dir.path(), &Keys::generate()).unwrap());
        (Arc::new(EngineProcessor::new(circle, EventBus::new())), dir)
    }

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

    /// The worker is the ONLY thing holding a relay to the filter its REQ was
    /// issued with — the engine `Client` runs without nostr-sdk's
    /// `verify_subscriptions`, because that check drops the first stored events
    /// of every fresh REQ (see `session::build_engine_client`).
    ///
    /// So: feed one live inbox subscription three events in order — a gift wrap
    /// routed at a STRANGER's `#p`, a `kind:445` (wrong kind for this plane) and
    /// finally a genuine wrap routed at us — and require the FIRST `Welcome` on
    /// the bus to be the genuine one. The channel is FIFO and one worker drains
    /// it, so that ordering is what proves the first two were dropped: had
    /// either reached the consumer, it would have arrived first. No sleeps, no
    /// timing assumptions.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn run_worker_drops_inbox_events_the_req_never_asked_for() {
        let dir = TempDir::new().unwrap();
        let keys = Keys::generate();
        let circle = Arc::new(CircleManager::new_unencrypted(dir.path(), &keys).unwrap());
        let bus = EventBus::new();
        let mut rx = bus.subscribe();
        let processor = Arc::new(EngineProcessor::new(Arc::clone(&circle), bus.clone()));

        let own = Keys::generate().public_key();
        let sub = SubscriptionId::new("s_inbox_0");
        let relay = "wss://relay.example".to_string();
        let router = Arc::new(RwLock::new(Router::new()));
        router.write().await.register(
            &relay,
            &sub,
            SubCtx {
                plane: PlaneKind::Inbox,
                group_ids_hex: HashSet::new(),
            },
        );

        let (tx, worker_rx) = mpsc::channel::<RawSignal>(16);
        tokio::spawn(run_worker(
            worker_rx,
            Arc::clone(&router),
            processor,
            Arc::new(RepairQueue::default()),
            own,
        ));

        let wrap_for = |recipient: nostr::PublicKey| {
            EventBuilder::new(Kind::GiftWrap, "sealed")
                .tags(vec![Tag::public_key(recipient)])
                .sign_with_keys(&Keys::generate())
                .unwrap()
        };
        let deliver = |event: nostr::Event| {
            RawSignal::Event(Box::new(RawEvent {
                relay_url: RelayUrl::parse(&relay).unwrap(),
                subscription_id: sub.clone(),
                event,
            }))
        };

        tx.send(deliver(wrap_for(Keys::generate().public_key())))
            .await
            .unwrap();
        tx.send(deliver(event_445("aa00", "not a wrap")))
            .await
            .unwrap();
        let genuine = wrap_for(own);
        tx.send(deliver(genuine.clone())).await.unwrap();

        let welcome = tokio::time::timeout(Duration::from_secs(5), async {
            loop {
                match rx.recv().await {
                    Ok(LiveSyncEvent::Welcome { gift_wrap_json }) => return gift_wrap_json,
                    // Another bus event, or dropped ones: keep waiting.
                    Ok(_) | Err(broadcast::error::RecvError::Lagged(_)) => {}
                    Err(broadcast::error::RecvError::Closed) => {
                        panic!("the worker dropped the bus before delivering the genuine wrap")
                    }
                }
            }
        })
        .await
        .expect("the genuine wrap must reach the consumer");

        assert!(
            welcome.contains(&genuine.id.to_hex()),
            "the first welcome on the bus must be the wrap routed at OUR #p: a \
             wrap addressed to a stranger and a kind:445 were delivered on this \
             inbox subscription first, and neither was requested by its REQ"
        );
    }

    /// R6 (GAP-A): a panic deep in the decrypt call (via the `#[cfg(test)]`
    /// content sentinel) must be CAUGHT by `run_worker`'s `catch_unwind` — the
    /// worker surfaces `Unprocessable` and KEEPS DRAINING, so a single adversarial
    /// event can never silently blind the receive path. Proven by requiring the
    /// worker to also process the NEXT event (>= 2 `Unprocessable` emits). A dead
    /// worker would emit at most one, then wedge (the harness times out at 0/1).
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn a_pause_marker_drains_every_queued_event_before_the_router_is_cleared() {
        // How much backlog sits ahead of the marker.
        const QUEUED: usize = 12;

        // SECURITY RULE 12, at the exact point it can be broken.
        //
        // The worker resolves the router at PROCESSING time. A pause that
        // cleared the router directly — rather than sending a marker THROUGH the
        // intake queue and letting the worker clear it once it has drained
        // everything ahead of it — would drop every stored event still queued
        // from the burst's own replay: downloaded, never applied, and (with the
        // generation's advance burned in the same breath) re-requested only by a
        // later REQ's lookback. That is the silent loss of legitimate offline
        // backlog the rule forbids.
        //
        // Deterministic by construction: every signal is queued BEFORE the worker
        // is spawned, so "the marker is behind the backlog" is a fact about the
        // channel, not a race. Swapping the worker's arm to clear-then-drain
        // makes this red at `seen == 0`.
        let dir = TempDir::new().unwrap();
        let keys = Keys::generate();
        let circle = Arc::new(CircleManager::new_unencrypted(dir.path(), &keys).unwrap());
        let bus = EventBus::new();
        let mut rx_bus = bus.subscribe();
        let processor = Arc::new(EngineProcessor::new(Arc::clone(&circle), bus.clone()));

        let group_hex = hex::encode([0x77u8; 32]);
        let sub = SubscriptionId::new("s_group_0");
        let relay = "wss://relay.example".to_string();
        let router = Arc::new(RwLock::new(Router::new()));
        router.write().await.register_group(
            std::slice::from_ref(&relay),
            &sub,
            &HashSet::from([group_hex.clone()]),
        );
        // An open generation, so the pause has an advance to burn.
        processor.note_subscription_opened(&group_hex, 1_000);

        // The queued backlog. The `#[cfg(test)]` panic seam inside
        // `process_group_event` is the per-event delivery oracle: reaching it
        // proves the worker ROUTED that event, which is exactly what a premature
        // router clear would prevent. (Scary panic messages on stderr are
        // expected.)
        let (tx, worker_rx) = mpsc::channel::<RawSignal>(QUEUED + 1);
        for _ in 0..QUEUED {
            tx.send(RawSignal::Event(Box::new(RawEvent {
                relay_url: RelayUrl::parse(&relay).unwrap(),
                subscription_id: sub.clone(),
                event: event_445(&group_hex, "__panic_for_test__"),
            })))
            .await
            .expect("the queue is sized for the whole backlog plus the marker");
        }
        let (ack_tx, ack_rx) = tokio::sync::oneshot::channel();
        tx.send(RawSignal::Pause {
            registrations: router.read().await.registrations(),
            ack: ack_tx,
        })
        .await
        .expect("the marker goes in BEHIND the backlog");

        tokio::spawn(run_worker(
            worker_rx,
            Arc::clone(&router),
            Arc::clone(&processor),
            Arc::new(RepairQueue::default()),
            Keys::generate().public_key(),
        ));

        tokio::time::timeout(Duration::from_secs(20), ack_rx)
            .await
            .expect("the marker must be acked")
            .expect("the worker must not drop the ack");

        let mut seen = 0usize;
        while let Ok(Ok(ev)) = tokio::time::timeout(Duration::from_millis(200), rx_bus.recv()).await
        {
            if matches!(
                ev,
                LiveSyncEvent::Status {
                    reason: SyncStatusReason::Unprocessable
                }
            ) {
                seen += 1;
            }
        }
        assert_eq!(
            seen, QUEUED,
            "every event queued AHEAD of the pause marker must be routed before the \
             router is cleared. Clearing first drops whatever is still queued from \
             this burst's own replay — downloaded backlog, discarded silently \
             (Security Rule 12)"
        );

        assert!(
            router.read().await.is_empty(),
            "...and only THEN is the router cleared: an acked marker means no further \
             ingest can start"
        );
        assert!(
            processor.all_advances_consumed(),
            "the marker must also burn every open generation's advance \
             (`note_delivery_gap`), or the next EOSE would advance a cursor over a \
             window this pause interrupted"
        );
    }

    #[tokio::test]
    async fn a_pause_marker_keeps_an_unapplied_hold_back_instead_of_forgetting_it() {
        // The `forget_*` trap, in one assertion.
        //
        // What this pins precisely: a hold-back recorded in the generation the
        // pause interrupts still bounds the advance of the generation the NEXT
        // burst opens. Two things could break it — the pause dropping the anchor
        // (a `forget_*`, which the CI guard also refuses in that function), or
        // `CursorAnchors::open_generation` no longer carrying an un-redeemed
        // hold-back across the generation boundary. Either way the next burst's
        // EOSE would advance the cursor straight over an event this device
        // recorded as un-applied, and nothing would ever ask for it again.
        //
        // The OTHER half of `note_delivery_gap` — burning the interrupted
        // generation's own pending advance, so a late EOSE for it cannot redeem
        // one — is pinned by `all_advances_consumed()` in the marker test above
        // and by `security_rule_gates::rule12_a_delivery_gap_suppresses_every_open_generation`.
        let dir = TempDir::new().unwrap();
        let keys = Keys::generate();
        let circle = Arc::new(CircleManager::new_unencrypted(dir.path(), &keys).unwrap());
        let processor = Arc::new(EngineProcessor::new(Arc::clone(&circle), EventBus::new()));
        let group_hex = hex::encode([0x66u8; 32]);
        let stream = crate::relay::live_sync::group_cursor_stream(&group_hex);

        // A generation with an un-applied event held at T_held.
        let opened = chrono::Utc::now().timestamp() - 600;
        let held = opened - 60;
        processor.note_subscription_opened(&group_hex, opened);
        processor.note_dropped_before_ingest(&group_hex, held);

        // The pause.
        processor.note_delivery_gap();

        // The next burst opens a fresh generation and its relay EOSEs.
        let next_open = chrono::Utc::now().timestamp();
        processor.note_subscription_opened(&group_hex, next_open);
        assert!(processor.note_end_of_stored_events(&group_hex));

        let cursor = circle
            .read_sync_cursor(&stream)
            .expect("cursor read")
            .expect("the EOSE advanced something");
        assert_eq!(
            cursor,
            held.saturating_mul(1000),
            "the hold-back must survive the pause and bound the NEXT generation's \
             advance. `forget`ting the anchor instead would let the advance reach the \
             new REQ's open time ({}), sailing over an event the plane recorded as \
             un-applied",
            next_open.saturating_mul(1000)
        );
        assert!(
            cursor < next_open.saturating_mul(1000),
            "anti-vacuity: the two values must actually differ, or this test would \
             pass for a cursor that never moved"
        );
    }

    #[tokio::test]
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

        let (tx, worker_rx) = mpsc::channel::<RawSignal>(16);
        tokio::spawn(run_worker(
            worker_rx,
            Arc::clone(&router),
            processor,
            Arc::new(RepairQueue::default()),
            Keys::generate().public_key(),
        ));

        let raw = |content: &str| {
            RawSignal::Event(Box::new(RawEvent {
                relay_url: RelayUrl::parse(&relay).unwrap(),
                subscription_id: sub.clone(),
                event: event_445(&group_hex, content),
            }))
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

    /// A `CLOSED` naming one of OUR live subscriptions must schedule a repair;
    /// one naming an id we never issued must do nothing at all.
    ///
    /// The second half is the security half: a relay chooses the id in a
    /// `CLOSED`, so if an arbitrary id could reach the repair queue, any relay
    /// could make this device allocate backoff state and re-subscribe on demand.
    ///
    /// Deterministic without sleeps: the UNOWNED close is delivered FIRST on the
    /// same FIFO channel drained by one worker, so by the time the owned one's
    /// `RelayError` reaches the bus the unowned one has already been handled. If
    /// it had been recorded, it would be in the queue.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn a_closed_schedules_a_repair_only_for_a_subscription_we_own() {
        let dir = TempDir::new().unwrap();
        let keys = Keys::generate();
        let circle = Arc::new(CircleManager::new_unencrypted(dir.path(), &keys).unwrap());
        let bus = EventBus::new();
        let mut rx_bus = bus.subscribe();
        let processor = Arc::new(EngineProcessor::new(circle, bus.clone()));
        let repair = Arc::new(RepairQueue::default());

        let group_hex = hex::encode([0x77u8; 32]);
        let ours = SubscriptionId::new("s_group_0");
        let relay = "wss://relay.example".to_string();
        let router = Arc::new(RwLock::new(Router::new()));
        router.write().await.register_group(
            std::slice::from_ref(&relay),
            &ours,
            &HashSet::from([group_hex]),
        );

        let (tx, worker_rx) = mpsc::channel::<RawSignal>(16);
        tokio::spawn(run_worker(
            worker_rx,
            Arc::clone(&router),
            processor,
            Arc::clone(&repair),
            Keys::generate().public_key(),
        ));

        let closed = |sub: &SubscriptionId| RawSignal::SubscriptionClosed {
            relay_url: RelayUrl::parse(&relay).unwrap(),
            subscription_id: sub.clone(),
            kind: ClosedKind::Dropped,
        };
        tx.send(closed(&SubscriptionId::new("an_id_we_never_issued")))
            .await
            .unwrap();
        tx.send(closed(&ours)).await.unwrap();

        let saw_status = tokio::time::timeout(Duration::from_secs(5), async {
            loop {
                match rx_bus.recv().await {
                    Ok(LiveSyncEvent::Status {
                        reason: SyncStatusReason::RelayError,
                    }) => return true,
                    Ok(_) | Err(broadcast::error::RecvError::Lagged(_)) => {}
                    Err(broadcast::error::RecvError::Closed) => return false,
                }
            }
        })
        .await
        .expect("a CLOSED on one of our subs must surface a status");
        assert!(saw_status, "the worker dropped the bus before reporting");

        let due = repair.take_due();
        assert_eq!(
            due,
            vec![RepairKey {
                relay_url: RelayUrl::parse(&relay).unwrap(),
                sub_id: ours,
            }],
            "exactly the subscription we own may be scheduled for repair; a \
             relay naming an arbitrary id must buy no work at all"
        );
    }

    /// A `CLOSED` must not count as a delivery.
    ///
    /// It is the relay ENDING the REQ, not serving it. Counting it would let a
    /// relay that ends and re-issues our subscription on a loop keep that
    /// endpoint's silence window permanently fresh — hiding, from the one health
    /// arm that measures delivery, the fact that nothing is arriving.
    ///
    /// The `RelayError` status is a sound happens-before edge for the
    /// assertion because `note_subscription_closed` schedules and emits in that
    /// order, and the delivery note (if any) would precede both.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn a_closed_is_not_counted_as_a_delivery() {
        let dir = TempDir::new().unwrap();
        let circle =
            Arc::new(CircleManager::new_unencrypted(dir.path(), &Keys::generate()).unwrap());
        let bus = EventBus::new();
        let mut rx_bus = bus.subscribe();
        let processor = Arc::new(EngineProcessor::new(circle, bus.clone()));

        let group_hex = hex::encode([0x55u8; 32]);
        let sub = SubscriptionId::new("s_group_0");
        let relay = "wss://relay.example".to_string();
        let key = RepairKey {
            relay_url: RelayUrl::parse(&relay).unwrap(),
            sub_id: sub.clone(),
        };
        let router = Arc::new(RwLock::new(Router::new()));
        router.write().await.register_group(
            std::slice::from_ref(&relay),
            &sub,
            &HashSet::from([group_hex]),
        );

        // A window opened well in the past, so any delivery note would be
        // visible as a jump to ~now.
        let opened_at = chrono::Utc::now().timestamp() - 10_000;
        processor.open_delivery_window(&key, opened_at);

        let (tx, worker_rx) = mpsc::channel::<RawSignal>(16);
        tokio::spawn(run_worker(
            worker_rx,
            Arc::clone(&router),
            Arc::clone(&processor),
            Arc::new(RepairQueue::default()),
            Keys::generate().public_key(),
        ));

        tx.send(RawSignal::SubscriptionClosed {
            relay_url: key.relay_url.clone(),
            subscription_id: sub,
            kind: ClosedKind::Dropped,
        })
        .await
        .unwrap();

        tokio::time::timeout(Duration::from_secs(5), async {
            loop {
                if matches!(
                    rx_bus.recv().await,
                    Ok(LiveSyncEvent::Status {
                        reason: SyncStatusReason::RelayError
                    })
                ) {
                    return;
                }
            }
        })
        .await
        .expect("the worker must handle the CLOSED");

        assert_eq!(
            processor.last_delivery_secs(&key),
            Some(opened_at),
            "a CLOSED must leave the silence window exactly where it was; \
             refreshing it would let a relay that ends our REQ on a loop mask \
             its own silence"
        );
    }

    /// A `CLOSED` reaches the worker classified, and the classification is the
    /// one that decides whether the pool kept the subscription.
    #[tokio::test]
    async fn the_receiver_forwards_a_closed_with_its_pool_disposition() {
        let (btx, brx) = broadcast::channel::<RelayPoolNotification>(8);
        let (mtx, mut mrx) = mpsc::channel::<RawSignal>(8);
        let (_cancel_tx, cancel_rx) = tokio::sync::watch::channel(false);
        let (processor, _dir) = bare_processor();
        let handle = tokio::spawn(run_receiver(
            brx,
            mtx,
            processor,
            Arc::new(AtomicBool::new(false)),
            Arc::new(AtomicBool::new(false)),
            cancel_rx,
        ));

        let closed = |message: &'static str| RelayPoolNotification::Message {
            relay_url: RelayUrl::parse("wss://relay.example").unwrap(),
            message: nostr::RelayMessage::Closed {
                subscription_id: std::borrow::Cow::Owned(SubscriptionId::new("s")),
                message: std::borrow::Cow::Borrowed(message),
            },
        };
        btx.send(closed("")).unwrap();
        btx.send(closed("rate-limited: slow down")).unwrap();

        let mut seen: Vec<ClosedKind> = Vec::new();
        while seen.len() < 2 {
            let signal = tokio::time::timeout(Duration::from_secs(2), mrx.recv())
                .await
                .expect("a CLOSED must be forwarded")
                .expect("the receiver must not drop the channel");
            if let RawSignal::SubscriptionClosed { kind, .. } = signal {
                seen.push(kind);
            }
        }
        assert_eq!(
            seen,
            vec![ClosedKind::Dropped, ClosedKind::Throttled],
            "an unprefixed CLOSED is the case the pool DELETES the subscription \
             for; `rate-limited:` is the one it keeps"
        );

        drop(btx);
        tokio::time::timeout(Duration::from_secs(2), handle)
            .await
            .expect("receiver exits on Closed")
            .expect("clean join");
    }

    /// A `CLOSED` the full intake queue drops must not wedge or stop the
    /// receiver — and must not be mistaken for a dead worker.
    ///
    /// The repair it would have scheduled IS lost, which is deliberate: the
    /// receiver holds no router, so recording one from here could not tell one
    /// of our subscription ids from an id a relay invented, and a relay flooding
    /// CLOSEDs while the queue is full would grow the backoff table without
    /// bound (Rule 12). The backstop is the health tick's subscription-PRESENCE
    /// arm — the deleted REQ is gone from `client.subscriptions()`, so it fires
    /// deterministically on the next tick rather than waiting out a silence
    /// window; that arm is pinned in the session tests.
    ///
    /// # Why this makes no ordering assumption
    ///
    /// The queue is filled once and NEVER drained, so both notifications below
    /// are necessarily dropped — there is no freed slot for either to slip into,
    /// and therefore no drain-then-refill choreography to lose a race with. The
    /// oracle is that the broadcast empties: `is_empty()` covers BOTH sends, and
    /// the receiver can only have taken the second one by continuing past the
    /// first. A loop that stopped at the `CLOSED` would leave the marker
    /// unreceived and time out here.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn a_closed_dropped_by_a_full_intake_queue_neither_wedges_nor_stops_the_receiver() {
        let (btx, brx) = broadcast::channel::<RelayPoolNotification>(8);
        // Capacity 1, filled through a second sender and never drained: every
        // try_send from here on reports Full, never Closed.
        let (mtx, _mrx) = mpsc::channel::<RawSignal>(1);
        mtx.clone()
            .try_send(RawSignal::EndOfStoredEvents {
                relay_url: RelayUrl::parse("wss://relay.example").unwrap(),
                subscription_id: SubscriptionId::new("filler"),
            })
            .expect("the queue takes its one slot");

        let (processor, _dir) = bare_processor();
        let wedged = Arc::new(AtomicBool::new(false));
        let (_cancel_tx, cancel_rx) = tokio::sync::watch::channel(false);
        let handle = tokio::spawn(run_receiver(
            brx,
            mtx,
            processor,
            Arc::new(AtomicBool::new(false)),
            Arc::clone(&wedged),
            cancel_rx,
        ));

        let relay_url = RelayUrl::parse("wss://relay.example").unwrap();
        btx.send(RelayPoolNotification::Message {
            relay_url: relay_url.clone(),
            message: nostr::RelayMessage::Closed {
                subscription_id: std::borrow::Cow::Owned(SubscriptionId::new("s")),
                message: std::borrow::Cow::Borrowed(""),
            },
        })
        .unwrap();
        btx.send(RelayPoolNotification::Message {
            relay_url,
            message: nostr::RelayMessage::EndOfStoredEvents(std::borrow::Cow::Owned(
                SubscriptionId::new("after_the_drop"),
            )),
        })
        .unwrap();

        // Both consumed ⇒ the loop continued past the dropped CLOSED.
        tokio::time::timeout(Duration::from_secs(5), async {
            while !btx.is_empty() {
                tokio::task::yield_now().await;
            }
        })
        .await
        .expect("the receiver must consume BOTH notifications: stopping at the dropped CLOSED would leave the second one unreceived");

        assert!(
            !wedged.load(std::sync::atomic::Ordering::Acquire),
            "a dropped CLOSED is backpressure, not a dead worker: flipping the wedged flag here would tear down a perfectly live session"
        );

        drop(btx);
        tokio::time::timeout(Duration::from_secs(2), handle)
            .await
            .expect("receiver exits cleanly on Closed")
            .expect("clean join");
    }

    /// The worker exiting must not be silent.
    ///
    /// `run_receiver` matched only `TrySendError::Full`, so a `Closed` channel —
    /// the worker having returned — fell through with no signal: the receive
    /// plane was dead while `is_running()` (a shutdown flag) still said `true`,
    /// so nothing restarted it. The receiver must now raise the wedged flag,
    /// surface a status, and stop.
    #[tokio::test]
    async fn a_dead_worker_raises_the_wedged_flag_and_surfaces_a_status() {
        let (btx, brx) = broadcast::channel::<RelayPoolNotification>(8);
        // Drop the worker end immediately: every try_send now reports `Closed`.
        let (mtx, mrx) = mpsc::channel::<RawSignal>(8);
        drop(mrx);

        let dir = TempDir::new().unwrap();
        let circle =
            Arc::new(CircleManager::new_unencrypted(dir.path(), &Keys::generate()).unwrap());
        let bus = EventBus::new();
        let mut rx_bus = bus.subscribe();
        let processor = Arc::new(EngineProcessor::new(circle, bus));
        let wedged = Arc::new(AtomicBool::new(false));
        let (_cancel_tx, cancel_rx) = tokio::sync::watch::channel(false);

        let handle = tokio::spawn(run_receiver(
            brx,
            mtx,
            processor,
            Arc::new(AtomicBool::new(false)),
            Arc::clone(&wedged),
            cancel_rx,
        ));

        btx.send(RelayPoolNotification::Event {
            relay_url: RelayUrl::parse("wss://relay.example").unwrap(),
            subscription_id: SubscriptionId::new("s"),
            event: Box::new(event_445("aa00", "x")),
        })
        .unwrap();

        tokio::time::timeout(Duration::from_secs(5), handle)
            .await
            .expect("a receiver with no worker must stop, not spin")
            .expect("clean join");
        assert!(
            wedged.load(std::sync::atomic::Ordering::Acquire),
            "a dead worker must make is_running() answer false"
        );
        let status = tokio::time::timeout(Duration::from_secs(2), rx_bus.recv())
            .await
            .expect("a dead worker must surface a status")
            .expect("bus alive");
        assert_eq!(
            status,
            LiveSyncEvent::Status {
                reason: SyncStatusReason::RelayError
            },
            "the failure must be visible, not swallowed"
        );
        drop(btx);
    }

    /// R7 (GAP-B+F): a broadcast `Lagged` must NOT kill `run_receiver` (losing
    /// deliveries beats losing the plane), and a `Closed` channel must stop it
    /// cleanly. We overfill a cap-4 broadcast BEFORE the receiver is polled so
    /// its first `recv()` yields `Lagged`, then require a post-lag MARKER to
    /// still be forwarded; then drop the sender and require the task to exit.
    ///
    /// What the skip costs the CURSOR is the other half, and it is not visible
    /// here: this processor has no open generation to suppress. It is gated in
    /// `security_rule_gates.rs` (Rule 12) against real cursors.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn run_receiver_survives_lagged_then_stops_on_closed() {
        let (btx, brx) = broadcast::channel::<RelayPoolNotification>(4);
        let (mtx, mut mrx) = mpsc::channel::<RawSignal>(64);
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
        let (_cancel_tx, cancel_rx) = tokio::sync::watch::channel(false);
        let (processor, _dir) = bare_processor();
        let handle = tokio::spawn(run_receiver(
            brx,
            mtx,
            processor,
            Arc::clone(&shutdown),
            Arc::new(AtomicBool::new(false)),
            cancel_rx,
        ));

        // A distinctive event AFTER the lag.
        let (marker_id, marker) = notif("MARKER");
        btx.send(marker).unwrap();

        // The receiver must swallow Lagged and still forward the post-lag marker.
        let mut forwarded = false;
        while let Ok(Some(signal)) = tokio::time::timeout(Duration::from_secs(2), mrx.recv()).await
        {
            if matches!(signal, RawSignal::Event(raw) if raw.event.id == marker_id) {
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

    /// The regression test for a permanent, unrecoverable wedge.
    ///
    /// `run_receiver` used to have exactly two exits: the `shutdown` flag —
    /// which it only polls at the TOP of the loop, so a task parked in
    /// `recv().await` never sees it — and the pool's `Shutdown`/`Closed`
    /// notification. That second exit is NOT guaranteed:
    /// `RelayPool::shutdown` latches an atomic BEFORE awaiting relay removal
    /// and only then sends the notification, so a bounded caller
    /// (`LiveSyncCore::stop_inner` wraps it in a 10s timeout) can drop the
    /// future in between. The notification is then never sent, and the latch
    /// makes every retry a no-op.
    ///
    /// A receiver stuck there holds its `mpsc::Sender`, which keeps
    /// `run_worker` alive, which holds `Arc<EngineProcessor>` →
    /// `Arc<CircleManager>` → the Rule-14 `LiveSessionGuard`. The result is an
    /// unowned MLS writer and a database no isolate can reopen for the life of
    /// the process.
    ///
    /// So: hold the broadcast sender (never `Closed`), never send `Shutdown`,
    /// and require the task to exit on `cancel` alone.
    #[tokio::test]
    async fn run_receiver_exits_on_cancel_without_any_pool_notification() {
        let (btx, brx) = broadcast::channel::<RelayPoolNotification>(4);
        let (mtx, _mrx) = mpsc::channel::<RawSignal>(4);
        let shutdown = Arc::new(AtomicBool::new(false));
        let (cancel_tx, cancel_rx) = tokio::sync::watch::channel(false);
        let (processor, _dir) = bare_processor();

        let handle = tokio::spawn(run_receiver(
            brx,
            mtx,
            processor,
            Arc::clone(&shutdown),
            Arc::new(AtomicBool::new(false)),
            cancel_rx,
        ));

        // The task is now parked in `recv().await`: nothing has been sent, and
        // `btx` is deliberately kept alive so the channel never closes.
        tokio::time::sleep(Duration::from_millis(50)).await;
        assert!(
            !handle.is_finished(),
            "precondition: the receiver must be parked"
        );

        cancel_tx.send(true).expect("cancel send");

        tokio::time::timeout(Duration::from_secs(2), handle)
            .await
            .expect("run_receiver must exit on cancel with no pool notification")
            .expect("the receiver task must join cleanly");
        drop(btx);
    }

    /// Pins `wait_for` over `changed()`.
    ///
    /// `stop` raises cancel BEFORE anything else, so a receiver can be created
    /// after the flag is already true. `changed()` marks the value seen at
    /// subscribe time and would miss exactly that case — the task would park
    /// forever on a session that was already told to stop.
    #[tokio::test]
    async fn run_receiver_observes_a_cancel_raised_before_it_subscribed() {
        let (btx, brx) = broadcast::channel::<RelayPoolNotification>(4);
        let (mtx, _mrx) = mpsc::channel::<RawSignal>(4);
        let shutdown = Arc::new(AtomicBool::new(false));
        // Mirror `LiveSyncCore`'s construction EXACTLY, because the details are
        // the whole test. An earlier version reused the receiver from
        // `channel(false)` and called `send`; that receiver has not observed the
        // send either, so `changed()` also fires and the test passed against the
        // very implementation it claimed to rule out (verified by mutation).
        //
        // Production drops the initial receiver (`watch::channel(false).0`) and
        // subscribes later, which pins two things at once:
        //   * `send` would return `Err` and DISCARD the value with no receivers
        //     alive — hence `send_replace`;
        //   * `Sender::subscribe` marks all prior sends as seen, so `changed()`
        //     would park forever — hence `wait_for`.
        let cancel_tx = tokio::sync::watch::channel(false).0;
        cancel_tx.send_replace(true);
        let cancel_rx = cancel_tx.subscribe();

        let (processor, _dir) = bare_processor();
        let handle = tokio::spawn(run_receiver(
            brx,
            mtx,
            processor,
            Arc::clone(&shutdown),
            Arc::new(AtomicBool::new(false)),
            cancel_rx,
        ));
        tokio::time::timeout(Duration::from_secs(2), handle)
            .await
            .expect("a pre-existing cancel must still be observed")
            .expect("the receiver task must join cleanly");
        drop(btx);
    }
}
