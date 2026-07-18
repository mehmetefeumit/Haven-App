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
//!
//! * **Heal** (a relay dropped the KP): re-publish the SAME cached last-resort
//!   package verbatim into the same slot — no re-mint (the private material
//!   still lives in the engine). [`build_kp_maintenance_events_reusing`].
//! * **Rotation / first publish**: mint a fresh package
//!   ([`build_kp_maintenance_events`]); on a rotation the FFI feeds the
//!   superseded package's cached bytes to [`SessionManager::delete_key_package`]
//!   (mdk#160) so orphaned private material does not accumulate.
//! * **Failed publish**: the FFI feeds the just-minted package to
//!   [`SessionManager::delete_key_package`] so a retry loop against a failing
//!   relay does not leak private material (mdk#160).
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
/// 2. **A slot is tracked** ⇒ heal the responders NOT serving it; if all serve
///    it, [`KpMaintenanceDecision::NoOp`].
/// 3. **No slot tracked but a responder serves a well-formed `d`** ⇒
///    [`KpMaintenanceDecision::SeedD`] (adopt it before publishing, so cycle 1
///    does not fork the address).
/// 4. **No slot tracked and no adoptable `d`** ⇒
///    [`KpMaintenanceDecision::Republish`] into a fresh slot, targeting every
///    responder.
///
/// `stored_stable_d` is the caller's `latest_canonical_d_tag()` from
/// `published_key_packages`.
#[must_use]
pub fn decide_kp_maintenance(
    snapshot: &RelayKpSnapshot,
    stored_stable_d: Option<&str>,
) -> KpMaintenanceDecision {
    // Branch 1: fail-closed. No responders ⇒ can't confirm any drop this tick.
    if snapshot.responders.is_empty() {
        return KpMaintenanceDecision::NoOp;
    }

    if let Some(stable_d) = stored_stable_d {
        // Branch 2: heal the responders that do not serve the tracked slot.
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

/// Builds a signed kind-30443 `KeyPackage` event from raw MLS wire bytes.
///
/// Mirrors the v0.9.4 `transport-nostr-adapter` tag set exactly: `d` slot,
/// `mls_protocol_version`, `i` (the `KeyPackage` ref, derived from the bytes),
/// `mls_ciphersuite`, `mls_extensions`, `mls_proposals`, `app_components`;
/// base64 content; NO `encoding` tag; NO `relays` tag. Unlike the adapter's
/// transport-agnostic unsigned event, Haven signs with the identity key (30443
/// is identity-signed, W1).
fn build_key_package_event(keys: &Keys, kp_bytes: &[u8], d: &str) -> PublisherResult<nostr::Event> {
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

/// Mints a FRESH `KeyPackage` and builds its signed kind-30443 event for a
/// [`KpMaintenanceDecision::Republish`] — the rotation / first-publish path.
///
/// Mints via [`SessionManager::fresh_key_package`], builds+signs the event into
/// `existing_d` (or a freshly minted stable slot when `None`), and returns the
/// [`KeyPackage`] handle so the FFI can delete it on a failed publish (mdk#160).
/// The returned [`KpMaintenanceEvents::relays`] is exactly `own_kp_relays` — no
/// default set is unioned in (own-relays-only invariant).
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
) -> PublisherResult<KpMaintenanceEvents> {
    let key_package = session
        .fresh_key_package()
        .await
        .map_err(|e| PublisherError::Build(format!("mint key package: {e}")))?;
    let d_tag = existing_d.map_or_else(mint_d, str::to_owned);
    let event = build_key_package_event(keys, key_package.bytes(), &d_tag)?;
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
/// # Errors
///
/// Returns [`PublisherError::Build`] if metadata derivation or signing fails.
pub fn build_kp_maintenance_events_reusing(
    keys: &Keys,
    cached_kp_bytes: &[u8],
    own_kp_relays: &[String],
    d: &str,
) -> PublisherResult<KpMaintenanceEvents> {
    let event = build_key_package_event(keys, cached_kp_bytes, d)?;
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
    /// Responding relays this tick republished to.
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

    #[test]
    fn all_responders_serve_slot_is_noop() {
        let snap = snapshot(vec![
            per("wss://a.example.com", vec![entry("d-slot", "ev1")]),
            per("wss://b.example.com", vec![entry("d-slot", "ev2")]),
        ]);
        assert_eq!(
            decide_kp_maintenance(&snap, Some("d-slot")),
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
            decide_kp_maintenance(&snap, Some("d-slot")),
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
            decide_kp_maintenance(&snap, Some("d-slot")),
            KpMaintenanceDecision::Republish {
                existing_d: Some("d-slot".to_owned()),
                targets: vec!["wss://b.example.com".to_owned()],
            }
        );
    }

    #[test]
    fn empty_responders_is_noop() {
        assert_eq!(
            decide_kp_maintenance(&snapshot(vec![]), Some("d-x")),
            KpMaintenanceDecision::NoOp
        );
        assert_eq!(
            decide_kp_maintenance(&snapshot(vec![]), None),
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
            decide_kp_maintenance(&snap, None),
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
            decide_kp_maintenance(&snap, None),
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
            decide_kp_maintenance(&snap, Some("d-unserved")),
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
            decide_kp_maintenance(&snap, None),
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
            decide_kp_maintenance(&snap, None),
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
        let KpMaintenanceDecision::Republish { targets, .. } =
            decide_kp_maintenance(&snap, Some("d-slot"))
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
            responders_probed: 3,
            relays_healed: 2,
            relay_errors: 1,
        };
        let dbg = format!("{o:?}");
        assert!(
            !dbg.contains("wss://"),
            "outcome must not carry a relay url"
        );
        assert!(dbg.contains("responders_probed"));
        assert!(dbg.contains("relays_healed"));
    }

    #[test]
    fn outcome_no_op_constructor() {
        let o = KpMaintenanceOutcome::no_op(3);
        assert_eq!(o.action, KpMaintenanceAction::AlreadyHealthy);
        assert_eq!(o.canonical_on_relays, 3);
        assert_eq!(o.relays_healed, 0);
    }

    // ── Event building ───────────────────────────────────────────────────────

    fn kp_bytes_from_session() -> (Keys, Vec<u8>) {
        // A real minted KeyPackage is required so `key_package_metadata`
        // validates (incl. the account-identity proof). Build one via an
        // in-memory session.
        let keys = Keys::generate();
        let dir = std::env::temp_dir().join(format!(
            "haven_kp_evt_{}_{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
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
        let event = build_key_package_event(&keys, &kp, "d-stable").expect("build");

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
        let err = build_key_package_event(&keys, &kp, "").expect_err("empty d must fail");
        assert_eq!(err.to_string(), "failed to build event");
    }

    #[test]
    fn reuse_builds_same_slot_and_content() {
        let (keys, kp) = kp_bytes_from_session();
        let own = vec!["wss://own.example.com".to_string()];
        let events =
            build_kp_maintenance_events_reusing(&keys, &kp, &own, "d-stable").expect("reuse");
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
        let events = build_kp_maintenance_events_reusing(&keys, &kp, &own, stable).expect("build");
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
