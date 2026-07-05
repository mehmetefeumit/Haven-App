//! B2 `KeyPackageMaintenance` (M8-2): the pure decision + event-building core.
//!
//! This module answers one question idempotently: **does the user's `KeyPackage`
//! need republishing to their own `KeyPackage` relays right now?** It never
//! touches the network and never signs — the network probe and the signed
//! publish are composed at the FFI boundary (which owns the identity secret and
//! the [`RelayManager`]). Everything here is either fully pure
//! ([`decide_kp_maintenance`], [`RelayKpSnapshot`], [`KpMaintenanceOutcome`]) or
//! takes an injected [`MdkManager`] to build the `KeyPackage` material
//! ([`build_kp_maintenance_events`]).
//!
//! # The live-material gate (marmot CRITICAL)
//!
//! Republish is gated on **live local MLS init-key material**, NOT relay
//! presence. A relays-only presence check would republish DEAD `KeyPackages`
//! (whose private `init_key` was consumed by a Welcome and then deleted
//! locally) — republishing over a consumed slot breaks Welcome processing for
//! anyone who still holds the stale event. The FFI computes the live-material
//! signal by asking MDK's `OpenMLS` `StorageProvider` whether the private
//! material for each tracked `hash_ref` is still stored
//! ([`MdkManager::has_live_key_material`]), then passes the boolean here.
//!
//! # Stable `d` (MIP-00 #6)
//!
//! MDK mints a fresh random NIP-33 `d` per `KeyPackage`, so a naive rotation
//! creates a brand-new addressable coordinate every cycle — a peer that cached
//! the old address never sees the new package. Maintenance reuses a **stable
//! `d`**: on first run it seeds the `d` from an existing on-relay 30443
//! ([`KpMaintenanceDecision::SeedD`]); thereafter it republishes into the same
//! `(kind, pubkey, d)` slot via [`MdkManager::create_key_package_with_d`], so a
//! rotation REPLACES the slot (NIP-33 same-`d` supersession) instead of piling
//! up orphaned coordinates.
//!
//! # Supersession, never a redundant delete
//!
//! NIP-33 same-`d` slot replacement is the authoritative supersession
//! mechanism for the canonical 30443, so a republish emits **no** NIP-09 for
//! it. A kind-5 delete is only ever built for a legacy 443 twin (a
//! non-addressable regular event with no stable slot) and, when built, targets
//! that twin **by event id only** (an `e` tag, never an `a`-coordinate — see
//! [`build_legacy_twin_deletion`] for why the coordinate form is invalid and
//! harmful here) under a self-authorship guard (author == own pubkey).
//!
//! [`RelayManager`]: crate::relay::RelayManager

use nostr::nips::nip09::EventDeletionRequest;
use nostr::{EventBuilder, EventId, Keys};

use crate::nostr::mls::types::KeyPackageBundle;
use crate::nostr::mls::MdkManager;
use crate::relay::publishers::{PublisherError, PublisherResult};

/// The legacy (non-addressable) `KeyPackage` event kind.
///
/// Test-only: the twin deletion is now built by event id (an id-only NIP-09
/// implies the kind), so no non-test code names this kind directly.
#[cfg(test)]
const KEY_PACKAGE_KIND_LEGACY: u16 = 443;

/// One canonical (kind 30443) `KeyPackage` event the FFI found on the user's own
/// `KeyPackage` relays, reduced to only the fields the decision needs.
///
/// Fieldless of any secret: `d_tag` and `event_id` are public Nostr
/// identifiers, and `hash_ref_matches_local_live` is the pre-computed
/// live-material verdict for this event's `hash_ref` (the FFI ran
/// [`MdkManager::has_live_key_material`] against the row recorded in
/// `published_key_packages`; a probed event whose `hash_ref` we never tracked
/// reads `false`). Deriving `Debug` here is leak-free because the raw
/// `hash_ref` bytes never enter this struct — only the boolean verdict.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RelayKpEntry {
    /// The NIP-33 `d` tag of the on-relay canonical event.
    pub d_tag: String,
    /// Lowercase-hex Nostr event id of the on-relay canonical event.
    pub event_id: String,
    /// Whether this event's `KeyPackage` still has LIVE private init-key material
    /// stored locally (the [`MdkManager::has_live_key_material`] verdict).
    pub hash_ref_matches_local_live: bool,
}

