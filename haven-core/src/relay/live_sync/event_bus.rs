//! The engine's internal fan-out bus for [`LiveSyncEvent`]s.
//!
//! A thin wrapper over a `tokio::sync::broadcast` channel. The producer (the
//! processor) calls [`EventBus::send`], which intentionally ignores a
//! "no subscribers" error so a dropped consumer never stalls the receive path.
//! Each consumer gets its own [`broadcast::Receiver`] via
//! [`EventBus::subscribe`]; the FFI `live_events` stream reads through
//! [`super::LiveEvents`], which owns what a lag means.

use tokio::sync::broadcast;

use super::config::BUS_CAP;
use super::event::LiveSyncEvent;

/// A cloneable handle to the engine's event bus.
#[derive(Clone)]
pub struct EventBus {
    tx: broadcast::Sender<LiveSyncEvent>,
}

impl EventBus {
    /// Creates a bus with the default [`BUS_CAP`] capacity.
    #[must_use]
    pub fn new() -> Self {
        Self::with_capacity(BUS_CAP)
    }

    /// Creates a bus with an explicit capacity (used by tests).
    #[must_use]
    pub fn with_capacity(capacity: usize) -> Self {
        let (tx, _rx) = broadcast::channel(capacity);
        Self { tx }
    }

    /// Subscribes a new consumer. Only events sent *after* this call are
    /// delivered to the returned receiver.
    #[must_use]
    pub fn subscribe(&self) -> broadcast::Receiver<LiveSyncEvent> {
        self.tx.subscribe()
    }

    /// Publishes an event. A `SendError` (no live subscribers) is swallowed so
    /// the producer is never blocked or failed by a missing consumer — a
    /// dropped consumer is recoverable via the cursor, an errored producer is
    /// not.
    pub fn send(&self, event: LiveSyncEvent) {
        let _ = self.tx.send(event);
    }

    /// Current number of live receivers (test/diagnostic aid).
    #[must_use]
    pub fn receiver_count(&self) -> usize {
        self.tx.receiver_count()
    }
}

impl Default for EventBus {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::relay::live_sync::event::SyncStatusReason;
    use tokio::sync::broadcast::error::TryRecvError;

    fn status(reason: SyncStatusReason) -> LiveSyncEvent {
        LiveSyncEvent::Status { reason }
    }

    #[test]
    fn delivers_events_in_order() {
        // broadcast send / try_recv are runtime-agnostic, so the ordering
        // contract is testable synchronously.
        let bus = EventBus::with_capacity(8);
        let mut rx = bus.subscribe();
        bus.send(status(SyncStatusReason::Connecting));
        bus.send(status(SyncStatusReason::Connected));

        assert_eq!(rx.try_recv().unwrap(), status(SyncStatusReason::Connecting));
        assert_eq!(rx.try_recv().unwrap(), status(SyncStatusReason::Connected));
        assert!(matches!(rx.try_recv(), Err(TryRecvError::Empty)));
    }

    #[test]
    fn send_with_no_subscribers_is_not_an_error() {
        let bus = EventBus::with_capacity(8);
        assert_eq!(bus.receiver_count(), 0);
        // No subscriber: send must be a no-op, never panic/err.
        bus.send(status(SyncStatusReason::SessionStarted));
    }

    #[test]
    fn overflow_surfaces_as_lagged_then_recovers() {
        // Capacity 2; push 4 without draining → the receiver lags. The next
        // recv reports Lagged, then resumes from the oldest retained event.
        let bus = EventBus::with_capacity(2);
        let mut rx = bus.subscribe();
        for _ in 0..4 {
            bus.send(status(SyncStatusReason::Connected));
        }
        assert!(matches!(rx.try_recv(), Err(TryRecvError::Lagged(_))));
        // After a lag, retained events are still delivered (not fatal).
        assert_eq!(rx.try_recv().unwrap(), status(SyncStatusReason::Connected));
    }

    #[test]
    fn second_subscriber_after_first_dropped_still_works() {
        let bus = EventBus::with_capacity(8);
        let rx1 = bus.subscribe();
        assert_eq!(bus.receiver_count(), 1);
        drop(rx1);

        let mut rx2 = bus.subscribe();
        bus.send(status(SyncStatusReason::BackgroundResumed));
        assert_eq!(
            rx2.try_recv().unwrap(),
            status(SyncStatusReason::BackgroundResumed)
        );
    }

    #[test]
    fn two_concurrent_subscribers_both_receive_the_same_event() {
        // The fan-out guarantee: every live receiver sees every event.
        let bus = EventBus::with_capacity(8);
        let mut rx1 = bus.subscribe();
        let mut rx2 = bus.subscribe();
        assert_eq!(bus.receiver_count(), 2);

        let ev = status(SyncStatusReason::Connected);
        bus.send(ev.clone());

        assert_eq!(rx1.try_recv().unwrap(), ev);
        assert_eq!(rx2.try_recv().unwrap(), ev);
    }

    #[test]
    fn dropping_all_senders_yields_closed_after_draining() {
        // The real bus must produce the `Closed` that ends a consumer —
        // buffered events drain first, then Closed.
        let bus = EventBus::with_capacity(8);
        let mut rx = bus.subscribe();
        bus.send(status(SyncStatusReason::SessionStarted));
        drop(bus); // last sender gone

        // The buffered event is still delivered...
        assert_eq!(
            rx.try_recv().unwrap(),
            status(SyncStatusReason::SessionStarted)
        );
        // ...then the channel reports Closed.
        assert!(matches!(rx.try_recv(), Err(TryRecvError::Closed)));
    }
}
