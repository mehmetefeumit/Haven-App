/// Widget tests for [NameCirclePage].
library;

import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/constants/circle_name_policy.dart';
import 'package:haven/src/pages/circles/name_circle_page.dart';
import 'package:haven/src/providers/circles_provider.dart';
import 'package:haven/src/providers/identity_provider.dart';
import 'package:haven/src/providers/join_watcher_provider.dart';
import 'package:haven/src/providers/key_package_provider.dart';
import 'package:haven/src/providers/location_sharing_provider.dart';
import 'package:haven/src/providers/relay_preferences_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/services/identity_service.dart';
import 'package:haven/src/services/relay_service.dart';
import 'package:haven/src/test_keys.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../mocks/mock_circle_service.dart';

// ---------------------------------------------------------------------------
// Fixtures / fakes shared by the "create flow" group below
// ---------------------------------------------------------------------------

/// The test identity used by every "create flow" test.
final _testIdentity = Identity(
  pubkeyHex:
      'abc123def456abc123def456abc123def456abc123def456abc123def456abcd',
  npub: 'npub1test',
  createdAt: DateTime(2024),
);

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

/// A fake [IdentityNotifier] that exposes [getSecretBytes] without FFI.
class _FakeIdentityNotifier extends IdentityNotifier {
  @override
  Future<Identity?> build() async => _testIdentity;

  @override
  Future<List<int>> getSecretBytes() async => List<int>.filled(32, 0);
}

/// Stub that satisfies [inboxRelaysProvider]'s [AsyncNotifierProvider] type
/// without touching SQLite or Rust.
class _StubInboxRelays extends InboxRelaysNotifier {
  @override
  Future<List<String>> build() async => ['wss://relay.example'];
}

/// Builds a [KeyPackageData] for an invitee. Only [pubkey] is observable by
/// the page under test (it feeds the member-summary chips); the rest of the
/// content is never inspected because [MockCircleService.createCircle]
/// returns a caller-configured result rather than deriving one from its
/// arguments.
KeyPackageData _invitee(String pubkey) => KeyPackageData(
  pubkey: pubkey,
  eventJson: '{"kind":30443,"pubkey":"$pubkey"}',
  relays: const ['wss://relay.example.com'],
);

/// Provider overrides shared by every "create flow" test.
List<Override> _overrides({required MockCircleService mockCircle}) {
  return [
    circleServiceProvider.overrideWithValue(mockCircle),
    identityServiceProvider.overrideWithValue(const _MockIdentityService()),
    identityProvider.overrideWith((_) async => _testIdentity),
    identityNotifierProvider.overrideWith(_FakeIdentityNotifier.new),
    // Stub inbox relay list — prevents InboxRelaysNotifier from hitting SQLite.
    inboxRelaysProvider.overrideWith(_StubInboxRelays.new),
    // Stub circles so invalidate() after confirm doesn't reach Rust.
    circlesProvider.overrideWith((ref) => Future.value(<Circle>[])),
    memberLocationsProvider.overrideWith((_) async => const []),
    // The page fires these two publishers fire-and-forget on success; their
    // real implementations reach Rust/relay I/O this suite never sets up, so
    // they are replaced with no-ops rather than left to run unmocked.
    keyPackagePublisherProvider.overrideWith(
      (ref) async => const KeyPackageMaintenanceHealthy(
        canonicalOnRelays: 1,
        respondersProbed: 1,
      ),
    ),
    locationPublisherProvider.overrideWith((ref) async => 0),
    // Deterministic RNG so JoinWatcherNotifier timers are predictable.
    joinWatcherProvider.overrideWith(
      (ref) => JoinWatcherNotifier(ref, rng: Random(0)),
    ),
  ];
}

/// Wraps [NameCirclePage] two routes deep (mirroring the real
/// CreateCirclePage → NameCirclePage push chain), so the page's own
/// double-`pop()` on success lands back on a real route instead of popping
/// past the navigator's initial route.
Widget _buildNavApp({
  required ProviderContainer container,
  required NavigatorObserver observer,
  required List<KeyPackageData> memberKeyPackages,
}) {
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      navigatorObservers: [observer],
      home: Scaffold(
        body: Builder(
          builder: (ctx) => ElevatedButton(
            onPressed: () => Navigator.of(ctx).push(
              MaterialPageRoute<void>(
                builder: (_) => Scaffold(
                  body: Builder(
                    builder: (ctx2) => ElevatedButton(
                      onPressed: () => Navigator.of(ctx2).push(
                        MaterialPageRoute<void>(
                          builder: (_) => NameCirclePage(
                            memberKeyPackages: memberKeyPackages,
                          ),
                        ),
                      ),
                      child: const Text('OpenName'),
                    ),
                  ),
                ),
              ),
            ),
            child: const Text('Open'),
          ),
        ),
      ),
    ),
  );
}

/// Records how many times a route was popped.
class _PopCountingNavigatorObserver extends NavigatorObserver {
  int popCount = 0;

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    popCount++;
  }
}

