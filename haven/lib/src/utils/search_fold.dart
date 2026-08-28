/// Search normalisation for the member directory.
///
/// Exactly one implementation of this exists, and it is in Rust
/// (`haven_core::directory::fold_for_search`). It is applied to BOTH sides of
/// a picker query — the stored name and the string being typed — so a second
/// implementation could not be proven to agree with the first. Dart is
/// especially unsuited to holding the second one: `toLowerCase` is as far as
/// its core library reaches, and the fold is not a lowercasing — `Ärger`
/// folds to `arger`, `Straße` to `strasse` and `Çağrı` to `cagri`, none of
/// which `toLowerCase` produces — while Dart ships no NFKD at all, so a Dart
/// fold would mean a second, separately versioned Unicode database drifting
/// on every SDK bump.
library;

import 'package:flutter/foundation.dart';
import 'package:haven/src/rust/api.dart' as rust;

/// The normalisation applied to both sides of a member-directory query.
///
/// Injectable so the pure directory functions can be exercised against
/// recorded Rust outputs in a process where the bridge does not exist (see
/// `test/services/member_directory_unicode_search_test.dart`).
typedef SearchFold = String Function(String value);

/// Normalises [value] into the key the member directory matches on.
///
/// Case-, accent- and invisible-character-insensitive; compositional, so the
/// fold of a prefix is a prefix of the fold. `fold_for_search` is exported
/// `#[frb(sync)]` precisely so this can run on every keystroke and let the
/// list update in the same frame as the caret.
///
/// Never throws. The synchronous bridge call throws whenever `RustLib` has
/// not been initialised — which is every `flutter test` process — so this
/// wraps it exactly as `constants/relays.dart` wraps `default_relays()`. A
/// picker that threw on a keystroke would be worse than one that searched
/// imprecisely — but it says so once, because a fold that degraded silently
/// would search wrongly and permanently with nothing in the log to say why.
String searchFold(String value) {
  try {
    return rust.foldForSearch(query: value);
  } on Object catch (e) {
    if (!_degradationReported) {
      _degradationReported = true;
      // Error TYPE only: [value] is the text the user is typing, which must
      // never reach a log (Security Rule 8). No debug `assert` either — every
      // `flutter test` process reaches this path, so a debug-only throw would
      // fail every widget test that types into the picker, on exactly the
      // degradation this wrapper exists to absorb.
      debugPrint('[SearchFold] bridge fold unavailable: ${e.runtimeType}');
    }
    return fallbackSearchFold(value);
  }
}

/// Whether the degradation has already been reported in this process.
///
/// Once per PROCESS, not once per keystroke: the fold runs on every character
/// typed, and a per-call line would bury every other line in the console,
/// which is how a loud signal becomes an ignored one.
bool _degradationReported = false;

/// Re-arms the once-per-process log so each test observes it from scratch.
@visibleForTesting
void resetSearchFoldDegradationLog() => _degradationReported = false;

/// Stand-in used only when the Rust bridge is unavailable.
///
/// A TEST-PATH AFFORDANCE, not a second fold: it is deliberately limited to
/// simple case folding, so it can never be mistaken for — or quietly grow
/// into — a rival implementation of the Unicode contract that
/// `fold_for_search` owns. Its limitation is pinned by
/// `test/utils/search_fold_test.dart`, and the production call site is
/// pinned by `test/lints/member_directory_fold_wiring_test.dart`.
String fallbackSearchFold(String value) => value.toLowerCase();
