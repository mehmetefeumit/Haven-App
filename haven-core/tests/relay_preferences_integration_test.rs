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
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

use haven_core::circle::{CircleStorage, RelayType, PRODUCTION_DEFAULT_RELAYS};
use haven_core::relay::dedup_relay_targets;
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

fn cleanup(path: &Path) {
    if let Some(parent) = path.parent() {
        let _ = std::fs::remove_dir_all(parent);
    }
}

/// 64-char hex key for `SQLCipher` tests.
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
fn publish_targets_are_exactly_the_user_list() {
    let path = unique_db_path("targets");
    let storage = CircleStorage::new(&path, None).expect("open");
    storage.seed_defaults_if_unseeded().unwrap();
    // Add a non-default custom relay.
    storage
        .add_user_relay("wss://nostr.wine", RelayType::Inbox)
        .unwrap();
    let user = storage.list_user_relays(RelayType::Inbox).unwrap();
    let targets = dedup_relay_targets(&user);
    // Two-plane invariant (I2): targets are EXACTLY the stored user list,
    // verbatim and in order — never a force-union with anything else. The
    // seeded defaults appear only because they are in the user's own list.
    assert_eq!(targets, user);

    // Leak invariant (I1): a user whose list does NOT contain a given default
    // never has it injected. nostr.wine is not a production default.
    let custom_only = dedup_relay_targets(&["wss://nostr.wine".to_string()]);
    assert_eq!(custom_only, vec!["wss://nostr.wine".to_string()]);
    for d in PRODUCTION_DEFAULT_RELAYS {
        assert!(
            !custom_only.iter().any(|u| u.starts_with(d)),
            "default {d} must never be injected into a custom-only target set"
        );
    }
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
// RP-8: dedup_relay_targets dedup property + normalize idempotency
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

    /// Property (RP-8, two-plane): `dedup_relay_targets` returns exactly the
    /// dedup-key-deduplicated user list — every distinct dedup-key survives
    /// once at its first verbatim occurrence, the output has no duplicate
    /// dedup-keys, and NO relay outside the user's own input is ever added
    /// (in particular, no account-seed default is force-unioned in — the
    /// leak invariant I1).
    #[test]
    fn dedup_relay_targets_equals_user_set(
        user in proptest::collection::vec(relay_url_strategy(), 0..12),
    ) {
        let targets = dedup_relay_targets(&user);

        // (1) Structural cardinality: output size equals the number of
        // distinct dedup-keys in the user list — nothing else.
        let mut expected_keys = std::collections::HashSet::new();
        for u in &user {
            expected_keys.insert(dedup_key_oracle(u));
        }
        prop_assert_eq!(
            targets.len(),
            expected_keys.len(),
            "output must contain exactly one entry per distinct user dedup-key"
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

        // (3) Leak invariant (I1): every output entry's dedup-key originates
        // in the user's own list — nothing (no default, no discovery relay)
        // is ever injected.
        for t in &targets {
            prop_assert!(
                expected_keys.contains(&dedup_key_oracle(t)),
                "output relay not present in user input (injected): {}",
                t
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
// RP-9: the CORE RelayType → Kind mapping never acquires NIP-65 (kind 10002)
//
// NOT an app-level claim: Haven publishes 10002 by design for KeyPackage
// discovery, via the FFI's Nip65 route, which bypasses `to_kind()` entirely.
// ============================================================================

/// Pins the CORE `RelayType → Kind` mapping. Read the scope note carefully:
/// this is no longer an app-level "Haven never publishes 10002" claim.
///
/// # Scope (corrected post-Dark-Matter)
///
/// Haven DOES publish kind 10002 — it is the NIP-65 relay list used for
/// `KeyPackage` discovery, and it retired kind 10051 for that purpose (see the
/// protocol table in `CLAUDE.md`). That publish goes through the FFI's
/// `RelayTypeFfi::Nip65` route, which calls
/// [`haven_core::relay::build_nip65_relay_list_event`] directly and never
/// consults `RelayType::to_kind()`.
///
/// So what this test guards is narrower and still worth guarding: the CORE
/// enum's mapping must not silently acquire 10002. The mapping feeds exactly
/// two live builders — `build_relay_list_event` and `build_unpublish_event`
/// — and the only surviving production caller for the `KeyPackage` arm is the
/// legacy-retraction path (`relay/maintenance/key_package.rs`), which
/// publishes an EMPTY kind-10051 to scrub a pre-Dark-Matter list. That is why
/// `RelayType::KeyPackage → 10051` below is correct and must stay: 10051 is
/// the kind being retracted, not a kind Haven advertises. Re-pointing it at
/// 10002 would make the cutover scrub the user's live NIP-65 list instead.
///
/// `RelayType::Profile` maps to `None`: the profile plane is local-only, and a
/// signed relay list naming its relays would hand observers a public pointer
/// joining the identity to that plane.
///
/// The exhaustive `match` makes this fail to COMPILE if a new `RelayType`
/// variant is added without being considered here — forcing a privacy review
/// of any future relay category. It has already fired once, for
/// `RelayType::Profile`.
#[test]
fn no_relay_type_maps_to_nip65_kind_10002() {
    const NIP65_KIND: u16 = 10002;
    assert_eq!(
        Kind::RelayList.as_u16(),
        NIP65_KIND,
        "sanity: NIP-65 is 10002"
    );

    let all_variants = [RelayType::Inbox, RelayType::KeyPackage, RelayType::Profile];
    for variant in all_variants {
        // Exhaustiveness guard: adding a variant breaks compilation here.
        match variant {
            RelayType::Inbox | RelayType::KeyPackage | RelayType::Profile => {}
        }
        // A category with no wire kind advertises nothing at all, which
        // satisfies "never 10002" more strongly than any other kind could.
        if let Some(kind) = variant.to_kind() {
            assert_ne!(
                kind.as_u16(),
                NIP65_KIND,
                "{variant:?} must not advertise NIP-65 (kind 10002)"
            );
        }
    }

    // Pin the expected mapping so a silent re-point to 10002 also fails.
    assert_eq!(RelayType::Inbox.to_kind(), Some(Kind::InboxRelays));
    assert_eq!(
        RelayType::KeyPackage.to_kind(),
        Some(Kind::MlsKeyPackageRelays)
    );
    // The profile plane is structurally unpublishable: there is no `Kind` to
    // hand an `EventBuilder`, so no present or future caller can advertise it
    // by forgetting a policy check. Giving it ANY kind — 10002 or otherwise —
    // would hand observers a signed, public pointer from this identity to the
    // relays carrying its kind-0 traffic, which is precisely the cross-plane
    // join the profile/location separation exists to break.
    assert!(
        RelayType::Profile.to_kind().is_none(),
        "RelayType::Profile must have NO wire kind — profile relays are local-only policy",
    );
}
