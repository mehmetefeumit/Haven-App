//! What each own relay and lookup relay serves of the user's own events, as
//! the maintenance passes last found and left it.
//!
//! One cell per relay and kind — `KeyPackage` (30443), relay list (10002) and
//! inbox relay list (10050) — written only by the passes that probe and heal
//! them, so the relay settings page shows what maintenance did and can never
//! disagree with it. A cell is judged by maintenance's own rules and settled
//! by the relay's own `OK`; the page reads a network-free snapshot.
//!
//! Beside them, per own inbox relay, how it answered the relay-list pass's
//! read of this account's gift wraps ([`OwnRelayBoard::ask_inbox_reads`]): a
//! relay that refuses it stores every invitation sent there out of this
//! device's reach, and no republish changes that.

use std::future::Future;
use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, PoisonError};
use std::time::{Duration, Instant};

use futures::stream::{FuturesUnordered, StreamExt};
use nostr::{Event, Kind, PublicKey, Timestamp};

use super::key_package::{kp_event_d_tag, kp_event_is_pre_migration, RelayKpEntry};
use super::key_package::{RelayKpPerRelay, RelayKpSnapshot};
use super::kp_lifetime::TrackedKpLifetime;
use super::relay_list::list_relay_healthy;
use crate::log_alias;
use crate::nostr::mls::TrackedKeyPackage;
use crate::relay::clock_skew::DeviceClockComplaint;
use crate::relay::nip42::Nip42Signer;
use crate::relay::publishers::dedup_key;
use crate::relay::{InboxRead, RelayFetchOutcome, RelayManager, SendAck};

/// One of the user's own events a relay is expected to serve.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OwnKind {
    /// Kind 30443, on the `KeyPackage` list.
    KeyPackage,
    /// Kind 10002, on the `KeyPackage` list and the lookup relays.
    RelayList,
    /// Kind 10050, on the inbox list and the lookup relays.
    InboxRelayList,
}

impl OwnKind {
    const fn index(self) -> usize {
        match self {
            Self::KeyPackage => 0,
            Self::RelayList => 1,
            Self::InboxRelayList => 2,
        }
    }
}

/// Why Haven publishes nothing of a kind right now.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OwnHold {
    /// The storage-reset notice is unanswered.
    AwaitingResetAcknowledgement,
    /// The list it is published to is empty.
    NoRelaysConfigured,
    /// The stored publish setting for this list is off.
    PublishingSuppressed,
}

/// What one relay serves of one kind, or what became of what was sent to it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OwnCell {
    /// Asked; the answer is not judged yet.
    Checking,
    /// It serves what maintenance would leave in place, or it returned `OK
    /// true` for what this pass sent it.
    Current,
    /// Sent; its `OK` has not arrived.
    Publishing,
    /// It answered in full and holds nothing of this account's.
    Missing,
    /// It serves an event of this account that maintenance would replace.
    Outdated,
    /// It returned `OK false` for what this pass sent it.
    Refused,
    /// Proven not to serve it, then sent it, and no `OK` came.
    Unconfirmed,
    /// It could not be reached or did not finish its answer, and nothing it
    /// said proves what it holds.
    NoAnswer,
}

/// A probe's verdict on one relay: [`OwnCell`]'s judged states.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Probed {
    /// See [`OwnCell::Current`].
    Current,
    /// See [`OwnCell::Missing`].
    Missing,
    /// See [`OwnCell::Outdated`].
    Outdated,
    /// See [`OwnCell::NoAnswer`].
    NoAnswer,
}

impl From<Probed> for OwnCell {
    fn from(probed: Probed) -> Self {
        match probed {
            Probed::Current => Self::Current,
            Probed::Missing => Self::Missing,
            Probed::Outdated => Self::Outdated,
            Probed::NoAnswer => Self::NoAnswer,
        }
    }
}

/// How an offer's answers settle their cells.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OfferMode {
    /// What is sent is what the record already names: each cell settles the
    /// moment its relay answers.
    Heal,
    /// A replacement the record names only once a relay accepted it: a cell
    /// whose outcome turns on that waits for [`OwnPass::settle_rest`].
    Mint,
}

/// What an offer's relays did. No `Debug`: it holds relay URLs (Rule 15).
#[derive(Default)]
pub struct Offered {
    /// The targets that returned `OK true`, as they were given.
    pub accepted: Vec<String>,
    /// When none accepted: what the refusals said about this device's clock.
    pub clock: Option<DeviceClockComplaint>,
}

/// One relay's cell of one kind, the relay as the user's list names it.
#[derive(Clone, PartialEq, Eq)]
pub struct OwnRelayCell {
    /// The list entry, verbatim.
    pub relay_url: String,
    /// What it serves.
    pub status: OwnCell,
}

/// Redacting `Debug`: the relay is named by a salted handle (Rule 15).
impl std::fmt::Debug for OwnRelayCell {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("OwnRelayCell")
            .field(
                "relay",
                &log_alias::relay(log_alias::RelayUrl(&self.relay_url)),
            )
            .field("status", &self.status)
            .finish()
    }
}

/// How one own inbox relay answered a read of this account's gift wraps, the
/// relay as the user's list names it.
#[derive(Clone, PartialEq, Eq)]
pub struct OwnInboxReadCell {
    /// The list entry, verbatim.
    pub relay_url: String,
    /// How it answered.
    pub read: InboxRead,
}

/// Redacting `Debug`: the relay is named by a salted handle (Rule 15).
impl std::fmt::Debug for OwnInboxReadCell {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("OwnInboxReadCell")
            .field(
                "relay",
                &log_alias::relay(log_alias::RelayUrl(&self.relay_url)),
            )
            .field("read", &self.read)
            .finish()
    }
}

/// One kind of the board.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OwnKindSnapshot {
    /// Why nothing of this kind is published now; its cells are then empty.
    pub hold: Option<OwnHold>,
    /// How long ago the last pass of this kind ended; `None` before one has.
    pub checked_secs_ago: Option<u64>,
    /// The relays that pass asked, in its order.
    pub cells: Vec<OwnRelayCell>,
}

/// The whole board.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OwnBoardSnapshot {
    /// A pass is running or waiting to run.
    pub running: bool,
    /// Kind 30443.
    pub key_package: OwnKindSnapshot,
    /// Kind 10002.
    pub relay_list: OwnKindSnapshot,
    /// Kind 10050.
    pub inbox_relay_list: OwnKindSnapshot,
    /// Each own inbox relay's answer to the last gift-wrap read, in the
    /// list's order; empty before one, and after an edit of the inbox list.
    pub inbox_reads: Vec<OwnInboxReadCell>,
}

struct Entry {
    /// The relay as [`dedup_key`] spells it, so two spellings are one cell.
    canonical: String,
    relay_url: String,
    status: OwnCell,
    probed: Option<Probed>,
    sent: Option<SendAck>,
}

