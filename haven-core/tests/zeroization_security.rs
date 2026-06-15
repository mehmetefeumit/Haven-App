//! Security Rule 7 (Secure Memory) coverage: the crate's `pub` secret-bearing
//! types must zeroize their secret material on drop.
//!
//! # Why this file exists
//!
//! An adversarial audit found that nothing *locked in* the zeroization
//! invariant for the crate's `pub` secret-bearing types. The
//! `#[derive(ZeroizeOnDrop)]` on those types is easy to delete by accident
//! (or a `#[zeroize(skip)]` could creep onto a secret field) with no test
//! catching the regression. The compile-time trait-bound assertion below fails
//! to compile the moment the derive is removed, turning a silent security
//! regression into a hard build error.
//!
//! # Scope
//!
//! The secret-bearing types *defined in* `haven-core/src/` are:
//!
//! * [`EphemeralKeypair`] — `secret_bytes: [u8; 32]`, `#[derive(ZeroizeOnDrop)]`
//! * [`IdentityKeypair`]  — `secret_bytes: [u8; 32]`, `#[derive(ZeroizeOnDrop)]`
//!
//! All *other* secret material in the crate is either held by MDK / `nostr`
//! types (never owned by a haven-core struct — the `get_stored_exporter_secret`
//! accessor returns only a `bool`, never raw bytes) or carried transiently in a
//! `Zeroizing<…>` wrapper. The scrubbing behavior of `Zeroizing`/`zeroize()`
//! itself is guaranteed by the upstream `zeroize` crate's own test suite;
//! re-asserting it here would test the dependency rather than haven-core, so we
//! deliberately do not.
//!
//! No security/privacy data is printed here: the assertion is a compile-time
//! trait bound only.

use haven_core::nostr::identity::IdentityKeypair;
use haven_core::nostr::EphemeralKeypair;
use zeroize::ZeroizeOnDrop;

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
