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
    build_legacy_twin_deletion, decide_kp_maintenance, decide_relay_list, list_relay_healthy,
    KpMaintenanceDecision, RelayKpEntry, RelayKpPerRelay, RelayKpSnapshot, RelayListDecision,
    RelayListPerRelay, RelayListSnapshot,
};
use haven_core::relay::RelayManager;
use nostr::{EventBuilder, Keys, Kind, Tag};
use nostr_relay_builder::MockRelay;

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

/// Builds a per-relay KP snapshot from a live per-relay probe, marking the
/// live-material verdict for whichever event ids are in `live_ids`.
async fn kp_snapshot(
    mgr: &RelayManager,
    author: nostr::PublicKey,
    relays: &[String],
    live_ids: &[nostr::EventId],
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
                hash_ref_matches_local_live: live_ids.contains(&ev.id),
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

/// Fetches all events of a given kind authored by `author` from a single relay.
async fn fetch_by_kind(
    mgr: &RelayManager,
    author: nostr::PublicKey,
    kind: Kind,
    relay: &str,
) -> Vec<nostr::Event> {
    let filter = nostr::Filter::new().kind(kind).author(author).limit(64);
    let per_relay = mgr
        .fetch_events_per_relay(filter, &[relay.to_string()])
        .await
        .unwrap();
    per_relay.into_iter().flat_map(|o| o.events).collect()
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
    let snapshot = kp_snapshot(&mgr, author, &own, &[ev_a.id]).await;
    // Both relays responded.
    assert_eq!(snapshot.responders.len(), 2, "both relays should respond");

    // The decision must republish into the SAME slot, targeting B only.
    let decision = decide_kp_maintenance(&snapshot, false, Some(d));
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

    let snapshot = kp_snapshot(&mgr, author, &own, &[ev_a.id]).await;
    // Only A responded; the dead relay is excluded structurally.
    assert_eq!(
        snapshot.responders.len(),
        1,
        "only the reachable relay is a responder"
    );
    assert_eq!(snapshot.responders[0].relay_url, url_a);

    // Every responder serves live ⇒ NoOp. The non-responder is NOT an error and
    // NOT a heal target (you cannot write to an unreachable relay).
    let decision = decide_kp_maintenance(&snapshot, false, Some(d));
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
    let snapshot = kp_snapshot(&mgr, author, &own, &[ev_a.id]).await;
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
    let decision = decide_kp_maintenance(&snapshot, false, Some(d));
    assert_eq!(decision, KpMaintenanceDecision::NoOp);
}

// ---------------------------------------------------------------------------
// Test 23: SeedD → next-tick handoff (integration).
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn test23_seed_d_then_next_tick_republishes_into_seeded_slot() {
    let _ = haven_core::relay::allow_ws_loopback_for_test();
    let relay_a = MockRelay::run().await.expect("relay a");
    let url_a = relay_a.url().await.to_string();
    let own = vec![url_a.clone()];

    let keys = Keys::generate();
    let author = keys.public_key();
    let mgr = RelayManager::new();

    // An on-relay canonical exists (DEAD: not in live_ids) with a well-formed
    // `d`, but we have never tracked its `d` (stored_d = None).
    let seed_d = "on-relay-seed-d";
    let ev = kp_30443(&keys, seed_d);
    seed_event_on(&url_a, &ev).await;

    // Tick 1: no stored `d` ⇒ SeedD (record-only, no publish).
    let snap1 = kp_snapshot(&mgr, author, &own, &[]).await;
    assert_eq!(snap1.responders.len(), 1);
    let d1 = decide_kp_maintenance(&snap1, false, None);
    assert_eq!(
        d1,
        KpMaintenanceDecision::SeedD {
            d: seed_d.to_owned()
        },
        "tick 1 must seed the on-relay `d` (no publish)"
    );

    // Tick 2: the seed is now the stored stable slot; the relay is still
    // unhealthy (dead), so we republish into the seeded slot, targeting A.
    let snap2 = kp_snapshot(&mgr, author, &own, &[]).await;
    let d2 = decide_kp_maintenance(&snap2, false, Some(seed_d));
    let KpMaintenanceDecision::Republish {
        existing_d,
        targets,
    } = d2
    else {
        panic!("tick 2 must republish, got {d2:?}");
    };
    assert_eq!(existing_d.as_deref(), Some(seed_d));
    assert_eq!(targets, vec![url_a.clone()]);

    // Actually perform the seeded-slot republish over the wire.
    let republished = kp_30443(&keys, seed_d);
    let new_id = republished.id;
    mgr.publish_event(&republished, &targets).await.unwrap();
    tokio::time::sleep(Duration::from_millis(300)).await;

    let filter = nostr::Filter::new()
        .kind(Kind::Custom(30443))
        .author(author)
        .limit(64);
    let after = mgr.fetch_events_per_relay(filter, &own).await.unwrap();
    let a = after.iter().find(|o| o.relay_url == url_a).unwrap();
    assert!(
        a.events
            .iter()
            .any(|e| e.id == new_id && kp_d_tag(e) == seed_d),
        "A must serve the republished same-`d` canonical after the handoff"
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

    let snapshot = kp_snapshot(&mgr, author, &own, &[ev_a.id]).await;
    let decision = decide_kp_maintenance(&snapshot, false, Some(d));
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
// Test 24b: storage→GC composition — the exact Rust wiring the FFI runs. Record
// a canonical + a legacy 443, read the twin id back via `latest_legacy_event_id`
// (NOT the 30443's id), and build a deletion for THAT id. Would fail if the
// getter returned None (skips GC), returned the 30443 (wrongly deletes the
// addressable slot), or the composition rejected the round-tripped id.
// ---------------------------------------------------------------------------

#[test]
fn test24b_storage_getter_feeds_twin_deletion_not_canonical() {
    use haven_core::circle::{
        CircleManager, PublishedKeyPackageRow, KEY_PACKAGE_KIND_CANONICAL, KEY_PACKAGE_KIND_LEGACY,
    };

    let keys = Keys::generate();
    let author_hex = keys.public_key().to_hex();
    // A real, self-signed 443 whose id we will record + then delete.
    let twin = kp_443(&keys, "recorded-twin");
    // A canonical whose id must NEVER be chosen by the legacy getter.
    let canonical = kp_30443(&keys, "stable-d");

    let dir = tempfile::tempdir().expect("tempdir");
    let mgr = CircleManager::new_unencrypted(dir.path()).expect("manager");
    mgr.record_published_key_package(&PublishedKeyPackageRow {
        key_package_hash_ref: vec![1, 2, 3],
        event_id: canonical.id.to_hex(),
        kind: KEY_PACKAGE_KIND_CANONICAL,
        d_tag: Some("stable-d".to_string()),
        created_at: 100,
    })
    .expect("record canonical");
    mgr.record_published_key_package(&PublishedKeyPackageRow {
        key_package_hash_ref: vec![1, 2, 3],
        event_id: twin.id.to_hex(),
        kind: KEY_PACKAGE_KIND_LEGACY,
        d_tag: None,
        created_at: 100,
    })
    .expect("record twin");

    // The FFI reads THIS before republishing/recording the new bundle.
    let old_id = mgr
        .latest_legacy_event_id()
        .expect("query")
        .expect("a prior twin exists");
    assert_eq!(
        old_id,
        twin.id.to_hex(),
        "must be the 443 twin, not the 30443"
    );
    assert_ne!(
        old_id,
        canonical.id.to_hex(),
        "must never be the canonical id"
    );

    // The FFI then builds a self-authored deletion for exactly that id.
    let deletion =
        build_legacy_twin_deletion(&keys, &old_id, &author_hex).expect("deletion builds");
    assert_eq!(deletion.kind, Kind::EventDeletion);
    assert!(
        deletion.tags.iter().any(|t| {
            let s = t.as_slice();
            s.len() >= 2 && s[0] == "e" && s[1] == twin.id.to_hex()
        }),
        "the composed deletion must reference the recorded twin id"
    );
}

// ---------------------------------------------------------------------------
// Test 25: legacy-443 twin GC — on a republish, a self-authored NIP-09 kind-5
// deletion of the SUPERSEDED prior 443 is published to the heal targets, and
// the canonical 30443 is NEVER a deletion target. This mirrors the FFI
// `republish_key_package` GC wiring (read old 443 id → republish new bundle →
// publish a deletion of the old twin), which cannot be tested from haven-core.
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn test25_republish_scrubs_superseded_legacy_443_twin() {
    let _ = haven_core::relay::allow_ws_loopback_for_test();
    let relay_a = MockRelay::run().await.expect("relay a");
    let url_a = relay_a.url().await.to_string();
    let own = vec![url_a.clone()];

    let keys = Keys::generate();
    let author = keys.public_key();
    let mgr = RelayManager::new();

    // A prior republish already put an OLD legacy 443 twin (and a 30443) on the
    // relay; the 30443's material is DEAD (not in live_ids), so this relay is a
    // heal target.
    let old_443 = kp_443(&keys, "cycle-1-material");
    let old_30443 = kp_30443(&keys, "stable-d");
    seed_event_on(&url_a, &old_443).await;
    seed_event_on(&url_a, &old_30443).await;

    // Decision: the relay serves a dead canonical ⇒ Republish into the stable
    // slot, targeting A.
    let snapshot = kp_snapshot(&mgr, author, &own, &[]).await;
    let decision = decide_kp_maintenance(&snapshot, false, Some("stable-d"));
    let KpMaintenanceDecision::Republish { targets, .. } = decision else {
        panic!("expected Republish, got {decision:?}");
    };
    assert_eq!(targets, vec![url_a.clone()]);

    // Mirror the FFI GC wiring: republish the fresh bundle (new 443 gets a NEW
    // id and does NOT replace the old one), then scrub the OLD twin.
    let new_30443 = kp_30443(&keys, "stable-d");
    let new_443 = kp_443(&keys, "cycle-2-material");
    assert_ne!(
        new_443.id, old_443.id,
        "a fresh 443 must get a NEW id (regular, non-replaceable) — hence the twin"
    );
    mgr.publish_event(&new_30443, &targets).await.unwrap();
    mgr.publish_event(&new_443, &targets).await.unwrap();

    // The GC: a self-authored NIP-09 deletion of the OLD 443 id, to the targets.
    let deletion = build_legacy_twin_deletion(&keys, &old_443.id.to_hex(), &author.to_hex())
        .expect("self-authored twin deletion builds");
    // The deletion targets the LEGACY twin, never the addressable canonical.
    assert!(
        deletion.tags.iter().any(|t| {
            let s = t.as_slice();
            s.len() >= 2 && s[0] == "e" && s[1] == old_443.id.to_hex()
        }),
        "deletion must reference the OLD legacy 443 id"
    );
    assert!(
        !deletion.tags.iter().any(|t| {
            let s = t.as_slice();
            s.len() >= 2 && s[1] == old_30443.id.to_hex()
        }),
        "deletion must NEVER reference the canonical 30443 (it self-supersedes)"
    );
    mgr.publish_event(&deletion, &targets).await.unwrap();
    tokio::time::sleep(Duration::from_millis(300)).await;

    // The deletion event itself is on the relay, authored by the user, naming
    // the old twin id. nostr-database (MockRelay's store) DOES honor NIP-09
    // tombstoning, so we assert BOTH the co-operative-relay contract (the
    // deletion was published) AND its effect on relay state below.
    let deletions = fetch_by_kind(&mgr, author, Kind::EventDeletion, &url_a).await;
    assert!(
        deletions.iter().any(|d| {
            d.tags.iter().any(|t| {
                let s = t.as_slice();
                s.len() >= 2 && s[0] == "e" && s[1] == old_443.id.to_hex()
            })
        }),
        "a kind-5 deletion of the superseded 443 twin must be published to the target relay"
    );

    // POST-GC relay state (regression guard for the e-tag-only twin GC): the
    // id-only NIP-09 deletion tombstones EXACTLY the old twin, so the relay now
    // serves the FRESH 443 (a distinct id) and no longer the OLD one. If the GC
    // ever regressed to the invalid `443:<pubkey>:` coordinate form, the store
    // would delete every kind-443 with `created_at <= deletion` — INCLUDING the
    // fresh twin — and the second assertion below would fail.
    let twins_443 = fetch_by_kind(&mgr, author, Kind::Custom(443), &url_a).await;
    assert!(
        !twins_443.iter().any(|e| e.id == old_443.id),
        "the superseded 443 twin must be tombstoned by the id-only deletion"
    );
    assert!(
        twins_443.iter().any(|e| e.id == new_443.id),
        "the freshly-republished 443 twin must SURVIVE the id-only GC"
    );
}

// ---------------------------------------------------------------------------
// Test 26: no prior 443 ⇒ GC is a no-op (nothing to scrub on the first publish).
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn test26_first_publish_no_prior_twin_no_deletion() {
    let _ = haven_core::relay::allow_ws_loopback_for_test();
    let relay_a = MockRelay::run().await.expect("relay a");
    let url_a = relay_a.url().await.to_string();
    let own = vec![url_a.clone()];

    let keys = Keys::generate();
    let author = keys.public_key();
    let mgr = RelayManager::new();

    // First-ever publish: only a dead on-relay canonical, no prior 443 twin.
    let old_30443 = kp_30443(&keys, "stable-d");
    seed_event_on(&url_a, &old_30443).await;

    let snapshot = kp_snapshot(&mgr, author, &own, &[]).await;
    let decision = decide_kp_maintenance(&snapshot, false, Some("stable-d"));
    let KpMaintenanceDecision::Republish { targets, .. } = decision else {
        panic!("expected Republish, got {decision:?}");
    };

    // Mirror the FFI: with NO stored prior 443 id, the GC branch is skipped —
    // nothing is deleted. Publish only the fresh bundle.
    let new_30443 = kp_30443(&keys, "stable-d");
    let new_443 = kp_443(&keys, "first-cycle-material");
    mgr.publish_event(&new_30443, &targets).await.unwrap();
    mgr.publish_event(&new_443, &targets).await.unwrap();
    // (No deletion is built/published because there is no prior 443 id.)
    tokio::time::sleep(Duration::from_millis(300)).await;

    let deletions = fetch_by_kind(&mgr, author, Kind::EventDeletion, &url_a).await;
    assert!(
        deletions.is_empty(),
        "no deletion may be published when there is no prior legacy twin to GC"
    );
}

// ---------------------------------------------------------------------------
// Test 27: best-effort GC — a deletion-publish FAILURE does not fail the
// republish. The deletion targets a dead relay (connection refused); the
// canonical republish to the LIVE relay still succeeds and is observable.
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn test27_deletion_publish_failure_does_not_fail_republish() {
    let _ = haven_core::relay::allow_ws_loopback_for_test();
    let relay_a = MockRelay::run().await.expect("relay a");
    let url_a = relay_a.url().await.to_string();
    let own = vec![url_a.clone()];

    let keys = Keys::generate();
    let author = keys.public_key();
    let mgr = RelayManager::new();

    let old_443 = kp_443(&keys, "stale-twin-material");
    seed_event_on(&url_a, &old_443).await;

    // Republish the fresh canonical to the LIVE relay — this must succeed.
    let new_30443 = kp_30443(&keys, "stable-d");
    let heal_id = new_30443.id;
    mgr.publish_event(&new_30443, &own)
        .await
        .expect("canonical republish to the live relay must succeed");

    // The GC deletion is directed at a DEAD relay (refused): publishing it
    // errors, but — mirroring the FFI's best-effort branch — that error is
    // swallowed (tallied, never propagated) and does not undo the republish.
    let url_dead = "ws://127.0.0.1:1".to_string();
    let deletion = build_legacy_twin_deletion(&keys, &old_443.id.to_hex(), &author.to_hex())
        .expect("deletion builds");
    let del_result = mgr.publish_event(&deletion, &[url_dead]).await;
    // The FFI treats ANY deletion-publish outcome as non-fatal; we assert here
    // that even when it errors, the republish above is untouched.
    let _ = del_result; // best-effort: outcome is irrelevant to the republish

    tokio::time::sleep(Duration::from_millis(300)).await;
    let canon = fetch_by_kind(&mgr, author, Kind::Custom(30443), &url_a).await;
    assert!(
        canon.iter().any(|e| e.id == heal_id),
        "the canonical republish must remain on the live relay regardless of the \
         best-effort deletion's fate"
    );
}
