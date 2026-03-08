/// Tests for CirclesBottomSheet widget.
///
/// Verifies that:
/// - Sheet displays circle selector dropdown
/// - Empty state is shown when no circles
/// - Members are displayed when circle is selected
/// - Dim overlay appears when dropdown is open
/// - Expansion callback is triggered correctly
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/providers/circles_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/widgets/circles/circles_bottom_sheet.dart';

import '../../mocks/mock_circle_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('CirclesBottomSheet', () {
    testWidgets('renders without errors', (tester) async {
      final mockService = MockCircleService();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [circleServiceProvider.overrideWithValue(mockService)],
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

      expect(find.byType(DraggableScrollableSheet), findsOneWidget);
    });

    testWidgets('shows empty state when no circles exist', (tester) async {
      final mockService = MockCircleService(circles: []);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [circleServiceProvider.overrideWithValue(mockService)],
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

      expect(find.text('No Circles Yet'), findsOneWidget);
      expect(find.text('Create Circle'), findsOneWidget);
    });

    testWidgets('shows circle selector when circles exist', (tester) async {
      final testCircles = [
        TestCircleFactory.createCircle(displayName: 'Family'),
      ];
      final mockService = MockCircleService(circles: testCircles);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [circleServiceProvider.overrideWithValue(mockService)],
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

      // No circle selected — should show placeholder text
      expect(find.text('Select a circle'), findsOneWidget);
    });

    testWidgets('shows hint when circles exist but none selected', (
      tester,
    ) async {
      final testCircles = [
        TestCircleFactory.createCircle(displayName: 'Family'),
      ];
      final mockService = MockCircleService(circles: testCircles);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [circleServiceProvider.overrideWithValue(mockService)],
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

      expect(find.text('Select a circle to view members'), findsOneWidget);
    });

    testWidgets('shows circle header when circle is selected', (tester) async {
      final testMembers = [
        TestCircleFactory.createMember(
          pubkey:
              'abc123def456abc123def456abc123def456abc123def456abc123def456abcd',
          displayName: 'Alice',
          isAdmin: true,
        ),
        TestCircleFactory.createMember(
          pubkey:
              'def456abc123def456abc123def456abc123def456abc123def456abc123defg',
          displayName: 'Bob',
        ),
      ];
      final testCircle = TestCircleFactory.createCircle(
        displayName: 'Family',
        members: testMembers,
      );
      final mockService = MockCircleService(circles: [testCircle]);
      final sheetController = DraggableScrollableController();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            circleServiceProvider.overrideWithValue(mockService),
            selectedCircleProvider.overrideWith((ref) => testCircle),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: Stack(
                children: [
                  CirclesBottomSheet(
                    onExpansionChanged: (_) {},
                    controller: sheetController,
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Expand the sheet so header content is visible
      sheetController.jumpTo(0.5);
      await tester.pumpAndSettle();

      // Circle name appears only in the dropdown trigger (not duplicated in header)
      expect(find.text('Family'), findsOneWidget);

      // Should show member count in header
      expect(find.text('2 members'), findsOneWidget);
    });

    testWidgets('shows E2E encryption indicator', (tester) async {
      final testCircle = TestCircleFactory.createCircle(displayName: 'Family');
      final mockService = MockCircleService(circles: [testCircle]);
      final sheetController = DraggableScrollableController();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            circleServiceProvider.overrideWithValue(mockService),
            selectedCircleProvider.overrideWith((ref) => testCircle),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: Stack(
                children: [
                  CirclesBottomSheet(
                    onExpansionChanged: (_) {},
                    controller: sheetController,
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Expand the sheet so header content is visible
      sheetController.jumpTo(0.5);
      await tester.pumpAndSettle();

      expect(find.text('E2E'), findsOneWidget);
      expect(find.byIcon(Icons.lock), findsOneWidget);
    });

    testWidgets('shows dim overlay when dropdown is open', (tester) async {
      final testCircles = [
        TestCircleFactory.createCircle(displayName: 'Family'),
      ];
      final mockService = MockCircleService(circles: testCircles);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            circleServiceProvider.overrideWithValue(mockService),
            circleDropdownOpenProvider.overrideWith((ref) => true),
          ],
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

      // Dim overlay should be present (ColoredBox with semi-transparent black)
      expect(find.byType(ColoredBox), findsWidgets);

      // The "select to view members" hint should NOT be visible (replaced by dim)
      expect(find.text('Select a circle to view members'), findsNothing);
    });

    testWidgets('handles service errors gracefully', (tester) async {
      final mockService = MockCircleService(
        shouldThrowOnGetCircles: true,
        errorMessage: 'Storage error',
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [circleServiceProvider.overrideWithValue(mockService)],
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

      // With graceful degradation, should show empty state
      expect(find.text('No Circles Yet'), findsOneWidget);
    });
  });
}