/// One RESPONDING own-`KeyPackage`-relay's canonical (kind 30443) entries
/// (FFI-built).
///
/// `relay_url` is a user-configured own-relay URL — callers MUST NOT log this
/// struct, and it MUST NEVER enter a maintenance OUTCOME (only integer counts
/// cross the FFI). Non-responders are NOT represented here: they are neither a
/// heal target nor "unhealthy" (you cannot write to an unreachable relay), so
/// excluding them at snapshot-build time makes "never target a non-responder" a
/// STRUCTURAL invariant. `canonical` holds only this relay's own 30443 entries.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RelayKpPerRelay {
    /// The own-relay URL these entries came from. MUST NOT be logged / put in an
    /// outcome.
    pub relay_url: String,
    /// The canonical (kind 30443) `KeyPackage` events THIS relay served.
    pub canonical: Vec<RelayKpEntry>,
}

impl RelayKpPerRelay {
    /// Returns whether this relay serves a canonical `KeyPackage` backed by LIVE
    /// local init-key material — the load-bearing per-relay gate. Mere presence
    /// (a canonical whose material is DEAD/consumed) does NOT count as healthy.
    #[must_use]
    fn serves_live(&self) -> bool {
        self.canonical.iter().any(|e| e.hash_ref_matches_local_live)
    }

    /// Returns this relay's byte-order-MIN non-empty on-relay `d`, for seed
    /// selection. `min` (not "first") so selection is deterministic even when a
    /// relay serves multiple 30443 slots in a fetch-order-dependent sequence.
    #[must_use]
    fn min_d(&self) -> Option<&str> {
        self.canonical
            .iter()
            .map(|e| e.d_tag.as_str())
            .filter(|d| !d.is_empty())
            .min()
    }
}

/// What the FFI found on the user's OWN `KeyPackage` relays for their own pubkey.
///
/// Built by probing the user's configured `KeyPackage` relays INDEPENDENTLY
/// (never the discovery plane, never a default union, never a merged union) for
/// kind-30443 events authored by the user, then annotating each with the local
/// live-material verdict. `responders` carries RESPONDING relays only; empty
/// means every configured relay was unreachable this tick.
///
/// `relay_url` values ARE present, so callers must NOT log a `RelayKpSnapshot`;
/// only the presence-only OUTCOME (integer counts) crosses the FFI.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct RelayKpSnapshot {
    /// Canonical (kind 30443) entries for RESPONDING own relays only.
    pub responders: Vec<RelayKpPerRelay>,
}

/// The deterministic canonical seed-`d`: the byte-order-MIN over each
/// responder's own min non-empty on-relay `d` — i.e. the global byte-min
/// non-empty `d` across all responders. Fully stable regardless of relay
/// iteration order OR intra-relay event order, so the
/// [`SeedD`](KpMaintenanceDecision::SeedD) → republish handoff and its test are
/// reproducible even when different relays advertise different `d`s.
fn pick_seed_d(snapshot: &RelayKpSnapshot) -> Option<String> {
    snapshot
        .responders
        .iter()
        .filter_map(RelayKpPerRelay::min_d)
        .min()
        .map(str::to_owned)
}

/// The maintenance decision for one `KeyPackage` tick.
///
/// [`NoOp`](Self::NoOp)/[`SeedD`](Self::SeedD) carry no relay URL, but
/// [`Republish`](Self::Republish) carries own-relay `targets`, so a
/// `KpMaintenanceDecision` MUST NOT be logged (only the presence-only OUTCOME
/// crosses the FFI).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum KpMaintenanceDecision {
    /// Every responding relay already serves a live-material canonical
    /// `KeyPackage` (or no relay responded this tick) — nothing to do.
    NoOp,
    /// First-run seeding: at least one responder serves a canonical whose `d`
    /// is not yet tracked locally. The FFI must record the seed `d` into
    /// `published_key_packages` (with the on-relay event id) BEFORE any future
    /// generate, so stability holds from cycle 1. No new material is published
    /// this tick; the next tick republishes into the seeded slot if needed.
    SeedD {
        /// The deterministic stable `d` adopted from the responders' 30443s.
        d: String,
    },
    /// One or more responding relays lack a live-material canonical — republish
    /// the CURRENT LIVE material into the stable slot (`existing_d`, or mint if
    /// `None`) to exactly these relays. Always non-empty.
    Republish {
        /// The stable `d` to republish into, or `None` to mint a new slot.
        existing_d: Option<String>,
        /// The responding, non-live own-relay URLs to (re)publish to.
        targets: Vec<String>,
    },
}

