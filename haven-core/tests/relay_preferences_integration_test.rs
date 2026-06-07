//! Integration tests for user-configurable relay preferences.
//!
//! Verifies the full storage surface end-to-end against a real (encrypted
//! and unencrypted) `circles.db`, including schema bootstrap, idempotent
//! seeding, normalization, and the publish-target unioning. Unit-test
//! coverage of pure helpers lives in `src/circle/storage_relay_prefs.rs`
//! and `src/relay/publishers.rs`; these tests catch regressions that a
//! pure-helper suite cannot (schema, encryption interaction, sentinel
//! persistence across reopen).

use std::env;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};

use haven_core::circle::{default_relays, CircleStorage, RelayType, PRODUCTION_DEFAULT_RELAYS};
use haven_core::relay::compute_publish_targets;
use nostr::Kind;
use proptest::prelude::*;

// Counter for unique test paths so parallel test runs don't collide.
static TEST_COUNTER: AtomicU64 = AtomicU64::new(0);

fn unique_db_path(prefix: &str) -> PathBuf {
    let id = TEST_COUNTER.fetch_add(1, Ordering::SeqCst);
    let dir = env::temp_dir().join(format!(
        "haven_relay_prefs_integ_{}_{}_{}",
        prefix,
        std::process::id(),
        id
    ));
    std::fs::create_dir_all(&dir).expect("temp dir");
    dir.join("circles.db")
}

fn cleanup(path: &PathBuf) {
    if let Some(parent) = path.parent() {
        let _ = std::fs::remove_dir_all(parent);
    }
}

/// 64-char hex key for SQLCipher tests.
fn test_hex_key() -> String {
    "deadbeefcafebabe1234567890abcdef".repeat(2)
}

#[test]
fn schema_bootstrap_creates_tables() {
    let path = unique_db_path("schema");
    let storage = CircleStorage::new(&path, None).expect("open");
    // Listing both categories must succeed even though no data exists yet.
    let inbox = storage.list_user_relays(RelayType::Inbox).unwrap();
    let kp = storage.list_user_relays(RelayType::KeyPackage).unwrap();
    assert!(inbox.is_empty());
    assert!(kp.is_empty());
    // Toggles default to true even without seeding.
    assert!(storage.get_publish_inbox_relay_list().unwrap());
    assert!(storage.get_publish_kp_relay_list().unwrap());
    cleanup(&path);
}

#[test]
fn seed_then_reopen_remembers_sentinel() {
    let path = unique_db_path("sentinel");
    {
        let storage = CircleStorage::new(&path, None).expect("open");
        let did_seed = storage.seed_defaults_if_unseeded().unwrap();
        assert!(did_seed);
        // User removes a default — leaves two others, allowed.
        storage
            .remove_user_relay(PRODUCTION_DEFAULT_RELAYS[0], RelayType::Inbox)
            .unwrap();
    }
    // Drop and reopen to simulate an app restart.
    {
        let storage = CircleStorage::new(&path, None).expect("reopen");
        // Sentinel persisted — re-seeding is a no-op even though the user
        // legitimately removed a default. This is the regression test for
        // the row-presence-vs-sentinel bug class.
        let did_seed = storage.seed_defaults_if_unseeded().unwrap();
        assert!(!did_seed);
        let inbox = storage.list_user_relays(RelayType::Inbox).unwrap();
        assert_eq!(
            inbox.len(),
            PRODUCTION_DEFAULT_RELAYS.len() - 1,
            "removed default must NOT be re-added by defensive seed"
        );
    }
    cleanup(&path);
}

