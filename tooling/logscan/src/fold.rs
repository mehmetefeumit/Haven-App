//! `search_fold`, ported verbatim from the app.
//!
//! The fold has exactly ONE owner: `haven_core::directory::fold_for_search`
//! (`haven-core/src/directory/fold.rs:89-124`, reached from Dart through
//! `haven/lib/src/utils/search_fold.dart` and pinned by
//! `haven/test/utils/search_fold_test.dart`). A name that reaches a log after
//! passing through the member directory is folded by THAT function, so the
//! needle this crate searches for has to be the output of the same
//! transformation — which is why this is a port and not a re-design.
//!
//! It is a port rather than a dependency because `haven-core` pulls the whole
//! MLS/Nostr graph, and a scanner that cannot be built without the app's
//! cryptographic stack could not run on a runner that has no Android NDK. The
//! cost is the one every port carries: the two copies can drift. The mitigation
//! is that the port is character-for-character the same algorithm, its tables
//! are the same tables, and `fold_matches_the_app_vectors` asserts the same
//! vectors `haven-core/src/directory/fold.rs`'s own tests assert — so a drift
//! in either direction shows up as a failing vector here.
//!
//! Ported from:
//! * `haven-core/src/directory/fold.rs:30-124` (the mark table, the
//!   transliteration table, `fold_for_search`)
//! * `haven-core/src/directory/invisible.rs:50-95` (`is_invisible`)

use unicode_normalization::char::is_combining_mark;
use unicode_normalization::UnicodeNormalization;

/// Combining marks that are DECORATION — optional pointing nobody types when
/// they type a name — sorted ascending, as inclusive `(first, last)` ranges.
///
/// Verbatim from `haven-core/src/directory/fold.rs:30-45`. Dropping ALL
/// combining marks instead merged `कमला` with `कमल` and `ガンダム` with
/// `ガンタム`, so the table is a carve-out list rather than a category test.
const DECORATIVE_MARK_RANGES: &[(char, char)] = &[
    ('\u{0300}', '\u{036F}'),
    ('\u{0483}', '\u{0489}'),
    ('\u{0591}', '\u{05C7}'),
    ('\u{0610}', '\u{061A}'),
    ('\u{064B}', '\u{065F}'),
    ('\u{0670}', '\u{0670}'),
    ('\u{06D6}', '\u{06ED}'),
    ('\u{0897}', '\u{08FF}'),
    ('\u{1AB0}', '\u{1AFF}'),
    ('\u{1DC0}', '\u{1DFF}'),
    ('\u{20D0}', '\u{20F0}'),
    ('\u{FB1E}', '\u{FB1E}'),
    ('\u{FE20}', '\u{FE2F}'),
    ('\u{10EFC}', '\u{10EFF}'),
];

/// Every `Cf` or `Default_Ignorable_Code_Point` range, sorted ascending, as
/// inclusive `(first, last)` pairs.
///
/// Verbatim from `haven-core/src/directory/invisible.rs:50-80`, enumerated
/// from Unicode 17.0.0. `haven-core`'s own
/// `the_table_is_re_enumerated_when_the_unicode_data_moves` guards the
/// original; this copy is guarded by the shared vectors below.
const INVISIBLE_RANGES: &[(char, char)] = &[
    ('\u{00AD}', '\u{00AD}'),
    ('\u{034F}', '\u{034F}'),
    ('\u{0600}', '\u{0605}'),
    ('\u{061C}', '\u{061C}'),
    ('\u{06DD}', '\u{06DD}'),
    ('\u{070F}', '\u{070F}'),
    ('\u{0890}', '\u{0891}'),
    ('\u{08E2}', '\u{08E2}'),
    ('\u{115F}', '\u{1160}'),
    ('\u{17B4}', '\u{17B5}'),
    ('\u{180B}', '\u{180F}'),
    ('\u{200B}', '\u{200F}'),
    ('\u{202A}', '\u{202E}'),
    ('\u{2060}', '\u{206F}'),
    ('\u{3164}', '\u{3164}'),
    ('\u{FE00}', '\u{FE0F}'),
    ('\u{FEFF}', '\u{FEFF}'),
    ('\u{FFA0}', '\u{FFA0}'),
    ('\u{FFF0}', '\u{FFFB}'),
    ('\u{110BD}', '\u{110BD}'),
    ('\u{110CD}', '\u{110CD}'),
    ('\u{13430}', '\u{1343F}'),
    ('\u{1BCA0}', '\u{1BCA3}'),
    ('\u{1D173}', '\u{1D17A}'),
    ('\u{E0000}', '\u{E0FFF}'),
];

