/// Tests for [NostrMemberDirectoryService] — the thin I/O shell that turns
/// the persistent member directory, the local profile cache and the local
/// contact (petname) cache into a [MemberDirectory] (P1-P3).
///
/// The promises under test are the ones a picker cannot degrade gracefully
/// without: it never throws, it never touches the network, it never hides a
/// co-member just because their profile has not resolved, and no raw error
/// text — from any of its three reads — ever survives into a rendered row.
library;

import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/services/identity_service.dart';
import 'package:haven/src/services/member_directory_service.dart';
import 'package:haven/src/services/nostr_member_directory_service.dart';
import 'package:haven/src/services/profile_service.dart';

import '../mocks/mock_circle_service.dart';
import '../mocks/mock_profile_service.dart';

const _alice =
    'a11ce0000000000000000000000000000000000000000000000000000000cafe';
const _bob =
    'b0b0000000000000000000000000000000000000000000000000000000000dad';
const _self =
    '5e1f0000000000000000000000000000000000000000000000000000000000ff';

final _identity = Identity(
  pubkeyHex: _self,
  npub: 'npub1self',
  createdAt: DateTime(2026),
);

class _FakeIdentityService implements IdentityService {
  _FakeIdentityService({this.identity, this.throwOnGetIdentity = false});

  final Identity? identity;
  final bool throwOnGetIdentity;

  @override
  Future<bool> hasIdentity() async => identity != null;

  @override
  Future<Identity?> getIdentity() async {
    if (throwOnGetIdentity) {
      throw const IdentityServiceException('identity read failed');
    }
    return identity;
  }

  @override
  Future<Identity> createIdentity() => throw UnimplementedError();

  @override
  Future<Identity> importFromNsec(String nsec) => throw UnimplementedError();

  @override
  Future<String> exportNsec() => throw UnimplementedError();

  @override
  Future<String> sign(Uint8List messageHash) => throw UnimplementedError();

  @override
  Future<String> getPubkeyHex() async => identity!.pubkeyHex;

  @override
  Future<List<int>> getSecretBytes() => throw UnimplementedError();

  @override
  Future<void> deleteIdentity() => throw UnimplementedError();

  @override
  Future<String?> getDisplayName() async => null;

  @override
  Future<void> setDisplayName(String? name) => throw UnimplementedError();

  @override
  Future<void> clearCache() async {}
}

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

CircleMember _member(String pubkey) {
  return CircleMember(
    pubkey: pubkey,
    npub: 'npub1${pubkey.substring(0, 58)}',
    isAdmin: false,
  );
}

Circle _circle(List<CircleMember> members, {int id = 1, String name = 'C'}) {
  return Circle(
    mlsGroupId: [id],
    nostrGroupId: [id],
    displayName: name,
    circleType: CircleType.locationSharing,
    relays: const [],
    membershipStatus: MembershipStatus.accepted,
    members: members,
    createdAt: DateTime(2026),
    updatedAt: DateTime(2026),
  );
}

NostrMemberDirectoryService _service({
  required MockCircleService circleService,
  required MockProfileService profileService,
  Identity? identity,
  bool throwOnGetIdentity = false,
}) {
  return NostrMemberDirectoryService(
    circleServiceFactory: () => circleService,
    profileService: profileService,
    identityService: _FakeIdentityService(
      identity: identity,
      throwOnGetIdentity: throwOnGetIdentity,
    ),
  );
}

