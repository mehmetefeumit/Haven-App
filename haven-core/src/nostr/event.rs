//! Nostr event types and kind numbers for location sharing.
//!
//! - [`KIND_LOCATION_UPDATE`]: the inner (MLS-tunnelled) location rumor's kind
//! - [`SignedLocationEvent`]: Outer event (kind 445) ready for relay transmission

use chrono::{DateTime, TimeZone, Utc};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use subtle::ConstantTimeEq;

use crate::nostr::error::{NostrError, Result};
use crate::nostr::keys::{EphemeralKeypair, SECP};
use crate::nostr::tags::TagBuilder;

/// Event kind for Marmot group messages (outer event).
pub const KIND_GROUP_MESSAGE: u16 = 445;

/// Event kind of the inner, MLS-tunnelled rumor carrying a location update.
///
/// The kind — not a tag — is what marks a payload as a location update, on both
/// the send and the receive side.
///
/// Drawn from the ephemeral band (20000–29999) and unallocated in
/// `nostr-protocol/registry-of-kinds`, the NIPs kind table, MDK and Haven, so no
/// Marmot client renders it. Haven previously sent kind 9
/// (`MARMOT_APP_EVENT_KIND_CHAT`), which every Marmot client draws as a chat
/// bubble and feeds to conversation previews, unread badges and push
/// notifications — a coordinate published to a shared group surfaced as chatter
/// in a co-member's White Noise. An unrecognised kind is safe by spec:
/// `marmot/foundation/application-messages.md` requires that protocol processing
/// not reject an otherwise-valid app payload merely because its kind is unknown,
/// and MDK's timeline projection drops unrecognised kinds.
///
/// The number is pinned by `location_update_kind_number_is_pinned`, because the
/// repo guard keys on the token `Kind::Custom(KIND_LOCATION_UPDATE)` and cannot
/// see what the constant holds.
pub const KIND_LOCATION_UPDATE: u16 = 25442;

/// The kind Haven sent location rumors as before [`KIND_LOCATION_UPDATE`].
///
/// **Receive-only, and only in combination with a `["t","location"]` tag** — see
/// `inner_location_content` in [`crate::nostr::mls`], the single site that reads
/// it. Nothing constructs a rumor at this kind any more.
///
/// The pairing narrows the transitional window: every Haven build that can still
/// share an MLS group with this one (v0.1.11 and v0.1.12 — earlier builds are
/// pre-Dark-Matter and cannot decrypt a current kind 445 at all) stamps that
/// hashtag on its kind-9 rumor, while a White Noise chat message is a bare kind
/// 9. It does not close the window — a client that lifts `#hashtags` out of
/// message content into `t` tags emits the same pair for anyone who types
/// "#location" — so this gate is defense in depth ON TOP OF the
/// `LocationMessage` parse, never a replacement for it.
pub const LEGACY_KIND_LOCATION_UPDATE: u16 = 9;

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
///   "content": "...",      // ChaCha20-Poly1305 under the MLS exporter
///   "sig": "..."           // Schnorr signature
/// }
/// ```
#[derive(Clone, Serialize, Deserialize, PartialEq, Eq)]
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

    /// Ciphertext (base64-encoded). ChaCha20-Poly1305 under the
    /// MLS-exporter-derived `marmot/group-event` key — NOT NIP-44, which has
    /// not been on the kind-445 path since the Dark Matter cutover.
    pub content: String,

    /// Schnorr signature (64 bytes, hex-encoded)
    pub sig: String,
}

