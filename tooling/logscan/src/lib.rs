//! `haven-logscan` — the runtime proof of Haven's log-anonymity rule.
//!
//! # What it is
//!
//! A lane (or a soak tier) mints identities, circles, names and coordinates,
//! **declares** every one of them through the wire proxy's control channel, and
//! captures a logcat, a `log show` export, a drive transcript, a relay log and
//! a handful of diag files. This crate turns that declaration into a verdict:
//!
//! * [`seal`](manifest::seal) expands every declared value into every encoding
//!   the tree can render it in (hex in four dialects, base64 at three
//!   alignments, Rust `{:x?}`, Dart's unpadded `toRadixString(16)`, bech32,
//!   Unicode normalisation forms, the app's own `search_fold`, percent and JSON
//!   escapes, coordinate decimal ladders, geohash prefixes, URL shapes) and
//!   writes a sealed manifest;
//! * [`scan`](scan::scan_sinks) streams every captured sink once, looking for
//!   those terms plus the structural shapes an **undeclared** identifier takes
//!   ([`rules`]), and reports `sink:line` with a class and an encoding — never
//!   a value.
//!
//! # Why the verdict is five-valued
//!
//! "Clean" and "leaking" are not the only answers that matter. A sink that was
//! never written, a manifest that cannot be parsed, a positive control that was
//! not caught and a capture that proves too little are all *different operator
//! failures*, and collapsing them into a pass is how a privacy control becomes
//! decoration. See [`RC_CLEAN`] and friends.
//!
//! # This binary's own output is in scope
//!
//! Security Rule 15 applies to every line this tool prints, too: the report
//! carries counts, classes, encodings, rule ids and `sink:line` only.
//! `--disclose-values` is the single exception, it says so on stderr, and a
//! repo guard keeps it out of every workflow. `logscan_never_prints_a_needle`
//! is the test that holds the line.

pub mod cli;
pub mod expand;
pub mod fold;
pub mod ledger;
pub mod manifest;
pub mod plants;
pub mod policy;
pub mod report;
pub mod rules;
pub mod scan;
pub mod seed;
pub mod selftest;

/// Every named sink was present, regular, readable, above its line floor, the
/// segments and the ledger reconciled, and every positive control was caught.
pub const RC_CLEAN: i32 = 0;

/// A needle term or a non-allowlisted structural hit. The caller's contract is
/// containment: delete the sink before any upload.
pub const RC_LEAK: i32 = 1;

/// The instrument, not the subject, is broken: bad arguments, a mis-shaped
/// manifest, an expired allowlist entry, a dangling proof, a plant that trips a
/// structural rule.
pub const RC_GUARD: i32 = 2;

/// The capture is unusable.
///
/// An absent, irregular, unreadable or empty sink, a manifest problem, a ledger
/// mismatch, a segment-count mismatch, or **any** missed positive control. Fix
/// the capture, not the app.
pub const RC_UNUSABLE: i32 = 3;

/// The capture is fine but proves too little: below a line floor, no manifest,
/// a declaration floor unmet, a needle that was never confirmed planted. Fix
/// the scenario.
pub const RC_META: i32 = 4;

/// Folds two exit codes into the one the caller must act on.
///
/// The order is `1 > 2 > 3 > 4 > 0`.
///
/// A leak anywhere takes the containment branch even if another sink was
/// unusable, because deleting a sink that might hold a needle is cheap and
/// publishing one is not.
#[must_use]
pub fn worse(a: i32, b: i32) -> i32 {
    // A code outside the closed set is itself a guard failure: a caller that
    // cannot name its verdict must never be read as clean.
    const CLOSED: [i32; 5] = [RC_CLEAN, RC_LEAK, RC_GUARD, RC_UNUSABLE, RC_META];
    if !CLOSED.contains(&a) || !CLOSED.contains(&b) {
        return RC_GUARD;
    }
    for rc in [RC_LEAK, RC_GUARD, RC_UNUSABLE, RC_META] {
        if a == rc || b == rc {
            return rc;
        }
    }
    RC_CLEAN
}

#[cfg(test)]
mod tests {
    use super::{worse, RC_CLEAN, RC_GUARD, RC_LEAK, RC_META, RC_UNUSABLE};

    #[test]
    fn aggregation_is_leak_guard_unusable_meta_clean() {
        assert_eq!(worse(RC_CLEAN, RC_META), RC_META);
        assert_eq!(worse(RC_META, RC_UNUSABLE), RC_UNUSABLE);
        assert_eq!(worse(RC_UNUSABLE, RC_GUARD), RC_GUARD);
        assert_eq!(worse(RC_GUARD, RC_LEAK), RC_LEAK);
        // The one that matters: a leak outranks an unusable sink, so a run that
        // could not read one file still deletes the one that held a needle.
        assert_eq!(worse(RC_UNUSABLE, RC_LEAK), RC_LEAK);
        assert_eq!(worse(RC_CLEAN, RC_CLEAN), RC_CLEAN);
    }

    #[test]
    fn an_unknown_code_is_a_guard_failure_not_a_pass() {
        assert_eq!(worse(RC_CLEAN, 7), RC_GUARD);
    }
}
