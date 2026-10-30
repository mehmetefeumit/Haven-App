//! What Haven keeps, per circle, about a commit under a durable fanout that
//! the fanout record itself has no place for.
//!
//! Three things, each read long after the call that wrote it and possibly in
//! another process:
//!
//! * whether the circle's recorded pending commit is KNOWN to remove nobody.
//!   Only such a commit may be undone when no relay could be reached for a
//!   day ([`crate::relay::fanout::FANOUT_BOUND_MS`]): undoing a removal would
//!   let the circle's queued locations go out to the member the user had just
//!   removed. The mark is cleared before every commit's record is written and
//!   set after it, so whatever a kill leaves reads as "may remove a member";
//! * what became of a change while nobody was waiting for the answer
//!   ([`ChangeNote`]), until it is acknowledged — and, beside those, what the
//!   engine holds of the circle's traffic that it has not read
//!   ([`ChangeNote::UnreadChange`], [`ChangeNote::UnreadLocation`]), for as
//!   long as it holds it;
//! * how long the circle waits before the engine's own commit — the eviction
//!   of a member who left — is staged again after the fanout driver rolled
//!   one back ([`RestageWait`]). Kept durably so that a run of short
//!   sessions does not each stage and send a commit every relay has just
//!   refused.
//!
//! And one thing that names somebody: who a removal the user asked for named,
//! when it was set aside unmade ([`CommitNotes::keep_removal_targets`]) —
//! member ids, at rest in this store only, for as long as the note that says
//! so stands.
//!
//! Nothing here is ever logged, and an implementation never logs a circle or
//! a member.

use std::collections::HashMap;
use std::sync::{Mutex, PoisonError};

use super::kept_input::KeptInput;
use super::types::{GroupId, MemberId, MessageId};

/// Something that happened to a circle's change in a drive its author may not
/// have been waiting on.
///
/// Fieldless on purpose: what the user is told is fixed copy chosen by the
/// variant, never a string from here.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ChangeNote {
    /// A commit that removed a member — the user's removal, or the eviction of
    /// a member who left — was undone: every relay proved it refused it. That
    /// member is still in the circle and can still read it. Also what is said
    /// of an undone commit whose kind this device kept no word on: it may
    /// have removed a member.
    RemovalUndone,
    /// A change that removed nobody was undone: every relay refused it, or
    /// none could be reached for a day.
    ChangeUndone,
    /// A commit a relay may hold was given a final state by the engine without
    /// this device ever learning it was accepted. The rest of the circle may
    /// have moved on without this device.
    MayBeOutOfStep,
    /// An invite was applied with no Welcome left to deliver: the invitee is
    /// on the roster and cannot join until invited again. Two recoveries,
    /// told apart by whether MDK holds a re-invite: an invite branch selection
    /// withdrew is invited again with fresh key packages by
    /// `Publishing::reinvite`; one whose Welcome was lost otherwise — never
    /// deliverable, no route kept — has no MDK record, and only the user
    /// removing and re-adding the invitee helps
    /// (`protocol-core/publish-lifecycle.md` 73-75).
    ReinviteOwed,
    /// A commit was staged and could be neither recorded nor undone: it was
    /// not sent, and it holds its circle until its rollback succeeds at a
    /// later call that stages, or until the next start, which gives an
    /// admin's removal its record and lets the engine clear anything else.
    ChangeUnrecorded,
    /// A change waiting in the engine's queue was taken out of it unmade:
    /// what it asked for can no longer be done as asked — its author is no
    /// longer an admin, or a member it removes is no longer in the circle.
    QueuedChangeDropped,
    /// The circle has changes waiting in the engine's queue and the advance
    /// that would have released them failed. They are still queued.
    QueuedChangesHeld,
    /// As [`Self::QueuedChangeDropped`], for a REMOVAL: one the user asked
    /// for was taken out of the engine's queue unmade, and a member it named
    /// may still be in the circle, reading what it is sent. The removal has
    /// to be asked for again. Kept until the user has been shown it.
    ///
    /// Set aside by a call that could never have made it — away from the
    /// foreground, or at an open — its targets are kept beside it
    /// ([`CommitNotes::keep_removal_targets`]), and while one of them is
    /// still listed nothing is sealed for the circle by any call (decision
    /// 238).
    QueuedRemovalDropped,
    /// The engine holds something the circle sent that it never opened, will
    /// not open by itself, and that by its tags is a commit or a proposal: a
    /// membership change this device has not applied. It may be an epoch
    /// behind its circle, unable to read it, and sealing what a member
    /// removed since can still read. Nothing in such an event was
    /// authenticated, so "may": anyone who knows the circle's routing tag can
    /// have sent it.
    ///
    /// Not an outcome to acknowledge away: it is written where the engine is
    /// found holding such an event with no commit of this device's own
    /// pending, and cleared where it is found holding none.
    UnreadChange,
    /// As [`Self::UnreadChange`], for an event that by its tags is a
    /// location: one or more fixes of this circle were not delivered.
    UnreadLocation,
    /// A change of the circle's relays was applied while the app was away,
    /// and this device's subscriptions have not followed it: it could miss a
    /// removal and seal for whoever was removed. Nothing is sealed for the
    /// circle except by a claimed foreground until a full drive has
    /// completed in one.
    ///
    /// A level, as the two above: written where a drive that only finishes
    /// applies such a change, and cleared at the end of a full drive that
    /// was still the foreground's. That drive is all it waits for: nothing
    /// here reads whether the subscriptions have followed.
    AwaitsForeground,
    /// A change the user made was withdrawn by branch selection and could
    /// not be made again: the winning change touched the same thing, or it
    /// lost more races than the engine retries. The winner's state stands;
    /// the user has to ask again. Kept until the user has been shown it.
    ChangeWithdrawn,
    /// An invitee of the circle is on its roster and their Welcome is not yet
    /// delivered: no relay of their inbox has acknowledged it. It is sent
    /// again on its own schedule for a day from its hand-over (less, when its
    /// invitee's inbox window would close sooner); past that it is no longer
    /// sent, and this stands until the user has been shown it, whatever
    /// becomes of the circle's other Welcomes.
    WelcomeOwed,
    /// The circle's routing id is also another circle's on this device: a
    /// rotation another client's admin made, or a Welcome, named one this
    /// device already held — or one the store could not check. MDK then
    /// resolves that id's traffic to one of the two, so the other can apply
    /// none of its commits — removals included. While it stands nothing is
    /// sealed for the circle by any call, and no commit of this device's is
    /// made for it but what its leave needs: the proposal, the admin steps
    /// the leave takes, and an eviction already due, which the engine's
    /// leave call stages first. A change asked for is refused; one the
    /// engine owes — a withdrawn change, a re-invite, an eviction or another
    /// deadline's commit — waits, owed. It stands until the circle itself is
    /// left, whatever becomes of the other: nothing in Haven can tell when
    /// the engine routes both again.
    RoutingCollision,
}

