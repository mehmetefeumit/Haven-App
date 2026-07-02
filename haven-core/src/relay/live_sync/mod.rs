//! The persistent live-sync engine (M3).
//!
//! Replaces Haven's short-poll receive model with one standing connection that
//! streams circle messages (`kind:445`) and invitations (`kind:1059`) as they
//! arrive, advancing a persisted cursor on success and buffering same-epoch
//! sibling commits for deterministic MIP-03 convergence.
//!
//! # Sub-milestones
//!
//! This module is built in layers so each is independently testable:
//!
//! - **M3a (this commit): the pure core.** [`config`] tuning constants,
//!   [`error`] redaction-safe errors, [`event`] the engine's data types,
//!   [`event_bus`] the fan-out bus, [`planes`] the filter/sub-id builders,
//!   [`router`] event routing, [`settle`] the competing-commit buffer, and
//!   [`plan`] the pure cursor-gating decision table. No `Client`, no statics, no
//!   FFI — every piece is unit-tested against in-memory fixtures.
//! - **M3b: the live session** — the engine `Client`, the raw notifications
//!   supervisor, the `Monitor` reconnect task, the serialized MLS write gate,
//!   and lifecycle, exercised against an in-process loopback relay.
//! - **M3c: the FFI surface** — `LiveSyncFfi` and the `StreamSink` of relay
//!   events that M6 consumes.
//!
//! # Privacy invariants
//!
//! Only `hex(nostr_group_id)` ever reaches a filter, sub-id, or log — the real
//! MLS group id never leaves haven-core (Security Rule 4). Sub-ids are derived
//! from a per-session ephemeral salt (PSI-2), the settle buffer holds only
//! relay-public commit JSON (Security Rule 5), and every error/event `Debug` is
//! presence-only (Security Rule 8).

pub mod autocommit;
pub mod config;
pub mod error;
pub mod event;
pub mod event_bus;
pub mod finalize;
pub mod gate;
pub mod plan;
pub mod planes;
pub mod processor;
pub mod router;
pub mod session;
pub mod settle;
pub mod supervisor;

pub use autocommit::{run_autocommit_converge, AutoCommitWork, EngineHandles};
pub use config::COMMIT_SETTLE_WINDOW_SECS;
pub use error::{LiveSyncError, LiveSyncResult};
pub use event::{EngineDecryptOutcome, LiveSyncEvent, SyncStatusReason};
pub use event_bus::{classify_recv, EventBus, RecvDisposition};
pub use finalize::{StagedAdd, StagedCommit};
pub use gate::{generate_session_salt, MlsWriteGate};
pub use plan::{plan_outcome, ProcessorPlan};
pub use planes::{
    build_relay_set_subscriptions, derive_sub_id, CircleSpec, GroupSubscription, InboxSubscription,
    PlaneKind,
};
pub use processor::{group_cursor_stream, EngineProcessor, GroupProcessOutcome};
pub use router::{Router, SubCtx};
pub use session::LiveSyncCore;
pub use settle::{BufferedCommit, CommitSettleBuffer};