/// Decides the `KeyPackage` maintenance action for this tick (PURE).
///
/// The PER-RELAY live-material gate: a responder is healthy iff it serves a
/// canonical `KeyPackage` backed by LIVE local init-key material
/// ([`RelayKpPerRelay::serves_live`]), NOT by mere presence. A responder that
/// serves only DEAD/consumed canonicals (or none) is a heal target. This
/// per-relay decision is the headline fix: a package live on relay A but
/// dropped from relay B republishes to B ONLY (A untouched), whereas the old
/// merged `any_live` short-circuit would have returned `NoOp` and left the user
/// undiscoverable on B.
///
/// `live_material_present` is retained for signature stability (the FFI still
/// passes it), but it is NO LONGER a global `NoOp` short-circuit — that
/// aggregate-blindness short-circuit was exactly the partial-drop bug.
///
/// Ordering of the branches:
///
/// 1. **No responders** (all transiently unreachable this tick) ⇒
///    [`KpMaintenanceDecision::NoOp`] (fail-closed; we cannot confirm any drop,
///    so retry next tick).
/// 2. **Every responder serves live** ⇒ [`KpMaintenanceDecision::NoOp`].
/// 3. **≥1 non-live responder AND no stored stable `d` AND some responder
///    serves a well-formed `d`** ⇒ [`KpMaintenanceDecision::SeedD`]: adopt that
///    `d` (deterministically, [`pick_seed_d`]) before generating, so cycle 1
///    does not fork the address. Record-only, no publish; the republish happens
///    next tick into the seeded slot.
/// 4. **≥1 non-live responder** ⇒ [`KpMaintenanceDecision::Republish`] into the
///    stored stable `d` when known, else `None` (mint + record a new slot),
///    targeting exactly the non-live responders.
///
/// `stored_stable_d` is the caller's `latest_canonical_d_tag()` from
/// `published_key_packages`.
#[must_use]
pub fn decide_kp_maintenance(
    snapshot: &RelayKpSnapshot,
    _live_material_present: bool,
    stored_stable_d: Option<&str>,
) -> KpMaintenanceDecision {
    // Branch 1: fail-closed. No responders ⇒ can't confirm any drop this tick.
    if snapshot.responders.is_empty() {
        return KpMaintenanceDecision::NoOp;
    }

    // Per-relay live-material gate: the non-live responders are the heal set.
    let targets: Vec<String> = snapshot
        .responders
        .iter()
        .filter(|r| !r.serves_live())
        .map(|r| r.relay_url.clone())
        .collect();

    // Branch 2: every responder serves a live canonical ⇒ healthy ⇒ NoOp.
    if targets.is_empty() {
        return KpMaintenanceDecision::NoOp;
    }

    // Branch 3: first-run seeding. ≥1 confirmed drop and no stored stable `d`;
    // adopt a well-formed on-relay `d` (deterministic min) as our stable slot
    // BEFORE generating, so we never fork the address on cycle 1. A degenerate
    // empty `d` is filtered by `first_d`, so `pick_seed_d` never adopts it —
    // in that case we fall through to Republish (mint a fresh, well-formed `d`).
    if stored_stable_d.is_none() {
        if let Some(d) = pick_seed_d(snapshot) {
            return KpMaintenanceDecision::SeedD { d };
        }
    }

    // Branch 4: republish current live material to the non-live responders.
    KpMaintenanceDecision::Republish {
        existing_d: stored_stable_d.map(str::to_owned),
        targets,
    }
}

/// The `KeyPackage` material to sign+publish for a [`KpMaintenanceDecision::Republish`].
///
/// A thin, `Debug`-redacting wrapper over the [`KeyPackageBundle`] the FFI
/// signs (kinds 30443 + 443) plus the resolved own-relay targets. The bundle's
/// own `Debug` already redacts `content`/`hash_ref`. The `d_tag` + `relays`
/// fields WOULD leak (a NIP-33 `d` and relay URLs) under a derived `Debug`, so
/// the `Debug` is hand-written to be presence-only (Security Rule 4/6).
#[derive(Clone)]
pub struct KpMaintenanceEvents {
    /// The `KeyPackage` bundle to sign (kind 30443 + legacy 443 twin).
    pub bundle: KeyPackageBundle,
    /// The stable NIP-33 `d` the bundle was built with (to record on publish).
    pub d_tag: String,
    /// The own-relay targets — dedup'd, own-relays-only, never a default union.
    pub relays: Vec<String>,
}

impl std::fmt::Debug for KpMaintenanceEvents {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("KpMaintenanceEvents")
            .field("bundle", &self.bundle) // KeyPackageBundle Debug self-redacts
            .field("d_tag", &"<redacted>")
            .field("relay_count", &self.relays.len())
            .finish()
    }
}

