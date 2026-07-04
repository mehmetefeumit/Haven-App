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

use crate::nostr::mls::types::GroupId;

/// A non-content lifecycle / status signal emitted by the engine.
///
/// Mirrors the FFI `FfiSyncStatusReason` (M3c); kept as a closed enum so a raw
/// error string never reaches the UI (Security Rule 8).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SyncStatusReason {
    /// The engine is establishing relay connections.
    Connecting,
    /// All required relays are connected.
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
    Welcome {
        /// The raw kind:1059 event JSON.
        gift_wrap_json: String,
        /// The wrapper's relay-public `created_at` (seconds).
        wrap_created_at_secs: i64,
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
            Self::Welcome {
                wrap_created_at_secs,
                ..
            } => f
                .debug_struct("Welcome")
                .field("gift_wrap_json", &"<redacted>")
                .field("wrap_created_at_secs", wrap_created_at_secs)
                .finish(),
            Self::Status { reason } => f.debug_struct("Status").field("reason", reason).finish(),
        }
    }
}

/// The neutral outcome of attempting to process one incoming relay event.
///
/// Produced by the real decrypt path (M3b) and by unit-test fixtures (M3a), and
/// consumed by [`super::plan::plan_outcome`]. Distinguishing
/// [`Self::CompetingCommit`] from [`Self::OtherError`] is the load-bearing
/// fork-safety signal: a same-epoch sibling commit racing our own pending
/// commit surfaces from MDK as an *error*, not a `GroupUpdate`, and must be
/// buffered for convergence rather than dropped.
#[derive(Clone, PartialEq, Eq)]
pub enum EngineDecryptOutcome {
    /// A decrypted location message.
    Location {
        /// The circle's pseudonymous `nostr_group_id`.
        nostr_group_id: Vec<u8>,
        /// Sender's hex-encoded Nostr public key.
        sender_pubkey: String,
        /// Decrypted location content (JSON).
        content: String,
        /// Source event `created_at` (seconds).
        created_at_secs: i64,
    },
    /// A group update that is ALREADY applied (no pending commit) — e.g. we
    /// processed a peer's merged commit; the roster changed. `evolution_event_json`
    /// is always `None` for the engine path (an auto-commit is surfaced as
    /// [`Self::AutoCommit`] instead); the `Option` is retained for the M3a unit
    /// fixtures and the legacy mapping.
    GroupUpdate {
        /// The circle's pseudonymous `nostr_group_id`.
        nostr_group_id: Vec<u8>,
        /// Outbound commit the consumer must publish+merge, or `None`.
        evolution_event_json: Option<String>,
    },
    /// An auto-committed peer `SelfRemove`: MDK staged a pending commit that the
    /// ENGINE (not the FFI consumer) must publish + converge in-Rust (path B,
    /// M6-2). The real `mls_group_id` is carried for `converge_commit` and NEVER
    /// crosses the FFI boundary — it stays in haven-core; the hand-written `Debug`
    /// redacts it and the commit JSON (Security Rule 4/8).
    AutoCommit {
        /// The circle's pseudonymous `nostr_group_id` (gate/settle key + UI).
        nostr_group_id: Vec<u8>,
        /// The real MLS group id (in-crate only) for `converge_commit`.
        mls_group_id: GroupId,
        /// The staged auto-commit `kind:445` JSON to publish + converge.
        commit_json: String,
    },
    /// The message could not be processed (stale, undecryptable, dropped).
    Unprocessable,
    /// The message was previously attempted and failed (MDK retry gate).
    PreviouslyFailed,
    /// A same-epoch sibling commit racing our pending commit (MDK
    /// `OwnCommitPending` / `WrongEpoch`-commit / `CannotDecryptOwnMessage`).
    /// Buffer-eligible for convergence; never advances the cursor.
    CompetingCommit,
    /// Any other failure: a plain drop. Never buffered, never advances.
    OtherError,
}

