/// Widget tests for AddMemberPage.
///
/// Covers: empty state rendering, valid member search + validate, existing
/// member exclusion (hex pubkey match), no-account (null KP), confirm success
/// path (snackbar + startAdminWatch + nav pop), partial delivery snackbar,
/// and error handling (snackbar, no pop, button re-enabled).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/pages/circles/add_member_page.dart';
import 'package:haven/src/providers/circles_provider.dart';
import 'package:haven/src/providers/identity_provider.dart';
import 'package:haven/src/providers/join_watcher_provider.dart';
import 'package:haven/src/providers/location_sharing_provider.dart';
import 'package:haven/src/providers/relay_preferences_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/services/identity_service.dart';
import 'package:haven/src/test_keys.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../mocks/mock_circle_service.dart';
import '../../mocks/mock_relay_service.dart';

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

/// A valid 63-character npub used as a "new member" in most tests.
const _newMemberNpub =
    'npub1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqspcd5';

/// The hex pubkey that a fresh KP event JSON advertises (NOT in the circle).
const _newMemberHex =
    'aabbccddaabbccddaabbccddaabbccddaabbccddaabbccddaabbccddaabbccdd';

/// The hex pubkey already present in the test circle's member list.
const _existingMemberHex =
    'abc123def456abc123def456abc123def456abc123def456abc123def456abcd';

// ---------------------------------------------------------------------------
// Test helpers
// ---------------------------------------------------------------------------

/// The test identity (self = admin of the circle).
final _testIdentity = Identity(
  pubkeyHex: _existingMemberHex,
  npub: 'npub1test',
  createdAt: DateTime(2024),
);

/// Builds a [KeyPackageData] whose `eventJson` carries [pubkeyHex] under the
/// current (Dark Matter, kind 30443) KeyPackage kind.
KeyPackageData _makeKp(String pubkeyHex) => KeyPackageData(
  pubkey: 'npub1newmember',
  eventJson: jsonEncode({'kind': 30443, 'pubkey': pubkeyHex}),
  relays: const ['wss://relay.example.com'],
);

/// Builds a [KeyPackageData] carrying the deprecated pre-Dark-Matter kind
/// (443) — the peer is on an old Haven build (DM-4c, plan §6 F11).
KeyPackageData _makeLegacyKp(String pubkeyHex) => KeyPackageData(
  pubkey: 'npub1newmember',
  eventJson: jsonEncode({'kind': 443, 'pubkey': pubkeyHex}),
  relays: const ['wss://relay.example.com'],
);

/// Default test circle: has one admin member whose hex == [_existingMemberHex].
///
/// The factory's default displayName is "Test Circle", which matches the
/// AppBar title assertion in test 1.
Circle _makeCircle({List<CircleMember>? members}) {
  return TestCircleFactory.createCircle(
    mlsGroupId: const [1, 2, 3, 4],
    members:
        members ??
        [
          TestCircleFactory.createMember(
            pubkey: _existingMemberHex,
            isAdmin: true,
          ),
        ],
  );
}

// ---------------------------------------------------------------------------
// Stub inbox relay notifier
// ---------------------------------------------------------------------------

/// Stub that satisfies [inboxRelaysProvider]'s [AsyncNotifierProvider] type
/// without touching SQLite or Rust.
class _StubInboxRelays extends InboxRelaysNotifier {
  @override
  Future<List<String>> build() async => ['wss://relay.example'];
}

// ---------------------------------------------------------------------------
// Mock identity service (no FFI)
// ---------------------------------------------------------------------------

/// A minimal [IdentityService] that answers all methods without FFI.
class _MockIdentityService implements IdentityService {
  const _MockIdentityService();

  @override
  Future<Identity?> getIdentity() async => _testIdentity;

  @override
  Future<bool> hasIdentity() async => true;

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
  Future<String> getPubkeyHex() async => _testIdentity.pubkeyHex;

  @override
  Future<List<int>> getSecretBytes() async => List<int>.filled(32, 0);

