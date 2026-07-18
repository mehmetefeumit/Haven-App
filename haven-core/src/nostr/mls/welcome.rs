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
//! - **Decline** → [`PendingWelcomeStore::remove`] drops the held 1059 locally.
//!   It is never ingested, so no join commit, no self-remove, nothing on the
//!   wire.
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
        // Present the gift-wrap id (public, its own event id) but never the
        // encrypted body.
        f.debug_struct("PendingWelcome")
            .field("gift_wrap_id", &self.gift_wrap.id)
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

    /// Inserts (or replaces) a held welcome, keyed by its gift-wrap id.
    ///
    /// Idempotent per gift-wrap id: re-receiving the same 1059 from a second
    /// relay overwrites the identical entry rather than duplicating it.
    pub fn insert(&self, welcome: PendingWelcome) {
        let mut guard = self.lock();
        guard.insert(welcome.id(), welcome);
    }

    /// Returns a clone of the held welcome for `id`, if present.
    #[must_use]
    pub fn get(&self, id: &EventId) -> Option<PendingWelcome> {
        self.lock().get(id).cloned()
    }

    /// Removes and returns the held welcome for `id`.
    ///
    /// This is the **decline** path (drop, never ingest) and also the
    /// post-accept cleanup (remove after a successful join). Either way the
    /// still-encrypted 1059 is dropped locally with no on-wire trace.
    pub fn remove(&self, id: &EventId) -> Option<PendingWelcome> {
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
        f.debug_struct("PendingWelcomeStore")
            .field("held", &self.len())
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
    fn debug_redacts_body_and_preview() {
        let store = PendingWelcomeStore::new();
        let w = pending("secret-body");
        let debug_pending = format!("{w:?}");
        assert!(debug_pending.contains("PendingWelcome"));
        assert!(debug_pending.contains("<redacted>"));
        // The store Debug only exposes a count.
        store.insert(w);
        let debug_store = format!("{store:?}");
        assert!(debug_store.contains("held: 1"));
    }
}