fn is_decorative_mark(ch: char) -> bool {
    is_combining_mark(ch)
        && DECORATIVE_MARK_RANGES
            .iter()
            .any(|(first, last)| (*first..=*last).contains(&ch))
}

fn is_invisible(ch: char) -> bool {
    ch >= '\u{00AD}'
        && INVISIBLE_RANGES
            .iter()
            .any(|(first, last)| (*first..=*last).contains(&ch))
}

/// The ASCII spelling of a letter whose diacritic is part of the GLYPH.
///
/// Verbatim from `haven-core/src/directory/fold.rs:71-85`. Lowercase keys
/// only, and the caller must lowercase first, or the fold is not idempotent.
const fn transliterate(ch: char) -> Option<&'static str> {
    Some(match ch {
        'æ' => "ae",
        'ð' | 'đ' => "d",
        'ħ' => "h",
        'ı' => "i",
        'ł' => "l",
        'ø' => "o",
        'œ' => "oe",
        'ß' => "ss",
        'þ' => "th",
        'ŧ' => "t",
        _ => return None,
    })
}

/// Normalises `input` into the key the member directory matches on.
///
/// Port of `haven_core::directory::fold_for_search`
/// (`haven-core/src/directory/fold.rs:89-124`). Per-CHARACTER lowercasing, not
/// `str::to_lowercase`: the string method applies `Final_Sigma`, which would
/// make the fold non-compositional.
#[must_use]
pub fn search_fold(input: &str) -> String {
    let lowercased: String = input.chars().flat_map(char::to_lowercase).collect();

    let mut folded = String::with_capacity(lowercased.len());
    for ch in lowercased.nfkd() {
        if is_decorative_mark(ch) || ch.is_control() || is_invisible(ch) {
            continue;
        }
        for lowered in ch.to_lowercase() {
            let lowered = if lowered == '\u{03C2}' {
                '\u{03C3}'
            } else {
                lowered
            };
            match transliterate(lowered) {
                Some(expansion) => folded.push_str(expansion),
                None => folded.push(lowered),
            }
        }
    }
    folded
}

#[cfg(test)]
mod tests {
    use super::search_fold;

    /// The vectors `haven-core/src/directory/fold.rs`'s own tests assert.
    ///
    /// Asserting the app's vectors rather than new ones is the whole point: a
    /// drift between the two copies of this algorithm has to show up as a
    /// failure here, and it can only do that if both sides are measured
    /// against the same inputs.
    #[test]
    fn fold_matches_the_app_vectors() {
        for (input, expected) in [
            ("Ärger", "arger"),
            ("ARGER", "arger"),
            ("ärger", "arger"),
            ("İstanbul", "istanbul"),
            ("Çağrı", "cagri"),
            ("ÇAĞRI", "cagri"),
            ("Élodie", "elodie"),
            ("E\u{0301}lodie", "elodie"),
            ("ΣΊΣΥΦΟΣ", "σισυφοσ"),
            ("Σίσυφος", "σισυφοσ"),
            ("ﬁsh", "fish"),
            ("Ⅻ", "xii"),
            ("ＡＢＣ", "abc"),
            ("𝔄lice", "alice"),
            ("Đurđević", "durdevic"),
            ("Bjørn", "bjorn"),
            ("Łukasz", "lukasz"),
        ] {
            assert_eq!(search_fold(input), expected, "fold of {input:?}");
        }
    }

    #[test]
    fn fold_strips_the_joiners_a_display_name_keeps() {
        // `می‌رود` and `میرود` are one key — the property that makes the fold
        // the right needle encoding for a name that reached a log.
        assert_eq!(search_fold("می\u{200C}رود"), search_fold("میرود"));
    }

    #[test]
    fn fold_of_a_prefix_is_a_prefix_of_the_fold() {
        // Compositionality is what lets the prefix ladder in `expand` truncate
        // a folded name and still have the result be a real substring of what
        // a log would hold.
        assert!(search_fold("ΟΔΥΣΣΕΑΣ").starts_with(&search_fold("ΟΔΥΣ")));
    }

    #[test]
    fn fold_is_idempotent() {
        for input in ["Kåre's Café", "Đurđević", "ΣΊΣΥΦΟΣ", "Straße"] {
            let once = search_fold(input);
            assert_eq!(search_fold(&once), once, "fold of fold of {input:?}");
        }
    }
}
