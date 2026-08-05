//! `KeyPackageMaintenance` (Dark Matter DM-2b): the pure decision + event-
//! building core for the user's own kind-30443 `KeyPackage` publication.
//!
//! This module answers one question idempotently: **does the user's
//! `KeyPackage` need (re)publishing to their own `KeyPackage` relays right
//! now?** It never touches the network and never signs the *probe* — the
//! network probe and the signed publish are composed at the FFI boundary (which
//! owns the identity secret and the [`RelayManager`]). Everything here is either
//! fully pure ([`decide_kp_maintenance`], [`RelayKpSnapshot`],
//! [`KpMaintenanceOutcome`]) or takes an injected [`SessionManager`] to mint the
//! `KeyPackage` material ([`build_kp_maintenance_events`]).
//!
//! # No more live-material gate (Dark Matter)
//!
//! The Dark Matter engine's [`SessionManager::fresh_key_package`] marks every
//! `KeyPackage` as an MLS **last-resort** package, so its private init-key
//! material is **never** auto-deleted when a Welcome consumes it — a single KP
//! serves unlimited joins. The old "is the private material still live?" gate
//! (M8-2 `has_live_key_material`) therefore dissolves: a published 30443 stays
//! valid until Haven explicitly rotates it. Health is now pure relay presence
//! of the user's **tracked stable slot**, not a material-liveness verdict.
//!
//! # Stable `d`, reuse, and rotation (plan §5.4)
//!
//! Kind-30443 is NIP-33 addressable: `(kind, pubkey, d)` is the coordinate a
//! peer caches. Maintenance reuses a **stable `d`**: on first run it seeds the
//! `d` from an existing on-relay 30443 ([`KpMaintenanceDecision::SeedD`]);
//! thereafter it republishes into the same slot so a rotation REPLACES the slot
//! (NIP-33 same-`d` supersession) instead of piling up orphaned coordinates.
//! The Nostr transport binding makes this a MUST: "Replacing the `KeyPackage` in
//! that logical slot MUST reuse the same `d`; a routine replacement MUST NOT
//! generate a fresh slot id."
//!
//! * **Heal** (a relay dropped the KP): re-publish the SAME cached last-resort
//!   package verbatim into the same slot — no re-mint (the private material
//!   still lives in the engine). [`build_kp_maintenance_events_reusing`].
//! * **Rotation** ([`KpMaintenanceDecision::Rotate`]): the tracked package has
//!   passed a fraction of its OWN MLS `Lifetime`
//!   ([`KP_ROTATE_AT_LIFETIME_FRACTION`]) — mint fresh material into the SAME
//!   `d` and publish it to EVERY responder, because every responder is serving
//!   the aging package. Without this the account goes silently uninvitable the
//!   day the lifetime expires (see [`super::kp_lifetime`]).
//! * **First publish**: mint a fresh package into a fresh slot
//!   ([`build_kp_maintenance_events`]).
//! * On any re-mint the FFI feeds the superseded package's cached bytes to
//!   [`SessionManager::delete_key_package`] (mdk#160) so orphaned private
//!   material does not accumulate — but only AFTER the replacement is confirmed
//!   published (`foundation/key-packages.md`'s first deletion bound).
//! * **Failed publish**: the FFI feeds the just-minted package to
//!   [`SessionManager::delete_key_package`] so a retry loop against a failing
//!   relay does not leak private material (mdk#160).
//!
//! # Monotonic `created_at` (NIP-01 tie-break)
//!
//! NIP-01 breaks a `created_at` tie between two events in the same addressable
//! slot by keeping the one with the **lowest event id**. A replacement that
//! lands in the same wall-clock second as its predecessor therefore has a ~50%
//! chance of *losing* and never replacing anything. Every event this module
//! builds is stamped with [`monotonic_kp_created_at`], i.e.
//! `max(now, previous + 1)`, which sidesteps the tie entirely.
//!
//! # The 443 twin is RETIRED
//!
//! Haven no longer builds a legacy kind-443 twin — kind-30443 natively owns the
//! addressable slot (W1). [`build_legacy_key_package_retraction`] survives only
//! as a one-time cutover RETRACTION of a *previously* published 443 (migration
//! plan §6 step 5, non-optional): it kind-5-deletes a stale twin by event id.
//!
//! [`RelayManager`]: crate::relay::RelayManager

use nostr::{EventBuilder, Keys, Kind, Tag};
use rand::rngs::OsRng;
use rand::RngCore;

use base64::engine::general_purpose::STANDARD as BASE64;
use base64::Engine as _;

use cgka_traits::engine::KeyPackage;

use super::kp_lifetime::TrackedKpLifetime;
use crate::nostr::mls::SessionManager;
use crate::relay::publishers::{build_unpublish_event, PublisherError, PublisherResult};

/// The Marmot `KeyPackage` event kind (NIP-33 addressable).
pub const KIND_MARMOT_KEY_PACKAGE: u16 = 30443;

// ── 30443 event tag names (mirrors the v0.9.4 transport-nostr-adapter) ───────
const D_TAG: &str = "d";
const IDENTITY_TAG: &str = "i";
const MLS_PROTOCOL_VERSION_TAG: &str = "mls_protocol_version";
const MLS_CIPHERSUITE_TAG: &str = "mls_ciphersuite";
const MLS_EXTENSIONS_TAG: &str = "mls_extensions";
const MLS_PROPOSALS_TAG: &str = "mls_proposals";
const APP_COMPONENTS_TAG: &str = "app_components";

// ── Descriptive capability metadata ──────────────────────────────────────────
//
// These `mls_*` / `app_components` tag VALUES are discovery/filtering metadata:
// the Marmot receive path (`SessionManager::key_package_from_event`) base64-
// decodes the event content into the real MLS `KeyPackage` and validates THAT —
// it never parses these tags. The values below mirror exactly what Haven's
// engine leaf advertises (single ciphersuite `0x0001`; the leaf extensions
// required_capabilities / app_data_dictionary / last_resort /
// account-identity-proof; the app_data_update + self_remove proposals; the
// profile / admin-policy / nostr-routing app components Haven configures in
// `SessionManager::open_session`). DM-5 e2e confirms discovery on-wire.

/// MLS protocol version tag value (MLS 1.0).
const MLS_PROTOCOL_VERSION: &str = "1.0";
/// The single hard-enforced ciphersuite (W10:
/// `MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519`).
const MLS_CIPHERSUITE: &str = "0x0001";
/// Leaf extension types Haven's engine advertises: `required_capabilities`
/// (0x0003), `app_data_dictionary` (0x0006), `last_resort` (0x000a),
/// account-identity-proof (0xf2f1).
const MLS_EXTENSIONS: [&str; 4] = ["0x0003", "0x0006", "0x000a", "0xf2f1"];
/// Non-default proposal types Haven's engine advertises: `app_data_update`
/// (0x0008), `self_remove` (0x000a).
const MLS_PROPOSALS: [&str; 2] = ["0x0008", "0x000a"];
/// App components Haven groups carry: profile (0x8001), admin-policy (0x8003),
/// nostr-routing (0x8004).
const APP_COMPONENTS: [&str; 3] = ["0x8001", "0x8003", "0x8004"];

/// One canonical (kind 30443) `KeyPackage` event the FFI found on the user's own
/// `KeyPackage` relays, reduced to only the fields the decision needs.
///
/// Fieldless of any secret: `d_tag` and `event_id` are public Nostr
/// identifiers. Deriving `Debug` here is leak-free.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RelayKpEntry {
    /// The NIP-33 `d` tag of the on-relay canonical event.
    pub d_tag: String,
    /// Lowercase-hex Nostr event id of the on-relay canonical event.
    pub event_id: String,
}

