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
use zeroize::Zeroizing;

/// Strategy for generating 32-byte keys with various characteristics, wrapped in `Zeroizing`
fn diverse_key_strategy() -> impl Strategy<Value = Zeroizing<[u8; 32]>> {
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
    .prop_map(Zeroizing::new)
}

/// Strategy for generating plaintext of various lengths
fn diverse_plaintext_strategy() -> impl Strategy<Value = String> {
    prop_oneof![
        // Single character
        "[a-zA-Z0-9]",
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

/// Strategy for valid secret key bytes (non-zero, below curve order).
///
/// Every byte is drawn from `1..=254`, so the array is always non-zero and
/// strictly below the secp256k1 curve order
/// (`FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141`):
/// the most-significant byte can never reach `0xFF`. No `prop_filter` is
/// needed — the range itself guarantees validity (the previous "non-zero"
/// filter could never fire and was dead code).
fn valid_secret_key_strategy() -> impl Strategy<Value = [u8; 32]> {
    prop::array::uniform32(1u8..=254u8)
}

/// The secp256k1 group order `n` as 32 big-endian bytes. Secret keys must lie
/// in `[1, n-1]`; `0` and any value `>= n` are invalid.
const SECP256K1_ORDER: [u8; 32] = [
    0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFE,
    0xBA, 0xAE, 0xDC, 0xE6, 0xAF, 0x48, 0xA0, 0x3B, 0xBF, 0xD2, 0x5E, 0x8C, 0xD0, 0x36, 0x41, 0x41,
];

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

    /// Property: the ciphertext never contains the plaintext as a substring.
    /// (Consolidated from the former `proptest_encryption.rs`, now exercised
    /// with the richer `diverse_key_strategy`. Plaintext is >=10 alpha chars so
    /// it cannot coincidentally appear within the base64 ciphertext.)
    #[test]
    fn ciphertext_never_contains_plaintext(
        plaintext in "[a-zA-Z]{10,100}",
        key in diverse_key_strategy(),
    ) {
        let ciphertext = encrypt_nip44(&plaintext, &key).expect("encryption should succeed");
        prop_assert!(
            !ciphertext.contains(&plaintext),
            "ciphertext must not contain the plaintext"
        );
    }

    /// Property: encrypting the same plaintext+key twice yields different
    /// ciphertexts (NIP-44 random nonce). (Consolidated from the former
    /// `proptest_encryption.rs`.)
    #[test]
    fn encryption_is_randomized(
        plaintext in diverse_plaintext_strategy(),
        key in diverse_key_strategy(),
    ) {
        prop_assume!(!plaintext.is_empty());
        let ct1 = encrypt_nip44(&plaintext, &key).expect("encryption should succeed");
        let ct2 = encrypt_nip44(&plaintext, &key).expect("encryption should succeed");
        prop_assert_ne!(ct1, ct2, "random nonce must make repeated ciphertexts differ");
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

    /// Property (RP-2): Decrypting with a key different from the one used to
    /// encrypt must fail. NIP-44's AEAD MAC is keyed by the conversation key,
    /// so a wrong key cannot verify the tag. The security-named file
    /// previously lacked this core confidentiality check.
    #[test]
    fn wrong_key_fails_decryption(
        plaintext in diverse_plaintext_strategy(),
        key1 in diverse_key_strategy(),
        key2 in diverse_key_strategy(),
    ) {
        prop_assume!(!plaintext.is_empty());
        prop_assume!(key1 != key2);

        let ciphertext = encrypt_nip44(&plaintext, &key1).expect("encryption should succeed");
        let result = decrypt_nip44(&ciphertext, &key2);

        prop_assert!(
            result.is_err(),
            "ciphertext encrypted under key1 must not decrypt under a different key2"
        );
    }

    /// Property (RP-3): Flipping any single byte of the 32-byte NIP-44 v2
    /// nonce (payload bytes `1..33`) causes decryption to fail. The nonce is
    /// authenticated by the MAC, so any alteration must be detected. Mirrors
    /// `d4_nonce_tampering_detected` in `proptest_encryption.rs` but over the
    /// diverse key strategy used here.
    #[test]
    fn nonce_tampering_causes_decryption_failure(
        plaintext in "[a-zA-Z]{20,50}",
        key in diverse_key_strategy(),
        nonce_offset in 0usize..32,
    ) {
        use base64::Engine;

        let ciphertext = encrypt_nip44(&plaintext, &key).expect("encryption succeeds");
        let mut ct_bytes = base64::engine::general_purpose::STANDARD
            .decode(&ciphertext)
            .expect("valid base64");

        // NIP-44 v2 layout: byte 0 = version, bytes 1..33 = nonce.
        prop_assume!(ct_bytes.len() > 33);

        let tamper_pos = 1 + nonce_offset;
        ct_bytes[tamper_pos] ^= 0xFF;

        let tampered_ct = base64::engine::general_purpose::STANDARD.encode(&ct_bytes);
        let result = decrypt_nip44(&tampered_ct, &key);

        prop_assert!(
            result.is_err(),
            "nonce-tampered ciphertext at offset {nonce_offset} must not decrypt"
        );
    }

    /// Property (RP-4): Encrypt→decrypt is the identity over the *diverse*
    /// plaintext strategy — unicode, JSON-shaped, control-free multi-script
    /// text, and long strings — not just ASCII. The `diverse_plaintext_strategy`
    /// never yields the empty string; the empty-string branch asserts the
    /// documented source contract that NIP-44 rejects empty plaintext rather
    /// than forcing a false round-trip.
    #[test]
    fn encrypt_decrypt_identity_over_diverse_plaintext(
        plaintext in diverse_plaintext_strategy(),
        key in diverse_key_strategy(),
    ) {
        if plaintext.is_empty() {
            // Source contract: NIP-44 v2 rejects empty plaintext.
            prop_assert!(
                encrypt_nip44(&plaintext, &key).is_err(),
                "empty plaintext must be rejected by NIP-44"
            );
        } else {
            let ciphertext = encrypt_nip44(&plaintext, &key).expect("encryption should succeed");
            let decrypted = decrypt_nip44(&ciphertext, &key).expect("decryption should succeed");
            prop_assert_eq!(decrypted, plaintext);
        }
    }

    /// Property (RP-5): Flipping ANY single byte in the authenticated region
    /// of the NIP-44 v2 payload — the nonce, the padded ciphertext, OR the
    /// MAC (payload bytes `1..len`) — causes decryption to fail. This is the
    /// whole-AEAD integrity guarantee and a strict superset of the MAC-only
    /// (`len-32..len`) and nonce-only (`1..33`) tamper properties.
    ///
    /// Byte 0 (the version tag) is deliberately excluded: Haven calls
    /// `nip44::v2::decrypt_to_bytes`, whose HMAC authenticates only
    /// `nonce || ciphertext` (verified against the source — it slices
    /// `payload[1..33]`, `payload[33..len-32]`, `payload[len-32..]` and never
    /// reads byte 0). Asserting a byte-0 flip must fail would be a *false*
    /// assertion, not a stronger one; the offset therefore ranges over
    /// `1..len`, covering every authenticated byte.
    #[test]
    fn any_authenticated_byte_tamper_causes_decryption_failure(
        plaintext in "[a-zA-Z]{20,80}",
        key in diverse_key_strategy(),
        offset_seed in any::<prop::sample::Index>(),
        flip_mask in 1u8..=255u8,
    ) {
        use base64::Engine;

        let ciphertext = encrypt_nip44(&plaintext, &key).expect("encryption succeeds");
        let mut ct_bytes = base64::engine::general_purpose::STANDARD
            .decode(&ciphertext)
            .expect("valid base64");

        // Need at least version(1) + nonce(32) + len-prefix-ish + MAC(32).
        prop_assume!(ct_bytes.len() > 33);

        // Pick an arbitrary byte in the authenticated region [1, len) and
        // flip >= 1 bit (flip_mask is never 0).
        let span = ct_bytes.len() - 1;
        let pos = 1 + offset_seed.index(span);
        ct_bytes[pos] ^= flip_mask;

        let tampered_ct = base64::engine::general_purpose::STANDARD.encode(&ct_bytes);
        let result = decrypt_nip44(&tampered_ct, &key);

        prop_assert!(
            result.is_err(),
            "tampering authenticated byte {pos}/{} must not decrypt successfully",
            ct_bytes.len()
        );
    }

    // ========================================================================
    // Ephemeral Keypair Security Properties
    // ========================================================================

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

    /// Property (RP-8): An `EphemeralKeypair` signature is not merely
    /// well-formed (128 hex chars) but *cryptographically valid* — it
    /// verifies under BIP-340 Schnorr against the keypair's own x-only public
    /// key over the exact message hash that was signed. A signer that emitted
    /// well-formed-but-invalid signatures (e.g. signing garbage, or with the
    /// wrong key) passes `signature_always_128_hex_chars` but fails here.
    /// Additionally, the *same* signature must FAIL verification against a
    /// different (tampered) message hash, proving the signature actually binds
    /// to the message rather than validating unconditionally.
    #[test]
    fn ephemeral_signature_verifies_and_binds_to_message(
        secret in valid_secret_key_strategy(),
        message_hash in prop::array::uniform32(0u8..=255u8),
        tamper_byte in 0usize..32,
        tamper_mask in 1u8..=255u8,
    ) {
        use nostr::secp256k1::{schnorr::Signature, Message, Secp256k1, XOnlyPublicKey};

        let keypair = EphemeralKeypair::from_bytes(secret);
        prop_assume!(keypair.is_ok());
        let keypair = keypair.unwrap();

        let signature_hex = keypair.sign(&message_hash).expect("signing must succeed");
        let sig_bytes = hex::decode(&signature_hex).expect("signature must be valid hex");
        let signature = Signature::from_slice(&sig_bytes).expect("64-byte Schnorr signature");

        // The verifier reconstructs the public key only from the public bytes
        // exposed by the keypair — no secret material is touched here.
        let pubkey = XOnlyPublicKey::from_slice(&keypair.pubkey_bytes())
            .expect("x-only public key from 32 bytes");

        let secp = Secp256k1::verification_only();

        // Correct message: signature MUST verify.
        let signed_msg = Message::from_digest(message_hash);
        prop_assert!(
            secp.verify_schnorr(&signature, &signed_msg, &pubkey).is_ok(),
            "a genuine Schnorr signature must verify against its own public key"
        );

        // Tampered message: the SAME signature MUST NOT verify, proving the
        // signature binds to the specific message hash.
        let mut tampered_hash = message_hash;
        tampered_hash[tamper_byte] ^= tamper_mask;
        let tampered_msg = Message::from_digest(tampered_hash);
        prop_assert!(
            secp.verify_schnorr(&signature, &tampered_msg, &pubkey).is_err(),
            "signature must not verify against a tampered message hash"
        );
    }

    /// Property (RP-6): An arbitrary interior scalar in `[1, 2^128)` — which
    /// is strictly inside the valid secret-key range `[1, n-1]` since
    /// `2^128 < n` — is always accepted and derives a public key, while a
    /// scalar built one step *past* the curve order (`n + delta`) is always
    /// rejected. The existing strategy never approaches the scalar-field
    /// edge; this drives `SecretKey::from_slice`'s range check directly.
    #[test]
    fn secret_key_interior_valid_and_overflow_rejected(
        low in 1u128..=u128::MAX,
        delta in 0u8..=0xBE, // n + delta stays below n's next byte-carry boundary
    ) {
        // Interior scalar: low 16 bytes hold a nonzero u128, high 16 are zero.
        let mut interior = [0u8; 32];
        interior[16..].copy_from_slice(&low.to_be_bytes());
        prop_assert!(
            EphemeralKeypair::from_bytes(interior).is_ok(),
            "scalar in [1, 2^128) must be a valid secp256k1 secret key"
        );

        // n + delta: increment the least-significant byte of the curve order.
        // The order ends in 0x41, so adding delta (<= 0xBE) cannot carry.
        let mut overflow = SECP256K1_ORDER;
        overflow[31] = overflow[31].wrapping_add(delta);
        prop_assert!(
            EphemeralKeypair::from_bytes(overflow).is_err(),
            "scalar >= curve order n must be rejected"
        );
    }
}

// ============================================================================
// RP-6: deterministic secp256k1 scalar-field boundary values
// ============================================================================

/// The exact scalar-field edges, asserted deterministically alongside the
/// randomized property above: `1` and `n-1` are valid secret keys; `0`, `n`,
/// and `n+1` are not. A regression that shifted the inclusive/exclusive
/// boundary (e.g. accepting `n` or rejecting `n-1`) fails here.
#[test]
fn secret_key_scalar_field_boundaries() {
    // 1 — minimum valid secret key.
    let mut one = [0u8; 32];
    one[31] = 1;
    assert!(
        EphemeralKeypair::from_bytes(one).is_ok(),
        "scalar 1 must be valid"
    );

    // n - 1 — maximum valid secret key.
    let mut n_minus_1 = SECP256K1_ORDER;
    n_minus_1[31] -= 1;
    assert!(
        EphemeralKeypair::from_bytes(n_minus_1).is_ok(),
        "scalar n-1 must be valid"
    );

    // 0 — invalid (no inverse / not in [1, n-1]).
    assert!(
        EphemeralKeypair::from_bytes([0u8; 32]).is_err(),
        "scalar 0 must be rejected"
    );

    // n — invalid (equals the group order).
    assert!(
        EphemeralKeypair::from_bytes(SECP256K1_ORDER).is_err(),
        "scalar n must be rejected"
    );

    // n + 1 — invalid (beyond the group order; last byte 0x41 -> 0x42, no carry).
    let mut n_plus_1 = SECP256K1_ORDER;
    n_plus_1[31] += 1;
    assert!(
        EphemeralKeypair::from_bytes(n_plus_1).is_err(),
        "scalar n+1 must be rejected"
    );
}

/// RP-7: Real uniqueness test (replaces the prior proptest whose only input,
/// `_iteration`, was ignored — generating the same two keypairs every case).
/// Collects `N` freshly generated ephemeral public keys into a `HashSet` and
/// asserts the set size equals `N`: any collision (a broken RNG) shrinks the
/// set and fails the assertion.
#[test]
fn generated_keypairs_always_unique() {
    use std::collections::HashSet;

    const N: usize = 256;
    let pubkeys: HashSet<String> = (0..N)
        .map(|_| EphemeralKeypair::generate().pubkey_hex())
        .collect();

    assert_eq!(
        pubkeys.len(),
        N,
        "all {N} generated keypairs must have distinct public keys"
    );
}

// Additional test that doesn't use proptest macro for special cases
#[cfg(test)]
mod special_cases {
    use super::*;

    #[test]
    fn empty_string_encryption_fails() {
        let key = Zeroizing::new([0x42u8; 32]);
        let result = encrypt_nip44("", &key);
        assert!(result.is_err());
    }

    #[test]
    fn all_zero_key_encryption_roundtrips() {
        // NIP-44 v2 treats the 32-byte conversation key as a *symmetric* key
        // fed directly into HKDF/ChaCha20 (see `encrypt_nip44` in
        // `src/nostr/encryption/mod.rs`, which calls `ConversationKey::new`
        // with the raw bytes). Unlike an secp256k1 *secret* scalar, there is no
        // curve-order range check, so an all-zero key is accepted. Assert the
        // exact behavior: encryption succeeds AND an encrypt -> decrypt cycle
        // recovers the plaintext under the same all-zero key.
        let key = Zeroizing::new([0u8; 32]);
        let plaintext = "test";

        let ciphertext = encrypt_nip44(plaintext, &key)
            .expect("NIP-44 v2 accepts an all-zero 32-byte symmetric key");
        let decrypted = decrypt_nip44(&ciphertext, &key)
            .expect("round-trip under the all-zero key must decrypt");

        assert_eq!(
            decrypted, plaintext,
            "encrypt -> decrypt under an all-zero key must recover the plaintext"
        );
    }

    #[test]
    fn invalid_base64_decryption_fails() {
        let key = Zeroizing::new([0x42u8; 32]);
        let invalid_inputs = ["not base64!!!", "====", "a", "", " ", "\n\t"];

        for input in invalid_inputs {
            let result = decrypt_nip44(input, &key);
            assert!(result.is_err(), "Should fail for input: {input:?}");
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
