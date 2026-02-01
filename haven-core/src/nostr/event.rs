//! Nostr event types for location sharing.
//!
//! This module defines the event structures for encrypted location messages:
//! - `UnsignedLocationEvent`: Inner event (kind 30078) containing location data
//! - `SignedLocationEvent`: Outer event (kind 445) ready for relay transmission

use chrono::{DateTime, TimeZone, Utc};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use subtle::ConstantTimeEq;

use crate::location::LocationMessage;
use crate::nostr::error::{NostrError, Result};
use crate::nostr::keys::{EphemeralKeypair, SECP};
use crate::nostr::tags::TagBuilder;

/// Event kind for Marmot group messages (outer event).
pub const KIND_GROUP_MESSAGE: u16 = 445;

/// Event kind for application-specific data (inner event).
/// Kind 30078 is an addressable event per NIP-78.
pub const KIND_LOCATION_DATA: u16 = 30078;

/// Default identifier for Haven location events (d tag value).
#[allow(dead_code)]
pub const HAVEN_LOCATION_IDENTIFIER: &str = "haven.location";

/// An unsigned Nostr event containing location data.
///
/// This is the inner event that gets encrypted before being wrapped
/// in a kind 445 group message. It uses kind 30078 for application-specific
/// data.
///
/// # Note
///
/// Inner events are not signed because they are encrypted within the outer
/// event (kind 445), which itself is signed. The outer signature provides
/// authentication for the entire encrypted payload.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct UnsignedLocationEvent {
    /// Event kind (30078 for application-specific data)
    pub kind: u16,

    /// JSON-serialized location data
    pub content: String,

    /// Event tags (typically empty for inner events)
    pub tags: Vec<Vec<String>>,

    /// Unix timestamp when the event was created
    pub created_at: i64,
}

impl UnsignedLocationEvent {
    /// Creates a new unsigned location event from a `LocationMessage`.
    ///
    /// # Arguments
    ///
    /// * `location` - The location data to include
    ///
    /// # Errors
    ///
    /// Returns an error if the location cannot be serialized to JSON.
    ///
    /// # Example
    ///
    /// ```
    /// use haven_core::location::LocationMessage;
    /// use haven_core::nostr::UnsignedLocationEvent;
    ///
    /// let location = LocationMessage::new(37.7749, -122.4194);
    /// let event = UnsignedLocationEvent::from_location(&location).unwrap();
    /// assert_eq!(event.kind, 30078);
    /// ```
    pub fn from_location(location: &LocationMessage) -> Result<Self> {
        let content = location.to_string()?;
        Ok(Self {
            kind: KIND_LOCATION_DATA,
            content,
            tags: vec![],
            created_at: Utc::now().timestamp(),
        })
    }

    /// Extracts the `LocationMessage` from this event's content.
    ///
    /// # Errors
    ///
    /// Returns an error if the content is not valid location JSON.
    pub fn to_location(&self) -> Result<LocationMessage> {
        LocationMessage::from_string(&self.content).map_err(NostrError::from)
    }

    /// Serializes this event to JSON for encryption.
    ///
    /// # Errors
    ///
    /// Returns an error if serialization fails.
    pub fn to_json(&self) -> Result<String> {
        serde_json::to_string(self).map_err(NostrError::from)
    }

    /// Deserializes an unsigned event from JSON.
    ///
    /// # Errors
    ///
    /// Returns an error if the JSON is invalid.
    pub fn from_json(json: &str) -> Result<Self> {
        serde_json::from_str(json).map_err(NostrError::from)
    }
}

/// A signed Nostr event ready for relay transmission.
///
/// This is the outer event (kind 445) that contains encrypted location data.
/// It is signed with an ephemeral keypair to prevent correlation between events.
///
/// # Structure
///
/// ```json
/// {
///   "id": "...",           // SHA256 of serialized event
///   "pubkey": "...",       // Ephemeral public key
///   "created_at": 123456,  // Unix timestamp
///   "kind": 445,           // Marmot group message
///   "tags": [["h", "..."], ["expiration", "..."]],
///   "content": "...",      // NIP-44 encrypted content
///   "sig": "..."           // Schnorr signature
/// }
/// ```
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct SignedLocationEvent {
    /// Event ID (32-byte SHA256 hash, hex-encoded)
    pub id: String,

    /// Ephemeral public key (32 bytes, hex-encoded)
    pub pubkey: String,

    /// Unix timestamp when the event was created
    pub created_at: i64,

    /// Event kind (445 for Marmot group messages)
    pub kind: u16,

    /// Event tags: [["h", `group_id`], ["expiration", timestamp], ...]
    pub tags: Vec<Vec<String>>,

    /// NIP-44 encrypted content (base64-encoded)
    pub content: String,

    /// Schnorr signature (64 bytes, hex-encoded)
    pub sig: String,
}

