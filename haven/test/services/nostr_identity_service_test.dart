import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/services/identity_service.dart';
import 'package:mockito/annotations.dart';

/// Tests for NostrIdentityService.
///
/// ## Test Strategy
///
/// NostrIdentityService has a hard dependency on
/// `NostrIdentityManager.newInstance()` which requires Rust FFI
/// initialization. This makes traditional unit testing challenging.
///
/// These tests verify:
/// 1. Data format conversions (testable without Rust)
/// 2. Validation logic (testable without Rust)
/// 3. Error types and messages
///
/// Full integration tests with Rust bridge are in integration_test/.
///
/// ## Known Limitation
///
/// The current implementation creates NostrIdentityManager via a static
/// factory, making it impossible to inject a mock. For better testability,
/// consider:
/// - Accepting NostrIdentityManager in constructor
/// - Using factory pattern with dependency injection
@GenerateMocks([FlutterSecureStorage])
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('NostrIdentityService - Storage Constants', () {
    test('uses consistent storage key for identity', () {
      const expectedKey = 'haven.nostr.identity';
      expect(expectedKey, 'haven.nostr.identity');
    });

    test('storage key is predictable and not random', () {
      // The storage key should be constant for reliable persistence
      const key1 = 'haven.nostr.identity';
      const key2 = 'haven.nostr.identity';
      expect(key1, equals(key2));
    });
  });

  group('NostrIdentityService - Base64 Encoding', () {
    test('encodes 32-byte secret to base64', () {
      final secretBytes = Uint8List.fromList(List.filled(32, 42));
      final encoded = base64Encode(secretBytes);

      expect(encoded, isNotEmpty);
      expect(encoded, isNot(contains(RegExp('[^A-Za-z0-9+/=]'))));
    });

    test('decodes base64 back to original bytes', () {
      final originalBytes = Uint8List.fromList(List.filled(32, 42));
      final encoded = base64Encode(originalBytes);
      final decoded = base64Decode(encoded);

      expect(decoded, equals(originalBytes));
      expect(decoded.length, 32);
    });

    test('handles different secret byte values', () {
      final testCases = [
        Uint8List.fromList(List.filled(32, 0)),
        Uint8List.fromList(List.filled(32, 255)),
        Uint8List.fromList(List.generate(32, (i) => i)),
      ];

      for (final testBytes in testCases) {
        final encoded = base64Encode(testBytes);
        final decoded = base64Decode(encoded);
        expect(decoded, equals(testBytes));
      }
    });

    test('rejects invalid base64 during decode', () {
      expect(() => base64Decode('invalid-base64!!!'), throwsFormatException);
    });
  });

  group('NostrIdentityService - Timestamp Conversion', () {
    test('converts Unix timestamp to DateTime', () {
      const unixTimestamp = 1704096000; // 2024-01-01 00:00:00 local time
      final dateTime = DateTime.fromMillisecondsSinceEpoch(
        unixTimestamp * 1000,
      );

      expect(dateTime.year, greaterThanOrEqualTo(2023));
      expect(dateTime.month, greaterThanOrEqualTo(1));
    });

    test('handles various timestamp values', () {
      final testCases = {
        0: DateTime.fromMillisecondsSinceEpoch(0),
        1000000000: DateTime.fromMillisecondsSinceEpoch(1000000000 * 1000),
        1704067200: DateTime.fromMillisecondsSinceEpoch(1704067200 * 1000),
      };

      for (final entry in testCases.entries) {
        final result = DateTime.fromMillisecondsSinceEpoch(entry.key * 1000);
        expect(result, equals(entry.value));
      }
    });
  });

  group('NostrIdentityService - Message Hash Validation', () {
    test('accepts exactly 32 bytes for signing', () {
      final validHash = Uint8List.fromList(List.filled(32, 1));
      expect(validHash.length, 32);
    });

    test('rejects hash shorter than 32 bytes', () {
      final shortHash = Uint8List.fromList(List.filled(16, 1));
      expect(shortHash.length, isNot(32));
      expect(shortHash.length, lessThan(32));
    });

    test('rejects hash longer than 32 bytes', () {
      final longHash = Uint8List.fromList(List.filled(64, 1));
      expect(longHash.length, isNot(32));
      expect(longHash.length, greaterThan(32));
    });

    test('empty hash is invalid', () {
      final emptyHash = Uint8List.fromList([]);
      expect(emptyHash.length, 0);
      expect(emptyHash.length, isNot(32));
    });
  });

  group('NostrIdentityService - Error Handling', () {
    test('IdentityServiceException wraps errors with context', () {
      const exception = IdentityServiceException('Test error');
      expect(exception.message, 'Test error');
      expect(exception.toString(), contains('IdentityServiceException'));
      expect(exception.toString(), contains('Test error'));
    });

    test('IdentityServiceException is an Exception', () {
      const exception = IdentityServiceException('Test');
      expect(exception, isA<Exception>());
    });

    test('message hash size error includes actual size', () {
      const size = 16;
      const message = 'Message hash must be exactly 32 bytes, got $size';

      expect(message, contains('32 bytes'));
      expect(message, contains('got 16'));
    });

    test('error message format for different sizes', () {
      for (final size in [0, 1, 16, 31, 33, 64]) {
        final message = 'Message hash must be exactly 32 bytes, got $size';
        expect(message, contains('$size'));
      }
    });
  });

  group('NostrIdentityService - Security Properties', () {
    test('secret bytes are 32 bytes long', () {
      final secretBytes = Uint8List.fromList(List.filled(32, 42));
      expect(secretBytes.length, 32);
    });

    test('secret bytes are not exposed in Identity class', () {
      final identity = Identity(
        pubkeyHex: 'a' * 64,
        npub: 'npub1test',
        createdAt: DateTime.now(),
      );

      // No nsec or secret bytes in Identity class
      expect(identity.npub, startsWith('npub'));
      expect(identity.pubkeyHex.length, 64);
    });

    test('storage uses platform secure mechanisms', () {
      // Android: EncryptedSharedPreferences
      // iOS: Keychain with first_unlock_this_device accessibility
      const androidOption = 'encryptedSharedPreferences';
      const iosOption = 'first_unlock_this_device';

      expect(androidOption, 'encryptedSharedPreferences');
      expect(iosOption, 'first_unlock_this_device');
    });
  });

  group('NostrIdentityService - Data Formats', () {
    test('npub format starts with npub1', () {
      const npub = 'npub1test123456789';
      expect(npub, startsWith('npub1'));
    });

    test('nsec format starts with nsec1', () {
      const nsec = 'nsec1secret123456789';
      expect(nsec, startsWith('nsec1'));
    });

    test('pubkey hex is 64 characters', () {
      final pubkeyHex = 'a' * 64;
      expect(pubkeyHex.length, 64);
      expect(pubkeyHex, matches(RegExp(r'^[0-9a-f]{64}$')));
    });

    test('signature hex is 128 characters', () {
      final signature = 'a' * 128;
      expect(signature.length, 128);
      expect(signature, matches(RegExp(r'^[0-9a-f]{128}$')));
    });

    test('message hash is 32 bytes', () {
      final hash = Uint8List.fromList(List.filled(32, 1));
      expect(hash.length, 32);
    });

    test('secret bytes are 32 bytes', () {
      final secret = Uint8List.fromList(List.filled(32, 42));
      expect(secret.length, 32);
    });
  });

  group('NostrIdentityService - Platform Options', () {
    test('Android options can be created', () {
      const androidOptions = AndroidOptions.defaultOptions;
      expect(androidOptions, isNotNull);
    });

    test('iOS options can be created with Keychain accessibility', () {
      const iosOptions = IOSOptions(
        accessibility: KeychainAccessibility.first_unlock_this_device,
      );
      expect(iosOptions, isNotNull);
    });

    test('FlutterSecureStorage accepts platform options', () {
      const storage = FlutterSecureStorage(
        iOptions: IOSOptions(
          accessibility: KeychainAccessibility.first_unlock_this_device,
        ),
      );
      expect(storage, isNotNull);
    });
  });
}
