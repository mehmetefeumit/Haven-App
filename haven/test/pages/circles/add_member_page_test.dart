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
import 'package:flutter/rendering.dart';
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
import 'package:haven/src/providers/sharing_health_provider.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/services/identity_service.dart';
import 'package:haven/src/services/member_directory_service.dart';
import 'package:haven/src/services/profile_service.dart';
import 'package:haven/src/test_keys.dart';
import 'package:haven/src/theme/theme.dart';
import 'package:haven/src/utils/npub_validator.dart';
import 'package:haven/src/widgets/circles/circle_member_tile.dart';
import 'package:haven/src/widgets/circles/member_picker.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../helpers/accessibility_announcements.dart';
import '../../helpers/localized_app_harness.dart';
import '../../helpers/log_capture.dart';
import '../../mocks/mock_circle_service.dart';
import '../../mocks/mock_member_directory_service.dart';
import '../../mocks/mock_profile_service.dart';
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

/// The hex pubkey already present in the test circle's member list — and
/// the local user's own, since the viewer is that circle's admin.
const _existingMemberHex = kTestPubkeyHex;

/// The npub half of [_existingMemberHex]. Both halves come from the same
/// place: the entry check compares npubs and the row check compares hex, so
/// an unrelated pair would make one of them silently untestable.
const _existingMemberNpub = kTestNpub;

const _aliceHex =
    'a11ce0000000000000000000000000000000000000000000000000000000cafe';
const _aliceNpub =
    'npub15ywwqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqetlqhgm683';

// ---------------------------------------------------------------------------
// Test helpers
// ---------------------------------------------------------------------------

/// The test identity (self = admin of the circle).
final _testIdentity = Identity(
  pubkeyHex: _existingMemberHex,
  npub: _existingMemberNpub,
  createdAt: DateTime(2024),
);

/// A directory holding one named co-member from ANOTHER circle, folded with a
/// plain lower-case because `RustLib` is not initialised in a `flutter test`
/// process.
MemberDirectory _aliceDirectory() {
  return buildDirectory(
    entries: const [
      DirectoryEntry(
        pubkeyHex: _aliceHex,
        npub: _aliceNpub,
        tier: DirectoryTier.current,
      ),
    ],
    profiles: const {
      _aliceHex: Profile(pubkeyHex: _aliceHex, displayName: 'Alice Aardvark'),
      _existingMemberHex: Profile(
        pubkeyHex: _existingMemberHex,
        displayName: 'Existing Member',
      ),
    },
    fold: (value) => value.toLowerCase(),
  );
}

