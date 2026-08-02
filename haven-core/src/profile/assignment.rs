//! Deterministic per-author relay assignment for the profile plane.
//!
//! # Why this exists
//!
//! Haven resolves members' kind-0 metadata by pubkey. The naive implementation
//! puts every pubkey the user knows into ONE filter's `authors` array and
//! broadcasts it to a fixed relay set, which hands each of those relays a
//! k-clique of the user's social graph in a single REQ. This module replaces
//! that with a per-author assignment: each author's kind-0 is requested from
//! exactly ONE relay, with exactly ONE author per REQ.
//!
//! # What this does and does NOT guarantee
//!
//! Be precise about the claim, because the intuitive one is false:
//!
//! * **Achieved** — no single REQ ever discloses a co-membership set; no relay
//!   ever observes a whole roster; each pool relay sees only an
//!   install-specific ~`1/N` sample of the *blended union across all circles*
//!   (the union invariant enforced by `check_profile_privacy_boundaries.sh`
//!   Check 7), which it cannot partition back into circles.
//! * **NOT achieved** — "no relay ever learns two members of the same circle".
//!   Assignment is a hash over the pubkey, so collisions follow the birthday
//!   bound: `1 - N!/((N-m)!*N^m)`, i.e. ~79 % for a 5-member roster over an
//!   8-relay pool. Collision-free-per-roster assignment would require this
//!   module to know roster membership, which the `profile/` import boundary
//!   forbids by design. What a collision leaks is "this install is interested
//!   in these two pubkeys" — NOT "these two pubkeys share a circle", because
//!   the queried set is the cross-circle union.
//!
//! # Why rendezvous (HRW) hashing, not `index = hash mod N`
//!
//! The usable pool SHRINKS monotonically over an install's lifetime: every
//! circle joined from an inviter who routes through a pool relay adds that
//! relay to the contamination ledger and removes it from the pool. Under
//! `mod N`, a pool-size change reshuffles ~`(N-1)/N` of all assignments, so
//! each such event re-discloses nearly every contact to a relay that had never
//! seen it. Repeated over the life of an install, total disclosure converges to
//! "every pool relay has seen every contact" — the scheme decays to nothing.
//!
//! Rendezvous hashing bounds the churn: dropping a relay moves ONLY the authors
//! whose top-ranked relay it was (~`1/N` of them) and leaves every other
//! assignment byte-identical. Filtering the pool before ranking is equivalent
//! to ranking then dropping, so contamination exclusion is free of churn too.
//!
//! # Why the salt is never rotated
//!
//! Rotation looks privacy-preserving and is strictly worse in total: each
//! rotation discloses every contact to an ADDITIONAL relay, so after `k`
//! rotations up to `min(k, N)` relays know each contact, converging on full
//! disclosure. A stable salt fixes each author's relay for the life of the
//! install, so the disclosure set never grows. The accepted cost is that the
//! assigned relay accumulates a durable "this IP is persistently interested in
//! this pubkey" observation. This is an owner-accepted deviation — do not
//! "fix" it by adding rotation.

use hmac::{Hmac, Mac};
use nostr::PublicKey;
use rand::RngCore;
use sha2::Sha256;
use zeroize::{Zeroize, ZeroizeOnDrop, Zeroizing};

use crate::profile::error::{ProfileError, Result};

type HmacSha256 = Hmac<Sha256>;

/// Domain separator between the author and the relay URL in the HRW preimage.
///
/// The author is fixed-length (32 bytes) so concatenation is already
/// unambiguous, but an explicit separator keeps the preimage self-describing
/// and immune to a future change in author encoding.
const HRW_SEPARATOR: u8 = 0x1F;

/// Highest rank an author's kind-0 may ever be requested from.
///
/// The retry ladder walks the HRW ranking, but is hard-capped here so a pubkey
/// is disclosed to at most this many pool relays for the life of the install.
/// Raising it directly widens per-author disclosure — treat as a privacy
/// parameter, not a tuning knob.
pub const PROFILE_MAX_RELAY_RANK: usize = 2;

