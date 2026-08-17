import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/services/fresh_secret.dart';

void main() {
  group('withFreshSecret', () {
    List<int> secret32([int fill = 7]) => List<int>.filled(32, fill);

    /// Runs [withFreshSecret] over a provider yielding [source] and asserts,
    /// WHILE `use` is running, Rule 9's actual invariant: **exactly ONE buffer
    /// holds the secret, and any other buffer that ever held it is already
    /// zeroed**.
    ///
    /// Stated as an invariant rather than `identical(secret, source)` so a
    /// future always-copy-then-wipe-the-source implementation still passes,
    /// while a copy that leaves the source live (two live secrets, only one of
    /// them ever scrubbed) fails. Callers assert the post-condition — that the
    /// last remaining buffer is zeroed too — themselves.
    Future<void> assertOneLiveCopyDuringUse(List<int> source, int fill) =>
        withFreshSecret(() async => source, (secret) async {
          expect(
            secret.every((b) => b == fill),
            isTrue,
            reason: 'use must see the real secret bytes',
          );
          if (!identical(secret, source)) {
            expect(
              source.every((b) => b == 0),
              isTrue,
              reason: 'a copy was minted, so the buffer it was copied FROM '
                  'must already be zeroed — otherwise two buffers hold the '
                  'secret and only one of them is ever scrubbed',
            );
          }
        });

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

    test('scrubs the buffer the instant use completes (Rule 9)', () async {
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

    test('scrubs the buffer even when use throws', () async {
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

    test(
      'exactly one buffer holds the secret — provider yields a Uint8List '
      '(the production shape: the buffer the FFI just allocated)',
      () async {
        final source = Uint8List.fromList(secret32(3));
        await assertOneLiveCopyDuringUse(source, 3);
        expect(
          source.every((b) => b == 0),
          isTrue,
          reason: 'nothing that ever held the secret survives the call',
        );
      },
    );

    test(
      'exactly one buffer holds the secret — provider yields a plain List<int>',
      () async {
        final source = secret32(3);
        await assertOneLiveCopyDuringUse(source, 3);
        expect(
          source.every((b) => b == 0),
          isTrue,
          reason: 'nothing that ever held the secret survives the call',
        );
      },
    );
  });

  group('takeSecretOwnership', () {
    test('hands back the very buffer it was given, minting no copy', () {
      final raw = Uint8List.fromList(List<int>.filled(32, 0x7E));
      final owned = takeSecretOwnership(raw);
      expect(
        identical(owned, raw),
        isTrue,
        reason: 'a copy here would be a second live secret that the '
            "caller's single scrub can never reach",
      );
      expect(owned.every((b) => b == 0x7E), isTrue);
    });

    test('wipes a foreign source BEFORE returning the copy', () {
      final source = List<int>.filled(32, 0x7E);
      final owned = takeSecretOwnership(source);
      expect(identical(owned, source), isFalse);
      expect(
        owned.every((b) => b == 0x7E),
        isTrue,
        reason: 'the caller still receives the real bytes',
      );
      expect(
        source.every((b) => b == 0),
        isTrue,
        reason: 'the buffer the copy came from must not outlive the copy',
      );
    });

    test('throws on a source it cannot wipe, rather than handing back a '
        'copy while the original stays live', () {
      // `const []` (and anything else mixing in `UnmodifiableListMixin`)
      // throws from `fillRange` unconditionally. Eager, so it surfaces here
      // instead of from a `finally` where it would mask the real exception.
      expect(
        () => takeSecretOwnership(const <int>[1, 2, 3]),
        throwsUnsupportedError,
      );
    });
  });
}
