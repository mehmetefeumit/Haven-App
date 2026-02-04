//! Haven Core Library
//!
//! Core functionality for Haven - private family location sharing.
//! This crate provides the Rust implementation for core Haven operations.

#![warn(clippy::all)]
#![warn(clippy::pedantic)]
#![warn(clippy::nursery)]
#![deny(unsafe_code)]

// Prevent accidental release builds with test-utils enabled.
// The test-utils feature enables unencrypted storage which must never be used in production.
#[cfg(all(feature = "test-utils", not(debug_assertions)))]
compile_error!(
    "The 'test-utils' feature enables unencrypted storage and must not be used in release builds. \
     Remove the 'test-utils' feature from your Cargo.toml for production builds."
);

mod api;
pub mod circle;
pub mod location;
pub mod nostr;
pub mod relay;

pub use api::HavenCore;
