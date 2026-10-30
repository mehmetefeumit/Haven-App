/// Tests for the Leave Circle flow in CirclesBottomSheet.
///
/// Verifies that:
/// - The info button opens a details sheet with a Leave Circle button
/// - Tapping "Leave Circle" shows the confirmation dialog
/// - Confirming calls circleService.leaveCircle() and clears selection
/// - Canceling does NOT call leaveCircle()
/// - Error shows generic SnackBar (not raw error details)
/// - Error message in circles list does not leak internals
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/providers/circles_provider.dart';
import 'package:haven/src/providers/identity_provider.dart';
import 'package:haven/src/providers/location_sharing_provider.dart';
import 'package:haven/src/providers/maintenance_scheduler_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/providers/sharing_health_provider.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/services/identity_service.dart';
import 'package:haven/src/widgets/circles/circles_bottom_sheet.dart';

import '../../mocks/mock_circle_service.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

final _testIdentity = Identity(
  pubkeyHex: 'abc123def456abc123def456abc123def456abc123def456abc123def456abcd',
  npub: 'npub1test',
  createdAt: DateTime(2024),
);

/// Builds the test harness with a selected circle and overrides.
/// The scheduler a leave's follow-up is armed on, recording and arming
/// nothing.
class _RecordingScheduler extends MaintenanceSchedulerNotifier {
  int followUps = 0;

  @override
  void build() {}

  @override
  void followUpLeave() => followUps++;
}