#[derive(Default)]
struct KindBoard {
    /// Moved by every write that replaces the kind's cells, so a pass the
    /// write superseded writes nothing more.
    generation: u64,
    hold: Option<OwnHold>,
    finished: Option<Instant>,
    cells: Vec<Entry>,
}

impl KindBoard {
    fn entry(&mut self, relay: &str) -> Option<&mut Entry> {
        let key = dedup_key(relay);
        self.cells.iter_mut().find(|entry| entry.canonical == key)
    }

    fn replace(&mut self, hold: Option<OwnHold>) {
        self.generation += 1;
        self.hold = hold;
        self.cells.clear();
    }
}

/// The last gift-wrap read's answers. Moved by every inbox list edit, as a
/// kind is, so a read the edit superseded writes nothing.
#[derive(Default)]
struct InboxReads {
    generation: u64,
    cells: Vec<OwnInboxReadCell>,
}

/// A monotonic clock: production reads [`Instant::now`], a test moves its own.
pub type BoardClock = Arc<dyn Fn() -> Instant + Send + Sync>;

/// The user's own relays and what each serves, per kind. One per account.
pub struct OwnRelayBoard {
    kinds: Mutex<[KindBoard; 3]>,
    inbox_reads: Mutex<InboxReads>,
    running: AtomicUsize,
    clock: BoardClock,
}

impl Default for OwnRelayBoard {
    fn default() -> Self {
        Self::with_clock(Arc::new(Instant::now))
    }
}

impl OwnRelayBoard {
    /// A board whose `checked_secs_ago` reads `clock`.
    #[must_use]
    pub fn with_clock(clock: BoardClock) -> Self {
        Self {
            kinds: Mutex::new(Default::default()),
            inbox_reads: Mutex::new(InboxReads::default()),
            running: AtomicUsize::new(0),
            clock,
        }
    }

    fn kinds(&self) -> std::sync::MutexGuard<'_, [KindBoard; 3]> {
        self.kinds.lock().unwrap_or_else(PoisonError::into_inner)
    }

    fn inbox_reads(&self) -> std::sync::MutexGuard<'_, InboxReads> {
        self.inbox_reads
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
    }

    fn with_kind<R>(&self, kind: OwnKind, write: impl FnOnce(&mut KindBoard) -> R) -> R {
        write(&mut self.kinds()[kind.index()])
    }

    /// What the board holds now. No network, no wait on a pass.
    #[must_use]
    pub fn snapshot(&self) -> OwnBoardSnapshot {
        let now = (self.clock)();
        let kinds = self.kinds();
        let kind = |kind: OwnKind| {
            let board = &kinds[kind.index()];
            OwnKindSnapshot {
                hold: board.hold,
                checked_secs_ago: board
                    .finished
                    .map(|at| now.saturating_duration_since(at).as_secs()),
                cells: board
                    .cells
                    .iter()
                    .map(|entry| OwnRelayCell {
                        relay_url: entry.relay_url.clone(),
                        status: entry.status,
                    })
                    .collect(),
            }
        };
        OwnBoardSnapshot {
            running: self.running.load(Ordering::SeqCst) > 0,
            key_package: kind(OwnKind::KeyPackage),
            relay_list: kind(OwnKind::RelayList),
            inbox_relay_list: kind(OwnKind::InboxRelayList),
            inbox_reads: self.inbox_reads().cells.clone(),
        }
    }

    /// Marks a pass running, from before it waits for its turn until the
    /// guard drops, however it ends.
    #[must_use]
    pub fn running(&self) -> Running<'_> {
        self.running.fetch_add(1, Ordering::SeqCst);
        Running(&self.running)
    }

    /// Where `kind` stands: a pass takes it before it reads the list it acts
    /// on and hands it to [`Self::hold`] or [`Self::begin`], so a list edit
    /// landing after that read leaves the pass writing nothing.
    #[must_use]
    pub fn generation(&self, kind: OwnKind) -> u64 {
        self.with_kind(kind, |board| board.generation)
    }

    /// Records that nothing of `kind` is published now, and why, unless a
    /// write since `seen` superseded the pass.
    pub fn hold(&self, kind: OwnKind, seen: u64, hold: OwnHold) {
        let now = (self.clock)();
        self.with_kind(kind, |board| {
            if board.generation == seen {
                board.replace(Some(hold));
                board.finished = Some(now);
            }
        });
    }

    /// Forgets every cell of `kind`: what they said was judged against a list
    /// that has changed, or by a pass that failed before it could judge.
    pub fn clear(&self, kind: OwnKind) {
        self.with_kind(kind, |board| board.replace(None));
    }

    /// Where the gift-wrap reads stand: taken before the inbox list is read
    /// and handed to [`Self::ask_inbox_reads`], as [`Self::generation`] is.
    #[must_use]
    pub fn inbox_reads_generation(&self) -> u64 {
        self.inbox_reads().generation
    }

    /// Forgets every inbox relay's answer: the list they were asked from has
    /// changed.
    pub fn clear_inbox_reads(&self) {
        let mut reads = self.inbox_reads();
        reads.generation += 1;
        reads.cells.clear();
    }

    /// Asks each of `inbox`, on an identity connection of its own that
    /// answers the relay's NIP-42 challenge as `signer`
    /// ([`RelayManager::read_own_inbox_per_relay`]), for this account's gift
    /// wraps from now — so it normally brings nothing back — and records how
    /// each answered, unless an edit since `seen` superseded the read. A
    /// relay that refuses this read refuses the invitee's own reads too.
    ///
    /// The last answers are forgotten as the read begins, as a pass's cells
    /// read checking: no warning stands on an answer being asked again.
    pub async fn ask_inbox_reads(&self, signer: &Arc<Nip42Signer>, seen: u64, inbox: &[String]) {
        {
            let mut reads = self.inbox_reads();
            if reads.generation == seen {
                reads.cells.clear();
            }
        }
        let answers = Box::pin(RelayManager::read_own_inbox_per_relay(
            signer,
            Some(Timestamp::now()),
            1,
            inbox,
        ))
        .await;
        let mut reads = self.inbox_reads();
        if reads.generation == seen {
            reads.cells = inbox
                .iter()
                .zip(&answers)
                .map(|(relay_url, answer)| OwnInboxReadCell {
                    relay_url: relay_url.clone(),
                    read: answer.inbox_read(),
                })
                .collect();
        }
    }

    /// Forgets `relay`'s cell of `kind` only.
    pub fn forget(&self, kind: OwnKind, relay: &str) {
        let key = dedup_key(relay);
        self.with_kind(kind, |board| {
            board.cells.retain(|entry| entry.canonical != key);
        });
    }

    /// Begins a pass of `kind` over `targets`: each is `Checking`, every
    /// other cell and any hold is gone. A pass a write since `seen`
    /// superseded writes nothing at all.
    #[must_use]
    pub fn begin(&self, kind: OwnKind, seen: u64, targets: &[String]) -> OwnPass<'_> {
        let generation = self.with_kind(kind, |board| {
            if board.generation != seen {
                // Generations only grow, so `seen` never matches again.
                return seen;
            }
            board.replace(None);
            for target in targets {
                let key = dedup_key(target);
                if board.cells.iter().all(|entry| entry.canonical != key) {
                    board.cells.push(Entry {
                        canonical: key,
                        relay_url: target.clone(),
                        status: OwnCell::Checking,
                        probed: None,
                        sent: None,
                    });
                }
            }
            board.generation
        });
        OwnPass {
            board: self,
            kind,
            generation,
        }
    }
}

