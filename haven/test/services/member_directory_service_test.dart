/// Tests for the pure half of the member directory (P1-P3, plan
/// §3/§6.1/§7.2/§9.3).
///
/// Everything the directory decides — which tier a row belongs to, how a
/// candidate is built from a directory row plus a cached profile and a local
/// petname, how a display-name collision is broken, and the total order each
/// tier renders in — lives in top-level functions with no FFI, so it is
/// provable here rather than only in an emulator lane.
library;

import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/services/member_directory_service.dart';
import 'package:haven/src/services/profile_service.dart';

const _alice =
    'a11ce0000000000000000000000000000000000000000000000000000000cafe';
const _bob =
    'b0b0000000000000000000000000000000000000000000000000000000000dad';
const _carol =
    'ca401000000000000000000000000000000000000000000000000000000beef0';
const _self =
    '5e1f0000000000000000000000000000000000000000000000000000000000ff';

DirectoryEntry _entry(
  String pubkeyHex, {
  String? npub,
  DirectoryTier tier = DirectoryTier.current,
}) {
  return DirectoryEntry(
    pubkeyHex: pubkeyHex,
    npub: npub ?? 'npub1${pubkeyHex.substring(0, 58)}',
    tier: tier,
  );
}

CircleMember _member(String pubkey, {String? npub}) {
  return CircleMember(
    pubkey: pubkey,
    npub: npub ?? 'npub1${pubkey.substring(0, 58)}',
    isAdmin: false,
  );
}

Circle _circle(
  List<CircleMember> members, {
  int id = 1,
  MembershipStatus status = MembershipStatus.accepted,
  String displayName = 'Circle',
}) {
  return Circle(
    mlsGroupId: [id],
    nostrGroupId: [id],
    displayName: displayName,
    circleType: CircleType.locationSharing,
    relays: const [],
    membershipStatus: status,
    members: members,
    createdAt: DateTime(2026),
    updatedAt: DateTime(2026),
  );
}