/// Per-install secret that keys the profile-plane relay assignment.
///
/// Not key material — leaking it costs unlinkability, never confidentiality —
/// but it is a perfect stable install fingerprint if it escapes, so it is
/// handled to the same standard as a secret (Security Rule 7): zeroized on
/// drop, redacted in `Debug`, and never crossed over the FFI boundary.
#[derive(Clone, ZeroizeOnDrop)]
pub struct ProfileRelaySalt {
    bytes: [u8; 32],
}

impl ProfileRelaySalt {
    /// Mints a fresh salt from the OS CSPRNG.
    ///
    /// # Panics
    ///
    /// Panics only if the OS CSPRNG is unavailable; `OsRng` fills are
    /// infallible on every supported platform, so a failure indicates a broken
    /// system entropy source.
    #[must_use]
    pub fn generate() -> Self {
        let mut bytes = [0u8; 32];
        rand::rngs::OsRng.fill_bytes(&mut bytes);
        Self { bytes }
    }

    /// Reconstructs a salt from raw bytes (storage round-trip).
    #[must_use]
    pub const fn from_bytes(bytes: [u8; 32]) -> Self {
        Self { bytes }
    }

    /// Parses a salt from its 64-character lowercase hex encoding.
    ///
    /// # Errors
    ///
    /// Returns [`ProfileError::InvalidData`] when the input is not exactly 32
    /// bytes of valid hex. The error never echoes the input.
    pub fn from_hex(hex_str: &str) -> Result<Self> {
        let mut decoded =
            Zeroizing::new(hex::decode(hex_str.trim()).map_err(|_| {
                ProfileError::InvalidData("malformed profile relay salt".to_string())
            })?);
        if decoded.len() != 32 {
            return Err(ProfileError::InvalidData(
                "malformed profile relay salt".to_string(),
            ));
        }
        let mut bytes = [0u8; 32];
        bytes.copy_from_slice(&decoded);
        decoded.zeroize();
        Ok(Self { bytes })
    }

    /// Renders the salt as 64 lowercase hex characters for storage.
    ///
    /// The returned `String` is wrapped in [`Zeroizing`] so the plaintext
    /// encoding is wiped once the caller has handed it to storage.
    #[must_use]
    pub fn to_hex(&self) -> Zeroizing<String> {
        Zeroizing::new(hex::encode(self.bytes))
    }
}

/// Redacts the salt entirely — it is a stable install fingerprint.
impl std::fmt::Debug for ProfileRelaySalt {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("ProfileRelaySalt(<redacted>)")
    }
}

/// Computes the rendezvous weight of `relay` for `author` under `salt`.
///
/// Takes the leading 8 bytes of `HMAC-SHA256(salt, author || 0x1F || relay)`
/// as a big-endian `u64`. Truncating a 256-bit MAC to 64 bits is sound here:
/// the weight only needs to induce an unpredictable total order, not to resist
/// second-preimage attacks.
fn relay_weight(salt: &ProfileRelaySalt, author: &PublicKey, relay: &str) -> u64 {
    // `new_from_slice` only errors for key lengths an implementation cannot
    // accept; HMAC accepts any length, so this cannot fail for a 32-byte key.
    let mut mac = HmacSha256::new_from_slice(&salt.bytes)
        .expect("HMAC accepts keys of any length; a 32-byte key is always valid");
    mac.update(&author.to_bytes());
    mac.update(&[HRW_SEPARATOR]);
    mac.update(relay.as_bytes());
    let tag = mac.finalize().into_bytes();
    let mut head = [0u8; 8];
    head.copy_from_slice(&tag[..8]);
    u64::from_be_bytes(head)
}

