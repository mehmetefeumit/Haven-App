//! B1 `RelayListMaintenance` (M8-1): the pure decision core.
//!
//! This module answers one question idempotently, per relay-list category
//! (kind 10050 inbox / kind 10051 `KeyPackage`): **does the user's relay list
//! need republishing to their own relays right now, and if so, to WHICH
//! relays?** It never touches the network and never signs — the network probe
//! and the signed publish are composed at the FFI boundary (which owns the
//! identity secret and the [`RelayManager`]). Everything here is fully pure
//! ([`decide_relay_list`], [`RelayListSnapshot`], [`RelayListMaintenanceOutcome`]).
//!
//! # Why a per-relay network probe, not a merged one (nostr must-fix)
//!
//! A relay-list event is a *replaceable* Nostr event: a relay can silently
//! drop it (retention/GC, storage reset, operator wipe) while the local
//! `published_events` row still says "we published one at T". A
//! local-timestamp-only check would then wrongly conclude "already published"
//! and leave the user undiscoverable. Worse, a MERGED probe (union across all
//! own relays) hides a PARTIAL drop: present on relay A, dropped from B — the
//! user is undiscoverable to any peer that queries B, yet the merge reports
//! "present". A peer discovering the list queries a *subset* of the advertised
//! relays, never the union. The FFI therefore probes each of the user's OWN
//! relays INDEPENDENTLY ([`RelayManager::fetch_events_per_relay`]) and this
//! decision runs on the per-relay verdicts — see [`RelayListSnapshot::responders`].
//!
//! # Drift detection
//!
//! Beyond mere presence, an on-relay list can be *stale*: it can enumerate a
//! different relay set than the user currently has configured (they added or
//! removed a relay via a path that never republished). Each responder's list is
//! compared to the locally-configured set (order-insensitive,
//! scheme/host-canonicalized via [`dedup_key`]) by [`list_relay_healthy`]; a
//! mismatch marks that relay unhealthy so the on-relay list converges to what
//! the user configured. A relay that returns no list at all is unhealthy too.
//!
//! # Targeted republish
//!
//! Only the RESPONDING relays that are unhealthy (missing or drifted) are
//! republish targets. Non-responders are NEVER targeted (you cannot write to an
//! unreachable relay, and a blind full-fan-out on a flapping relay is a
//! per-tick write storm). Healthy responders are skipped (a NIP-33 same-`d`
//! re-assert to a healthy relay would be harmless but wasteful). This is
//! strictly more precise than a full re-fan-out, gives an honest
//! `relays_healed` count, and reduces write/correlation surface (PSI-8).
//!
//! # Privacy toggle
//!
//! When the user has opted OUT of publishing a category
//! ([`RelayListSnapshot::publish_enabled`] is `false`), maintenance is a no-op
//! — it NEVER publishes a suppressed list. Un-publishing an already-published
//! list is a separate, user-initiated flow (`build_unpublish_relay_list`);
//! maintenance only ever *re-asserts* a list the user chose to publish.
//!
//! # Own-relays-only (PSI-8)
//!
//! Both the probe (read) and the republish (write) target the user's OWN
//! configured relays only — never the discovery plane, NIP-65/kind-10002, or a
//! default union. The republish TARGETS are a subset of the configured set, so
//! `targets ⊆ configured ⊆ own` holds structurally. Haven's kind-10050/10051
//! posture diverges from the current Marmot spec's 10002 KP discovery on
//! purpose; see the module docs on [`crate::relay::publishers`].
//!
//! [`RelayManager`]: crate::relay::RelayManager
//! [`RelayManager::fetch_events_per_relay`]: crate::relay::RelayManager::fetch_events_per_relay
//! [`dedup_key`]: crate::relay::publishers::dedup_key