/// Builds the `KeyPackage` bundle for a [`KpMaintenanceDecision::Republish`].
///
/// Given the decision's `existing_d` (or `None` to mint a fresh slot), builds
/// the 30443 (+443 twin) bundle via [`MdkManager::create_key_package_with_d`]
/// so a rotation replaces the same NIP-33 coordinate. The returned
/// [`KpMaintenanceEvents::relays`] is exactly `own_kp_relays` — the FFI passes
/// the user's own `KeyPackage` relays and this function does NOT union in any
/// default set (own-relays-only invariant; see the no-default-union test).
///
/// This is the ONLY function in the module that touches MDK (SQLite): the
/// decision above is pure. Returns `None` inputs unchanged only through the
/// bundle; the FFI signs the bundle exactly as `sign_key_package_event` does.
///
/// # Errors
///
/// Returns [`PublisherError::Build`] if MDK `KeyPackage` generation fails (the
/// inner string is redacted, suitable for `debug!` but excluded from
/// `Display`).
pub fn build_kp_maintenance_events(
    mdk: &MdkManager,
    identity_pubkey: &str,
    own_kp_relays: &[String],
    existing_d: Option<&str>,
) -> PublisherResult<KpMaintenanceEvents> {
    let bundle = mdk
        .create_key_package_with_d(identity_pubkey, own_kp_relays, existing_d)
        .map_err(|e| PublisherError::Build(format!("build key package: {e}")))?;

    let d_tag = bundle.d_tag.clone();
    Ok(KpMaintenanceEvents {
        // Own-relays-only: the publish targets are exactly what the caller
        // passed. `create_key_package_with_d` already echoes `own_kp_relays`
        // into `bundle.relays`, but we surface the caller's list explicitly so
        // the own-relays-only invariant is provable at this boundary and does
        // not depend on MDK's internal echo.
        relays: own_kp_relays.to_vec(),
        bundle,
        d_tag,
    })
}

/// Builds a self-authored NIP-09 (kind 5) deletion for a LEGACY 443 twin only.
///
/// A canonical (30443) rotation supersedes itself via NIP-33 same-`d`
/// replacement, so it is NEVER deleted here. The legacy 443 twin has no stable
/// addressable slot, so a stale twin must be scrubbed explicitly. This function
/// refuses unless the event author is the user themselves
/// (`author == keys.public_key()`, the self-authorship guard) — we never author
/// a deletion of someone else's event.
///
/// The deletion references the twin **by event id only** (a single `e` tag) and
/// deliberately carries **NO** `a`-coordinate. Kind 443 is a NON-addressable
/// regular event, so a `443:<pubkey>:` coordinate (empty identifier) is invalid
/// for it: per NIP-09, cooperative relays honor such a coordinate by deleting
/// EVERY kind-443 the author has with `created_at <= deletion`. Because the
/// maintenance path publishes the FRESH 443 twin BEFORE this deletion, that
/// fresh twin's `created_at` is `<=` the deletion's — so a coordinate deletion
/// would delete the very twin the republish just healed. An id-only `e`-tag
/// deletion scrubs exactly the one superseded twin and nothing else. (Contrast
/// [`build_nip09_deletion`], which DOES emit the coordinate — correct there
/// because 10050/10051 are replaceable, addressable kinds whose coordinate form
/// is well-defined.)
///
/// # Errors
///
/// Returns [`PublisherError::Build`] if the self-authorship guard fails, if the
/// event id is malformed, or if signing fails.
///
/// [`build_nip09_deletion`]: crate::relay::publishers::build_nip09_deletion
pub fn build_legacy_twin_deletion(
    keys: &Keys,
    legacy_event_id_hex: &str,
    event_author_hex: &str,
) -> PublisherResult<nostr::Event> {
    // Self-authorship guard (security must-fix): never author a deletion of an
    // event we did not sign. Compared as lowercase hex to defeat case skew.
    let own_hex = keys.public_key().to_hex();
    if !event_author_hex.eq_ignore_ascii_case(&own_hex) {
        return Err(PublisherError::Build(
            "refusing to delete an event authored by another key".to_owned(),
        ));
    }

    let event_id = EventId::from_hex(legacy_event_id_hex)
        .map_err(|e| PublisherError::Build(format!("bad legacy event id: {e}")))?;

    // Id-only (`e`-tag) deletion — NO `a`-coordinate. Kind 443 is a
    // non-addressable regular event; a `443:<pubkey>:` coordinate would tell
    // relays to delete ALL of the author's kind-443 events with
    // `created_at <= deletion`, nuking the fresh twin the republish just
    // published (which is older than this deletion).
    let request = EventDeletionRequest::new().ids(vec![event_id]);
    EventBuilder::delete(request)
        .sign_with_keys(keys)
        .map_err(|e| PublisherError::Build(format!("sign deletion: {e}")))
}

/// The terminal action a `KeyPackage` maintenance tick carried out.
///
/// Fieldless (Copy) and payload-free — no `d`, url, hex, or group id — so its
/// derived `Debug` cannot leak (Security Rule 4/6).
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum KpMaintenanceAction {
    /// A live-material canonical `KeyPackage` was already reachable — no change.
    #[default]
    AlreadyHealthy,
    /// A stable `d` was seeded from an on-relay canonical this tick; no publish.
    SeededD,
    /// A `KeyPackage` was (re)published into a reused, tracked/seeded stable `d`.
    RepublishedStableD,
    /// A `KeyPackage` was published into a freshly-minted `d` (first-ever slot).
    RepublishedFreshD,
}

