//! Hardened Marmot account-identity-proof signer (security F1).
//!
//! The Dark Matter engine binds the MLS leaf signature key to the Marmot
//! account identity with a Schnorr signature over a canonical, unpublished
//! kind-450 Nostr event (`marmot.account-identity-proof.v2`, extension type
//! `0xF2F1`). The engine asks the application to produce that signature through
//! the [`AccountIdentityProofSigner`] trait at every leaf-creating operation
//! (group create, key-package generation, self-update).
//!
//! # Why this wrapper is hardened, not a passthrough
//!
//! A naive signer that signs whatever digest the engine hands it would be a
//! **blind identity-key oracle**: anything holding a reference to it could ask
//! it to sign an arbitrary event id with the user's Nostr identity key. This
//! implementation closes that hole (security F1 / plan §7 Rule 1):
//!
//! 1. **Recompute, don't trust.** It never signs a caller-supplied digest. It
//!    recomputes the canonical kind-450 proof event from the request fields
//!    ([`AccountIdentityProofRequest::proof_event`]) and signs only that
//!    event's NIP-01 id, then re-validates via
//!    [`AccountIdentityProofRequest::signature_from_signed_event`] (which checks
//!    signer == account identity, id == recomputed id, and verifies the sig).
//! 2. **Fail closed on a foreign identity.** It refuses any request whose
//!    `account_identity` is not this device's own identity public key, so it can
//!    never be coerced into binding a leaf to someone else's account.
//! 3. **Purpose-scoped over the nsec.** It is not a general `NostrSigner`. It
//!    holds only the 32 raw secret-key bytes in a [`Zeroizing`] buffer,
//!    reconstructs an ephemeral [`Keys`] for the single signing call, and drops
//!    it immediately — no long-lived keypair, no signer surface exposed.

use std::sync::Arc;

use nostr::{Keys, SecretKey};
use zeroize::Zeroizing;

use cgka_engine::account_identity_proof::{
    AccountIdentityProofRequest, AccountIdentityProofSigner,
};

use crate::nostr::error::{NostrError, Result};

/// A hardened [`AccountIdentityProofSigner`] backed by the local Nostr identity
/// key.
///
/// Construct one with [`HavenIdentityProofSigner::new`] and install it on the
/// session via `SessionConfig::account_identity_proof_signer`.
pub struct HavenIdentityProofSigner {
    /// The local identity public key (x-only, 32 bytes). Public; used to fail
    /// closed on a foreign-identity request.
    identity_pubkey: [u8; 32],
    /// The local identity secret key bytes. Zeroized on drop; used only inside
    /// [`Self::sign_account_identity_proof`], reconstructed into an ephemeral
    /// [`Keys`] per call.
    secret_bytes: Zeroizing<[u8; 32]>,
}

impl HavenIdentityProofSigner {
    /// Builds a signer from the device's Nostr identity keys.
    ///
    /// Only the raw key material is copied out (public bytes for the guard,
    /// secret bytes into a [`Zeroizing`] buffer); the supplied `keys` reference
    /// is not retained.
    #[must_use]
    pub fn new(keys: &Keys) -> Self {
        Self {
            identity_pubkey: keys.public_key().to_bytes(),
            secret_bytes: Zeroizing::new(keys.secret_key().to_secret_bytes()),
        }
    }

    /// Builds a signer wrapped in an [`Arc`] ready for
    /// `SessionConfig::account_identity_proof_signer`.
    #[must_use]
    pub fn arc(keys: &Keys) -> Arc<dyn AccountIdentityProofSigner> {
        Arc::new(Self::new(keys))
    }

    /// Reconstructs the ephemeral signing keypair from the stored secret bytes.
    ///
    /// The returned [`Keys`] must be dropped as soon as the single signing call
    /// completes — it is never stored.
    fn signing_keys(&self) -> Result<Keys> {
        let secret = SecretKey::from_slice(self.secret_bytes.as_ref())
            .map_err(|e| NostrError::Signing(format!("invalid identity secret key: {e}")))?;
        Ok(Keys::new(secret))
    }
}

impl std::fmt::Debug for HavenIdentityProofSigner {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        // Never render key material — not even the public key, which would let
        // a leaked log line correlate the signer to a Nostr identity.
        f.debug_struct("HavenIdentityProofSigner")
            .field("identity_pubkey", &"<redacted>")
            .field("secret_bytes", &"<redacted>")
            .finish()
    }
}

