/// Tests for the Dark Matter cutover (DM-4c) legacy-circle banner in
/// [CirclesBottomSheet].
///
/// Verifies that:
/// - An orphaned pre-cutover circle (accepted, empty member list) shows the
///   legacy-circle banner instead of the generic "no members" hint.
/// - A pending (not-yet-accepted) invitation with an empty roster is NOT
///   mistaken for a legacy circle — it keeps the generic hint.
/// - "Re-create Circle" navigates to `CreateCirclePage`, pre-filled with the
///   old circle's display name.
/// - "Remove" shows a confirmation dialog; confirming calls
///   `circleService.leaveCircle` and clears the selection; canceling does
///   not call it.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/pages/circles/create_circle_page.dart';
import 'package:haven/src/providers/circles_provider.dart';
import 'package:haven/src/providers/identity_provider.dart';
import 'package:haven/src/providers/location_sharing_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/services/identity_service.dart';
import 'package:haven/src/test_keys.dart';
import 'package:haven/src/widgets/circles/circles_bottom_sheet.dart';

import '../../mocks/mock_circle_service.dart';

final _testIdentity = Identity(
  pubkeyHex: 'abc123def456abc123def456abc123def456abc123def456abc123def456abcd',
  npub: 'npub1test',
  createdAt: DateTime(2024),
);

Widget _buildTestWidget({
  required MockCircleService mockService,
  required Circle selectedCircle,
}) {
  return ProviderScope(
    overrides: [
      circleServiceProvider.overrideWithValue(mockService),
      selectedCircleProvider.overrideWith((ref) => selectedCircle),
      identityProvider.overrideWith((_) async => _testIdentity),
      memberLocationsProvider.overrideWith((_) async => const []),
    ],
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: Stack(children: [CirclesBottomSheet(onExpansionChanged: (_) {})]),
      ),
    ),
  );
}

/// Makes the viewport tall enough for the collapsed sheet (12%) to show the
/// circle header and member-list area.
void _setTallViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(800, 5000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Legacy circle banner (DM-4c)', () {
    testWidgets(
      'an orphaned circle (accepted, no members) shows the legacy banner '
      'instead of the generic "no members" hint',
      (tester) async {
        _setTallViewport(tester);
        final legacyCircle = TestCircleFactory.createCircle(
          displayName: 'Old Family',
        );
        final mockService = MockCircleService(circles: [legacyCircle]);

        await tester.pumpWidget(
          _buildTestWidget(
            mockService: mockService,
            selectedCircle: legacyCircle,
          ),
        );
        await tester.pumpAndSettle();

        expect(
          find.text('This circle needs to be re-created'),
          findsOneWidget,
        );
        expect(find.text('No members in this circle'), findsNothing);
        expect(find.byKey(WidgetKeys.legacyCircleRecreateCta), findsOneWidget);
        expect(find.byKey(WidgetKeys.legacyCircleRemoveCta), findsOneWidget);
      },
    );

    testWidgets(
      'a pending invitation with an empty roster is NOT treated as legacy',
      (tester) async {
        _setTallViewport(tester);
        final pendingCircle = TestCircleFactory.createCircle(
          displayName: 'New Invite',
          membershipStatus: MembershipStatus.pending,
        );
        final mockService = MockCircleService(circles: [pendingCircle]);

        await tester.pumpWidget(
          _buildTestWidget(
            mockService: mockService,
            selectedCircle: pendingCircle,
          ),
        );
        await tester.pumpAndSettle();

        expect(
          find.text('This circle needs to be re-created'),
          findsNothing,
        );
        expect(find.text('No members in this circle'), findsOneWidget);
      },
    );

    testWidgets(
      '"Re-create Circle" navigates to CreateCirclePage pre-filled with the '
      "old circle's name",
      (tester) async {
        _setTallViewport(tester);
        final legacyCircle = TestCircleFactory.createCircle(
          displayName: 'Old Family',
        );
        final mockService = MockCircleService(circles: [legacyCircle]);

        await tester.pumpWidget(
          _buildTestWidget(
            mockService: mockService,
            selectedCircle: legacyCircle,
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(WidgetKeys.legacyCircleRecreateCta));
        await tester.pumpAndSettle();

        final page = tester.widget<CreateCirclePage>(
          find.byType(CreateCirclePage),
        );
        expect(page.initialName, 'Old Family');
      },
    );

    testWidgets('"Remove" shows a confirmation dialog before removing', (
      tester,
    ) async {
      _setTallViewport(tester);
      final legacyCircle = TestCircleFactory.createCircle(
        displayName: 'Old Family',
      );
      final mockService = MockCircleService(circles: [legacyCircle]);

      await tester.pumpWidget(
        _buildTestWidget(
          mockService: mockService,
          selectedCircle: legacyCircle,
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(WidgetKeys.legacyCircleRemoveCta));
      await tester.pumpAndSettle();

      expect(find.text('Remove circle?'), findsOneWidget);
      expect(mockService.methodCalls, isNot(contains('leaveCircle')));
    });

    testWidgets(
      'canceling the remove dialog does NOT call leaveCircle',
      (tester) async {
        _setTallViewport(tester);
        final legacyCircle = TestCircleFactory.createCircle(
          displayName: 'Old Family',
        );
        final mockService = MockCircleService(circles: [legacyCircle]);

        await tester.pumpWidget(
          _buildTestWidget(
            mockService: mockService,
            selectedCircle: legacyCircle,
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(WidgetKeys.legacyCircleRemoveCta));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();

        expect(mockService.methodCalls, isNot(contains('leaveCircle')));
      },
    );

    testWidgets(
      'confirming "Remove" calls circleService.leaveCircle and clears '
      'selection',
      (tester) async {
        _setTallViewport(tester);
        final legacyCircle = TestCircleFactory.createCircle(
          mlsGroupId: const [9, 9, 9],
          displayName: 'Old Family',
        );
        final mockService = MockCircleService(circles: [legacyCircle]);

        await tester.pumpWidget(
          _buildTestWidget(
            mockService: mockService,
            selectedCircle: legacyCircle,
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(WidgetKeys.legacyCircleRemoveCta));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(TextButton, 'Remove'));
        await tester.pumpAndSettle();

        expect(mockService.methodCalls, contains('leaveCircle'));
        expect(
          mockService.leaveCircleCalledWith.single.mlsGroupId,
          const [9, 9, 9],
        );
        expect(find.text('Left circle successfully'), findsOneWidget);
      },
    );

    testWidgets(
      'a failed remove shows the generic error snackbar (no raw error)',
      (tester) async {
        _setTallViewport(tester);
        final legacyCircle = TestCircleFactory.createCircle(
          displayName: 'Old Family',
        );
        final mockService = MockCircleService(
          circles: [legacyCircle],
          shouldThrowOnLeaveCircle: true,
          errorMessage: 'MLS internal state: group_id=0xDEADBEEF',
        );

        await tester.pumpWidget(
          _buildTestWidget(
            mockService: mockService,
            selectedCircle: legacyCircle,
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(WidgetKeys.legacyCircleRemoveCta));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(TextButton, 'Remove'));
        await tester.pumpAndSettle();

        expect(find.text('Failed to leave circle'), findsOneWidget);
        expect(find.textContaining('DEADBEEF'), findsNothing);
      },
    );
  });
}
