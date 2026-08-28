/// Tests for [searchDirectory] — the synchronous, in-memory filter the
/// picker runs on every keystroke (plan §9.3).
///
/// These exercise the MATCHING rules with the production `searchFold`, which
/// under `flutter test` resolves to its bridge-less stand-in. The Unicode
/// contract that the stand-in cannot honour is proven separately in
/// `member_directory_unicode_search_test.dart`.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/services/member_directory_service.dart';
import 'package:haven/src/services/profile_service.dart';

const _aliceHex =
    'a11ce0000000000000000000000000000000000000000000000000000000cafe';
const _bobHex =
    'b0b0000000000000000000000000000000000000000000000000000000000dad';
const _carolHex =
    'ca401000000000000000000000000000000000000000000000000000000beef0';

// The real NIP-19 encoding of each hex key above: `npub1` + 52 data
// characters + a 6-character checksum, 63 in total. Written out rather than
// derived because Dart has no bech32 encoder here — and they must be the real
// length, or 'matches a whole npub' would never exercise one.
const _aliceNpub =
    'npub15ywwqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqetlqhgm683';
const _bobNpub =
    'npub1kzcqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqpkksrcdwkr';
const _carolNpub =
    'npub1efqpqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqtamcqhprsfg';

DirectoryEntry _entry(
  String pubkeyHex,
  String npub, {
  DirectoryTier tier = DirectoryTier.current,
}) {
  return DirectoryEntry(
    pubkeyHex: pubkeyHex,
    npub: npub,
    tier: tier,
  );
}

MemberDirectory _directory() {
  return buildDirectory(
    entries: [
      _entry(_aliceHex, _aliceNpub),
      _entry(_bobHex, _bobNpub),
      _entry(_carolHex, _carolNpub),
    ],
    profiles: const {
      _aliceHex: Profile(pubkeyHex: _aliceHex, displayName: 'Alice Aardvark'),
      _bobHex: Profile(pubkeyHex: _bobHex, displayName: 'Bob Badger'),
    },
    petnames: const {_bobHex: 'Landlord'},
  );
}

List<String> _hits(String query) {
  return searchDirectory(_directory(), query: query)
      .map((c) => c.pubkeyHex)
      .toList();
}

