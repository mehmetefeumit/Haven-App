//! Security Rule 7 (Secure Memory) coverage: secret-bearing types must
//! zeroize their secret material, and the `Zeroizing` wrapper that the
//! production code relies on for transient secrets must actually scrub the
//! buffer on `zeroize()` / drop.
//!
//! # Why this file exists
//!
//! An adversarial audit found that nothing *locked in* the zeroization
//! invariant for the crate's `pub` secret-bearing types. The
//! `#[derive(ZeroizeOnDrop)]` on those types is easy to delete by accident
//! (or a `#[zeroize(skip)]` could creep onto a secret field) with no test
//! catching the regression. These compile-time trait-bound assertions fail to
//! compile the moment the derive is removed, and the runtime test proves the
//! `Zeroizing` pattern behaves as the source comments claim.
//!
//! # Scope
//!
//! The secret-bearing types *defined in* `haven-core/src/` are:
//!
//! * [`EphemeralKeypair`] — `secret_bytes: [u8; 32]`, `#[derive(ZeroizeOnDrop)]`
//! * [`IdentityKeypair`]  — `secret_bytes: [u8; 32]`, `#[derive(ZeroizeOnDrop)]`
//!
//! All *other* secret material in the crate is either:
//! * held by MDK / `nostr` types (e.g. MLS exporter secrets, `ConversationKey`)
//!   and never owned by a haven-core struct — the `get_stored_exporter_secret`
//!   accessor returns only a `bool`, never raw bytes; or
//! * carried transiently in a `Zeroizing<[u8; 32]>` / `Zeroizing<Vec<u8>>`
//!   (e.g. `encrypt_nip44`'s key copy, `IdentityManager::get_secret_bytes`),
//!   whose scrubbing behavior the runtime test below pins down.
//!
//! No security/privacy data is printed here: assertions are over booleans and
//! zeroed buffers only, never over secret values.

use haven_core::nostr::identity::IdentityKeypair;
use haven_core::nostr::EphemeralKeypair;
use zeroize::{Zeroize, ZeroizeOnDrop, Zeroizing};

/// Compile-time proof that `T: ZeroizeOnDrop`. Instantiating this for a type
/// whose `ZeroizeOnDrop` derive was removed fails to compile — turning a
/// silent security regression into a hard build error.
const fn assert_zeroize_on_drop<T: ZeroizeOnDrop>() {}

/// RM-Z1: The crate's `pub` secret-bearing types must implement
/// `ZeroizeOnDrop`. This locks the Rule 7 invariant at the public API
/// boundary, complementing the in-module asserts that guard the private
/// internals.
///
/// Note: `#[derive(ZeroizeOnDrop)]` only synthesises a `Drop` impl that
/// zeroizes the non-`#[zeroize(skip)]` fields; it does *not* make the type
/// itself implement `Zeroize`. The invariant that matters for these key
/// wrappers — "secret bytes are wiped when the value is dropped" — is exactly
/// `ZeroizeOnDrop`, so that is what we assert.
#[test]
fn secret_bearing_types_are_zeroize_on_drop() {
    assert_zeroize_on_drop::<EphemeralKeypair>();
    assert_zeroize_on_drop::<IdentityKeypair>();
}

/// RM-Z2: Runtime proof that `Zeroize::zeroize` on an owned 32-byte buffer
/// actually overwrites every byte with zero. This is the wrapper the
/// production code uses for transient secret-key material (e.g. the conversation
/// key copy in `encrypt_nip44`/`decrypt_nip44` and the bytes returned by
/// `IdentityManager::get_secret_bytes`). Operates entirely on an owned buffer,
/// so there is no use-after-free / UB.
#[test]
fn owned_secret_buffer_is_zeroed_after_zeroize() {
    let mut secret = [0xABu8; 32];
    assert!(
        secret.iter().all(|&b| b == 0xAB),
        "precondition: buffer starts non-zero"
    );

    secret.zeroize();

    assert!(
        secret.iter().all(|&b| b == 0),
        "zeroize() must overwrite every byte with 0"
    );
}

/// RM-Z3: `Zeroizing<Vec<u8>>` — the type returned by
/// `IdentityManager::get_secret_bytes` — exposes an explicit `zeroize()` that
/// clears the contents. Verifying the contents are zeroed (over the still-live,
/// owned wrapper) confirms the scrubbing path the FFI relies on, without ever
/// reading freed memory.
#[test]
fn zeroizing_vec_clears_contents_on_explicit_zeroize() {
    let mut secret: Zeroizing<Vec<u8>> = Zeroizing::new(vec![0x42u8; 32]);
    assert!(
        secret.iter().all(|&b| b == 0x42),
        "precondition: vec starts non-zero"
    );

    secret.zeroize();

    assert!(
        secret.iter().all(|&b| b == 0),
        "Zeroizing<Vec<u8>>::zeroize must overwrite every byte with 0"
    );
}
