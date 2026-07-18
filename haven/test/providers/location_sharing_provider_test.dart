/// Tests for memberLocationsProvider self-exclusion behavior and
/// locationPublisherProvider disclosure gate.
///
/// Verifies that:
/// - memberLocationsProvider filters out the current user's own location
/// - memberLocationsProvider returns all locations when identity is null
/// - memberLocationsProvider returns empty list when no circle is selected
/// - memberLocationsProvider returns empty list for non-accepted circles
/// - locationPublisherProvider short-circuits (returns 0, never calls
///   getCurrentLocation) when the disclosure flag is absent from SharedPreferences
/// - locationPublisherProvider proceeds past the gate (calls getCurrentLocation)
///   when the disclosure flag IS set
library;

import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/constants/location.dart';
import 'package:haven/src/providers/circles_provider.dart';
import 'package:haven/src/providers/location_sharing_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/services/identity_service.dart';
import 'package:haven/src/services/location_service.dart';
import 'package:haven/src/services/location_sharing_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../mocks/mock_circle_service.dart';
import '../mocks/mock_profile_service.dart';
import '../mocks/mock_relay_service.dart';

// A pubkey that represents the current user (64 hex chars = 32 bytes).
const _selfPubkey =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

// A pubkey that represents another circle member.
const _otherPubkey =
    'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

// A second other-member pubkey for multi-member tests.
const _anotherPubkey =
    'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc';

