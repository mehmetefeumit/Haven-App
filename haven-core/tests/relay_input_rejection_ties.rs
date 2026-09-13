//! Ties every [`RelayInputRejection`] sentence to the two Dart files that are
//! keyed on it.
//!
//! # Why this exists
//!
//! A relay-edit rejection is the one `CircleError` payload that crosses the FFI
//! rendered (Phase L0 made every other payload absent from `Display`), because
//! each sentence is Haven-authored and value-free. That makes the sentence an
//! INTERFACE: `_mapStorageError` in
//! `haven/lib/src/services/nostr_relay_preferences_service.dart` compares the
//! flattened `Err(String)` against its own copies of these five sentences to
//! choose the message the user reads, and
//! `haven/test/services/nostr_relay_preferences_service_test.dart` feeds the
//! same sentences in to prove each arm fires.
//!
//! Nothing else in CI spans the three files. Reword a sentence on the Rust side
//! alone and every arm goes dead: the Dart test still passes (it supplies its own
//! copy of the old sentence), the Rust tests still pass (they pin the new one),
//! and the user silently gets the generic "Relay update failed." for a mistyped
//! URL — the exact defect this file exists to catch.
//!
//! Read from SOURCE rather than mirrored, and asserted case-insensitively on the
//! whole sentence, because a partial match would also be satisfied by a
//! half-renamed constant.

use haven_core::circle::{CircleError, RelayInputRejection};

/// Reads one repo-relative Dart file, lower-cased for comparison.
fn dart_source(rel_path: &str) -> String {
    let path = format!(
        "{}/../haven/{}",
        env!("CARGO_MANIFEST_DIR"),
        rel_path.trim_start_matches('/')
    );
    std::fs::read_to_string(&path)
        .unwrap_or_else(|e| panic!("failed to read {path}: {e}"))
        .to_lowercase()
}

#[test]
fn every_relay_rejection_sentence_is_present_in_the_dart_router_and_its_test() {
    const ROUTER: &str = "lib/src/services/nostr_relay_preferences_service.dart";
    const ROUTER_TEST: &str = "test/services/nostr_relay_preferences_service_test.dart";

    let router = dart_source(ROUTER);
    let router_test = dart_source(ROUTER_TEST);

    // Anti-vacuity: a read that succeeded on the WRONG file (a rename that left
    // a stub behind, a path reused for something else) would fail below with a
    // misleading message about sentences. Pin what each source is first.
    assert!(
        router.contains("_mapstorageerror"),
        "{ROUTER} no longer contains the prose-keyed router this pin protects"
    );
    assert!(
        router_test.contains("nostrrelaypreferencesservice"),
        "{ROUTER_TEST} is not the relay-preferences service's test any more"
    );

    for rejection in RelayInputRejection::ALL {
        let sentence = rejection.to_string().to_lowercase();
        assert!(
            router.contains(&sentence),
            "{ROUTER} does not carry {}'s sentence ({sentence:?}), so its arm \
             can never fire — the user would see the generic failure instead",
            rejection.code()
        );
        assert!(
            router_test.contains(&sentence),
            "{ROUTER_TEST} does not feed {}'s sentence ({sentence:?}), so the \
             router's arm for it is untested",
            rejection.code()
        );
    }
}

#[test]
fn the_circle_error_wrapper_surfaces_the_rejection_sentence_verbatim() {
    // The FFI flattens `CircleError`, not `RelayInputRejection`, so the
    // wrapper's `Display` is what the Dart comparisons actually see. A prefix or
    // a "Invalid data: " adornment here would break every arm at once.
    for rejection in RelayInputRejection::ALL {
        assert_eq!(
            CircleError::from(rejection).to_string(),
            rejection.to_string(),
            "{}'s sentence is adorned on the way through CircleError",
            rejection.code()
        );
    }
}
