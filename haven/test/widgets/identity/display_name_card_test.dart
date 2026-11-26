/// Widget tests for the [DisplayNameCard].
///
/// Covers the persistent inline edit/save state machine: initial saved,
/// dirty-on-typing, whitespace-only edits, success transitions including
/// the intermediate Saving state, failure surfacing, and the
/// initial-load race where the user types before the async provider
/// resolves. Also covers that saving ALWAYS saves the public profile too
/// — saving is unconditional (public-by-default, owner-directed
/// 2026-07-16), so there is no consent gate to test.
///
/// Profile-latency migration: `updateOwnProfile` is now a fast, local-only
/// write; the card must re-enable on THAT alone, never waiting on the
/// separately-triggered background publish (`syncOwnProfile`), and a local
/// failure must never fire that publish trigger at all.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/providers/identity_provider.dart';
import 'package:haven/src/providers/member_profile_refresh_provider.dart';
import 'package:haven/src/providers/own_profile_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/services/identity_service.dart';
import 'package:haven/src/services/profile_service.dart';
import 'package:haven/src/test_keys.dart';
import 'package:haven/src/widgets/circles/circle_member_tile.dart';
import 'package:haven/src/widgets/common/circular_save_button.dart';
import 'package:haven/src/widgets/identity/display_name_card.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../helpers/accessibility_announcements.dart';
import '../../mocks/local_name_identity_service.dart';
import '../../mocks/mock_profile_service.dart';

/// An identity used by tests that exercise the public-profile publish path,
/// which requires the own profile row to be read for a non-null identity.
final _testIdentity = Identity(
  pubkeyHex:
      'abcd1234abcd1234abcd1234abcd1234abcd1234abcd1234abcd1234abcd1234',
  npub: 'npub1testtest0001',
  createdAt: DateTime(2024),
);

