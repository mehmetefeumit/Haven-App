//! Display-name sanitization.
//!
//! This is the text Haven RENDERS, which is why it is a different function
//! from [`super::fold_for_search`] rather than a mode of it. The fold may
//! delete anything invisible because nobody ever sees its output; a rendered
//! name may not, because several of those invisible characters are load-bearing
//! spelling in languages Haven ships.
//!
//! What it removes is the class whose only effect is to make what the eye reads
//! differ from what the string contains — the bidi embeddings, overrides and
//! isolates — plus the zero-width padding an impersonator would use to make two
//! names compare unequal while rendering identically. That padding is NOT
//! confined to the format characters: U+3164 HANGUL FILLER is a `Lo` letter and
//! U+034F a `Mn` mark, so the strip list is [`super::invisible::is_invisible`],
//! which answers "renders as nothing" rather than "is a format character".

use unicode_segmentation::UnicodeSegmentation;

use super::invisible::is_invisible;

/// Longest rendered display name, in grapheme clusters.
///
/// Clusters, not chars and not bytes: a `char` cap splits a flag emoji between
/// its two regional indicators and a Devanagari syllable from its matra, and a
/// byte cap does not even survive a single accented letter.
pub const DISPLAY_NAME_MAX_GRAPHEMES: usize = 48;

/// Longest single grapheme cluster, in `char`s.
///
/// The cluster cap alone bounds how many clusters render, not how large one
/// gets: `a` followed by 100 000 combining marks is ONE cluster and 200 001
/// bytes, stored verbatim and drawn far outside the row it was given. 32
/// admits everything that has to render whole — the longest RGI emoji sequence
/// is 10 code points, and UAX #15's Stream-Safe Text Format caps a cluster at a
/// starter plus 30 non-starters — while capping the whole name at
/// `DISPLAY_NAME_MAX_GRAPHEMES * DISPLAY_NAME_MAX_CLUSTER_CHARS` chars, since a
/// cluster that does not fit ends the name rather than being skipped.
pub const DISPLAY_NAME_MAX_CLUSTER_CHARS: usize = 32;

/// Normalises a name for display, or returns `None` when nothing renderable
/// remains.
///
/// `None` is a real answer, not an error: callers fall through to the next tier
/// of the name precedence (petname → kind-0 name → npub), so a name made
/// entirely of invisible characters resolves to the npub rather than to a blank
/// row an impersonator controls.
#[must_use]
pub fn sanitize_display_name(name: Option<String>) -> Option<String> {
    let name = name?;

    // One pass does the stripping, the whitespace collapse and both trims: a
    // pending space is only emitted once a character that survives follows it,
    // so a leading run, a trailing run, and a run interrupted by a stripped
    // character all resolve correctly without a second scan.
    let mut collapsed = String::with_capacity(name.len());
    let mut pending_space = false;
    for ch in name.chars() {
        // Whitespace is classified FIRST because `\n`, `\r` and U+0085 are also
        // `Cc`: a name broken across two lines must read "Ada Lovelace", not
        // "AdaLovelace".
        if ch.is_whitespace() {
            pending_space = true;
            continue;
        }
        if is_stripped(ch) {
            continue;
        }
        if pending_space && !collapsed.is_empty() {
            collapsed.push(' ');
        }
        pending_space = false;
        collapsed.push(ch);
    }

    // A cluster that breaks either cap ENDS the name rather than being skipped:
    // truncating a suffix keeps the "no leading space, no double space"
    // invariant the loop above established, which dropping from the middle
    // would not.
    let capped: String = collapsed
        .graphemes(true)
        .take(DISPLAY_NAME_MAX_GRAPHEMES)
        .take_while(|cluster| cluster.chars().count() <= DISPLAY_NAME_MAX_CLUSTER_CHARS)
        .collect();
    // Only the caps can leave a trailing space — the loop above never emits one.
    let capped = capped.trim_end();

    capped
        .chars()
        .any(is_renderable)
        .then(|| capped.to_string())
}

/// Whether `ch` puts ink on the screen.
///
/// The emptiness test has to be this and not `!is_empty()`: [`is_kept`] is
/// PRECISELY the set of characters that are invisible AND kept, so a name built
/// only from those survives every strip above while rendering nothing. The only
/// whitespace that can reach here is the interior single space the collapse
/// emits, and a space between two invisibles is not a name either.
const fn is_renderable(ch: char) -> bool {
    ch != ' ' && !is_kept(ch)
}

