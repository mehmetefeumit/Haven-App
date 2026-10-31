/// Widget tests for [NameCirclePage].
library;

import 'dart:async';
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
import 'package:haven/src/services/publish_stagger.dart'
    show kMaxCirclesPerAccount;
import 'package:haven/src/services/relay_service.dart';
import 'package:haven/src/test_keys.dart';
import 'package:haven/src/utils/bidi_isolate.dart';
import 'package:haven/src/utils/npub_validator.dart';
import 'package:haven/src/widgets/circles/missed_invitations_dialog.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../helpers/accessibility_announcements.dart';
import '../../helpers/log_capture.dart';
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
  nip65WriteRelays: const [],
);

/// Provider overrides shared by every "create flow" test.
///
/// [identityNotifier] replaces [_FakeIdentityNotifier] for the tests that
/// need the secret read itself to fail.
List<Override> _overrides({
  required MockCircleService mockCircle,
  IdentityNotifier Function()? identityNotifier,
}) {
  return [
    circleServiceProvider.overrideWithValue(mockCircle),
    identityServiceProvider.overrideWithValue(const _MockIdentityService()),
    identityProvider.overrideWith((_) async => _testIdentity),
    identityNotifierProvider.overrideWith(
      identityNotifier ?? _FakeIdentityNotifier.new,
    ),
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
  Locale? locale,
  TextScaler? textScaler,
}) {
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      builder: textScaler == null
          ? null
          : (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(textScaler: textScaler),
              child: child!,
            ),
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
  await tester.ensureVisible(find.byKey(WidgetKeys.createCircleConfirm));
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

  group('grapheme cap (kCircleNameMaxGraphemes)', () {
    // Rust silently truncates a stored circle name at
    // DISPLAY_NAME_MAX_GRAPHEMES (48 clusters); the field's own cap must be
    // tied to that same number, and counted the same way, or typing stops
    // somewhere the stored name does not.
    testWidgets(
      'the field caps input at kCircleNameMaxGraphemes, tighter than the '
      'looser kCircleNameMaxLength the validator still backstops',
      (tester) async {
        await pumpPage(tester);
        final field = tester.widget<TextField>(
          find.descendant(
            of: find.byKey(WidgetKeys.circleNameInput),
            matching: find.byType(TextField),
          ),
        );

        expect(field.maxLength, equals(kCircleNameMaxGraphemes));
        expect(kCircleNameMaxGraphemes, lessThan(kCircleNameMaxLength));
      },
    );

    testWidgets(
      'the cap counts grapheme clusters, not UTF-16 code units — typing '
      'past it stops on a whole cluster, never mid-cluster',
      (tester) async {
        await pumpPage(tester);

        // A flag emoji is ONE grapheme cluster (a regional-indicator pair)
        // but FOUR UTF-16 code units. A code-unit-based cap of 48 would cut
        // this string off inside a flag, corrupting it; a cluster-aware cap
        // (what Flutter's `maxLength` actually counts) stops on a whole one.
        const flag = '🇺🇸';
        final overCap = flag * (kCircleNameMaxGraphemes + 5);
        expect(overCap.length, greaterThan(kCircleNameMaxLength));

        await tester.enterText(
          find.byKey(WidgetKeys.circleNameInput),
          overCap,
        );
        await tester.pump();

        final committed = tester
            .widget<TextField>(
              find.descendant(
                of: find.byKey(WidgetKeys.circleNameInput),
                matching: find.byType(TextField),
              ),
            )
            .controller!
            .text;

        expect(committed.characters.length, equals(kCircleNameMaxGraphemes));
        expect(committed, equals(flag * kCircleNameMaxGraphemes));
      },
    );

    testWidgets(
      'a name at exactly the cap can still be submitted without a "too '
      'long" error',
      (tester) async {
        await pumpPage(tester);

        final atCap = 'a' * kCircleNameMaxGraphemes;
        await tester.enterText(find.byKey(WidgetKeys.circleNameInput), atCap);
        await tester.pump();

        final formState = tester.state<FormState>(find.byType(Form));
        expect(formState.validate(), isTrue);
      },
    );
  });

  testWidgets('opts the circle-name field out of IME personalized learning', (
    tester,
  ) async {
    await pumpPage(tester);

    // A circle name describes a social grouping the app otherwise never
    // renders at rest; the keyboard's learned-word dictionary is outside
    // Haven's storage, its logout wipe, and its threat model. Read from the
    // TextField the TextFormField builds, which is where the flag lands.
    final field = tester.widget<TextField>(
      find.descendant(
        of: find.byKey(WidgetKeys.circleNameInput),
        matching: find.byType(TextField),
      ),
    );
    expect(field.enableIMEPersonalizedLearning, isFalse);
  });

  testWidgets('offers the circle-name field to no platform autofill service', (
    tester,
  ) async {
    await pumpPage(tester);

    // A circle name is not something an autofill service holds, so the
    // feature buys the user nothing here while still handing it the current
    // editing value — an empty hint list is the framework default and does
    // NOT disable autofill.
    final field = tester.widget<TextField>(
      find.descendant(
        of: find.byKey(WidgetKeys.circleNameInput),
        matching: find.byType(TextField),
      ),
    );
    expect(field.autofillHints, isNull);
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
          find.text(l10n.nameCircleCreatedSnack(bidiIsolate('Weekend Trip'), 2)),
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
      'partial sending: snackbar tells the truth (N of M sent), never '
      'claims every invitation was sent',
      (tester) async {
        // 1 of 3 Welcomes actually reached a relay. The circle exists either
        // way, so the failure of the other two is silent unless the UI is told
        // the real count.
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

        final said = captureAccessibilityAnnouncements(tester);
        final l10n = await _createCircle(tester, name: 'Family');

        // A SnackBar is not a live region: the same words are spoken, with
        // the name raw (no isolate marks read aloud).
        expect(
          said,
          contains(l10n.nameCircleCreatedSentSoFarSnack('Family', 1, 3)),
        );

        // The truthful count is shown — and it still leads with the circle
        // having been created, which is the outcome the user came here for and
        // which this screen pops away from immediately.
        expect(
          find.text(
            l10n.nameCircleCreatedSentSoFarSnack(bidiIsolate('Family'), 1, 3),
          ),
          findsOneWidget,
        );
        // ...and the false "all 3 sent" claim must never appear.
        expect(
          find.text(l10n.nameCircleCreatedSnack(bidiIsolate('Family'), 3)),
          findsNothing,
        );
        // It carries the remedy, so it stays up long enough to read and can
        // be dismissed sooner.
        final snacks = tester.widgetList<SnackBar>(find.byType(SnackBar));
        expect(snacks, isNotEmpty);
        for (final snack in snacks) {
          expect(snack.persist, isTrue);
          expect(snack.action, isNotNull);
        }

        container.read(joinWatcherProvider.notifier).cancel();
      },
    );

    testWidgets(
      'partial sending to several people says the count and offers who was '
      'missed',
      (tester) async {
        const missedB = 'npub1bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
        const missedC = 'npub1cccccccccccccccccccccccccccccccccccccccccccccccccccccccccc';
        final mockCircle = MockCircleService()
          ..createCircleResult = CircleCreationResult(
            circle: TestCircleFactory.createCircle(displayName: 'Family'),
            welcomesSent: 1,
            welcomesTotal: 3,
            unsentNpubs: const [missedB, missedC],
          );
        final container = ProviderContainer(
          overrides: _overrides(mockCircle: mockCircle),
        );
        addTearDown(container.dispose);
        await tester.pumpWidget(
          _buildNavApp(
            container: container,
            observer: _PopCountingNavigatorObserver(),
            memberKeyPackages: [_invitee('a'), _invitee('b'), _invitee('c')],
          ),
        );

        final l10n = await _createCircle(tester, name: 'Family');

        expect(
          find.text(
            l10n.nameCircleCreatedSentSoFarSnack(bidiIsolate('Family'), 1, 3),
          ),
          findsOneWidget,
        );
        final snack = tester.widget<SnackBar>(find.byType(SnackBar).first);
        expect(snack.persist, isTrue);
        // Still there long after any timeout a snackbar could have had.
        await tester.pump(const Duration(minutes: 5));
        expect(
          find.descendant(
            of: find.byType(SnackBar),
            matching: find.widgetWithText(
              TextButton,
              l10n.missedInvitationsShowWho,
            ),
          ),
          findsOneWidget,
          reason: 'the member list does not mark who was missed, so the '
              'remedy is only doable if the snack can say who',
        );
        expect(snack.showCloseIcon, isTrue, reason: 'and it can be closed');

        await tester.tap(find.text(l10n.missedInvitationsShowWho));
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
        expect(find.byType(MissedInvitationsDialog), findsOneWidget);
        expect(
          find.descendant(
            of: find.byType(MissedInvitationsDialog),
            matching: find.text(
              l10n.nameCircleCreatedSentSoFarSnack(bidiIsolate('Family'), 1, 3),
            ),
          ),
          findsOneWidget,
          reason: 'the remedy goes with the list when the snackbar closes',
        );
        for (final npub in const [missedB, missedC]) {
          expect(
            find.text(bidiIsolate(NpubValidator.shortenForDisplay(npub))),
            findsOneWidget,
          );
        }

        container.read(joinWatcherProvider.notifier).cancel();
      },
    );

    testWidgets(
      'a missed list that is not everyone who was missed is not offered',
      (tester) async {
        final mockCircle = MockCircleService()
          ..createCircleResult = CircleCreationResult(
            circle: TestCircleFactory.createCircle(displayName: 'Family'),
            welcomesSent: 1,
            welcomesTotal: 3,
            unsentNpubs: const [
              'npub1bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
            ],
          );
        final container = ProviderContainer(
          overrides: _overrides(mockCircle: mockCircle),
        );
        addTearDown(container.dispose);
        await tester.pumpWidget(
          _buildNavApp(
            container: container,
            observer: _PopCountingNavigatorObserver(),
            memberKeyPackages: [_invitee('a'), _invitee('b'), _invitee('c')],
          ),
        );

        final l10n = await _createCircle(tester, name: 'Family');

        expect(
          find.text(l10n.missedInvitationsShowWho),
          findsNothing,
          reason: 'naming one of two people would read as naming everyone',
        );
        final snack = tester.widget<SnackBar>(find.byType(SnackBar).first);
        expect(snack.action?.label, l10n.commonDismiss);
        container.read(joinWatcherProvider.notifier).cancel();
      },
    );

    testWidgets(
      'at 200% text on a small phone in German, three missed people: nothing '
      'overflows, and Show who and every person can be reached',
      (tester) async {
        tester.view
          ..physicalSize = const Size(320, 568)
          ..devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final missed = [
          for (final c in ['b', 'c', 'd']) 'npub1${c * 52}qqqqqq',
        ];
        final mockCircle = MockCircleService()
          ..createCircleResult = CircleCreationResult(
            circle: TestCircleFactory.createCircle(displayName: 'Familie'),
            welcomesSent: 1,
            welcomesTotal: 4,
            unsentNpubs: missed,
          );
        final container = ProviderContainer(
          overrides: _overrides(mockCircle: mockCircle),
        );
        addTearDown(container.dispose);
        await tester.pumpWidget(
          _buildNavApp(
            container: container,
            observer: _PopCountingNavigatorObserver(),
            memberKeyPackages: [
              for (final c in ['a', 'b', 'c', 'd']) _invitee(c),
            ],
            locale: const Locale('de'),
            textScaler: const TextScaler.linear(2),
          ),
        );

        final l10n = await _createCircle(tester, name: 'Familie');
        await tester.pump(const Duration(seconds: 1));
        expect(tester.takeException(), isNull);

        final showWho = find.text(l10n.missedInvitationsShowWho);
        expect(showWho, findsOneWidget);
        expect(tester.getRect(showWho).bottom, lessThanOrEqualTo(568));
        // The remedy is taller than the screen here, so it scrolls to its end
        // rather than being clipped.
        final message = find.descendant(
          of: find.byType(SnackBar),
          matching: find.byType(Scrollable),
        );
        final position = tester.state<ScrollableState>(message).position;
        expect(position.maxScrollExtent, greaterThan(0), reason: 'precondition');
        await tester.drag(message, const Offset(0, -2000));
        await tester.pump();
        expect(position.pixels, position.maxScrollExtent);
        expect(tester.getRect(message).top, greaterThanOrEqualTo(0));
        await tester.tap(showWho);
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
        expect(tester.takeException(), isNull);

        for (final npub in missed) {
          final row = find.text(
            bidiIsolate(NpubValidator.shortenForDisplay(npub)),
          );
          await tester.ensureVisible(row);
          await tester.pump(const Duration(milliseconds: 300));
          final rect = tester.getRect(row);
          expect(rect.top, greaterThanOrEqualTo(0));
          expect(rect.bottom, lessThanOrEqualTo(568));
        }
        expect(tester.takeException(), isNull);
        container.read(joinWatcherProvider.notifier).cancel();
      },
    );

    testWidgets(
      'while the circle is being created there is no back arrow, and a back '
      'gesture hears why it waits',
      (tester) async {
        final gate = Completer<CircleCreationResult>();
        final container = ProviderContainer(
          overrides: _overrides(mockCircle: _GatedCreateCircleService(gate)),
        );
        addTearDown(container.dispose);
        await tester.pumpWidget(
          _buildNavApp(
            container: container,
            observer: _PopCountingNavigatorObserver(),
            memberKeyPackages: [_invitee('a')],
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('OpenName'));
        await tester.pumpAndSettle();
        expect(find.byType(BackButton), findsOneWidget, reason: 'precondition');
        final l10n = AppLocalizations.of(
          tester.element(find.byType(NameCirclePage)),
        );

        await tester.enterText(find.byKey(WidgetKeys.circleNameInput), 'Hold');
        await tester.tap(find.byKey(WidgetKeys.createCircleConfirm));
        for (var i = 0; i < 6; i++) {
          await tester.pump(Duration.zero);
        }
        expect(
          find.byType(BackButton),
          findsNothing,
          reason: 'an arrow that does nothing for up to a minute reads as broken',
        );

        tester.takeAnnouncements();
        await tester.state<NavigatorState>(find.byType(Navigator)).maybePop();
        await tester.pump();
        expect(
          tester.takeAnnouncements().map((a) => a.message),
          contains(
            l10n.nameCircleProgressSemantics(
              CreationStage.creatingGroup.label(l10n),
            ),
          ),
        );

        gate.complete(
          CircleCreationResult(
            circle: TestCircleFactory.createCircle(displayName: 'Hold'),
            welcomesSent: 1,
            welcomesTotal: 1,
          ),
        );
        for (var i = 0; i < 6; i++) {
          await tester.pump(Duration.zero);
        }
        container.read(joinWatcherProvider.notifier).cancel();
      },
    );

    testWidgets(
      'leaving while the circle is being created is held until it finishes',
      (tester) async {
        final gate = Completer<CircleCreationResult>();
        final mockCircle = _GatedCreateCircleService(gate);
        final observer = _PopCountingNavigatorObserver();
        final container = ProviderContainer(
          overrides: _overrides(mockCircle: mockCircle),
        );
        addTearDown(container.dispose);
        await tester.pumpWidget(
          _buildNavApp(
            container: container,
            observer: observer,
            memberKeyPackages: [_invitee('a')],
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('OpenName'));
        await tester.pumpAndSettle();
        final pops = observer.popCount;
        await tester.enterText(find.byKey(WidgetKeys.circleNameInput), 'Hold');
        await tester.tap(find.byKey(WidgetKeys.createCircleConfirm));
        for (var i = 0; i < 6; i++) {
          await tester.pump(Duration.zero);
        }

        final navigator = tester.state<NavigatorState>(find.byType(Navigator));
        await navigator.maybePop();
        await tester.pump();
        expect(
          find.byType(NameCirclePage),
          findsOneWidget,
          reason: 'the outcome would have nowhere left to be said',
        );
        expect(observer.popCount, pops);

        gate.complete(
          CircleCreationResult(
            circle: TestCircleFactory.createCircle(displayName: 'Hold'),
            welcomesSent: 1,
            welcomesTotal: 1,
          ),
        );
        for (var i = 0; i < 6; i++) {
          await tester.pump(Duration.zero);
        }
        container.read(joinWatcherProvider.notifier).cancel();
      },
    );

    testWidgets(
      'no invitation sent: the circle is still created, the snackbar says 0 '
      'of N, and the create flow unwinds',
      (tester) async {
        // A founded circle is canonical whatever reached a relay, so zero
        // acked Welcomes is a created circle with an honest count — never the
        // "failed to create" error, which would send the user to make a
        // duplicate.
        final mockCircle = MockCircleService()
          ..createCircleResult = CircleCreationResult(
            circle: TestCircleFactory.createCircle(displayName: 'Trip'),
            welcomesSent: 0,
            welcomesTotal: 2,
            unsentNpubs: const [
              'npub1aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
              'npub1bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
            ],
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

        final l10n = await _createCircle(tester, name: 'Trip');

        expect(
          find.text(
            l10n.nameCircleCreatedSentSoFarSnack(bidiIsolate('Trip'), 0, 2),
          ),
          findsOneWidget,
        );
        expect(find.text(l10n.nameCircleCreateError), findsNothing);
        expect(
          find.text(l10n.missedInvitationsShowWho),
          findsNothing,
          reason: '"0 of 2" already says it was everyone',
        );
        expect(
          observer.popCount,
          2,
          reason: 'the circle exists, so both create-flow routes pop',
        );

        container.read(joinWatcherProvider.notifier).cancel();
      },
    );

    testWidgets(
      'at the roster bound the refusal names the limit and the remedy, and '
      'the page stays put',
      (tester) async {
        // The service refuses before staging anything (see
        // `nostr_circle_service_roster_bound_test.dart`). What this pins is the
        // half the user sees: not the generic "please try again", which would
        // send them back to a button that can never succeed.
        final mockCircle = _RosterFullCircleService();

        final observer = _PopCountingNavigatorObserver();
        final container = ProviderContainer(
          overrides: _overrides(mockCircle: mockCircle),
        );
        addTearDown(container.dispose);

        await tester.pumpWidget(
          _buildNavApp(
            container: container,
            observer: observer,
            memberKeyPackages: [_invitee('a')],
          ),
        );

        final l10n = await _createCircle(tester, name: 'Eleventh');

        final refusal = l10n.nameCircleRosterFullError(kMaxCirclesPerAccount);
        expect(find.text(refusal), findsOneWidget);
        // The copy itself, not only the key. Comparing the rendered text with
        // the same getter that produced it passes for ANY wording, including a
        // rewrite to "Something went wrong, please try again" — which is the
        // one thing this screen must never say here. English only: this test
        // pumps the default `en` locale; the other twelve are held by
        // `test/l10n/roster_bound_copy_accuracy_test.dart`.
        expect(
          refusal,
          contains('$kMaxCirclesPerAccount'),
          reason: 'the user cannot act on a limit they are not told',
        );
        expect(
          refusal,
          matches(
            RegExp(
              'up to|at most|a maximum of|no more than|only',
              caseSensitive: false,
            ),
          ),
          reason: 'the ceiling must be MARKED: a bare positive ("you can be '
              'in 10 circles") reads as capability, and eleven of the twelve '
              'locales had to add a limiter to the unmarked wording',
        );
        expect(
          refusal,
          matches(RegExp(r'\bleave\b', caseSensitive: false)),
          reason: 'the remedy is leaving a circle; without it the refusal is a '
              'dead end',
        );
        expect(
          refusal.toLowerCase(),
          isNot(contains('try again')),
          reason: 'retrying at the bound can never succeed',
        );
        expect(
          find.text(l10n.nameCircleCreateError),
          findsNothing,
          reason: 'a retry prompt for something that can never succeed',
        );
        // Security Rule 8: no exception text, however harmless, reaches the
        // screen — the refusal is copy, not a rendered error.
        expect(
          find.textContaining('Exception', findRichText: true),
          findsNothing,
        );
        expect(
          observer.popCount,
          0,
          reason: 'nothing was created, so the create flow must not unwind',
        );
      },
    );
  });

  // ---------------------------------------------------------------------
  // Every refusal must be AUDIBLE, not merely visible (WCAG 2.1 SC 4.1.3).
  // The setState that sets `_errorMessage` also clears `_isCreating`, so
  // `_buildProgress` — the page's only other live region — is gone by the
  // time the message renders. The error's own node is therefore the only
  // thing that can carry the announcement.
  // ---------------------------------------------------------------------
  group('NameCirclePage — a refusal is announced, not merely shown', () {
    Future<AppLocalizations> pumpFailedCreate(
      WidgetTester tester, {
      required MockCircleService mockCircle,
      IdentityNotifier Function()? identityNotifier,
    }) async {
      final container = ProviderContainer(
        overrides: _overrides(
          mockCircle: mockCircle,
          identityNotifier: identityNotifier,
        ),
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(
        _buildNavApp(
          container: container,
          observer: _PopCountingNavigatorObserver(),
          memberKeyPackages: [_invitee('a')],
        ),
      );
      return _createCircle(tester, name: 'Announce me');
    }

    void expectAnnounced(WidgetTester tester, String message) {
      expect(find.text(message), findsOneWidget);
      final node = tester.getSemantics(find.text(message));
      expect(
        node.label,
        message,
        reason: 'the live region must carry the refusal itself — a container '
            'node with no label announces nothing',
      );
      expect(
        node.flagsCollection.isLiveRegion,
        isTrue,
        reason: 'without isLiveRegion on the node that carries the message, '
            'TalkBack and VoiceOver stay silent when it appears, and the '
            'progress live region that used to be on screen has just been '
            'removed by the same setState',
      );
    }

    testWidgets('an invitee no invitation can reach gets its own copy as a '
        'live region, never the generic error', (tester) async {
      final handle = tester.ensureSemantics();
      final capture = LogCapture.install();
      final l10n = await pumpFailedCreate(
        tester,
        mockCircle: _UnreachableInviteeCircleService(),
      );
      expectAnnounced(tester, l10n.memberCannotReceiveInvitations);
      expect(find.text(l10n.nameCircleCreateError), findsNothing);
      capture
        ..restore()
        ..assertContains('[CircleCreate] invitee unreachable')
        ..assertNoNeedles(['Announce me']);
      handle.dispose();
    });

    testWidgets('a pool the own relay lists cover gets its own fixed copy as '
        'a live region, never the generic error or the raw one', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      final capture = LogCapture.install();
      final l10n = await pumpFailedCreate(
        tester,
        mockCircle: _NoLocationRelayCircleService(),
      );
      expectAnnounced(tester, l10n.circleCreateRefusedNoLocationRelay);
      expect(find.text(l10n.nameCircleCreateError), findsNothing);
      expect(
        find.textContaining(
          const CircleNoLocationRelayException().message,
        ),
        findsNothing,
        reason: 'Rule 8: the exception text never reaches the screen',
      );
      capture
        ..restore()
        ..assertContains('[CircleCreate] no location relay')
        ..assertNoNeedles(['Announce me']);
      handle.dispose();
    });

    testWidgets('the roster-bound refusal is a live region', (tester) async {
      // Disposed explicitly, not via addTearDown: the end-of-test
      // semantics-handle verification runs before tearDowns.
      final handle = tester.ensureSemantics();

      final l10n = await pumpFailedCreate(
        tester,
        mockCircle: _RosterFullCircleService(),
      );
      final refusal = l10n.nameCircleRosterFullError(kMaxCirclesPerAccount);
      expectAnnounced(tester, refusal);

      // The progress live region is NOT what speaks: it left the tree with
      // `_isCreating`. Pinned so moving the announcement back under
      // `_buildProgress` cannot pass.
      expect(
        find.byType(LinearProgressIndicator),
        findsNothing,
        reason: '_buildProgress is gone, so it cannot be the announcer',
      );

      // A second attempt at the same dead end must speak again. The message
      // is cleared before each retry, so this is a fresh insertion rather
      // than a rebuild with an unchanged label — the case a live region
      // announces reliably on both platforms.
      await tester.tap(find.byKey(WidgetKeys.createCircleConfirm));
      for (var i = 0; i < 6; i++) {
        await tester.pump(Duration.zero);
      }
      expectAnnounced(tester, refusal);
      handle.dispose();
    });

    testWidgets('the generic create failure is a live region', (tester) async {
      final handle = tester.ensureSemantics();

      final l10n = await pumpFailedCreate(
        tester,
        mockCircle: _FailingCircleService(),
      );
      expectAnnounced(tester, l10n.nameCircleCreateError);
      handle.dispose();
    });

    testWidgets('the identity failure is a live region', (tester) async {
      final handle = tester.ensureSemantics();

      final l10n = await pumpFailedCreate(
        tester,
        mockCircle: MockCircleService(),
        identityNotifier: _FailingIdentityNotifier.new,
      );
      expectAnnounced(tester, l10n.nameCircleIdentityError);
      handle.dispose();
    });
  });
}

/// A circle service at the account roster bound: every create is refused.
class _RosterFullCircleService extends MockCircleService {
  @override
  Future<CircleCreationResult> createCircle({
    required List<int> identitySecretBytes,
    required List<KeyPackageData> memberKeyPackages,
    required String name,
    required CircleType circleType,
    String? description,
    List<String>? relays,
  }) async {
    methodCalls.add('createCircle');
    throw const CircleRosterFullException();
  }
}

/// A circle service whose create the core refuses: an invitee lists no inbox
/// relay a Welcome could reach.
class _UnreachableInviteeCircleService extends MockCircleService {
  @override
  Future<CircleCreationResult> createCircle({
    required List<int> identitySecretBytes,
    required List<KeyPackageData> memberKeyPackages,
    required String name,
    required CircleType circleType,
    String? description,
    List<String>? relays,
  }) async {
    methodCalls.add('createCircle');
    throw const CircleInviteesUnreachableException();
  }
}

/// A circle service whose create the core refuses: the user's own relay lists
/// cover every relay a new circle may use.
class _NoLocationRelayCircleService extends MockCircleService {
  @override
  Future<CircleCreationResult> createCircle({
    required List<int> identitySecretBytes,
    required List<KeyPackageData> memberKeyPackages,
    required String name,
    required CircleType circleType,
    String? description,
    List<String>? relays,
  }) async {
    methodCalls.add('createCircle');
    throw const CircleNoLocationRelayException();
  }
}

/// A circle service whose create fails for a reason a retry might fix — the
/// page's generic `CircleServiceException` branch.
class _FailingCircleService extends MockCircleService {
  @override
  Future<CircleCreationResult> createCircle({
    required List<int> identitySecretBytes,
    required List<KeyPackageData> memberKeyPackages,
    required String name,
    required CircleType circleType,
    String? description,
    List<String>? relays,
  }) async {
    methodCalls.add('createCircle');
    throw const CircleServiceException('relay unreachable');
  }
}

/// An [IdentityNotifier] whose secret read fails — the page's
/// `IdentityServiceException` branch, reached before the service is called.
class _FailingIdentityNotifier extends IdentityNotifier {
  @override
  Future<Identity?> build() async => _testIdentity;

  @override
  Future<List<int>> getSecretBytes() async =>
      throw const IdentityServiceException('secret unavailable');
}

/// A circle service whose create finishes only when the test says.
class _GatedCreateCircleService extends MockCircleService {
  _GatedCreateCircleService(this.gate);

  final Completer<CircleCreationResult> gate;

  @override
  Future<CircleCreationResult> createCircle({
    required List<int> identitySecretBytes,
    required List<KeyPackageData> memberKeyPackages,
    required String name,
    required CircleType circleType,
    String? description,
    List<String>? relays,
  }) {
    methodCalls.add('createCircle');
    return gate.future;
  }
}
