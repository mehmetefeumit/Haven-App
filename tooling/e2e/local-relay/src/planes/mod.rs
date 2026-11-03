//! The relay-plane judge: which relay role may receive which frame, applied
//! to what a relay received.
//!
//! [`policy`] is the matrix, [`table`] the ground truth a run supplies,
//! [`judge`] the one function every layer of the relay-plane proof calls:
//! haven-core's and `rust_builder`'s tests, the soak rig, and the E2E journal
//! consumer here ([`cli`], binary `haven-wire-planes`). It reads frames with
//! `serde_json` alone: no haven-core, nostr or tokio type enters it, so every
//! consumer judges the same bytes the same way.

pub mod cli;
pub mod frame;
pub mod judge;
pub mod policy;
pub mod table;
