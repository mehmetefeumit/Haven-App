//! Nostr integration for location sharing.
//!
//! This module handles publishing location data to Nostr relays using:
//! - Marmot event kind 445 (Group Message)
//! - MDK for MLS encryption and group management
//! - Automatic expiration handling via MDK
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
//! # Privacy Features
//!
//! - Location is encrypted using MLS (via MDK)
//! - MDK handles ephemeral keypairs and signing
//! - Forward secrecy through MLS epoch rotation
//!
//! # Example
//!
//! ```ignore
//! use std::sync::Arc;
//! use std::path::Path;
//! use haven_core::location::{LocationMessage, nostr::LocationEventBuilder};
//! use haven_core::nostr::mls::{MdkManager, MlsGroupContext};
//! use haven_core::nostr::mls::types::GroupId;
//!
//! let manager = Arc::new(MdkManager::new(Path::new("/tmp/data")).unwrap());
//! let group_id = GroupId::from_slice(&[1, 2, 3]);
//! let group = MlsGroupContext::new(manager, group_id, "nostr-group-id");
//!
//! let location = LocationMessage::new(37.7749, -122.4194);
//! let builder = LocationEventBuilder::new();
//!
//! // Encrypt using MDK
//! let event = builder.encrypt(&location, &group).unwrap();
//!
//! // Later, decrypt received event
//! let decrypted = builder.decrypt(&event, &group).unwrap();
//! ```

use mdk_core::prelude::MessageProcessingResult;
use nostr::prelude::{Event, EventBuilder, Kind, PublicKey};

use super::types::LocationMessage;
use crate::nostr::{MlsGroupContext, NostrError, Result};