void main() {
  group('circleNamesForCollision', () {
    test('lists every accepted circle a co-member is currently on', () {
      final names = circleNamesForCollision(
        circles: [
          _circle([_member(_alice)], displayName: 'Family'),
          _circle([_member(_alice)], id: 2, displayName: 'Work'),
        ],
        selfPubkeyHex: _self,
      );

      expect(
        names[_alice],
        unorderedEquals(<String>['Family', 'Work']),
      );
    });

    test('never lists the local user', () {
      final names = circleNamesForCollision(
        circles: [_circle([_member(_self)], displayName: 'Family')],
        selfPubkeyHex: _self,
      );

      expect(names, isNot(contains(_self)));
    });

    test('never lists the local user under hex case drift', () {
      final names = circleNamesForCollision(
        circles: [
          _circle([_member(_self.toUpperCase())], displayName: 'Family'),
        ],
        selfPubkeyHex: _self,
      );

      expect(names, isEmpty);
    });

    test('skips circles the user has only been invited to', () {
      // A collision cannot be broken by naming a circle the user does not
      // yet share, matching the union the directory table is built from.
      final names = circleNamesForCollision(
        circles: [
          _circle(
            [_member(_alice)],
            status: MembershipStatus.pending,
            displayName: 'Pending Circle',
          ),
        ],
        selfPubkeyHex: _self,
      );

      expect(names, isEmpty);
    });

    test('keys are lowercase hex, matching directory entries', () {
      final names = circleNamesForCollision(
        circles: [
          _circle([_member(_alice.toUpperCase())], displayName: 'Family'),
        ],
        selfPubkeyHex: _self,
      );

      expect(names[_alice], equals(<String>['Family']));
    });
  });

  group('buildMemberCandidate', () {
    test('prefers the local petname over the published profile name', () {
      final candidate = buildMemberCandidate(
        entry: _entry(_alice),
        petname: 'Landlord',
        profile: const Profile(
          pubkeyHex: _alice,
          displayName: 'Alice Aardvark',
          name: 'alice',
        ),
      );

      expect(candidate.displayName, equals('Landlord'));
      expect(candidate.petname, equals('Landlord'));
    });

    test('prefers the published display_name over the published name', () {
      final candidate = buildMemberCandidate(
        entry: _entry(_alice),
        profile: const Profile(
          pubkeyHex: _alice,
          displayName: 'Alice Aardvark',
          name: 'alice',
        ),
      );

      expect(candidate.displayName, equals('Alice Aardvark'));
      expect(candidate.petname, isNull);
    });

    test('falls back to the published name when there is no display_name', () {
      final candidate = buildMemberCandidate(
        entry: _entry(_alice),
        profile: const Profile(pubkeyHex: _alice, name: 'alice'),
      );

      expect(candidate.displayName, equals('alice'));
    });

    test('resolves no name from a cache row that carries no content', () {
      // The profile cache answers with a row for a pubkey it resolved
      // nothing for. "An entry came back" is not "a profile resolved", so
      // the candidate is built from CONTENT, and a contentless row leaves
      // the person identified by npub alone.
      final candidate = buildMemberCandidate(
        entry: _entry(_alice),
        profile: const Profile(pubkeyHex: _alice),
      );

      expect(candidate.displayName, isNull);
      expect(candidate.searchKeys, isEmpty);
      expect(candidate.npub, isNotEmpty);
    });

    test('resolves no name from a profile whose names are whitespace', () {
      final candidate = buildMemberCandidate(
        entry: _entry(_alice),
        petname: '   ',
        profile: const Profile(
          pubkeyHex: _alice,
          displayName: '  ',
          name: '\t',
        ),
      );

      expect(candidate.displayName, isNull);
      expect(candidate.petname, isNull);
      expect(candidate.searchKeys, isEmpty);
    });

    test('resolves no name when there is no cached profile at all', () {
      final candidate = buildMemberCandidate(entry: _entry(_alice));

      expect(candidate.displayName, isNull);
      expect(candidate.hasPicture, isFalse);
    });

    test('keeps the published name searchable when a petname masks it', () {
      // R4 asks for people to be searchable by their CACHED USERNAME.
      // Renaming someone locally must not make them unfindable under the
      // name their other contacts know them by.
      final candidate = buildMemberCandidate(
        entry: _entry(_alice),
        petname: 'Landlord',
        profile: const Profile(
          pubkeyHex: _alice,
          displayName: 'Alice Aardvark',
          name: 'alice',
        ),
      );

      expect(
        candidate.searchKeys,
        orderedEquals(<String>['landlord', 'alice aardvark', 'alice']),
      );
    });

    test('records a name once when petname and profile name agree', () {
      final candidate = buildMemberCandidate(
        entry: _entry(_alice),
        petname: 'Alice',
        profile: const Profile(pubkeyHex: _alice, displayName: 'alice'),
      );

      expect(candidate.searchKeys, orderedEquals(<String>['alice']));
    });

    test('carries the picture hash and never the picture bytes', () {
      // Holding thumbnails for a whole roster would cost tens of megabytes
      // at scale; rows resolve their own bytes when they become visible.
      final candidate = buildMemberCandidate(
        entry: _entry(_alice),
        profile: const Profile(pubkeyHex: _alice, pictureHash: 'deadbeef'),
      );

      expect(candidate.hasPicture, isTrue);
      expect(candidate.pictureHash, equals('deadbeef'));
    });

    test('carries the tier straight from the directory entry', () {
      final current = buildMemberCandidate(entry: _entry(_alice));
      final recent = buildMemberCandidate(
        entry: _entry(_alice, tier: DirectoryTier.recent),
      );

      expect(current.tier, DirectoryTier.current);
      expect(recent.tier, DirectoryTier.recent);
    });
  });

  group('buildDirectory tier bucketing', () {
    test('places every tier-0 entry before every tier-1 entry', () {
      final directory = buildDirectory(
        entries: [
          _entry(_alice, tier: DirectoryTier.recent),
          _entry(_bob),
          _entry(_carol, tier: DirectoryTier.recent),
        ],
        profiles: const {},
      );

      expect(
        directory.entries.map((c) => c.tier),
        orderedEquals(<DirectoryTier>[
          DirectoryTier.current,
          DirectoryTier.recent,
          DirectoryTier.recent,
        ]),
      );
    });

    test(
      'a member added by an applied commit who has never sent a message '
      'still appears in tier 0',
      () {
        // This is the actual regression to guard against: nothing here may
        // ever gate tier-0 membership on participation — a decrypted
        // message, a resolved name, a cached picture. `entry.tier` is the
        // ONLY input `buildDirectory` may read to decide the section.
        final directory = buildDirectory(
          entries: [_entry(_alice)], // no profile, no petname: nothing
          // has ever resolved about this person — the roster placed them,
          // and that is all it takes.
          profiles: const {},
        );

        expect(directory.entries, hasLength(1));
        expect(directory.entries.single.pubkeyHex, equals(_alice));
        expect(directory.entries.single.tier, DirectoryTier.current);
      },
    );

    test(
      'tier 0 is exactly the current-tier entries — nothing else '
      'contributes a row',
      () {
        // Collision data must never be a WHO source: a circle name attached
        // to a pubkey that is not itself a directory entry must not conjure
        // a row for that pubkey.
        final directory = buildDirectory(
          entries: [_entry(_alice)],
          profiles: const {},
          circleNamesByPubkey: {
            _bob: ['Family'],
          },
        );

        expect(directory.entries.map((c) => c.pubkeyHex), [_alice]);
      },
    );

    test('each tier is independently ordered by folded name', () {
      final directory = buildDirectory(
        entries: [
          _entry(_alice, tier: DirectoryTier.recent),
          _entry(_bob),
          _entry(_carol, tier: DirectoryTier.recent),
        ],
        profiles: const {
          _alice: Profile(pubkeyHex: _alice, name: 'zoe'),
          _bob: Profile(pubkeyHex: _bob, name: 'alice'),
          _carol: Profile(pubkeyHex: _carol, name: 'ann'),
        },
      );

      // The tier-0 block (just Bob) is unaffected by the tier-1 block's
      // internal order — 'ann' sorts before 'zoe' but Carol never crosses
      // into the tier-0 block ahead of Bob.
      expect(
        directory.entries.map((c) => c.pubkeyHex),
        orderedEquals(<String>[_bob, _carol, _alice]),
      );
    });
  });

  group('buildDirectory ordering within a tier', () {
    MemberDirectory build(List<(String, Profile?)> rows) {
      return buildDirectory(
        entries: [for (final row in rows) _entry(row.$1)],
        profiles: {
          for (final row in rows)
            if (row.$2 != null) row.$1: row.$2!,
        },
      );
    }

    test('orders named entries by folded name, not by roster order', () {
      final directory = build([
        (_carol, const Profile(pubkeyHex: _carol, name: 'zoe')),
        (_alice, const Profile(pubkeyHex: _alice, name: 'Bob')),
        (_bob, const Profile(pubkeyHex: _bob, name: 'alice')),
      ]);

      expect(
        directory.entries.map((c) => c.displayName),
        orderedEquals(<String>['alice', 'Bob', 'zoe']),
      );
    });

    test('places entries with no resolved name last', () {
      final directory = build([
        (_alice, null),
        (_bob, const Profile(pubkeyHex: _bob, name: 'zoe')),
        (_carol, const Profile(pubkeyHex: _carol)),
      ]);

      expect(
        directory.entries.map((c) => c.pubkeyHex),
        orderedEquals(<String>[_bob, _alice, _carol]),
      );
    });

    test('breaks a folded-name tie by pubkey hex ascending', () {
      final directory = build([
        (_carol, const Profile(pubkeyHex: _carol, name: 'SAM')),
        (_alice, const Profile(pubkeyHex: _alice, name: 'sam')),
        (_bob, const Profile(pubkeyHex: _bob, name: 'Sam')),
      ]);

      expect(
        directory.entries.map((c) => c.pubkeyHex),
        orderedEquals(<String>[_alice, _bob, _carol]),
      );
    });

    test('breaks a tie between two unnamed entries by pubkey hex', () {
      final directory = build([
        (_carol, null),
        (_bob, null),
        (_alice, null),
      ]);

      expect(
        directory.entries.map((c) => c.pubkeyHex),
        orderedEquals(<String>[_alice, _bob, _carol]),
      );
    });

    test('produces identical output for every shuffle of one input', () {
      // A non-total order would render in a different sequence depending on
      // which circle happened to be read first, making every downstream
      // widget test flaky.
      final rows = <(String, Profile?)>[
        (_alice, const Profile(pubkeyHex: _alice, name: 'sam')),
        (_bob, const Profile(pubkeyHex: _bob, name: 'SAM')),
        (_carol, null),
        (
          '0${_alice.substring(1)}',
          const Profile(pubkeyHex: _alice, name: 'Sam'),
        ),
        ('f${_bob.substring(1)}', null),
      ];
      final expected = build(rows).entries.map((c) => c.pubkeyHex).toList();

      final random = Random(20260825);
      for (var i = 0; i < 50; i++) {
        final shuffled = List<(String, Profile?)>.of(rows)..shuffle(random);
        expect(
          build(shuffled).entries.map((c) => c.pubkeyHex),
          orderedEquals(expected),
          reason: 'shuffle $i changed the rendered order',
        );
      }
    });
  });

  group('collision disambiguation (plan §7.2)', () {
    test('marks every row when two tier-0 candidates share a resolved name',
        () {
      final directory = buildDirectory(
        entries: [_entry(_alice), _entry(_bob)],
        profiles: const {
          _alice: Profile(pubkeyHex: _alice, name: 'Alex'),
          _bob: Profile(pubkeyHex: _bob, name: 'Alex'),
        },
        circleNamesByPubkey: {
          _alice: ['Family'],
          _bob: ['Work Trip'],
        },
      );

      expect(
        {for (final c in directory.entries) c.pubkeyHex: c.collisionCircleName},
        {_alice: 'Family', _bob: 'Work Trip'},
      );
    });

    test('does not mark a name that appears once', () {
      final directory = buildDirectory(
        entries: [_entry(_alice), _entry(_bob)],
        profiles: const {
          _alice: Profile(pubkeyHex: _alice, name: 'Alex'),
          _bob: Profile(pubkeyHex: _bob, name: 'Bea'),
        },
        circleNamesByPubkey: {
          _alice: ['Family'],
          _bob: ['Work Trip'],
        },
      );

      expect(
        directory.entries.map((c) => c.collisionCircleName),
        everyElement(isNull),
      );
    });

    test('does not treat two unnamed rows as a collision', () {
      final directory = buildDirectory(
        entries: [_entry(_alice), _entry(_bob)],
        profiles: const {},
      );

      expect(
        directory.entries.map((c) => c.collisionCircleName),
        everyElement(isNull),
      );
    });

    test('never marks a tier-1 row, even against a colliding tier-0 name',
        () {
      // A tier-1 person is not a co-member of anything any more, so there is
      // no CURRENT circle that could be the reason the names collide.
      final directory = buildDirectory(
        entries: [_entry(_alice), _entry(_bob, tier: DirectoryTier.recent)],
        profiles: const {
          _alice: Profile(pubkeyHex: _alice, name: 'Alex'),
          _bob: Profile(pubkeyHex: _bob, name: 'Alex'),
        },
        circleNamesByPubkey: {
          _alice: ['Family'],
          _bob: ['Family'],
        },
      );

      final byHex = {
        for (final c in directory.entries) c.pubkeyHex: c,
      };
      expect(byHex[_alice]!.collisionCircleName, isNull);
      expect(byHex[_bob]!.collisionCircleName, isNull);
    });

    test('never marks two tier-1 rows against each other', () {
      final directory = buildDirectory(
        entries: [
          _entry(_alice, tier: DirectoryTier.recent),
          _entry(_bob, tier: DirectoryTier.recent),
        ],
        profiles: const {
          _alice: Profile(pubkeyHex: _alice, name: 'Alex'),
          _bob: Profile(pubkeyHex: _bob, name: 'Alex'),
        },
      );

      expect(
        directory.entries.map((c) => c.collisionCircleName),
        everyElement(isNull),
      );
    });

    test('names that fold alike but render differently are not a collision',
        () {
      // Collision detection compares the RENDERED name, not the search
      // fold: two names differing only by accent look different on screen,
      // so marking them would name a circle nobody needed to disambiguate.
      final directory = buildDirectory(
        entries: [_entry(_alice), _entry(_bob)],
        profiles: const {
          _alice: Profile(pubkeyHex: _alice, name: 'Café'),
          _bob: Profile(pubkeyHex: _bob, name: 'Cafe'),
        },
        circleNamesByPubkey: {
          _alice: ['Family'],
          _bob: ['Family'],
        },
      );

      expect(
        directory.entries.map((c) => c.collisionCircleName),
        everyElement(isNull),
      );
    });

    test(
      'chooses the disambiguator deterministically when more than one '
      'circle name is available',
      () {
        final directory = buildDirectory(
          entries: [_entry(_alice), _entry(_bob)],
          profiles: const {
            _alice: Profile(pubkeyHex: _alice, name: 'Alex'),
            _bob: Profile(pubkeyHex: _bob, name: 'Alex'),
          },
          circleNamesByPubkey: {
            _alice: ['Zebras', 'Ants'],
          },
        );

        final alice = directory.entries.firstWhere(
          (c) => c.pubkeyHex == _alice,
        );
        expect(alice.collisionCircleName, equals('Ants'));
      },
    );

    test(
      'picks a circle that actually distinguishes two colliding rows even '
      'when they share their alphabetically-first circle',
      () {
        // Naming each row its own first circle independently would hand
        // both 'Family' — disambiguating nothing.
        final directory = buildDirectory(
          entries: [_entry(_alice), _entry(_bob)],
          profiles: const {
            _alice: Profile(pubkeyHex: _alice, name: 'Alex'),
            _bob: Profile(pubkeyHex: _bob, name: 'Alex'),
          },
          circleNamesByPubkey: {
            _alice: ['Family', 'Home'],
            _bob: ['Family', 'House'],
          },
        );

        final byHex = {for (final c in directory.entries) c.pubkeyHex: c};
        expect(byHex[_alice]!.collisionCircleName, equals('Home'));
        expect(byHex[_bob]!.collisionCircleName, equals('House'));
        expect(
          byHex[_alice]!.collisionCircleName,
          isNot(equals(byHex[_bob]!.collisionCircleName)),
        );
      },
    );

    test(
      'shows no disambiguator when two colliding rows share every circle '
      'they are on',
      () {
        // Neither row has a circle unique to it, so a circle note would
        // read identically on both — worse than showing neither, since it
        // would look like a disambiguator that disambiguates nothing. The
        // npub, always rendered, remains their differentiator.
        final directory = buildDirectory(
          entries: [_entry(_alice), _entry(_bob)],
          profiles: const {
            _alice: Profile(pubkeyHex: _alice, name: 'Alex'),
            _bob: Profile(pubkeyHex: _bob, name: 'Alex'),
          },
          circleNamesByPubkey: {
            _alice: ['Family'],
            _bob: ['Family'],
          },
        );

        expect(
          directory.entries.map((c) => c.collisionCircleName),
          everyElement(isNull),
        );
      },
    );

    test(
      'a row with a circle unique to it is still marked even when the '
      'others it collides with share every circle between THEM',
      () {
        final directory = buildDirectory(
          entries: [_entry(_alice), _entry(_bob), _entry(_carol)],
          profiles: const {
            _alice: Profile(pubkeyHex: _alice, name: 'Alex'),
            _bob: Profile(pubkeyHex: _bob, name: 'Alex'),
            _carol: Profile(pubkeyHex: _carol, name: 'Alex'),
          },
          circleNamesByPubkey: {
            _alice: ['Family'],
            _bob: ['Family'],
            _carol: ['Family', 'Zoo'],
          },
        );

        final byHex = {for (final c in directory.entries) c.pubkeyHex: c};
        expect(byHex[_alice]!.collisionCircleName, isNull);
        expect(byHex[_bob]!.collisionCircleName, isNull);
        expect(byHex[_carol]!.collisionCircleName, equals('Zoo'));
      },
    );

    test('a circle name for a pubkey not in entries never creates a row',
        () {
      final directory = buildDirectory(
        entries: [_entry(_alice)],
        profiles: const {
          _alice: Profile(pubkeyHex: _alice, name: 'Alex'),
        },
        circleNamesByPubkey: {
          _alice: ['Family'],
          _bob: ['Family'],
        },
      );

      expect(directory.entries, hasLength(1));
      // A lone tier-0 candidate is never a collision, whatever the
      // (unmatched) collision map says about someone else.
      expect(directory.entries.single.collisionCircleName, isNull);
    });
  });

  group('collision disambiguation — invisible-character spoofing', () {
    // `sanitize_display_name` (haven-core/src/circle/types.rs) deliberately
    // KEEPS a short list of invisible-but-legible characters as real
    // orthography (ZWNJ, ZWJ, LRM/RLM/ALM, VS-16, emoji tags —
    // `KEPT_INVISIBLES` in that file). A circle named with one of them
    // renders identically to the plain name while surviving sanitization, so
    // comparing circle names as raw strings lets a spoofed name defeat the
    // very disambiguator built to tell two same-named people apart
    // (`the_search_fold_collapses_every_invisible_the_sanitizer_keeps` in
    // that same file is the Rust half of this fix). `fold_for_search`
    // strips the whole class; `flutter test` never calls `RustLib.init()`,
    // so these tests inject a recorded fold rather than the production
    // default, which degrades to plain `toLowerCase` and would not catch a
    // regression back to raw comparison.
    const foldSource = '../haven-core/src/circle/types.rs';
    const zwnj = '\u200C'; // ZERO WIDTH NON-JOINER, spelled out — invisible.
    const spoofedFamily = 'Fam${zwnj}ily';

    // The two entries below are RECORDED `fold_for_search` outputs (see
    // `haven-core/src/circle/types.rs`'s
    // `the_search_fold_collapses_every_invisible_the_sanitizer_keeps`);
    // everything else falls back to a plain casefold — the same bound
    // `fallbackSearchFold` itself has — which is uncontroversial for the
    // plain-ASCII display names ('Alex') this suite's profiles use and
    // cannot mask a regression in the two recorded vectors under test.
    String recordedFold(String value) {
      const invisibleStripped = {'Family': 'family', spoofedFamily: 'family'};
      return invisibleStripped[value] ?? value.toLowerCase();
    }

    test(
      'a circle name differing only by an invisible character the '
      'sanitizer keeps is not treated as distinguishing',
      () {
        // The exact attack: two circles that RENDER identically as
        // "Family" — one plain, one padded with a character the sanitizer
        // keeps — used to disambiguate two same-named co-members. Folded,
        // they are the same circle to the disambiguator, so neither row
        // gets a false "these are different" note; the npub remains their
        // differentiator.
        final directory = buildDirectory(
          entries: [_entry(_alice), _entry(_bob)],
          profiles: const {
            _alice: Profile(pubkeyHex: _alice, name: 'Alex'),
            _bob: Profile(pubkeyHex: _bob, name: 'Alex'),
          },
          circleNamesByPubkey: {
            _alice: ['Family'],
            _bob: [spoofedFamily],
          },
          fold: recordedFold,
        );

        expect(
          directory.entries.map((c) => c.collisionCircleName),
          everyElement(isNull),
        );
      },
    );

    test(
      'an all-invisible circle name yields no label rather than an empty '
      'one',
      () {
        // `sanitize_display_name` returns the EMPTY string for a circle
        // name built entirely from invisible characters. Without the
        // guard, '' sorts before every real name and would be picked and
        // rendered as a blank note.
        final directory = buildDirectory(
          entries: [_entry(_alice), _entry(_bob)],
          profiles: const {
            _alice: Profile(pubkeyHex: _alice, name: 'Alex'),
            _bob: Profile(pubkeyHex: _bob, name: 'Alex'),
          },
          circleNamesByPubkey: {
            _alice: ['', 'Family'],
            _bob: ['Different'],
          },
        );

        final alice = directory.entries.firstWhere(
          (c) => c.pubkeyHex == _alice,
        );
        expect(alice.collisionCircleName, equals('Family'));
        expect(alice.collisionCircleName, isNot(equals('')));
      },
    );

    test(
      'the shown note is the raw sanitized name, never the folded key',
      () {
        final directory = buildDirectory(
          entries: [_entry(_alice), _entry(_bob)],
          profiles: const {
            _alice: Profile(pubkeyHex: _alice, name: 'Alex'),
            _bob: Profile(pubkeyHex: _bob, name: 'Alex'),
          },
          circleNamesByPubkey: {
            _alice: ['Zebra'],
          },
          fold: (v) => v.toLowerCase(),
        );

        final alice = directory.entries.firstWhere(
          (c) => c.pubkeyHex == _alice,
        );
        expect(alice.collisionCircleName, equals('Zebra'));
      },
    );

    test(
      'the alphabetically-first choice is made on the raw name, not the '
      'folded one',
      () {
        // Raw code-unit order puts capital-first 'Banana' before lower-case
        // 'apple' ('B' < 'a'); a lower-casing fold would reverse that pick
        // if the sort ran on folded values instead of raw ones.
        final directory = buildDirectory(
          entries: [_entry(_alice), _entry(_bob)],
          profiles: const {
            _alice: Profile(pubkeyHex: _alice, name: 'Alex'),
            _bob: Profile(pubkeyHex: _bob, name: 'Alex'),
          },
          circleNamesByPubkey: {
            _alice: ['Banana', 'apple'],
          },
          fold: (v) => v.toLowerCase(),
        );

        final alice = directory.entries.firstWhere(
          (c) => c.pubkeyHex == _alice,
        );
        expect(alice.collisionCircleName, equals('Banana'));
      },
    );

    test(
      'the recorded fold outputs above are pinned to haven-core, so the '
      'vectors cannot silently drift from the spec',
      () {
        final file = File(foldSource);
        if (!file.existsSync()) {
          fail('cannot read $foldSource to pin the recorded fold outputs');
        }
        final code = file.readAsStringSync();
        expect(
          code,
          contains(
            'the_search_fold_collapses_every_invisible_the_sanitizer_keeps',
          ),
        );
        expect(code, contains(r"'\u{200C}',  // ZWNJ"));
      },
    );
  });

  group('MemberDirectory', () {
    test('empty carries no entries', () {
      expect(MemberDirectory.empty.entries, isEmpty);
    });

    test('empty is not degraded', () {
      expect(MemberDirectory.empty.degraded, isFalse);
    });

    test('readFailed is degraded and carries no entries', () {
      expect(MemberDirectory.readFailed.entries, isEmpty);
      expect(MemberDirectory.readFailed.degraded, isTrue);
    });

    test('empty and readFailed both have no entries but are not equal', () {
      // The whole point of the marker: two directories with the same
      // (empty) entry list must still compare unequal when one represents a
      // genuine failure and the other a genuinely empty result.
      expect(MemberDirectory.empty, isNot(equals(MemberDirectory.readFailed)));
    });

    test('compares by value so a rebuild with equal rows is not a change', () {
      final a = buildDirectory(entries: [_entry(_alice)], profiles: const {});
      final b = buildDirectory(entries: [_entry(_alice)], profiles: const {});

      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
    });

    test('rejects mutation of the rendered entry list', () {
      final directory = buildDirectory(
        entries: [_entry(_alice)],
        profiles: const {},
      );

      expect(directory.entries.clear, throwsUnsupportedError);
    });
  });

  group('debug output', () {
    test('a candidate never prints a whole pubkey or a name', () {
      // `toString` reaches logs and crash reports. A full pubkey there is an
      // identifier outside the encrypted store, and a name is someone else's
      // published data the user never asked Haven to log (Security Rule 8).
      final printed = buildMemberCandidate(
        entry: _entry(_alice),
        petname: 'Landlord',
        profile: const Profile(pubkeyHex: _alice, displayName: 'Alice'),
      ).toString();

      expect(printed, isNot(contains(_alice)));
      expect(printed, isNot(contains('Landlord')));
      expect(printed, isNot(contains('Alice')));
      expect(printed, contains(_alice.substring(0, 8)));
    });

    test('a candidate with a short key prints instead of throwing', () {
      // `toString` is what an error path reaches for. A value type whose
      // debug output can raise turns one diagnostic into two failures, and
      // the shortened key is the whole point of the output above.
      const candidate = MemberCandidate(
        pubkeyHex: 'ab12',
        npub: 'npub1ab12',
        nameKey: '',
        searchKeys: <String>[],
      );

      expect(candidate.toString, returnsNormally);
      expect(candidate.toString(), contains('ab12'));
    });

    test('a directory entry with a short key prints instead of throwing',
        () {
      // Sibling guard to the candidate one above — an unguarded
      // `substring(0, 8)` here throws for anything shorter than 8 hex
      // characters, turning one diagnostic into two failures.
      const entry = DirectoryEntry(
        pubkeyHex: 'ab12',
        npub: 'npub1ab12',
        tier: DirectoryTier.current,
      );

      expect(entry.toString, returnsNormally);
      expect(entry.toString(), contains('ab12'));
    });

    test('a directory prints only how many people it holds', () {
      final printed = buildDirectory(
        entries: [_entry(_alice), _entry(_bob)],
        profiles: const {
          _alice: Profile(pubkeyHex: _alice, displayName: 'Alice'),
        },
      ).toString();

      expect(printed, equals('MemberDirectory(2)'));
    });
  });
}