/// One RESPONDING own-`KeyPackage`-relay's canonical (kind 30443) entries
/// (FFI-built).
///
/// `relay_url` is a user-configured own-relay URL — callers MUST NOT log this
/// struct, and it MUST NEVER enter a maintenance OUTCOME (only integer counts
/// cross the FFI). Non-responders are NOT represented here: you cannot write to
/// an unreachable relay, so excluding them at snapshot-build time makes "never
/// target a non-responder" a STRUCTURAL invariant.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RelayKpPerRelay {
    /// The own-relay URL these entries came from. MUST NOT be logged / put in an
    /// outcome.
    pub relay_url: String,
    /// The canonical (kind 30443) `KeyPackage` events THIS relay served.
    pub canonical: Vec<RelayKpEntry>,
}

impl RelayKpPerRelay {
    /// Returns whether this relay serves the user's tracked stable slot — the
    /// load-bearing per-relay presence gate. A relay serving only a
    /// *different*-`d` 30443 (an orphaned/old coordinate) does NOT count.
    #[must_use]
    fn serves_slot(&self, stable_d: &str) -> bool {
        self.canonical.iter().any(|e| e.d_tag == stable_d)
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
/// (never the discovery plane, never a default union) for kind-30443 events
/// authored by the user. `responders` carries RESPONDING relays only; empty
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
/// iteration order OR intra-relay event order.
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
    /// Every responding relay already serves the tracked slot (or no relay
    /// responded this tick) — nothing to do.
    NoOp,
    /// First-run seeding: no slot is tracked locally yet, but a responder serves
    /// a canonical with a well-formed `d`. The FFI records the seed `d` into
    /// `published_key_packages` BEFORE any future publish, so stability holds
    /// from cycle 1. No new material is published this tick.
    SeedD {
        /// The deterministic stable `d` adopted from the responders' 30443s.
        d: String,
    },
    /// One or more responding relays lack the tracked slot — (re)publish the
    /// `KeyPackage` into the stable slot (`existing_d`, or mint a fresh slot if
    /// `None`) to exactly these relays. Always non-empty.
    Republish {
        /// The stable `d` to republish into, or `None` to mint a new slot.
        existing_d: Option<String>,
        /// The responding own-relay URLs that lack the tracked slot.
        targets: Vec<String>,
    },
    /// The tracked package has passed the rotation point of its OWN MLS
    /// `Lifetime` (or its lifetime could not be read) — **re-mint** into the
    /// SAME stable slot and publish to EVERY responder.
    ///
    /// Distinct from [`Self::Republish`] on both counts that matter:
    ///
    /// * The FFI MUST NOT reuse the cached bytes here even though they exist —
    ///   re-advertising aging material is exactly the failure being fixed.
    /// * `targets` is **every** responder, not just the ones missing the slot:
    ///   a relay that serves the old package is serving material that is about
    ///   to expire, so it needs the replacement most of all.
    ///
    /// `existing_d` is always `Some` — rotation happens only when a slot is
    /// already tracked, and the transport binding requires reusing it.
    Rotate {
        /// The stable `d` to re-mint into. Never `None`.
        existing_d: String,
        /// Every responding own-relay URL. Always non-empty.
        targets: Vec<String>,
        /// Whether the rotation was forced by an UNREADABLE lifetime rather
        /// than by the package genuinely aging out. Purely diagnostic — it
        /// changes no publishing behaviour, only the reported outcome, so an
        /// unreadable-lifetime loop is visible instead of silent.
        lifetime_unreadable: bool,
    },
}

/// Decides the `KeyPackage` maintenance action for this tick (PURE).
///
/// The per-relay presence gate: a responder is healthy iff it serves the user's
/// tracked stable slot ([`RelayKpPerRelay::serves_slot`]). A responder serving
/// only a different-`d` (orphaned) 30443, or nothing, is a heal target. So a
/// package live on relay A but dropped from relay B republishes to B ONLY (A
/// untouched).
///
/// Branch order:
///
/// 1. **No responders** (all transiently unreachable) ⇒ [`KpMaintenanceDecision::NoOp`]
///    (fail-closed; we cannot confirm any drop, so retry next tick).
/// 2. **A slot is tracked**:
///    * 2a. the tracked package is past the rotation point of its OWN MLS
///      `Lifetime` (or its lifetime is unreadable) ⇒
///      [`KpMaintenanceDecision::Rotate`] into the same slot, targeting EVERY
///      responder;
///    * 2b. otherwise heal the responders NOT serving the slot; if all serve
///      it, [`KpMaintenanceDecision::NoOp`].
/// 3. **No slot tracked but a responder serves a well-formed `d`** ⇒
///    [`KpMaintenanceDecision::SeedD`] (adopt it before publishing, so cycle 1
///    does not fork the address).
/// 4. **No slot tracked and no adoptable `d`** ⇒
///    [`KpMaintenanceDecision::Republish`] into a fresh slot, targeting every
///    responder.
///
/// # Why 2a sits ABOVE 2b, and why it targets everyone
///
/// A package can be past its threshold AND missing from some relays at the same
/// time. Healing first would re-publish the *cached, aging* bytes to the
/// missing relays and then (next tick, or worse: never, because the heal
/// refreshed the event's `created_at`) rotate — two publishes, and in between,
/// relays advertising material that is about to stop validating. Rotating first
/// collapses that into ONE re-mint published everywhere: the missing relays get
/// the slot back and the serving relays get material that is not about to die.
///
/// Rotation deliberately does NOT pre-empt branch 1. A tick where no relay
/// responded cannot publish anything, so minting there would burn init-key
/// material only to delete it again (mdk#160). The ~21 days of slack the 0.75
/// fraction leaves is exactly the budget for such ticks.
///
/// `stored_stable_d` is the caller's `latest_canonical_d_tag()` and
/// `tracked_lifetime` the lifetime read from the same row's cached bytes (see
/// [`read_kp_lifetime`]); `now_secs` is injected so the threshold is testable
/// without waiting 63 days.
///
/// [`read_kp_lifetime`]: super::kp_lifetime::read_kp_lifetime
#[must_use]
pub fn decide_kp_maintenance(
    snapshot: &RelayKpSnapshot,
    stored_stable_d: Option<&str>,
    tracked_lifetime: TrackedKpLifetime,
    now_secs: u64,
) -> KpMaintenanceDecision {
    // Branch 1: fail-closed. No responders ⇒ can't confirm any drop this tick,
    // and can't publish a rotation either.
    if snapshot.responders.is_empty() {
        return KpMaintenanceDecision::NoOp;
    }

    if let Some(stable_d) = stored_stable_d {
        // Branch 2a: the tracked material has aged out of its own lifetime (or
        // we cannot tell). Re-mint into the SAME slot, everywhere.
        if tracked_lifetime.is_rotation_due(now_secs) {
            return KpMaintenanceDecision::Rotate {
                existing_d: stable_d.to_owned(),
                targets: snapshot
                    .responders
                    .iter()
                    .map(|r| r.relay_url.clone())
                    .collect(),
                lifetime_unreadable: tracked_lifetime.is_unreadable(),
            };
        }
        // Branch 2b: heal the responders that do not serve the tracked slot.
        let targets: Vec<String> = snapshot
            .responders
            .iter()
            .filter(|r| !r.serves_slot(stable_d))
            .map(|r| r.relay_url.clone())
            .collect();
        if targets.is_empty() {
            return KpMaintenanceDecision::NoOp;
        }
        return KpMaintenanceDecision::Republish {
            existing_d: Some(stable_d.to_owned()),
            targets,
        };
    }

    // Branch 3: first run — adopt an on-relay `d` if one is well-formed.
    if let Some(d) = pick_seed_d(snapshot) {
        return KpMaintenanceDecision::SeedD { d };
    }

    // Branch 4: nothing to adopt — mint a fresh slot to every responder.
    KpMaintenanceDecision::Republish {
        existing_d: None,
        targets: snapshot
            .responders
            .iter()
            .map(|r| r.relay_url.clone())
            .collect(),
    }
}

/// A minted-or-reused `KeyPackage` publication for a [`KpMaintenanceDecision::Republish`].
///
/// Carries the SIGNED kind-30443 event to publish, the engine [`KeyPackage`]
/// handle (so the FFI can [`SessionManager::delete_key_package`] it on a FAILED
/// publish or on rotation of a superseded package — mdk#160), the stable `d`
/// (to record on success), and the resolved own-relay targets.
///
/// The `d_tag` + `relays` fields WOULD leak (a NIP-33 `d` and relay URLs) under
/// a derived `Debug`, and `key_package` is MLS wire material, so `Debug` is
/// hand-written to be presence-only (Security Rule 4/6).
#[derive(Clone)]
pub struct KpMaintenanceEvents {
    /// The signed kind-30443 event to publish.
    pub event: nostr::Event,
    /// The engine `KeyPackage` handle (delete-on-failure / delete-on-rotation).
    pub key_package: KeyPackage,
    /// The stable NIP-33 `d` the event was built with (to record on publish).
    pub d_tag: String,
    /// The own-relay targets — own-relays-only, never a default union.
    pub relays: Vec<String>,
}

impl std::fmt::Debug for KpMaintenanceEvents {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("KpMaintenanceEvents")
            .field("event_id", &self.event.id.to_hex())
            .field("key_package", &"<redacted>")
            .field("d_tag", &"<redacted>")
            .field("relay_count", &self.relays.len())
            .finish()
    }
}

