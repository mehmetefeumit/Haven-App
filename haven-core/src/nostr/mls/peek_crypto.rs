//! Verbatim copy of MDK's `pub(crate)` kind:445 outer-layer decrypt routines.
//!
//! MDK's `decrypt_message_with_exporter_secret`,
//! `decrypt_message_with_legacy_exporter_secret`, and
//! `decrypt_message_with_any_supported_format`
//! (`mdk-core/src/messages/crypto.rs`, pinned rev `93ae324`) are `pub(crate)`
//! and therefore unreachable from haven-core. The REV-1 non-destructive
//! content-type peek ([`super::manager::MdkManager::peek_content_type`]) must
//! decrypt a settle-window competitor's OUTER exporter-secret layer to read its
//! MLS `content_type` WITHOUT a destructive trial-apply — so this is a
//! byte-for-byte copy of MDK's decrypt logic (the same ChaCha20-Poly1305 +
//! NIP-44-legacy routine) — the BLOCKING decrypt-parity gate: a competitor the
//! peek decrypts yields the identical `content_type` MDK would derive, so it
//! cannot be mis-skipped / mis-applied. NOTE: the caller
//! ([`super::manager::MdkManager::peek_content_type`]) enables the NIP-44 legacy
//! fallback UNCONDITIONALLY (`allow_legacy_nip44 = true`), whereas MDK gates it
//! per-event (a base64-`encoding` tag / the migration deadline). That flag only
//! controls WHETHER the legacy fallback is attempted, never WHICH bytes result,
//! so it can never flip a Proposal into a Commit; the sole divergence —
//! decrypting a post-deadline legacy message MDK would reject — lands in the
//! FAIL-SAFE direction and is unreachable in Haven (a from-scratch app emits no
//! legacy-wrapped kind:445).
//!
//! The ChaCha20-Poly1305 parameters are IDENTICAL to MDK's: `base64(nonce ||
//! ciphertext)` with a 12-byte nonce (`split_at(12)`), no AAD, standard base64,
//! and a 28-byte minimum decoded length (12-byte nonce + 16-byte Poly1305 tag).
//!
//! Non-cryptographic differences from MDK (deliberate, do not affect parity):
//! - the fail-safe entry point returns `Option<Zeroizing<Vec<u8>>>` instead of a
//!   `Result<Vec<u8>, Error>` — the peek fails SAFE to `Unpeekable` on ANY
//!   failure and never surfaces a reason string;
//! - the decrypted transport bytes are wrapped in [`Zeroizing`] so they are
//!   scrubbed the moment the peek finishes reading the cleartext `content_type`;
//! - MDK's `tracing` diagnostics are omitted (Security Rule 6 — nothing about a
//!   secret or a decrypt attempt is ever logged).

use base64::engine::general_purpose::STANDARD as BASE64;
use base64::Engine;
use chacha20poly1305::{
    aead::{Aead, KeyInit},
    ChaCha20Poly1305, Nonce,
};
use mdk_core::prelude::group_types::GroupExporterSecret;
use nostr::nips::nip44;
use nostr::{Keys, SecretKey};
use zeroize::Zeroizing;

/// A peek-decrypt failure. Carries NO detail: the REV-1 peek fails SAFE
/// (→ `PeekedContent::Unpeekable`) on any decrypt failure and never surfaces a
/// reason, so — unlike MDK's `Error::Message(String)` — no string is retained.
#[derive(Debug)]
struct DecryptError;

/// Minimum valid byte length of decoded `event.content`:
/// 12-byte nonce + 16-byte Poly1305 authentication tag + 0 bytes of plaintext.
/// Verbatim from MDK's `MIN_ENCRYPTED_CONTENT_LEN`.
const MIN_ENCRYPTED_CONTENT_LEN: usize = 28;

/// ChaCha20-Poly1305 decrypt — byte-for-byte from MDK's
/// `decrypt_message_with_exporter_secret`.
///
/// The content format is `base64(nonce || ciphertext)`: a 12-byte nonce, a
/// ciphertext that includes the 16-byte Poly1305 tag, and no AAD.
fn decrypt_message_with_exporter_secret(
    secret: &GroupExporterSecret,
    encrypted_content: &str,
) -> Result<Vec<u8>, DecryptError> {
    let combined = BASE64.decode(encrypted_content).map_err(|_| DecryptError)?;

    if combined.len() < MIN_ENCRYPTED_CONTENT_LEN {
        return Err(DecryptError);
    }

    let (nonce_bytes, ciphertext) = combined.split_at(12);
    let nonce = Nonce::from_slice(nonce_bytes);

    // Pass the exporter secret by reference (never a copy): `GroupExporterSecret`
    // is `ZeroizeOnDrop`, and `as_ref()` borrows the raw bytes without materializing
    // an unwrapped `[u8; 32]` on the stack.
    let cipher =
        ChaCha20Poly1305::new_from_slice(secret.secret.as_ref()).map_err(|_| DecryptError)?;

    cipher.decrypt(nonce, ciphertext).map_err(|_| DecryptError)
}