impl SignedLocationEvent {
    /// Creates a new signed location event.
    ///
    /// This is the main construction method that:
    /// 1. Builds the event structure with provided encrypted content
    /// 2. Calculates the event ID
    /// 3. Signs the event with the ephemeral keypair
    ///
    /// # Arguments
    ///
    /// * `nostr_group_id` - The Nostr group identifier for the `h` tag
    /// * `encrypted_content` - The NIP-44 encrypted inner event
    /// * `expires_at` - When this event should expire (NIP-40)
    /// * `keypair` - Ephemeral keypair for signing
    /// * `geohash` - Optional geohash for relay filtering (already truncated to desired precision)
    ///
    /// # Errors
    ///
    /// Returns an error if signing fails.
    pub fn new(
        nostr_group_id: &str,
        encrypted_content: String,
        expires_at: DateTime<Utc>,
        keypair: &EphemeralKeypair,
        geohash: Option<&str>,
    ) -> Result<Self> {
        let pubkey = keypair.pubkey_hex();
        let created_at = Utc::now().timestamp();

        // Build tags
        let mut tags = vec![
            TagBuilder::h_tag(nostr_group_id),
            TagBuilder::expiration_tag(expires_at),
            TagBuilder::alt_tag("Encrypted family location update"),
        ];

        // Optionally add geohash tag for relay filtering
        if let Some(gh) = geohash {
            // Use the geohash as-is (caller is responsible for truncating)
            tags.push(vec!["g".to_string(), gh.to_string()]);
        }

        // Calculate event ID
        let id = Self::calculate_id(
            &pubkey,
            created_at,
            KIND_GROUP_MESSAGE,
            &tags,
            &encrypted_content,
        )?;

        // Sign the event
        let id_bytes: [u8; 32] = hex::decode(&id)
            .map_err(|e| NostrError::HexError(e.to_string()))?
            .try_into()
            .map_err(|_| NostrError::InvalidEvent("Invalid ID length".to_string()))?;
        let sig = keypair.sign(&id_bytes)?;

        Ok(Self {
            id,
            pubkey,
            created_at,
            kind: KIND_GROUP_MESSAGE,
            tags,
            content: encrypted_content,
            sig,
        })
    }

    /// Calculates the event ID per NIP-01.
    ///
    /// The ID is the SHA256 hash of the serialized event array:
    /// `[0, pubkey, created_at, kind, tags, content]`
    fn calculate_id(
        pubkey: &str,
        created_at: i64,
        kind: u16,
        tags: &[Vec<String>],
        content: &str,
    ) -> Result<String> {
        // Per NIP-01, serialize as: [0, pubkey, created_at, kind, tags, content]
        let serialized = serde_json::to_string(&(0, pubkey, created_at, kind, tags, content))
            .map_err(NostrError::from)?;

        let mut hasher = Sha256::new();
        hasher.update(serialized.as_bytes());
        let result = hasher.finalize();

        Ok(hex::encode(result))
    }

    /// Serializes this event to JSON for transmission.
    ///
    /// # Errors
    ///
    /// Returns an error if serialization fails.
    pub fn to_json(&self) -> Result<String> {
        serde_json::to_string(self).map_err(NostrError::from)
    }

    /// Deserializes a signed event from JSON.
    ///
    /// # Errors
    ///
    /// Returns an error if the JSON is invalid.
    pub fn from_json(json: &str) -> Result<Self> {
        serde_json::from_str(json).map_err(NostrError::from)
    }

    /// Extracts the Nostr group ID from the `h` tag.
    ///
    /// Returns `None` if no `h` tag is present.
    #[must_use]
    pub fn nostr_group_id(&self) -> Option<&str> {
        self.tags
            .iter()
            .find(|tag| tag.first().map(std::string::String::as_str) == Some("h"))
            .and_then(|tag| tag.get(1).map(std::string::String::as_str))
    }

