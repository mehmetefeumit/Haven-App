/// Tests for the "Add member" CTA inside _CircleDetailsSheet.
///
/// Verifies that:
/// 1. An admin sees the addMemberCta button.
/// 2. A non-admin member does NOT see addMemberCta.
/// 3. A user not in the circle does NOT see addMemberCta.
/// 4. Tapping addMemberCta navigates to AddMemberPage.
/// 5. The leaveCircleCta is always present for members.
/// 6. When identity is null the addMemberCta is absent.
library;

import 'dart:math';

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
import 'package:haven/src/widgets/circles/circles_bottom_sheet.dart';

import '../../mocks/mock_circle_service.dart';
import '../../mocks/mock_relay_service.dart';

// ---------------------------------------------------------------------------
// Pubkey constants
// ---------------------------------------------------------------------------

const _adminPubkey =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _nonAdminPubkey =
    'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const _outsiderPubkey =
    'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc';

// ---------------------------------------------------------------------------
// Stub inbox relay notifier
// ---------------------------------------------------------------------------

/// Stub for [inboxRelaysProvider] — returns a fixed list without SQLite.
class _StubInboxRelays extends InboxRelaysNotifier {
  @override
  Future<List<String>> build() async => ['wss://relay.example'];
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

Identity _identity(String pubkeyHex) => Identity(
  pubkeyHex: pubkeyHex,
  npub: 'npub1test',
  createdAt: DateTime(2024),
);

/// Builds a circle that has [_adminPubkey] as admin and
/// [_nonAdminPubkey] as a regular member.
Circle _makeCircle() => TestCircleFactory.createCircle(
  displayName: 'Family',
  members: [
    TestCircleFactory.createMember(pubkey: _adminPubkey, isAdmin: true),
    TestCircleFactory.createMember(pubkey: _nonAdminPubkey),
  ],
);

/// Pumps the [CirclesBottomSheet] with [circle] selected and [selfPubkeyHex]
/// as the current user, then opens the circle-details modal sheet by tapping
/// the [WidgetKeys.circleDetailsButton].
///
/// The viewport is set tall (5 000 px) so the 12 % collapsed snap exposes the
/// info icon without the sheet needing to be dragged.
Future<void> _pumpAndOpenDetails(
  WidgetTester tester, {
  required Circle circle,
  required String selfPubkeyHex,
  required MockCircleService mockService,
}) async {
  tester.view.physicalSize = const Size(800, 5000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        circleServiceProvider.overrideWithValue(mockService),
        selectedCircleProvider.overrideWith((ref) => circle),
        identityProvider.overrideWith((_) async => _identity(selfPubkeyHex)),
        memberLocationsProvider.overrideWith((_) async => const []),
        relayServiceProvider.overrideWithValue(MockRelayService()),
        inboxRelaysProvider.overrideWith(_StubInboxRelays.new),
        // Do NOT override circlesProvider — let it fetch from mockService so
        // circles.isNotEmpty and the _CircleHeader (info icon) is rendered.
        joinWatcherProvider.overrideWith(
          (ref) => JoinWatcherNotifier(ref, rng: Random(0)),
        ),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: ThemeData(
          useMaterial3: false,
          splashFactory: InkSplash.splashFactory,
        ),
        home: Scaffold(
          body: Stack(
            children: [CirclesBottomSheet(onExpansionChanged: (_) {})],
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();

  // Tap the info icon to open the modal circle-details sheet.
  await tester.tap(find.byKey(WidgetKeys.circleDetailsButton));
  await tester.pumpAndSettle();
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('_CircleDetailsSheet — Add member CTA', () {
    // -----------------------------------------------------------------------
    // 1. Admin: CTA is present
    // -----------------------------------------------------------------------
    testWidgets('1. admin sees addMemberCta', (tester) async {
      final circle = _makeCircle();
      final mockService = MockCircleService(circles: [circle]);

      await _pumpAndOpenDetails(
        tester,
        circle: circle,
        selfPubkeyHex: _adminPubkey,
        mockService: mockService,
      );

      expect(find.byKey(WidgetKeys.addMemberCta), findsOneWidget);
    });

    // -----------------------------------------------------------------------
    // 2. Non-admin: CTA is absent; leaveCircleCta still present
    // -----------------------------------------------------------------------
    testWidgets(
      '2. non-admin member does NOT see addMemberCta; leaveCircleCta present',
      (tester) async {
        final circle = _makeCircle();
        final mockService = MockCircleService(circles: [circle]);

        await _pumpAndOpenDetails(
          tester,
          circle: circle,
          selfPubkeyHex: _nonAdminPubkey,
          mockService: mockService,
        );

        expect(find.byKey(WidgetKeys.addMemberCta), findsNothing);
        expect(find.byKey(WidgetKeys.leaveCircleCta), findsOneWidget);
      },
    );

    // -----------------------------------------------------------------------
    // 3. Outsider: CTA absent; leaveCircleCta present
    // -----------------------------------------------------------------------
    testWidgets(
      '3. user not in circle does NOT see addMemberCta; leaveCircleCta present',
      (tester) async {
        final circle = _makeCircle();
        final mockService = MockCircleService(circles: [circle]);

        await _pumpAndOpenDetails(
          tester,
          circle: circle,
          selfPubkeyHex: _outsiderPubkey,
          mockService: mockService,
        );

        expect(find.byKey(WidgetKeys.addMemberCta), findsNothing);
        expect(find.byKey(WidgetKeys.leaveCircleCta), findsOneWidget);
      },
    );

    // -----------------------------------------------------------------------
    // 4. Admin: leaveCircleCta is also present
    // -----------------------------------------------------------------------
    testWidgets(
      '4. admin sees both addMemberCta and leaveCircleCta',
      (tester) async {
        final circle = _makeCircle();
        final mockService = MockCircleService(circles: [circle]);

        await _pumpAndOpenDetails(
          tester,
          circle: circle,
          selfPubkeyHex: _adminPubkey,
          mockService: mockService,
        );

        expect(find.byKey(WidgetKeys.addMemberCta), findsOneWidget);
        expect(find.byKey(WidgetKeys.leaveCircleCta), findsOneWidget);
      },
    );

    // -----------------------------------------------------------------------
    // 5. Tap navigates to AddMemberPage
    // -----------------------------------------------------------------------
    testWidgets(
      '5. tapping addMemberCta pushes AddMemberPage onto the navigator',
      (tester) async {
        final circle = _makeCircle();
        final mockService = MockCircleService(circles: [circle]);

        await _pumpAndOpenDetails(
          tester,
          circle: circle,
          selfPubkeyHex: _adminPubkey,
          mockService: mockService,
        );

        expect(find.byKey(WidgetKeys.addMemberCta), findsOneWidget);

        // Tap the CTA — this pushes AddMemberPage via MaterialPageRoute.
        await tester.tap(find.byKey(WidgetKeys.addMemberCta));
        await tester.pumpAndSettle();

        // AddMemberPage must now be in the widget tree.
        expect(find.byType(AddMemberPage), findsOneWidget);
      },
    );

    // -----------------------------------------------------------------------
    // 6. No identity: CTA absent
    // -----------------------------------------------------------------------
    testWidgets(
      '6. when identityProvider returns null, addMemberCta is absent',
      (tester) async {
        final circle = _makeCircle();
        final mockService = MockCircleService(circles: [circle]);

        tester.view.physicalSize = const Size(800, 5000);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              circleServiceProvider.overrideWithValue(mockService),
              selectedCircleProvider.overrideWith((ref) => circle),
              // Null identity — no logged-in user.
              identityProvider.overrideWith((_) async => null),
              memberLocationsProvider.overrideWith((_) async => const []),
              relayServiceProvider.overrideWithValue(MockRelayService()),
              inboxRelaysProvider.overrideWith(_StubInboxRelays.new),
              // Do NOT override circlesProvider so the header renders.
              joinWatcherProvider.overrideWith(
                (ref) => JoinWatcherNotifier(ref, rng: Random(0)),
              ),
            ],
            child: MaterialApp(
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              theme: ThemeData(
                useMaterial3: false,
                splashFactory: InkSplash.splashFactory,
              ),
              home: Scaffold(
                body: Stack(
                  children: [CirclesBottomSheet(onExpansionChanged: (_) {})],
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(WidgetKeys.circleDetailsButton));
        await tester.pumpAndSettle();

        expect(find.byKey(WidgetKeys.addMemberCta), findsNothing);
      },
    );
  });
}
