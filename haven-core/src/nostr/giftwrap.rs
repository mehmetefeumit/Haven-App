//! NIP-59 Gift Wrap for secure event delivery.
//!
//! This module provides gift-wrapping and unwrapping functionality
//! for Welcome events (kind 444) following NIP-59 specification.
//!
//! # Gift Wrap Structure
//!
//! ```text
//! ┌─────────────────────────────────────────────────────┐
//! │ Layer 3: Gift Wrap (kind 1059) - PUBLIC             │
//! │ • Uses ephemeral keypair (single use)               │
//! │ • Timestamp randomized ±48 hours                    │
//! │ • Only reveals: recipient (p-tag)                   │
//! │  ┌───────────────────────────────────────────────┐  │
//! │  │ Layer 2: Seal (kind 13) - ENCRYPTED           │  │
//! │  │ • NIP-44 encrypted for recipient              │  │
//! │  │ • Signed by sender's real key                 │  │
//! │  │  ┌─────────────────────────────────────────┐  │  │
//! │  │  │ Layer 1: Rumor (kind 444) - UNSIGNED    │  │  │
//! │  │  │ • Contains MLS Welcome bytes            │  │  │
//! │  │  │ • MUST remain unsigned (MIP-02)         │  │  │
//! │  │  └─────────────────────────────────────────┘  │  │
//! │  └───────────────────────────────────────────────┘  │
//! └─────────────────────────────────────────────────────┘
//! ```
//!
//! # Security
//!
//! - **Metadata protection**: Sender identity hidden behind ephemeral key
//! - **Unsigned rumor**: Kind 444 cannot be published even if leaked
//! - **Ephemeral keys**: Fresh keypair per wrap, never stored
//! - **Timestamp randomization**: ±48 hours to prevent timing correlation

use nostr::nips::nip59::UnwrappedGift as NostrUnwrappedGift;
use nostr::{Event, EventBuilder, EventId, Keys, Kind, PublicKey, UnsignedEvent};

use super::error::{NostrError, Result};

/// Kind for Welcome events (MLS group invitation).
pub const KIND_WELCOME: u16 = 444;

/// Kind for Gift Wrap (NIP-59).
pub const KIND_GIFT_WRAP: u16 = 1059;

/// Result of unwrapping a gift-wrapped Welcome event.
#[derive(Debug, Clone)]
pub struct UnwrappedWelcome {
    /// The sender's real public key (from the seal).
    pub sender_pubkey: PublicKey,

    /// The event ID of the gift wrap (used as wrapper ID for MDK).
    pub wrapper_event_id: EventId,

    /// The unsigned kind 444 Welcome rumor.
    pub rumor: UnsignedEvent,
}

/// Gift-wraps a Welcome rumor for secure delivery (NIP-59).
///
/// Creates a three-layer encrypted envelope:
/// 1. Rumor (unsigned kind 444 Welcome) - the actual invitation
/// 2. Seal (NIP-44 encrypted, sender authenticated)
/// 3. Gift Wrap (kind 1059, ephemeral key, public)
///
/// # Arguments
///
/// * `sender_keys` - The inviter's Nostr identity keys
/// * `recipient_pubkey` - The invitee's public key
/// * `welcome_rumor` - The unsigned kind 444 event from MDK
///
/// # Returns
///
/// A kind 1059 event ready to publish to the recipient's inbox relays.
///
/// # Errors
///
/// Returns error if:
/// - The rumor is not kind 444
/// - Encryption fails
///
/// # Security
///
/// - Uses a fresh ephemeral keypair for the outer layer
/// - Randomizes timestamp by ±48 hours
/// - Never stores or logs ephemeral keys
pub async fn wrap_welcome(
    sender_keys: &Keys,
    recipient_pubkey: &PublicKey,
    welcome_rumor: UnsignedEvent,
) -> Result<Event> {
    // Verify this is a kind 444 Welcome event
    if welcome_rumor.kind != Kind::Custom(KIND_WELCOME) {
        return Err(NostrError::GiftWrap(format!(
            "Welcome rumor must be kind {KIND_WELCOME}, got {}",
            welcome_rumor.kind.as_u16()
        )));
    }

    // Use nostr's built-in gift wrapping via EventBuilder
    // This automatically:
    // - Creates seal (kind 13) with sender's key
    // - Generates ephemeral keypair for outer layer
    // - Randomizes timestamp ±48 hours
    // - NIP-44 encrypts both layers
    let gift_wrap = EventBuilder::gift_wrap(
        sender_keys,
        recipient_pubkey,
        welcome_rumor,
        std::iter::empty(), // No extra tags needed for Welcomes
    )
    .await
    .map_err(|e| NostrError::GiftWrap(e.to_string()))?;

    Ok(gift_wrap)
}