/// See [`OwnRelayBoard::running`].
pub struct Running<'a>(&'a AtomicUsize);

impl Drop for Running<'_> {
    fn drop(&mut self) {
        self.0.fetch_sub(1, Ordering::SeqCst);
    }
}

/// One pass of one kind over the board.
///
/// Dropped however the pass ends: a cell still `Checking` is forgotten and one
/// still `Publishing` is settled as if a replacement superseded it, so no pass
/// leaves either behind and none paints a cell current without an `OK`.
pub struct OwnPass<'a> {
    board: &'a OwnRelayBoard,
    kind: OwnKind,
    generation: u64,
}

impl OwnPass<'_> {
    /// Runs `write` on this pass's kind unless a later write superseded it.
    fn write<R>(&self, write: impl FnOnce(&mut KindBoard) -> R) -> Option<R> {
        self.board.with_kind(self.kind, |board| {
            (board.generation == self.generation).then(|| write(board))
        })
    }

    /// Judges each relay's answer with `verdict` into its cell, returning
    /// the verdicts in the order of `answers`.
    pub fn judge(
        &mut self,
        answers: &[RelayFetchOutcome],
        verdict: impl Fn(&RelayFetchOutcome) -> Probed,
    ) -> Vec<Probed> {
        let verdicts: Vec<Probed> = answers.iter().map(verdict).collect();
        self.write(|board| {
            for (answer, &probed) in answers.iter().zip(&verdicts) {
                if let Some(entry) = board.entry(&answer.relay_url) {
                    entry.probed = Some(probed);
                    entry.status = probed.into();
                    entry.sent = None;
                }
            }
        });
        verdicts
    }

    /// Offers `event` to each of `targets` at once, and writes each relay's
    /// cell the moment its own answer lands; `ack` bounds each wait.
    pub async fn offer(
        &mut self,
        relay: &RelayManager,
        event: &Event,
        targets: &[String],
        mode: OfferMode,
        ack: Duration,
    ) -> Offered {
        self.write(|board| {
            for target in targets {
                if let Some(entry) = board.entry(target) {
                    entry.status = OwnCell::Publishing;
                    entry.sent = None;
                }
            }
        });
        let mut sends: FuturesUnordered<_> = targets
            .iter()
            .map(|target| async move {
                let sent = relay
                    .offer_event_to(event, target, ack)
                    .await
                    .unwrap_or(SendAck::Unanswered);
                (target, sent)
            })
            .collect();
        let mut offered = Offered::default();
        let mut clocks: Option<DeviceClockComplaint> = None;
        while let Some((target, sent)) = sends.next().await {
            match sent {
                SendAck::Accepted => offered.accepted.push(target.clone()),
                SendAck::Refused { clock: Some(clock) } => {
                    clocks = Some(clocks.map_or(clock, |seen| seen.merge(clock)));
                }
                SendAck::Refused { clock: None } | SendAck::Unanswered => {}
            }
            self.write(|board| {
                if let Some(entry) = board.entry(target) {
                    entry.sent = Some(sent);
                    let (kept, replaced) = (
                        settle(entry.probed, sent, false),
                        settle(entry.probed, sent, true),
                    );
                    if mode == OfferMode::Heal || kept == replaced {
                        entry.status = kept;
                    }
                }
            });
        }
        if offered.accepted.is_empty() {
            offered.clock = clocks;
        }
        offered
    }

    /// Settles every cell an offer left `Publishing`: `superseded` when the
    /// pass replaced the package those relays were judged against.
    pub fn settle_rest(&mut self, superseded: bool) {
        self.write(|board| settle_publishing(board, superseded));
    }
}

fn settle_publishing(board: &mut KindBoard, superseded: bool) {
    for entry in board
        .cells
        .iter_mut()
        .filter(|entry| entry.status == OwnCell::Publishing)
    {
        entry.status = settle(
            entry.probed,
            entry.sent.unwrap_or(SendAck::Unanswered),
            superseded,
        );
    }
}

impl Drop for OwnPass<'_> {
    fn drop(&mut self) {
        let now = (self.board.clock)();
        self.write(|board| {
            board
                .cells
                .retain(|entry| entry.status != OwnCell::Checking);
            settle_publishing(board, true);
            board.finished = Some(now);
        });
    }
}

/// What a sent-to cell reads once its relay answered (or did not), from what
/// the probe proved before the send.
///
/// A relay that still serves the record's current item stays current whatever
/// it said, unless this pass replaced that item; a relay proven not to serve
/// it stays red without an `OK`, labelled by what happened; a relay never
/// proven either way that did not answer is still unknown.
fn settle(probed: Option<Probed>, sent: SendAck, superseded: bool) -> OwnCell {
    let probed = probed.unwrap_or(Probed::NoAnswer);
    match sent {
        SendAck::Accepted => OwnCell::Current,
        _ if probed == Probed::Current && !superseded => OwnCell::Current,
        SendAck::Refused { .. } => OwnCell::Refused,
        SendAck::Unanswered if probed == Probed::NoAnswer => OwnCell::NoAnswer,
        SendAck::Unanswered => OwnCell::Unconfirmed,
    }
}

/// One relay's answer for `kind`, judged with `current`. A relay answers a
/// REQ with whatever it likes, so another author's event never counts; the
/// page is newest first.
#[must_use]
pub fn probe_verdict(
    answer: &RelayFetchOutcome,
    own: &PublicKey,
    kind: Kind,
    current: &dyn Fn(&[&Event]) -> bool,
) -> Probed {
    let mine: Vec<&Event> = answer
        .events
        .iter()
        .filter(|event| event.pubkey == *own && event.kind == kind)
        .collect();
    if current(&mine) {
        Probed::Current
    } else if !answer.drained {
        Probed::NoAnswer
    } else if mine.is_empty() {
        Probed::Missing
    } else {
        Probed::Outdated
    }
}

/// Whether one relay's own kind-30443 events serve `tracked` as maintenance
/// counts it ([`RelayKpSnapshot::serves_current_package`]).
#[must_use]
pub fn serves_tracked_package(
    mine: &[&Event],
    tracked: Option<&TrackedKeyPackage>,
    lifetime: TrackedKpLifetime,
) -> bool {
    RelayKpSnapshot {
        responders: vec![RelayKpPerRelay {
            relay_url: String::new(),
            canonical: mine.iter().copied().map(kp_entry).collect(),
        }],
    }
    .serves_current_package(tracked, lifetime)
}