Widget _buildTestWidget({
  required MockCircleService mockService,
  required Circle selectedCircle,
  SharingHealthNotifier Function()? health,
  _RecordingScheduler? scheduler,
}) {
  return ProviderScope(
    overrides: [
      if (health != null) sharingHealthProvider.overrideWith(health),
      maintenanceSchedulerProvider.overrideWith(
        () => scheduler ?? _RecordingScheduler(),
      ),
      circleServiceProvider.overrideWithValue(mockService),
      selectedCircleProvider.overrideWith((ref) => selectedCircle),
      identityProvider.overrideWith((_) async => _testIdentity),
      // Stub out location fetching — it reaches into Rust FFI which is
      // unavailable in widget tests. The leave flow does not exercise
      // location data, so an empty list is sufficient.
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Circle testCircle;
  late MockCircleService mockService;

  setUp(() {
    testCircle = TestCircleFactory.createCircle(
      displayName: 'Family',
      members: [
        TestCircleFactory.createMember(displayName: 'Alice', isAdmin: true),
        TestCircleFactory.createMember(
          pubkey:
              'def456abc123def456abc123def456'
              'abc123def456abc123def456abc123defg',
          displayName: 'Bob',
        ),
      ],
    );
    mockService = MockCircleService(circles: [testCircle]);
  });

  /// Makes the viewport tall enough for the collapsed sheet (12%)
  /// to show the circle header with the overflow menu.
  void setTallViewport(WidgetTester tester) {
    // 12% of 5000 = 600px — plenty for the header.
    tester.view.physicalSize = const Size(800, 5000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  /// Opens the circle-details sheet from the info button and taps the
  /// Leave Circle button inside it.
  Future<void> openLeaveCircleDialog(WidgetTester tester) async {
    await tester.tap(find.byIcon(LucideIcons.info));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(OutlinedButton, 'Leave Circle'));
    await tester.pumpAndSettle();
  }

  group('Leave Circle', () {
    testWidgets('details sheet exposes the Leave Circle button', (
      tester,
    ) async {
      setTallViewport(tester);
      await tester.pumpWidget(
        _buildTestWidget(mockService: mockService, selectedCircle: testCircle),
      );
      await tester.pumpAndSettle();

      // Overflow menu has been removed in favour of the in-sheet button.
      expect(find.byIcon(LucideIcons.ellipsisVertical), findsNothing);
      expect(find.byType(PopupMenuButton<String>), findsNothing);

      await tester.tap(find.byIcon(LucideIcons.info));
      await tester.pumpAndSettle();

      expect(
        find.widgetWithText(OutlinedButton, 'Leave Circle'),
        findsOneWidget,
      );
    });

    testWidgets('tapping Leave Circle shows confirmation dialog', (
      tester,
    ) async {
      setTallViewport(tester);
      await tester.pumpWidget(
        _buildTestWidget(mockService: mockService, selectedCircle: testCircle),
      );
      await tester.pumpAndSettle();

      await openLeaveCircleDialog(tester);

      // Confirmation dialog should appear.
      expect(find.textContaining('Leave this circle?'), findsOneWidget);
      expect(find.text('Cancel'), findsOneWidget);
      expect(find.text('Leave'), findsOneWidget);
    });

    testWidgets('confirming leave calls circleService.leaveCircle()', (
      tester,
    ) async {
      setTallViewport(tester);
      await tester.pumpWidget(
        _buildTestWidget(mockService: mockService, selectedCircle: testCircle),
      );
      await tester.pumpAndSettle();

      await openLeaveCircleDialog(tester);

      // Confirm the dialog.
      await tester.tap(find.text('Leave'));
      await tester.pumpAndSettle();

      // Verify leaveCircle was called.
      expect(mockService.methodCalls, contains('leaveCircle'));

      // Should show success snackbar.
      expect(find.text('Left circle successfully'), findsOneWidget);
    });

    testWidgets("leaving a disbanded circle deletes only this device's copy: "
        'no leave is sent, and it is left at once', (tester) async {
      setTallViewport(tester);
      final disbanded = TestCircleFactory.createCircle(
        displayName: 'Family',
        engineState: CircleEngineState.disbanded,
        members: testCircle.members,
      );
      final service = MockCircleService(circles: [disbanded]);
      await tester.pumpWidget(
        _buildTestWidget(mockService: service, selectedCircle: disbanded),
      );
      await tester.pumpAndSettle();

      await openLeaveCircleDialog(tester);
      await tester.tap(find.text('Leave'));
      await tester.pumpAndSettle();

      expect(service.leaveDisbandedCalledWith, [disbanded.mlsGroupId]);
      expect(
        service.methodCalls,
        isNot(contains('leaveCircle')),
        reason: 'no member receives anything for a disbanded circle, so no '
            'leave proposal is staged or sent',
      );
      expect(find.text('Left circle successfully'), findsOneWidget);
    });

    testWidgets('a leave still being carried on says neither "left" nor an '
        'error, records the deferred-send cause and arms its follow-up',
        (tester) async {
      setTallViewport(tester);
      final health = _RecordingHealth();
      final scheduler = _RecordingScheduler();
      mockService.leaveCircleDelivery = LeaveDelivery.leaving;
      await tester.pumpWidget(
        _buildTestWidget(
          mockService: mockService,
          selectedCircle: testCircle,
          health: () => health,
          scheduler: scheduler,
        ),
      );
      await tester.pumpAndSettle();

      await openLeaveCircleDialog(tester);
      await tester.tap(find.text('Leave'));
      await tester.pumpAndSettle();

      expect(mockService.methodCalls, contains('leaveCircle'));
      expect(find.text('Left circle successfully'), findsNothing);
      expect(find.byType(SnackBar), findsNothing);
      expect(health.deferred, [sharingCircleKey(testCircle)]);
      expect(health.byUser, [true], reason: "the user's own action");
      expect(scheduler.followUps, 1);
    });

    testWidgets('a press that leaves the selected circle closes its sheet '
        'once, not the page beneath it', (tester) async {
      setTallViewport(tester);
      await tester.pumpWidget(
        _buildTestWidget(mockService: mockService, selectedCircle: testCircle),
      );
      await tester.pumpAndSettle();
      ProviderScope.containerOf(
        tester.element(find.byType(CirclesBottomSheet)),
      ).read(selectedCircleIdProvider.notifier).state = testCircle.mlsGroupId;

      await openLeaveCircleDialog(tester);
      tester.takeAnnouncements();
      await tester.tap(find.text('Leave'));
      await tester.pumpAndSettle();

      expect(find.text('Left circle successfully'), findsOneWidget);
      expect(find.byType(CirclesBottomSheet), findsOne);
      expect(
        tester.takeAnnouncements(),
        isEmpty,
        reason: 'the press says it through its own snack bar, once',
      );
      expect(find.widgetWithText(OutlinedButton, 'Leave Circle'), findsNothing);
    });

    testWidgets('a leave a carry-on ended closes the open circle sheet',
        (tester) async {
      setTallViewport(tester);
      await tester.pumpWidget(
        _buildTestWidget(mockService: mockService, selectedCircle: testCircle),
      );
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(
        tester.element(find.byType(CirclesBottomSheet)),
      );
      container.read(selectedCircleIdProvider.notifier).state =
          testCircle.mlsGroupId;
      await tester.tap(find.byIcon(LucideIcons.info));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(OutlinedButton, 'Leave Circle'), findsOne);

      // What the scheduler does when a carry-on finds this circle's leave
      // ended.
      tester.takeAnnouncements();
      container.read(selectedCircleIdProvider.notifier).state = null;
      await tester.pumpAndSettle();

      expect(find.widgetWithText(OutlinedButton, 'Leave Circle'), findsNothing);
      expect(find.byType(CirclesBottomSheet), findsOne);
      expect(
        tester.takeAnnouncements().map((a) => a.message),
        ['Left circle successfully'],
        reason: 'a screen-reader user is not told the sheet closed because '
            'the leave ended',
      );
    });

    testWidgets('a sheet dismissed while its leave is answered still records '
        'the deferred-send cause', (tester) async {
      setTallViewport(tester);
      final health = _RecordingHealth();
      mockService
        ..leaveCircleDelivery = LeaveDelivery.leaving
        ..leaveCircleGate = Completer<void>();
      await tester.pumpWidget(
        _buildTestWidget(
          mockService: mockService,
          selectedCircle: testCircle,
          health: () => health,
        ),
      );
      await tester.pumpAndSettle();

      await openLeaveCircleDialog(tester);
      await tester.tap(find.text('Leave'));
      await tester.pump();
      expect(mockService.methodCalls, contains('leaveCircle'));
      // The user dismisses the details sheet while the leave is answered.
      tester.state<NavigatorState>(find.byType(Navigator)).pop();
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(find.widgetWithText(OutlinedButton, 'Leave Circle'), findsNothing);

      mockService.leaveCircleGate!.complete();
      await tester.pump();

      expect(health.deferred, [sharingCircleKey(testCircle)]);
      expect(health.byUser, [true], reason: "the user's own action");
    });

    testWidgets('a leave not made says it failed and keeps the circle', (
      tester,
    ) async {
      setTallViewport(tester);
      final health = _RecordingHealth();
      mockService.leaveCircleDelivery = LeaveDelivery.notMade;
      await tester.pumpWidget(
        _buildTestWidget(
          mockService: mockService,
          selectedCircle: testCircle,
          health: () => health,
        ),
      );
      await tester.pumpAndSettle();

      await openLeaveCircleDialog(tester);
      await tester.tap(find.text('Leave'));
      await tester.pumpAndSettle();

      expect(find.text('Failed to leave circle'), findsOneWidget);
      expect(find.text('Left circle successfully'), findsNothing);
      expect(health.deferred, isEmpty);
      expect(find.widgetWithText(OutlinedButton, 'Leave Circle'), findsOne);
    });

    testWidgets('canceling does NOT call leaveCircle()', (tester) async {
      setTallViewport(tester);
      await tester.pumpWidget(
        _buildTestWidget(mockService: mockService, selectedCircle: testCircle),
      );
      await tester.pumpAndSettle();

      await openLeaveCircleDialog(tester);

      // Cancel the dialog.
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      // Verify leaveCircle was NOT called.
      expect(mockService.methodCalls, isNot(contains('leaveCircle')));
    });

    testWidgets('error shows generic SnackBar without raw error details', (
      tester,
    ) async {
      setTallViewport(tester);
      final failingService = MockCircleService(
        circles: [testCircle],
        shouldThrowOnLeaveCircle: true,
        errorMessage: 'MLS internal state: group_id=0xDEADBEEF',
      );

      await tester.pumpWidget(
        _buildTestWidget(
          mockService: failingService,
          selectedCircle: testCircle,
        ),
      );
      await tester.pumpAndSettle();

      await openLeaveCircleDialog(tester);

      // Confirm the dialog.
      await tester.tap(find.text('Leave'));
      await tester.pumpAndSettle();

      // Should show generic error, NOT the raw error.
      expect(find.text('Failed to leave circle'), findsOneWidget);
      expect(find.textContaining('DEADBEEF'), findsNothing);
      expect(find.textContaining('MLS internal'), findsNothing);
    });

    testWidgets('error display in circles list does not leak internals', (
      tester,
    ) async {
      final failingService = MockCircleService(
        shouldThrowOnGetCircles: true,
        errorMessage: 'internal error: group_id=0xSECRET',
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [circleServiceProvider.overrideWithValue(failingService)],
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: Stack(
                children: [CirclesBottomSheet(onExpansionChanged: (_) {})],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Should NOT show raw error details.
      expect(find.textContaining('SECRET'), findsNothing);
      expect(find.textContaining('internal error'), findsNothing);
    });
  });

  group('the leave dialog and button say what is true', () {
    const other =
        'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc';

    Circle circleWith({required bool selfAdmin, required bool withOthers}) =>
        TestCircleFactory.createCircle(
          displayName: 'Family',
          members: [
            TestCircleFactory.createMember(
              pubkey: _testIdentity.pubkeyHex,
              isAdmin: selfAdmin,
            ),
            if (withOthers) TestCircleFactory.createMember(pubkey: other),
          ],
        );

    Future<AppLocalizations> openDialog(
      WidgetTester tester,
      Circle circle,
    ) async {
      setTallViewport(tester);
      await tester.pumpWidget(
        _buildTestWidget(
          mockService: MockCircleService(circles: [circle]),
          selectedCircle: circle,
        ),
      );
      await tester.pumpAndSettle();
      await openLeaveCircleDialog(tester);
      return AppLocalizations.of(tester.element(find.byType(AlertDialog)));
    }

    testWidgets('an admin with someone to hand over to is told so', (
      tester,
    ) async {
      final l10n = await openDialog(
        tester,
        circleWith(selfAdmin: true, withOthers: true),
      );
      expect(find.text(l10n.leaveCircleDialogBody), findsOneWidget);
      expect(find.text(l10n.leaveCircleDialogAdminNote), findsOneWidget);
    });

    for (final (name, selfAdmin, withOthers) in const [
      ('an admin alone', true, false),
      ('a member who is no admin', false, true),
    ]) {
      testWidgets('$name hears no hand-over', (tester) async {
        final l10n = await openDialog(
          tester,
          circleWith(selfAdmin: selfAdmin, withOthers: withOthers),
        );
        expect(find.text(l10n.leaveCircleDialogBody), findsOneWidget);
        expect(find.text(l10n.leaveCircleDialogAdminNote), findsNothing);
      });
    }

    testWidgets('an ended circle is told what leaving it does, and nothing '
        'about sending', (tester) async {
      final ended = TestCircleFactory.createCircle(
        displayName: 'Family',
        engineState: CircleEngineState.disbanded,
        members: circleWith(selfAdmin: true, withOthers: true).members,
      );
      final l10n = await openDialog(tester, ended);
      expect(find.text(l10n.leaveDisbandedCircleDialogBody), findsOneWidget);
      expect(find.text(l10n.leaveCircleDialogBody), findsNothing);
      expect(find.text(l10n.leaveCircleDialogAdminNote), findsNothing);
    });

    testWidgets('while this device is leaving, Leave is disabled and says so',
        (tester) async {
      setTallViewport(tester);
      final circle = circleWith(selfAdmin: false, withOthers: true);
      await tester.pumpWidget(
        _buildTestWidget(
          mockService: MockCircleService(circles: [circle]),
          selectedCircle: circle,
          health: () => _StandingHealth(
            SharingHealth.paused(
              SharingPausedReason.leaving,
              DateTime.utc(2026),
              ageProvable: false,
            ).about(sharingCircleKey(circle)),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(LucideIcons.info));
      await tester.pumpAndSettle();
      final l10n = AppLocalizations.of(
        tester.element(find.byType(CirclesBottomSheet)),
      );
      final button = find.widgetWithText(
        OutlinedButton,
        l10n.circleDetailsLeavingInProgress,
      );
      expect(button, findsOneWidget);
      expect(tester.widget<OutlinedButton>(button).onPressed, isNull);
    });

    testWidgets("another circle's leave leaves this circle's Leave enabled",
        (tester) async {
      setTallViewport(tester);
      final circle = circleWith(selfAdmin: false, withOthers: true);
      await tester.pumpWidget(
        _buildTestWidget(
          mockService: MockCircleService(circles: [circle]),
          selectedCircle: circle,
          health: () => _StandingHealth(
            SharingHealth.paused(
              SharingPausedReason.leaving,
              DateTime.utc(2026),
              ageProvable: false,
            ).about('another circle'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(LucideIcons.info));
      await tester.pumpAndSettle();
      final leave = find.widgetWithText(OutlinedButton, 'Leave Circle');
      expect(leave, findsOneWidget);
      expect(tester.widget<OutlinedButton>(leave).onPressed, isNotNull);
    });

    testWidgets('a circle that ends while its details are open is left as an '
        'ended circle', (tester) async {
      // The sheet reads the live circle for its actions (AM-D2-4): a leave
      // pressed after the disband must not go down the driver path the
      // driver refuses for an ended circle.
      setTallViewport(tester);
      final circle = circleWith(selfAdmin: false, withOthers: true);
      final service = MockCircleService(circles: [circle]);
      await tester.pumpWidget(
        _buildTestWidget(mockService: service, selectedCircle: circle),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(LucideIcons.info));
      await tester.pumpAndSettle();

      service.setEngineState(circle.mlsGroupId, CircleEngineState.disbanded);
      ProviderScope.containerOf(
        tester.element(find.byType(CirclesBottomSheet)),
      ).invalidate(circlesProvider);
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(OutlinedButton, 'Leave Circle'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Leave'));
      await tester.pumpAndSettle();
      expect(service.leaveDisbandedCalledWith, [circle.mlsGroupId]);
      expect(service.methodCalls, isNot(contains('leaveCircle')));
    });
  });
}

/// A verdict that stands as given.
class _StandingHealth extends SharingHealthNotifier {
  _StandingHealth(this._health);

  final SharingHealth _health;

  @override
  SharingHealth build() => _health;

  @override
  Future<void> refresh() async {}
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
