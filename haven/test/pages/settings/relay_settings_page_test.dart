/// Widget tests for the editable [`RelaySettingsPage`].
///
/// The page underwent a full rewrite from a read-only status view into
/// an editable two-section UI; the prior test suite was dropped because
/// it asserted layout details that no longer exist. Tests here cover
/// the surface that matters for v1: section presence, edit affordances,
/// the privacy callouts, and the publish toggles.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/pages/settings/relay_settings_page.dart';
import 'package:haven/src/providers/identity_provider.dart';
import 'package:haven/src/providers/relay_preferences_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/services/identity_service.dart';
import 'package:haven/src/services/relay_preferences_service.dart';
import 'package:haven/src/widgets/common/refresh_ring/refresh_ring_button.dart';

import '../../mocks/mock_relay_preferences_service.dart';
import '../../mocks/mock_relay_service.dart';

Identity _stubIdentity() => Identity(
  pubkeyHex: '0' * 64,
  npub: 'npub1stub',
  createdAt: DateTime.fromMillisecondsSinceEpoch(0),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Widget buildApp({
    required MockRelayPreferencesService mock,
    Identity? identity,
  }) {
    return ProviderScope(
      overrides: [
        identityProvider.overrideWith(
          (ref) async => identity ?? _stubIdentity(),
        ),
        relayPreferencesServiceProvider.overrideWith((ref) async => mock),
        // disconnect_relay routes through RelayService now; tests don't
        // exercise the persistent FFI client, but the page still calls
        // it on remove and would otherwise hit production NostrRelayService.
        relayServiceProvider.overrideWithValue(MockRelayService()),
      ],
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: RelaySettingsPage(),
      ),
    );
  }

  MockRelayPreferencesService seededMock() => MockRelayPreferencesService(
    initialRelays: const {
      RelayCategory.inbox: ['wss://inbox.example.com'],
      RelayCategory.keyPackage: ['wss://kp.example.com'],
    },
  );

  group('RelaySettingsPage', () {
    testWidgets('renders both relay sections', (tester) async {
      await tester.pumpWidget(buildApp(mock: seededMock()));
      await tester.pumpAndSettle();

      expect(find.text('My Inbox Relays'), findsOneWidget);
      expect(find.text('My KeyPackage Relays'), findsOneWidget);
      expect(find.text('inbox.example.com'), findsOneWidget);
      expect(find.text('kp.example.com'), findsOneWidget);
    });

    testWidgets('uses the refresh ring, not a spinner', (tester) async {
      await tester.pumpWidget(buildApp(mock: seededMock()));
      await tester.pumpAndSettle();

      // The segmented ring replaces the former IconButton/CircularProgress
      // swap; the app bar must never show a spinner while checking.
      expect(find.byType(RefreshRingButton), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(AppBar),
          matching: find.byType(CircularProgressIndicator),
        ),
        findsNothing,
      );
    });

    testWidgets('shows the backend explainer note', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(buildApp(mock: seededMock()));
      await tester.pumpAndSettle();

      // Scroll to surface the footer note via its concrete heading.
      final heading = find.text('How this works');
      await tester.scrollUntilVisible(heading, 300);
      expect(heading, findsOneWidget);
      expect(
        find.bySemanticsLabel(RegExp('How Haven relays work')),
        findsWidgets,
      );
      // It explains the backend and both relay roles...
      expect(find.textContaining('no central server'), findsOneWidget);
      expect(
        find.textContaining('KeyPackage relays', findRichText: true),
        findsWidgets,
      );
      // ...and the old privacy-tradeoff copy is gone.
      expect(find.textContaining('Private relays stay private'), findsNothing);
      handle.dispose();
    });

    testWidgets('renders Add relay buttons for each category', (tester) async {
      await tester.pumpWidget(buildApp(mock: seededMock()));
      await tester.pumpAndSettle();

      // One Add button per category.
      expect(find.text('Add relay'), findsNWidgets(2));
    });

    testWidgets('renders Restore defaults buttons for each category', (
      tester,
    ) async {
      await tester.pumpWidget(buildApp(mock: seededMock()));
      await tester.pumpAndSettle();

      expect(find.text('Restore defaults'), findsNWidgets(2));
    });

    testWidgets('shows empty-identity state when no identity', (tester) async {
      final mock = MockRelayPreferencesService();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            identityProvider.overrideWith((ref) async => null),
            relayPreferencesServiceProvider.overrideWith((ref) async => mock),
            relayServiceProvider.overrideWithValue(MockRelayService()),
          ],
          child: const MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: RelaySettingsPage(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('No Identity'), findsOneWidget);
    });

    testWidgets('strips wss:// prefix in relay row display', (tester) async {
      final mock = MockRelayPreferencesService(
        initialRelays: const {
          RelayCategory.inbox: ['wss://nice.example.com'],
          RelayCategory.keyPackage: ['wss://kp.example.com'],
        },
      );
      await tester.pumpWidget(buildApp(mock: mock));
      await tester.pumpAndSettle();

      // Display strips wss:// for compactness.
      expect(find.text('nice.example.com'), findsOneWidget);
      expect(find.text('wss://nice.example.com'), findsNothing);
    });

    testWidgets('removes a relay via the trash icon', (tester) async {
      final mock = MockRelayPreferencesService(
        initialRelays: const {
          RelayCategory.inbox: [
            'wss://keep.example.com',
            'wss://drop.example.com',
          ],
          RelayCategory.keyPackage: ['wss://kp.example.com'],
        },
      );
      await tester.pumpWidget(buildApp(mock: mock));
      await tester.pumpAndSettle();

      // Tap the trash icon for the relay we want to drop. The tooltip
      // is "Remove <displayUrl>" — see _EditableRelayRow.
      await tester.tap(find.byTooltip('Remove drop.example.com'));
      await tester.pumpAndSettle();

      expect(find.text('drop.example.com'), findsNothing);
      expect(find.text('keep.example.com'), findsOneWidget);
    });
  });
}
