//! End-to-end integration tests for the M8 per-relay maintenance probe fix,
//! over real in-process Nostr relays.
//!
//! These mirror the FFI orchestration in `rust_builder`'s `maintain_*`
//! functions (which cannot be tested from `haven-core`): they build a per-relay
//! snapshot from [`RelayManager::fetch_events_per_relay`] over `MockRelay`
//! instances, feed it through the pure decision cores
//! ([`decide_kp_maintenance`] / [`decide_relay_list`]), and assert the TARGETED
//! [`RelayManager::publish_event`] heals only the confirmed drops — the headline
//! partial-drop fix. The pure decision logic is unit-tested in the maintenance
//! module; these tests prove the network glue (per-relay probe → decide →
//! subset publish → re-probe) converges over the wire.

use std::time::Duration;

use haven_core::circle::RelayType;
use haven_core::relay::maintenance::{
    build_legacy_key_package_retraction, decide_kp_maintenance, decide_relay_list,
    list_relay_healthy, KpMaintenanceDecision, RelayKpEntry, RelayKpPerRelay, RelayKpSnapshot,
    RelayListDecision, RelayListPerRelay, RelayListSnapshot,
};
use haven_core::relay::RelayManager;
use nostr::{EventBuilder, Keys, Kind, Tag};
use nostr_relay_builder::MockRelay;

// Dark Matter port (DM-5a): the KP maintenance decision core dropped the
// live-material verdict (M8-2 gate deleted — last-resort KPs never expire), so
// `decide_kp_maintenance` takes `(snapshot, stored_stable_d)` and `RelayKpEntry`
// no longer carries `hash_ref_matches_local_live`. The per-republish legacy-443
// twin GC (`latest_legacy_event_id`, `KEY_PACKAGE_KIND_*`, per-cycle deletions)
// is retired (30443 self-supersedes via NIP-33 same-`d`); its surviving piece —
// the one-time cutover retraction of a stale 443 — is `build_legacy_key_package_retraction`,
// exercised in a single re-expressed test at the bottom.

// ---------------------------------------------------------------------------
// Helpers that mirror the FFI's per-relay snapshot construction.
// ---------------------------------------------------------------------------

/// Extracts a kind-30443 event's NIP-33 `d` tag (mirrors the FFI helper).
fn kp_d_tag(ev: &nostr::Event) -> String {
    ev.tags
        .iter()
        .find_map(|t| {
            let s = t.as_slice();
            (s.len() >= 2 && s[0] == "d").then(|| s[1].clone())
        })
        .unwrap_or_default()
}

/// Extracts a relay-list event's `["relay", <url>]` URLs (mirrors the FFI).
fn list_urls(ev: &nostr::Event) -> Vec<String> {
    ev.tags
        .iter()
        .filter_map(|t| {
            let s = t.as_slice();
            (s.len() >= 2 && s[0] == "relay").then(|| s[1].clone())
        })
        .collect()
}

/// Builds a signed kind-30443 `KeyPackage`-shaped event with a given `d`, so a
/// probe finds a canonical on the relay. The content is opaque (these tests
/// exercise the discovery/heal wiring, not MLS material).
fn kp_30443(keys: &Keys, d: &str) -> nostr::Event {
    EventBuilder::new(Kind::Custom(30443), "opaque-kp")
        .tags([Tag::parse(["d", d]).unwrap()])
        .sign_with_keys(keys)
        .unwrap()
}

/// Builds a per-relay KP snapshot from a live per-relay probe. (DM: no more
/// live-material verdict — a relay serving any 30443 with the tracked `d` is
/// healthy; last-resort KPs never expire.)
async fn kp_snapshot(
    mgr: &RelayManager,
    author: nostr::PublicKey,
    relays: &[String],
) -> RelayKpSnapshot {
    let filter = nostr::Filter::new()
        .kind(Kind::Custom(30443))
        .author(author)
        .limit(64);
    let per_relay = mgr.fetch_events_per_relay(filter, relays).await.unwrap();
    let mut responders = Vec::new();
    for o in &per_relay {
        if !o.responded {
            continue;
        }
        let canonical = o
            .events
            .iter()
            .map(|ev| RelayKpEntry {
                d_tag: kp_d_tag(ev),
                event_id: ev.id.to_hex(),
            })
            .collect();
        responders.push(RelayKpPerRelay {
            relay_url: o.relay_url.clone(),
            canonical,
        });
    }
    RelayKpSnapshot { responders }
}

