import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/services/fresh_secret.dart';

void main() {
  group('withFreshSecret', () {
    List<int> secret32([int fill = 7]) => List<int>.filled(32, fill);

    test("invokes the provider once and returns use's result", () async {
      var calls = 0;
      late Uint8List seen;
      final result = await withFreshSecret(
        () async {
          calls++;
          return secret32(9);
        },
        (secret) async {
          seen = secret;
          return 'ok';
        },
      );
      expect(result, 'ok');
      expect(calls, 1, reason: 'fetched fresh, exactly once, per call');
      expect(seen.length, 32);
    });

    test('scrubs the copy the instant use completes (Rule 9)', () async {
      late Uint8List captured;
      await withFreshSecret(
        () async => secret32(0xAB),
        (secret) async {
          captured = secret;
          expect(
            secret.every((b) => b == 0xAB),
            isTrue,
            reason: 'use sees the real secret bytes',
          );
          return null;
        },
      );
      expect(
        captured.every((b) => b == 0),
        isTrue,
        reason: 'the buffer is zeroed as soon as use returns',
      );
    });

    test('scrubs the copy even when use throws', () async {
      late Uint8List captured;
      await expectLater(
        withFreshSecret<void>(
          () async => secret32(0x5A),
          (secret) async {
            captured = secret;
            throw Exception('boom');
          },
        ),
        throwsA(isA<Exception>()),
      );
      expect(
        captured.every((b) => b == 0),
        isTrue,
        reason: 'the finally scrub runs on the throwing path too',
      );
    });

    test('throws on a non-32-byte secret and never reaches use', () async {
      var used = false;
      await expectLater(
        withFreshSecret<void>(
          () async => List<int>.filled(31, 1),
          (secret) async => used = true,
        ),
        throwsA(isA<CircleServiceException>()),
      );
      expect(used, isFalse, reason: 'a bad-length secret never reaches use');
    });

    test('copies the secret — never aliases the provider list', () async {
      final backing = secret32(3);
      await withFreshSecret(
        () async => backing,
        (secret) async {
          secret[0] = 99;
          return null;
        },
      );
      // Mutating and scrubbing the copy must not touch the provider's list.
      expect(backing[0], 3, reason: 'withFreshSecret copies, never aliases');
    });
  });
}
