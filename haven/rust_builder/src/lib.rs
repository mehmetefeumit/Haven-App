//! Flutter-Rust bridge wrapper for haven-core.

// Allow unsafe in generated FFI code
#![allow(clippy::not_unsafe_ptr_arg_deref)]
// Allow frb macro cfg attribute
#![allow(unexpected_cfgs)]

pub mod api;

// Test-only in-memory keyring backend. Compiled exclusively in debug builds
// — release callers see only the stub in `api.rs` that returns an error.
#[cfg(debug_assertions)]
mod test_keyring;

// Re-export location types from haven-core
pub use haven_core::location;

mod frb_generated;
pub use frb_generated::*;
