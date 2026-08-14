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
//! [`LOCATION_RETENTION_SECS`]. The same section promises how long a location
//! ciphertext may sit on a *relay* (`privacyWhatOthersSeeDetailExpiry`); that is
//! [`LOCATION_MESSAGE_RETENTION_SECS`], which is additionally held to the
//! derivation its own doc comment states, because that derivation is what makes
//! the sentence honest in the other direction.
//!
//! `src/profile/relay_pool.rs` and `src/relay/discovery.rs` each pin their own
//! constant to an exact size, which catches a resize. These catch the other
//! half: a resize that forgot the copy, and a copy edit that forgot the pool.
//! They live outside those modules because one paragraph states both counts.
//!
//! Only the English template is checked — a translated numeral or host is a
//! translation concern, gated by `scripts/ci/arb_parity_check.dart` and the
//! l10n review.

use haven_core::location::{LOCATION_MESSAGE_RETENTION_SECS, LOCATION_RETENTION_SECS};
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

/// Returns the number one `haven/lib/src/constants/location.dart` declaration
/// is set to.
///
/// `decl` is the whole declaration up to its digits, so a renamed or reshaped
/// constant panics here instead of quietly matching something else.
fn dart_location_constant(decl: &str) -> u64 {
    let dart_path = concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../haven/lib/src/constants/location.dart"
    );
    let source = std::fs::read_to_string(dart_path)
        .unwrap_or_else(|e| panic!("failed to read {dart_path}: {e}"));
    let digits: String = source
        .lines()
        .find_map(|line| line.strip_prefix(decl))
        .unwrap_or_else(|| {
            panic!(
                "no line of {dart_path} starts with \"{decl}\" — the declaration moved \
                 or changed shape, so this pin is reading nothing"
            )
        })
        .chars()
        .take_while(char::is_ascii_digit)
        .collect();
    digits
        .parse()
        .unwrap_or_else(|e| panic!("\"{decl}\" is not followed by a number: {e}"))
}

