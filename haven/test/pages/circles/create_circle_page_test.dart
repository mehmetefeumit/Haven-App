/// Widget tests for CreateCirclePage.
///
/// Verifies KeyPackage validation flow: valid result, null result (no account),
/// network errors with retry, and continue button state.
library;

import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:haven/src/test_keys.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/pages/circles/create_circle_page.dart';
import 'package:haven/src/providers/circles_provider.dart';
import 'package:haven/src/providers/identity_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/services/identity_service.dart';
import 'package:haven/src/services/member_directory_service.dart';
import 'package:haven/src/services/profile_service.dart';
import 'package:haven/src/theme/theme.dart';
import 'package:haven/src/utils/npub_validator.dart';
import 'package:haven/src/widgets/circles/circle_member_tile.dart';
import 'package:haven/src/widgets/circles/member_picker.dart';

import '../../helpers/localized_app_harness.dart';
import '../../helpers/log_capture.dart';
import '../../mocks/mock_circle_service.dart';
import '../../mocks/mock_member_directory_service.dart';
import '../../mocks/mock_profile_service.dart';
import '../../mocks/mock_relay_service.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Valid 63-character npubs for testing.
const _testNpub1 =
    'npub1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqspcd5';
const _testNpub2 =
    'npub1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqs9n5u';

const _selfHex =
    '5e1f0000000000000000000000000000000000000000000000000000000000ff';
const _selfNpub =
    'npub1tc0sqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqql7pytwqgs';
const _aliceHex =
    'a11ce0000000000000000000000000000000000000000000000000000000cafe';
const _aliceNpub =
    'npub15ywwqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqetlqhgm683';

final _identity = Identity(
  pubkeyHex: _selfHex,
  npub: _selfNpub,
  createdAt: DateTime(2024),
);

/// A directory holding one named co-member, folded with a plain lower-case
/// because `RustLib` is not initialised in a `flutter test` process.
MemberDirectory _aliceDirectory() => buildDirectory(
  entries: const [
    DirectoryEntry(
      pubkeyHex: _aliceHex,
      npub: _aliceNpub,
      tier: DirectoryTier.current,
    ),
  ],
  profiles: const {
    _aliceHex: Profile(pubkeyHex: _aliceHex, displayName: 'Alice Aardvark'),
  },
  fold: (value) => value.toLowerCase(),
);

KeyPackageData _makeKeyPackage(String pubkey) => KeyPackageData(
  pubkey: pubkey,
  eventJson: '{"kind":30443}',
  relays: const ['wss://relay.example.com'],
  nip65WriteRelays: const [],
);

/// Builds the test app with a Material 2 theme to avoid the ink_sparkle
/// shader issue in test environments.
Widget _buildApp(
  MockRelayService mockRelay, {
  MemberDirectory? directory,
  KeyPackageAdmission admission = KeyPackageAdmission.admissible,
  MockProfileService? profileService,
}) {
  return ProviderScope(
    overrides: [
      relayServiceProvider.overrideWithValue(mockRelay),
      circleServiceProvider.overrideWithValue(
        MockCircleService()..keyPackageAdmission = admission,
      ),
      memberDirectoryServiceProvider.overrideWithValue(
        MockMemberDirectoryService(directory: directory),
      ),
      profileServiceProvider.overrideWithValue(
        profileService ?? MockProfileService(),
      ),
      identityProvider.overrideWith((_) async => _identity),
      circlesProvider.overrideWith((ref) => Future.value(const <Circle>[])),
    ],
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: ThemeData(
        useMaterial3: false,
        splashFactory: InkSplash.splashFactory,
      ),
      home: const CreateCirclePage(),
    ),
  );
}

/// Enters a valid npub into the search field and submits it.
Future<void> _addMember(WidgetTester tester, String npub) async {
  await tester.enterText(find.byType(TextField), npub);
  await tester.tap(find.byIcon(LucideIcons.circlePlus));
  await tester.pump();
}