/// Whether `ch` must not reach the screen.
fn is_stripped(ch: char) -> bool {
    !is_kept(ch) && (ch.is_control() || is_invisible(ch))
}

/// The invisible characters a rendered name MUST keep.
///
/// Listed explicitly, and checked ahead of [`is_invisible`], because every one
/// of them answers to it: a rule phrased as "strip what renders as nothing"
/// removes all of them and corrupts real names.
const fn is_kept(ch: char) -> bool {
    matches!(
        ch,
        // ZWNJ / ZWJ. Grammatically required in Persian and Urdu (`می‌رود`),
        // needed for Devanagari conjuncts, and the glue in every emoji ZWJ
        // sequence. Haven ships fa, ur, hi and ne.
        '\u{200C}' | '\u{200D}'
        // LRM / RLM / ALM. Unlike the embeddings and overrides, these set the
        // direction of one neutral character — routine around digits in
        // Arabic, Hebrew and Urdu — rather than reordering a run.
        | '\u{200E}' | '\u{200F}' | '\u{061C}'
        // VARIATION SELECTOR-16 — the one of sixteen that has to survive. It
        // selects emoji presentation, so stripping it redraws `❤️` as the
        // monochrome text glyph and breaks every RGI ZWJ sequence built on it.
        // VS1–15 and the ideographic selectors (U+E0100..) are stripped: they
        // change which glyph variant draws, never which character, and they are
        // invisible padding otherwise.
        | '\u{FE0F}'
        // Tag characters, the payload of an emoji subdivision flag. U+E0001
        // LANGUAGE TAG is deliberately NOT in this range: it is deprecated and
        // belongs to no cluster.
        | '\u{E0020}'..='\u{E007F}'
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use proptest::prelude::*;

    /// U+1F1F9 U+1F1F7 — two regional indicators, ONE grapheme cluster.
    const FLAG: &str = "\u{1F1F9}\u{1F1F7}";
    /// Man + woman + girl + boy joined by ZWJ — seven chars, one cluster.
    const FAMILY: &str = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}";
    /// The Scotland subdivision flag: a waving black flag plus a `gbsct` tag
    /// sequence terminated by CANCEL TAG. Every tag character is `Cf`.
    const SCOTLAND: &str = "\u{1F3F4}\u{E0067}\u{E0062}\u{E0073}\u{E0063}\u{E0074}\u{E007F}";

    fn sanitize(name: &str) -> Option<String> {
        sanitize_display_name(Some(name.to_string()))
    }

    #[test]
    fn a_clean_name_passes_through_unchanged() {
        assert_eq!(sanitize("Alice"), Some("Alice".to_string()));
        assert_eq!(sanitize("محمد علي"), Some("محمد علي".to_string()));
        assert_eq!(sanitize("田中太郎"), Some("田中太郎".to_string()));
    }

    #[test]
    fn strips_bidi_embeddings_overrides_and_isolates() {
        // Their effect IS the attack: an override reorders everything after it,
        // so a name can render as a different name entirely.
        for control in [
            '\u{202A}', '\u{202B}', '\u{202C}', '\u{202D}', '\u{202E}', '\u{2066}', '\u{2067}',
            '\u{2068}', '\u{2069}',
        ] {
            let attacked = format!("Ali{control}ce");
            let out = sanitize(&attacked).expect("name survives");
            assert_eq!(out, "Alice", "U+{:04X} must be stripped", control as u32);
            assert!(!out.contains(control));
        }
    }

    #[test]
    fn keeps_the_directional_marks_that_orient_digits() {
        // LRM / RLM / ALM set the direction of ONE neutral character rather
        // than reordering a run; they appear in ordinary Arabic, Hebrew and
        // Urdu text around numbers.
        for mark in ['\u{200E}', '\u{200F}', '\u{061C}'] {
            let name = format!("محمد{mark} 12");
            assert_eq!(sanitize(&name), Some(name.clone()));
        }
    }

    #[test]
    fn keeps_the_joiners_persian_and_urdu_orthography_requires() {
        // `می‌رود` is spelled with a ZWNJ. Stripping it does not "clean" the
        // name, it misspells it.
        let persian = "می\u{200C}رود";
        assert!(persian.contains('\u{200C}'));
        assert_eq!(sanitize(persian), Some(persian.to_string()));

        let joined = "क्\u{200D}ष";
        assert_eq!(sanitize(joined), Some(joined.to_string()));
    }

    #[test]
    fn keeps_an_emoji_tag_sequence_whole() {
        let out = sanitize(SCOTLAND).expect("name survives");
        assert_eq!(out, SCOTLAND);
        assert_eq!(out.chars().count(), SCOTLAND.chars().count());
    }

    #[test]
    fn keeps_an_emoji_zwj_sequence_whole() {
        let out = sanitize(FAMILY).expect("name survives");
        assert_eq!(out, FAMILY);
        assert_eq!(out.chars().count(), 7, "no ZWJ may be dropped");
    }

    #[test]
    fn strips_the_remaining_invisible_format_characters() {
        for invisible in ['\u{200B}', '\u{2060}', '\u{FEFF}', '\u{00AD}', '\u{E0001}'] {
            let name = format!("Ali{invisible}ce");
            assert_eq!(
                sanitize(&name),
                Some("Alice".to_string()),
                "U+{:04X} must be stripped",
                invisible as u32
            );
        }
    }

    #[test]
    fn strips_the_invisible_characters_that_are_not_format_characters() {
        // The padding attack does not need a `Cf`. U+3164 HANGUL FILLER and its
        // siblings are `Lo` LETTERS that draw nothing; U+034F and the variation
        // selectors are `Mn` marks that draw nothing. A strip rule phrased as
        // "Cc or Cf" lets every one of them through, so `Al<U+3164>ice` renders
        // as `Alice`, compares unequal to it, and would be signed and published
        // by Haven into everybody else's client.
        for invisible in [
            '\u{3164}',
            '\u{115F}',
            '\u{1160}',
            '\u{FFA0}',
            '\u{034F}',
            '\u{FE00}',
            '\u{FE0E}',
            '\u{17B4}',
            '\u{180B}',
            '\u{2065}',
            '\u{E0100}',
        ] {
            assert!(
                !invisible.is_control(),
                "std cannot see U+{:04X}",
                invisible as u32
            );
            let padded = format!("Al{invisible}ice");
            assert_ne!(
                padded, "Alice",
                "the two strings must differ before sanitizing"
            );
            assert_eq!(
                sanitize(&padded),
                Some("Alice".to_string()),
                "U+{:04X} must be stripped",
                invisible as u32
            );
        }
    }

    #[test]
    fn keeps_the_emoji_presentation_selector() {
        // U+FE0F is default-ignorable like its fifteen siblings, and is the one
        // that must survive: stripping it re-renders `❤️` as the monochrome text
        // glyph and breaks every RGI ZWJ sequence built on it.
        let heart = "\u{2764}\u{FE0F}";
        assert_eq!(sanitize(heart), Some(heart.to_string()));

        let kiss =
            "\u{1F468}\u{1F3FB}\u{200D}\u{2764}\u{FE0F}\u{200D}\u{1F48B}\u{200D}\u{1F468}\u{1F3FF}";
        assert_eq!(sanitize(kiss), Some(kiss.to_string()));
        assert_eq!(
            kiss.graphemes(true).count(),
            1,
            "one cluster, ten code points"
        );
    }

    #[test]
    fn strips_control_characters() {
        assert_eq!(sanitize("Ali\u{0000}ce"), Some("Alice".to_string()));
        assert_eq!(sanitize("Ali\u{001B}ce"), Some("Alice".to_string()));
    }

    #[test]
    fn collapses_every_whitespace_run_to_a_single_space() {
        // Newlines and NEL are Cc, so this only holds if whitespace is
        // classified BEFORE the control strip — otherwise a two-line name
        // silently becomes one run-together word.
        assert_eq!(
            sanitize("Ali\nce\r\n  Smith\u{00A0}\u{2028}\u{2029}\u{0085}\tJones"),
            Some("Ali ce Smith Jones".to_string())
        );
    }

    #[test]
    fn trims_surrounding_whitespace() {
        assert_eq!(sanitize("  Alice  "), Some("Alice".to_string()));
        assert_eq!(sanitize("\n\tAlice\r\n"), Some("Alice".to_string()));
    }

    #[test]
    fn a_stripped_character_between_spaces_does_not_become_a_second_space() {
        assert_eq!(sanitize("Ali \u{202E} ce"), Some("Ali ce".to_string()));
    }

    #[test]
    fn caps_at_forty_eight_grapheme_clusters() {
        assert_eq!(DISPLAY_NAME_MAX_GRAPHEMES, 48);

        let exactly = "a".repeat(48);
        assert_eq!(sanitize(&exactly), Some(exactly.clone()));

        let over = "a".repeat(49);
        assert_eq!(sanitize(&over), Some(exactly));
    }

    #[test]
    fn the_cap_counts_clusters_not_chars_and_never_splits_one() {
        // 47 plain letters plus a flag is 48 clusters (49 chars) — it fits.
        let fits = format!("{}{FLAG}", "a".repeat(47));
        assert_eq!(fits.chars().count(), 49);
        assert_eq!(sanitize(&fits), Some(fits.clone()));

        // 48 letters plus a flag overflows by one cluster. The flag must go
        // whole: half a flag is a lone regional indicator that renders as a
        // letter tile.
        let overflows = format!("{}{FLAG}", "a".repeat(48));
        let out = sanitize(&overflows).expect("name survives");
        assert_eq!(out, "a".repeat(48));
        assert!(!out.contains('\u{1F1F9}'), "a cluster was split");

        // The same for a ZWJ family: 47 letters + family fits, 48 + family
        // drops the family entirely rather than leaving a headless torso.
        let family_fits = format!("{}{FAMILY}", "a".repeat(47));
        assert_eq!(sanitize(&family_fits), Some(family_fits.clone()));
        let family_overflows = format!("{}{FAMILY}", "a".repeat(48));
        assert_eq!(
            sanitize(&family_overflows),
            Some("a".repeat(48)),
            "a ZWJ sequence was split"
        );
    }

    #[test]
    fn the_cap_leaves_no_trailing_space() {
        let name = format!("{} bcd", "a".repeat(47));
        let out = sanitize(&name).expect("name survives");
        assert_eq!(out, "a".repeat(47));
    }

    #[test]
    fn returns_none_when_nothing_renderable_remains() {
        assert_eq!(sanitize_display_name(None), None);
        assert_eq!(sanitize(""), None);
        assert_eq!(sanitize("   "), None);
        assert_eq!(sanitize("\u{0000}\u{0001}\u{0002}"), None);
        assert_eq!(sanitize("\u{202E}\u{200B}\u{FEFF}"), None);
        assert_eq!(sanitize("\n\r\t "), None);
        assert_eq!(sanitize("\u{3164}\u{115F}\u{FFA0}\u{034F}"), None);
    }

    #[test]
    fn a_name_of_nothing_but_kept_invisible_characters_still_resolves_to_the_npub() {
        // The keep-list is PRECISELY the set of characters that are invisible
        // AND kept, so "the result is non-empty" never meant "the result
        // renders". A hostile kind-0 of `{"display_name":"\u{200E}"}` survived
        // the strip, `String.trim()` on the Dart side does not remove LRM
        // either, and the name precedence rendered a blank row an impersonator
        // controls instead of falling through to the npub.
        for kept in [
            '\u{200C}',
            '\u{200D}',
            '\u{200E}',
            '\u{200F}',
            '\u{061C}',
            '\u{FE0F}',
            '\u{E0041}',
        ] {
            assert!(is_kept(kept), "test vector must be on the keep-list");
            assert_eq!(
                sanitize(&kept.to_string()),
                None,
                "U+{:04X} alone renders nothing",
                kept as u32
            );
        }
        // A tag sequence stripped of its base flag is six kept characters and
        // no glyph.
        assert_eq!(
            sanitize("\u{E0067}\u{E0062}\u{E0073}\u{E0063}\u{E0074}\u{E007F}"),
            None
        );
        // An interior space is not ink either: the collapse can put one between
        // two kept characters, and a blank row is still a blank row.
        assert_eq!(sanitize("\u{200E} \u{200D}"), None);
        // Mixed with anything renderable, the same characters must survive.
        assert_eq!(sanitize("a\u{200E}"), Some("a\u{200E}".to_string()));
    }

    #[test]
    fn one_cluster_cannot_grow_past_the_char_ceiling() {
        // The cluster cap bounds how many clusters render, not how big one
        // gets: `a` + 100 000 combining marks is ONE cluster and 200 001 bytes,
        // it is stored verbatim in `profiles.metadata_json`, and it draws far
        // outside the row it was given — the same "what the eye reads differs
        // from what the string contains" class the strip list closes.
        let marks = format!("a{}", "\u{0301}".repeat(100_000));
        assert_eq!(
            marks.graphemes(true).count(),
            1,
            "the cluster cap sees ONE cluster"
        );
        assert_eq!(sanitize(&marks), None);
        assert_eq!(
            sanitize(&format!("Alice {marks}")),
            Some("Alice".to_string())
        );

        // Tag characters are `Extend` too, so the same bomb is buildable out of
        // characters the keep-list must not strip.
        let tags = format!("A{}", "\u{E0041}".repeat(100_000));
        assert_eq!(tags.graphemes(true).count(), 1);
        assert_eq!(sanitize(&tags), None);
    }

    #[test]
    fn the_char_ceiling_admits_a_stream_safe_cluster_and_stops_one_past_it() {
        assert_eq!(DISPLAY_NAME_MAX_CLUSTER_CHARS, 32);

        let at_limit = format!("a{}", "\u{0301}".repeat(DISPLAY_NAME_MAX_CLUSTER_CHARS - 1));
        assert_eq!(at_limit.chars().count(), DISPLAY_NAME_MAX_CLUSTER_CHARS);
        assert_eq!(sanitize(&at_limit), Some(at_limit.clone()));

        let one_over = format!("a{}", "\u{0301}".repeat(DISPLAY_NAME_MAX_CLUSTER_CHARS));
        assert_eq!(sanitize(&one_over), None);

        // Every cluster Haven must render whole fits with room to spare.
        for legitimate in [FLAG, FAMILY, SCOTLAND, "क्षि"] {
            assert!(legitimate.chars().count() <= DISPLAY_NAME_MAX_CLUSTER_CHARS);
            assert_eq!(sanitize(legitimate), Some(legitimate.to_string()));
        }
    }

    #[test]
    fn keeps_the_joiners_the_search_fold_strips() {
        // The two functions are deliberately different, and this is the pair
        // that proves it: matching must unify the ZWNJ spellings, rendering
        // must preserve them.
        let persian = "می\u{200C}رود";
        assert!(sanitize(persian)
            .expect("name survives")
            .contains('\u{200C}'));
        assert!(!crate::directory::fold_for_search(persian).contains('\u{200C}'));
    }

    proptest! {
        /// Sanitizing sanitized text changes nothing, the result never exceeds
        /// the cluster cap, and nothing on the strip list survives. Idempotence
        /// is what lets the writer re-apply the sanitizer to a row a caller has
        /// already sanitized without changing it.
        #[test]
        fn prop_sanitize_is_idempotent_and_bounded(
            input in proptest::collection::vec(any::<char>(), 0..80)
                .prop_map(|cs| cs.into_iter().collect::<String>())
        ) {
            use unicode_segmentation::UnicodeSegmentation;

            let once = sanitize_display_name(Some(input));
            prop_assert_eq!(&sanitize_display_name(once.clone()), &once);

            if let Some(name) = once {
                prop_assert!(!name.is_empty());
                prop_assert!(
                    name.chars().any(is_renderable),
                    "a name of nothing but invisible characters must be None"
                );
                prop_assert!(name.graphemes(true).count() <= DISPLAY_NAME_MAX_GRAPHEMES);
                prop_assert!(
                    name.graphemes(true)
                        .all(|g| g.chars().count() <= DISPLAY_NAME_MAX_CLUSTER_CHARS),
                    "a cluster grew past the char ceiling"
                );
                prop_assert!(
                    name.chars().count()
                        <= DISPLAY_NAME_MAX_GRAPHEMES * DISPLAY_NAME_MAX_CLUSTER_CHARS,
                    "the two caps must bound the whole name, not just its clusters"
                );
                // Explicit messages, not the default: `prop_assert!`
                // stringifies its expression into a format string, where a
                // `\u{...}` escape reads as an unterminated `{` placeholder.
                prop_assert!(!name.contains('\u{202E}'), "bidi override survived");
                prop_assert!(!name.contains('\u{200B}'), "zero-width space survived");
                prop_assert!(!name.contains('\u{0000}'), "NUL survived");
                prop_assert!(!name.contains('\u{3164}'), "invisible Hangul filler survived");
                prop_assert!(!name.contains('\u{034F}'), "grapheme joiner survived");
                prop_assert!(
                    !name.starts_with(' ') && !name.ends_with(' '),
                    "untrimmed"
                );
                prop_assert!(!name.contains("  "), "uncollapsed whitespace run");
            }
        }
    }
}
