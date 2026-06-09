//! Isolated-process integration test for the debug-only `ws://` loopback
//! storage seam.
//!
//! `allow_ws_loopback_for_test` arms a process-global install-once
//! `OnceLock`. Cargo runs each integration-test file as its OWN binary /
//! process, so placing this here guarantees a clean flag and prevents
//! cross-test pollution with the lib unit tests (which assert the
//! flag-unset default posture).
//!
//! It proves that, with the opt-in armed, the REAL add path
//! (`CircleStorage::add_user_relay` -> `normalize_url`) stores a `ws://`
//! loopback / emulator-host relay and round-trips it verbatim — the seam
//! that unblocks hermetic E2E coverage of custom-relay addition — while a
//! non-loopback `ws://` host stays rejected even with the opt-in armed
//! (the host allowlist is AND-ed with the flag, never relaxing `ws://` for
//! arbitrary hosts).
//!
//! The seam reuses the SAME `ALLOW_WS_LOOPBACK_FOR_TEST` flag and
//! `TEST_LOOPBACK_HOSTS` allowlist the relay manager consults at
//! publish/connect time, so storage-add and publish relax `ws://`
//! together. In release builds `ws_loopback_allowed_for_test` is a
//! `const fn` returning `false`, so this entire relaxation is compiled out
//! and `normalize_url` rejects every `ws://` unconditionally.

use std::env;
use std::path::PathBuf;

use haven_core::circle::{CircleStorage, RelayType};

/// Unique unencrypted `circles.db` path for this process.
fn unique_db_path() -> PathBuf {
    let dir = env::temp_dir().join(format!("haven_ws_loopback_seam_{}", std::process::id()));
    std::fs::create_dir_all(&dir).expect("temp dir");
    dir.join("circles.db")
}

#[test]
fn add_user_relay_honors_ws_loopback_optin_and_keeps_host_gate() {
    // Arm the debug-only opt-in once for this fresh process.
    haven_core::relay::allow_ws_loopback_for_test()
        .expect("opt-in must install cleanly in a fresh test process");

    let db_path = unique_db_path();
    let storage = CircleStorage::new(&db_path, None).expect("storage must initialize");

    // A loopback / emulator-host ws:// relay is accepted and stored verbatim
    // through the real add path. This is the exact relay form the hermetic
    // E2E lane points the second strfry at (`ws://10.0.2.2:7778`).
    let emulator_loopback = "ws://10.0.2.2:7778";
    storage
        .add_user_relay(emulator_loopback, RelayType::KeyPackage)
        .expect("armed opt-in must accept a ws:// loopback relay via add_user_relay");
    let kp = storage
        .list_user_relays(RelayType::KeyPackage)
        .expect("list_user_relays must succeed");
    assert!(
        kp.iter().any(|u| u == emulator_loopback),
        "stored KeyPackage relays {kp:?} must contain the ws:// loopback relay verbatim"
    );

    // `localhost` is also an accepted loopback alias (host-only check is
    // port-agnostic, matching the relay manager's validator).
    storage
        .add_user_relay("ws://localhost:7778", RelayType::Inbox)
        .expect("armed opt-in must accept a ws://localhost loopback relay");
    let inbox = storage
        .list_user_relays(RelayType::Inbox)
        .expect("list_user_relays must succeed");
    assert!(inbox.iter().any(|u| u == "ws://localhost:7778"));

    // A NON-loopback ws:// host stays rejected EVEN with the opt-in armed:
    // the host allowlist is AND-ed with the flag, so the seam never relaxes
    // ws:// for arbitrary hosts. A misconfigured
    // `--dart-define=HAVEN_E2E_RELAY=ws://evil.example` cannot be stored.
    for bad in [
        "ws://relay.damus.io",
        "ws://192.168.1.10:7777",
        "ws://0.0.0.0:7777",
    ] {
        assert!(
            storage.add_user_relay(bad, RelayType::KeyPackage).is_err(),
            "non-loopback ws:// {bad} must be rejected even with the opt-in armed"
        );
    }

    // wss:// continues to work normally — the seam only ever ADDS a narrow
    // loopback exception, never restricts the secure scheme.
    storage
        .add_user_relay("wss://relay.example.com", RelayType::KeyPackage)
        .expect("wss:// must always be accepted");

    // Credentials are still rejected for loopback ws:// (the seam falls
    // through to the existing `@`-reject in normalize_url).
    assert!(
        storage
            .add_user_relay("ws://user:pass@10.0.2.2:7778", RelayType::KeyPackage)
            .is_err(),
        "ws:// loopback with embedded credentials must still be rejected"
    );
}
