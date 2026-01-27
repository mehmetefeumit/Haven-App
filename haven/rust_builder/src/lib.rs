//! Flutter-Rust bridge wrapper for haven-core.
//!
//! This crate serves as a thin wrapper that re-exports `haven-core` for
//! integration with the Flutter build system via Cargokit. The actual
//! FFI bridge code is generated in `haven-core`.

pub use haven_core::*;