  @override
  Future<String?> getDisplayName() async => null;

  @override
  Future<void> setDisplayName(String? name) async {}

  @override
  Future<void> clearCache() async {}
}

// ---------------------------------------------------------------------------
// Fake IdentityNotifier
// ---------------------------------------------------------------------------

/// A fake [IdentityNotifier] that exposes [getSecretBytes] without FFI.
class _FakeIdentityNotifier extends IdentityNotifier {
  @override
  Future<Identity?> build() async => _testIdentity;

  @override
  Future<List<int>> getSecretBytes() async => List<int>.filled(32, 0);
}

// ---------------------------------------------------------------------------
// Provider override list shared by all tests
// ---------------------------------------------------------------------------

List<Override> _overrides({
  required MockRelayService mockRelay,
  required MockCircleService mockCircle,
}) {
  return [
    relayServiceProvider.overrideWithValue(mockRelay),
    circleServiceProvider.overrideWithValue(mockCircle),
    identityServiceProvider.overrideWithValue(const _MockIdentityService()),
    identityProvider.overrideWith((_) async => _testIdentity),
    identityNotifierProvider.overrideWith(_FakeIdentityNotifier.new),
    // Stub inbox relay list — prevents InboxRelaysNotifier from hitting SQLite.
    inboxRelaysProvider.overrideWith(_StubInboxRelays.new),
    // Stub circles so invalidate() after confirm doesn't reach Rust.
    circlesProvider.overrideWith((ref) => Future.value(<Circle>[])),
    memberLocationsProvider.overrideWith((_) async => const []),
    // Deterministic RNG so JoinWatcherNotifier timers are predictable.
    joinWatcherProvider.overrideWith(
      (ref) => JoinWatcherNotifier(ref, rng: Random(0)),
    ),
  ];
}

/// Builds the full test widget wrapping [circle] in a [MaterialApp].
Widget _buildApp({
  required Circle circle,
  required MockRelayService mockRelay,
  required MockCircleService mockCircle,
}) {
  return ProviderScope(
    overrides: _overrides(mockRelay: mockRelay, mockCircle: mockCircle),
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: ThemeData(
        useMaterial3: false,
        splashFactory: InkSplash.splashFactory,
      ),
      home: AddMemberPage(circle: circle),
    ),
  );
}

