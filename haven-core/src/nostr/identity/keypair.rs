//! Persistent identity keypair for Nostr operations.
//!
//! This module provides [`IdentityKeypair`], a long-lived keypair for the user's
//! Nostr identity. Unlike [`EphemeralKeypair`](crate::nostr::EphemeralKeypair),
//! this keypair is designed for persistence across sessions.
//!
//! # Security
//!
//! - Secret bytes are automatically zeroized on drop via [`ZeroizeOnDrop`]
//! - Temporary copies are manually zeroized after use
//! - Debug output never includes secret material
//! - This key is separate from MLS signing keys (MDK manages those internally)
//!
//! # Key Separation (Marmot Protocol)
//!
//! Per MIP-00, this Nostr identity key is used for:
//! - Signing `KeyPackage` events (kind 443)
//! - Nostr protocol operations (profile, follows, etc.)
//!
//! MLS signing keys are generated and managed internally by MDK.
//! Compromise of this Nostr identity key does NOT compromise MLS group messages.

use nostr::prelude::{Keys, PublicKey, ToBech32};
use nostr::secp256k1::{Keypair, Message, SecretKey as Secp256k1SecretKey};
use nostr::SecretKey as NostrSecretKey;
use zeroize::{Zeroize, ZeroizeOnDrop, Zeroizing};

use super::IdentityError;
use crate::nostr::keys::SECP;

/// A persistent Nostr identity keypair.
///
/// This represents the user's long-lived Nostr identity (nsec/npub).
/// The secret key bytes are automatically zeroized when dropped.
///
/// # Security
///
/// - Secret bytes are stored separately and zeroized on drop via `ZeroizeOnDrop`
/// - The keypair is reconstructed from bytes when signing operations are needed
/// - Use [`Self::export_nsec`] only for user-initiated backup
///
/// # Example
///
/// ```
/// use haven_core::nostr::identity::IdentityKeypair;
///
/// // Generate a new identity
/// let keypair = IdentityKeypair::generate();
/// println!("Your npub: {}", keypair.npub().unwrap());
///
/// // Export for backup (handle with care!)
/// let nsec = keypair.export_nsec().unwrap();
/// assert!(nsec.starts_with("nsec1"));
/// ```
#[derive(ZeroizeOnDrop)]
pub struct IdentityKeypair {
    /// The secret key bytes (zeroized on drop).
    secret_bytes: [u8; 32],

    /// Cached public key bytes (not sensitive, skip zeroization).
    #[zeroize(skip)]
    pubkey_bytes: [u8; 32],
}

impl IdentityKeypair {
    /// Generates a new random identity keypair.
    ///
    /// Uses the operating system's secure random number generator.
    ///
    /// # Example
    ///
    /// ```
    /// use haven_core::nostr::identity::IdentityKeypair;
    ///
    /// let keypair = IdentityKeypair::generate();
    /// assert_eq!(keypair.pubkey_hex().len(), 64);
    /// ```
    #[must_use]
    pub fn generate() -> Self {
        let keys = Keys::generate();

        let secret_bytes = keys.secret_key().secret_bytes();
        let pubkey_bytes = keys.public_key().to_bytes();

        Self {
            secret_bytes,
            pubkey_bytes,
        }
    }

    /// Creates an identity keypair from raw secret key bytes.
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
    /// use haven_core::nostr::identity::IdentityKeypair;
    ///
    /// let mut bytes = [0u8; 32];
    /// bytes[0] = 1; // All zeros is invalid
    /// let keypair = IdentityKeypair::from_secret_bytes(bytes);
    /// assert!(keypair.is_ok());
    /// ```
    pub fn from_secret_bytes(secret_bytes: [u8; 32]) -> Result<Self, IdentityError> {
        let secret_key = Secp256k1SecretKey::from_slice(&secret_bytes)
            .map_err(|e| IdentityError::KeyDerivation(e.to_string()))?;

        let keypair = Keypair::from_secret_key(&SECP, &secret_key);
        let (public_key, _parity) = keypair.x_only_public_key();
        let pubkey_bytes = public_key.serialize();

        Ok(Self {
            secret_bytes,
            pubkey_bytes,
        })
    }