#[test]
fn full_crud_against_encrypted_db() {
    let path = unique_db_path("encrypted");
    let key = test_hex_key();
    let storage = CircleStorage::new(&path, Some(&key)).expect("encrypted open");
    storage.seed_defaults_if_unseeded().unwrap();

    // Add custom URL — round-trips through SQLCipher.
    storage
        .add_user_relay("wss://my-relay.example.com", RelayType::KeyPackage)
        .unwrap();
    let kp = storage.list_user_relays(RelayType::KeyPackage).unwrap();
    assert!(kp.iter().any(|u| u.contains("my-relay.example.com")));

    // Remove a default (still leaves at least one).
    storage
        .remove_user_relay(PRODUCTION_DEFAULT_RELAYS[0], RelayType::KeyPackage)
        .unwrap();

    // Restore is non-destructive — defaults come back, custom stays.
    storage.restore_defaults_for(RelayType::KeyPackage).unwrap();
    let after_restore = storage.list_user_relays(RelayType::KeyPackage).unwrap();
    assert!(after_restore
        .iter()
        .any(|u| u.contains("my-relay.example.com")));
    for d in PRODUCTION_DEFAULT_RELAYS {
        assert!(after_restore.iter().any(|u| u.starts_with(d)));
    }

    cleanup(&path);
}

#[test]
fn publish_targets_dedupe_with_defaults() {
    let path = unique_db_path("targets");
    let storage = CircleStorage::new(&path, None).expect("open");
    storage.seed_defaults_if_unseeded().unwrap();
    // Add a non-default custom relay.
    storage
        .add_user_relay("wss://nostr.wine", RelayType::Inbox)
        .unwrap();
    let user = storage.list_user_relays(RelayType::Inbox).unwrap();
    let targets = compute_publish_targets(&user);
    // All defaults present and the custom one present, exactly once each.
    for d in PRODUCTION_DEFAULT_RELAYS {
        let count = targets.iter().filter(|u| u.starts_with(d)).count();
        assert_eq!(count, 1, "default {d} must appear exactly once in targets");
    }
    let custom_count = targets.iter().filter(|u| u.contains("nostr.wine")).count();
    assert_eq!(custom_count, 1);
    cleanup(&path);
}

#[test]
fn add_then_remove_to_empty_blocks() {
    let path = unique_db_path("empty_block");
    let storage = CircleStorage::new(&path, None).expect("open");
    storage
        .add_user_relay("wss://only.example.com", RelayType::Inbox)
        .unwrap();
    // Removing the only entry must error.
    let res = storage.remove_user_relay("wss://only.example.com", RelayType::Inbox);
    assert!(res.is_err(), "must refuse to delete the last relay");
    let after = storage.list_user_relays(RelayType::Inbox).unwrap();
    assert_eq!(after.len(), 1, "row must remain after refused delete");
    cleanup(&path);
}

#[test]
fn ws_scheme_rejected_at_storage_boundary() {
    let path = unique_db_path("ws_reject");
    let storage = CircleStorage::new(&path, None).expect("open");
    // Plaintext ws:// must never reach storage.
    let res = storage.add_user_relay("ws://insecure.example.com", RelayType::Inbox);
    assert!(res.is_err());
    cleanup(&path);
}

#[test]
fn credentials_in_url_rejected() {
    let path = unique_db_path("creds_reject");
    let storage = CircleStorage::new(&path, None).expect("open");
    let res = storage.add_user_relay("wss://user:pass@relay.example.com", RelayType::KeyPackage);
    assert!(
        res.is_err(),
        "URLs with embedded credentials must be rejected"
    );
    cleanup(&path);
}

#[test]
fn url_normalization_collides_on_unique() {
    let path = unique_db_path("normalize");
    let storage = CircleStorage::new(&path, None).expect("open");
    // Add with mixed case + trailing slash.
    storage
        .add_user_relay("WSS://Relay.Example.com/", RelayType::Inbox)
        .unwrap();
    // Same URL in canonical form — must collide on UNIQUE (no second row).
    storage
        .add_user_relay("wss://relay.example.com", RelayType::Inbox)
        .unwrap();
    let inbox = storage.list_user_relays(RelayType::Inbox).unwrap();
    let count = inbox
        .iter()
        .filter(|u| u.contains("relay.example.com"))
        .count();
    assert_eq!(count, 1);
    cleanup(&path);
}

#[test]
fn toggles_persist_across_reopen() {
    let path = unique_db_path("toggles");
    {
        let storage = CircleStorage::new(&path, None).expect("open");
        storage.set_publish_kp_relay_list(false).unwrap();
        storage.set_publish_inbox_relay_list(false).unwrap();
    }
    {
        let storage = CircleStorage::new(&path, None).expect("reopen");
        assert!(!storage.get_publish_kp_relay_list().unwrap());
        assert!(!storage.get_publish_inbox_relay_list().unwrap());
    }
    cleanup(&path);
}

