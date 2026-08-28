/// The Unicode search contract for the member directory (plan §6.2).
///
/// **What these tests do and do not prove.** `flutter test` never calls
/// `RustLib.init()`, so the real `fold_for_search` cannot run in this
/// process — `searchFold` resolves to its deliberately weaker stand-in here.
/// These tests therefore inject [_rustFold], a lookup over fold outputs
/// RECORDED FROM `haven-core/src/directory/fold.rs`, and prove that the Dart
/// half of the directory — candidate keys, substring matching, prefix
/// matching, ordering — turns those outputs into the right search results.
///
/// The chain of custody is:
///
/// 1. `cargo test` proves the fold itself; that suite is the spec.
/// 2. `every recorded fold output is pinned to an assertion in haven-core`
///    below fails if a vector recorded here stops matching an assertion in
///    that file, so the recording cannot silently drift from the spec.
/// 3. `test/lints/member_directory_fold_wiring_test.dart` proves production
///    calls the Rust fold rather than the stand-in.
///
/// [_rustFold] deliberately FAILS on an input it has no recording for: a
/// nearby approximation would quietly turn this file into a second fold.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/services/member_directory_service.dart';
import 'package:haven/src/services/profile_service.dart';

const _foldSource = '../haven-core/src/directory/fold.rs';

const _pubkey =
    'a11ce0000000000000000000000000000000000000000000000000000000cafe';

const _npub =
    'npub1qqqsyqcyq5rqwzqfpg9scrgwpugpzysnzs23v9ccrydpk8qarc0jt2wp';

/// U+200C ZERO WIDTH NON-JOINER, spelled out because it is invisible.
const _zwnj = '\u200C';

/// The two Persian spellings of one word, differing only by a ZWNJ.
const _miRavadJoined = 'می\u200Cرود';
const _miRavad = 'میرود';

/// One recorded input/output pair of `haven_core::directory::fold_for_search`,
/// with the exact source fragments in [_foldSource] that must still assert it.
typedef _FoldVector = ({String input, String folded, List<String> pins});

const _vectors = <_FoldVector>[
  (
    input: 'Ärger',
    folded: 'arger',
    pins: ['assert_eq!(fold_for_search("Ärger"), "arger");'],
  ),
  (
    input: 'İstanbul',
    folded: 'istanbul',
    pins: ['assert_eq!(fold_for_search("İstanbul"), "istanbul");'],
  ),
  (
    input: 'ISTANBUL',
    folded: 'istanbul',
    pins: ['assert_eq!(fold_for_search("ISTANBUL"), "istanbul");'],
  ),
  (
    input: 'Çağrı',
    folded: 'cagri',
    pins: ['assert_eq!(fold_for_search("Çağrı"), "cagri");'],
  ),
  (
    input: 'ÇAĞRI',
    folded: 'cagri',
    pins: ['assert_eq!(fold_for_search("ÇAĞRI"), "cagri");'],
  ),
  (
    input: 'Élodie',
    folded: 'elodie',
    pins: ['assert_eq!(fold_for_search("Élodie"), "elodie");'],
  ),
  (
    input: 'E\u0301lodie',
    folded: 'elodie',
    pins: [r'assert_eq!(fold_for_search("E\u{0301}lodie"), "elodie");'],
  ),
  (
    input: 'Đurđević',
    folded: 'durdevic',
    pins: ['assert_eq!(fold_for_search("Đurđević"), "durdevic");'],
  ),
  (
    input: 'Bjørn',
    folded: 'bjorn',
    pins: ['assert_eq!(fold_for_search("Bjørn"), "bjorn");'],
  ),
  (
    input: 'Łukasz',
    folded: 'lukasz',
    pins: ['assert_eq!(fold_for_search("Łukasz"), "lukasz");'],
  ),
  (
    input: 'Straße',
    folded: 'strasse',
    pins: ['assert_eq!(fold_for_search("Straße"), "strasse");'],
  ),
  (
    input: 'ΣΙΣΥΦΟΣ',
    folded: 'σισυφοσ',
    pins: [
      'let expected = "σισυφοσ";',
      'assert_eq!(fold_for_search("ΣΙΣΥΦΟΣ"), expected);',
    ],
  ),
  (
    input: 'Σίσυφος',
    folded: 'σισυφοσ',
    pins: ['assert_eq!(fold_for_search("Σίσυφος"), expected);'],
  ),
  // The VALUE of the folded prefix is not asserted on its own in haven-core.
  // What is asserted there — and what this directory actually depends on —
  // is that it is a substring of the folded name; that assertion is the pin.
  (
    input: 'ΣΙΣ',
    folded: 'σισ',
    pins: [
      'assert!(fold_for_search("ΣΙΣΥΦΟΣ").contains(&fold_for_search("ΣΙΣ")));',
    ],
  ),
  (
    input: '田中太郎',
    folded: '田中太郎',
    pins: ['assert_eq!(fold_for_search("田中太郎"), "田中太郎");'],
  ),
  (
    input: 'محمد علي',
    folded: 'محمد علي',
    pins: ['assert_eq!(fold_for_search("محمد علي"), "محمد علي");'],
  ),
  (
    input: _miRavadJoined,
    folded: _miRavad,
    pins: [
      r'let with_zwnj = "می\u{200C}رود";',
      'assert_eq!(fold_for_search(with_zwnj), fold_for_search(without));',
    ],
  ),
  (
    input: _miRavad,
    folded: _miRavad,
    pins: ['let without = "میرود";'],
  ),
];

