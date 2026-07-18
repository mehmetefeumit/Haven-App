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
      expect(find.text('No Haven account found'), findsOneWidget);

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
        expect(find.text('No Haven account found'), findsNothing);
        expect(find.text('Needs to update Haven'), findsOneWidget);

        final button = tester.widget<FilledButton>(
          find.widgetWithText(FilledButton, 'Continue'),
        );
        expect(button.onPressed, isNull);
      },
    );
  });
}