/// The notes that say what the engine holds unread.
pub(super) const UNREAD: [ChangeNote; 2] = [ChangeNote::UnreadChange, ChangeNote::UnreadLocation];

/// The notes that say what IS rather than what happened: Haven clears each
/// where it stops being so, and none is acknowledged away.
pub(super) const LEVELS: [ChangeNote; 4] = [
    ChangeNote::UnreadChange,
    ChangeNote::UnreadLocation,
    ChangeNote::AwaitsForeground,
    ChangeNote::RoutingCollision,
];

impl ChangeNote {
    /// Every note, in the order a reader is handed them.
    pub const ALL: [Self; 14] = [
        Self::RemovalUndone,
        Self::ChangeUndone,
        Self::MayBeOutOfStep,
        Self::ReinviteOwed,
        Self::ChangeUnrecorded,
        Self::QueuedChangeDropped,
        Self::QueuedChangesHeld,
        Self::UnreadChange,
        Self::UnreadLocation,
        Self::AwaitsForeground,
        Self::QueuedRemovalDropped,
        Self::ChangeWithdrawn,
        Self::WelcomeOwed,
        Self::RoutingCollision,
    ];

    /// The note's bit in a circle's stored set.
    #[must_use]
    pub const fn bit(self) -> u16 {
        match self {
            Self::RemovalUndone => 1,
            Self::ChangeUndone => 2,
            Self::MayBeOutOfStep => 4,
            Self::ReinviteOwed => 8,
            Self::ChangeUnrecorded => 16,
            Self::QueuedChangeDropped => 32,
            Self::QueuedChangesHeld => 64,
            Self::UnreadChange => 128,
            Self::UnreadLocation => 256,
            Self::AwaitsForeground => 512,
            Self::QueuedRemovalDropped => 1024,
            Self::ChangeWithdrawn => 2048,
            Self::WelcomeOwed => 4096,
            Self::RoutingCollision => 8192,
        }
    }

    /// The notes a stored set holds.
    #[must_use]
    pub fn of(bits: u16) -> Vec<Self> {
        Self::ALL
            .into_iter()
            .filter(|note| bits & note.bit() != 0)
            .collect()
    }
}

/// What a circle had not been told when it was read for showing, and which
/// of its writes that read saw: acknowledged, it drops exactly that and no
/// later write ([`CommitNotes::acknowledge`]).
#[derive(Clone, PartialEq, Eq)]
pub struct ChangeNotice {
    /// The notes, to be shown.
    pub notes: Vec<ChangeNote>,
    /// How many writes the circle had seen that raised a note or held a
    /// member — a note written again while it stands is none; `None` when
    /// the read failed, which no acknowledgement can match.
    seen: Option<u64>,
}

/// The notes alone: the write count is the circle's activity.
impl std::fmt::Debug for ChangeNotice {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ChangeNotice")
            .field("notes", &self.notes)
            .finish_non_exhaustive()
    }
}

impl ChangeNotice {
    /// A notice read at `seen` writes, holding `bits`.
    #[must_use]
    pub fn read(bits: u16, seen: Option<u64>) -> Self {
        Self {
            notes: ChangeNote::of(bits),
            seen,
        }
    }

    /// The writes the read saw.
    #[must_use]
    pub const fn seen(&self) -> Option<u64> {
        self.seen
    }

    /// The bits an acknowledgement drops: every note read but the levels,
    /// which end when what they say does.
    #[must_use]
    pub fn dropped_bits(&self) -> u16 {
        self.notes
            .iter()
            .filter(|note| !LEVELS.contains(note))
            .fold(0, |bits, note| bits | note.bit())
    }
}

/// How long a circle waits before the engine's own commit is staged again.
#[derive(Clone, Copy, PartialEq, Eq, Default)]
pub struct RestageWait {
    /// How many commits of the circle the fanout driver has rolled back in a
    /// row. A magnitude kept to double the wait; never logged.
    pub rollbacks: u32,
    /// The instant before which none is staged again, in the fanout clock's
    /// milliseconds. Never logged.
    pub not_before_ms: u64,
}

/// Nothing of it: one field counts a circle's refusals and the other is an
/// absolute instant (Security Rule 15).
impl std::fmt::Debug for RestageWait {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("RestageWait").finish_non_exhaustive()
    }
}

