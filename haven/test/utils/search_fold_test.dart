/// Tests for [searchFold] — the one normalisation applied to BOTH sides of a
/// member-directory query.
///
/// The normalisation itself belongs to `haven_core::directory::fold_for_search`
/// and is proven by that crate's own suite (`cargo test`). What is testable
/// here is the Dart wrapper's contract: it must never throw, and its
/// bridge-less stand-in must stay recognisably weaker than the real fold so
/// nothing can mistake it for a second implementation.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/utils/search_fold.dart';

/// Captures everything [debugPrint] emits for the duration of one test.
List<String?> _captureDebugPrint() {
  final logged = <String?>[];
  final previous = debugPrint;
  debugPrint = (message, {int? wrapWidth}) => logged.add(message);
  addTearDown(() => debugPrint = previous);
  resetSearchFoldDegradationLog();
  return logged;
}

void main() {
  group('searchFold', () {
    test('returns a value instead of throwing without the Rust bridge', () {
      // `flutter test` never calls `RustLib.init()`, so the synchronous
      // bridge call throws on every invocation in this process. A picker
      // that threw on a keystroke would be worse than one that searched
      // imprecisely, so the wrapper degrades instead of propagating.
      expect(() => searchFold('Alice'), returnsNormally);
      expect(searchFold('Alice'), isNotEmpty);
    });

    test('folds ASCII case, so a lowercase query matches a capital name', () {
      expect(searchFold('ALICE'), equals(searchFold('alice')));
    });

    test('folds the empty string to the empty string', () {
      // The picker treats an empty folded query as "show everyone"; a
      // fold that invented content for '' would break auto-populate.
      expect(searchFold(''), isEmpty);
    });
  });

  group('degrading to the stand-in is audible', () {
    test('says the bridge fold was unavailable, by error TYPE only', () {
      // Every other degradation in this app logs `e.runtimeType`. A fold
      // that fell back silently would search wrongly and permanently with
      // nothing in the log to say why — and the query is the user's typed
      // text, which must never reach a log (Security Rule 8).
      final logged = _captureDebugPrint();

      searchFold('Alice');

      expect(logged, hasLength(1));
      expect(logged.single, contains('SearchFold'));
      expect(logged.single, isNot(contains('Alice')));
    });

    test('says it once per process, not once per keystroke', () {
      // The fold runs on every character typed. A per-call log would bury
      // every other line in the console, which is how a loud signal
      // becomes an ignored one.
      final logged = _captureDebugPrint();

      for (final query in ['A', 'Al', 'Ali', 'Alic', 'Alice']) {
        searchFold(query);
      }

      expect(logged, hasLength(1));
    });
  });

  group('fallbackSearchFold', () {
    test('is deliberately weaker than the Rust fold it stands in for', () {
      // Pins the LIMITATION, not a capability. If this stand-in ever grew
      // accent stripping, NFKD or transliteration it would have become a
      // second implementation of a Unicode contract that has exactly one
      // owner — and one that drifts on every Dart SDK bump, since Dart
      // ships no NFKD at all.
      expect(fallbackSearchFold('Ärger'), isNot(equals('arger')));
      expect(fallbackSearchFold('Straße'), isNot(equals('strasse')));
      expect(fallbackSearchFold('Đurđević'), isNot(equals('durdevic')));
      expect(fallbackSearchFold('Çağrı'), isNot(equals('cagri')));
    });

    test('agrees with the Rust fold on the dotted I and the final sigma', () {
      // These two look like showcase divergences and are not. They diverge
      // from `str::to_lowercase` — the design haven-core REJECTED, which
      // applies the `Final_Sigma` context rule and expands `İ` to `i` +
      // U+0307 — but `fold_for_search` drops the context and the combining
      // mark, landing exactly where Dart's `toLowerCase` already lands.
      // Recorded in `member_directory_unicode_search_test.dart` and asserted
      // in `haven-core/src/directory/fold.rs`. Naming them as the reason a
      // Dart fold would be wrong would be citing evidence that says the
      // opposite; the four expansions above are the real reason.
      expect(fallbackSearchFold('İstanbul'), equals('istanbul'));
      expect(fallbackSearchFold('ΟΔΥΣΣΕΑΣ'), equals('οδυσσεασ'));
    });
  });
}