/// Builds a per-relay relay-list snapshot from a live per-relay probe, computing
/// each responder's `healthy` verdict against `configured`.
async fn list_snapshot(
    mgr: &RelayManager,
    author: nostr::PublicKey,
    relay_type: RelayType,
    probe_relays: &[String],
    configured: &[String],
    publish_enabled: bool,
) -> RelayListSnapshot {
    let filter = nostr::Filter::new()
        .kind(relay_type.to_kind())
        .author(author)
        .limit(4);
    let per_relay = mgr
        .fetch_events_per_relay(filter, probe_relays)
        .await
        .unwrap();
    let mut responders = Vec::new();
    for o in &per_relay {
        if !o.responded {
            continue;
        }
        let on_relay = o
            .events
            .iter()
            .max_by_key(|e| e.created_at.as_secs())
            .map(list_urls)
            .unwrap_or_default();
        responders.push(RelayListPerRelay {
            relay_url: o.relay_url.clone(),
            healthy: list_relay_healthy(&on_relay, configured),
        });
    }
    RelayListSnapshot {
        publish_enabled,
        responders,
        configured_relays: configured.to_vec(),
    }
}

/// Builds a signed kind-443 legacy `KeyPackage`-twin event. The legacy 443 is a
/// regular (non-replaceable) event, so each republish (rebuilding FRESH MLS
/// material, hence different content) leaves the prior one as a lingering twin
/// under a distinct event id — the exact garbage the maintenance GC scrubs.
/// `content` distinguishes cycles the way fresh key material does in production.
fn kp_443(keys: &Keys, content: &str) -> nostr::Event {
    EventBuilder::new(Kind::Custom(443), content)
        .sign_with_keys(keys)
        .unwrap()
}

/// Publishes an event to just `relay` via a bare client, so a probe against
/// that relay (and NOT the other) finds it. (Simulates a package present on one
/// own relay but not another.)
async fn seed_event_on(relay: &str, event: &nostr::Event) {
    let client = nostr_sdk::Client::builder().build();
    client.add_relay(relay).await.unwrap();
    client.connect().await;
    client.send_event(event).await.unwrap();
    // Give the relay a moment to persist before a subsequent probe.
    tokio::time::sleep(Duration::from_millis(200)).await;
}

// ---------------------------------------------------------------------------
// Test 20: KP partial drop — live on A, absent on B ⇒ publish to B only.
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn test20_kp_partial_drop_heals_b_only_a_untouched() {
    let _ = haven_core::relay::allow_ws_loopback_for_test();
    let relay_a = MockRelay::run().await.expect("relay a");
    let relay_b = MockRelay::run().await.expect("relay b");
    let url_a = relay_a.url().await.to_string();
    let url_b = relay_b.url().await.to_string();
    let own = vec![url_a.clone(), url_b.clone()];

    let keys = Keys::generate();
    let author = keys.public_key();
    let mgr = RelayManager::new();

    // A live canonical exists on A only (present, live); B has nothing.
    let d = "stable-d-slot";
    let ev_a = kp_30443(&keys, d);
    seed_event_on(&url_a, &ev_a).await;

    // Probe per-relay: A serves a live canonical, B responded-empty.
    let snapshot = kp_snapshot(&mgr, author, &own).await;
    // Both relays responded.
    assert_eq!(snapshot.responders.len(), 2, "both relays should respond");

    // The decision must republish into the SAME slot, targeting B only.
    let decision = decide_kp_maintenance(&snapshot, Some(d));
    let KpMaintenanceDecision::Republish {
        existing_d,
        targets,
    } = decision
    else {
        panic!("expected Republish, got {decision:?}");
    };
    assert_eq!(
        existing_d.as_deref(),
        Some(d),
        "reuse the stable slot (no fork)"
    );
    assert_eq!(targets, vec![url_b.clone()], "heal B only; A untouched");

    // Perform the TARGETED publish into the same `d`.
    let republished = kp_30443(&keys, d);
    let heal_id = republished.id;
    mgr.publish_event(&republished, &targets).await.unwrap();
    tokio::time::sleep(Duration::from_millis(300)).await;

    // Re-probe: B now serves the same-`d` canonical; A's original event id is
    // unchanged (no republish reached A).
    let filter = nostr::Filter::new()
        .kind(Kind::Custom(30443))
        .author(author)
        .limit(64);
    let after = mgr.fetch_events_per_relay(filter, &own).await.unwrap();
    let a = after.iter().find(|o| o.relay_url == url_a).unwrap();
    let b = after.iter().find(|o| o.relay_url == url_b).unwrap();
    assert!(
        a.events.iter().any(|e| e.id == ev_a.id),
        "A must still serve its original canonical, untouched"
    );
    assert!(
        b.events.iter().any(|e| e.id == heal_id && kp_d_tag(e) == d),
        "B must now serve the healed same-`d` canonical"
    );
    // relays_healed == 1 (the FFI would compute targets.len() on success).
    assert_eq!(targets.len(), 1);
}

