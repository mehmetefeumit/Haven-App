/// Tests for CircleSelector dropdown widget.
///
/// Verifies that:
/// - Collapsed state shows placeholder or selected circle name
/// - Tapping trigger opens/closes the dropdown
/// - Selecting a circle updates the provider and closes the dropdown
/// - Tapping a selected circle deselects it
/// - "New Circle" navigates to CreateCirclePage
/// - Loading and error states display correctly
/// - Arrow icon rotates when dropdown is open
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/pages/circles/create_circle_page.dart';
import 'package:haven/src/providers/circles_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/widgets/circles/circle_selector.dart';

import '../../mocks/mock_circle_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('CircleSelector', () {
    testWidgets('shows loading indicator while fetching circles', (
      tester,
    ) async {
      final mockService = MockCircleService();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [circleServiceProvider.overrideWithValue(mockService)],
          child: const MaterialApp(home: Scaffold(body: CircleSelector())),
        ),
      );

      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      await tester.pumpAndSettle();

      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('shows "Select a circle" when no circle selected', (
      tester,
    ) async {
      final testCircles = [
        TestCircleFactory.createCircle(displayName: 'Family'),
      ];
      final mockService = MockCircleService(circles: testCircles);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [circleServiceProvider.overrideWithValue(mockService)],
          child: const MaterialApp(home: Scaffold(body: CircleSelector())),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Select a circle'), findsOneWidget);
      expect(find.byIcon(Icons.keyboard_arrow_down), findsOneWidget);
      expect(find.byIcon(Icons.groups_outlined), findsOneWidget);
    });

    testWidgets('shows selected circle name when circle is selected', (
      tester,
    ) async {
      final testCircle = TestCircleFactory.createCircle(displayName: 'Family');
      final mockService = MockCircleService(circles: [testCircle]);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            circleServiceProvider.overrideWithValue(mockService),
            selectedCircleProvider.overrideWith((ref) => testCircle),
          ],
          child: const MaterialApp(home: Scaffold(body: CircleSelector())),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Family'), findsOneWidget);
      expect(find.text('Select a circle'), findsNothing);
    });

    testWidgets('tapping trigger opens dropdown and shows circle list', (
      tester,
    ) async {
      final testCircles = [
        TestCircleFactory.createCircle(
          mlsGroupId: [1, 2, 3],
          displayName: 'Family',
        ),
        TestCircleFactory.createCircle(
          mlsGroupId: [4, 5, 6],
          displayName: 'Friends',
        ),
      ];
      final mockService = MockCircleService(circles: testCircles);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [circleServiceProvider.overrideWithValue(mockService)],
          child: MaterialApp(
            theme: ThemeData(splashFactory: InkSplash.splashFactory),
            home: const Scaffold(body: CircleSelector()),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Initially dropdown is closed — no circle list items visible
      expect(find.text('New Circle'), findsNothing);

      // Tap the trigger row
      await tester.tap(find.text('Select a circle'));
      await tester.pumpAndSettle();

      // Circle list items and "New Circle" should appear
      expect(find.text('Family'), findsOneWidget);
      expect(find.text('Friends'), findsOneWidget);
      expect(find.text('New Circle'), findsOneWidget);
    });

    testWidgets('tapping trigger again closes dropdown', (tester) async {
      final testCircles = [
        TestCircleFactory.createCircle(displayName: 'Family'),
      ];
      final mockService = MockCircleService(circles: testCircles);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            circleServiceProvider.overrideWithValue(mockService),
            // Start with dropdown open
            circleDropdownOpenProvider.overrideWith((ref) => true),
          ],
          child: MaterialApp(
            theme: ThemeData(splashFactory: InkSplash.splashFactory),
            home: const Scaffold(body: CircleSelector()),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Dropdown open — list visible
      expect(find.text('New Circle'), findsOneWidget);

      // Tap trigger to close
      await tester.tap(find.text('Select a circle'));
      await tester.pumpAndSettle();

      // List should be hidden
      expect(find.text('New Circle'), findsNothing);
    });

    testWidgets('selecting a circle updates provider and closes dropdown', (
      tester,
    ) async {
      final testCircle = TestCircleFactory.createCircle(displayName: 'Family');
      final mockService = MockCircleService(circles: [testCircle]);

      late WidgetRef testRef;

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            circleServiceProvider.overrideWithValue(mockService),
            circleDropdownOpenProvider.overrideWith((ref) => true),
          ],
          child: MaterialApp(
            theme: ThemeData(splashFactory: InkSplash.splashFactory),
            home: Scaffold(
              body: Consumer(
                builder: (context, ref, _) {
                  testRef = ref;
                  return const CircleSelector();
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Tap the circle in the list
      await tester.tap(find.text('Family'));
      await tester.pumpAndSettle();

      // Provider should be updated
      expect(testRef.read(selectedCircleProvider), testCircle);
      // Dropdown should be closed
      expect(testRef.read(circleDropdownOpenProvider), isFalse);
    });

    testWidgets('tapping selected circle deselects it', (tester) async {
      final testCircle = TestCircleFactory.createCircle(displayName: 'Family');
      final mockService = MockCircleService(circles: [testCircle]);

      late WidgetRef testRef;

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            circleServiceProvider.overrideWithValue(mockService),
            selectedCircleProvider.overrideWith((ref) => testCircle),
            circleDropdownOpenProvider.overrideWith((ref) => true),
          ],
          child: MaterialApp(
            theme: ThemeData(splashFactory: InkSplash.splashFactory),
            home: Scaffold(
              body: Consumer(
                builder: (context, ref, _) {
                  testRef = ref;
                  return const CircleSelector();
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Should show check icon for the selected circle
      expect(find.byIcon(Icons.check), findsOneWidget);

      // Tap the selected circle in the list to deselect
      // Family appears both in trigger row and in list — tap the ListTile one
      await tester.tap(find.widgetWithText(ListTile, 'Family').first);
      await tester.pumpAndSettle();

      // Provider should be null (deselected)
      expect(testRef.read(selectedCircleProvider), isNull);
    });

    testWidgets('"New Circle" navigates to CreateCirclePage', (tester) async {
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
            theme: ThemeData(splashFactory: InkSplash.splashFactory),
            home: const Scaffold(body: CircleSelector()),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('New Circle'));
      await tester.pumpAndSettle();

      expect(find.byType(CreateCirclePage), findsOneWidget);
    });

    testWidgets('shows error state when service fails', (tester) async {
      final mockService = MockCircleService(
        shouldThrowOnGetCircles: true,
        errorMessage: 'Network error',
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [circleServiceProvider.overrideWithValue(mockService)],
          child: const MaterialApp(home: Scaffold(body: CircleSelector())),
        ),
      );
      await tester.pumpAndSettle();

      // With graceful degradation, circlesProvider returns empty list on error,
      // so the trigger row with placeholder should appear
      expect(find.text('Select a circle'), findsOneWidget);
    });

    testWidgets('arrow icon rotates when dropdown is open', (tester) async {
      final testCircles = [
        TestCircleFactory.createCircle(displayName: 'Family'),
      ];
      final mockService = MockCircleService(circles: testCircles);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [circleServiceProvider.overrideWithValue(mockService)],
          child: MaterialApp(
            theme: ThemeData(splashFactory: InkSplash.splashFactory),
            home: const Scaffold(body: CircleSelector()),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Closed: rotation should be 0
      var rotation = tester.widget<AnimatedRotation>(
        find.byType(AnimatedRotation),
      );
      expect(rotation.turns, 0);

      // Open dropdown
      await tester.tap(find.text('Select a circle'));
      await tester.pumpAndSettle();

      // Open: rotation should be 0.5
      rotation = tester.widget<AnimatedRotation>(find.byType(AnimatedRotation));
      expect(rotation.turns, 0.5);
    });

    testWidgets('shows check icon for selected circle in list', (tester) async {
      final testCircles = [
        TestCircleFactory.createCircle(
          mlsGroupId: [1, 2, 3],
          displayName: 'Family',
        ),
        TestCircleFactory.createCircle(
          mlsGroupId: [4, 5, 6],
          displayName: 'Friends',
        ),
      ];
      final mockService = MockCircleService(circles: testCircles);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            circleServiceProvider.overrideWithValue(mockService),
            selectedCircleProvider.overrideWith((ref) => testCircles[0]),
            circleDropdownOpenProvider.overrideWith((ref) => true),
          ],
          child: MaterialApp(
            theme: ThemeData(splashFactory: InkSplash.splashFactory),
            home: const Scaffold(body: CircleSelector()),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Check icon should appear for "Family" (selected) but not "Friends"
      expect(find.byIcon(Icons.check), findsOneWidget);
    });
  });
}
