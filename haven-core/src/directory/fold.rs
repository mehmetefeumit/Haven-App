//! Search normalisation for the member directory.
//!
//! [`fold_for_search`] is applied to BOTH sides of a picker query — the stored
//! name and the string the user is typing — so its defining requirement is not
//! that it be aggressive but that it be **compositional**: the fold of a prefix
//! must be a prefix of the fold. A fold that normalises a whole name one way
//! and its first three letters another returns zero results for a query that
//! obviously matches.

use unicode_normalization::char::is_combining_mark;
use unicode_normalization::UnicodeNormalization;

use super::invisible::is_invisible;

/// Combining marks that are DECORATION — optional pointing nobody types when
/// they type a name — sorted ascending, as inclusive `(first, last)` ranges.
///
/// The fold drops these and KEEPS every other combining mark, because outside
/// the scripts listed here a mark is a letter rather than an accent. Dropping
/// all of them reduced `नेपाल` to `नपल`, merged `कमला` with `कमल` and made
/// `ガンダム` and `ガンタム` one key — a silent false positive in hi, ne and ja,
/// three locales Haven ships, and in exactly the scripts the ZWNJ carve-out
/// exists to protect. A mark this table misses stays in the key, which costs a
/// search miss and never a wrong match.
///
/// The ranges are deliberately coarse: [`is_decorative_mark`] gates on
/// `is_combining_mark` first, so the punctuation and symbols sitting inside the
/// Hebrew and Arabic blocks (U+05BE MAQAF, U+06DE START OF RUB EL HIZB) are
/// never dropped.
const DECORATIVE_MARK_RANGES: &[(char, char)] = &[
    ('\u{0300}', '\u{036F}'), // Combining Diacritical Marks — Latin/Greek/Cyrillic accents
    ('\u{0483}', '\u{0489}'), // Combining Cyrillic titlo / palatalisation
    ('\u{0591}', '\u{05C7}'), // Hebrew niqqud and cantillation
    ('\u{0610}', '\u{061A}'), // Arabic honorific marks
    ('\u{064B}', '\u{065F}'), // Arabic harakat, hamza, maddah
    ('\u{0670}', '\u{0670}'), // ARABIC LETTER SUPERSCRIPT ALEF
    ('\u{06D6}', '\u{06ED}'), // Arabic Quranic annotation
    ('\u{0897}', '\u{08FF}'), // Arabic Extended-A/B annotation
    ('\u{1AB0}', '\u{1AFF}'), // Combining Diacritical Marks Extended
    ('\u{1DC0}', '\u{1DFF}'), // Combining Diacritical Marks Supplement
    ('\u{20D0}', '\u{20F0}'), // Combining Diacritical Marks for Symbols
    ('\u{FB1E}', '\u{FB1E}'), // HEBREW POINT JUDEO-SPANISH VARIKA
    ('\u{FE20}', '\u{FE2F}'), // Combining Half Marks
    ('\u{10EFC}', '\u{10EFF}'), // Arabic Extended-C annotation
];

/// Whether `ch` is a combining mark the fold may drop.
fn is_decorative_mark(ch: char) -> bool {
    is_combining_mark(ch)
        && DECORATIVE_MARK_RANGES
            .iter()
            .any(|(first, last)| (*first..=*last).contains(&ch))
}

