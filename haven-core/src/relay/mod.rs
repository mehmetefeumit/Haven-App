//! Relay management with mandatory Tor routing.
//!
//! This module provides relay connectivity for Haven, ensuring all
//! Nostr relay communication is routed through the embedded Tor
//! network for privacy protection.
//!
//! # Security Model
//!
//! Haven uses a privacy-first approach to relay communication:
//!
//! - **Mandatory Tor**: All connections go through embedded Tor
//! - **Fail-closed**: No fallback to direct connections
//! - **Circuit isolation**: Different operations use separate circuits
//! - **WSS only**: Plaintext ws:// connections are rejected
//!
//! # Architecture
//!
//! ```text
//! Haven App
//!     │
//!     ▼
//! RelayManager
//!     │
//!     ▼
//! nostr-sdk Client (embedded Tor)
//!     │
//!     ▼
//! Tor Network
//!     │
//!     ▼
//! Nostr Relays
//! ```
//!
//! # Circuit Isolation
//!
//! To prevent correlation attacks at the relay level, different
//! operation types use separate Tor circuits:
//!
//! | Operation | Circuit |
//! |-----------|---------|
//! | `KeyPackage` (kind 443) | Identity circuit |
//! | Relay list (kind 10051) | Identity circuit |
//! | Group messages (kind 445) | Per-group circuit |
//!
//! This ensures that even if a relay operator correlates traffic,
//! they cannot determine which groups a user participates in.

mod error;
mod manager;
mod types;

pub use error::{RelayError, RelayResult};
pub use manager::RelayManager;
pub use types::{CircuitPurpose, PublishResult, RelayConnectionStatus, RelayStatus, TorStatus};
