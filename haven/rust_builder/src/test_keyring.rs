//! In-memory keyring backend for E2E tests.
//!
//! This module is compiled only in debug builds (`#[cfg(debug_assertions)]`).
//! Release builds receive a stub that returns an error so the test hook is
//! physically unreachable on shipped binaries.
//!
//! # Why this exists
//!
//! Haven's production keyring code calls platform-native credential stores
//! (Keychain, GNOME Keyring, Credential Manager, Android Keystore). Headless
//! CI runners (no D-Bus session bus, no logged-in user) cannot provide those
//! services, which causes our existing four integration tests
//! (`keyring_test.dart` and friends) to skip on CI. This module installs the
//! upstream `keyring_core::mock::Store` as the process-wide default so the
//! Rust crypto layer can call `Entry::new(...)` and round-trip secrets
//! without touching the OS.
//!
//! # Lifecycle and zeroization caveat
//!
//! The backing storage is owned by the static returned from
//! `keyring_core::set_default_store`. When the test process exits, the
//! store's `Arc<CredentialStore>` is dropped along with every `Cred`
//! it owns. Mock secrets never touch disk and never leave the process.
//!
//! **Caveat:** the upstream `keyring_core::mock::Cred` stores secret
//! bytes in `CredData { secret: Option<Vec<u8>> }` *without* `Zeroize`
//! or `ZeroizeOnDrop`. The `Vec<u8>` is freed when the `Cred` is
//! dropped, but the heap region is **not overwritten** — it stays
//! intact until the allocator reuses it. Subsequent process-memory
//! inspection (e.g. a debugger attaching, a core dump being written)
//! can still observe the bytes. This is acceptable for E2E tests with
//! ephemeral keys regenerated per run — the bytes have no value past
//! process exit anyway — but it does NOT satisfy CLAUDE.md rule #7
//! ("Use `Zeroizing<T>` ... for secret bytes"). Do not use this
//! backend as a model for the production keyring path, and do not
//! reuse it for any flow where a key derived from a long-lived
//! identity must be protected from in-process forensic recovery.
//!
//! # Why we wrap the upstream mock instead of implementing from scratch
//!
//! `keyring_core::mock::Store` already implements the
//! `CredentialStoreApi`/`CredentialApi` traits with the exact in-memory
//! `Mutex<RefCell<Vec<Arc<Cred>>>>` layout we want. Reimplementing the trait
//! would only duplicate that code; the upstream type is the right primitive.

use std::sync::Arc;

use keyring_core::CredentialStore;

/// Constructs the default in-memory credential store used by E2E tests.
///
/// Returns an `Arc<CredentialStore>` that can be handed to
/// `keyring_core::set_default_store`.
///
/// # Errors
///
/// Propagates any error from the upstream mock constructor.
pub(crate) fn build_in_memory_store() -> Result<Arc<CredentialStore>, String> {
    let store =
        keyring_core::mock::Store::new().map_err(|e| format!("in-memory keyring store: {e}"))?;
    // `mock::Store::new()` returns `Arc<Store>` which coerces via
    // `CoerceUnsized` to `Arc<CredentialStore>` (the trait object alias).
    Ok(store as Arc<CredentialStore>)
}