// ---------------------------------------------------------------------------
// Test 21: relay-list drifted on B only ⇒ list republished to B (full set).
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn test21_relay_list_drift_on_b_heals_b_only_with_full_set() {
    let _ = haven_core::relay::allow_ws_loopback_for_test();
    let relay_a = MockRelay::run().await.expect("relay a");
    let relay_b = MockRelay::run().await.expect("relay b");
    let url_a = relay_a.url().await.to_string();
    let url_b = relay_b.url().await.to_string();
    let configured = vec![url_a.clone(), url_b.clone()];

    let keys = Keys::generate();
    let author = keys.public_key();
    let mgr = RelayManager::new();

    // A serves a CURRENT list (both configured relays); B serves a STALE list
    // (only A) — a drift the merged probe would have hidden.
    let current = haven_core::relay::build_relay_list_event(
        &keys,
        RelayType::Inbox,
        &configured,
        Some(1_000_000),
    )
    .unwrap();
    let stale = haven_core::relay::build_relay_list_event(
        &keys,
        RelayType::Inbox,
        std::slice::from_ref(&url_a),
        Some(1_000_001),
    )
    .unwrap();
    seed_event_on(&url_a, &current).await;
    seed_event_on(&url_b, &stale).await;

    let snapshot = list_snapshot(
        &mgr,
        author,
        RelayType::Inbox,
        &configured,
        &configured,
        true,
    )
    .await;
    assert_eq!(snapshot.responders.len(), 2);

    let decision = decide_relay_list(&snapshot);
    let RelayListDecision::Republish { targets } = decision else {
        panic!("expected Republish, got {decision:?}");
    };
    assert_eq!(
        targets,
        vec![url_b.clone()],
        "heal B only; A already current"
    );

    // Publish the FULL configured set as content, but only to B.
    let heal = haven_core::relay::build_relay_list_event(
        &keys,
        RelayType::Inbox,
        &configured,
        Some(2_000_000),
    )
    .unwrap();
    mgr.publish_event(&heal, &targets).await.unwrap();
    tokio::time::sleep(Duration::from_millis(300)).await;

    // Re-probe B: its newest list now enumerates the full configured set.
    let after = list_snapshot(
        &mgr,
        author,
        RelayType::Inbox,
        std::slice::from_ref(&url_b),
        &configured,
        true,
    )
    .await;
    assert_eq!(after.responders.len(), 1);
    assert!(after.responders[0].healthy, "B must now serve the full set");
    assert_eq!(targets.len(), 1);
}

// ---------------------------------------------------------------------------
// Test 22: one non-responding relay + one healthy ⇒ NoOp, no error.
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn test22_non_responder_plus_healthy_is_noop_not_error() {
    let _ = haven_core::relay::allow_ws_loopback_for_test();
    let relay_a = MockRelay::run().await.expect("relay a");
    let url_a = relay_a.url().await.to_string();
    // A dead loopback port: reachable-refused ⇒ responded == false.
    let url_dead = "ws://127.0.0.1:1".to_string();
    let own = vec![url_a.clone(), url_dead.clone()];

    let keys = Keys::generate();
    let author = keys.public_key();
    let mgr = RelayManager::new();

    // A live canonical on the reachable relay A.
    let d = "slot-healthy";
    let ev_a = kp_30443(&keys, d);
    seed_event_on(&url_a, &ev_a).await;

    let snapshot = kp_snapshot(&mgr, author, &own).await;
    // Only A responded; the dead relay is excluded structurally.
    assert_eq!(
        snapshot.responders.len(),
        1,
        "only the reachable relay is a responder"
    );
    assert_eq!(snapshot.responders[0].relay_url, url_a);

    // Every responder serves live ⇒ NoOp. The non-responder is NOT an error and
    // NOT a heal target (you cannot write to an unreachable relay).
    let decision = decide_kp_maintenance(&snapshot, Some(d));
    assert_eq!(decision, KpMaintenanceDecision::NoOp);
}