    /// Imports an identity from an nsec (NIP-19 bech32-encoded secret key).
    ///
    /// # Arguments
    ///
    /// * `nsec` - Bech32-encoded secret key starting with "nsec1"
    ///
    /// # Errors
    ///
    /// Returns an error if the nsec is invalid or malformed.
    ///
    /// # Example
    ///
    /// ```
    /// use haven_core::nostr::identity::IdentityKeypair;
    ///
    /// // Generate and export, then reimport
    /// let original = IdentityKeypair::generate();
    /// let nsec = original.export_nsec().unwrap();
    ///
    /// let imported = IdentityKeypair::from_nsec(&nsec).unwrap();
    /// assert_eq!(original.pubkey_hex(), imported.pubkey_hex());
    /// ```
    pub fn from_nsec(nsec: &str) -> Result<Self, IdentityError> {
        let keys = Keys::parse(nsec).map_err(|e| IdentityError::InvalidNsec(e.to_string()))?;

        let secret_bytes = keys.secret_key().secret_bytes();
        let pubkey_bytes = keys.public_key().to_bytes();

        Ok(Self {
            secret_bytes,
            pubkey_bytes,
        })
    }

    /// Exports the secret key as nsec (NIP-19 bech32 format).
    ///
    /// # Security Warning
    ///
    /// This exposes the secret key. Only use for user-initiated backup.
    /// The returned string should be handled with extreme care.
    ///
    /// # Errors
    ///
    /// Returns an error if bech32 encoding fails.
    ///
    /// # Example
    ///
    /// ```
    /// use haven_core::nostr::identity::IdentityKeypair;
    ///
    /// let keypair = IdentityKeypair::generate();
    /// let nsec = keypair.export_nsec().unwrap();
    /// assert!(nsec.starts_with("nsec1"));
    /// ```
    pub fn export_nsec(&self) -> Result<String, IdentityError> {
        let mut secret_bytes_copy = self.secret_bytes;

        let result = (|| {
            let secret_key = NostrSecretKey::from_slice(&secret_bytes_copy)
                .map_err(|e| IdentityError::KeyDerivation(e.to_string()))?;

            let keys = Keys::new(secret_key);
            keys.secret_key()
                .to_bech32()
                .map_err(|e| IdentityError::Bech32(e.to_string()))
        })();

        // Zeroize temporary copy
        secret_bytes_copy.zeroize();

        result
    }

    /// Returns the public key as a 64-character hex string.
    ///
    /// This format is used in Nostr event `pubkey` fields and for MDK operations.
    ///
    /// # Example
    ///
    /// ```
    /// use haven_core::nostr::identity::IdentityKeypair;
    ///
    /// let keypair = IdentityKeypair::generate();
    /// let hex = keypair.pubkey_hex();
    /// assert_eq!(hex.len(), 64);
    /// ```
    #[must_use]
    pub fn pubkey_hex(&self) -> String {
        hex::encode(self.pubkey_bytes)
    }

    /// Returns the public key as npub (NIP-19 bech32 format).
    ///
    /// This is the human-readable format for sharing public keys.
    ///
    /// # Errors
    ///
    /// Returns an error if bech32 encoding fails.
    ///
    /// # Example
    ///
    /// ```
    /// use haven_core::nostr::identity::IdentityKeypair;
    ///
    /// let keypair = IdentityKeypair::generate();
    /// let npub = keypair.npub().unwrap();
    /// assert!(npub.starts_with("npub1"));
    /// ```
    pub fn npub(&self) -> Result<String, IdentityError> {
        let pubkey = PublicKey::from_slice(&self.pubkey_bytes)
            .map_err(|e| IdentityError::KeyDerivation(e.to_string()))?;

        pubkey
            .to_bech32()
            .map_err(|e| IdentityError::Bech32(e.to_string()))
    }

    /// Returns the raw public key bytes.
    ///
    /// # Example
    ///
    /// ```
    /// use haven_core::nostr::identity::IdentityKeypair;
    ///
    /// let keypair = IdentityKeypair::generate();
    /// assert_eq!(keypair.pubkey_bytes().len(), 32);
    /// ```
    #[must_use]
    pub const fn pubkey_bytes(&self) -> [u8; 32] {
        self.pubkey_bytes
    }

