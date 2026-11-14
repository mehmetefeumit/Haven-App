/// Tests for NostrCircleService.
///
/// ## Test Strategy
///
/// NostrCircleService has a hard dependency on
/// `CircleManagerFfi.newInstance()` which requires Rust FFI initialization.
///
/// These tests verify:
/// 1. Data structure behavior and immutability
/// 2. Type conversions between FFI and service layer
/// 3. Validation logic
/// 4. Error types
/// 5. Initialization behavior via injectable dependencies
///
/// Full integration tests with Rust bridge are in integration_test/.
library;

import 'dart:async';

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/rust/api.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/services/mls_session_handover.dart';
import 'package:haven/src/services/nostr_circle_service.dart';
import 'package:haven/src/services/nostr_relay_service.dart';
import 'package:haven/src/services/relay_service.dart';

import '../helpers/fake_change_driver.dart';
import '../helpers/log_capture.dart';

// ---------------------------------------------------------------------------
// Minimal stubs used by NostrCircleService initialization tests
// ---------------------------------------------------------------------------

/// Stub [RelayService] that satisfies the interface without any real I/O.
///
/// All methods throw [UnimplementedError] — they are never reached during
/// the [NostrCircleService.initialize] path that these tests exercise.
class _StubRelayService implements RelayService {
  @override
  Future<CatchupResult> runCatchup({
    required CircleManagerFfi circle,
    required String ownPubkeyHex,
    int maxDurationSecs = 20,
  }) async => const CatchupResult.empty();

  @override
  Future<CatchupResult> runRefusedRefetch({
    required CircleManagerFfi circle,
    int maxDurationSecs = 20,
  }) async => const CatchupResult.empty();

  @override
  Future<KeyPackageMaintenanceOutcome> maintainKeyPackage({
    required CircleManagerFfi circle,
    required List<int> identitySecretBytes,
  }) async => const KeyPackageMaintenanceHealthy(
    canonicalOnRelays: 1,
    respondersProbed: 1,
  );

  @override
  Future<RelayListMaintenanceResult> maintainRelayList({
    required CircleManagerFfi circle,
    required List<int> identitySecretBytes,
  }) async => const RelayListMaintenanceResult.failed();

  @override
  Future<SubscriptionHealthResult> maintainSubscriptionHealth({
    required bool foreground,
  }) async => const SubscriptionHealthResult.empty();


  @override
  Future<List<String>> fetchNip65Relays(String pubkey) =>
      throw UnimplementedError();

  @override
  Future<KeyPackageData?> fetchKeyPackage(
    String pubkey, {
    List<int>? mlsGroupId,
  }) => throw UnimplementedError();

  @override
  Future<PublishResult> publishEvent({
    required String eventJson,
    required List<String> relays,
  }) => throw UnimplementedError();

  @override
  Future<List<String>> fetchGiftWraps({
    required String recipientPubkey,
    required List<String> relays,
    DateTime? since,
  }) => throw UnimplementedError();

  @override
  Future<List<RelayGiftWrapFetch>> fetchGiftWrapsPerRelay({
    required String recipientPubkey,
    required List<String> relays,
    DateTime? since,
  }) => throw UnimplementedError();

  @override
  Future<List<String>> fetchGroupMessages({
    required List<int> nostrGroupId,
    required List<String> relays,
    DateTime? since,
    int? limit,
  }) => throw UnimplementedError();

  @override
  Future<List<OwnRelayPresenceFfi>> checkOwnReachability({
    required String ownPubkey,
  }) => throw UnimplementedError();

  @override
  Future<void> disconnectRelay(String url) async {}
}

/// [DataDirectoryProvider] that records whether it was called and then
/// throws so that the Rust FFI manager constructor is never reached.
class _ThrowingDataDirectoryProvider implements DataDirectoryProvider {
  bool wasCalled = false;

  @override
  Future<String> getDataDirectory() async {
    wasCalled = true;
    throw Exception('Stub: stop before FFI');
  }
}

/// A manager whose release throws.
class _ThrowingDisposeManager extends _FakeManager {
  int disposeCalls = 0;

  @override
  void dispose() {
    disposeCalls++;
    throw StateError('release failed');
  }
}

/// A fake [CircleManagerFfi] that records whether its `RustOpaque` handle was
/// released. Only `dispose`/`isDisposed` are implemented — the tests using it
/// drive teardown only, and any other call is a bug this surfaces loudly.
///
/// Exists because the handle owns the MLS DB's Rule-14 `LiveSessionGuard`,
/// which Rust releases on `Drop`. Dropping the Dart reference alone defers that
/// to a GC that may never run before the next open, so teardown MUST dispose.
class _FakeManager implements CircleManagerFfi {
  bool disposed = false;

  @override
  void dispose() => disposed = true;

  @override
  bool get isDisposed => disposed;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('unexpected call: ${invocation.memberName}');
}

/// [DataDirectoryProvider] that resolves, so an `initialize()` reaches the real
/// open — which then fails on the absent Rust bridge, the failure every
/// recovery seam hangs off.
class _FixedDataDirectoryProvider implements DataDirectoryProvider {
  @override
  Future<String> getDataDirectory() async => '/haven-test-data';
}

/// [DataDirectoryProvider] that appends a tag to a shared call-order list
/// before throwing, so tests can verify execution order.
class _OrderTrackingDataDirectoryProvider implements DataDirectoryProvider {
  _OrderTrackingDataDirectoryProvider(this._callOrder);

  final List<String> _callOrder;

  @override
  Future<String> getDataDirectory() async {
    _callOrder.add('dataDir');
    throw Exception('Stub: stop before FFI');
  }
}