/// Generates a fresh, well-formed stable `d` (hex of 16 `OsRng` bytes).
fn mint_d() -> String {
    let mut bytes = [0u8; 16];
    OsRng.fill_bytes(&mut bytes);
    hex::encode(bytes)
}

/// Returns a strictly-monotonic `created_at` for the next canonical (kind
/// 30443) publish into the stable slot.
///
/// # Why this is not just "now"
///
/// Kind 30443 is addressable, and the Nostr transport binding resolves a slot
/// collision the NIP-01 way: "clients SHOULD keep the newest valid event by
/// `created_at`, with lower event id as the deterministic tie-breaker when
/// timestamps are equal." Two events one second apart are unambiguous; two in
/// the SAME second are decided by a hash comparison the publisher does not
/// control. A rotation that lands in the same wall-clock second as the publish
/// it means to replace therefore fails to replace it roughly half the time, and
/// fails **silently** — the relay accepts the event and then serves the old one.
///
/// `prev_max` is the `created_at` recorded for the slot in
/// `published_key_packages`. Flooring the new stamp at `prev_max + 1` removes
/// the tie by construction. A row written before this floor existed holds the
/// record-time clock rather than the event's own stamp; that value is `>=` the
/// event's `created_at` (it is sampled after the relay round-trip), so it is a
/// conservative floor and the invariant still holds across the upgrade.
///
/// Negative or absent `prev_max` falls through to `now` (a pre-epoch stamp is
/// not a meaningful floor).
#[must_use]
pub fn monotonic_kp_created_at(prev_max: Option<i64>, now_secs: u64) -> nostr::Timestamp {
    match prev_max {
        // `prev >= 0` makes the cast value-preserving.
        #[allow(clippy::cast_sign_loss)]
        Some(prev) if prev >= 0 => {
            nostr::Timestamp::from_secs((prev as u64).saturating_add(1).max(now_secs))
        }
        _ => nostr::Timestamp::from_secs(now_secs),
    }
}

/// Builds a signed kind-30443 `KeyPackage` event from raw MLS wire bytes.
///
/// Mirrors the v0.9.4 `transport-nostr-adapter` tag set exactly: `d` slot,
/// `mls_protocol_version`, `i` (the `KeyPackage` ref, derived from the bytes),
/// `mls_ciphersuite`, `mls_extensions`, `mls_proposals`, `app_components`;
/// base64 content; NO `encoding` tag; NO `relays` tag. Unlike the adapter's
/// transport-agnostic unsigned event, Haven signs with the identity key (30443
/// is identity-signed, W1).
///
/// `created_at` is the slot-monotonic stamp from [`monotonic_kp_created_at`],
/// NOT the builder's default `now` — see that function for why a same-second
/// replacement otherwise fails silently.
fn build_key_package_event(
    keys: &Keys,
    kp_bytes: &[u8],
    d: &str,
    created_at: nostr::Timestamp,
) -> PublisherResult<nostr::Event> {
    if d.is_empty() {
        return Err(PublisherError::Build(
            "key package d must not be empty".into(),
        ));
    }
    // The `i` tag is the MLS KeyPackage ref, derived from the wire bytes. This
    // also validates the leaf (incl. the account-identity proof) as a side
    // effect — a fresh Haven package always passes.
    let meta = cgka_engine::key_package::key_package_metadata(&KeyPackage::new(kp_bytes.to_vec()))
        .map_err(|e| PublisherError::Build(format!("key package metadata: {e}")))?;

    let tags: Vec<Tag> = vec![
        parse_tag(&[D_TAG, d])?,
        parse_tag(&[MLS_PROTOCOL_VERSION_TAG, MLS_PROTOCOL_VERSION])?,
        parse_tag(&[IDENTITY_TAG, &meta.key_package_ref_hex])?,
        parse_tag(&[MLS_CIPHERSUITE_TAG, MLS_CIPHERSUITE])?,
        values_tag(MLS_EXTENSIONS_TAG, &MLS_EXTENSIONS)?,
        values_tag(MLS_PROPOSALS_TAG, &MLS_PROPOSALS)?,
        values_tag(APP_COMPONENTS_TAG, &APP_COMPONENTS)?,
    ];

    EventBuilder::new(
        Kind::Custom(KIND_MARMOT_KEY_PACKAGE),
        BASE64.encode(kp_bytes),
    )
    .tags(tags)
    .custom_created_at(created_at)
    .sign_with_keys(keys)
    .map_err(|e| PublisherError::Build(format!("sign key package: {e}")))
}

/// Parses a fixed-arity string tag, mapping failure to [`PublisherError::Build`].
fn parse_tag(parts: &[&str]) -> PublisherResult<Tag> {
    Tag::parse(parts.iter().copied()).map_err(|e| PublisherError::Build(format!("tag: {e}")))
}

/// Builds a multi-value tag `[name, v0, v1, ...]`.
fn values_tag(name: &str, values: &[&str]) -> PublisherResult<Tag> {
    let mut parts = Vec::with_capacity(values.len() + 1);
    parts.push(name);
    parts.extend_from_slice(values);
    parse_tag(&parts)
}