    /// Signs a 32-byte message hash using Schnorr signature (BIP-340).
    ///
    /// This is used to sign event IDs for Nostr events.
    ///
    /// # Arguments
    ///
    /// * `message_hash` - The 32-byte SHA256 hash of the message to sign
    ///
    /// # Returns
    ///
    /// The 64-byte Schnorr signature as a 128-character hex string.
    ///
    /// # Errors
    ///
    /// Returns an error if signing fails.
    ///
    /// # Example
    ///
    /// ```
    /// use haven_core::nostr::identity::IdentityKeypair;
    ///
    /// let keypair = IdentityKeypair::generate();
    /// let message_hash = [0x42u8; 32];
    /// let signature = keypair.sign(&message_hash).unwrap();
    /// assert_eq!(signature.len(), 128); // 64 bytes hex-encoded
    /// ```
    pub fn sign(&self, message_hash: &[u8; 32]) -> Result<String, IdentityError> {
        let mut secret_bytes_copy = self.secret_bytes;

        let result = (|| {
            let secret_key = Secp256k1SecretKey::from_slice(&secret_bytes_copy)
                .map_err(|e| IdentityError::Signing(e.to_string()))?;

            let keypair = Keypair::from_secret_key(&SECP, &secret_key);
            let message = Message::from_digest(*message_hash);
            let signature = SECP.sign_schnorr(&message, &keypair);

            Ok(hex::encode(signature.serialize()))
        })();

        // Zeroize temporary copy
        secret_bytes_copy.zeroize();

        result
    }

    /// Returns the raw secret key bytes for storage, wrapped in `Zeroizing`.
    ///
    /// # Security Warning
    ///
    /// This is `pub(crate)` to limit exposure. The returned bytes are
    /// automatically zeroized when the `Zeroizing` wrapper is dropped.
    #[must_use]
    pub(crate) fn secret_bytes(&self) -> Zeroizing<[u8; 32]> {
        Zeroizing::new(self.secret_bytes)
    }
}

impl std::fmt::Debug for IdentityKeypair {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        // Never print the secret key
        f.debug_struct("IdentityKeypair")
            .field("pubkey", &self.pubkey_hex())
            .finish()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn generate_produces_valid_keypair() {
        let keypair = IdentityKeypair::generate();
        assert_eq!(keypair.pubkey_hex().len(), 64);
        assert_eq!(keypair.pubkey_bytes().len(), 32);
    }

    #[test]
    fn from_secret_bytes_with_valid_key() {
        let mut bytes = [0u8; 32];
        bytes[0] = 1;
        let keypair = IdentityKeypair::from_secret_bytes(bytes);
        assert!(keypair.is_ok());
    }

    #[test]
    fn from_secret_bytes_with_all_zeros_fails() {
        let bytes = [0u8; 32];
        let result = IdentityKeypair::from_secret_bytes(bytes);
        assert!(result.is_err());
    }

    #[test]
    fn from_secret_bytes_with_curve_order_fails() {
        // secp256k1 curve order n (invalid as secret key)
        let curve_order =
            hex::decode("FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141")
                .unwrap();
        let mut bytes = [0u8; 32];
        bytes.copy_from_slice(&curve_order);
        assert!(IdentityKeypair::from_secret_bytes(bytes).is_err());
    }

    #[test]
    fn nsec_roundtrip() {
        let original = IdentityKeypair::generate();
        let nsec = original.export_nsec().unwrap();

        assert!(nsec.starts_with("nsec1"));

        let imported = IdentityKeypair::from_nsec(&nsec).unwrap();
        assert_eq!(original.pubkey_hex(), imported.pubkey_hex());
    }

    #[test]
    fn from_nsec_with_invalid_string_fails() {
        assert!(IdentityKeypair::from_nsec("invalid").is_err());
        assert!(IdentityKeypair::from_nsec("nsec1invalid").is_err());
        assert!(IdentityKeypair::from_nsec("").is_err());
    }

    #[test]
    fn npub_format() {
        let keypair = IdentityKeypair::generate();
        let npub = keypair.npub().unwrap();
        assert!(npub.starts_with("npub1"));
    }

    #[test]
    fn sign_produces_valid_signature() {
        let keypair = IdentityKeypair::generate();
        let message_hash = [0x42u8; 32];
        let signature = keypair.sign(&message_hash).unwrap();

        assert_eq!(signature.len(), 128); // 64 bytes hex-encoded
        assert!(hex::decode(&signature).is_ok());
    }

    #[test]
    fn signature_verifies_correctly() {
        use nostr::secp256k1::{schnorr::Signature, Message, XOnlyPublicKey};

        let keypair = IdentityKeypair::generate();
        let message_hash = [0x42u8; 32];
        let signature_hex = keypair.sign(&message_hash).unwrap();

        // Parse signature
        let sig_bytes = hex::decode(&signature_hex).unwrap();
        let signature = Signature::from_slice(&sig_bytes).unwrap();

        // Parse public key
        let pubkey = XOnlyPublicKey::from_slice(&keypair.pubkey_bytes()).unwrap();

        // Verify signature
        let message = Message::from_digest(message_hash);
        assert!(SECP.verify_schnorr(&signature, &message, &pubkey).is_ok());
    }

