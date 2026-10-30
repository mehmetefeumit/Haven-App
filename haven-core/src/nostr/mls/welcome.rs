//! Hold-before-ingest pending-welcome store (security F3, plan §5.4 / §8.4-A).
//!
//! # Why hold, not decrypt
//!
//! In the Dark Matter stack, feeding a gift-wrapped welcome (kind 1059) into
//! `AccountDeviceSession::ingest` **auto-joins** the group and emits
//! `GroupEvent::GroupJoined`. There is no "pending / declined" MLS state — the
//! act of ingesting is the act of accepting. To preserve Haven's accept /
//! decline UX (and Rule 10: a decline must leave no on-wire trace), Haven holds
//! the **still-NIP-59-encrypted 1059 event** in this store and only ingests it
//! when the user taps Accept:
//!
//! - **Accept** → hand the held 1059 to `SessionManager::accept_welcome`, which
//!   ingests it (the engine peels + joins, emitting `GroupJoined`).
//! - **Decline** → [`PendingWelcomeStore::remove_recording`] drops the held 1059
//!   locally. It is never ingested, so no join commit, no self-remove, nothing
//!   on the wire.
//!
//! # Secret-at-rest posture (F3 / Rule 7)
//!
//! The store holds the **encrypted** 1059 event only. The decrypted MLS welcome
//! bytes (which carry group-join secrets) are NEVER stored here — they exist
//! transiently inside the engine during `accept_welcome` and nowhere else. The
//! optional [`WelcomePreview`] is derived from a transient peel that reads only
//! the NIP-59 seal author (the inviter) and immediately discards the welcome
//! bytes; it holds no secret material. Nothing in this module is logged.

use std::collections::HashMap;
use std::sync::Mutex;

use nostr::{Event, EventId};

use crate::log_alias::{self, bucket, EventIdHex};

/// Non-secret preview shown to the user before they accept a welcome.
///
/// Derived from a transient peel of the gift wrap that reads only the NIP-59
/// seal author; the decrypted MLS welcome bytes are discarded and never land
/// here. Group name / member count are intentionally unavailable pre-join (they
/// live inside the encrypted MLS welcome), so this preview is deliberately
/// minimal.
#[derive(Clone)]
pub struct WelcomePreview {
    /// The inviter's public key (hex-encoded), from the NIP-59 seal author.
    ///
    /// Never empty, and always a well-formed public key: the preview is only
    /// ever built by `SessionManager::preview_welcome`, which refuses a welcome
    /// whose peel exposes no usable author rather than previewing a blank
    /// identity beside an Accept button.
    pub inviter_pubkey: String,
}

impl std::fmt::Debug for WelcomePreview {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        // The inviter pubkey is not secret, but keep it out of logs anyway so a
        // stray Debug line never correlates an invite to a specific inviter.
        f.debug_struct("WelcomePreview")
            .field("inviter_pubkey", &"<redacted>")
            .finish()
    }
}

/// A single held, still-encrypted welcome awaiting the user's accept / decline.
#[derive(Clone)]
pub struct PendingWelcome {
    /// The still-NIP-59-encrypted kind-1059 gift wrap. Held verbatim so Accept
    /// can hand it to the engine for peel + join; NEVER decrypted at rest.
    gift_wrap: Event,
    /// Non-secret preview for the UI.
    preview: WelcomePreview,
}

impl PendingWelcome {
    /// Wraps a held gift wrap with its non-secret preview.
    #[must_use]
    pub const fn new(gift_wrap: Event, preview: WelcomePreview) -> Self {
        Self { gift_wrap, preview }
    }

    /// The gift wrap's event id — the store key.
    #[must_use]
    pub const fn id(&self) -> EventId {
        self.gift_wrap.id
    }

    /// The still-encrypted 1059 event, for the accept path to ingest.
    #[must_use]
    pub const fn gift_wrap(&self) -> &Event {
        &self.gift_wrap
    }

    /// The non-secret preview.
    #[must_use]
    pub const fn preview(&self) -> &WelcomePreview {
        &self.preview
    }
}

impl std::fmt::Debug for PendingWelcome {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        // The store is keyed by the gift-wrap id, so the alias handle keeps two
        // renderings of the same held welcome comparable without naming the
        // event any relay also saw (Rule 15). The body is never decrypted here.
        f.debug_struct("PendingWelcome")
            .field(
                "gift_wrap",
                &log_alias::event(EventIdHex(&self.gift_wrap.id.to_hex())),
            )
            .field("gift_wrap_body", &"<redacted>")
            .field("preview", &self.preview)
            .finish()
    }
}

/// In-memory store of held, still-encrypted welcomes, keyed by gift-wrap id.
///
/// Thread-safe (a plain `std::sync::Mutex` — the held values are already-public
/// ciphertext, and the critical sections never `.await`).
#[derive(Default)]
pub struct PendingWelcomeStore {
    inner: Mutex<HashMap<EventId, PendingWelcome>>,
}