/// Mints a FRESH `KeyPackage` and builds its signed kind-30443 event — the
/// rotation ([`KpMaintenanceDecision::Rotate`]) / first-publish path.
///
/// Mints via [`SessionManager::fresh_key_package`], builds+signs the event into
/// `existing_d` (or a freshly minted stable slot when `None`), and returns the
/// [`KeyPackage`] handle so the FFI can delete it on a failed publish (mdk#160).
/// The returned [`KpMaintenanceEvents::relays`] is exactly `own_kp_relays` — no
/// default set is unioned in (own-relays-only invariant).
///
/// `prev_created_at` is the slot's last recorded `created_at`; the new event is
/// stamped `max(now, prev + 1)` so a same-second rotation cannot lose the NIP-01
/// id tie-break and silently fail to replace ([`monotonic_kp_created_at`]).
///
/// # Errors
///
/// Returns [`PublisherError::Build`] if minting, metadata derivation, or signing
/// fails (inner detail redacted from `Display`).
pub async fn build_kp_maintenance_events(
    session: &SessionManager,
    keys: &Keys,
    own_kp_relays: &[String],
    existing_d: Option<&str>,
    prev_created_at: Option<i64>,
) -> PublisherResult<KpMaintenanceEvents> {
    let key_package = session
        .fresh_key_package()
        .await
        .map_err(|e| PublisherError::Build(format!("mint key package: {e}")))?;
    let d_tag = existing_d.map_or_else(mint_d, str::to_owned);
    let created_at = monotonic_kp_created_at(prev_created_at, super::kp_lifetime::now_secs());
    let event = build_key_package_event(keys, key_package.bytes(), &d_tag, created_at)?;
    Ok(KpMaintenanceEvents {
        event,
        key_package,
        d_tag,
        relays: own_kp_relays.to_vec(),
    })
}

/// Rebuilds the signed kind-30443 event for a CACHED last-resort `KeyPackage` —
/// the heal path (a relay dropped the KP), with NO re-mint.
///
/// `cached_kp_bytes` are the public MLS wire bytes tracked in
/// `published_key_packages`; the private material still lives in the engine
/// (last-resort packages are never auto-deleted), so re-publishing the same
/// bytes into the same slot re-advertises a package peers can still consume.
/// The returned [`KeyPackage`] handle mirrors the cached bytes.
///
/// # This path is why rotation cannot be timed off `created_at`
///
/// A heal stamps a **fresh** `created_at` on **old** material. Any age check
/// keyed on the event timestamp would therefore reset every time a flaky relay
/// is healed, while the package's real `not_after` kept ticking. The rotation
/// clock is read from the `KeyPackage` itself ([`super::kp_lifetime`]) precisely
/// so this function cannot move it.
///
/// # Errors
///
/// Returns [`PublisherError::Build`] if metadata derivation or signing fails.
pub fn build_kp_maintenance_events_reusing(
    keys: &Keys,
    cached_kp_bytes: &[u8],
    own_kp_relays: &[String],
    d: &str,
    prev_created_at: Option<i64>,
) -> PublisherResult<KpMaintenanceEvents> {
    let created_at = monotonic_kp_created_at(prev_created_at, super::kp_lifetime::now_secs());
    let event = build_key_package_event(keys, cached_kp_bytes, d, created_at)?;
    Ok(KpMaintenanceEvents {
        event,
        key_package: KeyPackage::new(cached_kp_bytes.to_vec()),
        d_tag: d.to_owned(),
        relays: own_kp_relays.to_vec(),
    })
}

/// Builds a self-authored NIP-09 (kind 5) retraction for a LEGACY 443
/// `KeyPackage` — the one-time cutover cleanup (migration plan §6 step 5,
/// NON-OPTIONAL).
///
/// The retired 443 is a NON-addressable regular event with no stable slot, so a
/// stale twin must be scrubbed explicitly. This refuses unless the event author
/// is the user themselves (`author == keys.public_key()`, the self-authorship
/// guard) — we never author a deletion of someone else's event.
///
/// The deletion references the 443 **by event id only** (a single `e` tag) and
/// deliberately carries **NO** `a`-coordinate: kind 443 is non-addressable, so a
/// `443:<pubkey>:` coordinate (empty identifier) would tell cooperative relays
/// to delete EVERY kind-443 the author has with `created_at <= deletion` — which
/// is exactly the wrong scope. An id-only `e`-tag deletion scrubs the one stale
/// event. (Contrast the addressable relay-list retraction below, whose
/// coordinate form is well-defined.)
///
/// # Errors
///
/// Returns [`PublisherError::Build`] if the self-authorship guard fails, the
/// event id is malformed, or signing fails.
pub fn build_legacy_key_package_retraction(
    keys: &Keys,
    legacy_event_id_hex: &str,
    event_author_hex: &str,
) -> PublisherResult<nostr::Event> {
    // Self-authorship guard: never author a deletion of an event we did not
    // sign. Compared as lowercase hex to defeat case skew.
    let own_hex = keys.public_key().to_hex();
    if !event_author_hex.eq_ignore_ascii_case(&own_hex) {
        return Err(PublisherError::Build(
            "refusing to delete an event authored by another key".to_owned(),
        ));
    }

    let event_id = nostr::EventId::from_hex(legacy_event_id_hex)
        .map_err(|e| PublisherError::Build(format!("bad legacy event id: {e}")))?;

    // Id-only (`e`-tag) deletion — NO `a`-coordinate for the non-addressable
    // 443.
    let request = nostr::nips::nip09::EventDeletionRequest::new().ids(vec![event_id]);
    EventBuilder::delete(request)
        .sign_with_keys(keys)
        .map_err(|e| PublisherError::Build(format!("sign deletion: {e}")))
}

/// Builds the retraction of the user's kind-10051 `KeyPackage`-relay list — the
/// one-time cutover cleanup (migration plan §6 W2 / §6 step 5, NON-OPTIONAL).
///
/// Kind 10051 is abolished under Dark Matter (`KeyPackages` are discovered on the
/// account's NIP-65 kind-10002 relays now). A live 10051 lets an old-stack
/// client build a Welcome the new client cannot process, so it must be retired.
/// This emits an **empty replaceable** kind-10051 (no `relay` tags): per
/// NIP-01 replaceable semantics, relays supersede the previous list with the
/// empty one. `last_published_at` (the previous list's `created_at`, if known)
/// floors the new `created_at` to strictly supersede across clock skew.
///
/// The FFI MAY additionally emit a kind-5 coordinate deletion
/// ([`crate::relay::publishers::build_nip09_deletion`] with
/// [`Kind::MlsKeyPackageRelays`]) for relays that honor NIP-09 over replaceable
/// supersession.
///
/// # Errors
///
/// Returns [`PublisherError::Build`] if signing fails.
pub fn build_key_package_relay_list_retraction(
    keys: &Keys,
    last_published_at: Option<i64>,
) -> PublisherResult<nostr::Event> {
    build_unpublish_event(
        keys,
        crate::circle::relay_prefs::RelayType::KeyPackage,
        last_published_at,
    )
}

/// The terminal action a `KeyPackage` maintenance tick carried out.
///
/// Fieldless (Copy) and payload-free — no `d`, url, hex, or group id — so its
/// derived `Debug` cannot leak (Security Rule 4/6).
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum KpMaintenanceAction {
    /// A canonical `KeyPackage` was already reachable on every relay — no change.
    #[default]
    AlreadyHealthy,
    /// A stable `d` was seeded from an on-relay canonical this tick; no publish.
    SeededD,
    /// A `KeyPackage` was (re)published into a reused, tracked/seeded stable `d`.
    RepublishedStableD,
    /// A `KeyPackage` was published into a freshly-minted `d` (first-ever slot).
    RepublishedFreshD,
    /// FRESH material was minted into the existing stable `d` because the
    /// tracked package passed the rotation point of its own MLS `Lifetime`.
    /// The healthy steady state — expect one of these roughly every ~63 days.
    RotatedExpiringMaterial,
    /// FRESH material was minted into the existing stable `d` because the
    /// tracked package's lifetime could NOT be read.
    ///
    /// Distinct from [`Self::RotatedExpiringMaterial`] on purpose. The
    /// unreadable case rotates by policy (see
    /// [`TrackedKpLifetime::is_rotation_due`]), and that policy is only safe
    /// because it self-corrects — the replacement is minted by our own engine,
    /// so the next tick reads a valid lifetime. If this value keeps appearing,
    /// the reader itself is broken and every tick is burning init-key material.
    /// Surfacing it separately is what makes that loud instead of silent.
    RotatedUnreadableLifetime,
}

