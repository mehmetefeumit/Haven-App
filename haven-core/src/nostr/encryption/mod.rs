//! NIP-44 encryption for Nostr events.
//!
//! This module implements NIP-44 encryption using the conversation key
//! derived from the MLS exporter secret.

use nostr::nips::nip44::v2::{self, ConversationKey};
use zeroize::Zeroizing;

use crate::nostr::error::{NostrError, Result};

/// Encrypts content using NIP-44 v2.
///
/// # Arguments
///
/// * `plaintext` - The content to encrypt
/// * `conversation_key` - 32-byte key derived from MLS exporter secret, wrapped in
///   `Zeroizing` so the caller's copy is wiped on drop
///
/// # Known Gap
///
/// `ConversationKey` from the `nostr` crate does **not** implement `Zeroize` /
/// `ZeroizeOnDrop`, so the internal copy it holds will not be scrubbed from memory.
/// This is tracked upstream and should be revisited when the crate adds support.
///
/// # Errors
///
/// Returns an error if encryption fails.
pub fn encrypt_nip44(plaintext: &str, conversation_key: &Zeroizing<[u8; 32]>) -> Result<String> {
    // Zeroize the intermediate copy; ConversationKey internals remain a known gap
    let key_copy = Zeroizing::new(**conversation_key);
    // TODO(security): ConversationKey does not impl Zeroize — revisit when nostr crate adds support
    let conv_key = ConversationKey::new(*key_copy);
    let encrypted_bytes = v2::encrypt_to_bytes(&conv_key, plaintext.as_bytes())
        .map_err(|e| NostrError::Encryption(e.to_string()))?;

    // Return as base64 encoded string (NIP-44 format)
    Ok(base64::Engine::encode(
        &base64::engine::general_purpose::STANDARD,
        &encrypted_bytes,
    ))
}