/// Whether one relay's newest own relay list names exactly `configured`
/// ([`list_relay_healthy`]): `r` tags for a 10002, `relay` tags for a 10050.
#[must_use]
pub fn names_configured_list(mine: &[&Event], configured: &[String]) -> bool {
    mine.first().is_some_and(|newest| {
        let tag = if newest.kind == Kind::RelayList {
            "r"
        } else {
            "relay"
        };
        list_relay_healthy(&tagged_urls(newest, tag), configured)
    })
}

fn kp_entry(event: &Event) -> RelayKpEntry {
    RelayKpEntry {
        d_tag: kp_event_d_tag(event).unwrap_or_default(),
        event_id: event.id.to_hex(),
        created_at: event.created_at.as_secs(),
        pre_migration: kp_event_is_pre_migration(event),
    }
}

/// The relay list an event names, as maintenance reads it: every such tag,
/// whatever its marker.
fn tagged_urls(event: &Event, name: &str) -> Vec<String> {
    event
        .tags
        .iter()
        .filter_map(|tag| {
            let values = tag.as_slice();
            (values.len() >= 2 && values[0] == name).then(|| values[1].clone())
        })
        .collect()
}

/// One pass for every request made before it began: requests that arrive
/// while one waits for its turn join it and share its outcome, so at most one
/// pass waits behind the one running.
pub struct Coalesced<T> {
    requested: AtomicU64,
    last: Mutex<Option<(u64, T)>>,
}

impl<T> Default for Coalesced<T> {
    fn default() -> Self {
        Self {
            requested: AtomicU64::new(0),
            last: Mutex::new(None),
        }
    }
}