/// Presence-only tally of a `KeyPackage` maintenance tick.
///
/// The action is an enum and the remaining fields are counts — no urls, hex,
/// `d` values, or group ids — so the derived `Debug` is leak-free by
/// construction (Security Rule 4/6). This is the shape the FFI folds ticks into
/// and returns to Dart.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct KpMaintenanceOutcome {
    /// Which BRANCH the tick took — **not** whether that branch landed.
    ///
    /// The action is chosen before the relay write is attempted, so a
    /// `Republished*` / `Rotated*` value means "this tick tried to publish",
    /// never "a replacement is now on a relay". The ack lives in
    /// [`Self::relays_healed`], which is `0` when no relay acknowledged. A consumer
    /// that reads the action alone as success will score a publish nobody
    /// accepted as a completed rotation.
    pub action: KpMaintenanceAction,
    /// Own-relay canonical events observed by the probe (summed across
    /// responders).
    pub canonical_on_relays: usize,
    /// Own `KeyPackage` relays this tick TARGETED — the account's configured
    /// NIP-65 set after dedup, counted before any of them is contacted.
    ///
    /// This is the field that separates two situations the rest of the outcome
    /// reports identically, and whose remedies are opposite:
    ///
    /// * `relays_targeted == 0` — the account has **no `KeyPackage` relays
    ///   configured**. Nothing to retry; the user must add one.
    /// * `relays_targeted > 0` **and** `responders_probed == 0` — every
    ///   configured relay was **unreachable this tick**. Transient; retry.
    ///
    /// Both otherwise surface as `AlreadyHealthy` with `responders_probed == 0`
    /// and `relay_errors == 0`, because the decision fails closed in both cases.
    pub relays_targeted: usize,
    /// Responding own relays probed this tick (non-responders excluded).
    pub responders_probed: usize,
    /// Responding relays that ACKED this tick's publish.
    ///
    /// The ONLY evidence in this struct that anything landed: `publish_event`
    /// returns `Ok` exclusively when at least one relay OK-acked, so a
    /// `Rotated*` action with `relays_healed == 0` is a rotation that reached
    /// nobody — and, when `expired_init_key_purged` is also set, an account with
    /// neither a usable init key nor a published replacement.
    pub relays_healed: usize,
    /// Relay probes/publishes that errored (tallied, never fatal).
    pub relay_errors: usize,
    /// Whether this tick deleted the tracked package's private `init_key`
    /// because it reached `Lifetime.not_after` — the spec's second, transport-
    /// independent deletion bound (see
    /// [`kp_init_key_purge_due`](super::kp_lifetime::kp_init_key_purge_due)).
    ///
    /// A boolean, not a key or an id, so the derived `Debug` stays leak-free.
    pub expired_init_key_purged: bool,
}

impl KpMaintenanceOutcome {
    /// Builds the outcome for a decision that resolved to [`KpMaintenanceDecision::NoOp`].
    ///
    /// `relays_targeted` must be the configured own-relay count, so the caller
    /// can still tell "nothing configured" from "nothing reachable" (see
    /// [`Self::relays_targeted`]).
    #[must_use]
    pub const fn no_op(canonical_on_relays: usize, relays_targeted: usize) -> Self {
        Self {
            action: KpMaintenanceAction::AlreadyHealthy,
            canonical_on_relays,
            relays_targeted,
            responders_probed: 0,
            relays_healed: 0,
            relay_errors: 0,
            expired_init_key_purged: false,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::super::kp_lifetime::{KeyPackageLifetime, KP_ROTATE_AT_LIFETIME_FRACTION};
    use super::*;

    /// The `OpenMLS`/Marmot maximum `KeyPackage` lifetime span (84 d + 1 h).
    const SPAN: u64 = 60 * 60 * 24 * 28 * 3 + 60 * 60;
    /// Fixed test clock (Unix seconds, ~2027). Large enough that "70 days ago"
    /// is a real timestamp rather than an underflow.
    const NOW: u64 = 1_800_000_000;

    /// A lifetime minted "now": far from its rotation threshold.
    fn fresh_lifetime() -> TrackedKpLifetime {
        TrackedKpLifetime::Known(KeyPackageLifetime::new(NOW, NOW + SPAN))
    }

    /// A lifetime whose rotation threshold has just been reached at [`NOW`].
    fn expiring_lifetime() -> TrackedKpLifetime {
        // `rotate_at` == NOW exactly: the inclusive boundary is due.
        let span = SPAN;
        #[allow(
            clippy::cast_precision_loss,
            clippy::cast_possible_truncation,
            clippy::cast_sign_loss
        )]
        let elapsed = (span as f64 * KP_ROTATE_AT_LIFETIME_FRACTION) as u64;
        TrackedKpLifetime::Known(KeyPackageLifetime::new(NOW - elapsed, NOW - elapsed + span))
    }

