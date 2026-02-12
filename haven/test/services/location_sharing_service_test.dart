/// Tests for LocationSharingService and related data classes.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/services/location_sharing_service.dart';
import 'package:haven/src/widgets/map/user_location_marker.dart';

import '../mocks/mock_circle_service.dart';
import '../mocks/mock_relay_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('MemberLocation', () {
    test('isExpired returns true for past expiresAt', () {
      final loc = MemberLocation(
        pubkey: 'abc123',
        latitude: 37.7749,
        longitude: -122.4194,
        geohash: '9q8yyk8',
        timestamp: DateTime.now().subtract(const Duration(hours: 25)),
        expiresAt: DateTime.now().subtract(const Duration(hours: 1)),
        precision: 'Enhanced',
      );
      expect(loc.isExpired, isTrue);
    });

    test('isExpired returns false for future expiresAt', () {
      final loc = MemberLocation(
        pubkey: 'abc123',
        latitude: 37.7749,
        longitude: -122.4194,
        geohash: '9q8yyk8',
        timestamp: DateTime.now(),
        expiresAt: DateTime.now().add(const Duration(hours: 23)),
        precision: 'Enhanced',
      );
      expect(loc.isExpired, isFalse);
    });

    test('freshness returns live for < 1 minute', () {
      final loc = MemberLocation(
        pubkey: 'abc123',
        latitude: 37.7749,
        longitude: -122.4194,
        geohash: '9q8yyk8',
        timestamp: DateTime.now().subtract(const Duration(seconds: 30)),
        expiresAt: DateTime.now().add(const Duration(hours: 23)),
        precision: 'Enhanced',
      );
      expect(loc.freshness, LocationFreshness.live);
    });

    test('freshness returns recent for 1-5 minutes', () {
      final loc = MemberLocation(
        pubkey: 'abc123',
        latitude: 37.7749,
        longitude: -122.4194,
        geohash: '9q8yyk8',
        timestamp: DateTime.now().subtract(const Duration(minutes: 3)),
        expiresAt: DateTime.now().add(const Duration(hours: 23)),
        precision: 'Enhanced',
      );
      expect(loc.freshness, LocationFreshness.recent);
    });

    test('freshness returns stale for 5-15 minutes', () {
      final loc = MemberLocation(
        pubkey: 'abc123',
        latitude: 37.7749,
        longitude: -122.4194,
        geohash: '9q8yyk8',
        timestamp: DateTime.now().subtract(const Duration(minutes: 10)),
        expiresAt: DateTime.now().add(const Duration(hours: 23)),
        precision: 'Enhanced',
      );
      expect(loc.freshness, LocationFreshness.stale);
    });

    test('freshness returns old for >= 15 minutes', () {
      final loc = MemberLocation(
        pubkey: 'abc123',
        latitude: 37.7749,
        longitude: -122.4194,
        geohash: '9q8yyk8',
        timestamp: DateTime.now().subtract(const Duration(minutes: 20)),
        expiresAt: DateTime.now().add(const Duration(hours: 23)),
        precision: 'Enhanced',
      );
      expect(loc.freshness, LocationFreshness.old);
    });
  });

  group('DecryptedLocation', () {
    test('isExpired works correctly', () {
      final expired = DecryptedLocation(
        senderPubkey: 'abc',
        latitude: 37.0,
        longitude: -122.0,
        geohash: '9q8',
        timestamp: DateTime.now().subtract(const Duration(hours: 25)),
        expiresAt: DateTime.now().subtract(const Duration(hours: 1)),
        precision: 'Enhanced',
      );
      expect(expired.isExpired, isTrue);

      final valid = DecryptedLocation(
        senderPubkey: 'abc',
        latitude: 37.0,
        longitude: -122.0,
        geohash: '9q8',
        timestamp: DateTime.now(),
        expiresAt: DateTime.now().add(const Duration(hours: 23)),
        precision: 'Enhanced',
      );
      expect(valid.isExpired, isFalse);
    });
  });

  group('EncryptedLocation', () {
    test('creates with required fields', () {
      const loc = EncryptedLocation(
        eventJson: '{"id":"test","kind":445}',
        nostrGroupId: [1, 2, 3],
        relays: ['wss://relay.example.com'],
      );
      expect(loc.eventJson, contains('445'));
      expect(loc.nostrGroupId, hasLength(3));
      expect(loc.relays, contains('wss://relay.example.com'));
    });
  });

  group('LocationSharingService', () {
    late MockCircleService mockCircleService;
    late MockRelayService mockRelayService;
    late LocationSharingService service;

    setUp(() {
      mockCircleService = MockCircleService();
      mockRelayService = MockRelayService();
      service = LocationSharingService(
        circleService: mockCircleService,
        relayService: mockRelayService,
      );
    });

    group('publishLocation', () {
      test('calls encrypt then publish', () async {
        await service.publishLocation(
          mlsGroupId: [1, 2, 3],
          senderPubkeyHex: 'abc123',
          latitude: 37.7749,
          longitude: -122.4194,
        );

        expect(mockCircleService.methodCalls, contains('encryptLocation'));
        expect(mockRelayService.methodCalls, contains('publishEvent'));
        expect(mockRelayService.publishedEvents, hasLength(1));
      });
    });

    group('fetchMemberLocations', () {
      final testCircle = TestCircleFactory.createCircle(
        displayName: 'Test',
        membershipStatus: MembershipStatus.accepted,
        members: [
          TestCircleFactory.createMember(
            pubkey: 'sender1',
            displayName: 'Alice',
          ),
        ],
      );

      test('returns empty for non-accepted circle', () async {
        final pendingCircle = TestCircleFactory.createCircle(
          membershipStatus: MembershipStatus.pending,
        );

        final locations = await service.fetchMemberLocations(
          circle: pendingCircle,
        );

        expect(locations, isEmpty);
        expect(mockRelayService.methodCalls, isEmpty);
      });

      test('fetches and decrypts locations', () async {
        // Set up mock relay to return event JSONs
        final mockRelay = MockRelayService(
          groupMessages: ['{"id":"evt1","kind":445,"content":"encrypted"}'],
        );
        final mockCircle = MockCircleService();
        mockCircle.decryptLocationResults = [
          DecryptedLocation(
            senderPubkey: 'sender1',
            latitude: 37.7749,
            longitude: -122.4194,
            geohash: '9q8yyk8',
            timestamp: DateTime.now(),
            expiresAt: DateTime.now().add(const Duration(hours: 23)),
            precision: 'Enhanced',
          ),
        ];

        final svc = LocationSharingService(
          circleService: mockCircle,
          relayService: mockRelay,
        );

        final locations = await svc.fetchMemberLocations(circle: testCircle);

        expect(locations, hasLength(1));
        expect(locations.first.latitude, 37.7749);
        expect(locations.first.displayName, 'Alice');
        expect(mockRelay.methodCalls, contains('fetchGroupMessages'));
        expect(mockCircle.methodCalls, contains('decryptLocation'));
      });

      test('skips null decrypt results', () async {
        final mockRelay = MockRelayService(
          groupMessages: ['{"id":"evt1","kind":445,"content":"group-update"}'],
        );
        final mockCircle = MockCircleService();
        // Default decrypt returns null

        final svc = LocationSharingService(
          circleService: mockCircle,
          relayService: mockRelay,
        );

        final locations = await svc.fetchMemberLocations(circle: testCircle);

        expect(locations, isEmpty);
      });

      test('skips expired locations', () async {
        final mockRelay = MockRelayService(
          groupMessages: ['{"id":"evt1","kind":445,"content":"expired"}'],
        );
        final mockCircle = MockCircleService();
        mockCircle.decryptLocationResults = [
          DecryptedLocation(
            senderPubkey: 'sender1',
            latitude: 37.0,
            longitude: -122.0,
            geohash: '9q8',
            timestamp: DateTime.now().subtract(const Duration(hours: 25)),
            expiresAt: DateTime.now().subtract(const Duration(hours: 1)),
            precision: 'Enhanced',
          ),
        ];

        final svc = LocationSharingService(
          circleService: mockCircle,
          relayService: mockRelay,
        );

        final locations = await svc.fetchMemberLocations(circle: testCircle);

        expect(locations, isEmpty);
      });

      test('deduplicates by sender keeping latest', () async {
        final now = DateTime.now();
        final mockRelay = MockRelayService(
          groupMessages: [
            '{"id":"evt1","kind":445,"content":"old"}',
            '{"id":"evt2","kind":445,"content":"new"}',
          ],
        );
        final mockCircle = MockCircleService();
        mockCircle.decryptLocationResults = [
          DecryptedLocation(
            senderPubkey: 'sender1',
            latitude: 37.0,
            longitude: -122.0,
            geohash: '9q8',
            timestamp: now.subtract(const Duration(minutes: 5)),
            expiresAt: now.add(const Duration(hours: 23)),
            precision: 'Enhanced',
          ),
          DecryptedLocation(
            senderPubkey: 'sender1',
            latitude: 38.0,
            longitude: -121.0,
            geohash: '9q9',
            timestamp: now,
            expiresAt: now.add(const Duration(hours: 23)),
            precision: 'Enhanced',
          ),
        ];

        final svc = LocationSharingService(
          circleService: mockCircle,
          relayService: mockRelay,
        );

        final locations = await svc.fetchMemberLocations(circle: testCircle);

        expect(locations, hasLength(1));
        expect(locations.first.latitude, 38.0); // Latest one
      });

      test('handles decryption errors gracefully', () async {
        final mockRelay = MockRelayService(
          groupMessages: [
            '{"id":"evt1","kind":445,"content":"will-fail"}',
            '{"id":"evt2","kind":445,"content":"will-succeed"}',
          ],
        );
        // Create a custom circle service that throws on first decrypt
        final throwingService = _ThrowOnFirstDecryptService();

        final svc = LocationSharingService(
          circleService: throwingService,
          relayService: mockRelay,
        );

        final locations = await svc.fetchMemberLocations(circle: testCircle);

        // Should have the second location (first one threw)
        expect(locations, hasLength(1));
        expect(locations.first.latitude, 38.0);
      });
    });
  });
}

