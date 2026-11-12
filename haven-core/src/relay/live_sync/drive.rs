//! The live plane's side of the durable fanout: which lifecycle may use it,
//! and what a drive is sent through.
//!
//! While a caller's claim that the app's lifecycle reads `resumed` stands,
//! the receive engine records every commit and proposal it surfaces as a
//! durable fanout, in the hold that
//! staged it, and a task of its own sends each through the fanout driver
//! ([`crate::relay::fanout::Publishing`]). The ingest worker never waits on a
//! relay for one.
//!
//! [`Lifecycle`] is the one place that decides, in two questions kept
//! apart: how what the engine hands over at an ingest or an advance is taken
//! in ([`Lifecycle::receives`]) and whether stored records are driven, and in
//! which mode ([`Lifecycle::drives`]). Only the foreground makes a commit and
//! records it. A background burst makes none and finishes what a relay has
//! already decided ([`DriveMode::FinishOnly`]); a pause drives nothing; a
//! session that has only been started takes in and finishes as a burst does
//! (privacy invariant `INV-L-WEDGED-CIRCLE-IS-DETECTED-AND-NAMED`).
//!
//! The foreground is never inferred from which call arrived. Each entry that
//! can begin it takes its caller's [`Claim`], and begins it on
//! [`Claim::Foreground`] alone.

use std::future::Future;
use std::pin::Pin;
use std::sync::atomic::{AtomicU64, AtomicU8, Ordering};
use std::sync::Arc;

use cgka_traits::TransportEndpoint;
use nostr::Event;
use tokio::sync::watch;

use crate::nostr::mls::types::{FanoutEndpointFailure, TransportMessage};
use crate::relay::fanout::{
    interrupted, DriveMode, FanoutClock, FanoutSend, FanoutTargetOutcome, InFlight, ModeSource,
    Taken, UnrecordedPublisher, WallClock,
};
use crate::relay::RelayManager;

/// What the caller of a session entry says of the app at the moment it
/// calls: carried by the call, because this crate cannot see the screen.
///
/// The app makes [`Self::Foreground`] only while its lifecycle state reads
/// `resumed`, and [`Self::Nothing`] for every other reading — an unset
/// state, a transient one, no binding at all.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Claim {
    /// The app's lifecycle state reads `resumed`. On Android that is the
    /// activity resumed AND its window focused.
    Foreground,
    /// Nothing is claimed: the app is in the background, or cannot say.
    Nothing,
}

/// Which lifecycle a session is serving.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Lifecycle {
    /// Started — a start claims nothing — and claimed for by no caller
    /// since: a background wake that cold-launched the process, a launch
    /// whose first frame has not arrived, a visit that ended while the start
    /// was in flight.
    Launched,
    /// A caller has claimed the foreground ([`Claim::Foreground`]): the
    /// claim made once a start has returned or by the heal that follows a
    /// resume, the app's resume, the user's own repair, or the
    /// subscription-health tick.
    Foreground,
    /// A background burst that is open: its REQs are issued and its sockets
    /// are up, until the pause that ends it.
    Burst,
    /// A pause, or a session being stopped: no REQ and no socket.
    Background,
}

impl Lifecycle {
    /// How a session in this lifecycle takes in what the engine hands it at
    /// an ingest or an advance.
    ///
    /// In the foreground as a plane that drives: every commit and proposal
    /// is recorded as a durable fanout in the hold that staged it
    /// ([`DriveMode::Full`]). In a background burst, and while a pause
    /// drains what was already downloaded, as a plane that makes no commit:
    /// what was received is settled inputs-only, nothing is staged, and
    /// nothing leaves the device from the ingest ([`DriveMode::FinishOnly`]);
    /// and so does a session that has only been started, which a background
    /// wake that cold-launched the process also is.
    #[must_use]
    pub const fn receives(self) -> DriveMode {
        match self {
            Self::Foreground => DriveMode::Full,
            Self::Launched | Self::Burst | Self::Background => DriveMode::FinishOnly,
        }
    }

    /// Whether a session in this lifecycle begins a drive of the stored
    /// records, and in which mode: the full one in the foreground; the one
    /// that only finishes in a background burst and in a session nobody has
    /// claimed the foreground for; none while paused, when every socket is
    /// down and none may come up.
    ///
    /// A pass that began in the foreground and outlives it goes on in
    /// [`DriveMode::FinishOnly`] ([`Leash`]).
    #[must_use]
    pub const fn drives(self) -> Option<DriveMode> {
        match self {
            Self::Foreground => Some(DriveMode::Full),
            Self::Launched | Self::Burst => Some(DriveMode::FinishOnly),
            Self::Background => None,
        }
    }
}

