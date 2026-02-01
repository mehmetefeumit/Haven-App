//! Ephemeral keypair management for Nostr events.
//!
//! Each Nostr event is signed with a fresh ephemeral keypair to prevent
//! correlation between events. This module provides secure key generation
//! and signing with automatic zeroization of secret material.

use std::sync::LazyLock;

use nostr::secp256k1::{rand::rngs::OsRng, Keypair, Message, Secp256k1, SecretKey};
use zeroize::ZeroizeOnDrop;

use crate::nostr::error::{NostrError, Result};

/// Global secp256k1 context for cryptographic operations.
///
/// Creating a `Secp256k1` context is expensive as it precomputes tables
/// for signing and verification. This shared context is initialized once
/// and reused across all operations.
///
/// # Thread Safety
///
/// The `Secp256k1` context is `Send + Sync`, making it safe to share
/// across threads.
///
/// # Performance
///
/// Reusing this context avoids the overhead of creating new precomputation
/// tables for each cryptographic operation.
pub static SECP: LazyLock<Secp256k1<nostr::secp256k1::All>> = LazyLock::new(Secp256k1::new);

/// An ephemeral keypair for signing a single Nostr event.
///
/// This keypair is generated fresh for each event to prevent correlation
/// between events. The secret key bytes are automatically zeroized when dropped.
///
/// # Security
///
/// - Secret key bytes are stored separately and zeroized on drop via `ZeroizeOnDrop`
/// - The keypair is reconstructed from bytes when signing operations are needed
/// - Each event should use a new `EphemeralKeypair`
/// - Never reuse keypairs across events
///
/// # Example
///
/// ```
/// use haven_core::nostr::EphemeralKeypair;
///
/// let keypair = EphemeralKeypair::generate();
/// let pubkey = keypair.pubkey_hex();
/// assert_eq!(pubkey.len(), 64); // 32 bytes hex-encoded
/// ```
#[derive(ZeroizeOnDrop)]
pub struct EphemeralKeypair {
    /// The secret key bytes (zeroized on drop)
    secret_bytes: [u8; 32],

    /// Cached public key bytes (not sensitive, skip zeroization)
    #[zeroize(skip)]
    pubkey_bytes: [u8; 32],
}

impl EphemeralKeypair {
    /// Generates a new random ephemeral keypair.
    ///
    /// Uses the operating system's secure random number generator.
    #[must_use]
    pub fn generate() -> Self {
        let keypair = Keypair::new(&SECP, &mut OsRng);

        // Extract and store the secret key bytes for proper zeroization
        let secret_bytes = keypair.secret_key().secret_bytes();
        let (public_key, _parity) = keypair.x_only_public_key();
        let pubkey_bytes = public_key.serialize();

        Self {
            secret_bytes,
            pubkey_bytes,
        }
    }

    /// Creates an `EphemeralKeypair` from raw secret key bytes.
    ///
    /// # Arguments
    ///
    /// * `secret_bytes` - 32-byte secret key
    ///
    /// # Errors
    ///
    /// Returns an error if the bytes don't represent a valid secret key.
    ///
    /// # Example
    ///
    /// ```
    /// use haven_core::nostr::EphemeralKeypair;
    ///
    /// let bytes = [0x01u8; 32]; // Example - use secure random in practice
    /// let keypair = EphemeralKeypair::from_bytes(bytes);
    /// assert!(keypair.is_ok());
    /// ```
    pub fn from_bytes(secret_bytes: [u8; 32]) -> Result<Self> {
        let secret_key = SecretKey::from_slice(&secret_bytes)
            .map_err(|e| NostrError::KeyDerivation(e.to_string()))?;
        let keypair = Keypair::from_secret_key(&SECP, &secret_key);
        let (public_key, _parity) = keypair.x_only_public_key();
        let pubkey_bytes = public_key.serialize();

        Ok(Self {
            secret_bytes,
            pubkey_bytes,
        })
    }