impl PendingWelcomeStore {
    /// Creates an empty store.
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Holds `welcome` once `mark` has recorded how many are then held, keyed
    /// by its gift-wrap id; a failed `mark` holds nothing.
    ///
    /// `mark` runs under this store's lock, as the `unmark` of
    /// [`Self::remove_recording`] and [`Self::unmark_if_empty`] does: a record
    /// kept beside the store ("an invitation is held") can therefore never be
    /// cleared by one caller between another's mark and its insert.
    ///
    /// Idempotent per gift-wrap id: re-receiving the same 1059 from a second
    /// relay overwrites the identical entry rather than duplicating it.
    ///
    /// # Errors
    ///
    /// Returns `mark`'s error.
    pub fn insert_marked<E>(
        &self,
        welcome: PendingWelcome,
        mark: impl FnOnce(usize) -> std::result::Result<(), E>,
    ) -> std::result::Result<(), E> {
        let mut guard = self.lock();
        mark(guard.len() + usize::from(!guard.contains_key(&welcome.id())))?;
        guard.insert(welcome.id(), welcome);
        drop(guard);
        Ok(())
    }

    #[cfg(test)]
    fn insert(&self, welcome: PendingWelcome) {
        let mut guard = self.lock();
        guard.insert(welcome.id(), welcome);
    }

    /// Returns a clone of the held welcome for `id`, if present.
    #[must_use]
    pub fn get(&self, id: &EventId) -> Option<PendingWelcome> {
        self.lock().get(id).cloned()
    }

    /// Removes and returns the held welcome for `id`, and has `record` told
    /// how many are still held — under the lock [`Self::insert_marked`] marks
    /// under.
    ///
    /// This is the **decline** path (drop, never ingest) and also the
    /// post-accept cleanup (remove after a successful join). Either way the
    /// still-encrypted 1059 is dropped locally with no on-wire trace.
    pub fn remove_recording(
        &self,
        id: &EventId,
        record: impl FnOnce(usize),
    ) -> Option<PendingWelcome> {
        let mut guard = self.lock();
        let removed = guard.remove(id);
        record(guard.len());
        drop(guard);
        removed
    }

    /// Runs `unmark` if nothing is held, under the same lock.
    pub fn unmark_if_empty(&self, unmark: impl FnOnce()) {
        let guard = self.lock();
        if guard.is_empty() {
            unmark();
        }
        drop(guard);
    }

    #[cfg(test)]
    fn remove(&self, id: &EventId) -> Option<PendingWelcome> {
        self.lock().remove(id)
    }

    /// Whether a welcome with `id` is currently held.
    #[must_use]
    pub fn contains(&self, id: &EventId) -> bool {
        self.lock().contains_key(id)
    }

    /// The (id, preview) pairs for every held welcome, for the invitations UI.
    #[must_use]
    pub fn previews(&self) -> Vec<(EventId, WelcomePreview)> {
        self.lock()
            .iter()
            .map(|(id, w)| (*id, w.preview.clone()))
            .collect()
    }

    /// Number of held welcomes.
    #[must_use]
    pub fn len(&self) -> usize {
        self.lock().len()
    }

    /// Whether the store is empty.
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.lock().is_empty()
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, HashMap<EventId, PendingWelcome>> {
        // A poisoned lock only means a prior holder panicked mid-mutation; the
        // held ciphertext is not corruptible, so recover the guard rather than
        // propagate the panic.
        self.inner
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
    }
}

impl std::fmt::Debug for PendingWelcomeStore {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        // Bucketed: how many invitations are pending is how many circles are
        // inviting this device right now (Rule 15).
        f.debug_struct("PendingWelcomeStore")
            .field("held", &bucket(self.len()))
            .finish()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use nostr::{EventBuilder, Keys, Kind};

    /// Builds a throwaway signed event to stand in for a held 1059 in store
    /// mechanics tests. (A real gift wrap is produced by the peeler; the store
    /// only ever treats the event as opaque held bytes keyed by its id.)
    fn fake_gift_wrap(tag: &str) -> Event {
        EventBuilder::new(Kind::Custom(1059), tag)
            .sign_with_keys(&Keys::generate())
            .expect("sign test event")
    }

    fn pending(tag: &str) -> PendingWelcome {
        PendingWelcome::new(
            fake_gift_wrap(tag),
            WelcomePreview {
                inviter_pubkey: "deadbeef".to_string(),
            },
        )
    }

    #[test]
    fn insert_get_and_contains() {
        let store = PendingWelcomeStore::new();
        let w = pending("a");
        let id = w.id();
        assert!(!store.contains(&id));

        store.insert(w);
        assert!(store.contains(&id));
        assert_eq!(store.len(), 1);
        let got = store.get(&id).expect("held");
        assert_eq!(got.id(), id);
        assert_eq!(got.preview().inviter_pubkey, "deadbeef");
    }

    #[test]
    fn decline_removes_without_exposing_body() {
        // The decline path: remove drops the held 1059 locally. The store never
        // decrypted it, so nothing on-wire and no secret material anywhere.
        let store = PendingWelcomeStore::new();
        let w = pending("decline");
        let id = w.id();
        store.insert(w);

        let removed = store.remove(&id).expect("declined welcome is returned");
        assert_eq!(removed.id(), id);
        assert!(!store.contains(&id));
        assert!(store.is_empty());

        // A second decline of the same id is a no-op.
        assert!(store.remove(&id).is_none());
    }