    /// Extracts the expiration timestamp from the `expiration` tag.
    ///
    /// Returns `None` if no expiration tag is present or if parsing fails.
    #[must_use]
    pub fn expires_at(&self) -> Option<DateTime<Utc>> {
        self.tags
            .iter()
            .find(|tag| tag.first().map(std::string::String::as_str) == Some("expiration"))
            .and_then(|tag| tag.get(1))
            .and_then(|ts| ts.parse::<i64>().ok())
            .and_then(|ts| Utc.timestamp_opt(ts, 0).single())
    }

    /// Checks if this event has expired according to NIP-40.
    #[must_use]
    pub fn is_expired(&self) -> bool {
        self.expires_at().is_some_and(|exp| Utc::now() > exp)
    }

    /// Extracts the geohash from the `g` tag if present.
    #[must_use]
    pub fn geohash(&self) -> Option<&str> {
        self.tags
            .iter()
            .find(|tag| tag.first().map(std::string::String::as_str) == Some("g"))
            .and_then(|tag| tag.get(1).map(std::string::String::as_str))
    }

    /// Verifies the event signature.
    ///
    /// # Errors
    ///
    /// Returns an error if the signature is invalid.
    pub fn verify_signature(&self) -> Result<()> {
        use nostr::secp256k1::{schnorr::Signature, Message, XOnlyPublicKey};

        // Parse the public key
        let pubkey_bytes: [u8; 32] = hex::decode(&self.pubkey)?
            .try_into()
            .map_err(|_| NostrError::InvalidEvent("Invalid pubkey length".to_string()))?;
        let pubkey = XOnlyPublicKey::from_slice(&pubkey_bytes)
            .map_err(|e| NostrError::InvalidEvent(format!("Invalid pubkey: {e}")))?;

        // Parse the signature
        let sig_bytes: [u8; 64] = hex::decode(&self.sig)?
            .try_into()
            .map_err(|_| NostrError::InvalidEvent("Invalid signature length".to_string()))?;
        let signature = Signature::from_slice(&sig_bytes)
            .map_err(|e| NostrError::InvalidEvent(format!("Invalid signature: {e}")))?;

        // Verify the ID matches using constant-time comparison to prevent timing attacks
        let calculated_id = Self::calculate_id(
            &self.pubkey,
            self.created_at,
            self.kind,
            &self.tags,
            &self.content,
        )?;

        if calculated_id.as_bytes().ct_eq(self.id.as_bytes()).into() {
            // IDs match, continue with signature verification
        } else {
            return Err(NostrError::InvalidEvent("Event ID mismatch".to_string()));
        }

        // Verify signature using the shared secp256k1 context
        let id_bytes: [u8; 32] = hex::decode(&self.id)?
            .try_into()
            .map_err(|_| NostrError::InvalidEvent("Invalid ID length".to_string()))?;
        let message = Message::from_digest(id_bytes);

        SECP.verify_schnorr(&signature, &message, &pubkey)
            .map_err(|_| NostrError::InvalidSignature)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn unsigned_event_from_location() {
        let location = LocationMessage::new(37.7749, -122.4194);
        let event = UnsignedLocationEvent::from_location(&location).unwrap();

        assert_eq!(event.kind, KIND_LOCATION_DATA);
        assert!(event.content.contains("latitude"));
        assert!(event.content.contains("longitude"));
        assert!(event.tags.is_empty());
    }

    #[test]
    fn unsigned_event_roundtrip_location() {
        let original = LocationMessage::new(37.7749, -122.4194);
        let event = UnsignedLocationEvent::from_location(&original).unwrap();
        let recovered = event.to_location().unwrap();

        assert_eq!(original.latitude, recovered.latitude);
        assert_eq!(original.longitude, recovered.longitude);
        assert_eq!(original.geohash, recovered.geohash);
    }

    #[test]
    fn unsigned_event_json_roundtrip() {
        let location = LocationMessage::new(37.7749, -122.4194);
        let original = UnsignedLocationEvent::from_location(&location).unwrap();
        let json = original.to_json().unwrap();
        let recovered = UnsignedLocationEvent::from_json(&json).unwrap();

        assert_eq!(original, recovered);
    }

    #[test]
    fn signed_event_creation() {
        use chrono::Duration;

        let keypair = EphemeralKeypair::generate();
        let expires = Utc::now() + Duration::hours(24);

        let event = SignedLocationEvent::new(
            "test-group-id",
            "encrypted-content".to_string(),
            expires,
            &keypair,
            None,
        )
        .unwrap();

        assert_eq!(event.kind, KIND_GROUP_MESSAGE);
        assert_eq!(event.content, "encrypted-content");
        assert_eq!(event.id.len(), 64);
        assert_eq!(event.pubkey.len(), 64);
        assert_eq!(event.sig.len(), 128);
    }

    #[test]
    fn signed_event_contains_h_tag() {
        use chrono::Duration;

        let keypair = EphemeralKeypair::generate();
        let expires = Utc::now() + Duration::hours(24);

        let event = SignedLocationEvent::new(
            "my-group-id",
            "content".to_string(),
            expires,
            &keypair,
            None,
        )
        .unwrap();

        assert_eq!(event.nostr_group_id(), Some("my-group-id"));
    }

    #[test]
    fn signed_event_contains_expiration_tag() {
        use chrono::Duration;

        let keypair = EphemeralKeypair::generate();
        let expires = Utc::now() + Duration::hours(24);

        let event =
            SignedLocationEvent::new("group", "content".to_string(), expires, &keypair, None)
                .unwrap();

        let event_expires = event.expires_at().unwrap();
        // Allow 1 second tolerance for test timing
        assert!((event_expires.timestamp() - expires.timestamp()).abs() < 2);
    }

    #[test]
    fn signed_event_with_geohash() {
        use chrono::Duration;

        let keypair = EphemeralKeypair::generate();
        let expires = Utc::now() + Duration::hours(24);

        let event = SignedLocationEvent::new(
            "group",
            "content".to_string(),
            expires,
            &keypair,
            Some("9q8yy"), // Pre-truncated to 5 chars
        )
        .unwrap();

        assert_eq!(event.geohash(), Some("9q8yy"));
    }

    #[test]
    fn signed_event_without_geohash() {
        use chrono::Duration;

        let keypair = EphemeralKeypair::generate();
        let expires = Utc::now() + Duration::hours(24);

        let event = SignedLocationEvent::new(
            "group",
            "content".to_string(),
            expires,
            &keypair,
            None, // No geohash tag
        )
        .unwrap();

        assert_eq!(event.geohash(), None);
    }

    #[test]
    fn signed_event_signature_verification() {
        use chrono::Duration;

        let keypair = EphemeralKeypair::generate();
        let expires = Utc::now() + Duration::hours(24);

        let event =
            SignedLocationEvent::new("group", "content".to_string(), expires, &keypair, None)
                .unwrap();

        assert!(event.verify_signature().is_ok());
    }

    #[test]
    fn signed_event_json_roundtrip() {
        use chrono::Duration;

        let keypair = EphemeralKeypair::generate();
        let expires = Utc::now() + Duration::hours(24);

        let original =
            SignedLocationEvent::new("group", "content".to_string(), expires, &keypair, None)
                .unwrap();

        let json = original.to_json().unwrap();
        let recovered = SignedLocationEvent::from_json(&json).unwrap();

        assert_eq!(original.id, recovered.id);
        assert_eq!(original.pubkey, recovered.pubkey);
        assert_eq!(original.kind, recovered.kind);
        assert_eq!(original.content, recovered.content);
        assert_eq!(original.sig, recovered.sig);
    }

    #[test]
    fn tampered_event_fails_verification() {
        use chrono::Duration;

        let keypair = EphemeralKeypair::generate();
        let expires = Utc::now() + Duration::hours(24);

        let mut event =
            SignedLocationEvent::new("group", "content".to_string(), expires, &keypair, None)
                .unwrap();

        // Tamper with the content
        event.content = "tampered-content".to_string();

        assert!(event.verify_signature().is_err());
    }

    #[test]
    fn event_not_expired_when_fresh() {
        use chrono::Duration;

        let keypair = EphemeralKeypair::generate();
        let expires = Utc::now() + Duration::hours(24);

        let event =
            SignedLocationEvent::new("group", "content".to_string(), expires, &keypair, None)
                .unwrap();

        assert!(!event.is_expired());
    }

    #[test]
    fn verify_signature_rejects_short_pubkey() {
        use chrono::Duration;

        let keypair = EphemeralKeypair::generate();
        let expires = Utc::now() + Duration::hours(24);

        let mut event =
            SignedLocationEvent::new("group", "content".to_string(), expires, &keypair, None)
                .unwrap();

        // Replace pubkey with too-short value
        event.pubkey = "abc".to_string();

        let result = event.verify_signature();
        assert!(result.is_err());
    }

    #[test]
    fn verify_signature_rejects_invalid_hex_pubkey() {
        use chrono::Duration;

        let keypair = EphemeralKeypair::generate();
        let expires = Utc::now() + Duration::hours(24);

        let mut event =
            SignedLocationEvent::new("group", "content".to_string(), expires, &keypair, None)
                .unwrap();

        // Replace pubkey with invalid hex (contains 'z')
        event.pubkey = "zz".repeat(32);

        let result = event.verify_signature();
        assert!(result.is_err());
    }

    #[test]
    fn verify_signature_rejects_short_signature() {
        use chrono::Duration;

        let keypair = EphemeralKeypair::generate();
        let expires = Utc::now() + Duration::hours(24);

        let mut event =
            SignedLocationEvent::new("group", "content".to_string(), expires, &keypair, None)
                .unwrap();

        // Replace signature with too-short value
        event.sig = "abc".to_string();

        let result = event.verify_signature();
        assert!(result.is_err());
    }

    #[test]
    fn nostr_group_id_returns_none_when_missing() {
        use chrono::Duration;

        let keypair = EphemeralKeypair::generate();
        let expires = Utc::now() + Duration::hours(24);

        let mut event =
            SignedLocationEvent::new("group", "content".to_string(), expires, &keypair, None)
                .unwrap();

        // Remove the h tag
        event
            .tags
            .retain(|tag| tag.first().map(|s| s.as_str()) != Some("h"));

        assert_eq!(event.nostr_group_id(), None);
    }

    #[test]
    fn expires_at_returns_none_for_invalid_timestamp() {
        use chrono::Duration;

        let keypair = EphemeralKeypair::generate();
        let expires = Utc::now() + Duration::hours(24);

        let mut event =
            SignedLocationEvent::new("group", "content".to_string(), expires, &keypair, None)
                .unwrap();

        // Replace expiration tag with invalid timestamp
        for tag in &mut event.tags {
            if tag.first().map(|s| s.as_str()) == Some("expiration") {
                if tag.len() > 1 {
                    tag[1] = "not_a_number".to_string();
                }
            }
        }

        assert_eq!(event.expires_at(), None);
    }

    #[test]
    fn unsigned_event_from_json_rejects_invalid_json() {
        let result = UnsignedLocationEvent::from_json("not valid json{");
        assert!(result.is_err());
    }

    #[test]
    fn signed_event_from_json_rejects_invalid_json() {
        let result = SignedLocationEvent::from_json("not valid json{");
        assert!(result.is_err());
    }

    #[test]
    fn verify_signature_detects_id_tampering() {
        use chrono::Duration;

        let keypair = EphemeralKeypair::generate();
        let expires = Utc::now() + Duration::hours(24);

        let mut event =
            SignedLocationEvent::new("group", "content".to_string(), expires, &keypair, None)
                .unwrap();

        // Tamper with the ID directly (not content) - flip first byte
        let mut id_bytes = hex::decode(&event.id).unwrap();
        id_bytes[0] ^= 0xFF;
        event.id = hex::encode(id_bytes);

        // Signature verification should catch ID tampering via constant-time comparison
        let result = event.verify_signature();
        assert!(result.is_err());
        if let Err(NostrError::InvalidEvent(msg)) = result {
            assert!(msg.contains("ID mismatch"), "Should detect ID mismatch");
        } else {
            panic!("Expected InvalidEvent error with ID mismatch message");
        }
    }

    #[test]
    fn verify_signature_rejects_pubkey_not_on_curve() {
        use chrono::Duration;

        let keypair = EphemeralKeypair::generate();
        let expires = Utc::now() + Duration::hours(24);

        let mut event =
            SignedLocationEvent::new("group", "content".to_string(), expires, &keypair, None)
                .unwrap();

        // Valid hex length, but not a valid point on secp256k1 curve
        // (all zeros is not a valid x-coordinate for a curve point)
        event.pubkey = "00".repeat(32);

        let result = event.verify_signature();
        assert!(result.is_err());
    }
}