/// Every recorded input, plus every recorded OUTPUT mapped to itself.
///
/// The self-mappings are not a shortcut: `fold_for_search` is proven
/// idempotent by `prop_fold_is_idempotent_and_never_panics`, so folding an
/// already-folded string is the identity. That is what lets a user type the
/// plain ASCII spelling and have it fold to itself.
final _foldTable = <String, String>{
  '': '',
  for (final vector in _vectors) ...{
    vector.input: vector.folded,
    vector.folded: vector.folded,
  },
};

String _rustFold(String value) {
  final folded = _foldTable[value];
  if (folded == null) {
    fail(
      'no recorded haven-core fold output for "$value" — add a vector to '
      '_vectors and pin it to an assertion in $_foldSource, rather than '
      'approximating the fold here',
    );
  }
  return folded;
}

/// A one-person directory whose only member publishes [name].
MemberDirectory _directoryFor(String name) {
  return buildDirectory(
    entries: const [
      DirectoryEntry(
        pubkeyHex: _pubkey,
        npub: _npub,
        tier: DirectoryTier.current,
      ),
    ],
    profiles: {_pubkey: Profile(pubkeyHex: _pubkey, displayName: name)},
    fold: _rustFold,
  );
}

/// Whether a member who published [name] is found by typing [query].
bool _finds(String name, String query) {
  return searchDirectory(
    _directoryFor(name),
    query: query,
    fold: _rustFold,
  ).isNotEmpty;
}

String _codeOnly(String source) => source
    .split('\n')
    .where((line) => !line.trimLeft().startsWith('//'))
    .join('\n');

