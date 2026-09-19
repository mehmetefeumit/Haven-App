//! The nemesis: what breaks, when, and how it heals.
//!
//! [`types`] is the vocabulary — the schedule value types a run is reproducible
//! from, and the one place a fault is named. The generator that mints a
//! schedule from a seed is a separate module, because the vocabulary is what
//! every other part of the crate compiles against while the minting is one
//! owner's algorithm.

pub mod generator;
pub mod types;