/// The shortest relay-side retention that still leaves a non-expired location
/// from every active publisher on the relay at all times: one worst-case
/// inter-publish gap, plus a propagation buffer at each end.
///
/// Both halves are read from Dart rather than mirrored here. The publish
/// ceiling is `nominal cadence * (1 + PUBLISH_INTERVAL_JITTER_FRACTION_BP)` and
/// the nominal exists only on the Dart side, so a widened jitter fraction moves
/// this floor (`scripts/ci/check_publish_jitter_fraction_parity.sh` forces the
/// Dart ceiling to follow the Rust fraction) without touching anything in this
/// crate — which is exactly how the derivation would otherwise stop holding
/// unnoticed.
fn no_gap_minimum_secs() -> u64 {
    let publish_ceiling =
        dart_location_constant("const Duration kLocationPublishMaxInterval = Duration(seconds: ");
    let network_buffer = dart_location_constant("const int kTtlNetworkBufferSeconds = ");
    publish_ceiling + 2 * network_buffer
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

/// How the copy words a relay-residency window of `secs`: "about four minutes".
///
/// The window is deliberately not a whole number of minutes (228 s is 3 min
/// 48 s) — that is what the copy's "about" is doing — so the figure spelled out
/// is the window rounded to the nearest minute.
fn spelled_about_minutes(secs: u64) -> String {
    let minutes =
        usize::try_from((secs + 30) / 60).expect("a retention window in minutes fits a usize");
    assert!(
        minutes >= 2,
        "the retention window no longer rounds to a plural number of minutes, but the \
         copy states it as one — change the window back, or reword the copy and this pin \
         together"
    );
    format!("about {} minutes", spelled(minutes))
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

// ---------------------------------------------------------------------------
// The relay-residency window. `LOCATION_MESSAGE_RETENTION_SECS` is stamped into
// every circle as the 0x8005 `message-retention.v1` component and the engine
// derives each kind-445 application message's NIP-40 `expiration` from it, so
// it is at once a sentence the user reads and the parameter the no-gap
// invariant rides on. Three pins, because three things move independently:
//
//   * the sentence, alone      -> relay_expiry_copy_states_the_retention_window
//   * the constant, upward     -> widening_the_retention_...
//   * the constant, downward   -> narrowing_the_retention_...
//
// The last two also fire when the constant stands still and the publish ceiling
// it is derived from moves under it, which changes the same two promises
// without touching this crate.
// ---------------------------------------------------------------------------

/// Copy ↔ constant, in both directions of drift. This paragraph is the only
/// place the user learns how long a location ciphertext may sit on a relay, and
/// it spells the figure in prose: edit the constant far enough and the sentence
/// describes a window Haven no longer asks for, edit the sentence and it
/// describes one Haven never asked for. The number is carried inside the clause
/// it belongs to, so a reword that keeps the promise stays green.
#[test]
fn relay_expiry_copy_states_the_retention_window() {
    let copy = english_copy("privacyWhatOthersSeeDetailExpiry");
    let claim = format!(
        "drop location messages after {}",
        spelled_about_minutes(LOCATION_MESSAGE_RETENTION_SECS)
    );
    assert!(
        copy.contains(&claim),
        "privacyWhatOthersSeeDetailExpiry no longer says \"{claim}\", but Haven asks \
         relays to drop a location message LOCATION_MESSAGE_RETENTION_SECS = \
         {LOCATION_MESSAGE_RETENTION_SECS}s after it was written \
         (src/location/ttl.rs, stamped into every circle as the 0x8005 \
         message-retention component). Restore the window, or update the English \
         copy in haven/lib/l10n/app_en.arb and every locale beside it.\nCopy was: {copy}"
    );
}

/// WIDENING. Relay-side residency of location ciphertext is the thing this
/// constant exists to minimize, and 228 s is documented as the *smallest* value
/// that still keeps the no-gap invariant, so anything above the derived floor
/// leaves every published location on relays longer than the design commits to.
///
/// This assertion is the only thing that catches that; the copy is NOT a second
/// line of defence. [`spelled_about_minutes`] rounds to the nearest minute, so
/// every window in `[210, 269]` still spells "about four minutes" and
/// `relay_expiry_copy_states_the_retention_window` stays green across an 18 %
/// widening of relay residency. The disclosed figure bounds the sentence, never
/// the residency.
#[test]
fn widening_the_retention_would_outlive_the_disclosed_expiry() {
    let retention = LOCATION_MESSAGE_RETENTION_SECS;
    let no_gap_minimum = no_gap_minimum_secs();
    assert!(
        retention <= no_gap_minimum,
        "LOCATION_MESSAGE_RETENTION_SECS = {retention}s is above {no_gap_minimum}s = \
         kLocationPublishMaxInterval + 2 * kTtlNetworkBufferSeconds \
         (haven/lib/src/constants/location.dart), the derivation src/location/ttl.rs \
         documents. Every location this device publishes would linger on relays past \
         the point it is needed for, which is the residency \
         privacyWhatOthersSeeDetailExpiry discloses and the whole reason this window \
         is short. Either the retention was widened, or the publish ceiling under it \
         shrank."
    );
}

/// NARROWING. The mirror image, and the one that breaks what members see.
///
/// The floor has two parts that fail differently, and the assertion guards the
/// outer one: it is the 168 s worst-case inter-publish gap
/// (`kLocationPublishMaxInterval`) plus a 60 s margin absorbing relay
/// propagation and sender/receiver clock skew. Between 168 s and the floor that
/// margin is being spent, so a publisher whose clock or relay is slow starts
/// losing coverage; only below 168 s does a location expire before its
/// publisher's next one lands regardless of skew. Guarding at the floor keeps
/// the margin intact instead of waiting for the gap the margin exists to
/// prevent.
#[test]
fn narrowing_the_retention_would_strand_a_returning_member() {
    let retention = LOCATION_MESSAGE_RETENTION_SECS;
    let no_gap_minimum = no_gap_minimum_secs();
    assert!(
        retention >= no_gap_minimum,
        "LOCATION_MESSAGE_RETENTION_SECS = {retention}s is below {no_gap_minimum}s = \
         kLocationPublishMaxInterval + 2 * kTtlNetworkBufferSeconds \
         (haven/lib/src/constants/location.dart), which is the worst-case \
         inter-publish gap plus the margin for propagation and clock skew. That \
         margin is now partly spent, so a publisher on a slow relay or a skewed \
         clock can already have nothing unexpired on the relay between two of its \
         updates; below kLocationPublishMaxInterval alone it happens to every \
         publisher regardless of skew. A member coming back from offline — the \
         background catch-up, which can only fetch what the relay still holds — \
         then finds no position at all, while the publisher is still told their \
         position goes out every couple of minutes. Either the retention was \
         narrowed, or the publish ceiling under it grew."
    );
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