/// One RESPONDING own-relay's verdict for a relay-list category (FFI-built).
///
/// `relay_url` is a user-configured own-relay URL — callers MUST NOT log this
/// struct, and it MUST NEVER enter a maintenance OUTCOME (only integer counts
/// cross the FFI). Non-responders are NOT represented here: they are neither a
/// heal target nor "unhealthy" (you cannot write to an unreachable relay), so
/// excluding them at snapshot-build time makes "never target a non-responder" a
/// STRUCTURAL invariant rather than a defensive check.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RelayListPerRelay {
    /// The own-relay URL this verdict is for. MUST NOT be logged / put in an
    /// outcome.
    pub relay_url: String,
    /// Whether this relay serves a current (newest), non-drifted list that
    /// matches the configured relay set. `false` when the list is absent,
    /// stale, or enumerates a different set.
    pub healthy: bool,
}

/// What the FFI's per-relay network probe found on the user's OWN relays for one
/// relay-list category, plus the local configuration inputs.
///
/// `responders` carries RESPONDING relays only. `publish_enabled` +
/// `configured_relays` carry no secret material, MLS group ids, or hex, but
/// `responders`/`configured_relays` DO carry relay URLs — so callers must NOT
/// log a `RelayListSnapshot`; only the OUTCOME (integer counts) crosses the FFI
/// (see the `wss://`-absence test on the outcome).
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct RelayListSnapshot {
    /// Whether the user has opted IN to publishing this category (the privacy
    /// toggle). When `false`, maintenance is always a no-op.
    pub publish_enabled: bool,
    /// Per-relay verdicts for RESPONDING own relays only. Empty means every
    /// configured relay was unreachable this tick (or none configured).
    pub responders: Vec<RelayListPerRelay>,
    /// The user's currently-configured relays for this category (the republish
    /// content + drift baseline, own-relays-only, already dedup'd by the caller).
    pub configured_relays: Vec<String>,
}

/// The maintenance decision for one relay-list category tick.
///
/// [`Suppressed`](Self::Suppressed)/[`NoOp`](Self::NoOp) are payload-free; the
/// [`Republish`](Self::Republish) variant carries own-relay URLs, so a
/// `RelayListDecision` MUST NOT be logged (only the presence-only OUTCOME
/// crosses the FFI).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RelayListDecision {
    /// Publishing is suppressed by the privacy toggle (or nothing configured).
    Suppressed,
    /// Every responding relay already serves a current, non-drifted list (or no
    /// relay responded this tick) — do nothing.
    NoOp,
    /// Republish the (full configured) list to exactly these responding +
    /// unhealthy relays. Always non-empty.
    Republish {
        /// The responding, unhealthy own-relay URLs to (re)publish to.
        targets: Vec<String>,
    },
}

/// Decides the relay-list maintenance action for one category this tick (PURE).
///
/// Ordering of the branches:
///
/// 1. **Toggle OFF or nothing configured** ⇒ [`RelayListDecision::Suppressed`].
///    We never publish a list the user opted out of, we never *unpublish* here
///    (that is a separate user-initiated flow), and with nothing configured
///    there is no legitimate own-relays-only publish target.
/// 2. **No responders** (all transiently unreachable this tick) ⇒
///    [`RelayListDecision::NoOp`] (fail-closed; retry next tick — never a blind
///    republish we cannot even confirm is needed).
/// 3. **≥1 responding unhealthy relay** ⇒ [`RelayListDecision::Republish`] to
///    exactly those relays (missing or drifted on the wire).
/// 4. **Every responder healthy** ⇒ [`RelayListDecision::NoOp`].
#[must_use]
pub fn decide_relay_list(snapshot: &RelayListSnapshot) -> RelayListDecision {
    if !snapshot.publish_enabled || snapshot.configured_relays.is_empty() {
        return RelayListDecision::Suppressed;
    }
    // Fail-closed: no responders (all transiently unreachable) ⇒ NoOp, retry
    // next tick. We never blind-republish when we could not confirm a drop.
    if snapshot.responders.is_empty() {
        return RelayListDecision::NoOp;
    }
    let targets: Vec<String> = snapshot
        .responders
        .iter()
        .filter(|r| !r.healthy)
        .map(|r| r.relay_url.clone())
        .collect();
    if targets.is_empty() {
        RelayListDecision::NoOp
    } else {
        RelayListDecision::Republish { targets }
    }
}

