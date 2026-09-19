//! Tier-1 soak rig: a whole Haven world in one process, broken on purpose.
//!
//! A run builds real [`rig::SimDevice`]s — real MLS stores, real
//! `LiveSyncCore` engines, a real relay — applies a seeded schedule of faults
//! to them, and grades what survives. Nothing here is a mock of the subject:
//! the only test doubles are the *environment* (the relay plane, the timeline
//! and the log drain), which is why they are traits.
//!
//! # Rule 15 applies to the rig's own output
//!
//! Everything this crate renders is a sanctioned handle (`simdev#3`), a bucket,
//! a delta or a duration. The rig emits no `log::` records at all — the
//! timeline is the diagnostic — and every `Debug`/`Display` defined here is
//! value-free, which `tests/renderings.rs` proves by reading the population out
//! of this source and rendering each one on a populated value.
//!
//! # Module map
//!
//! Modules land as their owners land them; this file lists only what exists.
//! Nothing here is a placeholder for an unlanded module.

pub mod banner;
pub mod clock;
pub mod driver;
pub mod logsink;
pub mod nemesis;
pub mod oracle;
pub mod profiles;
pub mod rc;
pub mod relay;
pub mod rig;
pub mod scenarios;
pub mod timeline;
