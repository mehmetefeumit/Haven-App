//! Circle management for location sharing.
//!
//! This module provides the core functionality for managing "circles" -
//! groups of people who share locations with each other. It builds on
//! the MLS protocol (via MDK) for secure group messaging.
//!
//! # Architecture
//!
//! ```text
//! CircleManager (high-level API)
//!     ├── MdkManager (MLS operations)
//!     └── CircleStorage (SQLite for app metadata)
//! ```
//!
//! # Privacy Model
//!
//! Haven uses a privacy-first approach:
//! - **No public profiles**: User profiles (kind 0) are never published to relays
//! - **Local contacts**: Display names and avatars are stored only on the device
//! - **Pubkey-only identity**: Relays only see pubkeys, never usernames
//!
//! This prevents relay-level correlation of usernames with invitation patterns.
//!
//! # Types
//!
//! - [`Circle`]: A group of people sharing locations
//! - [`Contact`]: Locally-stored profile for a pubkey
//! - [`CircleMember`]: A member with resolved contact info
//! - [`Invitation`]: A pending invitation to join a circle

pub mod contamination;
mod error;
mod leave;
pub(crate) mod location_pool;
mod manager;
pub mod profile_sync;
pub mod relay_prefs;
pub mod rotation;
mod storage;
mod storage_commit_notes;
mod storage_contamination;
mod storage_kept_input;
mod storage_key_packages;
mod storage_member_directory;
mod storage_mesh;
mod storage_profile;
mod storage_profile_sync;
mod storage_refused;
mod storage_relay_floor;
pub(crate) mod storage_relay_prefs;
pub mod types;

pub use contamination::ContaminationSource;
pub use error::{CircleError, RelayInputRejection, Result};
pub use leave::LeavePlan;
pub use location_pool::{
    production_location_relays, set_location_relays_for_test, PRODUCTION_LOCATION_RELAYS,
    RELAYS_PER_NEW_CIRCLE,
};
pub(crate) use manager::redact_storage_error;
pub(crate) use manager::{
    key_packages_of, welcome_routes_of, FanoutResolution, LeaveStep, StagedSeal,
};
pub use manager::{
    CircleCreationResult, CircleManager, DecryptedIngest, DirectoryReconcile, StagedChange,
    StagedPostJoin, StagedRepair,
};
pub use manager::{CIRCLES_DB_FILENAME, CONSUMED_KEY_PACKAGE_HOLD_SECS};
pub use profile_sync::{ProfileSyncOutcome, ProfileSyncReport};
pub use relay_prefs::RelayType;
pub use rotation::{RotationDecision, RotationInputs, SkipReason};
pub use storage::{CircleHealth, CircleRotationState, CircleStorage};
pub use storage_key_packages::KEY_PACKAGE_KIND;
pub use storage_member_directory::{
    DirectoryEntry, DirectoryTier, DIRECTORY_PURGE_NEVER, DIRECTORY_RETENTION_DAYS,
    DIRECTORY_RETENTION_SECS,
};
pub use storage_mesh::MeshCounts;
pub use storage_profile::{CachedProfileView, PROFILE_MISS_BACKOFF_SECS};
pub use storage_profile_sync::{ProfilePendingState, ProfileSyncCommit};
pub use storage_relay_prefs::{PublishedEventRecord, UserRelayRow};
pub use types::{
    default_relays, sanitize_circle_name, set_default_relays_for_test, Circle, CircleConfig,
    CircleEngineState, CircleMember, CircleMembership, CircleType, CircleUiState,
    CircleWithMembers, Contact, GiftWrappedWelcome, Invitation, LastKnownLocation,
    MemberKeyPackage, MembershipStatus, PRODUCTION_DEFAULT_RELAYS,
};
