//! Ties constants to the user-facing sentences that state them as facts, and
//! to the derivations those facts ride on.
//!
//! **Most of this file went with the Settings → Privacy page (owner directive,
//! 2026-08-29).** Four pins read `privacy*` strings that no longer exist — the
//! two relay-pool counts, the relay-residency figure and the Blossom host — and
//! were deleted with them; a pin against a string nobody can read asserts
//! nothing. What is kept is everything that still binds:
//!
//!   * `leaveCircleDialogBody` still promises how long a member's phone keeps
//!     the last position it received, and that is still
//!     [`LOCATION_RETENTION_SECS`]. The dialog is a surface the user reads
//!     while acting, so the tie survives the page.
//!   * The relay-residency window's DERIVATION is unchanged and is pinned in
//!     both directions ([`LOCATION_MESSAGE_RETENTION_SECS`] against the no-gap
//!     minimum). Those two pins never read the ARB; they hold the invariant the
//!     sentence used to describe, and they are what `INV-W-445-EXPIRATION-WINDOW`
//!     cites.
//!   * [`bounded_retention_secs`] honouring a shorter declared window is a
//!     BEHAVIOUR pin. It was written as the other half of a copy pin, and it
//!     outlives it: a circle created by another Marmot client declares its own
//!     window, and flooring it would ask relays to hold ciphertext longer than
//!     that circle asked.
//!
//! What is NOT recoverable here: the constants below are no longer stated to
//! the user anywhere, so nothing in CI can catch a drift between a number and
//! a sentence — there is no sentence. `src/profile/relay_pool.rs` and
//! `src/relay/discovery.rs` still pin their own pool sizes exactly, which is
//! now the whole of that guarantee.

use haven_core::location::{LOCATION_MESSAGE_RETENTION_SECS, LOCATION_RETENTION_SECS};
use haven_core::nostr::mls::bounded_retention_secs;

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

#[test]
fn on_device_retention_copy_states_the_purge_window() {
    // `privacyWhatOthersSeeDetailOnDevice` carried the same promise and was
    // deleted with the Privacy page (2026-08-29); the leave dialog is now the
    // only place the user is told this, which is why the pin narrowed rather
    // than went away.
    let window = spelled_days(LOCATION_RETENTION_SECS);
    let key = "leaveCircleDialogBody";
    let claim = format!("stays on their phones for up to {window}");
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

// ---------------------------------------------------------------------------
// The relay-residency window. `LOCATION_MESSAGE_RETENTION_SECS` is stamped into
// every circle as the 0x8005 `message-retention.v1` component and the engine
// derives each kind-445 application message's NIP-40 `expiration` from it, so
// it is at once a sentence the user reads and the parameter the no-gap
// invariant rides on. Four pins, because four things move independently:
//
//   * the sentence, alone      -> relay_expiry_copy_states_the_retention_window
//   * the sentence's BOUND     -> relay_expiry_copy_states_the_window_as_a_ceiling
//   * the constant, upward     -> widening_the_retention_...
//   * the constant, downward   -> narrowing_the_retention_...
//
// The last two also fire when the constant stands still and the publish ceiling
// it is derived from moves under it, which changes the same two promises
// without touching this crate.
// ---------------------------------------------------------------------------

/// WIDENING. The constant against the derivation it must not outgrow.
///
/// Nothing states this window to the user any more (the sentence went with the
/// Privacy page, 2026-08-29), so this pin and its mirror below are the whole of
/// the guarantee: they hold the no-gap invariant itself rather than a sentence
/// about it, and they fire when the constant moves OR when the publish ceiling
/// it is derived from moves under it — which happens in the Flutter crate.
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

/// A CEILING, not a flat figure. [`bounded_retention_secs`] honours a circle's
/// OWN declared window when it is shorter than Haven's, so
/// [`LOCATION_MESSAGE_RETENTION_SECS`] is the largest residency Haven ever asks
/// for and not the one every message carries. That case is neither hypothetical
/// nor the user's to control: a circle created by any other Marmot client
/// declares its own window, and Haven stamps it as declared.
///
/// This began as one half of a copy pin; the copy half is gone (2026-08-29) and
/// the behaviour half is what was worth keeping — a flat-flooring regression
/// would otherwise pass unnoticed now that no sentence contradicts it.
#[test]
fn bounded_retention_honours_a_shorter_declared_window() {
    let declared = LOCATION_MESSAGE_RETENTION_SECS / 2;
    assert_eq!(
        bounded_retention_secs(Some(declared)),
        declared,
        "a circle declaring a SHORTER window must reach the wire as declared \
         (src/nostr/mls/retention.rs). Flooring it would ask relays to hold \
         location ciphertext longer than the circle asked, and would make \
         LOCATION_MESSAGE_RETENTION_SECS the window every application 445 \
         carries rather than the ceiling it is. The sentence that used to state \
         this as a ceiling to the user went with the Privacy page (2026-08-29); \
         the behaviour it described is pinned here on its own."
    );
}
