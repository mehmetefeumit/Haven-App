/// Widget tests for CreateCirclePage.
///
/// Verifies KeyPackage validation flow: valid result, null result (no account),
/// network errors with retry, and continue button state.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/pages/circles/create_circle_page.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/theme/theme.dart';

import '../../helpers/localized_app_harness.dart';
import '../../mocks/mock_relay_service.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Valid 63-character npubs for testing.
const _testNpub1 =
    'npub1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqspcd5';
const _testNpub2 =
    'npub1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqs9n5u';

KeyPackageData _makeKeyPackage(String pubkey) => KeyPackageData(
  pubkey: pubkey,
  eventJson: '{"kind":30443}',
  relays: const ['wss://relay.example.com'],
);

/// A KeyPackage carrying the deprecated pre-Dark-Matter kind (443) — the
/// peer is on an old Haven build (DM-4c, plan §6 F11).
KeyPackageData _makeLegacyKeyPackage(String pubkey) => KeyPackageData(
  pubkey: pubkey,
  eventJson: '{"kind":443}',
  relays: const ['wss://relay.example.com'],
);

/// Builds the test app with a Material 2 theme to avoid the ink_sparkle
/// shader issue in test environments.
Widget _buildApp(MockRelayService mockRelay) {
  return ProviderScope(
    overrides: [relayServiceProvider.overrideWithValue(mockRelay)],
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
      expect(find.text("Couldn't find a Haven account for this ID"), findsOneWidget);

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
  group('CreateCirclePage legacy KeyPackage detection (DM-4c)', () {
    testWidgets(
      'shows "needs update" status for a legacy (kind 443) KeyPackage and '
      'keeps continue disabled',
      (tester) async {
        final mock = MockRelayService(
          keyPackageResult: _makeLegacyKeyPackage('hex'),
        );
        await tester.pumpWidget(_buildApp(mock));

        await _addMember(tester, _testNpub1);
        await tester.pumpAndSettle();

        // Distinct icon/status from both "valid" and "invalid" (no-account).
        expect(find.byIcon(LucideIcons.circleCheck), findsNothing);
        expect(find.text('Ready to invite'), findsNothing);
        expect(find.text("Couldn't find a Haven account for this ID"), findsNothing);
        expect(find.text('Needs to update Haven'), findsOneWidget);

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
}