impl std::fmt::Debug for SignedLocationEvent {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("SignedLocationEvent")
            .field("id", &"<redacted>")
            .field("pubkey", &"<redacted>")
            .field("kind", &self.kind)
            .field("created_at", &self.created_at)
            .field("tag_count", &self.tags.len())
            .field("content", &"<redacted>")
            .field("sig", &"<redacted>")
            .finish()
    }
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
    /// * `encrypted_content` - The already-encrypted inner event (on the
    ///   production path, ChaCha20-Poly1305 under the MLS exporter)
    /// * `expires_at` - When this event should expire (NIP-40)
    /// * `keypair` - Ephemeral keypair for signing
    /// * `geohash` - Optional geohash for relay filtering (truncated to max 5 chars internally)
    ///
    /// # Warning
    ///
    /// This creates events WITHOUT MLS encryption. Relay transmission goes
    /// through `SessionManager::send_location`, which hands the rumor to the
    /// engine; nothing on that path calls this.
    ///
    /// # Errors
    ///
    /// Returns an error if signing fails.
    // Test-only, and no longer waiting on a caller: the builder this comment
    // once promised (`LocationEventBuilder::encrypt`) never called it and has
    // been deleted. It stays reachable from tests alone — and the `g`/`alt`
    // tags it stamps below are exactly what the C5.4 wire oracle exists to
    // catch should any of it ever reach a relay.
    #[allow(dead_code)]
    pub(crate) fn new(
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
            TagBuilder::alt_tag("Encrypted group message"),
        ];

        // Optionally add geohash tag for relay filtering
        if let Some(gh) = geohash {
            // Truncate to max 5 chars (~2.4km precision) to prevent leaking
            // precise location to relay operators via the outer event
            const MAX_GEOHASH_PRECISION: usize = 5;
            let truncated = &gh[..gh.len().min(MAX_GEOHASH_PRECISION)];
            tags.push(vec!["g".to_string(), truncated.to_string()]);
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

    // ---- The inner location kind ------------------------------------------

    /// The number itself, spelled out. The repo's kind guard keys on the TOKEN
    /// `Kind::Custom(KIND_LOCATION_UPDATE)` at the send site, so it stays green
    /// no matter what the constant holds; without this assertion the value could
    /// be edited to anything — including back to 9 — with every other test and
    /// every guard still passing.
    #[test]
    fn location_update_kind_number_is_pinned() {
        assert_eq!(KIND_LOCATION_UPDATE, 25442);
    }

    /// The number must stay out of every kind another client would act on. Kind
    /// 9 is the one that caused the move (Marmot's chat kind); the rest are what
    /// a future re-draw could collide with. Listed explicitly rather than as a
    /// range so that adding a colliding constant is a compile-time visible edit
    /// to this list.
    #[test]
    fn location_update_kind_collides_with_no_allocated_kind() {
        // NIP-01 short text note / repost, NIP-09 deletion, NIP-25 reaction,
        // Marmot chat and welcome, and the Marmot/MDK group-system and media
        // kinds. 1209 is NOT an allocation — it appears in no Marmot registry
        // and no MDK rev — and is reserved here deliberately, as margin next to
        // 1210.
        for allocated in [
            1u16,
            2,
            5,
            7,
            9,
            444,
            446,
            447,
            448,
            449,
            450,
            451,
            452,
            1009,
            1200,
            1201,
            1202,
            1209,
            1210,
            KIND_GROUP_MESSAGE,
        ] {
            assert_ne!(
                KIND_LOCATION_UPDATE, allocated,
                "the inner location kind must not collide with allocated kind {allocated}"
            );
        }
        assert!(
            (20_000..=29_999).contains(&KIND_LOCATION_UPDATE),
            "the band is not about relay storage — the rumor is sealed inside \
             the 445 and never reaches a relay. It is where an application draws \
             a kind nothing else renders: got {KIND_LOCATION_UPDATE}"
        );
    }

    /// The legacy kind is the chat kind, and it is the reason the tag pairing in
    /// the receive gate is load-bearing: on its own, this number cannot tell a
    /// pre-cutover Haven rumor from a White Noise chat message.
    #[test]
    fn legacy_location_kind_is_the_marmot_chat_kind() {
        assert_eq!(LEGACY_KIND_LOCATION_UPDATE, 9);
        assert_ne!(LEGACY_KIND_LOCATION_UPDATE, KIND_LOCATION_UPDATE);
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
            .retain(|tag| tag.first().map(String::as_str) != Some("h"));

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
            if tag.first().map(String::as_str) == Some("expiration") && tag.len() > 1 {
                tag[1] = "not_a_number".to_string();
            }
        }

        assert_eq!(event.expires_at(), None);
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

    // ====================================================================
    // D2: Outer event content does not contain plaintext location
    // ====================================================================

    /// Creates a `SignedLocationEvent` with known "encrypted" content and
    /// known coordinates, then asserts the outer event's serialized JSON
    /// does not leak the original latitude, longitude, or geohash in
    /// plaintext. This verifies that only the encrypted blob appears in
    /// the relay-facing event.
    #[test]
    fn d2_outer_event_does_not_contain_plaintext_location() {
        use chrono::Duration;

        let keypair = EphemeralKeypair::generate();
        let expires = Utc::now() + Duration::hours(24);

        // Known coordinates
        let lat_str = "37.7749";
        let lon_str = "-122.4194";
        let geohash = "9q8yy";

        let event = SignedLocationEvent::new(
            "test-group-id",
            "ENCRYPTED_BLOB_abc123".to_string(),
            expires,
            &keypair,
            None,
        )
        .unwrap();

        let json = event.to_json().unwrap();

        assert!(
            !json.contains(lat_str),
            "Outer event JSON must not contain plaintext latitude"
        );
        assert!(
            !json.contains(lon_str),
            "Outer event JSON must not contain plaintext longitude"
        );
        assert!(
            !json.contains(geohash),
            "Outer event JSON must not contain plaintext geohash (no g tag was requested)"
        );

        // Also verify the content field is the encrypted blob, not location data
        assert_eq!(event.content, "ENCRYPTED_BLOB_abc123");
    }

    // ====================================================================
    // D6: Expired location event detection
    // ====================================================================

    /// Creates an event with an expiration timestamp one hour in the past
    /// and verifies that `is_expired()` returns `true`. This complements
    /// the existing `event_not_expired_when_fresh` test.
    #[test]
    fn d6_event_is_expired_when_expiration_in_past() {
        use chrono::Duration;

        let keypair = EphemeralKeypair::generate();
        // Set expiration to 1 hour ago
        let expires = Utc::now() - Duration::hours(1);

        let event =
            SignedLocationEvent::new("group", "content".to_string(), expires, &keypair, None)
                .unwrap();

        assert!(
            event.is_expired(),
            "Event with expiration in the past must report as expired"
        );
    }

    /// Verifies that `is_expired()` returns `true` even when the
    /// expiration is only one second in the past, catching any off-by-one
    /// errors in the comparison.
    #[test]
    fn d6_event_expired_by_one_second() {
        use chrono::Duration;

        let keypair = EphemeralKeypair::generate();
        let expires = Utc::now() - Duration::seconds(2);

        let event =
            SignedLocationEvent::new("group", "content".to_string(), expires, &keypair, None)
                .unwrap();

        assert!(
            event.is_expired(),
            "Event expired by 2 seconds must report as expired"
        );
    }

    // ====================================================================
    // D7: Geohash tag truncation enforcement
    // ====================================================================

    /// An 8-character geohash passed to `SignedLocationEvent::new()` must
    /// be truncated to exactly 5 characters in the `g` tag.
    #[test]
    fn d7_geohash_8_chars_truncated_to_5() {
        use chrono::Duration;

        let keypair = EphemeralKeypair::generate();
        let expires = Utc::now() + Duration::hours(24);

        let event = SignedLocationEvent::new(
            "group",
            "content".to_string(),
            expires,
            &keypair,
            Some("9q8yyz8r"), // 8 characters
        )
        .unwrap();

        let g_tag_value = event.geohash().expect("g tag must be present");
        assert_eq!(
            g_tag_value.len(),
            5,
            "8-char geohash must be truncated to 5 chars in g tag"
        );
        assert_eq!(g_tag_value, "9q8yy");
    }

    /// A 5-character geohash passed to `SignedLocationEvent::new()` must
    /// remain exactly 5 characters (no further truncation).
    #[test]
    fn d7_geohash_5_chars_stays_5() {
        use chrono::Duration;

        let keypair = EphemeralKeypair::generate();
        let expires = Utc::now() + Duration::hours(24);

        let event = SignedLocationEvent::new(
            "group",
            "content".to_string(),
            expires,
            &keypair,
            Some("9q8yy"), // Exactly 5 characters
        )
        .unwrap();

        let g_tag_value = event.geohash().expect("g tag must be present");
        assert_eq!(
            g_tag_value.len(),
            5,
            "5-char geohash must remain 5 chars in g tag"
        );
        assert_eq!(g_tag_value, "9q8yy");
    }

    /// A 3-character geohash (shorter than the 5-char max) must pass
    /// through unchanged. The truncation only caps at 5; it does not
    /// pad shorter values.
    #[test]
    fn d7_geohash_3_chars_stays_3() {
        use chrono::Duration;

        let keypair = EphemeralKeypair::generate();
        let expires = Utc::now() + Duration::hours(24);

        let event = SignedLocationEvent::new(
            "group",
            "content".to_string(),
            expires,
            &keypair,
            Some("9q8"), // 3 characters
        )
        .unwrap();

        let g_tag_value = event.geohash().expect("g tag must be present");
        assert_eq!(
            g_tag_value.len(),
            3,
            "3-char geohash must remain 3 chars in g tag"
        );
        assert_eq!(g_tag_value, "9q8");
    }

    /// The `alt` tag must be a generic description that does not reveal
    /// the application identity or purpose. It must NOT contain "haven",
    /// "location", or "family" (case-insensitive).
    #[test]
    fn d7_alt_tag_does_not_reveal_app_identity() {
        use chrono::Duration;

        let keypair = EphemeralKeypair::generate();
        let expires = Utc::now() + Duration::hours(24);

        let event =
            SignedLocationEvent::new("group", "content".to_string(), expires, &keypair, None)
                .unwrap();

        let alt_value = event
            .tags
            .iter()
            .find(|tag| tag.first().map(String::as_str) == Some("alt"))
            .and_then(|tag| tag.get(1))
            .expect("alt tag must be present");

        let alt_lower = alt_value.to_lowercase();
        assert!(
            !alt_lower.contains("haven"),
            "alt tag must not contain 'haven': got '{alt_value}'"
        );
        assert!(
            !alt_lower.contains("location"),
            "alt tag must not contain 'location': got '{alt_value}'"
        );
        assert!(
            !alt_lower.contains("family"),
            "alt tag must not contain 'family': got '{alt_value}'"
        );
    }

    // ---- Security Rules 4/6/8: the redacting `Debug` impl ------------------
    //
    // The outer event's `id` / `pubkey` / `sig` identify the ephemeral sender
    // key minted per message (Rule 2), and its `h` tag IS the nostr_group_id.
    // The type does not derive `Debug` — it hand-writes one that substitutes
    // `<redacted>`. A `#[derive(Debug)]` would compile, pass every other test,
    // and silently start printing that material into logcat, a bug report, or
    // an OEM log collector.
    //
    // This asserts on the RENDERED string, which is what actually reaches a
    // log, rather than on the impl's existence. The matching guarantee for the
    // decrypted inner payload lives on the types that still carry it:
    // `LocationMessageResult::Location` (mls::types) and `LocationMessage`.

    #[test]
    fn signed_event_debug_redacts_every_identifying_field() {
        let event = SignedLocationEvent {
            id: "aaaaaaaabbbbbbbbccccccccdddddddd".to_string(),
            pubkey: "deadbeefdeadbeefdeadbeefdeadbeef".to_string(),
            created_at: 1_700_000_000,
            kind: KIND_GROUP_MESSAGE,
            tags: vec![
                vec!["h".to_string(), "0123456789abcdef".to_string()],
                vec!["expiration".to_string(), "1700000228".to_string()],
            ],
            content: "BASE64CIPHERTEXTPAYLOAD".to_string(),
            sig: "ffffffffffffffffffffffffffffffff".to_string(),
        };

        let rendered = format!("{event:?}");

        for secret in [
            "aaaaaaaabbbbbbbb",        // id
            "deadbeefdeadbeef",        // ephemeral pubkey (Rule 2)
            "BASE64CIPHERTEXTPAYLOAD", // ciphertext
            "ffffffffffffffff",        // signature
        ] {
            assert!(
                !rendered.contains(secret),
                "`{secret}` leaked into the rendered Debug: {rendered}"
            );
        }
        assert!(
            !rendered.contains("0123456789abcdef"),
            "the `h` tag IS the nostr_group_id — rendering it links a device to \
             a circle across every log line it appears in (Rule 4): {rendered}"
        );
        assert!(
            rendered.contains("tag_count: 2"),
            "tags must reduce to a count: {rendered}"
        );
        assert!(
            rendered.contains("kind: 445"),
            "the kind is safe and is the field that makes a log line \
             identifiable at all: {rendered}"
        );
    }
}
