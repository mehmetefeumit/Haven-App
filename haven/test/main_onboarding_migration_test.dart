/// Tests for `loadInitialOnboardingFlags` (main.dart) — the pre-`runApp`
/// migration/hydration that decides whether an install is routed into
/// onboarding or straight to the main shell.
///
/// The load-bearing case is the crash-after-create-before-complete resume: a
/// new-flow user who created an identity but was killed before `markCompleted`
/// must NOT be mistaken for a pre-onboarding legacy user and silently marked
/// complete — they must fall through to the (idempotent) create-identity step.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:haven/main.dart';
import 'package:haven/src/providers/onboarding_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('fresh install (no flags, no identity) → all false', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});

    final flags = await loadInitialOnboardingFlags(hasIdentity: false);

    expect(flags, OnboardingFlags.none);
  });

  test('genuine legacy user (no flags, identity present) → all true', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});

    final flags = await loadInitialOnboardingFlags(hasIdentity: true);

    expect(flags.introSeen, isTrue);
    expect(flags.completed, isTrue);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(kOnboardingIntroSeenKey), isTrue);
    expect(prefs.getBool(kOnboardingCompletedKey), isTrue);
    // Legacy flag written defensively for downgrade safety.
    expect(prefs.getBool(kOnboardingDisplayNameSetKey), isTrue);
  });

  test(
    'crash after create, before complete (introSeen persisted, identity '
    'present) resumes at create-identity — NOT silently completed',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        kOnboardingIntroSeenKey: true,
      });

      final flags = await loadInitialOnboardingFlags(hasIdentity: true);

      expect(flags.introSeen, isTrue);
      expect(
        flags.completed,
        isFalse,
        reason: 'a mid-flow crash must not be treated as a legacy user',
      );
      // The router would resume this at the idempotent create-identity screen.
      expect(
        resolveStep(introSeen: flags.introSeen, completed: flags.completed),
        OnboardingStep.createIdentity,
      );
    },
  );

  test('already completed → stays completed', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      kOnboardingIntroSeenKey: true,
      kOnboardingCompletedKey: true,
    });

    final flags = await loadInitialOnboardingFlags(hasIdentity: true);

    expect(flags.completed, isTrue);
  });

  test('intro seen, no identity, not completed → not migrated', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      kOnboardingIntroSeenKey: true,
    });

    final flags = await loadInitialOnboardingFlags(hasIdentity: false);

    expect(flags.introSeen, isTrue);
    expect(flags.completed, isFalse);
  });
}
