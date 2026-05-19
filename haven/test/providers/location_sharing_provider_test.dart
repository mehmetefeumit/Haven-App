/// Tests for memberLocationsProvider self-exclusion behavior.
///
/// Verifies that:
/// - memberLocationsProvider filters out the current user's own location
/// - memberLocationsProvider returns all locations when identity is null
/// - memberLocationsProvider returns empty list when no circle is selected
/// - memberLocationsProvider returns empty list for non-accepted circles
library;

import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/providers/circles_provider.dart';
import 'package:haven/src/providers/location_sharing_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/services/identity_service.dart';
import 'package:haven/src/services/location_sharing_service.dart';

import '../mocks/mock_circle_service.dart';
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
  ProviderContainer buildContainer({
    required Identity? identity,
    required List<MemberLocation> locations,
    Circle? circle,
  }) {
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
            (loc) => DecryptResult(
              location: DecryptedLocation(
                senderPubkey: loc.pubkey,
                latitude: loc.latitude,
                longitude: loc.longitude,
                geohash: loc.geohash,
                timestamp: loc.timestamp,
                expiresAt: loc.expiresAt,
              ),
            ),
          )
          .toList();

    final locationService = LocationSharingService(
      circleService: mockCircle,
      relayService: mockRelay,
    );

    final selectedCircle = circle ?? TestCircleFactory.createCircle();

    final container = ProviderContainer(
      overrides: [
        identityServiceProvider.overrideWithValue(mockIdentityService),
        locationSharingServiceProvider.overrideWithValue(locationService),
        // Override the derived selectedCircleProvider directly so it
        // resolves synchronously without waiting for circlesProvider.
        selectedCircleProvider.overrideWithValue(selectedCircle),
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

        final container = buildContainer(
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

        final container = buildContainer(
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

        final container = buildContainer(
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

        final container = buildContainer(
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

        final container = buildContainer(identity: null, locations: locations);
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
      final container = buildContainer(identity: null, locations: []);
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
