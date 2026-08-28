//! The code points that render as nothing, spelled out by hand.
//!
//! The invisible characters that matter to a name — the bidi overrides, the
//! Persian joiners, the emoji tag letters, the Hangul fillers — are drawn from
//! TWO Unicode properties, and neither one alone is the answer:
//!
//! * general category **`Cf`** covers the bidi controls, whose effect is to
//!   reorder what the eye reads without changing the string;
//! * **`Default_Ignorable_Code_Point`** covers the ones that draw nothing at
//!   all — and several of those are `Lo` **letters** (U+3164 HANGUL FILLER,
//!   U+115F, U+FFA0) or `Mn` marks (U+034F, the variation selectors), so a rule
//!   phrased as "`Cc` or `Cf`" lets `Al<U+3164>ice` through: a name that renders
//!   as `Alice`, compares unequal to it, and would be signed and published.
//!
//! [`is_invisible`] is their union. Nothing already in Haven's graph answers
//! either question: `unicode-normalization` exposes no general categories at
//! all, and `char::is_control` is `Cc` ONLY — it returns `false` for U+202E
//! RIGHT-TO-LEFT OVERRIDE, the character the display sanitizer exists to
//! remove.
//!
//! # Why a table instead of a crate
//!
//! `icu_properties` would answer both questions, and it is already in
//! `Cargo.lock` — but only as a transitive dependency of `url → idna`. Naming a
//! crate that is present by accident makes Haven's build depend on another
//! crate's private choice of IDNA backend, and `icu_properties` carries the
//! whole `icu_provider` data-loading stack behind it. The union is 25
//! contiguous ranges that have not moved since Unicode 16.0.0, so the table
//! costs less than the dependency and is reviewable as a diff.
//!
//! # A missed code point fails in OPPOSITE directions for the two callers
//!
//! * [`super::fold_for_search`] — a missed code point stays in the search key,
//!   so two spellings of one name compare unequal. The cost is a **search
//!   miss**, and the user can retype.
//! * [`super::sanitize_display_name`] — a missed code point reaches the
//!   **screen**, which is the whole attack the sanitizer exists to stop. There
//!   is no safe direction here, only a correct table.
//!
//! That asymmetry is why the table is pinned to a Unicode release and why
//! `the_table_is_re_enumerated_when_the_unicode_data_moves` fails the build the
//! moment the crates that DO ship generated Unicode data move past it.

/// Every `Cf` or `Default_Ignorable_Code_Point` range, sorted ascending, as
/// inclusive `(first, last)` pairs.
///
/// Ranges that are `Cf` and default-ignorable are merged, as are the reserved
/// code points Unicode sets aside as default-ignorable so a future assignment
/// cannot make text reflow (U+2065, U+FFF0..FFF8, and most of plane 14).
const INVISIBLE_RANGES: &[(char, char)] = &[
    ('\u{00AD}', '\u{00AD}'),   // SOFT HYPHEN
    ('\u{034F}', '\u{034F}'),   // COMBINING GRAPHEME JOINER
    ('\u{0600}', '\u{0605}'),   // ARABIC NUMBER SIGN .. ARABIC NUMBER MARK ABOVE
    ('\u{061C}', '\u{061C}'),   // ARABIC LETTER MARK
    ('\u{06DD}', '\u{06DD}'),   // ARABIC END OF AYAH
    ('\u{070F}', '\u{070F}'),   // SYRIAC ABBREVIATION MARK
    ('\u{0890}', '\u{0891}'),   // ARABIC POUND / PIASTRE MARK ABOVE
    ('\u{08E2}', '\u{08E2}'),   // ARABIC DISPUTED END OF AYAH
    ('\u{115F}', '\u{1160}'),   // HANGUL CHOSEONG / JUNGSEONG FILLER
    ('\u{17B4}', '\u{17B5}'),   // KHMER VOWEL INHERENT AQ / AA
    ('\u{180B}', '\u{180F}'),   // MONGOLIAN FREE VARIATION SELECTORS + SEPARATOR
    ('\u{200B}', '\u{200F}'),   // ZERO WIDTH SPACE .. RIGHT-TO-LEFT MARK
    ('\u{202A}', '\u{202E}'),   // LEFT-TO-RIGHT EMBEDDING .. RIGHT-TO-LEFT OVERRIDE
    ('\u{2060}', '\u{206F}'),   // WORD JOINER .. NOMINAL DIGIT SHAPES
    ('\u{3164}', '\u{3164}'),   // HANGUL FILLER
    ('\u{FE00}', '\u{FE0F}'),   // VARIATION SELECTOR-1 .. 16
    ('\u{FEFF}', '\u{FEFF}'),   // ZERO WIDTH NO-BREAK SPACE
    ('\u{FFA0}', '\u{FFA0}'),   // HALFWIDTH HANGUL FILLER
    ('\u{FFF0}', '\u{FFFB}'),   // reserved .. INTERLINEAR ANNOTATION TERMINATOR
    ('\u{110BD}', '\u{110BD}'), // KAITHI NUMBER SIGN
    ('\u{110CD}', '\u{110CD}'), // KAITHI NUMBER SIGN ABOVE
    ('\u{13430}', '\u{1343F}'), // EGYPTIAN HIEROGLYPH FORMAT CONTROLS
    ('\u{1BCA0}', '\u{1BCA3}'), // SHORTHAND FORMAT LETTER OVERLAP .. UP STEP
    ('\u{1D173}', '\u{1D17A}'), // MUSICAL SYMBOL BEGIN BEAM .. END PHRASE
    ('\u{E0000}', '\u{E0FFF}'), // LANGUAGE TAG, TAG SPACE .. CANCEL TAG, VS-17 .. 256
];