/// Creates a non-expired [MemberLocation] with the given [pubkey].
MemberLocation _makeLoc(String pubkey, {double latitude = 37}) =>
    MemberLocation(
      pubkey: pubkey,
      latitude: latitude,
      longitude: -122,
      geohash: '9q8',
      timestamp: DateTime.now(),
      expiresAt: DateTime.now().add(const Duration(hours: 23)),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // ---------------------------------------------------------------------------
  // Helper: build a ProviderContainer with controlled dependencies.
  // ---------------------------------------------------------------------------

  /// Builds a [ProviderContainer] with:
  /// - [selectedCircleIdProvider] pre-set to select a circle
  /// - [circlesProvider] overridden to return the selected circle
  /// - [identityServiceProvider] returning the given [identity]
  /// - [locationSharingServiceProvider] backed by a [MockCircleService] that
  ///   decrypts to [locations]
  ///
  /// The service's in-memory location cache is ALSO seeded with [locations] so
  /// that `memberLocationsProvider`'s live-sync read path (the
  /// `if (liveSyncEnabled)` branch that calls `cachedLocations` instead of
  /// polling) returns the same set the poll path decrypts. This mirrors
  /// production, where the live-sync engine populates the cache via
  /// `ingestStreamedLocation` before invalidating the provider. The service is
  /// built WITHOUT an `IdentityService`, so `_resolveOwnPubkey()` resolves null
  /// and ingest keeps every seeded location (including self) — the provider's
  /// OWN self-exclusion filter is what removes self, exercised identically
  /// under both the poll (flag-off) and cache (flag-on) branches. Returns a
  /// `Future` because the cache seed awaits async ingest.
  Future<ProviderContainer> buildContainer({
    required Identity? identity,
    required List<MemberLocation> locations,
    Circle? circle,
  }) async {
    final mockIdentityService = _MockIdentityService(identity: identity);

    // Prime the mock circle service with decrypt results so that
    // LocationSharingService.fetchMemberLocations returns [locations].
    // We drive it by injecting a custom relay that returns one fake event JSON
    // per desired location, and a custom circle service that maps each decrypt
    // call to the corresponding location.
    final fakeEvents = List.generate(
      locations.length,
      (i) => '{"id":"evt$i","kind":445,"content":"enc$i"}',
    );

    final mockRelay = MockRelayService(groupMessages: fakeEvents);
    final mockCircle = MockCircleService()
      ..decryptLocationResults = locations
          .map(
            (loc) => [
              LocationEventResult(
                kind: LocationEventKind.location,
                location: DecryptedLocation(
                  senderPubkey: loc.pubkey,
                  latitude: loc.latitude,
                  longitude: loc.longitude,
                  geohash: loc.geohash,
                  timestamp: loc.timestamp,
                  expiresAt: loc.expiresAt,
                ),
                mlsGroupId: const [],
                epoch: 0,
              ),
            ],
          )
          .toList();

    final locationService = LocationSharingService(
      circleService: mockCircle,
      relayService: mockRelay,
    );

    final selectedCircle = circle ?? TestCircleFactory.createCircle();

    // Seed the in-memory cache so the flag-on `cachedLocations` read path
    // returns [locations] (see the doc comment above). Idempotent w.r.t. the
    // poll path: the poll's per-sender timestamp-wins merge reproduces the same
    // set, so the flag-off assertions are byte-for-byte unchanged.
    for (final loc in locations) {
      await locationService.ingestStreamedLocation(
        circle: selectedCircle,
        decrypted: DecryptedLocation(
          senderPubkey: loc.pubkey,
          latitude: loc.latitude,
          longitude: loc.longitude,
          geohash: loc.geohash,
          timestamp: loc.timestamp,
          expiresAt: loc.expiresAt,
        ),
      );
    }

    final container = ProviderContainer(
      overrides: [
        identityServiceProvider.overrideWithValue(mockIdentityService),
        locationSharingServiceProvider.overrideWithValue(locationService),
        // Override the derived selectedCircleProvider directly so it
        // resolves synchronously without waiting for circlesProvider.
        selectedCircleProvider.overrideWithValue(selectedCircle),
        // `_withEffectiveNames` (plan D6/F4) resolves each location's
        // effective name via `ProfileService.getMemberProfile` whenever
        // `publicProfilesEnabled` is on (the default) — override with a
        // no-op mock so this self-exclusion test never reaches the real
        // FFI-backed `NostrProfileService` (which needs a live keyring).
        profileServiceProvider.overrideWithValue(MockProfileService()),
      ],
    );
    return container;
  }

  // ---------------------------------------------------------------------------
  // Group: self-exclusion
  // ---------------------------------------------------------------------------

  group('memberLocationsProvider — self-exclusion', () {
    test(
      'excludes the entry whose pubkey matches the current user identity',
      () async {
        final identity = Identity(
          pubkeyHex: _selfPubkey,
          npub: 'npub1self',
          createdAt: DateTime(2025),
        );

        // Service returns two locations: self + another member.
        final locations = [_makeLoc(_selfPubkey), _makeLoc(_otherPubkey)];

        final container = await buildContainer(
          identity: identity,
          locations: locations,
        );
        addTearDown(container.dispose);

        final result = await container.read(memberLocationsProvider.future);

        // Self must be absent.
        expect(
          result.any((loc) => loc.pubkey == _selfPubkey),
          isFalse,
          reason:
              "memberLocationsProvider must filter out the current user's "
              'own pubkey ($_selfPubkey)',
        );
        // The other member must remain.
        expect(result.any((loc) => loc.pubkey == _otherPubkey), isTrue);
        expect(result.length, 1);
      },
    );

    test(
      'excludes only self when multiple other members are present',
      () async {
        final identity = Identity(
          pubkeyHex: _selfPubkey,
          npub: 'npub1self',
          createdAt: DateTime(2025),
        );

        final locations = [
          _makeLoc(_selfPubkey),
          _makeLoc(_otherPubkey, latitude: 38),
          _makeLoc(_anotherPubkey, latitude: 39),
        ];

        final container = await buildContainer(
          identity: identity,
          locations: locations,
        );
        addTearDown(container.dispose);

        final result = await container.read(memberLocationsProvider.future);

        expect(result.length, 2);
        expect(result.any((loc) => loc.pubkey == _selfPubkey), isFalse);
        expect(result.any((loc) => loc.pubkey == _otherPubkey), isTrue);
        expect(result.any((loc) => loc.pubkey == _anotherPubkey), isTrue);
      },
    );

    test(
      'returns all other locations when self location is absent from results',
      () async {
        final identity = Identity(
          pubkeyHex: _selfPubkey,
          npub: 'npub1self',
          createdAt: DateTime(2025),
        );

        // Service only returns locations for other members — self is absent.
        final locations = [_makeLoc(_otherPubkey), _makeLoc(_anotherPubkey)];

        final container = await buildContainer(
          identity: identity,
          locations: locations,
        );
        addTearDown(container.dispose);

        final result = await container.read(memberLocationsProvider.future);

        // Both non-self locations must be returned.
        expect(result.length, 2);
        expect(result.any((loc) => loc.pubkey == _otherPubkey), isTrue);
        expect(result.any((loc) => loc.pubkey == _anotherPubkey), isTrue);
      },
    );

    test(
      'returns empty list when the only location is the current user',
      () async {
        final identity = Identity(
          pubkeyHex: _selfPubkey,
          npub: 'npub1self',
          createdAt: DateTime(2025),
        );

        // Service returns only the self location.
        final locations = [_makeLoc(_selfPubkey)];

        final container = await buildContainer(
          identity: identity,
          locations: locations,
        );
        addTearDown(container.dispose);

        final result = await container.read(memberLocationsProvider.future);

        expect(result, isEmpty);
      },
    );
  });

  // ---------------------------------------------------------------------------
  // Group: null identity edge case
  // ---------------------------------------------------------------------------

  group('memberLocationsProvider — null identity', () {
    test(
      'returns all locations when identity is null (no filtering applied)',
      () async {
        // identity == null: provider must pass through all locations unchanged.
        final locations = [_makeLoc(_selfPubkey), _makeLoc(_otherPubkey)];

        final container = await buildContainer(
          identity: null,
          locations: locations,
        );
        addTearDown(container.dispose);

        final result = await container.read(memberLocationsProvider.future);

        // No filtering when identity is unknown — all locations returned.
        expect(result.length, 2);
        expect(result.any((loc) => loc.pubkey == _selfPubkey), isTrue);
        expect(result.any((loc) => loc.pubkey == _otherPubkey), isTrue);
      },
    );

    test('returns empty list when identity is null and service returns no '
        'locations', () async {
      final container = await buildContainer(identity: null, locations: []);
      addTearDown(container.dispose);

      final result = await container.read(memberLocationsProvider.future);

      expect(result, isEmpty);
    });
  });

  // ---------------------------------------------------------------------------
  // Group: no circle / non-accepted circle (baseline guard tests)
  // ---------------------------------------------------------------------------

  group('memberLocationsProvider — circle guard', () {
    test('returns empty list when no circle is selected', () async {
      final mockIdentityService = _MockIdentityService(
        identity: Identity(
          pubkeyHex: _selfPubkey,
          npub: 'npub1self',
          createdAt: DateTime(2025),
        ),
      );
      final locationService = LocationSharingService(
        circleService: MockCircleService(),
        relayService: MockRelayService(),
      );

      final container = ProviderContainer(
        overrides: [
          identityServiceProvider.overrideWithValue(mockIdentityService),
          locationSharingServiceProvider.overrideWithValue(locationService),
          // selectedCircleProvider defaults to null — no override needed.
        ],
      );
      addTearDown(container.dispose);

      final result = await container.read(memberLocationsProvider.future);

      expect(result, isEmpty);
    });

    test(
      'returns empty list when selected circle is not yet accepted (pending)',
      () async {
        final mockIdentityService = _MockIdentityService(
          identity: Identity(
            pubkeyHex: _selfPubkey,
            npub: 'npub1self',
            createdAt: DateTime(2025),
          ),
        );
        final locationService = LocationSharingService(
          circleService: MockCircleService(),
          relayService: MockRelayService(),
        );

        final pendingCircle = TestCircleFactory.createCircle(
          membershipStatus: MembershipStatus.pending,
        );

        final container = ProviderContainer(
          overrides: [
            identityServiceProvider.overrideWithValue(mockIdentityService),
            locationSharingServiceProvider.overrideWithValue(locationService),
            selectedCircleProvider.overrideWithValue(pendingCircle),
          ],
        );
        addTearDown(container.dispose);

        final result = await container.read(memberLocationsProvider.future);

        expect(result, isEmpty);
      },
    );
  });

  // ---------------------------------------------------------------------------
  // Group: disclosure gate
  // ---------------------------------------------------------------------------

  group('locationPublisherProvider — disclosure gate', () {
    // Valid identity used across all gate tests.
    final _gateIdentity = Identity(
      pubkeyHex: _selfPubkey,
      npub: 'npub1self',
      createdAt: DateTime(2025),
    );

    test(
      'returns 0 and never calls getCurrentLocation when disclosure flag is absent',
      () async {
        // No disclosure key set — gate must block.
        SharedPreferences.setMockInitialValues({});

        final recordingLocationService = _RecordingLocationService();

        final container = ProviderContainer(
          overrides: [
            identityServiceProvider.overrideWithValue(
              _MockIdentityService(identity: _gateIdentity),
            ),
            locationServiceProvider.overrideWithValue(recordingLocationService),
            // Circle and location-sharing services are not reached; use
            // minimal mocks to satisfy the dependency graph.
            circleServiceProvider.overrideWithValue(MockCircleService()),
            locationSharingServiceProvider.overrideWithValue(
              LocationSharingService(
                circleService: MockCircleService(),
                relayService: MockRelayService(),
              ),
            ),
          ],
        );
        addTearDown(container.dispose);

        final result = await container.read(locationPublisherProvider.future);

        expect(
          result,
          0,
          reason:
              'locationPublisherProvider must return 0 when disclosure is not accepted',
        );
        expect(
          recordingLocationService.called,
          isFalse,
          reason:
              'getCurrentLocation must NOT be called before disclosure is accepted '
              '(would trigger OS permission prompt)',
        );
      },
    );

    test(
      'calls getCurrentLocation when disclosure flag is set (gate opens)',
      () async {
        // Disclosure key present — gate must open.
        SharedPreferences.setMockInitialValues({
          kLocationDisclosureAcceptedKey: true,
        });

        final recordingLocationService = _RecordingLocationService();
        // The recording service throws after setting called=true; the
        // provider's outer catch returns 0 — we don't care about the final
        // count here, only that getCurrentLocation was reached.

        final container = ProviderContainer(
          overrides: [
            identityServiceProvider.overrideWithValue(
              _MockIdentityService(identity: _gateIdentity),
            ),
            locationServiceProvider.overrideWithValue(recordingLocationService),
            circleServiceProvider.overrideWithValue(MockCircleService()),
            locationSharingServiceProvider.overrideWithValue(
              LocationSharingService(
                circleService: MockCircleService(),
                relayService: MockRelayService(),
              ),
            ),
          ],
        );
        addTearDown(container.dispose);

        // The provider may return 0 (no accepted circles) or throw internally;
        // we only care that the service was reached.
        await container.read(locationPublisherProvider.future);

        expect(
          recordingLocationService.called,
          isTrue,
          reason:
              'getCurrentLocation must be called once disclosure is accepted — '
              'the disclosure gate must open',
        );
      },
    );

    test(
      'returns 0 and never calls getCurrentLocation when disclosure key is explicitly false',
      () async {
        // Disclosure key is present but set to false — gate must still block.
        SharedPreferences.setMockInitialValues({
          kLocationDisclosureAcceptedKey: false,
        });

        final recordingLocationService = _RecordingLocationService();

        final container = ProviderContainer(
          overrides: [
            identityServiceProvider.overrideWithValue(
              _MockIdentityService(identity: _gateIdentity),
            ),
            locationServiceProvider.overrideWithValue(recordingLocationService),
            circleServiceProvider.overrideWithValue(MockCircleService()),
            locationSharingServiceProvider.overrideWithValue(
              LocationSharingService(
                circleService: MockCircleService(),
                relayService: MockRelayService(),
              ),
            ),
          ],
        );
        addTearDown(container.dispose);

        final result = await container.read(locationPublisherProvider.future);

        expect(result, 0);
        expect(
          recordingLocationService.called,
          isFalse,
          reason:
              'getCurrentLocation must NOT be called when disclosure key is false',
        );
      },
    );
  });

  // ---------------------------------------------------------------------------
  // Group: Dark Matter cutover send-path exclusions (DM-4c, Security Rule 8 /
  // §6 F10). A legacy-orphaned circle has no live MLS group to encrypt
  // against, and a blocked (Unrecoverable) circle must never send/mutate —
  // both must be excluded from the publish set before `encryptLocation` is
  // ever reached, not merely fail loudly once reached.
  // ---------------------------------------------------------------------------

  group('locationPublisherProvider — Dark Matter cutover exclusions', () {
    final gateIdentity = Identity(
      pubkeyHex: _selfPubkey,
      npub: 'npub1self',
      createdAt: DateTime(2025),
    );

    setUp(() {
      SharedPreferences.setMockInitialValues({
        kLocationDisclosureAcceptedKey: true,
      });
    });

    test(
      'excludes a legacy-orphaned (accepted, no members) circle from publish',
      () async {
        final healthy = TestCircleFactory.createCircle(
          mlsGroupId: const [1],
          nostrGroupId: const [1],
          members: [TestCircleFactory.createMember(pubkey: _selfPubkey)],
        );
        // Default TestCircleFactory.createCircle(): accepted + no members —
        // exactly the legacy-orphaned signature (Circle.isLegacyOrphaned).
        final legacy = TestCircleFactory.createCircle(
          mlsGroupId: const [2],
          nostrGroupId: const [2],
        );

        final mockCircle = MockCircleService(circles: [healthy, legacy]);
        final locationService = LocationSharingService(
          circleService: mockCircle,
          relayService: MockRelayService(),
        );

        final container = ProviderContainer(
          overrides: [
            identityServiceProvider.overrideWithValue(
              _MockIdentityService(identity: gateIdentity),
            ),
            locationServiceProvider.overrideWithValue(
              _FixedLocationService(),
            ),
            circleServiceProvider.overrideWithValue(mockCircle),
            locationSharingServiceProvider.overrideWithValue(locationService),
          ],
        );
        addTearDown(container.dispose);

        final result = await container.read(locationPublisherProvider.future);

        expect(
          result,
          1,
          reason: 'only the healthy circle should be published to',
        );
        expect(
          mockCircle.methodCalls.where((m) => m == 'encryptLocation').length,
          1,
          reason:
              'the legacy-orphaned circle must never reach encryptLocation',
        );
      },
    );

    test(
      'excludes a circle marked blocked (MLS Unrecoverable) from publish',
      () async {
        final healthy = TestCircleFactory.createCircle(
          mlsGroupId: const [1],
          nostrGroupId: const [1],
          members: [TestCircleFactory.createMember(pubkey: _selfPubkey)],
        );
        final blocked = TestCircleFactory.createCircle(
          mlsGroupId: const [3],
          nostrGroupId: const [3],
          members: [TestCircleFactory.createMember(pubkey: _selfPubkey)],
        );

        final mockCircle = MockCircleService(circles: [healthy, blocked])
          ..markCircleBlocked(blocked.mlsGroupId);
        final locationService = LocationSharingService(
          circleService: mockCircle,
          relayService: MockRelayService(),
        );

        final container = ProviderContainer(
          overrides: [
            identityServiceProvider.overrideWithValue(
              _MockIdentityService(identity: gateIdentity),
            ),
            locationServiceProvider.overrideWithValue(
              _FixedLocationService(),
            ),
            circleServiceProvider.overrideWithValue(mockCircle),
            locationSharingServiceProvider.overrideWithValue(locationService),
          ],
        );
        addTearDown(container.dispose);

        final result = await container.read(locationPublisherProvider.future);

        expect(result, 1);
        expect(
          mockCircle.methodCalls.where((m) => m == 'encryptLocation').length,
          1,
          reason: 'the blocked circle must never reach encryptLocation',
        );
      },
    );
  });
}

