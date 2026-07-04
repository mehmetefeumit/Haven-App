//! Scheduled resilience maintenance (M8).
//!
//! Periodic, idempotent, fail-soft republish-if-missing safety nets that keep a
//! user reachable on their own relays even when a trigger-based publish was
//! missed (the "damus never sees my `KeyPackage`" reachability class, relay
//! audit #4). Maintenance NEVER authors group commits and never touches MLS
//! epochs — `KeyPackages` are pre-group init material.
//!
//! # Module layout
//!
//! * [`key_package`] — B2 `KeyPackageMaintenance` (M8-2): stable-`d` rotation,
//!   the live-material gate, and republish-if-missing. This module holds the
//!   pure, unit-testable decision + event-building logic; the network probe /
//!   publish orchestration is composed at the FFI boundary (which owns the
//!   identity secret and the `RelayManager`).
//! * [`relay_list`] — B1 `RelayListMaintenance` (M8-1): republish-if-missing /
//!   -drifted for the user's kind 10050 (inbox) + 10051 (`KeyPackage`) relay
//!   lists. Pure decision only; the own-relays network probe + signed publish
//!   are composed at the FFI boundary.

pub mod key_package;
pub mod relay_list;

pub use key_package::{
    build_kp_maintenance_events, build_legacy_twin_deletion, decide_kp_maintenance,
    KpMaintenanceAction, KpMaintenanceDecision, KpMaintenanceEvents, KpMaintenanceOutcome,
    RelayKpEntry, RelayKpPerRelay, RelayKpSnapshot,
};
pub use relay_list::{
    decide_relay_list, list_relay_healthy, RelayListAction, RelayListCategoryOutcome,
    RelayListDecision, RelayListMaintenanceOutcome, RelayListPerRelay, RelayListSnapshot,
};