/// Builds a [KeyPackageData] whose `eventJson` carries [pubkeyHex] under the
/// current (Dark Matter, kind 30443) KeyPackage kind.
KeyPackageData _makeKp(String pubkeyHex) => KeyPackageData(
  pubkey: 'npub1newmember',
  eventJson: jsonEncode({'kind': 30443, 'pubkey': pubkeyHex}),
  relays: const ['wss://relay.example.com'],
  nip65WriteRelays: const [],
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
  MemberDirectory? directory,
}) {
  return [
    relayServiceProvider.overrideWithValue(mockRelay),
    memberDirectoryServiceProvider.overrideWithValue(
      MockMemberDirectoryService(directory: directory),
    ),
    profileServiceProvider.overrideWithValue(MockProfileService()),
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
  MemberDirectory? directory,
}) {
  return ProviderScope(
    overrides: _overrides(
      mockRelay: mockRelay,
      mockCircle: mockCircle,
      directory: directory,
    ),
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

      // Empty-state content. The MemberSearchField also shows a userPlus prefix
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
        expect(find.text("Couldn't find a Haven account for this ID"), findsOneWidget);

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
            delivery: ChangeDelivery.applied,
            welcomesDelivered: 1,
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

        // The package was chosen for THIS circle, not for a new one.
        expect(mockRelay.fetchKeyPackageTargets, [circle.mlsGroupId]);

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
        // Isolated, so a right-to-left circle name cannot reorder it.
        expect(
          find.text('Invitation sent to \u2068Test Circle\u2069'),
          findsOneWidget,
        );

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
      '6. a re-invite owed: the snack and a screen reader name the circle '
      'and the one remedy, and promise no later delivery',
      (tester) async {
        final announcements = captureAccessibilityAnnouncements(tester);
        // Before: any Welcome no relay acked in the call. Now the driver sends
        // a Welcome again until a relay takes it; the remedy is offered only
        // when the invite was applied with no Welcome left to deliver.
        final mockRelay = MockRelayService(
          keyPackageResult: _makeKp(_newMemberHex),
        );
        final mockCircle = MockCircleService()
          ..addMemberResult = const AddMemberResult(
            delivery: ChangeDelivery.applied,
            welcomesDelivered: 0,
            welcomesTotal: 1,
            reinviteOwed: true,
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

        final l10n = AppLocalizations.of(tester.element(find.text('Open')));
        expect(
          find.text(l10n.addMemberReinviteNeeded('\u2068Test Circle\u2069')),
          findsOneWidget,
          reason: 'it names the circle, and offers the one remedy that works',
        );
        expect(
          announcements,
          contains(l10n.addMemberReinviteNeeded('Test Circle')),
          reason: 'a SnackBar is not a live region; spoken without isolates',
        );
        expect(
          find.textContaining(RegExp('pending|later', caseSensitive: false)),
          findsNothing,
          reason: 'no invitation is left to send, so the copy must not say so',
        );
        // The messenger may hold the same snackbar for more than one
        // scaffold while the page pops; every copy must be the long one.
        final snacks = tester.widgetList<SnackBar>(find.byType(SnackBar));
        expect(snacks, isNotEmpty);
        for (final snack in snacks) {
          expect(
            snack.persist,
            isTrue,
            reason: 'a remedy stays up until it is read',
          );
          expect(snack.action, isNotNull, reason: 'and can be dismissed');
        }

        // Cancel the watcher so no pending timers survive after test disposal.
        container.read(joinWatcherProvider.notifier).cancel();
      },
    );

    testWidgets(
      '6b. Welcomes the driver is still sending: the snack says how many '
      'were sent so far and that the rest are sent again, a screen reader '
      'hears it, and the page hands back a partial outcome',
      (tester) async {
        // The rest are sent again by the driver, while the app is open, for
        // up to a day: "sent so far", never "sent", and no re-invite asked.
        final announcements = captureAccessibilityAnnouncements(tester);
        final results = <AddMemberPageResult?>[];
        final mockCircle = MockCircleService()
          ..addMemberResult = const AddMemberResult(
            delivery: ChangeDelivery.applied,
            welcomesDelivered: 1,
            welcomesTotal: 3,
          );
        final observer = _RecordingNavigatorObserver();
        final container = ProviderContainer(
          overrides: _overrides(
            mockRelay: MockRelayService(
              keyPackageResult: _makeKp(_newMemberHex),
            ),
            mockCircle: mockCircle,
          ),
        );
        addTearDown(container.dispose);
        await _openAddMemberPage(
          tester,
          container,
          observer: observer,
          results: results,
        );
        await _addMember(tester, _newMemberNpub);
        await tester.pumpAndSettle();
        observer.reset();

        await tester.tap(find.byKey(WidgetKeys.addMemberConfirm));
        await tester.pump();
        await tester.pump(Duration.zero);
        await tester.pump(Duration.zero);

        final l10n = AppLocalizations.of(tester.element(find.text('Open')));
        expect(
          find.text(l10n.addMemberSentSoFar(1, 3, '\u2068Test Circle\u2069')),
          findsOneWidget,
        );
        expect(
          announcements,
          contains(l10n.addMemberSentSoFar(1, 3, 'Test Circle')),
        );
        expect(
          find.textContaining(
            RegExp('remove (them|that person)', caseSensitive: false),
          ),
          findsNothing,
          reason: 'the rest are still being sent: no re-invite is owed yet',
        );
        expect(observer.popped, isTrue);
        expect(results, [AddMemberPageResult.partial]);
        container.read(joinWatcherProvider.notifier).cancel();
      },
    );

    testWidgets(
      "6d. awaiting relays is no error: no snack, the circle's deferred-send "
      'cause is recorded and the page pops',
      (tester) async {
        final health = _RecordingHealth();
        final results = <AddMemberPageResult?>[];
        final mockCircle = MockCircleService()
          ..addMemberResult = const AddMemberResult(
            delivery: ChangeDelivery.awaitingRelays,
            welcomesDelivered: 0,
            welcomesTotal: 1,
          );
        final observer = _RecordingNavigatorObserver();
        final container = ProviderContainer(
          overrides: [
            ..._overrides(
              mockRelay: MockRelayService(
                keyPackageResult: _makeKp(_newMemberHex),
              ),
              mockCircle: mockCircle,
            ),
            sharingHealthProvider.overrideWith(() => health),
          ],
        );
        addTearDown(container.dispose);
        await _openAddMemberPage(
          tester,
          container,
          observer: observer,
          results: results,
        );
        await _addMember(tester, _newMemberNpub);
        await tester.pumpAndSettle();
        observer.reset();

        await tester.tap(find.byKey(WidgetKeys.addMemberConfirm));
        await tester.pump();
        await tester.pump(Duration.zero);
        await tester.pump(Duration.zero);

        expect(
          find.text('Failed to add member. Please try again.'),
          findsNothing,
          reason: 'awaiting relays was shown as an error',
        );
        expect(find.byType(SnackBar), findsNothing);
        expect(health.deferred, [sharingCircleKey(_makeCircle())]);
        expect(health.byUser, [true], reason: "the user's own action");
        expect(observer.popped, isTrue);
        expect(
          results,
          [AddMemberPageResult.awaiting],
          reason: 'so Circle details stays open, where its card says the rest',
        );
        expect(container.read(joinWatcherProvider).mode, JoinWatchMode.idle);
      },
    );

    testWidgets(
      '6f. an invitee no invitation can reach gets its own copy, never the '
      'generic error, and the page stays',
      (tester) async {
        final capture = LogCapture.install();
        final observer = _RecordingNavigatorObserver();
        final container = ProviderContainer(
          overrides: _overrides(
            mockRelay: MockRelayService(
              keyPackageResult: _makeKp(_newMemberHex),
            ),
            mockCircle: _UnreachableInviteeService(),
          ),
        );
        addTearDown(container.dispose);
        await _openAddMemberPage(tester, container, observer: observer);
        await _addMember(tester, _newMemberNpub);
        await tester.pumpAndSettle();
        observer.reset();

        await tester.tap(find.byKey(WidgetKeys.addMemberConfirm));
        await tester.pump();
        await tester.pump(Duration.zero);

        final l10n = AppLocalizations.of(
          tester.element(find.byType(AddMemberPage)),
        );
        expect(find.text(l10n.memberCannotReceiveInvitations), findsOneWidget);
        expect(find.text(l10n.addMemberError), findsNothing);
        expect(observer.popped, isFalse);
        // Restored inside the body: a widget test checks its debug variables
        // before tear-downs run.
        capture
          ..restore()
          ..assertContains('[AddMember] Invitee unreachable')
          ..assertNoNeedles([_newMemberNpub, _newMemberHex, 'Test Circle']);
      },
    );

    testWidgets(
      '6e. a change not made shows the error and keeps the page',
      (tester) async {
        final mockCircle = MockCircleService()
          ..addMemberResult = const AddMemberResult(
            delivery: ChangeDelivery.rejected,
            welcomesDelivered: 0,
            welcomesTotal: 1,
          );
        final observer = _RecordingNavigatorObserver();
        final container = ProviderContainer(
          overrides: _overrides(
            mockRelay: MockRelayService(
              keyPackageResult: _makeKp(_newMemberHex),
            ),
            mockCircle: mockCircle,
          ),
        );
        addTearDown(container.dispose);
        await _openAddMemberPage(tester, container, observer: observer);
        await _addMember(tester, _newMemberNpub);
        await tester.pumpAndSettle();
        observer.reset();

        await tester.tap(find.byKey(WidgetKeys.addMemberConfirm));
        await tester.pumpAndSettle();

        expect(
          find.text('Failed to add member. Please try again.'),
          findsOneWidget,
        );
        expect(observer.popped, isFalse);
        expect(container.read(joinWatcherProvider).mode, JoinWatchMode.idle);
      },
    );

    testWidgets(
      '6c. leaving the page while the invitations go out still reports them',
      (tester) async {
        final gate = Completer<AddMemberResult>();
        final mockCircle = _GatedAddMemberService(gate);
        final container = ProviderContainer(
          overrides: _overrides(
            mockRelay: MockRelayService(
              keyPackageResult: _makeKp(_newMemberHex),
            ),
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
              home: Scaffold(
                body: Builder(
                  builder: (ctx) => ElevatedButton(
                    onPressed: () => Navigator.of(ctx).push(
                      MaterialPageRoute<void>(
                        builder: (_) => AddMemberPage(circle: _makeCircle()),
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
        final l10n = AppLocalizations.of(
          tester.element(find.byType(AddMemberPage)),
        );
        await _addMember(tester, _newMemberNpub);
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(WidgetKeys.addMemberConfirm));
        await tester.pump();

        await tester.state<NavigatorState>(find.byType(Navigator)).maybePop();
        await tester.pumpAndSettle();
        expect(find.byType(AddMemberPage), findsNothing, reason: 'precondition');

        gate.complete(
          const AddMemberResult(
            delivery: ChangeDelivery.applied,
            welcomesDelivered: 0,
            welcomesTotal: 1,
            reinviteOwed: true,
          ),
        );
        await tester.pump();
        await tester.pump(Duration.zero);

        expect(
          find.text(l10n.addMemberReinviteNeeded('\u2068Test Circle\u2069')),
          findsOneWidget,
          reason: 'the remedy has to reach the user wherever they went',
        );
        expect(
          container.read(joinWatcherProvider).mode,
          JoinWatchMode.adminWaitingForJoin,
          reason: 'the new member is still watched for',
        );
        expect(tester.takeException(), isNull);
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
          find.textContaining("Once they accept, they will see everyone's location"),
          findsOneWidget,
        );
        // ...but the green security badge's lock icon is gone.
        expect(find.byIcon(LucideIcons.lock), findsNothing);
      },
    );
  });

  // -------------------------------------------------------------------------
  // Layout robustness
  //
  // This page puts its empty state in an `Expanded` between a search field and
  // ~230px of pinned chrome (the sharing disclosure plus the CTA), so the
  // placeholder's height is leftover space. Focusing the search field opens
  // the software keyboard, `Scaffold.resizeToAvoidBottomInset` removes its
  // inset from the body, and the leftover drops to about 110px against ~116px
  // of content — which is how CI run 31462924650 produced
  // `A RenderFlex overflowed by 7.8 pixels on the bottom` on an iPhone 15.
  //
  // These tests pump the real shipped theme. The suite's other tests use
  // `ThemeData(useMaterial3: false)`, whose text metrics are not the ones the
  // app renders, so they cannot measure this.
  // -------------------------------------------------------------------------
  group('AddMemberPage — KeyPackage admission (MDK v0.10.4)', () {
    Future<MockCircleService> stage(
      WidgetTester tester,
      KeyPackageAdmission admission,
    ) async {
      final mockCircle = MockCircleService()..keyPackageAdmission = admission;
      await tester.pumpWidget(
        _buildApp(
          circle: _makeCircle(),
          mockRelay: MockRelayService(keyPackageResult: _makeKp(_newMemberHex)),
          mockCircle: mockCircle,
        ),
      );
      await tester.pumpAndSettle();
      await _addMember(tester, _newMemberNpub);
      await tester.pumpAndSettle();
      expect(mockCircle.methodCalls, contains('checkMemberKeyPackage'));
      return mockCircle;
    }

    AppLocalizations l10n(WidgetTester tester) =>
        AppLocalizations.of(tester.element(find.byType(AddMemberPage)));

    testWidgets('a peer on a pre-migration build needs to update, and '
        'confirm stays disabled', (tester) async {
      await stage(tester, KeyPackageAdmission.needsUpdate);

      expect(find.text(l10n(tester).pendingMemberNeedsUpdate), findsOneWidget);
      expect(
        find.byIcon(LucideIcons.refreshCw),
        findsOneWidget,
        reason: 'opening Haven publishes a current package, so a retry can '
            'succeed',
      );
      final button = tester.widget<FilledButton>(
        find.byKey(WidgetKeys.addMemberConfirm),
      );
      expect(button.onPressed, isNull);
    });

    testWidgets('once the peer has updated, Retry makes them ready to invite', (
      tester,
    ) async {
      final mockCircle = await stage(tester, KeyPackageAdmission.needsUpdate);
      mockCircle.keyPackageAdmission = KeyPackageAdmission.admissible;

      await tester.tap(find.byIcon(LucideIcons.refreshCw));
      await tester.pumpAndSettle();

      expect(find.text(l10n(tester).pendingMemberReadyToInvite), findsOneWidget);
      expect(find.text(l10n(tester).pendingMemberNeedsUpdate), findsNothing);
      final button = tester.widget<FilledButton>(
        find.byKey(WidgetKeys.addMemberConfirm),
      );
      expect(button.onPressed, isNotNull);
    });

    testWidgets('a screen reader hears that the peer needs to update once', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      await stage(tester, KeyPackageAdmission.needsUpdate);
      final sentence = l10n(tester).pendingMemberNeedsUpdate;
      final labels = find.semantics
          .byPredicate((_) => true)
          .evaluate()
          .map((node) => node.getSemanticsData().label);
      expect(
        sentence.allMatches(labels.join('\n')).length,
        1,
        reason: 'the icon must not repeat the subtitle',
      );
      semantics.dispose();
    });

    testWidgets('a KeyPackage the engine would refuse offers a retry, and '
        'confirm stays disabled', (tester) async {
      await stage(tester, KeyPackageAdmission.unusable);

      expect(find.text(l10n(tester).memberKeyPackageStale), findsOneWidget);
      expect(find.byIcon(LucideIcons.refreshCw), findsOneWidget);
      final button = tester.widget<FilledButton>(
        find.byKey(WidgetKeys.addMemberConfirm),
      );
      expect(button.onPressed, isNull);
    });
  });

  group('AddMemberPage — layout under a squeeze', () {
    /// Lays the page out on an iPhone 15 with the keyboard up.
    Future<void> pumpSqueezed(
      WidgetTester tester, {
      TextScaler textScaler = TextScaler.noScaling,
      Locale locale = const Locale('en'),
      double bottomInset = 336,
      KeyPackageData? keyPackage,
    }) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(393, 852);
      tester.view.viewInsets = FakeViewPadding(bottom: bottomInset);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetViewInsets);

      await tester.pumpWidget(
        ProviderScope(
          overrides: _overrides(
            mockRelay: MockRelayService(keyPackageResult: keyPackage),
            mockCircle: MockCircleService(),
          ),
          child: MaterialApp(
            locale: locale,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            theme: HavenTheme.light(),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(textScaler: textScaler),
              child: child!,
            ),
            home: AddMemberPage(circle: _makeCircle()),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('L1. the empty state survives the keyboard', (tester) async {
      await pumpSqueezed(tester);

      expect(tester.takeException(), isNull);
    });

    testWidgets('L2. survives 2x in a long locale with no keyboard', (
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

    testWidgets('L3. survives the keyboard at 2x in a long locale', (
      tester,
    ) async {
      await pumpSqueezed(
        tester,
        textScaler: const TextScaler.linear(2),
        locale: const Locale('de'),
      );

      expect(tester.takeException(), isNull);
    });

    // The branch this restructure actually wrote: once a member exists the
    // body is a CustomScrollView (SliverList + the disclosure as a trailing
    // adapter) rather than the HavenScrollFill used when empty. Nothing else
    // in this suite lays that branch out under a squeeze.
    testWidgets('L5. the populated roster branch survives the keyboard at 2x', (
      tester,
    ) async {
      await pumpSqueezed(
        tester,
        textScaler: const TextScaler.linear(2),
        locale: const Locale('de'),
        keyPackage: _makeKp(_newMemberHex),
      );
      await _addMember(tester, _newMemberNpub);
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      // The roster header only renders once a member is selected, and unlike
      // the tile it is not a lazily-built sliver child — so it is the finder
      // that proves the populated branch is what just laid out.
      expect(find.byType(TextButton), findsOneWidget);
    });

    testWidgets('L6. the sharing disclosure stays reachable with a roster', (
      tester,
    ) async {
      await pumpSqueezed(
        tester,
        textScaler: const TextScaler.linear(2),
        keyPackage: _makeKp(_newMemberHex),
      );
      await _addMember(tester, _newMemberNpub);
      await tester.pumpAndSettle();

      // The disclosure is no longer pinned above the CTA, so "it is in the
      // tree" is not the promise — "the user can get to it" is. It now trails
      // a lazily-built SliverList, so it may not be built yet;
      // `scrollUntilVisible` fails outright if no amount of scrolling brings
      // it on screen, which is the clipped-vs-reachable distinction.
      final l10n = l10nOf(tester, AddMemberPage);
      await tester.scrollUntilVisible(
        find.text(l10n.addMemberInfo),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();

      expect(find.text(l10n.addMemberInfo), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('L4. the empty-state guidance stays reachable', (tester) async {
      await pumpSqueezed(tester, textScaler: const TextScaler.linear(2));

      expect(tester.takeException(), isNull);

      // `ensureVisible` needs a Scrollable ancestor, so this fails outright if
      // the placeholder ever loses its scroll parent — the difference between
      // guidance that is scrolled to and guidance that is clipped away.
      final l10n = l10nOf(tester, AddMemberPage);
      await tester.ensureVisible(find.text(l10n.createCircleEmptyTitle));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });
  });

  // -------------------------------------------------------------------------
  // The picker: people you already share a circle with (R2/R4)
  // -------------------------------------------------------------------------
  group('AddMemberPage — the picker', () {
    testWidgets('A1. offers co-members by name and key, with no relay call', (
      tester,
    ) async {
      final mockRelay = MockRelayService();
      await tester.pumpWidget(
        _buildApp(
          circle: _makeCircle(),
          mockRelay: mockRelay,
          mockCircle: MockCircleService(),
          directory: _aliceDirectory(),
        ),
      );
      await tester.pumpAndSettle();

      final l10n = l10nOf(tester, AddMemberPage);
      expect(find.text(l10n.memberPickerSectionRoster), findsOneWidget);
      expect(find.byType(MemberCandidateTile), findsOneWidget);
      expect(find.text('Alice Aardvark'), findsOneWidget);
      expect(
        find.text(NpubValidator.shortenForDisplay(_aliceNpub)),
        findsOneWidget,
      );
      expect(mockRelay.methodCalls, isEmpty);
    });

    testWidgets('A2. tapping a row stages that person', (tester) async {
      await tester.pumpWidget(
        _buildApp(
          circle: _makeCircle(),
          mockRelay: MockRelayService(keyPackageResult: _makeKp(_newMemberHex)),
          mockCircle: MockCircleService(),
          directory: _aliceDirectory(),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Alice Aardvark'));
      await tester.pumpAndSettle();

      expect(
        tester.widget<PendingMemberTile>(find.byType(PendingMemberTile)).npub,
        _aliceNpub,
      );
      expect(
        tester
            .widget<FilledButton>(find.byKey(WidgetKeys.addMemberConfirm))
            .onPressed,
        isNotNull,
      );
    });

    testWidgets('A3. someone already in THIS circle is shown, disabled, with '
        'that reason — not hidden', (tester) async {
      // Hiding them would empty the list for a user whose only circle is the
      // one being added to, and would hide the very person being searched for.
      final mockRelay = MockRelayService();
      await tester.pumpWidget(
        _buildApp(
          circle: _makeCircle(
            members: [
              TestCircleFactory.createMember(
                pubkey: _existingMemberHex,
                npub: _existingMemberNpub,
                isAdmin: true,
              ),
              TestCircleFactory.createMember(
                pubkey: _aliceHex,
                npub: _aliceNpub,
              ),
            ],
          ),
          mockRelay: mockRelay,
          mockCircle: MockCircleService(),
          directory: _aliceDirectory(),
        ),
      );
      await tester.pumpAndSettle();

      final l10n = l10nOf(tester, AddMemberPage);
      expect(find.text('Alice Aardvark'), findsOneWidget);
      expect(find.text(l10n.addMemberAlreadyInCircle), findsOneWidget);
      expect(find.text(l10n.memberSearchAlreadyAdded), findsNothing);

      await tester.tap(find.text('Alice Aardvark'));
      await tester.pumpAndSettle();
      expect(find.byType(PendingMemberTile), findsNothing);
      expect(mockRelay.methodCalls, isEmpty);
    });

    testWidgets('A4. typing filters the offered people in the same frame', (
      tester,
    ) async {
      await tester.pumpWidget(
        _buildApp(
          circle: _makeCircle(),
          mockRelay: MockRelayService(),
          mockCircle: MockCircleService(),
          directory: _aliceDirectory(),
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'zzz');
      await tester.pump();
      expect(find.text('Alice Aardvark'), findsNothing);

      await tester.enterText(find.byType(TextField), 'aardvark');
      await tester.pump();
      expect(find.text('Alice Aardvark'), findsOneWidget);
    });

    testWidgets('A5. with no shared circles yet, the guidance still stands', (
      tester,
    ) async {
      await tester.pumpWidget(
        _buildApp(
          circle: _makeCircle(),
          mockRelay: MockRelayService(),
          mockCircle: MockCircleService(),
        ),
      );
      await tester.pumpAndSettle();

      final l10n = l10nOf(tester, AddMemberPage);
      expect(find.text(l10n.createCircleEmptyTitle), findsOneWidget);
      expect(find.text(l10n.memberPickerSectionRoster), findsNothing);
    });
  });

  // -------------------------------------------------------------------------
  // The self-check. This page caught self only incidentally — as "Already in
  // this circle" — and that check sat AFTER a KeyPackage fetch, so offline it
  // failed open and the self-add was never identified (§9.5).
  // -------------------------------------------------------------------------
  group('AddMemberPage — you cannot invite yourself', () {
    testWidgets('A6. entering your own ID is refused as YOU, not as a member', (
      tester,
    ) async {
      final mockRelay = MockRelayService(
        keyPackageResult: _makeKp(_existingMemberHex),
      );
      await tester.pumpWidget(
        _buildApp(
          circle: _makeCircle(),
          mockRelay: mockRelay,
          mockCircle: MockCircleService(),
        ),
      );
      await tester.pumpAndSettle();

      await _addMember(tester, _existingMemberNpub);
      await tester.pumpAndSettle();

      final l10n = l10nOf(tester, AddMemberPage);
      expect(find.text(l10n.memberPickerReasonSelf), findsOneWidget);
      expect(find.text(l10n.addMemberAlreadyInCircle), findsNothing);
      expect(find.byType(PendingMemberTile), findsNothing);
    });

    testWidgets('A7. the refusal costs no relay lookup, so it holds offline', (
      tester,
    ) async {
      final mockRelay = MockRelayService(
        keyPackageResult: _makeKp(_existingMemberHex),
      );
      await tester.pumpWidget(
        _buildApp(
          circle: _makeCircle(),
          mockRelay: mockRelay,
          mockCircle: MockCircleService(),
        ),
      );
      await tester.pumpAndSettle();

      await _addMember(tester, _existingMemberNpub);
      await tester.pumpAndSettle();

      expect(
        mockRelay.methodCalls,
        isEmpty,
        reason:
            'the shipped check read a hex pubkey out of a FETCHED KeyPackage, '
            'so with no network it never ran at all',
      );
    });

    testWidgets('A9. the driver sequence — type by key, submit with done — '
        'enables a FilledButton confirm', (tester) async {
      // Exactly what `e2e_combined.dart` does on this page. A break here
      // hangs the lane for 60 s rather than failing it.
      await tester.pumpWidget(
        _buildApp(
          circle: _makeCircle(),
          mockRelay: MockRelayService(keyPackageResult: _makeKp(_newMemberHex)),
          mockCircle: MockCircleService(),
          directory: _aliceDirectory(),
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(WidgetKeys.memberSearchInput),
        _newMemberNpub,
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      final cta = tester.widget(find.byKey(WidgetKeys.addMemberConfirm));
      expect(cta, isA<FilledButton>());
      expect((cta as FilledButton).onPressed, isNotNull);
    });

    testWidgets('A8. an existing member who is NOT you keeps their own '
        'reason', (tester) async {
      final mockRelay = MockRelayService();
      await tester.pumpWidget(
        _buildApp(
          circle: _makeCircle(
            members: [
              TestCircleFactory.createMember(
                pubkey: _existingMemberHex,
                npub: _existingMemberNpub,
                isAdmin: true,
              ),
              TestCircleFactory.createMember(
                pubkey: _aliceHex,
                npub: _aliceNpub,
              ),
            ],
          ),
          mockRelay: mockRelay,
          mockCircle: MockCircleService(),
        ),
      );
      await tester.pumpAndSettle();

      await _addMember(tester, _aliceNpub);
      await tester.pumpAndSettle();

      final l10n = l10nOf(tester, AddMemberPage);
      expect(find.text(l10n.addMemberAlreadyInCircle), findsOneWidget);
      expect(find.text(l10n.memberPickerReasonSelf), findsNothing);
      expect(
        mockRelay.methodCalls,
        isEmpty,
        reason: 'roster npubs are already on the device',
      );
    });
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

/// A circle service whose invite the core refuses: an invitee lists no inbox
/// relay a Welcome could reach.
class _UnreachableInviteeService extends MockCircleService {
  @override
  Future<AddMemberResult> addMember({
    required List<int> mlsGroupId,
    required List<KeyPackageData> memberKeyPackages,
  }) async => throw const CircleInviteesUnreachableException();
}

class _GatedAddMemberService extends MockCircleService {
  _GatedAddMemberService(this.gate);

  final Completer<AddMemberResult> gate;

  @override
  Future<AddMemberResult> addMember({
    required List<int> mlsGroupId,
    required List<KeyPackageData> memberKeyPackages,
  }) {
    methodCalls.add('addMember');
    return gate.future;
  }
}

/// Records the circles whose deferred-send cause a flow recorded.
class _RecordingHealth extends SharingHealthNotifier {
  final List<String> deferred = [];

  /// Whether each recorded hold was the user's own action, in order.
  final List<bool> byUser = [];

  @override
  SharingHealth build() => SharingHealth.healthy;

  @override
  void recordDeferredSend(String circleKey, {bool byUser = false}) {
    deferred.add(circleKey);
    this.byUser.add(byUser);
  }
}

/// Opens [AddMemberPage] over a parent route it can pop back to.
Future<void> _openAddMemberPage(
  WidgetTester tester,
  ProviderContainer container, {
  required NavigatorObserver observer,
  List<AddMemberPageResult?>? results,
}) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        navigatorObservers: [observer],
        home: Scaffold(
          body: Builder(
            builder: (ctx) => ElevatedButton(
              onPressed: () => Navigator.of(ctx)
                  .push(
                    MaterialPageRoute<AddMemberPageResult>(
                      builder: (_) => AddMemberPage(circle: _makeCircle()),
                    ),
                  )
                  .then((result) => results?.add(result)),
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
}