void main() {
  Widget buildHarness({
    required IdentityService service,
    AsyncValue<String?>? displayNameOverride,
    MockProfileService? profileService,
    bool resolveIdentity = false,
    ValueNotifier<bool>? shown,
  }) {
    return ProviderScope(
      overrides: [
        identityServiceProvider.overrideWithValue(service),
        // The card always reads/watches the profile service (publishing is
        // unconditional) — always override it so nothing reaches real FFI.
        profileServiceProvider.overrideWithValue(
          profileService ?? MockProfileService(),
        ),
        if (resolveIdentity)
          identityProvider.overrideWith((_) async => _testIdentity),
        if (displayNameOverride != null)
          displayNameProvider.overrideWith(
            // Always-pending future so the override controls the AsyncValue.
            (ref) => switch (displayNameOverride) {
              AsyncData(:final value) => Future<String?>.value(value),
              AsyncError(:final error, :final stackTrace) =>
                Future<String?>.error(error, stackTrace),
              _ => Completer<String?>().future,
            },
          ),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: shown == null
              ? const Padding(
                  padding: EdgeInsets.all(16),
                  child: DisplayNameCard(),
                )
              : ValueListenableBuilder<bool>(
                  valueListenable: shown,
                  builder: (_, on, _) => on
                      ? const Padding(
                          padding: EdgeInsets.all(16),
                          child: DisplayNameCard(),
                        )
                      : const SizedBox(),
                ),
        ),
      ),
    );
  }

  group('DisplayNameCard', () {
    testWidgets('initial saved state when display name is loaded', (
      tester,
    ) async {
      final service = _FakeIdentityService(initialDisplayName: 'Alice');

      await tester.pumpWidget(buildHarness(service: service));
      await tester.pumpAndSettle();

      expect(find.text('Alice'), findsOneWidget);
      expect(
        _findSaveButton().onPressed,
        isNull,
        reason: 'Save button must be disabled with no edits',
      );
      // The saved state is encoded by a check icon on the circular button.
      expect(
        find.descendant(
          of: _findSaveButtonFinder(),
          matching: find.byIcon(LucideIcons.check),
        ),
        findsOneWidget,
        reason: 'saved state shows a check icon',
      );
    });

    testWidgets(
      'the save button is the shared circular button, with display-name '
      'labels',
      (tester) async {
        final service = _FakeIdentityService(initialDisplayName: 'Alice');

        await tester.pumpWidget(buildHarness(service: service));
        await tester.pumpAndSettle();

        expect(
          find.ancestor(
            of: _findSaveButtonFinder(),
            matching: find.byType(CircularSaveButton),
          ),
          findsOneWidget,
          reason: 'one widget for both save buttons, so they cannot drift',
        );
        expect(find.byTooltip('Display name saved'), findsOneWidget);

        await tester.enterText(find.byType(TextField), 'Bob');
        await tester.pump();
        expect(find.byTooltip('Save display name'), findsOneWidget);
      },
    );

    testWidgets(
      'the display-name field has a persistent label, not hint-only '
      '(NIT-c)',
      (tester) async {
        final service = _FakeIdentityService(initialDisplayName: 'Alice');

        await tester.pumpWidget(buildHarness(service: service));
        await tester.pumpAndSettle();

        final field = tester.widget<TextField>(find.byType(TextField));
        expect(
          field.decoration?.labelText,
          'Display Name',
          reason:
              'Once text is entered the hint disappears — a persistent '
              "labelText keeps the field's purpose announced to screen "
              'readers.',
        );
      },
    );

    testWidgets('"Display Name" is shown once, as the field label', (
      tester,
    ) async {
      final service = _FakeIdentityService(initialDisplayName: 'Alice');

      await tester.pumpWidget(buildHarness(service: service));
      await tester.pumpAndSettle();

      expect(find.text('Display Name'), findsOneWidget);
    });

    testWidgets('opts the display-name field out of IME personalized learning', (
      tester,
    ) async {
      final service = _FakeIdentityService(initialDisplayName: 'Alice');

      await tester.pumpWidget(buildHarness(service: service));
      await tester.pumpAndSettle();

      // Publishing this name to relays is the user's deliberate choice; the
      // keyboard's learned-word dictionary is a different recipient — an
      // OS-side store Haven cannot wipe on logout and that rides the device
      // backup and any third-party keyboard.
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.enableIMEPersonalizedLearning, isFalse);
    });

    testWidgets(
      'offers the display-name field to no platform autofill service',
      (tester) async {
        final service = _FakeIdentityService(initialDisplayName: 'Alice');

        await tester.pumpWidget(buildHarness(service: service));
        await tester.pumpAndSettle();

        // This name is a generated pseudonym, not the user's legal name — an
        // autofill service has nothing to supply, yet the framework's default
        // empty hint list would still hand it the current editing value.
        final field = tester.widget<TextField>(find.byType(TextField));
        expect(field.autofillHints, isNull);
      },
    );

    testWidgets('typing flips status to Unsaved changes and enables Save', (
      tester,
    ) async {
      final service = _FakeIdentityService(initialDisplayName: 'Alice');

      await tester.pumpWidget(buildHarness(service: service));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'Alice!');
      // Settle the button's AnimatedSwitcher so the outgoing check icon has
      // fully transitioned out before asserting the saved->unsaved swap.
      await tester.pumpAndSettle();

      // The dirty state is encoded by an up-arrow (save) icon on the button.
      expect(
        find.descendant(
          of: _findSaveButtonFinder(),
          matching: find.byIcon(LucideIcons.arrowUp),
        ),
        findsOneWidget,
        reason: 'unsaved state shows an up-arrow (save) icon',
      );
      expect(
        find.descendant(
          of: _findSaveButtonFinder(),
          matching: find.byIcon(LucideIcons.check),
        ),
        findsNothing,
        reason: 'no longer in the saved (check) state',
      );
      expect(_findSaveButton().onPressed, isNotNull);
    });

    testWidgets('whitespace-only edit does not mark dirty', (tester) async {
      final service = _FakeIdentityService(initialDisplayName: 'Alice');

      await tester.pumpWidget(buildHarness(service: service));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), '  Alice  ');
      await tester.pump();

      // Still saved: the button keeps its check icon and stays disabled
      // because a whitespace-only edit is not a real change.
      expect(
        find.descendant(
          of: _findSaveButtonFinder(),
          matching: find.byIcon(LucideIcons.check),
        ),
        findsOneWidget,
        reason: 'whitespace-only edit stays in the saved (check) state',
      );
      expect(_findSaveButton().onPressed, isNull);
    });

    testWidgets('save success: Saving -> Saved, no SnackBar', (tester) async {
      final completer = Completer<void>();
      final service = _FakeIdentityService(initialDisplayName: 'Alice');
      final profileService = MockProfileService()
        ..updateOwnProfileGate = completer;

      await tester.pumpWidget(
        buildHarness(
          service: service,
          profileService: profileService,
          resolveIdentity: true,
        ),
      );
      await tester.pumpAndSettle();
      final announcements = captureAccessibilityAnnouncements(tester);

      await tester.enterText(find.byType(TextField), 'Bob');
      await tester.pump();
      expect(
        find.descendant(
          of: _findSaveButtonFinder(),
          matching: find.byIcon(LucideIcons.arrowUp),
        ),
        findsOneWidget,
        reason: 'unsaved state shows an up-arrow (save) icon',
      );

      await tester.tap(_findSaveButtonFinder());
      await tester.pump();

      expect(
        _findSaveButton().onPressed,
        isNull,
        reason: 'Save button disabled while saving',
      );
      expect(
        find.descendant(
          of: _findSaveButtonFinder(),
          matching: find.byType(CircularProgressIndicator),
        ),
        findsOneWidget,
      );

      completer.complete();
      await tester.pumpAndSettle();

      // Back to saved: check icon returns, spinner is gone.
      expect(
        find.descendant(
          of: _findSaveButtonFinder(),
          matching: find.byIcon(LucideIcons.check),
        ),
        findsOneWidget,
        reason: 'save success returns to the saved (check) state',
      );
      expect(
        find.descendant(
          of: _findSaveButtonFinder(),
          matching: find.byType(CircularProgressIndicator),
        ),
        findsNothing,
        reason: 'spinner gone after save completes',
      );
      expect(
        _findSaveButton().onPressed,
        isNull,
        reason: 'After save the button is disabled (no longer dirty)',
      );
      expect(
        find.byType(SnackBar),
        findsNothing,
        reason: 'No SnackBar on success — inline indicator carries it',
      );
      expect(_savedNames(profileService), ['Bob']);
      expect(
        announcements,
        contains('Display name saved'),
        reason: 'screen readers are told the save succeeded',
      );
    });

    testWidgets('save failure flips status to failed and re-enables Save', (
      tester,
    ) async {
      final service = _FakeIdentityService(initialDisplayName: 'Alice');

      await tester.pumpWidget(
        buildHarness(
          service: service,
          profileService: MockProfileService()
            ..shouldThrowOnUpdateOwnProfile = true,
        ),
      );
      await tester.pumpAndSettle();
      final announcements = captureAccessibilityAnnouncements(tester);

      await tester.enterText(find.byType(TextField), 'Bob');
      await tester.pump();

      await tester.tap(_findSaveButtonFinder());
      await tester.pumpAndSettle();

      expect(
        find.byType(SnackBar),
        findsNothing,
        reason: 'Failure is shown via the button state, not a SnackBar',
      );
      expect(
        _findSaveButton().onPressed,
        isNotNull,
        reason: 'User must be able to retry',
      );
      // The failed state is encoded by a retry icon on the circular button.
      expect(
        find.descendant(
          of: _findSaveButtonFinder(),
          matching: find.byIcon(LucideIcons.rotateCcw),
        ),
        findsOneWidget,
        reason: 'failed state shows a retry icon',
      );
      expect(
        announcements,
        contains('Save failed, try again'),
        reason: 'screen readers are told the save failed',
      );
    });

    testWidgets(
      'a local save announces only the outcome, never a progress message',
      (tester) async {
        for (final fails in [false, true]) {
          final service = _FakeIdentityService(initialDisplayName: 'Alice');
          await tester.pumpWidget(
            buildHarness(
              service: service,
              profileService: MockProfileService()
                ..shouldThrowOnUpdateOwnProfile = fails,
            ),
          );
          await tester.pumpAndSettle();
          final announcements =
              captureAccessibilityAnnouncementsWithPriority(tester);

          await tester.enterText(find.byType(TextField), 'Bob');
          await tester.pump();
          await tester.tap(_findSaveButtonFinder());
          await tester.pumpAndSettle();

          expect(
            announcements,
            [
              if (fails)
                (
                  message: 'Save failed, try again',
                  assertiveness: Assertiveness.assertive,
                )
              else
                (
                  message: 'Display name saved',
                  assertiveness: Assertiveness.polite,
                ),
            ],
            reason: 'one announcement per outcome, none for the '
                'in-between "saving" state; success is polite, failure '
                'interrupts (fails: $fails)',
          );
          await tester.pumpWidget(const SizedBox());
        }
      },
    );

    testWidgets('loading provider: field disabled, typing cannot mark dirty', (
      tester,
    ) async {
      final service = _FakeIdentityService(initialDisplayName: 'Alice');

      await tester.pumpWidget(
        buildHarness(
          service: service,
          displayNameOverride: const AsyncLoading<String?>(),
        ),
      );
      // Do NOT pumpAndSettle — keep the provider in loading state.
      await tester.pump();

      // Loading skeleton, not the loaded body.
      expect(find.byType(TextField), findsNothing);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      expect(
        _findSaveButtonFinder(),
        findsNothing,
        reason: 'loaded body (and its save button) is not shown while loading',
      );
    });
  });

  // ---------------------------------------------------------------------------
  // Publishing is unconditional (public-by-default, owner-directed
  // 2026-07-16): saving ALWAYS calls both the local write-through AND the
  // public-profile publish — there is no consent gate left to test.
  // ---------------------------------------------------------------------------

  group('DisplayNameCard — saving always publishes (no consent gate)', () {
    testWidgets(
      'saving writes the own profile row, and no device-local name',
      (tester) async {
        final identityService = _FakeIdentityService(
          initialDisplayName: 'Alice',
        );
        final profileService = MockProfileService();

        await tester.pumpWidget(
          buildHarness(
            service: identityService,
            profileService: profileService,
            resolveIdentity: true,
          ),
        );
        await tester.pumpAndSettle();

        await tester.enterText(find.byType(TextField), 'Bob');
        await tester.pump();
        await tester.tap(_findSaveButtonFinder());
        await tester.pumpAndSettle();

        expect(
          _savedNames(profileService),
          ['Bob'],
          reason:
              'Publishing is unconditional — saving must always stage the '
              'public kind-0 profile for the background sync too.',
        );
        expect(
          identityService.setDisplayNameCalls,
          everyElement(isNull),
          reason: 'a name held only on this device is one no relay gets',
        );
      },
    );
  });

  // ---------------------------------------------------------------------------
  // Profile-latency migration: `updateOwnProfile` is now local-first (ms) and
  // the background publish is a separate, coalesced trigger
  // (`triggerProfileSync`) — these pin the three new promises that split
  // introduces.
  // ---------------------------------------------------------------------------

  group('DisplayNameCard — local save is not gated on the background sync', () {
    testWidgets(
      'the button re-enables to saved as soon as the LOCAL save resolves, '
      'even while the background sync is still unresolved',
      (tester) async {
        final identityService = _FakeIdentityService(
          initialDisplayName: 'Alice',
        );
        final profileService = MockProfileService()
          ..syncOwnProfileGate = Completer<void>();

        await tester.pumpWidget(
          buildHarness(
            service: identityService,
            profileService: profileService,
            resolveIdentity: true,
          ),
        );
        await tester.pumpAndSettle();

        await tester.enterText(find.byType(TextField), 'Bob');
        await tester.pump();
        await tester.tap(_findSaveButtonFinder());
        // Deliberately NOT pumpAndSettle — `syncOwnProfileGate` stays open
        // for the rest of this test, so a bounded, explicit-duration pump
        // lets the (local-only, unGated) identity + profile-service saves
        // resolve AND the button's 200ms AnimatedSwitcher cross-fade finish,
        // without ever waiting on the still-open sync gate.
        await tester.pump(const Duration(milliseconds: 250));

        expect(
          find.descendant(
            of: _findSaveButtonFinder(),
            matching: find.byIcon(LucideIcons.check),
          ),
          findsOneWidget,
          reason: 'the card must not wait on the background publish to '
              're-enable — only the local save gates the button',
        );
        expect(
          profileService.methodCalls.map((c) => c.method),
          contains('syncOwnProfile'),
          reason: 'the background sync must still have been TRIGGERED, '
              'just not awaited by the card',
        );

        // Clean up: release the gate so nothing is left pending.
        profileService.syncOwnProfileGate!.complete();
        await tester.pumpAndSettle();
      },
    );

    testWidgets(
      'a save completed after the card unmounted still triggers one sync',
      (tester) async {
        final profileService = MockProfileService()
          ..updateOwnProfileGate = Completer<void>();
        final identityService = _FakeIdentityService(
          initialDisplayName: 'Alice',
        );
        final shown = ValueNotifier<bool>(true);
        addTearDown(shown.dispose);
        await tester.pumpWidget(
          buildHarness(
            service: identityService,
            profileService: profileService,
            resolveIdentity: true,
            shown: shown,
          ),
        );
        await tester.pumpAndSettle();

        await tester.enterText(find.byType(TextField), 'Bob');
        await tester.pump();
        await tester.tap(_findSaveButtonFinder());
        await tester.pump();
        expect(
          profileService.methodCalls.map((c) => c.method),
          contains('updateOwnProfile'),
          reason: 'anti-vacuity: the local profile write is held in flight',
        );
        shown.value = false;
        await tester.pump();
        expect(find.byType(DisplayNameCard), findsNothing);

        profileService.updateOwnProfileGate!.complete();
        await tester.pump();

        expect(
          profileService.syncOwnProfileCalls,
          1,
          reason: 'the local write succeeded, so the publish must not wait '
              'for the next resume',
        );
        expect(
          await ProviderScope.containerOf(
            tester.element(find.byType(Scaffold)),
          ).read(displayNameProvider.future),
          'Bob',
          reason:
              'the name every surface shows is the saved one even when the '
              'card left mid-save',
        );
      },
    );

    testWidgets(
      'an edit made while the local save is still in flight is not '
      'silently marked saved — the newest text stays editable',
      (tester) async {
        final identityService = _FakeIdentityService(
          initialDisplayName: 'Alice',
        );
        final gate = Completer<void>();
        final profileService = MockProfileService()
          ..updateOwnProfileGate = gate;

        await tester.pumpWidget(
          buildHarness(
            service: identityService,
            profileService: profileService,
            resolveIdentity: true,
          ),
        );
        await tester.pumpAndSettle();

        await tester.enterText(find.byType(TextField), 'Bob');
        await tester.pump();
        await tester.tap(_findSaveButtonFinder());
        await tester.pump(); // Saving begins; updateOwnProfile is now gated.

        // The user keeps typing while the save is in flight — the field
        // stays enabled during Saving (only the button disables).
        await tester.enterText(find.byType(TextField), 'Bob Charlie');
        await tester.pump();

        gate.complete();
        await tester.pumpAndSettle();

        // The newest text survives — it is not clobbered by the completed
        // save, and the button re-opens so the newer edit can be saved.
        expect(find.text('Bob Charlie'), findsOneWidget);
        expect(
          find.descendant(
            of: _findSaveButtonFinder(),
            matching: find.byIcon(LucideIcons.arrowUp),
          ),
          findsOneWidget,
          reason: 'the newer edit must still be marked unsaved',
        );
      },
    );

    testWidgets(
      'a local save failure never triggers the background sync, and Retry '
      'is available',
      (tester) async {
        final identityService = _FakeIdentityService(
          initialDisplayName: 'Alice',
        );
        final profileService = MockProfileService()
          ..shouldThrowOnUpdateOwnProfile = true;

        await tester.pumpWidget(
          buildHarness(
            service: identityService,
            profileService: profileService,
            resolveIdentity: true,
          ),
        );
        await tester.pumpAndSettle();

        await tester.enterText(find.byType(TextField), 'Bob');
        await tester.pump();
        await tester.tap(_findSaveButtonFinder());
        await tester.pumpAndSettle();

        expect(
          find.descendant(
            of: _findSaveButtonFinder(),
            matching: find.byIcon(LucideIcons.rotateCcw),
          ),
          findsOneWidget,
          reason: 'failed state shows a retry icon',
        );
        expect(
          profileService.methodCalls.map((c) => c.method),
          contains('updateOwnProfile'),
        );
        expect(
          profileService.methodCalls.map((c) => c.method),
          isNot(contains('syncOwnProfile')),
          reason: 'a failed local save must never trigger a network publish',
        );
      },
    );
  });

  // ---------------------------------------------------------------------------
  // Reseed-on-saved (Flutter review F1 / plan D12): the seed-once guard is
  // relaxed to reseed whenever the card's status is `saved`, so a slower
  // kind-0 fetch can land after the fast local-cache seed without being
  // discarded — but it must never clobber an edit already in progress.
  // ---------------------------------------------------------------------------

  group('DisplayNameCard — reseed-on-saved (F1)', () {
    testWidgets(
      'a later kind-0 fetch reseeds the field when it is still in the '
      'saved state',
      (tester) async {
        final identityService = _FakeIdentityService(
          initialDisplayName: 'Alice',
        );
        final profileService = MockProfileService();
        final container = ProviderContainer(
          overrides: [
            identityServiceProvider.overrideWithValue(identityService),
            identityProvider.overrideWith((_) async => _testIdentity),
            profileServiceProvider.overrideWithValue(profileService),
          ],
        );
        addTearDown(container.dispose);

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: const MaterialApp(
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: Scaffold(body: DisplayNameCard()),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Fast local seed lands first.
        expect(find.text('Alice'), findsOneWidget);

        // The slower kind-0 fetch result lands.
        profileService.ownProfile = Profile(
          pubkeyHex: _testIdentity.pubkeyHex,
          displayName: 'Bob-Public',
        );
        _refreshProfiles(container);
        await tester.pumpAndSettle();

        expect(find.text('Bob-Public'), findsOneWidget);
        expect(find.text('Alice'), findsNothing);
      },
    );

    testWidgets(
      'a later kind-0 fetch does NOT clobber an in-progress unsaved edit',
      (tester) async {
        final identityService = _FakeIdentityService(
          initialDisplayName: 'Alice',
        );
        final profileService = MockProfileService();
        final container = ProviderContainer(
          overrides: [
            identityServiceProvider.overrideWithValue(identityService),
            identityProvider.overrideWith((_) async => _testIdentity),
            profileServiceProvider.overrideWithValue(profileService),
          ],
        );
        addTearDown(container.dispose);

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: const MaterialApp(
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: Scaffold(body: DisplayNameCard()),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Alice'), findsOneWidget);

        // The user starts editing — the field is now `unsaved`.
        await tester.enterText(find.byType(TextField), 'Alice Edited');
        await tester.pump();

        // The slower kind-0 fetch result lands mid-edit.
        profileService.ownProfile = Profile(
          pubkeyHex: _testIdentity.pubkeyHex,
          displayName: 'Bob-Public',
        );
        final reads = _rowReads(profileService);
        _refreshProfiles(container);
        await tester.pumpAndSettle();

        expect(
          _rowReads(profileService),
          greaterThan(reads),
          reason: 'anti-vacuity: the refresh re-read the name',
        );
        // The in-progress edit must survive untouched.
        expect(find.text('Alice Edited'), findsOneWidget);
        expect(find.text('Bob-Public'), findsNothing);
      },
    );
  });

  // ---------------------------------------------------------------------------
  // One source of truth. The own profile row
  // (`ProfileService.updateOwnProfile`, one SQLCipher transaction that also
  // queues the publish) is the save; a device-local name is shown only while
  // the row holds none. Save, leave, come back: the name shown is the one the
  // profile row holds.
  // ---------------------------------------------------------------------------

  group('DisplayNameCard — the own profile is the one source of truth', () {
    testWidgets(
      'a save whose profile write fails leaves the local name untouched',
      (tester) async {
        final identityService = _FakeIdentityService(
          initialDisplayName: 'Alice',
        );
        final profileService = MockProfileService()
          ..shouldThrowOnUpdateOwnProfile = true;
        await tester.pumpWidget(
          buildHarness(
            service: identityService,
            profileService: profileService,
            resolveIdentity: true,
          ),
        );
        await tester.pumpAndSettle();

        await tester.enterText(find.byType(TextField), 'Bob');
        await tester.pump();
        await tester.tap(_findSaveButtonFinder());
        await tester.pumpAndSettle();

        expect(
          profileService.methodCalls.map((c) => c.method),
          contains('updateOwnProfile'),
          reason: 'anti-vacuity: the profile write was attempted',
        );
        expect(
          identityService.setDisplayNameCalls,
          isEmpty,
          reason:
              'a name the profile never took must not reach the local '
              'name either, or the two stores disagree on the next launch',
        );
      },
    );

    testWidgets(
      'a save is what the next visit shows, and is published, even when the '
      'local name it supersedes cannot be dropped',
      (tester) async {
        final profileService = MockProfileService(
          ownProfile: Profile(
            pubkeyHex: _testIdentity.pubkeyHex,
            displayName: 'Alice',
          ),
        );
        final shown = ValueNotifier<bool>(true);
        addTearDown(shown.dispose);
        await tester.pumpWidget(
          buildHarness(
            service: _FakeIdentityService(
              initialDisplayName: 'Alice',
              throwOnSet: true,
            ),
            profileService: profileService,
            resolveIdentity: true,
            shown: shown,
          ),
        );
        await tester.pumpAndSettle();

        await tester.enterText(find.byType(TextField), 'Bob');
        await tester.pump();
        await tester.tap(_findSaveButtonFinder());
        await tester.pumpAndSettle();
        expect(
          profileService.syncOwnProfileCalls,
          1,
          reason: 'the profile row holds the edit, so it is published',
        );

        // Leave and come back.
        shown.value = false;
        await tester.pumpAndSettle();
        shown.value = true;
        await tester.pumpAndSettle();

        expect(find.text('Bob'), findsOneWidget);
        expect(find.text('Alice'), findsNothing);
      },
    );

    testWidgets(
      'the name the own profile holds wins over a stale local name, even '
      'when the profile loaded before the card mounted',
      (tester) async {
        final profileService = MockProfileService(
          ownProfile: Profile(
            pubkeyHex: _testIdentity.pubkeyHex,
            displayName: 'Bob',
          ),
        );
        final container = ProviderContainer(
          overrides: [
            identityServiceProvider.overrideWithValue(
              _FakeIdentityService(initialDisplayName: 'Alice'),
            ),
            identityProvider.overrideWith((_) async => _testIdentity),
            profileServiceProvider.overrideWithValue(profileService),
          ],
        );
        addTearDown(container.dispose);
        // Another surface (a member avatar) already holds the own profile.
        final held = container.listen(ownProfileProvider, (_, _) {});
        addTearDown(held.close);
        await container.read(ownProfileProvider.future);

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: const MaterialApp(
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: Scaffold(body: DisplayNameCard()),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('Bob'), findsOneWidget);
        expect(find.text('Alice'), findsNothing);
      },
    );

    testWidgets('a save never shows the previous name again, not even for a '
        'frame', (tester) async {
      final profileService = MockProfileService(
        ownProfile: Profile(
          pubkeyHex: _testIdentity.pubkeyHex,
          displayName: 'Alice',
        ),
      );
      await tester.pumpWidget(
        buildHarness(
          service: _FakeIdentityService(initialDisplayName: 'Alice'),
          profileService: profileService,
          resolveIdentity: true,
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'Bob');
      await tester.pump();
      final shown = <String>[];
      final controller = tester
          .widget<TextField>(find.byType(TextField))
          .controller!;
      void record() => shown.add(controller.text);
      controller.addListener(record);
      addTearDown(() => controller.removeListener(record));

      await tester.tap(_findSaveButtonFinder());
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      await tester.pumpAndSettle();

      expect(shown, isNot(contains('Alice')));
      expect(find.text('Bob'), findsOneWidget);
    });

    testWidgets('an interrupted clear never brings the old name back: the '
        'local name is dropped before the row is written', (tester) async {
      // A row with no name, as an install from before public profiles has:
      // the name shown is the device-local one.
      final identityService = _FakeIdentityService(initialDisplayName: 'Alice');
      final gate = Completer<void>();
      final profileService = MockProfileService(
        ownProfile: Profile(pubkeyHex: _testIdentity.pubkeyHex),
      )..updateOwnProfileGate = gate;
      await tester.pumpWidget(
        buildHarness(
          service: identityService,
          profileService: profileService,
          resolveIdentity: true,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Alice'), findsOneWidget);

      await tester.enterText(find.byType(TextField), '');
      await tester.pump();
      await tester.tap(_findSaveButtonFinder());
      await tester.pump();

      // The app is killed here, the row write still in flight.
      expect(_savedNames(profileService), ['']);
      expect(
        await identityService.getDisplayName(),
        isNull,
        reason: 'a blank row falls back to the local name, so one left '
            'behind is the old name back on the next launch',
      );

      gate.complete();
      await tester.pumpAndSettle();
      expect(find.text('Alice'), findsNothing);
    });

    testWidgets('the row reloading under the name never takes the field from '
        'someone typing in it', (tester) async {
      final profileService = MockProfileService(
        ownProfile: Profile(
          pubkeyHex: _testIdentity.pubkeyHex,
          displayName: 'Alice',
        ),
      );
      final container = ProviderContainer(
        overrides: [
          identityServiceProvider.overrideWithValue(
            _FakeIdentityService(),
          ),
          identityProvider.overrideWith((_) async => _testIdentity),
          profileServiceProvider.overrideWithValue(profileService),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(body: DisplayNameCard()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.showKeyboard(find.byType(TextField));
      await tester.enterText(find.byType(TextField), 'Alic');
      await tester.pump();
      final field = tester.widget<TextField>(find.byType(TextField));

      // A profile refresh lands mid-typing: the name reloads under the field.
      final reads = _rowReads(profileService);
      container.invalidate(displayNameProvider);
      for (var i = 0; i < 10; i++) {
        await tester.pump();
        expect(find.byType(LinearProgressIndicator), findsNothing);
        expect(
          tester.widget<TextField>(find.byType(TextField)).controller,
          same(field.controller),
        );
      }
      expect(
        _rowReads(profileService),
        greaterThan(reads),
        reason: 'anti-vacuity: the name reloaded during the frames above',
      );
      await tester.pumpAndSettle();

      final editable = tester.state<EditableTextState>(
        find.byType(EditableText),
      );
      expect(editable.widget.focusNode.hasFocus, isTrue);
      await tester.enterText(find.byType(TextField), 'Alice B');
      await tester.pump();
      expect(find.text('Alice B'), findsOneWidget);
    });
  });

  group('DisplayNameCard — Done on the keyboard saves', () {
    testWidgets('Done saves an edit, as the button does', (tester) async {
      final profileService = MockProfileService();
      await tester.pumpWidget(
        buildHarness(
          service: _FakeIdentityService(initialDisplayName: 'Alice'),
          profileService: profileService,
          resolveIdentity: true,
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField)).textInputAction,
        TextInputAction.done,
      );

      await tester.enterText(find.byType(TextField), ' Bob ');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(_savedNames(profileService), ['Bob']);
      expect(
        find.descendant(
          of: _findSaveButtonFinder(),
          matching: find.byIcon(LucideIcons.check),
        ),
        findsOneWidget,
      );
    });

    testWidgets('Done saves nothing without an edit, and nothing twice while '
        'a save is in flight', (tester) async {
      final gate = Completer<void>();
      final profileService = MockProfileService()..updateOwnProfileGate = gate;
      await tester.pumpWidget(
        buildHarness(
          service: _FakeIdentityService(initialDisplayName: 'Alice'),
          profileService: profileService,
          resolveIdentity: true,
        ),
      );
      await tester.pumpAndSettle();

      await tester.showKeyboard(find.byType(TextField));
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(_savedNames(profileService), isEmpty);

      await tester.enterText(find.byType(TextField), 'Bob');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      await tester.enterText(find.byType(TextField), 'Bo');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(_savedNames(profileService), ['Bob']);

      gate.complete();
      await tester.pumpAndSettle();
      expect(_savedNames(profileService), ['Bob']);
    });
  });

  group('DisplayNameCard — a row that cannot be read', () {
    testWidgets('keeps the name on the field and on the self label', (
      tester,
    ) async {
      final profileService = MockProfileService(
        ownProfile: Profile(
          pubkeyHex: _testIdentity.pubkeyHex,
          displayName: 'Bob',
        ),
      );
      final container = ProviderContainer(
        overrides: [
          identityServiceProvider.overrideWithValue(
            LocalNameIdentityService(identity: _testIdentity),
          ),
          profileServiceProvider.overrideWithValue(profileService),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: Column(
                children: [
                  const DisplayNameCard(),
                  CircleMemberTile(
                    member: CircleMember(
                      pubkey: _testIdentity.pubkeyHex,
                      npub: _testIdentity.npub,
                      isAdmin: false,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Bob'), findsNWidgets(2));

      // The store will not open when the profile refresh reads it again.
      profileService.shouldThrowOnGetOwnProfileText = true;
      final reads = _rowReads(profileService);
      _refreshProfiles(container);
      await tester.pumpAndSettle();

      expect(_rowReads(profileService), greaterThan(reads));
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'Bob',
      );
      expect(find.byType(CircleMemberTile), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(CircleMemberTile),
          matching: find.text('Bob'),
        ),
        findsOneWidget,
      );
      expect(
        find.text('Could not load your display name. Try again later.'),
        findsNothing,
      );
    });
  });
}

/// What the profile refresh does once Rust has taken a fetched kind-0 into
/// the own profile row.
void _refreshProfiles(ProviderContainer container) => container
    .read(memberProfileRefreshProvider.notifier)
    .refreshRoster([_testIdentity.pubkeyHex]);

/// How many times the name was read from the own profile row.
int _rowReads(MockProfileService profileService) => profileService.methodCalls
    .where((c) => c.method == 'getOwnProfileText')
    .length;

/// Every name the card saved, in order: the own profile row is the save.
List<Object?> _savedNames(MockProfileService profileService) => [
  for (final call in profileService.methodCalls)
    if (call.method == 'updateOwnProfile') call.args['displayName'],
];

ButtonStyleButton _findSaveButton() {
  return _findSaveButtonFinder().evaluate().single.widget as ButtonStyleButton;
}

Finder _findSaveButtonFinder() =>
    find.byKey(WidgetKeys.displayNameSaveButton);

class _FakeIdentityService implements IdentityService {
  _FakeIdentityService({this.initialDisplayName, this.throwOnSet = false})
    : _current = initialDisplayName;

  final String? initialDisplayName;
  final bool throwOnSet;
  final List<String?> setDisplayNameCalls = [];

  String? _current;

  @override
  Future<String?> getDisplayName() async => _current;

  @override
  Future<void> setDisplayName(String? name) async {
    if (throwOnSet) {
      throw const IdentityServiceException('boom');
    }
    setDisplayNameCalls.add(name);
    _current = name;
  }

  @override
  Future<Identity?> getIdentity() async => null;

  @override
  Future<bool> hasIdentity() async => false;

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
  Future<String> getPubkeyHex() async => throw UnimplementedError();

  @override
  Future<List<int>> getSecretBytes() async => throw UnimplementedError();

  @override
  Future<void> clearCache() async {}
}