void main() {
  group('loadDirectory', () {
    test('lists current co-members with their cached names', () async {
      final directory = await _service(
        circleService: MockCircleService()
          ..directoryEntries = [_entry(_alice), _entry(_bob)],
        profileService: MockProfileService(
          memberProfiles: {
            _alice: const Profile(pubkeyHex: _alice, displayName: 'Alice'),
            _bob: const Profile(pubkeyHex: _bob, displayName: 'Bob'),
          },
        ),
        identity: _identity,
      ).loadDirectory(circles: const []);

      expect(
        directory.entries.map((c) => c.displayName),
        orderedEquals(<String>['Alice', 'Bob']),
      );
    });

    test('lists a co-member with no cached profile, by npub', () async {
      // R2 must not silently hide people. A member Haven has resolved
      // nothing about is still someone you share a circle with.
      final directory = await _service(
        circleService: MockCircleService()..directoryEntries = [_entry(_alice)],
        profileService: MockProfileService(),
        identity: _identity,
      ).loadDirectory(circles: const []);

      expect(directory.entries, hasLength(1));
      expect(directory.entries.single.pubkeyHex, equals(_alice));
      expect(directory.entries.single.displayName, isNull);
      expect(directory.entries.single.npub, isNotEmpty);
    });

    test('reads the whole directory in ONE profile batch call, not one call '
        'per person', () async {
      // Serialised per-person reads make picker-open cost scale with the
      // roster: three SQLCipher queries each, awaited one after another.
      final profileService = MockProfileService();
      await _service(
        circleService: MockCircleService()
          ..directoryEntries = [_entry(_alice), _entry(_bob)],
        profileService: profileService,
        identity: _identity,
      ).loadDirectory(circles: const []);

      expect(profileService.methodCalls, hasLength(1));
      expect(
        profileService.methodCalls.single.method,
        equals('getCachedMemberProfiles'),
      );
      expect(
        profileService.methodCalls.single.args['pubkeyHexes'],
        orderedEquals(<String>[_alice, _bob]),
      );
    });

    test('never asks the profile service to touch the network', () async {
      // R2/R4 promise zero new wire traffic. Asserted as a call COUNT
      // first: `everyElement` over the calls that were made is vacuously
      // true for a load that read nothing at all.
      final profileService = MockProfileService();
      final directory = await _service(
        circleService: MockCircleService()
          ..directoryEntries = [_entry(_alice), _entry(_bob)],
        profileService: profileService,
        identity: _identity,
      ).loadDirectory(circles: const []);

      expect(directory.entries, hasLength(2));
      expect(profileService.methodCalls, hasLength(1));
      expect(
        profileService.methodCalls.single.method,
        equals('getCachedMemberProfiles'),
      );
    });

    test('never asks for picture bytes it would immediately drop', () async {
      // A [MemberCandidate] keeps only [MemberCandidate.pictureHash]; the
      // bytes a per-person `getMemberProfile` fetches are decrypted,
      // marshalled across FFI and thrown away, one 96px thumbnail per
      // person with a picture.
      final profileService = MockProfileService(
        memberProfiles: {
          _alice: const Profile(
            pubkeyHex: _alice,
            displayName: 'Alice',
            pictureHash: 'hash-a',
          ),
        },
      );
      final directory = await _service(
        circleService: MockCircleService()..directoryEntries = [_entry(_alice)],
        profileService: profileService,
        identity: _identity,
      ).loadDirectory(circles: const []);

      expect(directory.entries.single.pictureHash, equals('hash-a'));
      expect(
        profileService.methodCalls.map((c) => c.method),
        isNot(contains('getMemberProfile')),
      );
    });

    test(
      'a member added by an applied commit who has never sent a message '
      'still appears in tier 0',
      () async {
        // The whole regression class this must resist: gating tier 0 on any
        // participation signal (a message, a resolved name, a picture).
        // The directory entry's OWN tier is the only input that may decide
        // this — nothing this service reads can add or remove that.
        final directory = await _service(
          circleService: MockCircleService()
            ..directoryEntries = [_entry(_alice)],
          profileService: MockProfileService(),
          identity: _identity,
        ).loadDirectory(circles: const []);

        expect(directory.entries, hasLength(1));
        expect(directory.entries.single.tier, DirectoryTier.current);
      },
    );

    test('a tier-1 (recent) entry renders under its own tier', () async {
      final directory = await _service(
        circleService: MockCircleService()
          ..directoryEntries = [_entry(_bob, tier: DirectoryTier.recent)],
        profileService: MockProfileService(),
        identity: _identity,
      ).loadDirectory(circles: const []);

      expect(directory.entries.single.tier, DirectoryTier.recent);
    });
  });

  group('local petnames', () {
    test('reads petnames for the whole directory in ONE batch call',
        () async {
      final circleService = MockCircleService()
        ..directoryEntries = [_entry(_alice)]
        ..contactDisplayNames = {_alice: 'Landlord'};

      final directory = await _service(
        circleService: circleService,
        profileService: MockProfileService(),
        identity: _identity,
      ).loadDirectory(circles: const []);

      expect(directory.entries.single.petname, equals('Landlord'));
      expect(
        circleService.methodCalls.where((c) => c == 'allContactDisplayNames'),
        hasLength(1),
      );
    });

    test('a petname-read failure costs only nicknames, never the whole '
        'directory', () async {
      // Losing this input must never surface as an exception's text — the
      // person simply keeps whatever the profile cache resolved.
      final circleService = MockCircleService()
        ..directoryEntries = [_entry(_alice)]
        ..shouldThrowOnAllContactDisplayNames = true;

      final directory = await _service(
        circleService: circleService,
        profileService: MockProfileService(
          memberProfiles: {
            _alice: const Profile(pubkeyHex: _alice, displayName: 'Alice'),
          },
        ),
        identity: _identity,
      ).loadDirectory(circles: const []);

      expect(directory.entries, hasLength(1));
      expect(directory.entries.single.petname, isNull);
      expect(directory.entries.single.displayName, equals('Alice'));
    });
  });

  group('collision-name disambiguation (plan §7.2)', () {
    test('uses the CALLER-supplied circles list to disambiguate a tier-0 '
        'name collision, picking a circle that actually sets each row apart',
        () async {
      // A circle both share ('Family') cannot be either row's disambiguator
      // — it reads the same on both — so each needs a roster the OTHER
      // person is not also on.
      final circles = [
        _circle([_member(_alice), _member(_bob)], name: 'Family'),
        _circle([_member(_alice)], id: 2, name: 'Alice Circle'),
        _circle([_member(_bob)], id: 3, name: 'Bob Circle'),
      ];

      final directory = await _service(
        circleService: MockCircleService()
          ..directoryEntries = [_entry(_alice), _entry(_bob)],
        profileService: MockProfileService(
          memberProfiles: {
            _alice: const Profile(pubkeyHex: _alice, displayName: 'Alex'),
            _bob: const Profile(pubkeyHex: _bob, displayName: 'Alex'),
          },
        ),
        identity: _identity,
      ).loadDirectory(circles: circles);

      final byHex = {for (final c in directory.entries) c.pubkeyHex: c};
      expect(byHex[_alice]!.collisionCircleName, equals('Alice Circle'));
      expect(byHex[_bob]!.collisionCircleName, equals('Bob Circle'));
    });

    test('shows no disambiguator when the only circle two colliding rows '
        'share is one both are on — it would read the same on both', () async {
      // Regression coverage: naming each row its OWN alphabetically-first
      // circle independently (rather than one that sets it apart from the
      // other) used to hand both rows the identical 'Family' note here,
      // disambiguating nothing.
      final circles = [
        _circle([_member(_alice), _member(_bob)], name: 'Family'),
      ];

      final directory = await _service(
        circleService: MockCircleService()
          ..directoryEntries = [_entry(_alice), _entry(_bob)],
        profileService: MockProfileService(
          memberProfiles: {
            _alice: const Profile(pubkeyHex: _alice, displayName: 'Alex'),
            _bob: const Profile(pubkeyHex: _bob, displayName: 'Alex'),
          },
        ),
        identity: _identity,
      ).loadDirectory(circles: circles);

      expect(
        directory.entries.map((c) => c.collisionCircleName),
        everyElement(isNull),
      );
    });

    test('no collision when the resolved names differ', () async {
      final circles = [
        _circle([_member(_alice), _member(_bob)], name: 'Family'),
      ];

      final directory = await _service(
        circleService: MockCircleService()
          ..directoryEntries = [_entry(_alice), _entry(_bob)],
        profileService: MockProfileService(
          memberProfiles: {
            _alice: const Profile(pubkeyHex: _alice, displayName: 'Alice'),
            _bob: const Profile(pubkeyHex: _bob, displayName: 'Bob'),
          },
        ),
        identity: _identity,
      ).loadDirectory(circles: circles);

      expect(
        directory.entries.map((c) => c.collisionCircleName),
        everyElement(isNull),
      );
    });

    test('an empty (or non-collision-relevant) circles list costs only the '
        'disambiguator, never a co-members row', () async {
      // What upstream degradation looks like from here: `circlesProvider`
      // never throws (it degrades to `[]`), so this service never sees a
      // circles-list failure — only, at worst, an empty list.
      final directory = await _service(
        circleService: MockCircleService()
          ..directoryEntries = [_entry(_alice), _entry(_bob)],
        profileService: MockProfileService(
          memberProfiles: {
            _alice: const Profile(pubkeyHex: _alice, displayName: 'Alex'),
            _bob: const Profile(pubkeyHex: _bob, displayName: 'Alex'),
          },
        ),
        identity: _identity,
      ).loadDirectory(circles: const []);

      expect(directory.entries, hasLength(2));
      expect(
        directory.entries.map((c) => c.collisionCircleName),
        everyElement(isNull),
      );
    });

    test('never calls getVisibleCircles — the collision list comes from the '
        'caller, never a second walk of the same rosters', () async {
      final circleService = MockCircleService()
        ..directoryEntries = [_entry(_alice), _entry(_bob)];

      await _service(
        circleService: circleService,
        profileService: MockProfileService(
          memberProfiles: {
            _alice: const Profile(pubkeyHex: _alice, displayName: 'Alex'),
            _bob: const Profile(pubkeyHex: _bob, displayName: 'Alex'),
          },
        ),
        identity: _identity,
      ).loadDirectory(
        circles: [
          _circle([_member(_alice), _member(_bob)], name: 'Family'),
        ],
      );

      expect(circleService.methodCalls, isNot(contains('getVisibleCircles')));
    });
  });

  group('backfill reconcile (upgrade path)', () {
    test('reconciles once per service instance, not once per picker open',
        () async {
      final circleService = MockCircleService();
      final service = _service(
        circleService: circleService,
        profileService: MockProfileService(),
        identity: _identity,
      );

      await service.loadDirectory(circles: const []);
      await service.loadDirectory(circles: const []);
      await service.loadDirectory(circles: const []);

      expect(circleService.reconcileMemberDirectoryCallCount, equals(1));
    });

    test('a backfill failure does not block the load', () async {
      final circleService = MockCircleService()
        ..directoryEntries = [_entry(_alice)]
        ..shouldThrowOnReconcileMemberDirectory = true;

      final directory = await _service(
        circleService: circleService,
        profileService: MockProfileService(),
        identity: _identity,
      ).loadDirectory(circles: const []);

      expect(directory.entries, hasLength(1));
    });

    test('a GENUINE backfill failure latches — it is never retried on a '
        'later picker open', () async {
      final circleService = MockCircleService()
        ..directoryEntries = [_entry(_alice)]
        ..shouldThrowOnReconcileMemberDirectory = true;
      final service = _service(
        circleService: circleService,
        profileService: MockProfileService(),
        identity: _identity,
      );

      await service.loadDirectory(circles: const []);
      await service.loadDirectory(circles: const []);

      expect(circleService.reconcileMemberDirectoryCallCount, equals(1));
    });

    test('a DEFERRED backfill (a circle mid-publish; nothing written) is '
        'retried on the next picker open, unlike a genuine failure', () async {
      // `reconcileMemberDirectory` returning `false` is the cheap, transient
      // case — a circle's membership commit was still in flight when the
      // one-time backfill attempt landed. Latching it the way a genuine
      // failure latches would leave an upgraded install's picker silently
      // empty for the rest of the process if that attempt happened to land
      // in the window (e.g. add-member tapped right after create-circle).
      final circleService = MockCircleService()
        ..reconcileMemberDirectoryResult = false;
      final service = _service(
        circleService: circleService,
        profileService: MockProfileService(),
        identity: _identity,
      );

      await service.loadDirectory(circles: const []);
      await service.loadDirectory(circles: const []);
      await service.loadDirectory(circles: const []);

      expect(circleService.reconcileMemberDirectoryCallCount, equals(3));
    });

    test('once a deferred backfill later converges, it stops retrying',
        () async {
      final circleService = MockCircleService()
        ..reconcileMemberDirectoryResult = false;
      final service = _service(
        circleService: circleService,
        profileService: MockProfileService(),
        identity: _identity,
      );

      await service.loadDirectory(circles: const []);
      circleService.reconcileMemberDirectoryResult = true;
      await service.loadDirectory(circles: const []);
      await service.loadDirectory(circles: const []);

      expect(circleService.reconcileMemberDirectoryCallCount, equals(2));
    });

    test('the backfill runs BEFORE the ranked read, so an upgraded install '
        'is not empty on the very first open', () async {
      // Simulates the real relationship: on a device that predates P3, the
      // table is empty until reconcile populates it — the ranked read that
      // follows must see what the reconcile just wrote, not a stale empty
      // table read moments earlier.
      final circleService = MockCircleService()
        ..reconcileMemberDirectoryEffect = (mock) {
          mock.directoryEntries = [_entry(_alice)];
        };

      final directory = await _service(
        circleService: circleService,
        profileService: MockProfileService(),
        identity: _identity,
      ).loadDirectory(circles: const []);

      expect(directory.entries, hasLength(1));
    });
  });

  group('degradation', () {
    test('returns an empty (not degraded) directory when there is no '
        'identity', () async {
      // Without an identity the service cannot tell which directory row is
      // the user, and the user must never appear in their own picker — so
      // it fails closed rather than risk showing them, before reading the
      // circle service at all. This is a fail-closed refusal, not a
      // "something broke" signal, so it stays `.empty`.
      final circleService = MockCircleService()
        ..directoryEntries = [_entry(_alice)];
      final directory = await _service(
        circleService: circleService,
        profileService: MockProfileService(),
      ).loadDirectory(circles: const []);

      expect(directory, equals(MemberDirectory.empty));
      expect(directory.degraded, isFalse);
      expect(circleService.methodCalls, isEmpty);
    });

    test('returns an empty (not degraded) directory when the identity read '
        'fails', () async {
      final directory = await _service(
        circleService: MockCircleService()..directoryEntries = [_entry(_alice)],
        profileService: MockProfileService(),
        throwOnGetIdentity: true,
      ).loadDirectory(circles: const []);

      expect(directory, equals(MemberDirectory.empty));
      expect(directory.degraded, isFalse);
    });

    test('returns a DEGRADED directory when the ranked-directory read fails',
        () async {
      // Distinct from a legitimately-empty directory (below): a user with
      // real co-members must not be shown the fresh-install "you have
      // nobody yet" guidance because a query happened to throw.
      final directory = await _service(
        circleService: MockCircleService()
          ..shouldThrowOnRankedDirectoryMembers = true,
        profileService: MockProfileService(),
        identity: _identity,
      ).loadDirectory(circles: const []);

      expect(directory, equals(MemberDirectory.readFailed));
      expect(directory.degraded, isTrue);
      expect(directory, isNot(equals(MemberDirectory.empty)));
    });

    test('a directory that genuinely finds nobody is empty, never degraded',
        () async {
      final directory = await _service(
        circleService: MockCircleService(),
        profileService: MockProfileService(),
        identity: _identity,
      ).loadDirectory(circles: const []);

      expect(directory, equals(MemberDirectory.empty));
      expect(directory.degraded, isFalse);
    });

    test('lists everyone by npub when the cache resolves nobody', () async {
      // What an unreadable store actually looks like from here: the batch
      // read never throws, it just comes back empty. The accelerator
      // degrades to keys, never to an error state — the screen it
      // accelerates still works by paste and by QR.
      final directory = await _service(
        circleService: MockCircleService()
          ..directoryEntries = [_entry(_alice), _entry(_bob)],
        profileService: MockProfileService(),
        identity: _identity,
      ).loadDirectory(circles: const []);

      expect(
        directory.entries.map((c) => c.pubkeyHex),
        orderedEquals(<String>[_alice, _bob]),
      );
      expect(
        directory.entries.map((c) => c.displayName),
        everyElement(isNull),
      );
    });

    test('returns a DEGRADED directory if the profile read throws anyway',
        () async {
      // The backstop, against a profile service that breaks its own
      // never-throws contract. There is deliberately no second catch around
      // the batch read — this proves the outer one still holds, so the
      // picker degrades instead of putting an exception in front of a field
      // that paste and QR would have filled.
      final service = _service(
        circleService: MockCircleService()
          ..directoryEntries = [_entry(_alice), _entry(_bob)],
        profileService: MockProfileService()
          ..shouldThrowOnGetCachedMemberProfiles = true,
        identity: _identity,
      );

      await expectLater(service.loadDirectory(circles: const []), completes);
      expect(
        await service.loadDirectory(circles: const []),
        equals(MemberDirectory.readFailed),
      );
    });

    test('keeps the people the cache did resolve when one is missing',
        () async {
      // The batch read drops a person it could not resolve — whether the
      // cache never knew them or their row would not read. That must cost
      // that person their name, never the whole directory and never the
      // OTHER rows' names.
      final directory = await _service(
        circleService: MockCircleService()
          ..directoryEntries = [_entry(_alice), _entry(_bob)],
        profileService: MockProfileService(
          memberProfiles: {
            _bob: const Profile(pubkeyHex: _bob, displayName: 'Bob'),
          },
        ),
        identity: _identity,
      ).loadDirectory(circles: const []);

      expect(
        directory.entries.map((c) => c.pubkeyHex),
        orderedEquals(<String>[_bob, _alice]),
      );
      expect(directory.entries.first.displayName, equals('Bob'));
      expect(directory.entries.last.displayName, isNull);
    });

    test('no raw error text from any of the three reads ever survives into '
        'a rendered row (Security Rule 8)', () async {
      final circleService = MockCircleService()
        ..directoryEntries = [_entry(_alice)]
        ..shouldThrowOnAllContactDisplayNames = true;

      final directory = await _service(
        circleService: circleService,
        profileService: MockProfileService(
          memberProfiles: {
            _alice: const Profile(pubkeyHex: _alice, displayName: 'Alice'),
          },
        ),
        identity: _identity,
      ).loadDirectory(circles: const []);

      for (final candidate in directory.entries) {
        expect(candidate.petname, isNull);
        expect(candidate.collisionCircleName, isNull);
        expect(candidate.toString(), isNot(contains('Exception')));
        expect(candidate.toString(), isNot(contains('error')));
      }
    });
  });

  group('memberDirectoryServiceProvider', () {
    test('wires the production implementation from the existing services',
        () async {
      // The DI seam P2 overrides. Reading it also proves the directory opens
      // nothing of its own: with the three services faked, construction and
      // a full load complete with no FFI, no keyring and no relay.
      final container = ProviderContainer(
        overrides: [
          circleServiceProvider.overrideWithValue(
            MockCircleService()..directoryEntries = [_entry(_alice)],
          ),
          profileServiceProvider.overrideWithValue(MockProfileService()),
          identityServiceProvider.overrideWithValue(
            _FakeIdentityService(identity: _identity),
          ),
        ],
      );
      addTearDown(container.dispose);

      final service = container.read(memberDirectoryServiceProvider);

      expect(service, isA<NostrMemberDirectoryService>());
      expect(
        (await service.loadDirectory(circles: const [])).entries,
        hasLength(1),
      );
    });

    test('reads the circle service that replaced an invalidated one',
        () async {
      // `createIdentity`/`importFromNsec` invalidate `circleServiceProvider`
      // so a new identity provisions onto a FRESH instance — the logged-out
      // one is wiped and `_wiped`-latched, and answers empty forever. A
      // directory holding the old instance would show a permanently empty
      // list, with no error, for the rest of the process.
      var built = 0;
      final container = ProviderContainer(
        overrides: [
          circleServiceProvider.overrideWith((ref) {
            built++;
            return MockCircleService()
              ..directoryEntries = [_entry(built == 1 ? _alice : _bob)];
          }),
          profileServiceProvider.overrideWithValue(MockProfileService()),
          identityServiceProvider.overrideWithValue(
            _FakeIdentityService(identity: _identity),
          ),
        ],
      );
      addTearDown(container.dispose);

      final before = await container
          .read(memberDirectoryServiceProvider)
          .loadDirectory(circles: const []);
      expect(before.entries.single.pubkeyHex, equals(_alice));

      container.invalidate(circleServiceProvider);

      final after = await container
          .read(memberDirectoryServiceProvider)
          .loadDirectory(circles: const []);
      expect(after.entries.single.pubkeyHex, equals(_bob));
    });
  });
}