/// One member a removal set aside unmade named, while no commit this device
/// applied has taken them out.
///
/// No `Debug`: it carries a member id (Security Rule 15).
#[derive(Clone, PartialEq, Eq)]
pub struct KeptTarget {
    /// The member.
    pub member: MemberId,
    /// The epoch the circle stood on when the removal was set aside.
    pub set_aside_epoch: u64,
    /// How often it was asked for again (decision 180).
    pub asks: u32,
}

/// Where a circle's commit notes are kept. Durable when the session was
/// opened with a store (`SessionManager::new_with_notes`), as a
/// `CircleManager`'s is.
///
/// The same store keeps what Haven takes over of a circle's parked input
/// ([`KeptInput`]): the note that says input is waiting is written before
/// any of it is taken over, and both must outlive the same process.
pub trait CommitNotes: KeptInput {
    /// Records whether the circle's recorded pending commit is known to
    /// remove nobody. Returns whether the write landed: a mark that could not
    /// be CLEARED may be a stale "removes nobody", so its commit is not
    /// recorded at all.
    fn set_removes_nobody(&self, group_id: &GroupId, known: bool) -> bool;

    /// Whether the circle's recorded pending commit is known to remove
    /// nobody. `false` whenever it is not known — a missing mark, a failed
    /// read.
    fn removes_nobody(&self, group_id: &GroupId) -> bool;

    /// Adds `note` to what the circle has not been told. Returns whether
    /// the write landed: whoever is about to delete the only other trace of
    /// what the note says keeps that trace when it did not. Written again
    /// while it stands, it supersedes no notice read since.
    fn note(&self, group_id: &GroupId, note: ChangeNote) -> bool;

    /// [`Self::note`] for every one of `groups`, all or none: one write.
    fn note_all(&self, groups: &[&GroupId], note: ChangeNote) -> bool;

    /// What the circle has not been told, left in place.
    fn peek(&self, group_id: &GroupId) -> Vec<ChangeNote>;

    /// What the circle has not been told, read for showing, with how many
    /// writes that raised a note or held a member the read saw.
    fn notice(&self, group_id: &GroupId) -> ChangeNotice;

    /// Drops what `notice` read — its notes but the levels, and with
    /// [`ChangeNote::QueuedRemovalDropped`] the targets kept beside it —
    /// only while nothing has been written for the circle since the read: a
    /// note raised or a member held after it stands. Again for the same
    /// notice, it drops nothing more. Returns `false` when a write since the
    /// read superseded the notice.
    fn acknowledge(&self, group_id: &GroupId, notice: &ChangeNotice) -> bool;

    /// Whether `note` stands for the circle; `None` when that cannot be
    /// read, which [`Self::peek`] answers as "nothing stands". For a caller
    /// about to take back a note it wrote: one that may have stood before is
    /// not its to take.
    fn stands(&self, group_id: &GroupId, note: ChangeNote) -> Option<bool> {
        Some(self.peek(group_id).contains(&note))
    }

    /// Drops `note` from what the circle has not been told: whoever asked
    /// for the change was just told it. With
    /// [`ChangeNote::QueuedRemovalDropped`] go the targets kept beside it.
    fn clear(&self, group_id: &GroupId, note: ChangeNote);

    /// Keeps who a removal set aside unmade named, beside the note that
    /// says so ([`ChangeNote::QueuedRemovalDropped`]): what holds the
    /// circle's sends, the foreground's included, while one of them is still
    /// listed, and what a later removal is asked for again from — with the
    /// epoch the circle stood on when it was set aside, and `asks` already
    /// spent on it. A member kept again starts over. Returns whether the
    /// write landed; the removal stays queued when it did not.
    fn keep_removal_targets(
        &self,
        group_id: &GroupId,
        targets: &[MemberId],
        set_aside_epoch: u64,
        asks: u32,
    ) -> bool;

    /// Who the removals set aside unmade in the circle named and no commit
    /// this device applied has taken out; `None` when that cannot be read,
    /// which a caller takes as "somebody".
    fn removal_targets(&self, group_id: &GroupId) -> Option<Vec<MemberId>>;

    /// As [`Self::removal_targets`], with each one's epoch and count.
    fn kept_removals(&self, group_id: &GroupId) -> Option<Vec<KeptTarget>>;

    /// Marks `members` among the circle's targets as taken out by a commit
    /// this device applied — `by`, when the engine named one — at the epoch
    /// it reached. Returns whether a target changed.
    fn take_out_removal_targets(
        &self,
        group_id: &GroupId,
        members: &[MemberId],
        epoch: u64,
        by: Option<&MessageId>,
    ) -> bool;

    /// Brings back EVERY target of the circle an applied commit took out:
    /// branch selection withdrew commit `by`, and a target not keyed to it —
    /// taken out with no commit named, or by another — may have been taken
    /// out by a commit the same reorg undid. Each one not keyed to `by` comes
    /// back with `unkeyed_asks` spent. Returns whether a target changed.
    fn bring_back_removal_targets(
        &self,
        group_id: &GroupId,
        by: &MessageId,
        unkeyed_asks: u32,
    ) -> bool;

    /// Spends `asks` of every kept target of the circle that holds: a pass
    /// accepted more than one commit, and the membership it announces is
    /// their net change, which can hide a member removed and invited back.
    /// Returns whether the write landed.
    fn spend_removal_asks(&self, group_id: &GroupId, asks: u32) -> bool;

