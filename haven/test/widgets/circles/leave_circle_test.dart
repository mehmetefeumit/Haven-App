/// Tests for the Leave Circle flow in CirclesBottomSheet.
///
/// Verifies that:
/// - PopupMenuButton appears in circle header
/// - Tapping "Leave Circle" shows confirmation dialog
/// - Confirming calls circleService.leaveCircle() and clears selection
/// - Canceling does NOT call leaveCircle()
/// - Error shows generic SnackBar (not raw error details)
/// - Error message in circles list does not leak internals
library;

import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/providers/circles_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/widgets/circles/circles_bottom_sheet.dart';

import '../../mocks/mock_circle_service.dart';

/// Builds the test harness with a selected circle and overrides.
Widget _buildTestWidget({
  required MockCircleService mockService,
  required Circle selectedCircle,
}) {
  return ProviderScope(
    overrides: [
      circleServiceProvider.overrideWithValue(mockService),
      selectedCircleProvider.overrideWith((ref) => selectedCircle),
    ],
    child: MaterialApp(
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

  /// Opens the overflow menu and taps "Leave Circle".
  Future<void> openLeaveCircleDialog(WidgetTester tester) async {
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Leave Circle'));
    await tester.pumpAndSettle();
  }

  group('Leave Circle', () {
    testWidgets('overflow menu appears in circle header', (tester) async {
      setTallViewport(tester);
      await tester.pumpWidget(
        _buildTestWidget(mockService: mockService, selectedCircle: testCircle),
      );
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.more_vert), findsOneWidget);
      expect(find.byType(PopupMenuButton<String>), findsOneWidget);
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
      expect(find.textContaining('Are you sure'), findsOneWidget);
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
}
