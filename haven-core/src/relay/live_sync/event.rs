//! Core data types carried by the live-sync engine.
//!
//! Two enums sit at the heart of the engine:
//!
//! - [`EngineDecryptOutcome`] is the **neutral** result of attempting to
//!   process one incoming relay event. It is produced from the real
//!   `CircleManager` decrypt path (M3b) and from hand-built fixtures in unit
//!   tests, so the pure processor planning ([`super::plan`]) can be exercised
//!   without a relay or MLS state.
//! - [`LiveSyncEvent`] is what the engine **emits** on its broadcast bus (and,
//!   at the FFI boundary in M3c, what is mapped to `FfiRelayEvent`).
//!
//! Both carry decrypted content or relay-public identifiers, so their `Debug`
//! impls are hand-written to be **presence-only** (no coordinates, group-id
//! bytes, message content, or JSON) per Security Rule 8.

/// A non-content lifecycle / status signal emitted by the engine.
///
/// Mirrors the FFI `FfiSyncStatusReason` (M3c); kept as a closed enum so a raw
/// error string never reaches the UI (Security Rule 8).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SyncStatusReason {
    /// The engine is establishing relay connections.
    Connecting,
    /// The receive plane is serving: all required relays are connected at
    /// session start, **and** — emitted again later — a REQ this device had lost
    /// is live once more.
    ///
    /// The second meaning is what pairs with [`Self::RelayError`]. A relay
    /// `CLOSED` emits `RelayError`; when the repair puts that REQ back on the
    /// wire, this is the recovery signal, so a consumer showing "sharing may be
    /// paused" on the error has something to clear it on. Without it that banner
    /// would stand indefinitely, because the repair is otherwise silent.
    Connected,
    /// A relay dropped and the engine is re-establishing it.
    Reconnecting,
    /// A relay is disconnected.
    Disconnected,
    /// An incoming group message could not be processed (no cursor advance).
    Unprocessable,
    /// An inbox (gift-wrap) processing step failed.
    InboxError,
    /// A relay-level operation failed.
    RelayError,
    /// A live-sync session was started.
    SessionStarted,
    /// A live-sync session was stopped.
    SessionStopped,
    /// The session resumed from background.
    BackgroundResumed,
    /// The session is paused between background bursts: no standing REQ, no
    /// socket.
    ///
    /// Emitted ONCE per ENTRY into that state, by both things that produce it:
    /// a deliberate pause, and a burst open that failed after `connect()` and
    /// therefore put the radio back itself. It is a state, never a fault — a
    /// consumer must not stamp a "disconnected since" from it. The per-relay
    /// [`Self::Disconnected`] transitions a pause necessarily produces are
    /// suppressed while paused for the same reason: a burst interval can be as
    /// long as the receive-silence threshold, so a health model fed those
    /// transitions would confirm a relay outage on a deliberate pause. The
    /// `Reconnecting`/`Connected` churn each burst produces is harmless and
    /// expected.
    Paused,
}

/// An event emitted by the engine onto its internal broadcast bus.
///
/// The bus is consumed by the FFI `live_events` stream (M3c) and, internally,
/// by the settle/health machinery. `Debug` is presence-only.
#[derive(Clone, PartialEq, Eq)]
pub enum LiveSyncEvent {
    /// A decrypted location for a circle.
    Location {
        /// The circle's pseudonymous `nostr_group_id` (NOT the MLS group id).
        nostr_group_id: Vec<u8>,
        /// Sender's hex-encoded Nostr public key.
        sender_pubkey: String,
        /// Decrypted location content (JSON).
        content: String,
        /// The relay-public `created_at` of the source event (seconds).
        event_created_at_secs: i64,
    },
    /// A group membership / epoch update — the roster changed and the change is
    /// already applied locally. A UI-only signal: the consumer just refreshes; it
    /// owes NO publish/merge (since M6-2 the engine converges an auto-committed
    /// peer `SelfRemove` itself in-Rust and emits this with `None`).
    GroupUpdate {
        /// The circle's pseudonymous `nostr_group_id`.
        nostr_group_id: Vec<u8>,
        /// Always `None` from the engine path (an auto-commit is converged
        /// internally, not surfaced here). Retained as an `Option` only for the
        /// M3a unit fixtures + the legacy FFI mapping.
        evolution_event_json: Option<String>,
    },
    /// A raw gift-wrapped invitation (kind 1059). The engine never unwraps it;
    /// the consumer unwraps via `process_gift_wrapped_invitation`.
    ///
    /// # No wrapper timestamp
    ///
    /// The wrapper's `created_at` is deliberately NOT carried. Its only consumer
    /// was a sync-cursor advance, and it is an unauthenticated field on an event
    /// anyone who knows the recipient's (public) npub can mint — see
    /// [`super::anchor::InboxAnchor`]. The inbox cursor is advanced in-Rust from
    /// the inbox REQ's own local open time, redeemed on that REQ's `EOSE`.
    Welcome {
        /// The raw kind:1059 event JSON.
        gift_wrap_json: String,
    },
    /// A circle that cannot recover on its own and needs a re-invite.
    ///
    /// A TERMINAL verdict about ONE circle, and the only event on this bus that
    /// is. It means: this device holds group state no code path will move again,
    /// so waiting cannot help and neither can a retry — the circle has to be
    /// re-created. A consumer may therefore offer a destructive repair on it,
    /// which is exactly why nothing transient may ever be spelled this way.
    ///
    /// Two things produce it, and they are the same verdict from opposite ends:
    ///
    /// * the ENGINE reported the group `Unrecoverable` (`GroupUnrecoverable` →
    ///   [`crate::nostr::mls::types::LocationMessageResult::Unrecoverable`]);
    ///   its one legal exit has no caller at the pinned rev, so it never clears;
    /// * a DURABLE removal deferral outlived the session that staged it
    ///   ([`crate::circle::CircleManager::orphaned_removal_deferrals`]): a
    ///   departing peer's eviction commit is staged in the engine with its
    ///   `PendingStateRef` gone, which nothing can publish and hydrate will not
    ///   clear.
    ///
    /// # What it is NOT
    ///
    /// Not a relay outage ([`SyncStatusReason::RelayError`] /
    /// [`SyncStatusReason::Disconnected`]), not a pause
    /// ([`SyncStatusReason::Paused`]), not a message that could not be applied
    /// ([`SyncStatusReason::Unprocessable`]), and above all not a future-epoch
    /// backlog: convergence drains that on its own, and Rule 12 forbids
    /// treating legitimate offline backlog as a fault. Each of those clears by
    /// itself; this one does not, and telling a user to re-create a working
    /// circle is worse than telling them nothing.
    ///
    /// Repeats, and a consumer must treat it as idempotent per circle rather than
    /// counting it: the engine-reported source emits once per inbound event that
    /// carries the verdict, and the deferral source re-emits on every FOREGROUND
    /// re-anchor that still finds the state — so a consumer that missed the first
    /// one is not left blind. There is no paired clearing event: the state's only
    /// exit is the circle being re-created or left, and both remove the circle
    /// this names.
    GroupUnrecoverable {
        /// The circle's pseudonymous `nostr_group_id` (NOT the MLS group id).
        nostr_group_id: Vec<u8>,
    },
    /// A non-content status / lifecycle signal.
    Status {
        /// The closed status reason.
        reason: SyncStatusReason,
    },
}