    fn entry(d: &str, id: &str) -> RelayKpEntry {
        RelayKpEntry {
            d_tag: d.to_owned(),
            event_id: id.to_owned(),
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

    /// Decision for a tracked package that is nowhere near its rotation point —
    /// the pre-existing (lifetime-agnostic) behaviour these tests pin.
    fn decide_fresh(snap: &RelayKpSnapshot, stored_d: Option<&str>) -> KpMaintenanceDecision {
        decide_kp_maintenance(snap, stored_d, fresh_lifetime(), NOW)
    }

    #[test]
    fn all_responders_serve_slot_is_noop() {
        let snap = snapshot(vec![
            per("wss://a.example.com", vec![entry("d-slot", "ev1")]),
            per("wss://b.example.com", vec![entry("d-slot", "ev2")]),
        ]);
        assert_eq!(
            decide_fresh(&snap, Some("d-slot")),
            KpMaintenanceDecision::NoOp
        );
    }

    #[test]
    fn partial_drop_a_has_slot_b_empty_republishes_to_b_only() {
        // A serves the tracked slot; B responded but serves nothing. The
        // per-relay gate republishes to B ONLY.
        let snap = snapshot(vec![
            per("wss://a.example.com", vec![entry("d-slot", "ev1")]),
            per("wss://b.example.com", vec![]),
        ]);
        assert_eq!(
            decide_fresh(&snap, Some("d-slot")),
            KpMaintenanceDecision::Republish {
                existing_d: Some("d-slot".to_owned()),
                targets: vec!["wss://b.example.com".to_owned()],
            }
        );
    }

    #[test]
    fn relay_serving_only_other_slot_is_a_target() {
        // B serves a 30443, but at a DIFFERENT (orphaned) `d` — not our slot, so
        // it is a heal target.
        let snap = snapshot(vec![
            per("wss://a.example.com", vec![entry("d-slot", "ev1")]),
            per("wss://b.example.com", vec![entry("d-other", "ev2")]),
        ]);
        assert_eq!(
            decide_fresh(&snap, Some("d-slot")),
            KpMaintenanceDecision::Republish {
                existing_d: Some("d-slot".to_owned()),
                targets: vec!["wss://b.example.com".to_owned()],
            }
        );
    }

    #[test]
    fn empty_responders_is_noop() {
        assert_eq!(
            decide_fresh(&snapshot(vec![]), Some("d-x")),
            KpMaintenanceDecision::NoOp
        );
        assert_eq!(
            decide_fresh(&snapshot(vec![]), None),
            KpMaintenanceDecision::NoOp
        );
    }

    #[test]
    fn no_responders_never_rotates_even_past_the_threshold() {
        // Fail-closed dominates rotation: a tick with nothing to publish to must
        // not mint material only to delete it again (mdk#160). The 0.75 fraction
        // exists precisely to leave slack for these ticks.
        assert_eq!(
            decide_kp_maintenance(&snapshot(vec![]), Some("d-x"), expiring_lifetime(), NOW),
            KpMaintenanceDecision::NoOp
        );
        assert_eq!(
            decide_kp_maintenance(
                &snapshot(vec![]),
                Some("d-x"),
                TrackedKpLifetime::NotCurrent,
                NOW
            ),
            KpMaintenanceDecision::NoOp
        );
    }

    #[test]
    fn no_stored_d_with_good_relay_d_seeds() {
        let snap = snapshot(vec![per(
            "wss://a.example.com",
            vec![entry("d-onrelay", "ev1")],
        )]);
        assert_eq!(
            decide_fresh(&snap, None),
            KpMaintenanceDecision::SeedD {
                d: "d-onrelay".to_owned(),
            }
        );
    }

    #[test]
    fn pick_seed_d_is_byte_order_min_across_disagreeing_responders() {
        let snap = snapshot(vec![
            per(
                "wss://a.example.com",
                vec![entry("", "ev-empty"), entry("m-slot", "ev1")],
            ),
            per("wss://b.example.com", vec![entry("a-slot", "ev2")]),
        ]);
        assert_eq!(
            decide_fresh(&snap, None),
            KpMaintenanceDecision::SeedD {
                d: "a-slot".to_owned(),
            }
        );
    }

    #[test]
    fn seed_handoff_next_tick_republishes_into_seeded_slot() {
        let snap = snapshot(vec![per(
            "wss://a.example.com",
            vec![entry("d-seed", "ev1")],
        )]);
        // A serves `d-seed`, but the tracked slot is now `d-unserved` (which A
        // does NOT serve) — so the handoff heals A into the tracked slot.
        assert_eq!(
            decide_fresh(&snap, Some("d-unserved")),
            KpMaintenanceDecision::Republish {
                existing_d: Some("d-unserved".to_owned()),
                targets: vec!["wss://a.example.com".to_owned()],
            }
        );
    }

    #[test]
    fn only_empty_on_relay_d_no_stored_d_republishes_fresh() {
        // The only on-relay canonical carries an EMPTY `d`; it must NOT be
        // adopted. With no stored `d`, mint a fresh one and target the responder.
        let snap = snapshot(vec![per("wss://a.example.com", vec![entry("", "ev1")])]);
        assert_eq!(
            decide_fresh(&snap, None),
            KpMaintenanceDecision::Republish {
                existing_d: None,
                targets: vec!["wss://a.example.com".to_owned()],
            }
        );
    }

    #[test]
    fn no_stored_d_no_relay_entries_republishes_fresh_to_all() {
        let snap = snapshot(vec![
            per("wss://a.example.com", vec![]),
            per("wss://b.example.com", vec![]),
        ]);
        assert_eq!(
            decide_fresh(&snap, None),
            KpMaintenanceDecision::Republish {
                existing_d: None,
                targets: vec![
                    "wss://a.example.com".to_owned(),
                    "wss://b.example.com".to_owned(),
                ],
            }
        );
    }

    #[test]
    fn targets_are_exactly_the_non_serving_responders_in_order() {
        let snap = snapshot(vec![
            per("wss://a.example.com", vec![entry("d-other", "ev1")]),
            per("wss://b.example.com", vec![entry("d-slot", "ev2")]),
            per("wss://c.example.com", vec![]),
        ]);
        let KpMaintenanceDecision::Republish { targets, .. } = decide_fresh(&snap, Some("d-slot"))
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
        assert!(!targets.iter().any(|t| t == "wss://b.example.com"));
    }

    #[test]
    fn outcome_debug_has_no_relay_url() {
        let o = KpMaintenanceOutcome {
            action: KpMaintenanceAction::RepublishedStableD,
            canonical_on_relays: 2,
            relays_targeted: 3,
            responders_probed: 3,
            relays_healed: 2,
            relay_errors: 1,
            expired_init_key_purged: true,
        };
        let dbg = format!("{o:?}");
        assert!(
            !dbg.contains("wss://"),
            "outcome must not carry a relay url"
        );
        assert!(dbg.contains("responders_probed"));
        assert!(dbg.contains("relays_healed"));
        assert!(dbg.contains("expired_init_key_purged"));
    }

    #[test]
    fn outcome_no_op_constructor() {
        let o = KpMaintenanceOutcome::no_op(3, 2);
        assert_eq!(o.action, KpMaintenanceAction::AlreadyHealthy);
        assert_eq!(o.canonical_on_relays, 3);
        assert_eq!(o.relays_targeted, 2);
        assert_eq!(o.relays_healed, 0);
        assert!(!o.expired_init_key_purged);
    }

    #[test]
    fn no_op_separates_nothing_configured_from_nothing_reachable() {
        // The two situations the rest of the outcome reports identically. Their
        // remedies are opposite — configure a relay vs. retry shortly — so the
        // ONLY thing telling them apart is `relays_targeted`.
        let nothing_configured = KpMaintenanceOutcome::no_op(0, 0);
        let all_unreachable = KpMaintenanceOutcome::no_op(0, 3);
        assert_eq!(nothing_configured.action, all_unreachable.action);
        assert_eq!(
            nothing_configured.responders_probed,
            all_unreachable.responders_probed
        );
        assert_eq!(
            nothing_configured.relay_errors,
            all_unreachable.relay_errors
        );
        assert_ne!(
            nothing_configured.relays_targeted, all_unreachable.relays_targeted,
            "without this field the two are indistinguishable to any consumer"
        );
        assert_eq!(nothing_configured.relays_targeted, 0);
        assert_eq!(all_unreachable.relays_targeted, 3);
    }

    #[test]
    fn a_publish_branch_with_no_ack_is_not_a_completed_publish() {
        // The action names the BRANCH, not the result. A rotation that reached
        // nobody must be readable as a failure from the counters alone — and
        // when the `not_after` purge also fired, it is the worst state there is:
        // no usable init key AND no published replacement.
        let unacked_rotation = KpMaintenanceOutcome {
            action: KpMaintenanceAction::RotatedExpiringMaterial,
            canonical_on_relays: 1,
            relays_targeted: 2,
            responders_probed: 2,
            relays_healed: 0,
            relay_errors: 1,
            expired_init_key_purged: true,
        };
        assert_eq!(
            unacked_rotation.relays_healed, 0,
            "no relay acked, so nothing was rotated in fact"
        );
        assert!(
            unacked_rotation.relays_targeted > 0,
            "relays WERE configured — this is not the nothing-configured case"
        );
        assert!(unacked_rotation.expired_init_key_purged);
    }

    // ── Lifetime-aware rotation (branch 2a) ──────────────────────────────────

    #[test]
    fn rotation_fraction_is_pinned_in_both_directions() {
        // This test exists to make a quiet edit of the fraction impossible.
        //
        // The window is `not_after - not_before` = 7_261_200 s (84 d + 1 h), the
        // `OpenMLS` default and the Marmot maximum. At 0.75:
        //   * rotation lands ~day 63 (from the mint instant),
        //   * ~21 days of slack remain before the package stops validating.
        //
        // RAISING it spends that slack — and the slack is the entire budget for
        // a device that is backgrounded, offline, or whose relays are all
        // unreachable on the tick that would have rotated (a no-responder tick
        // is deliberately a NoOp). At 0.9 an ordinary 8-day absence becomes
        // silent uninvitability.
        //
        // LOWERING it buys slack Haven does not need and costs privacy: every
        // rotation is a fresh 30443 publish to the account's own relays — an
        // observable "this account is alive" beacon — and churns init-key
        // material for no protocol benefit.
        assert!(
            (KP_ROTATE_AT_LIFETIME_FRACTION - 0.75).abs() < f64::EPSILON,
            "KP_ROTATE_AT_LIFETIME_FRACTION moved from 0.75; read this test's \
             comment before changing it"
        );
        // Pin the CONSEQUENCE too, so replacing the constant with an equivalent
        // hard-coded expression still trips.
        let l = KeyPackageLifetime::new(0, SPAN);
        assert_eq!(l.rotate_at(), 5_445_900, "rotation point moved");
        assert_eq!(
            (l.not_after - l.rotate_at()) / 86_400,
            21,
            "the post-rotation slack moved"
        );
    }

    #[test]
    fn past_threshold_rotates_into_the_same_slot() {
        // Reuse the stable `d`: the transport binding says a routine replacement
        // MUST NOT generate a fresh slot id.
        let snap = snapshot(vec![per(
            "wss://a.example.com",
            vec![entry("d-slot", "ev1")],
        )]);
        assert_eq!(
            decide_kp_maintenance(&snap, Some("d-slot"), expiring_lifetime(), NOW),
            KpMaintenanceDecision::Rotate {
                existing_d: "d-slot".to_owned(),
                targets: vec!["wss://a.example.com".to_owned()],
                lifetime_unreadable: false,
            }
        );
    }

    #[test]
    fn one_second_before_threshold_does_not_rotate() {
        let snap = snapshot(vec![per(
            "wss://a.example.com",
            vec![entry("d-slot", "ev1")],
        )]);
        assert_eq!(
            decide_kp_maintenance(&snap, Some("d-slot"), expiring_lifetime(), NOW - 1),
            KpMaintenanceDecision::NoOp,
            "one second early must still be a no-op"
        );
    }

    #[test]
    fn rotation_targets_every_responder_not_just_the_missing_ones() {
        // THE ordering invariant: past-threshold AND partially dropped must
        // re-mint ONCE and publish everywhere — never heal-then-rotate, which
        // would re-advertise aging bytes to the dropped relay first.
        let snap = snapshot(vec![
            per("wss://a.example.com", vec![entry("d-slot", "ev1")]),
            per("wss://b.example.com", vec![]),
            per("wss://c.example.com", vec![entry("d-other", "ev2")]),
        ]);
        let decision = decide_kp_maintenance(&snap, Some("d-slot"), expiring_lifetime(), NOW);
        let KpMaintenanceDecision::Rotate { targets, .. } = decision else {
            panic!("past-threshold + partial drop must Rotate, not Republish: {decision:?}");
        };
        assert_eq!(
            targets,
            vec![
                "wss://a.example.com".to_owned(),
                "wss://b.example.com".to_owned(),
                "wss://c.example.com".to_owned(),
            ],
            "A already serves the slot but its material is aging — it needs the \
             replacement too"
        );
    }

    #[test]
    fn unreadable_lifetime_rotates_and_is_labelled() {
        let snap = snapshot(vec![per(
            "wss://a.example.com",
            vec![entry("d-slot", "ev1")],
        )]);
        assert_eq!(
            decide_kp_maintenance(&snap, Some("d-slot"), TrackedKpLifetime::Unreadable, NOW),
            KpMaintenanceDecision::Rotate {
                existing_d: "d-slot".to_owned(),
                targets: vec!["wss://a.example.com".to_owned()],
                // The load-bearing half: an unreadable-lifetime rotation must be
                // DISTINGUISHABLE, or a reader that breaks for every package
                // silently churns init keys forever.
                lifetime_unreadable: true,
            }
        );
    }

    #[test]
    fn not_current_lifetime_rotates_but_is_not_labelled_unreadable() {
        let snap = snapshot(vec![per(
            "wss://a.example.com",
            vec![entry("d-slot", "ev1")],
        )]);
        assert_eq!(
            decide_kp_maintenance(&snap, Some("d-slot"), TrackedKpLifetime::NotCurrent, NOW),
            KpMaintenanceDecision::Rotate {
                existing_d: "d-slot".to_owned(),
                targets: vec!["wss://a.example.com".to_owned()],
                lifetime_unreadable: false,
            }
        );
    }

    #[test]
    fn absent_lifetime_never_rotates_and_falls_through_to_heal() {
        // A seed row (empty bytes) tracks a `d` but no material. There is
        // nothing to age out, so branch 2a must not fire; branch 2b heals.
        let snap = snapshot(vec![per("wss://a.example.com", vec![])]);
        assert_eq!(
            decide_kp_maintenance(&snap, Some("d-slot"), TrackedKpLifetime::Absent, u64::MAX),
            KpMaintenanceDecision::Republish {
                existing_d: Some("d-slot".to_owned()),
                targets: vec!["wss://a.example.com".to_owned()],
            }
        );
    }

    #[test]
    fn migration_is_free_an_old_package_reads_past_threshold_immediately() {
        // No special-case migration path exists or is needed: an account
        // published before this feature shipped simply reads as past-threshold
        // on its very next check, because the verdict comes from `not_after` —
        // which was already stamped into the package when it was minted.
        let minted_70_days_ago =
            KeyPackageLifetime::new(NOW - 70 * 86_400, NOW - 70 * 86_400 + SPAN);
        let snap = snapshot(vec![per(
            "wss://a.example.com",
            vec![entry("d-slot", "ev1")],
        )]);
        let decision = decide_kp_maintenance(
            &snap,
            Some("d-slot"),
            TrackedKpLifetime::Known(minted_70_days_ago),
            NOW,
        );
        assert!(
            matches!(decision, KpMaintenanceDecision::Rotate { .. }),
            "a 70-day-old package must rotate on the first lifetime-aware tick, \
             with no migration step: {decision:?}"
        );
    }

    #[test]
    fn a_young_package_from_before_the_feature_is_left_alone() {
        // The other half of "migration is free": an account that published
        // yesterday must NOT be churned just because the check is new.
        let minted_yesterday = KeyPackageLifetime::new(NOW - 86_400, NOW - 86_400 + SPAN);
        let snap = snapshot(vec![per(
            "wss://a.example.com",
            vec![entry("d-slot", "ev1")],
        )]);
        assert_eq!(
            decide_kp_maintenance(
                &snap,
                Some("d-slot"),
                TrackedKpLifetime::Known(minted_yesterday),
                NOW
            ),
            KpMaintenanceDecision::NoOp
        );
    }

    // ── Monotonic `created_at` (NIP-01 tie-break) ────────────────────────────

    #[test]
    fn monotonic_created_at_uses_now_when_there_is_no_prior() {
        assert_eq!(monotonic_kp_created_at(None, 5_000).as_secs(), 5_000);
    }

    #[test]
    fn monotonic_created_at_steps_past_a_same_second_collision() {
        // THE bug this closes: a rotation landing in the same wall-clock second
        // as the publish it replaces. Equal `created_at` hands the slot to
        // whichever event has the lower id — a coin flip the publisher does not
        // control, resolved SILENTLY by the relay.
        assert_eq!(
            monotonic_kp_created_at(Some(5_000), 5_000).as_secs(),
            5_001,
            "a same-second replacement must be stamped strictly later"
        );
    }

    #[test]
    fn monotonic_created_at_steps_past_a_future_prior() {
        // A row written under a clock that was ahead: still step past it, or the
        // replacement loses to its own predecessor.
        assert_eq!(monotonic_kp_created_at(Some(9_000), 5_000).as_secs(), 9_001);
    }

    #[test]
    fn monotonic_created_at_prefers_now_when_the_prior_is_older() {
        assert_eq!(monotonic_kp_created_at(Some(1_000), 5_000).as_secs(), 5_000);
    }

    #[test]
    fn monotonic_created_at_ignores_a_negative_prior() {
        assert_eq!(monotonic_kp_created_at(Some(-5), 5_000).as_secs(), 5_000);
    }

    #[test]
    fn monotonic_created_at_saturates_at_u64_max() {
        assert_eq!(
            monotonic_kp_created_at(Some(i64::MAX), 0).as_secs(),
            i64::MAX as u64 + 1
        );
    }

    // ── Event building ───────────────────────────────────────────────────────

    fn kp_bytes_from_session() -> (Keys, Vec<u8>) {
        // A real minted KeyPackage is required so `key_package_metadata`
        // validates (incl. the account-identity proof). Build one via an
        // in-memory session.
        //
        // The suffix is a process-wide ATOMIC counter, not a nanosecond stamp:
        // `cargo test` runs these in parallel threads and two of them can read
        // the same nanosecond, in which case both sessions target the same DB
        // file and the second trips the Rule-14 single-session guard
        // (`HAVEN_E_SESSION_BUSY`) — a flake, not a real defect, but one that
        // gets likelier with every test added here.
        static SEQ: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
        let keys = Keys::generate();
        let dir = std::env::temp_dir().join(format!(
            "haven_kp_evt_{}_{}",
            std::process::id(),
            SEQ.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
        ));
        let session = SessionManager::new_unencrypted(&dir, &keys).expect("session");
        let rt = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap();
        let kp = rt.block_on(session.fresh_key_package()).expect("mint");
        let _ = std::fs::remove_dir_all(&dir);
        (keys, kp.bytes().to_vec())
    }

    fn tag_value<'a>(event: &'a nostr::Event, name: &str) -> Option<&'a str> {
        event
            .tags
            .iter()
            .find(|t| t.as_slice().first().map(String::as_str) == Some(name))
            .and_then(|t| t.as_slice().get(1))
            .map(String::as_str)
    }

