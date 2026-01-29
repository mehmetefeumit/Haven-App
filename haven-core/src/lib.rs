//! Haven Core Library
//!
//! Core functionality for Haven - private family location sharing.
//! This crate provides the Rust implementation for core Haven operations.

#![warn(clippy::all)]
#![warn(clippy::pedantic)]
#![warn(clippy::nursery)]
#![deny(unsafe_code)]

mod api;
pub mod location;

pub use api::HavenCore;