// ---------------------------------------------------------------------------
// Test 22b: one MALFORMED relay URL + one LIVE relay ⇒ the live relay is still
// a responder; the malformed one is a non-responder (NOT a whole-probe error).
// This is the headline robustness fix: a single bad entry in the user's stored
// relay set must NOT collapse the per-relay maintenance probe for their good
// relays. Before the fix, `fetch_events_per_relay` validated all URLs up-front
// with `?`, so ONE malformed entry returned a top-level Err and NONE of the
// relays were probed — silently disabling maintenance for every good relay.
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn test22b_malformed_url_plus_live_relay_does_not_collapse_probe() {
    let _ = haven_core::relay::allow_ws_loopback_for_test();
    let relay_a = MockRelay::run().await.expect("relay a");
    let url_a = relay_a.url().await.to_string();
    // A malformed entry the user somehow has stored (typo / corruption): not a
    // parseable ws(s):// URL at all.
    let url_malformed = "not-a-relay-url".to_string();
    // Interleave the bad URL FIRST so a fail-fast `?` would abort before the
    // live relay is ever reached.
    let own = vec![url_malformed.clone(), url_a.clone()];

    let keys = Keys::generate();
    let author = keys.public_key();
    let mgr = RelayManager::new();

    // A live canonical on the reachable relay A.
    let d = "slot-malformed-coexist";
    let ev_a = kp_30443(&keys, d);
    seed_event_on(&url_a, &ev_a).await;

    // The probe must NOT collapse: A responds (serving its canonical), the
    // malformed URL is a non-responder. `kp_snapshot` internally unwraps the
    // per-relay probe — before the fix that unwrap would panic on the top-level
    // Err (zero relays probed).
    let snapshot = kp_snapshot(&mgr, author, &own).await;
    assert_eq!(
        snapshot.responders.len(),
        1,
        "the live relay must still be a responder despite the malformed sibling"
    );
    assert_eq!(
        snapshot.responders[0].relay_url, url_a,
        "the responder must be exactly the live relay"
    );
    // The malformed URL is structurally excluded from responders (fail-closed:
    // never a heal target, never healthy).
    assert!(
        !snapshot
            .responders
            .iter()
            .any(|r| r.relay_url == url_malformed),
        "a malformed url must never appear as a responder / republish target"
    );

    // Every responder serves live ⇒ NoOp. Crucially this is a DECISION over a
    // populated snapshot, not a probe-collapse: maintenance for the good relay
    // is intact.
    let decision = decide_kp_maintenance(&snapshot, Some(d));
    assert_eq!(decision, KpMaintenanceDecision::NoOp);
}

// ---------------------------------------------------------------------------
// Test 23: SeedD → next-tick handoff (integration).
//
// RE-EXPRESSED: with the M8-2 live-material gate deleted, a relay serving a
// 30443 in the tracked slot is healthy REGARDLESS of whether its material is
// live (last-resort KPs never expire). So the handoff after a SeedD is: tick 1
// adopts the on-relay `d`; tick 2 with that `d` stored finds A already serving
// the slot ⇒ NoOp (no wasteful republish). This is the correct DM behavior; the
// pre-migration "dead material ⇒ republish" is exactly the gate that dissolved.
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn test23_seed_d_then_next_tick_is_noop_when_slot_already_served() {
    let _ = haven_core::relay::allow_ws_loopback_for_test();
    let relay_a = MockRelay::run().await.expect("relay a");
    let url_a = relay_a.url().await.to_string();
    let own = vec![url_a.clone()];

    let keys = Keys::generate();
    let author = keys.public_key();
    let mgr = RelayManager::new();

    // An on-relay canonical exists with a well-formed `d`, but we have never
    // tracked its `d` (stored_d = None).
    let seed_d = "on-relay-seed-d";
    let ev = kp_30443(&keys, seed_d);
    seed_event_on(&url_a, &ev).await;

    // Tick 1: no stored `d` ⇒ SeedD (record-only, no publish).
    let snap1 = kp_snapshot(&mgr, author, &own).await;
    assert_eq!(snap1.responders.len(), 1);
    let d1 = decide_kp_maintenance(&snap1, None);
    assert_eq!(
        d1,
        KpMaintenanceDecision::SeedD {
            d: seed_d.to_owned()
        },
        "tick 1 must seed the on-relay `d` (no publish)"
    );

    // Tick 2: the seed is now the stored stable slot and A already serves it ⇒
    // NoOp. No republish (the last-resort package on A is still valid).
    let snap2 = kp_snapshot(&mgr, author, &own).await;
    let d2 = decide_kp_maintenance(&snap2, Some(seed_d));
    assert_eq!(
        d2,
        KpMaintenanceDecision::NoOp,
        "tick 2 must NoOp — A already serves the seeded slot (no material expiry)"
    );
}