/// Ranks every relay in `pool` for `author`, best first.
///
/// The result is a deterministic function of `(salt, author, pool as a SET)` —
/// callers may pass the pool in any order and receive the same ranking, because
/// the ordering is total: descending weight, ties broken by ascending URL. That
/// matters because the pool is assembled from a database query unioned with a
/// constant, and neither source guarantees a stable order.
///
/// Duplicate entries are collapsed, so a pool that lists the same relay twice
/// cannot bias the assignment toward it.
#[must_use]
pub fn rank_relays(salt: &ProfileRelaySalt, author: &PublicKey, pool: &[String]) -> Vec<String> {
    let mut unique: Vec<String> = Vec::with_capacity(pool.len());
    for relay in pool {
        if !unique.contains(relay) {
            unique.push(relay.clone());
        }
    }
    let mut weighted: Vec<(u64, String)> = unique
        .into_iter()
        .map(|relay| (relay_weight(salt, author, &relay), relay))
        .collect();
    // Descending weight; ascending URL on a tie so the order is TOTAL. A
    // weight collision left to `sort_unstable`'s discretion would make the
    // assignment non-deterministic across runs.
    weighted.sort_by(|(lw, lu), (rw, ru)| rw.cmp(lw).then_with(|| lu.cmp(ru)));
    weighted.into_iter().map(|(_, relay)| relay).collect()
}

/// The relay that `author`'s kind-0 is requested from, or `None` for an empty pool.
#[must_use]
pub fn assigned_relay(
    salt: &ProfileRelaySalt,
    author: &PublicKey,
    pool: &[String],
) -> Option<String> {
    rank_relays(salt, author, pool).into_iter().next()
}