/// The session's current [`Lifecycle`], shared with what a drive is sent
/// through.
///
/// `SeqCst` on both sides, with the count of relay calls under way
/// ([`InFlight`]): a pause writes this and then reads the count, a call
/// counts itself and then reads this, and one of the two must see the other.
#[derive(Debug)]
pub(super) struct LifecycleCell {
    state: AtomicU8,
    /// How many times the lifecycle has changed: a pass that began before
    /// one of them is not in the lifecycle that follows it.
    changes: AtomicU64,
}

impl LifecycleCell {
    pub(super) const fn new() -> Self {
        Self {
            state: AtomicU8::new(Lifecycle::Launched as u8),
            changes: AtomicU64::new(0),
        }
    }

    pub(super) fn get(&self) -> Lifecycle {
        match self.state.load(Ordering::SeqCst) {
            x if x == Lifecycle::Foreground as u8 => Lifecycle::Foreground,
            x if x == Lifecycle::Burst as u8 => Lifecycle::Burst,
            x if x == Lifecycle::Background as u8 => Lifecycle::Background,
            _ => Lifecycle::Launched,
        }
    }

    pub(super) fn set(&self, lifecycle: Lifecycle) {
        let was = self.state.swap(lifecycle as u8, Ordering::SeqCst);
        if was != lifecycle as u8 {
            self.changes.fetch_add(1, Ordering::SeqCst);
        }
    }

    /// How many times the lifecycle has changed.
    pub(super) fn changes(&self) -> u64 {
        self.changes.load(Ordering::SeqCst)
    }

    /// `Launched` becomes `Foreground`, and the answer is whether it did; a
    /// background lifecycle is left as it is, since only its own next open
    /// ends it.
    pub(super) fn prove_foreground(&self) -> bool {
        let proven = self
            .state
            .compare_exchange(
                Lifecycle::Launched as u8,
                Lifecycle::Foreground as u8,
                Ordering::SeqCst,
                Ordering::SeqCst,
            )
            .is_ok();
        if proven {
            self.changes.fetch_add(1, Ordering::SeqCst);
        }
        proven
    }
}

/// What the live plane's drives are sent through.
///
/// A recorded commit or proposal goes through `fanout`, one relay per call. A
/// Welcome, and a proposal no record could be written for, go through
/// `publisher`. In the product both are one publish pool that carries nothing
/// else ([`Self::over`]): never the engine's own client, whose sockets hold
/// the session's subscriptions.
///
/// No `Debug`: the transport holds a relay client.
pub struct LiveDriver {
    /// Where a recorded event is sent.
    pub fanout: Arc<dyn FanoutSend>,
    /// Where what has no record is sent. Acked means acked.
    pub publisher: Arc<dyn UnrecordedPublisher>,
    /// The clock records are staged, paced and bounded on.
    pub clock: Arc<dyn FanoutClock>,
}

impl LiveDriver {
    /// The product's driver: `pool`'s fanout transport and its publish
    /// ladder, on the device's clock.
    #[must_use]
    pub fn over(pool: &Arc<RelayManager>) -> Self {
        Self {
            fanout: Arc::new(pool.fanout_transport()),
            publisher: Arc::clone(pool) as Arc<dyn UnrecordedPublisher>,
            clock: Arc::new(WallClock),
        }
    }
}

/// What one pass of the live plane's drive is held to: the mode it is in, and
/// when it must give its relays up.
///
/// A leash is taken in the lifecycle its pass begins in and belongs to that
/// stretch of it alone. It reads [`DriveMode::Full`] only when it was taken
/// in the foreground and that foreground has not ended since; taken anywhere
/// else — a background burst, a session only started — it reads
/// [`DriveMode::FinishOnly`] from its first read to its last, whatever the
/// lifecycle becomes. So a leash only ever narrows, and one taken outside the
/// foreground never reads `Full` at all.
///
/// Once the lifecycle it was taken in has changed — the foreground ended, a
/// burst was paused, a started session was claimed — the pass takes no
/// further relay and has no budget left for anything it had not begun
/// ([`ModeSource::stands`]): the lifecycle that follows has a pass of its
/// own. A step it had already decided on runs to its end: a confirm begun
/// completes with its fold, and a publish already handed to the publisher
/// runs out its own ladder. It makes no first send, begins no publish,
/// decides no rollback or bound, makes no queued change and begins no
/// confirm; it stores the answers of the calls it has out, and a commit a
/// stored acknowledgement stands for is the next pass's to confirm.
pub(super) struct Leash<'a> {
    pub(super) lifecycle: &'a LifecycleCell,
    /// The session's cancellation, when a session owns the processor.
    pub(super) halt: Option<watch::Receiver<bool>>,
    /// What counts the relay calls the pass begins, for the pause; `None`
    /// for a leash whose pass makes none.
    in_flight: Option<&'a InFlight>,
    /// The mode the pass began in and [`LifecycleCell::changes`] when the
    /// leash was taken; `None` when it was taken in a lifecycle that drives
    /// nothing.
    began: Option<(DriveMode, u64)>,
}