/// Navigates to [NameCirclePage], fills in [name], and taps Create.
///
/// Returns the localizations resolved while the page is still mounted — the
/// create flow pops past it, so the caller could not resolve them afterwards.
Future<AppLocalizations> _createCircle(
  WidgetTester tester, {
  required String name,
}) async {
  await tester.pumpAndSettle();
  await tester.tap(find.text('Open'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('OpenName'));
  await tester.pumpAndSettle();

  expect(find.byType(NameCirclePage), findsOneWidget);
  final l10n = AppLocalizations.of(
    tester.element(find.byType(NameCirclePage)),
  );

  await tester.enterText(find.byKey(WidgetKeys.circleNameInput), name);
  await tester.tap(find.byKey(WidgetKeys.createCircleConfirm));

  // Drain the async chain (creator-fallback-relays fetch, secret-bytes
  // fetch, createCircle call, then the snackbar/pop) without pumpAndSettle,
  // which would hang on JoinWatcherNotifier's long-lived timers.
  for (var i = 0; i < 6; i++) {
    await tester.pump(Duration.zero);
  }
  return l10n;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpPage(WidgetTester tester) async {
    // NameCirclePage only reads providers when Create is pressed, so it pumps
    // without overrides. ProviderScope is still required for its `ref`.
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: NameCirclePage(memberKeyPackages: []),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('shows the plain-language "what this circle means" note', (
    tester,
  ) async {
    await pumpPage(tester);

    // The useful disclosure is present: mutual location + name visibility,
    // the name's source, and cross-circle isolation.
    expect(
      find.textContaining('public name and photo'),
      findsOneWidget,
    );
    expect(
      find.textContaining('public on the Nostr network'),
      findsOneWidget,
    );
    expect(
      find.textContaining('stays separate from any others'),
      findsOneWidget,
    );
  });

  testWidgets('drops the old green encryption badge and lock icon', (
    tester,
  ) async {
    await pumpPage(tester);

    expect(
      find.text('Your location is encrypted and private to this circle'),
      findsNothing,
    );
    expect(find.byIcon(LucideIcons.lock), findsNothing);
  });

  group('name length validator', () {
    // Exercises the production validator closure directly (not a
    // reimplementation of it), proving kCircleNameMaxLength actually reaches
    // the field the user types into, at both edges of the boundary.
    testWidgets('accepts a name exactly at kCircleNameMaxLength', (
      tester,
    ) async {
      await pumpPage(tester);
      final field = tester.widget<TextFormField>(
        find.byKey(WidgetKeys.circleNameInput),
      );
      expect(field.validator, isNotNull);
      expect(field.validator!('a' * kCircleNameMaxLength), isNull);
    });

    testWidgets('rejects a name one character past kCircleNameMaxLength', (
      tester,
    ) async {
      await pumpPage(tester);
      final field = tester.widget<TextFormField>(
        find.byKey(WidgetKeys.circleNameInput),
      );
      final l10n = AppLocalizations.of(
        tester.element(find.byType(NameCirclePage)),
      );
      expect(
        field.validator!('a' * (kCircleNameMaxLength + 1)),
        l10n.nameCircleNameTooLongError,
      );
    });
  });

  // ---------------------------------------------------------------------
  // Create flow: the snackbar must report what actually happened, not the
  // number of people the user selected to invite.
  // ---------------------------------------------------------------------
  group('NameCirclePage — create flow', () {
    testWidgets(
      'full delivery: snackbar names the circle and the total invited; pops '
      'past both create-flow routes',
      (tester) async {
        final mockCircle = MockCircleService()
          ..createCircleResult = CircleCreationResult(
            circle: TestCircleFactory.createCircle(displayName: 'Weekend Trip'),
            welcomesSent: 2,
            welcomesTotal: 2,
          );

        final observer = _PopCountingNavigatorObserver();
        final container = ProviderContainer(
          overrides: _overrides(mockCircle: mockCircle),
        );
        addTearDown(container.dispose);

        await tester.pumpWidget(
          _buildNavApp(
            container: container,
            observer: observer,
            memberKeyPackages: [_invitee('a'), _invitee('b')],
          ),
        );

        final l10n = await _createCircle(tester, name: 'Weekend Trip');

        expect(
          find.text(l10n.nameCircleCreatedSnack('Weekend Trip', 2)),
          findsOneWidget,
        );

        container.read(joinWatcherProvider.notifier).cancel();
        expect(
          observer.popCount,
          2,
          reason: 'must pop both create-flow routes',
        );
      },
    );

    testWidgets(
      'partial delivery: snackbar tells the truth (N of M delivered), never '
      'claims every invitation was sent',
      (tester) async {
        // 1 of 3 Welcomes actually reached a relay — the scenario from the
        // bug report: NostrCircleService confirms the circle as soon as ANY
        // Welcome lands, so failure of the other two is silent unless the
        // UI is told the real count.
        final mockCircle = MockCircleService()
          ..createCircleResult = CircleCreationResult(
            circle: TestCircleFactory.createCircle(displayName: 'Family'),
            welcomesSent: 1,
            welcomesTotal: 3,
          );

        final observer = _PopCountingNavigatorObserver();
        final container = ProviderContainer(
          overrides: _overrides(mockCircle: mockCircle),
        );
        addTearDown(container.dispose);

        await tester.pumpWidget(
          _buildNavApp(
            container: container,
            observer: observer,
            memberKeyPackages: [
              _invitee('a'),
              _invitee('b'),
              _invitee('c'),
            ],
          ),
        );

        final l10n = await _createCircle(tester, name: 'Family');

        // The truthful, partial-delivery message is shown — and it still leads
        // with the circle having been created, which is the outcome the user
        // came here for and which this screen pops away from immediately.
        expect(
          find.text(l10n.nameCircleCreatedPartialSnack('Family', 1, 3)),
          findsOneWidget,
        );
        // ...and the false "all 3 sent" claim must never appear.
        expect(
          find.text(l10n.nameCircleCreatedSnack('Family', 3)),
          findsNothing,
        );

        container.read(joinWatcherProvider.notifier).cancel();
      },
    );
  });
}
