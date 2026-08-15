//! Nostr event construction for encrypted location sharing.
//!
//! This module provides functionality for creating MLS-encrypted Nostr events
//! following the Marmot protocol (kind 445 group messages).
//!
//! # Architecture
//!
//! ```text
//! LocationMessage → UnsignedEvent (inner kind-9 rumor with location JSON)
//!                          ↓
//!            SessionManager::send_location (engine: MLS + signing)
//!                          ↓
//!                   Event (kind 445, ready for relay)
//! ```
//!
//! The single send path is [`CircleManager::encrypt_location`] →
//! [`mls::SessionManager::send_location`]: it stamps the inner `pubkey` with
//! the session's own identity (W9) rather than accepting one from the caller,
//! and the engine mints the ephemeral key for each kind 445 (Security Rule 2).
//! A second builder that took a caller-supplied sender pubkey once lived in
//! `location::nostr`; it reached no caller and was deleted rather than
//! documented, because a parallel encrypt path is a trap even while unused.
//!
//! # Security
//!
//! - The engine handles MLS encryption and epoch management
//! - Forward secrecy bounded by MLS epoch rotation — and Haven rotates only on
//!   MEMBERSHIP CHANGE, never periodically, so a quiescent circle sits in one
//!   epoch indefinitely. Stated as a bound rather than a property because
//!   `SECURITY.md` records that as an accepted deviation, and the unqualified
//!   claim is the one the UI copy is forbidden to make.
//! - Ephemeral keypairs ensure no correlation between events
//! - NIP-40 expiration enables automatic relay cleanup
//!
//! [`CircleManager::encrypt_location`]: crate::circle::CircleManager::encrypt_location

mod error;
mod event;
mod keys;
mod tags;

pub mod encryption;
pub mod giftwrap;
pub mod identity;
pub mod mls;

pub use error::{NostrError, Result};
pub use event::{
    SignedLocationEvent, UnsignedLocationEvent, KIND_GROUP_MESSAGE, KIND_LOCATION_DATA,
};
pub use identity::{
    IdentityError, IdentityKeypair, IdentityManager, PublicIdentity, SecureKeyStorage,
};
pub use keys::EphemeralKeypair;
pub use mls::MlsGroupContext;
pub use tags::TagBuilder;