impl<'a> Leash<'a> {
    /// The leash of a pass that begins now.
    pub(super) fn over(lifecycle: &'a LifecycleCell, halt: Option<watch::Receiver<bool>>) -> Self {
        // The count before the lifecycle: a change between the two reads
        // shows in one of them.
        let changes = lifecycle.changes();
        let began = lifecycle.get().drives().map(|mode| (mode, changes));
        Self {
            lifecycle,
            halt,
            in_flight: None,
            began,
        }
    }

    /// The leash of a drive pass that begins now, each of whose relay calls
    /// `in_flight` counts from its mark to its answer.
    pub(super) fn counted(
        lifecycle: &'a LifecycleCell,
        in_flight: &'a InFlight,
        halt: Option<watch::Receiver<bool>>,
    ) -> Self {
        Self {
            in_flight: Some(in_flight),
            ..Self::over(lifecycle, halt)
        }
    }

    /// Whether the lifecycle this leash was taken in drives at all.
    pub(super) const fn runs(&self) -> bool {
        self.began.is_some()
    }
}

impl ModeSource for Leash<'_> {
    fn mode(&self) -> DriveMode {
        match self.began {
            Some((DriveMode::Full, at)) if at == self.lifecycle.changes() => DriveMode::Full,
            _ => DriveMode::FinishOnly,
        }
    }

    /// Whether the lifecycle this leash was taken in still stands: only
    /// then may its pass take a relay, or begin anything that needs room.
    fn stands(&self) -> bool {
        self.began
            .is_some_and(|(_, at)| at == self.lifecycle.changes())
    }

    fn in_flight(&self) -> Option<&InFlight> {
        self.in_flight
    }
}

impl Leash<'_> {
    /// Completes when the session is being stopped; never for a processor no
    /// session owns.
    async fn halted(&self) {
        match self.halt.clone() {
            // A sender that is gone is a session that is gone.
            Some(mut halt) => {
                let _ = halt.wait_for(|halted| *halted).await;
            }
            None => std::future::pending().await,
        }
    }
}

/// A drive's transport, on the session's leash.
///
/// No relay is taken once the lifecycle the pass began in has changed, so a
/// pass under way then begins no further call: nothing is stored for a relay
/// that was not taken. Which records a pass may send at all is its mode's to
/// say, and the driver's to read. A call under way when the session is
/// stopped is given up, and answered as what it is — an attempt that never
/// returned, which the record keeps as possibly exposed and nothing ever
/// rolls back.
pub(super) struct Leashed<'a> {
    pub(super) inner: &'a dyn FanoutSend,
    pub(super) leash: &'a Leash<'a>,
}

#[async_trait::async_trait]
impl FanoutSend for Leashed<'_> {
    async fn take(&self, target: &str) -> Option<Taken> {
        if !self.leash.stands() {
            return None;
        }
        let taken = tokio::select! {
            biased;
            () = self.leash.halted() => None,
            taken = self.inner.take(target) => taken,
        };
        // A relay waited for across a change of lifecycle is given back
        // uncalled: nothing was stored for it, so nothing was begun.
        taken.filter(|_| self.leash.stands())
    }

    async fn publish(
        &self,
        target: &str,
        message: &TransportMessage,
        taken: Taken,
    ) -> FanoutTargetOutcome {
        // The call first: it was marked as begun before this, and an answer
        // that is already there is the answer.
        tokio::select! {
            biased;
            outcome = self.inner.publish(target, message, taken) => outcome,
            () = self.leash.halted() => FanoutTargetOutcome::Failed(FanoutEndpointFailure::new(
                interrupted(&TransportEndpoint(target.to_owned())),
            )),
        }
    }

    async fn publish_location(
        &self,
        event: &nostr::Event,
        targets: &[String],
    ) -> crate::relay::RelayResult<crate::relay::PublishResult> {
        // Given up when the session is stopped: nothing says a relay took it.
        tokio::select! {
            biased;
            sent = self.inner.publish_location(event, targets) => sent,
            () = self.leash.halted() => Err(crate::relay::RelayError::AllRelaysFailed),
        }
    }
}

