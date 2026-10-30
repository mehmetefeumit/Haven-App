//! What Haven keeps of a circle's input that the engine left parked.
//!
//! While a commit of this device's own is pending, MDK v0.10.4 stores every
//! `kind:445` it is handed for that circle unopened and reads those rows
//! again only at the end of a confirm, of a rollback and of a join
//! (`cgka-engine/src/message_processor/mod.rs` 3544-3559). A row left behind
//! when that replay does not run, or does not finish, is delivered by
//! nothing (`docs/MDK_UPSTREAM_TRACKER.md` T-PARKED-REPLAY). Haven takes such
//! a row over: the signed event is kept here, the engine's row is released
//! through MDK's own `MessageStorage::release_message_for_replay`, and the
//! event is handed back to the engine as a relay would hand it.
//!
//! An entry is the event exactly as a relay served it: ciphertext under the
//! circle's epoch key, readable by nobody who could not read it on the relay.
//! It is written BEFORE the engine's row is released and ended only on an
//! answer — the engine judged the event, holds it again, has its own record
//! of it, or has no room for it, which leaves it owed a refetch by id as any
//! refused event is — or with its circle. So no death between the two loses
//! it, and no count of errors or of epochs does: what the engine could not
//! take may be an event from an epoch the device has not reached. Nothing
//! here is ever logged.

use super::types::{GroupId, MessageId};

/// The most entries of any standing one circle may have here.
///
/// Only an event the engine has not answered for yet, and one it erred on
/// without keeping any record of it — its own store failed — stand here, so
/// nothing anyone can send fills it: what the engine has no room for ends,
/// and so does what it recorded and then could not open. Past this nothing
/// more of that circle is taken over until an entry ends, and the circle's
/// sends and receives wait for that.
pub const KEPT_EVENTS_PER_CIRCLE: usize = 256;

/// The most event bytes one circle may have kept here at once.
pub const KEPT_BYTES_PER_CIRCLE: usize = 4 * 1024 * 1024;

/// One entry: an event Haven holds for the engine.
///
/// **No `Debug`**: an id is an event id and the event is a circle's traffic
/// (Security Rule 15).
#[derive(Clone, PartialEq, Eq)]
pub struct KeptEvent {
    /// The event's id, which is the id the engine stored it under.
    pub id: MessageId,
    /// Whether the event reads, by its tags alone, as a commit or a proposal
    /// rather than a location: it carries no NIP-40 expiration. It chooses
    /// the words of the circle's note and nothing else.
    pub change: bool,
    /// Whether the engine has been handed the event and erred on it. Such
    /// an entry is asked for again once at each look, behind everything the
    /// engine has not yet seen.
    pub asked: bool,
    /// The signed event as JSON.
    pub event: String,
}

/// Where a circle's taken-over input is kept. Durable when the session was
/// opened over a `CircleManager`'s store; a store that keeps nothing — the
/// default of every method — has nothing released for it.
pub trait KeptInput: Send + Sync {
    /// Everything kept for `group_id`, in the order it was kept; `None` when
    /// that cannot be read, which stops every release for the circle.
    fn kept(&self, _group_id: &GroupId) -> Option<Vec<KeptEvent>> {
        Some(Vec::new())
    }

    /// Whether anything can be kept here at all: not in a session with no
    /// store, for which no call waits.
    fn durable(&self) -> bool {
        false
    }

    /// Keeps `event` behind everything already kept. An id already here is
    /// left as it stands. Returns whether the entry is durably there: the
    /// engine's row is released only then.
    fn keep(&self, _group_id: &GroupId, _id: &MessageId, _change: bool, _event: &str) -> bool {
        false
    }

    /// Ends an entry: the engine judged the event, holds it again or has its
    /// own record of it. Returns whether the write landed.
    fn end(&self, _id: &MessageId) -> bool {
        false
    }

    /// Marks an entry as one the engine was handed and erred on
    /// ([`KeptEvent::asked`]). The event stays: Haven's copy is then the
    /// only one.
    fn unanswered(&self, _id: &MessageId) {}

    /// Destroys everything kept for `group_id`: this device is out of the
    /// circle, or the circle is gone.
    fn forget(&self, _group_id: &GroupId) {}
}