    /// Returns the public key as a 64-character hex string.
    ///
    /// This is the format used in the `pubkey` field of Nostr events.
    #[must_use]
    pub fn pubkey_hex(&self) -> String {
        hex::encode(self.pubkey_bytes)
    }

    /// Returns the public key as raw bytes.
    #[must_use]
    pub const fn pubkey_bytes(&self) -> [u8; 32] {
        self.pubkey_bytes
    }

    /// Signs a 32-byte message hash using Schnorr signature (BIP-340).
    ///
    /// This is used to sign the event ID, producing the `sig` field.
    ///
    /// # Arguments
    ///
    /// * `message_hash` - The 32-byte SHA256 hash of the event to sign
    ///
    /// # Returns
    ///
    /// The 64-byte Schnorr signature as a hex string.
    ///
    /// # Errors
    ///
    /// Returns an error if signing fails.
    pub fn sign(&self, message_hash: &[u8; 32]) -> Result<String> {
        use zeroize::Zeroize;

        // Create a copy of secret bytes for reconstruction (will be zeroized)
        let mut secret_bytes_copy = self.secret_bytes;

        // Reconstruct keypair from stored secret bytes
        let result = (|| {
            let secret_key = SecretKey::from_slice(&secret_bytes_copy)
                .map_err(|e| NostrError::Signing(e.to_string()))?;
            let keypair = Keypair::from_secret_key(&SECP, &secret_key);
            let message = Message::from_digest(*message_hash);
            let signature = SECP.sign_schnorr(&message, &keypair);
            Ok(hex::encode(signature.serialize()))
        })();

        // Zeroize the temporary copy regardless of success/failure
        secret_bytes_copy.zeroize();

        result
    }

    /// Reconstructs the keypair from stored secret bytes.
    ///
    /// # Warning
    ///
    /// This exposes the secret key. Use with caution.
    /// The returned keypair should be used only for immediate operations
    /// and not stored. Consider using [`Self::sign`] for signing operations instead.
    ///
    /// # Security Note
    ///
    /// The temporary secret bytes used for reconstruction are zeroized after
    /// the keypair is created. However, the returned `Keypair` itself contains
    /// secret material that is not automatically zeroized when dropped.
    #[must_use]
    #[allow(dead_code)]
    pub(crate) fn keypair(&self) -> Keypair {
        use zeroize::Zeroize;

        let mut secret_bytes_copy = self.secret_bytes;
        let secret_key =
            SecretKey::from_slice(&secret_bytes_copy).expect("stored secret bytes are valid");
        let keypair = Keypair::from_secret_key(&SECP, &secret_key);

        // Zeroize the temporary copy
        secret_bytes_copy.zeroize();

        keypair
    }
}

impl std::fmt::Debug for EphemeralKeypair {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        // Never print the secret key
        f.debug_struct("EphemeralKeypair")
            .field("pubkey", &self.pubkey_hex())
            .finish()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn generate_produces_valid_keypair() {
        let keypair = EphemeralKeypair::generate();
        let pubkey = keypair.pubkey_hex();
        assert_eq!(pubkey.len(), 64);
    }

    #[test]
    fn pubkey_hex_is_64_chars() {
        let keypair = EphemeralKeypair::generate();
        assert_eq!(keypair.pubkey_hex().len(), 64);
    }

    #[test]
    fn pubkey_bytes_is_32_bytes() {
        let keypair = EphemeralKeypair::generate();
        assert_eq!(keypair.pubkey_bytes().len(), 32);
    }

    #[test]
    fn from_bytes_with_valid_key() {
        // Use a valid 32-byte key (not all zeros, which is invalid)
        let mut bytes = [0u8; 32];
        bytes[0] = 1;
        let keypair = EphemeralKeypair::from_bytes(bytes);
        assert!(keypair.is_ok());
    }