    /// Spends `asks` of each of `members` among the circle's targets, held or
    /// taken out: an applied commit added them (decision 230). A re-invite by
    /// anyone is the circle's choice, so nobody it brought back is removed
    /// unattended. Returns whether the write landed.
    fn spend_target_asks(&self, group_id: &GroupId, members: &[MemberId], asks: u32) -> bool;

    /// The commit a target of the circle was taken out by, when it is taken
    /// out keyed to one; `None` otherwise, or when that cannot be read.
    fn taken_out_by(&self, group_id: &GroupId, member: &MemberId) -> Option<MessageId>;

    /// Forgets the targets taken out at an epoch before `before_epoch`: no
    /// reorg can bring them back.
    fn forget_gone_removal_targets(&self, group_id: &GroupId, before_epoch: u64);

    /// Counts one more ask against each of `members`. Returns whether the
    /// write landed.
    /// Returns what each count now reads, or `None` when the write did not
    /// land.
    fn count_removal_asks(
        &self,
        group_id: &GroupId,
        members: &[MemberId],
    ) -> Option<Vec<(MemberId, u32)>>;

    /// Gives back the asks a [`Self::count_removal_asks`] counted — `counted`
    /// is what it returned — each only while its count still reads what that
    /// call wrote: one spent meanwhile (a pass of several commits, a
    /// re-invite) stays spent.
    fn refund_removal_asks(&self, group_id: &GroupId, counted: &[(MemberId, u32)]);

    /// Takes back [`ChangeNote::QueuedRemovalDropped`] once nobody it named
    /// is listed, keeping its targets: a reorg that brings one back raises
    /// it again.
    fn settle_removal(&self, group_id: &GroupId);

    /// The wait the circle's last rolled-back commit earned, when it has
    /// one. `None` whenever that is not known — a missing row, a failed
    /// read — which lets one commit be staged that a wait would have held.
    fn restage_wait(&self, group_id: &GroupId) -> Option<RestageWait>;

    /// Records the circle's wait, or with `None` ends it.
    fn set_restage_wait(&self, group_id: &GroupId, wait: Option<RestageWait>);

    /// Whether this device asked to leave the circle; `None` when that
    /// cannot be read, which a caller takes as "it did".
    fn leaving(&self, group_id: &GroupId) -> Option<bool>;

    /// Whether the circle's row still exists; `None` when that cannot be
    /// read, which a caller takes as "it does not": a left circle sends
    /// nothing.
    fn circle_stands(&self, group_id: &GroupId) -> Option<bool>;

    /// Keeps where `recipient`'s Welcome to the circle goes — their inbox
    /// relays, as the invite was asked with — and the `not_after` of the
    /// `KeyPackage` it is made for, after which no Welcome can open it,
    /// until the Welcome's own delivery record carries them. Written before
    /// the invite is staged, so no restart leaves a Welcome without a route.
    /// Returns whether the write landed.
    fn keep_welcome_route(
        &self,
        group_id: &GroupId,
        recipient: &str,
        relays: &[String],
        not_after: Option<u64>,
    ) -> bool;

    /// Where `recipient`'s Welcome to the circle goes, and its `KeyPackage`'s
    /// `not_after`; `Ok(None)` when no route is kept, [`RouteUnread`] when
    /// the store cannot say.
    ///
    /// # Errors
    ///
    /// [`RouteUnread`]: the read failed, and is logged by its storage code.
    fn welcome_route(
        &self,
        group_id: &GroupId,
        recipient: &str,
    ) -> Result<Option<KeptWelcomeRoute>, RouteUnread>;

    /// Forgets `recipient`'s route: their Welcome's record carries it, or
    /// the invite was undone.
    fn forget_welcome_route(&self, group_id: &GroupId, recipient: &str);

    /// Marks that the user's repair of the circle is being staged (`true`),
    /// or that the hold staging it has ended (`false`). Returns whether the
    /// write landed. A mark a process left standing tells the next open
    /// that a self-update it clears was the user's repair, which they are
    /// told was undone.
    fn mark_repair(&self, group_id: &GroupId, staging: bool) -> bool;

    /// Whether a repair's mark stands; `None` when that cannot be read.
    fn repair_marked(&self, group_id: &GroupId) -> Option<bool>;

    /// Records that the circle's removal by `commit`, withdrawn by branch
    /// selection, was dropped with its members held: what a later
    /// re-adoption of that commit takes back. Returns whether the write
    /// landed.
    fn keep_dropped_removal(&self, group_id: &GroupId, commit: &MessageId) -> bool;

    /// Takes the record of the dropped removal by `commit` away, answering
    /// whether there was one; `None` when that cannot be read.
    fn take_dropped_removal(&self, group_id: &GroupId, commit: &MessageId) -> Option<bool>;
}

/// A Welcome's kept route: its invitee's inbox relays, and the `not_after`
/// of the `KeyPackage` it is made for when that could be read.
pub type KeptWelcomeRoute = (Vec<String>, Option<u64>);

/// A session with no circle store behind it: the notes last as long as it
/// does.
#[derive(Default)]
pub(super) struct InMemoryCommitNotes(Mutex<HashMap<GroupId, Kept>>);

/// The epoch and the commit, when named, that took a kept target out; `None`
/// while it holds.
type TakenOut = Option<(u64, Option<MessageId>)>;

/// What is kept for one circle.
#[derive(Default)]
struct Kept {
    removes_nobody: bool,
    repair_marked: bool,
    dropped_removals: Vec<MessageId>,
    untold: u16,
    restage: Option<RestageWait>,
    removal_targets: Vec<(KeptTarget, TakenOut)>,
    welcome_routes: HashMap<String, KeptWelcomeRoute>,
    /// Writes that raised a note or held a member ([`ChangeNotice`]).
    writes: u64,
}

