//! Nostr integration for location sharing.
//!
//! This module handles preparing location data for Nostr relays using the
//! Marmot "Dark Matter" MLS engine:
//! - Marmot event kind 445 (Group Message)
//! - The engine (via [`MlsGroupContext`]) for MLS encryption and group
//!   management
//! - Group-level NIP-40 retention (`message-retention.v1`), not per-send TTL
//!
//! # Architecture
//!
//! ```text
//! LocationMessage → UnsignedEvent (rumor with location JSON)
//!                          ↓
//!                   MlsGroupContext::encrypt_event (async → SessionEffects)
//!                          ↓
//!                   PublishWork::ApplicationMessage (published by relay layer)
//! ```
//!
//! # Privacy Features
//!
//! - Location is encrypted using MLS (via the engine)
//! - The engine handles ephemeral keypairs and signing
//! - Forward secrecy through MLS epoch rotation
//!
//! Since the Dark Matter engine's mutating calls are `async`, the encrypt and
//! decrypt helpers here are `async` (M6 send/receive convergence).

use nostr::prelude::{Event, EventBuilder, Kind, PublicKey, Tag};

use super::types::LocationMessage;
use crate::nostr::mls::types::LocationMessageResult;
use crate::nostr::mls::SessionManager;
use crate::nostr::{MlsGroupContext, NostrError, Result};
use cgka_session::SessionEffects;

/// Event kind for application messages (inner event).
///
/// Kind 9 is used per MIP-03 for application content inside MLS group messages.
/// A `["t", "location"]` tag distinguishes location messages from chat messages.
const KIND_LOCATION_DATA: u16 = 9;

/// Builder for creating encrypted Nostr location events using MDK.
///
/// This struct is responsible for constructing Nostr events that contain
/// encrypted location data. It uses MDK for MLS encryption and signing.
///
/// # Examples
///
/// ```
/// use haven_core::location::nostr::LocationEventBuilder;
///
/// let builder = LocationEventBuilder::new();
/// ```
#[derive(Debug, Clone, Default)]
pub struct LocationEventBuilder {
    // Reserved for future configuration options
    _private: (),
}

impl LocationEventBuilder {
    /// Creates a new `LocationEventBuilder`.
    ///
    /// # Examples
    ///
    /// ```
    /// use haven_core::location::nostr::LocationEventBuilder;
    ///
    /// let builder = LocationEventBuilder::new();
    /// ```
    #[must_use]
    pub const fn new() -> Self {
        Self { _private: () }
    }

    /// Encrypts a location message via the engine and returns the publishable
    /// [`SessionEffects`].
    ///
    /// This method performs the send flow:
    /// 1. Serializes the location data to JSON
    /// 2. Creates an unsigned inner event (rumor) with the location content
    ///    (Marmot app event, kind 9, `["t","location"]` tag; `pubkey` MUST be
    ///    the sender's identity per W9)
    /// 3. Delegates to the engine, which encrypts the MLS group message and
    ///    returns a [`PublishWork::ApplicationMessage`] for Haven's relay layer
    ///    to publish
    ///
    /// The engine owns MLS encryption, ephemeral-key generation, and the kind
    /// 445 outer event. Because those calls are `async`, this method is `async`.
    ///
    /// # Arguments
    ///
    /// * `location` - The location message to encrypt
    /// * `group` - The MLS group context for encryption
    /// * `sender_pubkey` - The sender's Nostr public key (the inner rumor
    ///   `pubkey`; MUST equal the session's local identity)
    ///
    /// # Returns
    ///
    /// [`SessionEffects`] carrying the `ApplicationMessage` transport work.
    ///
    /// # Errors
    ///
    /// Returns an error if serialization fails, the inner `pubkey` is not the
    /// local identity (W9), or the engine rejects the send.
    ///
    /// [`PublishWork::ApplicationMessage`]: cgka_session::PublishWork::ApplicationMessage
    pub async fn encrypt(
        &self,
        location: &LocationMessage,
        group: &MlsGroupContext,
        sender_pubkey: &PublicKey,
    ) -> Result<SessionEffects> {
        // Step 1: Serialize location to string
        let content = location.to_string()?;

        // Step 2: Create unsigned event (rumor) with location data
        // Tag ["t", "location"] distinguishes location messages from chat per MIP-03
        let location_tag = Tag::parse(["t", "location"])
            .map_err(|e| NostrError::InvalidEvent(format!("Failed to create location tag: {e}")))?;
        let rumor = EventBuilder::new(Kind::Custom(KIND_LOCATION_DATA), content)
            .tag(location_tag)
            .build(*sender_pubkey);

        // Step 3: Delegate to the engine for encryption + transport framing.
        group.encrypt_event(rumor).await
    }

