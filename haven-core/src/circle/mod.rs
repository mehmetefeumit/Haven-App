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

mod error;
mod leave;
mod manager;
pub mod relay_prefs;
mod storage;
mod storage_relay_prefs;
pub mod types;

pub use error::{CircleError, Result};
pub use leave::LeavePlan;
pub use manager::{AddMembersResult, CircleCreationResult, CircleManager};
pub use relay_prefs::RelayType;
pub use storage::CircleStorage;
pub use storage_relay_prefs::{PublishedEventRecord, UserRelayRow};
pub use types::{
    default_relays, set_default_relays_for_test, Circle, CircleConfig, CircleMember,
    CircleMembership, CircleType, CircleUiState, CircleWithMembers, Contact, GiftWrappedWelcome,
    Invitation, LastKnownLocation, MemberKeyPackage, MembershipStatus, PRODUCTION_DEFAULT_RELAYS,
};