impl<T: Clone> Coalesced<T> {
    /// Takes a turn with `turn`, then runs `pass` unless a pass that began
    /// after this request already ran, whose outcome is returned instead.
    ///
    /// Sound because a pass reads everything it acts on after its turn
    /// begins: a request made before then is served by what it reads.
    pub async fn run<G>(&self, turn: impl Future<Output = G>, pass: impl Future<Output = T>) -> T {
        let ticket = self.requested.fetch_add(1, Ordering::SeqCst) + 1;
        let _turn = turn.await;
        if let Some((covers, outcome)) = self
            .last
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .as_ref()
        {
            if *covers >= ticket {
                return outcome.clone();
            }
        }
        let covers = self.requested.load(Ordering::SeqCst);
        let outcome = pass.await;
        *self.last.lock().unwrap_or_else(PoisonError::into_inner) = Some((covers, outcome.clone()));
        outcome
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::relay::maintenance::{KeyPackageLifetime, KIND_MARMOT_KEY_PACKAGE};
    use crate::relay::recording_front::RecordingFront;
    use crate::relay::scripted_relay::{Frame, ScriptedRelay};
    use nostr::{EventBuilder, Filter, Keys, Tag, Timestamp};
    use OwnCell::{Checking, Current, Missing, NoAnswer, Publishing, Refused};

    const VALID: TrackedKpLifetime = TrackedKpLifetime::Known(KeyPackageLifetime::new(0, u64::MAX));
    const GONE: &str = "wss://gone.example.com";
    /// A slot a conformant inviter accepts.
    const SLOT: &str = "a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1";
    const KP: Kind = Kind::Custom(KIND_MARMOT_KEY_PACKAGE);

    fn answered(relay_url: &str, drained: bool) -> RelayFetchOutcome {
        RelayFetchOutcome {
            relay_url: relay_url.to_owned(),
            responded: true,
            drained,
            refused: false,
            events: Vec::new(),
        }
    }

    fn cells(kind: &OwnKindSnapshot) -> Vec<(&str, OwnCell)> {
        kind.cells
            .iter()
            .map(|cell| (cell.relay_url.as_str(), cell.status))
            .collect()
    }

    /// A board on a clock the test moves, in whole seconds.
    fn board_at() -> (OwnRelayBoard, Arc<AtomicU64>) {
        let start = Instant::now();
        let secs = Arc::new(AtomicU64::new(0));
        let read = Arc::clone(&secs);
        let board = OwnRelayBoard::with_clock(Arc::new(move || {
            start + Duration::from_secs(read.load(Ordering::SeqCst))
        }));
        (board, secs)
    }

    #[test]
    fn a_sent_cell_settles_by_what_the_probe_proved_and_what_the_relay_said() {
        use Probed as P;
        let refused = SendAck::Refused { clock: None };
        let clock = SendAck::Refused {
            clock: Some(DeviceClockComplaint::Ahead),
        };
        let cases = [
            // An `OK true` is current whatever came before, replacement or not.
            (P::Current, SendAck::Accepted, false, Current),
            (P::Current, SendAck::Accepted, true, Current),
            (P::Missing, SendAck::Accepted, false, Current),
            (P::Outdated, SendAck::Accepted, true, Current),
            (P::NoAnswer, SendAck::Accepted, false, Current),
            // A relay still serving the record's item stays current, unless
            // this pass replaced that item.
            (P::Current, refused, false, Current),
            (P::Current, SendAck::Unanswered, false, Current),
            (P::Current, refused, true, Refused),
            (P::Current, clock, true, Refused),
            (P::Current, SendAck::Unanswered, true, OwnCell::Unconfirmed),
            // Proven not to serve it: red, labelled by what happened.
            (P::Missing, refused, false, Refused),
            (P::Outdated, clock, false, Refused),
            (P::Missing, SendAck::Unanswered, false, OwnCell::Unconfirmed),
            (P::Outdated, SendAck::Unanswered, true, OwnCell::Unconfirmed),
            // Never proven either way: a refusal is still a refusal, silence
            // is still unknown.
            (P::NoAnswer, refused, false, Refused),
            (P::NoAnswer, SendAck::Unanswered, false, NoAnswer),
            (P::NoAnswer, SendAck::Unanswered, true, NoAnswer),
        ];
        for (probed, sent, superseded, expected) in cases {
            assert_eq!(
                settle(Some(probed), sent, superseded),
                expected,
                "{probed:?} {sent:?} superseded={superseded}"
            );
        }
        assert_eq!(
            settle(None, SendAck::Unanswered, false),
            NoAnswer,
            "a cell never judged was never proven missing"
        );
    }

    #[test]
    fn a_pass_judges_cells_keyed_by_relay_and_leaves_no_checking_cell_behind() {
        let (board, _) = board_at();
        // The list's spelling and the pool's differ in case only; the cell
        // shows the list's.
        let listed = "WSS://Relay.Example.com/".to_owned();
        let targets = [
            listed.clone(),
            "wss://b.example.com".to_owned(),
            "wss://c.example.com".to_owned(),
        ];
        let mut pass = board.begin(
            OwnKind::RelayList,
            board.generation(OwnKind::RelayList),
            &targets,
        );
        assert_eq!(
            cells(&board.snapshot().relay_list),
            [
                (listed.as_str(), Checking),
                ("wss://b.example.com", Checking),
                ("wss://c.example.com", Checking)
            ],
        );
        assert_eq!(board.snapshot().relay_list.checked_secs_ago, None);

        let verdicts = pass.judge(
            &[
                answered("wss://relay.example.com/", true),
                answered("wss://b.example.com", true),
            ],
            |answer| {
                if answer.relay_url.contains("relay.example") {
                    Probed::Current
                } else {
                    Probed::Missing
                }
            },
        );
        assert_eq!(verdicts, [Probed::Current, Probed::Missing]);
        assert_eq!(
            cells(&board.snapshot().relay_list),
            [
                (listed.as_str(), Current),
                ("wss://b.example.com", Missing),
                ("wss://c.example.com", Checking)
            ],
        );
        drop(pass);
        let after = board.snapshot().relay_list;
        assert_eq!(
            cells(&after),
            [(listed.as_str(), Current), ("wss://b.example.com", Missing)],
            "a relay the pass never judged reads not checked, never checking",
        );
        assert_eq!(after.checked_secs_ago, Some(0));
        assert!(
            board.snapshot().key_package.cells.is_empty(),
            "each kind is its own"
        );
    }

    #[test]
    fn a_hold_empties_its_kind_and_the_next_pass_lifts_it() {
        let (board, secs) = board_at();
        drop(board.begin(
            OwnKind::KeyPackage,
            board.generation(OwnKind::KeyPackage),
            &[GONE.to_owned()],
        ));
        board.hold(
            OwnKind::KeyPackage,
            board.generation(OwnKind::KeyPackage),
            OwnHold::AwaitingResetAcknowledgement,
        );
        secs.store(30, Ordering::SeqCst);
        let held = board.snapshot().key_package;
        assert_eq!(held.hold, Some(OwnHold::AwaitingResetAcknowledgement));
        assert!(held.cells.is_empty());
        assert_eq!(
            held.checked_secs_ago,
            Some(30),
            "a held pass is a finished one"
        );

        let pass = board.begin(
            OwnKind::KeyPackage,
            board.generation(OwnKind::KeyPackage),
            &[GONE.to_owned()],
        );
        assert_eq!(board.snapshot().key_package.hold, None);
        drop(pass);
        assert_eq!(board.snapshot().key_package.checked_secs_ago, Some(0));
    }

    #[test]
    fn checked_secs_ago_reads_the_monotonic_clock_from_the_end_of_the_last_pass() {
        let (board, secs) = board_at();
        let pass = board.begin(
            OwnKind::InboxRelayList,
            board.generation(OwnKind::InboxRelayList),
            &[],
        );
        secs.store(5, Ordering::SeqCst);
        drop(pass);
        secs.store(605, Ordering::SeqCst);
        assert_eq!(
            board.snapshot().inbox_relay_list.checked_secs_ago,
            Some(600)
        );
        secs.store(611, Ordering::SeqCst);
        assert_eq!(
            board.snapshot().inbox_relay_list.checked_secs_ago,
            Some(606)
        );
    }

    #[test]
    fn a_list_edit_supersedes_the_pass_in_flight_and_it_writes_nothing_more() {
        let (board, secs) = board_at();
        let mut pass = board.begin(
            OwnKind::RelayList,
            board.generation(OwnKind::RelayList),
            &[GONE.to_owned()],
        );
        board.clear(OwnKind::RelayList);
        pass.judge(&[answered(GONE, true)], |_| Probed::Current);
        secs.store(9, Ordering::SeqCst);
        drop(pass);
        let kind = board.snapshot().relay_list;
        assert!(
            kind.cells.is_empty(),
            "judged against the old list: {kind:?}"
        );
        assert_eq!(
            kind.checked_secs_ago, None,
            "a superseded pass finished nothing"
        );
    }

    /// A list edit that lands after a pass read the list, before it began,
    /// leaves that pass writing nothing: no cell, no hold, no finish.
    #[test]
    fn a_list_edit_before_the_pass_begins_leaves_it_writing_nothing() {
        let (board, _) = board_at();
        let seen = board.generation(OwnKind::InboxRelayList);
        board.clear(OwnKind::InboxRelayList);
        let mut pass = board.begin(OwnKind::InboxRelayList, seen, &[GONE.to_owned()]);
        assert!(board.snapshot().inbox_relay_list.cells.is_empty());
        pass.judge(&[answered(GONE, true)], |_| Probed::Current);
        drop(pass);
        board.hold(OwnKind::InboxRelayList, seen, OwnHold::NoRelaysConfigured);
        let kind = board.snapshot().inbox_relay_list;
        assert!(
            kind.cells.is_empty(),
            "judged against the old list: {kind:?}"
        );
        assert_eq!(kind.hold, None, "held for the old list");
        assert_eq!(
            kind.checked_secs_ago, None,
            "a superseded pass finished nothing"
        );
    }

    #[test]
    fn forgetting_one_relay_keeps_the_pass_writing_the_others() {
        let (board, _) = board_at();
        let (a, b) = (
            "wss://a.example.com".to_owned(),
            "wss://b.example.com".to_owned(),
        );
        let mut pass = board.begin(
            OwnKind::KeyPackage,
            board.generation(OwnKind::KeyPackage),
            &[a.clone(), b.clone()],
        );
        board.forget(OwnKind::KeyPackage, "WSS://A.example.com");
        pass.judge(&[answered(&a, true), answered(&b, true)], |_| {
            Probed::Missing
        });
        drop(pass);
        assert_eq!(
            cells(&board.snapshot().key_package),
            [(b.as_str(), Missing)]
        );
    }

    #[test]
    fn the_running_flag_covers_a_pass_from_its_request_to_its_end() {
        let board = OwnRelayBoard::default();
        assert!(!board.snapshot().running);
        let first = board.running();
        let second = board.running();
        drop(first);
        assert!(
            board.snapshot().running,
            "one is still waiting for its turn"
        );
        drop(second);
        assert!(!board.snapshot().running);
    }

    #[test]
    fn own_relay_cell_debug_redacts_the_relay() {
        const RELAY: &str = "wss://private.relay.example.com";
        let cell = OwnRelayCell {
            relay_url: RELAY.to_owned(),
            status: Publishing,
        };
        crate::assert_debug_redacted!(&cell, "OwnRelayCell", &[RELAY, "private.relay.example.com"]);
        let board = OwnRelayBoard::default();
        let mut pass = board.begin(
            OwnKind::RelayList,
            board.generation(OwnKind::RelayList),
            &[RELAY.to_owned()],
        );
        pass.judge(&[answered(RELAY, true)], |_| Probed::Missing);
        drop(pass);
        board.hold(
            OwnKind::KeyPackage,
            board.generation(OwnKind::KeyPackage),
            OwnHold::NoRelaysConfigured,
        );
        crate::assert_debug_redacted!(
            &board.snapshot(),
            "OwnBoardSnapshot",
            marker = "OwnRelayCell",
            &[RELAY, "private.relay.example.com"]
        );
    }

    #[test]
    fn own_inbox_read_cell_debug_redacts_the_relay() {
        const RELAY: &str = "wss://private.relay.example.com";
        let cell = OwnInboxReadCell {
            relay_url: RELAY.to_owned(),
            read: InboxRead::Refused,
        };
        crate::assert_debug_redacted!(
            &cell,
            "OwnInboxReadCell",
            &[RELAY, "private.relay.example.com"]
        );
        let board = OwnRelayBoard::default();
        board.inbox_reads().cells.push(cell);
        crate::assert_debug_redacted!(
            &board.snapshot(),
            "OwnBoardSnapshot",
            marker = "OwnInboxReadCell",
            &[RELAY, "private.relay.example.com"]
        );
    }

    /// Asks `inbox` for `own`'s gift wraps on a fresh board, as the
    /// relay-list pass does, and returns what the board then holds.
    async fn inbox_reads_of(own: &Keys, inbox: &[String]) -> Vec<OwnInboxReadCell> {
        let board = OwnRelayBoard::default();
        let signer = Arc::new(Nip42Signer::new(own));
        board
            .ask_inbox_reads(&signer, board.inbox_reads_generation(), inbox)
            .await;
        board.snapshot().inbox_reads
    }

    /// The relay settings page warns on exactly the relays that keep an
    /// invitation out of this device's reach: one refusing the read, here a
    /// relay that asks for authentication and never issues the challenge the
    /// device would answer. A throttle or a plain error is a read that did not
    /// finish, never a refusal.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn an_inbox_relay_is_judged_by_how_it_answers_a_gift_wrap_read() {
        let own = Keys::generate();
        let cases = [
            (
                vec![Frame::Closed(
                    "auth-required: requested filter requires authentication".to_owned(),
                )],
                InboxRead::Refused,
            ),
            (
                vec![Frame::Closed("restricted: not your inbox".to_owned())],
                InboxRead::Refused,
            ),
            (
                vec![Frame::Closed(
                    "ERROR: auth-required: requested filter requires authentication".to_owned(),
                )],
                InboxRead::Refused,
            ),
            (
                vec![Frame::Closed("rate-limited: slow down".to_owned())],
                InboxRead::Incomplete,
            ),
            (
                vec![Frame::Closed("error: shutting down".to_owned())],
                InboxRead::Incomplete,
            ),
            (served(vec![]), InboxRead::Served),
        ];
        for (frames, expected) in cases {
            let relay = ScriptedRelay::start();
            answer(&relay, Kind::GiftWrap, frames);
            let inbox = vec![relay.url().to_owned()];
            let reads = inbox_reads_of(&own, &inbox).await;
            assert_eq!(
                reads,
                [OwnInboxReadCell {
                    relay_url: inbox[0].clone(),
                    read: expected,
                }],
            );
        }
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn an_inbox_relay_that_cannot_be_reached_is_unreached() {
        let _ = crate::relay::allow_ws_loopback_for_test();
        let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("bind");
        let port = listener.local_addr().expect("local addr").port();
        drop(listener);
        let unreachable = vec![
            format!("ws://127.0.0.1:{port}"),
            "ws://insecure.relay.example.com".to_owned(),
            "not-a-url".to_owned(),
        ];
        let reads = inbox_reads_of(&Keys::generate(), &unreachable).await;
        assert_eq!(
            reads
                .iter()
                .map(|cell| (cell.relay_url.as_str(), cell.read))
                .collect::<Vec<_>>(),
            unreachable
                .iter()
                .map(|url| (url.as_str(), InboxRead::Unreached))
                .collect::<Vec<_>>(),
        );
    }

    /// The probe asks only what the live plane's own inbox REQ asks — this
    /// account's gift wraps by `#p`, never by author and never a circle's
    /// `#h` — and only from now, so a relay that serves it hands back nothing
    /// a later read would not.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn the_inbox_read_probe_asks_only_for_own_gift_wraps_from_now() {
        let own = Keys::generate();
        let relay = ScriptedRelay::start();
        let front = RecordingFront::start(relay.url());
        let before = Timestamp::now().as_secs();
        let _ = inbox_reads_of(&own, &[front.url().to_owned()]).await;

        let gift_wrap_reqs: Vec<serde_json::Value> = front
            .frames()
            .iter()
            .filter_map(|frame| serde_json::from_str::<serde_json::Value>(&frame.text).ok())
            .filter(|message| {
                message[0] == "REQ" && message[2]["kinds"] == serde_json::json!([1059])
            })
            .collect();
        assert_eq!(
            gift_wrap_reqs.len(),
            1,
            "one gift-wrap read per inbox relay"
        );
        let filter = gift_wrap_reqs[0][2]
            .as_object()
            .expect("a REQ filter")
            .clone();
        let mut keys: Vec<&str> = filter.keys().map(String::as_str).collect();
        keys.sort_unstable();
        assert_eq!(keys, ["#p", "kinds", "limit", "since"]);
        let own_hex = own.public_key().to_hex();
        assert!(
            filter["#p"]
                .as_array()
                .is_some_and(|p| p.len() == 1 && p[0] == own_hex.as_str()),
            "the read names this account's own key, and only it"
        );
        assert_eq!(filter["limit"], 1);
        assert!(
            filter["since"].as_u64().expect("a since") >= before,
            "the read asks from now"
        );
    }

