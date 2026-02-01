//! Nostr event construction for encrypted location sharing.
//!
//! This module provides functionality for creating MLS-encrypted Nostr events
//! following the Marmot protocol (kind 445 group messages).
//!
//! # Architecture
//!
//! ```text
//! LocationMessage → UnsignedEvent (rumor with location JSON)
//!                          ↓
//!                   MDK encrypt_event (MLS + signing)
//!                          ↓
//!                   Event (kind 445, ready for relay)
//! ```
//!
//! # Security
//!
//! - MDK handles MLS encryption and epoch management
//! - Forward secrecy through MLS epoch rotation
//! - Ephemeral keypairs ensure no correlation between events
//! - NIP-40 expiration enables automatic relay cleanup
//!
//! # Example
//!
//! ```ignore
//! use std::sync::Arc;
//! use std::path::Path;
//! use haven_core::location::LocationMessage;
//! use haven_core::location::nostr::LocationEventBuilder;
//! use haven_core::nostr::mls::{MdkManager, MlsGroupContext};
//! use haven_core::nostr::mls::types::GroupId;
//! use nostr::PublicKey;
//!
//! // Set up MDK storage
//! let manager = Arc::new(MdkManager::new(Path::new("/tmp/mdk")).unwrap());
//! let group_id = GroupId::from_slice(&[1, 2, 3]);
//! let group = MlsGroupContext::new(manager, group_id, "nostr-group-id");
//!
//! let location = LocationMessage::new(37.7749, -122.4194);
//! let builder = LocationEventBuilder::new();
//! let my_pubkey = PublicKey::from_hex("...").unwrap();
//!
//! // Encrypt using MDK
//! let event = builder.encrypt(&location, &group, &my_pubkey).unwrap();
//! ```

mod error;
mod event;
mod keys;
mod tags;

pub mod encryption;
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