impl InMemoryCommitNotes {
    fn held(&self) -> std::sync::MutexGuard<'_, HashMap<GroupId, Kept>> {
        self.0.lock().unwrap_or_else(PoisonError::into_inner)
    }
}

/// Nothing is taken over for a session with no store: it could not be kept.
impl KeptInput for InMemoryCommitNotes {}

impl CommitNotes for InMemoryCommitNotes {
    /// A leave is asked for through a circle store, which a session with
    /// none does not have.
    fn leaving(&self, _group_id: &GroupId) -> Option<bool> {
        Some(false)
    }

    /// A session with no circle store has no rows to lose.
    fn circle_stands(&self, _group_id: &GroupId) -> Option<bool> {
        Some(true)
    }

    fn keep_welcome_route(
        &self,
        group_id: &GroupId,
        recipient: &str,
        relays: &[String],
        not_after: Option<u64>,
    ) -> bool {
        self.held()
            .entry(group_id.clone())
            .or_default()
            .welcome_routes
            .insert(recipient.to_owned(), (relays.to_vec(), not_after));
        true
    }

    fn welcome_route(
        &self,
        group_id: &GroupId,
        recipient: &str,
    ) -> Result<Option<KeptWelcomeRoute>, RouteUnread> {
        Ok(self
            .held()
            .get(group_id)
            .and_then(|kept| kept.welcome_routes.get(recipient).cloned()))
    }

    fn forget_welcome_route(&self, group_id: &GroupId, recipient: &str) {
        if let Some(kept) = self.held().get_mut(group_id) {
            kept.welcome_routes.remove(recipient);
        }
    }

    fn set_removes_nobody(&self, group_id: &GroupId, known: bool) -> bool {
        self.held()
            .entry(group_id.clone())
            .or_default()
            .removes_nobody = known;
        true
    }

    fn mark_repair(&self, group_id: &GroupId, staging: bool) -> bool {
        self.held()
            .entry(group_id.clone())
            .or_default()
            .repair_marked = staging;
        true
    }

    fn repair_marked(&self, group_id: &GroupId) -> Option<bool> {
        Some(
            self.held()
                .get(group_id)
                .is_some_and(|kept| kept.repair_marked),
        )
    }

    fn keep_dropped_removal(&self, group_id: &GroupId, commit: &MessageId) -> bool {
        let mut held = self.held();
        let kept = held.entry(group_id.clone()).or_default();
        if !kept.dropped_removals.contains(commit) {
            kept.dropped_removals.push(commit.clone());
        }
        drop(held);
        true
    }

    fn take_dropped_removal(&self, group_id: &GroupId, commit: &MessageId) -> Option<bool> {
        let mut held = self.held();
        let taken = held.get_mut(group_id).is_some_and(|kept| {
            let before = kept.dropped_removals.len();
            kept.dropped_removals.retain(|dropped| dropped != commit);
            kept.dropped_removals.len() != before
        });
        drop(held);
        Some(taken)
    }

    fn removes_nobody(&self, group_id: &GroupId) -> bool {
        self.held()
            .get(group_id)
            .is_some_and(|kept| kept.removes_nobody)
    }

    fn note(&self, group_id: &GroupId, note: ChangeNote) -> bool {
        let mut held = self.held();
        let kept = held.entry(group_id.clone()).or_default();
        kept.writes += u64::from(kept.untold & note.bit() == 0);
        kept.untold |= note.bit();
        drop(held);
        true
    }

    fn note_all(&self, groups: &[&GroupId], note: ChangeNote) -> bool {
        for group_id in groups {
            self.note(group_id, note);
        }
        true
    }

    fn notice(&self, group_id: &GroupId) -> ChangeNotice {
        self.held().get(group_id).map_or_else(
            || ChangeNotice::read(0, Some(0)),
            |kept| ChangeNotice::read(kept.untold, Some(kept.writes)),
        )
    }

    fn acknowledge(&self, group_id: &GroupId, notice: &ChangeNotice) -> bool {
        let mut held = self.held();
        let Some(kept) = held.get_mut(group_id) else {
            return notice.seen() == Some(0);
        };
        if notice.seen() != Some(kept.writes) {
            return false;
        }
        let bits = notice.dropped_bits();
        kept.untold &= !bits;
        if bits & ChangeNote::QueuedRemovalDropped.bit() != 0 {
            kept.removal_targets.clear();
        }
        drop(held);
        true
    }

    fn peek(&self, group_id: &GroupId) -> Vec<ChangeNote> {
        self.held()
            .get(group_id)
            .map_or_else(Vec::new, |kept| ChangeNote::of(kept.untold))
    }

    fn clear(&self, group_id: &GroupId, note: ChangeNote) {
        if let Some(kept) = self.held().get_mut(group_id) {
            kept.untold &= !note.bit();
            if note == ChangeNote::QueuedRemovalDropped {
                kept.removal_targets.clear();
            }
        }
    }

    fn keep_removal_targets(
        &self,
        group_id: &GroupId,
        targets: &[MemberId],
        set_aside_epoch: u64,
        asks: u32,
    ) -> bool {
        let mut held = self.held();
        let circle = held.entry(group_id.clone()).or_default();
        circle.writes += 1;
        let kept = &mut circle.removal_targets;
        for target in targets {
            kept.retain(|(kept, _)| &kept.member != target);
            kept.push((
                KeptTarget {
                    member: target.clone(),
                    set_aside_epoch,
                    asks,
                },
                None,
            ));
        }
        drop(held);
        true
    }