// ============================================================================
// RP-8: compute_publish_targets dedup/union property + normalize idempotency
// ============================================================================

/// Independent oracle for the documented dedup contract: scheme + host are
/// compared case-insensitively, while the path/query/fragment are preserved
/// verbatim (so `wss://h/` and `wss://h` are distinct, but `WSS://H` and
/// `wss://h` are the same). Written from the spec in `publishers.rs`, NOT
/// copied from the private `dedup_key`, so a divergence between code and
/// contract is detectable.
fn dedup_key_oracle(url: &str) -> String {
    url.find("://").map_or_else(
        || url.to_ascii_lowercase(),
        |scheme_end| {
            let scheme = &url[..scheme_end];
            let after = &url[scheme_end + 3..];
            let host_end = after.find(['/', '?', '#']).unwrap_or(after.len());
            let host = &after[..host_end];
            let rest = &after[host_end..];
            format!(
                "{}://{}{}",
                scheme.to_ascii_lowercase(),
                host.to_ascii_lowercase(),
                rest
            )
        },
    )
}

/// Builds relay-shaped strings from a small host pool so that mixed-case and
/// trailing-slash variants collide on the dedup key, deliberately probing the
/// union/dedup logic at its boundaries.
fn relay_url_strategy() -> impl Strategy<Value = String> {
    let scheme = prop_oneof![Just("wss"), Just("WSS"), Just("Wss")];
    let host = prop_oneof![
        Just("relay.example.com"),
        Just("Relay.Example.com"),
        Just("nostr.wine"),
        Just("relay.damus.io"), // overlaps a production default
        Just("a.example.org"),
    ];
    let suffix = prop_oneof![Just(""), Just("/"), Just("/inbox"), Just("/inbox/")];
    (scheme, host, suffix).prop_map(|(s, h, suf)| format!("{s}://{h}{suf}"))
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(256))]

    /// Property (RP-8): `compute_publish_targets` returns the dedup-key union
    /// of the user list and the defaults — every distinct dedup-key survives
    /// exactly once, all defaults are appended, the output contains no
    /// duplicate dedup-keys, and each surviving user URL is preserved
    /// bit-for-bit at its first occurrence.
    #[test]
    fn compute_publish_targets_is_dedup_union(
        user in proptest::collection::vec(relay_url_strategy(), 0..12),
    ) {
        let targets = compute_publish_targets(&user);
        let defaults = default_relays();

        // (1) Structural cardinality: output size equals the number of
        // distinct dedup-keys across user ++ defaults (user takes priority).
        let mut expected_keys = std::collections::HashSet::new();
        for u in user.iter().chain(defaults.iter()) {
            expected_keys.insert(dedup_key_oracle(u));
        }
        prop_assert_eq!(
            targets.len(),
            expected_keys.len(),
            "output must contain exactly one entry per distinct dedup-key"
        );

        // (2) No duplicate dedup-keys in the output.
        let mut seen = std::collections::HashSet::new();
        for t in &targets {
            prop_assert!(
                seen.insert(dedup_key_oracle(t)),
                "duplicate dedup-key collision in output: {}",
                t
            );
        }

        // (3) Every default is present (matched by dedup-key, oracle-independent
        // host comparison would also work but dedup-key is the contract unit).
        for d in &defaults {
            prop_assert!(
                targets.iter().any(|t| dedup_key_oracle(t) == dedup_key_oracle(d)),
                "default relay missing from publish targets: {}",
                d
            );
        }

        // (4) First occurrence of each user URL is preserved verbatim — the
        // function dedups on a canonical key but emits the user's exact string.
        let mut first_seen: std::collections::HashSet<String> = std::collections::HashSet::new();
        for u in &user {
            let key = dedup_key_oracle(u);
            if first_seen.insert(key) {
                prop_assert!(
                    targets.contains(u),
                    "first occurrence of user URL must survive verbatim: {}",
                    u
                );
            }
        }
    }
}