    #[test]
    fn signature_fails_with_wrong_pubkey() {
        use nostr::secp256k1::{schnorr::Signature, Message, XOnlyPublicKey};

        let keypair1 = IdentityKeypair::generate();
        let keypair2 = IdentityKeypair::generate();
        let message_hash = [0x42u8; 32];

        // Sign with keypair1
        let signature_hex = keypair1.sign(&message_hash).unwrap();
        let sig_bytes = hex::decode(&signature_hex).unwrap();
        let signature = Signature::from_slice(&sig_bytes).unwrap();

        // Try to verify with keypair2's pubkey - should fail
        let wrong_pubkey = XOnlyPublicKey::from_slice(&keypair2.pubkey_bytes()).unwrap();
        let message = Message::from_digest(message_hash);

        assert!(SECP
            .verify_schnorr(&signature, &message, &wrong_pubkey)
            .is_err());
    }

    #[test]
    fn signature_fails_with_wrong_message() {
        use nostr::secp256k1::{schnorr::Signature, Message, XOnlyPublicKey};

        let keypair = IdentityKeypair::generate();
        let message_hash = [0x42u8; 32];
        let wrong_message = [0x43u8; 32];

        // Sign original message
        let signature_hex = keypair.sign(&message_hash).unwrap();
        let sig_bytes = hex::decode(&signature_hex).unwrap();
        let signature = Signature::from_slice(&sig_bytes).unwrap();

        // Verify with wrong message - should fail
        let pubkey = XOnlyPublicKey::from_slice(&keypair.pubkey_bytes()).unwrap();
        let message = Message::from_digest(wrong_message);

        assert!(SECP.verify_schnorr(&signature, &message, &pubkey).is_err());
    }

    #[test]
    fn different_keypairs_have_different_pubkeys() {
        let keypair1 = IdentityKeypair::generate();
        let keypair2 = IdentityKeypair::generate();
        assert_ne!(keypair1.pubkey_hex(), keypair2.pubkey_hex());
    }

    #[test]
    fn same_secret_produces_same_pubkey() {
        let mut bytes = [0u8; 32];
        bytes[0] = 42;

        let keypair1 = IdentityKeypair::from_secret_bytes(bytes).unwrap();
        let keypair2 = IdentityKeypair::from_secret_bytes(bytes).unwrap();

        assert_eq!(keypair1.pubkey_hex(), keypair2.pubkey_hex());
    }

    #[test]
    fn debug_does_not_leak_secret() {
        let keypair = IdentityKeypair::generate();
        let debug_output = format!("{keypair:?}");

        // Should contain pubkey but be short (no secret)
        assert!(debug_output.contains("pubkey"));
        assert!(debug_output.len() < 200);
    }

    #[test]
    fn debug_contains_pubkey_value() {
        let keypair = IdentityKeypair::generate();
        let debug_output = format!("{keypair:?}");
        let pubkey = keypair.pubkey_hex();

        assert!(debug_output.contains(&pubkey));
    }

    #[test]
    fn pubkey_hex_is_valid_hex() {
        let keypair = IdentityKeypair::generate();
        let pubkey = keypair.pubkey_hex();
        assert!(hex::decode(&pubkey).is_ok());
    }

    #[test]
    fn pubkey_bytes_matches_pubkey_hex() {
        let keypair = IdentityKeypair::generate();
        let pubkey_hex = keypair.pubkey_hex();
        let pubkey_bytes = keypair.pubkey_bytes();

        assert_eq!(pubkey_hex, hex::encode(pubkey_bytes));
    }

    #[test]
    fn implements_zeroize_on_drop() {
        fn assert_zeroize_on_drop<T: ZeroizeOnDrop>() {}
        assert_zeroize_on_drop::<IdentityKeypair>();
    }

    #[test]
    fn export_nsec_is_consistent() {
        let keypair = IdentityKeypair::generate();
        let nsec1 = keypair.export_nsec().unwrap();
        let nsec2 = keypair.export_nsec().unwrap();

        assert_eq!(nsec1, nsec2);
    }
}