/// NIP-44 legacy fallback — byte-for-byte from MDK's
/// `decrypt_message_with_legacy_exporter_secret`.
///
/// Pre-0.7.0 groups wrapped kind:445 content with NIP-44 keyed by the exporter
/// secret. Keeping this fallback means the peek recovers the SAME `content_type`
/// MDK would for a legacy-format competitor (decrypt-parity).
fn decrypt_message_with_legacy_exporter_secret(
    secret: &GroupExporterSecret,
    encrypted_content: &str,
) -> Result<Vec<u8>, DecryptError> {
    let secret_key = SecretKey::from_slice(secret.secret.as_ref()).map_err(|_| DecryptError)?;
    let export_nostr_keys = Keys::new(secret_key);

    nip44::decrypt_to_bytes(
        export_nostr_keys.secret_key(),
        &export_nostr_keys.public_key,
        encrypted_content,
    )
    .map_err(|_| DecryptError)
}

/// Fail-safe entry point mirroring MDK's `decrypt_message_with_any_supported_format`:
/// try the current ChaCha20-Poly1305 format, then (when `allow_legacy_nip44`)
/// the NIP-44 legacy fallback.
///
/// Returns the decrypted transport bytes in a [`Zeroizing`] buffer, or `None` on
/// ANY failure — the peek's non-destructive fail-safe skip. The raw exporter
/// secret is only ever borrowed (`secret.secret.as_ref()`), never copied.
pub(super) fn decrypt_message_with_any_supported_format(
    secret: &GroupExporterSecret,
    encrypted_content: &str,
    allow_legacy_nip44: bool,
) -> Option<Zeroizing<Vec<u8>>> {
    match decrypt_message_with_exporter_secret(secret, encrypted_content) {
        Ok(decrypted_bytes) => Some(Zeroizing::new(decrypted_bytes)),
        Err(_) if allow_legacy_nip44 => {
            decrypt_message_with_legacy_exporter_secret(secret, encrypted_content)
                .ok()
                .map(Zeroizing::new)
        }
        Err(_) => None,
    }
}

#[cfg(test)]
mod tests {
    use base64::engine::general_purpose::STANDARD as BASE64;
    use base64::Engine;
    use chacha20poly1305::{
        aead::{Aead, KeyInit},
        ChaCha20Poly1305, Nonce,
    };
    use mdk_storage_traits::{GroupId, Secret};
    use nostr::nips::nip44;
    use nostr::{Keys, SecretKey};

    use super::*;

    /// Builds a `GroupExporterSecret` around a fixed 32-byte key.
    fn secret_with(key: [u8; 32]) -> GroupExporterSecret {
        GroupExporterSecret {
            mls_group_id: GroupId::from_slice(&[1, 2, 3]),
            epoch: 0,
            secret: Secret::new(key),
        }
    }

    /// Frames `plaintext` exactly as MDK's `encrypt_message_with_exporter_secret`
    /// does — `base64(nonce || ChaCha20-Poly1305(plaintext))` — WITHOUT copying
    /// MDK's (prod-unused) encrypt routine into haven-core.
    fn frame_chacha(key: &[u8; 32], nonce_bytes: &[u8; 12], plaintext: &[u8]) -> String {
        let cipher = ChaCha20Poly1305::new_from_slice(key).unwrap();
        let nonce = Nonce::from_slice(nonce_bytes);
        let ciphertext = cipher.encrypt(nonce, plaintext).unwrap();
        let mut combined = Vec::with_capacity(12 + ciphertext.len());
        combined.extend_from_slice(nonce_bytes);
        combined.extend_from_slice(&ciphertext);
        BASE64.encode(&combined)
    }

    #[test]
    fn chacha_roundtrip_recovers_plaintext() {
        let secret = secret_with([0x42u8; 32]);
        let plaintext = b"marmot group-event transport bytes";
        let encrypted = frame_chacha(&[0x42u8; 32], &[7u8; 12], plaintext);

        let decrypted = decrypt_message_with_exporter_secret(&secret, &encrypted).unwrap();
        assert_eq!(decrypted, plaintext);
    }