/// Enters [npub] into the search field and presses the add button, then
/// pumps once so the async validation starts.
Future<void> _addMember(WidgetTester tester, String npub) async {
  await tester.enterText(find.byType(TextField), npub);
  await tester.tap(find.byIcon(LucideIcons.circlePlus));
  await tester.pump();
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AddMemberPage', () {
    // -----------------------------------------------------------------------
    // 1. Empty state
    // -----------------------------------------------------------------------
    testWidgets('1. empty state shows icon and helper text; confirm disabled', (
      tester,
    ) async {
      final mockRelay = MockRelayService();
      final mockCircle = MockCircleService();
      final circle = _makeCircle();

      await tester.pumpWidget(
        _buildApp(
          circle: circle,
          mockRelay: mockRelay,
          mockCircle: mockCircle,
        ),
      );
      await tester.pumpAndSettle();

      // AppBar title reflects the circle name.
      expect(find.text('Add to Test Circle'), findsOneWidget);

      // Empty-state content. The MemberSearchBar also shows a userPlus prefix
      // icon so there are at least two — assert the presence of both the icon
      // and the helper text to confirm the empty state renders.
      expect(find.byIcon(LucideIcons.userPlus), findsWidgets);
      expect(find.text('Add circle members'), findsOneWidget);

      // Confirm button is disabled when no members are selected.
      final button = tester.widget<FilledButton>(
        find.byKey(WidgetKeys.addMemberConfirm),
      );
      expect(button.onPressed, isNull);
    });

    // -----------------------------------------------------------------------
    // 2. Valid member: confirm becomes enabled
    // -----------------------------------------------------------------------
    testWidgets(
      '2. valid npub fetches KP, shows valid tile, enables confirm',
      (tester) async {
        final mockRelay = MockRelayService(
          keyPackageResult: _makeKp(_newMemberHex),
        );
        final mockCircle = MockCircleService();
        final circle = _makeCircle();

        await tester.pumpWidget(
          _buildApp(
            circle: circle,
            mockRelay: mockRelay,
            mockCircle: mockCircle,
          ),
        );
        await tester.pumpAndSettle();

        await _addMember(tester, _newMemberNpub);

        // Spinner may or may not be visible at this point — test 8 covers the
        // in-flight state with an explicit gate. Allow all microtasks here.
        await tester.pumpAndSettle();

        // Valid status.
        expect(find.byIcon(LucideIcons.circleCheck), findsOneWidget);
        expect(find.text('Ready to invite'), findsOneWidget);

        // Confirm button must now be enabled.
        final button = tester.widget<FilledButton>(
          find.byKey(WidgetKeys.addMemberConfirm),
        );
        expect(button.onPressed, isNotNull);
      },
    );

    // -----------------------------------------------------------------------
    // 3. Existing-member exclusion
    // -----------------------------------------------------------------------
    testWidgets(
      '3. KP whose pubkey is already in circle shows "Already in this circle"'
      ' and keeps confirm disabled',
      (tester) async {
        // The KP event JSON carries the existing member's hex pubkey.
        final mockRelay = MockRelayService(
          keyPackageResult: _makeKp(_existingMemberHex),
        );
        final mockCircle = MockCircleService();
        // circle member pubkey == _existingMemberHex
        final circle = _makeCircle();

        await tester.pumpWidget(
          _buildApp(
            circle: circle,
            mockRelay: mockRelay,
            mockCircle: mockCircle,
          ),
        );
        await tester.pumpAndSettle();

        await _addMember(tester, _newMemberNpub);
        await tester.pumpAndSettle();

        // Tile must show the exclusion error.
        expect(find.byIcon(LucideIcons.triangleAlert), findsOneWidget);
        expect(find.text('Already in this circle'), findsOneWidget);

        // Confirm stays disabled.
        final button = tester.widget<FilledButton>(
          find.byKey(WidgetKeys.addMemberConfirm),
        );
        expect(button.onPressed, isNull);
      },
    );

    // -----------------------------------------------------------------------
    // 4. No Haven account (null KP)
    // -----------------------------------------------------------------------
    testWidgets(
      '4. null KP shows "No Haven account found"; confirm stays disabled',
      (tester) async {
        final mockRelay = MockRelayService(); // keyPackageResult defaults null
        final mockCircle = MockCircleService();
        final circle = _makeCircle();

        await tester.pumpWidget(
          _buildApp(
            circle: circle,
            mockRelay: mockRelay,
            mockCircle: mockCircle,
          ),
        );
        await tester.pumpAndSettle();

        await _addMember(tester, _newMemberNpub);
        await tester.pumpAndSettle();

        expect(find.byIcon(LucideIcons.triangleAlert), findsOneWidget);
        expect(find.text('No Haven account found'), findsOneWidget);

        final button = tester.widget<FilledButton>(
          find.byKey(WidgetKeys.addMemberConfirm),
        );
        expect(button.onPressed, isNull);
      },
    );

    // -----------------------------------------------------------------------
    // 5. Confirm success path
    // -----------------------------------------------------------------------
    testWidgets(
      '5. confirm success: addMember called; snackbar "Invitation sent"; '
      'joinWatcher becomes adminWaitingForJoin; page pops',
      (tester) async {
        final mockRelay = MockRelayService(
          keyPackageResult: _makeKp(_newMemberHex),
        );
        final mockCircle = MockCircleService()
          ..addMemberResult = const AddMemberResult(
            welcomesSent: 1,
            welcomesTotal: 1,
          );
        final circle = _makeCircle();

        // Use a NavigatorObserver to detect the pop.
        final observer = _RecordingNavigatorObserver();

        final container = ProviderContainer(
          overrides: _overrides(
            mockRelay: mockRelay,
            mockCircle: mockCircle,
          ),
        );
        addTearDown(container.dispose);

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              navigatorObservers: [observer],
              theme: ThemeData(
                useMaterial3: false,
                splashFactory: InkSplash.splashFactory,
              ),
              // Wrap in a parent route so AddMemberPage can pop back.
              home: Scaffold(
                body: Builder(
                  builder:
                      (ctx) => ElevatedButton(
                        onPressed:
                            () => Navigator.of(ctx).push(
                              MaterialPageRoute<void>(
                                builder: (_) => AddMemberPage(circle: circle),
                              ),
                            ),
                        child: const Text('Open'),
                      ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Navigate to AddMemberPage.
        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();

        expect(find.byType(AddMemberPage), findsOneWidget);

        // Add and validate a member.
        await _addMember(tester, _newMemberNpub);
        await tester.pumpAndSettle();
        expect(find.byIcon(LucideIcons.circleCheck), findsOneWidget);

        // Tap confirm. Pump individual frames rather than pumpAndSettle so the
        // JoinWatcherNotifier's long-lived Timers do not cause a hang.
        await tester.tap(find.byKey(WidgetKeys.addMemberConfirm));
        // Let the async addMember call + setState resolve.
        await tester.pump();
        await tester.pump(Duration.zero);
        await tester.pump(Duration.zero);

        // addMember was called exactly once with the correct group id.
        expect(mockCircle.addMemberCalls, hasLength(1));
        expect(
          mockCircle.addMemberCalls.first.mlsGroupId,
          circle.mlsGroupId,
        );

        // The KeyPackage list passed to the service has exactly one entry.
        expect(
          mockCircle.addMemberCalls.first.memberKeyPackages,
          hasLength(1),
        );

        // Success snackbar names the circle.
        expect(find.text('Invitation sent to Test Circle'), findsOneWidget);

        // joinWatcher must have entered adminWaitingForJoin synchronously
        // (startAdminWatch updates state immediately, before any timer fires).
        final watchState = container.read(joinWatcherProvider);
        expect(watchState.mode, JoinWatchMode.adminWaitingForJoin);
        expect(watchState.mlsGroupId, circle.mlsGroupId);

        // Cancel the watcher BEFORE further pump calls so pending timers are
        // cleared before the test framework checks for them.
        container.read(joinWatcherProvider.notifier).cancel();

        // Observer fires synchronously on pop — the navigator pop already
        // happened during the pump sequence above.
        expect(observer.popped, isTrue);
      },
    );

    // -----------------------------------------------------------------------
    // 6. Partial delivery
    // -----------------------------------------------------------------------
    testWidgets(
      '6. partial delivery: snackbar reports the pending-delivery count',
      (tester) async {
        final mockRelay = MockRelayService(
          keyPackageResult: _makeKp(_newMemberHex),
        );
        final mockCircle = MockCircleService()
          ..addMemberResult = const AddMemberResult(
            welcomesSent: 0,
            welcomesTotal: 1,
          );
        final circle = _makeCircle();

        final container = ProviderContainer(
          overrides: _overrides(
            mockRelay: mockRelay,
            mockCircle: mockCircle,
          ),
        );
        addTearDown(container.dispose);

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              theme: ThemeData(
                useMaterial3: false,
                splashFactory: InkSplash.splashFactory,
              ),
              home: Scaffold(
                body: Builder(
                  builder:
                      (ctx) => ElevatedButton(
                        onPressed:
                            () => Navigator.of(ctx).push(
                              MaterialPageRoute<void>(
                                builder: (_) => AddMemberPage(circle: circle),
                              ),
                            ),
                        child: const Text('Open'),
                      ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();

        await _addMember(tester, _newMemberNpub);
        await tester.pumpAndSettle();

        // Pump individual frames to avoid pumpAndSettle hanging on
        // JoinWatcher's long-lived timers.
        await tester.tap(find.byKey(WidgetKeys.addMemberConfirm));
        await tester.pump();
        await tester.pump(Duration.zero);
        await tester.pump(Duration.zero);

        expect(
          find.text(
            'Invitations sent (0 of 1). Delivery pending for the rest.',
          ),
          findsOneWidget,
        );

        // Cancel the watcher so no pending timers survive after test disposal.
        container.read(joinWatcherProvider.notifier).cancel();
      },
    );

    // -----------------------------------------------------------------------
    // 7. Error: shows snackbar, page stays, button re-enabled
    // -----------------------------------------------------------------------
    testWidgets(
      '7. addMember throws: snackbar "Failed to add member. Please try '
      'again."; page does NOT pop; confirm re-enabled',
      (tester) async {
        final mockRelay = MockRelayService(
          keyPackageResult: _makeKp(_newMemberHex),
        );
        final mockCircle = MockCircleService()
          ..shouldThrowOnAddMember = true;
        final circle = _makeCircle();

        final observer = _RecordingNavigatorObserver();

        final container = ProviderContainer(
          overrides: _overrides(
            mockRelay: mockRelay,
            mockCircle: mockCircle,
          ),
        );
        addTearDown(container.dispose);

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              navigatorObservers: [observer],
              theme: ThemeData(
                useMaterial3: false,
                splashFactory: InkSplash.splashFactory,
              ),
              home: Scaffold(
                body: Builder(
                  builder:
                      (ctx) => ElevatedButton(
                        onPressed:
                            () => Navigator.of(ctx).push(
                              MaterialPageRoute<void>(
                                builder: (_) => AddMemberPage(circle: circle),
                              ),
                            ),
                        child: const Text('Open'),
                      ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();
        expect(find.byType(AddMemberPage), findsOneWidget);

        await _addMember(tester, _newMemberNpub);
        await tester.pumpAndSettle();

        // Reset the pop-observer before the confirm tap.
        observer.reset();

        await tester.tap(find.byKey(WidgetKeys.addMemberConfirm));
        await tester.pumpAndSettle();

        // Error snackbar.
        expect(
          find.text('Failed to add member. Please try again.'),
          findsOneWidget,
        );

        // Page must still be visible.
        expect(find.byType(AddMemberPage), findsOneWidget);
        expect(observer.popped, isFalse);

        // Button must be re-enabled (spinner gone).
        final button = tester.widget<FilledButton>(
          find.byKey(WidgetKeys.addMemberConfirm),
        );
        expect(button.onPressed, isNotNull);

        // joinWatcher must remain idle (no startAdminWatch fired on error).
        final watchState = container.read(joinWatcherProvider);
        expect(watchState.mode, JoinWatchMode.idle);
      },
    );

    // -----------------------------------------------------------------------
    // 8. Confirm is disabled while validation is in flight (gate test)
    // -----------------------------------------------------------------------
    testWidgets(
      '8. confirm stays disabled while KP fetch is in flight',
      (tester) async {
        final gate = Completer<void>();
        final mockRelay = MockRelayService(
          keyPackageResult: _makeKp(_newMemberHex),
        )..fetchKeyPackageGate = gate;
        final mockCircle = MockCircleService();
        final circle = _makeCircle();

        await tester.pumpWidget(
          _buildApp(
            circle: circle,
            mockRelay: mockRelay,
            mockCircle: mockCircle,
          ),
        );
        await tester.pumpAndSettle();

        await _addMember(tester, _newMemberNpub);
        // Gate is still open — validation is pending.

        final button = tester.widget<FilledButton>(
          find.byKey(WidgetKeys.addMemberConfirm),
        );
        expect(button.onPressed, isNull);

        // Clean up to avoid leaked async.
        gate.complete();
        await tester.pumpAndSettle();
      },
    );

    // -----------------------------------------------------------------------
    // 9. Removing a member brings back the empty state
    // -----------------------------------------------------------------------
    testWidgets(
      '9. removing the only member reverts to empty state',
      (tester) async {
        final mockRelay = MockRelayService(
          keyPackageResult: _makeKp(_newMemberHex),
        );
        final mockCircle = MockCircleService();
        final circle = _makeCircle();

        await tester.pumpWidget(
          _buildApp(
            circle: circle,
            mockRelay: mockRelay,
            mockCircle: mockCircle,
          ),
        );
        await tester.pumpAndSettle();

        await _addMember(tester, _newMemberNpub);
        await tester.pumpAndSettle();

        expect(find.byIcon(LucideIcons.circleCheck), findsOneWidget);

        // Remove via the × button on the PendingMemberTile.
        await tester.tap(find.byIcon(LucideIcons.x));
        await tester.pump();

        expect(find.byIcon(LucideIcons.circleCheck), findsNothing);
        expect(find.text('Add circle members'), findsOneWidget);
      },
    );

    // -----------------------------------------------------------------------
    // 10. RelayServiceException shows network-error tile + retry button
    // -----------------------------------------------------------------------
    testWidgets(
      '10. RelayServiceException shows "Could not verify member" + retry',
      (tester) async {
        final mockRelay = MockRelayService(
          shouldThrowOnFetchKeyPackage: true,
        );
        final mockCircle = MockCircleService();
        final circle = _makeCircle();

        await tester.pumpWidget(
          _buildApp(
            circle: circle,
            mockRelay: mockRelay,
            mockCircle: mockCircle,
          ),
        );
        await tester.pumpAndSettle();

        await _addMember(tester, _newMemberNpub);
        await tester.pumpAndSettle();

        expect(find.byIcon(LucideIcons.triangleAlert), findsOneWidget);
        expect(find.text('Could not verify member'), findsOneWidget);
        expect(find.byIcon(LucideIcons.refreshCw), findsOneWidget);
      },
    );

    // -----------------------------------------------------------------------
    // 11. Info note de-greened (copy kept, green badge + lock removed)
    // -----------------------------------------------------------------------
    testWidgets(
      '11. info note is a plain text box (copy kept, green badge + lock gone)',
      (tester) async {
        final mockRelay = MockRelayService();
        final mockCircle = MockCircleService();
        final circle = _makeCircle();

        await tester.pumpWidget(
          _buildApp(
            circle: circle,
            mockRelay: mockRelay,
            mockCircle: mockCircle,
          ),
        );
        await tester.pumpAndSettle();

        // The useful copy is preserved verbatim...
        expect(
          find.textContaining("New members can see this circle's encrypted"),
          findsOneWidget,
        );
        // ...but the green security badge's lock icon is gone.
        expect(find.byIcon(LucideIcons.lock), findsNothing);
      },
    );

    // -----------------------------------------------------------------------
    // 12. Legacy (kind 443) KeyPackage — Dark Matter migration (DM-4c)
    // -----------------------------------------------------------------------
    testWidgets(
      '12. legacy (kind 443) KeyPackage shows "needs update" status and '
      'keeps confirm disabled',
      (tester) async {
        final mockRelay = MockRelayService(
          keyPackageResult: _makeLegacyKp(_newMemberHex),
        );
        final mockCircle = MockCircleService();
        final circle = _makeCircle();

        await tester.pumpWidget(
          _buildApp(
            circle: circle,
            mockRelay: mockRelay,
            mockCircle: mockCircle,
          ),
        );
        await tester.pumpAndSettle();

        await _addMember(tester, _newMemberNpub);
        await tester.pumpAndSettle();

        expect(find.byIcon(LucideIcons.circleCheck), findsNothing);
        expect(find.text('Needs to update Haven'), findsOneWidget);

        final button = tester.widget<FilledButton>(
          find.byKey(WidgetKeys.addMemberConfirm),
        );
        expect(button.onPressed, isNull);
      },
    );
  });
}

// ---------------------------------------------------------------------------
// Navigation observer
// ---------------------------------------------------------------------------

/// Records the most-recent pop so tests can assert [popped] after a confirm.
class _RecordingNavigatorObserver extends NavigatorObserver {
  bool _popped = false;

  bool get popped => _popped;

  void reset() => _popped = false;

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _popped = true;
  }
}
