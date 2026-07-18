/// Tests for onboarding provider — state machine and persistence.
///
/// Covers three concerns:
///
/// 1. [resolveStep] — pure-function routing logic, exhaustively tabled over the
///    2² flag combinations. Identity presence is deliberately not an input
///    (resumption is handled inside the create-identity screen).
/// 2. [OnboardingController] — every mutator must await the underlying
///    `SharedPreferences.setBool` write *before* mutating `state`, so a process
///    kill between storage and memory cannot desync them.
/// 3. [onboardingStepProvider] — derives the step purely from flag state.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/providers/onboarding_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // -------------------------------------------------------------------------
  // resolveStep — pure-function routing
  // -------------------------------------------------------------------------

  group('resolveStep', () {
    test('completed = true always yields done regardless of introSeen', () {
      for (final introSeen in [false, true]) {
        expect(
          resolveStep(introSeen: introSeen, completed: true),
          OnboardingStep.done,
          reason: 'completed=true must short-circuit to done '
              '(introSeen=$introSeen)',
        );
      }
    });

    test('first-ever launch → intro', () {
      expect(
        resolveStep(introSeen: false, completed: false),
        OnboardingStep.intro,
      );
    });

    test('intro seen, not completed → createIdentity', () {
      expect(
        resolveStep(introSeen: true, completed: false),
        OnboardingStep.createIdentity,
      );
    });
  });

  // -------------------------------------------------------------------------
  // OnboardingController — persistence-before-state invariant
  // -------------------------------------------------------------------------

  group('OnboardingController.markIntroSeen', () {
    test('persists the flag and updates state', () async {
      SharedPreferences.setMockInitialValues({});
      final controller = OnboardingController(OnboardingFlags.none);

      await controller.markIntroSeen();

      expect(controller.state.introSeen, isTrue);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(kOnboardingIntroSeenKey), isTrue);
    });

    test('awaits persistence BEFORE mutating in-memory state', () async {
      SharedPreferences.setMockInitialValues({});
      final controller = OnboardingController(OnboardingFlags.none);

      final future = controller.markIntroSeen();
      // Before the await completes, state must not have changed: if it had,
      // a process kill here would desync storage (unwritten) from memory.
      expect(controller.state.introSeen, isFalse);

      await future;
      expect(controller.state.introSeen, isTrue);
    });
  });

  group('OnboardingController.markCompleted', () {
    test('persists the flag and updates state', () async {
      SharedPreferences.setMockInitialValues({});
      final controller = OnboardingController(OnboardingFlags.none);

      await controller.markCompleted();

      expect(controller.state.completed, isTrue);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(kOnboardingCompletedKey), isTrue);
    });

    test('does not reset the introSeen flag', () async {
      SharedPreferences.setMockInitialValues({
        kOnboardingIntroSeenKey: true,
      });
      final controller = OnboardingController(
        const OnboardingFlags(introSeen: true, completed: false),
      );

      await controller.markCompleted();

      expect(controller.state.introSeen, isTrue);
      expect(controller.state.completed, isTrue);
    });
  });

  group('OnboardingController.reset', () {
    test('clears every persisted flag and resets in-memory state', () async {
      SharedPreferences.setMockInitialValues({
        kOnboardingIntroSeenKey: true,
        kOnboardingDisplayNameSetKey: true,
        kOnboardingCompletedKey: true,
      });
      final controller = OnboardingController(
        const OnboardingFlags(introSeen: true, completed: true),
      );

      await controller.reset();

      expect(controller.state, OnboardingFlags.none);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(kOnboardingIntroSeenKey), isFalse);
      // The legacy display-name flag is cleared defensively so a downgrade to a
      // pre-consolidation build doesn't see a stale `true`.
      expect(prefs.getBool(kOnboardingDisplayNameSetKey), isFalse);
      expect(prefs.getBool(kOnboardingCompletedKey), isFalse);
    });
  });

  // -------------------------------------------------------------------------
  // onboardingStepProvider — derived purely from flags
  // -------------------------------------------------------------------------

  group('onboardingStepProvider', () {
    ProviderContainer buildContainer(OnboardingFlags flags) {
      return ProviderContainer(
        overrides: [
          onboardingControllerProvider.overrideWith(
            (ref) => OnboardingController(flags),
          ),
        ],
      );
    }

    test('flags.none resolves to intro', () {
      final container = buildContainer(OnboardingFlags.none);
      addTearDown(container.dispose);
      expect(container.read(onboardingStepProvider), OnboardingStep.intro);
    });

    test('introSeen, not completed → createIdentity', () {
      final container = buildContainer(
        const OnboardingFlags(introSeen: true, completed: false),
      );
      addTearDown(container.dispose);
      expect(
        container.read(onboardingStepProvider),
        OnboardingStep.createIdentity,
      );
    });

    test('completed flag short-circuits to done', () {
      final container = buildContainer(
        const OnboardingFlags(introSeen: false, completed: true),
      );
      addTearDown(container.dispose);
      expect(container.read(onboardingStepProvider), OnboardingStep.done);
    });
  });

  // -------------------------------------------------------------------------
  // OnboardingFlags value semantics
  // -------------------------------------------------------------------------

  group('OnboardingFlags', () {
    test('none is all-false', () {
      expect(OnboardingFlags.none.introSeen, isFalse);
      expect(OnboardingFlags.none.completed, isFalse);
    });

    test('equality compares by fields', () {
      const a = OnboardingFlags(introSeen: true, completed: false);
      const b = OnboardingFlags(introSeen: true, completed: false);
      const c = OnboardingFlags.none;

      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(c));
    });

    test('copyWith replaces selected fields and preserves the rest', () {
      const original = OnboardingFlags(introSeen: false, completed: true);

      final next = original.copyWith(introSeen: true);

      expect(next.introSeen, isTrue);
      // completed must be preserved — not reset to false.
      expect(next.completed, isTrue);
    });
  });
}