    #[test]
    fn build_key_package_event_has_marmot_tag_set_and_no_encoding_or_relays() {
        let (keys, kp) = kp_bytes_from_session();
        let event =
            build_key_package_event(&keys, &kp, "d-stable", nostr::Timestamp::from_secs(7_000))
                .expect("build");
        assert_eq!(
            event.created_at.as_secs(),
            7_000,
            "the caller's monotonic stamp must survive to the wire, not be \
             overwritten by the builder's default `now`"
        );

        assert_eq!(event.kind, Kind::Custom(KIND_MARMOT_KEY_PACKAGE));
        assert_eq!(event.pubkey, keys.public_key());
        assert_eq!(event.content, BASE64.encode(&kp));
        assert_eq!(tag_value(&event, "d"), Some("d-stable"));
        assert_eq!(tag_value(&event, "mls_protocol_version"), Some("1.0"));
        assert_eq!(tag_value(&event, "mls_ciphersuite"), Some("0x0001"));
        // `i` is the KeyPackage ref (64 hex chars).
        assert_eq!(tag_value(&event, "i").map(str::len), Some(64));
        // Retired / never-present tags.
        assert_eq!(tag_value(&event, "encoding"), None);
        assert_eq!(tag_value(&event, "relays"), None);
        // app_components carries the three configured component ids.
        let comp = event
            .tags
            .iter()
            .find(|t| t.as_slice().first().map(String::as_str) == Some("app_components"))
            .expect("app_components tag");
        assert_eq!(&comp.as_slice()[1..], &["0x8001", "0x8003", "0x8004"]);
    }