    fn removal_targets(&self, group_id: &GroupId) -> Option<Vec<MemberId>> {
        self.kept_removals(group_id)
            .map(|kept| kept.into_iter().map(|target| target.member).collect())
    }

    fn kept_removals(&self, group_id: &GroupId) -> Option<Vec<KeptTarget>> {
        Some(self.held().get(group_id).map_or_else(Vec::new, |kept| {
            kept.removal_targets
                .iter()
                .filter(|(_, gone)| gone.is_none())
                .map(|(target, _)| target.clone())
                .collect()
        }))
    }

    fn take_out_removal_targets(
        &self,
        group_id: &GroupId,
        members: &[MemberId],
        epoch: u64,
        by: Option<&MessageId>,
    ) -> bool {
        let mut changed = false;
        if let Some(kept) = self.held().get_mut(group_id) {
            for (target, gone) in &mut kept.removal_targets {
                if gone.is_none() && members.contains(&target.member) {
                    *gone = Some((epoch, by.cloned()));
                    changed = true;
                }
            }
        }
        changed
    }

    fn bring_back_removal_targets(
        &self,
        group_id: &GroupId,
        by: &MessageId,
        unkeyed_asks: u32,
    ) -> bool {
        let mut changed = false;
        if let Some(kept) = self.held().get_mut(group_id) {
            for (target, gone) in &mut kept.removal_targets {
                if let Some((_, taken_by)) = gone.take() {
                    if taken_by.as_ref() != Some(by) {
                        target.asks = target.asks.max(unkeyed_asks);
                    }
                    changed = true;
                }
            }
            kept.writes += u64::from(changed);
        }
        changed
    }

    fn spend_removal_asks(&self, group_id: &GroupId, asks: u32) -> bool {
        if let Some(kept) = self.held().get_mut(group_id) {
            for (target, gone) in &mut kept.removal_targets {
                if gone.is_none() {
                    target.asks = target.asks.max(asks);
                }
            }
        }
        true
    }

    fn taken_out_by(&self, group_id: &GroupId, member: &MemberId) -> Option<MessageId> {
        self.held().get(group_id).and_then(|kept| {
            kept.removal_targets
                .iter()
                .find(|(target, _)| &target.member == member)
                .and_then(|(_, gone)| gone.as_ref().and_then(|(_, by)| by.clone()))
        })
    }

    fn spend_target_asks(&self, group_id: &GroupId, members: &[MemberId], asks: u32) -> bool {
        if let Some(kept) = self.held().get_mut(group_id) {
            for (target, _) in &mut kept.removal_targets {
                if members.contains(&target.member) {
                    target.asks = target.asks.max(asks);
                }
            }
        }
        true
    }

    fn forget_gone_removal_targets(&self, group_id: &GroupId, before_epoch: u64) {
        if let Some(kept) = self.held().get_mut(group_id) {
            kept.removal_targets.retain(|(_, gone)| {
                gone.as_ref()
                    .is_none_or(|(epoch, _)| *epoch >= before_epoch)
            });
        }
    }

    fn count_removal_asks(
        &self,
        group_id: &GroupId,
        members: &[MemberId],
    ) -> Option<Vec<(MemberId, u32)>> {
        let mut counted = Vec::new();
        if let Some(kept) = self.held().get_mut(group_id) {
            for (target, _) in &mut kept.removal_targets {
                if members.contains(&target.member) {
                    target.asks = target.asks.saturating_add(1);
                    counted.push((target.member.clone(), target.asks));
                }
            }
        }
        Some(counted)
    }

    fn refund_removal_asks(&self, group_id: &GroupId, counted: &[(MemberId, u32)]) {
        if let Some(kept) = self.held().get_mut(group_id) {
            for (target, _) in &mut kept.removal_targets {
                if counted.contains(&(target.member.clone(), target.asks)) {
                    target.asks = target.asks.saturating_sub(1);
                }
            }
        }
    }

    fn settle_removal(&self, group_id: &GroupId) {
        if let Some(kept) = self.held().get_mut(group_id) {
            kept.untold &= !ChangeNote::QueuedRemovalDropped.bit();
        }
    }

    fn restage_wait(&self, group_id: &GroupId) -> Option<RestageWait> {
        self.held().get(group_id).and_then(|kept| kept.restage)
    }

    fn set_restage_wait(&self, group_id: &GroupId, wait: Option<RestageWait>) {
        self.held().entry(group_id.clone()).or_default().restage = wait;
    }
}