/// Event kind for application-specific data (inner event).
/// Kind 30078 is an addressable event per NIP-78.
const KIND_LOCATION_DATA: u16 = 30078;

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

    /// Encrypts a location message using MDK and creates a signed Nostr event.
    ///
    /// This method performs the full encryption flow:
    /// 1. Serializes the location data to JSON
    /// 2. Creates an unsigned event (rumor) with the location content
    /// 3. Delegates to MDK for MLS encryption and signing
    ///
    /// MDK handles:
    /// - MLS encryption using the group's current epoch key
    /// - Event signing with the group's keypair
    /// - Creating a kind 445 outer event with proper tags
    ///
    /// # Arguments
    ///
    /// * `location` - The location message to encrypt
    /// * `group` - The MLS group context for encryption
    /// * `sender_pubkey` - The sender's Nostr public key (for the inner rumor event)
    ///
    /// # Returns
    ///
    /// A signed Nostr event (kind 445) ready for relay transmission.
    ///
    /// # Errors
    ///
    /// Returns an error if:
    /// - Serialization of the location fails
    /// - MDK encryption fails
    /// - The group is not found
    ///
    /// # Example
    ///
    /// ```ignore
    /// use std::sync::Arc;
    /// use std::path::Path;
    /// use haven_core::location::{LocationMessage, nostr::LocationEventBuilder};
    /// use haven_core::nostr::mls::{MdkManager, MlsGroupContext};
    /// use haven_core::nostr::mls::types::GroupId;
    /// use nostr::PublicKey;
    ///
    /// let manager = Arc::new(MdkManager::new(Path::new("/tmp/data")).unwrap());
    /// let group_id = GroupId::from_slice(&[1, 2, 3]);
    /// let group = MlsGroupContext::new(manager, group_id, "nostr-group-id");
    ///
    /// let location = LocationMessage::new(37.7749, -122.4194);
    /// let builder = LocationEventBuilder::new();
    /// let my_pubkey = PublicKey::from_hex("...").unwrap();
    ///
    /// let event = builder.encrypt(&location, &group, &my_pubkey).unwrap();
    /// ```
    pub fn encrypt(
        &self,
        location: &LocationMessage,
        group: &MlsGroupContext,
        sender_pubkey: &PublicKey,
    ) -> Result<Event> {
        // Step 1: Serialize location to string
        let content = location.to_string()?;

        // Step 2: Create unsigned event (rumor) with location data
        let rumor =
            EventBuilder::new(Kind::Custom(KIND_LOCATION_DATA), content).build(*sender_pubkey);

        // Step 3: Delegate to MDK for encryption
        group.encrypt_event(rumor)
    }

    /// Decrypts a received location event using MDK.
    ///
    /// This method performs the decryption flow:
    /// 1. Delegates to MDK for signature verification and decryption
    /// 2. Extracts the location content from the decrypted message
    /// 3. Deserializes and returns the location message
    ///
    /// MDK handles:
    /// - Signature verification
    /// - MLS decryption
    /// - Epoch validation and updates
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
    /// Returns an error if:
    /// - MDK decryption fails
    /// - The message is not an application message (e.g., it's a proposal or commit)
    /// - Deserialization fails
    ///
    /// # Example
    ///
    /// ```ignore
    /// use std::sync::Arc;
    /// use std::path::Path;
    /// use haven_core::location::{LocationMessage, nostr::LocationEventBuilder};
    /// use haven_core::nostr::mls::{MdkManager, MlsGroupContext};
    /// use haven_core::nostr::mls::types::GroupId;
    ///
    /// let manager = Arc::new(MdkManager::new(Path::new("/tmp/data")).unwrap());
    /// let group_id = GroupId::from_slice(&[1, 2, 3]);
    /// let group = MlsGroupContext::new(manager, group_id, "nostr-group-id");
    ///
    /// let builder = LocationEventBuilder::new();
    ///
    /// // Assuming `event` is a received kind 445 event
    /// // let decrypted = builder.decrypt(&event, &group).unwrap();
    /// ```
    pub fn decrypt(&self, event: &Event, group: &MlsGroupContext) -> Result<LocationMessage> {
        // Step 1: Delegate to MDK for decryption
        let result = group.decrypt_event(event)?;

        // Step 2: Extract content from application message
        let content = match result {
            MessageProcessingResult::ApplicationMessage(msg) => msg.content,
            MessageProcessingResult::Proposal(_) => {
                return Err(NostrError::InvalidEvent(
                    "Expected application message, got proposal".to_string(),
                ));
            }
            MessageProcessingResult::Commit { .. } => {
                return Err(NostrError::InvalidEvent(
                    "Expected application message, got commit".to_string(),
                ));
            }
            MessageProcessingResult::ExternalJoinProposal { .. } => {
                return Err(NostrError::InvalidEvent(
                    "Expected application message, got external join proposal".to_string(),
                ));
            }
            MessageProcessingResult::Unprocessable { .. } => {
                return Err(NostrError::Decryption(
                    "Message could not be processed".to_string(),
                ));
            }
            MessageProcessingResult::PendingProposal { .. } => {
                return Err(NostrError::InvalidEvent(
                    "Expected application message, got pending proposal".to_string(),
                ));
            }
            MessageProcessingResult::IgnoredProposal { .. } => {
                return Err(NostrError::InvalidEvent(
                    "Expected application message, got ignored proposal".to_string(),
                ));
            }
            MessageProcessingResult::PreviouslyFailed => {
                return Err(NostrError::Decryption(
                    "Message previously failed processing".to_string(),
                ));
            }
        };

        // Step 3: Deserialize location
        LocationMessage::from_string(&content).map_err(NostrError::from)
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

    #[test]
    fn prepare_location_data_with_precision() {
        use crate::location::LocationPrecision;

        let location =
            LocationMessage::with_precision(37.7749295, -122.4194155, LocationPrecision::Private);
        let builder = LocationEventBuilder::new();

        let json = builder.prepare_location_data(&location).unwrap();

        assert!(json.contains("latitude"));
        assert!(json.contains("longitude"));
        assert!(json.contains("precision"));
    }

    // Note: Full encryption/decryption tests require MDK infrastructure
    // and are covered in the integration tests (tests/mls_integration_tests.rs)
    // These unit tests verify the builder construction and data preparation.
}