// =============================================================================
// Local mock: IdentityService
// =============================================================================

/// Minimal [IdentityService] mock that returns a fixed [identity].
class _MockIdentityService implements IdentityService {
  _MockIdentityService({required this.identity});

  final Identity? identity;

  @override
  Future<Identity?> getIdentity() async => identity;

  @override
  Future<bool> hasIdentity() async => identity != null;

  @override
  Future<Identity> createIdentity() async => throw UnimplementedError();

  @override
  Future<Identity> importFromNsec(String nsec) async =>
      throw UnimplementedError();

  @override
  Future<void> deleteIdentity() async {}

  @override
  Future<String> exportNsec() async => throw UnimplementedError();

  @override
  Future<String> sign(Uint8List messageHash) async =>
      throw UnimplementedError();

  @override
  Future<String> getPubkeyHex() async =>
      identity?.pubkeyHex ?? (throw UnimplementedError());

  @override
  Future<List<int>> getSecretBytes() async => throw UnimplementedError();

  @override
  Future<String?> getDisplayName() async => null;

  @override
  Future<void> setDisplayName(String? name) async {}

  @override
  Future<void> clearCache() async {}
}

// =============================================================================
// Local test double: recording LocationService
// =============================================================================

/// A [LocationService] test double that records whether [getCurrentLocation]
/// was ever invoked, then throws so that the publish path short-circuits
/// without requiring a full MLS stack.
///
/// Using a throw-after-record approach means:
/// - The disclosure gate tests only need to assert `called`.
/// - The "gate opens" test doesn't require a working publish pipeline.
class _RecordingLocationService implements LocationService {
  /// Set to `true` the first time [getCurrentLocation] is called.
  bool called = false;