    #[test]
    fn rejects_invalid_base64() {
        let secret = secret_with([0u8; 32]);
        assert!(decrypt_message_with_exporter_secret(&secret, "!!!not-base64!!!").is_err());
    }

    #[test]
    fn rejects_too_short_content() {
        let secret = secret_with([1u8; 32]);
        // 12-byte nonce + 16-byte tag = 28-byte minimum; every shorter decode fails.
        for len in [0usize, 1, 11, 12, 13, 27] {
            let too_short = BASE64.encode(vec![0u8; len]);
            assert!(
                decrypt_message_with_exporter_secret(&secret, &too_short).is_err(),
                "decoded length {len} must be rejected (below the 28-byte minimum)"
            );
        }
    }

    #[test]
    fn tampered_ciphertext_fails_aead() {
        let key = [0x42u8; 32];
        let cipher = ChaCha20Poly1305::new_from_slice(&key).unwrap();
        let nonce_bytes = [2u8; 12];
        let nonce = Nonce::from_slice(&nonce_bytes);
        let mut ciphertext = cipher.encrypt(nonce, b"secret".as_slice()).unwrap();
        ciphertext[0] ^= 0x01;

        let mut combined = Vec::new();
        combined.extend_from_slice(&nonce_bytes);
        combined.extend_from_slice(&ciphertext);
        let encrypted = BASE64.encode(&combined);

        let secret = secret_with(key);
        assert!(decrypt_message_with_exporter_secret(&secret, &encrypted).is_err());
    }

    /// Covers the NIP-44 legacy branch specifically (not exercised by the
    /// acceptance-gate reds, which use MDK's current ChaCha20 `create_message`).
    #[test]
    fn legacy_nip44_roundtrip() {
        let secret = secret_with([0x24u8; 32]);
        let secret_key = SecretKey::from_slice(secret.secret.as_ref()).unwrap();
        let export_nostr_keys = Keys::new(secret_key);
        let encrypted = nip44::encrypt(
            export_nostr_keys.secret_key(),
            &export_nostr_keys.public_key,
            b"legacy wrapper",
            nip44::Version::default(),
        )
        .unwrap();

        let decrypted = decrypt_message_with_legacy_exporter_secret(&secret, &encrypted).unwrap();
        assert_eq!(decrypted, b"legacy wrapper");
    }

    #[test]
    fn any_format_takes_the_chacha_path_first() {
        let secret = secret_with([0x42u8; 32]);
        let encrypted = frame_chacha(&[0x42u8; 32], &[9u8; 12], b"current format");

        let decrypted =
            decrypt_message_with_any_supported_format(&secret, &encrypted, true).unwrap();
        assert_eq!(decrypted.as_slice(), b"current format");
    }

    #[test]
    fn any_format_falls_back_to_legacy_nip44_when_allowed() {
        let secret = secret_with([0x25u8; 32]);
        let secret_key = SecretKey::from_slice(secret.secret.as_ref()).unwrap();
        let export_nostr_keys = Keys::new(secret_key);
        // NIP-44 content: the ChaCha20 path fails its AEAD tag, so the fallback runs.
        let encrypted = nip44::encrypt(
            export_nostr_keys.secret_key(),
            &export_nostr_keys.public_key,
            b"legacy fallback",
            nip44::Version::default(),
        )
        .unwrap();

        let decrypted =
            decrypt_message_with_any_supported_format(&secret, &encrypted, true).unwrap();
        assert_eq!(decrypted.as_slice(), b"legacy fallback");
    }

    #[test]
    fn any_format_skips_legacy_when_disallowed() {
        let secret = secret_with([0x25u8; 32]);
        let secret_key = SecretKey::from_slice(secret.secret.as_ref()).unwrap();
        let export_nostr_keys = Keys::new(secret_key);
        let encrypted = nip44::encrypt(
            export_nostr_keys.secret_key(),
            &export_nostr_keys.public_key,
            b"legacy fallback",
            nip44::Version::default(),
        )
        .unwrap();

        // Legacy disallowed: a NIP-44-only payload does not decrypt.
        assert!(decrypt_message_with_any_supported_format(&secret, &encrypted, false).is_none());
    }

    #[test]
    fn any_format_returns_none_on_total_failure() {
        let secret = secret_with([0x11u8; 32]);
        assert!(
            decrypt_message_with_any_supported_format(&secret, "!!!garbage!!!", true).is_none()
        );
    }
}
