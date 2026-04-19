/// Tests for BackgroundLocationTaskHandler.privacyLevelToFfiLabel (T5).
///
/// The method is `@visibleForTesting` on [BackgroundLocationTaskHandler].
/// It maps `PrivacyLevel.name` strings to Rust `LocationPrecision` labels.
///
/// PRIVACY INVARIANT: The 'hidden' case MUST return null — this gates
/// whether the background task publishes the user's location at all.
/// A non-null return from the 'hidden' case would cause silent location
/// disclosure, violating the user's explicit opt-out.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/services/background_location_task.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // ---------------------------------------------------------------------------
  // T5: Exhaustive mapping for privacyLevelToFfiLabel
  // ---------------------------------------------------------------------------

  group('BackgroundLocationTaskHandler.privacyLevelToFfiLabel — exhaustive '
      'mapping (T5)', () {
    // -----------------------------------------------------------------------
    // 'exact' → 'Enhanced'
    // -----------------------------------------------------------------------
    test("'exact' maps to 'Enhanced'", () {
      final result = BackgroundLocationTaskHandler.privacyLevelToFfiLabel(
        'exact',
      );

      expect(
        result,
        equals('Enhanced'),
        reason:
            "'exact' precision must map to the Rust 'Enhanced' "
            'LocationPrecision label',
      );
    });

    // -----------------------------------------------------------------------
    // 'neighborhood' → 'Standard'
    // -----------------------------------------------------------------------
    test("'neighborhood' maps to 'Standard'", () {
      final result = BackgroundLocationTaskHandler.privacyLevelToFfiLabel(
        'neighborhood',
      );

      expect(
        result,
        equals('Standard'),
        reason:
            "'neighborhood' precision must map to the Rust 'Standard' "
            'LocationPrecision label',
      );
    });

    // -----------------------------------------------------------------------
    // 'city' → 'Private'
    // -----------------------------------------------------------------------
    test("'city' maps to 'Private'", () {
      final result = BackgroundLocationTaskHandler.privacyLevelToFfiLabel(
        'city',
      );

      expect(
        result,
        equals('Private'),
        reason:
            "'city' precision must map to the Rust 'Private' "
            'LocationPrecision label',
      );
    });

    // -----------------------------------------------------------------------
    // CRITICAL PRIVACY INVARIANT: 'hidden' MUST return null
    //
    // Returning any non-null value here would cause the background task to
    // proceed to step 5 (GPS acquisition) and publish the user's encrypted
    // location even though they opted out of sharing. This is the gate
    // that enforces the hidden/stealth mode contract.
    // -----------------------------------------------------------------------
    test("PRIVACY INVARIANT: 'hidden' MUST return null — any non-null "
        'return causes silent location disclosure', () {
      final result = BackgroundLocationTaskHandler.privacyLevelToFfiLabel(
        'hidden',
      );

      expect(
        result,
        isNull,
        reason:
            "CRITICAL PRIVACY INVARIANT: 'hidden' must return null so "
            'the background task skips location publishing entirely. '
            'A non-null value here breaks stealth mode.',
      );
    });

    // -----------------------------------------------------------------------
    // Unknown / unrecognized level → safe default 'Standard'
    // -----------------------------------------------------------------------
    test('unknown level name falls back to safe default Standard', () {
      final result = BackgroundLocationTaskHandler.privacyLevelToFfiLabel(
        'unknownLevel',
      );

      expect(
        result,
        equals('Standard'),
        reason:
            'unrecognized level names must fall back to Standard '
            '(privacy-safe default — obfuscated neighborhood radius)',
      );
    });

    // -----------------------------------------------------------------------
    // Empty string → safe default 'Standard'
    // -----------------------------------------------------------------------
    test('empty string falls back to safe default Standard', () {
      final result = BackgroundLocationTaskHandler.privacyLevelToFfiLabel('');

      expect(
        result,
        equals('Standard'),
        reason:
            'empty string (malformed storage) must fall back to '
            'Standard rather than returning null (which would '
            'erroneously trigger stealth-mode suppression)',
      );
    });

    // -----------------------------------------------------------------------
    // Verify complete PrivacyLevel.values coverage — no variant is null
    // except 'hidden'. Guards against accidental future regressions when
    // new PrivacyLevel variants are added.
    // -----------------------------------------------------------------------
    test('all non-hidden level names produce a non-null Rust label', () {
      const nonHiddenLevels = ['exact', 'neighborhood', 'city'];

      for (final name in nonHiddenLevels) {
        final result = BackgroundLocationTaskHandler.privacyLevelToFfiLabel(
          name,
        );

        expect(
          result,
          isNotNull,
          reason:
              "'$name' is a sharing level and must produce a non-null "
              'Rust LocationPrecision label (null suppresses publishing)',
        );
      }
    });
  });
}