    /// An inbox list edit forgets every answer, and a read that began before
    /// it records nothing: its answers came from relays of the old list.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn an_inbox_list_edit_forgets_the_reads_and_supersedes_one_in_flight() {
        let own = Keys::generate();
        let signer = Arc::new(Nip42Signer::new(&own));
        let relay = ScriptedRelay::start();
        answer(&relay, Kind::GiftWrap, served(vec![]));
        let inbox = vec![relay.url().to_owned()];
        let board = OwnRelayBoard::default();

        board
            .ask_inbox_reads(&signer, board.inbox_reads_generation(), &inbox)
            .await;
        assert_eq!(board.snapshot().inbox_reads.len(), 1);
        board.clear_inbox_reads();
        assert!(board.snapshot().inbox_reads.is_empty());

        // A read asked again forgets the last answers while it is asked.
        board
            .ask_inbox_reads(&signer, board.inbox_reads_generation(), &inbox)
            .await;
        let held = ScriptedRelay::start();
        let (open, opened) = tokio::sync::watch::channel(false);
        answer(
            &held,
            Kind::GiftWrap,
            vec![Frame::Hold(opened), Frame::Eose],
        );
        let held_inbox = vec![held.url().to_owned()];
        let asked = board.ask_inbox_reads(&signer, board.inbox_reads_generation(), &held_inbox);
        let watched = async {
            while held.connections() == 0 {
                tokio::task::yield_now().await;
            }
            let mid = board.snapshot().inbox_reads;
            open.send(true).expect("the relay listens");
            mid
        };
        let ((), mid) = tokio::join!(asked, watched);
        assert!(mid.is_empty(), "an answer stood while it was asked again");
        assert_eq!(
            board.snapshot().inbox_reads,
            [OwnInboxReadCell {
                relay_url: held_inbox[0].clone(),
                read: InboxRead::Served,
            }],
        );

