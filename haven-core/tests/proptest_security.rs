//! Property-based tests for security-critical operations.
//!
//! These tests focus on:
//! - Key handling
//! - Encryption/decryption edge cases
//! - Signature verification
//! - Input validation and boundary conditions
//!
//! Note: MLS group context tests require MDK infrastructure and are covered
//! in the integration tests. This file focuses on cryptographic primitives.

use haven_core::nostr::encryption::{decrypt_nip44, encrypt_nip44};
use haven_core::nostr::EphemeralKeypair;
use proptest::prelude::*;

/// Strategy for generating 32-byte keys with various characteristics
fn diverse_key_strategy() -> impl Strategy<Value = [u8; 32]> {
    prop_oneof![
        // Normal random keys
        prop::array::uniform32(1u8..=255u8),
        // Keys with leading zeros
        (
            prop::array::uniform16(0u8..=10u8),
            prop::array::uniform16(1u8..=255u8)
        )
            .prop_map(|(a, b)| {
                let mut key = [0u8; 32];
                key[..16].copy_from_slice(&a);
                key[16..].copy_from_slice(&b);
                key
            }),
        // Keys with trailing zeros
        (
            prop::array::uniform16(1u8..=255u8),
            prop::array::uniform16(0u8..=10u8)
        )
            .prop_map(|(a, b)| {
                let mut key = [0u8; 32];
                key[..16].copy_from_slice(&a);
                key[16..].copy_from_slice(&b);
                key
            }),
        // High-entropy keys
        prop::array::uniform32(200u8..=255u8),
        // Low-entropy keys (but not all zeros)
        (1u8..=10u8).prop_map(|v| [v; 32]),
    ]
}

/// Strategy for generating plaintext of various lengths
fn diverse_plaintext_strategy() -> impl Strategy<Value = String> {
    prop_oneof![
        // Single character
        "[a-zA-Z0-9]".prop_map(|s| s.to_string()),
        // Short strings
        "[a-zA-Z0-9 ]{1,10}",
        // Medium strings
        "[a-zA-Z0-9 ]{50,200}",
        // Long strings
        "[a-zA-Z0-9 ]{500,1000}",
        // JSON-like content
        r#"\{"[a-z]+":"[a-zA-Z0-9]+"\}"#,
        // Unicode content
        "[\\p{L}\\p{N} ]{1,50}",
    ]
}