void main() {
  group('empty query', () {
    test('returns the whole directory, in rank order', () {
      // R2's auto-populate: the list renders as soon as the picker opens,
      // before a single character is typed.
      expect(_hits(''), orderedEquals(<String>[_aliceHex, _bobHex, _carolHex]));
    });

    test('treats a whitespace-only query as empty', () {
      expect(
        _hits('   '),
        orderedEquals(<String>[_aliceHex, _bobHex, _carolHex]),
      );
    });

    test('returns the same list instance the directory already holds', () {
      // No copy per keystroke while the field is empty — the picker opens
      // on this path and re-runs it on every backspace to empty.
      final directory = _directory();
      expect(
        searchDirectory(directory, query: ''),
        same(directory.entries),
      );
    });
  });

  group('name matching', () {
    test('matches a case-insensitive substring of the resolved name', () {
      expect(_hits('aardvark'), orderedEquals(<String>[_aliceHex]));
      expect(_hits('AARDVARK'), orderedEquals(<String>[_aliceHex]));
    });

    test('matches a leading fragment of the resolved name', () {
      expect(_hits('ali'), orderedEquals(<String>[_aliceHex]));
    });

    test('ignores leading and trailing whitespace in the query', () {
      expect(_hits('  alice  '), orderedEquals(<String>[_aliceHex]));
    });

    test('matches the local petname', () {
      expect(_hits('landlord'), orderedEquals(<String>[_bobHex]));
    });

    test('matches the published name a petname masks', () {
      expect(_hits('badger'), orderedEquals(<String>[_bobHex]));
    });

    test('returns every match, in directory order', () {
      expect(_hits('a'), orderedEquals(<String>[_aliceHex, _bobHex]));
    });

    test('returns nothing when no name and no key matches', () {
      expect(_hits('zzzzz'), isEmpty);
    });

    test('never matches a member who resolved no name by name', () {
      // Carol is in the directory (she must not be hidden) but has nothing
      // to match on except her key.
      expect(_hits('carol'), isEmpty);
      expect(_hits(''), contains(_carolHex));
    });
  });

  group('key matching', () {
    test('matches an npub prefix', () {
      expect(_hits('npub15yww'), orderedEquals(<String>[_aliceHex]));
    });

    test('matches an npub prefix typed in capitals', () {
      expect(_hits('NPUB15YWW'), orderedEquals(<String>[_aliceHex]));
    });

    test('matches a whole npub', () {
      expect(_aliceNpub, hasLength(63));
      expect(_hits(_aliceNpub), orderedEquals(<String>[_aliceHex]));
    });

    test('never matches an npub SUBSTRING', () {
      // A substring match turns any two characters into a directory
      // enumeration: `qqqqqq` is shared by every one of these keys, so a
      // substring rule would return the whole list for a fragment the user
      // could not have read off anyone's identity.
      expect(_aliceNpub, contains('qqqqqq'));
      expect(_bobNpub, contains('qqqqqq'));
      expect(_hits('qqqqqq'), isEmpty);
    });

    test('matches the key of a member who resolved no name', () {
      expect(_hits('npub1efq'), orderedEquals(<String>[_carolHex]));
    });
  });

  group('the shared npub prefix never enumerates the directory', () {
    test('a query no longer than `npub1` matches nobody by key', () {
      // EVERY npub starts `npub1`, so a bare prefix rule would return the
      // whole directory for keystroke 1 of "Nadia". Only `Landlord` comes
      // back for 'n', and it comes back on its NAME.
      expect(_hits('n'), orderedEquals(<String>[_bobHex]));
      expect(_hits('np'), isEmpty);
      expect(_hits('npu'), isEmpty);
      expect(_hits('npub'), isEmpty);
      expect(_hits('npub1'), isEmpty);
    });

    test('a query one character past the prefix narrows normally', () {
      // The rule bites only on the shared part: the first character that
      // distinguishes one key from another still matches.
      expect(_hits('npub1k'), orderedEquals(<String>[_bobHex]));
    });
  });

  group('hex pubkeys are not a search surface', () {
    test('never matches a hex pubkey prefix', () {
      // Hex is never rendered in the picker, so a hex match surfaces people
      // for a reason invisible to the user — and one hex character is
      // roughly a sixteenth of the roster.
      expect(_hits('a11ce'), isEmpty);
      expect(_hits('ca401'), isEmpty);
    });

    test('never matches a hex pubkey substring', () {
      expect(_aliceHex, contains('cafe'));
      expect(_hits('cafe'), isEmpty);
    });
  });

  group('non-BMP input', () {
    test('matches a name whose emoji sits outside the basic plane', () {
      // A surrogate pair is two UTF-16 code units. Any hand-rolled
      // index/substring arithmetic over the name would split it and either
      // throw or silently corrupt the key; `contains` over whole strings
      // does not.
      final directory = buildDirectory(
        entries: [_entry(_aliceHex, _aliceNpub)],
        profiles: const {
          _aliceHex: Profile(pubkeyHex: _aliceHex, displayName: 'Zoe 🎈 Party'),
        },
      );

      expect(searchDirectory(directory, query: 'party'), hasLength(1));
      expect(searchDirectory(directory, query: '🎈'), hasLength(1));
      expect(searchDirectory(directory, query: '🎉'), isEmpty);
    });
  });

  group('R5: tier-1 (recent) people stay searchable', () {
    MemberDirectory recentDirectory() {
      return buildDirectory(
        entries: [_entry(_carolHex, _carolNpub, tier: DirectoryTier.recent)],
        profiles: const {
          _carolHex: Profile(pubkeyHex: _carolHex, displayName: 'Carol Coyote'),
        },
        petnames: const {_carolHex: 'Old Roommate'},
      );
    }

    test('a recent (tier-1) person is found by their cached username', () {
      final hits = searchDirectory(recentDirectory(), query: 'coyote');
      expect(hits.map((c) => c.pubkeyHex), [_carolHex]);
      expect(hits.single.tier, DirectoryTier.recent);
    });

    test('a recent (tier-1) person is found by their local petname', () {
      final hits = searchDirectory(recentDirectory(), query: 'roommate');
      expect(hits.map((c) => c.pubkeyHex), [_carolHex]);
    });

    test('a recent (tier-1) person is found by a prefix of their npub', () {
      expect(_carolNpub, hasLength(63));
      final hits = searchDirectory(
        recentDirectory(),
        query: _carolNpub.substring(0, 10),
      );
      expect(hits.map((c) => c.pubkeyHex), [_carolHex]);
    });

    test('an empty query still returns the recent (tier-1) person', () {
      expect(
        searchDirectory(recentDirectory(), query: '').map((c) => c.pubkeyHex),
        [_carolHex],
      );
    });
  });
}