/// Strategy for arbitrary valid `wss://` URLs that `normalize_url` accepts.
fn normalizable_url_strategy() -> impl Strategy<Value = String> {
    let scheme = prop_oneof![Just("wss"), Just("WSS"), Just("WsS")];
    // Hostnames must remain syntactically valid for `RelayUrl::parse`.
    let host = prop_oneof![
        Just("relay.example.com"),
        Just("Relay.Example.COM"),
        Just("nostr.wine"),
        Just("a.b.example.org"),
    ];
    let port = prop_oneof![Just(""), Just(":7777"), Just(":443")];
    let path = prop_oneof![Just(""), Just("/"), Just("/v1"), Just("/v1/")];
    (scheme, host, port, path).prop_map(|(s, h, p, pa)| format!("{s}://{h}{p}{pa}"))
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(256))]

    /// Property (RP-8): `normalize_url` is idempotent —
    /// `normalize(normalize(x)) == normalize(x)`. Because `normalize_url` is
    /// not exported, idempotency is observed behaviourally through storage:
    /// the canonical form returned by `list_user_relays` (i.e. `normalize(x)`)
    /// must, when re-added, normalize to itself and collide on the UNIQUE
    /// `(url, relay_type)` index — leaving exactly one row. If `normalize`
    /// were non-idempotent, `normalize(normalize(x)) != normalize(x)` would
    /// dodge the constraint and insert a second row, failing this assertion.
    #[test]
    fn normalize_url_is_idempotent_through_storage(
        url in normalizable_url_strategy(),
    ) {
        let path = unique_db_path("normalize_idem");
        let storage = CircleStorage::new(&path, None).expect("open");

        // First insert stores normalize(url).
        storage
            .add_user_relay(&url, RelayType::Inbox)
            .expect("first add must succeed");
        let after_first = storage.list_user_relays(RelayType::Inbox).unwrap();
        prop_assert_eq!(after_first.len(), 1, "first add must yield exactly one row");
        let canonical = after_first[0].clone();

        // Re-adding the already-canonical form must normalize to itself and
        // collide — no second row.
        storage
            .add_user_relay(&canonical, RelayType::Inbox)
            .expect("re-adding canonical form must succeed");
        let after_second = storage.list_user_relays(RelayType::Inbox).unwrap();
        prop_assert_eq!(
            after_second.len(),
            1,
            "normalize(normalize(x)) must equal normalize(x) (no duplicate row)"
        );
        prop_assert_eq!(&after_second[0], &canonical, "canonical form must be stable");

        cleanup(&path);
    }
}

// ============================================================================
// RP-9: no RelayType variant advertises NIP-65 (kind 10002)
// ============================================================================

/// Guards the documented privacy invariant in `relay_prefs.rs:18-21`: Haven
/// never advertises a NIP-65 relay list (kind 10002), which would expand the
/// user's relay-side metadata footprint. Every `RelayType` variant must map
/// to its protocol-specific kind (10050 inbox / 10051 key-package) and never
/// to 10002.
///
/// The exhaustive `match` makes this fail to COMPILE if a new `RelayType`
/// variant is added without being considered here — forcing a privacy review
/// of any future relay category.
#[test]
fn no_relay_type_maps_to_nip65_kind_10002() {
    const NIP65_KIND: u16 = 10002;
    assert_eq!(
        Kind::RelayList.as_u16(),
        NIP65_KIND,
        "sanity: NIP-65 is 10002"
    );

    let all_variants = [RelayType::Inbox, RelayType::KeyPackage];
    for variant in all_variants {
        // Exhaustiveness guard: adding a variant breaks compilation here.
        match variant {
            RelayType::Inbox | RelayType::KeyPackage => {}
        }
        let kind = variant.to_kind();
        assert_ne!(
            kind.as_u16(),
            NIP65_KIND,
            "{variant:?} must not advertise NIP-65 (kind 10002)"
        );
    }

    // Pin the expected mapping so a silent re-point to 10002 also fails.
    assert_eq!(RelayType::Inbox.to_kind(), Kind::InboxRelays);
    assert_eq!(RelayType::KeyPackage.to_kind(), Kind::MlsKeyPackageRelays);
}
