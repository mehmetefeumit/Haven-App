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
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/providers/identity_provider.dart';
import 'package:haven/src/providers/own_profile_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/services/identity_service.dart';
import 'package:haven/src/services/profile_service.dart';
import 'package:haven/src/test_keys.dart';
import 'package:haven/src/widgets/identity/display_name_card.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../mocks/mock_profile_service.dart';

/// An identity used by tests that exercise the public-profile publish path,
/// which requires `ownProfileProvider` to resolve a non-null identity.
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
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Padding(padding: EdgeInsets.all(16), child: DisplayNameCard()),
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
      final service = _FakeIdentityService(
        initialDisplayName: 'Alice',
        setDisplayNameGate: completer.future,
      );

      await tester.pumpWidget(buildHarness(service: service));
      await tester.pumpAndSettle();
      final announcements = _captureAccessibilityAnnouncements(tester);

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
      expect(service.setDisplayNameCalls, ['Bob']);
      expect(
        announcements,
        contains('Display name saved'),
        reason: 'screen readers are told the save succeeded',
      );
    });

    testWidgets('save failure flips status to failed and re-enables Save', (
      tester,
    ) async {
      final service = _FakeIdentityService(
        initialDisplayName: 'Alice',
        throwOnSet: true,
      );

      await tester.pumpWidget(buildHarness(service: service));
      await tester.pumpAndSettle();
      final announcements = _captureAccessibilityAnnouncements(tester);

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
      'saving calls both the local write-through and updateOwnProfile',
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

        expect(identityService.setDisplayNameCalls, ['Bob']);
        expect(
          profileService.methodCalls.map((c) => c.method),
          contains('updateOwnProfile'),
          reason:
              'Publishing is unconditional — saving must always stage the '
              'public kind-0 profile for the background sync too.',
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
        // for the rest of this test, and this card no longer mounts the
        // sync status line itself (it moved to page scope; see
        // `identity_page.dart`), so a bounded, explicit-duration pump lets
        // the (now local-only, unGated) identity + profile-service saves
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
        container.invalidate(ownProfileProvider);
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
        container.invalidate(ownProfileProvider);
        await tester.pumpAndSettle();

        // The in-progress edit must survive untouched.
        expect(find.text('Alice Edited'), findsOneWidget);
        expect(find.text('Bob-Public'), findsNothing);
      },
    );
  });
}

ButtonStyleButton _findSaveButton() {
  return _findSaveButtonFinder().evaluate().single.widget as ButtonStyleButton;
}

Finder _findSaveButtonFinder() =>
    find.byKey(WidgetKeys.displayNameSaveButton);

/// Captures accessibility announcements (`SemanticsService.sendAnnouncement`)
/// sent on the platform channel, so tests can assert screen-reader feedback.
/// The mock handler is torn down automatically after the test.
List<String> _captureAccessibilityAnnouncements(WidgetTester tester) {
  final announcements = <String>[];
  tester.binding.defaultBinaryMessenger.setMockDecodedMessageHandler<dynamic>(
    SystemChannels.accessibility,
    (message) async {
      if (message is Map &&
          message['type'] == 'announce' &&
          message['data'] is Map) {
        final text = (message['data'] as Map)['message'];
        if (text is String) announcements.add(text);
      }
      return null;
    },
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger
        .setMockDecodedMessageHandler<dynamic>(
          SystemChannels.accessibility,
          null,
        ),
  );
  return announcements;
}

class _FakeIdentityService implements IdentityService {
  _FakeIdentityService({
    this.initialDisplayName,
    this.throwOnSet = false,
    this.setDisplayNameGate,
  });

  final String? initialDisplayName;
  final bool throwOnSet;
  final Future<void>? setDisplayNameGate;
  final List<String?> setDisplayNameCalls = [];

  String? _current;

  @override
  Future<String?> getDisplayName() async => _current ?? initialDisplayName;

  @override
  Future<void> setDisplayName(String? name) async {
    if (setDisplayNameGate != null) {
      await setDisplayNameGate;
    }
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