    #[test]
    fn build_key_package_event_rejects_empty_d() {
        let (keys, kp) = kp_bytes_from_session();
        let err = build_key_package_event(&keys, &kp, "", nostr::Timestamp::now())
            .expect_err("empty d must fail");
        assert_eq!(err.to_string(), "failed to build event");
    }

    #[test]
    fn reuse_builds_same_slot_and_content() {
        let (keys, kp) = kp_bytes_from_session();
        let own = vec!["wss://own.example.com".to_string()];
        let events =
            build_kp_maintenance_events_reusing(&keys, &kp, &own, "d-stable", None).expect("reuse");
        assert_eq!(events.d_tag, "d-stable");
        assert_eq!(events.relays, own);
        assert_eq!(events.key_package.bytes(), kp.as_slice());
        assert_eq!(events.event.content, BASE64.encode(&kp));
    }

    #[test]
    fn kp_maintenance_events_debug_is_presence_only() {
        let (keys, kp) = kp_bytes_from_session();
        let own = vec!["wss://secret-own-relay.example.com".to_string()];
        let stable = "deadbeefdeadbeefdeadbeefdeadbeef";
        let events =
            build_kp_maintenance_events_reusing(&keys, &kp, &own, stable, None).expect("build");
        let dbg = format!("{events:?}");
        assert!(!dbg.contains("secret-own-relay"), "leaked relay url: {dbg}");
        assert!(!dbg.contains(stable), "leaked d tag: {dbg}");
        assert!(dbg.contains("relay_count"));
        assert!(dbg.contains("<redacted>"));
    }

    // ── Retraction builders ──────────────────────────────────────────────────

    #[test]
    fn legacy_retraction_requires_self_authorship() {
        let keys = Keys::generate();
        let other = Keys::generate();
        let dummy = EventBuilder::new(Kind::Custom(443), "")
            .sign_with_keys(&other)
            .unwrap();
        let err = build_legacy_key_package_retraction(
            &keys,
            &dummy.id.to_hex(),
            &other.public_key().to_hex(),
        )
        .expect_err("must refuse foreign-authored deletion");
        assert_eq!(err.to_string(), "failed to build event");
    }

    #[test]
    fn legacy_retraction_is_e_tag_only_no_coordinate() {
        let keys = Keys::generate();
        let dummy = EventBuilder::new(Kind::Custom(443), "")
            .sign_with_keys(&keys)
            .unwrap();
        let deletion = build_legacy_key_package_retraction(
            &keys,
            &dummy.id.to_hex(),
            &keys.public_key().to_hex(),
        )
        .expect("self-authored deletion builds");
        assert_eq!(deletion.kind, Kind::EventDeletion);
        let has_e = deletion.tags.iter().any(|t| {
            let s = t.as_slice();
            s.len() >= 2 && s[0] == "e" && s[1] == dummy.id.to_hex()
        });
        assert!(has_e, "deletion must reference the legacy event id via 'e'");
        let has_a = deletion
            .tags
            .iter()
            .any(|t| t.as_slice().first().map(String::as_str) == Some("a"));
        assert!(
            !has_a,
            "deletion must NOT carry an 'a' coordinate: {:?}",
            deletion.tags
        );
    }

    #[test]
    fn key_package_relay_list_retraction_is_empty_replaceable_10051() {
        let keys = Keys::generate();
        let event = build_key_package_relay_list_retraction(&keys, None).expect("retraction");
        assert_eq!(event.kind, Kind::MlsKeyPackageRelays);
        assert_eq!(event.content, "");
        let has_relay = event
            .tags
            .iter()
            .any(|t| t.as_slice().first().map(String::as_str) == Some("relay"));
        assert!(!has_relay, "retraction must have no relay tags");
    }
}