impl std::fmt::Debug for EngineDecryptOutcome {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Location {
                created_at_secs, ..
            } => f
                .debug_struct("Location")
                .field("created_at_secs", created_at_secs)
                .finish_non_exhaustive(),
            Self::GroupUpdate {
                evolution_event_json,
                ..
            } => f
                .debug_struct("GroupUpdate")
                .field("has_evolution_event", &evolution_event_json.is_some())
                .finish_non_exhaustive(),
            // Presence-only: never render the MLS group id or the commit JSON.
            Self::AutoCommit { .. } => write!(f, "AutoCommit"),
            Self::Unprocessable => write!(f, "Unprocessable"),
            Self::PreviouslyFailed => write!(f, "PreviouslyFailed"),
            Self::CompetingCommit => write!(f, "CompetingCommit"),
            Self::OtherError => write!(f, "OtherError"),
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
            nostr_group_id: group_id,
            evolution_event_json: Some(EVOLUTION_JSON.to_string()),
        };
        let welcome = LiveSyncEvent::Welcome {
            gift_wrap_json: GIFTWRAP_JSON.to_string(),
            wrap_created_at_secs: 5678,
        };
        let status = LiveSyncEvent::Status {
            reason: SyncStatusReason::Connected,
        };

        for ev in [&location, &group_update, &welcome, &status] {
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
        assert!(format!("{welcome:?}").contains("5678"));
        assert!(format!("{group_update:?}").contains("has_evolution_event: true"));
        assert!(format!("{status:?}").contains("Connected"));
    }

    #[test]
    fn engine_decrypt_outcome_debug_is_presence_only() {
        let location = EngineDecryptOutcome::Location {
            nostr_group_id: vec![0xAB, 0xCD],
            sender_pubkey: SENDER_PK.to_string(),
            content: SECRET_CONTENT.to_string(),
            created_at_secs: 99,
        };
        let dbg = format!("{location:?}");
        assert!(!dbg.contains(SECRET_CONTENT));
        assert!(!dbg.contains(SENDER_PK));
        assert!(!dbg.contains("abcd"));
        assert!(
            dbg.contains("99"),
            "relay-public created_at may render: {dbg}"
        );

        let pending = EngineDecryptOutcome::GroupUpdate {
            nostr_group_id: vec![1],
            evolution_event_json: Some(EVOLUTION_JSON.to_string()),
        };
        let dbg = format!("{pending:?}");
        assert!(!dbg.contains(EVOLUTION_JSON));
        assert!(dbg.contains("has_evolution_event: true"));

        // AutoCommit is the only engine variant carrying the real MLS group id
        // AND commit JSON — both MUST be redacted (Security Rule 4/8). It
        // renders as a bare name so a future `debug_struct().field(...)`
        // refactor that leaked either can never slip through this test.
        let auto = EngineDecryptOutcome::AutoCommit {
            nostr_group_id: vec![1, 2, 3],
            mls_group_id: GroupId::from_slice(&[0xDE, 0xAD, 0xBE, 0xEF]),
            commit_json: SECRET_CONTENT.to_string(),
        };
        let dbg = format!("{auto:?}");
        assert_eq!(dbg, "AutoCommit", "AutoCommit must be presence-only");
        assert!(!dbg.contains("deadbeef"), "leaked mls group id: {dbg}");
        assert!(!dbg.contains(SECRET_CONTENT), "leaked commit json: {dbg}");

        // Unit-ish variants render as bare names, no payload.
        assert_eq!(
            format!("{:?}", EngineDecryptOutcome::CompetingCommit),
            "CompetingCommit"
        );
        assert_eq!(
            format!("{:?}", EngineDecryptOutcome::Unprocessable),
            "Unprocessable"
        );
        assert_eq!(
            format!("{:?}", EngineDecryptOutcome::PreviouslyFailed),
            "PreviouslyFailed"
        );
        assert_eq!(
            format!("{:?}", EngineDecryptOutcome::OtherError),
            "OtherError"
        );
    }
}
