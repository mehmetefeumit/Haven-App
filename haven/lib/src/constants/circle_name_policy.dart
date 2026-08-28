/// Policy constants for circle display names.
library;

/// Maximum length, in UTF-16 code units, of a circle's display name.
///
/// `nameCircleNameTooLongError` quotes this number verbatim; the two are
/// pinned together by `test/constants/circle_name_policy_test.dart`. This
/// bound is looser than, and independent of, [kCircleNameMaxGraphemes] below
/// — the field's `maxLength` keeps ordinary typing well under it, so in
/// practice this is a defence-in-depth backstop for the rare grapheme whose
/// code-unit footprint is large (e.g. multi-codepoint emoji), not the
/// number that governs what actually gets stored.
const int kCircleNameMaxLength = 50;

/// Maximum length, in grapheme clusters, of a circle's display name — what
/// the field's `maxLength` actually enforces while typing.
///
/// Mirrors `haven-core`'s `DISPLAY_NAME_MAX_GRAPHEMES`
/// (`haven-core/src/directory/sanitize.rs`): a name longer than this is
/// silently TRUNCATED at the storage boundary (`sanitize_circle_name`), so a
/// UI cap looser than the real one would let a user type a name, tap
/// Create, and have Haven quietly store something shorter than what they
/// typed. Grapheme clusters, not UTF-16 code units or `char`s, for the same
/// reason the Rust side counts them that way: a code-unit cap can split a
/// surrogate pair, and a `char` cap can split a flag emoji or a combining
/// sequence, mid-cluster.
const int kCircleNameMaxGraphemes = 48;
