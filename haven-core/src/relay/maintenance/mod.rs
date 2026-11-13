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
//!   slot, and the validation and ranking of another account's fetched
//!   `KeyPackage`s. This module holds the pure,
//!   unit-testable decision + event-building logic; the network probe / publish
//!   orchestration is composed at the FFI boundary (which owns the identity
//!   secret and the `RelayManager`).
//! * [`kp_lifetime`] — the lifetime-aware rotation policy: read a
//!   `KeyPackage`'s OWN MLS `Lifetime` and decide from that (never from a Nostr
//!   event timestamp) whether it must be re-minted.
//! * [`relay_list`] — B1 `RelayListMaintenance` (M8-1): republish-if-missing /
//!   -drifted for the user's kind 10050 (inbox) + 10002 (`KeyPackage`-discovery)
//!   relay lists, on the user's own relays and the lookup relays. Pure decision
//!   only; the network probe + signed publish are composed at the FFI boundary.
//! * [`own_presence`] — what each own relay and each lookup relay serves of
//!   the user's own `KeyPackage` and relay lists, asked with the probes above
//!   and judged by their rules (the relay settings check).

pub mod key_package;
pub mod kp_lifetime;
pub mod own_presence;
pub mod relay_list;

pub use kp_lifetime::{
    now_secs, read_kp_lifetime, KeyPackageLifetime, TrackedKpLifetime,
    KP_ROTATE_AT_LIFETIME_FRACTION,
};

pub use key_package::{
    build_kp_maintenance_events, build_kp_maintenance_events_reusing, build_kp_slot_repoint_event,
    build_kp_slot_retraction, decide_kp_maintenance, decide_kp_slot_retirement,
    find_adoptable_kp_slot, is_conformant_slot_id, kp_event_d_tag, kp_event_is_pre_migration,
    monotonic_kp_created_at, KpMaintenanceAction, KpMaintenanceDecision, KpMaintenanceEvents,
    KpMaintenanceOutcome, KpSlotRetirement, RelayKpEntry, RelayKpPerRelay, RelayKpSnapshot,
    TrackedKpSlot, KIND_MARMOT_KEY_PACKAGE,
};
pub use own_presence::{own_presence, OwnEventPresence, OwnRelayLists, OwnRelayPresence};
pub use relay_list::{
    decide_relay_list, list_relay_healthy, own_list_confirmed, RelayListAction,
    RelayListCategoryOutcome, RelayListDecision, RelayListMaintenanceOutcome, RelayListPerRelay,
    RelayListSnapshot,
};