/// What an acknowledgement drops, held for each store: exactly what its
/// notice read. A member held after the read, and its note, stand; a notice
/// acknowledged once drops nothing more when acknowledged again; and a note
/// written again while it stands supersedes no notice.
#[cfg(test)]
pub fn a_notice_drops_only_what_it_read(notes: &dyn CommitNotes) {
    use crate::nostr::mls::types::GroupIdExt;
    let circle = GroupId::from_slice(&[7; 32]);
    let (first, later) = (MemberId::new(vec![1; 32]), MemberId::new(vec![2; 32]));
    let held = |notes: &dyn CommitNotes| -> Vec<MemberId> {
        let mut held = notes.removal_targets(&circle).expect("read");
        held.sort_by(|a, b| a.as_slice().cmp(b.as_slice()));
        held
    };
    assert!(notes.keep_removal_targets(&circle, std::slice::from_ref(&first), 3, 0));
    assert!(notes.note(&circle, ChangeNote::QueuedRemovalDropped));
    assert!(notes.note(&circle, ChangeNote::ChangeWithdrawn));
    let stale = notes.notice(&circle);
    assert!(stale.notes.contains(&ChangeNote::ChangeWithdrawn));

    // A later removal's member held after the read; its note, raised again
    // while it stands, is not what supersedes the read.
    assert!(notes.note(&circle, ChangeNote::ChangeWithdrawn));
    assert!(notes.keep_removal_targets(&circle, std::slice::from_ref(&later), 4, 0));
    assert!(
        !notes.acknowledge(&circle, &stale),
        "a notice read before a later write dropped something",
    );
    assert!(
        notes.peek(&circle).contains(&ChangeNote::ChangeWithdrawn)
            && held(notes) == [first.clone(), later],
        "a note raised, or a member held, after the read was dropped unseen",
    );

    let shown = notes.notice(&circle);
    assert!(notes.acknowledge(&circle, &shown));
    assert!(
        notes.peek(&circle).is_empty() && held(notes).is_empty(),
        "what the notice read was not dropped",
    );
    assert!(
        notes.acknowledge(&circle, &shown),
        "a notice nothing has superseded was said to be superseded",
    );
    assert!(notes.note(&circle, ChangeNote::QueuedRemovalDropped));
    assert!(notes.keep_removal_targets(&circle, std::slice::from_ref(&first), 5, 0));
    assert!(
        !notes.acknowledge(&circle, &shown) && held(notes) == [first],
        "a notice acknowledged a second time dropped a later removal's hold",
    );
    let untouched = GroupId::from_slice(&[8; 32]);
    assert!(
        notes.acknowledge(&untouched, &notes.notice(&untouched)),
        "a circle that never had a note could not be acknowledged",
    );

    // Written again while it stands, a note is nothing new: a notice read
    // before the repeat still drops what it read.
    let repeated = GroupId::from_slice(&[9; 32]);
    assert!(notes.note(&repeated, ChangeNote::QueuedChangesHeld));
    assert!(notes.note(&repeated, ChangeNote::ChangeWithdrawn));
    let read = notes.notice(&repeated);
    for _ in 0..2 {
        assert!(notes.note(&repeated, ChangeNote::QueuedChangesHeld));
        assert!(notes.note(&repeated, ChangeNote::ChangeWithdrawn));
    }
    assert!(
        notes.acknowledge(&repeated, &read)
            && !notes.peek(&repeated).contains(&ChangeNote::ChangeWithdrawn),
        "a note written again while it stood superseded a notice that had read it",
    );
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::nostr::mls::types::GroupIdExt;

    /// A notice renders its notes and nothing of how often its circle was
    /// written to: that count is the circle's activity.
    #[test]
    fn change_notice_debug_redacts_its_write_count() {
        let notice = ChangeNotice::read(ChangeNote::WelcomeOwed.bit(), Some(48_271));
        let rendered = format!("{notice:?}");
        assert!(
            rendered.contains("WelcomeOwed"),
            "a notice's rendering lost its notes"
        );
        assert!(
            !rendered.contains("48271"),
            "a notice's rendering carries its write count",
        );
    }

    #[test]
    fn a_bare_sessions_notice_drops_only_what_it_read() {
        a_notice_drops_only_what_it_read(&InMemoryCommitNotes::default());
    }

    #[test]
    fn a_bare_sessions_notes_are_per_circle_and_kept_until_cleared() {
        let notes = InMemoryCommitNotes::default();
        let circle = GroupId::from_slice(&[1; 32]);
        let other = GroupId::from_slice(&[2; 32]);

        assert!(!notes.removes_nobody(&circle), "unknown reads as a removal");
        assert!(notes.set_removes_nobody(&circle, true));
        assert!(notes.removes_nobody(&circle) && !notes.removes_nobody(&other));
        assert!(notes.set_removes_nobody(&circle, false));
        assert!(!notes.removes_nobody(&circle));

        assert!(notes.note(&circle, ChangeNote::ChangeUndone));
        assert!(notes.note(&circle, ChangeNote::RemovalUndone));
        assert!(notes.note(&circle, ChangeNote::RemovalUndone));
        assert!(notes.peek(&other).is_empty());
        assert_eq!(
            notes.peek(&circle),
            [ChangeNote::RemovalUndone, ChangeNote::ChangeUndone]
        );
        assert_eq!(
            notes.peek(&circle),
            [ChangeNote::RemovalUndone, ChangeNote::ChangeUndone],
            "reading a note took it",
        );
        notes.clear(&circle, ChangeNote::RemovalUndone);
        notes.clear(&other, ChangeNote::ChangeUndone);
        assert_eq!(
            notes.peek(&circle),
            [ChangeNote::ChangeUndone],
            "telling a circle one thing forgot another, or told another circle",
        );
    }

    /// A bare session keeps who a removal set aside unmade named as a stored
    /// one does: per circle, once each, with its epoch and count; a member
    /// an applied commit took out stops holding, and comes back — its asks
    /// spent unless keyed to the commit withdrawn — at any withdrawal until
    /// it is forgotten past the horizon; the note can be taken back
    /// with the targets kept; and the user's acknowledgement takes both.
    #[test]
    fn a_bare_sessions_removal_targets_are_kept_with_their_note_and_end_with_it() {
        let notes = InMemoryCommitNotes::default();
        let circle = GroupId::from_slice(&[1; 32]);
        let other = GroupId::from_slice(&[2; 32]);
        let member = |seed: u8| MemberId::new(vec![seed; 32]);
        let held = |group: &GroupId| {
            let mut held = notes.removal_targets(group).expect("read");
            held.sort_by(|a, b| a.as_slice().cmp(b.as_slice()));
            held
        };

        // `assert!`, not `assert_eq!`: a member id is never formatted
        // (Security Rule 15).
        assert!(held(&circle).is_empty());
        assert!(notes.note(&circle, ChangeNote::QueuedRemovalDropped));
        assert!(
            notes.stands(&circle, ChangeNote::QueuedRemovalDropped) == Some(true)
                && notes.stands(&other, ChangeNote::QueuedRemovalDropped) == Some(false),
            "a note that stands for one circle does not read so, or reads so for another",
        );
        assert!(notes.keep_removal_targets(&circle, &[member(3), member(4)], 7, 0));
        assert!(notes.count_removal_asks(&circle, &[member(4)]).is_some());
        assert!(notes.keep_removal_targets(&circle, &[member(4), member(5)], 9, 0));
        assert!(notes.keep_removal_targets(&other, &[member(9)], 1, 2));
        assert!(
            held(&circle) == [member(3), member(4), member(5)]
                && notes
                    .kept_removals(&circle)
                    .expect("read")
                    .iter()
                    .all(|kept| {
                        (kept.member == member(3)) == (kept.set_aside_epoch == 7) && kept.asks == 0
                    }),
            "a removal's target was lost or kept twice, or a member kept again did not start over",
        );
        let commit = MessageId::new(vec![0xc0; 32]);
        let other_commit = MessageId::new(vec![0xc1; 32]);
        let asks = |member_seed: u8| {
            notes
                .kept_removals(&circle)
                .expect("read")
                .into_iter()
                .find(|kept| kept.member == member(member_seed))
                .map(|kept| kept.asks)
        };
        assert!(
            notes.take_out_removal_targets(&circle, &[member(4)], 12, Some(&commit))
                && !notes.take_out_removal_targets(&circle, &[member(4)], 13, None)
                && notes.take_out_removal_targets(&circle, &[member(5)], 12, None)
                && held(&circle) == [member(3)],
            "a member a commit took out still holds, or was taken out twice",
        );
        assert!(
            notes.bring_back_removal_targets(&circle, &commit, 2)
                && held(&circle) == [member(3), member(4), member(5)]
                && asks(4) == Some(0)
                && asks(5) == Some(2),
            "a withdrawal did not bring back every target taken out, or spent the asks of the \
             one keyed to it, or kept those of one it cannot be keyed to",
        );
        assert!(
            notes.spend_removal_asks(&circle, 2) && asks(3) == Some(2) && asks(4) == Some(2),
            "a pass of several commits did not spend the asks of every target that holds",
        );
        assert!(notes.take_out_removal_targets(&circle, &[member(4)], 12, Some(&other_commit)));
        notes.forget_gone_removal_targets(&circle, 12);
        assert!(
            notes.bring_back_removal_targets(&circle, &commit, 2)
                && notes.take_out_removal_targets(&circle, &[member(4)], 12, Some(&commit)),
            "a member taken out at the horizon's edge was forgotten",
        );
        notes.forget_gone_removal_targets(&circle, 13);
        assert!(
            !notes.bring_back_removal_targets(&circle, &commit, 2)
                && held(&circle) == [member(3), member(5)],
            "a member taken out past the horizon was not forgotten",
        );
        notes.settle_removal(&circle);
        assert!(
            !notes
                .peek(&circle)
                .contains(&ChangeNote::QueuedRemovalDropped)
                && held(&circle).len() == 2,
            "taking the note back took the targets, or left the note",
        );
        assert!(notes.note(&circle, ChangeNote::QueuedRemovalDropped));
        notes.clear(&circle, ChangeNote::ChangeUndone);
        assert!(
            held(&circle).len() == 2,
            "clearing another note took a removal's targets",
        );
        notes.clear(&circle, ChangeNote::QueuedRemovalDropped);
        assert!(
            held(&circle).is_empty() && held(&other) == [member(9)],
            "a removal's targets outlived its note, or another circle's went with them",
        );
    }

    #[test]
    fn every_note_has_its_own_bit() {
        let all = ChangeNote::ALL
            .iter()
            .fold(0_u16, |all, note| all | note.bit());
        assert_eq!(ChangeNote::of(all), ChangeNote::ALL);
        assert_eq!(all.count_ones() as usize, ChangeNote::ALL.len());
    }

    #[test]
    fn restage_wait_debug_redacts_its_count_and_its_instant() {
        let rendered = format!(
            "{:?}",
            RestageWait {
                rollbacks: 7,
                not_before_ms: 1_700_000_120_000,
            }
        );
        assert!(!rendered.contains('7') && !rendered.contains("1700000120000"));
        assert!(!rendered.contains("rollbacks") && !rendered.contains("not_before"));
    }

    #[test]
    fn a_bare_sessions_restage_wait_is_per_circle_and_ends_when_told() {
        let notes = InMemoryCommitNotes::default();
        let circle = GroupId::from_slice(&[1; 32]);
        let other = GroupId::from_slice(&[2; 32]);
        let wait = RestageWait {
            rollbacks: 3,
            not_before_ms: 9_000,
        };

        assert_eq!(notes.restage_wait(&circle), None);
        notes.set_restage_wait(&circle, Some(wait));
        assert!(notes.note(&circle, ChangeNote::ChangeUndone));
        assert_eq!(notes.restage_wait(&circle), Some(wait));
        assert_eq!(notes.restage_wait(&other), None);
        notes.set_restage_wait(&circle, None);
        assert_eq!(notes.restage_wait(&circle), None);
        assert_eq!(notes.peek(&circle), [ChangeNote::ChangeUndone]);
    }
}

/// A Welcome's route the circle store could not read: the caller holds the
/// Welcome for the next drive rather than take the absence for "no route".
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RouteUnread;