/// The ASCII spelling of a letter whose diacritic is part of the GLYPH rather
/// than a combining mark, so NFKD leaves it intact and the mark-drop never sees
/// it.
///
/// Without this `Đurđević` and `durdevic`, `Bjørn` and `bjorn`, `Þórir` and
/// `thorir` are different keys — i.e. Croatian, Serbian, Bosnian, Norwegian,
/// Danish, Polish, Icelandic, Turkish and Vietnamese names are unsearchable in
/// the ASCII spelling their owners routinely give them.
///
/// Only LOWERCASE letters have arms, and the caller must lowercase before
/// asking: `Æ` arriving here folds to `æ` while `æ` folds to `ae`, so the fold
/// would not be idempotent (pinned by
/// `fold_transliterates_the_two_scalars_whose_nfkd_is_an_uppercase_table_key`).
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
/// Case-insensitive, accent-insensitive, invisible-character-insensitive. The
/// result is never rendered — it exists only to be compared — so it strips the
/// ZWNJ/ZWJ joiners that [`super::sanitize_display_name`] must keep, which is
/// what makes `می‌رود` and `میرود` one key.
#[must_use]
pub fn fold_for_search(input: &str) -> String {
    // Per-CHARACTER lowercasing, never `str::to_lowercase`. The string method
    // applies Unicode's `Final_Sigma` context rule, which makes the fold
    // non-compositional: `fold("ΣΙΣΥΦΟΣ")` would end in `ς` while `fold("ΣΙΣ")`
    // — three letters that sit medially in the name — would also end in `ς`, so
    // the name would not contain its own prefix. Dropping the context is only
    // half the repair; the `ς → σ` map below unifies the two forms a user may
    // actually type. Both steps are required, neither suffices alone.
    let lowercased: String = input.chars().flat_map(char::to_lowercase).collect();

    let mut folded = String::with_capacity(lowercased.len());
    for ch in lowercased.nfkd() {
        if is_decorative_mark(ch) || ch.is_control() || is_invisible(ch) {
            continue;
        }
        // The surviving marks keep the output NFKD-normalised, which is what
        // makes the fold idempotent: deleting members of a canonically ordered
        // run leaves it canonically ordered, and no expansion below introduces
        // a non-starter.
        for lowered in ch.to_lowercase() {
            let lowered = if lowered == '\u{03C2}' {
                '\u{03C3}'
            } else {
                lowered
            };
            // NFKD can yield an UPPERCASE letter — `𝔄` decomposes to `A` — so
            // the lowercase pass has to run again after normalising, and it has
            // to run BEFORE the table: `ᴭ` decomposes to `Æ`, which misses the
            // lowercase-keyed table and folds to `æ`, while `æ` folds to `ae`.
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
    use super::*;
    use proptest::prelude::*;

    #[test]
    fn fold_normalises_german_umlauts_across_cases() {
        assert_eq!(fold_for_search("Ärger"), "arger");
        assert_eq!(fold_for_search("ARGER"), "arger");
        assert_eq!(fold_for_search("ärger"), "arger");
    }

    #[test]
    fn fold_unifies_turkish_dotted_and_dotless_i() {
        // `İ` lowercases to `i` + U+0307 COMBINING DOT ABOVE, which the
        // mark-drop then removes; `ı` has no lowercase mapping at all and is
        // reached only by the transliteration table.
        assert_eq!(fold_for_search("İstanbul"), "istanbul");
        assert_eq!(fold_for_search("ISTANBUL"), "istanbul");
        assert_eq!(fold_for_search("Çağrı"), "cagri");
        assert_eq!(fold_for_search("ÇAĞRI"), "cagri");
    }

    #[test]
    fn fold_strips_accents_from_composed_and_decomposed_forms() {
        assert_eq!(fold_for_search("Élodie"), "elodie");
        assert_eq!(fold_for_search("ELODIE"), "elodie");
        assert_eq!(fold_for_search("E\u{0301}lodie"), "elodie");
    }

    #[test]
    fn fold_unifies_the_two_greek_sigma_forms() {
        // U+03C3 in EVERY position, including the last. The plan's own worked
        // example wrote a final sigma here — the assertion below is what keeps
        // this test from quietly pre-authorising the bug it exists to catch.
        let expected = "σισυφοσ";
        assert!(
            !expected.contains('\u{03C2}'),
            "test vector must use U+03C3 throughout"
        );
        assert_eq!(fold_for_search("ΣΊΣΥΦΟΣ"), expected);
        assert_eq!(fold_for_search("Σίσυφος"), expected);
        assert_eq!(fold_for_search("ΣΙΣΥΦΟΣ"), expected);
        assert_eq!(fold_for_search("Γιώργος"), fold_for_search("ΓΙΩΡΓΟΣ"));
    }

    #[test]
    fn fold_of_a_greek_prefix_is_a_prefix_of_the_folded_name() {
        // The whole reason the fold lowercases per CHARACTER. With
        // `str::to_lowercase` the name would end in `ς` and the query's third
        // letter would too, so neither `contains` would hold and a Greek user
        // typing three capitals would get zero results.
        assert!(fold_for_search("ΣΙΣΥΦΟΣ").contains(&fold_for_search("ΣΙΣ")));
        assert!(fold_for_search("ΟΔΥΣΣΕΑΣ").contains(&fold_for_search("ΟΔΥΣ")));
        assert!(fold_for_search("ΟΔΥΣΣΕΑΣ").starts_with(&fold_for_search("ΟΔΥΣ")));
    }

    #[test]
    fn fold_expands_compatibility_forms() {
        assert_eq!(fold_for_search("ﬁsh"), "fish");
        assert_eq!(fold_for_search("Ⅻ"), "xii");
        assert_eq!(fold_for_search("ＡＢＣ"), "abc");
        // NFKD of a mathematical capital yields an ASCII CAPITAL, which is why
        // the pipeline lowercases a second time after normalising.
        assert_eq!(fold_for_search("𝔄lice"), "alice");
    }

    #[test]
    fn fold_transliterates_stroke_and_ligature_letters() {
        assert_eq!(fold_for_search("Đurđević"), "durdevic");
        assert_eq!(fold_for_search("Bjørn"), "bjorn");
        assert_eq!(fold_for_search("Łukasz"), "lukasz");
        assert_eq!(fold_for_search("Þórir"), "thorir");
        assert_eq!(fold_for_search("Nguyễn Đức"), "nguyen duc");
        assert_eq!(fold_for_search("Straße"), "strasse");
        assert_eq!(fold_for_search("Æsa"), "aesa");
        assert_eq!(fold_for_search("Ðóra"), "dora");
        assert_eq!(fold_for_search("Œuvre"), "oeuvre");
        assert_eq!(fold_for_search("Ħamed"), "hamed");
        assert_eq!(fold_for_search("Ŧorvald"), "torvald");
    }

    #[test]
    fn fold_transliterates_uppercase_stroke_letters_via_the_lowercase_table() {
        // The table carries lowercase keys ONLY; every uppercase form has to
        // arrive already lowercased by step 1. If it did not, these would fall
        // through untransliterated.
        for (upper, lower) in [
            ("Đ", "đ"),
            ("Ø", "ø"),
            ("Ł", "ł"),
            ("Ħ", "ħ"),
            ("Æ", "æ"),
            ("Ð", "ð"),
            ("Þ", "þ"),
            ("Œ", "œ"),
            ("Ŧ", "ŧ"),
            ("ẞ", "ß"),
        ] {
            assert_eq!(
                fold_for_search(upper),
                fold_for_search(lower),
                "uppercase {upper} must fold like {lower}"
            );
            assert_ne!(fold_for_search(upper), upper.to_string());
        }
        assert_eq!(fold_for_search("STRASSE"), fold_for_search("Straße"));
    }

    #[test]
    fn fold_transliterates_the_two_scalars_whose_nfkd_is_an_uppercase_table_key() {
        // U+1D2D and U+A7F8 are the ONLY two scalars in Unicode whose NFKD
        // yields an UPPERCASE key of the transliteration table (`Æ` and `Ħ`).
        // Looking the table up before the post-NFKD lowercase pass missed both,
        // so `ᴭ` folded to `æ` while `æ` folds to `ae` — a fold that is not
        // idempotent, and a name spelled with `ᴭ` that neither `Æ` nor `ae`
        // finds.
        assert_eq!(fold_for_search("\u{1D2D}"), "ae");
        assert_eq!(fold_for_search("\u{A7F8}"), "h");
        assert_eq!(fold_for_search("\u{1D2D}"), fold_for_search("Æ"));
        assert_eq!(fold_for_search("\u{A7F8}"), fold_for_search("Ħ"));
    }

    #[test]
    fn fold_keeps_the_devanagari_marks_that_are_letters() {
        // A matra is a LETTER in Devanagari, not decoration. Dropping every
        // combining mark reduced `नेपाल` to `नपल` and made `कमला`/`कमल` and
        // `राम`/`रमा` one key each — a silent false positive in hi and ne, two
        // locales Haven ships.
        assert_eq!(fold_for_search("नेपाल"), "नेपाल");
        assert_ne!(fold_for_search("कमला"), fold_for_search("कमल"));
        assert_ne!(fold_for_search("राम"), fold_for_search("रमा"));
        // The virama is what builds a conjunct; dropping it spells a different
        // word.
        assert_ne!(fold_for_search("क्ष"), fold_for_search("कष"));
    }

    #[test]
    fn fold_keeps_the_kana_voicing_marks_that_change_the_syllable() {
        // NFKD splits every voiced kana into base + U+3099, so a blanket
        // mark-drop merged だ with た and ガンダム with ガンタム.
        assert_ne!(fold_for_search("だいすけ"), fold_for_search("たいすけ"));
        assert_ne!(fold_for_search("ガンダム"), fold_for_search("ガンタム"));
        // Composed and decomposed spellings of the SAME syllable still agree —
        // that is what NFKD is for, and it is unaffected.
        assert_eq!(fold_for_search("だ"), fold_for_search("た\u{3099}"));
    }

    #[test]
    fn fold_still_drops_the_marks_that_are_decoration() {
        // The other half of the trade: where a mark is optional pointing rather
        // than a letter, the fold must still ignore it.
        assert_eq!(fold_for_search("café"), fold_for_search("cafe"));
        assert_eq!(fold_for_search("مُحَمَّد"), fold_for_search("محمد"));
        assert_eq!(fold_for_search("שָׁלוֹם"), fold_for_search("שלום"));
        assert_eq!(fold_for_search("Ἀθηνᾶ"), fold_for_search("ΑΘΗΝΑ"));
        assert_eq!(fold_for_search("Йося"), fold_for_search("иося"));
    }

    #[test]
    fn the_coarse_mark_ranges_never_swallow_the_punctuation_inside_them() {
        // What makes whole-block ranges safe is the `is_combining_mark` gate,
        // not the block boundaries: both of these sit INSIDE a declared range
        // and neither is a mark.
        for not_a_mark in ['\u{05BE}', '\u{06DE}'] {
            assert!(!is_decorative_mark(not_a_mark));
            assert_eq!(
                fold_for_search(&not_a_mark.to_string()),
                not_a_mark.to_string(),
                "U+{:04X} is inside a declared range but is not a mark",
                not_a_mark as u32
            );
        }
    }

    #[test]
    fn the_decorative_mark_table_is_sorted_and_non_overlapping() {
        // An inverted `(b, a)` row silently drops nothing, and a duplicate row
        // hides that one of the two was meant to be somewhere else. Neither is
        // visible by reading a hand-written table.
        let mut previous: Option<char> = None;
        for (first, last) in DECORATIVE_MARK_RANGES {
            assert!(first <= last, "range {first:?}..{last:?} is inverted");
            if let Some(prev) = previous {
                assert!(prev < *first, "range starting {first:?} is out of order");
            }
            previous = Some(*last);
        }
    }

    #[test]
    fn fold_leaves_cjk_and_arabic_unchanged() {
        assert_eq!(fold_for_search("田中太郎"), "田中太郎");
        assert_eq!(fold_for_search("محمد علي"), "محمد علي");
    }

    #[test]
    fn fold_unifies_persian_spellings_that_differ_only_by_zwnj() {
        // The fold is never rendered, so unlike the display sanitizer it drops
        // ZWNJ — which is exactly what makes the two spellings of one word
        // match.
        let with_zwnj = "می\u{200C}رود";
        let without = "میرود";
        assert!(with_zwnj.contains('\u{200C}'));
        assert_eq!(fold_for_search(with_zwnj), fold_for_search(without));
        assert!(!fold_for_search(with_zwnj).contains('\u{200C}'));
    }

    #[test]
    fn fold_strips_bidi_and_zero_width_format_characters() {
        let attacked = "Ali\u{202E}ce\u{2066}\u{2069}\u{200B}\u{FEFF}\u{00AD}\u{2060}";
        assert_eq!(fold_for_search(attacked), "alice");
    }

    #[test]
    fn fold_strips_the_invisible_letters_that_are_not_format_characters() {
        // The padding attack splits the fold too, and a `Cf`-only rule cannot
        // see it: U+3164 is `Lo` and NFKD-decomposes to U+1160, also `Lo`, so
        // the padded name kept an invisible letter in its key and a search for
        // `alice` missed it outright.
        for invisible in ['\u{3164}', '\u{115F}', '\u{1160}', '\u{FFA0}', '\u{034F}'] {
            assert_eq!(
                fold_for_search(&format!("Al{invisible}ice")),
                "alice",
                "U+{:04X} must not survive into the key",
                invisible as u32
            );
        }
    }

    #[test]
    fn fold_strips_control_characters_including_nul() {
        assert_eq!(fold_for_search("Ali\u{0000}ce\n\r\t"), "alice");
        assert!(!fold_for_search("\u{0000}").contains('\u{0000}'));
    }

    #[test]
    fn fold_of_empty_and_invisible_only_input_is_empty() {
        assert_eq!(fold_for_search(""), "");
        assert_eq!(fold_for_search("\u{200B}\u{202E}\u{0000}"), "");
    }

    #[test]
    fn fold_is_a_fixed_point_for_every_scalar_value_in_unicode() {
        // The exhaustive form of the property below. Idempotence is decidable
        // one scalar at a time — the fold has no cross-character context, and
        // every mark it keeps stays canonically ordered — so this sweep is the
        // whole promise rather than a sample of it. The randomised version
        // reaches the two scalars whose NFKD is an uppercase table key about
        // once in 592 runs, which made a real defect look like a flaky test.
        for cp in 0..=0x0010_FFFF_u32 {
            let Some(ch) = char::from_u32(cp) else {
                continue;
            };
            let once = fold_for_search(&ch.to_string());
            assert_eq!(
                fold_for_search(&once),
                once,
                "fold is not idempotent for U+{cp:04X}"
            );
        }
    }

    proptest! {
        /// The fold is idempotent and total: folding folded text changes
        /// nothing, and no input panics. Idempotence is what lets a folded
        /// column be compared against a freshly folded query.
        #[test]
        fn prop_fold_is_idempotent_and_never_panics(
            input in proptest::collection::vec(any::<char>(), 0..24)
                .prop_map(|cs| cs.into_iter().collect::<String>())
        ) {
            let once = fold_for_search(&input);
            prop_assert_eq!(fold_for_search(&once), once);
        }
    }
}