/// Whether `ch` is general category `Cf` or `Default_Ignorable_Code_Point`.
pub(super) fn is_invisible(ch: char) -> bool {
    // Every code point in the table is at or above U+00AD, so ASCII —
    // overwhelmingly the common case — costs one comparison.
    ch >= '\u{00AD}'
        && INVISIBLE_RANGES
            .iter()
            .any(|(first, last)| (*first..=*last).contains(&ch))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The Unicode release [`INVISIBLE_RANGES`] was enumerated from.
    ///
    /// Bumping this without re-deriving the table from that release's
    /// `DerivedGeneralCategory.txt` (`Cf`) and `DerivedCoreProperties.txt`
    /// (`Default_Ignorable_Code_Point`) defeats the guard it exists for.
    const TABLE_UNICODE_VERSION: (u64, u64, u64) = (17, 0, 0);

    /// The same 25 ranges, written independently of [`INVISIBLE_RANGES`] as
    /// numeric literals. Editing the table without editing this list is what
    /// the test is for.
    const EXPECTED_RANGES: &[(u32, u32)] = &[
        (0x00AD, 0x00AD),
        (0x034F, 0x034F),
        (0x0600, 0x0605),
        (0x061C, 0x061C),
        (0x06DD, 0x06DD),
        (0x070F, 0x070F),
        (0x0890, 0x0891),
        (0x08E2, 0x08E2),
        (0x115F, 0x1160),
        (0x17B4, 0x17B5),
        (0x180B, 0x180F),
        (0x200B, 0x200F),
        (0x202A, 0x202E),
        (0x2060, 0x206F),
        (0x3164, 0x3164),
        (0xFE00, 0xFE0F),
        (0xFEFF, 0xFEFF),
        (0xFFA0, 0xFFA0),
        (0xFFF0, 0xFFFB),
        (0x1_10BD, 0x1_10BD),
        (0x1_10CD, 0x1_10CD),
        (0x1_3430, 0x1_343F),
        (0x1_BCA0, 0x1_BCA3),
        (0x1_D173, 0x1_D17A),
        (0xE_0000, 0xE_0FFF),
    ];

    #[test]
    fn every_declared_invisible_range_is_classified_end_to_end() {
        for (first, last) in EXPECTED_RANGES {
            for cp in *first..=*last {
                let ch = char::from_u32(cp).expect("declared range holds scalar values");
                assert!(is_invisible(ch), "U+{cp:04X} must be invisible");
            }
        }
    }

    #[test]
    fn the_code_points_bounding_each_range_are_visible() {
        for (first, last) in EXPECTED_RANGES {
            for cp in [first - 1, last + 1] {
                // No declared range starts at 0, ends at the maximum scalar, or
                // borders the surrogate block, so both neighbours exist.
                let ch = char::from_u32(cp).expect("neighbour is a scalar value");
                // Adjacent ranges legitimately touch nothing here — the table
                // is built with at least one visible code point between entries
                // — so a neighbour inside ANY declared range would mean two
                // rows that should have been merged.
                let inside_another = EXPECTED_RANGES
                    .iter()
                    .any(|(lo, hi)| (*lo..=*hi).contains(&cp));
                assert!(
                    inside_another || !is_invisible(ch),
                    "U+{cp:04X} borders a range and must not be invisible"
                );
            }
        }
    }

    #[test]
    fn ascii_and_ordinary_letters_are_visible() {
        for ch in ['a', 'Z', '0', ' ', '\u{0000}', '\u{001F}', 'é', 'م', '田'] {
            assert!(!is_invisible(ch), "{ch:?} must be visible");
        }
    }

    #[test]
    fn the_characters_std_cannot_see_are_covered() {
        // `char::is_control` is Cc only. These are the reason this table
        // exists: every one of them returns `false` from std.
        for ch in ['\u{202E}', '\u{200C}', '\u{200F}', '\u{E0067}'] {
            assert!(!ch.is_control(), "{ch:?} is not Cc — std cannot see it");
            assert!(is_invisible(ch), "{ch:?} must be invisible");
        }
    }

    #[test]
    fn the_invisible_letters_and_marks_that_are_not_format_characters_are_covered() {
        // The half a `Cf`-only table misses. U+3164 and its siblings are `Lo`
        // LETTERS that draw nothing, U+034F and the variation selectors are
        // `Mn` marks that draw nothing — invisible padding an impersonator uses
        // to make two names compare unequal while rendering identically.
        for ch in [
            '\u{3164}',
            '\u{115F}',
            '\u{1160}',
            '\u{FFA0}',
            '\u{034F}',
            '\u{FE00}',
            '\u{FE0F}',
            '\u{17B4}',
            '\u{180B}',
            '\u{E0100}',
        ] {
            assert!(is_invisible(ch), "U+{:04X} must be invisible", ch as u32);
        }
    }

    #[test]
    fn the_table_is_sorted_and_non_overlapping() {
        // Sortedness is not decoration: it is what makes the range list
        // reviewable and what a future binary search would rest on.
        let mut previous: Option<char> = None;
        for (first, last) in INVISIBLE_RANGES {
            assert!(first <= last, "range {first:?}..{last:?} is inverted");
            if let Some(prev) = previous {
                assert!(prev < *first, "range starting {first:?} is out of order");
            }
            previous = Some(*last);
        }
    }

    #[test]
    fn the_table_is_re_enumerated_when_the_unicode_data_moves() {
        // The table is hand-written, so nothing but this test notices when the
        // crates that DO ship generated Unicode data move past the release it
        // was enumerated from. For the display sanitizer a code point this
        // table misses is an invisible character on the screen, so the skew has
        // to be a build failure rather than a note.
        let normalization = unicode_normalization::UNICODE_VERSION;
        let normalization = (
            u64::from(normalization.0),
            u64::from(normalization.1),
            u64::from(normalization.2),
        );
        for (crate_name, version) in [
            ("unicode-normalization", normalization),
            (
                "unicode-segmentation",
                unicode_segmentation::UNICODE_VERSION,
            ),
        ] {
            assert_eq!(
                version, TABLE_UNICODE_VERSION,
                "{crate_name} ships Unicode {version:?} but this table was enumerated from \
                 {TABLE_UNICODE_VERSION:?}. Re-derive Cf from DerivedGeneralCategory.txt and \
                 Default_Ignorable_Code_Point from DerivedCoreProperties.txt for the newer \
                 release, then bump TABLE_UNICODE_VERSION in the same commit."
            );
        }
    }
}