/// Returns whether one responding relay's on-relay list is CURRENT (PURE).
///
/// `healthy` ⇔ the relay's newest list `relay`-tag set equals the configured
/// set (order-insensitive, scheme/host-canonicalized via [`dedup_key`]). An
/// absent on-relay list ⇒ pass an empty `on_relay_relays` ⇒ `false`. The FFI
/// calls this once per responding relay to compute
/// [`RelayListPerRelay::healthy`].
///
/// [`dedup_key`]: crate::relay::publishers::dedup_key
#[must_use]
pub fn list_relay_healthy(on_relay_relays: &[String], configured_relays: &[String]) -> bool {
    canonical_set(on_relay_relays) == canonical_set(configured_relays)
}

/// Canonicalizes a relay-URL list into an order-insensitive set of dedup keys.
///
/// Reuses [`dedup_key`][crate::relay::publishers] semantics (lowercase scheme +
/// host, path/query/fragment preserved) so "the same relay" means the same
/// thing here as in the publish-target dedup.
fn canonical_set(urls: &[String]) -> std::collections::BTreeSet<String> {
    urls.iter()
        .map(|u| crate::relay::publishers::dedup_key(u))
        .collect()
}

/// The terminal action a relay-list maintenance tick carried out, per category.
///
/// Fieldless (Copy) and payload-free — no urls, hex, or group ids — so its
/// derived `Debug` cannot leak (Security Rule 4/6).
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum RelayListAction {
    /// Publishing is suppressed by the privacy toggle (or nothing configured).
    #[default]
    Suppressed,
    /// Every responding relay was already current — no change.
    AlreadyCurrent,
    /// The list was (re)published to one or more own relays this tick.
    Republished,
}

/// Presence-only tally of a relay-list maintenance tick, per category (one for
/// inbox 10050, one for `KeyPackage` 10051).
///
/// Every field is an enum or a count — no urls, hex, or group ids — so the
/// derived `Debug` is leak-free by construction (Security Rule 4/6). This is
/// the per-category shape the FFI folds into
/// [`RelayListMaintenanceOutcomeFfi`][crate::relay::maintenance].
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct RelayListCategoryOutcome {
    /// What the tick did for this category.
    pub action: RelayListAction,
    /// Responding own relays probed this tick (non-responders excluded).
    pub responders_probed: usize,
    /// Responding + unhealthy relays this tick was (re)published to.
    pub relays_healed: usize,
    /// Relay probes/publishes that errored (tallied, never fatal).
    pub relay_errors: usize,
}

impl RelayListCategoryOutcome {
    /// Builds the outcome for a decision that resolved to no publish
    /// (suppressed, or every responder already current).
    #[must_use]
    pub const fn no_publish(action: RelayListAction) -> Self {
        Self {
            action,
            responders_probed: 0,
            relays_healed: 0,
            relay_errors: 0,
        }
    }
}

/// Presence-only tally of a full relay-list maintenance tick (both categories).
///
/// Fieldless-of-secrets by construction (only nested enums + counts), so the
/// derived `Debug` is leak-free.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct RelayListMaintenanceOutcome {
    /// The inbox (kind 10050) category outcome.
    pub inbox: RelayListCategoryOutcome,
    /// The `KeyPackage` (kind 10051) category outcome.
    pub key_package: RelayListCategoryOutcome,
}

#[cfg(test)]
mod tests {
    use super::*;

    fn per(url: &str, healthy: bool) -> RelayListPerRelay {
        RelayListPerRelay {
            relay_url: url.to_owned(),
            healthy,
        }
    }