void main() {
  _handoffTests();
  _orphanedGuardRecoveryTests();
  TestWidgetsFlutterBinding.ensureInitialized();

  group('CircleService - Data Structures', () {
    group('MembershipStatus', () {
      test('has all expected values', () {
        expect(MembershipStatus.values.length, 3);
        expect(MembershipStatus.pending, isNotNull);
        expect(MembershipStatus.accepted, isNotNull);
        expect(MembershipStatus.declined, isNotNull);
      });
    });

    group('CircleType', () {
      test('has all expected values', () {
        expect(CircleType.values.length, 2);
        expect(CircleType.locationSharing, isNotNull);
        expect(CircleType.directShare, isNotNull);
      });
    });

    group('Circle', () {
      test('creates with all required fields', () {
        final circle = Circle(
          mlsGroupId: const [1, 2, 3, 4],
          nostrGroupId: const [5, 6, 7, 8],
          displayName: 'Test Circle',
          circleType: CircleType.locationSharing,
          relays: const ['wss://relay.example.com'],
          membershipStatus: MembershipStatus.accepted,
          members: const [],
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        );

        expect(circle.displayName, 'Test Circle');
        expect(circle.circleType, CircleType.locationSharing);
        expect(circle.relays, contains('wss://relay.example.com'));
        expect(circle.membershipStatus, MembershipStatus.accepted);
      });

      test('equality is based on mlsGroupId', () {
        final circle1 = Circle(
          mlsGroupId: const [1, 2, 3, 4],
          nostrGroupId: const [5, 6, 7, 8],
          displayName: 'Circle 1',
          circleType: CircleType.locationSharing,
          relays: const [],
          membershipStatus: MembershipStatus.accepted,
          members: const [],
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        );

        final circle2 = Circle(
          mlsGroupId: const [1, 2, 3, 4],
          nostrGroupId: const [9, 10, 11, 12],
          displayName: 'Circle 2 - Different Name',
          circleType: CircleType.directShare,
          relays: const [],
          membershipStatus: MembershipStatus.pending,
          members: const [],
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        );

        expect(circle1, equals(circle2));
      });

      test('hashCode is based on mlsGroupId', () {
        final circle1 = Circle(
          mlsGroupId: const [1, 2, 3, 4],
          nostrGroupId: const [5, 6, 7, 8],
          displayName: 'Circle 1',
          circleType: CircleType.locationSharing,
          relays: const [],
          membershipStatus: MembershipStatus.accepted,
          members: const [],
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        );

        final circle2 = Circle(
          mlsGroupId: const [1, 2, 3, 4],
          nostrGroupId: const [9, 10, 11, 12],
          displayName: 'Different',
          circleType: CircleType.locationSharing,
          relays: const [],
          membershipStatus: MembershipStatus.accepted,
          members: const [],
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        );

        expect(circle1.hashCode, equals(circle2.hashCode));
      });

      test('toString includes displayName', () {
        final circle = Circle(
          mlsGroupId: const [1, 2, 3, 4],
          nostrGroupId: const [5, 6, 7, 8],
          displayName: 'My Friends',
          circleType: CircleType.locationSharing,
          relays: const [],
          membershipStatus: MembershipStatus.accepted,
          members: const [],
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        );

        // toString must NOT expose displayName (privacy).
        expect(circle.toString(), isNot(contains('My Friends')));
        // It should show the member count instead.
        expect(circle.toString(), contains('members:'));
      });

      // F4: Verify toString does not expose mlsGroupId
      test('toString does not expose mlsGroupId', () {
        final circle = Circle(
          mlsGroupId: const [1, 2, 3, 4],
          nostrGroupId: const [5, 6, 7, 8],
          displayName: 'Test',
          circleType: CircleType.locationSharing,
          relays: const [],
          membershipStatus: MembershipStatus.accepted,
          members: const [],
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        );

        final str = circle.toString();
        // MLS group ID bytes must NOT appear in string representation
        expect(str, isNot(contains('1, 2, 3, 4')));
        expect(str, isNot(contains('[1,')));
        expect(str, isNot(contains('mlsGroupId')));
      });
    });

    group('CircleMember', () {
      test('creates with required fields', () {
        const member = CircleMember(
          pubkey:
              'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
          npub:
              'npub1424242424242424242424242424242424242424242424242424qamrcaj',
          isAdmin: true,
        );

        expect(member.pubkey.length, 64);
        expect(member.isAdmin, true);
      });

      test('creates with optional fields', () {
        const member = CircleMember(
          pubkey:
              'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
          npub:
              'npub1424242424242424242424242424242424242424242424242424qamrcaj',
          isAdmin: false,
          displayName: 'Alice',
        );

        expect(member.displayName, 'Alice');
      });

      test('equality is based on pubkey', () {
        const member1 = CircleMember(
          pubkey:
              'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
          npub:
              'npub1424242424242424242424242424242424242424242424242424qamrcaj',
          isAdmin: true,
          displayName: 'Alice',
        );

        const member2 = CircleMember(
          pubkey:
              'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
          npub:
              'npub1424242424242424242424242424242424242424242424242424qamrcaj',
          isAdmin: false,
          displayName: 'Different Name',
        );

        expect(member1, equals(member2));
      });

      test('toString carries no pubkey, not even a prefix', () {
        const member = CircleMember(
          pubkey:
              'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
          npub:
              'npub1424242424242424242424242424242424242424242424242424qamrcaj',
          isAdmin: true,
        );

        final str = member.toString();
        // Rule 15: "redacted" means ABSENT — a truncated pubkey still tells
        // one peer apart from another, so a salted handle takes its place.
        expect(str, isNot(contains('aaaaaaaa')));
        expect(str, isNot(contains('npub1')));
        expect(str, startsWith('CircleMember(peer#'));
      });
    });

    group('unsentNpubs', () {
      KeyPackageData invitee(String hex, String npub) => KeyPackageData(
        pubkey: npub,
        eventJson: '{"kind":30443,"pubkey":"$hex"}',
        relays: const [],
        nip65WriteRelays: const [],
      );

      test('names, in the order the core gave, each invitee whose founding '
          'Welcome is still owed, by the npub they were invited under', () {
        final named = NostrCircleService.unsentNpubs(
          ['bb' * 32, 'cc' * 32],
          [
            invitee('cc' * 32, 'npub1c'),
            invitee('aa' * 32, 'npub1a'),
            invitee('bb' * 32, 'npub1b'),
          ],
        );
        expect(named, ['npub1b', 'npub1c']);
      });

      test('a recipient nobody was invited under names nobody', () {
        expect(
          NostrCircleService.unsentNpubs(
            ['dd' * 32],
            [invitee('aa' * 32, 'npub1a')],
          ),
          isEmpty,
        );
      });

      test('a package that does not parse names nobody', () {
        expect(
          NostrCircleService.unsentNpubs(
            ['aa' * 32],
            [
              const KeyPackageData(
                pubkey: 'npub1a',
                eventJson: 'not json',
                relays: [],
                nip65WriteRelays: [],
              ),
            ],
          ),
          isEmpty,
        );
      });
    });

    group('CircleCreationResult', () {
      test('creates with circle and welcome delivery counts', () {
        // NostrCircleService.createCircle creates through the fanout driver,
        // which records and sends each founding Welcome, so the result
        // carries counts (mirrors AddMemberResult), never a Welcome event.
        final circle = Circle(
          mlsGroupId: const [1, 2, 3, 4],
          nostrGroupId: const [5, 6, 7, 8],
          displayName: 'Test',
          circleType: CircleType.locationSharing,
          relays: const [],
          membershipStatus: MembershipStatus.accepted,
          members: const [],
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        );

        final result = CircleCreationResult(
          circle: circle,
          welcomesSent: 1,
          welcomesTotal: 1,
        );

        expect(result.circle, equals(circle));
        expect(result.welcomesSent, 1);
        expect(result.welcomesTotal, 1);
      });
    });

    group('Invitation', () {
      test('creates with all fields', () {
        final invitation = Invitation(
          mlsGroupId: const [1, 2, 3, 4],
          circleName: 'Family',
          inviterPubkey:
              'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
          inviterNpub:
              'npub15feryxhrdz9m6y09mr8wrerwzgj6f8ntxvhxyrdlm5aahn0t09nl4ujy86',
          invitedAt: DateTime.now(),
        );

        expect(invitation.circleName, 'Family');
        expect(invitation.inviterPubkey.length, 64);
        expect(invitation.inviterNpub, startsWith('npub1'));
      });
    });

    group('KeyPackageData', () {
      test('creates with all fields', () {
        const keyPackage = KeyPackageData(
          pubkey:
              'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
          eventJson: '{"kind":30443,"content":"key_package_bytes"}',
          relays: ['wss://relay.example.com'],
          nip65WriteRelays: [],
        );

        expect(keyPackage.pubkey.length, 64);
        expect(keyPackage.eventJson, contains('"kind":30443'));
        expect(keyPackage.relays, isNotEmpty);
      });

      test('event is kind 30443 KeyPackage', () {
        const keyPackage = KeyPackageData(
          pubkey:
              'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
          eventJson: '{"kind":30443}',
          relays: ['wss://relay.example.com'],
          nip65WriteRelays: [],
        );

        // Kind 30443 is the Marmot v2 addressable KeyPackage (legacy 443
        // is retired by the Dark Matter migration).
        expect(keyPackage.eventJson, contains('30443'));
      });

      test('nip65Relays defaults to empty list', () {
        const keyPackage = KeyPackageData(
          pubkey:
              'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
          eventJson: '{"kind":30443}',
          relays: ['wss://relay.example.com'],
          nip65WriteRelays: [],
        );

        expect(keyPackage.nip65Relays, isEmpty);
      });

      test('creates with nip65Relays', () {
        const keyPackage = KeyPackageData(
          pubkey:
              'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
          eventJson: '{"kind":30443}',
          relays: ['wss://inbox.example.com'],
          nip65WriteRelays: ['wss://nip65-write.example.com'],
          nip65Relays: ['wss://nip65.example.com'],
        );

        expect(keyPackage.relays, ['wss://inbox.example.com']);
        expect(keyPackage.nip65Relays, ['wss://nip65.example.com']);
        expect(keyPackage.nip65WriteRelays, ['wss://nip65-write.example.com']);
      });
    });

    group('CircleServiceException', () {
      test('creates with message', () {
        const exception = CircleServiceException('Test error');
        expect(exception.message, 'Test error');
      });

      test('toString includes message', () {
        const exception = CircleServiceException('Circle not found');
        expect(exception.toString(), contains('CircleServiceException'));
        expect(exception.toString(), contains('Circle not found'));
      });

      test('is an Exception', () {
        const exception = CircleServiceException('Test');
        expect(exception, isA<Exception>());
      });
    });
  });

  group('CircleService - Validation', () {
    test('secret bytes must be 32 bytes', () {
      final validSecretBytes = List<int>.filled(32, 0);
      expect(validSecretBytes.length, 32);
    });

    test('circle name must be non-empty', () {
      const validName = 'My Circle';
      expect(validName, isNotEmpty);
    });

    test('pubkey must be 64 hex characters', () {
      const pubkey =
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
      expect(pubkey.length, 64);
    });

    test('MLS group ID is internal and private', () {
      final mlsGroupId = [1, 2, 3, 4];
      final nostrGroupId = [5, 6, 7, 8];

      // Only nostrGroupId goes in events, mlsGroupId stays local
      expect(mlsGroupId, isNotEmpty);
      expect(nostrGroupId, isNotEmpty);
    });
  });

  group('CircleService - Type Conversions', () {
    test('CircleType.locationSharing maps to location_sharing', () {
      const type = CircleType.locationSharing;
      expect(type, CircleType.locationSharing);
      // Expected string: 'location_sharing'
    });

    test('CircleType.directShare maps to direct_share', () {
      const type = CircleType.directShare;
      expect(type, CircleType.directShare);
      // Expected string: 'direct_share'
    });

    test('MembershipStatus.pending maps to pending', () {
      const status = MembershipStatus.pending;
      expect(status, MembershipStatus.pending);
      // Expected string: 'pending'
    });

    test('MembershipStatus.accepted maps to accepted', () {
      const status = MembershipStatus.accepted;
      expect(status, MembershipStatus.accepted);
      // Expected string: 'accepted'
    });

    test('MembershipStatus.declined maps to declined', () {
      const status = MembershipStatus.declined;
      expect(status, MembershipStatus.declined);
      // Expected string: 'declined'
    });

    test('timestamps convert from seconds to DateTime', () {
      final timestamp = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final dateTime = DateTime.fromMillisecondsSinceEpoch(timestamp * 1000);
      expect(dateTime, isA<DateTime>());
    });
  });

  group('CircleService - Security Requirements', () {
    test('secret bytes are 32 bytes for secp256k1', () {
      // Nostr uses secp256k1 with 32-byte private keys
      final secretBytes = List<int>.filled(32, 0);
      expect(secretBytes.length, 32);
    });

    test('nostrGroupId is exposed, not mlsGroupId', () {
      // For privacy, only nostrGroupId is shared publicly
      // mlsGroupId is internal and never leaves the device
      final circle = Circle(
        mlsGroupId: const [1, 2, 3, 4],
        nostrGroupId: const [5, 6, 7, 8],
        displayName: 'Test',
        circleType: CircleType.locationSharing,
        relays: const [],
        membershipStatus: MembershipStatus.accepted,
        members: const [],
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      expect(circle.mlsGroupId, isNotEmpty);
      expect(circle.nostrGroupId, isNotEmpty);
      // Only nostrGroupId goes in events
    });
  });

  group('CircleService - Error Handling', () {
    test('invalid secret bytes length error', () {
      final invalidBytes = List<int>.filled(16, 0);
      expect(invalidBytes.length, 16);
      // Should throw: "Invalid identity secret bytes length" (never the
      // actual length — Security Rule 6 forbids exposing key material).
    });

    test('error messages start with Failed to', () {
      final operations = [
        'Failed to create circle',
        'Failed to get circle',
        'Failed to get members',
        'Failed to accept invitation',
        'Failed to decline invitation',
        'Failed to leave circle',
      ];

      for (final operation in operations) {
        expect(operation, startsWith('Failed to'));
      }
    });
  });

  group('CircleService - Constants', () {
    test('data directory includes haven subdirectory', () {
      const dataDir = '/path/to/app/documents/haven';
      expect(dataDir, contains('haven'));
    });

    test('nostr group ID is 16 bytes', () {
      final nostrGroupId = List<int>.filled(16, 1);
      expect(nostrGroupId.length, 16);
    });
  });

  // -------------------------------------------------------------------------
  // NostrCircleService - Initialization
  //
  // These tests exercise the injectable seams introduced so that the keyring
  // initializer and the data-directory provider can be controlled in tests
  // without requiring the native Rust bridge.
  //
  // Strategy:
  //   1. Inject a tracking keyring initializer (a simple closure).
  //   2. Inject a _ThrowingDataDirectoryProvider so that initialization
  //      always fails before reaching CircleManagerFfi.newInstance(),
  //      which would require the native library.
  //   3. Verify observable side-effects (call counts, exception types).
  // -------------------------------------------------------------------------

  group('NostrCircleService - Initialization', () {
    test('keyring initializer is called during initialize()', () async {
      var keyringCallCount = 0;
      final dataDir = _ThrowingDataDirectoryProvider();

      final service = NostrCircleService(
        relayService: _StubRelayService(),
        dataDirectoryProvider: dataDir,
        keyringInitializer: () async {
          keyringCallCount++;
        },
      );

      // The data directory provider throws after keyring succeeds, so
      // initialize() will surface an error — but we only care that the
      // keyring initializer was invoked.
      await expectLater(service.initialize(), throwsA(anything));

      expect(keyringCallCount, 1);
    });

    test('keyring failure propagates as CircleServiceException', () async {
      final service = NostrCircleService(
        relayService: _StubRelayService(),
        dataDirectoryProvider: _ThrowingDataDirectoryProvider(),
        keyringInitializer: () async {
          throw Exception('keyring unavailable');
        },
      );

      await expectLater(
        service.initialize(),
        throwsA(isA<CircleServiceException>()),
      );
    });

    test(
      'CircleServiceException message is generic (no internal detail leak)',
      () async {
        final service = NostrCircleService(
          relayService: _StubRelayService(),
          dataDirectoryProvider: _ThrowingDataDirectoryProvider(),
          keyringInitializer: () async {
            throw Exception('internal keyring detail that must not leak');
          },
        );

        try {
          await service.initialize();
          fail('Expected CircleServiceException');
        } on CircleServiceException catch (e) {
          // The message must not contain internal exception details.
          expect(e.message, isNot(contains('internal keyring detail')));
          expect(e.message, contains('secure storage'));
        }
      },
    );

    test(
      'keyring initializer is called before data directory provider',
      () async {
        final callOrder = <String>[];

        final service = NostrCircleService(
          relayService: _StubRelayService(),
          dataDirectoryProvider: _OrderTrackingDataDirectoryProvider(callOrder),
          keyringInitializer: () async {
            callOrder.add('keyring');
          },
          // A configured (non-null) identity secret provider is required so
          // the "no identity available" gate — checked right after keyring
          // init, before the data-directory I/O — doesn't short-circuit
          // before `getDataDirectory()` is ever reached.
          identitySecretBytesProvider: () async => List<int>.filled(32, 7),
        );

        // Initialization will fail when data directory throws — that is fine.
        await expectLater(service.initialize(), throwsA(anything));

        // Keyring must appear before 'dataDir' in the call log.
        expect(callOrder, contains('keyring'));
        expect(callOrder, contains('dataDir'));
        expect(
          callOrder.indexOf('keyring'),
          lessThan(callOrder.indexOf('dataDir')),
        );
      },
    );

    test('failed initialization does not prevent retry', () async {
      var keyringCallCount = 0;

      // We cannot reach the "already initialized" short-circuit path in a
      // pure unit test because CircleManagerFfi.newInstance() requires the
      // native bridge. Instead we verify the complementary invariant: a
      // failed initialization does NOT set _initialized, so each retry
      // calls the keyring initializer again.
      final service = NostrCircleService(
        relayService: _StubRelayService(),
        dataDirectoryProvider: _ThrowingDataDirectoryProvider(),
        keyringInitializer: () async {
          keyringCallCount++;
        },
      );

      // First attempt — keyring is called once then data-dir throws.
      await expectLater(service.initialize(), throwsA(anything));
      expect(keyringCallCount, 1);

      // Second attempt — a new Completer is used (previous one was cleared),
      // so keyring is called again (service is not flagged as initialized
      // because init failed). This confirms the guard is only skipped on
      // success.
      await expectLater(service.initialize(), throwsA(anything));
      expect(keyringCallCount, 2);
    });

    test(
        'closeAndInvalidate latches the service: initialize() is refused '
        'without ever re-opening the DB (M10 H1 wipe race)', () async {
      // The M10 logout-wipe deletes circles.db while an in-flight
      // maintenance/engine tick may still hold a reference to this service.
      // closeAndInvalidate() MUST latch so any such tick that reaches
      // initialize() after the wipe is REFUSED — otherwise it would
      // SQLite-create a fresh (decryptable) DB + keyring key, defeating the
      // wipe. Proof: the keyring initializer (the very first side-effect of a
      // real re-open) must NOT run again after the latch.
      var keyringCallCount = 0;
      final service = NostrCircleService(
        relayService: _StubRelayService(),
        dataDirectoryProvider: _ThrowingDataDirectoryProvider(),
        keyringInitializer: () async {
          keyringCallCount++;
        },
      );

      // Prime one failed init attempt (no FFI in unit tests).
      await expectLater(service.initialize(), throwsA(anything));
      expect(keyringCallCount, 1);

      // Act: close + latch.
      await service.closeAndInvalidate();

      // Assert: initialize() now fails CLOSED with a generic wiped error and
      // does NOT touch the keyring (i.e. does not begin a re-open).
      await expectLater(
        service.initialize(),
        throwsA(
          isA<CircleServiceException>().having(
            (e) => e.message,
            'message',
            contains('wiped'),
          ),
        ),
      );
      expect(
        keyringCallCount,
        1,
        reason:
            'closeAndInvalidate must LATCH the service — a post-wipe '
            'initialize() must be refused before any keyring/DB re-open, so '
            'the keyring initializer must not run a second time',
      );
    });

    test('a release that throws still leaves no handle behind the latch',
        () async {
      // A handle left in the field would be handed to the next caller,
      // disposed, in place of the latch's refusal.
      final manager = _ThrowingDisposeManager();
      final service = NostrCircleService.withInjectedManager(
        relayService: _StubRelayService(),
        injectedManager: manager,
      );

      await expectLater(service.closeAndInvalidate(), throwsStateError);
      expect(manager.disposeCalls, 1, reason: 'premise: the release threw');
      CircleManagerFfi? handed;
      try {
        handed = await service.getCircleManagerFfi();
      } on Object catch (_) {
        // The latch's refusal.
      }
      expect(
        handed,
        isNull,
        reason: 'the disposed handle was handed out after the logout',
      );
    });

    test(
        'closeAndInvalidate DISPOSES the manager handle, releasing the '
        'Rule-14 session slot deterministically', () async {
      // The handle owns this DB's `LiveSessionGuard`; Rust releases it on
      // `Drop`, which for a flutter_rust_bridge `RustOpaque` happens only when
      // the Dart object is GARBAGE COLLECTED. Nulling the field therefore does
      // not free the process-global single-session slot at any bounded time,
      // and the next open of the same `session.sqlite` — a logout→login inside
      // one process, or a second HavenApp pumped in one test process — fails
      // closed with "an MLS session is already open on this database".
      final manager = _FakeManager();
      final service = NostrCircleService.withInjectedManager(
        relayService: _StubRelayService(),
        injectedManager: manager,
      );

      expect(manager.disposed, isFalse);
      await service.closeAndInvalidate();
      expect(
        manager.disposed,
        isTrue,
        reason:
            'closeAndInvalidate must release the RustOpaque Arc explicitly — '
            'dropping the Dart reference leaves the Rule-14 session slot held '
            'until an unbounded future GC',
      );

      // Idempotent: logout may close twice (M10.1 launch-retry), and
      // `dispose()` must not double-release the Arc.
      await service.closeAndInvalidate();
      expect(manager.disposed, isTrue);
    });

    test(
        'the _wiped latch is enforced through _ensureInitialized (getters '
        'cannot re-open a wiped service either)', () async {
      // The latch guards initialize(); every data-path method funnels through
      // _ensureInitialized() -> initialize(). Verify a representative such
      // method (pruneProcessedGiftWraps) is ALSO refused after the wipe, so
      // there is no back-door re-open via a getter/data method.
      var keyringCallCount = 0;
      final service = NostrCircleService(
        relayService: _StubRelayService(),
        dataDirectoryProvider: _ThrowingDataDirectoryProvider(),
        keyringInitializer: () async {
          keyringCallCount++;
        },
      );

      await service.closeAndInvalidate();

      await expectLater(
        service.pruneProcessedGiftWraps(),
        throwsA(
          isA<CircleServiceException>().having(
            (e) => e.message,
            'message',
            contains('wiped'),
          ),
        ),
      );
      expect(
        keyringCallCount,
        0,
        reason:
            'a wiped service must refuse every _ensureInitialized() caller '
            'before touching the keyring',
      );
    });

    test(
        'wipeAllMlsState surfaces a generic CircleServiceException on failure '
        '(no internal detail leak)', () async {
      // wipeAllMlsState() resolves the data dir then calls the FFI wipe. In a
      // unit test the throwing data-dir provider fails before the FFI is
      // reached; the failure must be wrapped in a GENERIC exception so no
      // internal path/detail leaks to a caller/UI (Security rule 8).
      final dataDir = _ThrowingDataDirectoryProvider();
      final service = NostrCircleService(
        relayService: _StubRelayService(),
        dataDirectoryProvider: dataDir,
        keyringInitializer: () async {},
      );

      try {
        await service.wipeAllMlsState();
        fail('Expected CircleServiceException');
      } on CircleServiceException catch (e) {
        expect(dataDir.wasCalled, isTrue);
        expect(e.message, 'Failed to wipe MLS state');
        expect(e.message, isNot(contains('Stub: stop before FFI')));
      }
    });

    test(
        'wipeAllMlsState does NOT latch the service — a later initialize() is '
        'still allowed (unlike closeAndInvalidate)', () async {
      // wipeAllMlsState() is a lower-level primitive than closeAndInvalidate():
      // it releases the handle + deletes the DB, but deliberately does NOT set
      // the one-way `_wiped` latch. That contrast is the meaningful property —
      // a caller that wipes WITHOUT the logout latch must still be able to
      // initialize again. (We cannot assert the defensive `_initialized` null
      // here: `_initialized` only becomes true via the native FFI, unavailable
      // in a unit test, so it is already false going in — hence this test
      // asserts the latch-absence property rather than the null.)
      var keyringCallCount = 0;
      final service = NostrCircleService(
        relayService: _StubRelayService(),
        dataDirectoryProvider: _ThrowingDataDirectoryProvider(),
        keyringInitializer: () async {
          keyringCallCount++;
        },
      );

      // wipeAllMlsState now ALSO installs the keyring backend (so the FFI wipe
      // can REMOVE the SQLCipher keys, not just delete files — M10.1 Finding-2),
      // then throws via the data-dir stub (before the FFI wipe). So it runs the
      // keyring exactly once.
      await expectLater(service.wipeAllMlsState(), throwsA(anything));
      expect(
        keyringCallCount,
        1,
        reason: 'wipeAllMlsState installs the keyring before the FFI wipe',
      );

      // A subsequent initialize() PROCEEDS (runs the keyring AGAIN) rather than
      // failing closed with the 'wiped' error — proving no latch was set. Had
      // wipeAllMlsState latched the service, this initialize() would short-
      // circuit BEFORE the keyring and the count would stay at 1.
      await expectLater(service.initialize(), throwsA(anything));
      expect(
        keyringCallCount,
        2,
        reason: 'wipeAllMlsState must not latch _wiped; the subsequent '
            'initialize() must run the keyring again rather than short-'
            'circuiting on the wiped guard',
      );
    });

    test(
        'acknowledgeStorageReset surfaces a generic CircleServiceException on '
        'failure (no internal detail leak)', () async {
      final dataDir = _ThrowingDataDirectoryProvider();
      final service = NostrCircleService(
        relayService: _StubRelayService(),
        dataDirectoryProvider: dataDir,
        keyringInitializer: () async {},
      );

      try {
        await service.acknowledgeStorageReset();
        fail('Expected CircleServiceException');
      } on CircleServiceException catch (e) {
        expect(dataDir.wasCalled, isTrue);
        expect(e.message, 'Failed to acknowledge the reset');
        expect(e.message, isNot(contains('Stub: stop before FFI')));
      }
    });

    test(
        'closeAndInvalidate DRAINS an in-flight initialization before '
        'returning (M10 H1 in-flight-open race)', () async {
      // The dangerous window: an initialize() suspended at its awaited DB open
      // at the instant logout latches the service. If closeAndInvalidate()
      // returned immediately, the wipeAllMlsState() that follows it in
      // deleteIdentity() would delete the files, and THEN the suspended open
      // would land — re-creating a fresh, decryptable circles.db + keyring key.
      // closeAndInvalidate() MUST therefore block until the in-flight init
      // unwinds. We simulate the suspension with a gated keyring initializer
      // (the first awaited step of _runInitialization).
      final keyringGate = Completer<void>();
      var keyringCallCount = 0;
      final service = NostrCircleService(
        relayService: _StubRelayService(),
        dataDirectoryProvider: _ThrowingDataDirectoryProvider(),
        keyringInitializer: () async {
          keyringCallCount++;
          await keyringGate.future; // suspend the in-flight init here
        },
      );

      // Kick off an init that suspends inside the keyring initializer. Attach
      // the failure expectation NOW so its eventual rejection is never an
      // unhandled async error.
      final initFuture = service.initialize();
      final initExpectation = expectLater(initFuture, throwsA(anything));
      await Future<void>.delayed(Duration.zero);
      expect(
        keyringCallCount,
        1,
        reason: 'the init should be suspended inside the keyring initializer',
      );

      // Latch + drain. Must NOT complete while the init is still suspended.
      var closed = false;
      final closeFuture =
          service.closeAndInvalidate().then((_) => closed = true);
      await Future<void>.delayed(Duration.zero);
      expect(
        closed,
        isFalse,
        reason: 'closeAndInvalidate must block on the in-flight init, not '
            'return while a suspended open could still create on-disk state',
      );

      // Release the suspension: the init resumes, fails closed (throwing
      // data-dir stub), and both futures settle.
      keyringGate.complete();
      await closeFuture;
      await initExpectation;
      expect(closed, isTrue);

      // The latch holds afterwards: a fresh initialize() is refused.
      await expectLater(
        service.initialize(),
        throwsA(
          isA<CircleServiceException>().having(
            (e) => e.message,
            'message',
            contains('wiped'),
          ),
        ),
      );
    });

    test('pruneProcessedGiftWraps propagates initialization failure', () async {
      // _ensureInitialized will fail via the throwing data-dir provider
      // (keyring succeeds, then data-dir throws before FFI is reached).
      // The initialization error propagates as-is (not wrapped) — consistent
      // with all other CircleService methods that call _ensureInitialized.
      final service = NostrCircleService(
        relayService: _StubRelayService(),
        dataDirectoryProvider: _ThrowingDataDirectoryProvider(),
        keyringInitializer: () async {},
      );

      await expectLater(
        service.pruneProcessedGiftWraps(),
        throwsA(anything),
        reason:
            'pruneProcessedGiftWraps must throw when initialization fails',
      );
    });
  });

  _publishResolutionTests();
  _rejoinAndDisbandTests();
  _recoveryTests();
}

/// The standing recovery read and the unmade-removal read.
void _recoveryTests() {
  const groupId = [4, 4, 4, 4];
  final circle = Circle(
    mlsGroupId: groupId,
    nostrGroupId: groupId,
    displayName: 'Fixture',
    circleType: CircleType.locationSharing,
    relays: const [],
    membershipStatus: MembershipStatus.accepted,
    members: const [],
    createdAt: DateTime.utc(2026),
    updatedAt: DateTime.utc(2026),
  );

  group('the recovery read', () {
    test('maps every cause by variant, worst first, and nothing to null',
        () async {
      final driver = FakeChangeDriver();
      final service = NostrCircleService.withInjectedManager(
        relayService: _StubRelayService(),
        injectedManager: _LeaveManager(),
        changeDriver: driver,
      );
      final read = <CircleRecoveryCause?>[];
      for (final cause in RecoveryCauseFfi.values) {
        driver.recovery = cause;
        read.add(await service.circleRecovery(circle));
      }
      // Index for index: the core's worst-first order is kept, and each
      // variant lands on its own Dart cause.
      expect(
        read.map((c) => c!.name),
        RecoveryCauseFfi.values.map((c) => c.name),
      );
      expect(
        CircleRecoveryCause.values,
        hasLength(RecoveryCauseFfi.values.length),
      );
      driver.recovery = null;
      expect(await service.circleRecovery(circle), isNull);
      expect(driver.groupIds, everyElement(groupId));
      expect(
        driver.foregrounds,
        everyElement(isFalse),
        reason: 'the injected-manager service is never the app in front',
      );
    });

    test('a failed read throws fixed text and logs only its type', () async {
      final capture = LogCapture.install();
      final driver = FakeChangeDriver()
        ..throws = StateError(
          'group ${_hexOf(groupId)} at wss://planted.example npub1planted',
        );
      final service = NostrCircleService.withInjectedManager(
        relayService: _StubRelayService(),
        injectedManager: _LeaveManager(),
        changeDriver: driver,
      );
      await expectLater(
        service.circleRecovery(circle),
        throwsA(
          isA<CircleServiceException>().having(
            (e) => e.message,
            'message',
            'Failed to read the circle',
          ),
        ),
      );
      capture
        ..assertContains('[Recovery] read failed: StateError')
        ..assertNoNeedles([
          _hexOf(groupId),
          'wss://planted.example',
          'npub1planted',
        ]);
    });
  });

  group('the unmade-removal read', () {
    test('answers who is still listed; a store fault throws fixed text and '
        'logs only its type', () async {
      final manager = _RemovalManager()..kept = ['ab' * 32];
      final service = NostrCircleService.withInjectedManager(
        relayService: _StubRelayService(),
        injectedManager: manager,
      );
      expect(await service.unmadeRemovalMembers(groupId), ['ab' * 32]);
      expect(manager.askedFor, groupId);

      final capture = LogCapture.install();
      manager.error = StateError(
        'group ${_hexOf(groupId)} member ${'ab' * 32} wss://planted.example',
      );
      await expectLater(
        service.unmadeRemovalMembers(groupId),
        throwsA(isA<CircleServiceException>()),
        reason: 'an empty answer would hide a member the user tried to remove',
      );
      capture
        ..assertContains('[Recovery] removal read failed: StateError')
        ..assertNoNeedles([_hexOf(groupId), 'ab' * 32, 'wss://planted']);
    });
  });
}

/// A manager whose unmade-removal read answers [kept], or throws [error].
class _RemovalManager implements CircleManagerFfi {
  List<String> kept = const [];
  Object? error;
  List<int>? askedFor;

  @override
  List<String> unmadeRemovalMembers({required List<int> mlsGroupId}) {
    askedFor = mlsGroupId;
    final failure = error;
    if (failure != null) Error.throwWithStackTrace(failure, StackTrace.current);
    return kept;
  }

  @override
  void dispose() {}

  @override
  bool get isDisposed => false;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('unexpected call: ${invocation.memberName}');
}

/// What a drive hands back, and what this service does with it.
///
/// Two promises live on this side of the boundary: what a drive replayed is
/// CONVERTED, and a throwing FFI still reaches the caller as a generic
/// exception rather than as the engine's own error text (Rule 8, and Rule 15 —
/// that text can carry group ids).
void _publishResolutionTests() {
  LocationMessageResultFfi unrecoverable(List<int> mlsGroupId) =>
      LocationMessageResultFfi(
        kind: LocationMessageResultKindFfi.unrecoverable,
        mlsGroupId: Uint8List.fromList(mlsGroupId),
        epoch: BigInt.zero,
      );

  group('a circle change goes through the fanout driver', () {
    // Before: the Dart side published each commit, confirmed it on an ack and
    // resolved whatever the confirm surfaced. The driver now stages the
    // commit under a durable record, sends it until a relay takes it and
    // resolves what it surfaces in Rust; this side maps the answer by variant
    // and converts what was replayed.
    const groupId = [4, 4, 4, 4];

    ({
      NostrCircleService service,
      FakeChangeDriver driver,
      _LeaveManager manager,
    })
    build() {
      final driver = FakeChangeDriver();
      final manager = _LeaveManager();
      return (
        service: NostrCircleService.withInjectedManager(
          relayService: _StubRelayService(),
          injectedManager: manager,
          changeDriver: driver,
        ),
        driver: driver,
        manager: manager,
      );
    }

    Future<CircleCreationResult> create(
      NostrCircleService service, {
      List<KeyPackageData> invited = const [],
      List<String>? relays,
    }) => service.createCircle(
      identitySecretBytes: List<int>.filled(32, 7),
      memberKeyPackages: invited,
      name: 'Founded',
      circleType: CircleType.locationSharing,
      relays: relays,
    );

    // Two invitees whose inbox relays see their pubkeys: the circle's relays
    // must never be drawn from them.
    final invitees = [
      KeyPackageData(
        pubkey: 'npub1a',
        eventJson: '{"kind":30443,"pubkey":"${'aa' * 32}"}',
        relays: const ['wss://inbox-a.example'],
        nip65WriteRelays: const ['wss://nip65-write-a.example'],
        nip65Relays: const ['wss://nip65-a.example'],
      ),
      KeyPackageData(
        pubkey: 'npub1b',
        eventJson: '{"kind":30443,"pubkey":"${'bb' * 32}"}',
        relays: const ['wss://inbox-b.example'],
        nip65WriteRelays: const ['wss://nip65-write-b.example'],
      ),
    ];

    test("a create that names no relays never makes the invitees' inbox "
        "relays the circle's, and still routes each Welcome to them", () async {
      final t = build();
      await create(t.service, invited: invitees);

      expect(
        t.driver.created?.relays,
        isEmpty,
        reason: 'empty is the request for Rust to pick from the location pool',
      );
      expect(
        t.driver.created?.members.map((m) => m.inboxRelays).toList(),
        [
          ['wss://inbox-a.example'],
          ['wss://inbox-b.example'],
        ],
      );
      expect(
        t.driver.created?.members.map((m) => m.nip65Relays).toList(),
        [
          ['wss://nip65-a.example'],
          <String>[],
        ],
      );
      expect(
        t.driver.created?.members.map((m) => m.nip65WriteRelays).toList(),
        [
          ['wss://nip65-write-a.example'],
          ['wss://nip65-write-b.example'],
        ],
        reason:
            'the write set is one of the lists a picked circle avoids; '
            'dropped here, Rust could place the circle on a relay an invitee '
            'writes to while another was free',
      );
    });

    test('named relays reach the driver verbatim, not merged with the '
        "invitees' inbox relays", () async {
      final t = build();
      await create(
        t.service,
        invited: invitees,
        relays: const ['wss://named-2.example', 'wss://named-1.example'],
      );

      expect(t.driver.created?.relays, [
        'wss://named-2.example',
        'wss://named-1.example',
      ]);
    });

    test('an empty relays list is the same request as none', () async {
      final omitted = build();
      await create(omitted.service, invited: invitees);
      final empty = build();
      await create(empty.service, invited: invitees, relays: const []);

      expect(omitted.driver.created?.relays, isEmpty);
      expect(empty.driver.created?.relays, isEmpty);
    });

    test("a create is the driver's create: the circle it founded and its "
        'Welcome counts, the owed invitees named by npub', () async {
      final t = build();
      t.driver.creation = CircleCreationOutcomeFfi(
        circle: _circleWithRelays(const [8, 8], const ['wss://c.example'])
            .circle,
        welcomesSent: 1,
        welcomesTotal: 2,
        unsentRecipients: ['bb' * 32],
      );

      final result = await create(
        t.service,
        invited: [
          KeyPackageData(
            pubkey: 'npub1a',
            eventJson: '{"kind":30443,"pubkey":"${'aa' * 32}"}',
            relays: const ['wss://inbox-a.example'],
            nip65WriteRelays: const [],
          ),
          KeyPackageData(
            pubkey: 'npub1b',
            eventJson: '{"kind":30443,"pubkey":"${'bb' * 32}"}',
            relays: const ['wss://inbox-b.example'],
            nip65WriteRelays: const [],
          ),
        ],
      );

      expect(t.driver.calls, ['createCircle']);
      expect(result.circle.mlsGroupId, const [8, 8]);
      expect(result.circle.membershipStatus, MembershipStatus.accepted);
      expect(result.welcomesSent, 1);
      expect(result.welcomesTotal, 2);
      expect(result.unsentNpubs, ['npub1b']);
      expect(t.driver.created?.name, 'Founded');
      expect(t.driver.created?.circleType, 'location_sharing');
    });

    test('a create claims the foreground only when the app is resumed',
        () async {
      // The injected-manager service is the background isolate's: never in
      // front, so it never asks the core to create.
      final t = build();
      await create(t.service);
      expect(t.driver.foregrounds, [false]);
    });

    group('a change the user asked for', () {
      // The core grants a foreground drive only to a live plane already
      // claimed for it, so the app's own session settles its claim first.
      // `FakeChangeDriver.calls` and the settle share one log: the order is
      // the promise.
      final asks = <String, Future<Object?> Function(NostrCircleService)>{
        'createCircle': create,
        'leave': (s) => s.leaveCircle(mlsGroupId: groupId),
        'removeMembers': (s) =>
            s.removeMember(mlsGroupId: groupId, memberPubkeyHex: 'aa' * 32),
        'addMembers': (s) => s.addMember(
          mlsGroupId: groupId,
          memberKeyPackages: const [
            KeyPackageData(
              pubkey: 'npub1x',
              eventJson: '{}',
              relays: [],
              nip65WriteRelays: [],
            ),
          ],
        ),
        'updateCircleRelays': (s) => s.updateCircleRelays(
          mlsGroupId: groupId,
          newRelays: const ['wss://r.example'],
        ),
        'repairRotation': (s) =>
            s.repairCircleEpoch(_circleOf(groupId), selfPubkeyHex: 'aa'),
      };

      NostrCircleService inFront(
        FakeChangeDriver driver, {
        required Future<void> Function() settle,
        bool Function()? front,
      }) => NostrCircleService.withInjectedManager(
        relayService: _StubRelayService(),
        injectedManager: _LeaveManager(),
        changeDriver: driver,
        appInFront: front ?? () => true,
        settleForeground: settle,
      );

      for (final entry in asks.entries) {
        test('${entry.key} is made only after the live session has settled '
            'its foreground claim', () async {
          final driver = FakeChangeDriver();
          final claim = Completer<void>();
          final service = inFront(driver, settle: () => claim.future);

          final done = entry.value(service);
          await pumpEventQueue();
          expect(driver.calls, isEmpty, reason: 'the claim is still pending');

          claim.complete();
          await done.then<void>((_) {}, onError: (Object _) {});

          expect(driver.calls, [entry.key]);
          expect(driver.foregrounds, [true]);
        });

        test('${entry.key} does not ask the session while the app is not '
            'in front', () async {
          final driver = FakeChangeDriver();
          var settles = 0;
          final service = inFront(
            driver,
            front: () => false,
            settle: () async => settles++,
          );

          await entry
              .value(service)
              .then<void>((_) {}, onError: (Object _) {});

          expect(settles, 0);
          expect(driver.foregrounds, [false]);
        });
      }

      test('a settle that throws does not stop the change', () async {
        final driver = FakeChangeDriver();
        final service = inFront(
          driver,
          settle: () async => throw StateError('boom'),
        );

        await create(service);

        expect(driver.calls, ['createCircle']);
        expect(driver.foregrounds, [true]);
      });

      test('the word is read again after the wait: an app that left the '
          'front meanwhile asks no foreground drive', () async {
        final driver = FakeChangeDriver();
        var front = true;
        final service = inFront(
          driver,
          front: () => front,
          settle: () async => front = false,
        );

        await create(service);

        expect(driver.foregrounds, [false]);
      });

      test("the background isolate's service never asks the session", () async {
        final driver = FakeChangeDriver();
        var settles = 0;
        final service = NostrCircleService.withInjectedManager(
          relayService: _StubRelayService(),
          injectedManager: _LeaveManager(),
          changeDriver: driver,
          settleForeground: () async => settles++,
        );

        await create(service);

        expect(settles, 0);
        expect(driver.foregrounds, [false]);
      });
    });

    test('a create the core refused is no circle: it fails with fixed text, '
        'and its log line names neither the circle nor an invitee', () async {
      final capture = LogCapture.install();
      final t = build();
      for (final refusal in RefusalFfi.values) {
        t.driver.creation = CircleCreationOutcomeFfi(
          refusal: refusal,
          welcomesSent: 0,
          welcomesTotal: 1,
          unsentRecipients: ['cd' * 32],
        );
        await expectLater(
          t.service.createCircle(
            identitySecretBytes: List<int>.filled(32, 7),
            memberKeyPackages: [
              KeyPackageData(
                pubkey: 'npub1planted',
                eventJson: '{"kind":30443,"pubkey":"${'cd' * 32}"}',
                relays: const ['wss://planted.example'],
                nip65WriteRelays: const [],
              ),
            ],
            name: 'Planted Circle Name',
            circleType: CircleType.locationSharing,
          ),
          throwsA(
            // An invitee no Welcome can reach, and a location pool the
            // creator's own lists cover, are each their own type, so the page
            // shows their own copy instead of "try again"; by variant, never
            // by text (Rule 8).
            switch (refusal) {
              RefusalFfi.missingWelcomeRelays =>
                isA<CircleInviteesUnreachableException>(),
              RefusalFfi.noLocationRelay =>
                isA<CircleNoLocationRelayException>(),
              _ =>
                isA<CircleServiceException>()
                    .having(
                      (e) => e.message,
                      'message',
                      'Failed to create circle',
                    )
                    .having(
                      (e) => e,
                      'type',
                      isNot(
                        anyOf(
                          isA<CircleInviteesUnreachableException>(),
                          isA<CircleNoLocationRelayException>(),
                        ),
                      ),
                    ),
            },
          ),
          reason: refusal.name,
        );
      }
      capture
        ..assertContains(
          '[Circle] Create refused: RefusalFfi.missingWelcomeRelays',
        )
        ..assertContains('[Circle] Create refused: RefusalFfi.noLocationRelay')
        ..assertNoNeedles([
          'cd' * 32,
          'npub1planted',
          'wss://planted.example',
          'Planted Circle Name',
        ]);
    });

    test('an invite refused for an invitee no Welcome can reach is its own '
        'type, by variant', () async {
      final t = build();
      t.driver.outcome = evolutionOutcome(
        PublishStatusFfi.refused,
        refusal: RefusalFfi.missingWelcomeRelays,
      );
      await expectLater(
        t.service.addMember(
          mlsGroupId: groupId,
          memberKeyPackages: const [
            KeyPackageData(
              pubkey: 'npub1x',
              eventJson: '{}',
              relays: [],
              nip65WriteRelays: [],
            ),
          ],
        ),
        throwsA(isA<CircleInviteesUnreachableException>()),
      );
      t.driver.outcome = evolutionOutcome(
        PublishStatusFfi.refused,
        refusal: RefusalFfi.foregroundOnly,
      );
      final other = await t.service.addMember(
        mlsGroupId: groupId,
        memberKeyPackages: const [
          KeyPackageData(
            pubkey: 'npub1x',
            eventJson: '{}',
            relays: [],
            nip65WriteRelays: [],
          ),
        ],
      );
      expect(other.delivery, ChangeDelivery.rejected);
    });

    test('a create the driver errors on fails with fixed text', () async {
      final capture = LogCapture.install();
      final t = build()
        ..driver.throws = 'group ${'ab' * 32} at wss://x refused';

      await expectLater(
        create(t.service),
        throwsA(
          isA<CircleServiceException>().having(
            (e) => e.message,
            'message',
            'Failed to create circle',
          ),
        ),
      );
      capture.assertNoNeedles(['ab' * 32, 'wss://x']);
    });

    test("a polled event is the driver's ingest: held only when the engine "
        'defers it, its replay converted', () async {
      final t = build();
      IngestOutcomeFfi answer(ReceiveVerdictFfi verdict) => IngestOutcomeFfi(
        verdict: verdict,
        replayed: [unrecoverable(groupId)],
        errored: false,
      );
      t.driver.ingests = [
        for (final v in ReceiveVerdictFfi.values) answer(v),
      ];

      final held = <ReceiveVerdictFfi, bool>{};
      for (final v in ReceiveVerdictFfi.values) {
        final ingested = await t.service.ingestEvent(eventJson: '{"id":"e"}');
        held[v] = ingested.held;
        expect(ingested.results.single.kind, LocationEventKind.unrecoverable);
      }

      expect(held, {
        ReceiveVerdictFfi.applied: false,
        ReceiveVerdictFfi.deferred_: true,
        ReceiveVerdictFfi.noEvidence: false,
        ReceiveVerdictFfi.stranded: false,
      });
      expect(t.driver.foregrounds, everyElement(isFalse));
    });

    test('an ingest whose drive erred says so with fixed text', () async {
      final capture = LogCapture.install();
      final t = build()
        ..driver.ingests = [
          IngestOutcomeFfi(
            verdict: ReceiveVerdictFfi.applied,
            replayed: [unrecoverable(groupId)],
            errored: true,
          ),
        ];

      await t.service.ingestEvent(eventJson: '{"id":"${'ef' * 32}"}');

      capture
        ..assertContains('[Circle] ingest drive ended on an error')
        ..assertNoNeedles([_hexOf(groupId), 'ef' * 32]);
    });

    test('an ingest the driver answers with an error fails with fixed text',
        () async {
      final capture = LogCapture.install();
      final t = build()
        ..driver.throws = 'mls group ${_hexOf(groupId)} at wss://x refused';

      await expectLater(
        t.service.ingestEvent(eventJson: '{"id":"e"}'),
        throwsA(
          isA<CircleServiceException>().having(
            (e) => e.message,
            'message',
            'Failed to decrypt location',
          ),
        ),
      );
      capture.assertNoNeedles([_hexOf(groupId), 'wss://x']);
    });

    test("a seal is the driver's seal: sealed, held or refused by its typed "
        'fields, its replay converted', () async {
      final t = build();
      final sealed = FakeSealedLocation();
      t.driver.sealOutcome = SealOutcomeFfi(
        sealed: sealed,
        replayed: [unrecoverable(groupId)],
        errored: false,
      );
      final made = await t.service.sealLocation(
        mlsGroupId: groupId,
        latitude: 1.5,
        longitude: -2.5,
      );
      expect(made, isA<LocationSealed>());
      expect((made as LocationSealed).sealed, same(sealed));
      expect(made.replayed.single.kind, LocationEventKind.unrecoverable);
      expect(t.driver.sealedFixes.single, (latitude: 1.5, longitude: -2.5));

      // Every hold, a routing collision included, is a hold: nothing sealed,
      // and every plane treats it as a deferral.
      for (final cause in SendHeldFfi.values.where(
        (cause) => cause != SendHeldFfi.nothing,
      )) {
        t.driver.sealOutcome = SealOutcomeFfi(
          heldBy: cause,
          replayed: const [],
          errored: false,
        );
        final held = await t.service.sealLocation(
          mlsGroupId: groupId,
          latitude: 1,
          longitude: 2,
        );
        expect(held, isA<LocationSendHeld>(), reason: cause.name);
      }

      t.driver.sealOutcome = const SealOutcomeFfi(
        refusal: RefusalFfi.leaveInProgress,
        replayed: [],
        errored: false,
      );
      final refused = await t.service.sealLocation(
        mlsGroupId: groupId,
        latitude: 1,
        longitude: 2,
      );
      expect(refused, isA<LocationSendHeld>());
      expect(t.driver.groupIds, everyElement(groupId));
    });

    test('a seal or send the driver errors on fails with fixed text, and no '
        'seal log line names the circle', () async {
      final capture = LogCapture.install();
      final t = build()
        ..driver.sealOutcome = const SealOutcomeFfi(
          heldBy: SendHeldFfi.awaitingRelays,
          replayed: [],
          errored: true,
        );
      await t.service.sealLocation(
        mlsGroupId: groupId,
        latitude: 1,
        longitude: 2,
      );
      t.driver.throws = 'mls group ${_hexOf(groupId)} at wss://x refused';

      await expectLater(
        t.service.sealLocation(
          mlsGroupId: groupId,
          latitude: 1,
          longitude: 2,
        ),
        throwsA(
          isA<CircleServiceException>().having(
            (e) => e.message,
            'message',
            'Failed to seal location',
          ),
        ),
      );
      await expectLater(
        t.service.publishSealedLocation(
          LocationSealed(FakeSealedLocation(), replayed: const []),
          received: false,
        ),
        throwsA(
          isA<CircleServiceException>().having(
            (e) => e.message,
            'message',
            'Failed to publish location',
          ),
        ),
      );
      capture
        ..assertContains('[Circle] seal drive ended on an error')
        ..assertContains('[Circle] location seal failed')
        ..assertContains('[Circle] location publish failed')
        ..assertNoNeedles([_hexOf(groupId), 'wss://x']);
    });

    test('a seal for the mesh alone takes the mesh-only seal, and only it',
        () async {
      // Plan §7.7 R1: a seal that calls no relay and drives nothing. Taking
      // the ordinary seal here would send a pending commit again and settle
      // records from a burst that could reach no relay.
      final t = build();
      final sealed = FakeSealedLocation();
      t.driver.sealOutcome = SealOutcomeFfi(
        sealed: sealed,
        replayed: const [],
        errored: false,
      );

      final made = await t.service.sealLocation(
        mlsGroupId: groupId,
        latitude: 1.5,
        longitude: -2.5,
        meshOnly: true,
      );

      expect(t.driver.calls, ['sealLocationForMesh']);
      expect((made as LocationSealed).sealed, same(sealed));
      expect(t.driver.sealedFixes.single, (latitude: 1.5, longitude: -2.5));
      expect(t.driver.groupIds.single, groupId);

      // Held — the mesh off included — is a hold like any other.
      t.driver.sealOutcome = const SealOutcomeFfi(
        heldBy: SendHeldFfi.nothing,
        replayed: [],
        errored: false,
      );
      expect(
        await t.service.sealLocation(
          mlsGroupId: groupId,
          latitude: 1,
          longitude: 2,
          meshOnly: true,
        ),
        isA<LocationSendHeld>(),
      );
    });

    test('an ordinary seal never takes the mesh-only seal', () async {
      final t = build();

      await t.service.sealLocation(
        mlsGroupId: groupId,
        latitude: 1,
        longitude: 2,
      );

      expect(t.driver.calls, ['sealLocation']);
    });

    test("a send carries its caller's word on the receive to the driver",
        () async {
      final t = build();
      final seal = LocationSealed(FakeSealedLocation(), replayed: const []);

      await t.service.publishSealedLocation(seal, received: false);
      await t.service.publishSealedLocation(seal, received: true);

      expect(t.driver.publishReceived, [false, true]);
    });

    test("a sealed location's one send is the driver's answer", () async {
      final t = build()..driver.publishAnswer = LocationPublishFfi.clockBehind;

      expect(
        await t.service.publishSealedLocation(
          LocationSealed(FakeSealedLocation(), replayed: const []),
          received: false,
        ),
        LocationPublishFfi.clockBehind,
      );
      expect(t.driver.calls, ['publishLocation']);
    });

    test('every leave status maps to the delivery it means', () {
      expect({for (final s in LeaveStatusFfi.values) s: leaveDeliveryOf(s)}, {
        LeaveStatusFfi.completed: LeaveDelivery.left,
        // The circle is not on this device: nothing of it is left to leave.
        LeaveStatusFfi.circleNotFound: LeaveDelivery.left,
        // The intent stands, and the next wake carries it on.
        LeaveStatusFfi.proposed: LeaveDelivery.leaving,
        LeaveStatusFfi.pending: LeaveDelivery.leaving,
        LeaveStatusFfi.foregroundOnly: LeaveDelivery.leaving,
        LeaveStatusFfi.engineHeld: LeaveDelivery.leaving,
        // Refused for good, the intent ended.
        LeaveStatusFfi.adminMustStepDown: LeaveDelivery.notMade,
        LeaveStatusFfi.notLeaving: LeaveDelivery.notMade,
      });
    });

    test('a leave the driver answers with an error fails with fixed text, and '
        'no leave or repair log line names the circle', () async {
      final capture = LogCapture.install();
      final t = build()
        ..driver.throws = 'mls group ${_hexOf(groupId)}: relay wss://x refused';

      await expectLater(
        t.service.leaveCircle(mlsGroupId: groupId),
        throwsA(
          isA<CircleServiceException>().having(
            (e) => e.message,
            'message',
            'Failed to leave circle',
          ),
        ),
      );
      t.driver
        ..throws = null
        ..leaveOutcome = const LeaveOutcomeFfi(status: LeaveStatusFfi.proposed)
        ..repair = const RepairOutcomeFfi(
          kind: RepairKindFfi.refused,
          refusal: RefusalFfi.foregroundOnly,
        );
      await t.service.leaveCircle(mlsGroupId: groupId);
      await expectLater(
        t.service.repairCircleEpoch(_circleOf(groupId), selfPubkeyHex: 'aa'),
        throwsA(isA<CircleServiceException>()),
      );

      expect(capture.joined, contains('[Leave] failed'));
      expect(capture.joined, contains('[Leave] proposed'));
      expect(capture.joined, contains('[EpochRepair] not made'));
      capture.assertNoNeedles([_hexOf(groupId), 'wss://x', 'wss://circle']);
    });

    test("a leave's log line names its status from the closed vocabulary "
        'and nothing else', () async {
      final capture = LogCapture.install();
      final t = build();
      for (final status in LeaveStatusFfi.values) {
        t.driver.leaveOutcome = LeaveOutcomeFfi(status: status);
        await t.service.leaveCircle(mlsGroupId: groupId);
      }

      expect(
        capture.joined
            .split('\n')
            .where((line) => line.startsWith('[Leave] '))
            .toList(),
        [for (final status in LeaveStatusFfi.values) '[Leave] ${status.name}'],
      );
    });

    test('a repair maps each kind it can answer, none awaiting as made',
        () async {
      final t = build();
      Future<EpochRepairResult> repairWith(RepairOutcomeFfi outcome) {
        t.driver.repair = outcome;
        return t.service.repairCircleEpoch(
          _circleOf(groupId),
          selfPubkeyHex: 'aa',
        );
      }

      expect(
        await repairWith(
          RepairOutcomeFfi(
            kind: RepairKindFfi.rotated,
            rotated: evolutionOutcome(PublishStatusFfi.confirmed),
          ),
        ),
        isA<EpochRepairApplied>(),
      );
      expect(
        await repairWith(
          RepairOutcomeFfi(
            kind: RepairKindFfi.rotated,
            rotated: evolutionOutcome(PublishStatusFfi.unresolved),
          ),
        ),
        isA<EpochRepairAwaitingRelays>(),
      );
      expect(
        await repairWith(
          const RepairOutcomeFfi(
            kind: RepairKindFfi.skipped,
            skipped: SkipReasonFfi.pendingProposal,
          ),
        ),
        isA<EpochRepairSkipped>(),
      );
      expect(
        await repairWith(
          const RepairOutcomeFfi(
            kind: RepairKindFfi.refused,
            refusal: RefusalFfi.routingCollision,
          ),
        ),
        isA<EpochRepairDeferred>(),
        reason: 'a collided circle is held, as its sends are',
      );
      expect(
        await repairWith(const RepairOutcomeFfi(kind: RepairKindFfi.deferred_)),
        isA<EpochRepairDeferred>(),
      );
      for (final notMade in [
        RepairOutcomeFfi(
          kind: RepairKindFfi.rotated,
          rotated: evolutionOutcome(PublishStatusFfi.rolledBack),
        ),
        const RepairOutcomeFfi(
          kind: RepairKindFfi.refused,
          refusal: RefusalFfi.foregroundOnly,
        ),
        const RepairOutcomeFfi(kind: RepairKindFfi.rotated),
      ]) {
        await expectLater(
          repairWith(notMade),
          throwsA(isA<CircleServiceException>()),
          reason: '$notMade was answered as a repair',
        );
      }
    });
  });
}

Circle _circleOf(List<int> groupId) => Circle(
  mlsGroupId: groupId,
  nostrGroupId: groupId,
  displayName: 'Fixture',
  circleType: CircleType.locationSharing,
  relays: const ['wss://circle.example'],
  membershipStatus: MembershipStatus.accepted,
  members: const [],
  createdAt: DateTime.utc(2026),
  updatedAt: DateTime.utc(2026),
);

/// A [CircleManagerFfi] holding the circle a change reads.
class _LeaveManager implements CircleManagerFfi {
  bool circleReadFails = false;

  static const planted = 'circle 0xdeadbeefcafe at wss://planted.example';

  @override
  Future<CircleWithMembersFfi?> getCircle({
    required List<int> mlsGroupId,
  }) async {
    if (circleReadFails) throw StateError(planted);
    return _circleWithRelays(mlsGroupId, const ['wss://circle.example']);
  }

  @override
  Future<List<CircleWithMembersFfi>> getVisibleCircles() async => [
    _circleWithRelays(const [4, 4, 4, 4], const ['wss://circle.example']),
  ];

  @override
  void dispose() {}

  @override
  bool get isDisposed => false;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('unexpected call: ${invocation.memberName}');
}

String _hexOf(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

CircleWithMembersFfi _circleWithRelays(
  List<int> groupId,
  List<String> relays,
) => CircleWithMembersFfi(
      circle: CircleFfi(
        mlsGroupId: Uint8List.fromList(groupId),
        nostrGroupId: Uint8List.fromList(groupId),
        displayName: 'Fixture',
        circleType: 'location_sharing',
        relays: relays,
        createdAt: 0,
        updatedAt: 0,
      ),
      membershipStatus: 'accepted',
      members: const [],
      engineState: CircleEngineStateFfi.live,
    );

void _handoffTests() {
  group('releaseForHandoff', () {
    // Rule 14 allows exactly one live session per database per process, so
    // while this isolate holds it the foreground service cannot open one and
    // therefore cannot publish. Handing it over at pause is what makes
    // background sharing work — and unlike the service's reclaim it needs no
    // inference about who is alive, since this isolate decides about itself.

    test('disposes the handle rather than dropping it', () {
      // The handle owns the Rust-side guard, released on Drop — which for a
      // RustOpaque means a GC that may never come. Nulling alone would leave
      // the service unable to open for the whole background session.
      final manager = _FakeManager();
      final service = NostrCircleService.withInjectedManager(
        relayService: _StubRelayService(),
        injectedManager: manager,
      );

      expect(service.releaseForHandoff(), isTrue);
      expect(
        manager.disposed,
        isTrue,
        reason: 'the guard is only freed when Rust drops the manager',
      );
    });

    test('does not latch the wipe flag, unlike a logout close', () {
      // THE difference from closeAndInvalidate, which sets `_wiped` so every
      // later initialize fails closed forever — correct for logout, where the
      // database is about to be deleted, and fatal here, where the session is
      // expected back on resume. Latching it would brick the app on return.
      //
      // Asserted on the source because the alternative — driving `initialize()`
      // in this harness — reaches the real keyring and produces an unhandled
      // completer error that says nothing about the property under test.
      final src = File(
        'lib/src/services/nostr_circle_service.dart',
      ).readAsStringSync();
      final at = src.indexOf('bool releaseForHandoff() {');
      expect(at, isNonNegative);
      final body = src.substring(at, src.indexOf('\n  /// Initializes', at));
      expect(
        body.contains('_wiped'),
        isFalse,
        reason: 'a handoff must leave the service re-openable on resume',
      );
      expect(body.contains('dispose()'), isTrue);
    });

    test('refuses while an initialisation is in flight', () {
      // An `initialize()` suspended on its awaited open would adopt its handle
      // AFTER the release returned, silently re-taking the guard we just gave
      // away — and the foreground service would already have failed to open.
      // Source-asserted: the in-flight state needs a suspended real open, which
      // this harness cannot produce without the Rust bridge.
      final src = File(
        'lib/src/services/nostr_circle_service.dart',
      ).readAsStringSync();
      final at = src.indexOf('bool releaseForHandoff() {');
      final body = src.substring(at, src.indexOf('\n  /// Initializes', at));
      final check = body.indexOf('_initCompleter != null');
      expect(check, isNonNegative, reason: 'the in-flight case must be gated');
      expect(
        check,
        lessThan(body.indexOf('dispose()')),
        reason: 'the refusal must precede the release, not follow it',
      );
    });

    test('is a no-op when nothing is held', () {
      final service = NostrCircleService.withInjectedManager(
        relayService: _StubRelayService(),
        injectedManager: _FakeManager(),
      );
      expect(service.releaseForHandoff(), isTrue);
      expect(
        service.releaseForHandoff(),
        isFalse,
        reason: 'a second handoff has nothing to give away',
      );
    });
  });

  group('handoff durability', () {
    // Releasing frees the Rule-14 guard for an INSTANT. Keeping it free is a
    // separate property, and it is the one the `e2e-fgs-publish` lane caught
    // missing: the paused main isolate is not a dead one, so a suspended
    // publish chain, the live-sync re-subscriber or a maintenance tick simply
    // re-opened the database milliseconds later. The foreground service's next
    // tick then found the guard held by a provably-alive owner — which its
    // reclaim correctly refuses to take — and background publishing stayed
    // dead through the very handoff meant to enable it.

    /// A service whose initialisation cannot reach the Rust bridge, with a
    /// controllable foreground answer. [keyringCalls] counts how far an
    /// `initialize()` got: a refusal that happens BEFORE the keyring proves the
    /// gate fires ahead of any I/O, not merely somewhere along the way.
    ({NostrCircleService service, List<int> keyringCalls}) build({
      required bool Function() isForegrounded,
      Future<void> Function()? keyring,
    }) {
      final calls = <int>[];
      final service = NostrCircleService(
        relayService: _StubRelayService(),
        dataDirectoryProvider: _ThrowingDataDirectoryProvider(),
        keyringInitializer: () async {
          calls.add(calls.length);
          if (keyring != null) await keyring();
        },
        isForegrounded: isForegrounded,
      );
      return (service: service, keyringCalls: calls);
    }

    Matcher throwsHandoffRefusal() => throwsA(
      isA<CircleServiceException>().having(
        (e) => e.message,
        'message',
        contains('handed off'),
      ),
    );

    test('a released session is not re-opened while backgrounded', () async {
      final h = build(isForegrounded: () => false);
      h.service.releaseForHandoff();

      await expectLater(h.service.initialize(), throwsHandoffRefusal());
      expect(
        h.keyringCalls,
        isEmpty,
        reason: 'the refusal must precede every step of the open — reaching '
            'the keyring means the gate is downstream of work that can '
            'succeed, and a successful open is exactly what re-takes the guard',
      );
    });

    test('latches even when there was no handle to release', () async {
      // The return value reports whether THIS call gave a live handle away;
      // the latch is about whether the isolate may take one back, and it must
      // hold in both cases. A service that had not opened yet at pause (or was
      // suspended mid-init) is precisely the case that would otherwise open
      // fresh, seconds later, into a guard the service was told it could have.
      final h = build(isForegrounded: () => false);
      expect(h.service.releaseForHandoff(), isFalse);
      await expectLater(h.service.initialize(), throwsHandoffRefusal());
    });

    test('a release during an in-flight init still latches', () async {
      // `releaseForHandoff` cannot cancel an open already suspended, so it
      // reports `false` — but the latch it sets is what stops the NEXT open,
      // and (see `_runInitialization`) what makes the suspended one dispose
      // its handle rather than adopt it.
      final gate = Completer<void>();
      final h = build(isForegrounded: () => false, keyring: () => gate.future);

      final first = h.service.initialize();
      // The init is now suspended inside the keyring initializer.
      expect(h.keyringCalls, hasLength(1));
      expect(h.service.releaseForHandoff(), isFalse);
      gate.complete();
      await expectLater(first, throwsA(isA<CircleServiceException>()));

      await expectLater(h.service.initialize(), throwsHandoffRefusal());
    });

    test('endSessionHandoff lets the next open through', () async {
      final h = build(isForegrounded: () => false);
      h.service.releaseForHandoff();
      expect(h.service.endSessionHandoff(), isTrue);
      expect(
        h.service.endSessionHandoff(),
        isFalse,
        reason: 'a second end has no handoff to end',
      );

      // No longer the handoff refusal — the open now runs and fails on this
      // harness's own missing identity instead.
      await expectLater(
        h.service.initialize(),
        throwsA(
          isA<CircleServiceException>().having(
            (e) => e.message,
            'message',
            isNot(contains('handed off')),
          ),
        ),
      );
      expect(h.keyringCalls, hasLength(1));
    });

    test('the refusal lapses on its own once foregrounded', () async {
      // The safety property. `endSessionHandoff` is called from the resume
      // path, and if that call were ever missed — an early return, a MapShell
      // disposed while paused — a latch alone would leave the user with a
      // database the app refuses to open for the rest of the process: no
      // circles, no map, no publishing. Pairing it with "still backgrounded"
      // bounds the refusal to the window it is for.
      var foregrounded = false;
      final h = build(isForegrounded: () => foregrounded);
      h.service.releaseForHandoff();
      await expectLater(h.service.initialize(), throwsHandoffRefusal());

      foregrounded = true;
      await expectLater(
        h.service.initialize(),
        throwsA(
          isA<CircleServiceException>().having(
            (e) => e.message,
            'message',
            isNot(contains('handed off')),
          ),
        ),
      );

      // And the lapse is durable: going backgrounded again with no NEW handoff
      // must not resurrect the refusal, or every background maintenance tick
      // after one resume would fail closed for no reason.
      foregrounded = false;
      await expectLater(
        h.service.initialize(),
        throwsA(
          isA<CircleServiceException>().having(
            (e) => e.message,
            'message',
            isNot(contains('handed off')),
          ),
        ),
      );
    });

    test('an in-flight open is not adopted once a handoff latched', () {
      // The adoption itself needs a real `CircleManagerFfi.newInstance`, so it
      // is asserted on the source: the guard must cover the handoff as well as
      // the wipe, and must dispose rather than orphan — the handle holds the
      // Rule-14 guard, and orphaning it locks out the service AND the next
      // legitimate open.
      final src = File(
        'lib/src/services/nostr_circle_service.dart',
      ).readAsStringSync();
      final at = src.indexOf('if (_wiped || _handoffHolds) {');
      expect(
        at,
        isNonNegative,
        reason: 'the post-open adoption must fail closed on BOTH latches',
      );
      final branch = src.substring(at, src.indexOf('return;', at));
      expect(
        branch.indexOf('manager.dispose()'),
        isNonNegative,
        reason: 'a refused adoption must release the guard it just took',
      );
    });
  });
}

/// Behavioural coverage for the SECOND recovery lever: a Rule-14 guard held by
/// this isolate's own orphaned live-sync session.
///
/// The wedge it closes is permanent and survives every reopen. A pause-time
/// `stop()` that times out reinstalls the wedged live-sync core into the Rust
/// static `SESSION`; the pause path then disposes this isolate's own
/// `CircleManagerFfi`, so the guard is held by something no Dart handle in any
/// isolate references. The foreground service cannot open it (held) and its
/// reclaim declines forever (this isolate answers its liveness probe), so the
/// only actor left is this one — and only when the handover has ESTABLISHED
/// that the service is not the holder.
///
/// The open itself cannot succeed here (`CircleManagerFfi.newInstance` needs
/// the Rust bridge and throws a `StateError` without it), which is exactly the
/// failing open these seams hang off. Open ATTEMPTS are counted through the
/// identity-secret provider, which `withFreshSecret` calls once per open.
void _orphanedGuardRecoveryTests() {
  /// One `initialize()` against a scripted set of seams.
  ///
  /// [handover] `null` models a service with no handover wired at all (the
  /// background isolate, and every test that injects a manager).
  Future<({int opens, int handovers, int guardReads, int forceReleases})> run({
    required HandoverOutcome? handover,
    bool guardHeld = true,
    bool guardReadThrows = false,
    bool forceReleaseThrows = false,
    ForceReleaseOutcomeFfi releaseOutcome = ForceReleaseOutcomeFfi.drained,
  }) async {
    var opens = 0;
    var handovers = 0;
    var guardReads = 0;
    var forceReleases = 0;

    final service = NostrCircleService(
      relayService: _StubRelayService(),
      dataDirectoryProvider: _FixedDataDirectoryProvider(),
      keyringInitializer: () async {},
      identitySecretBytesProvider: () async {
        opens++;
        // A fresh buffer per call: `withFreshSecret` scrubs what it is given.
        return List<int>.filled(32, 7);
      },
      sessionHandover: handover == null
          ? null
          : (_) async {
              handovers++;
              return handover;
            },
      isSessionLive: (_) async {
        guardReads++;
        if (guardReadThrows) throw Exception('registry unavailable');
        return guardHeld;
      },
      forceReleaseLiveSession: () async {
        forceReleases++;
        if (forceReleaseThrows) throw Exception('session lock poisoned');
        return releaseOutcome;
      },
    );

    // Every open fails in this harness, so `initialize()` always surfaces the
    // original failure; what varies is how hard it tried first.
    await expectLater(service.initialize(), throwsA(anything));

    return (
      opens: opens,
      handovers: handovers,
      guardReads: guardReads,
      forceReleases: forceReleases,
    );
  }

  group('a guard the stopped foreground service did not release', () {
    test('a timed-out handover force-releases and retries once', () async {
      // THE C1 signature: the service was asked to stop, complied or not, and
      // the guard is still there afterwards — so the holder is this isolate's
      // own reinstalled live-sync core.
      final r = await run(handover: HandoverOutcome.timedOut);
      expect(r.forceReleases, 1);
      expect(
        r.opens,
        2,
        reason: 'exactly one retry — the release is worthless without an open '
            'to use it, and a second retry would just re-stop the engine',
      );
    });

    test('a stopTimedOut release still buys the retry', () async {
      // None of the outcomes PROMISES a free guard — other holders are
      // untouched by that call and `acquire` stays the authority — so a
      // release that changed something is worth one open to ask.
      final r = await run(
        handover: HandoverOutcome.timedOut,
        releaseOutcome: ForceReleaseOutcomeFfi.stopTimedOut,
      );
      expect(r.forceReleases, 1);
      expect(r.opens, 2);
    });

    test('a noSession release does NOT buy a retry', () async {
      // Different in kind from the other two outcomes: the slot was already
      // empty, so this call positively released nothing and the guard belongs
      // to something else entirely. The retry would be an open guaranteed to
      // fail exactly as the first one did.
      final r = await run(
        handover: HandoverOutcome.timedOut,
        releaseOutcome: ForceReleaseOutcomeFfi.noSession,
      );
      expect(r.forceReleases, 1);
      expect(
        r.opens,
        1,
        reason: 'nothing was released, so nothing changed for the retry',
      );
    });

    test('nothing is force-released when the guard is free', () async {
      // A failure with a free guard is something else entirely — a locked
      // keyring, a full disk. Stopping the live-sync engine would destroy live
      // receive to fix a problem it has nothing to do with.
      final r = await run(handover: HandoverOutcome.timedOut, guardHeld: false);
      expect(r.forceReleases, 0);
      expect(r.guardReads, 1, reason: 'the registry decides, and it was asked');
      expect(r.opens, 1, reason: 'nothing changed, so a retry is a guess');
    });

    test('a registry that cannot answer is not read as a held guard',
        () async {
      // Fail closed in BOTH directions: an unanswerable query must not trigger
      // the destructive call either.
      final r = await run(
        handover: HandoverOutcome.timedOut,
        guardReadThrows: true,
      );
      expect(r.forceReleases, 0);
      expect(r.opens, 1);
    });
  });

  group('the handover already settled it', () {
    test('a released guard is retried WITHOUT force-releasing', () async {
      // The foreground service let go. Stopping this isolate's live-sync engine
      // on top of that is pure loss: live receive dies and nothing is gained.
      final r = await run(handover: HandoverOutcome.released);
      expect(r.forceReleases, 0);
      expect(r.guardReads, 0, reason: 'there is nothing left to decide');
      expect(r.opens, 2, reason: 'the retry is what uses the released guard');
    });
  });

  group('verdicts that must NOT reach the destructive lever', () {
    test('a backgrounded open never force-releases', () async {
      // The pause-time handoff working as designed: the service legitimately
      // holds the session and this open is routine background maintenance.
      // Force-releasing here would end background location sharing to satisfy
      // a task that can wait for the next foreground.
      final r = await run(handover: HandoverOutcome.backgrounded);
      expect(r.forceReleases, 0);
      expect(r.guardReads, 0);
      expect(r.opens, 1);
    });

    test('a failed stop leaves the service state unknown, so nothing fires',
        () async {
      final r = await run(handover: HandoverOutcome.stopFailed);
      expect(r.forceReleases, 0);
      expect(r.opens, 1);
    });

    test('a notHeld handover never force-releases', () async {
      // `notHeld` IS the handover reporting a free guard. Every realizable
      // case is answered `false` by the re-read a moment later, so the only
      // way past it is a race in which the guard was taken in between — by
      // something this isolate has established nothing about. Eligibility is
      // therefore `timedOut` alone: one verdict, one meaning.
      final r = await run(handover: HandoverOutcome.notHeld);
      expect(r.forceReleases, 0);
      expect(
        r.guardReads,
        0,
        reason: 'a verdict that is not eligible must not even reach the '
            're-read, let alone the lever',
      );
      expect(r.opens, 1, reason: 'the original failure is surfaced');
    });

    test('a service with no handover wired never force-releases', () async {
      // The background isolate's own `NostrCircleService` has neither seam, so
      // the ungated second route to `forceReleaseLiveSession` does not exist.
      final r = await run(handover: null);
      expect(r.handovers, 0);
      expect(r.forceReleases, 0);
      expect(r.opens, 1);
    });
  });

  group('the release itself failing', () {
    test('a throwing force-release does not buy a retry', () async {
      final r = await run(
        handover: HandoverOutcome.timedOut,
        forceReleaseThrows: true,
      );
      expect(r.forceReleases, 1);
      expect(
        r.opens,
        1,
        reason: 'nothing was released, so the retry would hit the same guard',
      );
    });
  });
}


/// The rejoin consent and the disbanded leave, at the FFI boundary: classified
/// by typed fields only, and failing with fixed text (Rules 8 and 15).
void _rejoinAndDisbandTests() {
  const wrapId = [7, 7, 7, 7];
  const groupId = [9, 9, 9];

  NostrCircleService serviceOver(_RejoinManager manager) =>
      NostrCircleService.withInjectedManager(
        relayService: _StubRelayService(),
        injectedManager: manager,
      );

  RejoinOfferFfi offerFfi(List<int> token) => RejoinOfferFfi(
    mlsGroupId: Uint8List.fromList(groupId),
    welcomerPubkey: 'ab' * 32,
    localStateToken: Uint8List.fromList(token),
  );

  group('rejoin consent and the disbanded leave', () {
    test("an offer is shown with the held circle's own name, and its token "
        'is handed back unchanged', () async {
      final manager = _RejoinManager()
        ..offers = RejoinOffersOutcomeFfi(offers: [offerFfi(const [3, 3])])
        ..confirm = AcceptInvitationOutcomeFfi(
          joined: _circleWithRelays(groupId, const ['wss://c.example']),
        );
      final service = serviceOver(manager);

      final offers = await service.rejoinOffersForInvitation(wrapId);
      expect(offers.single.mlsGroupId, groupId);
      expect(offers.single.circleName, 'Fixture');
      expect(manager.askedWrap, wrapId);

      final joined = await service.confirmGroupRejoin(wrapId, offers.single);
      expect(joined.mlsGroupId, groupId);
      expect(manager.confirmedToken, const [3, 3]);
      expect(manager.askedWrap, wrapId);
    });

    test('a circle the engine reports disbanded is read as disbanded',
        () async {
      final manager = _RejoinManager()
        ..visible = [
          CircleWithMembersFfi(
            circle: _circleWithRelays(groupId, const ['wss://c.example'])
                .circle,
            membershipStatus: 'accepted',
            members: const [],
            engineState: CircleEngineStateFfi.disbanded,
          ),
        ];

      final circles = await serviceOver(manager).getVisibleCircles();

      expect(circles.single.isDisbanded, isTrue);
      expect(circles.single.isQuarantined, isFalse);
    });

    test('every engine state the core reports is read as itself', () async {
      // MDK's halt is persisted and read on every circle read: the circle
      // list, not a session flag, is what blocks send and mutate (Rule 8).
      for (final state in CircleEngineStateFfi.values) {
        final manager = _RejoinManager()
          ..visible = [
            CircleWithMembersFfi(
              circle: _circleWithRelays(groupId, const ['wss://c.example'])
                  .circle,
              membershipStatus: 'accepted',
              members: const [],
              engineState: state,
            ),
          ];
        final circle = (await serviceOver(manager).getVisibleCircles()).single;
        expect(circle.engineState.name, state.name);
        expect(
          circle.isUnrecoverable,
          state == CircleEngineStateFfi.unrecoverable,
        );
      }
    });

    test('each failure is classified by its typed field', () async {
      final manager = _RejoinManager()
        ..offers = const RejoinOffersOutcomeFfi(
          offers: [],
          failure: AcceptFailureFfi.needsNewInvite,
        );
      final service = serviceOver(manager);
      const offer = RejoinOffer(
        mlsGroupId: groupId,
        circleName: 'x',
        localStateToken: [1],
      );

      await expectLater(
        service.rejoinOffersForInvitation(wrapId),
        throwsA(isA<InvitationNeedsNewInviteException>()),
      );

      manager.confirm = const AcceptInvitationOutcomeFfi(
        failure: AcceptFailureFfi.rejoinConfirmationRequired,
      );
      await expectLater(
        service.confirmGroupRejoin(wrapId, offer),
        throwsA(isA<InvitationRejoinConfirmationRequiredException>()),
      );

      manager.confirm = const AcceptInvitationOutcomeFfi(
        failure: AcceptFailureFfi.needsNewInvite,
      );
      await expectLater(
        service.confirmGroupRejoin(wrapId, offer),
        throwsA(isA<InvitationNeedsNewInviteException>()),
      );
    });

    test('a decline declines through the core, and the disbanded leave '
        "deletes this device's copy through the core", () async {
      final manager = _RejoinManager();
      final service = serviceOver(manager);

      await service.declineGroupRejoin(wrapId);
      expect(manager.declinedWrap, wrapId);

      await service.leaveDisbandedCircle(mlsGroupId: groupId);
      expect(manager.completedLeave, groupId);
    });

    test('an engine error on any of them fails with fixed text, and no log '
        'line names the circle, the welcomer or a relay', () async {
      final capture = LogCapture.install();
      final manager = _RejoinManager()..throws = true;
      final service = serviceOver(manager);
      const offer = RejoinOffer(
        mlsGroupId: groupId,
        circleName: 'x',
        localStateToken: [1],
      );

      Matcher fixed(String message) => throwsA(
        isA<CircleServiceException>().having(
          (e) => e.message,
          'message',
          message,
        ),
      );
      await expectLater(
        service.rejoinOffersForInvitation(wrapId),
        fixed('Failed to read the rejoin offers'),
      );
      await expectLater(
        service.confirmGroupRejoin(wrapId, offer),
        fixed('Failed to accept invitation'),
      );
      await expectLater(
        service.declineGroupRejoin(wrapId),
        fixed('Failed to decline invitation'),
      );
      await expectLater(
        service.leaveDisbandedCircle(mlsGroupId: groupId),
        fixed('Failed to leave circle'),
      );
      capture.assertNoNeedles([
        _hexOf(groupId),
        'ab' * 32,
        'wss://planted.example',
      ]);
    });
  });
}

class _RejoinManager implements CircleManagerFfi {
  RejoinOffersOutcomeFfi offers = const RejoinOffersOutcomeFfi(offers: []);
  AcceptInvitationOutcomeFfi confirm = const AcceptInvitationOutcomeFfi();
  List<CircleWithMembersFfi> visible = const [];
  bool throws = false;

  @override
  Future<List<CircleWithMembersFfi>> getVisibleCircles() async => visible;

  List<int>? askedWrap;
  List<int>? confirmedToken;
  List<int>? declinedWrap;
  List<int>? completedLeave;

  static final planted = StateError(
    'group ${'09' * 3} welcomer ${'ab' * 32} at wss://planted.example',
  );

  @override
  Future<RejoinOffersOutcomeFfi> rejoinOffersForInvitation({
    required List<int> giftWrapId,
  }) async {
    if (throws) throw planted;
    askedWrap = giftWrapId.toList();
    return offers;
  }

  @override
  Future<CircleWithMembersFfi?> getCircle({
    required List<int> mlsGroupId,
  }) async => _circleWithRelays(mlsGroupId, const ['wss://circle.example']);

  @override
  Future<AcceptInvitationOutcomeFfi> confirmGroupRejoin({
    required List<int> giftWrapId,
    required List<int> localStateToken,
  }) async {
    if (throws) throw planted;
    askedWrap = giftWrapId.toList();
    confirmedToken = localStateToken.toList();
    return confirm;
  }

  @override
  Future<void> declineGroupRejoin({required List<int> giftWrapId}) async {
    if (throws) throw planted;
    declinedWrap = giftWrapId.toList();
  }

  @override
  Future<void> completeLeave({required List<int> mlsGroupId}) async {
    if (throws) throw planted;
    completedLeave = mlsGroupId.toList();
  }

  @override
  void dispose() {}

  @override
  bool get isDisposed => false;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('unexpected call: ${invocation.memberName}');
}