/// Strategy for valid secret key bytes (non-zero, below curve order)
fn valid_secret_key_strategy() -> impl Strategy<Value = [u8; 32]> {
    // Generate keys that are valid for secp256k1
    // The curve order is FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141
    // We avoid keys >= curve order and keys that are all zeros
    prop::array::uniform32(1u8..=254u8).prop_filter("non-zero key", |k| {
        // Ensure at least one byte is non-zero
        k.iter().any(|&b| b != 0)
    })
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(100))]

    // ========================================================================
    // Encryption Security Properties
    // ========================================================================

    /// Property: Different keys always produce different ciphertexts for same plaintext
    #[test]
    fn different_keys_produce_different_ciphertexts(
        plaintext in "[a-zA-Z]{20,50}",
        key1 in diverse_key_strategy(),
        key2 in diverse_key_strategy(),
    ) {
        prop_assume!(key1 != key2);

        let ct1 = encrypt_nip44(&plaintext, &key1);
        let ct2 = encrypt_nip44(&plaintext, &key2);

        // Both should succeed
        prop_assert!(ct1.is_ok());
        prop_assert!(ct2.is_ok());

        // Ciphertexts should differ
        prop_assert_ne!(ct1.unwrap(), ct2.unwrap());
    }

    /// Property: Ciphertext length is always larger than plaintext
    #[test]
    fn ciphertext_larger_than_plaintext(
        plaintext in diverse_plaintext_strategy(),
        key in diverse_key_strategy(),
    ) {
        prop_assume!(!plaintext.is_empty());

        let ciphertext = encrypt_nip44(&plaintext, &key);
        prop_assert!(ciphertext.is_ok());

        let ct = ciphertext.unwrap();
        // Ciphertext includes nonce, padding, and MAC
        prop_assert!(ct.len() > plaintext.len());
    }

    /// Property: Decryption is deterministic - same ciphertext always decrypts to same plaintext
    #[test]
    fn decryption_is_deterministic(
        plaintext in diverse_plaintext_strategy(),
        key in diverse_key_strategy(),
    ) {
        prop_assume!(!plaintext.is_empty());

        let ciphertext = encrypt_nip44(&plaintext, &key).expect("encryption succeeds");

        // Decrypt multiple times
        let d1 = decrypt_nip44(&ciphertext, &key);
        let d2 = decrypt_nip44(&ciphertext, &key);
        let d3 = decrypt_nip44(&ciphertext, &key);

        prop_assert!(d1.is_ok());
        prop_assert!(d2.is_ok());
        prop_assert!(d3.is_ok());

        prop_assert_eq!(&d1.unwrap(), &plaintext);
        prop_assert_eq!(&d2.unwrap(), &plaintext);
        prop_assert_eq!(&d3.unwrap(), &plaintext);
    }

    /// Property: Tampering with the MAC portion of ciphertext causes decryption failure
    #[test]
    fn mac_tampering_causes_decryption_failure(
        plaintext in "[a-zA-Z]{20,50}",
        key in diverse_key_strategy(),
        mac_offset in 0usize..32,
    ) {
        use base64::Engine;

        let ciphertext = encrypt_nip44(&plaintext, &key).expect("encryption succeeds");
        let mut ct_bytes = base64::engine::general_purpose::STANDARD
            .decode(&ciphertext)
            .expect("valid base64");

        prop_assume!(ct_bytes.len() > 65); // At least version + nonce + 1 byte + MAC

        // Flip a bit in the MAC (last 32 bytes)
        let mac_pos = ct_bytes.len() - 32 + mac_offset;
        if mac_pos < ct_bytes.len() {
            ct_bytes[mac_pos] ^= 0xFF;
        }

        let tampered_ct = base64::engine::general_purpose::STANDARD.encode(&ct_bytes);
        let result = decrypt_nip44(&tampered_ct, &key);

        // Decryption should fail due to MAC verification
        prop_assert!(result.is_err(), "MAC-tampered ciphertext should not decrypt");
    }

    // ========================================================================
    // Ephemeral Keypair Security Properties
    // ========================================================================

    /// Property: Every generated keypair has a unique public key
    #[test]
    fn generated_keypairs_always_unique(
        _iteration in 0..10,
    ) {
        let keypair1 = EphemeralKeypair::generate();
        let keypair2 = EphemeralKeypair::generate();

        prop_assert_ne!(keypair1.pubkey_hex(), keypair2.pubkey_hex());
    }

    /// Property: Keypair from bytes is deterministic
    #[test]
    fn keypair_from_bytes_is_deterministic(
        secret in valid_secret_key_strategy(),
    ) {
        let kp1 = EphemeralKeypair::from_bytes(secret);
        let kp2 = EphemeralKeypair::from_bytes(secret);

        prop_assert!(kp1.is_ok());
        prop_assert!(kp2.is_ok());
        prop_assert_eq!(kp1.unwrap().pubkey_hex(), kp2.unwrap().pubkey_hex());
    }

    /// Property: Public key is always 64 hex characters
    #[test]
    fn pubkey_always_64_hex_chars(
        secret in valid_secret_key_strategy(),
    ) {
        let keypair = EphemeralKeypair::from_bytes(secret);
        prop_assume!(keypair.is_ok());

        let pubkey = keypair.unwrap().pubkey_hex();
        prop_assert_eq!(pubkey.len(), 64);
        prop_assert!(pubkey.chars().all(|c| c.is_ascii_hexdigit()));
    }

    /// Property: Signature is always 128 hex characters
    #[test]
    fn signature_always_128_hex_chars(
        secret in valid_secret_key_strategy(),
        message_hash in prop::array::uniform32(0u8..=255u8),
    ) {
        let keypair = EphemeralKeypair::from_bytes(secret);
        prop_assume!(keypair.is_ok());

        let sig = keypair.unwrap().sign(&message_hash);
        prop_assert!(sig.is_ok());
        prop_assert_eq!(sig.unwrap().len(), 128);
    }
}

// Additional test that doesn't use proptest macro for special cases
#[cfg(test)]
mod special_cases {
    use super::*;

    #[test]
    fn empty_string_encryption_fails() {
        let key = [0x42u8; 32];
        let result = encrypt_nip44("", &key);
        assert!(result.is_err());
    }

    #[test]
    fn all_zero_key_encryption_works() {
        // All zeros is technically a valid key for the encryption function
        // (the crypto library handles key validation)
        // This test documents the behavior
        let key = [0u8; 32];
        let result = encrypt_nip44("test", &key);
        // NIP-44 may or may not accept all-zero keys depending on implementation
        // We just verify it doesn't panic
        let _ = result;
    }

    #[test]
    fn invalid_base64_decryption_fails() {
        let key = [0x42u8; 32];
        let invalid_inputs = ["not base64!!!", "====", "a", "", " ", "\n\t"];

        for input in invalid_inputs {
            let result = decrypt_nip44(input, &key);
            assert!(result.is_err(), "Should fail for input: {:?}", input);
        }
    }

    #[test]
    fn keypair_from_curve_order_fails() {
        // secp256k1 curve order (invalid as secret key)
        let curve_order =
            hex::decode("FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141")
                .unwrap();
        let mut bytes = [0u8; 32];
        bytes.copy_from_slice(&curve_order);

        let result = EphemeralKeypair::from_bytes(bytes);
        assert!(result.is_err());
    }

    #[test]
    fn keypair_from_all_zeros_fails() {
        let bytes = [0u8; 32];
        let result = EphemeralKeypair::from_bytes(bytes);
        assert!(result.is_err());
    }

    #[test]
    fn keypair_from_all_ones_byte_succeeds() {
        let bytes = [0x01u8; 32];
        let result = EphemeralKeypair::from_bytes(bytes);
        assert!(result.is_ok());
    }
}
