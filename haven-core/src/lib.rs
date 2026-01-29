//! Haven Core Library
//!
//! Core functionality for Haven - private family location sharing.
//! This crate provides the Rust implementation that bridges to the Flutter UI
//! via `flutter_rust_bridge`.

#![warn(clippy::all)]
#![warn(clippy::pedantic)]
#![warn(clippy::nursery)]
#![deny(unsafe_code)]
// Allow frb macro cfg attribute
#![allow(unexpected_cfgs)]

mod api;
pub mod location;

// Suppress lints on auto-generated code.
#[allow(clippy::all, clippy::pedantic, clippy::nursery, unsafe_code, unused)]
#[path = "frb_generated/mod.rs"]
mod frb_generated;

pub use api::HavenCore;