/// A service that throws on the first decrypt call but succeeds on the second.
class _ThrowOnFirstDecryptService implements CircleService {
  int _decryptCount = 0;

  @override
  Future<DecryptedLocation?> decryptLocation({
    required String eventJson,
  }) async {
    _decryptCount++;
    if (_decryptCount == 1) {
      throw const CircleServiceException('MLS decryption failed');
    }
    return DecryptedLocation(
      senderPubkey: 'sender1',
      latitude: 38.0,
      longitude: -121.0,
      geohash: '9q9',
      timestamp: DateTime.now(),
      expiresAt: DateTime.now().add(const Duration(hours: 23)),
      precision: 'Enhanced',
    );
  }

  @override
  Future<EncryptedLocation> encryptLocation({
    required List<int> mlsGroupId,
    required String senderPubkeyHex,
    required double latitude,
    required double longitude,
  }) async => throw UnimplementedError();

  @override
  Future<CircleCreationResult> createCircle({
    required List<int> identitySecretBytes,
    required List<KeyPackageData> memberKeyPackages,
    required String name,
    required CircleType circleType,
    String? description,
    List<String>? relays,
  }) async => throw UnimplementedError();

  @override
  Future<List<Circle>> getVisibleCircles() async => [];

  @override
  Future<Circle?> getCircle(List<int> mlsGroupId) async => null;

  @override
  Future<List<CircleMember>> getMembers(List<int> mlsGroupId) async => [];

  @override
  Future<List<Invitation>> getPendingInvitations() async => [];

  @override
  Future<Circle> acceptInvitation(List<int> mlsGroupId) async =>
      throw UnimplementedError();

  @override
  Future<void> declineInvitation(List<int> mlsGroupId) async {}

  @override
  Future<void> leaveCircle(List<int> mlsGroupId) async {}

  @override
  Future<Invitation> processGiftWrappedInvitation({
    required List<int> identitySecretBytes,
    required String giftWrapEventJson,
    String circleName = 'New Circle',
  }) async => throw UnimplementedError();

  @override
  Future<void> finalizePendingCommit(List<int> mlsGroupId) async {}
}
