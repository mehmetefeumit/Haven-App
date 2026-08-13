//! Ties the constants the privacy copy states as facts to the values those
//! facts are read off.
//!
//! Privacy → Relays tells the user "eight for looking up other people's names
//! and photos, and six for looking up the keys needed to invite them"
//! (`privacyRelaysDetailIndexers`), and `privacyRelaysDetailProfileLookups`
//! states the same eight when bounding what a lookup discloses and where a
//! saved profile goes. Those numbers are [`PRODUCTION_PROFILE_RELAYS`] and
//! [`PRODUCTION_DISCOVERY_RELAYS`]. Privacy →
//! Public profile names the photo host verbatim
//! (`privacyPublicProfileDetailKindZero`); that is [`DEFAULT_BLOSSOM_SERVER`].
//! Privacy → What members see and the leave-circle dialog both promise how long
//! a member's phone keeps the last position it received from you
//! (`privacyWhatOthersSeeDetailOnDevice`, `leaveCircleDialogBody`); that is
//! [`LOCATION_RETENTION_SECS`].
//!
//! `src/profile/relay_pool.rs` and `src/relay/discovery.rs` each pin their own
//! constant to an exact size, which catches a resize. These catch the other
//! half: a resize that forgot the copy, and a copy edit that forgot the pool.
//! They live outside those modules because one paragraph states both counts.
//!
//! Only the English template is checked — a translated numeral or host is a
//! translation concern, gated by `scripts/ci/arb_parity_check.dart` and the
//! l10n review.

use haven_core::location::LOCATION_RETENTION_SECS;
use haven_core::profile::{DEFAULT_BLOSSOM_SERVER, PRODUCTION_PROFILE_RELAYS};
use haven_core::relay::PRODUCTION_DISCOVERY_RELAYS;

/// Returns the English (template) string for `key`.
fn english_copy(key: &str) -> String {
    let arb_path = concat!(env!("CARGO_MANIFEST_DIR"), "/../haven/lib/l10n/app_en.arb");
    let arb_source = std::fs::read_to_string(arb_path)
        .unwrap_or_else(|e| panic!("failed to read {arb_path}: {e}"));
    let arb: serde_json::Value =
        serde_json::from_str(&arb_source).expect("app_en.arb must be valid JSON");
    arb[key]
        .as_str()
        .unwrap_or_else(|| panic!("{key} must exist and be a string"))
        .to_string()
}

/// English spelling of a small count. The copy writes these numbers as words,
/// so comparing against a digit would never match anything.
fn spelled(n: usize) -> &'static str {
    const WORDS: [&str; 13] = [
        "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
        "eleven", "twelve",
    ];
    WORDS.get(n).copied().unwrap_or_else(|| {
        panic!("the privacy copy spells counts as words; add the English word for {n}")
    })
}

/// How the copy words a retention window of `secs`: "a day", or "three days".
fn spelled_days(secs: u64) -> String {
    const DAY: u64 = 24 * 60 * 60;
    assert_eq!(
        secs % DAY,
        0,
        "the retention window is no longer a whole number of days, but both strings \
         state it in days — change the window back, or reword the copy and this pin \
         together"
    );
    let days = usize::try_from(secs / DAY).expect("a retention window in days fits a usize");
    if days == 1 {
        "a day".to_string()
    } else {
        format!("{} days", spelled(days))
    }
}

#[test]
fn indexer_paragraph_spells_both_pool_sizes() {
    let copy = english_copy("privacyRelaysDetailIndexers");
    // Each count is matched together with the clause it introduces, never as a
    // bare number: the paragraph also says "two fixed groups", and a number
    // read positionally would still pass if a reword swapped the two clauses
    // and their numbers together — which is exactly the copy going false.
    for (claim, plural) in [
        (
            format!(
                "{} for looking up other people's names and photos",
                spelled(PRODUCTION_PROFILE_RELAYS.len())
            ),
            "profile (src/profile/relay_pool.rs)",
        ),
        (
            format!(
                "{} for looking up the keys needed to invite them",
                spelled(PRODUCTION_DISCOVERY_RELAYS.len())
            ),
            "discovery (src/relay/discovery.rs)",
        ),
    ] {
        assert!(
            copy.contains(&claim),
            "privacyRelaysDetailIndexers no longer says \"{claim}\", but the \
             {plural} pool is that size. Restore the pool size, or update the \
             English copy in haven/lib/l10n/app_en.arb and every locale beside \
             it.\nCopy was: {copy}"
        );
    }
}

#[test]
fn profile_publish_paragraph_spells_the_profile_pool_size() {
    let copy = english_copy("privacyRelaysDetailProfileLookups");
    // Carries the clause around the number, not the bare word: "the eight" is
    // also a prefix of "the eighteen", and the paragraph states a second,
    // unrelated count ("at most two of the eight") that a positional read
    // could pick up instead.
    let claim = format!(
        "the {}, minus any Haven has excluded",
        spelled(PRODUCTION_PROFILE_RELAYS.len())
    );
    assert!(
        copy.contains(&claim),
        "privacyRelaysDetailProfileLookups no longer says \"{claim}\", but the \
         profile pool holds {} (src/profile/relay_pool.rs). Restore the pool \
         size, or update the English copy in haven/lib/l10n/app_en.arb and \
         every locale beside it.\nCopy was: {copy}",
        PRODUCTION_PROFILE_RELAYS.len(),
    );
}

/// The purge window is receiver-side and hard-coded: no relay, no setting and no
/// FFI value carries it, so these two sentences are the only place the user ever
/// learns it — and, until this pin, the only place it was written down twice.
/// Each claim carries the clause around the duration, so a reword that keeps the
/// promise stays honest while an edit to "a couple of days" cannot ship.
#[test]
fn on_device_retention_copy_states_the_purge_window() {
    let window = spelled_days(LOCATION_RETENTION_SECS);
    for (key, claim) in [
        (
            "privacyWhatOthersSeeDetailOnDevice",
            format!("after {window}, and deletes it"),
        ),
        (
            "leaveCircleDialogBody",
            format!("stays on their phones for up to {window}"),
        ),
    ] {
        let copy = english_copy(key);
        assert!(
            copy.contains(&claim),
            "{key} no longer says \"{claim}\", but a receiver purges the last known \
             position after LOCATION_RETENTION_SECS = {LOCATION_RETENTION_SECS}s \
             (src/location/types.rs). Restore the retention window, or update the \
             English copy in haven/lib/l10n/app_en.arb and every locale beside \
             it.\nCopy was: {copy}"
        );
    }
}

#[test]
fn public_profile_paragraph_names_the_blossom_host() {
    let copy = english_copy("privacyPublicProfileDetailKindZero");
    let host = DEFAULT_BLOSSOM_SERVER
        .strip_prefix("https://")
        .expect("DEFAULT_BLOSSOM_SERVER must be an https:// URL");
    assert!(
        copy.contains(host),
        "privacyPublicProfileDetailKindZero no longer names {host} \
         (constant and copy have drifted apart)"
    );
}
