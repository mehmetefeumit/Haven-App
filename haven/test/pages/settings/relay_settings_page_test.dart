/// Widget tests for RelaySettingsPage.
///
/// Verifies:
/// - Page title renders
/// - Shows empty state when no identity
/// - Shows all default relay URLs
/// - Shows info card text
/// - Shows "Not checked" initially
/// - After mock refresh: shows green check / orange cancel per relay
/// - Refresh button exists
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/constants/relays.dart';
import 'package:haven/src/pages/settings/relay_settings_page.dart';
import 'package:haven/src/providers/identity_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/services/identity_service.dart';
import 'package:haven/src/services/relay_service.dart';

import '../../mocks/mock_relay_service.dart';

final _testIdentity = Identity(
  pubkeyHex: 'abc123def456abc123def456abc123def456abc123def456abc123def456abcd',
  npub: 'npub1test',
  createdAt: DateTime(2024),
);

Widget _buildApp({
  Identity? identity,
  bool useDefaultIdentity = true,
  MockRelayService? relayService,
}) {
  final mockRelay = relayService ?? MockRelayService();
  final effectiveIdentity = useDefaultIdentity
      ? (identity ?? _testIdentity)
      : identity;

  return ProviderScope(
    overrides: [
      identityProvider.overrideWith((_) async => effectiveIdentity),
      relayServiceProvider.overrideWithValue(mockRelay),
    ],
    child: MaterialApp(
      theme: ThemeData(
        useMaterial3: false,
        splashFactory: InkSplash.splashFactory,
      ),
      home: const RelaySettingsPage(),
    ),
  );
}

void main() {
  group('RelaySettingsPage', () {
    testWidgets('renders page title', (tester) async {
      await tester.pumpWidget(_buildApp());
      await tester.pumpAndSettle();

      expect(find.text('Relays'), findsOneWidget);
    });

    testWidgets('shows empty state when no identity', (tester) async {
      await tester.pumpWidget(
        _buildApp(identity: null, useDefaultIdentity: false),
      );
      await tester.pumpAndSettle();

      expect(find.text('No Identity'), findsOneWidget);
      expect(
        find.text(
          'Create a Nostr identity first to publish '
          'events to relays.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('shows all default relay URLs', (tester) async {
      await tester.pumpWidget(_buildApp());
      await tester.pumpAndSettle();

      for (final relay in defaultRelays) {
        // URLs are displayed without wss:// prefix
        final displayUrl = relay.replaceFirst('wss://', '');
        expect(find.text(displayUrl), findsOneWidget);
      }
    });

    testWidgets('shows info card text', (tester) async {
      await tester.pumpWidget(_buildApp());
      await tester.pumpAndSettle();

      expect(
        find.textContaining('Relays store your KeyPackage'),
        findsOneWidget,
      );
    });

    testWidgets('shows status labels for each relay', (tester) async {
      await tester.pumpWidget(_buildApp());
      await tester.pumpAndSettle();

      // Each relay should have both kind labels
      expect(
        find.text('KeyPackage (443)'),
        findsNWidgets(defaultRelays.length),
      );
      expect(
        find.text('Relay List (10051)'),
        findsNWidgets(defaultRelays.length),
      );
    });

    testWidgets('shows found status after successful check', (tester) async {
      final now = DateTime.now();
      final checkResults = <String, RelayEventCheck>{};
      for (final relay in defaultRelays) {
        checkResults['$relay:443'] = RelayEventCheck(
          relayUrl: relay,
          found: true,
          eventCount: 1,
          newestTimestamp: now,
        );
        checkResults['$relay:10051'] = RelayEventCheck(
          relayUrl: relay,
          found: true,
          eventCount: 1,
          newestTimestamp: now,
        );
      }

      final mock = MockRelayService(checkEventResults: checkResults);
      await tester.pumpWidget(_buildApp(relayService: mock));
      // Wait for auto-check triggered by initState
      await tester.pumpAndSettle();

      // Should show green check icons (one per kind per relay = 6 total)
      expect(
        find.byIcon(Icons.check_circle),
        findsNWidgets(defaultRelays.length * 2),
      );
    });

    testWidgets('shows not found status when events missing', (tester) async {
      final mock = MockRelayService();
      await tester.pumpWidget(_buildApp(relayService: mock));
      await tester.pumpAndSettle();

      // Should show cancel icons for not found
      expect(
        find.byIcon(Icons.cancel),
        findsNWidgets(defaultRelays.length * 2),
      );
      expect(find.text('Not found'), findsNWidgets(defaultRelays.length * 2));
    });

    testWidgets('shows error status when check throws', (tester) async {
      final mock = MockRelayService(shouldThrowOnCheckEvent: true);
      await tester.pumpWidget(_buildApp(relayService: mock));
      await tester.pumpAndSettle();

      // Should show error icons
      expect(find.byIcon(Icons.error), findsNWidgets(defaultRelays.length * 2));
      expect(find.text('Error'), findsNWidgets(defaultRelays.length * 2));
    });

    testWidgets('refresh button triggers check', (tester) async {
      final mock = MockRelayService();
      await tester.pumpWidget(_buildApp(relayService: mock));
      await tester.pumpAndSettle();

      // Clear method calls from initial auto-check
      mock.methodCalls.clear();

      // Tap refresh button
      await tester.tap(find.byIcon(Icons.refresh));
      await tester.pumpAndSettle();

      // Should have called checkEventOnRelay again
      expect(
        mock.methodCalls.where((c) => c.startsWith('checkEventOnRelay')),
        isNotEmpty,
      );
    });

    testWidgets('shows last checked timestamp', (tester) async {
      final mock = MockRelayService();
      await tester.pumpWidget(_buildApp(relayService: mock));
      await tester.pumpAndSettle();

      expect(find.textContaining('Last checked:'), findsOneWidget);
    });
  });
}