// ---------------------------------------------------------------------------
// Test 24: relay_url round-trip — the target byte-matches the configured entry.
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn test24_target_url_byte_matches_configured_entry() {
    let _ = haven_core::relay::allow_ws_loopback_for_test();
    let relay_a = MockRelay::run().await.expect("relay a");
    let relay_b = MockRelay::run().await.expect("relay b");
    let url_a = relay_a.url().await.to_string();
    let url_b = relay_b.url().await.to_string();
    let own = vec![url_a.clone(), url_b.clone()];

    let keys = Keys::generate();
    let author = keys.public_key();
    let mgr = RelayManager::new();

    // Live on A, dropped from B ⇒ the target must be exactly `url_b` as
    // configured (guards a future normalization silently dropping a target).
    let d = "slot-roundtrip";
    let ev_a = kp_30443(&keys, d);
    seed_event_on(&url_a, &ev_a).await;

    let snapshot = kp_snapshot(&mgr, author, &own).await;
    let decision = decide_kp_maintenance(&snapshot, Some(d));
    let KpMaintenanceDecision::Republish { targets, .. } = decision else {
        panic!("expected Republish");
    };
    assert_eq!(targets.len(), 1);
    // BYTE-for-byte equal to the configured own-relay entry.
    assert_eq!(targets[0], url_b);
    assert!(
        own.iter().any(|c| c == &targets[0]),
        "the target must be one of the configured own-relay entries verbatim"
    );

    // And a targeted publish to that exact string must reach the relay (no
    // validation-time rejection of the round-tripped URL).
    let republished = kp_30443(&keys, d);
    mgr.publish_event(&republished, &targets)
        .await
        .expect("targeted publish to the round-tripped URL must succeed");
}

// ---------------------------------------------------------------------------
// Test 24b (RE-EXPRESSED): legacy-443 cutover RETRACTION builder.
//
// DELETED-WITH-SUBJECT: the pre-migration per-republish 443-twin GC — tests 24b
// (`latest_legacy_event_id` + `KEY_PACKAGE_KIND_CANONICAL/_LEGACY` + the old
// 5-field `PublishedKeyPackageRow`), 25 (per-cycle twin scrub), 26 (first-publish
// no-op), 27 (best-effort deletion). Under Dark Matter the KeyPackage kind is
// 30443-only and NIP-33-addressable, so a republish into the same `d`
// SELF-supersedes: there is no per-cycle 443 twin to garbage-collect. The one
// surviving obligation is the ONE-TIME cutover retraction of a stale legacy 443
// (F10a), built by `build_legacy_key_package_retraction`. This test re-expresses
// its load-bearing invariants: a self-authored kind-5 (NIP-09) deletion that
// e-tags exactly the stale 443 id, refuses to author a deletion for another key,
// and never targets the addressable 30443 canonical.
// ---------------------------------------------------------------------------

#[test]
fn legacy_443_retraction_targets_the_stale_443_and_guards_self_authorship() {
    let keys = Keys::generate();
    let author_hex = keys.public_key().to_hex();
    // A real, self-signed stale 443 to retract, and a 30443 canonical that must
    // NEVER be a retraction target (it self-supersedes via NIP-33 same-`d`).
    let stale_443 = kp_443(&keys, "stale-legacy-material");
    let canonical_30443 = kp_30443(&keys, "stable-d");

    // The one-time cutover retraction: a self-authored kind-5 e-tag deletion.
    let retraction =
        build_legacy_key_package_retraction(&keys, &stale_443.id.to_hex(), &author_hex)
            .expect("retraction builds for a self-authored 443");
    assert_eq!(retraction.kind, Kind::EventDeletion);
    assert!(
        retraction.tags.iter().any(|t| {
            let s = t.as_slice();
            s.len() >= 2 && s[0] == "e" && s[1] == stale_443.id.to_hex()
        }),
        "the retraction must e-tag exactly the stale 443 id"
    );
    assert!(
        !retraction.tags.iter().any(|t| {
            let s = t.as_slice();
            s.len() >= 2 && s[1] == canonical_30443.id.to_hex()
        }),
        "the retraction must NEVER reference the addressable 30443 canonical"
    );

    // Self-authorship guard: refuse to author a deletion of another key's event.
    let other = Keys::generate();
    assert!(
        build_legacy_key_package_retraction(
            &keys,
            &stale_443.id.to_hex(),
            &other.public_key().to_hex()
        )
        .is_err(),
        "must refuse to retract an event authored by another key"
    );
}