/// Unwraps a received gift-wrapped Welcome event.
///
/// Decrypts and verifies a kind 1059 gift wrap to extract:
/// - The sender's real public key (authenticated via seal)
/// - The unsigned kind 444 Welcome rumor
///
/// # Arguments
///
/// * `recipient_keys` - The recipient's Nostr identity keys
/// * `gift_wrap_event` - The kind 1059 event from a relay
///
/// # Returns
///
/// [`UnwrappedWelcome`] containing sender pubkey, wrapper event ID,
/// and the Welcome rumor.
///
/// # Errors
///
/// Returns error if:
/// - Event is not kind 1059
/// - Decryption fails (not intended for this recipient)
/// - Seal verification fails
/// - Inner event is not kind 444
pub async fn unwrap_welcome(
    recipient_keys: &Keys,
    gift_wrap_event: &Event,
) -> Result<UnwrappedWelcome> {
    // Verify this is a gift wrap
    if gift_wrap_event.kind != Kind::GiftWrap {
        return Err(NostrError::GiftUnwrap(format!(
            "Event is not a gift wrap (kind {KIND_GIFT_WRAP}), got {}",
            gift_wrap_event.kind.as_u16()
        )));
    }

    // Extract the rumor using nostr's UnwrappedGift
    // This automatically:
    // - Decrypts outer layer with recipient's key
    // - Verifies seal signature
    // - Returns sender pubkey and rumor
    let unwrapped = NostrUnwrappedGift::from_gift_wrap(recipient_keys, gift_wrap_event)
        .await
        .map_err(|e| NostrError::GiftUnwrap(e.to_string()))?;

    // Verify the rumor is kind 444
    if unwrapped.rumor.kind != Kind::Custom(KIND_WELCOME) {
        return Err(NostrError::GiftUnwrap(format!(
            "Gift wrap does not contain a kind {KIND_WELCOME} Welcome, got {}",
            unwrapped.rumor.kind.as_u16()
        )));
    }

    Ok(UnwrappedWelcome {
        sender_pubkey: unwrapped.sender,
        wrapper_event_id: gift_wrap_event.id,
        rumor: unwrapped.rumor,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use nostr::Timestamp;

    fn create_test_welcome_rumor(sender: &Keys) -> UnsignedEvent {
        UnsignedEvent::new(
            sender.public_key(),
            Timestamp::now(),
            Kind::Custom(KIND_WELCOME),
            Vec::new(),
            "test_mls_welcome_bytes".to_string(),
        )
    }

    fn create_wrong_kind_rumor(sender: &Keys) -> UnsignedEvent {
        UnsignedEvent::new(
            sender.public_key(),
            Timestamp::now(),
            Kind::Custom(9), // Wrong kind
            Vec::new(),
            "test".to_string(),
        )
    }

    #[tokio::test]
    async fn wrap_welcome_creates_kind_1059() {
        let sender = Keys::generate();
        let recipient = Keys::generate();
        let rumor = create_test_welcome_rumor(&sender);

        let wrapped = wrap_welcome(&sender, &recipient.public_key(), rumor)
            .await
            .unwrap();

        assert_eq!(wrapped.kind, Kind::GiftWrap);
        // Ephemeral pubkey should differ from sender
        assert_ne!(wrapped.pubkey, sender.public_key());
    }

    #[tokio::test]
    async fn wrap_welcome_rejects_wrong_kind() {
        let sender = Keys::generate();
        let recipient = Keys::generate();
        let wrong_rumor = create_wrong_kind_rumor(&sender);

        let result = wrap_welcome(&sender, &recipient.public_key(), wrong_rumor).await;

        assert!(result.is_err());
        if let Err(NostrError::GiftWrap(msg)) = result {
            assert!(msg.contains("kind 444"));
        } else {
            panic!("Expected GiftWrap error");
        }
    }

    #[tokio::test]
    async fn unwrap_recovers_sender_and_rumor() {
        let sender = Keys::generate();
        let recipient = Keys::generate();
        let rumor = create_test_welcome_rumor(&sender);
        let original_content = rumor.content.clone();

        let wrapped = wrap_welcome(&sender, &recipient.public_key(), rumor)
            .await
            .unwrap();

        let unwrapped = unwrap_welcome(&recipient, &wrapped).await.unwrap();

        assert_eq!(unwrapped.sender_pubkey, sender.public_key());
        assert_eq!(unwrapped.rumor.kind, Kind::Custom(KIND_WELCOME));
        assert_eq!(unwrapped.rumor.content, original_content);
        assert_eq!(unwrapped.wrapper_event_id, wrapped.id);
    }

    #[tokio::test]
    async fn unwrap_fails_for_wrong_recipient() {
        let sender = Keys::generate();
        let intended_recipient = Keys::generate();
        let wrong_recipient = Keys::generate();
        let rumor = create_test_welcome_rumor(&sender);

        let wrapped = wrap_welcome(&sender, &intended_recipient.public_key(), rumor)
            .await
            .unwrap();

        // Wrong recipient should fail to unwrap
        let result = unwrap_welcome(&wrong_recipient, &wrapped).await;
        assert!(result.is_err());
    }

    #[tokio::test]
    async fn ephemeral_keys_are_unique() {
        let sender = Keys::generate();
        let recipient = Keys::generate();

        let rumor1 = create_test_welcome_rumor(&sender);
        let rumor2 = create_test_welcome_rumor(&sender);

        let wrapped1 = wrap_welcome(&sender, &recipient.public_key(), rumor1)
            .await
            .unwrap();
        let wrapped2 = wrap_welcome(&sender, &recipient.public_key(), rumor2)
            .await
            .unwrap();

        // Each wrap should use a different ephemeral key
        assert_ne!(wrapped1.pubkey, wrapped2.pubkey);
        // Neither should be the sender's real key
        assert_ne!(wrapped1.pubkey, sender.public_key());
        assert_ne!(wrapped2.pubkey, sender.public_key());
    }
}
