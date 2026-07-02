//! Engine safety primitives: the MLS write gate and the per-session sub-id salt.
//!
//! The always-on engine processor and the foreground finalize/converge writer
//! share ONE [`crate::circle::CircleManager`] (one MDK / one `SQLCipher` store).
//! [`MlsWriteGate`] serializes every MDK-mutating call per circle so the two
//! never corrupt the shared MLS state by writing concurrently. The
//! [`generate_session_salt`] helper produces the ephemeral salt that makes
//! subscription ids unlinkable across app sessions (PSI-2).

use std::collections::HashMap;
use std::sync::{Arc, Mutex as StdMutex};

use tokio::sync::Mutex as AsyncMutex;
use zeroize::Zeroizing;

/// A per-circle async write gate over the shared MLS state.
///
/// A caller acquires `for_group(hex).lock().await` around every MDK-mutating
/// call for that circle (engine decrypt, finalize, converge, `create_message`,
/// clear). Distinct circles get distinct locks, so unrelated circles still write
/// in parallel; the same circle is fully serialized. Added defensively — MDK's
/// own storage-level serialization was not relied upon.
#[derive(Default)]
pub struct MlsWriteGate {
    locks: StdMutex<HashMap<String, Arc<AsyncMutex<()>>>>,
}

impl MlsWriteGate {
    /// Creates an empty write gate.
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Returns the (shared, lazily-created) async lock for `group_id_hex`.
    ///
    /// Two callers for the SAME circle receive the same `Arc`, so awaiting the
    /// lock serializes them; callers for DISTINCT circles receive distinct locks
    /// and proceed in parallel. The brief inner `std` mutex is never held across
    /// an `.await`.
    #[must_use]
    pub fn for_group(&self, group_id_hex: &str) -> Arc<AsyncMutex<()>> {
        let mut locks = self
            .locks
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        Arc::clone(locks.entry(group_id_hex.to_string()).or_default())
    }
}

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
    fn same_group_shares_one_lock_distinct_groups_do_not() {
        let gate = MlsWriteGate::new();
        let a1 = gate.for_group("aa00");
        let a2 = gate.for_group("aa00");
        let b = gate.for_group("bb11");
        assert!(
            Arc::ptr_eq(&a1, &a2),
            "same circle must share one lock (serialized writes)"
        );
        assert!(
            !Arc::ptr_eq(&a1, &b),
            "distinct circles must have distinct locks (parallel writes)"
        );
    }

    #[test]
    fn write_gate_actually_serializes_same_group_holders() {
        // A held async lock must block a second acquisition of the SAME group's
        // lock (proving serialization), while a different group proceeds.
        let rt = tokio::runtime::Builder::new_current_thread()
            .build()
            .unwrap();
        rt.block_on(async {
            let gate = MlsWriteGate::new();
            let lock_a = gate.for_group("aa00");
            let _held = lock_a.lock().await;

            // Same group: a fresh handle to the same lock cannot be acquired now.
            let same = gate.for_group("aa00");
            assert!(
                same.try_lock().is_err(),
                "same-group lock must be contended while held"
            );

            // Different group: independent, acquirable.
            let other = gate.for_group("bb11");
            assert!(other.try_lock().is_ok(), "distinct-group lock must be free");
        });
    }

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