/// Presence-only tally of a `KeyPackage` maintenance tick.
///
/// The action is an enum and the remaining fields are counts — no urls, hex,
/// `d` values, or group ids — so the derived `Debug` is leak-free by
/// construction (Security Rule 4/6). This is the shape the FFI folds ticks into
/// and returns to Dart.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct KpMaintenanceOutcome {
    /// What the tick did.
    pub action: KpMaintenanceAction,
    /// Own-relay canonical events observed by the probe (summed across
    /// responders).
    pub canonical_on_relays: usize,
    /// Responding own relays probed this tick (non-responders excluded).
    pub responders_probed: usize,
    /// Responding + non-live relays this tick republished to.
    pub relays_healed: usize,
    /// Relay probes/publishes that errored (tallied, never fatal).
    pub relay_errors: usize,
}

impl KpMaintenanceOutcome {
    /// Builds the outcome for a decision that resolved to [`KpMaintenanceDecision::NoOp`].
    #[must_use]
    pub const fn no_op(canonical_on_relays: usize) -> Self {
        Self {
            action: KpMaintenanceAction::AlreadyHealthy,
            canonical_on_relays,
            responders_probed: 0,
            relays_healed: 0,
            relay_errors: 0,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use nostr::Kind;

    fn entry(d: &str, id: &str, live: bool) -> RelayKpEntry {
        RelayKpEntry {
            d_tag: d.to_owned(),
            event_id: id.to_owned(),
            hash_ref_matches_local_live: live,
        }
    }

    fn per(url: &str, entries: Vec<RelayKpEntry>) -> RelayKpPerRelay {
        RelayKpPerRelay {
            relay_url: url.to_owned(),
            canonical: entries,
        }
    }

    fn snapshot(responders: Vec<RelayKpPerRelay>) -> RelayKpSnapshot {
        RelayKpSnapshot { responders }
    }

    // ---- Test 10: all responders serve-live ⇒ NoOp ------------------------

    #[test]
    fn all_responders_serve_live_is_noop() {
        let snap = snapshot(vec![
            per("wss://a.example.com", vec![entry("d-live", "ev1", true)]),
            per("wss://b.example.com", vec![entry("d-live", "ev2", true)]),
        ]);
        assert_eq!(
            decide_kp_maintenance(&snap, false, Some("d-live")),
            KpMaintenanceDecision::NoOp
        );
    }

    // ---- Test 11: PARTIAL-DROP regression (the headline bug) --------------

    #[test]
    fn partial_drop_a_live_b_empty_republishes_to_b_only() {
        // A serves a live canonical; B responded but serves nothing (dropped).
        // The OLD merged `any_live` logic would have seen A's live copy and
        // returned NoOp, leaving the user undiscoverable on B. The per-relay
        // gate republishes to B ONLY.
        let snap = snapshot(vec![
            per("wss://a.example.com", vec![entry("d-slot", "ev1", true)]),
            per("wss://b.example.com", vec![]),
        ]);
        assert_eq!(
            decide_kp_maintenance(&snap, false, Some("d-slot")),
            KpMaintenanceDecision::Republish {
                existing_d: Some("d-slot".to_owned()),
                targets: vec!["wss://b.example.com".to_owned()],
            }
        );

        // Explicit proof the old aggregate rule would have masked this: ANY
        // live entry across the union exists, so a merged `any_live` is true.
        let any_live_merged = snap
            .responders
            .iter()
            .flat_map(|r| r.canonical.iter())
            .any(|e| e.hash_ref_matches_local_live);
        assert!(
            any_live_merged,
            "the merged any_live signal IS true here — the old short-circuit \
             would have wrongly returned NoOp; the per-relay gate must not"
        );
    }

    // ---- Test 12: live_material_present demotion ---------------------------

    #[test]
    fn live_material_present_true_but_a_responder_lacks_live_still_republishes() {
        // Even with the retained live_material_present flag set, a responder
        // that lacks a live canonical is still healed (the flag no longer
        // short-circuits to NoOp).
        let snap = snapshot(vec![
            per("wss://a.example.com", vec![entry("d-slot", "ev1", true)]),
            per("wss://b.example.com", vec![entry("d-dead", "ev2", false)]),
        ]);
        assert_eq!(
            decide_kp_maintenance(&snap, true, Some("d-slot")),
            KpMaintenanceDecision::Republish {
                existing_d: Some("d-slot".to_owned()),
                targets: vec!["wss://b.example.com".to_owned()],
            }
        );
    }

    // ---- Test 13: empty responders ⇒ NoOp (fail-closed) -------------------

    #[test]
    fn empty_responders_is_noop() {
        let snap = snapshot(vec![]);
        assert_eq!(
            decide_kp_maintenance(&snap, false, Some("d-x")),
            KpMaintenanceDecision::NoOp
        );
    }

    #[test]
    fn empty_responders_no_stored_d_is_noop_not_false_seed() {
        // No responders + no stored `d` must NOT synthesize a false SeedD; we
        // cannot confirm any drop this tick, so NoOp.
        let snap = snapshot(vec![]);
        assert_eq!(
            decide_kp_maintenance(&snap, false, None),
            KpMaintenanceDecision::NoOp
        );
    }

    // ---- Test 14: confirmed drop + no stored d + good relay d ⇒ SeedD -----

    #[test]
    fn confirmed_drop_no_stored_d_with_good_relay_d_seeds() {
        // A responder serves a canonical (dead/consumed) with a well-formed `d`
        // but we have never tracked its `d` ⇒ adopt it as the stable slot
        // (record-only, no targets).
        let snap = snapshot(vec![per(
            "wss://a.example.com",
            vec![entry("d-onrelay", "ev1", false)],
        )]);
        assert_eq!(
            decide_kp_maintenance(&snap, false, None),
            KpMaintenanceDecision::SeedD {
                d: "d-onrelay".to_owned(),
            }
        );
    }

    // ---- Test 15: pick_seed_d determinism ---------------------------------

    #[test]
    fn pick_seed_d_is_byte_order_min_across_disagreeing_responders() {
        // A serves d="m", B serves d="a" (both dead). The seed is the byte-min
        // "a" regardless of relay iteration order; empty `d`s are skipped.
        let snap = snapshot(vec![
            per(
                "wss://a.example.com",
                vec![entry("", "ev-empty", false), entry("m-slot", "ev1", false)],
            ),
            per("wss://b.example.com", vec![entry("a-slot", "ev2", false)]),
        ]);
        assert_eq!(
            decide_kp_maintenance(&snap, false, None),
            KpMaintenanceDecision::SeedD {
                d: "a-slot".to_owned(),
            }
        );
    }

    // ---- Test 16: SeedD → handoff to Republish ----------------------------

    #[test]
    fn seed_handoff_next_tick_republishes_into_seeded_slot() {
        // Same snapshot as the seed case, but now stored_d = Some(seed): the
        // slot is tracked, so we republish into it, targeting the non-live
        // responder.
        let snap = snapshot(vec![per(
            "wss://a.example.com",
            vec![entry("d-seed", "ev1", false)],
        )]);
        assert_eq!(
            decide_kp_maintenance(&snap, false, Some("d-seed")),
            KpMaintenanceDecision::Republish {
                existing_d: Some("d-seed".to_owned()),
                targets: vec!["wss://a.example.com".to_owned()],
            }
        );
    }

    // ---- Test 17: only an empty on-relay d + no stored d ⇒ Republish fresh --

    #[test]
    fn empty_on_relay_d_not_seeded_republishes_fresh() {
        // The only on-relay canonical carries an EMPTY `d`; it must NOT be
        // adopted as the slot. With no stored `d`, mint a fresh one and target
        // that responder.
        let snap = snapshot(vec![per(
            "wss://a.example.com",
            vec![entry("", "ev1", false)],
        )]);
        assert_eq!(
            decide_kp_maintenance(&snap, false, None),
            KpMaintenanceDecision::Republish {
                existing_d: None,
                targets: vec!["wss://a.example.com".to_owned()],
            }
        );
    }

    // ---- Test 18: d-conflict with a stored slot ---------------------------

    #[test]
    fn d_conflict_with_stored_slot_republishes_all_dead_responders() {
        // A serves d1 (dead), B serves d2 (dead), and we track d0. Republish
        // the current live material into d0, targeting BOTH dead responders.
        let snap = snapshot(vec![
            per("wss://a.example.com", vec![entry("d1", "ev1", false)]),
            per("wss://b.example.com", vec![entry("d2", "ev2", false)]),
        ]);
        assert_eq!(
            decide_kp_maintenance(&snap, false, Some("d0")),
            KpMaintenanceDecision::Republish {
                existing_d: Some("d0".to_owned()),
                targets: vec![
                    "wss://a.example.com".to_owned(),
                    "wss://b.example.com".to_owned(),
                ],
            }
        );
    }

    // ---- Test 19: targets = exactly the non-live responders; leak-free -----

    #[test]
    fn targets_are_exactly_the_non_live_responders_in_order() {
        let snap = snapshot(vec![
            per("wss://a.example.com", vec![entry("d-dead", "ev1", false)]),
            per("wss://b.example.com", vec![entry("d-live", "ev2", true)]),
            per("wss://c.example.com", vec![]),
        ]);
        let KpMaintenanceDecision::Republish { targets, .. } =
            decide_kp_maintenance(&snap, false, Some("d-slot"))
        else {
            panic!("expected Republish");
        };
        assert_eq!(
            targets,
            vec![
                "wss://a.example.com".to_owned(),
                "wss://c.example.com".to_owned()
            ]
        );
        // The live responder (B) is never a target.
        assert!(!targets.iter().any(|t| t == "wss://b.example.com"));
    }

    #[test]
    fn outcome_debug_has_no_relay_url_incl_new_counts() {
        let o = KpMaintenanceOutcome {
            action: KpMaintenanceAction::RepublishedStableD,
            canonical_on_relays: 2,
            responders_probed: 3,
            relays_healed: 2,
            relay_errors: 1,
        };
        let dbg = format!("{o:?}");
        assert!(
            !dbg.contains("wss://"),
            "outcome must not carry a relay url"
        );
        assert!(!dbg.contains("ws://"), "outcome must not carry a relay url");
        assert!(dbg.contains("responders_probed"));
        assert!(dbg.contains("relays_healed"));
    }

    // ---- build_kp_maintenance_events: own-relays-only + stable-d ------------

    fn test_mdk() -> (MdkManager, std::path::PathBuf) {
        let mut dir = std::env::temp_dir();
        dir.push(format!(
            "haven_kpm_{}_{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        let mgr = MdkManager::new_unencrypted(&dir).unwrap();
        (mgr, dir)
    }

    const TEST_PUBKEY: &str = "79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798";

    fn d_of(tags: &[Vec<String>]) -> Option<String> {
        tags.iter()
            .find(|t| t.first().map(String::as_str) == Some("d"))
            .and_then(|t| t.get(1).cloned())
    }

    #[test]
    fn build_events_targets_own_relays_only_no_default_union() {
        let (mdk, dir) = test_mdk();
        let own = vec!["wss://own-a.example.com".to_string()];

        let events =
            build_kp_maintenance_events(&mdk, TEST_PUBKEY, &own, Some("d-stable")).expect("build");

        // The publish targets are EXACTLY the caller's own relays — no default
        // set is unioned in (own-relays-only invariant).
        assert_eq!(events.relays, own);
        for default in crate::circle::default_relays() {
            assert!(
                !events.relays.iter().any(|u| u == &default),
                "republish target must never include an account-seed default {default}"
            );
        }

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn kp_maintenance_events_debug_is_presence_only() {
        let (mdk, dir) = test_mdk();
        let own = vec!["wss://secret-own-relay.example.com".to_string()];
        let stable = "deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef00";

        let events =
            build_kp_maintenance_events(&mdk, TEST_PUBKEY, &own, Some(stable)).expect("build");
        let dbg = format!("{events:?}");

        // The hand-written Debug must NOT leak the relay URL or the `d` value.
        assert!(
            !dbg.contains("secret-own-relay"),
            "Debug leaked a relay URL: {dbg}"
        );
        assert!(!dbg.contains(stable), "Debug leaked the d tag: {dbg}");
        assert!(dbg.contains("relay_count"));
        assert!(dbg.contains("<redacted>"));

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn build_events_stable_d_identical_across_two_rotations() {
        let (mdk, dir) = test_mdk();
        let own = vec!["wss://own.example.com".to_string()];
        let stable = "aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899";

        let first =
            build_kp_maintenance_events(&mdk, TEST_PUBKEY, &own, Some(stable)).expect("first");
        let second =
            build_kp_maintenance_events(&mdk, TEST_PUBKEY, &own, Some(stable)).expect("second");

        // Same stable slot across two independent rotations: the NIP-33
        // coordinate (`d`) is byte-identical, so the second REPLACES the first.
        assert_eq!(first.d_tag, stable);
        assert_eq!(second.d_tag, stable);
        assert_eq!(d_of(&first.bundle.tags_30443).as_deref(), Some(stable));
        assert_eq!(d_of(&second.bundle.tags_30443).as_deref(), Some(stable));

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn build_events_none_mints_fresh_slot() {
        let (mdk, dir) = test_mdk();
        let own = vec!["wss://own.example.com".to_string()];

        let a = build_kp_maintenance_events(&mdk, TEST_PUBKEY, &own, None).expect("a");
        let b = build_kp_maintenance_events(&mdk, TEST_PUBKEY, &own, None).expect("b");

        // No stable slot ⇒ MDK mints a fresh random `d` each time.
        assert_ne!(a.d_tag, b.d_tag);

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn build_events_invalid_pubkey_errors_without_leaking() {
        let (mdk, dir) = test_mdk();
        let own = vec!["wss://own.example.com".to_string()];

        let err = build_kp_maintenance_events(&mdk, "not-a-pubkey", &own, None)
            .expect_err("invalid pubkey must error");
        // Display is the fixed, non-leaky message.
        assert_eq!(err.to_string(), "failed to build event");

        let _ = std::fs::remove_dir_all(&dir);
    }

    // ---- build_legacy_twin_deletion: self-authorship guard -----------------

    #[test]
    fn legacy_twin_deletion_requires_self_authorship() {
        let keys = Keys::generate();
        // A well-formed but foreign event id + a DIFFERENT author.
        let other = Keys::generate();
        let dummy = nostr::EventBuilder::new(Kind::Custom(KEY_PACKAGE_KIND_LEGACY), "")
            .sign_with_keys(&other)
            .unwrap();

        let err =
            build_legacy_twin_deletion(&keys, &dummy.id.to_hex(), &other.public_key().to_hex())
                .expect_err("must refuse foreign-authored deletion");
        assert_eq!(err.to_string(), "failed to build event");
    }

    #[test]
    fn legacy_twin_deletion_is_e_tag_only_no_coordinate() {
        let keys = Keys::generate();
        let dummy = nostr::EventBuilder::new(Kind::Custom(KEY_PACKAGE_KIND_LEGACY), "")
            .sign_with_keys(&keys)
            .unwrap();

        let deletion =
            build_legacy_twin_deletion(&keys, &dummy.id.to_hex(), &keys.public_key().to_hex())
                .expect("self-authored deletion builds");
        assert_eq!(deletion.kind, Kind::EventDeletion);

        // `e` tag references the specific superseded event id (delete THIS twin).
        let has_e = deletion.tags.iter().any(|t| {
            let s = t.as_slice();
            s.len() >= 2 && s[0] == "e" && s[1] == dummy.id.to_hex()
        });
        assert!(has_e, "deletion must reference the legacy event id via 'e'");

        // NO `a`-coordinate: kind 443 is a NON-addressable regular event. A
        // `443:<pubkey>:` coordinate (empty identifier) would make cooperative
        // relays delete EVERY kind-443 the author has with
        // `created_at <= deletion` — including the fresh twin the republish just
        // published (which is older than this deletion). The GC must scrub the
        // OLD twin by event id ONLY. This assertion fails if the deletion ever
        // regresses to the coordinate form.
        let has_a = deletion.tags.iter().any(|t| {
            let s = t.as_slice();
            !s.is_empty() && s[0] == "a"
        });
        assert!(
            !has_a,
            "deletion must NOT carry any 'a' coordinate for the non-addressable \
             443 twin (tags: {:?})",
            deletion.tags
        );
    }

    #[test]
    fn legacy_twin_deletion_case_insensitive_author_match() {
        let keys = Keys::generate();
        let dummy = nostr::EventBuilder::new(Kind::Custom(KEY_PACKAGE_KIND_LEGACY), "")
            .sign_with_keys(&keys)
            .unwrap();
        // Author supplied in upper-case must still match our own lower-case hex.
        let upper = keys.public_key().to_hex().to_uppercase();
        assert!(build_legacy_twin_deletion(&keys, &dummy.id.to_hex(), &upper).is_ok());
    }

    // ---- outcome + snapshot: leak-free by construction ---------------------

    #[test]
    fn outcome_no_op_constructor() {
        let o = KpMaintenanceOutcome::no_op(3);
        assert_eq!(o.action, KpMaintenanceAction::AlreadyHealthy);
        assert_eq!(o.canonical_on_relays, 3);
        assert_eq!(o.responders_probed, 0);
        assert_eq!(o.relays_healed, 0);
        assert_eq!(o.relay_errors, 0);
    }

    #[test]
    fn snapshot_carries_relay_url_and_must_not_be_logged() {
        // Unlike the OUTCOME (which is leak-free and crosses the FFI), the
        // per-relay SNAPSHOT deliberately carries relay URLs — it is an
        // FFI-internal value that MUST NOT be logged. This test documents that
        // contract: a snapshot Debug DOES contain the url, so callers must
        // never emit it. Only the outcome (asserted leak-free above) is safe to
        // surface.
        let snap = snapshot(vec![per(
            "wss://secret-own-relay.example.com",
            vec![entry("d-x", "ev1", true)],
        )]);
        let dbg = format!("{snap:?}");
        assert!(
            dbg.contains("secret-own-relay"),
            "snapshot is expected to carry the relay url (must-not-log contract)"
        );
    }
}