        let seen = board.inbox_reads_generation();
        board.clear_inbox_reads();
        board.ask_inbox_reads(&signer, seen, &inbox).await;
        assert!(
            board.snapshot().inbox_reads.is_empty(),
            "a read the edit superseded wrote its answers"
        );
        assert!(
            board.snapshot().inbox_relay_list.cells.is_empty(),
            "the reads are no kind's cells"
        );
    }

    /// Requests made while a pass waits for its turn join it; the pass
    /// running when they were made does not serve them.
    #[tokio::test(flavor = "current_thread")]
    async fn requests_made_while_one_waits_join_it_and_share_its_outcome() {
        use futures::FutureExt as _;
        let turn = tokio::sync::Mutex::new(());
        let passes: Coalesced<usize> = Coalesced::default();
        let ran = AtomicUsize::new(0);
        let pass = || async { ran.fetch_add(1, Ordering::SeqCst) + 1 };

        let running = turn.lock().await;
        // The pass in flight began before these requests: none is served by it.
        let mut waiting: Vec<_> = (0..3)
            .map(|_| Box::pin(passes.run(turn.lock(), pass())))
            .collect();
        for request in &mut waiting {
            assert!(
                request.as_mut().now_or_never().is_none(),
                "a request waits for its turn"
            );
        }
        drop(running);
        let outcomes = futures::future::join_all(waiting).await;
        assert_eq!(ran.load(Ordering::SeqCst), 1, "one pass for all three");
        assert_eq!(outcomes, [1, 1, 1]);

        // A request after that pass began gets a pass of its own.
        assert_eq!(passes.run(turn.lock(), pass()).await, 2);
    }

    fn signed(keys: &Keys, kind: Kind, tags: Vec<Tag>, at: u64) -> Event {
        EventBuilder::new(kind, "")
            .tags(tags)
            .custom_created_at(Timestamp::from_secs(at))
            .sign_with_keys(keys)
            .expect("a locally built event signs")
    }

    /// A relay list of `kind` naming `urls`, in the tags its kind uses.
    fn list(keys: &Keys, kind: Kind, urls: &[&str], at: u64) -> Event {
        let name = if kind == Kind::RelayList {
            "r"
        } else {
            "relay"
        };
        let tags = urls
            .iter()
            .map(|url| Tag::parse([name, url]).expect("a relay tag"))
            .collect();
        signed(keys, kind, tags, at)
    }

    /// A kind 30443 in slot `d`; its content is never read here.
    fn key_package(keys: &Keys, d: &str, at: u64) -> Event {
        signed(keys, KP, vec![Tag::parse(["d", d]).expect("a d tag")], at)
    }

    /// Answers every REQ for `kind` with `frames`.
    fn answer(relay: &ScriptedRelay, kind: Kind, frames: Vec<Frame>) {
        relay.answer(
            move |filter| filter.kinds.as_ref().is_some_and(|k| k.contains(&kind)),
            frames,
        );
    }

    fn served(events: Vec<Event>) -> Vec<Frame> {
        events
            .into_iter()
            .map(Frame::Event)
            .chain(std::iter::once(Frame::Eose))
            .collect()
    }

    /// This device's record of `event`, published and still openable.
    fn tracked_in_slot(event: &Event) -> TrackedKeyPackage {
        TrackedKeyPackage {
            slot: kp_event_d_tag(event).expect("a slot"),
            published: Some(event.clone()),
            created_at: Some(event.created_at.as_secs()),
            package: vec![1],
            pending: None,
            adopted: false,
            replacement_owed: false,
            consumed_but_held: false,
        }
    }

    /// The maintenance passes' probe of `kind` on each of `relays`, judged
    /// with `current`, as they write the board.
    async fn probed(
        own: &Keys,
        kind: Kind,
        relays: &[String],
        current: &(dyn Fn(&[&Event]) -> bool + Sync),
    ) -> Vec<Probed> {
        let limit = if kind == KP { 64 } else { 4 };
        let filter = Filter::new()
            .kind(kind)
            .author(own.public_key())
            .limit(limit);
        let answers = Box::pin(RelayManager::new().fetch_events_per_relay(filter, relays))
            .await
            .expect("the per-relay read never fails as a whole");
        answers
            .iter()
            .map(|answer| probe_verdict(answer, &own.public_key(), kind, current))
            .collect()
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn a_relay_list_is_current_only_when_its_newest_copy_names_the_configured_list() {
        let own = Keys::generate();
        let relay = ScriptedRelay::start();
        let configured = vec![relay.url().to_owned()];
        let current = [relay.url()];
        let names = |mine: &[&Event]| names_configured_list(mine, &configured);

        answer(
            &relay,
            Kind::RelayList,
            served(vec![list(&own, Kind::RelayList, &current, 2_000)]),
        );
        answer(
            &relay,
            Kind::InboxRelays,
            served(vec![list(&own, Kind::InboxRelays, &[GONE], 2_000)]),
        );
        assert_eq!(
            probed(&own, Kind::RelayList, &configured, &names).await,
            [Probed::Current]
        );
        assert_eq!(
            probed(&own, Kind::InboxRelays, &configured, &names).await,
            [Probed::Outdated]
        );

        // The newest copy is judged, whatever order the relay sent them in.
        answer(
            &relay,
            Kind::RelayList,
            served(vec![
                list(&own, Kind::RelayList, &current, 1_000),
                list(&own, Kind::RelayList, &[GONE], 2_000),
            ]),
        );
        answer(
            &relay,
            Kind::InboxRelays,
            served(vec![
                list(&own, Kind::InboxRelays, &[GONE], 1_000),
                list(&own, Kind::InboxRelays, &current, 2_000),
            ]),
        );
        assert_eq!(
            probed(&own, Kind::RelayList, &configured, &names).await,
            [Probed::Outdated]
        );
        assert_eq!(
            probed(&own, Kind::InboxRelays, &configured, &names).await,
            [Probed::Current]
        );
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn only_this_devices_valid_tracked_package_reads_current() {
        let own = Keys::generate();
        let relay = ScriptedRelay::start();
        let kp_list = vec![relay.url().to_owned()];
        let tracked_event = key_package(&own, SLOT, 1_000);
        let record = tracked_in_slot(&tracked_event);
        let tracked = Some(&record);
        let newer = key_package(&own, SLOT, 2_000);
        let older = key_package(&own, SLOT, 500);
        let other_slot = key_package(&own, &"b2".repeat(32), 2_000);
        let cases = [
            (
                "the tracked event",
                &tracked_event,
                tracked,
                VALID,
                Probed::Current,
            ),
            (
                "a newer event in the slot",
                &newer,
                tracked,
                VALID,
                Probed::Current,
            ),
            (
                "an older event in the slot",
                &older,
                tracked,
                VALID,
                Probed::Outdated,
            ),
            (
                "only another slot",
                &other_slot,
                tracked,
                VALID,
                Probed::Outdated,
            ),
            (
                "an adopted slot",
                &tracked_event,
                tracked,
                TrackedKpLifetime::Absent,
                Probed::Outdated,
            ),
            (
                "an expired package",
                &tracked_event,
                tracked,
                TrackedKpLifetime::NotCurrent,
                Probed::Outdated,
            ),
            (
                "an unreadable package",
                &tracked_event,
                tracked,
                TrackedKpLifetime::Unreadable,
                Probed::Outdated,
            ),
            (
                "nothing tracked",
                &tracked_event,
                None,
                VALID,
                Probed::Outdated,
            ),
        ];
        for (case, event, tracked, lifetime, expected) in cases {
            answer(&relay, KP, served(vec![event.clone()]));
            let serves = |mine: &[&Event]| serves_tracked_package(mine, tracked, lifetime);
            assert_eq!(
                probed(&own, KP, &kp_list, &serves).await,
                [expected],
                "{case}"
            );
        }
        answer(&relay, KP, served(vec![]));
        let serves = |mine: &[&Event]| serves_tracked_package(mine, tracked, VALID);
        assert_eq!(
            probed(&own, KP, &kp_list, &serves).await,
            [Probed::Missing],
            "nothing served"
        );
    }

    /// A package maintenance would replace never reads current, however the
    /// relay serves it: the board and the pass share one rule.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn a_package_maintenance_would_replace_reads_outdated() {
        let own = Keys::generate();
        let relay = ScriptedRelay::start();
        let kp_list = vec![relay.url().to_owned()];
        let tracked_event = key_package(&own, SLOT, 1_000);
        let record = tracked_in_slot(&tracked_event);
        // Maintenance's own rule: a Welcome consumed the package and its key
        // is gone, so it is owed a replacement and opens nothing.
        let consumed_not_held = TrackedKeyPackage {
            replacement_owed: true,
            ..record.clone()
        };
        let consumed_but_held = TrackedKeyPackage {
            replacement_owed: true,
            consumed_but_held: true,
            ..record.clone()
        };
        let bundle_lost = TrackedKeyPackage {
            package: Vec::new(),
            ..record.clone()
        };
        let never_acknowledged = TrackedKeyPackage {
            published: None,
            ..record
        };
        let cases = [
            (
                "a consumed package whose key is not held",
                &consumed_not_held,
                Probed::Outdated,
            ),
            (
                "a consumed package whose key is still held",
                &consumed_but_held,
                Probed::Current,
            ),
            (
                "a package whose bundle is lost",
                &bundle_lost,
                Probed::Outdated,
            ),
            (
                "a package no relay acknowledged",
                &never_acknowledged,
                Probed::Outdated,
            ),
        ];
        answer(&relay, KP, served(vec![tracked_event]));
        for (case, tracked, expected) in cases {
            let serves = |mine: &[&Event]| serves_tracked_package(mine, Some(tracked), VALID);
            assert_eq!(
                probed(&own, KP, &kp_list, &serves).await,
                [expected],
                "{case}"
            );
        }
    }

    /// A slot a conformant inviter rejects is retired by maintenance before
    /// anything is published into it, so the package there is not current.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn a_package_in_a_non_conformant_slot_is_outdated() {
        let own = Keys::generate();
        let relay = ScriptedRelay::start();
        let kp_list = vec![relay.url().to_owned()];
        for (slot, expected) in [("slot", Probed::Outdated), (SLOT, Probed::Current)] {
            let event = key_package(&own, slot, 1_000);
            answer(&relay, KP, served(vec![event.clone()]));
            let record = tracked_in_slot(&event);
            let serves = |mine: &[&Event]| serves_tracked_package(mine, Some(&record), VALID);
            assert_eq!(
                probed(&own, KP, &kp_list, &serves).await,
                [expected],
                "slot {slot:?}"
            );
        }
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn another_authors_event_never_counts() {
        let (own, other) = (Keys::generate(), Keys::generate());
        let relay = ScriptedRelay::start();
        let lists = vec![relay.url().to_owned()];
        let record = tracked_in_slot(&key_package(&own, SLOT, 1_000));
        // Each would read current were its author not checked.
        answer(&relay, KP, served(vec![key_package(&other, SLOT, 2_000)]));
        answer(
            &relay,
            Kind::RelayList,
            served(vec![list(&other, Kind::RelayList, &[relay.url()], 2_000)]),
        );
        answer(
            &relay,
            Kind::InboxRelays,
            served(vec![list(&other, Kind::InboxRelays, &[relay.url()], 2_000)]),
        );

        let serves = |mine: &[&Event]| serves_tracked_package(mine, Some(&record), VALID);
        let names = |mine: &[&Event]| names_configured_list(mine, &lists);
        assert_eq!(probed(&own, KP, &lists, &serves).await, [Probed::Missing]);
        assert_eq!(
            probed(&own, Kind::RelayList, &lists, &names).await,
            [Probed::Missing]
        );
        assert_eq!(
            probed(&own, Kind::InboxRelays, &lists, &names).await,
            [Probed::Missing]
        );
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn a_req_the_relay_closed_is_no_answer_unless_what_came_first_is_current() {
        let own = Keys::generate();
        let relay = ScriptedRelay::start();
        let lists = vec![relay.url().to_owned()];
        let closed = || Frame::Closed("rate-limited: slow down".to_owned());
        answer(&relay, KP, vec![closed()]);
        answer(
            &relay,
            Kind::RelayList,
            vec![
                Frame::Event(list(&own, Kind::RelayList, &[GONE], 2_000)),
                closed(),
            ],
        );
        answer(
            &relay,
            Kind::InboxRelays,
            vec![
                Frame::Event(list(&own, Kind::InboxRelays, &[relay.url()], 2_000)),
                closed(),
            ],
        );
        let serves = |mine: &[&Event]| serves_tracked_package(mine, None, VALID);
        let names = |mine: &[&Event]| names_configured_list(mine, &lists);
        assert_eq!(probed(&own, KP, &lists, &serves).await, [Probed::NoAnswer]);
        assert_eq!(
            probed(&own, Kind::RelayList, &lists, &names).await,
            [Probed::NoAnswer]
        );
        assert_eq!(
            probed(&own, Kind::InboxRelays, &lists, &names).await,
            [Probed::Current]
        );
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn a_relay_that_cannot_be_reached_is_no_answer() {
        let _ = crate::relay::allow_ws_loopback_for_test();
        let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("bind");
        let port = listener.local_addr().expect("local addr").port();
        drop(listener);
        let unreachable = vec![
            format!("ws://127.0.0.1:{port}"),
            "ws://insecure.relay.example.com".to_owned(),
            "not-a-url".to_owned(),
        ];
        let names = |mine: &[&Event]| names_configured_list(mine, &unreachable);
        assert_eq!(
            probed(&Keys::generate(), Kind::InboxRelays, &unreachable, &names).await,
            [Probed::NoAnswer; 3]
        );
    }
}