    /// Decrypts / ingests a received location event via the engine.
    ///
    /// This method performs the receive flow:
    /// 1. Delegates to the engine, which peels + ingests the transport message,
    ///    validates the MLS-authenticated sender, and advances group state
    /// 2. Drains the emitted [`GroupEvent`] stream for the first application
    ///    message ([`LocationMessageResult::Location`])
    /// 3. Deserializes and returns the location message
    ///
    /// The engine owns signature verification, MLS decryption, epoch validation,
    /// and out-of-order sequencing. Because those calls are `async`, this method
    /// is `async`.
    ///
    /// # Arguments
    ///
    /// * `event` - The received encrypted event to decrypt
    /// * `group` - The MLS group context for decryption
    ///
    /// # Returns
    ///
    /// The decrypted location message.
    ///
    /// # Errors
    ///
    /// Returns an error if ingest fails hard, or if the event did not yield an
    /// application message (e.g. it was a commit/proposal, was stale, or was
    /// buffered for a future epoch), or if deserialization fails.
    ///
    /// [`GroupEvent`]: cgka_traits::engine::GroupEvent
    pub async fn decrypt(&self, event: &Event, group: &MlsGroupContext) -> Result<LocationMessage> {
        // Step 1: Delegate to the engine for peel + ingest.
        let ingest = group.decrypt_event(event).await?;

        // Step 2: Fold the emitted GroupEvents; the first location application
        // message carries the inner content. Commits/proposals/state changes
        // emit no `Location`, and stale/buffered outcomes emit no event at all.
        for group_event in &ingest.effects.events {
            if let Some(LocationMessageResult::Location { content, .. }) =
                SessionManager::location_result_from_event(group_event)
            {
                // Step 3: Deserialize location
                return LocationMessage::from_string(&content).map_err(NostrError::from);
            }
        }

        Err(NostrError::Decryption(
            "no application message in ingest result".to_string(),
        ))
    }

    /// Prepares location data for publishing to Nostr.
    ///
    /// This method serializes the location to JSON. For full encryption,
    /// use the `encrypt` method instead.
    ///
    /// # Arguments
    ///
    /// * `location` - The location message to prepare
    ///
    /// # Returns
    ///
    /// JSON string representation of the location.
    ///
    /// # Errors
    ///
    /// Returns an error if JSON serialization fails.
    ///
    /// # Examples
    ///
    /// ```
    /// use haven_core::location::{LocationMessage, nostr::LocationEventBuilder};
    ///
    /// let location = LocationMessage::new(37.7749, -122.4194);
    /// let builder = LocationEventBuilder::new();
    ///
    /// let json = builder.prepare_location_data(&location).unwrap();
    /// assert!(json.contains("latitude"));
    /// ```
    pub fn prepare_location_data(&self, location: &LocationMessage) -> Result<String> {
        location.to_string().map_err(NostrError::from)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn event_builder_new() {
        let _builder = LocationEventBuilder::new();
        // Builder should be created successfully - zero-sized type is valid
    }

    #[test]
    fn event_builder_default() {
        let _builder = LocationEventBuilder::default();
        // Default builder should be created successfully - zero-sized type is valid
    }

    #[test]
    fn prepare_location_data_success() {
        let location = LocationMessage::new(37.7749, -122.4194);
        let builder = LocationEventBuilder::new();

        let json = builder.prepare_location_data(&location).unwrap();

        assert!(json.contains("latitude"));
        assert!(json.contains("longitude"));
        assert!(json.contains("geohash"));
        assert!(json.contains("timestamp"));
    }

    #[test]
    fn prepare_location_data_excludes_private_fields() {
        let mut location = LocationMessage::new(37.7749, -122.4194);
        location.device_id = Some("secret".to_string());
        location.altitude = Some(100.0);

        let builder = LocationEventBuilder::new();
        let json = builder.prepare_location_data(&location).unwrap();

        // Verify private fields are NOT in the prepared data
        assert!(!json.contains("device_id"));
        assert!(!json.contains("secret"));
        assert!(!json.contains("altitude"));
    }

    // Note: Full encryption/decryption tests require MDK infrastructure
    // and are covered in the integration tests (tests/mls_integration_tests.rs)
    // These unit tests verify the builder construction and data preparation.
}
