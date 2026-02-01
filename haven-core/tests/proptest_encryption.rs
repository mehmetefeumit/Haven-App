//! Property-based tests for encryption operations.
//!
//! These tests use proptest to verify invariants that should hold for any valid input,
//! helping catch edge cases and subtle bugs that might not be found by unit tests alone.
//!
//! Note: Location event encryption/decryption tests require MDK infrastructure and are
//! covered in the integration tests. This file focuses on the lower-level NIP-44 encryption.

use haven_core::nostr::encryption::{decrypt_nip44, encrypt_nip44};
use proptest::prelude::*;

/// Strategy to generate non-empty ASCII strings (for plaintext)
fn plaintext_strategy() -> impl Strategy<Value = String> {
    "[a-zA-Z0-9 ]{1,1000}".prop_filter("non-empty", |s| !s.is_empty())
}

/// Strategy to generate valid 32-byte keys (non-zero)
fn key_strategy() -> impl Strategy<Value = [u8; 32]> {
    prop::array::uniform32(1u8..=255u8)
}

proptest! {
    /// Property: Encryption followed by decryption should yield the original plaintext
    #[test]
    fn encrypt_decrypt_roundtrip(
        plaintext in plaintext_strategy(),
        key in key_strategy(),
    ) {
        let ciphertext = encrypt_nip44(&plaintext, &key).expect("encryption should succeed");
        let decrypted = decrypt_nip44(&ciphertext, &key).expect("decryption should succeed");
        prop_assert_eq!(plaintext, decrypted);
    }

    /// Property: Encrypted content should never contain the plaintext
    #[test]
    fn ciphertext_never_contains_plaintext(
        plaintext in "[a-zA-Z]{10,100}",
        key in key_strategy(),
    ) {
        let ciphertext = encrypt_nip44(&plaintext, &key).expect("encryption should succeed");
        // Ciphertext is base64 encoded, but we check it doesn't contain plaintext
        prop_assert!(!ciphertext.contains(&plaintext),
            "Ciphertext should not contain plaintext");
    }

    /// Property: Same plaintext with same key should produce different ciphertexts
    /// (due to random nonce in NIP-44)
    #[test]
    fn encryption_is_randomized(
        plaintext in plaintext_strategy(),
        key in key_strategy(),
    ) {
        let ciphertext1 = encrypt_nip44(&plaintext, &key).expect("encryption should succeed");
        let ciphertext2 = encrypt_nip44(&plaintext, &key).expect("encryption should succeed");
        // NIP-44 uses random nonces, so ciphertexts should differ
        prop_assert_ne!(ciphertext1, ciphertext2,
            "Same plaintext should produce different ciphertexts due to random nonce");
    }

    /// Property: Decryption with wrong key should fail
    #[test]
    fn wrong_key_fails_decryption(
        plaintext in plaintext_strategy(),
        key1 in key_strategy(),
        key2 in key_strategy(),
    ) {
        prop_assume!(key1 != key2);
        let ciphertext = encrypt_nip44(&plaintext, &key1).expect("encryption should succeed");
        let result = decrypt_nip44(&ciphertext, &key2);
        prop_assert!(result.is_err(), "Decryption with wrong key should fail");
    }

    /// Property: Ciphertext length is always larger than plaintext
    #[test]
    fn ciphertext_larger_than_plaintext(
        plaintext in plaintext_strategy(),
        key in key_strategy(),
    ) {
        let ciphertext = encrypt_nip44(&plaintext, &key).expect("encryption should succeed");
        // Ciphertext includes nonce, padding, and MAC
        prop_assert!(ciphertext.len() > plaintext.len(),
            "Ciphertext should be larger than plaintext due to overhead");
    }

    /// Property: Decryption is deterministic - same ciphertext always decrypts to same plaintext
    #[test]
    fn decryption_is_deterministic(
        plaintext in plaintext_strategy(),
        key in key_strategy(),
    ) {
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

    /// Property: Different keys always produce different ciphertexts for same plaintext
    #[test]
    fn different_keys_produce_different_ciphertexts(
        plaintext in "[a-zA-Z]{20,50}",
        key1 in key_strategy(),
        key2 in key_strategy(),
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

    /// Property: Tampering with the MAC portion of ciphertext causes decryption failure
    #[test]
    fn mac_tampering_causes_decryption_failure(
        plaintext in "[a-zA-Z]{20,50}",
        key in key_strategy(),
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
}
