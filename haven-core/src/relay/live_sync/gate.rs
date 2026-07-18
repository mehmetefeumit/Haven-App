//! Engine safety primitive: the per-session sub-id salt.
//!
//! The [`generate_session_salt`] helper produces the ephemeral salt that makes
//! subscription ids unlinkable across app sessions (PSI-2).
//!
//! (The former per-circle `MlsWriteGate` was removed in the MDK Dark Matter
//! migration: write serialization is now enforced by the single process-global
//! `AccountDeviceSession` behind one `tokio` mutex — see Security Rule 14 and
//! `nostr::mls::storage::LiveSessionGuard` — so a separate per-circle gate is no
//! longer meaningful.)

use zeroize::Zeroizing;

/// Generates a per-session ephemeral subscription-id salt.
///
/// 16 bytes from the OS CSPRNG, held in [`Zeroizing`] so it is wiped on drop and
/// is **never persisted** — a relay therefore cannot link a user's subscriptions
/// across app sessions (PSI-2). Fed to [`super::planes::derive_sub_id`].
///
/// # Panics
///
/// Panics only if the OS CSPRNG is unavailable (`OsRng` fills are infallible on
/// every supported platform; a failure indicates a broken system entropy source).
#[must_use]
pub fn generate_session_salt() -> Zeroizing<[u8; 16]> {
    use rand::RngCore;
    let mut salt = Zeroizing::new([0u8; 16]);
    rand::rngs::OsRng.fill_bytes(salt.as_mut_slice());
    salt
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn session_salt_is_random_ephemeral_and_nonzero() {
        let a = generate_session_salt();
        let b = generate_session_salt();
        // Two CSPRNG draws colliding is ~2^-128 — effectively never.
        assert_ne!(*a, *b, "each session must get a fresh salt (PSI-2)");
        assert_ne!(*a, [0u8; 16], "salt must not be all-zeros");
    }

    #[test]
    fn session_salt_drives_cross_session_subscription_unlinkability() {
        use crate::relay::live_sync::planes::{derive_sub_id, PlaneKind};
        // Same pubkey, two sessions (two salts) → different sub-ids.
        let pk = [9u8; 32];
        let s1 = generate_session_salt();
        let s2 = generate_session_salt();
        let id1 = derive_sub_id(&s1, &pk, PlaneKind::Group, 0);
        let id2 = derive_sub_id(&s2, &pk, PlaneKind::Group, 0);
        assert_ne!(
            id1, id2,
            "a relay must not link the same user's subscriptions across sessions"
        );
    }
}
