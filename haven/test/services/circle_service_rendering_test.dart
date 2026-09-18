/// What `circle_service.dart`'s value types are allowed to say about
/// themselves when something interpolates them.
///
/// A `toString()` is a log line: it renders the moment the object reaches a
/// `debugPrint`, a thrown message, a Flutter error dump or a failing
/// `expect`'s `Actual:` line. So Security Rule 15 applies to it in full — no
/// pubkey (not even a prefix), no circle name, and no exact member count,
/// which is the single most fingerprinting number this app holds.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/rust/api.dart' show LogAliasClassFfi;
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/utils/log_alias.dart';

const _alice =
    'a11ce0000000000000000000000000000000000000000000000000000000cafe';

CircleMember _member(int index) => CircleMember(
  pubkey: '${index}0000000000000000000000000000000000000'
      '00000000000000000000000dad',
  npub: 'npub1member$index',
  isAdmin: false,
);

Circle _circleOf(List<CircleMember> members) => Circle(
  mlsGroupId: const [1],
  nostrGroupId: const [2],
  displayName: 'Weekend Hikers',
  circleType: CircleType.locationSharing,
  relays: const ['wss://relay.example.com'],
  membershipStatus: MembershipStatus.accepted,
  members: members,
  createdAt: DateTime.utc(2024),
  updatedAt: DateTime.utc(2024),
);

void main() {
  group('Circle', () {
    test('renders a member magnitude, never the exact roster size', () {
      final rendered = _circleOf([
        for (var i = 0; i < 7; i++) _member(i),
      ]).toString();

      expect(rendered, equals('Circle(members: 5+)'));
      expect(
        rendered,
        isNot(contains('7')),
        reason: 'an exact roster size tells one circle apart from another',
      );
    });

    test('renders neither the circle name nor either group id', () {
      final rendered = _circleOf([_member(0)]).toString();

      expect(rendered, isNot(contains('Weekend Hikers')));
      expect(rendered, isNot(contains('wss://')));
      expect(rendered, equals('Circle(members: 1)'));
    });

    test('an empty circle is still distinguishable from a single member', () {
      // The bucket boundary that matters for diagnostics: "nobody" and
      // "one person" are different states, and both are magnitudes.
      expect(_circleOf(const []).toString(), equals('Circle(members: 0)'));
    });
  });

  group('CircleMember', () {
    test('renders no pubkey, not even a prefix', () {
      const rendered = CircleMember(
        pubkey: _alice,
        npub: 'npub1alice',
        isAdmin: true,
        displayName: 'Alice',
      );

      final printed = rendered.toString();
      expect(printed, isNot(contains(_alice)));
      expect(printed, isNot(contains(_alice.substring(0, 8))));
      expect(printed, isNot(contains('npub1alice')));
      expect(printed, isNot(contains('Alice')));
      // A per-process salted handle takes its place, so two lines in one run
      // can still say "the same peer" without naming them.
      expect(printed, startsWith('CircleMember(peer#'));
    });

    test('a real handle renders in the alias shape, never the key', () {
      // Every other assertion here runs without the Rust bridge, where
      // `logAliasHandle` degrades to a fixed `peer#??????`. That marker would
      // satisfy `isNot(contains(pubkey))` even if the real binding returned
      // the key verbatim, so one test drives a REAL-SHAPED handle through.
      final original = logAliasFfiCall;
      addTearDown(() {
        logAliasFfiCall = original;
        clearLogAliasMemo();
      });
      clearLogAliasMemo();
      logAliasFfiCall =
          ({required LogAliasClassFfi class_, required String value}) =>
              'peer#a91f3c';

      const member = CircleMember(
        pubkey: _alice,
        npub: 'npub1alice',
        isAdmin: false,
      );

      expect(member.toString(), 'CircleMember(peer#a91f3c)');
      expect(member.toString(), isNot(contains(_alice.substring(0, 6))));
    });

    test('a short key renders instead of throwing', () {
      // `toString` is what an error path reaches for; a value type whose
      // debug output can raise turns one diagnostic into two failures.
      const member = CircleMember(
        pubkey: 'ab12',
        npub: 'npub1ab12',
        isAdmin: false,
      );

      expect(member.toString, returnsNormally);
      expect(member.toString(), isNot(contains('ab12')));
    });
  });
}
