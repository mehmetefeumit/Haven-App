/// Tests for onboarding provider — state machine and persistence.
///
/// Covers three concerns:
///
/// 1. [resolveStep] — pure-function routing logic, exhaustively tabled over
///    the 2³ × {identity absent, identity present} = 16 combinations.
/// 2. [OnboardingController] — every mutator must await the underlying
///    `SharedPreferences.setBool` write *before* mutating `state`, so a
///    process kill between storage and memory cannot desync them.
/// 3. [onboardingStepProvider] — derives the step from live identity plus
///    flag state; regression guard against reconciliation bugs.
library;

import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/providers/identity_provider.dart';
import 'package:haven/src/providers/onboarding_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/services/identity_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../mocks/mock_circle_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // -------------------------------------------------------------------------
  // resolveStep — pure-function routing
  // -------------------------------------------------------------------------

  group('resolveStep', () {
    test(
      'completed = true always yields done regardless of other flags',
      () {
        for (final introSeen in [false, true]) {
          for (final ageConfirmed in [false, true]) {
            for (final identityReady in [false, true]) {
              for (final displayNameSet in [false, true]) {
                expect(
                  resolveStep(
                    introSeen: introSeen,
                    ageConfirmed: ageConfirmed,
                    identityReady: identityReady,
                    displayNameSet: displayNameSet,
                    completed: true,
                  ),
                  OnboardingStep.done,
                  reason:
                      'completed=true must short-circuit to done '
                      '(introSeen=$introSeen, ageConfirmed=$ageConfirmed, '
                      'identityReady=$identityReady, '
                      'displayNameSet=$displayNameSet)',
                );
              }
            }
          }
        }
      },
    );

    test('first-ever launch → welcome', () {
      expect(
        resolveStep(
          introSeen: false,
          ageConfirmed: false,
          identityReady: false,
          displayNameSet: false,
          completed: false,
        ),
        OnboardingStep.welcome,
      );
    });

    test(
      'intro seen but not age-confirmed (gate enabled) → ageGate',
      () {
        expect(
          resolveStep(
            introSeen: true,
            ageConfirmed: false,
            identityReady: false,
            displayNameSet: false,
            completed: false,
            ageGateEnabled: true,
          ),
          OnboardingStep.ageGate,
          reason:
              'age gate is before identity creation when enabled',
        );
      },
    );

    test('intro seen + ageConfirmed + no identity → createIdentity', () {
      expect(
        resolveStep(
          introSeen: true,
          ageConfirmed: true,
          identityReady: false,
          displayNameSet: false,
          completed: false,
        ),
        OnboardingStep.createIdentity,
      );
    });

    test(
      'gate DISABLED + intro seen + not ageConfirmed + no identity'
      ' → createIdentity',
      () {
        expect(
          resolveStep(
            introSeen: true,
            ageConfirmed: false,
            identityReady: false,
            displayNameSet: false,
            completed: false,
            ageGateEnabled: false,
          ),
          OnboardingStep.createIdentity,
          reason: 'gate disabled — ageConfirmed is irrelevant',
        );
      },
    );

    test('identity present but no display name → displayName', () {
      expect(
        resolveStep(
          introSeen: true,
          ageConfirmed: true,
          identityReady: true,
          displayNameSet: false,
          completed: false,
        ),
        OnboardingStep.displayName,
      );
    });

    test('all flags set except completed → ready', () {
      expect(
        resolveStep(
          introSeen: true,
          ageConfirmed: true,
          identityReady: true,
          displayNameSet: true,
          completed: false,
        ),
        OnboardingStep.ready,
      );
    });

    test(
      'intro not seen beats identity presence '
      '(identity created out of band in an old build)',
      () {
        expect(
          resolveStep(
            introSeen: false,
            ageConfirmed: false,
            identityReady: true,
            displayNameSet: false,
            completed: false,
          ),
          OnboardingStep.welcome,
          reason:
              'welcome screen gates everything; identity presence '
              'does not let the user skip the intro',
        );
      },
    );

    test('display-name flag without identity → createIdentity', () {
      expect(
        resolveStep(
          introSeen: true,
          ageConfirmed: true,
          identityReady: false,
          displayNameSet: true,
          completed: false,
        ),
        OnboardingStep.createIdentity,
        reason:
            'identity is prerequisite to any post-identity step, even if '
            'displayNameSet was somehow flipped externally',
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

  group('OnboardingController.markAgeConfirmed', () {
    test('persists the flag and updates state', () async {
      SharedPreferences.setMockInitialValues({});
      final controller = OnboardingController(OnboardingFlags.none);

      await controller.markAgeConfirmed();

      expect(controller.state.ageConfirmed, isTrue);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(kAgeConfirmedKey), isTrue);
    });

    test('awaits persistence BEFORE mutating in-memory state', () async {
      SharedPreferences.setMockInitialValues({});
      final controller = OnboardingController(OnboardingFlags.none);

      final future = controller.markAgeConfirmed();
      // Before the await completes, state must not have changed.
      expect(controller.state.ageConfirmed, isFalse);

      await future;
      expect(controller.state.ageConfirmed, isTrue);
    });
  });

  group('OnboardingController.markDisplayNameSet', () {
    test('persists the flag and updates state', () async {
      SharedPreferences.setMockInitialValues({});
      final controller = OnboardingController(OnboardingFlags.none);

      await controller.markDisplayNameSet();

      expect(controller.state.displayNameSet, isTrue);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(kOnboardingDisplayNameSetKey), isTrue);
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

    test('does not reset other flags', () async {
      SharedPreferences.setMockInitialValues({
        kOnboardingIntroSeenKey: true,
        kOnboardingDisplayNameSetKey: true,
      });
      final controller = OnboardingController(
        const OnboardingFlags(
          introSeen: true,
          ageConfirmed: false,
          displayNameSet: true,
          completed: false,
        ),
      );

      await controller.markCompleted();

      expect(controller.state.introSeen, isTrue);
      expect(controller.state.displayNameSet, isTrue);
      expect(controller.state.completed, isTrue);
    });
  });

  group('OnboardingController.reset', () {
    test('clears every persisted flag and resets in-memory state', () async {
      SharedPreferences.setMockInitialValues({
        kOnboardingIntroSeenKey: true,
        kAgeConfirmedKey: true,
        kOnboardingDisplayNameSetKey: true,
        kOnboardingCompletedKey: true,
      });
      final controller = OnboardingController(
        const OnboardingFlags(
          introSeen: true,
          ageConfirmed: true,
          displayNameSet: true,
          completed: true,
        ),
      );

      await controller.reset();

      expect(controller.state, OnboardingFlags.none);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(kOnboardingIntroSeenKey), isFalse);
      expect(prefs.getBool(kAgeConfirmedKey), isFalse);
      expect(prefs.getBool(kOnboardingDisplayNameSetKey), isFalse);
      expect(prefs.getBool(kOnboardingCompletedKey), isFalse);
    });
  });

  // -------------------------------------------------------------------------
  // onboardingStepProvider — derived from flags + identity
  // -------------------------------------------------------------------------

  group('onboardingStepProvider', () {
    ProviderContainer buildContainer({
      required OnboardingFlags flags,
      required Identity? identity,
    }) {
      return ProviderContainer(
        overrides: [
          onboardingControllerProvider.overrideWith(
            (ref) => OnboardingController(flags),
          ),
          identityServiceProvider.overrideWithValue(
            _StubIdentityService(identity),
          ),
          circleServiceProvider.overrideWithValue(MockCircleService()),
        ],
      );
    }

    test('flags.none with no identity resolves to welcome', () async {
      SharedPreferences.setMockInitialValues({});
      final container = buildContainer(
        flags: OnboardingFlags.none,
        identity: null,
      );
      addTearDown(container.dispose);

      // Prime identityProvider.
      await container.read(identityProvider.future);

      expect(
        container.read(onboardingStepProvider),
        OnboardingStep.welcome,
      );
    });

    test('introSeen with no identity → ageGate (gate enabled)', () async {
      SharedPreferences.setMockInitialValues({});
      final container = buildContainer(
        flags: const OnboardingFlags(
          introSeen: true,
          ageConfirmed: false,
          displayNameSet: false,
          completed: false,
        ),
        identity: null,
      );
      addTearDown(container.dispose);

      await container.read(identityProvider.future);

      expect(
        container.read(onboardingStepProvider),
        OnboardingStep.ageGate,
      );
    });

    test(
      'introSeen + ageConfirmed with no identity → createIdentity',
      () async {
        SharedPreferences.setMockInitialValues({});
        final container = buildContainer(
          flags: const OnboardingFlags(
            introSeen: true,
            ageConfirmed: true,
            displayNameSet: false,
            completed: false,
          ),
          identity: null,
        );
        addTearDown(container.dispose);

        await container.read(identityProvider.future);

        expect(
          container.read(onboardingStepProvider),
          OnboardingStep.createIdentity,
        );
      },
    );

    test(
      'intro + ageConfirmed + identity but no display name → displayName',
      () async {
        SharedPreferences.setMockInitialValues({});
        final container = buildContainer(
          flags: const OnboardingFlags(
            introSeen: true,
            ageConfirmed: true,
            displayNameSet: false,
            completed: false,
          ),
          identity: _stubIdentity,
        );
        addTearDown(container.dispose);

        await container.read(identityProvider.future);

        expect(
          container.read(onboardingStepProvider),
          OnboardingStep.displayName,
        );
      },
    );

    test('all three flags set → ready (pre-completion)', () async {
      SharedPreferences.setMockInitialValues({});
      final container = buildContainer(
        flags: const OnboardingFlags(
          introSeen: true,
          ageConfirmed: true,
          displayNameSet: true,
          completed: false,
        ),
        identity: _stubIdentity,
      );
      addTearDown(container.dispose);

      await container.read(identityProvider.future);

      expect(
        container.read(onboardingStepProvider),
        OnboardingStep.ready,
      );
    });

    test('completed flag short-circuits to done', () async {
      SharedPreferences.setMockInitialValues({});
      final container = buildContainer(
        flags: const OnboardingFlags(
          introSeen: false,
          ageConfirmed: false,
          displayNameSet: false,
          completed: true,
        ),
        identity: null,
      );
      addTearDown(container.dispose);

      await container.read(identityProvider.future);

      expect(
        container.read(onboardingStepProvider),
        OnboardingStep.done,
      );
    });

    test(
      'identityProvider pending (not yet resolved) → createIdentity',
      () {
        SharedPreferences.setMockInitialValues({});
        final container = buildContainer(
          flags: const OnboardingFlags(
            introSeen: true,
            ageConfirmed: true,
            displayNameSet: false,
            completed: false,
          ),
          identity: _stubIdentity,
        );
        addTearDown(container.dispose);

        // Read step BEFORE awaiting identityProvider — valueOrNull is null.
        expect(
          container.read(onboardingStepProvider),
          OnboardingStep.createIdentity,
          reason:
              'pending identity resolves to createIdentity so the user sees '
              'a meaningful screen instantly; step auto-advances on resolve',
        );
      },
    );
  });

  // -------------------------------------------------------------------------
  // OnboardingFlags value semantics
  // -------------------------------------------------------------------------

  group('OnboardingFlags', () {
    test('equality compares by fields', () {
      const a = OnboardingFlags(
        introSeen: true,
        ageConfirmed: false,
        displayNameSet: false,
        completed: false,
      );
      const b = OnboardingFlags(
        introSeen: true,
        ageConfirmed: false,
        displayNameSet: false,
        completed: false,
      );
      const c = OnboardingFlags.none;

      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(c));
    });

    test('ageConfirmed is included in equality', () {
      const withAge = OnboardingFlags(
        introSeen: true,
        ageConfirmed: true,
        displayNameSet: false,
        completed: false,
      );
      const withoutAge = OnboardingFlags(
        introSeen: true,
        ageConfirmed: false,
        displayNameSet: false,
        completed: false,
      );

      expect(withAge, isNot(withoutAge));
      expect(withAge.hashCode, isNot(withoutAge.hashCode));
    });

    test('copyWith replaces selected fields', () {
      const original = OnboardingFlags.none;

      final next = original.copyWith(introSeen: true);

      expect(next.introSeen, isTrue);
      expect(next.ageConfirmed, isFalse);
      expect(next.displayNameSet, isFalse);
      expect(next.completed, isFalse);
    });

    test('copyWith preserves ageConfirmed when not specified', () {
      const original = OnboardingFlags(
        introSeen: false,
        ageConfirmed: true,
        displayNameSet: false,
        completed: false,
      );

      final next = original.copyWith(introSeen: true);

      expect(next.introSeen, isTrue);
      // ageConfirmed must be preserved — not reset to false.
      expect(next.ageConfirmed, isTrue);
      expect(next.displayNameSet, isFalse);
      expect(next.completed, isFalse);
    });
  });
}

final _stubIdentity = Identity(
  pubkeyHex:
      '1111111111111111111111111111111111111111111111111111111111111111',
  npub: 'npub1stub',
  createdAt: DateTime(2025),
);

class _StubIdentityService implements IdentityService {
  _StubIdentityService(this._identity);

  final Identity? _identity;

  @override
  Future<Identity?> getIdentity() async => _identity;

  @override
  Future<bool> hasIdentity() async => _identity != null;

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
      _identity?.pubkeyHex ?? (throw UnimplementedError());

  @override
  Future<List<int>> getSecretBytes() async => throw UnimplementedError();

  @override
  Future<String?> getDisplayName() async => null;

  @override
  Future<void> setDisplayName(String? name) async {}

  @override
  Future<void> clearCache() async {}
}