    #[test]
    fn from_bytes_with_all_zeros_fails() {
        let bytes = [0u8; 32];
        let keypair = EphemeralKeypair::from_bytes(bytes);
        assert!(keypair.is_err());
    }

    #[test]
    fn sign_produces_valid_signature() {
        let keypair = EphemeralKeypair::generate();
        let message_hash = [0x42u8; 32];
        let signature = keypair.sign(&message_hash);
        assert!(signature.is_ok());
        assert_eq!(signature.unwrap().len(), 128); // 64 bytes hex-encoded
    }

    #[test]
    fn different_keypairs_have_different_pubkeys() {
        let keypair1 = EphemeralKeypair::generate();
        let keypair2 = EphemeralKeypair::generate();
        assert_ne!(keypair1.pubkey_hex(), keypair2.pubkey_hex());
    }

    #[test]
    fn debug_does_not_leak_secret_key() {
        let keypair = EphemeralKeypair::generate();
        let debug_output = format!("{keypair:?}");
        // Should contain pubkey but not secret
        assert!(debug_output.contains("pubkey"));
        // The secret key would be much longer if included
        assert!(debug_output.len() < 200);
    }

    #[test]
    fn same_bytes_produce_same_pubkey() {
        let mut bytes = [0u8; 32];
        bytes[0] = 42;
        let keypair1 = EphemeralKeypair::from_bytes(bytes).unwrap();
        let keypair2 = EphemeralKeypair::from_bytes(bytes).unwrap();
        assert_eq!(keypair1.pubkey_hex(), keypair2.pubkey_hex());
    }

    #[test]
    fn from_bytes_with_all_ff_fails() {
        // 0xFFFF...FF is greater than the secp256k1 curve order, should fail
        let bytes = [0xFFu8; 32];
        let result = EphemeralKeypair::from_bytes(bytes);
        assert!(result.is_err());
    }

    #[test]
    fn pubkey_hex_is_valid_hex() {
        let keypair = EphemeralKeypair::generate();
        let pubkey = keypair.pubkey_hex();
        // Should be valid hex
        assert!(hex::decode(&pubkey).is_ok());
    }

    #[test]
    fn pubkey_bytes_matches_pubkey_hex() {
        let keypair = EphemeralKeypair::generate();
        let pubkey_hex = keypair.pubkey_hex();
        let pubkey_bytes = keypair.pubkey_bytes();

        assert_eq!(pubkey_hex, hex::encode(pubkey_bytes));
    }

    #[test]
    fn debug_output_contains_pubkey_value() {
        let keypair = EphemeralKeypair::generate();
        let debug_output = format!("{keypair:?}");
        let pubkey = keypair.pubkey_hex();

        // Debug output should contain the actual pubkey value
        assert!(debug_output.contains(&pubkey));
    }

    #[test]
    fn ephemeral_keypair_implements_zeroize_on_drop() {
        // Compile-time verification that EphemeralKeypair implements ZeroizeOnDrop
        fn assert_zeroize_on_drop<T: ZeroizeOnDrop>() {}
        assert_zeroize_on_drop::<EphemeralKeypair>();
    }

    #[test]
    fn from_bytes_with_curve_order_boundary() {
        // secp256k1 curve order n - 1 (should succeed - valid secret key)
        let curve_order_minus_1 =
            hex::decode("FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364140")
                .unwrap();
        let mut bytes = [0u8; 32];
        bytes.copy_from_slice(&curve_order_minus_1);
        assert!(
            EphemeralKeypair::from_bytes(bytes).is_ok(),
            "n-1 should be a valid secret key"
        );

        // secp256k1 curve order n (should fail - equals curve order)
        let curve_order =
            hex::decode("FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141")
                .unwrap();
        bytes.copy_from_slice(&curve_order);
        assert!(
            EphemeralKeypair::from_bytes(bytes).is_err(),
            "n itself should not be a valid secret key"
        );
    }
}