/// A drive's publisher of what has no record. Nothing is begun outside the
/// full mode, and a publish under way when the session is stopped is given
/// up: either way nothing says a relay took the event.
pub(super) struct LeashedPublisher<'a> {
    pub(super) inner: &'a dyn UnrecordedPublisher,
    pub(super) leash: &'a Leash<'a>,
}

impl UnrecordedPublisher for LeashedPublisher<'_> {
    fn publish_unrecorded<'a>(
        &'a self,
        event: &'a Event,
        relays: &'a [String],
    ) -> Pin<Box<dyn Future<Output = bool> + Send + 'a>> {
        Box::pin(async move {
            // Counted before the mode is read, as a fanout call is at its
            // mark: a pause either waits for the publish or finds it never
            // begun.
            let _counted = self.leash.in_flight.map(InFlight::count);
            if self.leash.mode() != DriveMode::Full {
                return false;
            }
            tokio::select! {
                biased;
                acked = self.inner.publish_unrecorded(event, relays) => acked,
                () = self.leash.halted() => false,
            }
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The one decision, for both questions. Only the foreground makes a
    /// commit and drives in full. A burst, a pause and a session only
    /// started take in what they receive without making one; a burst and a
    /// session only started finish what is stored, and a pause drives
    /// nothing.
    #[test]
    fn only_the_foreground_makes_commits_and_a_pause_drives_nothing() {
        let (full, finishing) = (DriveMode::Full, DriveMode::FinishOnly);
        assert_eq!(
            [
                Lifecycle::Foreground,
                Lifecycle::Burst,
                Lifecycle::Background,
                Lifecycle::Launched,
            ]
            .map(|lifecycle| (lifecycle.receives(), lifecycle.drives())),
            [
                (full, Some(full)),
                (finishing, Some(finishing)),
                (finishing, None),
                (finishing, Some(finishing)),
            ],
        );
    }

    /// A session that has only been started is not in the foreground until a
    /// foreground caller says so, and a background one is never made
    /// foreground by that caller alone. The answer says which happened, once.
    #[test]
    fn a_started_session_becomes_foreground_only_when_proven_and_a_background_one_never() {
        let cell = LifecycleCell::new();
        assert_eq!(cell.get(), Lifecycle::Launched);
        assert!(cell.prove_foreground());
        assert_eq!(cell.get(), Lifecycle::Foreground);
        assert!(
            !cell.prove_foreground(),
            "a session already in the foreground was said to have just entered it",
        );
        cell.set(Lifecycle::Background);
        assert!(!cell.prove_foreground());
        assert_eq!(cell.get(), Lifecycle::Background);
    }

    /// A leash only narrows. Taken in the foreground it reads full until
    /// that foreground ends, and never again; taken outside the foreground —
    /// a session only started, a background burst, a pause — it never reads
    /// full, whatever the lifecycle becomes afterwards.
    #[test]
    fn a_leash_reads_full_only_in_the_foreground_it_was_taken_in() {
        let cell = LifecycleCell::new();
        cell.set(Lifecycle::Foreground);
        let leash = Leash::over(&cell, None);
        assert_eq!(leash.mode(), DriveMode::Full);
        cell.set(Lifecycle::Background);
        assert_eq!(leash.mode(), DriveMode::FinishOnly);
        cell.set(Lifecycle::Foreground);
        assert_eq!(leash.mode(), DriveMode::FinishOnly);

        for outside in [Lifecycle::Launched, Lifecycle::Burst, Lifecycle::Background] {
            let cell = LifecycleCell::new();
            cell.set(outside);
            let leash = Leash::over(&cell, None);
            assert_eq!(leash.mode(), DriveMode::FinishOnly);
            cell.set(Lifecycle::Foreground);
            assert_eq!(
                leash.mode(),
                DriveMode::FinishOnly,
                "a leash taken outside the foreground widened when the foreground came",
            );
        }
    }

    /// A pass runs where its lifecycle drives and nowhere else, and holds its
    /// relays only while that very stretch stands: a burst's pass takes none
    /// once the burst is paused, nor in the burst after it; a started
    /// session's takes none once the session is claimed.
    #[test]
    fn a_leash_runs_where_its_lifecycle_drives_and_stands_until_that_lifecycle_changes() {
        let cell = LifecycleCell::new();
        cell.set(Lifecycle::Background);
        assert!(
            !Leash::over(&cell, None).runs(),
            "a pass began while the session was paused",
        );

        cell.set(Lifecycle::Burst);
        let burst = Leash::over(&cell, None);
        assert!(burst.runs() && burst.stands());
        cell.set(Lifecycle::Burst);
        assert!(burst.stands(), "a burst opened again ended its own pass");
        cell.set(Lifecycle::Background);
        assert!(!burst.stands());
        cell.set(Lifecycle::Burst);
        assert!(
            !burst.stands(),
            "a pass of one burst took a relay in the next",
        );

        let cell = LifecycleCell::new();
        let started = Leash::over(&cell, None);
        assert!(started.runs() && started.stands());
        assert!(cell.prove_foreground());
        assert!(
            !started.stands() && started.mode() == DriveMode::FinishOnly,
            "a pass begun before the claim went on as the foreground's",
        );
    }

    /// A relay that is free only when the test says so, and a publisher that
    /// counts what it is handed.
    #[derive(Default)]
    struct Held {
        waiting: tokio::sync::Notify,
        free: tokio::sync::Notify,
        handed: std::sync::atomic::AtomicUsize,
    }

    #[async_trait::async_trait]
    impl FanoutSend for Held {
        async fn take(&self, _target: &str) -> Option<Taken> {
            self.waiting.notify_one();
            self.free.notified().await;
            Some(Taken::nothing())
        }

        async fn publish(
            &self,
            target: &str,
            _message: &TransportMessage,
            _taken: Taken,
        ) -> FanoutTargetOutcome {
            FanoutTargetOutcome::Failed(FanoutEndpointFailure::new(interrupted(
                &TransportEndpoint(target.to_owned()),
            )))
        }

        async fn publish_location(
            &self,
            _event: &Event,
            _targets: &[String],
        ) -> crate::relay::RelayResult<crate::relay::PublishResult> {
            Err(crate::relay::RelayError::AllRelaysFailed)
        }
    }

    impl UnrecordedPublisher for Held {
        fn publish_unrecorded<'a>(
            &'a self,
            _event: &'a Event,
            _relays: &'a [String],
        ) -> Pin<Box<dyn Future<Output = bool> + Send + 'a>> {
            self.handed.fetch_add(1, Ordering::SeqCst);
            Box::pin(async { true })
        }
    }

    /// A relay the pass was still waiting for when the foreground ended is
    /// given back uncalled, and the pass takes none afterwards — not even
    /// when the foreground has come back: what it may do was decided when it
    /// ended.
    #[tokio::test]
    async fn a_relay_waited_for_across_the_end_of_the_foreground_is_given_back_uncalled() {
        let cell = LifecycleCell::new();
        cell.set(Lifecycle::Foreground);
        let (leash, relay) = (Leash::over(&cell, None), Held::default());
        let leashed = Leashed {
            inner: &relay,
            leash: &leash,
        };
        {
            let take = leashed.take("wss://relay.example.com");
            tokio::pin!(take);
            tokio::select! {
                biased;
                _ = &mut take => panic!("the relay was taken before it was free"),
                () = relay.waiting.notified() => {}
            }
            cell.set(Lifecycle::Background);
            relay.free.notify_one();
            assert!(
                take.await.is_none(),
                "a relay that came free after the foreground ended was kept for a call",
            );
        }
        cell.set(Lifecycle::Foreground);
        relay.free.notify_one();
        assert!(
            leashed.take("wss://relay.example.com").await.is_none(),
            "a pass that outlived the foreground took a relay when it came back",
        );
    }

    /// A burst's own pass takes a relay while the burst is open and gives
    /// back one it was still waiting for when the pause came; and it hands
    /// nothing to the publisher of what has no record, open or not.
    #[tokio::test]
    async fn a_bursts_pass_takes_a_relay_until_the_pause_and_publishes_nothing_unrecorded() {
        let cell = LifecycleCell::new();
        cell.set(Lifecycle::Burst);
        let (leash, relay) = (Leash::over(&cell, None), Held::default());
        let leashed = Leashed {
            inner: &relay,
            leash: &leash,
        };
        relay.free.notify_one();
        assert!(
            leashed.take("wss://relay.example.com").await.is_some(),
            "a burst's own pass could not take a relay",
        );
        let publisher = LeashedPublisher {
            inner: &relay,
            leash: &leash,
        };
        let event = nostr::EventBuilder::new(nostr::Kind::Custom(445), "sealed")
            .sign_with_keys(&nostr::Keys::generate())
            .expect("a signed event");
        assert!(
            !publisher
                .publish_unrecorded(&event, &["wss://relay.example.com".to_owned()])
                .await
                && relay.handed.load(Ordering::SeqCst) == 0,
            "a burst's pass published something that has no record",
        );
        {
            let take = leashed.take("wss://relay.example.com");
            tokio::pin!(take);
            tokio::select! {
                biased;
                _ = &mut take => panic!("the relay was taken before it was free"),
                () = relay.waiting.notified() => {}
            }
            cell.set(Lifecycle::Background);
            relay.free.notify_one();
            assert!(
                take.await.is_none(),
                "a relay that came free after the pause was kept for a call",
            );
        }
        assert!(leashed.take("wss://relay.example.com").await.is_none());
    }

    /// The pass's publisher of what has no record hands nothing on once the
    /// foreground has ended, and stays so when it returns.
    #[tokio::test]
    async fn a_leashed_publisher_hands_nothing_on_once_the_foreground_has_ended() {
        let cell = LifecycleCell::new();
        cell.set(Lifecycle::Foreground);
        let (leash, outbox) = (Leash::over(&cell, None), Held::default());
        let publisher = LeashedPublisher {
            inner: &outbox,
            leash: &leash,
        };
        let event = nostr::EventBuilder::new(nostr::Kind::Custom(445), "sealed")
            .sign_with_keys(&nostr::Keys::generate())
            .expect("a signed event");
        let relays = ["wss://relay.example.com".to_owned()];
        assert!(publisher.publish_unrecorded(&event, &relays).await);
        for after in [Lifecycle::Background, Lifecycle::Foreground] {
            cell.set(after);
            assert!(!publisher.publish_unrecorded(&event, &relays).await);
        }
        assert_eq!(
            outbox.handed.load(Ordering::SeqCst),
            1,
            "a pass that outlived the foreground published something that has no record",
        );
    }

    /// A publisher that holds each publish until the test lets it answer.
    #[derive(Default)]
    struct Unanswered(tokio::sync::Notify);

    impl UnrecordedPublisher for Unanswered {
        fn publish_unrecorded<'a>(
            &'a self,
            _event: &'a Event,
            _relays: &'a [String],
        ) -> Pin<Box<dyn Future<Output = bool> + Send + 'a>> {
            Box::pin(async move {
                self.0.notified().await;
                true
            })
        }
    }

    /// A drive's leash hands its pass's relay calls the count a pause waits
    /// on, and no other leash does; the publisher of what has no record holds
    /// a count for the whole of its publish — a pause that lands under it
    /// still finds it — and one it refuses leaves nothing counted.
    #[tokio::test]
    async fn a_counted_leash_counts_an_unrecorded_publish_until_it_answers() {
        let cell = LifecycleCell::new();
        cell.set(Lifecycle::Foreground);
        let in_flight = InFlight::default();
        let leash = Leash::counted(&cell, &in_flight, None);
        assert!(leash.in_flight().is_some() && Leash::over(&cell, None).in_flight().is_none());
        let outbox = Unanswered::default();
        let publisher = LeashedPublisher {
            inner: &outbox,
            leash: &leash,
        };
        let event = nostr::EventBuilder::new(nostr::Kind::Custom(445), "sealed")
            .sign_with_keys(&nostr::Keys::generate())
            .expect("a signed event");
        let relays = ["wss://relay.example.com".to_owned()];
        {
            let publish = publisher.publish_unrecorded(&event, &relays);
            tokio::pin!(publish);
            assert!(futures::poll!(&mut publish).is_pending());
            assert_eq!(in_flight.now(), 1, "a publish under way was not counted");
            cell.set(Lifecycle::Background);
            assert_eq!(
                in_flight.now(),
                1,
                "a pause found the publish under way ended"
            );
            outbox.0.notify_one();
            assert!(publish.await);
        }
        assert_eq!(
            in_flight.now(),
            0,
            "an answered publish left its count behind"
        );
        assert!(!publisher.publish_unrecorded(&event, &relays).await);
        assert_eq!(
            in_flight.now(),
            0,
            "a refused publish left its count behind"
        );
    }
}