void main() {
  group('Turkish', () {
    test('a dotted capital I matches the ASCII spelling', () {
      expect(_finds('İstanbul', 'istanbul'), isTrue);
      expect(_finds('ISTANBUL', 'istanbul'), isTrue);
    });

    test('a dotless i matches the ASCII spelling', () {
      expect(_finds('Çağrı', 'cagri'), isTrue);
      expect(_finds('ÇAĞRI', 'cagri'), isTrue);
    });
  });

  group('German', () {
    test('eszett matches the ss spelling', () {
      expect(_finds('Straße', 'strasse'), isTrue);
    });

    test('an umlaut matches the unaccented spelling', () {
      expect(_finds('Ärger', 'arger'), isTrue);
    });
  });

  group('Greek', () {
    test('a name folds to one sigma form in every position', () {
      expect(_rustFold('ΣΙΣΥΦΟΣ'), equals('σισυφοσ'));
      expect(_rustFold('ΣΙΣΥΦΟΣ'), isNot(contains('ς')));
    });

    test('a capitalised PREFIX still matches the name', () {
      // The case the plan nearly shipped broken: under a context-sensitive
      // lowercasing the query's own final sigma would not appear medially in
      // the folded name, and a Greek user typing the first three letters of
      // a name in capitals would get zero results.
      expect(_finds('ΣΙΣΥΦΟΣ', 'ΣΙΣ'), isTrue);
      expect(_finds('Σίσυφος', 'ΣΙΣ'), isTrue);
    });
  });

  group('accented Latin', () {
    test('matches whether the name is composed or decomposed', () {
      expect(_finds('Élodie', 'elodie'), isTrue);
      expect(_finds('E\u0301lodie', 'elodie'), isTrue);
    });

    test('the two encodings of one name fold to the same key', () {
      expect(_rustFold('Élodie'), equals(_rustFold('E\u0301lodie')));
    });
  });

  group('stroke and ligature letters', () {
    test('match the ASCII spelling their owners routinely give', () {
      // NFKD removes combining marks only, so these need the explicit
      // transliteration table — without it, Croatian, Norwegian and Polish
      // names are unsearchable in the spelling they are usually typed in.
      expect(_finds('Đurđević', 'durdevic'), isTrue);
      expect(_finds('Bjørn', 'bjorn'), isTrue);
      expect(_finds('Łukasz', 'lukasz'), isTrue);
    });
  });

  group('scripts the fold leaves alone', () {
    test('a CJK name matches itself unchanged', () {
      expect(_rustFold('田中太郎'), equals('田中太郎'));
      expect(_finds('田中太郎', '田中太郎'), isTrue);
    });

    test('an Arabic name matches itself unchanged', () {
      expect(_rustFold('محمد علي'), equals('محمد علي'));
      expect(_finds('محمد علي', 'محمد علي'), isTrue);
    });
  });

  group('Persian', () {
    test('spellings differing only by ZWNJ match each other', () {
      expect(_miRavadJoined, contains(_zwnj));
      expect(_finds(_miRavadJoined, _miRavad), isTrue);
      expect(_finds(_miRavad, _miRavadJoined), isTrue);
    });

    test('the folded key carries no ZWNJ', () {
      expect(_rustFold(_miRavadJoined), isNot(contains(_zwnj)));
    });
  });

  group('recording integrity', () {
    late String code;

    setUpAll(() {
      final file = File(_foldSource);
      if (!file.existsSync()) {
        fail(
          'cannot read $_foldSource — this test pins the fold outputs '
          'recorded here to the haven-core assertions that produce them',
        );
      }
      code = _codeOnly(file.readAsStringSync());
    });

    test('every recorded fold output is pinned to an assertion in '
        'haven-core', () {
      for (final vector in _vectors) {
        for (final pin in vector.pins) {
          expect(
            code,
            contains(pin),
            reason: 'the recorded fold of "${vector.input}" is no longer '
                'asserted by $_foldSource — re-derive the recording, never '
                'adjust it to match this suite',
          );
        }
      }
    });

    test('the self-mapped outputs rest on the idempotence property', () {
      expect(
        code,
        contains('fn prop_fold_is_idempotent_and_never_panics'),
        reason: 'without idempotence, folding an already-folded query is not '
            'the identity and every ASCII query recorded here is unfounded',
      );
    });

    test('every recorded vector is exercised by a real search', () {
      // A recording nobody searches with proves nothing.
      for (final vector in _vectors) {
        expect(
          _finds(vector.input, vector.folded),
          isTrue,
          reason: 'a member published as "${vector.input}" is not found by '
              'typing its own folded key',
        );
      }
    });
  });
}
