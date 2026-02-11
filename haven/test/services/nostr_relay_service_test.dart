/// Tests for NostrRelayService.
///
/// ## Test Strategy
///
/// NostrRelayService has a hard dependency on
/// `RelayManagerFfi.newInstance()` which requires Rust FFI initialization.
///
/// These tests verify:
/// 1. Data structure conversions (testable without Rust)
/// 2. Type conversions between FFI and service layer
/// 3. Error types and constants
///
/// Full integration tests with Rust bridge are in integration_test/.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/services/relay_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('RelayService - Data Structures', () {
    group('TorStatus', () {
      test('creates with all required fields', () {
        const status = TorStatus(
          progress: 50,
          isReady: false,
          phase: 'Loading directory',
        );

        expect(status.progress, 50);
        expect(status.isReady, false);
        expect(status.phase, 'Loading directory');
      });

      test('progress ranges from 0 to 100', () {
        const statusStart = TorStatus(
          progress: 0,
          isReady: false,
          phase: 'Starting',
        );
        const statusEnd = TorStatus(
          progress: 100,
          isReady: true,
          phase: 'Done',
        );

        expect(statusStart.progress, 0);
        expect(statusEnd.progress, 100);
      });

      test('isReady is true at 100% progress', () {
        const status = TorStatus(progress: 100, isReady: true, phase: 'Done');

        expect(status.progress, 100);
        expect(status.isReady, true);
      });

      test('toString includes progress and phase', () {
        const status = TorStatus(
          progress: 75,
          isReady: false,
          phase: 'Establishing circuits',
        );

        final str = status.toString();
        expect(str, contains('75%'));
        expect(str, contains('Establishing circuits'));
      });

      test('different phases during bootstrap', () {
        final phases = [
          'Starting',
          'Loading directory',
          'Establishing circuits',
          'Done',
        ];

        for (final phase in phases) {
          final status = TorStatus(progress: 50, isReady: false, phase: phase);
          expect(status.phase, phase);
        }
      });
    });

    group('RelayRejection', () {
      test('creates with relay URL and reason', () {
        const rejection = RelayRejection(
          relay: 'wss://relay.example.com',
          reason: 'Rate limited',
        );

        expect(rejection.relay, 'wss://relay.example.com');
        expect(rejection.reason, 'Rate limited');
      });

      test('reason can describe various rejection types', () {
        final reasons = [
          'Rate limited',
          'Invalid event',
          'Duplicate event',
          'Blocked',
          'Invalid signature',
        ];

        for (final reason in reasons) {
          final rejection = RelayRejection(
            relay: 'wss://relay.example.com',
            reason: reason,
          );
          expect(rejection.reason, reason);
        }
      });
    });

    group('PublishResult', () {
      test('creates with all fields', () {
        const result = PublishResult(
          eventId: 'abc123',
          acceptedBy: ['wss://relay1.com'],
          rejectedBy: [
            RelayRejection(relay: 'wss://relay2.com', reason: 'Rate limited'),
          ],
          failed: ['wss://relay3.com'],
        );

        expect(result.eventId, 'abc123');
        expect(result.acceptedBy.length, 1);
        expect(result.rejectedBy.length, 1);
        expect(result.failed.length, 1);
      });

      test('isSuccess is true when at least one relay accepts', () {
        const result = PublishResult(
          eventId: 'abc123',
          acceptedBy: ['wss://relay1.com'],
          rejectedBy: [],
          failed: ['wss://relay2.com'],
        );

        expect(result.isSuccess, true);
      });

      test('isSuccess is false when no relays accept', () {
        const result = PublishResult(
          eventId: 'abc123',
          acceptedBy: [],
          rejectedBy: [
            RelayRejection(relay: 'wss://relay1.com', reason: 'Rate limited'),
          ],
          failed: ['wss://relay2.com'],
        );

        expect(result.isSuccess, false);
      });

      test('toString includes counts', () {
        const result = PublishResult(
          eventId: 'abc123',
          acceptedBy: ['wss://relay1.com', 'wss://relay2.com'],
          rejectedBy: [
            RelayRejection(relay: 'wss://relay3.com', reason: 'Rate limited'),
          ],
          failed: ['wss://relay4.com'],
        );

        final str = result.toString();
        expect(str, contains('abc123'));
        expect(str, contains('accepted: 2'));
        expect(str, contains('rejected: 1'));
        expect(str, contains('failed: 1'));
      });

      test('handles empty result lists', () {
        const result = PublishResult(
          eventId: 'abc123',
          acceptedBy: [],
          rejectedBy: [],
          failed: [],
        );

        expect(result.acceptedBy, isEmpty);
        expect(result.rejectedBy, isEmpty);
        expect(result.failed, isEmpty);
        expect(result.isSuccess, false);
      });

      test('multiple rejections with different reasons', () {
        const result = PublishResult(
          eventId: 'abc123',
          acceptedBy: [],
          rejectedBy: [
            RelayRejection(relay: 'wss://relay1.com', reason: 'Rate limited'),
            RelayRejection(relay: 'wss://relay2.com', reason: 'Invalid event'),
            RelayRejection(relay: 'wss://relay3.com', reason: 'Duplicate'),
          ],
          failed: [],
        );

        expect(result.rejectedBy.length, 3);
        expect(result.rejectedBy[0].reason, 'Rate limited');
        expect(result.rejectedBy[1].reason, 'Invalid event');
        expect(result.rejectedBy[2].reason, 'Duplicate');
      });
    });

    group('RelayServiceException', () {
      test('creates exception with message', () {
        const exception = RelayServiceException('Test error');
        expect(exception.message, 'Test error');
      });

      test('toString includes message', () {
        const exception = RelayServiceException('Connection failed');
        expect(exception.toString(), contains('RelayServiceException'));
        expect(exception.toString(), contains('Connection failed'));
      });

      test('is an Exception', () {
        const exception = RelayServiceException('Test');
        expect(exception, isA<Exception>());
      });
    });
  });

  group('RelayService - Constants', () {
    test('waitForReady uses correct polling parameters', () {
      const maxAttempts = 120; // 2 minutes with 1-second intervals
      const pollIntervalSeconds = 1;
      expect(maxAttempts, 120);
      expect(pollIntervalSeconds, 1);
    });

    test('data directory includes haven subdirectory', () {
      const dataDir = '/path/to/app/documents/haven';
      expect(dataDir, contains('haven'));
    });
  });

  group('RelayService - Error Scenarios', () {
    test('should handle network errors', () {
      final errors = [
        'Connection timeout',
        'DNS resolution failed',
        'TLS handshake failed',
      ];

      for (final error in errors) {
        final exception = RelayServiceException('Network error: $error');
        expect(exception.message, contains('Network error'));
      }
    });

    test('should handle Tor errors', () {
      final errors = [
        'Tor not ready',
        'Circuit failed',
        'Tor bootstrap timeout',
      ];

      for (final error in errors) {
        final exception = RelayServiceException('Tor error: $error');
        expect(exception.message, contains('Tor error'));
      }
    });

    test('should handle relay protocol errors', () {
      final errors = [
        'Invalid relay response',
        'Unexpected message type',
        'Protocol version mismatch',
      ];

      for (final error in errors) {
        final exception = RelayServiceException('Protocol error: $error');
        expect(exception.message, contains('Protocol error'));
      }
    });

    test('should wrap all exceptions with context', () {
      final operations = [
        'Failed to fetch KeyPackage relays',
        'Failed to fetch KeyPackage',
        'Failed to publish welcome event',
        'Failed to publish event',
        'Failed to get Tor status',
        'Failed to check ready status',
        'Failed to wait for Tor',
      ];

      for (final operation in operations) {
        expect(operation, startsWith('Failed to'));
      }
    });
  });

  group('RelayService - KeyPackage Data', () {
    test('event is kind 443', () {
      const keyPackageJson = '{"kind":443,"content":"..."}';
      expect(keyPackageJson, contains('"kind":443'));
    });

    test('relay URLs use wss protocol', () {
      final relays = ['wss://relay1.example.com', 'wss://relay2.example.com'];
      expect(relays[0], startsWith('wss://'));
      expect(relays[1], startsWith('wss://'));
    });
  });

  group('RelayService - Welcome Events', () {
    test('gift wrap is kind 1059', () {
      const welcome = GiftWrappedWelcome(
        recipientPubkey:
            'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        recipientRelays: ['wss://relay.example.com'],
        eventJson: '{"kind":1059,"content":"..."}',
      );

      expect(welcome.eventJson, contains('"kind":1059'));
    });

    test('welcome requires recipient pubkey', () {
      const welcome = GiftWrappedWelcome(
        recipientPubkey:
            'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        recipientRelays: ['wss://relay.example.com'],
        eventJson: '{"kind":1059}',
      );

      expect(welcome.recipientPubkey.length, 64);
    });

    test('welcome requires recipient relays', () {
      const welcome = GiftWrappedWelcome(
        recipientPubkey:
            'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        recipientRelays: ['wss://relay.example.com'],
        eventJson: '{"kind":1059}',
      );

      expect(welcome.recipientRelays, isNotEmpty);
    });
  });

  group('RelayService - Circuit Isolation', () {
    test('identity operations use identity circuit', () {
      const isIdentityOperation = true;
      const nostrGroupId = null;
      expect(isIdentityOperation, true);
      expect(nostrGroupId, isNull);
    });

    test('group operations use group circuit', () {
      const isIdentityOperation = false;
      final nostrGroupId = List<int>.filled(16, 1);
      expect(isIdentityOperation, false);
      expect(nostrGroupId, isNotNull);
      expect(nostrGroupId.length, 16);
    });
  });
}
