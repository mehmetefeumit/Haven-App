//! Flutter-Rust bridge wrapper for haven-core.

// Allow unsafe in generated FFI code
#![allow(clippy::not_unsafe_ptr_arg_deref)]
// Allow frb macro cfg attribute
#![allow(unexpected_cfgs)]
// `unsafe` is written in the two modules allowed below and nowhere else in
// this crate (`scripts/ci/check_mesh_radio.sh`).
#![deny(unsafe_code)]

pub mod api;

// The Android radio's JNI exports. The lint fires on `#[no_mangle]`, which
// every export carries; the module holds no `unsafe` block.
#[cfg(any(target_os = "android", test))]
#[allow(unsafe_code)]
mod mesh_jni;

// Test-only in-memory keyring backend. Compiled exclusively in debug builds
// — release callers see only the stub in `api.rs` that returns an error.
#[cfg(debug_assertions)]
mod test_keyring;

// Re-export location types from haven-core
pub use haven_core::location;

#[allow(unsafe_code)]
mod frb_generated;
pub use frb_generated::*;