/// Decrypts NIP-44 v2 encrypted content.
///
/// # Arguments
///
/// * `ciphertext` - The encrypted content (base64 encoded)
/// * `conversation_key` - 32-byte key derived from MLS exporter secret, wrapped in
///   `Zeroizing` so the caller's copy is wiped on drop
///
/// # Known Gap
///
/// `ConversationKey` from the `nostr` crate does **not** implement `Zeroize` /
/// `ZeroizeOnDrop`, so the internal copy it holds will not be scrubbed from memory.
/// This is tracked upstream and should be revisited when the crate adds support.
///
/// # Errors
///
/// Returns an error if decryption fails.
pub fn decrypt_nip44(ciphertext: &str, conversation_key: &Zeroizing<[u8; 32]>) -> Result<String> {
    use base64::Engine;

    // Zeroize the intermediate copy; ConversationKey internals remain a known gap
    let key_copy = Zeroizing::new(**conversation_key);
    // TODO(security): ConversationKey does not impl Zeroize — revisit when nostr crate adds support
    let conv_key = ConversationKey::new(*key_copy);

    // Decode base64
    let encrypted_bytes = base64::engine::general_purpose::STANDARD
        .decode(ciphertext)
        .map_err(|e| NostrError::Decryption(format!("Base64 decode error: {e}")))?;

    // Decrypt
    let decrypted_bytes = v2::decrypt_to_bytes(&conv_key, &encrypted_bytes)
        .map_err(|e| NostrError::Decryption(e.to_string()))?;

    // Convert to string
    String::from_utf8(decrypted_bytes)
        .map_err(|e| NostrError::Decryption(format!("UTF-8 decode error: {e}")))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn test_key() -> Zeroizing<[u8; 32]> {
        // A test conversation key (NOT for production use)
        let mut key = [0u8; 32];
        key[0] = 0x42;
        key[31] = 0x42;
        Zeroizing::new(key)
    }

    #[test]
    fn encrypt_decrypt_roundtrip() {
        let key = test_key();
        let plaintext = "Hello, World!";

        let ciphertext = encrypt_nip44(plaintext, &key).unwrap();
        let decrypted = decrypt_nip44(&ciphertext, &key).unwrap();

        assert_eq!(plaintext, decrypted);
    }

    #[test]
    fn encrypt_produces_different_ciphertext_each_time() {
        let key = test_key();
        let plaintext = "Test message";

        let ct1 = encrypt_nip44(plaintext, &key).unwrap();
        let ct2 = encrypt_nip44(plaintext, &key).unwrap();

        // Due to random nonce, ciphertexts should be different
        assert_ne!(ct1, ct2);

        // But both should decrypt to the same plaintext
        assert_eq!(decrypt_nip44(&ct1, &key).unwrap(), plaintext);
        assert_eq!(decrypt_nip44(&ct2, &key).unwrap(), plaintext);
    }

    #[test]
    fn decrypt_with_wrong_key_fails() {
        let key1 = test_key();
        let mut key2 = test_key();
        key2[15] = 0xFF; // Different key (DerefMut on Zeroizing)

        let ciphertext = encrypt_nip44("secret", &key1).unwrap();
        let result = decrypt_nip44(&ciphertext, &key2);

        assert!(result.is_err());
    }

    #[test]
    fn encrypt_empty_string_fails() {
        // NIP-44 requires non-empty plaintext
        let key = test_key();
        let plaintext = "";

        let result = encrypt_nip44(plaintext, &key);
        assert!(result.is_err());
    }

    #[test]
    fn encrypt_long_message() {
        let key = test_key();
        let plaintext = "x".repeat(10000);

        let ciphertext = encrypt_nip44(&plaintext, &key).unwrap();
        let decrypted = decrypt_nip44(&ciphertext, &key).unwrap();

        assert_eq!(plaintext, decrypted);
    }

    #[test]
    fn encrypt_json_content() {
        let key = test_key();
        let plaintext = r#"{"latitude":37.7749,"longitude":-122.4194}"#;

        let ciphertext = encrypt_nip44(plaintext, &key).unwrap();
        let decrypted = decrypt_nip44(&ciphertext, &key).unwrap();

        assert_eq!(plaintext, decrypted);
    }

    #[test]
    fn decrypt_invalid_ciphertext_fails() {
        let key = test_key();
        let result = decrypt_nip44("not-valid-base64-ciphertext!!!", &key);

        assert!(result.is_err());
    }

    #[test]
    fn encrypt_unicode_content() {
        let key = test_key();
        let plaintext = "Hello 世界 🌍 مرحبا";

        let ciphertext = encrypt_nip44(plaintext, &key).unwrap();
        let decrypted = decrypt_nip44(&ciphertext, &key).unwrap();

        assert_eq!(plaintext, decrypted);
    }

    #[test]
    fn encrypt_single_character() {
        let key = test_key();
        let plaintext = "X";

        let ciphertext = encrypt_nip44(plaintext, &key).unwrap();
        let decrypted = decrypt_nip44(&ciphertext, &key).unwrap();

        assert_eq!(plaintext, decrypted);
    }

    #[test]
    fn decrypt_truncated_ciphertext_fails() {
        let key = test_key();
        let ciphertext = encrypt_nip44("test message", &key).unwrap();

        // Truncate the ciphertext
        let truncated = &ciphertext[..ciphertext.len() / 2];
        let result = decrypt_nip44(truncated, &key);

        assert!(result.is_err());
    }

    #[test]
    fn decrypt_corrupted_ciphertext_fails() {
        use base64::Engine;

        let key = test_key();
        let ciphertext = encrypt_nip44("test message", &key).unwrap();

        // Decode, corrupt, re-encode
        let mut bytes = base64::engine::general_purpose::STANDARD
            .decode(&ciphertext)
            .unwrap();
        if bytes.len() > 10 {
            bytes[10] ^= 0xFF; // Flip bits in the middle
        }
        let corrupted = base64::engine::general_purpose::STANDARD.encode(&bytes);

        let result = decrypt_nip44(&corrupted, &key);
        assert!(result.is_err());
    }

    // ====================================================================
    // D5: Multiple encryptions produce unique ciphertexts for location JSON
    // ====================================================================

    /// Encrypts the same location JSON 100 times with the same key and
    /// verifies every ciphertext is unique. NIP-44 uses a random 32-byte
    /// nonce per encryption, so collisions should be computationally
    /// impossible. A collision here would indicate a broken or
    /// deterministic RNG.
    #[test]
    fn d5_location_json_encryptions_are_unique() {
        use std::collections::HashSet;

        use crate::location::LocationMessage;

        let key = test_key();
        let location = LocationMessage::new(37.7749, -122.4194);
        let json = location.to_string().expect("serialization must succeed");

        let ciphertexts: HashSet<String> = (0..100)
            .map(|_| encrypt_nip44(&json, &key).expect("encryption must succeed"))
            .collect();

        assert_eq!(
            ciphertexts.len(),
            100,
            "All 100 ciphertexts must be unique (random nonce per encryption)"
        );
    }
}
