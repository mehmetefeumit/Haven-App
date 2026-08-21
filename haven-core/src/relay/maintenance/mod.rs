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
//! * [`key_package`] — `KeyPackageMaintenance` (Dark Matter DM-2b): stable-`d`
//!   reuse/rotation and republish-if-missing for the user's own kind-30443
//!   `KeyPackage`, the one-time retirement of a pre-width-fix (malformed) `d`
//!   slot, plus the one-time cutover retraction of a legacy 443 twin and the
//!   abolished kind-10051 relay list. This module holds the pure,
//!   unit-testable decision + event-building logic; the network probe / publish
//!   orchestration is composed at the FFI boundary (which owns the identity
//!   secret and the `RelayManager`).
//! * [`kp_lifetime`] — the lifetime-aware rotation policy: read a
//!   `KeyPackage`'s OWN MLS `Lifetime` and decide from that (never from a Nostr
//!   event timestamp) whether it must be re-minted, plus the spec's
//!   `not_after` init-key deletion bound.
//! * [`relay_list`] — B1 `RelayListMaintenance` (M8-1): republish-if-missing /
//!   -drifted for the user's kind 10050 (inbox) + 10051 (`KeyPackage`) relay
//!   lists. Pure decision only; the own-relays network probe + signed publish
//!   are composed at the FFI boundary.

pub mod key_package;
pub mod kp_lifetime;
pub mod relay_list;

pub use kp_lifetime::{
    kp_init_key_purge_due, now_secs, read_kp_lifetime, KeyPackageLifetime, TrackedKpLifetime,
    KP_ROTATE_AT_LIFETIME_FRACTION,
};

pub use key_package::{
    build_key_package_relay_list_retraction, build_kp_maintenance_events,
    build_kp_maintenance_events_reusing, build_kp_slot_repoint_event, build_kp_slot_retraction,
    build_legacy_key_package_retraction, decide_kp_maintenance, decide_kp_slot_retirement,
    find_adoptable_kp_slot, is_conformant_slot_id, kp_event_d_tag, monotonic_kp_created_at,
    KpMaintenanceAction, KpMaintenanceDecision, KpMaintenanceEvents, KpMaintenanceOutcome,
    KpSlotRetirement, RelayKpEntry, RelayKpPerRelay, RelayKpSnapshot, KIND_MARMOT_KEY_PACKAGE,
};
pub use relay_list::{
    decide_relay_list, list_relay_healthy, RelayListAction, RelayListCategoryOutcome,
    RelayListDecision, RelayListMaintenanceOutcome, RelayListPerRelay, RelayListSnapshot,
};
