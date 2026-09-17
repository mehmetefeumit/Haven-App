//! `seal --host-seed`: the pubkey a proxy-less lane can declare.
//!
//! # Why this exists
//!
//! A lane with a recording wire proxy declares every value it mints over the
//! control channel. A lane without one (every b-lane, the integration lanes, the
//! profile lanes) mints identities from FIXED seeds checked into the harness
//! (`haven/integration_test/e2e/_lib/test_user.dart`) — so the host knows the
//! secret, but not the pubkey, because deriving one needs secp256k1 and nothing
//! under `tooling/` had it. Without the derivation those lanes could declare
//! coordinates and names and nothing else, and a pubkey in a logcat would be
//! caught only by the structural rules — i.e. only in its 64-hex spelling, never
//! as an `npub`, a base64 core or a hex prefix.
//!
//! # Why the seeds are not secrets in the usual sense
//!
//! They are 32 repeated bytes, written down in a test file, shared by every run
//! of every lane, and never used outside an emulator. They are handled as
//! secret-class anyway (committed, never printed, never serialised) because the
//! SHAPE is what the discipline keys on — a tool that prints one kind of private
//! key learns to print the other — but the reader should not infer that argv on
//! a CI runner is a safe place for a real key. It is not, and nothing in Haven
//! puts one there.

use k256::elliptic_curve::sec1::ToEncodedPoint;
use k256::SecretKey;
use zeroize::Zeroizing;

/// Bytes in a secp256k1 secret.
const SEED_BYTES: usize = 32;

/// The x-only (BIP-340) public key of `seed_hex`, lower-case hex.
///
/// # Errors
///
/// Returns the reason, which NEVER quotes the seed or any part of it: a
/// malformed seed is a harness defect the operator fixes by reading the harness,
/// and an error string is a log line (Rule 15).
pub fn x_only_pubkey_hex(seed_hex: &str) -> Result<String, String> {
    // The decoded secret is wiped when this returns. `SecretKey` zeroizes its own
    // copy; this is the one the caller handed us, and the crate is allowed no
    // second reason to keep it.
    let bytes = Zeroizing::new(
        hex::decode(seed_hex)
            .map_err(|_| "--host-seed needs 32 bytes of hex (the value is withheld)".to_owned())?,
    );
    if bytes.len() != SEED_BYTES {
        return Err(format!(
            "--host-seed needs exactly {SEED_BYTES} bytes of hex, i.e. {} characters (the value is withheld)",
            SEED_BYTES * 2
        ));
    }
    // `from_slice` is what rejects the two scalars that are not secret keys —
    // zero and anything at or above the group order — so a typo'd seed is rc 2
    // rather than a derivation nobody can reproduce.
    let secret = SecretKey::from_slice(&bytes).map_err(|_| {
        "--host-seed is not a valid secp256k1 secret scalar (the value is withheld)".to_owned()
    })?;
    let point = secret.public_key().to_encoded_point(true);
    let x = point
        .x()
        .ok_or_else(|| "the derived public key has no x coordinate".to_owned())?;
    Ok(hex::encode(x))
}

#[cfg(test)]
mod tests {
    use super::x_only_pubkey_hex;

    /// The three harness seeds and the generator, computed OUTSIDE this crate.
    ///
    /// Two independent Python implementations produced these: affine
    /// double-and-add with Fermat inversion, and Jacobian coordinates driven by
    /// a Montgomery ladder with extended-Euclid inversion. Both reproduce the
    /// canonical `1G`/`2G`/`3G` x-coordinates first, so the arithmetic is
    /// anchored to published values and not merely to itself.
    ///
    /// The fourth row is the one the brief quotes as "`01`×32 → the generator".
    /// It is the generator's x-coordinate, but the secret that produces it is
    /// the SCALAR one — 31 zero bytes then `01` — not 32 bytes of `01`, which is
    /// the scalar `0x0101…01`. Both are pinned so the difference cannot be
    /// re-introduced by someone reading the brief's shorthand literally.
    const VECTORS: [(&str, &str); 4] = [
        (
            "0101010101010101010101010101010101010101010101010101010101010101",
            "1b84c5567b126440995d3ed5aaba0565d71e1834604819ff9c17f5e9d5dd078f",
        ),
        (
            "0202020202020202020202020202020202020202020202020202020202020202",
            "4d4b6cd1361032ca9bd2aeb9d900aa4d45d9ead80ac9423374c451a7254d0766",
        ),
        (
            "0303030303030303030303030303030303030303030303030303030303030303",
            "531fe6068134503d2723133227c867ac8fa6c83c537e9a44c3c5bdbdcb1fe337",
        ),
        (
            "0000000000000000000000000000000000000000000000000000000000000001",
            "79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798",
        ),
    ];

    #[test]
    fn the_derivation_matches_independently_computed_vectors() {
        for (seed, want) in VECTORS {
            assert_eq!(x_only_pubkey_hex(seed).as_deref(), Ok(want));
        }
    }

    #[test]
    fn the_derivation_is_case_insensitive_and_deterministic() {
        let (seed, want) = VECTORS[0];
        assert_eq!(x_only_pubkey_hex(&seed.to_uppercase()).as_deref(), Ok(want));
        assert_eq!(x_only_pubkey_hex(seed), x_only_pubkey_hex(seed));
    }

    #[test]
    fn a_malformed_seed_is_refused_and_never_quoted() {
        let order = "fffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141";
        for bad in [
            "",
            "0101",
            "zz01010101010101010101010101010101010101010101010101010101010101",
            "010101010101010101010101010101010101010101010101010101010101010",
            "0000000000000000000000000000000000000000000000000000000000000000",
            order,
        ] {
            let err = x_only_pubkey_hex(bad).expect_err("a malformed seed must be refused");
            assert!(
                !err.contains(bad) || bad.is_empty(),
                "an error must not quote the seed: {err}"
            );
            assert!(err.contains("withheld"), "{err}");
        }
    }
}