    /// The record kept beside the store is written and cleared with the store
    /// locked, so no clear can land between another caller's mark and its
    /// insert. Every callback notes whether the lock is held as it runs: a
    /// `std` mutex its own thread already holds answers `try_lock` with an
    /// error.
    #[test]
    fn the_mark_beside_the_store_is_written_and_cleared_under_the_stores_lock() {
        let store = PendingWelcomeStore::new();
        let seen = std::cell::RefCell::new(Vec::new());
        let note = |label: &'static str| {
            let (seen, store) = (&seen, &store);
            move || {
                seen.borrow_mut()
                    .push((label, store.inner.try_lock().is_err()));
            }
        };
        let (first, second) = (pending("first"), pending("second"));
        let (first_id, second_id) = (first.id(), second.id());

        let counts = std::cell::RefCell::new(Vec::new());
        let mark = note("mark");
        store
            .insert_marked(first.clone(), |held| {
                mark();
                counts.borrow_mut().push(held);
                Ok::<(), ()>(())
            })
            .expect("held");
        store
            .insert_marked(first, |held| {
                counts.borrow_mut().push(held);
                Ok::<(), ()>(())
            })
            .expect("held again");
        store
            .insert_marked(second, |held| {
                counts.borrow_mut().push(held);
                Ok::<(), ()>(())
            })
            .expect("held");
        assert!(store.contains(&first_id) && store.contains(&second_id));

        // Each removal is told how many are left; nothing is cleared early.
        let record = note("record");
        assert!(store
            .remove_recording(&first_id, |held| {
                record();
                counts.borrow_mut().push(held);
            })
            .is_some());
        store.unmark_if_empty(note("early unmark"));
        assert!(store
            .remove_recording(&second_id, |held| counts.borrow_mut().push(held))
            .is_some());
        store.unmark_if_empty(note("unmark when empty"));
        assert_eq!(
            seen.into_inner(),
            [
                ("mark", true),
                ("record", true),
                ("unmark when empty", true)
            ]
        );
        assert_eq!(counts.into_inner(), [1, 1, 2, 1, 0]);

        // A mark that fails holds nothing.
        let refused = pending("refused");
        let refused_id = refused.id();
        assert_eq!(store.insert_marked(refused, |_| Err("no")), Err("no"));
        assert!(!store.contains(&refused_id) && store.is_empty());
    }

    #[test]
    fn insert_is_idempotent_per_gift_wrap_id() {
        // Re-receiving the same 1059 from a second relay must not duplicate it.
        let store = PendingWelcomeStore::new();
        let w = pending("dup");
        let id = w.id();
        store.insert(w.clone());
        store.insert(w);
        assert_eq!(store.len(), 1);
        assert!(store.contains(&id));
    }

    #[test]
    fn previews_lists_every_held_welcome() {
        let store = PendingWelcomeStore::new();
        store.insert(pending("one"));
        store.insert(pending("two"));
        let previews = store.previews();
        assert_eq!(previews.len(), 2);
    }

    #[test]
    fn pending_welcome_debug_redacts_the_body_the_id_and_the_inviter() {
        let w: PendingWelcome = pending("secret-body");
        let gift_wrap_id = w.id().to_hex();
        let inviter = w.preview().inviter_pubkey.clone();
        let debug_pending = format!("{w:?}");
        assert!(debug_pending.contains("event#"), "expected an alias handle");
        crate::assert_debug_redacted!(
            w,
            "PendingWelcome",
            &["secret-body", &gift_wrap_id, &inviter]
        );
    }

    /// How many invitations are pending is how many circles are inviting this
    /// device right now, so the store reports a BUCKET (Rule 15).
    #[test]
    fn pending_welcome_store_debug_redacts_what_it_holds() {
        let store = PendingWelcomeStore::new();
        let held = pending("SECRET_GIFTWRAP_BODY");
        let gift_wrap_id = held.id().to_hex();
        let inviter = held.preview().inviter_pubkey.clone();
        store.insert(held);
        assert!(format!("{store:?}").contains("held: \"1\""));
        // Nothing ABOUT the held welcomes, only how many: not the bodies, not
        // the gift-wrap ids it is keyed by, not the inviters.
        crate::assert_debug_redacted!(
            store,
            "PendingWelcomeStore",
            &["SECRET_GIFTWRAP_BODY", &gift_wrap_id, &inviter]
        );

        for tag in ["two", "three", "four", "five", "six"] {
            store.insert(pending(tag));
        }
        let rendered = format!("{store:?}");
        assert!(
            rendered.contains("held: \"5+\""),
            "six held welcomes must render as the 5+ bucket: {rendered}"
        );
    }

    #[test]
    fn welcome_preview_debug_redacts_the_inviter() {
        let inviter = Keys::generate().public_key().to_hex();
        let preview = WelcomePreview {
            inviter_pubkey: inviter.clone(),
        };
        crate::assert_debug_redacted!(preview, "WelcomePreview", &[&inviter]);
    }
}