impl AccountIdentityProofSigner for HavenIdentityProofSigner {
    fn sign_account_identity_proof(
        &self,
        request: &AccountIdentityProofRequest,
    ) -> std::result::Result<[u8; 64], String> {
        // (F1-ii) Fail closed on a foreign identity: never bind a leaf to an
        // account that is not this device's own. `MemberId`/account identity is
        // a 32-byte x-only pubkey, compared in constant length here.
        if request.account_identity.as_slice() != self.identity_pubkey.as_slice() {
            return Err(
                "account identity proof request is for a different identity; refusing to sign"
                    .to_string(),
            );
        }

        // (F1-i) Recompute the canonical kind-450 proof event ourselves and sign
        // ONLY that event's id. We never sign a caller-supplied digest.
        let unsigned = request.proof_event()?;
        let keys = self
            .signing_keys()
            .map_err(|e| format!("proof signer key error: {e}"))?;
        let signed = unsigned
            .sign_with_keys(&keys)
            .map_err(|e| format!("signing account identity proof failed: {e}"))?;

        // Re-validate against the request: this checks the signer == account
        // identity, the signed id == the recomputed canonical id, and verifies
        // the Schnorr signature before we return it.
        request.signature_from_signed_event(signed)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use nostr::secp256k1::schnorr::Signature;
    use nostr::PublicKey;

    /// The Marmot mandatory ciphersuite id (`0x0001`) and its Ed25519 signature
    /// scheme (`0x0807`). Named as raw `u16`s here so the test does not need a
    /// direct OpenMLS dependency — [`AccountIdentityProofRequest`] exposes both
    /// as public `u16` fields, and signing only signs the canonical event id, so
    /// the concrete values need only be internally consistent.
    const CIPHERSUITE: u16 = 0x0001;
    const SIGNATURE_SCHEME_ED25519: u16 = 0x0807;

    fn request_for(identity: &Keys, leaf_key: &[u8]) -> AccountIdentityProofRequest {
        AccountIdentityProofRequest {
            account_identity: identity.public_key().to_bytes().to_vec(),
            mls_signature_public_key: leaf_key.to_vec(),
            ciphersuite: CIPHERSUITE,
            signature_scheme: SIGNATURE_SCHEME_ED25519,
        }
    }

    #[test]
    fn signs_a_request_for_its_own_identity() {
        let keys = Keys::generate();
        let signer = HavenIdentityProofSigner::new(&keys);
        let request = request_for(&keys, b"mls-leaf-signature-key");

        let sig_bytes = signer
            .sign_account_identity_proof(&request)
            .expect("a request for our own identity must sign");

        // The returned 64 bytes are a valid Schnorr signature over the canonical
        // proof-event id (the signer re-verified before returning).
        assert!(Signature::from_slice(&sig_bytes).is_ok());
    }

    #[test]
    fn refuses_a_request_for_a_foreign_identity() {
        let ours = Keys::generate();
        let theirs = Keys::generate();
        let signer = HavenIdentityProofSigner::new(&ours);

        // A request whose account_identity is someone else's pubkey must be
        // refused BEFORE any signing happens (F1-ii: no blind identity oracle).
        let foreign = request_for(&theirs, b"mls-leaf-signature-key");
        let err = signer
            .sign_account_identity_proof(&foreign)
            .expect_err("a foreign-identity request must be refused");
        assert!(err.contains("different identity"));
    }

    #[test]
    fn debug_never_leaks_key_material() {
        let keys = Keys::generate();
        let signer = HavenIdentityProofSigner::new(&keys);
        let rendered = format!("{signer:?}");
        assert!(rendered.contains("HavenIdentityProofSigner"));
        assert!(rendered.contains("<redacted>"));
        assert!(!rendered.contains(&keys.public_key().to_hex()));
    }

    #[test]
    fn public_key_guard_is_the_x_only_identity() {
        // Sanity: the guard bytes equal the x-only identity pubkey, so the
        // equality check against `request.account_identity` (also x-only) is a
        // like-for-like comparison.
        let keys = Keys::generate();
        let signer = HavenIdentityProofSigner::new(&keys);
        assert_eq!(
            signer.identity_pubkey,
            PublicKey::from_slice(&keys.public_key().to_bytes())
                .unwrap()
                .to_bytes()
        );
    }
}