impl std::fmt::Debug for LiveSyncEvent {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Location {
                event_created_at_secs,
                ..
            } => f
                .debug_struct("Location")
                .field("nostr_group_id", &"<redacted>")
                .field("sender_pubkey", &"<redacted>")
                .field("content", &"<redacted>")
                .field("event_created_at_secs", event_created_at_secs)
                .finish(),
            Self::GroupUpdate {
                evolution_event_json,
                ..
            } => f
                .debug_struct("GroupUpdate")
                .field("nostr_group_id", &"<redacted>")
                .field("has_evolution_event", &evolution_event_json.is_some())
                .finish(),
            Self::Welcome { .. } => f
                .debug_struct("Welcome")
                .field("gift_wrap_json", &"<redacted>")
                .finish(),
            Self::GroupUnrecoverable { .. } => f
                .debug_struct("GroupUnrecoverable")
                .field("nostr_group_id", &"<redacted>")
                .finish(),
            Self::Status { reason } => f.debug_struct("Status").field("reason", reason).finish(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // Sentinels that MUST NOT appear in any Debug output (Security Rule 8).
    const SECRET_CONTENT: &str = "SECRET_COORDS_48.0N_11.0E";
    const SENDER_PK: &str = "deadbeefcafef00d";
    const EVOLUTION_JSON: &str = "SECRET_EVOLUTION_COMMIT_JSON";
    const GIFTWRAP_JSON: &str = "SECRET_GIFTWRAP_JSON";

    #[test]
    fn live_sync_event_debug_is_presence_only_for_every_variant() {
        let group_id = vec![0xAB, 0xCD, 0xEF];

        let location = LiveSyncEvent::Location {
            nostr_group_id: group_id.clone(),
            sender_pubkey: SENDER_PK.to_string(),
            content: SECRET_CONTENT.to_string(),
            event_created_at_secs: 1234,
        };
        let group_update = LiveSyncEvent::GroupUpdate {
            nostr_group_id: group_id.clone(),
            evolution_event_json: Some(EVOLUTION_JSON.to_string()),
        };
        let unrecoverable = LiveSyncEvent::GroupUnrecoverable {
            nostr_group_id: group_id,
        };
        let welcome = LiveSyncEvent::Welcome {
            gift_wrap_json: GIFTWRAP_JSON.to_string(),
        };
        let status = LiveSyncEvent::Status {
            reason: SyncStatusReason::Connected,
        };

        for ev in [&location, &group_update, &welcome, &status, &unrecoverable] {
            let dbg = format!("{ev:?}");
            assert!(!dbg.contains(SECRET_CONTENT), "leaked content: {dbg}");
            assert!(!dbg.contains(SENDER_PK), "leaked sender pubkey: {dbg}");
            assert!(
                !dbg.contains(EVOLUTION_JSON),
                "leaked evolution json: {dbg}"
            );
            assert!(!dbg.contains(GIFTWRAP_JSON), "leaked gift-wrap json: {dbg}");
            assert!(!dbg.contains("abcdef"), "leaked group id bytes: {dbg}");
            assert!(!dbg.contains("ABCDEF"), "leaked group id bytes: {dbg}");
        }

        // Relay-public timestamps + the closed status enum may render.
        assert!(format!("{location:?}").contains("1234"));
        assert!(format!("{group_update:?}").contains("has_evolution_event: true"));
        assert!(format!("{status:?}").contains("Connected"));
    }
}