    fn snap(
        publish_enabled: bool,
        responders: Vec<RelayListPerRelay>,
        configured: &[&str],
    ) -> RelayListSnapshot {
        RelayListSnapshot {
            publish_enabled,
            responders,
            configured_relays: configured.iter().map(|s| (*s).to_owned()).collect(),
        }
    }

    // ---- Test 1: all responders healthy ⇒ NoOp ----------------------------

    #[test]
    fn all_responders_healthy_is_noop() {
        let s = snap(
            true,
            vec![
                per("wss://a.example.com", true),
                per("wss://b.example.com", true),
            ],
            &["wss://a.example.com", "wss://b.example.com"],
        );
        assert_eq!(decide_relay_list(&s), RelayListDecision::NoOp);
    }

    // ---- Test 2: headline partial-drop ⇒ Republish{[unhealthy]} ------------

    #[test]
    fn one_healthy_one_unhealthy_republishes_to_unhealthy_only() {
        let s = snap(
            true,
            vec![
                per("wss://healthy.example.com", true),
                per("wss://dropped.example.com", false),
            ],
            &["wss://healthy.example.com", "wss://dropped.example.com"],
        );
        assert_eq!(
            decide_relay_list(&s),
            RelayListDecision::Republish {
                targets: vec!["wss://dropped.example.com".to_owned()],
            }
        );
    }

    // ---- Test 3: one current + one absent ⇒ Republish to absent only ------

    #[test]
    fn one_current_one_absent_republishes_to_absent_only() {
        // "Absent" is modeled by the FFI as an unhealthy responder (empty
        // on-relay list ⇒ list_relay_healthy == false).
        let s = snap(
            true,
            vec![
                per("wss://has-list.example.com", true),
                per("wss://absent.example.com", false),
            ],
            &["wss://has-list.example.com", "wss://absent.example.com"],
        );
        assert_eq!(
            decide_relay_list(&s),
            RelayListDecision::Republish {
                targets: vec!["wss://absent.example.com".to_owned()],
            }
        );
    }

    // ---- Test 4: all unhealthy ⇒ targets = all responders -----------------

    #[test]
    fn all_unhealthy_targets_all_responders() {
        let s = snap(
            true,
            vec![
                per("wss://a.example.com", false),
                per("wss://b.example.com", false),
            ],
            &["wss://a.example.com", "wss://b.example.com"],
        );
        assert_eq!(
            decide_relay_list(&s),
            RelayListDecision::Republish {
                targets: vec![
                    "wss://a.example.com".to_owned(),
                    "wss://b.example.com".to_owned(),
                ],
            }
        );
    }

    // ---- Test 5: empty responders ⇒ NoOp (fail-closed) --------------------

    #[test]
    fn empty_responders_is_noop_fail_closed() {
        // All relays transiently unreachable this tick: we cannot confirm any
        // drop, so we NoOp and retry next tick rather than blind-republish.
        let s = snap(true, vec![], &["wss://own.example.com"]);
        assert_eq!(decide_relay_list(&s), RelayListDecision::NoOp);
    }

    // ---- Test 6: suppression gates (retain existing) ----------------------

    #[test]
    fn toggle_off_is_suppressed_even_when_unhealthy() {
        let s = snap(
            false,
            vec![per("wss://own.example.com", false)],
            &["wss://own.example.com"],
        );
        assert_eq!(decide_relay_list(&s), RelayListDecision::Suppressed);
    }

    #[test]
    fn no_configured_relays_is_suppressed() {
        // Own-relays-only: nothing configured ⇒ no legitimate publish target.
        let s = snap(true, vec![], &[]);
        assert_eq!(decide_relay_list(&s), RelayListDecision::Suppressed);
    }

    // ---- Test 7: targets contain ONLY unhealthy responders, in order ------