/// The relay to try for `author` on retry number `attempt`.
///
/// `attempt` is saturated at [`PROFILE_MAX_RELAY_RANK`] − 1, so the ladder
/// cycles between at most that many relays no matter how many times an author
/// misses. An author whose kind-0 genuinely does not exist is therefore
/// disclosed to a bounded set of relays rather than eventually to the whole
/// pool.
#[must_use]
pub fn assigned_relay_for_attempt(
    salt: &ProfileRelaySalt,
    author: &PublicKey,
    pool: &[String],
    attempt: u8,
) -> Option<String> {
    let ranked = rank_relays(salt, author, pool);
    if ranked.is_empty() {
        return None;
    }
    let capped = usize::from(attempt).min(PROFILE_MAX_RELAY_RANK - 1);
    // A pool smaller than the rank cap falls back to the last available rank
    // rather than returning None — a 1-relay pool must still resolve.
    let index = capped.min(ranked.len() - 1);
    ranked.into_iter().nth(index)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Deterministic authors — never random, so a failure is reproducible.
    fn author(seed: u8) -> PublicKey {
        let mut bytes = [0x11u8; 32];
        bytes[0] = seed;
        // Not every 32-byte string is a valid x-only key; walk until one is.
        let mut n = 0u8;
        loop {
            bytes[31] = n;
            if let Ok(pk) = PublicKey::from_slice(&bytes) {
                return pk;
            }
            n = n
                .checked_add(1)
                .expect("a valid x-only key exists in 256 tries");
        }
    }

    fn pool(n: usize) -> Vec<String> {
        (0..n).map(|i| format!("wss://relay{i}.example")).collect()
    }

    fn salt_a() -> ProfileRelaySalt {
        ProfileRelaySalt::from_bytes([0xAA; 32])
    }

    fn salt_b() -> ProfileRelaySalt {
        ProfileRelaySalt::from_bytes([0xBB; 32])
    }

    #[test]
    fn assignment_is_deterministic_for_same_salt_and_pool() {
        let p = pool(8);
        for seed in 0..16 {
            let a = author(seed);
            let first = assigned_relay(&salt_a(), &a, &p);
            assert!(first.is_some());
            for _ in 0..5 {
                assert_eq!(
                    assigned_relay(&salt_a(), &a, &p),
                    first,
                    "assignment must be stable across calls",
                );
            }
        }
    }

    #[test]
    fn assignment_is_independent_of_pool_input_order() {
        // The pool is assembled from a DB query unioned with a constant, so
        // input order is not guaranteed. If ranking depended on it, a member's
        // relay could silently change between launches.
        let forward = pool(8);
        let mut reversed = forward.clone();
        reversed.reverse();
        for seed in 0..32 {
            let a = author(seed);
            assert_eq!(
                rank_relays(&salt_a(), &a, &forward),
                rank_relays(&salt_a(), &a, &reversed),
                "ranking must depend on the pool as a SET, not its order",
            );
        }
    }

    #[test]
    fn assignment_differs_across_salts() {
        // Two installs must not derive the same mapping, or a relay could
        // correlate across users. Fixed salts keep this non-flaky.
        let p = pool(8);
        let differing = (0..32)
            .filter(|&seed| {
                let a = author(seed);
                assigned_relay(&salt_a(), &a, &p) != assigned_relay(&salt_b(), &a, &p)
            })
            .count();
        assert!(
            differing > 0,
            "two different salts produced an identical mapping for all 32 authors",
        );
    }

    #[test]
    fn assignment_distribution_is_balanced_across_pool() {
        // A skewed hash would concentrate the roster on a few relays, silently
        // undoing the 1/N sampling property.
        let p = pool(8);
        let n = 4_000usize;
        let mut counts = std::collections::HashMap::new();
        for seed in 0..n {
            // Vary two bytes so 4000 distinct authors are reachable.
            let mut bytes = [0x11u8; 32];
            bytes[0] = u8::try_from(seed % 251).expect("bounded by 251");
            bytes[1] = u8::try_from(seed / 251).expect("bounded by 16");
            let mut t = 0u8;
            let a = loop {
                bytes[31] = t;
                if let Ok(pk) = PublicKey::from_slice(&bytes) {
                    break pk;
                }
                t = t.checked_add(1).expect("a valid key exists");
            };
            *counts
                .entry(assigned_relay(&salt_a(), &a, &p).expect("non-empty pool"))
                .or_insert(0usize) += 1;
        }
        assert_eq!(counts.len(), 8, "every relay must receive some share");
        let expected = n / 8;
        for (relay, count) in &counts {
            let lo = expected * 3 / 4;
            let hi = expected * 5 / 4;
            assert!(
                (lo..=hi).contains(count),
                "relay {relay} got {count}, expected within [{lo}, {hi}]",
            );
        }
    }

    #[test]
    fn removing_a_relay_only_moves_its_own_assignments() {
        // THE reason for HRW over `mod N`. The usable pool shrinks over an
        // install's life; if a removal reshuffled everyone, each shrink would
        // re-disclose every contact to a relay that had never seen it.
        let full = pool(8);
        let dropped = &full[3];
        let reduced: Vec<String> = full.iter().filter(|r| *r != dropped).cloned().collect();
        for seed in 0..64 {
            let a = author(seed);
            let before = assigned_relay(&salt_a(), &a, &full).expect("non-empty");
            let after = assigned_relay(&salt_a(), &a, &reduced).expect("non-empty");
            if &before == dropped {
                assert_ne!(&after, dropped, "the removed relay must not be assigned");
            } else {
                assert_eq!(
                    before, after,
                    "removing a relay must not move an author assigned elsewhere",
                );
            }
        }
    }

    #[test]
    fn adding_a_relay_moves_at_most_one_over_pool_fraction() {
        let smaller = pool(8);
        let larger = pool(9);
        let total = 256usize;
        let moved = (0..total)
            .filter(|&seed| {
                let a = author(u8::try_from(seed % 256).expect("bounded"));
                assigned_relay(&salt_a(), &a, &smaller) != assigned_relay(&salt_a(), &a, &larger)
            })
            .count();
        // HRW bound is ~n/(N+1) = ~28; allow generous slack for a small sample.
        assert!(
            moved <= total / 3,
            "adding one relay moved {moved}/{total} assignments — churn far above the HRW bound",
        );
    }

    #[test]
    fn ranking_is_total_and_tie_broken_by_url() {
        let p = pool(8);
        for seed in 0..16 {
            let ranked = rank_relays(&salt_a(), &author(seed), &p);
            assert_eq!(ranked.len(), 8, "every relay must appear exactly once");
            let unique: std::collections::HashSet<_> = ranked.iter().collect();
            assert_eq!(unique.len(), 8, "ranking must not duplicate a relay");
        }
    }

    #[test]
    fn duplicate_pool_entries_are_collapsed() {
        // A pool listing the same relay twice must not double its odds.
        let mut dupes = pool(4);
        dupes.push(dupes[0].clone());
        let ranked = rank_relays(&salt_a(), &author(7), &dupes);
        assert_eq!(ranked.len(), 4, "duplicates must collapse");
    }

    #[test]
    fn retry_ladder_never_exceeds_two_relays() {
        // A pubkey with no kind-0 anywhere is retried forever; the ladder must
        // NOT walk the whole pool, or a missing profile would eventually
        // disclose that pubkey to every relay.
        let p = pool(8);
        for seed in 0..16 {
            let a = author(seed);
            let ranked = rank_relays(&salt_a(), &a, &p);
            let permitted: std::collections::HashSet<&String> =
                ranked.iter().take(PROFILE_MAX_RELAY_RANK).collect();
            for attempt in 0..=u8::MAX {
                let chosen =
                    assigned_relay_for_attempt(&salt_a(), &a, &p, attempt).expect("non-empty pool");
                assert!(
                    permitted.contains(&chosen),
                    "attempt {attempt} escaped the top-{PROFILE_MAX_RELAY_RANK} ladder",
                );
            }
        }
    }

    #[test]
    fn single_relay_pool_still_resolves_on_retry() {
        let p = pool(1);
        let a = author(3);
        for attempt in 0..4 {
            assert_eq!(
                assigned_relay_for_attempt(&salt_a(), &a, &p, attempt),
                Some(p[0].clone()),
                "a 1-relay pool must keep resolving rather than returning None",
            );
        }
    }

    #[test]
    fn empty_pool_yields_no_assignment() {
        assert!(assigned_relay(&salt_a(), &author(1), &[]).is_none());
        assert!(assigned_relay_for_attempt(&salt_a(), &author(1), &[], 0).is_none());
    }

    #[test]
    fn salt_debug_is_redacted() {
        let salt = ProfileRelaySalt::from_bytes([0xAB; 32]);
        let rendered = format!("{salt:?}");
        assert!(
            !rendered.contains("ab"),
            "Debug leaked salt bytes: {rendered}",
        );
        assert!(rendered.contains("redacted"));
    }

    #[test]
    fn salt_hex_round_trips() {
        let salt = ProfileRelaySalt::from_bytes([0x5C; 32]);
        let hex_str = salt.to_hex();
        assert_eq!(hex_str.len(), 64);
        let restored = ProfileRelaySalt::from_hex(&hex_str).expect("valid hex");
        // Compare via behaviour, not by exposing bytes.
        let p = pool(8);
        assert_eq!(
            rank_relays(&salt, &author(9), &p),
            rank_relays(&restored, &author(9), &p),
        );
    }

    #[test]
    fn salt_from_hex_rejects_malformed_input() {
        for bad in ["", "zz", &"ab".repeat(31), &"ab".repeat(33)] {
            assert!(
                ProfileRelaySalt::from_hex(bad).is_err(),
                "accepted malformed salt {bad:?}",
            );
        }
    }

    #[test]
    fn generated_salts_are_distinct() {
        let a = ProfileRelaySalt::generate();
        let b = ProfileRelaySalt::generate();
        assert_ne!(*a.to_hex(), *b.to_hex(), "two CSPRNG draws collided");
    }

    #[test]
    fn salt_implements_zeroize_on_drop() {
        const fn assert_zeroize_on_drop<T: ZeroizeOnDrop>() {}
        assert_zeroize_on_drop::<ProfileRelaySalt>();
    }
}