  @override
  Future<Position> getCurrentLocation() async {
    called = true;
    // Throw so the provider's outer catch absorbs the failure; the test
    // only needs to verify that this method was reached.
    throw LocationServiceException('_RecordingLocationService: test sentinel');
  }

  @override
  Future<Position> getCurrentLocationFresh() async {
    called = true;
    throw LocationServiceException(
      '_RecordingLocationService: getCurrentLocationFresh test sentinel',
    );
  }

  @override
  Stream<Position> getLocationStream() async* {
    called = true;
  }

  @override
  Future<bool> isLocationServiceEnabled() async => true;

  @override
  Future<bool> requestPermission() async => true;

  @override
  Future<LocationPermissionStatus> checkPermission() async =>
      LocationPermissionStatus.always;
}

// =============================================================================
// Local test double: a LocationService that always resolves a fixed fix
// =============================================================================

/// A [LocationService] test double that always resolves a fixed GPS fix,
/// letting `locationPublisherProvider` run all the way through its
/// per-circle publish loop (unlike [_RecordingLocationService], which throws
/// after recording).
class _FixedLocationService implements LocationService {
  @override
  Future<Position> getCurrentLocation() async => Position(
    latitude: 37,
    longitude: -122,
    timestamp: DateTime.now(),
  );

  @override
  Future<Position> getCurrentLocationFresh() async => getCurrentLocation();

  @override
  Stream<Position> getLocationStream() async* {
    yield await getCurrentLocation();
  }

  @override
  Future<bool> isLocationServiceEnabled() async => true;

  @override
  Future<bool> requestPermission() async => true;

  @override
  Future<LocationPermissionStatus> checkPermission() async =>
      LocationPermissionStatus.always;
}