void main() {
  group('CreateCirclePage KeyPackage validation', () {
    testWidgets('shows valid status when KeyPackage is found', (tester) async {
      final gate = Completer<void>();
      final mock = MockRelayService(keyPackageResult: _makeKeyPackage('hex'))
        ..fetchKeyPackageGate = gate;
      await tester.pumpWidget(_buildApp(mock));

      await _addMember(tester, _testNpub1);

      // Should show validating spinner while gate is open
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('Checking availability...'), findsOneWidget);

      // Release the gate and let validation complete
      gate.complete();
      await tester.pumpAndSettle();

      // Should show valid status
      expect(find.byIcon(LucideIcons.circleCheck), findsOneWidget);
      expect(find.text('Ready to invite'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('shows invalid status with no retry when KeyPackage is null', (
      tester,
    ) async {
      final mock = MockRelayService(); // keyPackageResult defaults to null
      await tester.pumpWidget(_buildApp(mock));

      await _addMember(tester, _testNpub1);
      await tester.pumpAndSettle();

      // Should show warning icon and "No Haven account found"
      expect(find.byIcon(LucideIcons.triangleAlert), findsOneWidget);
      expect(
        find.text("Couldn't find a Haven account for this ID"),
        findsOneWidget,
      );

      // No retry button for permanent failures
      expect(find.byIcon(LucideIcons.refreshCw), findsNothing);

      // Close button still present
      expect(find.byIcon(LucideIcons.x), findsOneWidget);
    });

    testWidgets('shows error with retry button on RelayServiceException', (
      tester,
    ) async {
      final mock = MockRelayService(shouldThrowOnFetchKeyPackage: true);
      await tester.pumpWidget(_buildApp(mock));

      await _addMember(tester, _testNpub1);
      await tester.pumpAndSettle();

      // Should show warning icon and network error message
      expect(find.byIcon(LucideIcons.triangleAlert), findsOneWidget);
      expect(find.text('Could not verify member'), findsOneWidget);

      // Retry button should be visible
      expect(find.byIcon(LucideIcons.refreshCw), findsOneWidget);

      // Close button also present
      expect(find.byIcon(LucideIcons.x), findsOneWidget);
    });

    testWidgets('retry re-validates the member', (tester) async {
      final mock = MockRelayService(shouldThrowOnFetchKeyPackage: true);
      await tester.pumpWidget(_buildApp(mock));

      await _addMember(tester, _testNpub1);
      await tester.pumpAndSettle();

      // Should show error with retry
      expect(find.text('Could not verify member'), findsOneWidget);
      expect(find.byIcon(LucideIcons.refreshCw), findsOneWidget);

      // Add a gate before tapping retry so we can observe the spinner
      final retryGate = Completer<void>();
      mock.fetchKeyPackageGate = retryGate;

      // Tap retry
      await tester.tap(find.byIcon(LucideIcons.refreshCw));
      await tester.pump();

      // Should show validating state (spinner)
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('Checking availability...'), findsOneWidget);

      // Release gate and let it settle
      retryGate.complete();
      await tester.pumpAndSettle();
    });

    testWidgets('continue button is disabled when any member is invalid', (
      tester,
    ) async {
      final mock = MockRelayService(); // null = no account
      await tester.pumpWidget(_buildApp(mock));

      await _addMember(tester, _testNpub1);
      await tester.pumpAndSettle();

      // Member is invalid, continue should be disabled
      final button = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Continue'),
      );
      expect(button.onPressed, isNull);
    });

    testWidgets('continue button is enabled when all members are valid', (
      tester,
    ) async {
      final mock = MockRelayService(keyPackageResult: _makeKeyPackage('hex'));
      await tester.pumpWidget(_buildApp(mock));

      await _addMember(tester, _testNpub1);
      await tester.pumpAndSettle();

      // Member is valid, continue should be enabled
      final button = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Continue'),
      );
      expect(button.onPressed, isNotNull);
    });

    testWidgets('continue button is disabled while validating', (tester) async {
      final gate = Completer<void>();
      final mock = MockRelayService(keyPackageResult: _makeKeyPackage('hex'))
        ..fetchKeyPackageGate = gate;
      await tester.pumpWidget(_buildApp(mock));

      await _addMember(tester, _testNpub1);
      // Gate is open, so member is still validating

      final button = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Continue'),
      );
      expect(button.onPressed, isNull);

      // Clean up: release the gate
      gate.complete();
      await tester.pumpAndSettle();
    });

    testWidgets('removing a member clears its state', (tester) async {
      final mock = MockRelayService(keyPackageResult: _makeKeyPackage('hex'));
      await tester.pumpWidget(_buildApp(mock));

      await _addMember(tester, _testNpub1);
      await tester.pumpAndSettle();

      // Member should be valid
      expect(find.byIcon(LucideIcons.circleCheck), findsOneWidget);

      // Remove the member
      await tester.tap(find.byIcon(LucideIcons.x));
      await tester.pump();

      // Member should be gone, empty state should show
      expect(find.byIcon(LucideIcons.circleCheck), findsNothing);
      expect(find.text('Add circle members'), findsOneWidget);
    });

    testWidgets('clear all removes all members', (tester) async {
      final mock = MockRelayService(keyPackageResult: _makeKeyPackage('hex'));
      await tester.pumpWidget(_buildApp(mock));

      // Add first member
      await _addMember(tester, _testNpub1);
      await tester.pumpAndSettle();

      // Add second member
      await _addMember(tester, _testNpub2);
      await tester.pumpAndSettle();

      // Both members should be valid
      expect(find.byIcon(LucideIcons.circleCheck), findsNWidgets(2));

      // Tap "Clear All"
      await tester.tap(find.text('Clear All'));
      await tester.pump();

      // All members should be gone
      expect(find.byIcon(LucideIcons.circleCheck), findsNothing);
      expect(find.text('Add circle members'), findsOneWidget);
    });
  });

  // ---------------------------------------------------------------------------
  // Dark Matter migration (DM-4c, plan §6 F11): a legacy (kind 443)
  // KeyPackage means the person is on a pre-migration Haven build and
  // cannot be invited — blocked with a distinct "needs update" status, not
  // treated as a generic invalid/no-account result.
  // ---------------------------------------------------------------------------
  group('CreateCirclePage KeyPackage admission (MDK v0.10.4)', () {
    testWidgets(
      'shows "needs update" for a peer on a pre-migration build and keeps '
      'continue disabled',
      (tester) async {
        final mock = MockRelayService(keyPackageResult: _makeKeyPackage('hex'));
        await tester.pumpWidget(
          _buildApp(mock, admission: KeyPackageAdmission.needsUpdate),
        );

        await _addMember(tester, _testNpub1);
        await tester.pumpAndSettle();

        // Distinct icon/status from both "valid" and "invalid" (no-account).
        expect(find.byIcon(LucideIcons.circleCheck), findsNothing);
        expect(find.text('Ready to invite'), findsNothing);
        expect(
          find.text("Couldn't find a Haven account for this ID"),
          findsNothing,
        );
        expect(find.text('Needs to update or open Haven'), findsOneWidget);
        expect(
          find.byIcon(LucideIcons.refreshCw),
          findsOneWidget,
          reason:
              'opening Haven publishes a current package, so a retry can '
              'succeed without removing and re-adding the person',
        );

        final button = tester.widget<FilledButton>(
          find.widgetWithText(FilledButton, 'Continue'),
        );
        expect(button.onPressed, isNull);
      },
    );

    testWidgets(
      'a KeyPackage the engine would refuse says it may be out of date, '
      'offers a retry and keeps continue disabled',
      (tester) async {
        final mock = MockRelayService(keyPackageResult: _makeKeyPackage('hex'));
        await tester.pumpWidget(
          _buildApp(mock, admission: KeyPackageAdmission.unusable),
        );

        await _addMember(tester, _testNpub1);
        await tester.pumpAndSettle();

        final l10n = AppLocalizations.of(
          tester.element(find.byType(CreateCirclePage)),
        );
        expect(find.text(l10n.memberKeyPackageStale), findsOneWidget);
        expect(find.text('Ready to invite'), findsNothing);
        expect(
          find.byIcon(LucideIcons.refreshCw),
          findsOneWidget,
          reason: 'a newer KeyPackage may already be on the relays',
        );
        final button = tester.widget<FilledButton>(
          find.widgetWithText(FilledButton, 'Continue'),
        );
        expect(button.onPressed, isNull);
      },
    );
  });

  // -------------------------------------------------------------------------
  // Layout robustness
  //
  // The empty state sits in an `Expanded` between the search field and the
  // CTA, so its height is leftover space. Focusing the field opens the
  // software keyboard and `Scaffold.resizeToAvoidBottomInset` takes that
  // leftover away — the same squeeze that clipped the sibling AddMemberPage in
  // CI run 31462924650. These pump the real shipped theme, whose text metrics
  // are the ones the app actually renders.
  // -------------------------------------------------------------------------
  group('CreateCirclePage — layout under a squeeze', () {
    Future<void> pumpSqueezed(
      WidgetTester tester, {
      TextScaler textScaler = TextScaler.noScaling,
      Locale locale = const Locale('en'),
      double bottomInset = 336,
      MemberDirectory? directory,
    }) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(393, 852);
      tester.view.viewInsets = FakeViewPadding(bottom: bottomInset);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetViewInsets);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            relayServiceProvider.overrideWithValue(MockRelayService()),
            memberDirectoryServiceProvider.overrideWithValue(
              MockMemberDirectoryService(directory: directory),
            ),
            profileServiceProvider.overrideWithValue(MockProfileService()),
            identityProvider.overrideWith((_) async => _identity),
            circlesProvider.overrideWith(
              (ref) => Future.value(const <Circle>[]),
            ),
          ],
          child: MaterialApp(
            locale: locale,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            theme: HavenTheme.light(),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(textScaler: textScaler),
              child: child!,
            ),
            home: const CreateCirclePage(),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('the empty state survives the keyboard', (tester) async {
      await pumpSqueezed(tester);

      expect(tester.takeException(), isNull);
    });

    testWidgets('survives 2x in a long locale with no keyboard', (
      tester,
    ) async {
      await pumpSqueezed(
        tester,
        textScaler: const TextScaler.linear(2),
        locale: const Locale('de'),
        bottomInset: 0,
      );

      expect(tester.takeException(), isNull);
    });

    testWidgets('survives the keyboard at 2x in a long locale', (tester) async {
      await pumpSqueezed(
        tester,
        textScaler: const TextScaler.linear(2),
        locale: const Locale('de'),
      );

      expect(tester.takeException(), isNull);
    });

    testWidgets('the empty-state guidance stays reachable', (tester) async {
      await pumpSqueezed(tester, textScaler: const TextScaler.linear(2));

      expect(tester.takeException(), isNull);

      // `ensureVisible` needs a Scrollable ancestor, so this fails outright if
      // the placeholder loses its scroll host.
      final l10n = l10nOf(tester, CreateCirclePage);
      await tester.ensureVisible(find.text(l10n.createCircleEmptyTitle));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });
  });

  // -------------------------------------------------------------------------
  // The picker: people you already share a circle with (R2/R4)
  // -------------------------------------------------------------------------
  group('CreateCirclePage — the picker', () {
    testWidgets('C1. offers co-members by name and key, with no relay call', (
      tester,
    ) async {
      final mock = MockRelayService();
      await tester.pumpWidget(_buildApp(mock, directory: _aliceDirectory()));
      await tester.pumpAndSettle();

      final l10n = l10nOf(tester, CreateCirclePage);
      expect(find.text(l10n.memberPickerSectionRoster), findsOneWidget);
      expect(find.text('Alice Aardvark'), findsOneWidget);
      expect(
        find.text(NpubValidator.shortenForDisplay(_aliceNpub)),
        findsOneWidget,
        reason: 'a name is attacker-chosen; the key is what pins the person',
      );
      expect(
        mock.methodCalls,
        isEmpty,
        reason: 'R2/R4 add no wire traffic — the roster is already local',
      );
    });

    testWidgets('C2. tapping a row stages that person', (tester) async {
      final mock = MockRelayService(keyPackageResult: _makeKeyPackage('hex'));
      await tester.pumpWidget(_buildApp(mock, directory: _aliceDirectory()));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Alice Aardvark'));
      await tester.pumpAndSettle();

      expect(find.byType(PendingMemberTile), findsOneWidget);
      expect(
        tester.widget<PendingMemberTile>(find.byType(PendingMemberTile)).npub,
        _aliceNpub,
      );
      final button = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Continue'),
      );
      expect(button.onPressed, isNotNull);
    });

    testWidgets('C3. a staged person is shown on a disabled row, with the '
        'reason', (tester) async {
      final mock = MockRelayService(keyPackageResult: _makeKeyPackage('hex'));
      await tester.pumpWidget(_buildApp(mock, directory: _aliceDirectory()));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Alice Aardvark'));
      await tester.pumpAndSettle();

      final l10n = l10nOf(tester, CreateCirclePage);
      expect(find.byType(MemberCandidateTile), findsOneWidget);
      expect(find.text(l10n.memberSearchAlreadyAdded), findsOneWidget);

      // The staged tile now names her too; tap the refused picker row.
      await tester.tap(
        find.descendant(
          of: find.byType(MemberCandidateTile),
          matching: find.text('Alice Aardvark'),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byType(PendingMemberTile),
        findsOneWidget,
        reason: 'a second tap on a refused row must stage nothing',
      );
    });

    testWidgets('C4. with no shared circles yet, the guidance still stands', (
      tester,
    ) async {
      await tester.pumpWidget(_buildApp(MockRelayService()));
      await tester.pumpAndSettle();

      final l10n = l10nOf(tester, CreateCirclePage);
      expect(find.text(l10n.createCircleEmptyTitle), findsOneWidget);
      expect(find.text(l10n.memberPickerSectionRoster), findsNothing);
    });

    testWidgets('C5. typing filters the offered people in the same frame', (
      tester,
    ) async {
      await tester.pumpWidget(
        _buildApp(MockRelayService(), directory: _aliceDirectory()),
      );
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'zzz');
      await tester.pump();
      expect(find.text('Alice Aardvark'), findsNothing);

      await tester.enterText(find.byType(TextField), 'aardvark');
      await tester.pump();
      expect(find.text('Alice Aardvark'), findsOneWidget);
    });
  });

  // -------------------------------------------------------------------------
  // The self-check: this screen previously read no identity at all, so a user
  // could stage their own npub, `_validateMember` would find their own
  // KeyPackage, mark it valid, and carry it into circle creation (§9.5).
  // -------------------------------------------------------------------------
  group('CreateCirclePage — you cannot invite yourself', () {
    testWidgets('C6. entering your own ID is refused by name, and staged '
        'nowhere', (tester) async {
      final mock = MockRelayService(keyPackageResult: _makeKeyPackage('hex'));
      await tester.pumpWidget(_buildApp(mock));
      await tester.pumpAndSettle();

      await _addMember(tester, _selfNpub);
      await tester.pumpAndSettle();

      final l10n = l10nOf(tester, CreateCirclePage);
      expect(find.text(l10n.memberPickerReasonSelf), findsOneWidget);
      expect(find.byType(PendingMemberTile), findsNothing);
      final button = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Continue'),
      );
      expect(button.onPressed, isNull);
    });

    testWidgets('C7. the refusal costs no relay lookup, so it holds offline', (
      tester,
    ) async {
      final mock = MockRelayService(keyPackageResult: _makeKeyPackage('hex'));
      await tester.pumpWidget(_buildApp(mock));
      await tester.pumpAndSettle();

      await _addMember(tester, _selfNpub);
      await tester.pumpAndSettle();

      expect(
        mock.methodCalls,
        isEmpty,
        reason:
            'the check that shipped ran on a hex pubkey read out of a FETCHED '
            'KeyPackage, so with no network it never fired at all',
      );
    });

    testWidgets('C9. the driver sequence — type by key, submit with done — '
        'enables a FilledButton Continue', (tester) async {
      // Exactly what `e2e_combined.dart` does. If any clause of this breaks
      // the lane does not fail, it hangs to a 60 s timeout: the driver waits
      // for a FilledButton whose onPressed is non-null, and returns false
      // forever for any other widget type.
      final mock = MockRelayService(keyPackageResult: _makeKeyPackage('hex'));
      await tester.pumpWidget(_buildApp(mock, directory: _aliceDirectory()));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(WidgetKeys.memberSearchInput),
        _testNpub1,
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      final cta = tester.widget(find.byKey(WidgetKeys.createCircleContinue));
      expect(cta, isA<FilledButton>());
      expect((cta as FilledButton).onPressed, isNotNull);
    });

    testWidgets('C8. someone else is still staged normally', (tester) async {
      final mock = MockRelayService(keyPackageResult: _makeKeyPackage('hex'));
      await tester.pumpWidget(_buildApp(mock));
      await tester.pumpAndSettle();

      await _addMember(tester, _testNpub1);
      await tester.pumpAndSettle();

      expect(find.byType(PendingMemberTile), findsOneWidget);
      expect(mock.methodCalls, contains('fetchKeyPackage'));
      expect(
        mock.fetchKeyPackageTargets,
        [null],
        reason: 'no circle exists yet: the package is chosen for a new one',
      );
    });
  });

  // -------------------------------------------------------------------------
  // A staged row shows the person, by npub, whatever staged it (owner
  // direction 2026-11-12) — and asks a relay only about someone the local
  // directory does not already hold, once.
  // -------------------------------------------------------------------------
  group('CreateCirclePage — a staged row shows the person', () {
    const cousinHex =
        'de1e00000000000000000000000000000000000000000000000000000000fac3';

    MockProfileService cousinProfiles() => MockProfileService()
      ..strangerProfiles[_testNpub1] = const Profile(
        pubkeyHex: cousinHex,
        displayName: 'Distant Cousin',
      );

    int resolves(MockProfileService service) => service.methodCalls
        .where((c) => c.method == 'resolveTypedStrangerProfile')
        .length;

    Finder onStagedRow(String text) => find.descendant(
      of: find.byType(PendingMemberTile),
      matching: find.text(text),
    );

    void expectStagedPerson(String name, String npub) {
      expect(onStagedRow(name), findsOneWidget);
      expect(
        onStagedRow(NpubValidator.shortenForDisplay(npub)),
        findsOneWidget,
      );
    }

    void mockClipboard(WidgetTester tester, String text) {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async => call.method == 'Clipboard.getData'
            ? <String, dynamic>{'text': text}
            : null,
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
    }

    testWidgets('CS1. a suggestion tap names the co-member from the '
        'directory, asking no relay', (tester) async {
      final profiles = MockProfileService();
      await tester.pumpWidget(
        _buildApp(
          MockRelayService(keyPackageResult: _makeKeyPackage('hex')),
          directory: _aliceDirectory(),
          profileService: profiles,
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Alice Aardvark'));
      await tester.pumpAndSettle();

      expectStagedPerson('Alice Aardvark', _aliceNpub);
      expect(resolves(profiles), 0);
    });

    testWidgets(
      'CS2. a typed-row tap names the person, clears the field, leaves no '
      '"No matches" under them, and asks once',
      (tester) async {
        final profiles = cousinProfiles();
        await tester.pumpWidget(
          _buildApp(
            MockRelayService(keyPackageResult: _makeKeyPackage('hex')),
            directory: _aliceDirectory(),
            profileService: profiles,
          ),
        );
        await tester.pumpAndSettle();

        await tester.enterText(
          find.byKey(WidgetKeys.memberSearchInput),
          _testNpub1,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Distant Cousin'));
        await tester.pumpAndSettle();

        expectStagedPerson('Distant Cousin', _testNpub1);
        final l10n = l10nOf(tester, CreateCirclePage);
        expect(
          tester
              .widget<TextField>(find.byKey(WidgetKeys.memberSearchInput))
              .controller!
              .text,
          isEmpty,
        );
        expect(find.text(l10n.memberPickerNoMatches), findsNothing);
        expect(resolves(profiles), 1);
      },
    );

    testWidgets('CS9. a typed-row tap hands the focus back to the search '
        'field', (tester) async {
      await tester.pumpWidget(
        _buildApp(
          MockRelayService(keyPackageResult: _makeKeyPackage('hex')),
          directory: _aliceDirectory(),
          profileService: cousinProfiles(),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(WidgetKeys.memberSearchInput),
        _testNpub1,
      );
      await tester.pumpAndSettle();
      FocusNode fieldFocus() => tester
          .widget<TextField>(find.byKey(WidgetKeys.memberSearchInput))
          .focusNode!;

      // A mouse press outside a text field takes its focus; a touch does not.
      final press = await tester.startGesture(
        tester.getCenter(find.text('Distant Cousin')),
        kind: PointerDeviceKind.mouse,
      );
      addTearDown(press.removePointer);
      await tester.pump();
      expect(fieldFocus().hasPrimaryFocus, isFalse, reason: 'anti-vacuity');
      await press.up();
      await tester.pumpAndSettle();

      expectStagedPerson('Distant Cousin', _testNpub1);
      expect(
        fieldFocus().hasPrimaryFocus,
        isTrue,
        reason: 'the tapped row is gone, so focus left there is focus lost',
      );
    });

    testWidgets('CS8. looking up, naming and fetching the picture of a '
        'staged person logs no key, pubkey or name', (tester) async {
      final capture = LogCapture.install();
      final profiles = cousinProfiles();
      await tester.pumpWidget(
        _buildApp(
          MockRelayService(shouldThrowOnFetchKeyPackage: true),
          directory: _aliceDirectory(),
          profileService: profiles,
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(WidgetKeys.memberSearchInput),
        _testNpub1,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Distant Cousin'));
      await tester.pumpAndSettle();
      expectStagedPerson('Distant Cousin', _testNpub1);
      expect(
        profiles.methodCalls.where((c) => c.method == 'downloadMemberPictures'),
        hasLength(1),
      );

      capture
        ..restore()
        ..assertContains('Relay error fetching KeyPackage')
        ..assertNoNeedles([_testNpub1, cousinHex, 'Distant Cousin']);
    });

    testWidgets('CS3. the paste button names the person', (tester) async {
      final profiles = cousinProfiles();
      mockClipboard(tester, _testNpub1);
      await tester.pumpWidget(
        _buildApp(
          MockRelayService(keyPackageResult: _makeKeyPackage('hex')),
          directory: _aliceDirectory(),
          profileService: profiles,
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(LucideIcons.clipboard));
      await tester.pumpAndSettle();

      expectStagedPerson('Distant Cousin', _testNpub1);
      expect(resolves(profiles), 1);
    });

    testWidgets('CS4. Done names the person', (tester) async {
      final profiles = cousinProfiles();
      await tester.pumpWidget(
        _buildApp(
          MockRelayService(keyPackageResult: _makeKeyPackage('hex')),
          directory: _aliceDirectory(),
          profileService: profiles,
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(WidgetKeys.memberSearchInput),
        _testNpub1,
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expectStagedPerson('Distant Cousin', _testNpub1);
      expect(resolves(profiles), 1);
    });

    testWidgets("CS5. pasting a co-member's npub asks no relay about them", (
      tester,
    ) async {
      final profiles = MockProfileService();
      mockClipboard(tester, _aliceNpub);
      await tester.pumpWidget(
        _buildApp(
          MockRelayService(keyPackageResult: _makeKeyPackage('hex')),
          directory: _aliceDirectory(),
          profileService: profiles,
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(LucideIcons.clipboard));
      await tester.pumpAndSettle();

      expectStagedPerson('Alice Aardvark', _aliceNpub);
      expect(resolves(profiles), 0);
    });

    testWidgets('CS6. with a degraded directory a staged stranger is shown '
        'by key alone and no relay is asked', (tester) async {
      final profiles = cousinProfiles();
      await tester.pumpWidget(
        _buildApp(
          MockRelayService(keyPackageResult: _makeKeyPackage('hex')),
          directory: MemberDirectory.readFailed,
          profileService: profiles,
        ),
      );
      await tester.pumpAndSettle();

      await _addMember(tester, _testNpub1);
      await tester.pumpAndSettle();

      expect(onStagedRow('Distant Cousin'), findsNothing);
      expect(
        onStagedRow(NpubValidator.shortenForDisplay(_testNpub1)),
        findsOneWidget,
      );
      expect(resolves(profiles), 0);
      expect(
        onStagedRow(
          l10nOf(tester, CreateCirclePage).memberPickerStrangerLookupNote,
        ),
        findsNothing,
        reason: 'nothing was asked, so there is nothing to disclose',
      );
    });

    testWidgets('CS10. a stranger staged by the paste button carries the '
        'lookup note under their row, as the typed row does', (tester) async {
      final handle = tester.ensureSemantics();
      final profiles = cousinProfiles();
      mockClipboard(tester, _testNpub1);
      await tester.pumpWidget(
        _buildApp(
          MockRelayService(keyPackageResult: _makeKeyPackage('hex')),
          directory: _aliceDirectory(),
          profileService: profiles,
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(LucideIcons.clipboard));
      await tester.pumpAndSettle();

      final note = l10nOf(
        tester,
        CreateCirclePage,
      ).memberPickerStrangerLookupNote;
      expectStagedPerson('Distant Cousin', _testNpub1);
      expect(onStagedRow(note), findsOneWidget);
      expect(
        tester
            .getSemantics(find.bySemanticsLabel(RegExp('Distant Cousin')))
            .label,
        endsWith(', $note'),
        reason: 'the disclosure is spoken in the row label, not a hint',
      );
      expect(resolves(profiles), 1);
      handle.dispose();
    });

    testWidgets('CS11. a co-member staged by the paste button carries no '
        'lookup note', (tester) async {
      mockClipboard(tester, _aliceNpub);
      await tester.pumpWidget(
        _buildApp(
          MockRelayService(keyPackageResult: _makeKeyPackage('hex')),
          directory: _aliceDirectory(),
          profileService: cousinProfiles(),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(LucideIcons.clipboard));
      await tester.pumpAndSettle();

      expectStagedPerson('Alice Aardvark', _aliceNpub);
      expect(
        find.text(
          l10nOf(tester, CreateCirclePage).memberPickerStrangerLookupNote,
        ),
        findsNothing,
      );
    });

    testWidgets('CS7. a staged row scrolled out of view and back asks no '
        'relay again', (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(400, 600);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      const charset = 'qpzry9x8gf2tvdw0s3jn54khce6mua7l';
      final entries = [
        for (var i = 0; i < 60; i++)
          DirectoryEntry(
            pubkeyHex: i.toRadixString(16).padLeft(64, '0'),
            npub: 'npub1${'z' * 51}${charset[i ~/ 32]}${charset[i % 32]}qqqqq',
            tier: DirectoryTier.current,
          ),
      ];
      final directory = buildDirectory(
        entries: entries,
        profiles: {
          for (final (i, e) in entries.indexed)
            e.pubkeyHex: Profile(
              pubkeyHex: e.pubkeyHex,
              displayName: 'Member $i',
            ),
        },
        fold: (value) => value.toLowerCase(),
      );
      final profiles = cousinProfiles();
      await tester.pumpWidget(
        _buildApp(
          MockRelayService(keyPackageResult: _makeKeyPackage('hex')),
          directory: directory,
          profileService: profiles,
        ),
      );
      await tester.pumpAndSettle();
      await _addMember(tester, _testNpub1);
      await tester.pumpAndSettle();
      expectStagedPerson('Distant Cousin', _testNpub1);
      // More rows after it: a sliver list always keeps its last child, so
      // the stranger must not be the last.
      for (final name in ['Member 0', 'Member 1']) {
        // The stranger's row carries the lookup note, which pushes the
        // suggestions below the fold of this short view.
        await tester.scrollUntilVisible(
          find.text(name),
          100,
          scrollable: find
              .descendant(
                of: find.byType(CustomScrollView),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        await tester.ensureVisible(find.text(name));
        await tester.pumpAndSettle();
        await tester.tap(find.text(name));
        await tester.pumpAndSettle();
      }
      Finder strangerRow({bool skipOffstage = true}) => find.byWidgetPredicate(
        (w) => w is PendingMemberTile && w.npub == _testNpub1,
        skipOffstage: skipOffstage,
      );

      await tester.drag(find.byType(CustomScrollView), const Offset(0, -6000));
      await tester.pumpAndSettle();
      expect(
        strangerRow(skipOffstage: false),
        findsNothing,
        reason: 'the row really left the lazily built list',
      );

      await tester.drag(find.byType(CustomScrollView), const Offset(0, 6000));
      await tester.pumpAndSettle();

      expectStagedPerson('Distant Cousin', _testNpub1);
      expect(resolves(profiles), 1);
    });
  });
}
