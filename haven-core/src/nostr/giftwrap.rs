//! NIP-59 Gift Wrap peeling for received Welcome events.
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
//! Haven does NOT build this envelope. Both directions belong to the engine:
//! the MDK peeler wraps outbound welcomes (`transport-nostr-peeler`, with an
//! empty extra-tag set, so a production 1059 carries `p` and nothing else) and
//! peels inbound ones inside `SessionManager::accept_welcome`. What lives here
//! is the read-only peel used by tests that need to inspect an engine-produced
//! gift wrap from the recipient's side.

use nostr::nips::nip59::UnwrappedGift as NostrUnwrappedGift;
use nostr::{Event, EventId, Keys, Kind, PublicKey, UnsignedEvent};

use super::error::{NostrError, Result};

/// Kind for Welcome events (MLS group invitation).
pub const KIND_WELCOME: u16 = 444;

/// Kind for Gift Wrap (NIP-59).
pub const KIND_GIFT_WRAP: u16 = 1059;

/// Result of unwrapping a gift-wrapped Welcome event.
#[derive(Clone)]
pub struct UnwrappedWelcome {
    /// The sender's real public key (from the seal).
    pub sender_pubkey: PublicKey,

    /// The event ID of the gift wrap (used as wrapper ID for MDK).
    pub wrapper_event_id: EventId,

    /// The unsigned kind 444 Welcome rumor.
    pub rumor: UnsignedEvent,
}

impl std::fmt::Debug for UnwrappedWelcome {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("UnwrappedWelcome")
            .field("sender_pubkey", &"<redacted>")
            .field("wrapper_event_id", &self.wrapper_event_id)
            .field("rumor", &"<redacted>")
            .finish()
    }
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
    use nostr::{EventBuilder, Timestamp};

    /// Wraps `rumor` exactly the way production does — `EventBuilder::gift_wrap`
    /// with an EMPTY extra-tag set, mirroring the MDK peeler
    /// (`transport-nostr-peeler/src/peeler.rs`). Peeling a fixture built any
    /// other way would test a wire shape Haven never emits.
    async fn production_shaped_wrap(sender: &Keys, recipient: &PublicKey, kind: u16) -> Event {
        let rumor = UnsignedEvent::new(
            sender.public_key(),
            Timestamp::now(),
            Kind::Custom(kind),
            Vec::new(),
            "test_mls_welcome_bytes".to_string(),
        );
        EventBuilder::gift_wrap(sender, recipient, rumor, [])
            .await
            .expect("wrap the fixture")
    }

    #[tokio::test]
    async fn unwrap_recovers_sender_and_rumor() {
        let sender = Keys::generate();
        let recipient = Keys::generate();

        let wrapped = production_shaped_wrap(&sender, &recipient.public_key(), KIND_WELCOME).await;

        let unwrapped = unwrap_welcome(&recipient, &wrapped).await.unwrap();

        assert_eq!(unwrapped.sender_pubkey, sender.public_key());
        assert_eq!(unwrapped.rumor.kind, Kind::Custom(KIND_WELCOME));
        assert_eq!(unwrapped.rumor.content, "test_mls_welcome_bytes");
        assert_eq!(unwrapped.wrapper_event_id, wrapped.id);
    }

    #[tokio::test]
    async fn unwrap_fails_for_wrong_recipient() {
        let sender = Keys::generate();
        let intended_recipient = Keys::generate();
        let wrong_recipient = Keys::generate();

        let wrapped =
            production_shaped_wrap(&sender, &intended_recipient.public_key(), KIND_WELCOME).await;

        let result = unwrap_welcome(&wrong_recipient, &wrapped).await;
        assert!(result.is_err());
    }

    /// The kind check runs before any decryption, so a relay cannot get an
    /// arbitrary event peeled by addressing it at the recipient.
    #[tokio::test]
    async fn unwrap_rejects_an_event_that_is_not_a_gift_wrap() {
        let recipient = Keys::generate();
        let not_a_wrap = EventBuilder::new(Kind::Custom(1), "hello")
            .sign_with_keys(&Keys::generate())
            .expect("sign fixture");

        let result = unwrap_welcome(&recipient, &not_a_wrap).await;

        match result {
            Err(NostrError::GiftUnwrap(msg)) => assert!(msg.contains("1059")),
            other => panic!("expected a GiftUnwrap rejection, got {other:?}"),
        }
    }

    /// A well-formed 1059 addressed to us may still carry something other than
    /// a Welcome. Fail closed rather than hand a foreign rumor to the caller.
    #[tokio::test]
    async fn unwrap_rejects_a_gift_wrap_whose_rumor_is_not_a_welcome() {
        let sender = Keys::generate();
        let recipient = Keys::generate();

        let wrapped = production_shaped_wrap(&sender, &recipient.public_key(), 9).await;

        let result = unwrap_welcome(&recipient, &wrapped).await;

        match result {
            Err(NostrError::GiftUnwrap(msg)) => assert!(msg.contains("444")),
            other => panic!("expected a GiftUnwrap rejection, got {other:?}"),
        }
    }
}