    #[test]
    fn targets_are_exactly_the_unhealthy_responders_in_order() {
        let s = snap(
            true,
            vec![
                per("wss://a.example.com", false),
                per("wss://b.example.com", true),
                per("wss://c.example.com", false),
            ],
            &[
                "wss://a.example.com",
                "wss://b.example.com",
                "wss://c.example.com",
            ],
        );
        let RelayListDecision::Republish { targets } = decide_relay_list(&s) else {
            panic!("expected Republish");
        };
        // Exactly the unhealthy URLs, healthy excluded, iteration order kept.
        assert_eq!(
            targets,
            vec![
                "wss://a.example.com".to_owned(),
                "wss://c.example.com".to_owned()
            ]
        );
        // No healthy relay leaked in.
        assert!(!targets.iter().any(|t| t == "wss://b.example.com"));
    }

    // ---- Test 8: list_relay_healthy semantics -----------------------------

    #[test]
    fn list_relay_healthy_is_order_and_scheme_host_canonical() {
        // Same set, different order + case ⇒ healthy.
        assert!(list_relay_healthy(
            &[
                "WSS://B.Example.com".to_owned(),
                "wss://a.example.com".to_owned()
            ],
            &[
                "wss://a.example.com".to_owned(),
                "wss://b.example.com".to_owned()
            ],
        ));
    }

    #[test]
    fn list_relay_healthy_added_relay_is_unhealthy() {
        assert!(!list_relay_healthy(
            &["wss://a.example.com".to_owned()],
            &[
                "wss://a.example.com".to_owned(),
                "wss://b.example.com".to_owned()
            ],
        ));
    }

    #[test]
    fn list_relay_healthy_removed_relay_is_unhealthy() {
        assert!(!list_relay_healthy(
            &[
                "wss://a.example.com".to_owned(),
                "wss://b.example.com".to_owned()
            ],
            &["wss://a.example.com".to_owned()],
        ));
    }

    #[test]
    fn list_relay_healthy_empty_on_relay_is_unhealthy() {
        // Absent list ⇒ empty on-relay set ⇒ never matches a non-empty config.
        assert!(!list_relay_healthy(
            &[],
            &["wss://a.example.com".to_owned()]
        ));
    }

    // ---- Test 9: relays_healed count + leak-free outcome ------------------

    #[test]
    fn relays_healed_equals_targets_len_semantics() {
        // The FFI sets relays_healed = targets.len() on a successful republish;
        // assert the decision produces the target count the FFI will use.
        let s = snap(
            true,
            vec![
                per("wss://a.example.com", false),
                per("wss://b.example.com", false),
                per("wss://c.example.com", true),
            ],
            &[
                "wss://a.example.com",
                "wss://b.example.com",
                "wss://c.example.com",
            ],
        );
        let RelayListDecision::Republish { targets } = decide_relay_list(&s) else {
            panic!("expected Republish");
        };
        assert_eq!(targets.len(), 2);
    }

    #[test]
    fn outcome_debug_has_no_relay_url_incl_new_counts() {
        let o = RelayListMaintenanceOutcome {
            inbox: RelayListCategoryOutcome {
                action: RelayListAction::Republished,
                responders_probed: 3,
                relays_healed: 2,
                relay_errors: 1,
            },
            key_package: RelayListCategoryOutcome::no_publish(RelayListAction::AlreadyCurrent),
        };
        let dbg = format!("{o:?}");
        assert!(
            !dbg.contains("wss://"),
            "outcome must not carry a relay url"
        );
        assert!(!dbg.contains("ws://"), "outcome must not carry a relay url");
        // The new count fields ARE present (as bare integers, no url).
        assert!(dbg.contains("responders_probed"));
        assert!(dbg.contains("relays_healed"));
    }

    #[test]
    fn category_outcome_no_publish_zeroes_new_counts() {
        let o = RelayListCategoryOutcome::no_publish(RelayListAction::AlreadyCurrent);
        assert_eq!(o.action, RelayListAction::AlreadyCurrent);
        assert_eq!(o.responders_probed, 0);
        assert_eq!(o.relays_healed, 0);
        assert_eq!(o.relay_errors, 0);
    }
}
